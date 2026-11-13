# macOS handoff

Everything in this file was written on Linux and has **never been run**. It is the checklist for
the first sessions on a Mac. Commits that touched these files carry `[mac-unverified]` in their
subject (`git log --grep mac-unverified`).

Since D-099 the Mac modules **type-check** on Linux against stub frameworks
(`scripts/mac-typecheck.py`). A compile error on the Mac therefore most likely means a stub
disagrees with the real SDK: fix the code, the stub and `docs/MAC_API_NOTES.md` together. Known
modelling choices in the stubs: imported methods returning values are `@discardableResult` (Swift
never warns about unused results of Objective-C methods), and SwiftUI's `task` modifier inherits the
actor context, as its SDK interface says (`@_inheritActorContext`, absent from the docs JSON).

## How to build on the Mac

```sh
swift build                 # Linux + Mac targets
swift test                  # Linux-testable suites (run on macOS too)
(cd web && pnpm install --frozen-lockfile && pnpm test)
scripts/run-mac.sh          # builds GlossMac and wraps it in build/gloss.app (dev only)
scripts/check.sh            # works here too; it skips the stub type-check on a Mac
                            # (the real build already type-checks the Mac targets)
```

## First Mac session (what ran, what broke)

Run on macOS 26 / Xcode 26.2 / Swift 6.2 (Node 22.18 for the web tests; Node 23.7 breaks jsdom, and
corepack 0.31 cannot run pnpm 12 until `npm i -g corepack@latest`).

- **Compiled with three fixes:** `Columns.date` overload ambiguity, `NSApplication.ModalResponse.OK`
  (not `.ok`), `NSItemProvider.loadObject` returns a non-discardable `Progress`. Stub and notes follow.
- **Verified by hand:** the EPUB opens from the database, contents jumps, position restore, switching
  books and kinds; library grid, sidebar, trash view; passage links both ways (⌘K, marker click, hover,
  undo); markdown styling, format bar, slash menu open and filter.
- **Failed, fixed (all `[mac-unverified]` until re-checked):** the PDF pane stayed blank (the PDF session
  never posted `.ready`); a crash opening a book after a PDF (model text outran its parse in
  `SlashTrigger.detect`); PDF covers overflowing the grid cell; notes text black on black in dark mode
  (no foreground colour on styled runs); the subpage row invisible in dark mode (drawing appearance and
  an untinted icon); no way to name a page (the title field above the body, brief 21, was missing);
  I-beam over the format bar; book sections and layout switch shown on the library; title before the
  chevrons in the toolbar; the heading button's icon read as a font-size control.
- **Changed after feedback (unverified):** opening a book from the library, open quickly or a URL starts a
  fresh reader and notes history; back at the start of the trail goes to the library and forward comes
  back (`WorkspaceModel.goHome`/`returnToBook`). Layout changes animate. The sheet layout (reader card
  left, notes on the same paper right), the title field above the body, hidden markdown syntax (D-141)
  and hover/click on subpage rows were redone from feedback and await a re-check.
- **Open → reworked (unverified, D-142):** paginated EPUB scrolling. A wheel handler alone felt wrong;
  now the page follows a horizontal swipe and turns slide (checks under `EPUBReaderSession.swift`).
- **Still unverified:** the first crash (`.relocated` handled in `ReaderController`, a SIGBUS inside
  Observation) has not recurred but was never explained; click targets of links/markers feel small.
- **Stubs owed (Linux `mac-typecheck.py`):** `NSAppearance.currentDrawing()` /
  `performAsCurrentDrawingAppearance`, `NSImage(size:flipped:drawingHandler:)`, `NSColor.set()`,
  `NSWindow.titleVisibility`, `NSView.viewDidMoveToWindow`, `NSCursor.arrow`/`set()`, SwiftUI
  `onContinuousHover`, `onSubmit`, `onChange(of:initial:)`, conditional `ToolbarContent`. Verify each in
  Apple's docs JSON before adding (CLAUDE.md); the Mac build already type-checks them for real.

## Verify first (riskiest parts)

1. **EPUB opens from the database in the web view.** Written in milestone 9: import a book with
   `gloss import`, run `scripts/run-mac.sh`, pick it in the sidebar.
   - **Book scripts never run.** Import an EPUB whose chapters cover every vector: an inline
     `<script>` and an `onload="…"` attribute, an external `<script src>`, a `<template>` holding
     both, an SVG with a script and a `<set attributeName="onbegin">`, and — the vectors review 4
     added — one chapter whose media type is `application/xml` (and an `<iframe src>` pointing at
     another `application/xml` item) containing an XHTML-namespace script; each `fetch`es a
     `gloss-reader://app/book/…` URL and posts a message: nothing may execute. Then disable the
     glue's sanitizer (`guardScripts` in `web/src/glue.ts`) and check again: the page CSP alone must
     still stop them (WebKit inheriting the policy into `blob:` documents is the unverified
     assumption; docs/READER_BRIDGE.md "Book scripts").
   - **Switching books in place:** open book A, then B from the library, then A again quickly; the reader
     always ends on the last one asked for, and A's position is never saved onto B.
2. **Passage links resolve in both directions** (notes → book and book marker → note). Written in
   milestone 11 over the Linux-tested `LinkingCoordinator` and `ReaderController`; details in the
   `GlossReaderPDF`, `ReaderPopovers` and `WindowCommands` sections below.
   - In split view select words in the notes, select a passage in the book, press ⌘K: the words
     become a `gloss://passage/…` link in one undo step, and once the page saves a marker appears
     under the passage. Do it in an EPUB and in a PDF (on page 2 or later).
   - Click the link: the reader goes to the passage and flashes it. Click the marker: the notes page
     opens with the link selected and flashed; a passage linked from two pages lists both first.
   - Rest the pointer on the link: a popover shows the passage's quote, label and book.
   - Delete the link, then ⌘Z: the marker goes and comes back. Remove it with `gloss page write`
     from the terminal: the marker goes within about a second (the change monitor).
   - **Across books (D-102):** with book A's notes open, follow a link to book B (or go back in the
     reader to B): the reader swaps, the notes stay on A, and the sidebar's notes section reads
     "notes · A". Select words in A's notes and a passage in B, press ⌘K: the marker appears in B.
     Click it: A's note opens beside B without the reader moving. Click into the reader and press ⌘[:
     only the reader goes back; click into the notes and press ⌘[: only the notes do.
   - A link to something in the trash or deleted for good says so in an alert instead of doing
     nothing.
3. **Native markdown editor with links and the floating formatting bar.** Written in milestone 10;
   details in the `Sources/GlossEditor/` section below.
   - Type markdown (headings, emphasis, lists, task boxes, quotes, code): it styles as you type and the
     text stays raw markdown (`gloss read --raw` shows exactly what you typed).
   - Select words: the format bar appears above the selection (below it near the top of the pane);
     its buttons and the Format menu's shortcuts each make one undo step.
   - Type `/` on an empty line: the slash menu filters as you type, arrows and Return pick, Escape
     closes. A subpage made there shows as a row that opens the page.

## Every Mac slice: Apple-likeness pass

- Compare against Books, Notes and Preview: system components, standard menus and shortcuts, no custom
  chrome, modes or banners (CLAUDE.md "Design principles").
- Light and dark appearance, Increase Contrast, Reduce Motion and Reduce Transparency all look right.
- VoiceOver reads every custom control (format bar, slash menu, link chips, subpage rows, markers).
- Copy is lowercase, short and clear.

## Checklist by file

### `Sources/GlossReaderKit/` (milestone 9)

- `ReadingEngine.swift` — protocols and registry only; should just compile.
- `ReaderPane.swift`
  - The placeholder shows over the engine view for: no book, no engine for the kind (PDFs until
    milestone 11), and a book that failed to open. It must not cover a book that is showing.
  - `.task(id: reader.document?.kind)` creates the session the first time a book of a kind opens;
    switching EPUB → EPUB keeps the same web view (watch for a flash or a reload: there must be none).
  - `ReaderHostView` returns the session's view from `makeNSView`; check it resizes with the window and
    that closing the window releases the web view (no leak in the memory graph).

### `Sources/GlossReaderEPUB/` (milestone 9)

- `ReaderSchemeHandler.swift`
  - Open a large EPUB and switch away mid-load: no "task already stopped" exception (a load finishing
    after `webView(_:stop:)` must find no entry and drop its answer).
  - Check the Web Inspector's network tab: every `gloss-reader://` response carries `Content-Type`,
    `Cache-Control: no-store` and `nosniff`; module scripts load (WebKit refuses modules with a wrong type).
- `EPUBReaderSession.swift`
  - The page loads, the glue posts `ready`, the book opens at the saved position (risk #1).
  - Events arrive as strings (`postMessage(JSON.stringify(…))`); a non-main-frame message is ignored.
  - Clicking a web link in a book opens the browser (via `linkActivated`), never navigates the web view;
    `target=_blank` links open nothing in the app.
  - Kill the web content process (Activity Monitor, "gloss Web Content"): the page reloads and the book
    comes back where it was.
  - `underPageBackgroundColor` matches the theme when scrolling past the edges (sepia by default).
  - **One page colour (D-144), unverified:** open a paginated EPUB in the reader-only layout, in
    light and in dark system appearance, with each theme (light, sepia, night). The whole reader
    card is one solid colour: margins, the gap between the two columns, below a chapter's last
    lines, the blank page sliding in at a chapter end, and while rubber-banding in scrolled flow.
    Changing the theme in ⌘, recolours all of it once the window closes, rubber-band area included. Night: a
    book that sets its own dark text colour reads light-on-dark; links and highlights still show.
    If white still shows anywhere, inspect (Develop menu) whether `html` of the reader page has
    `--gloss-background` set and whether the iframe's `html` computed background is the theme's.
  - In debug builds the page is inspectable in Safari's Develop menu.
  - **Page turning feels like Books (D-142), paginated flow, a long reflowable book:**
    1. Two-finger swipe left slowly: the page follows the fingers. Lift under halfway: it slides back;
       past halfway: it slides on. A short quick flick turns one page; the momentum after it never
       turns a second one, and flicking again straight away turns the next page.
    2. Swipe at the last page of a chapter: a blank page slides in, then the next chapter appears at
       its start (backwards: the previous chapter at its end). At the very first/last page nothing moves.
    3. Two-finger vertical swipe: nothing happens (pages slide sideways). A mouse wheel: one page per notch.
    4. Arrow keys, Page Up/Down, Space and Shift-Space turn with a ~300 ms slide; ↑/↓ turn too. With
       System Settings › Accessibility › Display › Reduce motion on, turns cut instead of sliding.
    5. Scrolled flow: trackpad and wheel scroll natively with momentum, ↑/↓ scroll by lines.
    6. An RTL book: swiping and ←/→ move visually (← goes forward); Space/↓ still go forward.
    7. Tune if needed: `TURN_DISTANCE`/`LATCH_DISTANCE` in `web/src/bridge/swipe.ts`, the lift-velocity
       push is foliate's `snap` (velocity in px/ms × page width).
- `EPUBReadingEngine.swift` — `ReaderBundle.directory()` finds `reader/` both in `build/gloss.app` and
  when running the bare executable (`swift run GlossMac`).

### `Sources/GlossMac/` (milestone 9)

- `GlossApp.swift` — on Linux this target is a stub that prints a line (D-084); on the Mac `@main`
  must pick the SwiftUI branch. A library that can't open shows the failure instead of a window.
- `AppRoot.swift`
  - The library opens at `~/Library/Application Support/gloss/library.sqlite` (or `GLOSS_LIBRARY`),
    the same file the cli uses: import with the cli while the app runs and the book appears within a
    second or so.
  - Reading settings saved in the store give the theme of the first book opened.
  - Maintenance runs once at launch, off the main actor.
- `Sources/GlossUI/MainWindow.swift` (moved from GlossMac in milestone 12; it now takes the
  services, the engines and the once-per-launch `prepare` from the root)
  - Selecting a book opens it; selecting another switches in place; the window title is the book's.
  - Trash the open book with `gloss book trash` while it's showing: the reader blanks to "pick a book".
  - A second window (⌘N) has its own reader and selection.
  - The poll loop stops when its window closes (no polling from closed windows).
- `PDFKitCoverRenderer.swift` — import a PDF; its cover is the first page. Rotated first pages may come
  out sideways (rotation isn't applied); check, and use `PDFPage.rotation` if so.
- `scripts/run-mac.sh` — builds `build/gloss.app` (ad hoc signed) and opens it; `--no-open`, `--release`.

### `Sources/GlossReaderPDF/` (milestone 11)

- `PDFReaderSession.swift` — one object is session, driver and overlay provider (no bridge).
  - Open a PDF from the sidebar: it renders, the position saves, reopening returns to the page.
  - Select text: the selection popover (highlight colours, add to notes) anchors to the first line.
  - Highlights fill in their colours, markers underline; clicking either opens its popover; clicks
    outside them select text normally (the overlay's `hitTest` returns nil there).
  - ⌘K over a book selection + a notes selection links them; the marker appears on the PDF page
    **at once, without scrolling** (review 6: `show(_:)` pushes new marks into the overlays on
    screen; every page gets an overlay, marked or not).
  - The flash outline on a passage jump appears and fades after 1.5 s.
  - A passage jump puts the passage's first line at the top of the view: the destination's point is
    the top of that line, taking PDFDestination's point as the view's top-left corner (PDF's own
    /XYZ model; Apple's docs only say "page space"). If the line lands just above the view, use the
    line's bottom instead.
  - Links inside the PDF open in the browser, never in the reader.
  - `.PDFViewPageChanged` / `.PDFViewSelectionChanged` — the Swift spelling of the two notification
    names is the importer's; the docs JSON only has the ObjC extern. If they don't compile, the fix
    is the spelling on this line.
  - The overlay converts page → PDF view → itself when drawing, and superview/window → PDF view →
    page for clicks (review 6: PDFKit places each overlay over its page, not at the PDF view's
    origin). Verify highlights and markers land on their text **on the second and later pages**,
    at several zoom levels, and that clicks on them hit (and clicks beside them select text).
  - The marker underline sits under the text's baseline side whether or not the overlay is flipped.
  - A search hit with a page jumps to its own occurrence on that page and flashes it; only a hit
    without a locator searches the whole document.
  - The TOC comes from the PDF outline (nested, at most 4 levels and 2000 nodes); entries whose
    destination PDFKit can't resolve hand their children up instead of pointing at page 1.
- `PDFReadingEngine.swift` — registration only; PDFs now open with an engine (the "can't show this
  kind" placeholder should be gone).

### `Sources/GlossReaderKit/ReaderPopovers.swift` + `ReaderPane.swift` (milestone 11)

- One popover at a time over the reader, anchored to the selection/mark (top-left `ReaderRect`
  contract): selecting text offers the five highlight colours and "add to notes"; clicking a
  highlight offers recolouring (current colour checked) and "remove highlight" (⌘Z restores it);
  clicking a marker linked from several notes lists them with the linking line.
- The popover is attached to a transparent overlay at `.rect(.rect(anchorRect))`; check it points at
  the selection at different window sizes and scroll positions, in both engines. CSS px = points is
  assumed for the EPUB engine's anchors (true at the default zoom).
- `UndoManager.setActionName(_:)` (standard, not in the verified notes) names the undo item.
- The session host belongs to the window: switch to notes only (⌥⌘3) and back (⌥⌘1) — the book must
  stay where it was without reloading.

### `Sources/GlossUI/WindowCommands.swift` (milestone 11)

- The Go menu: back/forward (⌘[/⌘]), acting on the notes pane when the editor has focus, else the
  reader. Check that focus routing is right: click into the reader, ⌘[ goes back a book; click into
  the notes, ⌘[ goes back a page.
- "link to passage" (⌘K) and "add to notes" in the Format area after the text formatting items.
  Both apply through the editor's coordinator (one undo step). Enabled state comes from the models:
  ⌘K disabled with the hint as its tooltip ("now select a passage in the book", …).
- Two windows: the commands act on the key window's models (`focusedSceneValue`).
- View menu: "reader and notes" ⌥⌘1, "reader only" ⌥⌘2, "notes only" ⌥⌘3, checkmarked (toggles); the
  toolbar's segmented control mirrors them. The layout persists and applies to every window.
- Toolbar: back/forward on the leading edge (a `ControlGroup`), the layout switch on the trailing
  side. SF Symbols `rectangle.split.2x1`, `book`, `note.text`, `chevron.left/right` — standard names,
  but check they render.

### `Sources/GlossUI/SourceList.swift` + `MainWindow.swift` (milestone 12)

- One source list (D-101), `.sidebar` style: "library" (all, books, pdfs with their formats'
  symbols, trash with a count badge that disappears at zero), then, with a book open, "reading" (the
  book), "contents", "highlights" and "notes" — the last three collapsible, remembered per window
  across relaunches (`@SceneStorage`).
- The detail column follows the selection: a shelf shows the library, the trash shows the trash, the
  book and anything in it show reader and notes. Click "all", then the book again: the reader must
  come back where it was without reloading (the session lives in the window).
- Clicks go through `AppModel.select`, which updates `workspace.sidebar` asynchronously; check the
  highlight doesn't flicker back to the previous row on a click (a page row awaits the page read
  first). Clicking empty space must not deselect.
- A contents entry jumps the reader there; a highlight jumps and flashes it; a page opens it in the
  notes. Each reveals its pane when the layout hides it (try from "notes only" and "reader only").
- Highlights: colour dot, two lines of passage, its location label. Right-click › "remove
  highlight" and the delete key (Edit › Delete via `onDeleteCommand`) both remove it; ⌘Z brings it
  back and the row returns.
- Long tables of contents: check scrolling; nested entries are indented rows now, always shown
  (D-147, no disclosure triangles); untitled pages show as "untitled".
- **Row alignment (D-147), unverified:** with a book open, "all", the shelves and "trash" sit
  exactly where they sit on the library (icons and titles at the same x); click "all" and back to
  the book: nothing in the sidebar moves sideways. Nested contents entries and subpages step in
  14 pt per level. If rows still shift, the collapsible `Section(isExpanded:)` headers are the
  next suspect.
- The title bar follows the detail column: the shelf's name, "library", "trash", or the book's title.
- **Back/forward look like Finder's (D-150), unverified:** the toolbar reads [sidebar toggle]
  [back|forward as one grouped pair] [title] … [layout picker] [search]. The pair is the system's
  navigation control group: one capsule (glass on macOS 26), system chevrons close together,
  hover highlight per half, a disabled half greyed out; tooltips "back (⌘[)" / "forward (⌘])",
  and ⌘[ / ⌘] still work. The title has no capsule of its own and appears once. Opening a book
  still collapses the sidebar; on macOS 14 the system title sits after the pair.

### `Sources/GlossUI/LibraryGrid.swift` + `LibraryFeatures.swift` + `LibraryCommands.swift` (milestone 12)

- The library grid: covers in adaptive columns (Books-style), the format's badge bottom-trailing
  on the cover, a thin progress bar only under books that were opened, title and author below.
  Check light/dark, and that the generated fallback (title/author on a tinted cover) never
  changes colour for the same book across relaunches.
- A single click opens the book; the context menu offers open, edit details…, move to trash
  (which shows the undo toast, and ⌘Z brings the book back, open or not).
- **The whole window is a drop zone** (review 7 caught the wiring never being applied): drop
  epub/pdf files or a folder anywhere over the window — including over the reader — and the grid
  highlights and imports; ⇧⌘A must open the panel too (both funnel into the same import).
- The "recently read" shelf shows above the grid on "all" only, and disappears on a filtered
  shelf or when nothing was opened yet.
- The sort menu (trailing toolbar, arrow.up.arrow.down) switches recent/title/author/date added;
  the choice survives relaunch and a **second open window** follows within a second (its menu
  checkmark moves too).
- Empty states: no books at all → "nothing glossed yet" with an import… button; a filtered shelf
  with no books → "no pdfs yet" (the shelf's name).
- File › import… (⇧⌘A) opens an NSOpenPanel as a sheet: multiple files AND folders, filtered to
  epub/pdf. Importing shows a small circular progress indicator in the toolbar (D-148): spinning
  while folders are listed, then filling file by file; its tooltip says what it's doing
  ("reading…", "storing…"); it disappears when done, and VoiceOver announces "added …". Never
  beachballs. Importing a duplicate shows the "already in your library" alert; "open it" opens
  the existing copy.
- Drag files or a folder anywhere onto the window: the library gets an accent-colour rounded
  outline (no banner, D-148) and the import runs. **Verify a drop over the reader's web view still reaches the
  window-level drop zone** — WKWebView has no public drag API (MAC_API_NOTES), but if it
  swallows file drags the drop needs a grid-level `onDrop` too.
- Dropping a non-book file (a .png, say) anywhere outside the details sheet is silently ignored
  (the extension filter drops it); check nothing looks broken.
- Import progress while a book is open (a Finder or `gloss://` import): the toolbar indicator shows
  there too; check the import completes and the grid updates when you go back to it. Import 8
  books at once: the ring fills in 8 steps, VoiceOver reads "importing, 3 of 8" on it and "added 8
  items to your library" at the end; a duplicate or broken file still gets the alert.
- Two windows: import from one; the other's grid follows at once (windows in one process hear
  each other's writes, review 7 — trashing, restores, details edits and opens included).
### `Sources/GlossUI/SearchPane.swift` + `MainWindow.swift` (milestone 12)

- The toolbar search field (brief 31): `.searchable` in the toolbar, scope menu via
  `.searchScopes(activation: .onTextEntry)`. Check: the field sits in the toolbar with the
  prompt "search"; typing shows the scope menu under it (in split view: "this book", "this
  book's text", "this book's notes", "all notes", "library"; on the home shelf: "library",
  "all notes"); the scope follows the open document (open another book — the menu and the
  default scope change).
- While the query is non-empty the results **replace the detail column** (Mail-style, D-130):
  grouped "notes" / "in the book" / "library", each row title + subtitle + snippet with the
  match in the accent colour. Check a query that hits all three groups from split view.
- Choosing a result dismisses the search and jumps: a notes hit opens the page with the match
  selected and flashed (`showFindIndicator`); a book-text hit goes to the passage and flashes it
  (EPUB: the engine finds the match text near the chunk locator; PDF: jumps to the page and
  highlights its occurrence); a library hit opens the book. Check from "reader only" and
  "notes only" layouts — the needed pane appears.
- Keyboard: arrow keys move through the list (a plain `List` selection), Return/typing Enter
  on a row selects it (single click selects; selection jumps). Check arrow keys actually move
  selection and that typing while the list has focus edits the field.
- The empty state ("no matches") shows while the query is non-empty and nothing was found.
- **Search as a toolbar icon on macOS 26 (D-152), unverified:** the trailing toolbar reads
  [sort][🔍] on the library, [layout picker][🔍] in a book, the import ring before them while
  importing. Click the magnifying glass: the field appears in its place, focused, with the scope
  menu once you type. Escape with an empty field (or clicking outside with it empty) folds it back
  into the icon; with a query it stays a field. **Riskiest assumption:** the field's `searchable`
  sits on a background view that appears only while the search is open — if no field shows, or it
  doesn't take focus, move that `searchable` to the detail column (keeping the condition). On
  macOS 14/15 the standard always-visible field stays. There is no ⌘F for it: ⌘F is the notes
  editor's find bar.
- **Clearing the field keeps the search (D-151), unverified:** type "whale", then clear the field
  with backspace (or the field's clear button while text remains): the results pane stays and
  shows "search your books and notes · type to search <scope>", not the library. Escape, or
  clicking outside with the field empty, closes the search and the previous view returns. With
  a query standing, clicking outside keeps the results.
- Debounce: type fast — the results follow the last keystroke, never one query per character,
  and the UI never blocks (searches run off the main actor through `SearchService`).

### `Sources/GlossUI/QuickSwitcherPane.swift` + `WindowCommands.swift` (milestone 12)

- File › open quickly… (⇧⌘O, D-071) opens a small sheet over the window: one field, results
  (books and pages, mixing titles and note text like the model's search), the keyboard's pick
  highlighted. Check the menu item is in the File menu after "new", the shortcut is ⇧⌘O (not
  ⌘O — File › open must still be untouched), and the field is focused when it opens.
- Keyboard: ↑/↓ move (wrapping), Return opens the pick, Escape closes the sheet. **The arrows
  must move the selection and not the text caret** — `onKeyPress` on the TextField intercepts
  and returns `.handled`; if on a Mac the caret moves instead (onKeyPress not consulted before
  the text view), the fallback is hidden `Button`s with `.keyboardShortcut(.upArrow, modifiers: [])`
  inside the sheet.
- The field takes focus when the sheet opens (`@FocusState` set in `onAppear`); if that races
  the sheet's animation on a Mac and the field isn't focused, move the focus set to
  `.onAppear` + a short `Task.sleep`, or use `.defaultFocus`.
- Empty query shows the "nothing yet" state (Xcode-like: no recents).
- Opening a book from the sheet opens it in this window (reader + notes follow, today's both-
  panes behaviour).

### `Sources/GlossUI/ExportCommands.swift` (milestone 12)

- File menu: "export book's notes…", "export this page…", "export page and subpages…" after
  "new"; enabled only with a book/page open. Each runs the export, then a save panel with the
  default file name from the exporter ("Camus.md"); ⌘S is NOT taken (save is autosave).
- While a save or print panel is up, all five items stay disabled — the three File-menu exports,
  the notes pane's context-menu exports, and print notes (`ExportActions.isBusy`): check the
  menus grey out with a panel open and come back when it closes.
- The notes pane's context menu carries the two page exports.
- File › print notes… (⌘P) replaces the empty print group: it exports the open page with its
  subpages to html, loads it into an offscreen non-persistent WKWebView, waits for
  `didFinish` (5s timeout), and runs `printOperation(with: NSPrintInfo.shared)` as a modal on
  the key window. Check: the print panel appears **as a sheet on the window**, the preview
  shows the notes with the print stylesheet, several pages paginate, and the panel's PDF menu
  saves a working PDF. If the panel misbehaves, the fallback is `operation.run()`.
  **If the first page comes out blank**, the web view hadn't laid out at `didFinish` — wait a
  beat (or poll `webView.isLoading`) before printing.
- A failed export/print shows the alert from `ExportModel.failure` ("couldn't export…").

### `Sources/GlossUI/URLHandling.swift` + `GlossApp.swift` + `scripts/run-mac.sh` (milestone 12)

- `gloss://` links from outside (brief 16): with the app running, from Terminal run
  `gloss open "<a link>"` (or `open 'gloss://book/<id>'`) — the link routes into the **existing
  window** (D-136: `WindowGroup(id: "main")` + `handlesExternalEvents(matching:)`), the book/
  page/passage opens, and no duplicate window appears. With no window open, one opens with
  the destination. A link to something trashed or missing shows the window alert ("that link
  points at …, which is in the trash — bring it back first" / "that link points at something
  that's gone").
- Finder double-click on an .epub or .pdf with gloss closed: gloss launches and imports it
  (progress shows in the library import state), then opens it. Double-clicking the same file
  again opens the **existing copy** (no duplicate document). Double-clicking a .txt does
  nothing except the "gloss can't do anything with…" alert — gloss must not become the default
  handler for it. **Info.plist verification (D-137):** after `scripts/run-mac.sh`, check
  `build/gloss.app/Contents/Info.plist` contains CFBundleURLTypes (gloss) and
  CFBundleDocumentTypes (org.idpf.epub-container, com.adobe.pdf); run
  `/usr/libexec/PlistBuddy -c Print CFBundleURLTypes build/gloss.app/Contents/Info.plist`.
  If Finder still doesn't offer gloss, LaunchServices may need the app moved into /Applications
  or `lsregister -f` on the bundle.
- The url scheme and document types only exist in the dev bundle `run-mac.sh` builds — a bare
  `swift run GlossMac` has neither, so external links won't reach it (expected).
### `Sources/GlossUI/TrashView.swift` + `TrashToast.swift` (milestone 12)

- The trash view: click "trash" in the sidebar. Each row shows an icon, its title, the book a
  page lived in, and `trashed 2 hours ago · gone for good in 28 days` (both dates are live
  `Text(date, style:)`s, so they must tick on their own) or `kept until you empty the trash`.
- "put back" (the row's button and the context menu) restores; the note at the bottom says
  `restored “x” and 2 more` when a cascade pulled its containers back too. The sidebar badge
  follows every trash, restore, purge and empty — also from the cli: run `gloss trash empty`
  in a terminal while the window is open.
- A restore that brought nothing back (the entry purged meanwhile) shows the problem capsule —
  `couldn't put it back — it may have gone for good` — in preference to the "restored" note,
  in the same material capsule and with the same 12pt bottom gap as it. Purging the entry or
  emptying the trash clears it. Check both capsules: padding, light, dark, Increase Contrast
  and Reduce Transparency.
- "delete for good…" (context menu) and "empty trash" (toolbar) confirm first, Apple-style and
  lowercase; the empty one names how many things go.
- The undo toast: right-click a notes page that isn't the book's main page, or the book row in
  "reading" → "move to trash". A material capsule slides up from the bottom of the window,
  says `“moby dick” moved to the trash`, offers "undo", and goes away on its own after ~6 s.
  A second trash replaces the first toast.
- ⌘Z restores after the toast is gone (registered with the window's undo manager, D-019;
  Edit › Undo reads "move to trash"). Two trashes in a row undo in reverse order. There is no
  redo after an undo (D-127).
- VoiceOver: the toast posts an announcement through `NSAccessibility.post` with
  `NSApplication.shared` as the element — check it reads the message once, naturally, and
  doesn't fight the "undo" button's own accessibility (the element choice needs a run).
- Trashing the open book blanks the reader to "pick a book" and shows the grid; trashing the
  open page lands the notes on its parent (or the book's main page); undo brings the book or
  page back open where it was.
- Edit › Delete and the delete key on a selected page, the book row, or a highlight act on
  each; the book's main page answers with the "trash the book instead" toast and stays.
- The toast must not cover the toolbar or the trash view's "restored" note; check light, dark,
  Increase Contrast and Reduce Transparency.

### `Sources/GlossUI/SettingsView.swift` + `Sources/GlossMac/GlossApp.swift` (milestone 12)

- ⌘, opens the Settings window: one grouped form (D-145) with "reading" (a sample page, then
  theme, text size, line spacing, margins, layout, columns) and "trash" (keep trashed things: for
  7, 30 or 90 days, or forever; default 30). It is a form, not tabs, because the only tab API a macOS 14 target can use
  is deprecated in the newest SDK (D-121).
- Everything persists in the one library file: `gloss trash keep 7` and the picker agree, both
  ways, while the app runs.
- **Applied on close (D-149, supersedes D-122's live apply), unverified:** with an EPUB open,
  change theme, size, spacing, margins, flow and columns: the open book does NOT change while the
  Settings window is open (only the sample page does). Close the window (red button or ⌘W): the
  book takes the final values once, at the same reading position, in every window with an EPUB
  open. Close without changing anything: the book doesn't flicker. A PDF can't reflow, so it picks
  changes up at its next open.
- A book opened after the window closed starts with the new settings (AppRoot's appearance source
  follows the same notification, so it also updates on close). Settings saved while a book is mid-open (between click and `.opened`) apply
  at the next open — check the theme doesn't stick stale in that window.
- **Crash fixed (D-143):** changing any setting twice within 400 ms aborted the app in
  `AppSettingsModel.scheduleSave` (`swift_task_dealloc`). Drag a slider back and forth and click
  through every theme quickly: no crash, and the book follows when the window closes. Undo toasts (trash two things
  quickly) use the same sleep — check they still dismiss after ~6 s.
- **Redone (D-145), unverified:** the window is 480 pt wide and as tall as its content, grouped
  like System Settings: labels left, controls right-aligned, no label shown twice. Theme, layout
  and columns are segmented controls; each slider shows its value (pt, or the spacing factor) in
  a fixed-width column that doesn't jiggle. The sample page at the top follows every control
  instantly as you drag: theme colours, text size, line spacing (the reader's system font), the
  margins (at half scale), two columns under pages + two, one column under scrolling or one. Columns greys out under "scrolling". A failed save
  shows as the trash section's footer. Labels don't truncate; dragging a slider saves once.

### `Sources/GlossUI/BackupCommands.swift` (milestone 12)

- File › back up library…: the save panel offers `gloss backup <date>.sqlite` — the same name
  the cli's `gloss backup` gives a folder (shared `LibraryBackupNaming`).
- Picking an existing file reports "already exists — gloss never overwrites a backup" and
  leaves the file untouched (the model pre-checks; the store refuses too).
- The copy runs off the main actor: with a big library the window must stay responsive during
  the backup.
- Success reports with a "show in finder" button (Finder opens with the file selected);
  failure says why. The command acts on the key window — with two windows open, it works from
  whichever is key.

### `Sources/GlossUI/DocumentDetailsSheet.swift` (milestone 12)

- "edit details…" (the grid's and the source list's book-row context menu) opens the sheet: title,
  author, and the cover (a preview, choose…, drop an image, remove the custom cover).
- An empty title is refused (the save button disables); unchanged fields are not written; a save
  refreshes the window's grid, title, source list and the notes editor's breadcrumbs (a rename
  changes them).
- The root page's title follows a title change only if it still matched the old one (core rule);
  check the sidebar's page tree shows the new name.
- Choosing a cover image (an NSOpenPanel as a sheet on the sheet — nested sheets, see the
  "APIs I was unsure about" entry) and dropping one both work; "remove" returns to the file's
  cover, then the generated one. The grid's cover cache invalidates (the new cover shows).

### `Sources/GlossEditor/` (milestone 10)

- `NotesEditorTheme.swift` — system fonts and colours only; check light/dark, Increase Contrast
  and Reduce Transparency all look right, and that headings/code/quotes read like Notes'.
- `NotesTextView.swift` — a click toggles a task box and opens a subpage row; verify the click
  target feels right (the box glyph plus half a character either side, not the whole line). Clicks
  map through `characterIndexForInsertion(at:)` in view coordinates (review 6: the old
  `characterIndex(for:)` wanted screen coordinates).
- `NotesEditorCoordinator.swift`
  - Typing is native (input methods, undo, find bar); the buffer must stay the raw markdown.
  - Smart quotes/dashes/text replacement are off — type `"` and `--` and they must stay ASCII.
  - The format bar and slash menu anchor to the selection/caret and follow scrolling
    (bounds-change notifications recompute the anchor); check they stay inside the window.
  - **The format bar sits above the selection when there's room and below it otherwise**, at the
    top and the bottom of a long page, scrolled and not. The anchor flips into SwiftUI's top-left
    space only when the scroll view isn't flipped (review 6 doubted review 5's unconditional flip);
    a bar mirrored to the other end of the pane means `isFlipped` isn't what the conversion
    assumed.
  - Model edits (format bar clicks, Format menu items, slash menu clicks and keys, Return/Tab in
    lists) all go through `NotesEditorCoordinator.apply` and land as ONE undo step each; ⌘Z undoes
    them one at a time and the styling follows.
  - `isRichText = false`: paste rich text from Safari and only the plain text arrives. **Check the
    storage attributes still draw** (heading sizes, dimmed syntax) with rich text off — code
    editors rely on this, but it's unverified here; if they don't, set it back to `true` and
    restrict pasteboard types instead.
  - A marker click in the book selects the link in the notes, scrolls to it and flashes it
    (`showFindIndicator`) — only once the right page is installed (`NotesReveal.pageID`).
  - A failed save shows "couldn't save — your words are still here" at the bottom; switching
    pages then offers keep/discard (Escape = keep editing; never silent loss).
  - Closing a window flushes the editor's pending save and the reader's position (`onDisappear`);
    check with `gloss page read` after closing mid-typing that the last words made it. The same
    flush keeps the window's last choices: close with ⌥⌘2 (notes only) and the library sorted by
    author, relaunch, and the window comes back notes-only sorted by author.
  - `.link` attributes make gloss and web links clickable with the pointing hand cursor; gloss
    links route inside the app, web links open the browser.
- `NotesEditorView.swift` — the overlays are SwiftUI over the scroll view, clamped to the pane's
  width (`GeometryReader`); check both stay inside the pane near either edge and at the top.
- `NotesEditorActions.swift`
  - The Format menu replaces the system's text formatting group (Font, Text submenus): its items
    carry Notes' shortcuts (⌘B, ⌘I, ⇧⌘7, ⌘ quote, ⇧⌘M, ⇧⌘K; no heading button, headings come from slash) and are enabled only while the notes
    text view has focus (`becomeFirstResponder`/`resignFirstResponder` overrides).
  - With focus in the reader, ⌘B does nothing (the item is disabled) and never bolds the book.
  - Two windows: the menu acts on the key window's editor (`focusedSceneValue`).
- `SubpageRowFragment.swift` — subpage block lines draw as rows (icon + live title + chevron,
  trashed ones dimmed and struck through) instead of raw markdown. Check: the row's height and
  icon match a Notes-like list, clicking anywhere on the line opens the page, arrow keys still
  step through the hidden line, and a rename from another window refreshes the title
  (`invalidateRows` on the next sync).
  - **Re-diagnosed (D-146), unverified; 1d26dd5 didn't fix it.** Rows are now hit by where they are
    drawn (the paragraph's first line fragment), drawn in that line only (fixed 28 pt, never
    wrapped), and the hover block is a subview under the text. Check, on a page whose text ends
    with a subpage row:
    1. Put the caret at the end of the row line and press Return: the row doesn't move; the caret
       sits on a fresh line one row-height below, not overlapping the row.
    2. Click on that empty line (anywhere, including just under the row's centre): the caret goes
       there, the subpage does not open. Clicking the row itself (icon, title, the empty right part,
       the chevron) opens it.
    3. Press Return a few more times and type: the text is body size, line spacing even from the
       first line after the row.
    4. Hover a row: a full-width rounded block appears under it (light and dark mode) and goes
       when the pointer leaves the row or starts typing; the cursor is the pointing hand only
       over the row.
    5. Put the caret at the row's end (arrow keys): the row's markdown never appears or wraps.
    6. If the block draws over the row's title rather than under it, TextKit draws text beneath
       its subviews here; it is translucent, so still fine, but note it.
    7. Click a row: the block vanishes at once (not ~0.5 s later, after the subpage opened).
    8. The row's icon isn't squished (the symbol at its own aspect, sized from the body font), and
       its title is exactly the size of the notes text around it. All plain notes text is now the
       system body font (it was the text system's Helvetica 12 fallback): check it reads like Notes.
- `NotesEditorCoordinator.swift` — the fragment delegate is `nonisolated` and builds the fragment
  there (TextKit's classes aren't main-actor isolated); only the read of the model's rows uses
  `MainActor.assumeIsolated`. It must never be hit from a background layout pass; if it ever crashes
  there, the rows snapshot needs a lock instead. `SubpageRowFragment` is not main-actor isolated
  either (its superclass isn't).
- `NotesHover.swift` + the text view's tracking area — resting the pointer on a passage link shows
  its quote, label and book in a transient popover (120 ms rest, one lookup per link, cancelled on
  move). Check: the popover anchors to the link's line, closes on click/scroll/leave, and nothing
  shows over web or page links. Leaving a link within the 120 ms rest must not open the popover
  over plain text afterwards (review 6: the pending lookup is cancelled on every close). The
  `NSTrackingArea(rect: .zero, … .inVisibleRect …)` pattern is documented (the rect is ignored) but
  needs a run.
- `Sources/GlossUI/MainWindow.swift` — the editor pane: page loads, the unsaved-changes alert,
  breadcrumbs, and the reveal (a marker click selects the link line and scrolls to it). The split
  layout switches with the workspace setting (reader and notes in an `HSplitView` since milestone 11).

## APIs I was unsure about

- `ContentUnavailableView(_:systemImage:description:)` is verified with a `LocalizedStringResource`
  title; the code passes string literals.
- `WKWebViewConfiguration()`: Apple's docs JSON has no page for a no-argument initializer (only
  `init(coder:)`), though Apple's own sample code calls it.
- `Bundle(url:)` over SwiftPM's resource bundle copied into `Contents/Resources`, and
  `url(forResource: "reader", withExtension: nil)` finding a directory in it.
- `WKWebView.load(_:)` and `reload()` return `WKNavigation?` without `@discardableResult`, hence `_ =`.
- `.navigationTitle(_:)` with a `String` (only the `LocalizedStringResource` overload page could be
  checked).
- `NSTextView(usingTextLayoutManager: true)` minimum macOS version (docs omit it; TextKit 2 siblings
  are 12.0+ — the target is macOS 14, so only the gap matters for the record).
- `NSView.boundsDidChangeNotification` on the scroll view's clip view (standard AppKit, not in the
  verified notes) and `postsBoundsChangedNotifications` defaulting to true.
- `NSColor.separatorColor` (verified, 10.14+) in the slash menu border, via `Color(nsColor:)`
  (verified, 12.0+): SwiftUI's `Color` has no `separatorColor`.
- Whether a paragraph's `elementRange` includes its line terminator (the row matcher handles
  either; verify rows actually draw on a real page).
- `textView.undoManager` being non-nil with `allowsUndo = true` when `install()` clears it.
- `NSResponder.becomeFirstResponder()`/`resignFirstResponder()` overrides returning `Bool`,
  `KeyEquivalent(Character)`, `@FocusedValue` in a `Commands` type, `@ObservationIgnored weak var`
  in an `@Observable` class, and `@Entry public var` on `FocusedValues` (each standard; none in the
  verified notes beyond `@Entry`/`focusedSceneValue` themselves).
- Storage attributes drawing in a plain-text (`isRichText = false`) TextKit 2 view.
- `firstRect(forCharacterRange:actualRange:)` returning screen coordinates and the screen → window →
  scroll-view conversion chain (`convertFromScreen` then `convert(_:from: nil)`), verified as declared;
  the composed result needs a run.
- `shouldChangeText(in:replacementString:)` + `replaceCharacters(in:with:)` + `didChangeText()` as the
  one-undo-step recipe for programmatic edits (each part verified; the composition needs a run).
- `NSImage(systemSymbolName:accessibilityDescription:)` (verified, 11.0+) and
  `NSAttributedString.draw(in:)` / `size()` (verified; `size()` is a method) inside an
  `NSTextLayoutFragment.draw(at:in:)` — drawing there needs a run.
- `NSTextContentStorage.documentRange` reached through `textContentManager` (documented on
  `NSTextElementProvider`, which it implements) and `NSTextParagraph.elementRange` mapping to
  UTF-16 offsets via `offset(from:to:)` — each verified, the composition needs a run.
- `PDFDocument` and `PDFPage.thumbnail(of:for:)` off the main thread (imports run there).
- `NSOpenPanel()`/`NSSavePanel()` (no initializer docs page; Apple sample code calls them) and
  `beginSheetModal(for:)` with the key window grabbed from `NSApplication.shared.keyWindow` out
  of SwiftUI — the sheet attaches to the SwiftUI window only if it is the key window when the
  command runs; if the import panel ever appears detached, that is why.
- `NSOpenPanel` with both `allowedContentTypes` set and `canChooseDirectories = true`: the type
  filter should apply to files while folders stay selectable — the docs don't spell the
  combination out; if folders grey out, drop `allowedContentTypes` and filter in code.
- `UTType(filenameExtension:)` returns nil for extensions no app on the Mac claims, so a
  registered format with such an extension would be unpickable in the import panel (epub and
  pdf are both system-claimed; only a future exotic format could hit this).
- `NSItemProvider.loadObject(ofClass: URL.self)` for Finder drags (the bridged generic overload)
  and one `onDrop` at window level receiving drops over the WKWebView reader — both need a run.
- The details sheet's image panel presented as a sheet on the sheet (`beginSheetModal` for the
  cover panel while the details sheet is the key window): nested sheets are standard AppKit,
  but the stacking needs a look.
