import Foundation

/// An sRGB colour parsed from the hex notation the appearance palette uses (`#rgb`, `#rrggbb`,
/// `#rrggbbaa`), so the Mac layer can match native backgrounds to the page.
public struct CSSColor: Hashable, Sendable {
    /// Components in 0…1.
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        var digits = Array(text.dropFirst())
        // ASCII only: `isHexDigit` also accepts fullwidth digits, which `Int(_:radix:)` does not.
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        switch digits.count {
        case 3: digits = digits.flatMap { [$0, $0] } + ["f", "f"]
        case 6: digits += ["f", "f"]
        case 8: break
        default: return nil
        }
        let bytes = stride(from: 0, to: 8, by: 2).map { Double(Int(String(digits[$0...$0 + 1]), radix: 16)!) / 255 }
        self.init(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }
}
