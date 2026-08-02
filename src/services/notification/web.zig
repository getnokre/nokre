//! notification web leg: services.js and the site's service worker are
//! the native side (docs/internals/dom-edition.md). There is no C shell
//! to implement nokre_notification_install, so the Zig side keeps the
//! installed receiver here and exports the entries JS calls.
//!
//! The single-app anchor is deep_link/web.zig's: the browser runs exactly
//! one nokre app per module instance, so the installed ctx + callback
//! live here rather than on a per-app struct a test could multiply. Under
//! `zig test` this file is never imported (notification.zig gates it on
//! wasm && !is_test), so the per-app mock stays the only test path and no
//! global leaks between tests.

const notification = @import("notification.zig");

const CCallback = *const fn (
    ctx: ?*anyopaque,
    kind: i32,
    status: i32,
    a: [*]const u8,
    a_len: usize,
    b: [*]const u8,
    b_len: usize,
) callconv(.c) void;

var receiver_ctx: ?*anyopaque = null;
var receiver_cb: ?CCallback = null;

/// One landing buffer for both strings, laid out a-then-b: JS never
/// allocates in the wasm heap, it asks for a buffer, writes into it, and
/// calls receive with the two lengths — the http transport's three beats,
/// with one call instead of two because a tap's id and route arrive
/// together.
///
/// Sized to the contract: a push subscription is the longest thing that
/// ever lands here, and `max_token_bytes` is what bounds it.
var landing: [notification.max_token_bytes + notification.max_route_bytes]u8 = undefined;

/// App.init's install (notification.zig).
pub fn install(ctx: ?*anyopaque, cb: CCallback) void {
    receiver_ctx = ctx;
    receiver_cb = cb;
}

/// App.deinit's release: the stored ctx is per-app state the app is about
/// to free, so a notificationclick after this must find no callback, not
/// freed memory.
pub fn uninstall() void {
    receiver_ctx = null;
    receiver_cb = null;
}

pub export fn nokre_notification_scratch(len: usize) ?[*]u8 {
    if (len > landing.len) return null;
    return &landing;
}

/// services.js calls this for an answered permission prompt, a tap the
/// service worker forwarded, a foreground arrival, and a push
/// subscription. The bytes are already in `landing`; which of the two
/// halves means what per kind is notification.h's table. A call before the
/// app installs a receiver is a no-op — the same posture as a launch tap
/// that arrives before boot finishes.
pub export fn nokre_notification_receive(kind: i32, status: i32, a_len: usize, b_len: usize) void {
    const cb = receiver_cb orelse return;
    if (a_len + b_len > landing.len) return;
    cb(receiver_ctx, kind, status, &landing, a_len, landing[a_len..].ptr, b_len);
}
