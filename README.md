# gloss

gloss is a mac app for reading epubs and pdfs, with a markdown notes page for every book.

The twist: your notes can link to exact passages. Select a few words in your notes, select a
passage in the book, press ⌘K. The passage gets a small marker in the book, and from then on you can
hop between the two. Think footnotes, except you write them yourself.

## what you get

- **a reader** for epubs and pdfs. Table of contents, search inside the book, reading progress,
  and gloss remembers where you stopped. Epubs have light, sepia and night themes, text size, line
  spacing, margins, paginated or scrolling layout.
- **highlights** in five colours. They're drawn on top of the book, never written into your file.
- **a notes page per book**, with live markdown styling as you type, a floating format bar, a `/`
  menu, task lists and subpages.
- **links to passages**: plain markdown links with a `gloss://` address, so your notes stay plain text.
  Linked passages show a marker in the book, hovering previews the other end, clicking follows it.
  Links can cross books, and each pane has its own back and forward (⌘[ ⌘]).
- **split view** with the book and the notes side by side, or either on its own.
- **a library** of covers with reading progress, a "recently read" shelf, filters and sorting.
  Drop files in, or double-click one in Finder.
- **search** that knows where you are: this book's text, this book's notes, all notes, or the whole
  library. Open quickly (⇧⌘O) jumps to any book or page.
- **trash** with undo, for books and pages. You pick how long things stay (7, 30 or 90 days, or forever).
- **export** a book's notes as markdown or html, or print them. "back up library…" makes a copy.
- **automatic backup**: switch on "back up automatically" in settings and gloss keeps one file,
  `gloss-backup.sqlite`, in a folder you pick (iCloud Drive's `gloss` folder by default), replacing
  it in one step once a day, so a failed run never costs you the last good copy.
- **one file**: books, covers, notes and highlights all live in a single SQLite file in
  `~/Library/Application Support/gloss/`.

## install

Grab `gloss-<version>.dmg` from the releases page, open it and drag gloss to Applications. It needs
macOS 14 or later, on apple silicon or intel.

Builds aren't notarized yet, so the first launch needs a nudge: right-click gloss in Applications,
choose open, then open again. Or clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/gloss.app
```

gloss keeps itself up to date: on the second launch it asks whether to check for updates
automatically, and **gloss > check for updates…** looks right away.

## build and run

To build it yourself you need macOS 14 or later and Xcode
16.3 or later (Swift 6.1+).

```sh
scripts/run-mac.sh        # builds build/gloss.app (ad hoc signed, for development) and opens it
GLOSS_NO_SPARKLE=1 scripts/release.sh 0.1.0  # universal gloss.app, dmg, zip and checksum in dist/
```

`GLOSS_NO_SPARKLE=1` leaves out the update feed, so that build never updates itself; a real
release sets `GLOSS_SPARKLE_PUBLIC_KEY` instead (see releasing).

The reader's web side is TypeScript, but its compiled output is committed, so you only need Node 22
and pnpm if you're changing `web/`. Run `scripts/check.sh` before committing; `CLAUDE.md` and
`docs/ARCHITECTURE.md` explain how the code is laid out.

## releasing

Merging a pull request labelled `release` into main publishes the next version (the first is
0.1.0) with the dmg, the zip and the signed `appcast.xml` that installed copies check. It's a patch
release unless you add one of `minor`, `major` (or `patch`); more than one of those three fails
the pull request's checks. Running the release workflow by hand is a dry run: it builds everything
for the version you give and keeps it as a workflow artifact, publishing nothing.

Once, before the first release, make the update signing keys with Sparkle's `generate_keys` (after
a `swift build` it's in `.build/artifacts/sparkle/Sparkle/bin/`; it keeps the private key in your
login keychain) and hand them to GitHub:

```sh
bin=.build/artifacts/sparkle/Sparkle/bin
$bin/generate_keys --account gloss
gh variable set SPARKLE_PUBLIC_KEY --body "$($bin/generate_keys --account gloss -p)"
key="$(mktemp -d)/key" && $bin/generate_keys --account gloss -x "$key" \
  && gh secret set SPARKLE_PRIVATE_KEY < "$key"; rm -f "$key"
```

Keep the private key safe: losing it means installed copies can't update to new releases.

## the `gloss` command

Everything the app does with your library, scripts can do too. The command and the app share the
library safely, and the app picks up changes made from the terminal.

It ships inside the app. Choose **gloss > install command line tool** (it links `/usr/local/bin/gloss`
and asks for your password if it has to), or link it yourself:

```sh
ln -s /Applications/gloss.app/Contents/Helpers/gloss /usr/local/bin/gloss
```

Building from source instead: `swift build -c release --product gloss`, then run `.build/release/gloss`.

```sh
gloss import ~/Books                        # files or whole folders
gloss ls                                    # your library
gloss pages "moby dick"                     # a book's notes pages, as a tree
gloss read "moby dick"                      # a page, rendered (raw markdown when piped)
gloss page write "moby dick" -- '- call me ishmael'
gloss search whiteness --book "moby dick"   # this book's text and notes
gloss link "moby dick" --text "his obsession" --quote "the white whale"   # words → a passage
gloss export "moby dick" --output notes.md
gloss open gloss://page/<id>                # jump there in the app
gloss backup ~/Desktop                      # a consistent copy of the library
```

`gloss --help` lists every command and `gloss help <command>` explains one. Books and pages can be
named by title, id or `gloss://` link. Every command takes `--json`. `gloss link` makes passage
links without the app and never guesses: if your words appear more than once, it lists each match
and the flag that picks one.

## license

[MIT](LICENSE). Third-party code keeps its own licence: [foliate-js](https://github.com/johnfactotum/foliate-js)
(MIT, vendored), [GRDB](https://github.com/groue/GRDB.swift) (MIT),
[Sparkle](https://github.com/sparkle-project/Sparkle) (MIT), and Apple's
[swift-crypto](https://github.com/apple/swift-crypto) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache 2.0).
