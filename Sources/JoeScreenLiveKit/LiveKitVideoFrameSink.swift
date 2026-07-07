import Foundation
import CoreMedia
import CoreVideo
import LiveKit
import JoeScreenKit

/// A `VideoFrameSink` (JoeScreenKit seam) backed by a LiveKit `BufferCapturer`. Capture submits
/// `OpaqueVideoFrame`s here; this unboxes the platform buffer and feeds it to the capturer.
///
/// Frame-before-publish handshake (§3, verified in BufferCapturer.swift): LiveKit requires at least
/// ONE frame captured BEFORE `publish(videoTrack:)` or the publish times out. The transport creates
/// the sink, feeds a first frame (real or a synthetic priming frame), awaits `waitForFirstFrame()`,
/// THEN publishes. `firstFrameSubmitted` fulfills exactly once.
///
/// Pixel-format guard (R14): the SDK silently SKIPS a buffer whose format isn't in
/// `VideoCapturer.supportedPixelFormats` (which manifests as the publish timeout). We debug-assert
/// the format so a misconfigured capture is caught in development rather than as an opaque hang.
final class LiveKitVideoFrameSink: VideoFrameSink, @unchecked Sendable {
    let track: LocalVideoTrack
    private let capturer: BufferCapturer

    // First-frame gate. `continuation` is fulfilled on the first successful capture.
    private let firstFrameLock = NSLock()
    private var firstFrameContinuation: CheckedContinuation<Void, Never>?
    private var firstFrameDone = false

    init(track: LocalVideoTrack, capturer: BufferCapturer) {
        self.track = track
        self.capturer = capturer
    }

    func submit(_ frame: OpaqueVideoFrame) async {
        // Unbox to the concrete capturer call. Accept both CMSampleBuffer (ScreenCaptureKit) and
        // CVPixelBuffer (tests / alternate capture). Unknown boxes are dropped (adapter contract).
        if let box = frame.box as? CMSampleBufferBox {
            assertSupportedFormat(CMSampleBufferGetImageBuffer(box.sampleBuffer))
            capturer.capture(box.sampleBuffer)
            markFirstFrame()
        } else if let box = frame.box as? CVPixelBufferBox {
            assertSupportedFormat(box.pixelBuffer)
            // Use the frame's capture timestamp when it carries a real (non-zero) one; otherwise let
            // the SDK stamp "now" from its own monotonic clock. WebRTC drops frames with
            // non-increasing timestamps, so a real capture path must supply monotonic values (the
            // ScreenCaptureKit path does; a caller passing 0 opts into the SDK clock).
            if frame.timestampNanos != 0 {
                capturer.capture(box.pixelBuffer, timeStampNs: Int64(bitPattern: frame.timestampNanos))
            } else {
                capturer.capture(box.pixelBuffer)
            }
            markFirstFrame()
        }
        // else: an unrecognized box — silently ignore per the OpaqueVideoFrame contract.
    }

    /// Suspends until the first frame has been submitted, so the caller can publish safely.
    func waitForFirstFrame() async {
        firstFrameLock.lock()
        if firstFrameDone {
            firstFrameLock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Re-check under the lock we already hold from above.
            firstFrameContinuation = cont
            firstFrameLock.unlock()
        }
    }

    private func markFirstFrame() {
        firstFrameLock.lock()
        if !firstFrameDone {
            firstFrameDone = true
            let cont = firstFrameContinuation
            firstFrameContinuation = nil
            firstFrameLock.unlock()
            cont?.resume()
        } else {
            firstFrameLock.unlock()
        }
    }

    private func assertSupportedFormat(_ pixelBuffer: CVPixelBuffer?) {
        #if DEBUG
        guard let pixelBuffer else { return }
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let supported = VideoCapturer.supportedPixelFormats.contains { $0.uint32Value == fmt }
        assert(supported, """
            Captured pixel format \(fmt) is NOT in VideoCapturer.supportedPixelFormats — LiveKit will \
            silently drop this frame (R14) and the publish will time out. Set the SCStream pixelFormat \
            to 420v (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange).
            """)
        #endif
    }
}
