import Foundation
import Testing
@testable import GlossReaderBridge

@Suite("reader navigation policy")
struct ReaderNavigationPolicyTests {
    func allows(_ string: String?, _ target: ReaderNavigationPolicy.Target) -> Bool {
        ReaderNavigationPolicy.allows(string.flatMap(URL.init(string:)), target: target)
    }

    @Test("the main frame only ever shows the reader page")
    func mainFrame() {
        #expect(allows("gloss-reader://app/index.html", .mainFrame))
        #expect(allows("GLOSS-READER://APP/index.html", .mainFrame))
        for url in ["gloss-reader://app/book/01m78xptr8fa4r6vwtr0f789s9", "gloss-reader://app/glue.js", "gloss-reader://other/index.html",
                    "https://example.com/", "file:///etc/passwd", "blob:gloss-reader://app/1234", "about:blank", "javascript:alert(1)"] {
            #expect(!allows(url, .mainFrame), "\(url)")
        }
        #expect(!allows(nil, .mainFrame))
    }

    @Test("book sections load in frames as blob documents; nothing else does")
    func subframes() {
        #expect(allows("blob:gloss-reader://app/0f3c1b9e-5a1d-4c8e-9f00-1b2c3d4e5f60", .subframe))
        #expect(allows("about:blank", .subframe))
        #expect(allows("about:srcdoc", .subframe))
        for url in ["https://example.com/", "gloss-reader://app/book/x", "file:///tmp/x.html", "data:text/html,<p>x</p>", "javascript:x()"] {
            #expect(!allows(url, .subframe), "\(url)")
        }
    }

    @Test("new windows never open")
    func newWindows() {
        #expect(!allows("gloss-reader://app/index.html", .newWindow))
        #expect(!allows("https://example.com/", .newWindow))
    }
}
