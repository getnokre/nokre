//! nokre — a deliberately limited, deterministic, accessible GUI:
//! text, lines, and boxes. See README.md for the manifesto.

const std = @import("std");

/// The vendoring pin. Consumers reach nokre by bare relative path — a
/// sibling checkout, not a registry — so the checkout itself carries no
/// version a build can check, and a prose pin in a consumer's docs
/// drifts (two of them already disagreed when surveyed). This constant
/// is the one machine-checked statement of which nokre a consumer was
/// written against: assert it at comptime beside your app's declaration
/// and a mismatched checkout fails the build naming both numbers,
/// instead of failing at whatever call site the contract moved under.
/// Hand-bumped on every consumer-visible contract change, never by
/// machinery — the no-CI stance is deliberate
/// (docs/getting-started.md).
pub const revision: u32 = 34;

pub const geometry = @import("core/geometry.zig");
pub const color = @import("core/color.zig");
pub const bidi = @import("core/bidi.zig");
pub const text = @import("core/text.zig");
pub const element = @import("core/element.zig");
pub const load = @import("core/load.zig");
pub const gate = @import("core/gate.zig");
pub const bounded = @import("core/bounded.zig");
pub const tree = @import("core/tree.zig");
pub const cursor = @import("core/cursor.zig");
pub const layout = @import("core/layout.zig");
pub const wrap = @import("core/wrap.zig");
pub const event = @import("core/event.zig");
pub const focus = @import("core/focus.zig");
pub const router = @import("core/router.zig");
pub const app = @import("core/app.zig");

pub const render = struct {
    pub const canvas = @import("render/canvas.zig");
    pub const renderer = @import("render/renderer.zig");
    pub const skia = @import("render/skia/canvas_skia.zig");
    /// The DOM edition: the same tree walk, writing markup instead of
    /// draw calls. Pure Zig, links nothing
    /// (docs/internals/dom-edition.md).
    pub const dom = @import("render/dom/dom.zig");
    /// That edition's live driver: the browser half, exported to
    /// JavaScript. wasm32 only, and forced into the build by the block
    /// below — it is what `zig build web` produces.
    pub const dom_live = @import("render/dom/live.zig");
};

pub const a11y = struct {
    pub const semantics = @import("a11y/semantics.zig");
    pub const accesskit = @import("a11y/accesskit.zig");
};

pub const platform = @import("platform/platform.zig");

/// Long-lived compute actors off the UI thread: typed messages in,
/// typed replies out, handlers on the UI thread. Contract and rationale
/// in docs/internals/workers.md.
pub const workers = @import("workers/workers.zig");

/// A bounded FIFO in front of a single-flight port: submissions past
/// the one in flight wait their turn, a full queue refuses at the
/// call. The contract lives on the module (core/queue.zig).
pub const Queue = @import("core/queue.zig").Queue;

/// ARB message catalogs compiled at comptime: @embedFile the .arb
/// sources, get typed keys, per-locale CLDR plural validation, and
/// call-site-checked placeholders. Pure module, no state, no linking.
/// Contract and rationale in docs/localization.md.
pub const l10n = @import("l10n/l10n.zig");

// The web shell has no blocking run() — the browser drives its wasm
// exports instead — so nothing in a consumer's code reaches it and lazy
// analysis would drop the export block. Force it into every wasm build.
// secure_store's seed exports have the same problem when linked: its
// web leg is reached by nothing on the consumer side, so force the
// service too — through its own linked comptime block, which lands on
// the web exports — while unlinked builds keep exporting nothing.
comptime {
    if (@import("builtin").cpu.arch == .wasm32) {
        // The web's driver is reached by nothing on the consumer side
        // — the browser drives its exports — so lazy analysis would
        // drop it. Force it in.
        _ = render.dom_live;
    }
    if (@import("nokre_secure_store_options").linked) _ = services.secure_store;
    if (@import("nokre_deep_link_options").linked) _ = services.deep_link;
    if (@import("nokre_oauth_options").linked) _ = services.oauth;
    if (@import("nokre_iap_options").linked) _ = services.iap;
    // locale has no linked/unlinked split to gate on — it is always
    // present — so it is forced unconditionally; its own comptime block
    // is where the per-target install path and the web exports get
    // analyzed, and nothing else on the consumer side reaches them.
    _ = services.locale;
}

// Optional per-platform capabilities (docs/services.md). Like the
// shells, services bind extern symbols, so unit tests never reference
// them; an unlinked service is a comptime error at its call site.
// http is the exception on both counts: like workers it needs no
// linking (unreferenced, it costs nothing), and its native transport
// is pure std, so tests may reference it freely. secure_store binds
// externs when linked, but its test path is the per-app fake — the
// only path compiled under `zig test` — so tests may reference it too.
// locale, open_url, share, and clock are the other exceptions: they
// link nothing at all — no framework, no entitlement, no identity — so
// none has an options module or an unlinked error to raise; each rides
// whatever shell is there (clipboard's posture). open_url's one
// refusal — the scheme allowlist — and share's caps are pure functions
// of the argument, checked before any OS call; share's platform gap
// (no sheet on the Linux desktop) is a runtime `available`, iap's
// shape, not a link-time one. clock rides no shell at all: its native
// legs are the OS call Zig already declares and its web leg is one
// services.js import, so tests reference it as freely as http.
pub const services = struct {
    /// The one failure shape http, oauth, and iap all answer with —
    /// each module's `Failure` is this type, so a consumer's shared
    /// failure surface names `nokre.services.Failure` once.
    pub const Failure = @import("services/services.zig").Failure;
    pub const package_info = @import("services/package_info/package_info.zig");
    pub const http = @import("services/http/http.zig");
    pub const secure_store = @import("services/secure_store/secure_store.zig");
    pub const deep_link = @import("services/deep_link/deep_link.zig");
    pub const locale = @import("services/locale/locale.zig");
    pub const oauth = @import("services/oauth/oauth.zig");
    pub const open_url = @import("services/open_url/open_url.zig");
    pub const share = @import("services/share/share.zig");
    pub const clock = @import("services/clock/clock.zig");
    pub const iap = @import("services/iap/iap.zig");
    pub const notification = @import("services/notification/notification.zig");
};

pub const testing = @import("testing/harness.zig");

// Convenience re-exports: the names consumers use daily.
pub const App = app.App;
pub const Tree = tree.Tree;
pub const NodeId = tree.NodeId;
pub const Element = element.Element;
/// What an element *is*, as the a11y tree and every query see it —
/// `Element`'s tag. Beside `Element` because it is the same fact read
/// from the other side, and because a driver's own `press(role, label)`
/// wrapper has to name it.
pub const Role = element.Role;
/// The callback pair every control's `on_press`-shaped field holds, and
/// the type a consumer's own controller writes when it carries one
/// forward (`on_created: h.Action = .{}` — nineteen such fields across
/// the two real apps). Fill it with `.bind`; `bindAs` below is the same
/// generator for a pair nokre did not declare.
pub const Action = element.Action;
/// One run of inline text: words plus what they are — emphasis, code, a
/// route, an external destination. Written by anything that composes
/// rich text, which is why it is the element type most often aliased at
/// the top of a consumer's module (`IconName`'s argument, span-shaped).
pub const Span = element.Span;
/// The builder cursor: one method per element, standing where children
/// go. Sugar over `Tree.append` — the raw API stays the substrate
/// (core/cursor.zig). Builders start from `App.root()`; a sheet's
/// subtree from `App.at(presentSheet(...))`.
pub const Cursor = cursor.Cursor;
/// The four-phase async-value vocabulary (`idle`/`loading`/`ready`/
/// `failed`). Pure data nokre never reads — apps write it, their
/// screens read it, and `Cursor.loadGate` renders the not-ready states
/// (core/load.zig).
pub const Load = load.Load;
/// The one-shot in-flight latch: `begin` refuses the second press,
/// `end` lowers, `up` is what a builder feeds to `in_progress`. `Load`'s
/// mutation twin, and pure data nokre never reads — a latch, not a
/// machine (core/gate.zig).
pub const Gate = gate.Gate;
/// A string the consumer owns, up to `cap` bytes — the landing place
/// for a slice borrowed for the length of a callback. Truncates at the
/// ceiling without splitting a codepoint, and says when it did
/// (core/bounded.zig).
pub const Str = bounded.Str;
/// A bounded list of rows the consumer owns: `push`/`fill` in a reply
/// handler, `items` in the screen, and `truncated` when the reply had
/// more than fits. Pure data nokre never reads, like `Load` — the
/// phase stays a field beside the list (core/bounded.zig).
pub const Rows = bounded.Rows;
/// Every Lucide glyph a consumer can place, named. Daily now that a
/// `tile` carries a mark as well as a button, a notice and a
/// destination: an app that picks its glyphs once, by meaning, in one
/// module writes this type on every line of it.
pub const IconName = element.IconName;
/// A nav destination as consumers declare it: a route and a glyph. The
/// label is the route's own `RouteDef.title` (`App.setNav`).
pub const Destination = @import("core/nav.zig").Destination;
pub const Event = event.Event;
pub const RouteDef = router.RouteDef;
/// The route table with its state typed once instead of at every screen:
/// `Routes(State).table` lowers builders written `fn (state: *State, app:
/// *App) !void` into ordinary `RouteDef`s (core/router.zig).
pub const Routes = router.Routes;
/// Builds any `{ ctx: ?*anyopaque, call: *const fn (?*anyopaque, …) R }`
/// pair from a typed handler — `Action.bind`'s generator, open to the
/// callback types a consumer or a nokre-free domain package declares for
/// itself (core/bind.zig).
pub const bindAs = @import("core/bind.zig").bindAs;
/// A sheet declared as data: what `App.openSheet` takes, and the
/// framework re-runs on reload. The everyday door is `App.openSheetAs`,
/// which fills this from a typed name and a bound builder; the struct
/// itself is for the sheet that also owes work when it closes
/// (`on_dismiss`) — core/overlays.zig.
pub const SheetBuilder = app.App.SheetBuilder;
pub const Gray = color.Gray;
pub const Scheme = color.Scheme;
pub const Appearance = color.Appearance;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Canvas = render.canvas.Canvas;

test {
    // Reference only pure modules: skia bindings and platform shells
    // contain extern symbols that unit tests must not link against.
    _ = geometry;
    _ = color;
    _ = bidi;
    _ = text;
    _ = element;
    _ = @import("core/bind.zig");
    _ = load;
    _ = gate;
    _ = bounded;
    _ = tree;
    _ = cursor;
    _ = layout;
    _ = wrap;
    _ = event;
    _ = focus;
    _ = router;
    _ = app;
    _ = render.canvas;
    _ = render.dom;
    _ = render.renderer;
    _ = a11y.semantics;
    _ = a11y.accesskit;
    _ = workers;
    _ = @import("core/queue.zig");
    _ = l10n;
    _ = testing;
    _ = testing.queries;
    _ = testing.driver;
    _ = testing.audit;
    _ = testing.golden;
    _ = testing.trace;
    _ = testing.wait;
    _ = testing.device;
    // Unlike the platform shells this one is safe to name here: it
    // *defines* the shell symbols (`export`) rather than referencing
    // them (`extern`), and under `zig test` no other definition exists
    // to collide with — the mocks are the only service path.
    _ = testing.shell;
    // Test suites for the larger modules live in sibling *_test.zig files.
    _ = @import("core/app_test.zig");
    _ = @import("core/bidi_test.zig");
    _ = @import("core/input_test.zig");
    _ = @import("core/layout_test.zig");
    _ = @import("core/markdown_test.zig");
    _ = @import("core/cursor_test.zig");
    _ = @import("core/router_test.zig");
    _ = @import("core/tree_test.zig");
    _ = @import("core/wrap_test.zig");
    _ = @import("render/renderer_test.zig");
    _ = @import("render/dom/serialize_test.zig");
    _ = @import("render/dom/document_test.zig");
    _ = @import("a11y/semantics_test.zig");
    _ = @import("testing/audit_test.zig");
    _ = @import("testing/harness_test.zig");
    _ = @import("testing/device_test.zig");
    _ = @import("workers/workers_test.zig");
    _ = @import("l10n/l10n_test.zig");
    _ = @import("services/http/http_test.zig");
    // The one suite that runs a transport instead of the mock — a
    // loopback origin in this process — so it is host-only.
    if (@import("builtin").cpu.arch != .wasm32) _ = @import("services/http/native_test.zig");
    _ = @import("services/secure_store/secure_store_test.zig");
    _ = @import("services/deep_link/deep_link_test.zig");
    _ = @import("services/locale/locale_test.zig");
    _ = @import("services/clock/clock_test.zig");
    _ = @import("services/oauth/oauth_test.zig");
    _ = @import("services/iap/iap_test.zig");
    _ = @import("services/notification/notification_test.zig");
    _ = @import("services/services_test.zig");
    // Build-time only (consumed by build.zig, never compiled into
    // apps), but its goldens run with everything else's.
    _ = @import("packaging/packaging_test.zig");
    // The declared Apple icon keeps its tests inline, and build.zig is
    // its only consumer — no golden reaches the module, so it is named
    // here or it is never analyzed.
    _ = @import("packaging/apple_icon.zig");
}
