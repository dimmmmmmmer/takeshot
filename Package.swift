// swift-tools-version:6.0
import PackageDescription

// Swift 6 strict concurrency will be turned on later, in a separate pass.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "TakeShot",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // Core: REC detection, naming, take writing. No DeckLink SDK dependency.
        .target(
            name: "CaptureCore",
            swiftSettings: swift5Mode
        ),
        // Obj-C++ bridge to the Blackmagic DeckLink SDK.
        // SDK headers go in vendor/DeckLinkSDK/include (see vendor/DeckLinkSDK/README.md).
        // Without them the target builds as a stub (isSDKAvailable == NO).
        .target(
            name: "CDeckLink",
            cxxSettings: [
                .headerSearchPath("../../vendor/DeckLinkSDK/include")
            ]
        ),
        // Obj-C++ bridge to the Blackmagic RAW SDK (playback of .braw takes).
        // Headers go in vendor/BRAWSDK/include (see vendor/BRAWSDK/README.md);
        // without them the target builds as a stub (CBRClip.isSDKAvailable == NO).
        .target(
            name: "CBraw",
            cxxSettings: [
                .headerSearchPath("../../vendor/BRAWSDK/include")
            ]
        ),
        // The app.
        .executableTarget(
            name: "TakeShot",
            dependencies: ["CaptureCore", "CDeckLink", "CBraw"],
            resources: [.process("Resources")],
            swiftSettings: swift5Mode
        ),
        // CLI smoke test: list DeckLink devices.
        .executableTarget(
            name: "takeshot-devices",
            dependencies: ["CDeckLink"],
            swiftSettings: swift5Mode
        ),
        // Without Xcode, tests run via scripts/test.sh (see the comment there).
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            swiftSettings: swift5Mode
        ),
    ],
    cxxLanguageStandard: .cxx17
)
