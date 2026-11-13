#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlossAppModel
import GlossCore

/// Everything the library adds around the window, in one modifier MainWindow applies in one
/// line: the whole-window drop zone, the import panel, the "already in your library" offer,
/// the details sheet (the toolbar's sort menu and import ring are placed by the window's toolbar). The panel and drop both funnel into
/// `LibraryModel.importFiles`, the single import entry point (the Finder and `gloss://` paths
/// call it too).
extension View {
    public func libraryFeatures(app: AppModel) -> some View {
        LibraryFeatures(app: app) { self }
    }
}

/// The modifier above. Holds no state of its own: the window's `AppModel.presentation` is the
/// switchboard, so the source list and the File menu reach the same sheets.
private struct LibraryFeatures<Content: View>: View {
    let app: AppModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            // The whole window is the drop zone (brief 36); the grid draws the highlight.
            .onDrop(of: [UTType.fileURL], isTargeted: Binding(
                get: { app.presentation.dropTargeted },
                set: { app.presentation.dropTargeted = $0 }
            )) { providers in
                Self.importDropped(providers, into: app)
            }
            .onChange(of: app.presentation.showsImportPanel) { _, shows in
                if shows {
                    app.presentation.showsImportPanel = false
                    Self.showImportPanel(app)
                }
            }
            .sheet(item: Binding(
                get: { app.presentation.detailsDocument.map(DetailsTarget.init) },
                set: { app.presentation.detailsDocument = $0?.id }
            )) { target in
                DocumentDetailsSheet(app: app, documentID: target.id)
            }
            .alert(importNews?.alertTitle ?? "", isPresented: importNewsPresented) {
                Button(importNews?.openActionTitle ?? "open") {
                    let duplicates = importNews?.duplicates ?? []
                    Task { await openDuplicates(duplicates) }
                }
                Button("not now", role: .cancel) { app.presentation.importNews = nil }
            } message: {
                Text(verbatim: importNews?.alertMessage ?? "")
            }
            .focusedSceneValue(\.libraryPresentation, app.presentation)
    }

    private var importNews: ImportSummary? { app.presentation.importNews }

    private var importNewsPresented: Binding<Bool> {
        Binding(get: { app.presentation.importNews != nil },
                set: { if !$0 { app.presentation.importNews = nil } })
    }

    /// Opens the copies the import already had, ending on the last one.
    private func openDuplicates(_ duplicates: [Document]) async {
        for document in duplicates {
            try? await app.workspace.openDocument(document.id)
        }
    }

    // MARK: The drop

    /// Accepts file and folder drags: every provider that carries a file URL is read (off the
    /// main actor by the load), then one import runs. Folders expand inside `importFiles`.
    private static func importDropped(_ providers: [NSItemProvider], into app: AppModel) -> Bool {
        guard providers.contains(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        let collector = DropCollector(count: providers.count, app: app)
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in await collector.add(url) }
            }
        }
        return true
    }

    /// Gathers dropped URLs on the main actor until every provider answered, then imports.
    @MainActor private final class DropCollector {
        private var urls: [URL] = []
        private var remaining: Int
        private let app: AppModel

        init(count: Int, app: AppModel) {
            remaining = count
            self.app = app
        }

        func add(_ url: URL?) async {
            if let url { urls.append(url) }
            remaining -= 1
            if remaining == 0, !urls.isEmpty {
                await Self.importChosen(urls, into: app)
            }
        }

        static func importChosen(_ urls: [URL], into app: AppModel) async {
            _ = await app.library.importFiles(at: urls)
            // VoiceOver hears the result; the toolbar ring just disappears for everyone else.
            if let announcement = app.library.lastImport?.announcement {
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                     userInfo: [.announcement: announcement])
            }
            if let news = app.library.lastImport, news.hasNews {
                app.presentation.importNews = news
            }
        }
    }

    // MARK: The import panel

    /// File › import…: a standard open panel over the registered formats' extensions — files,
    /// folders, several at once (brief 36); never a hardcoded list of kinds.
    @MainActor private static func showImportPanel(_ app: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = app.library.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "choose books to add to your library"
        panel.prompt = "add"
        LibraryPanels.present(panel) { urls in
            Task { await DropCollector.importChosen(urls, into: app) }
        }
    }
}

/// How the sort menu names each order (data, never localization keys).
/// The library's sort menu (toolbar, only on the library). The window's toolbar places it, so the
/// trailing order is fixed: [sort][search] (D-152).
struct LibrarySortMenu: View {
    let app: AppModel

    var body: some View {
        Menu {
            Picker("sort by", selection: Binding(
                get: { app.library.sort },
                set: { app.library.sort = $0 }
            )) {
                ForEach(LibrarySort.allCases, id: \.self) { sort in
                    Text(verbatim: librarySortTitles[sort] ?? sort.rawValue).tag(sort)
                }
            }
            // Flat in the menu, the current order checked (Photos' and Books' sort menus): a
            // picker in a menu is otherwise a submenu, one level deeper for nothing (D-163).
            .pickerStyle(.inline)
        } label: {
            Label("sort", systemImage: "arrow.up.arrow.down")
        }
        .help("how the grid is ordered")
    }
}

/// The toolbar's import progress: a small circular indicator, determinate once the files are
/// counted ("3 of 8" for VoiceOver), spinning while folders are still being looked through.
struct ImportActivity: View {
    let library: LibraryModel

    var body: some View {
        Group {
            if library.importTotal > 0 {
                ProgressView(value: Double(min(library.importCompleted, library.importTotal)),
                             total: Double(library.importTotal))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.circular)
        .controlSize(.small)
        .padding(.horizontal, 4)
        .help(library.importStatus ?? "importing…")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        library.importTotal > 1
            ? "importing, \(library.importCompleted) of \(library.importTotal)"
            : "importing"
    }
}

private let librarySortTitles: [LibrarySort: String] = [
    .recent: "recent", .title: "title", .author: "author", .dateAdded: "date added",
]

/// Presents an open panel as a sheet on the key window, app-modal when there is none.
@MainActor enum LibraryPanels {
    static func present(_ panel: NSOpenPanel, onPick: @escaping @MainActor ([URL]) -> Void) {
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { onPick(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            onPick(panel.urls)
        }
    }
}

/// The details sheet's anchor: `DocumentID` isn't Identifiable on its own.
private struct DetailsTarget: Identifiable {
    let id: DocumentID
}
#endif
