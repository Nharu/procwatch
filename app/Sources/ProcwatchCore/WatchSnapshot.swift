import Foundation

/// 엔진이 게시마다 하나 내는 불변 값. 경계를 넘는 것은 이것뿐이다.
public struct WatchSnapshot: Sendable {
    public let seq: UInt64                      // 게시마다 1 증가. 묶음 알림 id `runaway-batch-<seq>`의 재료
    public let sampledAt: Date                  // 표시 전용

    // 규모
    public let rootCount: Int                   // claude로 분류된 식별자 수(최상위 + 중첩). 0이면 걸음 정지
                                                // 메뉴 첫 줄의 문면은 이 값 혼자가 아니라 trackedCount와 함께 고른다
    public let trackedCount: Int                // 판정 대상 수 |J|(중첩 claude 포함). 추적 집합 T = C ∪ J의 크기가 아니다
    public let warmingCount: Int                // 「측정 중…」. 빨강이 되지 않음
    public let unmeasurableCount: Int           // 판정 대상인데 cpuTicks == nil (메뉴 「측정 불가」)
    public let clockUnitsSuspect: Bool          // 시작 시 시계 자체 점검 결과

    // 걸음
    public let rootPeakPercent: Double?         // claude로 분류된 식별자 전부의 R̄ 최댓값(%). 전부 워밍이거나 없으면 nil
    public let rootSumPercent: Double           // 메뉴 문구 전용

    // 레벨 — 빨간 키위
    public let runaway: [ProcRowView]           // R̄ 내림차순, 최대 10
    public let runawayTotal: Int                // 상한과 무관한 전체 수. 「외 N건」
    public var anyRunaway: Bool { runawayTotal > 0 }   // 저장하지 않는 계산 속성
    public let topWatched: [ProcRowView]        // 폭주 아닌 판정 대상 중 credit 내림차순, 최대 10 (「지켜보는 중」)
    public let watchedTotal: Int                // topWatched 상한과 무관한 전체 수. 메뉴가 두 목록 모두에 「외 N건」을 붙이므로 runawayTotal과 짝으로 둔다

    // 에지 — 코어가 게시마다 한 번만 계산
    public let tripped: [ProcRowView]           // 이번에 폭주 에지가 났고 그 식별자가 한 번도 배너를 받지 않은 것만
    public let cleared: [ProcIdentity]          // 폭주→비폭주 에지. 진정, 상환, 편집(판정기), 종료, 정체성 단절(엔진)

    public init(
        seq: UInt64, sampledAt: Date,
        rootCount: Int, trackedCount: Int, warmingCount: Int, unmeasurableCount: Int,
        clockUnitsSuspect: Bool,
        rootPeakPercent: Double?, rootSumPercent: Double,
        runaway: [ProcRowView], runawayTotal: Int,
        topWatched: [ProcRowView], watchedTotal: Int,
        tripped: [ProcRowView], cleared: [ProcIdentity]
    ) {
        self.seq = seq
        self.sampledAt = sampledAt
        self.rootCount = rootCount
        self.trackedCount = trackedCount
        self.warmingCount = warmingCount
        self.unmeasurableCount = unmeasurableCount
        self.clockUnitsSuspect = clockUnitsSuspect
        self.rootPeakPercent = rootPeakPercent
        self.rootSumPercent = rootSumPercent
        self.runaway = runaway
        self.runawayTotal = runawayTotal
        self.topWatched = topWatched
        self.watchedTotal = watchedTotal
        self.tripped = tripped
        self.cleared = cleared
    }
}

public enum RowState: Sendable, Equatable {     // 행이 왜 rate를 못 내는지 가른다
    case warming                                // 표본이 하나뿐. 메뉴 「측정 중…」
    case unmeasurable                           // cpuTicks == nil. 메뉴 「측정 불가」
    case measured                               // ratePercent가 값을 갖는다
}

public struct ProcRowView: Sendable, Identifiable, Equatable {
    public var id: ProcIdentity { identity }
    public let identity: ProcIdentity           // (pid, startSec, startUsec)
    public let name: String                     // basename(argv[0]) → 없으면 p_comm. 아래 표시 상한을 적용한 값
    public let ancestry: [String]               // 처음 본 순간의 경로로 고정. 예: ["claude 12345", "zsh", "python3"]
    public let state: RowState                  // ratePercent의 nil을 푸는 유일한 수단
    public let ratePercent: Double?             // R̄(%). state == .measured일 때만 값이 있다
    public let creditSeconds: Double            // 표시 전용
    public let runawaySince: Date?              // 표시 전용

    public init(
        identity: ProcIdentity, name: String, ancestry: [String], state: RowState,
        ratePercent: Double?, creditSeconds: Double, runawaySince: Date?
    ) {
        self.identity = identity
        self.name = name
        self.ancestry = ancestry
        self.state = state
        self.ratePercent = ratePercent
        self.creditSeconds = creditSeconds
        self.runawaySince = runawaySince
    }
}

/// argv 에서 온 문자열의 표시 상한. argv[0] 은 프로세스가 스스로 정하고 `kern.argmax` 가
/// 1 MiB 라, 자르지 않으면 앱의 유일한 UI 인 메뉴가 화면 밖으로 늘어난다. 표시 전용이며
/// 판정에는 쓰이지 않는다.
public enum DisplayText {
    /// 이름 한 칸의 최대 글자 수.
    public static let nameLimit = 64
    /// 조상 경로는 앞 이만큼과 뒤 `ancestryTail` 만큼만 남기고 가운데를 접는다.
    public static let ancestryHead = 1
    public static let ancestryTail = 2
    public static let fold = "…"

    /// 줄바꿈과 제어문자를 지우고 64 자로 자른다.
    public static func name(_ raw: String) -> String {
        let visible = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ))
        guard visible.count > nameLimit else { return visible }
        return String(visible.prefix(nameLimit - 1)) + fold
    }

    public static func ancestry(_ raw: [String]) -> [String] {
        let cleaned = raw.map(name)
        guard cleaned.count > ancestryHead + ancestryTail else { return cleaned }
        return Array(cleaned.prefix(ancestryHead)) + [fold] + Array(cleaned.suffix(ancestryTail))
    }
}
