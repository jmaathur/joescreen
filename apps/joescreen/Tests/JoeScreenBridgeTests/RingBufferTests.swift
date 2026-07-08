import XCTest
@testable import JoeScreenBridge

final class RingBufferTests: XCTestCase {

    private func frame(_ b: UInt8, pts: Double, key: Bool = false) -> EncodedFrameRingBuffer.Frame {
        EncodedFrameRingBuffer.Frame(data: Data([b]), pts: pts, isKeyframe: key)
    }

    func testWriteReadFIFO() {
        var rb = EncodedFrameRingBuffer(capacity: 4)
        rb.write(frame(1, pts: 0, key: true))
        rb.write(frame(2, pts: 1))
        XCTAssertEqual(rb.read()?.data, Data([1]))
        XCTAssertEqual(rb.read()?.data, Data([2]))
        XCTAssertNil(rb.read())
    }

    func testCapacityOverflowDropsOldest() {
        var rb = EncodedFrameRingBuffer(capacity: 2)
        rb.write(frame(1, pts: 0))
        rb.write(frame(2, pts: 1))
        rb.write(frame(3, pts: 2)) // overflow → oldest (1) dropped
        XCTAssertEqual(rb.count, 2)
        XCTAssertEqual(rb.droppedCount, 1)
        XCTAssertEqual(rb.read()?.data, Data([2]), "oldest survivor")
        XCTAssertEqual(rb.read()?.data, Data([3]))
    }

    func testByteBudgetDropsOldest() {
        // Each frame is 1 byte; a 2-byte budget forces drops beyond 2 frames regardless of capacity.
        var rb = EncodedFrameRingBuffer(capacity: 100, maxBytes: 2)
        rb.write(frame(1, pts: 0))
        rb.write(frame(2, pts: 1))
        rb.write(frame(3, pts: 2))
        XCTAssertLessThanOrEqual(rb.byteFootprint, 2)
        XCTAssertGreaterThanOrEqual(rb.droppedCount, 1)
    }

    func testNeverBlocksNeverEmptyUnbounded() {
        var rb = EncodedFrameRingBuffer(capacity: 8)
        for i in 0..<1000 { rb.write(frame(UInt8(i % 256), pts: Double(i))) }
        XCTAssertLessThanOrEqual(rb.count, 8, "bounded footprint under a flood")
    }

    func testDrainReturnsAllAvailable() {
        var rb = EncodedFrameRingBuffer(capacity: 8)
        rb.write(frame(1, pts: 0)); rb.write(frame(2, pts: 1)); rb.write(frame(3, pts: 2))
        let all = rb.drain()
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(rb.isEmpty)
    }
}
