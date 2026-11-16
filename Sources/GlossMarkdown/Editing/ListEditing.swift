/// Return-key behaviour in lists and quotes: continue the item, or end it when it is empty.
public enum ListContinuation {
    /// The edit for pressing Return with `selection`, or nil to insert a plain newline.
    public static func newline(in document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        guard selection.isEmpty else { return nil }
        let text = document.text
        let cursor = selection.lowerBound
        let line = LineStructure(document: document, lineIndex: text.lineIndex(containing: cursor))
        let inQuote = line.block.kind == .quote
        let isList = line.leaf.kind == .listItem
        guard isList || inQuote, !line.isCode else { return nil }
        // Pressing Return inside the markers behaves normally.
        guard cursor >= (isList ? line.marker.upperBound : line.quoteEnd) else { return nil }

        let contentEmpty = text.isBlank(line.contentStart..<line.line.upperBound)
        if contentEmpty {
            if isList {
                // An empty nested item outdents; an empty top-level item stops the list.
                if let outdent = ListIndentation.outdent(in: document, selection: selection) { return outdent }
                return EditResult(edits: [.delete(line.marker)], originalSelection: line.marker.lowerBound..<line.marker.lowerBound)
            }
            // An empty quote line ends the quote.
            let markers = line.line.lowerBound..<line.quoteEnd
            return EditResult(edits: [.delete(markers)], originalSelection: markers.lowerBound..<markers.lowerBound)
        }

        var prefix = text[line.line.lowerBound..<line.quoteEnd]
        if isList {
            prefix += text[line.indentRange]
            prefix += nextMarker(for: line.leaf, text: text)
        }
        let insertion = "\n" + prefix
        return EditResult(edits: [.insert(insertion, at: cursor)], originalSelection: cursor..<cursor,
                          lowerAfterInsertions: true, upperAfterInsertions: true)
    }

    static func nextMarker(for item: Block, text: MarkdownText) -> String {
        let marker = text[item.syntax[0]]
        if item.attributes.checked != nil {
            let bullet = marker.first.map(String.init) ?? "-"
            if item.attributes.ordered == true, let number = item.attributes.number {
                let delimiter = marker.contains(")") ? ")" : "."
                return "\(number + 1)\(delimiter) [ ] "
            }
            return "\(bullet) [ ] "
        }
        if item.attributes.ordered == true, let number = item.attributes.number {
            let delimiter = marker.contains(")") ? ")" : "."
            return "\(number + 1)\(delimiter) "
        }
        return (marker.first.map(String.init) ?? "-") + " "
    }
}

/// Tab / Shift-Tab on list items: indent or outdent by one level (two spaces), renumbering
/// ordered items for their new level.
public enum ListIndentation {
    public static let unit = "  "

    public static func indent(in document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        let lines = LineStructure.all(in: document, touching: selection).filter { $0.leaf.kind == .listItem && !$0.isCode }
        guard !lines.isEmpty else { return nil }
        let text = document.text
        var edits = lines.map { TextEdit.insert(unit, at: $0.quoteEnd) }
        var levels: [Int: Int] = [:]
        for line in lines {
            levels[text.lineIndex(containing: line.line.lowerBound)] = (ListNumbering.indentWidth(of: line, in: text) + unit.count) / 2
        }
        edits += ListNumbering.edits(in: document, levels: levels)
        return EditResult(edits: edits, originalSelection: selection, lowerAfterInsertions: true, upperAfterInsertions: true)
    }

    public static func outdent(in document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        let lines = LineStructure.all(in: document, touching: selection).filter { $0.leaf.kind == .listItem && !$0.isCode }
        let text = document.text
        var edits: [TextEdit] = []
        var levels: [Int: Int] = [:]
        for line in lines {
            let indent = line.indentRange
            guard !indent.isEmpty else { continue }
            let removed = text.units[indent.lowerBound] == .tab ? 1 : min(2, indent.count)
            let removedWidth = text.units[indent.lowerBound] == .tab ? 2 : removed
            edits.append(.delete(indent.lowerBound..<indent.lowerBound + removed))
            levels[text.lineIndex(containing: line.line.lowerBound)] = (ListNumbering.indentWidth(of: line, in: text) - removedWidth) / 2
        }
        guard !edits.isEmpty else { return nil }
        edits += ListNumbering.edits(in: document, levels: levels)
        return EditResult(edits: edits, originalSelection: selection)
    }
}

/// Clicking a task box: `[ ]` ↔ `[x]`.
public enum TaskToggle {
    /// The box range on the line containing `offset`, if that line is a task item.
    public static func boxRange(in document: MarkdownDocument, at offset: Int) -> Range<Int>? {
        let line = LineStructure(document: document, lineIndex: document.text.lineIndex(containing: offset))
        guard line.leaf.kind == .listItem, line.leaf.attributes.checked != nil else { return nil }
        let marker = line.marker
        guard let open = (marker.lowerBound..<marker.upperBound).first(where: { document.text.units[$0] == .lbracket }) else { return nil }
        return open..<open + 3
    }

    public static func toggle(in document: MarkdownDocument, at offset: Int) -> EditResult? {
        guard let box = boxRange(in: document, at: offset) else { return nil }
        let inner = box.lowerBound + 1..<box.lowerBound + 2
        let checked = document.text.units[inner.lowerBound] != .space
        return EditResult(edits: [TextEdit(range: inner, replacement: checked ? " " : "x")], selection: box.upperBound..<box.upperBound)
    }
}
