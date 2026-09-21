import Darwin
import Foundation

/// 테이블 행 하나. 파싱이 뽑는 것은 `(pid, ppid, startSec, startUsec, ruid)` 다섯이다.
public struct ProcessRow: Sendable, Equatable {
    public let identity: ProcIdentity
    public let ppid: pid_t
    public let ruid: uid_t
    /// `p_comm`. 판정에는 쓰지 않고, argv 를 읽지 못한 행의 표시 이름으로만 쓴다.
    public let comm: String

    public init(identity: ProcIdentity, ppid: pid_t, ruid: uid_t, comm: String = "") {
        self.identity = identity
        self.ppid = ppid
        self.ruid = ruid
        self.comm = comm
    }

    public var pid: pid_t { identity.pid }
}

public struct ProcessTable: Sendable {
    public let rows: [ProcessRow]

    public init(rows: [ProcessRow]) { self.rows = rows }

    public var byIdentity: [ProcIdentity: ProcessRow] {
        Dictionary(rows.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

public enum ProcessSourceError: Error, Sendable, Equatable {
    /// 크기 조회 또는 읽기가 실패했다. 이 틱은 통째로 건너뛴다.
    case sysctlFailed(Int32)
    /// `ENOMEM` 재시도를 한 틱 안에서 소진했다.
    case retriesExhausted
}

/// 시스템콜을 부르는 유일한 자리의 계약.
///
/// 읽기가 끝내 실패하면 `table()` 이 던지고, 엔진은 그 틱을 통째로 건너뛴다 — 실패한
/// 읽기를 빈 테이블로 다루면 퇴거가 추적 집합 전체를 지워 폭주 중이던 식별자가 전부
/// `cleared` 를 내고 `notified` 까지 사라진다.
public protocol ProcessSource: AnyObject, Sendable {
    /// 이번 틱의 전체 테이블.
    func table() throws -> ProcessTable
    /// `basename(argv[0])`. nil 은 「미상, 다음 틱에 재시도」이지 「claude 아님」이 아니다.
    func argv0BaseName(pid: pid_t) -> String?
    /// 누적 CPU(mach tick). nil 은 측정 불가.
    func cpuTicks(pid: pid_t) -> UInt64?
    /// 이 프로세스의 실제 uid. 분류가 같은 uid 인지 보는 데 쓴다.
    var ownUID: uid_t { get }
}
