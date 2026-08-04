//! The DOM edition's live driver: the same walk, in a browser, patching
//! a real document.
//!
//! The static driver runs at build time and writes files. This one runs
//! the app — the identical `App`, the identical tree, the identical
//! serializer — and re-renders when state changes. Together they are
//! one page's whole life: markup a browser can show before any script
//! arrives, and the same markup kept live once it does.
//!
//! It links no Skia and no emscripten. `wasm32-freestanding` and
//! `std.heap.wasm_allocator` are the entire platform requirement, which
//! is what makes the bundle a fraction of the canvas shell's — the
//! rasterizer this edition needs is the one already in the browser.
//!
//! ## The event flow is inverted, deliberately
//!
//! [renderer-editions.md](../../../docs/internals/renderer-editions.md)
//! flagged this and deferred it: "Edition-owned layout is possible but
//! inverts the event flow — the backend would resolve hits and deliver
//! semantic events — and is deliberately deferred until an edition
//! actually needs different spatial arrangement." This edition is that
//! case, and the inversion is not optional here: the browser lays the
//! page out, so core's rects describe a geometry the reader is not
//! looking at, and hit testing against them would be answering about
//! the wrong picture.
//!
//! So the browser resolves the hit and this hands core a *semantic*
//! event: activate this node, focus that one. Everything downstream —
//! what activation means, what a key does to a field, which subtree a
//! route rebuilds — is core's, unchanged. Only the question "which
//! element did the user mean" is answered somewhere else, by the thing
//! that drew it.
//!
//! What the browser also keeps is scrolling. The content is real, so a
//! `scroll_region` is a real scroll container and the page is a real
//! page; no offset round-trips through wasm, and a `scroll_region`'s
//! `offset` simply goes unread on this edition.
//!
//! ## The consumer contract
//!
//! The same one the canvas shell states: the root module exports
//! `nokreWebBuild(gpa) !*App`, because on the web the browser is
//! already mid-event-loop when the module instantiates and `main` never
//! runs. An app written for one web edition boots on the other with no
//! edit.
//!
//! Two more decls, both optional, and both only meaningful to a driver
//! mounted over a page the *static* driver already wrote:
//!
//! - `nokreWebRefs(*App) dom.Refs` — how a route reference becomes an
//!   `href`. A live app that owns the whole page leaves it out and gets
//!   the fragment the address bar mirrors routes into; one whose screens
//!   are published as files installs the same resolver that wrote them,
//!   so a re-render cannot rewrite a link the file already has.
//! - `nokreWebSeed([]const u8) void` — the bytes the host page hands the
//!   app before its first build. A screen built from content that is
//!   *not* compiled in has to answer for it synchronously, the way a
//!   locale read inside the first `build` does (services/locale/web.zig
//!   states that ordering at length), so this lands strictly before
//!   `boot` and the app keeps whatever it needs of it.

const std = @import("std");
const builtin = @import("builtin");

const app_mod = @import("../../core/app.zig");
const router_mod = @import("../../core/router.zig");
const editing = @import("../../core/editing.zig");
const element_mod = @import("../../core/element.zig");
const event_mod = @import("../../core/event.zig");
const focus_mod = @import("../../core/focus.zig");
const layout = @import("../../core/layout.zig");
const text_mod = @import("../../core/text.zig");
const http_web = @import("../../services/http/web.zig");
const dom = @import("dom.zig");
const tree_mod = @import("../../core/tree.zig");
const workers_post = @import("../../workers/post.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

const gpa = std.heap.wasm_allocator;

/// What the browser says a run is worth, in whole logical pixels.
///
/// Every measured decision core makes runs through here: where a
/// paragraph wraps, whether a nav roster fits its row, whether a row of
/// actions has to fold. The harness's stand-in charges three fifths of
/// the size per codepoint, which is fine for a test and wrong for a
/// page — it overcharges proportional text badly enough to collapse a
/// nav that would have fitted. The browser is the thing that will
/// actually draw the run, so it is the thing to ask.
///
/// Asked *when*, though, is the glue's problem and a real one: a face
/// that has not arrived yet is answered for by whatever the browser
/// fell back to. `services.js` holds the answers only as long as the
/// font set they were measured against, and the driver re-reports the
/// viewport when that set changes — so a decision made against a
/// fallback is retaken rather than kept.
extern fn nokre_dom_measure(family: u32, bold: u32, italic: u32, size: i32, ptr: [*]const u8, len: usize) i32;

fn measure(_: ?*anyopaque, face: text_mod.Face, size_px: i32, bytes: []const u8) i32 {
    return nokre_dom_measure(
        @intFromEnum(face.family),
        @intFromBool(face.bold),
        @intFromBool(face.italic),
        size_px,
        bytes.ptr,
        bytes.len,
    );
}

const browser_measurer: text_mod.Measurer = .{ .measureFn = measure };

var app: *App = undefined;
var booted = false;
/// The markup of the last frame. Held so `nokre_dom_render` can hand
/// out a stable pointer, and so the glue can skip a DOM write when the
/// bytes did not move.
var markup: std.ArrayList(u8) = .empty;
/// The frame under construction. `render` serializes into this and
/// swaps it with `markup` only when the walk completes: a serializer
/// error mid-emit — OOM, on this allocator — must leave the shown
/// document the previous *complete* frame, never a truncated one that
/// ends mid-element. Two buffers that trade places, so the steady
/// state allocates nothing.
var building: std.ArrayList(u8) = .empty;
/// How much of that frame is chrome. The two halves are written into
/// one buffer by one walk, and a host document that placed them in two
/// places of its own splits there — `dom.chrome` and
/// `dom.content` are already separate for that reason.
var chrome_bytes: usize = 0;
/// One string per event — text, a route reference — written by the glue
/// before it calls the export that reads it.
var scratch: std.ArrayList(u8) = .empty;
/// The seed the host page handed over, copied out of the scratch that
/// carried it: the scratch is one event's buffer and the app is going
/// to read this inside a build, long after the call that delivered it.
var seed: std.ArrayList(u8) = .empty;
/// The app's own answer to "where does this screen live". Null until
/// boot, because it takes the `*App` the root builds.
var refs: ?dom.Refs = null;
/// One href, for the glue to read back out of; `nokre_dom_href`.
var href_out: std.ArrayList(u8) = .empty;
/// Whether the last frame's screen has chrome under it.
var reserve = false;

comptime {
    if (builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding) {
        @export(&boot, .{ .name = "nokre_dom_boot" });
        @export(&seedBytes, .{ .name = "nokre_dom_seed" });
        @export(&render, .{ .name = "nokre_dom_render" });
        @export(&renderLen, .{ .name = "nokre_dom_render_len" });
        @export(&chromeLen, .{ .name = "nokre_dom_chrome_len" });
        @export(&chromed, .{ .name = "nokre_dom_chromed" });
        @export(&href, .{ .name = "nokre_dom_href" });
        @export(&hrefLen, .{ .name = "nokre_dom_href_len" });
        @export(&scratchPtr, .{ .name = "nokre_dom_scratch" });
        @export(&press, .{ .name = "nokre_dom_press" });
        @export(&setFocus, .{ .name = "nokre_dom_focus" });
        @export(&selectOption, .{ .name = "nokre_dom_select" });
        @export(&keyDown, .{ .name = "nokre_dom_key" });
        @export(&text, .{ .name = "nokre_dom_text" });
        @export(&imeUpdate, .{ .name = "nokre_dom_ime_update" });
        @export(&imeCommit, .{ .name = "nokre_dom_ime_commit" });
        @export(&imeCancel, .{ .name = "nokre_dom_ime_cancel" });
        @export(&navigate, .{ .name = "nokre_dom_navigate" });
        @export(&back, .{ .name = "nokre_dom_back" });
        @export(&resize, .{ .name = "nokre_dom_resize" });
        @export(&systemAppearance, .{ .name = "nokre_dom_system_appearance" });
        @export(&appearance, .{ .name = "nokre_dom_appearance" });
        @export(&direction, .{ .name = "nokre_dom_direction" });
        @export(&route, .{ .name = "nokre_dom_route" });
        @export(&routeLen, .{ .name = "nokre_dom_route_len" });
        @export(&routeMotion, .{ .name = "nokre_dom_route_motion" });
        @export(&focusedNode, .{ .name = "nokre_dom_focused_node" });
        @export(&focusedSpan, .{ .name = "nokre_dom_focused_span" });
        @export(&caret, .{ .name = "nokre_dom_caret" });

        // The service ferry, under the names the canvas shell exports
        // them by. These are not the edition's — they are the doorway
        // a linked service's web leg lands through, and an edition has
        // no opinion about http or a compute worker. One name, so glue
        // written against either build says the same thing.
        @export(&workerScratch, .{ .name = "nokre_worker_scratch" });
        @export(&workerBoot, .{ .name = "nokre_worker_boot" });
        @export(&workerHandle, .{ .name = "nokre_worker_handle" });
        @export(&workerDeliver, .{ .name = "nokre_worker_deliver" });
        @export(&workerDied, .{ .name = "nokre_worker_died" });
        @export(&httpScratch, .{ .name = "nokre_http_scratch" });
        @export(&httpDeliver, .{ .name = "nokre_http_deliver" });
        @export(&httpFail, .{ .name = "nokre_http_fail" });
    }
}

/// `route_len` bytes of the scratch name the screen this document is,
/// or zero for a page that is the app itself and starts wherever
/// `nokreWebBuild` left it. It is a boot argument rather than a
/// navigation afterwards because a generated page already *shows* that
/// screen: switching to it after the first frame would mean building —
/// and painting — a screen nobody asked for on the way past.
fn boot(w: i32, h: i32, route_len: usize) callconv(.c) i32 {
    const root = @import("root");
    if (comptime !@hasDecl(root, "nokreWebBuild")) return 0;
    if (booted) return 1;
    app = root.nokreWebBuild(gpa) catch return 0;
    // The address bar is this platform's place to show the current
    // screen (docs/routing.md), and *which motion* put the app there
    // is the router's to say, not this driver's to infer: a pushed
    // screen adds a history entry and nothing else does.
    app.router.installObserver(null, onRoute);
    // Before the viewport, so the resync `setViewport` does already has
    // real widths to decide the nav's shape with.
    app.setMeasurer(browser_measurer);
    app.setViewport(.{ .w = w, .h = h });
    // `switchTo`, for the reason `navigate` gives: arriving by
    // reference resets the stack, and a reader who typed a URL has
    // nothing behind them. Vetted, because switchTo no longer errors on
    // a bad reference (router.zig) and this one is the site manifest's
    // — a wrong one should fail the boot loudly, not paint a screen
    // with nothing on it.
    if (route_len != 0) {
        const reference = scratch.items[0..route_len];
        if (app.router.vet(reference) != null) return 0;
        app.router.switchTo(app, reference) catch return 0;
    }
    if (comptime @hasDecl(root, "nokreWebRefs")) refs = root.nokreWebRefs(app);
    booted = true;
    return 1;
}

/// The host page's bytes, before boot. What they *are* is the app's
/// business — this holds them and hands them over, which is the whole
/// of the mechanism.
fn seedBytes(len: usize) callconv(.c) void {
    const root = @import("root");
    if (comptime !@hasDecl(root, "nokreWebSeed")) return;
    // Before boot or not at all: the app holds this slice for as long
    // as it holds anything built from it, and a second seed would move
    // the buffer under whatever kept the first.
    if (booted) return;
    seed.clearRetainingCapacity();
    seed.appendSlice(gpa, scratch.items[0..len]) catch return;
    root.nokreWebSeed(seed.items);
}

/// The screen and its chrome, as one document fragment. Returns the
/// pointer; `nokre_dom_render_len` is its length.
///
/// Whole-screen serialize, per-node write. nokre rebuilds subtrees
/// instantly and has no animation to preserve, so "build it again" is
/// the model rather than a shortcut — and the glue holds the last
/// frame's bytes and does nothing when the new one matches, which is
/// the case a frame usually is. A frame that differs is not swapped in
/// wholesale either: the glue patches the shown document against this
/// markup node by node, under the same identity rule the hydration
/// handover uses — same tag, same `data-n`, same node — so the write is
/// proportional to what changed even though the serialization never is.
///
/// `wrap` asks for the driver's own `<main>` around the screen. A page
/// that has one already — a generated file keeping its id, its class
/// and the skip link that names it — passes 0 and reads the two halves
/// out separately at `nokre_dom_chrome_len`, which is the same seam
/// `content` / `chrome` are split at for the static driver.
fn render(wrap: i32) callconv(.c) [*]const u8 {
    // The glue attaches its DOM listeners before boot completes (the
    // seed fetch is awaited in between), so every event export — and
    // this one, which they all funnel into — guards on `booted`: before
    // it, `app` is undefined memory, the workerDeliver rule.
    if (!booted) return markup.items.ptr;
    // Layout first, even though not one rect of it is read here.
    //
    // Geometry stays in core, and core does more than place boxes with
    // it: the pass is where a row of actions that has run out of width
    // gives up its tail, marking the buttons that folded and installing
    // the `more` control that stands in for them (overflow.zig). Chrome
    // the framework installs during layout simply does not exist in a
    // tree that was never laid out — so this edition ran without it,
    // and a narrow window quietly lost its actions instead of folding
    // them.
    app.performLayout();
    building.clearRetainingCapacity();
    var em: dom.Emitter = .{
        .gpa = gpa,
        .app = app,
        .out = &building,
        .options = .{ .node_ids = true, .refs = refs orelse .{} },
    };
    defer em.deinit();
    if (buildFrame(&em, wrap)) |frame| {
        std.mem.swap(std.ArrayList(u8), &markup, &building);
        chrome_bytes = frame.chrome_bytes;
        reserve = frame.reserve;
        // Only on success: a frame that failed to build is still owed,
        // and the one showing is the previous one.
        app.needs_frame = false;
    } else |_| {}
    return markup.items.ptr;
}

/// One whole frame into `em.out`, or an error and a buffer of no
/// further interest — `render` shows nothing that did not come out of
/// the success arm, which is the entire point of building off to the
/// side.
fn buildFrame(em: *dom.Emitter, wrap: i32) !struct { chrome_bytes: usize, reserve: bool } {
    try dom.chrome(em);
    const chrome_len = em.out.items.len;
    // The bottom reserve is `trailingSpace`'s question: a screen with
    // no chrome under it keeps the stack's own padding, and only one
    // that has some owes the clear space a control needs. Reserving it
    // unconditionally left every plain screen ending in 96px of
    // nothing.
    const chromed_screen = layout.hasBottomChrome(&app.tree);
    if (wrap != 0) try em.raw(if (chromed_screen) "<main class=\"nokre has-chrome\">" else "<main class=\"nokre\">");
    try dom.content(em);
    if (wrap != 0) try em.raw("</main>");
    return .{ .chrome_bytes = chrome_len, .reserve = chromed_screen };
}

fn renderLen() callconv(.c) usize {
    return markup.items.len;
}

fn chromeLen() callconv(.c) usize {
    return chrome_bytes;
}

/// Whether the screen owes the clear space bottom chrome needs — the
/// `has-chrome` class, for a host document that wrote the `<main>` this
/// driver would otherwise have put it on. The answer is layout's either
/// way; only who writes it down changes.
fn chromed() callconv(.c) i32 {
    return @intFromBool(reserve);
}

/// Where a screen lives, asked of the same `Refs` that wrote every
/// href in the markup. The address bar is a driver's to keep true and
/// the mapping is the app's to state, so this is how one reaches the
/// other — a second copy of it in the glue is a second place for a URL
/// to be wrong.
fn href(len: usize) callconv(.c) [*]const u8 {
    href_out.clearRetainingCapacity();
    if (!booted) return href_out.items.ptr;
    var em: dom.Emitter = .{ .gpa = gpa, .app = app, .out = &href_out };
    defer em.deinit();
    const r: dom.Refs = refs orelse .{};
    r.write(r.ctx, &em, scratch.items[0..len]) catch {};
    return href_out.items.ptr;
}

fn hrefLen() callconv(.c) usize {
    return href_out.items.len;
}

/// The buffer the glue writes a string into before calling the export
/// that consumes it. One event carries at most one string, so one
/// scratch suffices — the canvas shell's arrangement, for its reason.
/// Null on OOM, `workerScratch`'s shape: the glue skips the write, where
/// a pointer to nothing would invite one at address 0.
fn scratchPtr(len: usize) callconv(.c) ?[*]u8 {
    scratch.clearRetainingCapacity();
    scratch.resize(gpa, len) catch return null;
    return scratch.items.ptr;
}

/// One press, one call. Which element the reader meant is the only
/// thing this driver knows better than core; the rest — the focus it
/// moves, what activation means, the latches an input releases — is
/// `App.deliver`'s, and re-stating any of it here would be a second
/// copy of a rule that has one home.
fn press(packed_id: u32, span: i32) callconv(.c) void {
    if (!booted) return;
    app.deliver(.{ .press = stopOf(packed_id, span) }) catch {};
}

fn setFocus(packed_id: u32, span: i32) callconv(.c) void {
    if (!booted) return;
    const stop = stopOf(packed_id, span);
    if (app.tree.getConst(stop.node) == null) return;
    app.deliver(.{ .focus = stop }) catch {};
}

fn selectOption(packed_id: u32, index: u32) callconv(.c) void {
    if (!booted) return;
    app.deliver(.{ .select = .{ .node = @bitCast(packed_id), .index = index } }) catch {};
}

/// A node, plus which of its inline links was meant. An element is a
/// stop as a whole; only `text` and `heading` carry link spans.
fn stopOf(packed_id: u32, span: i32) focus_mod.Focus {
    const id: NodeId = @bitCast(packed_id);
    return if (span < 0) .of(id) else .{ .node = id, .span = @intCast(span) };
}

fn keyDown(key: u32, mods: u8) callconv(.c) void {
    if (!booted) return;
    const count = @typeInfo(event_mod.Key).@"enum".fields.len;
    if (key >= count) return;
    app.dispatch(.{ .key_down = .{
        .key = @enumFromInt(key),
        .mods = @bitCast(mods),
    } }) catch {};
}

fn text(len: usize) callconv(.c) void {
    if (!booted) return;
    app.dispatch(.{ .text = .{ .bytes = scratch.items[0..len] } }) catch {};
}

// The composition protocol, on the three legs every shell sends
// (docs/internals/platform-shells.md): the preedit streams as updates,
// and the session resolves as a commit or a cancel. No start leg — no
// shell sends one, because the first update opens the composition and
// `handleIme` treats them alike.

fn imeUpdate(len: usize, cursor: usize) callconv(.c) void {
    if (!booted) return;
    app.dispatch(.{ .ime = .{ .update = .{ .composition = scratch.items[0..len], .cursor = cursor } } }) catch {};
}

fn imeCommit(len: usize) callconv(.c) void {
    if (!booted) return;
    app.dispatch(.{ .ime = .{ .commit = .{ .text = scratch.items[0..len] } } }) catch {};
}

fn imeCancel() callconv(.c) void {
    if (!booted) return;
    app.dispatch(.{ .ime = .cancel }) catch {};
}

/// An inbound reference: a link the glue intercepted, or an address bar
/// the reader typed into. `switchTo`, because arriving by reference
/// resets the stack — one screen, one URL, and nothing behind you
/// (docs/routing.md). A reference the router cannot honor leaves the
/// app where it is, which is why the glue puts the bar back — and the
/// bar's bytes are a stranger's, so they are vetted at this door and
/// never reach the router's programmer-error record (router.zig).
fn navigate(len: usize) callconv(.c) i32 {
    if (!booted) return 0;
    const reference = scratch.items[0..len];
    if (app.router.vet(reference) != null) return 0;
    app.router.switchTo(app, reference) catch return 0;
    return 1;
}

fn back() callconv(.c) void {
    if (!booted) return;
    app.navigateBack() catch {};
}

fn resize(w: i32, h: i32) callconv(.c) void {
    if (!booted) return;
    app.setViewport(.{ .w = w, .h = h });
}

/// What the OS says, reported the way every native shell reports it
/// (`on_appearance` in platform/shell.h). It is not the answer — an app
/// pinned to light stays light on a dark desktop — it is the input
/// `Scheme.auto` resolves through, and core owns the resolution here as
/// it does everywhere else.
fn systemAppearance(dark: i32) callconv(.c) void {
    if (!booted) return;
    app.setSystemAppearance(if (dark != 0) .dark else .light);
}

/// Which way the chrome is mirrored (`App.setDirection`). Text is not
/// this question — it aligns by its own content, in both editions —
/// so this is the rows, the leading edges and the nav, and it reaches
/// them the way the appearance does: stamped on the document, spent by
/// the generated sheet, which is written in logical properties
/// throughout for exactly this.
fn direction() callconv(.c) i32 {
    if (!booted) return 0;
    return @intFromBool(app.direction == .rtl);
}

/// The resolved appearance, which every other platform reads at paint.
/// Here the painter is a stylesheet, so the glue reads it once a frame
/// and stamps it on the document for the two ramps to hang off — a
/// media query cannot ask this question, because half of it is the
/// app's own `scheme`.
fn appearance() callconv(.c) i32 {
    if (!booted) return 0;
    return @intFromBool(app.appearance() == .dark);
}

var motion: router_mod.Change = .replace;

fn onRoute(_: ?*anyopaque, _: []const u8, change: router_mod.Change) void {
    motion = change;
}

fn routeMotion() callconv(.c) u32 {
    return @intFromEnum(motion);
}

fn currentRef() []const u8 {
    if (!booted) return "";
    return app.router.currentRef() orelse "";
}

fn route() callconv(.c) [*]const u8 {
    return currentRef().ptr;
}

fn routeLen() callconv(.c) usize {
    return currentRef().len;
}

fn focusedNode() callconv(.c) u32 {
    if (!booted) return @bitCast(NodeId.invalid);
    const f = app.focused orelse return @bitCast(NodeId.invalid);
    return @bitCast(f.node);
}

fn focusedSpan() callconv(.c) i32 {
    if (!booted) return -1;
    const f = app.focused orelse return -1;
    return if (f.span) |s| @intCast(s) else -1;
}

/// Where the caret sits in the focused field, in UTF-8 bytes. The tree
/// owns it — `editing.zig` moves it, not the browser — so the glue
/// restores it after a re-render rather than letting the DOM keep its
/// own idea.
fn caret() callconv(.c) i32 {
    if (!booted) return -1;
    const f = app.focused orelse return -1;
    const el = app.tree.getConst(f.node) orelse return -1;
    return switch (el.*) {
        .text_input => |t| @intCast(t.cursor),
        .text_area => |t| @intCast(t.cursor),
        else => -1,
    };
}

// ---- workers (docs/internals/workers.md) -------------------------
//
// Two instances of one module: this one runs the app, and a sibling in
// a Worker runs the compute actor. Nothing here is edition-specific —
// a worker has no more to do with markup than it has with Skia — so
// these forward straight into the transport, exactly as the canvas
// shell's do.
//
// The scratch is separate from the event one on purpose: a compute
// instance never boots an app, so it has no `App` to hang a buffer off.

var worker_scratch: std.ArrayList(u8) = .empty;

fn workerScratch(len: usize) callconv(.c) ?[*]u8 {
    worker_scratch.resize(gpa, len) catch return null;
    return worker_scratch.items.ptr;
}

fn workerBoot(index: u32) callconv(.c) i32 {
    return if (workers_post.bootWorker(gpa, index)) 1 else 0;
}

fn workerHandle(ptr: [*]const u8, len: usize) callconv(.c) void {
    workers_post.handleFrame(ptr[0..len]);
}

/// A reply landing on the UI thread. Handlers run here and invalidate
/// like any action, so the glue paints after the call.
fn workerDeliver(slot: u32, ptr: [*]const u8, len: usize) callconv(.c) void {
    if (!booted) return;
    app.runtime.deliverFromPost(slot, ptr[0..len]);
}

fn workerDied(slot: u32) callconv(.c) void {
    if (!booted) return;
    app.runtime.postWorkerDied(slot);
}

// ---- http (docs/internals/http.md) --------------------------------
//
// The browser is the client; these are the response's landing. The
// logic is the service's own web leg — this is the doorway, like
// `nokre_worker_deliver`.

fn httpScratch(len: usize) callconv(.c) ?[*]u8 {
    return http_web.scratchAlloc(len);
}

fn httpDeliver(index: u32, gen: u32, status: u32, headers_len: usize, body_len: usize) callconv(.c) void {
    http_web.deliver(index, gen, @truncate(status), headers_len, body_len);
}

fn httpFail(index: u32, gen: u32, name_len: usize) callconv(.c) void {
    http_web.fail(index, gen, name_len);
}

comptime {
    // Referenced so the driver's own dependencies analyze on every
    // target the library compiles for, not only wasm.
    _ = editing;
    _ = element_mod;
    _ = focus_mod;
}
