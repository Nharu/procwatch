import Darwin
import Foundation

/// pid 하나를 시작 시각까지 포함해 가리키는 키.
///
/// pid 는 재사용되므로 그것만으로는 식별자가 되지 못한다. start 시각이 같으면 같은
/// 식별자라는 것이 이 문서 전체가 기대는 정의이고, 정체성 단절과 카운터 재기준선을
/// 가르는 것도 `Δc` 의 부호가 아니라 이 값이다.
public struct ProcIdentity: Sendable, Hashable, CustomStringConvertible {
    public let pid: pid_t
    public let startSec: Int64
    public let startUsec: Int32

    public init(pid: pid_t, startSec: Int64, startUsec: Int32) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
    }

    /// 알림 식별자 `runaway-<pid>-<startSec>-<startUsec>` 의 꼬리.
    public var notificationSuffix: String { "\(pid)-\(startSec)-\(startUsec)" }

    public var description: String { "pid \(pid) @\(startSec).\(startUsec)" }

    /// 시작 시각의 앞뒤. 트리 간선 가드가 쓴다.
    public func startsBefore(_ other: ProcIdentity) -> Bool {
        (startSec, startUsec) < (other.startSec, other.startUsec)
    }
}
