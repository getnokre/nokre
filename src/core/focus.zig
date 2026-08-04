//! Focus is a single linear order per layer: depth-first document order
//! over focus stops, scoped to the active layer (the open sheet, or the
//! whole tree). Within a layer there are no traps, no tab groups, no
//! spatial navigation. Predictable for users, trivially auditable for
//! tests. A modal sheet is not a trap: Esc always leaves it.
//!
//! A stop is usually a whole element. The exception is a paragraph
//! carrying link spans: the paragraph itself is not focusable, but each
//! of its links is its own stop, so a link inside prose is reached by
//! Tab like any other control.

const std = @import("std");
const element_mod = @import("element.zig");
const tree_mod = @import("tree.zig");

const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;

/// Where focus sits: a node, plus which of its link spans holds it.
/// The span index is part of the target rather than a field beside it
/// so that no code path can move focus and leave a stale index behind —
/// the compiler asks at every assignment.
pub const Focus = struct {
    node: NodeId,
    /// Index into the element's `spans` when the stop is an inline
    /// link; null when the stop is the element itself.
    span: ?u16 = null,

    pub fn of(node: NodeId) Focus {
        return .{ .node = node };
    }

    pub fn eql(a: Focus, b: Focus) bool {
        return a.node.eql(b.node) and a.span == b.span;
    }

    /// Whether focus lands anywhere on `node` — the element itself or
    /// one of its links. What draw code and the a11y snapshot ask.
    pub fn on(self: Focus, node: NodeId) bool {
        return self.node.eql(node);
    }
};

/// The link spans of an element, or empty when it has none. Only `text`
/// and `heading` carry spans; everything else is a stop as a whole.
pub fn spansOf(el: element_mod.Element) []const element_mod.Span {
    return if (el.textRun()) |run| run.spans else &.{};
}

/// Whether `el` contributes stops through its spans rather than as an
/// element. A paragraph is never focusable itself; its links are.
pub fn hasLinkSpans(el: element_mod.Element) bool {
    for (spansOf(el)) |span| {
        if (span.isLink()) return true;
    }
    return false;
}

/// Walks the focus stops of `scope` and its descendants in document
/// order.
pub const StopIterator = struct {
    tree: *const Tree,
    dfs: Tree.DfsIterator,
    /// The node whose link spans are still being handed out.
    node: ?NodeId = null,
    spans: []const element_mod.Span = &.{},
    next_span: usize = 0,

    pub fn next(self: *StopIterator) ?Focus {
        while (true) {
            if (self.node) |id| {
                while (self.next_span < self.spans.len) {
                    const i = self.next_span;
                    self.next_span += 1;
                    if (self.spans[i].isLink()) {
                        return .{ .node = id, .span = @intCast(i) };
                    }
                }
                self.node = null;
            }
            const id = self.dfs.next() orelse return null;
            const el = self.tree.getConst(id).?;
            if (hasLinkSpans(el.*)) {
                self.node = id;
                self.spans = spansOf(el.*);
                self.next_span = 0;
                continue;
            }
            if (el.isFocusable()) return .of(id);
        }
    }
};

pub fn stops(tree: *const Tree, scope: NodeId) StopIterator {
    return .{ .tree = tree, .dfs = tree.dfsUnder(scope) };
}

pub fn firstFocusable(tree: *const Tree, scope: NodeId) ?Focus {
    var it = stops(tree, scope);
    return it.next();
}

/// Next stop after `current` in document order, wrapping around.
pub fn nextFocusable(tree: *const Tree, scope: NodeId, current: ?Focus) ?Focus {
    const cur = current orelse return firstFocusable(tree, scope);
    var it = stops(tree, scope);
    var seen_current = false;
    while (it.next()) |stop| {
        if (seen_current) return stop;
        if (stop.eql(cur)) seen_current = true;
    }
    return firstFocusable(tree, scope); // wrap (or stale `current`)
}

/// Previous stop before `current` in document order, wrapping around.
pub fn prevFocusable(tree: *const Tree, scope: NodeId, current: ?Focus) ?Focus {
    const cur = current orelse return lastFocusable(tree, scope);
    var it = stops(tree, scope);
    var prev: ?Focus = null;
    while (it.next()) |stop| {
        if (stop.eql(cur)) return prev orelse lastFocusable(tree, scope);
        prev = stop;
    }
    return lastFocusable(tree, scope);
}

pub fn lastFocusable(tree: *const Tree, scope: NodeId) ?Focus {
    var it = stops(tree, scope);
    var last: ?Focus = null;
    while (it.next()) |stop| last = stop;
    return last;
}

test "focus order is document order and wraps" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const a = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "a" } });
    try tree.append(tree.rootId(), .{ .text = .{ .content = "not focusable" } });
    const box = try tree.appendId(tree.rootId(), .{ .box = .{} });
    const b = try tree.appendId(box, .{ .toggle = .{ .label = "b" } });
    const c = try tree.appendId(tree.rootId(), .{ .link = .{ .label = "c", .route = "r" } });

    const root = tree.rootId();
    try std.testing.expect(firstFocusable(&tree, root).?.eql(.of(a)));
    try std.testing.expect(nextFocusable(&tree, root, .of(a)).?.eql(.of(b)));
    try std.testing.expect(nextFocusable(&tree, root, .of(b)).?.eql(.of(c)));
    try std.testing.expect(nextFocusable(&tree, root, .of(c)).?.eql(.of(a))); // wrap
    try std.testing.expect(prevFocusable(&tree, root, .of(a)).?.eql(.of(c))); // wrap back
    try std.testing.expect(prevFocusable(&tree, root, .of(c)).?.eql(.of(b)));
}

test "disabled buttons are skipped" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.append(tree.rootId(), .{ .button = .{ .label = "off", .disabled = true } });
    const on = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "on" } });
    try std.testing.expect(firstFocusable(&tree, tree.rootId()).?.eql(.of(on)));
}

test "an in-progress button keeps its stop; a disabled one still loses it" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const running = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "Save", .in_progress = true } });
    const next = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "Cancel" } });
    // The user pressed it a moment ago — Tab must go on from here, not
    // from wherever a vanished stop would have thrown them.
    try std.testing.expect(firstFocusable(&tree, tree.rootId()).?.eql(.of(running)));
    try std.testing.expect(nextFocusable(&tree, tree.rootId(), .of(running)).?.eql(.of(next)));

    // Disabled is the stronger statement, and it wins when both are set.
    try tree.append(tree.rootId(), .{ .button = .{ .label = "Retry", .disabled = true, .in_progress = true } });
    try std.testing.expect(nextFocusable(&tree, tree.rootId(), .of(next)).?.eql(.of(running))); // wraps past it
}

test "a scope confines traversal to its subtree, wrapping inside it" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.append(tree.rootId(), .{ .button = .{ .label = "outside" } });
    const sheet = try tree.appendId(tree.rootId(), .{ .sheet = .{ .title = "Filters" } });
    const x = try tree.appendId(sheet, .{ .button = .{ .label = "x" } });
    const y = try tree.appendId(sheet, .{ .toggle = .{ .label = "y" } });
    try tree.append(tree.rootId(), .{ .button = .{ .label = "after" } });

    try std.testing.expect(firstFocusable(&tree, sheet).?.eql(.of(x)));
    try std.testing.expect(nextFocusable(&tree, sheet, .of(x)).?.eql(.of(y)));
    try std.testing.expect(nextFocusable(&tree, sheet, .of(y)).?.eql(.of(x))); // wraps inside
    try std.testing.expect(prevFocusable(&tree, sheet, .of(x)).?.eql(.of(y)));
    try std.testing.expect(lastFocusable(&tree, sheet).?.eql(.of(y)));
}

test "empty tree has no focus" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectEqual(@as(?Focus, null), firstFocusable(&tree, tree.rootId()));
    try std.testing.expectEqual(@as(?Focus, null), nextFocusable(&tree, tree.rootId(), null));
}

test "each link span is its own stop, in span order; styling spans are not" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const before = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "before" } });
    const para = try tree.appendId(tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "See the " },
        .{ .text = "terms", .route = "terms" },
        .{ .text = " and the " },
        .{ .text = "policy", .route = "policy" },
        .{ .text = ", or read on.", .strong = true },
    } } });
    const after = try tree.appendId(tree.rootId(), .{ .button = .{ .label = "after" } });

    const root = tree.rootId();
    // The paragraph itself is never a stop — only its links are, and
    // the plain and merely-styled runs contribute none.
    try std.testing.expect(!tree.getConst(para).?.isFocusable());
    const terms: Focus = .{ .node = para, .span = 1 };
    const policy: Focus = .{ .node = para, .span = 3 };
    try std.testing.expect(nextFocusable(&tree, root, .of(before)).?.eql(terms));
    try std.testing.expect(nextFocusable(&tree, root, terms).?.eql(policy));
    try std.testing.expect(nextFocusable(&tree, root, policy).?.eql(.of(after)));
    try std.testing.expect(prevFocusable(&tree, root, .of(after)).?.eql(policy));
    try std.testing.expect(prevFocusable(&tree, root, policy).?.eql(terms));
    try std.testing.expect(prevFocusable(&tree, root, terms).?.eql(.of(before)));
}
