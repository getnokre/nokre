//! The App nokre's own unit tests build on.
//!
//! Every test needs a viewport and a service set, and almost none is
//! about either: `.services = .mocks()` is what "this test depends on no
//! service state" looks like, and spelling it out two hundred times
//! buried the line that was actually under test. The compile-time
//! enforcement it exists for (App.Options drops the field's default in
//! test builds) is untouched — this states the same thing once.
//!
//! A test that *does* care about a service — a seeded store, a canned
//! HTTP handler, a boot locale — still calls `App.init` itself, as does
//! one that needs routes, a ctx pointer, or a fixed scheme. What varies
//! stays visible at the call site; only what never varies moved here.
//!
//! This is internal. The consumer-facing fixture is testing/harness.zig.

const std = @import("std");
const app_mod = @import("app.zig");

const App = app_mod.App;

/// A `w` x `h` app with every service mocked. The caller deinits.
pub fn init(w: i32, h: i32) !App {
    return App.init(std.testing.allocator, .{
        .viewport = .{ .w = w, .h = h },
        .services = .mocks(),
    });
}

/// `init` with the chrome mirrored (`App.setDirection(.rtl)`) — the RTL
/// half of every direction-sensitive test.
pub fn mirrored(w: i32, h: i32) !App {
    return App.init(std.testing.allocator, .{
        .viewport = .{ .w = w, .h = h },
        .direction = .rtl,
        .services = .mocks(),
    });
}
