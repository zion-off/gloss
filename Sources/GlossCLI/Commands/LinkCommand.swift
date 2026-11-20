import ArgumentParser
import Foundation
import GlossCore
import GlossMarkdown
import GlossTerminal

// MARK: link

struct LinkCommand: AsyncParsableCommand {
    /// The part flags (`--section`, `--page`) come from the registered formats, so the
    /// help is built when it's asked for, inside a run.
    static var configuration: CommandConfiguration {
        let names = CLIEnvironment.current.partNames
        let flags = names.isEmpty ? "--part" : names.map { "--\($0)" }.joined(separator: "/")
        return CommandConfiguration(
            commandName: "link", abstract: "link words in a notes page to a passage in a book",
            discussion: """
            say which words in the page with --text (or --text-offset), and which passage in the book with --quote, \
            --from/--through, --match or \(flags) with --offset. without --text, gloss adds the passage to the \
            page as a quote line instead.

            gloss never guesses: when words appear more than once it lists every match with the flag that picks it \
            (--nth, --match, --text-nth) and stops, or asks which one on a terminal. matching ignores spacing and line \
            breaks; add -i to ignore case. offsets count utf-16 units, 0-based, end exclusive: in the page as \
            gloss read --raw prints it, in the book's extracted text as --list shows it. a book's parts are called \
            \(names.isEmpty ? "parts" : names.map { "\($0)s" }.joined(separator: " or ")) depending on its format; \
            --part N works for all of them.

            --text-after links the first match of --text after words that appear once in the page, usually a \
            heading, so repeated words are linked in the right section. gloss warns when a passage runs past \
            \(Self.longPassage) characters: a closer --through makes a better link. gloss link only ever adds or \
            re-points links: if the page's text would change in any other way, it writes nothing.

            --batch links many words in one go from a json array (a file, or - for stdin). each object holds the \
            flags of one gloss link, named without their dashes ("text-after", "quote", "section": 12, \
            "ignore-case": true); flags given on the command line apply to every entry that doesn't set them. \
            entries run in order, a failure doesn't stop the rest, and the summary says whether the page's text \
            stayed the same apart from links. combine with --dry-run to check every entry first.

            examples:
              gloss link "moby dick" --text "his obsession" --quote "the white whale"
              gloss link notes --text "the sea" --to "the waves" --quote "the sea" --nth 2
              gloss link notes --text "that speech" --from "Call me Ishmael" --through "the watery part of the world"
              gloss link notes --quote "the whale" --list --json      (see every match and its --match ref)
              gloss link notes --text "here" --match epub-section:4@1204-1213 --quote "the whale"
              gloss link notes --text-offset 10-14 --\(names.first ?? "part") 5 --offset 1204-1213 --dry-run
              gloss link notes --text-after "## 2. leaders" --text "replica" --quote "Each node that stores a copy"
              gloss link notes --batch links.json --match epub-section:12 --dry-run
            """)
    }

    @OptionGroup var global: GlobalOptions
    @Argument(help: "the notes page (or book, for its main page): title, id or gloss:// link") var page: String

    @Option(help: "the words in the page that become the link") var text: String?
    @Option(name: .customLong("text-offset"), help: "the words by their place in the page: START-END") var textOffset: String?
    @Option(name: .customLong("text-nth"), help: "which match of --text, counting from 1") var textNth: Int?
    @Option(name: .customLong("text-after"), help: "link the first match of --text after these words, which appear once in the page")
    var textAfter: String?

    @Option(help: "the book to link into (default: the page's own book)") var to: String?
    @Option(help: "the passage's words (with --match or --offset: what they should say)") var quote: String?
    @Option(help: "a longer passage: where it starts") var from: String?
    @Option(help: "a longer passage: where it ends") var through: String?
    @Option(help: "an exact match from a listing (epub-section:4@1204-1213), or a search hit's place (epub-section:4)") var match: String?
    @Option(help: "the passage by its place in the text of the part --part (or its format's own flag) names: START-END") var offset: String?
    @Option(help: "which match in the book, counting from 1 in reading order") var nth: Int?
    @Option(help: "only this part of the book, counting from 1 (a format's own word for its parts works as a flag too, see above)",
            transform: { try PartFlags.Selection.parse($0) }) var part: [PartFlags.Selection] = []
    @Option(help: "only sections whose title has these words (\"3\", \"loomings\")") var chapter: String?
    @Option(help: "words that come right before the passage") var before: String?
    @Option(help: "words that come right after the passage") var after: String?
    @Flag(name: [.customShort("i"), .customLong("ignore-case")], help: "match regardless of case") var ignoreCase = false
    @Flag(help: "link even if the text at --match or --offset doesn't say --quote") var force = false
    @Flag(help: "list every match and write nothing") var list = false
    @Flag(name: .customLong("dry-run"), help: "show what would be linked and write nothing") var dryRun = false
    @Option(help: "link many words from a json array of flag objects (a file, or - for stdin)") var batch: String?

    /// Past this many characters a passage is more of a chapter than a quote.
    static let longPassage = 900

    func validate() throws {
        if batch != nil {
            if list { throw ValidationError("--batch links, so it doesn't go with --list") }
            return  // each entry is checked with these flags added
        }
        let exact = [match.map { _ in "--match" }, offset.map { _ in "--offset" }].compactMap { $0 }
        if exact.count > 1 { throw ValidationError("pick either --match or --offset") }
        if (from == nil) != (through == nil) { throw ValidationError("a longer passage needs both --from and --through") }
        if from != nil, quote != nil { throw ValidationError("pick either --quote or --from/--through") }
        if from != nil, offset != nil || isExactRef { throw ValidationError("--from/--through finds text, so it doesn't go with --match or --offset") }
        if part.count > 1 { throw ValidationError("pick one part of the book: \(partFlags)") }
        if offset != nil, part.isEmpty { throw ValidationError("--offset counts within one part: add \(partFlags) N") }
        if quote == nil, from == nil, match == nil || !isExactRef, offset == nil {
            throw ValidationError("which passage? give --quote, --from/--through, --match or \(partFlags) with --offset")
        }
        if textNth != nil, text == nil { throw ValidationError("--text-nth picks among the matches of --text") }
        if textAfter != nil, text == nil { throw ValidationError("--text-after says where to look for --text") }
        if textOffset != nil, Self.range(textOffset) == nil { throw ValidationError("--text-offset needs START-END, like 10-24") }
        if offset != nil, Self.range(offset) == nil { throw ValidationError("--offset needs START-END, like 1204-1251") }
        if let match, isExactRef, BookTextRef(string: match) == nil { throw ValidationError("--match needs a ref like epub-section:4@1204-1251") }
        for (name, value) in [("--nth", nth), ("--text-nth", textNth)] {
            if let value, value < 1 { throw ValidationError("\(name) counts from 1") }
        }
        if let selection = part.first, selection.number < 1 { throw ValidationError("\(selection.flag) counts from 1") }
        if list, dryRun { throw ValidationError("pick either --list or --dry-run") }
        try rejectFlagsAnExactPlaceIgnores()
    }

    /// An exact place (`--match` with a range, `--offset`, `--text-offset`) names one spot, so flags
    /// that choose among matches or narrow the search would be silently ignored: refuse them.
    /// (A usage error rather than a warning: no combination of them with an exact place means
    /// anything, and a script that passes one expects it to have an effect.)
    private func rejectFlagsAnExactPlaceIgnores() throws {
        if isExact {
            var ignored = [("--nth", nth != nil), ("--chapter", chapter != nil), ("--before", before != nil),
                           ("--after", after != nil)]
            // --offset counts within the part --part (or --section, --page) names; a --match range already says which.
            if isExactRef { ignored += [(part.first?.flag ?? "--part", !part.isEmpty)] }
            let given = ignored.filter(\.1).map(\.0)
            if !given.isEmpty {
                let place = isExactRef ? "--match with a range" : "--offset"
                throw ValidationError("\(place) names one exact place, so \(given.joined(separator: ", ")) would do nothing\n"
                    + "drop \(given.count == 1 ? "it" : "them"), or drop \(place == "--offset" ? "--offset" : "the range") to search by words instead")
            }
        }
        if textOffset != nil, textNth != nil || textAfter != nil {
            throw ValidationError("--text-offset names one exact place, so \(textNth != nil ? "--text-nth" : "--text-after") would do nothing\n"
                + "drop one of them")
        }
    }

    /// `--match scheme:value@start-end` is exact; `--match scheme:value` only says where to look.
    private var isExactRef: Bool { match?.contains("@") ?? false }

    static func range(_ text: String?) -> Range<Int>? { text.flatMap(BookTextRef.range) }

    /// "--section/--page" (or "--part"): the flags that name a part, as the registered formats call it.
    private var partFlags: String {
        let names = CLIEnvironment.current.partNames
        return names.isEmpty ? "--part" : names.map { "--\($0)" }.joined(separator: "/")
    }

    func run() async throws {
        let context = try Context(global)
        if let batch { return try await runBatch(batch, context: context) }
        var texts: [DocumentID: BookText] = [:]
        guard let done = try await perform(context: context, texts: &texts, mode: .single) else { return }
        try report(done, context: context)
    }

    /// One command line, or one entry of a batch: never asks, lists ambiguity as an error.
    enum Mode { case single, batch }

    /// What a link did, for the report.
    struct Performed {
        var outcome: Outcome
        var page: Page
        var url: String?
        var words: Words?
        var picked: Picked
        var notesCount: Int?
        var document: Document
        var bookText: BookText
        var linkRange: Range<Int>?
    }

    /// Finds the words and the passage and links them (or, for --list, shows the matches and
    /// returns nil). `texts` keeps each book's extracted text across a batch.
    func perform(context: Context, texts: inout [DocumentID: BookText], mode: Mode) async throws -> Performed? {
        let page = try await context.references.page(self.page)
        let book: Document
        if let to {
            book = try await context.references.document(to)
        } else {
            guard let own = try await context.core.library.document(page.documentID) else {
                throw CLIFailure("couldn't find the book for that page")
            }
            book = own
        }
        let bookText: BookText
        if let cached = texts[book.id] {
            bookText = cached
        } else {
            do { bookText = try await context.core.passages.text(of: book.id) }
            catch let error as GlossError { throw CLIFailure(error.description) }
            texts[book.id] = bookText
        }

        let query = try bookQuery(for: bookText)
        let candidates: [PassageCandidate]
        do { candidates = try bookText.candidates(for: query) }
        catch let error as GlossError { throw CLIFailure(error.description, code: CLIFailure.usageCode) }
        let notes = try notesMatches(in: page)

        if list {
            try showList(book: candidates, notes: notes, bookText: bookText, document: book, page: page, context: context)
            return nil
        }
        // Words that aren't there fail before anything asks which of several to use.
        if candidates.isEmpty { _ = try pickPassage(candidates, bookText: bookText, document: book, context: context, mode: mode) }
        let words = try notes.map { try pickWords($0, page: page, context: context, mode: mode) }
        let (chosen, number) = try pickPassage(candidates, bookText: bookText, document: book, context: context, mode: mode)
        var done = Performed(outcome: .dryRun, page: page, url: nil, words: words,
                             picked: Picked(candidate: chosen, number: number, of: candidates.count),
                             notesCount: notes?.count, document: book, bookText: bookText)
        if dryRun { return done }
        guard let words else {
            let target = try await context.core.links.target(for: chosen.passage, in: book.id)
            let url = GlossLink.passage(target.id).string
            done.url = url
            if LinkScanner.links(in: page.body).contains(where: { $0.destination == url }) {
                done.outcome = .alreadyQuoted
                return done
            }
            let added = try await context.core.links.addQuote(of: chosen.passage, in: book.id, to: page.id)
            done.outcome = .quoted
            done.page = added.page
            return done
        }
        let result: NotesLinkResult
        do {
            result = try await context.core.links.link(words.match.range, expecting: words.match.text, in: page.id,
                                                       to: chosen.passage, in: book.id)
        } catch let error as GlossError { throw CLIFailure(error.description) }
        switch result.change {
        case .linked: done.outcome = .linked
        case .relinked(let from): done.outcome = .relinked(from)
        case .alreadyLinked: done.outcome = .alreadyLinked
        }
        done.page = result.page
        done.url = GlossLink.passage(result.target.id).string
        done.linkRange = result.range
        return done
    }

    // MARK: The book side

    private func bookQuery(for text: BookText) throws -> BookTextQuery {
        try PartFlags.check(part.first, against: text.partName)
        let part = part.first?.number
        let target: BookTextQuery.Target
        var scope: Locator?
        if let match, let ref = BookTextRef(string: match), isExactRef {
            target = .ref(ref)
        } else if let offset, let part, let range = Self.range(offset) {
            target = .offsets(part: part, range: range)
        } else if let from, let through {
            target = .span(from: from, through: through)
        } else if let quote {
            target = .quote(quote)
        } else {
            throw CLIFailure("which passage? give --quote, --from/--through, --match or --offset", code: CLIFailure.usageCode)
        }
        if let match, !isExactRef {
            guard let colon = match.firstIndex(of: ":"), match.index(after: colon) < match.endIndex else {
                throw CLIFailure("--match needs a ref like epub-section:4@1204-1251, or a place like epub-section:4", code: CLIFailure.usageCode)
            }
            scope = Locator(scheme: LocatorScheme(String(match[..<colon])), value: String(match[match.index(after: colon)...]))
        }
        return BookTextQuery(target, part: part, chunk: scope, chapter: chapter, before: before, after: after, ignoringCase: ignoreCase)
    }

    private var isExact: Bool { isExactRef || offset != nil }

    /// The candidate to link and its 1-based number among the matches (0 for an exact place).
    private func pickPassage(_ candidates: [PassageCandidate], bookText: BookText, document: Document,
                             context: Context, mode: Mode) throws -> (PassageCandidate, Int) {
        if isExact, let only = candidates.first {
            if let quote, !force, !only.says(quote, ignoringCase: ignoreCase) {
                throw CLIFailure("the text at \(only.ref) says “\(DisplayWidth.truncate(only.passage.quote, to: 80))”, not “\(quote)”",
                                 hint: "check the offsets, or link it anyway with --force", code: CLIFailure.usageCode)
            }
            return (only, 0)
        }
        let what = from.map { "“\($0)” … “\(through ?? "")”" } ?? "“\(quote ?? "")”"
        guard !candidates.isEmpty else {
            var hints = [ignoreCase ? nil : "try -i to ignore case", "see where words appear: gloss search \"\(quote ?? from ?? "")\" --book \(Format.shortID(document.id)) --in text"]
            if !part.isEmpty || chapter != nil || before != nil || after != nil || match != nil {
                hints.insert("or drop \(partFlags)/--chapter/--before/--after to look everywhere", at: 0)
            }
            throw CLIFailure("couldn't find \(what) in \(document.title)", hint: hints.compactMap { $0 }.joined(separator: "\n"))
        }
        if let nth {
            guard nth <= candidates.count else {
                throw CLIFailure("\(what) appears \(Self.times(candidates.count)) in \(document.title), so there's no match \(nth)",
                                 code: CLIFailure.usageCode)
            }
            return (candidates[nth - 1], nth)
        }
        guard candidates.count > 1 else { return (candidates[0], 1) }
        let rows = candidates.enumerated().map { index, candidate in
            Row(number: index + 1, place: place(of: candidate, in: bookText), before: candidate.before, match: candidate.passage.quote,
                after: candidate.after, pick: "--nth \(index + 1)", exact: "--match \(candidate.ref)")
        }
        let index = try choose(rows, message: "\(what) appears \(Self.times(candidates.count)) in \(document.title)",
                               hint: "pick one with --nth N or its --match ref; narrow with --\(bookText.partName), --chapter, --before or --after",
                               side: "book", json: candidates.enumerated().map { CandidateJSON($1, number: $0 + 1, bookText: bookText) },
                               context: context, mode: mode)
        return (candidates[index], index + 1)
    }

    private func place(of candidate: PassageCandidate, in bookText: BookText) -> String {
        let part = candidate.part.map { "\(bookText.partName) \($0)" }
        let label = candidate.label?.trimmingCharacters(in: .whitespaces)
        return [label, part == label ? nil : part].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: The notes side

    struct Words {
        var match: NotesTextMatch
        var number: Int
    }

    /// Every match of the words (after --text-after's words, with it), or nil when the command
    /// isn't linking words.
    private func notesMatches(in page: Page) throws -> [NotesTextMatch]? {
        let body = page.body
        if let textOffset, let range = Self.range(textOffset) {
            // After an earlier run the link's "[" has shifted the words by one.
            guard let match = NotesTextFinder.match(wrappedAt: range, in: body) ?? NotesTextFinder.match(at: range, in: body) else {
                throw CLIFailure("gloss can't link the words at \(textOffset)",
                                 hint: "links need a few words on one line, outside code (offsets count utf-16 units in gloss read --raw)",
                                 code: CLIFailure.usageCode)
            }
            if let text, !force, !NotesTextFinder.range(match.range, in: body, says: text, ignoringCase: ignoreCase) {
                throw CLIFailure("the page says “\(match.text)” at \(textOffset), not “\(text)”",
                                 hint: "check the offsets, or link it anyway with --force", code: CLIFailure.usageCode)
            }
            return [match]
        }
        guard let text else { return nil }
        let matches = NotesTextFinder.matches(of: text, in: body, ignoringCase: ignoreCase)
        guard let textAfter else { return matches }
        let anchors = NotesTextFinder.ranges(of: textAfter, in: body, ignoringCase: ignoreCase)
        guard anchors.count == 1, let anchor = anchors.first else {
            let title = page.title.isEmpty ? PageService.untitled : page.title
            throw CLIFailure(anchors.isEmpty ? "couldn't find “\(textAfter)” in \(title)"
                                 : "“\(textAfter)” appears \(Self.times(anchors.count)) in \(title), so it doesn't mark one place",
                             hint: "--text-after needs words that appear once in the page, like a heading\n"
                                 + "see the page with: gloss read \(Format.shortID(page.id)) --raw")
        }
        return matches.filter { $0.range.lowerBound >= anchor.upperBound }
    }

    private func pickWords(_ matches: [NotesTextMatch], page: Page, context: Context, mode: Mode) throws -> Words {
        let title = page.title.isEmpty ? PageService.untitled : page.title
        if textOffset != nil, let only = matches.first { return Words(match: only, number: 1) }
        let text = self.text ?? ""
        guard !matches.isEmpty else {
            if let textAfter {
                throw CLIFailure("couldn't find “\(text)” after “\(textAfter)” in \(title)",
                                 hint: (ignoreCase ? "" : "try -i to ignore case\n") + "see the page with: gloss read \(Format.shortID(page.id)) --raw")
            }
            let anywhere = FoldedText.ranges(of: text, in: page.body, ignoringCase: ignoreCase, wholeWords: true)
                + NotesTextFinder.ranges(of: text, in: page.body, ignoringCase: ignoreCase, wholeWords: true)
            if !anywhere.isEmpty {
                throw CLIFailure("“\(text)” is in \(title) only inside code, a link's address or across lines",
                                 hint: "links need a few words on one line, outside code")
            }
            throw CLIFailure("couldn't find “\(text)” in \(title)",
                             hint: (ignoreCase ? "" : "try -i to ignore case\n") + "see the page with: gloss read \(Format.shortID(page.id)) --raw")
        }
        if let textNth {
            guard textNth <= matches.count else {
                throw CLIFailure("“\(text)” appears \(Self.times(matches.count)) in \(title), so there's no match \(textNth)",
                                 code: CLIFailure.usageCode)
            }
            return Words(match: matches[textNth - 1], number: textNth)
        }
        // The first match after the anchor is what --text-after means, not a guess.
        guard matches.count > 1, textAfter == nil else { return Words(match: matches[0], number: 1) }
        let rows = matches.enumerated().map { index, match in
            Row(number: index + 1, place: "line \(match.line)", before: match.before, match: match.text, after: match.after,
                pick: "--text-nth \(index + 1)", exact: "--text-offset \(match.range.lowerBound)-\(match.range.upperBound)")
        }
        let index = try choose(rows, message: "“\(text)” appears \(Self.times(matches.count)) in \(title)",
                               hint: "pick one with --text-nth N or --text-offset START-END",
                               side: "notes", json: matches.enumerated().map { NotesMatchJSON($1, number: $0 + 1) }, context: context,
                               mode: mode)
        return Words(match: matches[index], number: index + 1)
    }

    // MARK: Choosing

    struct Row {
        var number: Int
        var place: String
        var before: String
        var match: String
        var after: String
        var pick: String
        var exact: String
    }

    /// Several matches and no way to tell: on a terminal, ask; otherwise list them all and stop
    /// (exit 64), in json too. In a batch, the listing is the entry's failure. Never guesses.
    private func choose<J: Encodable>(_ rows: [Row], message: String, hint: String, side: String, json: [J], context: Context,
                                      mode: Mode) throws -> Int {
        if mode == .batch { throw Ambiguity(message: message, hint: hint, side: side, rows: rows) }
        let printer = context.printer
        let interactive = context.environment.stdinIsTTY && printer.terminal.isTTY && !context.json
        guard interactive else { try Self.list(rows, message: message, hint: hint, side: side, json: json, context: context) }
        printer.clearStatus()
        context.environment.output.err(message + "\n")
        for row in rows {
            context.environment.output.err(Self.render(row, on: printer.stderrTerminal) + "\n")
        }
        printer.ask("which one? (1–\(rows.count), return to stop)")
        let answer = context.environment.readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let number = Int(answer), (1...rows.count).contains(number) else {
            throw CLIFailure("nothing linked", hint: hint, code: 1)
        }
        return number - 1
    }

    /// Lists every match with the flags that pick it, on stderr (or as json), and stops with exit 64.
    static func list<J: Encodable>(_ rows: [Row], message: String, hint: String, side: String, json: [J], context: Context) throws -> Never {
        let printer = context.printer
        if context.json {
            try printer.json(AmbiguityJSON(error: message, hint: hint, side: side, candidates: json))
            throw ExitCode(CLIFailure.usageCode)
        }
        printer.failure(CLIFailure(message))
        let stderr = printer.stderrTerminal
        for row in rows {
            context.environment.output.err(render(row, on: stderr) + "\n")
        }
        context.environment.output.err(stderr.paint(hint, .muted) + "\n")
        throw ExitCode(CLIFailure.usageCode)
    }

    /// Several matches in a batch entry: its failure, with the rows that would pick each.
    struct Ambiguity: Error {
        var message: String
        var hint: String
        var side: String
        var rows: [Row]
    }

    static func render(_ row: Row, on terminal: Terminal) -> String {
        let before = (row.before.count >= PassageCandidate.contextLength ? "…" : "") + row.before
        let after = row.after + (row.after.count >= PassageCandidate.contextLength ? "…" : "")
        let shown = DisplayWidth.truncate(row.match, to: 60)
        let snippet = before + mark(shown, on: terminal) + after
        return "  " + terminal.paint(String(row.number).leftPad(3), .strong) + "  " + terminal.paint(row.place, .heading) + "\n"
            + "       " + snippet + "\n"
            + "       " + terminal.paint(row.pick + "  ·  " + row.exact, .faint)
    }

    static func times(_ count: Int) -> String { count == 1 ? "once" : count == 2 ? "twice" : "\(count) times" }

    // MARK: Listing

    private func showList(book candidates: [PassageCandidate], notes: [NotesTextMatch]?, bookText: BookText, document: Document,
                          page: Page, context: Context) throws {
        let printer = context.printer
        if context.json {
            try printer.json(ListJSON(book: candidates.enumerated().map { CandidateJSON($1, number: $0 + 1, bookText: bookText) },
                                      notes: notes?.enumerated().map { NotesMatchJSON($1, number: $0 + 1) }))
            return
        }
        let title = page.title.isEmpty ? PageService.untitled : page.title
        if let notes {
            printer.line(printer.paint("in \(title)", .heading) + printer.paint("  \(notes.count)", .faint))
            for (index, match) in notes.enumerated() {
                printer.line(Self.render(Row(number: index + 1, place: "line \(match.line)", before: match.before, match: match.text,
                                             after: match.after, pick: "--text-nth \(index + 1)",
                                             exact: "--text-offset \(match.range.lowerBound)-\(match.range.upperBound)"), on: printer.terminal))
            }
            if notes.isEmpty { printer.note("  nothing linkable matches “\(text ?? "")”") }
            printer.line()
        }
        printer.line(printer.paint("in \(document.title)", .heading) + printer.paint("  \(candidates.count)", .faint))
        for (index, candidate) in candidates.enumerated() {
            printer.line(Self.render(Row(number: index + 1, place: place(of: candidate, in: bookText), before: candidate.before,
                                         match: candidate.passage.quote, after: candidate.after, pick: "--nth \(index + 1)",
                                         exact: "--match \(candidate.ref)"), on: printer.terminal))
        }
        if candidates.isEmpty { printer.note("  nothing matches") }
    }

    // MARK: Reporting

    enum Outcome {
        case linked, relinked(String), alreadyLinked, quoted, alreadyQuoted, dryRun

        var name: String {
            switch self {
            case .linked: "linked"
            case .relinked: "relinked"
            case .alreadyLinked: "alreadyLinked"
            case .quoted: "quoted"
            case .alreadyQuoted: "alreadyQuoted"
            case .dryRun: "dryRun"
            }
        }
    }

    struct Picked {
        var candidate: PassageCandidate
        /// 1-based among the matches, 0 for an exact place.
        var number: Int
        var of: Int
    }

    private func report(_ done: Performed, context: Context) throws {
        let (outcome, page, url, words, picked) = (done.outcome, done.page, done.url, done.words, done.picked)
        let (notesCount, document, bookText) = (done.notesCount, done.document, done.bookText)
        let printer = context.printer
        if context.json {
            try printer.json(LinkResultJSON(done))
            return
        }
        let title = printer.title(page.title)
        let passage = picked.candidate
        let place = self.place(of: passage, in: bookText)
        let where_ = (place.isEmpty ? "" : place + " in ") + printer.title(document.title)
        let wordsText = words.map { printer.title($0.match.text) } ?? ""
        switch outcome {
        case .linked: printer.success("linked \(wordsText) in \(title) to \(where_)")
        case .relinked(let old): printer.success("re-pointed \(wordsText) in \(title) to \(where_) " + printer.paint("(it linked to \(old))", .faint))
        case .alreadyLinked: printer.success("\(wordsText) in \(title) already links to \(where_)")
        case .quoted: printer.success("added the passage from \(where_) to \(title)")
        case .alreadyQuoted: printer.success("\(title) already quotes that passage from \(where_)")
        case .dryRun: printer.line(printer.paint("would link", .heading) + printer.paint("  (dry run, nothing written)", .faint))
        }
        let pad = "    "
        if let words {
            let of = notesCount.map { $0 > 1 ? ", match \(words.number) of \($0)" : "" } ?? ""
            printer.line(pad + printer.paint("notes ", .muted) + " " + Self.mark(words.match.text, on: printer.terminal)
                         + printer.paint(" · line \(words.match.line)" + of + " · --text-offset \(words.match.range.lowerBound)-\(words.match.range.upperBound)", .faint))
        } else if case .dryRun = outcome {
            printer.line(pad + printer.paint("notes ", .muted) + " a quote line at the end of \(title)")
        }
        let of = picked.of > 1 && picked.number > 0 ? "match \(picked.number) of \(picked.of) · " : ""
        printer.line(pad + printer.paint("book  ", .muted) + " " + Self.snippet(passage, on: printer.terminal))
        printer.line(pad + "       " + printer.paint(of + "--match \(passage.ref)", .faint))
        if let url { printer.line(pad + printer.paint("link  ", .muted) + " " + printer.paint(url, .link)) }
        if let warning = Self.lengthWarning(picked.candidate) { printer.warn(warning) }
    }

    /// A passage past `longPassage` characters.
    static func lengthWarning(_ candidate: PassageCandidate) -> String? {
        let length = candidate.ref.range.count
        guard length > longPassage else { return nil }
        return "that passage is \(length) characters long; a closer --through would make a tighter link"
    }

    static func snippet(_ candidate: PassageCandidate, on terminal: Terminal) -> String {
        let before = (candidate.before.count >= PassageCandidate.contextLength ? "…" : "") + candidate.before
        let after = candidate.after + (candidate.after.count >= PassageCandidate.contextLength ? "…" : "")
        return before + mark(DisplayWidth.truncate(candidate.passage.quote, to: 80), on: terminal) + after
    }

    /// The matched words, in colour on a terminal and in brackets without colour.
    static func mark(_ text: String, on terminal: Terminal) -> String {
        terminal.colorEnabled ? terminal.paint(text, TerminalStyle(color: .accent, bold: true)) : "[" + text + "]"
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}

// MARK: json

struct CandidateJSON: Encodable {
    var number: Int?
    var of: Int?
    var ref: String
    var label: String?
    var part: Int?
    var partName: String
    var text: String
    var before: String
    var after: String
    var progression: Double?

    init(_ candidate: PassageCandidate, number: Int, of count: Int? = nil, bookText: BookText) {
        self.number = number > 0 ? number : nil
        of = count
        ref = candidate.ref.description
        label = candidate.label
        part = candidate.part
        partName = bookText.partName
        text = candidate.passage.quote
        before = candidate.before
        after = candidate.after
        progression = candidate.passage.progression
    }
}

struct NotesMatchJSON: Encodable {
    var number: Int
    var of: Int?
    var offset: String
    var range: [Int]
    var line: Int
    var text: String
    var before: String
    var after: String
    var linkedTo: String?

    init(_ match: NotesTextMatch, number: Int, of count: Int? = nil) {
        self.number = number
        of = count
        offset = "\(match.range.lowerBound)-\(match.range.upperBound)"
        range = [match.range.lowerBound, match.range.upperBound]
        line = match.line
        text = match.text
        before = match.before
        after = match.after
        linkedTo = match.linkDestination
    }
}

struct AmbiguityJSON<Candidate: Encodable>: Encodable {
    var error: String
    var hint: String
    /// "book" or "notes": which side was ambiguous.
    var side: String
    var candidates: [Candidate]
}

struct ListJSON: Encodable {
    var book: [CandidateJSON]
    var notes: [NotesMatchJSON]?
}

struct LinkResultJSON: Encodable {
    /// linked, relinked, alreadyLinked, quoted, alreadyQuoted or dryRun.
    var outcome: String
    var dryRun: Bool
    var url: String?
    var page: PageJSON
    var book: DocumentJSON
    var words: NotesMatchJSON?
    /// UTF-16 range of the whole `[words](gloss://…)` link in the saved page.
    var link: [Int]?
    var passage: CandidateJSON
    /// Things worth a look that didn't stop the link (a very long passage).
    var warnings: [String]?

    init(_ done: LinkCommand.Performed) {
        outcome = done.outcome.name
        if case .dryRun = done.outcome { dryRun = true } else { dryRun = false }
        url = done.url
        page = PageJSON(done.page)
        book = DocumentJSON(done.document)
        words = done.words.map { NotesMatchJSON($0.match, number: $0.number, of: done.notesCount) }
        link = done.linkRange.map { [$0.lowerBound, $0.upperBound] }
        let picked = done.picked
        passage = CandidateJSON(picked.candidate, number: picked.number, of: picked.number > 0 ? picked.of : nil, bookText: done.bookText)
        warnings = LinkCommand.lengthWarning(picked.candidate).map { [$0] }
    }
}
