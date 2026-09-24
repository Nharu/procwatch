import Foundation

/// 걸음 빠르기. CPU 로 정지하지 않고 빠르기만 정한다 — claude 루트의 CPU 는 쉬는 중과
/// 일하는 중이 갈리지 않아, 정지 문턱을 두면 키위가 거의 늘 서 있다.
public enum WalkPace {
    public static let minimumFPS = 2
    public static let maximumFPS = 10
    /// 저전력 모드에서의 상한.
    public static let lowPowerCap = 4

    /// `clamp(round(2 + 8 × sqrt(min(p, 100) / 100)), 2, 10)`, 저전력이면 4 이하.
    /// 곡선 상수는 R13 이 두 통제 조건의 `rootPeakPercent` 로 보정한다.
    public static func fps(peakPercent p: Double, lowPower: Bool) -> Int {
        let clampedInput = min(max(p, 0), 100)
        let raw = Int((2 + 8 * (clampedInput / 100).squareRoot()).rounded())
        let fps = min(max(raw, minimumFPS), maximumFPS)
        return lowPower ? min(fps, lowPowerCap) : fps
    }

    /// 걷는 조건의 입력.
    public struct Conditions: Sendable, Equatable {
        public var peakPercent: Double?
        public var rootCount: Int
        public var systemAsleep = false
        public var screensAsleep = false
        public var sessionActive = true
        public var itemVisible = true
        public var windowVisible = true
        /// 사용자가 드롭다운에서 걸음을 멈췄는가.
        public var userPaused = false

        public init(peakPercent: Double? = nil, rootCount: Int = 0) {
            self.peakPercent = peakPercent
            self.rootCount = rootCount
        }

        public var walking: Bool {
            peakPercent != nil
                && rootCount > 0
                && !systemAsleep
                && !screensAsleep
                && sessionActive
                && itemVisible
                && windowVisible
                && !userPaused
        }
    }
}
