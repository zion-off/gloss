/// Turns the touched lines into headings of `level`, or back into paragraphs.
public struct ToggleHeading: MarkdownEditCommand {
    public let level: Int
    public init(level: Int) { self.level = min(6, max(1, level)) }

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        let lines = LineStructure.all(in: document, touching: selection).filter { !$0.isBlank && !$0.isCode }
        return !lines.isEmpty && lines.allSatisfy { $0.leaf.kind == .heading && $0.leaf.attributes.level == level }
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        let lines = LineStructure.all(in: document, touching: selection).filter { !$0.isBlank && !$0.isCode }
        guard !lines.isEmpty else {
            // An empty line becomes an empty heading ready for typing.
            let line = LineStructure(document: document, lineIndex: document.text.lineIndex(containing: selection.lowerBound))
            guard line.isBlank else { return nil }
            let prefix = String(repeating: "#", count: level) + " "
            return EditResult(edits: [.insert(prefix, at: line.line.lowerBound)], originalSelection: selection,
                              lowerAfterInsertions: true, upperAfterInsertions: true)
        }
        let remove = isActive(document, selection: selection)
        let prefix = remove ? "" : String(repeating: "#", count: level) + " "
        let edits = lines.map { TextEdit(range: $0.quoteEnd..<$0.marker.upperBound, replacement: prefix) }
        return EditResult(edits: edits, originalSelection: selection, lowerAfterInsertions: true, upperAfterInsertions: true)
    }
}

/// List styles the format bar and slash menu can apply.
public enum ListStyle: Sendable {
    case bullet, ordered, task

    func matches(_ block: Block) -> Bool {
        guard block.kind == .listItem else { return false }
        switch self {
        case .bullet: return block.attributes.ordered == false && block.attributes.checked == nil
        case .ordered: return block.attributes.ordered == true
        case .task: return block.attributes.checked != nil
        }
    }

    func marker(number: Int) -> String {
        switch self {
        case .bullet: "- "
        case .ordered: "\(number). "
        case .task: "- [ ] "
        }
    }
}

/// Turns the touched lines into list items of a style, or removes the markers when they all
/// already are. Indentation is kept; other markers (headings, other list styles) are replaced.
public struct ToggleList: MarkdownEditCommand {
    public let style: ListStyle
    public init(_ style: ListStyle) { self.style = style }

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        let lines = LineStructure.all(in: document, touching: selection).filter { !$0.isBlank && !$0.isCode }
        return !lines.isEmpty && lines.allSatisfy { style.matches($0.leaf) }
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        var lines = LineStructure.all(in: document, touching: selection).filter { !$0.isCode }
        if lines.count > 1 { lines.removeAll(where: \.isBlank) }
        guard !lines.isEmpty else { return nil }
        let remove = isActive(document, selection: selection)
        var edits: [TextEdit] = []
        for (index, line) in lines.enumerated() {
            if remove {
                edits.append(.delete(line.marker))
            } else if line.leaf.kind == .heading {
                edits.append(TextEdit(range: line.quoteEnd..<line.marker.upperBound, replacement: style.marker(number: index + 1)))
            } else {
                edits.append(TextEdit(range: line.marker, replacement: style.marker(number: index + 1)))
            }
        }
        return EditResult(edits: edits, originalSelection: selection, lowerAfterInsertions: true, upperAfterInsertions: true)
    }
}

/// Adds or removes one level of `> ` on the touched lines.
public struct ToggleQuote: MarkdownEditCommand {
    public init() {}

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        let lines = LineStructure.all(in: document, touching: selection).filter { !$0.isBlank || $0.block.kind == .quote }
        return !lines.isEmpty && lines.allSatisfy { $0.block.kind == .quote }
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        var lines = LineStructure.all(in: document, touching: selection).filter { !$0.isCode }
        if lines.count > 1 { lines.removeAll { $0.isBlank && $0.block.kind != .quote } }
        guard !lines.isEmpty else { return nil }
        let remove = isActive(document, selection: selection)
        let edits: [TextEdit] = lines.map { line in
            if remove, let marker = line.block.syntax.first { return .delete(marker) }
            return .insert("> ", at: line.line.lowerBound)
        }
        return EditResult(edits: edits, originalSelection: selection, lowerAfterInsertions: true, upperAfterInsertions: true)
    }
}

/// Wraps the touched lines in a fenced code block, or unwraps the block around the cursor.
public struct ToggleCodeBlock: MarkdownEditCommand {
    public init() {}

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        enclosingBlock(document, selection) != nil
    }

    private func enclosingBlock(_ document: MarkdownDocument, _ selection: Range<Int>) -> Block? {
        document.blocks.first { $0.kind == .codeBlock && $0.range.lowerBound <= selection.lowerBound && selection.upperBound <= $0.range.upperBound }
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        let text = document.text
        if let block = enclosingBlock(document, selection) {
            // Delete each fence line together with one adjacent newline.
            let edits: [TextEdit] = block.syntax.enumerated().map { index, fence in
                if index == 0 { return .delete(fence.lowerBound..<min(text.length, fence.upperBound + 1)) }
                return .delete(max(0, fence.lowerBound - 1)..<fence.upperBound)
            }
            return EditResult(edits: edits, originalSelection: selection)
        }
        let indices = text.lineIndices(touching: selection)
        let first = text.lines[indices.lowerBound], last = text.lines[indices.upperBound]
        let edits: [TextEdit] = [.insert("```\n", at: first.lowerBound), .insert("\n```", at: last.upperBound)]
        let original = selection.isEmpty ? selection : first.lowerBound..<last.upperBound
        return EditResult(edits: edits, originalSelection: original, lowerAfterInsertions: true, upperAfterInsertions: false)
    }
}

/// Code that adapts to the selection: inline code within a line, a code block across lines.
public struct ToggleCode: MarkdownEditCommand {
    public init() {}

    private func usesBlock(_ document: MarkdownDocument, _ selection: Range<Int>) -> Bool {
        ToggleCodeBlock().isActive(document, selection: selection) || document.text.lineIndices(touching: selection).count > 1
    }

    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool {
        usesBlock(document, selection) ? ToggleCodeBlock().isActive(document, selection: selection)
            : ToggleInline.code.isActive(document, selection: selection)
    }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        usesBlock(document, selection) ? ToggleCodeBlock().edit(document, selection: selection)
            : ToggleInline.code.edit(document, selection: selection)
    }
}

/// Inserts a horizontal divider on its own line.
public struct InsertDivider: MarkdownEditCommand {
    public init() {}
    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool { false }
    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        let line = document.text.lines[document.text.lineIndex(containing: selection.lowerBound)]
        if document.text.isBlank(line) {
            return EditResult(edits: [TextEdit(range: line, replacement: "---\n")], originalSelection: line.upperBound..<line.upperBound,
                              lowerAfterInsertions: true, upperAfterInsertions: true)
        }
        return EditResult(edits: [.insert("\n---\n", at: line.upperBound)], originalSelection: line.upperBound..<line.upperBound,
                          lowerAfterInsertions: true, upperAfterInsertions: true)
    }
}
