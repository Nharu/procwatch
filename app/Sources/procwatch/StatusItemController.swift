import AppKit
import ProcwatchCore

/// 상태 항목 하나가 앱의 유일한 UI 다. 그래서 끌어서 치울 수 없게 두고(`.removalAllowed`
/// 없음), 이미지 파생이 실패해도 항목 자체는 반드시 뜬다.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let fallbackSymbol = "exclamationmark.triangle"

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let builder: MenuBuilder
    private let frames: KiwiFrames?
    private var animator: KiwiAnimator?
    private var frameLayer: CALayer?

    private var snapshot: WatchSnapshot?
    private var runaway = false
    private var menuOpen = false
    private var visibilityObservation: NSKeyValueObservation?
    private var occlusionObserver: NSObjectProtocol?

    init(builder: MenuBuilder) {
        self.builder = builder
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "procwatch"

        do {
            frames = try KiwiFrames.load()
        } catch {
            frames = nil
            FileHandle.standardError.write(Data("procwatch: failed to derive kiwi images — \(error)\n".utf8))
        }
        super.init()

        builder.framesUnavailable = frames == nil
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly

        if frames != nil {
            let animator = KiwiAnimator { [weak self] index in self?.render(index) }
            self.animator = animator
            observeVisibility()
        } else {
            // 걸음과 빨강은 이 실행 동안 꺼지고, 판정과 알림은 그대로 돈다.
            let image = NSImage(systemSymbolName: Self.fallbackSymbol, accessibilityDescription: "procwatch")
            image?.isTemplate = true
            statusItem.button?.image = image
        }
    }

    /// 스냅숏 하나를 반영한다. 레벨은 에지로만 바뀐다 — `anyRunaway` 를 그대로 그린다.
    func apply(_ snapshot: WatchSnapshot) {
        self.snapshot = snapshot
        let red = snapshot.anyRunaway
        if red != runaway {
            runaway = red
            animator?.redraw()
        }
        animator?.update(peakPercent: snapshot.rootPeakPercent, rootCount: snapshot.rootCount)
        if menuOpen { builder.refresh(menu, with: snapshot) }
    }

    /// 표본 없이 걸음만 돌리는 디버그 경로(`debugSamplerPaused`).
    func walkWithoutSampler(peakPercent: Double) {
        animator?.update(peakPercent: peakPercent, rootCount: 1)
    }

    /// 걸음 멈춤을 애니메이터에 넘긴다. 키위 이미지가 없으면 아무 일도 하지 않는다.
    func setWalkPaused(_ paused: Bool) {
        animator?.setUserPaused(paused)
    }

    /// 배너를 누르면 드롭다운을 연다.
    func openMenu() {
        statusItem.button?.performClick(nil)
    }

    // MARK: - 그리기

    private func render(_ index: Int) {
        guard let frames, let button = statusItem.button else { return }
        let image: NSImage
        var tint: NSColor?
        switch (runaway, RedStyle.redMechanism) {
        case (false, _):
            image = frames.template[index]
        case (true, .imageSwap):
            image = frames.runaway[index]
        case (true, .contentTint):
            image = frames.template[index]
            tint = frames.runawayTint
        case (true, .glyphSwap):
            image = frames.glyph[index]
        }
        // 애니메이터는 매 프레임 이미지와 틴트를 둘 다 설정한다.
        button.contentTintColor = tint
        switch RedStyle.effectiveFrameSink {
        case .buttonImage:
            button.image = image
        case .layerContents:
            setLayerContents(image, on: button)
        }
    }

    /// 상태 버튼 레이어의 하위 `CALayer.contents` 교체. 외형이 바뀌면 이미지가 다시 해석된다.
    private func setLayerContents(_ image: NSImage, on button: NSStatusBarButton) {
        button.wantsLayer = true
        if frameLayer == nil, let host = button.layer {
            let layer = CALayer()
            layer.contentsGravity = .center
            layer.magnificationFilter = .nearest
            host.addSublayer(layer)
            frameLayer = layer
        }
        guard let layer = frameLayer else { return }
        if button.image == nil {
            // 폭을 잡아 둘 투명 자리표시.
            button.image = NSImage(size: KiwiFrames.pointSize)
        }
        layer.frame = button.bounds
        var appearanceImage: CGImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            var rect = CGRect(origin: .zero, size: KiwiFrames.pointSize)
            appearanceImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        layer.contentsScale = button.window?.backingScaleFactor ?? 2
        layer.contents = appearanceImage
    }

    // MARK: - 가시성

    private func observeVisibility() {
        visibilityObservation = statusItem.observe(\.isVisible, options: [.initial, .new]) { [weak self] item, _ in
            let visible = item.isVisible
            MainActor.assumeIsolated { self?.animator?.setItemVisible(visible) }
        }
        guard let window = statusItem.button?.window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                let visible = window?.occlusionState.contains(.visible) ?? true
                self?.animator?.setWindowVisible(visible)
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        builder.items(for: snapshot).forEach(menu.addItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        // 알림 권한은 메뉴를 열 때 다시 읽고 폴링하지 않는다. 읽기가 끝나면 알림 줄을 고친다.
        Task {
            await onMenuWillOpen?()
            if menuOpen { builder.refresh(menu, with: snapshot) }
        }
    }

    /// 메뉴가 열릴 때 부른다.
    var onMenuWillOpen: (() async -> Void)?
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
}
