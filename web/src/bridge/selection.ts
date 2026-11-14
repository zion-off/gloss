// Selection handling for the reader bridge. Pure logic, no DOM.
//
// `makeSelectionPayload` builds the `selectionChanged` payload from plain
// inputs: the selection CFI, the raw selected text, the TOC label of the
// section, a book fraction, the selection's client rect *inside the section
// iframe*, and the iframe's own offset in the web view viewport.
// Whitespace is normalised; empty selections yield null (nothing to post).

import type { SelectionChangedPayload } from './protocol.ts'

export const normalizeText = (text: unknown): string =>
    typeof text === 'string' ? text.replace(/\s+/g, ' ').trim() : ''

export interface RectLike {
    x: number
    y: number
    width: number
    height: number
}

export interface OffsetLike {
    x: number
    y: number
}

export interface SelectionInputs {
    cfi: string
    text: string
    label?: string | null
    fraction?: number | null
    rect: RectLike
    iframeOffset?: OffsetLike
}

export const makeSelectionPayload = ({
    cfi,
    text,
    label,
    fraction,
    rect,
    iframeOffset,
}: SelectionInputs): SelectionChangedPayload | null => {
    const normalized = normalizeText(text)
    if (typeof cfi !== 'string' || !cfi || !normalized || !rect) return null
    const offset = iframeOffset ?? { x: 0, y: 0 }
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
    }
}

// Injectable timers, so tests can drive the debounce without real time.
export interface DebouncerTimers {
    setTimeout: (callback: () => void, delay: number) => unknown
    clearTimeout: (handle: unknown) => void
}

const defaultTimers: DebouncerTimers = {
    setTimeout: (callback, delay) => globalThis.setTimeout(callback, delay),
    clearTimeout: handle =>
        globalThis.clearTimeout(
            handle as Parameters<typeof globalThis.clearTimeout>[0]),
}

export type Debouncer<A extends unknown[]> =
    ((...args: A) => void) & {
        cancel(): void
        pending(): boolean
    }

// Tiny trailing-edge debouncer with injectable timers.
export const makeDebouncer = <A extends unknown[]>(
    fn: (...args: A) => void,
    delay: number,
    timers: DebouncerTimers = defaultTimers,
): Debouncer<A> => {
    let handle: unknown = null
    return Object.assign(
        (...args: A): void => {
            if (handle != null) timers.clearTimeout(handle)
            handle = timers.setTimeout(() => {
                handle = null
                fn(...args)
            }, delay)
        },
        {
            cancel(): void {
                if (handle != null) {
                    timers.clearTimeout(handle)
                    handle = null
                }
            },
            pending(): boolean {
                return handle != null
            },
        },
    )
}

export interface SelectionGate {
    /** the primary button went down: a selection made now grows until it comes up */
    press(): void
    /** the button came up: the selection is final, report it */
    release(): void
    /** the selection settled (debounced); `collapsed` when there is none */
    changed(collapsed: boolean): void
}

// A selection dragged out with the mouse is reported once the button comes up, like the system's
// own edit menus: a pause mid-drag must not open the selection popover under the pointer. A
// selection that went away (a click elsewhere) is reported at once, so the popover closes, and
// one made from the keyboard (no button down) is reported as it settles.
export const makeSelectionGate = (report: () => void): SelectionGate => {
    let pressed = false
    return {
        press(): void {
            pressed = true
        },
        release(): void {
            pressed = false
            report()
        },
        changed(collapsed: boolean): void {
            if (!pressed || collapsed) report()
        },
    }
}
