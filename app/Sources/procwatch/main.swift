import AppKit
import ProcwatchCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains(LoginItemController.unregisterArgument) {
    // 상태 항목도 표본 티어도 띄우지 않는다.
    MainActor.assumeIsolated { LoginItemController.unregisterAndExit() }
}

if arguments.contains("--dump") {
    // `--ticks N` 은 유한 회차로 돌려 보기 위한 편의이며, 없으면 중단할 때까지 돈다.
    var tickLimit: Int?
    if let index = arguments.firstIndex(of: "--ticks"),
       arguments.index(after: index) < arguments.endIndex,
       let value = Int(arguments[arguments.index(after: index)]), value > 0 {
        tickLimit = value
    }
    // `--thresholds t:m` — 앱의 설정과 같은 파싱을 코어가 갖는다.
    var settings = ThresholdSettings.default
    if let index = arguments.firstIndex(of: "--thresholds") {
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, let parsed = ThresholdSettings(argument: arguments[next]) else {
            FileHandle.standardError.write(Data("procwatch: --thresholds takes t:m (t 5–800 %, m 1–1440 min)\n".utf8))
            exit(2)
        }
        settings = parsed
    }
    DumpCommand.run(tickLimit: tickLimit, settings: settings)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { app.run() }
}
