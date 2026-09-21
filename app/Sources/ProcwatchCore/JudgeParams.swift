import Foundation

/// 판정기 매개변수. 사용자가 고치는 것은 `T_hi` 와 `D` 둘뿐이고 나머지는 거기서 나온다.
public struct JudgeParams: Sendable, Equatable {
    /// credit 게이트 `R̄ ≥ T_hi`. 1.0 이 코어 하나다.
    public let tHi: Double
    /// 폭주 판정까지의 순증 credit(깨어 있는 초).
    public let d: Double

    /// 해제 쪽 진정 문턱에만 쓴다.
    public var tLo: Double { 0.8 * tHi }
    /// EMA 시정수(깨어 있는 초).
    public var tau: Double { Self.tau }
    /// credit 상한.
    public var cap: Double { 1.5 * d }
    /// 폭주 중 credit 이 이보다 작아지면 해소(「상환」).
    public var release: Double { 0.5 * d }
    /// `R̄ < T_lo` 가 연속으로 이만큼이면 해소(「진정」).
    public var rClear: Double { Self.rClear }

    public static let tau = 30.0
    public static let rClear = 120.0

    public init(tHi: Double, d: Double) {
        precondition(tHi > 0, "T_hi 는 양수여야 한다")
        precondition(d >= 60, "D 는 60 s 이상이어야 한다")
        self.tHi = tHi
        self.d = d
    }

    /// 사용자 설정 단위(% 와 분)에서 만든다. 범위 밖 값은 읽을 때 잘라낸다.
    public init(settings: ThresholdSettings) {
        let clamped = settings.clamped
        self.init(tHi: Double(clamped.cpuThresholdPercent) / 100,
                  d: Double(clamped.sustainMinutes) * 60)
    }

    public static let `default` = JudgeParams(settings: .default)
}

/// `UserDefaults` 에 저장되는 두 값. 저장 단위는 판정기가 초를 받으므로 UI 선택일 뿐이다.
public struct ThresholdSettings: Sendable, Equatable {
    public var cpuThresholdPercent: Int
    public var sustainMinutes: Int

    public static let cpuThresholdRange = 5...800
    public static let sustainMinutesRange = 1...1440
    public static let `default` = ThresholdSettings(cpuThresholdPercent: 50, sustainMinutes: 30)

    public enum Key {
        public static let cpuThresholdPercent = "cpuThresholdPercent"
        public static let sustainMinutes = "sustainMinutes"
    }

    public init(cpuThresholdPercent: Int, sustainMinutes: Int) {
        self.cpuThresholdPercent = cpuThresholdPercent
        self.sustainMinutes = sustainMinutes
    }

    public var clamped: ThresholdSettings {
        ThresholdSettings(
            cpuThresholdPercent: min(max(cpuThresholdPercent, Self.cpuThresholdRange.lowerBound),
                                     Self.cpuThresholdRange.upperBound),
            sustainMinutes: min(max(sustainMinutes, Self.sustainMinutesRange.lowerBound),
                                Self.sustainMinutesRange.upperBound)
        )
    }

    /// `register(defaults:)` 에 넘길 기본값.
    public static var registrationDefaults: [String: Any] {
        [Key.cpuThresholdPercent: Self.default.cpuThresholdPercent,
         Key.sustainMinutes: Self.default.sustainMinutes]
    }

    /// 읽는 시점에 잘라낸다. 값이 없거나 정수가 아니면 기본값이다.
    public init(defaults: UserDefaults) {
        let percent = defaults.object(forKey: Key.cpuThresholdPercent) as? Int
        let minutes = defaults.object(forKey: Key.sustainMinutes) as? Int
        self = ThresholdSettings(
            cpuThresholdPercent: percent ?? Self.default.cpuThresholdPercent,
            sustainMinutes: minutes ?? Self.default.sustainMinutes
        ).clamped
    }

    public func write(to defaults: UserDefaults) {
        let value = clamped
        defaults.set(value.cpuThresholdPercent, forKey: Key.cpuThresholdPercent)
        defaults.set(value.sustainMinutes, forKey: Key.sustainMinutes)
    }

    /// `--thresholds t:m` — `t` 는 % 정수, `m` 은 분 정수. CLI 와 앱이 같은 파싱을 쓴다.
    public init?(argument: String) {
        let parts = argument.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let percent = Int(parts[0]), let minutes = Int(parts[1]),
              Self.cpuThresholdRange.contains(percent),
              Self.sustainMinutesRange.contains(minutes)
        else { return nil }
        self.init(cpuThresholdPercent: percent, sustainMinutes: minutes)
    }
}
