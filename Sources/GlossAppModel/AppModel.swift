import Foundation
import Observation
import GlossCore

/// One window's models over one set of services, plus the glue that reacts to external
/// changes. The Mac composition root builds this; views take the piece they need.
@MainActor @Observable public final class AppModel {
    public let services: GlossServices
    public let workspace: WorkspaceModel
    public let library: LibraryModel
    public let search: SearchModel
    public let trash: TrashModel
    public let switcher: QuickSwitcherModel
    public let router: URLRouter
    public let reader: ReaderController
    public var linking: LinkingCoordinator { LinkingCoordinator(services: services, reader: reader) }
    public var changeMonitor: ExternalChangeMonitor?

    public init(services: GlossServices) {
        self.services = services
        self.workspace = WorkspaceModel(services: services)
        self.library = LibraryModel(services: services)
        self.search = SearchModel(services: services, contextProvider: { [workspace] in workspace.searchContext })
        self.trash = TrashModel(services: services)
        self.switcher = QuickSwitcherModel(services: services)
        self.router = URLRouter(links: services.links)
        self.reader = ReaderController(services: services)
        reader.openNote = { [weak self] page, range in
            try? await self?.workspace.openPage(page, revealing: range)
        }
    }

    /// Wires the change monitor (call once at startup, after the views exist).
    public func startMonitoringChanges() async {
        guard changeMonitor == nil else { return }
        changeMonitor = await ExternalChangeMonitor(feed: services.store as? any ChangeFeed ?? NoChanges()) { [weak self] changes in
            await self?.handleExternalChanges(changes)
        }
    }

    /// Reloads what the changes touch.
    public func handleExternalChanges(_ changes: [ChangeRecord]) async {
        guard !changes.isEmpty else { return }
        let documentIDs = Set(changes.filter { $0.entity == ChangeEntity.document }.map(\.entityID))
        let pageIDs = Set(changes.filter { $0.entity == ChangeEntity.page }.map(\.entityID))
        if changes.contains(where: { $0.entity == ChangeEntity.trash }) {
            await trash.reload()
        }
        await library.invalidate(ids: documentIDs.compactMap { DocumentID($0) })
        await workspace.refresh()
        if !pageIDs.isEmpty || !documentIDs.isEmpty {
            search.contextChanged()
        }
        let annotationEntities: Set<String> = [ChangeEntity.page, ChangeEntity.highlight, ChangeEntity.linkTarget]
        if changes.contains(where: { annotationEntities.contains($0.entity) }) {
            await reader.refreshAnnotations()
        }
    }

    /// Applies a `gloss://` link; returns false when the destination is gone.
    @discardableResult
    public func follow(_ link: GlossLink) async -> RouteOutcome {
        let outcome = await router.route(link)
        switch outcome {
        case .routed(.document(let id)):
            try? await workspace.openDocument(id)
            workspace.layout = workspace.layout.showsReader ? workspace.layout : .split
        case .routed(.page(let pageID, _)):
            try? await workspace.openPage(pageID)
            workspace.layout = workspace.layout.showsNotes ? workspace.layout : .split
        case .routed(.passage(let targetID, _)):
            try? await workspace.openPassage(targetID)
            workspace.layout = workspace.layout.showsReader ? workspace.layout : .split
        case .inTrash, .missing:
            break
        }
        return outcome
    }
}

/// A feed that never reports changes (when the store has no journal).
struct NoChanges: ChangeFeed {
    let origin = "none"
    func latestChangeSequence() async throws -> Int64 { 0 }
    func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord] { [] }
    func trimChanges(before date: Date) async throws {}
}
