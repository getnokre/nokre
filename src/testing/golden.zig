//! Golden screenshot testing over PGM (P5) files: a trivially diffable
//! grayscale format with no dependencies. Because nokre rendering is
//! deterministic, goldens compare byte-for-byte — no tolerance knobs.
//!
//! Baseline maintenance is explicit (`update` below): a missing golden
//! is a failure, not a first run — otherwise a baseline lost in CI
//! would silently re-mint itself and turn the byte-exactness gate into
//! a pass. A mismatch writes `<path>.actual.pgm` next to the golden
//! for diffing.

const std = @import("std");
const Io = std.Io;
const diag = @import("diag.zig");

pub const max_file_size = 64 * 1024 * 1024;

/// When set (build.zig threads `-Dupdate-goldens` into the golden test
/// module, which assigns it), a missing golden is created and a
/// mismatched one is rewritten in place — intentional visual changes
/// are one command, not delete-then-rerun. Off, the only mode CI runs,
/// both are failures: a baseline can only ever be minted or healed by
/// someone who asked for it and will review the diff.
///
/// Deliberately module state, on the same exemption as `diag.quiet`:
/// this configures the test process, not app behavior — nothing an app
/// or a service does reads it.
pub var update = false;

pub fn writePgm(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, sub_path: []const u8) !void {
    std.debug.assert(pixels.len == w * h);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.print(gpa, "P5\n{d} {d}\n255\n", .{ w, h });
    try data.appendSlice(gpa, pixels);
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data.items });
}

pub const Pgm = struct {
    w: usize,
    h: usize,
    pixels: []const u8,
    raw: []const u8,

    pub fn deinit(self: Pgm, gpa: std.mem.Allocator) void {
        gpa.free(self.raw);
    }
};

pub fn readPgm(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, sub_path: []const u8) !Pgm {
    const raw = try dir.readFileAlloc(io, sub_path, gpa, .limited(max_file_size));
    errdefer gpa.free(raw);

    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    if (!std.mem.eql(u8, it.next() orelse return error.BadPgm, "P5")) return error.BadPgm;
    const w = try std.fmt.parseInt(usize, it.next() orelse return error.BadPgm, 10);
    const h = try std.fmt.parseInt(usize, it.next() orelse return error.BadPgm, 10);
    const maxval = try std.fmt.parseInt(usize, it.next() orelse return error.BadPgm, 10);
    if (maxval != 255) return error.BadPgm;

    const header_end = it.index + 1; // single whitespace byte after maxval
    if (header_end > raw.len) return error.BadPgm;
    const size = std.math.mul(usize, w, h) catch return error.BadPgm;
    if (raw.len - header_end != size) return error.BadPgm;
    return .{ .w = w, .h = h, .pixels = raw[header_end..], .raw = raw };
}

/// Byte-exact comparison against the golden at `sub_path` (relative to
/// `dir`). A missing golden fails unless `update` is set (then it is
/// created); a mismatch writes `<path>.actual.pgm` and fails unless
/// `update` is set (then the golden is rewritten in place).
pub fn expectMatchesIn(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, sub_path: []const u8) !void {
    const golden = readPgm(io, dir, gpa, sub_path) catch |err| switch (err) {
        error.FileNotFound => {
            if (!update) {
                diag.print("golden: {s} is missing — baselines are never created implicitly; rerun with -Dupdate-goldens to create it, then review and commit\n", .{sub_path});
                return error.GoldenMissing;
            }
            try writePgm(io, dir, gpa, pixels, w, h, sub_path);
            diag.print("golden: created {s} — review and commit it\n", .{sub_path});
            return;
        },
        else => return err,
    };
    defer golden.deinit(gpa);

    const matches = golden.w == w and golden.h == h and std.mem.eql(u8, golden.pixels, pixels);
    if (matches) return;

    if (update) {
        try writePgm(io, dir, gpa, pixels, w, h, sub_path);
        diag.print("golden: rewrote {s} — review the diff and commit it\n", .{sub_path});
        return;
    }
    const actual_path = try std.fmt.allocPrint(gpa, "{s}.actual.pgm", .{sub_path});
    defer gpa.free(actual_path);
    try writePgm(io, dir, gpa, pixels, w, h, actual_path);
    diag.print("golden: mismatch against {s}; wrote {s} — if the change is intentional, rerun with -Dupdate-goldens\n", .{ sub_path, actual_path });
    return error.GoldenMismatch;
}

/// Convenience for tests: golden path relative to the current working
/// directory, io from the test runner.
pub fn expectMatches(gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, sub_path: []const u8) !void {
    try expectMatchesIn(std.testing.io, Io.Dir.cwd(), gpa, pixels, w, h, sub_path);
}

// ---- tests ----

const testing = std.testing;

test "pgm round-trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pixels = [_]u8{ 0, 64, 128, 192, 255, 10 };
    try writePgm(testing.io, tmp.dir, testing.allocator, &pixels, 3, 2, "x.pgm");
    const back = try readPgm(testing.io, tmp.dir, testing.allocator, "x.pgm");
    defer back.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), back.w);
    try testing.expectEqual(@as(usize, 2), back.h);
    try testing.expectEqualSlices(u8, &pixels, back.pixels);
}

test "readPgm rejects truncated and overflowing headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Ends right at the maxval token — not even the header's own
    // terminating whitespace byte, let alone pixels.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.pgm", .data = "P5\n3 2\n255" });
    try testing.expectError(
        error.BadPgm,
        readPgm(testing.io, tmp.dir, testing.allocator, "t.pgm"),
    );

    // Dimensions that each fit usize but whose product does not.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "o.pgm",
        .data = "P5\n9223372036854775807 9223372036854775807\n255\n",
    });
    try testing.expectError(
        error.BadPgm,
        readPgm(testing.io, tmp.dir, testing.allocator, "o.pgm"),
    );
}

test "expectMatches creates only under update, then verifies and detects change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    diag.quiet = true;
    defer diag.quiet = false;

    const a = [_]u8{ 1, 2, 3, 4 };
    // The CI shape: missing without `update` fails and writes nothing —
    // a lost baseline must never re-mint itself into a pass.
    try testing.expectError(
        error.GoldenMissing,
        expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 2, "goldens/g.pgm"),
    );
    try testing.expectError(
        error.FileNotFound,
        readPgm(testing.io, tmp.dir, testing.allocator, "goldens/g.pgm"),
    );

    {
        update = true;
        defer update = false;
        try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 2, "goldens/g.pgm"); // creates
    }
    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 2, "goldens/g.pgm"); // matches

    const b = [_]u8{ 1, 2, 3, 5 };
    try testing.expectError(
        error.GoldenMismatch,
        expectMatchesIn(testing.io, tmp.dir, testing.allocator, &b, 2, 2, "goldens/g.pgm"),
    );
}

test "update rewrites a mismatched golden in place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    diag.quiet = true;
    defer diag.quiet = false;

    const a = [_]u8{ 1, 2, 3, 4 };
    const b = [_]u8{ 1, 2, 3, 5 };
    {
        update = true;
        defer update = false;
        try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 2, "goldens/g.pgm"); // creates
        try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &b, 2, 2, "goldens/g.pgm"); // rewrites
    }
    // The rewrite is the new baseline; the old pixels now mismatch.
    try expectMatchesIn(testing.io, tmp.dir, testing.allocator, &b, 2, 2, "goldens/g.pgm");
    try testing.expectError(
        error.GoldenMismatch,
        expectMatchesIn(testing.io, tmp.dir, testing.allocator, &a, 2, 2, "goldens/g.pgm"),
    );
}
