// generated from web/src/bridge/swipe.ts by pnpm build; do not edit
// Trackpad gestures for the paginated reader. Pure logic, no DOM.
//
// Swift forwards each trackpad scroll event of a paginated book with its phase (begin, change,
// end, cancel; the momentum after a lift never arrives) and DOM-style deltas: positive means
// "scroll right/down", i.e. towards the next page in a left-to-right book.
//
// A gesture latches to one axis on its first few pixels, like an NSScrollView:
// - horizontal, when the page can follow the fingers: `drag` deltas while the fingers move,
//   then one `settle` with the lift velocity (px/ms), which foliate's `snap` turns into the
//   nearest page, pushed by the velocity (so a short flick turns, a slow half drag decides by
//   distance);
// - vertical, or a renderer that can't be dragged: a single `turn` once the gesture has moved
//   far enough, like a wheel.
export const LATCH_DISTANCE = 4; // px before a gesture picks its axis
export const TURN_DISTANCE = 30; // px a non-dragging gesture travels to turn a page
export const VELOCITY_WINDOW_MS = 80; // how far back the lift velocity looks
const fresh = () => ({ axis: null, sx: 0, sy: 0, distance: 0, turned: false, dragged: false, samples: [] });
// Average speed over the last moments before the lift; zero when the fingers rested first.
export const liftVelocity = (samples, endTime) => {
    const recent = samples.filter(s => endTime - s.time <= VELOCITY_WINDOW_MS);
    if (recent.length === 0)
        return 0;
    const span = Math.max(16, endTime - recent[0].time);
    return recent.reduce((sum, s) => sum + s.delta, 0) / span;
};
export const makeSwipeTracker = () => {
    let gesture = null;
    const move = (g, delta, time, draggable) => {
        if (delta === 0)
            return [];
        if (g.axis === 'x' && draggable) {
            g.dragged = true;
            g.samples.push({ time, delta });
            return [{ kind: 'drag', delta }];
        }
        g.distance += delta;
        if (g.turned || Math.abs(g.distance) < TURN_DISTANCE)
            return [];
        g.turned = true;
        return [{ kind: 'turn', axis: g.axis ?? 'x', forward: g.distance > 0 }];
    };
    return {
        feed(phase, dx, dy, time, draggable) {
            if (![dx, dy, time].every(Number.isFinite))
                return [];
            switch (phase) {
                case 'begin':
                    gesture = fresh();
                    return [];
                case 'change': {
                    const g = gesture ??= fresh();
                    if (g.axis === null) {
                        g.sx += dx;
                        g.sy += dy;
                        if (Math.abs(g.sx) + Math.abs(g.sy) < LATCH_DISTANCE)
                            return [];
                        g.axis = Math.abs(g.sx) >= Math.abs(g.sy) ? 'x' : 'y';
                        return move(g, g.axis === 'x' ? g.sx : g.sy, time, draggable);
                    }
                    return move(g, g.axis === 'x' ? dx : dy, time, draggable);
                }
                case 'end':
                case 'cancel': {
                    const g = gesture;
                    gesture = null;
                    if (!g?.dragged)
                        return [];
                    return [{
                            kind: 'settle',
                            velocity: phase === 'end' ? liftVelocity(g.samples, time) : 0,
                        }];
                }
            }
        },
    };
};
