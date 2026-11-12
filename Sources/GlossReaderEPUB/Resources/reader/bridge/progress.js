// generated from web/src/bridge/progress.ts by pnpm build; do not edit
// Progress mapping for the reader bridge. Pure logic, no DOM.
//
// The foliate `View` re-emits every renderer `relocate` as its own `relocate`
// event whose detail (also `view.lastLocation`) is:
//
//     { fraction, section: { current, total }, location, time,
//       tocItem, pageItem, cfi, range }
//
// — `fraction` is the book-wide fraction (from `SectionProgress.getProgress`),
// `tocItem`/`pageItem` are TOC/page-list progress items (`{ label, href, … }`
// or null). The *renderer* (paginator) exposes the page position in the
// current section through public getters:
//
// - `page`  — current page: `Math.floor(((start + end) / 2) / size)`; the
//   text pages of a section are `1 … pages - 2` (page 0 and `pages - 1` are
//   the blank padding pages the paginator adds on either side).
// - `pages` — total pages of the section including the two padding pages:
//   `Math.round(viewSize / size)`.
// - `scrolled` — true when the `flow` attribute is `scrolled`.
// - `atStart` / `atEnd` — true at the very start/end of the book.
//
// So the number of pages left in the section after the current one is
// `(pages - 2) - page`, and it is null in scrolled flow (no pages) or for
// renderers without page getters (fixed layout).
export const pagesLeftInSection = (renderer) => {
    if (!renderer || renderer.scrolled)
        return null;
    const { page, pages } = renderer;
    if (typeof page !== 'number' || !Number.isFinite(page)
        || typeof pages !== 'number' || !Number.isFinite(pages) || pages <= 2)
        return null;
    return Math.max(0, pages - 2 - page);
};
// `detail` is the foliate View `relocate` detail; `renderer` is
// `view.renderer` (the paginator or fixed-layout element).
export const makeRelocated = (detail, renderer) => ({
    cfi: detail.cfi,
    fraction: detail.fraction,
    section: {
        index: detail.section.current,
        count: detail.section.total,
    },
    tocLabel: detail.tocItem?.label ?? null,
    pageLabel: detail.pageItem?.label ?? null,
    pagesLeftInSection: pagesLeftInSection(renderer),
    atStart: renderer?.atStart === true,
    atEnd: renderer?.atEnd === true,
});
