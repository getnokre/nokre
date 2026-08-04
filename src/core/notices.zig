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
    icon: ?element_mod.IconName,
    important: bool,

    pub fn deinit(self: OwnedNotice, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.description);
        gpa.free(self.route);
    }
};

/// What `notify` raises. Quiet by default: interrupting is the thing a
/// notice has to ask for, not the thing it has to remember to decline.
pub const Notify = struct {
    title: []const u8,
    description: []const u8 = "",
    /// Route reference the notice deep-links to via its open control.
    route: []const u8 = "",
    /// Leading mark, decorative: the title stays the accessible name,
    /// so the icon adds recognition without carrying information the
    /// words don't state.
    icon: ?element_mod.IconName = null,
    /// An important notice claims the banner and re-surfaces minimized
    /// notices; a quiet one only joins the pending list behind the nav
    /// pane's indicator. The split is behavioral, not visual — it
    /// decides who interrupts, and the pane groups by it.
    important: bool = false,
};

/// Raises a persistent notice. The front notice shows as a banner in
/// the bottom pane; duplicates (by title) are dropped. Notices never
/// steal focus (WCAG 3.2.1) and never time out (WCAG 2.2.1) — there is
/// deliberately no auto-dismiss to offer.
///
/// Important notices interrupt: the banner appears (unless the pane is
/// already open, which shows everything). Quiet ones don't: they
/// accumulate behind the indicator, which appears if no chrome is up.
/// Important notices stand in front of quiet ones, arrival order
/// within each group, so the banner is always an important notice
/// while any is pending.
pub fn notify(app: *App, opts: Notify) !void {
    if (opts.title.len == 0) return error.EmptyNotice;
    for (app.notices.items) |n| {
        if (std.mem.eql(u8, n.title, opts.title)) return;
    }
    const t = try app.gpa.dupe(u8, opts.title);
    errdefer app.gpa.free(t);
    const d = try app.gpa.dupe(u8, opts.description);
    errdefer app.gpa.free(d);
    const r = try app.gpa.dupe(u8, opts.route);
    errdefer app.gpa.free(r);
    const owned: OwnedNotice = .{
        .title = t,
        .description = d,
        .route = r,
        .icon = opts.icon,
        .important = opts.important,
    };
    if (opts.important) {
        var i: usize = 0;
        while (i < app.notices.items.len and app.notices.items[i].important) i += 1;
        try app.notices.insert(app.gpa, i, owned);
        if (app.notice_state != .pane) app.notice_state = .banner;
    } else {
        try app.notices.append(app.gpa, owned);
        if (app.notice_state == .none) app.notice_state = .minimized;
    }
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
    if (app.notices.items.len == 0) {
        app.notice_state = .none;
    } else if (app.notice_state == .banner and !app.notices.items[0].important) {
        // Important notices stand in front, so a quiet front means none
        // remain. The banner was the important ones' surface; quiet
        // notices never claim it — not even by succession.
        app.notice_state = .minimized;
    }
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
        .icon = front.icon,
    } });
    if (app.notices.items.len == 1) {
        try app.tree.append(notice, .{ .icon_button = .{
            .glyph = .open,
            .label = try chromeLabel(app, app.chrome.open_prefix, front.title),
        } });
    } else {
        try app.tree.append(notice, .{ .icon_button = .{ .glyph = .expand, .label = app.chrome.show_all_notices } });
    }
    try app.tree.append(notice, .{ .icon_button = .{ .glyph = .minimize, .label = app.chrome.minimize_notices } });
    try app.tree.append(notice, .{ .icon_button = .{
        .glyph = .dismiss,
        .label = try chromeLabel(app, app.chrome.dismiss_prefix, front.title),
    } });
}

fn installPane(app: *App) !void {
    const pane = try installChromeRoot(app, .{ .notices_pane = .{ .title = app.chrome.notices } });
    // Both header controls pin to the trailing corner, dismiss-all
    // inward and minimize outermost-last (`pinHeaderControl`), so
    // document order is the visual order. Minimize keeps the corner
    // itself: that slot is where a modal closes (the sheet's close),
    // and the reflex press it collects must park the notices, not
    // destroy them.
    try app.tree.append(pane, .{ .icon_button = .{ .glyph = .dismiss_all, .label = app.chrome.dismiss_all_notices } });
    try app.tree.append(pane, .{ .icon_button = .{ .glyph = .minimize, .label = app.chrome.minimize_notices } });
    // The rows scroll; the header does not. A pane is capped at
    // `sheet_min_top` from the top edge, and enough notices — or few of
    // them on a landscape phone, where that cap is most of a short
    // viewport — come to more than the cap allows. Flowed straight
    // into the pane they were simply clipped at its edge, with no way to
    // reach the rest by wheel, drag or keyboard. `scroll_region` is the
    // library's answer to exactly that and it is focusable for the same
    // reason (WCAG 2.1.1), so the hidden rows gain a keyboard route too.
    // Dismiss-all lives in the header for the same reason the picker's
    // filter stays outside its region: the control that empties the
    // list must not scroll away as the list grows.
    const region = try app.tree.appendId(pane, .{ .scroll_region = .{ .height = 0 } });
    // Important notices lead the list (notify keeps them in front), and
    // when both kinds are pending a caption heads each group. Framework
    // words in the framework's own language (`App.Chrome`): no consumer
    // named these groups, so no consumer's data can — only their
    // catalog. Plain text, not headings — two words of chrome should not
    // enter a screen reader's heading navigation ahead of the
    // consumer's page.
    const split = blk: {
        var i: usize = 0;
        while (i < app.notices.items.len and app.notices.items[i].important) i += 1;
        break :blk i;
    };
    const grouped = split > 0 and split < app.notices.items.len;
    for (app.notices.items, 0..) |n, i| {
        if (grouped and i == 0) try app.tree.append(region, groupLabel(app.chrome.important));
        if (grouped and i == split) try app.tree.append(region, groupLabel(app.chrome.other));
        const row = try app.tree.appendId(region, .{ .notice = .{
            .title = n.title,
            .description = n.description,
            .route = n.route,
            .icon = n.icon,
        } });
        try app.tree.append(row, .{ .icon_button = .{
            .glyph = .open,
            .label = try chromeLabel(app, app.chrome.open_prefix, n.title),
        } });
        try app.tree.append(row, .{ .icon_button = .{
            .glyph = .dismiss,
            .label = try chromeLabel(app, app.chrome.dismiss_prefix, n.title),
        } });
    }
}

/// A pane group's caption: small and dark like a notice's description —
/// a caption over the rows, not a rival to their titles.
fn groupLabel(words: []const u8) Element {
    return .{ .text = .{ .content = words, .style = .{ .scale = .small, .ink = .dark } } };
}

fn installIndicator(app: *App) !void {
    _ = try installChromeRoot(app, .{ .icon_button = .{ .glyph = .expand, .label = app.chrome.show_notices } });
}

/// Right after the nav in document order: chrome leads the focus
/// order regardless of its visual position in the bottom pane.
fn installChromeRoot(app: *App, el: Element) !NodeId {
    return if (layout.findNav(&app.tree)) |nav|
        app.tree.insertAfter(nav, el)
    else
        app.tree.insertFirst(app.tree.rootId(), el);
}

/// A notice control's name: the framework's word for what it does, then
/// the notice it does it to. A prefix and a join, never a format string
/// — see `Chrome.open_prefix` for why a runtime format is not on offer.
fn chromeLabel(app: *App, prefix: []const u8, title: []const u8) ![]const u8 {
    return std.mem.concat(app.tree.arena.allocator(), u8, &.{ prefix, title });
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
