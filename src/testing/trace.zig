//! Step tracing: an optional per-step observer on the harness. Off by
//! default and free when off. `TreeSink` writes a text snapshot of the
//! laid-out tree per step — pure Zig, no Skia. The pixel sink lives with
//! the Skia bindings (`render.skia.PixelSink`) and pairs with this one
//! file-for-file: `0007-tap-Show-done.txt` next to `0007-tap-Show-done.ppm`.

const std = @import("std");
const Io = std.Io;
const app_mod = @import("../core/app.zig");
const tree_mod = @import("../core/tree.zig");
const test_app = @import("../core/test_app.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

pub const StepObserver = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, step: u32, action: []const u8, app: *App) anyerror!void,
};

/// `NNNN-action.ext`, action sanitized to filename-safe characters and
/// truncated to fit `buf`.
pub fn stepFileName(buf: *[64]u8, step: u32, action: []const u8, ext: []const u8) []const u8 {
    var n = (std.fmt.bufPrint(buf, "{d:0>4}-", .{step}) catch unreachable).len;
    const room = buf.len - n - ext.len - 1;
    for (action[0..@min(action.len, room)]) |c| {
        buf[n] = if (std.ascii.isAlphanumeric(c)) c else '-';
        n += 1;
    }
    n += (std.fmt.bufPrint(buf[n..], ".{s}", .{ext}) catch unreachable).len;
    return buf[0..n];
}

/// Serializes the laid-out tree: one node per line, indented by depth —
/// role, rect, label/content, element state, focus marker. Deterministic
/// and diffable, the text twin of a golden frame.
pub fn dump(gpa: std.mem.Allocator, out: *std.ArrayList(u8), app: *App) !void {
    app.performLayout();
    try out.print(gpa, "viewport {d}x{d} {s}\n", .{ app.viewport.w, app.viewport.h, @tagName(app.appearance()) });
    try dumpNode(gpa, out, app, app.tree.rootId(), 0);
}

fn dumpNode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), app: *App, id: NodeId, depth: usize) !void {
    const el = app.tree.getConst(id) orelse return;
    const r = app.tree.rectOf(id);
    try out.appendNTimes(gpa, ' ', depth * 2);
    try out.print(gpa, "{s} [{d},{d},{d},{d}]", .{ @tagName(el.role()), r.x, r.y, r.w, r.h });

    switch (el.*) {
        .text => |t| try appendQuoted(gpa, out, t.content),
        .badge => |b| try appendQuoted(gpa, out, b.label),
        .meter => |m| {
            try appendQuoted(gpa, out, m.label);
            try out.print(gpa, " value={d} max={d}", .{ m.value, m.max });
        },
        .qr => |q| {
            try appendQuoted(gpa, out, q.label);
            try out.appendSlice(gpa, " value=");
            try appendQuoted(gpa, out, q.value);
            try out.print(gpa, " size={d}", .{q.size});
        },
        .heading => |h| {
            try appendQuoted(gpa, out, h.content);
            try out.print(gpa, " level={d}", .{@intFromEnum(h.level)});
        },
        .button => |b| {
            try appendQuoted(gpa, out, b.label);
            // The row folded it away and a `more` stands where it was
            // (overflow.zig): the trace says so, and the zero rect
            // beside it says the rest.
            if (b.folded) try out.appendSlice(gpa, " folded");
            if (b.secondary) try out.appendSlice(gpa, " secondary");
            if (b.disabled) try out.appendSlice(gpa, " disabled");
            if (b.in_progress) try out.appendSlice(gpa, " in_progress");
            if (b.progress_percent) |pct| try out.print(gpa, " {d}%", .{pct});
        },
        .link => |l| {
            try appendQuoted(gpa, out, l.label);
            if (l.folded) try out.appendSlice(gpa, " folded");
            try out.appendSlice(gpa, " route=");
            try appendQuoted(gpa, out, l.route);
        },
        .toggle => |t| {
            try appendQuoted(gpa, out, t.label);
            if (t.on) try out.appendSlice(gpa, " on");
            if (t.in_progress) try out.appendSlice(gpa, " in_progress");
        },
        .checkbox => |c| {
            try appendQuoted(gpa, out, c.label);
            if (c.checked) try out.appendSlice(gpa, " checked");
            if (c.in_progress) try out.appendSlice(gpa, " in_progress");
        },
        .tile_group => |tg| {
            if (tg.description.len > 0) {
                try out.appendSlice(gpa, " description=");
                try appendQuoted(gpa, out, tg.description);
            }
        },
        .tile => |t| {
            try appendQuoted(gpa, out, t.label);
            if (t.detail.len > 0) {
                try out.appendSlice(gpa, " detail=");
                try appendQuoted(gpa, out, t.detail);
            }
            if (t.route.len > 0) {
                try out.appendSlice(gpa, " route=");
                try appendQuoted(gpa, out, t.route);
            }
        },
        .text_input => |inp| {
            try appendQuoted(gpa, out, inp.label);
            if (inp.obscured) {
                // Never write a password into a committed trace; the
                // codepoint count still pins the rendered bullet run.
                var n: usize = 0;
                for (inp.value) |b| n += @intFromBool(b & 0xC0 != 0x80);
                try out.print(gpa, " obscured codepoints={d}", .{n});
            } else {
                try out.appendSlice(gpa, " value=");
                try appendQuoted(gpa, out, inp.value);
            }
            try out.print(gpa, " cursor={d}", .{inp.cursor});
            if (!inp.obscured and inp.composition.len > 0) {
                try out.appendSlice(gpa, " composition=");
                try appendQuoted(gpa, out, inp.composition);
            }
        },
        .text_area => |area| {
            try appendQuoted(gpa, out, area.label);
            try out.appendSlice(gpa, " value=");
            try appendQuoted(gpa, out, area.value);
            try out.print(gpa, " cursor={d}", .{area.cursor});
            if (area.composition.len > 0) {
                try out.appendSlice(gpa, " composition=");
                try appendQuoted(gpa, out, area.composition);
            }
        },
        .segmented => |s| {
            try appendQuoted(gpa, out, s.label);
            try out.print(gpa, " selected={d}", .{s.selected});
            if (s.selected < s.options.len) try appendQuoted(gpa, out, s.options[s.selected]);
        },
        .radio_group => |rg| {
            try appendQuoted(gpa, out, rg.label);
            try out.print(gpa, " selected={d}", .{rg.selected});
            if (rg.selected < rg.options.len) try appendQuoted(gpa, out, rg.options[rg.selected]);
        },
        .select => |s| {
            try appendQuoted(gpa, out, s.label);
            try out.print(gpa, " selected={d}", .{s.selected});
            if (s.selected < s.options.len) try appendQuoted(gpa, out, s.options[s.selected]);
        },
        .copyable => |c| {
            try appendQuoted(gpa, out, c.label);
            try out.appendSlice(gpa, " value=");
            try appendQuoted(gpa, out, c.value);
        },
        .picker => |p| try appendQuoted(gpa, out, p.title),
        .picker_item => |p| {
            try appendQuoted(gpa, out, p.label);
            if (p.selected) try out.appendSlice(gpa, " selected");
        },
        .scroll_region => |sr| try out.print(gpa, " offset={d} content_h={d}", .{ sr.offset, sr.content_height }),
        .code_block => |cb| {
            try appendQuoted(gpa, out, cb.content);
            try out.print(gpa, " offset={d} content_w={d}", .{ cb.offset, cb.content_width });
        },
        .row => |row| if (row.header) try out.appendSlice(gpa, " header"),
        .nav_item => |n| {
            try appendQuoted(gpa, out, n.label);
            try out.appendSlice(gpa, " route=");
            try appendQuoted(gpa, out, n.route);
            const current = if (app.router.current()) |c| std.mem.eql(u8, c, n.route) else false;
            if (current) try out.appendSlice(gpa, " current");
        },
        .nav_current => |n| {
            try appendQuoted(gpa, out, n.section);
            try out.appendSlice(gpa, " collapsed");
        },
        .nav_here => |n| {
            try appendQuoted(gpa, out, n.label);
            try out.appendSlice(gpa, " here");
        },
        .sheet => |s| try appendQuoted(gpa, out, s.title),
        .notice => |n| {
            try appendQuoted(gpa, out, n.title);
            if (n.description.len > 0) {
                try out.appendSlice(gpa, " description=");
                try appendQuoted(gpa, out, n.description);
            }
            try out.appendSlice(gpa, " route=");
            try appendQuoted(gpa, out, n.route);
        },
        .icon_button => |ib| {
            try out.print(gpa, " {s}", .{@tagName(ib.glyph)});
            try appendQuoted(gpa, out, ib.label);
        },
        .icon => |ic| {
            try out.print(gpa, " {s} scale={s} ink={s}", .{ @tagName(ic.name), @tagName(ic.scale), @tagName(ic.ink) });
            if (ic.label.len > 0) try appendQuoted(gpa, out, ic.label);
        },
        .list => |l| {
            if (l.ordered) try out.print(gpa, " ordered start={d}", .{l.start});
        },
        .list_item => |item| try appendQuoted(gpa, out, item.marker()),
        .document => |d| try appendQuoted(gpa, out, d.label),
        .box, .divider, .stack, .blockquote, .table, .cell, .nav, .sheet_close, .back, .notices_pane, .more => {},
    }

    if (app.focused) |f| {
        if (f.on(id)) try out.appendSlice(gpa, " focused");
    }
    // App state, like focus, rather than the element's own: the trace is
    // the text twin of the frame, so the mark has to show in it.
    if (app.ack) |a| {
        if (a.eql(id)) try out.appendSlice(gpa, " acknowledged");
    }
    try out.append(gpa, '\n');

    var it = app.tree.children(id);
    while (it.next()) |child| try dumpNode(gpa, out, app, child, depth + 1);
}

fn appendQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try out.appendSlice(gpa, " \"");
    for (bytes) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        else => {
            if (c < 0x20) {
                try out.print(gpa, "\\x{x:0>2}", .{c});
            } else {
                try out.append(gpa, c);
            }
        },
    };
    try out.append(gpa, '"');
}

/// Writes one tree snapshot per step into `sub_dir` (relative to `dir`).
pub const TreeSink = struct {
    io: Io,
    dir: Io.Dir,
    gpa: std.mem.Allocator,
    sub_dir: []const u8,

    pub fn init(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, sub_dir: []const u8) !TreeSink {
        try dir.createDirPath(io, sub_dir);
        return .{ .io = io, .dir = dir, .gpa = gpa, .sub_dir = sub_dir };
    }

    pub fn observer(self: *TreeSink) StepObserver {
        return .{ .ctx = self, .call = onStepErased };
    }

    fn onStepErased(ctx: ?*anyopaque, step: u32, action: []const u8, app: *App) anyerror!void {
        const self: *TreeSink = @ptrCast(@alignCast(ctx.?));
        try self.onStep(step, action, app);
    }

    pub fn onStep(self: *TreeSink, step: u32, action: []const u8, app: *App) !void {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.gpa);
        try dump(self.gpa, &data, app);

        var name_buf: [64]u8 = undefined;
        const name = stepFileName(&name_buf, step, action, "txt");
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.sub_dir, name });
        defer self.gpa.free(path);
        try self.dir.writeFile(self.io, .{ .sub_path = path, .data = data.items });
    }
};

// ---- tests ----

const testing = std.testing;

test "stepFileName numbers, sanitizes, truncates" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0007-tap-Show-done.ppm", stepFileName(&buf, 7, "tap Show done", "ppm"));
    try testing.expectEqualStrings("0000-init.txt", stepFileName(&buf, 0, "init", "txt"));
    const long = stepFileName(&buf, 1, "x" ** 100, "txt");
    try testing.expect(long.len <= buf.len);
    try testing.expect(std.mem.endsWith(u8, long, ".txt"));
}

test "dump serializes roles, rects, state, and focus" {
    var app = try test_app.init(200, 200);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .heading = .{ .content = "Hi \"there\"", .level = .h2 } });
    const cb = try app.tree.appendId(root, .{ .toggle = .{ .label = "Done", .on = true } });
    app.focused = .of(cb);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try dump(testing.allocator, &out, &app);

    try testing.expect(std.mem.indexOf(u8, out.items, "viewport 200x200") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "heading [") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"Hi \\\"there\\\"\" level=2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"Done\" on focused") != null);
}

test "dump serializes sheets and notices" {
    var app = try test_app.init(200, 200);
    defer app.deinit();
    try app.notify(.{ .title = "Sync failed", .description = "Changes kept locally.", .route = "details", .important = true });
    try app.tree.append(app.tree.rootId(), .{ .sheet = .{ .title = "Options" } });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try dump(testing.allocator, &out, &app);

    try testing.expect(std.mem.indexOf(u8, out.items, "sheet [") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"Options\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"Sync failed\" description= \"Changes kept locally.\" route= \"details\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "dismiss \"Dismiss: Sync failed\"") != null);
}

test "TreeSink writes one numbered file per step" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var app = try test_app.init(100, 100);
    defer app.deinit();

    var sink = try TreeSink.init(testing.io, tmp.dir, testing.allocator, "trace");
    try sink.onStep(0, "init", &app);
    try sink.onStep(1, "tap Done", &app);

    const back = try tmp.dir.readFileAlloc(testing.io, "trace/0001-tap-Done.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(back);
    try testing.expect(std.mem.indexOf(u8, back, "stack [") != null);
}
