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
import * as queue from './bridge/queue.ts'
import * as swipe from './bridge/swipe.ts'
import * as quote from './bridge/quote.ts'

const view = document.querySelector('foliate-view') as View | null
if (!view) throw new Error('gloss: <foliate-view> element is missing')

const SVG_NS = 'http://www.w3.org/2000/svg'
const SELECTION_DEBOUNCE_MS = 150
const FLASH_MS = 1500

// -- state -----------------------------------------------------------------

let opened = false                          // a book is open and taking commands
let needsClose = false                      // view.open may have built a renderer
const bookGeneration = queue.makeGeneration()   // late callbacks of a closed book bail
const searchGeneration = queue.makeGeneration() // stopped searches stop posting
let colors: protocol.AppearanceColors | null = null
let drawn: annotations.DrawnEntry[] = []   // annotations currently drawn
let hadSelection = false                    // suppress selectionCleared noise
let quoteCfis = new Map<string, string | null>() // quote targets resolved in the open book

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

const postError = (error: unknown, context?: string, openID: number | null = null): void =>
    postEvent('error', {
        message: error instanceof Error ? error.message : String(error),
        context: context ?? null,
        openID,
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
    const generation = bookGeneration.value()
    const debounced = selection.makeDebouncer(() => {
        if (bookGeneration.isCurrent(generation) && opened) emitSelection(doc, index)
    }, SELECTION_DEBOUNCE_MS)
    doc.addEventListener('selectionchange', debounced)
})

// -- keyboard ---------------------------------------------------------------

// goLeft/goRight already respect the book direction (`view.goRight()` is
// `prev` in RTL books), so the arrow keys always mean "visual left/right".
const turn = (forward: boolean): Promise<void> =>
    forward ? view.goRight() : view.goLeft()

// Down/up mean the reading order (next/previous), whatever the book's direction.
const turnInOrder = (forward: boolean): Promise<void> =>
    forward ? view.next() : view.prev()

const onKeyDown = (e: KeyboardEvent): void => {
    if (e.metaKey || e.ctrlKey || e.altKey) return
    const paginated = !view.renderer?.scrolled
    switch (e.key) {
        case 'ArrowRight':
            e.preventDefault()
            void turn(true)
            break
        case 'ArrowLeft':
            e.preventDefault()
            void turn(false)
            break
        case 'PageDown':
            e.preventDefault()
            void turnInOrder(true)
            break
        case 'PageUp':
            e.preventDefault()
            void turnInOrder(false)
            break
        case ' ':
            e.preventDefault()
            void turnInOrder(!e.shiftKey)
            break
        case 'ArrowDown': case 'ArrowUp':
            // scrolled flow keeps the native line scroll
            if (!paginated) break
            e.preventDefault()
            void turnInOrder(e.key === 'ArrowDown')
            break
    }
}

document.addEventListener('keydown', onKeyDown)
view.addEventListener('load', e => {
    const { doc } = eventDetail<{ doc: Document }>(e)
    doc.addEventListener('keydown', onKeyDown)
    doc.addEventListener('wheel', onWheel, { passive: false })
})

// -- trackpad and wheel -------------------------------------------------------

// In paginated flow Swift takes every trackpad and wheel event before WebKit sees it
// (`ReaderWebView.scrollWheel`) and calls `glossReader.swipe` with its phase, so the page can
// follow the fingers and settle on lift like Books, and the momentum after a lift (never
// forwarded) can't turn another page. Scrolled flow scrolls natively.

const SNAP_MS = 300                 // foliate's snap and page-turn animation
const SETTLE_TIMEOUT_MS = 1500      // a section load after a snap rarely takes longer
const WHEEL_NOTCH_INTERVAL_MS = 250 // a fast wheel spin turns pages at about the animation's pace
let swipes = swipe.makeSwipeTracker()
let draggable = false               // decided when a gesture begins
let settling = false                // a snap is animating or loading the next section
let settleUntil = 0
let lastNotch = -Infinity
const pendingSwipes: (() => void)[] = []
let flushScheduled = false

// The page can follow the fingers: a reflowable book, paginated, past its first relocate (before
// that foliate's `scrollBy` has no bounds to clamp to).
const canDrag = (): boolean => {
    const r = view.renderer
    return typeof r?.scrollBy === 'function' && typeof r.snap === 'function'
        && !r.scrolled && !view.isFixedLayout && view.lastLocation != null
}

// After a snap: settled once its animation is over and foliate isn't resting on a section's
// blank edge page (it loads the neighbouring section from there). A gesture that starts before
// then waits, so its deltas aren't overwritten by the animation or clamped to the page the snap
// left.
const isSettled = (): boolean => {
    if (!settling) return true
    const now = performance.now()
    if (now < settleUntil) return false
    const r = view.renderer
    const onEdge = r?.page !== undefined && r.pages !== undefined
        && (r.page <= 0 || r.page >= r.pages - 1)
    if (onEdge && now <= settleUntil + SETTLE_TIMEOUT_MS) return false
    settling = false
    return true
}

const flushSwipes = (): void => {
    flushScheduled = false
    while (pendingSwipes.length > 0 && isSettled()) pendingSwipes.shift()?.()
    if (pendingSwipes.length > 0) {
        flushScheduled = true
        requestAnimationFrame(flushSwipes)
    }
}

const applySwipe = (action: swipe.SwipeAction): void => {
    const r = view.renderer
    switch (action.kind) {
        case 'drag':
            r?.scrollBy?.(action.delta, action.delta)
            break
        case 'settle':
            r?.snap?.(action.velocity, action.velocity)
            settling = true
            settleUntil = performance.now() + (r?.hasAttribute('animated') ? SNAP_MS : 0)
            break
        case 'turn':
            void (action.axis === 'x' ? turn(action.forward) : turnInOrder(action.forward))
            break
    }
}

const handleSwipe = (phase: swipe.SwipePhase | 'wheel', dx: number, dy: number, time: number): void => {
    if (!opened) return
    if (phase === 'wheel') {
        // a mouse wheel: each notch turns a page, at most one per interval
        if (time - lastNotch < WHEEL_NOTCH_INTERVAL_MS || (dx === 0 && dy === 0)) return
        lastNotch = time
        void (Math.abs(dx) > Math.abs(dy) ? turn(dx > 0) : turnInOrder(dy > 0))
        return
    }
    if (phase === 'begin') draggable = canDrag()
    try {
        for (const action of swipes.feed(phase, dx, dy, time, draggable)) applySwipe(action)
    } catch (error) {
        console.warn('gloss: swipe failed', error)
    }
}

const SWIPE_PHASES: readonly unknown[] = ['begin', 'change', 'end', 'cancel', 'wheel']

const receiveSwipe = (phase: unknown, dx: unknown, dy: unknown, time: unknown): void => {
    if (!SWIPE_PHASES.includes(phase) || typeof dx !== 'number' || typeof dy !== 'number'
        || typeof time !== 'number') return
    pendingSwipes.push(() => handleSwipe(phase as swipe.SwipePhase | 'wheel', dx, dy, time))
    if (!flushScheduled) flushSwipes()
}

const resetSwipes = (): void => {
    swipes = swipe.makeSwipeTracker()
    pendingSwipes.length = 0
    settling = false
}

// Wheel events reach the page in scrolled flow (native scrolling; ignored here) and when Swift's
// idea of the flow differs from the renderer's (a fixed-layout book ignores the flow setting).
// There a gesture is the run of events with no 200 ms gap and turns one page, so a trackpad's
// momentum tail never turns a second one.
const WHEEL_TURN_DISTANCE = 40
const WHEEL_GESTURE_GAP_MS = 200
let wheelDistance = 0
let wheelLastStamp = 0
let wheelTurned = false

const onWheel = (e: WheelEvent): void => {
    if (!opened || view.renderer?.scrolled) return
    e.preventDefault()
    if (e.timeStamp - wheelLastStamp > WHEEL_GESTURE_GAP_MS) {
        wheelDistance = 0
        wheelTurned = false
    }
    wheelLastStamp = e.timeStamp
    if (wheelTurned) return
    const horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY)
    wheelDistance += horizontal ? e.deltaX : e.deltaY
    if (Math.abs(wheelDistance) >= WHEEL_TURN_DISTANCE) {
        wheelTurned = true
        void (horizontal ? turn(wheelDistance > 0) : turnInOrder(wheelDistance > 0))
    }
}
document.addEventListener('wheel', onWheel, { passive: false })

// -- appearance -------------------------------------------------------------

// Page turns and snaps slide (foliate's `animated` attribute, 300 ms ease-out), unless the user
// asked for reduced motion: then they cut, like Books.
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)')
const applyMotion = (): void => {
    view.renderer?.toggleAttribute('animated', !reducedMotion.matches)
}
reducedMotion.addEventListener('change', applyMotion)

// The reader page itself takes the theme's colours (reader.css, D-144): foliate's margins and
// column gap show the page through, so it must match the section documents' background.
const applyPageColors = (pageColors: protocol.AppearanceColors): void => {
    const root = document.documentElement.style
    root.setProperty('--gloss-background', pageColors.background)
    root.setProperty('--gloss-foreground', pageColors.foreground)
    root.colorScheme = appearance.colorSchemeFor(pageColors.background)
}

const applyAppearance = (payload: protocol.Appearance): void => {
    colors = payload.colors
    applyPageColors(payload.colors)
    for (const op of appearance.appearanceOps(payload)) {
        if (op.op === 'attr') view.renderer?.setAttribute(op.name, op.value)
        else view.renderer?.setStyles?.(op.css)
    }
    applyMotion()
}

// -- book lifecycle ------------------------------------------------------------

// Closes the open book, if any. After this nothing about it reaches Swift: view-level
// listeners check `opened`, per-section ones check the generation they were made in.
const closeBook = (): void => {
    bookGeneration.bump()
    searchGeneration.bump()
    opened = false
    drawn = []
    hadSelection = false
    quoteCfis = new Map()
    resetSwipes()
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

// -- quotes ----------------------------------------------------------------------

// Text nodes the way foliate's search walks them (text-walker.js): everything in the body but
// script and style.
const textNodes = (doc: Document): Text[] => {
    const root = doc.body ?? doc.documentElement
    const nodes: Text[] = []
    if (!root) return nodes
    const walker = doc.createTreeWalker(root,
        NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION, {
            acceptNode: node => {
                if (node.nodeType !== Node.ELEMENT_NODE) return NodeFilter.FILTER_ACCEPT
                const name = (node as Element).localName.toLowerCase()
                // svg and math text isn't in gloss's extracted text either (HTMLText skips them)
                return name === 'script' || name === 'style' || name === 'svg' || name === 'math'
                    ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP
            },
        })
    for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node as Text)
    return nodes
}

// The CFI of a passage pinned by its words (an `epub-quote` locator from `gloss link`, D-190):
// find the words in the section's document (context first, then the occurrence; bridge/quote.ts)
// and take the range's CFI, the way foliate's own search does. The document is given the shape
// of the rendered one first (the elements the sanitizer strips), so the CFI matches what is shown.
// Null when the words aren't there; remembered for as long as the book is open.
const resolveQuote = async (target: protocol.QuoteTarget): Promise<string | null> => {
    const key = JSON.stringify([target.section, target.text, target.prefix, target.suffix, target.occurrence])
    const known = quoteCfis.get(key)
    if (known !== undefined) return known
    const generation = bookGeneration.value()
    let cfi: string | null = null
    let failed = false
    try {
        const section = view.book.sections[target.section]
        let doc = await section?.createDocument?.()
        // Broken XHTML: foliate renders it as HTML (and so does the sanitizer), so parse it that
        // way too, or the CFI's path would point into WebKit's error document.
        if (doc && section && (doc.getElementsByTagName('parsererror').length > 0 || !doc.body)) {
            const markup = await view.book.loadText?.(section.id)
            if (typeof markup === 'string') doc = new DOMParser().parseFromString(markup, 'text/html')
        }
        if (doc) {
            for (const element of Array.from(doc.querySelectorAll('*')))
                if (sanitize.shouldRemove(element)) element.remove()
            const nodes = textNodes(doc)
            const found = quote.resolveInNodes(nodes.map(node => node.nodeValue ?? ''), target)
            if (found) {
                const range = doc.createRange()
                range.setStart(nodes[found.start.node], found.start.offset)
                range.setEnd(nodes[found.end.node], found.end.offset)
                cfi = view.getCFI(target.section, range)
            }
        }
    } catch (error) {
        failed = true
        console.warn('gloss: a quote did not resolve', error)
    }
    // a failure may be passing (a section still loading); only settled answers are remembered
    if (!failed && bookGeneration.isCurrent(generation)) quoteCfis.set(key, cfi)
    return cfi
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
        // the page turns the theme's colour now, not after the book has loaded
        applyPageColors(appearancePayload.colors)
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
        if ('quote' in target) {
            // words that can't be found still land in their section, unflashed
            const cfi = await resolveQuote(target.quote)
            const resolved = await view.goTo(cfi ?? target.quote.section)
            if (flash && cfi) await flashTarget(resolved)
            return
        }
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

    async setAnnotations(desired: protocol.SetAnnotationsPayload) {
        requireRenderer()
        const generation = bookGeneration.value()
        const payload = await annotations.resolveMarkers(desired, resolveQuote)
        if (!bookGeneration.isCurrent(generation)) return
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
        const generation = searchGeneration.bump()
        const mapper = search.makeSearchMapper(query)
        void (async () => {
            try {
                for await (const result of view.search({ query })) {
                    if (!searchGeneration.isCurrent(generation)) return
                    const payload = mapper.map(result)
                    if (payload) postEvent('searchResults', payload)
                }
            } catch (error) {
                if (searchGeneration.isCurrent(generation)) postError(error, 'search')
            }
        })()
    },

    async clearSearch() {
        requireRenderer()
        searchGeneration.bump()
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
        // Search within the spine section, off the command queue (review 4): a whole
        // section scan must not hold back the commands sent after it. Foliate outlines every
        // match like its search results do; we go to the first one and flash it.
        const generation = searchGeneration.bump()
        void (async () => {
            try {
                for await (const result of view.search({ query: text, index: section })) {
                    if (!searchGeneration.isCurrent(generation)) return
                    if (protocol.isRecord(result) && typeof result.cfi === 'string') {
                        await flashTarget(await view.goTo(result.cfi))
                        return
                    }
                }
            } catch (error) {
                if (searchGeneration.isCurrent(generation)) postError(error, 'revealSearchHit')
            }
        })()
    },
}

// -- bridge surface ------------------------------------------------------------

const commandQueue = queue.makeSerialQueue()

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
        await commandQueue
            .run(() => (commands[type] as (payload: unknown) => Promise<void>)(payload))
            .catch((error: unknown) => postError(
                error, type, type === 'open' ? (payload as protocol.OpenPayload).openID : null))
        return null
    },
    // Called by Swift via evaluateJavaScript for every trackpad or wheel event of a paginated
    // book, in order and off the command queue (a drag can't wait behind a search).
    swipe: receiveSwipe,
}

postEvent('ready', {})
