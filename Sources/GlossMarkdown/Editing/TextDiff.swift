/// The smallest single replacement turning one string into another (common UTF-16 prefix and
/// suffix kept). Lets multi-step commands apply as one undoable change.
public enum TextDiff {
    public static func minimalEdit(from old: String, to new: String) -> TextEdit? {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Never split a surrogate pair.
        if prefix > 0, prefix < a.count, UTF16.isTrailSurrogate(a[prefix]) { prefix -= 1 }
        if suffix > 0, a.count - suffix < a.count, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        guard prefix + suffix < a.count || prefix + suffix < b.count else { return nil }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return TextEdit(range: prefix..<(a.count - suffix), replacement: replacement)
    }
}
