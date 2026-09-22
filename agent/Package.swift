// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AttenuatorAgent",
    // 14.4 rather than .v14: the Core Audio process-tap API this agent
    // is built around is only available from 14.2, and the project targets 14.4.
    platforms: [.macOS("14.4")],
    targets: [
        .target(
            name: "CAudioShim",
            path: "Sources/CAudioShim"
        ),
        .executableTarget(
            name: "AttenuatorAgent",
            dependencies: ["CAudioShim"],
            path: "Sources/AttenuatorAgent",
            // Info.plist is consumed by scripts/package-app.sh when it builds
            // the .app bundle, not embedded by SwiftPM.
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
