//! Golden screenshot testing over PPM (P6) files: a trivially diffable
//! raw-RGB format with no dependencies. Because nokre rendering is
//! deterministic, goldens compare byte-for-byte — no tolerance knobs.
//!
//! PPM and not PGM since the frame widened to RGB for the vendor
//! sign-in mark (docs/internals/pixel-model.md): the surface hands back
//! RGBX (4 bytes per pixel, the fourth padding), and the file keeps the
//! three that matter. Everything outside the mark still writes r=g=b,
//! so a golden's diff stays as readable as the gray ones were.
//!
//! Baseline maintenance is explicit (`Options.update`): a missing
//! golden is a failure, not a first run — otherwise a baseline lost in
//! CI would silently re-mint itself and turn the byte-exactness gate
//! into a pass. A mismatch writes `<path>.actual.ppm` next to the
//! golden for diffing.

const std = @import("std");
const Io = std.Io;
const diag = @import("diag.zig");

pub const max_file_size = 64 * 1024 * 1024;

pub const Options = struct {
    /// When set (build.zig threads `-Dupdate-goldens` into the golden
    /// test module, which passes it here), a missing golden is created
    /// and a mismatched one is rewritten in place — intentional visual
    /// changes are one command, not delete-then-rerun. Unset, the only
    /// mode CI runs, both are failures: a baseline can only ever be
    /// minted or healed by someone who asked for it and will review the
    /// diff.
    ///
    /// An argument rather than module state: the flag rides the
    /// assertion it governs, so two suites in one process cannot fight
    /// over a global, and nothing an app or a service does can reach it.
    update: bool = false,
};

/// `pixels` is RGBX as `Surface.pixels` returns it — 4 bytes per pixel,
/// the padding byte dropped on the way to disk so the golden is pure
/// RGB and the padding can never make two identical frames differ.
pub fn writePpm(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, sub_path: []const u8) !void {
    std.debug.assert(pixels.len == w * h * 4);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.print(gpa, "P6\n{d} {d}\n255\n", .{ w, h });
    try data.ensureUnusedCapacity(gpa, w * h * 3);
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        data.appendSliceAssumeCapacity(pixels[i .. i + 3]);
    }
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data.items });
}

pub const Ppm = struct {
    w: usize,
    h: usize,
    /// Packed RGB, 3 bytes per pixel — the file's own layout.
    pixels: []const u8,
    raw: []const u8,

    pub fn deinit(self: Ppm, gpa: std.mem.Allocator) void {
        gpa.free(self.raw);
    }
};

pub fn readPpm(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, sub_path: []const u8) !Ppm {
    const raw = try dir.readFileAlloc(io, sub_path, gpa, .limited(max_file_size));
    errdefer gpa.free(raw);

    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    if (!std.mem.eql(u8, it.next() orelse return error.BadPpm, "P6")) return error.BadPpm;
    const w = try std.fmt.parseInt(usize, it.next() orelse return error.BadPpm, 10);
    const h = try std.fmt.parseInt(usize, it.next() orelse return error.BadPpm, 10);
    const maxval = try std.fmt.parseInt(usize, it.next() orelse return error.BadPpm, 10);
    if (maxval != 255) return error.BadPpm;

    const header_end = it.index + 1; // single whitespace byte after maxval
    if (header_end > raw.len) return error.BadPpm;
    const size = std.math.mul(usize, std.math.mul(usize, w, h) catch return error.BadPpm, 3) catch return error.BadPpm;
    if (raw.len - header_end != size) return error.BadPpm;
    return .{ .w = w, .h = h, .pixels = raw[header_end..], .raw = raw };
}

/// RGBX frame vs packed-RGB golden, ignoring the padding byte — the one
/// byte of the frame the pixel model does not speak for.
fn frameMatches(golden: Ppm, pixels: []const u8, w: usize, h: usize) bool {
    if (golden.w != w or golden.h != h) return false;
    var px: usize = 0;
    var gp: usize = 0;
    while (px < pixels.len) : ({
        px += 4;
        gp += 3;
    }) {
        if (!std.mem.eql(u8, pixels[px .. px + 3], golden.pixels[gp .. gp + 3])) return false;
    }
    return true;
}

/// Byte-exact comparison against the golden at `sub_path` (relative to
/// `dir`); `pixels` is RGBX as the surface hands it back. A missing
/// golden fails unless `opts.update` is set (then it is created); a
/// mismatch writes `<path>.actual.ppm` and fails unless `opts.update`
/// is set (then the golden is rewritten in place).
pub fn expectMatchesIn(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, sub_path: []const u8, opts: Options) !void {
    const golden = readPpm(io, dir, gpa, sub_path) catch |err| switch (err) {
        error.FileNotFound => {
            if (!opts.update) {
                diag.print("golden: {s} is missing — baselines are never created implicitly; rerun with -Dupdate-goldens to create it, then review and commit\n", .{sub_path});
                return error.GoldenMissing;
            }
            try writePpm(io, dir, gpa, pixels, w, h, sub_path);
            diag.print("golden: created {s} — review and commit it\n", .{sub_path});
            return;
        },
        else => return err,
    };
    defer golden.deinit(gpa);

    if (frameMatches(golden, pixels, w, h)) return;

    if (opts.update) {
        try writePpm(io, dir, gpa, pixels, w, h, sub_path);
        diag.print("golden: rewrote {s} — review the diff and commit it\n", .{sub_path});
        return;
    }
    const actual_path = try std.fmt.allocPrint(gpa, "{s}.actual.ppm", .{sub_path});
    defer gpa.free(actual_path);
    try writePpm(io, dir, gpa, pixels, w, h, actual_path);
    diag.print("golden: mismatch against {s}; wrote {s} — if the change is intentional, rerun with -Dupdate-goldens\n", .{ sub_path, actual_path });
    return error.GoldenMismatch;
}

/// Convenience for tests: golden path relative to the current working
/// directory, io from the test runner.
pub fn expectMatches(gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, sub_path: []const u8, opts: Options) !void {
    try expectMatchesIn(std.testing.io, Io.Dir.cwd(), gpa, pixels, w, h, sub_path, opts);
}

// ---- tests ----

const testing = std.testing;

test "ppm round-trips, dropping the padding byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two pixels: one gray (r=g=b, the frame's normal state), one
    // colored (the mark's). Padding bytes differ on purpose — they must
    // not survive into the file.
    const pixels = [_]u8{ 64, 64, 64, 0xFF, 0x42, 0x85, 0xF4, 0x00 };
    try writePpm(testing.io, tmp.dir, testing.allocator, &pixels, 2, 1, "x.ppm");
    const back = try readPpm(testing.io, tmp.dir, testing.allocator, "x.ppm");
    defer back.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), back.w);
    try testing.expectEqual(@as(usize, 1), back.h);
    try testing.expectEqualSlices(u8, &[_]u8{ 64, 64, 64, 0x42, 0x85, 0xF4 }, back.pixels);
}

test "readPpm rejects truncated and overflowing headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Ends right at the maxval token — not even the header's own
    // terminating whitespace byte, let alone pixels.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.ppm", .data = "P6\n3 2\n255" });
    try testing.expectError(
        error.BadPpm,
        readPpm(testing.io, tmp.dir, testing.allocator, "t.ppm"),
    );

    // Dimensions that each fit usize but whose product does not.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "o.ppm",
        .data = "P6\n9223372036854775807 9223372036854775807\n255\n",
    });
    try testing.expectError(
        error.BadPpm,
        readPpm(testing.io, tmp.dir, testing.allocator, "o.ppm"),
    );
}

test "expectMatches creates only under update, then verifies and detects change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    diag.quiet = true;
    defer diag.quiet = false;

    const a = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 0 };
    // The CI shape: missing without `.update` fails and writes nothing —
    // a lost baseline must never re-mint itself into a pass.
    try testing.expectError(
        error.GoldenMissing,
        expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 1, "goldens/g.ppm", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        readPpm(testing.io, tmp.dir, testing.allocator, "goldens/g.ppm"),
    );

    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 1, "goldens/g.ppm", .{ .update = true }); // creates
    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 1, "goldens/g.ppm", .{}); // matches

    // The same frame under different padding bytes still matches: the
    // padding is not part of the pixel model's promise.
    const a_padded = [_]u8{ 1, 2, 3, 0xAB, 4, 5, 6, 0xCD };
    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a_padded, 2, 1, "goldens/g.ppm", .{});

    const b = [_]u8{ 1, 2, 3, 0, 4, 5, 7, 0 };
    try testing.expectError(
        error.GoldenMismatch,
        expectMatchesIn(testing.io, tmp.dir, testing.allocator, &b, 2, 1, "goldens/g.ppm", .{}),
    );
}

test "update rewrites a mismatched golden in place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    diag.quiet = true;
    defer diag.quiet = false;

    const a = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 0 };
    const b = [_]u8{ 1, 2, 3, 0, 4, 5, 7, 0 };
    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 1, "goldens/g.ppm", .{ .update = true }); // creates
    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &b, 2, 1, "goldens/g.ppm", .{ .update = true }); // rewrites
    // The rewrite is the new baseline; the old pixels now mismatch.
    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &b, 2, 1, "goldens/g.ppm", .{});
    try testing.expectError(
        error.GoldenMismatch,
        expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 1, "goldens/g.ppm", .{}),
    );
}
