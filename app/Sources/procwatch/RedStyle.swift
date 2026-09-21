import AppKit

/// 빨강 기전과 프레임을 꽂는 자리를 가두는 상수 둘. 화면 판정이나 에너지 판정이 바뀌어도
/// 이 파일 하나만 바뀐다.
enum RedMechanism {
    /// 비template 빨강 프레임으로 `button.image` 를 바꾼다.
    case imageSwap
    /// template 그대로 두고 `contentTintColor` 를 빨강으로 한다.
    case contentTint
    /// 색 대신 머리 위 「!」를 뚫은 두 번째 template 세트로 신호한다.
    case glyphSwap
}

enum FrameSink {
    /// `button.image` 교체.
    case buttonImage
    /// 상태 버튼 레이어의 하위 `CALayer.contents` 교체.
    case layerContents
}

@MainActor
enum RedStyle {
    static let redMechanism: RedMechanism = .imageSwap
    static let frameSink: FrameSink = .buttonImage

    /// `.contentTint` 를 고르면 프레임은 `button.image` 로만 꽂힌다.
    static var effectiveFrameSink: FrameSink {
        redMechanism == .contentTint ? .buttonImage : frameSink
    }

    /// 정확한 빨강은 시스템이 정한다. 16 진 값을 고정하지 않는다.
    static var red: NSColor { .systemRed }
}
