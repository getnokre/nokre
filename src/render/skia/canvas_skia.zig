//! Zig bindings for the Skia C shim (shim/nokre_skia.h) plus the Canvas
//! and Measurer implementations backed by it. Only linked into artifacts
//! built with -Dskia; the pure core never touches this file.
//!
//! Face indices: family * 4 + variant (variant: 0 regular, 1 bold,
//! 2 italic, 3 bold-italic; family: 0 mono, 1 prose), 8 for the icon
//! face (no variants), and 9/10 for the Arabic-script companion
//! (regular/bold) that the shim substitutes for Arabic runs — core
//! never requests it by index. Must match the shim.

const std = @import("std");
const Io = std.Io;
const geometry = @import("../../core/geometry.zig");
const color = @import("../../core/color.zig");
const text = @import("../../core/text.zig");
const app_mod = @import("../../core/app.zig");
const canvas_mod = @import("../canvas.zig");
const renderer = @import("../renderer.zig");
const trace = @import("../../testing/trace.zig");
const golden = @import("../../testing/golden.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;
const Gray = color.Gray;
const Appearance = color.Appearance;
const Canvas = canvas_mod.Canvas;

const HskSurface = opaque {};

extern fn hsk_fonts_load(faces: [*]const [*]const u8, lens: [*]const usize, count: i32) i32;
extern fn hsk_text_width(face: i32, size_px: i32, utf8: [*]const u8, len: usize) i32;
extern fn hsk_surface_create(w: i32, h: i32, scale: i32) ?*HskSurface;
extern fn hsk_surface_destroy(s: *HskSurface) void;
extern fn hsk_surface_pixels(s: *HskSurface) [*]const u8;
extern fn hsk_clear(s: *HskSurface, gray: u8) void;
extern fn hsk_fill_rect(s: *HskSurface, x: i32, y: i32, w: i32, h: i32, radius: i32, gray: u8) void;
extern fn hsk_stroke_rect(s: *HskSurface, x: i32, y: i32, w: i32, h: i32, radius: i32, thickness: i32, gray: u8) void;
extern fn hsk_line(s: *HskSurface, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, gray: u8) void;
extern fn hsk_draw_text(s: *HskSurface, face: i32, size_px: i32, x: i32, baseline: i32, utf8: [*]const u8, len: usize, gray: u8) void;
extern fn hsk_draw_text_rgb(s: *HskSurface, face: i32, size_px: i32, x: i32, baseline: i32, utf8: [*]const u8, len: usize, r: u8, g: u8, b: u8) void;
extern fn hsk_clip_push(s: *HskSurface, x: i32, y: i32, w: i32, h: i32) void;
extern fn hsk_clip_pop(s: *HskSurface) void;
extern fn hsk_dither(s: *HskSurface, x: i32, y: i32, w: i32, h: i32, gray: u8) void;

// The faces nokre will ever render. Bundled, never system — variants
// are real drawn faces from the same upstream builds as the regulars,
// in face-index order.
const face_files = [_][]const u8{
    @embedFile("../../assets/fonts/mono.ttf"),
    @embedFile("../../assets/fonts/mono-bold.ttf"),
    @embedFile("../../assets/fonts/mono-italic.ttf"),
    @embedFile("../../assets/fonts/mono-bolditalic.ttf"),
    @embedFile("../../assets/fonts/prose.ttf"),
    @embedFile("../../assets/fonts/prose-bold.ttf"),
    @embedFile("../../assets/fonts/prose-italic.ttf"),
    @embedFile("../../assets/fonts/prose-bolditalic.ttf"),
    @embedFile("../../assets/fonts/lucide.ttf"),
    @embedFile("../../assets/fonts/arabic.ttf"),
    @embedFile("../../assets/fonts/arabic-bold.ttf"),
    // The vendor sign-in marks, last so every index above is unmoved
    // (src/assets/fonts/LICENSE-Brand.txt). Not nokre's artwork, and
    // not reachable from any consumer-settable face.
    @embedFile("../../assets/fonts/brand.ttf"),
};

// Process-level by nature (Skia's font tables are one C-side registry)
// — a documented exemption from the state-lives-on-the-App rule, with
// the guard the rule requires: the CAS spin keeps two apps booting from
// two threads from racing the one-time load (see workers/thread.zig
// for why not std.Io.Mutex).
var fonts_lock: std.atomic.Value(bool) = .init(false);
var fonts_loaded: std.atomic.Value(bool) = .init(false);

pub fn ensureFontsLoaded() !void {
    if (fonts_loaded.load(.acquire)) return;
    while (fonts_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer fonts_lock.store(false, .release);
    if (fonts_loaded.load(.acquire)) return;
    var ptrs: [face_files.len][*]const u8 = undefined;
    var lens: [face_files.len]usize = undefined;
    for (face_files, &ptrs, &lens) |f, *p, *l| {
        p.* = f.ptr;
        l.* = f.len;
    }
    if (hsk_fonts_load(&ptrs, &lens, face_files.len) == 0) {
        return error.FontLoadFailed;
    }
    fonts_loaded.store(true, .release);
}

fn faceIndex(face: text.Face) i32 {
    const family: i32 = switch (face.family) {
        .mono => 0,
        .prose => 1,
        .icons => return 8, // no variants; flags are ignored
        .brand => return 11, // likewise; 9/10 are the Arabic fallback
    };
    const variant: i32 = @as(i32, @intFromBool(face.bold)) + 2 * @as(i32, @intFromBool(face.italic));
    return family * 4 + variant;
}

/// Text measurement backed by Skia's shaping of the bundled fonts.
pub fn measurer() text.Measurer {
    return .{ .measureFn = skiaMeasure };
}

fn skiaMeasure(_: ?*anyopaque, face: text.Face, size_px: i32, bytes: []const u8) i32 {
    return hsk_text_width(faceIndex(face), size_px, bytes.ptr, bytes.len);
}

/// A CPU raster surface at `scale`x resolution. Draw calls take logical
/// pixels; the shim applies the integer scale transform.
pub const Surface = struct {
    handle: *HskSurface,
    logical_w: i32,
    logical_h: i32,
    scale: i32,

    pub fn init(logical_w: i32, logical_h: i32, scale: i32) !Surface {
        try ensureFontsLoaded();
        const handle = hsk_surface_create(logical_w, logical_h, scale) orelse return error.SurfaceCreateFailed;
        return .{ .handle = handle, .logical_w = logical_w, .logical_h = logical_h, .scale = scale };
    }

    pub fn deinit(self: *Surface) void {
        hsk_surface_destroy(self.handle);
    }

    /// Tightly packed RGBX8888 (4 bytes per pixel; the fourth is padding
    /// readers ignore), (logical_w*scale) x (logical_h*scale). RGB, not
    /// gray8, since the frame format widened for the vendor sign-in mark
    /// — every op but `drawTextRgb` still writes r=g=b
    /// (docs/internals/pixel-model.md).
    pub fn pixels(self: *Surface) []const u8 {
        const n: usize = @intCast(self.logical_w * self.scale * self.logical_h * self.scale * 4);
        return hsk_surface_pixels(self.handle)[0..n];
    }

    pub fn pixelWidth(self: *const Surface) usize {
        return @intCast(self.logical_w * self.scale);
    }

    pub fn pixelHeight(self: *const Surface) usize {
        return @intCast(self.logical_h * self.scale);
    }

    pub fn canvas(self: *Surface) Canvas {
        return .{ .ctx = self.handle, .vtable = &vtable };
    }
};

fn handleFrom(ctx: ?*anyopaque) *HskSurface {
    return @ptrCast(ctx.?);
}

const vtable: Canvas.VTable = .{
    .clear = struct {
        fn f(ctx: ?*anyopaque, gray: Gray, a: Appearance) void {
            hsk_clear(handleFrom(ctx), gray.byte(a));
        }
    }.f,
    .fillRect = struct {
        fn f(ctx: ?*anyopaque, rect: Rect, radius: i32, gray: Gray, a: Appearance) void {
            hsk_fill_rect(handleFrom(ctx), rect.x, rect.y, rect.w, rect.h, radius, gray.byte(a));
        }
    }.f,
    .strokeRect = struct {
        fn f(ctx: ?*anyopaque, rect: Rect, radius: i32, thickness: i32, gray: Gray, a: Appearance) void {
            hsk_stroke_rect(handleFrom(ctx), rect.x, rect.y, rect.w, rect.h, radius, thickness, gray.byte(a));
        }
    }.f,
    .line = struct {
        fn f(ctx: ?*anyopaque, from: Point, to: Point, thickness: i32, gray: Gray, a: Appearance) void {
            hsk_line(handleFrom(ctx), from.x, from.y, to.x, to.y, thickness, gray.byte(a));
        }
    }.f,
    .drawText = struct {
        fn f(ctx: ?*anyopaque, x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, gray: Gray, a: Appearance) void {
            hsk_draw_text(handleFrom(ctx), faceIndex(face), size_px, x, baseline, bytes.ptr, bytes.len, gray.byte(a));
        }
    }.f,
    .drawTextRgb = struct {
        fn f(ctx: ?*anyopaque, x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, rgb: canvas_mod.Rgb) void {
            hsk_draw_text_rgb(handleFrom(ctx), faceIndex(face), size_px, x, baseline, bytes.ptr, bytes.len, rgb.r, rgb.g, rgb.b);
        }
    }.f,
    .pushClip = struct {
        fn f(ctx: ?*anyopaque, rect: Rect) void {
            hsk_clip_push(handleFrom(ctx), rect.x, rect.y, rect.w, rect.h);
        }
    }.f,
    .popClip = struct {
        fn f(ctx: ?*anyopaque) void {
            hsk_clip_pop(handleFrom(ctx));
        }
    }.f,
    .dither = struct {
        fn f(ctx: ?*anyopaque, rect: Rect, gray: Gray, a: Appearance) void {
            hsk_dither(handleFrom(ctx), rect.x, rect.y, rect.w, rect.h, gray.byte(a));
        }
    }.f,
};

/// The pixel twin of `testing.trace.TreeSink`: renders the app through
/// the production Skia pipeline after every step and writes a PPM per
/// frame with the same numbering, so `.txt` and `.ppm` traces pair up.
pub const PixelSink = struct {
    io: Io,
    dir: Io.Dir,
    gpa: std.mem.Allocator,
    sub_dir: []const u8,
    scale: i32 = 1,

    pub fn init(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, sub_dir: []const u8) !PixelSink {
        try dir.createDirPath(io, sub_dir);
        return .{ .io = io, .dir = dir, .gpa = gpa, .sub_dir = sub_dir };
    }

    pub fn observer(self: *PixelSink) trace.StepObserver {
        return .{ .ctx = self, .call = onStepErased };
    }

    fn onStepErased(ctx: ?*anyopaque, step: u32, action: []const u8, app: *app_mod.App) anyerror!void {
        const self: *PixelSink = @ptrCast(@alignCast(ctx.?));
        try self.onStep(step, action, app);
    }

    pub fn onStep(self: *PixelSink, step: u32, action: []const u8, app: *app_mod.App) !void {
        var surface = try Surface.init(app.viewport.w, app.viewport.h, self.scale);
        defer surface.deinit();
        renderer.render(app, surface.canvas());

        var name_buf: [64]u8 = undefined;
        const name = trace.stepFileName(&name_buf, step, action, "ppm");
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.sub_dir, name });
        defer self.gpa.free(path);
        try golden.writePpm(self.io, self.dir, self.gpa, surface.pixels(), surface.pixelWidth(), surface.pixelHeight(), path);
    }
};
