// generated from web/src/bridge/sanitize.ts by pnpm build; do not edit
// Strips script from book markup before foliate turns it into `blob:` documents.
//
// The reader page's CSP is meant to govern those documents too, but that inheritance can't be
// checked off a Mac, and a script that ran there could fetch other books from the scheme
// handler. So the glue removes what could run: script elements, event-handler attributes,
// `javascript:` URLs, `srcdoc`, meta refreshes and SVG animations that rewrite links. Styles,
// images, fonts and ordinary links are left alone. Pure: the caller passes the DOMParser and
// XMLSerializer (the page's in WebKit, jsdom's in tests).
// Every type WebKit could parse as a document: anything xml- or html-flavoured (review 4: an
// `application/xml` spine item or iframe target is parsed by the same machinery as XHTML and its
// scripts would run). Binary types (images, fonts, media) never match. EPUB-internal XML that
// foliate parses itself (container.xml, the OPF, NCX) never goes through the `data` event.
export const isMarkupType = (type) => typeof type === 'string' && /(?:xml|html|xsl)/i.test(type);
// What to hand the DOMParser. The three known document types keep their own parser MIME (jsdom
// and WebKit both special-case them); anything else xml-ish parses as generic XML, which
// round-trips through the serializer with namespaces intact.
const parserType = (type) => type === 'text/html' || type === 'application/xhtml+xml' || type === 'image/svg+xml'
    ? type
    : 'application/xml';
// Attributes that take a URL a script could hide in.
const URL_ATTRIBUTES = new Set(['href', 'src', 'action', 'formaction', 'data', 'poster', 'background']);
// Browsers ignore ASCII whitespace and control characters inside a scheme ("java\tscript:").
const scriptURL = (value) => /^(?:javascript|vbscript):/i.test(value.replace(/[\u0000-\u0020]/g, ''));
// `set`/`animate` that rewrite a link target, or anything that could write an event handler.
const isLinkAnimation = (element) => ['set', 'animate'].includes(element.localName)
    && /(?:^|:)(?:href|on[a-z]+)$/i.test(element.getAttribute('attributeName') ?? '');
const isRefresh = (element) => element.localName === 'meta'
    && (element.getAttribute('http-equiv') ?? '').trim().toLowerCase() === 'refresh';
const shouldRemove = (element) => element.localName === 'script' || element.localName === 'base'
    || isRefresh(element) || isLinkAnimation(element);
const cleanAttributes = (element) => {
    let removed = 0;
    for (const attribute of Array.from(element.attributes)) {
        const name = attribute.localName.toLowerCase();
        if (name.startsWith('on') || name === 'srcdoc'
            || (URL_ATTRIBUTES.has(name) && scriptURL(attribute.value))) {
            element.removeAttributeNode(attribute);
            removed++;
        }
    }
    return removed;
};
export const sanitizeMarkup = (markup, type, parser, serializer) => {
    let doc = parser.parseFromString(markup, parserType(type));
    // foliate falls back to HTML for broken XHTML; do the same, and never pass the broken
    // markup through (WebKit would render it up to the error, scripts included)
    const fellBack = type !== 'text/html' && doc.getElementsByTagName('parsererror').length > 0;
    if (fellBack)
        doc = parser.parseFromString(markup, 'text/html');
    // Template content is a separate tree the walker never reaches (review 4); walk it too.
    const allElements = (root) => {
        const found = Array.from(root.querySelectorAll('*'));
        for (const template of root.querySelectorAll('template'))
            found.push(...allElements(template.content));
        return found;
    };
    let removed = 0;
    // `<?xml-stylesheet?>` could pull a transform into the frame; a book has no business
    // styling its content that way (EPUB content uses <link>).
    for (const child of Array.from(doc.childNodes)) {
        if (child.nodeType === doc.PROCESSING_INSTRUCTION_NODE && /^xml-stylesheet$/i.test(child.nodeName)) {
            doc.removeChild(child);
            removed++;
        }
    }
    for (const element of allElements(doc)) {
        if (shouldRemove(element)) {
            element.remove();
            removed++;
        }
        else {
            removed += cleanAttributes(element);
        }
    }
    return { markup: removed > 0 || fellBack ? serializer.serializeToString(doc) : markup, removed };
};
