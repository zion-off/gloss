// swift-tools-version: 6.1
import PackageDescription

// gloss — see docs/ARCHITECTURE.md for the module map.
// Every target builds on Linux. macOS-only targets wrap all of their sources in
// `#if os(macOS)` so they compile to empty modules elsewhere (docs/DECISIONS.md D-002).

let package = Package(
    name: "gloss",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "gloss", targets: ["gloss"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
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
        .target(name: "GlossReaderBridge", dependencies: ["GlossCore", "GlossEPUB"]),
        .target(name: "GlossPDF", dependencies: ["GlossCore", "GlossArchive"]),
        .target(name: "GlossMemoryStore", dependencies: ["GlossCore"]),
        .target(name: "GlossTestSupport", dependencies: ["GlossCore", "GlossMemoryStore", "GlossArchive"]),
        .target(name: "GlossStore", dependencies: [
            "GlossCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .executableTarget(name: "gloss", dependencies: ["GlossCore"]),
        .testTarget(name: "GlossMarkdownTests", dependencies: ["GlossMarkdown"]),
        .testTarget(name: "GlossEPUBTests", dependencies: ["GlossEPUB", "GlossTestSupport"]),
        .testTarget(name: "GlossExportTests", dependencies: ["GlossExport", "GlossTestSupport"]),
        .testTarget(name: "GlossNotesTests", dependencies: ["GlossNotes", "GlossTestSupport"]),
        .testTarget(name: "GlossReaderBridgeTests", dependencies: ["GlossReaderBridge", "GlossTestSupport"]),
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
