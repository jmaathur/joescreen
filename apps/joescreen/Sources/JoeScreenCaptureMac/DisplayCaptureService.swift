import Foundation
import JoeScreenKit

#if os(macOS)
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Captures a WHOLE display via ScreenCaptureKit and forwards its frames into a `VideoFrameSink`
/// (spec §M11). Sibling of `WindowCaptureService`; shares `CaptureStreamBridge` for the SCStream
/// output/delegate plumbing and conforms to `ShareCaptureService` so `AppModel` treats window +
/// display shares uniformly.
///
/// Filter: `SCContentFilter(display:excludingApplications:[ownApp] exceptingWindows:[])` — excludes
/// ALL of JoeScreen's windows (including future remote-share viewers), the hall-of-mirrors fix.
/// Resolution: `DisplayResolutionPolicy` (cap area, snap even, never upscale). 420v, 30 fps, cursor
/// SHOWN (deviation from the window path — the overlay plane never carries the sharer's own pointer;
/// decided in §5). Lifecycle: display removal (1 Hz poll) = terminal; screen lock/unlock = pause/
/// resume (SCK keeps delivering lock-screen frames, so PauseDetector alone never fires); display-
/// resolution change → `updateConfiguration`.
@available(macOS 14.0, *)
public actor DisplayCaptureService: NSObject, ShareCaptureService {

    public typealias Event = ShareCaptureEvent

    public nonisolated let windowID: WindowID
    private let displayID: CGDirectDisplayID

    private var stream: SCStream?
    private var output: CaptureFrameOutput?
    private var pauseDetector = PauseDetector()
    private var completeFrameCount = 0
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var pauseTicker: Task<Void, Never>?
    private var displayWatcher: DisplayLifecycleWatcher?

    public private(set) var backingScale: Double = 1.0
    public private(set) var shareInfo: ShareInfo?
    /// Locked (screen-lock pause) — while true, complete frames are suppressed from the sink.
    private var isScreenLocked = false

    public init(windowID: WindowID, displayID: CGDirectDisplayID) {
        self.windowID = windowID
        self.displayID = displayID
        super.init()
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in self.eventContinuation = continuation }
    }

    // MARK: - Start / stop

    /// Start capturing `displayID`, forwarding complete frames into `sink`. Resolves the SCDisplay
    /// INSIDE the actor so the non-Sendable object never crosses an isolation boundary.
    public func start(sink: any VideoFrameSink) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        // Exclude ALL of our own app's windows (hall-of-mirrors fix): find our SCRunningApplication.
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = Double(filter.pointPixelScale == 0 ? 1 : filter.pointPixelScale)
        backingScale = scale
        let resolution = DisplayResolutionPolicy.resolution(
            pointWidth: display.width, pointHeight: display.height, pointPixelScale: scale)

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Displays SHOW the cursor (deviation from the window path — decided §5). The overlay plane
        // never carries the sharer's own pointer, so bake it into the display frame.
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.width = resolution.width
        config.height = resolution.height
        config.queueDepth = 5

        shareInfo = ShareInfo(
            kind: .display,
            title: "Screen \(displayIndex(of: display, in: content))",
            appName: nil,
            sourcePixelWidth: resolution.width,
            sourcePixelHeight: resolution.height)

        let output = CaptureFrameOutput { [weak self] box, status in
            Task { await self?.handleSample(box, status: status, sink: sink) }
        }
        self.output = output

        let stream = SCStream(filter: filter, configuration: config, delegate: CaptureStreamDelegate { [weak self] reason in
            Task { await self?.handleStopped(reason: reason) }
        })
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: CaptureFrameOutput.queue)
        self.stream = stream
        try await stream.startCapture()

        startPauseTicker()

        // Lifecycle watcher: screen lock/unlock = pause/resume; display removal = terminal end.
        let watcher = DisplayLifecycleWatcher(
            displayID: displayID,
            onLockChange: { [weak self] locked in Task { await self?.handleLockChange(locked) } },
            onDisplayRemoved: { [weak self] in Task { await self?.handleDisplayRemoved() } })
        watcher.start()
        self.displayWatcher = watcher
    }

    public func stop() async {
        pauseTicker?.cancel(); pauseTicker = nil
        displayWatcher?.stop(); displayWatcher = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
        eventContinuation?.finish()
    }

    public enum CaptureError: Error, Equatable {
        case displayNotFound(CGDirectDisplayID)
    }

    // MARK: - Frame handling

    private func handleSample(_ box: CMSampleBufferBox, status: FrameStatus, sink: any VideoFrameSink) async {
        let now = ProcessInfo.processInfo.systemUptime
        if let transition = pauseDetector.observe(status, now: now) {
            emit(transition == .didPause ? .paused : .resumed)
        }
        // While screen-locked we still receive lock-screen frames; suppress them from the sink so we
        // don't broadcast the lock screen (and report paused).
        guard !isScreenLocked else { return }
        let imageBuffer = CMSampleBufferGetImageBuffer(box.sampleBuffer)
        guard status == .complete, let imageBuffer else { return }

        completeFrameCount += 1
        let count = completeFrameCount
        let dims = (CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer))
        let frame = OpaqueVideoFrame(
            box: box, timestampNanos: 0, pixelWidth: dims.0, pixelHeight: dims.1)
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

    private func handleLockChange(_ locked: Bool) {
        isScreenLocked = locked
        // SCK keeps delivering lock-screen frames, so PauseDetector never fires on lock — surface the
        // pause explicitly. Unlock resumes.
        emit(locked ? .paused : .resumed)
    }

    private func handleDisplayRemoved() {
        emit(.ended(reason: "display removed"))
    }

    private func handleStopped(reason: String) {
        emit(.stopped(reason: reason))
    }

    private func emit(_ event: Event) {
        eventContinuation?.yield(event)
    }

    /// A stable 1-based index of the display among the content's displays (for a human title).
    private func displayIndex(of display: SCDisplay, in content: SCShareableContent) -> Int {
        (content.displays.firstIndex { $0.displayID == display.displayID } ?? 0) + 1
    }
}

#endif
