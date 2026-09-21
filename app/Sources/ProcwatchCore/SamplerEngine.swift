import Dispatch
import Foundation

/// 판정에 쓰이는 가변 상태의 유일한 소유자.
///
/// 실행자는 `.utility` QoS 의 직렬 큐이고, 같은 큐 위의 `DispatchSourceTimer` 가
/// `assumeIsolated` 로 틱을 동기 실행한다. `tick` 안에는 `await` 가 없으므로 재진입이
/// 생기지 않고 틱이 쌓이지 않는다. `tickNow()` 도 깨어남 알림 구독도 없다 —
/// `DispatchTime` 기한은 가동 시간 시계로 돌아 잠자기 동안 울리지 않는다.
public actor SamplerEngine {
    private let queue: DispatchSerialQueue
    private let core: SamplerCore
    private let continuation: AsyncStream<WatchSnapshot>.Continuation
    private let tickObserver: (@Sendable (TickRecord) -> Void)?
    private var timer: DispatchSourceTimer?
    private var scheduledInterval: Double?

    /// 스냅숏 스트림. 에지를 잃지 않도록 `.unbounded` 다.
    public nonisolated let snapshots: AsyncStream<WatchSnapshot>

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// 타이머 leeway 는 주기의 이 비율이다.
    public static let leewayFraction = 0.1

    public init(
        source: any ProcessSource,
        clock: any MonotonicClock,
        params: JudgeParams,
        tickObserver: (@Sendable (TickRecord) -> Void)? = nil
    ) {
        self.queue = DispatchSerialQueue(label: "procwatch.sampler", qos: .utility)
        self.core = SamplerCore(source: source, clock: clock, params: params)
        self.tickObserver = tickObserver
        (self.snapshots, self.continuation) = AsyncStream.makeStream(
            of: WatchSnapshot.self,
            bufferingPolicy: .unbounded
        )
    }

    /// 표본 타이머를 건다. 첫 틱은 곧바로 돈다.
    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.assumeIsolated { engine in _ = engine.tick() }
        }
        timer = source
        schedule(interval: core.nextInterval, firstAfter: 0)
        source.resume()
    }

    /// 한 틱. 테이블 읽기가 실패한 틱은 게시하지 않는다. 시험은 이것을 직접 부른다.
    @discardableResult
    public func tick() -> WatchSnapshot? {
        guard let (snapshot, record) = core.tick() else { return nil }
        continuation.yield(snapshot)
        tickObserver?(record)
        if timer != nil, scheduledInterval != record.nextInterval {
            // 주기가 바뀔 때만 타이머를 다시 건다.
            schedule(interval: record.nextInterval, firstAfter: record.nextInterval)
        }
        return snapshot
    }

    /// 임계 편집. 읽는 시점에 재평가하고 표본 없이 스냅숏 하나를 곧바로 게시한다.
    @discardableResult
    public func apply(_ params: JudgeParams) -> WatchSnapshot {
        let snapshot = core.apply(params)
        continuation.yield(snapshot)
        return snapshot
    }

    public var nextInterval: Double { core.nextInterval }
    public var timerInterval: Double? { scheduledInterval }

    /// 시험이 식별자별 상태를 읽는 자리.
    public func inspect(_ identity: ProcIdentity) -> SamplerCore.Inspection? { core.inspect(identity) }
    public var trackedIdentities: Set<ProcIdentity> { core.trackedIdentities }
    public var classifierCacheCount: Int { core.classifierCacheCount }
    public func settledVerdict(for identity: ProcIdentity) -> Bool? { core.settledVerdict(for: identity) }

    private func schedule(interval: Double, firstAfter delay: Double) {
        scheduledInterval = interval
        let nanoseconds = Int(interval * 1e9)
        timer?.schedule(
            deadline: .now() + delay,
            repeating: .nanoseconds(nanoseconds),
            leeway: .nanoseconds(Int(Double(nanoseconds) * Self.leewayFraction))
        )
    }

    deinit {
        timer?.cancel()
        continuation.finish()
    }
}
