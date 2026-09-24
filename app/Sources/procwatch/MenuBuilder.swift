import AppKit
import ProcwatchCore

/// 드롭다운의 항목들을 최신 스냅숏에서 만든다. 메뉴는 `menuNeedsUpdate` 에서 다시 만들고,
/// 열려 있는 동안에는 구조가 같으면 제목만 제자리에서 고친다.
@MainActor
final class MenuBuilder: NSObject {
    static let thresholdPresets = [25, 50, 75, 100, 150, 200]
    static let sustainPresets = [5, 10, 15, 30, 60, 120]

    private let settings: SettingsStore
    private let loginItem: LoginItemController
    private let notifier: Notifier
    /// 파생이 실패해 대체 아이콘으로 떠 있는가.
    var framesUnavailable = false
    /// 「직접 입력…」이 부른다.
    var onCustomThreshold: (() -> Void)?
    var onCustomSustain: (() -> Void)?

    init(settings: SettingsStore, loginItem: LoginItemController, notifier: Notifier) {
        self.settings = settings
        self.loginItem = loginItem
        self.notifier = notifier
    }

    // MARK: - 조립

    func items(for snapshot: WatchSnapshot?, now: Date = Date()) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if framesUnavailable { items.append(info("키위 이미지를 읽지 못함 — 감시는 정상")) }

        items.append(info(Self.headline(snapshot)))
        if let snapshot {
            items.append(info(Self.rootCPULine(snapshot)))
            if snapshot.unmeasurableCount > 0 {
                items.append(info("측정 불가 후손 \(snapshot.unmeasurableCount)개"))
            }
            if snapshot.clockUnitsSuspect {
                items.append(info("시간 단위 이상 — 판정이 틀릴 수 있음"))
            }
        }

        items.append(.separator())
        if let snapshot {
            let d = settings.params.d
            if snapshot.runawayTotal > 0 {
                items.append(info("폭주 \(snapshot.runawayTotal)건"))
                for row in snapshot.runaway {
                    items.append(processItem(Self.runawayTitle(row, d: d, now: now), row: row))
                }
                if snapshot.runawayTotal > snapshot.runaway.count {
                    items.append(info("   외 \(snapshot.runawayTotal - snapshot.runaway.count)건"))
                }
            }
            if snapshot.watchedTotal > 0 {
                items.append(info("지켜보는 중 \(snapshot.watchedTotal)건"))
                for row in snapshot.topWatched {
                    items.append(processItem(Self.watchedTitle(row, d: d), row: row))
                }
                if snapshot.watchedTotal > snapshot.topWatched.count {
                    items.append(info("   외 \(snapshot.watchedTotal - snapshot.topWatched.count)건"))
                }
            }
            if snapshot.runawayTotal > 0 || snapshot.watchedTotal > 0 { items.append(.separator()) }
        }

        items.append(contentsOf: settingsItems())
        items.append(.separator())
        if !framesUnavailable { items.append(walkPauseItem()) }
        items.append(contentsOf: loginItems())
        items.append(notificationItem())
        items.append(.separator())
        items.append(info(Self.versionLine()))
        let quit = NSMenuItem(title: "procwatch 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        items.append(quit)
        return items
    }

    /// 열려 있는 메뉴를 고친다. 항목 구조(개수와 종류)가 같으면 제목만 바꾸고, 다르면
    /// 통째로 갈아 끼운다.
    func refresh(_ menu: NSMenu, with snapshot: WatchSnapshot?) {
        let fresh = items(for: snapshot)
        let sameShape = fresh.count == menu.items.count && zip(fresh, menu.items).allSatisfy { new, old in
            new.isSeparatorItem == old.isSeparatorItem && new.hasSubmenu == old.hasSubmenu
                && new.action == old.action && new.isEnabled == old.isEnabled
        }
        if sameShape {
            for (new, old) in zip(fresh, menu.items) where !new.isSeparatorItem {
                if old.title != new.title { old.title = new.title }
                if let attributed = new.attributedTitle { old.attributedTitle = attributed }
                old.state = new.state
                old.representedObject = new.representedObject
            }
        } else {
            menu.removeAllItems()
            fresh.forEach(menu.addItem)
        }
    }

    // MARK: - 문면

    /// 첫 줄은 `rootCount` 와 `trackedCount` 둘로 고른다 — sticky 고아만 남은 상태는
    /// 설계가 의도한 정상 상태라, 그때 「대기 중」이라고 말하면 폭주 목록과 모순된다.
    static func headline(_ snapshot: WatchSnapshot?) -> String {
        guard let snapshot else { return "시작 중…" }
        switch (snapshot.rootCount, snapshot.trackedCount) {
        case (0, 0): return "claude 프로세스 없음 — 대기 중"
        case (0, let tracked): return "claude 없음 · 후손 \(tracked)개 계속 감시 중"
        case (let roots, let tracked): return "claude \(roots)개 · 후손 \(tracked)개 감시 중"
        }
    }

    static func rootCPULine(_ snapshot: WatchSnapshot) -> String {
        guard let peak = snapshot.rootPeakPercent else { return "claude CPU 측정 중…" }
        return String(format: "claude 최고 CPU %.0f%% · 합계 %.0f%%", peak, snapshot.rootSumPercent)
    }

    static func cpuText(_ row: ProcRowView) -> String {
        switch row.state {
        case .warming: return "측정 중…"
        case .unmeasurable: return "측정 불가"
        case .measured: return String(format: "CPU %.0f%%", row.ratePercent ?? 0)
        }
    }

    /// 「python3 · pid 1234 · CPU 98% · 42분째」. 경과는 보고 기준 `D` 에 폭주로 넘어간
    /// 뒤의 시간을 더한 값이다.
    static func runawayTitle(_ row: ProcRowView, d: Double, now: Date) -> String {
        let since = row.runawaySince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let minutes = Int((d + since) / 60)
        return "   \(row.name) · pid \(row.identity.pid) · \(cpuText(row)) · \(minutes)분째"
    }

    /// 「node · pid 555 · CPU 71% · 12/30분」.
    static func watchedTitle(_ row: ProcRowView, d: Double) -> String {
        "   \(row.name) · pid \(row.identity.pid) · \(cpuText(row)) · \(Int(row.creditSeconds / 60))/\(Int(d / 60))분"
    }

    static func versionLine() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info["CFBundleVersion"] as? String ?? "개발"
        return "procwatch \(short) (빌드 \(build))"
    }

    /// 드롭다운 도움말. `D` 자리에 현재 지속 시간을 넣는다.
    static func helpText(sustainMinutes: Int) -> String {
        [
            "프로세스의 평활 CPU가 임계 이상인 깨어 있는 초가",
            "임계 미만인 초보다 순으로 \(sustainMinutes)분 많아지면 보고한다.",
            "임계 미만인 1초가 임계 이상인 1초를 갚는다.",
            "임계의 80 % 아래로 2분 연속 가라앉거나, 보고 기준의 절반까지",
            "갚거나, 끝나면 해소된다. 배너는 프로세스마다 한 번이다.",
            "예: 늘 바쁨 → 30분에 보고. 15분 블록으로 75 % → 50분.",
            "12분 블록으로 60 % → 110분. 긴 블록으로 정확히 절반 → 보고 안 함.",
        ].joined(separator: "\n")
    }

    // MARK: - 항목

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 클릭하면 pid 를 클립보드로 복사한다.
    private func processItem(_ title: String, row: ProcRowView) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyPID(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Int(row.identity.pid)
        item.toolTip = row.ancestry.joined(separator: " › ")
        return item
    }

    @objc private func copyPID(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(pid), forType: .string)
    }

    private func settingsItems() -> [NSMenuItem] {
        let current = settings.thresholds

        let threshold = NSMenuItem(title: "CPU 임계값: \(current.cpuThresholdPercent)%", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for value in Self.thresholdPresets {
            let item = NSMenuItem(title: "\(value)%", action: #selector(pickThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = value == current.cpuThresholdPercent ? .on : .off
            thresholdMenu.addItem(item)
        }
        if !Self.thresholdPresets.contains(current.cpuThresholdPercent) {
            let custom = NSMenuItem(title: "사용자 지정: \(current.cpuThresholdPercent)%", action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            thresholdMenu.addItem(custom)
        }
        thresholdMenu.addItem(.separator())
        let customThreshold = NSMenuItem(title: "직접 입력…", action: #selector(customThreshold(_:)), keyEquivalent: "")
        customThreshold.target = self
        thresholdMenu.addItem(customThreshold)
        thresholdMenu.addItem(info("코어 1개 = 100%"))
        threshold.submenu = thresholdMenu

        let sustain = NSMenuItem(title: "지속 시간: \(current.sustainMinutes)분", action: nil, keyEquivalent: "")
        let sustainMenu = NSMenu()
        for value in Self.sustainPresets {
            let item = NSMenuItem(title: "\(value)분", action: #selector(pickSustain(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = value == current.sustainMinutes ? .on : .off
            sustainMenu.addItem(item)
        }
        if !Self.sustainPresets.contains(current.sustainMinutes) {
            let custom = NSMenuItem(title: "사용자 지정: \(current.sustainMinutes)분", action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            sustainMenu.addItem(custom)
        }
        sustainMenu.addItem(.separator())
        let customSustain = NSMenuItem(title: "직접 입력…", action: #selector(customSustain(_:)), keyEquivalent: "")
        customSustain.target = self
        sustainMenu.addItem(customSustain)
        sustain.submenu = sustainMenu

        let help = info("판정 기준 설명")
        help.attributedTitle = NSAttributedString(
            string: Self.helpText(sustainMinutes: current.sustainMinutes),
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]
        )
        return [threshold, sustain, help]
    }

    @objc private func pickThreshold(_ sender: NSMenuItem) {
        var value = settings.thresholds
        value.cpuThresholdPercent = sender.tag
        settings.thresholds = value
    }

    @objc private func pickSustain(_ sender: NSMenuItem) {
        var value = settings.thresholds
        value.sustainMinutes = sender.tag
        settings.thresholds = value
    }

    @objc private func customThreshold(_ sender: NSMenuItem) { onCustomThreshold?() }
    @objc private func customSustain(_ sender: NSMenuItem) { onCustomSustain?() }

    /// 체크가 켜져 있으면 키위가 걷지 않는다. 감시·판정·알림은 그대로다.
    private func walkPauseItem() -> NSMenuItem {
        let item = NSMenuItem(title: "걸음 애니메이션 멈춤", action: #selector(toggleWalkPaused(_:)), keyEquivalent: "")
        item.target = self
        item.state = settings.walkPaused ? .on : .off
        return item
    }

    @objc private func toggleWalkPaused(_ sender: NSMenuItem) { settings.walkPaused.toggle() }

    private func loginItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        switch loginItem.presentation {
        case .unavailable:
            items.append(info("로그인 시 자동 실행 (/Applications 에 설치하면 사용 가능)"))
        case .toggle(let state):
            let toggle = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin(_:)), keyEquivalent: "")
            toggle.target = self
            toggle.state = state
            items.append(toggle)
        }
        if let failure = loginItem.failureLine { items.append(info(failure)) }
        return items
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) { loginItem.toggle() }

    private func notificationItem() -> NSMenuItem {
        if notifier.enabled { return info("알림: 켜짐") }
        let item = NSMenuItem(title: "알림 꺼짐 — 알림 설정 열기…", action: #selector(openNotificationSettings(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openNotificationSettings(_ sender: NSMenuItem) { Notifier.openSettings() }
}
