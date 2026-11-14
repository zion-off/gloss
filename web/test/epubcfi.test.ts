// CFI round-trip with the real vendored foliate/epubcfi.js under jsdom.
// This pins the exact CFI semantics every existing gloss note depends on
// (see foliate/VENDORED.md) — do not change this test lightly.
//
// The vendored file is plain JavaScript, so its types are inferred by tsc
// (`allowJs`); that inference is the project's one untyped boundary.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { JSDOM } from 'jsdom'
import * as CFI from '../../Sources/GlossReaderEPUB/Resources/reader/foliate/epubcfi.js'
import { validateCommand } from '../src/bridge/protocol.ts'
import type { Appearance } from '../src/bridge/protocol.ts'

const XHTML = `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>Chapter 1</title></head>
    <body>
        <section id="s1">
            <h1 id="h1">Loomings</h1>
            <p>Call me Ishmael. Some years ago—never mind how long
               precisely—having little or no money in my purse, and nothing
               particular to interest me on shore, I thought I would sail
               about a little and see the watery part of the world.</p>
            <p>It is a way I have of driving off the spleen and regulating
               the circulation.</p>
        </section>
    </body>
</html>`

const makeDoc = (): Document =>
    new JSDOM(XHTML, { contentType: 'application/xhtml+xml' }).window.document

test('fromRange → parse → toRange returns the same text (single text node)', () => {
    const doc = makeDoc()
    const p = doc.querySelectorAll('p')[0]
    const text = p.firstChild
    assert.ok(text, 'first child of <p>')
    assert.equal(text.nodeType, 3, 'first child of <p> is a text node')

    const range = doc.createRange()
    range.setStart(text, 0)
    range.setEnd(text, 15) // "Call me Ishma"
    const expected = range.toString()

    const cfi = CFI.fromRange(range)
    assert.match(cfi, /^epubcfi\(/)
    const range2 = CFI.toRange(doc, CFI.parse(cfi))
    assert.equal(range2.toString(), expected)
    assert.equal(range2.startContainer, text)
    assert.equal(range2.startOffset, 0)
    assert.equal(range2.endOffset, 15)
})

test('fromRange → parse → toRange returns the same text (across elements)', () => {
    const doc = makeDoc()
    const heading = doc.getElementById('h1')?.firstChild
    assert.ok(heading, 'h1 has a text node')
    const headingText = heading.nodeValue ?? ''
    const para = doc.querySelectorAll('p')[0].firstChild
    assert.ok(para, 'first paragraph has a text node')

    const range = doc.createRange()
    range.setStart(heading, headingText.length - 4) // "mings"
    range.setEnd(para, 10)                          // "Call me Is"
    const expected = range.toString()

    const cfi = CFI.fromRange(range)
    const range2 = CFI.toRange(doc, CFI.parse(cfi))
    assert.equal(range2.toString(), expected)
})

test('collapsed range produces a collapsed round-trip', () => {
    const doc = makeDoc()
    const text = doc.querySelectorAll('p')[1].firstChild
    assert.ok(text, 'second paragraph has a text node')
    const range = doc.createRange()
    range.setStart(text, 4)
    range.collapse(true)
    const cfi = CFI.fromRange(range)
    const range2 = CFI.toRange(doc, CFI.parse(cfi))
    assert.equal(range2.collapsed, true)
    assert.equal(range2.toString(), '')
})

test('joinIndir with a section base CFI produces a string the bridge accepts', () => {
    const doc = makeDoc()
    const text = doc.querySelectorAll('p')[0].firstChild
    assert.ok(text, 'first paragraph has a text node')
    const range = doc.createRange()
    range.setStart(text, 0)
    range.setEnd(text, 15)

    // this is exactly what foliate's View.getCFI(index, range) does
    const baseCFI = CFI.fake.fromIndex(3)
    const inner = CFI.fromRange(range)
    const cfi = CFI.joinIndir(baseCFI, inner)

    assert.equal(baseCFI, 'epubcfi(/6/8)')
    assert.match(cfi, /^epubcfi\(/)
    assert.ok(cfi.startsWith('epubcfi(/6/8!'),
        'section base joined with indirection, unchanged')

    // the bridge accepts it wherever a CFI string is expected
    assert.deepEqual(validateCommand({
        v: 1, type: 'open',
        payload: {
            openID: 1,
            url: 'gloss-reader://books/x.blob',
            position: cfi,
            appearance: validAppearance(),
        },
    }), { ok: true })
    assert.deepEqual(validateCommand({
        v: 1, type: 'goTo', payload: { target: { cfi }, flash: false },
    }), { ok: true })

    // and it resolves back to the same text the way foliate does it in
    // Resources.resolveCFI: drop the first indirection segment (the
    // package-document step) and resolve the rest in the section document
    const parts = CFI.parse(cfi)
    const segments = 'parent' in parts ? parts.parent : parts
    assert.equal(segments.length, 2)
    segments.shift()
    const range2 = CFI.toRange(doc, parts)
    assert.equal(range2.toString(), range.toString())
})

test('CFIs stored by gloss are stable strings', () => {
    const cfiOf = (doc: Document): string => {
        const text = doc.querySelectorAll('p')[0].firstChild
        assert.ok(text, 'first paragraph has a text node')
        const range = doc.createRange()
        range.setStart(text, 0)
        range.setEnd(text, 15)
        return CFI.joinIndir(CFI.fake.fromIndex(0), CFI.fromRange(range))
    }
    // deterministic: same document + same range → same CFI
    assert.equal(cfiOf(makeDoc()), cfiOf(makeDoc()))
})

const validAppearance = (): Appearance => ({
    flow: 'paginated',
    css: '',
    layout: { margin: 48, gap: 0.06, maxInlineSize: 720, maxColumnCount: 2 },
    colors: {
        background: '#f8f1e3', foreground: '#3b2f1e', marker: 'rgba(0,0,0,.4)',
        highlights: { yellow: 'y', green: 'g', blue: 'b', pink: 'p', purple: 'u' },
        search: { soft: 's', current: 'c' },
    },
})
