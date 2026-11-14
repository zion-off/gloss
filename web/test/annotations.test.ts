// Annotation plan diffing: add/remove/update/merge/split, idsAt, styleFor.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
    entriesFromPayload,
    planAnnotations,
    idsAt,
    groupQuoteMarkers,
    resolveMarkers,
    styleFor,
    type AnnotationsPayloadInput,
    type CfiMarker,
    type AnnotationPlan,
    type DrawnEntry,
    type StyleColors,
} from '../src/bridge/annotations.ts'
import { type HighlightAnnotation } from '../src/bridge/protocol.ts'

const CFI_A = 'epubcfi(/6/8!/4/2/1:0,/4/2/1:10)'
const CFI_B = 'epubcfi(/6/10!/4/2/2/1:5)'
const CFI_C = 'epubcfi(/6/12!/4/2/1:0)'

const payload = (
    highlights: HighlightAnnotation[] = [],
    markers: CfiMarker[] = [],
): Required<AnnotationsPayloadInput> => ({ highlights, markers })
const hl = (id: string, cfi: string, color: HighlightAnnotation['color'] = 'yellow'): HighlightAnnotation =>
    ({ id, cfi, color })
const mk = (id: string, cfi: string): CfiMarker => ({ id, cfi })

const cfis = (plan: AnnotationPlan) => ({
    add: plan.add.map(e => e.cfi),
    remove: plan.remove.map(e => e.cfi),
    update: plan.update.map(e => e.cfi),
})

test('entriesFromPayload merges a highlight and markers at one CFI', () => {
    const entries = entriesFromPayload(payload(
        [hl('h1', CFI_A), hl('h2', CFI_B, 'blue')],
        [mk('m1', CFI_A), mk('m2', CFI_A), mk('m3', CFI_C)],
    ))
    assert.deepEqual(entries, [
        { cfi: CFI_A, highlight: { id: 'h1', color: 'yellow' }, markerIDs: ['m1', 'm2'] },
        { cfi: CFI_B, highlight: { id: 'h2', color: 'blue' }, markerIDs: [] },
        { cfi: CFI_C, highlight: null, markerIDs: ['m3'] },
    ])
})

test('entriesFromPayload tolerates empty and missing arrays', () => {
    assert.deepEqual(entriesFromPayload({}), [])
    assert.deepEqual(entriesFromPayload(payload()), [])
})

test('plan: drawing nothing yet → everything is an add', () => {
    const plan = planAnnotations(payload([hl('h1', CFI_A)], [mk('m1', CFI_B)]), [])
    assert.deepEqual(cfis(plan), { add: [CFI_A, CFI_B], remove: [], update: [] })
    assert.deepEqual(plan.add[0], { cfi: CFI_A, highlight: { id: 'h1', color: 'yellow' }, markerIDs: [] })
})

test('plan: identical desired state → empty plan', () => {
    const current = entriesFromPayload(payload([hl('h1', CFI_A)], [mk('m1', CFI_B)]))
    const plan = planAnnotations(payload([hl('h1', CFI_A)], [mk('m1', CFI_B)]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [] })
})

test('plan: clearing everything → all removed', () => {
    const current = entriesFromPayload(payload([hl('h1', CFI_A)], [mk('m1', CFI_B)]))
    const plan = planAnnotations(payload(), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [CFI_A, CFI_B], update: [] })
})

test('plan: recolouring a highlight → update, not remove+add', () => {
    const current = entriesFromPayload(payload([hl('h1', CFI_A)]))
    const plan = planAnnotations(payload([hl('h1', CFI_A, 'green')]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [CFI_A] })
    assert.deepEqual(plan.update[0].highlight, { id: 'h1', color: 'green' })
})

test('plan: changing the highlight id at the same CFI → update', () => {
    const current = entriesFromPayload(payload([hl('h1', CFI_A)]))
    const plan = planAnnotations(payload([hl('h9', CFI_A)]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [CFI_A] })
})

test('plan: adding a second marker at a CFI → update with both ids', () => {
    const current = entriesFromPayload(payload([], [mk('m1', CFI_A)]))
    const plan = planAnnotations(payload([], [mk('m1', CFI_A), mk('m2', CFI_A)]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [CFI_A] })
    assert.deepEqual(plan.update[0].markerIDs, ['m1', 'm2'])
})

test('plan: removing one of two markers → update, other marker survives', () => {
    const current = entriesFromPayload(payload([], [mk('m1', CFI_A), mk('m2', CFI_A)]))
    const plan = planAnnotations(payload([], [mk('m2', CFI_A)]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [CFI_A] })
    assert.deepEqual(plan.update[0].markerIDs, ['m2'])
})

test('plan: removing one of two kinds at a CFI → update, not remove', () => {
    const current = entriesFromPayload(payload([hl('h1', CFI_A)], [mk('m1', CFI_A)]))
    const plan = planAnnotations(payload([hl('h1', CFI_A)]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [CFI_A] })
    assert.deepEqual(plan.update[0],
        { cfi: CFI_A, highlight: { id: 'h1', color: 'yellow' }, markerIDs: [] })
})

test('plan: adding the other kind at a CFI → update merging both', () => {
    const current = entriesFromPayload(payload([hl('h1', CFI_A)]))
    const plan = planAnnotations(payload([hl('h1', CFI_A)], [mk('m1', CFI_A)]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [CFI_A] })
    assert.deepEqual(plan.update[0],
        { cfi: CFI_A, highlight: { id: 'h1', color: 'yellow' }, markerIDs: ['m1'] })
})

test('plan: independent add, update and remove in one pass', () => {
    const current = entriesFromPayload(payload(
        [hl('h1', CFI_A), hl('h2', CFI_B)],
        [mk('m1', CFI_C)],
    ))
    const plan = planAnnotations(payload(
        [hl('h1', CFI_A, 'pink'), hl('h3', CFI_C)],
        [mk('m1', CFI_C), mk('m2', CFI_C)],
    ), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [CFI_B], update: [CFI_A, CFI_C] })
})

test('plan ignores extra bookkeeping fields on current entries', () => {
    const current: DrawnEntry[] = entriesFromPayload(payload([hl('h1', CFI_A)]))
    current[0].index = 3
    const plan = planAnnotations(payload([hl('h1', CFI_A)]), current)
    assert.deepEqual(cfis(plan), { add: [], remove: [], update: [] })
})

test('idsAt returns both kinds at a merged CFI', () => {
    const state = entriesFromPayload(payload([hl('h1', CFI_A)], [mk('m1', CFI_A), mk('m2', CFI_A)]))
    assert.deepEqual(idsAt(CFI_A, state), { highlightIDs: ['h1'], markerIDs: ['m1', 'm2'] })
})

test('idsAt for marker-only, and for unknown CFIs', () => {
    const state = entriesFromPayload(payload([], [mk('m1', CFI_B)]))
    assert.deepEqual(idsAt(CFI_B, state), { highlightIDs: [], markerIDs: ['m1'] })
    assert.deepEqual(idsAt(CFI_A, state), { highlightIDs: [], markerIDs: [] })
    assert.deepEqual(idsAt(CFI_A, []), { highlightIDs: [], markerIDs: [] })
    assert.deepEqual(idsAt(CFI_A, undefined), { highlightIDs: [], markerIDs: [] })
})

test('idsAt returns copies, not the live arrays', () => {
    const state = entriesFromPayload(payload([], [mk('m1', CFI_A)]))
    const ids = idsAt(CFI_A, state)
    ids.markerIDs.push('m9')
    assert.deepEqual(state[0].markerIDs, ['m1'])
})

const colors: StyleColors = {
    marker: 'rgba(0, 0, 0, 0.4)',
    highlights: {
        yellow: 'rgba(240, 199, 56, 0.35)',
        green: 'rgba(98, 165, 122, 0.35)',
        blue: 'rgba(96, 138, 188, 0.35)',
        pink: 'rgba(216, 128, 149, 0.35)',
        purple: 'rgba(154, 111, 181, 0.35)',
    },
}

test('styleFor: highlight only', () => {
    const entry = entriesFromPayload(payload([hl('h1', CFI_A, 'blue')]))[0]
    assert.deepEqual(styleFor(entry, colors), {
        highlightColor: 'rgba(96, 138, 188, 0.35)',
        underline: false,
        underlineColor: null,
    })
})

test('styleFor: marker only', () => {
    const entry = entriesFromPayload(payload([], [mk('m1', CFI_A)]))[0]
    assert.deepEqual(styleFor(entry, colors), {
        highlightColor: null,
        underline: true,
        underlineColor: 'rgba(0, 0, 0, 0.4)',
    })
})

test('styleFor: highlight plus markers draws both', () => {
    const entry = entriesFromPayload(payload([hl('h1', CFI_A, 'green')], [mk('m1', CFI_A)]))[0]
    assert.deepEqual(styleFor(entry, colors), {
        highlightColor: 'rgba(98, 165, 122, 0.35)',
        underline: true,
        underlineColor: 'rgba(0, 0, 0, 0.4)',
    })
})

test('styleFor: unknown entry or colours falls back to nothing drawn', () => {
    assert.deepEqual(styleFor(null, colors),
        { highlightColor: null, underline: false, underlineColor: null })
    assert.deepEqual(styleFor({ cfi: CFI_A, highlight: null, markerIDs: [] }, null),
        { highlightColor: null, underline: false, underlineColor: null })
    const entry = entriesFromPayload(payload([hl('h1', CFI_A)]))[0]
    assert.deepEqual(styleFor(entry, {}),
        { highlightColor: null, underline: false, underlineColor: null })
})

test('quote markers are placed by the CFI their words resolve to; unfound ones are left out', async () => {
    const quote = { section: 4, text: 'the whale', prefix: 'Not', suffix: '', occurrence: 1 }
    const asked: unknown[] = []
    const resolved = await resolveMarkers({
        highlights: [hl('h1', CFI_A)],
        markers: [mk('m1', CFI_B), { id: 'm2', quote }, { id: 'm3', quote: { ...quote, text: 'nowhere' } }],
    }, async (section, quotes) => {
        asked.push([section, quotes.length])
        return quotes.map(q => q.text === 'the whale' ? CFI_C : null)
    })
    assert.deepEqual(resolved, { highlights: [hl('h1', CFI_A)], markers: [mk('m1', CFI_B), mk('m2', CFI_C)] })
    assert.deepEqual(asked, [[4, 2]])
})

test('quote markers are grouped by section: one lookup each, payload order kept', async () => {
    const q = (section: number, text: string) => ({ section, text, prefix: '', suffix: '', occurrence: 0 })
    const markers = [
        { id: 'a', quote: q(7, 'a') }, mk('c1', CFI_A), { id: 'b', quote: q(2, 'b') },
        { id: 'c', quote: q(7, 'c') }, { id: 'd', quote: q(2, 'd') },
    ]
    const groups = groupQuoteMarkers(markers)
    assert.deepEqual([...groups.keys()], [7, 2])
    assert.deepEqual(groups.get(7)?.map(e => [e.index, e.quote.text]), [[0, 'a'], [3, 'c']])
    assert.deepEqual(groups.get(2)?.map(e => [e.index, e.quote.text]), [[2, 'b'], [4, 'd']])
    assert.equal(groupQuoteMarkers([mk('x', CFI_A)]).size, 0)

    const asked: [number, string[]][] = []
    const resolved = await resolveMarkers({ highlights: [], markers }, async (section, quotes) => {
        asked.push([section, quotes.map(x => x.text)])
        return quotes.map(x => x.text === 'd' ? null : `cfi-${x.text}`)
    })
    assert.deepEqual(asked, [[7, ['a', 'c']], [2, ['b', 'd']]])
    assert.deepEqual(resolved.markers.map(m => m.id), ['a', 'c1', 'b', 'c'])
    assert.deepEqual(resolved.markers.map(m => m.cfi), ['cfi-a', CFI_A, 'cfi-b', 'cfi-c'])
})
