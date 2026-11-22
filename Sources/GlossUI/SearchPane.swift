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
            .modifier(SearchFieldFocus(model: model))
    }
}

/// Puts the cursor in the field when the model asks (Find…, the search button). `initial` covers
/// the field macOS 26 creates on demand: it arrives with the request already standing. Before
/// macOS 15 there is no way to focus a toolbar search field, and opening it is all there is.
private struct SearchFieldFocus: ViewModifier {
    let model: SearchModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(Focusing(model: model))
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private struct Focusing: ViewModifier {
        let model: SearchModel
        @FocusState private var focused: Bool

        func body(content: Content) -> some View {
            content
                .searchFocused($focused)
                .onChange(of: model.wantsFieldFocus, initial: true) { _, wants in
                    guard wants else { return }
                    // A turn later: a field the toolbar is only now adding can't take focus yet.
                    Task { @MainActor in
                        focused = true
                        model.fieldDidTakeFocus()
                    }
                }
        }
    }
}

/// The resting search on macOS 26: a magnifying glass that opens the field in its place.
struct SearchToolbarButton: View {
    let model: SearchModel

    var body: some View {
        Button { model.present() } label: {
            Label("search", systemImage: "magnifyingglass")
        }
        .help("search your books and notes (⌘F)")
    }
}

/// Which column the results are in: the sidebar (a book is open; the book or notes stay in the
/// main pane beside it) or the main pane (the library, the trash).
enum SearchResultsPlacement {
    case sidebar, mainPane
}

/// The sidebar's empty state: a title and one line of detail in small secondary type.
private struct CompactEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// The sidebar's list style in the sidebar, the inset one in the main pane (the two styles are
/// different types, so a ternary between them doesn't compile).
private struct ResultsListStyle: ViewModifier {
    let placement: SearchResultsPlacement

    func body(content: Content) -> some View {
        if placement == .sidebar {
            content.listStyle(.sidebar)
        } else {
            content.listStyle(.inset)
        }
    }
}

/// The grouped results — notes, book text, library — with the match marked in each snippet.
/// The flat index is the session's stepping place: a click, Up/Down in the list, or ⌘G makes a
/// row current and opens it, and the list stays so the rest can be stepped through. The current
/// row is selected and kept visible.
struct SearchResults: View {
    let app: AppModel
    var placement: SearchResultsPlacement = .mainPane
    @State private var chosen: Int?

    /// What shows when there is nothing to list. The main pane has room for the system's empty
    /// state; the sidebar is narrow, so it gets a quiet two-line note instead of a big icon.
    @ViewBuilder private var emptyState: some View {
        let scope = app.search.scopeTitle.map { "type to search \($0)" } ?? "type to search gloss"
        if !app.search.hasQuery {
            // The search is open but the field is empty: say what it will look through.
            switch placement {
            case .sidebar:
                CompactEmptyState(title: "search your books and notes", detail: scope)
            case .mainPane:
                ContentUnavailableView {
                    Label("search your books and notes", systemImage: "magnifyingglass")
                } description: {
                    Text(verbatim: scope)
                }
            }
        } else if !app.search.isSearching, app.search.results.isEmpty {
            switch placement {
            case .sidebar:
                CompactEmptyState(title: "no matches", detail: "nothing in gloss matches that yet")
            case .mainPane:
                ContentUnavailableView("no matches", systemImage: "magnifyingglass",
                                       description: Text("nothing in gloss matches that yet"))
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                ResultSections(sections: app.search.results, starts: app.search.stepper.sectionStarts)
            }
            .modifier(ResultsListStyle(placement: placement))
            .overlay { emptyState }
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
                    // Escape closes the innermost thing first: with the results in the sidebar
                    // the notes editor is on screen beside them, and its open slash menu takes
                    // Escape before the search does (a key equivalent would otherwise win).
                    .disabled(app.notes.slashMenu != nil)
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
}

/// The rows, apart from the list: nothing they take changes when the selection does, so a step
/// (⌘G, a click) doesn't make SwiftUI walk every result, which took a second with 100k of them.
private struct ResultSections: View {
    let sections: [SearchResultSection]
    let starts: [String: Int]

    var body: some View {
        ForEach(sections) { section in
            Section(content: { hits(of: section) }, header: { Text(verbatim: section.group.title) })
        }
    }

    /// The section's rows, each tagged with its place in the flat stepping list.
    private func hits(of section: SearchResultSection) -> some View {
        let start = starts[section.id] ?? 0
        return ForEach(section.hits.indices, id: \.self) { index in
            SearchHitRow(hit: section.hits[index])
                .tag(start + index)
                .id(start + index)
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
