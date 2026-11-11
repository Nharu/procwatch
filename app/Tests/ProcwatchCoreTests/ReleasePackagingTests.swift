import Foundation
import XCTest

/// 커밋된 `app/Bundle/Info.plist` 와 cask 틀 `packaging/homebrew/procwatch.rb` 의 짝.
///
/// 번들 버전은 `build-app.sh` 가 태그나 `PROCWATCH_VERSION` 에서 넣으므로 Info.plist 에
/// 적혀 있으면 안 된다. cask 의 종료 신호·설정 삭제가 다른 번들 식별자를 가리키거나 최소 OS
/// 가 번들과 어긋나면, 설치는 되는데 제거가 앱을 끝내지 못하거나 실행할 수 없는 OS 에
/// 설치된다. 렌더러는 자리 표시자를 모두 바꾸므로 각각 한 번씩이어야 한다.
final class ReleasePackagingTests: XCTestCase {
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)        // app/Tests/ProcwatchCoreTests/ReleasePackagingTests.swift
            .deletingLastPathComponent()       // app/Tests/ProcwatchCoreTests
            .deletingLastPathComponent()       // app/Tests
            .deletingLastPathComponent()       // app
    }

    private static var repoRoot: URL { appRoot.deletingLastPathComponent() }

    /// macOS 주 버전과 Homebrew 의 `depends_on macos:` 기호 이름.
    private static let macOSNames: [Int: String] = [15: "sequoia"]

    private static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("Bundle/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static func caskTemplate() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("packaging/homebrew/procwatch.rb"), encoding: .utf8)
    }

    /// `pattern` 의 첫 묶음이 `text` 에서 잡힌 값들.
    private static func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testInfoPlistCarriesNoShortVersion() throws {
        XCTAssertNil(try Self.infoPlist()["CFBundleShortVersionString"], "번들 버전은 build-app.sh 가 넣는다")
    }

    func testCaskUninstallAndZapUseBundleIdentifier() throws {
        let identifier = try XCTUnwrap(try Self.infoPlist()["CFBundleIdentifier"] as? String)
        let cask = try Self.caskTemplate()

        let signals = try Self.captures(#"uninstall signal: \[\["TERM", "([^"]+)"\]\]"#, in: cask)
        XCTAssertEqual(signals, [identifier], "uninstall signal 의 번들 식별자")

        let zaps = try Self.captures(#"zap trash: "~/Library/Preferences/([^"]+)\.plist""#, in: cask)
        XCTAssertEqual(zaps, [identifier], "zap 이 지우는 설정 파일의 번들 식별자")
    }

    func testCaskArchitectureAndMinimumOSMatchBundle() throws {
        let cask = try Self.caskTemplate()
        XCTAssertTrue(cask.contains("depends_on arch: :arm64"), "cask 는 Apple 실리콘 전용이어야 한다")

        let declared = try XCTUnwrap(try Self.infoPlist()["LSMinimumSystemVersion"] as? String)
        let major = try XCTUnwrap(declared.split(separator: ".").first.flatMap { Int($0) })
        let expected = try XCTUnwrap(Self.macOSNames[major], "macOS \(major) 의 cask 이름이 시험 표에 없다")

        let names = try Self.captures(#"depends_on macos: :([a-z_]+)\n"#, in: cask)
        XCTAssertEqual(names, [expected], "depends_on macos 는 LSMinimumSystemVersion \(declared) 과 짝이어야 한다")
    }

    func testCaskPlaceholdersAppearOnceEach() throws {
        let cask = try Self.caskTemplate()
        for placeholder in ["@VERSION@", "@SHA256@"] {
            XCTAssertEqual(cask.components(separatedBy: placeholder).count - 1, 1, "\(placeholder) 의 개수")
        }
    }
}
