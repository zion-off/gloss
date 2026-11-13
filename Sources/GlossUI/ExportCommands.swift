#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import GlossAppModel
import GlossCore

/// The File menu's export and print actions for the focused window. The portable half is
/// `ExportModel` (what to export, the file name, failures); this is the AppKit half: the save
/// panel, and printing the html export from an offscreen web view (D-133, D-134).
@MainActor @Observable public final class ExportActions {
    @ObservationIgnored weak var app: AppModel?
    /// A save or print panel is up (menus stay quiet meanwhile).
    public internal(set) var isBusy = false

    public init() {}

    public func bind(_ app: AppModel) {
        self.app = app
    }

    public var canExportBook: Bool {
        guard let app else { return false }
        return app.workspace.document != nil && app.export.isAvailable
    }

    public var canExportPage: Bool {
        guard let app else { return false }
        return app.workspace.page != nil && app.export.isAvailable
    }

    public var canPrint: Bool { canExportPage }

    // MARK: Export

    /// The open book's notes as one markdown file (brief 41).
    public func exportBookNotes() {
        Task { await exportBookNotesNow() }
    }

    /// The open notes page, with or without the pages inside it.
    public func exportPage(includeSubpages: Bool) {
        Task { await exportPageNow(includeSubpages: includeSubpages) }
    }

    private func exportBookNotesNow() async {
        guard let app, let document = app.workspace.document else { return }
        guard let exported = await app.export.exportBookNotes(of: document.id) else { return }
        await save(exported)
    }

    private func exportPageNow(includeSubpages: Bool) async {
        guard let app, let page = app.workspace.page else { return }
        guard let exported = await app.export.exportPage(page.id, includeSubpages: includeSubpages) else { return }
        await save(exported)
    }

    /// One save panel with the export's own default name; the export already failed loudly if
    /// there was nothing to write.
    private func save(_ exported: ExportModel.ExportedNotes) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = exported.filename
        panel.canCreateDirectories = true
        panel.message = "one markdown file, ready anywhere"
        isBusy = true
        defer { isBusy = false }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exported.data.write(to: url, options: .atomic)
        } catch {
            app?.export.recordFailure("couldn't write \(url.lastPathComponent)")
        }
    }

    // MARK: Print (⌘P)

    /// File › print…: the open notes (the page and its subpages) through the print panel,
    /// whose pdf menu saves a pdf ("pdf via print", brief 41).
    public func printPage() {
        Task { await printPageNow() }
    }

    private func printPageNow() async {
        guard let app, let page = app.workspace.page else { return }
        guard let printable = await app.export.printablePage(page.id, includeSubpages: true) else { return }
        await print(printable)
    }

    /// The html export renders in an offscreen web view — the exporter's stylesheet is built
    /// for exactly this — and the web view's print operation runs the print panel.
    private func print(_ printable: ExportModel.PrintableNotes) async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        let waiter = PrintLoadWaiter()
        webView.navigationDelegate = waiter
        _ = webView.loadHTMLString(printable.html, baseURL: nil)
        guard await waiter.finished() else {
            app?.export.recordFailure("couldn't get the notes ready to print")
            return
        }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.jobTitle = printable.title
        isBusy = true
        defer { isBusy = false }
        if let window = NSApplication.shared.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            _ = operation.run()
        }
    }
}

/// Waits for the print web view to load once; a timeout (5s) counts as a failure, so a page
/// that never settles can't wedge the menu item.
@MainActor private final class PrintLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    func finished() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.resume(false)
            }
        }
    }

    private func resume(_ loaded: Bool) {
        timeout?.cancel()
        continuation?.resume(returning: loaded)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resume(false)
    }
}

/// The File menu: exporting notes and print. ⌘P is the system's, so it replaces the (empty)
/// print group; the export items sit after "new" like Preview's export.
public struct GlossExportCommands: Commands {
    @FocusedValue(\.exportActions) private var actions: ExportActions?

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("export book's notes…") { actions?.exportBookNotes() }
                .disabled(actions?.canExportBook != true || actions?.isBusy == true)
            Button("export this page…") { actions?.exportPage(includeSubpages: false) }
                .disabled(actions?.canExportPage != true || actions?.isBusy == true)
            Button("export page and subpages…") { actions?.exportPage(includeSubpages: true) }
                .disabled(actions?.canExportPage != true || actions?.isBusy == true)
        }
        CommandGroup(replacing: .printItem) {
            Button("print notes…") { actions?.printPage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions?.canPrint != true)
        }
    }
}

extension FocusedValues {
    /// The focused window's export and print actions.
    @Entry public var exportActions: ExportActions?
}

/// Two one-liners MainWindow attaches: the export failure alert, and the notes pane's context
/// menu with the page exports.
extension View {
    /// The alert for an export or print failure (`ExportModel.failure`).
    public func exportFailureAlert(app: AppModel) -> some View {
        alert("couldn't export", isPresented: Binding(
            get: { app.export.failure != nil },
            set: { if !$0 { app.export.clearFailure() } })) {
            Button("ok") { app.export.clearFailure() }
        } message: {
            Text(verbatim: app.export.failure ?? "")
        }
    }

    /// The notes pane's context menu: export the open page, with or without its subpages.
    public func notesExportMenu(actions: ExportActions?) -> some View {
        contextMenu {
            Button("export this page…") { actions?.exportPage(includeSubpages: false) }
                .disabled(actions?.canExportPage != true)
            Button("export page and subpages…") { actions?.exportPage(includeSubpages: true) }
                .disabled(actions?.canExportPage != true)
        }
    }
}
#endif
