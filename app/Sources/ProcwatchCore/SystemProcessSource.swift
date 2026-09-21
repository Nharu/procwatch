import Darwin
import Foundation

/// `sysctl` 과 `libproc` 을 부르는 유일한 자리.
///
/// 버퍼 둘(테이블, argv)을 틱 사이에 재사용한다. 소유자는 `SamplerEngine` 하나이고
/// 그 직렬 실행자 위에서만 불리므로, `@unchecked Sendable` 은 그 소유 규칙에 기댄다.
public final class SystemProcessSource: ProcessSource, @unchecked Sendable {
    /// 한 틱 안에서 `ENOMEM` 재시도 횟수.
    public static let enomemRetryLimit = 3
    /// 크기 조회 뒤 얹는 여유.
    public static let headroomNumerator = 1
    public static let headroomDenominator = 5      // 약 20 %

    public let ownUID: uid_t

    private var tableBuffer: UnsafeMutableRawPointer?
    private var tableCapacity = 0
    private var argsBuffer: [UInt8]

    public init() {
        self.ownUID = getuid()
        self.argsBuffer = [UInt8](repeating: 0, count: Self.readArgMax())
    }

    deinit { tableBuffer?.deallocate() }

    /// `kern.argmax`. 이 기기에서는 1 MiB 다.
    private static func readArgMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return 1 << 20
    }

    // MARK: - 테이블

    public func table() throws -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var lastErrno: Int32 = 0

        for _ in 0..<Self.enomemRetryLimit {
            var needed = 0
            guard sysctl(&mib, 4, nil, &needed, nil, 0) == 0 else {
                throw ProcessSourceError.sysctlFailed(errno)
            }
            guard needed > 0 else { return ProcessTable(rows: []) }

            let wanted = needed + needed / Self.headroomDenominator * Self.headroomNumerator
            ensureCapacity(wanted)

            var size = tableCapacity
            if sysctl(&mib, 4, tableBuffer, &size, nil, 0) == 0 {
                return ProcessTable(rows: parseRows(byteCount: size))
            }
            lastErrno = errno
            // ENOMEM 이면 테이블이 그사이 자란 것이므로 크기 조회부터 다시 한다.
            guard lastErrno == ENOMEM else { throw ProcessSourceError.sysctlFailed(lastErrno) }
        }
        throw ProcessSourceError.retriesExhausted
    }

    private func ensureCapacity(_ wanted: Int) {
        guard wanted > tableCapacity else { return }
        tableBuffer?.deallocate()
        tableBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: wanted,
            alignment: MemoryLayout<kinfo_proc>.alignment
        )
        tableCapacity = wanted
    }

    private func parseRows(byteCount: Int) -> [ProcessRow] {
        guard let base = tableBuffer else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = byteCount / stride
        guard count > 0 else { return [] }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let entry = base.load(fromByteOffset: index * stride, as: kinfo_proc.self)
            rows.append(Self.row(from: entry))
        }
        return rows
    }

    /// `p_starttime` 은 Swift 임포터에서 매크로가 사라지지만 무명 공용체가 `p_un` 이라는
    /// 이름으로 들어온다. 생바이트 오프셋 대신 그 이름 있는 경로를 쓰며, 이 파일이
    /// 컴파일된다는 사실 자체가 그 경로가 실재한다는 증거다(§구현 시 검증 항목 R17).
    static func row(from entry: kinfo_proc) -> ProcessRow {
        let started = entry.kp_proc.p_un.__p_starttime
        let identity = ProcIdentity(
            pid: entry.kp_proc.p_pid,
            startSec: Int64(started.tv_sec),
            startUsec: Int32(started.tv_usec)
        )
        var command = entry.kp_proc.p_comm
        let comm = withUnsafeBytes(of: &command) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return ProcessRow(
            identity: identity,
            ppid: entry.kp_eproc.e_ppid,
            ruid: entry.kp_eproc.e_pcred.p_ruid,
            comm: comm
        )
    }

    // MARK: - argv

    public func argv0BaseName(pid: pid_t) -> String? {
        guard let argv0 = readArgv0(pid: pid) else { return nil }
        return Self.baseName(of: argv0)
    }

    /// 경로의 마지막 칸. `/` 로만 자르고 확장자는 건드리지 않는다.
    public static func baseName(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private func readArgv0(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argsBuffer.count
        let succeeded = argsBuffer.withUnsafeMutableBytes { raw -> Bool in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) == 0
        }
        guard succeeded else { return nil }
        return Self.argv0(inProcArgs2: argsBuffer, byteCount: size)
    }

    /// `KERN_PROCARGS2` 의 배치: argc(Int32) · 실행 경로 · NUL 채움 · argv[0] · …
    ///
    /// 실행 경로가 아니라 argv[0] 을 쓰는 것이 §결정 2 의 요지다 — claude 바이너리가
    /// `argv0=ugrep` 으로도 돌아서, 경로 가지를 두면 그 도우미가 claude 로 분류된다.
    static func argv0(inProcArgs2 bytes: [UInt8], byteCount: Int) -> String? {
        let header = MemoryLayout<Int32>.size
        guard byteCount > header else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = header
        while index < byteCount, bytes[index] != 0 { index += 1 }   // 실행 경로
        while index < byteCount, bytes[index] == 0 { index += 1 }   // NUL 채움
        guard index < byteCount else { return nil }

        let start = index
        while index < byteCount, bytes[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    // MARK: - CPU

    public func cpuTicks(pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let wanted = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, wanted)
        }
        // 행은 있는데 호출이 실패하는 경우(다른 uid, 종료 경합)가 있으므로 반환값을 본다.
        guard read == wanted else { return nil }
        return info.pti_total_user &+ info.pti_total_system
    }
}
