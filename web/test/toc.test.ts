// foliate TOC ({ label, href, subitems }) → bridge TocItem ({ label, href, children }).

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { normalizeToc, normalizeTocItem } from '../src/bridge/toc.ts'
import { validateEvent, makeEvent } from '../src/bridge/protocol.ts'

test('renames subitems to children recursively', () => {
    const toc = [{
        label: 'Part I',
        href: 'part1.xhtml',
        subitems: [
            { label: 'Chapter 1', href: 'ch1.xhtml', subitems: [
                { label: 'Section', href: 'ch1.xhtml#s', subitems: [] },
            ] },
            { label: 'Chapter 2', href: 'ch2.xhtml' }, // leaf: no subitems key
        ],
    }]
    assert.deepEqual(normalizeToc(toc), [{
        label: 'Part I',
        href: 'part1.xhtml',
        children: [
            { label: 'Chapter 1', href: 'ch1.xhtml', children: [
                { label: 'Section', href: 'ch1.xhtml#s', children: [] },
            ] },
            { label: 'Chapter 2', href: 'ch2.xhtml', children: [] },
        ],
    }])
})

test('trims labels', () => {
    assert.deepEqual(normalizeTocItem({ label: '  Chapter 1. Loomings\n', href: 'x' }),
        { label: 'Chapter 1. Loomings', href: 'x', children: [] })
})

test('tolerates missing or malformed input', () => {
    assert.deepEqual(normalizeToc(undefined), [])
    assert.deepEqual(normalizeToc(null), [])
    assert.deepEqual(normalizeToc([null, { label: 'a', href: 'b' }]), [
        { label: '', href: '', children: [] },
        { label: 'a', href: 'b', children: [] },
    ])
})

test('normalized toc validates as the opened payload', () => {
    const envelope = makeEvent('opened', {
        openID: 1,
        toc: normalizeToc([{
            label: 'A', href: 'a.xhtml',
            subitems: [{ label: 'B', href: 'b.xhtml' }],
        }]),
        sectionCount: 2,
        direction: 'ltr',
        fixedLayout: false,
    })
    assert.deepEqual(validateEvent(envelope), { ok: true })
})
