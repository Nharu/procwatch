import Foundation
@testable import ProcwatchCore

/// 시험용 시계. timebase 를 손으로 정하고 눈금을 손으로 민다.
final class FakeClock: MonotonicClock, @unchecked Sendable {
    let secondsPerTick: Double
    private var ticks: UInt64

    init(numer: UInt32, denom: UInt32, start: UInt64 = 0) {
        self.secondsPerTick = Double(numer) / Double(denom) / 1e9
        self.ticks = start
    }

    func now() -> UInt64 { ticks }

    func advance(ticks delta: UInt64) { ticks &+= delta }
}
