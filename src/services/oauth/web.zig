//! oauth web leg: live.js + services.js are the native side
//! (docs/internals/platform-shells.md). There is no C shell to
//! implement `nokre_oauth_start`, so the popup lives in JS and this
//! file is the doorway — the redirect the page will land on, seeded
//! before boot, and the receiver services.js calls when the popup
//! reports back.
//!
//! The web's redirect is the page's own address, not a custom scheme: in
//! a browser the origin *is* the registration, and a `com.example:/…`
//! URL means nothing. So the popup navigates to the app's own page,
//! which loads the driver, notices it is a popup carrying an auth
//! response, posts its href to its opener, and closes — the whole
//! detour is a dozen lines in services.js, and it costs the consumer no
//! second HTML file to deploy and no second origin to register with the
//! provider.
//!
//! The redirect is seeded strictly before boot, the locale's ordering
//! and for the same reason: `redirectUri` is called inside an action,
//! and an async read would have nothing to answer with.
//!
//! The single-app anchor: the browser runs exactly one nokre app per
//! module instance — the web driver already holds that one app as
//! module state — so the installed ctx + callback live here too, not on
//! a per-app struct a test could multiply. Under `zig test` this file is
//! never imported (oauth.zig gates it on the `.web` leg, which a test
//! build never chooses), so the per-app mock stays the only test path
//! and no global leaks between tests.

const oauth = @import("oauth.zig");
const workers = @import("../../workers/workers.zig");

/// Mirrors `nokre_oauth_cb` in oauth.h — the same shape the native legs
/// use, so oauth.zig's trampoline is one function for all of them.
const Callback = *const fn (ctx: ?*anyopaque, status: c_int, text: [*]const u8, len: usize) callconv(.c) void;

// Mirrors NOKRE_OAUTH_* in oauth.h.
const status_callback: c_int = 0;
const status_cancelled: c_int = 1;
const status_failure: c_int = 2;

/// Implemented by services.js on the app instance's import object —
/// `window.open` is a main-thread API and so is this instance, so the
/// popup opens inside the call. What `open` still cannot answer is
/// whether the flow can proceed: a popup the browser blocks comes back
/// through `nokre_oauth_receive` as a failure, queued a task over so
/// the result never lands before the app holds the handle.
extern fn nokre_oauth_js_open(url: [*]const u8, len: usize) void;
extern fn nokre_oauth_js_close() void;

/// The redirect live.js seeded: `location.origin + location.pathname`
/// of the page hosting the app. Capped at oauth's `max_redirect_bytes`
/// (the web-sized arm), which the scratch export enforces — an
/// over-long URL seeds nothing and `redirectUri` fails loudly, never
/// truncates into a URI the provider would reject at the token
/// exchange.
var redirect_buf: [oauth.max_redirect_bytes]u8 = undefined;
var redirect_len: usize = 0;

/// The landing buffer for the callback URL. Fixed, not grown: this leg
/// has no allocator of its own, and 8 KiB covers an implicit-flow
/// fragment carrying an idToken with room to spare — the same head
/// budget the loopback listener gives a request line.
var callback_buf: [8 * 1024]u8 = undefined;

var receiver_ctx: ?*anyopaque = null;
var receiver_cb: ?Callback = null;

/// The runtime the live flow's result pumps through — single-app module
/// state like the receiver pair above. The trampoline only *queues* the
/// result, and no shell loop stands behind this instance to wake the
/// queue, so `nokre_oauth_receive` pumps inline: `deliverFromPost`'s
/// shape, the http web leg's reason.
var runtime: ?*workers.Runtime = null;

/// A session handle that points at nothing in particular: the popup is
/// owned by JS, and there is nothing for Zig to hold but "a flow is
/// live". Anchored on a real byte rather than a fabricated address, so
/// nothing in the language has to tolerate it.
var live_anchor: u8 = 0;

pub fn sentinel() *anyopaque {
    return @ptrCast(&live_anchor);
}

pub fn redirect(buf: *oauth.RedirectBuf) error{RedirectTooLong}![]const u8 {
    if (redirect_len == 0) return error.RedirectTooLong;
    @memcpy(buf[0..redirect_len], redirect_buf[0..redirect_len]);
    return buf[0..redirect_len];
}

/// Cannot fail: `window.open` reports a blocked popup, but services.js
/// defers that a task and it arrives through `nokre_oauth_receive` as a
/// status like any other — never synchronously, so there is nothing for
/// this call to return (the extern's doc above states the arrangement).
pub fn start(ctx: ?*anyopaque, cb: Callback, url: []const u8, rt: *workers.Runtime) void {
    receiver_ctx = ctx;
    receiver_cb = cb;
    runtime = rt;
    nokre_oauth_js_open(url.ptr, url.len);
}

pub fn cancel() void {
    receiver_cb = null;
    nokre_oauth_js_close();
}

/// live.js asks for the seed buffer before boot, copies the page URL
/// into it, then calls `nokre_oauth_seed_redirect`. Null for an over-cap
/// URL: live.js then seeds nothing, and the first sign-in fails
/// loudly — locale's truncate-to-empty rule, with an error instead of a
/// fallback, because there is no defensible default redirect the way
/// there is a default locale.
pub export fn nokre_oauth_seed_scratch(len: usize) ?[*]u8 {
    if (len > redirect_buf.len) return null;
    return &redirect_buf;
}

pub export fn nokre_oauth_seed_redirect(len: usize) void {
    if (len > redirect_buf.len) return;
    redirect_len = len;
}

/// The landing buffer for a result: JS never allocates in the wasm heap,
/// it asks for a buffer, writes into it, and calls `nokre_oauth_receive` —
/// the http transport's three beats.
pub export fn nokre_oauth_scratch(len: usize) ?[*]u8 {
    if (len > callback_buf.len) return null;
    return &callback_buf;
}

/// services.js's lane back: the popup posted its landing URL (status 0),
/// the user closed it (1), or the browser blocked it (2, with a failure
/// name in the scratch). A call with no receiver installed is a no-op —
/// a stale popup from a flow the app already cancelled.
pub export fn nokre_oauth_receive(status: i32, len: usize) void {
    const cb = receiver_cb orelse return;
    receiver_cb = null;
    if (len > callback_buf.len) return;
    const mapped: c_int = switch (status) {
        0 => status_callback,
        1 => status_cancelled,
        else => status_failure,
    };
    cb(receiver_ctx, mapped, &callback_buf, len);
    // The trampoline queued the result; pump it through to the app now,
    // on this (the only) thread — services.js paints right after this
    // call returns, and the paint must show what the handler did.
    if (runtime) |rt| _ = rt.pump();
}
