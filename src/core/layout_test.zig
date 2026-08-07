//! Tests for layout.zig: block flow, chrome panes, and the
//! WCAG 2.5.8 target-size proof. Word wrap and elision live with their
//! module in wrap_test.zig.

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
const paneX = layout.paneX;
const qrSide = layout.qrSide;
const radioRowY = layout.radioRowY;

fn noopPress(_: ?*anyopaque) void {}

test "layout: the page stops at the pane cap and centers past it" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const body = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "x" } });

    // Below the cap nothing changed: the page is the viewport less its
    // own two margins, which is every phone-sized baseline there is.
    compute(&tree, text.Measurer.fixed, .{ .w = 480, .h = 640 });
    try testing.expectEqual(@as(i32, 16), tree.rectOf(body).x);
    try testing.expectEqual(@as(i32, 480 - 32), tree.rectOf(body).w);

    // Exactly at it, still nothing: the cap is a maximum, not a width.
    compute(&tree, text.Measurer.fixed, .{ .w = metrics.sheet_max_w, .h = 640 });
    try testing.expectEqual(@as(i32, 16), tree.rectOf(body).x);
    try testing.expectEqual(@as(i32, metrics.sheet_max_w - 32), tree.rectOf(body).w);

    // Past it the column holds its measure and takes the middle, so a
    // window twice the cap reads the same as one at it.
    for ([_]i32{ 1024, 1180, 2400 }) |w| {
        compute(&tree, text.Measurer.fixed, .{ .w = w, .h = 640 });
        const r = tree.rectOf(body);
        try testing.expectEqual(@as(i32, metrics.sheet_max_w - 32), r.w);
        try testing.expectEqual(@divTrunc(w - metrics.sheet_max_w, 2) + 16, r.x);
        try testing.expectEqual(w - r.right(), r.x);
    }
}

test "layout: a reflowing medium keeps the whole width it was handed" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const body = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "x" } });

    // The viewport a reflowing driver reports is the container it was
    // mounted in rather than the window, and a host that wanted a column
    // has already made one (`packaging.web_page_css`). Capping here
    // would overrule that number *and* leave core measuring wrap, fold
    // and bleed against a width the browser is not laying out.
    const wide: geometry.Size = .{ .w = 1180, .h = 640 };
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, wide, 0, 0, .ltr, element.default_chrome.more, .reflows);
    try testing.expectEqual(@as(i32, 16), tree.rectOf(body).x);
    try testing.expectEqual(@as(i32, 1180 - 32), tree.rectOf(body).w);

    // The same tree at the same width on the other medium: the medium is
    // the whole of the difference.
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, wide, 0, 0, .ltr, element.default_chrome.more, .clips);
    try testing.expectEqual(@as(i32, metrics.sheet_max_w - 32), tree.rectOf(body).w);
}

test "layout: spanned text takes full width at the wrapped height" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const t = try tree.appendId(tree.rootId(), .{ .text = .{ .spans = &.{
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
    const a = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "a" } });
    const b = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "b" } });

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
    const t = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "aaaa bbbb cccc dddd" } });

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
        const box = try tree.appendId(tree.rootId(), .{ .box = .{} });
        try tree.append(box, .{ .button = .{ .label = "Press" } });
        try tree.append(tree.rootId(), .{ .divider = .{} });
        compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
        slot.* = tree.rectOf(box);
    }
    try testing.expectEqual(results[0], results[1]);
}

test "layout: a box in a row hugs its content; in flow it still stretches" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 0 } });
    var boxes: [3]NodeId = undefined;
    for (&boxes) |*slot| {
        slot.* = try tree.appendId(row, .{ .box = .{ .border = false, .padding = 6 } });
        try tree.append(slot.*, .{ .text = .{ .content = "ab", .style = .{ .scale = .small } } });
    }
    const stretched = try tree.appendId(tree.rootId(), .{ .box = .{ .border = false, .padding = 6 } });
    try tree.append(stretched, .{ .text = .{ .content = "ab", .style = .{ .scale = .small } } });

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
    const btn = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "OK" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(btn);
    // 2 chars * 9px + 2*(16+1) = 18 + 34 = 52
    try testing.expectEqual(@as(i32, 52), r.w);
    try testing.expectEqual(@as(i32, 24 + 2 * 6), r.h);
}

test "layout: glyph-form button is the bare touch-target square" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const btn = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "Next cycle", .form = .{ .glyph = .chevron_right } } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(btn);
    try testing.expectEqual(@as(i32, metrics.touch_target), r.w);
    try testing.expectEqual(@as(i32, metrics.touch_target), r.h);
}

test "layout: a pill with an icon grows by the glyph and its gap" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const plain = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "OK" } });
    const iconed = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "OK", .form = .{ .filled = .alarm_clock_plus } } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    // Fixed measurer: one glyph codepoint at body(16px) is 9px wide.
    try testing.expectEqual(tree.rectOf(plain).w + 9 + metrics.icon_gap, tree.rectOf(iconed).w);
    try testing.expectEqual(tree.rectOf(plain).h, tree.rectOf(iconed).h);
}

test "layout: scroll region clamps to fixed height and records content" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const sr = try tree.appendId(tree.rootId(), .{ .scroll_region = .{ .height = 50 } });
    try tree.append(sr, .{ .text = .{ .content = "one" } });
    try tree.append(sr, .{ .text = .{ .content = "two" } });
    try tree.append(sr, .{ .text = .{ .content = "three" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    try testing.expectEqual(@as(i32, 50), tree.rectOf(sr).h);
    const el = tree.getConst(sr).?;
    try testing.expectEqual(@as(i32, 3 * 24 + 2 * 8), el.scroll_region.content_height);
}

test "layout: fill scroll region extends to the viewport bottom" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    try tree.append(tree.rootId(), .{ .heading = .{ .content = "Title" } });
    const sr = try tree.appendId(tree.rootId(), .{ .scroll_region = .{} });
    try tree.append(sr, .{ .text = .{ .content = "row" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });

    // Fills to the viewport bottom minus the root stack's padding.
    try testing.expectEqual(@as(i32, 600 - 16), tree.rectOf(sr).bottom());
}

test "layout: stale scroll offset is clamped during layout" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const sr = try tree.appendId(tree.rootId(), .{ .scroll_region = .{ .height = 50, .offset = 10000 } });
    try tree.append(sr, .{ .text = .{ .content = "one" } });
    try tree.append(sr, .{ .text = .{ .content = "two" } });
    try tree.append(sr, .{ .text = .{ .content = "three" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const el = tree.getConst(sr).?;
    try testing.expectEqual(el.scroll_region.content_height - 50, el.scroll_region.offset);
}

test "layout: table columns align across rows" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const tbl = try tree.appendId(tree.rootId(), .{ .table = .{} });
    const r1 = try tree.appendId(tbl, .{ .row = .{ .header = true } });
    const c11 = try tree.appendId(r1, .{ .cell = .{} });
    try tree.append(c11, .{ .text = .{ .content = "Name" } });
    const c12 = try tree.appendId(r1, .{ .cell = .{} });
    try tree.append(c12, .{ .text = .{ .content = "Qty" } });
    const r2 = try tree.appendId(tbl, .{ .row = .{} });
    const c21 = try tree.appendId(r2, .{ .cell = .{} });
    try tree.append(c21, .{ .text = .{ .content = "Blueberries" } });
    const c22 = try tree.appendId(r2, .{ .cell = .{} });
    try tree.append(c22, .{ .text = .{ .content = "2" } });

    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });

    try testing.expectEqual(tree.rectOf(c11).x, tree.rectOf(c21).x);
    try testing.expectEqual(tree.rectOf(c12).x, tree.rectOf(c22).x);
    try testing.expectEqual(tree.rectOf(c11).w, tree.rectOf(c21).w);
}

test "layout: a table wider than the viewport reports its real width" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const tbl = try tree.appendId(tree.rootId(), .{ .table = .{} });
    const row = try tree.appendId(tbl, .{ .row = .{} });
    const a = try tree.appendId(row, .{ .cell = .{} });
    try tree.append(a, .{ .text = .{ .content = "aaaaaaaaaaaaaaaaaaaaaaaa" } });
    const b = try tree.appendId(row, .{ .cell = .{} });
    try tree.append(b, .{ .text = .{ .content = "bbbbbbbbbbbbbbbbbbbbbbbb" } });

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
    const nav = try tree.appendId(tree.rootId(), .{ .nav = .{} });
    try tree.append(nav, .{ .nav_item = .{ .label = "Home", .route = "home", .icon = .house } });
    try tree.append(nav, .{ .nav_item = .{ .label = "Settings", .route = "settings", .icon = .settings } });
    return nav;
}

test "layout: segmented takes intrinsic width" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const seg = try tree.appendId(tree.rootId(), .{ .segmented = .{ .label = "View", .options = &.{ "List", "Grid" } } });
    compute(&tree, text.Measurer.fixed, .{ .w = 480, .h = 480 });
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
    const seg = try tree.appendId(tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts, .selected = 4 } });
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
    const box = try tree.appendId(tree.rootId(), .{ .box = .{} });
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try tree.appendId(box, .{ .segmented = .{ .label = "K", .options = opts } });
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
    const row = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = gap } });
    for ([_][]const u8{ "One", "Two", "Three", "Four", "Five" }) |label| {
        try tree.append(row, .{ .button = .{ .label = label } });
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
    try testing.expect(x - 16 + layout.moreSize(text.Measurer.fixed, element.default_chrome.more).w <= 368);
}

test "layout: the folded tail's control stands where the first folded button did" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try buildButtonRow(&tree, 8);
    // What `overflow.syncOverflowChrome` appends after the first pass;
    // layout reserved its width before it existed either way.
    const more = try tree.appendId(row, .{ .more = .{} });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 480 });

    const size = layout.moreSize(text.Measurer.fixed, element.default_chrome.more);
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
    const more = try tree.appendId(row, .{ .more = .{} });
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, .{ .w = 400, .h = 480 }, 0, 0, .rtl, element.default_chrome.more, .clips);

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
    const mixed = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    try tree.append(mixed, .{ .text = .{ .content = "Ready to publish?" } });
    for ([_][]const u8{ "Publish", "Save draft", "Discard" }) |label| {
        try tree.append(mixed, .{ .button = .{ .label = label } });
    }
    // One button too wide for the row is not a row: folding it would
    // hide the only action behind a control named for having more.
    const lone = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    try tree.append(lone, .{ .button = .{ .label = "A very long single action indeed" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 300, .h = 480 });

    var folded: [5][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), foldedLabels(&tree, mixed, &folded));
    try testing.expectEqual(@as(usize, 0), foldedLabels(&tree, lone, &folded));
    // Both wrap instead — which is what "does not fold" now means.
    try testing.expectEqual(layout.RowOverflow.wrap, layout.rowOverflow(&tree, mixed));
    try testing.expectEqual(layout.RowOverflow.wrap, layout.rowOverflow(&tree, lone));
}

// ---- the wrapped lines of every other row -----------------------------------

/// Chips of `len` codepoints under the fixed measurer: small is 12px, so
/// 7px a character, plus the chip's two pads and two borders.
fn badgeWidth(len: i32) i32 {
    return 7 * len + 2 * (metrics.badge_pad_h + metrics.border);
}

const badge_h = text.Scale.small.lineHeight() + 2 * (metrics.badge_pad_v + metrics.border);

/// Five four-character chips, 46px each with an 8px gap, in the 168px a
/// 200px viewport leaves after the root's margin: three fit (154), a
/// fourth would want 208.
fn buildChipRow(tree: *Tree, count: usize) !NodeId {
    const row = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for (0..count) |_| try tree.append(row, .{ .badge = .{ .label = "abcd" } });
    return row;
}

fn nthChild(tree: *const Tree, parent: NodeId, n: usize) NodeId {
    var it = tree.children(parent);
    var i: usize = 0;
    while (it.next()) |c| : (i += 1) if (i == n) return c;
    unreachable;
}

test "layout: a row of chips breaks to the next line rather than off the edge" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try buildChipRow(&tree, 5);
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    const w = badgeWidth(4);
    try testing.expectEqual(46, w);
    // Greedy first fit, in document order: three, then the rest.
    const xs = [_]i32{ 16, 16 + w + 8, 16 + 2 * (w + 8), 16, 16 + w + 8 };
    const ys = [_]i32{ 16, 16, 16, 16 + badge_h + 8, 16 + badge_h + 8 };
    for (xs, ys, 0..) |x, y, i| {
        const r = tree.rectOf(nthChild(&tree, row, i));
        try testing.expectEqual(x, r.x);
        try testing.expectEqual(y, r.y);
        try testing.expectEqual(w, r.w);
    }
    // Nothing runs past the content edge any more, and the row is as
    // tall as the two lines it took.
    for (0..5) |i| {
        const r = tree.rectOf(nthChild(&tree, row, i));
        try testing.expect(r.x + r.w <= 200 - 16);
    }
    try testing.expectEqual(2 * badge_h + 8, tree.rectOf(row).h);
}

test "layout: a wrapped row mirrors, and breaks in the same places" {
    var ltr = try Tree.init(testing.allocator);
    defer ltr.deinit();
    const ltr_row = try buildChipRow(&ltr, 5);
    compute(&ltr, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    var rtl = try Tree.init(testing.allocator);
    defer rtl.deinit();
    const rtl_row = try buildChipRow(&rtl, 5);
    _ = layout.computeScrolled(&rtl, text.Measurer.fixed, .{ .w = 200, .h = 480 }, 0, 0, .rtl, "More", .clips);

    const w = badgeWidth(4);
    for (0..5) |i| {
        const l = ltr.rectOf(nthChild(&ltr, ltr_row, i));
        const r = rtl.rectOf(nthChild(&rtl, rtl_row, i));
        // Same line, same order along it — the mirror image, not a
        // different break.
        try testing.expectEqual(l.y, r.y);
        try testing.expectEqual(200 - l.x - w, r.x);
    }
    try testing.expectEqual(ltr.rectOf(ltr_row).h, rtl.rectOf(rtl_row).h);
}

test "layout: a chip wider than the line gets the line to itself" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    try tree.append(row, .{ .badge = .{ .label = "abcd" } });
    const huge = try tree.appendId(row, .{ .badge = .{ .label = "a" ** 40 } });
    try tree.append(row, .{ .badge = .{ .label = "abcd" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    const first = tree.rectOf(nthChild(&tree, row, 0));
    const big = tree.rectOf(huge);
    const last = tree.rectOf(nthChild(&tree, row, 2));
    // The one case wrapping cannot rescue, and does not pretend to: the
    // chip starts a line of its own and overflows it. What wrapping does
    // buy is that it overflows by its own width and no more — nothing
    // ahead of it pushes it further out, and nothing behind it is dragged
    // along.
    try testing.expectEqual(16, first.x);
    try testing.expectEqual(16, big.x);
    try testing.expect(big.x + big.w > 200);
    try testing.expectEqual(16, last.x);
    try testing.expectEqual(first.y + badge_h + 8, big.y);
    try testing.expectEqual(big.y + badge_h + 8, last.y);
}

test "layout: each wrapped line centers on its own tallest" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const row = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    // Line one: a chip beside a button, which is taller. Line two: two
    // chips, whose line has no button to center against.
    const chip = try tree.appendId(row, .{ .badge = .{ .label = "abcd" } });
    const button = try tree.appendId(row, .{ .button = .{ .label = "Press" } });
    const wrapped = try tree.appendId(row, .{ .badge = .{ .label = "abcd" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 200, .h = 480 });

    const button_h = text.Scale.body.lineHeight() + 2 * (metrics.button_pad_v + metrics.border);
    const b = tree.rectOf(button);
    try testing.expectEqual(16, b.y);
    // Centered against the button on its line…
    try testing.expectEqual(16 + @divTrunc(button_h - badge_h, 2), tree.rectOf(chip).y);
    // …and flush with the top of a line that holds only chips.
    try testing.expectEqual(16 + button_h + 8, tree.rectOf(wrapped).y);
}

test "layout: a link among the buttons is one of the actions, not a disqualifier" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // The shape a real screen has: actions, one of which goes somewhere
    // instead of doing something. It folds like the rest.
    const row = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Save", "Cancel", "Add reminder", "Disabled" }) |label| {
        try tree.append(row, .{ .button = .{ .label = label } });
    }
    const link = try tree.appendId(row, .{ .link = .{ .label = "More details", .route = "details" } });
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
    const stack = try tree.appendId(tree.rootId(), .{ .stack = .{ .padding = 8 } });
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try tree.appendId(stack, .{ .segmented = .{ .label = "K", .options = opts } });
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
    try tree.append(tree.rootId(), .{ .back = .{} });
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try tree.appendId(tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
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
    const back = try tree.appendId(tree.rootId(), .{ .back = .{} });
    const doc = try tree.appendId(tree.rootId(), .{ .document = .{
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
    const badge = try tree.appendId(tree.rootId(), .{ .badge = .{ .label = "Active" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 640, .h = 480 });
    const r = tree.rectOf(badge);
    // 6 chars * 7px (fixed measurer at small 12px) + 2*(8 pad + 1 border)
    try testing.expectEqual(@as(i32, 6 * 7 + 18), r.w);
    try testing.expectEqual(@as(i32, 16 + 2 * (2 + 1)), r.h);
}

test "layout: meter is a full-width block of label plus bar" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const meter = try tree.appendId(tree.rootId(), .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });
    compute(&tree, text.Measurer.fixed, .{ .w = 480, .h = 480 });
    const r = tree.rectOf(meter);
    try testing.expectEqual(@as(i32, 480 - 32), r.w);
    try testing.expectEqual(@as(i32, text.Scale.small.lineHeight() + metrics.input_label_gap + metrics.meter_h), r.h);
}

test "layout: qr is a full-width block of label plus whole-module square" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const qr = try tree.appendId(tree.rootId(), .{ .qr = .{ .label = "Invite link", .value = "https://example.com" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 480, .h = 800 });
    const q = tree.getConst(qr).?.qr;
    const r = tree.rectOf(qr);
    try testing.expectEqual(@as(i32, 480 - 32), r.w);
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
    const group = try tree.appendId(tree.rootId(), .{ .tile_group = .{} });
    const plain = try tree.appendId(group, .{ .tile = .{ .label = "Members", .on_press = .{ .call = noopPress } } });
    const detailed = try tree.appendId(group, .{ .tile = .{ .label = "Billing", .detail = "Visa 4242", .on_press = .{ .call = noopPress } } });
    compute(&tree, text.Measurer.fixed, .{ .w = 480, .h = 480 });
    try testing.expectEqual(@as(i32, 480 - 32), tree.rectOf(group).w);
    try testing.expectEqual(@as(i32, 44), tree.rectOf(plain).h);
    // A detail line adds the small line height.
    try testing.expectEqual(@as(i32, 44 + 16), tree.rectOf(detailed).h);
    // border + row + hairline + row + border
    try testing.expectEqual(@as(i32, 1 + 44 + 1 + 60 + 1), tree.rectOf(group).h);
}

test "layout: tile group description hangs below the border" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const group = try tree.appendId(tree.rootId(), .{ .tile_group = .{ .description = "Personalize your experience" } });
    const row = try tree.appendId(group, .{ .tile = .{ .label = "Members", .on_press = .{ .call = noopPress } } });
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
    const rg = try tree.appendId(tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS" },
    } });
    compute(&tree, text.Measurer.fixed, .{ .w = 480, .h = 480 });
    const r = tree.rectOf(rg);
    try testing.expectEqual(@as(i32, 480 - 32), r.w);
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
    const body = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "content" } });
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

    // Content ignores the row entirely — and the two are centered on
    // different widths, which is the whole of `sheet_max_w`'s refusal to
    // cap the bar: the page stops at the cap, the row at its own words.
    const page = paneX(.{ .w = 800, .h = 600 });
    try testing.expectEqual(page + 16, tree.rectOf(body).x);
    try testing.expectEqual(@as(i32, metrics.sheet_max_w - 32), tree.rectOf(body).w);
    try testing.expect(tree.rectOf(nav).x != page);
}

test "layout: a narrow viewport centers the same row, not a stretched one" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try appendNav(&tree);
    const body = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "content" } });
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
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &fits, .{ .w = 716, .h = 600 }, .clips));
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &fits, .{ .w = 715, .h = 600 }, .clips));

    // One character more anywhere in the set and the row wants 9 more:
    // each destination is its own width, so a longer word costs the row
    // exactly that word, not five slots' worth.
    const longer = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Explore" },  .{ .label = "Account" },
        .{ .label = "History" }, .{ .label = "Settings" },
    };
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &longer, .{ .w = 716, .h = 600 }, .clips));
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &longer, .{ .w = 725, .h = 600 }, .clips));

    // Either set collapses on a portrait phone. Five destinations with
    // marks beside their words do not fit 375px, and no arrangement of
    // them would: the chip is what that width can hold.
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &fits, .{ .w = 375, .h = 600 }, .clips));
}

test "layout: a wider viewport reopens the row at the width it asked for" {
    const items = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Settings" },
        .{ .label = "Explore" }, .{ .label = "Account" },
    };
    // 120 + 129 + 120 + 120 of pills, four gaps, the reserve, the
    // insets: 597.
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &items, .{ .w = 375, .h = 600 }, .clips));
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &items, .{ .w = 596, .h = 600 }, .clips));
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &items, .{ .w = 597, .h = 600 }, .clips));

    // A longer set wants more, and gets it: the 560px pane cap governs
    // the bottom chrome that is a surface holding prose, and a row of
    // destinations is not prose. Swapping "Account" for "Subscriptions"
    // adds exactly that word's 54px, so the row reopens at 651 — not at
    // some breakpoint, and not never.
    const long = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Settings" },
        .{ .label = "Explore" }, .{ .label = "Subscriptions" },
    };
    try testing.expect(layout.navCollapses(text.Measurer.fixed, &long, .{ .w = 650, .h = 1440 }, .clips));
    try testing.expect(!layout.navCollapses(text.Measurer.fixed, &long, .{ .w = 651, .h = 1440 }, .clips));
}

test "layout: a row that wraps has no width at which it fails to fit" {
    // The set from the threshold test above, which does not make a line
    // at 715 and does at 716 — on a surface that clips. Where the
    // surface wraps, every one of those answers is the wrong question
    // asked: the row is already on two lines and nothing was lost.
    const fits = [_]NavLabel{
        .{ .label = "Library" }, .{ .label = "Explore" }, .{ .label = "Account" },
        .{ .label = "History" }, .{ .label = "Support" },
    };
    for ([_]i32{ 561, 600, 715, 716, 900, 1400, 5120 }) |w| {
        const viewport: geometry.Size = .{ .w = w, .h = 900 };
        try testing.expect(layout.navRowWraps(viewport, .reflows));
        try testing.expect(!layout.navCollapses(text.Measurer.fixed, &fits, viewport, .reflows));
        // The same window on the medium that cannot wrap keeps the
        // answer it always had: this is one arm, not a new threshold.
        try testing.expect(!layout.navRowWraps(viewport, .clips));
        try testing.expectEqual(
            w < 716,
            layout.navCollapses(text.Measurer.fixed, &fits, viewport, .clips),
        );
    }

    // At and below the pane cap a reflowing medium has the band, which
    // is one line by construction — so the measurement is live again and
    // both mediums answer alike. The chip is what that width holds.
    for ([_]i32{ 320, 375, 480, metrics.sheet_max_w }) |w| {
        const viewport: geometry.Size = .{ .w = w, .h = 900 };
        try testing.expect(!layout.navRowWraps(viewport, .reflows));
        try testing.expect(layout.navCollapses(text.Measurer.fixed, &fits, viewport, .reflows));
        try testing.expect(layout.navCollapses(text.Measurer.fixed, &fits, viewport, .clips));
    }
}

test "layout: a row past the shared cap takes the width it needs, centered" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.appendId(tree.rootId(), .{ .nav = .{} });
    for ([_][]const u8{ "Subscriptions", "Subscriptions", "Subscriptions", "Subscriptions" }) |label| {
        try tree.append(nav, .{ .nav_item = .{ .label = label, .route = "r", .icon = .circle } });
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
    const decided = layout.navCollapses(text.Measurer.fixed, &items, viewport, .clips);

    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.appendId(tree.rootId(), .{ .nav = .{} });
    for (items) |i| try tree.append(nav, .{ .nav_item = .{ .label = i.label, .route = "r", .icon = .circle } });
    try tree.append(tree.rootId(), .{ .icon_button = .{ .label = "Notices", .glyph = .expand } });
    compute(&tree, text.Measurer.fixed, viewport);

    try testing.expectEqual(decided, layout.navCollapses(text.Measurer.fixed, &items, viewport, .clips));
}

test "layout: the collapsed chip is as wide as what it holds" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.appendId(tree.rootId(), .{ .nav = .{} });
    const chip = try tree.appendId(nav, .{ .nav_current = .{ .section = "Subscriptions", .icon = .circle } });
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
    const nav = try tree.appendId(tree.rootId(), .{ .nav = .{} });
    // Long enough that its natural width would cover the whole bar.
    const chip = try tree.appendId(nav, .{ .nav_current = .{ .section = "Subscriptions and downloads", .icon = .circle } });
    const ind = try tree.appendId(tree.rootId(), .{ .icon_button = .{ .label = "Notices", .glyph = .expand } });
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
    const body = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "content" } });
    const inset = 34;
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 }, 0, inset, .ltr, element.default_chrome.more, .clips);

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
    const sr = try tree.appendId(tree.rootId(), .{ .scroll_region = .{} });
    try tree.append(sr, .{ .text = .{ .content = "row" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });

    // The clearance is `nav_content_gap`, not the stack's 16px margin:
    // a fill region ends where any other content would, and content
    // stands 24px off the destinations now that they have no ground.
    try testing.expectEqual(600 - navBarHeight(0) - metrics.nav_content_gap, tree.rectOf(sr).bottom());
}

test "layout: text area holds three rows empty and grows with content" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const ta = try tree.appendId(tree.rootId(), .{ .text_area = .{ .label = "Notes" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });

    const chrome = text.Scale.small.lineHeight() + metrics.input_label_gap +
        2 * (metrics.input_pad + metrics.border);
    const min_h = chrome + 3 * text.Scale.body.lineHeight();
    try testing.expectEqual(min_h, tree.rectOf(ta).h);

    try tree.setContent(ta, "a\nb\nc\nd");
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 600 });
    try testing.expectEqual(chrome + 4 * text.Scale.body.lineHeight(), tree.rectOf(ta).h);
}

test "layout: a problem extends the field's rect below its outline" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const plain = try tree.appendId(tree.rootId(), .{ .text_input = .{ .label = "City" } });
    const refused = try tree.appendId(tree.rootId(), .{ .text_input = .{
        .label = "Email",
        .problem = "That is not an email address.",
    } });
    const area = try tree.appendId(tree.rootId(), .{ .text_area = .{
        .label = "Notes",
        .problem = "Say a little more than that.",
    } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 900 });

    // The words ride *inside* the element's rect rather than beside it,
    // which is what makes them scroll, clip and hit-test with the field
    // they belong to — the same move `tile_group` makes for a caption.
    const box = tree.rectOf(plain).h;
    const words = layout.fieldProblemHeight(text.Measurer.fixed, "That is not an email address.", 400);
    try testing.expect(words > metrics.input_label_gap);
    try testing.expectEqual(box + words, tree.rectOf(refused).h);

    const min_area = layout.labeledFieldHeight(3 * text.Scale.body.lineHeight());
    try testing.expectEqual(
        min_area + layout.fieldProblemHeight(text.Measurer.fixed, "Say a little more than that.", 400),
        tree.rectOf(area).h,
    );
}

test "design proof: every interactive target is at least 24x24 (WCAG 2.5.8)" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const nav = try tree.appendId(tree.rootId(), .{ .nav = .{} });
    try tree.append(nav, .{ .nav_item = .{ .label = "A", .route = "a", .icon = .circle } });
    try tree.append(nav, .{ .nav_item = .{ .label = "B", .route = "b", .icon = .circle } });
    try tree.append(tree.rootId(), .{ .button = .{ .label = "K" } });
    try tree.append(tree.rootId(), .{ .link = .{ .label = "K", .route = "a" } });
    try tree.append(tree.rootId(), .{ .toggle = .{ .label = "K" } });
    try tree.append(tree.rootId(), .{ .text_input = .{ .label = "K" } });
    try tree.append(tree.rootId(), .{ .text_area = .{ .label = "K" } });
    try tree.append(tree.rootId(), .{ .segmented = .{ .label = "K", .options = &.{ "A", "B" } } });
    const sheet = try tree.appendId(tree.rootId(), .{ .sheet = .{ .title = "S" } });
    try tree.append(sheet, .{ .sheet_close = .{} });

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
    const nav = try tree.appendId(tree.rootId(), .{ .nav = .{} });
    try tree.append(nav, .{ .nav_item = .{ .label = "A", .route = "a", .icon = .circle } });
    try tree.append(nav, .{ .nav_item = .{ .label = "B", .route = "b", .icon = .circle } });
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
    const body = try tree.appendId(tree.rootId(), .{ .text = .{ .content = "line" } });
    const viewport: geometry.Size = .{ .w = 400, .h = 600 };
    const content_h = layout.computeScrolled(&tree, text.Measurer.fixed, viewport, 0, 34, .ltr, element.default_chrome.more, .clips);

    // Nothing hides what passes behind the items, so the page reserves
    // the band itself: its own top margin, its words, then 24px of air
    // — the bar and the safe band being already out of the content area.
    const line_h = text.Scale.body.lineHeight();
    try testing.expectEqual(16 + line_h + metrics.nav_content_gap, content_h);

    // Scrolled to the end, that band is what the reader sees: the last
    // line lands `nav_content_gap` above the destinations, with nothing
    // of the page behind them.
    var i: usize = 0;
    while (i < 40) : (i += 1) try tree.append(tree.rootId(), .{ .text = .{ .content = "line" } });
    const long_h = layout.computeScrolled(&tree, text.Measurer.fixed, viewport, 0, 34, .ltr, element.default_chrome.more, .clips);
    const area = layout.contentArea(&tree, viewport, 34);
    _ = layout.computeScrolled(&tree, text.Measurer.fixed, viewport, long_h - area.h, 34, .ltr, element.default_chrome.more, .clips);

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
    const back = try tree.appendId(tree.rootId(), .{ .back = .{} });
    try tree.append(tree.rootId(), .{ .heading = .{ .content = "T" } }); // the back control's row
    const glyph_btn = try tree.appendId(tree.rootId(), .{ .button = .{
        .label = "K",
        .form = .{ .glyph = .chevron_right },
    } });
    const check = try tree.appendId(tree.rootId(), .{ .checkbox = .{ .label = "K" } });
    const toggle = try tree.appendId(tree.rootId(), .{ .toggle = .{ .label = "K" } });
    const sheet = try tree.appendId(tree.rootId(), .{ .sheet = .{ .title = "S" } });
    const close = try tree.appendId(sheet, .{ .sheet_close = .{} });
    const notice = try tree.appendId(tree.rootId(), .{ .notice = .{ .title = "N", .route = "a" } });
    const dismiss = try tree.appendId(notice, .{ .icon_button = .{ .glyph = .dismiss, .label = "D" } });

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
    const check = try tree.appendId(tree.rootId(), .{ .checkbox = .{ .label = "A" } });
    const toggle = try tree.appendId(tree.rootId(), .{ .toggle = .{ .label = "B" } });
    const btn = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "C" } });
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
    const notice = try tree.appendId(tree.rootId(), .{ .notice = .{
        .title = "Sync failed",
        .description = "Changes are kept locally.",
        .route = "a",
    } });
    const open = try tree.appendId(notice, .{ .icon_button = .{ .glyph = .open, .label = "O" } });
    const minimize = try tree.appendId(notice, .{ .icon_button = .{ .glyph = .minimize, .label = "M" } });
    const dismiss = try tree.appendId(notice, .{ .icon_button = .{ .glyph = .dismiss, .label = "D" } });
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

// ---- lists ----------------------------------------------------------------

// Fixed measurer at the body scale (16px) → 9px per codepoint.

test "a list indents every item past one shared marker gutter" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const list = try tree.appendId(tree.rootId(), .{ .list = .{} });
    const one = try tree.appendId(list, .{ .list_item = .{} });
    const one_text = try tree.appendId(one, .{ .text = .{ .content = "Wash" } });
    const two = try tree.appendId(list, .{ .list_item = .{} });
    try tree.append(two, .{ .text = .{ .content = "Dry" } });
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
    const list = try tree.appendId(tree.rootId(), .{ .list = .{ .ordered = true, .start = 9 } });
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const item = try tree.appendId(list, .{ .list_item = .{} });
        try tree.append(item, .{ .text = .{ .content = "Step" } });
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
    const outer = try tree.appendId(tree.rootId(), .{ .list = .{} });
    const outer_item = try tree.appendId(outer, .{ .list_item = .{} });
    const inner = try tree.appendId(outer_item, .{ .list = .{} });
    const inner_item = try tree.appendId(inner, .{ .list_item = .{} });
    const leaf = try tree.appendId(inner_item, .{ .text = .{ .content = "Deep" } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    const gutter = 9 + metrics.list_marker_gap;
    try testing.expectEqual(@as(i32, 16 + 2 * gutter), tree.rectOf(leaf).x);
    try testing.expectEqual(@as(i32, 368 - 2 * gutter), tree.rectOf(leaf).w);
}

// ---- code blocks ----------------------------------------------------------

test "a code block that fits keeps the flow span and never bleeds" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const cb = try tree.appendId(tree.rootId(), .{ .code_block = .{ .content = "fn a() {}\nfn b() {}" } });
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
    const cb = try tree.appendId(tree.rootId(), .{ .code_block = .{
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
    const box = try tree.appendId(tree.rootId(), .{ .box = .{} });
    const cb = try tree.appendId(box, .{ .code_block = .{ .content = "y" ** 60, .offset = 9999 } });
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
    const quote = try tree.appendId(tree.rootId(), .{ .blockquote = .{} });
    const words = try tree.appendId(quote, .{ .text = .{ .content = "Quoted." } });
    // An overflowing code block inside would bleed to the nearest drawn
    // edge — which is the quote's rule, so it must not bleed at all.
    const cb = try tree.appendId(quote, .{ .code_block = .{ .content = "k" ** 60 } });
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 800 });

    try testing.expectEqual(@as(i32, 16), tree.rectOf(quote).x);
    try testing.expectEqual(@as(i32, 368), tree.rectOf(quote).w);
    try testing.expectEqual(@as(i32, 16 + metrics.quote_indent), tree.rectOf(words).x);
    try testing.expectEqual(@as(i32, 368 - metrics.quote_indent), tree.rectOf(words).w);
    try testing.expectEqual(@as(i32, 0), tree.getConst(cb).?.code_block.bleed);
}

// ---- RTL chrome mirroring (App.setDirection(.rtl)) -------------------------

fn computeRtl(tree: *Tree, viewport: geometry.Size) void {
    _ = layout.computeScrolled(tree, text.Measurer.fixed, viewport, 0, 0, .rtl, element.default_chrome.more, .clips);
}

test "layout rtl: an intrinsic block snaps to the right edge" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const btn = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "OK" } });
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
    const row = try tree.appendId(tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    const a = try tree.appendId(row, .{ .button = .{ .label = "A" } }); // 43px
    const b = try tree.appendId(row, .{ .button = .{ .label = "BB" } }); // 52px
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
    const back_id = try tree.appendId(tree.rootId(), .{ .back = .{} });
    const title = try tree.appendId(tree.rootId(), .{ .heading = .{ .content = "Screen" } });
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
    const ind = try tree.appendId(tree.rootId(), .{ .icon_button = .{ .glyph = .expand, .label = "Notices" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });
    // With no destinations beside it the square is the bar's whole
    // group, and a centered group has no leading edge for a mirror to
    // swap — so this is the one piece of chrome direction does not move.
    try testing.expectEqual(@divTrunc(400 - metrics.touch_target, 2), tree.rectOf(ind).x);

    var ltr = try Tree.init(testing.allocator);
    defer ltr.deinit();
    const ltr_ind = try ltr.appendId(ltr.rootId(), .{ .icon_button = .{ .glyph = .expand, .label = "Notices" } });
    compute(&ltr, text.Measurer.fixed, .{ .w = 400, .h = 800 });
    try testing.expectEqual(ltr.rectOf(ltr_ind), tree.rectOf(ind));
}

test "layout rtl: the list marker band moves to the right of the words" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const list = try tree.appendId(tree.rootId(), .{ .list = .{} });
    const item = try tree.appendId(list, .{ .list_item = .{} });
    const words = try tree.appendId(item, .{ .text = .{ .content = "سلام" } });
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
    const quote = try tree.appendId(tree.rootId(), .{ .blockquote = .{} });
    const words = try tree.appendId(quote, .{ .text = .{ .content = "نقل قول" } });
    computeRtl(&tree, .{ .w = 400, .h = 800 });

    // The words keep the left end; the band the rule occupies is now on
    // the right, where reading starts.
    try testing.expectEqual(@as(i32, 16), tree.rectOf(words).x);
    try testing.expectEqual(@as(i32, 400 - 16 - metrics.quote_indent), tree.rectOf(words).right());
}

test "layout rtl: table columns mirror but still align across rows" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const tbl = try tree.appendId(tree.rootId(), .{ .table = .{} });
    const r1 = try tree.appendId(tbl, .{ .row = .{ .header = true } });
    const c11 = try tree.appendId(r1, .{ .cell = .{} });
    try tree.append(c11, .{ .text = .{ .content = "Name" } });
    const c12 = try tree.appendId(r1, .{ .cell = .{} });
    try tree.append(c12, .{ .text = .{ .content = "Qty" } });
    const r2 = try tree.appendId(tbl, .{ .row = .{} });
    const c21 = try tree.appendId(r2, .{ .cell = .{} });
    try tree.append(c21, .{ .text = .{ .content = "Blueberries" } });
    const c22 = try tree.appendId(r2, .{ .cell = .{} });
    try tree.append(c22, .{ .text = .{ .content = "2" } });

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
    const notice = try tree.appendId(tree.rootId(), .{ .notice = .{ .title = "Saved", .route = "home" } });
    try tree.append(notice, .{ .icon_button = .{ .glyph = .open, .label = "Open" } });
    try tree.append(notice, .{ .icon_button = .{ .glyph = .minimize, .label = "Minimize" } });
    try tree.append(notice, .{ .icon_button = .{ .glyph = .dismiss, .label = "Dismiss" } });
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
    try tree.append(tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    const picker = try tree.appendId(tree.rootId(), .{ .picker = .{ .title = "Language", .option_count = 2 } });
    const region = try tree.appendId(picker, .{ .scroll_region = .{ .height = 0 } });
    try tree.append(region, .{ .picker_item = .{ .label = "English", .index = 0 } });
    try tree.append(region, .{ .picker_item = .{ .label = "Deutsch", .index = 1, .selected = true } });

    // 60px is under sheet_min_top plus the header: there is no room at
    // all, and the region collapses to empty rather than going negative.
    compute(&tree, text.Measurer.fixed, .{ .w = 400, .h = 60 });
    try testing.expect(tree.getConst(region).?.scroll_region.height.? >= 0);
    try testing.expect(tree.rectOf(picker).h >= 0);
}
