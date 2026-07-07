import Foundation
import CoreMedia
import CoreVideo

/// `@unchecked Sendable` boxes for the platform frame carried across the `MediaTransport` seam.
///
/// `CMSampleBuffer` and `CVPixelBuffer` are NOT `Sendable` under Swift 6. `OpaqueVideoFrame.box` is
/// typed `any Sendable`, so the capture side wraps the buffer in one of these boxes and the transport
/// unwraps it. This is safe by CONVENTION: the buffer is **transferred, never shared** — the capture
/// engine hands off ownership of a fresh buffer per frame and does not retain or mutate it after
/// submitting. Nothing reads the boxed buffer concurrently on two isolation domains; it flows one
/// way, capture → sink → SDK, and is released after the SDK copies it into its own pipeline.
///
/// Defined in JoeScreenCaptureMac (the frame PRODUCER) so JoeScreenKit stays CoreMedia-free. The
/// LiveKit adapter (the CONSUMER) depends on this target and downcasts `OpaqueVideoFrame.box` to
/// these types — a clean one-way dependency (capture → boxes ← transport); capture never imports
/// LiveKit, preserving the one-libwebrtc rule (R22).

/// A boxed `CMSampleBuffer` (the ScreenCaptureKit output type — M3).
public struct CMSampleBufferBox: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public init(_ sampleBuffer: CMSampleBuffer) { self.sampleBuffer = sampleBuffer }
}

/// A boxed `CVPixelBuffer` (alternate capture output / test frames), with the rotation-free
/// timestamp the SDK's `BufferCapturer.capture(_:timeStampNs:)` overload wants.
public struct CVPixelBufferBox: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}
