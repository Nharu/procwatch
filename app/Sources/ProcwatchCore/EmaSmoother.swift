import Foundation

/// `R̄ += (r − R̄)(1 − e^{−dt/τ})` 하나를 갖는 순수 값 타입.
///
/// 판정기도 `--dump` 도 이 타입을 부르고 자기 안에 평활을 다시 쓰지 않는다. 그래야
/// 2 단계가 모으는 보정 기록과 3 단계 판정기가 쓰는 `R̄` 가 같은 수다.
public struct EmaSmoother: Sendable, Equatable {
    /// 시정수(깨어 있는 초).
    public let tau: Double
    /// 워밍 중에는 nil. 첫 rate 가 이 값을 정한다.
    public private(set) var rBar: Double?

    public init(tau: Double) {
        precondition(tau > 0, "τ 는 양수여야 한다")
        self.tau = tau
    }

    /// 한 걸음 민다. 첫 호출은 평활하지 않고 `rate` 를 그대로 씨앗으로 놓는다.
    @discardableResult
    public mutating func update(rate: Double, dt: Double) -> Double {
        guard let current = rBar else {
            rBar = rate
            return rate
        }
        let next = current + (rate - current) * (1 - exp(-dt / tau))
        rBar = next
        return next
    }

    /// 정체성 단절에서 상태를 버리고 다시 워밍한다.
    public mutating func reset() { rBar = nil }
}
