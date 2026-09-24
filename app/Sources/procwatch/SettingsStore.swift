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
    }

    private let defaults: UserDefaults

    /// 임계가 바뀌면 부른다. 엔진에 새 불변 설정을 넣는 자리다.
    var onThresholdsChange: ((JudgeParams) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var registration = ThresholdSettings.registrationDefaults
        registration[Key.launchAtLoginDesired] = true
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
