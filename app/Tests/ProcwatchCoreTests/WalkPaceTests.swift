import XCTest
@testable import ProcwatchCore

final class WalkPaceTests: XCTestCase {
    /// 구간표: p < 0.39 % → 2, 0.39–3.52 → 3, 3.52–9.77 → 4, 9.77–19.1 → 5, 19.1–31.6 → 6,
    /// 31.6–47.3 → 7, 47.3–66.0 → 8, 66.0–87.9 → 9, ≥ 87.9 → 10.
    func testBandsMatchTheTable() {
        let samples: [(Double, Int)] = [
            (0, 2), (0.38, 2), (0.40, 3), (3.5, 3), (3.6, 4), (9.7, 4), (9.8, 5),
            (19.0, 5), (19.2, 6), (31.5, 6), (31.7, 7), (47.2, 7), (47.4, 8),
            (65.9, 8), (66.1, 9), (87.8, 9), (88.0, 10), (100, 10), (350, 10),
        ]
        for (p, expected) in samples {
            XCTAssertEqual(WalkPace.fps(peakPercent: p, lowPower: false), expected, "p = \(p)")
        }
    }

    func testMeasuredLoadsWalkAtThreeToFour() {
        XCTAssertEqual(WalkPace.fps(peakPercent: 1, lowPower: false), 3)
        XCTAssertEqual(WalkPace.fps(peakPercent: 6, lowPower: false), 4)
    }

    func testLowPowerCapsAtFour() {
        XCTAssertEqual(WalkPace.fps(peakPercent: 100, lowPower: true), 4)
        XCTAssertEqual(WalkPace.fps(peakPercent: 1, lowPower: true), 3)
    }

    func testWalkingNeedsARateAndAClaudeAndAVisibleAwakeItem() {
        var conditions = WalkPace.Conditions(peakPercent: 1, rootCount: 1)
        XCTAssertTrue(conditions.walking)
        conditions.peakPercent = nil
        XCTAssertFalse(conditions.walking)
        conditions = WalkPace.Conditions(peakPercent: 1, rootCount: 0)
        XCTAssertFalse(conditions.walking)
        conditions = WalkPace.Conditions(peakPercent: 1, rootCount: 1)
        conditions.windowVisible = false
        XCTAssertFalse(conditions.walking)
        conditions.windowVisible = true
        conditions.screensAsleep = true
        XCTAssertFalse(conditions.walking)
    }

    func testNotPausedByDefault() {
        let conditions = WalkPace.Conditions(peakPercent: 1, rootCount: 1)
        XCTAssertFalse(conditions.userPaused)
        XCTAssertTrue(conditions.walking)
    }

    func testUserPauseStopsWalkingEvenWhenEverythingElseAllows() {
        var conditions = WalkPace.Conditions(peakPercent: 1, rootCount: 1)
        conditions.userPaused = true
        XCTAssertFalse(conditions.walking)
        conditions.userPaused = false
        XCTAssertTrue(conditions.walking)
    }
}
