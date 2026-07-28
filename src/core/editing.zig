//! Text editing for `text_input` and `text_area`: cursor motion,
//! splicing, and the IME composition protocol (start/update/commit/
//! cancel) every platform shell shares. Reached only through
//! `App.dispatch`.

const std = @import("std");
const app_mod = @import("app.zig");
const bidi = @import("bidi.zig");
const element_mod = @import("element.zig");
const event_mod = @import("event.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

/// One view over both editable elements: value, cursor, and composition,
/// with the element-specific keys (Home/End/Enter/↑/↓) left to each.
pub const Editable = struct {
    value: *[]const u8,
    cursor: *usize,
    composition: *[]const u8,
    on_change: element_mod.ChangeAction,
};

pub fn focusedEditable(app: *App) ?Editable {
    const stop = app.focused orelse return null;
    const el = app.tree.get(stop.node) orelse return null;
    return switch (el.*) {
        .text_input => |*i| inputEditable(i),
        .text_area => |*a| areaEditable(a),
        else => null,
    };
}

fn inputEditable(input: *element_mod.TextInput) Editable {
    return .{ .value = &input.value, .cursor = &input.cursor, .composition = &input.composition, .on_change = input.on_change };
}

fn areaEditable(area: *element_mod.TextArea) Editable {
    return .{ .value = &area.value, .cursor = &area.cursor, .composition = &area.composition, .on_change = area.on_change };
}

pub fn handleInputKey(app: *App, input: *element_mod.TextInput, key: event_mod.Key) !void {
    switch (key) {
        .home => input.cursor = 0,
        .end => input.cursor = input.value.len,
        .enter => input.on_submit.invoke(),
        else => try editKey(app, inputEditable(input), key),
    }
    app.layout_dirty = true;
}

pub fn handleAreaKey(app: *App, id: NodeId, area: *element_mod.TextArea, key: event_mod.Key) !void {
    switch (key) {
        .enter => try insertText(app, "\n"),
        .up => moveAreaCursor(app, id, area, -1),
        .down => moveAreaCursor(app, id, area, 1),
        .home => area.cursor = areaLines(app, id, area).cur.start,
        .end => area.cursor = areaLines(app, id, area).cur.end,
        else => try editKey(app, areaEditable(area), key),
    }
    app.layout_dirty = true;
}

/// Cursor motion and deletion shared by both text elements; the keys
/// whose meaning differs (Home/End/Enter/↑/↓) stay with each element.
fn editKey(app: *App, e: Editable, key: event_mod.Key) !void {
    switch (key) {
        .backspace => {
            if (e.cursor.* == 0) return;
            const start = prevCodepointBoundary(e.value.*, e.cursor.*);
            try splice(app, e, start, e.cursor.*, "");
            e.cursor.* = start;
            // Last use of `e`: the callback may grow the tree and
            // move the node this Editable points into.
            e.on_change.invoke(e.value.*);
        },
        .delete => {
            if (e.cursor.* >= e.value.len) return;
            const end = nextCodepointBoundary(e.value.*, e.cursor.*);
            try splice(app, e, e.cursor.*, end, "");
            e.on_change.invoke(e.value.*);
        },
        .left => {
            if (e.cursor.* > 0) e.cursor.* = prevCodepointBoundary(e.value.*, e.cursor.*);
        },
        .right => {
            if (e.cursor.* < e.value.len) e.cursor.* = nextCodepointBoundary(e.value.*, e.cursor.*);
        },
        .escape => e.composition.* = "",
        // Space is deliberately not an insert arm. A field's space
        // arrives as text, never as a key — `on_key` in
        // src/platform/shell.h — and a shell that sends both legs would
        // type it twice. A space that reaches a field as a key is a
        // shell bug; it is silently inert, like every other key here.
        else => {},
    }
}

pub fn insertText(app: *App, bytes: []const u8) !void {
    const e = focusedEditable(app) orelse return;
    // Platform bytes join tree-owned text here without passing the
    // tree's validating boundary, so the same rule is applied first:
    // an invalid sequence spliced mid-value would hand every prefix
    // slice invalid UTF-8. Valid input — every real shell's — costs
    // one scan and no extra copy.
    const clean = if (std.unicode.utf8ValidateSlice(bytes)) bytes else try app.tree.ownString(bytes);
    try splice(app, e, e.cursor.*, e.cursor.*, clean);
    e.cursor.* += clean.len;
    e.composition.* = "";
    app.needs_frame = true;
    app.layout_dirty = true;
    e.on_change.invoke(e.value.*);
}

pub fn handleIme(app: *App, ime: event_mod.ImeEvent) !void {
    const e = focusedEditable(app) orelse return;
    app.needs_frame = true;
    switch (ime) {
        .start => e.composition.* = "",
        .update => |u| e.composition.* = try app.tree.ownString(u.composition),
        .commit => |c| try insertText(app, c.text),
        .cancel => e.composition.* = "",
    }
}

fn splice(app: *App, e: Editable, start: usize, end: usize, insert: []const u8) !void {
    const old = e.value.*;
    const new_len = old.len - (end - start) + insert.len;
    const buf = try app.tree.arena.allocator().alloc(u8, new_len);
    @memcpy(buf[0..start], old[0..start]);
    @memcpy(buf[start .. start + insert.len], insert);
    @memcpy(buf[start + insert.len ..], old[end..]);
    e.value.* = buf;
}

pub const LineSpan = struct { start: usize, end: usize };
const AreaLines = struct { prev: ?LineSpan, cur: LineSpan, next: ?LineSpan };

/// The wrapped line holding the cursor plus its visual neighbors,
/// iterating the exact lines layout and the renderer produce. A cursor
/// at a soft-wrap boundary belongs to the end of the earlier line.
fn areaLines(app: *App, id: NodeId, area: *const element_mod.TextArea) AreaLines {
    const inner_w = app.tree.rectOf(id).w - 2 * (layout.metrics.input_pad + layout.metrics.border);
    var it = layout.wrap(app.measurer, .prose, text.Scale.body.px(), area.value, inner_w);
    var prev: ?LineSpan = null;
    var cur: ?LineSpan = null;
    var last: ?LineSpan = null;
    var before_last: ?LineSpan = null;
    while (it.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(area.value.ptr);
        const span: LineSpan = .{ .start = start, .end = start + line.len };
        if (cur == null) {
            if (area.cursor <= span.end) {
                prev = last;
                cur = span;
            } else {
                before_last = last;
                last = span;
            }
        } else {
            return .{ .prev = prev, .cur = cur.?, .next = span };
        }
    }
    if (cur) |c| return .{ .prev = prev, .cur = c, .next = null };
    // Cursor rides in trailing hanging whitespace past the last line.
    return .{ .prev = before_last, .cur = last orelse .{ .start = 0, .end = 0 }, .next = null };
}

fn moveAreaCursor(app: *App, id: NodeId, area: *element_mod.TextArea, dir: i32) void {
    const lines = areaLines(app, id, area);
    const target = (if (dir < 0) lines.prev else lines.next) orelse {
        area.cursor = if (dir < 0) 0 else area.value.len;
        return;
    };
    const size = text.Scale.body.px();
    if (!bidi.isComplex(area.value)) {
        // Keep the horizontal position: land on the last codepoint
        // boundary of the target line that fits within the caret's x.
        const px = app.measurer.measure(.prose, size, area.value[lines.cur.start..area.cursor]);
        var off = target.start;
        while (off < target.end) {
            const step = nextCodepointBoundary(area.value, off);
            if (app.measurer.measure(.prose, size, area.value[target.start..step]) > px) break;
            off = step;
        }
        area.cursor = off;
        return;
    }
    // Complex text: prefix widths are not positions, so keep the
    // *visual* x — including each line's own origin, since an RTL
    // paragraph's lines right-align — and land on the boundary whose
    // visual caret is nearest it.
    const inner_w = app.tree.rectOf(id).w - 2 * (layout.metrics.input_pad + layout.metrics.border);
    const px = lineOriginX(app, area.value, lines.cur, inner_w) +
        caretX(app, area.value, lines.cur.start, lines.cur.end, area.cursor, size);
    const target_origin = lineOriginX(app, area.value, target, inner_w);
    var best_off = target.start;
    var best_d: i32 = std.math.maxInt(i32);
    var off = target.start;
    while (true) {
        const vx = target_origin + caretX(app, area.value, target.start, target.end, off, size);
        const d: i32 = @intCast(@abs(vx - px));
        if (d < best_d) {
            best_d = d;
            best_off = off;
        }
        if (off >= target.end) break;
        off = nextCodepointBoundary(area.value, off);
    }
    area.cursor = best_off;
}

/// The x of a wrapped line's left edge within its field's inner box:
/// zero except for lines of a right-aligned (RTL, complex) paragraph.
/// Must agree with the renderer's alignment decision exactly.
pub fn lineOriginX(app: *App, value: []const u8, span: LineSpan, inner_w: i32) i32 {
    const bounds = paragraphBounds(value, span);
    const para = value[bounds.start..bounds.end];
    if (!bidi.isComplex(para) or bidi.paragraphDirection(para) != .rtl) return 0;
    return inner_w - app.measurer.measure(.prose, text.Scale.body.px(), value[span.start..span.end]);
}

/// Visual caret x for a logical offset within one wrapped line, relative
/// to the line's left edge. Complex lines map the offset through the
/// line's visual pieces; a caret inside an RTL piece sits at the width
/// of the piece's logical *suffix*, because later codepoints lie further
/// left. Prefix widths measure standalone, so a caret mid-word in joined
/// script can sit a pixel or two off the exact glyph boundary — the same
/// forfeit contextual shaping already imposes on prefix measurement.
pub fn caretX(app: *App, value: []const u8, line_start: usize, line_end: usize, cursor: usize, size_px: i32) i32 {
    const line = value[line_start..line_end];
    if (!bidi.isComplex(line)) {
        const to = @min(@max(cursor, line_start), line_end);
        return app.measurer.measure(.prose, size_px, value[line_start..to]);
    }
    const bounds = paragraphBounds(value, .{ .start = line_start, .end = line_end });
    const pb = value[bounds.start..bounds.end];
    const para = bidi.resolve(app.bidi_scratch, pb, bidi.paragraphDirection(pb));
    var runs_buf: [bidi.max_line_runs]bidi.Run = undefined;
    var edges_buf: [bidi.max_line_edges]u32 = undefined;
    var it = bidi.linePieces(&para, line_start - bounds.start, line_end - bounds.start, &runs_buf, &edges_buf);
    const rel = @min(@max(cursor, line_start), line_end) - bounds.start;
    var pen: i32 = 0;
    while (it.next()) |piece| {
        const bytes = pb[piece.start..piece.end];
        if (rel >= piece.start and rel <= piece.end) {
            return pen + if (piece.rtl)
                app.measurer.measure(.prose, size_px, pb[rel..piece.end])
            else
                app.measurer.measure(.prose, size_px, pb[piece.start..rel]);
        }
        pen += app.measurer.measureRun(.prose, size_px, bytes);
    }
    return pen;
}

const ParagraphBounds = struct { start: usize, end: usize };

/// The hard paragraph (\n-delimited) containing a wrapped line.
fn paragraphBounds(value: []const u8, span: LineSpan) ParagraphBounds {
    const start = if (std.mem.lastIndexOfScalar(u8, value[0..span.start], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, value, span.end, '\n') orelse value.len;
    return .{ .start = start, .end = end };
}

fn prevCodepointBoundary(bytes: []const u8, pos: usize) usize {
    var i = pos - 1;
    while (i > 0 and bytes[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

fn nextCodepointBoundary(bytes: []const u8, pos: usize) usize {
    var i = pos + 1;
    while (i < bytes.len and bytes[i] & 0xC0 == 0x80) i += 1;
    return i;
}
