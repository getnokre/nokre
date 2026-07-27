//! One platform contract, six thin shells. The shell's whole job:
//! create a surface, deliver input events, blit the CPU-rendered frame.
//! Everything intelligent lives above this line.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../core/geometry.zig");
const app_mod = @import("../core/app.zig");

pub const RunOptions = struct {
    title: []const u8 = "nokre",
};

pub const backend = switch (builtin.os.tag) {
    .macos => @import("macos/macos.zig"),
    .windows => @import("windows/windows.zig"),
    .ios => @import("ios/ios.zig"),
    .linux => if (builtin.abi.isAndroid())
        @import("android/android.zig")
    else
        @import("linux/linux.zig"),
    // The web has no shell. Its edition is the DOM one
    // (docs/internals/dom-edition.md): the browser owns the event
    // loop and drives render/dom/live.zig's exports, so there is no
    // window to open and no blocking run() to call.
    else => struct {
        pub fn run(_: *app_mod.App, _: RunOptions) !void {
            return error.PlatformNotImplemented;
        }
    },
};

/// Runs the platform event loop until the app exits. The shell renders
/// on demand (when `app.needs_frame`) — nokre never has a frame ticker.
pub fn run(app: *app_mod.App, options: RunOptions) !void {
    return backend.run(app, options);
}
