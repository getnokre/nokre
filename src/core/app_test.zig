//! Tests for the App: dispatch, focus, editing, overlays, notices, and
//! the nav chrome — everything a shell can drive. The press/key/scroll
//! dispatch tests live in input_test.zig, the router's contract in
//! router_test.zig.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const focus = @import("focus.zig");
const geometry = @import("geometry.zig");
const input_mod = @import("input.zig");
const layout = @import("layout.zig");
const wrap = @import("wrap.zig");
const nav_mod = @import("nav.zig");
const notices_mod = @import("notices.zig");
const overflow = @import("overflow.zig");
const router_mod = @import("router.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");
const test_app = @import("test_app.zig");

const App = app_mod.App;
const Element = element_mod.Element;
const NodeId = tree_mod.NodeId;

const testing = std.testing;

const PressCounter = struct {
    count: u32 = 0,
    fn onPress(ctx: ?*anyopaque) void {
        const self: *PressCounter = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
    }
};

fn down(app: *App, p: geometry.Point) !void {
    try app.dispatch(.{ .pointer = .{ .at = p, .phase = .down } });
}

fn up(app: *App, p: geometry.Point) !void {
    try app.dispatch(.{ .pointer = .{ .at = p, .phase = .up } });
}

const CtxData = struct { built: u32 = 0 };

fn buildHome(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *CtxData = @ptrCast(@alignCast(ctx.?));
    data.built += 1;
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Details", .route = "details" } });
}

fn buildDetails(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Details" } });
}

const home_and_details = [_]router_mod.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildHome },
    .{ .name = "details", .title = .{ .fixed = "Details" }, .build = buildDetails },
};

/// The router fixture's app: two screens and the counter `buildHome`
/// bumps, so a test can say how many times a screen was rebuilt.
fn routedApp(data: *CtxData) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &home_and_details,
        .ctx = data,
        .services = .mocks(),
    });
}

test "link activation navigates through the router" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();

    try app.navigate("home");
    try testing.expectEqual(@as(u32, 1), data.built);
    app.performLayout();

    const link = focus.firstFocusable(&app.tree, app.tree.rootId()).?.node;
    try app.tap(app.tree.rectOf(link).center());

    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expect(app.focused == null);

    try app.navigateBack();
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expectEqual(@as(u32, 2), data.built);
}

test "pushed screens get framework back chrome; the root does not" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();

    try app.navigate("home");
    try testing.expect(firstChild(&app).role() != .back);

    try app.navigate("details");
    var it = app.tree.children(app.tree.rootId());
    const back = it.next().?;
    const title = it.next().?;
    const first = app.tree.getConst(back).?;
    try testing.expect(first.role() == .back);
    try testing.expectEqualStrings("Back", first.label());

    // The control shares the title's line: indented title, same row.
    app.performLayout();
    const br = app.tree.rectOf(back);
    const tr = app.tree.rectOf(title);
    try testing.expectEqual(br.x + br.w + layout.metrics.icon_gap, tr.x);
    // The target is taller than the line it marks, so it hangs past the
    // title's box on both sides — including *above* it. What has to hold
    // is the exact thing the eye checks: the glyph's center sits on the
    // title's cap center, not on its line box, which reads low.
    const scale = text.Scale.h1;
    const cap_center = tr.y + scale.baseline() - @divTrunc(3 * scale.px(), 8);
    try testing.expectEqual(cap_center, br.center().y);
    try testing.expect(br.y < tr.y);

    try app.tap(br.center());
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expectEqual(@as(usize, 1), app.router.depth());
    try testing.expect(firstChild(&app).role() != .back);
}

fn firstChild(app: *App) Element {
    var it = app.tree.children(app.tree.rootId());
    return app.tree.getConst(it.next().?).?.*;
}

/// The framework-installed Back control, or null at a stack root. Not
/// `firstChild`: app chrome installed before the content (a nav) leads
/// the root's children and outlives every rebuild.
fn backControl(app: *App) ?NodeId {
    var it = app.tree.children(app.tree.rootId());
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .back) return c;
    }
    return null;
}

fn buildTileHome(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *CtxData = @ptrCast(@alignCast(ctx.?));
    data.built += 1;
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Details", .route = "details" } });
}

test "tile with a route navigates like a link" {
    var data: CtxData = .{};
    const routes = [_]router_mod.RouteDef{
        .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildTileHome },
        .{ .name = "details", .title = .{ .fixed = "Details" }, .build = buildDetails },
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &routes,
        .ctx = &data,
        .services = .mocks(),
    });
    defer app.deinit();

    try app.navigate("home");
    app.performLayout();

    const tile = focus.firstFocusable(&app.tree, app.tree.rootId()).?.node;
    try app.tap(app.tree.rectOf(tile).center());

    try testing.expectEqualStrings("details", app.router.current().?);
}

test "nav survives rebuilds; activation pushes the destination" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "details", .icon = .info },
    });
    try app.navigate("home");
    try app.navigate("details"); // push: depth 2
    try testing.expectEqual(@as(usize, 2), app.router.depth());

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 2), app.tree.childCount(nav));

    app.performLayout();
    var it = app.tree.children(nav);
    const home_item = it.next().?;
    try app.tap(app.tree.rectOf(home_item).center());

    try testing.expectEqualStrings("home", app.router.current().?);
    // The destination goes *on* the stack: the screen it was reached
    // from is still behind it, and now has a way back to it.
    try testing.expectEqual(@as(usize, 3), app.router.depth());
    try testing.expect(app.focused.?.on(home_item));
    try testing.expect(layout.findNav(&app.tree).?.eql(nav));

    // The way back is the framework's own control, and it leads to the
    // screen the nav was crossed from — not to a section root nobody
    // was standing on.
    try testing.expect(backControl(&app) != null);
    try app.navigateBack();
    try testing.expectEqualStrings("details", app.router.current().?);
}

test "crossing to the destination already showing is the one no-op" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "details", .icon = .info },
    });
    try app.navigate("home");
    app.performLayout();

    var it = app.tree.children(layout.findNav(&app.tree).?);
    const home_item = it.next().?;
    try app.tap(app.tree.rectOf(home_item).center());

    // Not "home" on top of "home": that would grow a Back control out of
    // nowhere, leading to the screen you are looking at.
    try testing.expectEqual(@as(usize, 1), app.router.depth());
    try testing.expect(backControl(&app) == null);
    try testing.expect(app.focused.?.on(home_item));
}

// ---- the collapsed nav (docs/elements.md#navigation-chrome) ----

// Four sections whose widest title ("Subscriptions", from the route
// table below) clears a row at no viewport width, so the shape is
// decided by the fixture, not by luck.
const crowded_nav = [_]nav_mod.Destination{
    .{ .route = "library", .icon = .library },
    .{ .route = "settings", .icon = .settings },
    .{ .route = "explore", .icon = .compass },
    .{ .route = "subs", .icon = .user },
};

fn buildNavSection(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Section" } });
}

/// The smallest `.of_locale` title a test needs: one word until the app
/// chooses `tag`, another after. A real app answers from its catalog
/// (`L.tr(L.resolve(tag), …)`); the shape is what matters here.
fn bilingual(comptime tag: []const u8, comptime before: []const u8, comptime after: []const u8) router_mod.Title {
    return .{ .of_locale = struct {
        fn call(t: []const u8) []const u8 {
            return if (std.mem.eql(u8, t, tag)) after else before;
        }
    }.call };
}

const crowded_routes = [_]router_mod.RouteDef{
    .{ .name = "library", .title = bilingual("de", "Library", "Bibliothek"), .build = buildNavSection },
    .{ .name = "settings", .title = bilingual("de", "Settings", "Einstellungen"), .build = buildNavSection },
    .{ .name = "explore", .title = bilingual("de", "Explore", "Entdecken"), .build = buildNavSection },
    .{ .name = "subs", .title = bilingual("de", "Subscriptions", "Abonnements"), .build = buildNavSection },
    .{ .name = "account", .title = bilingual("de", "Account", "Konto"), .build = buildNavSection },
};

/// The nav-collapse fixture's app: a phone-width viewport and the
/// crowded roster's routes, which is what every test below turns on.
fn crowdedApp() !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 375, .h = 600 },
        .routes = &crowded_routes,
        .services = .mocks(),
    });
}

fn navChip(app: *App) ?NodeId {
    const nav = layout.findNav(&app.tree) orelse return null;
    var it = app.tree.children(nav);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .nav_current) return c;
    }
    return null;
}

test "a nav too wide for its labels collapses to the current section" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("settings");

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 1), app.tree.childCount(nav));
    const chip = navChip(&app).?;
    // The roster is intact behind it — the shape changed, not the set.
    try testing.expectEqual(@as(usize, 4), app.nav_items.items.len);
    try testing.expectEqualStrings("Settings", app.tree.getConst(chip).?.nav_current.section);
    // Its name is the framework's and stays put; the section is its value.
    try testing.expectEqualStrings("Section", app.tree.getConst(chip).?.label());
}

test "the collapsed chip follows the router without being rebuilt for nothing" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");

    const first = navChip(&app).?;
    try testing.expectEqualStrings("Library", app.tree.getConst(first).?.nav_current.section);

    // A rebuild that lands on the same section leaves the node alone:
    // replacing it would drop whatever names it.
    try app.router.reload(&app);
    try testing.expect(navChip(&app).?.eql(first));

    try app.router.switchTo(&app, "explore");
    try testing.expectEqualStrings("Explore", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

test "a locale change rebuilds the chip without stranding focus" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");

    // The visitor is holding the collapsed chip when the locale changes.
    app.focused = .of(navChip(&app).?);
    try app.setLocale("de");

    // The chip was rebuilt to say the new language, and focus moved
    // with it instead of dangling into the removed node.
    const chip = navChip(&app).?;
    try testing.expect(app.focused.?.node.eql(chip));
    try testing.expectEqualStrings("Bibliothek", app.tree.getConst(chip).?.nav_current.section);
}

test "a relabelled row re-seats focus on the same destination, by route" {
    var app = try App.init(testing.allocator, .{
        // Wide enough that two short titles stay a row through both
        // languages.
        .viewport = .{ .w = 800, .h = 600 },
        .routes = &crowded_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("library");

    var settings: ?NodeId = null;
    var it = app.tree.dfs();
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.* == .nav_item and std.mem.eql(u8, el.nav_item.route, "settings")) settings = id;
    }
    app.focused = .of(settings.?);

    try app.setLocale("de");
    const held = app.focused.?.node;
    const el = app.tree.getConst(held).?;
    // Not the old node — the locale change rebuilt the row — but the
    // same destination, found by the one term a relabel cannot change.
    try testing.expect(!held.eql(settings.?));
    try testing.expectEqualStrings("settings", el.nav_item.route);
    try testing.expectEqualStrings("Einstellungen", el.nav_item.label);
}

test "focus on surviving chrome carries across reload by identity, not name" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");

    const chip = navChip(&app).?;
    app.focused = .of(chip);
    try app.router.reload(&app);
    // The chip is never rebuilt (the test above), so the carried focus
    // lands back on the very node — no name lookup to go wrong.
    try testing.expect(app.focused.?.node.eql(chip));
}

test "the nav reshapes as the viewport crosses the threshold" {
    var app = try crowdedApp();
    defer app.deinit();
    // Two short titles fit anywhere; four long ones fit nowhere. This
    // set sits between: collapsed in portrait, a row in landscape.
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
        .{ .route = "explore", .icon = .compass },
        .{ .route = "account", .icon = .user },
    });
    try app.navigate("library");
    try testing.expect(navChip(&app) != null);

    app.setViewport(.{ .w = 900, .h = 400 });
    try testing.expect(navChip(&app) == null);
    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 4), app.tree.childCount(nav));

    app.setViewport(.{ .w = 375, .h = 600 });
    try testing.expect(navChip(&app) != null);
}

test "the chip's picker lists every section with the current one selected" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("explore");
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    const picker = layout.findPicker(&app.tree).?;
    try testing.expectEqualStrings("Sections", app.tree.getConst(picker).?.picker.title);

    var rows: [8]NodeId = undefined;
    var n: usize = 0;
    var it = app.tree.dfsUnder(picker);
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() == .picker_item) {
            rows[n] = id;
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("Library", app.tree.getConst(rows[0]).?.picker_item.label);
    try testing.expect(app.tree.getConst(rows[2]).?.picker_item.selected);
    // Focus opens on the current row, as the select's picker does.
    try testing.expect(app.focused.?.on(rows[2]));
}

test "choosing a section pushes it and keeps focus in the chrome" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    try app.navigate("settings"); // depth 2 inside the section
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    var target: ?NodeId = null;
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.role() == .picker_item and el.picker_item.index == 3) target = id;
    }
    try app.tap(app.tree.rectOf(target.?).center());

    try testing.expectEqualStrings("subs", app.router.current().?);
    // A push, exactly as the row's items make: the two screens behind
    // it stay behind it. The chip and the row are one behavior in two
    // shapes, and the shape must not decide what a choice costs.
    try testing.expectEqual(@as(usize, 3), app.router.depth());
    try testing.expect(layout.findPicker(&app.tree) == null);
    // The chip the picker was opened from is gone with the resync;
    // focus follows the chrome rather than dangling.
    const chip = navChip(&app).?;
    try testing.expect(app.focused.?.on(chip));
    try testing.expectEqualStrings("Subscriptions", app.tree.getConst(chip).?.nav_current.section);

    try app.navigateBack();
    try testing.expectEqualStrings("settings", app.router.current().?);
    try testing.expectEqualStrings("Settings", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

test "re-choosing the current section is a no-op, stack and all" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    try app.navigate("settings"); // depth 2, and worth keeping
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    var target: ?NodeId = null;
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        // "settings" is the roster's index 1, and the screen we are on.
        if (el.role() == .picker_item and el.picker_item.index == 1) target = id;
    }
    try app.tap(app.tree.rectOf(target.?).center());

    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("settings", app.router.current().?);
    // Confirming where you are is not a navigation: no second copy of
    // this screen, and the way back still leads where it did.
    try testing.expectEqual(@as(usize, 2), app.router.depth());
}

// ---- the section menu's geometry ----

/// The open menu and the chip it came out of, laid out.
fn openSectionMenu(app: *App) !struct { menu: geometry.Rect, chip: geometry.Rect } {
    try app.tap(app.tree.rectOf(navChip(app).?).center());
    app.performLayout();
    return .{
        .menu = app.tree.rectOf(layout.findPicker(&app.tree).?),
        .chip = app.tree.rectOf(navChip(app).?),
    };
}

test "the section menu stands on the bar rather than spanning the pane" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    const r = try openSectionMenu(&app);
    // Centered on the bar's group and resting a gap above it — the card
    // stands on that bar, so it is measured from it and not from a pane.
    // Never narrower than the chip (a menu that came out of a wider
    // control reads as clipped), never wider than the margins the chip
    // itself is placed inside.
    try testing.expectEqual(layout.navGroupX(app.viewport, r.menu.w), r.menu.x);
    try testing.expectEqual(r.chip.y - layout.metrics.nav_item_gap, r.menu.bottom());
    try testing.expect(r.menu.w >= r.chip.w);
    try testing.expect(r.menu.w <= layout.navContentWidth(app.viewport));
    // The bar's cap, not the sheet's, and no header: the pane's title
    // bar and its 560px span both went with the pane.
    try testing.expect(r.menu.w < layout.paneWidth(app.viewport));

    // Four rows flush inside the 1px edge, and every one of them fits:
    // the roster caps at six, so this list can never want to scroll.
    const rows: i32 = 4;
    const content = rows * layout.pickerItemHeight() + (rows - 1) * layout.metrics.border;
    try testing.expectEqual(content + 2 * layout.metrics.border, r.menu.h);
    var it = app.tree.children(layout.findPicker(&app.tree).?);
    const region = it.next().?;
    try testing.expectEqual(content, app.tree.rectOf(region).h);
}

test "the section menu clears the bar whatever the safe band costs" {
    var app = try crowdedApp();
    defer app.deinit();
    app.setSafeBottom(34); // a home-indicator phone
    try crowdedNavApp(&app);

    const r = try openSectionMenu(&app);
    // The regression this shape replaced: the menu was a bottom-anchored
    // pane, so it bled its fill `safe_bottom` px past its own rect and
    // let the clip square the edge off — over the chip it was supposed
    // to leave visible. Nothing of it may reach the chip's band now.
    try testing.expect(r.menu.bottom() < r.chip.y);
    try testing.expect(r.menu.bottom() + app.safe_bottom < app.viewport.h);
    try testing.expect(r.menu.y >= layout.metrics.sheet_min_top);
}

test "the section menu is its own mirror, being centered on the bar" {
    var rtl_app = try crowdedApp();
    defer rtl_app.deinit();
    rtl_app.setDirection(.rtl);
    try crowdedNavApp(&rtl_app);
    const rtl = try openSectionMenu(&rtl_app);

    var ltr_app = try crowdedApp();
    defer ltr_app.deinit();
    try crowdedNavApp(&ltr_app);
    const ltr = try openSectionMenu(&ltr_app);

    // A centered card has no leading edge to swap, so mirroring the
    // chrome moves it nowhere: the same rect either way. What the two
    // directions still disagree about is inside the rows, which is where
    // the words are.
    try testing.expectEqual(ltr.menu, rtl.menu);
    try testing.expectEqual(rtl.chip.y - layout.metrics.nav_item_gap, rtl.menu.bottom());
}

// ---- press-drag-release through the section menu ----

fn crowdedNavApp(app: *App) !void {
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    app.performLayout();
}

fn sectionRow(app: *App, index: usize) NodeId {
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.role() == .picker_item and el.picker_item.index == index) return id;
    }
    unreachable;
}

test "the section menu opens on the press, not the release" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    try down(&app, app.tree.rectOf(navChip(&app).?).center());
    // The whole point: the same press can now travel to a row.
    try testing.expect(layout.findPicker(&app.tree) != null);
}

test "the open menu leaves the chip that opened it uncovered" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?);

    try down(&app, chip.center());
    app.performLayout();

    // A menu drawn over its own control would put a row under the
    // finger still holding it, and letting go without moving would
    // choose a section nobody aimed at.
    const picker = app.tree.rectOf(layout.findPicker(&app.tree).?);
    try testing.expect(picker.bottom() <= chip.y);
}

test "dragging to a row and releasing chooses that section" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?).center();

    try down(&app, chip);
    app.performLayout();
    const row = app.tree.rectOf(sectionRow(&app, 2)).center();
    try app.dispatch(.{ .pointer = .{ .at = row, .phase = .move } });
    // Motion moves focus and nothing else — the state the arrow keys
    // move, not a second kind of highlight.
    try testing.expect(app.focused.?.on(sectionRow(&app, 2)));

    try up(&app, row);
    try testing.expectEqualStrings("explore", app.router.current().?);
    try testing.expect(layout.findPicker(&app.tree) == null);
}

test "releasing back on the chip leaves the menu open for a second press" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?).center();

    // The sticky menu: this is what keeps the drag an addition rather
    // than a replacement — a plain click still works, in two presses.
    try app.tap(chip);
    try testing.expect(layout.findPicker(&app.tree) != null);
    try testing.expectEqualStrings("library", app.router.current().?);

    app.performLayout();
    try app.tap(app.tree.rectOf(sectionRow(&app, 3)).center());
    try testing.expectEqualStrings("subs", app.router.current().?);
}

test "releasing away from both chip and rows chooses nothing" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    try down(&app, app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    try up(&app, .{ .x = 4, .y = 4 }); // the scrim, above the menu

    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("library", app.router.current().?);
}

test "a cancelled section drag chooses nothing and closes" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    try down(&app, app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    const row = app.tree.rectOf(sectionRow(&app, 2)).center();
    try app.dispatch(.{ .pointer = .{ .at = row, .phase = .move } });
    try app.dispatch(.{ .pointer = .{ .at = row, .phase = .cancel } });
    try up(&app, row);

    // A recognizer taken away mid-drag must never commit a navigation
    // the user did not finish — the edge pan's rule, same reasoning.
    try testing.expectEqualStrings("library", app.router.current().?);
}

test "only the collapsed chip asks the touch shells for the raw stream" {
    var app = try crowdedApp();
    defer app.deinit();

    // Nothing wants it before there is a nav at all.
    try testing.expect(input_mod.pointerStreamRect(&app) == null);

    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?);
    try testing.expectEqual(chip, input_mod.pointerStreamRect(&app).?);
    try testing.expect(input_mod.wantsPointerStream(&app, chip.center()));
    // Everything else takes the shells' ordinary recognized-tap path,
    // so their scrolling and tap detection are untouched.
    try testing.expect(!input_mod.wantsPointerStream(&app, .{ .x = 8, .y = 8 }));

    // Inert while the menu it opened is up: the next press belongs to
    // the scrim, which closes rather than reopens.
    try down(&app, chip.center());
    try testing.expect(input_mod.pointerStreamRect(&app) == null);
}

test "a nav wide enough for its row asks for nothing" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 400 },
        .routes = &crowded_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "explore", .icon = .compass },
    });
    try app.navigate("library");
    app.performLayout();

    // Row items are plain links: a press-drag has nothing to open, and
    // every touch shell keeps its own recognizer for them.
    try testing.expect(input_mod.pointerStreamRect(&app) == null);
}

test "a select still opens on release and is chosen by a second press" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
    } });
    app.performLayout();

    // The drag is the nav's alone: pressing a select opens nothing
    // until the release, and nothing follows the pointer after it.
    try down(&app, app.tree.rectOf(sel).center());
    try testing.expect(layout.findPicker(&app.tree) == null);
    try up(&app, app.tree.rectOf(sel).center());
    try testing.expect(layout.findPicker(&app.tree) != null);
}

test "Esc leaves the section picker without navigating" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    try testing.expect(layout.findPicker(&app.tree) != null);
    try app.dispatch(.{ .key_down = .{ .key = .escape } });

    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("library", app.router.current().?);
}

// ---- a screen that is none of the destinations ----

// Two sections, and two routes the roster does not name — one plain, one
// carrying an argument, because the marker has to name a route whose
// reference is not its name.
const offroster_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = bilingual("tr", "Home", "Ana sayfa"), .build = buildNavSection },
    .{ .name = "settings", .title = bilingual("tr", "Settings", "Ayarlar"), .build = buildNavSection },
    .{ .name = "terms", .title = bilingual("tr", "Terms", "Koşullar"), .build = buildNavSection },
    .{ .name = "ticket", .title = bilingual("tr", "Ticket", "Bilet"), .args = 1, .build = buildNavSection },
};

const offroster_nav = [_]nav_mod.Destination{
    .{ .route = "home", .icon = .house },
    .{ .route = "settings", .icon = .settings },
};

fn offRosterApp(w: i32) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = w, .h = 600 },
        .routes = &offroster_routes,
        .services = .mocks(),
    });
}

fn navHere(app: *App) ?NodeId {
    const nav = layout.findNav(&app.tree) orelse return null;
    var it = app.tree.children(nav);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .nav_here) return c;
    }
    return null;
}

test "the row names a screen that is none of its destinations" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 2), app.tree.childCount(nav));
    try testing.expect(navHere(&app) == null);

    // Off the roster: the screen joins the row, at the end, naming
    // itself from the route table — not silently marking Home current,
    // which is where the visitor is not.
    try app.navigate("terms");
    try testing.expectEqual(@as(usize, 3), app.tree.childCount(nav));
    const here = navHere(&app).?;
    try testing.expectEqualStrings("Terms", app.tree.getConst(here).?.nav_here.value);
    var it = app.tree.children(nav);
    _ = it.next();
    _ = it.next();
    try testing.expect(it.next().?.eql(here)); // last, so the roster keeps its indices

    // And back: crossing onto a destination drops the marker again.
    try app.navigate("settings");
    try testing.expect(navHere(&app) == null);
    try testing.expectEqual(@as(usize, 2), app.tree.childCount(nav));
}

test "the marker names the route, arguments and all" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("ticket~42");

    // The title names the route, not the instance: `ticket~42` and
    // `ticket~43` are both "Ticket" (router.zig).
    try testing.expectEqualStrings("Ticket", app.tree.getConst(navHere(&app).?).?.nav_here.value);
}

test "the marker is a label, not a destination" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("terms");
    app.performLayout();

    const here = navHere(&app).?;
    const el = app.tree.getConst(here).?;
    try testing.expect(!el.isInteractive());
    try testing.expect(!el.isFocusable());
    // Its name is the framework's and the title is its value, the split
    // the collapsed chip already makes.
    try testing.expectEqualStrings("Current screen", el.label());

    // A press lands on nothing: no focus moves, no navigation happens.
    const before = app.router.depth();
    try app.tap(app.tree.rectOf(here).center());
    try testing.expectEqual(before, app.router.depth());
    try testing.expect(app.focused == null);

    // And the keyboard walks past it. The tab order wraps, so one lap
    // is every stop there is — bounded, or a marker in the order would
    // hang this test rather than fail it.
    var stop = focus.firstFocusable(&app.tree, app.tree.rootId());
    const first = stop.?;
    for (0..16) |_| {
        try testing.expect(!stop.?.node.eql(here));
        stop = focus.nextFocusable(&app.tree, app.tree.rootId(), stop.?);
        if (stop.?.node.eql(first.node)) break;
    }
}

test "the chip names an off-roster screen instead of the first section" {
    var app = try offRosterApp(300);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("terms");

    // The old answer here was "Home" — the first destination, standing
    // in for a screen the visitor had not opened.
    try testing.expectEqualStrings("Terms", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

test "the screen's own entry is measured like any other destination" {
    // A width that holds the two destinations and not a third pill.
    var app = try offRosterApp(380);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    try testing.expect(navChip(&app) == null);

    // Nothing in the collapse threshold knows this feature exists: the
    // row simply has one more pill in it (`nav.effectiveRoster`).
    try app.navigate("terms");
    try testing.expect(navChip(&app) != null);
    try testing.expectEqualStrings("Terms", app.tree.getConst(navChip(&app).?).?.nav_current.section);

    try app.navigate("settings");
    try testing.expect(navChip(&app) == null);
}

test "the picker offers the screen you are on, selected, and declines it" {
    // Narrow enough that the shape is the chip whichever screen is on
    // top: this is a test about the picker, not about reshaping.
    var app = try offRosterApp(300);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    try app.navigate("terms"); // depth 2, and worth keeping
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    var rows: [8]NodeId = undefined;
    var n: usize = 0;
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() == .picker_item) {
            rows[n] = id;
            n += 1;
        }
    }
    // A combo box whose value is one of its own options: the chip says
    // "Terms" and the list it opens contains Terms.
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("Terms", app.tree.getConst(rows[2]).?.picker_item.label);
    try testing.expect(app.tree.getConst(rows[2]).?.picker_item.selected);

    // Choosing it is the no-op every current destination gets: the
    // entry carries the current reference, so `isCurrent` catches it.
    try app.tap(app.tree.rectOf(rows[2]).center());
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("terms", app.router.current().?);
    try testing.expectEqual(@as(usize, 2), app.router.depth());
}

test "the picker still crosses to a destination from an off-roster screen" {
    var app = try offRosterApp(300);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("terms");
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    var target: ?NodeId = null;
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.role() == .picker_item and el.picker_item.index == 1) target = id;
    }
    try app.tap(app.tree.rectOf(target.?).center());

    try testing.expectEqualStrings("settings", app.router.current().?);
    try testing.expectEqualStrings("Settings", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

// ---- a nav bar in another language ----
//
// The same four routes answer "tr" in Turkish (`bilingual`, above). A
// real app answers from its catalog; the shape is what matters here —
// the same table, only the locale moved.

test "setLocale renames the destinations, the chip, and the marker" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");

    const nav = layout.findNav(&app.tree).?;
    var it = app.tree.children(nav);
    try testing.expectEqualStrings("Home", app.tree.getConst(it.next().?).?.nav_item.label);

    try app.setLocale("tr");
    // The roster re-evaluated its titles: a guard that only counted
    // destinations would have left the English words standing.
    it = app.tree.children(nav);
    try testing.expectEqualStrings("Ana sayfa", app.tree.getConst(it.next().?).?.nav_item.label);
    try testing.expectEqualStrings("Ayarlar", app.tree.getConst(it.next().?).?.nav_item.label);

    // The marker for a screen that is no destination is labelled from
    // the same table, so it follows without being told.
    try app.navigate("terms");
    try testing.expectEqualStrings("Koşullar", app.tree.getConst(navHere(&app).?).?.nav_here.value);

    // And the collapsed shape, which names the section it stands on.
    var narrow = try offRosterApp(300);
    defer narrow.deinit();
    try narrow.setNav(&offroster_nav);
    try narrow.navigate("settings");
    try narrow.setLocale("tr");
    try testing.expectEqualStrings("Ayarlar", narrow.tree.getConst(navChip(&narrow).?).?.nav_current.section);
}

test "setLocale accepts a tag every title answers, and nothing else" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");

    // A tag past the service's cap is a programmer error, not a
    // truncation — the same bound the device's own tag lives under.
    const oversize = "x" ** 65;
    try testing.expectError(error.LocaleTagTooLong, app.setLocale(oversize));

    // A title function answering a tag with nothing is `init`'s empty
    // check, reached again at the moment that tag is chosen.
    var blank = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .routes = &.{
            .{ .name = "home", .title = bilingual("xx", "Home", ""), .build = buildNavSection },
        },
        .services = .mocks(),
    });
    defer blank.deinit();
    try testing.expectError(error.EmptyRouteTitle, blank.setLocale("xx"));
    // …and the refusal committed nothing: the app still answers as
    // never-chosen.
    try testing.expectEqualStrings("", blank.locale());

    // Every refusal left the roster exactly as it was.
    var it = app.tree.children(layout.findNav(&app.tree).?);
    try testing.expectEqualStrings("Home", app.tree.getConst(it.next().?).?.nav_item.label);
    try testing.expectEqualStrings("", app.locale());
}

test "a boot locale rides Options through the same gate" {
    // Chosen before init — a restored preference — so the first tree
    // ever built is already in the language, roster included.
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .routes = &offroster_routes,
        .services = .mocks(),
        .locale = "tr",
    });
    defer app.deinit();
    try testing.expectEqualStrings("tr", app.locale());
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    var it = app.tree.children(layout.findNav(&app.tree).?);
    try testing.expectEqualStrings("Ana sayfa", app.tree.getConst(it.next().?).?.nav_item.label);

    // And the gate is the same one: a boot tag no title answers is an
    // `init` failure, not a screen booting half-said.
    try testing.expectError(error.EmptyRouteTitle, App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .routes = &.{
            .{ .name = "home", .title = bilingual("xx", "Home", ""), .build = buildNavSection },
        },
        .services = .mocks(),
        .locale = "xx",
    }));
}

test "setChrome re-says the framework's own words, in place" {
    var app = try offRosterApp(300); // narrow: the collapsed chip
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    try app.navigate("terms"); // depth 2, so a back control exists
    app.notify(.{ .title = "Kaydedildi", .route = "home", .important = true });

    try testing.expectEqualStrings("Back", app.tree.getConst(findBack(&app).?).?.label());
    try testing.expectEqualStrings("Section", app.tree.getConst(navChip(&app).?).?.label());

    app.setChrome(.{
        .back = "Geri",
        .close = "Kapat",
        .section = "Bölüm",
        .current_screen = "Bu ekran",
        .sections = "Bölümler",
        .notices = "Bildirimler",
        .show_notices = "Bildirimleri göster",
        .show_all_notices = "Tüm bildirimleri göster",
        .minimize_notices = "Bildirimleri küçült",
        .dismiss_all_notices = "Tüm bildirimleri kapat",
        .open_prefix = "Aç: ",
        .dismiss_prefix = "Kapat: ",
        .important = "Önemli",
        .other = "Diğer",
    });

    // Chrome already standing is re-said on the spot, not left for
    // whatever rebuild happens next.
    try testing.expectEqualStrings("Geri", app.tree.getConst(findBack(&app).?).?.label());
    try testing.expectEqualStrings("Bölüm", app.tree.getConst(navChip(&app).?).?.label());
    // The banner's controls name the notice they act on, so they are
    // rebuilt rather than patched — prefix joined to the title.
    try testing.expect(queryLabel(&app, "Aç: Kaydedildi") != null);
    try testing.expect(queryLabel(&app, "Kapat: Kaydedildi") != null);
    try testing.expect(queryLabel(&app, "Bildirimleri küçült") != null);
    try testing.expect(queryLabel(&app, "Minimize notices") == null);

    // And chrome built afterwards is born in the new language.
    try app.openNoticesPane();
    const pane = layout.findNoticesPane(&app.tree).?;
    try testing.expectEqualStrings("Bildirimler", app.tree.getConst(pane).?.label());
    try testing.expect(queryLabel(&app, "Tüm bildirimleri kapat") != null);

    const sheet = try app.presentSheet("Bir sayfa");
    _ = sheet;
    try testing.expect(queryLabel(&app, "Kapat") != null);
}

// The old `Chrome.Catalog` structural test lived here; the opt-in it
// proved moved to the catalog itself — `l10n` `Bundle.chrome` derives
// one reserved key per `Chrome` field — and l10n_test.zig proves the
// derivation, field for field.

fn findBack(app: *App) ?NodeId {
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() == .back) return id;
    }
    return null;
}

fn queryLabel(app: *App, label: []const u8) ?NodeId {
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (std.mem.eql(u8, app.tree.getConst(id).?.label(), label)) return id;
    }
    return null;
}

test "the bar leads the focus order wherever setNav is called from" {
    var app = try offRosterApp(900);
    defer app.deinit();
    // A screen is already up — which used to refuse the call, and is
    // exactly where an app whose bar belongs to a session installs one.
    try app.navigate("terms");
    try testing.expect(app.tree.childCount(app.tree.rootId()) > 0);

    try app.setNav(&offroster_nav);
    // Position, not timing, is what makes the navigation landmark lead.
    var it = app.tree.children(app.tree.rootId());
    try testing.expect(it.next().?.eql(layout.findNav(&app.tree).?));
}

test "clearNav takes the bar down, and its destinations stop being reachable" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    app.performLayout();

    var it = app.tree.children(layout.findNav(&app.tree).?);
    _ = it.next();
    const settings_item = it.next().?;
    const spot = app.tree.rectOf(settings_item).center();

    app.clearNav();
    try testing.expect(layout.findNav(&app.tree) == null);
    try testing.expectEqual(@as(usize, 0), app.nav_items.items.len);
    app.performLayout();

    // The band is gone, not hidden: a press where Settings stood
    // reaches nothing, and the router has not moved.
    try app.tap(spot);
    try testing.expectEqualStrings("home", app.router.current().?);

    // Idempotent, and no rebuild brings it back — a rebuild preserves
    // the nav node on purpose, and there is none left to preserve.
    app.clearNav();
    try app.navigate("terms");
    try testing.expect(layout.findNav(&app.tree) == null);
}

test "clearNav is not one-way: a later setNav puts the bar back" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    app.clearNav();
    try testing.expect(layout.findNav(&app.tree) == null);

    // The session begins again, from the transition rather than a
    // builder: a screen is on the tree and the install still lands.
    try app.setNav(&offroster_nav);
    const nav = layout.findNav(&app.tree).?;
    // Two destinations, not two rosters stacked.
    try testing.expectEqual(@as(usize, 2), app.nav_items.items.len);
    try testing.expectEqual(@as(usize, 2), app.tree.childCount(nav));
    var it = app.tree.children(nav);
    try testing.expectEqualStrings("Home", app.tree.getConst(it.next().?).?.nav_item.label);
}

test "clearNav takes what was pointing at the bar: the open picker and focus" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("settings");
    app.performLayout();

    // The collapsed chip's section menu is open, and focus is in it.
    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    try testing.expect(app.picker_owner != null);
    try testing.expect(layout.findPicker(&app.tree) != null);

    app.clearNav();
    // Nothing is left naming a node that no longer exists.
    try testing.expect(layout.findNav(&app.tree) == null);
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expect(app.picker_owner == null);
    try testing.expect(app.focused == null);
}

test "setNav rejects too few or too many destinations" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try testing.expectError(error.NavItemCount, app.setNav(&.{
        .{ .route = "only", .icon = .circle },
    }));
    try testing.expectError(error.NavItemCount, app.setNav(&.{
        .{ .route = "a", .icon = .circle }, .{ .route = "b", .icon = .circle },
        .{ .route = "c", .icon = .circle }, .{ .route = "d", .icon = .circle },
        .{ .route = "e", .icon = .circle }, .{ .route = "f", .icon = .circle },
    }));
}

test "a destination is a route the table has, taking no arguments" {
    var app = try offRosterApp(900);
    defer app.deinit();
    // Nothing names it, so nothing could draw it: a roster the route
    // table has never heard of is refused whole, not drawn blank.
    try testing.expectError(error.UnknownRoute, app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "nowhere", .icon = .circle },
    }));
    // `ticket` takes one: the row has no argument to press with, so the
    // destination would be inert rather than merely unnamed.
    try testing.expectError(error.RouteArgCount, app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "ticket", .icon = .circle },
    }));
    // Neither attempt left half a roster behind.
    try testing.expectEqual(@as(usize, 0), app.nav_items.items.len);
    try app.setNav(&offroster_nav);
    try testing.expectEqual(@as(usize, 2), app.nav_items.items.len);
}

test "the roster's labels are the route table's titles" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");

    var it = app.tree.children(layout.findNav(&app.tree).?);
    // Declared once, at the route table, and never restated by the nav.
    try testing.expectEqualStrings("Home", app.tree.getConst(it.next().?).?.nav_item.label);
    try testing.expectEqualStrings("Settings", app.tree.getConst(it.next().?).?.nav_item.label);
}

test "tap on content scrolled under the bottom bar hits the nav item" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 200 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildDetails },
            .{ .name = "away", .title = .{ .fixed = "Away" }, .build = buildDetails },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "away", .icon = .circle },
    });
    try app.navigate("home");
    // Overflowing content: its rects extend into the bar region.
    for (0..20) |_| {
        try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "filler" } });
    }
    app.performLayout();

    const nav = layout.findNav(&app.tree).?;
    var it = app.tree.children(nav);
    const first = it.next().?;
    try app.tap(app.tree.rectOf(first).center());
    try testing.expect(app.focused.?.on(first));
}

const SegCtx = struct {
    selected: usize = 99,
    fn onSelect(ctx: ?*anyopaque, selected: usize) void {
        const self: *SegCtx = @ptrCast(@alignCast(ctx.?));
        self.selected = selected;
    }
};

test "segmented: arrows move the selection and commit" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid", "Map" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(seg);

    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(seg).?.segmented.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);

    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try app.dispatch(.{ .key_down = .{ .key = .right } }); // clamps at the end
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);

    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);
}

test "segmented: tap selects the segment under the point" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.performLayout();
    const r = app.tree.rectOf(seg);

    try app.tap(.{ .x = r.right() - 4, .y = r.center().y });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(seg).?.segmented.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expect(app.focused.?.on(seg));

    // Re-tapping the selected segment does not re-fire the action.
    ctx.selected = 99;
    try app.tap(.{ .x = r.right() - 4, .y = r.center().y });
    try testing.expectEqual(@as(usize, 99), ctx.selected);
}

test "segmented: arrows scroll an overflowing track to reveal the selection" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    // 5 chips * 60px = 300 content in a 168px slot (164 inside the pads).
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    app.focused = .of(seg);

    for (0..4) |_| try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 4), app.tree.getConst(seg).?.segmented.selected);
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);

    try app.dispatch(.{ .key_down = .{ .key = .left } });
    // Chip 3 (180..240) was already visible at offset 136; no movement.
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);
}

// ---- inline links ----------------------------------------------------------

fn buildLinkHome(_: ?*anyopaque, app: *App) anyerror!void {
    // 9px per codepoint at the body scale. In a 168px content span the
    // greedy wrap breaks after "and", so the link straddles two lines:
    //   line 1 "Read the terms and"  — link bytes 9..18
    //   line 2 "conditions now."     — link bytes 19..29
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "terms and conditions", .route = "terms" },
        .{ .text = " now." },
    } } });
}

fn buildLinkTerms(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Terms" } });
}

const link_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildLinkHome },
    .{ .name = "terms", .title = .{ .fixed = "Terms" }, .build = buildLinkTerms },
};

test "an inline link is hit on every line it wraps across, and nowhere else" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 200, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();

    const para = focus.firstFocusable(&app.tree, app.tree.rootId()).?.node;
    var buf: [wrap.max_span_rects]@import("geometry.zig").Rect = undefined;
    const rects = input_mod.spanRectsOf(&app, para, 1, &buf);
    // Two rects, because the link crosses a wrap: one box around their
    // union would enclose "Read the " and claim to be the link.
    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(@as(i32, 16 + 81), rects[0].x); // past "Read the "
    try testing.expectEqual(@as(i32, 9 * 9), rects[0].w); // "terms and"
    try testing.expectEqual(@as(i32, 16), rects[1].x); // "conditions" starts the line
    try testing.expectEqual(@as(i32, 10 * 9), rects[1].w);
    try testing.expectEqual(rects[0].y + text.Scale.body.lineHeight(), rects[1].y);

    // The words before the link are prose, not a target — and both of
    // the link's own rects are.
    try testing.expectEqual(@as(?focus.Focus, null), app.hitTest(.{ .x = 20, .y = rects[0].center().y }));
    const stop: focus.Focus = .{ .node = para, .span = 1 };
    try testing.expect(app.hitTest(rects[0].center()).?.eql(stop));
    try testing.expect(app.hitTest(rects[1].center()).?.eql(stop));

    try app.tap(rects[1].center());
    try testing.expectEqualStrings("terms", app.router.current().?);
}

test "tab reaches an inline link and Enter navigates" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 200, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();
    var kids = app.tree.children(app.tree.rootId());
    const para = kids.next().?;

    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    // The paragraph is not focusable; the link inside it is.
    try testing.expect(!app.tree.getConst(para).?.isFocusable());
    try testing.expect(app.focused.?.eql(.{ .node = para, .span = 1 }));

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expectEqualStrings("terms", app.router.current().?);
}

test "an inline link to an unknown route is refused where every other route is" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    const para = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Go ", .route = "nowhere" },
        .{ .text = "please." },
    } } });
    app.performLayout();
    app.focused = .{ .node = para, .span = 0 };
    // The parser needs no router access to stay honest: the name is
    // resolved at activation, like a `link` element's — and refused the
    // same way, a record and an untouched stack rather than an error
    // (router.zig). The audit is what turns the record into a failing
    // test, and its `unresolvable_route` rule names this span's node
    // without waiting for the press.
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expectEqual(.unknown_route, app.router.refused.?.reason);
    try testing.expectEqualStrings("nowhere", app.router.refused.?.ref());
    try testing.expectEqual(@as(usize, 0), app.router.depth());
}

test "an external link span hands its URL to the browser and navigates nowhere" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    const para = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Mail " },
        .{ .text = "us", .external = "mailto:help@example.com" },
        .{ .text = "." },
    } } });
    app.performLayout();
    app.focused = .{ .node = para, .span = 1 };
    try app.dispatch(.{ .key_down = .{ .key = .enter } });

    // The press left the app: the journal shows the handoff, and the
    // router — which never saw a destination — still stands where it
    // stood.
    const requested = app.services.open_url.opens();
    try testing.expectEqual(1, requested.len);
    try testing.expectEqualStrings("mailto:help@example.com", requested[0]);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "an external link element activates through the open_url service" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    const link = try app.tree.appendId(app.tree.rootId(), .{ .link = .{
        .label = "Full terms",
        .external = "https://example.com/terms",
    } });
    app.performLayout();
    try input_mod.activate(&app, link);

    const requested = app.services.open_url.opens();
    try testing.expectEqual(1, requested.len);
    try testing.expectEqualStrings("https://example.com/terms", requested[0]);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "rtl: an inline link mirrors with the paragraph it sits in" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .direction = .rtl,
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    // A Persian paragraph aligns by its own bytes, so its line hangs
    // from the right margin and the runs read right to left.
    const para = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "سلام " },
        .{ .text = "شرایط", .route = "terms" },
        .{ .text = " را بخوانید" },
    } } });
    app.performLayout();

    var buf: [wrap.max_span_rects]@import("geometry.zig").Rect = undefined;
    const rects = input_mod.spanRectsOf(&app, para, 1, &buf);
    try testing.expectEqual(@as(usize, 1), rects.len);
    const r = rects[0];
    // Not at the leading (left) edge: the line hangs from the right
    // margin and the link sits inside it, one run in from the end.
    try testing.expect(r.x > 16);
    try testing.expect(r.right() < 400 - 16);

    try testing.expect(app.hitTest(r.center()).?.eql(.{ .node = para, .span = 1 }));
    // The greeting precedes it logically and therefore sits to its
    // right; it is prose, so nothing there is a target.
    try testing.expectEqual(@as(?focus.Focus, null), app.hitTest(.{ .x = r.right() + 20, .y = r.center().y }));
}

// ---- code blocks -----------------------------------------------------------

test "code block: focusable, arrows walk it sideways, up/down still page" {
    var app = try test_app.init(200, 100);
    defer app.deinit();
    // 60 codepoints at 9px = 540 in a 168px span.
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .code_block = .{ .content = "z" ** 60 } });
    for (0..40) |_| {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    app.performLayout();
    // It scrolls, so it is a tab stop — but it never activates.
    try testing.expect(app.tree.getConst(cb).?.isFocusable());
    try testing.expect(!app.tree.getConst(cb).?.isInteractive());

    app.focused = .of(cb);
    // Four mono advances per press: 4 * 9 = 36.
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(i32, 36), app.tree.getConst(cb).?.code_block.offset);
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(cb).?.code_block.offset);
    // Already at the leading end: the clamp holds, nothing wraps.
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(cb).?.code_block.offset);

    // A focused block must not trap the page's scroll keys.
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expect(app.root_scroll > 0);
}

test "code block: horizontal wheel scrolls it; vertical passes through" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .code_block = .{ .content = "q" ** 60 } });
    for (0..40) |_| {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(cb).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .delta_x = 50 } });
    try testing.expectEqual(@as(i32, 50), app.tree.getConst(cb).?.code_block.offset);
    // Past the end it clamps: 540 content in the 168px window.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .delta_x = 10000 } });
    try testing.expectEqual(@as(i32, 540 - 168), app.tree.getConst(cb).?.code_block.offset);

    // Vertical delta over it belongs to the page: a code block scrolls
    // one axis, and the other is not its business.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 30 } });
    try testing.expectEqual(@as(i32, 30), app.root_scroll);
}

test "code block: the offset does not mirror, because the lines do not" {
    var app = try test_app.mirrored(200, 400);
    defer app.deinit();
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .code_block = .{ .content = "w" ** 60 } });
    app.performLayout();

    // Verbatim content is defined by its own bytes (the QR rule), so a
    // rightward drag reveals later columns under either chrome — unlike
    // a segmented track, whose chips do lay out mirrored.
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(cb).center(), .delta_y = 0, .delta_x = 40 } });
    try testing.expectEqual(@as(i32, 40), app.tree.getConst(cb).?.code_block.offset);
}

// ---- RTL chrome direction (App.setDirection) -------------------------------

test "rtl: setDirection mirrors an intrinsic block and re-lays out" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "OK" } });
    app.performLayout();
    try testing.expectEqual(@as(i32, 16), app.tree.rectOf(btn).x); // left in LTR

    app.setDirection(.rtl);
    try testing.expect(app.layout_dirty); // the switch invalidates layout
    app.performLayout();
    try testing.expectEqual(@as(i32, 400 - 16), app.tree.rectOf(btn).right()); // right in RTL

    // Setting the same direction is a no-op — no needless relayout.
    app.layout_dirty = false;
    app.setDirection(.rtl);
    try testing.expect(!app.layout_dirty);
}

test "rtl: an app can be constructed right-to-left up front" {
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "OK" } });
    app.performLayout();
    try testing.expectEqual(@as(i32, 400 - 16), app.tree.rectOf(btn).right());
}

test "rtl: segmented arrows follow the pressed direction, not the index" {
    var ctx: SegCtx = .{};
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid", "Map" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(seg);

    // Options lay out right-to-left, so the next chip is to the LEFT:
    // ← advances the selection, → steps back — the reverse of LTR.
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(seg).?.segmented.selected);
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);
    try app.dispatch(.{ .key_down = .{ .key = .left } }); // clamps
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);
}

test "rtl: radio arrows mirror horizontally but keep the vertical axis" {
    var ctx: SegCtx = .{};
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const rg = try app.tree.appendId(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS", "None" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(rg);

    // ↓ still advances (rows never mirror); ← advances in RTL, → steps back.
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(rg).?.radio_group.selected);
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try app.dispatch(.{ .key_down = .{ .key = .up } });
    try testing.expectEqual(@as(usize, 0), ctx.selected);
}

test "rtl: a right-edge tap on segmented selects the first (rightmost) chip" {
    var ctx: SegCtx = .{};
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(seg);
    app.performLayout();
    const r = app.tree.rectOf(seg);

    // The first option holds the right end when mirrored — the reverse
    // of the LTR "right-edge tap selects the last chip" test above.
    try app.tap(.{ .x = r.right() - 4, .y = r.center().y });
    try testing.expectEqual(@as(usize, 0), app.tree.getConst(seg).?.segmented.selected);
}

test "rtl: the sheet close control pins to the left corner" {
    var app = try test_app.mirrored(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    try app.tree.append(sheet, .{ .text = .{ .content = "body" } });
    app.performLayout();

    var it = app.tree.children(sheet);
    const close = while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .sheet_close) break c;
    } else unreachable;
    try testing.expectEqual(layout.modalPaneX(app.viewport) + layout.pane_edge_h, app.tree.rectOf(close).x);
}

test "rtl: a lone minimized-notices indicator centers, having no edge to swap" {
    var app = try test_app.mirrored(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home" });
    app.minimizeNotices();
    app.performLayout();
    const ind = layout.findIndicator(&app.tree).?;
    // No nav here, so the square is the whole of the bar's group and
    // centers as one — the same place under either direction, because a
    // centered control is its own mirror image. It is the pane's corner
    // it no longer keeps: the sheet cap governs prose, and this is a
    // control.
    try testing.expectEqual(
        layout.navGroupX(app.viewport, layout.metrics.touch_target),
        app.tree.rectOf(ind).x,
    );

    var ltr = try test_app.init(400, 600);
    defer ltr.deinit();
    ltr.notify(.{ .title = "Saved", .route = "home" });
    ltr.minimizeNotices();
    ltr.performLayout();
    try testing.expectEqual(
        ltr.tree.rectOf(layout.findIndicator(&ltr.tree).?),
        app.tree.rectOf(ind),
    );
}

test "segmented: horizontal scroll moves the track without changing the selection" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    app.performLayout();
    const at = app.tree.rectOf(seg).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = 60, .delta_y = 0 } });
    try testing.expectEqual(@as(i32, 60), app.tree.getConst(seg).?.segmented.offset);
    try testing.expectEqual(@as(usize, 0), app.tree.getConst(seg).?.segmented.selected);

    // Free scroll survives an unrelated relayout: no snap back.
    app.invalidate();
    app.performLayout();
    try testing.expectEqual(@as(i32, 60), app.tree.getConst(seg).?.segmented.offset);

    // Clamped at both ends.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = 10000, .delta_y = 0 } });
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = -10000, .delta_y = 0 } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(seg).?.segmented.offset);
}

test "segmented: a touch drag keeps the track after the finger drifts off it" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    app.performLayout();
    const at = app.tree.rectOf(seg).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .begin } });
    // The move's point is far below the track; the lock still routes to it.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 100, .y = 300 }, .delta_x = 60, .delta_y = 0, .phase = .move } });
    try testing.expectEqual(@as(i32, 60), app.tree.getConst(seg).?.segmented.offset);
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .end } });
}

test "scroll: the dominant axis wins and the minor one is dropped" {
    var app = try test_app.init(200, 100);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    // Tall filler so the window itself can scroll vertically.
    for (0..20) |_| try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Filler" } });
    app.performLayout();
    const at = app.tree.rectOf(seg).center();

    // Mostly horizontal: the slight vertical jitter must not move the page.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = 40, .delta_y = 3 } });
    try testing.expectEqual(@as(i32, 40), app.tree.getConst(seg).?.segmented.offset);
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    // Mostly vertical: the slight horizontal jitter must not move the track.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = -3, .delta_y = 40 } });
    try testing.expectEqual(@as(i32, 40), app.tree.getConst(seg).?.segmented.offset);
    try testing.expectEqual(@as(i32, 40), app.root_scroll);
}

test "segmented: tap honors the scroll offset" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{
        .label = "K",
        .options = opts,
        .selected = 4,
    } });
    app.performLayout();
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);
    const r = app.tree.rectOf(seg);

    // At offset 136 the track's left edge shows chip 2 (content 120..180).
    try app.tap(.{ .x = r.x + 6, .y = r.center().y });
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);
    // The tapped chip, clipped at the edge, scrolls fully into view.
    try testing.expectEqual(@as(i32, 120), app.tree.getConst(seg).?.segmented.offset);
}

test "radio group: arrows move the selection and commit" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const rg = try app.tree.appendId(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS", "None" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(rg);

    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);

    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .down } }); // clamps at the end
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(rg).?.radio_group.selected);

    try app.dispatch(.{ .key_down = .{ .key = .up } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);

    // ←/→ mirror ↑/↓, matching ARIA radio-group practice.
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 0), ctx.selected);
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);
}

test "radio group: tap selects the row under the point" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const rg = try app.tree.appendId(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.performLayout();
    const r = app.tree.rectOf(rg);

    try app.tap(.{ .x = r.x + 4, .y = r.bottom() - 4 });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expect(app.focused.?.on(rg));

    // Re-tapping the selected row does not re-fire the action.
    ctx.selected = 99;
    try app.tap(.{ .x = r.x + 4, .y = r.bottom() - 4 });
    try testing.expectEqual(@as(usize, 99), ctx.selected);

    try app.tap(.{ .x = r.x + 4, .y = r.y + layout.radioRowY(0) + 4 });
    try testing.expectEqual(@as(usize, 0), ctx.selected);
}

test "select: enter opens the picker focused on the current choice" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch", "Français" },
        .selected = 1,
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const picker = layout.findPicker(&app.tree).?;
    try testing.expectEqualStrings("Language", app.tree.getConst(picker).?.picker.title);
    const item = app.tree.getConst(app.focused.?.node).?.picker_item;
    try testing.expectEqualStrings("Deutsch", item.label);
    try testing.expect(item.selected);
}

test "picker: escape closes without committing and restores focus" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 0), app.tree.getConst(sel).?.select.selected);
    try testing.expectEqual(@as(usize, 99), ctx.selected);
    try testing.expect(app.focused.?.on(sel));
}

test "picker: activating a row commits the choice and closes" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch", "Français" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(sel).?.select.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expect(app.focused.?.on(sel));

    // Re-choosing the current option does not re-fire the action.
    ctx.selected = 99;
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expectEqual(@as(usize, 99), ctx.selected);
}

const filter_test_options: []const []const u8 = &.{
    "Argentina", "Australia", "Austria", "Brazil",  "Canada",
    "Denmark",   "Germany",   "Iceland", "Ireland",
};

test "picker: long option lists gain a filter field, focused on open" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Country",
        .options = filter_test_options,
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const input = app.tree.getConst(app.focused.?.node).?.text_input;
    try testing.expectEqualStrings("Filter", input.label);

    // Short lists stay bare and keep focus on the current choice.
    var short = try test_app.init(400, 600);
    defer short.deinit();
    const s = try short.tree.appendId(short.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    short.focused = .of(s);
    try short.dispatch(.{ .key_down = .{ .key = .enter } });
    const picker = layout.findPicker(&short.tree).?;
    var it = short.tree.children(picker);
    while (it.next()) |c| {
        try testing.expect(short.tree.getConst(c).?.role() != .text_input);
    }
    try testing.expect(short.tree.getConst(short.focused.?.node).?.role() == .picker_item);
}

test "picker: typing filters rows and a filtered row commits its option index" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Country",
        .options = filter_test_options,
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .text = .{ .bytes = "ice" } }); // case-insensitive: Iceland
    const picker = layout.findPicker(&app.tree).?;
    var region: ?NodeId = null;
    var it = app.tree.children(picker);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .scroll_region) region = c;
    }
    try testing.expectEqual(@as(usize, 1), app.tree.childCount(region.?));

    // Tab to the lone row and commit: the original option index fires.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expectEqualStrings("Iceland", app.tree.getConst(app.focused.?.node).?.picker_item.label);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 7), ctx.selected);
    try testing.expectEqual(@as(usize, 7), app.tree.getConst(sel).?.select.selected);
}

test "picker: backspace re-widens the filter and no matches leaves words" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Country",
        .options = filter_test_options,
    } });
    app.focused = .of(sel);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });

    const regionOf = struct {
        fn call(a: *App) NodeId {
            const picker = layout.findPicker(&a.tree).?;
            var it = a.tree.children(picker);
            while (it.next()) |c| {
                if (a.tree.getConst(c).?.role() == .scroll_region) return c;
            }
            unreachable;
        }
    }.call;

    try app.dispatch(.{ .text = .{ .bytes = "xyz" } });
    const region = regionOf(&app);
    try testing.expectEqual(@as(usize, 1), app.tree.childCount(region));
    var it = app.tree.children(region);
    const lone = app.tree.getConst(it.next().?).?;
    try testing.expect(lone.role() == .text);
    try testing.expectEqualStrings("No matches", lone.text.content);

    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try testing.expectEqual(filter_test_options.len, app.tree.childCount(regionOf(&app)));
}

test "picker: arrows clamp at the option list ends" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .up } }); // already first: stays
    try testing.expectEqualStrings("English", app.tree.getConst(app.focused.?.node).?.picker_item.label);
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .down } }); // clamps at the end
    try testing.expectEqualStrings("Deutsch", app.tree.getConst(app.focused.?.node).?.picker_item.label);
}

test "picker: taps commit on a row and cancel on the scrim" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    app.performLayout();
    try app.tap(.{ .x = 4, .y = 4 }); // scrim: cancels
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 99), ctx.selected);
    try testing.expect(app.focused.?.on(sel));

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    app.performLayout();
    const picker = layout.findPicker(&app.tree).?;
    var region_it = app.tree.children(picker);
    const region = region_it.next().?;
    var it = app.tree.children(region);
    _ = it.next();
    const second = it.next().?;
    try app.tap(app.tree.rectOf(second).center());
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(sel).?.select.selected);
}

test "picker stacks above an open sheet and escape peels one layer" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    const sel = try app.tree.appendId(sheet, .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const picker = layout.findPicker(&app.tree).?;
    try testing.expect(app.focusScope().eql(picker));

    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expect(layout.findSheet(&app.tree) != null);
    try testing.expect(app.focused.?.on(sel));

    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findSheet(&app.tree) == null);
}

test "presentSheet focuses its close button and confines tab to the sheet" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Behind" } });
    app.focused = .of(behind);

    const sheet = try app.presentSheet("Options");
    const close = focus.firstFocusable(&app.tree, sheet).?.node;
    try testing.expect(app.focused.?.on(close));

    const extra = try app.tree.appendId(sheet, .{ .toggle = .{ .label = "Wrap text" } });
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(extra));
    // Wraps inside the sheet; "Behind" is unreachable while it is open.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(close));
}

test "escape dismisses the sheet and restores focus to the invoker" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Behind" } });
    app.focused = .of(behind);

    _ = try app.presentSheet("Options");
    try app.dispatch(.{ .key_down = .{ .key = .escape } });

    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.focused.?.on(behind));
}

/// The declared-sheet fixture: a controller in miniature — an enum
/// saying which sheet is wanted, state the builder reads, and the two
/// callbacks a `SheetBuilder` carries.
const SheetHost = struct {
    sheet: enum { none, confirm } = .none,
    label: []const u8 = "Delete",
    builds: u32 = 0,
    dismissed: u32 = 0,

    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *SheetHost = @ptrCast(@alignCast(ctx.?));
        if (self.sheet == .none) return;
        self.builds += 1;
        const sheet = try app.presentSheet("Confirm");
        try app.tree.append(sheet, .{ .button = .{ .label = self.label } });
    }

    fn onDismiss(ctx: ?*anyopaque) void {
        const self: *SheetHost = @ptrCast(@alignCast(ctx.?));
        self.sheet = .none;
        self.dismissed += 1;
    }

    fn builder(self: *SheetHost) App.SheetBuilder {
        return .{ .ctx = self, .call = build, .on_dismiss = onDismiss };
    }
};

/// Whether the open sheet holds a button with exactly `label`.
fn sheetHasButton(app: *App, label: []const u8) bool {
    const sheet = layout.findSheet(&app.tree) orelse return false;
    var it = app.tree.children(sheet);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.role() == .button and std.mem.eql(u8, el.button.label, label)) return true;
    }
    return false;
}

test "openSheet builds the declared sheet and rebuilds it in place" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Behind" } });
    app.focused = .of(behind);

    var host: SheetHost = .{ .sheet = .confirm };
    try app.openSheet(host.builder());
    try testing.expect(sheetHasButton(&app, "Delete"));
    try testing.expectEqual(@as(u32, 1), host.builds);

    // State changed under the open sheet: the same call again is the
    // whole ceremony, and the sheet is rebuilt in place, not stacked.
    host.label = "Really delete";
    try app.openSheet(host.builder());
    try testing.expect(sheetHasButton(&app, "Really delete"));
    try testing.expectEqual(@as(u32, 2), host.builds);
    // A rebuild is not a closure.
    try testing.expectEqual(@as(u32, 0), host.dismissed);

    // And the rebuilt sheet still remembers the original invoker.
    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(app.focused.?.on(behind));
}

test "the framework's dismissals tell the declared sheet's on_dismiss" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    var host: SheetHost = .{ .sheet = .confirm };
    try app.openSheet(host.builder());

    // Esc is the framework's dismissal, not the consumer's: without the
    // callback the controller's state would still say the sheet is open,
    // and its next refresh would put a dismissed dialog back.
    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expectEqual(@as(u32, 1), host.dismissed);
    try testing.expect(host.sheet == .none);
    try testing.expect(app.sheet_builder == null);
}

test "a builder that presents nothing declines quietly" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    // The sheet's subject vanished before the build: the state already
    // says .none, so there is no closure to announce.
    var host: SheetHost = .{ .sheet = .none };
    try app.openSheet(host.builder());
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.sheet_builder == null);
    try testing.expectEqual(@as(u32, 0), host.dismissed);
}

fn buildHalfThenFail(_: ?*anyopaque, app: *App) anyerror!void {
    const sheet = try app.presentSheet("Confirm");
    try app.tree.append(sheet, .{ .button = .{ .label = "Half" } });
    return error.SheetFixture;
}

test "a builder that fails strands no half-built sheet" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Behind" } });
    app.focused = .of(behind);

    try testing.expectError(error.SheetFixture, app.openSheet(.{ .call = buildHalfThenFail }));
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.sheet_builder == null);
    try testing.expect(app.focused.?.on(behind));
}

test "openSheetTag answers the declared tag while the sheet is up, null when closed" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    try testing.expectEqual(@as(?u32, null), app.openSheetTag());

    var host: SheetHost = .{ .sheet = .confirm };
    var b = host.builder();
    b.tag = 7;
    try app.openSheet(b);
    try testing.expectEqual(@as(?u32, 7), app.openSheetTag());

    // Rebuild-in-place keeps the identity with the builder it rides on.
    try app.openSheet(b);
    try testing.expectEqual(@as(?u32, 7), app.openSheetTag());

    app.dismissSheet();
    try testing.expectEqual(@as(?u32, null), app.openSheetTag());

    // A builder that declines leaves no sheet and so no name for one.
    host.sheet = .none;
    try app.openSheet(b);
    try testing.expectEqual(@as(?u32, null), app.openSheetTag());

    // A bare `presentSheet` never declared a builder: that sheet has no
    // consumer name (and dies on reload besides).
    _ = try app.presentSheet("Options");
    try testing.expectEqual(@as(?u32, null), app.openSheetTag());
}

/// The dismissal-ordering fixture: records what `openSheetTag` says
/// *inside* `on_dismiss`, where consumer state code runs.
const DismissOrderHost = struct {
    app: *App,
    told: bool = false,
    tag_inside: ?u32 = 99, // overwritten; 99 = "handler never ran"

    fn build(_: ?*anyopaque, app: *App) anyerror!void {
        _ = try app.presentSheet("Confirm");
    }

    fn onDismiss(ctx: ?*anyopaque) void {
        const self: *DismissOrderHost = @ptrCast(@alignCast(ctx.?));
        self.told = true;
        self.tag_inside = self.app.openSheetTag();
    }
};

test "on_dismiss is told after the tag is gone: the callback reads a closed sheet" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    var host: DismissOrderHost = .{ .app = &app };
    try app.openSheet(.{ .ctx = &host, .tag = 9, .call = DismissOrderHost.build, .on_dismiss = DismissOrderHost.onDismiss });
    try testing.expectEqual(@as(?u32, 9), app.openSheetTag());

    // The builder is let go before its `on_dismiss` is told, so state
    // code in the callback sees "closed" — never a ghost of the sheet
    // it is recording the closure of.
    app.dismissSheet();
    try testing.expect(host.told);
    try testing.expectEqual(@as(?u32, null), host.tag_inside);
}

// ---- refresh: the composed polite-update verb (docs/routing.md) ----

/// A controller in miniature for `App.refresh`: state the builders
/// read, counting every run, over a screen that carries an editable —
/// the thing a polite rebuild must leave alone.
const RefreshHost = struct {
    screen_builds: u32 = 0,
    sheet_builds: u32 = 0,
    refresh_in_build: bool = false,

    fn buildScreen(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *RefreshHost = @ptrCast(@alignCast(ctx.?));
        self.screen_builds += 1;
        try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Notes" } });
        try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Title" } });
        // A builder-issued load answered synchronously: its callback
        // says refresh, and the polite verb declines quietly — the
        // builder reads the answered state the line after.
        if (self.refresh_in_build) app.refresh(.{});
    }

    fn buildSheet(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *RefreshHost = @ptrCast(@alignCast(ctx.?));
        self.sheet_builds += 1;
        const sheet = try app.presentSheet("Confirm");
        try app.tree.append(sheet, .{ .button = .{ .label = "Delete" } });
    }

    fn fixture(self: *RefreshHost) !App {
        return App.init(testing.allocator, .{
            .viewport = .{ .w = 400, .h = 600 },
            .routes = &.{
                .{ .name = "notes", .title = .{ .fixed = "Notes" }, .build = buildScreen },
                .{ .name = "docs", .title = .{ .fixed = "Docs" }, .build = buildLabeled },
            },
            .ctx = self,
            .services = .mocks(),
        });
    }
};

fn buildLabeled(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Docs" } });
}

test "refresh reloads, and the route filter scopes it to the screen on top" {
    var host: RefreshHost = .{};
    var app = try host.fixture();
    defer app.deinit();
    try app.navigate("notes");
    try testing.expectEqual(@as(u32, 1), host.screen_builds);

    // Nothing held: a refresh is a reload, scroll-and-focus semantics
    // and all (the router's own verb underneath).
    app.refresh(.{});
    try testing.expectEqual(@as(u32, 2), host.screen_builds);

    // The reply that lands after the user walked away: the named route
    // is not on top, so the screen it no longer owns is left alone —
    // and naming the one showing still reloads.
    app.refresh(.{ .route = "docs" });
    try testing.expectEqual(@as(u32, 2), host.screen_builds);
    app.refresh(.{ .route = "notes" });
    try testing.expectEqual(@as(u32, 3), host.screen_builds);
}

test "refresh leaves an edit in flight alone; reload takes it" {
    var host: RefreshHost = .{};
    var app = try host.fixture();
    defer app.deinit();
    try app.navigate("notes");

    // The user is mid-edit: caret, composition, and the unwritten
    // value die with the field's node, so the polite verb declines.
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.* == .text_input) app.focused = .of(id);
    }
    app.refresh(.{});
    try testing.expectEqual(@as(u32, 1), host.screen_builds);

    // The deliberate gesture never asks — same state, same screen, and
    // the edit goes with it, which is what deliberate means.
    try app.reload();
    try testing.expectEqual(@as(u32, 2), host.screen_builds);
}

test "refresh re-runs the open sheet's builder instead of reloading under it" {
    var host: RefreshHost = .{};
    var app = try host.fixture();
    defer app.deinit();
    try app.navigate("notes");
    try app.openSheet(.{ .ctx = &host, .call = RefreshHost.buildSheet });
    try testing.expectEqual(@as(u32, 1), host.sheet_builds);

    // The sheet owns the screen, so it is what answers the changed
    // state: rebuilt in place, while the content behind it — and the
    // route filter's meaning — stay exactly as the hand policies kept
    // them (the sheet stands on the route that opened it).
    app.refresh(.{});
    try testing.expectEqual(@as(u32, 2), host.sheet_builds);
    try testing.expectEqual(@as(u32, 1), host.screen_builds);
    app.refresh(.{ .route = "notes" });
    try testing.expectEqual(@as(u32, 3), host.sheet_builds);
}

test "the sheet's tag survives refresh's re-present and reload's carry" {
    var host: RefreshHost = .{};
    var app = try host.fixture();
    defer app.deinit();
    try app.navigate("notes");
    try app.openSheet(.{ .ctx = &host, .tag = 3, .call = RefreshHost.buildSheet });
    try testing.expectEqual(@as(?u32, 3), app.openSheetTag());

    // The kept builder carries the tag, so both promises that keep the
    // sheet alive keep its name: refresh's re-present…
    app.refresh(.{});
    try testing.expectEqual(@as(u32, 2), host.sheet_builds);
    try testing.expectEqual(@as(?u32, 3), app.openSheetTag());

    // …and the reload that rebuilds the screen under it.
    try app.reload();
    try testing.expectEqual(@as(u32, 3), host.sheet_builds);
    try testing.expectEqual(@as(?u32, 3), app.openSheetTag());

    // Navigation is a closure, and takes the name with the sheet.
    try app.navigate("docs");
    try testing.expectEqual(@as(?u32, null), app.openSheetTag());
}

test "refresh from inside a build declines quietly, with nothing on the record" {
    var host: RefreshHost = .{ .refresh_in_build = true };
    var app = try host.fixture();
    defer app.deinit();
    try app.navigate("notes");

    // One build, one screen — and unlike a re-entrant `reload`, no
    // refusal: from a synchronously-answered load's callback the polite
    // verb declining is a normal flow, not a programmer error.
    try testing.expectEqual(@as(u32, 1), host.screen_builds);
    try testing.expect(app.router.refused == null);
}

test "tap on the scrim dismisses the sheet; background is not hittable" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Behind",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });
    app.performLayout();
    const behind_center = app.tree.rectOf(behind).center();

    _ = try app.presentSheet("Options");
    // The background button sits under the scrim: tapping it must not
    // activate it, only dismiss the sheet.
    try app.tap(behind_center);
    try testing.expectEqual(@as(u32, 0), counter.count);
    try testing.expect(layout.findSheet(&app.tree) == null);

    try app.tap(behind_center);
    try testing.expectEqual(@as(u32, 1), counter.count);
}

test "notify shows the front notice as a banner and dedups by title" {
    var app = try test_app.init(400, 600);
    defer app.deinit();

    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    app.notify(.{ .title = "Sync failed", .description = "Changes kept locally.", .route = "details", .important = true });
    app.notify(.{ .title = "Saved", .route = "home", .important = true }); // duplicate: dropped
    try testing.expectEqual(@as(usize, 2), app.notices.items.len);
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);

    const first = layout.findNotice(&app.tree).?;
    try testing.expectEqualStrings("Saved", app.tree.getConst(first).?.notice.title);

    app.dismissNotice();
    const second = layout.findNotice(&app.tree).?;
    try testing.expectEqualStrings("Sync failed", app.tree.getConst(second).?.notice.title);

    app.dismissNotice();
    try testing.expect(layout.findNotice(&app.tree) == null);
    try testing.expectEqual(App.NoticeState.none, app.notice_state);
}

test "notify is infallible: void-typed, and no allocator is touched after init" {
    // The signature is the contract: there was never anything a
    // consumer could do with the old error, so there is no error.
    comptime std.debug.assert(@typeInfo(@TypeOf(notices_mod.notify)).@"fn".return_type.? == void);

    var app = try test_app.init(400, 600);
    defer app.deinit();
    // Every slot was reserved at init; from here a notice is a copy
    // into paid-for memory — proven by handing the app an allocator
    // that refuses everything. (The chrome resync draws on the tree's
    // own allocator, captured at its init, so the banner still stands.)
    const real_gpa = app.gpa;
    defer app.gpa = real_gpa;
    app.gpa = testing.failing_allocator;
    app.notify(.{ .title = "Saved", .description = "Synced.", .route = "home", .important = true });
    try testing.expectEqual(@as(usize, 1), app.notices.items.len);
    try testing.expectEqualStrings("Saved", app.notices.items[0].title());
    try testing.expect(layout.findNotice(&app.tree) != null);
}

test "a full ring evicts drop-oldest, quiet before important" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Important 0", .important = true });
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < notices_mod.max_pending - 1) : (i += 1) {
        app.notify(.{ .title = std.fmt.bufPrint(&buf, "Quiet {d}", .{i}) catch unreachable });
    }
    try testing.expectEqual(notices_mod.max_pending, app.notices.items.len);

    // One past the bound: the longest-waiting *quiet* notice goes —
    // never the banner's important front, which outranks it.
    app.notify(.{ .title = "Quiet last" });
    try testing.expectEqual(notices_mod.max_pending, app.notices.items.len);
    try testing.expectEqualStrings("Important 0", app.notices.items[0].title());
    try testing.expectEqualStrings("Quiet 1", app.notices.items[1].title());
    try testing.expectEqualStrings("Quiet last", app.notices.items[app.notices.items.len - 1].title());
}

test "a ring of nothing but important notices evicts its own front" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < notices_mod.max_pending) : (i += 1) {
        app.notify(.{ .title = std.fmt.bufPrint(&buf, "Important {d}", .{i}) catch unreachable, .important = true });
    }
    try testing.expectEqualStrings("Important 0", app.notices.items[0].title());

    // With no quiet notice to give up, the oldest important goes; the
    // newcomer joins the back of the group like any other arrival.
    app.notify(.{ .title = "Important new", .important = true });
    try testing.expectEqual(notices_mod.max_pending, app.notices.items.len);
    try testing.expectEqualStrings("Important 1", app.notices.items[0].title());
    try testing.expectEqualStrings("Important new", app.notices.items[app.notices.items.len - 1].title());
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);
}

test "an overlong title is clipped at a codepoint boundary and dedups on the stored form" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    // 127 ASCII bytes then a two-byte codepoint straddling the cap:
    // storing 128 bytes would keep half of "é", so the clip backs up.
    var long: [notices_mod.max_title_bytes + 1]u8 = undefined;
    @memset(long[0 .. notices_mod.max_title_bytes - 1], 'a');
    long[notices_mod.max_title_bytes - 1] = 0xC3; // "é",
    long[notices_mod.max_title_bytes] = 0xA9; // split by the cap
    app.notify(.{ .title = &long });
    try testing.expectEqual(@as(usize, 1), app.notices.items.len);
    try testing.expectEqual(notices_mod.max_title_bytes - 1, app.notices.items[0].title().len);

    // The stored form is the identity: raising the clipped twin —
    // byte-identical once stored — is the duplicate dedup drops.
    app.notify(.{ .title = long[0 .. notices_mod.max_title_bytes - 1] });
    try testing.expectEqual(@as(usize, 1), app.notices.items.len);
}

test "the banner reserves its band at the viewport bottom" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Go" } });

    app.performLayout();
    const before = app.tree.rectOf(btn).y;

    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    app.performLayout();
    const banner = app.tree.rectOf(layout.findNotice(&app.tree).?);
    try testing.expect(banner.h > 0);
    try testing.expectEqual(@as(i32, 600), banner.bottom());
    try testing.expectEqual(banner.y, layout.contentArea(&app.tree, app.viewport, app.safe_bottom).bottom());
    try testing.expectEqual(before, app.tree.rectOf(btn).y);
}

test "notice never steals focus and dismissal keeps focus sane" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Go" } });
    app.focused = .of(btn);

    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    try testing.expect(app.focused.?.on(btn));

    // Focus a banner control, then dismiss: focus must not dangle.
    const notice = layout.findNotice(&app.tree).?;
    app.focused = focus.firstFocusable(&app.tree, notice).?;
    app.dismissNotice();
    try testing.expect(app.focused == null);
}

test "notices expand to the pane, minimize to the indicator, and reopen" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    app.notify(.{ .title = "Sync failed", .route = "details", .important = true });

    // With several pending, the banner leads with the expand control.
    const banner = layout.findNotice(&app.tree).?;
    const expand = focus.firstFocusable(&app.tree, banner).?.node;
    try testing.expectEqual(element_mod.Glyph.expand, app.tree.getConst(expand).?.icon_button.glyph);
    try app.activate(expand);
    try testing.expect(layout.findNoticesPane(&app.tree) != null);
    try testing.expectEqual(App.NoticeState.pane, app.notice_state);

    // Esc minimizes; the notices stay pending behind the indicator.
    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findNoticesPane(&app.tree) == null);
    try testing.expectEqual(@as(usize, 2), app.notices.items.len);
    const indicator = layout.findIndicator(&app.tree).?;

    try app.activate(indicator);
    try testing.expect(layout.findNoticesPane(&app.tree) != null);
}

/// The pane's scroll region, and the rows it holds.
fn noticesRegion(app: *App) ?NodeId {
    const pane = layout.findNoticesPane(&app.tree) orelse return null;
    var it = app.tree.children(pane);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .scroll_region) return c;
    }
    return null;
}

test "the notices pane keeps its rows reachable on a landscape viewport" {
    // A phone on its side: `sheet_min_top` is a bigger share of 390 than
    // of 844, so the pane runs out of room after very few notices. The
    // rows used to be flowed into it unbounded and simply clipped at its
    // edge, which lost them — no wheel, no drag, no tab stop reached
    // them, and the pane gave no sign there was more.
    var app = try test_app.init(844, 390);
    defer app.deinit();
    for ([_][]const u8{ "Settings saved", "Sync failed", "Primes counted", "Payload hashed", "Export ready" }) |t| {
        app.notify(.{ .title = t, .description = "This notice stays until dismissed or minimized.", .route = "home" });
    }
    try app.openNoticesPane();
    app.performLayout();

    const pane = layout.findNoticesPane(&app.tree).?;
    const pr = app.tree.rectOf(pane);
    const reg = noticesRegion(&app).?;
    const rr = app.tree.rectOf(reg);

    // The pane still honours its cap and the region still sits inside it.
    try testing.expect(pr.y >= layout.metrics.sheet_min_top);
    try testing.expect(pr.bottom() <= 390);
    try testing.expect(rr.bottom() <= pr.bottom());

    // There is more content than room, and the region says so — which is
    // what makes it scrollable and what draws the indicator.
    const sr = app.tree.getConst(reg).?.scroll_region;
    try testing.expect(sr.content_height > rr.h);

    // And it is reachable: a scroll region is focusable precisely so the
    // hidden rows have a keyboard route (WCAG 2.1.1).
    try testing.expect(app.tree.getConst(reg).?.isFocusable());
    const before = app.tree.getConst(reg).?.scroll_region.offset;
    try app.dispatch(.{ .scroll = .{ .at = rr.center(), .delta_y = 80 } });
    try testing.expect(app.tree.getConst(reg).?.scroll_region.offset > before);
    // The last row lands inside the region once scrolled to the end.
    try app.dispatch(.{ .scroll = .{ .at = rr.center(), .delta_y = 10000 } });
    app.performLayout();
    var rows = app.tree.children(reg);
    var last: ?NodeId = null;
    while (rows.next()) |c| last = c;
    try testing.expect(app.tree.rectOf(last.?).bottom() <= app.tree.rectOf(reg).bottom());
}

test "a notices pane that fits takes only the height it needs" {
    var app = try test_app.init(400, 800);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home" });
    try app.openNoticesPane();
    app.performLayout();

    const pr = app.tree.rectOf(layout.findNoticesPane(&app.tree).?);
    const reg = noticesRegion(&app).?;
    const sr = app.tree.getConst(reg).?.scroll_region;
    // Nothing hidden, nothing to scroll, and the pane is far short of the
    // cap: the region is exactly its content.
    try testing.expectEqual(sr.content_height, app.tree.rectOf(reg).h);
    try testing.expect(pr.h < 800 - layout.metrics.sheet_min_top);
    try testing.expectEqual(@as(i32, 800), pr.bottom());
}

test "the pane's dismiss controls remove one notice or all" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home" });
    app.notify(.{ .title = "Sync failed", .route = "details" });
    try app.openNoticesPane();

    const pane = layout.findNoticesPane(&app.tree).?;
    var dismiss: ?NodeId = null;
    var it = app.tree.dfsUnder(pane);
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.* == .icon_button and el.icon_button.glyph == .dismiss) {
            dismiss = id;
            break;
        }
    }
    try app.activate(dismiss.?);
    try testing.expectEqual(@as(usize, 1), app.notices.items.len);
    try testing.expectEqualStrings("Sync failed", app.notices.items[0].title());
    try testing.expect(layout.findNoticesPane(&app.tree) != null);

    // The header's dismiss-all control empties the rest.
    const pane2 = layout.findNoticesPane(&app.tree).?;
    var all: ?NodeId = null;
    var headers = app.tree.children(pane2);
    while (headers.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.* == .icon_button and el.icon_button.glyph == .dismiss_all) all = c;
    }
    try app.activate(all.?);
    try testing.expectEqual(App.NoticeState.none, app.notice_state);
    try testing.expect(layout.findNoticesPane(&app.tree) == null);
    try testing.expect(layout.findIndicator(&app.tree) == null);
}

test "a new important notice re-surfaces minimized ones as the banner" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    app.minimizeNotices();
    try testing.expect(layout.findIndicator(&app.tree) != null);

    app.notify(.{ .title = "Sync failed", .route = "details", .important = true });
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);
    try testing.expect(layout.findNotice(&app.tree) != null);
    try testing.expect(layout.findIndicator(&app.tree) == null);
}

test "a quiet notice lands behind the indicator without a banner" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Export ready", .route = "exports" });
    try testing.expectEqual(App.NoticeState.minimized, app.notice_state);
    try testing.expect(layout.findNotice(&app.tree) == null);
    try testing.expect(layout.findIndicator(&app.tree) != null);

    // A second quiet one accumulates; a banner already up stays on its
    // own notice; a pane already open lists the newcomer — no state
    // changes hands either way.
    app.notify(.{ .title = "Backup done", .route = "home" });
    try testing.expectEqual(App.NoticeState.minimized, app.notice_state);
    try testing.expectEqual(@as(usize, 2), app.notices.items.len);
}

test "important notices stand in front of quiet ones" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Export ready", .route = "exports" });
    app.notify(.{ .title = "Sync failed", .route = "details", .important = true });

    // The important arrival claims the banner even though it came last.
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);
    try testing.expectEqualStrings("Sync failed", app.notices.items[0].title());
    const banner = layout.findNotice(&app.tree).?;
    try testing.expectEqualStrings("Sync failed", app.tree.getConst(banner).?.notice.title);
}

test "dismissing the last important collapses the banner to the indicator" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Export ready", .route = "exports" });
    app.notify(.{ .title = "Sync failed", .route = "details", .important = true });

    // Quiet notices never claim the banner — not even by succession.
    app.dismissNotice();
    try testing.expectEqual(App.NoticeState.minimized, app.notice_state);
    try testing.expect(layout.findNotice(&app.tree) == null);
    try testing.expect(layout.findIndicator(&app.tree) != null);
    try testing.expectEqual(@as(usize, 1), app.notices.items.len);
}

test "the pane groups important and quiet notices under labels" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Export ready", .route = "exports" });
    app.notify(.{ .title = "Sync failed", .route = "details", .important = true });
    try app.openNoticesPane();

    // Important leads, and each group takes its label.
    const reg = noticesRegion(&app).?;
    var it = app.tree.children(reg);
    try testing.expectEqualStrings("Important", app.tree.getConst(it.next().?).?.text.content);
    try testing.expectEqualStrings("Sync failed", app.tree.getConst(it.next().?).?.notice.title);
    try testing.expectEqualStrings("Other", app.tree.getConst(it.next().?).?.text.content);
    try testing.expectEqualStrings("Export ready", app.tree.getConst(it.next().?).?.notice.title);
    try testing.expect(it.next() == null);
    app.minimizeNotices();

    // One kind pending — nothing to tell apart, so no labels.
    app.dismissNoticeAt(1);
    try app.openNoticesPane();
    var rows = app.tree.children(noticesRegion(&app).?);
    try testing.expectEqualStrings("Sync failed", app.tree.getConst(rows.next().?).?.notice.title);
    try testing.expect(rows.next() == null);
}

test "a notice's icon narrows the words' column by its square and gap" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    app.performLayout();
    const bare = layout.noticeTextRegion(&app.tree, layout.findNotice(&app.tree).?, false);

    app.dismissAllNotices();
    app.notify(.{ .title = "Saved", .route = "home", .icon = .circle_check, .important = true });
    app.performLayout();
    const marked = layout.noticeTextRegion(&app.tree, layout.findNotice(&app.tree).?, false);

    const slot = text.Scale.body.lineHeight() + layout.metrics.icon_gap;
    try testing.expectEqual(bare.w - slot, marked.w);
    try testing.expectEqual(bare.x + slot, marked.x);
}

test "a sheet suppresses notice chrome to the indicator until dismissed" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home", .important = true });

    _ = try app.presentSheet("Options");
    try testing.expect(layout.findNotice(&app.tree) == null);
    try testing.expect(layout.findIndicator(&app.tree) != null);
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);

    app.dismissSheet();
    try testing.expect(layout.findNotice(&app.tree) != null);
    try testing.expect(layout.findIndicator(&app.tree) == null);
}

test "the banner hides the nav from pointer and keyboard alike" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 600 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildDetails },
            .{ .name = "away", .title = .{ .fixed = "Away" }, .build = buildDetails },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "away", .icon = .circle },
    });
    try app.navigate("home");
    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    app.performLayout();

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(i32, 0), app.tree.rectOf(nav).w);

    // Tab cycles through banner controls and content, never nav items.
    var hops: usize = 0;
    while (hops < 16) : (hops += 1) {
        try app.dispatch(.{ .key_down = .{ .key = .tab } });
        const f = app.focused.?.node;
        try testing.expect(!app.tree.isDescendant(f, nav));
    }
}

test "copyText journals into the app's clipboard mock" {
    const Copier = struct {
        app: *App,
        fn onPress(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.app.copyText("XKCD-1234");
        }
    };

    var app = try test_app.init(400, 400);
    defer app.deinit();
    var copier: Copier = .{ .app = &app };
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Copy code",
        .on_press = .{ .ctx = &copier, .call = Copier.onPress },
    } });
    app.performLayout();

    try app.tap(app.tree.rectOf(btn).center());
    const copies = app.services.clipboard.copies();
    try testing.expectEqual(1, copies.len);
    try testing.expectEqualStrings("XKCD-1234", copies[0]);
}

test "activating a copyable writes its value to the clipboard" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{
        .label = "Recovery code",
        .value = "XKCD-1234",
    } });
    app.performLayout();

    // Tap copies; so do Enter and Space on the focused field. The
    // journal keeps program order, so both writes are on the record.
    try app.tap(app.tree.rectOf(c).center());
    try testing.expectEqualStrings("XKCD-1234", app.services.clipboard.copies()[0]);
    try testing.expect(app.focused.?.on(c));

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const copies = app.services.clipboard.copies();
    try testing.expectEqual(2, copies.len);
    try testing.expectEqualStrings("XKCD-1234", copies[1]);
}

test "acknowledgement latches on the copyable that just copied" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const a = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
    const b = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Invite link", .value = "nok.re/x" } });
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Done" } });
    app.performLayout();
    try testing.expect(app.ack == null);

    try app.tap(app.tree.rectOf(a).center());
    try testing.expect(app.ack.?.eql(a));

    // Only one element is ever marked: the second copyable takes it.
    try app.tap(app.tree.rectOf(b).center());
    try testing.expect(app.ack.?.eql(b));
    try testing.expectEqual(2, app.services.clipboard.copies().len);

    // Activating the marked element again copies again and toggles the
    // mark off — the only visible sign the second copy happened.
    try app.tap(app.tree.rectOf(b).center());
    try testing.expect(app.ack == null);
    const copies = app.services.clipboard.copies();
    try testing.expectEqual(3, copies.len);
    try testing.expectEqualStrings("nok.re/x", copies[2]);

    // ...and a third activation marks it once more: the toggle is on the
    // mark, never on the copy.
    try app.tap(app.tree.rectOf(b).center());
    try testing.expect(app.ack.?.eql(b));
    try testing.expectEqual(4, app.services.clipboard.copies().len);

    // Anything else on the screen releases it.
    try app.tap(app.tree.rectOf(btn).center());
    try testing.expect(app.ack == null);
}

test "any input releases the acknowledgement, scrolling included" {
    var app = try test_app.init(400, 120);
    defer app.deinit();
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    app.performLayout();

    // Enter on the focused field arms it exactly as a tap does.
    try app.tap(app.tree.rectOf(c).center());
    try testing.expect(app.ack.?.eql(c));

    // Unlike `scroll_hot` there is no scroll exemption: nothing arms this
    // latch but activation, so every event releases it.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 60 }, .delta_y = 20 } });
    try testing.expect(app.ack == null);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(app.ack.?.eql(c));

    // Tab moves focus and takes the mark with it.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.ack == null);
}

test "navigating away leaves no acknowledgement behind" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildCopyScreen },
            .{ .name = "next", .title = .{ .fixed = "Next" }, .build = buildDetails },
        },
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();
    var kids = app.tree.children(app.tree.rootId());
    const c = kids.next().?;
    try app.tap(app.tree.rectOf(c).center());
    try testing.expect(app.ack != null);

    // The mark names a node, and a rebuild retires every node it named —
    // so it is dropped there, like the other latched ids.
    try app.navigate("next");
    app.performLayout();
    try testing.expect(app.ack == null);
}

fn buildCopyScreen(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
}

test "scroll emphasis latches on the moved surface until other input" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 50 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try app.tree.append(sr, .{ .text = .{ .content = "line" } });
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(sr).center();
    try testing.expect(app.scroll_hot == .none);

    // A touch drag: the latch survives the gesture's end — there is no
    // timer to fade the bar, only the next non-scroll input.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .begin } });
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 20, .phase = .move } });
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .end } });
    try testing.expect(app.scroll_gesture == null);
    try testing.expect(app.scroll_hot.node.eql(sr));

    // A tap that scrolls nothing releases it.
    try app.tap(.{ .x = 5, .y = 95 });
    try testing.expect(app.scroll_hot == .none);

    // Wheel outside the region moves the window: the latch follows the
    // surface that actually moved.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 90 }, .delta_y = 30 } });
    try testing.expect(app.scroll_hot == .window);
}

// ---- the folded tail of a row of actions (overflow.zig) ---------------------

/// The same five buttons the layout tests use — 373px of row in a 368px
/// span — with a counter on the last one, which is where the fold puts
/// the interesting question: it is reachable only through the sheet.
fn buildOverflowingRow(app: *App, counter: *PressCounter) !NodeId {
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "One", "Two", "Three", "Four" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }
    try app.tree.append(row, .{ .button = .{
        .label = "Five",
        .on_press = .{ .ctx = counter, .call = PressCounter.onPress },
    } });
    return row;
}

fn childOfRole(app: *const App, parent: NodeId, role: element_mod.Role) ?NodeId {
    var it = app.tree.children(parent);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == role) return c;
    }
    return null;
}

fn labelsUnder(app: *const App, parent: NodeId, role: element_mod.Role, out: [][]const u8) usize {
    var n: usize = 0;
    var it = app.tree.children(parent);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.role() == role) {
            out[n] = el.label();
            n += 1;
        }
    }
    return n;
}

test "an overflowing row grows a More control that opens the rest" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();

    // One pass decides the fold, the sync installs the control, and the
    // second pass places it — all inside `performLayout`, so a shell
    // never sees the half-built shape.
    const more = childOfRole(&app, row, .more) orelse return error.NoMoreControl;
    try testing.expect(app.tree.rectOf(more).w > 0);
    try testing.expect(!app.layout_dirty);

    // A tap, not a synthetic activation: the control is a real target at
    // the trailing end of the row.
    try app.tap(app.tree.rectOf(more).center());
    const sheet = layout.findSheet(&app.tree) orelse return error.NoSheet;
    try testing.expectEqualStrings("More", app.tree.getConst(sheet).?.sheet.title);

    // The button that gave up its slot leads the sheet, then the ones
    // that had actually overflowed — the row's own order.
    var labels: [5][]const u8 = undefined;
    const n = labelsUnder(&app, sheet, .button, &labels);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Four", labels[0]);
    try testing.expectEqualStrings("Five", labels[1]);
}

fn standingActions(app: *const App, row: NodeId) usize {
    var n: usize = 0;
    var it = app.tree.children(row);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.* == .button and !el.button.folded) n += 1;
    }
    return n;
}

test "the folded tail says the app's word for itself, and is measured by it" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);

    // Said before the control exists: the word has to reach the pass
    // that reserves its room, not only the pill that ends up drawn.
    app.setChrome(.{ .more = "Daha fazla" });
    app.performLayout();

    const more = childOfRole(&app, row, .more) orelse return error.NoMoreControl;
    try testing.expectEqualStrings("Daha fazla", app.tree.getConst(more).?.label());
    // The room claimed while deciding the fold is the room these words
    // need — the control is not laid out to fit "More" and then drawn
    // wider than it.
    try testing.expectEqual(layout.moreSize(app.measurer, "Daha fazla").w, app.tree.rectOf(more).w);
    // And the sheet it opens carries the same word as its title.
    try app.tap(app.tree.rectOf(more).center());
    const sheet = layout.findSheet(&app.tree) orelse return error.NoSheet;
    try testing.expectEqualStrings("Daha fazla", app.tree.getConst(sheet).?.sheet.title);
}

test "a wider word for the tail folds the row deeper" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    const in_english = standingActions(&app, row);
    try testing.expect(in_english > 0);

    // The fold is decided against the control's real width, so a longer
    // word costs the row an action rather than clipping the pill that
    // carries it.
    app.setChrome(.{ .more = "Weitere Aktionen anzeigen" });
    app.performLayout();
    try testing.expect(standingActions(&app, row) < in_english);
    const more = childOfRole(&app, row, .more) orelse return error.NoMoreControl;
    const r = app.tree.rectOf(more);
    try testing.expectEqual(layout.moreSize(app.measurer, "Weitere Aktionen anzeigen").w, r.w);
    // Still inside the row it stands in: what the fold gave up, it gave
    // up for this.
    try testing.expect(r.right() <= app.tree.rectOf(row).right());
}

test "pressing a folded button runs its action and closes the tail sheet" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);

    const sheet = layout.findSheet(&app.tree).?;
    var restated: ?NodeId = null;
    var it = app.tree.children(sheet);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.role() == .button and std.mem.eql(u8, el.label(), "Five")) restated = c;
    }
    app.performLayout();
    try app.tap(app.tree.rectOf(restated.?).center());

    // The action the row declared, run through the sheet's copy of it —
    // and the sheet goes, the way choosing a row closes a picker.
    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.more_sheet == null);
}

test "a widened viewport gives the folded buttons back" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    try testing.expect(childOfRole(&app, row, .more) != null);

    app.setViewport(.{ .w = 800, .h = 400 });
    app.performLayout();
    // No control, nothing folded, five buttons standing again.
    try testing.expect(childOfRole(&app, row, .more) == null);
    var labels: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 5), labelsUnder(&app, row, .button, &labels));
    var it = app.tree.children(row);
    while (it.next()) |c| {
        try testing.expect(!app.tree.getConst(c).?.button.folded);
        try testing.expect(app.tree.rectOf(c).w > 0);
    }
}

test "focus follows the fold rather than being dropped by it" {
    var counter: PressCounter = .{};
    var app = try test_app.init(800, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    var it = app.tree.children(row);
    var last: NodeId = undefined;
    while (it.next()) |c| last = c;
    app.focused = .of(last); // "Five", standing on the wide viewport

    // The viewport narrows and the button the user was on folds away.
    // Focus lands on the control that now holds it — not back at the top
    // of the tab order (WCAG 3.2.2).
    app.setViewport(.{ .w = 400, .h = 400 });
    app.performLayout();
    const more = childOfRole(&app, row, .more).?;
    try testing.expect(app.focused.?.on(more));

    // Wide again: the control goes, and focus stays at the row's
    // trailing end instead of following it out of the tree.
    app.setViewport(.{ .w = 800, .h = 400 });
    app.performLayout();
    try testing.expect(app.tree.getConst(more) == null);
    try testing.expect(app.focused.?.on(last));
}

test "a folded button is neither a focus stop nor a target" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();

    var folded: NodeId = undefined;
    var it = app.tree.children(row);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.* == .button and el.button.folded) folded = c;
    }
    try testing.expect(!app.tree.getConst(folded).?.isFocusable());
    // Tab from the last standing button reaches the control, never the
    // buttons behind it.
    const more = childOfRole(&app, row, .more).?;
    app.focused = null;
    var stops: usize = 0;
    var stop = focus.nextFocusable(&app.tree, app.tree.rootId(), null);
    while (stop) |s| : (stop = focus.nextFocusable(&app.tree, app.tree.rootId(), s)) {
        stops += 1;
        if (stops == 4) break;
    }
    try testing.expect(stop.?.on(more)); // One, Two, Three, then More
}

test "a row of actions inside a sheet wraps instead of folding" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Share");
    const row = try app.tree.appendId(sheet, .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "One", "Two", "Three", "Four", "Five" }) |label| {
        try app.tree.append(row, .{ .button = .{
            .label = label,
            .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
        } });
    }
    app.performLayout();

    // A sheet is the one layer a sheet cannot open over, so the tail has
    // nowhere to go and the row keeps every button it was given. It is
    // therefore not a folding row, and gets the other behaviour: the
    // buttons that do not fit stand on a second line inside the sheet,
    // where they used to run out through its edge.
    try testing.expect(childOfRole(&app, row, .more) == null);
    const pane = app.tree.rectOf(sheet);
    var lines: usize = 0;
    var prev_y: i32 = -1;
    var it = app.tree.children(row);
    while (it.next()) |c| {
        try testing.expect(!app.tree.getConst(c).?.button.folded);
        const r = app.tree.rectOf(c);
        try testing.expect(r.x >= pane.x and r.x + r.w <= pane.x + pane.w);
        if (r.y != prev_y) {
            lines += 1;
            prev_y = r.y;
        }
    }
    try testing.expect(lines > 1);
}

test "focus follows a second fold, when the control is already standing" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    // Three standing, "Four"/"Five" folded, the control already there.
    const more = childOfRole(&app, row, .more).?;
    var it = app.tree.children(row);
    _ = it.next();
    _ = it.next();
    const third = it.next().?; // "Three"
    app.focused = .of(third);

    // Narrower still: "Three" folds too, into a control that was
    // installed passes ago. Focus has to follow it there anyway.
    app.setViewport(.{ .w = 260, .h = 400 });
    app.performLayout();
    try testing.expect(app.tree.getConst(third).?.button.folded);
    try testing.expect(app.focused.?.on(more));
}

test "the tail sheet closes when the fold behind it moves" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);
    try testing.expect(app.more_sheet != null);

    // The window grew and the buttons are standing on the row again. A
    // sheet still listing them would show each of them twice — and
    // press the copy.
    app.setViewport(.{ .w = 900, .h = 400 });
    app.performLayout();
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.more_sheet == null);
    try testing.expect(!app.layout_dirty); // the dismissal was laid out, not deferred

    // The other direction: a deeper fold means the open list no longer
    // names everything hidden behind it, which is the same lie.
    app.setViewport(.{ .w = 400, .h = 400 });
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);
    try testing.expect(app.more_sheet != null);
    app.setViewport(.{ .w = 260, .h = 400 });
    app.performLayout();
    try testing.expect(layout.findSheet(&app.tree) == null);
}

test "a settled row reports no further chrome changes" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    // The second pass inside `performLayout` must find nothing left to
    // do, or every frame would rebuild the row's chrome.
    try testing.expect(!overflow.syncOverflowChrome(&app));
    try testing.expect(!app.layout_dirty);
}

test "a row of buttons and a link folds, and the link is still a link in the sheet" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 480, .h = 640 },
        .routes = &.{ .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildHomeWithActionRow }, .{ .name = "details", .title = .{ .fixed = "Details" }, .build = buildEmpty } },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();

    // The shape a real screen has: actions, and a link among them. One
    // trailing link must not be what decides whether a row of actions
    // gets the fold at all.
    const row = app.tree.rootChild(.stack) orelse blk: {
        var it = app.tree.children(app.tree.rootId());
        break :blk it.next().?;
    };
    const more = childOfRole(&app, row, .more) orelse return error.NoMoreControl;
    try app.activate(more);

    // Restated whole: the link arrives as a link carrying its route, not
    // as a button wearing its words.
    const sheet = layout.findSheet(&app.tree).?;
    var link: ?NodeId = null;
    var it = app.tree.children(sheet);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.* == .link) link = c;
    }
    const el = app.tree.getConst(link.?).?.link;
    try testing.expectEqualStrings("More details", el.label);
    try testing.expectEqualStrings("details", el.route);

    // And it navigates from there like any other link.
    try app.activate(link.?);
    try testing.expectEqualStrings("details", app.router.current().?);
}

fn buildHomeWithActionRow(_: ?*anyopaque, app: *App) anyerror!void {
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    try app.tree.append(row, .{ .button = .{ .label = "Save" } });
    try app.tree.append(row, .{ .button = .{ .label = "Cancel", .form = .{ .secondary = null } } });
    try app.tree.append(row, .{ .button = .{ .label = "Add reminder" } });
    try app.tree.append(row, .{ .button = .{ .label = "Disabled", .disabled = true } });
    try app.tree.append(row, .{ .link = .{ .label = "More details", .route = "details" } });
}

fn buildEmpty(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Details" } });
}

// ---- the UTF-8 boundary, under layout (tree_test.zig owns the
// per-path substitutions; this is the crash the boundary exists to
// prevent) ----

test "a fetched document with invalid bytes lays out instead of panicking" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    // Markdown promises arbitrary bytes never crash; before the
    // validating copy this parsed fine and panicked at first layout,
    // when the measurer's UTF-8 iterator met the raw bytes.
    const doc = try app.tree.appendId(app.tree.rootId(), .{ .document = .{
        .label = "Fetched",
        .source = "# T\xffitle\n\npara \xc3\n\n- item \x80\n",
    } });
    app.performLayout();

    var found = false;
    var it = app.tree.dfsUnder(doc);
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.* == .heading) {
            try testing.expectEqualStrings("T\u{FFFD}itle", el.heading.content);
            found = true;
        }
    }
    try testing.expect(found);
}

test "typed bytes pass the same boundary as appended ones" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Name" } });
    app.focused = .of(input);
    // A shell should never send these, but a value is measured prefix
    // by prefix, so one bad splice would poison every later caret move.
    try app.dispatch(.{ .text = .{ .bytes = "a\xffb" } });
    try testing.expectEqualStrings("a\u{FFFD}b", app.tree.getConst(input).?.text_input.value);
    app.performLayout();
}

// ---- the tail sheet's restatement is state, not words (overflow.zig) ----

test "the tail sheet follows a folded original's state, not only its words" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);
    try testing.expect(app.more_sheet != null);

    // A rebuild disables a folded original in place. The labels still
    // match, so a words-only staleness check would keep the sheet up —
    // with its copy still enabled and still pressing.
    var it = app.tree.children(row);
    while (it.next()) |c| {
        const el = app.tree.get(c).?;
        if (el.* == .button and el.button.folded) el.button.disabled = true;
    }
    app.invalidate();
    app.performLayout();
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.more_sheet == null);

    // Action identity is part of the claim too: the same words wired to
    // a different ctx/fn pair is a different action.
    it = app.tree.children(row);
    while (it.next()) |c| {
        const el = app.tree.get(c).?;
        if (el.* == .button and el.button.folded) el.button.disabled = false;
    }
    app.invalidate();
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);
    try testing.expect(app.more_sheet != null);
    var other: PressCounter = .{};
    it = app.tree.children(row);
    while (it.next()) |c| {
        const el = app.tree.get(c).?;
        if (el.* == .button and el.button.folded) el.button.on_press = .{ .ctx = &other, .call = PressCounter.onPress };
    }
    app.invalidate();
    app.performLayout();
    try testing.expect(layout.findSheet(&app.tree) == null);

    // An untouched fold keeps its sheet: the check is exact, not jumpy.
    try app.activate(childOfRole(&app, row, .more).?);
    try testing.expect(app.more_sheet != null);
    app.invalidate();
    app.performLayout();
    try testing.expect(layout.findSheet(&app.tree) != null);
}

// ---- the arena reclaim point (tree.zig; router.rebuild) ----

fn buildReclaimScreen(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Notes" } });
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "A paragraph long enough to cost real bytes every rebuild." } });
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Title" } });
}

fn reclaimCycle(app: *App) !void {
    // Type into the screen's field — every keystroke splices a fresh
    // copy of the whole value into the arena — then rebuild.
    var input: ?NodeId = null;
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.* == .text_input) input = id;
    }
    app.focused = .of(input.?);
    var n: usize = 0;
    while (n < 8) : (n += 1) try app.dispatch(.{ .text = .{ .bytes = "abcdefgh" } });
    try app.router.reload(app);
}

test "a router rebuild reclaims the tree arena" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 600 },
        .routes = &.{.{ .name = "notes", .title = .{ .fixed = "Notes" }, .build = buildReclaimScreen }},
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("notes");

    // Warm up, then hold: every cycle types the same bytes and rebuilds
    // the same screen, so a reclaiming arena settles at a fixed
    // capacity — without the reclaim, each cycle's splice copies and
    // rebuilt strings accumulate and capacity climbs monotonically.
    var i: usize = 0;
    while (i < 3) : (i += 1) try reclaimCycle(&app);
    const settled = app.tree.arena.queryCapacity();
    try testing.expect(settled > 0);
    while (i < 24) : (i += 1) try reclaimCycle(&app);
    try testing.expectEqual(settled, app.tree.arena.queryCapacity());
}

test "chrome keeps its nodes across the reclaim, strings and all" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    app.notify(.{ .title = "Update ready", .description = "Restart to apply", .route = "settings" });
    app.minimizeNotices();

    const chip = navChip(&app).?;
    const indicator = layout.findIndicator(&app.tree).?;
    // Two rebuilds: the chrome nodes survive both (nav.zig's "leave the
    // node alone" guard), so the reclaim must carry their strings into
    // each fresh arena rather than leave them dangling in a freed one.
    try app.router.reload(&app);
    try app.router.reload(&app);
    try testing.expect(navChip(&app).?.eql(chip));
    try testing.expect(layout.findIndicator(&app.tree).?.eql(indicator));
    try testing.expectEqualStrings("Library", app.tree.getConst(chip).?.nav_current.section);
    try testing.expectEqualStrings("Show notices", app.tree.getConst(indicator).?.label());
}

// ---- focus origin: rings for the keyboard, not the finger ----

test "focus rings follow the input that moved focus" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const a = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "a" } });
    const b = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "b" } });
    // Programmatic focus (tests, a11y actions) shows itself.
    try testing.expect(app.focus_visible);

    app.performLayout();
    try app.tap(app.tree.rectOf(a).center());
    try testing.expect(app.focused.?.on(a));
    try testing.expect(!app.focus_visible);

    // Tab after a tap: the keyboard is back, and so is the ring.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(b));
    try testing.expect(app.focus_visible);

    // And a tap after keys hides it again.
    try app.tap(app.tree.rectOf(a).center());
    try testing.expect(!app.focus_visible);
}

test "delivered semantics carry their origin for the ring" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Go" } });

    // A resolved press is a pointer; a delivered traversal is not.
    try app.deliver(.{ .press = .of(btn) });
    try testing.expect(!app.focus_visible);
    try app.deliver(.{ .focus = .of(btn) });
    try testing.expect(app.focus_visible);
}

// ---- tap-out: the gesture that puts the on-screen keyboard away ----

test "a tap on nothing clears an editable's focus, and only an editable's" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Name" } });
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Go",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });
    app.performLayout();

    // Focused field + tap on dead space: focus clears, and the shell's
    // `wants_text_input` sync drops the keyboard with it.
    try app.tap(app.tree.rectOf(input).center());
    try testing.expect(app.focused.?.on(input));
    try app.tap(.{ .x = 399, .y = 399 });
    try testing.expect(app.focused == null);

    // A tap on another control is that control's normal press.
    try app.tap(app.tree.rectOf(input).center());
    try app.tap(app.tree.rectOf(btn).center());
    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expect(app.focused.?.on(btn));

    // A tap on the field itself keeps its focus.
    try app.tap(app.tree.rectOf(input).center());
    try app.tap(app.tree.rectOf(input).center());
    try testing.expect(app.focused.?.on(input));

    // A non-editable's focus is not cleared by a stray tap: there is no
    // keyboard to put away, only a keyboard user's place to lose.
    try app.tap(app.tree.rectOf(btn).center());
    try app.tap(.{ .x = 399, .y = 399 });
    try testing.expect(app.focused.?.on(btn));

    // A drag that a recognizer turned into a scroll is not a tap-out.
    try app.tap(app.tree.rectOf(input).center());
    try app.dispatch(.{ .pointer = .{ .at = .{ .x = 399, .y = 399 }, .phase = .down } });
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 399, .y = 399 }, .delta_y = 10, .phase = .begin } });
    try app.dispatch(.{ .pointer = .{ .at = .{ .x = 399, .y = 380 }, .phase = .up } });
    try testing.expect(app.focused.?.on(input));
}

test "a tap on a sheet's empty area clears its field's focus too" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Filters");
    const field = try app.tree.appendId(sheet, .{ .text_input = .{ .label = "Query" } });
    app.performLayout();

    try app.tap(app.tree.rectOf(field).center());
    try testing.expect(app.focused.?.on(field));

    // Empty area *inside* the sheet: same dismissal, sheet stays.
    const sr = app.tree.rectOf(sheet);
    try app.tap(.{ .x = sr.x + sr.w - 4, .y = sr.y + sr.h - 4 });
    try testing.expect(app.focused == null);
    try testing.expect(layout.findSheet(&app.tree) != null);
}
