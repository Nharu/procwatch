import Darwin
import XCTest
@testable import ProcwatchCore

/// `KERN_PROCARGS2` 파싱과 basename.
final class ProcArgsParserTests: XCTestCase {
    private func procArgs(argc: Int32, executable: String, padding: Int, argv: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(executable.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for argument in argv {
            bytes += Array(argument.utf8) + [0]
        }
        return bytes
    }

    func testArgvZeroIsReadAfterTheExecutablePathAndPadding() {
        let bytes = procArgs(argc: 2, executable: "/Users/x/.local/share/claude/versions/2.1.0",
                             padding: 3, argv: ["claude", "--resume"])
        XCTAssertEqual(SystemProcessSource.argv0(inProcArgs2: bytes, byteCount: bytes.count), "claude")
    }

    /// 실행 경로가 claude 여도 argv[0] 이 `ugrep` 이면 그 이름을 돌려준다.
    func testArgvZeroWinsOverTheExecutablePath() {
        let bytes = procArgs(argc: 1, executable: "/Users/x/.local/share/claude/versions/2.1.0",
                             padding: 0, argv: ["ugrep"])
        XCTAssertEqual(SystemProcessSource.argv0(inProcArgs2: bytes, byteCount: bytes.count), "ugrep")
    }

    func testTruncatedOrEmptyBuffersAreUnknown() {
        XCTAssertNil(SystemProcessSource.argv0(inProcArgs2: [1, 0], byteCount: 2))
        let noArgv = procArgs(argc: 1, executable: "/bin/zsh", padding: 4, argv: [])
        XCTAssertNil(SystemProcessSource.argv0(inProcArgs2: noArgv, byteCount: noArgv.count))
        let zeroArgc = procArgs(argc: 0, executable: "/bin/zsh", padding: 0, argv: ["zsh"])
        XCTAssertNil(SystemProcessSource.argv0(inProcArgs2: zeroArgc, byteCount: zeroArgc.count))
    }

    func testBaseName() {
        XCTAssertEqual(SystemProcessSource.baseName(of: "/Users/x/.local/bin/claude"), "claude")
        XCTAssertEqual(SystemProcessSource.baseName(of: "claude"), "claude")
        XCTAssertEqual(SystemProcessSource.baseName(of: "-zsh"), "-zsh")
    }
}

/// `basename(argv[0]) == "claude"` 하나로 가르고, 판정은 식별자별로 캐시한다.
final class RootClassifierTests: XCTestCase {
    private let me: uid_t = 501

    private func row(_ pid: pid_t, uid: uid_t = 501, start: Int64 = 100) -> ProcessRow {
        ProcessRow(identity: ProcIdentity(pid: pid, startSec: start, startUsec: 0), ppid: 1, ruid: uid)
    }

    func testExactCaseSensitiveMatchOnly() {
        let classifier = RootClassifier()
        let names: [pid_t: String] = [10: "claude", 11: "Claude", 12: "claude-code", 13: "ugrep"]
        XCTAssertTrue(classifier.isClaude(row: row(10), ownUID: me) { names[$0] })
        XCTAssertFalse(classifier.isClaude(row: row(11), ownUID: me) { names[$0] })
        XCTAssertFalse(classifier.isClaude(row: row(12), ownUID: me) { names[$0] })
        XCTAssertFalse(classifier.isClaude(row: row(13), ownUID: me) { names[$0] })
    }

    func testOtherUIDIsNeverClaudeAndIsNotRead() {
        let classifier = RootClassifier()
        var reads = 0
        XCTAssertFalse(classifier.isClaude(row: row(10, uid: 0), ownUID: me) { _ in reads += 1; return "claude" })
        XCTAssertEqual(reads, 0)
    }

    /// 새 식별자만 분류한다 — 확정된 판정은 다시 읽지 않는다.
    func testVerdictIsCachedPerIdentity() {
        let classifier = RootClassifier()
        var reads = 0
        let read: (pid_t) -> String? = { _ in reads += 1; return "claude" }
        XCTAssertTrue(classifier.isClaude(row: row(10), ownUID: me, readBaseName: read))
        XCTAssertTrue(classifier.isClaude(row: row(10), ownUID: me, readBaseName: read))
        XCTAssertEqual(reads, 1)

        // 같은 pid 라도 start 시각이 다르면 다른 식별자라 다시 읽는다.
        XCTAssertTrue(classifier.isClaude(row: row(10, start: 200), ownUID: me, readBaseName: read))
        XCTAssertEqual(reads, 2)
    }

    /// 빈 읽기는 「미상」이다. 세 번 연속이면 「루트 아님」으로 확정되고 다시 읽지 않는다.
    func testThreeConsecutiveReadFailuresSettleAsNotRoot() {
        let classifier = RootClassifier()
        var reads = 0
        let failing: (pid_t) -> String? = { _ in reads += 1; return nil }

        XCTAssertFalse(classifier.isClaude(row: row(10), ownUID: me, readBaseName: failing))
        XCTAssertNil(classifier.settledVerdict(for: row(10).identity))
        XCTAssertFalse(classifier.isClaude(row: row(10), ownUID: me, readBaseName: failing))
        XCTAssertNil(classifier.settledVerdict(for: row(10).identity))
        XCTAssertFalse(classifier.isClaude(row: row(10), ownUID: me, readBaseName: failing))
        XCTAssertEqual(classifier.settledVerdict(for: row(10).identity), false)

        XCTAssertFalse(classifier.isClaude(row: row(10), ownUID: me) { _ in reads += 1; return "claude" })
        XCTAssertEqual(reads, 3)
    }

    /// 실패가 연속이 아니면 확정하지 않는다.
    func testASuccessfulReadBetweenFailuresResetsTheCount() {
        let classifier = RootClassifier()
        XCTAssertFalse(classifier.isClaude(row: row(10), ownUID: me) { _ in nil })
        XCTAssertFalse(classifier.isClaude(row: row(10), ownUID: me) { _ in nil })
        XCTAssertTrue(classifier.isClaude(row: row(10), ownUID: me) { _ in "claude" })
        XCTAssertEqual(classifier.settledVerdict(for: row(10).identity), true)
    }

    func testRetainDropsIdentitiesThatLeftTheTable() {
        let classifier = RootClassifier()
        for pid in 10..<20 {
            _ = classifier.isClaude(row: row(pid_t(pid)), ownUID: me) { _ in "zsh" }
        }
        XCTAssertEqual(classifier.cachedIdentityCount, 10)
        classifier.retain([row(10).identity])
        XCTAssertEqual(classifier.cachedIdentityCount, 1)
    }
}

/// 소속 — 중첩 claude, 간선 가드, sticky, 깊이 상한.
final class TreeResolverTests: XCTestCase {
    private func identity(_ pid: pid_t, _ start: Int64) -> ProcIdentity {
        ProcIdentity(pid: pid, startSec: start, startUsec: 0)
    }

    private func row(_ pid: pid_t, parent: pid_t, start: Int64) -> ProcessRow {
        ProcessRow(identity: identity(pid, start), ppid: parent, ruid: 501)
    }

    private func name(_ identity: ProcIdentity) -> String { "p\(identity.pid)" }

    /// `claude → claude → zsh → python3`: 최상위만 판정하지 않는다.
    func testNestedClaudeAndItsDescendantsAreJudgedButTheTopLevelIsNot() {
        let rows = [
            row(1, parent: 0, start: 0),
            row(100, parent: 1, start: 10),       // 최상위 claude
            row(200, parent: 100, start: 20),     // 중첩 claude
            row(300, parent: 200, start: 30),     // zsh
            row(400, parent: 300, start: 40),     // python3
        ]
        let claude: Set = [identity(100, 10), identity(200, 20)]
        let sets = TreeResolver().resolve(rows: rows, claude: claude, displayName: name)

        XCTAssertEqual(sets.judged, [identity(200, 20), identity(300, 30), identity(400, 40)])
        XCTAssertFalse(sets.judged.contains(identity(100, 10)))
        XCTAssertEqual(sets.tracked.count, 4)
        XCTAssertEqual(sets.ancestry[identity(400, 40)], ["p100", "p200", "p300", "p400"])
    }

    /// pid 가 순환해 중첩 claude 의 pid 가 조상보다 작아도 중첩 claude 는 판정 대상이다.
    func testNestedClaudeWithASmallerPIDIsStillJudged() {
        let rows = [
            row(900, parent: 1, start: 10),       // 최상위 claude
            row(50, parent: 900, start: 20),      // 중첩 claude (pid 순환)
            row(60, parent: 50, start: 30),
        ]
        let claude: Set = [identity(900, 10), identity(50, 20)]
        let sets = TreeResolver().resolve(rows: rows, claude: claude, displayName: name)
        XCTAssertEqual(sets.judged, [identity(50, 20), identity(60, 30)])
        XCTAssertEqual(sets.ancestry[identity(60, 30)], ["p900", "p50", "p60"])
    }

    /// claude 바이너리가 `argv0=ugrep` 으로 돈 자식은 claude 가 아니므로 후손으로 판정된다.
    func testUgrepChildOfClaudeIsJudged() {
        let rows = [row(100, parent: 1, start: 10), row(101, parent: 100, start: 11)]
        let sets = TreeResolver().resolve(rows: rows, claude: [identity(100, 10)], displayName: name)
        XCTAssertEqual(sets.judged, [identity(101, 11)])
    }

    /// 자식 start 가 부모 start 보다 이르면 그 간선은 pid 재사용이 만든 가짜다.
    func testEdgeFromAYoungerParentIsDiscarded() {
        let rows = [
            row(100, parent: 1, start: 50),       // claude 가 pid 100 을 재사용해 늦게 시작
            row(101, parent: 100, start: 20),     // 옛 pid 100 의 자식
        ]
        let sets = TreeResolver().resolve(rows: rows, claude: [identity(100, 50)], displayName: name)
        XCTAssertTrue(sets.judged.isEmpty)
    }

    /// 부모 claude 가 끝나 launchd 로 입양돼도 판정 대상으로 남고, 끝나면 빠진다.
    func testMembershipIsStickyUntilTheIdentityEnds() {
        let resolver = TreeResolver()
        let claude = identity(100, 10)
        let child = identity(200, 20)

        var sets = resolver.resolve(
            rows: [row(100, parent: 1, start: 10), row(200, parent: 100, start: 20)],
            claude: [claude], displayName: name)
        XCTAssertEqual(sets.judged, [child])

        // claude 가 끝나고 자식은 launchd 로 입양됐다.
        sets = resolver.resolve(rows: [row(200, parent: 1, start: 20)], claude: [], displayName: name)
        XCTAssertEqual(sets.judged, [child])
        XCTAssertEqual(sets.ancestry[child], ["p100", "p200"], "조상 경로는 처음 본 순간으로 고정")

        // 자식도 끝났다.
        sets = resolver.resolve(rows: [], claude: [], displayName: name)
        XCTAssertTrue(sets.judged.isEmpty)
    }

    /// 고아가 된 뒤에 새로 만든 자식도 판정 대상이다 — sticky 는 결과 집합에만 합쳐지는
    /// 것이 아니라 다음 틱의 탐색 시작점으로 다시 들어간다.
    func testStickyOrphanIsReinjectedSoItsNewChildIsJudged() {
        let resolver = TreeResolver()
        let claude = identity(100, 10)
        let orphan = identity(200, 20)
        let worker = identity(300, 30)

        var sets = resolver.resolve(
            rows: [row(1, parent: 0, start: 0), row(100, parent: 1, start: 10), row(200, parent: 100, start: 20)],
            claude: [claude], displayName: name)
        XCTAssertEqual(sets.judged, [orphan])

        // claude 가 끝나 고아가 된 뒤에 그 고아가 새 자식을 만들었다.
        sets = resolver.resolve(
            rows: [row(200, parent: 1, start: 20), row(300, parent: 200, start: 30)],
            claude: [], displayName: name)
        XCTAssertEqual(sets.judged, [orphan, worker])
        XCTAssertEqual(sets.ancestry[worker], ["p100", "p200", "p300"],
                       "새 가지는 고아의 고정된 조상 경로에 이어 붙는다")

        // 고아까지 끝나도 그 자식은 sticky 로 계속 판정된다 — 재투입은 한 세대에서 끝나지 않는다.
        sets = resolver.resolve(rows: [row(300, parent: 1, start: 30)], claude: [], displayName: name)
        XCTAssertEqual(sets.judged, [worker])
    }

    func testDepthLimitStopsTheWalk() {
        var rows = [row(1, parent: 0, start: 0)]
        for depth in 1...(TreeResolver.depthLimit + 5) {
            rows.append(row(pid_t(depth + 1), parent: pid_t(depth), start: Int64(depth)))
        }
        let sets = TreeResolver().resolve(rows: rows, claude: [identity(1, 0)], displayName: name)
        XCTAssertEqual(sets.judged.count, TreeResolver.depthLimit)
    }

    func testCycleThroughSelfParentingIsHarmless() {
        let rows = [row(0, parent: 0, start: 0), row(100, parent: 0, start: 5)]
        let sets = TreeResolver().resolve(rows: rows, claude: [identity(0, 0)], displayName: name)
        XCTAssertEqual(sets.judged, [identity(100, 5)])
    }
}
