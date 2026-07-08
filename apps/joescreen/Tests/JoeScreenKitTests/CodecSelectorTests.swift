import XCTest
@testable import JoeScreenKit

final class CodecSelectorTests: XCTestCase {

    func testSingleWindowStartsOnVP9() {
        let s = CodecSelector(windowCount: 1)
        XCTAssertEqual(s.current, .vp9)
    }

    func testMultiWindowStartsOnH264Structurally() {
        let s = CodecSelector(windowCount: 2)
        XCTAssertEqual(s.current, .h264)
    }

    func testWholeDisplayStartsOnH264() {
        let s = CodecSelector(windowCount: 1, wholeDisplay: true)
        XCTAssertEqual(s.current, .h264)
    }

    func testP95EncodeTripFallsBackOnce() {
        var s = CodecSelector(windowCount: 1)
        let t = s.evaluate(rollingP95EncodeSec: 0.030, sustainedFps: 30,
                           sustainedLowFpsSeconds: 0, framesChanging: true, thermal: .nominal)
        XCTAssertEqual(t, .init(to: .h264, trigger: .p95EncodeTooHigh, requiresRenegotiation: true))
        XCTAssertEqual(s.current, .h264)
        // Subsequent evaluations no longer transition (one-way).
        XCTAssertNil(s.evaluate(rollingP95EncodeSec: 0.001, sustainedFps: 60,
                                sustainedLowFpsSeconds: 0, framesChanging: true, thermal: .nominal))
        XCTAssertEqual(s.current, .h264, "no automatic return to VP9 within a session")
    }

    func testThermalSeriousFallsBack() {
        var s = CodecSelector(windowCount: 1)
        let t = s.evaluate(rollingP95EncodeSec: 0.001, sustainedFps: 60,
                           sustainedLowFpsSeconds: 0, framesChanging: true, thermal: .serious)
        XCTAssertEqual(t?.trigger, .thermalSerious)
    }

    func testCpuLimitedLowFpsRequiresSustainAndMotion() {
        var s = CodecSelector(windowCount: 1)
        // Low fps but not sustained long enough → no fallback.
        XCTAssertNil(s.evaluate(rollingP95EncodeSec: 0.001, sustainedFps: 10,
                                sustainedLowFpsSeconds: 3, framesChanging: true, thermal: .nominal))
        // Low fps but frames static (idle content) → not a codec problem → no fallback.
        XCTAssertNil(s.evaluate(rollingP95EncodeSec: 0.001, sustainedFps: 5,
                                sustainedLowFpsSeconds: 30, framesChanging: false, thermal: .nominal))
        // Sustained low fps WITH motion → fallback.
        let t = s.evaluate(rollingP95EncodeSec: 0.001, sustainedFps: 10,
                           sustainedLowFpsSeconds: 12, framesChanging: true, thermal: .nominal)
        XCTAssertEqual(t?.trigger, .cpuLimitedLowFps)
    }

    func testNoFallbackWhenHealthy() {
        var s = CodecSelector(windowCount: 1)
        XCTAssertNil(s.evaluate(rollingP95EncodeSec: 0.010, sustainedFps: 30,
                                sustainedLowFpsSeconds: 0, framesChanging: true, thermal: .fair))
        XCTAssertEqual(s.current, .vp9)
    }
}
