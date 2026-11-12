/// Blank or whitespace-only lines.
public struct BlankLineParser: BlockParser {
    public init() {}
    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        guard context.text.isBlank(slice.range) else { return nil }
        return BlockMatch(block: Block(kind: .blank, range: slice.range, contentRange: slice.range.upperBound..<slice.range.upperBound))
    }
}

/// ``` or ~~~ fenced code, up to the matching fence or the end of the text.
public struct FencedCodeParser: BlockParser {
    public init() {}

    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        guard !context.isNested else { return nil }
        let text = context.text
        guard let open = fence(in: slice.range, text: text) else { return nil }
        let infoStart = text.firstNonBlank(in: open.end..<slice.range.upperBound)
        let info = text[infoStart..<slice.range.upperBound].split(separator: " ").first.map(String.init)
        // Backtick fences may not have backticks in the info string.
        if open.char == .backtick, text[open.end..<slice.range.upperBound].utf16.contains(.backtick) { return nil }

        var syntax = [slice.range]
        var lineIndex = slice.lineIndex + 1
        var end = slice.range.upperBound
        var contentEnd = slice.range.upperBound
        var closed = false
        while lineIndex < text.lines.count {
            let line = text.lines[lineIndex]
            if let close = fence(in: line, text: text), close.char == open.char, close.count >= open.count,
               text.isBlank(close.end..<line.upperBound) {
                syntax.append(line)
                end = line.upperBound
                closed = true
                break
            }
            contentEnd = line.upperBound
            end = line.upperBound
            lineIndex += 1
        }
        let contentStart = min(slice.range.upperBound + 1, contentEnd)
        let consumed = (closed ? lineIndex : lineIndex - 1) - slice.lineIndex + 1
        let block = Block(kind: .codeBlock, range: slice.range.lowerBound..<end,
                          contentRange: contentStart..<max(contentStart, contentEnd), syntax: syntax,
                          attributes: BlockAttributes(language: info?.isEmpty == false ? info : nil))
        return BlockMatch(block: block, consumedLines: consumed)
    }

    private func fence(in range: Range<Int>, text: MarkdownText) -> (char: UInt16, count: Int, end: Int)? {
        let start = text.firstNonBlank(in: range)
        guard start - range.lowerBound <= 3, let char = text.unit(at: start), char == .backtick || char == .tilde else { return nil }
        var index = start
        while index < range.upperBound, text.units[index] == char { index += 1 }
        let count = index - start
        return count >= 3 ? (char, count, index) : nil
    }
}

/// `#` … `######` ATX headings.
public struct HeadingParser: BlockParser {
    public init() {}

    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        let text = context.text
        let start = text.firstNonBlank(in: slice.range)
        guard start - slice.range.lowerBound <= 3 else { return nil }
        var index = start
        while index < slice.range.upperBound, text.units[index] == .hash { index += 1 }
        let level = index - start
        guard (1...6).contains(level) else { return nil }
        guard index == slice.range.upperBound || text.units[index].isSpaceOrTab else { return nil }
        let contentStart = text.firstNonBlank(in: index..<slice.range.upperBound)
        let content = contentStart..<slice.range.upperBound
        let block = Block(kind: .heading, range: slice.range, contentRange: content,
                          syntax: [slice.range.lowerBound..<contentStart],
                          attributes: BlockAttributes(level: level), inlines: context.inlines(in: content))
        return BlockMatch(block: block)
    }
}

/// `---`, `***`, `___` (three or more, spaces allowed) on their own.
/// Setext headings are not supported, so `---` under text is always a divider.
public struct ThematicBreakParser: BlockParser {
    public init() {}

    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        let text = context.text
        let start = text.firstNonBlank(in: slice.range)
        guard start - slice.range.lowerBound <= 3, let char = text.unit(at: start),
              char == .dash || char == .star || char == .underscore else { return nil }
        var count = 0
        for index in start..<slice.range.upperBound {
            let unit = text.units[index]
            if unit == char { count += 1 } else if !unit.isSpaceOrTab { return nil }
        }
        guard count >= 3 else { return nil }
        return BlockMatch(block: Block(kind: .thematicBreak, range: slice.range, contentRange: slice.range.upperBound..<slice.range.upperBound,
                                       syntax: [slice.range]))
    }
}

/// `>` block quotes. The rest of the line is parsed again as a nested block (so quotes can hold
/// headings, list items and further quotes).
public struct QuoteParser: BlockParser {
    public init() {}

    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        let text = context.text
        let start = text.firstNonBlank(in: slice.range)
        guard start - slice.range.lowerBound <= 3, text.unit(at: start) == .gt else { return nil }
        var markerEnd = start + 1
        if markerEnd < slice.range.upperBound, text.units[markerEnd].isSpaceOrTab { markerEnd += 1 }
        let inner = LineSlice(lineIndex: slice.lineIndex, range: markerEnd..<slice.range.upperBound)
        let child = context.parseSlice(inner, nested: true).block
        let block = Block(kind: .quote, range: slice.range, contentRange: inner.range,
                          syntax: [slice.range.lowerBound..<markerEnd], children: [child])
        return BlockMatch(block: block)
    }
}

/// Bullet (`-`, `*`, `+`) and ordered (`1.`, `1)`) list items, with optional task boxes
/// (`- [ ]`, `- [x]`). Two spaces (or one tab) of indentation make one nesting level.
public struct ListItemParser: BlockParser {
    public init() {}

    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        let text = context.text
        let start = text.firstNonBlank(in: slice.range)
        let end = slice.range.upperBound
        guard start < end else { return nil }
        var markerEnd: Int
        var ordered = false
        var number: Int?
        let first = text.units[start]
        if first == .dash || first == .star || first == .plus {
            markerEnd = start + 1
        } else if first.isDigit {
            var index = start
            while index < end, text.units[index].isDigit, index - start < 9 { index += 1 }
            guard index < end, text.units[index] == .dot || text.units[index] == .rparen else { return nil }
            number = Int(text[start..<index])
            ordered = true
            markerEnd = index + 1
        } else {
            return nil
        }
        // A marker must be followed by a space/tab or end the line.
        if markerEnd < end {
            guard text.units[markerEnd].isSpaceOrTab else { return nil }
            markerEnd += 1
        }
        var checked: Bool?
        if markerEnd + 2 < end, text.units[markerEnd] == .lbracket, text.units[markerEnd + 2] == .rbracket,
           markerEnd + 3 == end || text.units[markerEnd + 3].isSpaceOrTab {
            let box = text.units[markerEnd + 1]
            if box == .space { checked = false } else if box == .x || box == .X { checked = true }
            if checked != nil { markerEnd = min(end, markerEnd + 4) }
        }
        let indentWidth = (slice.range.lowerBound..<start).reduce(0) { width, index in
            width + (text.units[index] == .tab ? 2 : 1)
        }
        let content = markerEnd..<end
        let block = Block(kind: .listItem, range: slice.range, contentRange: content,
                          syntax: [start..<markerEnd],
                          attributes: BlockAttributes(ordered: ordered, number: number, indent: indentWidth / 2, checked: checked),
                          inlines: context.inlines(in: content))
        return BlockMatch(block: block)
    }
}

/// Anything else: one paragraph line.
public struct ParagraphParser: BlockParser {
    public init() {}
    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        let content = context.text.firstNonBlank(in: slice.range)..<slice.range.upperBound
        return BlockMatch(block: Block(kind: .paragraph, range: slice.range, contentRange: content,
                                       inlines: context.inlines(in: content)))
    }
}
