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
//! Serialization is PNG written here in full — signature, chunks, and a
//! fixed-Huffman deflate that knows only literals and distance-1 runs —
//! because an external encoder (or std.compress, whose output bytes may
//! change between releases) would put the byte-exactness of the manifest
//! goldens at the mercy of someone else's release notes. Flat regions
//! are all an identicon has, so run-length matches alone keep even the
//! 1024px icon around 15 KiB (each scanline's filter byte interrupts
//! the run — the cost of refusing distances beyond 1). Grayscale 8-bit, no alpha: launcher icons
//! must be opaque on iOS, and the paper field doubles as the icon's own
//! background everywhere else.
//!
//! Integer math only, the core rule, even though this never ships in an
//! app: icon bytes are golden-tested (packaging_test.zig) and must not
//! depend on the host.

const std = @import("std");

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

    // Raw PNG scanline stream: one filter byte (0 = None — flat fields
    // gain nothing from prediction) then the row's pixels.
    const raw = try gpa.alloc(u8, size * (size + 1));
    defer gpa.free(raw);
    var i: usize = 0;
    for (0..size) |y| {
        raw[i] = 0; // filter: None
        i += 1;
        const row: ?usize = if (y >= margin and y < margin + grid * cell) (y - margin) / cell else null;
        for (0..size) |x| {
            const col: ?usize = if (x >= margin and x < margin + grid * cell) (x - margin) / cell else null;
            raw[i] = if (row != null and col != null) cells[row.?][col.?] else paper;
            i += 1;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], size, .big);
    std.mem.writeInt(u32, ihdr[4..8], size, .big);
    // bit depth 8, color type 0 (grayscale), compression 0, filter 0,
    // interlace 0.
    ihdr[8..13].* = .{ 8, 0, 0, 0, 0 };
    try writeChunk(gpa, &out, "IHDR", &ihdr);

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    try zlibDeflate(gpa, &idat, raw);
    try writeChunk(gpa, &out, "IDAT", idat.items);

    try writeChunk(gpa, &out, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

fn writeChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) error{OutOfMemory}!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}

/// zlib stream around one fixed-Huffman deflate block. The encoder
/// knows exactly two shapes — literal bytes and distance-1 matches
/// (i.e. "repeat the previous byte") — which is the whole grammar of a
/// flat-field image and keeps every emitted bit specified by this file
/// alone.
fn zlibDeflate(gpa: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8) error{OutOfMemory}!void {
    // CMF 0x78 (deflate, 32K window), FLG 0x01 (no dict; check bits
    // making CMF·256+FLG ≡ 0 mod 31).
    try out.appendSlice(gpa, &.{ 0x78, 0x01 });

    var bw: BitWriter = .{ .gpa = gpa, .out = out };
    try bw.bits(1, 1); // BFINAL: single block
    try bw.bits(1, 2); // BTYPE 01: fixed Huffman
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        var run: usize = 1;
        while (i + run < data.len and data[i + run] == b) run += 1;
        try bw.literal(b);
        var rest = run - 1;
        while (rest >= 3) {
            const take: usize = @min(258, rest);
            try bw.match(@intCast(take));
            rest -= take;
        }
        for (0..rest) |_| try bw.literal(b);
        i += run;
    }
    // End-of-block: symbol 256, fixed code 0000000.
    try bw.huff(0, 7);
    try bw.flushByte();

    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(data), .big);
    try out.appendSlice(gpa, &adler);
}

/// Deflate's two bit orders in one place: fields fill bytes LSB-first,
/// but Huffman codes are emitted MSB-of-code-first — `huff` reverses so
/// callers pass codes as RFC 1951 prints them.
const BitWriter = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    buf: u32 = 0,
    n: u6 = 0,

    fn bits(self: *BitWriter, value: u32, count: u6) error{OutOfMemory}!void {
        self.buf |= value << @intCast(self.n);
        self.n += count;
        while (self.n >= 8) {
            try self.out.append(self.gpa, @truncate(self.buf));
            self.buf >>= 8;
            self.n -= 8;
        }
    }

    fn huff(self: *BitWriter, code: u32, count: u6) error{OutOfMemory}!void {
        var reversed: u32 = 0;
        for (0..count) |k| {
            if (code & (@as(u32, 1) << @intCast(k)) != 0)
                reversed |= @as(u32, 1) << @intCast(count - 1 - k);
        }
        try self.bits(reversed, count);
    }

    fn flushByte(self: *BitWriter) error{OutOfMemory}!void {
        if (self.n > 0) try self.bits(0, 8 - self.n);
    }

    fn literal(self: *BitWriter, byte: u8) error{OutOfMemory}!void {
        // Fixed table: 0–143 are 8-bit codes from 00110000,
        // 144–255 are 9-bit codes from 110010000.
        if (byte < 144)
            try self.huff(0x30 + @as(u32, byte), 8)
        else
            try self.huff(0x190 + @as(u32, byte) - 144, 9);
    }

    /// A length-`len` copy at distance 1. Length symbols 257–284 carry
    /// base+extra per RFC 1951; 285 (=258, our common case: a long run)
    /// carries none.
    fn match(self: *BitWriter, len: u9) error{OutOfMemory}!void {
        std.debug.assert(len >= 3 and len <= 258);
        const bases = [_]u9{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
        var sym: usize = bases.len - 1;
        while (bases[sym] > len) sym -= 1;
        const extra_bits: u6 = if (sym < 8 or sym == 28) 0 else @intCast((sym - 4) / 4);
        const symbol = 257 + sym;
        // Fixed table: 256–279 are 7-bit codes from 0, 280–287 are
        // 8-bit codes from 11000000.
        if (symbol < 280)
            try self.huff(@intCast(symbol - 256), 7)
        else
            try self.huff(0xC0 + @as(u32, @intCast(symbol - 280)), 8);
        if (extra_bits > 0) try self.bits(len - bases[sym], extra_bits);
        // Distance 1: symbol 0, five zero bits, no extra.
        try self.huff(0, 5);
    }
};

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
