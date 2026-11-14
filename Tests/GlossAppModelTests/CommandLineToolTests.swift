import Testing
@testable import GlossAppModel

@Suite("command line tool link")
struct CommandLineToolTests {
    struct Disk: LinkFileSystem {
        var links: [String: String] = [:]
        var files: Set<String> = []
        func linkDestination(atPath path: String) -> String? { links[path] }
        func exists(atPath path: String) -> Bool { links[path] != nil || files.contains(path) }
    }

    static let link = "/usr/local/bin/gloss"
    static let helper = "/Applications/gloss.app/Contents/Helpers/gloss"

    func tool(helper: String? = CommandLineToolTests.helper, _ disk: Disk) -> CommandLineTool {
        CommandLineTool(helperPath: helper, files: disk)
    }

    @Test("the five states, the action for each, and which are replaceable")
    func states() {
        let cases: [(Disk, String?, CommandLineTool.State, replaceable: Bool, install: Bool?)] = [
            (Disk(), nil, .unavailable, false, nil),
            (Disk(), Self.helper, .notInstalled, true, false),
            (Disk(links: [Self.link: Self.helper]), Self.helper, .installed, true, nil),
            (Disk(links: [Self.link: "/Users/me/Downloads/gloss.app/Contents/Helpers/gloss"]), Self.helper,
             .linkedElsewhere("/Users/me/Downloads/gloss.app/Contents/Helpers/gloss"), true, true),
            (Disk(links: [Self.link: "/opt/other/gloss"]), Self.helper, .linkedElsewhere("/opt/other/gloss"), false, nil),
            (Disk(files: [Self.link]), Self.helper, .blockedByOtherFile, false, nil),
        ]
        for (disk, helper, state, replaceable, install) in cases {
            let tool = tool(helper: helper, disk)
            #expect(tool.state == state)
            #expect(tool.isReplaceable == replaceable)
            switch (tool.action, install) {
            case (.install(_, _, let replacing), let expected?): #expect(replacing == expected)
            case (.remove, nil) where state == .installed: break
            case (.none, nil) where state == .unavailable: break
            case (.refuse(let why), nil): #expect(why.contains(Self.link))
            default: Issue.record("unexpected action \(tool.action) for \(state)")
            }
        }
        #expect(tool(Disk(links: [Self.link: Self.helper])).menuTitle == "remove command line tool")
        #expect(tool(helper: nil, Disk()).isEnabled == false)
    }

    @Test("a relative link to this helper counts as installed")
    func relative() {
        let tool = CommandLineTool(helperPath: "/usr/local/gloss.app/Contents/Helpers/gloss",
                                   files: Disk(links: [Self.link: "../gloss.app/Contents/Helpers/gloss"]))
        #expect(tool.state == .installed)
    }
}
