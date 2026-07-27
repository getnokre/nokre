//! The Apple / Android extern surface: the two browser-session verbs of
//! oauth.h, plus Apple's native Sign in with Apple leg. Policy stays out
//! — the redirect string, the scheme validation, the one-flow rule, and
//! the synthetic callback URL all ran in oauth.zig before any call lands
//! here; this file is the ferry and nothing else, secure_store's
//! native.zig posture.
//!
//! The session pointer is the one piece of state that cannot live in
//! Zig: an `ASWebAuthenticationSession` (or a Custom Tab's launch
//! record) is an object the platform owns. So the contract inverts the
//! usual direction exactly once — the native side hands *us* an opaque
//! handle, we hold it while the flow is live, and it releases the object
//! itself either at the callback or inside `cancel`. Zig never
//! dereferences it.

/// The browser legs' callback: `text` is the callback URL, empty, or a
/// failure name, per the status. Mirrors `nokre_oauth_cb` in oauth.h.
pub const Callback = *const fn (ctx: ?*anyopaque, status: c_int, text: [*]const u8, len: usize) callconv(.c) void;

/// Apple's native leg: fields, not a URL — Zig composes the synthetic
/// callback from them. Mirrors `nokre_oauth_apple_cb` in oauth.h.
pub const AppleCallback = *const fn (
    ctx: ?*anyopaque,
    status: c_int,
    code: [*]const u8,
    code_len: usize,
    id_token: [*]const u8,
    id_token_len: usize,
    err: [*]const u8,
    err_len: usize,
) callconv(.c) void;

extern fn nokre_oauth_start(
    ctx: ?*anyopaque,
    cb: Callback,
    url: [*]const u8,
    url_len: usize,
    scheme: [*]const u8,
    scheme_len: usize,
) ?*anyopaque;

extern fn nokre_oauth_cancel(session: *anyopaque) void;

extern fn nokre_oauth_apple_start(
    ctx: ?*anyopaque,
    cb: AppleCallback,
    nonce: [*]const u8,
    nonce_len: usize,
) ?*anyopaque;

/// Null means the platform could not start a session at all, and the
/// callback will never fire — oauth.zig turns that into one
/// "SessionUnavailable" failure rather than a flow that hangs.
pub fn start(ctx: ?*anyopaque, cb: Callback, url: []const u8, scheme: []const u8) ?*anyopaque {
    return nokre_oauth_start(ctx, cb, url.ptr, url.len, scheme.ptr, scheme.len);
}

pub fn cancel(session: *anyopaque) void {
    nokre_oauth_cancel(session);
}

/// Apple's own platforms only; the `.apple` leg is the only caller, so
/// Android never names the symbol.
pub fn appleStart(ctx: ?*anyopaque, cb: AppleCallback, nonce: []const u8) ?*anyopaque {
    return nokre_oauth_apple_start(ctx, cb, nonce.ptr, nonce.len);
}
