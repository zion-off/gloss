import Foundation
import Testing
@testable import GlossCore
import GlossTestSupport

@Suite("gloss:// links")
struct GlossLinkTests {
    let ids = SequentialIDGenerator()

    @Test("every link kind round-trips")
    func roundTrip() throws {
        let links: [GlossLink] = [.passage(ids.make()), .page(ids.make()), .document(ids.make())]
        for link in links {
            #expect(GlossLink(string: link.string) == link)
            #expect(GlossLink(link.url) == link)
        }
    }

    @Test("the textual form is short and readable")
    func format() {
        let id: PageID = ids.make()
        #expect(GlossLink.page(id).string == "gloss://page/\(id)")
        #expect(GlossLink.page(id).string.count == "gloss://page/".count + 26)
    }

    @Test("parsing tolerates case, trailing slashes, queries and fragments")
    func tolerant() {
        let id: LinkTargetID = ids.make()
        #expect(GlossLink(string: "GLOSS://Passage/\(id.stringValue.uppercased())/") == .passage(id))
        #expect(GlossLink(string: "gloss://passage/\(id)?from=cli#x") == .passage(id))
    }

    @Test("rejects foreign schemes, unknown kinds and bad ids")
    func rejects() {
        let id: PageID = ids.make()
        #expect(GlossLink(string: "https://page/\(id)") == nil)
        #expect(GlossLink(string: "gloss://chapter/\(id)") == nil)
        #expect(GlossLink(string: "gloss://page/not-an-id") == nil)
        #expect(GlossLink(string: "gloss://page/\(id)/extra") == nil)
        #expect(GlossLink(string: "gloss:page") == nil)
    }
}
