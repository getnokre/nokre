//! The desktop legs' whole native surface: one verb, "open this URL in
//! the user's browser". Implemented in windows.c (ShellExecuteW) and
//! linux.c (xdg-open); everything else about the flow — the listener,
//! the parse, the delivery — is Zig (loopback.zig).
//!
//! Separate from native.zig so the Apple/Android extern surface and this
//! one never compile into the same object: a target links exactly the
//! symbols its leg defines.

extern fn nokre_oauth_open_url(url: [*]const u8, len: usize) c_int;

/// False means no browser could be launched — a real outcome on a
/// headless session or a container, and one the app should see as a
/// named failure rather than a flow that never returns.
pub fn openUrl(url: []const u8) bool {
    return nokre_oauth_open_url(url.ptr, url.len) == 0;
}
