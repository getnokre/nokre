//! The complete input vocabulary. Note what is absent: no hover, no
//! free-form drag. A pointer, keys, committed text, IME composition,
//! scroll, and one bracketed pan from a screen edge.
//!
//! The pointer has a press and a release, and it has them for a reason
//! that predates any gesture built on top: **activation belongs on the
//! release.** A press that leaves its control before letting go must
//! abort, which is WCAG 2.5.2, and a vocabulary with only a single `tap`
//! cannot express the abort — the shells that fired it at press time
//! (macOS, Windows, Linux and the web's mouse path all did) had no way
//! to offer one.
//!
//! `move` is the narrow member and stays narrow: it exists so a press
//! already holding an open menu can move *focus* to the row under the
//! pointer, and for nothing else. That is not hover reintroduced —
//! hover is a state with no keyboard equivalent, and this is the very
//! state the arrow keys move. Nothing else on screen follows the
//! pointer, and no element may start.
//!
//! The edge pan remains the only *gesture*, on its original narrow
//! terms: it is navigation, not a pointer. It carries a distance so the
//! core can decide whether a release goes back, and nothing on screen
//! tracks it — there is no partially-slid screen, no intermediate state
//! to render or to describe, and no frame that is not a direct answer to
//! an event. Reading either of these as an opening for dragging
//! arbitrary things would take all of that back
//! (docs/introduction.md).
//!
//! IME: the composition protocol is part of the core event model from day
//! one so every platform shell speaks the same language, even though not
//! every shell implements it yet (see docs/roadmap.md).

const geometry = @import("geometry.zig");

pub const Key = enum {
    tab,
    enter,
    space,
    escape,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
    _pad: u4 = 0,
};

pub const ImeEvent = union(enum) {
    start,
    /// In-progress composition text (e.g. romaji before kana conversion).
    update: struct { composition: []const u8, cursor: usize },
    /// Composition resolved; text is committed as if typed.
    commit: struct { text: []const u8 },
    cancel,
};

pub const Event = union(enum) {
    pointer: Pointer,
    key_down: struct { key: Key, mods: Modifiers = .{} },
    /// Committed text insertion (plain typing or post-IME commit).
    text: struct { bytes: []const u8 },
    ime: ImeEvent,
    scroll: Scroll,
    edge_pan: EdgePan,
};

/// One step of a pointer's life: a finger or a mouse button going down,
/// travelling, and coming up. Coordinates are logical pixels.
///
/// Nothing activates on `down`. The press is *recorded* — focus moves to
/// what is under it, as every platform's own pointer does — and the
/// release decides: landing on the same stop activates it, landing
/// anywhere else abandons it (WCAG 2.5.2's abort), and `cancel`
/// abandons it too. A shell whose recognizer loses the touch, or whose
/// window loses capture, sends `cancel` rather than `up`; the
/// distinction is load-bearing in exactly the way `EdgePan.Phase`'s is.
pub const Pointer = struct {
    at: geometry.Point,
    phase: Phase,

    pub const Phase = enum { down, move, up, cancel };
};

/// One step of a drag inward from a screen edge: the gesture that goes
/// back. The shell reports where the finger started and how far in it
/// has come; every question of *meaning* — which edge is the back edge,
/// how far is far enough, whether there is anything to go back to — is
/// the core's, so five shells cannot answer it five ways (see input.zig's
/// `handleEdgePan`).
pub const EdgePan = struct {
    from: Edge,
    /// How far in from `from` the finger has travelled. Never negative:
    /// a pan that returns to the edge is `dx` back near zero, not a
    /// sign flip.
    dx: i32,
    phase: Phase,

    /// Reported as the physical side of the screen, not as leading or
    /// trailing: a shell knows where a finger landed and nothing about
    /// the chrome's direction.
    pub const Edge = enum { left, right };

    /// `cancel` is not `end`, and the distinction is load-bearing: a
    /// recognizer can be killed mid-drag (a call arrives, a failure
    /// requirement resolves late), and that must never commit a
    /// navigation the user did not finish.
    pub const Phase = enum { begin, move, end, cancel };
};

/// A wheel/trackpad tick or one step of a touch drag. `delta_y` feeds
/// vertical scrolling (regions, then the window); `delta_x` feeds the
/// horizontal track (an overflowing `segmented`).
pub const Scroll = struct {
    at: geometry.Point,
    delta_y: i32,
    delta_x: i32 = 0,
    phase: ScrollPhase = .free,
};

/// Whether a scroll event stands alone or belongs to a gesture. A wheel
/// tick is `.free`: routed at the pointer, chaining outward where a
/// region clamps — the macOS semantics. A touch drag is bracketed:
/// `.begin` locks the targets under the initial touch for the whole
/// gesture, momentum included, `.move` carries the deltas (`at` is
/// ignored — the finger drifting out of the region must not re-route
/// mid-gesture), and `.end` (finger up, momentum spent) releases the
/// lock — the iOS semantics, where the scroller a drag starts in owns
/// it and running dry never hands the rest to an enclosing one.
pub const ScrollPhase = enum { free, begin, move, end };
