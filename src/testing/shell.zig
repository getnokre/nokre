//! The shell a driver links instead of writing.
//!
//! A driver — the program shape docs/testing.md calls "a shell, minus
//! the window" — owes the C hooks a shell owes: the services name
//! them, so a binary with no shell must still resolve them. Before
//! this module every driver wrote the same block by hand: nokre's own
//! two (tests/dev_store.zig, tests/http_stress.zig), the stylesheet
//! tool, and every consumer's system-test and e2e runners. Naming this
//! module is now the whole install:
//!
//!     comptime {
//!         _ = nokre.testing.shell;
//!     }
//!
//! An export enters the binary only when its file is analyzed, so the
//! shell stays out of every build that does not name it — and a
//! windowed build that named it anyway would collide with the real
//! shell's definitions at link time. That collision is the guard: the
//! mistake is a loud duplicate-symbol error, never two shells wired to
//! one app.
//!
//! Each hook answers the way a shell with nothing to report does — no
//! window, no device to ask, never an invented answer. Locale answers
//! its contract's way (src/services/locale/locale.zig: the install
//! fires the callback synchronously with the current tag), and the
//! truthful current tag here is the empty one. Three hooks are not
//! silent, and deliberately: the clipboard, the share sheet, and an
//! outbound URL are where screens end, and a shell that swallowed them
//! would leave those screens with no observable outcome at all. So
//! each records what it was last handed — exactly as the platform
//! mocks do under `zig test` — and the driver reads it back with
//! `lastCopied`, `lastShared`, `lastOpened`.
//!
//! The slots are module-global `var`s, against the services' own rule,
//! because a C export has no ctx parameter to thread state through —
//! the corner the platform shells' own .m/.c files live in. One
//! process, one shell is the contract, exactly as it is for a window:
//! a driver holding two `App`s (docs/testing.md sanctions it) still
//! holds one clipboard.
//!
//! What this module deliberately does not own is the loop: a driver
//! pumps `app.runtime.pump()` itself, on its own schedule and
//! deadlines. A shell's wake machinery exists to reach a platform main
//! loop, and there is none here to reach.

const std = @import("std");

export fn nokre_deep_link_install(_: ?*anyopaque, _: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void) void {}
export fn nokre_deep_link_uninstall() void {}

export fn nokre_locale_install(
    ctx: ?*anyopaque,
    cb: *const fn (ctx: ?*anyopaque, tag: [*]const u8, len: usize) callconv(.c) void,
) void {
    cb(ctx, "", 0);
}
export fn nokre_locale_uninstall() void {}

export fn nokre_open_url_open(utf8: [*]const u8, len: usize) void {
    record(&opened, utf8, len);
}

export fn nokre_shell_write_clipboard(utf8: [*]const u8, len: usize) void {
    record(&clipboard, utf8, len);
}

export fn nokre_share_show(utf8: [*]const u8, len: usize) void {
    record(&shared, utf8, len);
}

/// One slot holds one payload — the last one, whole. A journal would
/// impose a drain discipline on drivers that only ever ask "where did
/// this screen end?", and 64 KiB is slack of orders of magnitude over
/// any URL or share text a screen produces; a longer payload is kept
/// truncated rather than dropped, so the assertion that reads it fails
/// on content, legibly, not on absence.
const capacity = 1 << 16;

const Slot = struct {
    buf: [capacity]u8 = undefined,
    len: usize = 0,

    fn view(self: *const Slot) []const u8 {
        return self.buf[0..self.len];
    }
};

var clipboard: Slot = .{};
var shared: Slot = .{};
var opened: Slot = .{};

fn record(slot: *Slot, utf8: [*]const u8, len: usize) void {
    slot.len = @min(len, capacity);
    @memcpy(slot.buf[0..slot.len], utf8[0..slot.len]);
}

/// What was last written to the clipboard, or empty if nothing was.
pub fn lastCopied() []const u8 {
    return clipboard.view();
}

/// What the last share sheet was handed, or empty if none was raised.
pub fn lastShared() []const u8 {
    return shared.view();
}

/// The last URL handed out to the system, or empty if none was.
pub fn lastOpened() []const u8 {
    return opened.view();
}

test "locale install answers synchronously with the empty tag" {
    const Probe = struct {
        var fired: bool = false;
        fn cb(ctx: ?*anyopaque, tag: [*]const u8, len: usize) callconv(.c) void {
            _ = ctx;
            _ = tag;
            std.debug.assert(len == 0);
            fired = true;
        }
    };
    nokre_locale_install(null, Probe.cb);
    try std.testing.expect(Probe.fired);
    nokre_locale_uninstall();
}

test "the recording hooks hand back the last payload whole" {
    try std.testing.expectEqualStrings("", lastCopied());
    const first = "https://example.test/a";
    const second = "copied text";
    nokre_open_url_open(first.ptr, first.len);
    nokre_shell_write_clipboard(second.ptr, second.len);
    nokre_share_show(first.ptr, first.len);
    try std.testing.expectEqualStrings(first, lastOpened());
    try std.testing.expectEqualStrings(second, lastCopied());
    try std.testing.expectEqualStrings(first, lastShared());
    // Last write wins — the slot is a question about where a screen
    // ended, not a log of how it got there.
    nokre_shell_write_clipboard(first.ptr, first.len);
    try std.testing.expectEqualStrings(first, lastCopied());
}
