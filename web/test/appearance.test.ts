// Appearance → renderer operations, exactly as paginator.js expects them.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { appearanceOps, colorSchemeFor } from '../src/bridge/appearance.ts'
import type { Appearance } from '../src/bridge/protocol.ts'

const appearance: Appearance = {
    flow: 'paginated',
    css: 'html { color: #3b2f1e; } p { line-height: 1.5; }',
    layout: { margin: 48, gap: 0.06, maxInlineSize: 720, maxColumnCount: 2 },
    colors: {
        background: '#f8f1e3', foreground: '#3b2f1e', marker: 'rgba(0,0,0,.4)',
        highlights: { yellow: 'y', green: 'g', blue: 'b', pink: 'p', purple: 'u' },
    },
}

test('maps layout onto paginator attributes and styles', () => {
    assert.deepEqual(appearanceOps(appearance), [
        { op: 'attr', name: 'flow', value: 'paginated' },
        { op: 'attr', name: 'margin', value: '48px' },
        { op: 'attr', name: 'gap', value: '6%' },
        { op: 'attr', name: 'max-inline-size', value: '720px' },
        { op: 'attr', name: 'max-column-count', value: '2' },
        { op: 'styles', css: 'html { color: #3b2f1e; } p { line-height: 1.5; }' },
    ])
})

test('scrolled flow and single-column layout map through', () => {
    const ops = appearanceOps({
        ...appearance,
        flow: 'scrolled',
        layout: { margin: 32, gap: 0.08, maxInlineSize: 640, maxColumnCount: 1 },
    })
    assert.deepEqual(ops[0], { op: 'attr', name: 'flow', value: 'scrolled' })
    assert.deepEqual(ops[1], { op: 'attr', name: 'margin', value: '32px' })
    assert.deepEqual(ops[2], { op: 'attr', name: 'gap', value: '8%' })
    assert.deepEqual(ops[3], { op: 'attr', name: 'max-inline-size', value: '640px' })
    assert.deepEqual(ops[4], { op: 'attr', name: 'max-column-count', value: '1' })
})

test('attr ops only use names in the paginator observedAttributes', () => {
    const observed = ['flow', 'gap', 'margin',
        'max-inline-size', 'max-block-size', 'max-column-count']
    for (const op of appearanceOps(appearance))
        if (op.op === 'attr') assert.ok(observed.includes(op.name), op.name)
})

test('the page colour scheme follows the theme background', () => {
    assert.equal(colorSchemeFor('#f8f1e3'), 'light')
    assert.equal(colorSchemeFor('#ffffff'), 'light')
    assert.equal(colorSchemeFor('#1c1c1e'), 'dark')
    assert.equal(colorSchemeFor('#000'), 'dark')
    assert.equal(colorSchemeFor('rgb(0, 0, 0)'), 'light')
})
