//! clipboard — one verb: copy UTF-8 text out (docs/services.md).
//! Write-only by design: reading the clipboard is a permission prompt
//! and a privacy posture nokre has no business taking; paste arrives
//! as ordinary text input through the platform's IME/text events.
//!
//! Every shell exports the same C hook (nokre_shell_write_clipboard —
//! NSPasteboard on macOS, UIPasteboard on iOS, OpenClipboard on
//! Windows, navigator.clipboard via the JS shell on the web,
//! ClipboardManager via the JNI shell on Android, a wl_data_source on
//! the Wayland shell on Linux), so the release path is one extern call.
//! Under `zig test` the mock journals every write — "activating this
//! copyable wrote X" is a first-class assertion.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const services = @import("../services.zig");

const App = app_mod.App;

// Every shell exports nokre_shell_write_clipboard.
const has_shell_hook = services.every_shell_hooks;

extern fn nokre_shell_write_clipboard(utf8: [*]const u8, len: usize) void;

/// Write `utf8` to the platform clipboard; `App.copyText` lands here.
/// What to show for feedback is the caller's build's business; nokre
/// adds none.
pub fn copy(app: *const App, utf8: []const u8) void {
    if (comptime builtin.is_test) {
        app.services.clipboard.state.?.record(utf8);
    } else if (comptime has_shell_hook) {
        nokre_shell_write_clipboard(utf8.ptr, utf8.len);
    }
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, nothing in release — the extern call keeps no state.
pub const Service = if (builtin.is_test) Mock else services.Stateless;

/// The mock's heap half: every copy the app made, in order
/// (services.Journal's ownership and no-error rules).
pub const MockState = services.Journal([]u8, "clipboard mock");

/// One app's journaling clipboard.
pub const Mock = struct {
    /// The heap half; null only before App.init.
    state: ?*MockState = null,

    pub const Config = struct {};

    pub fn mock(config: Config) Mock {
        _ = config;
        return .{};
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        state.* = .{ .gpa = gpa };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        const gpa = state.gpa;
        state.deinit();
        gpa.destroy(state);
        self.state = null;
    }

    /// Every copy the app made, in order. Borrowed views.
    pub fn copies(self: Mock) []const []const u8 {
        return services.borrowed(self.state.?.view());
    }

    /// The per-phase reset (http's rule).
    pub fn clearJournal(self: Mock) void {
        self.state.?.clear();
    }
};
