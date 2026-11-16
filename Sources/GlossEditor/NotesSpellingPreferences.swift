import AppKit

/// The notes' Edit › Spelling and Grammar choices, kept across pages, windows and launches.
/// `NSTextView` keeps them per view and forgets them, and every page gets a fresh view. They live
/// in this Mac's defaults, like the window layout: how a keyboard on this Mac checks spelling,
/// nothing a library carries. The defaults are TextEdit's and Notes': check spelling while typing,
/// no grammar, and correct spelling automatically as the system setting says until changed here.
@MainActor
enum NotesSpellingPreferences {
    private static let checkSpelling = "notes.checkSpellingWhileTyping"
    private static let checkGrammar = "notes.checkGrammarWithSpelling"
    private static let correctSpelling = "notes.correctSpellingAutomatically"

    static func apply(to textView: NSTextView) {
        let defaults = UserDefaults.standard
        textView.isContinuousSpellCheckingEnabled = defaults.object(forKey: checkSpelling) as? Bool ?? true
        textView.isGrammarCheckingEnabled = defaults.object(forKey: checkGrammar) as? Bool ?? false
        textView.isAutomaticSpellingCorrectionEnabled = defaults.object(forKey: correctSpelling) as? Bool
            ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled
    }

    /// Remembers one choice the user just made; the others keep following their defaults.
    static func save(_ choice: Choice, from textView: NSTextView) {
        let defaults = UserDefaults.standard
        switch choice {
        case .checkSpelling: defaults.set(textView.isContinuousSpellCheckingEnabled, forKey: checkSpelling)
        case .checkGrammar: defaults.set(textView.isGrammarCheckingEnabled, forKey: checkGrammar)
        case .correctSpelling: defaults.set(textView.isAutomaticSpellingCorrectionEnabled, forKey: correctSpelling)
        }
    }

    enum Choice { case checkSpelling, checkGrammar, correctSpelling }
}
