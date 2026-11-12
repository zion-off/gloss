// Shared helpers for the bridge tests.

import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const moduleDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(moduleDir, '..', '..')

export interface FixtureFile {
    name: string
    envelope: unknown
}

export const readJsonFiles = (dir: string): FixtureFile[] =>
    readdirSync(dir)
        .filter(name => name.endsWith('.json'))
        .sort()
        .map(name => ({
            name,
            envelope: JSON.parse(readFileSync(join(dir, name), 'utf8')) as unknown,
        }))

export const fixturesDir = (...parts: string[]): string =>
    join(repoRoot, 'Tests/Fixtures/bridge', ...parts)

export const fixtureNamed = (files: FixtureFile[], name: string): unknown => {
    const file = files.find(f => f.name === name)
    if (!file) throw new Error(`missing fixture ${name}`)
    return file.envelope
}
