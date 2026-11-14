# CLAUDE.md — working agreement for gloss

Read `docs/ARCHITECTURE.md` (a one-page overview) at the start of a session. The code is the
source of truth; everything else in here is what the code can't tell you.

## The product in one paragraph

**gloss** (always lowercase in anything user-facing: app name, CLI, URL scheme, docs and in-app
copy) is a native macOS app for reading EPUBs and PDFs with a free-form markdown notes page per
book, plus a `gloss` command line over the same library. Notes link to exact passages with
standard markdown links using the `gloss://` scheme, and the book shows which passages are linked
from notes, like footnotes you write yourself. MIT licensed. **macOS only**: SwiftUI/AppKit,
TextKit 2, WKWebView and PDFKit are used directly, with no platform abstraction (no view
protocols, no cross-platform wrappers, no other app targets). iCloud sync must stay possible
later: design the data layer for it, never build it. No distribution, packaging, signing or update
work.

## Design principles

- When the plan does not specify a UI decision, do what a first-party Apple app (Books, Notes,
  Preview) would do. Prefer system components, system behaviour and Human Interface Guidelines
  conventions over custom designs.
- No custom chrome, modes, banners or novel interaction patterns where a standard macOS pattern
  exists. Prefer contextual commands, menus, popovers and sheets.
- Keyboard shortcuts follow the system and first-party apps (Notes for text formatting, Xcode's
  Open Quickly for the switcher). Never take a system shortcut (⇧⌘Q log out, ⌘P print, ⌘O open,
  ⌘H hide, ⌘M minimize, ⌘, settings).
- Custom UI (the floating format bar, the slash menu, link chips) must still look and behave like
  something Apple could have shipped: system materials, system fonts, SF Symbols, standard
  animations, standard focus and accessibility behaviour.
- Copy is lowercase, short and a bit playful, never at the cost of clarity ("nothing glossed
  yet"). The product name is `gloss` wherever a user can see it; Swift type names keep normal
  casing (`GlossCore`, `PageService`).

## Engineering principles

- **SOLID.** Every module has one reason to change. Depend on abstractions at the real seams
  (storage, blob storage, readers/engines, importers/formats, text extraction, search sources,
  exporters, slash commands, markdown parsers and styling rules, trashable entities, anything
  that varies by document kind) and nowhere else. Do not wrap every class in a protocol.
- **Open/closed.** A new document format, search source, exporter, deletable entity, slash command
  or markdown element is *added and registered*, never wired in by editing existing code or
  branching on a kind. `DocumentKind` is an open struct, not an enum.
- **Liskov and interface segregation.** No no-op methods, no fat interfaces. Capabilities only
  some formats have (reflowable appearance, say) are separate protocols.
- **Dependency inversion.** `GlossCore` knows nothing about GRDB, SwiftUI/AppKit or WebKit.
  Concrete implementations are wired at the composition roots, one per executable
  (`Sources/gloss/main.swift`, `Sources/GlossMac/AppRoot.swift`).
- **UI-free core.** The app and the CLI are thin clients over the same core services. The CLI
  never imports UI code.
- **Keep views thin.** Anything that does not need an Apple framework lives in a unit-tested
  module: markdown tokenizing and styling rules, selection-to-markdown edits, slash-command
  matching, link and anchor handling, navigation history, search scope, trash rules, export, the
  bridge protocol, appearance CSS, view state. The Mac layer only renders state and forwards events.
- **Testability.** Time (`TimeSource`) and ID generation (`IDGenerator`) are injected. Core logic
  is tested first against the in-memory store.
- Modern Swift 6 with strict concurrency, zero compiler warnings. Keep dependencies minimal and
  justify a new one in its commit message.
- Web code is TypeScript, managed with pnpm (never npm or yarn). JavaScript only where TypeScript
  is impossible: vendored foliate-js (byte-identical to its pinned commit) and the `.js` that
  `pnpm build` emits into `Sources/GlossReaderEPUB/Resources/reader/`. That output is committed
  (SwiftPM copies resources verbatim), never edited by hand; `pnpm check-build` fails if stale.

## Build and test

```sh
swift build                      # everything
swift test                       # all Swift tests
(cd web && pnpm test)            # typecheck + bridge tests under Node
(cd web && pnpm build)           # regenerate the committed reader .js from web/src
scripts/check.sh                 # build, tests, web checks, cli smoke test: run before every commit
scripts/run-mac.sh               # build and open build/gloss.app (development only, ad hoc signing)
```

## Commits

- Granular commits: one logical change each, with the tests that cover it.
- Conventional Commits scoped by module: `feat(store): …`, `fix(cli): …`, `test(core): …`,
  `refactor(markdown): …`, `docs: …`, `chore: …`.
- Commit only after `scripts/check.sh` exits 0. Don't pipe its output when gating a commit (a pipe
  reports the last command's status, not the check's).
- Generated files and build products stay out of git (`.build/`, `web/node_modules/`, …), except
  the committed reader `.js` above.
- The commit message is where the *why* lives: rationale, trade-offs and deviations go there.

## Docs

- Docs stay short and broad: a quick overview for a human or an agent. Don't document what the
  code already says; if it can be figured out from the code, it doesn't belong in a doc.
- Keep `docs/ARCHITECTURE.md` and `README.md` current when the design or the user-facing
  behaviour changes, and no longer than they are.
- Don't add decision logs, review logs, handoff checklists or per-feature design files. Put the
  why in commit messages.
