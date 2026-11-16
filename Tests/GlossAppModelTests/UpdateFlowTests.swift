import Foundation
import Testing
@testable import GlossAppModel

@MainActor
struct UpdateFlowTests {
    /// Records what the flow answered the updater.
    final class Replies {
        var choices: [UpdateFlow.Choice] = []
        var permissions: [Bool] = []
        var cancels = 0, acknowledgements = 0, retries = 0
    }

    func flow() -> (UpdateFlow, Replies) {
        (UpdateFlow(currentVersion: "1.4"), Replies())
    }

    func action(_ flow: UpdateFlow, _ title: String) -> UpdateFlow.Action {
        guard let action = flow.actions.first(where: { $0.title == title }) else {
            Issue.record("no \(title) in \(flow.actions.map(\.title))")
            return flow.actions[0]
        }
        return action
    }

    let offer = UpdateFlow.Offer(version: "1.5", notes: [.paragraph("new things")])

    @Test("update goes from the offer through the download to the relaunch without asking twice")
    func updateRunsThrough() {
        let (flow, replies) = flow()
        var presented: [Bool] = []
        flow.onPresentationChange = { presented.append($0) }
        flow.showUpdateFound(offer) { replies.choices.append($0) }
        #expect(flow.title == "gloss 1.5 is here")
        #expect(flow.detail == "you have 1.4. updating relaunches gloss.")
        #expect(flow.actions.map(\.title) == ["skip this version", "later", "update"])
        #expect(flow.actions.map(\.role) == [.leading, .cancel, .primary])
        #expect(flow.notes == [.paragraph("new things")])

        flow.perform(action(flow, "update"))
        #expect(replies.choices == [.install])
        #expect(flow.title == "downloading gloss 1.5…" && flow.progress == .indeterminate)

        flow.showDownloadStarted { replies.cancels += 1 }
        flow.showExpectedLength(12_000_000)
        flow.showReceived(3_000_000)
        flow.showReceived(100_000)
        #expect(flow.detail == "3.1 MB of 12.0 MB")
        #expect(flow.progress == .fraction(3_100_000.0 / 12_000_000.0))
        #expect(flow.actions.map(\.title) == ["cancel"])

        flow.showPreparing()
        #expect(flow.title == "getting gloss 1.5 ready…" && flow.progress == .indeterminate && flow.actions.isEmpty)
        flow.showPreparing(progress: 0.5)
        #expect(flow.progress == .fraction(0.5))

        flow.showReadyToRelaunch { replies.choices.append($0) }
        #expect(replies.choices == [.install, .install])  // answered for the user who said update
        #expect(flow.title == "installing gloss 1.5…")
        #expect(replies.cancels == 0)  // the download's cancel went with its step
        #expect(presented == [true])
    }

    @Test("later and skip answer once and close; the close button is later")
    func laterAndSkip() {
        let (flow, replies) = flow()
        flow.showUpdateFound(offer) { replies.choices.append($0) }
        flow.perform(action(flow, "skip this version"))
        #expect(replies.choices == [.skip] && !flow.isPresented && flow.phase == .idle)

        flow.showUpdateFound(offer) { replies.choices.append($0) }
        flow.close()
        #expect(replies.choices == [.skip, .later] && !flow.isPresented)
        flow.close()  // nothing left to answer
        #expect(replies.choices == [.skip, .later])
    }

    @Test("an update downloaded in the background asks before relaunching")
    func backgroundReady() {
        let (flow, replies) = flow()
        flow.showReadyToRelaunch { replies.choices.append($0) }
        #expect(flow.title == "the update is ready")  // no offer was shown to name it
        #expect(flow.isPresented && flow.actions.map(\.title) == ["later", "relaunch"])
        #expect(flow.detail == "relaunch now, or it installs the next time you quit.")
        flow.perform(action(flow, "later"))
        #expect(replies.choices == [.later] && !flow.isPresented)

        let downloaded = UpdateFlow.Offer(version: "1.5", isDownloaded: true)
        flow.showUpdateFound(downloaded) { replies.choices.append($0) }
        #expect(flow.detail == "you have 1.4. it's downloaded: updating relaunches gloss.")
        flow.perform(action(flow, "update"))
        #expect(replies.choices == [.later, .install] && flow.title == "installing gloss 1.5…")
    }

    @Test("checking can be cancelled; a step that arrives drops the last one's replies")
    func checkingAndStaleReplies() {
        let (flow, replies) = flow()
        flow.showChecking { replies.cancels += 1 }
        #expect(flow.title == "checking for updates…" && flow.progress == .indeterminate)
        flow.close()
        #expect(replies.cancels == 1 && !flow.isPresented)

        flow.showChecking { replies.cancels += 1 }
        flow.showUpToDate { replies.acknowledgements += 1 }
        #expect(flow.title == "you're up to date" && flow.detail == "gloss 1.4 is the newest version.")
        flow.close()  // ok
        #expect(replies.cancels == 1 && replies.acknowledgements == 1)

        flow.showUpToDate(detail: "this mac's macos is too old for the newest gloss.") { replies.acknowledgements += 1 }
        #expect(flow.detail == "this mac's macos is too old for the newest gloss.")
        flow.showFailure("The update couldn't be verified.") { replies.acknowledgements += 1 }
        #expect(flow.title == "couldn't update" && flow.detail == "The update couldn't be verified.")
        flow.perform(action(flow, "ok"))
        #expect(replies.acknowledgements == 2)  // the replaced up-to-date never answered
    }

    @Test("closing a step that runs on its own hides the window; the next step brings it back")
    func hideWhilePreparing() {
        let (flow, replies) = flow()
        flow.showUpdateFound(offer) { replies.choices.append($0) }
        flow.perform(action(flow, "update"))
        flow.showPreparing()
        flow.close()
        #expect(!flow.isPresented && flow.title == "getting gloss 1.5 ready…")
        flow.showInFocus()
        #expect(flow.isPresented)
        flow.showInstalling(applicationTerminated: false) { replies.retries += 1 }
        #expect(flow.detail == "gloss didn't quit. close what's open and try again.")
        flow.perform(action(flow, "try again"))
        #expect(replies.retries == 1)
        flow.dismiss()
        #expect(!flow.isPresented && flow.phase == .idle && flow.actions.isEmpty)
    }

    @Test("asked to check automatically, either answer is passed on once")
    func permission() {
        let (flow, replies) = flow()
        flow.showPermissionRequest { replies.permissions.append($0) }
        #expect(flow.title == "check for updates automatically?")
        #expect(flow.actions.map(\.title) == ["don't check", "check automatically"])
        flow.perform(action(flow, "check automatically"))
        flow.showPermissionRequest { replies.permissions.append($0) }
        flow.close()
        #expect(replies.permissions == [true, false])
    }

    @Test("an announcement opens its page instead of installing")
    func announcement() {
        let (flow, replies) = flow()
        var opened: [URL] = []
        flow.openURL = { opened.append($0) }
        let url = URL(string: "https://example.com/gloss")!
        flow.showUpdateFound(UpdateFlow.Offer(version: "2.0", infoURL: url)) { replies.choices.append($0) }
        #expect(flow.actions.map(\.title) == ["skip this version", "later", "learn more"])
        flow.perform(action(flow, "learn more"))
        #expect(opened == [url] && replies.choices == [.later])
    }

    @Test("all copy is lowercase except what the updater says")
    func lowercase() {
        let (flow, _) = flow()
        var copy: [String] = []
        func collect() { copy += [flow.title, flow.detail ?? ""] + flow.actions.map(\.title) }
        flow.showPermissionRequest { _ in }; collect()
        flow.showChecking {}; collect()
        flow.showUpdateFound(offer) { _ in }; collect()
        flow.showReadyToRelaunch { _ in }; collect()
        flow.showUpToDate {}; collect()
        #expect(copy.allSatisfy { $0 == $0.lowercased() })
    }

    @Test("sizes read like Finder's")
    func sizes() {
        #expect(UpdateFlow.size(512) == "512 bytes")
        #expect(UpdateFlow.size(820_000) == "820 KB")
        #expect(UpdateFlow.size(12_345_678) == "12.3 MB")
        #expect(UpdateFlow.size(2_500_000_000) == "2.5 GB")
    }
}

struct ReleaseNotesTests {
    @Test("the appcast's markdown: headings, items, numbered steps and paragraphs")
    func markdown() {
        let notes = """
        ## what changes

        - **spell check in your notes.** misspelled words get underlined,
        and autocorrect follows your mac.
        - search highlights stay.
          - nested detail

        ## to try

        1. open a book.
        2. press ⇧⌘H.

        thanks for reading
        all of it.
        """
        #expect(ReleaseNotes.blocks(notes, format: "markdown") == [
            .heading("what changes"),
            .item(marker: "•", text: "**spell check in your notes.** misspelled words get underlined, and autocorrect follows your mac.", level: 0),
            .item(marker: "•", text: "search highlights stay.", level: 0),
            .item(marker: "•", text: "nested detail", level: 1),
            .heading("to try"),
            .item(marker: "1.", text: "open a book.", level: 0),
            .item(marker: "2.", text: "press ⇧⌘H.", level: 0),
            .paragraph("thanks for reading all of it."),
        ])
    }

    @Test("html and plain text notes read too, their own markup characters kept as text")
    func otherFormats() {
        let html = "<h2>New</h2><ul><li><b>Faster</b> search</li><li>a &amp; b</li></ul><p>Thanks *all*</p>"
        #expect(ReleaseNotes.blocks(html, format: nil) == [
            .heading("New"), .item(marker: "•", text: "Faster search", level: 0), .item(marker: "•", text: "a & b", level: 0),
            .paragraph("Thanks \\*all\\*"),
        ])
        #expect(ReleaseNotes.blocks("one\nline\n\ntwo", format: "plain") == [.paragraph("one line"), .paragraph("two")])
        #expect(ReleaseNotes.blocks("just text, no tags", format: "html") == [.paragraph("just text, no tags")])
    }
}
