import CoreFoundation
import Foundation

/// 아이콘 높이 설정. 저장값 `0` 은 `기본` 이고 `16`·`19`·`22` 는 그 높이(pt)다.
public enum IconHeight: Equatable, Sendable {
    /// 테마마다 지금 높이를 쓴다 — 키위 16 pt, 사용자 테마 22 pt.
    case standard
    case points(Int)

    /// 메뉴에서 고를 수 있는 높이(pt).
    public static let choices = [16, 19, 22]
    public static let kiwiStandardPoints = 16
    public static let userThemeStandardPoints = 22

    /// 목록에 없는 값(0·음수 포함)은 `기본` 으로 읽는다.
    public init(stored: Int) {
        self = Self.choices.contains(stored) ? .points(stored) : .standard
    }

    public var storedValue: Int {
        switch self {
        case .standard: return 0
        case .points(let value): return value
        }
    }

    public func points(isKiwi: Bool) -> Int {
        switch self {
        case .standard: return isKiwi ? Self.kiwiStandardPoints : Self.userThemeStandardPoints
        case .points(let value): return value
        }
    }
}

/// 사용자 테마의 그리기 방식.
public enum ThemeKind: Equatable, Sendable {
    /// 색을 그대로 그린다. 폭주는 빨강을 덮는다.
    case color
    /// 알파만 쓰는 template. 막대 밝기에 따라 시스템이 뒤집는다.
    case template
}

/// 테마를 읽지 못한 이유. 메뉴에는 이름만 보이고 이유는 stderr 한 줄로 남는다.
public enum ThemeProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case folderMissing
    /// 프레임 파일이 없거나 이미지로 풀리지 않는다.
    case frameUnreadable(String)
    case wrongSize(String, width: Int, height: Int)
    case allTransparent
    case manifestMalformed
    /// 이름이 비었거나 `/` 를 담거나 `.` 으로 시작한다.
    case invalidName

    public var description: String {
        switch self {
        case .folderMissing: return "theme folder is missing"
        case .frameUnreadable(let file): return "\(file) is missing or unreadable"
        case .wrongSize(let file, let width, let height):
            return "\(file) is \(width)x\(height), expected \(ThemeFrames.pixelWidth)x\(ThemeFrames.pixelHeight)"
        case .allTransparent: return "all frames are fully transparent"
        case .manifestMalformed: return "\(ThemeFrames.manifestName) is malformed"
        case .invalidName: return "invalid theme name"
        }
    }
}

/// 판정을 마친 사용자 테마. 프레임은 네 장 공통으로 좌우를 자른 원본 해상도 RGBA 다.
public struct ThemeFrameSet: Equatable, Sendable {
    public let kind: ThemeKind
    public let frames: [MaskBitmap]

    public init(kind: ThemeKind, frames: [MaskBitmap]) {
        self.kind = kind
        self.frames = frames
    }
}

/// 사용자 테마 폴더의 판정과 픽셀 계산. AppKit 을 쓰지 않는다 — 앱 타깃은 결과 비트맵을
/// `NSImage` 로 싸기만 한다.
public enum ThemeFrames {
    public static let frameCount = 4
    public static let pixelWidth = 48
    public static let pixelHeight = 32
    public static let manifestName = "theme.json"
    /// 컬러 테마 좌우의 투명 여백(px). 외곽선 자리이고, 토글을 바꿔도 너비가 그대로다.
    public static let colorMargin = 1

    public static func frameName(_ index: Int) -> String {
        String(format: "%02d@2x.png", index)
    }

    // MARK: - 판정

    /// `theme.json` 바이트. 없으면 컬러다. JSON 이 아니거나 최상위가 객체가 아니거나
    /// `template` 이 불리언이 아니면 형식 오류이고, 모르는 필드는 무시한다.
    public static func parseManifest(_ data: Data?) throws -> ThemeKind {
        guard let data else { return .color }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { throw ThemeProblem.manifestMalformed }
        guard let value = dictionary["template"] else { return .color }
        // `NSNumber` 는 1·0 숫자도 Bool 로 바뀌므로 CFBoolean 인지 직접 본다.
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ThemeProblem.manifestMalformed
        }
        return number.boolValue ? .template : .color
    }

    /// 폴더 하나를 읽는다. `00@2x.png`~`03@2x.png` 와 `theme.json` 말고는 읽지 않는다.
    public static func load(directory: URL) throws -> ThemeFrameSet {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw ThemeProblem.folderMissing }

        let manifestURL = directory.appendingPathComponent(manifestName)
        var manifest: Data?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            guard let data = try? Data(contentsOf: manifestURL) else { throw ThemeProblem.manifestMalformed }
            manifest = data
        }
        let kind = try parseManifest(manifest)

        var frames: [MaskBitmap] = []
        for index in 0..<frameCount {
            let name = frameName(index)
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let bitmap = try? KiwiMask.decodeRGBA(pngData: data)
            else { throw ThemeProblem.frameUnreadable(name) }
            guard bitmap.width == pixelWidth, bitmap.height == pixelHeight else {
                throw ThemeProblem.wrongSize(name, width: bitmap.width, height: bitmap.height)
            }
            frames.append(bitmap)
        }
        guard frames.contains(where: { $0.opaquePixelCount > 0 }) else { throw ThemeProblem.allTransparent }
        return ThemeFrameSet(kind: kind, frames: cropToCommonColumns(frames))
    }

    // MARK: - 픽셀

    /// 네 장의 불투명 열(알파가 0 이 아닌 픽셀이 있는 열)의 합집합 범위로 한 번에 자른다.
    /// 프레임마다 자르면 몸이 좌우로 흔들린다. 불투명 열이 없으면 그대로 돌려준다.
    public static func cropToCommonColumns(_ frames: [MaskBitmap]) -> [MaskBitmap] {
        var first = Int.max
        var last = Int.min
        for bitmap in frames {
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width where bitmap.rgba[(y * bitmap.width + x) * 4 + 3] != 0 {
                    first = min(first, x)
                    last = max(last, x)
                }
            }
        }
        guard first <= last else { return frames }
        return frames.map { crop($0, from: first, through: last) }
    }

    private static func crop(_ bitmap: MaskBitmap, from first: Int, through last: Int) -> MaskBitmap {
        let width = last - first + 1
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * bitmap.height * 4)
        for y in 0..<bitmap.height {
            let start = (y * bitmap.width + first) * 4
            rgba.append(contentsOf: bitmap.rgba[start..<(start + width * 4)])
        }
        return MaskBitmap(width: width, height: bitmap.height, rgba: rgba)
    }

    /// 높이 `height`(px) 로 최근접 확대한다. 너비는 같은 비율로 반올림한다.
    public static func scaled(_ bitmap: MaskBitmap, height: Int) -> MaskBitmap {
        let width = Int((Double(bitmap.width) * Double(height) / Double(bitmap.height)).rounded())
        return KiwiMask.nearest(bitmap, width: width, height: height)
    }

    /// 좌우에 `horizontal` px 의 투명 열을 붙인다.
    public static func padded(_ bitmap: MaskBitmap, horizontal: Int) -> MaskBitmap {
        let width = bitmap.width + horizontal * 2
        var rgba = [UInt8](repeating: 0, count: width * bitmap.height * 4)
        for y in 0..<bitmap.height {
            let source = y * bitmap.width * 4
            let target = (y * width + horizontal) * 4
            rgba.replaceSubrange(target..<(target + bitmap.width * 4),
                                 with: bitmap.rgba[source..<(source + bitmap.width * 4)])
        }
        return MaskBitmap(width: width, height: bitmap.height, rgba: rgba)
    }

    /// 투명 픽셀 가운데 8방향 이웃에 불투명 픽셀이 있는 것을 흰색 불투명으로, 나머지는
    /// 투명으로 둔 마스크. 최종 비트맵에 쓰므로 굵기는 기기 픽셀 한 줄이다.
    public static func outlineMask(_ bitmap: MaskBitmap) -> MaskBitmap {
        let width = bitmap.width
        let height = bitmap.height
        func opaque(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && bitmap.rgba[(y * width + x) * 4 + 3] != 0
        }
        var rgba = [UInt8](repeating: 0, count: bitmap.rgba.count)
        for y in 0..<height {
            for x in 0..<width where !opaque(x, y) {
                var touches = false
                for dy in -1...1 {
                    for dx in -1...1 where (dx != 0 || dy != 0) && opaque(x + dx, y + dy) {
                        touches = true
                    }
                }
                if touches {
                    let index = (y * width + x) * 4
                    for channel in 0..<4 { rgba[index + channel] = 255 }
                }
            }
        }
        return MaskBitmap(width: width, height: height, rgba: rgba)
    }

    /// 아이콘 높이 `height`(pt) 의 최종 @2x 비트맵 한 장. 컬러 테마는 좌우 여백을 붙인다.
    public static func pixels(_ bitmap: MaskBitmap, kind: ThemeKind, height: Int) -> MaskBitmap {
        let scaledBitmap = scaled(bitmap, height: height * 2)
        switch kind {
        case .color: return padded(scaledBitmap, horizontal: colorMargin)
        case .template: return scaledBitmap
        }
    }

    public static func pixels(for set: ThemeFrameSet, height: Int) -> [MaskBitmap] {
        set.frames.map { pixels($0, kind: set.kind, height: height) }
    }
}
