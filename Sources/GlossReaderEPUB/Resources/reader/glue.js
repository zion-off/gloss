// generated from web/src/glue.ts by pnpm build; do not edit
// gloss reader glue — the only file that runs in the WKWebView and touches
// the DOM, `window.webkit` and the foliate `<foliate-view>` element. All
// message-shaped logic lives in the pure `bridge/` modules; this file wires
// them to the foliate View API (verified against the vendored source at the
// pinned commit; see foliate/VENDORED.md).
//
// Not testable under Node (needs WebKit); keep it small and readable.
import { makeBook } from 'foliate/view.js';
import { Overlayer } from 'foliate/overlayer.js';
import * as protocol from './bridge/protocol.js';
import * as annotations from './bridge/annotations.js';
import * as selection from './bridge/selection.js';
import * as progress from './bridge/progress.js';
import * as appearance from './bridge/appearance.js';
import * as toc from './bridge/toc.js';
import * as search from './bridge/search.js';
import * as sanitize from './bridge/sanitize.js';
import * as queue from './bridge/queue.js';
import * as swipe from './bridge/swipe.js';
import * as quoteDOM from './bridge/quote-dom.js';
const view = document.querySelector('foliate-view');
if (!view)
    throw new Error('gloss: <foliate-view> element is missing');
const SVG_NS = 'http://www.w3.org/2000/svg';
const SELECTION_DEBOUNCE_MS = 150;
const FLASH_MS = 1500;
// -- state -----------------------------------------------------------------
let opened = false; // a book is open and taking commands
let needsClose = false; // view.open may have built a renderer
const bookGeneration = queue.makeGeneration(); // late callbacks of a closed book bail
const searchGeneration = queue.makeGeneration(); // stopped searches stop posting
const annotationRequests = queue.makeGeneration(); // a newer setAnnotations supersedes quote lookups
let colors = null;
let drawn = []; // annotations currently drawn
let hadSelection = false; // suppress selectionCleared noise
let quoteCfis = new Map(); // quote targets resolved in the open book
// -- events ----------------------------------------------------------------
// foliate's custom events carry their payload in `detail`
const eventDetail = (event) => event.detail;
const postEvent = (type, payload) => {
    const envelope = protocol.makeEvent(type, payload);
    const res = protocol.validateEvent(envelope);
    if (!res.ok) {
        console.error(res.error, envelope);
        return;
    }
    const handler = window.webkit?.messageHandlers?.gloss;
    // JSON text, so Swift decodes exactly what was validated here (no object bridging).
    if (handler)
        handler.postMessage(JSON.stringify(envelope));
    else
        console.log('gloss: no message handler, dropping event', envelope.type);
};
const postError = (error, context, openID = null) => postEvent('error', {
    message: error instanceof Error ? error.message : String(error),
    context: context ?? null,
    openID,
});
// Rect of a range in the current section, offset by the section iframe's own
// rect so the coordinates are relative to the web view viewport.
const viewportRect = (range, index) => {
    const contents = view.renderer?.getContents?.() ?? [];
    const content = contents.find(c => c.index === index);
    const frame = content?.doc.defaultView?.frameElement?.getBoundingClientRect();
    const r = range.getBoundingClientRect();
    return {
        x: r.x + (frame?.x ?? 0),
        y: r.y + (frame?.y ?? 0),
        width: r.width,
        height: r.height,
    };
};
// -- annotations -----------------------------------------------------------
// One overlay entry per CFI, drawn with both styles at once: a highlight fill
// plus a faint marker underline (see bridge/annotations.ts `styleFor`).
const makeDraw = (style) => rects => {
    const g = document.createElementNS(SVG_NS, 'g');
    if (style.highlightColor)
        g.append(Overlayer.highlight(rects, { color: style.highlightColor }));
    if (style.underline && style.underlineColor)
        g.append(Overlayer.underline(rects, {
            color: style.underlineColor,
            width: 2,
        }));
    return g;
};
const entryAt = (cfi) => drawn.find(e => e.cfi === cfi);
const addAnnotation = async (cfi) => {
    // foliate removes the previous overlay for the same CFI itself
    // (`overlayer.remove(value)`), so re-adding redraws in place.
    const { index } = await view.addAnnotation({ value: cfi });
    return index;
};
// `create-overlay` fires whenever a section (re)loads; foliate only re-adds
// its own search overlays, so the glue must re-add note overlays. The section
// index of every entry was recorded when it was added.
view.addEventListener('create-overlay', e => {
    const { index } = eventDetail(e);
    for (const entry of drawn)
        if (entry.index === index)
            view.addAnnotation({ value: entry.cfi })
                .catch((error) => postError(error, 'setAnnotations'));
});
view.addEventListener('draw-annotation', e => {
    const { draw, annotation } = eventDetail(e);
    draw(makeDraw(annotations.styleFor(entryAt(annotation.value), colors)));
});
view.addEventListener('show-annotation', e => {
    if (!opened)
        return;
    const { value, range, index } = eventDetail(e);
    postEvent('annotationActivated', {
        ...annotations.idsAt(value, drawn),
        rect: viewportRect(range, index),
    });
});
// -- navigation ------------------------------------------------------------
view.addEventListener('relocate', e => {
    if (!opened)
        return;
    postEvent('relocated', progress.makeRelocated(eventDetail(e), view.renderer));
});
// External links: foliate would `window.open` them; we prevent that and hand
// them to Swift instead. Internal links are handled by foliate itself.
view.addEventListener('external-link', e => {
    e.preventDefault();
    if (!opened)
        return;
    postEvent('linkActivated', {
        href: eventDetail(e).href_,
        external: true,
    });
});
// Briefly outline a navigation target (goTo flash, revealSearchHit).
const flashTarget = async (resolved) => {
    const contents = view.renderer?.getContents?.() ?? [];
    const content = contents.find(c => c.index === resolved?.index);
    if (!content?.overlayer || typeof resolved?.anchor !== 'function')
        return;
    const anchor = resolved.anchor;
    const anchored = anchor(content.doc);
    let range = null;
    if (anchored instanceof Range)
        range = anchored;
    else if (anchored instanceof Element) {
        const r = content.doc.createRange();
        r.selectNodeContents(anchored);
        range = r;
    }
    if (!range?.getClientRects)
        return;
    const key = 'gloss-flash';
    content.overlayer.add(key, range, Overlayer.outline, { color: colors?.foreground ?? 'currentColor' });
    setTimeout(() => content.overlayer?.remove(key), FLASH_MS);
};
// -- selection --------------------------------------------------------------
const emitSelection = (doc, index) => {
    const sel = doc.getSelection();
    const collapsed = !sel || sel.rangeCount === 0 || sel.isCollapsed;
    if (collapsed) {
        if (hadSelection) {
            hadSelection = false;
            postEvent('selectionCleared', {});
        }
        return;
    }
    const selRange = sel.getRangeAt(0);
    const payload = selection.makeSelectionPayload({
        cfi: view.getCFI(index, selRange),
        text: sel.toString(),
        label: view.getProgressOf(index, selRange)?.tocItem?.label,
        // best available book fraction for a selection: the fraction of the
        // page it is on (foliate has no per-range fraction API)
        fraction: view.lastLocation?.fraction ?? null,
        rect: selRange.getBoundingClientRect(),
        iframeOffset: doc.defaultView?.frameElement?.getBoundingClientRect(),
    });
    if (!payload)
        return;
    hadSelection = true;
    postEvent('selectionChanged', payload);
};
view.addEventListener('load', e => {
    const { doc, index } = eventDetail(e);
    // a debounced selection that settles after its book closed must not reach Swift
    const generation = bookGeneration.value();
    const debounced = selection.makeDebouncer(() => {
        if (bookGeneration.isCurrent(generation) && opened)
            emitSelection(doc, index);
    }, SELECTION_DEBOUNCE_MS);
    doc.addEventListener('selectionchange', debounced);
});
// -- keyboard ---------------------------------------------------------------
// goLeft/goRight already respect the book direction (`view.goRight()` is
// `prev` in RTL books), so the arrow keys always mean "visual left/right".
const turn = (forward) => forward ? view.goRight() : view.goLeft();
// Down/up mean the reading order (next/previous), whatever the book's direction.
const turnInOrder = (forward) => forward ? view.next() : view.prev();
const onKeyDown = (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey)
        return;
    const paginated = !view.renderer?.scrolled;
    switch (e.key) {
        case 'ArrowRight':
            e.preventDefault();
            void turn(true);
            break;
        case 'ArrowLeft':
            e.preventDefault();
            void turn(false);
            break;
        case 'PageDown':
            e.preventDefault();
            void turnInOrder(true);
            break;
        case 'PageUp':
            e.preventDefault();
            void turnInOrder(false);
            break;
        case ' ':
            e.preventDefault();
            void turnInOrder(!e.shiftKey);
            break;
        case 'ArrowDown':
        case 'ArrowUp':
            // scrolled flow keeps the native line scroll
            if (!paginated)
                break;
            e.preventDefault();
            void turnInOrder(e.key === 'ArrowDown');
            break;
    }
};
document.addEventListener('keydown', onKeyDown);
view.addEventListener('load', e => {
    const { doc } = eventDetail(e);
    doc.addEventListener('keydown', onKeyDown);
    doc.addEventListener('wheel', onWheel, { passive: false });
});
// -- trackpad and wheel -------------------------------------------------------
// In paginated flow Swift takes every trackpad and wheel event before WebKit sees it
// (`ReaderWebView.scrollWheel`) and calls `glossReader.swipe` with its phase, so the page can
// follow the fingers and settle on lift like Books, and the momentum after a lift (never
// forwarded) can't turn another page. Scrolled flow scrolls natively.
const SNAP_MS = 300; // foliate's snap and page-turn animation
const SETTLE_TIMEOUT_MS = 1500; // a section load after a snap rarely takes longer
const WHEEL_NOTCH_INTERVAL_MS = 250; // a fast wheel spin turns pages at about the animation's pace
let swipes = swipe.makeSwipeTracker();
let draggable = false; // decided when a gesture begins
let settling = false; // a snap is animating or loading the next section
let settleUntil = 0;
let lastNotch = -Infinity;
const pendingSwipes = [];
let flushScheduled = false;
// The page can follow the fingers: a reflowable book, paginated, past its first relocate (before
// that foliate's `scrollBy` has no bounds to clamp to).
const canDrag = () => {
    const r = view.renderer;
    return typeof r?.scrollBy === 'function' && typeof r.snap === 'function'
        && !r.scrolled && !view.isFixedLayout && view.lastLocation != null;
};
// After a snap: settled once its animation is over and foliate isn't resting on a section's
// blank edge page (it loads the neighbouring section from there). A gesture that starts before
// then waits, so its deltas aren't overwritten by the animation or clamped to the page the snap
// left.
const isSettled = () => {
    if (!settling)
        return true;
    const now = performance.now();
    if (now < settleUntil)
        return false;
    const r = view.renderer;
    const onEdge = r?.page !== undefined && r.pages !== undefined
        && (r.page <= 0 || r.page >= r.pages - 1);
    if (onEdge && now <= settleUntil + SETTLE_TIMEOUT_MS)
        return false;
    settling = false;
    return true;
};
const flushSwipes = () => {
    flushScheduled = false;
    while (pendingSwipes.length > 0 && isSettled())
        pendingSwipes.shift()?.();
    if (pendingSwipes.length > 0) {
        flushScheduled = true;
        requestAnimationFrame(flushSwipes);
    }
};
const applySwipe = (action) => {
    const r = view.renderer;
    switch (action.kind) {
        case 'drag':
            r?.scrollBy?.(action.delta, action.delta);
            break;
        case 'settle':
            r?.snap?.(action.velocity, action.velocity);
            settling = true;
            settleUntil = performance.now() + (r?.hasAttribute('animated') ? SNAP_MS : 0);
            break;
        case 'turn':
            void (action.axis === 'x' ? turn(action.forward) : turnInOrder(action.forward));
            break;
    }
};
const handleSwipe = (phase, dx, dy, time) => {
    if (!opened)
        return;
    if (phase === 'wheel') {
        // a mouse wheel: each notch turns a page, at most one per interval
        if (time - lastNotch < WHEEL_NOTCH_INTERVAL_MS || (dx === 0 && dy === 0))
            return;
        lastNotch = time;
        void (Math.abs(dx) > Math.abs(dy) ? turn(dx > 0) : turnInOrder(dy > 0));
        return;
    }
    if (phase === 'begin')
        draggable = canDrag();
    try {
        for (const action of swipes.feed(phase, dx, dy, time, draggable))
            applySwipe(action);
    }
    catch (error) {
        console.warn('gloss: swipe failed', error);
    }
};
const SWIPE_PHASES = ['begin', 'change', 'end', 'cancel', 'wheel'];
const receiveSwipe = (phase, dx, dy, time) => {
    if (!SWIPE_PHASES.includes(phase) || typeof dx !== 'number' || typeof dy !== 'number'
        || typeof time !== 'number')
        return;
    pendingSwipes.push(() => handleSwipe(phase, dx, dy, time));
    if (!flushScheduled)
        flushSwipes();
};
const resetSwipes = () => {
    swipes = swipe.makeSwipeTracker();
    pendingSwipes.length = 0;
    settling = false;
};
// Wheel events reach the page in scrolled flow (native scrolling; ignored here) and when Swift's
// idea of the flow differs from the renderer's (a fixed-layout book ignores the flow setting).
// There a gesture is the run of events with no 200 ms gap and turns one page, so a trackpad's
// momentum tail never turns a second one.
const WHEEL_TURN_DISTANCE = 40;
const WHEEL_GESTURE_GAP_MS = 200;
let wheelDistance = 0;
let wheelLastStamp = 0;
let wheelTurned = false;
const onWheel = (e) => {
    if (!opened || view.renderer?.scrolled)
        return;
    e.preventDefault();
    if (e.timeStamp - wheelLastStamp > WHEEL_GESTURE_GAP_MS) {
        wheelDistance = 0;
        wheelTurned = false;
    }
    wheelLastStamp = e.timeStamp;
    if (wheelTurned)
        return;
    const horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY);
    wheelDistance += horizontal ? e.deltaX : e.deltaY;
    if (Math.abs(wheelDistance) >= WHEEL_TURN_DISTANCE) {
        wheelTurned = true;
        void (horizontal ? turn(wheelDistance > 0) : turnInOrder(wheelDistance > 0));
    }
};
document.addEventListener('wheel', onWheel, { passive: false });
// -- appearance -------------------------------------------------------------
// Page turns and snaps slide (foliate's `animated` attribute, 300 ms ease-out), unless the user
// asked for reduced motion: then they cut, like Books.
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const applyMotion = () => {
    view.renderer?.toggleAttribute('animated', !reducedMotion.matches);
};
reducedMotion.addEventListener('change', applyMotion);
// The reader page itself takes the theme's colours (reader.css, D-144): foliate's margins and
// column gap show the page through, so it must match the section documents' background.
const applyPageColors = (pageColors) => {
    const root = document.documentElement.style;
    root.setProperty('--gloss-background', pageColors.background);
    root.setProperty('--gloss-foreground', pageColors.foreground);
    root.colorScheme = appearance.colorSchemeFor(pageColors.background);
};
const applyAppearance = (payload) => {
    colors = payload.colors;
    applyPageColors(payload.colors);
    for (const op of appearance.appearanceOps(payload)) {
        if (op.op === 'attr')
            view.renderer?.setAttribute(op.name, op.value);
        else
            view.renderer?.setStyles?.(op.css);
    }
    applyMotion();
};
// -- book lifecycle ------------------------------------------------------------
// Closes the open book, if any. After this nothing about it reaches Swift: view-level
// listeners check `opened`, per-section ones check the generation they were made in.
const closeBook = () => {
    bookGeneration.bump();
    searchGeneration.bump();
    annotationRequests.bump();
    opened = false;
    drawn = [];
    hadSelection = false;
    quoteCfis = new Map();
    resetSwipes();
    if (needsClose) {
        needsClose = false;
        try {
            view.close();
        }
        catch (error) {
            postError(error, 'close');
        }
    }
};
// Defence in depth for the page CSP (see bridge/sanitize.ts): skip script resources and
// strip script from every document before foliate turns it into a blob: URL.
const guardScripts = (book) => {
    const target = book.transformTarget;
    if (!target)
        return;
    target.addEventListener('load', e => {
        const detail = eventDetail(e);
        if (detail.isScript)
            detail.allow = false;
    });
    target.addEventListener('data', e => {
        const detail = eventDetail(e);
        const type = detail.type;
        if (!sanitize.isMarkupType(type))
            return;
        detail.data = Promise.resolve(detail.data).then(async (data) => {
            const markup = typeof data === 'string' ? data
                : data instanceof Blob ? await data.text()
                    : null;
            if (markup === null)
                throw new Error(`unexpected ${type} data for ${detail.name}`);
            return sanitize.sanitizeMarkup(markup, type, new DOMParser(), new XMLSerializer()).markup;
        });
    });
};
// -- quotes ----------------------------------------------------------------------
const quoteKey = (target) => JSON.stringify([target.section, target.text, target.prefix, target.suffix, target.occurrence]);
// A section's document the way foliate renders it, for finding quotes.
const sectionDocument = async (index) => {
    const section = view.book.sections[index];
    let doc = await section?.createDocument?.();
    // Broken XHTML: foliate renders it as HTML (and so does the sanitizer), so parse it that
    // way too, or the CFI's path would point into WebKit's error document.
    if (doc && section && (doc.getElementsByTagName('parsererror').length > 0 || !doc.body)) {
        const markup = await view.book.loadText?.(section.id);
        if (typeof markup === 'string')
            doc = new DOMParser().parseFromString(markup, 'text/html');
    }
    return doc ?? null;
};
// The CFIs of passages pinned by their words (`epub-quote` locators from `gloss link`, D-190),
// all in one section: the section is parsed once, each quote's words are found in it (context
// first, then the occurrence; bridge/quote.ts, bridge/quote-dom.ts) and the range's CFI is taken
// the way foliate's own search does. Null for words that aren't there; answers are remembered for
// as long as the book is open.
const resolveQuotes = async (index, targets) => {
    const generation = bookGeneration.value();
    const cfis = targets.map(target => quoteCfis.get(quoteKey(target)));
    if (cfis.every(cfi => cfi !== undefined))
        return cfis;
    let prepared = null;
    try {
        const doc = await sectionDocument(index);
        if (doc)
            prepared = quoteDOM.sectionText(doc);
    }
    catch (error) {
        // a failure may be passing (a section still loading), so nothing is remembered
        console.warn('gloss: a section did not load for its quotes', error);
        return targets.map(target => quoteCfis.get(quoteKey(target)) ?? null);
    }
    return targets.map((target, i) => {
        const known = cfis[i];
        if (known !== undefined)
            return known;
        let cfi = null;
        try {
            const range = prepared ? quoteDOM.quoteRange(prepared, target) : null;
            if (range)
                cfi = view.getCFI(index, range);
        }
        catch (error) {
            console.warn('gloss: a quote did not resolve', error);
            return null;
        }
        if (bookGeneration.isCurrent(generation))
            quoteCfis.set(quoteKey(target), cfi);
        return cfi;
    });
};
const resolveQuote = async (target) => (await resolveQuotes(target.section, [target]))[0] ?? null;
// What is already known, without parsing anything.
const knownQuotes = async (_index, targets) => targets.map(target => quoteCfis.get(quoteKey(target)) ?? null);
// Makes the drawn annotations match a payload with every marker placed by a CFI. Draws run one
// at a time (a background quote lookup and a newer command may both have something to draw), and
// one made stale by a newer request or a closed book draws nothing.
const drawQueue = queue.makeSerialQueue();
const drawAnnotations = (payload, generation, request) => drawQueue.run(async () => {
    if (!bookGeneration.isCurrent(generation) || !annotationRequests.isCurrent(request))
        return;
    const plan = annotations.planAnnotations(payload, drawn);
    const indexByCfi = new Map(drawn.map(e => [e.cfi, e.index]));
    // update the drawn state *first*: the draw-annotation handlers fired
    // by re-adding below must see the new colours and marker sets
    drawn = annotations.entriesFromPayload(payload);
    for (const entry of drawn)
        entry.index = indexByCfi.get(entry.cfi);
    for (const entry of plan.remove) {
        try {
            await view.deleteAnnotation({ value: entry.cfi });
        }
        catch (error) {
            postError(error, 'setAnnotations');
        }
    }
    for (const entry of [...plan.update, ...plan.add]) {
        try {
            entry.index = await addAnnotation(entry.cfi);
            const state = drawn.find(e => e.cfi === entry.cfi);
            if (state)
                state.index = entry.index;
        }
        catch (error) {
            postError(error, 'setAnnotations');
        }
    }
});
// -- command handlers ---------------------------------------------------------
const requireRenderer = () => {
    // after `close`, foliate leaves `renderer` pointing at the destroyed element
    if (!opened || !view.renderer)
        throw new Error('no book is open');
    return view.renderer;
};
const commands = {
    async open({ openID, url, position, appearance: appearancePayload }) {
        // switching books happens in place: the previous one closes first
        closeBook();
        // the page turns the theme's colour now, not after the book has loaded
        applyPageColors(appearancePayload.colors);
        const res = await fetch(url);
        if (!res.ok)
            throw new Error(`fetch ${url} failed: ${res.status} ${res.statusText}`);
        const blob = await res.blob();
        const file = new File([blob], 'book.epub', { type: 'application/epub+zip' });
        const book = await makeBook(file);
        guardScripts(book);
        needsClose = true;
        await view.open(book);
        opened = true;
        applyAppearance(appearancePayload);
        postEvent('opened', {
            openID,
            toc: toc.normalizeToc(view.book.toc),
            sectionCount: view.book.sections.length,
            direction: view.book.dir === 'rtl' ? 'rtl' : 'ltr',
            fixedLayout: view.isFixedLayout,
        });
        await view.init({
            lastLocation: position ?? undefined,
            showTextStart: !position,
        });
    },
    async close() {
        closeBook();
    },
    async goTo({ target, flash }) {
        requireRenderer();
        if ('quote' in target) {
            // words that can't be found still land in their section, unflashed
            const cfi = await resolveQuote(target.quote);
            const resolved = await view.goTo(cfi ?? target.quote.section);
            if (flash && cfi)
                await flashTarget(resolved);
            return;
        }
        const targetValue = 'cfi' in target ? target.cfi
            : 'href' in target ? target.href
                : { fraction: target.fraction };
        const resolved = await view.goTo(targetValue);
        if (flash)
            await flashTarget(resolved);
    },
    async turnPage({ direction }) {
        requireRenderer();
        await (direction === 'forward' ? view.next() : view.prev());
    },
    async setAppearance({ appearance: appearancePayload }) {
        requireRenderer();
        applyAppearance(appearancePayload);
        // colours changed → redraw every drawn overlay with fresh draw
        // functions (the overlayer keeps the closures it was given)
        for (const entry of drawn)
            await addAnnotation(entry.cfi)
                .catch((error) => postError(error, 'setAppearance'));
    },
    // Highlights and CFI markers are drawn at once; markers pinned by quotes (`gloss link`) need
    // their sections parsed, which must not hold back the commands behind this one: they are
    // looked up in the background, a section at a time, and drawn when found. A newer
    // `setAnnotations`, a `close` or an `open` supersedes a lookup still running.
    async setAnnotations(desired) {
        requireRenderer();
        const generation = bookGeneration.value();
        const request = annotationRequests.bump();
        await drawAnnotations(await annotations.resolveMarkers(desired, knownQuotes), generation, request);
        const pending = desired.markers.some(m => 'quote' in m && !quoteCfis.has(quoteKey(m.quote)));
        if (!pending)
            return;
        void (async () => {
            try {
                const payload = await annotations.resolveMarkers(desired, resolveQuotes);
                await drawAnnotations(payload, generation, request);
            }
            catch (error) {
                if (bookGeneration.isCurrent(generation))
                    postError(error, 'setAnnotations');
            }
        })();
    },
    async clearSelection() {
        requireRenderer();
        view.deselect();
    },
    // Starts the search and returns: results stream as events, and commands queued behind
    // it (navigation, the next search) must not wait for the whole book to be searched.
    async search({ query }) {
        requireRenderer();
        const generation = searchGeneration.bump();
        const mapper = search.makeSearchMapper(query);
        void (async () => {
            try {
                for await (const result of view.search({ query })) {
                    if (!searchGeneration.isCurrent(generation))
                        return;
                    const payload = mapper.map(result);
                    if (payload)
                        postEvent('searchResults', payload);
                }
            }
            catch (error) {
                if (searchGeneration.isCurrent(generation))
                    postError(error, 'search');
            }
        })();
    },
    async clearSearch() {
        requireRenderer();
        searchGeneration.bump();
        view.clearSearch();
    },
    async revealSearchHit({ cfi, section, text }) {
        requireRenderer();
        if (cfi != null) {
            await flashTarget(await view.goTo(cfi));
            return;
        }
        if (section == null)
            throw new Error('revealSearchHit needs a cfi or a section');
        // Search within the spine section, off the command queue (review 4): a whole
        // section scan must not hold back the commands sent after it. Foliate outlines every
        // match like its search results do; we go to the first one and flash it.
        const generation = searchGeneration.bump();
        void (async () => {
            try {
                for await (const result of view.search({ query: text, index: section })) {
                    if (!searchGeneration.isCurrent(generation))
                        return;
                    if (protocol.isRecord(result) && typeof result.cfi === 'string') {
                        await flashTarget(await view.goTo(result.cfi));
                        return;
                    }
                }
            }
            catch (error) {
                if (searchGeneration.isCurrent(generation))
                    postError(error, 'revealSearchHit');
            }
        })();
    },
};
// -- bridge surface ------------------------------------------------------------
const commandQueue = queue.makeSerialQueue();
window.glossReader = {
    // Called by Swift via callAsyncJavaScript. Invalid commands reject with
    // an Error whose message starts with "bridge:"; runtime failures become
    // `error` events. Returns null (commands reply through events).
    // Commands run one at a time, in the order they arrive, so an `open` that is still
    // fetching never interleaves with the commands sent after it.
    async receive(envelope) {
        const res = protocol.validateCommand(envelope);
        if (!res.ok)
            throw new Error(res.error);
        const { type, payload } = envelope;
        // the payload was just validated against `type`'s spec
        await commandQueue
            .run(() => commands[type](payload))
            .catch((error) => postError(error, type, type === 'open' ? payload.openID : null));
        return null;
    },
    // Called by Swift via evaluateJavaScript for every trackpad or wheel event of a paginated
    // book, in order and off the command queue (a drag can't wait behind a search).
    swipe: receiveSwipe,
};
postEvent('ready', {});
