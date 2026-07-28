//! Semantic queries, testing-library style: find nodes by what users
//! (and screen readers) perceive, never by tree position or index.
//! `query*` returns null for absence checks; `get*` (on the harness)
//! fails loudly, listing every label that does exist.

const std = @import("std");
const diag = @import("diag.zig");
const tree_mod = @import("../core/tree.zig");
const element_mod = @import("../core/element.zig");
const focus = @import("../core/focus.zig");

const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const Role = element_mod.Role;

/// Whether the element is on the screen at all. Queries address what a
/// user perceives, and an action its row folded away perceives as absent:
/// the `more` control stands where it was, and the sheet that control
/// opens is the one place its words appear (overflow.zig). Returning it
/// would hand a test a node no tap could reach — and hide the fact that
/// the row folded, which is usually the bug.
fn onScreen(el: element_mod.Element) bool {
    return !el.isFolded();
}

/// First node whose accessible label equals `label` exactly.
pub fn queryByLabel(tree: *const Tree, label: []const u8) ?NodeId {
    var it = tree.dfs();
    while (it.next()) |id| {
        const el = tree.getConst(id).?;
        if (!onScreen(el.*)) continue;
        if (el.label().len > 0 and std.mem.eql(u8, el.label(), label)) return id;
    }
    return null;
}

/// First node whose accessible label contains `needle`.
pub fn queryByLabelContaining(tree: *const Tree, needle: []const u8) ?NodeId {
    var it = tree.dfs();
    while (it.next()) |id| {
        const el = tree.getConst(id).?;
        if (!onScreen(el.*)) continue;
        if (std.mem.indexOf(u8, el.label(), needle) != null) return id;
    }
    return null;
}

/// First node with the given role whose accessible label equals `name` —
/// role plus name, never an index: indexes address tree positions, and
/// users don't perceive those.
pub fn queryByRole(tree: *const Tree, role: Role, name: []const u8) ?NodeId {
    var it = tree.dfs();
    while (it.next()) |id| {
        const el = tree.getConst(id).?;
        if (!onScreen(el.*)) continue;
        if (el.role() == role and std.mem.eql(u8, el.label(), name)) return id;
    }
    return null;
}

/// First inline link whose words equal `label`. Link spans are not
/// nodes, so they cannot come back as a `NodeId` — but they are
/// controls, and a control tests cannot reach is a control consumers
/// cannot trust.
pub fn queryLink(tree: *const Tree, label: []const u8) ?focus.Focus {
    var it = tree.dfs();
    while (it.next()) |id| {
        const spans = focus.spansOf(tree.getConst(id).?.*);
        for (spans, 0..) |span, i| {
            if (!span.isLink()) continue;
            if (std.mem.eql(u8, span.text, label)) return .{ .node = id, .span = @intCast(i) };
        }
    }
    return null;
}

/// The words of the link a focus stop names, for diagnostics.
pub fn linkLabel(tree: *const Tree, stop: focus.Focus) ?[]const u8 {
    const el = tree.getConst(stop.node) orelse return null;
    const index = stop.span orelse return el.label();
    const spans = focus.spansOf(el.*);
    return if (index < spans.len) spans[index].text else null;
}

pub fn countByRole(tree: *const Tree, role: Role) usize {
    var it = tree.dfs();
    var n: usize = 0;
    while (it.next()) |id| {
        const el = tree.getConst(id).?;
        if (onScreen(el.*) and el.role() == role) n += 1;
    }
    return n;
}

/// Diagnoses a failed `get*`: names what was searched for and lists every
/// labeled node on screen, then returns the error the caller propagates.
pub fn noMatch(tree: *const Tree, what: []const u8, needle: []const u8) error{NoSuchElement} {
    diag.print("no element with {s} \"{s}\"; labeled nodes on screen:\n", .{ what, needle });
    var it = tree.dfs();
    var any = false;
    while (it.next()) |id| {
        const el = tree.getConst(id).?;
        // Inline links are controls without nodes of their own; a
        // listing that omitted them would send the reader hunting for a
        // link that is right there.
        for (focus.spansOf(el.*)) |span| {
            if (!span.isLink()) continue;
            diag.print("  link (inline) \"{s}\"\n", .{span.text});
            any = true;
        }
        if (el.label().len == 0) continue;
        // A folded button is off the screen, so the queries above cannot
        // return it — but leaving it out of the listing would send the
        // reader hunting for a button that is on the screen's other side
        // of a press. Name it, and name where it went.
        if (!onScreen(el.*)) {
            diag.print("  {s} \"{s}\" (folded into this row's \"More\" sheet)\n", .{ @tagName(el.role()), el.label() });
            any = true;
            continue;
        }
        diag.print("  {s} \"{s}\"\n", .{ @tagName(el.role()), el.label() });
        any = true;
    }
    if (!any) diag.print("  (none)\n", .{});
    return error.NoSuchElement;
}

// ---- tests ----

const testing = std.testing;

test "queries find nodes by label and by role+name" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    _ = try tree.append(tree.rootId(), .{ .button = .{ .label = "Save" } });
    const cancel = try tree.append(tree.rootId(), .{ .button = .{ .label = "Cancel all" } });
    _ = try tree.append(tree.rootId(), .{ .text = .{ .content = "Cancel all" } });

    try testing.expect(queryByLabel(&tree, "Cancel all").?.eql(cancel));
    try testing.expectEqual(@as(?NodeId, null), queryByLabel(&tree, "Cancel"));
    try testing.expect(queryByLabelContaining(&tree, "Cancel").?.eql(cancel));
    try testing.expect(queryByRole(&tree, .button, "Cancel all").?.eql(cancel));
    try testing.expectEqual(@as(?NodeId, null), queryByRole(&tree, .toggle, "Cancel all"));
    try testing.expectEqual(@as(usize, 2), countByRole(&tree, .button));
}
