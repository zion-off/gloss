// generated from web/src/bridge/appearance.ts by pnpm build; do not edit
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
export const appearanceOps = (appearance) => {
    const layout = appearance.layout;
    return [
        { op: 'attr', name: 'flow', value: appearance.flow },
        { op: 'attr', name: 'margin', value: `${layout.margin}px` },
        { op: 'attr', name: 'gap', value: `${layout.gap * 100}%` },
        { op: 'attr', name: 'max-inline-size', value: `${layout.maxInlineSize}px` },
        { op: 'attr', name: 'max-column-count', value: `${layout.maxColumnCount}` },
        { op: 'styles', css: appearance.css },
    ];
};
