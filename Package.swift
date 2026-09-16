// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Scribe",
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
