import XCTest
@testable import JoeScreenKit

final class AdmissionControllerTests: XCTestCase {

    func testSFUAdmitsWhenUnderBudget() {
        let c = AdmissionController(config: .init(uplinkSafetyFraction: 0.7, maxEncodeSessions: 4))
        // 1 existing @2Mbps, adding @3Mbps, 20Mbps up, 5 peers, SFU (1 copy).
        // fullCost = 1 * (2M*1 + 3M) = 5M ≤ 0.7*20M = 14M → admit.
        let d = c.admitShare(currentWindowCount: 1, requestedBitrate: 3_000_000,
                             existingBitrate: 2_000_000, measuredUplinkBps: 20_000_000,
                             peerCount: 5, topology: .sfu)
        XCTAssertEqual(d, .admit(bitrate: 3_000_000))
    }

    func testSFUDegradesWhenOverBudget() {
        let c = AdmissionController(config: .init(uplinkSafetyFraction: 0.7, maxEncodeSessions: 4,
                                                  minPerWindowBitrate: 500_000))
        // 2 existing @3Mbps, adding @3Mbps, only 10Mbps up. budget=7M.
        // fullCost = 3*3=9M > 7M → degrade. perWindow = 7M/(1*3)=2.33M ≥ floor → degrade.
        let d = c.admitShare(currentWindowCount: 2, requestedBitrate: 3_000_000,
                             existingBitrate: 3_000_000, measuredUplinkBps: 10_000_000,
                             peerCount: 3, topology: .sfu)
        guard case let .degrade(pw) = d else { return XCTFail("expected degrade, got \(d)") }
        XCTAssertEqual(pw, 7_000_000.0 / 3.0, accuracy: 1.0)
    }

    func testRefusesWhenBelowFloor() {
        let c = AdmissionController(config: .init(uplinkSafetyFraction: 0.7, maxEncodeSessions: 10,
                                                  minPerWindowBitrate: 2_000_000))
        // Tiny uplink: even the floor won't fit.
        let d = c.admitShare(currentWindowCount: 3, requestedBitrate: 3_000_000,
                             existingBitrate: 3_000_000, measuredUplinkBps: 3_000_000,
                             peerCount: 3, topology: .sfu)
        guard case .refuseAtCapacity(.uplinkExhausted) = d else { return XCTFail("expected uplink refuse, got \(d)") }
    }

    func testEncodeSessionCapRefusesRegardlessOfBandwidth() {
        let c = AdmissionController(config: .init(maxEncodeSessions: 1))
        // Base-chip single-encoder case: already sharing 1, adding a 2nd is refused structurally
        // even on an infinite uplink.
        let d = c.admitShare(currentWindowCount: 1, requestedBitrate: 1,
                             existingBitrate: 1, measuredUplinkBps: 1_000_000_000,
                             peerCount: 2, topology: .sfu)
        XCTAssertEqual(d, .refuseAtCapacity(reason: .encodeSessionCap(max: 1)))
    }

    func testMeshMultipliesCostByPeersMinusOne() {
        let c = AdmissionController(config: .init(uplinkSafetyFraction: 1.0, maxEncodeSessions: 8))
        // 0 existing, adding @3Mbps, 10 peers mesh → 9 copies = 27Mbps. 20Mbps up → cannot admit
        // at full; must degrade or refuse. Proves the (N-1) multiplier is applied.
        let d = c.admitShare(currentWindowCount: 0, requestedBitrate: 3_000_000,
                             existingBitrate: 0, measuredUplinkBps: 20_000_000,
                             peerCount: 10, topology: .mesh)
        if case .admit = d { XCTFail("mesh at 9 copies must not admit full 27Mbps into 20Mbps") }
    }

    func testDecodeWindowCap() {
        let c = AdmissionController(config: .init(maxDecodedWindows: 6))
        XCTAssertTrue(c.canDecodeAnotherWindow(currentlyDecoded: 5))
        XCTAssertFalse(c.canDecodeAnotherWindow(currentlyDecoded: 6))
    }
}
