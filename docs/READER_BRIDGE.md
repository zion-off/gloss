# Reader bridge protocol (EPUB engine)

The EPUB engine is foliate-js running in a `WKWebView`. Swift and JS talk through one small JSON
protocol. Both sides implement it and are tested against the same fixtures:

- TypeScript: `web/src/bridge/protocol.ts` (compiled into `Resources/reader/bridge/`), tested under Node in `web/test/`.
- Swift: `GlossReaderBridge` (`ReaderCommand`, `ReaderEvent`), tested in `Tests/GlossReaderBridgeTests/`.
- Fixtures: `Tests/Fixtures/bridge/commands/<type>.json` and `Tests/Fixtures/bridge/events/<type>.json`,
  one valid envelope per message type. Both test suites load every fixture.

## Transport

- Every message is an envelope: `{ "v": 1, "type": "<type>", "payload": { … } }`.
- **Swift → JS (commands):** `webView.callAsyncJavaScript("return await window.glossReader.receive(JSON.parse(command))",
  arguments: ["command": <ReaderCommand.encodedString()>], contentWorld: .page)` — the envelope travels as JSON text
  for the same reason as events. `receive` validates the envelope and returns `null` (or a small reply
  object where noted). Invalid commands reject with an `Error` whose message starts with `bridge:`.
- **JS → Swift (events):** `window.webkit.messageHandlers.gloss.postMessage(JSON.stringify(envelope))`. Events
  travel as JSON text so Swift decodes exactly what the glue validated, without WebKit's object bridging
  (`EPUBBridgeDriver.engineEvent(fromMessageBody:)` refuses anything that isn't a string).
- Book bytes never travel through JS strings: `open` gives a URL on the `gloss-reader` scheme that the
  app's `WKURLSchemeHandler` serves from the blob store; JS `fetch`es it into a `File` and calls
  `view.open(file)`.
- Locators for passages and positions are foliate CFIs (`epubcfi(…)`), scheme `epubcfi` on the Swift side.
  Book-text search chunks extracted on Linux use scheme `epub-section` with the spine index as the value.

## Shared types

- `Rect`: `{ "x": number, "y": number, "width": number, "height": number }` in CSS pixels, relative to the
  web view's viewport (top-left origin). JS adds the section iframe's offset.
- `HighlightColorName`: `"yellow" | "green" | "blue" | "pink" | "purple"`.
- `TocItem`: `{ "label": string, "href": string, "children": [TocItem] }`.
- `Appearance` (computed in Swift by `GlossReaderBridge.AppearanceStyler`):

  ```json
  {
    "flow": "paginated" | "scrolled",
    "css": "string passed to renderer.setStyles()",
    "layout": { "margin": 48, "gap": 0.06, "maxInlineSize": 720, "maxColumnCount": 2 },
    "colors": { "background": "#f8f1e3", "foreground": "#3b2f1e", "marker": "rgba(…)",
                "highlights": { "yellow": "rgba(…)", "green": "…", "blue": "…", "pink": "…", "purple": "…" } }
  }
  ```
  `layout` maps onto the paginator attributes `margin` (px), `gap` (fraction, `"6%"`), `max-inline-size`
  (px) and `max-column-count`.

## Commands (Swift → JS)

| type | payload | effect |
|---|---|---|
| `open` | `{ "openID": int ≥ 1, "url": string, "position": string \| null, "appearance": Appearance }` | close the open book if any, fetch the new one, `view.open(book)`, apply appearance, `view.init({ lastLocation: position })` or show the text start; emits `opened` (echoing `openID`) then `relocated` |
| `close` | `{}` | close the open book (`view.close()`); the reader shows nothing until the next `open` |
| `goTo` | `{ "target": { "cfi": string } \| { "href": string } \| { "fraction": number }, "flash": bool }` | navigate; with `flash`, briefly outline the target range (≈1.5 s) |
| `turnPage` | `{ "direction": "forward" \| "backward" }` | `view.next()` / `view.prev()` |
| `setAppearance` | `Appearance` | re-apply styles, layout attributes and flow; redraw annotations with the new colours |
| `setAnnotations` | `{ "highlights": [{ "id": string, "cfi": string, "color": HighlightColorName }], "markers": [{ "id": string, "cfi": string }] }` | the complete desired set; JS diffs against what it drew. A CFI that is both highlighted and marked is drawn once with both styles (foliate keys overlays by CFI) |
| `clearSelection` | `{}` | `view.deselect()` |
| `search` | `{ "query": string }` | run `view.search({ query })`, emitting `searchResults` batches |
| `clearSearch` | `{}` | `view.clearSearch()` |
| `revealSearchHit` | `{ "cfi": string \| null, "section": number \| null, "text": string }` | go to `cfi`, or search `text` within spine `section` and go to the first match; outline it like foliate search results |

## Events (JS → Swift)

| type | payload | when |
|---|---|---|
| `ready` | `{}` | the bridge loaded and waits for `open` |
| `opened` | `{ "openID": int, "toc": [TocItem], "sectionCount": number, "direction": "ltr" \| "rtl", "fixedLayout": bool }` | after `view.open`; `openID` is the one the `open` carried |
| `relocated` | `{ "cfi": string, "fraction": number, "section": { "index": number, "count": number }, "tocLabel": string \| null, "pageLabel": string \| null, "pagesLeftInSection": number \| null, "atStart": bool, "atEnd": bool }` | every foliate `relocate` |
| `selectionChanged` | `{ "cfi": string, "text": string, "label": string \| null, "fraction": number \| null, "rect": Rect }` | a non-collapsed selection settles (debounced ≈150 ms) |
| `selectionCleared` | `{}` | the selection collapses or is removed |
| `annotationActivated` | `{ "highlightIDs": [string], "markerIDs": [string], "rect": Rect }` | the user clicks a drawn highlight or marker |
| `linkActivated` | `{ "href": string, "external": bool }` | the user clicks an external link in the book |
| `searchResults` | `{ "query": string, "items": [{ "cfi": string, "label": string \| null, "excerpt": { "pre": string, "match": string, "post": string } }], "progress": number, "done": bool }` | while a `search` runs |
| `error` | `{ "message": string, "context": string \| null, "openID": int \| null }` | anything that failed on the JS side; `openID` names the `open` that failed, and the controller ignores failures of opens a newer one replaced |

## Switching books

Events carry no book identity, so opens are numbered (review 3):

- Swift gives every `open` a new `openID`; `opened` echoes it. `ReaderController` drops book events
  (`relocated`, `selectionChanged`, `selectionCleared`, `annotationActivated`, `linkActivated`) from the
  moment it asks for a book until the `opened` with that id arrives, and ignores `opened` replies to
  opens a newer one replaced. Book commands wait for the `opened` too.
- The glue runs commands one at a time in arrival order (`search` only *starts* there; its results
  stream as events, and a newer `search`, `clearSearch`, `close` or `open` stops it).
- `open` closes the previous book before fetching the next, in the same page. Once a book is closed
  nothing about it reaches Swift: view-level listeners check that a book is open, and per-section
  listeners (the debounced selection) check the generation they were created in. So every event after
  `opened` belongs to the new book.

## Book scripts

Book sections become `blob:` documents in foliate's `allow-scripts` iframes, so scripts in a book must
never run (they could `fetch` other books from the scheme handler). Three layers:

1. The page CSP (`ReaderPagePolicy`), which `blob:` documents should inherit (CSP3). Unverified in
   WebKit: `docs/MACOS_HANDOFF.md`.
2. The glue vetoes every script resource foliate's loader asks about (`transformTarget` `load` event).
3. The glue strips script from every document-ish resource before it becomes a blob
   (`bridge/sanitize.ts`, `transformTarget` `data` event) — anything with a media type containing
   `xml`, `html` or `xsl` (review 4: generic XML is parsed by the same machinery as XHTML): `<script>`,
   `on*` attributes, `javascript:` URLs, `srcdoc`, `<base>`, meta refreshes, `xml-stylesheet`
   instructions, SVG animations that rewrite links or event handlers, and template content.

EPUB 3 `<object>`/`<embed>` content stays blocked (`object-src` falls back to `default-src 'none'`):
embedded objects are rare in books and plugins are the wrong thing to let a book start.

## Behaviour notes

- Keyboard: ←/→, PageUp/PageDown and Space turn pages inside the web view (respecting `direction`).
- `pagesLeftInSection` comes from the paginator's position in the current section; `null` in scrolled
  flow. Swift turns it into "3 pages left in chapter".
- Highlights use the colour from `colors.highlights`; markers draw a faint underline in `colors.marker`,
  visually separate from highlight colours.
- The web view's data store is non-persistent; JS keeps no state that must survive a reload.
- `index.html` loads its scripts through an inline `<script type="importmap">`; the scheme handler's
  response headers must not set a CSP that blocks import maps or module scripts.
