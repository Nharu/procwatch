import AppKit
import ProcwatchCore

/// 번들의 컬러 프레임 넷에서 template 과 빨강 프레임을 만든다.
///
/// 파생 PNG 는 커밋하지 않는다 — 빨강은 외형과 OS 릴리스에 따라 `systemRed` 가 달라지므로
/// 실행 시에 드로잉 핸들러가 그린다.
@MainActor
final class KiwiFrames {
    static let frameCount = 4
    /// 상태 막대에서의 크기(pt).
    static let pointSize = NSSize(width: 24, height: 16)

    enum LoadError: Error {
        case resourceMissing(String)
        case unreadable(String)
        case derive(String, Error)
    }

    /// 단색 template 프레임.
    let template: [NSImage]
    /// 비template 빨강 프레임. 눈 구멍을 유지한다.
    let runaway: [NSImage]
    /// `.contentTint` 기전의 틴트.
    let runawayTint: NSColor
    /// `.glyphSwap` 기전의 두 번째 template 세트.
    let glyph: [NSImage]

    /// 번들 리소스 조회 → 디코드 → 마스크 파생. 어느 단계가 실패해도 던진다.
    static func load(bundle: Bundle = .main) throws -> KiwiFrames {
        var masks: [KiwiMaskPair] = []
        for index in 0..<frameCount {
            let name = String(format: "%02d", index)
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "kiwi") else {
                throw LoadError.resourceMissing("kiwi/\(name).png")
            }
            guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(url.path) }
            do {
                masks.append(try KiwiMask.derive(pngData: data))
            } catch {
                throw LoadError.derive(url.path, error)
            }
        }
        return KiwiFrames(masks: masks)
    }

    private init(masks: [KiwiMaskPair]) {
        template = masks.map { Self.templateImage($0) }
        runaway = masks.map { Self.redImage($0) }
        runawayTint = RedStyle.red
        glyph = masks.map { Self.templateImage(Self.withBang($0)) }
    }

    // MARK: - 조립

    private static func cgImage(_ bitmap: MaskBitmap) -> CGImage? {
        let data = Data(bitmap.rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// @1x 와 @2x 두 표현을 24x16 pt 이미지 하나에 넣는다.
    private static func templateImage(_ pair: KiwiMaskPair) -> NSImage {
        let image = NSImage(size: pointSize)
        for bitmap in [pair.scale1x, pair.scale2x] {
            guard let cg = cgImage(bitmap) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = pointSize
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    /// 빨강 프레임. `systemRed` 로 채우고 template 을 `.destinationIn` 으로 겹쳐 그리며
    /// 보간은 `.none` 이다. 드로잉 핸들러라 외형이 바뀌면 다시 해석되어 그려진다.
    private static func redImage(_ pair: KiwiMaskPair) -> NSImage {
        let mask = templateImage(pair)
        let image = NSImage(size: pointSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.imageInterpolation = .none
            RedStyle.red.setFill()
            rect.fill()
            mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 머리 위 가운데에 「!」 모양(세로 막대 + 점)을 알파로 칠한 세트. 대체 순서 (2) 용.
    private static func withBang(_ pair: KiwiMaskPair) -> KiwiMaskPair {
        func paint(_ bitmap: MaskBitmap, scale: Int) -> MaskBitmap {
            var rgba = bitmap.rgba
            let column = bitmap.width - 3 * scale
            let rows = Array(0..<(3 * scale)) + Array((4 * scale)..<(5 * scale))
            for y in rows where y < bitmap.height {
                for x in column..<(column + scale) where x < bitmap.width {
                    rgba[(y * bitmap.width + x) * 4 + 3] = 255
                }
            }
            return MaskBitmap(width: bitmap.width, height: bitmap.height, rgba: rgba)
        }
        return KiwiMaskPair(scale1x: paint(pair.scale1x, scale: 1), scale2x: paint(pair.scale2x, scale: 2))
    }
}
