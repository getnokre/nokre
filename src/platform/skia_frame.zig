//! The Skia frame source: the surface lifecycle and the render call that
//! turn a dirty app into the gray8 buffer a shell blits.
//!
//! This lives beside the shells rather than inside them. A shell's whole
//! job is events in and blit the buffer it is handed
//! (docs/internals/platform-shells.md) — what is *in* the buffer belongs
//! to the renderer, one layer up. Keeping the surface here is what lets
//! c_shell.zig name no backend at all, so a second renderer edition
//! installs its own source instead of forking five shells
//! (docs/internals/renderer-editions.md).

const std = @import("std");
const app_mod = @import("../core/app.zig");
const renderer = @import("../render/renderer.zig");
const skia = @import("../render/skia/canvas_skia.zig");
const c_shell = @import("c_shell.zig");

const App = app_mod.App;

/// Installs the source on `state` and prepares the app to be measured by
/// it: fonts loaded, measurer swapped off core's fixed one. Called once
/// per shell run, before `c_shell.config`; `state.deinit` frees it.
pub fn install(state: *c_shell.State) !void {
    try skia.ensureFontsLoaded();
    state.app.measurer = skia.measurer();
    const self = try state.app.gpa.create(Source);
    self.* = .{ .gpa = state.app.gpa };
    state.frame_source = .{ .ctx = self, .vtable = &vtable };
}

const Source = struct {
    gpa: std.mem.Allocator,
    surface: ?skia.Surface = null,
};

const vtable: c_shell.FrameSource.VTable = .{ .render = render, .deinit = deinit };

fn render(
    ctx: ?*anyopaque,
    app: *App,
    w: i32,
    h: i32,
    scale: i32,
    out_w: *i32,
    out_h: *i32,
) ?[*]const u8 {
    const self: *Source = @ptrCast(@alignCast(ctx.?));

    // One surface per (size, scale); a resize or a move between displays
    // is the only thing that reallocates.
    const stale = if (self.surface) |s|
        s.logical_w != w or s.logical_h != h or s.scale != scale
    else
        true;
    if (stale) {
        if (self.surface) |*s| s.deinit();
        self.surface = skia.Surface.init(w, h, scale) catch {
            self.surface = null;
            return null;
        };
    }

    var surface = &self.surface.?;
    renderer.render(app, surface.canvas());
    out_w.* = w * scale;
    out_h.* = h * scale;
    return surface.pixels().ptr;
}

fn deinit(ctx: ?*anyopaque) void {
    const self: *Source = @ptrCast(@alignCast(ctx.?));
    if (self.surface) |*s| s.deinit();
    self.gpa.destroy(self);
}
