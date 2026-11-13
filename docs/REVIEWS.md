# Independent reviews

After each finished chunk, an independent review agent at maximum effort reads the diff for
correctness and code smell (CLAUDE.md, "Independent review"). It reports; the lead fixes. Every
fix has a regression test that fails without it where the platform allows; fixes in Mac-only code
and in glue.ts (which needs WebKit) carry a `docs/MACOS_HANDOFF.md` check instead. Declined
findings say why.

## Review 1 — `milestone-5..review-1-head` (PDF reader, Swift reader bridge, app model)

| Severity | Finding | Outcome |
|---|---|---|
| critical | Swift left nil optionals off the wire; the JS validator requires them as `null`, so `open` without a saved position and section-only search hits could never run | fixed in `304a53e`: explicit nulls, plus Swift-encoded commands committed and validated by the real JS validator (`wire-contract.test.ts`) |
| major | PDF object scan was quadratic on unterminated strings (32 KB took 37 s) | fixed in `2b75058`: bounded header matcher plus a shared linear scan budget; hostile-input tests at 1 MB |
| major | object streams overwrote newer loose definitions | fixed in `2b75058`: file position decides |
| major | xref-stream trailers picked in dictionary order (nondeterministic `/Info`) | fixed in `2b75058`: candidates sorted by offset |
| major | change monitor skipped rows past 500, and rows landing mid-poll | fixed in `af06573`: drains in pages, advances only past received rows |
| minor | `refresh()` dropped forward history and kept a stale reader focus | fixed in `af06573` |
| minor | `refresh()` treated a failed read as "gone" | fixed in `af06573` (explicit `Result`, since `try?` flattens the two) |
| minor | reader kept showing a book trashed from outside; blank after an engine reload | fixed in `af06573` |
| minor | symlink loops hung folder import | fixed in `fc08989` |
| minor | `TrashModel.Item.documentTitle` was always nil | fixed in `af06573` |
| minor | font cache shared decoders across different direct font dictionaries | fixed in `2b75058` |
| nit | progress-label doc comment promised a percentage | fixed in `d724bb5` |
| nit | dead test helper | fixed in `af06573` |
| nit | TJ kerning threshold ignores font size | **declined**: TJ adjustments are thousandths of an em, so `-200` already means 0.2 em at every size; scaling by font size would make it wrong |
| (found mid-review) | stale library reloads, layout-persist ordering, timing-based tests | fixed before the report in `3ea4ea3`, `d76dcf2` |

## Review 2 — `review-1-head..review-2-head` (CLI, terminal, race fixes)

| Severity | Finding | Outcome |
|---|---|---|
| major | `--json` on a terminal put status escapes on stdout | fixed in `ed17767`: the printer knows json mode |
| major | the delete-forever question went to stdout | fixed in `ed17767`: questions go to stderr, and `--json` never prompts |
| major | dash-leading text became options (a silent exit-0 help screen with `h`) | fixed in `2700c50` by documenting `--` in `page write` and `search`; making ArgumentParser reject help mixed with arguments was **declined** as fighting the library |
| major | `try?` in `export`/`open` replaced ambiguity and trash errors with "couldn't find a page" | fixed in `2700c50`: `CLIFailure.isNotFound` lets callers fall back only on not-found |
| minor | raw page ids didn't name their book | fixed in `2700c50` |
| minor | a fragment matching a page and a book read as "not found" | fixed in `2700c50`: lists the candidates |
| minor | an id fragment could beat an exact base32-looking title | fixed in `2700c50`: exact titles first |
| minor | import turned every metadata failure (even cancellation) into "damaged" | fixed in `fc08989` |
| minor | `export -o` overwrote files | fixed in `2700c50`: refuses unless `--force` |
| minor | `open --json` said `"true"`, dropped the reason | fixed in `2700c50` |
| minor | invalid UTF-8 from `$EDITOR` was saved as U+FFFD | fixed in `2700c50`: refused, page unchanged |
| nit | stderr terminal stored a colour flag as `isTTY` | fixed in `ed17767` |
| nit | wasted inline renders; misaligned wrapped list items | fixed in `2700c50` |
| nit | `TextWrap` collapsing whitespace was undocumented | fixed in `df6811b` |
| nit | the warning gate only worked in a checkout named `gloss` | fixed in `d463fc7` |
| nit | `settle()`-style waits weren't barriers for later work | fixed in `af06573` (loop until the task stops changing) |
| nit | harness lock coverage; import failure paths mixed typed and expanded paths | fixed in `2700c50` (`input` and `file` fields) |

## Review 3 — `review-2-head..review-3-head` (reader routing and CSP, engine boundary, reader controller, linking, notes editor model, review 1–2 fixes)

The review 1–2 fixes were re-checked by reverting each one in a scratch copy: every regression test failed
without its fix.

| Severity | Finding | Outcome |
|---|---|---|
| major | a failed autosave counted as clean: `flushSave` skipped it and an external change replaced the unsaved text | fixed in `a4c9a5a`: dirty means "not saved"; a flush retries, and an external change after a failure is the cue to retry. Still open for milestone 10: switching pages after a retry fails again drops the text, so the editor must show the failure first |
| major | events from the previous book landed on the next one (a late `relocated` saved A's position onto B; a late selection could link A's passage into B) | fixed in `8233d75`: numbered opens echoed by `opened`, book events dropped until the matching one (D-079) |
| major | the controller sent a second `open` that glue.js refused by design; no `close` | fixed in `8233d75`: `open` switches books in place, a new `close` command, commands run one at a time in the page (D-080) |
| major | "book scripts never run" rested on one unverified WebKit behaviour (CSP inherited by `blob:` documents) and wasn't in the handoff | fixed in `3a270b4`: script resources vetoed, script stripped from every document (`bridge/sanitize.ts`), and the Mac check in `MACOS_HANDOFF.md` (D-082) |
| minor | object headers with a comment between tokens were lost | fixed in `3592e57`: comments skip like whitespace, still bounded |
| minor | a pending note reveal survived opening another page | fixed in `5e2da38` |
| minor | no `X-Content-Type-Options: nosniff` on reader responses | fixed in `8d18efe` |
| minor | EPUB 3 embedded objects render nothing under the CSP | **declined**: `object-src` stays `'none'`; embedded objects are rare in books and plugins are the wrong thing to let a book start (docs/READER_BRIDGE.md) |
| minor | `highlightSelection` left the selection anchor behind | fixed in `8233d75` |
| minor | any page, highlight or link change in the library redraws the reader's annotations | **declined as asked**: change records carry no book, a page in any book can link into the open one, and deleted rows can't be looked up. Instead the controller sends nothing when the annotations didn't change (`8233d75`) |
| minor | the trash window made two reads per entry on the main actor | fixed in `7dd1b68`: `TrashService.overview()` in one read |
| nit | attaching the attached engine again dead-ended the controller | fixed in `8233d75` |
| nit | link gesture availability computed twice | fixed in `ceb00da` |
| nit | a failed link lookup styled live links as broken; a generic `Array[safe:]` hidden in the editor model | fixed in `a4c9a5a` |

## Review 4 — `review-3-head..review-4-head` (review 3 fixes, milestone 9 Mac reader)

The reviewer re-verified every review-3 fix by reverting it in a scratch copy: each regression
test failed without its fix.

| Severity | Finding | Outcome |
|---|---|---|
| major | the sanitizer only covered XHTML/HTML/SVG: an `application/xml` spine item or iframe target reached the sandbox frame with its script intact, defeating two of the three layers | fixed in `e71a839`: every `xml`/`html`/`xsl` type is sanitized (parsed as XML, serialized back), `xml-stylesheet` instructions go, and the Mac test book covers the vector |
| major | a failed `open` wedged the reader: the JS failure left `awaitedOpenID` set, so re-opening the same book short-circuited forever | fixed in `6f8577d`: `error` events carry the failed `open`'s id (`openID`), the controller unwedges only on a match, and the placeholder offers "try again" (`retryOpen`) |
| minor | a failed position read opened at the start, and the first relocation then overwrote the real saved position | fixed in `f27fae7`: a failed read doesn't open; retry works once the store answers |
| minor | template content was never cleaned (`isConnected` skip) | fixed in `e71a839`: template content is walked, nested included |
| minor | a replaced session's inbox wasn't drained: stale events could land after the next engine attached | fixed in `6797207`: `invalidate()` drains before the pane attaches the next session |
| minor | reader files were read synchronously on the main actor | fixed in `6fb2e88`: the read runs off the main actor |
| minor | `revealSearchHit`'s fallback scan held the command queue and wasn't generation-guarded | fixed in `4163730`: it detaches like `search`, and the queue/generation logic now lives in `bridge/queue.ts` (Node-tested) |
| minor | command errors while a book shows are set but never rendered, and a stale error spoke for the next open | half fixed in `6ebb8be`: errors no longer outlive their open; rendering lands with the reader's status line (milestone 10/11 UI, where `progressText` already goes) |
| nit | `img-src`/`font-src 'self'` lets a book reference another book's bytes | **declined**: without script the bytes can't come back to the page, and the target ids are 128-bit random; scoping needs either a second scheme or CSP source expressions with custom schemes, which can't be verified off a Mac |
| nit | the command queue lived in glue.ts, untestable under Node | fixed in `4163730` (`bridge/queue.ts`) |
| nit | opening at a passage resolves the CFI twice (once as `position`, once to flash) | **declined**: the flash needs the second resolve; a `flash` flag on `open` saves one round trip but adds protocol for nothing user-visible |
| nit | the trash title cache's double optional deserved a comment | fixed in `36408e7` |
| nit | SMIL `set`/`animate` targeting `on*` attributes wasn't covered | fixed in `e71a839` |

## Review 5 — `review-4-head..review-5-head` (review 4 fixes, milestone 10 Mac editor)

The reviewer re-verified every review-4 fix by reverting it in a scratch copy: each regression
test failed without its fix, and the `application/xml` vector was confirmed against the vendored
foliate loader.

| Severity | Finding | Outcome |
|---|---|---|
| critical | the Mac editor could not compile: `runs` was called on the wrong theme, `textStorage` unwrapped five times, a struct cached fonts from a non-mutating method | fixed in `0048bb2` |
| major | overlay anchors were mirrored vertically (AppKit bottom-left vs SwiftUI top-left) | fixed in `fd4bac4`: the flip and placement are `OverlayGeometry` (GlossAppModel), Linux-tested |
| major | undo history survived page switches, so ⌘Z replayed the old page's edit into the new one and the autosave persisted it | fixed in `0048bb2`: installs and external replaces clear the undo history |
| major | subpage row matching depended on whether the paragraph range includes its newline — unverifiable off a Mac | fixed in `45e4706`: overlap matching in `SubpageRows.row(covering:in:)`, Linux-tested |
| major | an engine throw during an open left the reader wedged (only the event path unwedged) | fixed in `a461491`, with a throwing-driver regression test |
| minor | rapid document-kind switches could clobber the fresh session (async prepare, no cancellation check) | fixed in `65bb2e9` |
| minor | link-status changes never restyled until the next keystroke | fixed in `65bb2e9` (span tracking in sync) |
| minor | closing a window dropped up to 500 ms of typed notes and the last position | fixed in `40a6bc7` (`onDisappear` flushes both) |
| minor | a `<template>` in a generic XML document crashed the sanitizer's promise (fail-closed, but the section died) | fixed in `a303e25`, duck-typed fragment |
| minor | the unsaved-changes alert's title didn't match its cause, and Escape couldn't dismiss it | fixed in `40a6bc7` ("this page has unsaved changes", keep = cancel role) |
| minor | REVIEWS.md claimed every fix has a failing-without-it test, untrue for glue.ts and Mac-only fixes | fixed in `cc32fc7`: the header says where the platform forbids it |
| nit | milestone-10 decisions missing from DECISIONS.md | fixed in `cc32fc7` (D-089…D-094) |
| nit | dead `max(length, 1)` in the restyle clamp | fixed in `0048bb2` |
| nit | every external change refetched the editor's page | fixed in `cc32fc7` (scoped to the changed page ids) |
| nit | the coordinator's closures were wired only at creation | fixed in `cc32fc7` (rewired every update) |
| nit | handoff gaps: the fragment subclass's isolation, the paragraph-range semantics, undoManager presence | fixed in `cc32fc7` |

## Review 6 — `review-5-head..review-6-head` (review 5 fixes, milestone 11 linking UI and PDF engine)

The reviewer re-verified every portable fix by reverting it in a scratch copy (each new test failed
without its code, except review 5's page-scoped refetch, which had no test) and checked the PDFKit
calls against Apple's docs JSON. Its four compile errors were each reproduced with the Swift 6.4.2
compiler. In answer, the Mac modules now type-check on Linux against stub frameworks copied from
Apple's docs (`bad64a6`, D-099), which also found compile errors the review missed (listed below).

| Severity | Finding | Outcome |
|---|---|---|
| critical | `NotesPane` was passed and used `commands` but never declared it | fixed in `6c2dcf1` |
| critical | five `guard let pdf` in the PDF session named nothing (the property is `document`) | fixed in `283e08a` |
| critical | `open` called the throwing async `go(to:flash:)` without `try await` | fixed in `283e08a` |
| critical | `NotificationCenter.removeObservers(_:)` doesn't exist | fixed in `283e08a` (one `removeObserver(_:)` per token) |
| critical | (type-check) the PDF session couldn't satisfy the non-isolated `PDFPageOverlayViewProvider`; `PDFLocators` wasn't imported | fixed in `283e08a` (nonisolated + `assumeIsolated`, D-100) |
| critical | (type-check) the editor: missing `NSTextLayoutManagerDelegate` conformance, a non-Sendable fragment out of `assumeIsolated`, `OverlayRect`/`NSRect` callbacks, `size` used as a property, a duplicate font enum, `frame(width:maxHeight:)`, `Color.separatorColor` | fixed in `7f9b7c2` and `7cfda47` |
| major | PDF overlays drew and hit-tested in the PDF view's coordinates, not their own: marks offset on every page but the first | fixed in `b63cafc`: page → PDF view → overlay and back; the clicked rect comes from `PDFAnnotationLayout.hit` (Linux-tested, `926e76c`) |
| major | overlays froze their marks: a marker linked with ⌘K didn't appear until its page scrolled away and back | fixed in `b63cafc`: every page gets an overlay, the session keeps those on screen and `show(_:)` updates them |
| major | the editor's overlay flip assumed an unflipped scroll view (likely a double flip) | fixed in `722bea0`: `OverlayGeometry.topLeft(_:inHeight:flipped:)` asks the view (Linux-tested); a handoff check covers it |
| major | (found while verifying) clicks in the notes used `characterIndex(for:)`, which takes screen coordinates | fixed in `cf8b513`: `characterIndexForInsertion(at:)`; task boxes take insertion indices (tested) |
| minor | a hover lookup still waiting outlived the popover's close | fixed in `af68902` (`endHover()` cancels it) |
| minor | a PDF search hit re-searched the whole document after jumping to its page | fixed in `fbc0475`: its own page first (`PDFTextMatch`, Linux-tested) |
| minor | the PDF outline walk was unbounded in breadth and sent unresolved destinations to page 1 | fixed in `fbc0475`: `PDFOutlineTOC`, bounded and nested (Linux-tested, `926e76c`) |
| minor | accessibility labels interpolated user content through `LocalizedStringKey` | the marker list's labels were already verbatim (**declined** there); the colour and slash-menu labels and help tags made verbatim in `e61f8e3` |
| minor | review 5's page-scoped refetch had no regression test | fixed in `a26c0ff` (fails with the scoping removed) |
| nit | unused `target` binding in `open` | fixed in `283e08a` |
| nit | the flash view stroked half outside its bounds | fixed in `fbc0475` |
| nit | `mac-visibility.py` can't see member- or statement-level errors | answered by `scripts/mac-typecheck.py` (`bad64a6`, D-099) |
| nit | MAC_API_NOTES called `Commands` nonisolated; the protocol is `@MainActor @preconcurrency` | fixed in this commit, with every API verified for the stubs |
