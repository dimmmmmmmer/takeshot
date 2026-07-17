// swift-tools-version:6.0
import PackageDescription

// Строгая конкурентность Swift 6 включится позже, отдельным проходом.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "TakeShot",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // Ядро: детекция REC, именование, запись дублей. Не зависит от DeckLink SDK.
        .target(
            name: "CaptureCore",
            swiftSettings: swift5Mode
        ),
        // Obj-C++ мост к Blackmagic DeckLink SDK.
        // Заголовки SDK кладутся в vendor/DeckLinkSDK/include (см. vendor/DeckLinkSDK/README.md).
        // Без них таргет собирается как стаб (isSDKAvailable == NO).
        .target(
            name: "CDeckLink",
            cxxSettings: [
                .headerSearchPath("../../vendor/DeckLinkSDK/include")
            ]
        ),
        // Приложение.
        .executableTarget(
            name: "TakeShot",
            dependencies: ["CaptureCore", "CDeckLink"],
            resources: [.process("Resources")],
            swiftSettings: swift5Mode
        ),
        // CLI-smoke: перечислить DeckLink-устройства.
        .executableTarget(
            name: "takeshot-devices",
            dependencies: ["CDeckLink"],
            swiftSettings: swift5Mode
        ),
        // Без Xcode тесты запускаются через scripts/test.sh (см. комментарий там).
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            swiftSettings: swift5Mode
        ),
    ],
    cxxLanguageStandard: .cxx17
)
