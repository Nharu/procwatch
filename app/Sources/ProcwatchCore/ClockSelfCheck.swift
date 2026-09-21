import Foundation

/// 시작 시 시계 자체 점검.
///
/// 지키려는 오류는 mach tick 을 나노초로 읽는 것이며, 그때 `dtSec / wallSec` 는
/// 1/41.67 또는 41.67 이 된다. 잠자기나 시계 조정 한 번은 구간 하나만 흔들므로
/// **연속 3 개**를 요구해 그런 단발을 걸러 낸다. 플래그는 저장하지 않고 실행마다
/// 다시 판정한다.
public struct ClockSelfCheck: Sendable, Equatable {
    /// 비율이 이 범위 밖이면 그 구간은 어긋난 것으로 센다.
    public static let acceptableRatio: ClosedRange<Double> = 0.5...2.0
    /// 벽시계 간격이 이만큼 이상인 구간만 본다.
    public static let minimumWallSeconds: Double = 1.0
    /// 그런 구간 가운데 처음 이만큼만 본다.
    public static let sampleLimit = 10
    /// 어긋난 구간이 연속으로 이만큼이면 켠다.
    public static let consecutiveLimit = 3

    private var observed = 0
    private var consecutiveOffScale = 0

    /// 켜지면 메뉴에 「시간 단위 이상 — 판정이 틀릴 수 있음」 줄을 보인다.
    public private(set) var isSuspect = false

    public init() {}

    /// 구간 하나를 넣는다. 켜진 뒤에는 더 보지 않고, 표본 상한을 넘겨도 보지 않는다.
    @discardableResult
    public mutating func observe(dtSec: Double, wallSec: Double) -> Bool {
        guard !isSuspect,
              observed < Self.sampleLimit,
              wallSec >= Self.minimumWallSeconds
        else { return isSuspect }

        observed += 1
        let ratio = dtSec / wallSec
        if Self.acceptableRatio.contains(ratio) {
            consecutiveOffScale = 0
        } else {
            consecutiveOffScale += 1
            if consecutiveOffScale >= Self.consecutiveLimit { isSuspect = true }
        }
        return isSuspect
    }
}
