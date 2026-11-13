import Foundation

/// Backup file names, in one place: the cli (`gloss backup <folder>`) and the app's
/// "back up library…" panel must offer the same shape of name.
public enum LibraryBackupNaming {
    /// "gloss backup 2026-11-13 1015.sqlite" — the date in the user's time zone, to the minute,
    /// so two backups of one session never collide.
    public static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "gloss backup \(formatter.string(from: date)).sqlite"
    }
}
