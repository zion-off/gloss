import Foundation
import GlossCore
import GlossMarkdown
import GlossTerminal

/// Renders a notes page for the terminal: styled headings, quotes with a bar, bullets, task
/// boxes, code, and links whose `gloss://` destinations become readable hints.
struct TerminalMarkdown {
    let terminal: Terminal
    /// A short description of where a gloss link points ("chapter 3", "a page"), when known.
    let describe: (GlossLink) -> String?
    var width: Int { min(terminal.width, 100) }

    func render(_ body: String) -> String {
        let document = MarkdownParser.standard.parse(body)
        let text = document.text
        var lines: [String] = []
        var lastBlank = true
        func emit(_ newLines: [String]) {
            lines += newLines
            lastBlank = false
        }
        for block in document.blocks {
            switch block.kind {
            case .blank:
                if !lastBlank { lines.append(""); lastBlank = true }
            case .heading:
                if !lastBlank, !lines.isEmpty { lines.append("") }
                let level = block.attributes.level ?? 1
                let style: TerminalStyle = level == 1 ? .title : level == 2 ? .heading : .strong
                emit([terminal.paint(PlainText.strip(text[block.contentRange]), style)])
            case .paragraph:
                if let pageRow = subpageRow(block, text) { emit([pageRow]); continue }
                emit(TextWrap.wrap(inline(block, text), width: width))
            case .listItem:
                let indent = String(repeating: "  ", count: block.attributes.indent ?? 0)
                let marker: String
                var content = inline(block, text)
                if let checked = block.attributes.checked {
                    marker = checked ? terminal.paint("☑", .success) : terminal.paint("☐", .muted)
                    if checked { content = terminal.paint(PlainText.strip(text[block.contentRange]), TerminalStyle(color: .faint, strikethrough: true)) }
                } else if block.attributes.ordered == true {
                    marker = terminal.paint("\(block.attributes.number ?? 1).", .muted)
                } else {
                    marker = terminal.paint("•", TerminalStyle(color: .accent))
                }
                let wrapped = TextWrap.wrap(content, width: width, indent: indent + "   ")
                emit(wrapped.enumerated().map { index, line in
                    index == 0 ? indent + marker + " " + line.dropFirst(indent.count + 3) : line
                })
            case .quote:
                let bar = terminal.paint("│", TerminalStyle(color: .accent2))
                let inner = block.leaf
                emit(TextWrap.wrap(inline(inner, text), width: width - 2).map { bar + " " + terminal.paint($0, .muted) })
            case .codeBlock:
                var out: [String] = []
                if let language = block.attributes.language { out.append(terminal.paint(language, .faint)) }
                out += text[block.contentRange].split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  " + terminal.paint(String($0), .code) }
                emit(out)
            case .thematicBreak:
                emit([terminal.paint(String(repeating: "─", count: min(width, 40)), .faint)])
            default:
                emit([text[block.range]])
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A line that is only a page link renders as a row, like the app's subpage blocks.
    private func subpageRow(_ block: Block, _ text: MarkdownText) -> String? {
        guard block.inlines.count == 1, let link = block.inlines.first, link.kind == .link,
              let destination = link.destination, case .page = GlossLink(string: destination),
              text.isBlank(block.range.lowerBound..<link.range.lowerBound),
              text.isBlank(link.range.upperBound..<block.range.upperBound) else { return nil }
        return terminal.paint("›", TerminalStyle(color: .accent2)) + " " + terminal.paint(PlainText.strip(text[link.contentRange]), .strong)
    }

    private func inline(_ block: Block, _ text: MarkdownText) -> String {
        render(block.inlines, in: block.contentRange, text)
    }

    private func render(_ inlines: [Inline], in range: Range<Int>, _ text: MarkdownText) -> String {
        var out = ""
        var cursor = range.lowerBound
        for inline in inlines {
            out += text[cursor..<inline.range.lowerBound]
            let content = render(inline.children, in: inline.contentRange, text)
            switch inline.kind {
            case .strong: out += terminal.paint(PlainText.strip(text[inline.contentRange]), .strong)
            case .emphasis: out += terminal.paint(PlainText.strip(text[inline.contentRange]), TerminalStyle(italic: true))
            case .strikethrough: out += terminal.paint(PlainText.strip(text[inline.contentRange]), TerminalStyle(strikethrough: true))
            case .code: out += terminal.paint(text[inline.contentRange], .code)
            case .escape: out += text[inline.contentRange]
            case .autolink: out += terminal.paint(text[inline.contentRange], .link)
            case .link: out += link(inline, label: content, text)
            default: out += content
            }
            cursor = inline.range.upperBound
        }
        return out + text[cursor..<max(cursor, range.upperBound)]
    }

    private func link(_ inline: Inline, label: String, _ text: MarkdownText) -> String {
        let destination = inline.destination ?? ""
        let plainLabel = PlainText.strip(text[inline.contentRange])
        guard let glossLink = GlossLink(string: destination) else {
            let shown = terminal.paint(plainLabel, .link)
            return plainLabel == destination ? shown : shown + terminal.paint(" (\(destination))", .faint)
        }
        let hint = describe(glossLink)
        if case .passage = glossLink, plainLabel == QuoteLine.arrow {
            return terminal.paint("↗" + (hint.map { " " + $0 } ?? ""), TerminalStyle(color: .link))
        }
        return terminal.paint(plainLabel, .link) + (hint.map { terminal.paint(" ↗ " + $0, .faint) } ?? "")
    }
}
