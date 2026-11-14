import Foundation
import GlossCore
import GlossEPUB

/// Drives foliate-js through the JSON bridge. Commands become `ReaderCommand`s for `send`
/// (the WKWebView adapter calls `glossReader.receive`); events come back through `translate`.
@MainActor
public final class EPUBBridgeDriver: ReaderDriving, ReflowableAppearanceApplying, SearchHighlighting {
    private let send: @MainActor (ReaderCommand) async throws -> Void
    public private(set) var appearance: ReaderAppearance
    /// Called after each live appearance change, so the host can match native backgrounds.
    public var appearanceDidChange: (@MainActor (ReaderAppearance) -> Void)?

    public init(appearance: ReaderAppearance, send: @escaping @MainActor (ReaderCommand) async throws -> Void) {
        self.appearance = appearance
        self.send = send
    }

    public func open(_ document: Document, at position: Locator?, openID: Int) async throws {
        let cfi = position.flatMap { $0.scheme == EPUBLocators.cfiScheme ? $0.value : nil }
        try await send(.open(ReaderOpenPayload(openID: openID, url: ReaderResourceRouter.bookURL(document.id).absoluteString,
                                               position: cfi, appearance: appearance)))
    }

    public func close() async throws {
        try await send(.close)
    }

    public func go(to locator: Locator, flash: Bool) async throws {
        let target: ReaderTarget
        switch locator.scheme {
        case EPUBLocators.cfiScheme: target = .cfi(locator.value)
        case EPUBLocators.hrefScheme: target = .href(locator.value)
        case EPUBLocators.quoteScheme:
            guard let quote = Self.quoteTarget(locator) else { throw ReaderDrivingError.unsupportedLocator(locator.scheme) }
            target = .quote(quote)
        default: throw ReaderDrivingError.unsupportedLocator(locator.scheme)
        }
        try await send(.goTo(ReaderGoToPayload(target: target, flash: flash)))
    }

    public func turnPage(forward: Bool) async throws {
        try await send(.turnPage(ReaderTurnPagePayload(direction: forward ? .forward : .backward)))
    }

    public func show(_ annotations: ReaderAnnotations) async throws {
        try await send(.setAnnotations(ReaderSetAnnotationsPayload(
            highlights: annotations.highlights.compactMap { mark in
                mark.locator.scheme == EPUBLocators.cfiScheme
                    ? ReaderHighlightAnnotation(id: mark.id.stringValue, cfi: mark.locator.value, color: ReaderColorName(mark.color)) : nil
            },
            markers: annotations.markers.compactMap { mark in
                if mark.locator.scheme == EPUBLocators.cfiScheme { return ReaderMarkerAnnotation(id: mark.id.stringValue, cfi: mark.locator.value) }
                return Self.quoteTarget(mark.locator).map { ReaderMarkerAnnotation(id: mark.id.stringValue, quote: $0) }
            })))
    }

    /// The bridge's shape of an `epub-quote` locator; nil for anything else.
    nonisolated static func quoteTarget(_ locator: Locator) -> ReaderQuoteTarget? {
        guard let quote = EPUBQuoteLocator(locator: locator) else { return nil }
        return ReaderQuoteTarget(section: quote.section, text: quote.quote.text, prefix: quote.quote.prefix,
                                 suffix: quote.quote.suffix, occurrence: quote.quote.occurrence)
    }

    public func clearSelection() async throws {
        try await send(.clearSelection)
    }

    public func reveal(searchHit locator: Locator?, text: String) async throws {
        var payload = ReaderRevealSearchHitPayload(text: text)
        switch locator?.scheme {
        case EPUBLocators.cfiScheme?: payload.cfi = locator?.value
        case EPUBLocators.sectionScheme?: payload.section = locator.flatMap { Int($0.value) }
        default: break
        }
        try await send(.revealSearchHit(payload))
    }

    public func setSearchHighlights(_ query: String?) async throws {
        try await send(.setSearchHighlights(ReaderSearchHighlightsPayload(query: query)))
    }

    public func apply(_ appearance: ReaderAppearance) async throws {
        self.appearance = appearance
        appearanceDidChange?(appearance)
        try await send(.setAppearance(ReaderSetAppearancePayload(appearance: appearance)))
    }

    /// Decodes and translates a `gloss` script message: glue.js posts each event as JSON text,
    /// so no value goes through WebKit's object bridging. `nil` for events the controller
    /// doesn't take (search batches).
    public nonisolated static func engineEvent(fromMessageBody body: Any) throws -> ReaderEngineEvent? {
        guard let text = body as? String else {
            throw ReaderBridgeError.malformed("expected the event as JSON text, got \(type(of: body))")
        }
        return translate(try ReaderEvent.decode(fromJSON: Data(text.utf8)))
    }

    /// Translates a bridge event. Search batches are handled by the find bar, not the controller.
    public nonisolated static func translate(_ event: ReaderEvent) -> ReaderEngineEvent? {
        switch event {
        case .ready:
            return .ready
        case .opened(let payload):
            return .opened(toc: payload.toc.map(tocEntry), openID: payload.openID)
        case .relocated(let payload):
            return .relocated(ReaderLocation(
                locator: Locator(scheme: EPUBLocators.cfiScheme, value: payload.cfi), progression: payload.fraction,
                label: ReaderEventMapping.progressLabel(of: payload), progressText: ReaderProgressText.describe(payload),
                atStart: payload.atStart, atEnd: payload.atEnd, pagesLeftInSection: payload.pagesLeftInSection,
                contentsTarget: payload.tocHref.map { Locator(scheme: EPUBLocators.hrefScheme, value: $0) }))
        case .selectionChanged(let payload):
            return .selectionChanged(ReaderEventMapping.passage(from: payload), anchor: payload.rect)
        case .selectionCleared:
            return .selectionCleared
        case .annotationActivated(let payload):
            return .annotationActivated(highlights: payload.highlightIDs.compactMap(HighlightID.init),
                                        markers: payload.markerIDs.compactMap(LinkTargetID.init), anchor: payload.rect)
        case .linkActivated(let payload):
            return URL(string: payload.href).map(ReaderEngineEvent.externalLink)
        case .searchResults:
            return nil
        case .error(let payload):
            if let openID = payload.openID { return .openFailed(payload.message, openID: openID) }
            return .failed(payload.context.map { "\($0): \(payload.message)" } ?? payload.message)
        }
    }

    nonisolated static func tocEntry(_ item: ReaderTocItem) -> ReaderTocEntry {
        ReaderTocEntry(label: item.label, target: Locator(scheme: EPUBLocators.hrefScheme, value: item.href),
                       children: item.children.map(tocEntry))
    }
}
