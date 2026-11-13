// Trackpad gesture tracker: axis latching, drag + lift velocity, discrete turns.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeSwipeTracker, liftVelocity } from '../src/bridge/swipe.ts'

test('a horizontal drag follows the fingers and settles with the lift velocity', () => {
    const t = makeSwipeTracker()
    assert.deepEqual(t.feed('begin', 0, 0, 0, true), [])
    assert.deepEqual(t.feed('change', 2, 1, 8, true), [])          // not latched yet
    assert.deepEqual(t.feed('change', 3, 0, 16, true), [{ kind: 'drag', delta: 5 }])
    assert.deepEqual(t.feed('change', 16, 4, 32, true), [{ kind: 'drag', delta: 16 }])
    const [settle] = t.feed('end', 0, 0, 40, true)
    assert.equal(settle.kind, 'settle')
    assert.ok(settle.kind === 'settle' && settle.velocity > 0.5)
})

test('resting before the lift settles without a push; a touch without movement does nothing', () => {
    const t = makeSwipeTracker()
    t.feed('begin', 0, 0, 0, true)
    t.feed('change', -40, 0, 10, true)
    assert.deepEqual(t.feed('end', 0, 0, 500, true), [{ kind: 'settle', velocity: 0 }])
    t.feed('begin', 0, 0, 600, true)
    assert.deepEqual(t.feed('cancel', 0, 0, 700, true), [])
})

test('a vertical gesture, or one that cannot drag, turns once per gesture', () => {
    const t = makeSwipeTracker()
    t.feed('begin', 0, 0, 0, true)
    const actions = [0, 1, 2, 3, 4].flatMap(i => t.feed('change', 1, 12, i * 8, true))
    assert.deepEqual(actions, [{ kind: 'turn', axis: 'y', forward: true }])
    assert.deepEqual(t.feed('end', 0, 0, 50, true), [])
    t.feed('begin', 0, 0, 100, false)
    const back = [0, 1, 2, 3].flatMap(i => t.feed('change', -12, 0, 100 + i * 8, false))
    assert.deepEqual(back, [{ kind: 'turn', axis: 'x', forward: false }])
})

test('lift velocity looks only at the last moments', () => {
    assert.equal(liftVelocity([], 100), 0)
    assert.equal(liftVelocity([{ time: 0, delta: 100 }, { time: 90, delta: 16 }], 100), 1)
})
