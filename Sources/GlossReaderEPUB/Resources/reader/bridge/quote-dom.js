// generated from web/src/bridge/quote-dom.ts by pnpm build; do not edit
// The DOM half of quote resolution (`gloss link` quote markers, D-190): the words of a section's
// parsed document, and the Range an anchor's words cover in it. The pure matching is in
// ./quote.ts; this only walks a Document it is given (no globals), so jsdom can run it.
import { resolveInNodes } from './quote.js';
import { shouldRemove } from './sanitize.js';
const TEXT_NODE = 3;
const CDATA_SECTION_NODE = 4;
const ELEMENT_NODE = 1;
// svg and math text isn't in gloss's extracted text either (HTMLText skips them)
const SKIPPED = new Set(['script', 'style', 'svg', 'math']);
// Text nodes the way foliate's search walks them (text-walker.js): everything in the body but
// script and style.
export const textNodes = (doc) => {
    const nodes = [];
    const walk = (parent) => {
        for (const child of Array.from(parent.childNodes)) {
            if (child.nodeType === TEXT_NODE || child.nodeType === CDATA_SECTION_NODE)
                nodes.push(child);
            else if (child.nodeType === ELEMENT_NODE && !SKIPPED.has(child.localName.toLowerCase()))
                walk(child);
        }
    };
    const root = doc.body ?? doc.documentElement;
    if (root)
        walk(root);
    return nodes;
};
// Gives a document the shape of the rendered one (the elements the sanitizer strips, so the
// range's CFI matches what is shown), then finds the anchor's words: the Range they cover, or
// null when they aren't there. Changes `doc`.
export const quoteRange = (doc, anchor) => {
    for (const element of Array.from(doc.querySelectorAll('*')))
        if (shouldRemove(element))
            element.remove();
    const nodes = textNodes(doc);
    const found = resolveInNodes(nodes.map(node => node.nodeValue ?? ''), anchor);
    if (!found)
        return null;
    const range = doc.createRange();
    range.setStart(nodes[found.start.node], found.start.offset);
    range.setEnd(nodes[found.end.node], found.end.offset);
    return range;
};
