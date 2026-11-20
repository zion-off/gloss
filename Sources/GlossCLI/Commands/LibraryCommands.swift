import ArgumentParser
import Foundation
import GlossCore
import GlossTerminal

// MARK: import

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "add epubs and pdfs (files or whole folders) to your library")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "files or folders to import")
    var paths: [String]

    struct Output: Encodable {
        /// `input` is the argument as typed; `file` the file that failed (inside it, for folders).
        struct Failure: Encodable { var input: String; var file: String; var error: String }
        var imported: [DocumentJSON] = []
        var duplicates: [DocumentJSON] = []
        var failed: [Failure] = []
    }

    func run() async throws {
        let context = try Context(global)
        let printer = context.printer
        var result = Output()
        let extensions = context.core.formats.supportedExtensions
        for path in paths {
            let url = context.environment.url(forPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.failed.append(.init(input: path, file: url.path, error: "no such file"))
                if !context.json { printer.failure(CLIFailure("couldn't find \(path)")) }
                continue
            }
            let files = ImportCandidates.expand(url, supportedExtensions: extensions)
            if files.isEmpty, !context.json {
                printer.warn("no epubs or pdfs in \(path)")
            }
            for file in files {
                let name = file.lastPathComponent
                printer.status("reading \(name)…")
                do {
                    let outcome = try await context.core.imports.importFile(at: file) { progress in
                        switch progress {
                        case .storing: printer.status("storing \(name)…")
                        case .indexing: printer.status("indexing \(name)…")
                        default: break
                        }
                    }
                    switch outcome {
                    case .imported(let document):
                        result.imported.append(DocumentJSON(document))
                        if !context.json {
                            let byline = document.author.isEmpty ? "" : printer.paint(" — \(document.author)", .muted)
                            printer.success("added \(printer.title(document.title))\(byline) \(printer.paint("· \(context.core.formats.badge(of: document.kind))", .faint))")
                        }
                    case .duplicate(let document):
                        result.duplicates.append(DocumentJSON(document))
                        if !context.json {
                            printer.clearStatus()
                            printer.line(printer.paint("↺", .accent2Style) + " already have \(printer.title(document.title)) "
                                         + printer.paint("(\(Format.shortID(document.id)))", .faint))
                        }
                    }
                } catch {
                    let message = (error as? GlossError)?.description ?? "it doesn't look like an epub or pdf gloss can read"
                    result.failed.append(.init(input: path, file: file.path, error: message))
                    if !context.json { printer.failure(CLIFailure("couldn't import \(name): \(message)")) }
                }
            }
        }
        printer.clearStatus()
        if context.json { try printer.json(result) }
        else if result.imported.count + result.duplicates.count > 1 || !result.failed.isEmpty {
            printer.note("\(result.imported.count) added, \(result.duplicates.count) already there, \(result.failed.count) failed")
        }
        if !result.failed.isEmpty { throw ExitCode.failure }
    }
}

// MARK: list

enum CLISort: String, CaseIterable, ExpressibleByArgument {
    case recent, title, author, added

    var librarySort: LibrarySort {
        switch self {
        case .recent: .recent
        case .title: .title
        case .author: .author
        case .added: .dateAdded
        }
    }
}

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "show your library", aliases: ["ls"])

    @OptionGroup var global: GlobalOptions

    @Option(help: "recent, title, author or added")
    var sort: CLISort = .recent

    @Option(help: "only one shelf: books or pdfs")
    var shelf: String?

    func run() async throws {
        let context = try Context(global)
        let formats = context.core.formats
        var shelfFilter: LibraryShelf?
        if let shelf {
            guard let match = formats.shelves.first(where: { $0.rawValue == shelf.lowercased() }) else {
                throw CLIFailure("there's no shelf called “\(shelf)”",
                                 hint: "try one of: " + formats.shelves.map(\.rawValue).joined(separator: ", "), code: CLIFailure.usageCode)
            }
            shelfFilter = match
        }
        let entries = try await context.core.library.entries(sortedBy: sort.librarySort, shelf: shelfFilter)
        if context.json {
            try context.printer.json(entries.map { DocumentJSON($0.document, position: $0.position) })
            return
        }
        let printer = context.printer
        guard !entries.isEmpty else {
            printer.line(printer.paint("nothing glossed yet", .title))
            printer.note("add a book with: gloss import ~/Downloads/book.epub")
            return
        }
        let table = TerminalTable(
            columns: [.init("id", style: .faint), .init("title", flexible: true, style: .strong),
                      .init("author", flexible: true, style: .muted), .init("kind", style: .faint),
                      .init("read", style: .muted, alignRight: true), .init("added", style: .faint)],
            rows: entries.map { entry in
                [Format.shortID(entry.document.id), entry.document.title, entry.document.author,
                 formats.badge(of: entry.document.kind),
                 entry.position.map { Format.percent($0.progression) } ?? "—",
                 Format.relative(entry.document.addedAt, now: context.now)]
            })
        printer.line(table.render(on: printer.terminal))
    }
}

// MARK: book

struct BookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "book", abstract: "look at, edit or trash one book",
        subcommands: [BookShowCommand.self, BookEditCommand.self, BookTrashCommand.self],
        defaultSubcommand: BookShowCommand.self)
}

struct BookShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "details about a book")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a title, id or gloss:// link") var book: String

    struct Output: Encodable {
        var book: DocumentJSON
        var pages: Int
        var highlights: Int
        var linkedPassages: Int
    }

    func run() async throws {
        let context = try Context(global)
        let document = try await context.references.document(book)
        let position = try await context.core.library.position(of: document.id)
        let pages = try await context.core.pages.tree(of: document.id).root.walk().count
        let highlights = try await context.core.highlights.highlights(in: document.id).count
        let linked = try await context.core.links.linkedPassages(in: document.id).count
        if context.json {
            try context.printer.json(Output(book: DocumentJSON(document, position: position), pages: pages,
                                            highlights: highlights, linkedPassages: linked))
            return
        }
        let printer = context.printer
        printer.line(printer.paint(document.title, .title))
        if !document.author.isEmpty { printer.line(printer.paint(document.author, .muted)) }
        printer.line()
        var rows: [(String, String)] = [
            ("kind", context.core.formats.badge(of: document.kind)),
            ("size", Format.bytes(document.fileSize)),
        ]
        if let filename = document.originalFilename { rows.append(("file", filename)) }
        if let pageCount = document.metadata.pageCount { rows.append(("pages", String(pageCount))) }
        if let language = document.metadata.language { rows.append(("language", language)) }
        if let publisher = document.metadata.publisher { rows.append(("publisher", publisher)) }
        rows.append(("added", Format.relative(document.addedAt, now: context.now)))
        if let opened = document.lastOpenedAt { rows.append(("last read", Format.relative(opened, now: context.now))) }
        if let position {
            rows.append(("progress", Format.percent(position.progression) + (position.label.map { " · \($0)" } ?? "")))
        }
        rows.append(("notes", "\(pages) \(pages == 1 ? "page" : "pages")"))
        rows.append(("highlights", String(highlights)))
        rows.append(("linked passages", String(linked)))
        rows.append(("id", document.id.stringValue))
        rows.append(("link", GlossLink.document(document.id).string))
        let labelWidth = rows.map { DisplayWidth.of($0.0) }.max() ?? 0
        for (label, value) in rows {
            printer.line(printer.paint(DisplayWidth.pad(label, to: labelWidth), .faint) + "  " + value)
        }
    }
}

struct BookEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "change a book's title, author or cover")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a title, id or gloss:// link") var book: String
    @Option(help: "a new title") var title: String?
    @Option(help: "a new author") var author: String?
    @Option(help: "an image file to use as the cover") var cover: String?
    @Flag(help: "go back to the cover from the file") var resetCover = false

    func validate() throws {
        guard title != nil || author != nil || cover != nil || resetCover else {
            throw ValidationError("tell gloss what to change: --title, --author, --cover or --reset-cover")
        }
        if cover != nil && resetCover { throw ValidationError("pick either --cover or --reset-cover") }
        if let title, title.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("a book needs a title") }
    }

    func run() async throws {
        let context = try Context(global)
        var document = try await context.references.document(book)
        if title != nil || author != nil {
            document = try await context.core.library.updateDetails(document.id, title: title, author: author)
        }
        if let cover {
            let url = context.environment.url(forPath: cover)
            guard let data = FileManager.default.contents(atPath: url.path) else { throw CLIFailure("couldn't read \(cover)") }
            guard CoverImage.sniffMimeType(data).hasPrefix("image/") else {
                throw CLIFailure("\(cover) doesn't look like an image", hint: "png, jpeg, gif, webp or svg work")
            }
            document = try await context.core.library.setCover(document.id, imageData: data)
        } else if resetCover {
            document = try await context.core.library.setCover(document.id, imageData: nil)
        }
        if context.json { try context.printer.json(DocumentJSON(document)); return }
        context.printer.success("updated \(context.printer.title(document.title))")
    }
}

struct BookTrashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trash", abstract: "move a book and its notes to the trash")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a title, id or gloss:// link") var book: String

    func run() async throws {
        let context = try Context(global)
        let document = try await context.references.document(book)
        let entry = try await context.core.trash.trash(.document, id: document.id.stringValue)
        if context.json { try context.printer.json(TrashEntryJSON(entry, expires: try await context.core.trash.expiry(of: entry))); return }
        context.printer.success("moved \(context.printer.title(document.title)) and its notes to the trash")
        context.printer.note("changed your mind? gloss trash restore \(Format.shortID(entry.id))")
    }
}

// MARK: highlights

struct HighlightsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "highlights", abstract: "list or delete a book's highlights",
        subcommands: [HighlightsListCommand.self, HighlightsDeleteCommand.self],
        defaultSubcommand: HighlightsListCommand.self)
}

struct HighlightsListCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        let names = CLIEnvironment.current.partNames
        return CommandConfiguration(
            commandName: "list", abstract: "a book's highlights, in reading order",
            discussion: """
            each highlight shows the part of the book it's in, a --match ref that links exactly its words (when \
            they appear once in that part), and “heading?” when it's a short line on its own, which usually means \
            a heading. \(names.isEmpty ? "--part" : names.map { "--\($0)" }.joined(separator: "/")) N or --chapter \
            show only one part's highlights.
            """)
    }

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a title, id or gloss:// link") var book: String
    @Option(help: "only this part of the book, counting from 1 (a format's own word for its parts works as a flag too)",
            transform: { try PartFlags.Selection.parse($0) }) var part: [PartFlags.Selection] = []
    @Option(help: "only parts whose title has these words (\"6\", \"replication\")") var chapter: String?

    func validate() throws {
        if part.count > 1 { throw ValidationError("pick one part of the book") }
        if let selection = part.first, selection.number < 1 { throw ValidationError("\(selection.flag) counts from 1") }
    }

    func run() async throws {
        let context = try Context(global)
        let document = try await context.references.document(book)
        var highlights = try await context.core.highlights.highlights(in: document.id)
        let filtering = !part.isEmpty || chapter != nil
        // Where each highlight sits in the text; books without text gloss can read just list.
        var bookText: BookText?
        if !highlights.isEmpty {
            do { bookText = try await context.core.passages.text(of: document.id) }
            catch let error as GlossError where filtering { throw CLIFailure(error.description) }
            catch {}
        }
        let places = Dictionary(uniqueKeysWithValues: highlights.map { ($0.id, bookText?.place(of: $0.passage)) })
        var unplaced = 0
        if filtering, let bookText {
            try PartFlags.check(part.first, against: bookText.partName)
            let scope = Set(bookText.parts(number: part.first?.number, chapter: chapter).map(\.index))
            guard !scope.isEmpty else {
                throw CLIFailure("\(document.title) has no such \(bookText.partName) with text",
                                 hint: "see its parts with: gloss text \(Format.shortID(document.id))")
            }
            unplaced = highlights.filter { places[$0.id].flatMap { $0 } == nil }.count
            highlights = highlights.filter { places[$0.id].flatMap { $0 }.map { scope.contains($0.part.index) } ?? false }
        }
        if context.json {
            try context.printer.json(highlights.map { HighlightJSON($0, place: places[$0.id].flatMap { $0 }, partName: bookText?.partName) })
            if unplaced > 0 { context.printer.warn(Self.unplacedNote(unplaced, bookText)) }
            return
        }
        let printer = context.printer
        guard !highlights.isEmpty else {
            printer.note(filtering ? "no highlights there" : "no highlights in \(document.title) yet")
            if unplaced > 0 { printer.warn(Self.unplacedNote(unplaced, bookText)) }
            return
        }
        printer.line(printer.paint(document.title, .title))
        for highlight in highlights {
            let place = places[highlight.id].flatMap { $0 }
            let swatch = printer.paint("●", TerminalStyle(color: Self.color(highlight.color)))
            let part = place.flatMap { place in place.part.number.map { "\(bookText?.partName ?? "part") \($0)" } }
            let label = place?.part.label ?? highlight.passage.label
            let meta = [Format.shortID(highlight.id), label, part == label ? nil : part,
                        place?.ref.map { "--match \($0)" }].compactMap { $0 }.joined(separator: " · ")
            let lines = TextWrap.wrap("“\(highlight.passage.quote)”", width: min(printer.terminal.width, 100), indent: "  ")
            let heading = place?.looksLikeHeading == true ? " " + printer.paint("heading?", .accent2Style) : ""
            printer.line()
            printer.line(swatch + " " + lines.first!.dropFirst(2) + (lines.count == 1 ? heading : ""))
            for (index, line) in lines.dropFirst().enumerated() { printer.line(line + (index == lines.count - 2 ? heading : "")) }
            printer.line("  " + printer.paint(meta, .faint))
        }
        if filtering {
            printer.line()
            let headings = highlights.filter { places[$0.id].flatMap { $0 }?.looksLikeHeading == true }.count
            printer.note("\(highlights.count) \(highlights.count == 1 ? "highlight" : "highlights"), \(headings) heading?")
        }
        if unplaced > 0 { printer.warn(Self.unplacedNote(unplaced, bookText)) }
    }

    static func unplacedNote(_ count: Int, _ bookText: BookText?) -> String {
        let noun = bookText?.partName ?? "part"
        return "\(count) \(count == 1 ? "highlight" : "highlights") couldn't be placed in a \(noun), so \(count == 1 ? "it isn't" : "they aren't") shown; "
            + "see every highlight with: gloss highlights list <book>"
    }

    static func color(_ color: HighlightColor) -> TerminalColor {
        switch color {
        case .yellow: .ansi256(221)
        case .green: .ansi256(114)
        case .blue: .ansi256(111)
        case .pink: .ansi256(211)
        case .purple: .ansi256(141)
        }
    }
}

struct HighlightsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "delete a highlight (notes and links stay)")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "the highlight's id (or its short id)") var highlight: String
    @Option(help: "the book it's in (speeds things up for short ids)") var book: String?

    func run() async throws {
        let context = try Context(global)
        let documents: [Document]
        if let book { documents = [try await context.references.document(book)] }
        else { documents = try await context.core.library.entries().map(\.document) }
        var matches: [Highlight] = []
        for document in documents {
            matches += try await context.core.highlights.highlights(in: document.id).filter {
                $0.id.stringValue == highlight.lowercased() || References.matchesFragment($0.id.stringValue, highlight)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw CLIFailure(matches.isEmpty ? "couldn't find that highlight" : "“\(highlight)” matches more than one highlight",
                             hint: "list them with: gloss highlights <book>")
        }
        try await context.core.highlights.delete(match.id)
        if context.json { try context.printer.json(HighlightJSON(match)); return }
        context.printer.success("deleted the highlight “\(DisplayWidth.truncate(match.passage.quote, to: 50))”")
    }
}
