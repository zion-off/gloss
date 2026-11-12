import Foundation
import GlossCore

/// What a `gloss://` link should make the app do.
public enum GlossRoute: Hashable, Sendable {
    case document(DocumentID)
    case page(PageID, DocumentID)
    case passage(LinkTargetID, DocumentID)
}

/// What happened when routing a link.
public enum RouteOutcome: Hashable, Sendable {
    case routed(GlossRoute)
    /// The destination exists but sits in the trash (title included for the message).
    case inTrash(String)
    case missing

    public var routed: GlossRoute? { if case .routed(let route) = self { route } else { nil } }
}

/// Turns `gloss://` links (from notes, `gloss open`, or other apps) into routes.
public struct URLRouter: Sendable {
    let links: LinkService

    public init(links: LinkService) {
        self.links = links
    }

    public func route(_ link: GlossLink) async -> RouteOutcome {
        switch try? await links.resolve(link) {
        case .document(let document): return .routed(.document(document.id))
        case .passage(let target, let document): return .routed(.passage(target.id, document.id))
        case .page(let page, let document): return .routed(.page(page.id, document.id))
        case .inTrash(let title, _): return .inTrash(title)
        default: return .missing
        }
    }

    public func route(url: URL) async -> RouteOutcome {
        guard let link = GlossLink(url) else { return .missing }
        return await route(link)
    }
}
