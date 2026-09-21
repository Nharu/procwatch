import Darwin
import Foundation
import XCTest
@testable import ProcwatchCore

/// 이 기기의 실제 테이블에 대고 도는 파서 시험. start 시각을 읽는 경로의 세 검사
/// (`tv_sec` 대조, `tv_usec` 불변, `tv_usec` 범위)가 여기 있다.
///
/// start 시각 경로가 틀리면 매 틱 정체성 단절로 보여 판정기가 영원히 워밍에 머물거나
/// 서로 다른 프로세스가 한 식별자로 합쳐지고, 둘 다 화면상 멀쩡해 보이는 조용한 실패다.
final class SystemProcessSourceTests: XCTestCase {
    func testTableContainsThisProcessWithItsParent() throws {
        let source = SystemProcessSource()
        let table = try source.table()
        XCTAssertGreaterThan(table.rows.count, 10)

        let me = try XCTUnwrap(table.rows.first { $0.pid == getpid() })
        XCTAssertEqual(me.ppid, getppid())
        XCTAssertEqual(me.ruid, getuid())
        XCTAssertEqual(source.ownUID, getuid())
    }

    /// 1. `tv_sec` 를 `ps -o lstart=` 와 초 단위로 대조한다.
    func testStartSecondsMatchPsLstart() throws {
        let table = try SystemProcessSource().table()
        let candidates = [getpid(), getppid(), 1]
        var compared = 0
        for pid in candidates {
            guard let row = table.rows.first(where: { $0.pid == pid }),
                  let lstart = try Self.psStartSeconds(pid: pid)
            else { continue }
            XCTAssertEqual(row.identity.startSec, lstart, "pid \(pid)")
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 2)
    }

    /// 2. 같은 pid 를 두 번 읽어 `startUsec` 가 정확히 같은지 본다. 값이 흔들리면 그
    /// 경로는 start 시각이 아닌 바이트를 가리키고 있다.
    func testStartMicrosecondsAreStableAcrossReads() throws {
        let source = SystemProcessSource()
        let first = try source.table().byIdentity
        Thread.sleep(forTimeInterval: 0.2)
        let second = try source.table()

        let firstByPID = Dictionary(first.values.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var shared = 0
        for row in second.rows {
            guard let earlier = firstByPID[row.pid], earlier.identity.startSec == row.identity.startSec
            else { continue }
            XCTAssertEqual(earlier.identity.startUsec, row.identity.startUsec, "pid \(row.pid)")
            shared += 1
        }
        XCTAssertGreaterThan(shared, 10)
    }

    /// 3. 전 행에서 `0 ≤ startUsec < 1_000_000`.
    func testStartMicrosecondsAreInRange() throws {
        let table = try SystemProcessSource().table()
        let outOfRange = table.rows.filter { !(0..<1_000_000).contains($0.identity.startUsec) }
        XCTAssertEqual(outOfRange.count, 0, "\(outOfRange.prefix(5))")
    }

    func testOwnArgvAndCPUAreReadable() {
        let source = SystemProcessSource()
        XCTAssertNotNil(source.argv0BaseName(pid: getpid()))
        XCTAssertNotNil(source.cpuTicks(pid: getpid()))
    }

    /// 행은 있는데 호출이 실패하는 경우 — 다른 uid 의 pid 1 은 nil 이다.
    func testCPUOfAnotherUIDIsUnmeasurable() throws {
        try XCTSkipIf(getuid() == 0, "root 로 돌면 다른 uid 가 없다")
        XCTAssertNil(SystemProcessSource().cpuTicks(pid: 1))
    }

    // MARK: - ps

    /// `ps -o lstart=` 를 epoch 초로. 해상도는 1 초라 `tv_sec` 만 대조할 수 있다.
    private static func psStartSeconds(pid: pid_t) throws -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "lstart=", "-p", String(pid)]
        process.environment = ["LC_ALL": "C", "TZ": TimeZone.current.identifier]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let date = formatter.date(from: collapsed) else {
            XCTFail("ps lstart 를 풀지 못함: \(collapsed)")
            return nil
        }
        return Int64(date.timeIntervalSince1970)
    }
}
