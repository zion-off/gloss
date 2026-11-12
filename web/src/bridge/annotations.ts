// Annotation diffing for the reader bridge. Pure logic, no DOM.
//
// foliate keys overlay entries by CFI (`view.addAnnotation({ value: cfi })`),
// so a highlight and a marker at the same CFI must be merged into ONE overlay
// entry drawn with both styles. This module turns the desired `setAnnotations`
// payload plus the currently drawn state into a minimal plan
// `{ add, remove, update }`, and answers "which note IDs live at this CFI?" for
// `annotationActivated`.

import type { HighlightColorName, SetAnnotationsPayload } from './protocol.ts'

/** the `setAnnotations` payload, with both arrays optional for internal calls */
export type AnnotationsPayloadInput = Partial<SetAnnotationsPayload>

export interface Highlight {
    id: string
    color: HighlightColorName
}

// An entry is one overlay per CFI, in first-seen payload order (deterministic;
// the diff never depends on it). `index` is glue bookkeeping (the section the
// entry was added to); it never affects diffing.
export interface DrawnEntry {
    cfi: string
    highlight: Highlight | null
    markerIDs: string[]
    index?: number
}

export interface AnnotationPlan {
    add: DrawnEntry[]
    remove: DrawnEntry[]
    update: DrawnEntry[]
}

// Build the complete desired entry list from a `setAnnotations` payload.
export const entriesFromPayload = (payload?: AnnotationsPayloadInput): DrawnEntry[] => {
    const byCfi = new Map<string, DrawnEntry>()
    const entryAt = (cfi: string): DrawnEntry => {
        let entry = byCfi.get(cfi)
        if (!entry) {
            entry = { cfi, highlight: null, markerIDs: [] }
            byCfi.set(cfi, entry)
        }
        return entry
    }
    for (const { cfi, id, color } of payload?.highlights ?? [])
        entryAt(cfi).highlight = { id, color }
    for (const { cfi, id } of payload?.markers ?? []) {
        const entry = entryAt(cfi)
        if (!entry.markerIDs.includes(id)) entry.markerIDs.push(id)
    }
    return [...byCfi.values()]
}

const sameHighlight = (a: Highlight | null, b: Highlight | null): boolean =>
    a == null && b == null
    || (a != null && b != null && a.id === b.id && a.color === b.color)

const sameMarkers = (a: string[], b: string[]): boolean =>
    a.length === b.length && a.every((id, i) => id === b[i])

// Minimal plan to get from `currentEntries` (what is drawn) to the state
// described by `desiredPayload`. Entries in `add`/`update` are the full
// desired entries; entries in `remove` are the current entries to drop.
export const planAnnotations = (
    desiredPayload: SetAnnotationsPayload,
    currentEntries?: DrawnEntry[],
): AnnotationPlan => {
    const desired = entriesFromPayload(desiredPayload)
    const desiredCfis = new Set(desired.map(e => e.cfi))
    const current = new Map((currentEntries ?? []).map(e => [e.cfi, e]))
    const add: DrawnEntry[] = []
    const update: DrawnEntry[] = []
    const remove: DrawnEntry[] = []
    for (const entry of desired) {
        const cur = current.get(entry.cfi)
        if (!cur) add.push(entry)
        else if (!sameHighlight(cur.highlight, entry.highlight)
            || !sameMarkers(cur.markerIDs, entry.markerIDs)) update.push(entry)
    }
    for (const [cfi, entry] of current)
        if (!desiredCfis.has(cfi)) remove.push(entry)
    return { add, remove, update }
}

// Which note IDs are drawn at `cfi`? Used for `annotationActivated`.
export const idsAt = (
    cfi: string,
    entries?: DrawnEntry[],
): { highlightIDs: string[]; markerIDs: string[] } => {
    const entry = entries?.find(e => e.cfi === cfi)
    return {
        highlightIDs: entry?.highlight ? [entry.highlight.id] : [],
        markerIDs: entry ? [...entry.markerIDs] : [],
    }
}

export interface StyleColors {
    marker?: string
    highlights?: Partial<Record<HighlightColorName, string>>
}

// How to draw an entry: highlight colour (null = no highlight), whether to
// draw a marker underline, and its colour. `colors` is the Appearance
// `colors` object (`{ marker, highlights: { yellow, … } }`).
export interface DrawStyle {
    highlightColor: string | null
    underline: boolean
    underlineColor: string | null
}

export const styleFor = (
    entry: DrawnEntry | null | undefined,
    colors: StyleColors | null | undefined,
): DrawStyle => {
    const highlights = colors?.highlights ?? {}
    const hasMarkers = (entry?.markerIDs?.length ?? 0) > 0
    return {
        highlightColor: entry?.highlight
            ? highlights[entry.highlight.color] ?? null
            : null,
        underline: hasMarkers,
        underlineColor: hasMarkers ? colors?.marker ?? null : null,
    }
}
