import AppKit
import ProcwatchCore
@preconcurrency import UserNotifications

/// 폭주 에지를 배너로 알린다. 받는 것은 스냅숏의 `tripped`·`cleared` 에지뿐이고 판정
/// 상태를 기억하지 않는다. 갖는 것은 요청 id → 식별자 집합 지도와 게시하지 못한 배너의
/// 식별자 집합 둘이다.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let threadIdentifier = "runaway"
    static let settingsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.nharu.procwatch"
    static let settingsFallbackURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    /// 번들 식별자가 없는 프로세스에서 `UNUserNotificationCenter.current()` 를 부르면 잡을
    /// 수 없는 예외로 죽으므로, 번들로 뜬 경우에만 닿는다.
    private let center: UNUserNotificationCenter?
    /// 요청 id → 아직 `cleared` 되지 않은 식별자.
    private var outstanding: [String: Set<ProcIdentity>] = [:]
    /// 권한 미정이나 `center.add` 실패로 게시하지 못한 식별자. `runaway` 행에 다시 보이면
    /// 게시를 다시 시도한다.
    private var undelivered = UndeliveredBanners()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// 배너를 누르면 드롭다운을 연다.
    var onActivate: (() -> Void)?

    override init() {
        center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
    }

    var enabled: Bool {
        authorization == .authorized || authorization == .provisional
    }

    /// `applicationWillFinishLaunching` 에서 부른다. 대리자를 먼저 세워 알림 클릭으로 뜬
    /// 실행도 받고, 그 직후 이전 실행이 남긴 폭주 배너를 걷어낸다 — 제거 규칙은 메모리에만
    /// 있는 지도에 기대므로, 이 청소가 없으면 그 배너를 지울 주체가 영구히 없다.
    func install() {
        guard let center else { return }
        center.delegate = self
        Task {
            let delivered = await center.deliveredNotifications()
            let stale = delivered
                .filter { $0.request.content.threadIdentifier == Self.threadIdentifier }
                .map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }

            await refreshAuthorization()
            if authorization == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                await refreshAuthorization()
            }
        }
    }

    /// 권한 상태는 메뉴를 열 때와 게시 직전에 다시 읽고 폴링하지 않는다.
    func refreshAuthorization() async {
        guard let center else {
            authorization = .denied
            return
        }
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// 스냅숏 하나의 에지를 처리한다.
    func handle(_ snapshot: WatchSnapshot) {
        if !snapshot.cleared.isEmpty { remove(cleared: snapshot.cleared) }
        let rows = undelivered.takeAttempt(from: snapshot)
        guard !rows.isEmpty else { return }
        let seq = snapshot.seq
        let sustainSeconds = rows.map(\.creditSeconds)
        Task {
            await refreshAuthorization()
            // 권한이 없으면 게시를 건너뛰고 빨간 키위가 레벨 신호를 계속 진다. 거부면 미배달을
            // 버리고, 아직 정해지지 않았으면 다음 스냅숏에서 다시 시도하도록 되돌린다.
            guard enabled, let center else {
                if authorization == .denied { undelivered.discardAll() } else { undelivered.putBack(rows) }
                return
            }
            let identifier = rows.count == 1
                ? "runaway-\(rows[0].identity.notificationSuffix)"
                : "runaway-batch-\(seq)"
            let content = UNMutableNotificationContent()
            content.title = L("notification.title")
            content.body = Self.body(rows, sustainSeconds: sustainSeconds)
            content.threadIdentifier = Self.threadIdentifier
            content.interruptionLevel = .active
            content.sound = .default
            outstanding[identifier] = Set(rows.map(\.identity))
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                undelivered.putBack(rows)
            }
        }
    }

    /// 요청에 묶인 식별자가 모두 `cleared` 되면 전달된 배너를 한 번 지운다.
    private func remove(cleared: [ProcIdentity]) {
        var finished: [String] = []
        for (identifier, members) in outstanding {
            let remaining = members.subtracting(cleared)
            if remaining.isEmpty {
                finished.append(identifier)
            } else {
                outstanding[identifier] = remaining
            }
        }
        guard !finished.isEmpty else { return }
        finished.forEach { outstanding[$0] = nil }
        center?.removeDeliveredNotifications(withIdentifiers: finished)
    }

    /// 「python3 (pid 1234) — CPU 98%, 32분째 · claude 12345 아래」, 여럿이면 「외 N건」.
    static func body(_ rows: [ProcRowView], sustainSeconds: [Double]) -> String {
        guard let first = rows.first else { return "" }
        let cpu = first.ratePercent.map { String(format: "CPU %.0f%%", $0) } ?? L("notification.cpuUnmeasurable")
        let minutes = Int((sustainSeconds.first ?? 0) / 60)
        var text = L("notification.body", first.name, Int(first.identity.pid), cpu, minutes)
        if let root = first.ancestry.first { text += L("notification.under", root) }
        if rows.count > 1 { text += L("notification.more", rows.count - 1) }
        return text
    }

    /// 거부 경로의 메뉴 줄이 부른다. `?id=` 형태가 실패하면 없는 형태로 연다.
    static func openSettings() {
        if let url = URL(string: settingsURL), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: settingsFallbackURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { self.onActivate?() }
    }
}
