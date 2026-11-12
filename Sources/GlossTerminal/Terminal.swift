import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A colour from the 256-colour palette, or one of the basic 16.
public struct TerminalColor: Hashable, Sendable {
    let code: String

    public static func ansi256(_ index: UInt8) -> TerminalColor { TerminalColor(code: "38;5;\(index)") }

    // gloss's palette: a soft pink accent, like Charm's tools, with calm neutrals.
    public static let accent = ansi256(212)
    public static let accent2 = ansi256(141)
    public static let muted = ansi256(245)
    public static let faint = ansi256(240)
    public static let success = ansi256(114)
    public static let warning = ansi256(221)
    public static let danger = ansi256(203)
    public static let link = ansi256(117)
}

/// How a run of text looks.
public struct TerminalStyle: Hashable, Sendable {
    public var color: TerminalColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var strikethrough = false

    public init(color: TerminalColor? = nil, bold: Bool = false, dim: Bool = false, italic: Bool = false,
                underline: Bool = false, strikethrough: Bool = false) {
        self.color = color
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
    }

    public static let plain = TerminalStyle()
    public static let title = TerminalStyle(color: .accent, bold: true)
    public static let heading = TerminalStyle(color: .accent2, bold: true)
    public static let muted = TerminalStyle(color: .muted)
    public static let faint = TerminalStyle(color: .faint)
    public static let strong = TerminalStyle(bold: true)
    public static let success = TerminalStyle(color: .success)
    public static let warning = TerminalStyle(color: .warning)
    public static let danger = TerminalStyle(color: .danger, bold: true)
    public static let link = TerminalStyle(color: .link, underline: true)
    public static let code = TerminalStyle(color: .warning)

    var sgr: String {
        var codes: [String] = []
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if italic { codes.append("3") }
        if underline { codes.append("4") }
        if strikethrough { codes.append("9") }
        if let color { codes.append(color.code) }
        return codes.joined(separator: ";")
    }
}

/// What the terminal can do. Colours follow the `NO_COLOR` / `CLICOLOR_FORCE` conventions
/// and switch off when output is piped.
public struct Terminal: Sendable {
    public var colorEnabled: Bool
    public var isTTY: Bool
    /// Columns available for layout.
    public var width: Int

    public init(colorEnabled: Bool, isTTY: Bool, width: Int) {
        self.colorEnabled = colorEnabled
        self.isTTY = isTTY
        self.width = max(20, width)
    }

    /// A terminal for plain, uncoloured output (tests, pipes).
    public static let plain = Terminal(colorEnabled: false, isTTY: false, width: 80)

    /// Detects the capabilities of the process's stdout.
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> Terminal {
        let tty = isatty(STDOUT_FILENO) == 1
        return Terminal(colorEnabled: colorPolicy(isTTY: tty, environment: environment), isTTY: tty,
                        width: detectWidth(environment: environment))
    }

    /// `NO_COLOR` (any value) wins, then `CLICOLOR_FORCE`, then `TERM=dumb`, then the TTY check.
    public static func colorPolicy(isTTY: Bool, environment: [String: String]) -> Bool {
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return false }
        if let force = environment["CLICOLOR_FORCE"], !force.isEmpty, force != "0" { return true }
        if environment["TERM"] == "dumb" { return false }
        return isTTY
    }

    static func detectWidth(environment: [String: String]) -> Int {
        if let columns = environment["COLUMNS"].flatMap(Int.init), columns > 0 { return columns }
        var size = winsize()
        #if canImport(Glibc)
        let request = UInt(TIOCGWINSZ)
        #else
        let request = TIOCGWINSZ
        #endif
        if ioctl(STDOUT_FILENO, request, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return 80
    }

    /// Wraps `text` in the style's escape codes (or returns it as is when colours are off).
    public func paint(_ text: String, _ style: TerminalStyle) -> String {
        guard colorEnabled, !text.isEmpty else { return text }
        let sgr = style.sgr
        guard !sgr.isEmpty else { return text }
        return "\u{1B}[\(sgr)m\(text)\u{1B}[0m"
    }
}
