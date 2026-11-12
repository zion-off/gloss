// generated from web/src/bridge/toc.ts by pnpm build; do not edit
// TOC normalisation for the reader bridge. Pure logic, no DOM.
//
// foliate's TOC (`book.toc`, from the nav doc or NCX) is a tree of
// `{ label, href, subitems }` where `subitems` is missing on leaves. The
// bridge's `TocItem` is `{ label, href, children }` with trimmed labels.
export const normalizeTocItem = (item) => {
    const subitems = item?.subitems;
    return {
        label: typeof item?.label === 'string' ? item.label.trim() : '',
        href: typeof item?.href === 'string' ? item.href : '',
        children: Array.isArray(subitems)
            ? subitems.map(subitem => normalizeTocItem(subitem))
            : [],
    };
};
export const normalizeToc = (toc) => Array.isArray(toc)
    ? toc.map(item => normalizeTocItem(item))
    : [];
