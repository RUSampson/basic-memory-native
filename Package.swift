// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "bm-native",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/john-rocky/coreai-kit", revision: "f38ccb8e863633202ce919ff0b12c8cfe82560ff"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "BMemCore",
            dependencies: [
                "CSQLite",
                // Daemon lifecycle fix: BMemTuning (idle-unload threshold) — one constant
                // shared by daemon and UI; BMemAPI has no deps, no cycle.
                "BMemAPI",
                .product(name: "CoreAIKitEmbeddings", package: "coreai-kit"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(name: "bmem", dependencies: ["BMemCore", "BMemAPI"]),
        // UI-3: control API DTOs — dependency-free, tested directly.
        .target(name: "BMemAPI", path: "Sources/BMemAPI"),
        .executableTarget(name: "BMemApp", dependencies: ["BMemAPI"], path: "Sources/BMemApp",
                          // L10N: language catalog — the l10n/ folder (<lang>.json per
                          // language), copied into the resource bundle as-is and parsed
                          // by L10n at runtime (instant language switch, new language =
                          // new file). xcstrings — system strings only (macOS menus).
                          resources: [.copy("Resources/l10n"),
                                      .copy("Resources/Localizable.xcstrings")]),
        .testTarget(name: "BMemAPITests", dependencies: ["BMemCore", "BMemAPI", "BMemApp"], path: "Tests/BMemAPITests"),
        // UI-4: git backup and rollbacks — plain file tests without model or daemon.
        .testTarget(name: "BMemCoreTests", dependencies: ["BMemCore"], path: "Tests/BMemCoreTests"),
    ]
)
