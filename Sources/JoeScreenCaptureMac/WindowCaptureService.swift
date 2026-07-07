import Foundation
import JoeScreenKit

#if os(macOS)
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures ONE macOS window via ScreenCaptureKit and forwards its frames into a `VideoFrameSink`
/// (spec §3 / D10 / M3). One service instance == one shared window == one published track.
///
/// Pipeline: `SCContentSharingPicker` (primary) or a `--share-window-id` bypass →
/// `SCContentFilter(desktopIndependentWindow:)` → `SCStream` configured 420v / `showsCursor = false`
/// / `minimumFrameInterval 1/30` (verified against the 14.x SDK headers) → per-frame
/// `didOutputSampleBuffer` → classify status through `PauseDetector` (pause ≠ disconnect, R13) →
/// forward `.complete` frames as `OpaqueVideoFrame`s boxing the `CMSampleBuffer`.
///
/// A `MinimizeUnshareWatcher` observes the window; a minimize ⇒ stop + emit an unshare event (R13).
///
/// Runtime-only (needs Screen Recording TCC); the pure classification it drives (`PauseDetector`) is
/// unit-tested separately. This service is exercised by the M3 capture smoke run + the M4 demo.
@available(macOS 14.0, *)
public actor WindowCaptureService: NSObject {

    /// Events surfaced to the caller (the app/transport orchestrator).
    public enum Event: Sendable {
        /// A `.complete` frame was captured and forwarded to the sink.
        case frame(count: Int)
        /// The capture pipeline paused (window off-Space / suspended) — NOT a disconnect (R13).
        case paused
        /// The capture pipeline resumed delivering complete frames.
        case resumed
        /// The window was minimized ⇒ the share should end (R13).
        case minimizedShouldUnshare
        /// The stream stopped with an error (SCStreamDelegate.didStopWithError).
        case stopped(reason: String)
    }

    private let windowID: WindowID
    private var stream: SCStream?
    private var output: FrameOutput?
    private var pauseDetector = PauseDetector()
    private var completeFrameCount = 0
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var minimizeWatcher: MinimizeUnshareWatcher?
    private var pauseTicker: Task<Void, Never>?

    /// The captured window's owner-space frame (for CoordinateMapper / window bounds), set on start.
    public private(set) var capturedWindowFrame: CGRect?
    public private(set) var backingScale: Double = 1.0

    /// - Parameter windowID: the JoeScreen window identity this capture publishes under (the track
    ///   name is derived from it upstream). Distinct from the OS `CGWindowID`.
    public init(windowID: WindowID) {
        self.windowID = windowID
        super.init()
    }

    /// The event stream. Subscribe before `start`.
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    // MARK: - Window enumeration

    /// All shareable on-screen windows with a title (for a custom picker or the `--share-window-id`
    /// lookup). Excludes desktop windows.
    public static func shareableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.filter { $0.isOnScreen && ($0.title?.isEmpty == false) }
    }

    /// Find a shareable window by its OS `CGWindowID` (the `--share-window-id` debug bypass path).
    public static func window(cgWindowID: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == cgWindowID }
    }

    // MARK: - Start / stop

    /// Start capturing the given SCWindow, forwarding complete frames into `sink`.
    public func start(window: SCWindow, sink: any VideoFrameSink) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        // 420v — verified in VideoCapturer.supportedPixelFormats (R14); the SDK silently drops other
        // formats, so this MUST match. Debug-asserted downstream in the sink.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Remote cursors render in the overlay (M6), not baked into the frame (D10).
        config.showsCursor = false
        // 30 fps source cap (D5 legibility invariant).
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // Size to the window's pixel dimensions.
        let scale = Double(filter.pointPixelScale == 0 ? 1 : filter.pointPixelScale)
        backingScale = scale
        config.width = Int(window.frame.width * CGFloat(scale))
        config.height = Int(window.frame.height * CGFloat(scale))
        config.queueDepth = 5
        capturedWindowFrame = window.frame

        let output = FrameOutput { [weak self] box, status in
            // `box` is a CMSampleBufferBox (Sendable) built ON the capture queue before crossing into
            // the actor — the raw non-Sendable CMSampleBuffer never crosses isolation directly (R33
            // convention: the buffer is transferred, never shared).
            Task { await self?.handleSample(box, status: status, sink: sink) }
        }
        self.output = output

        let stream = SCStream(filter: filter, configuration: config, delegate: StreamDelegate { [weak self] reason in
            Task { await self?.handleStopped(reason: reason) }
        })
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: FrameOutput.queue)
        self.stream = stream

        try await stream.startCapture()

        // Minimize watcher (R13): a minimize ⇒ unshare.
        let watcher = MinimizeUnshareWatcher(cgWindowID: window.windowID) { [weak self] in
            Task { await self?.handleMinimized() }
        }
        watcher.start()
        self.minimizeWatcher = watcher

        // Pause ticker: PauseDetector needs a timer tick to notice a TOTAL delivery stop (off-Space),
        // which produces no sample callbacks at all (R13).
        startPauseTicker()
    }

    /// Stop capturing and tear down.
    public func stop() async {
        pauseTicker?.cancel(); pauseTicker = nil
        minimizeWatcher?.stop(); minimizeWatcher = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        output = nil
        eventContinuation?.finish()
    }

    // MARK: - Frame handling

    private func handleSample(_ box: CMSampleBufferBox, status: FrameStatus, sink: any VideoFrameSink) async {
        let now = ProcessInfo.processInfo.systemUptime
        if let transition = pauseDetector.observe(status, now: now) {
            emit(transition == .didPause ? .paused : .resumed)
        }
        let imageBuffer = CMSampleBufferGetImageBuffer(box.sampleBuffer)
        guard status == .complete, let imageBuffer else { return }

        completeFrameCount += 1
        let count = completeFrameCount
        let dims = (CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer))
        let frame = OpaqueVideoFrame(
            box: box,
            timestampNanos: 0, // let the transport/SDK stamp with its monotonic clock (R33)
            pixelWidth: dims.0, pixelHeight: dims.1)
        await sink.submit(frame)
        emit(.frame(count: count))
    }

    private func startPauseTicker() {
        pauseTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self?.tickPause()
            }
        }
    }

    private func tickPause() {
        let now = ProcessInfo.processInfo.systemUptime
        if let transition = pauseDetector.tick(now: now) {
            emit(transition == .didPause ? .paused : .resumed)
        }
    }

    private func handleMinimized() {
        emit(.minimizedShouldUnshare)
    }

    private func handleStopped(reason: String) {
        emit(.stopped(reason: reason))
    }

    private func emit(_ event: Event) {
        eventContinuation?.yield(event)
    }
}

// MARK: - SCStreamOutput bridge

/// Bridges `SCStreamOutput.didOutputSampleBuffer` to a closure, extracting the `SCFrameStatus` from
/// the sample buffer's attachments (verified attachment key `SCStreamFrameInfoStatus`).
@available(macOS 14.0, *)
private final class FrameOutput: NSObject, SCStreamOutput {
    static let queue = DispatchQueue(label: "com.joescreen.capture.frames", qos: .userInteractive)
    private let onSample: @Sendable (CMSampleBufferBox, FrameStatus) -> Void

    init(onSample: @escaping @Sendable (CMSampleBufferBox, FrameStatus) -> Void) {
        self.onSample = onSample
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let status = FrameOutput.status(of: sampleBuffer)
        // Box the (non-Sendable) buffer on THIS queue so only the Sendable box crosses into the actor.
        onSample(CMSampleBufferBox(sampleBuffer), status)
    }

    /// Read the frame status from the buffer's attachments; map the SC enum to our testable enum.
    static func status(of sampleBuffer: CMSampleBuffer) -> FrameStatus {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let rawStatus = attachments[.status] as? Int,
              let scStatus = SCFrameStatus(rawValue: rawStatus) else {
            // No status attachment: treat as complete if it carries an image, else idle.
            return CMSampleBufferGetImageBuffer(sampleBuffer) != nil ? .complete : .idle
        }
        switch scStatus {
        case .complete, .started: return .complete
        case .idle:               return .idle
        case .blank:              return .blank
        case .suspended, .stopped: return .suspended
        @unknown default:         return .idle
        }
    }
}

/// Bridges `SCStreamDelegate.didStopWithError` to a closure.
@available(macOS 14.0, *)
private final class StreamDelegate: NSObject, SCStreamDelegate {
    private let onStop: @Sendable (String) -> Void
    init(onStop: @escaping @Sendable (String) -> Void) { self.onStop = onStop }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(String(describing: error))
    }
}

#endif
