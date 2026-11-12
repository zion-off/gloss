import Foundation

/// Decodes character codes from content streams to Unicode for one font. Built from the
/// font dictionary: `/ToUnicode` CMap first, then Type0 (2-byte codes), then simple fonts
/// (base encoding + `/Differences`). Without any usable mapping, bytes fall back to
/// Latin-1 when printable.
struct PDFFontDecoder: Sendable {
    /// Bytes per code (1 for simple fonts, 2+ for Type0).
    var codeLength = 1
    /// Code → Unicode from a ToUnicode CMap (Type0 and mapped simple fonts).
    var cmap: [UInt32: String]?
    /// Byte → Unicode for simple fonts (base table with Differences overrides).
    var byteTable: [Unicode.Scalar?] = .init(repeating: nil, count: 256)
    /// Whether unmapped printable bytes decode as Latin-1.
    var latin1Fallback = true

    /// A decoder that only does the Latin-1 fallback (no font, or unreadable font).
    static let latin1 = PDFFontDecoder()

    /// Builds the decoder for a font object (reference or direct dictionary).
    static func make(fontObject: PDFObject, in doc: PDFDocument) -> PDFFontDecoder {
        var decoder = PDFFontDecoder()
        guard let resolved = doc.resolve(fontObject), case .dictionary(let dict) = resolved else {
            return decoder
        }

        // ToUnicode wins: it maps codes straight to Unicode.
        if let toUnicode = doc.stream(dict["ToUnicode"]) {
            let cmap = PDFCMap.parse(PDFFilters.decode(toUnicode) ?? Data())
            if !cmap.map.isEmpty {
                decoder.cmap = cmap.map
                decoder.codeLength = cmap.codeLength
                decoder.latin1Fallback = false
                return decoder
            }
        }

        if doc.resolve(dict["Subtype"]) == .name("Type0") {
            // Identity-H/V and friends: 2-byte codes; unmapped codes are skipped.
            decoder.codeLength = 2
            decoder.latin1Fallback = false
            return decoder
        }

        // Simple font: base encoding plus /Differences overrides.
        var base: [UInt32]?
        switch doc.resolve(dict["Encoding"]) {
        case .name(let name):
            base = PDFEncoding.table(named: name)
        case .dictionary(let encoding):
            if case .name(let name)? = doc.resolve(encoding["BaseEncoding"]) {
                base = PDFEncoding.table(named: name)
            }
            if case .array(let differences)? = doc.resolve(encoding["Differences"]) {
                decoder.apply(differences)
            }
        default:
            break
        }
        if let base {
            for byte in 0..<256 where decoder.byteTable[byte] == nil {
                if let unicode = UnicodeScalar(base[byte]) {
                    decoder.byteTable[byte] = base[byte] == 0xA0 ? " " : unicode
                }
            }
        }
        return decoder
    }

    /// `/Differences [code /name /name … code /name …]`.
    private mutating func apply(_ differences: [PDFObject]) {
        var pending: Int?
        for item in differences {
            switch item {
            case .integer(let code):
                pending = code
            case .name(let name):
                if let code = pending, (0..<256).contains(code) {
                    byteTable[code] = PDFGlyphs.unicodeScalar(for: name)
                }
                pending = (pending ?? -1) + 1
            default:
                pending = nil
            }
        }
    }

    /// Decodes a run of bytes with this font's mapping.
    func decode(_ bytes: Data) -> String {
        if let cmap {
            var out = String()
            var index = bytes.startIndex
            let end = bytes.endIndex
            while index < end {
                let length = Swift.min(codeLength, end - index)
                var code: UInt32 = 0
                for k in 0..<length { code = (code << 8) | UInt32(bytes[bytes.index(index, offsetBy: k)]) }
                index += length
                if let text = cmap[code] { out += text }
            }
            return out
        }
        // Simple fonts: one scalar per byte, assembled in one pass.
        var scalars = [Unicode.Scalar]()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            if let scalar = byteTable[Int(byte)] {
                scalars.append(scalar)
            } else if latin1Fallback, byte >= 0x20, byte != 0x7F, let scalar = PDFEncoding.latin1Scalar(byte) {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
