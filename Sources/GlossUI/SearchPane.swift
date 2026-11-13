#if os(macOS)
import SwiftUI
import GlossAppModel
import GlossCore

/// The toolbar search (brief 31): `.searchable` puts the field in the toolbar, `.searchScopes`
/// hangs the scope menu off it (the options come from where the user is, via `SearchModel`),
/// and the results replace the detail column while the search is open or a query stands —
/// Mail's search, with Books' "choosing a result closes the search" (D-130, D-151).
///
/// On macOS 26 the search rests as a magnifying-glass toolbar button (`SearchToolbarButton`) and
/// the field exists only while the search is open or holds a query, like Mail's (D-152):
/// `searchToolbarBehavior(.minimize)` is unavailable on macOS, so the field's `searchable` sits on
/// a background view that comes and goes, leaving the window's own view tree untouched. Earlier
/// systems keep the standard always-visible field.
extension View {
    public func glossSearch(model: SearchModel) -> some View {
        modifier(GlossSearch(model: model))
    }
}

private struct GlossSearch: ViewModifier {
    let model: SearchModel

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background {
                if model.showsResults {
                    Color.clear.modifier(SearchField(model: model))
                }
            }
        } else {
            content.modifier(SearchField(model: model))
        }
    }
}

/// The field itself: query, open/closed state and the scope menu, all the model's.
private struct SearchField: ViewModifier {
    let model: SearchModel

    func body(content: Content) -> some View {
        content
            .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }),
                        isPresented: Binding(get: { model.isPresented }, set: { model.isPresented = $0 }),
                        placement: .toolbar,
                        prompt: "search")
            .searchScopes(Binding(get: { model.scope }, set: { model.setScope($0) }),
                          activation: .onTextEntry) {
                ForEach(model.scopeOptions) { option in
                    Text(verbatim: option.title).tag(option.scope)
                }
            }
    }
}

/// The resting search on macOS 26: a magnifying glass that opens the field in its place.
struct SearchToolbarButton: View {
    let model: SearchModel

    var body: some View {
        Button { model.isPresented = true } label: {
            Label("search", systemImage: "magnifyingglass")
        }
        .help("search your books and notes")
    }
}

/// Where a result sits in the results: its section and its place in it. Search hits carry no
/// id of their own, and wrapping them in fresh UUIDs every render would churn the list's
/// identity, so the rows are tagged by position instead.
struct SearchResultKey: Hashable {
    var section: String
    var index: Int
}

/// The grouped results — notes, book text, library — with the hit marked in each snippet.
/// Arrow keys move through the list (a plain `List` selection); choosing a row dismisses the
/// search and jumps to the hit.
struct SearchResults: View {
    let app: AppModel
    @State private var chosen: SearchResultKey?

    var body: some View {
        List(selection: Binding(get: { chosen }, set: { chosen = $0 })) {
            ForEach(app.search.results) { section in
                Section(content: { hits(of: section) }, header: { Text(verbatim: section.group.title) })
            }
        }
        .overlay {
            if !app.search.hasQuery {
                // The search is open but the field is empty: say what it will look through (D-151).
                ContentUnavailableView {
                    Label("search your books and notes", systemImage: "magnifyingglass")
                } description: {
                    Text(verbatim: app.search.scopeTitle.map { "type to search \($0)" } ?? "type to search gloss")
                }
            } else if !app.search.isSearching, app.search.results.isEmpty {
                ContentUnavailableView("no matches", systemImage: "magnifyingglass",
                                       description: Text("nothing in gloss matches that yet"))
            }
        }
        .onChange(of: chosen) { _, new in
            guard let new else { return }
            choose(new)
        }
        .onChange(of: app.search.results) { _, _ in
            chosen = nil  // new results: nothing is selected, and a stale pick can't block a click
        }
    }

    /// The section's rows, each tagged with where it sits.
    private func hits(of section: SearchResultSection) -> some View {
        ForEach(Array(section.hits.enumerated()), id: \.offset) { index, hit in
            SearchHitRow(hit: hit)
                .tag(SearchResultKey(section: section.id, index: index))
        }
    }

    /// A row became the selection: jump there and hand the window back.
    private func choose(_ key: SearchResultKey) {
        guard let section = app.search.results.first(where: { $0.id == key.section }),
              section.hits.indices.contains(key.index) else { return }
        let hit = section.hits[key.index]
        Task {
            await app.reveal(SearchModel.Hit(hit: hit, section: key.section).selection)
            app.search.dismiss()
        }
    }
}

/// One result: its title, where it lives, and the snippet with the match emphasised.
struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: hit.title)
                    .lineLimit(1)
                if let subtitle = hit.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            snippetText
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(hit.title): \(hit.snippet.plainText)"))
    }

    /// The snippet with matching segments emphasised, like the search field's own suggestions.
    private var snippetText: Text {
        hit.snippet.segments.reduce(Text(verbatim: "")) { acc, segment in
            (acc + Text(verbatim: segment.text)
                .foregroundStyle(segment.isMatch ? Color.accentColor : Color.secondary))
        }
    }
}
#endif
