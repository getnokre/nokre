//! open_url — one verb: hand a URL to the system browser, or the OS's
//! default handler for its scheme (docs/services.md).
//!
//! The posture is oauth's browser leg, generalized (RFC 8252's spirit:
//! the system browser, never an embedded web view). nokre renders no
//! external content — the page opens where the user's own chrome,
//! cookies, and password manager live, and where the address bar is
//! theirs to trust. Fire-and-forget at this surface: the only thing
//! the launcher can honestly report is that the handoff started, and
//! that bit belongs to oauth's loopback leg, not to an app — so
//! nothing comes back here and no state is kept. The launcher itself
//! is the shell's, and oauth shares it (open_url.h).
//!
//! The scheme set is closed — `https`, `http`, `mailto` — and checked
//! here, before any OS call, so `UnsupportedScheme` means one thing on
//! every platform (secure_store's pure-function rule). The OS would
//! happily open `file:`, `javascript:`, or whatever handler an
//! installed app registered; the closed set is the element-set posture
//! applied to destinations, and it is the same allowlist markdown's
//! link parser consults, so a URL that can be constructed is a URL
//! that can be opened.
//!
//! Nothing links — clipboard's posture: every shell exports the same
//! hook (`NSWorkspace` on macOS, `UIApplication` on iOS, ShellExecuteW
//! on Windows, `window.open` via services.js on the web, an ACTION_VIEW
//! intent via the JNI shell on Android, xdg-open on the Wayland shell
//! on Linux; src/services/open_url/open_url.h). Under `zig test` the
//! mock journals every open, so "pressing this link asked for X" is a
//! first-class assertion.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const services = @import("../services.zig");

const App = app_mod.App;

pub const Error = error{UnsupportedScheme};

// Every shell exports nokre_open_url_open. The return — 0 when the
// handoff started — exists for oauth's loopback leg, the launcher's
// other caller (open_url.h states the coupling); this service's
// contract stays fire-and-forget, so it discards the value.
const has_shell_hook = services.every_shell_hooks;

extern fn nokre_open_url_open(url: [*]const u8, len: usize) c_int;

/// The closed scheme set: `https`, `http`, `mailto`, and nothing else.
/// Pure — construction gates (tree.zig) and the markdown parser ask the
/// same function this service enforces, so the answer cannot drift.
/// Compared case-insensitively because RFC 3986 §3.1 says schemes are;
/// fetched content writes `HTTPS://` and means it.
pub fn schemeAllowed(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    // "mailto:" alone names nobody; a bare scheme is not a destination.
    if (colon + 1 >= url.len) return false;
    const scheme = url[0..colon];
    inline for (.{ "https", "http", "mailto" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(scheme, allowed)) return true;
    }
    return false;
}

/// Ask the OS to open `url`. A scheme off the allowlist is
/// `error.UnsupportedScheme`, uniformly, before any OS call; past the
/// check the handoff is fire-and-forget.
pub fn open(app: *const App, url: []const u8) Error!void {
    if (!schemeAllowed(url)) return error.UnsupportedScheme;
    if (comptime builtin.is_test) {
        app.services.open_url.state.?.record(url);
    } else if (comptime has_shell_hook) {
        _ = nokre_open_url_open(url.ptr, url.len);
    }
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, nothing in release — the extern call keeps no state.
pub const Service = if (builtin.is_test) Mock else services.Stateless;

/// The mock's heap half: every URL the app asked to open, in order
/// (services.Journal's ownership and no-error rules).
pub const MockState = services.Journal([]u8, "open_url mock");

/// One app's journaling browser handoff.
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

    /// Every URL the app asked to open, in order. Borrowed views.
    /// Rejected schemes never journal — the OS was never asked.
    pub fn opens(self: Mock) []const []u8 {
        return self.state.?.view();
    }

    /// The per-phase reset (http's rule).
    pub fn clearJournal(self: Mock) void {
        self.state.?.clear();
    }
};

test "the scheme allowlist is closed, case-insensitive, and demands a remainder" {
    try std.testing.expect(schemeAllowed("https://example.com/terms"));
    try std.testing.expect(schemeAllowed("http://example.com"));
    try std.testing.expect(schemeAllowed("mailto:help@example.com"));
    try std.testing.expect(schemeAllowed("HTTPS://EXAMPLE.COM")); // RFC 3986 §3.1
    // Everything the OS would open and nokre will not.
    try std.testing.expect(!schemeAllowed("javascript:alert(1)"));
    try std.testing.expect(!schemeAllowed("file:///etc/passwd"));
    try std.testing.expect(!schemeAllowed("ftp://example.com"));
    try std.testing.expect(!schemeAllowed("tel:+123"));
    // Not URLs at all: a route name, a protocol-relative reference, a
    // bare scheme with nobody behind it.
    try std.testing.expect(!schemeAllowed("terms"));
    try std.testing.expect(!schemeAllowed("//cdn.example.com/x"));
    try std.testing.expect(!schemeAllowed("mailto:"));
    try std.testing.expect(!schemeAllowed(""));
}
