import Foundation
import GlossCore

/// The portable decisions behind a generated cover (brief 34): which tint a book with no cover
/// image gets, and how its title and author are laid out. The Mac layer only draws this; the
/// decisions are here so they are identical every launch and testable on Linux.
///
/// The tint is picked from a fixed palette by a stable hash of the document's id, so a book
/// never changes colour between launches or windows (the id never changes).
public struct GeneratedCoverStyle: Hashable, Sendable {
    /// A palette colour, in sRGB 0…1.
    public struct Swatch: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public var swatch: Swatch
    /// The title, wrapped to short lines (at most three), "…" when cut.
    public var titleLines: [String]
    /// The author, trimmed; nil when the book names none.
    public var author: String?

    public init(document: Document) {
        swatch = Self.palette[Self.pick(document.id.stringValue) % Self.palette.count]
        titleLines = Self.wrap(document.title)
        let author = document.author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = author.isEmpty ? nil : author
    }

    /// Muted, bookshelf-like colours, all dark enough for white text (no lightness juggling in
    /// the view). Ordered so neighbours feel varied.
    public static let palette: [Swatch] = [
        Swatch(red: 0.27, green: 0.35, blue: 0.52),  // slate blue
        Swatch(red: 0.44, green: 0.24, blue: 0.32),  // oxblood
        Swatch(red: 0.20, green: 0.38, blue: 0.36),  // deep teal
        Swatch(red: 0.46, green: 0.34, blue: 0.20),  // ochre
        Swatch(red: 0.33, green: 0.25, blue: 0.45),  // plum
        Swatch(red: 0.17, green: 0.30, blue: 0.20),  // forest
        Swatch(red: 0.50, green: 0.28, blue: 0.24),  // rust
        Swatch(red: 0.24, green: 0.26, blue: 0.40),  // indigo
        Swatch(red: 0.38, green: 0.19, blue: 0.30),  // mulberry
        Swatch(red: 0.16, green: 0.33, blue: 0.45),  // petrol
    ]

    /// A stable, deterministic hash (FNV-1a over the id string): the same book always picks the
    /// same colour, on every launch and every machine.
    static func pick(_ id: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % 1_000_000_007)
    }

    /// The longest a generated title line runs; covers are narrow.
    static let lineLimit = 14
    static let maxLines = 3

    /// Word-wraps a title to short lines, at most three, marking a cut with "…". A word longer
    /// than a line is split. An untitled book keeps one empty line (the view shows a book symbol).
    static func wrap(_ title: String) -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [""] }
        var lines: [String] = []
        var line = ""
        func endLine() {
            lines.append(line)
            line = ""
        }
        for word in trimmed.split(separator: " ", omittingEmptySubsequences: true) {
            var piece = String(word)
            // A word longer than a line is split at the line width.
            while piece.count > lineLimit {
                let head = String(piece.prefix(lineLimit))
                piece = String(piece.dropFirst(lineLimit))
                if !line.isEmpty { endLine() }
                line = head
                endLine()
            }
            if piece.isEmpty { continue }
            if line.isEmpty {
                line = piece
            } else if line.count + 1 + piece.count <= lineLimit {
                line += " " + piece
            } else {
                endLine()
                line = piece
            }
        }
        if !line.isEmpty { endLine() }
        // Too long even for three lines: keep the first three and mark the cut.
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines[lines.count - 1] = String(lines.last!.prefix(lineLimit - 1)) + "…"
        }
        return lines
    }
}
