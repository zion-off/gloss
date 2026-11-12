import Foundation

/// Character encodings for PDF text: metadata strings (PDFDocEncoding / UTF-16BE / UTF-8)
/// and the simple-font base encodings (WinAnsi, MacRoman, Standard).
enum PDFEncoding {
    /// WinAnsiEncoding (CP1252). 0 = undefined.
    static let winAnsi: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
        32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
        48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
        80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
        96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
        112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
        8364, 0, 8218, 402, 8222, 8230, 8224, 8225, 710, 8240, 352, 8249, 338, 0, 381, 0,
        0, 8216, 8217, 8220, 8221, 8226, 8211, 8212, 732, 8482, 353, 8250, 339, 0, 382, 376,
        160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175,
        176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
        192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207,
        208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223,
        224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
        240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255,
    ]

    /// MacRomanEncoding. 0 = undefined.
    static let macRoman: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
        32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
        48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
        80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
        96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
        112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
        196, 197, 199, 201, 209, 214, 220, 225, 224, 226, 228, 227, 229, 231, 233, 232,
        234, 235, 237, 236, 238, 239, 241, 243, 242, 244, 246, 245, 250, 249, 251, 252,
        8224, 176, 162, 163, 167, 8226, 182, 223, 174, 169, 8482, 180, 168, 8800, 198, 216,
        8734, 177, 8804, 8805, 165, 181, 8706, 8721, 8719, 960, 8747, 170, 186, 937, 230, 248,
        191, 161, 172, 8730, 402, 8776, 8710, 171, 187, 8230, 160, 192, 195, 213, 338, 339,
        8211, 8212, 8220, 8221, 8216, 8217, 247, 9674, 255, 376, 8260, 8364, 8249, 8250, 64257, 64258,
        8225, 183, 8218, 8222, 8240, 194, 202, 193, 203, 200, 205, 206, 207, 204, 211, 212,
        63743, 210, 218, 219, 217, 305, 710, 732, 175, 728, 729, 730, 184, 733, 731, 711,
    ]

    /// Adobe StandardEncoding: ASCII plus the quote swaps at 0x27/0x60. 0 = undefined.
    static let standard: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for byte in 32...126 { table[byte] = UInt32(byte) }
        table[39] = 0x2019 // quoteright
        table[96] = 0x2018 // quoteleft
        return table
    }()

    /// PDFDocEncoding: Latin-1 plus Adobe's additions in the control and 0x80–0x8A ranges.
    static let pdfDoc: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for byte in 0...255 { table[byte] = UInt32(byte) }
        let patches: [Int: UInt32] = [
            0x18: 0x02D8, 0x19: 0x02C7, 0x1A: 0x02C6, 0x1B: 0x02D9,
            0x1C: 0x02DD, 0x1D: 0x02DB, 0x1E: 0x02DA, 0x1F: 0x02DC,
            0x80: 0x2022, 0x81: 0x2020, 0x82: 0x2021, 0x83: 0x2026,
            0x84: 0x2014, 0x85: 0x2013, 0x86: 0xFB00, 0x87: 0xFB01,
            0x88: 0xFB02, 0x89: 0xFB03, 0x8A: 0xFB04,
        ]
        for (byte, scalar) in patches { table[byte] = scalar }
        return table
    }()

    /// The base table for a simple-font encoding name, if known.
    static func table(named name: String) -> [UInt32]? {
        switch name {
        case "WinAnsiEncoding": return winAnsi
        case "MacRomanEncoding": return macRoman
        case "StandardEncoding": return standard
        default: return nil
        }
    }

    /// Decodes a PDF text string (Info values, `/Lang`, …): UTF-16BE with BOM, UTF-8 with
    /// BOM, else PDFDocEncoding.
    static func decodeTextString(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(decoding: utf16Units(bytes, from: 2), as: UTF16.self)
        }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(decoding: bytes[3...], as: UTF8.self)
        }
        var out = String()
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            if let scalar = UnicodeScalar(pdfDoc[Int(byte)]) { out.append(Character(scalar)) }
        }
        return out
    }

    /// Big-endian UTF-16 code units from `data`, starting at `from`.
    static func utf16Units(_ data: [UInt8], from: Int = 0) -> [UInt16] {
        var units = [UInt16]()
        units.reserveCapacity((data.count - from) / 2)
        var i = from
        while i + 1 < data.count {
            units.append(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
            i += 2
        }
        return units
    }

    /// Latin-1 fallback for bytes with no font mapping: printable bytes decode, others skip.
    static func latin1Scalar(_ byte: UInt8) -> Unicode.Scalar? {
        switch byte {
        case 0x20...0x7E, 0xA1...0xFF: return UnicodeScalar(byte)
        case 0xA0: return UnicodeScalar(0x20) // nbsp reads as a space
        default: return nil
        }
    }
}
