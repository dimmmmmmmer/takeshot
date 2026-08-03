// swift-tools-version:6.0
import Foundation
import PackageDescription

// CaptureCore is on Swift 6 (see its target below). The app layer is still
// Swift 5: SwiftUI/AppKit isolation there needs a pass of its own — 61 errors
// at last count, mostly main-actor sending and app-level global state.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// RED's R3D SDK is the odd one out. DeckLink and Blackmagic RAW ship headers
// plus a dispatch file that dlopens the vendor's framework at runtime, so
// nothing links; RED ships a STATIC library that must be linked. SwiftPM has
// three linker settings — .linkedLibrary, .linkedFramework, .unsafeFlags —
// and neither of the first two can carry a library search path, while
// .unsafeFlags is off limits for a package we release. A binary target is the
// one sanctioned way in: vendor/R3DSDK.xcframework is our own stub whose
// Info.plist reaches into the vendor drop (that file states the layout).
//
// A binaryTarget whose library is missing is a hard package-graph error rather
// than a stub, so it only joins the package when the archive is really on disk.
// Without it CR3D compiles as a stub (`CR3DClip.isSDKAvailable == NO`) and the
// app still builds, tests and ships — which is what CI does on every push, and
// what a release built without RED's redistributables is.
let r3dArchive = Context.packageDirectory
    + "/vendor/R3DSDK/Lib/mac64/libR3DSDK-libcpp.a"
let hasR3DSDK = FileManager.default.fileExists(atPath: r3dArchive)

var targets: [Target] = [
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
    // Obj-C++ bridge to RED's R3D SDK (playback of .r3d clips). The headers
    // arrive with the binary target above instead of through a search path of
    // their own, so `__has_include("R3DSDK.h")` is the one switch between the
    // real bridge and the stub (see vendor/R3DSDK/README.md).
    .target(
        name: "CR3D",
        dependencies: hasR3DSDK ? ["R3DSDK"] : []
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
        dependencies: ["CaptureCore", "CDeckLink", "CBraw", "CR3D", "CNDI"],
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
    // CLI smoke test: open an .r3d clip, print its metadata and measure the
    // decode rate at each scale. The one thing the suite cannot do for itself —
    // there is no way to synthesize an R3D file, so the numbers need real
    // footage and a person to point this at it.
    .executableTarget(
        name: "takeshot-r3d",
        dependencies: ["CR3D"],
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
]

if hasR3DSDK {
    targets.append(.binaryTarget(name: "R3DSDK", path: "vendor/R3DSDK.xcframework"))
}

let package = Package(
    name: "TakeShot",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: targets,
    cxxLanguageStandard: .cxx17
)
