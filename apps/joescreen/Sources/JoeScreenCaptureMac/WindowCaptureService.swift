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
public actor WindowCaptureService: NSObject, ShareCaptureService {

    /// Events surfaced to the caller (the app/transport orchestrator). Shared vocabulary with the
    /// display-capture service via `ShareCaptureEvent` (M11).
    public typealias Event = ShareCaptureEvent

    public nonisolated let windowID: WindowID
    private var stream: SCStream?
    private var output: CaptureFrameOutput?
    private var pauseDetector = PauseDetector()
    private var completeFrameCount = 0
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var minimizeWatcher: MinimizeUnshareWatcher?
    private var resizeWatcher: WindowResizeWatcher?
    private var resizeStabilizer = ResizeStabilizer()
    private var pauseTicker: Task<Void, Never>?

    /// The captured window's owner-space frame (for CoordinateMapper / window bounds), set on start.
    public private(set) var capturedWindowFrame: CGRect?
    public private(set) var backingScale: Double = 1.0

    /// Advisory metadata about the shared window, captured at `start` (title/app/source pixels/kind).
    /// The app broadcasts it in the RoomModel so receivers can title + aspect-size a viewer window.
    public private(set) var shareInfo: ShareInfo?

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

    /// Start capturing the window with the given OS `CGWindowID`, forwarding complete frames into
    /// `sink`. Resolves the `SCWindow` INSIDE the actor so the non-Sendable object never crosses an
    /// isolation boundary — this is the entry point callers should use (picker + --share-window-id).
    public func start(cgWindowID: CGWindowID, sink: any VideoFrameSink) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == cgWindowID }) else {
            throw CaptureError.windowNotFound(cgWindowID)
        }
        try await start(window: window, sink: sink)
    }

    public enum CaptureError: Error, Equatable {
        case windowNotFound(CGWindowID)
    }

    /// Start capturing the given SCWindow, forwarding complete frames into `sink`. Actor-internal;
    /// callers use `start(cgWindowID:sink:)` to avoid crossing a non-Sendable SCWindow.
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
        resizeStabilizer.seed(window.frame.size)

        // Capture advisory ShareInfo from the SCWindow (title + owning app + source pixels). Receivers
        // use it to title + aspect-size the viewer window before the first frame lands (M9).
        shareInfo = ShareInfo(
            kind: .window,
            title: window.title,
            appName: window.owningApplication?.applicationName,
            sourcePixelWidth: config.width,
            sourcePixelHeight: config.height)

        let output = CaptureFrameOutput { [weak self] box, status in
            // `box` is a CMSampleBufferBox (Sendable) built ON the capture queue before crossing into
            // the actor — the raw non-Sendable CMSampleBuffer never crosses isolation directly (R33
            // convention: the buffer is transferred, never shared).
            Task { await self?.handleSample(box, status: status, sink: sink) }
        }
        self.output = output

        let stream = SCStream(filter: filter, configuration: config, delegate: CaptureStreamDelegate { [weak self] reason in
            Task { await self?.handleStopped(reason: reason) }
        })
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: CaptureFrameOutput.queue)
        self.stream = stream

        try await stream.startCapture()

        // Minimize watcher (R13): a minimize ⇒ unshare.
        let watcher = MinimizeUnshareWatcher(cgWindowID: window.windowID) { [weak self] in
            Task { await self?.handleMinimized() }
        }
        watcher.start()
        self.minimizeWatcher = watcher

        // Resize watcher (M9): a settled source resize ⇒ rebuild the SCStream config so receivers
        // stay aspect-true. Raw poll → ResizeStabilizer (jitter/confirm) inside handleResizePoll.
        let resize = WindowResizeWatcher(cgWindowID: window.windowID) { [weak self] size in
            Task { await self?.handleResizePoll(size) }
        }
        resize.start()
        self.resizeWatcher = resize

        // Pause ticker: PauseDetector needs a timer tick to notice a TOTAL delivery stop (off-Space),
        // which produces no sample callbacks at all (R13).
        startPauseTicker()
    }

    /// Stop capturing and tear down.
    public func stop() async {
        pauseTicker?.cancel(); pauseTicker = nil
        minimizeWatcher?.stop(); minimizeWatcher = nil
        resizeWatcher?.stop(); resizeWatcher = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        output = nil
        eventContinuation?.finish()
    }

    // MARK: - Resize handling (M9)

    /// A raw 4 Hz size sample from the resize watcher. Runs it through the stabilizer; on a settled
    /// change, rebuilds the SCStreamConfiguration to the new pixel size and applies it live via
    /// `updateConfiguration` (async, macOS 12.3+), updates `capturedWindowFrame` + `shareInfo`, and
    /// emits `.resized` so the app re-broadcasts the new dimensions.
    private func handleResizePoll(_ pointSize: CGSize) async {
        guard let settled = resizeStabilizer.observe(pointSize), let stream else { return }
        let pixelW = Int((settled.width * CGFloat(backingScale)).rounded())
        let pixelH = Int((settled.height * CGFloat(backingScale)).rounded())
        guard pixelW > 0, pixelH > 0 else { return }

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.width = pixelW
        config.height = pixelH
        config.queueDepth = 5

        do {
            try await stream.updateConfiguration(config)
        } catch {
            // A failed reconfigure is non-fatal: the stream keeps delivering at the old size, so the
            // window just stays its prior aspect. Roll the stabilizer back so a retry can re-fire.
            resizeStabilizer.seed(capturedWindowFrame?.size ?? pointSize)
            return
        }

        // Update our owner-space frame (origin unchanged; only size shifts here — the app resolves
        // injection against live bounds elsewhere) and the advisory ShareInfo dimensions.
        if var frame = capturedWindowFrame {
            frame.size = settled
            capturedWindowFrame = frame
        }
        if var info = shareInfo {
            info.sourcePixelWidth = pixelW
            info.sourcePixelHeight = pixelH
            shareInfo = info
        }
        emit(.resized(pixelWidth: pixelW, pixelHeight: pixelH))
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
        emit(.ended(reason: "minimized"))
    }

    private func handleStopped(reason: String) {
        emit(.stopped(reason: reason))
    }

    private func emit(_ event: Event) {
        eventContinuation?.yield(event)
    }
}
// The SCStream output + delegate bridges now live in CaptureStreamBridge.swift (shared with
// DisplayCaptureService, M11).

#endif
