import AppKit
import ProcwatchCore

/// 사용자 테마 폴더와 지금 설정으로 프레임 세트를 고르는 자리. 판정은 Core 가 하고,
/// 여기서는 `NSImage` 를 붙이고 폴백을 정한다.
@MainActor
final class ThemeLibrary {
    /// 테마 하위 메뉴의 항목 하나.
    struct Item {
        let name: String
        /// 읽을 수 없는 테마는 썸네일이 없다.
        let thumbnail: NSImage?
        let readable: Bool
    }

    /// 고른 설정으로 만든 결과.
    struct Resolution {
        /// nil 이면 키위까지 읽지 못해 경고 기호를 꽂는다.
        let frames: KiwiFrames?
        /// 고른 테마를 읽지 못해 키위로 물러났으면 그 이름.
        let failedTheme: String?
    }

    /// `~/Library/Application Support/procwatch/themes/`.
    let themesDirectory: URL
    private let bundle: Bundle

    /// 메뉴를 열 때마다 쓰므로 한 번만 만든다.
    private(set) lazy var kiwiThumbnail: NSImage? = KiwiFrames.kiwiThumbnail(bundle: bundle)

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        themesDirectory = support.appendingPathComponent("procwatch/themes", isDirectory: true)
    }

    /// 테마 폴더를 지금 다시 읽어 판정한 목록.
    func items() -> [Item] {
        ThemeCatalog.list(root: themesDirectory).map { entry in
            switch entry.result {
            case .success(let set):
                return Item(name: entry.name, thumbnail: KiwiFrames.thumbnail(set), readable: true)
            case .failure:
                return Item(name: entry.name, thumbnail: nil, readable: false)
            }
        }
    }

    /// 폴백 순서는 사용자 테마 → 같은 높이 설정의 번들 키위 → 경고 기호다.
    func resolve(_ appearance: SettingsStore.IconAppearance) -> Resolution {
        var failedTheme: String?
        if let name = appearance.theme {
            switch ThemeCatalog.judge(root: themesDirectory, name: name) {
            case .success(let set):
                let height = appearance.height.points(isKiwi: false)
                return Resolution(frames: KiwiFrames.theme(set, height: height, outline: appearance.outline),
                                  failedTheme: nil)
            case .failure(let problem):
                FileHandle.standardError.write(Data("procwatch: failed to load theme \(name) — \(problem)\n".utf8))
                failedTheme = name
            }
        }
        do {
            let frames = try KiwiFrames.load(bundle: bundle, height: appearance.height.points(isKiwi: true))
            return Resolution(frames: frames, failedTheme: failedTheme)
        } catch {
            FileHandle.standardError.write(Data("procwatch: failed to derive kiwi images — \(error)\n".utf8))
            return Resolution(frames: nil, failedTheme: failedTheme)
        }
    }

    /// 테마 폴더가 없으면 만들고 Finder 로 연다.
    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("procwatch: failed to create themes folder — \(error)\n".utf8))
            return
        }
        NSWorkspace.shared.open(themesDirectory)
    }
}
