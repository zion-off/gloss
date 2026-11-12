import Foundation

/// Extracts readable text from decoded content streams, appending into one page buffer.
/// Handles the text operators (`BT/ET Tf Td TD T* Tm Tj TJ ' "`), recurses into Form
/// XObjects, skips inline images, and inserts line breaks and word spaces from the
/// positioning operators. Everything else (graphics state, colour, paths) is ignored.
struct PDFPageTextExtractor {
    /// Bounds against absurd content.
    private enum Limits {
        static let maxFormDepth = 8
        static let maxFormsPerPage = 512
        static let maxOperators = 2_000_000
    }

    private let doc: PDFDocument
    /// The extracted text so far for the current page.
    private(set) var text = ""
    /// Font decoders by object identity (cached across pages of one document).
    private var fontCache: [Int: PDFFontDecoder] = [:]

    // Text state (subset).
    private var currentFont: PDFFontDecoder?
    private var fontSize = 0.0
    private var leading = 0.0
    private var lineX = 0.0
    private var lineY = 0.0
    /// Where text was last shown; drives newline/space decisions.
    private var lastShownX: Double?
    private var lastShownY: Double?
    private var formCalls = 0

    init(document: PDFDocument) {
        self.doc = document
    }

    /// Resets per-page state; the font cache survives.
    mutating func beginPage() {
        text = ""
        currentFont = nil
        fontSize = 0
        leading = 0
        lineX = 0
        lineY = 0
        lastShownX = nil
        lastShownY = nil
        formCalls = 0
    }

    /// Runs one content stream (a page's `/Contents` or a Form XObject).
    mutating func run(stream: Data, resources: [String: PDFObject]?, depth: Int) {
        guard depth <= Limits.maxFormDepth else { return }
        var lexer = PDFLexer([UInt8](stream))
        var operands: [PDFObject] = []
        operands.reserveCapacity(8)
        var processed = 0
        while let token = lexer.nextToken(), processed < Limits.maxOperators {
            processed += 1
            switch token {
            case .integer, .real, .name, .string:
                operands.append(asObject(token))
            case .arrayOpen:
                operands.append(.array(PDFObjectParser.parseArray(&lexer)))
            case .dictOpen:
                operands.append(.dictionary(PDFObjectParser.parseDictionary(&lexer)))
            case .arrayClose, .dictClose:
                break // stray delimiter
            case .keyword(let keyword):
                handle(keyword, operands: operands, lexer: &lexer, resources: resources, depth: depth)
                operands.removeAll(keepingCapacity: true)
            }
        }
    }

    private func asObject(_ token: PDFToken) -> PDFObject {
        switch token {
        case .integer(let value): return .integer(value)
        case .real(let value): return .real(value)
        case .name(let value): return .name(value)
        case .string(let value): return .string(value)
        default: return .null
        }
    }

    private func number(_ object: PDFObject?) -> Double? {
        switch object {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return nil
        }
    }

    // MARK: Operators

    private mutating func handle(
        _ keyword: String, operands: [PDFObject], lexer: inout PDFLexer,
        resources: [String: PDFObject]?, depth: Int
    ) {
        switch keyword {
        case "Tf":
            if operands.count >= 2, case .name(let fontName) = operands[0],
               let size = number(operands[1]) {
                fontSize = abs(size)
                currentFont = font(named: fontName, resources: resources)
            }
        case "TL":
            if let value = number(operands.last) { leading = value }
        case "Td":
            if operands.count >= 2, let tx = number(operands[0]), let ty = number(operands[1]) {
                lineX += tx
                lineY += ty
            }
        case "TD":
            if operands.count >= 2, let tx = number(operands[0]), let ty = number(operands[1]) {
                leading = -ty
                lineX += tx
                lineY += ty
            }
        case "T*":
            emitNewline()
            lineY -= leading
        case "Tm":
            if operands.count >= 6, let tx = number(operands[4]), let ty = number(operands[5]) {
                lineX = tx
                lineY = ty
            }
        case "Tj":
            if case .string(let bytes)? = operands.last { show(bytes) }
        case "TJ":
            guard case .array(let items)? = operands.last else { break }
            for item in items {
                switch item {
                case .string(let bytes):
                    show(bytes)
                case .integer(let value):
                    if Double(value) < -200 { emitSpace() } // word-sized kerning adjustment
                case .real(let value):
                    if value < -200 { emitSpace() }
                default:
                    break
                }
            }
        case "'":
            emitNewline()
            lineY -= leading
            if case .string(let bytes)? = operands.last { show(bytes) }
        case "\"":
            emitNewline()
            lineY -= leading
            if case .string(let bytes)? = operands.last { show(bytes) }
        case "Do":
            drawXObject(operands, resources: resources, depth: depth)
        case "BI":
            skipInlineImage(&lexer)
        default:
            break // BT, ET, q, Q, cm, colour, paths, marked content, …
        }
    }

    /// Shows a string: inserts a line break or space when the position moved, then decodes.
    private mutating func show(_ bytes: Data) {
        separator()
        text += (currentFont ?? .latin1).decode(bytes)
        lastShownX = lineX
        lastShownY = lineY
    }

    /// A newline when the line moved vertically, a space for noticeable horizontal jumps.
    private mutating func separator() {
        guard let shownX = lastShownX, let shownY = lastShownY else { return }
        let em = fontSize > 0 ? fontSize : 12
        if abs(lineY - shownY) > em * 0.3 {
            emitNewline()
        } else if abs(lineX - shownX) > em * 0.3 {
            emitSpace()
        }
    }

    private mutating func emitNewline() {
        while text.last == " " { text.removeLast() }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    }

    private mutating func emitSpace() {
        guard let last = text.last, !last.isNewline, last != " " else { return }
        text += " "
    }

    /// `Do`: recurses into Form XObjects with their own resources; images are skipped.
    private mutating func drawXObject(_ operands: [PDFObject], resources: [String: PDFObject]?, depth: Int) {
        guard depth < Limits.maxFormDepth, formCalls < Limits.maxFormsPerPage,
              case .name(let name)? = operands.last,
              let xObjects = doc.dictionary(resources?["XObject"]),
              let object = xObjects[name],
              let stream = doc.stream(object),
              stream.dictionary["Subtype"] == .name("Form"),
              let content = PDFFilters.decode(stream) else { return }
        formCalls += 1
        let formResources = doc.dictionary(stream.dictionary["Resources"]) ?? resources
        // The form runs in its own text state; the caller's is restored afterwards. The
        // last-shown position is kept so line breaks between the form's and the caller's
        // text still come out right.
        let saved = (currentFont, fontSize, leading, lineX, lineY)
        run(stream: content, resources: formResources, depth: depth + 1)
        (currentFont, fontSize, leading, lineX, lineY) = saved
    }

    /// `BI … ID <binary> EI`: skips the binary safely (EI at a token boundary).
    private mutating func skipInlineImage(_ lexer: inout PDFLexer) {
        while let token = lexer.nextToken() {
            if case .keyword("ID") = token { break }
            if case .keyword("EI") = token { return }
        }
        var i = lexer.index
        let bytes = lexer.bytes
        if i < bytes.count, bytes[i] == 0x0D {
            i += 1
            if i < bytes.count, bytes[i] == 0x0A { i += 1 }
        } else if i < bytes.count, bytes[i] == 0x0A {
            i += 1
        }
        while i + 1 < bytes.count {
            if bytes[i] == 0x45, bytes[i + 1] == 0x49, // "EI"
               (i == 0 || PDFBytes.isWhitespace(bytes[i - 1]) || PDFBytes.isDelimiter(bytes[i - 1])),
               (i + 2 == bytes.count || PDFBytes.isWhitespace(bytes[i + 2]) || PDFBytes.isDelimiter(bytes[i + 2])) {
                lexer.index = i + 2
                return
            }
            i += 1
        }
        lexer.index = bytes.count // unterminated: consume the rest
    }

    /// The font decoder for a resource name. Indirect fonts are cached by object number (the
    /// document keeps one definition per number); direct font dictionaries aren't cached, since
    /// two pages may define different fonts under the same resource name.
    private mutating func font(named name: String, resources: [String: PDFObject]?) -> PDFFontDecoder? {
        guard let resources, let fonts = doc.dictionary(resources["Font"]),
              let object = fonts[name] else { return nil }
        guard case .reference(let number, _) = object else {
            return PDFFontDecoder.make(fontObject: object, in: doc)
        }
        if let cached = fontCache[number] { return cached }
        let decoder = PDFFontDecoder.make(fontObject: object, in: doc)
        fontCache[number] = decoder
        return decoder
    }
}
