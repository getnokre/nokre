//! iOS specifics over the shared C shell (../c_shell.zig): run() wiring
//! plus the VoiceOver attachment. Unlike macOS there is no AccessKit
//! library on iOS — the shell maps the same flattened snapshot straight
//! onto UIAccessibility (see shell.m). The software keyboard is driven
//! by the shared `wants_text_input` callback.

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
    // UIApplicationMain never returns; cleanup is the OS reclaiming the
    // process, same as every iOS app.
    const rc = c_shell.nokre_shell_run(&config);
    state.deinit();
    if (rc != 0) return error.ShellFailed;
}

fn onReady(ctx: ?*anyopaque, view: *anyopaque, _: [*:0]const u8) callconv(.c) void {
    const state = c_shell.stateFrom(ctx);
    state.view = view;
    if (accesskit.Ios.attach(view, c_shell.a11yFill, ctx, c_shell.a11yAction, ctx)) |a| {
        state.a11y_handle = a.handle;
        state.a11y_push = pushA11y;
    }
}

fn pushA11y(state: *c_shell.State) void {
    (accesskit.Ios{ .handle = state.a11y_handle.? }).update();
}

fn onWindowFocus(_: ?*anyopaque, _: i32) callconv(.c) void {
    // VoiceOver focus follows the app lifecycle on iOS; nothing to do.
}
