//! One platform contract, five thin shells. The shell's whole job:
//! create a surface, deliver input events, blit the CPU-rendered frame.
//! Everything intelligent lives above this line.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../core/geometry.zig");
const app_mod = @import("../core/app.zig");
const pkg_options = @import("nokre_package_info_options");

pub const RunOptions = struct {
    title: []const u8 = "nokre",
    /// The window's application identity for the OS — on Wayland the
    /// xdg_toplevel app_id, which compositors match against the
    /// desktop-entry basename (`<app_id>.desktop`) for the icon, task
    /// grouping, and the deep-link handler registration. Defaulted from
    /// the packaging declaration (build.zig's .pkg_id) so it cannot
    /// drift from the .desktop file `zig build pkg`'s id names; null —
    /// no declared identity — means no app_id is set at all, because a
    /// wrong id breaks the association worse than none. Only the Linux
    /// shell consumes it: every other platform derives identity from
    /// the bundle or package, not from the window.
    app_id: ?[]const u8 = if (pkg_options.linked) pkg_options.id else null,
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
