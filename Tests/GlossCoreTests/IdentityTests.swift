import Foundation
import Testing
@testable import GlossCore
import GlossTestSupport

@Suite("identity")
struct IdentityTests {
    @Test("ids round-trip through their 26-character form")
    func roundTrip() throws {
        let generator = UUIDv7Generator()
        for _ in 0..<500 {
            let id = generator.next()
            let string = id.stringValue
            #expect(string.count == 26)
            #expect(string == string.lowercased())
            #expect(GlossID(string: string) == id)
        }
    }

    @Test("extreme values encode and decode")
    func extremes() {
        let zero = GlossID(high: 0, low: 0)
        let max = GlossID(high: .max, low: .max)
        #expect(zero.stringValue == String(repeating: "0", count: 26))
        #expect(max.stringValue == "7" + String(repeating: "z", count: 25))
        #expect(GlossID(string: max.stringValue) == max)
    }

    @Test("parsing is case-insensitive, accepts Crockford aliases and rejects junk")
    func parsing() {
        let id = GlossID(high: 0x0123_4567_89ab_cdef, low: 0xfedc_ba98_7654_3210)
        #expect(GlossID(string: id.stringValue.uppercased()) == id)
        #expect(GlossID(string: "0000000000000000000000000O") == GlossID(string: "00000000000000000000000000"))
        #expect(GlossID(string: "0000000000000000000000000L") == GlossID(high: 0, low: 1))
        #expect(GlossID(string: "short") == nil)
        #expect(GlossID(string: "8zzzzzzzzzzzzzzzzzzzzzzzzz") == nil) // overflows 128 bits
        #expect(GlossID(string: "0000000000000000000000000u") == nil) // u is not in the alphabet
    }

    @Test("v7 ids carry their timestamp and sort by time")
    func v7Ordering() {
        let clock = ManualTimeSource(Date(timeIntervalSince1970: 1_700_000_000))
        let generator = UUIDv7Generator(time: clock)
        let first = generator.next()
        clock.advance(by: 1)
        let second = generator.next()
        #expect(first < second)
        #expect(first.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("typed identifiers encode as plain strings")
    func codable() throws {
        let id: PageID = SequentialIDGenerator().make()
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[\"\(id.stringValue)\"]")
        #expect(try JSONDecoder().decode([PageID].self, from: data) == [id])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([PageID].self, from: Data("[\"nope\"]".utf8)) }
    }

    @Test("content hashes are lowercase sha-256 hex")
    func contentHash() {
        let hash = ContentHash.of(Data("gloss".utf8))
        #expect(hash.hex.count == 64)
        #expect(ContentHash(hex: hash.hex.uppercased()) == hash)
        #expect(ContentHash.of(Data()).hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ContentHash(hex: "xyz") == nil)
    }
}
