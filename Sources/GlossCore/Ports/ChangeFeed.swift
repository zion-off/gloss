import Foundation

/// Names of entities recorded in the change journal.
public enum ChangeEntity {
    public static let document = "document"
    public static let page = "page"
    public static let highlight = "highlight"
    public static let linkTarget = "linkTarget"
    public static let readingPosition = "readingPosition"
    public static let setting = "setting"
    public static let trash = "trash"
}

public struct ChangeRecord: Hashable, Sendable {
    public var sequence: Int64
    public var entity: String
    public var entityID: String
    public var origin: String
    public var date: Date

    public init(sequence: Int64, entity: String, entityID: String, origin: String, date: Date) {
        self.sequence = sequence
        self.entity = entity
        self.entityID = entityID
        self.origin = origin
        self.date = date
    }
}

/// Every write is journaled with the writing process's `origin`, so one process can notice
/// what another (the CLI, say) changed.
public protocol ChangeFeed: Sendable {
    /// Identifies this process's writes.
    var origin: String { get }
    func latestChangeSequence() async throws -> Int64
    func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord]
    /// Drops journal entries older than `date`.
    func trimChanges(before date: Date) async throws
}

/// Makes a consistent copy of the whole library.
public protocol LibraryBackup: Sendable {
    func backup(to url: URL) async throws
}
