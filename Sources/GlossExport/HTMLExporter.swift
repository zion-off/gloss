import Foundation
import GlossCore
import GlossMarkdown

/// Standalone HTML (used for "export as PDF" through the system print dialog): the markdown
/// export rendered with a small print stylesheet.
public struct HTMLExporter: Exporter {
    public init() {}
    public var format: ExportFormat { .html }
    public var fileExtension: String { "html" }
    public var mimeType: String { "text/html" }

    public func export(_ bundle: ExportBundle) throws -> Data {
        let markdown = MarkdownExporter().compose(bundle)
        let body = HTMLRenderer().render(markdown)
        let html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <title>\(HTMLRenderer.escape(bundle.title))</title>
        <style>\(Self.stylesheet)</style>
        </head><body>
        \(body)
        </body></html>

        """
        return Data(html.utf8)
    }

    static let stylesheet = """
    body { font: 12pt/1.5 -apple-system, "New York", Georgia, serif; max-width: 40em; margin: 2em auto; color: #1d1d1f; }
    h1, h2, h3, h4, h5, h6 { font-family: -apple-system, "Helvetica Neue", sans-serif; line-height: 1.2; margin: 1.6em 0 .5em; }
    blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid #d2d2d7; color: #424245; }
    code { font: .9em ui-monospace, Menlo, monospace; background: #f5f5f7; padding: .1em .3em; border-radius: 3px; }
    pre code { display: block; padding: .8em; overflow-x: auto; }
    ul.tasks { list-style: none; padding-left: 1.2em; }
    .footnotes { font-size: .9em; border-top: 1px solid #d2d2d7; margin-top: 2em; padding-top: .5em; }
    a { color: inherit; }
    @media print { body { margin: 0; } a { text-decoration: none; } }
    """
}

/// Markdown → HTML using the gloss parser plus two registered extensions for footnotes
/// (`[^1]` references and `[^1]: …` definitions) — an example of adding elements by
/// registration rather than by editing the parser.
public struct HTMLRenderer: Sendable {
    let parser: MarkdownParser

    public init() {
        var parser = MarkdownParser.standard
        parser.blockParsers.insert(FootnoteDefinitionParser(), at: 1)
        parser.inlineParsers.insert(FootnoteReferenceParser(), at: 1)
        self.parser = parser
    }

    public func render(_ markdown: String) -> String {
        let document = parser.parse(markdown)
        var html: [String] = []
        var paragraph: [String] = []
        var quote: [Block] = []
        var listStack: [(tag: String, indent: Int)] = []
        var footnotes: [String] = []
        var slugger = Slugger()

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>" + paragraph.joined(separator: "<br>\n") + "</p>") }
            paragraph = []
        }
        func closeLists(to depth: Int) {
            while listStack.count > depth { html.append("</li></\(listStack.removeLast().tag)>") }
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            let inner = quote.map { inline($0.children.first ?? $0, document.text) }.filter { !$0.isEmpty }
            html.append("<blockquote><p>" + inner.joined(separator: "<br>\n") + "</p></blockquote>")
            quote = []
        }

        for block in document.blocks {
            if block.kind != .paragraph { flushParagraph() }
            if block.kind != .quote { flushQuote() }
            if block.kind != .listItem { closeLists(to: 0) }
            switch block.kind {
            case .paragraph:
                paragraph.append(inline(block, document.text))
            case .heading:
                let level = block.attributes.level ?? 1
                let text = inline(block, document.text)
                let id = slugger.slug(PlainText.strip(document.text[block.contentRange]))
                html.append("<h\(level) id=\"\(id)\">\(text)</h\(level)>")
            case .quote:
                quote.append(block)
            case .listItem:
                let indent = block.attributes.indent ?? 0
                let tag = block.attributes.ordered == true ? "ol" : "ul"
                let open = "<\(tag)\(block.attributes.checked != nil ? " class=\"tasks\"" : "")>"
                while let top = listStack.last, top.indent > indent { closeLists(to: listStack.count - 1) }
                if let top = listStack.last, top.indent == indent {
                    if top.tag == tag {
                        html.append("</li>")
                    } else {
                        closeLists(to: listStack.count - 1)
                        listStack.append((tag, indent))
                        html.append(open)
                    }
                } else {
                    listStack.append((tag, indent))
                    html.append(open)
                }
                var item = "<li>"
                if let checked = block.attributes.checked {
                    item += "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                }
                html.append(item + inline(block, document.text))
            case .codeBlock:
                let language = block.attributes.language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
                html.append("<pre><code\(language)>\(Self.escape(document.text[block.contentRange]))</code></pre>")
            case .thematicBreak:
                html.append("<hr>")
            case FootnoteDefinitionParser.kind:
                let id = block.attributes.extra["id"] ?? ""
                footnotes.append("<li id=\"fn-\(Self.escape(id))\">\(inline(block, document.text))</li>")
            default:
                break
            }
        }
        flushParagraph()
        flushQuote()
        closeLists(to: 0)
        if !footnotes.isEmpty { html.append("<ol class=\"footnotes\">\n" + footnotes.joined(separator: "\n") + "\n</ol>") }
        return html.joined(separator: "\n")
    }

    private func inline(_ block: Block, _ text: MarkdownText) -> String {
        render(block.inlines, in: block.contentRange, text)
    }

    private func render(_ inlines: [Inline], in range: Range<Int>, _ text: MarkdownText) -> String {
        var out = ""
        var cursor = range.lowerBound
        for inline in inlines {
            out += Self.escape(text[cursor..<inline.range.lowerBound])
            let content = render(inline.children, in: inline.contentRange, text)
            switch inline.kind {
            case .strong: out += "<strong>\(content)</strong>"
            case .emphasis: out += "<em>\(content)</em>"
            case .strikethrough: out += "<del>\(content)</del>"
            case .code: out += "<code>\(Self.escape(text[inline.contentRange]))</code>"
            case .escape: out += Self.escape(text[inline.contentRange])
            case .link, .autolink:
                out += "<a href=\"\(Self.escape(inline.destination ?? ""))\">\(inline.kind == .autolink ? Self.escape(text[inline.contentRange]) : content)</a>"
            case FootnoteReferenceParser.kind:
                let id = Self.escape(text[inline.contentRange])
                out += "<sup><a href=\"#fn-\(id)\">\(id)</a></sup>"
            default: out += content
            }
            cursor = inline.range.upperBound
        }
        return out + Self.escape(text[cursor..<max(cursor, range.upperBound)])
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(char)
            }
        }
        return out
    }
}

/// `[^label]` footnote references.
struct FootnoteReferenceParser: InlineParser {
    static let kind = InlineKind("footnoteReference")
    var triggers: Set<UInt16> { [0x5B] }

    func parse(at index: Int, limit: Int, in context: InlineParsingContext) -> Inline? {
        let units = context.text.units
        guard index + 3 < limit, units[index + 1] == 0x5E else { return nil }
        var end = index + 2
        while end < limit, units[end] != 0x5D, units[end] != 0x20 { end += 1 }
        guard end < limit, units[end] == 0x5D, end > index + 2 else { return nil }
        // Not a definition (`[^1]:` at line start is handled by the block parser).
        return Inline(kind: Self.kind, range: index..<end + 1, contentRange: index + 2..<end, syntax: [index..<index + 2, end..<end + 1])
    }
}

/// `[^label]: text` footnote definitions.
struct FootnoteDefinitionParser: BlockParser {
    static let kind = BlockKind("footnoteDefinition")

    func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        let text = context.text
        let start = slice.range.lowerBound
        guard text.unit(at: start) == 0x5B, text.unit(at: start + 1) == 0x5E else { return nil }
        var end = start + 2
        while end < slice.range.upperBound, text.units[end] != 0x5D { end += 1 }
        guard end + 1 < slice.range.upperBound, text.units[end + 1] == 0x3A else { return nil }
        let content = text.firstNonBlank(in: end + 2..<slice.range.upperBound)..<slice.range.upperBound
        var attributes = BlockAttributes()
        attributes.extra["id"] = text[start + 2..<end]
        return BlockMatch(block: Block(kind: Self.kind, range: slice.range, contentRange: content, syntax: [start..<end + 2],
                                       attributes: attributes, inlines: context.inlines(in: content)))
    }
}
