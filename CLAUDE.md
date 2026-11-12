# CLAUDE.md — working agreement for gloss

This file persists the rules for anyone (human or agent) working on this repository.
Read it at the start of every session, together with `docs/ARCHITECTURE.md` (design and
milestones), `docs/DECISIONS.md` (why things are the way they are) and
`docs/MACOS_HANDOFF.md` (what still needs a Mac to verify).

## The product in one paragraph

**gloss** (always lowercase in anything user-facing: app name, CLI, URL scheme, docs and
in-app copy) is a native macOS app for reading EPUBs and PDFs with a free-form markdown
notes page per book. Notes link to exact passages with standard markdown links using the
`gloss://` scheme, and the book shows which passages are linked from notes, like footnotes
you write yourself. MIT licensed. **The app targets macOS only** (see "Platform constraint").
iCloud sync must stay possible later: design the data layer for it, never build it. No
distribution, packaging, signing or update work.

## Platform constraint

- The app targets **macOS only**: SwiftUI/AppKit, TextKit 2, WKWebView, PDFKit. It does not
  need to run on Linux, Windows, the web, iOS or iPadOS. Any non-macOS app target is out of
  scope; do not add one, and do not declare other platforms in `Package.swift`.
- Only the core, storage, import, export and CLI modules are platform-portable, and only so they
  can be built and tested on the Linux VM and reused later.
- The Linux-buildable logic modules (`GlossMarkdown`, `GlossNotes`, `GlossReaderBridge`,
  `GlossAppModel`, `GlossTerminal`) are portable **for testing only**, under "keep Mac-only code
  thin" below. They hold no view code and no platform abstraction.
- **Do not abstract the UI layer for other platforms.** No view protocols, no cross-platform
  wrappers, no `#if os(iOS)`. Mac code uses AppKit/SwiftUI directly.

## Design principles

- When the plan does not specify a UI decision, do what a first-party Apple app (Books, Notes,
  Preview) would do. Prefer system components, system behaviour and Human Interface Guidelines
  conventions over custom designs.
- No custom chrome, modes, banners or novel interaction patterns where a standard macOS pattern
  exists. Prefer contextual commands, menus, popovers and sheets.
- Keyboard shortcuts follow the system and first-party apps (Notes for text formatting, Xcode's
  Open Quickly for the switcher). Never take a system shortcut (⇧⌘Q log out, ⌘P print, ⌘O open,
  ⌘H hide, ⌘M minimize, ⌘, settings).
- Copy is lowercase, short and a bit playful, never at the cost of clarity.
- Custom UI (the floating format bar, the slash menu, link chips) must still look and behave like
  something Apple could have shipped: system materials, system fonts, SF Symbols, standard
  animations, standard focus and accessibility behaviour.

## How to work

- Build the whole project without stopping for approval, in vertical slices that always
  build and pass tests.
- Record every significant decision, deviation from the brief and ambiguity resolution in
  `docs/DECISIONS.md` with a one-line rationale. Do not stop to ask.
- If something cannot be verified without running the app, implement it as well as possible
  and list it in `docs/MACOS_HANDOFF.md`.
- Verify third-party API details against current docs or source, not memory.
  Apple APIs: `docs/MAC_API_NOTES.md` (exact declarations, availability and actor isolation,
  verified against Apple's documentation JSON); anything marked UNVERIFIED goes in the handoff.
- Keep dependencies minimal; justify each one in `docs/DECISIONS.md`.
- Keep `docs/ARCHITECTURE.md` current when the design changes.

## Build environment

Development happens on a **Linux VM** without macOS, Xcode or Apple frameworks. The human
builds and verifies the Mac-only parts later, in batches.

- **Linux-buildable modules** (core, markdown, notes logic, app-model logic, storage,
  formats/import, text extraction, export, reader-bridge types, terminal UI, CLI) must build
  and pass all tests on Linux:
  - no Apple-only frameworks: swift-crypto instead of CryptoKit, no Combine, only portable
    Foundation (`FoundationXML`, `FoundationNetworking` where needed);
  - `swift build && swift test` from the repository root must be green;
  - the bridge tests must pass with `cd web && pnpm test` (Node 22).
- **Mac-only modules** (app, WKWebView/foliate reader, PDFKit reader, TextKit 2 editor,
  SwiftUI views) are always part of the package but every source file is wrapped entirely in
  `#if os(macOS) … #endif`. Swift still *parses* inactive `#if` regions, so the Linux build
  catches syntax errors in Mac code; it cannot type-check it. Write Mac code carefully
  against documented APIs.
- **Keep Mac-only code thin.** Anything that does not need an Apple framework lives in a
  Linux-testable module with unit tests: markdown tokenizing and styling rules,
  selection-to-markdown edits, slash-command matching, link and anchor handling, navigation
  history, search-scope derivation, trash and restore rules, export, bridge protocol,
  appearance CSS, view state. The Mac layer only renders state and forwards events.
- **Order of work:** Linux modules and the CLI first, fully tested. Then the Mac layer in thin
  slices, each listed in `docs/MACOS_HANDOFF.md` in the same commit that adds the code. Never
  let Mac-only code grow ahead of the testable core.
- **Web code is TypeScript, managed with pnpm.** JavaScript only where TypeScript is impossible:
  the vendored foliate-js files (byte-identical to the pinned commit) and the `.js` that `tsc`
  emits into `Sources/GlossReaderEPUB/Resources/reader/` for the web view (generated by
  `pnpm build`, committed because SwiftPM copies resources verbatim, never edited by hand;
  `pnpm check-build` fails if it is stale). Never use npm or yarn in this repo.
- Toolchain on the VM: Swift 6.4.2 at `/opt/swift`, system SQLite 3.45.1 (FTS5 enabled),
  Node 22, pnpm 12.

Useful commands:

```sh
swift build                      # all Linux targets (Mac targets compile to empty modules)
swift test                       # all Swift tests
(cd web && pnpm test)            # typecheck + bridge tests under Node
(cd web && pnpm build)           # regenerate the web view's .js from web/src
scripts/check.sh                 # everything above, used before every commit
```

## Independent review

- When a chunk of work (a milestone or a coherent slice) is finished and green, send an
  independent review sub-agent at **maximum effort** over the changes since the last review
  (correctness, concurrency, API misuse, code smell, test quality). It reports findings only;
  it changes nothing. Fix the findings, re-check, then commit the fixes. Keep a short log of
  review findings and fixes in `docs/REVIEWS.md`.

## Commit policy

- Granular commits: one logical change each. Tests go with the code they cover.
- Conventional Commits scoped by module: `feat(store): …`, `test(core): …`,
  `refactor(markdown): …`, `docs: …`, `chore: …`, `fix(cli): …`.
- Every commit builds and passes tests on the Linux targets (`scripts/check.sh`).
- Mac-only code may be uncompiled; such commits get a ` [mac-unverified]` suffix in the
  subject so the human can find and review them after building on a Mac.
- Commit as you go, never in bulk at the end.
- Commit only after `scripts/check.sh` exits 0. Never pipe its output into another command when
  gating a commit (a pipe reports the last command's status, not the check's).
- Tag milestones as `milestone-N` (see `docs/ARCHITECTURE.md`).
- Commit locally only. No pushing, history rewriting or force operations.
- Generated files and build products stay out of git (`.build/`, `web/node_modules/`, …).

## Engineering principles

- **SOLID is mandatory.** Every module has one reason to change. Depend on abstractions at
  the real seams — storage, blob storage, readers/engines, importers/formats, text
  extraction, search sources, exporters, slash commands, markdown block/inline parsers and
  styling rules, trashable entities, anything that varies by document kind — and not
  everywhere else. Do not wrap every class in a protocol.
- **Open/closed:** a new document format, search source, exporter, deletable entity, slash
  command or markdown element is *added and registered*, never wired in by editing existing
  code or branching on a kind. `DocumentKind` is an open struct, not an enum.
- **Liskov and interface segregation:** no no-op methods, no fat interfaces. Capabilities
  only some formats have (reflowable appearance, say) are separate protocols.
- **Dependency inversion:** `GlossCore` knows nothing about GRDB, SwiftUI/AppKit or WebKit.
  Concrete implementations are wired at composition roots, one per executable
  (`Sources/gloss/main.swift`, `Sources/GlossMac/GlossApp.swift`).
- **UI-free core:** the app and the CLI are thin clients over the same core services. The CLI
  never imports UI code. The portable modules stay free of UI and platform code so they can be
  reused later; the UI layer itself is macOS-only and not abstracted.
- **Testability:** time (`TimeSource`) and ID generation (`IDGenerator`) are injected. The
  core is test-first against the in-memory store.
- Modern Swift 6 with strict concurrency; SwiftUI first, AppKit where needed.

## Copy and naming

- The product name is `gloss`, lowercase, everywhere a user can see it.
- All in-app copy is lowercase, friendly and a little playful ("nothing glossed yet").
- Swift type names keep normal Swift casing (`GlossCore`, `PageService`).
