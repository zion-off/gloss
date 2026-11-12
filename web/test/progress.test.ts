// relocated payload mapping from foliate relocate details + paginator state.
// The shapes here mirror the vendored foliate source:
// - view.js `#onRelocate` detail: { fraction, section: { current, total },
//   tocItem, pageItem, cfi, range, … }
// - paginator.js public getters: `page`, `pages`, `scrolled`, `atStart`, `atEnd`.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
    makeRelocated,
    pagesLeftInSection,
    type RelocateDetail,
    type RendererPageInfo,
} from '../src/bridge/progress.ts'
import { validateEvent, makeEvent } from '../src/bridge/protocol.ts'

const detail: RelocateDetail = {
    fraction: 0.281,
    section: { current: 3, total: 14 },
    tocItem: { label: 'Chapter 1. Loomings', href: 'text/ch1.xhtml' },
    pageItem: null,
    cfi: 'epubcfi(/6/8!/4/2/1:23)',
}

const paginator = (
    page: number,
    pages: number,
    extra: Partial<RendererPageInfo> = {},
): RendererPageInfo => ({
    page, pages, scrolled: false, atStart: false, atEnd: false, ...extra,
})

test('maps a paginated relocate detail', () => {
    const payload = makeRelocated(detail, paginator(3, 12))
    assert.deepEqual(payload, {
        cfi: 'epubcfi(/6/8!/4/2/1:23)',
        fraction: 0.281,
        section: { index: 3, count: 14 },
        tocLabel: 'Chapter 1. Loomings',
        pageLabel: null,
        pagesLeftInSection: 7, // 12 total pages − 2 padding pages − current page 3
        atStart: false,
        atEnd: false,
    })
})

test('pagesLeftInSection counts the pages after the current one', () => {
    // text pages are 1 … pages−2
    assert.equal(pagesLeftInSection(paginator(1, 10)), 7)
    assert.equal(pagesLeftInSection(paginator(8, 10)), 0) // last text page
    assert.equal(pagesLeftInSection(paginator(1, 3)), 0)  // single text page
})

test('pagesLeftInSection is null in scrolled flow', () => {
    assert.equal(pagesLeftInSection(paginator(0, 0, { scrolled: true })), null)
    assert.equal(
        makeRelocated(detail, paginator(0, 0, { scrolled: true })).pagesLeftInSection,
        null)
})

test('pagesLeftInSection is null without usable page getters', () => {
    // fixed-layout renderer has no page/pages getters
    assert.equal(pagesLeftInSection({ scrolled: false }), null)
    assert.equal(pagesLeftInSection(null), null)
    assert.equal(pagesLeftInSection(paginator(NaN, 10)), null)
    assert.equal(pagesLeftInSection(paginator(3, 2)), null) // pages <= 2: no text pages
})

test('start and end flags come from the paginator', () => {
    const payload = makeRelocated(detail, paginator(1, 10, { atStart: true }))
    assert.equal(payload.atStart, true)
    assert.equal(payload.atEnd, false)
    const payload2 = makeRelocated(detail, paginator(8, 10, { atEnd: true }))
    assert.equal(payload2.atEnd, true)
})

test('start and end flags are false without a renderer', () => {
    const payload = makeRelocated(detail, null)
    assert.equal(payload.atStart, false)
    assert.equal(payload.atEnd, false)
})

test('toc and page labels are null when foliate has no progress item', () => {
    const payload = makeRelocated({ ...detail, tocItem: null, pageItem: null },
        paginator(1, 10))
    assert.equal(payload.tocLabel, null)
    assert.equal(payload.pageLabel, null)
})

test('page label comes from the page-list progress item', () => {
    const payload = makeRelocated({ ...detail, pageItem: { label: '17' } },
        paginator(1, 10))
    assert.equal(payload.pageLabel, '17')
})

test('relocated payload validates as an event', () => {
    const envelope = makeEvent('relocated', makeRelocated(detail, paginator(3, 12)))
    assert.deepEqual(validateEvent(envelope), { ok: true })
})
