/// Ordered-list numbers after items change nesting level. Numbers are literal text, so an item
/// moved deeper must start its sublist at 1 (or continue the sibling already there) instead of
/// keeping its old place in the parent's count, and the items after it close the gap.
///
/// Only lists with a moved item change, and only from the first moved line on, so a list's
/// chosen start (`5.`) and lists elsewhere stay as written. An item that started its run before
/// the move and still does keeps its number; one that newly starts a run gets 1.
enum ListNumbering {
    /// The renumbering edits for `document` once the lines in `levels` (line index to new level)
    /// have moved there. They touch only the digits of ordered markers.
    static func edits(in document: MarkdownDocument, levels: [Int: Int]) -> [TextEdit] {
        guard !levels.isEmpty else { return [] }
        let text = document.text
        var edits: [TextEdit] = []
        // Per level, whether the previous item there was ordered (before the move), and the
        // number it has after the move.
        var oldRuns: Set<Int> = []
        var newRuns: [Int: Int] = [:]
        var quotePrefix: String?
        var active = false

        for index in text.lines.indices {
            let line = LineStructure(document: document, lineIndex: index)
            guard line.leaf.kind == .listItem, !line.isCode else {
                oldRuns = []; newRuns = [:]; quotePrefix = nil; active = false
                continue
            }
            let prefix = text[line.line.lowerBound..<line.quoteEnd].filter { $0 != " " && $0 != "\t" }
            if prefix != quotePrefix {
                oldRuns = []; newRuns = [:]; active = false
                quotePrefix = prefix
            }
            let oldLevel = line.leaf.attributes.indent ?? 0
            let newLevel = levels[index] ?? oldLevel
            if levels[index] != nil { active = true }
            let ordered = line.leaf.attributes.ordered == true

            oldRuns = oldRuns.filter { $0 <= oldLevel }
            let startedRun = !oldRuns.contains(oldLevel)
            if ordered { oldRuns.insert(oldLevel) }

            newRuns = newRuns.filter { $0.key <= newLevel }
            guard ordered, let written = line.leaf.attributes.number else {
                newRuns[newLevel] = nil
                continue
            }
            let number: Int
            if !active {
                number = written
            } else if let previous = newRuns[newLevel] {
                number = previous + 1
            } else {
                number = startedRun ? written : 1
            }
            newRuns[newLevel] = number
            if number != written, let digits = digitRange(of: line, in: text) {
                edits.append(TextEdit(range: digits, replacement: String(number)))
            }
        }
        return edits
    }

    /// The digits of an ordered item's marker (`12` in `12. `).
    private static func digitRange(of line: LineStructure, in text: MarkdownText) -> Range<Int>? {
        let start = line.marker.lowerBound
        var end = start
        while end < line.marker.upperBound, text.units[end].isDigit { end += 1 }
        return end > start ? start..<end : nil
    }

    /// The width of a line's indentation, a tab counting as one level (as the parser reads it).
    static func indentWidth(of line: LineStructure, in text: MarkdownText) -> Int {
        line.indentRange.reduce(0) { $0 + (text.units[$1] == .tab ? 2 : 1) }
    }
}
