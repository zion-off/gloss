// Command choreography for the reader glue, pure enough to test under Node: commands run one
// at a time in arrival order (a book's `open` must never interleave with the commands sent
// after it), and a counter that invalidates work started before a newer one (a running search
// stops posting when a new search, a `clearSearch`, a `close` or an `open` supersedes it).

export interface SerialQueue {
    /// Runs `work` after everything before it finished (successfully or not). The returned
    /// promise settles with `work`'s outcome; the chain itself never breaks.
    run(work: () => Promise<void>): Promise<void>
}

export const makeSerialQueue = (): SerialQueue => {
    let chain: Promise<void> = Promise.resolve()
    return {
        run(work) {
            const next = chain.then(work)
            chain = next.catch(() => {})   // keep the chain running after a failure
            return next
        },
    }
}

export interface Generation {
    value(): number
    bump(): number
    isCurrent(value: number): boolean
}

export const makeGeneration = (): Generation => {
    let current = 0
    return {
        value: () => current,
        bump: () => ++current,
        isCurrent: value => value === current,
    }
}
