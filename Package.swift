// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingRecorderShared", targets: ["MeetingRecorderShared"]),
        .library(name: "MeetingRecorderCore", targets: ["MeetingRecorderCore"]),
        .executable(name: "MeetingRecorderAgent", targets: ["MeetingRecorderAgent"]),
        .executable(name: "meeting-recorder", targets: ["MeetingRecorderCLI"]),
    ],
    targets: [
        .target(name: "MeetingRecorderShared"),
        .target(
            name: "MeetingRecorderCore",
            dependencies: ["MeetingRecorderShared"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "MeetingRecorderAgent",
            dependencies: ["MeetingRecorderCore", "MeetingRecorderShared"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "MeetingRecorderCLI",
            dependencies: ["MeetingRecorderShared"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "MeetingRecorderSharedTests", dependencies: ["MeetingRecorderShared"]),
        .testTarget(name: "MeetingRecorderCoreTests", dependencies: ["MeetingRecorderCore", "MeetingRecorderShared"]),
    ],
    swiftLanguageModes: [.v5]
)
