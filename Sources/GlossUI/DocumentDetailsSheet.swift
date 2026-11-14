import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlossAppModel
import GlossCore

/// The document details sheet: title, author and cover. The rules live in
/// `DocumentDetailsModel` (GlossAppModel, tested): the title is trimmed and never emptied,
/// only changed fields are written, and a cover can be chosen, dropped or removed. After a
/// save every pane that shows the book refreshes (the window title, the source list, the grid).
struct DocumentDetailsSheet: View {
    let app: AppModel
    let documentID: DocumentID
    @Environment(\.dismiss) private var dismiss
    @State private var model: DocumentDetailsModel?

    var body: some View {
        Group {
            if let model {
                form(model)
            } else {
                ProgressView()
                    .padding(40)
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .task(id: documentID) { await load() }
    }

    /// The book may be gone by the time the sheet shows (trashed from the cli): just close.
    private func load() async {
        guard let document = try? await app.services.library.document(documentID), document.trash == nil else {
            dismiss()
            return
        }
        model = DocumentDetailsModel(services: app.services, document: document)
    }

    private func form(_ model: DocumentDetailsModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            CoverWell(model: model, app: app)
            VStack(alignment: .leading, spacing: 10) {
                Text("title").font(.headline)
                TextField("title", text: Binding(
                    get: { model.draft.title },
                    set: { model.draft.title = $0 }
                ))
                if let problem = model.titleProblem {
                    Text(verbatim: problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("author").font(.headline)
                TextField("author", text: Binding(
                    get: { model.draft.author },
                    set: { model.draft.author = $0 }
                ))
            }
            if let problem = model.coverProblem ?? model.saveProblem {
                Text(verbatim: problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("cancel", role: .cancel) { dismiss() }
                Button("save") { Task { await save(model) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isValid)
            }
        }
        .padding(20)
    }

    private func save(_ model: DocumentDetailsModel) async {
        if await model.save() {
            await app.refreshAfterDetailsEdit(of: documentID)
            dismiss()
        }
    }
}

/// The cover well: the cover as it stands (a chosen image, the current one, or the generated
/// fallback), with choose, drop and remove. Removing goes back to the file's cover, or the
/// generated one.
private struct CoverWell: View {
    let model: DocumentDetailsModel
    let app: AppModel
    @State private var currentCover: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            preview
                .frame(width: 96)
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in await model.chooseCover(from: url) }
                    }
                    return true
                }
            VStack(alignment: .leading, spacing: 8) {
                Button("choose…") { showCoverPanel() }
                if model.showsRemoveCover {
                    Button("remove custom cover", role: .destructive) { model.removeCover() }
                }
                Text("drop an image on the cover")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The chosen image once there is one, else the cover the library has (the file's, the
    /// custom one), else the generated fallback.
    @ViewBuilder private var preview: some View {
        ZStack {
            if case .set(let data) = model.cover, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let currentCover {
                Image(nsImage: currentCover).resizable().scaledToFill()
            } else {
                GeneratedCoverView(style: GeneratedCoverStyle(document: model.document))
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipped()
        .task(id: model.document.id) {
            if case .set = model.cover { return }
            currentCover = await app.library.cover(of: model.document.id).flatMap { NSImage(data: $0.data) }
        }
    }

    private func showCoverPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.image]
        panel.message = "choose a cover image"
        LibraryPanels.present(panel) { urls in
            guard let url = urls.first else { return }
            Task { await model.chooseCover(from: url) }
        }
    }
}
