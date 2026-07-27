//! The app-level navigation chrome: the roster of destinations, and the
//! two shapes it renders as. `App.setNav` records the set; `syncNavChrome`
//! decides — every time the viewport, the direction, or the current route
//! changes — whether the bottom pane shows the row of `nav_item`s or the
//! single `nav_current` chip standing in for all of them.
//!
//! The choice is a *tree* decision rather than a layout one, and it has
//! to be: `semantics.roleOf` reads the element kind and nothing else, so
//! a row of links and a chip that opens a menu cannot be the same node
//! wearing two hats. Assistive tech is told what is actually there.
//!
//! Both shapes draw the same list: `effectiveRoster`, which is the
//! consumer's destinations plus — on a screen that is none of them — the
//! screen itself. Everything downstream reads that one list, which is
//! what keeps the two shapes from needing separate answers to "what if
//! the route is off the roster": there is no such route. The chip finds
//! a match because one was made for it, and the row's width question is
//! asked of a list the extra entry is already in, so nothing about the
//! collapse threshold had to learn this feature exists.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const layout = @import("layout.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

/// A destination, as consumers declare it (`setNav`): where it goes and
/// the mark it wears. Deliberately no label — the route table already
/// says what the screen is called (`RouteDef.title`), and a roster that
/// repeated it would be a second place for the same fact to be wrong,
/// with the nav and the screen's own chrome free to disagree.
pub const Destination = struct {
    /// A route *name*, never a reference: a destination is a place the
    /// app always has, and an argument would make it one particular
    /// screen. `setNav` refuses a route that takes any.
    route: []const u8,
    /// The destination's glyph, leading its label. Required, not
    /// optional: the roster is a closed 2–5 set drawn as one row, and
    /// a row where some items have icons and others do not is worse
    /// than either uniform answer.
    icon: element_mod.IconName,
};

/// The most destinations a roster may declare (`setNav`).
pub const max_nav_items = 5;

/// One line of the list both shapes draw: a declared destination, or the
/// screen standing in for itself. Also what the App keeps its roster in,
/// resolved once by `setNav` — the tree holds whichever *shape* fits the
/// viewport, so the list itself has to live somewhere that survives
/// reshaping.
///
/// Borrowed, never owned — every field points into the route table,
/// which outlives the App (`Router.init` holds the slice it was given),
/// and the tree copies what it keeps.
pub const RosterItem = struct {
    /// What the line is called: the route's `RouteDef.title`, resolved
    /// once — by `setNav` for a destination, by the router for the
    /// screen standing in for itself.
    label: []const u8,
    /// What activating it navigates to. A destination carries its route
    /// *name*; the off-roster entry carries the current **reference**,
    /// arguments and all, so `isCurrent` recognizes it and declines. The
    /// name alone would push a bare `ticket` and fail its arity.
    route: []const u8,
    icon: element_mod.IconName,
    /// Set on the one entry that is not a destination: the row draws it
    /// as a `nav_here` rather than a `nav_item`, and the picker offers
    /// it as the row you are already on.
    here: bool = false,
};

/// Storage for `effectiveRoster`, owned by its caller and living exactly
/// as long as the call that reads it.
pub const RosterBuf = [max_nav_items + 1]RosterItem;

/// The destinations, plus the current screen when it is none of them.
///
/// The extra entry goes **last**, which is not a visual preference: the
/// roster's indices are what the picker commits and what `currentIndex`
/// returns, so appending leaves every declared destination at the index
/// it has always had, and the one past the end is unambiguously "the
/// screen you are on".
///
/// Nothing is inherited. A screen pushed from Details is not "in"
/// Details — nokre never asked consumers to declare a hierarchy, so it
/// has none to walk, and guessing one from the stack would put a section
/// in the current state on the strength of how the visitor happened to
/// arrive. Two doors to the same screen would light different sections;
/// a deep link would light none. The screen speaks for itself instead.
pub fn effectiveRoster(app: *const App, buf: *RosterBuf) []const RosterItem {
    var n: usize = 0;
    for (app.nav_items.items) |item| {
        buf[n] = item;
        n += 1;
    }
    if (app.router.current()) |name| {
        for (app.nav_items.items) |item| {
            if (std.mem.eql(u8, item.route, name)) return buf[0..n];
        }
        // Off the roster: the route names itself. `currentRef` is
        // non-null whenever `current` is — both read the same top entry.
        buf[n] = .{
            .label = app.router.currentTitle().?,
            .route = app.router.currentRef().?,
            .icon = element_mod.nav_here_icon,
            .here = true,
        };
        n += 1;
    }
    return buf[0..n];
}

/// Installs app-level navigation chrome: the destinations, preserved
/// across router rebuilds. Call once, before the first navigate — nav
/// leads the focus order as the navigation landmark. The route table is
/// already in place by then (it is an `App.init` option), which is what
/// lets a destination be a route and a glyph and nothing else — every
/// label here is a `RouteDef.title`.
///
/// It takes the bottom band of the viewport, centered at whatever width
/// its own contents come to — not the sheet cap, which is a rule about
/// line length and about nothing the bar holds — and none of a pane's
/// surface: the nav is its items, each plated just enough to stay
/// readable while the page scrolls behind them.
///
/// Which *shape* it takes is the framework's decision, like its
/// placement: the row where the labels fit, the collapsed chip where
/// they do not. Consumers declare the set of places; nokre draws it
/// and reshapes it as the viewport changes. There is no placement API
/// and no shape API.
pub fn setNav(app: *App, items: []const Destination) !void {
    // 2–5 destinations: fewer is not navigation, more does not fit a
    // bottom bar at any viewport width.
    if (items.len < 2 or items.len > max_nav_items) return error.NavItemCount;
    const root = app.tree.rootId();
    if (app.tree.childCount(root) != 0) return error.NavMustComeFirst;
    // All or nothing: a roster half-built by a refused route — or by a
    // failed allocation — would outlive the error and describe a nav
    // that was never installed.
    errdefer app.nav_items.clearRetainingCapacity();
    for (items) |item| {
        // The route table is what names the destination, so a route it
        // has never heard of is refused here rather than drawn as a
        // blank chip leading nowhere. It also settles the labels: they
        // are the titles the routes declare, borrowed from the table.
        const def = app.router.lookup(item.route) orelse return error.UnknownRoute;
        // A destination is entered by name alone — the row has no
        // argument to supply and would fail the arity check on every
        // press. Better a refused roster than an inert one.
        if (def.args != 0) return error.RouteArgCount;
        try app.nav_items.append(app.gpa, .{ .label = def.title, .route = def.name, .icon = item.icon });
    }
    _ = try app.tree.append(root, .{ .nav = .{} });
    try syncNavChrome(app);
    app.invalidate();
}

/// Rebuilds the nav's children to match the roster, the viewport, and
/// the current route — the shape that fits, with the chip carrying
/// whichever section the router is on.
///
/// A no-op when nothing it would draw has changed. That is not an
/// optimization: a rebuild replaces the nodes, and replacing the node
/// that focus (or an open picker) names would drop both. Chrome that
/// redraws itself for no reason is chrome that loses your place.
pub fn syncNavChrome(app: *App) !void {
    const nav = layout.findNav(&app.tree) orelse return;
    if (app.nav_items.items.len == 0) return;
    var buf: RosterBuf = undefined;
    const roster = effectiveRoster(app, &buf);
    // Asked of the list actually being drawn, so an off-roster screen's
    // own entry is measured like any other. A row with one more thing in
    // it collapses at a wider viewport, which is the same rule the
    // roster has always been under and not a special case for this.
    const collapse = layout.navCollapses(app.measurer, roster, app.viewport);
    if (collapse) {
        // Found whenever there is a screen at all: `effectiveRoster`
        // made an entry for it if the consumer declared none. What used
        // to stand here was a fallback to the first destination for
        // *any* unmatched route — a chip naming a section the visitor
        // was not in and had possibly never opened.
        //
        // The first destination survives as the answer to the one
        // question it actually answers: `setNav` runs before the first
        // navigate (it must — the nav leads the focus order), so there
        // is a moment with a roster and no screen. A chip naming the
        // first destination there is a chip showing where the app is
        // about to be, not a claim about where the visitor is.
        const cur = currentRosterItem(app, roster) orelse roster[0];
        // Already the right shape showing the right section: leave the
        // node — and whatever names it — alone. The glyph is part of
        // "the right section": two destinations may share a label
        // across locales, and only the mark would be stale.
        if (soleChild(app, nav)) |child| {
            const el = app.tree.getConst(child).?;
            if (el.role() == .nav_current and
                std.mem.eql(u8, el.nav_current.section, cur.label) and
                el.nav_current.icon == cur.icon) return;
        }
        try clearChildren(app, nav);
        _ = try app.tree.append(nav, .{ .nav_current = .{ .section = cur.label, .icon = cur.icon } });
    } else {
        // The destinations draw their own current state from the router,
        // so the row survives a move between two of them untouched. What
        // it cannot survive is the roster changing under it — crossing on
        // or off it adds or drops the trailing marker — so the guard
        // compares the tail as well as the count.
        if (rowMatches(app, nav, roster)) return;
        try clearChildren(app, nav);
        for (roster) |item| {
            _ = if (item.here)
                try app.tree.append(nav, .{ .nav_here = .{ .label = item.label } })
            else
                try app.tree.append(nav, .{ .nav_item = .{ .label = item.label, .route = item.route, .icon = item.icon } });
        }
    }
    app.invalidate();
}

/// Whether the row already on screen is the one `roster` describes.
fn rowMatches(app: *const App, nav: NodeId, roster: []const RosterItem) bool {
    if (app.tree.childCount(nav) != roster.len) return false;
    var it = app.tree.children(nav);
    for (roster) |item| {
        const el = app.tree.getConst(it.next() orelse return false).?;
        if (item.here) {
            // The label is the whole of it: the marker's glyph is a
            // constant, and two routes sharing a title render alike.
            if (el.* != .nav_here or !std.mem.eql(u8, el.nav_here.label, item.label)) return false;
        } else if (el.* != .nav_item) return false;
    }
    return true;
}

/// The roster entry the router is standing on. Never null for a roster
/// built by `effectiveRoster` while a screen is on the stack.
fn currentRosterItem(app: *const App, roster: []const RosterItem) ?RosterItem {
    const i = currentIndexIn(app, roster) orelse return null;
    return roster[i];
}

/// Whether the screen on top *is* the one `route` names — not merely
/// somewhere inside its section.
///
/// Activating a destination you are already standing on is declined in
/// both shapes. Activation pushes, so the alternative is the same screen
/// stacked on itself: a Back control appearing out of nowhere, leading
/// to a screen indistinguishable from the one you are looking at.
/// Confirming where you are is not a navigation.
pub fn isCurrent(app: *const App, route: []const u8) bool {
    const cur = app.router.currentRef() orelse return false;
    return std.mem.eql(u8, cur, route);
}

/// The roster index the collapsed chip stands for — what the picker
/// opens with selected, and what a choice is compared against. Never
/// null while a screen is on the stack: past the declared destinations
/// sits the screen's own entry (`effectiveRoster`).
pub fn currentIndex(app: *const App) ?usize {
    var buf: RosterBuf = undefined;
    return currentIndexIn(app, effectiveRoster(app, &buf));
}

/// `currentIndex` against a roster the caller already has — the one the
/// picker built its rows from, so the index it commits and the index it
/// selected are read off the same list.
fn currentIndexIn(app: *const App, roster: []const RosterItem) ?usize {
    const cur = app.router.current() orelse return null;
    for (roster, 0..) |item, i| {
        // The declared entries carry route names; the screen's own
        // carries a full reference, which `current` never equals — it
        // is matched by `here` instead, and there is at most one.
        if (item.here or std.mem.eql(u8, item.route, cur)) return i;
    }
    return null;
}

fn firstChild(app: *const App, nav: NodeId) ?NodeId {
    var it = app.tree.children(nav);
    return it.next();
}

fn soleChild(app: *const App, nav: NodeId) ?NodeId {
    if (app.tree.childCount(nav) != 1) return null;
    return firstChild(app, nav);
}

fn clearChildren(app: *App, nav: NodeId) !void {
    while (true) {
        var it = app.tree.children(nav);
        const c = it.next() orelse break;
        try app.tree.remove(c);
    }
}
