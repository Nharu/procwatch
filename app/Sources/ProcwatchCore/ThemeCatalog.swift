import Foundation

/// 테마 폴더 한 항목과 그 판정.
public struct ThemeEntry: Sendable {
    public let name: String
    public let result: Result<ThemeFrameSet, ThemeProblem>

    public init(name: String, result: Result<ThemeFrameSet, ThemeProblem>) {
        self.name = name
        self.result = result
    }

    public var isReadable: Bool {
        if case .success = result { return true }
        return false
    }
}

/// 테마 폴더(`themes/`)의 목록과 항목별 판정. 직속 하위 디렉터리만 테마이고, `.` 으로
/// 시작하는 이름과 일반 파일은 뺀다.
public enum ThemeCatalog {
    /// 비어 있거나 `/` 를 담거나 `.` 으로 시작하면 테마 이름이 아니다.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }

    public static func judge(root: URL, name: String) -> Result<ThemeFrameSet, ThemeProblem> {
        guard isValidName(name) else { return .failure(.invalidName) }
        do {
            return .success(try ThemeFrames.load(directory: root.appendingPathComponent(name, isDirectory: true)))
        } catch let problem as ThemeProblem {
            return .failure(problem)
        } catch {
            return .failure(.folderMissing)
        }
    }

    /// Finder 와 같은 이름순. 테마 폴더가 없으면 빈 목록이다.
    public static func list(root: URL) -> [ThemeEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { name in
                guard !name.hasPrefix(".") else { return false }
                var isDirectory: ObjCBool = false
                let path = root.appendingPathComponent(name).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ThemeEntry(name: $0, result: judge(root: root, name: $0)) }
    }
}
