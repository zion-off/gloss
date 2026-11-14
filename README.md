<img width="1448" height="893" alt="image" src="https://github.com/user-attachments/assets/b1eb58de-a534-4cb7-9b0d-63b33d914784" />

# gloss

a mac app for reading epubs and pdfs, with a markdown notes page for every book, where your notes can link to exact passages.

select a few words in your notes, select a passage in the book, press ⌘K. the passage gets a small
marker in the book, and from then on you can hop between the two. think footnotes, except you write
them yourself.

**[download the latest release](../../releases/latest)** · macOS 14+, apple silicon and intel

## why gloss

- **links to passages.** they're plain markdown links with a `gloss://` address, so your notes stay
  plain text. they can cross books, and each pane has its own back and forward (⌘[ ⌘]).
- **notes beside the book.** split view with live markdown, tables, task lists and subpages.
- **search that knows where you are.** this book, this book's notes, all notes, or the whole library (⌘F).
- **easy backup.** books, covers, notes and highlights live in a single SQLite file, so backing up
  is one copy. turn on automatic backup and gloss saves it daily to a folder you pick (iCloud Drive
  by default).
- **scriptable.** a `gloss` command does everything the app does with your library.

## install

open `gloss-<version>.dmg` and drag gloss to Applications.

builds aren't notarized yet, so macOS will show a warning on first launch. close it, then go to
system settings > privacy & security, scroll to the bottom and click **open anyway**.

gloss updates itself; **gloss > check for updates…** looks right away.

## the `gloss` command

choose **gloss > install command line tool**, then:

```sh
gloss import ~/Books
gloss read "moby dick"
gloss search whiteness --book "moby dick"
gloss link "moby dick" --text "his obsession" --quote "the white whale"
```

every command takes `--json`. `gloss --help` lists them all.
