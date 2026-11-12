import Foundation
import GlossArchive

/// Decodes stream data through its `/Filter` chain. Unknown filters make the whole stream
/// undecodable (nil) — never a crash. `/DecodeParms` predictors are applied after FlateDecode.
enum PDFFilters {
    /// Cap on decompressed/predicted output (zip-bomb guard).
    static let maxDecoded = 256 << 20

    /// Runs the filter chain in order; nil when a filter is missing, unknown or fails.
    static func decode(_ stream: PDFStream) -> Data? {
        var data = stream.raw
        let names = filterNames(stream.dictionary)
        guard !names.isEmpty else { return data }
        let parms = decodeParms(stream.dictionary)
        for (index, name) in names.enumerated() {
            let parm = index < parms.count ? parms[index] : nil
            switch name {
            case "FlateDecode", "Fl":
                guard let inflated = try? Inflate.zlib(data, limit: maxDecoded) else { return nil }
                data = applyPredictor(inflated, parms: parm)
            case "ASCIIHexDecode", "AHx":
                data = asciiHex(data)
            case "ASCII85Decode", "A85":
                guard let decoded = ascii85(data) else { return nil }
                data = decoded
            default:
                return nil // LZWDecode, DCTDecode, … — not supported
            }
            if data.count > maxDecoded { return nil }
        }
        return data
    }

    /// `/Filter` as a list of names (a single name or an array).
    private static func filterNames(_ dict: [String: PDFObject]) -> [String] {
        guard let filter = dict["Filter"] else { return [] }
        switch filter {
        case .name(let name): return [name]
        case .array(let items): return items.compactMap { if case .name(let n) = $0 { return n }; return nil }
        default: return []
        }
    }

    /// `/DecodeParms` aligned with the filter list (dictionary, array, or none).
    private static func decodeParms(_ dict: [String: PDFObject]) -> [PDFObject?] {
        guard let parms = dict["DecodeParms"] ?? dict["DP"] else { return [] }
        switch parms {
        case .dictionary: return [parms]
        case .array(let items): return items
        default: return []
        }
    }

    // MARK: Predictors

    /// Applies the `/Predictor` from DecodeParms: PNG (>= 10, all five tags) or TIFF (2).
    static func applyPredictor(_ data: Data, parms: PDFObject?) -> Data {
        guard let parms, case .dictionary(let dict) = parms,
              let predictor = PDFDocument.intValue(dict["Predictor"]), predictor >= 2
        else { return data }
        // PDF defaults for the other DecodeParms values.
        let columns = Swift.max(1, PDFDocument.intValue(dict["Columns"]) ?? 1)
        let colors = Swift.max(1, PDFDocument.intValue(dict["Colors"]) ?? 1)
        let bpc = Swift.max(1, PDFDocument.intValue(dict["BitsPerComponent"]) ?? 8)
        guard columns <= 1 << 20, colors <= 16, bpc <= 16 else { return data }
        if predictor == 2 {
            guard bpc == 8 else { return data } // TIFF predictor only with 8-bit components
            return tiffPredictor(data, rowLength: columns * colors, colors: colors)
        }
        if predictor >= 10 {
            let rowLength = (columns * colors * bpc + 7) / 8
            return pngPredictor(data, rowLength: rowLength, samples: bpc >= 8 ? colors : 1)
        }
        return data
    }

    /// TIFF predictor 2: each pixel is the sum of the current byte and the byte `colors`
    /// earlier in the same row. Partial trailing rows are decoded too.
    private static func tiffPredictor(_ data: Data, rowLength: Int, colors: Int) -> Data {
        let bytes = [UInt8](data)
        var out = bytes
        var rowStart = 0
        while rowStart < out.count {
            let rowEnd = Swift.min(rowStart + rowLength, out.count)
            for j in (rowStart + colors)..<rowEnd {
                out[j] = out[j] &+ out[j - colors]
            }
            rowStart += rowLength
        }
        return Data(out)
    }

    /// PNG predictors: each row is a tag byte (0 none, 1 sub, 2 up, 3 average, 4 paeth)
    /// followed by filtered bytes. Partial trailing rows are decoded too.
    private static func pngPredictor(_ data: Data, rowLength: Int, samples: Int) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(Swift.max(rowLength * bytes.count / 2, rowLength))
        var previous = [UInt8](repeating: 0, count: rowLength)
        var i = 0
        while i < bytes.count, out.count <= maxDecoded {
            let available = Swift.min(rowLength, bytes.count - i - 1)
            if available < 0 { break }
            var row = [UInt8](repeating: 0, count: rowLength)
            for j in 0..<available { row[j] = bytes[i + 1 + j] }
            switch bytes[i] {
            case 1: // Sub
                for j in samples..<rowLength { row[j] = row[j] &+ row[j - samples] }
            case 2: // Up
                for j in 0..<rowLength { row[j] = row[j] &+ previous[j] }
            case 3: // Average
                for j in 0..<rowLength {
                    let left = j >= samples ? Int(row[j - samples]) : 0
                    row[j] = row[j] &+ UInt8((left + Int(previous[j])) / 2)
                }
            case 4: // Paeth
                for j in 0..<rowLength {
                    let a = j >= samples ? row[j - samples] : 0
                    let b = previous[j]
                    let c = j >= samples ? previous[j - samples] : 0
                    row[j] = row[j] &+ paeth(a, b, c)
                }
            default:
                break // 0 (None) and unknown tags: raw
            }
            out.append(contentsOf: row)
            previous = row
            i += 1 + available
        }
        return Data(out)
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb, pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    // MARK: ASCII filters

    /// ASCIIHexDecode: hex digits (whitespace ignored) until `>`; a dangling digit is padded.
    static func asciiHex(_ data: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(data.count / 2)
        var high: UInt8?
        for byte in data {
            if byte == 0x3E { break } // '>'
            if let value = PDFBytes.hexValue(byte) {
                if let h = high {
                    out.append((h << 4) | value)
                    high = nil
                } else {
                    high = value
                }
            }
            if out.count > maxDecoded { break }
        }
        if let h = high { out.append(h << 4) }
        return Data(out)
    }

    /// ASCII85Decode: `<~`? data `~>`?; `z` is four zero bytes; a short final group yields
    /// its digits minus one bytes. Invalid input → nil.
    static func ascii85(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        var i = 0
        if bytes.count >= 2, bytes[0] == 0x3C, bytes[1] == 0x7E { i = 2 } // '<~'
        var group: [UInt8] = []
        var finished = false
        while i < bytes.count, !finished, out.count <= maxDecoded {
            let c = bytes[i]
            i += 1
            if PDFBytes.isWhitespace(c) { continue }
            if c == 0x7E { finished = true; break } // '~' (usually followed by '>')
            if c == 0x7A, group.isEmpty { // 'z'
                out += [0, 0, 0, 0]
                continue
            }
            guard c >= 0x21, c <= 0x75 else { return nil } // invalid character
            group.append(c - 0x21)
            if group.count == 5 {
                out.append(contentsOf: decodeGroup(group))
                group = []
            }
        }
        if !group.isEmpty {
            guard group.count >= 2 else { return nil } // one trailing digit is invalid
            let padded = group + [UInt8](repeating: 84, count: 5 - group.count)
            out.append(contentsOf: decodeGroup(padded).prefix(group.count - 1))
        }
        return Data(out)
    }

    private static func decodeGroup(_ group: [UInt8]) -> [UInt8] {
        var value: UInt32 = 0
        for digit in group { value = value &* 85 &+ UInt32(digit) }
        return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
