//! nokre — a deliberately limited, deterministic, accessible GUI:
//! text, lines, and boxes. See README.md for the manifesto.

const std = @import("std");

pub const geometry = @import("core/geometry.zig");
pub const color = @import("core/color.zig");
pub const bidi = @import("core/bidi.zig");
pub const text = @import("core/text.zig");
pub const element = @import("core/element.zig");
pub const tree = @import("core/tree.zig");
pub const layout = @import("core/layout.zig");
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
};

pub const testing = @import("testing/harness.zig");

// Convenience re-exports: the names consumers use daily.
pub const App = app.App;
pub const Tree = tree.Tree;
pub const NodeId = tree.NodeId;
pub const Element = element.Element;
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
    _ = tree;
    _ = layout;
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
    _ = l10n;
    _ = testing;
    _ = testing.queries;
    _ = testing.driver;
    _ = testing.audit;
    _ = testing.golden;
    _ = testing.trace;
    // Test suites for the larger modules live in sibling *_test.zig files.
    _ = @import("core/app_test.zig");
    _ = @import("core/bidi_test.zig");
    _ = @import("core/layout_test.zig");
    _ = @import("core/markdown_test.zig");
    _ = @import("core/tree_test.zig");
    _ = @import("render/renderer_test.zig");
    _ = @import("render/dom/serialize_test.zig");
    _ = @import("a11y/semantics_test.zig");
    _ = @import("testing/audit_test.zig");
    _ = @import("testing/harness_test.zig");
    _ = @import("workers/workers_test.zig");
    _ = @import("l10n/l10n_test.zig");
    _ = @import("services/http/http_test.zig");
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
