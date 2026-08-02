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
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Todo", .level = .h1 } });
    _ = try app.tree.append(root, .{ .text_input = .{
        .label = "New item",
        .placeholder = "What needs doing?",
        .on_change = .{ .ctx = data, .call = TodoCtx.onChange },
        .on_submit = .{ .ctx = data, .call = TodoCtx.onSubmit },
    } });
    _ = try app.tree.append(root, .{ .toggle = .{ .label = "Show done" } });
}

test "e2e: fill a form with keyboard only" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
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
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
    defer h.deinit();

    try h.tapLabel("Show done");
    try h.expectFocused("Show done");
    try h.expectChecked("Show done", true);
}

test "e2e: ime composition through the harness" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
    defer h.deinit();

    try h.focusVia(try h.getByLabel("New item"));
    try h.composeText("miruku", "ミルク");
    try h.expectValue("New item", "ミルク");
}

test "e2e: a11y snapshot reflects interaction state" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
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
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
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
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
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
        _ = try h.app.tree.append(h.app.tree.rootId(), .{ .toggle = .{ .label = label } });
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
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
    defer h.deinit();
    const btn = try h.app.tree.append(h.app.tree.rootId(), .{ .button = .{ .label = "Count primes", .in_progress = true } });
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
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
    defer h.deinit();
    const sw = try h.app.tree.append(h.app.tree.rootId(), .{ .toggle = .{ .label = "Push to phone", .in_progress = true } });
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

test "e2e: pending notices are assertable where the snapshot cannot see them" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
    defer h.deinit();

    // Quiet: nothing but the indicator appears, so the only trace on
    // screen is a button named for the *chrome*, not for the notice.
    try h.app.notify(.{ .title = "Draft saved", .description = "Kept locally." });
    try h.expectNotified("Draft saved");
    try h.expectAbsent("Draft saved"); // …and no element says so
    _ = try h.getByLabel("Show notices");

    // Important notices go in front of quiet ones, whatever order they
    // were raised in, and the banner is always the front one.
    try h.app.notify(.{ .title = "Sync failed", .route = "home", .important = true });
    const pending = h.noticesPending();
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqualStrings("Sync failed", pending[0].title);
    try testing.expect(pending[0].important);
    try testing.expectEqualStrings("home", pending[0].route);
    try testing.expectEqualStrings("Draft saved", pending[1].title);
    try testing.expect(!pending[1].important);
    try testing.expectEqualStrings("Kept locally.", pending[1].description);

    // A duplicate title is dropped, and leaves no mark anywhere else:
    // the second call is silent, so the count is the only witness.
    try h.app.notify(.{ .title = "Sync failed", .description = "…again", .important = true });
    try testing.expectEqual(@as(usize, 2), h.noticesPending().len);
    try testing.expectEqualStrings("", h.noticesPending()[0].description);

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
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
    defer h.deinit();
    try h.app.notify(.{ .title = "Draft saved" });

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
            _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Section", .level = .h2 } });
        }
    };
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(
        error.A11yAuditFailed,
        Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, null, bad.build),
    );
}

test "e2e: expectTree snapshots the laid-out tree inline" {
    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 200, .h = 200 }, &ctx, buildMinimal);
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
    _ = try app.tree.append(app.tree.rootId(), .{ .toggle = .{ .label = "Show done" } });
}

test "e2e: step trace writes a tree snapshot per action" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var ctx: TodoCtx = .{};
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, &ctx, buildTodo);
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
    _ = try app.tree.append(app.tree.rootId(), .{ .copyable = .{
        .label = "Recovery code",
        .value = "XKCD-1234",
    } });
}

test "e2e: expectCopied asserts the last clipboard write" {
    var h = try Harness.init(testing.allocator, .{ .w = 480, .h = 640 }, null, buildRecovery);
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
    .{ .name = "consent", .title = "Consent", .build = buildTermsDoc },
    .{ .name = "terms", .title = "Terms", .build = buildTermsTarget },
};

fn buildTermsDoc(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .document = .{
        .label = "Consent",
        .source =
        \\By continuing you accept the [terms of service](terms).
        ,
    } });
}

fn buildTermsTarget(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Terms" } });
}

test "e2e: an inline link is tapped and tabbed to by its words" {
    var harness = try Harness.initWithRoutes(testing.allocator, .{ .w = 360, .h = 300 }, &consent_routes, null, "consent");
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
    .{ .name = "inbox", .title = "Inbox", .build = buildInbox },
    .{ .name = "ticket", .title = "Ticket", .args = 1, .build = buildTicketScreen },
};

fn buildInbox(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .document = .{
        .label = "Inbox",
        .source =
        \\Latest: [the flaky build](ticket~2938).
        ,
    } });
}

fn buildTicketScreen(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{
        .heading = .{ .content = app.routeArg(0) orelse "?" },
    });
}

test "e2e: a Markdown link carries route arguments" {
    var harness = try Harness.initWithRoutes(testing.allocator, .{ .w = 360, .h = 300 }, &ticket_routes, null, "inbox");
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

test "e2e: the back gesture is an action like any other" {
    var harness = try Harness.initWithRoutes(testing.allocator, .{ .w = 360, .h = 300 }, &ticket_routes, null, "inbox");
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
    var harness = try Harness.initWithRoutes(testing.allocator, .{ .w = 360, .h = 300 }, &consent_routes, null, "consent");
    defer harness.deinit();

    try testing.expect(harness.queryLink("terms of service") != null);
    try testing.expect(harness.queryLink("privacy policy") == null);
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NoSuchElement, harness.tapLabel("privacy policy"));
}

fn buildActionRow(_: ?*anyopaque, app: *App) anyerror!void {
    const row = try app.tree.append(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Publish", "Save draft", "Duplicate", "Archive", "Delete" }) |label| {
        _ = try app.tree.append(row, .{ .button = .{ .label = label } });
    }
}

test "e2e: a folded button is reached through More, and says so when it is not" {
    // Narrow enough that the row cannot hold five actions: the tail
    // folds, and the screen still passes the audit the harness runs
    // after every step.
    var h = try Harness.init(testing.allocator, .{ .w = 400, .h = 640 }, null, buildActionRow);
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
