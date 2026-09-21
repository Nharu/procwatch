import AppKit
import ServiceManagement

/// `SMAppService.mainApp` 로그인 항목. 규칙 넷을 이 한 곳이 진다.
@MainActor
final class LoginItemController {
    /// 메뉴 줄의 상태.
    enum Presentation: Equatable {
        /// 위치 관문에 걸렸다(규칙 1).
        case unavailable
        /// 체크 토글. `.requiresApproval` 은 혼합 상태로 보인다(규칙 4).
        case toggle(NSControl.StateValue)
    }

    static let unregisterArgument = "--unregister-login-item"

    private let settings: SettingsStore
    private let service = SMAppService.mainApp
    /// 마지막 `register()` 실패. 있으면 메뉴에 한 줄을 더한다(규칙 3).
    private(set) var lastFailure: String?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// 규칙 1. `.build` 트리를 가리키는 로그인 항목이 생기지 않게 한다.
    var isInApplications: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications"
    }

    private var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// 실행 시 한 번. 프로세스 수명당 한 번이라 `register()` 의 재시도는 이미 유계다.
    func reconcileAtLaunch() {
        // 규칙 2 — 가장 먼저. 시스템 설정에서 끈 사용자를 기록해, 나중의 재설치가 조용히
        // 다시 켜지 않게 한다.
        if service.status == .requiresApproval {
            settings.launchAtLoginDesired = false
        }
        // 규칙 3 — 맞추기. 빌드 비교는 조건에 넣지 않는다: 같은 커밋의 재빌드는
        // `CFBundleVersion` 이 같은데 ad-hoc cdhash 가 달라져 등록이 떨어진다.
        guard isInApplications else { return }
        if settings.launchAtLoginDesired && service.status == .notRegistered {
            register()
        }
    }

    var presentation: Presentation {
        guard isInApplications else { return .unavailable }
        switch service.status {
        case .enabled: return .toggle(.on)
        case .requiresApproval: return .toggle(.mixed)
        default: return .toggle(.off)
        }
    }

    /// 「로그인 항목 등록 실패 — 마지막 성공 빌드 N」. 실패가 없으면 nil.
    var failureLine: String? {
        guard lastFailure != nil else { return nil }
        return "로그인 항목 등록 실패 — 마지막 성공 빌드 \(settings.launchAtLoginRegisteredBuild ?? "없음")"
    }

    /// 규칙 4 — 메뉴 토글.
    func toggle() {
        guard isInApplications else { return }
        switch service.status {
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .enabled:
            settings.launchAtLoginDesired = false
            do { try service.unregister() } catch { lastFailure = error.localizedDescription }
        default:
            settings.launchAtLoginDesired = true
            register()
        }
    }

    private func register() {
        do {
            try service.register()
            // 성공한 빌드만 기록한다. 실패하면 이 값을 건드리지 않는다.
            settings.launchAtLoginRegisteredBuild = bundleVersion
            lastFailure = nil
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    /// `--unregister-login-item` 으로 뜬 실행. 상태 항목도 표본 티어도 띄우지 않고 규칙
    /// 2·3 도 돌리지 않는다 — 규칙 3 을 돌리면 제거 절차 자신이 `register()` 를 먼저
    /// 불러 죽은 항목을 만들 수 있다. `unregister()` 하나와 그 결과 한 줄뿐이다.
    static func unregisterAndExit() -> Never {
        do {
            try SMAppService.mainApp.unregister()
            FileHandle.standardError.write(Data("procwatch: 로그인 항목 등록 해제됨\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("procwatch: 로그인 항목 등록 해제 실패 — \(error)\n".utf8))
            exit(1)
        }
    }
}
