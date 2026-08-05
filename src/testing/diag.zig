//! The one stderr gate for harness diagnostics.
//!
//! Assertion helpers print rich diagnostics before returning an error —
//! exactly what a developer debugging a real failure needs. But the
//! harness's own negative-path tests trigger those same paths on
//! purpose, and `zig build` reports any run step that writes to stderr
//! under a "failed command" banner even when the step exits 0 and every
//! test passed — output that reads as a system failure to anyone (human
//! or tool) watching the build. So the contract is: every diagnostic
//! goes through here, tests that *expect* a failure mute the gate in a
//! tight scope, and `zig build test` therefore prints nothing unless
//! something is actually wrong.

const std = @import("std");

/// Flipped only by expected-failure tests, always in a block scope:
/// `diag.quiet = true; defer diag.quiet = false;`
///
/// Deliberately module state — the documented exemption from the
/// state-lives-on-the-App rule: this gates *test process* output, not
/// app behavior; nothing an app or a service does reads it, so two
/// concurrently-driven apps cannot disagree through it. The worst a
/// racing flip could do is print (or mute) a diagnostic, cosmetically.
pub var quiet = false;

/// Where the diagnostics go instead of stderr, while one is installed:
/// `diag.sink = &w; defer diag.sink = null;`
///
/// Muting proves a verb *failed*; a sink proves it said something
/// useful. An assertion whose failure prints nothing actionable is a
/// bug in the assertion, so the harness's own tests pin the words —
/// which they can only do if the words are reachable. A sink is
/// implicitly quiet: nothing reaches stderr while one is set, so a
/// capturing test keeps `zig build test` silent for free. Same module
/// state, same exemption, same rationale as `quiet`.
pub var sink: ?*std.Io.Writer = null;

/// A sink and the buffer behind it, for the test that asserts what a
/// refusal *said*:
///
/// ```zig
/// var said: diag.Capture = .{};
/// said.start();
/// defer said.stop();
/// try std.testing.expectError(error.RequestMismatch, t.expectRequest("/notes", .{ .method = .PUT }));
/// try std.testing.expectEqualStrings("POST https://…/notes: expected method PUT\n", said.text());
/// ```
///
/// `stop` is idempotent, so pairing `start` with a `defer` restores
/// stderr even when the expectation itself fails. An over-long
/// diagnostic truncates rather than erroring — a short message the
/// test can widen the buffer for, never a failure attributed to the
/// code under test.
pub const Capture = struct {
    buf: [1024]u8 = undefined,
    w: std.Io.Writer = undefined,

    pub fn start(self: *Capture) void {
        self.w = std.Io.Writer.fixed(&self.buf);
        sink = &self.w;
    }

    pub fn stop(_: *Capture) void {
        sink = null;
    }

    pub fn text(self: *Capture) []const u8 {
        return self.w.buffered();
    }
};

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (sink) |w| {
        // A full fixed buffer truncates rather than failing: a test
        // that under-sized its buffer should see a short message it
        // can fix, not an error from the code under test.
        w.print(fmt, args) catch {};
        return;
    }
    if (!quiet) std.debug.print(fmt, args);
}
