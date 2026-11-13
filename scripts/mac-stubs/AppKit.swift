// Stand-in for AppKit, for scripts/mac-typecheck.py (D-099). Declarations only: every member
// here was copied from the Swift declaration tokens of Apple's documentation JSON
// (developer.apple.com/tutorials/data/documentation/appkit/...), the same source as
// docs/MAC_API_NOTES.md. Isolation follows the docs: NSResponder, NSView and NSWindow are
// `@MainActor` classes (subclasses inherit it); NSColor, NSFont, NSImage, NSEvent, NSBezierPath
// and the TextKit 2 element/layout classes are not. Add a member only after checking its page.
//
// Methods returning a value are `@discardableResult`: Swift never warns about unused results of
// imported Objective-C methods, and these stand in for imported ones.
//
// Also here: the few Darwin Foundation and CoreGraphics APIs that swift-corelibs-foundation
// lacks (AppKit re-exports both on a Mac).

@_exported import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking  // URLRequest, URLResponse: part of Foundation on Darwin
#endif
import UniformTypeIdentifiers  // UTType (NSSavePanel.allowedContentTypes)

// MARK: - Darwin Foundation / CoreGraphics (not in swift-corelibs-foundation)

/// Objective-C selectors (`#selector` is rewritten to `_glossSelector`, which returns one).
public struct Selector: Hashable, Sendable {
    public init(_ name: String) {}
}

/// coregraphics/cgcontext
open class CGContext {}

extension NotificationCenter {
    /// foundation/notificationcenter/addobserver(_:selector:name:object:)
    public func addObserver(_ observer: Any, selector aSelector: Selector, name aName: NSNotification.Name?, object anObject: Any?) {}
}

/// foundation/undomanager — `@MainActor class UndoManager` (Darwin only)
@MainActor open class UndoManager: NSObject {
    /// foundation/undomanager/registerundo(withtarget:handler:) — macOS 10.11+
    @MainActor @preconcurrency public func registerUndo<TargetType: AnyObject>(withTarget target: TargetType, handler: @escaping @MainActor (TargetType) -> Void) {}
    open func setActionName(_ actionName: String) {}
    open func removeAllActions() {}
    open func undo() {}
    open func redo() {}
    open var canUndo: Bool { false }
    open var canRedo: Bool { false }
}

// MARK: - Responders, views, windows

/// appkit/nsresponder — `@MainActor class NSResponder`
@MainActor open class NSResponder: NSObject {
    public override init() {}
    open var undoManager: UndoManager? { nil }
    open func mouseDown(with event: NSEvent) {}
    open func mouseMoved(with event: NSEvent) {}
    open func mouseExited(with event: NSEvent) {}
    open func keyDown(with event: NSEvent) {}
    @discardableResult open func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    @discardableResult open func becomeFirstResponder() -> Bool { true }
    @discardableResult open func resignFirstResponder() -> Bool { true }
    // Standard key bindings (NSStandardKeyBindingResponding), matched in doCommandBy.
    open func insertNewline(_ sender: Any?) {}
    open func insertTab(_ sender: Any?) {}
    open func insertBacktab(_ sender: Any?) {}
    open func cancelOperation(_ sender: Any?) {}
    open func moveUp(_ sender: Any?) {}
    open func moveDown(_ sender: Any?) {}
}

/// appkit/nsview — `@MainActor class NSView`
@MainActor open class NSView: NSResponder {
    public init(frame frameRect: NSRect) { super.init() }
    public required init?(coder: NSCoder) { super.init() }
    /// `NSView()`: NSObject's `init` reaches `init(frame:)` with a zero rect.
    public convenience override init() { self.init(frame: .zero) }
    open var frame: NSRect { get { .zero } set {} }
    open var bounds: NSRect { get { .zero } set {} }
    open var isFlipped: Bool { false }
    open var needsDisplay: Bool { get { false } set {} }
    open var window: NSWindow? { nil }
    open var superview: NSView? { nil }
    open var postsBoundsChangedNotifications: Bool { get { false } set {} }
    public static let boundsDidChangeNotification = NSNotification.Name("NSViewBoundsDidChangeNotification")
    open func addSubview(_ view: NSView) {}
    open func removeFromSuperview() {}
    /// `point` is in the **superview's** coordinate system (per the docs).
    @discardableResult open func hitTest(_ point: NSPoint) -> NSView? { nil }
    open func draw(_ dirtyRect: NSRect) {}
    open func scroll(_ point: NSPoint) {}
    @discardableResult open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint { point }
    @discardableResult open func convert(_ point: NSPoint, to view: NSView?) -> NSPoint { point }
    @discardableResult open func convert(_ rect: NSRect, from view: NSView?) -> NSRect { rect }
    @discardableResult open func convert(_ rect: NSRect, to view: NSView?) -> NSRect { rect }
    open func updateTrackingAreas() {}
    open func addTrackingArea(_ trackingArea: NSTrackingArea) {}
    open func removeTrackingArea(_ trackingArea: NSTrackingArea) {}
    open var trackingAreas: [NSTrackingArea] { [] }
}

/// appkit/nswindow — `@MainActor class NSWindow`
@MainActor open class NSWindow: NSResponder {
    @discardableResult open func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
    @discardableResult open func convertFromScreen(_ rect: NSRect) -> NSRect { rect }
}

/// appkit/nsviewcontroller — an NSResponder subclass (main actor by inheritance)
@MainActor open class NSViewController: NSResponder {}

/// appkit/nsevent — `class NSEvent` (not main-actor isolated)
open class NSEvent: NSObject {
    open var locationInWindow: NSPoint { .zero }
}

/// appkit/nstrackingarea
open class NSTrackingArea: NSObject {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static var mouseEnteredAndExited: NSTrackingArea.Options { .init(rawValue: 1) }
        public static var mouseMoved: NSTrackingArea.Options { .init(rawValue: 2) }
        public static var activeInKeyWindow: NSTrackingArea.Options { .init(rawValue: 0x20) }
        public static var inVisibleRect: NSTrackingArea.Options { .init(rawValue: 0x200) }
    }
    public init(rect: NSRect, options: NSTrackingArea.Options = [], owner: Any?, userInfo: [AnyHashable: Any]? = nil) {}
}

/// appkit/nsclipview
@MainActor open class NSClipView: NSView {}

/// appkit/nsscrollview
@MainActor open class NSScrollView: NSView {
    open var documentView: NSView? { get { nil } set {} }
    open var contentView: NSClipView { get { fatalError() } set {} }
    open var hasVerticalScroller: Bool { get { false } set {} }
    open var hasHorizontalScroller: Bool { get { false } set {} }
    open var autohidesScrollers: Bool { get { false } set {} }
}

/// appkit/nspopover — an NSResponder subclass
@MainActor open class NSPopover: NSResponder {
    public enum Behavior: Int, Sendable { case applicationDefined, transient, semitransient }
    open var behavior: NSPopover.Behavior { get { .applicationDefined } set {} }
    open var animates: Bool { get { true } set {} }
    open var contentViewController: NSViewController? { get { nil } set {} }
    open var isShown: Bool { false }
    open func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {}
    open func close() {}
    open func performClose(_ sender: Any?) {}
}

/// appkit/nsworkspace
open class NSWorkspace: NSObject {
    open class var shared: NSWorkspace { NSWorkspace() }
    @discardableResult open func open(_ url: URL) -> Bool { true }
    /// appkit/nsworkspace/activatefileviewerselecting(_:) (macOS 10.6+)
    open func activateFileViewerSelecting(_ fileURLs: [URL]) {}
}

/// appkit/nsapplication
@MainActor open class NSApplication: NSResponder {
    public class var shared: NSApplication { fatalError() }
    open func activate() {}
    /// appkit/nsapplication/keywindow — `weak var keyWindow: NSWindow? { get }`
    open var keyWindow: NSWindow? { nil }
    /// appkit/nsapplication/modalresponse — `struct ModalResponse`
    public struct ModalResponse: Equatable, Sendable {
        public let rawValue: UInt
        public init(_ rawValue: UInt) { self.rawValue = rawValue }
        /// appkit/nsapplication/modalresponse/cancel
        public static let cancel = ModalResponse(0)
        /// appkit/nsapplication/modalresponse/ok — the Swift name is `OK` (a Mac build rejected `.ok`)
        public static let OK = ModalResponse(1)
    }
}

// MARK: - Open and save panels

/// appkit/nssavepanel — `@MainActor class NSSavePanel`. `NSSavePanel()`/`NSOpenPanel()` have no
/// initializer page of their own (NSObject's `init` reaches them); Apple's sample code calls
/// them, like `WKWebViewConfiguration()` (see MAC_API_NOTES).
@MainActor open class NSSavePanel: NSResponder {
    /// appkit/nssavepanel/allowedcontenttypes (macOS 11)
    open var allowedContentTypes: [UTType] { get { fatalError() } set {} }
    /// appkit/nssavepanel/message — `var message: String!`
    open var message: String! { get { "" } set {} }
    /// appkit/nssavepanel/prompt — `var prompt: String!`
    open var prompt: String! { get { "" } set {} }
    /// appkit/nssavepanel/beginsheetmodal(for:completionhandler:) (macOS 10.6). The docs show
    /// no isolation on the handler; it runs on the main thread (AppKit), so the stub — like
    /// other AppKit completions here — models it as @MainActor. The page also lists the
    /// `async` overload (`func beginSheetModal(for:) async -> NSApplication.ModalResponse`).
    open func beginSheetModal(for window: NSWindow, completionHandler handler: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {}
    /// appkit/nssavepanel/beginsheetmodal(for:) — the async overload from the same docs page.
    open func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse { .cancel }
    /// appkit/nssavepanel/runmodal()
    open func runModal() -> NSApplication.ModalResponse { fatalError() }
    /// appkit/nssavepanel/namefieldstringvalue
    open var nameFieldStringValue: String { get { "" } set {} }
    /// appkit/nssavepanel/cancreatedirectories
    open var canCreateDirectories: Bool { get { true } set {} }
    /// appkit/nssavepanel/url — `var url: URL? { get }`
    open var url: URL? { nil }
    /// appkit/nssavepanel/directoryurl (macOS 10.6+)
    open var directoryURL: URL? { get { nil } set {} }
}

/// appkit/nsprintinfo — `class NSPrintInfo` (the docs pages carry no availability; AppKit since
/// 10.0). `NSPrintInfo()` has no initializer page of its own (NSObject's `init` reaches it).
open class NSPrintInfo {
    /// appkit/nsprintinfo/shared
    public class var shared: NSPrintInfo { get { fatalError() } set {} }
}

/// appkit/nsprintoperation — `@MainActor class NSPrintOperation`
@MainActor open class NSPrintOperation {
    /// appkit/nsprintoperation/init(view:printinfo:)
    public init(view: NSView, printInfo: NSPrintInfo) {}
    /// appkit/nsprintoperation/run() — "Runs the print operation on the current thread."
    @discardableResult public func run() -> Bool { false }
    /// appkit/nsprintoperation/runmodal(for:delegate:didrun:contextinfo:)
    public func runModal(for docWindow: NSWindow, delegate: Any?, didRun didRunSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {}
    /// appkit/nsprintoperation/showsprintpanel
    public var showsPrintPanel: Bool { get { true } set {} }
    /// appkit/nsprintoperation/jobtitle
    public var jobTitle: String? { get { nil } set {} }
}

/// appkit/nsopenpanel — `class NSOpenPanel`
@MainActor open class NSOpenPanel: NSSavePanel {
    /// appkit/nsopenpanel/canchoosefiles
    open var canChooseFiles: Bool { get { false } set {} }
    /// appkit/nsopenpanel/canchoosedirectories
    open var canChooseDirectories: Bool { get { false } set {} }
    /// appkit/nsopenpanel/allowsmultipleselection
    open var allowsMultipleSelection: Bool { get { false } set {} }
    /// appkit/nsopenpanel/urls
    open var urls: [URL] { [] }
}

// MARK: - Drag and drop (Foundation on Darwin; corelibs Foundation has no NSItemProvider)

/// foundation/nsitemproviderreading
public protocol NSItemProviderReading: NSObjectProtocol {}

/// foundation/nsitemprovider — `class NSItemProvider` (macOS 10.10). The generic members below
/// are documented with a `T : _ObjectiveCBridgeable, T._ObjectiveCType : NSItemProviderReading`
/// constraint (URL qualifies on a Mac); the stub drops that underscored constraint because
/// corelibs Foundation on Linux has no `_ObjectiveCBridgeable`. Use them only with bridged
/// types (URL, String).
open class NSItemProvider: NSObject {
    /// foundation/nsitemprovider/canloadobject(ofclass:)-40grc (macOS 10.13)
    public func canLoadObject<T>(ofClass: T.Type) -> Bool { false }
    /// foundation/nsitemprovider/loadobject(ofclass:completionhandler:)-6pysm (macOS 10.13)
    public func loadObject<T>(ofClass: T.Type, completionHandler: @escaping @Sendable (T?, (any Error)?) -> Void) -> Progress { fatalError() }
}

/// appkit/nsaccessibility-swift.struct — `struct NSAccessibility` (the Swift-side API).
public struct NSAccessibility {
    /// appkit/nsaccessibility-swift.struct/post(element:notification:userinfo:) (macOS 10.7+)
    public static func post(element: Any, notification: NSAccessibility.Notification, userInfo: [NSAccessibility.NotificationUserInfoKey : Any]?) {}
    /// appkit/nsaccessibility-swift.struct/notification — `struct Notification`
    public struct Notification: Hashable, Sendable {
        /// appkit/nsaccessibility-swift.struct/notification/announcementrequested (macOS 10.7+)
        public static let announcementRequested: NSAccessibility.Notification = Notification()
        init() {}
    }
    /// appkit/nsaccessibility-swift.struct/notificationuserinfokey — `struct NotificationUserInfoKey`
    public struct NotificationUserInfoKey: Hashable, Sendable {
        /// appkit/nsaccessibility-swift.struct/notificationuserinfokey/announcement (macOS 10.7+)
        public static let announcement: NSAccessibility.NotificationUserInfoKey = NotificationUserInfoKey()
        init() {}
    }
}

// MARK: - Colours, fonts, images, drawing

/// appkit/nscolor — `class NSColor`
open class NSColor: NSObject, @unchecked Sendable {
    public init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {}
    open class var labelColor: NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) }
    open class var secondaryLabelColor: NSColor { labelColor }
    open class var tertiaryLabelColor: NSColor { labelColor }
    open class var linkColor: NSColor { labelColor }
    open class var controlAccentColor: NSColor { labelColor }
    open class var separatorColor: NSColor { labelColor }
    open class var textBackgroundColor: NSColor { labelColor }
    open class var systemRed: NSColor { labelColor }
    open class var clear: NSColor { labelColor }
    open func setFill() {}
    open func setStroke() {}
}

/// appkit/nsfont — `class NSFont`
open class NSFont: NSObject, @unchecked Sendable {
    public struct TextStyle: Hashable, Sendable {
        public static let body = TextStyle(), headline = TextStyle(), title1 = TextStyle()
        public static let title2 = TextStyle(), title3 = TextStyle(), caption1 = TextStyle()
    }
    public struct Weight: Hashable, Sendable {
        public static let regular = Weight(), medium = Weight(), semibold = Weight(), bold = Weight()
    }
    public struct TextStyleOptionKey: Hashable, Sendable {}
    public init?(descriptor fontDescriptor: NSFontDescriptor, size fontSize: CGFloat) {}
    @discardableResult open class func preferredFont(forTextStyle style: NSFont.TextStyle, options: [NSFont.TextStyleOptionKey: Any] = [:]) -> NSFont { fatalError() }
    @discardableResult open class func monospacedSystemFont(ofSize fontSize: CGFloat, weight: NSFont.Weight) -> NSFont { fatalError() }
    @discardableResult open class func systemFont(ofSize fontSize: CGFloat, weight: NSFont.Weight) -> NSFont { fatalError() }
    open var pointSize: CGFloat { 0 }
    open var fontDescriptor: NSFontDescriptor { fatalError() }
}

/// appkit/nsfontdescriptor
open class NSFontDescriptor: NSObject, @unchecked Sendable {
    public struct SymbolicTraits: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static var italic: SymbolicTraits { .init(rawValue: 1) }
        public static var bold: SymbolicTraits { .init(rawValue: 2) }
    }
    open var symbolicTraits: NSFontDescriptor.SymbolicTraits { [] }
    @discardableResult open func withSymbolicTraits(_ symbolicTraits: NSFontDescriptor.SymbolicTraits) -> NSFontDescriptor { self }
}

/// appkit/nsimage — `class NSImage`
open class NSImage: NSObject {
    public init?(systemSymbolName name: String, accessibilityDescription description: String?) {}
    /// appkit/nsimage/init(data:) — `convenience init?(data: Data)` (docs metadata omits the
    /// version; it predates 10.10)
    public convenience init?(data: Data) { fatalError() }
    open var tiffRepresentation: Data? { nil }
    open func draw(in rect: NSRect) {}
}

/// appkit/nsbitmapimagerep
open class NSBitmapImageRep: NSObject {
    public enum FileType: UInt, Sendable { case tiff, bmp, gif, jpeg, png, jpeg2000 }
    public struct PropertyKey: Hashable, Sendable {}
    public init?(data: Data) {}
    @discardableResult open func representation(using storageType: NSBitmapImageRep.FileType, properties: [NSBitmapImageRep.PropertyKey: Any]) -> Data? { nil }
}

/// appkit/nsbezierpath — `class NSBezierPath`
open class NSBezierPath: NSObject {
    public init(rect: NSRect) {}
    public init(roundedRect rect: NSRect, xRadius: CGFloat, yRadius: CGFloat) {}
    open var lineWidth: CGFloat { get { 1 } set {} }
    open func fill() {}
    open func stroke() {}
}

extension NSRect {
    /// appkit/nsrectfill (Swift: `NSRect.fill(using:)`)
    public func fill() {}
}

// MARK: - Attributed strings

extension NSAttributedString.Key {
    /// appkit/nsattributedstring/key — the AppKit attribute names gloss sets.
    public static let font = NSAttributedString.Key("NSFont")
    public static let foregroundColor = NSAttributedString.Key("NSColor")
    public static let strikethroughStyle = NSAttributedString.Key("NSStrikethrough")
    public static let underlineStyle = NSAttributedString.Key("NSUnderline")
    public static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
    public static let link = NSAttributedString.Key("NSLink")
}

extension NSAttributedString {
    /// foundation/nsattributedstring/size() — a method, not a property.
    @discardableResult public func size() -> NSSize { .zero }
    /// foundation/nsattributedstring/draw(at:)
    public func draw(at point: NSPoint) {}
    /// foundation/nsattributedstring/draw(in:)
    public func draw(in rect: NSRect) {}
}

/// appkit/nsunderlinestyle — OptionSet, rawValue Int
public struct NSUnderlineStyle: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static var single: NSUnderlineStyle { .init(rawValue: 1) }
    public static var thick: NSUnderlineStyle { .init(rawValue: 2) }
    public static var double: NSUnderlineStyle { .init(rawValue: 9) }
    public static var patternDot: NSUnderlineStyle { .init(rawValue: 0x100) }
}

/// appkit/nsparagraphstyle
open class NSParagraphStyle: NSObject {}

/// appkit/nsmutableparagraphstyle
open class NSMutableParagraphStyle: NSParagraphStyle {
    open var headIndent: CGFloat { get { 0 } set {} }
    open var firstLineHeadIndent: CGFloat { get { 0 } set {} }
    open var paragraphSpacingBefore: CGFloat { get { 0 } set {} }
}

/// appkit/nstextstorage — an NSMutableAttributedString subclass
open class NSTextStorage: NSMutableAttributedString {}

// MARK: - Text views

/// appkit/nstextdelegate — the protocol isn't isolated; its methods are `@MainActor optional`.
public protocol NSTextDelegate: NSObjectProtocol {
    @MainActor func textDidChange(_ notification: Notification)
}
extension NSTextDelegate {
    @MainActor public func textDidChange(_ notification: Notification) {}
}

/// appkit/nstextviewdelegate — methods are `@MainActor optional`.
public protocol NSTextViewDelegate: NSTextDelegate {
    @MainActor func textViewDidChangeSelection(_ notification: Notification)
    @MainActor func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool
    @MainActor func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool
}
extension NSTextViewDelegate {
    @MainActor public func textViewDidChangeSelection(_ notification: Notification) {}
    @MainActor public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool { false }
    @MainActor public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { false }
}

/// appkit/nstext
@MainActor open class NSText: NSView {
    open var string: String { get { "" } set {} }
    open var selectedRange: NSRange { get { NSRange(location: 0, length: 0) } set {} }
    open var isRichText: Bool { get { true } set {} }
    open var backgroundColor: NSColor? { get { nil } set {} }
    open var textStorage: NSTextStorage? { nil }
    open func scrollRangeToVisible(_ range: NSRange) {}
    open func replaceCharacters(in range: NSRange, with string: String) {}
}

/// appkit/nstextview
@MainActor open class NSTextView: NSText {
    public convenience init(usingTextLayoutManager: Bool) { self.init(frame: .zero) }
    open var delegate: (any NSTextViewDelegate)? { get { nil } set {} }
    open var textLayoutManager: NSTextLayoutManager? { nil }
    open var textContentStorage: NSTextContentStorage? { nil }
    open var typingAttributes: [NSAttributedString.Key: Any] { get { [:] } set {} }
    open var allowsUndo: Bool { get { false } set {} }
    open var usesFindBar: Bool { get { false } set {} }
    open var isAutomaticQuoteSubstitutionEnabled: Bool { get { false } set {} }
    open var isAutomaticDashSubstitutionEnabled: Bool { get { false } set {} }
    open var isAutomaticTextReplacementEnabled: Bool { get { false } set {} }
    open var textContainerInset: NSSize { get { .zero } set {} }
    @discardableResult open func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool { true }
    open func didChangeText() {}
    open func setSelectedRange(_ charRange: NSRange) {}
    open func showFindIndicator(for charRange: NSRange) {}
    open func breakUndoCoalescing() {}
    @discardableResult open func characterIndexForInsertion(at point: NSPoint) -> Int { 0 }
    // NSTextInputClient (NSTextView conforms; documented on the protocol)
    @discardableResult open func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    @discardableResult open func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    /// appkit/nstextinputclient/characterindex(for:) — the point is in **screen** coordinates.
    @discardableResult open func characterIndex(for point: NSPoint) -> Int { 0 }
}

// MARK: - TextKit 2 (none of these are main-actor isolated)

/// appkit/nstextlocation
public protocol NSTextLocation: NSObjectProtocol {}

/// appkit/nstextrange
open class NSTextRange: NSObject {
    public init?(location: any NSTextLocation, end endLocation: (any NSTextLocation)?) {}
    open var location: any NSTextLocation { fatalError() }
    open var endLocation: any NSTextLocation { fatalError() }
}

/// appkit/nstextelement
open class NSTextElement: NSObject {
    open var elementRange: NSTextRange? { get { nil } set {} }
}

/// appkit/nstextparagraph
open class NSTextParagraph: NSTextElement {
    open var attributedString: NSAttributedString { fatalError() }
}

/// appkit/nstextcontentmanager
open class NSTextContentManager: NSObject {
    open var documentRange: NSTextRange { fatalError() }
    @discardableResult open func offset(from: any NSTextLocation, to: any NSTextLocation) -> Int { 0 }
    @discardableResult open func location(_ location: any NSTextLocation, offsetBy offset: Int) -> (any NSTextLocation)? { nil }
}

/// appkit/nstextcontentstorage — inherits NSTextContentManager (not NSTextStorage)
open class NSTextContentStorage: NSTextContentManager {
    open var textStorage: NSTextStorage? { get { nil } set {} }
}

/// appkit/nstextlayoutmanagerdelegate — not isolated; requirements are optional.
public protocol NSTextLayoutManagerDelegate: NSObjectProtocol {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment
}
extension NSTextLayoutManagerDelegate {
    @discardableResult public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment { fatalError() }
}

/// appkit/nstextlayoutmanager
open class NSTextLayoutManager: NSObject {
    open var delegate: (any NSTextLayoutManagerDelegate)? { get { nil } set {} }
    open var textContentManager: NSTextContentManager? { nil }
    open func invalidateLayout(for range: NSTextRange) {}
    open func ensureLayout(for range: NSTextRange) {}
    open func ensureLayout(for bounds: CGRect) {}
    @discardableResult open func textLayoutFragment(for location: any NSTextLocation) -> NSTextLayoutFragment? { nil }
    @discardableResult open func textLayoutFragment(for position: CGPoint) -> NSTextLayoutFragment? { nil }
}

/// appkit/nstextlayoutfragment — `class NSTextLayoutFragment` (not main-actor isolated)
open class NSTextLayoutFragment: NSObject {
    public enum State: UInt, Sendable { case none, estimatedUsageBounds, calculatedUsageBounds, layoutAvailable }
    public init(textElement: NSTextElement, range rangeInElement: NSTextRange?) {}
    open var textElement: NSTextElement? { nil }
    open var rangeInElement: NSTextRange { fatalError() }
    open var layoutFragmentFrame: CGRect { .zero }
    open var renderingSurfaceBounds: CGRect { .zero }
    open var state: NSTextLayoutFragment.State { .none }
    open var textLineFragments: [NSTextLineFragment] { [] }
    open func draw(at point: CGPoint, in context: CGContext) {}
}

/// appkit/nstextlinefragment
open class NSTextLineFragment: NSObject {
    @discardableResult open func characterIndex(for point: CGPoint) -> Int { 0 }
}
