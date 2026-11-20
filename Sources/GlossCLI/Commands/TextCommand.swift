import ArgumentParser
import Foundation
import GlossCore
import GlossTerminal

// MARK: text

struct TextCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        let names = CLIEnvironment.current.partNames
        let flag = "--" + (names.first ?? "part")
        return CommandConfiguration(
            commandName: "text", abstract: "a book's parts, or the text of one",
            discussion: """
            without a part, gloss lists the book's parts: their numbers, titles and lengths. name one with \
            \(names.isEmpty ? "--part" : names.map { "--\($0)" }.joined(separator: "/")) N (--part N works for every format) or \
            with words from its title (--chapter), and gloss prints its text as gloss link and search see it. \
            --from and --through cut out a stretch (either alone runs to the part's end or from its start); they \
            match like gloss link: whole words, ignoring spacing, curly quotes and dashes.

            examples:
              gloss text "moby dick"
              gloss text "moby dick" \(flag) 12
              gloss text "moby dick" --chapter loomings --from "Call me Ishmael" --through "the world"
            """)
    }

    @OptionGroup var global: GlobalOptions
    @Argument(help: "a title, id or gloss:// link") var book: String

    @Option(help: "the part to print, counting from 1 (a format's own word for its parts works as a flag too)",
            transform: { try PartFlags.Selection.parse($0) }) var part: [PartFlags.Selection] = []
    @Option(help: "the part whose title has these words (\"6\", \"replication\")") var chapter: String?
    @Option(help: "start at these words") var from: String?
    @Option(help: "end with these words") var through: String?
    @Option(help: "which match of --from (or --through alone), counting from 1") var nth: Int?
    @Flag(name: [.customShort("i"), .customLong("ignore-case")], help: "match regardless of case") var ignoreCase = false

    func validate() throws {
        if part.count > 1 { throw ValidationError("pick one part of the book") }
        if let selection = part.first, selection.number < 1 { throw ValidationError("\(selection.flag) counts from 1") }
        if let nth, nth < 1 { throw ValidationError("--nth counts from 1") }
        if nth != nil, from == nil, through == nil { throw ValidationError("--nth picks among the matches of --from or --through") }
    }

    struct PartJSON: Encodable {
        var number: Int?
        var label: String?
        /// The part's place, as `gloss link --match` and search hits write it.
        var match: String
        var length: Int

        init(_ part: BookTextPart) {
            number = part.number
            label = part.label
            match = "\(part.locator.scheme.rawValue):\(part.locator.value)"
            length = part.length
        }
    }

    struct Output: Encodable {
        var book: DocumentJSON
        var partName: String
        var part: PartJSON
        /// The stretch printed, as a `gloss link --match` ref; offsets count utf-16 units of the part.
        var ref: String
        var range: [Int]
        var text: String
    }

    func run() async throws {
        let context = try Context(global)
        let document = try await context.references.document(book)
        let bookText: BookText
        do { bookText = try await context.core.passages.text(of: document.id) }
        catch let error as GlossError { throw CLIFailure(error.description) }
        try PartFlags.check(part.first, against: bookText.partName)
        let scope = bookText.parts(number: part.first?.number, chapter: chapter)
        let selected = !part.isEmpty || chapter != nil
        if scope.isEmpty {
            throw CLIFailure(selected ? "\(document.title) has no \(selectionWords(bookText)) with text" : "\(document.title) has no text gloss can read",
                             hint: selected ? "see its parts with: gloss text \(Format.shortID(document.id))" : nil)
        }
        if from == nil, through == nil {
            guard selected else { return try list(scope, of: document, bookText: bookText, context: context) }
            guard scope.count == 1 else {
                return try ambiguous(scope, of: document, bookText: bookText, context: context)
            }
            return try show(scope[0], range: 0..<scope[0].length, of: document, bookText: bookText, context: context)
        }
        let (part, range) = try stretch(in: scope, of: document, bookText: bookText, context: context)
        try show(part, range: range, of: document, bookText: bookText, context: context)
    }

    private func selectionWords(_ bookText: BookText) -> String {
        [part.first.map { "\(bookText.partName) \($0.number)" }, chapter.map { "\(bookText.partName) titled “\($0)”" }]
            .compactMap { $0 }.joined(separator: " and ")
    }

    // MARK: Cutting

    /// The part and range `--from`/`--through` pick within the scope; several matches list and stop.
    private func stretch(in scope: [BookTextPart], of document: Document, bookText: BookText,
                         context: Context) throws -> (BookTextPart, Range<Int>) {
        let target: BookTextQuery.Target
        if let from, let through { target = .span(from: from, through: through) }
        else { target = .quote(from ?? through ?? "") }
        var candidates: [PassageCandidate] = []
        for part in scope {
            let query = BookTextQuery(target, chunk: part.locator, ignoringCase: ignoreCase)
            do { candidates += try bookText.candidates(for: query) }
            catch let error as GlossError { throw CLIFailure(error.description, code: CLIFailure.usageCode) }
        }
        let what = from.map { f in through.map { "“\(f)” … “\($0)”" } ?? "“\(f)”" } ?? "“\(through ?? "")”"
        guard !candidates.isEmpty else {
            throw CLIFailure("couldn't find \(what) in \(scope.count == 1 ? scope[0].label ?? bookText.partName : document.title)",
                             hint: ignoreCase ? nil : "try -i to ignore case")
        }
        let index: Int
        if let nth {
            guard nth <= candidates.count else {
                throw CLIFailure("\(what) appears \(LinkCommand.times(candidates.count)), so there's no match \(nth)", code: CLIFailure.usageCode)
            }
            index = nth - 1
        } else if candidates.count == 1 {
            index = 0
        } else {
            let rows = candidates.enumerated().map { number, candidate in
                LinkCommand.Row(number: number + 1, place: candidate.label ?? candidate.part.map { "\(bookText.partName) \($0)" } ?? "",
                                before: candidate.before, match: candidate.passage.quote, after: candidate.after,
                                pick: "--nth \(number + 1)", exact: candidate.part.map { "--\(bookText.partName) \($0)" } ?? "")
            }
            try LinkCommand.list(rows, message: "\(what) appears \(LinkCommand.times(candidates.count)) in \(document.title)",
                                 hint: "pick one with --nth N, or narrow with --\(bookText.partName) or --chapter", side: "book",
                                 json: candidates.enumerated().map { CandidateJSON($1, number: $0 + 1, bookText: bookText) }, context: context)
        }
        let chosen = candidates[index]
        guard let part = scope.first(where: { $0.locator == chosen.ref.chunk }) else { throw CLIFailure("couldn't find that part") }
        let range: Range<Int>
        switch (from, through) {
        case (_?, _?): range = chosen.ref.range
        case (_?, nil): range = chosen.ref.range.lowerBound..<part.length
        default: range = 0..<chosen.ref.range.upperBound
        }
        return (part, range)
    }

    // MARK: Printing

    private func show(_ part: BookTextPart, range: Range<Int>, of document: Document, bookText: BookText, context: Context) throws {
        let units = Array(part.text.utf16)
        let text = String(decoding: units[range], as: UTF16.self)
        let ref = BookTextRef(chunk: part.locator, range: range)
        if context.json {
            try context.printer.json(Output(book: DocumentJSON(document), partName: bookText.partName, part: PartJSON(part),
                                            ref: ref.description, range: [range.lowerBound, range.upperBound], text: text))
            return
        }
        // Where the text came from goes to stderr, so stdout is the book's words and nothing else.
        let stderr = context.printer.stderrTerminal
        let heading = [part.label, part.number.map { "\(bookText.partName) \($0)" }].compactMap { $0 }.joined(separator: " · ")
        context.environment.output.err(stderr.paint(heading, .heading) + stderr.paint("  --match \(ref)", .faint) + "\n")
        context.printer.line(text.hasSuffix("\n") ? String(text.dropLast()) : text)
    }

    private func list(_ parts: [BookTextPart], of document: Document, bookText: BookText, context: Context) throws {
        if context.json { try context.printer.json(parts.map(PartJSON.init)); return }
        let printer = context.printer
        printer.line(printer.paint(document.title, .title))
        let table = TerminalTable(
            columns: [.init(bookText.partName, style: .faint, alignRight: true), .init("title", flexible: true, style: .strong),
                      .init("length", style: .muted, alignRight: true), .init("match", style: .faint)],
            rows: parts.map { part in
                [part.number.map(String.init) ?? "—", part.label ?? "", Self.length(part.length),
                 "\(part.locator.scheme.rawValue):\(part.locator.value)"]
            })
        printer.line(table.render(on: printer.terminal))
        printer.note("print one with: gloss text \(Format.shortID(document.id)) --\(bookText.partName) N")
    }

    /// Several parts have the --chapter words: list them and stop, never guess.
    private func ambiguous(_ parts: [BookTextPart], of document: Document, bookText: BookText, context: Context) throws {
        let message = "“\(chapter ?? "")” is in the titles of \(parts.count) \(bookText.partName)s of \(document.title)"
        let hint = "pick one with --\(bookText.partName) N"
        if context.json {
            try context.printer.json(AmbiguityJSON(error: message, hint: hint, side: "book", candidates: parts.map(PartJSON.init)))
            throw ExitCode(CLIFailure.usageCode)
        }
        let rows = parts.map { "  " + ($0.number.map { "--\(bookText.partName) \($0)" } ?? "—") + "  " + ($0.label ?? "") }
        throw CLIFailure(message, hint: rows.joined(separator: "\n") + "\n" + hint, code: CLIFailure.usageCode)
    }

    /// "12,480 chars".
    static func length(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return (formatter.string(from: NSNumber(value: count)) ?? String(count)) + " chars"
    }
}
