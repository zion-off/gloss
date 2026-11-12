// generated from web/src/glue.ts by pnpm build; do not edit
// gloss reader glue — the only file that runs in the WKWebView and touches
// the DOM, `window.webkit` and the foliate `<foliate-view>` element. All
// message-shaped logic lives in the pure `bridge/` modules; this file wires
// them to the foliate View API (verified against the vendored source at the
// pinned commit; see foliate/VENDORED.md).
//
// Not testable under Node (needs WebKit); keep it small and readable.
import 'foliate/view.js';
import { Overlayer } from 'foliate/overlayer.js';
import * as protocol from './bridge/protocol.js';
import * as annotations from './bridge/annotations.js';
import * as selection from './bridge/selection.js';
import * as progress from './bridge/progress.js';
import * as appearance from './bridge/appearance.js';
import * as toc from './bridge/toc.js';
import * as search from './bridge/search.js';
const view = document.querySelector('foliate-view');
if (!view)
    throw new Error('gloss: <foliate-view> element is missing');
const SVG_NS = 'http://www.w3.org/2000/svg';
const SELECTION_DEBOUNCE_MS = 150;
const FLASH_MS = 1500;
// -- state -----------------------------------------------------------------
let opened = false;
let colors = null;
let drawn = []; // annotations currently drawn
let hadSelection = false; // suppress selectionCleared noise
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
    if (handler)
        handler.postMessage(envelope);
    else
        console.log('gloss: no message handler, dropping event', envelope.type);
};
const postError = (error, context) => postEvent('error', {
    message: error instanceof Error ? error.message : String(error),
    context: context ?? null,
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
    const { value, range, index } = eventDetail(e);
    postEvent('annotationActivated', {
        ...annotations.idsAt(value, drawn),
        rect: viewportRect(range, index),
    });
});
// -- navigation ------------------------------------------------------------
view.addEventListener('relocate', e => postEvent('relocated', progress.makeRelocated(eventDetail(e), view.renderer)));
// External links: foliate would `window.open` them; we prevent that and hand
// them to Swift instead. Internal links are handled by foliate itself.
view.addEventListener('external-link', e => {
    e.preventDefault();
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
    const debounced = selection.makeDebouncer(() => emitSelection(doc, index), SELECTION_DEBOUNCE_MS);
    doc.addEventListener('selectionchange', debounced);
});
// -- keyboard ---------------------------------------------------------------
// goLeft/goRight already respect the book direction (`view.goRight()` is
// `prev` in RTL books), so the arrow keys always mean "visual left/right".
const turn = (forward) => forward ? view.goRight() : view.goLeft();
const onKeyDown = (e) => {
    switch (e.key) {
        case 'ArrowRight':
        case 'PageDown':
        case ' ':
            e.preventDefault();
            void turn(true);
            break;
        case 'ArrowLeft':
        case 'PageUp':
            e.preventDefault();
            void turn(false);
            break;
    }
};
document.addEventListener('keydown', onKeyDown);
view.addEventListener('load', e => {
    const { doc } = eventDetail(e);
    doc.addEventListener('keydown', onKeyDown);
});
// -- appearance -------------------------------------------------------------
const applyAppearance = (payload) => {
    colors = payload.colors;
    for (const op of appearance.appearanceOps(payload)) {
        if (op.op === 'attr')
            view.renderer?.setAttribute(op.name, op.value);
        else
            view.renderer?.setStyles?.(op.css);
    }
};
// -- command handlers ---------------------------------------------------------
const requireRenderer = () => {
    if (!view.renderer)
        throw new Error('no book is open');
    return view.renderer;
};
const commands = {
    async open({ url, position, appearance: appearancePayload }) {
        if (opened)
            throw new Error('a book is already open');
        const res = await fetch(url);
        if (!res.ok)
            throw new Error(`fetch ${url} failed: ${res.status} ${res.statusText}`);
        const blob = await res.blob();
        const file = new File([blob], 'book.epub', { type: 'application/epub+zip' });
        await view.open(file);
        opened = true;
        applyAppearance(appearancePayload);
        postEvent('opened', {
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
    async goTo({ target, flash }) {
        requireRenderer();
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
    async setAnnotations(payload) {
        requireRenderer();
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
    },
    async clearSelection() {
        requireRenderer();
        view.deselect();
    },
    async search({ query }) {
        requireRenderer();
        const mapper = search.makeSearchMapper(query);
        for await (const result of view.search({ query })) {
            const payload = mapper.map(result);
            if (payload)
                postEvent('searchResults', payload);
        }
    },
    async clearSearch() {
        requireRenderer();
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
        // search within the spine section; foliate outlines every match like
        // its search results do, we go to the first one and flash it
        for await (const result of view.search({ query: text, index: section })) {
            if (protocol.isRecord(result) && typeof result.cfi === 'string') {
                await flashTarget(await view.goTo(result.cfi));
                return;
            }
        }
    },
};
// -- bridge surface ------------------------------------------------------------
window.glossReader = {
    // Called by Swift via callAsyncJavaScript. Invalid commands reject with
    // an Error whose message starts with "bridge:"; runtime failures become
    // `error` events. Returns null (commands reply through events).
    async receive(envelope) {
        const res = protocol.validateCommand(envelope);
        if (!res.ok)
            throw new Error(res.error);
        const { type, payload } = envelope;
        try {
            // the payload was just validated against `type`'s spec
            await commands[type](payload);
        }
        catch (error) {
            postError(error, type);
        }
        return null;
    },
};
postEvent('ready', {});
