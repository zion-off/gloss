// generated from web/src/bridge/queue.ts by pnpm build; do not edit
// Command choreography for the reader glue, pure enough to test under Node: commands run one
// at a time in arrival order (a book's `open` must never interleave with the commands sent
// after it), and a counter that invalidates work started before a newer one (a running search
// stops posting when a new search, a `clearSearch`, a `close` or an `open` supersedes it).
export const makeSerialQueue = () => {
    let chain = Promise.resolve();
    return {
        run(work) {
            const next = chain.then(work);
            chain = next.catch(() => { }); // keep the chain running after a failure
            return next;
        },
    };
};
export const makeGeneration = () => {
    let current = 0;
    return {
        value: () => current,
        bump: () => ++current,
        isCurrent: value => value === current,
    };
};
