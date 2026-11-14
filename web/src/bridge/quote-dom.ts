// The DOM half of quote resolution (`gloss link` quote markers, D-190): the words of a section's
// parsed document, and the Range an anchor's words cover in it. The pure matching is in
// ./quote.ts; this only walks a Document it is given (no globals), so jsdom can run it.

import type { QuoteAnchor } from './quote.ts'
import { resolveInNodes } from './quote.ts'
import { shouldRemove } from './sanitize.ts'

const TEXT_NODE = 3
const CDATA_SECTION_NODE = 4
const ELEMENT_NODE = 1
// svg and math text isn't in gloss's extracted text either (HTMLText skips them)
const SKIPPED = new Set(['script', 'style', 'svg', 'math'])

// Text nodes the way foliate's search walks them (text-walker.js): everything in the body but
// script and style.
export const textNodes = (doc: Document): Text[] => {
    const nodes: Text[] = []
    const walk = (parent: Node): void => {
        for (const child of Array.from(parent.childNodes)) {
            if (child.nodeType === TEXT_NODE || child.nodeType === CDATA_SECTION_NODE) nodes.push(child as Text)
            else if (child.nodeType === ELEMENT_NODE && !SKIPPED.has((child as Element).localName.toLowerCase())) walk(child)
        }
    }
    const root = doc.body ?? doc.documentElement
    if (root) walk(root)
    return nodes
}

// A section's document given the shape of the rendered one (the elements the sanitizer strips,
// so a range's CFI matches what is shown) with its text nodes found once, to resolve any number
// of quotes in it. Changes `doc`.
export interface SectionText {
    doc: Document
    nodes: Text[]
    texts: string[]
}

export const sectionText = (doc: Document): SectionText => {
    for (const element of Array.from(doc.querySelectorAll('*')))
        if (shouldRemove(element)) element.remove()
    const nodes = textNodes(doc)
    return { doc, nodes, texts: nodes.map(node => node.nodeValue ?? '') }
}

// The Range the anchor's words cover in the section, or null when they aren't there.
export const quoteRange = (section: SectionText, anchor: QuoteAnchor): Range | null => {
    const found = resolveInNodes(section.texts, anchor)
    if (!found) return null
    const range = section.doc.createRange()
    range.setStart(section.nodes[found.start.node], found.start.offset)
    range.setEnd(section.nodes[found.end.node], found.end.offset)
    return range
}
