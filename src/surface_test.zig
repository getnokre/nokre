//! The gate on `revision`: the recorded surface, or a reason it moved.

const std = @import("std");
const surface = @import("surface.zig");

const recorded = @embedFile("public_surface.txt");
const path = "src/public_surface.txt";
const actual_path = path ++ ".actual";

test "the public surface is the one on record, and the record says which revision it is" {
    const gpa = std.testing.allocator;
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(gpa);
    try surface.write(gpa, &live);

    if (std.mem.eql(u8, live.items, recorded)) return;

    // The surface moved. Whether that is allowed to be recorded depends
    // on one line of it, and the line is `nokre.revision`'s value.
    const was = revisionIn(recorded);
    const now = revisionIn(live.items);
    const diff = try firstDifference(gpa, recorded, live.items);
    defer gpa.free(diff);
    if (std.mem.eql(u8, was, now)) {
        std.debug.print(
            \\
            \\nokre's public surface moved and `revision` is still {s}.
            \\
            \\  {s}
            \\
            \\Four pins in three repositories assert that constant, and a surface that
            \\moves under a standing number is exactly what they cannot catch — it has
            \\happened once (revision 53 shipped `dom.Csp` and two `csp` fields under
            \\52's number). So the record is not written while the number stands still:
            \\bump `revision` in src/nokre.zig, re-run, and this will write the new
            \\surface out for you to review.
            \\
            \\If the change is genuinely invisible to a consumer — a `pub` helper that
            \\is only pub for a sibling module — bump anyway. An adoption that finds
            \\nothing costs a pin; a contract change nobody announced costs a debugging
            \\session in someone else's repository.
            \\
        , .{ was, diff });
        return error.SurfaceMovedWithoutRevision;
    }

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = actual_path, .data = live.items });
    std.debug.print(
        \\
        \\nokre's public surface is at revision {s}; the record is at {s}. Wrote {s}.
        \\
        \\  {s}
        \\
        \\Review that diff — it is the contract change, stated — then record it:
        \\    mv {s} {s}
        \\
    , .{ now, was, actual_path, diff, actual_path, path });
    return error.SurfaceNotRecorded;
}

fn revisionIn(doc: []const u8) []const u8 {
    const mark = "nokre.revision : u32 = ";
    const at = std.mem.indexOf(u8, doc, mark) orelse return "";
    const from = at + mark.len;
    const end = std.mem.indexOfScalarPos(u8, doc, from, '\n') orelse doc.len;
    return doc[from..end];
}

/// The first line that differs, either way round — what a reader needs
/// before opening a 7,000-line diff.
fn firstDifference(gpa: std.mem.Allocator, was: []const u8, now: []const u8) ![]u8 {
    var a = std.mem.splitScalar(u8, was, '\n');
    var b = std.mem.splitScalar(u8, now, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return gpa.dupe(u8, "the two agree line by line but not byte for byte");
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?)) continue;
        return std.fmt.allocPrint(gpa, "line {d}: recorded {?s} — live {?s}", .{ line, x, y });
    }
}
