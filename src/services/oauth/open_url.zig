//! The desktop legs' whole native surface: one verb, "open this URL in
//! the user's browser" — and the verb is the shell's. Each desktop
//! shell exports one launcher, `nokre_open_url_open`
//! (src/services/open_url/open_url.h), and this leg names that symbol
//! instead of keeping the second ShellExecuteW/xdg-open copy it once
//! carried in windows.c and linux.c. The coupling crosses the
//! service/shell line on purpose and is owner-approved — the header
//! states it, so it does not get "fixed" back into two copies.
//! Everything else about the flow — the listener, the parse, the
//! delivery — is Zig (loopback.zig).
//!
//! Separate from native.zig so the Apple/Android extern surface and
//! this one never meet: a target references exactly the symbols its
//! leg needs.

extern fn nokre_open_url_open(url: [*]const u8, len: usize) c_int;

/// False means the launch never started — no browser on a headless
/// session or a container, a real outcome the app should see as a
/// named failure rather than a flow that never returns. That is the
/// launcher's whole return contract (open_url.h): past "started", the
/// page belongs to the user.
pub fn openUrl(url: []const u8) bool {
    return nokre_open_url_open(url.ptr, url.len) == 0;
}
