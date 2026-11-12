/// Toggles an inline wrapper (`**bold**`, `*italic*`, `` `code` ``, `~~strike~~`).
///
/// - Inside an existing span of the same kind: removes its markers.
/// - Empty selection inside a word: wraps the word. Elsewhere: inserts an empty pair with the
///   cursor in the middle.
/// - A selection: wraps each touched line's part of it (whitespace trimmed, block markers
///   excluded), absorbing same-kind spans inside it so markers never nest.
public struct ToggleInline: MarkdownEditCommand {
    public let kind: InlineKind
    public let marker: String

    public init(kind: InlineKind, marker: String) {
        self.kind = kind
        self.marker = marker
    }

    public static let bold = ToggleInline(kind: .strong, marker: "**")
    public static let italic = ToggleInline(kind: .emphasis, marker: "*")
    public static let code = ToggleInline(kind: .code, marker: "`")
    public static let strikethrough = ToggleInline(kind: .strikethrough, marker: "~~")

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        enclosing(document, selection) != nil
    }

    private func enclosing(_ document: MarkdownDocument, _ selection: Range<Int>) -> Inline? {
        document.allInlines.last { inline in
            inline.kind == kind && inline.range.lowerBound <= selection.lowerBound && selection.upperBound <= inline.range.upperBound
                && !(selection.isEmpty && (selection.lowerBound == inline.range.lowerBound || selection.lowerBound == inline.range.upperBound))
        }
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        if let existing = enclosing(document, selection) {
            let edits = existing.syntax.map(TextEdit.delete)
            return EditResult(edits: edits, originalSelection: clamp(selection, to: existing.contentRange))
        }
        let text = document.text
        if selection.isEmpty {
            if let word = wordRange(around: selection.lowerBound, in: text) {
                // Keep the caret where it was inside the word.
                var result = wrap([word], document: document)
                let caret = selection.lowerBound + marker.utf16.count
                result.selection = caret..<caret
                return result
            }
            let offset = selection.lowerBound
            let length = marker.utf16.count
            return EditResult(edits: [.insert(marker + marker, at: offset)], selection: offset + length..<offset + length)
        }
        var segments: [Range<Int>] = []
        for line in LineStructure.all(in: document, touching: selection) where !line.isBlank {
            let start = max(selection.lowerBound, line.isCode ? line.line.lowerBound : line.contentStart)
            let end = min(selection.upperBound, line.line.upperBound)
            guard start < end else { continue }
            let trimmed = trimWhitespace(start..<end, in: text)
            if !trimmed.isEmpty { segments.append(trimmed) }
        }
        return segments.isEmpty ? nil : wrap(segments, document: document)
    }

    private func wrap(_ segments: [Range<Int>], document: MarkdownDocument) -> EditResult {
        var edits: [TextEdit] = []
        let inner = document.allInlines.filter { $0.kind == kind }
        for segment in segments {
            edits.append(.insert(marker, at: segment.lowerBound))
            for absorbed in inner where segment.lowerBound <= absorbed.range.lowerBound && absorbed.range.upperBound <= segment.upperBound {
                edits += absorbed.syntax.map(TextEdit.delete)
            }
            edits.append(.insert(marker, at: segment.upperBound))
        }
        let span = segments.first!.lowerBound..<segments.last!.upperBound
        return EditResult(edits: edits, originalSelection: span, lowerAfterInsertions: true, upperAfterInsertions: false)
    }

    private func clamp(_ selection: Range<Int>, to content: Range<Int>) -> Range<Int> {
        let lower = min(max(selection.lowerBound, content.lowerBound), content.upperBound)
        let upper = min(max(selection.upperBound, lower), content.upperBound)
        return lower..<upper
    }
}

func isWordUnit(_ unit: UInt16) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return true } // surrogate halves belong to words
    return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "'"
}

/// The word around `offset`, if the cursor is strictly inside or at the edge of one.
func wordRange(around offset: Int, in text: MarkdownText) -> Range<Int>? {
    var start = offset, end = offset
    while start > 0, isWordUnit(text.units[start - 1]) { start -= 1 }
    while end < text.length, isWordUnit(text.units[end]) { end += 1 }
    return start < end ? start..<end : nil
}

func trimWhitespace(_ range: Range<Int>, in text: MarkdownText) -> Range<Int> {
    var lower = range.lowerBound, upper = range.upperBound
    while lower < upper, text.units[lower].isSpaceOrTab || text.units[lower] == .newline { lower += 1 }
    while upper > lower, text.units[upper - 1].isSpaceOrTab || text.units[upper - 1] == .newline { upper -= 1 }
    return lower..<upper
}
