import Darwin
import Foundation

/// mach tick 을 초로 바꾸는 이음매. 판정기가 쓰는 지속 시간은 전부 깨어 있는 초이고,
/// 변환은 틱마다 식별자마다 이 한 곳에서 한 번만 한다.
public protocol MonotonicClock: Sendable {
    /// `mach_absolute_time()` 눈금. 잠자기 동안 멈춘다.
    func now() -> UInt64
    /// `numer / denom / 1e9`. 실행 시 한 번 읽고 그대로 둔다.
    var secondsPerTick: Double { get }
}

/// 이 기기의 timebase 로 도는 구현.
public struct SystemMonotonicClock: MonotonicClock {
    public let secondsPerTick: Double

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    public func now() -> UInt64 { mach_absolute_time() }
}

extension MonotonicClock {
    /// 두 눈금 사이의 깨어 있는 초.
    public func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start else { return 0 }
        return Double(end - start) * secondsPerTick
    }
}
