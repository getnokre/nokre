//! Synthetic input driver. Everything goes through `App.dispatch` — the
//! same pipeline production shells use — so e2e tests exercise hit
//! testing, focus, and event handling for real.

const std = @import("std");
const diag = @import("diag.zig");
const app_mod = @import("../core/app.zig");
const tree_mod = @import("../core/tree.zig");
const element_mod = @import("../core/element.zig");
const event_mod = @import("../core/event.zig");
const focus = @import("../core/focus.zig");
const geometry = @import("../core/geometry.zig");
const input = @import("../core/input.zig");
const layout = @import("../core/layout.zig");
const queries = @import("queries.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

/// Taps the center of the node, exactly like a finger would — and fails
/// if a finger couldn't: the target must be interactive and the hit test
/// at that point must actually resolve to it. A tap that would silently
/// land elsewhere is a lie, not a test.
pub fn tap(app: *App, id: NodeId) !void {
    app.performLayout();
    const el = app.tree.getConst(id) orelse return error.InvalidNode;
    // Folded is not disabled, and saying "not interactive" here would
    // send the test looking at the button instead of at the row: it is
    // off the screen because the row ran out of width, and the way to it
    // is the way a user takes (overflow.zig).
    if (el.isFolded()) {
        diag.print("tap: \"{s}\" did not fit its row and is folded into the row's \"More\" sheet — press More first, like a user would, or give the row more width\n", .{el.label()});
        return error.Folded;
    }
    if (!el.isFocusable()) {
        diag.print("tap: \"{s}\" is not interactive (static or disabled)\n", .{el.label()});
        return error.NotInteractive;
    }
    // A control with work in flight is focusable on purpose (it keeps
    // the stop the user's own press put focus on), so the check above
    // lets it through — and a tap on it does nothing at all. Silence
    // there would read as a passing test of an action that never ran.
    if (inProgress(el.*)) {
        diag.print("tap: \"{s}\" has work in progress — it takes no press until that work finishes; settle the work first, or clear in_progress if the test meant to press it again\n", .{el.label()});
        return error.InProgress;
    }
    const center = app.tree.rectOf(id).center();
    const hit = app.hitTest(center) orelse {
        diag.print("tap: \"{s}\" is not visible at its center ({d},{d}) — scrolled out of view or clipped; scroll it into view first, like a user would\n", .{ el.label(), center.x, center.y });
        return error.NotVisible;
    };
    if (!hit.on(id)) {
        const other = app.tree.getConst(hit.node).?;
        diag.print("tap: \"{s}\" is obscured — a tap at its center lands on {s} \"{s}\"\n", .{ el.label(), @tagName(other.role()), other.label() });
        return error.Obscured;
    }
    try app.tap(center);
}

/// The three controls that can have work in flight, asked as one
/// question — each keeps its focus stop while it does, so `isFocusable`
/// cannot answer this and every driver verb that presses needs the same
/// answer (`Toggle.in_progress`).
fn inProgress(el: element_mod.Element) bool {
    return switch (el) {
        .button => |b| b.in_progress,
        .toggle => |t| t.in_progress,
        .checkbox => |c| c.in_progress,
        else => false,
    };
}

/// Taps an inline link at the middle of its first rect — the same
/// checks `tap` makes, against the geometry the renderer underlined.
/// A link that wraps is tapped on its first line, where a reader's
/// finger goes.
pub fn tapLink(app: *App, stop: focus.Focus) !void {
    app.performLayout();
    const span_index = stop.span orelse return tap(app, stop.node);
    var buf: [layout.max_span_rects]geometry.Rect = undefined;
    const rects = input.spanRectsOf(app, stop.node, span_index, &buf);
    const label = queries.linkLabel(&app.tree, stop) orelse "";
    if (rects.len == 0) {
        diag.print("tapLink: \"{s}\" occupies no space — the paragraph has not been laid out, or the link's words wrapped away\n", .{label});
        return error.NotVisible;
    }
    const center = rects[0].center();
    const hit = app.hitTest(center) orelse {
        diag.print("tapLink: \"{s}\" is not visible at ({d},{d}) — scrolled out of view or clipped; scroll it into view first, like a user would\n", .{ label, center.x, center.y });
        return error.NotVisible;
    };
    if (!hit.eql(stop)) {
        const other = app.tree.getConst(hit.node).?;
        diag.print("tapLink: \"{s}\" is obscured — a tap on it lands on {s} \"{s}\"\n", .{ label, @tagName(other.role()), other.label() });
        return error.Obscured;
    }
    try app.tap(center);
}

pub fn pressKey(app: *App, key: event_mod.Key, mods: event_mod.Modifiers) !void {
    try app.dispatch(.{ .key_down = .{ .key = key, .mods = mods } });
}

/// Types committed text into whatever is focused.
pub fn typeText(app: *App, bytes: []const u8) !void {
    try app.dispatch(.{ .text = .{ .bytes = bytes } });
}

/// Drives a full IME composition sequence ending in a commit.
pub fn composeText(app: *App, composition: []const u8, committed: []const u8) !void {
    try app.dispatch(.{ .ime = .start });
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = composition, .cursor = composition.len } } });
    try app.dispatch(.{ .ime = .{ .commit = .{ .text = committed } } });
}

pub fn scroll(app: *App, id: NodeId, delta_y: i32) !void {
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(id).center(), .delta_y = delta_y } });
}

/// Horizontal scroll over the element — a trackpad swipe across a
/// segmented track.
pub fn scrollX(app: *App, id: NodeId, delta_x: i32) !void {
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(id).center(), .delta_y = 0, .delta_x = delta_x } });
}

/// The whole back gesture: a drag in from the leading edge, past the
/// point of no return, and released — what a finger does when it means
/// "back" and nothing more. Tests that care about the threshold itself
/// dispatch `.edge_pan` steps directly; this is the one-liner for tests
/// that only care that the gesture navigates.
pub fn edgePanBack(app: *App) !void {
    const from: event_mod.EdgePan.Edge = if (app.direction == .rtl) .right else .left;
    // Comfortably past any threshold: the far edge of the viewport is
    // the most a real drag can ever report.
    try app.dispatch(.{ .edge_pan = .{ .from = from, .dx = 0, .phase = .begin } });
    try app.dispatch(.{ .edge_pan = .{ .from = from, .dx = app.viewport.w, .phase = .move } });
    try app.dispatch(.{ .edge_pan = .{ .from = from, .dx = app.viewport.w, .phase = .end } });
}

/// Tab until the given node is focused; errors if a full cycle never
/// reaches it (i.e. the node is not keyboard-reachable).
pub fn focusVia(app: *App, id: NodeId) !void {
    var steps: usize = 0;
    // The hop budget counts focus *stops*, not nodes: every link span in
    // a text or heading is its own stop, so a link-heavy screen has more
    // stops than nodes and a node-count budget would give up mid-cycle —
    // a false NotKeyboardReachable. One extra full node count on top is
    // slack, not precision; the point of the limit is only to terminate.
    var limit = 2 * app.tree.nodes.items.len + 1;
    var it = app.tree.dfs();
    while (it.next()) |n| {
        const spans = switch (app.tree.getConst(n).?.*) {
            .text => |t| t.spans,
            .heading => |h| h.spans,
            else => continue,
        };
        for (spans) |s| {
            if (s.route != null) limit += 1;
        }
    }
    while (steps < limit) : (steps += 1) {
        try pressKey(app, .tab, .{});
        if (app.focused) |f| {
            if (f.on(id)) return;
        }
    }
    return error.NotKeyboardReachable;
}
