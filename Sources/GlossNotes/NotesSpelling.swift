import GlossMarkdown

/// What the spelling and grammar checker and autocorrect leave alone in a notes page: code, link
/// destinations, markdown syntax (shown or not) and text drawn as something else (a table's grid,
/// a subpage row). Underlines there would sit under a grid or a row, or under characters with no
/// width; a correction there would quietly rewrite a URL or code.
public struct NotesSpelling: Sendable {
    public var skippedRoles: Set<StyleRole>

    public init(skippedRoles: Set<StyleRole>) {
        self.skippedRoles = skippedRoles
    }

    public static let standard = NotesSpelling(skippedRoles: [
        .code, .codeBlock, .linkDestination, .linkDestinationRevealed, .syntax, .syntaxRevealed,
        NotesRole.tableGrid, NotesRole.subpageBlock,
    ])

    /// The ranges the checker skips, sorted and merged.
    public func skippedRanges(in spans: [StyleSpan]) -> [Range<Int>] {
        let ranges = spans.filter { skippedRoles.contains($0.role) && !$0.range.isEmpty }.map(\.range)
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Whether a checker result over `range` touches a skipped range (`skipped` as returned by
    /// `skippedRanges`): a result only partly in one is dropped whole.
    public static func isSkipped(_ range: Range<Int>, in skipped: [Range<Int>]) -> Bool {
        var low = 0, high = skipped.count
        while low < high {
            let mid = (low + high) / 2
            if skipped[mid].upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        guard low < skipped.count else { return false }
        let candidate = skipped[low]
        return range.isEmpty ? candidate.contains(range.lowerBound) : candidate.lowerBound < range.upperBound
    }
}
