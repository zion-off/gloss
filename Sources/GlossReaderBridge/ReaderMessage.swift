import Foundation

public enum ReaderBridgeError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case unknownType(String)
    case malformed(String)
}

/// The bridge protocol version, checked on both sides.
public enum ReaderBridge {
    public static let protocolVersion = 1
}

/// Every command the app can send to the reader.
public enum ReaderCommand: Equatable, Sendable {
    case open(ReaderOpenPayload)
    /// Closes the open book (it was trashed); the reader shows nothing until the next `open`.
    case close
    case goTo(ReaderGoToPayload)
    case turnPage(ReaderTurnPagePayload)
    case setAppearance(ReaderSetAppearancePayload)
    case setAnnotations(ReaderSetAnnotationsPayload)
    case clearSelection
    case search(ReaderSearchPayload)
    case clearSearch
    case revealSearchHit(ReaderRevealSearchHitPayload)
    case setSearchHighlights(ReaderSearchHighlightsPayload)

    public static let typeNames = [
        "open", "close", "goTo", "turnPage", "setAppearance", "setAnnotations", "clearSelection", "search", "clearSearch", "revealSearchHit", "setSearchHighlights",
    ]
}

/// Every event the reader can send back.
public enum ReaderEvent: Equatable, Sendable {
    case ready
    case opened(ReaderOpenedPayload)
    case relocated(ReaderRelocatedPayload)
    case selectionChanged(ReaderSelectionChangedPayload)
    case selectionCleared
    case annotationActivated(ReaderAnnotationActivatedPayload)
    case linkActivated(ReaderLinkActivatedPayload)
    case searchResults(ReaderSearchResultsPayload)
    case error(ReaderErrorPayload)

    public static let typeNames = [
        "ready", "opened", "relocated", "selectionChanged", "selectionCleared", "annotationActivated", "linkActivated",
        "searchResults", "error",
    ]
}

// MARK: Coding

extension ReaderCommand: Codable {
    private enum CodingKeys: String, CodingKey { case v, type, payload }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == ReaderBridge.protocolVersion else {
            throw ReaderBridgeError.unsupportedVersion(version)
        }
        let type = try container.decode(String.self, forKey: .type)
        func payload<P: Codable>(_ type: P.Type) throws -> P { try container.decode(P.self, forKey: .payload) }
        switch type {
        case "open": self = .open(try payload(ReaderOpenPayload.self))
        case "close":
            self = .close
            _ = try container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .payload)
        case "goTo": self = .goTo(try payload(ReaderGoToPayload.self))
        case "turnPage": self = .turnPage(try payload(ReaderTurnPagePayload.self))
        case "setAppearance": self = .setAppearance(try payload(ReaderSetAppearancePayload.self))
        case "setAnnotations": self = .setAnnotations(try payload(ReaderSetAnnotationsPayload.self))
        case "clearSelection":
            self = .clearSelection
            _ = try container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .payload)
        case "search": self = .search(try payload(ReaderSearchPayload.self))
        case "clearSearch":
            self = .clearSearch
            _ = try container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .payload)
        case "revealSearchHit": self = .revealSearchHit(try payload(ReaderRevealSearchHitPayload.self))
        case "setSearchHighlights": self = .setSearchHighlights(try payload(ReaderSearchHighlightsPayload.self))
        default: throw ReaderBridgeError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ReaderBridge.protocolVersion, forKey: .v)
        switch self {
        case .open(let payload):
            try container.encode("open", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .close:
            try container.encode("close", forKey: .type)
            try container.encode([String: String](), forKey: .payload)
        case .goTo(let payload):
            try container.encode("goTo", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .turnPage(let payload):
            try container.encode("turnPage", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setAppearance(let payload):
            try container.encode("setAppearance", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setAnnotations(let payload):
            try container.encode("setAnnotations", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .clearSelection:
            try container.encode("clearSelection", forKey: .type)
            try container.encode([String: String](), forKey: .payload)
        case .search(let payload):
            try container.encode("search", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .clearSearch:
            try container.encode("clearSearch", forKey: .type)
            try container.encode([String: String](), forKey: .payload)
        case .revealSearchHit(let payload):
            try container.encode("revealSearchHit", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setSearchHighlights(let payload):
            try container.encode("setSearchHighlights", forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }

    private enum EmptyKeys: String, CodingKey { case none }
}

extension ReaderEvent: Codable {
    private enum CodingKeys: String, CodingKey { case v, type, payload }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == ReaderBridge.protocolVersion else {
            throw ReaderBridgeError.unsupportedVersion(version)
        }
        let type = try container.decode(String.self, forKey: .type)
        func payload<P: Codable>(_ type: P.Type) throws -> P { try container.decode(P.self, forKey: .payload) }
        switch type {
        case "ready":
            self = .ready
            _ = try container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .payload)
        case "opened": self = .opened(try payload(ReaderOpenedPayload.self))
        case "relocated": self = .relocated(try payload(ReaderRelocatedPayload.self))
        case "selectionChanged": self = .selectionChanged(try payload(ReaderSelectionChangedPayload.self))
        case "selectionCleared":
            self = .selectionCleared
            _ = try container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .payload)
        case "annotationActivated": self = .annotationActivated(try payload(ReaderAnnotationActivatedPayload.self))
        case "linkActivated": self = .linkActivated(try payload(ReaderLinkActivatedPayload.self))
        case "searchResults": self = .searchResults(try payload(ReaderSearchResultsPayload.self))
        case "error": self = .error(try payload(ReaderErrorPayload.self))
        default: throw ReaderBridgeError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ReaderBridge.protocolVersion, forKey: .v)
        switch self {
        case .ready:
            try container.encode("ready", forKey: .type)
            try container.encode([String: String](), forKey: .payload)
        case .opened(let payload):
            try container.encode("opened", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .relocated(let payload):
            try container.encode("relocated", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .selectionChanged(let payload):
            try container.encode("selectionChanged", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .selectionCleared:
            try container.encode("selectionCleared", forKey: .type)
            try container.encode([String: String](), forKey: .payload)
        case .annotationActivated(let payload):
            try container.encode("annotationActivated", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .linkActivated(let payload):
            try container.encode("linkActivated", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .searchResults(let payload):
            try container.encode("searchResults", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .error(let payload):
            try container.encode("error", forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }

    private enum EmptyKeys: String, CodingKey { case none }
}

// MARK: Wire helpers

public extension ReaderCommand {
    /// The JSON string to send through `callAsyncJavaScript`.
    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public extension ReaderEvent {
    /// Parses what the web view posts.
    static func decode(fromJSON data: Data) throws -> ReaderEvent {
        try JSONDecoder().decode(ReaderEvent.self, from: data)
    }
}
