// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AttenuatorAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CAudioShim",
            path: "Sources/CAudioShim"
        ),
        .executableTarget(
            name: "AttenuatorAgent",
            dependencies: ["CAudioShim"],
            path: "Sources/AttenuatorAgent",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
