import Foundation
import Testing
@testable import GlossReaderBridge

/// The shared cases: the reader's TypeScript twin (web/test/selection.test.ts) runs the same
/// file, so EPUB and PDF popovers point at the same place for the same selection.
@Suite("selection anchor")
struct SelectionAnchorTests {
    struct Case: Decodable {
        struct Point: Decodable { var x: Double; var y: Double }
        var name: String
        var lines: [ReaderRect]
        var pointer: Point?
        var backward: Bool
        var expected: ReaderRect?
    }

    static let cases: [Case] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bridge/selection-anchor.json")
        return (try? JSONDecoder().decode([Case].self, from: Data(contentsOf: url))) ?? []
    }()

    @Test("the shared cases")
    func sharedCases() {
        #expect(Self.cases.count >= 10)
        for item in Self.cases {
            let pointer = item.pointer.map { SelectionAnchor.Point(x: $0.x, y: $0.y) }
            #expect(SelectionAnchor.rect(lines: item.lines, pointer: pointer, backward: item.backward) == item.expected, "\(item.name)")
        }
    }
}
