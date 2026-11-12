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
