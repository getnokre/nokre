//! Zig side shared by every C-contract shell (src/platform/shell.h):
//! the mirrored config struct, the callback adapters that translate C
//! callbacks into `App.dispatch`, and the a11y fill/action bridge over
//! the flattened semantic snapshot. A platform file (macos.zig, ios.zig)
//! adds only its `run` wiring and a11y adapter attachment.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../core/app.zig");
const editing = @import("../core/editing.zig");
const event_mod = @import("../core/event.zig");
const geometry = @import("../core/geometry.zig");
const input = @import("../core/input.zig");
const layout = @import("../core/layout.zig");
const wrap = @import("../core/wrap.zig");
const semantics = @import("../a11y/semantics.zig");
const accesskit = @import("../a11y/accesskit.zig");

const App = app_mod.App;

/// Mirrors nokre_shell_config in src/platform/shell.h exactly.
pub const ShellConfig = extern struct {
    logical_w: i32,
    logical_h: i32,
    title: [*:0]const u8,
    /// shell.h's app_id: the Wayland desktop-entry basename, null when
    /// the app declared no packaging identity. Defaulted null by
    /// `config`; the Linux platform file fills it (the one consumer).
    app_id: ?[*:0]const u8,
    ctx: ?*anyopaque,
    on_frame: *const fn (ctx: ?*anyopaque, logical_w: i32, logical_h: i32, safe_bottom: i32, scale: i32, out_w: *i32, out_h: *i32) callconv(.c) ?[*]const u8,
    on_pointer: *const fn (ctx: ?*anyopaque, x: i32, y: i32, phase: i32) callconv(.c) void,
    on_key: *const fn (ctx: ?*anyopaque, key: i32, mods: u8) callconv(.c) void,
    on_text: *const fn (ctx: ?*anyopaque, utf8: [*]const u8, len: usize) callconv(.c) void,
    on_scroll: *const fn (ctx: ?*anyopaque, x: i32, y: i32, delta_x: i32, delta_y: i32, phase: i32) callconv(.c) void,
    on_edge_pan: *const fn (ctx: ?*anyopaque, from: i32, dx: i32, phase: i32) callconv(.c) void,
    on_back: *const fn (ctx: ?*anyopaque) callconv(.c) i32,
    on_ime_update: *const fn (ctx: ?*anyopaque, utf8: [*]const u8, len: usize, cursor: usize) callconv(.c) void,
    on_ime_commit: *const fn (ctx: ?*anyopaque, utf8: [*]const u8, len: usize) callconv(.c) void,
    on_ime_cancel: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    wants_frame: *const fn (ctx: ?*anyopaque) callconv(.c) i32,
    wants_text_input: *const fn (ctx: ?*anyopaque) callconv(.c) i32,
    wants_pointer_stream: *const fn (ctx: ?*anyopaque, x: i32, y: i32) callconv(.c) i32,
    on_appearance: *const fn (ctx: ?*anyopaque, dark: i32) callconv(.c) void,
    on_ready: *const fn (ctx: ?*anyopaque, view: *anyopaque, window_class: [*:0]const u8) callconv(.c) void,
    on_window_focus: *const fn (ctx: ?*anyopaque, focused: i32) callconv(.c) void,
};

pub extern fn nokre_shell_run(config: *const ShellConfig) i32;
pub extern fn nokre_shell_request_frame(view: *anyopaque) void;

// ---- worker wake (docs/internals/workers.md) ----
// The one native-side need of the worker service: get the app runtime's `pump()`
// called on the main thread after a worker thread queues a reply. On
// Apple platforms that is a single libdispatch call — no shell code.
// dispatch_get_main_queue() is a C macro over &_dispatch_main_q, and
// dispatch_async_f is callable from any thread. Windows, Android, and
// the desktop Linux (Wayland) shell have no Zig-reachable main queue, so
// the shell lends its loop: nokre_shell_post_main posts the pump to the
// window procedure (Windows), through an ALooper pipe on the main thread
// (Android shell.c), or through an eventfd the Wayland event loop waits
// on alongside the display fd (Linux shell.c).

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;
const is_windows = builtin.os.tag == .windows;
const is_android = builtin.abi.isAndroid();
// Desktop Linux only: Android also reports os.tag == .linux, so exclude
// it (it takes the ALooper leg above, selected by the same predicate).
const is_linux_desktop = builtin.os.tag == .linux and !builtin.abi.isAndroid();

extern var _dispatch_main_q: u8;
extern fn dispatch_async_f(
    queue: *anyopaque,
    context: ?*anyopaque,
    work: *const fn (ctx: ?*anyopaque) callconv(.c) void,
) void;

extern fn nokre_shell_post_main(
    view: *anyopaque,
    work: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) void;

/// The view the post-main wake posts through (Windows: HWND; Android:
/// unused by shell.c but non-null marks readiness). Atomic because
/// worker threads read it while the main thread may still be booting;
/// until it is published there is nowhere to post, and workersViewReady
/// pumps whatever queued in the meantime.
var wake_view: std.atomic.Value(?*anyopaque) = .init(null);

fn workerWake(ctx: ?*anyopaque) void {
    if (comptime is_apple) {
        dispatch_async_f(@ptrCast(&_dispatch_main_q), ctx, workerPumpMain);
    } else if (comptime is_windows or is_android or is_linux_desktop) {
        const view = wake_view.load(.acquire) orelse return;
        nokre_shell_post_main(view, workerPumpMain, ctx);
    }
}

/// The post-main shells' on_ready calls this once the loop's target
/// exists (Windows: the window; Android: the booted shell state): wakes
/// can reach the main loop from here on, and replies a boot-spawned
/// worker queued before there was a target are delivered now.
pub fn workersViewReady(state: *State) void {
    wake_view.store(state.view.?, .release);
    workerPumpMain(state);
}

fn workerPumpMain(ctx: ?*anyopaque) callconv(.c) void {
    const state = stateFrom(ctx);
    _ = state.app.runtime.pump();
    // Handlers invalidate like any action; one frame request covers
    // however many replies just landed.
    if (state.app.needs_frame) {
        if (state.view) |v| nokre_shell_request_frame(v);
    }
}

/// How a shell turns a dirty app into a blittable buffer — the one thing
/// a shell needs from a rendering backend, and therefore the whole seam.
/// The shell layer never names the backend: `skia_frame.zig` installs the
/// Skia source, and a future edition installs its own instead of forking
/// five shells (docs/internals/renderer-editions.md).
pub const FrameSource = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Draws the current tree at `scale` and returns the buffer to
        /// blit, reporting its device-pixel dimensions. Null means no
        /// frame could be produced; the shell blits nothing and keeps
        /// whatever is on screen.
        render: *const fn (
            ctx: ?*anyopaque,
            app: *App,
            w: i32,
            h: i32,
            scale: i32,
            out_w: *i32,
            out_h: *i32,
        ) ?[*]const u8,
        deinit: *const fn (ctx: ?*anyopaque) void,
    };
};

pub const State = struct {
    app: *App,
    /// Installed by the platform file before `config` (skia_frame.install);
    /// a shell without one reports every frame as unavailable.
    frame_source: ?FrameSource = null,
    view: ?*anyopaque = null,
    a11y_nodes: std.ArrayList(accesskit.CNode) = .empty,
    /// Opaque handle to the platform a11y adapter, owned by the platform
    /// file; `a11y_push` runs after every rendered frame when set.
    a11y_handle: ?*anyopaque = null,
    a11y_push: ?*const fn (state: *State) void = null,

    pub fn deinit(self: *State) void {
        // Workers ride the app's runtime now; app.deinit joins them.
        wake_view.store(null, .monotonic);
        self.a11y_nodes.deinit(self.app.gpa);
        if (self.frame_source) |fs| fs.vtable.deinit(fs.ctx);
        self.frame_source = null;
    }
};

/// Fills the config with the shared adapters; the caller supplies what
/// differs. Fonts and the measurer come with the frame source the
/// platform file installs beforehand — this layer names no backend. The
/// clipboard needs no wiring either: the service calls the shell's C hook
/// directly.
pub fn config(
    state: *State,
    title: [*:0]const u8,
    on_ready: *const fn (ctx: ?*anyopaque, view: *anyopaque, window_class: [*:0]const u8) callconv(.c) void,
    on_window_focus: *const fn (ctx: ?*anyopaque, focused: i32) callconv(.c) void,
) ShellConfig {
    if (comptime is_apple or is_windows or is_android or is_linux_desktop) state.app.runtime.installWake(state, workerWake);
    state.app.invalidate();
    return .{
        .logical_w = state.app.viewport.w,
        .logical_h = state.app.viewport.h,
        .title = title,
        .app_id = null,
        .ctx = state,
        .on_frame = onFrame,
        .on_pointer = onPointer,
        .on_key = onKey,
        .on_text = onText,
        .on_scroll = onScroll,
        .on_edge_pan = onEdgePan,
        .on_back = onBack,
        .on_ime_update = onImeUpdate,
        .on_ime_commit = onImeCommit,
        .on_ime_cancel = onImeCancel,
        .wants_frame = wantsFrame,
        .wants_text_input = wantsTextInput,
        .wants_pointer_stream = wantsPointerStream,
        .on_appearance = onAppearance,
        .on_ready = on_ready,
        .on_window_focus = on_window_focus,
    };
}

pub fn stateFrom(ctx: ?*anyopaque) *State {
    return @ptrCast(@alignCast(ctx.?));
}

fn onFrame(ctx: ?*anyopaque, logical_w: i32, logical_h: i32, safe_bottom: i32, scale: i32, out_w: *i32, out_h: *i32) callconv(.c) ?[*]const u8 {
    const state = stateFrom(ctx);
    const app = state.app;

    const w = @max(logical_w, 1);
    const h = @max(logical_h, 1);
    if (app.viewport.w != w or app.viewport.h != h) {
        app.setViewport(.{ .w = w, .h = h });
    }
    app.setSafeBottom(std.math.clamp(safe_bottom, 0, h - 1));

    // Reconciling what the OS reported is the shell's share of a frame;
    // producing the pixels is the backend's (skia_frame.zig).
    const source = state.frame_source orelse return null;
    const pixels = source.vtable.render(source.ctx, app, w, h, scale, out_w, out_h) orelse return null;
    if (state.a11y_push) |push| push(state);
    return pixels;
}

/// A C ordinal back as its enum: a bounds check, not a second map —
/// event.zig's wire pins are what make that honest. Out of range is a
/// shell bug; the event is dropped rather than invented.
fn enumFromC(comptime E: type, v: i32) ?E {
    if (v < 0 or v >= @typeInfo(E).@"enum".fields.len) return null;
    return @enumFromInt(v);
}

fn onPointer(ctx: ?*anyopaque, x: i32, y: i32, phase: i32) callconv(.c) void {
    const p = enumFromC(event_mod.Pointer.Phase, phase) orelse return;
    stateFrom(ctx).app.dispatch(.{ .pointer = .{ .at = .{ .x = x, .y = y }, .phase = p } }) catch {};
}

fn onKey(ctx: ?*anyopaque, key: i32, mods: u8) callconv(.c) void {
    // NOKRE_KEY_* is the one 1-based block — 0 is a shell's "not a
    // control key" — so the enum sits at C value − 1.
    const k = enumFromC(event_mod.Key, key - 1) orelse return;
    // The high nibble is room shell.h has not spent: masked, so a
    // flag added there is ignored here until it is wired, never
    // smuggled into padding.
    const m: event_mod.Modifiers = @bitCast(mods & 0x0f);
    stateFrom(ctx).app.dispatch(.{ .key_down = .{ .key = k, .mods = m } }) catch {};
}

fn onText(ctx: ?*anyopaque, utf8: [*]const u8, len: usize) callconv(.c) void {
    stateFrom(ctx).app.dispatch(.{ .text = .{ .bytes = utf8[0..len] } }) catch {};
}

fn onScroll(ctx: ?*anyopaque, x: i32, y: i32, delta_x: i32, delta_y: i32, phase: i32) callconv(.c) void {
    const p = enumFromC(event_mod.ScrollPhase, phase) orelse return;
    stateFrom(ctx).app.dispatch(.{ .scroll = .{ .at = .{ .x = x, .y = y }, .delta_x = delta_x, .delta_y = delta_y, .phase = p } }) catch {};
}

fn onEdgePan(ctx: ?*anyopaque, from: i32, dx: i32, phase: i32) callconv(.c) void {
    const p = enumFromC(event_mod.EdgePan.Phase, phase) orelse return;
    const edge = enumFromC(event_mod.EdgePan.Edge, from) orelse return;
    stateFrom(ctx).app.dispatch(.{ .edge_pan = .{ .from = edge, .dx = dx, .phase = p } }) catch {};
}

/// The platform's own back command. Returns whether nokre consumed it;
/// a shell whose OS owns back (Android) finishes the activity when it
/// did not. `depth` is asked *before* the pop for exactly that reason —
/// afterwards there is no way to tell "went back" from "was already at
/// the root".
fn onBack(ctx: ?*anyopaque) callconv(.c) i32 {
    const state = stateFrom(ctx);
    if (state.app.router.depth() <= 1) return 0;
    state.app.navigateBack() catch return 0;
    return 1;
}

fn onImeUpdate(ctx: ?*anyopaque, utf8: [*]const u8, len: usize, cursor: usize) callconv(.c) void {
    stateFrom(ctx).app.dispatch(.{ .ime = .{ .update = .{ .composition = utf8[0..len], .cursor = cursor } } }) catch {};
}

fn onImeCommit(ctx: ?*anyopaque, utf8: [*]const u8, len: usize) callconv(.c) void {
    stateFrom(ctx).app.dispatch(.{ .ime = .{ .commit = .{ .text = utf8[0..len] } } }) catch {};
}

fn onImeCancel(ctx: ?*anyopaque) callconv(.c) void {
    stateFrom(ctx).app.dispatch(.{ .ime = .cancel }) catch {};
}

fn onAppearance(ctx: ?*anyopaque, dark: i32) callconv(.c) void {
    stateFrom(ctx).app.setSystemAppearance(if (dark != 0) .dark else .light);
}

fn wantsFrame(ctx: ?*anyopaque) callconv(.c) i32 {
    return if (stateFrom(ctx).app.needs_frame) 1 else 0;
}

fn wantsTextInput(ctx: ?*anyopaque) callconv(.c) i32 {
    return if (editing.focusedEditable(stateFrom(ctx).app) != null) 1 else 0;
}

fn wantsPointerStream(ctx: ?*anyopaque, x: i32, y: i32) callconv(.c) i32 {
    return if (input.wantsPointerStream(stateFrom(ctx).app, .{ .x = x, .y = y })) 1 else 0;
}

// ---- accessibility bridge (flattened snapshot in, actions out) ----

pub fn a11yFill(ctx: ?*anyopaque, count: *usize, focus_id: *u64) callconv(.c) ?[*]const accesskit.CNode {
    const state = stateFrom(ctx);
    const app = state.app;
    state.a11y_nodes.clearRetainingCapacity();
    var snap = semantics.snapshot(app.gpa, app) catch return null;
    defer snap.deinit();
    focus_id.* = accesskit.flatten(&snap, app.gpa, &state.a11y_nodes) catch return null;
    count.* = state.a11y_nodes.items.len;
    return state.a11y_nodes.items.ptr;
}

pub fn a11yAction(ctx: ?*anyopaque, target: u64, action: i32) callconv(.c) void {
    const state = stateFrom(ctx);
    const app = state.app;
    const stop = accesskit.focusFromU64(target) orelse return;
    const el = app.tree.getConst(stop.node) orelse return;
    switch (action) {
        accesskit.action_click => {
            app.performLayout();
            // An inline link is clicked at the middle of its first
            // rect; the whole paragraph's centre would land on prose.
            var buf: [wrap.max_span_rects]geometry.Rect = undefined;
            const r = if (stop.span) |i| blk: {
                const rects = input.spanRectsOf(app, stop.node, i, &buf);
                if (rects.len == 0) return;
                break :blk rects[0];
            } else app.tree.rectOf(stop.node);
            if (r.isEmpty()) return;
            app.tap(.{ .x = r.x + @divTrunc(r.w, 2), .y = r.y + @divTrunc(r.h, 2) }) catch return;
        },
        accesskit.action_focus => {
            if (stop.span == null and !el.isFocusable()) return;
            app.focused = stop;
            app.needs_frame = true;
        },
        else => return,
    }
    if (state.view) |v| nokre_shell_request_frame(v);
}
