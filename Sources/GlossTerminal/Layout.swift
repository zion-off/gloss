/// A borderless table with a dim header, the way Charm's tools print lists.
public struct TerminalTable: Sendable {
    public struct Column: Sendable {
        public var title: String
        /// Columns marked flexible shrink (with "…") when the table is too wide.
        public var flexible: Bool
        public var style: TerminalStyle
        public var alignRight: Bool

        public init(_ title: String, flexible: Bool = false, style: TerminalStyle = .plain, alignRight: Bool = false) {
            self.title = title
            self.flexible = flexible
            self.style = style
            self.alignRight = alignRight
        }
    }

    public var columns: [Column]
    public var rows: [[String]]
    public var gap = 2

    public init(columns: [Column], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    public func render(on terminal: Terminal) -> String {
        guard !columns.isEmpty else { return "" }
        var widths = columns.indices.map { index in
            ([DisplayWidth.of(columns[index].title)] + rows.map { DisplayWidth.of($0.indices.contains(index) ? $0[index] : "") }).max() ?? 0
        }
        let total = widths.reduce(0, +) + gap * (columns.count - 1)
        if total > terminal.width {
            let flexible = columns.indices.filter { columns[$0].flexible }
            var excess = total - terminal.width
            for index in flexible.sorted(by: { widths[$0] > widths[$1] }) where excess > 0 {
                let floor = max(8, DisplayWidth.of(columns[index].title))
                let cut = min(excess, max(0, widths[index] - floor))
                widths[index] -= cut
                excess -= cut
            }
        }
        func line(_ cells: [String], styles: [TerminalStyle]) -> String {
            columns.indices.map { index -> String in
                let raw = cells.indices.contains(index) ? cells[index] : ""
                let cut = DisplayWidth.truncate(raw, to: widths[index])
                let padding = String(repeating: " ", count: max(0, widths[index] - DisplayWidth.of(cut)))
                let painted = terminal.paint(cut, styles[index])
                let isLast = index == columns.count - 1
                if columns[index].alignRight { return padding + painted }
                return isLast ? painted : painted + padding
            }.joined(separator: String(repeating: " ", count: gap))
        }
        var lines = [line(columns.map(\.title), styles: columns.map { _ in .muted })]
        lines += rows.map { line($0, styles: columns.map(\.style)) }
        return lines.map { trimTrailingSpaces($0) }.joined(separator: "\n")
    }

    private func trimTrailingSpaces(_ text: String) -> String {
        var text = text
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}

/// A tree drawn with box characters.
public struct TerminalTree: Sendable {
    public struct Node: Sendable {
        public var label: String
        public var detail: String?
        public var children: [Node]

        public init(label: String, detail: String? = nil, children: [Node] = []) {
            self.label = label
            self.detail = detail
            self.children = children
        }
    }

    public var root: Node

    public init(root: Node) { self.root = root }

    public func render(on terminal: Terminal, labelStyle: TerminalStyle = .plain, rootStyle: TerminalStyle = .title) -> String {
        var lines: [String] = [row(root, terminal: terminal, style: rootStyle)]
        func walk(_ node: Node, prefix: String) {
            for (index, child) in node.children.enumerated() {
                let last = index == node.children.count - 1
                lines.append(terminal.paint(prefix + (last ? "└─ " : "├─ "), .faint) + row(child, terminal: terminal, style: labelStyle))
                walk(child, prefix: prefix + (last ? "   " : "│  "))
            }
        }
        walk(root, prefix: "")
        return lines.joined(separator: "\n")
    }

    private func row(_ node: Node, terminal: Terminal, style: TerminalStyle) -> String {
        let label = terminal.paint(node.label, style)
        guard let detail = node.detail, !detail.isEmpty else { return label }
        return label + "  " + terminal.paint(detail, .faint)
    }
}

/// Words wrapped to a width, keeping words whole where possible.
public enum TextWrap {
    public static func wrap(_ text: String, width: Int, indent: String = "") -> [String] {
        let available = max(10, width - DisplayWidth.of(indent))
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if DisplayWidth.of(candidate) > available, !current.isEmpty {
                lines.append(indent + current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(indent + current) }
        return lines
    }
}
