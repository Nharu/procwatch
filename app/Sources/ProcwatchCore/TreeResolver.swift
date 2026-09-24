import Darwin
import Foundation

/// 이번 틱의 소속. `T = C ∪ J` 이고, 스냅숏의 `trackedCount` 는 `|T|` 가 아니라 `|J|` 다.
public struct TrackedSets: Sendable {
    /// `C` — claude 로 분류된 식별자(최상위 + 중첩).
    public let claude: Set<ProcIdentity>
    /// `J` — 판정 대상. 시작점 집합(`C` 와 sticky 유지 집합의 합집합)의 어느 원소에서
    /// 한 간선 이상 내려가 닿는 전부이며, 간선을 하나도 타지 않은 시작 노드 자신은
    /// sticky 일 때만 든다.
    public let judged: Set<ProcIdentity>
    /// 처음 본 순간의 경로로 고정된 조상 이름들.
    public let ancestry: [ProcIdentity: [String]]

    /// 추적 집합.
    public var tracked: Set<ProcIdentity> { claude.union(judged) }
}

/// `C` 와 sticky 유지 집합을 시작점으로 ppid→자식 지도를 내려가 `J` 를 만든다.
public final class TreeResolver {
    /// BFS 깊이 상한.
    public static let depthLimit = 64

    /// 소속은 sticky 다 — 부모 claude 가 끝나 launchd 로 입양되어도 한 번 후손이었던
    /// 식별자는 정체성이 끝날 때까지 판정된다.
    private var previousJudged: Set<ProcIdentity> = []
    /// 조상 경로는 처음 본 순간에 고정한다.
    private var ancestryByIdentity: [ProcIdentity: [String]] = [:]

    public init() {}

    public func resolve(
        rows: [ProcessRow],
        claude: Set<ProcIdentity>,
        displayName: (ProcIdentity) -> String
    ) -> TrackedSets {
        let rowsByPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [pid_t: [ProcessRow]] = [:]
        for row in rows {
            children[row.ppid, default: []].append(row)
        }

        var judged: Set<ProcIdentity> = []
        // 한 번 펼친 노드는 다시 펼치지 않는다. 「후손으로 닿았는가」는 이것과 따로 센다 —
        // 시작 노드를 여기 먼저 넣어 두면, 먼저 펼쳐진 중첩 claude 가 나중에 조상에서
        // 내려올 때 `J` 에 들어가지 못한다.
        var expanded: Set<ProcIdentity> = []

        // sticky — 이전 틱 `J` 가운데 아직 테이블에 있는 것. 결과 집합에만 합치면 부모가
        // 끝나 입양된 뒤에 새로 생긴 자식을 아무도 펼치지 않으므로, 시작점으로 다시 넣는다.
        // 틱 비용은 늘지 않는다 — 살아 있는 조상 아래에 있는 원소는 그쪽 탐색에서 이미
        // 펼쳐져 `expanded` 가 거르고, sticky 원소는 이번 틱 행을 이미 갖고 있다.
        let living = Set(rows.map(\.identity))
        let sticky = previousJudged.intersection(living)

        // 먼저 시작한 시작점부터 펼친다. 간선 가드 때문에 조상은 늘 후손보다 먼저
        // 시작했으므로, 조상 경로가 중첩 claude 자신의 경로보다 먼저 고정된다.
        let starts = claude.union(sticky).sorted {
            ($0.startSec, $0.startUsec, $0.pid) < ($1.startSec, $1.startUsec, $1.pid)
        }
        for start in starts {
            guard let startRow = rowsByPID[start.pid], startRow.identity == start else { continue }
            guard expanded.insert(start).inserted else { continue }
            // sticky 시작점은 처음 보였을 때 고정된 경로를 갖고 있으므로 새 가지가 그 뒤에
            // 이어 붙는다. 최상위 claude 는 항목이 없어 자기 이름 하나로 시작한다.
            var frontier: [(row: ProcessRow, depth: Int, path: [String])] = [
                (startRow, 0, ancestryByIdentity[start] ?? [displayName(start)])
            ]

            while !frontier.isEmpty {
                let node = frontier.removeFirst()
                guard node.depth < Self.depthLimit else { continue }
                for child in children[node.row.pid] ?? [] {
                    // 자식 start 가 부모 start 보다 이른 간선은 pid 재사용이 만든 가짜다.
                    guard !child.identity.startsBefore(node.row.identity) else { continue }
                    guard child.identity != node.row.identity else { continue }

                    judged.insert(child.identity)
                    let path = node.path + [displayName(child.identity)]
                    if ancestryByIdentity[child.identity] == nil {
                        ancestryByIdentity[child.identity] = path
                    }
                    guard expanded.insert(child.identity).inserted else { continue }
                    frontier.append((child, node.depth + 1, path))
                }
            }
        }

        // 간선을 하나도 타지 않은 sticky 시작 노드 자신은 이 줄이 `J` 에 넣는다.
        judged.formUnion(sticky)
        previousJudged = judged
        ancestryByIdentity = ancestryByIdentity.filter { living.contains($0.key) }

        return TrackedSets(
            claude: claude,
            judged: judged,
            ancestry: ancestryByIdentity
        )
    }
}
