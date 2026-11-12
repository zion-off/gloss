/// Turns a selection into a link to `destination` (used by "link to passage" with a
/// `gloss://` URL), or retargets the link the selection is in.
public struct WrapInLink: MarkdownEditCommand {
    public let destination: String
    public init(destination: String) { self.destination = destination }

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        WrapInLink.enclosingLink(document, selection) != nil
    }

    /// Whether `selection` can become (or already is inside) a link.
    public static func canWrap(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        if enclosingLink(document, selection) != nil { return true }
        guard !selection.isEmpty, document.text.lineIndices(touching: selection).count == 1 else { return false }
        if document.blocks.contains(where: { $0.kind == .codeBlock && $0.range.overlaps(selection) }) { return false }
        // Not across a code span or link boundary.
        return !document.allInlines.contains { inline in
            (inline.kind == .code || inline.kind == .link || inline.kind == .autolink) && inline.range.overlaps(selection)
                && !(inline.range.lowerBound >= selection.lowerBound && inline.range.upperBound <= selection.upperBound && inline.kind == .code)
        } && !trimWhitespace(selection, in: document.text).isEmpty
    }

    static func enclosingLink(_ document: MarkdownDocument, _ selection: Range<Int>) -> Inline? {
        document.allInlines.first { $0.kind == .link && $0.contentRange.lowerBound <= selection.lowerBound && selection.upperBound <= $0.contentRange.upperBound }
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        if let link = WrapInLink.enclosingLink(document, selection), let range = link.destinationRange {
            let edit = TextEdit(range: range, replacement: MarkdownEscaping.escapeDestination(destination))
            return EditResult(edits: [edit], originalSelection: link.contentRange)
        }
        guard WrapInLink.canWrap(document, selection: selection) else { return nil }
        let target = trimWhitespace(selection, in: document.text)
        var edits: [TextEdit] = [.insert("[", at: target.lowerBound)]
        // Escape stray brackets so the label cannot end early.
        for offset in target where (document.text.units[offset] == .lbracket || document.text.units[offset] == .rbracket)
            && (offset == 0 || document.text.units[offset - 1] != .backslash) {
            edits.append(.insert("\\", at: offset))
        }
        edits.append(.insert("](\(MarkdownEscaping.escapeDestination(destination)))", at: target.upperBound))
        return EditResult(edits: edits, originalSelection: target, lowerAfterInsertions: true, upperAfterInsertions: false)
    }
}

/// The format bar's link button: `[selection]()` with the cursor in the parentheses, or `[]()`
/// with the cursor in the brackets.
public struct InsertLinkTemplate: MarkdownEditCommand {
    public init() {}

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        WrapInLink.enclosingLink(document, selection) != nil
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        if let link = WrapInLink.enclosingLink(document, selection), let destination = link.destinationRange {
            return EditResult(edits: [], selection: destination)
        }
        if selection.isEmpty {
            return EditResult(edits: [.insert("[]()", at: selection.lowerBound)], selection: selection.lowerBound + 1..<selection.lowerBound + 1)
        }
        guard document.text.lineIndices(touching: selection).count == 1 else { return nil }
        let target = trimWhitespace(selection, in: document.text)
        let edits: [TextEdit] = [.insert("[", at: target.lowerBound), .insert("]()", at: target.upperBound)]
        let caret = target.upperBound + 1 + 2  // after "[" and "]("
        return EditResult(edits: edits, selection: caret..<caret)
    }
}

/// Escaping for text gloss writes into notes (quotes, labels, destinations).
public enum MarkdownEscaping {
    /// Escapes characters that would start inline syntax, plus block markers at the start.
    public static func escapeInline(_ text: String, atLineStart: Bool = true) -> String {
        var out = ""
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            let prev = index > 0 ? chars[index - 1] : nil
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            switch char {
            case "\\", "`", "*", "[", "]", "~":
                out += "\\" + String(char)
            case "_":
                let intraword = (prev.map { $0.isLetter || $0.isNumber } ?? false) && (next.map { $0.isLetter || $0.isNumber } ?? false)
                out += intraword ? "_" : "\\_"
            case "<":
                out += next.map({ $0.isLetter || $0 == "/" }) == true ? "\\<" : "<"
            default:
                out.append(char)
            }
        }
        guard atLineStart else { return out }
        return escapeBlockStart(out)
    }

    /// Escapes a leading `#`, `>`, `-`, `+`, `1.` so text cannot become a block marker.
    public static func escapeBlockStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#>+-".contains(first) { return "\\" + text }
        let digits = text.prefix { $0.isNumber }
        if !digits.isEmpty, let after = text.dropFirst(digits.count).first, after == "." || after == ")" {
            return digits + "\\" + text.dropFirst(digits.count)
        }
        return text
    }

    /// Escapes what would end a link label early.
    public static func escapeLinkLabel(_ text: String) -> String {
        var out = ""
        for char in text {
            if char == "[" || char == "]" || char == "\\" { out += "\\" }
            out.append(char)
        }
        return out
    }

    /// Wraps destinations with spaces or unbalanced parentheses in `<…>`.
    public static func escapeDestination(_ destination: String) -> String {
        var depth = 0
        var balanced = true
        for char in destination {
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1; if depth < 0 { balanced = false } }
        }
        if destination.contains(" ") || !balanced || depth != 0 { return "<\(destination)>" }
        return destination
    }

    /// Removes backslash escapes, for showing markdown as plain text.
    public static func unescape(_ text: String) -> String {
        var out = ""
        var escaping = false
        for char in text {
            if escaping {
                if !(char.isASCII && char.isPunctuation || char.isASCII && char.isSymbol) { out.append("\\") }
                out.append(char)
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else {
                out.append(char)
            }
        }
        if escaping { out.append("\\") }
        return out
    }
}
