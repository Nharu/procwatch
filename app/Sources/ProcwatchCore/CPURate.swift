import Foundation

/// CPU 시간 카운터는 mach tick 단위이고 나노초가 아니다. 비율 꼴은 분자와 분모가 같은
/// 단위라 timebase 없이 올바른 크기를 주므로, 카운터를 초로 변환하지 않는다.
/// 1.0 이 코어 하나다.
public enum CPURate {
    /// `rate = Δc / Δabs`. 분모가 0 이면 이 구간에는 rate 가 없다.
    public static func rate(deltaCPUTicks: UInt64, deltaAbsoluteTicks: UInt64) -> Double? {
        guard deltaAbsoluteTicks > 0 else { return nil }
        return Double(deltaCPUTicks) / Double(deltaAbsoluteTicks)
    }
}
