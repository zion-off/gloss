import Foundation

/// What to find in a book's text (`gloss link --quote/--from/--match/--offset`). Words match
/// whole words, ignoring spacing and line breaks, and optionally case.
public struct BookTextQuery: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        /// Every occurrence of these words.
        case quote(String)
        /// From an occurrence of the first words through the first occurrence of the second
        /// words that ends at or after it, in the same part.
        case span(from: String, through: String)
        /// An exact stretch of extracted text.
        case ref(BookTextRef)
        /// UTF-16 offsets into the text of part `part` (1-based, as `partNumber` counts).
        case offsets(part: Int, range: Range<Int>)
    }

    public var target: Target
    /// Only this part (1-based).
    public var part: Int?
    /// Only the text chunk with this locator (a search hit's location).
    public var chunk: Locator?
    /// Only parts whose label has these words ("3", "loomings").
    public var chapter: String?
    /// Text that must come right before the match (whitespace aside).
    public var before: String?
    /// Text that must come right after it.
    public var after: String?
    public var ignoringCase: Bool

    public init(_ target: Target, part: Int? = nil, chunk: Locator? = nil, chapter: String? = nil, before: String? = nil,
                after: String? = nil, ignoringCase: Bool = false) {
        self.target = target
        self.part = part
        self.chunk = chunk
        self.chapter = chapter
        self.before = before
        self.after = after
        self.ignoringCase = ignoringCase
    }
}

/// One place in a book a query found, with what a person needs to choose it and what a link needs.
public struct PassageCandidate: Hashable, Sendable {
    public var ref: BookTextRef
    /// "chapter 3", "page 12".
    public var label: String?
    /// The 1-based part number (section, page).
    public var part: Int?
    /// Up to 40 characters before and after the match, whitespace-normalised, for listings.
    public var before: String
    public var after: String
    /// The passage to link: the format's quote locator, the matched text, label, progression.
    public var passage: Passage

    public static let contextLength = 40

    /// Whether the matched text says `text` (whitespace aside), to verify a ref or offsets.
    public func says(_ text: String, ignoringCase: Bool) -> Bool {
        FoldedText(passage.quote, whitespace: .collapsed, ignoringCase: ignoringCase).units
            == FoldedText(text, whitespace: .collapsed, ignoringCase: ignoringCase).units
    }
}

/// A book's extracted text, ready to be searched for passages to link.
public struct BookText: Sendable {
    public let documentID: DocumentID
    public let chunks: [TextChunk]
    public let locating: any QuoteLocating
    private let offsets: [Int]
    private let total: Int

    public init(documentID: DocumentID, chunks: [TextChunk], locating: any QuoteLocating) {
        self.documentID = documentID
        self.chunks = chunks
        self.locating = locating
        var running = 0
        var offsets: [Int] = []
        for chunk in chunks {
            offsets.append(running)
            running += chunk.text.utf16.count
        }
        self.offsets = offsets
        total = running
    }

    /// "section", "page".
    public var partName: String { locating.partName }

    /// Every candidate for a query, in reading order. Throws for refs and offsets that point
    /// nowhere; an empty result means the words aren't there.
    public func candidates(for query: BookTextQuery) throws -> [PassageCandidate] {
        switch query.target {
        case .ref(let ref):
            guard let index = chunks.firstIndex(where: { $0.locator == ref.chunk }) else {
                throw GlossError.notFound("\(ref.chunk.scheme.rawValue):\(ref.chunk.value) in this book")
            }
            return [try candidate(chunk: index, range: ref.range)]
        case .offsets(let part, let range):
            guard let index = chunks.firstIndex(where: { locating.partNumber(of: $0) == part }) else {
                throw GlossError.notFound("\(partName) \(part) in this book (or it has no text)")
            }
            return [try candidate(chunk: index, range: range)]
        case .quote(let quote):
            return try search(query) { folded in
                let needle = FoldedText(quote, whitespace: .collapsed, ignoringCase: query.ignoringCase).units
                return folded.occurrences(of: needle).map { $0..<($0 + needle.count) }
            }
        case .span(let from, let through):
            return try search(query) { folded in
                let start = FoldedText(from, whitespace: .collapsed, ignoringCase: query.ignoringCase).units
                let end = FoldedText(through, whitespace: .collapsed, ignoringCase: query.ignoringCase).units
                guard !start.isEmpty, !end.isEmpty else { return [] }
                // Both lists are sorted and the first acceptable end only moves forward: one pass.
                // Each end is whole words on its own ("end" is not in "legend").
                let ends = folded.occurrences(of: end).filter { folded.isWholeWords($0..<($0 + end.count)) }
                var next = 0
                return folded.occurrences(of: start).filter { folded.isWholeWords($0..<($0 + start.count)) }.compactMap { s in
                    let earliest = max(s, s + start.count - end.count)
                    while next < ends.count, ends[next] < earliest { next += 1 }
                    return next < ends.count ? s..<(ends[next] + end.count) : nil
                }
            }
        }
    }

    /// The candidate for an exact UTF-16 range of chunk `index`.
    public func candidate(chunk index: Int, range: Range<Int>) throws -> PassageCandidate {
        var anchoring = QuoteAnchoring(chunks[index].text)
        return try candidate(chunk: index, range: range, anchoring: &anchoring)
    }

    private func candidate(chunk index: Int, range: Range<Int>, anchoring: inout QuoteAnchoring) throws -> PassageCandidate {
        let chunk = chunks[index]
        let units = anchoring.units
        guard range.upperBound <= units.count else {
            throw GlossError.invalid("that range runs past the end of \(label(of: chunk)) (\(units.count) characters)")
        }
        func splitsScalar(_ offset: Int) -> Bool { offset < units.count && UTF16.isTrailSurrogate(units[offset]) }
        guard !splitsScalar(range.lowerBound), !splitsScalar(range.upperBound) else {
            throw GlossError.invalid("that range splits a character; offsets count utf-16 units")
        }
        let anchor = anchoring.anchor(for: range)
        guard !anchor.text.isEmpty else { throw GlossError.invalid("there's only space at \(BookTextRef(chunk: chunk.locator, range: range))") }
        guard let locator = locating.quoteLocator(for: anchor, in: chunk) else {
            throw GlossError.notAllowed("gloss can't point at \(label(of: chunk)) of this book")
        }
        let progression = total > 0 ? Double(offsets[index] + range.lowerBound) / Double(total) : 0
        func context(_ r: Range<Int>) -> String {
            Passage.normalize(String(decoding: units[r], as: UTF16.self))
        }
        // Normalising trims, so keep the one space that separates the context from the match.
        func isSpace(_ offset: Int) -> Bool {
            offset >= 0 && offset < units.count && (Unicode.Scalar(units[offset])?.properties.isWhitespace ?? false)
        }
        let before = context(max(0, range.lowerBound - 4 * PassageCandidate.contextLength)..<range.lowerBound)
            + (isSpace(range.lowerBound - 1) ? " " : "")
        let after = (isSpace(range.upperBound) ? " " : "")
            + context(range.upperBound..<min(units.count, range.upperBound + 4 * PassageCandidate.contextLength))
        return PassageCandidate(ref: BookTextRef(chunk: chunk.locator, range: range), label: chunk.label,
                                part: locating.partNumber(of: chunk),
                                before: String(before.suffix(PassageCandidate.contextLength)),
                                after: String(after.prefix(PassageCandidate.contextLength)),
                                passage: Passage(locator: locator, quote: anchor.text, label: chunk.label,
                                                 progression: min(max(progression, 0), 1)))
    }

    // MARK: Searching

    private func search(_ query: BookTextQuery, matches: (FoldedText) -> [Range<Int>]) throws -> [PassageCandidate] {
        let before = query.before.map { FoldedText($0, whitespace: .collapsed, ignoringCase: query.ignoringCase).units } ?? []
        let after = query.after.map { FoldedText($0, whitespace: .collapsed, ignoringCase: query.ignoringCase).units } ?? []
        var result: [PassageCandidate] = []
        for (index, chunk) in chunks.enumerated() where inScope(chunk, query) {
            let folded = FoldedText(chunk.text, whitespace: .collapsed, ignoringCase: query.ignoringCase)
            var anchoring: QuoteAnchoring?
            for range in matches(folded) where folded.isWholeWords(range) {
                guard Self.ends(folded.units, before: range.lowerBound, with: before),
                      Self.starts(folded.units, after: range.upperBound, with: after) else { continue }
                if anchoring == nil { anchoring = QuoteAnchoring(chunk.text) }
                result.append(try candidate(chunk: index, range: folded.sourceRange(range), anchoring: &anchoring!))
            }
        }
        return result
    }

    private func inScope(_ chunk: TextChunk, _ query: BookTextQuery) -> Bool {
        if let part = query.part, locating.partNumber(of: chunk) != part { return false }
        if let scope = query.chunk, chunk.locator != scope { return false }
        if let chapter = query.chapter, !Self.label(chunk.label ?? "", hasWords: chapter) { return false }
        return true
    }

    private func label(of chunk: TextChunk) -> String {
        locating.partNumber(of: chunk).map { "\(partName) \($0)" } ?? chunk.label ?? partName
    }

    /// Whether the folded text right before `index` (spaces aside) ends with `context`.
    static func ends(_ units: [UInt16], before index: Int, with context: [UInt16]) -> Bool {
        guard !context.isEmpty else { return true }
        var end = index
        while end > 0, units[end - 1] == 0x20 { end -= 1 }
        return end >= context.count && Array(units[(end - context.count)..<end]) == context
    }

    /// Whether the folded text right after `index` (spaces aside) starts with `context`.
    static func starts(_ units: [UInt16], after index: Int, with context: [UInt16]) -> Bool {
        guard !context.isEmpty else { return true }
        var start = index
        while start < units.count, units[start] == 0x20 { start += 1 }
        return units.count - start >= context.count && Array(units[start..<(start + context.count)]) == context
    }

    /// Whether a label contains `words` as whole words, in order ("3" is in "Chapter 3. Loomings",
    /// not in "chapter 30").
    static func label(_ label: String, hasWords words: String) -> Bool {
        let haystack = TextMatcher.words(in: label).map(\.folded)
        let needle = TextMatcher.words(in: words).map(\.folded)
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
}

/// Loads a book's text for linking: the stored file, through its format's text extraction.
public struct PassageFinder: Sendable {
    let store: any LibraryStore
    let blobs: any BlobStore
    let formats: FormatRegistry

    public init(store: any LibraryStore, blobs: any BlobStore, formats: FormatRegistry) {
        self.store = store
        self.blobs = blobs
        self.formats = formats
    }

    public func text(of documentID: DocumentID) async throws -> BookText {
        guard let document = try await store.read({ try $0.documents.document(documentID) }) else { throw GlossError.notFound("that book") }
        guard document.trash == nil else { throw GlossError.inTrash(document.title) }
        guard let extractor = formats.textExtractor(for: document.kind), let locating = formats.quoteLocator(for: document.kind) else {
            throw GlossError.notAllowed("gloss can't link into \(document.kind.rawValue) books by their text")
        }
        guard let data = try await blobs.data(for: document.contentHash) else { throw GlossError.notFound("the file for \(document.title)") }
        let chunks = try extractor.extractText(from: data)
        return BookText(documentID: documentID, chunks: chunks, locating: locating)
    }
}
