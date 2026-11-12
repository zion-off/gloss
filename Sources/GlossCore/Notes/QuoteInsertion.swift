/// Where "add to notes" puts a quote line: at the caret (on its own line), or at the end of
/// the page when the editor is not focused.
public enum QuoteInsertion {
    public struct Result: Hashable, Sendable {
        public var body: String
        /// UTF-16 range of the inserted line in the new body.
        public var insertedRange: Range<Int>
        /// Where the caret goes afterwards (end of the inserted line).
        public var caret: Int
    }

    public static func insert(_ line: String, into body: String, at offset: Int?) -> Result {
        let units = Array(body.utf16)
        let lineUnits = Array(line.utf16)
        let newline: UInt16 = 0x0A
        guard let requested = offset else {
            // End of page: start a fresh line, separated from a non-empty last line.
            var prefix: [UInt16] = []
            if let last = units.last {
                prefix = last == newline ? [] : [newline]
            }
            let start = units.count + prefix.count
            let newUnits = units + prefix + lineUnits + [newline]
            return Result(body: String(decoding: newUnits, as: UTF16.self), insertedRange: start..<start + lineUnits.count,
                          caret: start + lineUnits.count + 1)
        }
        let at = min(max(0, requested), units.count)
        let atLineStart = at == 0 || units[at - 1] == newline
        let atLineEnd = at == units.count || units[at] == newline
        let before: [UInt16] = atLineStart ? [] : [newline]
        let after: [UInt16] = atLineEnd && at < units.count ? [] : [newline]
        let start = at + before.count
        let newUnits = Array(units[..<at]) + before + lineUnits + after + Array(units[at...])
        return Result(body: String(decoding: newUnits, as: UTF16.self), insertedRange: start..<start + lineUnits.count,
                      caret: start + lineUnits.count)
    }
}
