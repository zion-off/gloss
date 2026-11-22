// gloss reader bridge protocol. The Swift twin is GlossReaderBridge; both are tested against Tests/Fixtures/bridge/.
//
// Every message is an envelope `{ v, type, payload }`. Swift → JS messages are
// "commands" (validated by `validateCommand`); JS → Swift messages are "events"
// (built with `makeEvent`, validated by `validateEvent` before posting).
// Pure logic only: no DOM, no window — testable under Node.

export const PROTOCOL_VERSION = 1

export type CommandType =
    | 'open'
    | 'close'
    | 'goTo'
    | 'turnPage'
    | 'setAppearance'
    | 'setAnnotations'
    | 'clearSelection'
    | 'clearSearch'
    | 'revealSearchHit'
    | 'setSearchHighlights'

export const COMMAND_TYPES: readonly CommandType[] = Object.freeze([
    'open',
    'close',
    'goTo',
    'turnPage',
    'setAppearance',
    'setAnnotations',
    'clearSelection',
    'clearSearch',
    'revealSearchHit',
    'setSearchHighlights',
])

export type EventType =
    | 'ready'
    | 'opened'
    | 'relocated'
    | 'selectionChanged'
    | 'selectionCleared'
    | 'annotationActivated'
    | 'linkActivated'
    | 'error'

export const EVENT_TYPES: readonly EventType[] = Object.freeze([
    'ready',
    'opened',
    'relocated',
    'selectionChanged',
    'selectionCleared',
    'annotationActivated',
    'linkActivated',
    'error',
])

export const FLOWS = Object.freeze(['paginated', 'scrolled'] as const)
export const DIRECTIONS = Object.freeze(['ltr', 'rtl'] as const)
export const PAGE_DIRECTIONS = Object.freeze(['forward', 'backward'] as const)
export const HIGHLIGHT_COLOR_NAMES =
    Object.freeze(['yellow', 'green', 'blue', 'pink', 'purple'] as const)

export type Flow = (typeof FLOWS)[number]
export type Direction = (typeof DIRECTIONS)[number]
export type PageDirection = (typeof PAGE_DIRECTIONS)[number]
export type HighlightColorName = (typeof HIGHLIGHT_COLOR_NAMES)[number]

// -- shared payload types --------------------------------------------------

export interface Rect {
    x: number
    y: number
    width: number
    height: number
}

export interface TocItem {
    label: string
    href: string
    children: TocItem[]
}

export interface AppearanceLayout {
    margin: number
    gap: number
    maxInlineSize: number
    maxColumnCount: number
}

export interface AppearanceColors {
    background: string
    foreground: string
    marker: string
    highlights: Record<HighlightColorName, string>
    /** A search session's shades: every match softly, the current one strongly. */
    search: { soft: string; current: string }
}

export interface Appearance {
    flow: Flow
    css: string
    layout: AppearanceLayout
    colors: AppearanceColors
}

// A passage pinned by its words (`gloss link`): the glue finds them in spine section
// `section` (bridge/quote.ts) and uses the range's CFI.
export interface QuoteTarget {
    section: number
    text: string
    prefix: string
    suffix: string
    occurrence: number
}

export type GoToTarget =
    | { cfi: string }
    | { href: string }
    | { fraction: number }
    | { quote: QuoteTarget }

export interface HighlightAnnotation {
    id: string
    cfi: string
    color: HighlightColorName
}

// exactly one of `cfi` and `quote`
export type MarkerAnnotation =
    | { id: string; cfi: string }
    | { id: string; quote: QuoteTarget }

export interface OpenPayload {
    // echoed by `opened`, so Swift can tell which open a reply belongs to
    openID: number
    url: string
    position: string | null
    appearance: Appearance
}

export interface GoToPayload {
    target: GoToTarget
}

export interface TurnPagePayload {
    direction: PageDirection
}

export interface SetAppearancePayload {
    appearance: Appearance
}

export interface SetAnnotationsPayload {
    highlights: HighlightAnnotation[]
    markers: MarkerAnnotation[]
}

export interface SearchHighlightsPayload {
    /** The session's query; null clears its highlights. */
    query: string | null
}

export interface RevealSearchHitPayload {
    cfi: string | null
    section: number | null
    text: string
    /** This very match, pinned by its words; null finds the first match of `text` in `section`. */
    quote: QuoteTarget | null
}

export interface CommandPayloads {
    open: OpenPayload
    close: Record<string, never>
    goTo: GoToPayload
    turnPage: TurnPagePayload
    setAppearance: SetAppearancePayload
    setAnnotations: SetAnnotationsPayload
    clearSelection: Record<string, never>
    clearSearch: Record<string, never>
    revealSearchHit: RevealSearchHitPayload
    setSearchHighlights: SearchHighlightsPayload
}

export interface OpenedPayload {
    // the `openID` of the `open` this answers
    openID: number
    toc: TocItem[]
    sectionCount: number
    direction: Direction
    fixedLayout: boolean
}

export interface RelocatedPayload {
    cfi: string
    fraction: number
    section: { index: number; count: number }
    tocLabel: string | null
    /** The contents entry being read (foliate's `tocItem.href`), to mark it in the sidebar. */
    tocHref: string | null
    pageLabel: string | null
    pagesLeftInSection: number | null
    atStart: boolean
    atEnd: boolean
}

export interface SelectionChangedPayload {
    cfi: string
    text: string
    label: string | null
    fraction: number | null
    rect: Rect
}

export interface AnnotationActivatedPayload {
    highlightIDs: string[]
    markerIDs: string[]
    rect: Rect
}

export interface LinkActivatedPayload {
    href: string
    external: boolean
}

export interface ErrorPayload {
    message: string
    context: string | null
    // the `openID` of the `open` that failed, so Swift can tell which open it belongs to
    openID: number | null
}

export interface EventPayloads {
    ready: Record<string, never>
    opened: OpenedPayload
    relocated: RelocatedPayload
    selectionChanged: SelectionChangedPayload
    selectionCleared: Record<string, never>
    annotationActivated: AnnotationActivatedPayload
    linkActivated: LinkActivatedPayload
    error: ErrorPayload
}

export interface Envelope {
    v: number
    type: string
    payload: unknown
}

export type ValidationResult =
    | { ok: true }
    | { ok: false; error: string }

export const makeEvent = <K extends EventType>(type: K, payload: EventPayloads[K]): Envelope =>
    ({ v: PROTOCOL_VERSION, type, payload })

// -- validators ------------------------------------------------------------

export const isRecord = (x: unknown): x is Record<string, unknown> =>
    typeof x === 'object' && x !== null && !Array.isArray(x)

type FieldSpec =
    | { t: 'string'; opt?: boolean; nullable?: boolean }
    | { t: 'number'; min?: number; max?: number; int?: boolean; opt?: boolean; nullable?: boolean }
    | { t: 'boolean'; opt?: boolean; nullable?: boolean }
    | { t: 'enum'; values: readonly (string | number)[]; opt?: boolean; nullable?: boolean }
    | { t: 'array'; item: FieldSpec; opt?: boolean; nullable?: boolean }
    | { t: 'object'; fields: Record<string, FieldSpec>; opt?: boolean; nullable?: boolean }
    | { t: 'tocitem'; opt?: boolean; nullable?: boolean }
    | {
        t: 'custom'
        describe: string
        check: (value: unknown, path: string, errors: string[]) => void
        opt?: boolean
        nullable?: boolean
    }

const STR: FieldSpec = { t: 'string' }
const BOOL: FieldSpec = { t: 'boolean' }

const describe = (spec: FieldSpec): string => {
    let what: string
    switch (spec.t) {
        case 'string': what = 'a string'; break
        case 'number': what = spec.int ? 'an integer' : 'a number'; break
        case 'boolean': what = 'a boolean'; break
        case 'enum': what = `one of ${spec.values.map(v => JSON.stringify(v)).join(', ')}`; break
        case 'array': what = 'an array'; break
        case 'object': what = 'an object'; break
        case 'tocitem': what = 'a TocItem object'; break
        case 'custom': what = spec.describe; break
    }
    return spec.nullable ? `${what} or null` : what
}

const fail = (errors: string[], path: string, what: string): void => {
    errors.push(`${path} must be ${what}`)
}

const rectFields: Record<string, FieldSpec> = {
    x: { t: 'number' },
    y: { t: 'number' },
    width: { t: 'number' },
    height: { t: 'number' },
}
const RECT: FieldSpec = { t: 'object', fields: rectFields }

// foliate TOC items are `{ label, href, subitems }`; the bridge's TocItem is
// `{ label, href, children }` (normalised by bridge/toc.ts before `opened`).
const tocItemFields: Record<string, FieldSpec> = {
    label: STR,
    href: STR,
    children: { t: 'array', item: { t: 'tocitem' } },
}

const appearanceFields: Record<string, FieldSpec> = {
    flow: { t: 'enum', values: FLOWS },
    css: STR,
    layout: {
        t: 'object',
        fields: {
            margin: { t: 'number', min: 0 },
            gap: { t: 'number', min: 0, max: 1 },
            maxInlineSize: { t: 'number', min: 1 },
            maxColumnCount: { t: 'number', min: 1, int: true },
        },
    },
    colors: {
        t: 'object',
        fields: {
            background: STR,
            foreground: STR,
            marker: STR,
            highlights: {
                t: 'object',
                fields: {
                    yellow: STR,
                    green: STR,
                    blue: STR,
                    pink: STR,
                    purple: STR,
                },
            },
            search: {
                t: 'object',
                fields: {
                    soft: STR,
                    current: STR,
                },
            },
        },
    },
}
const APPEARANCE: FieldSpec = { t: 'object', fields: appearanceFields }

const quoteTargetFields: Record<string, FieldSpec> = {
    section: { t: 'number', min: 0, int: true },
    text: STR,
    prefix: STR,
    suffix: STR,
    occurrence: { t: 'number', min: 0, int: true },
}

const goToTargetSpec: FieldSpec = {
    t: 'custom',
    describe: 'an object with exactly one of "cfi", "href", "fraction" or "quote"',
    check(value, path, errors) {
        if (!isRecord(value)) {
            fail(errors, path, 'an object with exactly one of "cfi", "href", "fraction" or "quote"')
            return
        }
        const present: string[] = []
        if (value.cfi !== undefined) {
            if (typeof value.cfi === 'string') present.push('cfi')
            else fail(errors, `${path}.cfi`, 'a string')
        }
        if (value.href !== undefined) {
            if (typeof value.href === 'string') present.push('href')
            else fail(errors, `${path}.href`, 'a string')
        }
        if (value.fraction !== undefined) {
            if (typeof value.fraction === 'number' && Number.isFinite(value.fraction)
                && value.fraction >= 0 && value.fraction <= 1) present.push('fraction')
            else fail(errors, `${path}.fraction`, 'a number between 0 and 1')
        }
        if (value.quote !== undefined) {
            const before = errors.length
            validateFields(value.quote, quoteTargetFields, `${path}.quote`, errors)
            if (errors.length === before) present.push('quote')
        }
        if (present.length !== 1)
            fail(errors, path, 'an object with exactly one of "cfi", "href", "fraction" or "quote"')
    },
}

const markerSpec: FieldSpec = {
    t: 'custom',
    describe: 'a marker with an "id" and exactly one of "cfi" or "quote"',
    check(value, path, errors) {
        if (!isRecord(value)) {
            fail(errors, path, 'an object')
            return
        }
        if (typeof value.id !== 'string') fail(errors, `${path}.id`, 'a string')
        const hasCfi = value.cfi !== undefined
        const hasQuote = value.quote !== undefined
        if (hasCfi && typeof value.cfi !== 'string') fail(errors, `${path}.cfi`, 'a string')
        if (hasQuote) validateFields(value.quote, quoteTargetFields, `${path}.quote`, errors)
        if (hasCfi === hasQuote) fail(errors, path, 'a marker with exactly one of "cfi" or "quote"')
    },
}

// -- payload specs ---------------------------------------------------------

export const COMMAND_PAYLOAD_SPECS: Record<CommandType, Record<string, FieldSpec>> = {
    open: {
        openID: { t: 'number', min: 1, int: true },
        url: STR,
        position: { t: 'string', nullable: true },
        appearance: APPEARANCE,
    },
    close: {},
    goTo: {
        target: goToTargetSpec,
    },
    turnPage: {
        direction: { t: 'enum', values: PAGE_DIRECTIONS },
    },
    setAppearance: {
        appearance: APPEARANCE,
    },
    setAnnotations: {
        highlights: {
            t: 'array',
            item: {
                t: 'object',
                fields: {
                    id: STR,
                    cfi: STR,
                    color: { t: 'enum', values: HIGHLIGHT_COLOR_NAMES },
                },
            },
        },
        markers: {
            t: 'array',
            item: markerSpec,
        },
    },
    clearSelection: {},
    clearSearch: {},
    revealSearchHit: {
        cfi: { t: 'string', nullable: true },
        section: { t: 'number', min: 0, int: true, nullable: true },
        text: STR,
        quote: { t: 'object', fields: quoteTargetFields, nullable: true },
    },
    setSearchHighlights: {
        query: { t: 'string', nullable: true },
    },
}

export const EVENT_PAYLOAD_SPECS: Record<EventType, Record<string, FieldSpec>> = {
    ready: {},
    opened: {
        openID: { t: 'number', min: 1, int: true },
        toc: { t: 'array', item: { t: 'tocitem' } },
        sectionCount: { t: 'number', min: 1, int: true },
        direction: { t: 'enum', values: DIRECTIONS },
        fixedLayout: BOOL,
    },
    relocated: {
        cfi: STR,
        fraction: { t: 'number', min: 0, max: 1 },
        section: {
            t: 'object',
            fields: {
                index: { t: 'number', min: 0, int: true },
                count: { t: 'number', min: 1, int: true },
            },
        },
        tocLabel: { t: 'string', nullable: true },
        tocHref: { t: 'string', nullable: true },
        pageLabel: { t: 'string', nullable: true },
        pagesLeftInSection: { t: 'number', min: 0, int: true, nullable: true },
        atStart: BOOL,
        atEnd: BOOL,
    },
    selectionChanged: {
        cfi: STR,
        text: STR,
        label: { t: 'string', nullable: true },
        fraction: { t: 'number', min: 0, max: 1, nullable: true },
        rect: RECT,
    },
    selectionCleared: {},
    annotationActivated: {
        highlightIDs: { t: 'array', item: STR },
        markerIDs: { t: 'array', item: STR },
        rect: RECT,
    },
    linkActivated: {
        href: STR,
        external: BOOL,
    },
    error: {
        message: STR,
        context: { t: 'string', nullable: true },
        openID: { t: 'number', min: 1, int: true, nullable: true },
    },
}

// -- entry points ----------------------------------------------------------

const validateFields = (
    value: unknown,
    fields: Record<string, FieldSpec>,
    path: string,
    errors: string[],
    what = 'an object',
): void => {
    if (!isRecord(value)) {
        fail(errors, path, what)
        return
    }
    for (const [name, fieldSpec] of Object.entries(fields)) {
        const fieldPath = `${path}.${name}`
        const v = value[name]
        if (v === undefined) {
            if (!fieldSpec.opt) fail(errors, fieldPath, describe(fieldSpec))
            continue
        }
        if (v === null) {
            if (!fieldSpec.nullable) fail(errors, fieldPath, describe(fieldSpec))
            continue
        }
        validateValue(v, fieldSpec, fieldPath, errors)
    }
}

const validateValue = (
    value: unknown,
    spec: FieldSpec,
    path: string,
    errors: string[],
): void => {
    switch (spec.t) {
        case 'string':
            if (typeof value !== 'string') fail(errors, path, describe(spec))
            break
        case 'number': {
            if (typeof value !== 'number' || !Number.isFinite(value)) {
                fail(errors, path, describe(spec))
                break
            }
            if (spec.int && !Number.isInteger(value)) {
                fail(errors, path, describe(spec))
                break
            }
            if (spec.min !== undefined && value < spec.min)
                fail(errors, path, `${spec.min} or greater`)
            if (spec.max !== undefined && value > spec.max)
                fail(errors, path, `${spec.max} or less`)
            break
        }
        case 'boolean':
            if (typeof value !== 'boolean') fail(errors, path, describe(spec))
            break
        case 'enum':
            if (!spec.values.includes(value as string | number))
                fail(errors, path, describe(spec))
            break
        case 'array': {
            if (!Array.isArray(value)) {
                fail(errors, path, describe(spec))
                break
            }
            value.forEach((item, i) =>
                validateValue(item, spec.item, `${path}[${i}]`, errors))
            break
        }
        case 'object':
            validateFields(value, spec.fields, path, errors)
            break
        case 'tocitem':
            validateFields(value, tocItemFields, path, errors, 'a TocItem object')
            break
        case 'custom':
            spec.check(value, path, errors)
            break
    }
}

const validateEnvelope = (
    envelope: unknown,
    types: readonly string[],
    specs: Record<string, Record<string, FieldSpec>>,
    kind: string,
): ValidationResult => {
    if (!isRecord(envelope))
        return { ok: false, error: 'bridge: envelope must be an object' }
    if (envelope.v !== PROTOCOL_VERSION)
        return { ok: false, error: `bridge: v must be ${PROTOCOL_VERSION}` }
    const type = envelope.type
    if (typeof type !== 'string' || !types.includes(type))
        return {
            ok: false,
            error: `bridge: unknown ${kind} type ${JSON.stringify(type) ?? 'undefined'}`,
        }
    if (!isRecord(envelope.payload))
        return { ok: false, error: `bridge: ${type}: payload must be an object` }
    const errors: string[] = []
    validateFields(envelope.payload, specs[type], 'payload', errors)
    if (errors.length) return { ok: false, error: `bridge: ${type}: ${errors[0]}` }
    return { ok: true }
}

export const validateCommand = (envelope: unknown): ValidationResult =>
    validateEnvelope(envelope, COMMAND_TYPES, COMMAND_PAYLOAD_SPECS, 'command')

export const validateEvent = (envelope: unknown): ValidationResult =>
    validateEnvelope(envelope, EVENT_TYPES, EVENT_PAYLOAD_SPECS, 'event')
