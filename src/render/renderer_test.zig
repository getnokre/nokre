//! Tests for renderer.zig against the recording canvas: op-stream
//! structure, appearance inversion, and per-element draw contracts.

const std = @import("std");
const app_mod = @import("../core/app.zig");
const canvas_mod = @import("canvas.zig");
const color = @import("../core/color.zig");
const element_mod = @import("../core/element.zig");
const geometry = @import("../core/geometry.zig");
const layout = @import("../core/layout.zig");
const wrap = @import("../core/wrap.zig");
const renderer = @import("renderer.zig");
const text = @import("../core/text.zig");
const test_app = @import("../core/test_app.zig");

const testing = std.testing;
const App = app_mod.App;
const Gray = color.Gray;
const Rect = geometry.Rect;
const Recording = canvas_mod.Recording;
const metrics = layout.metrics;
const obscure_bullet = renderer.obscure_bullet;
const render = renderer.render;

fn noopPress(_: ?*anyopaque) void {}

/// One frame of `app`, as the ops it drew. The caller deinits — every
/// test here reads a recording, and none of them cares how it was made.
fn frameOf(app: *App) Recording {
    var rec = Recording.init(testing.allocator);
    render(app, rec.canvas());
    return rec;
}

/// The rect the recording canvas sees for an outset focus ring: the
/// element's rect, the clear, and the stroke itself.
fn focusRingRect(r: Rect) Rect {
    return r.inset(-(metrics.focus_clear + metrics.focus_stroke));
}

test "renderer clears to paper and draws all visible text" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Title" } });
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    try testing.expectEqual(Recording.Op{ .clear = .paper }, rec.ops.items[0]);
    try testing.expect(rec.containsText("Title"));
    try testing.expect(rec.containsText("Save"));
    try testing.expect(!app.needs_frame);
}

test "window overflow draws a root scroll indicator, quiet until scrolled" {
    var app = try test_app.init(200, 100);
    defer app.deinit();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }

    var rec = frameOf(&app);
    defer rec.deinit();
    try testing.expectEqual(Gray.g8, rootIndicatorGray(&rec).?);

    // Scrolling the window arms the emphasis latch; a tap that moves
    // nothing releases it.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 100, .y = 50 }, .delta_y = 30 } });
    var scrolled = frameOf(&app);
    defer scrolled.deinit();
    try testing.expectEqual(Gray.g6, rootIndicatorGray(&scrolled).?);

    try app.tap(.{ .x = 100, .y = 50 });
    var rested = frameOf(&app);
    defer rested.deinit();
    try testing.expectEqual(Gray.g8, rootIndicatorGray(&rested).?);
}

fn rootIndicatorGray(rec: *const Recording) ?Gray {
    var fills = rec.opsOf(.fill_rect);
    while (fills.next()) |f| {
        if (f.rect.x == 198 and f.rect.w == 2) return f.gray;
    }
    return null;
}

test "dark scheme swaps the ramp, not the steps" {
    // Draw code names steps and never inverts; the appearance picks the
    // bytes. So the *same* ops come out in both appearances — the page
    // is `paper` and the heading is `ink` either way — and the whole
    // difference is which ramp the canvas was told to resolve through.
    var app = try App.init(testing.allocator, .{ .viewport = .{ .w = 400, .h = 400 }, .scheme = .dark, .services = .mocks() });
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Title" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    try testing.expectEqual(Recording.Op{ .clear = .paper }, rec.ops.items[0]);
    try testing.expectEqual(color.Appearance.dark, rec.appearance);
    for (rec.ops.items) |op| {
        if (op == .draw_text) try testing.expectEqual(Gray.ink, op.draw_text.gray);
    }
    // …and the ramp really does flip the page: paper is the lightest
    // byte in light and the darkest in dark.
    try testing.expectEqual(@as(u8, 0xFF), Gray.paper.byte(.light));
    try testing.expectEqual(@as(u8, 0x00), Gray.paper.byte(.dark));
}

test "dark is eased, not mirrored" {
    // The property that makes the second ramp worth its existence: body
    // text is gentler in dark than in light, where an inversion would
    // have made it identical. Component boundaries are held instead.
    const l = Gray.ink.contrastWith(.paper, .light);
    const d = Gray.ink.contrastWith(.paper, .dark);
    try testing.expect(d < l);
    try testing.expect(d >= color.min_text_contrast);
    // Neither appearance reaches the harshness the old palette shipped.
    try testing.expect(l <= color.max_text_contrast);
}

test "auto scheme follows the system appearance" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    app.setSystemAppearance(.dark);
    try testing.expect(app.needs_frame);

    var rec = frameOf(&app);
    defer rec.deinit();
    try testing.expectEqual(Recording.Op{ .clear = .paper }, rec.ops.items[0]);
    try testing.expectEqual(color.Appearance.dark, rec.appearance);
}

test "focused button renders inverted with a focus ring" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Go" } });
    app.focused = .of(btn);

    var rec = frameOf(&app);
    defer rec.deinit();

    var found_fill = false;
    var found_ring = false;
    app.performLayout();
    const r = app.tree.rectOf(btn);
    for (rec.ops.items) |op| {
        switch (op) {
            .fill_rect => |f| {
                if (std.meta.eql(f.rect, r) and f.gray == Gray.ink) found_fill = true;
            },
            .stroke_rect => |s| {
                if (std.meta.eql(s.rect, focusRingRect(r))) found_ring = true;
            },
            else => {},
        }
    }
    try testing.expect(found_fill);
    try testing.expect(found_ring);
}

test "pointer-origin focus draws no ring; keyboard focus draws it again" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Go" } });
    app.performLayout();
    const r = app.tree.rectOf(btn);

    // A tap focuses the button but stands the drawn ring down: the
    // finger knows where it pressed (`App.focus_visible`).
    try app.tap(r.center());
    try testing.expect(app.focused.?.on(btn));
    var tapped = frameOf(&app);
    defer tapped.deinit();
    try testing.expect(!hasStroke(&tapped, focusRingRect(r)));

    // Tab brings the keyboard back, and the ring with it — focus
    // semantics never changed, only the indicator.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(btn));
    var keyed = frameOf(&app);
    defer keyed.deinit();
    try testing.expect(hasStroke(&keyed, focusRingRect(r)));
}

test "a tapped text field keeps its caret and focused edge" {
    // The editable carve-out: an element taking text input shows its
    // focus whatever moved it there — the thickened edge is where the
    // caret lives, and a tapped field with no visible focus would be a
    // field that looks dead while the keyboard is up.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Name", .value = "hi" } });
    app.performLayout();
    try app.tap(app.tree.rectOf(input).center());
    try testing.expect(!app.focus_visible);

    var rec = frameOf(&app);
    defer rec.deinit();
    var found_edge = false;
    var strokes = rec.opsOf(.stroke_rect);
    while (strokes.next()) |s| {
        if (s.thickness == metrics.focus_stroke and s.gray == Gray.ink) found_edge = true;
    }
    try testing.expect(found_edge);
    var found_caret = false;
    var lines = rec.opsOf(.line);
    while (lines.next()) |l| {
        if (l.from.x == l.to.x and l.gray == Gray.ink) found_caret = true;
    }
    try testing.expect(found_caret);
}

fn hasStroke(rec: *const Recording, r: Rect) bool {
    var it = rec.opsOf(.stroke_rect);
    while (it.next()) |s| {
        if (std.meta.eql(s.rect, r)) return true;
    }
    return false;
}

test "glyph-form button draws the quiet glyph, no pill and no label text" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Next cycle", .form = .{ .glyph = .chevron_right } } });
    app.focused = .of(btn);

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(btn);
    var found_fill = false;
    var found_ring = false;
    for (rec.ops.items) |op| {
        switch (op) {
            .fill_rect => |f| {
                if (std.meta.eql(f.rect, r)) found_fill = true;
            },
            .stroke_rect => |s| {
                if (std.meta.eql(s.rect, focusRingRect(r))) found_ring = true;
            },
            else => {},
        }
    }
    try testing.expect(!found_fill);
    try testing.expect(found_ring);
    try testing.expect(rec.containsText(element_mod.IconName.chevron_right.utf8()));
    try testing.expect(!rec.containsText("Next cycle"));
}

test "a pill with an icon draws glyph and label inside the fill" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Add reminder", .form = .{ .filled = .alarm_clock_plus } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(btn);
    var found_fill = false;
    var glyph_x: i32 = 0;
    var label_x: i32 = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .fill_rect => |f| {
                if (std.meta.eql(f.rect, r) and f.gray == Gray.ink) found_fill = true;
            },
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, element_mod.IconName.alarm_clock_plus.utf8())) {
                    try testing.expectEqual(Gray.paper, t.gray);
                    glyph_x = t.x;
                }
                if (std.mem.eql(u8, t.bytes, "Add reminder")) {
                    try testing.expectEqual(Gray.paper, t.gray);
                    label_x = t.x;
                }
            },
            else => {},
        }
    }
    try testing.expect(found_fill);
    try testing.expect(glyph_x > 0 and label_x > glyph_x); // glyph leads the words
}

test "secondary button draws an outline on the ambient, never a fill" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Cancel", .form = .{ .secondary = null } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(btn);
    var found_fill = false;
    var found_outline = false;
    for (rec.ops.items) |op| {
        switch (op) {
            .fill_rect => |f| {
                if (std.meta.eql(f.rect, r)) found_fill = true;
            },
            .stroke_rect => |s| {
                if (std.meta.eql(s.rect, r) and s.gray == Gray.g6) found_outline = true;
            },
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, "Cancel")) try testing.expectEqual(Gray.ink, t.gray);
            },
            else => {},
        }
    }
    try testing.expect(!found_fill);
    try testing.expect(found_outline);

    // Same geometry as the filled primary: the pair aligns side by side.
    // (Same codepoint count under the fixed measurer → same intrinsic width.)
    const primary = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Delete" } });
    app.invalidate();
    app.performLayout();
    try testing.expectEqual(app.tree.rectOf(primary).w, r.w);
    try testing.expectEqual(app.tree.rectOf(primary).h, r.h);
}

test "the Google button overlays four arc glyphs in the mandated colors at one origin" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Sign in with Google", .form = .{ .provider = .google } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    // The four colors are the vendor's spec, transcribed — pinned here
    // so a palette refactor can never drift them. One origin: the arcs
    // compose into a G only because they share the frame they were cut
    // from.
    const want = [_]struct { glyph: []const u8, rgb: canvas_mod.Rgb }{
        .{ .glyph = "\u{e901}", .rgb = .{ .r = 0x42, .g = 0x85, .b = 0xF4 } },
        .{ .glyph = "\u{e902}", .rgb = .{ .r = 0x34, .g = 0xA8, .b = 0x53 } },
        .{ .glyph = "\u{e903}", .rgb = .{ .r = 0xFB, .g = 0xBC, .b = 0x05 } },
        .{ .glyph = "\u{e904}", .rgb = .{ .r = 0xEA, .g = 0x43, .b = 0x35 } },
    };
    var arcs = rec.opsOf(.draw_text_rgb);
    var n: usize = 0;
    var origin_x: ?i32 = null;
    var origin_y: ?i32 = null;
    while (arcs.next()) |a| : (n += 1) {
        try testing.expect(n < want.len);
        try testing.expectEqualStrings(want[n].glyph, a.bytes);
        try testing.expectEqual(want[n].rgb, a.rgb);
        try testing.expectEqual(text.Face.brand, a.face);
        if (origin_x) |x| try testing.expectEqual(x, a.x) else origin_x = a.x;
        if (origin_y) |y| try testing.expectEqual(y, a.baseline) else origin_y = a.baseline;
    }
    try testing.expectEqual(want.len, n);

    // The pill itself never leaves the palette: white at the pinned
    // endpoint with the hairline border, near-black label (the golden
    // pins the bytes; this pins the steps).
    app.performLayout();
    const r = app.tree.rectOf(btn);
    var found_fill = false;
    var found_border = false;
    var fills = rec.opsOf(.fill_rect);
    while (fills.next()) |f| {
        if (std.meta.eql(f.rect, r) and f.gray == Gray.g12) found_fill = true;
    }
    var strokes = rec.opsOf(.stroke_rect);
    while (strokes.next()) |s| {
        if (std.meta.eql(s.rect, r) and s.gray == Gray.g6 and s.thickness == metrics.border) found_border = true;
    }
    try testing.expect(found_fill);
    try testing.expect(found_border);
    try testing.expect(rec.containsText("Sign in with Google"));
}

test "the dark appearance flips the Google button to its dark theme, G unchanged" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    app.setScheme(.dark);
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Sign in with Google", .form = .{ .provider = .google } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(btn);
    var found_fill = false;
    var fills = rec.opsOf(.fill_rect);
    while (fills.next()) |f| {
        if (std.meta.eql(f.rect, r) and f.gray == Gray.g0) found_fill = true;
    }
    try testing.expect(found_fill);
    // A trademark has no dark mode: the same four ops, the same colors.
    var arcs = rec.opsOf(.draw_text_rgb);
    var n: usize = 0;
    while (arcs.next()) |a| : (n += 1) {
        try testing.expect(a.rgb.r != a.rgb.g or a.rgb.g != a.rgb.b); // colored, not resolved through any ramp
    }
    try testing.expectEqual(@as(usize, 4), n);
}

test "a dimmed Google button draws the G as a silhouette, not in color" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Sign in with Google", .form = .{ .provider = .google }, .disabled = true } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var arcs = rec.opsOf(.draw_text_rgb);
    try testing.expectEqual(@as(?canvas_mod.Recording.DrawTextRgb, null), arcs.next());
    // All four arcs still land — overlaid in one tone they read as the
    // whole G — in the disabled label gray.
    var n: usize = 0;
    var texts = rec.opsOf(.draw_text);
    while (texts.next()) |t| {
        if (t.face.family == .brand) {
            try testing.expectEqual(Gray.g11, t.gray);
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), n);
}

test "no frame without a Google button carries a colored op" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .heading = .{ .content = "Sign in", .level = .h1 } });
    try app.tree.append(root, .{ .button = .{ .label = "Sign in with Apple", .form = .{ .provider = .apple } } });
    try app.tree.append(root, .{ .button = .{ .label = "Continue", .form = .{ .filled = .chevron_right } } });

    var rec = frameOf(&app);
    defer rec.deinit();
    var arcs = rec.opsOf(.draw_text_rgb);
    try testing.expectEqual(@as(?canvas_mod.Recording.DrawTextRgb, null), arcs.next());
}

test "disabled glyph-form button dims its glyph" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Next cycle", .form = .{ .glyph = .chevron_right }, .disabled = true } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var found = false;
    for (rec.ops.items) |op| {
        if (op == .draw_text and std.mem.eql(u8, op.draw_text.bytes, element_mod.IconName.chevron_right.utf8())) {
            try testing.expectEqual(Gray.g6, op.draw_text.gray);
            found = true;
        }
    }
    try testing.expect(found);
}

test "an in-progress button swaps its words for a centered ellipsis, at the size the words asked for" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const running = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save changes", .form = .{ .filled = .alarm_clock_plus }, .in_progress = true } });
    // The same button at rest: the pill must measure identically, so
    // starting the work moves nothing on the screen.
    const resting = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save changes", .form = .{ .filled = .alarm_clock_plus } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    const r = app.tree.rectOf(running);
    try testing.expectEqual(app.tree.rectOf(resting).w, r.w);
    try testing.expectEqual(app.tree.rectOf(resting).h, r.h);

    var ellipses: usize = 0;
    var icons: usize = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, wrap.ellipsis)) {
                    ellipses += 1;
                    // Centered in the pill the label sized — not at the
                    // leading pad, where a label would start.
                    const w = app.measurer.measure(.prose, t.size_px, t.bytes);
                    try testing.expectEqual(r.x + @divTrunc(r.w - w, 2), t.x);
                    // Busy is not unavailable: the fill and the ink stay
                    // exactly the enabled pill's.
                    try testing.expectEqual(Gray.paper, t.gray);
                }
                // The icon names the action, and the action is running.
                if (t.face.family == .icons) icons += 1;
            },
            .fill_rect => |f| if (std.meta.eql(f.rect, r)) try testing.expectEqual(Gray.ink, f.gray),
            else => {},
        }
    }
    // The words are gone while the work runs; the resting twin still
    // draws its own, so one of each mark is on screen.
    try testing.expectEqual(@as(usize, 1), ellipses);
    try testing.expectEqual(@as(usize, 1), icons);
    // The accessible name never changed — only the pixels did.
    try testing.expectEqualStrings("Save changes", app.tree.getConst(running).?.label());
}

test "a busy switch stands its track down for the ellipsis and keeps the row" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const busy = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{ .label = "Push to phone", .on = true, .in_progress = true } });
    // The same switch at rest: the row must measure identically, so the
    // flip moves nothing on the screen.
    const resting = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{ .label = "Push to phone", .on = true } });

    var rec = frameOf(&app);
    defer rec.deinit();

    const r = app.tree.rectOf(busy);
    try testing.expectEqual(app.tree.rectOf(resting).w, r.w);
    try testing.expectEqual(app.tree.rectOf(resting).h, r.h);

    var ellipses: usize = 0;
    var words: usize = 0;
    for (rec.ops.items) |op| switch (op) {
        .draw_text => |t| {
            if (std.mem.eql(u8, t.bytes, wrap.ellipsis)) {
                ellipses += 1;
                // Centered in the track's own slot, not in the row: the
                // words keep the column beside it.
                const w = app.measurer.measure(.prose, t.size_px, t.bytes);
                try testing.expectEqual(r.x + @divTrunc(metrics.toggle_track_w - w, 2), t.x);
                // Busy is not unavailable — full ink, like the words.
                try testing.expectEqual(Gray.ink, t.gray);
            }
            if (std.mem.eql(u8, t.bytes, "Push to phone")) words += 1;
        },
        // The track and the knob are the two fills a resting switch
        // draws; the busy one draws neither, so only the resting twin's
        // pair is on screen.
        .fill_rect => |f| try testing.expect(f.rect.y < r.y or f.rect.y >= r.y + r.h),
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), ellipses);
    // Both rows still say their name — a state is not a name.
    try testing.expectEqual(@as(usize, 2), words);
}

test "a busy checkbox does the same in its own narrower slot" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const busy = try app.tree.appendId(app.tree.rootId(), .{ .checkbox = .{ .label = "Weekly digest", .checked = true, .in_progress = true } });

    var rec = frameOf(&app);
    defer rec.deinit();

    const r = app.tree.rectOf(busy);
    var found = false;
    for (rec.ops.items) |op| switch (op) {
        .draw_text => |t| {
            if (std.mem.eql(u8, t.bytes, wrap.ellipsis)) {
                const w = app.measurer.measure(.prose, t.size_px, t.bytes);
                try testing.expectEqual(r.x + @divTrunc(metrics.checkbox_box - w, 2), t.x);
                found = true;
            }
            // The check mark is the box's, and the box has stood down.
            try testing.expect(!std.mem.eql(u8, t.bytes, element_mod.checkbox_check));
        },
        else => {},
    };
    try testing.expect(found);
}

test "a known percentage takes the ellipsis's slot without moving the pill" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const running = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save changes", .in_progress = true, .progress_percent = 60 } });
    const resting = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save changes" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    const r = app.tree.rectOf(running);
    // Same button as ever: the state changes what stands in the middle,
    // never the box or its fill.
    try testing.expectEqual(app.tree.rectOf(resting).w, r.w);
    try testing.expectEqual(app.tree.rectOf(resting).h, r.h);
    try testing.expect(!rec.containsText(wrap.ellipsis));

    const track: Rect = .{
        .x = r.x + metrics.border + metrics.button_pad_h,
        .y = r.y + @divTrunc(r.h - metrics.meter_h, 2),
        .w = r.w - 2 * (metrics.border + metrics.button_pad_h),
        .h = metrics.meter_h,
    };
    const inner_w = track.w - 2 * metrics.border;
    var found_track = false;
    var found_fill = false;
    for (rec.ops.items) |op| {
        switch (op) {
            .fill_rect => |f| {
                if (std.meta.eql(f.rect, r)) try testing.expectEqual(Gray.ink, f.gray);
                if (std.meta.eql(f.rect, track)) {
                    // On the ink pill the track carries itself; no stroke.
                    try testing.expectEqual(Gray.g7, f.gray);
                    found_track = true;
                }
                if (f.rect.x == track.x + metrics.border and f.rect.h == track.h - 2 * metrics.border) {
                    // 60% of the inner width, from the leading edge.
                    try testing.expectEqual(@divTrunc(inner_w * 60, 100), f.rect.w);
                    try testing.expectEqual(Gray.paper, f.gray);
                    found_fill = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(found_track);
    try testing.expect(found_fill);
}

test "an outlined button at a known percentage reuses the standalone meter's tones" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const id = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Cancel upload",
        .form = .{ .secondary = null },
        .in_progress = true,
        .progress_percent = 25,
    } });

    var rec = frameOf(&app);
    defer rec.deinit();

    const r = app.tree.rectOf(id);
    const track: Rect = .{
        .x = r.x + metrics.border + metrics.button_pad_h,
        .y = r.y + @divTrunc(r.h - metrics.meter_h, 2),
        .w = r.w - 2 * (metrics.border + metrics.button_pad_h),
        .h = metrics.meter_h,
    };
    var track_fill: ?Gray = null;
    var boundary: ?Gray = null;
    var progress: ?Gray = null;
    for (rec.ops.items) |op| {
        switch (op) {
            .fill_rect => |f| {
                if (std.meta.eql(f.rect, track)) track_fill = f.gray;
                if (f.rect.x == track.x + metrics.border and f.rect.h == track.h - 2 * metrics.border) progress = f.gray;
            },
            // The ambient ground is the one that needs the 1.4.11 stroke.
            .stroke_rect => |s| if (std.meta.eql(s.rect, track)) {
                boundary = s.gray;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(?Gray, .g11), track_fill);
    try testing.expectEqual(@as(?Gray, .g6), boundary);
    try testing.expectEqual(@as(?Gray, .ink), progress);
}

test "design proof: a button's meter clears WCAG 1.4.11 on both grounds, both appearances" {
    // The track has to be perceivable against the pill it sits in, and
    // the fill against the track — 3:1 each, in both appearances. On the
    // filled pill exactly one step does both: g6 fails against the ink
    // ground in dark (2.69), g8 fails against the paper fill (2.32), and
    // g7 clears both. This is why the renderer names g7 and not a tone
    // that merely looked right.
    const min = color.min_component_contrast;
    for ([_]color.Appearance{ .light, .dark }) |a| {
        try testing.expect(Gray.g7.contrastWith(.ink, a) >= min);
        try testing.expect(Gray.g7.contrastWith(.paper, a) >= min);
        // The neighbours do not, either side.
        try testing.expect(Gray.g6.contrastWith(.ink, .dark) < min);
        try testing.expect(Gray.g8.contrastWith(.paper, a) < min);
        // The outlined pill sits on the ambient ground, so it borrows
        // the standalone meter's pair, already proven in color.zig.
        try testing.expect(Gray.g6.contrastWith(.g11, a) >= min);
        try testing.expect(Gray.ink.contrastWith(.g11, a) >= min);
    }
}

test "an in-progress glyph-form button stands the ellipsis where its glyph was" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const id = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Next cycle",
        .form = .{ .glyph = .chevron_right },
        .in_progress = true,
    } });

    var rec = frameOf(&app);
    defer rec.deinit();

    const r = app.tree.rectOf(id);
    var found = false;
    for (rec.ops.items) |op| {
        if (op != .draw_text) continue;
        const t = op.draw_text;
        // No pill to swap the words inside: the glyph itself stands down.
        try testing.expect(t.face.family != .icons);
        if (std.mem.eql(u8, t.bytes, wrap.ellipsis)) {
            const w = app.measurer.measure(.prose, t.size_px, t.bytes);
            try testing.expectEqual(r.x + @divTrunc(r.w - w, 2), t.x);
            try testing.expectEqual(Gray.ink, t.gray);
            found = true;
        }
    }
    try testing.expect(found);
    // Still the bare touch target — the state costs no geometry here either.
    try testing.expectEqual(metrics.touch_target, r.w);
    try testing.expectEqual(metrics.touch_target, r.h);
}

test "obscured input draws one bullet per codepoint, never the value" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{
        .label = "Passphrase",
        .value = "héllo",
        .cursor = 3,
        .obscured = true,
    } });

    var rec = frameOf(&app);
    defer rec.deinit();

    try testing.expect(!rec.containsText("héllo"));
    try testing.expect(!rec.containsText("llo"));
    var bullets: usize = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, obscure_bullet)) bullets += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 5), bullets); // 5 codepoints
}

test "copyable draws a short value whole, in mono" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Code", .value = "XKCD-1234" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var mono: usize = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .draw_text => |t| if (t.face.family == .mono) {
                try testing.expectEqualStrings("XKCD-1234", t.bytes);
                try testing.expectEqual(Gray.ink, t.gray);
                mono += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), mono);
}

test "copyable elides a long value in the middle, clear of the copy glyph" {
    var app = try test_app.init(200, 200);
    defer app.deinit();
    // Fixed measurer, body scale: 9px per codepoint. Field 168 wide,
    // value slot 139 (pads, glyph, gap off) — 14 of 46 codepoints
    // survive around the ellipsis, 7 a side.
    const value = "0123456789abcdefghijklmnopqrstuvwxyz0123456789";
    try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Invite", .value = value } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var mono_end: i32 = 0;
    var glyph_x: i32 = 0;
    var runs: [3]Recording.Op = undefined;
    var n: usize = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .draw_text => |t| switch (t.face.family) {
                .mono => {
                    runs[n] = op;
                    n += 1;
                    mono_end = t.x + app.measurer.measure(.mono, t.size_px, t.bytes);
                },
                .icons => glyph_x = t.x,
                else => {},
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("0123456", runs[0].draw_text.bytes);
    try testing.expectEqualStrings("…", runs[1].draw_text.bytes);
    try testing.expectEqual(Gray.mid, runs[1].draw_text.gray);
    try testing.expectEqualStrings("3456789", runs[2].draw_text.bytes);
    try testing.expect(!rec.containsText(value));
    // The elided run stops short of the glyph's reserved slot.
    try testing.expect(mono_end <= glyph_x - metrics.icon_gap);
}

test "an acknowledged copyable draws a check where its copy glyph sits" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Code", .value = "XKCD-1234" } });

    var before = frameOf(&app);
    defer before.deinit();
    try testing.expect(before.containsText(element_mod.copy_glyph));
    try testing.expect(!before.containsText(element_mod.copy_check));

    app.ack = c;
    var after = frameOf(&app);
    defer after.deinit();
    try testing.expect(after.containsText(element_mod.copy_check));
    try testing.expect(!after.containsText(element_mod.copy_glyph));

    // The mark is the acknowledged element's alone: a second copyable
    // keeps its affordance while the first wears the check.
    const other = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Link", .value = "nok.re/x" } });
    _ = other;
    var both = frameOf(&app);
    defer both.deinit();
    try testing.expect(both.containsText(element_mod.copy_check));
    try testing.expect(both.containsText(element_mod.copy_glyph));
}

/// Every codepoint 9px, except the check, which reports twice that: the
/// widths that matter to the reserved slot are the ones a real font
/// gives, and the fixed measurer's are identical by construction.
fn lopsidedCheck(_: ?*anyopaque, face: text.Face, size_px: i32, bytes: []const u8) i32 {
    const w = text.Measurer.fixed.measureRun(face, size_px, bytes);
    return if (std.mem.eql(u8, bytes, element_mod.copy_check)) w * 2 else w;
}

test "the mark's slot is reserved, so acknowledging never reflows the value" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 200, .h = 200 },
        .services = .mocks(),
        .measurer = .{ .measureFn = lopsidedCheck },
    });
    defer app.deinit();
    // Long enough to elide: the elision budget is what would move if the
    // slot tracked the drawn glyph instead of the wider of the two.
    const value = "0123456789abcdefghijklmnopqrstuvwxyz0123456789";
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Invite", .value = value } });

    var before = frameOf(&app);
    defer before.deinit();

    app.ack = c;
    var after = frameOf(&app);
    defer after.deinit();

    // Same runs, same bytes, same pixels: the value is a property of the
    // field, not of what just happened to it.
    var seen: usize = 0;
    var i: usize = 0;
    var texts = before.opsOf(.draw_text);
    while (texts.next()) |t| {
        if (t.face.family != .mono) continue;
        while (i < after.ops.items.len) : (i += 1) {
            const a = switch (after.ops.items[i]) {
                .draw_text => |a| a,
                else => continue,
            };
            if (a.face.family != .mono) continue;
            try testing.expectEqualStrings(t.bytes, a.bytes);
            try testing.expectEqual(t.x, a.x);
            i += 1;
            seen += 1;
            break;
        }
    }
    // head, ellipsis, tail — the value did elide, so the budget was live.
    try testing.expectEqual(@as(usize, 3), seen);
}

test "tile group: labels and details drawn, route tiles carry a chevron" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Members", .route = "members" } });
    try app.tree.append(group, .{ .tile = .{ .label = "Sign out", .detail = "Ends the session", .on_press = .{ .call = noopPress } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    try testing.expect(rec.containsText("Members"));
    try testing.expect(rec.containsText("Sign out"));
    try testing.expect(rec.containsText("Ends the session"));
    // One chevron: the route tile's affordance, absent on the action tile.
    var chevrons: usize = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, element_mod.tile_chevron)) chevrons += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), chevrons);
}

test "tile group description: dim small print below a border that excludes it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{ .description = "Personalize your experience" } });
    try app.tree.append(group, .{ .tile = .{ .label = "Personalization", .route = "personalization" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(group);
    var found_border = false;
    var desc_y: i32 = 0;
    var border_bottom: i32 = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .stroke_rect => |s| {
                // The border wraps the rows only, not the description.
                if (s.rect.x == r.x and s.rect.y == r.y and s.gray == Gray.g10) {
                    found_border = true;
                    border_bottom = s.rect.bottom();
                    try testing.expect(s.rect.h < r.h);
                }
            },
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, "Personalize your experience")) {
                    desc_y = t.baseline;
                    try testing.expectEqual(Gray.dark, t.gray);
                }
            },
            else => {},
        }
    }
    try testing.expect(found_border);
    // The caption's baseline sits below the border box, inside the rect.
    try testing.expect(desc_y > border_bottom);
    try testing.expect(desc_y <= r.bottom());
}

test "badge draws its label inside a grouping border" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const badge = try app.tree.appendId(app.tree.rootId(), .{ .badge = .{ .label = "Active" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(badge);
    var found_border = false;
    var found_label = false;
    for (rec.ops.items) |op| {
        switch (op) {
            .stroke_rect => |s| {
                if (std.meta.eql(s.rect, r) and s.gray == Gray.g10) found_border = true;
            },
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, "Active") and t.size_px == text.Scale.small.px()) found_label = true;
            },
            else => {},
        }
    }
    try testing.expect(found_border);
    try testing.expect(found_label);
}

test "meter draws its words above a proportionally filled track" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const meter = try app.tree.appendId(app.tree.rootId(), .{ .meter = .{ .label = "12 of 30 days", .value = 15, .max = 30 } });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(meter);
    const track_w = r.w;
    const fill_w = @divTrunc((track_w - 2 * metrics.border) * 15, 30);
    var found_label = false;
    var found_track = false;
    var found_border = false;
    var found_fill = false;
    for (rec.ops.items) |op| {
        switch (op) {
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, "12 of 30 days") and t.size_px == text.Scale.small.px()) found_label = true;
            },
            .fill_rect => |f| {
                if (f.gray == Gray.g11 and f.rect.w == track_w and f.rect.h == metrics.meter_h) found_track = true;
                if (f.gray == Gray.ink and f.rect.w == fill_w) found_fill = true;
            },
            .stroke_rect => |s| {
                if (s.gray == Gray.g6 and s.rect.w == track_w and s.rect.h == metrics.meter_h) found_border = true;
            },
            else => {},
        }
    }
    try testing.expect(found_label);
    try testing.expect(found_track);
    try testing.expect(found_border);
    try testing.expect(found_fill);
}

test "qr holds true ink on true paper in dark mode; its label follows the ramp" {
    var app = try App.init(testing.allocator, .{ .viewport = .{ .w = 400, .h = 400 }, .scheme = .dark, .services = .mocks() });
    defer app.deinit();
    const qr = try app.tree.appendId(app.tree.rootId(), .{ .qr = .{
        .label = "Invite link",
        .value = "https://example.com/invite/XKCD-1234",
    } });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const q = app.tree.getConst(qr).?.qr;
    const r = app.tree.rectOf(qr);
    const side = layout.qrSide(q.size, r.w);
    var found_tile = false;
    var module_fills: usize = 0;
    var labeled = false;
    for (rec.ops.items) |op| switch (op) {
        .fill_rect => |f| {
            // Dark appearance, yet the tile draws `.g12` and the modules
            // `.g0` — the two steps the design system no longer uses,
            // pinned to the light ramp so they rasterize to true paper
            // and true ink. A scanner wants maximum modulation, and a
            // photo-negative code is a different code.
            if (f.gray == Gray.g12 and f.rect.w == side and f.rect.h == side) found_tile = true;
            if (f.gray == Gray.g0 and f.rect.h == @divTrunc(side, q.size + 2 * metrics.qr_quiet)) module_fills += 1;
        },
        .draw_text => |t| {
            // The label is ordinary text and does follow the appearance.
            if (std.mem.eql(u8, t.bytes, "Invite link") and t.gray == Gray.ink) labeled = true;
        },
        else => {},
    };
    try testing.expect(found_tile);
    try testing.expect(module_fills > 0);
    try testing.expect(labeled);
    // The escape is about bytes, so assert bytes: the tile stays true
    // paper and the modules true ink while the label goes light.
    try testing.expectEqual(@as(u8, 0xFF), Gray.g12.byte(.light));
    try testing.expectEqual(@as(u8, 0x00), Gray.g0.byte(.light));
    try testing.expect(Gray.ink.byte(.dark) > 0x80);
}

test "scroll region clips its children" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    try app.tree.append(sr, .{ .text = .{ .content = "in" } });
    try app.tree.append(sr, .{ .text = .{ .content = "below the fold" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var clip_depth: i32 = 0;
    var texts_inside: usize = 0;
    for (rec.ops.items) |op| {
        switch (op) {
            .push_clip => clip_depth += 1,
            .pop_clip => clip_depth -= 1,
            .draw_text => if (clip_depth > 0) {
                texts_inside += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(i32, 0), clip_depth);
    try testing.expectEqual(@as(usize, 2), texts_inside);
}

test "identical trees produce identical op streams" {
    var streams: [2]usize = undefined;
    for (&streams) |*slot| {
        var app = try test_app.init(640, 480);
        defer app.deinit();
        const box = try app.tree.appendId(app.tree.rootId(), .{ .box = .{} });
        try app.tree.append(box, .{ .text = .{ .content = "deterministic output every time" } });
        try app.tree.append(app.tree.rootId(), .{ .toggle = .{ .label = "agree", .on = true } });

        var rec = frameOf(&app);
        defer rec.deinit();
        slot.* = rec.ops.items.len;
    }
    try testing.expectEqual(streams[0], streams[1]);
}

test "segmented: selected segment is an elevated paper chip on the dimmed track" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
        .selected = 1,
    } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var track_fills: usize = 0;
    var chip_fills: usize = 0;
    var chip_borders: usize = 0;
    for (rec.ops.items) |op| switch (op) {
        .fill_rect => |f| {
            if (f.gray == Gray.g11) track_fills += 1;
            if (f.gray == Gray.paper) chip_fills += 1;
        },
        .stroke_rect => |s| {
            if (s.gray == Gray.g6) chip_borders += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), track_fills);
    try testing.expectEqual(@as(usize, 1), chip_fills);
    try testing.expectEqual(@as(usize, 1), chip_borders);
    try testing.expect(rec.containsText("List"));
    try testing.expect(rec.containsText("Grid"));
}

test "segmented: an overflowing track clips its chips and shows an indicator" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    // 5 chips * 60px = 300 content in a 168px slot.
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });

    var rec = frameOf(&app);
    defer rec.deinit();

    const r = app.tree.rectOf(seg);
    // Overflowing at the root, the track declines the 16px margin and
    // bleeds to the viewport edges; the clip is the whole bled rect.
    try testing.expectEqual(@as(i32, 0), r.x);
    try testing.expectEqual(app.viewport.w, r.w);
    var clipped = false;
    var indicator: ?Rect = null;
    var chip: ?Rect = null;
    for (rec.ops.items) |op| switch (op) {
        .push_clip => |c| {
            if (c.y == r.y and c.h == r.h and c.x == r.x and c.w == r.w) clipped = true;
        },
        .fill_rect => |f| {
            // Untouched, the bar rests at the quiet tone.
            if (f.rect.h == 2 and f.gray == Gray.g8) indicator = f.rect;
            // The selected chip: paper, inside the track.
            if (f.gray == Gray.paper and f.rect.h < r.h) chip = f.rect;
        },
        else => {},
    };
    try testing.expect(clipped);
    // Scrolling costs height, not padding: the rect grows by the head
    // and the indicator's gutter, and the chip band inside it is what
    // it would be if the same track fit.
    try testing.expectEqual(
        text.Scale.body.lineHeight() + 2 * (layout.metrics.seg_pad_v + layout.metrics.seg_track_pad) +
            layout.metrics.seg_scroll_head + layout.metrics.seg_scroll_gutter,
        r.h,
    );
    try testing.expectEqual(r.y + layout.metrics.seg_scroll_head + layout.metrics.seg_track_pad, chip.?.y);
    try testing.expectEqual(text.Scale.body.lineHeight() + 2 * layout.metrics.seg_pad_v, chip.?.h);
    // Bar at the resting window's start (offset 0) — content margins,
    // not the bled edge — scaled to the visible share.
    const window = layout.segTrackWindow(r, app.tree.getConst(seg).?.segmented.bleed);
    const bar = indicator.?;
    try testing.expectEqual(window.x, bar.x);
    // In the gutter the overflowing track grew for it, inset by the
    // track pad so the same 2px sits below the bar as above the chips.
    try testing.expectEqual(r.bottom() - layout.metrics.seg_track_pad - 2, bar.y);
    try testing.expect(bar.w < window.w);

    // A horizontal scroll over the track engages its bar.
    try app.dispatch(.{ .scroll = .{ .at = r.center(), .delta_y = 0, .delta_x = 20 } });
    var engaged = frameOf(&app);
    defer engaged.deinit();
    var emphasized = false;
    var fills = engaged.opsOf(.fill_rect);
    while (fills.next()) |f| {
        if (f.rect.h == 2 and f.gray == Gray.g6) emphasized = true;
    }
    try testing.expect(emphasized);
}

test "scroll region indicator: quiet at rest, emphasized while engaged" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 108 } });
    for (0..6) |_| {
        try app.tree.append(sr, .{ .text = .{ .content = "line" } });
    }
    app.performLayout();
    const region_r = app.tree.rectOf(sr);

    const barGray = struct {
        fn of(rec: *const Recording, r: Rect) ?Gray {
            var fills = rec.opsOf(.fill_rect);
            while (fills.next()) |f| {
                if (f.rect.x == r.right() - 2 and f.rect.w == 2) return f.gray;
            }
            return null;
        }
    }.of;

    var rest = frameOf(&app);
    defer rest.deinit();
    try testing.expectEqual(Gray.g8, barGray(&rest, region_r).?);

    // Wheel over the region: its bar engages via the latch.
    try app.dispatch(.{ .scroll = .{ .at = region_r.center(), .delta_y = 20 } });
    var hot = frameOf(&app);
    defer hot.deinit();
    try testing.expectEqual(Gray.g6, barGray(&hot, region_r).?);

    // Tab focuses the region (the only tab stop): keys scroll it, so
    // focus alone keeps the bar engaged even after the latch clears.
    try app.dispatch(.{ .key_down = .{ .key = .tab, .mods = .{} } });
    try testing.expect(app.focused.?.on(sr));
    try testing.expect(app.scroll_hot == .none);
    var focused = frameOf(&app);
    defer focused.deinit();
    try testing.expectEqual(Gray.g6, barGray(&focused, region_r).?);
}

fn buildNavHome(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home" } });
}

test "sheet paints last over a paper dither scrim" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Behind" } });
    _ = try app.presentSheet("Options");

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const sheet_rect = app.tree.rectOf(layout.findSheet(&app.tree).?);
    var dither_index: ?usize = null;
    var sheet_fill_index: ?usize = null;
    for (rec.ops.items, 0..) |op, i| switch (op) {
        .dither => |d| {
            try testing.expectEqual(Gray.paper, d.gray);
            try testing.expectEqual(app.viewport.w, d.rect.w);
            try testing.expectEqual(app.viewport.h, d.rect.h);
            dither_index = i;
        },
        .fill_rect => |f| {
            if (f.rect.x == sheet_rect.x and f.rect.y == sheet_rect.y and f.gray == Gray.paper) {
                sheet_fill_index = i;
            }
        },
        else => {},
    };
    // Scrim covers the content, sheet covers the scrim.
    try testing.expect(dither_index.? < sheet_fill_index.?);
    try testing.expect(rec.containsText("Options"));
    try testing.expect(rec.containsText(element_mod.ChromeGlyph.dismiss.utf8()));
}

test "notice banner: pane chrome at the bottom carrying its controls" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .description = "Synced to disk.", .route = "home", .icon = .circle_check, .important = true });

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const banner = app.tree.rectOf(layout.findNotice(&app.tree).?);
    var band_fill = false;
    var outlined = false;
    for (rec.ops.items) |op| switch (op) {
        .fill_rect => |f| {
            // At full width the body overhangs the sides (the clip
            // drops the side borders), so match on coverage, not x.
            if (f.rect.x <= banner.x and f.rect.y == banner.y and f.gray == Gray.g11) band_fill = true;
        },
        .stroke_rect => |s| {
            if (s.rect.y == banner.y and s.gray == Gray.g6) outlined = true;
        },
        else => {},
    };
    try testing.expect(band_fill);
    try testing.expect(outlined);
    try testing.expect(rec.containsText("Saved"));
    try testing.expect(rec.containsText("Synced to disk."));
    try testing.expect(rec.containsText(element_mod.IconName.circle_check.utf8()));
    try testing.expect(rec.containsText(element_mod.ChromeGlyph.open.utf8()));
    try testing.expect(rec.containsText(element_mod.ChromeGlyph.minimize.utf8()));
    try testing.expect(rec.containsText(element_mod.ChromeGlyph.dismiss.utf8()));
}

test "notices pane paints over a scrim with a row per notice" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home" });
    app.notify(.{ .title = "Sync failed", .route = "home", .important = true });
    try app.openNoticesPane();

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const pane = app.tree.rectOf(layout.findNoticesPane(&app.tree).?);
    var dither_index: ?usize = null;
    var pane_fill_index: ?usize = null;
    for (rec.ops.items, 0..) |op, i| switch (op) {
        .dither => |d| {
            if (d.gray == Gray.paper) dither_index = i;
        },
        .fill_rect => |f| {
            if (f.rect.x == pane.x and f.rect.y == pane.y and f.gray == Gray.paper) pane_fill_index = i;
        },
        else => {},
    };
    try testing.expect(dither_index.? < pane_fill_index.?);
    try testing.expect(rec.containsText("Notices"));
    try testing.expect(rec.containsText(element_mod.ChromeGlyph.dismiss_all.utf8()));
    try testing.expect(rec.containsText("Saved"));
    try testing.expect(rec.containsText("Sync failed"));
    // Mixed importance: each group under its label.
    try testing.expect(rec.containsText("Important"));
    try testing.expect(rec.containsText("Other"));
}

test "the minimized indicator paints its glyph in the pane band" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home" });
    app.minimizeNotices();

    var rec = frameOf(&app);
    defer rec.deinit();

    try testing.expect(rec.containsText(element_mod.ChromeGlyph.expand.utf8()));
    try testing.expect(!rec.containsText("Saved"));
}

test "nav chrome paints after content, on plates, with no track under it" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 200 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildNavHome },
            .{ .name = "away", .title = .{ .fixed = "Away" }, .build = buildNavHome },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "away", .icon = .circle },
    });
    try app.navigate("home");

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const nav = layout.findNav(&app.tree).?;
    const nav_rect = app.tree.rectOf(nav);
    var items = app.tree.children(nav);
    const current_plate = layout.navItemPlate(app.tree.rectOf(items.next().?));
    const other_plate = layout.navItemPlate(app.tree.rectOf(items.next().?));
    var current_fill: ?usize = null;
    var other_plated = false;
    var heading_index: ?usize = null;
    var track = false;
    var current_edged = false;
    for (rec.ops.items, 0..) |op, i| {
        switch (op) {
            .fill_rect => |f| {
                if (sameRect(f.rect, current_plate) and f.gray == Gray.g10) current_fill = i;
                if (sameRect(f.rect, other_plate) and f.gray == Gray.g11) other_plated = true;
                // Anything spanning the bar's own rect is the track the
                // nav no longer has.
                if (f.rect.y == nav_rect.y and f.rect.w >= nav_rect.w) track = true;
            },
            .stroke_rect => |s| {
                if (s.gray == Gray.mid and sameRect(s.rect, current_plate)) current_edged = true;
            },
            .draw_text => |t| {
                if (std.mem.eql(u8, t.bytes, "Home") and t.baseline < nav_rect.y) heading_index = i;
            },
            else => {},
        }
    }
    // Three levels, not two: the page, the destinations on `.g11`, and
    // current one step above them on `.g10` with its own boundary.
    try testing.expect(current_edged);
    try testing.expect(current_fill.? > heading_index.?);
    // Every item is a plate, so a destination never reads as bare page
    // and the words never have the page scrolling through them.
    try testing.expect(other_plated);
    try testing.expect(!track);
}

fn sameRect(a: geometry.Rect, b: geometry.Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

test "the section menu is a card, not a pane bleeding through the safe band" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 375, .h = 420 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildNavHome },
            .{ .name = "away", .title = .{ .fixed = "Away" }, .build = buildNavHome },
            .{ .name = "far", .title = .{ .fixed = "Far" }, .build = buildNavHome },
            .{ .name = "further", .title = .{ .fixed = "Furthest of them all" }, .build = buildNavHome },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    app.setSafeBottom(34);
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "away", .icon = .circle },
        .{ .route = "far", .icon = .compass },
        .{ .route = "further", .icon = .user },
    });
    try app.navigate("home");
    app.performLayout();
    // The roster is too wide for a row here, so the nav is the chip —
    // and the chip is as wide as its words, not as wide as the nav.
    var nav_it = app.tree.children(layout.findNav(&app.tree).?);
    const chip = nav_it.next().?;
    try testing.expectEqual(element_mod.Role.nav_current, app.tree.getConst(chip).?.role());
    try app.tap(app.tree.rectOf(chip).center());

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const menu = app.tree.rectOf(layout.findPicker(&app.tree).?);
    var carded = false;
    var edged = false;
    var overhang = false;
    var clipped = false;
    for (rec.ops.items) |op| switch (op) {
        // The card's own rect, not the panes' rect-plus-safe-band: a
        // section name past the width cap stops at the edge.
        .push_clip => |c| if (sameRect(c, menu)) {
            clipped = true;
        },
        .fill_rect => |f| {
            if (sameRect(f.rect, menu) and f.gray == Gray.paper and f.radius == metrics.radius_card) carded = true;
            // The bottom-anchored panes fill past their own rect and let
            // a clip square the lower edge off. A card that floats has
            // no edge to hide anything behind, so nothing starting at
            // its top may finish below it — that overhang is the tail
            // that used to hang over the chip.
            if (f.rect.y == menu.y and f.rect.bottom() > menu.bottom()) overhang = true;
        },
        .stroke_rect => |s| {
            if (sameRect(s.rect, menu) and s.gray == Gray.g6) edged = true;
        },
        else => {},
    };
    try testing.expect(carded);
    try testing.expect(edged);
    try testing.expect(!overhang);
    try testing.expect(clipped);
    // The pane's title bar went with the pane; the chip below names it.
    try testing.expect(!rec.containsText("Sections"));
    try testing.expect(rec.containsText("Furthest of them all"));
}

test "a focused field takes over its outline instead of ringing it" {
    var app = try test_app.init(400, 200);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Name" } });

    // Unfocused: the g7 outline, one hairline.
    var rest = frameOf(&app);
    defer rest.deinit();
    const field = fieldRect(&app, input);
    try testing.expectEqual(@as(usize, 1), strokesOn(&rest, field));
    try testing.expectEqual(Gray.g7, strokeOn(&rest, field).?.gray);

    // Focused: still one stroke, on the same rect — heavier and in ink,
    // with no ring outside it. Two boundaries is what this replaced.
    app.focused = .of(input);
    var rec = frameOf(&app);
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 1), strokesOn(&rec, field));
    const edge = strokeOn(&rec, field).?;
    try testing.expectEqual(Gray.ink, edge.gray);
    try testing.expectEqual(metrics.focus_stroke, edge.thickness);
    try testing.expectEqual(@as(usize, 0), strokesOn(&rec, focusRingRect(field)));
}

test "a focused pill's ring keeps clear of the fill it rings" {
    var app = try test_app.init(400, 200);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save" } });
    app.focused = .of(btn);
    app.performLayout();

    var rec = frameOf(&app);
    defer rec.deinit();

    // The ring's inner edge and the fill's outer edge are two
    // anti-aliased arcs; touching, they leave a light seam at every
    // corner, so paper has to separate them.
    const r = app.tree.rectOf(btn);
    try testing.expect(metrics.focus_clear > 0);
    try testing.expectEqual(@as(usize, 0), strokesOn(&rec, r.inset(-metrics.focus_stroke)));
    try testing.expectEqual(@as(usize, 1), strokesOn(&rec, focusRingRect(r)));
}

test "a problem hangs below the outline and leaves the box exactly where it was" {
    var app = try test_app.init(400, 300);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Email" } });

    const before = fieldRect(&app, input);
    app.tree.get(input).?.text_input.problem = "That is not an email address.";
    app.layout_dirty = true;
    app.performLayout();

    var rec = frameOf(&app);
    defer rec.deinit();
    // The rect grew downward; the field itself did not move and did not
    // resize. A refused field looks exactly like the field it was, plus
    // the words saying why — the outline is left to focus, which is the
    // only state allowed to change it.
    const after = app.tree.rectOf(input);
    try testing.expect(after.h > before.h + text.Scale.small.lineHeight() - 1);
    try testing.expectEqual(@as(usize, 1), strokesOn(&rec, before));
    try testing.expectEqual(Gray.g7, strokeOn(&rec, before).?.gray);
    try testing.expect(rec.containsText("That is not an email address."));
}

fn fieldRect(app: *App, input: anytype) Rect {
    app.performLayout();
    const r = app.tree.rectOf(input);
    const label_h = text.Scale.small.lineHeight() + metrics.input_label_gap;
    return .{ .x = r.x, .y = r.y + label_h, .w = r.w, .h = r.h - label_h };
}

fn strokesOn(rec: *const Recording, r: Rect) usize {
    var n: usize = 0;
    for (rec.ops.items) |op| {
        if (op == .stroke_rect and std.meta.eql(op.stroke_rect.rect, r)) n += 1;
    }
    return n;
}

fn strokeOn(rec: *const Recording, r: Rect) ?@FieldType(Recording.Op, "stroke_rect") {
    for (rec.ops.items) |op| {
        if (op == .stroke_rect and std.meta.eql(op.stroke_rect.rect, r)) return op.stroke_rect;
    }
    return null;
}

test "focused nav item draws a hugging stroke, not the outset ring" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 200 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildNavHome },
            .{ .name = "away", .title = .{ .fixed = "Away" }, .build = buildNavHome },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "away", .icon = .circle },
    });
    try app.navigate("home");
    app.performLayout();
    const nav = layout.findNav(&app.tree).?;
    var items = app.tree.children(nav);
    const item = items.next().?;
    app.focused = .of(item);

    var rec = frameOf(&app);
    defer rec.deinit();

    // The stroke hugs the drawn plate, not the slot around it: the slot
    // stays flush with its neighbour so no tap falls between them, and
    // a ring on that edge would touch the item next door.
    const r = layout.navItemPlate(app.tree.rectOf(item));
    var found_hug = false;
    var found_outset = false;
    for (rec.ops.items) |op| switch (op) {
        .stroke_rect => |s| {
            if (std.meta.eql(s.rect, r) and s.thickness == metrics.focus_stroke and s.gray == Gray.ink) found_hug = true;
            if (std.meta.eql(s.rect, focusRingRect(r))) found_outset = true;
        },
        else => {},
    };
    try testing.expect(found_hug);
    try testing.expect(!found_outset);
}

test "spanned text draws one run per segment, faces and inks resolved" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "plain " },
        .{ .text = "bold ", .strong = true },
        .{ .text = "code", .code = true, .ink = .dark },
    } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var n: usize = 0;
    var x_prev: i32 = -1;
    var texts = rec.opsOf(.draw_text);
    while (texts.next()) |t| {
        switch (n) {
            0 => {
                try testing.expectEqualStrings("plain ", t.bytes);
                try testing.expectEqual(text.Face.prose, t.face);
                try testing.expectEqual(Gray.ink, t.gray);
            },
            1 => {
                try testing.expectEqualStrings("bold ", t.bytes);
                try testing.expectEqual(text.Face{ .family = .prose, .bold = true }, t.face);
            },
            2 => {
                try testing.expectEqualStrings("code", t.bytes);
                try testing.expectEqual(text.Face{ .family = .mono }, t.face);
                try testing.expectEqual(Gray.dark, t.gray);
            },
            else => {},
        }
        // The pen only ever advances; segments share one baseline row.
        try testing.expect(t.x > x_prev);
        x_prev = t.x;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
}

test "a spanned heading draws every run bold at the heading scale" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // Headings are bold at every level, so `strong` adds nothing here:
    // the plain run must not fall back to the regular face (Span.face
    // composes onto the element's base), and the italic run keeps the
    // weight while adding the slant.
    // Short enough to stay on one line, so each span is exactly one
    // draw call and the faces can be checked run by run.
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .level = .h1, .spans = &.{
        .{ .text = "Sync " },
        .{ .text = "failed", .strong = true },
        .{ .text = " now", .emphasis = true },
    } } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var n: usize = 0;
    var texts = rec.opsOf(.draw_text);
    while (texts.next()) |t| {
        try testing.expectEqual(@import("../core/text.zig").Scale.h1.px(), t.size_px);
        try testing.expect(t.face.bold);
        try testing.expectEqual(std.mem.eql(u8, t.bytes, " now"), t.face.italic);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
}

test "list markers are derived, right-aligned in their band, and mirror" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const list = try app.tree.appendId(app.tree.rootId(), .{ .list = .{ .ordered = true, .start = 9 } });
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const item = try app.tree.appendId(list, .{ .list_item = .{} });
        try app.tree.append(item, .{ .text = .{ .content = "Step" } });
    }

    var rec = frameOf(&app);
    defer rec.deinit();
    // Nobody authored these: the ordinals come from `start` and the
    // item's position.
    try testing.expect(rec.containsText("9."));
    try testing.expect(rec.containsText("10."));

    // The band is sized for "10." (3 codepoints, 27px); "9." is pushed
    // right inside it so both markers end on the same column, one gap
    // short of the words.
    var nine_x: i32 = 0;
    var ten_x: i32 = 0;
    var words_x: i32 = 0;
    var texts = rec.opsOf(.draw_text);
    while (texts.next()) |t| {
        if (std.mem.eql(u8, t.bytes, "9.")) nine_x = t.x;
        if (std.mem.eql(u8, t.bytes, "10.")) ten_x = t.x;
        if (std.mem.eql(u8, t.bytes, "Step")) words_x = t.x;
    }
    try testing.expectEqual(@as(i32, 16), ten_x);
    try testing.expectEqual(@as(i32, 16 + 9), nine_x); // one codepoint narrower
    try testing.expectEqual(@as(i32, 16 + 27 + metrics.list_marker_gap), words_x);

    // Mirrored, the band holds the right end and the marker hugs its
    // leading (right-hand) side, flush against the words again.
    app.setDirection(.rtl);
    rec.ops.clearRetainingCapacity();
    render(&app, rec.canvas());
    var mirrored_texts = rec.opsOf(.draw_text);
    while (mirrored_texts.next()) |t| {
        if (std.mem.eql(u8, t.bytes, "10.")) ten_x = t.x;
    }
    try testing.expectEqual(@as(i32, 400 - 16 - 27 - metrics.list_marker_gap), ten_x);
}

test "a code block draws one mono line per newline, unwrapped and clipped" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    // The second line is 60 codepoints (540px) in a 168px span, so the
    // block overflows and must clip rather than wrap.
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .code_block = .{
        .content = "short\n" ++ "e" ** 60,
    } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var lines: usize = 0;
    var ys: [2]i32 = undefined;
    var texts = rec.opsOf(.draw_text);
    while (texts.next()) |t| {
        try testing.expectEqual(text.Face.mono, t.face);
        // Both lines start at the same x: no wrapping, no re-indent.
        try testing.expectEqual(@as(i32, 16), t.x);
        if (lines < ys.len) ys[lines] = t.baseline;
        lines += 1;
    }
    try testing.expectEqual(@as(usize, 2), lines);
    try testing.expectEqual(text.Scale.body.lineHeight(), ys[1] - ys[0]);

    // Overflow clips at the bled rect and rides a 2px indicator, quiet
    // until the surface is engaged.
    const r = app.tree.rectOf(cb);
    try testing.expectEqual(@as(i32, 0), r.x); // bled through the root padding
    var clipped = false;
    var bar: ?Rect = null;
    for (rec.ops.items) |op| switch (op) {
        .push_clip => |c| if (std.meta.eql(c, r)) {
            clipped = true;
        },
        .fill_rect => |f| if (f.rect.h == 2) {
            bar = f.rect;
            try testing.expectEqual(Gray.g8, f.gray);
        },
        else => {},
    };
    try testing.expect(clipped);
    try testing.expect(bar != null);
    // The bar sits in the resting content span, not the bled rect, so
    // it keeps the page's margins.
    try testing.expectEqual(@as(i32, 16), bar.?.x);
}

test "a blockquote draws a leading rule the full height of what it quotes" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const quote = try app.tree.appendId(app.tree.rootId(), .{ .blockquote = .{} });
    try app.tree.append(quote, .{ .text = .{ .content = "One." } });
    try app.tree.append(quote, .{ .text = .{ .content = "Two." } });

    var rec = frameOf(&app);
    defer rec.deinit();
    const r = app.tree.rectOf(quote);

    var rule: ?Rect = null;
    var gray: Gray = .paper;
    for (rec.ops.items) |op| switch (op) {
        .fill_rect => |f| if (f.rect.w == metrics.border) {
            rule = f.rect;
            gray = f.gray;
        },
        else => {},
    };
    try testing.expect(rule != null);
    // Grouping, not state: the `.g10` tone box and tile_group use, and
    // it spans everything quoted, both lines included.
    try testing.expectEqual(Gray.g10, gray);
    try testing.expectEqual(r.x, rule.?.x);
    try testing.expectEqual(r.y, rule.?.y);
    try testing.expectEqual(r.h, rule.?.h);
    try testing.expect(r.h > text.Scale.body.lineHeight());

    // Mirrored, the rule holds the right edge — an explicit branch,
    // because a rule is an edge, not a centered block.
    app.setDirection(.rtl);
    rec.ops.clearRetainingCapacity();
    render(&app, rec.canvas());
    for (rec.ops.items) |op| switch (op) {
        .fill_rect => |f| if (f.rect.w == metrics.border) {
            rule = f.rect;
        },
        else => {},
    };
    try testing.expectEqual(app.tree.rectOf(quote).right() - metrics.border, rule.?.x);
}

test "an inline link underlines and rings every line it crosses" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    // Wraps after "and", so the link lands on two lines (see the
    // matching app_test for the arithmetic).
    const para = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "terms and conditions", .route = "terms" },
        .{ .text = " now." },
    } } });
    app.focused = .{ .node = para, .span = 1 };

    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    var buf: [wrap.max_span_rects]Rect = undefined;
    const rects = @import("../core/input.zig").spanRectsOf(&app, para, 1, &buf);
    try testing.expectEqual(@as(usize, 2), rects.len);

    // One ring per rect: a single box around their union would enclose
    // "Read the " and claim to be the link.
    var rings: usize = 0;
    for (rec.ops.items) |op| switch (op) {
        .stroke_rect => |s| {
            for (rects) |r| {
                // A link's ring is the one drawn flush around its
                // line box rather than held clear of it.
                if (std.meta.eql(s.rect, r.inset(-metrics.focus_stroke))) rings += 1;
            }
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), rings);

    // Underlines cover the link's ink on both lines and stop there:
    // the words before and after it are prose.
    var underlines: usize = 0;
    for (rec.ops.items) |op| switch (op) {
        .line => |l| {
            if (l.from.y != l.to.y) continue;
            underlines += 1;
            var inside = false;
            for (rects) |r| {
                if (l.from.x >= r.x and l.to.x <= r.right()) inside = true;
            }
            try testing.expect(inside);
        },
        else => {},
    };
    try testing.expect(underlines >= 2);
}

test "a struck span is ruled through its middle, and measures the same" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const struck = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Fees are " },
        .{ .text = "20", .strike = true },
        .{ .text = " 0 from May." },
    } } });
    // Strike is a drawn rule, not a face, so no bundled family needs a
    // struck variant and the run occupies exactly the width it would
    // without the mark.
    const plain = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .content = "Fees are 20 0 from May." } });
    app.performLayout();
    try testing.expectEqual(app.tree.rectOf(plain).h, app.tree.rectOf(struck).h);

    var rec = frameOf(&app);
    defer rec.deinit();

    var run_x: i32 = 0;
    var run_w: i32 = 0;
    var baseline: i32 = 0;
    for (rec.ops.items) |op| switch (op) {
        .draw_text => |t| if (std.mem.eql(u8, t.bytes, "20")) {
            run_x = t.x;
            run_w = app.measurer.measure(t.face, t.size_px, t.bytes);
            baseline = t.baseline;
        },
        else => {},
    };
    try testing.expect(run_w > 0);

    var rules: usize = 0;
    for (rec.ops.items) |op| switch (op) {
        .line => |l| {
            rules += 1;
            // Spans the struck run and nothing beside it, on a
            // horizontal line a quarter of the em above the baseline —
            // through the lowercase band, not under it.
            try testing.expectEqual(l.from.y, l.to.y);
            try testing.expectEqual(run_x, l.from.x);
            try testing.expectEqual(run_x + run_w, l.to.x);
            try testing.expectEqual(baseline - @divTrunc(text.Scale.body.px(), 4), l.from.y);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), rules);
}

test "RTL paragraph right-aligns and reorders around Latin" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // Logical order: Arabic first, then the acronym. Visually the Latin
    // run sits leftmost and the line hugs the right margin.
    const id = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .content = "سلام ABC" } });

    var rec = frameOf(&app);
    defer rec.deinit();
    const r = app.tree.rectOf(id);

    // Fixed measurer: 16px body → 9px per codepoint. 8 codepoints = 72.
    const cp: i32 = 9;
    var xs: [4]i32 = undefined;
    var bytes: [4][]const u8 = undefined;
    var n: usize = 0;
    for (rec.ops.items) |op| {
        if (op == .draw_text) {
            xs[n] = op.draw_text.x;
            bytes[n] = op.draw_text.bytes;
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("ABC", bytes[0]);
    try testing.expectEqualStrings("سلام ", bytes[1]);
    const line_w = 8 * cp;
    try testing.expectEqual(r.x + r.w - line_w, xs[0]);
    try testing.expectEqual(r.x + r.w - line_w + 3 * cp, xs[1]);
}

test "paragraph direction is per hard paragraph within one element" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const id = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .content = "Hello world\nسلام دنیا" } });

    var rec = frameOf(&app);
    defer rec.deinit();
    const r = app.tree.rectOf(id);

    var latin_x: ?i32 = null;
    var arabic_x: ?i32 = null;
    for (rec.ops.items) |op| {
        if (op != .draw_text) continue;
        if (std.mem.eql(u8, op.draw_text.bytes, "Hello world")) latin_x = op.draw_text.x;
        if (std.mem.eql(u8, op.draw_text.bytes, "سلام دنیا")) arabic_x = op.draw_text.x;
    }
    // The English paragraph keeps the left margin; the Persian one
    // derives right alignment from its direction (9 codepoints × 9px).
    try testing.expectEqual(r.x, latin_x.?);
    try testing.expectEqual(r.x + r.w - 9 * 9, arabic_x.?);
}

test "labels reorder through the painter without their draw site knowing" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "سلام ABC" } });

    var rec = frameOf(&app);
    defer rec.deinit();

    var abc_x: ?i32 = null;
    var arabic_x: ?i32 = null;
    for (rec.ops.items) |op| {
        if (op != .draw_text) continue;
        if (std.mem.eql(u8, op.draw_text.bytes, "ABC")) abc_x = op.draw_text.x;
        if (std.mem.startsWith(u8, op.draw_text.bytes, "سلام")) arabic_x = op.draw_text.x;
    }
    try testing.expect(abc_x.? < arabic_x.?);
}

test "RTL input value right-aligns; caret maps visually" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "نام" } });
    app.focused = .of(input);
    try app.dispatch(.{ .text = .{ .bytes = "سلام" } });

    // Cursor sits at the logical end after typing; visually that is the
    // *left* edge of a right-aligned RTL value.
    var rec = frameOf(&app);
    defer rec.deinit();

    var value_x: ?i32 = null;
    for (rec.ops.items) |op| {
        if (op == .draw_text and std.mem.eql(u8, op.draw_text.bytes, "سلام")) value_x = op.draw_text.x;
    }
    const caret_end = caretLineX(&rec).?;
    try testing.expectEqual(value_x.?, caret_end);

    // Home moves to logical 0 — the right edge (4 codepoints × 9px).
    try app.dispatch(.{ .key_down = .{ .key = .home } });
    var rec2 = frameOf(&app);
    defer rec2.deinit();
    try testing.expectEqual(value_x.? + 4 * 9, caretLineX(&rec2).?);
}

fn caretLineX(rec: *const Recording) ?i32 {
    // The caret is the only vertical 1px line inside the field.
    for (rec.ops.items) |op| {
        if (op == .line and op.line.from.x == op.line.to.x and op.line.thickness == 1) return op.line.from.x;
    }
    return null;
}

// ---- RTL chrome mirroring --------------------------------------------------

fn textX(rec: *const Recording, needle: []const u8) ?i32 {
    for (rec.ops.items) |op| {
        if (op == .draw_text and std.mem.eql(u8, op.draw_text.bytes, needle)) return op.draw_text.x;
    }
    return null;
}

test "rtl: the select chevron draws at the leading (left) edge" {
    var ltr = try test_app.init(400, 400);
    defer ltr.deinit();
    try ltr.tree.append(ltr.tree.rootId(), .{ .select = .{ .label = "Language", .options = &.{ "English", "Deutsch" } } });
    var rtl = try test_app.mirrored(400, 400);
    defer rtl.deinit();
    try rtl.tree.append(rtl.tree.rootId(), .{ .select = .{ .label = "Language", .options = &.{ "English", "Deutsch" } } });

    var lrec = frameOf(&ltr);
    defer lrec.deinit();
    var rrec = frameOf(&rtl);
    defer rrec.deinit();

    const chevron = element_mod.select_chevron;
    // The affordance sits at the trailing edge: right in LTR, left when
    // mirrored — so the RTL chevron is well left of the LTR one.
    try testing.expect(textX(&rrec, chevron).? < textX(&lrec, chevron).?);
    // ...and the selected value now hugs the right instead of the left.
    try testing.expect(textX(&rrec, "English").? > textX(&lrec, "English").?);
}

test "rtl: the toggle track sits at the trailing edge, label leads" {
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const tog = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{ .label = "Wifi" } });
    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(tog);
    // The 36×20 track (a g11 fill) ends at the toggle's right edge.
    var track_right: ?i32 = null;
    var fills = rec.opsOf(.fill_rect);
    while (fills.next()) |f| {
        if (f.rect.w == metrics.toggle_track_w and f.gray == .g11) {
            track_right = f.rect.x + f.rect.w;
        }
    }
    try testing.expectEqual(r.right(), track_right.?);
    // The label draws at the leading (left) edge, before the track.
    try testing.expectEqual(r.x, textX(&rec, "Wifi").?);
}

test "rtl: the root scroll indicator hugs the left edge" {
    var app = try test_app.mirrored(200, 100);
    defer app.deinit();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
    var rec = frameOf(&app);
    defer rec.deinit();

    // The 2px overlay bar rides x=0 in RTL (it is x=198 in LTR).
    var found = false;
    var fills = rec.opsOf(.fill_rect);
    while (fills.next()) |f| {
        if (f.rect.x == 0 and f.rect.w == 2) found = true;
    }
    try testing.expect(found);
}

/// The gray a run was drawn in, or null if it was never drawn.
fn textGray(rec: *const Recording, needle: []const u8) ?Gray {
    for (rec.ops.items) |op| {
        switch (op) {
            .draw_text => |t| if (std.mem.eql(u8, t.bytes, needle)) return t.gray,
            else => {},
        }
    }
    return null;
}

test "an armed back gesture swaps the chevron for the arrow, and nothing else" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const back = try app.tree.appendId(app.tree.rootId(), .{ .back = .{} });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Detail" } });

    var resting = frameOf(&app);
    defer resting.deinit();
    app.performLayout();
    const r = app.tree.rectOf(back);
    try testing.expect(resting.containsText(element_mod.back_chevron));
    try testing.expect(!resting.containsText(element_mod.back_arrow));

    app.back_gesture = .{ .armed = true };
    var armed = frameOf(&app);
    defer armed.deinit();
    try testing.expect(armed.containsText(element_mod.back_arrow));
    try testing.expect(!armed.containsText(element_mod.back_chevron));
    // The mark carries the state alone: still `ink`, still the same slot,
    // and no ground appears under it. A ground would be the one painted
    // edge on the screen outside the text column — the target hangs into
    // the page margin so the *glyph* can line up (layout's `layoutRow`).
    try testing.expectEqual(Gray.ink, textGray(&armed, element_mod.back_arrow).?);
    var fills = armed.opsOf(.fill_rect);
    while (fills.next()) |f| {
        try testing.expect(!f.rect.contains(r.center()));
    }
}

test "rtl: both of the back control's marks mirror with the chrome" {
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .back = .{} });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "جزئیات" } });

    var resting = frameOf(&app);
    defer resting.deinit();
    try testing.expect(resting.containsText(element_mod.back_chevron_rtl));

    app.back_gesture = .{ .armed = true };
    var armed = frameOf(&app);
    defer armed.deinit();
    try testing.expect(armed.containsText(element_mod.back_arrow_rtl));
    try testing.expect(!armed.containsText(element_mod.back_arrow));
}

test "rtl: a navigating tile's chevron mirrors to the left and points back" {
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Account", .route = "account" } });
    var rec = frameOf(&app);
    defer rec.deinit();

    app.performLayout();
    const r = app.tree.rectOf(group);
    // The chevron points the RTL way (chevron-left) and sits at the
    // trailing (left) edge; the label hugs the right.
    const cx = textX(&rec, element_mod.tile_chevron_rtl).?;
    try testing.expect(cx < r.x + @divTrunc(r.w, 2));
    try testing.expect(textX(&rec, "Account").? > cx);
}

test "an overflowing button row draws three buttons and the control, not the rest" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "One", "Two", "Three", "Four", "Five" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }

    var rec = frameOf(&app);
    defer rec.deinit();

    try testing.expect(rec.containsText("Three"));
    // Folded is not dimmed or clipped — it is not drawn at all.
    try testing.expect(!rec.containsText("Four"));
    try testing.expect(!rec.containsText("Five"));
    try testing.expect(rec.containsText("More"));

    // Drawn as the outlined pill its neighbors wear: the state edge, no
    // fill of its own, at the row's trailing end.
    var more: ?Rect = null;
    var it = app.tree.children(row);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.* == .more) more = app.tree.rectOf(c);
    }
    var outlined = false;
    var filled = false;
    for (rec.ops.items) |op| switch (op) {
        .stroke_rect => |s| {
            if (std.meta.eql(s.rect, more.?)) outlined = true;
        },
        .fill_rect => |f| {
            if (std.meta.eql(f.rect, more.?)) filled = true;
        },
        else => {},
    };
    try testing.expect(outlined);
    try testing.expect(!filled);
}
