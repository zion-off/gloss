import ArgumentParser
import Foundation
import GlossCore
import GlossMarkdown
import GlossTerminal

// MARK: pages

struct PagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pages", abstract: "a book's notes pages, as a tree")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a title, id or gloss:// link") var book: String

    func run() async throws {
        let context = try Context(global)
        let document = try await context.references.document(book)
        let tree = try await context.core.pages.tree(of: document.id)
        if context.json { try context.printer.json(PageJSON(tree: tree.root)); return }
        func node(_ page: PageTree.Node) -> TerminalTree.Node {
            let detail = Format.shortID(page.page.id) + (page.page.body.isEmpty ? " · empty" : " · " + Format.lines(page.page.body))
            return TerminalTree.Node(label: page.page.title.isEmpty ? PageService.untitled : page.page.title,
                                     detail: detail, children: page.children.map(node))
        }
        context.printer.line(TerminalTree(root: node(tree.root)).render(on: context.printer.terminal))
    }
}

// MARK: read

struct ReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read", abstract: "print a notes page (rendered on a terminal, raw markdown when piped)")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a page or book (its main page): title, id or gloss:// link") var page: String
    @Flag(help: "print the markdown exactly as stored") var raw = false
    @Flag(help: "render even when piped") var rendered = false

    func validate() throws {
        if raw && rendered { throw ValidationError("pick either --raw or --rendered") }
    }

    func run() async throws {
        let context = try Context(global)
        let page = try await context.references.page(self.page)
        if context.json { try context.printer.json(PageJSON(page, includeBody: true)); return }
        let printer = context.printer
        let render = rendered || (!raw && printer.terminal.isTTY)
        guard render else {
            context.environment.output.out(page.body.hasSuffix("\n") || page.body.isEmpty ? page.body : page.body + "\n")
            return
        }
        let crumbs = try await context.core.pages.breadcrumbs(to: page.id)
        let document = try await context.core.library.document(page.documentID)
        let path = ([document?.title ?? ""] + crumbs.dropFirst().dropLast().map(\.title)).filter { !$0.isEmpty }
        if page.parentID != nil, !path.isEmpty { printer.line(printer.paint(path.joined(separator: " › "), .faint)) }
        printer.line(printer.paint(page.title.isEmpty ? PageService.untitled : page.title, .title))
        printer.line()
        let hints = try await Self.linkHints(in: page.body, bookID: page.documentID, context: context)
        let markdown = TerminalMarkdown(terminal: printer.terminal, describe: { hints[$0] })
        let body = markdown.render(page.body)
        printer.line(body.isEmpty ? printer.paint("nothing here yet — write with: gloss page write \(Format.shortID(page.id))", .muted) : body)
        let unplaced = try await context.core.pages.unplacedChildren(of: page.id)
        if !unplaced.isEmpty {
            printer.line()
            for child in unplaced {
                printer.line(printer.paint("›", .accent2Style) + " " + printer.paint(child.title.isEmpty ? PageService.untitled : child.title, .strong))
            }
        }
    }

    /// Where gloss links point: "chapter 3" for passages in this book, "chapter 3, other book"
    /// for passages elsewhere, and a warning for links into the trash or to nothing.
    static func linkHints(in body: String, bookID: DocumentID, context: Context) async throws -> [GlossLink: String] {
        var hints: [GlossLink: String] = [:]
        for link in Set(LinkScanner.links(in: body).compactMap({ GlossLink(string: $0.destination) })) {
            switch try await context.core.links.resolve(link) {
            case .passage(let target, let document):
                let parts = target.documentID == bookID ? [target.passage.label] : [target.passage.label, document.title]
                let hint = parts.compactMap { $0 }.joined(separator: ", ")
                if !hint.isEmpty { hints[link] = hint }
            case .page, .document:
                break  // the link's label already names it
            case .inTrash:
                hints[link] = "in the trash"
            case .missing:
                hints[link] = "gone"
            }
        }
        return hints
    }
}

// MARK: page

struct PageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "page", abstract: "create, write, edit, rename or trash notes pages",
        subcommands: [PageAddCommand.self, PageWriteCommand.self, PageEditCommand.self, PageRenameCommand.self, PageTrashCommand.self])
}

/// The text a command was given: the arguments, or stdin for `-` (or when piped with no
/// arguments). Nil when there is neither.
func readText(_ words: [String], context: Context) -> String? {
    if words == ["-"] || (words.isEmpty && !context.environment.stdinIsTTY) {
        return context.environment.readStdin()
    }
    guard !words.isEmpty else { return nil }
    return words.joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n")
}

struct PageAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "create a page inside another page (or inside a book's main page)")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "the page or book it goes in") var parent: String
    @Argument(help: "its title") var title: String = PageService.untitled
    @Option(help: "its first text (use - to read stdin)") var text: String?

    func run() async throws {
        let context = try Context(global)
        let parent = try await context.references.page(self.parent)
        var page = try await context.core.pages.createSubpage(under: parent.id, title: title, appendBlockLine: true)
        if let text {
            let body = text == "-" ? context.environment.readStdin() : text.replacingOccurrences(of: "\\n", with: "\n")
            page = try await context.core.pages.updateBody(page.id, to: body)
        }
        if context.json { try context.printer.json(PageJSON(page, includeBody: true)); return }
        context.printer.success("created \(context.printer.title(page.title)) in \(context.printer.title(parent.title)) "
                                + context.printer.paint("(\(Format.shortID(page.id)))", .faint))
    }
}

struct PageWriteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write", abstract: "replace a page's text, or add to it with --append",
        discussion: """
        the text comes from the arguments, or from stdin when you pass - (or pipe something in). \\n becomes a line break.
        text starting with a dash, like a list item, needs -- in front: gloss page write notes -- '- buy milk'
        """)

    @OptionGroup var global: GlobalOptions
    @Argument(help: "the page (or book) to write") var page: String
    @Argument(help: "the text") var text: [String] = []
    @Flag(help: "add to the end instead of replacing") var append = false

    func run() async throws {
        let context = try Context(global)
        let page = try await context.references.page(self.page)
        guard let body = readText(text, context: context) else {
            throw CLIFailure("what should the page say?", hint: "pass the text, or pipe it in: echo \"hi\" | gloss page write \(Format.shortID(page.id))",
                             code: CLIFailure.usageCode)
        }
        let saved = append ? try await context.core.pages.append(body, to: page.id)
                           : try await context.core.pages.updateBody(page.id, to: body)
        if context.json { try context.printer.json(PageJSON(saved, includeBody: true)); return }
        context.printer.success("\(append ? "added to" : "saved") \(context.printer.title(saved.title)) "
                                + context.printer.paint("(\(Format.lines(saved.body)))", .faint))
    }
}

struct PageEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit", abstract: "edit a page in your $EDITOR")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "the page (or book) to edit") var page: String

    func run() async throws {
        let context = try Context(global)
        let page = try await context.references.page(self.page)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let safeTitle = String((page.title.isEmpty ? PageService.untitled : page.title).map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "-" })
        let file = directory.appendingPathComponent(safeTitle + ".md")
        try Data(page.body.utf8).write(to: file)
        try context.environment.editFile(file)
        guard let data = FileManager.default.contents(atPath: file.path) else { throw CLIFailure("the edited file disappeared") }
        guard let edited = String(data: data, encoding: .utf8) else {
            throw CLIFailure("the editor didn't save utf-8 text, so gloss kept the page as it was")
        }
        guard edited != page.body else {
            if context.json { try context.printer.json(PageJSON(page, includeBody: true)) } else { context.printer.note("no changes") }
            return
        }
        let saved = try await context.core.pages.updateBody(page.id, to: edited)
        if context.json { try context.printer.json(PageJSON(saved, includeBody: true)); return }
        context.printer.success("saved \(context.printer.title(saved.title))")
    }
}

struct PageRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "give a page a new title")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "the page") var page: String
    @Argument(help: "the new title") var title: [String]

    func run() async throws {
        let context = try Context(global)
        let page = try await context.references.page(self.page)
        let renamed = try await context.core.pages.rename(page.id, to: title.joined(separator: " "))
        if context.json { try context.printer.json(PageJSON(renamed)); return }
        context.printer.success("renamed to \(context.printer.title(renamed.title))")
    }
}

struct PageTrashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trash", abstract: "move a page (and the pages inside it) to the trash")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "the page") var page: String

    func run() async throws {
        let context = try Context(global)
        let page = try await context.references.page(self.page)
        let entry = try await context.core.trash.trash(.page, id: page.id.stringValue)
        if context.json { try context.printer.json(TrashEntryJSON(entry, expires: try await context.core.trash.expiry(of: entry))); return }
        context.printer.success("moved \(context.printer.title(entry.title)) to the trash")
        context.printer.note("changed your mind? gloss trash restore \(Format.shortID(entry.id))")
    }
}
