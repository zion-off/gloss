import Foundation
import Testing
@testable import GlossReaderBridge
import GlossCore

@MainActor
@Suite("reader event inbox")
struct ReaderEventInboxTests {
    /// Records when each delivery starts and ends.
    @MainActor final class Log {
        var entries: [String] = []
    }

    func location(_ value: String) -> ReaderEngineEvent {
        .relocated(ReaderLocation(locator: Locator(scheme: LocatorScheme("test"), value: value), progression: 0, label: nil, progressText: ""))
    }

    @Test("events are delivered in order, one at a time")
    func ordered() async {
        let log = Log()
        let inbox = ReaderEventInbox { event in
            let name = if case .relocated(let location) = event { location.locator.value } else { "\(event)" }
            log.entries.append("start \(name)")
            // A slow handler: the next event must still wait for it.
            for _ in 0..<5 { await Task.yield() }
            log.entries.append("end \(name)")
        }
        inbox.post(.ready)
        inbox.post(location("a"))
        inbox.post(location("b"))
        await inbox.closeAndDrain()
        #expect(log.entries == ["start ready", "end ready", "start a", "end a", "start b", "end b"])
    }

    @Test("a closed inbox drops new events but delivers the queued ones")
    func closed() async {
        let log = Log()
        let inbox = ReaderEventInbox { event in log.entries.append("\(event)") }
        inbox.post(.ready)
        inbox.close()
        inbox.post(.selectionCleared)
        await inbox.closeAndDrain()
        #expect(log.entries == ["ready"])
    }
}
