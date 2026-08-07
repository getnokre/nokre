//! The app-level navigation chrome: the roster of destinations, and the
//! two shapes it renders as. `App.setNav` records the set and
//! `App.clearNav` retires it; `syncNavChrome`
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
const overlays = @import("overlays.zig");
const router_mod = @import("router.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

/// A destination, as consumers declare it (`setNav`): where it goes and
/// the mark it wears. Deliberately no label — the route table already
/// says what the screen is called (`RouteDef.title`), and a roster that
/// repeated it would be a second place for the same fact to be wrong,
/// with the nav and the screen's own chrome free to disagree.
///
/// Which is also why a translated nav bar is not a label here: the
/// titles are the table's, functions of the chosen locale where the app
/// has more than one language (`App.setLocale`). One screen, one name,
/// in every language.
pub const Destination = struct {
    /// A route *name*, never a reference: a destination is a place the
    /// app always has, and an argument would make it one particular
    /// screen. `setNav` refuses a route that takes any.
    route: []const u8,
    /// The destination's glyph, leading its label — or `null` on a
    /// roster that wears no marks.
    ///
    /// **Uniform, not required**, and the difference is the whole of
    /// this field's history. The rule was always that *a row where some
    /// items have icons and others do not is worse than either uniform
    /// answer*; requiring the glyph was one way of reaching a uniform
    /// row, and it was the only one while a roster was a phone's tab
    /// bar. A generated document's header wears no marks, so the other
    /// uniform answer had to become statable — and mixing them did not:
    /// `setNav` reads the whole set and refuses one carrying both
    /// (`error.NavIconsMixed`), the way it already refuses a route the
    /// table does not have.
    icon: ?element_mod.IconName = null,
};

/// The most destinations a roster may declare (`setNav`) — derived, not
/// chosen.
///
/// It used to be five, on the ground that *more does not fit a bottom
/// bar at any viewport width*, and that ground was never the one doing
/// the work: whether a row fits is `layout.navCollapses`'s question,
/// asked of the reader's own viewport, and a roster of two with long
/// enough labels collapses on a phone exactly as readily as a roster of
/// six. A constant cannot answer a question about a window it has never
/// seen, and it was not answering it.
///
/// What a constant *can* protect is the other shape. Collapsed, the
/// whole roster is the section picker's list, and `overlays` already
/// names the count at which a list stops being scanned and starts being
/// typed into: `picker_filter_min`. Past it a picker grows a filter
/// field, and a filtered list is one whose row position is no longer
/// its roster index — a split the section picker deliberately does not
/// carry (`openNavPicker`). So the bound is that list's, less the one
/// row the screen standing in for itself may add (`effectiveRoster`),
/// and it moves if that number ever does.
pub const max_nav_items = overlays.picker_filter_min - 2;

/// One line of the list both shapes draw: a declared destination, or the
/// screen standing in for itself. Also what the App keeps its roster in,
/// resolved once by `setNav` — the tree holds whichever *shape* fits the
/// viewport, so the list itself has to live somewhere that survives
/// reshaping.
///
/// Borrowed, never owned — the route points into the table, which
/// outlives the App (`Router.init` holds the slice it was given), the
/// label into a title's constant data (`router.Title`'s rule), and the
/// tree copies what it keeps.
pub const RosterItem = struct {
    /// What the line is called: the route's `RouteDef.title` in the
    /// chosen locale, evaluated by `setNav` for a destination (and
    /// again by `App.setLocale` when the locale moves), by the router
    /// for the screen standing in for itself.
    label: []const u8,
    /// What activating it navigates to. A destination carries its route
    /// *name*; the off-roster entry carries the current **reference**,
    /// arguments and all, so `isCurrent` recognizes it and declines. The
    /// name alone would push a bare `ticket` and fail its arity.
    route: []const u8,
    /// Uniform across the whole list — every declared destination's
    /// `Destination.icon`, and the same answer again on the entry the
    /// screen makes for itself (`effectiveRoster`).
    icon: ?element_mod.IconName,
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
        //
        // Its mark follows the roster's rather than being the constant
        // outright: the marker stands *in the row*, so a file-text
        // glyph beside a bar of bare words would be the one mixed item
        // `setNav` refuses to let a consumer state. The roster is
        // uniform by then, so the first entry answers for all of them.
        buf[n] = .{
            .label = app.router.currentTitle(app.locale()).?,
            .route = app.router.currentRef().?,
            .icon = if (marked(app)) element_mod.nav_here_icon else null,
            .here = true,
        };
        n += 1;
    }
    return buf[0..n];
}

/// Whether this bar wears marks. One question of the whole roster, and
/// the first entry is the whole answer: `setNav` refuses a mixed set,
/// so there is no second entry that could disagree. False for no roster
/// at all, which draws nothing either way.
fn marked(app: *const App) bool {
    const items = app.nav_items.items;
    return items.len != 0 and items[0].icon != null;
}

/// Installs app-level navigation chrome: the destinations, preserved
/// across router rebuilds and taken back down by `clearNav`. The route
/// table is what names them (it is an `App.init` option), which is what
/// lets a destination be a route and a glyph and nothing else — every
/// label here is a `RouteDef.title`.
///
/// The node goes **first** among the root's children wherever the call
/// lands: the nav leads the focus order as the navigation landmark, and
/// enforcing that by position rather than by demanding a bare tree is
/// what lets an app install the bar at the moment it earns one — see
/// `clearNav` for the teardown that only makes sense if this half is
/// callable from the same place.
///
/// Which *shape* it takes is the framework's decision, and so is where
/// it stands: the row where the labels fit, the collapsed chip where
/// they do not; the bottom band at a phone's width, a header above the
/// page anywhere wider. Consumers declare the set of places; nokre
/// draws it and reshapes it as the viewport changes. There is no
/// placement API and no shape API.
///
/// The band is the bottom of the viewport, centered at whatever width
/// its own contents come to — not the sheet cap, which is a rule about
/// line length and about nothing the bar holds — and none of a pane's
/// surface: the nav is its items, each plated just enough to stay
/// readable while the page scrolls behind them. The header is the same
/// items as words in the page's own margin, wrapping. Which of the two
/// a reader gets is decided against *their* window, by the sheet, over
/// one markup (render/dom/stylesheet.zig, "two shapes and the reader's
/// window picks"); the reference edition draws the band at every width,
/// having no medium that reflows under a reader.
///
/// **The collapse follows the medium, not the width alone.** A header
/// wraps, and a row that wraps has no width at which it fails to fit —
/// so where the surface reflows above the pane cap there is nothing for
/// the chip to answer, and `navCollapses` declines before it measures
/// (`layout.navRowWraps`). Where the surface clips, it fires at every
/// width, which is the reference edition and every shell over it,
/// unchanged. The band's own answer when a row will not fit is the
/// chip where something can work one and a scrolling strip where
/// nothing can, and neither is this call's to state.
///
/// **A generated document's header is one of these**, and that is the
/// whole reason `Destination.icon` is optional. A static site's row of
/// links across the top is a set of places the site always has, which
/// is what this call models — so it is stated here rather than spliced
/// into the document as markup, and it arrives with everything markup
/// would have thrown away: the current destination marked
/// (`aria-current`), the screen that is on none of them named
/// (`nav_here`), every route resolved against the table at build time,
/// and a navigation landmark ahead of the page's own `h1` in document
/// and focus order (docs/static-sites.md, "A site's header is a
/// roster").
pub fn setNav(app: *App, items: []const Destination) !void {
    // Fewer than two is not navigation. The upper bound is the
    // collapsed shape's list (`max_nav_items`), not the row's width —
    // that is `navCollapses`'s question and it is asked of a viewport.
    if (items.len < 2 or items.len > max_nav_items) return error.NavItemCount;
    // The whole roster is read before anything moves. The route table
    // is what names a destination, so a route it has never heard of is
    // refused here rather than drawn as a blank chip leading nowhere;
    // and a destination is entered by name alone, so a route that takes
    // arguments would fail its arity on every press — better a refused
    // roster than an inert one. Checking first is also what lets a
    // refused call leave a bar that is already up exactly as it was.
    //
    // The marks are read the same way and for the same reason. A row
    // where some items carry a glyph and others do not is worse than
    // either uniform answer, and the two answers are both legitimate —
    // so the *mixture* is what is refused, at the roster, before a
    // ransom-note bar exists to look at.
    for (items) |item| {
        const def = app.router.lookup(item.route) orelse return error.UnknownRoute;
        if (def.args != 0) return error.RouteArgCount;
        if ((item.icon == null) != (items[0].icon == null)) return error.NavIconsMixed;
    }
    // All or nothing past here: only an allocation can still fail, and
    // a roster half-copied would outlive the error describing a nav
    // that was never installed. Down to nothing rather than down to
    // half — `clearNav` is the same teardown a consumer would ask for.
    errdefer clearNav(app);
    app.nav_items.clearRetainingCapacity();
    for (items) |item| {
        // The labels settle here: they are the titles the routes
        // declare, said in the chosen locale — and re-said by
        // `App.setLocale` when it changes, which is why the roster
        // never caches across one.
        const def = app.router.lookup(item.route).?;
        try app.nav_items.append(app.gpa, .{ .label = def.title.text(app.locale()), .route = def.name, .icon = item.icon });
    }
    // Reused when a bar is already up, so re-declaring a roster does
    // not replace the node that focus — or an open picker — is naming.
    // The tree keeps the rest honest: a nav is a root child and there
    // is at most one (`validateAppend`).
    if (layout.findNav(&app.tree) == null)
        _ = try app.tree.insertFirst(app.tree.rootId(), .{ .nav = .{} });
    try syncNavChrome(app);
    app.invalidate();
}

/// Takes the nav chrome back down — the roster and the node — leaving a
/// tree that is simply an app without app-level navigation, and every
/// destination unreachable because there is nothing left to press.
///
/// The counterpart `setNav` needs, and it has to be a verb: a router
/// rebuild preserves the nav on purpose (`Router.clearContent`), so an
/// app whose bar belongs to a session had no way to end one except to
/// reach into the tree for the child whose role is `.nav`.
///
/// Idempotent and infallible — an app that never installed a bar, or
/// one signing out twice, costs nothing. It takes with it whatever was
/// pointing at the bar: the section picker is the collapsed chip's own
/// overlay, and focus cannot outlive the node that held it.
///
/// **Where to call it.** At the transition that ends the session, with
/// `setNav` at the one that begins it. Both are ordinary calls against
/// a tree of any shape, which is why `setNav` places the node first
/// rather than demanding a bare root: an install that lives inside a
/// screen builder runs again on every rebuild of that screen, so any
/// rebuild landing after the clear puts the bar back up — and nokre
/// cannot tell that reinstall from a wanted one. Moving both halves out
/// of the builders is what makes the order stop mattering.
pub fn clearNav(app: *App) void {
    app.nav_items.clearRetainingCapacity();
    const nav = layout.findNav(&app.tree) orelse return;
    // The section picker belongs to the chip that is about to go, so it
    // goes first — through the one verb that knows how to close it.
    if (app.picker_owner) |owner| {
        if (app.tree.isDescendant(owner, nav)) overlays.closePicker(app, null);
    }
    // …which hands focus back to that chip, so this runs after it.
    if (app.focused) |f| {
        if (app.tree.isDescendant(f.node, nav)) app.focused = null;
    }
    // Only CannotRemoveRoot and InvalidNode, neither reachable for a
    // node `findNav` just handed back.
    app.tree.remove(nav) catch {};
    app.invalidate();
}

/// Rebuilds the nav's children to match the roster, the viewport, and
/// the current route — the shape that fits, with the chip carrying
/// whichever section the router is on.
///
/// A no-op when nothing it would draw has changed. That is not an
/// optimization: a rebuild replaces the nodes, and replacing the node
/// that focus (or an open picker) names would drop both. Chrome that
/// redraws itself for no reason is chrome that loses your place — and
/// when the redraw is for a reason (a locale change, the collapse flipping),
/// the place is carried across it instead (`holdNavFocus`,
/// `reseatNavFocus`).
pub fn syncNavChrome(app: *App) !void {
    const nav = layout.findNav(&app.tree) orelse return;
    if (app.nav_items.items.len == 0) return;
    var buf: RosterBuf = undefined;
    const roster = effectiveRoster(app, &buf);
    // Asked of the list actually being drawn, so an off-roster screen's
    // own entry is measured like any other. A row with one more thing in
    // it collapses at a wider viewport, which is the same rule the
    // roster has always been under and not a special case for this.
    const collapse = layout.navCollapses(app.measurer, roster, app.viewport, app.medium);
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
        const held = holdNavFocus(app, nav);
        try clearChildren(app, nav);
        try app.tree.append(nav, .{ .nav_current = .{ .section = cur.label, .icon = cur.icon, .name = app.chrome.section } });
        reseatNavFocus(app, nav, held);
    } else {
        // The destinations draw their own current state from the router,
        // so the row survives a move between two of them untouched. What
        // it cannot survive is the roster changing under it — crossing on
        // or off it adds or drops the trailing marker, and a locale
        // change renames every one of them (`App.setLocale`) — so the
        // guard compares the words and the tail as well as the count.
        if (rowMatches(app, nav, roster)) return;
        const held = holdNavFocus(app, nav);
        try clearChildren(app, nav);
        for (roster) |item| {
            _ = if (item.here)
                try app.tree.append(nav, .{ .nav_here = .{ .value = item.label, .name = app.chrome.current_screen, .icon = item.icon } })
            else
                try app.tree.append(nav, .{ .nav_item = .{ .label = item.label, .route = item.route, .icon = item.icon } });
        }
        reseatNavFocus(app, nav, held);
    }
    app.invalidate();
}

/// What the necessary rebuild would otherwise strand — the guard above
/// it is a no-op precisely to protect these, so the path that must
/// replace the nodes has to hand them across itself.
///
/// Focus is held in the one term of a destination a relabel cannot
/// change: its route. The chip and the here-marker have no route, but
/// each shape holds at most one of them, so the kind alone names it.
const NavHold = union(enum) {
    none,
    chip,
    here,
    item: struct { route: [router_mod.max_ref_bytes]u8, len: usize },
};

/// The capture half, and the section picker with it: an open picker is
/// anchored to a chip about to go, so it closes now, through the verb
/// that knows how — before the focus read, the order `clearNav` uses,
/// because closing hands focus back to that chip and the hold must see
/// where it landed. The route is a copy: the node it borrows from is
/// exactly what the caller is about to remove.
fn holdNavFocus(app: *App, nav: NodeId) NavHold {
    if (app.picker_owner) |owner| {
        if (app.tree.isDescendant(owner, nav)) overlays.closePicker(app, null);
    }
    const f = app.focused orelse return .none;
    if (!app.tree.isDescendant(f.node, nav)) return .none;
    const el = app.tree.getConst(f.node) orelse return .none;
    switch (el.*) {
        .nav_current => return .chip,
        .nav_here => return .here,
        .nav_item => |n| {
            if (n.route.len > router_mod.max_ref_bytes) return .none;
            var hold: NavHold = .{ .item = .{ .route = undefined, .len = n.route.len } };
            @memcpy(hold.item.route[0..n.route.len], n.route);
            return hold;
        },
        else => return .none,
    }
}

/// Seats the held focus on the rebuilt child that means the same
/// thing. A hold the new shape cannot honor — the collapse flipped, or
/// the route left the roster — starts focus over: null is a fresh
/// start, where a dangling id is a crash and a guessed neighbor is a
/// screen reader announcing somewhere nobody asked for.
fn reseatNavFocus(app: *App, nav: NodeId, held: NavHold) void {
    if (held == .none) return;
    var it = app.tree.children(nav);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        const hit = switch (held) {
            .none => false,
            .chip => el.role() == .nav_current,
            .here => el.role() == .nav_here,
            .item => |h| el.* == .nav_item and std.mem.eql(u8, el.nav_item.route, h.route[0..h.len]),
        };
        if (hit) {
            app.focused = .of(c);
            return;
        }
    }
    app.focused = null;
}

/// Whether the row already on screen is the one `roster` describes.
fn rowMatches(app: *const App, nav: NodeId, roster: []const RosterItem) bool {
    if (app.tree.childCount(nav) != roster.len) return false;
    var it = app.tree.children(nav);
    for (roster) |item| {
        const el = app.tree.getConst(it.next() orelse return false).?;
        if (item.here) {
            // The value, and whether the row wears marks at all: two
            // routes sharing a title render alike, but a roster
            // re-declared from glyphs to words keeps every label and
            // changes every mark, and the marker is in that row. Its
            // *name* is chrome and is re-said in place (`setChrome`).
            if (el.* != .nav_here or
                !std.mem.eql(u8, el.nav_here.value, item.label) or
                el.nav_here.icon != item.icon) return false;
        } else if (el.* != .nav_item or
            !std.mem.eql(u8, el.nav_item.label, item.label) or
            el.nav_item.icon != item.icon) return false;
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

fn soleChild(app: *const App, nav: NodeId) ?NodeId {
    if (app.tree.childCount(nav) != 1) return null;
    var it = app.tree.children(nav);
    return it.next();
}

fn clearChildren(app: *App, nav: NodeId) !void {
    while (true) {
        var it = app.tree.children(nav);
        const c = it.next() orelse break;
        try app.tree.remove(c);
    }
}
