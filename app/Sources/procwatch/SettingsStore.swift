import Foundation
import ProcwatchCore

/// `UserDefaults.standard`(도메인 = 번들 id) 위의 설정. 폭주 상태는 저장하지 않는다.
@MainActor
final class SettingsStore {
    enum Key {
        static let launchAtLoginDesired = "launchAtLoginDesired"
        static let launchAtLoginRegisteredBuild = "launchAtLoginRegisteredBuild"
        /// 켜져 있으면 틱마다 시각을 `os_log` 디버그 수준으로 찍는다.
        static let debugTickLog = "debugTickLog"
        /// 켜져 있으면 표본 타이머를 걸지 않고 걸음 타이머만 둔다.
        static let debugSamplerPaused = "debugSamplerPaused"
        /// 켜져 있으면 키위가 걷지 않고 프레임 00 으로 서 있는다.
        static let walkPaused = "walkPaused"
        /// 사용자 테마 폴더 이름. 없거나 빈 문자열이면 번들 키위를 쓴다.
        static let theme = "theme"
        /// 아이콘 높이(pt). `0` 은 테마마다 지금 높이를 쓰는 `기본` 이다.
        static let iconHeight = "iconHeight"
        /// 어두운 막대에서 컬러 테마에 밝은 외곽선을 그린다.
        static let themeOutline = "themeOutline"
    }

    /// 아이콘 모양을 정하는 설정 셋.
    struct IconAppearance: Equatable {
        /// 고른 테마 폴더 이름. nil 이면 키위다.
        var theme: String?
        var height: IconHeight
        var outline: Bool
    }

    private let defaults: UserDefaults

    /// 임계가 바뀌면 부른다. 엔진에 새 불변 설정을 넣는 자리다.
    var onThresholdsChange: ((JudgeParams) -> Void)?
    /// 걸음 멈춤이 바뀌면 부른다.
    var onWalkPausedChange: ((Bool) -> Void)?
    /// 테마·아이콘 높이·외곽선 가운데 하나가 바뀌면 부른다.
    var onIconAppearanceChange: ((IconAppearance) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var registration = ThresholdSettings.registrationDefaults
        registration[Key.launchAtLoginDesired] = true
        registration[Key.walkPaused] = false
        registration[Key.iconHeight] = 0
        registration[Key.themeOutline] = false
        defaults.register(defaults: registration)
    }

    // MARK: - 임계

    /// 읽는 시점에 범위로 잘라낸다.
    var thresholds: ThresholdSettings {
        get { ThresholdSettings(defaults: defaults) }
        set {
            newValue.write(to: defaults)
            onThresholdsChange?(JudgeParams(settings: thresholds))
        }
    }

    var params: JudgeParams { JudgeParams(settings: thresholds) }

    // MARK: - 걸음

    /// 사용자가 끌 때까지, 재시작 뒤에도 유지된다.
    var walkPaused: Bool {
        get { defaults.bool(forKey: Key.walkPaused) }
        set {
            defaults.set(newValue, forKey: Key.walkPaused)
            onWalkPausedChange?(newValue)
        }
    }

    // MARK: - 아이콘 모양

    var iconAppearance: IconAppearance {
        IconAppearance(theme: theme, height: iconHeight, outline: themeOutline)
    }

    var theme: String? {
        guard let name = defaults.string(forKey: Key.theme), !name.isEmpty else { return nil }
        return name
    }

    /// nil 이면 키를 지워 키위로 돌아간다.
    func setTheme(_ name: String?) {
        if let name, !name.isEmpty {
            defaults.set(name, forKey: Key.theme)
        } else {
            defaults.removeObject(forKey: Key.theme)
        }
        onIconAppearanceChange?(iconAppearance)
    }

    var iconHeight: IconHeight {
        get { IconHeight(stored: defaults.integer(forKey: Key.iconHeight)) }
        set {
            defaults.set(newValue.storedValue, forKey: Key.iconHeight)
            onIconAppearanceChange?(iconAppearance)
        }
    }

    var themeOutline: Bool {
        get { defaults.bool(forKey: Key.themeOutline) }
        set {
            defaults.set(newValue, forKey: Key.themeOutline)
            onIconAppearanceChange?(iconAppearance)
        }
    }

    // MARK: - 로그인 항목

    /// 사용자의 의도. 실제 상태는 `SMAppService.status` 이며 복제하지 않는다.
    var launchAtLoginDesired: Bool {
        get { defaults.bool(forKey: Key.launchAtLoginDesired) }
        set { defaults.set(newValue, forKey: Key.launchAtLoginDesired) }
    }

    /// 마지막으로 `register()` 가 성공한 `CFBundleVersion`. 진단·표시 전용이며 맞추기
    /// 규칙의 조건에 쓰지 않는다.
    var launchAtLoginRegisteredBuild: String? {
        get { defaults.string(forKey: Key.launchAtLoginRegisteredBuild) }
        set { defaults.set(newValue, forKey: Key.launchAtLoginRegisteredBuild) }
    }

    // MARK: - 디버그

    var debugTickLog: Bool { defaults.bool(forKey: Key.debugTickLog) }
    var debugSamplerPaused: Bool { defaults.bool(forKey: Key.debugSamplerPaused) }
}
