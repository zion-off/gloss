// Build script for the reader bridge. Runs `tsc` (tsconfig.build.json) into a
// temp dir, stamps every emitted file with a "generated — do not edit"
// header, and then either copies the files over the committed output or, with
// `--check`, verifies the committed output is exactly what a fresh build
// produces.
//
//   node scripts/build.ts          compile into Sources/…/Resources/reader/
//   node scripts/build.ts --check  fail if the committed output is stale
//
// The compiled output is committed because SwiftPM copies resources verbatim;
// `check-build` guards against it going stale. Only `glue.js` and
// `bridge/*.js` are ever written — the vendored foliate/ tree and the static
// reader files are never touched.

import { spawnSync } from 'node:child_process'
import {
    existsSync,
    readFileSync,
    readdirSync,
    rmSync,
    writeFileSync,
} from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const webDir = dirname(dirname(fileURLToPath(import.meta.url)))
const readerDir = resolve(webDir, '..', 'Sources/GlossReaderEPUB/Resources/reader')
const check = process.argv.includes('--check')
const tempDir = join(webDir, '.check-build')

const walk = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true })
        .flatMap(entry => {
            const path = join(dir, entry.name)
            return entry.isDirectory() ? walk(path) : [path]
        })

// committed outputs the build owns (never the vendored foliate/*.js)
const isOwnedOutput = (rel: string): boolean =>
    rel === 'glue.js' || rel.startsWith('bridge/')

rmSync(tempDir, { recursive: true, force: true })

const tsc = join(webDir, 'node_modules', '.bin', 'tsc')
const compiled = spawnSync(tsc,
    ['-p', 'tsconfig.build.json', '--outDir', tempDir],
    { stdio: 'inherit', cwd: webDir })

if (compiled.status !== 0) {
    rmSync(tempDir, { recursive: true, force: true })
    process.exit(1)
}

const emitted = walk(tempDir).filter(file => file.endsWith('.js'))
const problems: string[] = []
for (const file of emitted) {
    const rel = relative(tempDir, file)              // e.g. bridge/protocol.js
    const sourceRel = rel.replace(/\.js$/, '.ts')   // e.g. bridge/protocol.ts
    const header = `// generated from web/src/${sourceRel} by pnpm build; do not edit\n`
    const content = header + readFileSync(file, 'utf8')
    const committed = join(readerDir, rel)
    if (check) {
        if (!existsSync(committed)) problems.push(`missing committed output: ${rel}`)
        else if (readFileSync(committed, 'utf8') !== content)
            problems.push(`committed output is stale: ${rel}`)
    } else {
        writeFileSync(committed, content)
    }
}

// the committed output must not contain owned files a fresh build cannot make
const emittedRels = emitted.map(file => relative(tempDir, file))
for (const rel of walk(readerDir)
    .filter(file => file.endsWith('.js'))
    .map(file => relative(readerDir, file))
    .filter(isOwnedOutput))
    if (!emittedRels.includes(rel))
        problems.push(`stale committed output (no source): ${rel}`)

rmSync(tempDir, { recursive: true, force: true })

if (problems.length) {
    for (const problem of problems) console.error(`check-build: ${problem}`)
    process.exit(1)
}
console.log(check
    ? `check-build: ${emitted.length} compiled files match the committed output`
    : `build: wrote ${emitted.length} files to ${relative(webDir, readerDir)}`)
