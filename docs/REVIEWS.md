# Independent reviews

After each finished chunk, an independent review agent at maximum effort reads the diff for
correctness and code smell (CLAUDE.md, "Independent review"). It reports; the lead fixes. Every
fix has a regression test that fails without it. Declined findings say why.

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
