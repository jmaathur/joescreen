import XCTest
@testable import JoeScreenKit

/// M11 heterogeneous admission overload. The existing `AdmissionControllerTests` cover the
/// homogeneous path; these cover distinct per-share bitrates + legacy delegation equivalence.
final class AdmissionOverloadTests: XCTestCase {

    private let controller = AdmissionController(config: .init(
        uplinkSafetyFraction: 0.70, maxEncodeSessions: 3, maxDecodedWindows: 6,
        minPerWindowBitrate: 800_000))

    func testHeterogeneousAdmitUnderBudget() {
        // Existing: a 2.5 Mbps window + a 3.9 Mbps display; request 2.5 Mbps. Sum = 8.9 Mbps ≤
        // 0.7×20 = 14 Mbps → admit at requested.
        let d = controller.admitShare(
            existingBitrates: [2_500_000, 3_900_000], requestedBitrate: 2_500_000,
            measuredUplinkBps: 20_000_000, peerCount: 3, topology: .sfu)
        XCTAssertEqual(d, .admit(bitrate: 2_500_000))
    }

    func testHeterogeneousDegradeUniformly() {
        // Existing two 5 Mbps shares + request 5 Mbps = 15 Mbps > 0.7×18 = 12.6 → degrade to a uniform
        // per-window = 12.6/3 = 4.2 Mbps (≥ floor).
        let d = controller.admitShare(
            existingBitrates: [5_000_000, 5_000_000], requestedBitrate: 5_000_000,
            measuredUplinkBps: 18_000_000, peerCount: 2, topology: .sfu)
        guard case .degrade(let perWindow) = d else { return XCTFail("expected degrade, got \(d)") }
        XCTAssertEqual(perWindow, 12_600_000.0 / 3.0, accuracy: 1.0)
    }

    func testHeterogeneousRefuseBelowFloor() {
        // Tiny uplink → even the floor (0.8 Mbps × 2 windows) won't fit.
        let d = controller.admitShare(
            existingBitrates: [5_000_000], requestedBitrate: 5_000_000,
            measuredUplinkBps: 1_000_000, peerCount: 2, topology: .sfu)
        guard case .refuseAtCapacity(.uplinkExhausted) = d else {
            return XCTFail("expected uplink refusal, got \(d)")
        }
    }

    func testEncodeSessionCapRefusesRegardlessOfBandwidth() {
        // 3 existing shares + 1 = 4 > maxEncodeSessions 3 → structural refuse even with huge uplink.
        let d = controller.admitShare(
            existingBitrates: [1_000_000, 1_000_000, 1_000_000], requestedBitrate: 1_000_000,
            measuredUplinkBps: 100_000_000, peerCount: 2, topology: .sfu)
        XCTAssertEqual(d, .refuseAtCapacity(reason: .encodeSessionCap(max: 3)))
    }

    // MARK: - Legacy delegation equivalence

    func testLegacySignatureMatchesHeterogeneousWithUniformBitrates() {
        // The homogeneous signature must produce the SAME decision as the overload fed uniform values.
        for (count, existing, requested, uplink) in [
            (1, 2_000_000.0, 2_000_000.0, 20_000_000.0),
            (2, 4_000_000.0, 4_000_000.0, 10_000_000.0),
            (0, 3_000_000.0, 3_000_000.0, 1_000_000.0),
        ] {
            let legacy = controller.admitShare(
                currentWindowCount: count, requestedBitrate: requested, existingBitrate: existing,
                measuredUplinkBps: uplink, peerCount: 3, topology: .sfu)
            let hetero = controller.admitShare(
                existingBitrates: Array(repeating: existing, count: count), requestedBitrate: requested,
                measuredUplinkBps: uplink, peerCount: 3, topology: .sfu)
            XCTAssertEqual(legacy, hetero, "mismatch at count=\(count)")
        }
    }
}
