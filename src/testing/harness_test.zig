//! The harness testing itself, end to end: queries, synthetic input,
//! a11y-snapshot assertions, and step tracing.

const std = @import("std");
const app_mod = @import("../core/app.zig");
const harness_mod = @import("harness.zig");
const diag = @import("diag.zig");
const trace = @import("trace.zig");

const testing = std.testing;
const App = app_mod.App;
const Harness = harness_mod.Harness;

const TodoCtx = struct {
    submitted: u32 = 0,
    last_value: [64]u8 = undefined,
    last_len: usize = 0,

    fn onSubmit(ctx: ?*anyopaque) void {
        const self: *TodoCtx = @ptrCast(@alignCast(ctx.?));
        self.submitted += 1;
    }

    fn onChange(ctx: ?*anyopaque, value: []const u8) void {
        const self: *TodoCtx = @ptrCast(@alignCast(ctx.?));
        self.last_len = @min(value.len, self.last_value.len);
        @memcpy(self.last_value[0..self.last_len], value[0..self.last_len]);
    }
};

fn buildTodo(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *TodoCtx = @ptrCast(@alignCast(ctx.?));
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .heading = .{ .content = "Todo", .level = .h1 } });
    try app.tree.append(root, .{ .text_input = .{
        .label = "New item",
        .placeholder = "What needs doing?",
        .on_change = .{ .ctx = data, .call = TodoCtx.onChange },
        .on_submit = .{ .ctx = data, .call = TodoCtx.onSubmit },
    } });
    try app.tree.append(root, .{ .toggle = .{ .label = "Show done" } });
}

test "e2e: fill a form with keyboard only" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    const input = try h.getByLabel("New item");
    try h.focusVia(input);
    try h.typeText("buy milk");
    try h.pressKey(.enter, .{});

    try testing.expectEqual(@as(u32, 1), ctx.submitted);
    try testing.expectEqualStrings("buy milk", ctx.last_value[0..ctx.last_len]);
    try h.expectValue("New item", "buy milk");
}

test "e2e: tap flips toggle and moves focus" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    try h.tapLabel("Show done");
    try h.expectFocused("Show done");
    try h.expectChecked("Show done", true);
}

test "e2e: ime composition through the harness" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    try h.focusVia(try h.getByLabel("New item"));
    try h.composeText("miruku", "ミルク");
    try h.expectValue("New item", "ミルク");
}

test "e2e: a11y snapshot reflects interaction state" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    try h.tapLabel("Show done");
    var snap = try h.a11ySnapshot(testing.allocator);
    defer snap.deinit();

    const cb = snap.findByLabel("Show done").?;
    try testing.expectEqual(@as(?bool, true), cb.checked);
    try testing.expect(cb.focused);
}

test "e2e: get queries fail loudly, query queries assert absence" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    // Expected failures run muted so their diagnostics never reach
    // stderr — `zig build test` must stay silent when green (diag.zig).
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.NoSuchElement, h.getByLabel("No such thing"));
        try testing.expectError(error.NoSuchElement, h.getByRole(.button, "Show done"));
    }
    try h.expectAbsent("No such thing");
    _ = try h.getByRole(.toggle, "Show done");
}

test "e2e: tap refuses targets a finger could not hit" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    // Static text is not a tap target.
    const heading = try h.getByLabel("Todo");
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.NotInteractive, h.tap(heading));
    }

    // An element scrolled out of the viewport is not visible to a finger.
    for (0..60) |i| {
        var buf: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "Filler {d}", .{i});
        try h.app.tree.append(h.app.tree.rootId(), .{ .toggle = .{ .label = label } });
    }
    h.app.invalidate();
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.NotVisible, h.tap(try h.getByLabel("Filler 59")));
    }
}

test "e2e: tap refuses a button whose work is still running" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();
    const btn = try h.app.tree.appendId(h.app.tree.rootId(), .{ .button = .{ .label = "Count primes", .in_progress = true } });
    h.app.invalidate();

    // The button is deliberately still focusable, so the plain "not
    // interactive" check lets it through — and the press would land
    // nowhere. A test that pressed it and saw nothing happen would be
    // asserting against silence.
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.InProgress, h.tap(btn));
    }

    // Once the work lands, it is an ordinary button again.
    h.app.tree.get(btn).?.button.in_progress = false;
    try h.tap(btn);
}

test "e2e: a switch with work in flight takes no press and loses no place" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();
    const sw = try h.app.tree.appendId(h.app.tree.rootId(), .{ .toggle = .{ .label = "Push to phone", .in_progress = true } });
    h.app.invalidate();

    // Keyboard-reachable while busy — that is the whole point of the
    // state — so Tab still lands on it and focus stays put.
    try h.focusVia(sw);
    try h.expectFocused("Push to phone");
    // …and Enter on the focused switch flips nothing.
    try h.pressKey(.enter, .{});
    try h.expectChecked("Push to phone", false);

    // The tap refuses loudly rather than pressing nothing quietly, the
    // button's rule reached through the same verb.
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.InProgress, h.tap(sw));
    }

    // Once the work lands, it is an ordinary switch again.
    h.app.tree.get(sw).?.toggle.in_progress = false;
    try h.tap(sw);
    try h.expectChecked("Push to phone", true);
}

const ChoiceCtx = struct {
    view: usize = 0,
    delivery: usize = 0,
    country: usize = 0,

    fn onView(ctx: ?*anyopaque, i: usize) void {
        @as(*ChoiceCtx, @ptrCast(@alignCast(ctx.?))).view = i;
    }
    fn onDelivery(ctx: ?*anyopaque, i: usize) void {
        @as(*ChoiceCtx, @ptrCast(@alignCast(ctx.?))).delivery = i;
    }
    fn onCountry(ctx: ?*anyopaque, i: usize) void {
        @as(*ChoiceCtx, @ptrCast(@alignCast(ctx.?))).country = i;
    }
};

/// One of each exclusive choice, and the select's list long enough to
/// earn the picker's filter field (`overlays.picker_filter_min`) — the
/// shape where focus lands on the filter rather than on a row, and the
/// one a verb that only knew about rows would fall over on.
fn buildChoices(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *ChoiceCtx = @ptrCast(@alignCast(ctx.?));
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .heading = .{ .content = "Preferences", .level = .h1 } });
    try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid", "Compact" },
        .on_select = .{ .ctx = data, .call = ChoiceCtx.onView },
    } });
    try app.tree.append(root, .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS", "Post" },
        .selected = 2,
        .on_select = .{ .ctx = data, .call = ChoiceCtx.onDelivery },
    } });
    try app.tree.append(root, .{ .select = .{
        .label = "Country",
        .options = &.{ "Brazil", "Canada", "Denmark", "Egypt", "France", "Ghana", "Hungary", "Iceland", "Japan" },
        .on_select = .{ .ctx = data, .call = ChoiceCtx.onCountry },
    } });
}

test "e2e: selectOption names the option in all three exclusive controls" {
    var ctx: ChoiceCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildChoices });
    defer h.deinit();

    // A track: forward along the chips, committing at each step like the
    // arrows a user presses.
    try h.selectOption("View", "Compact");
    try h.expectValue("View", "Compact");
    try testing.expectEqual(@as(usize, 2), ctx.view);

    // A radio group, and backwards this time — the walk goes either way.
    try h.selectOption("Delivery", "Email");
    try h.expectValue("Delivery", "Email");
    try testing.expectEqual(@as(usize, 0), ctx.delivery);

    // A select opens its modal picker and chooses in there; the row is
    // below the fold and behind a filter field, and stepping to it is
    // what scrolls it into view.
    try h.selectOption("Country", "Japan");
    try h.expectValue("Country", "Japan");
    try testing.expectEqual(@as(usize, 8), ctx.country);
    // The picker closed behind the choice, and focus came back to the
    // field that opened it.
    try h.expectAbsent("Filter");
    try h.expectFocused("Country");

    // Choosing what is already chosen is the no-op it is for a user: no
    // callback, no move.
    ctx.view = 99;
    try h.selectOption("View", "Compact");
    try h.expectValue("View", "Compact");
    try testing.expectEqual(@as(usize, 99), ctx.view);
}

test "e2e: selectOption walks a mirrored track the way it looks" {
    var ctx: ChoiceCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildChoices });
    defer h.deinit();
    // Under mirrored chrome the chips lay right-to-left and ←/→ swap
    // roles with them, so the verb asks the app which way forward is
    // rather than assuming. The vertical axis never mirrors, so the
    // radio group's walk is the same in both.
    h.app.setDirection(.rtl);
    try h.selectOption("View", "Compact");
    try h.expectValue("View", "Compact");
    try h.selectOption("Delivery", "Email");
    try h.expectValue("Delivery", "Email");
}

test "e2e: selectOption refuses what a user could not choose" {
    var ctx: ChoiceCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildChoices });
    defer h.deinit();

    diag.quiet = true;
    defer diag.quiet = false;
    // An option nothing offers: the diagnostic lists what is actually
    // there, so a renamed option reads as a rename and not a mystery.
    try testing.expectError(error.NoSuchOption, h.selectOption("View", "Gallery"));
    // A control with no options at all — tapping is what that one takes.
    try testing.expectError(error.NotAChoiceControl, h.selectOption("Preferences", "List"));
    // Nothing moved on the way out of either refusal.
    try h.expectValue("View", "List");
}

test "e2e: pending notices are assertable where the snapshot cannot see them" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    // Quiet: nothing but the indicator appears, so the only trace on
    // screen is a button named for the *chrome*, not for the notice.
    h.app.notify(.{ .title = "Draft saved", .description = "Kept locally." });
    try h.expectNotified("Draft saved");
    try h.expectAbsent("Draft saved"); // …and no element says so
    _ = try h.getByLabel("Show notices");

    // Important notices go in front of quiet ones, whatever order they
    // were raised in, and the banner is always the front one.
    h.app.notify(.{ .title = "Sync failed", .route = "home", .important = true });
    const pending = h.noticesPending();
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqualStrings("Sync failed", pending[0].title());
    try testing.expect(pending[0].important);
    try testing.expectEqualStrings("home", pending[0].route());
    try testing.expectEqualStrings("Draft saved", pending[1].title());
    try testing.expect(!pending[1].important);
    try testing.expectEqualStrings("Kept locally.", pending[1].description());

    // A duplicate title is dropped, and leaves no mark anywhere else:
    // the second call is silent, so the count is the only witness.
    h.app.notify(.{ .title = "Sync failed", .description = "…again", .important = true });
    try testing.expectEqual(@as(usize, 2), h.noticesPending().len);
    try testing.expectEqualStrings("", h.noticesPending()[0].description());

    // Dismissing by title, app-side: the front one goes and the quiet
    // one behind it does not inherit the banner (notices.zig).
    try h.dismissNotice("Sync failed");
    try testing.expectEqual(@as(usize, 1), h.noticesPending().len);
    try h.expectNotified("Draft saved");
    _ = try h.getByLabel("Show notices");

    // …and dismiss-all empties the list and takes the chrome with it.
    try h.dismissAllNotices();
    try testing.expectEqual(@as(usize, 0), h.noticesPending().len);
    try h.expectAbsent("Show notices");
}

test "e2e: the notice verbs fail loudly when the title is not pending" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();
    h.app.notify(.{ .title = "Draft saved" });

    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NoticeMismatch, h.expectNotified("Sync failed"));
    try testing.expectError(error.NoticeMismatch, h.dismissNotice("Sync failed"));
    // The one that is pending is untouched by either failure.
    try testing.expectEqual(@as(usize, 1), h.noticesPending().len);
}

test "e2e: harness rejects screens that fail the audit" {
    const bad = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            // Skipped heading level: h2 with no h1 before it.
            try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Section", .level = .h2 } });
        }
    };
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(
        error.A11yAuditFailed,
        Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = bad.build }),
    );
}

test "e2e: expectTree snapshots the laid-out tree inline" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 200, .h = 200 }, .{ .ctx = &ctx, .build = buildMinimal });
    defer h.deinit();

    try h.tapLabel("Show done");
    try h.expectTree(
        \\viewport 200x200 light
        \\stack [0,0,200,200]
        \\  toggle [16,16,125,44] "Show done" on focused
    );
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.TreeMismatch, h.expectTree("viewport 200x200 light"));
    }
}

fn buildMinimal(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .toggle = .{ .label = "Show done" } });
}

test "e2e: step trace writes a tree snapshot per action" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    var sink = try trace.TreeSink.init(testing.io, tmp.dir, testing.allocator, "trace");
    try h.startTrace(sink.observer());

    try h.tapLabel("Show done");
    try h.pressKey(.tab, .{});

    const init_snap = try tmp.dir.readFileAlloc(testing.io, "trace/0000-init.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(init_snap);
    try testing.expect(std.mem.indexOf(u8, init_snap, "toggle") != null);
    try testing.expect(std.mem.indexOf(u8, init_snap, "\"Show done\" on") == null);

    const tap_snap = try tmp.dir.readFileAlloc(testing.io, "trace/0001-tap-Show-done.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(tap_snap);
    try testing.expect(std.mem.indexOf(u8, tap_snap, "\"Show done\" on focused") != null);

    const key_snap = try tmp.dir.readFileAlloc(testing.io, "trace/0002-key-tab.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(key_snap);
    try testing.expect(std.mem.indexOf(u8, key_snap, "focused") != null);
}

fn buildRecovery(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .copyable = .{
        .label = "Recovery code",
        .value = "XKCD-1234",
    } });
}

test "e2e: expectCopied asserts the last clipboard write" {
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = buildRecovery });
    defer h.deinit();

    {
        diag.quiet = true;
        defer diag.quiet = false;
        // Before any activation there is nothing on the record.
        try testing.expectError(error.CopiedMismatch, h.expectCopied("XKCD-1234"));
    }
    try h.tapLabel("Recovery code");
    try h.expectCopied("XKCD-1234");
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.CopiedMismatch, h.expectCopied("something-else"));
    }
}

const consent_routes = [_]@import("../core/router.zig").RouteDef{
    .{ .name = "consent", .title = .{ .fixed = "Consent" }, .build = buildTermsDoc },
    .{ .name = "terms", .title = .{ .fixed = "Terms" }, .build = buildTermsTarget },
};

fn buildTermsDoc(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .document = .{
        .label = "Consent",
        .source =
        \\By continuing you accept the [terms of service](terms).
        ,
    } });
}

fn buildTermsTarget(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Terms" } });
}

test "e2e: an inline link is tapped and tabbed to by its words" {
    var harness = try Harness.init(testing.allocator, .{ .w = 360, .h = 300 }, .{ .routes = &consent_routes, .initial_route = "consent" });
    defer harness.deinit();

    // A link has no node of its own, but to a user it is a control with
    // those words on it — so it answers to the same verb as any other.
    try harness.pressKey(.tab, .{});
    try testing.expectEqualStrings("terms of service", harness.focusedLabel());

    try harness.tapLabel("terms of service");
    try harness.expectRoute("terms");
    // The link pushed rather than switching section, so the consent
    // screen is still underneath it.
    try testing.expectEqual(@as(usize, 2), harness.app.router.depth());
}

const ticket_routes = [_]@import("../core/router.zig").RouteDef{
    .{ .name = "inbox", .title = .{ .fixed = "Inbox" }, .build = buildInbox },
    .{ .name = "ticket", .title = .{ .fixed = "Ticket" }, .args = 1, .build = buildTicketScreen },
};

fn buildInbox(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .document = .{
        .label = "Inbox",
        .source =
        \\Latest: [the flaky build](ticket~2938).
        ,
    } });
}

fn buildTicketScreen(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{
        .heading = .{ .content = app.routeArg(0) orelse "?" },
    });
}

test "e2e: a Markdown link carries route arguments" {
    var harness = try Harness.init(testing.allocator, .{ .w = 360, .h = 300 }, .{ .routes = &ticket_routes, .initial_route = "inbox" });
    defer harness.deinit();

    // `~` is not a URI scheme, so the destination stays an in-app route
    // and the arguments ride along with no parser involvement
    // (docs/markdown.md).
    try harness.tapLabel("the flaky build");
    try harness.expectRoute("ticket");
    try testing.expectEqualStrings("2938", harness.app.routeArg(0).?);
    // And the screen built itself from that argument, not from state.
    try testing.expect(harness.queryByLabel("2938") != null);
}

// One table, two languages: each title answers "fa" from what an app's
// Farsi catalog would say, and everything else as English — the shape
// `RouteDef.Title.of_locale` exists for.
fn buildBlank(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "…" } });
}

fn faTitle(comptime en: []const u8, comptime fa: []const u8) @import("../core/router.zig").Title {
    return .{ .of_locale = struct {
        fn call(tag: []const u8) []const u8 {
            return if (std.mem.eql(u8, tag, "fa")) fa else en;
        }
    }.call };
}

const shop_routes = [_]@import("../core/router.zig").RouteDef{
    .{ .name = "inbox", .title = faTitle("Inbox", "صندوق"), .build = buildInbox },
    .{ .name = "archive", .title = faTitle("Archive", "بایگانی"), .build = buildBlank },
    .{ .name = "ticket", .title = faTitle("Ticket", "بلیت"), .args = 1, .build = buildTicketScreen },
};

test "e2e: a Farsi app ships a Farsi nav bar and a Farsi back control" {
    var h = try Harness.init(testing.allocator, .{ .w = 900, .h = 480 }, .{ .routes = &shop_routes, .nav = &.{
        .{ .route = "inbox", .icon = .inbox },
        .{ .route = "archive", .icon = .archive },
    }, .initial_route = "inbox" });
    defer h.deinit();
    _ = try h.getByRole(.nav_item, "Archive");

    try h.app.setLocale("fa");
    h.app.setChrome(.{ .back = "بازگشت", .current_screen = "این صفحه" });
    h.app.setDirection(.rtl);

    // The destinations are labelled from the route table, so choosing
    // the locale is the whole of a translated nav bar — nothing on the
    // roster had to be told, and no `Destination` grew a label of its
    // own.
    _ = try h.getByRole(.nav_item, "بایگانی");
    try h.expectAbsent("Archive");

    // A pushed screen's back control is the framework's own word,
    // reached through the a11y snapshot like any other name.
    try h.tapLabel("the flaky build");
    _ = try h.getByRole(.back, "بازگشت");
    try h.expectAbsent("Back");
    // …and the marker for a screen that is no destination is the same
    // name/value split, both halves translated from their own home.
    _ = try h.getByRole(.nav_here, "این صفحه");
    try h.expectValue("این صفحه", "بلیت");
}

test "e2e: the back gesture is an action like any other" {
    var harness = try Harness.init(testing.allocator, .{ .w = 360, .h = 300 }, .{ .routes = &ticket_routes, .initial_route = "inbox" });
    defer harness.deinit();
    try harness.tapLabel("the flaky build");
    try harness.expectRoute("ticket");

    // One verb for the whole drag, and the screen it lands on is audited
    // like every other action's — a gesture is not a back door around
    // the harness's rules.
    try harness.edgePanBack();
    try harness.expectRoute("inbox");
    // The threshold was crossed once, and felt once.
    try testing.expectEqualSlices(harness_mod.Knock, &.{.armed}, harness.knocks());
}

test "e2e: a missing link is diagnosed alongside the labels that do exist" {
    var harness = try Harness.init(testing.allocator, .{ .w = 360, .h = 300 }, .{ .routes = &consent_routes, .initial_route = "consent" });
    defer harness.deinit();

    try testing.expect(harness.queryLink("terms of service") != null);
    try testing.expect(harness.queryLink("privacy policy") == null);
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NoSuchElement, harness.tapLabel("privacy policy"));
}

fn buildActionRow(_: ?*anyopaque, app: *App) anyerror!void {
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Publish", "Save draft", "Duplicate", "Archive", "Delete" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }
}

test "e2e: a folded button is reached through More, and says so when it is not" {
    // Narrow enough that the row cannot hold five actions: the tail
    // folds, and the screen still passes the audit the harness runs
    // after every step.
    var h = try Harness.init(testing.allocator, .{ .w = 400, .h = 640 }, .{ .build = buildActionRow });
    defer h.deinit();

    // A folded button is not on the screen, so its words do not address
    // it: the listing that comes back says where it went.
    var archive = h.app.tree.rootId();
    var it = h.app.tree.dfs();
    while (it.next()) |id| {
        const el = h.app.tree.getConst(id).?;
        if (el.* == .button and std.mem.eql(u8, el.button.label, "Archive")) archive = id;
    }
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.NoSuchElement, h.getByLabel("Archive"));
        // Held directly (a builder kept the id), it is refused with its
        // own error rather than "not interactive": folded is neither.
        try testing.expectError(error.Folded, h.tap(archive));
    }

    // The way a user takes: press More, then the button in the sheet.
    try h.tapLabel("More");
    try h.tapLabel("Archive");
    try testing.expect(h.app.more_sheet == null);
}

// ---- the consumer-proven verbs ----
// press, typeInto, goTab, expectPresent, expectDisabled: the verbs both
// shipped apps wrote over the primitives above, folded into the harness
// with their fallback behavior intact (docs/testing.md).

const PressCtx = struct {
    pressed: u32 = 0,

    fn onPress(ctx: ?*anyopaque) void {
        @as(*PressCtx, @ptrCast(@alignCast(ctx.?))).pressed += 1;
    }
};

fn buildFoldedActions(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *PressCtx = @ptrCast(@alignCast(ctx.?));
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Publish", "Save draft", "Duplicate" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }
    try app.tree.append(row, .{ .button = .{
        .label = "Archive",
        .on_press = .{ .ctx = data, .call = PressCtx.onPress },
    } });
    try app.tree.append(row, .{ .button = .{ .label = "Delete" } });
}

test "e2e: press reaches a folded action through More, like a user would" {
    var ctx: PressCtx = .{};
    // Narrow enough that the row cannot hold five actions: the tail
    // folds, and "Archive" is invisible to every on-screen query.
    var h = try Harness.init(testing.allocator, .{ .w = 400, .h = 640 }, .{ .ctx = &ctx, .build = buildFoldedActions });
    defer h.deinit();

    try testing.expectError(error.NoSuchElement, blk: {
        diag.quiet = true;
        defer diag.quiet = false;
        break :blk h.getByLabel("Archive");
    });
    try h.press(.button, "Archive");
    try testing.expectEqual(@as(u32, 1), ctx.pressed);
    // The overflow sheet closed behind the press.
    try testing.expect(h.app.more_sheet == null);
}

fn buildLongForm(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *PressCtx = @ptrCast(@alignCast(ctx.?));
    for (0..40) |i| {
        var buf: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "Filler {d}", .{i});
        try app.tree.append(app.tree.rootId(), .{ .toggle = .{ .label = label } });
    }
    try app.tree.append(app.tree.rootId(), .{ .button = .{
        .label = "Submit",
        .on_press = .{ .ctx = data, .call = PressCtx.onPress },
    } });
}

test "e2e: press falls back to the keyboard when the control is past the fold" {
    var ctx: PressCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 400 }, .{ .ctx = &ctx, .build = buildLongForm });
    defer h.deinit();

    // A tap at the button's center would land below the viewport —
    // `tap` alone refuses. press takes the route a user takes: Tab to
    // it (which scrolls it into view) and Enter.
    {
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.NotVisible, h.tap(try h.getByLabel("Submit")));
    }
    try h.press(.button, "Submit");
    try testing.expectEqual(@as(u32, 1), ctx.pressed);
}

test "e2e: press taps by semantic identity when the control is simply there" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .ctx = &ctx, .build = buildTodo });
    defer h.deinit();

    try h.press(.toggle, "Show done");
    try h.expectChecked("Show done", true);
    // The role half is load-bearing: the same words under another role
    // are a loud miss, not a press on whatever matched first.
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NoSuchElement, h.press(.button, "Show done"));
}

fn buildComposer(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Subject" } });
    try app.tree.append(app.tree.rootId(), .{ .text_area = .{ .label = "Body" } });
}

test "e2e: typeInto puts the caret in a named field and types" {
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = buildComposer });
    defer h.deinit();

    // Both text-entry roles answer to the one verb…
    try h.typeInto("Subject", "Hello");
    try h.expectValue("Subject", "Hello");
    try h.typeInto("Body", "First line.");
    try h.expectValue("Body", "First line.");
    // …and typing types: a second call appends, like a user's fingers.
    try h.typeInto("Subject", " again");
    try h.expectValue("Subject", "Hello again");

    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NoSuchElement, h.typeInto("Recipient", "x"));
}

test "e2e: expectPresent and expectDisabled assert what a user meets" {
    const Form = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.append(app.tree.rootId(), .{ .toggle = .{ .label = "Show done" } });
            try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Send", .disabled = true } });
            try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save" } });
        }
    };
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = Form.build });
    defer h.deinit();

    try h.expectPresent(.toggle, "Show done");
    // A control that declines rather than acts, read off the node —
    // pressing it would print a diagnostic from a passing test.
    try h.expectDisabled("Send");
    // Its twin: "the last field armed Save" is an assertion about the
    // form, and proving it by pressing would submit the form.
    try h.expectEnabled("Save");

    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NoSuchElement, h.expectPresent(.button, "Show done"));
    try testing.expectError(error.DisabledMismatch, h.expectDisabled("Save"));
    try testing.expectError(error.NoSuchElement, h.expectDisabled("Publish"));
    try testing.expectError(error.EnabledMismatch, h.expectEnabled("Send"));
    try testing.expectError(error.NoSuchElement, h.expectEnabled("Publish"));
    // A name on screen that belongs to something that cannot be
    // disabled at all: the wrong words, not a placid "enabled".
    try testing.expectError(error.NotAControl, h.expectDisabled("Show done"));

    // And the lookup is scoped to the kinds that carry the state, not
    // label-first: a heading names the control under it on nearly every
    // screen, and the verb must find the control (`controlWithLabel`).
    try h.app.tree.append(h.app.tree.rootId(), .{ .heading = .{ .content = "Send", .level = .h2 } });
    h.app.invalidate();
    try h.expectDisabled("Send");
}

test "e2e: expectDisabled reads across the kinds that can be disabled" {
    // The verb was buttons-only while the state was not, so a form that
    // stands its fields down on submit had no assertion to make about
    // them (`driver.disabledOf`).
    const Form = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            const root = app.tree.rootId();
            try app.tree.append(root, .{ .text_input = .{
                .label = "Verification code",
                .value = "481923",
                .disabled = true,
            } });
            try app.tree.append(root, .{ .text_area = .{ .label = "Why you are joining", .disabled = true } });
            try app.tree.append(root, .{ .text_input = .{ .label = "City", .value = "Berlin" } });
            try app.tree.append(root, .{ .button = .{ .label = "Verify", .in_progress = true } });
        }
    };
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = Form.build });
    defer h.deinit();

    try h.expectDisabled("Verification code");
    try h.expectDisabled("Why you are joining");
    try h.expectEnabled("City");
    // Busy is not disabled, and the two verbs stay different questions:
    // the button beside the fields keeps its focus stop and its arm.
    try h.expectEnabled("Verify");
    try h.expectBusy("Verify", true);

    diag.quiet = true;
    defer diag.quiet = false;
    // Every road text reaches a field by is shut, and the driver says
    // so instead of timing out on an unreachable tab stop.
    try testing.expectError(error.Disabled, h.typeInto("Verification code", "7"));
    try testing.expectError(error.Disabled, h.clearField("Why you are joining"));
    // And the tap road, which refuses on `isFocusable` like any
    // non-interactive target.
    const id = try h.getByLabel("Verification code");
    try testing.expectError(error.NotInteractive, h.tap(id));
}

test "e2e: expectValue reads whatever the a11y node calls its value" {
    const Screen = struct {
        fn open(_: ?*anyopaque) void {}

        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            const root = app.tree.rootId();
            const group = try app.tree.appendId(root, .{ .tile_group = .{} });
            try app.tree.append(group, .{ .tile = .{
                .label = "Design",
                .detail = "3 more need to collect their keys",
                .on_press = .{ .call = open },
            } });
            try app.tree.append(root, .{ .copyable = .{ .label = "Invite code", .value = "ACME01" } });
            try app.tree.append(root, .{ .qr = .{
                .label = "Scan to join",
                .value = "https://example.test/#/invite/ACME01",
            } });
            try app.tree.append(root, .{ .select = .{
                .label = "Country",
                .options = &.{ "Japan", "Peru" },
                .selected = 1,
            } });
        }
    };
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = Screen.build });
    defer h.deinit();

    // A tile's detail line, a copyable's payload, a QR's encoded URL:
    // all three are the *value* the snapshot reports, so all three
    // answer to the one verb — reaching into `tree.getConst(id).?
    // .tile.detail` asserts the same bytes through a door the audit
    // does not watch.
    try h.expectValue("Design", "3 more need to collect their keys");
    try h.expectValue("Invite code", "ACME01");
    try h.expectValue("Scan to join", "https://example.test/#/invite/ACME01");
    try h.expectValue("Country", "Peru");

    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try testing.expectError(error.ValueMismatch, h.expectValue("Invite code", "ACME02"));
    try testing.expectEqualStrings(
        "expected \"Invite code\" value \"ACME02\", got \"ACME01\"\n",
        said.text(),
    );
}

// Five destinations that cannot fit a phone's width: the roster golden
// tests prove 375 collapses this set to the chip and 1000 lays it out
// as a row, so the same table drives goTab through both shapes.
const tab_routes = [_]@import("../core/router.zig").RouteDef{
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildBlank },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildBlank },
    .{ .name = "explore", .title = .{ .fixed = "Explore" }, .build = buildBlank },
    .{ .name = "downloads", .title = .{ .fixed = "Downloads" }, .build = buildBlank },
    .{ .name = "subs", .title = .{ .fixed = "Subscriptions" }, .build = buildBlank },
};
const tab_items = [_]@import("../core/nav.zig").Destination{
    .{ .route = "library", .icon = .library },
    .{ .route = "settings", .icon = .settings },
    .{ .route = "explore", .icon = .compass },
    .{ .route = "downloads", .icon = .download },
    .{ .route = "subs", .icon = .user },
};

test "e2e: goTab crosses the wide row, and going where you stand is done already" {
    var h = try Harness.init(testing.allocator, .{ .w = 1000, .h = 300 }, .{ .routes = &tab_routes, .nav = &tab_items, .initial_route = "explore" });
    defer h.deinit();

    // Shape one: a row of destinations, each a `nav_item`.
    try h.goTab("Library");
    try h.expectRoute("library");

    // Shape two: the destination under foot is the `nav_here` marker —
    // deliberately not a control — so crossing to it is a no-op, not a
    // refused tap.
    try h.goTab("Library");
    try h.expectRoute("library");

    // A title no destination carries is a loud miss.
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NoSuchElement, h.goTab("Nowhere"));
}

test "e2e: goTab crosses the collapsed chip's picker" {
    var h = try Harness.init(testing.allocator, .{ .w = 375, .h = 300 }, .{ .routes = &tab_routes, .nav = &tab_items, .initial_route = "explore" });
    defer h.deinit();

    // Shape three: the roster did not fit, so the bar is one chip and
    // the roster is the picker it opens.
    _ = try h.getByRole(.nav_current, h.app.chrome.section);
    try h.goTab("Downloads");
    try h.expectRoute("downloads");
}

// The three controls that can be busy, one of each, plus a paragraph
// wearing a control's words: `in_progress` is not a button-only fact,
// and half the consumer tests that reached into the raw tree for it
// were reading toggles.
fn buildBusy(_: ?*anyopaque, app: *App) anyerror!void {
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .button = .{ .label = "Send", .in_progress = true } });
    try app.tree.append(root, .{ .toggle = .{ .label = "Share snapshot", .on = false, .in_progress = true } });
    try app.tree.append(root, .{ .checkbox = .{ .label = "Weekly digest", .checked = true, .in_progress = true } });
    try app.tree.append(root, .{ .button = .{ .label = "Cancel" } });
    try app.tree.append(root, .{ .text = .{ .content = "Encrypting..." } });
}

test "e2e: expectProblem reads the reason and the invalid flag together" {
    const Screen = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            const root = app.tree.rootId();
            try app.tree.append(root, .{ .text_input = .{
                .label = "Email",
                .value = "not-an-address",
                .problem = "That is not an email address.",
            } });
            try app.tree.append(root, .{ .text_area = .{ .label = "Notes" } });
        }
    };
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = Screen.build });
    defer h.deinit();

    try h.expectProblem("Email", "That is not an email address.");
    // A field with nothing wrong with it answers the same verb with the
    // empty string — the other half of every validation test.
    try h.expectProblem("Notes", "");

    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try testing.expectError(error.ProblemMismatch, h.expectProblem("Email", "Try again."));
    try testing.expectEqualStrings(
        "expected \"Email\" problem \"Try again.\", got \"That is not an email address.\"\n",
        said.text(),
    );
    said.stop();

    // Cleared, and the flag clears with it — the pair is derived from
    // one string, so there is no second field to leave behind.
    h.app.tree.get(try h.getByLabel("Email")).?.text_input.problem = "";
    h.app.invalidate();
    try h.expectProblem("Email", "");
}

test "e2e: expectBusy reads across the three kinds that can be busy" {
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = buildBusy });
    defer h.deinit();

    try h.expectBusy("Send", true);
    try h.expectBusy("Share snapshot", true);
    try h.expectBusy("Weekly digest", true);
    try h.expectBusy("Cancel", false);

    // Busy is not disabled and not a value: a control with work in
    // flight keeps its focus stop and still reads what the server holds.
    try h.expectEnabled("Send");
    try h.expectChecked("Share snapshot", false);
}

test "e2e: expectBusy says which way round it was, and refuses a non-control" {
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = buildBusy });
    defer h.deinit();

    {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.BusyMismatch, h.expectBusy("Send", false));
        try testing.expectEqualStrings(
            "expected \"Send\" not busy, but work is in flight on it\n",
            said.text(),
        );
    }
    {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.BusyMismatch, h.expectBusy("Cancel", true));
        try testing.expectEqualStrings(
            "expected \"Cancel\" busy, but no work is in flight on it\n",
            said.text(),
        );
    }
    {
        // A paragraph is never busy, and saying "not busy" would send
        // the reader looking at the control instead of at the query.
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.NotAControl, h.expectBusy("Encrypting...", false));
        try testing.expectEqualStrings(
            "expected \"Encrypting...\" busy or not, but it is a text — only buttons, toggles and checkboxes carry work in flight\n",
            said.text(),
        );
    }
    {
        // A name nothing carries is the query's usual loud miss.
        diag.quiet = true;
        defer diag.quiet = false;
        try testing.expectError(error.NoSuchElement, h.expectBusy("Nowhere", true));
    }
}

test "e2e: a busy control refuses the press, and expectBusy is how a test says so" {
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, .{ .build = buildBusy });
    defer h.deinit();

    // The pair the six migrated consumer sites are made of: the driver
    // refuses to press work that is already running, and the assertion
    // names the reason without reaching into the tree.
    try h.expectBusy("Send", true);
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.InProgress, h.tapLabel("Send"));
}
