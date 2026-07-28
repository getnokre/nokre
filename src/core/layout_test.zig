//! Tests for layout.zig: word wrap, block flow, chrome panes, and the
//! WCAG 2.5.8 target-size proof.

const std = @import("std");
const geometry = @import("geometry.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");
const element = @import("element.zig");

const testing = std.testing;
const Rect = geometry.Rect;
const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const compute = layout.compute;
const metrics = layout.metrics;
const navBarHeight = layout.navBarHeight;
const qrSide = layout.qrSide;
const radioRowY = layout.radioRowY;
const wrap = layout.wrap;

fn collectLines(content: []const u8, max_w: i32, out: [][]const u8) usize {
    var it = wrap(text.Measurer.fixed, .prose, 10, content, max_w);
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) out[n] = line;
    return n;
}

// Fixed measurer at size 10 → every codepoint is 6px wide.

test "wrap: fits on one line" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("hello world", 100, &lines);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("hello world", lines[0]);
}

test "wrap: breaks at word boundary" {
    var lines: [8][]const u8 = undefined;
    // 60px = 10 chars. "hello world" = 11 chars.
    const n = collectLines("hello world", 60, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("hello", lines[0]);
    try testing.expectEqualStrings("world", lines[1]);
}

test "wrap: hard newline" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("a\nb", 600, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("b", lines[1]);
}

test "wrap: trailing newline yields an empty final line" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("a\n", 600, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("", lines[1]);
    // A trailing space is hanging whitespace, not a new line.
    try testing.expectEqual(@as(usize, 1), collectLines("a ", 600, &lines));
}

test "wrap: over-long word overflows without splitting" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("abcdefghijkl x", 30, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("abcdefghijkl", lines[0]);
    try testing.expectEqualStrings("x", lines[1]);
}

test "wrap: empty content yields one empty line" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("", 100, &lines);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("", lines[0]);
}

// A measurer whose bold face is visibly wider (10px vs 6px per
// codepoint): wide enough apart to prove wrapping consults each span's
// face rather than the base one.
fn variantMeasure(_: ?*anyopaque, face: text.Face, _: i32, bytes: []const u8) i32 {
    var n: i32 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (it.nextCodepoint()) |_| n += 1;
    return n * @as(i32, if (face.bold) 10 else 6);
}
const variant_measurer: text.Measurer = .{ .measureFn = variantMeasure };

test "spans: segments split a byte range at span boundaries" {
    const content = "abcdef";
    const spans = [_]element.Span{
        .{ .text = content[0..3] },
        .{ .text = content[3..], .strong = true },
    };
    var it = layout.segments(content, &spans, 1, 5);
    const first = it.next().?;
    try testing.expectEqualStrings("bc", first.bytes);
    try testing.expect(!first.span.strong);
    const second = it.next().?;
    try testing.expectEqualStrings("de", second.bytes);
    try testing.expect(second.span.strong);
    try testing.expect(it.next() == null);
}

test "spans: wrap breaks with each span's face widths" {
    const content = "aaa bbb";
    const spans = [_]element.Span{
        .{ .text = content[0..4] },
        .{ .text = content[4..], .strong = true },
    };
    // Regular widths alone would fit the line — prove the premise first.
    var plain = layout.wrap(variant_measurer, .prose, 10, content, 45);
    try testing.expectEqualStrings("aaa bbb", plain.next().?);
    // The bold run's real width forces the break.
    var it = layout.wrapSpans(variant_measurer, .prose, 10, content, &spans, 45);
    try testing.expectEqualStrings("aaa", it.next().?);
    try testing.expectEqualStrings("bbb", it.next().?);
    try testing.expect(it.next() == null);
}

test "spans: a word crossing a span boundary stays unbreakable" {
    const content = "aabb cc";
    const spans = [_]element.Span{
        .{ .text = content[0..2] },
        .{ .text = content[2..], .strong = true },
    };
    // "aabb" (12 + 20 = 32px) exceeds 20px: it overflows whole, never
    // splitting at the style boundary inside it.
    var it = layout.wrapSpans(variant_measurer, .prose, 10, content, &spans, 20);
    try testing.expectEqualStrings("aabb", it.next().?);
    try testing.expectEqualStrings("cc", it.next().?);
    try testing.expect(it.next() == null);
}

test "spans: spanTextWidth sums per-face widths" {
    const content = "aabb";
    const spans = [_]element.Span{
        .{ .text = content[0..2] },
        .{ .text = content[2..], .strong = true },
    };
    try testing.expectEqual(@as(i32, 32), layout.spanTextWidth(variant_measurer, .prose, 10, &spans));
}

test "layout: spanned text takes full width at the wrapped height" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const t = try tree.append(tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "hello " },
        .{ .text = "world", .strong = true },
    } } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });
    const r = tree.rectOf(t);
    try testing.expectEqual(@as(i32, 400 - 2 * 16), r.w);
    try testing.expectEqual(text.Scale.body.lineHeight(), r.h);
}

test "layout: vertical flow stacks children with gap" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // Root stack has padding 16, gap 8.
    const a = try tree.append(tree.rootId(), .{ .text = .{ .content = "a" } });
    const b = try tree.append(tree.rootId(), .{ .text = .{ .content = "b" } });

    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const ra = tree.rectOf(a);
    const rb = tree.rectOf(b);
    try testing.expectEqual(@as(i32, 16), ra.x);
    try testing.expectEqual(@as(i32, 16), ra.y);
    try testing.expectEqual(@as(i32, 400 - 32), ra.w);
    try testing.expectEqual(@as(i32, 24), ra.h); // body line height
    try testing.expectEqual(@as(i32, ra.bottom() + 8), rb.y);
}

test "layout: text wraps and grows in height" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const t = try tree.append(tree.rootId(), .{ .text = .{ .content = "aaaa bbbb cccc dddd" } });

    // Inner width 100px; fixed measurer at body(16px) → 9px/char.
    // "aaaa bbbb" = 9 chars = 81px fits; three lines? "aaaa bbbb"(81) fits,
    // "cccc dddd"(81) fits → 2 lines.
    compute(&tree, text.Measurer.fixed, .{ .w = 132, .h = 800 });
    try testing.expectEqual(@as(i32, 48), tree.rectOf(t).h);
}

test "layout: identical inputs produce identical rects" {
    var results: [2]Rect = undefined;
    for (&results) |*slot| {
        var tree = try Tree.init(testing.allocator);
        defer tree.deinit();
        const box = try tree.append(tree.rootId(), .{ .box = .{} });
        _ = try tree.append(box, .{ .button = .{ .label = "Press" } });
        _ = try tree.append(tree.rootId(), .{ .divider = .{} });
        compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
        slot.* = tree.rectOf(box);
    }
    try testing.expectEqual(results[0], results[1]);
}

test "layout: a box in a row hugs its content; in flow it still stretches" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try tree.append(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 0 } });
    var boxes: [3]NodeId = undefined;
    for (&boxes) |*slot| {
        slot.* = try tree.append(row, .{ .box = .{ .border = false, .padding = 6 } });
        _ = try tree.append(slot.*, .{ .text = .{ .content = "ab", .style = .{ .scale = .small } } });
    }
    const stretched = try tree.append(tree.rootId(), .{ .box = .{ .border = false, .padding = 6 } });
    _ = try tree.append(stretched, .{ .text = .{ .content = "ab", .style = .{ .scale = .small } } });

    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    // Fixed measurer at small(12px) → 7px/char: 2 chars + 2*6 padding.
    const w = 2 * 7 + 2 * 6;
    var x: i32 = 16; // root padding
    for (boxes) |id| {
        const r = tree.rectOf(id);
        try testing.expectEqual(x, r.x);
        try testing.expectEqual(w, r.w);
        try testing.expectEqual(text.Scale.small.lineHeight() + 2 * 6, r.h);
        x += w;
    }
    // Whole ramp inside the content width, not two boxes and a cliff.
    try testing.expect(x <= 400 - 16);
    try testing.expectEqual(@as(i32, 400 - 32), tree.rectOf(stretched).w);
}

test "layout: button takes intrinsic width, not full width" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const btn = try tree.append(tree.rootId(), .{ .button = .{ .label = "OK" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(btn);
    // 2 chars * 9px + 2*(16+1) = 18 + 34 = 52
    try testing.expectEqual(@as(i32, 52), r.w);
    try testing.expectEqual(@as(i32, 24 + 2 * 6), r.h);
}

test "layout: glyph-form button is the bare touch-target square" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const btn = try tree.append(tree.rootId(), .{ .button = .{ .label = "Next cycle", .icon = .chevron_right, .icon_only = true } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(btn);
    try testing.expectEqual(@as(i32, metrics.touch_target), r.w);
    try testing.expectEqual(@as(i32, metrics.touch_target), r.h);
}

test "layout: a pill with an icon grows by the glyph and its gap" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const plain = try tree.append(tree.rootId(), .{ .button = .{ .label = "OK" } });
    const iconed = try tree.append(tree.rootId(), .{ .button = .{ .label = "OK", .icon = .alarm_clock_plus } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    // Fixed measurer: one glyph codepoint at body(16px) is 9px wide.
    try testing.expectEqual(tree.rectOf(plain).w + 9 + metrics.icon_gap, tree.rectOf(iconed).w);
    try testing.expectEqual(tree.rectOf(plain).h, tree.rectOf(iconed).h);
}

test "layout: scroll region clamps to fixed height and records content" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const sr = try tree.append(tree.rootId(), .{ .scroll_region = .{ .height = 50 } });
    _ = try tree.append(sr, .{ .text = .{ .content = "one" } });
    _ = try tree.append(sr, .{ .text = .{ .content = "two" } });
    _ = try tree.append(sr, .{ .text = .{ .content = "three" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    try testing.expectEqual(@as(i32, 50), tree.rectOf(sr).h);
    const el = tree.getConst(sr).?;
    try testing.expectEqual(@as(i32, 3 * 24 + 2 * 8), el.scroll_region.content_height);
}

test "layout: fill scroll region extends to the viewport bottom" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    _ = try tree.append(tree.rootId(), .{ .heading = .{ .content = "Title" } });
    const sr = try tree.append(tree.rootId(), .{ .scroll_region = .{} });
    _ = try tree.append(sr, .{ .text = .{ .content = "row" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });

    // Fills to the viewport bottom minus the root stack's padding.
    try testing.expectEqual(@as(i32, 600 - 16), tree.rectOf(sr).bottom());
}

test "layout: stale scroll offset is clamped during layout" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const sr = try tree.append(tree.rootId(), .{ .scroll_region = .{ .height = 50, .offset = 10000 } });
    _ = try tree.append(sr, .{ .text = .{ .content = "one" } });
    _ = try tree.append(sr, .{ .text = .{ .content = "two" } });
    _ = try tree.append(sr, .{ .text = .{ .content = "three" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const el = tree.getConst(sr).?;
    try testing.expectEqual(el.scroll_region.content_height - 50, el.scroll_region.offset);
}

test "layout: table columns align across rows" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const tbl = try tree.append(tree.rootId(), .{ .table = .{} });
    const r1 = try tree.append(tbl, .{ .row = .{ .header = true } });
    const c11 = try tree.append(r1, .{ .cell = .{} });
    _ = try tree.append(c11, .{ .text = .{ .content = "Name" } });
    const c12 = try tree.append(r1, .{ .cell = .{} });
    _ = try tree.append(c12, .{ .text = .{ .content = "Qty" } });
    const r2 = try tree.append(tbl, .{ .row = .{} });
    const c21 = try tree.append(r2, .{ .cell = .{} });
    _ = try tree.append(c21, .{ .text = .{ .content = "Blueberries" } });
    const c22 = try tree.append(r2, .{ .cell = .{} });
    _ = try tree.append(c22, .{ .text = .{ .content = "2" } });

    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });

    try testing.expectEqual(tree.rectOf(c11).x, tree.rectOf(c21).x);
    try testing.expectEqual(tree.rectOf(c12).x, tree.rectOf(c22).x);
    try testing.expectEqual(tree.rectOf(c11).w, tree.rectOf(c21).w);
}

test "layout: a table wider than the viewport reports its real width" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const tbl = try tree.append(tree.rootId(), .{ .table = .{} });
    const row = try tree.append(tbl, .{ .row = .{} });
    const a = try tree.append(row, .{ .cell = .{} });
    _ = try tree.append(a, .{ .text = .{ .content = "aaaaaaaaaaaaaaaaaaaaaaaa" } });
    const b = try tree.append(row, .{ .cell = .{} });
    _ = try tree.append(b, .{ .text = .{ .content = "bbbbbbbbbbbbbbbbbbbbbbbb" } });

    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    // The rect tells the truth: cells are laid at their intrinsic
    // column widths, so a rect clamped to the viewport would claim a
    // fit while the trailing column rendered past it — and hit testing,
    // focus reveal, and the a11y snapshot all read this rect.
    const r = tree.rectOf(tbl);
    try testing.expect(r.w > 200);
    try testing.expectEqual(r.w, tree.rectOf(row).w);
    // The trailing cell stands in its real column, off-screen included.
    try testing.expectEqual(tree.rectOf(a).right() + metrics.border, tree.rectOf(b).x);
    try testing.expectEqual(
        metrics.border + tree.rectOf(a).w + metrics.border + tree.rectOf(b).w + metrics.border,
        r.w,
    );
}

fn appendNav(tree: *Tree) !NodeId {
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });
    _ = try tree.append(nav, .{ .nav_item = .{ .label = "Home", .route = "home", .icon = .house } });
    _ = try tree.append(nav, .{ .nav_item = .{ .label = "Settings", .route = "settings", .icon = .settings } });
    return nav;
}

test "layout: segmented takes intrinsic width" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const seg = try tree.append(tree.rootId(), .{ .segmented = .{ .label = "View", .options = &.{ "List", "Grid" } } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(seg);
    // 2*2 track pad + 2 options * (4 chars * 9px + 2*12 pad) = 4 + 2*60
    try testing.expectEqual(@as(i32, 124), r.w);
    try testing.expectEqual(@as(i32, 24 + 2 * (4 + 2)), r.h);
    // Fitting, it takes the advised margin like any block.
    try testing.expectEqual(@as(i32, 16), r.x);
    try testing.expectEqual(@as(i32, 0), tree.get(seg).?.segmented.bleed);
}

test "layout: overflowing segmented reveals the selection once, then only clamps" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // 5 chips * (4 chars * 9px + 2*12 pad) = 300 content in a 168px slot
    // (164 inside the track pads).
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try tree.append(tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts, .selected = 4 } });
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    // Overflowing, the track declines the root stack's 16px margin and
    // bleeds to the viewport edges; the resting window stays the
    // content span (164 wide), so the offset space is unchanged.
    try testing.expectEqual(@as(i32, 0), tree.rectOf(seg).x);
    try testing.expectEqual(@as(i32, 200), tree.rectOf(seg).w);
    try testing.expectEqual(@as(i32, 16), tree.get(seg).?.segmented.bleed);
    // The -1 sentinel reveals: last chip (content 240..300) at max
    // offset, 300 - 164.
    try testing.expectEqual(@as(i32, 136), tree.get(seg).?.segmented.offset);

    // Scroll state survives relayout — no snap back to the selection...
    tree.get(seg).?.segmented.offset = 50;
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });
    try testing.expectEqual(@as(i32, 50), tree.get(seg).?.segmented.offset);

    // ...but never past the track's bounds.
    tree.get(seg).?.segmented.offset = 500;
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });
    try testing.expectEqual(@as(i32, 136), tree.get(seg).?.segmented.offset);
}

test "layout: an overflowing segmented bleeds only to the nearest drawn edge" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // A box's border is law: the same 300px track inside one keeps the
    // box's content span instead of reaching the screen.
    const box = try tree.append(tree.rootId(), .{ .box = .{} });
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try tree.append(box, .{ .segmented = .{ .label = "K", .options = opts } });
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    // Root pad 16 + box pad 12 + border 1: content span 29..171.
    try testing.expectEqual(@as(i32, 29), tree.rectOf(seg).x);
    try testing.expectEqual(@as(i32, 142), tree.rectOf(seg).w);
    try testing.expectEqual(@as(i32, 0), tree.get(seg).?.segmented.bleed);
}

// ---- the folded tail of a row of actions ------------------------------------

/// Five buttons, 373px of row in a 368px span — over by five, which is
/// the interesting amount: the row overflows by less than a button, so
/// only the deliberate extra fold (see `foldButtonRow`) puts more than
/// one name in the sheet.
fn buildButtonRow(tree: *Tree, gap: i32) !NodeId {
    const row = try tree.append(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = gap } });
    for ([_][]const u8{ "One", "Two", "Three", "Four", "Five" }) |label| {
        _ = try tree.append(row, .{ .button = .{ .label = label } });
    }
    return row;
}

fn foldedLabels(tree: *const Tree, row: NodeId, out: [][]const u8) usize {
    var n: usize = 0;
    var it = tree.children(row);
    while (it.next()) |c| {
        const el = tree.getConst(c).?;
        if (el.isFolded()) {
            out[n] = el.label();
            n += 1;
        }
    }
    return n;
}

test "layout: an overflowing row folds its tail, one action deeper than the overflow" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try buildButtonRow(&tree, 8);
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 480 });

    // 9px per codepoint at the body scale, plus 2*(16 pad + 1 border):
    // "One"/"Two" 61, "Three" 79, "Four"/"Five" 70. Four of them fit the
    // 368px span (295 through "Four"); the fifth takes it to 373.
    var folded: [5][]const u8 = undefined;
    const n = foldedLabels(&tree, row, &folded);
    // "Four" was completely visible and gives up its slot anyway — the
    // control must not stand where the clipping was.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Four", folded[0]);
    try testing.expectEqualStrings("Five", folded[1]);
    // Folded is off the row entirely: no slot, nothing to hit or draw.
    var it = tree.children(row);
    var x: i32 = 16;
    while (it.next()) |c| {
        const el = tree.getConst(c).?;
        const r = tree.rectOf(c);
        if (el.button.folded) {
            try testing.expectEqual(Rect.zero, r);
            continue;
        }
        try testing.expectEqual(x, r.x);
        x += r.w + 8;
    }
    // The three that stayed leave room for the control beside them.
    try testing.expect(x - 16 + layout.moreSize(text.Measurer.fixed).w <= 368);
}

test "layout: the folded tail's control stands where the first folded button did" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try buildButtonRow(&tree, 8);
    // What `overflow.syncOverflowChrome` appends after the first pass;
    // layout reserved its width before it existed either way.
    const more = try tree.append(row, .{ .more = .{} });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 480 });

    const size = layout.moreSize(text.Measurer.fixed);
    // 16 root pad + "One" 61 + 8 + "Two" 61 + 8 + "Three" 79 + 8.
    try testing.expectEqual(@as(i32, 241), tree.rectOf(more).x);
    try testing.expectEqual(size.w, tree.rectOf(more).w);
    try testing.expectEqual(size.h, tree.rectOf(more).h);
    // The row's own height is a button's: the control is one of them.
    try testing.expectEqual(size.h, tree.rectOf(row).h);
}

test "layout rtl: the folded tail keeps the row's leading three and its trailing control" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try buildButtonRow(&tree, 8);
    const more = try tree.append(row, .{ .more = .{} });
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, .{ .w = 400, .h = 480 }, 0, 0, .rtl);

    // Mirrored, document order runs right-to-left: "One" holds the
    // right end and the row grows leftward, so the control ends up at
    // 400 - 328 — the LTR row (241..328) reflected exactly.
    var it = tree.children(row);
    const first = tree.rectOf(it.next().?);
    try testing.expectEqual(@as(i32, 400 - 16), first.right());
    try testing.expectEqual(@as(i32, 72), tree.rectOf(more).x);
    try testing.expectEqual(@as(i32, 159), tree.rectOf(more).right());
}

test "layout: a mixed row and a lone button never fold" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // Words beside the buttons: two arrows with a month between them is
    // a pager, not a menu, and there is no sheet the framework can fold
    // a paragraph into. The row stays as it was.
    const mixed = try tree.append(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    _ = try tree.append(mixed, .{ .text = .{ .content = "Ready to publish?" } });
    for ([_][]const u8{ "Publish", "Save draft", "Discard" }) |label| {
        _ = try tree.append(mixed, .{ .button = .{ .label = label } });
    }
    // One button too wide for the row is not a row: folding it would
    // hide the only action behind a control named for having more.
    const lone = try tree.append(tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    _ = try tree.append(lone, .{ .button = .{ .label = "A very long single action indeed" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 300, .h = 480 });

    var folded: [5][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), foldedLabels(&tree, mixed, &folded));
    try testing.expectEqual(@as(usize, 0), foldedLabels(&tree, lone, &folded));
}

test "layout: a link among the buttons is one of the actions, not a disqualifier" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // The shape a real screen has: actions, one of which goes somewhere
    // instead of doing something. It folds like the rest.
    const row = try tree.append(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Save", "Cancel", "Add reminder", "Disabled" }) |label| {
        _ = try tree.append(row, .{ .button = .{ .label = label } });
    }
    const link = try tree.append(row, .{ .link = .{ .label = "More details", .route = "details" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 480, .h = 480 });

    var folded: [5][]const u8 = undefined;
    const n = foldedLabels(&tree, row, &folded);
    try testing.expect(n > 0);
    // The trailing link is the far end of the row, so it is folded and
    // its rect is gone with the rest.
    try testing.expect(tree.getConst(link).?.link.folded);
    try testing.expectEqual(Rect.zero, tree.rectOf(link));
}

test "layout: a row narrower than the control itself keeps nothing standing" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try buildButtonRow(&tree, 8);
    compute(&tree, text.Measurer.fixed, .{ .w = 120, .h = 480 });

    // 88px of span: the first button alone overflows it, so every one of
    // them is in the sheet and the control is the whole row.
    var folded: [5][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 5), foldedLabels(&tree, row, &folded));
}

test "layout: borderless stacks pass the margin advice through, accumulated" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const stack = try tree.append(tree.rootId(), .{ .stack = .{ .padding = 8 } });
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try tree.append(stack, .{ .segmented = .{ .label = "K", .options = opts } });
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    // No edge between the track and the screen: root 16 + stack 8
    // advise 24, and the overflowing track declines all of it.
    try testing.expectEqual(@as(i32, 0), tree.rectOf(seg).x);
    try testing.expectEqual(@as(i32, 200), tree.rectOf(seg).w);
    try testing.expectEqual(@as(i32, 24), tree.get(seg).?.segmented.bleed);
}

test "layout: a back control's row consumes the margin advice" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // The back control occupies the leading band, so the shared row's
    // track has no clear path to the edge and must not bleed over it.
    _ = try tree.append(tree.rootId(), .{ .back = .{} });
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try tree.append(tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    // Indented past the 44px control and its 8px gap, less the 10px it
    // hangs into the margin: 16 + 42.
    try testing.expectEqual(@as(i32, 58), tree.rectOf(seg).x);
    try testing.expectEqual(@as(i32, 126), tree.rectOf(seg).w);
    try testing.expectEqual(@as(i32, 0), tree.get(seg).?.segmented.bleed);
}

test "layout: a back control's row is handed down into a document" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // A screen written as one `document` draws nothing and pads nothing,
    // so the control marks the heading the document parsed rather than
    // the document itself: the prose under it keeps the page margin
    // every other screen starts at.
    const back = try tree.append(tree.rootId(), .{ .back = .{} });
    const doc = try tree.append(tree.rootId(), .{ .document = .{
        .label = "Terms",
        .source = "## Terms\n\nBody text.\n",
    } });
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    var it = tree.children(doc);
    const heading = it.next().?;
    const body = it.next().?;
    try testing.expectEqual(@as(i32, 16), tree.rectOf(doc).x);
    try testing.expectEqual(@as(i32, 16 + 42), tree.rectOf(heading).x); // the shared row
    try testing.expectEqual(@as(i32, 16), tree.rectOf(body).x); // and only that row
    // Paired with the heading, not the container: the control hangs into
    // the margin and rides up onto the title's cap region, which it can
    // only do if it found a text run to measure.
    try testing.expectEqual(@as(i32, 16 - 10), tree.rectOf(back).x);
    try testing.expect(tree.rectOf(back).y < tree.rectOf(heading).y);
}

test "layout: badge takes intrinsic width at the small scale" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const badge = try tree.append(tree.rootId(), .{ .badge = .{ .label = "Active" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(badge);
    // 6 chars * 7px (fixed measurer at small 12px) + 2*(8 pad + 1 border)
    try testing.expectEqual(@as(i32, 6 * 7 + 18), r.w);
    try testing.expectEqual(@as(i32, 16 + 2 * (2 + 1)), r.h);
}

test "layout: meter is a full-width block of label plus bar" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const meter = try tree.append(tree.rootId(), .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(meter);
    try testing.expectEqual(@as(i32, 640 - 32), r.w);
    try testing.expectEqual(@as(i32, text.Scale.small.lineHeight() + metrics.input_label_gap + metrics.meter_h), r.h);
}

test "layout: qr is a full-width block of label plus whole-module square" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const qr = try tree.append(tree.rootId(), .{ .qr = .{ .label = "Invite link", .value = "https://example.com" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 800 });
    const q = tree.getConst(qr).?.qr;
    const r = tree.rectOf(qr);
    try testing.expectEqual(@as(i32, 640 - 32), r.w);
    const side = qrSide(q.size, r.w);
    try testing.expectEqual(text.Scale.small.lineHeight() + metrics.input_label_gap + side, r.h);
    // The square is a whole number of pixels per module, capped.
    const m = q.size + 2 * metrics.qr_quiet;
    try testing.expectEqual(@as(i32, 0), @mod(side, m));
    try testing.expect(side <= metrics.qr_max_side);
    // A narrow viewport shrinks it; the floor is one pixel per module.
    try testing.expectEqual(m, qrSide(q.size, m - 1));
}

test "layout: tile group is hairline-gapped rows inside a 1px border" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const group = try tree.append(tree.rootId(), .{ .tile_group = .{} });
    const plain = try tree.append(group, .{ .tile = .{ .label = "Members" } });
    const detailed = try tree.append(group, .{ .tile = .{ .label = "Billing", .detail = "Visa 4242" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    try testing.expectEqual(@as(i32, 640 - 32), tree.rectOf(group).w);
    try testing.expectEqual(@as(i32, 44), tree.rectOf(plain).h);
    // A detail line adds the small line height.
    try testing.expectEqual(@as(i32, 44 + 16), tree.rectOf(detailed).h);
    // border + row + hairline + row + border
    try testing.expectEqual(@as(i32, 1 + 44 + 1 + 60 + 1), tree.rectOf(group).h);
}

test "layout: tile group description hangs below the border" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const group = try tree.append(tree.rootId(), .{ .tile_group = .{ .description = "Personalize your experience" } });
    const row = try tree.append(group, .{ .tile = .{ .label = "Members" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    // border box (1 + 44 + 1) + label gap + one small line
    try testing.expectEqual(@as(i32, 46 + 6 + 16), tree.rectOf(group).h);
    // The row stays flush inside the border; the description only
    // extends the group's rect.
    try testing.expectEqual(@as(i32, 44), tree.rectOf(row).h);
}

test "layout: radio group is a full-width tile group under its label" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const rg = try tree.append(tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS" },
    } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(rg);
    try testing.expectEqual(@as(i32, 640 - 32), r.w);
    // small label (16) + 6 gap + 2 rows * 44 + 3 borders (top, hairline, bottom)
    try testing.expectEqual(@as(i32, 16 + 6 + 2 * 44 + 3), r.h);
    try testing.expectEqual(r.h, radioRowY(2));
}

// Every destination is as wide as its own words: with the fixed
// measurer each codepoint (glyph included) is 9px, so a pill is
// 9 + 8 + 9*len + 2*20 = 57 + 9*len.
fn pillWidth(label: []const u8) i32 {
    return 57 + 9 * @as(i32, @intCast(label.len));
}

test "layout: the row is its own width, centered, whatever the viewport" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try appendNav(&tree); // Home, Settings
    const body = try tree.append(tree.rootId(), .{ .text = .{ .content = "content" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 800, .h = 600 });

    const bar_h = navBarHeight(0);
    const row_w = pillWidth("Home") + metrics.nav_item_gap + pillWidth("Settings");
    try testing.expectEqual(
        Rect{ .x = @divTrunc(800 - row_w, 2), .y = 600 - bar_h, .w = row_w, .h = bar_h },
        tree.rectOf(nav),
    );

    // Each item's rect is its pill grown half a gap on either side, so
    // the targets meet and nothing a thumb lands on is dead ground.
    var it = tree.children(nav);
    const first = tree.rectOf(it.next().?);
    const second = tree.rectOf(it.next().?);
    try testing.expectEqual(pillWidth("Home") + metrics.nav_item_gap, first.w);
    try testing.expectEqual(pillWidth("Settings") + metrics.nav_item_gap, second.w);
    try testing.expect(first.w != second.w);
    try testing.expectEqual(first.right(), second.x);

    // Content ignores the row entirely.
    try testing.expectEqual(@as(i32, 16), tree.rectOf(body).x);
    try testing.expectEqual(@as(i32, 800 - 32), tree.rectOf(body).w);
}

test "layout: a narrow viewport centers the same row, not a stretched one" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try appendNav(&tree);
    const body = try tree.append(tree.rootId(), .{ .text = .{ .content = "content" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });

    const bar_h = navBarHeight(0);
    const row_w = pillWidth("Home") + metrics.nav_item_gap + pillWidth("Settings");
    // The same row: destinations do not stretch to fill a window, so
    // the only thing a wider viewport changes is where the group sits.
    try testing.expectEqual(
        Rect{ .x = @divTrunc(400 - row_w, 2), .y = 600 - bar_h, .w = row_w, .h = bar_h },
        tree.rectOf(nav),
    );

    try testing.expectEqual(@as(i32, 16), tree.rectOf(body).x);
    try testing.expectEqual(@as(i32, 400 - 32), tree.rectOf(body).w);
}

// ---- the collapse threshold (docs/elements.md, nav.syncNavChrome) ----

// The fixed measurer gives every codepoint 3/5 of the size, so a body
// label is 9px per character and the glyph — one codepoint — is 9px
// too. A destination's pill is therefore 9 + 8 (mark and gap) + 9 per
// character + 2*20 of padding, and the arithmetic below is in
// characters.
const NavLabel = struct { label: []const u8, icon: element.IconName = .circle };

test "layout: the row survives while the destinations it holds fit the window" {
    // Five seven-character labels: 120px a pill, 8 between them and one
    // more before the indicator's reserved 44, then the bar's 2*16 of
    // inset — 716 in all.
    const fits = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Explore" }, .{ .label = "Account" },
        .{ .label = "History" }, .{ .label = "Support" },
    };
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &fits, .{ .w = 716, .h = 600 }));
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &fits, .{ .w = 715, .h = 600 }));

    // One character more anywhere in the set and the row wants 9 more:
    // each destination is its own width, so a longer word costs the row
    // exactly that word, not five slots' worth.
    const longer = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Explore" },  .{ .label = "Account" },
        .{ .label = "History" }, .{ .label = "Settings" },
    };
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &longer, .{ .w = 716, .h = 600 }));
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &longer, .{ .w = 725, .h = 600 }));

    // Either set collapses on a portrait phone. Five destinations with
    // marks beside their words do not fit 375px, and no arrangement of
    // them would: the chip is what that width can hold.
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &fits, .{ .w = 375, .h = 600 }));
}

test "layout: a wider viewport reopens the row at the width it asked for" {
    const items = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Settings" },
        .{ .label = "Explore" }, .{ .label = "Account" },
    };
    // 120 + 129 + 120 + 120 of pills, four gaps, the reserve, the
    // insets: 597.
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &items, .{ .w = 375, .h = 600 }));
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &items, .{ .w = 596, .h = 600 }));
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &items, .{ .w = 597, .h = 600 }));

    // A longer set wants more, and gets it: the 560px pane cap governs
    // the bottom chrome that is a surface holding prose, and a row of
    // destinations is not prose. Swapping "Account" for "Subscriptions"
    // adds exactly that word's 54px, so the row reopens at 651 — not at
    // some breakpoint, and not never.
    const long = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Settings" },
        .{ .label = "Explore" }, .{ .label = "Subscriptions" },
    };
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &long, .{ .w = 650, .h = 1440 }));
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &long, .{ .w = 651, .h = 1440 }));
}

test "layout: a row past the shared cap takes the width it needs, centered" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });
    for ([_][]const u8{ "Subscriptions", "Subscriptions", "Subscriptions", "Subscriptions" }) |label| {
        _ = try tree.append(nav, .{ .nav_item = .{ .label = label, .route = "r", .icon = .circle } });
    }
    compute(&tree, text.Measurer.fixed, .{ .w = 1200, .h = 800 });

    // Four 174px pills and three gaps: 720, well past the 560 cap that
    // governs panes holding prose. Not the cap, and not the whole
    // monitor either — the row stays a group at its natural width,
    // centered, instead of flinging its destinations at the far corners.
    const row_w = 4 * pillWidth("Subscriptions") + 3 * metrics.nav_item_gap;
    const r = tree.rectOf(nav);
    try testing.expectEqual(@as(i32, 720), row_w);
    try testing.expectEqual(row_w, r.w);
    try testing.expectEqual(@divTrunc(1200 - row_w, 2), r.x);
}

test "layout: the threshold reserves the indicator whether or not one is there" {
    // The reserve is unconditional so the nav cannot change shape
    // because a notice arrived — the decision never consults the tree,
    // which is what makes that guarantee structural rather than a rule
    // someone has to remember.
    const items = [_]NavLabel{
        .{ .label = "Alpha" }, .{ .label = "Bravo" }, .{ .label = "Charlie" },
    };
    const viewport: geometry.Size = .{ .w = 375, .h = 600 };
    const decided = layout.navCollapses(text.Measurer.fixed, &items, viewport);

    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });
    for (items) |i| _ = try tree.append(nav, .{ .nav_item = .{ .label = i.label, .route = "r", .icon = .circle } });
    _ = try tree.append(tree.rootId(), .{ .icon_button = .{ .label = "Notices", .glyph = .expand } });
    compute(&tree, text.Measurer.fixed, viewport);

    try testing.expectEqual(decided, layout.navCollapses(text.Measurer.fixed, &items, viewport));
}

test "layout: the collapsed chip is as wide as what it holds" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });
    const chip = try tree.append(nav, .{ .nav_current = .{ .section = "Subscriptions", .icon = .circle } });
    compute(&tree, text.Measurer.fixed, .{ .w = 375, .h = 600 });

    // Its pill, the gap, and the chevron — centered at that width, with
    // the rest of the bar left to the page rather than stretched over it.
    // One control standing in for the bar is still the bar's group.
    const r = tree.rectOf(chip);
    try testing.expectEqual(pillWidth("Subscriptions") + metrics.icon_gap + 9, r.w);
    try testing.expectEqual(@divTrunc(375 - r.w, 2), r.x);
    try testing.expect(r.w < 375 - 2 * metrics.nav_bar_pad_h);
    // The group is the chip and nothing else: no indicator to reserve.
    try testing.expectEqual(r.x, tree.rectOf(nav).x);
    try testing.expectEqual(r.w, tree.rectOf(nav).w);
}

test "layout: the collapsed chip never reaches under the notices indicator" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });
    // Long enough that its natural width would cover the whole bar.
    const chip = try tree.append(nav, .{ .nav_current = .{ .section = "Subscriptions and downloads", .icon = .circle } });
    const ind = try tree.append(tree.rootId(), .{ .icon_button = .{ .label = "Notices", .glyph = .expand } });
    compute(&tree, text.Measurer.fixed, .{ .w = 375, .h = 600 });

    // Capped at what the indicator leaves, so a long section name runs
    // up to its own chevron and stops — never under the control beside
    // it, which is what stretching the chip to the pane used to do.
    try testing.expect(tree.rectOf(chip).right() <= tree.rectOf(ind).x);
    try testing.expectEqual(
        375 - 2 * metrics.nav_bar_pad_h - metrics.nav_item_gap - metrics.touch_target,
        tree.rectOf(chip).w,
    );
    // With no OS band under it, the whole inset is the bar's own.
    try testing.expectEqual(600 - metrics.nav_bar_pad_b, tree.rectOf(chip).bottom());
}

test "layout: safe_bottom anchors chrome above the band and shrinks content" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try appendNav(&tree);
    const body = try tree.append(tree.rootId(), .{ .text = .{ .content = "content" } });
    const inset = 34;
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 }, 0, inset, .ltr);

    // The bar sits above the band; no rect enters it. With a home
    // indicator below, the band *is* the bar's clear space, so the
    // items keep only `nav_bar_pad` of their own.
    const bar_h = navBarHeight(inset);
    const row_w = pillWidth("Home") + metrics.nav_item_gap + pillWidth("Settings");
    try testing.expectEqual(
        Rect{ .x = @divTrunc(400 - row_w, 2), .y = 600 - inset - bar_h, .w = row_w, .h = bar_h },
        tree.rectOf(nav),
    );
    var it = tree.children(nav);
    while (it.next()) |item| {
        try testing.expectEqual(600 - inset - metrics.nav_bar_pad, tree.rectOf(item).bottom());
    }

    const area = layout.contentArea(&tree, .{ .w = 400, .h = 600 }, inset);
    try testing.expectEqual(600 - inset - bar_h, area.h);
    try testing.expect(tree.rectOf(body).bottom() <= area.h);
}

test "layout: fill scroll region stops above the bottom bar" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    _ = try appendNav(&tree);
    const sr = try tree.append(tree.rootId(), .{ .scroll_region = .{} });
    _ = try tree.append(sr, .{ .text = .{ .content = "row" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });

    // The clearance is `nav_content_gap`, not the stack's 16px margin:
    // a fill region ends where any other content would, and content
    // stands 24px off the destinations now that they have no ground.
    try testing.expectEqual(600 - navBarHeight(0) - metrics.nav_content_gap, tree.rectOf(sr).bottom());
}

test "layout: text area holds three rows empty and grows with content" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const ta = try tree.append(tree.rootId(), .{ .text_area = .{ .label = "Notes" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });

    const chrome = text.Scale.small.lineHeight() + metrics.input_label_gap +
        2 * (metrics.input_pad + metrics.border);
    const min_h = chrome + 3 * text.Scale.body.lineHeight();
    try testing.expectEqual(min_h, tree.rectOf(ta).h);

    try tree.setContent(ta, "a\nb\nc\nd");
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });
    try testing.expectEqual(chrome + 4 * text.Scale.body.lineHeight(), tree.rectOf(ta).h);
}

test "design proof: every interactive target is at least 24x24 (WCAG 2.5.8)" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });
    _ = try tree.append(nav, .{ .nav_item = .{ .label = "A", .route = "a", .icon = .circle } });
    _ = try tree.append(nav, .{ .nav_item = .{ .label = "B", .route = "b", .icon = .circle } });
    _ = try tree.append(tree.rootId(), .{ .button = .{ .label = "K" } });
    _ = try tree.append(tree.rootId(), .{ .link = .{ .label = "K", .route = "a" } });
    _ = try tree.append(tree.rootId(), .{ .toggle = .{ .label = "K" } });
    _ = try tree.append(tree.rootId(), .{ .text_input = .{ .label = "K" } });
    _ = try tree.append(tree.rootId(), .{ .text_area = .{ .label = "K" } });
    _ = try tree.append(tree.rootId(), .{ .segmented = .{ .label = "K", .options = &.{ "A", "B" } } });
    const sheet = try tree.append(tree.rootId(), .{ .sheet = .{ .title = "S" } });
    _ = try tree.append(sheet, .{ .sheet_close = .{} });

    // Worst case for every element: single-character labels.
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });

    var it = tree.dfs();
    while (it.next()) |id| {
        const el = tree.getConst(id).?;
        if (!el.isInteractive()) continue;
        const r = tree.rectOf(id);
        try testing.expect(r.w >= metrics.tap_target);
        try testing.expect(r.h >= metrics.tap_target);
    }
}

test "design proof: a nav slot clears the comfort target, not just the floor" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });
    _ = try tree.append(nav, .{ .nav_item = .{ .label = "A", .route = "a", .icon = .circle } });
    _ = try tree.append(nav, .{ .nav_item = .{ .label = "B", .route = "b", .icon = .circle } });
    compute(&tree, text.Measurer.fixed, .{ .w = 375, .h = 600 });

    // 2.5.8's 24 is the floor every control clears; the nav is asked for
    // more. It is the chrome a thumb reaches for without looking, on
    // every screen the app has, at the bottom edge where reach is worst
    // — so a slot is at least the platform comfort number, and the
    // collapsed chip that stands in for the whole row is too.
    var it = tree.children(nav);
    while (it.next()) |item| {
        try testing.expect(tree.rectOf(item).h >= metrics.touch_target);
    }
}

test "layout: a page with bottom chrome ends a clear band above it" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    _ = try appendNav(&tree);
    const body = try tree.append(tree.rootId(), .{ .text = .{ .content = "line" } });
    const viewport: geometry.Size = .{ .w = 400, .h = 600 };
    const content_h = layout.computeScrolled(&tree, text.Measurer.fixed, viewport, 0, 34, .ltr);

    // Nothing hides what passes behind the items, so the page reserves
    // the band itself: its own top margin, its words, then 24px of air
    // — the bar and the safe band being already out of the content area.
    const line_h = text.Scale.body.lineHeight();
    try testing.expectEqual(16 + line_h + metrics.nav_content_gap, content_h);

    // Scrolled to the end, that band is what the reader sees: the last
    // line lands `nav_content_gap` above the destinations, with nothing
    // of the page behind them.
    var i: usize = 0;
    while (i < 40) : (i += 1) _ = try tree.append(tree.rootId(), .{ .text = .{ .content = "line" } });
    const long_h = layout.computeScrolled(&tree, text.Measurer.fixed, viewport, 0, 34, .ltr);
    const area = layout.contentArea(&tree, viewport, 34);
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, viewport, long_h - area.h, 34, .ltr);

    var last: NodeId = body;
    var it = tree.children(tree.rootId());
    while (it.next()) |c| {
        if (tree.getConst(c).?.role() == .text) last = c;
    }
    const nav_top = 600 - 34 - navBarHeight(34);
    try testing.expectEqual(nav_top - metrics.nav_content_gap, tree.rectOf(last).bottom());
}

test "design proof: a control that is nothing but a target gets the full 44 (WCAG 2.5.5)" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // No pill, no words, no row to widen them: for each of these the
    // rect *is* the whole affordance, so 2.5.8's 24 is the floor it has
    // to clear and not the size it may lay out at.
    const back = try tree.append(tree.rootId(), .{ .back = .{} });
    _ = try tree.append(tree.rootId(), .{ .heading = .{ .content = "T" } }); // the back control's row
    const glyph_btn = try tree.append(tree.rootId(), .{ .button = .{
        .label = "K",
        .icon = .chevron_right,
        .icon_only = true,
    } });
    const check = try tree.append(tree.rootId(), .{ .checkbox = .{ .label = "K" } });
    const toggle = try tree.append(tree.rootId(), .{ .toggle = .{ .label = "K" } });
    const sheet = try tree.append(tree.rootId(), .{ .sheet = .{ .title = "S" } });
    const close = try tree.append(sheet, .{ .sheet_close = .{} });
    const notice = try tree.append(tree.rootId(), .{ .notice = .{ .title = "N", .route = "a" } });
    const dismiss = try tree.append(notice, .{ .icon_button = .{ .glyph = .dismiss, .label = "D" } });

    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });

    for ([_]NodeId{ back, glyph_btn, close, dismiss }) |id| {
        const r = tree.rectOf(id);
        try testing.expectEqual(@as(i32, metrics.touch_target), r.w);
        try testing.expectEqual(@as(i32, metrics.touch_target), r.h);
    }
    // The rows are as wide as their words; only the depth is the target.
    for ([_]NodeId{ check, toggle }) |id| {
        try testing.expectEqual(@as(i32, metrics.touch_target), tree.rectOf(id).h);
    }
}

test "layout: stacked checkbox and toggle rows collapse the flow gap" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const check = try tree.append(tree.rootId(), .{ .checkbox = .{ .label = "A" } });
    const toggle = try tree.append(tree.rootId(), .{ .toggle = .{ .label = "B" } });
    const btn = try tree.append(tree.rootId(), .{ .button = .{ .label = "C" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });

    const rc = tree.rectOf(check);
    const rt = tree.rectOf(toggle);
    // Flush: the padding each row already owns is the space between
    // them, so their words end up one target apart, as radio tiles are.
    try testing.expectEqual(rc.bottom(), rt.y);
    try testing.expectEqual(@as(i32, metrics.touch_target), rt.y - rc.y);
    // A pill is a different weight and keeps the stack's full gap.
    try testing.expectEqual(rt.bottom() + 8, tree.rectOf(btn).y);
}

test "design proof: a notice's flanking targets never overlap its text" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const notice = try tree.append(tree.rootId(), .{ .notice = .{
        .title = "Sync failed",
        .description = "Changes are kept locally.",
        .route = "a",
    } });
    const open = try tree.append(notice, .{ .icon_button = .{ .glyph = .open, .label = "O" } });
    const minimize = try tree.append(notice, .{ .icon_button = .{ .glyph = .minimize, .label = "M" } });
    const dismiss = try tree.append(notice, .{ .icon_button = .{ .glyph = .dismiss, .label = "D" } });
    // The narrowest viewport the banner has to survive: three targets
    // and a text column, all in one pane.
    compute(&tree, text.Measurer.fixed, .{ .w = 320, .h = 480 });

    const col = layout.noticeTextRegion(&tree, notice, false);
    const ro = tree.rectOf(open);
    const rm = tree.rectOf(minimize);
    const rd = tree.rectOf(dismiss);
    try testing.expect(col.w > 0);
    try testing.expect(ro.right() <= col.x);
    try testing.expect(col.x + col.w <= rm.x);
    // The trailing pair packs flush — each target's own padding is the
    // air between the two glyphs — and dismiss stays at the far edge.
    try testing.expectEqual(rm.right(), rd.x);
    try testing.expect(rd.right() <= tree.rectOf(notice).right());
}

// elideMiddle under Measurer.fixed at size 10: every codepoint (the
// ellipsis included) is 6px wide, so max_w budgets are exact codepoint
// counts.

test "elideMiddle returns null when the value fits" {
    try testing.expectEqual(@as(?layout.Elision, null), layout.elideMiddle(text.Measurer.fixed, .mono, 10, "abcdefghij", 60));
}

test "elideMiddle keeps both ends and drops the middle" {
    // 10 codepoints in 30px: ellipsis (6) + 4 codepoints (24) fit,
    // split evenly.
    const e = layout.elideMiddle(text.Measurer.fixed, .mono, 10, "abcdefghij", 30).?;
    try testing.expectEqual(@as(usize, 2), e.head_end);
    try testing.expectEqual(@as(usize, 8), e.tail_start);
}

test "elideMiddle gives an odd budget's extra codepoint to the head" {
    // 27px holds ellipsis + 3 codepoints: head 2, tail 1.
    const e = layout.elideMiddle(text.Measurer.fixed, .mono, 10, "abcdefghij", 27).?;
    try testing.expectEqual(@as(usize, 2), e.head_end);
    try testing.expectEqual(@as(usize, 9), e.tail_start);
}

test "elideMiddle splits on codepoint boundaries" {
    // Five 2-byte codepoints in 24px: head 2, tail 1 — offsets land
    // between sequences, so both slices stay valid UTF-8.
    const value = "ééééé";
    const e = layout.elideMiddle(text.Measurer.fixed, .mono, 10, value, 24).?;
    try testing.expectEqual(@as(usize, 4), e.head_end);
    try testing.expectEqual(@as(usize, 8), e.tail_start);
    try testing.expect(std.unicode.utf8ValidateSlice(value[0..e.head_end]));
    try testing.expect(std.unicode.utf8ValidateSlice(value[e.tail_start..]));
}

test "elideMiddle never reassembles the whole value around the marker" {
    // One codepoint over budget: eliding must still drop something —
    // head + tail stay short of the full value.
    const e = layout.elideMiddle(text.Measurer.fixed, .mono, 10, "abcd", 18).?;
    try testing.expect(e.head_end < e.tail_start);
}

// ---- lists ----------------------------------------------------------------

// Fixed measurer at the body scale (16px) → 9px per codepoint.

test "a list indents every item past one shared marker gutter" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const list = try tree.append(tree.rootId(), .{ .list = .{} });
    const one = try tree.append(list, .{ .list_item = .{} });
    const one_text = try tree.append(one, .{ .text = .{ .content = "Wash" } });
    const two = try tree.append(list, .{ .list_item = .{} });
    _ = try tree.append(two, .{ .text = .{ .content = "Dry" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    // Bullet: one codepoint (9px) plus the 8px gap.
    const gutter = 9 + metrics.list_marker_gap;
    try testing.expectEqual(gutter, layout.listGutter(text.Measurer.fixed, &tree, list));
    // The item keeps the full span (its rect is the row the marker sits
    // in); the words inside start past the gutter.
    try testing.expectEqual(@as(i32, 16), tree.rectOf(one).x);
    try testing.expectEqual(@as(i32, 368), tree.rectOf(one).w);
    try testing.expectEqual(@as(i32, 16 + gutter), tree.rectOf(one_text).x);
    try testing.expectEqual(@as(i32, 368 - gutter), tree.rectOf(one_text).w);
    // Items flow tighter than free blocks.
    try testing.expectEqual(
        tree.rectOf(one).bottom() + metrics.list_gap,
        tree.rectOf(two).y,
    );
}

test "an ordered list sizes its gutter to the widest ordinal, not the first" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // 9. through 11.: the column must be wide enough for three
    // characters, or the two-digit rows would push their words out.
    const list = try tree.append(tree.rootId(), .{ .list = .{ .ordered = true, .start = 9 } });
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const item = try tree.append(list, .{ .list_item = .{} });
        _ = try tree.append(item, .{ .text = .{ .content = "Step" } });
    }
    var buf: [layout.list_marker_max]u8 = undefined;
    try testing.expectEqualStrings("9.", layout.listMarker(&buf, .{ .ordered = true, .start = 9 }, 0));
    try testing.expectEqualStrings("11.", layout.listMarker(&buf, .{ .ordered = true, .start = 9 }, 2));
    try testing.expectEqual(
        @as(i32, 3 * 9 + metrics.list_marker_gap),
        layout.listGutter(text.Measurer.fixed, &tree, list),
    );
}

test "nesting adds one gutter per level" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const outer = try tree.append(tree.rootId(), .{ .list = .{} });
    const outer_item = try tree.append(outer, .{ .list_item = .{} });
    const inner = try tree.append(outer_item, .{ .list = .{} });
    const inner_item = try tree.append(inner, .{ .list_item = .{} });
    const leaf = try tree.append(inner_item, .{ .text = .{ .content = "Deep" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const gutter = 9 + metrics.list_marker_gap;
    try testing.expectEqual(@as(i32, 16 + 2 * gutter), tree.rectOf(leaf).x);
    try testing.expectEqual(@as(i32, 368 - 2 * gutter), tree.rectOf(leaf).w);
}

// ---- code blocks ----------------------------------------------------------

test "a code block that fits keeps the flow span and never bleeds" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const cb = try tree.append(tree.rootId(), .{ .code_block = .{ .content = "fn a() {}\nfn b() {}" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const el = tree.getConst(cb).?.code_block;
    // Two lines, no wrapping: height is exactly two body lines whatever
    // the width, and the widest line sets content_width (9 codepoints
    // at 9px).
    try testing.expectEqual(@as(i32, 2 * text.Scale.body.lineHeight()), tree.rectOf(cb).h);
    try testing.expectEqual(@as(i32, 81), el.content_width);
    try testing.expectEqual(@as(i32, 0), el.bleed);
    try testing.expectEqual(@as(i32, 16), tree.rectOf(cb).x);
    try testing.expectEqual(@as(i32, 368), tree.rectOf(cb).w);
}

test "an overflowing code block declines the margin and bleeds to the screen" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // 60 codepoints at 9px = 540, well past the 368px content span.
    const cb = try tree.append(tree.rootId(), .{ .code_block = .{
        .content = "x" ** 60,
    } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const el = tree.getConst(cb).?.code_block;
    // The root stack's 16px padding is the advice it declines, so the
    // rect reaches both screen edges — and the resting content span is
    // still the unbled block's, so lines stay aligned with the prose.
    try testing.expectEqual(@as(i32, 16), el.bleed);
    try testing.expectEqual(@as(i32, 0), tree.rectOf(cb).x);
    try testing.expectEqual(@as(i32, 400), tree.rectOf(cb).w);
    const window = layout.codeWindow(tree.rectOf(cb), el.bleed);
    try testing.expectEqual(@as(i32, 16), window.x);
    try testing.expectEqual(@as(i32, 368), window.w);
}

test "a box's border stops the bleed and clamps the offset" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const box = try tree.append(tree.rootId(), .{ .box = .{} });
    const cb = try tree.append(box, .{ .code_block = .{ .content = "y" ** 60, .offset = 9999 } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const el = tree.getConst(cb).?.code_block;
    // A box consumes the advice, so there is nothing left to bleed
    // through — the block clips at the box's padding, not the screen.
    try testing.expectEqual(@as(i32, 0), el.bleed);
    // Layout clamps the offset the way it clamps a scroll region's.
    const span = 368 - 2 * (12 + metrics.border);
    try testing.expectEqual(el.content_width - span, el.offset);
}

// ---- blockquotes ----------------------------------------------------------

test "a blockquote indents past its rule and consumes the advised margin" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const quote = try tree.append(tree.rootId(), .{ .blockquote = .{} });
    const words = try tree.append(quote, .{ .text = .{ .content = "Quoted." } });
    // An overflowing code block inside would bleed to the nearest drawn
    // edge — which is the quote's rule, so it must not bleed at all.
    const cb = try tree.append(quote, .{ .code_block = .{ .content = "k" ** 60 } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    try testing.expectEqual(@as(i32, 16), tree.rectOf(quote).x);
    try testing.expectEqual(@as(i32, 368), tree.rectOf(quote).w);
    try testing.expectEqual(@as(i32, 16 + metrics.quote_indent), tree.rectOf(words).x);
    try testing.expectEqual(@as(i32, 368 - metrics.quote_indent), tree.rectOf(words).w);
    try testing.expectEqual(@as(i32, 0), tree.getConst(cb).?.code_block.bleed);
}

// ---- RTL chrome mirroring (App.setDirection(.rtl)) -------------------------

fn computeRtl(tree: *Tree, viewport: geometry.Size) void {
    _ = layout.computeScrolled(tree, text.Measurer.fixed, viewport, 0, 0, .rtl);
}

test "layout rtl: an intrinsic block snaps to the right edge" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const btn = try tree.append(tree.rootId(), .{ .button = .{ .label = "OK" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });
    const r = tree.rectOf(btn);
    // Same 52px width as LTR, flush with the content's right edge (16px
    // root padding): 400 - 16 - 52 = 332.
    try testing.expectEqual(@as(i32, 52), r.w);
    try testing.expectEqual(@as(i32, 332), r.x);
    try testing.expectEqual(@as(i32, 400 - 16), r.right());
}

test "layout rtl: a horizontal stack runs right-to-left in document order" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try tree.append(tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    const a = try tree.append(row, .{ .button = .{ .label = "A" } }); // 43px
    const b = try tree.append(row, .{ .button = .{ .label = "BB" } }); // 52px
    computeRtl(&tree, .{ .w = 400, .h = 800 });
    const ra = tree.rectOf(a);
    const rb = tree.rectOf(b);
    // The first child holds the right end; the row grows leftward with
    // the 8px gap preserved between them.
    try testing.expectEqual(@as(i32, 400 - 16), ra.right());
    try testing.expect(ra.x > rb.x);
    try testing.expectEqual(@as(i32, 8), ra.x - rb.right());
}

test "layout rtl: the back control pins to the right, the title indents left" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const back_id = try tree.append(tree.rootId(), .{ .back = .{} });
    const title = try tree.append(tree.rootId(), .{ .heading = .{ .content = "Screen" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });
    const back = tree.rectOf(back_id);
    const bleed = @divTrunc(metrics.touch_target - metrics.icon_glyph, 2);
    // Back at the right edge, hanging into the margin the way it hangs
    // into the left one under LTR; the title takes the rest, ending one
    // control + gap short of it.
    try testing.expectEqual(@as(i32, 400 - 16 + bleed), back.right());
    try testing.expectEqual(@as(i32, metrics.touch_target), back.w);
    const rt = tree.rectOf(title);
    try testing.expectEqual(@as(i32, 16), rt.x);
    try testing.expectEqual(@as(i32, 400 - 16 - metrics.touch_target - metrics.icon_gap + bleed), rt.right());
}

test "layout rtl: nav slots mirror to right-to-left" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try appendNav(&tree); // Home, Settings
    var ltr = try Tree.init(testing.allocator);
    defer ltr.deinit();
    const ltr_nav = try appendNav(&ltr);

    computeRtl(&tree, .{ .w = 400, .h = 800 });
    compute(&ltr, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    // Destinations are no longer interchangeable widths, so this is a
    // mirror rather than a swap: each item's trailing edge lands as far
    // from the row's trailing edge as its leading edge was from the
    // row's leading edge. The row itself is the same rect either way.
    const row = tree.rectOf(nav);
    try testing.expectEqual(row, ltr.rectOf(ltr_nav));
    var it = tree.children(nav);
    var lit = ltr.children(ltr_nav);
    while (it.next()) |item| {
        const l = ltr.rectOf(lit.next().?);
        try testing.expectEqual(row.right() - (l.x - row.x), tree.rectOf(item).right());
    }
}

test "layout rtl: a lone minimized-notices indicator stays centered" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const ind = try tree.append(tree.rootId(), .{ .icon_button = .{ .glyph = .expand, .label = "Notices" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });
    // With no destinations beside it the square is the bar's whole
    // group, and a centered group has no leading edge for a mirror to
    // swap — so this is the one piece of chrome direction does not move.
    try testing.expectEqual(@divTrunc(400 - metrics.touch_target, 2), tree.rectOf(ind).x);

    var ltr = try Tree.init(testing.allocator);
    defer ltr.deinit();
    const ltr_ind = try ltr.append(ltr.rootId(), .{ .icon_button = .{ .glyph = .expand, .label = "Notices" } });
    compute(&ltr, text.Measurer.fixed, .{ .w = 400, .h = 800 });
    try testing.expectEqual(ltr.rectOf(ltr_ind), tree.rectOf(ind));
}

test "layout rtl: the list marker band moves to the right of the words" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const list = try tree.append(tree.rootId(), .{ .list = .{} });
    const item = try tree.append(list, .{ .list_item = .{} });
    const words = try tree.append(item, .{ .text = .{ .content = "سلام" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });

    const gutter = 9 + metrics.list_marker_gap;
    // The item still spans the content width; the words keep the left
    // end and stop short of the right, where the marker band now sits.
    try testing.expectEqual(@as(i32, 16), tree.rectOf(item).x);
    try testing.expectEqual(@as(i32, 16), tree.rectOf(words).x);
    try testing.expectEqual(@as(i32, 368 - gutter), tree.rectOf(words).w);
    try testing.expectEqual(@as(i32, 400 - 16 - gutter), tree.rectOf(words).right());
}

test "layout rtl: the blockquote's rule and indent move to the right" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const quote = try tree.append(tree.rootId(), .{ .blockquote = .{} });
    const words = try tree.append(quote, .{ .text = .{ .content = "نقل قول" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });

    // The words keep the left end; the band the rule occupies is now on
    // the right, where reading starts.
    try testing.expectEqual(@as(i32, 16), tree.rectOf(words).x);
    try testing.expectEqual(@as(i32, 400 - 16 - metrics.quote_indent), tree.rectOf(words).right());
}

test "layout rtl: table columns mirror but still align across rows" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const tbl = try tree.append(tree.rootId(), .{ .table = .{} });
    const r1 = try tree.append(tbl, .{ .row = .{ .header = true } });
    const c11 = try tree.append(r1, .{ .cell = .{} });
    _ = try tree.append(c11, .{ .text = .{ .content = "Name" } });
    const c12 = try tree.append(r1, .{ .cell = .{} });
    _ = try tree.append(c12, .{ .text = .{ .content = "Qty" } });
    const r2 = try tree.append(tbl, .{ .row = .{} });
    const c21 = try tree.append(r2, .{ .cell = .{} });
    _ = try tree.append(c21, .{ .text = .{ .content = "Blueberries" } });
    const c22 = try tree.append(r2, .{ .cell = .{} });
    _ = try tree.append(c22, .{ .text = .{ .content = "2" } });

    computeRtl(&tree, .{ .w = 400, .h = 800 });

    // The first column takes the right end; columns still line up.
    try testing.expect(tree.rectOf(c11).x > tree.rectOf(c12).x);
    try testing.expectEqual(tree.rectOf(c11).x, tree.rectOf(c21).x);
    try testing.expectEqual(tree.rectOf(c12).x, tree.rectOf(c22).x);
}

test "layout rtl: noticeTextRegion swaps the icon flanks" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // A banner with one leading control (open) and two trailing ones
    // (minimize, dismiss): asymmetric flanks, so mirroring moves the
    // text column's start.
    const notice = try tree.append(tree.rootId(), .{ .notice = .{ .title = "Saved", .route = "home" } });
    _ = try tree.append(notice, .{ .icon_button = .{ .glyph = .open, .label = "Open" } });
    _ = try tree.append(notice, .{ .icon_button = .{ .glyph = .minimize, .label = "Minimize" } });
    _ = try tree.append(notice, .{ .icon_button = .{ .glyph = .dismiss, .label = "Dismiss" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });

    const ltr_region = layout.noticeTextRegion(&tree, notice, false);
    const rtl_region = layout.noticeTextRegion(&tree, notice, true);
    // Same column width, mirrored start: LTR text clears the single
    // leading control; RTL text clears the two-control trailing stack.
    // The stack packs flush, so the difference is one bare target.
    try testing.expectEqual(ltr_region.w, rtl_region.w);
    try testing.expectEqual(ltr_region.x + metrics.touch_target, rtl_region.x);
}

test "layout: a picker on a viewport shorter than the sheet's top keeps a non-negative region" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    _ = try tree.append(tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    const picker = try tree.append(tree.rootId(), .{ .picker = .{ .title = "Language", .option_count = 2 } });
    const region = try tree.append(picker, .{ .scroll_region = .{ .height = 0 } });
    _ = try tree.append(region, .{ .picker_item = .{ .label = "English", .index = 0 } });
    _ = try tree.append(region, .{ .picker_item = .{ .label = "Deutsch", .index = 1, .selected = true } });

    // 60px is under sheet_min_top plus the header: there is no room at
    // all, and the region collapses to empty rather than going negative.
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 60 });
    try testing.expect(tree.getConst(region).?.scroll_region.height.? >= 0);
    try testing.expect(tree.rectOf(picker).h >= 0);
}
