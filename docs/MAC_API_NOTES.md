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
- SwiftUI: scenes/commands/`View` modifiers are `nonisolated`; `OpenWindowAction` and
  `NSViewRepresentable` are `@MainActor @preconcurrency`.

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
```

---

## Verified vs UNVERIFIED

- **61 documented entries total; 57 fully verified** from the Apple docs JSON (exact Swift
  declaration tokens, macOS availability, actor isolation, and discussion notes).
- **4 entries carry UNVERIFIED aspects:**
  1. `NSTextView.init(usingTextLayoutManager:)` minimum macOS version — docs metadata omits
     `introducedAt` (likely docs data gap; TextKit 2 siblings are 12.0+).
  2. Swift spelling of `PDFViewSelectionChangedNotification` / `PDFViewPageChangedNotification` —
     docs JSON contains only the ObjC `extern NSNotificationName` declaration.
  3. `setValue(false, forKey: "drawsBackground")` on WKWebView — not documented anywhere in WebKit
     docs (verified absent); whether it works is unverifiable from documentation (private API).
  4. WKWebView drag/drop APIs — no public drag/drop API present in the WebKit docs index (absence
     verified, but absence of evidence in the index is the only proof available).

Sources: `https://developer.apple.com/tutorials/data/documentation/{webkit,appkit,pdfkit,swiftui,observation,uniformtypeidentifiers}/...json`, fetched 2026-11-13.
