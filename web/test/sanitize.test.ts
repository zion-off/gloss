// Book markup loses everything that could run, and nothing else.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { JSDOM } from 'jsdom'
import { isMarkupType, sanitizeMarkup } from '../src/bridge/sanitize.ts'

const { window } = new JSDOM('')
const parser = new window.DOMParser()
const serializer = new window.XMLSerializer()

const XHTML_NS = 'http://www.w3.org/1999/xhtml'
const xhtml = (body: string): string =>
    `<html xmlns="${XHTML_NS}" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>t</title></head><body>${body}</body></html>`

const clean = (markup: string, type: Parameters<typeof sanitizeMarkup>[1] = 'application/xhtml+xml') =>
    sanitizeMarkup(markup, type, parser, serializer)

test('script elements go, inline and external, in XHTML and SVG', () => {
    const result = clean(xhtml(
        '<p>call me ishmael</p><script>fetch("gloss-reader://app/book/x")</script>'
        + '<script src="evil.js"></script>'
        + '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><circle r="1"/></svg>'))
    assert.equal(result.removed, 3)
    assert.doesNotMatch(result.markup, /script/i)
    assert.match(result.markup, /<p>call me ishmael<\/p>/)
    assert.match(result.markup, /<circle r="1"/)
})

test('event handlers, javascript: URLs and srcdoc go; the elements stay', () => {
    const result = clean(xhtml(
        '<img src="blob:x" onerror="alert(1)" alt="whale"/>'
        + '<a href=" JaVa\tScRiPt:alert(1)">link</a>'
        + '<a href="ch2.xhtml#p3" ONCLICK="x()">next</a>'
        + '<form action="javascript:x()"><button formaction="vbscript:y">go</button></form>'
        + '<iframe srcdoc="&lt;script&gt;x()&lt;/script&gt;"></iframe>'
        + '<body onload="x()"></body>'))
    assert.doesNotMatch(result.markup, /onerror|onclick|javascript|vbscript|srcdoc/i)
    assert.match(result.markup, /<img src="blob:x" alt="whale"/)
    assert.match(result.markup, /<a href="ch2.xhtml#p3">next<\/a>/)
    assert.match(result.markup, /<a>link<\/a>/)
    // onerror, the javascript: href, ONCLICK, action, formaction, srcdoc and the nested onload
    assert.equal(result.removed, 7)
})

test('meta refreshes, base elements and link-rewriting SVG animations go', () => {
    const result = clean(xhtml(
        '<meta http-equiv=" Refresh " content="0;url=javascript:x()"/><base href="https://evil.example/"/>'
        + '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">'
        + '<a xlink:href="#"><set attributeName="xlink:href" to="javascript:x()"/>'
        + '<animate attributeName="opacity" from="0" to="1"/><text>t</text></a></svg>'))
    assert.equal(result.removed, 3)
    assert.doesNotMatch(result.markup, /refresh|<base|<set/i)
    assert.match(result.markup, /<animate attributeName="opacity"/)
})

test('clean markup comes back untouched, byte for byte', () => {
    const markup = xhtml('<h1 epub:type="title">Loomings</h1><p style="color: red">Call me <em>Ishmael</em>.</p>'
        + '<img src="blob:abc" alt=""/><a href="https://www.gutenberg.org/">gutenberg</a>')
    assert.deepEqual(clean(markup), { markup, removed: 0 })
})

test('XHTML stays XHTML after cleaning', () => {
    const result = clean(xhtml('<p>a</p><script>x()</script>'))
    const doc = parser.parseFromString(result.markup, 'application/xhtml+xml')
    assert.equal(doc.getElementsByTagName('parsererror').length, 0)
    assert.equal(doc.documentElement.namespaceURI, XHTML_NS)
})

test('broken XHTML is reparsed as HTML and never passed through', () => {
    const result = clean(`<html xmlns="${XHTML_NS}"><body><p>unclosed<script>x()</script></body></html>`)
    assert.doesNotMatch(result.markup, /script/i)
    assert.match(result.markup, /unclosed/)
})

test('HTML documents are cleaned too', () => {
    const result = clean('<!doctype html><p onclick="x()">hi</p><script>x()</script>', 'text/html')
    assert.equal(result.removed, 2)
    assert.doesNotMatch(result.markup, /script|onclick/i)
})

test('only markup types are cleaned', () => {
    for (const type of ['application/xhtml+xml', 'text/html', 'image/svg+xml', 'application/xml',
        'text/xml', 'application/rss+xml', 'application/atom+xml', 'text/xsl']) {
        assert.equal(isMarkupType(type), true, type)
    }
    for (const type of ['text/css', 'image/png', 'image/jpeg', 'font/woff2', 'audio/mp3',
        'application/epub+zip', 'application/javascript', 'text/plain', undefined, 3] as const) {
        assert.equal(isMarkupType(type), false, String(type))
    }
})

test('xml-stylesheet instructions go; xsl types are cleaned', () => {
    const result = clean('<?xml-stylesheet href="evil.xsl"?><root><set attributeName="onbegin" to="x"/></root>',
        'application/xml')
    assert.doesNotMatch(result.markup, /xml-stylesheet|onbegin/i)
    assert.equal(isMarkupType('text/xsl'), true)
})

test('generic XML types are documents too: scripts and handlers go', () => {
    // An `application/xml` spine item or iframe target is parsed like XHTML (review 4).
    for (const type of ['application/xml', 'text/xml', 'application/rss+xml']) {
        const result = clean(
            '<root xmlns:h="http://www.w3.org/1999/xhtml">'
            + '<h:img src="blob:x" onload="alert(1)"/>'
            + "<h:script>fetch('gloss-reader://app/book/1')</h:script>"
            + '<plain note="stays"/></root>', type)
        assert.equal(result.removed, 2, type)
        assert.doesNotMatch(result.markup, /script|onload/i, type)
        assert.match(result.markup, /plain/, type)
        // XML in, XML out: the round trip is well-formed.
        const doc = parser.parseFromString(result.markup, 'application/xml')
        assert.equal(doc.getElementsByTagName('parsererror').length, 0, type)
    }
})

test('template content is cleaned, nested included', () => {
    // `querySelectorAll('*')` never descends into template content (review 4).
    const result = clean(xhtml(
        '<template><img src="x" onerror="alert(1)"><script>fetch(1)</script>'
        + '<template><a href="javascript:x()">t</a></template></template>'))
    assert.equal(result.removed, 3)
    assert.doesNotMatch(result.markup, /onerror|script|javascript/i)
})

test('SMIL that writes event handlers goes; ordinary animations stay', () => {
    const result = clean(xhtml(
        '<svg xmlns="http://www.w3.org/2000/svg">'
        + '<set attributeName="onbegin" to="alert(1)"/>'
        + '<set attributeName="xlink:href" to="javascript:x()"/>'
        + '<animate attributeName="opacity" from="0" to="1"/></svg>'))
    assert.equal(result.removed, 2)
    assert.match(result.markup, /<animate attributeName="opacity"/)
})
