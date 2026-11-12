// The cross-language contract: every command exactly as Swift encodes it (committed by
// Tests/GlossReaderBridgeTests/WireContractTests.swift) must pass the real validator. Review 1
// found Swift dropping nil fields that this validator requires as null; hand-written fixtures
// could never catch that.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { COMMAND_TYPES, validateCommand } from '../src/bridge/protocol.ts'
import { readJsonFiles, fixturesDir } from './helpers.ts'

const encoded = readJsonFiles(fixturesDir('swift-encoded', 'commands'))

test('swift-encoded commands exist for every command type', () => {
    const types = new Set(encoded.map(file => (file.envelope as { type: string }).type))
    assert.deepEqual([...types].sort(), [...COMMAND_TYPES].sort())
})

test('every command swift encodes passes validateCommand', () => {
    for (const file of encoded) {
        const result = validateCommand(file.envelope)
        assert.equal(result.ok, true, `${file.name}: ${result.ok ? '' : result.error}`)
    }
})

test('the empty-position open would have been rejected without explicit nulls', () => {
    const open = encoded.find(file => file.name === 'open-without-position.json')?.envelope as
        { payload: Record<string, unknown> } | undefined
    assert.ok(open, 'missing open-without-position.json')
    assert.equal(open.payload.position, null)
    const { position: _dropped, ...withoutKey } = open.payload
    assert.equal(validateCommand({ ...open, payload: withoutKey }).ok, false)
})
