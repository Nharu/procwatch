import Foundation

/// 판정기가 내는 에지.
public enum JudgeEvent: Sendable, Equatable {
    /// 폭주로 넘어갔다. `banner` 는 이 식별자가 처음 배너를 받을 차례인지다.
    case tripped(banner: Bool)
    /// 폭주에서 내려왔다.
    case cleared(ClearReason)
}

/// 판정기가 아는 해소 사유. 퇴거(종료)와 정체성 단절은 판정기 밖의 사건이라 그 둘의
/// `cleared` 는 엔진이 만든다.
public enum ClearReason: Sendable, Equatable {
    /// `R̄ < T_lo` 가 `R_clear` 동안 이어졌다.
    case calm
    /// 폭주 중 credit 이 해제 수준 아래로 갚아졌다.
    case repaid
    /// 임계 편집으로 게이트가 닫혔다.
    case edited
}

/// 식별자 하나의 판정 상태. 에지와 레벨을 한 곳에서 계산한다.
public struct RunawayJudge: Sendable {
    /// EMA 와 워밍 씨앗의 소유자. 판정기 안에 평활을 다시 쓰지 않는다.
    public private(set) var smoother: EmaSmoother
    public private(set) var credit: Double = 0
    public private(set) var belowLo: Double = 0
    public private(set) var runaway = false
    public private(set) var notified = false
    /// 표시용. 폭주로 넘어간 벽시계 시각이며 판정에는 쓰이지 않는다.
    public private(set) var runawaySince: Date?
    /// 걸음 입력 집합에 드는가.
    public var isClaude: Bool
    /// 판정 대상(후손)인가. 한 번 참이면 sticky 로 남는다.
    public var judged: Bool

    public var rBar: Double? { smoother.rBar }

    public init(tau: Double = JudgeParams.tau, isClaude: Bool, judged: Bool) {
        self.smoother = EmaSmoother(tau: tau)
        self.isClaude = isClaude
        self.judged = judged
    }

    /// 한 걸음 민다. `now` 는 `runawaySince` 표시에만 쓴다.
    public mutating func step(dt: Double, rate: Double, p: JudgeParams, now: Date = Date()) -> JudgeEvent? {
        let rBar = smoother.update(rate: rate, dt: dt)                     // 첫 rate 가 EMA 를 정한다
        guard judged else { return nil }                                   // 최상위 claude: rate 만 추적
        credit = min(max(credit + (rBar >= p.tHi ? dt : -dt), 0), p.cap)   // 대칭, 단일 문턱, 구간 상한 없음
        belowLo = rBar < p.tLo ? belowLo + dt : 0
        if runaway {
            if belowLo >= p.rClear { fall(); credit = 0; return .cleared(.calm) }
            if credit < p.release { fall(); return .cleared(.repaid) }
        } else if credit >= p.d {
            runaway = true
            runawaySince = now
            if !notified { notified = true; return .tripped(banner: true) }
            return .tripped(banner: false)                                 // 빨간 키위만
        }
        return nil
    }

    /// 임계 편집. 읽는 시점에 재평가하고, `credit` 을 잘라내기만 하며 키우지 않는다.
    /// 편집으로 새로 trip 하는 일은 여기서 나지 않고 다음 `step` 에서 난다.
    public mutating func apply(_ p: JudgeParams) -> JudgeEvent? {
        credit = min(credit, p.cap)
        if runaway && !(credit >= p.d && (rBar ?? 0) >= p.tHi) {
            fall()
            credit = min(credit, p.d)                                      // 게이트가 다시 열릴 때만 재trip
            return .cleared(.edited)                                       // 에지도 판정기가 낸다
        }
        return nil
    }

    private mutating func fall() {
        runaway = false
        runawaySince = nil
    }
}
