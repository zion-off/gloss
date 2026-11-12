/// A replacement of a UTF-16 range of the original text.
public struct TextEdit: Hashable, Sendable {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public static func insert(_ text: String, at offset: Int) -> TextEdit { TextEdit(range: offset..<offset, replacement: text) }
    public static func delete(_ range: Range<Int>) -> TextEdit { TextEdit(range: range, replacement: "") }

    var delta: Int { replacement.utf16.count - range.count }
}

/// The outcome of an editing command: edits against the original text (non-overlapping) and
/// the selection to show afterwards, in the resulting text's coordinates.
public struct EditResult: Hashable, Sendable {
    public var edits: [TextEdit]
    public var selection: Range<Int>

    public init(edits: [TextEdit], selection: Range<Int>) {
        self.edits = edits.sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        self.selection = selection
    }

    /// Builds a result whose selection is given in *original* coordinates and mapped through
    /// the edits. `lowerAfterInsertions`/`upperAfterInsertions` decide which side of an
    /// insertion at exactly that offset the bound lands on.
    public init(edits: [TextEdit], originalSelection: Range<Int>, lowerAfterInsertions: Bool = true, upperAfterInsertions: Bool = false) {
        let sorted = edits.sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        let lower = EditResult.map(originalSelection.lowerBound, through: sorted, afterInsertions: lowerAfterInsertions)
        let upper = EditResult.map(originalSelection.upperBound, through: sorted, afterInsertions: upperAfterInsertions)
        self.init(edits: sorted, selection: lower..<max(lower, upper))
    }

    /// Maps an original offset into the edited text.
    public static func map(_ offset: Int, through edits: [TextEdit], afterInsertions: Bool) -> Int {
        var shift = 0
        for edit in edits {
            if edit.range.isEmpty, edit.range.lowerBound == offset {
                if afterInsertions { shift += edit.delta }
                continue
            }
            if edit.range.upperBound <= offset {
                shift += edit.delta
            } else if edit.range.lowerBound < offset {
                // Inside a replaced range: clamp to the replacement's edge.
                return edit.range.lowerBound + shift + (afterInsertions ? edit.replacement.utf16.count : 0)
            }
        }
        return offset + shift
    }

    /// Applies the edits to `string` (the editor uses `coalesced` instead, for one undo step).
    public func apply(to string: String) -> String {
        var units = Array(string.utf16)
        for edit in edits.reversed() {
            units.replaceSubrange(edit.range, with: Array(edit.replacement.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// One replacement covering every edit, for applying as a single change.
    public func coalesced(in string: String) -> TextEdit? {
        guard let first = edits.first, let last = edits.last else { return nil }
        let units = Array(string.utf16)
        let span = first.range.lowerBound..<last.range.upperBound
        var middle = Array(units[span])
        for edit in edits.reversed() {
            let local = (edit.range.lowerBound - span.lowerBound)..<(edit.range.upperBound - span.lowerBound)
            middle.replaceSubrange(local, with: Array(edit.replacement.utf16))
        }
        return TextEdit(range: span, replacement: String(decoding: middle, as: UTF16.self))
    }
}

/// A command the format bar, menus, shortcuts or slash menu can run on the notes text.
public protocol MarkdownEditCommand: Sendable {
    /// Returns nil when the command does not apply to this selection.
    func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult?
    /// Whether the selection is already formatted this way (format bar button state).
    func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool
}
