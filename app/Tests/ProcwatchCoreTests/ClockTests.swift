import XCTest
@testable import ProcwatchCore

/// U1 — rate 식에는 timebase 가 들어가지 않는다.
final class CPURateTests: XCTestCase {
    func testU1_rateIsExactlyOneWhenCPUTicksMatchWallTicks() {
        // 두 timebase 를 나란히 놓는 이유는, rate 가 그 둘을 구별하지 않는다는 것이
        // 이 식의 성질이기 때문이다. 시계는 dtSec 에만 들어간다.
        let identity = FakeClock(numer: 1, denom: 1)
        let thisMachine = FakeClock(numer: 125, denom: 3)
        XCTAssertNotEqual(identity.secondsPerTick, thisMachine.secondsPerTick)

        for delta in [UInt64(1), 1_000, 120_000_000] {
            let rate = CPURate.rate(deltaCPUTicks: delta, deltaAbsoluteTicks: delta)
            XCTAssertEqual(rate, 1.0)
        }
    }

    func testRateIsNilWithoutAnInterval() {
        XCTAssertNil(CPURate.rate(deltaCPUTicks: 42, deltaAbsoluteTicks: 0))
    }
}

/// U2 — 이음매 한 곳이 mach tick 을 초로 바꾼다.
final class MonotonicClockTests: XCTestCase {
    func testU2_oneHundredTwentyMillionTicksIsFiveSecondsOnThisTimebase() {
        let clock = FakeClock(numer: 125, denom: 3)
        let start = clock.now()
        clock.advance(ticks: 120_000_000)
        XCTAssertEqual(clock.seconds(from: start, to: clock.now()), 5.0, accuracy: 1e-9)
    }

    func testSecondsIsZeroWhenTheClockDidNotMove() {
        let clock = FakeClock(numer: 125, denom: 3, start: 7)
        XCTAssertEqual(clock.seconds(from: 7, to: 7), 0)
    }
}

/// U3 — 시작 시 시계 자체 점검.
final class ClockSelfCheckTests: XCTestCase {
    /// (a) tick 을 나노초로 읽은 비율(1/41.67)이 연속 3 구간이면 켜진다.
    func testU3a_threeConsecutiveOffScaleIntervalsTripTheCheck() {
        var check = ClockSelfCheck()
        let wall = 5.0
        let mistaken = wall / (125.0 / 3.0)   // tick 을 ns 로 읽었을 때의 dtSec

        check.observe(dtSec: mistaken, wallSec: wall)
        XCTAssertFalse(check.isSuspect)
        check.observe(dtSec: mistaken, wallSec: wall)
        XCTAssertFalse(check.isSuspect)
        check.observe(dtSec: mistaken, wallSec: wall)
        XCTAssertTrue(check.isSuspect)
    }

    /// (b) 올바른 구간 사이에 낀 잠자기 구간 하나(벽시계 8 h, 깨어 있는 5 s)는 켜지 않는다.
    func testU3b_oneSleepSpanningIntervalDoesNotTripTheCheck() {
        var check = ClockSelfCheck()
        check.observe(dtSec: 5.0, wallSec: 5.0)
        check.observe(dtSec: 5.0, wallSec: 8 * 3600)   // 잠자기를 걸친 구간
        XCTAssertFalse(check.isSuspect)
        check.observe(dtSec: 5.0, wallSec: 5.0)
        check.observe(dtSec: 5.0, wallSec: 5.0)
        XCTAssertFalse(check.isSuspect)
    }

    /// (c) 올바른 125/3 은 10 구간을 넘겨도 꺼진 채다.
    func testU3c_correctTimebaseStaysOffPastTheSampleLimit() {
        var check = ClockSelfCheck()
        for _ in 0..<20 {
            check.observe(dtSec: 5.0, wallSec: 5.0)
        }
        XCTAssertFalse(check.isSuspect)
    }

    /// 1 s 미만 구간은 표본에 들어가지 않는다.
    func testShortIntervalsAreNotSampled() {
        var check = ClockSelfCheck()
        for _ in 0..<10 {
            check.observe(dtSec: 0.5 / (125.0 / 3.0), wallSec: 0.5)
        }
        XCTAssertFalse(check.isSuspect)
    }
}
