// Protocol validation and the shared command/event fixtures. The Swift side
// decodes the exact same files in Tests/Fixtures/bridge/, so both
// implementations are tested against one contract.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
    PROTOCOL_VERSION,
    COMMAND_TYPES,
    EVENT_TYPES,
    validateCommand,
    validateEvent,
    makeEvent,
    type RelocatedPayload,
} from '../src/bridge/protocol.ts'
import { readJsonFiles, fixturesDir, fixtureNamed } from './helpers.ts'

const commandFixtures = readJsonFiles(fixturesDir('commands'))
const eventFixtures = readJsonFiles(fixturesDir('events'))

const sampleRelocated = (): RelocatedPayload => ({
    cfi: 'epubcfi(/6/8!/4/2/1:23)',
    fraction: 0.281,
    section: { index: 3, count: 14 },
    tocLabel: 'Chapter 1. Loomings',
    tocHref: 'text/ch1.xhtml',
    pageLabel: null,
    pagesLeftInSection: 7,
    atStart: false,
    atEnd: false,
})

test('fixture files are exactly one per command type', () => {
    const names = commandFixtures.map(f => f.name.replace(/\.json$/, ''))
    assert.deepEqual([...names].sort(), [...COMMAND_TYPES].sort())
    assert.equal(new Set(names).size, names.length, 'no duplicate fixtures')
})

test('fixture files are exactly one per event type', () => {
    const names = eventFixtures.map(f => f.name.replace(/\.json$/, ''))
    assert.deepEqual([...names].sort(), [...EVENT_TYPES].sort())
    assert.equal(new Set(names).size, names.length, 'no duplicate fixtures')
})

test('every command fixture passes validateCommand', () => {
    for (const { name, envelope } of commandFixtures) {
        const res = validateCommand(envelope)
        assert.deepEqual(res, { ok: true }, `${name}: ${res.ok ? '' : res.error}`)
    }
})

test('every event fixture passes validateEvent', () => {
    for (const { name, envelope } of eventFixtures) {
        const res = validateEvent(envelope)
        assert.deepEqual(res, { ok: true }, `${name}: ${res.ok ? '' : res.error}`)
    }
})

test('makeEvent stamps the version and validates for payloadless events', () => {
    for (const type of ['ready', 'selectionCleared'] as const)
        assert.deepEqual(validateEvent(makeEvent(type, {})), { ok: true }, type)
    const envelope = makeEvent('relocated', sampleRelocated())
    assert.equal(envelope.v, PROTOCOL_VERSION)
    assert.deepEqual(validateEvent(envelope), { ok: true })
    // events that require fields must fail when the fields are absent
    assert.equal(validateEvent({ v: 1, type: 'relocated', payload: {} }).ok, false)
})

// -- negative cases ------------------------------------------------------

const invalidCommand = (envelope: unknown, note: string) => {
    const res = validateCommand(envelope)
    assert.equal(res.ok, false, note)
    assert.match(res.ok ? '' : res.error, /^bridge:/, note)
    return res
}

const invalidEvent = (envelope: unknown, note: string) => {
    const res = validateEvent(envelope)
    assert.equal(res.ok, false, note)
    assert.match(res.ok ? '' : res.error, /^bridge:/, note)
    return res
}

test('rejects wrong or missing protocol version', () => {
    invalidCommand({ v: 2, type: 'clearSearch', payload: {} }, 'command v2')
    invalidEvent({ v: 0, type: 'ready', payload: {} }, 'event v0')
    invalidCommand({ type: 'clearSearch', payload: {} }, 'no v')
    invalidCommand({ v: '1', type: 'clearSearch', payload: {} }, 'string v')
})

test('rejects unknown or missing types', () => {
    invalidCommand({ v: 1, type: 'flyToMoon', payload: {} }, 'unknown command')
    invalidEvent({ v: 1, type: 'exploded', payload: {} }, 'unknown event')
    invalidCommand({ v: 1, payload: {} }, 'missing type')
})

test('rejects non-object envelopes and payloads', () => {
    invalidCommand(null, 'null envelope')
    invalidCommand([1, 2], 'array envelope')
    invalidCommand({ v: 1, type: 'setSearchHighlights', payload: 'nope' }, 'string payload')
    invalidCommand({ v: 1, type: 'setSearchHighlights' }, 'missing payload')
})

test('rejects missing and mistyped fields', () => {
    invalidCommand({ v: 1, type: 'setSearchHighlights', payload: {} }, 'search without query')
    invalidCommand({ v: 1, type: 'setSearchHighlights', payload: { query: 42 } }, 'query not a string')
    invalidCommand({ v: 1, type: 'turnPage', payload: { direction: 'up' } }, 'bad direction')
    invalidCommand({ v: 1, type: 'turnPage', payload: { direction: 'foward' } }, 'typo direction')
    invalidCommand({ v: 1, type: 'open', payload: { url: 'u', position: null } }, 'open without appearance')
    invalidCommand({ v: 1, type: 'open', payload: { url: 1, position: null, appearance: {} } }, 'url not a string')
    invalidCommand({ v: 1, type: 'open', payload: {
        url: 'u', position: null,
        appearance: { flow: 'diagonal', css: '', layout: {}, colors: {} },
    } }, 'bad flow')
    invalidCommand({ v: 1, type: 'open', payload: {
        url: 'u', position: null,
        appearance: {
            flow: 'paginated', css: '',
            layout: { margin: 48, gap: 1.5, maxInlineSize: 720, maxColumnCount: 2 },
            colors: { background: '#fff', foreground: '#000', marker: '#000', highlights: {} },
        },
    } }, 'gap out of range')
    invalidCommand({ v: 1, type: 'open', payload: {
        url: 'u', position: null,
        appearance: {
            flow: 'paginated', css: '',
            layout: { margin: 48, gap: 0.06, maxInlineSize: 720, maxColumnCount: 2.5 },
            colors: { background: '#fff', foreground: '#000', marker: '#000', highlights: {} },
        },
    } }, 'maxColumnCount not an integer')
    invalidCommand({ v: 1, type: 'open', payload: {
        url: 'u', position: null,
        appearance: {
            flow: 'paginated', css: '',
            layout: { margin: 48, gap: 0.06, maxInlineSize: 720, maxColumnCount: 2 },
            colors: {
                background: '#fff', foreground: '#000', marker: '#000',
                highlights: { yellow: 'y', green: 'g', blue: 'b', pink: 'p' },
            },
        },
    } }, 'missing purple highlight colour')
    invalidCommand({ v: 1, type: 'setAnnotations', payload: {
        highlights: [{ id: 'a', cfi: 'epubcfi(/6)', color: 'crimson' }], markers: [],
    } }, 'bad highlight colour name')
    invalidCommand({ v: 1, type: 'setAnnotations', payload: {
        highlights: [], markers: [{ id: 'm', cfi: 3 }],
    } }, 'marker cfi not a string')
    invalidCommand({ v: 1, type: 'revealSearchHit', payload: { cfi: null, section: -1, text: 'x', quote: null } }, 'negative section')
    invalidCommand({ v: 1, type: 'revealSearchHit', payload: { cfi: 5, section: null, text: 'x', quote: null } }, 'cfi not a string')
    invalidCommand({ v: 1, type: 'revealSearchHit', payload: { cfi: null, section: 3, text: 'x' } }, 'quote left out, not null')
    invalidCommand({ v: 1, type: 'revealSearchHit', payload: { cfi: null, section: 3, text: 'x', quote: {
        section: 3, text: 'x', prefix: '', suffix: '', occurrence: -1,
    } } }, 'negative quote occurrence')
})

test('goTo target must have exactly one of cfi/href/fraction', () => {
    const go = (target: unknown) =>
        validateCommand({ v: 1, type: 'goTo', payload: { target } })
    assert.equal(go({ cfi: 'epubcfi(/6)' }).ok, true)
    assert.equal(go({ href: 'text/ch1.xhtml' }).ok, true)
    assert.equal(go({ fraction: 0.5 }).ok, true)
    assert.equal(go({}).ok, false)
    assert.equal(go({ cfi: 'epubcfi(/6)', href: 'x' }).ok, false)
    assert.equal(go({ cfi: 'epubcfi(/6)', fraction: 0.5 }).ok, false)
    assert.equal(go({ fraction: 1.5 }).ok, false)
    assert.equal(go({ cfi: 42 }).ok, false)
    assert.equal(go('epubcfi(/6)').ok, false)
})

test('event field checks', () => {
    invalidEvent({ v: 1, type: 'relocated', payload: {
        cfi: 'epubcfi(/6)', fraction: 0.5,
        section: { index: 0, count: 2 },
        tocLabel: null, tocHref: null, pageLabel: null,
        pagesLeftInSection: -3, atStart: false, atEnd: false,
    } }, 'negative pagesLeftInSection')
    invalidEvent({ v: 1, type: 'relocated', payload: {
        cfi: 'epubcfi(/6)', fraction: 0.5,
        section: { index: 0 },
        tocLabel: null, tocHref: null, pageLabel: null,
        pagesLeftInSection: null, atStart: false, atEnd: false,
    } }, 'section missing count')
    invalidEvent({ v: 1, type: 'selectionChanged', payload: {
        cfi: 'epubcfi(/6)', text: 'hi', label: null, fraction: null,
        rect: { x: 0, y: 0, width: 'wide', height: 1 },
    } }, 'rect width not a number')
    invalidEvent({ v: 1, type: 'annotationActivated', payload: {
        highlightIDs: 'note-1', markerIDs: [], rect: { x: 0, y: 0, width: 1, height: 1 },
    } }, 'highlightIDs not an array')
    invalidEvent({ v: 1, type: 'linkActivated', payload: {
        href: 'https://x', external: 'yes',
    } }, 'external not a bool')
    invalidEvent({ v: 1, type: 'error', payload: { message: 42 } }, 'error with a number message')
    invalidEvent({ v: 1, type: 'error', payload: { message: 'boom', context: 42 } }, 'context not a string')
    invalidEvent({ v: 1, type: 'opened', payload: {
        toc: [{ label: 'a', href: 'b', children: 'nope' }],
        sectionCount: 3, direction: 'ltr', fixedLayout: false,
    } }, 'toc children not an array')
    invalidEvent({ v: 1, type: 'opened', payload: {
        toc: [{ label: 'a', href: 'b', children: [] },
            { label: 'p', href: 'q', children: [{ href: 'r', children: [] }] }],
        sectionCount: 3, direction: 'rtl', fixedLayout: true,
    } }, 'nested toc item missing label')
})

test('commands do not validate as events and vice versa', () => {
    assert.equal(validateEvent(fixtureNamed(commandFixtures, 'clearSearch.json')).ok, false)
    assert.equal(validateCommand(fixtureNamed(eventFixtures, 'ready.json')).ok, false)
})

test('extra fields are tolerated', () => {
    assert.equal(validateCommand({
        v: 1, type: 'setSearchHighlights', payload: { query: 'x', future: 'field' },
    }).ok, true)
})

test('PROTOCOL_VERSION is 1', () => {
    assert.equal(PROTOCOL_VERSION, 1)
})
