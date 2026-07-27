//! deep_link web leg: live.js is the native side (docs/internals/
//! platform-shells.md). There is no C shell to implement
//! nokre_deep_link_install, so the Zig side keeps the installed receiver
//! here and exports the entry live.js calls.
//!
//! The single-app anchor: the browser runs exactly one nokre app per
//! module instance — the web shell already holds that one app as module
//! state — so the installed ctx + callback live here too, not on a
//! per-app struct a test could multiply. Under `zig test` this file is
//! never imported (deep_link.zig gates it on wasm && !is_test), so the
//! per-app mock stays the only test path and no global leaks between
//! tests.

const CCallback = *const fn (ctx: ?*anyopaque, url: [*]const u8, len: usize) callconv(.c) void;

var receiver_ctx: ?*anyopaque = null;
var receiver_cb: ?CCallback = null;

/// setHandler's first call installs the receiver here (deep_link.zig).
pub fn install(ctx: ?*anyopaque, cb: CCallback) void {
    receiver_ctx = ctx;
    receiver_cb = cb;
}

/// App.deinit's release: the stored ctx is per-app state the app is
/// about to free, so a `hashchange` after this must find no callback,
/// not freed memory.
pub fn uninstall() void {
    receiver_ctx = null;
    receiver_cb = null;
}

/// live.js calls this after boot (the initial `location.hash`, if any)
/// and on every `hashchange`, having copied the URL bytes into wasm
/// memory. A call before the app registers a handler is a no-op — the
/// fragment simply had no listener yet, the same posture as a launch
/// URL that arrives before setHandler.
pub export fn nokre_deep_link_receive(url: [*]const u8, len: usize) void {
    if (receiver_cb) |cb| cb(receiver_ctx, url, len);
}
