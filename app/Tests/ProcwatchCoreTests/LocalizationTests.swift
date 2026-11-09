import Foundation
import XCTest

/// 커밋된 현지화 표 `app/Bundle/{en,ko}.lproj/Localizable.strings` 와 소스의 짝.
///
/// 시험 타깃은 실행 타깃의 코드를 부를 수 없으므로, 두 표와 소스 파일을 경로로 읽어
/// 키 집합·형식 지정자·사용 키·남은 한글 문자열 리터럴을 고정한다. 키가 표에 없으면
/// 메뉴에 키 이름이 그대로 찍히고, 두 언어의 형식 지정자가 어긋나면 `String(format:)` 이
/// 엉뚱한 인자를 읽는다.
final class LocalizationTests: XCTestCase {
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)        // app/Tests/ProcwatchCoreTests/LocalizationTests.swift
            .deletingLastPathComponent()       // app/Tests/ProcwatchCoreTests
            .deletingLastPathComponent()       // app/Tests
            .deletingLastPathComponent()       // app
    }

    private static func table(_ language: String) throws -> [String: String] {
        let url = appRoot.appendingPathComponent("Bundle/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
            "\(language) 표가 문자열 사전으로 읽히지 않는다"
        )
    }

    /// `dir` 아래의 모든 `.swift` 파일 (경로, 내용).
    private static func swiftSources(under dir: String) throws -> [(String, String)] {
        let root = appRoot.appendingPathComponent(dir)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(files.isEmpty, "\(dir) 에서 .swift 파일을 찾지 못했다")
        return files.sorted { $0.0 < $1.0 }
    }

    func testTablesHaveSameKeys() throws {
        let en = try Self.table("en")
        let ko = try Self.table("ko")
        XCTAssertFalse(en.isEmpty)
        XCTAssertEqual(Set(en.keys).subtracting(ko.keys).sorted(), [], "en 에만 있는 키")
        XCTAssertEqual(Set(ko.keys).subtracting(en.keys).sorted(), [], "ko 에만 있는 키")
    }

    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let en = try Self.table("en")
        let ko = try Self.table("ko")
        for key in en.keys.sorted() {
            guard let koValue = ko[key], let enValue = en[key] else { continue }
            XCTAssertEqual(
                Self.formatSpecifiers(enValue), Self.formatSpecifiers(koValue),
                "\(key) 의 형식 지정자 열이 en·ko 에서 다르다"
            )
        }
    }

    func testSourceKeysAndTableKeysMatch() throws {
        let en = try Self.table("en")
        let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])L\("([^"\\]*)""#)
        var used: Set<String> = []
        for (_, text) in try Self.swiftSources(under: "Sources/procwatch") {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let keyRange = Range(match.range(at: 1), in: text) { used.insert(String(text[keyRange])) }
            }
        }
        XCTAssertFalse(used.isEmpty, "소스에서 L(\"…\") 호출을 찾지 못했다")
        XCTAssertEqual(used.subtracting(en.keys).sorted(), [], "소스가 쓰는데 en 표에 없는 키")
        XCTAssertEqual(Set(en.keys).subtracting(used).sorted(), [], "en 표에 있는데 소스가 쓰지 않는 키")
    }

    func testNoHangulStringLiteralsInSources() throws {
        var offenders: [String] = []
        for (path, text) in try Self.swiftSources(under: "Sources") {
            for line in Self.hangulLiteralLines(in: text) {
                offenders.append("\(path):\(line)")
            }
        }
        XCTAssertEqual(offenders, [], "주석 밖에 한글 문자열 리터럴이 남았다")
    }

    /// 위 시험이 빈손으로 통과하지 않게, 판독기가 리터럴·보간 안 리터럴은 잡고 주석은
    /// 넘기는지 본다.
    func testHangulScannerFindsLiteralsAndSkipsComments() {
        let sample = """
            let a = "\u{D55C}"
            // "\u{D55C}"
            let b = "\\(x ?? "\u{AE00}")" /* "\u{D55C}" */
            let c = "plain"
            """
        XCTAssertEqual(Self.hangulLiteralLines(in: sample), [1, 3])
    }

    func testDevelopmentRegionIsEnglish() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("Bundle/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
    }

    // MARK: - 판독 도우미

    /// 나타난 순서대로의 형식 지정자. `%%` 도 하나로 센다.
    static func formatSpecifiers(_ value: String) -> [String] {
        let pattern = #"%(?:%|[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSpaA])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private enum ScanContext {
        /// 코드. 문자열 보간 안이면 여는 괄호의 깊이를 센다.
        case code(depth: Int)
        case string(multiline: Bool)
    }

    /// 주석 밖 문자열 리터럴 안에 한글이 있는 줄 번호(1부터). 보간 안의 문자열과 여러 줄
    /// 문자열도 읽고, `//`·`/* */` 주석은 건너뛴다.
    static func hangulLiteralLines(in source: String) -> [Int] {
        let chars = Array(source.unicodeScalars)
        var stack: [ScanContext] = [.code(depth: 0)]
        var lines: [Int] = []
        var line = 1
        var i = 0

        func at(_ offset: Int) -> Character? {
            i + offset < chars.count ? Character(chars[i + offset]) : nil
        }
        func startsTripleQuote() -> Bool { at(0) == "\"" && at(1) == "\"" && at(2) == "\"" }

        while i < chars.count {
            let c = Character(chars[i])
            switch stack.last! {
            case .code(let depth):
                if c == "/" && at(1) == "/" {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/" && at(1) == "*" {
                    i += 2
                    while i < chars.count && !(chars[i] == "*" && at(1) == "/") {
                        if chars[i] == "\n" { line += 1 }
                        i += 1
                    }
                    i += 2
                    continue
                }
                if startsTripleQuote() {
                    stack.append(.string(multiline: true))
                    i += 3
                    continue
                }
                if c == "\"" {
                    stack.append(.string(multiline: false))
                } else if c == "(" && stack.count > 1 {
                    stack[stack.count - 1] = .code(depth: depth + 1)
                } else if c == ")" && stack.count > 1 {
                    if depth == 0 { stack.removeLast() } else { stack[stack.count - 1] = .code(depth: depth - 1) }
                } else if c == "\n" {
                    line += 1
                }
                i += 1
            case .string(let multiline):
                if c == "\\" {
                    if at(1) == "(" {
                        stack.append(.code(depth: 0))
                        i += 2
                    } else {
                        // 여러 줄 문자열의 줄 이음 `\` 도 줄 번호를 센다.
                        if at(1) == "\n" { line += 1 }
                        i += 2
                    }
                    continue
                }
                if multiline && startsTripleQuote() {
                    stack.removeLast()
                    i += 3
                    continue
                }
                if !multiline && (c == "\"" || c == "\n") {
                    stack.removeLast()
                    if c == "\n" { line += 1 }
                    i += 1
                    continue
                }
                if c == "\n" { line += 1 }
                if isHangul(chars[i]), lines.last != line { lines.append(line) }
                i += 1
            }
        }
        return lines
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value)
            || (0x3131...0x318E).contains(scalar.value)
    }
}
