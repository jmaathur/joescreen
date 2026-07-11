import XCTest
import Foundation
import CoreVideo
import AVFoundation
import LiveKit
@testable import JoeScreenLiveKit
@testable import JoeScreenKit
import JoeScreenCaptureMac   // CVPixelBufferBox / CMSampleBufferBox

/// M2 integration suite. These need a running SFU — every test SKIPS (via `XCTSkip`) unless
/// `LIVEKIT_URL` is set, so the offline `swift test` gate stays green. Run with:
///
///   livekit-server --dev &
///   LIVEKIT_URL=ws://localhost:7880 swift test --filter JoeScreenLiveKitTests
///
/// Proves (§2/§3): two Rooms in one process; a synthetic video frame published on A is received on B
/// (via the verified `VideoRenderer` hook); all six data channels round-trip an Envelope with the
/// correct topic/reliability; identity binding surfaces the right ParticipantID.
final class LiveKitIntegrationTests: XCTestCase {

    /// The dev server URL, or skip.
    private func serverURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["LIVEKIT_URL"],
              let url = URL(string: raw) else {
            throw XCTSkip("LIVEKIT_URL not set — skipping LiveKit integration test (offline gate).")
        }
        return url
    }

    /// Mint a dev token for `identity` in `room` (DevTokenMinter is DEBUG-only; tests build DEBUG).
    private func token(identity: String, room: String) -> String {
        DevTokenMinter.mint(identity: identity, room: room)
    }

    // MARK: - Video A → B

    func testSyntheticVideoFrameFlowsAToB() async throws {
        let url = try serverURL()
        let room = "itest-video-\(UUID().uuidString.prefix(8))"
        let idA = UUID(), idB = UUID()

        let transportA = LiveKitTransport()
        let transportB = LiveKitTransport()
        defer { Task { await transportA.disconnect(); await transportB.disconnect() } }

        // Receiver B installs a frame-counting renderer BEFORE A publishes.
        let received = FrameCountBox()
        await transportB.setOnRemoteTrack { descriptor, track in
            let renderer = CountingRenderer(box: received, trackName: descriptor.trackName)
            track.add(videoRenderer: renderer)
            received.retain(renderer) // keep it alive for the test duration
        }

        try await transportB.connect(.init(serverURL: url, authToken: token(identity: idB.uuidString, room: room)))
        try await transportA.connect(.init(serverURL: url, authToken: token(identity: idA.uuidString, room: room)))

        // Publish a window track on A. publishVideoTrack returns the sink immediately; the track goes
        // live once the first frame is fed (frame-before-publish is handled inside the transport).
        let windowID = UUID()
        let sink = try await transportA.publishVideoTrack(for: windowID)

        // Feed synthetic 420v frames at ~30 fps so B has something to decode/render. CRITICAL: each
        // frame must have DIFFERENT content — a stream of identical frames makes the VP9 encoder emit
        // one keyframe then go silent (screen-content VP9 is highly efficient at static content), the
        // SFU reports FEED_DRY, and the receiver renders ~1 frame. Varying luma per frame keeps the
        // encoder producing a continuous stream.
        let feeder = Task {
            var tick: UInt8 = 0
            for _ in 0..<300 {
                // timestampNanos: 0 → the sink lets the SDK stamp each frame from its own monotonic
                // clock (WebRTC drops non-increasing timestamps; the SDK clock guarantees monotonic).
                await sink.submit(Self.syntheticFrame(luma: tick, timestampNanos: 0))
                tick = tick &+ 7                 // change content every frame so the encoder streams
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        defer { feeder.cancel() }

        // Wait up to 15s for B to render at least a few frames.
        let ok = await received.waitForFrames(atLeast: 3, timeout: 15)
        XCTAssertTrue(ok, "receiver B did not render frames from A within timeout")
    }

    // MARK: - Six data channels round-trip

    func testAllSixDataChannelsRoundTrip() async throws {
        let url = try serverURL()
        let room = "itest-data-\(UUID().uuidString.prefix(8))"
        let idA = UUID(), idB = UUID()

        let transportA = LiveKitTransport()
        let transportB = LiveKitTransport()
        defer { Task { await transportA.disconnect(); await transportB.disconnect() } }

        try await transportB.connect(.init(serverURL: url, authToken: token(identity: idB.uuidString, room: room)))
        try await transportA.connect(.init(serverURL: url, authToken: token(identity: idA.uuidString, room: room)))
        try await transportA.openAllDataChannels()
        try await transportB.openAllDataChannels()

        // Iterate DataChannel.allCases — SIX channels, not five.
        XCTAssertEqual(DataChannel.allCases.count, 6)
        for channel in DataChannel.allCases {
            let chA = try await transportA.openDataChannel(channel)
            let chB = try await transportB.openDataChannel(channel)

            // Build an envelope appropriate to this channel so validate() passes.
            let env = try Self.sampleEnvelope(for: channel, sender: idA)
            let bytes = try WireCodec.makeEncoder().encode(env)

            // Subscribe on B, then send from A.
            var iterator = chB.incoming().makeAsyncIterator()
            try await chA.send(bytes)

            let receivedBytes = try await withThrowingTaskGroup(of: Data?.self) { group -> Data? in
                group.addTask { await iterator.next() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            let got = try XCTUnwrap(receivedBytes, "channel \(channel.rawValue) delivered no data")
            let decoded = try JSONDecoder().decode(Envelope.self, from: got)
            XCTAssertEqual(decoded.rawKind, env.rawKind, "channel \(channel.rawValue) kind mismatch")
            XCTAssertEqual(decoded.senderID, idA, "channel \(channel.rawValue) sender mismatch")
        }
    }

    // MARK: - Identity binding

    func testIdentityBindingSurfacesParticipantID() async throws {
        let url = try serverURL()
        let room = "itest-id-\(UUID().uuidString.prefix(8))"
        let idA = UUID()

        let transportA = LiveKitTransport()
        defer { Task { await transportA.disconnect() } }
        try await transportA.connect(.init(serverURL: url, authToken: token(identity: idA.uuidString, room: room)))

        // The identity string (JWT sub = idA.uuidString) maps back to the ParticipantID.
        let mapped = await transportA.participantID(forIdentity: idA.uuidString)
        XCTAssertEqual(mapped, idA)

        // An explicit binding is honored.
        let other = UUID()
        await transportA.bindIdentity(other, transportIdentity: "custom-identity")
        let mappedCustom = await transportA.participantID(forIdentity: "custom-identity")
        XCTAssertEqual(mappedCustom, other)

        // An unparseable identity with no binding yields nil (transport rejects it — §3).
        let none = await transportA.participantID(forIdentity: "not-a-uuid")
        XCTAssertNil(none)
    }

    // MARK: - Helpers

    /// A synthetic 420v (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) pixel buffer boxed as an
    /// OpaqueVideoFrame. 320×240; the Y plane is filled with `luma` so successive frames DIFFER,
    /// keeping the VP9 encoder producing a continuous stream (a static frame stalls to FEED_DRY).
    static func syntheticFrame(luma: UInt8 = 128, timestampNanos: UInt64 = 0) -> OpaqueVideoFrame {
        let width = 320, height = 240
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        // Fill Y plane with the per-frame luma; chroma neutral. Add a moving diagonal so there's real
        // spatial change frame-to-frame, not just a global level shift.
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let ptr = yBase.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    ptr[row * rowBytes + col] = UInt8((Int(luma) + row + col) & 0xFF)
                }
            }
        }
        if let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let cBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2)
            memset(cBase, 128, cBytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return OpaqueVideoFrame(
            box: CVPixelBufferBox(buffer),
            timestampNanos: timestampNanos,
            pixelWidth: width, pixelHeight: height)
    }

    /// A valid envelope for `channel` (satisfies validate()'s seq-presence contract).
    static func sampleEnvelope(for channel: DataChannel, sender: ParticipantID) throws -> Envelope {
        let window = UUID()
        switch channel {
        case .cursor:
            return try WireCodec.pack(CursorMove(windowID: window, point: .init(x: 0.5, y: 0.5), timestamp: 1), sender: sender)
        case .input:
            return try WireCodec.pack(InputEvent(eventKind: .keyDown, windowID: window, keyCode: 4), sender: sender, seq: 1)
        case .clipboard:
            return try WireCodec.pack(ClipboardPayload(type: .utf8Text, bytes: Data("hi".utf8)), sender: sender)
        case .terminal:
            return try WireCodec.pack(TerminalData(ptyBytes: Data("ls\n".utf8)), sender: sender)
        case .draw:
            return try WireCodec.pack(DrawOp(authorID: sender, authorSeq: 1, windowID: window,
                                             points: [.init(x: 0, y: 0)], color: .init(r: 1, g: 0, b: 0, a: 1), width: 2), sender: sender)
        case .state:
            var model = RoomModel(); model.addShare(window, owner: sender)
            return try WireCodec.pack(RoomSnapshot(model: model), sender: sender)
        }
    }
}

// MARK: - Test renderer + frame counter

/// A LiveKit `VideoRenderer` that counts frames it receives — the verified receive assertion (§3).
///
/// CRITICAL for adaptive stream (verified in RemoteTrackPublication.swift:346–379): with
/// `adaptiveStream: true` (R24, load-bearing), the SDK sets `videoTrack.shouldReceive = isEnabled`,
/// where `isEnabled` is true ONLY if at least one attached renderer reports
/// `isAdaptiveStreamEnabled == true` AND a non-zero `adaptiveStreamSize` (it picks `largestSize()`).
/// A renderer that reports `false`/`.zero` causes the SFU to send NO frames. So this test renderer
/// reports enabled + a real size — exactly what a real on-screen SwiftUIVideoView does.
final class CountingRenderer: VideoRenderer, @unchecked Sendable {
    private let box: FrameCountBox
    let trackName: String
    init(box: FrameCountBox, trackName: String) { self.box = box; self.trackName = trackName }

    // The SDK renderer contract — report as a visible, adaptive-stream-enabled renderer so the SFU
    // actually forwards frames.
    var isAdaptiveStreamEnabled: Bool { true }
    var adaptiveStreamSize: CGSize { CGSize(width: 320, height: 240) }
    func set(size: CGSize) {}
    func render(frame: VideoFrame) { box.increment() }
    func render(frame: VideoFrame, captureDevice: AVCaptureDevice?, captureOptions: VideoCaptureOptions?) {
        box.increment()
    }
}

/// Thread-safe frame counter shared with the test.
final class FrameCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var retained: [AnyObject] = []

    func increment() { lock.lock(); count += 1; lock.unlock() }
    func retain(_ obj: AnyObject) { lock.lock(); retained.append(obj); lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// Poll until at least `atLeast` frames arrive or the timeout elapses.
    func waitForFrames(atLeast: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if current >= atLeast { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return current >= atLeast
    }
}
