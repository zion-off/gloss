import Foundation

/// The per-format flags of `gloss link` (`--section 5` for epubs, `--page 5` for pdfs).
///
/// ArgumentParser's options are fixed at compile time, but which words name a part of a book
/// belongs to the formats (`QuoteLocating.partName`, D-197). So the command declares one
/// `--part` option and the names the formats supply are rewritten into it before parsing:
/// `--section 5` becomes `--part section:5`. Only arguments after the `link` subcommand change.
enum PartFlags {
    static func rewrite(_ arguments: [String], names: [String]) -> [String] {
        guard !names.isEmpty, let link = arguments.firstIndex(of: "link") else { return arguments }
        var result = Array(arguments[...link])
        var index = link + 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                result.append(contentsOf: arguments[(index - 1)...])
                break
            }
            if let name = names.first(where: { argument == "--\($0)" }) {
                result.append("--part")
                if index < arguments.count { result.append("\(name):\(arguments[index])"); index += 1 }
            } else if let name = names.first(where: { argument.hasPrefix("--\($0)=") }) {
                result.append("--part=\(name):\(argument.dropFirst(name.count + 3))")
            } else {
                result.append(argument)
            }
        }
        return result
    }

    /// `3` or `section:3`: which part, and the noun the user used for it (nil for plain `--part`).
    struct Selection: Equatable {
        var noun: String?
        var number: Int

        init?(_ text: String) {
            if let colon = text.firstIndex(of: ":") {
                noun = String(text[..<colon])
                guard let number = Int(text[text.index(after: colon)...]) else { return nil }
                self.number = number
            } else {
                guard let number = Int(text) else { return nil }
                noun = nil
                self.number = number
            }
        }

        /// What to call the flag in messages: `--section`, or `--part`.
        var flag: String { "--\(noun ?? "part")" }
    }
}
