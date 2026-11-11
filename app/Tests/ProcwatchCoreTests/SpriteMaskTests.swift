import Foundation
import XCTest
@testable import ProcwatchCore

/// `KiwiMask` 의 픽셀 결과.
///
/// 입력을 번들 리소스가 아니라 `#filePath` 기준 상대 경로로 읽는다 — SwiftPM
/// `resources:` 를 두지 않기로 했고, 실행 시 경로(`Contents/Resources/kiwi/`)는
/// 번들을 조립하는 4 단계가 만드는 것이라 이 단계에 존재하지 않는다.
final class SpriteMaskTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)        // app/Tests/ProcwatchCoreTests/SpriteMaskTests.swift
            .deletingLastPathComponent()       // app/Tests/ProcwatchCoreTests
            .deletingLastPathComponent()       // app/Tests
            .deletingLastPathComponent()       // app
            .deletingLastPathComponent()       // 레포 루트
    }

    private static func frameData(_ index: Int) throws -> Data {
        let url = repositoryRoot
            .appendingPathComponent("assets/frames2/kiwi")
            .appendingPathComponent(String(format: "%02d.png", index))
        return try Data(contentsOf: url)
    }

    func testFramesDeriveAtTwentyFourBySixteen() throws {
        for index in 0...3 {
            let pair = try KiwiMask.derive(pngData: Self.frameData(index))
            XCTAssertEqual(pair.scale1x.width, 24, "프레임 \(index)")
            XCTAssertEqual(pair.scale1x.height, 16, "프레임 \(index)")
        }
    }

    func testAlphaIsBinary() throws {
        for index in 0...3 {
            let pair = try KiwiMask.derive(pngData: Self.frameData(index))
            for y in 0..<pair.scale1x.height {
                for x in 0..<pair.scale1x.width {
                    let alpha = pair.scale1x.alpha(x: x, y: y)
                    XCTAssertTrue(alpha == 0 || alpha == 255,
                                  "프레임 \(index) (\(x), \(y)) 알파 \(alpha)")
                }
            }
        }
    }

    func testEyePixelsArePunchedOutOfFrameZero() throws {
        let pair = try KiwiMask.derive(pngData: Self.frameData(0))
        for y in 6...7 {
            for x in 10...11 {
                XCTAssertEqual(pair.scale1x.alpha(x: x, y: y), 0, "눈 (\(x), \(y))")
            }
        }
    }

    func testFrameZeroPixelCensus() throws {
        let pair = try KiwiMask.derive(pngData: Self.frameData(0))
        XCTAssertEqual(pair.scale1x.transparentPixelCount, 168)
        XCTAssertEqual(pair.scale1x.opaquePixelCount, 216)
    }

    /// @2x 는 보간이 아니라 정확한 2 배다.
    func testTwoTimesIsAnExactNearestNeighbourDouble() throws {
        for index in 0...3 {
            let pair = try KiwiMask.derive(pngData: Self.frameData(index))
            XCTAssertEqual(pair.scale2x.width, pair.scale1x.width * 2)
            XCTAssertEqual(pair.scale2x.height, pair.scale1x.height * 2)

            for y in 0..<pair.scale1x.height {
                for x in 0..<pair.scale1x.width {
                    let expected = pair.scale1x.alpha(x: x, y: y)
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            XCTAssertEqual(pair.scale2x.alpha(x: x * 2 + dx, y: y * 2 + dy),
                                           expected,
                                           "프레임 \(index) (\(x), \(y)) → (\(x * 2 + dx), \(y * 2 + dy))")
                        }
                    }
                }
            }
        }
    }

    /// 아이콘 크기 16 pt 는 지금의 키위 그대로다.
    func testScalingToSixteenKeepsTheOriginalPair() throws {
        let pair = try KiwiMask.derive(pngData: Self.frameData(0))
        XCTAssertEqual(KiwiMask.scaled(pair, height: 16), pair)
    }

    /// 22 pt 는 원본에서 최근접으로 키우고, 눈 구멍이 확대 뒤에도 뚫려 있다.
    func testScalingToTwentyTwoKeepsTheEyeHole() throws {
        let pair = KiwiMask.scaled(try KiwiMask.derive(pngData: Self.frameData(0)), height: 22)
        XCTAssertEqual(pair.scale1x.width, 33)
        XCTAssertEqual(pair.scale1x.height, 22)
        XCTAssertEqual(pair.scale2x.width, 66)
        XCTAssertEqual(pair.scale2x.height, 44)

        for bitmap in [pair.scale1x, pair.scale2x] {
            var eyePixels = 0
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let sourceX = x * 24 / bitmap.width
                    let sourceY = y * 16 / bitmap.height
                    guard 10...11 ~= sourceX, 6...7 ~= sourceY else { continue }
                    eyePixels += 1
                    XCTAssertEqual(bitmap.alpha(x: x, y: y), 0, "\(bitmap.width)x\(bitmap.height) 눈 (\(x), \(y))")
                }
            }
            XCTAssertGreaterThan(eyePixels, 0)
        }
    }
}
