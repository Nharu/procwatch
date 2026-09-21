import XCTest
@testable import ProcwatchCore

/// 판정기 한 식별자를 `(dt, rate)` 순수 입력으로 모는 시험 틀.
///
/// 시각 `t` 는 처음 본 뒤의 깨어 있는 초다. 첫 관측은 기준선만 잡으므로 첫 걸음이
/// `t = dt` 에 난다. 구간 `(t − dt, t]` 의 rate 가 그 걸음의 입력이다.
private struct JudgeSim {
    var judge = RunawayJudge(isClaude: false, judged: true)
    var params: JudgeParams
    var t = 0.0
    var events: [(t: Double, event: JudgeEvent)] = []
    var maxCredit = 0.0

    init(params: JudgeParams = .default) { self.params = params }

    mutating func step(rate: Double, dt: Double = 5) {
        t += dt
        if let event = judge.step(dt: dt, rate: rate, p: params) { events.append((t, event)) }
        maxCredit = max(maxCredit, judge.credit)
    }

    mutating func run(rate: Double, for seconds: Double, dt: Double = 5) {
        for _ in 0..<Int((seconds / dt).rounded()) { step(rate: rate, dt: dt) }
    }

    /// 구간 시작 시각으로 rate 를 고른다.
    mutating func run(until end: Double, dt: Double = 5, rate: (Double) -> Double) {
        while t + dt <= end + 1e-9 { step(rate: rate(t), dt: dt) }
    }

    /// 켜짐 `on` 초 / 꺼짐 `off` 초, 켜짐부터.
    static func duty(on: Double, off: Double, high: Double = 1.0, low: Double = 0.0) -> (Double) -> Double {
        { start in start.truncatingRemainder(dividingBy: on + off) < on ? high : low }
    }

    mutating func apply(_ newParams: JudgeParams) -> JudgeEvent? {
        params = newParams
        let event = judge.apply(newParams)
        if let event { events.append((t, event)) }
        return event
    }

    var trips: [Double] { events.compactMap { if case .tripped = $0.event { return $0.t } else { return nil } } }
    var clears: [Double] { events.compactMap { if case .cleared = $0.event { return $0.t } else { return nil } } }
    var banners: Int { events.filter { $0.event == .tripped(banner: true) }.count }
    var firstTrip: Double? { trips.first }
}

private let day = 86_400.0

final class RunawayJudgeTableTests: XCTestCase {
    func testJ1_fixedFiftyFiveTripsAt1800() {
        var sim = JudgeSim()
        sim.run(rate: 0.55, for: 3600)
        XCTAssertEqual(sim.firstTrip, 1800)
    }

    /// 비교가 `≥` 이므로 정확히 50 % 는 trip 한다.
    func testJ2_exactlyFiftyTripsAt1800() {
        var sim = JudgeSim()
        sim.run(rate: 0.50, for: 3600)
        XCTAssertEqual(sim.firstTrip, 1800)
    }

    func testJ3_fortyNineNeverTrips() {
        var sim = JudgeSim()
        sim.run(rate: 0.49, for: day)
        XCTAssertNil(sim.firstTrip)
    }

    /// 1 s 주기 50/50 듀티는 모든 5 s 구간 평균이 0.5 다.
    func testJ4_oneSecondDutyAveragesToHalfAndTrips() {
        var sim = JudgeSim()
        sim.run(rate: 0.5, for: 3600)
        XCTAssertEqual(sim.firstTrip, 1800)
    }

    /// 틱에 정렬된 5 s 켜짐 / 5 s 꺼짐은 잔물결 때문에 trip 하지 않는다.
    func testJ4b_tickAlignedFiveSecondDutyDoesNotTrip() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 5, off: 5))
        XCTAssertNil(sim.firstTrip)
        XCTAssertEqual(sim.maxCredit, 75)
    }

    func testJ5_tenMinuteHalfDutyDoesNotTrip() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 600, off: 600))
        XCTAssertNil(sim.firstTrip)
        XCTAssertEqual(sim.maxCredit, 620)
    }

    func testJ5b_oneMinuteHalfDutyDoesNotTrip() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 60, off: 60))
        XCTAssertNil(sim.firstTrip)
        XCTAssertEqual(sim.maxCredit, 85)
    }

    func testJ6_sixtyPercentDuty() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 720, off: 480))
        XCTAssertEqual(sim.firstTrip, 6600)
        XCTAssertEqual(sim.trips.count, 12)
        XCTAssertEqual(sim.banners, 1)
    }

    func testJ7_seventyFivePercentDuty() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 900, off: 300))
        XCTAssertEqual(sim.firstTrip, 3000)
        XCTAssertEqual(sim.trips.count, 24)
        XCTAssertEqual(sim.banners, 1)
    }

    func testJ18_twentyNineOnThreeOff() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 1740, off: 180))
        XCTAssertEqual(sim.firstTrip, 2160)
        XCTAssertEqual(sim.trips.count, 22)
        XCTAssertEqual(sim.banners, 1)
    }

    func testJ8a_twentyNineMinutesThenIdleNeverTrips() {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 1740)
        sim.run(rate: 0, for: 3600)
        XCTAssertNil(sim.firstTrip)
        XCTAssertEqual(sim.maxCredit, 1760)
    }

    func testJ8b_thirtyOneMinutesThenIdleTripsAndClears() {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 1860)
        sim.run(rate: 0, for: 3600)
        XCTAssertEqual(sim.firstTrip, 1800)
        XCTAssertEqual(sim.clears.first, 2005)
    }

    /// 단일 문턱 게이트 — 60 s 만 55 % 였다가 45 % 로 고정되면 trip 하지 않는다.
    func testJ9_briefExcursionThenFortyFive() {
        var sim = JudgeSim()
        sim.run(rate: 0.55, for: 60)
        sim.run(rate: 0.45, for: day)
        XCTAssertNil(sim.firstTrip)
        XCTAssertEqual(sim.maxCredit, 80)
    }

    func testJ9b_briefExcursionThenFortyTwo() {
        var sim = JudgeSim()
        sim.run(rate: 0.55, for: 60)
        sim.run(rate: 0.42, for: day)
        XCTAssertNil(sim.firstTrip)
        // 0.42 쪽으로는 R̄ 이 더 빨리 내려가 60 s 뒤 게이트가 두 틱만 더 열린다(0.530, 0.513).
        // 최댓값 80 은 0.45 입력(네 틱)의 값이다.
        XCTAssertEqual(sim.maxCredit, 70)
    }

    /// 잠자기를 걸친 구간은 양쪽 깨어 있는 초에 대한 정확한 평균이다 — 깨어 있는 `dt`
    /// 만큼만 움직이고 아무것도 리셋하지 않는다.
    func testJ10_sleepSpanningIntervalCountsOnlyAwakeSeconds() {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 1200)
        sim.step(rate: 1.0, dt: 5)          // 8 h 잠자기를 걸친 구간 — 깨어 있는 5 s
        sim.run(rate: 1.0, for: 1200)
        XCTAssertEqual(sim.firstTrip, 1800, "깨어 있는 1800 s 에 trip")
    }

    func testJ10b_calmAfterWakeClearsAt145() {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 3000)
        XCTAssertEqual(sim.firstTrip, 1800)
        let wake = sim.t
        sim.step(rate: 0, dt: 5)            // 잠자기를 걸친 구간
        sim.run(rate: 0, for: 600)
        XCTAssertEqual(sim.clears.first.map { $0 - wake }, 145)
    }

    /// 구간당 상한이 없다 — 600 s 구간 하나가 credit 을 600 만큼 움직인다.
    func testJ11_longIntervalMovesCreditByItsWholeLength() {
        var sim = JudgeSim()
        sim.run(rate: 0, for: 60)
        let before = sim.judge.credit
        sim.step(rate: 1.0, dt: 600)
        XCTAssertEqual(sim.judge.credit - before, 600, accuracy: 1e-9)
    }

    func testT1_threeHundredSecondSamplesTripAt1800() {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 3600, dt: 300)
        XCTAssertEqual(sim.firstTrip, 1800)
    }

    func testJ19_longRunawayWithShallowRestsIsOneEpisode() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 3600, off: 1500, high: 1.0, low: 0.45))
        XCTAssertEqual(sim.trips.count, 1)
        XCTAssertEqual(sim.banners, 1)
    }

    func testJ20_sixtyAndFortyFiveBlocks() {
        var sim = JudgeSim()
        sim.run(until: day, rate: JudgeSim.duty(on: 1800, off: 1200, high: 0.60, low: 0.45))
        XCTAssertEqual(sim.trips.count, 2)
        let gaps = zip(sim.clears, sim.trips.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(gaps.min(), 1395)
    }
}

final class RunawayJudgeClearingTests: XCTestCase {
    /// 폭주가 cap 까지 쌓인 상태에서 시작한다.
    private func saturatedRunaway() -> JudgeSim {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 3000)
        XCTAssertTrue(sim.judge.runaway)
        XCTAssertEqual(sim.judge.credit, JudgeParams.default.cap)
        return sim
    }

    func testJ16_idleAfterRunawayClearsAt145() {
        var sim = saturatedRunaway()
        let start = sim.t
        sim.run(rate: 0, for: 600)
        XCTAssertEqual(sim.clears.first.map { $0 - start }, 145)
        XCTAssertEqual(sim.events.last?.event, .cleared(.calm))
        XCTAssertEqual(sim.judge.credit, 0)
    }

    /// 40–50 % 로 가라앉은 폭주는 진정이 아니라 상환으로 풀린다.
    func testJ17_fortyFiveAfterRunawayRepaysAt1875() {
        var sim = saturatedRunaway()
        let start = sim.t
        sim.run(rate: 0.45, for: 3600)
        XCTAssertEqual(sim.clears.first.map { $0 - start }, 1875)
        XCTAssertEqual(sim.events.last?.event, .cleared(.repaid))
    }

    func testJ17b_thirtyAfterRunawayClearsAt175() {
        var sim = saturatedRunaway()
        let start = sim.t
        sim.run(rate: 0.30, for: 600)
        XCTAssertEqual(sim.clears.first.map { $0 - start }, 175)
    }
}

final class RunawayJudgeEditTests: XCTestCase {
    private func params(percent: Int, minutes: Int = 30) -> JudgeParams {
        JudgeParams(settings: ThresholdSettings(cpuThresholdPercent: percent, sustainMinutes: minutes))
    }

    /// 무장 중인 credit 은 초기화하지 않고, 새 기준 아래에서 갚아 나간다.
    func testJ12_raisingThresholdWhileArmedDrainsCredit() {
        var sim = JudgeSim()
        sim.run(rate: 0.6, for: 995)
        XCTAssertEqual(sim.judge.credit, 995)
        XCTAssertNil(sim.apply(params(percent: 70)))
        XCTAssertEqual(sim.judge.credit, 995)
        let edit = sim.t
        while sim.judge.credit > 0 { sim.step(rate: 0.6) }
        XCTAssertEqual(sim.t - edit, 995)
    }

    func testJ12b_raisingThresholdDuringRunawayClearsImmediately() {
        var sim = JudgeSim()
        sim.run(rate: 0.6, for: 1800)
        XCTAssertTrue(sim.judge.runaway)
        XCTAssertEqual(sim.apply(params(percent: 70)), .cleared(.edited))
        XCTAssertFalse(sim.judge.runaway)
        XCTAssertNil(sim.judge.runawaySince)
    }

    func testJ12c_restoringThresholdRetripsWithoutASecondBanner() {
        var sim = JudgeSim()
        sim.run(rate: 0.6, for: 1800)
        _ = sim.apply(params(percent: 70))
        sim.run(rate: 0.6, for: 60)
        XCTAssertNil(sim.apply(params(percent: 50)))

        sim.step(rate: 0.6)
        XCTAssertFalse(sim.judge.runaway, "다음 틱에는 빨강 아님")
        XCTAssertEqual(sim.judge.credit, 1745)

        let restore = sim.t - 5
        sim.run(rate: 0.6, for: 600)
        XCTAssertEqual(sim.trips.dropFirst().first.map { $0 - restore }, 60)
        XCTAssertEqual(sim.banners, 1, "두 번째 배너 없음")
    }

    /// 임계를 낮춰도 지나간 시간에 소급해 credit 을 주지 않는다.
    func testJ13_loweringThresholdDoesNotBackdateCredit() {
        var sim = JudgeSim()
        sim.run(rate: 0.4, for: 600)
        XCTAssertEqual(sim.judge.credit, 0)
        XCTAssertNil(sim.apply(params(percent: 30)))
        let edit = sim.t
        sim.run(rate: 0.4, for: 3600)
        XCTAssertEqual(sim.firstTrip.map { $0 - edit }, 1800)
    }

    /// 편집은 trip 시키지 않는다 — trip 은 그다음 틱의 `step` 에서 나고 배너도 거기서 난다.
    func testJ14_shorteningDurationTripsOnTheNextTick() {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 720)
        XCTAssertNil(sim.apply(params(percent: 50, minutes: 10)))
        XCTAssertFalse(sim.judge.runaway)
        sim.step(rate: 1.0)
        XCTAssertEqual(sim.events.last?.event, .tripped(banner: true))
    }

    func testJ15_raisingDurationDuringRunawayRetripsWithoutASecondBanner() {
        var sim = JudgeSim()
        sim.run(rate: 1.0, for: 1800)
        XCTAssertEqual(sim.apply(params(percent: 50, minutes: 45)), .cleared(.edited))
        let edit = sim.t
        sim.run(rate: 1.0, for: 1800)
        XCTAssertEqual(sim.trips.dropFirst().first.map { $0 - edit }, 900)
        XCTAssertEqual(sim.banners, 1)
    }
}

final class RunawayJudgeLifecycleTests: XCTestCase {
    /// 최상위 claude 는 rate 만 추적하고 판정하지 않는다.
    func testTopLevelClaudeOnlyTracksRate() {
        var judge = RunawayJudge(isClaude: true, judged: false)
        for _ in 0..<1000 {
            XCTAssertNil(judge.step(dt: 5, rate: 1.0, p: .default))
        }
        XCTAssertEqual(judge.rBar ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(judge.credit, 0)
        XCTAssertFalse(judge.runaway)
    }

    func testRunawaySinceIsSetOnTripAndClearedOnFall() {
        var judge = RunawayJudge(isClaude: false, judged: true)
        let when = Date(timeIntervalSince1970: 1_000)
        var event: JudgeEvent?
        while event == nil { event = judge.step(dt: 5, rate: 1.0, p: .default, now: when) }
        XCTAssertEqual(judge.runawaySince, when)
        for _ in 0..<100 { _ = judge.step(dt: 5, rate: 0, p: .default) }
        XCTAssertNil(judge.runawaySince)
    }
}

final class ThresholdSettingsTests: XCTestCase {
    func testDefaultsAreFiftyPercentAndThirtyMinutes() {
        XCTAssertEqual(JudgeParams.default.tHi, 0.5)
        XCTAssertEqual(JudgeParams.default.d, 1800)
        XCTAssertEqual(JudgeParams.default.tLo, 0.4, accuracy: 1e-12)
        XCTAssertEqual(JudgeParams.default.cap, 2700)
        XCTAssertEqual(JudgeParams.default.release, 900)
    }

    func testValuesAreClampedWhenRead() {
        let suite = "procwatch-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ThresholdSettings(defaults: defaults), .default)
        defaults.set(2, forKey: ThresholdSettings.Key.cpuThresholdPercent)
        defaults.set(99_999, forKey: ThresholdSettings.Key.sustainMinutes)
        XCTAssertEqual(ThresholdSettings(defaults: defaults),
                       ThresholdSettings(cpuThresholdPercent: 5, sustainMinutes: 1440))
    }

    func testThresholdArgument() {
        XCTAssertEqual(ThresholdSettings(argument: "5:1"),
                       ThresholdSettings(cpuThresholdPercent: 5, sustainMinutes: 1))
        XCTAssertNil(ThresholdSettings(argument: "5"))
        XCTAssertNil(ThresholdSettings(argument: "4:1"))
        XCTAssertNil(ThresholdSettings(argument: "50:0"))
        XCTAssertNil(ThresholdSettings(argument: "a:b"))
        let params = JudgeParams(settings: ThresholdSettings(argument: "5:1")!)
        XCTAssertEqual(params.tHi, 0.05, accuracy: 1e-12)
        XCTAssertEqual(params.d, 60)
    }
}
