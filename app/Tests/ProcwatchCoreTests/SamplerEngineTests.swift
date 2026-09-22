import Darwin
import Foundation
import XCTest
@testable import ProcwatchCore

/// 손으로 움직이는 프로세스 테이블. 누적 CPU 는 부하(rate)에서 시계와 함께 자란다.
final class FakeProcessSource: ProcessSource, @unchecked Sendable {
    let ownUID: uid_t = 501

    private(set) var rows: [ProcessRow] = []
    var argv: [pid_t: String] = [:]
    /// argv 읽기가 실패하는 pid.
    var argvFailures: Set<pid_t> = []
    /// 누적 CPU(ns — 시험 시계의 timebase 가 1/1 이다).
    var counters: [pid_t: UInt64] = [:]
    /// `cpuTicks` 가 nil 을 내는 pid. 카운터는 뒤에서 계속 자란다.
    var hidden: Set<pid_t> = []
    var load: [pid_t: Double] = [:]
    /// 참이면 `table()` 이 던진다.
    var failTable = false

    private(set) var tableCalls = 0
    private(set) var argvCalls: [pid_t: Int] = [:]

    func table() throws -> ProcessTable {
        tableCalls += 1
        if failTable { throw ProcessSourceError.retriesExhausted }
        return ProcessTable(rows: rows)
    }

    func argv0BaseName(pid: pid_t) -> String? {
        argvCalls[pid, default: 0] += 1
        return argvFailures.contains(pid) ? nil : argv[pid]
    }

    func cpuTicks(pid: pid_t) -> UInt64? {
        hidden.contains(pid) ? nil : counters[pid]
    }

    @discardableResult
    func spawn(_ pid: pid_t, parent: pid_t, name: String, start: Int64, uid: uid_t = 501, rate: Double = 0) -> ProcIdentity {
        let identity = ProcIdentity(pid: pid, startSec: start, startUsec: 0)
        rows.removeAll { $0.pid == pid }
        rows.append(ProcessRow(identity: identity, ppid: parent, ruid: uid, comm: name))
        argv[pid] = name
        counters[pid] = 0
        load[pid] = rate
        return identity
    }

    func kill(_ pid: pid_t) {
        rows.removeAll { $0.pid == pid }
        counters[pid] = nil
        load[pid] = nil
    }

    func reparent(_ pid: pid_t, to parent: pid_t) {
        guard let index = rows.firstIndex(where: { $0.pid == pid }) else { return }
        let row = rows[index]
        rows[index] = ProcessRow(identity: row.identity, ppid: parent, ruid: row.ruid, comm: row.comm)
    }

    func accrue(seconds: Double) {
        for (pid, rate) in load where counters[pid] != nil {
            counters[pid]! += UInt64((rate * seconds * 1e9).rounded())
        }
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

/// 스트림을 소비하는 태스크가 받은 첫 스냅숏을 시험 쪽으로 건네는 상자.
actor SnapshotBox {
    private(set) var value: WatchSnapshot?

    func store(_ snapshot: WatchSnapshot) {
        if value == nil { value = snapshot }
    }
}

/// `FakeProcessSource` + `FakeClock` + `tick()` 직접 호출.
struct EngineHarness {
    let source = FakeProcessSource()
    let clock = FakeClock(numer: 1, denom: 1, start: 1_000_000_000)
    let engine: SamplerEngine

    /// D = 60 s 이면 1.0 부하가 워밍 한 틱 뒤 열두 걸음(60 s)에 trip 한다.
    static let quick = JudgeParams(tHi: 0.5, d: 60)

    init(params: JudgeParams = EngineHarness.quick) {
        engine = SamplerEngine(source: source, clock: clock, params: params)
    }

    /// 시계를 민 뒤 한 틱. 테이블 읽기가 실패한 틱이면 nil.
    @discardableResult
    func step(seconds: Double = 5) async -> WatchSnapshot? {
        source.accrue(seconds: seconds)
        clock.advance(ticks: UInt64(seconds * 1e9))
        return await engine.tick()
    }

    /// 게시가 있어야 하는 틱.
    @discardableResult
    func published(seconds: Double = 5) async throws -> WatchSnapshot {
        guard let snapshot = await step(seconds: seconds) else {
            throw HarnessError(description: "게시가 없었다")
        }
        return snapshot
    }

    /// 시계를 밀지 않는 첫 틱.
    @discardableResult
    func first() async throws -> WatchSnapshot {
        guard let snapshot = await engine.tick() else { throw HarnessError(description: "첫 틱 게시 없음") }
        return snapshot
    }

    /// n 틱을 돌고 게시된 스냅숏을 모은다.
    @discardableResult
    func steps(_ count: Int, seconds: Double = 5) async -> [WatchSnapshot] {
        var result: [WatchSnapshot] = []
        for _ in 0..<count {
            if let snapshot = await step(seconds: seconds) { result.append(snapshot) }
        }
        return result
    }

    func state(_ identity: ProcIdentity) async throws -> SamplerCore.Inspection {
        guard let inspection = await engine.inspect(identity) else {
            throw HarnessError(description: "\(identity) 의 상태가 없다")
        }
        return inspection
    }
}

final class SamplerEngineTests: XCTestCase {
    private let claudeStart: Int64 = 100

    /// launchd(1) → claude(10) → zsh(30) → python3(40)
    private func basicTree(_ h: EngineHarness, childRate: Double) -> ProcIdentity {
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        h.source.spawn(10, parent: 1, name: "claude", start: claudeStart, rate: 0.02)
        h.source.spawn(30, parent: 10, name: "zsh", start: 200)
        return h.source.spawn(40, parent: 30, name: "python3", start: 300, rate: childRate)
    }

    /// 폭주 상태까지 민다. 첫 틱은 워밍, 그 뒤 열두 걸음.
    @discardableResult
    private func driveToRunaway(_ h: EngineHarness) async throws -> [WatchSnapshot] {
        try await h.first()
        return await h.steps(12)
    }

    // MARK: - E5

    func testE5_nestedClaudeAndUgrepChildAreJudgedButTheTopLevelIsNot() async throws {
        let h = EngineHarness()
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        let top = h.source.spawn(10, parent: 1, name: "claude", start: 100, rate: 0.02)
        let nested = h.source.spawn(20, parent: 10, name: "claude", start: 110, rate: 0.04)
        let zsh = h.source.spawn(30, parent: 20, name: "zsh", start: 120)
        let python = h.source.spawn(40, parent: 30, name: "python3", start: 130)
        let ugrep = h.source.spawn(50, parent: 10, name: "ugrep", start: 140)

        try await h.first()
        try await h.published()
        let snapshot = try await h.published()

        XCTAssertEqual(snapshot.rootCount, 2)
        XCTAssertEqual(snapshot.trackedCount, 4)
        for identity in [nested, zsh, python, ugrep] {
            let judged = try await h.state(identity).judged
            XCTAssertTrue(judged, "\(identity)")
        }
        let topJudged = try await h.state(top).judged
        XCTAssertFalse(topJudged)

        // 걸음 입력은 두 claude 의 최댓값이다.
        let peak = try XCTUnwrap(snapshot.rootPeakPercent)
        XCTAssertEqual(peak, 4, accuracy: 1e-6)
        XCTAssertEqual(snapshot.rootSumPercent, 6, accuracy: 1e-6)
    }

    // MARK: - E1 / E2 / E2b

    func testE1_samePIDWithANewStartIsANewIdentityWithoutInheritedState() async throws {
        let h = EngineHarness()
        let old = basicTree(h, childRate: 1.0)
        try await h.first()
        await h.steps(3)
        let oldCredit = try await h.state(old).credit
        XCTAssertEqual(oldCredit, 15)

        let replacement = h.source.spawn(40, parent: 30, name: "python3", start: 900, rate: 1.0)
        try await h.published()

        let oldGone = await h.engine.inspect(old)
        XCTAssertNil(oldGone)
        let fresh = try await h.state(replacement)
        XCTAssertNil(fresh.rBar, "새 식별자는 워밍부터다")
        XCTAssertEqual(fresh.credit, 0)
        XCTAssertEqual(fresh.steps, 0)
    }

    func testE2_identityBreakDropsNotifiedAndClearsARunaway() async throws {
        let h = EngineHarness()
        let old = basicTree(h, childRate: 1.0)
        let snapshots = try await driveToRunaway(h)
        XCTAssertEqual(snapshots.last?.tripped.map(\.identity), [old])
        XCTAssertEqual(snapshots.last?.runawayTotal, 1)

        let replacement = h.source.spawn(40, parent: 30, name: "python3", start: 900, rate: 1.0)
        let broken = try await h.published()
        XCTAssertEqual(broken.cleared, [old], "버리기 전 폭주였으면 그 틱의 cleared 에 든다")
        XCTAssertEqual(broken.runawayTotal, 0)
        XCTAssertEqual(broken.warmingCount, 1)
        let freshNotified = try await h.state(replacement).notified
        XCTAssertFalse(freshNotified)

        // 새 식별자는 다시 배너를 받을 수 있다.
        let later = await h.steps(12)
        XCTAssertEqual(later.flatMap(\.tripped).map(\.identity), [replacement])
    }

    func testE2b_counterDropWithTheSameStartKeepsNotifiedAndRaisesNoEdge() async throws {
        let h = EngineHarness()
        let child = basicTree(h, childRate: 1.0)
        try await driveToRunaway(h)
        let before = try await h.state(child)
        XCTAssertTrue(before.runaway)
        XCTAssertTrue(before.notified)

        h.source.counters[40] = 0                      // 같은 start 시각, 누적 카운터만 줄었다
        let rebased = try await h.published()
        XCTAssertEqual(rebased.cleared, [])
        XCTAssertEqual(rebased.tripped, [])
        let after = try await h.state(child)
        XCTAssertTrue(after.runaway)
        XCTAssertTrue(after.notified)
        XCTAssertEqual(after.credit, before.credit, "표본 하나만 버리고 판정 상태는 그대로")
        XCTAssertEqual(after.steps, before.steps)

        // 다음 틱에는 정상 걸음으로 돌아온다.
        try await h.published()
        let resumed = try await h.state(child)
        XCTAssertEqual(resumed.steps, before.steps + 1)
        XCTAssertEqual(resumed.credit, before.credit + 5)

        // 같은 살아 있는 프로세스는 두 번째 배너를 받지 않는다.
        let rest = await h.steps(40)
        XCTAssertEqual(rest.flatMap(\.tripped), [])
    }

    // MARK: - E3

    func testE3_tenThousandShortLivedIdentitiesDoNotGrowTheState() async throws {
        let h = EngineHarness()
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        h.source.spawn(10, parent: 1, name: "claude", start: claudeStart)
        try await h.first()

        var nextPID: pid_t = 1000
        var start: Int64 = 1000
        var alive: [pid_t] = []
        var maxTracked = 0
        var maxCache = 0
        for _ in 0..<100 {
            alive.forEach(h.source.kill)
            alive = []
            for _ in 0..<100 {
                h.source.spawn(nextPID, parent: 10, name: "sh", start: start)
                alive.append(nextPID)
                nextPID += 1
                start += 1
            }
            try await h.published()
            let tracked = await h.engine.trackedIdentities.count
            let cache = await h.engine.classifierCacheCount
            maxTracked = max(maxTracked, tracked)
            maxCache = max(maxCache, cache)
        }
        XCTAssertEqual(nextPID - 1000, 10_000)
        XCTAssertLessThanOrEqual(maxTracked, 101)
        XCTAssertLessThanOrEqual(maxCache, 102)
    }

    // MARK: - E4

    func testE4_orphanAdoptedByLaunchdStaysJudgedWithItsState() async throws {
        let h = EngineHarness()
        let child = basicTree(h, childRate: 1.0)
        try await h.first()
        await h.steps(4)
        let before = try await h.state(child)

        h.source.kill(10)
        h.source.kill(30)
        h.source.reparent(40, to: 1)
        let snapshot = try await h.published()

        let after = try await h.state(child)
        XCTAssertTrue(after.judged)
        XCTAssertEqual(after.credit, before.credit + 5, "입양은 판정 상태를 건드리지 않는다")
        XCTAssertEqual(snapshot.rootCount, 0)
        XCTAssertEqual(snapshot.trackedCount, 1)
    }

    // MARK: - E6

    func testE6_unmeasurableRowIsKeptAndRecoversWithOneLongStep() async throws {
        let h = EngineHarness()
        let child = basicTree(h, childRate: 1.0)
        try await h.first()
        await h.steps(3)
        let before = try await h.state(child)

        h.source.hidden.insert(40)
        for _ in 0..<3 {
            let snapshot = try await h.published()
            XCTAssertEqual(snapshot.unmeasurableCount, 1)
            let during = try await h.state(child)          // 퇴거되지 않는다
            XCTAssertEqual(during.steps, before.steps, "걸음 없음")
        }

        h.source.hidden.remove(40)
        let recovered = try await h.published()
        XCTAssertEqual(recovered.unmeasurableCount, 0)
        let after = try await h.state(child)
        XCTAssertEqual(after.steps, before.steps + 1, "dt = 20 한 걸음")
        XCTAssertEqual(after.credit, before.credit + 20, accuracy: 1e-9)
    }

    func testRunawayRowThatBecomesUnmeasurableStaysRed() async throws {
        let h = EngineHarness()
        _ = basicTree(h, childRate: 1.0)
        try await driveToRunaway(h)
        h.source.hidden.insert(40)
        let snapshot = try await h.published()
        XCTAssertEqual(snapshot.runawayTotal, 1)
        XCTAssertEqual(snapshot.runaway.first?.state, .unmeasurable)
        XCTAssertNil(snapshot.runaway.first?.ratePercent)
    }

    // MARK: - E7

    func testE7_idleIntervalOnlyWhenTheTrackedSetIsEmpty() async throws {
        let h = EngineHarness()
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        h.source.spawn(2, parent: 1, name: "zsh", start: 50)
        try await h.first()
        let idle = await h.engine.nextInterval
        XCTAssertEqual(idle, 30)

        h.source.spawn(10, parent: 1, name: "claude", start: claudeStart)
        h.source.spawn(40, parent: 10, name: "python3", start: 300)
        try await h.published()
        let active = await h.engine.nextInterval
        XCTAssertEqual(active, 5)

        // claude 가 끝나고 sticky 고아만 남아도 추적 집합은 비지 않았다.
        h.source.kill(10)
        h.source.reparent(40, to: 1)
        let orphanOnly = try await h.published()
        XCTAssertEqual(orphanOnly.rootCount, 0)
        let orphanInterval = await h.engine.nextInterval
        XCTAssertEqual(orphanInterval, 5)

        h.source.kill(40)
        try await h.published()
        let emptyAgain = await h.engine.nextInterval
        XCTAssertEqual(emptyAgain, 30)
    }

    // MARK: - E8

    func testE8_warmingIdentityIsNeitherRedNorWalkInput() async throws {
        let h = EngineHarness()
        _ = basicTree(h, childRate: 1.0)
        let first = try await h.first()
        XCTAssertNil(first.rootPeakPercent, "rate 가 생기기 전에는 걸음 입력이 없다")
        XCTAssertEqual(first.warmingCount, 2)
        XCTAssertEqual(first.runawayTotal, 0)
        XCTAssertEqual(first.runaway, [])

        let second = try await h.published()
        XCTAssertNotNil(second.rootPeakPercent)
        XCTAssertEqual(second.warmingCount, 0)
    }

    // MARK: - E9

    func testE9_applyPublishesWithoutSamplingAndClearsFromTheJudgeReturnValue() async throws {
        let h = EngineHarness()
        let child = basicTree(h, childRate: 0.6)
        try await driveToRunaway(h)
        let red = try await h.state(child)
        XCTAssertTrue(red.runaway)

        let callsBefore = h.source.tableCalls
        let edited = await h.engine.apply(JudgeParams(tHi: 0.7, d: 60))
        XCTAssertEqual(h.source.tableCalls, callsBefore, "apply 는 source.table() 을 부르지 않는다")
        XCTAssertEqual(edited.cleared, [child])
        XCTAssertEqual(edited.runawayTotal, 0)
        XCTAssertEqual(edited.tripped, [])

        // 스트림에도 게시됐다. 앞 틱들의 스냅숏이 먼저 쌓여 있으므로 그 seq 까지 읽는다.
        var iterator = h.engine.snapshots.makeAsyncIterator()
        var last: WatchSnapshot?
        while let next = await iterator.next() {
            last = next
            if next.seq == edited.seq { break }
        }
        XCTAssertEqual(last?.seq, edited.seq)
        XCTAssertEqual(last?.cleared, [child])
    }

    // MARK: - E10

    func testE10_runawayThatLeavesTheTableIsClearedAndEvicted() async throws {
        let h = EngineHarness()
        let child = basicTree(h, childRate: 1.0)
        try await driveToRunaway(h)

        h.source.kill(40)
        let snapshot = try await h.published()
        XCTAssertEqual(snapshot.cleared, [child])
        XCTAssertEqual(snapshot.runawayTotal, 0)
        let gone = await h.engine.inspect(child)
        XCTAssertNil(gone)
    }

    // MARK: - E11

    func testE11_threeArgvFailuresSettleAsNotRootAndAreNeverRetried() async throws {
        let h = EngineHarness()
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        let stubborn = h.source.spawn(77, parent: 1, name: "claude", start: 500)
        h.source.argvFailures.insert(77)

        try await h.first()
        await h.steps(2)
        let settled = await h.engine.settledVerdict(for: stubborn)
        XCTAssertEqual(settled, false)
        XCTAssertEqual(h.source.argvCalls[77], 3)

        // 읽기가 돌아와도 그 정체성이 끝날 때까지 다시 분류하지 않는다.
        h.source.argvFailures.remove(77)
        let later = await h.steps(10)
        XCTAssertEqual(h.source.argvCalls[77], 3)
        XCTAssertEqual(later.last?.rootCount, 0)
    }

    // MARK: - E12

    func testE12_failedTableSkipsTheWholeTickAndKeepsState() async throws {
        let h = EngineHarness()
        let child = basicTree(h, childRate: 1.0)
        try await driveToRunaway(h)
        let before = try await h.state(child)
        XCTAssertTrue(before.runaway)

        h.source.failTable = true
        let skipped = await h.step()
        XCTAssertNil(skipped, "게시하지 않는다")
        let during = try await h.state(child)
        XCTAssertEqual(during.credit, before.credit)
        XCTAssertEqual(during.steps, before.steps)

        h.source.failTable = false
        let resumed = try await h.published()
        XCTAssertEqual(resumed.cleared, [])
        XCTAssertEqual(resumed.tripped, [])
        let after = try await h.state(child)
        XCTAssertTrue(after.runaway)
        XCTAssertTrue(after.notified)
        XCTAssertEqual(after.steps, before.steps + 1, "두 주기를 걸친 Δt 한 걸음")
        XCTAssertEqual(after.credit, before.credit + 10, accuracy: 1e-9)
    }

    // MARK: - 생산 샘플링 경로

    /// 다른 시험은 전부 `tick()` 을 직접 부르므로, `start()` 가 거는 타이머의 이벤트
    /// 핸들러 — Swift task 가 아닌 순수 GCD 블록에서 `assumeIsolated` 로 틱을 동기
    /// 실행하는 유일한 생산 경로 — 는 어느 시험도 지나지 않았다. 그 블록에서 격리 검사가
    /// 거짓을 답하면 `assumeIsolated` 가 그것을 치명적 오류로 바꾸어 첫 틱에서 죽으므로,
    /// 이 시험은 첫 스냅숏이 도착하는 것 자체로 그 트랩이 없음을 덮는다.
    func testStart_firstTickRunsThroughThePureGCDTimerHandler() async throws {
        let h = EngineHarness()
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        h.source.spawn(10, parent: 1, name: "claude", start: claudeStart, rate: 0.02)
        h.source.spawn(40, parent: 10, name: "python3", start: 300, rate: 1.0)

        let engine = h.engine
        let box = SnapshotBox()
        let arrived = expectation(description: "첫 스냅숏이 생산 타이머 경로로 도착한다")
        Task {
            for await snapshot in engine.snapshots {
                await box.store(snapshot)
                arrived.fulfill()
                break
            }
        }

        await engine.start()

        // 대기에 상한이 없으면 타이머가 영영 발화하지 않을 때 시험이 실패 대신 멈춘다.
        await fulfillment(of: [arrived], timeout: 5)

        let received = await box.value
        let first = try XCTUnwrap(received)
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(first.rootCount, 1)
        XCTAssertEqual(first.trackedCount, 1, "claude 자신은 판정 대상이 아니고 자식 하나만 J 에 든다")

        // 첫 틱이 추적 집합을 비지 않은 것으로 보았으므로 주기가 30 에서 5 로 바뀐다.
        let interval = await engine.timerInterval
        XCTAssertEqual(interval, 5)
    }

    // MARK: - 스냅숏 조립

    func testSnapshotRowsCarryDisplayLimitsAndAncestry() async throws {
        let h = EngineHarness()
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        h.source.spawn(10, parent: 1, name: "claude", start: claudeStart)
        var parent: pid_t = 10
        for depth in 0..<5 {
            h.source.spawn(pid_t(100 + depth), parent: parent, name: "sh\(depth)", start: Int64(200 + depth))
            parent = pid_t(100 + depth)
        }
        let longName = String(repeating: "x", count: 200) + "\n\u{7}"
        h.source.spawn(900, parent: parent, name: longName, start: 900, rate: 1.0)

        try await h.first()
        let snapshots = await h.steps(12)
        let row = try XCTUnwrap(snapshots.last?.tripped.first)
        XCTAssertEqual(row.name.count, DisplayText.nameLimit)
        XCTAssertFalse(row.name.contains("\n"))
        XCTAssertEqual(row.ancestry, ["claude 10", "…", "sh4", row.name])
        XCTAssertEqual(row.state, .measured)
        let rate = try XCTUnwrap(row.ratePercent)
        XCTAssertEqual(rate, 100, accuracy: 1e-6)
        XCTAssertNotNil(row.runawaySince)
    }

    func testTopWatchedIsCreditOrderedAndExcludesRunaways() async throws {
        let h = EngineHarness()
        h.source.spawn(1, parent: 0, name: "launchd", start: 1, uid: 0)
        h.source.spawn(10, parent: 1, name: "claude", start: claudeStart)
        let hot = h.source.spawn(20, parent: 10, name: "hot", start: 200, rate: 1.0)
        let idle = h.source.spawn(30, parent: 10, name: "idle", start: 210, rate: 0.0)
        try await h.first()
        await h.steps(3)
        let mid = try await h.published()
        XCTAssertEqual(mid.topWatched.map(\.identity), [hot])
        XCTAssertEqual(mid.watchedTotal, 1)
        XCTAssertFalse(mid.topWatched.contains { $0.identity == idle })

        await h.steps(7)
        let red = try await h.published()
        XCTAssertEqual(red.runaway.map(\.identity), [hot])
        XCTAssertEqual(red.topWatched, [])
    }
}
