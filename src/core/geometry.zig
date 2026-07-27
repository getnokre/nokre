//! Integer-only geometry. nokre has no floats in layout — that is the
//! foundation of the pixel-determinism guarantee.

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    w: i32,
    h: i32,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub const zero: Rect = .{};

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x < self.right() and p.y >= self.y and p.y < self.bottom();
    }

    pub fn inset(self: Rect, amount: i32) Rect {
        return .{
            .x = self.x + amount,
            .y = self.y + amount,
            .w = @max(0, self.w - 2 * amount),
            .h = @max(0, self.h - 2 * amount),
        };
    }

    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.right(), other.right());
        const y1 = @min(self.bottom(), other.bottom());
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn center(self: Rect) Point {
        return .{ .x = self.x + @divTrunc(self.w, 2), .y = self.y + @divTrunc(self.h, 2) };
    }
};

const std = @import("std");

test "rect contains is half-open" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 5, .h = 5 };
    try std.testing.expect(r.contains(.{ .x = 10, .y = 10 }));
    try std.testing.expect(r.contains(.{ .x = 14, .y = 14 }));
    try std.testing.expect(!r.contains(.{ .x = 15, .y = 10 }));
}

test "inset never goes negative" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 };
    const s = r.inset(10);
    try std.testing.expectEqual(@as(i32, 0), s.w);
    try std.testing.expectEqual(@as(i32, 0), s.h);
}

test "intersect of disjoint rects is empty" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: Rect = .{ .x = 20, .y = 20, .w = 10, .h = 10 };
    try std.testing.expect(a.intersect(b).isEmpty());
}
