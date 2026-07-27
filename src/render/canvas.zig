//! The drawing vocabulary. Eight operations — everything nokre can ever
//! put on screen. Backends: the Skia shim (production), a recording canvas
//! (renderer tests).

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const color = @import("../core/color.zig");
const text = @import("../core/text.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;
const Gray = color.Gray;
const Appearance = color.Appearance;

pub const Canvas = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,
    /// Which ramp a `Gray` resolves through. `render` stamps this from
    /// the app; the escapes pin it (see `light`). Backends resolve —
    /// the recording canvas keeps the authored step, so renderer tests
    /// still read in palette terms rather than bytes.
    appearance: Appearance = .light,

    pub const VTable = struct {
        clear: *const fn (ctx: ?*anyopaque, gray: Gray, a: Appearance) void,
        fillRect: *const fn (ctx: ?*anyopaque, rect: Rect, radius: i32, gray: Gray, a: Appearance) void,
        strokeRect: *const fn (ctx: ?*anyopaque, rect: Rect, radius: i32, thickness: i32, gray: Gray, a: Appearance) void,
        line: *const fn (ctx: ?*anyopaque, from: Point, to: Point, thickness: i32, gray: Gray, a: Appearance) void,
        drawText: *const fn (ctx: ?*anyopaque, x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, gray: Gray, a: Appearance) void,
        pushClip: *const fn (ctx: ?*anyopaque, rect: Rect) void,
        popClip: *const fn (ctx: ?*anyopaque) void,
        /// 1px checkerboard of `gray` over the rect: the palette-pure
        /// scrim — no alpha, so no off-palette grays can appear.
        dither: *const fn (ctx: ?*anyopaque, rect: Rect, gray: Gray, a: Appearance) void,
    };

    /// The same canvas pinned to the light ramp. Two surfaces want true
    /// ink on true paper whatever the appearance: the QR tile, because a
    /// scanner wants maximum modulation and a photo-negative code is a
    /// different code, and the vendor sign-in marks, because Apple's HIG
    /// sanctions black / white / white-outlined and nothing between.
    /// Both then draw `.g0` and `.g12` explicitly — the two steps the
    /// design system itself no longer uses.
    pub fn light(self: Canvas) Canvas {
        return .{ .ctx = self.ctx, .vtable = self.vtable, .appearance = .light };
    }

    pub fn clear(self: Canvas, gray: Gray) void {
        self.vtable.clear(self.ctx, gray, self.appearance);
    }
    pub fn fillRect(self: Canvas, rect: Rect, radius: i32, gray: Gray) void {
        self.vtable.fillRect(self.ctx, rect, radius, gray, self.appearance);
    }
    pub fn strokeRect(self: Canvas, rect: Rect, radius: i32, thickness: i32, gray: Gray) void {
        self.vtable.strokeRect(self.ctx, rect, radius, thickness, gray, self.appearance);
    }
    pub fn line(self: Canvas, from: Point, to: Point, thickness: i32, gray: Gray) void {
        self.vtable.line(self.ctx, from, to, thickness, gray, self.appearance);
    }
    pub fn drawText(self: Canvas, x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, gray: Gray) void {
        self.vtable.drawText(self.ctx, x, baseline, face, size_px, bytes, gray, self.appearance);
    }
    pub fn pushClip(self: Canvas, rect: Rect) void {
        self.vtable.pushClip(self.ctx, rect);
    }
    pub fn popClip(self: Canvas) void {
        self.vtable.popClip(self.ctx);
    }
    pub fn dither(self: Canvas, rect: Rect, gray: Gray) void {
        self.vtable.dither(self.ctx, rect, gray, self.appearance);
    }
};

/// Records every draw call. Used by renderer unit tests; text slices are
/// borrowed from the tree, so keep the tree alive while asserting.
pub const Recording = struct {
    gpa: std.mem.Allocator,
    ops: std.ArrayList(Op),
    /// The appearance the last op was drawn under. Ops keep the authored
    /// step rather than the resolved byte — the ramps are proven in
    /// color.zig, and renderer tests are about which step a draw site
    /// picked, not what it rasterized to.
    appearance: Appearance = .light,

    pub const DrawText = struct { x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, gray: Gray };

    pub const Op = union(enum) {
        clear: Gray,
        fill_rect: struct { rect: Rect, radius: i32, gray: Gray },
        stroke_rect: struct { rect: Rect, radius: i32, thickness: i32, gray: Gray },
        line: struct { from: Point, to: Point, thickness: i32, gray: Gray },
        draw_text: DrawText,
        push_clip: Rect,
        pop_clip,
        dither: struct { rect: Rect, gray: Gray },
    };

    pub fn init(gpa: std.mem.Allocator) Recording {
        return .{ .gpa = gpa, .ops = .empty };
    }

    pub fn deinit(self: *Recording) void {
        self.ops.deinit(self.gpa);
    }

    pub fn canvas(self: *Recording) Canvas {
        return .{ .ctx = self, .vtable = &recording_vtable };
    }

    /// The recorded ops of one kind, in draw order. Almost every
    /// renderer assertion is about a single kind — what was written and
    /// where, what was filled and in which step — so this is the walk
    /// the tests take rather than each of them re-opening the union.
    pub fn opsOf(self: *const Recording, comptime kind: std.meta.Tag(Op)) OpIterator(kind) {
        return .{ .ops = self.ops.items };
    }

    pub fn OpIterator(comptime kind: std.meta.Tag(Op)) type {
        return struct {
            ops: []const Op,
            i: usize = 0,

            pub fn next(self: *@This()) ?@FieldType(Op, @tagName(kind)) {
                while (self.i < self.ops.len) : (self.i += 1) {
                    if (self.ops[self.i] == kind) {
                        defer self.i += 1;
                        return @field(self.ops[self.i], @tagName(kind));
                    }
                }
                return null;
            }
        };
    }

    pub fn containsText(self: *const Recording, needle: []const u8) bool {
        var it = self.opsOf(.draw_text);
        while (it.next()) |t| {
            if (std.mem.indexOf(u8, t.bytes, needle) != null) return true;
        }
        return false;
    }

    fn recordPlain(ctx: ?*anyopaque, op: Op) void {
        const self: *Recording = @ptrCast(@alignCast(ctx.?));
        self.ops.append(self.gpa, op) catch @panic("recording canvas OOM");
    }

    fn record(ctx: ?*anyopaque, op: Op, a: Appearance) void {
        const self: *Recording = @ptrCast(@alignCast(ctx.?));
        self.appearance = a;
        recordPlain(ctx, op);
    }

    const recording_vtable: Canvas.VTable = .{
        .clear = struct {
            fn f(ctx: ?*anyopaque, gray: Gray, a: Appearance) void {
                record(ctx, .{ .clear = gray }, a);
            }
        }.f,
        .fillRect = struct {
            fn f(ctx: ?*anyopaque, rect: Rect, radius: i32, gray: Gray, a: Appearance) void {
                record(ctx, .{ .fill_rect = .{ .rect = rect, .radius = radius, .gray = gray } }, a);
            }
        }.f,
        .strokeRect = struct {
            fn f(ctx: ?*anyopaque, rect: Rect, radius: i32, thickness: i32, gray: Gray, a: Appearance) void {
                record(ctx, .{ .stroke_rect = .{ .rect = rect, .radius = radius, .thickness = thickness, .gray = gray } }, a);
            }
        }.f,
        .line = struct {
            fn f(ctx: ?*anyopaque, from: Point, to: Point, thickness: i32, gray: Gray, a: Appearance) void {
                record(ctx, .{ .line = .{ .from = from, .to = to, .thickness = thickness, .gray = gray } }, a);
            }
        }.f,
        .drawText = struct {
            fn f(ctx: ?*anyopaque, x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, gray: Gray, a: Appearance) void {
                record(ctx, .{ .draw_text = .{ .x = x, .baseline = baseline, .face = face, .size_px = size_px, .bytes = bytes, .gray = gray } }, a);
            }
        }.f,
        .pushClip = struct {
            fn f(ctx: ?*anyopaque, rect: Rect) void {
                recordPlain(ctx, .{ .push_clip = rect });
            }
        }.f,
        .popClip = struct {
            fn f(ctx: ?*anyopaque) void {
                recordPlain(ctx, .pop_clip);
            }
        }.f,
        .dither = struct {
            fn f(ctx: ?*anyopaque, rect: Rect, gray: Gray, a: Appearance) void {
                record(ctx, .{ .dither = .{ .rect = rect, .gray = gray } }, a);
            }
        }.f,
    };
};
