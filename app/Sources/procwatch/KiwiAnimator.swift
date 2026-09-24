import AppKit
import ProcwatchCore

/// 걸음 프레임 타이머. main 큐의 `DispatchSourceTimer`(leeway 15 %)라 메뉴 추적 중에도
/// 울린다. 기본 모드 `Timer` 는 그때 멈춘다.
///
/// 갖는 상태(현재 fps 와 프레임 인덱스)는 스냅숏에서 파생될 뿐 엔진으로 돌아가지 않는다.
@MainActor
final class KiwiAnimator {
    static let leewayFraction = 0.15

    /// 프레임 인덱스 하나를 그리는 자리. 빨강 여부는 그리는 쪽이 안다.
    var render: (Int) -> Void

    private(set) var conditions = WalkPace.Conditions()
    private(set) var frameIndex = 0
    private(set) var fps: Int?
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private let timer: DispatchSourceTimer
    private var timerRunning = false
    private var observers: [NSObjectProtocol] = []

    init(render: @escaping (Int) -> Void) {
        self.render = render
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.advance() }
        }
        observeSystem()
        render(0)                                     // 시작 상태는 서 있음
    }

    /// 스냅숏이 들어올 때마다 부른다.
    func update(peakPercent: Double?, rootCount: Int) {
        conditions.peakPercent = peakPercent
        conditions.rootCount = rootCount
        reevaluate()
    }

    func setItemVisible(_ visible: Bool) {
        conditions.itemVisible = visible
        reevaluate()
    }

    func setWindowVisible(_ visible: Bool) {
        conditions.windowVisible = visible
        reevaluate()
    }

    /// 사용자 멈춤. 켜면 `stop()` 이 타이머를 멈추고 프레임 00 을 그린다.
    func setUserPaused(_ paused: Bool) {
        conditions.userPaused = paused
        reevaluate()
    }

    /// 빨강이 바뀌었을 때처럼 같은 프레임을 다시 그려야 할 때.
    func redraw() { render(frameIndex) }

    // MARK: - 내부

    private func reevaluate() {
        guard conditions.walking, let peak = conditions.peakPercent else {
            stop()
            return
        }
        let next = WalkPace.fps(peakPercent: peak, lowPower: lowPower)
        guard next != fps || !timerRunning else { return }   // 정수 fps 가 바뀔 때만 다시 건다
        fps = next
        let period = 1.0 / Double(next)
        let nanoseconds = Int(period * 1e9)
        timer.schedule(
            deadline: .now() + period,
            repeating: .nanoseconds(nanoseconds),
            leeway: .nanoseconds(Int(Double(nanoseconds) * Self.leewayFraction))
        )
        if !timerRunning {
            timer.resume()
            timerRunning = true
        }
    }

    /// 걷지 않을 때는 `suspend()` 로 멈추고 프레임 00(서 있음)을 보인다.
    private func stop() {
        if timerRunning {
            timer.suspend()
            timerRunning = false
        }
        fps = nil
        frameIndex = 0
        render(0)
    }

    private func advance() {
        frameIndex = (frameIndex + 1) % KiwiFrames.frameCount
        render(frameIndex)
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, @Sendable (inout WalkPace.Conditions) -> Void)] = [
            (NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.systemAsleep = false }),
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true }),
        ]
        for (name, change) in pairs {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(&self.conditions)
                    self.reevaluate()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.reevaluate()
            }
        })
    }
}
