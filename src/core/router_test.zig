//! Tests for router.zig, dispatch-side: what leaves the router (the
//! current-route observer), the arguments a reference carries, the
//! viewport an entry remembers, the edge pan that goes back, and the
//! validation that refuses a bad reference or table. Split from
//! app_test.zig, which keeps the fixtures these were copied from.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const event_mod = @import("event.zig");
const haptic = @import("../services/haptic/haptic.zig");
const layout = @import("layout.zig");
const router_mod = @import("router.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const Element = element_mod.Element;
const NodeId = tree_mod.NodeId;

const testing = std.testing;

const CtxData = struct { built: u32 = 0 };

fn buildHome(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *CtxData = @ptrCast(@alignCast(ctx.?));
    data.built += 1;
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Details", .route = "details" } });
}

fn buildDetails(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Details" } });
}

fn firstChild(app: *App) Element {
    var it = app.tree.children(app.tree.rootId());
    return app.tree.getConst(it.next().?).?.*;
}

// ---- what leaves the router: the current route (docs/routing.md) ----

fn buildLeaf(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Leaf" } });
}

const observed_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildHome },
    .{ .name = "details", .title = "Details", .build = buildDetails },
    .{ .name = "leaf", .title = "Leaf", .build = buildLeaf },
};

const RouteRecorder = struct {
    count: usize = 0,
    refs: [8][32]u8 = undefined,
    lens: [8]usize = undefined,
    changes: [8]router_mod.Change = undefined,

    fn observe(ctx: ?*anyopaque, route: []const u8, change: router_mod.Change) void {
        const self: *RouteRecorder = @ptrCast(@alignCast(ctx.?));
        if (self.count == self.lens.len) return;
        // Copied, not kept: the reference belongs to the stack entry and
        // dies with it, which is what "borrowed only for the call" means.
        @memcpy(self.refs[self.count][0..route.len], route);
        self.lens[self.count] = route.len;
        self.changes[self.count] = change;
        self.count += 1;
    }

    fn at(self: *const RouteRecorder, i: usize) []const u8 {
        return self.refs[i][0..self.lens[i]];
    }
};

test "every change announces the screen on top, with the motion that made it" {
    var data: CtxData = .{};
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &observed_routes,
        .ctx = &data,
        .services = .mocks(),
    });
    defer app.deinit();
    var rec: RouteRecorder = .{};
    app.router.installObserver(&rec, RouteRecorder.observe);

    try app.navigate("home"); // push
    try app.navigate("details"); // push
    try app.navigateBack(); // pop
    try app.router.replace(&app, "leaf"); // replace
    try app.router.switchTo(&app, "home"); // switch_to

    try testing.expectEqual(@as(usize, 5), rec.count);
    const want_names = [_][]const u8{ "home", "details", "home", "leaf", "home" };
    const want_changes = [_]router_mod.Change{ .push, .push, .pop, .replace, .switch_to };
    for (want_names, want_changes, 0..) |n, c, i| {
        try testing.expectEqualStrings(n, rec.at(i));
        try testing.expectEqual(c, rec.changes[i]);
    }

    // The depth the app came through is the router's alone: `home` is
    // announced identically whether it was pushed, popped back to, or
    // switched to — one screen, one name.
    try testing.expectEqualStrings(rec.at(0), rec.at(4));

    // A pop at the root is a no-op, so it announces nothing.
    const before = rec.count;
    try app.navigateBack();
    try testing.expectEqual(before, rec.count);
}

// ---- route arguments: `note~42` (docs/routing.md) ----

fn buildTicket(_: ?*anyopaque, app: *App) anyerror!void {
    // A parameterized screen reads its own identity, not app state —
    // which is what makes the entry, not the app, remember it.
    try app.tree.append(app.tree.rootId(), .{
        .heading = .{ .content = app.routeArg(0) orelse "?" },
    });
}

const arg_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildHome },
    .{ .name = "ticket", .title = "Ticket", .args = 1, .build = buildTicket },
    .{ .name = "sum", .title = "Sum", .args = 2, .build = buildLeaf },
};

fn argApp(data: *CtxData) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &arg_routes,
        .ctx = data,
        .services = .mocks(),
    });
}

/// The screen's own first element, past the framework's back control —
/// every reference below is pushed, so the control is always there.
fn pushedTitle(app: *App) []const u8 {
    var it = app.tree.children(app.tree.rootId());
    _ = it.next(); // .back
    return app.tree.getConst(it.next().?).?.label();
}

test "a reference carries its arguments to the screen" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();

    try app.navigate("home");
    try app.navigate("ticket~2938");
    try testing.expectEqualStrings("ticket", app.router.current().?); // the name
    try testing.expectEqualStrings("ticket~2938", app.router.currentRef().?);
    try testing.expectEqualStrings("2938", app.routeArg(0).?);
    try testing.expect(app.routeArg(1) == null);
    // The builder read it, so it reached the tree.
    try testing.expectEqualStrings("2938", pushedTitle(&app));

    try app.navigate("sum~10~5");
    try testing.expectEqualStrings("10", app.routeArg(0).?);
    try testing.expectEqualStrings("5", app.routeArg(1).?);
}

test "arguments belong to the stack entry, so a pop restores them" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("ticket~41");
    try app.navigate("ticket~42");
    try testing.expectEqualStrings("42", app.routeArg(0).?);

    // The whole point of owning the reference per entry: the screen
    // underneath is a *different* ticket, and popping back proves the
    // entry remembered which — app state never held it.
    try app.navigateBack();
    try testing.expectEqualStrings("41", app.routeArg(0).?);
    try testing.expectEqualStrings("41", pushedTitle(&app));

    // And a reload rebuilds this entry with its own arguments —
    // `replace(app, current())` would drop them, since `current` is the
    // bare name.
    try app.router.reload(&app);
    try testing.expectEqualStrings("41", app.routeArg(0).?);
    try testing.expectEqual(@as(usize, 2), app.router.depth());
}

// ---- an entry remembers a viewport, not just a name (docs/routing.md) ----

/// Knobs a rebuild turns: the screen that comes back is built from
/// scratch, so it can legitimately come back a different shape.
const ScrollCtx = struct {
    rows: usize = 40,
    regions: usize = 0,
};

fn buildScrolled(ctx: ?*anyopaque, app: *App) anyerror!void {
    const c: *ScrollCtx = @ptrCast(@alignCast(ctx.?));
    var r: usize = 0;
    while (r < c.regions) : (r += 1) {
        const region = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 60 } });
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            try app.tree.append(region, .{ .text = .{ .content = "row" } });
        }
    }
    var i: usize = 0;
    while (i < c.rows) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
}

const scroll_routes = [_]router_mod.RouteDef{
    .{ .name = "list", .title = "List", .build = buildScrolled },
    .{ .name = "detail", .title = "Detail", .build = buildDetails },
};

fn scrollApp(c: *ScrollCtx) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 200 },
        .routes = &scroll_routes,
        .ctx = c,
        .services = .mocks(),
    });
}

fn regionAt(app: *App, n: usize) NodeId {
    var seen: usize = 0;
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() != .scroll_region) continue;
        if (seen == n) return id;
        seen += 1;
    }
    unreachable;
}

test "popping back returns the screen to where it was scrolled" {
    var c: ScrollCtx = .{};
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 120 } });
    try testing.expectEqual(@as(i32, 120), app.root_scroll);

    try app.navigate("detail");
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    // The rebuild is still from scratch; what came back is the viewport.
    try app.navigateBack();
    try testing.expectEqual(@as(i32, 120), app.root_scroll);
}

test "regions come back by position, and do not swap" {
    var c: ScrollCtx = .{ .regions = 2 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 0)).center(), .delta_y = 30 } });
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 1)).center(), .delta_y = 70 } });

    try app.navigate("detail");
    try app.navigateBack();
    app.performLayout();

    // NodeIds are generational and the freelist reuses them, so this is
    // the DFS ordinal doing the matching and nothing else.
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 70), app.tree.getConst(regionAt(&app, 1)).?.scroll_region.offset);
}

test "a screen that comes back a different shape restores what lines up" {
    var c: ScrollCtx = .{ .regions = 2 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 0)).center(), .delta_y = 30 } });
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 1)).center(), .delta_y = 70 } });
    try app.navigate("detail");

    // Fewer regions than were saved: the second position no longer
    // exists, which is a screen answering to changed state, not an error.
    c.regions = 1;
    try app.navigateBack();
    app.performLayout();
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);

    // And more regions than were saved: the extras start at the top.
    try app.navigate("detail");
    c.regions = 3;
    try app.navigateBack();
    app.performLayout();
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(regionAt(&app, 2)).?.scroll_region.offset);
}

test "a restored offset past the new content is clamped, not stranded" {
    var c: ScrollCtx = .{ .rows = 60 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 100000 } });
    const deep = app.root_scroll;
    try testing.expect(deep > 0);

    try app.navigate("detail");
    c.rows = 12; // the list shrank while the detail screen was up
    try app.navigateBack();
    app.performLayout();
    try testing.expect(app.root_scroll < deep);
    try testing.expectEqual(@max(0, app.root_content_height - app.viewport.h), app.root_scroll);
}

test "only pop and reload restore; replace and switchTo start at the top" {
    var c: ScrollCtx = .{};
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 90 } });

    // A reload is the same screen answering to changed state, so the
    // viewport is the user's, not the builder's.
    try app.router.reload(&app);
    try testing.expectEqual(@as(i32, 90), app.root_scroll);

    // A replace is a different screen at the same depth, and switchTo is
    // a different section: neither inherits a position it never had.
    try app.router.replace(&app, "list");
    try testing.expectEqual(@as(i32, 0), app.root_scroll);
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 90 } });
    try app.router.switchTo(&app, "list");
    try testing.expectEqual(@as(i32, 0), app.root_scroll);
}

test "the saved positions are bounded, like the reference is" {
    var c: ScrollCtx = .{ .regions = router_mod.max_saved_regions + 2 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    const last = router_mod.max_saved_regions + 1;
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 0)).center(), .delta_y = 30 } });
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, last)).center(), .delta_y = 30 } });

    try app.navigate("detail");
    try app.navigateBack();
    app.performLayout();
    // Past the bound a region comes back at the top — what every screen
    // did before any of this, not a failure.
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(regionAt(&app, last)).?.scroll_region.offset);
}

// ---- the one gesture: an edge pan goes back (docs/routing.md) ----

const pan_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildHome },
    .{ .name = "details", .title = "Details", .build = buildDetails },
};

fn panApp(data: *CtxData) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &pan_routes,
        .ctx = data,
        .services = .mocks(),
    });
}

fn panThreshold(app: *const App) i32 {
    return @max(
        layout.metrics.back_gesture_min,
        @divTrunc(app.viewport.w, layout.metrics.back_gesture_divisor),
    );
}

fn pan(app: *App, from: event_mod.EdgePan.Edge, dx: i32, phase: event_mod.EdgePan.Phase) !void {
    try app.dispatch(.{ .edge_pan = .{ .from = from, .dx = dx, .phase = phase } });
}

test "a pan past the threshold knocks, and releasing there goes back" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    const t = panThreshold(&app);

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, t - 1, .move);
    // Short of it, nothing has been promised and nothing is drawn.
    try testing.expect(!app.back_gesture.?.armed);
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);

    try pan(&app, .left, t, .move);
    try testing.expect(app.back_gesture.?.armed);
    try testing.expectEqualSlices(haptic.Knock, &.{.armed}, app.services.haptic.fired());
    // The knock is the promise, not the act: still on the same screen.
    try testing.expectEqualStrings("details", app.router.current().?);

    try pan(&app, .left, t, .end);
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expect(app.back_gesture == null);
}

test "releasing short of the threshold goes nowhere" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, panThreshold(&app) - 1, .move);
    try pan(&app, .left, panThreshold(&app) - 1, .end);
    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);
}

test "a finger at the threshold settles instead of rattling" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    const t = panThreshold(&app);
    const band = layout.metrics.back_gesture_hysteresis;

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, t, .move);
    // Retreating inside the band keeps the promise: this is the jitter
    // of a hand holding still, not a decision.
    try pan(&app, .left, t - 1, .move);
    try pan(&app, .left, t - band + 1, .move);
    try testing.expect(app.back_gesture.?.armed);
    try testing.expectEqualSlices(haptic.Knock, &.{.armed}, app.services.haptic.fired());

    // Past the band it is a decision, and it is taken back.
    try pan(&app, .left, t - band, .move);
    try testing.expect(!app.back_gesture.?.armed);
    try testing.expectEqualSlices(haptic.Knock, &.{ .armed, .disarmed }, app.services.haptic.fired());

    // And it can be made again — the gesture is not spent.
    try pan(&app, .left, t, .move);
    try testing.expectEqualSlices(
        haptic.Knock,
        &.{ .armed, .disarmed, .armed },
        app.services.haptic.fired(),
    );
    try pan(&app, .left, t, .end);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "a cancelled pan commits nothing, however far it got" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, panThreshold(&app), .move);
    // The system took the gesture away; there is no release to honour,
    // and no knock either — the user did not do this.
    try pan(&app, .left, panThreshold(&app), .cancel);
    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expect(app.back_gesture == null);
    try testing.expectEqualSlices(haptic.Knock, &.{.armed}, app.services.haptic.fired());

    // And the release that follows a cancel is not a second chance.
    try pan(&app, .left, panThreshold(&app), .end);
    try testing.expectEqualStrings("details", app.router.current().?);
}

test "with nothing to go back to, the gesture promises nothing" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");

    try pan(&app, .left, 0, .begin);
    try testing.expect(app.back_gesture == null);
    try pan(&app, .left, 10000, .move);
    try pan(&app, .left, 10000, .end);
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expectEqual(@as(usize, 1), app.router.depth());
    // The point of refusing at `.begin`: no knock announced a navigation
    // that was never going to happen.
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);
}

test "an open sheet keeps the gesture inert" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    _ = try app.presentSheet("Options");

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, 10000, .move);
    try pan(&app, .left, 10000, .end);
    // The sheet dismisses itself, by its own close control and Escape.
    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expect(layout.findSheet(&app.tree) != null);
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);
}

test "mirrored chrome mirrors its gesture" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    app.setDirection(.rtl);
    try app.navigate("home");
    try app.navigate("details");

    // Back runs against the reading direction, like the chevron.
    try pan(&app, .left, 0, .begin);
    try testing.expect(app.back_gesture == null);
    try pan(&app, .left, 10000, .end);
    try testing.expectEqualStrings("details", app.router.current().?);

    try pan(&app, .right, 0, .begin);
    try pan(&app, .right, panThreshold(&app), .move);
    try pan(&app, .right, panThreshold(&app), .end);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "the gesture and the Back control are the same act" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    app.performLayout();

    // Armed, the framework's Back control says so — the threshold has
    // to be visible to someone whose device cannot buzz.
    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, panThreshold(&app), .move);
    try testing.expect(app.back_gesture.?.armed);
    try testing.expect(firstChild(&app).role() == .back);

    // And what it commits is a pop like any other, scroll memory
    // included — not a second way to leave a screen.
    try pan(&app, .left, panThreshold(&app), .end);
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expect(firstChild(&app).role() != .back);
}

test "a reference with the wrong number of arguments is refused" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");

    // A refusal is a record, not an error (router.zig): the call
    // returns clean, the stack does not move, and `refused` names the
    // reference — which is what the audit fails a test over.
    try app.navigate("ticket"); // too few
    try testing.expectEqual(.arg_count, app.router.refused.?.reason);
    try app.navigate("ticket~1~2"); // too many
    try testing.expectEqual(.arg_count, app.router.refused.?.reason);
    try app.navigate("home~1"); // takes none
    try testing.expectEqual(.arg_count, app.router.refused.?.reason);
    try app.navigate("nope~1");
    try testing.expectEqual(.unknown_route, app.router.refused.?.reason);
    try testing.expectEqualStrings("nope~1", app.router.refused.?.ref());

    // Refused before anything is committed, exactly like the unknown name.
    try testing.expectEqualStrings("home", app.router.currentRef().?);
    try testing.expectEqual(@as(usize, 1), app.router.depth());
}

test "vet answers what a verb would refuse, without recording it" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");

    // The door for bytes from outside the program: the answer a verb
    // would give, with nothing written down — a stranger's typo is not
    // a programmer error.
    try testing.expectEqual(null, app.router.vet("ticket~42"));
    try testing.expectEqual(.unknown_route, app.router.vet("nope").?);
    try testing.expectEqual(.arg_count, app.router.vet("ticket").?);
    try testing.expect(app.router.refused == null);
}

test "an argument is an identifier, not a payload" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");

    // Free text is a URL's business, not a route's (docs/services.md).
    try app.navigate("ticket~has space");
    try testing.expectEqual(.arg_charset, app.router.refused.?.reason);
    app.router.refused = null;
    try app.navigate("ticket~a/b");
    try testing.expectEqual(.arg_charset, app.router.refused.?.reason);
    app.router.refused = null;
    try app.navigate("ticket~%20");
    try testing.expectEqual(.arg_charset, app.router.refused.?.reason);
    app.router.refused = null;
    // A trailing separator is a missing argument, not an empty one.
    try app.navigate("ticket~");
    try testing.expectEqual(.arg_charset, app.router.refused.?.reason);

    // But `.` and `-` are in, which is why they are not the separator:
    // versions, ids and slugs are arguments without escaping.
    try app.navigate("ticket~1.2.3-rc1");
    try testing.expectEqualStrings("1.2.3-rc1", app.routeArg(0).?);

    // A reference arrives from outside the app, so its length is bounded
    // even when the arity checks out — and the record keeps only what
    // fits, enough to name the culprit.
    var long: [router_mod.max_ref_bytes + 8]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..7], "ticket~");
    try app.navigate(&long);
    try testing.expectEqual(.ref_too_long, app.router.refused.?.reason);
    try testing.expectEqual(@as(usize, router_mod.max_ref_bytes), app.router.refused.?.ref().len);
    try testing.expectEqualStrings("ticket~1.2.3-rc1", app.router.currentRef().?);
}

test "routeRef is resolve's writing mirror" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");

    // What it writes, resolve accepts — separator included, which no
    // consumer spells anymore.
    var buf: [router_mod.max_ref_bytes]u8 = undefined;
    try testing.expectEqualStrings("home", try app.routeRef(&buf, "home", &.{}));
    const ticket = try app.routeRef(&buf, "ticket", &.{"1.2.3-rc1"});
    try testing.expectEqualStrings("ticket~1.2.3-rc1", ticket);
    try app.navigate(ticket);
    try testing.expectEqualStrings("1.2.3-rc1", app.routeArg(0).?);

    // And it refuses what resolve refuses, at the site that builds the
    // reference instead of the one that opens it.
    try testing.expectError(error.UnknownRoute, app.routeRef(&buf, "nope", &.{}));
    try testing.expectError(error.RouteArgCount, app.routeRef(&buf, "ticket", &.{}));
    try testing.expectError(error.RouteArgCount, app.routeRef(&buf, "home", &.{"1"}));
    try testing.expectError(error.RouteArgCharset, app.routeRef(&buf, "ticket", &.{"has space"}));
    // An argument cannot smuggle the separator in as content.
    try testing.expectError(error.RouteArgCharset, app.routeRef(&buf, "ticket", &.{"1~2"}));
    try testing.expectError(error.RouteArgCharset, app.routeRef(&buf, "ticket", &.{""}));

    // Bounded like an arriving reference, and refused before a byte
    // lands — a failed call leaves no half-written reference behind.
    var tiny: [4]u8 = .{ 'x', 'x', 'x', 'x' };
    try testing.expectError(error.RouteRefTooLong, app.routeRef(&tiny, "ticket", &.{"12345"}));
    try testing.expectEqualStrings("xxxx", &tiny);
}

test "the route table is validated at init, not at first navigation" {
    try testing.expectError(error.EmptyRouteName, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "", .title = "Untitled", .build = buildLeaf }},
        .services = .mocks(),
    }));
    // Without this, `find` resolves every reference to the first of them.
    try testing.expectError(error.DuplicateRouteName, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{
            .{ .name = "home", .title = "Home", .build = buildLeaf },
            .{ .name = "home", .title = "Home", .build = buildLeaf },
        },
        .services = .mocks(),
    }));
    // A name carrying the argument separator would make every reference
    // to it ambiguous; the rest of the charset is the same rule
    // arguments obey.
    try testing.expectError(error.RouteNameCharset, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "note~42", .title = "Note~42", .build = buildLeaf }},
        .services = .mocks(),
    }));
    try testing.expectError(error.RouteNameCharset, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "two words", .title = "Two Words", .build = buildLeaf }},
        .services = .mocks(),
    }));
}

// ---- the sheet across the motions: carried by reload, dropped by the
// rest (docs/routing.md, docs/elements.md "sheet") ----

/// A controller in miniature, sheet-side: the state its builder reads,
/// and the record of what the framework told it.
const SheetCtx = struct {
    built: u32 = 0,
    sheet_open: bool = false,
    sheet_builds: u32 = 0,
    dismissed: u32 = 0,

    fn buildScreen(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *SheetCtx = @ptrCast(@alignCast(ctx.?));
        self.built += 1;
        try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home" } });
    }

    fn buildSheet(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *SheetCtx = @ptrCast(@alignCast(ctx.?));
        if (!self.sheet_open) return;
        self.sheet_builds += 1;
        _ = try app.presentSheet("Confirm");
    }

    fn onDismiss(ctx: ?*anyopaque) void {
        const self: *SheetCtx = @ptrCast(@alignCast(ctx.?));
        self.sheet_open = false;
        self.dismissed += 1;
    }

    fn open(self: *SheetCtx, app: *App) !void {
        self.sheet_open = true;
        try app.openSheet(.{ .ctx = self, .call = buildSheet, .on_dismiss = onDismiss });
    }
};

const sheet_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = SheetCtx.buildScreen },
    .{ .name = "details", .title = "Details", .build = buildDetails },
};

test "reload carries the open sheet: its builder runs again over the rebuilt screen" {
    var data: SheetCtx = .{};
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &sheet_routes,
        .ctx = &data,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    try data.open(&app);
    try testing.expectEqual(@as(u32, 1), data.sheet_builds);

    try app.reload();
    // The screen rebuilt, and the sheet stood back up on it — same
    // builder, fresh tree, no closure announced.
    try testing.expectEqual(@as(u32, 2), data.built);
    try testing.expectEqual(@as(u32, 2), data.sheet_builds);
    try testing.expect(layout.findSheet(&app.tree) != null);
    try testing.expectEqual(@as(u32, 0), data.dismissed);
}

test "a navigation drops the open sheet and tells its builder" {
    var data: SheetCtx = .{};
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &sheet_routes,
        .ctx = &data,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    try data.open(&app);

    try app.navigate("details");
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expectEqual(@as(u32, 1), data.dismissed);
    try testing.expect(!data.sheet_open);
    try testing.expect(app.sheet_builder == null);
    // And a reload of the new screen has no sheet to stand back up.
    try app.reload();
    try testing.expect(layout.findSheet(&app.tree) == null);
}

// ---- focus across reload: carried by name, never by position
// (docs/routing.md) ----

const FocusCtx = struct {
    renamed: bool = false,

    fn buildForm(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *FocusCtx = @ptrCast(@alignCast(ctx.?));
        try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Name" } });
        try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save" } });
        try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = if (self.renamed) "Discard" else "Cancel" } });
    }

    fn buildProse(_: ?*anyopaque, app: *App) anyerror!void {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
            .{ .text = "Read the " },
            .{ .text = "terms", .route = "form" },
        } } });
    }
};

const focus_routes = [_]router_mod.RouteDef{
    .{ .name = "form", .title = "Form", .build = FocusCtx.buildForm },
    .{ .name = "prose", .title = "Prose", .build = FocusCtx.buildProse },
};

fn focusApp(data: *FocusCtx) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &focus_routes,
        .ctx = data,
        .services = .mocks(),
    });
}

fn nodeLabeled(app: *const App, label: []const u8) ?NodeId {
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (std.mem.eql(u8, app.tree.getConst(id).?.label(), label)) return id;
    }
    return null;
}

test "reload re-finds focus by name over the rebuilt tree" {
    var data: FocusCtx = .{};
    var app = try focusApp(&data);
    defer app.deinit();
    try app.navigate("form");
    const before = nodeLabeled(&app, "Cancel").?;
    app.focused = .of(before);

    try app.reload();
    const after = app.focused orelse return error.TestUnexpectedResult;
    // The node is a new one — the content was rebuilt from scratch —
    // but it answers to the same name, so it is the same control.
    try testing.expect(!after.node.eql(before));
    try testing.expectEqualStrings("Cancel", app.tree.getConst(after.node).?.label());
}

test "focus starts over when the carried name is gone" {
    var data: FocusCtx = .{};
    var app = try focusApp(&data);
    defer app.deinit();
    try app.navigate("form");
    app.focused = .of(nodeLabeled(&app, "Cancel").?);

    data.renamed = true; // the rebuilt screen says "Discard" instead
    try app.reload();
    // Nothing wears the carried name, and nothing else is guessed at:
    // a wrong control under a screen reader's cursor is worse than a
    // fresh start.
    try testing.expect(app.focused == null);
}

test "a link span's stop is not carried" {
    var data: FocusCtx = .{};
    var app = try focusApp(&data);
    defer app.deinit();
    try app.navigate("prose");
    var it = app.tree.children(app.tree.rootId());
    const para = it.next().?;
    app.focused = .{ .node = para, .span = 1 };

    try app.reload();
    // The paragraph has no name of its own, and the span index is
    // exactly the ordinal a restore must never trust.
    try testing.expect(app.focused == null);
}

/// Sheet-side of the carry: the sheet is re-presented first, then the
/// carried name is looked for inside it — the active layer.
const SheetFocusCtx = struct {
    sheet_open: bool = false,

    fn buildScreen(_: ?*anyopaque, app: *App) anyerror!void {
        try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home" } });
        try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Refresh" } });
    }

    fn buildSheet(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *SheetFocusCtx = @ptrCast(@alignCast(ctx.?));
        if (!self.sheet_open) return;
        const sheet = try app.presentSheet("Confirm");
        try app.tree.append(sheet, .{ .button = .{ .label = "Keep" } });
        try app.tree.append(sheet, .{ .button = .{ .label = "Delete" } });
    }
};

test "reload under a sheet re-finds focus inside the re-presented sheet" {
    var data: SheetFocusCtx = .{};
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "home", .title = "Home", .build = SheetFocusCtx.buildScreen }},
        .ctx = &data,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    data.sheet_open = true;
    try app.openSheet(.{ .ctx = &data, .call = SheetFocusCtx.buildSheet });

    const before = nodeLabeled(&app, "Delete").?;
    app.focused = .of(before);
    try app.reload();
    const after = app.focused orelse return error.TestUnexpectedResult;
    try testing.expect(!after.node.eql(before));
    try testing.expectEqualStrings("Delete", app.tree.getConst(after.node).?.label());
}

test "reloadSafe: an overlay or an edit in flight says wait" {
    var data: FocusCtx = .{};
    var app = try focusApp(&data);
    defer app.deinit();
    try app.navigate("form");

    // Nothing held: safe, and a control that is not an edit is safe
    // too — the carry returns the place, and no work is in it to lose.
    try testing.expect(app.reloadSafe());
    app.focused = .of(nodeLabeled(&app, "Save").?);
    try testing.expect(app.reloadSafe());

    // An editable holds more than a place: caret, composition, and the
    // unwritten value all die with the node.
    app.focused = .of(nodeLabeled(&app, "Name").?);
    try testing.expect(!app.reloadSafe());

    // An overlay owns the screen, whoever holds focus inside it.
    app.focused = null;
    _ = try app.presentSheet("Confirm");
    try testing.expect(!app.reloadSafe());
    app.dismissSheet();
    try testing.expect(app.reloadSafe());
}
