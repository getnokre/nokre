//! The inspection path's own gate: a real executable — no window, no
//! display server, no `zig test` — that drives a live `App` through
//! `testing.Device` and writes the two artifacts an agent reads, then
//! decodes one of them with something that is not the encoder.
//!
//! **Why an executable.** The thing under test is the shape a consumer's
//! e2e binary is: `Device` over a real `App`, the headless shell named
//! for its C hooks, a `Pacer` of the driver's own. `zig test` cannot be
//! that program — nokre swaps its http transport under
//! `builtin.is_test`, which is why the driver tier exists at all
//! (docs/testing.md, "Driving an app outside `zig test`") — so a gate
//! that ran there would prove the API compiles and nothing about the
//! program that uses it. It is also the worked example: this file is
//! what a driver copies to get a trace.
//!
//! **What it proves, in order.** That `Device.startTrace` reaches the
//! same observers a `Harness` takes; that `trace.Tee` puts the text tree
//! and the raster on one numbering in one pass, file-for-file; that a
//! frame comes out of `SkSurfaces::Raster` in a process with no window;
//! that the PNG is a *real* PNG — signature, IHDR, per-chunk CRCs, and an
//! IDAT that `std.compress.flate` inflates to the scanlines it claims —
//! at `scale` times the logical viewport, in RGB; and that the tree half
//! says what the raster cannot, which is the half that matters more.
//!
//! The artifacts land in the directory named as the first argument
//! (`zig-out/inspect` when there is none — the convention
//! docs/testing.md states), unconditionally, pass or fail. That is the
//! whole difference from a golden: nothing here is compared against a
//! baseline, because the question is "what is on the screen", and a
//! screen nobody has seen has no baseline to be compared against.

const std = @import("std");
const nok = @import("nokre");

const skia = nok.render.skia;
const trace = nok.testing.trace;
const wait = nok.testing.wait;

// A program that links the library owes the hooks a shell owes — the
// driver *is* the shell's half of the line (docs/testing.md). Naming
// the shipped headless shell is the whole install.
comptime {
    _ = nok.testing.shell;
}

const State = struct {
    app: *nok.App = undefined,
    greeted: bool = false,
};

fn buildHome(state: *State, app: *nok.App) !void {
    state.app = app;
    const root = app.tree.rootId();
    try app.tree.setTitle("Capture");
    try app.tree.append(root, .{ .heading = .{ .content = "Sign in", .level = .h2 } });
    try app.tree.append(root, .{ .text_input = .{ .label = "Email", .value = "" } });
    try app.tree.append(root, .{ .button = .{ .label = "Continue", .on_press = .bind(onContinue, state) } });
    if (state.greeted) {
        try app.tree.append(root, .{ .text = .{ .content = "Welcome back." } });
    }
}

fn onContinue(state: *State) void {
    state.greeted = true;
    state.app.tree.clearChildren(state.app.tree.rootId()) catch return;
    buildHome(state, state.app) catch return;
    state.app.invalidate();
}

/// The driver's own clock and nap, handed to `wait.Pacer` as function
/// pointers: nokre reads no wall clock and sleeps no thread itself, which
/// is what keeps the library deterministic and the timeout path testable.
/// Both are the driver's existing facilities — the app's own clock
/// service and the `Io` the process was started with — rather than a
/// second time source beside them.
const Clock = struct {
    app: *nok.App,
    io: std.Io,

    fn nowMs(ctx: ?*anyopaque) i64 {
        const self: *Clock = @ptrCast(@alignCast(ctx.?));
        return nok.services.clock.now(self.app);
    }

    fn nap(ctx: ?*anyopaque, ns: u64) void {
        const self: *Clock = @ptrCast(@alignCast(ctx.?));
        std.Io.sleep(self.io, .fromNanoseconds(ns), .awake) catch {};
    }
};

/// A PNG read the way a reader reads it, by a decoder this repository
/// did not write: the container walked chunk by chunk with every CRC
/// re-derived, then the IDAT inflated by `std.compress.flate` and
/// measured against the dimensions IHDR declared. "The encoder returned
/// without error" is not the claim being checked here.
fn expectRealPng(gpa: std.mem.Allocator, bytes: []const u8, w: u32, h: u32) !void {
    if (!std.mem.eql(u8, bytes[0..8], &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' })) return error.NotPng;
    if (std.mem.readInt(u32, bytes[16..20], .big) != w) return error.WrongWidth;
    if (std.mem.readInt(u32, bytes[20..24], .big) != h) return error.WrongHeight;
    if (bytes[24] != 8) return error.WrongBitDepth;
    if (bytes[25] != 2) return error.NotRgb; // color type 2: truecolor, no alpha

    var raw: ?[]u8 = null;
    defer if (raw) |r| gpa.free(r);
    var i: usize = 8;
    var saw_iend = false;
    while (i < bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const tag = bytes[i + 4 ..][0..4];
        if (std.hash.Crc32.hash(bytes[i + 4 ..][0 .. 4 + len]) != std.mem.readInt(u32, bytes[i + 8 + len ..][0..4], .big)) {
            return error.BadChunkCrc;
        }
        if (std.mem.eql(u8, tag, "IDAT")) {
            var reader: std.Io.Reader = .fixed(bytes[i + 8 ..][0..len]);
            var out: std.Io.Writer.Allocating = .init(gpa);
            errdefer out.deinit();
            const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(window);
            var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, window);
            _ = try decompress.reader.streamRemaining(&out.writer);
            raw = try out.toOwnedSlice();
        }
        saw_iend = std.mem.eql(u8, tag, "IEND");
        i += 12 + len;
    }
    if (!saw_iend or i != bytes.len) return error.MalformedContainer;

    // One filter byte plus three samples per pixel, per scanline.
    const scanlines = raw orelse return error.NoIdat;
    if (scanlines.len != @as(usize, h) * (1 + @as(usize, w) * 3)) return error.WrongScanlineCount;
    // A frame that decoded to a single value is a surface that was
    // cleared and never drawn on — which the tree half would not catch,
    // because a tree is laid out whether or not anything reaches a
    // canvas.
    var distinct = false;
    for (scanlines[1..]) |b| {
        if (b != scanlines[1]) distinct = true;
    }
    if (!distinct) return error.BlankFrame;
}

fn readAll(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, sub_path, gpa, .limited(64 * 1024 * 1024));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const out_dir = args.next() orelse "zig-out/inspect";

    var state: State = .{};
    // The App lives in storage that outlives every call: a press handler
    // holds a `*App`, so one returned by value strands them.
    var app: nok.App = undefined;
    app = try nok.App.init(gpa, .{ .viewport = .{ .w = 320, .h = 240 }, .ctx = &state });
    defer app.deinit();
    try buildHome(&state, &app);

    var clock: Clock = .{ .app = &app, .io = io };
    var d: nok.testing.Device = .{
        .app = &app,
        .pacer = .{ .ctx = &clock, .now_ms = Clock.nowMs, .nap = Clock.nap, .timeout_ms = 5_000 },
    };

    var trees = try trace.TreeSink.init(io, .cwd(), gpa, out_dir);
    var frames = try skia.PixelSink.init(io, .cwd(), gpa, out_dir);
    // 2× is the knob `Surface.init` always had and nothing reached; a
    // golden pins it at 1 and must, but an inspection frame is compared
    // against nothing, so the resolution costs only bytes.
    frames.take = .{ .scale = 2, .format = .png };
    var tee: trace.Tee = .{ .sinks = &.{ trees.observer(), frames.observer() } };
    try d.startTrace(tee.observer());

    try d.typeInto("Email", "ada@example.com");
    try d.press(.button, "Continue");
    try d.expectPresent(.text, "Welcome back.");
    try d.step("the screen the run ended on");

    // Both instruments, same numbering, same directory — the pairing
    // this file exists to hold.
    const names = [_][]const u8{
        "0000-init",
        "0001-type-into-Email",
        "0002-press-Continue",
        "0003-the-screen-the-run-ended-on",
    };
    for (names) |name| {
        const tree_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ out_dir, name });
        defer gpa.free(tree_path);
        const tree_bytes = try readAll(io, .cwd(), gpa, tree_path);
        defer gpa.free(tree_bytes);
        // The primary instrument: a raster says something looks wrong,
        // the tree says what — that a screen mounted, that a subtree is
        // not empty, that a node has a size.
        if (std.mem.indexOf(u8, tree_bytes, "viewport 320x240") == null) return error.NoViewportLine;
        if (std.mem.indexOf(u8, tree_bytes, "heading [") == null) return error.NoHeading;

        const png_path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ out_dir, name });
        defer gpa.free(png_path);
        const png_bytes = try readAll(io, .cwd(), gpa, png_path);
        defer gpa.free(png_bytes);
        try expectRealPng(gpa, png_bytes, 640, 480);
    }

    // The tree is the instrument that answers *what*: the last step must
    // carry the element the press produced, at a real rect.
    const last = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ out_dir, names[names.len - 1] });
    defer gpa.free(last);
    const last_tree = try readAll(io, .cwd(), gpa, last);
    defer gpa.free(last_tree);
    if (std.mem.indexOf(u8, last_tree, "\"Welcome back.\"") == null) return error.TreeMissedTheChange;
    if (std.mem.indexOf(u8, last_tree, "text_input [") == null) return error.TreeMissedTheField;

    // The one-shot under the sink: the same engine, addressed directly,
    // which is what a store-screenshot preset loops over.
    const shot = try std.fmt.allocPrint(gpa, "{s}/one-shot.png", .{out_dir});
    defer gpa.free(shot);
    try skia.capture(io, .cwd(), gpa, &app, shot, .{ .scale = 1 });
    const shot_bytes = try readAll(io, .cwd(), gpa, shot);
    defer gpa.free(shot_bytes);
    try expectRealPng(gpa, shot_bytes, 320, 240);

    // stderr, and a substring the build step matches: asserting the last
    // line asserts every step before it ran.
    std.debug.print("capture: 4 steps, tree and 2x RGB PNG paired, one-shot ok — in {s}\n", .{out_dir});
}
