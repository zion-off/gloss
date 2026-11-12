import ArgumentParser
import Foundation
import GlossCore
import GlossExport
import GlossTerminal

// MARK: search

enum CLISearchScope: String, CaseIterable, ExpressibleByArgument {
    case library, notes, text, everything
}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "search titles, notes and book text",
        discussion: """
        without --book, gloss searches your library and all your notes.
        with --book, it searches that book's text and notes (like split view in the app).
        """)

    @OptionGroup var global: GlobalOptions
    @Argument(help: "what to look for") var query: [String]
    @Option(help: "a book to search inside") var book: String?
    @Option(name: .customLong("in"), help: "library, notes, text or everything") var scope: CLISearchScope?
    @Option(help: "most results per group") var limit = 20

    func validate() throws {
        guard !query.joined().trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("what should gloss look for?") }
        guard limit > 0 else { throw ValidationError("--limit needs to be at least 1") }
    }

    func run() async throws {
        let context = try Context(global)
        let text = query.joined(separator: " ")
        let scopes = try await resolveScopes(context)
        var sections: [SearchResultSection] = []
        for scope in scopes {
            for section in try await context.core.search.search(text, in: scope, limit: limit) {
                if let index = sections.firstIndex(where: { $0.group == section.group }) { sections[index].hits += section.hits }
                else { sections.append(section) }
            }
        }
        sections.sort { $0.group.order < $1.group.order }
        if context.json { try context.printer.json(sections.flatMap(\.hits).map(SearchHitJSON.init)); return }
        let printer = context.printer
        guard !sections.isEmpty else {
            printer.note("nothing matches “\(text)”")
            return
        }
        for (index, section) in sections.enumerated() {
            if index > 0 { printer.line() }
            printer.line(printer.paint(section.group.title, .heading) + printer.paint("  \(section.hits.count)", .faint))
            for hit in section.hits {
                let subtitle = hit.subtitle.map { printer.paint(" · \($0)", .muted) } ?? ""
                printer.line("  " + printer.paint(hit.title, .strong) + subtitle + printer.paint("  " + reference(hit), .faint))
                let snippet = hit.snippet.segments.map { $0.isMatch ? printer.paint($0.text, TerminalStyle(color: .accent, bold: true)) : $0.text }.joined()
                for line in TextWrap.wrap(snippet, width: min(printer.terminal.width, 100), indent: "    ") { printer.line(line) }
            }
        }
    }

    private func reference(_ hit: SearchHit) -> String {
        switch hit.destination {
        case .document(let id): Format.shortID(id)
        case .page(let id, _, _): Format.shortID(id)
        case .bookText(let id, _, _): Format.shortID(id)
        }
    }

    private func resolveScopes(_ context: Context) async throws -> [SearchScope] {
        if let book {
            let document = try await context.references.document(book)
            switch scope {
            case nil, .everything: return [.document(document.id, [.text, .notes])]
            case .text: return [.document(document.id, [.text])]
            case .notes: return [.document(document.id, [.notes])]
            case .library: throw CLIFailure("--in library searches every book, so it doesn't go with --book", code: CLIFailure.usageCode)
            }
        }
        switch scope {
        case nil, .everything: return [.library, .allNotes]
        case .library: return [.library]
        case .notes: return [.allNotes]
        case .text: throw CLIFailure("searching book text needs a book", hint: "add --book <title>", code: CLIFailure.usageCode)
        }
    }
}

// MARK: export

enum CLIExportFormat: String, CaseIterable, ExpressibleByArgument {
    case markdown, html
    var format: ExportFormat { self == .markdown ? .markdown : .html }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "export notes as one markdown (or html) file",
        discussion: """
        give a book to export all its notes (subpages become nested headings), or a page to export
        that page and the pages inside it. html is ready to print or save as pdf.
        """)

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a book or a page") var target: String
    @Option(help: "markdown or html") var format: CLIExportFormat = .markdown
    @Flag(help: "only this page, without the pages inside it") var pageOnly = false
    @Option(name: .shortAndLong, help: "a file or folder to write to (default: print it)") var output: String?

    func run() async throws {
        let context = try Context(global)
        let scope = try await exportScope(context)
        let file = try await context.services.export.export(scope, as: format.format)
        guard let output else {
            context.environment.output.out(String(decoding: file.data, as: UTF8.self))
            return
        }
        var url = context.environment.url(forPath: output)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            url.appendPathComponent(file.filename)
        }
        do { try file.data.write(to: url, options: .atomic) }
        catch { throw CLIFailure("couldn't write \(url.path)") }
        if context.json {
            struct Out: Encodable { var file: String; var bytes: Int; var format: String }
            try context.printer.json(Out(file: url.path, bytes: file.data.count, format: format.rawValue))
            return
        }
        context.printer.success("exported to \(context.printer.paint(url.path, .link))")
    }

    /// A page link or page id exports that page; anything else is looked up as a book first.
    private func exportScope(_ context: Context) async throws -> ExportScope {
        let link = GlossLink(string: target)
        let isPageRef: Bool
        if case .page = link { isPageRef = true }
        else if let raw = GlossID(string: target) { isPageRef = try await context.core.pages.page(PageID(raw)) != nil }
        else { isPageRef = false }
        if !isPageRef, let document = try? await context.references.document(target) {
            if pageOnly, let root = try await context.core.pages.rootPage(of: document.id) {
                return .page(root.id, includeSubpages: false)
            }
            return .document(document.id)
        }
        let page = try await context.references.page(target)
        return .page(page.id, includeSubpages: !pageOnly)
    }
}

// MARK: open

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "open a book, page or gloss:// link in the gloss app")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a gloss:// link, or a book or page") var target: String

    func run() async throws {
        let context = try Context(global)
        let link: GlossLink
        if let parsed = GlossLink(string: target) {
            guard await URLRouterCheck.exists(parsed, context: context) else {
                throw CLIFailure("that link points at something that's gone")
            }
            link = parsed
        } else if let document = try? await context.references.document(target) {
            link = .document(document.id)
        } else {
            link = .page(try await context.references.page(target).id)
        }
        switch try context.environment.openURL(link.url) {
        case .opened:
            if context.json { try context.printer.json(["url": link.string, "opened": "true"]); return }
            context.printer.success("opened \(context.printer.paint(link.string, .link))")
        case .unsupported(let reason):
            if context.json { try context.printer.json(["url": link.string, "opened": "false"]); return }
            context.environment.output.out(link.string + "\n")
            context.printer.warn(reason)
        }
    }
}

enum URLRouterCheck {
    static func exists(_ link: GlossLink, context: Context) async -> Bool {
        switch try? await context.core.links.resolve(link) {
        case .passage, .page, .document: true
        default: false
        }
    }
}
