// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Scribe",
    // macOS 26 is the floor for Liquid Glass. Linking against the modern SDK is
    // also what makes the system restyle standard controls: a binary that
    // records an older SDK is treated as a legacy app and keeps the old look,
    // however new the machine running it is.
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Scribe",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Scribe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("EventKit"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
