// TOC normalisation for the reader bridge. Pure logic, no DOM.
//
// foliate's TOC (`book.toc`, from the nav doc or NCX) is a tree of
// `{ label, href, subitems }` where `subitems` is missing on leaves. The
// bridge's `TocItem` is `{ label, href, children }` with trimmed labels.

import type { TocItem } from './protocol.ts'

export interface FoliateTocItem {
    label?: unknown
    href?: unknown
    subitems?: unknown
}

export const normalizeTocItem = (item?: FoliateTocItem | null): TocItem => {
    const subitems = item?.subitems
    return {
        label: typeof item?.label === 'string' ? item.label.trim() : '',
        href: typeof item?.href === 'string' ? item.href : '',
        children: Array.isArray(subitems)
            ? subitems.map(subitem => normalizeTocItem(subitem as FoliateTocItem | null))
            : [],
    }
}

export const normalizeToc = (toc: unknown): TocItem[] =>
    Array.isArray(toc)
        ? toc.map(item => normalizeTocItem(item as FoliateTocItem | null))
        : []
