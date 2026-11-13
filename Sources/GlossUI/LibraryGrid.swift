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

    // MARK: Drop

    /// The window is the drop zone; while a drag is over it the library gets the system's
    /// drop-target ring, an accent outline like Finder and Mail draw, and nothing else (D-148).
    /// Import progress lives in the toolbar (`LibraryFeatures`).
    @ViewBuilder private var dropHighlight: some View {
        if presentation.dropTargeted {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(4)
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
                // Every cell reserves the same text lines, so covers line up whatever is below them.
                Text(verbatim: entry.document.title)
                    .font(.callout)
                    .lineLimit(2, reservesSpace: true)
                Text(verbatim: entry.document.author.isEmpty ? " " : entry.document.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Like Books: a quiet line of text, no bar and no badge on the cover. A book never
                // opened shows only its format: absence of a percentage is the "new" state (D-115).
                Text(verbatim: statusLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

    /// The format's own word ("epub", "pdf"), then how far along the reader is, when they've started.
    private var statusLine: String {
        let kind = library.badge(of: entry.document.kind)
        guard entry.position != nil else { return kind }
        return entry.progress >= 0.995 ? "\(kind) · finished" : "\(kind) · \(Int((entry.progress * 100).rounded()))%"
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
        // The cell's size comes from this 2:3 shape alone; the cover is drawn over it. An image
        // laid out as the content would size the cell to its own aspect ratio (a PDF page is
        // not 2:3) and spill into its neighbours, clipping or not.
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    GeneratedCoverView(style: GeneratedCoverStyle(document: entry.document))
                }
            }
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
