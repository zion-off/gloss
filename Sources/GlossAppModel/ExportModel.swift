import Foundation
import Observation
import GlossCore
import GlossExport

    /// Export and print state for one window: turns an export request into bytes with a sensible
    /// file name, and remembers the last failure for a small alert. The composition root hands in
    /// the `ExportService` (the same one the cli wires); without one, exporting is unavailable.
    @MainActor @Observable public final class ExportModel {
    /// Notes as one markdown file, ready for a save panel.
    public struct ExportedNotes: Equatable, Sendable {
        public var data: Data
        public var filename: String

        public init(data: Data, filename: String) {
            self.data = data
            self.filename = filename
        }
    }

    /// Notes as standalone html with the print stylesheet, ready for the print panel.
    public struct PrintableNotes: Equatable, Sendable {
        public var html: String
        public var title: String

        public init(html: String, title: String) {
            self.html = html
            self.title = title
        }
    }

    /// The last failure to tell the user about; the window shows it in a small alert.
    public private(set) var failure: String?

    private let service: ExportService?

    public init(service: ExportService?) {
        self.service = service
    }

    public var isAvailable: Bool { service != nil }

    public func clearFailure() { failure = nil }

    /// A failure that happened outside this model (writing the file the save panel chose).
    public func recordFailure(_ message: String) { failure = message }

    /// A book's whole notes tree as one markdown file.
    public func exportBookNotes(of document: DocumentID) async -> ExportedNotes? {
        await export(.document(document))
    }

    /// One notes page, with or without the pages inside it.
    public func exportPage(_ page: PageID, includeSubpages: Bool) async -> ExportedNotes? {
        await export(.page(page, includeSubpages: includeSubpages))
    }

    private func export(_ scope: ExportScope) async -> ExportedNotes? {
        guard let service else {
            failure = "exporting isn't set up"
            return nil
        }
        do {
            let file = try await service.export(scope, as: .markdown)
            return ExportedNotes(data: file.data, filename: file.filename)
        } catch {
            failure = (error as? GlossError)?.description ?? "couldn't export these notes"
            return nil
        }
    }

    /// The notes to print (⌘P): the open page and the pages inside it, rendered by the html
    /// exporter whose stylesheet is built for the print panel.
    public func printablePage(_ page: PageID, includeSubpages: Bool) async -> PrintableNotes? {
        guard let service else {
            failure = "printing isn't set up"
            return nil
        }
        do {
            let file = try await service.export(.page(page, includeSubpages: includeSubpages), as: .html)
            let title = (file.filename as NSString).deletingPathExtension
            return PrintableNotes(html: String(decoding: file.data, as: UTF8.self), title: title)
        } catch {
            failure = (error as? GlossError)?.description ?? "couldn't get these notes ready to print"
            return nil
        }
    }
}
