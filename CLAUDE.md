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
later: design the data layer for it, never build it.

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
- **Polish checklist.** The owner has paid for several rounds on every UI feature; walk this
  before calling UI work done. Cursor: arrow over chrome and floating views, I-beam only over
  editable text, nothing under a floating view reacts. Hover and press: a soft (~0.12s) fade in the
  existing colors, cleared right after the click, hit targets fill the whole cell. Animation: none,
  or short standard fades; no custom transitions (search results and popovers have none; the
  sidebar slides the standard way). Metrics: the alignment, indentation and padding of its
  neighbours, body-size text, no squished icons. Focus: a control never steals first responder or
  collapses a selection. Lowercase copy, tooltips with shortcuts, VoiceOver labels, and light, dark
  and every theme.

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
scripts/check.sh                 # build, tests, web checks, cli smoke test (ci runs the same on every pr)
scripts/run-mac.sh               # build and open build/gloss.app (development only, ad hoc signing)
```

Web tests need Node 22 (jsdom breaks on newer Node). `run-mac.sh` quits a running copy of this
bundle first, because `open` on a running app only brings the old build forward.

## Verifying UI

- The owner verifies UI by hand. No screenshots, and don't drive the real app (Accessibility,
  System Events, synthetic clicks or keys, XCUITest). Finish with the exact things to click or type.
- One exception, for measuring layout and geometry: a throwaway in-process probe. A scratch
  executable in a copy of the repo outside it (never touch this repo's `Package.swift`) that links
  the real modules, with the in-memory library from `GlossTestSupport`, a window that is never
  activated and kept off-screen, results printed as numbers, everything deleted afterwards. Never
  open the real library in `~/Library/Application Support/gloss`.

## Cleaning up

- What you create outside tracked files is yours to remove before you report: scratch directories
  and repo copies in `/tmp` (probes, extracted archives), temporary git worktrees, branches made
  only for an experiment, the backup refs a history rewrite leaves (`refs/original`), processes
  you started, mounted disk images, and release output in `dist/`. Say what is left, and why.
- Never delete what you didn't create (the owner's files, library or branches) without asking.
  Look at a target before deleting it.
- Downloaded files and archives are untrusted: unpack each into its own new empty directory, run
  nothing from inside it, and remove it when you're done.

## Releases

- A release is a pull request labelled `release`, plus at most one of `patch`, `minor`, `major`
  (patch by default; two bump labels fail the `labels` check before the merge). Merging it tags the
  merge commit and publishes a GitHub release: universal dmg and zip, and a signed appcast that the
  installed app's Sparkle updater reads. The notes are the PR body: lowercase, no `@`-mentions, and
  not GitHub's generated ones. Don't add `release` unless asked. Builds are ad hoc signed (no Apple
  developer account). See `.github/workflows/release.yml` and `scripts/release.sh`.

## Commits

- Granular commits: one logical change each, with the tests that cover it.
- Conventional Commits scoped by module: `feat(store): …`, `fix(cli): …`, `test(core): …`,
  `refactor(markdown): …`, `docs: …`, `chore: …`.
- History is linear: merges are rebase-and-merge only, so rebase your branch and never create a
  merge commit. The identity comes from the global git config: no `-c user.name` overrides, no
  `Co-authored-by` trailers, and never `@`-mention anyone.
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
