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
    /// The destination's row couldn't be read (a busy or broken store) — not the same as gone.
    case unreadable

    public var routed: GlossRoute? { if case .routed(let route) = self { route } else { nil } }

    /// What to tell someone whose link couldn't be followed; nil when it was.
    public var problem: RouteProblem? {
        switch self {
        case .routed:
            return nil
        case .inTrash(let title):
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return RouteProblem(title: "“\(name.isEmpty ? PageService.untitled : name)” is in the trash",
                                detail: "restore it from the trash to follow this link.")
        case .missing:
            return RouteProblem(title: "this link leads nowhere", detail: "what it pointed to has been deleted for good.")
        case .unreadable:
            return RouteProblem(title: "couldn't read the library just now",
                                detail: "the link isn't broken — try following it again in a moment.")
        }
    }
}

/// The message for a link that led nowhere (lowercase and short, like the rest of gloss).
public struct RouteProblem: Hashable, Sendable {
    public var title: String
    public var detail: String
}

/// Turns `gloss://` links (from notes, `gloss open`, or other apps) into routes.
public struct URLRouter: Sendable {
    let links: LinkService

    public init(links: LinkService) {
        self.links = links
    }

    public func route(_ link: GlossLink) async -> RouteOutcome {
        do {
            switch try await links.resolve(link) {
            case .document(let document): return .routed(.document(document.id))
            case .passage(let target, let document): return .routed(.passage(target.id, document.id))
            case .page(let page, let document): return .routed(.page(page.id, document.id))
            case .inTrash(let title, _): return .inTrash(title)
            case .missing: return .missing
            }
        } catch {
            // A failed read is not a dead link: the store was busy or broken, and
            // "deleted for good" would be a lie the user might act on.
            return .unreadable
        }
    }

    public func route(url: URL) async -> RouteOutcome {
        guard let link = GlossLink(url) else { return .missing }
        return await route(link)
    }
}
