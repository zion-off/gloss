import Foundation

/// Glyph names → Unicode (an Adobe Glyph List subset), for simple-font `/Differences`.
enum PDFGlyphs {
    private static let names: [String: String] = [
        // ASCII names
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$",
        "percent": "%", "ampersand": "&", "quotesingle": "'", "parenleft": "(", "parenright": ")",
        "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-", "period": ".", "slash": "/",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "colon": ":", "semicolon": ";", "less": "<", "equal": "=", "greater": ">",
        "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\", "bracketright": "]",
        "asciicircum": "^", "underscore": "_", "grave": "`", "braceleft": "{", "bar": "|",
        "braceright": "}", "asciitilde": "~",
        // punctuation
        "quoteleft": "\u{2018}", "quoteright": "\u{2019}", "quotedblleft": "\u{201C}",
        "quotedblright": "\u{201D}", "quotesinglbase": "\u{201A}", "quotedblbase": "\u{201E}",
        "guillemotleft": "\u{00AB}", "guillemotright": "\u{00BB}",
        "guilsinglleft": "\u{2039}", "guilsinglright": "\u{203A}",
        "endash": "\u{2013}", "emdash": "\u{2014}", "bullet": "\u{2022}", "dagger": "\u{2020}",
        "daggerdbl": "\u{2021}", "ellipsis": "\u{2026}", "perthousand": "\u{2030}",
        "trademark": "\u{2122}", "florin": "\u{0192}", "fraction": "\u{2044}",
        "minus": "\u{2212}", "sfthyphen": "\u{00AD}", "nbspace": "\u{00A0}", "blank": " ",
        // ligatures
        "fi": "\u{FB01}", "fl": "\u{FB02}", "ff": "\u{FB00}", "ffi": "\u{FB03}", "ffl": "\u{FB04}",
        // Latin-1 supplement
        "exclamdown": "\u{00A1}", "cent": "\u{00A2}", "sterling": "\u{00A3}", "currency": "\u{00A4}",
        "yen": "\u{00A5}", "brokenbar": "\u{00A6}", "section": "\u{00A7}", "dieresis": "\u{00A8}",
        "copyright": "\u{00A9}", "ordfeminine": "\u{00AA}", "logicalnot": "\u{00AC}",
        "registered": "\u{00AE}", "macron": "\u{00AF}", "degree": "\u{00B0}", "plusminus": "\u{00B1}",
        "twosuperior": "\u{00B2}", "threesuperior": "\u{00B3}", "acute": "\u{00B4}", "mu": "\u{00B5}",
        "paragraph": "\u{00B6}", "periodcentered": "\u{00B7}", "cedilla": "\u{00B8}",
        "onesuperior": "\u{00B9}", "ordmasculine": "\u{00BA}", "onequarter": "\u{00BC}",
        "onehalf": "\u{00BD}", "threequarters": "\u{00BE}", "questiondown": "\u{00BF}",
        "multiply": "\u{00D7}", "divide": "\u{00F7}",
        // accented letters
        "Agrave": "\u{00C0}", "Aacute": "\u{00C1}", "Acirc": "\u{00C2}", "Atilde": "\u{00C3}",
        "Adieresis": "\u{00C4}", "Aring": "\u{00C5}", "AE": "\u{00C6}", "Ccedilla": "\u{00C7}",
        "Egrave": "\u{00C8}", "Eacute": "\u{00C9}", "Ecirc": "\u{00CA}", "Edieresis": "\u{00CB}",
        "Igrave": "\u{00CC}", "Iacute": "\u{00CD}", "Icirc": "\u{00CE}", "Idieresis": "\u{00CF}",
        "Eth": "\u{00D0}", "Ntilde": "\u{00D1}", "Ograve": "\u{00D2}", "Oacute": "\u{00D3}",
        "Ocirc": "\u{00D4}", "Otilde": "\u{00D5}", "Odieresis": "\u{00D6}", "Oslash": "\u{00D8}",
        "Ugrave": "\u{00D9}", "Uacute": "\u{00DA}", "Ucirc": "\u{00DB}", "Udieresis": "\u{00DC}",
        "Yacute": "\u{00DD}", "Thorn": "\u{00DE}",
        "agrave": "\u{00E0}", "aacute": "\u{00E1}", "acirc": "\u{00E2}", "atilde": "\u{00E3}",
        "adieresis": "\u{00E4}", "aring": "\u{00E5}", "ae": "\u{00E6}", "ccedilla": "\u{00E7}",
        "egrave": "\u{00E8}", "eacute": "\u{00E9}", "ecirc": "\u{00EA}", "edieresis": "\u{00EB}",
        "igrave": "\u{00EC}", "iacute": "\u{00ED}", "icirc": "\u{00EE}", "idieresis": "\u{00EF}",
        "eth": "\u{00F0}", "ntilde": "\u{00F1}", "ograve": "\u{00F2}", "oacute": "\u{00F3}",
        "ocirc": "\u{00F4}", "otilde": "\u{00F5}", "odieresis": "\u{00F6}", "oslash": "\u{00F8}",
        "ugrave": "\u{00F9}", "uacute": "\u{00FA}", "ucirc": "\u{00FB}", "udieresis": "\u{00FC}",
        "yacute": "\u{00FD}", "thorn": "\u{00FE}", "yuml": "\u{00FF}", "ydieresis": "\u{00FF}",
        "dotlessi": "\u{0131}", "OE": "\u{0152}", "oe": "\u{0153}",
        "Scaron": "\u{0160}", "scaron": "\u{0161}", "Ydieresis": "\u{0178}",
        "Zcaron": "\u{017D}", "zcaron": "\u{017E}", "Lslash": "\u{0141}", "lslash": "\u{0142}",
        // accents
        "circumflex": "\u{02C6}", "caron": "\u{02C7}", "breve": "\u{02D8}", "dotaccent": "\u{02D9}",
        "ring": "\u{02DA}", "ogonek": "\u{02DB}", "tilde": "\u{02DC}", "hungarumlaut": "\u{02DD}",
        // math and symbols
        "notequal": "\u{2260}", "infinity": "\u{221E}", "lessequal": "\u{2264}",
        "greaterequal": "\u{2265}", "partialdiff": "\u{2202}", "summation": "\u{2211}",
        "product": "\u{220F}", "radical": "\u{221A}", "integral": "\u{222B}",
        "approxequal": "\u{2248}", "Delta": "\u{0394}", "Omega": "\u{03A9}", "Ohm": "\u{03A9}",
        "Pi": "\u{03A0}", "pi": "\u{03C0}", "alpha": "\u{03B1}",
    ]

    /// Unicode for a glyph name: the table, `uniXXXX`/`uXXXX` hex names, or a single
    /// printable ASCII character name standing for itself. Every mapping is a single
    /// scalar, so the font decoder can build strings without per-byte allocation.
    static func unicodeScalar(for name: String) -> Unicode.Scalar? {
        if let value = names[name] { return value.unicodeScalars.first }
        for prefix in ["uni", "u"] where name.hasPrefix(prefix) {
            let hex = name.dropFirst(prefix.count)
            if hex.count >= 4, hex.count <= 6, hex.allSatisfy(\Character.isHexDigit),
               let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                return scalar
            }
        }
        // Single-byte printable names ("A" → "A") are conventional for base fonts.
        if name.utf8.count == 1, let c = name.utf8.first, c >= 0x21, c != 0x7F {
            return UnicodeScalar(c)
        }
        return nil
    }
}
