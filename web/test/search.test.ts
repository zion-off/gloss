// Mapping foliate's view.search() generator yields into searchResults batches.
// Yield shapes (verified against vendored view.js):
//   { progress } | { label, subitems: [{ cfi, excerpt }] } | { cfi, excerpt } | 'done'

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeSearchMapper } from '../src/bridge/search.ts'
import { validateEvent, makeEvent } from '../src/bridge/protocol.ts'

const excerpt = { pre: '…the grand and dreaded', match: 'white whale', post: 'of the Pacific…' }

test('a book search run maps into ordered batches', () => {
    const mapper = makeSearchMapper('white whale')
    assert.deepEqual(mapper.map({ progress: 1 / 3 }), {
        query: 'white whale', items: [], progress: 1 / 3, done: false,
    })
    assert.deepEqual(mapper.map({ progress: 2 / 3 }), {
        query: 'white whale', items: [], progress: 2 / 3, done: false,
    })
    assert.deepEqual(mapper.map({
        label: 'Chapter 3. The Spouter-Inn',
        subitems: [
            { cfi: 'epubcfi(/6/10!/4/2/2/1:88,/4/2/2/1:99)', excerpt },
            { cfi: 'epubcfi(/6/10!/4/2/4/1:1,/4/2/4/1:12)', excerpt },
        ],
    }), {
        query: 'white whale',
        items: [
            { cfi: 'epubcfi(/6/10!/4/2/2/1:88,/4/2/2/1:99)',
                label: 'Chapter 3. The Spouter-Inn', excerpt },
            { cfi: 'epubcfi(/6/10!/4/2/4/1:1,/4/2/4/1:12)',
                label: 'Chapter 3. The Spouter-Inn', excerpt },
        ],
        progress: 2 / 3,
        done: false,
    })
    assert.deepEqual(mapper.map('done'), {
        query: 'white whale', items: [], progress: 1, done: true,
    })
})

test('a label of empty string (foliate uses "" for unknown) becomes null', () => {
    const mapper = makeSearchMapper('x')
    const batch = mapper.map({ label: '', subitems: [{ cfi: 'epubcfi(/6)', excerpt }] })
    assert.ok(batch)
    assert.equal(batch.items[0].label, null)
})

test('section search results map with a null label', () => {
    const mapper = makeSearchMapper('whale')
    assert.deepEqual(mapper.map({
        cfi: 'epubcfi(/6/10!/4/2/2/1:88,/4/2/2/1:99)', excerpt,
    }), {
        query: 'whale',
        items: [{ cfi: 'epubcfi(/6/10!/4/2/2/1:88,/4/2/2/1:99)', label: null, excerpt }],
        progress: 0,
        done: false,
    })
})

test('unknown yields map to null', () => {
    const mapper = makeSearchMapper('x')
    assert.equal(mapper.map(undefined), null)
    assert.equal(mapper.map({}), null)
})

test('every mapped batch validates as a searchResults event', () => {
    const mapper = makeSearchMapper('white whale')
    const batches = [
        { progress: 0.5 },
        { label: 'Ch 3', subitems: [{ cfi: 'epubcfi(/6)', excerpt }] },
        'done',
    ]
        .map(r => mapper.map(r))
        .filter((batch): batch is NonNullable<typeof batch> => batch !== null)
    for (const batch of batches)
        assert.deepEqual(validateEvent(makeEvent('searchResults', batch)), { ok: true })
})
