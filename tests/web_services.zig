//! The app the web harness boots (tests/web_services.mjs): a real nokre
//! app on the *real* web legs of deep_link, oauth, secure_store and
//! locale, compiled to wasm32-freestanding and driven through the
//! shipped live.js — the one place those four legs execute.
//!
//! Under `zig test` a service is its mock, and `check-targets` compiles
//! the web legs into objects it never links or runs, so until this
//! program nothing anywhere called `nokre_deep_link_receive`, opened the
//! oauth popup loop, poured a seed into the in-wasm table, or answered
//! `nokre_locale_seed` (docs/testing.md, "Where the harness stops").
//!
//! It is the dev-store driver's shape on the other side of the language
//! gap: an ordinary app, no mock in the binary, plus one probe export
//! per question the harness asks. The probes are the *only* thing here
//! that a shipping app would not have — they read back what a handler
//! recorded, so every assertion is about what the app saw, not about
//! what the driver claims it sent.
//!
//! Two buffers carry every string across, because JS never allocates in
//! the wasm heap: the harness writes arguments into `nokre_probe_arg`
//! and reads answers out of `nokre_probe_result` — the http transport's
//! three beats, which is also how live.js and services.js talk to every
//! service leg in here.

const std = @import("std");
const h = @import("nokre");

const dom = h.render.dom;
const deep_link = h.services.deep_link;
const locale = h.services.locale;
const oauth = h.services.oauth;
const ss = h.services.secure_store;

/// Two locales, and the second is right-to-left on purpose: the tag the
/// shell seeds decides the words *and* the direction the document gets
/// stamped with, and only an RTL locale makes the second one visible.
/// English is the template, so the empty tag resolves here
/// (docs/localization.md).
const L = h.l10n.Bundle(&.{
    @embedFile("l10n/webcheck_en.arb"),
    @embedFile("l10n/webcheck_fa.arb"),
});

/// The scheme is validated on every platform even where the web leg
/// ignores it (oauth.redirectUri says why), so the app declares the one
/// its packaging registers.
const scheme = "dev.nokre.webcheck";

const State = struct {
    app: *h.App = undefined,

    // deep_link: what arrived, and how many times. Both, because "the
    // fragment was delivered once" and "the fragment was delivered" are
    // different claims and the second is the weaker one.
    links: u32 = 0,
    link: [4096]u8 = undefined,
    link_len: usize = 0,

    // secure_store: the value a *boot read inside the first build*
    // found, kept apart from every later read — the seed's whole
    // contract is that it landed before this call, not eventually.
    boot_len: isize = -1,
    boot: ss.ValueBuf = undefined,
    built: bool = false,

    // oauth: the flow's one result, plus the redirect the page seeded
    // and the error name of a verb that refused.
    results: u32 = 0,
    status: i32 = 0,
    text: [4096]u8 = undefined,
    text_len: usize = 0,
    handle: ?oauth.Handle = null,
    redirect: oauth.RedirectBuf = undefined,
    redirect_len: isize = -1,
    err: [64]u8 = undefined,
    err_len: usize = 0,

    // locale: how many times the device reported a *change* after boot.
    // The boot fire is not one — it lands before any handler is
    // registered — so this counts what the app was told, not what the
    // service cached.
    locale_changes: u32 = 0,

    // The segmented control's answer, and the only screen state a press
    // moves. The hydration scenario asserts on it from both sides: the
    // app saw the press, and the words the rebuild wrote came out of it.
    view: usize = 0,
};

var state_ptr: ?*State = null;

var arg_buf: [8 * 1024]u8 = undefined;
var result_buf: [8 * 1024]u8 = undefined;
/// Where `nokre_probe_document` builds; the answer is copied into
/// `result_buf` like every other, so the harness reads one buffer.
var doc_buf: std.ArrayList(u8) = .empty;

// ---- the app ----------------------------------------------------

/// The handler registered inside `build`, which is what makes a launch
/// fragment land at all (docs/services.md's "first callback after
/// boot").
fn onLink(ctx: ?*anyopaque, url: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.links += 1;
    const n = @min(url.len, state.link.len);
    @memcpy(state.link[0..n], url[0..n]);
    state.link_len = n;
}

/// The three lines every localized nokre app writes
/// (docs/localization.md, "Choosing the locale"): resolve the tag the
/// shell reported against the bundle, tell the app which locale it is
/// *in*, and mirror the chrome with it. Written here rather than
/// paraphrased, because what the harness is checking is that these three
/// lines land in the page's language and not the reader's.
fn applyLocale(state: *State) void {
    const loc = L.resolve(locale.tag(state.app));
    state.app.setLocale(L.tag(loc)) catch |err| return note(state, err);
    state.app.setDirection(L.dir(loc));
}

/// A device locale change after boot. The service does not rebuild for
/// you — what a new locale changes is the app's business — and the
/// screen's words came out of the catalog inside `build`, so the verb is
/// `reload`, the deliberate-gesture one `App.reload` names a locale
/// change as: `invalidate` alone would re-lay-out and re-serialize the
/// tree that is already there, in the old language.
fn onLocale(ctx: ?*anyopaque, _: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.locale_changes += 1;
    applyLocale(state);
    state.app.reload() catch |err| note(state, err);
}

fn onAuth(ctx: ?*anyopaque, result: oauth.Result) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.results += 1;
    state.handle = null;
    switch (result) {
        .callback => |url| {
            state.status = 1;
            state.text_len = @min(url.len, state.text.len);
            @memcpy(state.text[0..state.text_len], url[0..state.text_len]);
        },
        .cancelled => {
            state.status = 2;
            state.text_len = 0;
        },
        .failure => |f| {
            state.status = 3;
            state.text_len = @min(f.name.len, state.text.len);
            @memcpy(state.text[0..state.text_len], f.name[0..state.text_len]);
        },
    }
    state.app.invalidate();
}

/// A press starts the flow, not an export: `window.open` is a
/// user-activation API, so the popup a browser will actually allow is
/// one opened inside the press — and driving it from the DOM makes
/// click → live.js → core → service one path rather than two.
fn onSignIn(state: *State) void {
    state.redirect_len = -1;
    state.err_len = 0;
    const redirect = oauth.redirectUri(state.app, scheme, &state.redirect) catch |err| return note(state, err);
    state.redirect_len = @intCast(redirect.len);
    // The authorize URL is the app's, whole — nothing about a
    // provider's parameter names lives in nokre.
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://provider.example/authorize?client_id=webcheck&state=xyz&redirect_uri={s}",
        .{redirect},
    ) catch |err| return note(state, err);
    state.handle = oauth.start(.{
        .app = state.app,
        .url = url,
        .redirect = redirect,
        .ctx = state,
        .on_result = onAuth,
    }) catch |err| return note(state, err);
}

fn note(state: *State, err: anyerror) void {
    const name = @errorName(err);
    state.err_len = @min(name.len, state.err.len);
    @memcpy(state.err[0..state.err_len], name[0..state.err_len]);
}

/// The two chips of the one control on this app's screen, and the two
/// sentences under it. A press has to change both, because a chip that
/// moves proves the browser resolved the hit and nothing else: the
/// sentence is written by the *builder*, so it only moves if the app
/// rebuilt the screen and the driver patched the result in.
const views = [_][]const u8{ "List", "Grid" };
const shown = [_][]const u8{ "Showing a list.", "Showing a grid." };

/// A press on a chip. `reload` and not `invalidate`: the words above
/// come out of `build`, and `invalidate` re-lays-out and re-serializes
/// the tree that is already there (docs/routing.md, the four motions).
fn onView(state: *State, selected: usize) void {
    state.view = selected;
    state.app.reload() catch |err| note(state, err);
}

fn buildHome(state: *State, app: *h.App) !void {
    state.app = app;
    deep_link.setHandler(app, state, onLink);
    locale.setHandler(app, state, onLocale);
    // Inside the first build and nowhere else: a boot read is
    // synchronous by contract, and the seed either beat it or the
    // contract is broken.
    if (!state.built) {
        state.built = true;
        var buf: ss.ValueBuf = undefined;
        if (ss.get(app, "token", &buf) catch null) |v| {
            @memcpy(state.boot[0..v.len], v);
            state.boot_len = @intCast(v.len);
        }
    }
    const root = app.tree.rootId();
    // From the catalog, so the *rendered* words are what a scenario
    // reads back: the failure this gate exists for is a page whose text
    // is silently in the other language.
    try app.tree.append(root, .{ .heading = .{ .content = L.of(app).tr(.title), .level = .h1 } });
    try app.tree.append(root, .{ .text = .{ .content = "The harness drives this app through the shipped live.js." } });
    try app.tree.append(root, .{ .button = .{
        .label = "Sign in",
        .on_press = .bind(onSignIn, state),
    } });
    try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &views,
        .selected = state.view,
        .on_select = .bind(onView, state),
    } });
    try app.tree.append(root, .{ .text = .{ .content = shown[state.view] } });
}

/// The nav's second destination, and nothing more: a roster is two
/// entries at the least (`setNav`), and a roster is what puts anything
/// at all in the *chrome* mount — which is half of what a page with two
/// of them is for.
fn buildSecond(_: *State, app: *h.App) !void {
    try app.tree.append(app.tree.rootId(), .{
        .heading = .{ .content = "Second", .level = .h1 },
    });
}

const routes = h.Routes(State).table(&.{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildHome },
    .{ .name = "second", .title = .{ .fixed = "Second" }, .build = buildSecond },
});

comptime {
    // `main` never runs on the web; without this nothing pulls the
    // library into the build at all (the kitchen sink's note).
    _ = h;
}

pub fn main() void {}

pub fn nokreWebBuild(alloc: std.mem.Allocator) !*h.App {
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    state.* = .{};
    const app = try alloc.create(h.App);
    errdefer alloc.destroy(app);
    app.* = try h.App.init(alloc, .{
        .viewport = .{ .w = 480, .h = 640 },
        .routes = &routes,
        .ctx = state,
    });
    state.app = app;
    state_ptr = state;
    // After `App.init` and before the first build, which is where a
    // boot locale is readable at all: the service's install fired inside
    // `init` with whatever the shell seeded (services/locale/locale.zig).
    applyLocale(state);
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "second", .icon = .settings },
    });
    try app.navigate("home");
    return app;
}

// ---- the probes -------------------------------------------------

pub export fn nokre_probe_arg() [*]u8 {
    return &arg_buf;
}

pub export fn nokre_probe_result() [*]u8 {
    return &result_buf;
}

fn probe() *State {
    return state_ptr.?;
}

fn out(bytes: []const u8) isize {
    const n = @min(bytes.len, result_buf.len);
    @memcpy(result_buf[0..n], bytes[0..n]);
    return @intCast(n);
}

pub export fn nokre_probe_links() u32 {
    return probe().links;
}

pub export fn nokre_probe_link() isize {
    const s = probe();
    return out(s.link[0..s.link_len]);
}

/// The value the first `build` read, or -1 for a store that had none.
pub export fn nokre_probe_boot_value() isize {
    const s = probe();
    if (s.boot_len < 0) return -1;
    return out(s.boot[0..@intCast(s.boot_len)]);
}

/// -1 is absence (a missing key is data, never a failure); -2 is the
/// error the verb returned, named in `nokre_probe_error`.
pub export fn nokre_probe_store_get(k_len: usize) isize {
    const s = probe();
    s.err_len = 0;
    var buf: ss.ValueBuf = undefined;
    const value = ss.get(s.app, arg_buf[0..k_len], &buf) catch |err| {
        note(s, err);
        return -2;
    };
    return if (value) |v| out(v) else -1;
}

pub export fn nokre_probe_store_set(k_len: usize, v_len: usize) isize {
    const s = probe();
    s.err_len = 0;
    ss.set(s.app, arg_buf[0..k_len], arg_buf[k_len..][0..v_len]) catch |err| {
        note(s, err);
        return -2;
    };
    return 0;
}

pub export fn nokre_probe_store_delete(k_len: usize) isize {
    const s = probe();
    s.err_len = 0;
    ss.delete(s.app, arg_buf[0..k_len]) catch |err| {
        note(s, err);
        return -2;
    };
    return 0;
}

/// The keys, newline-joined in the order `list` returned them — so the
/// harness asserts the contract's sort, not a set.
pub export fn nokre_probe_store_list() isize {
    const s = probe();
    s.err_len = 0;
    var buf: ss.ListBuf = undefined;
    const keys = ss.list(s.app, &buf) catch |err| {
        note(s, err);
        return -2;
    };
    var len: usize = 0;
    for (keys, 0..) |key, i| {
        if (i != 0) {
            result_buf[len] = '\n';
            len += 1;
        }
        @memcpy(result_buf[len..][0..key.len], key);
        len += key.len;
    }
    return @intCast(len);
}

/// The redirect `redirectUri` composed on the last press: the page's own
/// address as live.js seeded it, or -1 when the seed was refused.
pub export fn nokre_probe_redirect() isize {
    const s = probe();
    if (s.redirect_len < 0) return -1;
    return out(s.redirect[0..@intCast(s.redirect_len)]);
}

/// 0 none yet, 1 callback, 2 cancelled, 3 failure.
pub export fn nokre_probe_oauth_status() i32 {
    return probe().status;
}

pub export fn nokre_probe_oauth_results() u32 {
    return probe().results;
}

/// The callback URL, or a failure's name.
pub export fn nokre_probe_oauth_text() isize {
    const s = probe();
    return out(s.text[0..s.text_len]);
}

/// The app dismissing its own session — `Handle.cancel`, which is not
/// the user closing the popup and must reach `nokre_oauth_js_close`.
pub export fn nokre_probe_oauth_cancel() void {
    const s = probe();
    if (s.handle) |handle| handle.cancel();
    s.handle = null;
}

/// The tag the *shell* reported — what live.js poured into the seed
/// lane, before any resolution. Kept apart from the one below so "the
/// page's locale never arrived" and "it arrived and the app resolved it
/// elsewhere" stay different findings.
pub export fn nokre_probe_device_tag() isize {
    return out(locale.tag(probe().app));
}

/// The locale the app is *in* (`App.locale()`) — the resolved tag,
/// which is also what `L.of(app)` spends and what a generated document
/// would have carried as its `lang`.
pub export fn nokre_probe_locale() isize {
    return out(probe().app.locale());
}

/// 1 when the chrome is mirrored. Read from the app rather than from
/// the attribute, so a scenario can hold the two against each other.
pub export fn nokre_probe_rtl() i32 {
    return @intFromBool(probe().app.direction == .rtl);
}

/// Device locale changes delivered *after* boot.
pub export fn nokre_probe_locale_changes() u32 {
    return probe().locale_changes;
}

/// Which chip the app believes is chosen. Read from the app, so a
/// scenario can hold it against the chip the *document* is showing —
/// the two disagreeing is a press the browser resolved and core never
/// heard, which is exactly the failure a hydrated page can have.
pub export fn nokre_probe_view() usize {
    return probe().view;
}

/// The file a generator would publish for the screen this app is on:
/// `dom.document`, over this app's own tree, with the two mount ids and
/// the boot options the harness then mounts back over it.
///
/// It is a probe rather than markup the harness holds because the
/// hydration claim is about *two writers of one page* — the static
/// driver wrote the file, the live driver rebuilds it — and a fixture
/// typed in JavaScript would be a third, agreeing with neither. -2 is a
/// document too long for the result buffer: a probe that outgrew its
/// transport, not a fault in what it measured.
pub export fn nokre_probe_document() isize {
    const s = probe();
    doc_buf.clearRetainingCapacity();
    var em: dom.Emitter = .{
        .gpa = std.heap.wasm_allocator,
        .app = s.app,
        .out = &doc_buf,
        // What the live driver renders with (live.zig), and what makes
        // a node's identity *stated* across the handover rather than
        // guessed at.
        .options = .{ .node_ids = true },
    };
    defer em.deinit();
    dom.document(&em, .{
        .title = "web services",
        .stylesheet = "/style.css",
        .chrome_id = "chrome",
        .content_id = "content",
        .content_class = "page",
        .skip = "Skip to content",
        .boot = .{ .wasm = "/app.wasm", .addressing = .documents },
    }) catch |err| {
        note(s, err);
        return -2;
    };
    if (doc_buf.items.len > result_buf.len) return -2;
    return out(doc_buf.items);
}

/// The name of the error the last verb returned, empty if it succeeded.
pub export fn nokre_probe_error() isize {
    const s = probe();
    return out(s.err[0..s.err_len]);
}
