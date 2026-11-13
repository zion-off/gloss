import Foundation
import GlossCore
import GlossTerminal

/// What a bare `gloss` shows: a hello, the library at a glance, where you left off, and a few
/// commands worth trying. `gloss --help` still prints the full reference.
enum Home {
    static func show(_ context: Context?) async {
        let printer = context?.printer ?? Printer(environment: CLIEnvironment.current, colorEnabled: true)
        printer.line()
        printer.line("  " + printer.paint("gloss", .title) + printer.paint("  read, note and link books", .muted))
        printer.line()

        if let context, let entries = try? await context.core.library.entries(sortedBy: .recent) {
            if entries.isEmpty {
                printer.line("  " + printer.paint("nothing glossed yet", .strong))
                printer.line("  " + printer.paint("add a book to begin:", .muted) + " gloss import ~/Downloads/book.epub")
                printer.line()
            } else {
                summary(entries, printer: printer)
                recents(entries, context: context, printer: printer)
            }
        }

        printer.line("  " + printer.paint("try", .heading))
        let tips: [(String, String)] = [
            ("gloss import <files or folders>", "add epubs and pdfs"),
            ("gloss ls", "see your library"),
            ("gloss read \"<book>\"", "read the notes you wrote on a book"),
            ("gloss search \"<words>\"", "search titles, notes and book text"),
            ("gloss open \"<book>\"", "open it in the gloss app"),
        ]
        let width = tips.map { DisplayWidth.of($0.0) }.max() ?? 0
        for (command, what) in tips {
            let pad = String(repeating: " ", count: width - DisplayWidth.of(command))
            printer.line("    " + command + pad + "  " + printer.paint(what, .muted))
        }
        printer.line()
        printer.line("  " + printer.paint("every command: gloss help · add --json to anything for scripts", .faint))
        printer.line()
    }

    private static func summary(_ entries: [LibraryEntry], printer: Printer) {
        let started = entries.filter { $0.position != nil }.count
        let books = entries.count == 1 ? "1 book" : "\(entries.count) books"
        let parts = [books] + (started > 0 ? ["\(started) started"] : [])
        printer.line("  " + printer.paint(parts.joined(separator: " · "), .strong))
        printer.line()
    }

    private static func recents(_ entries: [LibraryEntry], context: Context, printer: Printer) {
        let opened = entries.filter { $0.document.lastOpenedAt != nil }.prefix(3)
        guard !opened.isEmpty else { return }
        printer.line("  " + printer.paint("pick up where you left off", .heading))
        let room = max(printer.terminal.width - 4, 20)
        for entry in opened {
            let detail = [entry.position.map { Format.percent($0.progression) },
                          entry.document.lastOpenedAt.map { Format.relative($0, now: context.now) }]
                .compactMap { $0 }.joined(separator: " · ")
            let author = entry.document.author.isEmpty ? "" : " — " + entry.document.author
            let tail = detail.isEmpty ? "" : "  " + detail
            let titleRoom = max(room - DisplayWidth.of(author) - DisplayWidth.of(tail), 12)
            let title = DisplayWidth.truncate(entry.document.title, to: titleRoom)
            printer.line("    " + printer.paint(title, .strong) + printer.paint(author, .muted) + printer.paint(tail, .faint))
        }
        printer.line()
    }
}
