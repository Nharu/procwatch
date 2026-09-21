import Darwin
import Foundation

/// 틱 하나의 기록. 틱 시각 로그(`debugTickLog`)가 찍는 값이다.
public struct TickRecord: Sendable, Equatable {
    public let absolute: UInt64
    public let wall: Date
    /// 앞 틱과의 깨어 있는 초. 첫 틱에는 없다.
    public let dtSec: Double?
    /// 이 틱이 정한 다음 주기(초).
    public let nextInterval: Double
}

/// 틱 하나의 흐름(시계 → 테이블 → 분류 → 소속 → CPU → 갱신 → 퇴거 → 게시 → 주기)을
/// 동기로 도는 몸체. `SamplerEngine` 이 유일한 소유자이며, `--dump` 도 같은 몸체를
/// 부르므로 판정 경로는 한 벌이다.
///
/// 틱 사이에 갖는 가변 상태는 아래 저장 프로퍼티가 전부다.
public final class SamplerCore {
    /// 추적 집합이 비었을 때와 아닐 때의 주기.
    public static let idleInterval = 30.0
    public static let activeInterval = 5.0
    /// 스냅숏 목록 하나의 최대 행 수.
    public static let rowLimit = 10

    /// 식별자 하나의 틱 상태.
    struct Record {
        var judge: RunawayJudge
        /// 기준선. 워밍 중이거나 `cpuTicks == nil` 만 이어진 식별자는 없다.
        var baselineCPU: UInt64?
        var baselineAbsolute: UInt64?
        /// 이번 틱에 `cpuTicks == nil` 이었는가.
        var unmeasurable = false
        /// 판정기를 민 횟수. `--dump` 가 씨앗(첫 걸음)을 평활값으로 찍지 않는 데 쓴다.
        var steps = 0
        /// 표시 이름(표시 상한 적용 전). 처음 본 순간에 한 번 정한다.
        let name: String
    }

    private let source: any ProcessSource
    private let clock: any MonotonicClock
    private let classifier = RootClassifier()
    private let resolver = TreeResolver()

    public private(set) var params: JudgeParams
    private var records: [ProcIdentity: Record] = [:]
    /// 마지막으로 성공한 틱의 소속. 편집 게시가 테이블을 다시 읽지 않고 규모를 싣는다.
    private var lastSets = TrackedSets(claude: [], judged: [], ancestry: [:])
    private var seq: UInt64 = 0
    private var selfCheck = ClockSelfCheck()
    private var lastTick: (absolute: UInt64, wall: Date)?
    public private(set) var nextInterval = SamplerCore.idleInterval

    public init(source: any ProcessSource, clock: any MonotonicClock, params: JudgeParams) {
        self.source = source
        self.clock = clock
        self.params = params
    }

    // MARK: - 틱

    /// 한 틱을 돈다. 테이블 읽기가 끝내 실패하면 아무 상태도 건드리지 않고 nil 이다 —
    /// 실패한 읽기를 빈 테이블로 다루면 퇴거가 추적 집합 전체를 지워 폭주 중이던
    /// 식별자 전부가 `cleared` 를 내고 `notified` 까지 사라진다.
    public func tick(wall: Date = Date()) -> (snapshot: WatchSnapshot, record: TickRecord)? {
        // 1. 시계
        let now = clock.now()

        // 2. 테이블
        let table: ProcessTable
        do { table = try source.table() } catch { return nil }

        var dtSec: Double?
        if let lastTick {
            let dt = clock.seconds(from: lastTick.absolute, to: now)
            dtSec = dt
            selfCheck.observe(dtSec: dt, wallSec: wall.timeIntervalSince(lastTick.wall))
        }
        lastTick = (now, wall)

        let living = Set(table.rows.map(\.identity))
        let rowsByIdentity = table.byIdentity
        classifier.retain(living)

        // 3. 새 식별자만 분류한다(캐시는 분류기가 갖는다).
        let ownUID = source.ownUID
        let claude = classifier.claudeSet(rows: table.rows, ownUID: ownUID) { [source] in
            source.argv0BaseName(pid: $0)
        }

        // 4. 소속
        let sets = resolver.resolve(rows: table.rows, claude: claude) { [unowned self] identity in
            self.label(for: identity, row: rowsByIdentity[identity], isClaude: claude.contains(identity))
        }
        lastSets = sets

        // 5·6. CPU 와 식별자별 갱신
        var tripped: [ProcIdentity] = []
        var cleared: [ProcIdentity] = []
        for identity in sets.tracked {
            let isClaude = sets.claude.contains(identity)
            let isJudged = sets.judged.contains(identity)
            var record = records[identity] ?? Record(
                judge: RunawayJudge(tau: JudgeParams.tau, isClaude: isClaude, judged: isJudged),
                name: displayName(for: identity, row: rowsByIdentity[identity])
            )
            record.judge.isClaude = isClaude
            record.judge.judged = record.judge.judged || isJudged

            let event = advance(&record, cpu: source.cpuTicks(pid: identity.pid), now: now, wall: wall)
            switch event {
            case .tripped(banner: true)?: tripped.append(identity)
            case .cleared?: cleared.append(identity)
            case .tripped(banner: false)?, nil: break
            }
            records[identity] = record
        }

        // 7. 퇴거 — 테이블에서 사라진 식별자. 같은 pid 가 다른 start 시각으로 다시 나타난
        // 정체성 단절도 키가 다르므로 여기서 앞 식별자가 퇴거되고, 새 식별자는 워밍부터다.
        for (identity, record) in records where !sets.tracked.contains(identity) {
            if record.judge.runaway { cleared.append(identity) }
            records[identity] = nil
        }

        // 9. 주기 — 게시보다 먼저 정해 틱 기록에 싣는다.
        nextInterval = sets.tracked.isEmpty ? Self.idleInterval : Self.activeInterval

        // 8. 게시
        let snapshot = makeSnapshot(wall: wall, tripped: tripped, cleared: cleared)
        return (snapshot, TickRecord(absolute: now, wall: wall, dtSec: dtSec, nextInterval: nextInterval))
    }

    /// 걸음 하나. 워밍, 측정 불가, 카운터 재기준선, 정상 걸음 넷을 가른다.
    private func advance(_ record: inout Record, cpu: UInt64?, now: UInt64, wall: Date) -> JudgeEvent? {
        guard let cpu else {
            // cpuTicks == nil 이면 걸음도 Δt 소비도 없다. 기준선을 그대로 두므로 회복한
            // 틱의 한 걸음이 비었던 구간 전체를 덮는다.
            record.unmeasurable = true
            return nil
        }
        record.unmeasurable = false

        guard let baselineCPU = record.baselineCPU, let baselineAbsolute = record.baselineAbsolute else {
            record.baselineCPU = cpu           // 워밍 — 기준선만 저장한다
            record.baselineAbsolute = now
            return nil
        }
        defer {
            record.baselineCPU = cpu
            record.baselineAbsolute = now
        }
        // 카운터 재기준선 — start 시각은 같으므로 같은 식별자다. 표본 하나만 버린다.
        guard cpu >= baselineCPU, now > baselineAbsolute else { return nil }

        let deltaAbsolute = now - baselineAbsolute
        guard let rate = CPURate.rate(deltaCPUTicks: cpu - baselineCPU, deltaAbsoluteTicks: deltaAbsolute) else {
            return nil
        }
        let dt = clock.seconds(from: baselineAbsolute, to: now)
        record.steps += 1
        return record.judge.step(dt: dt, rate: rate, p: params, now: wall)
    }

    // MARK: - 편집

    /// 임계 편집. 다시 표본을 뜨지 않고(`source.table()` 을 부르지 않는다) 스냅숏 하나를
    /// 곧바로 낸다. 떨어진 폭주는 판정기의 반환값에서 와 그 스냅숏의 `cleared` 에 든다.
    public func apply(_ newParams: JudgeParams, wall: Date = Date()) -> WatchSnapshot {
        params = newParams
        var cleared: [ProcIdentity] = []
        for identity in records.keys.sorted(by: Self.identityOrder) {
            guard var record = records[identity] else { continue }
            if case .cleared? = record.judge.apply(newParams) { cleared.append(identity) }
            records[identity] = record
        }
        return makeSnapshot(wall: wall, tripped: [], cleared: cleared)
    }

    // MARK: - 스냅숏

    private func makeSnapshot(wall: Date, tripped: [ProcIdentity], cleared: [ProcIdentity]) -> WatchSnapshot {
        seq += 1

        var warming = 0
        var unmeasurable = 0
        var runawayRows: [ProcRowView] = []
        var watchedRows: [ProcRowView] = []
        for (identity, record) in records where record.judge.judged {
            let row = rowView(identity, record)
            switch row.state {
            case .warming: warming += 1
            case .unmeasurable: unmeasurable += 1
            case .measured: break
            }
            if record.judge.runaway {
                runawayRows.append(row)
            } else if record.judge.credit > 0 {
                // 「지켜보는 중」은 credit 이 쌓인 것만이다 — 메뉴 예시가 후손 41개 가운데
                // 1건을 보이듯, 쉬는 후손 전부를 이 목록에 싣지 않는다.
                watchedRows.append(row)
            }
        }
        runawayRows.sort { lhs, rhs in
            let l = lhs.ratePercent ?? -1, r = rhs.ratePercent ?? -1
            return l != r ? l > r : Self.identityOrder(lhs.identity, rhs.identity)
        }
        watchedRows.sort { lhs, rhs in
            lhs.creditSeconds != rhs.creditSeconds
                ? lhs.creditSeconds > rhs.creditSeconds
                : Self.identityOrder(lhs.identity, rhs.identity)
        }

        let rootRates = lastSets.claude.compactMap { records[$0]?.judge.rBar }
        let trippedRows = tripped.sorted(by: Self.identityOrder).compactMap { identity in
            records[identity].map { rowView(identity, $0) }
        }

        return WatchSnapshot(
            seq: seq,
            sampledAt: wall,
            rootCount: lastSets.claude.count,
            trackedCount: lastSets.judged.count,
            warmingCount: warming,
            unmeasurableCount: unmeasurable,
            clockUnitsSuspect: selfCheck.isSuspect,
            rootPeakPercent: rootRates.max().map { $0 * 100 },
            rootSumPercent: rootRates.reduce(0, +) * 100,
            runaway: Array(runawayRows.prefix(Self.rowLimit)),
            runawayTotal: runawayRows.count,
            topWatched: Array(watchedRows.prefix(Self.rowLimit)),
            watchedTotal: watchedRows.count,
            tripped: trippedRows,
            cleared: cleared.sorted(by: Self.identityOrder)
        )
    }

    private func rowView(_ identity: ProcIdentity, _ record: Record) -> ProcRowView {
        let state: RowState
        if record.unmeasurable {
            state = .unmeasurable
        } else if record.judge.rBar == nil {
            state = .warming
        } else {
            state = .measured
        }
        return ProcRowView(
            identity: identity,
            name: DisplayText.name(record.name),
            ancestry: DisplayText.ancestry(lastSets.ancestry[identity] ?? []),
            state: state,
            ratePercent: state == .measured ? record.judge.rBar.map { $0 * 100 } : nil,
            creditSeconds: record.judge.credit,
            runawaySince: record.judge.runawaySince
        )
    }

    // MARK: - 이름

    /// `basename(argv[0])` → 없으면 `p_comm` → 없으면 pid.
    private func displayName(for identity: ProcIdentity, row: ProcessRow?) -> String {
        if let existing = records[identity] { return existing.name }
        if let base = source.argv0BaseName(pid: identity.pid), !base.isEmpty { return base }
        if let comm = row?.comm, !comm.isEmpty { return comm }
        return "pid \(identity.pid)"
    }

    /// 조상 경로의 한 칸. claude 는 pid 를 붙여 여러 세션을 가른다.
    private func label(for identity: ProcIdentity, row: ProcessRow?, isClaude: Bool) -> String {
        isClaude ? "claude \(identity.pid)" : displayName(for: identity, row: row)
    }

    private static func identityOrder(_ lhs: ProcIdentity, _ rhs: ProcIdentity) -> Bool {
        (lhs.pid, lhs.startSec, lhs.startUsec) < (rhs.pid, rhs.startSec, rhs.startUsec)
    }

    // MARK: - 들여다보기

    /// 시험과 `--dump` 가 식별자별 상태를 읽는 자리.
    public struct Inspection: Sendable {
        public let rBar: Double?
        public let credit: Double
        public let runaway: Bool
        public let notified: Bool
        public let judged: Bool
        public let steps: Int
        public let name: String
        public let ancestry: [String]
    }

    public func inspect(_ identity: ProcIdentity) -> Inspection? {
        guard let record = records[identity] else { return nil }
        return Inspection(
            rBar: record.judge.rBar,
            credit: record.judge.credit,
            runaway: record.judge.runaway,
            notified: record.judge.notified,
            judged: record.judge.judged,
            steps: record.steps,
            name: record.name,
            ancestry: lastSets.ancestry[identity] ?? []
        )
    }

    public var trackedIdentities: Set<ProcIdentity> { Set(records.keys) }
    public var claudeIdentities: Set<ProcIdentity> { lastSets.claude }
    public var judgedIdentities: Set<ProcIdentity> { lastSets.judged }
    /// 분류기 캐시 크기. 1 만 개가 나고 죽어도 자라지 않는지 시험이 본다.
    public var classifierCacheCount: Int { classifier.cachedIdentityCount }
    public func settledVerdict(for identity: ProcIdentity) -> Bool? { classifier.settledVerdict(for: identity) }
}
