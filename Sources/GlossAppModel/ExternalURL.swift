import Foundation
import GlossCore

/// What a URL handed to gloss from outside is: a `gloss://` link, a book file Finder or
/// LaunchServices asks us to open, or something gloss has nothing to do with.
public enum IncomingURL: Equatable, Sendable {
    case gloss(GlossLink)
    case supportedFile(URL)
    case other(URL)

    public var url: URL {
        switch self {
        case .gloss(let link): link.url
        case .supportedFile(let url), .other(let url): url
        }
    }
}

/// What happened when an URL from outside opened.
public enum ExternalOpenOutcome: Equatable, Sendable {
    case routed(GlossRoute)
    case inTrash(String)
    case missing
    /// A book file: freshly imported, or already in the library and opened as-is.
    case opened(Document)
    /// Gloss understood it and declined, with the reason.
    case refused(String)
}

/// The alert copy for an incoming link gloss couldn't open. Trashed and missing say what
/// `RouteOutcome.problem` says, so a dead link reads the same however it arrives.
public enum UnopenableLinkCopy {
    public static func message(for outcome: ExternalOpenOutcome) -> String? {
        switch outcome {
        case .routed, .opened:
            nil
        case .inTrash(let title):
            line(RouteOutcome.inTrash(title).problem)
        case .missing:
            line(RouteOutcome.missing.problem)
        case .refused(let why):
            why
        }
    }

    private static func line(_ problem: RouteProblem?) -> String? {
        problem.map { $0.title + " — " + $0.detail }
    }
}

/// Sorts incoming URLs by what gloss can do with them, using the registered formats'
/// extensions — the same list import and the cli use, so the app, the cli and Finder agree.
public enum IncomingURLClassifier: Sendable {
    public static func classify(_ url: URL, supportedExtensions: [String]) -> IncomingURL {
        if let link = GlossLink(url) { return .gloss(link) }
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty, supportedExtensions.contains(ext) { return .supportedFile(url) }
        }
        return .other(url)
    }
}
