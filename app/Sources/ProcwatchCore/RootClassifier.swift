import Darwin
import Foundation

/// `basename(argv[0]) == "claude"` 하나로 claude 를 가른다. OR 가지는 없다.
///
/// `p_comm` 은 버전 문자열이라 쓰지 않고 `proc_pidpath` 도 쓰지 않는다 — claude
/// 바이너리가 `argv0=ugrep` 으로 도는 경우가 있어, 경로 가지를 두면 그 도우미가
/// claude 로 분류된다.
public final class RootClassifier {
    /// 정확 일치, 대소문자 구분.
    public static let rootBaseName = "claude"
    /// 한 정체성에서 argv 읽기가 이만큼 연속 실패하면 「루트 아님」으로 확정한다.
    public static let consecutiveFailureLimit = 3

    /// 확정된 판정. 새 식별자만 분류한다는 비용 전제를 이 캐시가 진다.
    private var settled: [ProcIdentity: Bool] = [:]
    private var consecutiveFailures: [ProcIdentity: Int] = [:]

    public init() {}

    /// 이번 틱의 판정. 읽기가 비면 「미상」이라 이번 틱에는 claude 가 아니지만 확정도
    /// 하지 않는다 — 다만 연속 실패가 상한에 닿으면 그때는 확정한다.
    ///
    /// 상한이 없으면 영구히 읽을 수 없는 같은 uid 행(좀비 등)이 살아 있는 내내 매 틱
    /// `KERN_PROCARGS2` 비용을 내어, 이 단계의 비용 전제가 그 행들에 대해 깨진다.
    public func isClaude(row: ProcessRow, ownUID: uid_t, readBaseName: (pid_t) -> String?) -> Bool {
        if let cached = settled[row.identity] { return cached }

        guard row.ruid == ownUID else {
            settled[row.identity] = false
            return false
        }

        guard let baseName = readBaseName(row.pid) else {
            let failures = (consecutiveFailures[row.identity] ?? 0) + 1
            consecutiveFailures[row.identity] = failures
            if failures >= Self.consecutiveFailureLimit {
                settled[row.identity] = false
                consecutiveFailures[row.identity] = nil
            }
            return false
        }

        consecutiveFailures[row.identity] = nil
        let verdict = baseName == Self.rootBaseName
        settled[row.identity] = verdict
        return verdict
    }

    /// 이번 틱에 claude 로 분류된 집합 `C`.
    public func claudeSet(rows: [ProcessRow], ownUID: uid_t, readBaseName: (pid_t) -> String?) -> Set<ProcIdentity> {
        var result: Set<ProcIdentity> = []
        for row in rows where isClaude(row: row, ownUID: ownUID, readBaseName: readBaseName) {
            result.insert(row.identity)
        }
        return result
    }

    /// 테이블에서 사라진 식별자의 캐시를 지운다. 1 만 개가 나고 죽어도 사전이 자라지
    /// 않게 하는 것은 이 호출이다.
    public func retain(_ living: Set<ProcIdentity>) {
        settled = settled.filter { living.contains($0.key) }
        consecutiveFailures = consecutiveFailures.filter { living.contains($0.key) }
    }

    /// 시험이 캐시 상태를 들여다보는 자리.
    public func settledVerdict(for identity: ProcIdentity) -> Bool? { settled[identity] }
    public var cachedIdentityCount: Int { settled.count }
}
