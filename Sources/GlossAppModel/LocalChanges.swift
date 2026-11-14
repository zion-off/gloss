import Foundation
import Observation
import GlossCore

/// Same-process, cross-window change fan-out: the change journal's origin is
/// per-process, so a second window's monitor never sees the first window's writes — windows
/// only agreed on the sort and settings because those got their own fan-outs.
/// A window posts what it wrote here, addressed to the store it shares with the app's other
/// windows (`object:`, so tests with separate libraries never hear each other), and every
/// window applies the others' records through `handleExternalChanges`, unchanged.
public extension Notification.Name {
    static let glossLocalChanges = Notification.Name("gloss.localChanges")
}

/// The `userInfo` key a `glossLocalChanges` notification carries its records under.
public let glossLocalChangesKey = "records"

/// Posts what one window wrote, in the journal's own shape so the receiving windows can reuse
/// their external-change reaction unchanged. Each record's `origin` carries the posting
/// window's id, which is how a window recognises (and skips) its own writes.
public enum LocalChanges {
    public static func post(_ records: [ChangeRecord], from window: String, to store: any LibraryStore) {
        guard !records.isEmpty else { return }
        let marked = records.map { record in
            ChangeRecord(sequence: record.sequence, entity: record.entity, entityID: record.entityID,
                         origin: window, date: record.date)
        }
        NotificationCenter.default.post(name: .glossLocalChanges, object: store as AnyObject,
                                        userInfo: [glossLocalChangesKey: marked])
    }
}
