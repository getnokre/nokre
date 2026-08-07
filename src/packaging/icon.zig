//! icon — the app icon, derived from the declaration like everything
//! else packaging emits.
//!
//! nokre refuses custom visual identity (docs/introduction.md), and the
//! icon is where that refusal meets the home screen: the mark is a pure
//! function of the declared reverse-DNS id — a 5×5 horizontally
//! symmetric grid of palette grays on paper — so every app gets a
//! legible, distinct icon with zero art assets, and the same id renders
//! the same icon on every platform, forever. Renaming the display name
//! keeps the mark; changing the id is a new identity and honestly gets a
//! new mark.
//!
//! Serialization is PNG written in the repository's own encoder
//! ([image/png.zig](../image/png.zig)) rather than reached for, because
//! an external one (or std.compress, whose output bytes may change
//! between releases) would put the byte-exactness of the manifest
//! goldens at the mercy of someone else's release notes. Flat regions
//! are all an identicon has, so that encoder's run-length matches alone
//! keep even the 1024px icon around 15 KiB. Grayscale 8-bit, no alpha:
//! launcher icons must be opaque on iOS, and the paper field doubles as
//! the icon's own background everywhere else.
//!
//! Integer math only, the core rule, even though this never ships in an
//! app: icon bytes are golden-tested (packaging_test.zig) and must not
//! depend on the host.

const std = @import("std");
// The one import outside std, and it is below packaging rather than
// beside it: `image/png.zig` names std alone, so the rule that packaging
// reaches no layer of the library still holds
// (docs/internals/architecture.md).
const png_mod = @import("../image/png.zig");

/// The mark's grid — 5 is the smallest side where horizontal mirroring
/// (the trick that makes arbitrary hash bits read as a deliberate
/// glyph) still leaves 15 free cells, enough that distinct ids collide
/// with probability ~4^-15.
pub const grid = 5;

// The palette bytes, restated from src/core/color.zig by value: the
// packaging layer never imports core (docs/internals/architecture.md),
// and the color design proofs pin these bytes anyway — drift would fail
// that build before it could skew an icon.
const ink: u8 = 0x00;
const mid: u8 = 0x6A;
const paper: u8 = 0xFF;

/// The mark: paper field, cells in ink or mid. Two hash bits per cell —
/// half the cells stay paper, a quarter go mid, a quarter ink — mirrored
/// about the center column. FNV-1a is fixed by reference for all time,
/// which is the property that matters more than its distribution here.
pub fn derive(id: []const u8) [grid][grid]u8 {
    const hash = std.hash.Fnv1a_64.hash(id);
    var cells: [grid][grid]u8 = @splat(@splat(paper));
    var marked = false;
    var bit: u6 = 0;
    for (0..grid) |row| {
        for (0..(grid + 1) / 2) |col| {
            const two: u2 = @truncate(hash >> bit);
            bit +%= 2;
            const shade: u8 = switch (two) {
                0b11 => ink,
                0b10 => mid,
                else => paper,
            };
            cells[row][col] = shade;
            cells[row][grid - 1 - col] = shade;
            if (shade != paper) marked = true;
        }
    }
    // 2^-30 of ids hash to a blank field; a blank icon is still wrong
    // for every one of them.
    if (!marked) cells[grid / 2][grid / 2] = ink;
    return cells;
}

/// The icon as a complete PNG: `size`×`size` paper square with the mark
/// centered at `cell` pixels per grid cell. Callers pick `cell` so the
/// mark's footprint (5×cell) fits the platform's safe zone — the tables
/// live with the packaging emitters. When size − 5×cell is odd the
/// spare pixel goes right/bottom; at icon sizes a 1px bias is invisible
/// and the alternative is a fractional coordinate.
pub fn png(gpa: std.mem.Allocator, id: []const u8, size: u32, cell: u32) error{OutOfMemory}![]u8 {
    std.debug.assert(cell > 0 and grid * cell <= size);
    const cells = derive(id);
    const margin = (size - grid * cell) / 2;

    const samples = try gpa.alloc(u8, size * size);
    defer gpa.free(samples);
    var i: usize = 0;
    for (0..size) |y| {
        const row: ?usize = if (y >= margin and y < margin + grid * cell) (y - margin) / cell else null;
        for (0..size) |x| {
            const col: ?usize = if (x >= margin and x < margin + grid * cell) (x - margin) / cell else null;
            samples[i] = if (row != null and col != null) cells[row.?][col.?] else paper;
            i += 1;
        }
    }
    return png_mod.gray8(gpa, samples, size, size);
}

test "the mark is symmetric, deterministic, and never blank" {
    const a = derive("dev.nokre.kitchensink_test");
    const b = derive("dev.nokre.kitchensink_test");
    try std.testing.expectEqual(a, b);
    var marked = false;
    for (a, 0..) |row, r| {
        for (row, 0..) |shade, c| {
            try std.testing.expectEqual(shade, a[r][grid - 1 - c]);
            if (shade != paper) marked = true;
        }
    }
    try std.testing.expect(marked);
    // Distinct ids draw distinct marks (not guaranteed in general —
    // 2^-30 — but locked for the ids the repo itself ships).
    try std.testing.expect(!std.meta.eql(a, derive("dev.nokre.hello")));
}

test "png carries the declared dimensions and valid chunk CRCs" {
    const bytes = try png(std.testing.allocator, "dev.nokre.check", 48, 6);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }, bytes[0..8]);
    try std.testing.expectEqual(@as(u32, 48), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u32, 48), std.mem.readInt(u32, bytes[20..24], .big));
    // Walk every chunk, re-deriving each CRC.
    var i: usize = 8;
    var saw_iend = false;
    while (i < bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const crc = std.hash.Crc32.hash(bytes[i + 4 ..][0 .. 4 + len]);
        try std.testing.expectEqual(crc, std.mem.readInt(u32, bytes[i + 8 + len ..][0..4], .big));
        saw_iend = std.mem.eql(u8, bytes[i + 4 ..][0..4], "IEND");
        i += 12 + len;
    }
    try std.testing.expect(saw_iend);
    try std.testing.expectEqual(bytes.len, i);
}

test "flat fields stay small — the deflate is doing its one job" {
    const bytes = try png(std.testing.allocator, "dev.nokre.kitchensink_test", 1024, 128);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len < 20 * 1024);
}

/// The mark as an `.icns` — macOS's icon container, and the one format
/// that only exists because the app is a bundle now
/// (docs/internals/notifications.md explains why there is one).
///
/// ICNS is a tagged container, not an image format: a 4-byte magic, a
/// big-endian total length, then `(type, length, payload)` entries. Every
/// type below takes a PNG payload on macOS 10.8 and newer, so the same
/// `png` derivation every other platform gets is what goes in — nothing
/// is resampled, re-encoded, or invented here. Integer math throughout,
/// like the rest of packaging.
///
/// The five sizes are the ones Finder, the Dock and the notification
/// centre actually ask for; `ic10` is the 1024 retina slot Apple wants a
/// modern icon to carry.
pub const icns_entries = [_]struct { tag: *const [4]u8, size: u32, cell: u32 }{
    .{ .tag = "ic11", .size = 32, .cell = 4 },
    .{ .tag = "ic12", .size = 64, .cell = 8 },
    .{ .tag = "ic07", .size = 128, .cell = 16 },
    .{ .tag = "ic13", .size = 256, .cell = 32 },
    .{ .tag = "ic14", .size = 512, .cell = 64 },
    .{ .tag = "ic10", .size = 1024, .cell = 128 },
};

pub fn icns(gpa: std.mem.Allocator, id: []const u8) error{OutOfMemory}![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    for (icns_entries) |entry| {
        const image = try png(gpa, id, entry.size, entry.cell);
        defer gpa.free(image);
        try body.appendSlice(gpa, entry.tag);
        try body.appendSlice(gpa, &beU32(@intCast(image.len + 8)));
        try body.appendSlice(gpa, image);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "icns");
    try out.appendSlice(gpa, &beU32(@intCast(body.items.len + 8)));
    try out.appendSlice(gpa, body.items);
    body.deinit(gpa);
    return out.toOwnedSlice(gpa);
}

fn beU32(v: u32) [4]u8 {
    return .{
        @intCast((v >> 24) & 0xFF),
        @intCast((v >> 16) & 0xFF),
        @intCast((v >> 8) & 0xFF),
        @intCast(v & 0xFF),
    };
}
