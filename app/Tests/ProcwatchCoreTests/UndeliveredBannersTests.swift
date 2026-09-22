import XCTest
@testable import ProcwatchCore

/// 게시하지 못한 폭주 배너의 재시도 규칙.
///
/// 판정기는 식별자마다 배너 에지를 한 번만 내므로, 그 한 번이 권한 대화상자가 떠 있는
/// 동안 떨어지면 이 집합만이 이어지는 폭주에 배너를 다시 낼 수 있다.
final class UndeliveredBannersTests: XCTestCase {
    private let a = ProcIdentity(pid: 101, startSec: 1_000, startUsec: 1)
    private let b = ProcIdentity(pid: 202, startSec: 2_000, startUsec: 2)

    private func row(_ identity: ProcIdentity) -> ProcRowView {
        ProcRowView(
            identity: identity, name: "python3", ancestry: ["claude 1"], state: .measured,
            ratePercent: 98, creditSeconds: 1_800, runawaySince: nil
        )
    }

    private func snapshot(
        seq: UInt64 = 1,
        runaway: [ProcIdentity], tripped: [ProcIdentity] = [], cleared: [ProcIdentity] = []
    ) -> WatchSnapshot {
        WatchSnapshot(
            seq: seq, sampledAt: Date(timeIntervalSince1970: 0),
            rootCount: 1, trackedCount: runaway.count, warmingCount: 0, unmeasurableCount: 0,
            clockUnitsSuspect: false,
            rootPeakPercent: nil, rootSumPercent: 0,
            runaway: runaway.map(row), runawayTotal: runaway.count,
            topWatched: [], watchedTotal: 0,
            tripped: tripped.map(row), cleared: cleared
        )
    }

    /// 권한 미정 구간에 trip 한 폭주가 이어지는 동안 다음 스냅숏에서 다시 게시되고,
    /// 게시되고 나면 더 나오지 않는다.
    func testTripDuringUndeterminedAuthorizationIsRetriedWhileRunaway() {
        var undelivered = UndeliveredBanners()

        let first = undelivered.takeAttempt(from: snapshot(seq: 1, runaway: [a], tripped: [a]))
        XCTAssertEqual(first.map(\.identity), [a])
        undelivered.putBack(first)                                  // 권한 미정 — 게시하지 못함

        let second = undelivered.takeAttempt(from: snapshot(seq: 2, runaway: [a]))
        XCTAssertEqual(second.map(\.identity), [a], "tripped 가 비어도 미배달이 다시 나온다")

        let third = undelivered.takeAttempt(from: snapshot(seq: 3, runaway: [a]))
        XCTAssertEqual(third, [], "게시한 식별자는 다시 나오지 않는다")
    }

    /// 시도 중인 식별자는 결과가 오기 전의 다음 스냅숏에서 중복 시도되지 않는다.
    func testAttemptInFlightIsNotRetriedTwice() {
        var undelivered = UndeliveredBanners()
        undelivered.putBack([row(a)])

        XCTAssertEqual(undelivered.takeAttempt(from: snapshot(seq: 1, runaway: [a])).map(\.identity), [a])
        XCTAssertEqual(undelivered.takeAttempt(from: snapshot(seq: 2, runaway: [a])), [])
    }

    /// 폭주 레벨에 없는 동안은 미뤄지고 `cleared` 로도 빠지지 않으며, 같은 식별자의 다음
    /// 에피소드 레벨에서 나간다.
    func testDeferredUntilRunawayAndKeptAcrossCleared() {
        var undelivered = UndeliveredBanners()
        undelivered.putBack([row(a)])

        XCTAssertEqual(undelivered.takeAttempt(from: snapshot(seq: 1, runaway: [], cleared: [a])), [])
        XCTAssertEqual(undelivered.identities, [a])

        XCTAssertEqual(undelivered.takeAttempt(from: snapshot(seq: 2, runaway: [a])).map(\.identity), [a])
    }

    /// 권한 거부는 사용자의 선택이므로 집합을 비운다.
    func testDenialDiscardsUndelivered() {
        var undelivered = UndeliveredBanners()
        undelivered.putBack([row(a)])
        undelivered.discardAll()

        XCTAssertEqual(undelivered.takeAttempt(from: snapshot(runaway: [a])), [])
    }

    /// 같은 스냅숏에서 `tripped` 와 미배달을 함께 시도하되 식별자마다 한 번씩이다.
    func testTrippedAndUndeliveredAreAttemptedOnceEach() {
        var undelivered = UndeliveredBanners()
        undelivered.putBack([row(a), row(b)])

        let rows = undelivered.takeAttempt(from: snapshot(runaway: [b, a], tripped: [b]))
        XCTAssertEqual(rows.map(\.identity), [b, a])
        XCTAssertTrue(undelivered.identities.isEmpty)
    }

    /// 판정기는 이어지는 폭주에 배너 에지를 다시 내지 않는다 — 그 전제 위에서 첫 에지를
    /// 게시하지 못해도 미배달 집합이 둘째 스냅숏에 행을 다시 낸다.
    func testJudgeEmitsOneBannerEdgeAndUndeliveredCoversTheRest() {
        var judge = RunawayJudge(isClaude: false, judged: true)
        var undelivered = UndeliveredBanners()
        var events: [JudgeEvent] = []
        for _ in 0..<(1_800 / 5) {
            if let event = judge.step(dt: 5, rate: 1.0, p: .default) { events.append(event) }
        }
        XCTAssertEqual(events, [.tripped(banner: true)])
        let attempt = undelivered.takeAttempt(from: snapshot(seq: 1, runaway: [a], tripped: [a]))
        undelivered.putBack(attempt)                                // 권한 미정 — 게시하지 못함

        for _ in 0..<12 {
            XCTAssertNil(judge.step(dt: 5, rate: 1.0, p: .default), "이어지는 폭주에는 에지가 없다")
        }
        XCTAssertTrue(judge.runaway)

        let retry = undelivered.takeAttempt(from: snapshot(seq: 2, runaway: [a]))
        XCTAssertEqual(retry.map(\.identity), [a])
    }
}
