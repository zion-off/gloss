import Foundation
import GlossCore

/// One transaction over `MemoryState`. A single class plays every repository role; the
/// typed IDs keep the overloads apart.
final class MemoryTransaction: WriteTransaction {
    var state: MemoryState
    private let origin: String
    private let now: Date

    init(state: MemoryState, origin: String, now: Date) {
        self.state = state
        self.origin = origin
        self.now = now
    }

    private func journal(_ entity: String, _ id: CustomStringConvertible) {
        let sequence = (state.changes.last?.sequence ?? 0) + 1
        state.changes.append(ChangeRecord(sequence: sequence, entity: entity, entityID: id.description, origin: origin, date: now))
    }

    var documents: any DocumentRepository { self }
    var pages: any PageRepository { self }
    var highlights: any HighlightRepository { self }
    var linkTargets: any LinkTargetRepository { self }
    var references: any ReferenceRepository { self }
    var trash: any TrashRepository { self }
    var settings: any SettingsRepository { self }
    var readingPositions: any ReadingPositionRepository { self }
    var fullText: any FullTextIndexing { self }
    var covers: any CoverRepository { self }
    var tombstones: any TombstoneRecording { self }
}

extension MemoryTransaction: DocumentRepository {
    func document(_ id: DocumentID) throws -> Document? { state.documents[id] }

    func documents(_ filter: TrashFilter) throws -> [Document] {
        state.documents.values.filter { filter.admits($0.trash) }.sorted { $0.id < $1.id }
    }

    func documents(withContentHash hash: ContentHash) throws -> [Document] {
        state.documents.values.filter { $0.contentHash == hash }.sorted { $0.id < $1.id }
    }

    func documents(inTrashEntry entryID: TrashEntryID) throws -> [Document] {
        state.documents.values.filter { $0.trash?.entryID == entryID }.sorted { $0.id < $1.id }
    }

    func referencedBlobHashes() throws -> Set<ContentHash> {
        Set(state.documents.values.flatMap { [$0.contentHash] + ($0.coverHash.map { [$0] } ?? []) })
    }

    func insert(_ document: Document) throws {
        guard state.documents[document.id] == nil else { throw StoreError.conflict("document \(document.id)") }
        state.documents[document.id] = document
        journal(ChangeEntity.document, document.id)
    }

    func update(_ document: Document) throws {
        guard state.documents[document.id] != nil else { throw StoreError.notFound("document \(document.id)") }
        state.documents[document.id] = document
        journal(ChangeEntity.document, document.id)
    }

    func delete(_ id: DocumentID) throws {
        state.documents[id] = nil
        state.positions[id] = nil
        state.covers[id] = nil
        journal(ChangeEntity.document, id)
    }
}

extension MemoryTransaction: PageRepository {
    private func sorted(_ pages: some Sequence<Page>) -> [Page] {
        pages.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    func page(_ id: PageID) throws -> Page? { state.pages[id] }

    func rootPage(of documentID: DocumentID) throws -> Page? {
        state.pages.values.first { $0.documentID == documentID && $0.parentID == nil }
    }

    func pages(in documentID: DocumentID, _ filter: TrashFilter) throws -> [Page] {
        sorted(state.pages.values.filter { $0.documentID == documentID && filter.admits($0.trash) })
    }

    func children(of pageID: PageID, _ filter: TrashFilter) throws -> [Page] {
        sorted(state.pages.values.filter { $0.parentID == pageID && filter.admits($0.trash) })
    }

    func pages(_ filter: TrashFilter) throws -> [Page] {
        sorted(state.pages.values.filter { filter.admits($0.trash) })
    }

    func pages(inTrashEntry entryID: TrashEntryID) throws -> [Page] {
        sorted(state.pages.values.filter { $0.trash?.entryID == entryID })
    }

    func insert(_ page: Page) throws {
        guard state.pages[page.id] == nil else { throw StoreError.conflict("page \(page.id)") }
        guard state.documents[page.documentID] != nil else { throw StoreError.notFound("document \(page.documentID)") }
        state.pages[page.id] = page
        journal(ChangeEntity.page, page.id)
    }

    func update(_ page: Page) throws {
        guard state.pages[page.id] != nil else { throw StoreError.notFound("page \(page.id)") }
        state.pages[page.id] = page
        journal(ChangeEntity.page, page.id)
    }

    func delete(_ id: PageID) throws {
        state.pages[id] = nil
        state.references[id] = nil
        journal(ChangeEntity.page, id)
    }
}

extension MemoryTransaction: HighlightRepository {
    func highlight(_ id: HighlightID) throws -> Highlight? { state.highlights[id] }

    func highlights(in documentID: DocumentID) throws -> [Highlight] {
        state.highlights.values.filter { $0.documentID == documentID }
            .sorted { ($0.passage.progression ?? 0, $0.createdAt, $0.id) < ($1.passage.progression ?? 0, $1.createdAt, $1.id) }
    }

    func insert(_ highlight: Highlight) throws {
        guard state.documents[highlight.documentID] != nil else { throw StoreError.notFound("document \(highlight.documentID)") }
        state.highlights[highlight.id] = highlight
        journal(ChangeEntity.highlight, highlight.id)
    }

    func update(_ highlight: Highlight) throws {
        guard state.highlights[highlight.id] != nil else { throw StoreError.notFound("highlight \(highlight.id)") }
        state.highlights[highlight.id] = highlight
        journal(ChangeEntity.highlight, highlight.id)
    }

    func delete(_ id: HighlightID) throws {
        state.highlights[id] = nil
        journal(ChangeEntity.highlight, id)
    }
}

extension MemoryTransaction: LinkTargetRepository {
    func linkTarget(_ id: LinkTargetID) throws -> LinkTarget? { state.linkTargets[id] }

    func linkTargets(in documentID: DocumentID) throws -> [LinkTarget] {
        state.linkTargets.values.filter { $0.documentID == documentID }
            .sorted { ($0.passage.progression ?? 0, $0.id) < ($1.passage.progression ?? 0, $1.id) }
    }

    func linkTarget(in documentID: DocumentID, at locator: Locator) throws -> LinkTarget? {
        state.linkTargets.values.first { $0.documentID == documentID && $0.passage.locator == locator }
    }

    func orphanedLinkTargets(since cutoff: Date) throws -> [LinkTarget] {
        state.linkTargets.values.filter { ($0.orphanedSince.map { $0 <= cutoff }) ?? false }.sorted { $0.id < $1.id }
    }

    func insert(_ target: LinkTarget) throws {
        guard state.documents[target.documentID] != nil else { throw StoreError.notFound("document \(target.documentID)") }
        state.linkTargets[target.id] = target
        journal(ChangeEntity.linkTarget, target.id)
    }

    func update(_ target: LinkTarget) throws {
        guard state.linkTargets[target.id] != nil else { throw StoreError.notFound("link target \(target.id)") }
        state.linkTargets[target.id] = target
        journal(ChangeEntity.linkTarget, target.id)
    }

    func delete(_ id: LinkTargetID) throws {
        state.linkTargets[id] = nil
        journal(ChangeEntity.linkTarget, id)
    }
}

extension MemoryTransaction: ReferenceRepository {
    func references(from pageID: PageID) throws -> Set<ReferenceTarget> { state.references[pageID] ?? [] }

    func referringPages(to target: ReferenceTarget) throws -> [PageID] {
        state.references.filter { $0.value.contains(target) }.map(\.key).sorted()
    }

    func setReferences(_ targets: Set<ReferenceTarget>, from pageID: PageID) throws {
        state.references[pageID] = targets.isEmpty ? nil : targets
    }

    func removeAllReferences() throws { state.references.removeAll() }
}

extension MemoryTransaction: TrashRepository {
    func trashEntries() throws -> [TrashEntry] {
        state.trash.values.sorted { ($0.trashedAt, $0.id) > ($1.trashedAt, $1.id) }
    }

    func trashEntry(_ id: TrashEntryID) throws -> TrashEntry? { state.trash[id] }

    func insert(_ entry: TrashEntry) throws {
        state.trash[entry.id] = entry
        journal(ChangeEntity.trash, entry.id)
    }

    func delete(_ id: TrashEntryID) throws {
        state.trash[id] = nil
        journal(ChangeEntity.trash, id)
    }
}

extension MemoryTransaction: SettingsRepository {
    func rawSetting(_ key: String) throws -> Data? { state.settings[key] }

    func setRawSetting(_ value: Data?, for key: String, at date: Date) throws {
        state.settings[key] = value
        journal(ChangeEntity.setting, key)
    }
}

extension MemoryTransaction: ReadingPositionRepository {
    func readingPosition(of documentID: DocumentID) throws -> ReadingPosition? { state.positions[documentID] }

    func save(_ position: ReadingPosition) throws {
        state.positions[position.documentID] = position
        journal(ChangeEntity.readingPosition, position.documentID)
    }

    func deleteReadingPosition(of documentID: DocumentID) throws {
        state.positions[documentID] = nil
    }
}

extension MemoryTransaction: CoverRepository {
    func derivedCover(of documentID: DocumentID) throws -> CoverImage? { state.covers[documentID] }

    func setDerivedCover(_ cover: CoverImage?, of documentID: DocumentID) throws {
        state.covers[documentID] = cover
    }
}

extension MemoryTransaction: TombstoneRecording {
    func recordDeletion(entity: String, id: String, at date: Date) throws {
        state.tombstones.append((entity, id, date))
    }
}

extension MemoryTransaction: FullTextIndexing {
    func search(_ query: FullTextQuery) throws -> [FullTextHit] {
        let matcher = TextMatcher(query: query.text)
        guard !matcher.isEmpty else { return [] }
        let candidates = state.fullText.values.joined().filter {
            $0.corpus == query.corpus && (query.documentID == nil || $0.documentID == query.documentID)
        }
        let hits: [FullTextHit] = candidates.compactMap { entry in
            let haystack = entry.title + "\n" + entry.body
            guard matcher.matches(haystack) else { return nil }
            let snippetSource = matcher.score(entry.body) > 0 ? entry.body : entry.title
            return FullTextHit(corpus: entry.corpus, owner: entry.owner, documentID: entry.documentID,
                               locator: entry.locator, label: entry.label, title: entry.title,
                               snippet: matcher.snippet(of: snippetSource), rank: -Double(matcher.score(haystack)))
        }
        let ranked = hits.sorted { ($0.rank, $0.owner) < ($1.rank, $1.owner) }
        return query.limit.map { Array(ranked.prefix($0)) } ?? ranked
    }

    func entries(corpus: Corpus, documentID: DocumentID) throws -> [FullTextEntry] {
        // Owners in a stable order; each owner's chunks as they were indexed.
        state.fullText.sorted { $0.key < $1.key }.flatMap(\.value)
            .filter { $0.corpus == corpus && $0.documentID == documentID }
    }

    func replaceEntries(_ entries: [FullTextEntry], corpus: Corpus, owner: String) throws {
        state.fullText[MemoryState.ftsKey(corpus, owner)] = entries.isEmpty ? nil : entries
    }

    func removeEntries(corpus: Corpus, owner: String) throws {
        state.fullText[MemoryState.ftsKey(corpus, owner)] = nil
    }

    func removeEntries(corpus: Corpus, documentID: DocumentID) throws {
        for (key, entries) in state.fullText where entries.first?.corpus == corpus {
            let kept = entries.filter { $0.documentID != documentID }
            state.fullText[key] = kept.isEmpty ? nil : kept
        }
    }

    func removeAllEntries(corpus: Corpus) throws {
        for (key, entries) in state.fullText where entries.first?.corpus == corpus {
            state.fullText[key] = nil
        }
    }
}
