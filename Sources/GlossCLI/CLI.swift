import ArgumentParser
import Foundation
import GlossCore
import GlossTerminal

/// Runs the `gloss` command line. Parsing, help and errors go through ArgumentParser; gloss's
/// own failures are printed with its styling and a hint.
public enum CLI {
    public static func run(_ arguments: [String], environment: CLIEnvironment) async -> Int32 {
        let arguments = PartFlags.rewrite(arguments, names: environment.partNames)
        return await CLIEnvironment.$current.withValue(environment) {
            let printer = Printer(environment: environment, colorEnabled: !arguments.contains("--no-color"))
            do {
                var command = try await GlossCommand.asyncParseAsRoot(arguments)
                if var asyncCommand = command as? any AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                return 0
            } catch let failure as CLIFailure {
                printer.failure(failure)
                return failure.code
            } catch let error as GlossError {
                printer.failure(CLIFailure(error.description))
                return 1
            } catch let error as ExitCode {
                return error.rawValue
            } catch {
                let code = GlossCommand.exitCode(for: error)
                let message = GlossCommand.fullMessage(for: error, columns: environment.terminal.width)
                if code == .success {
                    if !message.isEmpty { environment.output.out(message + "\n") }
                } else if !message.isEmpty {
                    environment.output.err(message + "\n")
                }
                return code.rawValue
            }
        }
    }
}

/// `--library`, `--json` and `--no-color`, accepted by every command.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "the library file to use (default: GLOSS_LIBRARY, then the standard place)")
    var library: String?

    @Flag(name: .long, help: "print machine-readable json")
    var json = false

    @Flag(name: .long, help: "no colours, even on a terminal")
    var noColor = false
}

/// What every command run starts with.
struct Context: Sendable {
    let environment: CLIEnvironment
    let printer: Printer
    let services: CLIServices
    let references: References
    let json: Bool

    init(_ options: GlobalOptions) throws {
        environment = CLIEnvironment.current
        printer = Printer(environment: environment, colorEnabled: !options.noColor, json: options.json)
        services = try environment.makeServices(options.library)
        references = References(services: services.core, printer: printer)
        json = options.json
    }

    var core: GlossServices { services.core }
    var now: Date { environment.now() }
}

/// The root command.
public struct GlossCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gloss",
        abstract: "read, note and link books — from the terminal",
        discussion: """
        books and pages can be named by title, by id (or the short id gloss prints), or by a gloss:// link.
        every command takes --json for scripts. the library is shared safely with the gloss app.
        """,
        version: BuildInfo.version,
        subcommands: [
            ImportCommand.self, ListCommand.self, BookCommand.self, PagesCommand.self, ReadCommand.self,
            PageCommand.self, LinkCommand.self, HighlightsCommand.self, SearchCommand.self, ExportCommand.self, OpenCommand.self,
            TrashCommand.self, BackupCommand.self, ReindexCommand.self, WhereCommand.self,
        ])

    public init() {}

    /// A bare `gloss` says hello instead of dumping usage (`--help` still does that).
    public func run() async throws {
        await Home.show(try? Context(GlobalOptions.parse([])))
    }
}
