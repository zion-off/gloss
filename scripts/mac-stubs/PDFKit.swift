// Stand-in for PDFKit, for scripts/mac-typecheck.py (D-099). Declarations copied from Apple's
// documentation JSON (documentation/pdfkit/...), as recorded in docs/MAC_API_NOTES.md. PDFKit's
// classes and protocols carry no actor annotation in the docs; `PDFView` is an NSView subclass
// and so main-actor isolated by inheritance.

import AppKit

/// pdfkit/pdfdisplaybox
public enum PDFDisplayBox: Int, Sendable { case mediaBox, cropBox, bleedBox, trimBox, artBox }
/// pdfkit/pdfdisplaymode
public enum PDFDisplayMode: Int, Sendable { case singlePage, singlePageContinuous, twoUp, twoUpContinuous }
/// pdfkit/pdfdisplaydirection (macOS 10.13+)
public enum PDFDisplayDirection: Int, Sendable { case vertical, horizontal }

/// pdfkit/pdfpage
open class PDFPage: NSObject {
    open var string: String? { nil }
    open var label: String? { nil }
    @discardableResult open func selection(for range: NSRange) -> PDFSelection? { nil }
    @discardableResult open func selection(for rect: NSRect) -> PDFSelection? { nil }
    @discardableResult open func thumbnail(of size: NSSize, for box: PDFDisplayBox) -> NSImage { fatalError() }
    @discardableResult open func bounds(for box: PDFDisplayBox) -> NSRect { .zero }
    @discardableResult open func characterIndex(at point: NSPoint) -> Int { 0 }
}

/// pdfkit/pdfselection
open class PDFSelection: NSObject {
    open var string: String? { nil }
    open var pages: [PDFPage] { [] }
    @discardableResult open func selectionsByLine() -> [PDFSelection] { [] }
    @discardableResult open func bounds(for page: PDFPage) -> NSRect { .zero }
    @discardableResult open func numberOfTextRanges(on page: PDFPage) -> Int { 0 }
    @discardableResult open func range(at index: Int, on page: PDFPage) -> NSRange { NSRange(location: 0, length: 0) }
}

/// pdfkit/pdfdestination
open class PDFDestination: NSObject {
    public init(page: PDFPage, at point: NSPoint) {}
    open var page: PDFPage? { nil }
}

/// pdfkit/pdfoutline
open class PDFOutline: NSObject {
    open var numberOfChildren: Int { 0 }
    @discardableResult open func child(at index: Int) -> PDFOutline? { nil }
    open var label: String? { get { nil } set {} }
    open var destination: PDFDestination? { get { nil } set {} }
}

/// pdfkit/pdfdocument
open class PDFDocument: NSObject {
    public init?(data: Data) {}
    open var pageCount: Int { 0 }
    @discardableResult open func page(at index: Int) -> PDFPage? { nil }
    @discardableResult open func index(for page: PDFPage) -> Int { 0 }
    /// macOS 10.6+
    open var outlineRoot: PDFOutline? { get { nil } set {} }
    @discardableResult open func findString(_ string: String, withOptions options: NSString.CompareOptions = []) -> [PDFSelection] { [] }
}

/// pdfkit/pdfviewdelegate — not isolated; every requirement optional
public protocol PDFViewDelegate: NSObjectProtocol {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL)
}
extension PDFViewDelegate {
    public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
}

/// pdfkit/pdfpageoverlayviewprovider — macOS 13.0+, not isolated
public protocol PDFPageOverlayViewProvider: NSObjectProtocol {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView?
    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage)
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage)
}
extension PDFPageOverlayViewProvider {
    public func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {}
    public func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {}
}

/// pdfkit/pdfview — `class PDFView` (an NSView subclass)
@MainActor open class PDFView: NSView {
    open var document: PDFDocument? { get { nil } set {} }
    open var currentPage: PDFPage? { nil }
    open var currentSelection: PDFSelection? { get { nil } set {} }
    open func setCurrentSelection(_ selection: PDFSelection?, animate: Bool) {}
    open var highlightedSelections: [PDFSelection]? { get { nil } set {} }
    open var delegate: (any PDFViewDelegate)? { get { nil } set {} }
    /// macOS 13.0+
    open var pageOverlayViewProvider: (any PDFPageOverlayViewProvider)? { get { nil } set {} }
    open var backgroundColor: NSColor { get { .textBackgroundColor } set {} }
    open var autoScales: Bool { get { false } set {} }
    open var displayMode: PDFDisplayMode { get { .singlePage } set {} }
    open var displaysPageBreaks: Bool { get { true } set {} }
    open var displayDirection: PDFDisplayDirection { get { .vertical } set {} }
    open func go(to page: PDFPage) {}
    open func go(to destination: PDFDestination) {}
    open func go(to selection: PDFSelection) {}
    open func go(to rect: NSRect, on page: PDFPage) {}
    open func goToNextPage(_ sender: Any?) {}
    open func goToPreviousPage(_ sender: Any?) {}
    @discardableResult open func page(for point: NSPoint, nearest: Bool) -> PDFPage? { nil }
    open func clearSelection() {}
    @discardableResult open func convert(_ point: NSPoint, from page: PDFPage) -> NSPoint { point }
    @discardableResult open func convert(_ rect: NSRect, from page: PDFPage) -> NSRect { rect }
    @discardableResult open func convert(_ rect: NSRect, to page: PDFPage) -> NSRect { rect }
    @discardableResult open func convert(_ point: NSPoint, to page: PDFPage) -> NSPoint { point }
}

extension Notification.Name {
    /// pdfkit/pdfviewpagechangednotification — the JSON only carries the ObjC extern; this is
    /// the importer's standard Swift spelling (UNVERIFIED, MAC_API_NOTES.md).
    public static let PDFViewPageChanged = Notification.Name("PDFViewChangedPage")
    public static let PDFViewSelectionChanged = Notification.Name("PDFViewSelectionChanged")
}
