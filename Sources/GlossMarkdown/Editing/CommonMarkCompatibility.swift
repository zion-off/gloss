/// Makes gloss's line-based structure explicit for other markdown readers.
///
/// gloss treats every line as its own block (docs/DECISIONS.md D-051). CommonMark folds a plain
/// line that directly follows a quote or a list item into it ("lazy continuation"), so a note
/// that reads as two blocks in gloss would read as one elsewhere. Exporters insert a blank line
/// in exactly those places; nothing else changes.
public enum CommonMarkCompatibility {
    public static func separatingLazyContinuations(_ markdown: String, parser: MarkdownParser = .standard) -> String {
        let document = parser.parse(markdown)
        let edits = zip(document.blocks, document.blocks.dropFirst()).compactMap { previous, next -> TextEdit? in
            guard next.kind == .paragraph, previous.kind == .quote || previous.kind == .listItem else { return nil }
            return .insert("\n", at: next.range.lowerBound)
        }
        return edits.isEmpty ? markdown : EditResult(edits: edits, selection: 0..<0).apply(to: markdown)
    }
}
