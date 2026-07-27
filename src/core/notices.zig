//! Persistent notices and their chrome: the banner (front notice in the
//! bottom pane), the modal notices pane, and the minimized indicator.
//! State lives on the App (`notices`, `notice_state`); this module keeps
//! the tree's chrome nodes in sync with it.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const focus = @import("focus.zig");
const layout = @import("layout.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const Element = element_mod.Element;
const NodeId = tree_mod.NodeId;

pub const OwnedNotice = struct {
    title: []u8,
    description: []u8,
    route: []u8,

    pub fn deinit(self: OwnedNotice, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.description);
        gpa.free(self.route);
    }
};

/// Raises a persistent notice: a title, a description, and the route
/// its open control deep-links to. The front notice shows as a
/// banner in the bottom pane; duplicates (by title) are dropped. A
/// new notice re-surfaces minimized ones. Notices never steal focus
/// (WCAG 3.2.1) and never time out (WCAG 2.2.1) — there is
/// deliberately no auto-dismiss to offer.
pub fn notify(app: *App, title: []const u8, description: []const u8, route: []const u8) !void {
    if (title.len == 0) return error.EmptyNotice;
    for (app.notices.items) |n| {
        if (std.mem.eql(u8, n.title, title)) return;
    }
    const t = try app.gpa.dupe(u8, title);
    errdefer app.gpa.free(t);
    const d = try app.gpa.dupe(u8, description);
    errdefer app.gpa.free(d);
    const r = try app.gpa.dupe(u8, route);
    errdefer app.gpa.free(r);
    try app.notices.append(app.gpa, .{ .title = t, .description = d, .route = r });
    if (app.notice_state != .pane) app.notice_state = .banner;
    try syncNoticeChrome(app);
}

/// Dismisses the front notice. No-op when there is none.
pub fn dismissNotice(app: *App) void {
    dismissNoticeAt(app, 0);
}

/// Expands every pending notice into the modal notices pane.
pub fn openNoticesPane(app: *App) !void {
    if (app.notices.items.len == 0) return;
    app.notice_state = .pane;
    try syncNoticeChrome(app);
}

/// Collapses the banner or the notices pane to the nav pane's
/// indicator; the notices stay pending.
pub fn minimizeNotices(app: *App) void {
    if (app.notices.items.len == 0) return;
    app.notice_state = .minimized;
    syncNoticeChrome(app) catch {};
}

pub fn dismissAllNotices(app: *App) void {
    for (app.notices.items) |n| n.deinit(app.gpa);
    app.notices.clearRetainingCapacity();
    app.notice_state = .none;
    syncNoticeChrome(app) catch {};
}

pub fn dismissNoticeAt(app: *App, index: usize) void {
    if (index >= app.notices.items.len) return;
    const removed = app.notices.orderedRemove(index);
    removed.deinit(app.gpa);
    if (app.notices.items.len == 0) app.notice_state = .none;
    syncNoticeChrome(app) catch {};
}

/// Rebuilds the notice chrome (banner, pane, or indicator) to match
/// `notice_state`. Keyboard focus that lived in the old chrome moves
/// to the new chrome's first control; focus elsewhere is never
/// touched.
pub fn syncNoticeChrome(app: *App) !void {
    const tree = &app.tree;
    const focus_in_chrome = if (app.focused) |f| inNoticeChrome(app, f.node) else false;
    if (layout.findNotice(tree)) |n| tree.remove(n) catch {};
    if (layout.findNoticesPane(tree)) |p| tree.remove(p) catch {};
    if (layout.findIndicator(tree)) |i| tree.remove(i) catch {};
    if (focus_in_chrome) app.focused = null;

    const suppressed = layout.findSheet(tree) != null and app.notice_state != .none;
    switch (if (suppressed) App.NoticeState.minimized else app.notice_state) {
        .none => {},
        .banner => try installBanner(app),
        .pane => try installPane(app),
        .minimized => try installIndicator(app),
    }
    if (focus_in_chrome) {
        const anchor: ?NodeId = layout.findNoticesPane(tree) orelse
            layout.findNotice(tree) orelse
            layout.findIndicator(tree);
        if (anchor) |a| app.focused = focus.firstFocusable(tree, a);
    }
    app.invalidate();
}

fn installBanner(app: *App) !void {
    const front = app.notices.items[0];
    const notice = try installChromeRoot(app, .{ .notice = .{
        .title = front.title,
        .description = front.description,
        .route = front.route,
    } });
    if (app.notices.items.len == 1) {
        _ = try app.tree.append(notice, .{ .icon_button = .{
            .glyph = .open,
            .label = try chromeLabel(app, "Open: {s}", front.title),
        } });
    } else {
        _ = try app.tree.append(notice, .{ .icon_button = .{ .glyph = .expand, .label = "Show all notices" } });
    }
    _ = try app.tree.append(notice, .{ .icon_button = .{ .glyph = .minimize, .label = "Minimize notices" } });
    _ = try app.tree.append(notice, .{ .icon_button = .{
        .glyph = .dismiss,
        .label = try chromeLabel(app, "Dismiss: {s}", front.title),
    } });
}

fn installPane(app: *App) !void {
    const pane = try installChromeRoot(app, .{ .notices_pane = .{} });
    _ = try app.tree.append(pane, .{ .icon_button = .{ .glyph = .minimize, .label = "Minimize notices" } });
    _ = try app.tree.append(pane, .{ .button = .{
        .label = "Dismiss all",
        .on_press = .{ .ctx = app, .call = dismissAllAction },
    } });
    // The rows scroll; the header and "Dismiss all" do not. A pane is
    // capped at `sheet_min_top` from the top edge, and enough notices —
    // or few of them on a landscape phone, where that cap is most of a
    // short viewport — come to more than the cap allows. Flowed straight
    // into the pane they were simply clipped at its edge, with no way to
    // reach the rest by wheel, drag or keyboard. `scroll_region` is the
    // library's answer to exactly that and it is focusable for the same
    // reason (WCAG 2.1.1), so the hidden rows gain a keyboard route too.
    //
    // "Dismiss all" stays outside it, like the select picker's filter
    // field: the action that empties the list should not be the thing
    // that scrolls away as the list grows.
    const region = try app.tree.append(pane, .{ .scroll_region = .{ .height = 0 } });
    for (app.notices.items) |n| {
        const row = try app.tree.append(region, .{ .notice = .{
            .title = n.title,
            .description = n.description,
            .route = n.route,
        } });
        _ = try app.tree.append(row, .{ .icon_button = .{
            .glyph = .open,
            .label = try chromeLabel(app, "Open: {s}", n.title),
        } });
        _ = try app.tree.append(row, .{ .icon_button = .{
            .glyph = .dismiss,
            .label = try chromeLabel(app, "Dismiss: {s}", n.title),
        } });
    }
}

fn installIndicator(app: *App) !void {
    _ = try installChromeRoot(app, .{ .icon_button = .{ .glyph = .expand, .label = "Show notices" } });
}

/// Right after the nav in document order: chrome leads the focus
/// order regardless of its visual position in the bottom pane.
fn installChromeRoot(app: *App, el: Element) !NodeId {
    return if (layout.findNav(&app.tree)) |nav|
        app.tree.insertAfter(nav, el)
    else
        app.tree.insertFirst(app.tree.rootId(), el);
}

fn chromeLabel(app: *App, comptime fmt: []const u8, arg: []const u8) ![]const u8 {
    return std.fmt.allocPrint(app.tree.arena.allocator(), fmt, .{arg});
}

fn dismissAllAction(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    dismissAllNotices(app);
}

fn inNoticeChrome(app: *const App, id: NodeId) bool {
    var cur: ?NodeId = id;
    while (cur) |c| : (cur = app.tree.parentOf(c)) {
        switch (app.tree.getConst(c).?.role()) {
            .notice, .notices_pane, .icon_button => return true,
            else => {},
        }
    }
    return false;
}

/// The index into `notices` of the notice row an icon control
/// belongs to. Titles are unique by construction (notify dedups).
pub fn noticeIndexOf(app: *const App, icon: NodeId) ?usize {
    const parent = app.tree.parentOf(icon) orelse return null;
    const el = app.tree.getConst(parent) orelse return null;
    if (el.role() != .notice) return null;
    for (app.notices.items, 0..) |n, i| {
        if (std.mem.eql(u8, n.title, el.notice.title)) return i;
    }
    return null;
}
