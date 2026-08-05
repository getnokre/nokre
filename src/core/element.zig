//! The closed element set. Every element is semantic: role, label, and
//! states are intrinsic, so accessibility derives automatically from the
//! tree — consumers cannot forget it.

const text = @import("text.zig");
const color = @import("color.zig");

pub const Axis = enum { vertical, horizontal };

/// The six outline levels. Only three sizes sit above the 16px body, so
/// the deeper levels descend to body and small and lean on the weight
/// every heading carries (see `Heading.base_face`) to stay distinct from
/// the prose around them.
pub const HeadingLevel = enum(u8) {
    h1 = 1,
    h2 = 2,
    h3 = 3,
    h4 = 4,
    h5 = 5,
    h6 = 6,

    pub fn scale(self: HeadingLevel) text.Scale {
        return switch (self) {
            .h1 => .h1,
            .h2 => .h2,
            .h3 => .h3,
            .h4 => .h4,
            .h5 => .body,
            .h6 => .small,
        };
    }
};

/// A context+function pair. nokre never allocates closures.
///
/// A list row's action carries the row: set `index` at append and
/// receive it in `call_indexed`. The alternative is a comptime table of
/// generated functions, one per possible row, baking a position into
/// code — the index here is data on the element, exactly as fresh as
/// the tree it rides in (the same reason `PickerItem` carries its
/// `index` on the node rather than in a callback). A press can still
/// land after the list it named has moved, and that check belongs to
/// the receiver, who alone knows the list — the contract's home is
/// docs/elements.md, "Actions". `call` and `call_indexed` name one
/// function between them; both set is refused at append.
pub const Action = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Handed to `call_indexed` at dispatch. Meaningless to `call`.
    index: usize = 0,
    call_indexed: ?*const fn (ctx: ?*anyopaque, index: usize) void = null,

    pub fn invoke(self: Action) void {
        if (self.call_indexed) |f| return f(self.ctx, self.index);
        if (self.call) |f| f(self.ctx);
    }

    /// Whether any function is named — the thing `invoke` treats as
    /// something to do.
    pub fn wired(self: Action) bool {
        return self.call != null or self.call_indexed != null;
    }

    /// Synthesizes the `ctx`+`call` pair from a typed method, so the
    /// `?*anyopaque` boundary never appears in consumer source:
    /// `.on_press = .bind(State.retry, state)` generates the same
    /// trampoline a consumer would otherwise write by hand — the cast
    /// (with its loud null unwrap) and the forward, minus the lines.
    /// `f` takes the state pointer and nothing else.
    pub fn bind(comptime f: anytype, state: anytype) Action {
        const T = @typeInfo(@TypeOf(state)).pointer.child;
        return .{ .ctx = state, .call = struct {
            fn call(c: ?*anyopaque) void {
                f(@as(*T, @ptrCast(@alignCast(c.?))));
            }
        }.call };
    }

    /// `bind` for the `call_indexed` shape: `f(state, index)`, the row
    /// arriving as data per the `index` contract above.
    pub fn bindAt(comptime f: anytype, state: anytype, index: usize) Action {
        const T = @typeInfo(@TypeOf(state)).pointer.child;
        return .{ .ctx = state, .index = index, .call_indexed = struct {
            fn call(c: ?*anyopaque, i: usize) void {
                f(@as(*T, @ptrCast(@alignCast(c.?))), i);
            }
        }.call };
    }
};

pub const ToggleAction = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque, checked: bool) void = null,
    /// Handed to `call_indexed` at dispatch. Meaningless to `call`.
    /// Same contract as `Action.index`.
    index: usize = 0,
    call_indexed: ?*const fn (ctx: ?*anyopaque, index: usize, checked: bool) void = null,

    pub fn invoke(self: ToggleAction, checked: bool) void {
        if (self.call_indexed) |f| return f(self.ctx, self.index, checked);
        if (self.call) |f| f(self.ctx, checked);
    }

    /// Same contract as `Action.bind`; `f(state, checked)`.
    pub fn bind(comptime f: anytype, state: anytype) ToggleAction {
        const T = @typeInfo(@TypeOf(state)).pointer.child;
        return .{ .ctx = state, .call = struct {
            fn call(c: ?*anyopaque, checked: bool) void {
                f(@as(*T, @ptrCast(@alignCast(c.?))), checked);
            }
        }.call };
    }

    /// Same contract as `Action.bindAt`; `f(state, index, checked)` —
    /// the payload keeps its dispatch position, after the index.
    pub fn bindAt(comptime f: anytype, state: anytype, index: usize) ToggleAction {
        const T = @typeInfo(@TypeOf(state)).pointer.child;
        return .{ .ctx = state, .index = index, .call_indexed = struct {
            fn call(c: ?*anyopaque, i: usize, checked: bool) void {
                f(@as(*T, @ptrCast(@alignCast(c.?))), i, checked);
            }
        }.call };
    }
};

pub const ChangeAction = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque, value: []const u8) void = null,

    pub fn invoke(self: ChangeAction, value: []const u8) void {
        if (self.call) |f| f(self.ctx, value);
    }

    /// Same contract as `Action.bind`; `f(state, value)`.
    pub fn bind(comptime f: anytype, state: anytype) ChangeAction {
        const T = @typeInfo(@TypeOf(state)).pointer.child;
        return .{ .ctx = state, .call = struct {
            fn call(c: ?*anyopaque, value: []const u8) void {
                f(@as(*T, @ptrCast(@alignCast(c.?))), value);
            }
        }.call };
    }
};

pub const SelectAction = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque, selected: usize) void = null,

    pub fn invoke(self: SelectAction, selected: usize) void {
        if (self.call) |f| f(self.ctx, selected);
    }

    /// Same contract as `Action.bind`; `f(state, selected)`.
    pub fn bind(comptime f: anytype, state: anytype) SelectAction {
        const T = @typeInfo(@TypeOf(state)).pointer.child;
        return .{ .ctx = state, .call = struct {
            fn call(c: ?*anyopaque, selected: usize) void {
                f(@as(*T, @ptrCast(@alignCast(c.?))), selected);
            }
        }.call };
    }
};

/// One styled run inside a `text` or `heading`. Spans are semantic, not
/// free styling — Markdown's inline vocabulary: `strong` (bold),
/// `emphasis` (italic), `code` (the mono family, verbatim voice),
/// `strike` (struck through).
/// Styling spans are invisible to assistive tech by design: the
/// accessibility tree announces the element's concatenated content as
/// one text node, so a span must never be the sole carrier of
/// information the words don't state — the same rule grayscale already
/// imposes on color.
///
/// A span carrying a `route` is the one carve-out. It is a control, not
/// styling: it is announced as a link inside the paragraph, it is a tab
/// stop, and it is activated. A link nobody can hear is worse than no
/// link at all, so the invisibility rule stops exactly where behavior
/// starts.
pub const Span = struct {
    text: []const u8,
    strong: bool = false,
    emphasis: bool = false,
    /// Verbatim voice: renders in the mono family (variants included —
    /// strong/emphasis compose onto it).
    code: bool = false,
    /// Struck through: a 1px rule across the run's middle. Not a face —
    /// no bundled family ships a struck variant, and synthesizing one
    /// would re-open the rasterizer variance the bundled fonts exist to
    /// close — so it is drawn like the link underline and costs the
    /// measurement nothing. Because the mark is the only thing carrying
    /// it, the span rule applies with full force: struck words must
    /// still read correctly to someone who cannot see the line, since
    /// assistive tech hears the element's content as one plain string.
    strike: bool = false,
    /// Makes this run an inline link: underlined, its own tab stop, and
    /// on activation resolved by the router exactly like a `link`
    /// element's route — so a bad reference is refused where every
    /// other bad route is (a recorded no-op, router.zig), and the
    /// audit's `unresolvable_route` rule names the span's node.
    route: ?[]const u8 = null,
    /// The other kind of link destination, exclusive with `route`: an
    /// external URL handed to the system browser on activation (the
    /// open_url service). nokre still renders no external content — the
    /// page opens where the user's own chrome and trust live — and the
    /// scheme set is closed (https/http/mailto, open_url's allowlist),
    /// checked at append like every other construction rule. Same
    /// visual, same tab stop, same announced role as a routed span:
    /// where it goes is semantics, not styling.
    external: ?[]const u8 = null,
    /// null inherits the element's ink. Gated by the same append-time
    /// contrast check as the element's own ink.
    ink: ?color.Gray = null,

    /// Whether this run is a link at all — one question for the six
    /// places that ask (focus, hit testing, a11y, both editions'
    /// drawing), so a destination kind added here cannot be a link to
    /// five of them and prose to the sixth.
    pub fn isLink(self: Span) bool {
        return self.route != null or self.external != null;
    }

    /// The drawable face this span resolves to on an element drawn in
    /// `base`. The variants compose onto the base rather than replacing
    /// it: a heading's base face is already bold, and a run that isn't
    /// `strong` inside one must not fall back to regular.
    pub fn face(self: Span, base: text.Face) text.Face {
        return .{
            .family = if (self.code) .mono else base.family,
            .bold = base.bold or self.strong,
            .italic = base.italic or self.emphasis,
        };
    }
};

pub const Text = struct {
    /// With `spans` empty this is the text; with spans it is written by
    /// `append` as their concatenation (consumers leave it empty) so the
    /// accessible name and every content consumer see one plain string.
    content: []const u8 = "",
    style: text.Style = .{},
    /// Styled runs; empty means the whole content renders in `style`.
    /// After `append` each span's `text` is a slice into `content`.
    spans: []const Span = &.{},
};

pub const Heading = struct {
    content: []const u8 = "",
    level: HeadingLevel = .h1,
    /// As on `Text`; the base face is always `base_face`, the base ink
    /// `.ink`.
    spans: []const Span = &.{},

    /// Every level draws bold. Size alone cannot separate the levels —
    /// body text is 16px, so the smaller levels sit at or below it — so
    /// weight is the second axis, applied uniformly: "h3 regular but h4
    /// bold" is not a rule anyone could predict. The bundled families
    /// ship real drawn bold faces, so this stays clear of synthetic
    /// emboldening and the rasterizer variance it reopens.
    pub const base_face: text.Face = .{ .family = .prose, .bold = true };
};

/// Block container: children flow vertically inside padding and an
/// optional 1px border.
pub const Box = struct {
    border: bool = true,
    padding: i32 = 12,
    fill: ?color.Gray = null,
};

pub const Divider = struct {};

/// A static inline status label: small text inside a bordered chip,
/// sized to its content. State is carried by the words, not a hue.
/// Never interactive — an actionable chip is a `button`.
pub const Badge = struct {
    label: []const u8,
    /// Leading mark on the chip, decorative — `Tile.icon`'s shape and
    /// `Tile.icon`'s terms. A field, not a child node: it takes no focus
    /// and answers no press, and it enters no accessibility tree, so the
    /// `label` remains both mandatory and the whole of what is announced.
    ///
    /// **It restates; it never states.** A chip whose glyph carries
    /// something its words do not is a chip that says less to a reader
    /// than to a looker, which is the refusal behind "the words carry
    /// it" — the state was never allowed to live in the ornament. The
    /// check is one deletion: take every mark off the screen and nothing
    /// on it has stopped being true or knowable. What the glyph buys is
    /// recognition in a row that gets scanned, not a fact.
    ///
    /// Sized as the chip's own text (`small`) and inked as it is, so it
    /// costs the glyph's advance plus `icon_gap` and no more — a `mark`
    /// and not the `lineHeight` band a `tile` spends, because chips flow
    /// inline and have no column to line up. On a chip that stands alone
    /// that width buys nothing; see [elements.md](../../docs/elements.md).
    icon: ?IconName = null,
};

/// A static gauge: how much of a whole is filled, as a bar under the
/// words that state it. As with `badge`, the words carry the state —
/// the label ("12 of 30 days") is rendered above the bar and is what
/// assistive tech hears; the fill only restates it visually. Never
/// interactive, never animated.
pub const Meter = struct {
    label: []const u8,
    /// Filled portion, 0...max inclusive.
    value: i32 = 0,
    max: i32 = 100,
};

/// A verbatim value restated as a scannable QR code — `copyable`'s
/// visual twin for the value that leaves through a camera instead of
/// the clipboard. `label` (mandatory, rendered above at the small
/// scale) is what assistive tech announces; `value` (mandatory) is the
/// encoded text. Encoding happens once at `append` (medium error
/// correction, no knobs); a value that cannot encode is rejected there.
/// Never interactive. The code always draws ink-on-paper from the
/// light palette, both appearances — scanners want dark modules on a
/// light ground.
pub const Qr = struct {
    label: []const u8,
    value: []const u8,
    /// Written by append; consumers read, never write. Module bits,
    /// row-major, packed LSB-first.
    modules: []const u8 = "",
    /// Modules per side (21–177). Written by append.
    size: i32 = 0,

    /// Whether the module at (x, y) is dark.
    pub fn module(self: Qr, x: i32, y: i32) bool {
        const i: usize = @intCast(y * self.size + x);
        return self.modules[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) != 0;
    }
};

pub const Stack = struct {
    axis: Axis = .vertical,
    gap: i32 = 8,
    padding: i32 = 0,
};

/// The vendors nokre can draw a conforming sign-in button for. Not an
/// open set and not a styling knob: every visual and verbal detail of
/// these buttons is the vendor's to specify, so `provider` is the whole
/// API and there is nothing else to configure.
///
/// Google's arm is the one place color exists in nokre, and it is the
/// renderer's, not this element's. Its guidelines require the official
/// multicolour G — a gray one is not a sanctioned variant — and drawing
/// it was long refused for exactly that reason. The refusal was
/// reversed as a deliberate owner decision (2026-08, recorded in
/// docs/internals/oauth.md): rgb is unlocked for the *infrastructure* —
/// the canvas, the shim, the frame — and for this trademark alone. No
/// element carries a color, no consumer call accepts one, and this enum
/// stays the whole API; an app still cannot put a colored pixel on
/// screen. The no-color guarantee an app can rely on is unchanged —
/// what changed is that the framework itself now draws one vendor's
/// artwork in the vendor's colors.
pub const AuthProvider = enum {
    apple,
    google,

    /// The mark, as a codepoint in the brand face
    /// (src/assets/fonts/LICENSE-Brand.txt). Trademarked artwork, drawn
    /// from exactly one place in each edition. Google's G is four
    /// glyphs on one shared advance (one per colored arc —
    /// `google_g_rgb` below); this returns the first, which is also
    /// what layout measures, and the renderer overlays all four at the
    /// origin this one is placed at.
    pub fn mark(self: AuthProvider) []const u8 {
        return switch (self) {
            .apple => "\u{e900}",
            .google => "\u{e901}",
        };
    }
};

/// Google's four arc colors, in arc order — blue, green, yellow, red —
/// the order the brand face stacks its glyphs and the DOM markup its
/// spans. The vendor's trademark spec, transcribed exactly once: the
/// reference renderer paints them and the generated stylesheet prints
/// them, both from this table, so the two editions cannot drift
/// (docs/internals/oauth.md). They are the only color values in nokre —
/// infrastructure, not a palette: no element carries a color and no
/// consumer call accepts one.
pub const google_g_rgb = [4]struct { r: u8, g: u8, b: u8 }{
    .{ .r = 0x42, .g = 0x85, .b = 0xF4 }, // blue
    .{ .r = 0x34, .g = 0xA8, .b = 0x53 }, // green
    .{ .r = 0xFB, .g = 0xBC, .b = 0x05 }, // yellow
    .{ .r = 0xEA, .g = 0x43, .b = 0x35 }, // red
};

pub const Button = struct {
    label: []const u8,
    on_press: Action = .{},
    disabled: bool = false,
    /// The work this button started is running: it has been pressed and
    /// the result has not arrived. Not "loading" — nothing is being
    /// loaded, an action is outstanding — and not a spinner, which would
    /// be animation the frame model does not have.
    ///
    /// The button renders `…` in place of its words (the literal form of
    /// suspense, and the one nokre already uses for elided text) at the
    /// size it measured for the label, so the screen does not move when
    /// the work starts or when it ends. It stops activating — a second
    /// press cannot start the work twice — but unlike `disabled` it
    /// keeps its focus stop: the user pressed this button, usually with
    /// the keyboard, and dropping the stop out from under their own
    /// focus is the focus loss WCAG 3.2.2 is about. Assistive tech hears
    /// the same pair the ARIA practices prescribe: still named, still
    /// reachable, disabled and busy (docs/accessibility.md).
    ///
    /// The label stays what it was — `…` is a state, not a name. A name
    /// that changed under a voice-control user mid-action would take
    /// away the words they were about to say.
    ///
    /// Setting `disabled` alongside is allowed and not redundant: an app
    /// that derives one from its form and the other from its work has no
    /// reason to reconcile them. `in_progress` wins the pixels, and
    /// `disabled` wins the focus stop, each saying the stronger thing.
    in_progress: bool = false,
    /// How far along that work is, 0–100. Set it and the `…` gives way
    /// to a meter track in the same slot — same pill, same size, same
    /// fill, so the button never becomes a different button; only what
    /// stands in the middle changes. Leave it null when the work cannot
    /// say, which is the honest default: `…` means *no estimate*, and a
    /// bar that moves on a guess is worse than one that isn't there.
    ///
    /// Only with `in_progress`, and never on the glyph form — a
    /// percentage on a button that is not working means nothing, and a
    /// 24px glyph target has no room to read a bar. Both are rejected at
    /// append, along with a value past 100.
    ///
    /// The words do not change and neither does the accessible name;
    /// assistive tech gets the number as the node's value, so it hears
    /// "Save changes, 60%" — the same trade `meter` makes, where the
    /// state is in the words and the bar only restates it.
    progress_percent: ?u8 = null,
    /// Folded away by an overflowing row of actions: the row could not
    /// fit this button, so a `more` control stands where it was and the
    /// sheet that control opens is where it can be reached
    /// (overflow.zig). It draws nothing, takes no tap, keeps no focus
    /// stop, and is invisible to assistive tech — a name announced for
    /// something nobody can reach is worse than one that is not there.
    /// Written by layout; consumers read, never write. See
    /// `Element.foldable` for which elements a row may fold, and why the
    /// set stops where it does.
    folded: bool = false,
    /// Which button this is. Once four independent flags (`secondary`,
    /// `icon`, `icon_only`, `provider`) whose five illegal combinations
    /// append had to refuse one by one; as a union those states cannot
    /// be written, and the checks are gone with them.
    form: Form = .{ .filled = null },

    pub const Form = union(enum) {
        /// The filled primary pill — ink fill, paper text. The payload
        /// is an optional Lucide glyph leading the label; both stay
        /// visible, because an icon never hides the words by itself.
        filled: ?IconName,
        /// Secondary emphasis: an outlined pill — ambient background,
        /// 1px `.g6` border (the same WCAG 1.4.11 carrier as segmented
        /// chips), ink text — instead of the filled primary. Same
        /// geometry, so the pair aligns side by side; same optional
        /// leading glyph.
        secondary: ?IconName,
        /// Glyph form: drops the pill and renders only this glyph,
        /// quiet on the ambient surface, on the standard 24px tap
        /// target — the form framework chrome uses (back, sheet
        /// close). The glyph *is* the payload, which is what makes a
        /// glyph form without one unbuildable; there is no pill, so
        /// there is no emphasis to vary. The label stays mandatory and
        /// is what assistive tech announces.
        glyph: IconName,
        /// A conforming vendor sign-in button: the vendor's mark leads
        /// the label, occupying the glyph slot — which is why neither
        /// an icon nor the glyph form can be asked for beside it. The
        /// button is otherwise an ordinary button — same geometry, same
        /// activation, same a11y — because that is what the vendors'
        /// own specs describe.
        ///
        /// `label` stays the app's to supply, and stays mandatory.
        /// nokre ships the mark, which is artwork it can hold; it does
        /// not ship the words, which are a translation problem it
        /// cannot: the vendors require their string localized, and
        /// nokre has no idea which languages an app ships. A default
        /// here would only make the unlocalized button the silent
        /// path. Take the wording from the vendor's own published
        /// strings for each locale you support (Apple's ship with the
        /// button assets, alongside the mark).
        ///
        /// The G on Google's button is the one colored thing nokre
        /// ever draws — the renderer's doing, not a field here; see
        /// `AuthProvider`.
        provider: Provider,

        /// The sanctioned vendor styles, spelled out rather than
        /// composed: Apple sanctions three (black, white, and a white
        /// outlined third — the filled pair falls out of the true
        /// endpoints flipping with the appearance, so `.apple` covers
        /// both and `.apple_outlined` is the third). Google sanctions
        /// *themes* (a light button and a dark one), not emphases: the
        /// appearance picks the theme, and the outlined Google button
        /// this enum has no member for is not a form their guidelines
        /// describe.
        pub const Provider = enum {
            apple,
            apple_outlined,
            google,

            /// Whose mark this style carries.
            pub fn vendor(self: Provider) AuthProvider {
                return switch (self) {
                    .apple, .apple_outlined => .apple,
                    .google => .google,
                };
            }
        };

        /// The Lucide glyph this form carries, wherever it stands — a
        /// pill's lead or the glyph form's whole face. Null for the
        /// vendor forms: the mark owns that slot.
        pub fn icon(self: Form) ?IconName {
            return switch (self) {
                .filled, .secondary => |ic| ic,
                .glyph => |ic| ic,
                .provider => null,
            };
        }

        /// The outlined pill faces — `secondary`, and Apple's outlined
        /// third — which draw ink on the ambient and take focus as a
        /// thickened edge rather than a ring.
        pub fn outlined(self: Form) bool {
            return switch (self) {
                .secondary => true,
                .provider => |p| p == .apple_outlined,
                .filled, .glyph => false,
            };
        }

        /// The vendor whose mark leads the label, when this is a
        /// sign-in button.
        pub fn vendor(self: Form) ?AuthProvider {
            return switch (self) {
                .provider => |p| p.vendor(),
                else => null,
            };
        }
    };
};

pub const Link = struct {
    label: []const u8,
    /// Route reference resolved by the router on activation — a name,
    /// optionally with arguments: `note~42` (docs/routing.md). Exactly
    /// one of `route`/`external` must be set; append enforces it.
    route: []const u8 = "",
    /// External destination instead of a route: the URL is handed to
    /// the system browser on activation (`Span.external` has the whole
    /// argument; the allowlist is checked at append here too).
    external: ?[]const u8 = null,
    /// Folded away by an overflowing row of actions, exactly as
    /// `Button.folded` — a row of things to press is a row of things to
    /// press whether the press acts or goes somewhere. Written by
    /// layout; consumers read, never write.
    folded: bool = false,
};

/// On/off state as an iOS-style pill switch. State changes apply
/// immediately — a toggle never needs a submit button beside it, and a
/// change that has to reach a server before it is true says so with
/// `in_progress` rather than borrowing one.
pub const Toggle = struct {
    label: []const u8,
    on: bool = false,
    on_toggle: ToggleAction = .{},
    /// The work this switch started is running: it has been flipped and
    /// the new value is not a fact yet. `Button.in_progress` in every
    /// respect but one — what stands down is not the words but the
    /// *switch*, because a button's words say what the press will do
    /// while a track says what the value is, and neither is knowable
    /// while the work is in flight.
    ///
    /// The track and its knob give way to `…` in the slot they
    /// occupied, at the size layout already gave the row, so nothing
    /// moves when the work starts or when it ends. It does not dim:
    /// busy is not unavailable. The words stay — `…` is a state, not a
    /// name — and so does `on`, which assistive tech still hears: the
    /// ellipsis is a rendering, and a reader who cannot see it is owed
    /// the value the app still holds.
    ///
    /// It stops flipping — a second press cannot start the work twice —
    /// and keeps its focus stop, for the reason `Button.in_progress`
    /// keeps its: the user flipped this switch, usually with the
    /// keyboard, and dropping the stop out from under their own focus is
    /// the focus loss WCAG 3.2.2 is about.
    ///
    /// There is deliberately no twin of `Button.progress_percent` here:
    /// a 20px track has nowhere to read a bar, which is the same reason
    /// an `icon_only` button is refused one.
    in_progress: bool = false,
};

/// On/off state as a square check box. Unlike `toggle`, checking commits
/// nothing by itself — a checkbox marks a choice for a nearby control to
/// gather (consent-then-submit, picking members from a list).
pub const Checkbox = struct {
    label: []const u8,
    checked: bool = false,
    on_toggle: ToggleAction = .{},
    /// `Toggle.in_progress`, box for track: the mark this box carries is
    /// what stands down for `…` while the work runs. The rarer of the
    /// two, because checking commits nothing by itself — but a box whose
    /// row is gathered the moment it is ticked has work in flight like
    /// any other, and nothing else on the row can say so.
    in_progress: bool = false,
};

/// Single-line text input. The label is rendered above the field — it is
/// mandatory, which is what makes the field accessible by construction.
/// IME composition state lives here so every platform shell shares one
/// protocol (see docs/roadmap.md for per-platform IME status).
pub const TextInput = struct {
    label: []const u8,
    value: []const u8 = "",
    placeholder: []const u8 = "",
    cursor: usize = 0,
    composition: []const u8 = "",
    /// Password mode: renders one bullet per codepoint and never exposes
    /// the value to assistive tech or traces. Editing is unchanged.
    obscured: bool = false,
    on_change: ChangeAction = .{},
    on_submit: Action = .{},
};

/// Multi-line text input. Wraps like prose and grows with content, never
/// below three rows. Enter inserts a newline — there is no submit action.
pub const TextArea = struct {
    label: []const u8,
    value: []const u8 = "",
    placeholder: []const u8 = "",
    cursor: usize = 0,
    composition: []const u8 = "",
    on_change: ChangeAction = .{},
};

/// An ordered or unordered sequence of peer items; children must be
/// `list_item`s. Markers are derived from the list and the item's
/// position, never authored — a list whose numbers say something the
/// order doesn't is a lie assistive tech would repeat. Nesting is
/// capped at `max_list_depth`: past that the indent stops carrying
/// structure and starts eating the line.
pub const List = struct {
    ordered: bool = false,
    /// The first ordinal of an ordered list; ignored when unordered.
    /// Markdown's `3.` start, so a list resumed after a paragraph keeps
    /// counting.
    start: i32 = 1,
};

/// One item of a `list`. Holds document blocks, not arbitrary content:
/// a heading inside one would claim an outline position the list cannot
/// own, and a nested grid reads as a mistake at any depth.
pub const ListItem = struct {
    /// The rendered marker, written by layout from the owning list and
    /// this item's position — consumers read, never write, as with
    /// `scroll_region`'s `content_height`. It lives here rather than in
    /// a render-time scratch buffer so it outlives the frame: the
    /// recording canvas and the trace both borrow the bytes they are
    /// handed.
    marker_buf: [max_marker_len]u8 = @splat(0),
    marker_len: u8 = 0,

    /// Longest derived marker: "-2147483648." plus room to spare.
    pub const max_marker_len = 24;

    pub fn marker(self: *const ListItem) []const u8 {
        return self.marker_buf[0..self.marker_len];
    }

    pub fn setMarker(self: *ListItem, bytes: []const u8) void {
        const n = @min(bytes.len, self.marker_buf.len);
        @memcpy(self.marker_buf[0..n], bytes[0..n]);
        self.marker_len = @intCast(n);
    }
};

/// How deep lists may nest. Beyond three the indent has consumed the
/// line without telling the reader anything the words don't; the
/// Markdown parser flattens deeper levels onto this one rather than
/// failing, the way it rebases heading levels.
pub const max_list_depth = 3;

/// The widest table layout can place: its per-column width table is
/// sized by this. A construction rule like `max_list_depth`, not a
/// rendering truncation — the cell that would open a 33rd column is
/// refused at append (`error.TooManyColumns`), because past layout's
/// bookkeeping a cell keeps only a stale rect, which hit testing and
/// assistive tech would go on reading while nothing draws it. The
/// Markdown parser degrades a wider table to its literal source text
/// rather than fail, as it does a nested one (markdown.zig).
pub const max_table_columns = 32;

/// The unordered marker, at every depth. A per-depth glyph ladder
/// (circle, square) would need codepoints the bundled families do not
/// all draw, and the indent already carries the depth.
pub const list_bullet = "\u{2022}";

/// A Markdown document, expanded into ordinary children at `append`.
/// It is not a renderer with private drawing rules: the expansion
/// produces only elements the framework already knows, so the set stays
/// closed and every append-time gate applies to parsed content for free
/// — the parser's error path *is* append's.
///
/// `label` is explicit and mandatory. Deriving a name from the first
/// `h1` fails on documents that do not open with one, and legal text
/// often does not.
///
/// `source` is copied like every other string, so an app may free its
/// HTTP response buffer the moment `append` returns. See
/// docs/markdown.md for the subset and the degrade rule.
pub const Document = struct {
    label: []const u8,
    source: []const u8,
};

/// An attributed quotation: words that belong to someone other than the
/// surrounding prose. Marked by a 1px rule on the leading edge plus an
/// indent — the rule is an edge it draws, so unlike `list` it consumes
/// the advised margin and nothing bleeds across it. Children are the
/// document block set, like a `list_item`'s. The attribution is words
/// inside it, not a field: a quote whose source only a border implies
/// is a quote whose source nobody hears.
pub const Blockquote = struct {};

/// A verbatim block: whitespace preserved, never reflowed. The mono
/// family, one rendered line per newline, no word wrap — a wrapped code
/// line lies about where the code breaks, and re-indents the next one.
/// A block wider than its parent scrolls horizontally, following the
/// `segmented` precedent: it declines the advised margin, bleeds to the
/// nearest drawn edge, clips there, and rides a 2px indicator.
/// Focusable, because it scrolls.
///
/// It draws no fill and no border. Boxing it would be decoration, and
/// would move its text onto a surface the contrast gate would then have
/// to re-prove; a block that wants a frame goes inside a `box`.
pub const CodeBlock = struct {
    content: []const u8,
    /// Horizontal scroll state, like `segmented`'s: scroll input writes
    /// it, layout clamps it. Consumers read, never write.
    offset: i32 = 0,
    /// How far the rect bleeds past the flow span on each side — the
    /// advised margin the overflowing block declined (see layout's
    /// `Ctx.margin`); zero while it fits. Written by layout; consumers
    /// read, never write.
    bleed: i32 = 0,
    /// The widest line's width, as `scroll_region`'s `content_height`
    /// is to its viewport. Written by layout; consumers read, never
    /// write.
    content_width: i32 = 0,
};

/// Children must be `row` elements; a row's children must be `cell`s.
/// `Tree.append` rejects anything else.
pub const Table = struct {};

pub const Row = struct {
    header: bool = false,
};

pub const Cell = struct {};

/// Viewport over vertically flowing children. A fixed `height` sizes it
/// explicitly; null fills the space remaining below it.
pub const ScrollRegion = struct {
    height: ?i32 = null,
    offset: i32 = 0,
    /// Written by layout; consumers read, never write.
    content_height: i32 = 0,
};

/// Exclusive choice among a fixed set of options (radiogroup semantics).
/// One tab stop; ←/→ move the selection and commit immediately. A track
/// wider than its parent scrolls horizontally: it declines the advised
/// margin and bleeds to the nearest drawn edge, chips clip there, a
/// 2px indicator appears under them, and the framework keeps the
/// selected chip in view — selection is the only thing that moves it.
pub const Segmented = struct {
    label: []const u8,
    options: []const []const u8,
    selected: usize = 0,
    on_select: SelectAction = .{},
    /// Scroll state, like `scroll_region`'s: horizontal scroll input
    /// and selection reveals write it, layout clamps it. -1 (the
    /// initial value) asks layout to reveal the selected chip.
    /// Consumers read, never write.
    offset: i32 = -1,
    /// How far the rect bleeds past the flow span on each side — the
    /// advised margin the overflowing track declined (see layout's
    /// `Ctx.margin`); zero while the track fits. Written by layout;
    /// consumers read, never write.
    bleed: i32 = 0,
};

/// A bordered vertical group of tappable rows; children must be `tile`s.
/// The border is grouping, not state — it draws like `radio_group`'s
/// group but carries no selection. An optional `description` hangs below
/// the border in dim small print — the group-level counterpart of a
/// tile's `detail`, for a caption that belongs to the set of rows rather
/// than any one of them.
pub const TileGroup = struct {
    description: []const u8 = "",
};

/// One tappable row in a `tile_group`: a label, an optional dimmed
/// `detail` line beneath it, and either a `route` reference (a trailing
/// chevron; activation navigates like a link) or an `on_press` (a button
/// in row clothing). Each tile is its own tab stop.
pub const Tile = struct {
    label: []const u8,
    detail: []const u8 = "",
    route: []const u8 = "",
    on_press: Action = .{},
    /// Leading mark on the row, decorative: the `label` stays the
    /// accessible name, exactly as a `notice`'s icon stands down for its
    /// title. A row whose glyph were also announced would say its own
    /// name twice, and the second saying would be a guess — no glyph
    /// means one thing, which is why the standalone `icon` element makes
    /// naming a mark deliberate (`Icon.label`) rather than automatic.
    ///
    /// A field, not a child node, for the reason `Notice.icon` is one: it
    /// takes no focus and answers no press, so it must not exist where
    /// focus and hit testing look. It is sized as the `icon` element is,
    /// a `lineHeight` square (`layout.tileIconBand`) — the same box for
    /// every glyph, so a group's rows start their words on one column the
    /// way a `list`'s marker band makes its items do.
    ///
    /// All the rows of a group or none of them: `append` rejects a mixed
    /// group (`error.TileGroupMixedIcons`).
    icon: ?IconName = null,
};

/// The same exclusive-choice semantics as `segmented`, presented as a
/// vertical list of circle glyphs under a visible group label. One tab
/// stop; ↑/↓ (and ←/→) move the selection and commit immediately.
pub const RadioGroup = struct {
    label: []const u8,
    options: []const []const u8,
    selected: usize = 0,
    on_select: SelectAction = .{},
};

/// Closed choice from a list too long to lay bare as `segmented` or
/// `radio_group` rows. The field shows the current option; activation
/// opens the modal picker (framework chrome). One tab stop.
pub const Select = struct {
    label: []const u8,
    options: []const []const u8,
    selected: usize = 0,
    on_select: SelectAction = .{},
};

/// A verbatim value the user carries away (a recovery code, an invite
/// link): `label` above, `value` in mono inside the field, a copy glyph
/// at the trailing edge. Activation is intrinsic — it writes the value
/// to the platform clipboard (`App.copyText`); there is no action to
/// wire, so it cannot be miswired. One tab stop.
pub const Copyable = struct {
    label: []const u8,
    value: []const u8,
};

/// App-level navigation chrome; children must be `nav_item`s. Installed
/// once via `App.setNav` and preserved across router rebuilds. Always a
/// bottom pane, centered and capped at the sheet width.
pub const Nav = struct {};

/// Every string nokre itself puts on a screen or into the accessibility
/// tree — the framework's own words. No consumer wrote them, so no
/// consumer's data can supply them: `RouteDef.title` names *screens*,
/// and none of these is a screen.
///
/// English by default, so an app that ships one language declares
/// nothing. An app that ships more says them in the language on screen
/// with one call (`App.setChrome`), because that is what they are —
/// one fact, "what nokre calls its own chrome", and a locale changes
/// every one of them at once. A field per control would let a nav bar
/// be half translated.
///
/// The defaults cut the other way for that app: a `Chrome` literal
/// that misses a field compiles, and the miss ships as English in the
/// middle of a translated nav bar. `Catalog` is the opt-in that closes
/// this — the same fields with no defaults, so full coverage is
/// checked where every other catalog mistake is checked here: at
/// compile time.
///
/// Borrowed, never owned, exactly like `RouteDef.title`: an ARB
/// catalog's `tr` hands back constant data, which is what these are for.
pub const Chrome = struct {
    /// The back control's accessible name. Nothing draws it — the
    /// chevron is the control — so this is purely what a reader hears.
    back: []const u8 = "Back",
    /// The sheet's close control, same shape.
    close: []const u8 = "Close",
    /// The collapsed nav chip's *name*. The section it stands on is its
    /// value and comes from the route table, so this is the half of the
    /// chip a catalog has to supply.
    section: []const u8 = "Section",
    /// The marker for a screen that is none of the destinations — again
    /// a name, with the route's own title as its value.
    current_screen: []const u8 = "Current screen",
    /// The dialog title of the picker the collapsed chip opens. Never
    /// drawn (the card stands on the chip that names it), but it is what
    /// assistive tech is told the dialog is called.
    sections: []const u8 = "Sections",
    /// The notices pane's title: drawn as its heading and announced as
    /// its name.
    notices: []const u8 = "Notices",
    /// The indicator that stands for pending notices in the nav pane.
    show_notices: []const u8 = "Show notices",
    /// The banner's expand control, when more than one notice is
    /// pending; with exactly one, the banner offers `open_prefix`
    /// instead.
    show_all_notices: []const u8 = "Show all notices",
    minimize_notices: []const u8 = "Minimize notices",
    dismiss_all_notices: []const u8 = "Dismiss all notices",
    /// A notice's own two controls name the notice they act on, so they
    /// are a prefix and a title joined — not a format string. A runtime
    /// format is a placeholder a translator can drop, reorder, or
    /// mistype, and nokre's whole l10n posture is that such a mistake is
    /// a build error; there is no comptime left to check one written
    /// here. Joining costs the reordering a few languages would want,
    /// and buys a string that cannot be wrong.
    open_prefix: []const u8 = "Open: ",
    dismiss_prefix: []const u8 = "Dismiss: ",
    /// The two captions the notices pane heads its groups with, when
    /// both kinds are pending.
    important: []const u8 = "Important",
    other: []const u8 = "Other",
    /// The live region an acknowledged `copyable` grows while its check
    /// is showing (docs/accessibility.md). A derived node, not an
    /// element — so unlike the rest this one is read where it is built,
    /// which the snapshot can do because it holds the App.
    copied: []const u8 = "Copied",
    /// The folded tail's name, the words on its pill, and its sheet's
    /// title (`More`). The other one read somewhere besides the node it
    /// names: layout reserves this control's width while *deciding* the
    /// fold, before the control exists, so `App.flow` hands layout this
    /// word on its own (`layout.moreSize`) — the only field of this
    /// struct layout is told about, because it is the only control whose
    /// room is claimed before there is anything to measure.
    more: []const u8 = "More",

    // The localized app's opt-in lives with the words, not here:
    // `l10n` `Bundle.chrome(locale)` derives one reserved catalog key
    // per field above (`chromeBack`, `chromeCurrentScreen`, …) and
    // builds this struct whole, so a missing chrome word — including
    // one a new field creates — is a missing-key compile error in the
    // catalog. A field added above therefore names its key in the same
    // breath, and every localized app stops compiling until its
    // catalogs say the new word. The bare literal with these defaults
    // stays for what defaults are for: the English-only app, or one
    // saying a word or two.
};

/// The English nokre ships, and what every chrome element's own field
/// defaults to — so a framework control built before `setChrome` is
/// named rather than blank.
pub const default_chrome: Chrome = .{};

/// Modal bottom sheet, installed via `App.presentSheet`. While one is
/// open the rest of the tree is inert: focus, taps, and scrolling stay
/// inside. It appears and disappears instantly — there is no transition
/// to wait out and nothing for WCAG 2.3.3 to object to.
pub const Sheet = struct {
    /// The dialog's accessible name; also rendered as its header.
    title: []const u8,
};

/// The sheet's close control, installed by `App.presentSheet` and pinned
/// to the header corner by layout. Drawn as the square-x glyph;
/// activation dismisses the sheet.
pub const SheetClose = struct {
    /// The framework's own word for it (`App.Chrome.close`), copied in
    /// when the control is built rather than read where it is needed:
    /// `Element.label()` is pure and has no App to ask which language
    /// this app is in.
    label: []const u8 = default_chrome.close,
};

/// The folded tail of an overflowing row of actions: the control that
/// stands in for the buttons and links that did not fit — and for the
/// last one that did, which gives up its slot so the control never
/// appears without warning at the edge it is standing on. Installed by
/// `overflow.syncOverflowChrome` in place of nothing the consumer wrote
/// — like the nav's shape, how many actions a row can show is the
/// framework's decision, and there is no API for it.
///
/// It is a plain button to assistive tech, and drawn as one: the
/// outlined pill its neighbors already wear, leading an ellipsis. What
/// it opens is a sheet holding those actions — the way to them, not one
/// of them, which is why it is the quiet emphasis and never the filled.
///
/// The actions themselves stay in the tree, folded (`Button.folded`), so
/// a consumer's `NodeId` survives the row reshaping under it exactly as
/// the roster survives the nav collapsing.
pub const More = struct {
    /// The framework's own word for it (`App.Chrome.more`), the words on
    /// its pill and its sheet's title alike — copied in when
    /// `overflow.syncOverflowChrome` builds the control, for
    /// `SheetClose.label`'s reason: `Element.label()` is pure and has no
    /// App to ask which language this app is in. What is unlike the rest
    /// is the *other* reader: layout claims this control's width while
    /// deciding the fold, when there is no node here to read, so
    /// `App.flow` hands the same word to layout separately
    /// (`layout.moreSize`). One word, two routes to the same place — and
    /// `App.setChrome` re-says it here so they cannot drift apart.
    label: []const u8 = default_chrome.more,
};

/// The framework's back control, installed by the router on every pushed
/// screen (stack depth > 1) — consumers never wire their own. Laid out at
/// the start of the first content element's line (a heading, by
/// convention), drawn as the chevron-left glyph. Activation pops one
/// screen.
pub const Back = struct {
    /// The framework's own word for it (`App.Chrome.back`), copied in at
    /// construction — `SheetClose.label`'s rule. Nothing draws it: the
    /// glyph is the control, and this is what a reader hears.
    label: []const u8 = default_chrome.back,
};

/// The Lucide glyphs framework chrome draws. Icons are text: the bundled
/// icon font keeps them grayscale and deterministic like everything else.
pub const Glyph = enum {
    /// square-arrow-out-up-right: navigate to a notice's route.
    open,
    /// square-arrow-up: expand pending notices into the notices pane.
    expand,
    /// square-chevron-down: minimize notices back to the nav pane.
    minimize,
    /// square-x: dismiss one notice.
    dismiss,
    /// trash-2: dismiss every pending notice, from the pane's header.
    /// The one glyph outside the square family — emptying the list is
    /// not one more way to file it, and the bin says so.
    dismiss_all,

    pub fn utf8(self: Glyph) []const u8 {
        return switch (self) {
            .open => "\u{e5a4}",
            .expand => "\u{e42a}",
            .minimize => "\u{e3cf}",
            .dismiss => "\u{e175}",
            .dismiss_all => "\u{e18e}",
        };
    }
};

/// chevron-down: the select field's affordance. Drawn directly by the
/// renderer — it is not a control, so it is not a `Glyph`.
pub const select_chevron = "\u{e06d}";

/// chevron-up: the collapsed nav chip's affordance, same footing as
/// `select_chevron`. It points up because that is where the list
/// appears — the chip sits in the bottom pane and the picker opens
/// above it. A vertical chevron is horizontally symmetric, so unlike
/// the tile's it does not mirror; only its side of the chip does.
pub const nav_chevron = "\u{e070}";

/// chevron-right: the navigating tile's affordance, same footing as
/// `select_chevron`. Chevrons point where navigation goes, so they are
/// the one glyph pair that mirrors with the chrome direction; the
/// symmetric-box glyphs above and the copy/check marks do not.
pub const tile_chevron = "\u{e06f}";

/// chevron-left: `tile_chevron` under a mirrored (RTL) chrome.
pub const tile_chevron_rtl = "\u{e06e}";

/// chevron-left: the back control's glyph, same footing as
/// `select_chevron`.
pub const back_chevron = "\u{e06e}";

/// chevron-right: `back_chevron` under a mirrored (RTL) chrome.
pub const back_chevron_rtl = "\u{e06f}";

/// arrow-left: `back_chevron`'s slot while a back gesture is past the
/// point where releasing goes back (`App.back_gesture`). A swap, not a
/// decoration — the same move `copy_check` makes in `copy_glyph`'s slot,
/// and for the same reason: on a glyph control the mark *is* the state,
/// so a latch changes what is drawn rather than adding a ground under
/// it. The two say different things, which is the point. A chevron
/// points the way navigation goes; an arrow is the act of going, so
/// arming a gesture reads as the outcome it is promising and not as a
/// button being held.
///
/// It also carries: at 24px the arrow's ink is twice the chevron's width
/// and reaches nearer the em box's leading edge, so the change survives
/// the peripheral vision this is actually read with — a thumb at the
/// screen edge, eyes on the content.
pub const back_arrow = "\u{e048}";

/// arrow-right: `back_arrow` under a mirrored (RTL) chrome, pairing like
/// the chevrons above.
pub const back_arrow_rtl = "\u{e049}";

/// check: the checked box's mark, same footing as `select_chevron`.
pub const checkbox_check = "\u{e06c}";

/// copy: the copyable field's affordance, same footing as
/// `select_chevron`.
pub const copy_glyph = "\u{e09e}";

/// check: the acknowledged copyable's mark, drawn in `copy_glyph`'s slot
/// while the field holds the acknowledgement (`App.ack`). The same
/// codepoint as `checkbox_check` under its own name, as the chevrons
/// above pair up: the role names the constant, not the outline.
pub const copy_check = "\u{e06c}";

/// Every Lucide glyph consumers can place, named — the whole bundled
/// font, generated from it rather than curated by hand (see
/// `icon_names.zig`, `tools/gen-icon-names.py`).
pub const IconName = @import("icon_names.zig").IconName;

/// A named glyph as content, sized like text. Decorative by default: an
/// empty label hides it from assistive tech (alt=""); naming it makes it
/// an image whose ink must clear the same contrast gate as text.
pub const Icon = struct {
    name: IconName,
    label: []const u8 = "",
    scale: text.Scale = .body,
    ink: color.Gray = .ink,
};

/// Icon-only button, framework chrome only — consumers get labeled
/// `button`s. Activation is intrinsic to the glyph and its position
/// (see `App.activate`), so there is no action to wire.
pub const IconButton = struct {
    glyph: Glyph,
    label: []const u8,
};

/// App-level status banner in the bottom pane, installed via
/// `App.notify`. The front notice shows as a banner; all pending ones
/// list inside the notices pane. Never auto-dismissed (WCAG 2.2.1) and
/// never steals focus (WCAG 3.2.1).
pub const Notice = struct {
    title: []const u8,
    description: []const u8 = "",
    /// Route reference the notice deep-links to via its open control.
    route: []const u8,
    /// Leading mark on the words' side of the row, decorative: the
    /// title stays the accessible name (`notify`'s rationale). A field,
    /// not a child node — it takes no focus and answers no press, so it
    /// must not exist where focus and hit testing look. Sized as the
    /// `icon` element is, a `lineHeight` square, so layout needs no
    /// measurer to know what the words' column loses to it.
    icon: ?IconName = null,
    /// Written by layout; consumers read, never write.
    height: i32 = 0,
};

/// Modal list of every pending notice, opened from the banner's expand
/// control or the nav pane's indicator. Children are `notice` rows plus
/// the pane's own controls; Esc, the scrim, or its minimize control
/// collapse it back to the nav pane.
pub const NoticesPane = struct {
    /// The pane's accessible name *and* its drawn header title — one
    /// field, because layout measures the header from the same bytes
    /// `label()` announces and a second copy could drift and
    /// mis-measure. Copied in from `App.Chrome.notices` at
    /// construction, `SheetClose.label`'s rule.
    title: []const u8 = default_chrome.notices,
    /// Written by layout; consumers read, never write.
    height: i32 = 0,
};

/// The select picker: a modal option list installed by activating a
/// `select` — never appended by consumers. It stacks above everything,
/// an open sheet included; Esc or the scrim closes it without
/// committing. Its children are a scroll region of `picker_item` rows,
/// preceded by a filter `text_input` when the option list is long.
pub const Picker = struct {
    /// The owning select's label; the dialog's accessible name.
    title: []const u8,
    /// The owning select's full option count. With a filter present it
    /// keeps the picker's height stable while rows come and go.
    option_count: usize = 0,
    /// Stand on the bottom bar instead of covering it. Set for the
    /// collapsed nav's section list, whose owner *is* the bottom bar: a
    /// menu drawn over the control that opened it would put a row under
    /// the finger still holding it, so letting go without moving would
    /// choose a section nobody aimed at — and there would be nowhere to
    /// release that means "never mind". A select's picker has no such
    /// problem: its owner is in the content, already behind the scrim.
    ///
    /// Placement is the whole of what it decides for the tree, and the
    /// whole of what it decides for semantics — but layout and the
    /// renderer read it for the shape too, a card on the chip rather
    /// than a pane on the frame (`layout.layoutNavMenu`). Both shapes
    /// are one dialog of options either way.
    above_nav: bool = false,
};

/// One option row inside the picker. Activation commits the choice and
/// closes the picker.
pub const PickerItem = struct {
    label: []const u8,
    selected: bool = false,
    /// Index into the owning select's options: filtering hides rows, so
    /// row position no longer equals option index.
    index: usize = 0,
    /// The row's leading glyph, carried only by the collapsed nav's
    /// section list — the destinations wear the same icons in the
    /// picker that they wear in the row, so the shape the framework
    /// picked never changes what a section looks like. A select's
    /// options have no icons, so it stays null there.
    icon: ?IconName = null,
};

/// One destination in the nav row, appended by `nav.syncNavChrome` from
/// the roster — never by consumers, who declare a route and a glyph and
/// let the framework do the rest (`nav.Destination`).
pub const NavItem = struct {
    /// The destination's `RouteDef.title`. Carried on the node rather
    /// than looked up where it is drawn: layout, the renderer and
    /// semantics read the tree and nothing else.
    label: []const u8,
    /// Activation pushes this route, so the screen it was crossed from
    /// keeps its way back; standing on it already is a no-op (nav.zig).
    route: []const u8,
    /// The destination's glyph, leading its label.
    icon: IconName,
};

/// The collapsed nav: the current section's name, and the control that
/// opens the others. Installed by `nav.syncNavChrome` in place of the
/// `nav_item` row when the roster's widest label will not fit its slot
/// — never appended by consumers, who declare destinations and let the
/// framework choose the shape (`App.setNav`).
///
/// It is a `combo_box` to assistive tech, not a link: what it does is
/// open a list and take a choice, which is the select's contract, not
/// the nav item's. The roster lives on the App while this stands in for
/// it, so the destinations the row would have exposed are reachable
/// exactly one way — through the picker this opens.
pub const NavCurrent = struct {
    /// The current section's label, refreshed by the sync on every
    /// router rebuild. Stored rather than derived because `label()` is
    /// pure: it has no App to ask which route is current.
    ///
    /// It is the control's *value*, not its name — the name is `name`
    /// below, like a select's. A control that renamed itself every time
    /// it was used would leave a screen-reader user with nothing stable
    /// to look for.
    section: []const u8,
    /// The current section's glyph, refreshed by the same sync and
    /// leading the label exactly as the row item's does. The chip
    /// stands in for one destination; it wears that destination's mark.
    icon: IconName,
    /// The framework's own word for the control (`App.Chrome.section`),
    /// copied in at construction — the other half of the name/value
    /// split above, and the half a catalog has to supply.
    name: []const u8 = default_chrome.section,
};

/// The row's marker for a screen that is *not* one of the destinations:
/// the route's declared title (`RouteDef.title`), wearing the plating a
/// current `nav_item` wears. Installed by `nav.syncNavChrome` alongside
/// the row, never appended by consumers.
///
/// It exists because the alternatives both lie. Marking nothing current
/// leaves the one piece of chrome whose job is "where am I" answering
/// nothing on every screen that is not a section root. Marking the
/// nearest destination — the section a push came *from* — would be
/// nokre inventing a hierarchy consumers never declared, and the
/// declaration is the only thing that could make it true.
///
/// It is static text, not a `nav_item`: a destination is a link that
/// goes somewhere, and this one goes where you already are. So it takes
/// no focus, answers no press, and is not in the tab order — it is a
/// label in the shape of a plate. Its name is the framework's and the
/// title is its value, the same split `nav_current` makes, so a screen
/// reader has something stable to look for.
pub const NavHere = struct {
    /// `RouteDef.title` for the screen on top. Named, not derived: see
    /// that field's rationale (router.zig). `value` because that is what
    /// a11y makes of it: the node's *value* (semantics.zig), never its
    /// name — the marker's accessible name is the chrome's "Current
    /// screen" (`name`, below), and `title` in this file always means
    /// accessible name.
    value: []const u8,
    /// And this is its name (`App.Chrome.current_screen`), copied in at
    /// construction like `nav_current`'s.
    name: []const u8 = default_chrome.current_screen,
};

/// file-text: the mark every off-roster screen wears. One glyph for all
/// of them, deliberately — a per-route mark would make each of these
/// look like a destination the roster forgot, and the roster is closed
/// (`setNav`). A destination earns a recognizable mark by being somewhere
/// you return to; this is only ever *here*.
pub const nav_here_icon: IconName = .file_text;

pub const Role = enum {
    text,
    heading,
    icon,
    box,
    divider,
    badge,
    meter,
    qr,
    stack,
    button,
    link,
    toggle,
    checkbox,
    text_input,
    text_area,
    list,
    list_item,
    code_block,
    blockquote,
    document,
    table,
    row,
    cell,
    scroll_region,
    segmented,
    tile_group,
    tile,
    radio_group,
    select,
    copyable,
    nav,
    nav_item,
    nav_current,
    nav_here,
    sheet,
    sheet_close,
    back,
    notice,
    notices_pane,
    icon_button,
    picker,
    picker_item,
    more,

    /// Whether a root child of this role is a framework chrome layer —
    /// drawn by the chrome pass, in its fixed order — rather than page
    /// content. Both editions partition the root with this one answer
    /// (`render`, `serialize.chrome`/`content`); exhaustive with no
    /// `else`, so a new element must say which side it stands on or
    /// neither edition compiles.
    pub fn isChromeLayer(self: Role) bool {
        return switch (self) {
            .nav, .icon_button, .notice, .notices_pane, .sheet, .picker => true,
            .text, .heading, .icon, .box, .divider, .badge, .meter, .qr, .stack, .button, .link, .toggle, .checkbox, .text_input, .text_area, .list, .list_item, .code_block, .blockquote, .document, .table, .row, .cell, .scroll_region, .segmented, .tile_group, .tile, .radio_group, .select, .copyable, .nav_item, .nav_current, .nav_here, .sheet_close, .back, .picker_item, .more => false,
        };
    }

    /// Whether an element of this role must carry a non-empty
    /// accessible name to enter the tree (`Tree.validateAppend`,
    /// `error.UnlabeledInteractive`). The consumer-built interactive
    /// set — narrower than `isInteractive`, because framework chrome
    /// (`nav_current`, `sheet_close`, `back`, `more`) names itself and
    /// a disabled control still needs its name. Exhaustive, so a new
    /// interactive element cannot silently skip the guarantee.
    pub fn requiresLabel(self: Role) bool {
        return switch (self) {
            .button, .link, .toggle, .checkbox, .text_input, .text_area, .nav_item, .segmented, .tile, .radio_group, .select, .copyable, .icon_button, .picker_item => true,
            .text, .heading, .icon, .box, .divider, .badge, .meter, .qr, .stack, .list, .list_item, .code_block, .blockquote, .document, .table, .row, .cell, .scroll_region, .tile_group, .nav, .nav_current, .nav_here, .sheet, .sheet_close, .back, .notice, .notices_pane, .picker, .more => false,
        };
    }
};

/// See `Element.textRun`.
pub const TextRun = struct {
    face: text.Face,
    scale: text.Scale,
    ink: color.Gray,
    content: []const u8,
    spans: []const Span,
};

pub const Element = union(Role) {
    text: Text,
    heading: Heading,
    icon: Icon,
    box: Box,
    divider: Divider,
    badge: Badge,
    meter: Meter,
    qr: Qr,
    stack: Stack,
    button: Button,
    link: Link,
    toggle: Toggle,
    checkbox: Checkbox,
    text_input: TextInput,
    text_area: TextArea,
    list: List,
    list_item: ListItem,
    code_block: CodeBlock,
    blockquote: Blockquote,
    document: Document,
    table: Table,
    row: Row,
    cell: Cell,
    scroll_region: ScrollRegion,
    segmented: Segmented,
    tile_group: TileGroup,
    tile: Tile,
    radio_group: RadioGroup,
    select: Select,
    copyable: Copyable,
    nav: Nav,
    nav_item: NavItem,
    nav_current: NavCurrent,
    nav_here: NavHere,
    sheet: Sheet,
    sheet_close: SheetClose,
    back: Back,
    notice: Notice,
    notices_pane: NoticesPane,
    icon_button: IconButton,
    picker: Picker,
    picker_item: PickerItem,
    more: More,

    pub fn role(self: Element) Role {
        return @as(Role, self);
    }

    /// Whether this element may stand in a row that folds, and be
    /// restated in the sheet the fold opens (overflow.zig).
    ///
    /// A button and a link, and deliberately nothing else. They are the
    /// two press-me leaves whose whole state is what they call or where
    /// they go, so the sheet can restate one of them *whole* and the
    /// press means the same thing in both places. A toggle, a checkbox,
    /// a select, a field — each keeps its state in the node, and a
    /// restatement of one would take the press and leave the original
    /// saying the old thing.
    ///
    /// It is also what makes a row a row of actions rather than a
    /// composition: two arrows with a month between them is a pager, not
    /// a menu, and folding "March" behind a control named "More" would
    /// be nonsense. Such rows keep the behavior every over-wide row had
    /// before the fold existed.
    pub fn foldable(self: Element) bool {
        return self == .button or self == .link;
    }

    /// Whether an overflowing row folded this one away — asked by focus,
    /// hit testing, drawing, the a11y snapshot, and the test queries, so
    /// it is one question in one place rather than a switch at each of
    /// them.
    pub fn isFolded(self: Element) bool {
        return switch (self) {
            .button => |b| b.folded,
            .link => |l| l.folded,
            else => false,
        };
    }

    /// Layout's half of `isFolded`. Silently does nothing for the rest of
    /// the set — a row containing any of them never folds, so there is
    /// no state to keep.
    pub fn setFolded(self: *Element, folded: bool) void {
        switch (self.*) {
            .button => |*b| b.folded = folded,
            .link => |*l| l.folded = folded,
            else => {},
        }
    }

    pub fn isInteractive(self: Element) bool {
        return switch (self) {
            // A folded control is not on screen (see `Button.folded`),
            // so it is not a control either: the row's `more` stands in
            // for it, and nothing may reach past that to press it.
            .button => |b| !b.disabled and !b.in_progress and !b.folded,
            .link => |l| !l.folded,
            // The button's rule, for the two controls that also start
            // work: a flip whose result has not landed takes no second
            // press.
            .toggle => |t| !t.in_progress,
            .checkbox => |c| !c.in_progress,
            .text_input, .text_area, .segmented, .tile, .radio_group, .select, .copyable, .nav_item, .nav_current, .sheet_close, .back, .icon_button, .picker_item, .more => true,
            // Static content and containers. Enumerated rather than
            // defaulted: a new element must declare its answer here, or
            // it silently takes no press, no focus stop, and no place
            // in the a11y tree's interaction order.
            .text, .heading, .icon, .box, .divider, .badge, .meter, .qr, .stack, .list, .list_item, .code_block, .blockquote, .document, .table, .row, .cell, .scroll_region, .tile_group, .nav, .nav_here, .sheet, .notice, .notices_pane, .picker => false,
        };
    }

    pub fn isFocusable(self: Element) bool {
        return switch (self) {
            // Both scroll, so both need a keyboard route to their
            // hidden content. Neither activates: focusable, not
            // interactive.
            .scroll_region, .code_block => true,
            // The same split, for the other reason: a button whose work
            // is running cannot be pressed again, but it keeps its stop
            // so the keyboard user who just pressed it is not thrown
            // back to the top of the tab order. Only `disabled` — "not
            // yours to press at all" — takes the stop away.
            // Folded takes the stop the way `disabled` does, and for a
            // stronger reason: there is nothing there to land on.
            .button => |b| !b.disabled and !b.folded,
            // The same split again, and here it is the whole of it:
            // neither control has a `disabled` to take the stop away,
            // so busy is the only thing that stops them activating and
            // the stop always survives it.
            .toggle, .checkbox => true,
            else => self.isInteractive(),
        };
    }

    /// The accessible name. Interactive elements must have a non-empty
    /// one; `Tree.append` rejects them otherwise.
    pub fn label(self: Element) []const u8 {
        return switch (self) {
            .text => |t| t.content,
            .heading => |h| h.content,
            // Announced whole, as one node: a verbatim block is read
            // out, not navigated line by line.
            .code_block => |c| c.content,
            .document => |d| d.label,
            .icon => |i| i.label,
            .badge => |b| b.label,
            .meter => |m| m.label,
            .qr => |q| q.label,
            .button => |b| b.label,
            .link => |l| l.label,
            .toggle => |t| t.label,
            .checkbox => |c| c.label,
            .text_input => |i| i.label,
            .text_area => |a| a.label,
            .segmented => |s| s.label,
            .tile => |t| t.label,
            .radio_group => |r| r.label,
            .select => |s| s.label,
            .copyable => |c| c.label,
            .nav_item => |n| n.label,
            .sheet => |s| s.title,
            .sheet_close => |c| c.label,
            .back => |b| b.label,
            // Framework chrome, framework name — the section it is
            // showing is its value, not what it is called.
            .nav_current => |n| n.name,
            // The same split, for the marker that is not a section: the
            // route's title is its value (`NavHere`).
            .nav_here => |n| n.name,
            .notice => |n| n.title,
            .notices_pane => |p| p.title,
            .icon_button => |i| i.label,
            .picker => |p| p.title,
            .picker_item => |p| p.label,
            .more => |m| m.label,
            // Pure structure: no name of its own. Enumerated rather
            // than defaulted so a new element cannot ship a silently
            // empty accessible name.
            .box, .divider, .stack, .list, .list_item, .blockquote, .table, .row, .cell, .scroll_region, .tile_group, .nav => "",
        };
    }

    /// How a wrapped-prose element draws: the base face and ink its
    /// spans compose onto, the scale, and the bytes. Layout measures
    /// from this, the renderer draws from it, and hit testing places
    /// link spans with it — one home, so the three cannot disagree
    /// about a heading's face or a span's base ink. Null for everything
    /// that carries no wrapped prose.
    pub fn textRun(self: Element) ?TextRun {
        return switch (self) {
            .text => |t| .{
                .face = t.style.face(),
                .scale = t.style.scale,
                .ink = t.style.ink,
                .content = t.content,
                .spans = t.spans,
            },
            .heading => |h| .{
                .face = Heading.base_face,
                .scale = h.level.scale(),
                .ink = .ink,
                .content = h.content,
                .spans = h.spans,
            },
            else => null,
        };
    }

    /// The ink this element draws directly on the ambient background,
    /// or null if it paints its own (labeled button, segmented, nav) or
    /// renders nothing (whitespace-only text, containers).
    pub fn ambientTextInk(self: Element) ?color.Gray {
        return switch (self) {
            // Spanned text is judged run by run (append and the audit
            // check each span's effective ink); the element-level ink
            // may go unused entirely, so it is not gated here.
            .text => |t| if (t.spans.len > 0 or std.mem.trim(u8, t.content, " \t\n\r").len == 0) null else t.style.ink,
            .heading => |h| if (h.spans.len > 0) null else .ink,
            // The filled pill paints its own background; the glyph form
            // and the secondary outline draw ink on the ambient (disabled
            // they dim deliberately, as the pill's text does). Running
            // work does not dim: `in_progress` is busy, not unavailable,
            // and its `…` is the only sign the work is happening — so it
            // stays at full ink and gates like any other words.
            // A folded control paints nothing at all, so there is no
            // pair for the contrast gate to judge.
            .button => |b| if (b.folded) null else if ((b.form == .glyph or b.form.outlined()) and !b.disabled) .ink else null,
            .link => |l| if (l.folded) null else .ink,
            // Drawn as the outlined pill, so its words gate exactly like
            // a secondary button's.
            .more => .ink,
            // Decorative icons may be as quiet as they like; meaningful
            // (labeled) ones carry information and must stay legible.
            .icon => |i| if (i.label.len == 0) null else i.ink,
            // The item draws its own marker on the ambient; the words
            // beside it are their own elements and gate separately.
            .list_item => .ink,
            // Verbatim ink straight onto the ambient — it paints no
            // surface of its own, so it gates exactly like `text`.
            .code_block => |c| if (std.mem.trim(u8, c.content, " \t\n\r").len == 0) null else .ink,
            .badge, .meter, .qr, .toggle, .checkbox, .text_input, .text_area, .tile, .radio_group, .select, .copyable, .sheet_close, .back, .icon_button => .ink,
            .picker_item => .dark,
            // The group draws no text of its own unless described.
            .tile_group => |tg| if (tg.description.len == 0) null else .dark,
            // Containers draw no text; the plated surfaces (segmented,
            // nav and its markers, sheet, the notice layers, picker)
            // paint their own background, so their words are judged
            // where they are drawn. Enumerated rather than defaulted so
            // a new element cannot silently skip the contrast gate.
            .box, .divider, .stack, .list, .blockquote, .document, .table, .row, .cell, .scroll_region, .segmented, .nav, .nav_item, .nav_current, .nav_here, .sheet, .notice, .notices_pane, .picker => null,
        };
    }
};

const std = @import("std");

test "interactive implies focusable" {
    const btn: Element = .{ .button = .{ .label = "Go" } };
    try std.testing.expect(btn.isInteractive());
    try std.testing.expect(btn.isFocusable());

    const disabled: Element = .{ .button = .{ .label = "Go", .disabled = true } };
    try std.testing.expect(!disabled.isInteractive());
    try std.testing.expect(!disabled.isFocusable());

    const scroll: Element = .{ .scroll_region = .{ .height = 100 } };
    try std.testing.expect(!scroll.isInteractive());
    try std.testing.expect(scroll.isFocusable());
}

test "an in-progress button stops activating but keeps its focus stop" {
    const running: Element = .{ .button = .{ .label = "Save", .in_progress = true } };
    try std.testing.expect(!running.isInteractive());
    // The point of the state: focus stays where the user put it.
    try std.testing.expect(running.isFocusable());
    // `…` is what renders; the name never changes under a voice-control
    // user mid-action.
    try std.testing.expectEqualStrings("Save", running.label());

    // Disabled is the stronger statement and takes the stop away; the
    // pixels still say the work is running.
    const both: Element = .{ .button = .{ .label = "Save", .disabled = true, .in_progress = true } };
    try std.testing.expect(!both.isInteractive());
    try std.testing.expect(!both.isFocusable());

    // Busy is not unavailable: an outlined or glyph-form button keeps
    // full ink while it runs, so the gate still judges it.
    const outlined: Element = .{ .button = .{ .label = "Cancel", .form = .{ .secondary = null }, .in_progress = true } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), outlined.ambientTextInk());
    const glyph: Element = .{ .button = .{ .label = "Next cycle", .form = .{ .glyph = .chevron_right }, .in_progress = true } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), glyph.ambientTextInk());
}

test "a busy switch stops flipping but keeps its focus stop" {
    // The button's bargain, restated for the two controls that have no
    // `disabled` to be confused with: busy takes the press, never the
    // stop, and never the name.
    for ([_]Element{
        .{ .toggle = .{ .label = "Email me", .on = true, .in_progress = true } },
        .{ .checkbox = .{ .label = "Email me", .checked = true, .in_progress = true } },
    }) |busy| {
        try std.testing.expect(!busy.isInteractive());
        try std.testing.expect(busy.isFocusable());
        try std.testing.expectEqualStrings("Email me", busy.label());
        // Busy is not unavailable, so the words stay at full ink and
        // face the contrast gate exactly as they did at rest.
        try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), busy.ambientTextInk());
    }

    const resting: Element = .{ .toggle = .{ .label = "Email me" } };
    try std.testing.expect(resting.isInteractive());
}

test "six heading levels descend through six distinct sizes" {
    // Six levels need a size each, and the bold weight is what keeps h5
    // (body-sized) and h6 (small) reading as headings rather than prose.
    var last: i32 = 1 << 20;
    for ([_]HeadingLevel{ .h1, .h2, .h3, .h4, .h5, .h6 }) |level| {
        const px = level.scale().px();
        try std.testing.expect(px < last);
        last = px;
    }
    try std.testing.expect(Heading.base_face.bold);
    // The audit reads the level off the enum value, so it must stay the
    // outline depth, not an ordinal.
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(HeadingLevel.h6));
}

test "labels come from semantic fields" {
    const tg: Element = .{ .toggle = .{ .label = "Subscribe" } };
    try std.testing.expectEqualStrings("Subscribe", tg.label());
}

test "segmented and nav items are interactive; nav is not" {
    const seg: Element = .{ .segmented = .{ .label = "View", .options = &.{ "List", "Grid" } } };
    try std.testing.expect(seg.isInteractive());
    try std.testing.expectEqualStrings("View", seg.label());

    const item: Element = .{ .nav_item = .{ .label = "Home", .route = "home", .icon = .house } };
    try std.testing.expect(item.isFocusable());
    try std.testing.expectEqualStrings("Home", item.label());

    const nav: Element = .{ .nav = .{} };
    try std.testing.expect(!nav.isFocusable());
}

test "radio_group is interactive and carries its label" {
    const rg: Element = .{ .radio_group = .{ .label = "Delivery", .options = &.{ "Email", "SMS" } } };
    try std.testing.expect(rg.isInteractive());
    try std.testing.expect(rg.isFocusable());
    try std.testing.expectEqualStrings("Delivery", rg.label());
}

test "select and picker items are interactive; the picker itself is not" {
    const sel: Element = .{ .select = .{ .label = "Language", .options = &.{ "English", "Deutsch" } } };
    try std.testing.expect(sel.isInteractive());
    try std.testing.expect(sel.isFocusable());
    try std.testing.expectEqualStrings("Language", sel.label());

    const item: Element = .{ .picker_item = .{ .label = "English" } };
    try std.testing.expect(item.isInteractive());
    try std.testing.expectEqualStrings("English", item.label());

    const picker: Element = .{ .picker = .{ .title = "Language" } };
    try std.testing.expect(!picker.isInteractive());
    try std.testing.expectEqualStrings("Language", picker.label());
}

test "copyable is interactive and carries its label as ink text" {
    const c: Element = .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } };
    try std.testing.expect(c.isInteractive());
    try std.testing.expect(c.isFocusable());
    try std.testing.expectEqualStrings("Recovery code", c.label());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), c.ambientTextInk());
}

test "a badge's mark is decorative and never replaces its label" {
    // The chip announces its words and nothing else: `label()` is the
    // label with or without a mark, and the mark is a field, so no node
    // exists for it to be announced from.
    const marked: Element = .{ .badge = .{ .label = "Istanbul", .icon = .map_pin } };
    const bare: Element = .{ .badge = .{ .label = "Istanbul" } };
    try std.testing.expectEqualStrings(bare.label(), marked.label());
    try std.testing.expect(!marked.isInteractive());
    try std.testing.expect(!marked.isFocusable());
    // Same ink as the words it leads, so the mark reaches the contrast
    // gate at exactly the level the label already cleared.
    try std.testing.expectEqual(bare.ambientTextInk(), marked.ambientTextInk());
}

test "badges are static and carry their label as ink text" {
    const b: Element = .{ .badge = .{ .label = "Active" } };
    try std.testing.expect(!b.isInteractive());
    try std.testing.expect(!b.isFocusable());
    try std.testing.expectEqualStrings("Active", b.label());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), b.ambientTextInk());
}

test "meters are static and carry their words as ink text" {
    const m: Element = .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } };
    try std.testing.expect(!m.isInteractive());
    try std.testing.expect(!m.isFocusable());
    try std.testing.expectEqualStrings("12 of 30 days", m.label());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), m.ambientTextInk());
}

test "qr is static, carries its label as ink text, and reads packed modules" {
    // 2x2 grid packed LSB-first: bits 0 and 3 set → (0,0) and (1,1) dark.
    const q: Element = .{ .qr = .{ .label = "Invite link", .value = "x", .modules = &.{0b1001}, .size = 2 } };
    try std.testing.expect(!q.isInteractive());
    try std.testing.expect(!q.isFocusable());
    try std.testing.expectEqualStrings("Invite link", q.label());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), q.ambientTextInk());
    try std.testing.expect(q.qr.module(0, 0));
    try std.testing.expect(!q.qr.module(1, 0));
    try std.testing.expect(!q.qr.module(0, 1));
    try std.testing.expect(q.qr.module(1, 1));
}

test "spans resolve semantic flags to faces; code wins the family" {
    const strong: Span = .{ .text = "x", .strong = true };
    try std.testing.expectEqual(text.Face{ .family = .prose, .bold = true }, strong.face(.prose));

    const both: Span = .{ .text = "x", .strong = true, .emphasis = true };
    try std.testing.expectEqual(text.Face{ .family = .prose, .bold = true, .italic = true }, both.face(.prose));

    // Code is a voice, not a knob: it moves the run to mono wherever it is.
    const code: Span = .{ .text = "x", .code = true, .emphasis = true };
    try std.testing.expectEqual(text.Face{ .family = .mono, .italic = true }, code.face(.prose));
}

test "spanned text and headings hide their element ink from the ambient gate" {
    const spanned: Element = .{ .text = .{ .spans = &.{.{ .text = "x" }} } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, null), spanned.ambientTextInk());
    const plain: Element = .{ .text = .{ .content = "x" } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), plain.ambientTextInk());
}

test "icon names encode their own codepoint" {
    try std.testing.expectEqualStrings("\u{e585}", IconName.a_arrow_down.utf8());
    try std.testing.expectEqualStrings("\u{e1ec}", IconName.alarm_clock_check.utf8());
}

test "glyph-form buttons stay buttons and gate their ink like chrome" {
    const b: Element = .{ .button = .{ .label = "Next cycle", .form = .{ .glyph = .chevron_right } } };
    try std.testing.expect(b.isInteractive());
    try std.testing.expect(b.isFocusable());
    try std.testing.expectEqualStrings("Next cycle", b.label());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), b.ambientTextInk());

    const disabled: Element = .{ .button = .{ .label = "Next cycle", .form = .{ .glyph = .chevron_right }, .disabled = true } };
    try std.testing.expect(!disabled.isInteractive());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, null), disabled.ambientTextInk());

    // A pill carrying an icon still paints its own background: no gate.
    const pill: Element = .{ .button = .{ .label = "Add reminder", .form = .{ .filled = .alarm_clock_plus } } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, null), pill.ambientTextInk());

    // A secondary button draws ink on the ambient and gates like text.
    const sec: Element = .{ .button = .{ .label = "Cancel", .form = .{ .secondary = null } } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), sec.ambientTextInk());
    const sec_disabled: Element = .{ .button = .{ .label = "Cancel", .form = .{ .secondary = null }, .disabled = true } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, null), sec_disabled.ambientTextInk());
}

test "a provider button carries the vendor mark and the app's own words" {
    const b: Element = .{ .button = .{ .label = "Sign in with Apple", .form = .{ .provider = .apple } } };
    try std.testing.expect(b.isInteractive());
    try std.testing.expect(b.isFocusable());
    // The words are the app's — nokre ships the mark, never a
    // translation of the vendor's string.
    try std.testing.expectEqualStrings("Sign in with Apple", b.label());
    const localized: Element = .{ .button = .{ .label = "Mit Apple anmelden", .form = .{ .provider = .apple } } };
    try std.testing.expectEqualStrings("Mit Apple anmelden", localized.label());
    try std.testing.expectEqualStrings("\u{e900}", AuthProvider.apple.mark());
    // Google's mark answers with the first of its four arc glyphs —
    // the one layout measures; the colors live in the renderer.
    try std.testing.expectEqualStrings("\u{e901}", AuthProvider.google.mark());
    // Both Apple styles carry Apple's mark; the style names the pill,
    // the vendor names the artwork.
    try std.testing.expectEqual(AuthProvider.apple, Button.Form.Provider.apple_outlined.vendor());

    // Emphasis is spelled per vendor style rather than composed:
    // filled paints its own ground, Apple's outlined third draws ink
    // on the ambient and gates like text.
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, null), b.ambientTextInk());
    const outlined: Element = .{ .button = .{ .label = "x", .form = .{ .provider = .apple_outlined } } };
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), outlined.ambientTextInk());
}

test "icons are static; only labeled ones gate their ink" {
    const deco: Element = .{ .icon = .{ .name = .activity, .ink = .light } };
    try std.testing.expect(!deco.isInteractive());
    try std.testing.expect(!deco.isFocusable());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, null), deco.ambientTextInk());

    const meaningful: Element = .{ .icon = .{ .name = .accessibility, .label = "Accessible venue" } };
    try std.testing.expectEqualStrings("Accessible venue", meaningful.label());
    try std.testing.expectEqual(@as(?@import("color.zig").Gray, .ink), meaningful.ambientTextInk());
}

test "every icon name encodes its own codepoint" {
    // The generated set indexes one dense table by codepoint, so the ends
    // of that table are where an off-by-one would hide. Checking all of
    // them costs nothing and makes the invariant — the enum value IS the
    // codepoint the font maps — hold for the whole set rather than a
    // sample.
    for (std.enums.values(IconName)) |name| {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(@intFromEnum(name), &buf);
        try std.testing.expectEqualStrings(buf[0..len], name.utf8());
    }

    // The chrome's hand-written constants name the same glyphs by role
    // (`back_chevron` is chevron-left because back points there). Nothing
    // enforces that pairing but this: a regeneration that shifted a
    // codepoint would leave the two disagreeing and drawing tofu.
    try std.testing.expectEqualStrings(back_chevron, IconName.chevron_left.utf8());
    try std.testing.expectEqualStrings(tile_chevron, IconName.chevron_right.utf8());
}

test "bind synthesizes the trampoline: dispatch reaches the typed method" {
    // The generated fn must be indistinguishable from the hand-written
    // one it replaces: same ctx round-trip, same null-unwrap safety.
    const Counter = struct {
        hits: u32 = 0,
        fn bump(self: *@This()) void {
            self.hits += 1;
        }
    };
    var c: Counter = .{};
    const a: Action = .bind(Counter.bump, &c);
    try std.testing.expect(a.wired());
    a.invoke();
    a.invoke();
    try std.testing.expectEqual(@as(u32, 2), c.hits);
}

test "bindAt forwards the element's index as data" {
    // The index rides the element, not the function: two bindings of one
    // method must dispatch with their own rows.
    const Rows = struct {
        last: usize = 0,
        fn pick(self: *@This(), index: usize) void {
            self.last = index;
        }
    };
    var r: Rows = .{};
    const third: Action = .bindAt(Rows.pick, &r, 3);
    const seventh: Action = .bindAt(Rows.pick, &r, 7);
    third.invoke();
    try std.testing.expectEqual(@as(usize, 3), r.last);
    seventh.invoke();
    try std.testing.expectEqual(@as(usize, 7), r.last);
}

test "payload-carrying binds forward their payloads" {
    const Form = struct {
        on: bool = false,
        row: usize = 0,
        row_on: bool = false,
        text: []const u8 = "",
        choice: usize = 0,
        fn setOn(self: *@This(), checked: bool) void {
            self.on = checked;
        }
        fn setRowOn(self: *@This(), index: usize, checked: bool) void {
            self.row = index;
            self.row_on = checked;
        }
        fn edit(self: *@This(), value: []const u8) void {
            self.text = value;
        }
        fn choose(self: *@This(), selected: usize) void {
            self.choice = selected;
        }
    };
    var f: Form = .{};

    const toggle: ToggleAction = .bind(Form.setOn, &f);
    toggle.invoke(true);
    try std.testing.expect(f.on);

    // The indexed toggle shape carries both: which row, and to what.
    const row_toggle: ToggleAction = .bindAt(Form.setRowOn, &f, 5);
    row_toggle.invoke(true);
    try std.testing.expectEqual(@as(usize, 5), f.row);
    try std.testing.expect(f.row_on);

    const change: ChangeAction = .bind(Form.edit, &f);
    change.invoke("draft");
    try std.testing.expectEqualStrings("draft", f.text);

    const select: SelectAction = .bind(Form.choose, &f);
    select.invoke(2);
    try std.testing.expectEqual(@as(usize, 2), f.choice);
}
