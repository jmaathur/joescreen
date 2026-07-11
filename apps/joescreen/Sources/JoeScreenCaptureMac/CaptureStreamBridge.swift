import Foundation

#if os(macOS)
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Shared SCStream output + delegate plumbing for BOTH capture services (window + display, M11).
/// Extracted from `WindowCaptureService` so `DisplayCaptureService` reuses the identical, already-
/// verified frame/status/stop bridging (boxing the non-Sendable `CMSampleBuffer` on the capture
/// queue before it crosses into the actor — the R33 transfer convention).

/// Bridges `SCStreamOutput.didOutputSampleBuffer` to a closure, extracting the frame status from the
/// sample buffer's attachments (verified attachment key `SCStreamFrameInfoStatus`).
@available(macOS 14.0, *)
final class CaptureFrameOutput: NSObject, SCStreamOutput {
    static let queue = DispatchQueue(label: "com.joescreen.capture.frames", qos: .userInteractive)
    private let onSample: @Sendable (CMSampleBufferBox, FrameStatus) -> Void

    init(onSample: @escaping @Sendable (CMSampleBufferBox, FrameStatus) -> Void) {
        self.onSample = onSample
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let status = Self.status(of: sampleBuffer)
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
final class CaptureStreamDelegate: NSObject, SCStreamDelegate {
    private let onStop: @Sendable (String) -> Void
    init(onStop: @escaping @Sendable (String) -> Void) { self.onStop = onStop }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(String(describing: error))
    }
}

#endif
