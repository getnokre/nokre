//! Android shell — Zig side. Android owns the event loop (the
//! Activity), so like the web there is no blocking run(): shell.c (the
//! JNI native side, compiled by the example's CMake) drives the
//! exports below, which forward into the same shared c_shell adapters
//! every native shell uses. The Java half
//! (java/dev/nokre/shell/NokreView.java + NokreActivity.java) plays the
//! role shell.m plays on iOS: surface, touch, soft keyboard + IME via
//! InputConnection, TalkBack via AccessibilityNodeProvider — built
//! from the same flattened a11y snapshot, no AccessKit library (the
//! iOS bargain: the platform natively consumes a flat element list).
//!
//! The app comes from the consumer: the root module exports
//! `nokreAndroidBuild(gpa) !*App` (see examples/kitchen_sink/main.zig)
//! and `nokre_android_boot` calls it — `main` never runs; the Activity is
//! already alive when the library loads.
//!
//! Strings arriving from shell.c (text, IME) are borrowed for the call,
//! exactly the C shell contract; dispatch copies what it keeps.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const platform = @import("../platform.zig");
const c_shell = @import("../c_shell.zig");
const skia_frame = @import("../skia_frame.zig");
const accesskit = @import("../../a11y/accesskit.zig");

const App = app_mod.App;

pub fn run(_: *App, _: platform.RunOptions) !void {
    // On Android the event loop belongs to the OS; shell.c drives the
    // exports below instead of a blocking run().
    return error.PlatformNotImplemented;
}

var state: c_shell.State = undefined;
var shell: c_shell.ShellConfig = undefined;
var booted = false;

comptime {
    if (builtin.abi.isAndroid()) {
        @export(&nokreBoot, .{ .name = "nokre_android_boot" });
        @export(&nokreFrame, .{ .name = "nokre_android_frame" });
        @export(&nokrePointer, .{ .name = "nokre_android_pointer" });
        @export(&nokreKey, .{ .name = "nokre_android_key" });
        @export(&nokreText, .{ .name = "nokre_android_text" });
        @export(&nokreScroll, .{ .name = "nokre_android_scroll" });
        @export(&nokreBack, .{ .name = "nokre_android_back" });
        @export(&nokreImeUpdate, .{ .name = "nokre_android_ime_update" });
        @export(&nokreImeCommit, .{ .name = "nokre_android_ime_commit" });
        @export(&nokreImeCancel, .{ .name = "nokre_android_ime_cancel" });
        @export(&nokreWantsFrame, .{ .name = "nokre_android_wants_frame" });
        @export(&nokreWantsTextInput, .{ .name = "nokre_android_wants_text_input" });
        @export(&nokreWantsPointerStream, .{ .name = "nokre_android_wants_pointer_stream" });
        @export(&nokreAppearance, .{ .name = "nokre_android_appearance" });
        @export(&nokreWindowFocus, .{ .name = "nokre_android_window_focus" });
        @export(&nokreA11yFill, .{ .name = "nokre_android_a11y_fill" });
        @export(&nokreA11yAction, .{ .name = "nokre_android_a11y_action" });
    }
}

// Snapshot invalidation, pushed after every rendered frame while
// assistive tech listens; shell.c forwards it to the Java view on the
// spot (frames render on the main thread, so the JNIEnv is at hand).
extern fn nokre_android_a11y_changed() void;

fn pushA11y(_: *c_shell.State) void {
    nokre_android_a11y_changed();
}

fn nokreBoot() callconv(.c) i32 {
    const root = @import("root");
    if (comptime !@hasDecl(root, "nokreAndroidBuild")) {
        // Compile-check builds (build.zig check-targets) have no app.
        return 0;
    } else {
        if (booted) return 1;
        // Bionic's malloc is the process heap Skia already allocates
        // from (the NDK link); no reason to run a second allocator
        // beside it.
        const app = root.nokreAndroidBuild(std.heap.c_allocator) catch return 0;
        state = .{ .app = app };
        skia_frame.install(&state) catch return 0;
        shell = c_shell.config(&state, "nokre", onReady, onWindowFocus);
        booted = true;
        // Parity with nokre_shell_run: ready fires once before any event.
        // The "view" is the shell state — shell.c's post-main and
        // request-frame reach the Java view through their own global
        // refs, but a non-null handle keeps a11y actions requesting
        // frames and marks the worker wake target ready.
        shell.on_ready(&state, @ptrCast(&state), "");
        return 1;
    }
}

fn onReady(ctx: ?*anyopaque, view: *anyopaque, _: [*:0]const u8) callconv(.c) void {
    const s = c_shell.stateFrom(ctx);
    s.view = view;
    s.a11y_push = pushA11y;
    // Boot-spawned workers may already have queued replies; publish the
    // wake target and pump them (the Windows on_ready pattern).
    c_shell.workersViewReady(s);
}

fn onWindowFocus(_: ?*anyopaque, _: i32) callconv(.c) void {
    // Only AccessKit consumes window focus (macOS); TalkBack follows
    // the Activity lifecycle on its own.
}

fn nokreFrame(logical_w: i32, logical_h: i32, safe_bottom: i32, scale: i32, out_w: *i32, out_h: *i32) callconv(.c) ?[*]const u8 {
    if (!booted) return null;
    return shell.on_frame(&state, logical_w, logical_h, safe_bottom, scale, out_w, out_h);
}

fn nokrePointer(x: i32, y: i32, phase: i32) callconv(.c) void {
    if (booted) shell.on_pointer(&state, x, y, phase);
}

fn nokreKey(key: i32, mods: u8) callconv(.c) void {
    if (booted) shell.on_key(&state, key, mods);
}

fn nokreText(utf8: [*]const u8, len: usize) callconv(.c) void {
    if (booted) shell.on_text(&state, utf8, len);
}

fn nokreScroll(x: i32, y: i32, delta_x: i32, delta_y: i32, phase: i32) callconv(.c) void {
    if (booted) shell.on_scroll(&state, x, y, delta_x, delta_y, phase);
}
/// The system back, gesture or button. Android is the one platform
/// where back arrives already decided — its gesture navigation owns
/// both screen edges, so nokre never runs a threshold of its own here
/// (docs/internals/haptics.md) and there is no edge-pan leg to pair
/// with this. Returns whether there was a screen to go back to; the
/// Activity finishes when there was not.
fn nokreBack() callconv(.c) i32 {
    return if (booted) shell.on_back(&state) else 0;
}

fn nokreImeUpdate(utf8: [*]const u8, len: usize, cursor: usize) callconv(.c) void {
    if (booted) shell.on_ime_update(&state, utf8, len, cursor);
}

fn nokreImeCommit(utf8: [*]const u8, len: usize) callconv(.c) void {
    if (booted) shell.on_ime_commit(&state, utf8, len);
}

fn nokreImeCancel() callconv(.c) void {
    if (booted) shell.on_ime_cancel(&state);
}

fn nokreWantsFrame() callconv(.c) i32 {
    return if (booted) shell.wants_frame(&state) else 0;
}

fn nokreWantsTextInput() callconv(.c) i32 {
    return if (booted) shell.wants_text_input(&state) else 0;
}

fn nokreWantsPointerStream(x: i32, y: i32) callconv(.c) i32 {
    return if (booted) shell.wants_pointer_stream(&state, x, y) else 0;
}

fn nokreAppearance(dark: i32) callconv(.c) void {
    if (booted) shell.on_appearance(&state, dark);
}

fn nokreWindowFocus(focused: i32) callconv(.c) void {
    if (booted) shell.on_window_focus(&state, focused);
}

// ---- accessibility bridge (same fill/action as macOS, iOS, web) ----
// shell.c walks the returned nokre_a11y_node array (nokre_accesskit.h
// mirrors CNode exactly) and hands each node to the Java provider.

fn nokreA11yFill(count: *usize, focus_id: *u64) callconv(.c) ?[*]const accesskit.CNode {
    if (!booted) return null;
    return c_shell.a11yFill(&state, count, focus_id);
}

fn nokreA11yAction(target: u64, action: i32) callconv(.c) void {
    if (booted) c_shell.a11yAction(&state, target, action);
}
