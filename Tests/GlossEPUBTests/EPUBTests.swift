import Foundation
import Testing
@testable import GlossEPUB
import GlossCore
import GlossTestSupport

@Suite("epub")
struct EPUBTests {
    let format = EPUBFormat()

    @Test("metadata comes from the OPF")
    func metadata() throws {
        var builder = EPUBBuilder()
        builder.authors = ["Albert Camus", "Stuart Gilbert"]
        let metadata = try format.readMetadata(from: try builder.build())
        #expect(metadata.title == "The Stranger")
        #expect(metadata.author == "Albert Camus, Stuart Gilbert")
        #expect(metadata.metadata.language == "en")
        #expect(metadata.metadata.identifier == "urn:uuid:1234")
    }

    @Test("epub 2 creators with a non-author role are skipped")
    func roles() throws {
        var builder = EPUBBuilder()
        builder.epub3 = false
        let data = try builder.build()
        let metadata = try format.readMetadata(from: data)
        #expect(metadata.author == "Albert Camus")
    }

    @Test("sniffing recognises the mimetype entry")
    func sniff() throws {
        let data = try EPUBBuilder().build()
        #expect(format.sniff(data.prefix(4096)))
        #expect(!format.sniff(Data("%PDF-1.7".utf8)))
    }

    @Test("text is extracted per spine section with TOC labels and locators")
    func text() throws {
        var builder = EPUBBuilder()
        builder.chapters = [
            ("Part One", "<p>Mother died today. Or maybe&nbsp;yesterday;&#160;I don&rsquo;t know.</p><script>var x = 1</script>"),
            ("Part Two", "<p>Caf&eacute; &amp; <i>sun</i> &#x2014; heat.</p><!-- a > comment --><p>Next</p>"),
        ]
        let chunks = try format.extractText(from: try builder.build())
        #expect(chunks.count == 2)
        #expect(chunks[0].label == "Part One")
        #expect(chunks[0].locator == Locator(scheme: EPUBLocators.sectionScheme, value: "0"))
        #expect(chunks[0].text == "Part One\nMother died today. Or maybe yesterday; I don’t know.")
        #expect(chunks[1].text == "Part Two\nCafé & sun — heat.\nNext")
    }

    @Test("epub 2 books use the NCX for labels")
    func ncx() throws {
        var builder = EPUBBuilder()
        builder.epub3 = false
        builder.chapters = [("Chapter One", "<p>a</p>"), ("Chapter Two", "<p>b</p>")]
        let package = try EPUBPackage(data: try builder.build())
        #expect(package.toc.map(\.label) == ["Chapter One", "Chapter Two"])
        #expect(package.toc[0].fragment == "start")
        #expect(package.label(forSpineIndex: 1) == "Chapter Two")
    }

    @Test("covers are found by EPUB 3 property or EPUB 2 meta")
    func covers() throws {
        for epub3 in [true, false] {
            var builder = EPUBBuilder()
            builder.epub3 = epub3
            builder.coverPNG = EPUBBuilder.tinyPNG
            let cover = try format.extractCover(from: try builder.build())
            #expect(cover == CoverImage(data: EPUBBuilder.tinyPNG, mimeType: "image/png"))
        }
        #expect(try format.extractCover(from: try EPUBBuilder().build()) == nil)
    }

    @Test("packages at the zip root resolve paths")
    func rootPackage() throws {
        var builder = EPUBBuilder()
        builder.opfDirectory = ""
        let package = try EPUBPackage(data: try builder.build())
        #expect(package.spine.first?.path == "text/chapter 1.xhtml")
    }

    @Test("paths resolve dot segments and percent escapes")
    func paths() {
        #expect(EPUBPackage.resolve("../Images/a%20b.png", against: "OEBPS/Text/") == "OEBPS/Images/a b.png")
        #expect(EPUBPackage.resolve("/abs.xhtml", against: "OEBPS/") == "abs.xhtml")
        #expect(EPUBPackage.resolve("./x.xhtml", against: "") == "x.xhtml")
    }

    @Test("non-epubs and broken epubs throw instead of crashing")
    func broken() throws {
        #expect(throws: EPUBError.notAnEPUB) { try format.readMetadata(from: Data("nope".utf8)) }
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", stored: true)
        #expect(throws: EPUBError.notAnEPUB) { try format.readMetadata(from: try zip.build()) }
        zip.add("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"missing.opf\"/></rootfiles></container>")
        #expect(throws: EPUBError.self) { try format.readMetadata(from: try zip.build()) }
    }

    @Test("an epub imports end to end with text search and a cover")
    func importsThroughCore() async throws {
        var builder = EPUBBuilder()
        builder.coverPNG = EPUBBuilder.tinyPNG
        builder.chapters = [("One", "<p>the sea was calm</p>"), ("Two", "<p>the trial began</p>")]
        let lib = TestLibrary(formats: [EPUBFormat()])
        let outcome = try await lib.services.imports.importData(try builder.build(), filename: "stranger.epub")
        #expect(outcome.document.kind == .epub)
        #expect(outcome.document.title == "The Stranger")
        let hits = try await lib.services.search.search("trial", in: .document(outcome.document.id, [.text]))
        #expect(hits.first?.hits.first?.title == "Two")
        #expect(try await lib.services.library.cover(of: outcome.document.id)?.mimeType == "image/png")
    }
}
