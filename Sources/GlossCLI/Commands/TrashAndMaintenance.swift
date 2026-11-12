import ArgumentParser
import Foundation
import GlossCore
import GlossTerminal

// MARK: trash

struct TrashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash", abstract: "see, restore and empty the trash",
        subcommands: [TrashListCommand.self, TrashRestoreCommand.self, TrashPurgeCommand.self,
                      TrashEmptyCommand.self, TrashKeepCommand.self],
        defaultSubcommand: TrashListCommand.self)
}

struct TrashListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "what's in the trash")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = try Context(global)
        let entries = try await context.core.trash.entries()
        var expiries: [TrashEntryID: Date] = [:]
        for entry in entries { expiries[entry.id] = try await context.core.trash.expiry(of: entry) }
        if context.json { try context.printer.json(entries.map { TrashEntryJSON($0, expires: expiries[$0.id]) }); return }
        let printer = context.printer
        guard !entries.isEmpty else {
            printer.note("the trash is empty — nice and tidy")
            return
        }
        let table = TerminalTable(
            columns: [.init("id", style: .faint), .init("what", style: .faint), .init("title", flexible: true, style: .strong),
                      .init("trashed", style: .muted), .init("gone for good", style: .muted)],
            rows: entries.map { entry in
                [Format.shortID(entry.id), entry.kind == .document ? "book" : entry.kind.rawValue, entry.title,
                 Format.relative(entry.trashedAt, now: context.now),
                 expiries[entry.id].map { Format.future($0, now: context.now) } ?? "never"]
            })
        printer.line(table.render(on: printer.terminal))
    }
}

struct TrashRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "bring something back (and whatever it was inside)")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "its title or id") var item: String

    func run() async throws {
        let context = try Context(global)
        let entry = try await context.references.trashEntry(item)
        let restored = try await context.core.trash.restore(entry.id)
        if context.json { try context.printer.json(restored.map { TrashEntryJSON($0, expires: nil) }); return }
        context.printer.success("restored \(context.printer.title(entry.title))")
        for other in restored where other.id != entry.id {
            context.printer.note("  and \(other.title), which it lives in")
        }
    }
}

/// Asks before deleting forever, unless --yes. Without a terminal to ask on, refuses.
func confirmForever(_ question: String, yes: Bool, context: Context) throws {
    guard !yes else { return }
    guard context.environment.stdinIsTTY else {
        throw CLIFailure("this deletes for good, so gloss wants a --yes", code: CLIFailure.usageCode)
    }
    context.environment.output.out(context.printer.paint("?", .warning) + " \(question) [y/N] ")
    let answer = context.environment.readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    guard answer == "y" || answer == "yes" else { throw CLIFailure("kept it", code: 1) }
}

struct TrashPurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "purge", abstract: "delete one thing from the trash, for good")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "its title or id") var item: String
    @Flag(name: .shortAndLong, help: "don't ask") var yes = false

    func run() async throws {
        let context = try Context(global)
        let entry = try await context.references.trashEntry(item)
        try confirmForever("delete “\(entry.title)” for good?", yes: yes, context: context)
        try await context.core.trash.purge(entry.id)
        try await context.core.blobCollector.collect()
        if context.json { try context.printer.json(TrashEntryJSON(entry, expires: nil)); return }
        context.printer.success("deleted \(context.printer.title(entry.title)) for good")
    }
}

struct TrashEmptyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "empty", abstract: "delete everything in the trash, for good")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "don't ask") var yes = false

    func run() async throws {
        let context = try Context(global)
        let entries = try await context.core.trash.entries()
        guard !entries.isEmpty else {
            if context.json { try context.printer.json([String]()) } else { context.printer.note("the trash is already empty") }
            return
        }
        try confirmForever("delete \(entries.count) \(entries.count == 1 ? "thing" : "things") for good?", yes: yes, context: context)
        try await context.core.trash.empty()
        try await context.core.blobCollector.collect()
        if context.json { try context.printer.json(entries.map { TrashEntryJSON($0, expires: nil) }); return }
        context.printer.success("emptied the trash (\(entries.count) \(entries.count == 1 ? "thing" : "things"))")
    }
}

struct TrashKeepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep", abstract: "how long things stay in the trash: a number of days, or forever")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "days (like 30), or forever") var duration: String?

    func run() async throws {
        let context = try Context(global)
        if let duration {
            let days: Int?
            switch duration.lowercased() {
            case "forever", "never": days = nil
            default:
                guard let value = Int(duration), value > 0 else {
                    throw CLIFailure("“\(duration)” isn't a number of days", hint: "try: gloss trash keep 30, or gloss trash keep forever",
                                     code: CLIFailure.usageCode)
                }
                days = value
            }
            try await context.core.settings.set(days, for: TrashSettings.retentionDays)
        }
        let current = try await context.core.settings.value(TrashSettings.retentionDays)
        if context.json {
            struct Out: Encodable { var days: Int? }
            try context.printer.json(Out(days: current))
            return
        }
        let description = current.map { "\($0) \($0 == 1 ? "day" : "days")" } ?? "forever"
        if duration == nil { context.printer.line("things stay in the trash for \(context.printer.paint(description, .strong))") }
        else { context.printer.success("things now stay in the trash for \(context.printer.paint(description, .strong))") }
    }
}

// MARK: backup, reindex, where

struct BackupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup", abstract: "save a consistent copy of your whole library")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a file to create, or a folder to put it in") var destination: String

    func run() async throws {
        let context = try Context(global)
        guard let backup = context.services.backup else { throw CLIFailure("this library can't be backed up") }
        var url = context.environment.url(forPath: destination)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmm"
            url.appendPathComponent("gloss backup \(formatter.string(from: context.now)).sqlite")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CLIFailure("\(url.lastPathComponent) already exists", hint: "pick another name — gloss never overwrites a backup")
        }
        context.printer.status("backing up…")
        try await backup.backup(to: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if context.json {
            struct Out: Encodable { var file: String; var bytes: Int64 }
            try context.printer.json(Out(file: url.path, bytes: size))
            return
        }
        context.printer.success("backed up your library to \(context.printer.paint(url.path, .link)) \(context.printer.paint("(\(Format.bytes(size)))", .faint))")
    }
}

struct ReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex", abstract: "rebuild search, links and covers from scratch")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = try Context(global)
        let printer = context.printer
        let report = try await context.core.rebuilder.rebuildAll { step in
            if !context.json { printer.status("indexing \(step)…") }
        }
        printer.clearStatus()
        if context.json {
            struct Out: Encodable { var books: Int; var pages: Int; var textChunks: Int }
            try printer.json(Out(books: report.documents, pages: report.pages, textChunks: report.textChunks))
            return
        }
        printer.success("rebuilt search and links: \(report.documents) \(report.documents == 1 ? "book" : "books"), "
                        + "\(report.pages) \(report.pages == 1 ? "page" : "pages"), \(report.textChunks) sections of text")
    }
}

struct WhereCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "where", abstract: "print where the library file lives")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = try Context(global)
        if context.json { try context.printer.json(["library": context.services.libraryLocation]); return }
        context.printer.line(context.services.libraryLocation)
    }
}
