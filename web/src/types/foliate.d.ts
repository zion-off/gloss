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
    }
    export interface Book {
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
    }
    export class View extends HTMLElement {
        book: Book
        renderer?: Renderer
        isFixedLayout: boolean
        lastLocation?: RelocateDetail | null
        open(book: File | string): Promise<void>
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
        search(options: { query: string; index?: number }): AsyncGenerator<unknown, void, unknown>
        clearSearch(): void
    }
}
