import Foundation

public enum ZipError: Error, Equatable, Sendable {
    case notAZip
    case corrupt(String)
    case missingEntry(String)
    case unsupportedCompression(UInt16)
}

/// A read-only ZIP archive held in memory (EPUBs, later CBZ comics). Reads the central
/// directory, supports stored and deflated entries and ZIP64 sizes/offsets.
public struct ZipArchive: Sendable {
    public struct Entry: Hashable, Sendable {
        public let path: String
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int

        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    private let data: Data
    public let entries: [Entry]
    private let index: [String: Int]

    public init(data: Data) throws {
        self.data = data
        let bytes = ByteReader(data)
        guard let eocd = Self.findEndOfCentralDirectory(bytes) else { throw ZipError.notAZip }
        var count = Int(try bytes.u16(eocd + 10))
        var directorySize = Int(try bytes.u32(eocd + 12))
        var directoryOffset = Int(try bytes.u32(eocd + 16))
        // ZIP64 end of central directory locator sits right before the EOCD.
        if eocd >= 20, (try? bytes.u32(eocd - 20)) == 0x0706_4b50 {
            let zip64Offset = Int(try bytes.u64(eocd - 20 + 8))
            guard (try? bytes.u32(zip64Offset)) == 0x0606_4b50 else { throw ZipError.corrupt("zip64 directory") }
            count = Int(try bytes.u64(zip64Offset + 32))
            directorySize = Int(try bytes.u64(zip64Offset + 40))
            directoryOffset = Int(try bytes.u64(zip64Offset + 48))
        }
        guard directoryOffset >= 0, directoryOffset + directorySize <= data.count else { throw ZipError.corrupt("central directory bounds") }
        var entries: [Entry] = []
        var cursor = directoryOffset
        for _ in 0..<count {
            guard try bytes.u32(cursor) == 0x0201_4b50 else { throw ZipError.corrupt("central directory entry") }
            let flags = try bytes.u16(cursor + 8)
            let method = try bytes.u16(cursor + 10)
            var compressed = Int(try bytes.u32(cursor + 20))
            var uncompressed = Int(try bytes.u32(cursor + 24))
            let nameLength = Int(try bytes.u16(cursor + 28))
            let extraLength = Int(try bytes.u16(cursor + 30))
            let commentLength = Int(try bytes.u16(cursor + 32))
            var offset = Int(try bytes.u32(cursor + 42))
            let nameBytes = try bytes.slice(cursor + 46, nameLength)
            let name = (flags & 0x800) != 0 || nameBytes.allSatisfy({ $0 < 0x80 })
                ? String(decoding: nameBytes, as: UTF8.self)
                : String(nameBytes.map { Character(Unicode.Scalar($0)) })
            // ZIP64 extended information extra field.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let tag = try bytes.u16(extra), size = Int(try bytes.u16(extra + 2))
                if tag == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF { uncompressed = Int(try bytes.u64(field)); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = Int(try bytes.u64(field)); field += 8 }
                    if offset == 0xFFFF_FFFF { offset = Int(try bytes.u64(field)) }
                }
                extra += 4 + size
            }
            entries.append(Entry(path: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: offset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() where index[entry.path] == nil { index[entry.path] = position }
        self.index = index
    }

    public var paths: [String] { entries.map(\.path) }

    public func contains(_ path: String) -> Bool { entry(at: path) != nil }

    /// Looks an entry up by exact path, then case-insensitively (some EPUBs get case wrong).
    public func entry(at path: String) -> Entry? {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let position = index[normalized] { return entries[position] }
        let lower = normalized.lowercased()
        return entries.first { $0.path.lowercased() == lower }
    }

    public func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw ZipError.missingEntry(path) }
        return try data(for: entry)
    }

    public func data(for entry: Entry) throws -> Data {
        let bytes = ByteReader(data)
        let header = entry.localHeaderOffset
        guard try bytes.u32(header) == 0x0403_4b50 else { throw ZipError.corrupt("local header for \(entry.path)") }
        let start = header + 30 + Int(try bytes.u16(header + 26)) + Int(try bytes.u16(header + 28))
        let payload = Data(try bytes.slice(start, entry.compressedSize))
        switch entry.method {
        case 0: return payload
        case 8:
            do { return try Inflate.raw(payload, sizeHint: entry.uncompressedSize) }
            catch { throw ZipError.corrupt("deflate data for \(entry.path)") }
        default: throw ZipError.unsupportedCompression(entry.method)
        }
    }

    public func text(at path: String) throws -> String {
        let raw = try data(at: path)
        return String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
    }

    private static func findEndOfCentralDirectory(_ bytes: ByteReader) -> Int? {
        let minimum = 22
        guard bytes.count >= minimum else { return nil }
        let lowest = max(0, bytes.count - minimum - 0xFFFF)
        var position = bytes.count - minimum
        while position >= lowest {
            if (try? bytes.u32(position)) == 0x0605_4b50 { return position }
            position -= 1
        }
        return nil
    }
}

/// Bounds-checked little-endian reads.
struct ByteReader {
    let bytes: [UInt8]
    init(_ data: Data) { bytes = [UInt8](data) }
    var count: Int { bytes.count }

    func slice(_ offset: Int, _ length: Int) throws -> ArraySlice<UInt8> {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else { throw ZipError.corrupt("read past end") }
        return bytes[offset..<offset + length]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        let s = try slice(offset, 2)
        return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }

    func u32(_ offset: Int) throws -> UInt32 {
        let s = try slice(offset, 4)
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(s[s.startIndex + $1]) << (8 * UInt32($1)) }
    }

    func u64(_ offset: Int) throws -> UInt64 {
        let s = try slice(offset, 8)
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(s[s.startIndex + $1]) << (8 * UInt64($1)) }
    }
}
