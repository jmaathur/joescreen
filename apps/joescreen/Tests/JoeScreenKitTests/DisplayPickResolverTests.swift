import XCTest
import CoreGraphics
@testable import JoeScreenKit

final class DisplayPickResolverTests: XCTestCase {

    private let candidates = [
        DisplayPickResolver.Candidate(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        DisplayPickResolver.Candidate(displayID: 2, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440)),
        DisplayPickResolver.Candidate(displayID: 3, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900)),
    ]

    func testExactMatchResolvesDisplay() {
        let rect = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(DisplayPickResolver.resolve(contentRect: rect, candidates: candidates), 2)
    }

    func testExactMatchLeftDisplay() {
        let rect = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(DisplayPickResolver.resolve(contentRect: rect, candidates: candidates), 3)
    }

    func testSubPointRoundingWithinToleranceResolves() {
        // A 1.5pt rounding drift on each edge is within the 2pt tolerance.
        let rect = CGRect(x: 1918.5, y: 1.5, width: 2561.5, height: 1441.5)
        XCTAssertEqual(DisplayPickResolver.resolve(contentRect: rect, candidates: candidates), 2)
    }

    func testBeyondToleranceIsAmbiguousNil() {
        // A rect that matches no display within tolerance → nil (caller shows retry).
        let rect = CGRect(x: 500, y: 500, width: 800, height: 600)
        XCTAssertNil(DisplayPickResolver.resolve(contentRect: rect, candidates: candidates))
    }

    func testClosestWinsWhenTwoAreNear() {
        // Two candidates near the rect; the closest (smaller max-edge deviation) wins.
        let near = [
            DisplayPickResolver.Candidate(displayID: 10, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            DisplayPickResolver.Candidate(displayID: 11, frame: CGRect(x: 1, y: 1, width: 1000, height: 1000)),
        ]
        // Rect exactly matches 10 → 10 wins (deviation 0 < 1).
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(DisplayPickResolver.resolve(contentRect: rect, candidates: near, tolerance: 3), 10)
    }

    func testEmptyCandidatesReturnsNil() {
        XCTAssertNil(DisplayPickResolver.resolve(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), candidates: []))
    }
}
