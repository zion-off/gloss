// generated from web/src/bridge/quote.ts by pnpm build; do not edit
// Finding a passage pinned by its words (`gloss link`, an `epub-quote` locator) in the
// text of a section. The twin of Swift's `FoldedText` and `QuoteAnchor.resolve`
// (Sources/GlossCore/Quotes/): both run the shared cases in Tests/Fixtures/quotes/resolve.json,
// so the reader lands on the words the CLI chose. Change one, change the other.
// Pure logic only: no DOM.
const IGNORABLE = new Set([0x00ad, 0x200b, 0x200c, 0x200d, 0x2060, 0xfeff]);
const SINGLE_QUOTES = new Set([0x2018, 0x2019, 0x201a, 0x201b, 0x2032, 0x02bc]);
const DOUBLE_QUOTES = new Set([0x201c, 0x201d, 0x201e, 0x201f, 0x2033]);
const DASHES = new Set([0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212]);
const WHITE_SPACE = /^\p{White_Space}$/u;
const isWhiteSpace = (cp) => WHITE_SPACE.test(String.fromCodePoint(cp));
export const foldScalar = (cp, ignoreCase) => {
    if (cp < 0x80)
        return [ignoreCase && cp >= 0x41 && cp <= 0x5a ? cp + 0x20 : cp];
    if (IGNORABLE.has(cp))
        return [];
    if (SINGLE_QUOTES.has(cp))
        return [0x27];
    if (DOUBLE_QUOTES.has(cp))
        return [0x22];
    if (DASHES.has(cp))
        return [0x2d];
    let folded = String.fromCodePoint(cp).normalize('NFKD');
    if (ignoreCase)
        folded = folded.toLowerCase();
    const units = [];
    for (const ch of folded) {
        if (WHITE_SPACE.test(ch))
            continue;
        for (let i = 0; i < ch.length; i++)
            units.push(ch.charCodeAt(i));
    }
    return units;
};
// Whitespace-insensitive folding (Swift's `.stripped`).
export const fold = (text, ignoreCase = false) => {
    const units = [];
    const starts = [];
    const ends = [];
    const cache = new Map();
    for (let offset = 0; offset < text.length;) {
        const cp = text.codePointAt(offset) ?? 0;
        const width = cp > 0xffff ? 2 : 1;
        if (!isWhiteSpace(cp)) {
            let folded = cache.get(cp);
            if (!folded) {
                folded = foldScalar(cp, ignoreCase);
                cache.set(cp, folded);
            }
            for (const unit of folded) {
                units.push(unit);
                starts.push(offset);
                ends.push(offset + width);
            }
        }
        offset += width;
    }
    return { units, starts, ends };
};
export const occurrences = (units, needle, from = 0, to = units.length) => {
    const found = [];
    if (needle.length === 0 || needle.length > to - from)
        return found;
    for (let i = from; i <= to - needle.length; i++) {
        let matched = true;
        for (let k = 0; k < needle.length; k++)
            if (units[i + k] !== needle[k]) {
                matched = false;
                break;
            }
        if (matched)
            found.push(i);
    }
    return found;
};
const commonSuffix = (context, units, end) => {
    let count = 0;
    while (count < context.length && end - count - 1 >= 0
        && context[context.length - 1 - count] === units[end - count - 1])
        count++;
    return count;
};
const commonPrefix = (context, units, start) => {
    let count = 0;
    while (count < context.length && start + count < units.length
        && context[count] === units[start + count])
        count++;
    return count;
};
const sourceRange = (folded, start, end) => [folded.starts[start], folded.ends[end - 1]];
// Most agreeing context, then the stored occurrence, then the one nearest to it.
const pick = (anchor, starts, length, text, ignoreCase) => {
    if (starts.length === 0)
        return null;
    if (starts.length === 1)
        return starts[0];
    const before = fold(anchor.prefix, ignoreCase).units;
    const after = fold(anchor.suffix, ignoreCase).units;
    const scores = starts.map(start => commonSuffix(before, text.units, start) + commonPrefix(after, text.units, start + length));
    let top = 0;
    for (const score of scores)
        if (score > top)
            top = score;
    let chosen = -1;
    for (let i = 0; i < starts.length; i++) {
        if (scores[i] !== top)
            continue;
        if (chosen < 0 || Math.abs(i - anchor.occurrence) < Math.abs(chosen - anchor.occurrence))
            chosen = i;
    }
    return starts[chosen];
};
const END_LENGTH = 16;
// The quote's first and last characters, when its middle differs from the book's text.
const resolveByEnds = (anchor, text, quote) => {
    if (quote.length <= 2 * END_LENGTH)
        return null;
    const head = quote.slice(0, END_LENGTH);
    const tail = quote.slice(quote.length - END_LENGTH);
    const before = fold(anchor.prefix).units;
    const after = fold(anchor.suffix).units;
    let best = null;
    for (const start of occurrences(text.units, head)) {
        const windowEnd = Math.min(text.units.length, start + quote.length * 2 + 64);
        if (start + END_LENGTH > windowEnd)
            continue;
        const tailStart = occurrences(text.units, tail, start + END_LENGTH, windowEnd)[0];
        if (tailStart === undefined)
            continue;
        const score = commonSuffix(before, text.units, start)
            + commonPrefix(after, text.units, tailStart + END_LENGTH);
        if (!best || score > best.score)
            best = { start, end: tailStart + END_LENGTH, score };
    }
    if (!best || !(best.score > 0 || (before.length === 0 && after.length === 0)))
        return null;
    return sourceRange(text, best.start, best.end);
};
// Where the anchored words are in `source`, as a UTF-16 [start, end); null when not found.
export const resolve = (source, anchor) => {
    const quote = fold(anchor.text).units;
    if (quote.length === 0)
        return null;
    for (const ignoreCase of [false, true]) {
        const text = fold(source, ignoreCase);
        const needle = ignoreCase ? fold(anchor.text, true).units : quote;
        const best = pick(anchor, occurrences(text.units, needle), needle.length, text, ignoreCase);
        if (best !== null)
            return sourceRange(text, best, best + needle.length);
    }
    return resolveByEnds(anchor, fold(source), quote);
};
// The same, over a section's text nodes in document order: where the range starts and ends.
export const resolveInNodes = (texts, anchor) => {
    const found = resolve(texts.join(''), anchor);
    if (!found)
        return null;
    const [start, end] = found;
    let startPoint = null;
    let endPoint = null;
    let base = 0;
    for (let node = 0; node < texts.length; node++) {
        const length = texts[node].length;
        if (!startPoint && start < base + length)
            startPoint = { node, offset: start - base };
        if (!endPoint && end <= base + length && end > base)
            endPoint = { node, offset: end - base };
        base += length;
    }
    return startPoint && endPoint ? { start: startPoint, end: endPoint } : null;
};
