// The glue's choreography, testable under Node: one command at a time, stale work ignored.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeSerialQueue, makeGeneration } from '../src/bridge/queue.ts'

const tick = (): Promise<void> => new Promise(resolve => setImmediate(resolve))

test('commands run one at a time, in arrival order', async () => {
    const queue = makeSerialQueue()
    const log: string[] = []
    const make = (name: string, ticks: number): () => Promise<void> =>
        async () => {
            log.push(`start ${name}`)
            for (let i = 0; i < ticks; i++) await tick()
            log.push(`end ${name}`)
        }
    const first = queue.run(make('a', 3))
    const second = queue.run(make('b', 1))
    const third = queue.run(make('c', 0))
    await Promise.all([first, second, third])
    assert.deepEqual(log, ['start a', 'end a', 'start b', 'end b', 'start c', 'end c'])
})

test("a failing command doesn't break the chain, and its rejection reaches the caller", async () => {
    const queue = makeSerialQueue()
    const log: string[] = []
    const failure = queue.run(async () => { throw new Error('fetch failed') })
    await queue.run(async () => { log.push('still runs') })
    await assert.rejects(failure, /fetch failed/)
    assert.deepEqual(log, ['still runs'])
})

test('a generation invalidates work started before a newer one', () => {
    const generation = makeGeneration()
    const first = generation.bump()
    assert.equal(generation.isCurrent(first), true)
    assert.equal(generation.value(), first)
    const second = generation.bump()
    assert.equal(generation.isCurrent(first), false)
    assert.equal(generation.isCurrent(second), true)
})
