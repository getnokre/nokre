//! haptic — one signal, one sender: the knock the back gesture fires as
//! it crosses its commit threshold, and again as it crosses back
//! (docs/internals/haptics.md).
//!
//! **Framework-internal, and that is the whole design.** There is no
//! `App.haptic(...)` and there will not be one: "buzz when I say so" is
//! a feedback hook in the same family as a styling hook, and the roster
//! `iap` closed stays closed to consumer-facing capabilities. What earns
//! a `Services` field anyway is the rule that outranks the roster —
//! anything platform-flavored is injected and observable, never a
//! module-global extern nobody can assert against
//! (docs/internals/contributing.md). Under `zig test` the mock journals
//! every knock, so "crossing the threshold knocked once, and crossing
//! back knocked again" is a first-class assertion rather than something
//! only a finger can check.
//!
//! One shell exports the hook, because one shell has a threshold to
//! cross: iOS, via `UIImpactFeedbackGenerator`. Android's own gesture
//! navigation owns the screen edges, so nokre never runs a threshold
//! there — the system back arrives already decided, with the OS's own
//! feedback attached. Everywhere else this compiles to nothing and the
//! extern is never named — clipboard's `has_shell_hook` rule, for the
//! same reason: a service that links nothing costs nothing where the
//! platform has no hook.
//!
//! There is no nokre-side "off" switch: the one shell that fires
//! already honours the system haptics setting (UIImpactFeedbackGenerator
//! respects it), and Android's back feedback is the OS's own. A
//! framework toggle would be a second answer to a question the OS has
//! already asked.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const services = @import("../services.zig");

const App = app_mod.App;

/// Which way the threshold was crossed. Two signals rather than one
/// because they mean opposite things — arming promises a navigation,
/// disarming takes the promise back — and both platforms have distinct
/// constants for exactly that (Android names them ACTIVATE and
/// DEACTIVATE). Explicitly numbered: these cross the C boundary.
pub const Knock = enum(i32) {
    armed = 0,
    disarmed = 1,
};

/// Whether this target's shell provides the hook. One platform runs a
/// threshold of nokre's own; the other five have no edge pan to give
/// feedback about, so they get no extern rather than a no-op one.
const has_shell_hook = builtin.os.tag == .ios;

extern fn nokre_shell_haptic(kind: i32) void;

/// Fires one knock. Called only from the back gesture's threshold
/// crossings (see input.zig's `handleEdgePan`).
pub fn knock(app: *const App, kind: Knock) void {
    if (comptime builtin.is_test) {
        app.services.haptic.state.?.record(kind);
    } else if (comptime has_shell_hook) {
        nokre_shell_haptic(@intFromEnum(kind));
    }
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, nothing in release — the extern call keeps no state.
pub const Service = if (builtin.is_test) Mock else services.Stateless;

/// The mock's heap half: every knock the app fired, in order
/// (services.Journal's no-error rule).
pub const MockState = services.Journal(Knock, "haptic mock");

/// One app's journaling haptics.
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

    /// Every knock the app fired, in order. Borrowed view.
    pub fn fired(self: Mock) []const Knock {
        return self.state.?.view();
    }

    /// The per-phase reset (http's rule).
    pub fn clearJournal(self: Mock) void {
        self.state.?.clear();
    }
};
