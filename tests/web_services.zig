//! The app the web harness boots (tests/web_services.mjs): a real nokre
//! app on the *real* web legs of deep_link, oauth and secure_store,
//! compiled to wasm32-freestanding and driven through the shipped
//! live.js — the one place those three legs execute.
//!
//! Under `zig test` a service is its mock, and `check-targets` compiles
//! the web legs into objects it never links or runs, so until this
//! program nothing anywhere called `nokre_deep_link_receive`, opened the
//! oauth popup loop, or poured a seed into the in-wasm table
//! (docs/testing.md, "Where the harness stops").
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

const deep_link = h.services.deep_link;
const oauth = h.services.oauth;
const ss = h.services.secure_store;

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
};

var state_ptr: ?*State = null;

var arg_buf: [8 * 1024]u8 = undefined;
var result_buf: [8 * 1024]u8 = undefined;

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

fn buildHome(state: *State, app: *h.App) !void {
    state.app = app;
    deep_link.setHandler(app, state, onLink);
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
    try app.tree.append(root, .{ .heading = .{ .content = "web services", .level = .h1 } });
    try app.tree.append(root, .{ .text = .{ .content = "The harness drives this app through the shipped live.js." } });
    try app.tree.append(root, .{ .button = .{
        .label = "Sign in",
        .on_press = .bind(onSignIn, state),
    } });
}

const routes = h.Routes(State).table(&.{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildHome },
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

/// The name of the error the last verb returned, empty if it succeeded.
pub export fn nokre_probe_error() isize {
    const s = probe();
    return out(s.err[0..s.err_len]);
}
