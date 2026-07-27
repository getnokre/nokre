//! QR encoding over Nayuki's qrcodegen (deps/qrcodegen): the reference
//! C implementation, vendored. No heap — caller-supplied buffers only —
//! so it shares nokre's determinism guarantees. The only extern symbols
//! in core; everything else is pure Zig.

const std = @import("std");

pub const Encoded = struct {
    /// Module bits, row-major, packed LSB-first.
    modules: []const u8,
    /// Modules per side (21–177).
    size: i32,
};

/// Encodes `value` at medium error correction, no knobs. Called once at
/// `Tree.append`: a value too long to encode cannot enter the tree, and
/// rendering never touches the C library.
pub fn encode(arena: std.mem.Allocator, value: [:0]const u8) !Encoded {
    var temp: [buffer_len]u8 = undefined;
    var code: [buffer_len]u8 = undefined;
    if (!qrcodegen_encodeText(value, &temp, &code, ecc_medium, 1, 40, mask_auto, true)) {
        return error.QrValueTooLong;
    }
    const size = qrcodegen_getSize(&code);
    const n: usize = @intCast(size * size);
    const bits = try arena.alloc(u8, (n + 7) / 8);
    @memset(bits, 0);
    var i: usize = 0;
    var y: c_int = 0;
    while (y < size) : (y += 1) {
        var x: c_int = 0;
        while (x < size) : (x += 1) {
            if (qrcodegen_getModule(&code, x, y)) bits[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
            i += 1;
        }
    }
    return .{ .modules = bits, .size = size };
}

extern fn qrcodegen_encodeText(text: [*:0]const u8, tempBuffer: [*]u8, qrcode: [*]u8, ecl: c_int, minVersion: c_int, maxVersion: c_int, mask: c_int, boostEcl: bool) bool;
extern fn qrcodegen_getSize(qrcode: [*]const u8) c_int;
extern fn qrcodegen_getModule(qrcode: [*]const u8, x: c_int, y: c_int) bool;

/// qrcodegen_BUFFER_LEN_MAX: worst case (version 40), just under 4KB.
const buffer_len = 3918;
const ecc_medium: c_int = 1;
const mask_auto: c_int = -1;
