// Ambient declarations for the vendored foliate-js modules the glue imports
// (see ../../../../../Sources/GlossReaderEPUB/Resources/reader/foliate/ and
// foliate/VENDORED.md). The vendored files are plain JavaScript kept
// byte-identical, so they cannot carry their own declarations; these
// signatures were written against the vendored source at the pinned commit.
//
// The glue imports foliate under the bare `foliate/` prefix, which the
// import map in index.html resolves to `./foliate/` in the web view.

declare module 'foliate/overlayer.js' {
    export interface OverlayerDrawOptions {
        color?: string
        width?: number
        writingMode?: string
        radius?: number
    }
    export type OverlayerDrawFunction =
        (rects: ArrayLike<DOMRect>, options?: OverlayerDrawOptions) => Element
    export class Overlayer {
        constructor()
        get element(): SVGElement
        add(key: string, range: Range, draw: OverlayerDrawFunction,
            options?: OverlayerDrawOptions): void
        remove(key: string): void
        redraw(): void
        static underline: OverlayerDrawFunction
        static strikethrough: OverlayerDrawFunction
        static squiggly: OverlayerDrawFunction
        static highlight: OverlayerDrawFunction
        static outline: OverlayerDrawFunction
    }
}

declare module 'foliate/search.js' {
    /** foliate's matcher factory; the glue builds one to find a hit's own CFI in its section */
    export const searchMatcher: (
        textWalker: unknown,
        opts: { defaultLocale?: string; matchCase?: boolean; matchDiacritics?: boolean; matchWholeWords?: boolean },
    ) => (doc: Document, query: string) => Generator<{ range: unknown; excerpt: unknown }>
}

declare module 'foliate/text-walker.js' {
    export const textWalker: unknown
}

declare module 'foliate/view.js' {
    /** one TOC entry as foliate produces it (nav doc or NCX) */
    export interface FoliateTocItem {
        label?: string
        href?: string
        subitems?: FoliateTocItem[]
    }
    export interface BookSection {
        id: string
        linear?: string
        size: number
        cfi?: string
        /** parses the section's (untransformed) document, as foliate's search does */
        createDocument?(): Promise<Document>
    }
    /** the `load` event detail of `book.transformTarget`: set `allow` to false to skip a resource */
    export interface LoadResourceDetail {
        type: string
        isScript: boolean
        allow: boolean | Promise<boolean>
    }
    /** the `data` event detail of `book.transformTarget`: replace `data` to transform a resource */
    export interface ResourceDataDetail {
        readonly name: string
        type: string
        data: unknown
    }
    export interface Book {
        /** EPUB only: the raw text of a resource in the book, by its href (a section's `id`) */
        loadText?(href: string): Promise<string>
        /** EPUB only: fires `load` and `data` events while resources load */
        transformTarget?: EventTarget
        toc?: FoliateTocItem[]
        sections: BookSection[]
        dir?: string
        rendition?: { layout?: string }
    }
    /** TOC / page-list progress item (`TOCProgress.getProgress` result item) */
    export interface ProgressItem {
        label?: string
        href?: string
    }
    /** the View's `relocate` event detail (also `view.lastLocation`) */
    export interface RelocateDetail {
        fraction: number
        section: { current: number; total: number }
        tocItem?: ProgressItem | null
        pageItem?: ProgressItem | null
        cfi: string
    }
    /** what `view.goTo` / `view.resolveNavigation` resolve a target to */
    export interface ResolvedTarget {
        index: number
        // Range | Element | number | ((doc) => Range | Element | number)
        anchor: unknown
    }
    export interface Content {
        index: number
        doc: Document
        overlayer?: import('foliate/overlayer.js').Overlayer
    }
    export interface Renderer extends HTMLElement {
        scrolled?: boolean
        page?: number
        pages?: number
        atStart?: boolean
        atEnd?: boolean
        setStyles?(css: string): void
        getContents(): Content[]
        next(distance?: number): Promise<void>
        prev(distance?: number): Promise<void>
        /** paginator only: moves the page by a delta, at most one page from where it rests */
        scrollBy?(dx: number, dy: number): void
        /** paginator only: settles on the nearest page, pushed by a velocity in px/ms */
        snap?(vx: number, vy: number): void
    }
    /** opens a File (EPUB, CBZ, FB2, MOBI, …) as a foliate book */
    export function makeBook(file: File): Promise<Book>
    export class View extends HTMLElement {
        book: Book
        renderer?: Renderer
        isFixedLayout: boolean
        lastLocation?: RelocateDetail | null
        open(book: File | string | Book): Promise<void>
        /** destroys the renderer; `renderer` keeps pointing at the destroyed element */
        close(): void
        init(options: { lastLocation?: string; showTextStart?: boolean }): Promise<void>
        addAnnotation(annotation: { value: string }, remove?: boolean):
            Promise<{ index: number; label: string }>
        deleteAnnotation(annotation: { value: string }):
            Promise<{ index: number; label: string }>
        getCFI(index: number, range?: Range): string
        getProgressOf(index: number, range?: Range): {
            tocItem?: ProgressItem | null
            pageItem?: ProgressItem | null
        }
        goTo(target: unknown): Promise<ResolvedTarget | undefined>
        goToFraction(fraction: number): Promise<void>
        next(distance?: number): Promise<void>
        prev(distance?: number): Promise<void>
        goLeft(): Promise<void>
        goRight(): Promise<void>
        deselect(): void
        search(options: {
            query: string
            index?: number
            /** how the matches are drawn; foliate's default is a thick outline */
            draw?: unknown
            drawOptions?: { color?: string }
        }): AsyncGenerator<unknown, void, unknown>
        clearSearch(): void
        /** the book's language, as foliate's own search defaults to */
        language: string
    }
}
