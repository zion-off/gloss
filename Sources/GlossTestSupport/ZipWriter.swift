import Foundation
import GlossArchive

/// Writes small ZIP files for tests (EPUB fixtures). Entries are deflated unless `stored`.
public struct ZipWriter {
    private var entries: [(name: String, data: Data, stored: Bool)] = []

    public init() {}

    public mutating func add(_ name: String, _ text: String, stored: Bool = false) {
        entries.append((name, Data(text.utf8), stored))
    }

    public mutating func add(_ name: String, data: Data, stored: Bool = false) {
        entries.append((name, data, stored))
    }

    public func build() throws -> Data {
        var out = [UInt8]()
        var central = [UInt8]()
        func u16(_ v: Int, _ buffer: inout [UInt8]) { buffer += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func u32(_ v: UInt32, _ buffer: inout [UInt8]) { for i in 0..<4 { buffer.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
        for entry in entries {
            let payload = entry.stored ? entry.data : try Deflate.raw(entry.data)
            let method = entry.stored ? 0 : 8
            let crc = CRC32.checksum(entry.data)
            let name = Array(entry.name.utf8)
            let offset = UInt32(out.count)
            u32(0x0403_4b50, &out); u16(20, &out); u16(0x800, &out); u16(method, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(UInt32(payload.count), &out); u32(UInt32(entry.data.count), &out)
            u16(name.count, &out); u16(0, &out); out += name; out += payload
            u32(0x0201_4b50, &central); u16(20, &central); u16(20, &central); u16(0x800, &central); u16(method, &central)
            u16(0, &central); u16(0, &central); u32(crc, &central); u32(UInt32(payload.count), &central)
            u32(UInt32(entry.data.count), &central); u16(name.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central); central += name
        }
        let directoryOffset = UInt32(out.count)
        out += central
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(directoryOffset, &out); u16(0, &out)
        return Data(out)
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
    }
}
