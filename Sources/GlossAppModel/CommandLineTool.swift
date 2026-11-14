import Foundation

/// The two questions the "install command line tool" menu item asks of the file system, and
/// nothing more: what a symlink points at, and whether anything sits at a path.
public protocol LinkFileSystem: Sendable {
    /// Where the symlink at `path` points (as written), or nil when `path` isn't a symlink.
    func linkDestination(atPath path: String) -> String?
    /// Whether anything is at `path`, a broken symlink included (does not follow links).
    func exists(atPath path: String) -> Bool
}

/// The real file system.
public struct DiskLinkFileSystem: LinkFileSystem {
    public init() {}

    public func linkDestination(atPath path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    public func exists(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
}

/// The "install command line tool" app-menu item's portable half: given where the app's
/// helper is and what sits at `/usr/local/bin/gloss`, which state the link is in and what the
/// menu item does. The Mac layer builds the item, runs the (maybe privileged) commands and shows
/// the alerts.
public struct CommandLineTool: Sendable {
    public static let defaultLinkPath = "/usr/local/bin/gloss"
    /// Every gloss helper ends like this; it is how "ours, from some other location" is told
    /// apart from "someone else's".
    static let helperSuffix = "/Contents/Helpers/gloss"

    public enum State: Equatable, Sendable {
        /// The running app has no helper to link to (a dev build, `swift run`).
        case unavailable
        case notInstalled
        /// The link points at this app's helper.
        case installed
        /// A link to something else; the target as written.
        case linkedElsewhere(String)
        /// Not a link at all: a regular file or directory.
        case blockedByOtherFile
    }

    public enum Action: Equatable, Sendable {
        case install(helper: String, link: String, replacingLink: Bool)
        case remove(link: String)
        /// Leave everything alone and say why (lowercase, ready for an alert).
        case refuse(String)
        /// The menu item is disabled.
        case none
    }

    /// The helper inside the running bundle; nil when the bundle has none.
    public let helperPath: String?
    public let linkPath: String
    private let files: any LinkFileSystem

    public init(helperPath: String?, linkPath: String = CommandLineTool.defaultLinkPath,
                files: any LinkFileSystem = DiskLinkFileSystem()) {
        self.helperPath = helperPath
        self.linkPath = linkPath
        self.files = files
    }

    public var state: State {
        guard let helperPath else { return .unavailable }
        guard let destination = files.linkDestination(atPath: linkPath) else {
            return files.exists(atPath: linkPath) ? .blockedByOtherFile : .notInstalled
        }
        return resolved(destination) == Self.normalized(helperPath) ? .installed : .linkedElsewhere(destination)
    }

    /// A stale link from another gloss.app location is ours to replace; anything else is not.
    public var isReplaceable: Bool {
        switch state {
        case .notInstalled, .installed: true
        case .linkedElsewhere(let target): resolved(target).hasSuffix(Self.helperSuffix)
        case .unavailable, .blockedByOtherFile: false
        }
    }

    public var action: Action {
        guard let helperPath else { return .none }
        switch state {
        case .unavailable: return .none
        case .installed: return .remove(link: linkPath)
        case .notInstalled: return .install(helper: helperPath, link: linkPath, replacingLink: false)
        case .linkedElsewhere where isReplaceable:
            return .install(helper: helperPath, link: linkPath, replacingLink: true)
        case .linkedElsewhere, .blockedByOtherFile:
            return .refuse("\(linkPath) is something else, so nothing was changed.")
        }
    }

    public var menuTitle: String {
        state == .installed ? "remove command line tool" : "install command line tool"
    }

    public var isEnabled: Bool { state != .unavailable }

    /// Link destinations may be relative to the link's directory.
    private func resolved(_ destination: String) -> String {
        guard !destination.hasPrefix("/") else { return Self.normalized(destination) }
        let directory = (linkPath as NSString).deletingLastPathComponent
        return Self.normalized(directory + "/" + destination)
    }

    private static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

extension CommandLineTool.Action {
    /// The shell script that performs the action with the user's privileges or an admin's.
    /// Every path is single-quoted. Nil for `refuse` and `none`.
    public var shellScript: String? {
        switch self {
        case .install(let helper, let link, let replacing):
            let directory = (link as NSString).deletingLastPathComponent
            let flags = replacing ? "-sfn" : "-sn"
            return "/bin/mkdir -p \(Self.quoted(directory)) && /bin/ln \(flags) \(Self.quoted(helper)) \(Self.quoted(link))"
        case .remove(let link):
            return "/bin/rm \(Self.quoted(link))"
        case .refuse, .none:
            return nil
        }
    }

    /// An AppleScript that runs `shellScript` behind the system admin password prompt.
    public var administratorAppleScript: String? {
        shellScript.map { "do shell script \(Self.appleScriptLiteral($0)) with administrator privileges" }
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
