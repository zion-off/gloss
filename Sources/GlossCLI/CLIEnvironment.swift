import Foundation
import GlossCore
import GlossExport
import GlossTerminal

/// The services one CLI run works with, built by the composition root (`Sources/gloss/main.swift`).
public struct CLIServices: Sendable {
    public var core: GlossServices
    public var export: ExportService
    /// Makes consistent copies of the library (`gloss backup`).
    public var backup: (any LibraryBackup)?
    /// Where the library lives, for `gloss where` and messages.
    public var libraryLocation: String

    public init(core: GlossServices, export: ExportService, backup: (any LibraryBackup)?, libraryLocation: String) {
        self.core = core
        self.export = export
        self.backup = backup
        self.libraryLocation = libraryLocation
    }
}

/// Where output goes. Tests capture it; the real CLI writes to stdout and stderr.
public struct OutputSink: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    public static let standard = OutputSink(
        out: { FileHandle.standardOutput.write(Data($0.utf8)) },
        err: { FileHandle.standardError.write(Data($0.utf8)) })
}

/// What happened when asking the system to open a `gloss://` link.
public enum OpenResult: Sendable, Equatable {
    case opened
    /// The app can't be opened here (Linux); the message says why.
    case unsupported(String)
}

/// Everything a command needs from the outside world. Injected through a task-local so
/// ArgumentParser's value-type commands stay simple and tests run commands in-process.
public struct CLIEnvironment: Sendable {
    public var makeServices: @Sendable (_ libraryPath: String?) throws -> CLIServices
    public var output: OutputSink
    /// Capabilities of stdout (colour, width, tty).
    public var terminal: Terminal
    /// Whether stderr may be coloured.
    public var stderrColor: Bool
    public var stdinIsTTY: Bool
    public var readStdin: @Sendable () -> String
    /// Reads one line from the user (confirmations); nil at end of input.
    public var readLine: @Sendable () -> String?
    public var openURL: @Sendable (URL) throws -> OpenResult
    /// Opens a file in the user's editor and waits until it's closed.
    public var editFile: @Sendable (URL) throws -> Void
    public var currentDirectory: URL
    public var now: @Sendable () -> Date

    public init(makeServices: @escaping @Sendable (String?) throws -> CLIServices, output: OutputSink, terminal: Terminal,
                stderrColor: Bool, stdinIsTTY: Bool, readStdin: @escaping @Sendable () -> String,
                readLine: @escaping @Sendable () -> String?, openURL: @escaping @Sendable (URL) throws -> OpenResult,
                editFile: @escaping @Sendable (URL) throws -> Void, currentDirectory: URL,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.makeServices = makeServices
        self.output = output
        self.terminal = terminal
        self.stderrColor = stderrColor
        self.stdinIsTTY = stdinIsTTY
        self.readStdin = readStdin
        self.readLine = readLine
        self.openURL = openURL
        self.editFile = editFile
        self.currentDirectory = currentDirectory
        self.now = now
    }

    @TaskLocal public static var current = CLIEnvironment.unconfigured

    static let unconfigured = CLIEnvironment(
        makeServices: { _ in throw CLIFailure("gloss isn't set up (no environment)") },
        output: .standard, terminal: .plain, stderrColor: false, stdinIsTTY: false,
        readStdin: { "" }, readLine: { nil }, openURL: { _ in .unsupported("no opener") },
        editFile: { _ in throw CLIFailure("no editor") }, currentDirectory: URL(fileURLWithPath: "/"))

    /// Resolves a path the user typed against the current directory (with `~` expansion).
    func url(forPath path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : currentDirectory.appendingPathComponent(expanded)
    }
}

/// A failure the CLI reports to the user: a short message, an optional hint, an exit code.
public struct CLIFailure: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var hint: String?
    public var code: Int32
    /// "Nothing by that name": callers may try another kind of thing. Ambiguity and trash
    /// errors are not this, and must reach the user.
    public var isNotFound: Bool

    public init(_ message: String, hint: String? = nil, code: Int32 = 1, notFound: Bool = false) {
        self.message = message
        self.hint = hint
        self.code = code
        self.isNotFound = notFound
    }

    public var description: String { message }

    /// Exit code for wrong usage (EX_USAGE), matching ArgumentParser's validation failures.
    public static let usageCode: Int32 = 64
}
