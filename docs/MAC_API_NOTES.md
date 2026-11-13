# macOS API notes (verified against Apple's documentation, 2026-11-13)

Every declaration below was copied from the Swift `declarations` tokens of Apple's
documentation JSON (`developer.apple.com/tutorials/data/documentation/...`), fetched 2026-11-13.
"macOS" availability = `introducedAt` from the `metadata.platforms` entry (deprecations noted).
Isolation = what the declaration tokens / protocol declarations actually say.
Anything not confirmed in the docs is marked **UNVERIFIED** with the reason.

## Swift 6 / strict-concurrency summary (verified)

- WebKit: `WKWebView`, `WKWebViewConfiguration`, `WKWebsiteDataStore`, `WKUserContentController`,
  `WKScriptMessage`, `WKContentWorld`, `WKNavigationAction` are `@MainActor` **classes**;
  `WKURLSchemeHandler`, `WKScriptMessageHandler`, `WKScriptMessageHandlerWithReply`,
  `WKNavigationDelegate`, `WKUIDelegate` are `@MainActor` **protocols** (so every requirement is
  MainActor-isolated). `WKURLSchemeTask` is **not** `@MainActor`.
- WebKit methods that predate concurrency annotations are exported `@MainActor @preconcurrency`
  (e.g. `callAsyncJavaScript`, `evaluateJavaScript(_:in:...)`, `NSViewRepresentable` requirements).
- AppKit: delegate protocols are not annotated at the type level, but individual delegate methods
  are `@MainActor optional func ...` (e.g. `textViewDidChangeSelection(_:)`, `textView(_:clickedOnLink:at:)`).
  `NSTextLayoutManagerDelegate` and its requirement are **not** `@MainActor`.
- PDFKit: `PDFView`, `PDFPageOverlayViewProvider` etc. carry **no** actor annotation in the docs.
- SwiftUI: scene and `View` **modifiers** are `nonisolated`; the protocols `View`, `App`, `Scene`,
  `Commands` and `NSViewRepresentable`, and `OpenWindowAction`, are `@MainActor @preconcurrency`, so a
  conforming type's `body` runs on the main actor (review 6 corrected this line).

---

# WebKit

### `WKURLSchemeHandler` — protocol, macOS 10.13+
```swift
@MainActor protocol WKURLSchemeHandler : NSObjectProtocol
```
- Isolation: **@MainActor at the protocol level** → both requirements are MainActor-isolated.
- Requirements (macOS 10.13+):
```swift
func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask)
func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask)
```
- Note (`webView(_:stop:)` discussion): after WebKit calls `stop`, "Don't call any methods of the
  provided `urlSchemeTask` object... If you do, the methods of that object **raise an exception**."

### `WKURLSchemeTask` — protocol, macOS 10.13+
```swift
protocol WKURLSchemeTask : NSObjectProtocol
```
- Isolation: **NOT @MainActor** (no annotation anywhere on the type or its members) — unlike its
  handler protocol. Under Swift 6 the task object you get inside your `@MainActor` handler is
  nonisolated.
```swift
var request: URLRequest { get }
func didReceive(_ response: URLResponse)   // slug .../didreceive(_:)-2u23r
func didReceive(_ data: Data)              // slug .../didreceive(_:)-8t5f8
func didFinish()
func didFailWithError(_ error: any Error)
```
- Required ordering (from discussions): `didReceive(_ response:)` **must** be called at least once
  and **before** any `didReceive(_ data:)`; `didFinish()` after response+data. Calling any of them
  after `didFinish()`/`didFailWithError(_:)`, or after WebKit called `webView(_:stop:)`, **raises an
  exception** (documented per-method). `request` is explicitly safe to read *after* the load was stopped.

### `WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)` — macOS 10.13+
```swift
func setURLSchemeHandler(_ urlSchemeHandler: (any WKURLSchemeHandler)?, forURLScheme urlScheme: String)
```
- Note: "It is a programmer error to call this method more than once for the same scheme."

### `WKWebViewConfiguration.websiteDataStore` — macOS 10.11+
```swift
var websiteDataStore: WKWebsiteDataStore { get set }
```
- Note: config settings are only incorporated at WKWebView creation time (class discussion).

### `WKWebsiteDataStore.nonPersistent()` — macOS 10.11+
```swift
class func nonPersistent() -> WKWebsiteDataStore
```
- Isolation: `WKWebsiteDataStore` is an `@MainActor class`; in-memory store, use for private browsing.

### `WKWebViewConfiguration.userContentController` — macOS 10.10+
```swift
var userContentController: WKUserContentController { get set }
```

### `WKUserContentController.add(_:name:)` — macOS 10.10+
```swift
func add(_ scriptMessageHandler: any WKScriptMessageHandler, name: String)
```
- Note (discussion): "This method uses the content world from the `page` property of
  `WKContentWorld`" — i.e. the plain `add` registers the handler in **`WKContentWorld.page`**, not in
  all worlds.

### `WKUserContentController.addScriptMessageHandler(_:contentWorld:name:)` — macOS 11.0+
```swift
func addScriptMessageHandler(_ scriptMessageHandlerWithReply: any WKScriptMessageHandlerWithReply, contentWorld: WKContentWorld, name: String)
```
- Note: despite the generic-sounding name, this overload takes the **WithReply** handler.

### `WKScriptMessageHandler.userContentController(_:didReceive:)` — macOS 10.10+
```swift
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
```
- Isolation: protocol is `@MainActor`, so the requirement is MainActor-isolated.

### `WKScriptMessageHandlerWithReply.userContentController(_:didReceive:replyHandler:)` — macOS 11.0+
```swift
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void)
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?)
```
- Note: reply is a tuple `(Any?, String?)` = (result, error); replyHandler is `@MainActor @Sendable`.

### `WKScriptMessage.body` — macOS 10.10+
```swift
var body: Any { get }
```
- Note: allowed types per docs: `NSNumber`, `NSString`, `NSDate`, `NSArray`, `NSDictionary`, `NSNull`.

### `WKWebView.callAsyncJavaScript` — completion variant macOS 11.0+, async variant **macOS 12.0+**
```swift
@MainActor @preconcurrency func callAsyncJavaScript(_ functionBody: String, arguments: [String : Any] = [:], in frame: WKFrameInfo? = nil, in contentWorld: WKContentWorld, completionHandler: (@MainActor @Sendable (Result<Any, any Error>) -> Void)? = nil)

@MainActor @preconcurrency func callAsyncJavaScript(_ functionBody: String, arguments: [String : Any] = [:], in frame: WKFrameInfo? = nil, contentWorld: WKContentWorld) async throws -> Any?
```
- Note: `functionBody` is only the body (not a callable); a `then`-able result is awaited; rejection →
  `WKErrorJavaScriptAsyncFunctionResultRejected`. Async variant needs macOS 12.

### `WKWebView.evaluateJavaScript` — macOS 10.10+ (plain), contentWorld variants macOS 11.0+/12.0+
```swift
func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil)
func evaluateJavaScript(_ javaScriptString: String) async throws -> Any?
@MainActor @preconcurrency func evaluateJavaScript(_ javaScript: String, in frame: WKFrameInfo? = nil, contentWorld: WKContentWorld) async throws -> Any?   // macOS 12.0+
@MainActor @preconcurrency func evaluateJavaScript(_ javaScript: String, in frame: WKFrameInfo? = nil, in contentWorld: WKContentWorld, completionHandler: (@MainActor @Sendable (Result<Any, any Error>) -> Void)? = nil)  // macOS 11.0+
```
- Note (discussion): "The completion handler **always runs on the app's main thread**."

### `WKWebView.load(_:)` — macOS 10.10+ (URLRequest) / **macOS 27.0+** (URL)
```swift
func load(_ request: URLRequest) -> WKNavigation?   // macOS 10.10+
func load(_ url: URL) -> WKNavigation?               // macOS 27.0+ (new overload)
```

### `WKWebView.isInspectable` — **macOS 13.3+**
```swift
var isInspectable: Bool { get set }
```
- Note: defaults to `false`; settable at any point in the view's lifetime; setting `false` during
  inspection immediately closes Safari Web Inspector.

### `WKContentWorld.page` — macOS 11.0+
```swift
class var page: WKContentWorld { get }
```
- Isolation: `WKContentWorld` is an `@MainActor class`. Note: modifying page-world variables can
  disrupt the page.

### `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` (WKNavigationAction) — macOS 10.10+
```swift
optional func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)
optional func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy
```
- Note: "always execute the `decisionHandler` block at some point" — sync or async both allowed.
  If you implement the `preferences` variant (`webView(_:decidePolicyFor:preferences:decisionHandler:)`),
  the web view does **not** call this one. (A `WKNavigationResponse` variant also exists.)

### `WKUIDelegate` / target=_blank / window.open — macOS 10.10+
```swift
@MainActor protocol WKUIDelegate : NSObjectProtocol
optional func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
```
- Verified chain for target=_blank: `WKNavigationAction.targetFrame` discussion says "If the target
  of the navigation is a new window, this property is `nil`" → such navigations surface in
  `decidePolicyFor navigationAction`; if allowed, WebKit asks `webView(_:createWebViewWith:for:windowFeatures:)`
  to vend the new WKWebView ("The web view returned must be created with the specified configuration.
  WebKit loads the request in the returned web view."). Returning `nil` = don't open.
  (The linkage "allow → createWebViewWith is then called" is the documented purpose of the method;
  the docs don't spell out the full sequence in one place.)

### `WKWebView.allowsBackForwardNavigationGestures` — macOS 10.10+
```swift
var allowsBackForwardNavigationGestures: Bool { get set }
```

### `WKWebView.underPageBackgroundColor` — **macOS 12.0+**
```swift
@NSCopying var underPageBackgroundColor: NSColor! { get set }   // macOS
```
- Note: default is derived from the page's `<html>`/`<body>` background colors.

### Transparent WKWebView background / `setValue(false, forKey: "drawsBackground")`
- **No public API exists**: `drawsBackground` (or any background-transparency property) appears
  **nowhere** in the WebKit documentation JSON (checked the WebKit framework index and the entire
  `WKWebView` page references). `setValue(_:forKey:)` targeting `"drawsBackground"` is therefore
  **UNVERIFIED / undocumented (private)** — cannot be confirmed from Apple's docs; App Review risk.
  The only documented knob is `underPageBackgroundColor` (macOS 12+).

### WKWebView drag & drop
- **UNVERIFIED**: no public drag/drop customization API for WKWebView appears in the WebKit docs
  index or the WKWebView page (absence checked). Nothing to verify further from documentation.

---

# AppKit / TextKit 2

### `NSTextView.init(usingTextLayoutManager:)`
```swift
convenience init(usingTextLayoutManager: Bool)
```
- Availability: docs metadata lists **macOS with no `introducedAt`** (i.e. the page claims
  availability on all macOS versions). This is almost certainly a docs data gap — every TextKit 2
  sibling (`textLayoutManager`, `textContentStorage`, `NSTextLayoutManager`) is macOS 12.0+.
  **UNVERIFIED minimum version** (docs provide none; assume ≥12.0 in practice).

### `NSTextView.textLayoutManager` — macOS 12.0+
```swift
weak var textLayoutManager: NSTextLayoutManager? { get }
```

### `NSTextView.textContentStorage` — macOS 12.0+
```swift
weak var textContentStorage: NSTextContentStorage? { get }
```

### `NSTextContentStorage` + its `textStorage` — macOS 12.0+
```swift
class NSTextContentStorage                       // inherits NSTextContentManager (NOT NSTextStorage!)
var textStorage: NSTextStorage? { get set }      // from NSTextStorageObserving conformance
```
- Surprise: per the docs relationships, `NSTextContentStorage` inherits from
  **`NSTextContentManager`** and *conforms to* `NSTextStorageObserving` — it is **not** an
  `NSTextStorage` subclass. The `textStorage` property (macOS 12.0+) comes from that conformance.
- For the classic storage on a TextKit-2 text view, `NSTextView.textStorage` (inherited from
  `NSText`) is still documented on the NSTextView page:
```swift
unowned(unsafe) var textStorage: NSTextStorage? { get }
```

### `NSTextLayoutManager` — macOS 12.0+
```swift
class NSTextLayoutManager
```

### `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)` — macOS 12.0+
```swift
protocol NSTextLayoutManagerDelegate : NSObjectProtocol          // NOT @MainActor
optional func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment
```
- Note: return `nil` to use the default fragment. No actor isolation on protocol or requirement.

### `NSTextLayoutFragment` — macOS 12.0+
```swift
class NSTextLayoutFragment
init(textElement: NSTextElement, range rangeInElement: NSTextRange?)
func draw(at point: CGPoint, in context: CGContext)
var layoutFragmentFrame: CGRect { get }
var renderingSurfaceBounds: CGRect { get }
```
- Note (`renderingSurfaceBounds`): coordinate system is **vertically flipped** relative to
  `layoutFragmentFrame` (origin upper-left); size should be larger than `layoutFragmentFrame.size`;
  origin may be negative; **only valid when `state` is greater than** (a certain state — docs
  reference stripped, i.e. use only after layout).

### `NSTextView.shouldChangeText(in:replacementString:)` / `didChangeText()`
```swift
func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool
func didChangeText()
```
- Notes: `shouldChangeText` **must be invoked at the start of any user-initiated editing change**;
  if you override it you **must call `super` first**; returns `false` automatically when not editable.
  Complete an allowed change by invoking `didChangeText()`, which posts `NSTextDidChangeNotification`.

### `firstRect(forCharacterRange:actualRange:)` — documented on `NSTextInputClient` (NSTextView conforms)
```swift
func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect
```
- Note: returns the rect **in screen coordinates**; if the range spans multiple lines you get the
  first line's rect and `actualRange` tells you what it covered; zero-length range → insertion-point
  rect with zero width. (NSTextView's conformance to `NSTextInputClient` is verified on its page.)

### `NSTextViewDelegate` selection/link methods
```swift
@MainActor optional func textViewDidChangeSelection(_ notification: Notification)   // macOS 10.10+
@MainActor optional func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool
```
- Note: `clickedOnLink` returns `true` if handled, `false` to pass it on; `charIndex` is somewhere in
  the link attribute range (not necessarily the physically clicked char).

### `NSTextView.setSelectedRange(_:)` / `scrollRangeToVisible(_:)`
```swift
func setSelectedRange(_ charRange: NSRange)          // NSTextView
func scrollRangeToVisible(_ range: NSRange)         // inherited from NSText
```

### `NSTextView.showFindIndicator(for:)` — macOS 10.5+
```swift
func showFindIndicator(for charRange: NSRange)
```
- Note: does **not** scroll — scroll **before** calling (scrolling makes indicators disappear);
  acts only on the visible portion; zero-length range removes existing indicators.

### `NSVisualEffectView.Material` cases + `material`
```swift
var material: NSVisualEffectView.Material { get set }   // macOS 10.10+; default .appearanceBased
case popover    // macOS 10.11+
case menu       // macOS 10.11+
case hudWindow  // macOS 10.14+
```

### `NSResponder.scrollWheel(with:)` + `NSEvent` scroll members — macOS 10.7+
```swift
func scrollWheel(with event: NSEvent)                 // NSResponder (appkit/nsresponder/scrollwheel(with:))
var phase: NSEvent.Phase { get }                       // macOS 10.7+
var momentumPhase: NSEvent.Phase { get }               // macOS 10.7+
var hasPreciseScrollingDeltas: Bool { get }            // macOS 10.7+
var scrollingDeltaX: CGFloat { get }                   // macOS 10.7+
var scrollingDeltaY: CGFloat { get }                   // macOS 10.7+
var timestamp: TimeInterval { get }
struct Phase: OptionSet, Sendable                      // began, stationary, changed, ended, cancelled, mayBegin
```
- Used by `ReaderWebView` (EPUB, paginated flow) to take trackpad gestures before WebKit. Behaviour
  assumed, not stated on these pages: a trackpad gesture is `mayBegin`/`began` → `changed`… →
  `ended` (or `cancelled`), then momentum events with an empty `phase` and a non-empty
  `momentumPhase`; a line-based mouse wheel has neither phase and imprecise deltas.

### `NSWindow.StyleMask.nonactivatingPanel` / `NSWindow.addChildWindow(_:ordered:)`
```swift
static var nonactivatingPanel: NSWindow.StyleMask { get }
func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode)
```
- Note: moving the child does not move the parent; moving the parent moves the child; **never create
  parent/child cycles**.

### `NSPopover.show(relativeTo:of:preferredEdge:)` / `behavior` — macOS 10.7+
```swift
func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge)
var behavior: NSPopover.Behavior { get set }   // default is .applicationDefined (NOT .transient)
case transient
```
- Notes: raises an exception if the positioning view (or VC's view) is `nil`; re-calling while shown
  just re-anchors; does nothing if the positioning view isn't visible. `.transient` discussion:
  interacting with menus or panels that become key only when needed will **not** close a transient
  popover; "the exact interactions that will cause transient popovers to close are not specified."

---

# PDFKit

### `PDFView` — class, macOS 10.4+ (no actor annotation in docs)
```swift
class PDFView
var document: PDFDocument? { get set }
var currentSelection: PDFSelection? { get set }
func setCurrentSelection(_ selection: PDFSelection?, animate: Bool)          // macOS 10.5+
var highlightedSelections: [PDFSelection]? { get set }                       // macOS 10.5+
weak var pageOverlayViewProvider: (any PDFPageOverlayViewProvider)? { get set }  // macOS 13.0+
```
- Note (`currentSelection`): returns the **actual instance** — copy it before modifying.

### `PDFView.go(to:)` overloads — macOS 10.4+
```swift
func go(to page: PDFPage)
func go(to destination: PDFDestination)
func go(to selection: PDFSelection)
func go(to rect: NSRect, on page: PDFPage)    // macOS: NSRect (iOS: CGRect)
```

### `PDFView.convert(_:)` page↔view — macOS 10.4+
```swift
func convert(_ point: NSPoint, from page: PDFPage) -> NSPoint
func convert(_ rect: NSRect, from page: PDFPage) -> NSRect
func convert(_ rect: NSRect, to page: PDFPage) -> NSRect
func convert(_ point: NSPoint, to page: PDFPage) -> NSPoint
```
- Note: page space = 72 dpi, origin **lower-left** of the page; view space origin = lower-left of the
  PDFView. (Four overloads; slug disambiguators `-4evlx`, `-9xv1z`, `-8cp0c`, `-9twqk`.)

### Notifications `PDFViewSelectionChanged` / `PDFViewPageChanged` — macOS 10.4+
```swift
extern NSNotificationName const PDFViewSelectionChangedNotification;
extern NSNotificationName const PDFViewPageChangedNotification;
```
- Notification object is the `PDFView` itself (both verified). The docs JSON only carries the
  Objective-C declaration; the Swift spelling (standard importer rule would give
  `Notification.Name.PDFViewSelectionChanged` / `.PDFViewPageChanged`) is **UNVERIFIED** — not
  present in the documentation JSON.

### `PDFPageOverlayViewProvider` — protocol, **macOS 13.0+**, no actor annotation
```swift
protocol PDFPageOverlayViewProvider : NSObjectProtocol
func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView?                 // required
optional func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage)
optional func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage)
```
- Note: macOS flavor uses `NSView` (the iOS/Catalyst declaration uses `UIView`).

### `PDFDocument` — macOS 10.4+
```swift
init?(data: Data)
func findString(_ string: String, withOptions options: NSString.CompareOptions = []) -> [PDFSelection]
```
- Notes: `init(data:)` returns `nil` if the data isn't PDF; `findString` returns an empty array when
  no hits (synchronous; use `beginFindString(_:withOptions:)` for long searches).

### `PDFPage` — macOS 10.4+ (thumbnail 10.13+)
```swift
var string: String? { get }
func selection(for range: NSRange) -> PDFSelection?     // raises exception if length 0 or out of range
func selection(for rect: NSRect) -> PDFSelection?
func thumbnail(of size: NSSize, for box: PDFDisplayBox) -> NSImage   // macOS 10.13+
func bounds(for box: PDFDisplayBox) -> NSRect
```
- Note (`bounds(for:)`): only the media box is required; missing crop box falls back to media box,
  other missing boxes fall back to crop box; coordinates in page space (transform for rotated pages).

### `PDFSelection` — macOS 10.4+ (line/range APIs 10.5+/10.7+)
```swift
func selectionsByLine() -> [PDFSelection]               // macOS 10.5+
func bounds(for page: PDFPage) -> NSRect                // page space, 72 dpi, lower-left origin
func numberOfTextRanges(on page: PDFPage) -> Int        // macOS 10.7+
func range(at index: Int, on page: PDFPage) -> NSRange  // macOS 10.7+
var pages: [PDFPage] { get }                           // sorted by page index
```

---

# SwiftUI (macOS 14 target)

### `WindowGroup(for:)` — macOS 13.0+
```swift
nonisolated init<D, C>(for type: D.Type, @ContentBuilder content: @escaping (Binding<D?>) -> C)
  where Content == PresentedWindowContent<D, C>, D : Decodable, D : Encodable, D : Hashable, C : View
```
- Note: the value type must be `Codable` **and** `Hashable`; content receives `Binding<D?>`.

### `OpenWindowAction` — macOS 13.0+
```swift
@MainActor @preconcurrency struct OpenWindowAction
@MainActor @preconcurrency func callAsFunction<D>(value: D) where D : Decodable, D : Encodable, D : Hashable
@MainActor @preconcurrency func callAsFunction<D>(id: String, value: D) where D : Decodable, D : Encodable, D : Hashable
```
- Note: also `callAsFunction(id:)`, `(id:sharingBehavior:)`, `(value:sharingBehavior:)` variants.
  Accessed via the `openWindow` environment value.

### `Settings` — macOS 11.0+ (macOS-only)
```swift
nonisolated struct Settings<Content> where Content : View
```
- Note: adding it enables the app's Settings menu item; SwiftUI shows/removes the view for you.

### `Scene.commands(content:)` / `CommandGroup` / placements — macOS 11.0+
```swift
nonisolated func commands<Content>(@ContentBuilder content: () -> Content) -> some Scene where Content : Commands
nonisolated init(replacing group: CommandGroupPlacement, @ContentBuilder addition: () -> Content)
static let newItem: CommandGroupPlacement        // .importExport, .pasteboard, .textEditing, .sidebar
nonisolated struct CommandMenu<Content> where Content : View   // inserted between View and Window menus
```
- Note: `importExport` is **empty by default** in macOS; `newItem`/`pasteboard`/`textEditing`/
  `sidebar` contain default commands.

### `keyboardShortcut(_:modifiers:)` — macOS 11.0+
```swift
nonisolated func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View
```
- Note: on macOS the shortcut target search order is key window → main window → command groups.

### `FocusedValues` / `@FocusedValue` / `.focusedSceneValue` — macOS 11.0+ (focusedSceneValue 12.0+)
```swift
struct FocusedValues
@propertyWrapper struct FocusedValue<Value>
protocol FocusedValueKey
nonisolated func focusedSceneValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T) -> some View   // macOS 12.0+
```
- Note: use the `@Entry` macro to add focused values (default always `nil`, so all focused values
  are optional); `focusedSceneValue` publishes regardless of where focus is in the active scene.

### `NavigationSplitView` — macOS 13.0+
```swift
nonisolated struct NavigationSplitView<Sidebar, Content, Detail> where Sidebar : View, Content : View, Detail : View
```

### `.searchable(text:placement:prompt:)` — macOS 13.0+ / `.searchScopes(_:activation:_:)` — **macOS 13.3+**
```swift
@export(implementation) nonisolated func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringResource) -> some View
nonisolated func searchScopes<V, S>(_ scope: Binding<V>, activation: SearchScopeActivation, @ContentBuilder _ scopes: () -> S) -> some View where V : Hashable, S : View
```
- Note: `searchScopes` needs **13.3**, not 13.0 or 14 — fine for a macOS 14 target.

### `.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)` — macOS 11.0+
```swift
nonisolated func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool, onCompletion: @escaping (Result<[URL], any Error>) -> Void) -> some View
```
- Note: on cancel, `isPresented` is set to `false` and **`onCompletion` is not called**; `isPresented`
  is set to `false` before `onCompletion` on success.

### `.dropDestination(for:action:isTargeted:)` — macOS 13.0+, **deprecated macOS 27.3**
```swift
nonisolated func dropDestination<T>(for payloadType: T.Type = T.self, action: @escaping ([T], CGPoint) -> Bool, isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View where T : Transferable
```
- Deprecation message (macOS 27.3): "Use `dropDestination(for:isEnabled:action:)` with an `action`
  that takes a `DropSession` parameter instead." The replacement `dropDestination(for:isEnabled:action:)`
  is the current documented variant.

### `.onOpenURL(perform:)` / `.handlesExternalEvents(preferring:allowing:)` — macOS 11.0+
```swift
nonisolated func onOpenURL(perform action: @escaping (URL) -> ()) -> some View
nonisolated func handlesExternalEvents(preferring: Set<String>, allowing: Set<String>) -> some View
```
- Note: SwiftUI routes incoming URLs by scene structure/active scenes; `handlesExternalEvents`
  controls which **already-open** scene handles the event.

### `NSViewRepresentable` — macOS 10.15+
```swift
@MainActor @preconcurrency protocol NSViewRepresentable : View where Self.Body == Never
@MainActor @preconcurrency func makeNSView(context: Self.Context) -> Self.NSViewType
@MainActor @preconcurrency func updateNSView(_ nsView: Self.NSViewType, context: Self.Context)
@MainActor @preconcurrency func makeCoordinator() -> Self.Coordinator
@MainActor @preconcurrency static func dismantleNSView(_ nsView: Self.NSViewType, coordinator: Self.Coordinator)
```
- Notes: `makeNSView` is called **only once**; `updateNSView` for all subsequent changes;
  `makeCoordinator` is called **before** `makeNSView`; `dismantleNSView` is a **static** method;
  `Body == Never`.

### `@Observable` / `@Bindable` — macOS 14.0+
```swift
protocol Observable        // Observation framework; always use the @Observable macro, not bare conformance
@dynamicMemberLookup @propertyWrapper struct Bindable<Value>
```

### `.inspector(isPresented:content:)` — **macOS 14.0+**
```swift
nonisolated func inspector<V>(isPresented: Binding<Bool>, @ContentBuilder content: () -> V) -> some View where V : View
```
- Note: presents as a trailing column in regular horizontal size class, adapts to a sheet in compact.

### `UTType.epub` — **exists**, macOS 11.0+
```swift
static var epub: UTType { get }
```
- Note: docs state "The identifier for this type is `org.idpf.epub-container`." No need for a manual
  `UTType(identifier:)` string.

### `UTType.pdf` — macOS 11.0+
```swift
static var pdf: UTType { get }
```
- Note: identifier `com.adobe.pdf`.

---

# Milestone 9 additions (verified 2026-11-13, same method)

### WebKit
```swift
optional func webViewWebContentProcessDidTerminate(_ webView: WKWebView)          // WKNavigationDelegate, macOS 10.11+
var request: URLRequest { get }                                                   // WKNavigationAction, 10.10+
@NSCopying var targetFrame: WKFrameInfo? { get }                                  // nil = new window
var isMainFrame: Bool { get }                                                     // WKFrameInfo, 10.10+
var request: URLRequest { get }                                                   // WKFrameInfo, 10.10+
enum WKNavigationActionPolicy { case allow, cancel, download }                    // 10.10+
init(frame: CGRect, configuration: WKWebViewConfiguration)                        // WKWebView, @MainActor via the class
weak var navigationDelegate: (any WKNavigationDelegate)? { get set }              // weak
weak var uiDelegate: (any WKUIDelegate)? { get set }                              // weak
func reload() -> WKNavigation?                                                    // NOT @discardableResult
func load(_ request: URLRequest) -> WKNavigation?                                 // NOT @discardableResult
func add(_ scriptMessageHandler: any WKScriptMessageHandler, contentWorld world: WKContentWorld, name: String)   // 11.0+
func removeScriptMessageHandler(forName name: String)                             // page world only, 10.10+
func removeAllScriptMessageHandlers()                                             // all worlds, 11.0+
@NSCopying var frameInfo: WKFrameInfo { get }                                     // WKScriptMessage, 10.10+
var world: WKContentWorld { get }                                                 // WKScriptMessage, 11.0+
```
- **UNVERIFIED:** `WKWebViewConfiguration()` has no docs page (only `init(coder:)`); Apple's sample code calls it.
- The user content controller retains its handlers: use a weak proxy.

### AppKit, PDFKit, Foundation
```swift
init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)          // NSColor, 10.7+ (also a synthesized init(SRGBRed:…) page)
func open(_ url: URL) -> Bool                                                     // NSWorkspace; safe from any thread
func representation(using storageType: NSBitmapImageRep.FileType, properties: [NSBitmapImageRep.PropertyKey : Any]) -> Data?
init?(data: Data)                                                                 // NSBitmapImageRep
var tiffRepresentation: Data? { get }                                             // NSImage
enum NSBitmapImageRep.FileType { case tiff, bmp, gif, jpeg, png, jpeg2000 }
func page(at index: Int) -> PDFPage?                                              // PDFDocument, 10.4+
var pageCount: Int { get }
enum PDFDisplayBox { case mediaBox, cropBox, bleedBox, trimBox, artBox }
func thumbnail(of size: NSSize, for box: PDFDisplayBox) -> NSImage                // PDFPage, 10.13+
init?(url: URL, statusCode: Int, httpVersion HTTPVersion: String?, headerFields: [String : String]?)   // HTTPURLResponse
init(url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy, timeoutInterval: TimeInterval = 60.0)
func activate()                                                                   // NSApplication, 14.0+; activate(ignoringOtherApps:) deprecated 27.0
```

### SwiftUI
```swift
@MainActor @preconcurrency static func main()                                     // App; docs only describe @main
nonisolated struct ContentUnavailableView<Label, Description, Actions>             // 14.0+
nonisolated init(_ title: LocalizedStringResource, systemImage name: String, description: Text? = nil)
nonisolated func task<T>(id: T, name: String? = nil, priority: TaskPriority = .userInitiated, file: String = #fileID, line: Int = #line,
                         _ action: sending @escaping @isolated(any) () async -> Void) -> some View where T : Equatable   // 12.0+
nonisolated init(@ContentBuilder sidebar: () -> Sidebar, @ContentBuilder detail: () -> Detail) where Content == EmptyView   // NavigationSplitView, 13.0+
nonisolated init(selection: Binding<SelectionValue?>?, @ContentBuilder content: () -> Content)   // List, single optional selection, 13.0+
nonisolated func tag<V>(_ tag: V, includeOptional: Bool = true) -> some View where V : Hashable  // also tags Optional<V>
nonisolated func navigationTitle(_ titleResource: LocalizedStringResource) -> some View          // 13.0+; String overload not checkable
nonisolated func navigationSubtitle(_ subtitleKey: LocalizedStringResource) -> some View         // 13.0+
@MainActor @preconcurrency let coordinator: View.Coordinator                       // NSViewRepresentableContext
```

---

# Milestone 10 additions — the TextKit 2 editor (verified 2026-11-13, same method)

### Text view and delegate
```swift
weak var delegate: (any NSTextViewDelegate)? { get set }                  // NSTextView
@MainActor optional func textDidChange(_ notification: Notification)      // NSTextDelegate, 10.10+
@MainActor optional func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool
@MainActor optional func textViewDidChangeSelection(_ notification: Notification)
@MainActor optional func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool
var typingAttributes: [NSAttributedString.Key : Any] { get set }        // resets on selection change
var allowsUndo: Bool { get set }
var isRichText: Bool { get set }
var usesFindBar: Bool { get set }                                         // 10.7+
var isAutomaticQuoteSubstitutionEnabled: Bool { get set }                 // 10.5+
var isAutomaticDashSubstitutionEnabled: Bool { get set }                  // 10.6+
var isAutomaticTextReplacementEnabled: Bool { get set }                   // 10.6+
var textContainerInset: NSSize { get set }
func replaceCharacters(in range: NSRange, with string: String)           // NSText; NO undo unless shouldChangeText wraps it
func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool   // call super first when overridden
func didChangeText()
func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect   // screen coordinates
```
- `NSTextView.insertText(_:)` (10.0) is deprecated 10.11; typed input goes through
  `NSTextInputClient.insertText(_:replacementRange:)`, which is not for programmatic edits — use
  the text storage (`replaceCharacters` inside `shouldChangeText`/`didChangeText`).
- **UNVERIFIED:** whether `NSTextView.scrollableTextView()` (10.14+) creates a TextKit 2 view — its
  doc page has no discussion. Build the view with `NSTextView(usingTextLayoutManager: true)` instead.

### Text storage and layout
```swift
func setAttributes(_ attrs: [NSAttributedString.Key : Any]?, range: NSRange)   // NSMutableAttributedString
func addAttributes(_ attrs: [NSAttributedString.Key : Any] = [:], range: NSRange)
func beginEditing() / func endEditing()          // layout fix-up happens at endEditing
weak var delegate: (any NSTextLayoutManagerDelegate)? { get set }             // NSTextLayoutManager, 12.0+
func invalidateLayout(for range: NSTextRange)                                   // 12.0+
func ensureLayout(for range: NSTextRange) / func ensureLayout(for bounds: CGRect)
func textLayoutFragment(for location: any NSTextLocation) -> NSTextLayoutFragment?
func textLayoutFragment(for position: CGPoint) -> NSTextLayoutFragment?
var documentRange: NSTextRange { get }         // NSTextElementProvider (NSTextContentStorage implements it)
func offset(from: any NSTextLocation, to: any NSTextLocation) -> Int            // NSTextContentStorage, non-optional
func location(_ location: any NSTextLocation, offsetBy offset: Int) -> (any NSTextLocation)?
init?(location: any NSTextLocation, end endLocation: (any NSTextLocation)?)    // NSTextRange, failable
weak var textElement: NSTextElement? { get }     // NSTextLayoutFragment
var rangeInElement: NSTextRange { get }
var elementRange: NSTextRange? { get set }      // NSTextElement
var attributedString: NSAttributedString { get } // NSTextParagraph
var state: NSTextLayoutFragment.State { get }    // .none, .estimatedUsageBounds, .calculatedUsageBounds, .layoutAvailable
func convert(_ rect: NSRect, from view: NSView?) -> NSRect   // nil view = window base coordinates
func convertFromScreen(_ rect: NSRect) -> NSRect             // NSWindow, 10.7+
```

### Fonts, colours, attributes
```swift
class func preferredFont(forTextStyle style: NSFont.TextStyle, options: [NSFont.TextStyleOptionKey : Any] = [:]) -> NSFont   // 11.0+
static let body: NSFont.TextStyle / .title1 / .title2 / .title3 / .headline                  // struct, 11.0+
class func monospacedSystemFont(ofSize fontSize: CGFloat, weight: NSFont.Weight) -> NSFont    // 10.15+
class func systemFont(ofSize fontSize: CGFloat, weight: NSFont.Weight) -> NSFont              // 10.11+
func withSymbolicTraits(_ symbolicTraits: NSFontDescriptor.SymbolicTraits) -> NSFontDescriptor   // NON-optional
init?(descriptor fontDescriptor: NSFontDescriptor, size fontSize: CGFloat)                    // failable
class var labelColor: NSColor { get } / secondaryLabelColor / tertiaryLabelColor / linkColor // 10.10+
class var controlAccentColor: NSColor { get }                                                // 10.14+
static var single: NSUnderlineStyle { get } / static var patternDot: NSUnderlineStyle { get } // OptionSet, rawValue Int
var headIndent: CGFloat { get set } / firstLineHeadIndent / paragraphSpacingBefore           // NSMutableParagraphStyle
static let foregroundColor / font / strikethroughStyle / underlineStyle / paragraphStyle / link: NSAttributedString.Key
```
- `NSUnderlineStyle` combines pattern and style with union (`[.single, .patternDot]`).
- Attribute values on macOS: `.font` → `NSFont`, `.foregroundColor` → `NSColor`, underline/strikethrough
  styles → `NSNumber` wrapping `NSUnderlineStyle`, `.link` → `NSURL` (or `NSString`).

### Commands and focus
```swift
@attached(accessor) @attached(peer, names: prefixed(__Key_)) macro Entry()   // FocusedValues: 10.15+ for @Entry, 11.0+ for FocusedValues
nonisolated func focusedSceneValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T) -> some View  // 12.0+
nonisolated func focusedSceneValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T?) -> some View // 13.0+
static let textFormatting: CommandGroupPlacement                                // exists on macOS, 11.0+
nonisolated init(after group: CommandGroupPlacement, @ContentBuilder addition: () -> Content)
func performKeyEquivalent(with event: NSEvent) -> Bool                          // NSResponder, default false
func keyDown(with event: NSEvent)                                               // NSResponder
```
- `@Entry` FocusedValues must be Optional (the default is always nil).

---

# Milestone 11 additions — hover, popovers, split view (verified 2026-11-13, same method)

### Tracking areas and mouse
```swift
init(rect: NSRect, options: NSTrackingArea.Options = [], owner: Any?, userInfo: [AnyHashable : Any]? = nil)   // NSTrackingArea, 10.5+
static var mouseMoved: NSTrackingArea.Options { get }
static var mouseEnteredAndExited: NSTrackingArea.Options { get }
static var activeInKeyWindow: NSTrackingArea.Options { get }
static var inVisibleRect: NSTrackingArea.Options { get }   // the rect is ignored; tracks the visible rect
func updateTrackingAreas()                                  // NSView, 10.5+; remove stale, add recomputed
func addTrackingArea(_ trackingArea: NSTrackingArea)         // 10.5+
func removeTrackingArea(_ trackingArea: NSTrackingArea)      // 10.5+
var trackingAreas: [NSTrackingArea] { get }
func mouseMoved(with event: NSEvent)                         // NSResponder; default passes to next responder
func mouseExited(with event: NSEvent)
```

### Popovers
```swift
init()                                    // NSPopover, 10.7+
@IBOutlet var contentViewController: NSViewController? { get set }   // set before showing
var animates: Bool { get set }            // a hint, not guaranteed
var isShown: Bool { get }
func close()                              // without consulting the delegate
@IBAction func performClose(_ sender: Any?)   // respects popoverShouldClose(_:)
```

### SwiftUI hosting and layout
```swift
@MainActor @preconcurrency init(rootView: Content)   // NSHostingController, 10.15+
@MainActor @preconcurrency required init(rootView: Content)   // NSHostingView, 10.15+
nonisolated struct HSplitView<Content> where Content : View   // 10.15+, macOS-only
struct NavigationSplitViewVisibility      // macOS 13.0+; exactly 4 cases:
static var automatic / all / doubleColumn / detailOnly: NavigationSplitViewVisibility { get }
nonisolated init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ContentBuilder sidebar: () -> Sidebar, @ContentBuilder detail: () -> Detail) where Content == EmptyView   // 13.0+
static let navigation: ToolbarItemPlacement   // macOS 11.0+; leading edge of the toolbar
nonisolated struct ControlGroup<Content> where Content : View   // macOS 12.0+
init(_ character: Character)               // KeyEquivalent, 11.0+; `KeyEquivalent("[")` compiles
nonisolated func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View   // 11.0+
```
- `keyboardShortcut` resolution on macOS: key window → main window → command groups.

### TextKit 2 point → character
```swift
func characterIndexForInsertion(at point: NSPoint) -> Int   // NSTextView, 10.5+; for click/drag insertion points
var textLineFragments: [NSTextLineFragment] { get }          // NSTextLayoutFragment, 12.0+; valid once geometry is set
func characterIndex(for point: CGPoint) -> Int               // NSTextLineFragment, 12.0+; point in the line fragment's coordinates
var lineFragmentPadding: CGFloat { get set }                  // NSTextContainer, 10.0 (default 5); NSTextView.textContainer, NSTextLayoutManager.textContainer (12.0)
var typographicBounds: CGRect { get }                        // NSTextLineFragment, 12.0+; "origin offset from the beginning of the line fragment group belonging to the parent layout fragment"
func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo otherView: NSView?)   // NSView; nil otherView = above/below all siblings
var isHidden: Bool { get set }                               // NSView
enum OrderingMode { case below, out, above }                 // NSWindow.OrderingMode
var minimumLineHeight: CGFloat { get set }                   // NSMutableParagraphStyle, 10.0; "regardless of the font size"
var maximumLineHeight: CGFloat { get set }                   // NSMutableParagraphStyle, 10.0; 0 = no limit
var lineBreakMode: NSLineBreakMode { get set }               // NSMutableParagraphStyle, 10.0; `.byClipping` keeps a paragraph on one line
convenience init(pointSize: CGFloat, weight: NSFont.Weight)  // NSImage.SymbolConfiguration (symbolconfiguration-swift.class), 11.0
func withSymbolConfiguration(_ configuration: NSImage.SymbolConfiguration) -> NSImage?   // NSImage, 11.0
var size: NSSize { get set }                                 // NSImage
```

---

# Milestone 11 additions — PDFKit reader (verified 2026-11-13, same method)

```swift
var autoScales: Bool { get set }                       // PDFView, 10.4+
var displayMode: PDFDisplayMode { get set }            // 10.4+
var displaysPageBreaks: Bool { get set }               // 10.4+
var displayDirection: PDFDisplayDirection { get set }  // 10.13+
@IBAction func goToNextPage(_ sender: Any?)            // 10.4+
@IBAction func goToPreviousPage(_ sender: Any?)       // 10.4+
func page(for point: NSPoint, nearest: Bool) -> PDFPage?   // 10.4+ (macOS flavor; also a CGPoint variant)
func clearSelection()                                  // 10.4+
func index(for page: PDFPage) -> Int                   // PDFDocument, 10.4+
var label: String? { get }                             // PDFPage, 10.4+
func characterIndex(at point: NSPoint) -> Int          // PDFPage, 10.4+
optional func pdfViewWillClick(onLink sender: PDFView, with url: URL)   // PDFViewDelegate, 10.5+
init(page: PDFPage, at point: NSPoint)                 // PDFDestination, 10.4+
```
- `PDFDisplayMode` cases (from the enum's Constants section): `singlePage`, `singlePageContinuous`,
  `twoUp`, `twoUpContinuous` (10.4+).
- `PDFView.init(frame:)` is inherited from `NSView` (no PDFKit page of its own).
- Previously verified and used by the engine: `document`, `currentSelection`,
  `setCurrentSelection(_:animate:)`, `pageOverlayViewProvider` (13.0+), `go(to:)` overloads,
  `convert(_:)` page↔view, `PDFPageOverlayViewProvider` requirements, `PDFDocument.init(data:)`,
  `findString`, `page(at:)`, `pageCount`, `PDFPage.string/selection(for:)/bounds(for:)`,
  `PDFSelection.selectionsByLine()/bounds(for:)/numberOfTextRanges(on:)/range(at:on:)/pages`.
- Still UNVERIFIED from the docs JSON: the Swift spelling of `PDFViewSelectionChanged` /
  `PDFViewPageChanged` notifications (only the ObjC extern exists in the JSON).

---

# Review 6 / D-099 additions (verified 2026-11-13, same method)

These back `scripts/mac-stubs/`; each stub member names its docs path.

```swift
func removeObserver(_ observer: Any)                                   // NotificationCenter, 10.0+ — there is NO removeObservers(_:)
func removeObserver(_ observer: Any, name aName: NSNotification.Name?, object anObject: Any?)
func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol   // 10.6+
func addObserver(_ observer: Any, selector aSelector: Selector, name aName: NSNotification.Name?, object anObject: Any?)
@MainActor class UndoManager                                           // Foundation
@MainActor @preconcurrency func registerUndo<TargetType>(withTarget target: TargetType, handler: @escaping @MainActor (TargetType) -> Void) where TargetType : AnyObject   // 10.11+
func size() -> CGSize                                                  // NSAttributedString — a METHOD, not a property
func draw(at point: CGPoint) / func draw(in rect: CGRect)              // NSAttributedString
func range(of searchString: String, options mask: NSString.CompareOptions = []) -> NSRange   // NSString
var superview: NSView? { get }                                         // NSView (unowned(unsafe))
func hitTest(_ point: NSPoint) -> NSView?                              // point is in the SUPERVIEW's coordinates
var isFlipped: Bool { get } / var needsDisplay: Bool { get set } / func addSubview(_:) / func removeFromSuperview()
@NSCopying var backgroundColor: NSColor? { get set }                   // NSText (optional)
func breakUndoCoalescing()                                             // NSTextView
func characterIndex(for point: NSPoint) -> Int                         // NSTextInputClient — point in SCREEN coordinates
optional func insertNewline(_ sender: Any?) / cancelOperation(_:) …    // NSStandardKeyBindingResponding
var backgroundColor: NSColor { get set }                               // PDFView (non-optional)
var currentPage: PDFPage? { get }                                      // PDFView
var outlineRoot: PDFOutline? { get set }                               // PDFDocument, 10.6+
var numberOfChildren: Int { get } / func child(at index: Int) -> PDFOutline? / var label: String? / var destination: PDFDestination?   // PDFOutline, 10.4+
weak var page: PDFPage? { get }                                        // PDFDestination
var string: String? { get } / var pages: [PDFPage] { get }             // PDFSelection
nonisolated init(nsColor: NSColor)                                     // SwiftUI.Color, 12.0+ (Color has no separatorColor)
nonisolated func help(_ text: Text) -> some View                       // also LocalizedStringKey, StringProtocol (11.0+), LocalizedStringResource (13.0+)
nonisolated func frame(width:height:alignment:) / frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:alignment:)   // two overloads: no frame(width:maxHeight:)
nonisolated func overlay<V>(alignment: Alignment = .center, @ContentBuilder content: () -> V) -> some View   // 12.0+; overlay(_:alignment:) deprecated 27.3
nonisolated func accessibilityLabel(_ label: Text) / accessibilityAddTraits(_:)   // 11.0+
```

- AppKit's `NSView`, `NSResponder` and `NSWindow` are `@MainActor` classes; `NSColor`, `NSFont`,
  `NSImage`, `NSEvent`, `NSBezierPath` and the TextKit 2 classes (`NSTextLayoutFragment`,
  `NSTextElement`, …) are not. `PDFPage` isn't Sendable: moving one into `assumeIsolated` needs a
  `nonisolated(unsafe)` local (D-100).
- **UNVERIFIED from the docs JSON:** SwiftUI's `task` modifiers inherit the caller's actor context;
  the SDK interface spells it `@_inheritActorContext`, which the docs drop.

# Milestone 12 additions — the source list (verified 2026-11-13, same method)

Overloads that share a docs path are listed under the page's `otherDeclarations`, each with a
hash-suffixed path (`init(wrappedValue:_:)-48yjd`); the stubs name that path.

```swift
@frozen @propertyWrapper struct SceneStorage<Value>                    // 11.0+; wrappedValue { get nonmutating set }, projectedValue: Binding<Value>
init(wrappedValue: Value, _ key: String) where Value == Bool           // -48yjd; also Int (-3kgmn), String (-40fny), RawRepresentable<String> (-8hd2d), Double, Data, Date, URL
struct Section<Parent, Content, Footer>                                // View when all three are
init(_ titleKey: LocalizedStringKey, @ContentBuilder content: () -> Content)                           // 12.0+, Parent == Text, Footer == EmptyView
init(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ContentBuilder content: () -> Content)  // 14.0+, collapsible sidebar section
init(isExpanded: Binding<Bool>, @ContentBuilder content: () -> Content, @ContentBuilder header: () -> Parent)   // 14.0+, Footer == EmptyView
init<DataElement>(_ data: Data, children: KeyPath<DataElement, Data?>, @ContentBuilder content: @escaping (DataElement) -> Leaf)
    // OutlineGroup, -4rmem, 11.0+: ID == Data.Element.ID, Parent == Leaf, Subgroup == DisclosureGroup<Parent, OutlineSubgroupChildren>
nonisolated struct DisclosureGroup<Label, Content> where Label : View, Content : View   // 11.0+
static var sidebar: SidebarListStyle { get }                           // ListStyle, 10.15+
nonisolated func listStyle<S>(_ style: S) -> some View where S : ListStyle
nonisolated func badge(_ count: Int) -> some View                      // 12.0+ (-8adyq): "set the value to zero to hide the badge"
nonisolated func contextMenu<MenuItems>(@ContentBuilder menuItems: () -> MenuItems) -> some View   // 10.15+
nonisolated func onDeleteCommand(perform action: (() -> Void)?) -> some View                       // 10.15+, Edit › Delete and the delete key
nonisolated func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View   // 13.0+
nonisolated init<S>(_ title: S, systemImage name: String) where S : StringProtocol   // Label, -2z97t: data, not a localization key
```

# Milestone 12 additions — the library (verified 2026-11-13, same method)

```swift
nonisolated init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = .init(), @ContentBuilder content: () -> Content)   // LazyVGrid, 11.0+
init(_ size: GridItem.Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil)      // GridItem, 11.0+
case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)                                       // GridItem.Size, 11.0+
case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)                                  // GridItem.Size; flexible's defaults are the stub's (docs page lists no defaults)
struct PinnedScrollableViews { init(); static let sectionHeaders, sectionFooters }                   // 11.0+
nonisolated init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label)               // Menu, 11.0+
nonisolated init(_ titleKey: LocalizedStringKey, @ContentBuilder content: () -> Content)           // Menu where Label == Text, -7v768, 11.0+
nonisolated init(_ titleKey: LocalizedStringKey, text: Binding<String>)                              // TextField where Label == Text, 10.15+
nonisolated func aspectRatio(_ aspectRatio: CGFloat?, contentMode: ContentMode) -> some View        // 10.15+; CGSize overload -771ow unused
enum ContentMode { case fit, fill }                                                                 // 10.15+
nonisolated func clipped(antialiased: Bool = false) -> some View                                    // 10.15+ (docs slug is clipped(antialiased:))
nonisolated func scaledToFill() -> some View                                                        // 10.15+
nonisolated func controlSize(_ controlSize: ControlSize) -> some View                                // 10.15+; ControlSize mini/small/regular/large
nonisolated func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider]) -> Bool) -> some View   // 11.0+ (the [String] and CGPoint overloads exist too)
init(_ colorSpace: Color.RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1)   // Color, 10.15+; RGBColorSpace sRGB/sRGBLinear/displayP3
convenience init?(data: Data)                                                                       // NSImage; docs metadata omits introducedAt (it predates 10.10)
```

- `dropDestination(for:action:isTargeted:)` is **deprecated macOS 27.3** (introduced 13.0); its
  replacement `dropDestination(for:isEnabled:action:)` is **macOS 26.0+** — unusable at the
  macOS 14 target, so the drop uses `onDrop` + `NSItemProvider` instead (D-118).

### Import panels and providers

```swift
@MainActor class NSSavePanel                                                            // allowedContentTypes 11.0+; message/prompt are String!
var allowedContentTypes: [UTType] { get set }
var message: String! { get set } / var prompt: String! { get set }
func beginSheetModal(for window: NSWindow, completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void)   // 10.6+; also an async variant
func runModal() -> NSApplication.ModalResponse
@MainActor class NSOpenPanel: NSSavePanel
var canChooseFiles: Bool / canChooseDirectories: Bool / allowsMultipleSelection: Bool  // NSOpenPanel
var urls: [URL] { get }                                                                 // NSOpenPanel
weak var keyWindow: NSWindow? { get }                                                   // NSApplication
struct ModalResponse { init(_ rawValue: UInt); static let OK, cancel, continue, stop, abort, … }   // NSApplication.ModalResponse
init?(filenameExtension: String, conformingTo supertype: UTType = .data)                // UTType, 11.0+ (one page covers both spellings)
static var image: UTType { get }                                                       // UTType, 11.0+ ("public.image")
```

- **UNVERIFIED:** `NSOpenPanel()`/`NSSavePanel()` have no initializer docs page (NSObject's
  `init` reaches them); Apple's sample code calls them, as with `WKWebViewConfiguration()`.
- **Modelling choice:** `beginSheetModal`'s completion has no isolation in the docs; the stub
  declares it `@MainActor` (AppKit runs it on the main thread), like other AppKit completions.
- **Modelling choice:** `NSItemProvider.loadObject(ofClass:completionHandler:)`'s generic
  overload is documented as `T : _ObjectiveCBridgeable, T._ObjectiveCType : NSItemProviderReading`
  (URL qualifies on a Mac). corelibs Foundation has no `_ObjectiveCBridgeable`, so the stub
  drops the constraint; `loadObject(ofClass: URL.self)` still compiles line for line on a Mac.
  Only use it with bridged types (URL, String).
  The real SDK warns about the unused `Progress` it returns (a Mac build, D-099 follow-up), so the
  stub is not `@discardableResult` and callers write `_ = provider.loadObject(…)`.
- `NSItemProvider`/`NSItemProviderReading` are Darwin Foundation (corelibs lacks them), so they
  live in the AppKit stub's Darwin section; `canLoadObject(ofClass:)` 10.13+, `loadObject` 10.13+.
# Milestone 12 additions — search, open quickly, export/print, url handling (verified 2026-11-13, same method)

### SwiftUI (macOS 14 target)
```swift
nonisolated func searchScopes<V, S>(_ scope: Binding<V>, activation: SearchScopeActivation, @ContentBuilder _ scopes: () -> S) -> some View where V : Hashable, S : View   // view/searchscopes(_:activation:_:), macOS 13.3+
struct SearchScopeActivation { static var automatic / onSearchPresentation / onTextEntry }  // macOS 13.3
nonisolated func onKeyPress(keys: Set<KeyEquivalent>, phases: KeyPress.Phases = [.down, .repeat], action: @escaping (KeyPress) -> KeyPress.Result) -> some View   // macOS 14.0
nonisolated func onKeyPress(_ key: KeyEquivalent, phases: KeyPress.Phases = [.down, .repeat], action: @escaping (KeyPress) -> KeyPress.Result) -> some View   // macOS 14.0
struct KeyPress { let key: KeyEquivalent; let characters: String; let modifiers: EventModifiers; let phase: KeyPress.Phase; enum Result { case handled, ignored }; struct Phases: OptionSet { static let down, up, repeat, all }; enum Phase { case down, up, repeat } }   // macOS 14.0
@export(implementation) nonisolated init(_ titleKey: LocalizedStringKey, text: Binding<String>)                    // TextField init(_:text:), macOS 10.15
@export(implementation) nonisolated init<S>(_ title: S, text: Binding<String>) where S : StringProtocol             // TextField init(_:text:)-2laoi
nonisolated init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?)                              // TextField init(_:text:prompt:)-70zi2, macOS 13.0
nonisolated init<S>(_ title: S, text: Binding<String>, prompt: Text?) where S : StringProtocol                      // TextField init(_:text:prompt:)-4kzyv, macOS 13.0
nonisolated init(id: String, @ContentBuilder makeContent: @escaping () -> Content)                                  // WindowGroup init(id:makeContent:), macOS 11.0+; init(id:content:) is DEPRECATED macOS 15
nonisolated func handlesExternalEvents(matching conditions: Set<String>) -> some Scene                               // scene/handlesexternalevents(matching:), macOS 11.0+
nonisolated func formStyle<S>(_ style: S) -> some View where S : FormStyle                                          // view/formstyle(_:), macOS 13.0
nonisolated static var grouped: GroupedFormStyle { get }                                                            // formstyle/grouped; struct GroupedFormStyle, macOS 13.0
nonisolated func labelsHidden() -> some View                                                                        // view/labelshidden(), macOS 10.15
nonisolated func progressViewStyle<S>(_ style: S) -> some View where S : ProgressViewStyle                          // view/progressviewstyle(_:), macOS 11.0
init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis)                                             // TextField init(_:text:axis:)-7n1bm, macOS 13.0
nonisolated func lineLimit(_ limit: PartialRangeFrom<Int>) -> some View                                             // view/linelimit(_:)-251ko, macOS 13.0
nonisolated func controlGroupStyle<S>(_ style: S) -> some View where S : ControlGroupStyle                          // view/controlgroupstyle(_:), macOS 12.0
nonisolated func searchable(text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringResource) -> some View   // macOS 14.0
nonisolated init(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic)                 // ToolbarSpacer, macOS 26.0; SpacerSizing.flexible / .fixed
// ToolbarItemPlacement.primaryAction — docs: "In macOS … the location for the primary action is the leading edge of the toolbar"
// ToolbarItemPlacement.automatic — docs: "In macOS … places items in the current toolbar section in order of leading to trailing"
nonisolated init(kind: ToolbarDefaultItemKind, placement: ToolbarItemPlacement = .automatic)                        // DefaultToolbarItem, macOS 26.0; ToolbarDefaultItemKind.search, macOS 26.0
nonisolated func sharedBackgroundVisibility(_ visibility: Visibility) -> some ToolbarContent                         // ToolbarContent, macOS 26.0 (stub returns Self)
var accessibilityReduceMotion: Bool { get }                                                                          // EnvironmentValues, macOS 10.15
func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result     // macOS 10.15; Animation.smooth, macOS 10.15 per docs
static var minimize: SearchToolbarBehavior                                                                           // NOT available on macOS (iOS/iPadOS/Catalyst/visionOS 26 only) — gloss emulates it (D-152)
@MainActor static var navigation: NavigationControlGroupStyle { get }                                               // controlgroupstyle/navigation, macOS 12.0; "on macOS, a separated momentary segmented control"
static let navigation: ToolbarItemPlacement                                                                          // docs: "places navigation items in the leading edge of the toolbar ahead of the inline title"
nonisolated static var circular: CircularProgressViewStyle { get }                                                  // progressviewstyle/circular, macOS 11.0
nonisolated init<V>(value: V?, total: V = 1.0) where Label == EmptyView, CurrentValueLabel == EmptyView, V : BinaryFloatingPoint   // ProgressView init(value:total:), macOS 11.0
nonisolated func lineSpacing(_ lineSpacing: CGFloat) -> some View                                                   // view/linespacing(_:), macOS 10.15
init(@ContentBuilder content: () -> Content, @ContentBuilder header: () -> Parent, @ContentBuilder footer: () -> Footer)   // section/init(content:header:footer:), macOS 10.15
```
- `searchable(text:placement:prompt:)` (already stubbed) is documented with
  `prompt: LocalizedStringResource`; the stub keeps `LocalizedStringKey` (both accept a literal,
  and declaring both would be ambiguous).
- `WindowGroup.init(id:content:)` is deprecated from macOS 15 in favour of
  `init(id:makeContent:)` — identical call shape. The stub now declares only the surviving
  initializer, so callers compile against the non-deprecated one.

### AppKit — save and print
```swift
@MainActor class NSSavePanel
func runModal() -> NSApplication.ModalResponse                                     // macOS 10.0+ (docs metadata lists no introducedAt)
func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse    // macOS 10.6+; async overload listed with the completion-handler one
var url: URL? { get }
var nameFieldStringValue: String { get set }                                       // macOS 10.6
var allowedContentTypes: [UTType] { get set }                                     // macOS 11.0
var canCreateDirectories: Bool { get set }
var directoryURL: URL? { get set }                                                 // macOS 10.6
var message: String! { get set }                                                  // docs type is String! (implicitly unwrapped)
var prompt: String! { get set }
var title: String! { get set }
struct ModalResponse { static var OK: ModalResponse; static var cancel: ModalResponse }   // NSApplication
class NSPrintInfo { class var shared: NSPrintInfo { get set }; convenience init() }
@MainActor class NSPrintOperation
init(view: NSView, printInfo: NSPrintInfo)
func run() -> Bool                                                                 // "Runs the print operation on the current thread"
func runModal(for docWindow: NSWindow, delegate: Any?, didRun didRunSelector: Selector?, contextInfo: UnsafeMutableRawPointer?)
var jobTitle: String? { get set }                                                 // macOS 10.5
var showsPrintPanel: Bool { get set }                                             // default true
weak var keyWindow: NSWindow? { get }                                             // NSApplication
```
- `NSPrintOperation.run()`'s docs give no discussion (declaration only); whether it presents
  the panel without a window is **UNVERIFIED** — the code prefers `runModal(for: keyWindow)`
  and only falls back to `run()` when there is no key window.

### WebKit — offscreen print
```swift
func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation?              // macOS 10.10+
func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation               // macOS 11.0+; "Returns the print operation object to use when printing the contents of the web view"
optional func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)     // WKNavigationDelegate, macOS 10.10+
optional func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error)   // macOS 10.10+
```
- Both navigation callbacks are declared with the implicitly unwrapped `WKNavigation!`
  parameter (docs tokens); the stub matches, since a `WKNavigation?` parameter would not
  satisfy the requirement as imported.
- **UNVERIFIED (needs a run):** that printing right after `didFinish` has the web view laid
  out — the html is static, but if the first page comes out blank, wait a beat after
  `didFinish` — and that `printOperation(with:)` paginates long notes.
# Milestone 12 additions — the trash, settings and backup (verified 2026-11-13, same method)

### AppKit
```swift
@MainActor class NSSavePanel                                     // init inherited (no init page; see note)
func runModal() -> NSApplication.ModalResponse                   // page carries no introducedAt (10.0-era)
var url: URL? { get }
var nameFieldStringValue: String { get set }                     // 10.6+
var directoryURL: URL? { get set }                               // 10.6+
var message: String! { get set }                                 // implicitly unwrapped
var prompt: String! { get set }
var canCreateDirectories: Bool { get set }
struct ModalResponse                                             // NSApplication: `static var OK`, `static var cancel`
static func post(element: Any, notification: NSAccessibility.Notification, userInfo: [NSAccessibility.NotificationUserInfoKey : Any]?)   // NSAccessibility, 10.7+
static let announcementRequested: NSAccessibility.Notification          // 10.7+
static let announcement: NSAccessibility.NotificationUserInfoKey         // 10.7+
func activateFileViewerSelecting(_ fileURLs: [URL])              // NSWorkspace, 10.6+
```
- `NSSavePanel()` has no initializer page of its own (the class page lists none); the stub
  models it as the inherited no-argument init, the same way `NSView()` is modelled. Apple's
  own sample code calls `NSSavePanel()`.
- `NSAccessibility.post(element:notification:userInfo:)` is the Swift-side struct API
  (`nsaccessibility-swift.struct`), not the old `NSAccessibilityNotifications` C API. Which
  element to pass for an announcement from SwiftUI is a judgement call (gloss passes
  `NSApplication.shared`); the API itself is verified.
- `allowedContentTypes` is deliberately NOT stubbed or used: there is no system UTType for a
  SQLite file, and the default name already carries the extension (D-124).

### SwiftUI
```swift
nonisolated struct Form<Content: View>                           // 10.15+; init(content:) (the stub uses @ViewBuilder spelling)
nonisolated struct Slider<Label, ValueLabel>                      // 10.15+
init<V>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V : BinaryFloatingPoint, V.Stride : BinaryFloatingPoint   // unlabeled
init<V>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V : BinaryFloatingPoint, V.Stride : BinaryFloatingPoint, ValueLabel == EmptyView
init<S: StringProtocol, V>(_ title: S, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V : Strideable    // Stepper, -99t9q, macOS 13
nonisolated struct LabeledContent<Label, Content>
init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) where Label == Text   // -6g03w, macOS 13
init(_ date: Date, style: Text.DateStyle)                        // Text, 11.0+
struct Text.DateStyle                                            // 11.0+: .date, .time, .relative, .offset, .timer
@frozen struct AnyTransition                                     // 10.15+: .opacity, .move(edge:), .combined(with:)
nonisolated func transition(_ t: AnyTransition) -> some View     // the -5h5h0 overload (the page's 14.0 is the generic form)
nonisolated func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View   // 10.15+
@frozen struct Animation                                         // static var snappy
```
- `tabItem(_:)` is **deprecated macOS 27.3**; its replacement (`Tab`/`TabContentBuilder`)
  needs macOS 15, above the target. That's why the Settings window is a form, not tabs (D-121).
- `Slider`'s unlabeled initializer's `Label == EmptyView` constraint comes from the page's
  generic constraints; the labeled one carries `ValueLabel == EmptyView` (per the docs page's
  conformance).

---

## Verified vs UNVERIFIED

- **78 documented sections** (one per `###` heading below; several hold more than one
  declaration) — every declaration in them was checked against the Apple docs JSON: exact Swift
  declaration tokens, macOS availability, actor isolation, and discussion notes.
- **10 distinct entries carry UNVERIFIED markers** (11 marker lines; the PDF notification
  spelling is noted both at its PDFKit entry and at its use), each with its reason inline:
  1. `NSTextView.init(usingTextLayoutManager:)` minimum macOS version — docs metadata omits
     `introducedAt` (likely docs data gap; TextKit 2 siblings are 12.0+).
  2. Swift spelling of `PDFViewSelectionChangedNotification` / `PDFViewPageChangedNotification` —
     docs JSON contains only the ObjC `extern NSNotificationName` declaration.
  3. `setValue(false, forKey: "drawsBackground")` on WKWebView — not documented anywhere in WebKit
     docs (verified absent); whether it works is unverifiable from documentation (private API).
  4. WKWebView drag/drop APIs — no public drag/drop API present in the WebKit docs index (absence
     verified, but absence of evidence in the index is the only proof available).
  5. `WKWebViewConfiguration()` — no initializer page exists in the docs JSON (the class page
     lists none); the inherited no-argument init is assumed, as Apple's sample code calls it.
  6. `NSTextView.scrollableTextView()` — whether it creates a TextKit 2 view; its doc page has
     no discussion (the code builds the view with `usingTextLayoutManager: true` instead).
  7. SwiftUI's `task` modifiers inheriting the caller's actor context — the SDK interface spells
     it `@_inheritActorContext`, which the docs drop.
  8. `NSOpenPanel()` / `NSSavePanel()` — no initializer docs page (NSObject's `init` reaches
     them); Apple's sample code calls them, as with `WKWebViewConfiguration()`.
  9. `NSPrintOperation.run()` — declaration only, no discussion; whether it presents a panel
     without a window. The code prefers `runModal(for:)` and falls back only without a key window.
  10. Printing right after `didFinish` having the web view laid out — needs a run; if the first
      page comes out blank, wait a beat after the navigation completes.

Sources: `https://developer.apple.com/tutorials/data/documentation/{webkit,appkit,pdfkit,swiftui,observation,uniformtypeidentifiers}/...json`, fetched 2026-11-13.
