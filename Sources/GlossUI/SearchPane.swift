import SwiftUI
import GlossAppModel
import GlossCore

/// The toolbar search: `.searchable` puts the field in the toolbar, `.searchScopes`
/// hangs the scope menu off it (the options come from where the user is, via `SearchModel`),
/// and the results replace the detail column while the search is open or a query stands —
/// Mail's search, with Books' "choosing a result closes the search".
///
/// On macOS 26 the search rests as a magnifying-glass toolbar button (`SearchToolbarButton`) and
/// the field exists only while the search is open or holds a query, like Mail's:
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
                        // Opening and closing switch at once: deliberately no transition.
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

/// Which column the results are in: the sidebar (a book is open; the book or notes stay in the
/// main pane beside it) or the main pane (the library, the trash).
enum SearchResultsPlacement {
    case sidebar, mainPane
}

/// The grouped results — notes, book text, library — with the match marked in each snippet.
/// The flat index is the session's stepping place: a click, Up/Down in the list, or ⌘G makes a
/// row current and opens it, and the list stays so the rest can be stepped through. The current
/// row is selected and kept visible.
struct SearchResults: View {
    let app: AppModel
    var placement: SearchResultsPlacement = .mainPane
    @State private var chosen: Int?

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(app.search.results) { section in
                    Section(content: { hits(of: section) }, header: { Text(verbatim: section.group.title) })
                }
            }
            .listStyle(placement == .sidebar ? .sidebar : .inset)
            .overlay {
                if !app.search.hasQuery {
                    // The search is open but the field is empty: say what it will look through.
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
            // Stepping (⌘G, the menu) moves the current row: keep it visible, centred like the
            // system's lists do. No animation, like the rest of the search.
            .onChange(of: app.search.stepper.current, initial: true) { _, current in
                chosen = current
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
            // Escape closes the search even when nothing has keyboard focus. A click on a blank part
            // of the results (or the reader having had focus before the book was swapped out) leaves
            // the window itself as first responder, where `.onExitCommand` never fires; a key
            // equivalent is looked up through the window's views regardless of focus. Not
            // `.hidden()`: hidden controls take no key equivalents.
            .background {
                Button("close search") { Task { await app.endSearch() } }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The list's selection is the session's current result: setting it (a click, Up/Down in the
    /// list) opens that result and makes it current. The window's ⌘G steps too, arriving here
    /// through the stepper's change.
    private var selection: Binding<Int?> {
        Binding(get: { chosen }, set: { new in
            guard let new, new != app.search.stepper.current else { return }
            chosen = new
            Task { await app.openSearchResult(at: new) }
        })
    }

    /// The section's rows, each tagged with its place in the flat stepping list.
    private func hits(of section: SearchResultSection) -> some View {
        ForEach(Array(section.hits.enumerated()), id: \.offset) { index, hit in
            SearchHitRow(hit: hit)
                .tag(flatIndex(of: index, in: section) ?? 0)
                .id(flatIndex(of: index, in: section) ?? 0)
        }
    }

    private func flatIndex(of index: Int, in section: SearchResultSection) -> Int? {
        app.search.index(of: section.hits[index])
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
