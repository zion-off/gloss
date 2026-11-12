/// A semantic style. The editor maps roles to fonts and colours through its theme, so this
/// module never touches a UI framework. Open: new elements bring new roles.
public struct StyleRole: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func heading(_ level: Int) -> StyleRole { StyleRole("heading\(level)") }
    public static let strong = StyleRole("strong")
    public static let emphasis = StyleRole("emphasis")
    public static let strikethrough = StyleRole("strikethrough")
    public static let code = StyleRole("code")
    public static let codeBlock = StyleRole("codeBlock")
    public static let quote = StyleRole("quote")
    public static let listMarker = StyleRole("listMarker")
    public static let taskBox = StyleRole("taskBox")
    public static let taskBoxChecked = StyleRole("taskBoxChecked")
    public static let taskDone = StyleRole("taskDone")
    public static let link = StyleRole("link")
    public static let linkDestination = StyleRole("linkDestination")
    public static let thematicBreak = StyleRole("thematicBreak")
    /// Markdown syntax characters, drawn dimmed.
    public static let syntax = StyleRole("syntax")
    /// Syntax characters of the element under the cursor, drawn at full strength.
    public static let syntaxRevealed = StyleRole("syntaxRevealed")

    /// Whether the editor draws this role dimmed (the cursor reveals it).
    public var isSyntax: Bool { self == .syntax || self == .syntaxRevealed }
}

/// A styled range. Syntax spans remember their element's range so the editor can reveal
/// the syntax of whatever the cursor is in.
public struct StyleSpan: Hashable, Sendable {
    public var range: Range<Int>
    public var role: StyleRole
    public var element: Range<Int>?

    public init(range: Range<Int>, role: StyleRole, element: Range<Int>? = nil) {
        self.range = range
        self.role = role
        self.element = element
    }
}

/// Turns one kind of block or inline into style spans. Register rules in a `StyleRuleSet`;
/// unknown kinds simply stay unstyled.
public protocol StylingRule: Sendable {
    func spans(for block: Block, in text: MarkdownText) -> [StyleSpan]
    func spans(for inline: Inline, in text: MarkdownText) -> [StyleSpan]
}

extension StylingRule {
    public func spans(for block: Block, in text: MarkdownText) -> [StyleSpan] { [] }
    public func spans(for inline: Inline, in text: MarkdownText) -> [StyleSpan] { [] }
}

/// Rules keyed by block and inline kind, plus rules that see every inline (used by the notes
/// layer to classify `gloss://` links without editing the link rule).
public struct StyleRuleSet: Sendable {
    public var blockRules: [BlockKind: any StylingRule]
    public var inlineRules: [InlineKind: any StylingRule]
    public var decorators: [any StylingRule]

    public init(blockRules: [BlockKind: any StylingRule] = [:], inlineRules: [InlineKind: any StylingRule] = [:],
                decorators: [any StylingRule] = []) {
        self.blockRules = blockRules
        self.inlineRules = inlineRules
        self.decorators = decorators
    }

    public static let standard = StyleRuleSet(
        blockRules: [
            .heading: HeadingRule(), .listItem: ListItemRule(), .quote: QuoteRule(),
            .codeBlock: CodeBlockRule(), .thematicBreak: ThematicBreakRule(),
        ],
        inlineRules: [
            .strong: WrapRule(role: .strong), .emphasis: WrapRule(role: .emphasis),
            .strikethrough: WrapRule(role: .strikethrough), .code: WrapRule(role: .code),
            .link: LinkRule(), .autolink: LinkRule(), .escape: WrapRule(role: nil),
        ]
    )

    /// All spans for a document, in document order (outer spans before inner ones).
    public func spans(for document: MarkdownDocument) -> [StyleSpan] {
        var result: [StyleSpan] = []
        for block in document.blocks { collect(block, document.text, into: &result) }
        return result
    }

    private func collect(_ block: Block, _ text: MarkdownText, into result: inout [StyleSpan]) {
        if let rule = blockRules[block.kind] { result += rule.spans(for: block, in: text) }
        for decorator in decorators { result += decorator.spans(for: block, in: text) }
        for child in block.children { collect(child, text, into: &result) }
        for inline in block.inlines { collect(inline, text, into: &result) }
    }

    private func collect(_ inline: Inline, _ text: MarkdownText, into result: inout [StyleSpan]) {
        if let rule = inlineRules[inline.kind] { result += rule.spans(for: inline, in: text) }
        for decorator in decorators { result += decorator.spans(for: inline, in: text) }
        for child in inline.children { collect(child, text, into: &result) }
    }
}

/// Picks which syntax the cursor reveals: every element whose range touches the selection.
public enum SyntaxReveal {
    public static func apply(_ spans: [StyleSpan], selection: Range<Int>) -> [StyleSpan] {
        spans.map { span in
            guard span.role == .syntax, let element = span.element,
                  selection.lowerBound <= element.upperBound, selection.upperBound >= element.lowerBound else { return span }
            var revealed = span
            revealed.role = .syntaxRevealed
            return revealed
        }
    }

    /// Element ranges whose syntax is revealed for `selection` (lets the editor restyle only
    /// what changed when the cursor moves).
    public static func revealedElements(in spans: [StyleSpan], selection: Range<Int>) -> Set<Range<Int>> {
        Set(apply(spans, selection: selection).filter { $0.role == .syntaxRevealed }.compactMap(\.element))
    }
}

// MARK: Standard rules

func syntaxSpans(_ ranges: [Range<Int>], element: Range<Int>) -> [StyleSpan] {
    ranges.filter { !$0.isEmpty }.map { StyleSpan(range: $0, role: .syntax, element: element) }
}

public struct HeadingRule: StylingRule {
    public init() {}
    public func spans(for block: Block, in text: MarkdownText) -> [StyleSpan] {
        [StyleSpan(range: block.range, role: .heading(block.attributes.level ?? 1))] + syntaxSpans(block.syntax, element: block.range)
    }
}

public struct ListItemRule: StylingRule {
    public init() {}
    public func spans(for block: Block, in text: MarkdownText) -> [StyleSpan] {
        guard let marker = block.syntax.first else { return [] }
        guard let checked = block.attributes.checked else {
            return [StyleSpan(range: marker, role: .listMarker)]
        }
        // "- [ ] ": the bullet dims like syntax, the box is a control.
        let boxStart = marker.upperBound - (marker.upperBound - marker.lowerBound >= 4 ? 4 : 3)
        let box = boxStart..<min(boxStart + 3, marker.upperBound)
        var spans = syntaxSpans([marker.lowerBound..<boxStart], element: block.range)
        spans.append(StyleSpan(range: box, role: checked ? .taskBoxChecked : .taskBox))
        if checked, !block.contentRange.isEmpty { spans.append(StyleSpan(range: block.contentRange, role: .taskDone)) }
        return spans
    }
}

public struct QuoteRule: StylingRule {
    public init() {}
    public func spans(for block: Block, in text: MarkdownText) -> [StyleSpan] {
        [StyleSpan(range: block.range, role: .quote)] + syntaxSpans(block.syntax, element: block.range)
    }
}

public struct CodeBlockRule: StylingRule {
    public init() {}
    public func spans(for block: Block, in text: MarkdownText) -> [StyleSpan] {
        [StyleSpan(range: block.range, role: .codeBlock)] + syntaxSpans(block.syntax, element: block.range)
    }
}

public struct ThematicBreakRule: StylingRule {
    public init() {}
    public func spans(for block: Block, in text: MarkdownText) -> [StyleSpan] {
        [StyleSpan(range: block.range, role: .thematicBreak)] + syntaxSpans(block.syntax, element: block.range)
    }
}

/// Styles the content with `role` (if any) and dims the syntax.
public struct WrapRule: StylingRule {
    public let role: StyleRole?
    public init(role: StyleRole?) { self.role = role }
    public func spans(for inline: Inline, in text: MarkdownText) -> [StyleSpan] {
        (role.map { [StyleSpan(range: inline.range, role: $0)] } ?? []) + syntaxSpans(inline.syntax, element: inline.range)
    }
}

public struct LinkRule: StylingRule {
    public init() {}
    public func spans(for inline: Inline, in text: MarkdownText) -> [StyleSpan] {
        var spans = [StyleSpan(range: inline.contentRange, role: .link)]
        spans += syntaxSpans(inline.syntax, element: inline.range)
        if let destination = inline.destinationRange, inline.kind == .link {
            spans.append(StyleSpan(range: destination, role: .linkDestination, element: inline.range))
        }
        return spans
    }
}
