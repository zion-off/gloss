# Vendored foliate-js

- **Upstream:** https://github.com/johnfactotum/foliate-js
- **Commit:** `78914aef4466eb960965702401634c2cb348e9b1`
- **Commit date:** 2026-05-01 ("Use original hrefs for external links and add isExternal in fb2.js (#129)")
- **License:** MIT (`LICENSE` vendored below)
- **Why pinned:** gloss notes link to passages with `gloss://` locators built from foliate CFIs, and the app stores
  those locators permanently. CFI anchor resolution (`epubcfi.js` `fromRange`/`toRange`) must never change under
  existing notes, so the reader engine is frozen at one exact commit and vendored into the repository. Upgrading is
  a deliberate, reviewed migration (re-resolve a corpus of real notes before bumping the pin), never a routine
  dependency update.
- **Byte fidelity:** every file was fetched from
  `raw.githubusercontent.com/johnfactotum/foliate-js/78914aef…/<path>` and verified byte-identical to what is
  stored here (SHA-256 below). **Do not modify anything in this directory.**

## Files and SHA-256

| file | sha-256 |
|---|---|
| `comic-book.js` | `7f3bf77561ca77300d5244015fcb1f73805787db246928074dc49fb56c88762e` |
| `dict.js` | `9c5f7d9d87ebec302594178f8960539a4573830f9ef84c8a915f599047dcc4aa` |
| `epubcfi.js` | `e1a688ad5c84bf31f33cef467f92c7a6d060a0f17ec37c1d3c048e9c7b1cf645` |
| `epub.js` | `dfe347495039e9b5991478986ec6b7713cf9efbcd8f475a77ef7b967c5176298` |
| `fb2.js` | `09a7890bf191f1b6c6dd435fae2868b86c75e73e00731b0051c02f2a998a180a` |
| `fixed-layout.js` | `7aee1d15d8e0479b8a6c59a20304b250dafc4c7dc158147a2b2c6bed9e180b4c` |
| `footnotes.js` | `d377b45d2ac05290c42873612ec0a92e640938e8be8ed850a467133a883388de` |
| `mobi.js` | `016526df13a9f11ee6671a8c74346e1cf41fe6bdfe50165fdcbf744f015694f3` |
| `opds.js` | `4b9f2a8f77ba191e1bb892032fd21a4e2ca14e5ff0b14239421d331556fa352f` |
| `overlayer.js` | `d3d3396e3083277ccbd4f17c407621159b22a407107e43ce75ca3014578094fb` |
| `paginator.js` | `51cec81572d5d182e231fe68ce9c3b5489a0976b36172060516336ba893565ea` |
| `pdf.js` | `684da69d4366f2fee1e08423d02e727c32c553f2487bba661c6a1870b0508475` |
| `progress.js` | `544f5e90babc0cb31c5caf971a5f06dd6249ec06600cb62f672fa7179811fde1` |
| `quote-image.js` | `32df52ebce383bade52d84e7510270e3c192bea51db070f4458a44d3cacf05e7` |
| `search.js` | `31e846bdc095a645de0e94f7baa2c9e136561a363a2f774d4032e72cfa1fb0ef` |
| `text-walker.js` | `4ad740ab6142b5be428700ef4d270253cef6649cf6e047ae7d2698a7aec65e92` |
| `tts.js` | `530d34605b758a5e2260438964a85bb9909bcb49e8848e303fe22cac63859026` |
| `uri-template.js` | `28bd96a9960cbfb07e14d4b9e9f334f28d1c3c96cbd8d58880631dcb1387e9f6` |
| `view.js` | `e0093af921feb03bb58fb51aeedc321fa108a4158d215f6913ecf7925415c945` |
| `ui/menu.js` | `90795bdec271a32ad8414dd7a07ba8ffe6f810dbfd706a8c0805302360856160` |
| `ui/tree.js` | `713134d5f242239b094e121912d07eb925d4ae20a9a5c8a7363feb7560ebbd16` |
| `vendor/zip.js` | `2a0d43157e4a447c6e43351225758795b75a33e8dfec10c6767248df2182949a` |
| `vendor/fflate.js` | `e63bcc21f83a43e5f71d5cbefd351ff4d4dbd57bef8b29ad65c8bd65752f6e6b` |
| `LICENSE` | `b621ffc351fe263bc9b09dd0bc1c9332fda9c462a3904c1e4f0b4d3236b9c28c` |

## Exclusions

Not vendored, on purpose:

- `vendor/pdfjs/` — gloss renders PDFs with PDFKit, never PDF.js (decision D-014).
- `tests/`, `rollup/`, `rollup.config.js`, `eslint.config.js`, `package.json`, `package-lock.json`, `.github/` —
  build tooling and upstream CI, not needed at runtime.
- `reader.html`, `reader.js` — foliate's demo reader app; gloss has its own `index.html` + `glue.js`.
- `README.md`, `.gitattributes`, `.gitignore` — repo metadata.

Note: `view.js` dynamically imports `./pdf.js` only when it detects a PDF file; gloss never opens PDFs through this
engine, so that path is never taken. `pdf.js` itself is vendored (it is a top-level `.js` module and harmless to
keep) but `vendor/pdfjs/` is not.
