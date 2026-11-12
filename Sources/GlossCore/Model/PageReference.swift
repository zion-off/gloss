/// Something a page links to. Derived from the page body on every save.
public enum ReferenceTarget: Hashable, Codable, Sendable {
    case passage(LinkTargetID)
    case page(PageID)
    case document(DocumentID)
}

/// "page P links to T". Rebuildable from page bodies at any time.
public struct PageReference: Hashable, Codable, Sendable {
    public var pageID: PageID
    public var target: ReferenceTarget

    public init(pageID: PageID, target: ReferenceTarget) {
        self.pageID = pageID
        self.target = target
    }
}
