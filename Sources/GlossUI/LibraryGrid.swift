#if os(macOS)
import AppKit
import SwiftUI
import GlossAppModel
import GlossCore

/// The library detail column (brief 34): a "recently read" shelf above an Apple Books-style
/// grid of covers. Every decision is portable and lives in GlossAppModel (the sort, the
/// generated-cover look, what an import found); this view renders state and forwards events.
/// A single click opens the book, as Books does; arrow-key selection is not part of it.
struct LibraryGrid: View {
    let library: LibraryModel
    let presentation: LibraryPresentationModel
    let open: @MainActor (DocumentID) async -> Void
    /// brief 39's trash-with-undo toast lands with the trash slice; the lead wires it at merge.
    let moveToTrash: @MainActor (Document) -> Void

    /// Covers sit in columns between these widths, as many as fit.
    private static let columns = [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 16)]

    var body: some View {
        ScrollView {
            if library.entries.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if showsRecentShelf { recentShelf }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 20) {
                        ForEach(library.entries) { entry in
                            CoverCell(entry: entry, library: library, presentation: presentation,
                                      open: open, moveToTrash: moveToTrash)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { importStatusLine }
        .overlay { dropHighlight }
    }

    /// The shelf only shows on "all" (D-111): a filter means "show me this kind", and the recent
    /// row would repeat what the grid below already holds.
    private var showsRecentShelf: Bool {
        library.shelf == nil && !library.recentlyRead.isEmpty
    }

    // MARK: The recent shelf

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently read").font(.title3)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(library.recentlyRead) { entry in
                        RecentCell(entry: entry, library: library, open: open)
                    }
                }
            }
        }
    }

    // MARK: Empty states (brief 38)

    /// The home empty state is a drop zone: the whole window takes the drop, this says so.
    private var emptyState: some View {
        ContentUnavailableView {
            if let shelf = library.shelf {
                Label("no \(shelf.rawValue) yet", systemImage: library.symbol(of: shelf))
            } else {
                Label("nothing glossed yet", systemImage: "books.vertical")
            }
        } description: {
            Text("drop a book on this window, or choose file › import…")
        } actions: {
            Button("import…") { presentation.showsImportPanel = true }
        }
    }

    // MARK: Import feedback

    /// One quiet line while an import runs, Books-style, never blocking the UI (the work
    /// happens off the main actor).
    @ViewBuilder private var importStatusLine: some View {
        if library.importing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: library.importStatus ?? "importing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(16)
        }
    }

    /// The window is the drop zone; this rings the library while a drag is over it.
    @ViewBuilder private var dropHighlight: some View {
        if presentation.dropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06))
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2)
                Text("drop to add to your library")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(10)
            .allowsHitTesting(false)
        }
    }
}

/// One grid cell: the cover (real, or generated from the title), the kind badge, reading
/// progress, then title and author. A click opens the book; the context menu edits or trashes.
private struct CoverCell: View {
    let entry: LibraryEntry
    let library: LibraryModel
    let presentation: LibraryPresentationModel
    let open: @MainActor (DocumentID) async -> Void
    let moveToTrash: @MainActor (Document) -> Void

    var body: some View {
        Button {
            Task { await open(entry.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverArt(entry: entry, library: library)
                    .overlay(alignment: .bottomTrailing) { kindBadge }
                if entry.position != nil {
                    // A book never opened shows no bar: absence is the "new" state (D-115).
                    ProgressView(value: entry.progress)
                        .padding(.top, -2)
                }
                Text(verbatim: entry.document.title)
                    .font(.callout)
                    .lineLimit(2)
                if !entry.document.author.isEmpty {
                    Text(verbatim: entry.document.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("open") { Task { await open(entry.id) } }
            Button("edit details…") { presentation.detailsDocument = entry.id }
            Divider()
            Button("move to trash", role: .destructive) { moveToTrash(entry.document) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    /// The badge names the kind ("epub", "pdf") — the format's own word, never a switch on kind.
    private var kindBadge: some View {
        Text(verbatim: library.badge(of: entry.document.kind))
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .padding(5)
    }

    private var accessibilityLabel: String {
        var parts = [entry.document.title]
        if !entry.document.author.isEmpty { parts.append("by \(entry.document.author)") }
        parts.append(library.badge(of: entry.document.kind))
        if entry.position != nil {
            parts.append("\(Int((entry.progress * 100).rounded()))% read")
        } else {
            parts.append("not started yet")
        }
        return parts.joined(separator: ", ")
    }
}

/// One cell of the "recently read" shelf: a smaller cover and the title.
private struct RecentCell: View {
    let entry: LibraryEntry
    let library: LibraryModel
    let open: @MainActor (DocumentID) async -> Void

    var body: some View {
        Button {
            Task { await open(entry.id) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                CoverArt(entry: entry, library: library)
                    .frame(width: 92)
                Text(verbatim: entry.document.title)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(entry.document.title), recently read"))
    }
}

/// A rendered cover: the book's own image once it loads, with the generated one underneath so
/// nothing ever flashes empty. Re-loads when the document's custom cover changes.
private struct CoverArt: View {
    let entry: LibraryEntry
    let library: LibraryModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedCoverView(style: GeneratedCoverStyle(document: entry.document))
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipped()
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1.5)
        .task(id: CoverKey(entry: entry)) {
            image = await library.cover(of: entry.id).flatMap { NSImage(data: $0.data) }
        }
    }

    /// A custom cover coming or going must redraw the cell.
    private struct CoverKey: Hashable {
        let id: DocumentID
        let coverHash: ContentHash?

        init(entry: LibraryEntry) {
            id = entry.id
            coverHash = entry.document.coverHash
        }
    }
}

/// The fallback cover (brief 34): title and author on a tint Books never change between
/// launches — the tint and the text layout are decided in GlossAppModel (GeneratedCoverStyle).
struct GeneratedCoverView: View {
    let style: GeneratedCoverStyle

    var body: some View {
        ZStack {
            Rectangle().fill(Color(red: style.swatch.red, green: style.swatch.green, blue: style.swatch.blue))
            VStack(spacing: 5) {
                if style.titleLines == [""] {
                    Image(systemName: "books.vertical")
                        .font(.title2)
                } else {
                    ForEach(style.titleLines, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.system(size: 12, weight: .semibold, design: .serif))
                            .lineLimit(1)
                    }
                }
                if let author = style.author {
                    Text(verbatim: author)
                        .font(.system(size: 9))
                        .opacity(0.8)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
