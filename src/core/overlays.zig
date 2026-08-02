//! The modal layers above content: the bottom sheet (`App.presentSheet`)
//! and the select picker (opened by activating a `select`). While one is
//! open the rest of the tree is inert — `App.focusScope` and hit testing
//! enforce that; this module owns their lifecycle and focus hand-off.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const focus = @import("focus.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");
const nav_mod = @import("nav.zig");
const notices = @import("notices.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

// ---- sheet ----

/// Opens a modal bottom sheet and returns its node to fill with
/// content. While it is open the rest of the tree is inert: focus,
/// taps, and scrolling stay inside. A close control (×, accessible
/// name "Close") is pinned to the header corner — an inescapable
/// sheet cannot be built — and Esc or tapping outside also dismiss.
/// Focus moves in now and returns to the invoking element on
/// dismissal.
pub fn presentSheet(app: *App, title: []const u8) !NodeId {
    closePicker(app, null); // an in-flight choice does not survive a new layer
    // Whatever this sheet is, it is not the one a folded row opened —
    // `overflow.presentMoreSheet` says so itself, afterwards.
    app.more_sheet = null;
    const sheet = try app.tree.append(app.tree.rootId(), .{ .sheet = .{ .title = title } });
    // A sheet without its close control is inescapable chrome; if the
    // control cannot be built, neither is the sheet.
    errdefer app.tree.remove(sheet) catch {};
    _ = try app.tree.append(sheet, .{ .sheet_close = .{ .label = app.chrome.close } });
    app.sheet_return_focus = app.focused;
    app.focused = focus.firstFocusable(&app.tree, sheet);
    // The sheet wins the bottom pane; the banner or notices pane
    // waits as the minimized indicator until dismissal.
    try notices.syncNoticeChrome(app);
    app.invalidate();
    return sheet;
}

/// No-op when no sheet is open.
pub fn dismissSheet(app: *App) void {
    const sheet = layout.findSheet(&app.tree) orelse return;
    closePicker(app, null); // its owner may be about to go with the sheet
    app.more_sheet = null;
    app.tree.remove(sheet) catch {};
    app.focused = if (app.sheet_return_focus) |f|
        (if (app.tree.getConst(f.node) != null) f else null)
    else
        null;
    app.sheet_return_focus = null;
    notices.syncNoticeChrome(app) catch {};
    app.invalidate();
}

// ---- picker ----

/// Option count at which the picker gains a filter field: fewer
/// rows scan faster by eye than by typing.
const picker_filter_min = 8;

/// Opens the modal option picker for a select: its label as the
/// title, one row per option, focus on the current choice. Long
/// lists (>= `picker_filter_min` options) get a filter field pinned
/// above the rows, focused on open — those lists want typing, not
/// scanning. Stacks above everything, an open sheet included.
pub fn openPicker(app: *App, select_id: NodeId) !void {
    if (layout.findPicker(&app.tree) != null) return;
    const sel = app.tree.getConst(select_id).?.select;
    const picker = try app.tree.append(app.tree.rootId(), .{ .picker = .{
        .title = sel.label,
        .option_count = sel.options.len,
    } });
    const filtered = sel.options.len >= picker_filter_min;
    if (filtered) {
        _ = try app.tree.append(picker, .{ .text_input = .{
            .label = "Filter",
            .on_change = .{ .ctx = app, .call = onPickerFilter },
        } });
    }
    const region = try app.tree.append(picker, .{ .scroll_region = .{ .height = 0 } });
    try fillPickerRows(app, region, sel, "");
    app.focused = if (filtered)
        focus.firstFocusable(&app.tree, picker)
    else blk: {
        var it = app.tree.children(region);
        while (it.next()) |c| {
            const el = app.tree.getConst(c).?;
            if (el.role() == .picker_item and el.picker_item.selected) break :blk .of(c);
        }
        break :blk null;
    };
    app.picker_owner = select_id;
    app.invalidate();
    input.revealFocused(app);
}

/// One row per option whose label contains `filter`
/// (ASCII-case-insensitively); "No matches" words when none does.
fn fillPickerRows(app: *App, region: NodeId, sel: element_mod.Select, filter: []const u8) !void {
    // ASCII-only case folding; Unicode options still match exactly.
    // Full case folding needs tables nokre doesn't carry.
    for (sel.options, 0..) |opt, i| {
        if (filter.len > 0 and std.ascii.indexOfIgnoreCase(opt, filter) == null) continue;
        _ = try app.tree.append(region, .{ .picker_item = .{
            .label = opt,
            .selected = i == sel.selected,
            .index = i,
        } });
    }
    if (app.tree.childCount(region) == 0) {
        _ = try app.tree.append(region, .{ .text = .{ .content = "No matches" } });
    }
}

fn onPickerFilter(ctx: ?*anyopaque, value: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    refilterPicker(app, value) catch {};
}

/// Rebuilds the picker's rows to the options matching `filter`.
fn refilterPicker(app: *App, filter: []const u8) !void {
    const picker = layout.findPicker(&app.tree) orelse return;
    const owner = app.picker_owner orelse return;
    // The tree can rebuild under an open picker; a stale owner filters
    // nothing rather than dereferencing a dead generation, the same
    // tolerance `closePicker` keeps.
    const sel = (app.tree.getConst(owner) orelse return).select;
    var region: ?NodeId = null;
    var it = app.tree.children(picker);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .scroll_region) region = c;
    }
    const reg = region orelse return;
    while (true) {
        var cit = app.tree.children(reg);
        const c = cit.next() orelse break;
        try app.tree.remove(c);
    }
    if (app.tree.get(reg)) |el| el.scroll_region.offset = 0;
    try fillPickerRows(app, reg, sel, filter);
    app.invalidate();
}

/// The collapsed nav's picker: the roster as rows, the current section
/// selected, opened by the chip that stands in for it
/// (`nav.syncNavChrome`). It is the select's picker in every respect but
/// where the options come from — the App's roster rather than an
/// element's `options` — so the modal layer, the focus hand-off, the
/// keyboard, and Esc are all the same code and cannot drift apart.
///
/// The title is the framework's own word, in the app's language
/// (`App.Chrome.sections`): no consumer named this control, so no
/// consumer's *data* can name it — only their catalog can. It is not
/// drawn — a card standing on the chip is named by the chip
/// (`renderer.drawNavMenu`) — but it is still what assistive tech is
/// told the dialog is called, which is the job it was written for.
pub fn openNavPicker(app: *App, nav_current: NodeId) !void {
    if (layout.findPicker(&app.tree) != null) return;
    // The same list the chip was built from, so the row it selects and
    // the row a choice commits are the same numbering. On an off-roster
    // screen that list ends with the screen itself: a combo box whose
    // value is one of its own options, rather than a chip naming
    // something the list it opens does not contain.
    var buf: nav_mod.RosterBuf = undefined;
    const roster = nav_mod.effectiveRoster(app, &buf);
    const current = nav_mod.currentIndex(app);
    const picker = try app.tree.append(app.tree.rootId(), .{ .picker = .{
        .title = app.chrome.sections,
        .option_count = roster.len,
        .above_nav = true,
    } });
    const region = try app.tree.append(picker, .{ .scroll_region = .{ .height = 0 } });
    // A 2–5 roster (plus at most the screen's own entry) is always under
    // `picker_filter_min`, so there is no filter field to build and no
    // filtered/unfiltered split to keep: row position and roster index
    // stay the same number.
    for (roster, 0..) |item, i| {
        _ = try app.tree.append(region, .{ .picker_item = .{
            .label = item.label,
            .selected = if (current) |c| c == i else false,
            .index = i,
            .icon = item.icon,
        } });
    }
    app.focused = blk: {
        var it = app.tree.children(region);
        while (it.next()) |c| {
            if (app.tree.getConst(c).?.picker_item.selected) break :blk .of(c);
        }
        break :blk focus.firstFocusable(&app.tree, picker);
    };
    app.picker_owner = nav_current;
    app.invalidate();
    input.revealFocused(app);
}

/// Removes the picker; commits `choice` to the owner when given — the
/// select's option, or the nav's section. Focus returns to the owner.
/// No-op when none is open.
pub fn closePicker(app: *App, choice: ?usize) void {
    const picker = layout.findPicker(&app.tree) orelse return;
    app.tree.remove(picker) catch {};
    const owner = app.picker_owner;
    app.picker_owner = null;
    app.focused = if (owner) |id|
        (if (app.tree.getConst(id) != null) .of(id) else null)
    else
        null;
    app.invalidate();
    const el = app.tree.get(owner orelse return) orelse return;
    switch (el.*) {
        .select => |*s| {
            const idx = choice orelse return;
            if (idx >= s.options.len or idx == s.selected) return;
            s.selected = idx;
            s.on_select.invoke(idx);
        },
        .nav_current => {
            const idx = choice orelse return;
            var buf: nav_mod.RosterBuf = undefined;
            const roster = nav_mod.effectiveRoster(app, &buf);
            if (idx >= roster.len) return;
            // The row's rule, reached by the other shape: a push, and a
            // no-op when the screen you picked is the one showing. The
            // select's arm declines the same no-op for the same reason.
            // The screen's own entry is declined by exactly that rule
            // and needs no arm of its own — it carries the current
            // reference, so `isCurrent` recognizes it.
            const route = roster[idx].route;
            if (nav_mod.isCurrent(app, route)) return;
            app.router.push(app, route) catch return;
            // After the push, not before: the rebuild resyncs the nav
            // and the chip the owner id named is gone. Focus follows the
            // chrome to the node that replaced it, so a keyboard user
            // keeps their place (the `nav_item` arm of `input.activate`
            // does this for the row).
            app.focused = if (layout.findNav(&app.tree)) |nav| blk: {
                var it = app.tree.children(nav);
                break :blk if (it.next()) |c| .of(c) else null;
            } else null;
        },
        else => {},
    }
}

/// The option index a picker row commits: carried on the row itself,
/// because filtering breaks the row-position/option-index identity.
pub fn pickerIndexOf(app: *const App, item: NodeId) ?usize {
    const el = app.tree.getConst(item) orelse return null;
    return el.picker_item.index;
}

/// ↑/↓ between option rows, clamped at the ends — no wrap, like a
/// native select.
pub fn movePickerFocus(app: *App, item: NodeId, delta: i32) void {
    const region = app.tree.parentOf(item) orelse return;
    var prev: ?NodeId = null;
    var it = app.tree.children(region);
    while (it.next()) |c| {
        if (c.eql(item)) {
            const next = if (delta < 0) prev else it.next();
            if (next) |n| {
                app.focused = .of(n);
                app.needs_frame = true;
                input.revealFocused(app);
            }
            return;
        }
        prev = c;
    }
}
