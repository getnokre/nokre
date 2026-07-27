//! Tests for tree.zig: structure, generational ids, and append-time
//! validation.

const std = @import("std");
const tree_mod = @import("tree.zig");
const element_mod = @import("element.zig");
const color = @import("color.zig");

const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const Element = tree_mod.Element;
const Role = element_mod.Role;

test "append builds sibling chains in order" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try tree.append(tree.rootId(), .{ .text = .{ .content = "a" } });
    const b = try tree.append(tree.rootId(), .{ .text = .{ .content = "b" } });
    _ = a;
    _ = b;

    var it = tree.children(tree.rootId());
    try std.testing.expectEqualStrings("a", tree.getConst(it.next().?).?.label());
    try std.testing.expectEqualStrings("b", tree.getConst(it.next().?).?.label());
    try std.testing.expectEqual(@as(?NodeId, null), it.next());
}

test "strings are copied, not borrowed" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    var buf = [_]u8{ 'h', 'i' };
    const id = try tree.append(tree.rootId(), .{ .text = .{ .content = &buf } });
    buf[0] = 'X';
    try std.testing.expectEqualStrings("hi", tree.getConst(id).?.label());
}

test "labels formatted into stack buffers survive the buffer" {
    // The tree never borrows consumer memory — a label bufPrint'd into
    // a builder's stack buffer must stay valid after the builder
    // returns. Every string-bearing element goes through
    // dupeStrings; a new element that skips it fails here, not in a
    // consumer's app. (Regression: badge/meter/tile_group/copyable
    // once borrowed, invisible while every caller passed literals.)
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    var buf: [24]u8 = undefined;
    var label = std.fmt.bufPrint(&buf, "{d} of {d} notes", .{ 3, 16 }) catch unreachable;
    const meter = try tree.append(tree.rootId(), .{ .meter = .{ .label = label, .value = 3, .max = 16 } });
    label = std.fmt.bufPrint(&buf, "{d} pending", .{7}) catch unreachable;
    const badge = try tree.append(tree.rootId(), .{ .badge = .{ .label = label } });
    label = std.fmt.bufPrint(&buf, "code {s}", .{"XK-1"}) catch unreachable;
    const copyable = try tree.append(tree.rootId(), .{ .copyable = .{ .label = "Code", .value = label } });
    label = std.fmt.bufPrint(&buf, "{d} rows", .{2}) catch unreachable;
    const group = try tree.append(tree.rootId(), .{ .tile_group = .{ .description = label } });
    @memset(&buf, 'X');

    try std.testing.expectEqualStrings("3 of 16 notes", tree.getConst(meter).?.meter.label);
    try std.testing.expectEqualStrings("7 pending", tree.getConst(badge).?.badge.label);
    try std.testing.expectEqualStrings("code XK-1", tree.getConst(copyable).?.copyable.value);
    try std.testing.expectEqualStrings("2 rows", tree.getConst(group).?.tile_group.description);
}

test "stale ids are rejected after removal" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.append(tree.rootId(), .{ .divider = .{} });
    try tree.remove(id);
    try std.testing.expectEqual(@as(?*Element, null), tree.get(id));

    // Slot reuse must not resurrect the old id.
    const id2 = try tree.append(tree.rootId(), .{ .divider = .{} });
    try std.testing.expect(!id.eql(id2));
    try std.testing.expectEqual(@as(?*Element, null), tree.get(id));
    try std.testing.expect(tree.get(id2) != null);
}

test "a stale id stays rejected past 256 reuses of its slot" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    // A router rebuild frees and reallocates the content subtree on
    // every navigation, so a low slot cycles once per screen change.
    // With the u8 generation this counter replaced, the stale id
    // aliased the live node at cycle 255 — an ordinary session. The
    // generation is a u12 now, so the first cycle where an alias is
    // possible is 4095.
    const stale = try tree.append(tree.rootId(), .{ .divider = .{} });
    try tree.remove(stale);
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const id = try tree.append(tree.rootId(), .{ .divider = .{} });
        // The free list hands the same slot back each cycle, so this
        // loop really is spinning one slot's generation counter.
        try std.testing.expectEqual(stale.index, id.index);
        // The check that matters happens while the slot is live under a
        // fresh id: a dead slot rejects any id regardless of generation.
        try std.testing.expectEqual(@as(?*Element, null), tree.get(stale));
        try tree.remove(id);
    }
}

test "release keeps every slot reachable through the free list" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    // Free-list room is bought when a slot is first allocated
    // (`allocNode`), so release can never strand one: across repeated
    // build/clear rounds the node table stops growing after the first,
    // because every freed slot is genuinely reusable.
    var high_water: usize = 0;
    var round: usize = 0;
    while (round < 32) : (round += 1) {
        const box = try tree.append(tree.rootId(), .{ .box = .{} });
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            _ = try tree.append(box, .{ .text = .{ .content = "row" } });
        }
        try tree.remove(box);
        if (round == 0) high_water = tree.nodes.items.len;
        try std.testing.expectEqual(high_water, tree.nodes.items.len);

        // Slot accounting: every slot is either alive or on the free
        // list. A stranded slot would be neither.
        var alive: usize = 0;
        for (tree.nodes.items) |n| {
            if (n.alive) alive += 1;
        }
        try std.testing.expectEqual(tree.nodes.items.len, alive + tree.free_list.items.len);
    }
}

test "remove unlinks middle sibling" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.append(tree.rootId(), .{ .text = .{ .content = "a" } });
    const b = try tree.append(tree.rootId(), .{ .text = .{ .content = "b" } });
    _ = try tree.append(tree.rootId(), .{ .text = .{ .content = "c" } });
    try tree.remove(b);

    var it = tree.children(tree.rootId());
    try std.testing.expectEqualStrings("a", tree.getConst(it.next().?).?.label());
    try std.testing.expectEqualStrings("c", tree.getConst(it.next().?).?.label());
    try std.testing.expectEqual(@as(?NodeId, null), it.next());
}

test "dfs visits pre-order" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const box = try tree.append(tree.rootId(), .{ .box = .{} });
    _ = try tree.append(box, .{ .text = .{ .content = "inner" } });
    _ = try tree.append(tree.rootId(), .{ .text = .{ .content = "after" } });

    var it = tree.dfs();
    try std.testing.expectEqual(Role.stack, tree.getConst(it.next().?).?.role());
    try std.testing.expectEqual(Role.box, tree.getConst(it.next().?).?.role());
    try std.testing.expectEqualStrings("inner", tree.getConst(it.next().?).?.label());
    try std.testing.expectEqualStrings("after", tree.getConst(it.next().?).?.label());
    try std.testing.expectEqual(@as(?NodeId, null), it.next());
}

test "clearChildren empties a subtree" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const box = try tree.append(tree.rootId(), .{ .box = .{} });
    _ = try tree.append(box, .{ .text = .{ .content = "x" } });
    _ = try tree.append(box, .{ .text = .{ .content = "y" } });
    try tree.clearChildren(box);
    try std.testing.expectEqual(@as(usize, 0), tree.childCount(box));
}

test "append rejects unlabeled interactive elements" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .button = .{ .label = "" } }));
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .toggle = .{ .label = "" } }));
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .text_input = .{ .label = "" } }));
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .link = .{ .label = "", .route = "r" } }));
    // The `…` an in-progress button renders is a state, not a name:
    // it buys no exemption from the label rule.
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .button = .{ .label = "", .in_progress = true } }));
    _ = try tree.append(root, .{ .button = .{ .label = "Go", .disabled = true } });
}

test "append rejects a percentage with nothing to measure" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // A percentage on a button that is not working measures nothing.
    try std.testing.expectError(error.ProgressNeedsInProgress, tree.append(root, .{ .button = .{ .label = "Save", .progress_percent = 40 } }));
    // Percent means percent.
    try std.testing.expectError(error.ProgressOutOfRange, tree.append(root, .{ .button = .{ .label = "Save", .in_progress = true, .progress_percent = 101 } }));
    // A 24px glyph target has nowhere to read a bar…
    try std.testing.expectError(error.IconOnlyButtonHasNoMeter, tree.append(root, .{ .button = .{
        .label = "Next",
        .icon = .chevron_right,
        .icon_only = true,
        .in_progress = true,
        .progress_percent = 40,
    } }));
    // …and a vendor's button is not nokre's to draw a bar inside.
    try std.testing.expectError(error.AuthButtonHasNoMeter, tree.append(root, .{ .button = .{
        .label = "Sign in with Apple",
        .provider = .apple,
        .in_progress = true,
        .progress_percent = 40,
    } }));

    _ = try tree.append(root, .{ .button = .{ .label = "Save", .in_progress = true, .progress_percent = 0 } });
    _ = try tree.append(root, .{ .button = .{ .label = "Send", .in_progress = true, .progress_percent = 100 } });
}

test "append rejects negative spacing" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // Margins are advice a child may decline (layout's Ctx.margin);
    // the escape a negative inset exists for has no meaning here.
    try std.testing.expectError(error.NegativeSpacing, tree.append(root, .{ .stack = .{ .padding = -4 } }));
    try std.testing.expectError(error.NegativeSpacing, tree.append(root, .{ .stack = .{ .gap = -1 } }));
    try std.testing.expectError(error.NegativeSpacing, tree.append(root, .{ .box = .{ .padding = -1 } }));
    _ = try tree.append(root, .{ .stack = .{ .padding = 0, .gap = 0 } });
}

test "append rejects icon-only buttons without an icon" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.IconOnlyButtonNeedsIcon, tree.append(root, .{ .button = .{ .label = "Next", .icon_only = true } }));
    _ = try tree.append(root, .{ .button = .{ .label = "Next", .icon = .chevron_right, .icon_only = true } });
    _ = try tree.append(root, .{ .button = .{ .label = "Add", .icon = .alarm_clock_plus } });
}

test "append rejects secondary emphasis on icon-only buttons" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.IconOnlyButtonHasNoEmphasis, tree.append(root, .{ .button = .{
        .label = "Next",
        .icon = .chevron_right,
        .icon_only = true,
        .secondary = true,
    } }));
    _ = try tree.append(root, .{ .button = .{ .label = "Cancel", .secondary = true } });
}

test "append demands the vendor's words on a sign-in button, and refuses an icon beside the mark" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // nokre ships the mark and not the words: it cannot know which
    // languages an app ships, and a default would only make the
    // unlocalized button the silent path. The error names that rule
    // rather than the general unlabeled-interactive one, because "any
    // non-empty string" is not the fix.
    try std.testing.expectError(error.AuthButtonNeedsVendorLabel, tree.append(root, .{ .button = .{
        .label = "",
        .provider = .apple,
    } }));
    const id = try tree.append(root, .{ .button = .{ .label = "Mit Apple anmelden", .provider = .apple } });
    try std.testing.expectEqualStrings("Mit Apple anmelden", tree.getConst(id).?.button.label);

    // The mark occupies the icon slot, and no vendor sanctions a
    // glyph-only sign-in button.
    try std.testing.expectError(error.AuthButtonHasNoIcon, tree.append(root, .{ .button = .{
        .label = "Sign in with Apple",
        .provider = .apple,
        .icon = .chevron_right,
    } }));
    try std.testing.expectError(error.AuthButtonNeedsItsLabel, tree.append(root, .{ .button = .{
        .label = "Sign in with Apple",
        .provider = .apple,
        .icon_only = true,
    } }));
    // Outlined is Apple's third sanctioned style, not a new one.
    _ = try tree.append(root, .{ .button = .{
        .label = "Sign in with Apple",
        .provider = .apple,
        .secondary = true,
    } });
}

test "append rejects malformed table structure" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    const tbl = try tree.append(root, .{ .table = .{} });
    try std.testing.expectError(error.TableChildMustBeRow, tree.append(tbl, .{ .text = .{ .content = "stray" } }));
    const row = try tree.append(tbl, .{ .row = .{} });
    try std.testing.expectError(error.RowChildMustBeCell, tree.append(row, .{ .text = .{ .content = "stray" } }));
    _ = try tree.append(row, .{ .cell = .{} });
    try std.testing.expectError(error.RowOutsideTable, tree.append(root, .{ .row = .{} }));
    try std.testing.expectError(error.CellOutsideRow, tree.append(root, .{ .cell = .{} }));
}

test "append rejects malformed nav structure" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    const box = try tree.append(root, .{ .box = .{} });
    try std.testing.expectError(error.NavMustBeAtRoot, tree.append(box, .{ .nav = .{} }));

    const nav = try tree.append(root, .{ .nav = .{} });
    try std.testing.expectError(error.MultipleNavs, tree.append(root, .{ .nav = .{} }));
    try std.testing.expectError(error.NavChildMustBeNavItem, tree.append(nav, .{ .text = .{ .content = "stray" } }));
    _ = try tree.append(nav, .{ .nav_item = .{ .label = "Home", .route = "home", .icon = .house } });
    try std.testing.expectError(error.NavItemOutsideNav, tree.append(root, .{ .nav_item = .{ .label = "Lost", .route = "lost", .icon = .circle } }));
}

test "append rejects a malformed off-roster marker" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();
    const nav = try tree.append(root, .{ .nav = .{} });

    try std.testing.expectError(error.NavItemOutsideNav, tree.append(root, .{ .nav_here = .{ .label = "Terms" } }));
    try std.testing.expectError(error.EmptyNavHere, tree.append(nav, .{ .nav_here = .{ .label = "" } }));

    _ = try tree.append(nav, .{ .nav_item = .{ .label = "Home", .route = "home", .icon = .house } });
    _ = try tree.append(nav, .{ .nav_here = .{ .label = "Terms" } });
    // It is the tail of the row and there is one of it: a destination
    // behind it would be read after the screen it stands on, and a
    // second marker would say you are in two places.
    try std.testing.expectError(error.NavItemAfterNavHere, tree.append(nav, .{ .nav_item = .{ .label = "Late", .route = "late", .icon = .circle } }));
    try std.testing.expectError(error.MultipleNavHere, tree.append(nav, .{ .nav_here = .{ .label = "Also" } }));
}

test "append keeps the two nav shapes exclusive of the marker too" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const nav = try tree.append(tree.rootId(), .{ .nav = .{} });

    _ = try tree.append(nav, .{ .nav_current = .{ .section = "Library", .icon = .library } });
    // The chip already carries what the marker would have said, so the
    // collapsed shape has no room for one (`element.NavHere`).
    try std.testing.expectError(error.NavShapeIsExclusive, tree.append(nav, .{ .nav_here = .{ .label = "Terms" } }));
}

test "append rejects a folded-tail control anywhere but on a row" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // The root is a vertical stack; a row is the only thing that folds.
    try std.testing.expectError(error.MoreOutsideButtonRow, tree.append(root, .{ .more = .{} }));
    const box = try tree.append(root, .{ .box = .{} });
    try std.testing.expectError(error.MoreOutsideButtonRow, tree.append(box, .{ .more = .{} }));

    const row = try tree.append(root, .{ .stack = .{ .axis = .horizontal } });
    _ = try tree.append(row, .{ .more = .{} });
    // One tail per row: a second control would stand for the same
    // buttons twice.
    try std.testing.expectError(error.MultipleMoreControls, tree.append(row, .{ .more = .{} }));
}

test "append rejects malformed tile structure" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    const group = try tree.append(root, .{ .tile_group = .{} });
    try std.testing.expectError(error.TileGroupChildMustBeTile, tree.append(group, .{ .text = .{ .content = "stray" } }));
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(group, .{ .tile = .{ .label = "" } }));
    _ = try tree.append(group, .{ .tile = .{ .label = "Members" } });
    try std.testing.expectError(error.TileOutsideTileGroup, tree.append(root, .{ .tile = .{ .label = "Lost" } }));
}

test "append rejects malformed list structure" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    const list = try tree.append(root, .{ .list = .{} });
    try std.testing.expectError(error.ListChildMustBeListItem, tree.append(list, .{ .text = .{ .content = "stray" } }));
    try std.testing.expectError(error.ListItemOutsideList, tree.append(root, .{ .list_item = .{} }));

    const item = try tree.append(list, .{ .list_item = .{} });
    _ = try tree.append(item, .{ .text = .{ .content = "Wash the dishes" } });
    // The document block set: no heading (it would claim an outline
    // position the list cannot own) and no table (a grid at list depth
    // reads as a mistake — the parser degrades one to literal text).
    try std.testing.expectError(error.InvalidListItemChild, tree.append(item, .{ .heading = .{ .content = "Nope" } }));
    try std.testing.expectError(error.InvalidListItemChild, tree.append(item, .{ .table = .{} }));
    try std.testing.expectError(error.InvalidListItemChild, tree.append(item, .{ .button = .{ .label = "Nope" } }));
}

test "append holds link spans to the rules every other control obeys" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // A control with no words is an invisible tab stop; a link with no
    // destination is a control that does nothing.
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "   ", .route = "terms" },
    } } }));
    try std.testing.expectError(error.EmptySpanRoute, tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "terms", .route = "" },
    } } }));

    // The route is its own string, not a slice of the concatenation, so
    // it needs its own copy — the tree never borrows consumer memory.
    var route = [_]u8{ 't', 'e', 'r', 'm', 's' };
    const para = try tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "terms", .route = &route },
    } } });
    @memset(&route, 0);
    const spans = tree.getConst(para).?.text.spans;
    try std.testing.expectEqualStrings("terms", spans[1].route.?);
    try std.testing.expectEqualStrings("Read the terms", tree.getConst(para).?.text.content);
    try std.testing.expectEqual(@as(?[]const u8, null), spans[0].route);
}

test "append holds external destinations to open_url's closed scheme set, spans and link element alike" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // A span goes exactly one place; a scheme off the allowlist is the
    // service's refusal, applied at construction.
    try std.testing.expectError(error.RouteAndExternal, tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "terms", .route = "terms", .external = "https://example.com" },
    } } }));
    try std.testing.expectError(error.UnsupportedScheme, tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "boom", .external = "javascript:alert(1)" },
    } } }));
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "  ", .external = "https://example.com" },
    } } }));

    // The link element obeys the same rules: exactly one destination,
    // scheme-checked.
    try std.testing.expectError(error.RouteAndExternal, tree.append(root, .{ .link = .{
        .label = "Site",
        .route = "terms",
        .external = "https://example.com",
    } }));
    try std.testing.expectError(error.UnsupportedScheme, tree.append(root, .{ .link = .{
        .label = "File",
        .external = "file:///etc/passwd",
    } }));
    try std.testing.expectError(error.EmptyRoute, tree.append(root, .{ .link = .{ .label = "Nowhere" } }));

    // Well-formed external destinations construct, copied like routes —
    // the tree never borrows consumer memory.
    var url = [_]u8{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'x', '.', 'c', 'o' };
    const para = try tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "the site", .external = &url },
    } } });
    _ = try tree.append(root, .{ .link = .{ .label = "Mail us", .external = "mailto:x@example.com" } });
    @memset(&url, 0);
    const spans = tree.getConst(para).?.text.spans;
    try std.testing.expectEqualStrings("https://x.co", spans[0].external.?);
}

test "append holds a blockquote to the document block set" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const quote = try tree.append(tree.rootId(), .{ .blockquote = .{} });
    _ = try tree.append(quote, .{ .text = .{ .content = "Not everything that counts can be counted." } });
    _ = try tree.append(quote, .{ .blockquote = .{} }); // quotes nest
    _ = try tree.append(quote, .{ .code_block = .{ .content = "cite();" } });
    try std.testing.expectError(error.InvalidBlockquoteChild, tree.append(quote, .{ .heading = .{ .content = "Nope" } }));
    try std.testing.expectError(error.InvalidBlockquoteChild, tree.append(quote, .{ .button = .{ .label = "Nope" } }));
}

test "append rejects a verbatim block with nothing verbatim in it" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectError(error.EmptyCodeBlock, tree.append(tree.rootId(), .{ .code_block = .{ .content = "" } }));
    // Content is copied like every other string, so the caller may free
    // its buffer the moment append returns.
    var buf = [_]u8{ 'f', 'n', ' ', 'x' };
    const cb = try tree.append(tree.rootId(), .{ .code_block = .{ .content = &buf } });
    @memset(&buf, 0);
    try std.testing.expectEqualStrings("fn x", tree.getConst(cb).?.code_block.content);
}

test "append caps list nesting at three levels" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    var parent = tree.rootId();
    var depth: usize = 0;
    while (depth < element_mod.max_list_depth) : (depth += 1) {
        const list = try tree.append(parent, .{ .list = .{} });
        try std.testing.expectEqual(depth + 1, tree.listDepth(list));
        parent = try tree.append(list, .{ .list_item = .{} });
    }
    // A fourth level is refused at construction; content nokre does not
    // control flattens onto the third rather than failing.
    try std.testing.expectError(error.ListNestingTooDeep, tree.append(parent, .{ .list = .{} }));
}

test "append rejects degenerate segmented controls" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.SegmentedNeedsTwoOptions, tree.append(root, .{ .segmented = .{ .label = "Lonely", .options = &.{"One"} } }));
    try std.testing.expectError(error.SegmentedEmptyOption, tree.append(root, .{ .segmented = .{ .label = "Blank", .options = &.{ "A", "" } } }));
    try std.testing.expectError(error.SegmentedSelectionOutOfRange, tree.append(root, .{ .segmented = .{ .label = "Off", .options = &.{ "A", "B" }, .selected = 7 } }));
    _ = try tree.append(root, .{ .segmented = .{ .label = "View", .options = &.{ "List", "Grid" } } });
}

test "append rejects degenerate radio groups" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.RadioGroupNeedsTwoOptions, tree.append(root, .{ .radio_group = .{ .label = "Lonely", .options = &.{"One"} } }));
    try std.testing.expectError(error.RadioGroupEmptyOption, tree.append(root, .{ .radio_group = .{ .label = "Blank", .options = &.{ "A", "" } } }));
    try std.testing.expectError(error.RadioGroupSelectionOutOfRange, tree.append(root, .{ .radio_group = .{ .label = "Off", .options = &.{ "A", "B" }, .selected = 7 } }));
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .radio_group = .{ .label = "", .options = &.{ "A", "B" } } }));
    _ = try tree.append(root, .{ .radio_group = .{ .label = "Delivery", .options = &.{ "Email", "SMS" } } });
}

test "append rejects degenerate selects" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.SelectNeedsTwoOptions, tree.append(root, .{ .select = .{ .label = "Lonely", .options = &.{"One"} } }));
    try std.testing.expectError(error.SelectEmptyOption, tree.append(root, .{ .select = .{ .label = "Blank", .options = &.{ "A", "" } } }));
    try std.testing.expectError(error.SelectSelectionOutOfRange, tree.append(root, .{ .select = .{ .label = "Off", .options = &.{ "A", "B" }, .selected = 7 } }));
    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .select = .{ .label = "", .options = &.{ "A", "B" } } }));
    _ = try tree.append(root, .{ .select = .{ .label = "Language", .options = &.{ "English", "Deutsch" } } });
}

test "append rejects malformed picker structure" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.UntitledPicker, tree.append(root, .{ .picker = .{ .title = "" } }));
    const box = try tree.append(root, .{ .box = .{} });
    try std.testing.expectError(error.PickerMustBeAtRoot, tree.append(box, .{ .picker = .{ .title = "Language" } }));
    try std.testing.expectError(error.PickerItemOutsidePicker, tree.append(root, .{ .picker_item = .{ .label = "English" } }));

    const picker = try tree.append(root, .{ .picker = .{ .title = "Language" } });
    try std.testing.expectError(error.InvalidPickerChild, tree.append(picker, .{ .text = .{ .content = "stray" } }));
    const region = try tree.append(picker, .{ .scroll_region = .{ .height = 0 } });
    _ = try tree.append(region, .{ .picker_item = .{ .label = "English" } });
    try std.testing.expectError(error.MultiplePickers, tree.append(root, .{ .picker = .{ .title = "Another" } }));
}

test "append rejects wordless and out-of-range meters" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();
    try std.testing.expectError(error.EmptyMeter, tree.append(root, .{ .meter = .{ .label = "", .value = 1, .max = 2 } }));
    try std.testing.expectError(error.MeterValueOutOfRange, tree.append(root, .{ .meter = .{ .label = "1 of 0", .value = 1, .max = 0 } }));
    try std.testing.expectError(error.MeterValueOutOfRange, tree.append(root, .{ .meter = .{ .label = "31 of 30", .value = 31, .max = 30 } }));
    _ = try tree.append(root, .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });
}

test "append rejects unlabeled, valueless, and non-text qr codes" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.UnlabeledQr, tree.append(root, .{ .qr = .{ .label = "", .value = "https://example.com" } }));
    try std.testing.expectError(error.EmptyQr, tree.append(root, .{ .qr = .{ .label = "Invite link", .value = "" } }));
    try std.testing.expectError(error.QrValueNotText, tree.append(root, .{ .qr = .{ .label = "Invite link", .value = "a\x00b" } }));
    // ~4300 chars exceeds even version 40 at medium error correction.
    const long = "x" ** 4300;
    try std.testing.expectError(error.QrValueTooLong, tree.append(root, .{ .qr = .{ .label = "Invite link", .value = long } }));
}

test "append encodes a qr value into module bits" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.append(tree.rootId(), .{ .qr = .{
        .label = "Invite link",
        .value = "https://example.com/invite/XKCD-1234",
    } });
    const q = tree.getConst(id).?.qr;
    // Smallest symbol is version 1 (21 modules); side is always 4k+17.
    try std.testing.expect(q.size >= 21 and q.size <= 177);
    try std.testing.expectEqual(@as(i32, 1), @mod(q.size, 4));
    try std.testing.expectEqual((@as(usize, @intCast(q.size * q.size)) + 7) / 8, q.modules.len);
    // Every QR code's corners open with a dark finder-pattern module.
    try std.testing.expect(q.module(0, 0));
    try std.testing.expect(q.module(q.size - 1, 0));
    try std.testing.expect(q.module(0, q.size - 1));

    // Same value → same bits: encoding is deterministic.
    const id2 = try tree.append(tree.rootId(), .{ .qr = .{
        .label = "Invite link again",
        .value = "https://example.com/invite/XKCD-1234",
    } });
    const q2 = tree.getConst(id2).?.qr;
    try std.testing.expectEqual(q.size, q2.size);
    try std.testing.expectEqualSlices(u8, q.modules, q2.modules);
}

test "append rejects empty badges" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.EmptyBadge, tree.append(root, .{ .badge = .{ .label = "" } }));
    _ = try tree.append(root, .{ .badge = .{ .label = "Active" } });
}

test "append rejects unlabeled and valueless copyables" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    try std.testing.expectError(error.UnlabeledInteractive, tree.append(root, .{ .copyable = .{ .label = "", .value = "XKCD-1234" } }));
    try std.testing.expectError(error.EmptyCopyable, tree.append(root, .{ .copyable = .{ .label = "Recovery code", .value = "" } }));
    _ = try tree.append(root, .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
}

test "append rejects illegible text on its background" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // Light ink on paper fails WCAG AA.
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(root, .{ .text = .{ .content = "faint", .style = .{ .ink = .g6 } } }));

    // Default (ink) text inside an ink-filled box is invisible.
    const dark_box = try tree.append(root, .{ .box = .{ .fill = .ink } });
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(dark_box, .{ .text = .{ .content = "void" } }));
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(dark_box, .{ .link = .{ .label = "hidden", .route = "x" } }));

    // Paper ink on the same fill, and whitespace-only swatch text, pass.
    _ = try tree.append(dark_box, .{ .text = .{ .content = "legible", .style = .{ .ink = .paper } } });
    _ = try tree.append(dark_box, .{ .text = .{ .content = " " } });
    _ = try tree.append(root, .{ .text = .{ .content = "secondary", .style = .{ .ink = .mid } } });

    // Decorative icons may fade; meaningful ones must not.
    _ = try tree.append(root, .{ .icon = .{ .name = .activity, .ink = .light } });
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(root, .{ .icon = .{ .name = .activity, .ink = .light, .label = "Live" } }));
    _ = try tree.append(root, .{ .icon = .{ .name = .activity, .label = "Live" } });
}

test "append gates text contrast in both appearances, not just light" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // The two ramps are independent, so contrast is not preserved
    // across them: `ink` on a `.g7` fill is 4.73:1 in light — over the
    // AA floor, and accepted by a light-only gate — but 3.46:1 in dark.
    // Twenty such pairs exist; checking one appearance checked half the
    // app. The rejection must cite the appearance-blind failure, so it
    // is the same error either way.
    const mid_box = try tree.append(root, .{ .box = .{ .fill = .g7 } });
    try std.testing.expect(color.Gray.ink.contrastWith(.g7, .light) >= color.min_text_contrast);
    try std.testing.expect(color.Gray.ink.contrastWith(.g7, .dark) < color.min_text_contrast);
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(mid_box, .{ .text = .{ .content = "half-legible" } }));

    // Span inks face the same two-appearance gate.
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(mid_box, .{ .text = .{
        .spans = &.{.{ .text = "half-legible" }},
    } }));
}

test "append rejects text that is too contrasty, not only too faint" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();

    // True ink on true paper is 21:1. WCAG 2.x has no ceiling because
    // it treats contrast as monotonically good; at this end of the
    // scale it is a glare source, not a legibility win. `g0` and `g12`
    // stay in the palette for the QR tile and the vendor marks, which
    // draw through the renderer rather than the tree.
    try std.testing.expectError(error.ExcessiveTextContrast, tree.append(root, .{ .text = .{ .content = "glare", .style = .{ .ink = .g0 } } }));
    try std.testing.expectError(error.ExcessiveTextContrast, tree.append(root, .{ .text = .{
        .spans = &.{.{ .text = "glare", .ink = .g0 }},
    } }));

    // The alias the framework steers you to sits comfortably inside.
    _ = try tree.append(root, .{ .text = .{ .content = "comfortable" } });
}

test "spans: append concatenates into content and rebases the spans" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const id = try tree.append(tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Rokovski " },
        .{ .text = "Feedback", .strong = true },
    } } });
    const t = tree.getConst(id).?.text;
    try std.testing.expectEqualStrings("Rokovski Feedback", t.content);
    try std.testing.expectEqualStrings("Rokovski Feedback", tree.getConst(id).?.label());
    // Spans are slices of the stored content, adjacent and in order.
    try std.testing.expectEqual(t.content.ptr, t.spans[0].text.ptr);
    try std.testing.expectEqual(t.content.ptr + t.spans[0].text.len, t.spans[1].text.ptr);
}

test "spans: heading spans concatenate the same way" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const id = try tree.append(tree.rootId(), .{ .heading = .{ .level = .h2, .spans = &.{
        .{ .text = "The " },
        .{ .text = "wrap", .code = true },
        .{ .text = " function" },
    } } });
    try std.testing.expectEqualStrings("The wrap function", tree.getConst(id).?.label());
}

test "spans: content alongside spans is rejected" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectError(error.ContentAlongsideSpans, tree.append(tree.rootId(), .{ .text = .{
        .content = "both",
        .spans = &.{.{ .text = "both" }},
    } }));
}

test "spans: an empty span is rejected" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectError(error.EmptySpan, tree.append(tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "a" },
        .{ .text = "" },
    } } }));
}

test "spans: an illegible span ink is rejected like plain text ink" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "dim", .ink = .g9 },
    } } }));
    // A null span ink inherits the style's — which gates the same way.
    try std.testing.expectError(error.InsufficientTextContrast, tree.append(tree.rootId(), .{ .text = .{
        .style = .{ .ink = .g9 },
        .spans = &.{.{ .text = "dim" }},
    } }));
    // Whitespace-only runs render no ink and pass, as whitespace text does.
    _ = try tree.append(tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "legible" },
        .{ .text = "   ", .ink = .g9 },
    } } });
}

test "spans: setContent replaces spanned text with plain content" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const id = try tree.append(tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "a" },
        .{ .text = "b", .strong = true },
    } } });
    try tree.setContent(id, "plain");
    const t = tree.getConst(id).?.text;
    try std.testing.expectEqualStrings("plain", t.content);
    try std.testing.expectEqual(@as(usize, 0), t.spans.len);
}

test "setContent clamps a caret the new value no longer reaches" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const input = try tree.append(tree.rootId(), .{ .text_input = .{ .label = "Name", .value = "hello world" } });
    const area = try tree.append(tree.rootId(), .{ .text_area = .{ .label = "Notes", .value = "hello world" } });
    tree.get(input).?.text_input.cursor = "hello world".len;
    tree.get(area).?.text_area.cursor = "hello world".len;

    // The caret is state over the old bytes, exactly like a span: past
    // the new end it would dangle into bytes that no longer exist, so
    // it is clamped rather than left for the next edit to trip on.
    try tree.setContent(input, "hi");
    try tree.setContent(area, "hi");
    try std.testing.expectEqualStrings("hi", tree.getConst(input).?.text_input.value);
    try std.testing.expectEqual(@as(usize, 2), tree.getConst(input).?.text_input.cursor);
    try std.testing.expectEqual(@as(usize, 2), tree.getConst(area).?.text_area.cursor);

    // A caret the new value still covers keeps its place.
    try tree.setContent(input, "hi there");
    try std.testing.expectEqual(@as(usize, 2), tree.getConst(input).?.text_input.cursor);
}

test "a document expands wherever it enters the tree, not only via append" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.rootId();
    const anchor = try tree.append(root, .{ .text = .{ .content = "before" } });

    const doc = try tree.insertFirst(root, .{ .document = .{ .label = "Doc", .source = "# Title\n\nBody." } });
    try std.testing.expectEqual(@as(usize, 2), tree.childCount(doc));

    const doc2 = try tree.insertAfter(anchor, .{ .document = .{ .label = "Doc2", .source = "words" } });
    try std.testing.expectEqual(@as(usize, 1), tree.childCount(doc2));
}
