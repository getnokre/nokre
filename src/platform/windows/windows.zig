//! Windows specifics over the shared C shell (../c_shell.zig): run()
//! wiring plus the AccessKit (UIA — Narrator, NVDA, JAWS) attachment.
//! Single window by design; everything event-shaped lives in c_shell.zig
//! and src/platform/windows/shell.c.

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
    if (state.a11y_handle) |h| (accesskit.Windows{ .handle = h }).detach();
    state.deinit();
    if (rc != 0) return error.ShellFailed;
}

fn onReady(ctx: ?*anyopaque, view: *anyopaque, _: [*:0]const u8) callconv(.c) void {
    const state = c_shell.stateFrom(ctx);
    state.view = view;
    if (accesskit.Windows.attach(view, c_shell.a11yFill, ctx, c_shell.a11yAction, ctx)) |a| {
        state.a11y_handle = a.handle;
        state.a11y_push = pushA11y;
    }
    // Worker wakes post to this window from here on (docs/internals/workers.md).
    c_shell.workersViewReady(state);
}

fn pushA11y(state: *c_shell.State) void {
    (accesskit.Windows{ .handle = state.a11y_handle.? }).update();
}

fn onWindowFocus(_: ?*anyopaque, _: i32) callconv(.c) void {
    // The subclassing adapter wraps the window procedure and sees
    // WM_SETFOCUS/WM_KILLFOCUS itself; nothing to forward.
}
