import Foundation

/// One part of a book's extracted text (an epub section, a pdf page), as `gloss text` lists it.
public struct BookTextPart: Hashable, Sendable {
    /// Index into `BookText.chunks`.
    public var index: Int
    /// The 1-based number people use for it (`--section 12`); nil when the format can't say.
    public var number: Int?
    public var label: String?
    /// Where search hits and `gloss link --match` place it (`epub-section:11`).
    public var locator: Locator
    public var text: String

    /// UTF-16 units, as offsets count them.
    public var length: Int { text.utf16.count }
}

/// Where a passage someone made in the reader (a highlight) sits in the extracted text.
public struct BookTextPlace: Hashable, Sendable {
    public var part: BookTextPart
    /// The passage's words in that part, when they appear there exactly once: a ref `gloss link
    /// --match` takes to link the same words.
    public var ref: BookTextRef?
    /// A guess: the passage is a short line on its own without closing punctuation.
    public var looksLikeHeading: Bool
}

extension BookText {
    /// Every part with text, in reading order.
    public var parts: [BookTextPart] {
        chunks.indices.map(part)
    }

    public func part(_ index: Int) -> BookTextPart {
        let chunk = chunks[index]
        return BookTextPart(index: index, number: locating.partNumber(of: chunk), label: chunk.label, locator: chunk.locator,
                            text: chunk.text)
    }

    /// The parts a selection names: a part number, words from the label ("replication",
    /// "6"), or both. With neither, every part.
    public func parts(number: Int? = nil, chapter: String? = nil) -> [BookTextPart] {
        parts.filter { part in
            if let number, part.number != number { return false }
            if let chapter, !Self.label(part.label ?? "", hasWords: chapter) { return false }
            return true
        }
    }

    /// Where a passage sits: the part its locator names, or else the one part whose text has
    /// its words. Nil when neither tells.
    public func place(of passage: Passage) -> BookTextPlace? {
        let needle = FoldedText(passage.quote, whitespace: .collapsed).units
        guard !needle.isEmpty else { return nil }
        let candidates: [Int]
        if let number = locating.partNumber(of: passage.locator),
           let index = chunks.firstIndex(where: { locating.partNumber(of: $0) == number }) {
            candidates = [index]
        } else {
            candidates = chunks.indices.filter { !FoldedText(chunks[$0].text, whitespace: .collapsed).occurrences(of: needle).isEmpty }
        }
        guard candidates.count == 1, let index = candidates.first else { return nil }
        let text = chunks[index].text
        let folded = FoldedText(text, whitespace: .collapsed)
        let ranges = folded.occurrences(of: needle).map { folded.sourceRange($0..<($0 + needle.count)) }
        return BookTextPlace(
            part: part(index),
            ref: ranges.count == 1 ? BookTextRef(chunk: chunks[index].locator, range: ranges[0]) : nil,
            looksLikeHeading: ranges.first.map { Self.isHeadingLike($0, in: text) } ?? false)
    }

    /// A line on its own, under 100 characters, not ending like a sentence or a lead-in.
    static func isHeadingLike(_ range: Range<Int>, in text: String) -> Bool {
        let units = Array(text.utf16)
        func isBlank(_ slice: ArraySlice<UInt16>) -> Bool {
            slice.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0xA0 }
        }
        let lineStart = units[..<range.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let lineEnd = units[range.upperBound...].firstIndex(of: 0x0A) ?? units.count
        guard isBlank(units[lineStart..<range.lowerBound]), isBlank(units[range.upperBound..<lineEnd]) else { return false }
        let words = Passage.normalize(String(decoding: units[range], as: UTF16.self))
        guard !words.isEmpty, words.count < 100, let last = words.last else { return false }
        return !".:;,".contains(last)
    }
}
