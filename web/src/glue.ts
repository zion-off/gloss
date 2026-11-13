// gloss reader glue — the only file that runs in the WKWebView and touches
// the DOM, `window.webkit` and the foliate `<foliate-view>` element. All
// message-shaped logic lives in the pure `bridge/` modules; this file wires
// them to the foliate View API (verified against the vendored source at the
// pinned commit; see foliate/VENDORED.md).
//
// Not testable under Node (needs WebKit); keep it small and readable.

import { makeBook } from 'foliate/view.js'
import { Overlayer } from 'foliate/overlayer.js'
import type {
    OverlayerDrawFunction,
} from 'foliate/overlayer.js'
import type {
    Book,
    Content,
    LoadResourceDetail,
    RelocateDetail,
    Renderer,
    ResolvedTarget,
    ResourceDataDetail,
    View,
} from 'foliate/view.js'
import * as protocol from './bridge/protocol.ts'
import * as annotations from './bridge/annotations.ts'
import * as selection from './bridge/selection.ts'
import * as progress from './bridge/progress.ts'
import * as appearance from './bridge/appearance.ts'
import * as toc from './bridge/toc.ts'
import * as search from './bridge/search.ts'
import * as sanitize from './bridge/sanitize.ts'

const view = document.querySelector('foliate-view') as View | null
if (!view) throw new Error('gloss: <foliate-view> element is missing')

const SVG_NS = 'http://www.w3.org/2000/svg'
const SELECTION_DEBOUNCE_MS = 150
const FLASH_MS = 1500

// -- state -----------------------------------------------------------------

let opened = false                          // a book is open and taking commands
let needsClose = false                      // view.open may have built a renderer
let bookGeneration = 0                      // bumped on close: late callbacks of a closed book bail
let searchGeneration = 0                    // bumped to stop a running search posting
let colors: protocol.AppearanceColors | null = null
let drawn: annotations.DrawnEntry[] = []   // annotations currently drawn
let hadSelection = false                    // suppress selectionCleared noise

// -- events ----------------------------------------------------------------

// foliate's custom events carry their payload in `detail`
const eventDetail = <T>(event: Event): T => (event as CustomEvent<T>).detail

const postEvent = <K extends protocol.EventType>(
    type: K,
    payload: protocol.EventPayloads[K],
): void => {
    const envelope = protocol.makeEvent(type, payload)
    const res = protocol.validateEvent(envelope)
    if (!res.ok) {
        console.error(res.error, envelope)
        return
    }
    const handler = window.webkit?.messageHandlers?.gloss
    // JSON text, so Swift decodes exactly what was validated here (no object bridging).
    if (handler) handler.postMessage(JSON.stringify(envelope))
    else console.log('gloss: no message handler, dropping event', envelope.type)
}

const postError = (error: unknown, context?: string): void =>
    postEvent('error', {
        message: error instanceof Error ? error.message : String(error),
        context: context ?? null,
    })

// Rect of a range in the current section, offset by the section iframe's own
// rect so the coordinates are relative to the web view viewport.
const viewportRect = (range: Range, index: number): protocol.Rect => {
    const contents: Content[] = view.renderer?.getContents?.() ?? []
    const content = contents.find(c => c.index === index)
    const frame = content?.doc.defaultView?.frameElement?.getBoundingClientRect()
    const r = range.getBoundingClientRect()
    return {
        x: r.x + (frame?.x ?? 0),
        y: r.y + (frame?.y ?? 0),
        width: r.width,
        height: r.height,
    }
}

// -- annotations -----------------------------------------------------------

// One overlay entry per CFI, drawn with both styles at once: a highlight fill
// plus a faint marker underline (see bridge/annotations.ts `styleFor`).
const makeDraw = (style: annotations.DrawStyle): OverlayerDrawFunction =>
    rects => {
        const g = document.createElementNS(SVG_NS, 'g')
        if (style.highlightColor)
            g.append(Overlayer.highlight(rects, { color: style.highlightColor }))
        if (style.underline && style.underlineColor)
            g.append(Overlayer.underline(rects, {
                color: style.underlineColor,
                width: 2,
            }))
        return g
    }

const entryAt = (cfi: string): annotations.DrawnEntry | undefined =>
    drawn.find(e => e.cfi === cfi)

const addAnnotation = async (cfi: string): Promise<number> => {
    // foliate removes the previous overlay for the same CFI itself
    // (`overlayer.remove(value)`), so re-adding redraws in place.
    const { index } = await view.addAnnotation({ value: cfi })
    return index
}

// `create-overlay` fires whenever a section (re)loads; foliate only re-adds
// its own search overlays, so the glue must re-add note overlays. The section
// index of every entry was recorded when it was added.
view.addEventListener('create-overlay', e => {
    const { index } = eventDetail<{ index: number }>(e)
    for (const entry of drawn)
        if (entry.index === index)
            view.addAnnotation({ value: entry.cfi })
                .catch((error: unknown) => postError(error, 'setAnnotations'))
})

view.addEventListener('draw-annotation', e => {
    const { draw, annotation } = eventDetail<{
        draw: (draw: OverlayerDrawFunction) => void
        annotation: { value: string }
    }>(e)
    draw(makeDraw(annotations.styleFor(entryAt(annotation.value), colors)))
})

view.addEventListener('show-annotation', e => {
    if (!opened) return
    const { value, range, index } = eventDetail<{
        value: string
        range: Range
        index: number
    }>(e)
    postEvent('annotationActivated', {
        ...annotations.idsAt(value, drawn),
        rect: viewportRect(range, index),
    })
})

// -- navigation ------------------------------------------------------------

view.addEventListener('relocate', e => {
    if (!opened) return
    postEvent('relocated', progress.makeRelocated(eventDetail<RelocateDetail>(e), view.renderer))
})

// External links: foliate would `window.open` them; we prevent that and hand
// them to Swift instead. Internal links are handled by foliate itself.
view.addEventListener('external-link', e => {
    e.preventDefault()
    if (!opened) return
    postEvent('linkActivated', {
        href: eventDetail<{ href_: string }>(e).href_,
        external: true,
    })
})

// Briefly outline a navigation target (goTo flash, revealSearchHit).
const flashTarget = async (resolved: ResolvedTarget | undefined): Promise<void> => {
    const contents: Content[] = view.renderer?.getContents?.() ?? []
    const content = contents.find(c => c.index === resolved?.index)
    if (!content?.overlayer || typeof resolved?.anchor !== 'function') return
    const anchor = resolved.anchor as (doc: Document) => Range | Element | number
    const anchored = anchor(content.doc)
    let range: Range | null = null
    if (anchored instanceof Range) range = anchored
    else if (anchored instanceof Element) {
        const r = content.doc.createRange()
        r.selectNodeContents(anchored)
        range = r
    }
    if (!range?.getClientRects) return
    const key = 'gloss-flash'
    content.overlayer.add(key, range, Overlayer.outline,
        { color: colors?.foreground ?? 'currentColor' })
    setTimeout(() => content.overlayer?.remove(key), FLASH_MS)
}

// -- selection --------------------------------------------------------------

const emitSelection = (doc: Document, index: number): void => {
    const sel = doc.getSelection()
    const collapsed = !sel || sel.rangeCount === 0 || sel.isCollapsed
    if (collapsed) {
        if (hadSelection) {
            hadSelection = false
            postEvent('selectionCleared', {})
        }
        return
    }
    const selRange = sel.getRangeAt(0)
    const payload = selection.makeSelectionPayload({
        cfi: view.getCFI(index, selRange),
        text: sel.toString(),
        label: view.getProgressOf(index, selRange)?.tocItem?.label,
        // best available book fraction for a selection: the fraction of the
        // page it is on (foliate has no per-range fraction API)
        fraction: view.lastLocation?.fraction ?? null,
        rect: selRange.getBoundingClientRect(),
        iframeOffset: doc.defaultView?.frameElement?.getBoundingClientRect(),
    })
    if (!payload) return
    hadSelection = true
    postEvent('selectionChanged', payload)
}

view.addEventListener('load', e => {
    const { doc, index } = eventDetail<{ doc: Document; index: number }>(e)
    // a debounced selection that settles after its book closed must not reach Swift
    const generation = bookGeneration
    const debounced = selection.makeDebouncer(() => {
        if (generation === bookGeneration && opened) emitSelection(doc, index)
    }, SELECTION_DEBOUNCE_MS)
    doc.addEventListener('selectionchange', debounced)
})

// -- keyboard ---------------------------------------------------------------

// goLeft/goRight already respect the book direction (`view.goRight()` is
// `prev` in RTL books), so the arrow keys always mean "visual left/right".
const turn = (forward: boolean): Promise<void> =>
    forward ? view.goRight() : view.goLeft()

const onKeyDown = (e: KeyboardEvent): void => {
    switch (e.key) {
        case 'ArrowRight': case 'PageDown': case ' ':
            e.preventDefault()
            void turn(true)
            break
        case 'ArrowLeft': case 'PageUp':
            e.preventDefault()
            void turn(false)
            break
    }
}

document.addEventListener('keydown', onKeyDown)
view.addEventListener('load', e => {
    const { doc } = eventDetail<{ doc: Document }>(e)
    doc.addEventListener('keydown', onKeyDown)
})

// -- appearance -------------------------------------------------------------

const applyAppearance = (payload: protocol.Appearance): void => {
    colors = payload.colors
    for (const op of appearance.appearanceOps(payload)) {
        if (op.op === 'attr') view.renderer?.setAttribute(op.name, op.value)
        else view.renderer?.setStyles?.(op.css)
    }
}

// -- book lifecycle ------------------------------------------------------------

// Closes the open book, if any. After this nothing about it reaches Swift: view-level
// listeners check `opened`, per-section ones check the generation they were made in.
const closeBook = (): void => {
    bookGeneration++
    searchGeneration++
    opened = false
    drawn = []
    hadSelection = false
    if (needsClose) {
        needsClose = false
        try {
            view.close()
        } catch (error) {
            postError(error, 'close')
        }
    }
}

// Defence in depth for the page CSP (see bridge/sanitize.ts): skip script resources and
// strip script from every document before foliate turns it into a blob: URL.
const guardScripts = (book: Book): void => {
    const target = book.transformTarget
    if (!target) return
    target.addEventListener('load', e => {
        const detail = eventDetail<LoadResourceDetail>(e)
        if (detail.isScript) detail.allow = false
    })
    target.addEventListener('data', e => {
        const detail = eventDetail<ResourceDataDetail>(e)
        const type = detail.type
        if (!sanitize.isMarkupType(type)) return
        detail.data = Promise.resolve(detail.data).then(async (data: unknown) => {
            const markup = typeof data === 'string' ? data
                : data instanceof Blob ? await data.text()
                : null
            if (markup === null) throw new Error(`unexpected ${type} data for ${detail.name}`)
            return sanitize.sanitizeMarkup(markup, type, new DOMParser(), new XMLSerializer()).markup
        })
    })
}

// -- command handlers ---------------------------------------------------------

const requireRenderer = (): Renderer => {
    // after `close`, foliate leaves `renderer` pointing at the destroyed element
    if (!opened || !view.renderer) throw new Error('no book is open')
    return view.renderer
}

const commands: { [K in protocol.CommandType]: (payload: protocol.CommandPayloads[K]) => Promise<void> } = {
    async open({ openID, url, position, appearance: appearancePayload }: protocol.OpenPayload) {
        // switching books happens in place: the previous one closes first
        closeBook()
        const res = await fetch(url)
        if (!res.ok)
            throw new Error(`fetch ${url} failed: ${res.status} ${res.statusText}`)
        const blob = await res.blob()
        const file = new File([blob], 'book.epub', { type: 'application/epub+zip' })
        const book = await makeBook(file)
        guardScripts(book)
        needsClose = true
        await view.open(book)
        opened = true
        applyAppearance(appearancePayload)
        postEvent('opened', {
            openID,
            toc: toc.normalizeToc(view.book.toc),
            sectionCount: view.book.sections.length,
            direction: view.book.dir === 'rtl' ? 'rtl' : 'ltr',
            fixedLayout: view.isFixedLayout,
        })
        await view.init({
            lastLocation: position ?? undefined,
            showTextStart: !position,
        })
    },

    async close() {
        closeBook()
    },

    async goTo({ target, flash }: protocol.GoToPayload) {
        requireRenderer()
        const targetValue: string | { fraction: number } =
            'cfi' in target ? target.cfi
            : 'href' in target ? target.href
            : { fraction: target.fraction }
        const resolved = await view.goTo(targetValue)
        if (flash) await flashTarget(resolved)
    },

    async turnPage({ direction }: protocol.TurnPagePayload) {
        requireRenderer()
        await (direction === 'forward' ? view.next() : view.prev())
    },

    async setAppearance({ appearance: appearancePayload }: protocol.SetAppearancePayload) {
        requireRenderer()
        applyAppearance(appearancePayload)
        // colours changed → redraw every drawn overlay with fresh draw
        // functions (the overlayer keeps the closures it was given)
        for (const entry of drawn)
            await addAnnotation(entry.cfi)
                .catch((error: unknown) => postError(error, 'setAppearance'))
    },

    async setAnnotations(payload: protocol.SetAnnotationsPayload) {
        requireRenderer()
        const plan = annotations.planAnnotations(payload, drawn)
        const indexByCfi = new Map(drawn.map(e => [e.cfi, e.index] as const))
        // update the drawn state *first*: the draw-annotation handlers fired
        // by re-adding below must see the new colours and marker sets
        drawn = annotations.entriesFromPayload(payload)
        for (const entry of drawn) entry.index = indexByCfi.get(entry.cfi)
        for (const entry of plan.remove) {
            try {
                await view.deleteAnnotation({ value: entry.cfi })
            } catch (error) {
                postError(error, 'setAnnotations')
            }
        }
        for (const entry of [...plan.update, ...plan.add]) {
            try {
                entry.index = await addAnnotation(entry.cfi)
                const state = drawn.find(e => e.cfi === entry.cfi)
                if (state) state.index = entry.index
            } catch (error) {
                postError(error, 'setAnnotations')
            }
        }
    },

    async clearSelection() {
        requireRenderer()
        view.deselect()
    },

    // Starts the search and returns: results stream as events, and commands queued behind
    // it (navigation, the next search) must not wait for the whole book to be searched.
    async search({ query }: protocol.SearchPayload) {
        requireRenderer()
        const generation = ++searchGeneration
        const mapper = search.makeSearchMapper(query)
        void (async () => {
            try {
                for await (const result of view.search({ query })) {
                    if (generation !== searchGeneration) return
                    const payload = mapper.map(result)
                    if (payload) postEvent('searchResults', payload)
                }
            } catch (error) {
                if (generation === searchGeneration) postError(error, 'search')
            }
        })()
    },

    async clearSearch() {
        requireRenderer()
        searchGeneration++
        view.clearSearch()
    },

    async revealSearchHit({ cfi, section, text }: protocol.RevealSearchHitPayload) {
        requireRenderer()
        if (cfi != null) {
            await flashTarget(await view.goTo(cfi))
            return
        }
        if (section == null)
            throw new Error('revealSearchHit needs a cfi or a section')
        // search within the spine section; foliate outlines every match like
        // its search results do, we go to the first one and flash it
        for await (const result of view.search({ query: text, index: section })) {
            if (protocol.isRecord(result) && typeof result.cfi === 'string') {
                await flashTarget(await view.goTo(result.cfi))
                return
            }
        }
    },
}

// -- bridge surface ------------------------------------------------------------

let commandQueue: Promise<void> = Promise.resolve()

window.glossReader = {
    // Called by Swift via callAsyncJavaScript. Invalid commands reject with
    // an Error whose message starts with "bridge:"; runtime failures become
    // `error` events. Returns null (commands reply through events).
    // Commands run one at a time, in the order they arrive, so an `open` that is still
    // fetching never interleaves with the commands sent after it.
    async receive(envelope: unknown): Promise<null> {
        const res = protocol.validateCommand(envelope)
        if (!res.ok) throw new Error(res.error)
        const { type, payload } =
            envelope as { type: protocol.CommandType; payload: unknown }
        // the payload was just validated against `type`'s spec
        const run = commandQueue
            .then(() => (commands[type] as (payload: unknown) => Promise<void>)(payload))
            .catch((error: unknown) => postError(error, type))
        commandQueue = run
        await run
        return null
    },
}

postEvent('ready', {})
