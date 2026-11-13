// generated from web/src/bridge/annotations.ts by pnpm build; do not edit
// Annotation diffing for the reader bridge. Pure logic, no DOM.
//
// foliate keys overlay entries by CFI (`view.addAnnotation({ value: cfi })`),
// so a highlight and a marker at the same CFI must be merged into ONE overlay
// entry drawn with both styles. This module turns the desired `setAnnotations`
// payload plus the currently drawn state into a minimal plan
// `{ add, remove, update }`, and answers "which note IDs live at this CFI?" for
// `annotationActivated`.
// Markers pinned by quotes (`gloss link`) are placed by the CFI their words resolve to; the ones
// whose words can't be found in the book are left out (no marker beats a wrong one).
export const resolveMarkers = async (payload, resolveQuote) => {
    const markers = [];
    for (const marker of payload.markers) {
        if ('cfi' in marker)
            markers.push(marker);
        else {
            const cfi = await resolveQuote(marker.quote);
            if (cfi)
                markers.push({ id: marker.id, cfi });
        }
    }
    return { highlights: payload.highlights, markers };
};
// Build the complete desired entry list from a `setAnnotations` payload.
export const entriesFromPayload = (payload) => {
    const byCfi = new Map();
    const entryAt = (cfi) => {
        let entry = byCfi.get(cfi);
        if (!entry) {
            entry = { cfi, highlight: null, markerIDs: [] };
            byCfi.set(cfi, entry);
        }
        return entry;
    };
    for (const { cfi, id, color } of payload?.highlights ?? [])
        entryAt(cfi).highlight = { id, color };
    for (const { cfi, id } of payload?.markers ?? []) {
        const entry = entryAt(cfi);
        if (!entry.markerIDs.includes(id))
            entry.markerIDs.push(id);
    }
    return [...byCfi.values()];
};
const sameHighlight = (a, b) => a == null && b == null
    || (a != null && b != null && a.id === b.id && a.color === b.color);
const sameMarkers = (a, b) => a.length === b.length && a.every((id, i) => id === b[i]);
// Minimal plan to get from `currentEntries` (what is drawn) to the state
// described by `desiredPayload`. Entries in `add`/`update` are the full
// desired entries; entries in `remove` are the current entries to drop.
export const planAnnotations = (desiredPayload, currentEntries) => {
    const desired = entriesFromPayload(desiredPayload);
    const desiredCfis = new Set(desired.map(e => e.cfi));
    const current = new Map((currentEntries ?? []).map(e => [e.cfi, e]));
    const add = [];
    const update = [];
    const remove = [];
    for (const entry of desired) {
        const cur = current.get(entry.cfi);
        if (!cur)
            add.push(entry);
        else if (!sameHighlight(cur.highlight, entry.highlight)
            || !sameMarkers(cur.markerIDs, entry.markerIDs))
            update.push(entry);
    }
    for (const [cfi, entry] of current)
        if (!desiredCfis.has(cfi))
            remove.push(entry);
    return { add, remove, update };
};
// Which note IDs are drawn at `cfi`? Used for `annotationActivated`.
export const idsAt = (cfi, entries) => {
    const entry = entries?.find(e => e.cfi === cfi);
    return {
        highlightIDs: entry?.highlight ? [entry.highlight.id] : [],
        markerIDs: entry ? [...entry.markerIDs] : [],
    };
};
export const styleFor = (entry, colors) => {
    const highlights = colors?.highlights ?? {};
    const hasMarkers = (entry?.markerIDs?.length ?? 0) > 0;
    return {
        highlightColor: entry?.highlight
            ? highlights[entry.highlight.color] ?? null
            : null,
        underline: hasMarkers,
        underlineColor: hasMarkers ? colors?.marker ?? null : null,
    };
};
