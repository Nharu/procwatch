import AppKit
import os
import ProcwatchCore

/// 스냅숏 스트림의 소비자이자 표시·알림·설정을 잇는 자리.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    /// `debugSamplerPaused` 에서 걸음 타이머에 넣는 입력. 측정된 부하(1–6 %)의 빠르기다.
    static let pausedWalkPercent = 1.0

    private let settings = SettingsStore()
    private let notifier = Notifier()
    private lazy var loginItem = LoginItemController(settings: settings)
    private var statusItem: StatusItemController?
    private var engine: SamplerEngine?
    private var consumer: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 대리자를 여기서 세워 알림 클릭으로 뜬 실행도 받는다.
        notifier.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loginItem.reconcileAtLaunch()

        let builder = MenuBuilder(settings: settings, loginItem: loginItem, notifier: notifier)
        builder.onCustomThreshold = { [weak self] in self?.promptThreshold() }
        builder.onCustomSustain = { [weak self] in self?.promptSustain() }
        let statusItem = StatusItemController(builder: builder)
        statusItem.onMenuWillOpen = { [notifier] in await notifier.refreshAuthorization() }
        self.statusItem = statusItem
        notifier.onActivate = { [weak statusItem] in statusItem?.openMenu() }

        let engine = SamplerEngine(
            source: SystemProcessSource(),
            clock: SystemMonotonicClock(),
            params: settings.params,
            tickObserver: settings.debugTickLog ? Self.logTick : nil
        )
        self.engine = engine
        settings.onThresholdsChange = { params in
            // 읽는 시점에 재평가하고 곧바로 게시한다. 그 스냅숏은 스트림으로 온다.
            Task { await engine.apply(params) }
        }

        consumer = Task { [weak self] in
            for await snapshot in engine.snapshots {
                self?.handle(snapshot)
            }
        }

        if settings.debugSamplerPaused {
            statusItem.walkWithoutSampler(peakPercent: Self.pausedWalkPercent)
        } else {
            Task { await engine.start() }
        }
    }

    private func handle(_ snapshot: WatchSnapshot) {
        statusItem?.apply(snapshot)
        notifier.handle(snapshot)
    }

    // MARK: - 틱 시각 로그

    private nonisolated static let tickLogger = Logger(subsystem: "io.github.nharu.procwatch", category: "tick")

    private nonisolated static let logTick: @Sendable (TickRecord) -> Void = { record in
        let dt = record.dtSec.map { String(format: "%.3f", $0) } ?? "-"
        tickLogger.debug("""
            tick abs=\(record.absolute, privacy: .public) \
            wall=\(record.wall.timeIntervalSince1970, privacy: .public) \
            dtSec=\(dt, privacy: .public) next=\(record.nextInterval, privacy: .public)
            """)
    }

    // MARK: - 직접 입력

    private func promptThreshold() {
        let range = ThresholdSettings.cpuThresholdRange
        guard let value = CustomValuePrompt.ask(
            title: "CPU 임계값 직접 입력",
            message: "\(range.lowerBound)–\(range.upperBound) % (코어 1개 = 100%)",
            range: range,
            current: settings.thresholds.cpuThresholdPercent
        ) else { return }
        var thresholds = settings.thresholds
        thresholds.cpuThresholdPercent = value
        settings.thresholds = thresholds
    }

    private func promptSustain() {
        let range = ThresholdSettings.sustainMinutesRange
        guard let value = CustomValuePrompt.ask(
            title: "지속 시간 직접 입력",
            message: "\(range.lowerBound)–\(range.upperBound) 분",
            range: range,
            current: settings.thresholds.sustainMinutes
        ) else { return }
        var thresholds = settings.thresholds
        thresholds.sustainMinutes = value
        settings.thresholds = thresholds
    }
}
