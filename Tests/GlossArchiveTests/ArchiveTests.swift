import Foundation
import Testing
@testable import GlossArchive
import GlossTestSupport

@Suite("archive")
struct ArchiveTests {
    @Test("inflate round-trips raw and zlib streams")
    func roundTrip() throws {
        let text = Data(String(repeating: "the absurd is born of this confrontation. ", count: 200).utf8)
        #expect(try Inflate.raw(Deflate.raw(text)) == text)
        #expect(try Inflate.zlib(Deflate.zlib(text)) == text)
        // zlib() tolerates raw streams that lack the header.
        #expect(try Inflate.zlib(Deflate.raw(text)) == text)
    }

    @Test("truncated and corrupt input terminates")
    func truncated() throws {
        let text = Data(String(repeating: "abcdefghij", count: 5000).utf8)
        let deflated = try Deflate.raw(text)
        let cut = deflated.prefix(deflated.count / 2)
        #expect(throws: CompressionError.corrupt) { try Inflate.raw(cut) }
        let partial = try Inflate.raw(cut, allowTruncated: true)
        #expect(!partial.isEmpty && text.starts(with: partial))
        #expect(throws: CompressionError.self) { try Inflate.raw(Data(repeating: 0xFF, count: 64)) }
        #expect(try Inflate.raw(Data()) == Data())
    }

    @Test("the size limit stops zip bombs")
    func limit() throws {
        let zeros = try Deflate.raw(Data(count: 1 << 20))
        #expect(throws: CompressionError.tooLarge) { try Inflate.raw(zeros, limit: 1000) }
    }

    @Test("zip entries read back, stored and deflated, with case-insensitive fallback")
    func zip() throws {
        var writer = ZipWriter()
        writer.add("mimetype", "application/epub+zip", stored: true)
        writer.add("OEBPS/Chapter 1.xhtml", "<p>héllo</p>")
        let archive = try ZipArchive(data: try writer.build())
        #expect(archive.paths == ["mimetype", "OEBPS/Chapter 1.xhtml"])
        #expect(try archive.text(at: "mimetype") == "application/epub+zip")
        #expect(try archive.text(at: "/oebps/chapter 1.xhtml") == "<p>héllo</p>")
        #expect(throws: ZipError.missingEntry("nope")) { try archive.data(at: "nope") }
    }

    @Test("non-zips and damaged zips are rejected, never crash")
    func damaged() throws {
        #expect(throws: ZipError.notAZip) { try ZipArchive(data: Data("not a zip".utf8)) }
        var writer = ZipWriter()
        writer.add("a.txt", String(repeating: "x", count: 1000))
        let good = try writer.build()
        for cut in stride(from: 1, to: good.count, by: 7) {
            var damaged = good
            damaged[cut] ^= 0x5A
            if let archive = try? ZipArchive(data: damaged) { _ = try? archive.data(at: "a.txt") }
        }
        _ = try? ZipArchive(data: good.suffix(30))
    }
}
