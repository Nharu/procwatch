import XCTest
@testable import ProcwatchCore

/// U4 — 첫 값이 `R̄` 를 정하고, τ = 30 · dt = 5 에서 0.55 → 0.45 전환이 다섯째 틱에
/// 0.50 을 가른다. 기대값은 설계 문서의 손 추적(§검증 기록 V36)과 같은 수다.
final class EmaSmootherTests: XCTestCase {
    func testU4_firstRateSeedsTheAverage() {
        var smoother = EmaSmoother(tau: 30)
        XCTAssertNil(smoother.rBar)
        XCTAssertEqual(smoother.update(rate: 0.55, dt: 5), 0.55)
        XCTAssertEqual(smoother.rBar, 0.55)
    }

    func testU4_transitionCrossesFiftyPercentOnTheFifthTick() {
        var smoother = EmaSmoother(tau: 30)
        smoother.update(rate: 0.55, dt: 5)      // 씨앗

        var values: [Double] = []
        for _ in 0..<5 {
            values.append(smoother.update(rate: 0.45, dt: 5))
        }

        for (index, value) in values.prefix(4).enumerated() {
            XCTAssertGreaterThanOrEqual(value, 0.50, "틱 \(index + 1) 은 0.50 이상이어야 한다")
        }
        XCTAssertLessThan(values[4], 0.50, "다섯째 틱은 0.50 아래여야 한다")
    }

    func testResetReturnsToWarming() {
        var smoother = EmaSmoother(tau: 30)
        smoother.update(rate: 0.55, dt: 5)
        smoother.reset()
        XCTAssertNil(smoother.rBar)
        // 다시 워밍이므로 그다음 값이 새 씨앗이다.
        XCTAssertEqual(smoother.update(rate: 0.10, dt: 5), 0.10)
    }

    func testLongIntervalApproachesTheInput() {
        var smoother = EmaSmoother(tau: 30)
        smoother.update(rate: 0.0, dt: 5)
        let value = smoother.update(rate: 1.0, dt: 3000)   // dt ≫ τ
        XCTAssertEqual(value, 1.0, accuracy: 1e-6)
    }
}
