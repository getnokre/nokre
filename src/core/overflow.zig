//! The folded tail of an overflowing row of actions: the `more` control
//! that stands in for the buttons and links a row could not fit, and the
//! sheet it opens to reach them.
//!
//! How many actions a row can show is the framework's decision, like the
//! nav's shape (nav.zig) — consumers declare the actions and nokre
//! draws as many as fit. Nothing opts in: a row that overflows folds,
//! and there is no arrangement a consumer has to reach for to get it. And like the nav's, the choice is a *tree*
//! decision rather than a drawing one: `semantics.roleOf` reads the
//! element kind and nothing else, so a control that opens a sheet cannot
//! be a button quietly wearing a different label. Assistive tech is told
//! what is actually there.
//!
//! It takes two steps, in this order, because neither can do the other's
//! half: layout is the only place that knows how wide the row's span
//! turned out to be, and it may not touch the tree; `syncOverflowChrome`
//! may, and runs on what layout marked (`App.performLayout`). The width
//! layout reserves for the control (`layout.moreSize`) is the same
//! whether the control is standing there yet or not, so the second pass
//! reaches the fold the first one decided and the shape cannot flicker
//! between them.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const focus = @import("focus.zig");
const layout = @import("layout.zig");
const overlays = @import("overlays.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

/// Brings every row's `more` control into line with what layout folded,
/// and reports whether the tree changed — the caller lays out again when
/// it did, because a row that just gained or lost a control is a row
/// with a different set of things standing in it.
///
/// A failed allocation leaves the shape as it was, exactly as a failed
/// nav reshape does: the wrong number of buttons showing beats a row
/// that emptied itself because an allocation did.
pub fn syncOverflowChrome(app: *App) bool {
    var changed = false;
    // Removals first, restarting the walk each time: `remove` unlinks
    // the node an in-flight iterator may be standing on. A row only
    // grows back when the viewport does, so this runs approximately
    // never.
    while (staleControl(app)) |control| {
        if (app.focused) |f| {
            // The control held focus and is about to go. Focus lands on
            // the row's last action — the trailing end, where the
            // control was standing — rather than wherever a dropped stop
            // would have thrown it (WCAG 3.2.2).
            if (f.node.eql(control)) app.focused = lastAction(app, app.tree.parentOf(control));
        }
        app.tree.remove(control) catch break;
        changed = true;
    }
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (!needsControl(app, id)) continue;
        _ = app.tree.append(id, .{ .more = .{} }) catch continue;
        changed = true;
    }
    // Same courtesy in the other direction, and checked last rather than
    // beside the append: a row that folds one button deeper than it did
    // a moment ago already has its control, so this cannot ride on the
    // pass that installs one.
    if (app.focused) |f| {
        if (foldedAction(app, f.node)) app.focused = controlOfRow(app, app.tree.parentOf(f.node));
    }
    if (dismissStaleTailSheet(app)) changed = true;
    return changed;
}

/// An open tail sheet stops being true the moment the fold behind it
/// moves. A window that widened has put those buttons back on the row —
/// leaving the sheet up would show every one of them twice, and press
/// the copy — and a row that folded deeper is hiding something the open
/// list does not name. Neither is a list worth reading, so it goes, the
/// way navigating away takes a sheet with it.
///
/// Reports whether it dismissed, because the layer leaving is a layout
/// change like any other.
fn dismissStaleTailSheet(app: *App) bool {
    const open = app.more_sheet orelse return false;
    // Already gone with a rebuilt screen: forget it, dismiss nothing.
    if (app.tree.getConst(open.sheet) == null or app.tree.getConst(open.row) == null) {
        app.more_sheet = null;
        return false;
    }
    if (listsExactly(app, open)) return false;
    overlays.dismissSheet(app);
    return true;
}

/// Whether the sheet still lists the row's folded actions, in order and
/// no others — the one thing it claims by being open.
fn listsExactly(app: *const App, open: app_mod.App.MoreSheet) bool {
    var folded = app.tree.children(open.row);
    var listed = app.tree.children(open.sheet);
    while (true) {
        const want = nextFolded(app, &folded);
        const got = nextListed(app, &listed);
        if (want == null and got == null) return true;
        if (want == null or got == null) return false;
        if (!std.mem.eql(u8, want.?, got.?)) return false;
    }
}

fn nextFolded(app: *const App, it: *tree_mod.Tree.ChildIterator) ?[]const u8 {
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.isFolded()) return el.label();
    }
    return null;
}

fn nextListed(app: *const App, it: *tree_mod.Tree.ChildIterator) ?[]const u8 {
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.foldable()) return el.label();
    }
    return null;
}

/// A `more` whose row no longer folds anything: the viewport grew, or
/// the screen was rebuilt with fewer actions.
fn staleControl(app: *const App) ?NodeId {
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.* != .more) continue;
        const row = app.tree.parentOf(id) orelse return id;
        if (!foldsAnything(app, row)) return id;
    }
    return null;
}

/// A row layout folded that has no control standing in for it yet.
fn needsControl(app: *const App, row: NodeId) bool {
    if (!foldsAnything(app, row)) return false;
    var it = app.tree.children(row);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.* == .more) return false;
    }
    return true;
}

fn foldsAnything(app: *const App, row: NodeId) bool {
    var it = app.tree.children(row);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.isFolded()) return true;
    }
    return false;
}

fn foldedAction(app: *const App, id: NodeId) bool {
    const el = app.tree.getConst(id) orelse return false;
    return el.isFolded();
}

fn controlOfRow(app: *const App, row: ?NodeId) ?focus.Focus {
    const r = row orelse return null;
    var it = app.tree.children(r);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.* == .more) return .of(c);
    }
    return null;
}

fn lastAction(app: *const App, row: ?NodeId) ?focus.Focus {
    const r = row orelse return null;
    var last: ?NodeId = null;
    var it = app.tree.children(r);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.foldable()) last = c;
    }
    return if (last) |l| .of(l) else null;
}

/// Opens the folded tail: a sheet holding the actions the row could not
/// show — the one that gave up its slot to the control first, then the
/// ones that had already overflowed, in the order the row declared them.
///
/// The sheet lists the *elements*, not a menu of names: each is the
/// button or link itself, restated, carrying the same action or route,
/// the same emphasis, and the same disabled or in-progress state. A
/// row's overflow must not change what pressing a thing does, or whether
/// it can be pressed at all.
pub fn presentMoreSheet(app: *App, control: NodeId) !void {
    const row = app.tree.parentOf(control) orelse return;
    const sheet = try overlays.presentSheet(app, element_mod.more_label);
    app.more_sheet = .{ .row = row, .sheet = sheet };
    var it = app.tree.children(row);
    while (it.next()) |child| {
        const el = app.tree.getConst(child).?;
        if (!el.isFolded()) continue;
        var restated = el.*;
        // In the sheet it is itself again, standing on its own — the
        // whole element, so a button arrives as a button and a link as a
        // link, carrying everything it carried on the row.
        restated.setFolded(false);
        _ = try app.tree.append(sheet, restated);
    }
}

/// The folded-tail sheet a press inside it is about to close, read
/// *before* the action runs — the action may navigate, or open a layer
/// of its own, and then there is no telling from the outside which sheet
/// this press came from. Null for every other activation.
///
/// A press that does nothing (disabled, or work already running) closes
/// nothing: the sheet going away would report an action that never ran.
pub fn tailSheetOf(app: *const App, id: NodeId) ?NodeId {
    const open = app.more_sheet orelse return null;
    if (!app.tree.isDescendant(id, open.sheet)) return null;
    const el = app.tree.getConst(id) orelse return null;
    if (!el.foldable() or !el.isInteractive()) return null;
    return open.sheet;
}

/// Closes it, the way choosing a row closes a picker: the sheet is the
/// row's tail, not a screen. No-op when the action already took the
/// sheet with it — a navigation rebuilds the tree, and what it put there
/// instead is not ours to dismiss.
pub fn closeTailSheet(app: *App, sheet: NodeId) void {
    const open = layout.findSheet(&app.tree) orelse return;
    if (!open.eql(sheet)) return;
    overlays.dismissSheet(app);
}
