import Foundation

/// 게시하지 못한 폭주 배너의 식별자 집합. `Notifier` 가 소유하고 엔진으로 돌아가지 않는다.
///
/// 판정기는 `.tripped` 를 비폭주→폭주 전이에서만 내므로, 권한이 정해지기 전이거나
/// `center.add` 가 던져 배너가 나가지 못하면 이어지는 폭주에는 다시 낼 에지가 없다. 그
/// 식별자를 여기 남겨 두고, 스냅숏의 `runaway` 행에 다시 보일 때 게시를 다시 시도한다.
/// 재시도에는 타이머를 두지 않고 스냅숏 도착에 맡긴다.
public struct UndeliveredBanners: Sendable {
    public private(set) var identities: Set<ProcIdentity> = []

    public init() {}

    /// 이 스냅숏에서 게시를 시도할 행 — `tripped` 전부, 그리고 집합과 겹치는 `runaway`
    /// 행(`tripped` 에 이미 있는 것 제외, `runaway` 순서). 시도하는 식별자는 시도가 끝날
    /// 때까지 집합에서 빠지므로 다음 스냅숏이 같은 식별자를 두 번 시도하지 않는다.
    /// `cleared` 는 집합에서 빼지 않는다 — 다음 에피소드의 레벨에서 게시하기 위해서다.
    public mutating func takeAttempt(from snapshot: WatchSnapshot) -> [ProcRowView] {
        let tripped = Set(snapshot.tripped.map(\.identity))
        let retried = snapshot.runaway.filter {
            identities.contains($0.identity) && !tripped.contains($0.identity)
        }
        let rows = snapshot.tripped + retried
        identities.subtract(rows.map(\.identity))
        return rows
    }

    /// 게시하지 못한 시도의 행을 집합에 되돌린다(권한 미정 또는 `center.add` 실패).
    public mutating func putBack(_ rows: [ProcRowView]) {
        identities.formUnion(rows.map(\.identity))
    }

    /// 권한 거부. 거부는 사용자의 선택이므로 게시를 건너뛰는 것과 같게 집합을 비운다.
    public mutating func discardAll() {
        identities.removeAll()
    }
}
