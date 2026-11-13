// Strips script from book markup before foliate turns it into `blob:` documents.
//
// The reader page's CSP is meant to govern those documents too, but that inheritance can't be
// checked off a Mac, and a script that ran there could fetch other books from the scheme
// handler. So the glue removes what could run: script elements, event-handler attributes,
// `javascript:` URLs, `srcdoc`, meta refreshes and SVG animations that rewrite links. Styles,
// images, fonts and ordinary links are left alone. Pure: the caller passes the DOMParser and
// XMLSerializer (the page's in WebKit, jsdom's in tests).

const MARKUP_TYPES = Object.freeze([
    'application/xhtml+xml',
    'text/html',
    'image/svg+xml',
] as const)
type MarkupType = typeof MARKUP_TYPES[number]

export const isMarkupType = (type: unknown): type is MarkupType =>
    typeof type === 'string' && (MARKUP_TYPES as readonly string[]).includes(type)

// Attributes that take a URL a script could hide in.
const URL_ATTRIBUTES = new Set(['href', 'src', 'action', 'formaction', 'data', 'poster', 'background'])

// Browsers ignore ASCII whitespace and control characters inside a scheme ("java\tscript:").
const scriptURL = (value: string): boolean =>
    /^(?:javascript|vbscript):/i.test(value.replace(/[\u0000-\u0020]/g, ''))

const isLinkAnimation = (element: Element): boolean =>
    ['set', 'animate'].includes(element.localName)
    && /(^|:)href$/i.test(element.getAttribute('attributeName') ?? '')

const isRefresh = (element: Element): boolean =>
    element.localName === 'meta'
    && (element.getAttribute('http-equiv') ?? '').trim().toLowerCase() === 'refresh'

const shouldRemove = (element: Element): boolean =>
    element.localName === 'script' || element.localName === 'base'
    || isRefresh(element) || isLinkAnimation(element)

const cleanAttributes = (element: Element): number => {
    let removed = 0
    for (const attribute of Array.from(element.attributes)) {
        const name = attribute.localName.toLowerCase()
        if (name.startsWith('on') || name === 'srcdoc'
            || (URL_ATTRIBUTES.has(name) && scriptURL(attribute.value))) {
            element.removeAttributeNode(attribute)
            removed++
        }
    }
    return removed
}

export interface SanitizeResult {
    markup: string
    // how many elements and attributes were taken out
    removed: number
}

export const sanitizeMarkup = (
    markup: string,
    type: MarkupType,
    parser: DOMParser,
    serializer: XMLSerializer,
): SanitizeResult => {
    let doc = parser.parseFromString(markup, type)
    // foliate falls back to HTML for broken XHTML; do the same, and never pass the broken
    // markup through (WebKit would render it up to the error, scripts included)
    const fellBack = type !== 'text/html' && doc.getElementsByTagName('parsererror').length > 0
    if (fellBack) doc = parser.parseFromString(markup, 'text/html')
    let removed = 0
    for (const element of Array.from(doc.getElementsByTagName('*'))) {
        if (!element.isConnected) continue
        if (shouldRemove(element)) {
            element.remove()
            removed++
        } else {
            removed += cleanAttributes(element)
        }
    }
    return { markup: removed > 0 || fellBack ? serializer.serializeToString(doc) : markup, removed }
}
