import Foundation

/// Where the library lives.
///
/// - macOS: `~/Library/Application Support/gloss/library.sqlite`
/// - Linux: `$XDG_DATA_HOME/gloss/library.sqlite` (default `~/.local/share`)
/// - anywhere: the `GLOSS_LIBRARY` environment variable or an explicit path wins.
public enum LibraryLocation {
    public static let fileName = "library.sqlite"

    public static func resolve(explicit: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit, !explicit.isEmpty { return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath) }
        if let fromEnv = environment["GLOSS_LIBRARY"], !fromEnv.isEmpty {
            return URL(fileURLWithPath: (fromEnv as NSString).expandingTildeInPath)
        }
        return defaultDirectory(environment: environment).appendingPathComponent(fileName)
    }

    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/gloss", isDirectory: true)
        #else
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("gloss", isDirectory: true)
        }
        return home.appendingPathComponent(".local/share/gloss", isDirectory: true)
        #endif
    }
}
