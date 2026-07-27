//! Linux specifics over the shared C shell (../c_shell.zig): run()
//! wiring plus the AccessKit (AT-SPI — Orca) attachment. Single window
//! by design; everything event-shaped lives in c_shell.zig and
//! src/platform/linux/shell.c (Wayland). The native side is the one
//! shell that owns its event loop *and* lends it back for worker wakes
//! (like Windows and Android), so on_ready both attaches the a11y
//! adapter and publishes the wake target.

const std = @import("std");
const app_mod = @import("../../core/app.zig");
const platform = @import("../platform.zig");
const c_shell = @import("../c_shell.zig");
const skia_frame = @import("../skia_frame.zig");
const accesskit = @import("../../a11y/accesskit.zig");

const App = app_mod.App;

pub fn run(app: *App, options: platform.RunOptions) !void {
    var state: c_shell.State = .{ .app = app };

    const title_z = try app.gpa.dupeZ(u8, options.title);
    defer app.gpa.free(title_z);

    try skia_frame.install(&state);
    const config = c_shell.config(&state, title_z, onReady, onWindowFocus);
    const rc = c_shell.nokre_shell_run(&config);
    if (state.a11y_handle) |h| (accesskit.Unix{ .handle = h }).detach();
    state.deinit();
    if (rc != 0) return error.ShellFailed;
}

fn onReady(ctx: ?*anyopaque, view: *anyopaque, _: [*:0]const u8) callconv(.c) void {
    const state = c_shell.stateFrom(ctx);
    state.view = view;
    // The AccessKit Unix adapter registers the process on the a11y bus
    // and runs its handlers on its own thread; it takes the surface so
    // the shim can marshal off-thread actions back to the UI loop
    // (accesskit.zig documents the hop). No window class to forward, so
    // the third on_ready argument is unused.
    if (accesskit.Unix.attach(view, c_shell.a11yFill, ctx, c_shell.a11yAction, ctx)) |a| {
        state.a11y_handle = a.handle;
        state.a11y_push = pushA11y;
    }
    // Worker wakes post to this surface's eventfd from here on
    // (docs/internals/workers.md); publish the target and drain anything
    // a boot-spawned worker queued before the loop existed.
    c_shell.workersViewReady(state);
}

fn pushA11y(state: *c_shell.State) void {
    (accesskit.Unix{ .handle = state.a11y_handle.? }).update();
}

fn onWindowFocus(ctx: ?*anyopaque, focused: i32) callconv(.c) void {
    const state = c_shell.stateFrom(ctx);
    if (state.a11y_handle) |h| (accesskit.Unix{ .handle = h }).focusState(focused != 0);
}
