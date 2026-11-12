import Foundation

/// Turns what the user dropped or named (files and folders) into the files to import.
/// Folders are searched recursively for supported extensions, depth first, sorted per folder.
public enum ImportCandidates {
    public static func expand(_ url: URL, supportedExtensions: [String]) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [url]
        }
        let extensions = Set(supportedExtensions.map { $0.lowercased() })
        var result: [URL] = []
        var queue = [url]
        while let directory = queue.popLast() {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let childIsDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if childIsDirectory { queue.append(item) }
                else if extensions.contains(item.pathExtension.lowercased()) { result.append(item) }
            }
        }
        return result
    }

    public static func expand(_ urls: [URL], supportedExtensions: [String]) -> [URL] {
        urls.flatMap { expand($0, supportedExtensions: supportedExtensions) }
    }
}
