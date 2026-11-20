import GlossMarkdown

/// A page's text as it reads: every inline element's syntax (`**`, backticks, a link's
/// brackets and address, an escape's backslash) left out, block markers kept. Lets
/// `gloss link --text` find "a replica stores" in `a **replica** stores`, and words with
/// brackets after a link has escaped them (`[a \[b\]](…)`).
struct VisibleNotesText {
    let document: MarkdownDocument
    let string: String
    /// For each UTF-16 unit of `string`, the body range it came from; an escaped character's
    /// range includes its backslash, so a link never lands between the two.
    let sources: [Range<Int>]

    init(_ document: MarkdownDocument) {
        self.document = document
        let units = document.text.units
        var hidden = [Bool](repeating: false, count: units.count)
        var escapes = Set<Int>()
        for inline in document.allInlines {
            for range in inline.syntax { for index in range where index < units.count { hidden[index] = true } }
            if inline.kind == .escape, let backslash = inline.syntax.first?.lowerBound { escapes.insert(backslash) }
        }
        var visible: [UInt16] = []
        var sources: [Range<Int>] = []
        var pendingEscape: Int?
        for index in units.indices {
            if hidden[index] {
                if escapes.contains(index) { pendingEscape = index }
                continue
            }
            visible.append(units[index])
            sources.append((pendingEscape ?? index)..<(index + 1))
            pendingEscape = nil
        }
        string = String(decoding: visible, as: UTF16.self)
        self.sources = sources
    }

    /// Body ranges of every occurrence of `needle` as the page reads, fitted to the formatting
    /// around them; occurrences that cut through formatting are left out.
    func ranges(of needle: String, ignoringCase: Bool, wholeWords: Bool) -> [Range<Int>] {
        FoldedText.ranges(of: needle, in: string, whitespace: .collapsed, ignoringCase: ignoringCase, wholeWords: wholeWords)
            .compactMap { found in
                guard !found.isEmpty, found.upperBound <= sources.count else { return nil }
                return fit(sources[found.lowerBound].lowerBound..<sources[found.upperBound - 1].upperBound)
            }
    }

    /// The visible text inside a body range.
    func text(in range: Range<Int>) -> String {
        let units = Array(string.utf16)
        let inside = sources.indices.filter { range.contains(sources[$0].upperBound - 1) }
        return String(decoding: inside.map { units[$0] }, as: UTF16.self)
    }

    /// Grows a range over the syntax of elements whose content it covers whole, so the link
    /// wraps them (`[a **replica** stores](…)`); nil when it would split one (`a **rep`).
    /// A range inside an element's content stays inside it (`**[replica](…)**`).
    func fit(_ range: Range<Int>) -> Range<Int>? {
        var range = range
        var changed = true
        while changed {
            changed = false
            for inline in document.allInlines where inline.kind != .escape && inline.range.overlaps(range) {
                let content = inline.contentRange
                if content.lowerBound <= range.lowerBound, range.upperBound <= content.upperBound { continue }
                guard range.lowerBound <= content.lowerBound, content.upperBound <= range.upperBound else { return nil }
                let grown = min(range.lowerBound, inline.range.lowerBound)..<max(range.upperBound, inline.range.upperBound)
                if grown != range { range = grown; changed = true }
            }
        }
        return range
    }
}
