import ArgumentParser
import Foundation
import GlossCore
import GlossMarkdown
import GlossTerminal

// MARK: link --batch

extension LinkCommand {
    /// One value in a batch entry: `"quote": "…"`, `"nth": 2`, `"force": true`.
    enum FlagValue: Decodable {
        case string(String), int(Int), bool(Bool)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
            else if let int = try? container.decode(Int.self) { self = .int(int) }
            else { self = .string(try container.decode(String.self)) }
        }
    }

    /// The flags an entry may set: everything that says which words and which passage.
    static func batchFlags(partNames: [String]) -> Set<String> {
        Set(["text", "text-offset", "text-nth", "text-after", "to", "quote", "from", "through", "match", "offset", "nth",
             "part", "chapter", "before", "after", "ignore-case", "force"] + partNames)
    }

    func runBatch(_ source: String, context: Context) async throws {
        let entries = try readBatch(source, context: context)
        let partNames = context.environment.partNames
        let page = try await context.references.page(self.page)
        var texts: [DocumentID: BookText] = [:]
        var results: [BatchEntryJSON] = []
        let printer = context.printer

        for (index, entry) in entries.enumerated() {
            let number = index + 1
            let label = Self.label(of: entry, number: number)
            printer.status("linking \(number) of \(entries.count)…")
            do {
                let command = try command(for: entry, page: page, partNames: partNames)
                guard let done = try await command.perform(context: context, texts: &texts, mode: .batch) else { continue }
                results.append(BatchEntryJSON(number: number, ok: true, result: LinkResultJSON(done)))
                if !context.json { printSuccess(done, number: number, label: label, printer: printer) }
            } catch {
                let failure = BatchEntryJSON(number: number, error: error)
                results.append(failure)
                if !context.json { printFailure(failure, label: label, error: error, printer: printer) }
            }
        }
        printer.clearStatus()

        let after = try await context.references.page(page.id.stringValue)
        let unchanged = LinkScanner.unlinked(after.body) == LinkScanner.unlinked(page.body)
        let links = LinkScanner.links(in: after.body).filter {
            if case .passage = GlossLink(string: $0.destination) { true } else { false }
        }.count
        let failed = results.filter { !$0.ok }.count
        if context.json {
            try printer.json(BatchJSON(dryRun: dryRun, entries: entries.count, succeeded: entries.count - failed, failed: failed,
                                       page: PageJSON(after), pageLinks: links, textUnchanged: unchanged, results: results))
        } else {
            let tally = "\(entries.count) \(entries.count == 1 ? "entry" : "entries"), \(failed) failed"
                + (dryRun ? " (dry run, nothing written)" : "")
            printer.line()
            printer.line(printer.paint(tally, failed > 0 ? .warning : .strong)
                         + printer.paint(" · the page has \(links) passage \(links == 1 ? "link" : "links")"
                                         + (unchanged ? " and its text is unchanged apart from links" : ""), .muted))
        }
        if !unchanged {
            // gloss link refuses any write that changes more than links, so this is someone else's edit.
            printer.failure(CLIFailure("the page's text changed apart from links while gloss was linking",
                                       hint: "every link gloss wrote changed only links, so it was edited meanwhile; "
                                           + "check it with: gloss read \(Format.shortID(page.id)) --raw"))
            throw ExitCode(2)
        }
        if failed > 0 { throw ExitCode.failure }
    }

    private func readBatch(_ source: String, context: Context) throws -> [[String: FlagValue]] {
        let data: Data
        if source == "-" {
            data = Data(context.environment.readStdin().utf8)
        } else {
            let url = context.environment.url(forPath: source)
            guard let contents = FileManager.default.contents(atPath: url.path) else { throw CLIFailure("couldn't read \(source)") }
            data = contents
        }
        let entries: [[String: FlagValue]]
        do { entries = try JSONDecoder().decode([[String: FlagValue]].self, from: data) }
        catch {
            throw CLIFailure("\(source == "-" ? "stdin" : source) isn't a json array of flag objects",
                             hint: #"like: [{"text": "replica", "quote": "Each node that stores a copy"}]"#, code: CLIFailure.usageCode)
        }
        guard !entries.isEmpty else { throw CLIFailure("there's nothing to link in \(source == "-" ? "stdin" : source)", code: CLIFailure.usageCode) }
        return entries
    }

    /// The entry as a `gloss link` of its own: its flags, then the command line's for the ones it
    /// doesn't set, parsed and checked like any command line.
    private func command(for entry: [String: FlagValue], page: Page, partNames: [String]) throws -> LinkCommand {
        let allowed = Self.batchFlags(partNames: partNames)
        if let unknown = entry.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw CLIFailure("“\(unknown)” isn't a flag an entry can set",
                             hint: "use gloss link's flags without their dashes: " + allowed.sorted().joined(separator: ", "),
                             code: CLIFailure.usageCode)
        }
        var arguments = [page.id.stringValue]
        for (name, value) in entry.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .bool(true): arguments.append("--\(name)")
            case .bool(false): break
            case .int(let number): arguments += ["--\(name)", String(number)]
            case .string(let text): arguments += ["--\(name)", text]
            }
        }
        arguments += sharedArguments(skipping: Set(entry.keys), partNames: partNames)
        return try LinkCommand.parse(Array(PartFlags.rewrite(["link"] + arguments, names: partNames).dropFirst()))
    }

    /// This command line's flags as arguments, leaving out the ones an entry sets itself.
    private func sharedArguments(skipping keys: Set<String>, partNames: [String]) -> [String] {
        let options: [(String, String?)] = [
            ("text", text), ("text-offset", textOffset), ("text-nth", textNth.map(String.init)), ("text-after", textAfter),
            ("to", to), ("quote", quote), ("from", from), ("through", through), ("match", match), ("offset", offset),
            ("nth", nth.map(String.init)), ("chapter", chapter), ("before", before), ("after", after),
        ]
        var arguments: [String] = []
        for case let (name, value?) in options where !keys.contains(name) { arguments += ["--\(name)", value] }
        if let selection = part.first, keys.isDisjoint(with: ["part"] + partNames) {
            arguments += ["--part", selection.noun.map { "\($0):\(selection.number)" } ?? String(selection.number)]
        }
        if ignoreCase, !keys.contains("ignore-case") { arguments.append("--ignore-case") }
        if force, !keys.contains("force") { arguments.append("--force") }
        if dryRun { arguments.append("--dry-run") }
        return arguments
    }

    /// How a line of the report names an entry: its words in the page.
    static func label(of entry: [String: FlagValue], number: Int) -> String {
        switch entry["text"] ?? entry["text-offset"] ?? entry["quote"] {
        case .string(let text): "“\(DisplayWidth.truncate(text, to: 40))”"
        default: "entry \(number)"
        }
    }

    private func printSuccess(_ done: Performed, number: Int, label: String, printer: Printer) {
        let verb: String
        switch done.outcome {
        case .linked: verb = "linked"
        case .relinked: verb = "re-pointed"
        case .alreadyLinked: verb = "already linked"
        case .quoted: verb = "quoted"
        case .alreadyQuoted: verb = "already quoted"
        case .dryRun: verb = "would link"
        }
        let candidate = done.picked.candidate
        let place = [candidate.label, candidate.part.map { "\(done.bookText.partName) \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let line = done.words.map { " · line \($0.match.line)" } ?? ""
        printer.line(printer.paint(String(number).leftPadded(3), .faint) + " " + printer.paint("✔", .success) + " \(verb) \(label)"
                     + printer.paint(line + " → " + place + " · \(candidate.ref.range.count) chars", .faint))
        if let warning = Self.lengthWarning(candidate) {
            printer.line("      " + printer.paint("! " + warning, .warning))
        }
    }

    private func printFailure(_ failure: BatchEntryJSON, label: String, error: any Error, printer: Printer) {
        printer.line(printer.paint(String(failure.number).leftPadded(3), .faint) + " " + printer.paint("✘", .danger)
                     + " \(label): \(failure.error ?? "failed")")
        if let ambiguity = error as? Ambiguity {
            for row in ambiguity.rows {
                printer.line(Self.render(row, on: printer.terminal).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
            }
        }
        if let hint = failure.hint, !hint.isEmpty {
            printer.line(hint.split(separator: "\n").map { printer.paint("      " + $0, .muted) }.joined(separator: "\n"))
        }
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}

// MARK: json

struct BatchJSON: Encodable {
    var dryRun: Bool
    var entries: Int
    var succeeded: Int
    var failed: Int
    var page: PageJSON
    /// `gloss://passage` links in the page afterwards.
    var pageLinks: Int
    /// Whether the page's text, links aside, is what it was before the batch.
    var textUnchanged: Bool
    var results: [BatchEntryJSON]
}

struct BatchEntryJSON: Encodable {
    struct Candidate: Encodable {
        var number: Int
        var place: String
        var text: String
        var pick: String
        var exact: String
    }

    var number: Int
    var ok: Bool
    var result: LinkResultJSON?
    var error: String?
    var hint: String?
    /// For several matches: "book" or "notes", and every match with the flags that pick it.
    var side: String?
    var candidates: [Candidate]?

    init(number: Int, ok: Bool, result: LinkResultJSON) {
        self.number = number
        self.ok = ok
        self.result = result
    }

    init(number: Int, error: any Error) {
        self.number = number
        ok = false
        switch error {
        case let ambiguity as LinkCommand.Ambiguity:
            self.error = ambiguity.message
            hint = ambiguity.hint
            side = ambiguity.side
            candidates = ambiguity.rows.map { Candidate(number: $0.number, place: $0.place, text: $0.match, pick: $0.pick, exact: $0.exact) }
        case let failure as CLIFailure:
            self.error = failure.message
            hint = failure.hint
        case let error as GlossError:
            self.error = error.description
        default:
            // ArgumentParser's own: unknown flags, values it can't read, validation.
            let lines = LinkCommand.message(for: error).split(separator: "\n").map(String.init)
            self.error = lines.first ?? "failed"
            hint = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : nil
        }
    }
}
