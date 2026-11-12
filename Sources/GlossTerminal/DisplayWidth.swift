/// Terminal column widths of text (an approximation of `wcwidth`): combining marks and
/// zero-width characters take 0 columns, East Asian wide characters and emoji take 2.
public enum DisplayWidth {
    public static func of(_ text: some StringProtocol) -> Int {
        var width = 0
        for character in stripANSI(String(text)) {
            width += of(character)
        }
        return width
    }

    public static func of(_ character: Character) -> Int {
        guard let first = character.unicodeScalars.first else { return 0 }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        if character.unicodeScalars.count > 1, character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        return scalarWidth(first)
    }

    static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v == 0 || v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFEFF { return 0 }
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD,
        ]
        return wide.contains { $0.contains(v) } ? 2 : 1
    }

    /// Removes SGR escape sequences.
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1B}", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "[" {
                var end = text.index(index, offsetBy: 2)
                while end < text.endIndex, !(text[end].isLetter) { end = text.index(after: end) }
                index = end < text.endIndex ? text.index(after: end) : end
                continue
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    /// Cuts `text` to at most `width` columns, ending in "…" when shortened.
    public static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        guard of(text) > width else { return text }
        var out = ""
        var used = 0
        for character in stripANSI(text) {
            let w = of(character)
            if used + w > width - 1 { break }
            out.append(character)
            used += w
        }
        return out + "…"
    }

    /// Pads with spaces on the right to exactly `width` columns (never truncates).
    public static func pad(_ text: String, to width: Int) -> String {
        let current = of(text)
        return current >= width ? text : text + String(repeating: " ", count: width - current)
    }
}
