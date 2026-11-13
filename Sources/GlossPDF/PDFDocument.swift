import Foundation

/// A parsed PDF: every object the scanner could find (later definitions of the same object
/// number win, like incremental updates), plus trailer information.
///
/// The whole file is scanned for `N G obj … endobj` bodies instead of trusting xref offsets,
/// so broken xref tables and incremental updates still work. Trailers (`trailer` dictionaries
/// and xref-stream dictionaries) are only used to locate `/Root`, `/Info` and `/Encrypt`.
struct PDFDocument: Sendable {
    /// One object definition with its file offset.
    struct Entry: Sendable {
        let offset: Int
        let object: PDFObject
    }

    /// A page with its (inherited) resources resolved.
    struct Page: Sendable {
        let dictionary: [String: PDFObject]
        let resources: [String: PDFObject]
    }

    /// Bounds against absurd or malicious files.
    enum Limits {
        static let maxObjects = 500_000
        static let maxObjectNumber = 9_999_999
        static let maxPages = 100_000
        static let maxKidsPerNode = 8_192
        static let maxTreeDepth = 64
        static let maxResolveDepth = 16
    }

    /// Object number → latest definition.
    let objects: [Int: Entry]
    /// The catalog (`/Root`) value from the last usable trailer, if any.
    let root: PDFObject?
    /// The `/Info` value from the last usable trailer, if any.
    let info: PDFObject?
    /// True when any trailer carries `/Encrypt` — strings and streams are unreadable.
    let isEncrypted: Bool

    // MARK: Parsing

    /// Scans the whole file for objects, expands object streams, then picks trailer values.
    static func parse(_ data: Data) -> PDFDocument {
        let bytes = [UInt8](data)
        var objects: [Int: Entry] = [:]

        // Loose objects: a byte scan for `N G obj` headers (bounded, allocation-free), then a
        // full parse of each body. Bodies share one budget, so failed parses that re-read the
        // input can't add up to more than linear time.
        let budget = PDFScanBudget.linear(in: bytes.count)
        let endstream = Array("endstream".utf8)
        var position = 0
        while position < bytes.count, objects.count < Limits.maxObjects, !budget.isExhausted {
            guard let header = matchObjectHeader(bytes, at: position) else {
                position += 1
                continue
            }
            let (n, g, objectOffset, bodyStart) = header
            var lexer = PDFLexer(bytes, at: bodyStart, budget: budget)
            guard var body = PDFObjectParser.parse(&lexer) else {
                position = bodyStart
                continue
            }
            if case .dictionary(let dict) = body {
                let peek = lexer.index
                if case .keyword("stream")? = lexer.nextToken() {
                    var dataStart = lexer.index
                    if dataStart < bytes.count, bytes[dataStart] == 0x0D {
                        dataStart += 1
                        if dataStart < bytes.count, bytes[dataStart] == 0x0A { dataStart += 1 }
                    } else if dataStart < bytes.count, bytes[dataStart] == 0x0A {
                        dataStart += 1
                    }
                    let length: Int?
                    if case .integer(let l)? = dict["Length"] { length = l } else { length = nil }
                    let (raw, end) = streamBytes(bytes, dataStart: dataStart, length: length, endstream: endstream)
                    body = .stream(PDFStream(dictionary: dict, raw: raw))
                    lexer.index = end
                } else {
                    lexer.index = peek
                }
            }
            if n <= Limits.maxObjectNumber, g >= 0 {
                objects[n] = Entry(offset: objectOffset, object: body)
            }
            let save = lexer.index
            if case .keyword("endobj")? = lexer.nextToken() {} else { lexer.index = save }
            position = Swift.max(lexer.index, bodyStart)
        }

        // Objects inside object streams (compressed objects), in file order.
        expandObjectStreams(&objects)

        // Trailers: `trailer` dictionaries and xref-stream dictionaries, last one wins.
        var candidates: [(offset: Int, dict: [String: PDFObject])] = []
        let needle = Array("trailer".utf8)
        var searchFrom = 0
        while let found = PDFBytes.find(needle, in: bytes, from: searchFrom, limit: bytes.count - searchFrom) {
            searchFrom = found + needle.count
            var trailerLexer = PDFLexer(bytes, at: searchFrom, budget: budget)
            let dict = PDFObjectParser.parseDictionary(&trailerLexer)
            if !dict.isEmpty { candidates.append((found, dict)) }
        }
        for entry in objects.values {
            if case .stream(let stream) = entry.object, stream.dictionary["Type"] == .name("XRef") {
                candidates.append((entry.offset, stream.dictionary))
            }
        }
        // Incremental updates append: the trailer latest in the file is the current one.
        candidates.sort { $0.offset < $1.offset }
        var root: PDFObject?
        var info: PDFObject?
        var encrypted = false
        if let lastRoot = candidates.last(where: { $0.dict["Root"] != nil })?.dict["Root"] { root = lastRoot }
        if let lastInfo = candidates.last(where: { $0.dict["Info"] != nil })?.dict["Info"] { info = lastInfo }
        encrypted = candidates.contains { candidate in
            switch candidate.dict["Encrypt"] {
            case .none, .some(.null): return false
            default: return true
            }
        }

        // Files with no usable trailer: find catalog and info by their /Type instead.
        if root == nil {
            let catalog = objects.filter { _, entry in
                if case .dictionary(let dict) = entry.object, dict["Type"] == .name("Catalog") { return true }
                return false
            }.min { $0.value.offset < $1.value.offset }
            root = catalog.map { .reference($0.key, 0) }
        }
        if info == nil {
            let infoEntry = objects.filter { _, entry in
                if case .dictionary(let dict) = entry.object, dict["Type"] == .name("Info") { return true }
                return false
            }.min { $0.value.offset < $1.value.offset }
            info = infoEntry.map { .reference($0.key, 0) }
        }

        return PDFDocument(objects: objects, root: root, info: info, isEncrypted: encrypted)
    }

    /// Extracts stream bytes: `/Length` when it is a direct integer and checks out,
    /// else a scan for `endstream` (handles indirect or wrong lengths).
    private static func streamBytes(
        _ bytes: [UInt8], dataStart inputStart: Int, length: Int?, endstream: [UInt8]
    ) -> (Data, Int) {
        let count = bytes.count
        let dataStart = Swift.min(inputStart, count)
        if let length, length >= 0, dataStart + length <= count,
           PDFBytes.find(endstream, in: bytes, from: dataStart + length, limit: 32) != nil {
            let end = dataStart + length
            return (Data(bytes[dataStart..<end]), end)
        }
        if let found = PDFBytes.find(endstream, in: bytes, from: dataStart, limit: count - dataStart) {
            var rawEnd = found
            if rawEnd > dataStart, bytes[rawEnd - 1] == 0x0A {
                rawEnd -= 1
                if rawEnd > dataStart, bytes[rawEnd - 1] == 0x0D { rawEnd -= 1 }
            } else if rawEnd > dataStart, bytes[rawEnd - 1] == 0x0D {
                rawEnd -= 1
            }
            return (Data(bytes[dataStart..<rawEnd]), found + endstream.count)
        }
        // Truncated file: take the rest.
        return (Data(bytes[dataStart...]), count)
    }

    /// Matches `N G obj` at `start`: N where the previous byte isn't part of a number, then
    /// whitespace or comments, G, whitespace or comments and the keyword `obj`. Reads at most
    /// ~530 bytes. Returns the numbers, the header's offset and where the body starts.
    static func matchObjectHeader(_ bytes: [UInt8], at start: Int) -> (n: Int, g: Int, offset: Int, bodyStart: Int)? {
        func isDigit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 }
        guard isDigit(start) else { return nil }
        if start > 0 {
            let previous = bytes[start - 1]
            if (previous >= 0x30 && previous <= 0x39) || previous == 0x2E || previous == 0x2B || previous == 0x2D { return nil }
        }
        func number(at i: inout Int, maxDigits: Int) -> Int? {
            let begin = i
            var value = 0
            while isDigit(i), i - begin < maxDigits {
                value = value * 10 + Int(bytes[i] - 0x30)
                i += 1
            }
            return i > begin && !isDigit(i) ? value : nil
        }
        /// Whitespace and `%` comments, as the lexer skips them (review 3: `3 0 % c\nobj` is a
        /// legal header). Bounded so scanning hostile bytes stays linear; a comment cut off by
        /// the bound fails rather than letting its text be read as a token.
        func separator(at i: inout Int) -> Bool {
            let begin = i
            let limit = min(bytes.count, i + 256)
            while i < limit {
                if PDFBytes.isWhitespace(bytes[i]) {
                    i += 1
                } else if bytes[i] == 0x25 {
                    while i < limit, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
                    if i == limit, limit < bytes.count { return false }
                } else {
                    break
                }
            }
            return i > begin
        }
        var i = start
        guard let n = number(at: &i, maxDigits: 10), separator(at: &i),
              let g = number(at: &i, maxDigits: 5), separator(at: &i),
              i + 3 <= bytes.count, bytes[i] == 0x6F, bytes[i + 1] == 0x62, bytes[i + 2] == 0x6A else { return nil }
        i += 3
        guard i == bytes.count || !PDFBytes.isRegular(bytes[i]) else { return nil }
        return (n, g, start, i)
    }

    /// Adds the objects inside `/Type /ObjStm` streams to `objects`. A member replaces an
    /// existing definition only if its object stream comes later in the file: incremental
    /// updates append, so position decides which definition is current.
    private static func expandObjectStreams(_ objects: inout [Int: Entry]) {
        let streams = objects.values.compactMap { entry -> (offset: Int, stream: PDFStream)? in
            if case .stream(let stream) = entry.object, stream.dictionary["Type"] == .name("ObjStm") {
                return (entry.offset, stream)
            }
            return nil
        }.sorted { $0.offset < $1.offset }
        for entry in streams {
            guard let data = PDFFilters.decode(entry.stream) else { continue }
            let count = intValue(entry.stream.dictionary["N"]) ?? 0
            let first = intValue(entry.stream.dictionary["First"]) ?? 0
            guard count > 0, count <= 65_536, first >= 0 else { continue }
            let streamBytes = [UInt8](data)
            guard first <= streamBytes.count else { continue }
            let budget = PDFScanBudget.linear(in: streamBytes.count)
            var lexer = PDFLexer(streamBytes, budget: budget)
            var pairs: [(num: Int, offset: Int)] = []
            for _ in 0..<count {
                guard case .integer(let num)? = lexer.nextToken(),
                      case .integer(let offset)? = lexer.nextToken() else { break }
                pairs.append((num, offset))
            }
            for pair in pairs {
                let at = first + pair.offset
                guard pair.num >= 1, pair.num <= Limits.maxObjectNumber, at >= 0, at <= streamBytes.count else { continue }
                if let existing = objects[pair.num], existing.offset >= entry.offset { continue }
                var sub = PDFLexer(streamBytes, at: at, budget: budget)
                if let object = PDFObjectParser.parse(&sub) {
                    objects[pair.num] = Entry(offset: entry.offset, object: object)
                }
            }
        }
    }

    /// An integer view of a number object.
    static func intValue(_ object: PDFObject?) -> Int? {
        switch object {
        case .integer(let value): return value
        case .real(let value): return Int(value)
        default: return nil
        }
    }

    // MARK: Resolution

    /// Resolves a reference to its object (arrays and dictionaries come back as-is).
    func resolve(_ object: PDFObject?, depth: Int = 0) -> PDFObject? {
        guard let object, depth < Limits.maxResolveDepth else { return nil }
        if case .reference(let number, _) = object { return resolveNumber(number, depth: depth + 1) }
        return object
    }

    func resolveNumber(_ number: Int, depth: Int = 0) -> PDFObject? {
        guard depth < Limits.maxResolveDepth, number >= 0, let entry = objects[number] else { return nil }
        if case .reference(let inner, _) = entry.object { return resolveNumber(inner, depth: depth + 1) }
        return entry.object
    }

    /// The object as a resolved dictionary, if it is one.
    func dictionary(_ object: PDFObject?) -> [String: PDFObject]? {
        if case .dictionary(let dict)? = resolve(object) { return dict }
        return nil
    }

    /// The object as a resolved stream, if it is one.
    func stream(_ object: PDFObject?) -> PDFStream? {
        if case .stream(let stream)? = resolve(object) { return stream }
        return nil
    }

    /// The catalog dictionary, when a root was found.
    var catalog: [String: PDFObject]? { dictionary(root) }

    // MARK: Pages

    /// The page tree in order, bounded against cycles and absurd sizes.
    func pages() -> [Page] {
        var pages: [Page] = []
        guard let catalog, let pagesNode = catalog["Pages"] else { return pages }
        var visited: Set<Int> = []
        walk(pagesNode, inherited: nil, depth: 0, into: &pages, visited: &visited)
        return pages
    }

    /// Walks `/Pages` → `/Kids`, carrying inherited `/Resources` down to the leaves.
    private func walk(
        _ nodeObject: PDFObject?, inherited: [String: PDFObject]?, depth: Int,
        into pages: inout [Page], visited: inout Set<Int>
    ) {
        guard depth < Limits.maxTreeDepth, pages.count < Limits.maxPages, let nodeObject else { return }
        if case .reference(let number, _) = nodeObject, !visited.insert(number).inserted { return } // cycle
        guard let dict = dictionary(nodeObject) else { return }
        let resources = dictionary(dict["Resources"]) ?? inherited ?? [:]
        if let kids = resolve(dict["Kids"]), case .array(let kidArray) = kids {
            for kid in kidArray.prefix(Limits.maxKidsPerNode) {
                walk(kid, inherited: resources, depth: depth + 1, into: &pages, visited: &visited)
            }
        } else if dict["Contents"] != nil || dict["Parent"] != nil || resolve(dict["Type"]) == .name("Page") {
            pages.append(Page(dictionary: dict, resources: resources))
        }
    }
}
