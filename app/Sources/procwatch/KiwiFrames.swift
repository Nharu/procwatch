import AppKit
import ProcwatchCore

/// 상태 막대에 꽂는 프레임 세트. 번들 키위의 컬러 프레임 넷이나 사용자 테마 폴더에서 평상·
/// 빨강 프레임을 만든다.
///
/// 파생 PNG 는 커밋하지 않는다 — 빨강은 외형과 OS 릴리스에 따라 `systemRed` 가 달라지므로
/// 실행 시에 드로잉 핸들러가 그린다.
@MainActor
final class KiwiFrames {
    static let frameCount = 4

    enum LoadError: Error {
        case resourceMissing(String)
        case unreadable(String)
        case derive(String, Error)
    }

    /// 평상 프레임. 키위와 단색 테마는 template, 컬러 테마는 비template 이다.
    let template: [NSImage]
    /// 비template 빨강 프레임. 키위는 눈 구멍을 유지한다.
    let runaway: [NSImage]
    /// `.contentTint` 기전의 틴트.
    let runawayTint: NSColor
    /// `.glyphSwap` 기전의 두 번째 template 세트. 사용자 테마는 `runaway` 와 같다.
    let glyph: [NSImage]
    /// 상태 막대에서의 크기(pt).
    let size: NSSize
    /// 사용자 테마인가. 그렇다면 폭주는 기전과 상관없이 `runaway` 로 그린다.
    let isUserTheme: Bool

    private init(template: [NSImage], runaway: [NSImage], glyph: [NSImage], size: NSSize, isUserTheme: Bool) {
        self.template = template
        self.runaway = runaway
        self.runawayTint = RedStyle.red
        self.glyph = glyph
        self.size = size
        self.isUserTheme = isUserTheme
    }

    // MARK: - 번들 키위

    /// 번들 리소스 조회 → 디코드 → 마스크 파생 → 높이 `height`(pt) 로 확대. 어느 단계가
    /// 실패해도 던진다.
    static func load(bundle: Bundle = .main, height: Int = KiwiMask.baseHeight) throws -> KiwiFrames {
        let masks = try kiwiMasks(bundle: bundle)
        let scaled = masks.map { KiwiMask.scaled($0, height: height) }
        let size = pointSize(scaled[0])
        return KiwiFrames(
            template: scaled.map { templateImage($0, size: size) },
            runaway: scaled.map { redImage(templateImage($0, size: size)) },
            // 느낌표는 원본 마스크에 칠한 뒤 같은 방식으로 확대한다.
            glyph: masks.map { templateImage(KiwiMask.scaled(withBang($0), height: height), size: size) },
            size: size,
            isUserTheme: false
        )
    }

    /// 메뉴의 `키위(기본)` 항목 썸네일. 프레임 00 을 원본 높이로 그린다.
    static func kiwiThumbnail(bundle: Bundle = .main) -> NSImage? {
        guard let first = try? kiwiMasks(bundle: bundle, count: 1).first else { return nil }
        return templateImage(first, size: pointSize(first))
    }

    private static func kiwiMasks(bundle: Bundle, count: Int = frameCount) throws -> [KiwiMaskPair] {
        var masks: [KiwiMaskPair] = []
        for index in 0..<count {
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
        return masks
    }

    // MARK: - 사용자 테마

    /// 판정을 마친 테마에서 높이 `height`(pt) 의 세트를 만든다. 이미지는 @2x 표현 하나이고
    /// 크기(pt)는 픽셀의 절반이다.
    static func theme(_ set: ThemeFrameSet, height: Int, outline: Bool) -> KiwiFrames {
        let bitmaps = ThemeFrames.pixels(for: set, height: height)
        let bases = bitmaps.map { bitmapImage($0) }
        let size = bases[0].size
        let normal: [NSImage]
        let red: [NSImage]
        switch set.kind {
        case .color:
            // 외곽선은 컬러 테마이고 토글이 켜졌을 때만 쓴다.
            let outlines = bitmaps.map { outline ? bitmapImage(ThemeFrames.outlineMask($0)) : nil }
            normal = zip(bases, outlines).map { colorImage($0, outline: $1, red: false) }
            red = zip(bases, outlines).map { colorImage($0, outline: $1, red: true) }
        case .template:
            bases.forEach { $0.isTemplate = true }
            normal = bases
            red = bases.map { redImage($0) }
        }
        return KiwiFrames(template: normal, runaway: red, glyph: red, size: size, isUserTheme: true)
    }

    /// 테마 하위 메뉴의 썸네일. 프레임 00 을 16 pt 로, 외곽선 없이 그린다.
    static func thumbnail(_ set: ThemeFrameSet) -> NSImage? {
        guard let first = set.frames.first else { return nil }
        let image = bitmapImage(ThemeFrames.pixels(first, kind: set.kind, height: KiwiMask.baseHeight))
        image.isTemplate = set.kind == .template
        return image
    }

    // MARK: - 조립

    private static func pointSize(_ pair: KiwiMaskPair) -> NSSize {
        NSSize(width: pair.scale1x.width, height: pair.scale1x.height)
    }

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

    /// @1x 와 @2x 두 표현을 `size` pt 이미지 하나에 넣는다.
    private static func templateImage(_ pair: KiwiMaskPair, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        for bitmap in [pair.scale1x, pair.scale2x] {
            guard let cg = cgImage(bitmap) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    /// @2x 표현 하나만 가진 이미지. @1x 는 AppKit 의 축소에 맡긴다.
    private static func bitmapImage(_ bitmap: MaskBitmap) -> NSImage {
        let size = NSSize(width: Double(bitmap.width) / 2, height: Double(bitmap.height) / 2)
        let image = NSImage(size: size)
        if let cg = cgImage(bitmap) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = false
        return image
    }

    /// 빨강 프레임. `systemRed` 로 채우고 마스크를 `.destinationIn` 으로 겹쳐 그리며
    /// 보간은 `.none` 이다. 드로잉 핸들러라 외형이 바뀌면 다시 해석되어 그려진다.
    private static func redImage(_ mask: NSImage) -> NSImage {
        let image = NSImage(size: mask.size, flipped: false) { rect in
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

    /// 컬러 테마 프레임. 빨강이면 불투명한 픽셀에만 `systemRed` 60% 를 덮어 생김새를 남긴다.
    /// 외곽선은 빨강을 덮은 다음, 그리는 외형이 어두울 때만 그린다 — 막대 밝기는 배경 화면을
    /// 따르므로 전역 외형 설정이 아니라 상태 버튼이 그리는 외형을 본다.
    private static func colorImage(_ base: NSImage, outline: NSImage?, red: Bool) -> NSImage {
        guard red || outline != nil else { return base }
        let image = NSImage(size: base.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.imageInterpolation = .none
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            if red {
                RedStyle.red.withAlphaComponent(0.6).setFill()
                rect.fill(using: .sourceAtop)
            }
            if let outline, NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                outline.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
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
