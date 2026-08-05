//! share — one verb: put the OS share sheet on screen with a piece of
//! UTF-8 text on it (docs/services.md).
//!
//! The sheet is the user's, twice over. Fire-and-forget, open_url's
//! line: once the sheet is up the only thing this call could honestly
//! report is that the OS was asked, so nothing comes back. And which
//! destination the user picks — or whether they dismiss it — is
//! deliberately unobservable, clipboard's write-only posture applied to
//! sharing out: three platforms would tell us and three would not, and
//! the three that would are reporting on the user, not for the app.
//!
//! The payload is one string. No `url` field, no `title`, no subject
//! line: those are knobs only some destinations honor (mail reads a
//! subject, a chat app drops it), and a field that works on half the
//! sheet is a styling hook wearing a lanyard. A URL rides as text —
//! every share target accepts text, and the ones that special-case
//! links find the link in it.
//!
//! `available` is iap's posture, not clipboard's: the Linux desktop has
//! no share sheet to show (no portal, no convention — a chooser built
//! from .desktop files would be nokre inventing OS UI), and a browser
//! only sometimes has `navigator.share`. Both answer at runtime so an
//! app ships one build tree and simply draws no share affordance where
//! the platform has none — iap's "do not draw a Buy button" argument.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const services = @import("../services.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

/// Whether this target's shell provides the hook. Referenced only where
/// true, so stub targets never name the extern. Unlike clipboard's
/// switch, `.linux` is *not* blanket-true: the Android JNI shell
/// exports the hook, the Wayland shell deliberately does not (there is
/// no sheet to host), and the abi tells them apart at comptime.
const has_shell_hook = is_wasm or builtin.abi.isAndroid() or switch (builtin.os.tag) {
    .macos, .ios, .windows => true,
    else => false,
};

extern fn nokre_share_show(text: [*]const u8, len: usize) void;

// The web's boot probe: services.js answers `navigator.share`'s
// presence, synchronously, before anything is drawn — iap's
// `nokre_iap_available` shape, with the browser as the store. Named
// only on wasm, so native builds never import it.
extern fn nokre_share_available() i32;

/// The payload cap, checked on the Zig side everywhere so
/// `TextTooLarge` means one thing on every platform. Android sets the
/// bound: the chooser intent crosses the binder transaction buffer —
/// 1 MiB, shared by every transaction the process has in flight, and
/// overflowing it is a process-killing exception, not an error return.
/// 64 KiB keeps the whole intent an order of magnitude clear of a
/// cliff whose exact edge depends on what else is in flight, and a
/// share bigger than that is a document, not a message — share a URL
/// to the document instead (secure_store's refusal, restated).
pub const max_text_bytes = 64 * 1024;

pub const Error = error{ EmptyText, TextTooLarge, Unavailable };

/// Is there a share sheet here at all? Cached at `App.init` — locale's
/// boot-tag pattern: synchronous, no OS call, no error — so it is legal
/// inside `build`, and an app can decide not to draw a share affordance
/// before it draws anything. True on macOS, iOS, Windows, and Android;
/// false on the Linux desktop always; on the web, whatever
/// `navigator.share` answered at boot.
pub fn available(app: *const App) bool {
    return app.services.share.canShare();
}

/// Ask the OS to show its share sheet with `text` on it. The argument
/// checks are pure and run first — `EmptyText` (a sheet with nothing on
/// it shares nothing; open_url's bare-`mailto:` rule) and
/// `TextTooLarge` are producible everywhere, identically — then
/// `Unavailable` is the platform posture `available` already answers.
/// Past the checks the handoff is fire-and-forget.
pub fn show(app: *const App, text: []const u8) Error!void {
    if (text.len == 0) return error.EmptyText;
    if (text.len > max_text_bytes) return error.TextTooLarge;
    if (!available(app)) return error.Unavailable;
    if (comptime builtin.is_test) {
        app.services.share.state.?.journal.record(text);
    } else if (comptime has_shell_hook) {
        nokre_share_show(text.ptr, text.len);
    }
    // No third arm: a hookless target already answered false above.
}

/// What the App carries for this service: the journaling mock under
/// `zig test`; in release, one cached bool — the boot answer to
/// `available` — so unlike clipboard this service writes its own
/// init/deinit pair rather than naming `services.Stateless`.
pub const Service = if (builtin.is_test) Mock else PlatformService;

const PlatformService = struct {
    can_share: bool = false,

    pub fn init(self: *PlatformService, gpa: std.mem.Allocator) !void {
        _ = gpa;
        // The one probe, and the reason `available` needs none later.
        // Native targets answer at comptime; the web asks the page —
        // a value query that fires into nothing, so init order does
        // not care (locale's fire-into-services concern is not this).
        self.can_share = if (comptime is_wasm)
            nokre_share_available() != 0
        else
            has_shell_hook;
    }

    pub fn deinit(self: *PlatformService) void {
        self.can_share = false;
    }

    fn canShare(self: PlatformService) bool {
        return self.can_share;
    }
};

/// The mock's heap half: the boot answer, and every text the app put on
/// the sheet, in order (services.Journal's ownership and no-error
/// rules).
pub const MockState = struct {
    can_share: bool,
    journal: services.Journal([]u8, "share mock"),
};

/// One app's journaling share sheet.
pub const Mock = struct {
    /// The heap half; null only before App.init.
    state: ?*MockState = null,
    /// The seeds `mock()` took, applied by `init` — iap's split.
    boot: Config = .{},

    pub const Config = struct {
        /// False boots the app onto a sheetless target — the Linux
        /// desktop, or a browser without `navigator.share` — where
        /// `available` answers false and `show` is `error.Unavailable`.
        available: bool = true,
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot = config };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        state.* = .{ .can_share = self.boot.available, .journal = .{ .gpa = gpa } };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        const gpa = state.journal.gpa;
        state.journal.deinit();
        gpa.destroy(state);
        self.state = null;
    }

    fn canShare(self: Mock) bool {
        return self.state.?.can_share;
    }

    /// Every text the app handed to the sheet, in order. Borrowed
    /// views. A refused share never journals — empty, over-cap, and
    /// unavailable all return before the OS would have been asked.
    pub fn shares(self: Mock) []const []const u8 {
        return services.borrowed(self.state.?.journal.view());
    }

    /// The per-phase reset (http's rule).
    pub fn clearJournal(self: Mock) void {
        self.state.?.journal.clear();
    }
};
