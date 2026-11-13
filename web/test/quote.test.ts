// The reader's half of quote anchors: the same cases as Swift's QuoteAnchorTests
// (Tests/Fixtures/quotes/resolve.json), so the CLI's links land on the same words.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolve, resolveInNodes } from '../src/bridge/quote.ts'
import type { QuoteAnchor } from '../src/bridge/quote.ts'

interface Case {
    name: string
    source: string
    anchor: QuoteAnchor
    expected: [number, number] | null
}

const casesPath = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'Tests/Fixtures/quotes/resolve.json')
const cases = JSON.parse(readFileSync(casesPath, 'utf8')) as Case[]

test('the shared resolution cases', () => {
    assert.ok(cases.length > 10)
    for (const item of cases)
        assert.deepEqual(resolve(item.source, item.anchor), item.expected, item.name)
})

test('a match across text nodes maps to node offsets', () => {
    // <p>Not <em>the</em> whale</p>\n<p>said</p>: inline elements and block whitespace
    const texts = ['Not ', 'the', ' whale', '\n', 'said']
    const anchor = { text: 'the whale said', prefix: 'Not', suffix: '', occurrence: 0 }
    assert.deepEqual(resolveInNodes(texts, anchor), {
        start: { node: 1, offset: 0 },
        end: { node: 4, offset: 4 },
    })
    // an end exactly at a node's end stays in that node
    assert.deepEqual(resolveInNodes(texts, { ...anchor, text: 'Not the' }), {
        start: { node: 0, offset: 0 },
        end: { node: 1, offset: 3 },
    })
    assert.equal(resolveInNodes(texts, { ...anchor, text: 'nowhere' }), null)
})
