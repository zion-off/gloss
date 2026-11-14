// selectionChanged payload construction and the injectable-timer debouncer.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
    normalizeText,
    makeSelectionPayload,
    makeDebouncer,
    makeSelectionGate,
    type DebouncerTimers,
} from '../src/bridge/selection.ts'

test('builds the payload, offsetting the rect by the iframe position', () => {
    const payload = makeSelectionPayload({
        cfi: 'epubcfi(/6/8!/4/2/1:23,/4/2/1:57)',
        text: 'Call me Ishmael.',
        label: 'Chapter 1. Loomings',
        fraction: 0.281,
        rect: { x: 12.5, y: 100, width: 300, height: 22.5 },
        iframeOffset: { x: 84, y: 108.25 },
    })
    assert.deepEqual(payload, {
        cfi: 'epubcfi(/6/8!/4/2/1:23,/4/2/1:57)',
        text: 'Call me Ishmael.',
        label: 'Chapter 1. Loomings',
        fraction: 0.281,
        rect: { x: 96.5, y: 208.25, width: 300, height: 22.5 },
    })
})

test('whitespace-normalises the text', () => {
    const payload = makeSelectionPayload({
        cfi: 'epubcfi(/6)',
        text: '  a\n\n b\t c  ',
        label: null,
        fraction: null,
        rect: { x: 0, y: 0, width: 10, height: 10 },
        iframeOffset: { x: 0, y: 0 },
    })
    assert.ok(payload)
    assert.equal(payload.text, 'a b c')
})

test('drops empty selections to null', () => {
    const base = {
        cfi: 'epubcfi(/6)', label: null, fraction: null,
        rect: { x: 0, y: 0, width: 10, height: 10 }, iframeOffset: { x: 0, y: 0 },
    }
    assert.equal(makeSelectionPayload({ ...base, text: '   \n\t ' }), null)
    assert.equal(makeSelectionPayload({ ...base, text: '' }), null)
    assert.equal(makeSelectionPayload({ ...base, text: 'hi', cfi: '' }), null)
    assert.equal(makeSelectionPayload({ ...base, text: 'hi', cfi: null as unknown as string }), null)
    assert.equal(makeSelectionPayload({ ...base, text: 'hi', rect: null as unknown as never }), null)
    assert.equal(makeSelectionPayload({ ...base, text: 'hi', rect: undefined as unknown as never }), null)
})

test('missing optional inputs become null, not undefined', () => {
    const payload = makeSelectionPayload({
        cfi: 'epubcfi(/6)',
        text: 'hi',
        rect: { x: 1, y: 2, width: 3, height: 4 },
    })
    assert.deepEqual(payload, {
        cfi: 'epubcfi(/6)',
        text: 'hi',
        label: null,
        fraction: null,
        rect: { x: 1, y: 2, width: 3, height: 4 },
    })
})

test('normalizeText handles non-strings', () => {
    assert.equal(normalizeText(undefined), '')
    assert.equal(normalizeText(null), '')
    assert.equal(normalizeText(42), '')
})

// fake timers: capture scheduled callbacks instead of running them
interface ScheduledTimer {
    fn: () => void
    delay: number
}
const makeFakeTimers = (): DebouncerTimers & {
    scheduled: Array<ScheduledTimer | undefined>
    flush(): void
} => {
    const scheduled: Array<ScheduledTimer | undefined> = []
    const timers = {
        scheduled,
        setTimeout: (fn: () => void, delay: number): unknown => {
            scheduled.push({ fn, delay })
            return scheduled.length - 1
        },
        clearTimeout: (handle: unknown): void => {
            scheduled[handle as number] = undefined
        },
        flush: (): void => {
            const pending = scheduled.filter((x): x is ScheduledTimer => x !== undefined)
            scheduled.length = 0
            for (const { fn } of pending) fn()
        },
    }
    return timers
}

test('debouncer fires once, after the delay, with the latest args', () => {
    const timers = makeFakeTimers()
    const calls: string[][] = []
    const debounced = makeDebouncer((...args: string[]) => calls.push(args), 150, timers)
    debounced('a')
    debounced('b')
    debounced('c')
    assert.deepEqual(calls, [])
    assert.equal(debounced.pending(), true)
    timers.flush()
    assert.deepEqual(calls, [['c']])
    assert.equal(debounced.pending(), false)
})

test('debouncer passes the delay through', () => {
    const timers = makeFakeTimers()
    const debounced = makeDebouncer(() => {}, 150, timers)
    debounced()
    const scheduled = timers.scheduled.filter((x): x is ScheduledTimer => x !== undefined)
    assert.equal(scheduled.length, 1)
    assert.equal(scheduled[0].delay, 150)
})

test('debouncer cancel prevents firing', () => {
    const timers = makeFakeTimers()
    const calls: string[] = []
    const debounced = makeDebouncer((x: string) => calls.push(x), 150, timers)
    debounced('x')
    debounced.cancel()
    assert.equal(debounced.pending(), false)
    timers.flush()
    assert.deepEqual(calls, [])
})

test('debouncer can fire again after being cancelled', () => {
    const timers = makeFakeTimers()
    const calls: string[] = []
    const debounced = makeDebouncer((x: string) => calls.push(x), 150, timers)
    debounced('one')
    debounced.cancel()
    debounced('two')
    timers.flush()
    assert.deepEqual(calls, ['two'])
})

test('gate holds a selection made while the button is down until it comes up', () => {
    let reports = 0
    const gate = makeSelectionGate(() => { reports += 1 })
    gate.press()
    gate.changed(false)
    gate.changed(false)
    assert.equal(reports, 0)
    gate.release()
    assert.equal(reports, 1)
})

test('gate reports a cleared selection even while the button is down', () => {
    let reports = 0
    const gate = makeSelectionGate(() => { reports += 1 })
    gate.press()
    gate.changed(true)
    assert.equal(reports, 1)
})

test('gate reports keyboard selections as they settle', () => {
    let reports = 0
    const gate = makeSelectionGate(() => { reports += 1 })
    gate.changed(false)
    assert.equal(reports, 1)
    gate.press()
    gate.release()
    gate.changed(false)
    assert.equal(reports, 3)
})
