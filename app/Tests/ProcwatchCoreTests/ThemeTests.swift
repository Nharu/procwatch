import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ProcwatchCore

/// 사용자 테마의 판정과 픽셀 계산.
///
/// 시험용 PNG 는 시험 안에서 `CGImageDestination` 으로 임시 디렉터리에 만들고 끝나면 지운다 —
/// 레포에는 번들 키위 말고 테마 에셋을 두지 않는다.
final class ThemeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - 도우미

    /// `opaque(x, y)` 가 참인 픽셀을 불투명 빨강으로 칠한 비트맵.
    private static func bitmap(width: Int, height: Int, opaque: (Int, Int) -> Bool) -> MaskBitmap {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where opaque(x, y) {
                let index = (y * width + x) * 4
                rgba[index] = 255
                rgba[index + 3] = 255
            }
        }
        return MaskBitmap(width: width, height: height, rgba: rgba)
    }

    private static func writePNG(_ bitmap: MaskBitmap, to url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bitmap.rgba) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// 프레임 `index` 는 열 `10 + index`~`20 + index`, 행 8~23 이 불투명하다.
    private static func frame(_ index: Int, width: Int = 48, height: Int = 32) -> MaskBitmap {
        bitmap(width: width, height: height) { x, y in
            (10 + index)...(20 + index) ~= x && 8...23 ~= y
        }
    }

    @discardableResult
    private func makeTheme(
        _ name: String,
        manifest: String? = nil,
        frames: [MaskBitmap]? = nil,
        skip: Set<Int> = []
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmaps = frames ?? (0..<4).map { Self.frame($0) }
        for (index, bitmap) in bitmaps.enumerated() where !skip.contains(index) {
            try Self.writePNG(bitmap, to: directory.appendingPathComponent(ThemeFrames.frameName(index)))
        }
        if let manifest {
            try Data(manifest.utf8).write(to: directory.appendingPathComponent(ThemeFrames.manifestName))
        }
        return directory
    }

    private func loadProblem(_ directory: URL) -> ThemeProblem? {
        do {
            _ = try ThemeFrames.load(directory: directory)
            return nil
        } catch {
            return error as? ThemeProblem
        }
    }

    // MARK: - theme.json

    func testMissingManifestIsColor() throws {
        XCTAssertEqual(try ThemeFrames.parseManifest(nil), .color)
    }

    func testTemplateTrueIsTemplate() throws {
        XCTAssertEqual(try ThemeFrames.parseManifest(Data(#"{"template": true}"#.utf8)), .template)
    }

    func testTemplateFalseWithUnknownFieldIsColor() throws {
        XCTAssertEqual(try ThemeFrames.parseManifest(Data(#"{"template": false, "x": 1}"#.utf8)), .color)
    }

    func testMalformedManifestsAreRejected() {
        for text in ["{not json", "[true]", #"{"template": "yes"}"#, #"{"template": 1}"#] {
            XCTAssertThrowsError(try ThemeFrames.parseManifest(Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? ThemeProblem, .manifestMalformed, text)
            }
        }
    }

    func testMalformedManifestMakesThemeInvalid() throws {
        let directory = try makeTheme("broken", manifest: "{not json")
        XCTAssertEqual(loadProblem(directory), .manifestMalformed)
    }

    // MARK: - 프레임 읽기

    func testFourFramesLoad() throws {
        let directory = try makeTheme("good", manifest: #"{"template": true}"#)
        let set = try ThemeFrames.load(directory: directory)
        XCTAssertEqual(set.kind, .template)
        XCTAssertEqual(set.frames.count, 4)
    }

    func testMissingFrameIsUnreadable() throws {
        let directory = try makeTheme("missing", skip: [2])
        XCTAssertEqual(loadProblem(directory), .frameUnreadable("02@2x.png"))
    }

    func testWrongSizeIsRejected() throws {
        var frames = (0..<4).map { Self.frame($0) }
        frames[1] = Self.frame(1, width: 47)
        let directory = try makeTheme("narrow", frames: frames)
        XCTAssertEqual(loadProblem(directory), .wrongSize("01@2x.png", width: 47, height: 32))
    }

    func testAllTransparentIsRejected() throws {
        let empty = Self.bitmap(width: 48, height: 32) { _, _ in false }
        let directory = try makeTheme("empty", frames: Array(repeating: empty, count: 4))
        XCTAssertEqual(loadProblem(directory), .allTransparent)
    }

    func testMissingFolderIsRejected() {
        XCTAssertEqual(loadProblem(root.appendingPathComponent("nowhere")), .folderMissing)
    }

    // MARK: - 공통 자르기와 확대

    func testCommonCropKeepsTheUnionOfOpaqueColumns() throws {
        let set = try ThemeFrames.load(directory: makeTheme("crop"))
        // 프레임 0 은 열 10~20, 프레임 3 은 열 13~23 — 합집합은 10~23 이다.
        for (index, bitmap) in set.frames.enumerated() {
            XCTAssertEqual(bitmap.width, 14, "프레임 \(index)")
            XCTAssertEqual(bitmap.height, 32, "프레임 \(index)")
        }
        XCTAssertEqual(set.frames[0].alpha(x: 0, y: 8), 255)
        XCTAssertEqual(set.frames[0].alpha(x: 13, y: 8), 0)
        XCTAssertEqual(set.frames[3].alpha(x: 0, y: 8), 0)
        XCTAssertEqual(set.frames[3].alpha(x: 13, y: 8), 255)
    }

    func testScalingToSixteenPointsKeepsPixels() throws {
        let set = try ThemeFrames.load(directory: makeTheme("same", manifest: #"{"template": true}"#))
        let pixels = ThemeFrames.pixels(for: set, height: 16)
        XCTAssertEqual(pixels, set.frames)
    }

    func testScalingToTwentyTwoPoints() throws {
        let set = try ThemeFrames.load(directory: makeTheme("big", manifest: #"{"template": true}"#))
        for bitmap in ThemeFrames.pixels(for: set, height: 22) {
            XCTAssertEqual(bitmap.height, 44)
            XCTAssertEqual(bitmap.width, Int((14.0 * 44.0 / 32.0).rounded()))
        }
    }

    // MARK: - 외곽선

    func testOutlineMaskSurroundsAPixelInEightDirections() {
        let dot = Self.bitmap(width: 5, height: 5) { x, y in x == 2 && y == 2 }
        let mask = ThemeFrames.outlineMask(dot)
        for y in 0..<5 {
            for x in 0..<5 {
                let ring = abs(x - 2) <= 1 && abs(y - 2) <= 1 && !(x == 2 && y == 2)
                XCTAssertEqual(mask.alpha(x: x, y: y), ring ? 255 : 0, "(\(x), \(y))")
            }
        }
        XCTAssertEqual(mask.opaquePixelCount, 8)
    }

    func testColorThemeHasOnePixelMarginOnEachSide() throws {
        let set = try ThemeFrames.load(directory: makeTheme("margin"))
        XCTAssertEqual(set.kind, .color)
        let pixels = ThemeFrames.pixels(for: set, height: 16)
        for (bitmap, cropped) in zip(pixels, set.frames) {
            XCTAssertEqual(bitmap.width, cropped.width + 2)
            for y in 0..<bitmap.height {
                XCTAssertEqual(bitmap.alpha(x: 0, y: y), 0)
                XCTAssertEqual(bitmap.alpha(x: bitmap.width - 1, y: y), 0)
            }
        }
        // 여백 열은 외곽선이 들어갈 자리다.
        let outline = ThemeFrames.outlineMask(pixels[0])
        XCTAssertEqual(outline.alpha(x: 0, y: 8), 255)
    }

    // MARK: - 아이콘 크기

    func testIconHeightReadsUnknownValuesAsStandard() {
        XCTAssertEqual(IconHeight(stored: 0), .standard)
        XCTAssertEqual(IconHeight(stored: 17), .standard)
        XCTAssertEqual(IconHeight(stored: -4), .standard)
        XCTAssertEqual(IconHeight(stored: 19), .points(19))
        XCTAssertEqual(IconHeight(stored: 19).storedValue, 19)
        XCTAssertEqual(IconHeight.standard.storedValue, 0)
    }

    func testStandardHeightDependsOnTheme() {
        XCTAssertEqual(IconHeight.standard.points(isKiwi: true), 16)
        XCTAssertEqual(IconHeight.standard.points(isKiwi: false), 22)
        XCTAssertEqual(IconHeight.points(19).points(isKiwi: true), 19)
        XCTAssertEqual(IconHeight.points(19).points(isKiwi: false), 19)
    }

    // MARK: - 목록

    func testListShowsDirectoriesOnlyInNameOrder() throws {
        try makeTheme("b-theme")
        try makeTheme("A-theme", manifest: #"{"template": true}"#)
        try makeTheme("c-broken", skip: [0])
        try makeTheme(".hidden")
        try Data([0]).write(to: root.appendingPathComponent(".DS_Store"))
        try Data([0]).write(to: root.appendingPathComponent("notes.txt"))

        let entries = ThemeCatalog.list(root: root)
        XCTAssertEqual(entries.map(\.name), ["A-theme", "b-theme", "c-broken"])
        XCTAssertEqual(entries.map(\.isReadable), [true, true, false])
        for entry in entries {
            switch (entry.result, ThemeCatalog.judge(root: root, name: entry.name)) {
            case (.success(let listed), .success(let judged)): XCTAssertEqual(listed, judged)
            case (.failure(let listed), .failure(let judged)): XCTAssertEqual(listed, judged)
            default: XCTFail("\(entry.name) 의 목록 판정과 단독 판정이 다르다")
            }
        }
    }

    func testMissingThemesFolderListsNothing() {
        XCTAssertTrue(ThemeCatalog.list(root: root.appendingPathComponent("absent")).isEmpty)
    }

    func testInvalidNamesAreRejected() {
        for name in ["../x", ".x", "", "a/b"] {
            XCTAssertFalse(ThemeCatalog.isValidName(name), name)
            guard case .failure(let problem) = ThemeCatalog.judge(root: root, name: name) else {
                XCTFail(name)
                continue
            }
            XCTAssertEqual(problem, .invalidName, name)
        }
    }
}
