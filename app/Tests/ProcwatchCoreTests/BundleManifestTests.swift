import Foundation
import XCTest

/// 커밋된 `app/Bundle/Info.plist` 와 `app/Package.swift` 의 짝.
///
/// 번들이 선언한 최소 OS 가 바이너리의 배포 하한보다 낮으면, 그 사이 OS 에서 Launch
/// Services 는 plist 만 보고 실행을 허용하고 dyld 는 바이너리의 minos 를 보고 적재를
/// 거부한다. `LSUIElement` 가 참이라 사용자에게 보이는 단서가 없으므로 두 값은 손으로
/// 적힌 두 파일에서 함께 움직여야 하고, 그것을 여기서 고정한다.
final class BundleManifestTests: XCTestCase {
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)        // app/Tests/ProcwatchCoreTests/BundleManifestTests.swift
            .deletingLastPathComponent()       // app/Tests/ProcwatchCoreTests
            .deletingLastPathComponent()       // app/Tests
            .deletingLastPathComponent()       // app
    }

    func testMinimumSystemVersionMatchesPackagePlatform() throws {
        let plistData = try Data(contentsOf: Self.appRoot.appendingPathComponent("Bundle/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let declared = try XCTUnwrap(plist["LSMinimumSystemVersion"] as? String)

        let manifest = try String(
            contentsOf: Self.appRoot.appendingPathComponent("Package.swift"), encoding: .utf8
        )
        let pattern = try NSRegularExpression(pattern: #"\.macOS\(\.v(\d+)\)"#)
        let matches = pattern.matches(in: manifest, range: NSRange(manifest.startIndex..., in: manifest))
        XCTAssertEqual(matches.count, 1, "Package.swift 의 macOS 하한 선언은 하나여야 한다")
        let match = try XCTUnwrap(matches.first)
        let major = try XCTUnwrap(Range(match.range(at: 1), in: manifest).map { String(manifest[$0]) })

        XCTAssertEqual(declared, "\(major).0", "LSMinimumSystemVersion 은 배포 하한 .v\(major) 과 같아야 한다")
    }
}
