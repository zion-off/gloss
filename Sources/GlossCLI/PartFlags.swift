import ArgumentParser
import Foundation

/// The per-format flags of `gloss link`, `gloss text` and `gloss highlights` (`--section 5` for
/// epubs, `--page 5` for pdfs).
///
/// ArgumentParser's options are fixed at compile time, but which words name a part of a book
/// belongs to the formats (`QuoteLocating.partName`). So the commands declare one
/// `--part` option and the names the formats supply are rewritten into it before parsing:
/// `--section 5` becomes `--part section:5`. Only arguments after one of those subcommands change.
enum PartFlags {
    static let commands: Set<String> = ["link", "text", "highlights"]

    static func rewrite(_ arguments: [String], names: [String]) -> [String] {
        guard !names.isEmpty, let command = arguments.firstIndex(where: { !$0.hasPrefix("-") }),
              commands.contains(arguments[command]) else { return arguments }
        var result = Array(arguments[...command])
        var index = command + 1
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

        /// The transform for a `--part` option.
        static func parse(_ text: String) throws -> Selection {
            guard let selection = Selection(text) else {
                let flag = text.firstIndex(of: ":").map { "--" + text[..<$0] } ?? "--part"
                throw ValidationError("\(flag) needs a number, like 3")
            }
            return selection
        }
    }

    /// Fails when the part was named with another format's word (`--page` for an epub).
    static func check(_ selection: Selection?, against partName: String) throws {
        guard let selection, let used = selection.noun, used != partName else { return }
        throw CLIFailure("this book has \(partName)s, not \(used)s", hint: "use --\(partName) \(selection.number)", code: CLIFailure.usageCode)
    }
}
