// generated from web/src/bridge/selection.ts by pnpm build; do not edit
// Selection handling for the reader bridge. Pure logic, no DOM.
//
// `makeSelectionPayload` builds the `selectionChanged` payload from plain
// inputs: the selection CFI, the raw selected text, the TOC label of the
// section, a book fraction, the selection's client rect *inside the section
// iframe*, and the iframe's own offset in the web view viewport.
// Whitespace is normalised; empty selections yield null (nothing to post).
export const normalizeText = (text) => typeof text === 'string' ? text.replace(/\s+/g, ' ').trim() : '';
export const makeSelectionPayload = ({ cfi, text, label, fraction, rect, iframeOffset, }) => {
    const normalized = normalizeText(text);
    if (typeof cfi !== 'string' || !cfi || !normalized || !rect)
        return null;
    const offset = iframeOffset ?? { x: 0, y: 0 };
    return {
        cfi,
        text: normalized,
        label: label ?? null,
        fraction: fraction ?? null,
        rect: {
            x: rect.x + offset.x,
            y: rect.y + offset.y,
            width: rect.width,
            height: rect.height,
        },
    };
};
const defaultTimers = {
    setTimeout: (callback, delay) => globalThis.setTimeout(callback, delay),
    clearTimeout: handle => globalThis.clearTimeout(handle),
};
// Tiny trailing-edge debouncer with injectable timers.
export const makeDebouncer = (fn, delay, timers = defaultTimers) => {
    let handle = null;
    return Object.assign((...args) => {
        if (handle != null)
            timers.clearTimeout(handle);
        handle = timers.setTimeout(() => {
            handle = null;
            fn(...args);
        }, delay);
    }, {
        cancel() {
            if (handle != null) {
                timers.clearTimeout(handle);
                handle = null;
            }
        },
        pending() {
            return handle != null;
        },
    });
};
// A selection dragged out with the mouse is reported once the button comes up, like the system's
// own edit menus: a pause mid-drag must not open the selection popover under the pointer. A
// selection that went away (a click elsewhere) is reported at once, so the popover closes, and
// one made from the keyboard (no button down) is reported as it settles.
export const makeSelectionGate = (report) => {
    let pressed = false;
    return {
        press() {
            pressed = true;
        },
        release() {
            pressed = false;
            report();
        },
        changed(collapsed) {
            if (!pressed || collapsed)
                report();
        },
    };
};
