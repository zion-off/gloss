#!/usr/bin/env bash
# End to end: the real `gloss` binary on a real SQLite library with real EPUB and PDF files,
# including several processes writing at once (the app and the CLI share the file).
set -euo pipefail
cd "$(dirname "$0")/.."
bin="$(swift build --show-bin-path)/gloss"
[ -x "$bin" ] || { echo "✘ cli smoke: build the gloss product first"; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GLOSS_LIBRARY="$work/library.sqlite" NO_COLOR=1
python3 scripts/make-fixtures.py "$work/books" >/dev/null
fail() { echo "✘ cli smoke: $*"; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

"$bin" import "$work/books" >/dev/null || fail "import"
[ "$("$bin" list --json | json 'len(d)')" = 3 ] || fail "expected 3 books"
[ "$("$bin" import "$work/books/stranger.epub" --json | json 'len(d["duplicates"])')" = 1 ] || fail "duplicate detection"
[ "$("$bin" book show "myth of sisyphus" --json | json 'd["book"]["pageCount"]')" = 1 ] || fail "pdf metadata"

# Book text search through FTS5, with engine locators.
[ "$("$bin" search sisyphus --book myth --in text --json | json 'd[0]["locator"]["scheme"]')" = "pdf-page" ] || fail "pdf text search"
[ "$("$bin" search maman --book stranger --in text --json | json 'd[0]["title"]')" = "Part Two" ] || fail "epub text search"

# Notes round trip, raw.
"$bin" page write stranger '# notes\n- [ ] read part two' >/dev/null
[ "$("$bin" read stranger)" = "$(printf '# notes\n- [ ] read part two')" ] || fail "raw read"

# Ten processes add pages at once.
for i in $(seq 1 10); do "$bin" page add stranger "page $i" >/dev/null & done
wait
[ "$("$bin" pages stranger --json | json 'len(d["children"])')" = 10 ] || fail "concurrent writers"

# Export, backup (and read the backup back), trash round trip.
"$bin" export stranger | grep -q '^# The Stranger' || fail "export"
"$bin" backup "$work/backup.sqlite" >/dev/null
[ "$(GLOSS_LIBRARY="$work/backup.sqlite" "$bin" list --json | json 'len(d)')" = 3 ] || fail "backup is readable"
"$bin" book trash plague >/dev/null
[ "$("$bin" list --json | json 'len(d)')" = 2 ] || fail "trash hides the book"
"$bin" trash restore plague >/dev/null
[ "$("$bin" list --json | json 'len(d)')" = 3 ] || fail "restore"

# Exit codes: 1 for failures, 64 for wrong usage.
set +e
"$bin" book show "no such book" 2>/dev/null; [ $? = 1 ] || fail "missing book exits 1"
"$bin" search 2>/dev/null; [ $? = 64 ] || fail "usage error exits 64"
set -e
echo "✔ cli smoke passed (real binary, sqlite, epub, pdf, 10 concurrent writers)"
