// swift-tools-version: 6.0
import PackageDescription

/// `APP_STORE=1` builds the Mac App Store flavour. It leaves Sparkle out
/// entirely: the App Store does the updating, and rejects apps that bring
/// their own updater. build-appstore.sh sets it, with its own scratch path so
/// SwiftPM can't reuse the manifest it cached for the regular build.
let appStore = Context.environment["APP_STORE"] == "1"

var appDependencies: [Target.Dependency] = ["PomodoroCore"]
var appSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
if appStore {
    appSwiftSettings.append(.define("APP_STORE"))
} else {
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "Pomodoro",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-update framework. SwiftPM links the XCFramework but does not
        // embed it — build.sh copies Sparkle.framework into Contents/Frameworks
        // and the rpath below is what lets the executable find it there.
        // Listed in both flavours so Package.resolved never changes between
        // them; only the app target's use of it is conditional.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure scheduling logic. No AppKit, no EventKit, no I/O — so it can be
        // unit tested without a running app or calendar permission.
        .target(
            name: "PomodoroCore",
            path: "Sources/PomodoroCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Pomodoro",
            dependencies: appDependencies,
            path: "Sources/Pomodoro",
            swiftSettings: appSwiftSettings,
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "PomodoroCoreTests",
            dependencies: ["PomodoroCore"],
            path: "Tests/PomodoroCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PomodoroTests",
            dependencies: ["Pomodoro"],
            path: "Tests/PomodoroTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
