//! macOS specifics over the shared C shell (../c_shell.zig): run()
//! wiring plus the AccessKit (VoiceOver) attachment. Single window by
//! design; everything event-shaped lives in c_shell.zig.

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

    // Nothing between here and state.deinit() may fail: the source is
    // freed there, not by an errdefer.
    try skia_frame.install(&state);
    const config = c_shell.config(&state, title_z, onReady, onWindowFocus);
    const rc = c_shell.nokre_shell_run(&config);
    if (state.a11y_handle) |h| (accesskit.Macos{ .handle = h }).detach();
    state.deinit();
    if (rc != 0) return error.ShellFailed;
}

fn onReady(ctx: ?*anyopaque, view: *anyopaque, window_class: [*:0]const u8) callconv(.c) void {
    const state = c_shell.stateFrom(ctx);
    state.view = view;
    if (accesskit.Macos.attach(view, window_class, c_shell.a11yFill, ctx, c_shell.a11yAction, ctx)) |a| {
        state.a11y_handle = a.handle;
        state.a11y_push = pushA11y;
    }
}

fn pushA11y(state: *c_shell.State) void {
    (accesskit.Macos{ .handle = state.a11y_handle.? }).update();
}

fn onWindowFocus(ctx: ?*anyopaque, focused: i32) callconv(.c) void {
    const state = c_shell.stateFrom(ctx);
    if (state.a11y_handle) |h| (accesskit.Macos{ .handle = h }).focusState(focused != 0);
}
