// The WKWebView surface the glue talks to. `window.webkit.messageHandlers.gloss`
// is registered by Swift; `window.glossReader.receive` is called by Swift via
// `callAsyncJavaScript`. Both are optional at runtime (the glue logs instead
// of posting when the handler is absent).

interface Window {
    webkit?: {
        messageHandlers?: {
            gloss?: { postMessage(json: string): void }
        }
    }
    glossReader?: {
        receive(envelope: unknown): Promise<unknown>
        /** a trackpad or wheel event of a paginated book, from `ReaderWebView.scrollWheel` */
        swipe(phase: unknown, dx: unknown, dy: unknown, time: unknown): void
    }
}
