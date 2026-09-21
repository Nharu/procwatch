import CoreGraphics
import Foundation
import ImageIO

/// RGBA8 비트맵 하나. RGB 는 전부 0(검정)이고 하중은 알파가 진다 — template 렌더는
/// 시스템이 막대 배경에 맞춰 알아서 뒤집는다.
public struct MaskBitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// 행당 `width * 4` 바이트.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// 왼쪽 위가 (0, 0) 이다.
    public func alpha(x: Int, y: Int) -> UInt8 {
        precondition(x >= 0 && x < width && y >= 0 && y < height)
        return rgba[(y * width + x) * 4 + 3]
    }

    public var opaquePixelCount: Int {
        stride(from: 3, to: rgba.count, by: 4).reduce(into: 0) { count, index in
            if rgba[index] != 0 { count += 1 }
        }
    }

    public var transparentPixelCount: Int { width * height - opaquePixelCount }
}

/// 같은 그림의 @1x·@2x 두 표현. 앱 타깃의 `KiwiFrames` 가 이 둘을 `NSImage` 하나에 넣는다.
public struct KiwiMaskPair: Sendable, Equatable {
    public let scale1x: MaskBitmap
    public let scale2x: MaskBitmap

    public init(scale1x: MaskBitmap, scale2x: MaskBitmap) {
        self.scale1x = scale1x
        self.scale2x = scale2x
    }
}

public enum KiwiMaskError: Error, Sendable, Equatable {
    /// PNG 바이트를 이미지로 풀지 못했다.
    case decodeFailed
    /// 크기가 0 인 이미지.
    case emptyImage
    /// 비트맵 문맥을 만들지 못했다.
    case contextUnavailable
}

/// PNG 바이트 → template 마스크. 순수 함수이고 AppKit 을 쓰지 않는다.
///
/// 입력이 경로가 아니라 `Data` 인 것이 하중을 진다 — 번들 리소스 기전 없이도 테스트가
/// 레포의 원본 PNG 를 그대로 먹일 수 있다.
public enum KiwiMask {
    /// 눈 픽셀. 이 색만 알파 0 으로 뚫어 template 에서도 눈이 남는다.
    public static let eyeColor: (r: UInt8, g: UInt8, b: UInt8) = (56, 56, 56)

    public static func derive(pngData: Data) throws -> KiwiMaskPair {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw KiwiMaskError.decodeFailed }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw KiwiMaskError.emptyImage }

        let decoded = try decode(image, width: width, height: height)
        let mask = maskPixels(from: decoded, width: width, height: height)
        let base = MaskBitmap(width: width, height: height, rgba: mask)
        return KiwiMaskPair(scale1x: base, scale2x: doubled(base))
    }

    /// 어떤 PNG 가 들어와도 같은 배치(RGBA8, 행 0 이 위)로 펴서 읽는다.
    private static func decode(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let made: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard made else { throw KiwiMaskError.contextUnavailable }
        return buffer
    }

    private static func maskPixels(from decoded: [UInt8], width: Int, height: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: decoded.count)
        for index in stride(from: 0, to: decoded.count, by: 4) {
            let alpha = decoded[index + 3]
            let isEye = alpha == 255
                && decoded[index] == eyeColor.r
                && decoded[index + 1] == eyeColor.g
                && decoded[index + 2] == eyeColor.b
            // RGB 는 0 으로 둔 채 알파만 싣는다. 눈은 뚫는다.
            mask[index + 3] = isEye ? 0 : alpha
        }
        return mask
    }

    /// 최근접 이웃 2 배. @2x 는 @1x 의 정확한 2 배여야 해서 보간하지 않는다.
    private static func doubled(_ bitmap: MaskBitmap) -> MaskBitmap {
        let width = bitmap.width * 2
        let height = bitmap.height * 2
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let source = (y * bitmap.width + x) * 4
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let target = ((y * 2 + dy) * width + (x * 2 + dx)) * 4
                        rgba[target] = bitmap.rgba[source]
                        rgba[target + 1] = bitmap.rgba[source + 1]
                        rgba[target + 2] = bitmap.rgba[source + 2]
                        rgba[target + 3] = bitmap.rgba[source + 3]
                    }
                }
            }
        }
        return MaskBitmap(width: width, height: height, rgba: rgba)
    }
}
