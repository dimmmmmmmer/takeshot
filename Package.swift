// swift-tools-version:6.0
import PackageDescription

// CaptureCore is on Swift 6 (see its target below). The app layer is still
// Swift 5: SwiftUI/AppKit isolation there needs a pass of its own — 61 errors
// at last count, mostly main-actor sending and app-level global state.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "TakeShot",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // Core: REC detection, naming, take writing. No DeckLink SDK dependency.
        .target(
            name: "CaptureCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
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
        // Obj-C++ bridge to the NDI SDK (sending the viewer over the set
        // network). Headers go in vendor/NDISDK/include (see
        // vendor/NDISDK/README.md); without them the target builds as a stub
        // (CNDSender.isSDKAvailable == NO) and the feature reports itself
        // unavailable, which is the shape of every build that has no SDK —
        // CI included. The runtime libndi is opened with dlopen, so nothing
        // links here either way.
        .target(
            name: "CNDI",
            cxxSettings: [
                .headerSearchPath("../../vendor/NDISDK/include")
            ]
        ),
        // The application layer. A library rather than part of the executable:
        // SwiftPM cannot import an executable target from tests, so everything
        // here — CaptureController, the session logic, the mock backend — was
        // untestable while it lived in the executable.
        .target(
            name: "TakeShotKit",
            dependencies: ["CaptureCore", "CDeckLink", "CBraw", "CNDI"],
            resources: [.process("Resources")],
            swiftSettings: swift5Mode
        ),
        // The executable is the entry point and nothing else.
        .executableTarget(
            name: "TakeShot",
            dependencies: ["TakeShotKit"],
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
        // Application-layer tests: the take session driven end to end through
        // the mock backend, with no hardware and no window.
        .testTarget(
            name: "TakeShotKitTests",
            dependencies: ["TakeShotKit"],
            swiftSettings: swift5Mode
        ),
    ],
    cxxLanguageStandard: .cxx17
)
