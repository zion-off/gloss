// Appearance mapping for the reader bridge. Pure logic, no DOM.
//
// An `Appearance` payload is turned into a list of operations for the foliate
// renderer (`view.renderer`), exactly how the paginator expects them
// (verified against vendored `paginator.js`):
//
// - attributes (`static observedAttributes`): `flow` (`paginated`/`scrolled`),
//   `margin` in px, `gap` as a percentage string, `max-inline-size` in px,
//   `max-column-count` as a plain integer string.
// - `{ op: 'styles', css }` → `renderer.setStyles(css)`.
//
// `gap` is a fraction (0.06) because the paginator interprets the attribute as
// a percentage of the container (`--_gap: 7%` in its default styles).

import type { Appearance } from './protocol.ts'

export type RendererOp =
    | {
        op: 'attr'
        name: 'flow' | 'margin' | 'gap' | 'max-inline-size' | 'max-column-count'
        value: string
    }
    | { op: 'styles'; css: string }

export const appearanceOps = (appearance: Appearance): RendererOp[] => {
    const layout = appearance.layout
    return [
        { op: 'attr', name: 'flow', value: appearance.flow },
        { op: 'attr', name: 'margin', value: `${layout.margin}px` },
        { op: 'attr', name: 'gap', value: `${layout.gap * 100}%` },
        { op: 'attr', name: 'max-inline-size', value: `${layout.maxInlineSize}px` },
        { op: 'attr', name: 'max-column-count', value: `${layout.maxColumnCount}` },
        { op: 'styles', css: appearance.css },
    ]
}

// The `color-scheme` the reader page should use under a theme background (`#rgb`, `#rrggbb`,
// with or without alpha), so scrollbars and form controls match the page: dark when the
// background is dark (relative luminance below 0.4), light otherwise and for anything else.
export const colorSchemeFor = (background: string): 'light' | 'dark' => {
    const hex = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.exec(background.trim())?.[1]
    if (!hex) return 'light'
    const digits = hex.length <= 4 ? [...hex].map(d => d + d).join('') : hex
    const [r, g, b] = [0, 2, 4].map(i => {
        const c = parseInt(digits.slice(i, i + 2), 16) / 255
        return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
    }) as [number, number, number]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.4 ? 'dark' : 'light'
}
