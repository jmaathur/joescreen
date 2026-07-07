import XCTest
import Foundation
@testable import JoeScreenKit
@testable import JoeScreenCaptureMac

#if os(macOS)
import ScreenCaptureKit
import CoreMedia

/// M3 capture smoke run. Needs Screen Recording TCC + a real on-screen window, so it SKIPS unless
/// `JOESCREEN_CAPTURE_SMOKE=1` is set (a headless/CI host would hang on the unclickable TCC prompt).
/// Grant Screen Recording once, then:
///
///   JOESCREEN_CAPTURE_SMOKE=1 swift test --filter WindowCaptureSmokeTests
///
/// Proves: `WindowCaptureService` receives ≥N `.complete` frames from a real window and forwards them
/// into a `VideoFrameSink` (the M3 gate).
@available(macOS 14.0, *)
final class WindowCaptureSmokeTests: XCTestCase {

    func testCapturesCompleteFramesFromARealWindow() async throws {
        guard ProcessInfo.processInfo.environment["JOESCREEN_CAPTURE_SMOKE"] == "1" else {
            throw XCTSkip("JOESCREEN_CAPTURE_SMOKE not set — skipping (needs Screen Recording TCC + a real window).")
        }

        let sink = CountingSink()
        let service = WindowCaptureService(windowID: UUID())

        // Collect events while capturing.
        let events = await service.events()
        let collector = Task {
            var frames = 0
            for await event in events {
                if case .frame = event { frames += 1; if frames >= 5 { break } }
            }
            return frames
        }

        do {
            // Both enumeration AND start touch Screen Recording TCC.
            let windows = try await WindowCaptureService.shareableWindows()
            let window = try XCTUnwrap(windows.first, "no shareable on-screen windows found")
            try await service.start(window: window, sink: sink)
        } catch let error as XCTSkip {
            throw error
        } catch {
            // The `xctest` binary is a transient CLI process that can't hold a Screen Recording TCC
            // grant (unlike a stable .app bundle). A -3801 "user declined TCCs" here means the TEST
            // HOST lacks the grant, not that capture is broken — real capture is verified through the
            // signed JoeScreen.app in the M4 demo. Skip rather than fail in that case.
            let desc = String(describing: error)
            if desc.contains("-3801") || desc.contains("declined TCC") {
                throw XCTSkip("Screen Recording TCC not granted to the test host (xctest can't hold it) — verify capture via the M4 app.")
            }
            throw error
        }

        // Wait up to 10s for ≥5 complete frames.
        let deadline = Date().addingTimeInterval(10)
        while await sink.count < 5, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        await service.stop()
        collector.cancel()

        let received = await sink.count
        XCTAssertGreaterThanOrEqual(received, 5, "expected ≥5 complete frames forwarded into the sink, got \(received)")
    }
}

/// A `VideoFrameSink` that just counts submitted frames.
private actor CountingSink: VideoFrameSink {
    private(set) var count = 0
    func submit(_ frame: OpaqueVideoFrame) async { count += 1 }
}

#endif
