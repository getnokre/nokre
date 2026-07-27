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

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!quiet) std.debug.print(fmt, args);
}
