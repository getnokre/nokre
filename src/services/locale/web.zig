//! locale web leg: render/dom/live.js is the native side
//! (docs/internals/platform-shells.md). There is no C shell to implement
//! nokre_locale_install, so the seeded tag and the installed receiver
//! live here, and the entries live.js calls are exported from here.
//!
//! The ordering that makes the boot tag synchronous is the driver's:
//! live.js pours the page's tag in through the scratch/seed pair
//! strictly before `nokre_dom_boot` — so by the time App.init installs,
//! the tag is already in hand and `install` can honour locale.h's
//! fire-before-you-return clause
//! itself. Appearance's post-boot push would not do: appearance is read
//! at paint, the locale is read inside the first `build`.
//!
//! *Which* tag that is, is the driver's too, and there are two: the page
//! pins one where nokre generated the page (`mount({ locale })`, from
//! the same `App.locale()` its `lang` came from), and otherwise it is
//! `navigator.language`. Nothing here can tell them apart, and nothing
//! here should — this leg reports what the shell says, and on the web
//! the page is part of the shell (docs/internals/dom-edition.md, "The
//! page's locale, not the reader's").
//!
//! The single-app anchor: the browser runs exactly one nokre app per
//! module instance — the web shell already holds that one app as module
//! state — so the seed and the installed ctx + callback live here too,
//! not on a per-app struct a test could multiply. Under `zig test` this
//! file is never imported (locale.zig gates it on wasm && !is_test), so
//! the per-app mock stays the only test path and no global leaks
//! between tests.

const locale = @import("locale.zig");

const max_tag_bytes = locale.max_tag_bytes;
const CCallback = *const fn (ctx: ?*anyopaque, tag: [*]const u8, len: usize) callconv(.c) void;

var tag_buf: [max_tag_bytes]u8 = undefined;
var tag_len: usize = 0;

var receiver_ctx: ?*anyopaque = null;
var receiver_cb: ?CCallback = null;

/// App.init's install lands here (locale.zig). Fires the callback
/// synchronously with whatever was seeded — the empty tag if glue sent
/// nothing, which resolves to the bundle's template.
pub fn install(ctx: ?*anyopaque, cb: CCallback) void {
    receiver_ctx = ctx;
    receiver_cb = cb;
    cb(ctx, &tag_buf, tag_len);
}

/// App.deinit's release: the stored ctx is per-app state the app is
/// about to free, so a `languagechange` after this must find no
/// callback, not freed memory.
pub fn uninstall() void {
    receiver_ctx = null;
    receiver_cb = null;
}

/// live.js asks for the landing buffer before boot, copies `len`
/// UTF-8 bytes of `navigator.language` into it, then calls
/// `nokre_locale_seed`. Null for an over-cap tag: live.js then seeds
/// nothing and the tag stays empty, the truncate-to-empty rule
/// (locale.zig's max_tag_bytes).
pub export fn nokre_locale_scratch(len: usize) ?[*]u8 {
    if (len > tag_buf.len) return null;
    return &tag_buf;
}

/// Publishes the bytes just written into the scratch. Seeding never
/// dispatches — nothing is installed yet, and this is not a change; it
/// is the value `install` will fire with.
pub export fn nokre_locale_seed(len: usize) void {
    if (len > tag_buf.len) return;
    tag_len = len;
}

/// live.js's `languagechange` lane, after boot: copies the tag in and
/// dispatches. A call before App.init installed can only slip in while
/// live.js awaits the seed fetch, and it is
/// harmless — the seed is overwritten and the next install fires with
/// the newer tag. `len` 0 is a real value, not a no-op: it is the
/// browser saying it no longer knows.
pub export fn nokre_locale_receive(t: [*]const u8, len: usize) void {
    tag_len = if (len > tag_buf.len) 0 else len;
    // live.js writes through nokre_locale_scratch, so `t` is usually
    // tag_buf itself — and an exactly-overlapping @memcpy is illegal.
    if (tag_len != 0 and t != @as([*]const u8, &tag_buf)) @memcpy(tag_buf[0..tag_len], t[0..tag_len]);
    if (receiver_cb) |cb| cb(receiver_ctx, &tag_buf, tag_len);
}
