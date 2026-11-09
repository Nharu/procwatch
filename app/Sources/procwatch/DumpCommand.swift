import Darwin
import Foundation
import ProcwatchCore

/// `procwatch --dump` — 번들도 창도 없이 열거·분류·트리·rate·판정을 찍는 관측 진입점.
///
/// R13(걸음 곡선 보정)과 R17(start 시각 오프셋)과 R15(중첩 claude 오탐)의 레시피가
/// 부르는 것이 이 명령이다. 판정 경로는 앱과 같은 `SamplerCore` 한 벌이다.
enum DumpCommand {
    /// 관측 간격. 앱의 표본 주기와 달리 추적 집합이 비어도 늘리지 않는다.
    static let intervalSeconds = 5.0
    /// 「후손 상위」 줄에 찍는 행 수.
    static let topDescendantCount = 5

    static func run(tickLimit: Int?, settings: ThresholdSettings) {
        let params = JudgeParams(settings: settings)
        let core = SamplerCore(source: SystemProcessSource(), clock: SystemMonotonicClock(), params: params)
        print(String(format: "thresholds: T_hi=%d%% · D=%d min", settings.cpuThresholdPercent, settings.sustainMinutes))

        var previousRunaway: Set<ProcIdentity> = []
        var tick = 0
        while tickLimit.map({ tick < $0 }) ?? true {
            tick += 1
            guard let (snapshot, _) = core.tick() else {
                // 읽기가 실패한 틱은 통째로 건너뛴다. 기준선도 건드리지 않는다.
                print("tick \(tick): table read failed — skipping this tick")
                sleepOneInterval()
                continue
            }
            previousRunaway = reportEdges(snapshot, core: core, previousRunaway: previousRunaway)
            report(tick: tick, snapshot: snapshot, core: core)
            if tickLimit.map({ tick < $0 }) ?? true { sleepOneInterval() }
        }
    }

    private static func sleepOneInterval() {
        Thread.sleep(forTimeInterval: intervalSeconds)
    }

    /// 에지 줄. `tripped` 는 배너를 받을 첫 trip 만 싣으므로, 배너 없는 재trip 은 폭주
    /// 집합의 차이로 찾아 따로 표시한다.
    private static func reportEdges(
        _ snapshot: WatchSnapshot,
        core: SamplerCore,
        previousRunaway: Set<ProcIdentity>
    ) -> Set<ProcIdentity> {
        let current = Set(core.trackedIdentities.filter { core.inspect($0)?.runaway == true })
        let banners = Set(snapshot.tripped.map(\.identity))
        for identity in current.subtracting(previousRunaway).sorted(by: { $0.pid < $1.pid }) {
            let inspection = core.inspect(identity)
            let suffix = banners.contains(identity) ? "" : " (no banner)"
            print(String(
                format: "TRIPPED %@ · pid %d · R̄ %.1f%% · credit %.0f s%@",
                inspection?.name ?? "?", identity.pid, (inspection?.rBar ?? 0) * 100,
                inspection?.credit ?? 0, suffix
            ))
        }
        for identity in snapshot.cleared {
            print("CLEARED pid \(identity.pid) (start \(identity.startSec))")
        }
        return current
    }

    private static func report(tick: Int, snapshot: WatchSnapshot, core: SamplerCore) {
        // EMA 가 서기 전의 값은 숫자로 찍지 않는다 — 첫 표본은 기준선, 둘째는 씨앗이라
        // 평활된 값이 아니다. 찍으면 R13 이 보정에 쓰는 기록의 앞머리가 EMA 인 척 오염된다.
        let rootValues = core.claudeIdentities.compactMap { identity -> Double? in
            guard let inspection = core.inspect(identity), inspection.steps >= 2 else { return nil }
            return inspection.rBar
        }

        let head = "tick \(tick): claude: \(snapshot.rootCount) · judged: \(snapshot.trackedCount)"
        let stats: String
        if let peak = rootValues.max() {
            let sum = rootValues.reduce(0, +)
            stats = String(format: "peak(ema-max)=%.2f%% · sum(ema-sum)=%.2f%%", peak * 100, sum * 100)
        } else {
            stats = "peak(ema-max)=warming · sum(ema-sum)=warming"
        }
        let red = snapshot.anyRunaway ? " · runaway: \(snapshot.runawayTotal)" : ""
        print("\(head) · \(stats)\(red)")

        let descendants = core.judgedIdentities
            .compactMap { identity -> (ProcIdentity, SamplerCore.Inspection)? in
                guard let inspection = core.inspect(identity), inspection.steps >= 2,
                      inspection.rBar != nil else { return nil }
                return (identity, inspection)
            }
            .sorted { ($0.1.rBar ?? 0) > ($1.1.rBar ?? 0) }
            .prefix(topDescendantCount)

        for (identity, inspection) in descendants {
            let ancestry = DisplayText.ancestry(inspection.ancestry).joined(separator: " › ")
            print(String(
                format: "    %@ · pid %d · %.2f%% · credit %.0f s%@ · %@",
                DisplayText.name(inspection.name), identity.pid, (inspection.rBar ?? 0) * 100,
                inspection.credit, inspection.runaway ? " · runaway" : "", ancestry.isEmpty ? "-" : ancestry
            ))
        }
    }
}
