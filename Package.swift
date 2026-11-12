// swift-tools-version: 6.1
import PackageDescription

// gloss — see docs/ARCHITECTURE.md for the module map. The app targets macOS only; the portable
// modules also build on Linux for testing (docs/DECISIONS.md D-018).
// Every target builds on Linux. macOS-only targets wrap all of their sources in
// `#if os(macOS)` so they compile to empty modules elsewhere (docs/DECISIONS.md D-002).

let package = Package(
    name: "gloss",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gloss", targets: ["gloss"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "GlossMarkdown"),
        .target(name: "GlossCore", dependencies: [
            "GlossMarkdown",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib", providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]),
        .target(name: "GlossArchive", dependencies: ["CZlib"]),
        .target(name: "GlossEPUB", dependencies: ["GlossCore", "GlossArchive"]),
        .target(name: "GlossExport", dependencies: ["GlossCore", "GlossMarkdown"]),
        .target(name: "GlossNotes", dependencies: ["GlossCore", "GlossMarkdown"]),
        .target(name: "GlossReaderBridge", dependencies: [
            "GlossCore", "GlossEPUB",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "GlossPDF", dependencies: ["GlossCore", "GlossArchive"]),
        .target(name: "GlossAppModel", dependencies: ["GlossCore", "GlossNotes", "GlossReaderBridge"]),
        .target(name: "GlossTerminal"),
        .target(name: "GlossMemoryStore", dependencies: ["GlossCore"]),
        .target(name: "GlossTestSupport", dependencies: ["GlossCore", "GlossMemoryStore", "GlossArchive"]),
        .target(name: "GlossStore", dependencies: [
            "GlossCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "GlossCLI", dependencies: [
            "GlossCore", "GlossMarkdown", "GlossExport", "GlossTerminal",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "gloss", dependencies: ["GlossCLI", "GlossStore", "GlossEPUB", "GlossPDF", "GlossExport"]),
        .testTarget(name: "GlossMarkdownTests", dependencies: ["GlossMarkdown"]),
        .testTarget(name: "GlossEPUBTests", dependencies: ["GlossEPUB", "GlossTestSupport"]),
        .testTarget(name: "GlossExportTests", dependencies: ["GlossExport", "GlossTestSupport"]),
        .testTarget(name: "GlossNotesTests", dependencies: ["GlossNotes", "GlossTestSupport"]),
        .testTarget(name: "GlossReaderBridgeTests", dependencies: ["GlossReaderBridge", "GlossTestSupport"]),
        .testTarget(name: "GlossAppModelTests", dependencies: ["GlossAppModel", "GlossTestSupport", "GlossReaderBridge"]),
        .testTarget(name: "GlossTerminalTests", dependencies: ["GlossTerminal"]),
        .testTarget(name: "GlossCLITests", dependencies: ["GlossCLI", "GlossTestSupport", "GlossEPUB"]),
        .testTarget(name: "GlossArchiveTests", dependencies: ["GlossArchive", "GlossTestSupport"]),
        .testTarget(name: "GlossPDFTests", dependencies: ["GlossPDF", "GlossTestSupport", "GlossArchive"]),
        .testTarget(name: "GlossCoreTests", dependencies: ["GlossCore", "GlossMemoryStore", "GlossTestSupport"]),
        .testTarget(name: "GlossStoreTests", dependencies: [
            "GlossStore", "GlossTestSupport",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
