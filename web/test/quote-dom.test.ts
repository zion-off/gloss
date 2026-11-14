// The DOM half of quote resolution, over parsed sections: quotes across inline elements, line
// breaks and paragraphs, repeated quotes, and the text the reader doesn't show.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { JSDOM } from 'jsdom'
import { quoteRange, textNodes } from '../src/bridge/quote-dom.ts'
import type { QuoteAnchor } from '../src/bridge/quote.ts'

const { window } = new JSDOM('')
const XHTML_NS = 'http://www.w3.org/1999/xhtml'
const section = (body: string): Document =>
    new window.DOMParser().parseFromString(
        `<html xmlns="${XHTML_NS}"><head><title>t</title></head><body>${body}</body></html>`, 'application/xhtml+xml')

const anchor = (text: string, extra: Partial<QuoteAnchor> = {}): QuoteAnchor =>
    ({ text, prefix: '', suffix: '', occurrence: 0, ...extra })

test('a quote spanning italics, a line break and two paragraphs', () => {
    const doc = section('<p>Call me <i>Ish</i>mael. Some<br/>years ago</p>\n<p>never mind how long</p>')
    const range = quoteRange(doc, anchor('Ishmael. Some years ago never mind'))
    assert.ok(range)
    assert.equal(range.toString().replace(/\s+/g, ' '), 'Ishmael. Someyears ago never mind')
    assert.equal(range.startContainer.nodeValue, 'Ish')
    assert.equal(range.startOffset, 0)
    assert.equal(range.endContainer.nodeValue, 'never mind how long')
    assert.equal(range.endOffset, 'never mind'.length)
})

test('a repeated quote: context first, then the occurrence number', () => {
    const doc = section('<p>the whale</p><p>and the whale</p><p>then the whale again</p>')
    const third = quoteRange(doc, anchor('the whale', { occurrence: 2 }))
    assert.equal(third?.endContainer.nodeValue, 'then the whale again')
    const second = quoteRange(section('<p>the whale</p><p>and the whale</p><p>then the whale again</p>'),
        anchor('the whale', { occurrence: 1 }))
    assert.equal(second?.startContainer.nodeValue, 'and the whale')
    // context beats a stale occurrence
    const byContext = quoteRange(section('<p>the whale</p><p>and the whale</p><p>then the whale again</p>'),
        anchor('the whale', { occurrence: 0, prefix: 'and', suffix: '' }))
    assert.equal(byContext?.startContainer.nodeValue, 'and the whale')
})

test('words that are not there give no range', () => {
    assert.equal(quoteRange(section('<p>call me</p>'), anchor('the white whale')), null)
})

test('text the reader never shows is not searched: script, style, svg, math, comments', () => {
    const doc = section('<p>a</p><script>whale</script><style>whale</style>'
        + '<svg xmlns="http://www.w3.org/2000/svg"><text>whale</text></svg>'
        + '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>whale</mi></math><!-- whale --><p>b whale</p>')
    assert.deepEqual(textNodes(doc).map(node => node.nodeValue), ['a', 'b whale'])
    assert.equal(quoteRange(doc, anchor('whale'))?.startContainer.nodeValue, 'b whale')
})
