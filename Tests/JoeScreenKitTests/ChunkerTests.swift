import XCTest
@testable import JoeScreenKit

final class ChunkerTests: XCTestCase {

    // A payload under the limit becomes one chunk (count == 1) and round-trips whole.
    func testSmallPayloadIsOneChunk() throws {
        let data = Data("hello world".utf8)
        let chunks = Chunker.split(data, maxChunkBytes: 1000)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].index, 0)
        XCTAssertEqual(chunks[0].count, 1)
        XCTAssertEqual(chunks[0].payload, data)

        var r = Chunker.Reassembler()
        XCTAssertEqual(try r.offer(chunks[0]), data)
        XCTAssertEqual(r.pendingGroupCount, 0)
    }

    // A payload above the limit splits into ceil(n/max) chunks that reassemble byte-intact.
    func testLargePayloadSplitsAndReassembles() throws {
        // 25 KB of structured bytes so a boundary bug corrupts detectably.
        var data = Data()
        for i in 0..<25_000 { data.append(UInt8(i % 251)) }
        let max = 10_000
        let chunks = Chunker.split(data, maxChunkBytes: max)
        XCTAssertEqual(chunks.count, 3) // ceil(25000/10000)
        XCTAssertEqual(chunks[0].payload.count, 10_000)
        XCTAssertEqual(chunks[1].payload.count, 10_000)
        XCTAssertEqual(chunks[2].payload.count, 5_000)
        for c in chunks { XCTAssertEqual(c.count, 3) }
        // All share one group.
        XCTAssertEqual(Set(chunks.map(\.groupID)).count, 1)

        var r = Chunker.Reassembler()
        var out: Data?
        for c in chunks { out = try r.offer(c) ?? out }
        XCTAssertEqual(out, data)
        XCTAssertEqual(r.pendingGroupCount, 0)
    }

    // Fragments arriving out of order within a group still reassemble correctly.
    func testOutOfOrderFragmentsReassemble() throws {
        var data = Data()
        for i in 0..<30_000 { data.append(UInt8((i * 7) % 251)) }
        let chunks = Chunker.split(data, maxChunkBytes: 8_000) // 4 chunks
        XCTAssertEqual(chunks.count, 4)

        var r = Chunker.Reassembler()
        // Deliver in a shuffled order; only the last delivered fragment completes the group.
        let order = [2, 0, 3, 1]
        var completed: Data?
        for (i, idx) in order.enumerated() {
            let result = try r.offer(chunks[idx])
            if i < order.count - 1 {
                XCTAssertNil(result, "group should stay partial until the final fragment")
            } else {
                completed = result
            }
        }
        XCTAssertEqual(completed, data)
    }

    // Duplicate fragments are idempotent (a reliable channel may re-deliver).
    func testDuplicateFragmentsAreIdempotent() throws {
        var data = Data()
        for i in 0..<20_000 { data.append(UInt8(i % 251)) }
        let chunks = Chunker.split(data, maxChunkBytes: 10_000) // 2 chunks

        var r = Chunker.Reassembler()
        XCTAssertNil(try r.offer(chunks[0]))
        XCTAssertNil(try r.offer(chunks[0]), "duplicate must not complete the group")
        XCTAssertEqual(try r.offer(chunks[1]), data)
    }

    // Two interleaved groups reassemble independently.
    func testInterleavedGroupsAreIndependent() throws {
        let a = Data(repeating: 0xAA, count: 15_000)
        let b = Data(repeating: 0xBB, count: 15_000)
        let ca = Chunker.split(a, maxChunkBytes: 10_000) // 2
        let cb = Chunker.split(b, maxChunkBytes: 10_000) // 2

        var r = Chunker.Reassembler()
        XCTAssertNil(try r.offer(ca[0]))
        XCTAssertNil(try r.offer(cb[0]))
        XCTAssertEqual(r.pendingGroupCount, 2)
        XCTAssertEqual(try r.offer(cb[1]), b)
        XCTAssertEqual(try r.offer(ca[1]), a)
        XCTAssertEqual(r.pendingGroupCount, 0)
    }

    // Wire encode/decode of a chunk frame is byte-stable and lossless.
    func testChunkWireRoundTrip() throws {
        let chunk = Chunker.Chunk(
            groupID: UUID(), index: 2, count: 5, payload: Data("frag\n\t".utf8))
        let enc1 = try Chunker.encode(chunk)
        let enc2 = try Chunker.encode(chunk)
        XCTAssertEqual(enc1, enc2, "sorted-keys encoder is deterministic")
        let back = try Chunker.decode(enc1)
        XCTAssertEqual(back, chunk)
    }

    // Empty payload still yields a reconstructable (empty) message.
    func testEmptyPayload() throws {
        let chunks = Chunker.split(Data(), maxChunkBytes: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 1)
        var r = Chunker.Reassembler()
        XCTAssertEqual(try r.offer(chunks[0]), Data())
    }

    // A full clipboard-image-sized payload (>15 KB LiveKit limit) round-trips at the real budget.
    func testRealisticClipboardImageRoundTrip() throws {
        // 120 KB "image" — well over the ~15 KB LiveKit data cap.
        var image = Data()
        for i in 0..<120_000 { image.append(UInt8((i &* 31 &+ 7) % 256)) }
        let chunks = Chunker.split(image) // default budget
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            let wire = try Chunker.encode(c)
            // Encoded chunk (with base64 + JSON) must fit under the 15 KB LiveKit message cap.
            XCTAssertLessThanOrEqual(wire.count, 15_000, "encoded chunk must fit LiveKit's ~15KB cap")
        }
        var r = Chunker.Reassembler()
        var out: Data?
        // Decode through the wire like the transport does.
        for c in chunks { out = try r.offer(Chunker.decode(try Chunker.encode(c))) ?? out }
        XCTAssertEqual(out, image)
    }

    // Inconsistent count across a group's fragments is rejected.
    func testInconsistentCountRejected() throws {
        let g = UUID()
        var r = Chunker.Reassembler()
        _ = try r.offer(Chunker.Chunk(groupID: g, index: 0, count: 3, payload: Data([1])))
        XCTAssertThrowsError(try r.offer(Chunker.Chunk(groupID: g, index: 1, count: 4, payload: Data([2])))) { err in
            XCTAssertEqual(err as? Chunker.Reassembler.OfferError,
                           .inconsistentCount(groupID: g, expected: 3, got: 4))
        }
    }

    // Out-of-range index is rejected.
    func testIndexOutOfRangeRejected() {
        let g = UUID()
        var r = Chunker.Reassembler()
        XCTAssertThrowsError(try r.offer(Chunker.Chunk(groupID: g, index: 5, count: 3, payload: Data()))) { err in
            XCTAssertEqual(err as? Chunker.Reassembler.OfferError,
                           .indexOutOfRange(groupID: g, index: 5, count: 3))
        }
    }
}
