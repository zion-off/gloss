import Foundation
import GlossCore
import GlossTerminal

/// Output helpers with gloss's look: green checks, soft pink titles, faint details.
struct Printer: Sendable {
    let output: OutputSink
    let terminal: Terminal
    let stderrTerminal: Terminal
    /// In json mode stdout carries nothing but the json document: no status lines.
    let json: Bool

    init(environment: CLIEnvironment, colorEnabled: Bool, json: Bool = false) {
        output = environment.output
        var terminal = environment.terminal
        terminal.colorEnabled = terminal.colorEnabled && colorEnabled
        self.terminal = terminal
        self.json = json
        // Status lines never go to stderr, so whether it's a tty doesn't matter here.
        stderrTerminal = Terminal(colorEnabled: environment.stderrColor && colorEnabled, isTTY: false,
                                  width: environment.terminal.width)
    }

    func paint(_ text: String, _ style: TerminalStyle) -> String { terminal.paint(text, style) }

    func line(_ text: String = "") { output.out(text + "\n") }

    /// A question on stderr, so stdout stays clean for data and json.
    func ask(_ question: String) {
        output.err(stderrTerminal.paint("?", .warning) + " \(question) ")
    }

    func success(_ text: String) {
        clearStatus()
        line(paint("✔", .success) + " " + text)
    }

    func note(_ text: String) { line(paint(text, .muted)) }

    /// A warning on stderr (doesn't fail the command).
    func warn(_ text: String) {
        clearStatus()
        output.err(stderrTerminal.paint("!", .warning) + " " + text + "\n")
    }

    /// An error on stderr.
    func failure(_ failure: CLIFailure) {
        clearStatus()
        output.err(stderrTerminal.paint("✘", .danger) + " " + failure.message + "\n")
        if let hint = failure.hint, !hint.isEmpty {
            output.err(hint.split(separator: "\n", omittingEmptySubsequences: false)
                .map { stderrTerminal.paint("  " + $0, .muted) }.joined(separator: "\n") + "\n")
        }
    }

    /// A transient status line, shown only on a terminal (never with --json) and overwritten by
    /// the next line.
    func status(_ text: String) {
        guard terminal.isTTY, !json else { return }
        output.out("\r\u{1B}[2K" + paint("•", .accent2Style) + " " + paint(DisplayWidth.truncate(text, to: terminal.width - 2), .muted))
    }

    func clearStatus() {
        guard terminal.isTTY, !json else { return }
        output.out("\r\u{1B}[2K")
    }

    func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        line(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// A quoted title, the way gloss refers to books and pages in messages.
    func title(_ text: String) -> String {
        paint("“" + (text.isEmpty ? PageService.untitled : text) + "”", .strong)
    }
}

extension TerminalStyle {
    static let accent2Style = TerminalStyle(color: .accent2)
}

/// Short, readable forms of ids and dates.
enum Format {
    /// The last 8 characters of an id: the random tail of a UUIDv7, so short ids of things
    /// created in the same second still differ (prefixes are timestamps).
    static func shortID(_ id: some CustomStringConvertible) -> String { String(id.description.suffix(8)) }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "just now", "5 min ago", "3 days ago", or a date.
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return future(date, now: now) }
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: let h = Int(seconds / 3600); return "\(h) \(h == 1 ? "hour" : "hours") ago"
        case ..<(86_400 * 30): let d = Int(seconds / 86_400); return "\(d) \(d == 1 ? "day" : "days") ago"
        default: return day(date)
        }
    }

    /// "in 3 days", "in 5 hours", "any moment".
    static func future(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        switch seconds {
        case ..<60: return "any moment"
        case ..<3600: return "in \(Int(seconds / 60)) min"
        case ..<86_400: let h = Int(seconds / 3600); return "in \(h) \(h == 1 ? "hour" : "hours")"
        default: let d = Int((seconds / 86_400).rounded(.up)); return "in \(d) \(d == 1 ? "day" : "days")"
        }
    }

    static func bytes(_ count: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        guard unit > 0 else { return "\(count) bytes" }
        return String(format: value < 10 ? "%.1f" : "%.0f", value) + " " + units[unit]
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// Lines of text, not counting the empty line after a final newline.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
    }

    /// "1 line", "3 lines".
    static func lines(_ text: String) -> String {
        let count = lineCount(text)
        return "\(count) \(count == 1 ? "line" : "lines")"
    }
}
