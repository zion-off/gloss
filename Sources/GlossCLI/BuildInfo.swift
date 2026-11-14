import Foundation

/// The version `gloss --version` prints: the app's, when this binary lives inside gloss.app
/// (`Contents/Helpers/gloss`, possibly through a symlink on the user's PATH), and "dev" for a
/// binary built from source.
enum BuildInfo {
    static let version: String = bundledVersion() ?? "dev"

    private static func bundledVersion() -> String? {
        guard let executable = Bundle.main.executablePath else { return nil }
        let real = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let contents = real.deletingLastPathComponent().deletingLastPathComponent()
        guard real.deletingLastPathComponent().lastPathComponent == "Helpers",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}
