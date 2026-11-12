// generated from web/src/bridge/search.ts by pnpm build; do not edit
// Search batch mapping for the reader bridge. Pure logic, no DOM.
// (Bridge-level; deliberately does not clash with foliate's own `search.js`.)
//
// `view.search({ query })` is an async generator that yields, in order:
//
// - `{ progress }` — once per section of the book, as the search advances;
// - `{ label, subitems: [{ cfi, excerpt }] }` — per section that has matches
//   (`label` is the TOC label, `''` when unknown; `excerpt` is foliate's
//   `{ pre, match, post }`);
// - `{ cfi, excerpt }` — per match for a single-section search
//   (`view.search({ query, index })`);
// - `'done'` — a plain string, at the very end.
//
// `makeSearchMapper(query)` folds one search run into `searchResults` payloads:
// progress-only batches keep Swift's progress UI live, match batches carry the
// items, and the final batch has `done: true` (with `progress: 1`).
import { isRecord } from './protocol.js';
export const makeSearchMapper = (query) => {
    let progress = 0;
    const mapItem = (item, label) => ({
        cfi: item.cfi,
        label: label || null,
        excerpt: {
            pre: item.excerpt.pre,
            match: item.excerpt.match,
            post: item.excerpt.post,
        },
    });
    return {
        map(result) {
            if (result === 'done')
                return { query, items: [], progress: 1, done: true };
            if (!isRecord(result))
                return null;
            if (Array.isArray(result.subitems)) {
                const subitems = result.subitems;
                const label = typeof result.label === 'string' ? result.label : '';
                return {
                    query,
                    items: subitems.map(item => mapItem(item, label)),
                    progress,
                    done: false,
                };
            }
            if (typeof result.progress === 'number') {
                progress = result.progress;
                return { query, items: [], progress, done: false };
            }
            if (typeof result.cfi === 'string' && isRecord(result.excerpt)) {
                return {
                    query,
                    items: [mapItem({
                            cfi: result.cfi,
                            excerpt: result.excerpt,
                        })],
                    progress,
                    done: false,
                };
            }
            return null;
        },
    };
};
