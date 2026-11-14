import Foundation
import GlossCLI
import GlossCore
import GlossEPUB
import GlossExport
import GlossTerminal
import GlossTestSupport

/// Runs `gloss` commands in-process against an in-memory library and captures the output.
final class CLIHarness: @unchecked Sendable {
    struct Result {
        var out: String
        var err: String
        var code: Int32

        /// Parses stdout as JSON.
        func json() throws -> Any { try JSONSerialization.jsonObject(with: Data(out.utf8)) }
    }

    let library: TestLibrary
    let directory: URL
    private let lock = NSLock()
    private var out = ""
    private var err = ""
    var stdin = ""
    var stdinIsTTY = false
    var answers: [String] = []
    var opened: [URL] = []
    var openResult: OpenResult = .unsupported("the gloss app runs on macOS; here's the link instead")
    /// What the fake editor does to the file it's given.
    var edit: @Sendable (String) -> String = { $0 }
    /// When set, the fake editor writes these bytes instead (for invalid UTF-8).
    var editBytes: Data?
    var terminal = Terminal.plain

    init() {
        library = TestLibrary(formats: [FakeFormat(), EPUBFormat()])
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-cli-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var services: GlossServices { library.services }

    @discardableResult
    func run(_ arguments: String...) async -> Result {
        await run(arguments)
    }

    func run(_ arguments: [String]) async -> Result {
        lock.withLock { out = ""; err = "" }
        let library = self.library
        let environment = CLIEnvironment(
            makeServices: { _ in
                CLIServices(core: library.services, export: ExportService(store: library.store),
                            backup: library.store, libraryLocation: "/memory/library.sqlite")
            },
            output: OutputSink(out: { [self] text in lock.withLock { out += text } },
                               err: { [self] text in lock.withLock { err += text } }),
            terminal: terminal, stderrColor: false, stdinIsTTY: stdinIsTTY,
            readStdin: { [stdin] in stdin },
            readLine: { [self] in lock.withLock { answers.isEmpty ? nil : answers.removeFirst() } },
            openURL: { [self] url in lock.withLock { opened.append(url); return openResult } },
            editFile: { [edit, editBytes] url in
                if let editBytes { try editBytes.write(to: url); return }
                let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                try Data(edit(text).utf8).write(to: url)
            },
            currentDirectory: directory,
            now: { library.clock.now() },
            // what the real composition root gets from its epub and pdf formats
            partNames: ["section", "page"])
        let code = await CLI.run(arguments, environment: environment)
        return lock.withLock { Result(out: out, err: err, code: code) }
    }

    /// Writes a file into the harness's working directory.
    @discardableResult
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Imports a fake book through the CLI and returns it.
    func book(_ title: String, author: String = "Albert Camus", chapters: [String] = ["once upon a time"]) async throws -> Document {
        try file("\(title).fake", FakeFormat.file(title: title, author: author, chapters: chapters))
        let result = await run("import", "\(title).fake")
        precondition(result.code == 0, result.err)
        return try await services.library.entries().first { $0.document.title == title }!.document
    }
}
