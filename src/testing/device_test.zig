//! The driver tier, proved end to end: `wait.zig`'s deadline-bounded
//! waits and the `Device` composed over them.
//!
//! One suite, because there is one fake clock. A driver's time is
//! injected (`Pacer`), so a test of this tier hands in a clock that
//! moves only when the wait naps — which is what makes a *timeout*
//! testable without waiting a minute, and a *late arrival* testable
//! without a thread. `Arrival` is the other half: work that lands at a
//! chosen instant on that same clock, which is the whole of "the server
//! answered while the driver was pumping".
//!
//! Every timeout here pins its **words**, not just its error. A wait
//! that fails after a minute and says "waited 60000ms" has told the
//! reader nothing; the contract is that it names what it was waiting
//! for *and* what was on the screen instead, and a contract nothing
//! asserts is a comment.

const std = @import("std");

const app_mod = @import("../core/app.zig");
const bind = @import("../core/bind.zig");
const nav_mod = @import("../core/nav.zig");
const router_mod = @import("../core/router.zig");
const diag = @import("diag.zig");
const device_mod = @import("device.zig");
const queries = @import("queries.zig");
const wait = @import("wait.zig");

const App = app_mod.App;
const Device = device_mod.Device;
const testing = std.testing;

// ---- the fake clock ----

/// A clock that only moves when the wait naps, plus one piece of work
/// that lands at a chosen instant on it. Nothing here reads real time
/// or sleeps a thread, so every test below is deterministic to the poll.
const Fake = struct {
    millis: i64 = 0,
    naps: usize = 0,
    step_ms: i64 = 10,
    /// The app the arrival lands on, and when.
    app: ?*App = null,
    at_ms: i64 = std.math.maxInt(i64),
    arrive: ?*const fn (app: *App) anyerror!void = null,

    fn now(ctx: ?*anyopaque) i64 {
        return @as(*Fake, @ptrCast(@alignCast(ctx.?))).millis;
    }

    fn nap(ctx: ?*anyopaque, ns: u64) void {
        _ = ns;
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.naps += 1;
        self.millis += self.step_ms;
        if (self.millis < self.at_ms) return;
        const f = self.arrive orelse return;
        self.arrive = null;
        f(self.app.?) catch {};
    }

    fn pacer(self: *Fake, timeout_ms: i64) wait.Pacer {
        return .{ .ctx = self, .now_ms = now, .nap = nap, .timeout_ms = timeout_ms };
    }

    /// Schedules `f` to land after three naps — long enough that a wait
    /// which returned early would be caught, short enough to stay well
    /// inside the tests' deadlines.
    fn lands(self: *Fake, app: *App, f: *const fn (app: *App) anyerror!void) void {
        self.app = app;
        self.at_ms = self.millis + 3 * self.step_ms;
        self.arrive = f;
    }
};

fn plainApp(w: i32, h: i32) !App {
    return App.init(testing.allocator, .{ .viewport = .{ .w = w, .h = h }, .services = .mocks() });
}

fn deviceOn(app: *App, fake: *Fake, timeout_ms: i64) Device {
    return .{ .app = app, .pacer = fake.pacer(timeout_ms) };
}

// ---- wait.waitUntil ----

test "driver tier: waitUntil returns as soon as the predicate holds" {
    var app = try plainApp(320, 240);
    defer app.deinit();

    const Counter = struct {
        asked: usize = 0,
        fn readyOnThird(self: *@This(), _: *App) bool {
            self.asked += 1;
            return self.asked >= 3;
        }
    };
    var counter: Counter = .{};
    var fake: Fake = .{};
    try wait.waitUntil(&app, fake.pacer(60_000), "the third poll", bind.bindAs(wait.Ready, Counter.readyOnThird, &counter));
    try testing.expectEqual(@as(usize, 3), counter.asked);
    // One nap per miss, none after the hit.
    try testing.expectEqual(@as(usize, 2), fake.naps);
}

test "driver tier: waitUntil holds to its deadline, then errors" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save" } });

    const Never = struct {
        fn ready(_: *@This(), _: *App) bool {
            return false;
        }
    };
    var never: Never = .{};
    var fake: Fake = .{}; // 10ms per nap
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(
        error.WaitTimeout,
        wait.waitUntil(&app, fake.pacer(35), "a label that never comes", bind.bindAs(wait.Ready, Never.ready, &never)),
    );
    // The wait held to its deadline — four polls at 10ms crossed 35ms —
    // rather than giving up early or spinning forever.
    try testing.expectEqual(@as(usize, 4), fake.naps);
}

test "driver tier: a predicate about app state is a bound method, not a cast" {
    // The condition a driver actually waits on is rarely about the
    // screen: it is "the proof-of-work queue drained", "the prefetch
    // sweep finished". `Ready` is a `{ctx, call}` pair precisely so
    // that stays an ordinary method — no `@ptrCast`, no wrapper struct
    // per condition, which is what a bare function pointer cost.
    var app = try plainApp(320, 240);
    defer app.deinit();

    const Queue = struct {
        pending: usize = 2,
        fn drained(self: *@This(), _: *App) bool {
            if (self.pending > 0) self.pending -= 1;
            return self.pending == 0;
        }
    };
    var queue: Queue = .{};
    var fake: Fake = .{};
    try wait.waitUntil(&app, fake.pacer(60_000), "the work queue to drain", bind.bindAs(wait.Ready, Queue.drained, &queue));
    try testing.expectEqual(@as(usize, 0), queue.pending);
}

test "driver tier: the failure dump names the route, element states, notices, and the tree" {
    var app = try plainApp(400, 640);
    defer app.deinit();
    // A row too narrow for its actions, so the tail folds — the state a
    // driver most needs the dump to explain, because the folded action
    // is invisible to every query.
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Publish", "Save draft", "Duplicate", "Archive", "Delete" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Submit", .disabled = true } });
    app.notify(.{ .title = "Sync failed", .important = true });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try wait.writeScreen(testing.allocator, &out, &app);

    try testing.expect(std.mem.indexOf(u8, out.items, "on route \"(none)\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "button \"Delete\" (folded)") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "button \"Submit\" (disabled)") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "notice \"Sync failed\"") != null);
    // The trace-format tree rides along, laid out.
    try testing.expect(std.mem.indexOf(u8, out.items, "viewport 400x640") != null);
}

// ---- the promoted waits ----

fn arriveSaved(app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Saved" } });
}

test "driver tier: untilLabel waits for the screen to say it, then answers the node" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    var fake: Fake = .{};
    fake.lands(&app, arriveSaved);

    const id = try wait.untilLabel(&app, fake.pacer(60_000), "Saved");
    try testing.expect(queries.queryByLabel(&app.tree, "Saved").?.eql(id));
    // It really waited: the arrival was three naps out.
    try testing.expectEqual(@as(usize, 3), fake.naps);
}

test "driver tier: untilRole waits by semantic identity, and the role half is load-bearing" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Saved" } });
    var fake: Fake = .{};
    fake.lands(&app, arriveSaved);

    // The words are already on screen under another role; the wait is
    // for the *button*.
    const id = try wait.untilRole(&app, fake.pacer(60_000), .button, "Saved");
    try testing.expect(queries.queryByRole(&app.tree, .button, "Saved").?.eql(id));
    try testing.expectEqual(@as(usize, 3), fake.naps);
}

test "driver tier: untilLabelContaining, untilEither and untilGone" {
    var app = try plainApp(320, 320);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Invite code ACME01" } });
    var fake: Fake = .{};

    const id = try wait.untilLabelContaining(&app, fake.pacer(60_000), "ACME01");
    try testing.expectEqualStrings("Invite code ACME01", app.tree.getConst(id).?.label());

    // A fork: whichever arrives first, answered by name, so the caller
    // can branch on it.
    try testing.expectEqualStrings("Invite code ACME01", try wait.untilEither(&app, fake.pacer(60_000), "Nothing here", "Invite code ACME01"));

    const Gone = struct {
        fn strip(a: *App) anyerror!void {
            try a.tree.clearChildren(a.tree.rootId());
        }
    };
    fake.lands(&app, Gone.strip);
    try wait.untilGone(&app, fake.pacer(60_000), "Invite code ACME01");
}

const wait_routes = [_]router_mod.RouteDef{
    .{ .name = "inbox", .title = .{ .fixed = "Inbox" }, .build = buildBlank },
    .{ .name = "ticket", .title = .{ .fixed = "Ticket" }, .build = buildBlank },
};

fn buildBlank(_: ?*anyopaque, _: *App) anyerror!void {}

test "driver tier: untilRoute waits out a navigation nothing on screen announces" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .routes = &wait_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("inbox");

    const Late = struct {
        fn go(a: *App) anyerror!void {
            try a.navigate("ticket");
        }
    };
    var fake: Fake = .{};
    fake.lands(&app, Late.go);

    try wait.untilRoute(&app, fake.pacer(60_000), "ticket");
    try testing.expectEqualStrings("ticket", app.router.current().?);
}

test "driver tier: untilNotice waits for a notice the screen may never show" {
    var app = try plainApp(320, 240);
    defer app.deinit();

    const Late = struct {
        fn raise(a: *App) anyerror!void {
            a.notify(.{ .title = "Sync failed", .important = true });
        }
    };
    var fake: Fake = .{};
    fake.lands(&app, Late.raise);

    try wait.untilNotice(&app, fake.pacer(60_000), "Sync failed");
    try testing.expectEqual(@as(usize, 1), app.notices.items.len);
}

// ---- what a timeout says ----

test "driver tier: a timeout names what it waited for and what was on screen instead" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Retry" } });
    var fake: Fake = .{};

    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try testing.expectError(error.WaitTimeout, wait.untilRole(&app, fake.pacer(20), .button, "Saved"));
    said.stop();

    // The two halves the contract owes: the thing waited for, named the
    // way the caller named it, and the screen that stood there instead.
    try testing.expect(std.mem.startsWith(u8, said.text(), "waited 20ms for a button named \"Saved\"; the screen stands at:\n"));
    try testing.expect(std.mem.indexOf(u8, said.text(), "  on route \"(none)\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, said.text(), "  button \"Retry\"\n") != null);
}

test "driver tier: every promoted wait says what it was waiting for in its own words" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Retry" } });
    var fake: Fake = .{};

    const Case = struct { run: *const fn (a: *App, p: wait.Pacer) anyerror!void, said: []const u8 };
    const cases = [_]Case{
        .{ .said = "waited 20ms for \"Saved\"; ", .run = struct {
            fn f(a: *App, p: wait.Pacer) anyerror!void {
                _ = try wait.untilLabel(a, p, "Saved");
            }
        }.f },
        .{ .said = "waited 20ms for a label containing \"Saved\"; ", .run = struct {
            fn f(a: *App, p: wait.Pacer) anyerror!void {
                _ = try wait.untilLabelContaining(a, p, "Saved");
            }
        }.f },
        .{ .said = "waited 20ms for \"Saved\" or \"Failed\"; ", .run = struct {
            fn f(a: *App, p: wait.Pacer) anyerror!void {
                _ = try wait.untilEither(a, p, "Saved", "Failed");
            }
        }.f },
        .{ .said = "waited 20ms for \"Retry\" to leave the screen; ", .run = struct {
            fn f(a: *App, p: wait.Pacer) anyerror!void {
                try wait.untilGone(a, p, "Retry");
            }
        }.f },
        .{ .said = "waited 20ms for route \"ticket\"; ", .run = struct {
            fn f(a: *App, p: wait.Pacer) anyerror!void {
                try wait.untilRoute(a, p, "ticket");
            }
        }.f },
        .{ .said = "waited 20ms for a notice titled \"Sync failed\"; ", .run = struct {
            fn f(a: *App, p: wait.Pacer) anyerror!void {
                try wait.untilNotice(a, p, "Sync failed");
            }
        }.f },
    };

    for (cases) |c| {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.WaitTimeout, c.run(&app, fake.pacer(20)));
        said.stop();
        try testing.expect(std.mem.startsWith(u8, said.text(), c.said));
        // Every one of them owes the screen, not only the heading.
        try testing.expect(std.mem.indexOf(u8, said.text(), "button \"Retry\"") != null);
    }
}

// ---- the Device's verbs ----

test "driver tier: press waits for the control, then takes a user's route to it" {
    var app = try plainApp(400, 640);
    defer app.deinit();

    const Pressed = struct {
        var count: u32 = 0;
        fn onPress(_: ?*anyopaque) void {
            count += 1;
        }
        fn arrive(a: *App) anyerror!void {
            try a.tree.append(a.tree.rootId(), .{ .button = .{
                .label = "Archive",
                .on_press = .{ .call = onPress },
            } });
        }
    };
    Pressed.count = 0;

    var fake: Fake = .{};
    fake.lands(&app, Pressed.arrive);
    var d = deviceOn(&app, &fake, 60_000);

    try d.press(.button, "Archive");
    try testing.expectEqual(@as(u32, 1), Pressed.count);
    try testing.expectEqual(@as(usize, 3), fake.naps);
}

test "driver tier: press reaches a folded action without spending the deadline first" {
    var app = try plainApp(400, 640);
    defer app.deinit();
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    const Pressed = struct {
        var count: u32 = 0;
        fn onPress(_: ?*anyopaque) void {
            count += 1;
        }
    };
    Pressed.count = 0;
    for ([_][]const u8{ "Publish", "Save draft", "Duplicate" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }
    try app.tree.append(row, .{ .button = .{ .label = "Archive", .on_press = .{ .call = Pressed.onPress } } });
    try app.tree.append(row, .{ .button = .{ .label = "Delete" } });

    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 60_000);

    // The row folded the tail, so "Archive" is invisible to every
    // query — and the wait must *not* run: a minute spent discovering
    // that is the hour this check exists to save.
    try d.press(.button, "Archive");
    try testing.expectEqual(@as(u32, 1), Pressed.count);
    try testing.expectEqual(@as(usize, 0), fake.naps);
}

test "driver tier: clearField then typeInto leaves the field holding exactly the text" {
    var app = try plainApp(480, 640);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Subject" } });

    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 60_000);

    try d.typeInto("Subject", "Hello");
    try d.expectValue("Subject", "Hello");
    // typeInto appends, exactly as a user's fingers do…
    try d.typeInto("Subject", " again");
    try d.expectValue("Subject", "Hello again");
    // …and clearing is the separate act it is for a user.
    try d.clearField("Subject");
    try d.expectValue("Subject", "");
    try d.typeInto("Subject", "Fresh");
    try d.expectValue("Subject", "Fresh");
}

test "driver tier: clearField empties a field holding multi-byte text" {
    var app = try plainApp(480, 640);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Name" } });

    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 60_000);
    // Four codepoints, twelve bytes: the budget is bytes, so it is an
    // upper bound that terminates rather than a step count that would
    // leave two characters behind.
    try d.typeInto("Name", "日本語だ");
    try d.clearField("Name");
    try d.expectValue("Name", "");
}

// A choice control on a screen that rebuilds on every commit — the
// shape both shipped drivers hit and worked around by re-implementing
// the whole walk. `driver.selectOption` re-finds the control between
// steps, so one walk serves both tiers.
const Rebuilder = struct {
    selected: usize = 0,
    rebuilds: u32 = 0,
    app: *App = undefined,

    const options = [_][]const u8{ "Daily", "Weekly", "Monthly", "Never" };

    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *Rebuilder = @ptrCast(@alignCast(ctx.?));
        // A fresh node ahead of the control every rebuild, so the id the
        // walk started from cannot survive one.
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Digest frequency" } });
        try app.tree.append(app.tree.rootId(), .{ .segmented = .{
            .label = "Digest",
            .options = &options,
            .selected = self.selected,
            .on_select = .{ .ctx = self, .call = onSelect },
        } });
    }

    fn onSelect(ctx: ?*anyopaque, index: usize) void {
        const self: *Rebuilder = @ptrCast(@alignCast(ctx.?));
        self.selected = index;
        self.rebuilds += 1;
        self.app.refresh(.{});
    }
};

const rebuild_routes = [_]router_mod.RouteDef{
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = Rebuilder.build },
};

test "driver tier: selectOption survives a screen that rebuilds on every commit" {
    var state: Rebuilder = .{};
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 640, .h = 480 },
        .routes = &rebuild_routes,
        .ctx = &state,
        .services = .mocks(),
    });
    defer app.deinit();
    state.app = &app;
    try app.navigate("settings");

    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 60_000);

    try d.selectOption("Digest", "Never");
    try d.expectValue("Digest", "Never");
    // Three commits to walk Daily → Never, each one a rebuild: holding
    // the first node id would have failed on the second step.
    try testing.expectEqual(@as(u32, 3), state.rebuilds);

    // And backwards, which is the other direction's key.
    try d.selectOption("Digest", "Weekly");
    try d.expectValue("Digest", "Weekly");
}

const tab_routes = [_]router_mod.RouteDef{
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildBlank },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildBlank },
    .{ .name = "explore", .title = .{ .fixed = "Explore" }, .build = buildBlank },
    .{ .name = "downloads", .title = .{ .fixed = "Downloads" }, .build = buildBlank },
    .{ .name = "subs", .title = .{ .fixed = "Subscriptions" }, .build = buildBlank },
};
const tab_items = [_]nav_mod.Destination{
    .{ .route = "library", .icon = .library },
    .{ .route = "settings", .icon = .settings },
    .{ .route = "explore", .icon = .compass },
    .{ .route = "downloads", .icon = .download },
    .{ .route = "subs", .icon = .user },
};

fn tabApp(w: i32, h: i32) !App {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = w, .h = h },
        .routes = &tab_routes,
        .services = .mocks(),
    });
    errdefer app.deinit();
    try app.setNav(&tab_items);
    try app.navigate("explore");
    return app;
}

test "driver tier: goTab crosses both shapes of the bar, and standing still is a no-op" {
    var wide = try tabApp(1000, 300);
    defer wide.deinit();
    var fake: Fake = .{};
    var d = deviceOn(&wide, &fake, 60_000);

    try d.goTab("Library");
    try d.expectRoute("library");
    // The destination under foot is the `nav_here` marker, which is
    // deliberately not a control: going where you stand is done.
    try d.goTab("Library");
    try d.expectRoute("library");

    var narrow = try tabApp(375, 300);
    defer narrow.deinit();
    var d2 = deviceOn(&narrow, &fake, 60_000);
    try d2.goTab("Downloads");
    try d2.expectRoute("downloads");
}

test "driver tier: the expect verbs assert what a user meets, and wait where waiting is honest" {
    var app = try plainApp(480, 640);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save", .disabled = true } });
    try app.tree.append(app.tree.rootId(), .{ .toggle = .{ .label = "Show done" } });

    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 60_000);

    try d.expectPresent(.toggle, "Show done");
    try d.expectDisabled("Save");
    try d.expectAbsent("Publish");

    // The arming reply lands three naps out and `expectEnabled` waits
    // it out by itself: the button is on screen, disabled, for the
    // whole time the reply is in flight, so a verb that waited only for
    // the *control* would have failed here on a form that arms
    // perfectly well.
    const Arm = struct {
        fn arrive(a: *App) anyerror!void {
            try a.tree.clearChildren(a.tree.rootId());
            try a.tree.append(a.tree.rootId(), .{ .button = .{ .label = "Save" } });
        }
    };
    fake.lands(&app, Arm.arrive);
    try d.expectEnabled("Save");
    try testing.expectEqual(@as(usize, 3), fake.naps);
    try d.expectGone("Show done");
}

test "driver tier: goTab waits for a bar whose roster has not arrived" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 1000, .h = 300 },
        .routes = &tab_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("explore");

    // The roster is what a session's first reply installs; until then
    // the bar is not there to walk. The old drivers waited for this and
    // the framework's first cut did not — a `pump()` and straight into
    // the walk, which is strictly less patient than the code it
    // replaced.
    const Roster = struct {
        fn arrive(a: *App) anyerror!void {
            try a.setNav(&tab_items);
            try a.navigate("explore");
        }
    };
    var fake: Fake = .{};
    fake.lands(&app, Roster.arrive);
    var d = deviceOn(&app, &fake, 60_000);

    try d.goTab("Library");
    try d.expectRoute("library");
    try testing.expectEqual(@as(usize, 3), fake.naps);
}

test "driver tier: goTab's wait knows all three shapes the bar wears" {
    // The collapsed chip is the shape a phone gets, and it carries no
    // `nav_item` at all — a wait that knew only the row would time out
    // on every narrow viewport.
    var narrow = try App.init(testing.allocator, .{
        .viewport = .{ .w = 375, .h = 300 },
        .routes = &tab_routes,
        .services = .mocks(),
    });
    defer narrow.deinit();
    try narrow.navigate("explore");

    const Roster = struct {
        fn arrive(a: *App) anyerror!void {
            try a.setNav(&tab_items);
            try a.navigate("explore");
        }
    };
    var fake: Fake = .{};
    fake.lands(&narrow, Roster.arrive);
    var d = deviceOn(&narrow, &fake, 60_000);

    try d.goTab("Downloads");
    try d.expectRoute("downloads");
    try testing.expectEqual(@as(usize, 3), fake.naps);

    // And the third shape: the marker under foot, which is not a
    // control, so crossing to where you stand ends the wait and does
    // nothing.
    try d.goTab("Downloads");
    try d.expectRoute("downloads");
}

test "driver tier: the field verbs wait for a field, not for the words" {
    var app = try plainApp(480, 640);
    defer app.deinit();
    // The screen says "Email" from the start — as prose. A wait on the
    // bare label would end here and hand `typeInto` a control that has
    // not been built yet.
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Email" } });

    const Field = struct {
        fn arrive(a: *App) anyerror!void {
            try a.tree.append(a.tree.rootId(), .{ .text_input = .{ .label = "Email" } });
        }
    };
    var fake: Fake = .{};
    fake.lands(&app, Field.arrive);
    var d = deviceOn(&app, &fake, 60_000);

    try d.typeInto("Email", "ada@example.com");
    try testing.expectEqual(@as(usize, 3), fake.naps);
    // Read off the element rather than through `expectValue`: this
    // fixture deliberately puts the same words on two nodes, and the
    // a11y snapshot answers a label in document order — so the prose
    // would answer first. That ambiguity is exactly what naming the
    // *family* protects the acting verbs from.
    const field = queries.queryByRole(&app.tree, .text_input, "Email").?;
    try testing.expectEqualStrings("ada@example.com", app.tree.getConst(field).?.text_input.value);
}

test "driver tier: expectValue waits for the value, not for the label" {
    var app = try plainApp(480, 640);
    defer app.deinit();
    const Stale = struct {
        var text: []const u8 = "ACME01";
        fn build(_: ?*anyopaque, a: *App) anyerror!void {
            try a.tree.append(a.tree.rootId(), .{ .copyable = .{ .label = "Invite code", .value = text } });
        }
        fn arrive(a: *App) anyerror!void {
            text = "ACME02";
            try a.tree.clearChildren(a.tree.rootId());
            try build(null, a);
        }
    };
    Stale.text = "ACME01";
    try Stale.build(null, &app);

    // The label is on screen the whole time, carrying the *previous*
    // answer. A wait that stopped at the label would assert the stale
    // value every run.
    var fake: Fake = .{};
    fake.lands(&app, Stale.arrive);
    var d = deviceOn(&app, &fake, 60_000);

    try d.expectValue("Invite code", "ACME02");
    try testing.expectEqual(@as(usize, 3), fake.naps);
}

test "driver tier: the state waits say what they wanted and what they found" {
    var app = try plainApp(480, 640);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save", .disabled = true } });
    try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Invite code", .value = "ACME01" } });
    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 20);

    {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.WaitTimeout, d.expectEnabled("Save"));
        said.stop();
        try testing.expect(std.mem.startsWith(u8, said.text(), "waited 20ms for \"Save\" to take presses; the screen stands at:\n"));
        try testing.expect(std.mem.indexOf(u8, said.text(), "button \"Save\" (disabled)") != null);
        // The screen dump carries no values, so the precise mismatch is
        // spelled out under it rather than left to a tree diff.
        try testing.expect(std.mem.endsWith(u8, said.text(), "expected \"Save\" to take presses, but it is disabled\n"));
    }
    {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.WaitTimeout, d.expectValue("Invite code", "ACME02"));
        said.stop();
        try testing.expect(std.mem.startsWith(u8, said.text(), "waited 20ms for \"Invite code\" to read \"ACME02\"; the screen stands at:\n"));
        try testing.expect(std.mem.endsWith(u8, said.text(), "expected \"Invite code\" value \"ACME02\", got \"ACME01\"\n"));
    }
    {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.WaitTimeout, d.goTab("Library"));
        said.stop();
        try testing.expect(std.mem.startsWith(u8, said.text(), "waited 20ms for a nav destination named \"Library\"; the screen stands at:\n"));
    }
    {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try testing.expectError(error.WaitTimeout, d.typeInto("Save", "x"));
        said.stop();
        // The family it was looking for, read out — not the first
        // member of it.
        try testing.expect(std.mem.startsWith(u8, said.text(), "waited 20ms for a text_input or text_area named \"Save\"; the screen stands at:\n"));
    }
}

test "driver tier: expectAbsent never waits, because a wait would assert the opposite" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    var fake: Fake = .{};
    // A label that is going to appear would pass a waiting absence
    // check for as long as it took to arrive, which is why this one
    // reads the screen as it stands.
    fake.lands(&app, arriveSaved);
    var d = deviceOn(&app, &fake, 60_000);

    try d.expectAbsent("Saved");
    try testing.expectEqual(@as(usize, 0), fake.naps);
}

test "driver tier: expectNotified and expectRoute wait for what no label announces" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .routes = &wait_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("inbox");

    const Late = struct {
        fn arrive(a: *App) anyerror!void {
            a.notify(.{ .title = "Sync failed", .important = true });
            try a.navigate("ticket");
        }
    };
    var fake: Fake = .{};
    fake.lands(&app, Late.arrive);
    var d = deviceOn(&app, &fake, 60_000);

    try d.expectNotified("Sync failed");
    try d.expectRoute("ticket");
}

test "driver tier: valueOf and labelContaining read what a screen reader could" {
    var app = try plainApp(480, 640);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Invite code", .value = "ACME01" } });
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Seats used: 7 of 20" } });

    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 60_000);

    const code = try d.valueOf(testing.allocator, "Invite code");
    defer testing.allocator.free(code);
    try testing.expectEqualStrings("ACME01", code);
    try testing.expectEqualStrings("Seats used: 7 of 20", try d.labelContaining("7 of 20"));
}

test "driver tier: every action re-audits, so two live controls sharing a label fail" {
    var app = try plainApp(480, 640);
    defer app.deinit();

    const Dup = struct {
        var target: ?*App = null;
        var fired: u32 = 0;
        /// The press succeeds and the screen it produced is the
        /// problem — two controls a driver could only tell apart by
        /// tree position, which is the thing driving by accessible
        /// name must never have to do.
        fn onPress(_: ?*anyopaque) void {
            fired += 1;
            (target.?).tree.append(target.?.tree.rootId(), .{ .button = .{ .label = "Open" } }) catch {};
        }
    };
    Dup.target = &app;
    Dup.fired = 0;
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Open" } });
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Duplicate row", .on_press = .{ .call = Dup.onPress } } });

    var fake: Fake = .{};
    var d = deviceOn(&app, &fake, 60_000);

    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.A11yAuditFailed, d.press(.button, "Duplicate row"));
    try testing.expectEqual(@as(u32, 1), Dup.fired);
}

test "driver tier: notes ride under the framework's picture on any refusal, exactly once" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Retry" } });

    const Phases = struct {
        calls: u32 = 0,
        fn dump(self: *@This()) void {
            self.calls += 1;
            diag.print("    (proofs pending: 3)\n", .{});
        }
    };
    var phases: Phases = .{};
    var fake: Fake = .{};
    var d: Device = .{
        .app = &app,
        .pacer = fake.pacer(20),
        .notes = bind.bindAs(device_mod.Notes, Phases.dump, &phases),
    };

    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try testing.expectError(error.WaitTimeout, d.press(.button, "Saved"));
    said.stop();

    try testing.expectEqual(@as(u32, 1), phases.calls);
    // The app's own state lands *after* the screen nokre dumped: the
    // framework says what is on the screen, the driver says what is
    // behind it.
    const dumped = std.mem.indexOf(u8, said.text(), "button \"Retry\"").?;
    const noted = std.mem.indexOf(u8, said.text(), "(proofs pending: 3)").?;
    try testing.expect(noted > dumped);
}

test "driver tier: quiesce pumps for a fixed span and never longer" {
    var app = try plainApp(320, 240);
    defer app.deinit();
    var fake: Fake = .{}; // 10ms per nap
    var d = deviceOn(&app, &fake, 60_000);

    d.quiesce(35);
    try testing.expectEqual(@as(usize, 4), fake.naps);
    try testing.expectEqual(@as(i64, 40), fake.millis);
}
