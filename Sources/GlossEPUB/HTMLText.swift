/// Tolerant XHTML/HTML → plain text for search indexing. Content documents often use HTML
/// entities that a strict XML parser rejects, so this is a forgiving scanner, not a parser.
enum HTMLText {
    private static let blockElements: Set<String> = [
        "p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "tr", "section", "article",
        "header", "footer", "aside", "pre", "dt", "dd", "figcaption", "hr", "table", "ul", "ol", "nav",
    ]
    private static let skippedElements: Set<String> = ["head", "script", "style", "svg", "math", "title"]

    static func extract(_ html: String) -> String {
        var out = ""
        var skipping: String?
        var index = html.startIndex
        while index < html.endIndex {
            let char = html[index]
            if char == "<" {
                guard let close = html[index...].firstIndex(of: ">") else { break }
                let tag = html[html.index(after: index)..<close]
                index = html.index(after: close)
                if tag.hasPrefix("!--") {
                    // Comments may contain ">"; skip to "-->".
                    if !tag.hasSuffix("--"), let end = html[index...].range(of: "-->") { index = end.upperBound }
                    continue
                }
                let isClosing = tag.hasPrefix("/")
                let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber || $0 == ":" }
                    .split(separator: ":").last.map { $0.lowercased() } ?? ""
                if let skipped = skipping {
                    if isClosing && name == skipped { skipping = nil }
                    continue
                }
                if skippedElements.contains(name), !isClosing, !tag.hasSuffix("/") { skipping = name; continue }
                if blockElements.contains(name) { out += "\n" }
                if name == "img", let alt = attribute("alt", in: tag), !alt.isEmpty { out += " \(alt) " }
                continue
            }
            if skipping != nil { index = html.index(after: index); continue }
            if char == "&", let semicolon = html[index...].prefix(12).firstIndex(of: ";") {
                let entity = html[html.index(after: index)..<semicolon]
                if let decoded = decode(entity) {
                    out += decoded
                    index = html.index(after: semicolon)
                    continue
                }
            }
            out.append(char)
            index = html.index(after: index)
        }
        return normalize(out)
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let range = tag.range(of: "\(name)=") else { return nil }
        let rest = tag[range.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        return rest.dropFirst().prefix { $0 != quote }.description
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "shy": "", "mdash": "—",
        "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«",
        "raquo": "»", "copy": "©", "reg": "®", "trade": "™", "eacute": "é", "egrave": "è", "ecirc": "ê",
        "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "ouml": "ö", "uuml": "ü", "iuml": "ï",
        "ccedil": "ç", "ntilde": "ñ", "oacute": "ó", "uacute": "ú", "iacute": "í", "szlig": "ß", "aelig": "æ",
        "oelig": "œ", "middot": "·", "bull": "•", "deg": "°", "frac12": "½", "times": "×", "thinsp": " ",
        "ensp": " ", "emsp": " ", "zwnj": "", "zwj": "",
    ]

    private static func decode(_ entity: Substring) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[String(entity)]
    }

    /// Collapses spaces within lines and drops empty lines: one block per line.
    private static func normalize(_ text: String) -> String {
        text.split(separator: "\n").map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\u{A0}" }).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
