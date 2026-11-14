// swift-tools-version: 6.1
import PackageDescription

// gloss — see docs/ARCHITECTURE.md for the module map.

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
        // Updates for the released app (the GlossMac target only; the CLI never links it).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
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
        .target(name: "GlossReaderPDFSupport", dependencies: ["GlossCore", "GlossPDF", "GlossReaderBridge"]),
        .target(name: "GlossAppModel", dependencies: ["GlossCore", "GlossNotes", "GlossReaderBridge", "GlossExport"]),
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
        // app and reader targets (SwiftUI, AppKit, WebKit, PDFKit)
        .target(name: "GlossReaderKit", dependencies: ["GlossCore", "GlossAppModel", "GlossReaderBridge"]),
        .target(name: "GlossReaderEPUB", dependencies: ["GlossCore", "GlossReaderBridge", "GlossReaderKit"],
                resources: [.copy("Resources/reader")]),
        .target(name: "GlossReaderPDF", dependencies: ["GlossCore", "GlossReaderBridge", "GlossReaderKit", "GlossReaderPDFSupport"]),
        .target(name: "GlossEditor", dependencies: ["GlossCore", "GlossMarkdown", "GlossNotes", "GlossAppModel"]),
        .target(name: "GlossUI", dependencies: [
            "GlossCore", "GlossMarkdown", "GlossNotes", "GlossAppModel", "GlossReaderBridge", "GlossReaderKit", "GlossEditor",
        ]),
        .executableTarget(name: "GlossMac", dependencies: [
            "GlossCore", "GlossStore", "GlossEPUB", "GlossPDF", "GlossReaderBridge",
            "GlossReaderKit", "GlossReaderEPUB", "GlossReaderPDF", "GlossEditor", "GlossUI",
            "GlossAppModel", "GlossExport",
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
        ], linkerSettings: [
            // gloss.app embeds Sparkle.framework in Contents/Frameworks (scripts/lib/app-bundle.sh).
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS])),
        ]),
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
        .testTarget(name: "GlossReaderPDFSupportTests", dependencies: ["GlossReaderPDFSupport", "GlossTestSupport"]),
        .testTarget(name: "GlossCoreTests", dependencies: ["GlossCore", "GlossMemoryStore", "GlossTestSupport"]),
        .testTarget(name: "GlossStoreTests", dependencies: [
            "GlossStore", "GlossTestSupport",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
