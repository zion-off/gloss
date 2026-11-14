#if os(macOS)
import SwiftUI
import GlossAppModel
import GlossCore

/// The trash: what's in it, when each thing goes away for good, put back, delete
/// for good, and empty. The source list's badge is `TrashModel.items.count`, which every
/// restore, purge and empty here reloads.
struct TrashView: View {
    let trash: TrashModel
    /// Holds the "empty the trash?" question: its button lives in the window's toolbar, so the
    /// trailing toolbar order is the window's to decide.
    let presentation: LibraryPresentationModel
    /// The row about to be deleted for good (a confirmation, like the cli's question).
    @State private var confirmDelete: TrashOverview.Item?

    var body: some View {
        Group {
            if trash.items.isEmpty {
                ContentUnavailableView("nothing in the trash", systemImage: "trash",
                                       description: Text("things you delete wait here first"))
            } else {
                List {
                    ForEach(trash.items) { item in
                        row(item)
                            .contextMenu {
                                Button("put back") { Task { await trash.restore(item.entry.id) } }
                                Divider()
                                Button("delete for good…", role: .destructive) { confirmDelete = item }
                            }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let problem = trash.restoreProblem {
                // A restore that brought nothing back says so, and goes when the
                // situation is over — floating like its sibling below.
                Text(verbatim: problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
            } else if let message = trash.lastRestoredMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
            }
        }
        .confirmationDialog("delete for good?",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } })) {
            Button("delete for good", role: .destructive) {
                if let item = confirmDelete { Task { await trash.purge(item.entry.id) } }
            }
        } message: {
            if let item = confirmDelete {
                Text(verbatim: "“\(item.title)” goes away for good, with everything inside it.")
            }
        }
        .confirmationDialog("empty the trash?", isPresented: Binding(get: { presentation.confirmsEmptyTrash },
                                                                    set: { presentation.confirmsEmptyTrash = $0 })) {
            Button("empty trash", role: .destructive) { Task { await trash.empty() } }
        } message: {
            Text(verbatim: "\(trash.items.count) \(trash.items.count == 1 ? "thing" : "things") go away for good.")
        }
    }

    // MARK: Rows

    /// One trashed thing: what it is, its title, which book it lived in, and the two dates.
    private func row(_ item: TrashOverview.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(of: item.entry.kind))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .lineLimit(2)
                if let book = item.documentTitle, item.entry.kind != .document {
                    Text(verbatim: "in \(book)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                details(item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("put back") { Task { await trash.restore(item.entry.id) } }
        }
        .padding(.vertical, 2)
    }
    /// "trashed 2 hours ago · gone for good in 28 days" — or "kept until you empty the trash".
    private func details(_ item: TrashOverview.Item) -> Text {
        var text = Text("trashed ") + Text(item.entry.trashedAt, style: .relative)
        text = text + Text(verbatim: " · ")
        if let expiry = item.expiresAt {
            text = text + Text("gone for good ") + Text(expiry, style: .offset)
        } else {
            text = text + Text(verbatim: "kept until you empty the trash")
        }
        return text
    }

    /// The symbol for what an entry holds. Kinds are open (new handlers register their own);
    /// unknown ones read as a plain page.
    private func symbol(of kind: TrashableKind) -> String {
        kind == .document ? "books.vertical" : "doc.text"
    }
}
#endif
