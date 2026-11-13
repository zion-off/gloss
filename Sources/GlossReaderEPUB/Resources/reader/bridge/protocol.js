// generated from web/src/bridge/protocol.ts by pnpm build; do not edit
// gloss reader bridge protocol — see docs/READER_BRIDGE.md.
//
// Every message is an envelope `{ v, type, payload }`. Swift → JS messages are
// "commands" (validated by `validateCommand`); JS → Swift messages are "events"
// (built with `makeEvent`, validated by `validateEvent` before posting).
// Pure logic only: no DOM, no window — testable under Node.
export const PROTOCOL_VERSION = 1;
export const COMMAND_TYPES = Object.freeze([
    'open',
    'close',
    'goTo',
    'turnPage',
    'setAppearance',
    'setAnnotations',
    'clearSelection',
    'search',
    'clearSearch',
    'revealSearchHit',
]);
export const EVENT_TYPES = Object.freeze([
    'ready',
    'opened',
    'relocated',
    'selectionChanged',
    'selectionCleared',
    'annotationActivated',
    'linkActivated',
    'searchResults',
    'error',
]);
export const FLOWS = Object.freeze(['paginated', 'scrolled']);
export const DIRECTIONS = Object.freeze(['ltr', 'rtl']);
export const PAGE_DIRECTIONS = Object.freeze(['forward', 'backward']);
export const HIGHLIGHT_COLOR_NAMES = Object.freeze(['yellow', 'green', 'blue', 'pink', 'purple']);
export const makeEvent = (type, payload) => ({ v: PROTOCOL_VERSION, type, payload });
// -- validators ------------------------------------------------------------
export const isRecord = (x) => typeof x === 'object' && x !== null && !Array.isArray(x);
const STR = { t: 'string' };
const BOOL = { t: 'boolean' };
const describe = (spec) => {
    let what;
    switch (spec.t) {
        case 'string':
            what = 'a string';
            break;
        case 'number':
            what = spec.int ? 'an integer' : 'a number';
            break;
        case 'boolean':
            what = 'a boolean';
            break;
        case 'enum':
            what = `one of ${spec.values.map(v => JSON.stringify(v)).join(', ')}`;
            break;
        case 'array':
            what = 'an array';
            break;
        case 'object':
            what = 'an object';
            break;
        case 'tocitem':
            what = 'a TocItem object';
            break;
        case 'custom':
            what = spec.describe;
            break;
    }
    return spec.nullable ? `${what} or null` : what;
};
const fail = (errors, path, what) => {
    errors.push(`${path} must be ${what}`);
};
const rectFields = {
    x: { t: 'number' },
    y: { t: 'number' },
    width: { t: 'number' },
    height: { t: 'number' },
};
const RECT = { t: 'object', fields: rectFields };
// foliate TOC items are `{ label, href, subitems }`; the bridge's TocItem is
// `{ label, href, children }` (normalised by bridge/toc.ts before `opened`).
const tocItemFields = {
    label: STR,
    href: STR,
    children: { t: 'array', item: { t: 'tocitem' } },
};
const appearanceFields = {
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
        },
    },
};
const APPEARANCE = { t: 'object', fields: appearanceFields };
const goToTargetSpec = {
    t: 'custom',
    describe: 'an object with exactly one of "cfi", "href" or "fraction"',
    check(value, path, errors) {
        if (!isRecord(value)) {
            fail(errors, path, 'an object with exactly one of "cfi", "href" or "fraction"');
            return;
        }
        const present = [];
        if (value.cfi !== undefined) {
            if (typeof value.cfi === 'string')
                present.push('cfi');
            else
                fail(errors, `${path}.cfi`, 'a string');
        }
        if (value.href !== undefined) {
            if (typeof value.href === 'string')
                present.push('href');
            else
                fail(errors, `${path}.href`, 'a string');
        }
        if (value.fraction !== undefined) {
            if (typeof value.fraction === 'number' && Number.isFinite(value.fraction)
                && value.fraction >= 0 && value.fraction <= 1)
                present.push('fraction');
            else
                fail(errors, `${path}.fraction`, 'a number between 0 and 1');
        }
        if (present.length !== 1)
            fail(errors, path, 'an object with exactly one of "cfi", "href" or "fraction"');
    },
};
// -- payload specs ---------------------------------------------------------
export const COMMAND_PAYLOAD_SPECS = {
    open: {
        openID: { t: 'number', min: 1, int: true },
        url: STR,
        position: { t: 'string', nullable: true },
        appearance: APPEARANCE,
    },
    close: {},
    goTo: {
        target: goToTargetSpec,
        flash: BOOL,
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
            item: {
                t: 'object',
                fields: { id: STR, cfi: STR },
            },
        },
    },
    clearSelection: {},
    search: {
        query: STR,
    },
    clearSearch: {},
    revealSearchHit: {
        cfi: { t: 'string', nullable: true },
        section: { t: 'number', min: 0, int: true, nullable: true },
        text: STR,
    },
};
export const EVENT_PAYLOAD_SPECS = {
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
    searchResults: {
        query: STR,
        items: {
            t: 'array',
            item: {
                t: 'object',
                fields: {
                    cfi: STR,
                    label: { t: 'string', nullable: true },
                    excerpt: {
                        t: 'object',
                        fields: { pre: STR, match: STR, post: STR },
                    },
                },
            },
        },
        progress: { t: 'number', min: 0, max: 1 },
        done: BOOL,
    },
    error: {
        message: STR,
        context: { t: 'string', nullable: true },
        openID: { t: 'number', min: 1, int: true, nullable: true },
    },
};
// -- entry points ----------------------------------------------------------
const validateFields = (value, fields, path, errors, what = 'an object') => {
    if (!isRecord(value)) {
        fail(errors, path, what);
        return;
    }
    for (const [name, fieldSpec] of Object.entries(fields)) {
        const fieldPath = `${path}.${name}`;
        const v = value[name];
        if (v === undefined) {
            if (!fieldSpec.opt)
                fail(errors, fieldPath, describe(fieldSpec));
            continue;
        }
        if (v === null) {
            if (!fieldSpec.nullable)
                fail(errors, fieldPath, describe(fieldSpec));
            continue;
        }
        validateValue(v, fieldSpec, fieldPath, errors);
    }
};
const validateValue = (value, spec, path, errors) => {
    switch (spec.t) {
        case 'string':
            if (typeof value !== 'string')
                fail(errors, path, describe(spec));
            break;
        case 'number': {
            if (typeof value !== 'number' || !Number.isFinite(value)) {
                fail(errors, path, describe(spec));
                break;
            }
            if (spec.int && !Number.isInteger(value)) {
                fail(errors, path, describe(spec));
                break;
            }
            if (spec.min !== undefined && value < spec.min)
                fail(errors, path, `${spec.min} or greater`);
            if (spec.max !== undefined && value > spec.max)
                fail(errors, path, `${spec.max} or less`);
            break;
        }
        case 'boolean':
            if (typeof value !== 'boolean')
                fail(errors, path, describe(spec));
            break;
        case 'enum':
            if (!spec.values.includes(value))
                fail(errors, path, describe(spec));
            break;
        case 'array': {
            if (!Array.isArray(value)) {
                fail(errors, path, describe(spec));
                break;
            }
            value.forEach((item, i) => validateValue(item, spec.item, `${path}[${i}]`, errors));
            break;
        }
        case 'object':
            validateFields(value, spec.fields, path, errors);
            break;
        case 'tocitem':
            validateFields(value, tocItemFields, path, errors, 'a TocItem object');
            break;
        case 'custom':
            spec.check(value, path, errors);
            break;
    }
};
const validateEnvelope = (envelope, types, specs, kind) => {
    if (!isRecord(envelope))
        return { ok: false, error: 'bridge: envelope must be an object' };
    if (envelope.v !== PROTOCOL_VERSION)
        return { ok: false, error: `bridge: v must be ${PROTOCOL_VERSION}` };
    const type = envelope.type;
    if (typeof type !== 'string' || !types.includes(type))
        return {
            ok: false,
            error: `bridge: unknown ${kind} type ${JSON.stringify(type) ?? 'undefined'}`,
        };
    if (!isRecord(envelope.payload))
        return { ok: false, error: `bridge: ${type}: payload must be an object` };
    const errors = [];
    validateFields(envelope.payload, specs[type], 'payload', errors);
    if (errors.length)
        return { ok: false, error: `bridge: ${type}: ${errors[0]}` };
    return { ok: true };
};
export const validateCommand = (envelope) => validateEnvelope(envelope, COMMAND_TYPES, COMMAND_PAYLOAD_SPECS, 'command');
export const validateEvent = (envelope) => validateEnvelope(envelope, EVENT_TYPES, EVENT_PAYLOAD_SPECS, 'event');
