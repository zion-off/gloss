/// Errors the core services raise. Messages are lowercase, user-presentable copy.
public enum GlossError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case inTrash(String)
    case notAllowed(String)
    case unsupportedFormat(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound(let what): "couldn't find \(what)"
        case .inTrash(let what): "\(what) is in the trash"
        case .notAllowed(let why): why
        case .unsupportedFormat(let name): "gloss can't read \(name) yet — epub and pdf only for now"
        case .invalid(let why): why
        }
    }
}
