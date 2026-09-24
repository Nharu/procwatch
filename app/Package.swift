// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "procwatch",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ProcwatchCore"),
        .executableTarget(name: "procwatch", dependencies: ["ProcwatchCore"]),
        .testTarget(name: "ProcwatchCoreTests", dependencies: ["ProcwatchCore"]),
    ]
)
