//! png — the repository's one PNG encoder: signature, chunks, CRCs, and
//! a fixed-Huffman deflate that knows only literals and distance-1 runs.
//!
//! It is written here rather than reached for because the two callers
//! want opposite things from an encoder and the same thing from its
//! bytes. `packaging/icon.zig` golden-tests the icon it emits, so an
//! external encoder (or `std.compress`, whose output may change between
//! releases) would put a committed baseline at the mercy of someone
//! else's release notes. `testing` writes frames a person or an agent
//! opens, so the bytes must be a *real* PNG on the first try, in a
//! process with no window and no display server. One encoder answers
//! both, and answering both is why it moved out of `icon.zig`.
//!
//! **Why distance-1 runs are enough for a frame too.** The refusal that
//! keeps this small in an identicon keeps it small in a screenshot: every
//! canvas op but one writes r=g=b (`docs/internals/pixel-model.md`), so a
//! flat region of a nokre frame is a run of *identical bytes* across the
//! RGB triples, not merely across pixels — exactly the grammar this
//! deflate speaks. The one colored mark costs a few hundred literals.
//!
//! Filter 0 (None) on every scanline. Prediction buys nothing on flat
//! fields, and it would cost this file the property it exists for: every
//! emitted bit is specified here. Each row's filter byte does interrupt
//! the run across the seam — that is the price of refusing distances
//! beyond 1, and it is one literal per scanline.
//!
//! Integer math only, the core rule: these bytes are golden-tested and
//! must not depend on the host.

const std = @import("std");

/// The two PNG color types this encoder writes, by their IHDR ordinals.
/// There is no alpha in either: an icon must be opaque on iOS, and a
/// nokre frame has no transparency to carry — the surface hands back
/// RGBX whose fourth byte is padding nobody reads.
pub const Color = enum(u8) {
    gray8 = 0,
    rgb8 = 2,

    fn samplesPerPixel(self: Color) usize {
        return switch (self) {
            .gray8 => 1,
            .rgb8 => 3,
        };
    }
};

/// `samples` is one byte per pixel, row-major, `w * h` long.
pub fn gray8(gpa: std.mem.Allocator, samples: []const u8, w: usize, h: usize) error{OutOfMemory}![]u8 {
    std.debug.assert(samples.len == w * h);
    const raw = try scanlines(gpa, w, h, .gray8);
    defer gpa.free(raw);
    var i: usize = 0;
    for (0..h) |y| {
        i += 1; // the row's filter byte, already zero
        @memcpy(raw[i..][0..w], samples[y * w ..][0..w]);
        i += w;
    }
    return encode(gpa, raw, w, h, .gray8);
}

/// `pixels` is RGBX as `render.skia.Surface.pixels` hands it back — four
/// bytes per pixel, the fourth padding. The padding is dropped on the way
/// in, exactly as `golden.writePpm` drops it, so two frames that differ
/// only in bytes the pixel model does not speak for encode identically.
pub fn rgbx(gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize) error{OutOfMemory}![]u8 {
    std.debug.assert(pixels.len == w * h * 4);
    const raw = try scanlines(gpa, w, h, .rgb8);
    defer gpa.free(raw);
    var src: usize = 0;
    var dst: usize = 0;
    for (0..h) |_| {
        dst += 1; // the row's filter byte, already zero
        for (0..w) |_| {
            @memcpy(raw[dst..][0..3], pixels[src..][0..3]);
            dst += 3;
            src += 4;
        }
    }
    return encode(gpa, raw, w, h, .rgb8);
}

/// The raw scanline stream, zeroed: one filter byte per row (0 = None)
/// followed by that row's samples. Callers fill the samples and leave the
/// filter bytes alone.
fn scanlines(gpa: std.mem.Allocator, w: usize, h: usize, color: Color) error{OutOfMemory}![]u8 {
    const raw = try gpa.alloc(u8, h * (1 + w * color.samplesPerPixel()));
    @memset(raw, 0);
    return raw;
}

fn encode(gpa: std.mem.Allocator, raw: []const u8, w: usize, h: usize, color: Color) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
    // bit depth 8, the color type, compression 0, filter 0, interlace 0.
    ihdr[8..13].* = .{ 8, @intFromEnum(color), 0, 0, 0 };
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
    // A literal costs at most nine bits, so the stream can exceed its
    // input by an eighth. Reserving that up front keeps a megapixel
    // frame from re-growing the list a hundred times; it never changes
    // a byte.
    try out.ensureUnusedCapacity(gpa, data.len + data.len / 8 + 16);

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

// ---- tests ----

const testing = std.testing;

/// Walks the container the way a decoder does: signature, then every
/// chunk's length/tag/CRC, ending at IEND with no trailing bytes.
fn expectWellFormed(bytes: []const u8, w: u32, h: u32, color: Color) !void {
    try testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }, bytes[0..8]);
    try testing.expectEqual(w, std.mem.readInt(u32, bytes[16..20], .big));
    try testing.expectEqual(h, std.mem.readInt(u32, bytes[20..24], .big));
    try testing.expectEqual(@as(u8, 8), bytes[24]); // bit depth
    try testing.expectEqual(@intFromEnum(color), bytes[25]);
    var i: usize = 8;
    var saw_iend = false;
    while (i < bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const crc = std.hash.Crc32.hash(bytes[i + 4 ..][0 .. 4 + len]);
        try testing.expectEqual(crc, std.mem.readInt(u32, bytes[i + 8 + len ..][0..4], .big));
        saw_iend = std.mem.eql(u8, bytes[i + 4 ..][0..4], "IEND");
        i += 12 + len;
    }
    try testing.expect(saw_iend);
    try testing.expectEqual(bytes.len, i);
}

/// The IDAT, inflated by a decoder that is not this file — the only
/// check that proves the bit-level emission and not merely the frame
/// around it.
fn inflateIdat(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var i: usize = 8;
    while (i < bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        if (std.mem.eql(u8, bytes[i + 4 ..][0..4], "IDAT")) {
            const zlib = bytes[i + 8 ..][0..len];
            var reader: std.Io.Reader = .fixed(zlib);
            var out: std.Io.Writer.Allocating = .init(gpa);
            errdefer out.deinit();
            const buf = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(buf);
            var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, buf);
            _ = try decompress.reader.streamRemaining(&out.writer);
            return out.toOwnedSlice();
        }
        i += 12 + len;
    }
    return error.NoIdat;
}

test "gray8 writes a decodable image whose scanlines round-trip" {
    const samples = [_]u8{ 0, 0, 0, 0xFF, 0x6A, 0x6A };
    const bytes = try gray8(testing.allocator, &samples, 3, 2);
    defer testing.allocator.free(bytes);
    try expectWellFormed(bytes, 3, 2, .gray8);

    const raw = try inflateIdat(testing.allocator, bytes);
    defer testing.allocator.free(raw);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0xFF, 0x6A, 0x6A }, raw);
}

test "rgbx drops the padding byte and keeps the colored mark" {
    // One gray pixel (the frame's normal state) and one colored (the
    // vendor mark's), with padding bytes that differ on purpose.
    const pixels = [_]u8{ 64, 64, 64, 0xFF, 0x42, 0x85, 0xF4, 0x00 };
    const bytes = try rgbx(testing.allocator, &pixels, 2, 1);
    defer testing.allocator.free(bytes);
    try expectWellFormed(bytes, 2, 1, .rgb8);

    const raw = try inflateIdat(testing.allocator, bytes);
    defer testing.allocator.free(raw);
    try testing.expectEqualSlices(u8, &.{ 0, 64, 64, 64, 0x42, 0x85, 0xF4 }, raw);
}

test "a flat field costs runs, not literals" {
    // A megapixel of paper is the shape a nokre frame mostly is; if the
    // distance-1 grammar ever stopped applying to RGB triples this is
    // where it would show, as a file two orders of magnitude larger.
    const w = 512;
    const h = 512;
    const pixels = try testing.allocator.alloc(u8, w * h * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0xFF);
    const bytes = try rgbx(testing.allocator, pixels, w, h);
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len < 16 * 1024);
}
