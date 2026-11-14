// The CLI's composition root: the only place that knows which store, formats and system
// integrations the `gloss` command uses (CLAUDE.md, "Dependency inversion").
import Foundation
import GlossCLI
import GlossCore
import GlossEPUB
import GlossExport
import GlossPDF
import GlossStore
import GlossTerminal
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let processEnvironment = ProcessInfo.processInfo.environment
let stdout = Terminal.detect(environment: processEnvironment)

let formats = FormatRegistry([EPUBFormat(), PDFFormat()])

let environment = CLIEnvironment(
    makeServices: { explicitPath in
        let url = LibraryLocation.resolve(explicit: explicitPath, environment: processEnvironment)
        let store = try SQLiteLibraryStore.open(at: url, origin: "cli-\(ProcessInfo.processInfo.processIdentifier)")
        let core = GlossServices(store: store, blobs: store.blobs, formats: formats)
        return CLIServices(core: core, export: ExportService(store: store), backup: store, libraryLocation: url.path)
    },
    output: .standard,
    terminal: stdout,
    stderrColor: Terminal.colorPolicy(isTTY: isatty(STDERR_FILENO) == 1, environment: processEnvironment),
    stdinIsTTY: isatty(STDIN_FILENO) == 1,
    readStdin: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) },
    readLine: { Swift.readLine() },
    openURL: { url in
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? .opened : .unsupported("macOS couldn't open the link — is gloss installed?")
        #else
        return .unsupported("the gloss app runs on macOS; here's the link instead")
        #endif
    },
    editFile: { file in
        let editor = processEnvironment["VISUAL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? processEnvironment["EDITOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Let the shell split "code --wait" and friends; pass the file as "$1".
        process.arguments = ["-c", "\(editor) \"$1\"", "gloss-editor", file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIFailure("the editor exited with an error, so gloss kept the page as it was")
        }
    },
    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    partNames: formats.quotePartNames)

exit(await CLI.run(Array(CommandLine.arguments.dropFirst()), environment: environment))
