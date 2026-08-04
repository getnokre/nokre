//! Writes the DOM edition's stylesheet to a file.
//!
//! Build-time only, and the whole of it is `stylesheet.write` — a
//! driver that already links nokre calls that directly. This exists for
//! the ones that do not: a static host, a demo page, a build step in
//! another language.
//!
//!     zig build dom-css                 # zig-out/dom/style.css
//!     ./emit-css out.css [font-dir] [.ext]

const std = @import("std");
const stylesheet = @import("nokre").render.dom.stylesheet;

// A program that links the library owes the hooks a shell owes, and
// `locale` is the one every non-test build names (services/locale/
// locale.h). Naming the shipped shell is the whole install
// (src/testing/shell.zig).
comptime {
    _ = @import("nokre").testing.shell;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next(); // argv0

    const out_path = args.next() orelse return error.MissingOutputPath;
    var options: stylesheet.Options = .{};
    if (args.next()) |dir| options.fonts = dir;
    if (args.next()) |ext| options.font_suffix = ext;

    var css: std.ArrayList(u8) = .empty;
    try stylesheet.write(gpa, &css, options);

    const cwd: std.Io.Dir = .cwd();
    if (std.fs.path.dirname(out_path)) |parent| try cwd.createDirPath(init.io, parent);
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = css.items });
}
