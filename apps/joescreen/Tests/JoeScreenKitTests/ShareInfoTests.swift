import XCTest
@testable import JoeScreenKit

final class ShareInfoTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    func testRoundTripFullyPopulated() throws {
        let info = ShareInfo(kind: .window, title: "main.swift — MyApp", appName: "Xcode",
                             sourcePixelWidth: 2880, sourcePixelHeight: 1800)
        let data = try encoder.encode(info)
        XCTAssertEqual(try decoder.decode(ShareInfo.self, from: data), info)
    }

    func testRoundTripMinimal() throws {
        let info = ShareInfo(kind: .display)
        let data = try encoder.encode(info)
        let back = try decoder.decode(ShareInfo.self, from: data)
        XCTAssertEqual(back, info)
        XCTAssertNil(back.title)
        XCTAssertNil(back.appName)
        XCTAssertNil(back.sourcePixelWidth)
    }

    // MARK: - Old ↔ new decode matrix (additive-only wire rule)

    func testDecodesFutureExtraFieldsIgnored() throws {
        // A NEWER peer sends a field this build doesn't know — decoding must ignore it, not throw.
        let json = """
        {"kind":"window","title":"T","appName":"A","sourcePixelWidth":100,\
        "sourcePixelHeight":50,"futureField":"whatever","anotherNew":42}
        """.data(using: .utf8)!
        let info = try decoder.decode(ShareInfo.self, from: json)
        XCTAssertEqual(info.kind, .window)
        XCTAssertEqual(info.title, "T")
        XCTAssertEqual(info.sourcePixelWidth, 100)
    }

    func testDecodesOlderPayloadMissingOptionalFields() throws {
        // An OLDER peer omitted the pixel dimensions (predates them). decodeIfPresent → nil, no throw.
        let json = #"{"kind":"window","title":"OnlyTitle"}"#.data(using: .utf8)!
        let info = try decoder.decode(ShareInfo.self, from: json)
        XCTAssertEqual(info.kind, .window)
        XCTAssertEqual(info.title, "OnlyTitle")
        XCTAssertNil(info.sourcePixelWidth)
        XCTAssertNil(info.sourcePixelHeight)
    }

    func testDecodesAncientPayloadMissingKind() throws {
        // Defensive: a payload with no `kind` at all defaults to `.window` rather than throwing.
        let json = #"{"title":"NoKind"}"#.data(using: .utf8)!
        let info = try decoder.decode(ShareInfo.self, from: json)
        XCTAssertEqual(info.kind, .window)
        XCTAssertEqual(info.title, "NoKind")
    }

    // MARK: - Aspect ratio helper

    func testSourceAspectRatio() {
        XCTAssertEqual(ShareInfo(kind: .window, sourcePixelWidth: 1600, sourcePixelHeight: 1000)
            .sourceAspectRatio!, 1.6, accuracy: 1e-9)
    }

    func testSourceAspectRatioNilWhenIncompleteOrZero() {
        XCTAssertNil(ShareInfo(kind: .window, sourcePixelWidth: 1600).sourceAspectRatio)
        XCTAssertNil(ShareInfo(kind: .window, sourcePixelWidth: 0, sourcePixelHeight: 100).sourceAspectRatio)
        XCTAssertNil(ShareInfo(kind: .window).sourceAspectRatio)
    }
}
