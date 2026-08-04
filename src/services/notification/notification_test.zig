//! notification service tests: the consumer surface driven through the
//! per-app mock — the only notification centre under `zig test`, so what
//! holds here is the whole contract. Two directions: what the app asked
//! the OS to do is journaled, and what the user did is a verb the test
//! fires. docs/services.md is the contract held here.

const std = @import("std");
const notification = @import("notification.zig");
const app_mod = @import("../../core/app.zig");
const clock = @import("../clock/clock.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;
const Notification = notification.Notification;

fn grantedApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .notification = .mock(.{ .status = .granted }) },
    });
}

const ok: Notification = .{ .id = "n.1", .title = "Ready" };

// ---- the argument gate: pure, and identical on all six platforms ----

test "id charset and cap: a pure function of the argument" {
    try std.testing.expect(notification.validId("n.1"));
    try std.testing.expect(notification.validId("a-b_c.9"));
    // Empty, over-cap, uppercase, and anything outside [a-z0-9._-].
    try std.testing.expect(!notification.validId(""));
    try std.testing.expect(!notification.validId(&([_]u8{'a'} ** (notification.max_id_bytes + 1))));
    try std.testing.expect(!notification.validId("Nope"));
    try std.testing.expect(!notification.validId("has space"));
    try std.testing.expect(!notification.validId("emoji🙂"));
    // Exactly at the cap still passes: the bound is inclusive.
    try std.testing.expect(notification.validId(&([_]u8{'a'} ** notification.max_id_bytes)));
}

test "argument errors are reachable before any OS call, and journal nothing" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();

    try std.testing.expectError(error.InvalidId, notification.post(&app, .{ .id = "", .title = "x" }));
    try std.testing.expectError(error.EmptyTitle, notification.post(&app, .{ .id = "n.1", .title = "" }));
    const long_title = [_]u8{'t'} ** (notification.max_title_bytes + 1);
    try std.testing.expectError(error.TitleTooLarge, notification.post(&app, .{ .id = "n.1", .title = &long_title }));
    const long_body = [_]u8{'b'} ** (notification.max_body_bytes + 1);
    try std.testing.expectError(error.BodyTooLarge, notification.post(&app, .{ .id = "n.1", .title = "t", .body = &long_body }));
    const long_route = [_]u8{'r'} ** (notification.max_route_bytes + 1);
    try std.testing.expectError(error.RouteTooLarge, notification.post(&app, .{ .id = "n.1", .title = "t", .route = &long_route }));
    // A refused call never reached the OS, so it left no trace.
    try std.testing.expectEqual(@as(usize, 0), app.services.notification.entries().len);
}

test "posting needs authorization, and the argument checks still run without it" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .notification = .mock(.{}) }, // not_determined: the fresh install
    });
    defer app.deinit();

    try std.testing.expectEqual(notification.Status.not_determined, notification.status(&app));
    try std.testing.expectError(error.NotAuthorized, notification.post(&app, ok));
    // Malformed is malformed whether or not the prompt was ever answered.
    try std.testing.expectError(error.InvalidId, notification.post(&app, .{ .id = "NO", .title = "t" }));

    app.services.notification.grant();
    try std.testing.expectEqual(notification.Status.granted, notification.status(&app));
    try notification.post(&app, ok);
    try std.testing.expectEqual(@as(usize, 1), app.services.notification.entries().len);
}

test "a denied device refuses every post, and cannot be asked back into granted" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();
    try notification.post(&app, ok);

    // Revoked in Settings with the app running.
    app.services.notification.deny();
    try std.testing.expectEqual(notification.Status.denied, notification.status(&app));
    try std.testing.expectError(error.NotAuthorized, notification.post(&app, ok));
    // Asking again is legal and does nothing on every platform — the
    // journal shows the app asked, and the status does not move.
    try notification.authorize(&app);
    try std.testing.expectEqual(notification.Status.denied, notification.status(&app));
}

// ---- available / pushAvailable: the two runtime postures ----

test "a device with no notification system refuses everything by posture" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .notification = .mock(.{ .available = false, .status = .granted }) },
    });
    defer app.deinit();

    try std.testing.expect(!notification.available(&app));
    try std.testing.expectError(error.Unavailable, notification.post(&app, ok));
    try std.testing.expectError(error.Unavailable, notification.cancel(&app, "n.1"));
    try std.testing.expectError(error.Unavailable, notification.authorize(&app));
    try std.testing.expectEqual(@as(usize, 0), app.services.notification.entries().len);
}

test "push is a separate posture from notifying at all" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .notification = .mock(.{ .push_available = false, .status = .granted }) },
    });
    defer app.deinit();

    // The Linux desktop and an unpackaged Windows app: notifications
    // work, push does not.
    try std.testing.expect(notification.available(&app));
    try std.testing.expect(!notification.pushAvailable(&app));
    try notification.post(&app, ok);
    try std.testing.expectError(error.Unavailable, notification.requestPushToken(&app));
}

test "a device that posts but holds no fire date refuses only schedule" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{
            .notification = .mock(.{ .schedule_available = false, .status = .granted }),
            .clock = .mock(.{ .millis = 1_700_000_000_000 }),
        },
    });
    defer app.deinit();

    // The Linux desktop and the web: posting works, and nothing outlives
    // the process to fire a date later. Stated rather than faked with a
    // timer nokre would have to own.
    try std.testing.expect(notification.available(&app));
    try std.testing.expect(!notification.scheduleAvailable(&app));
    try notification.post(&app, ok);
    try std.testing.expectError(
        error.Unavailable,
        notification.schedule(&app, ok, clock.now(&app) + 60_000),
    );
    // The argument gate still runs first, so a malformed payload reports
    // what is wrong with it rather than what is missing from the device.
    try std.testing.expectError(
        error.EmptyTitle,
        notification.schedule(&app, .{ .id = "n.1", .title = "" }, clock.now(&app) + 60_000),
    );
    try std.testing.expectEqual(@as(usize, 1), app.services.notification.entries().len);
}

test "a token is refused before the user has granted anything" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .notification = .mock(.{}) },
    });
    defer app.deinit();
    try std.testing.expectError(error.NotAuthorized, notification.requestPushToken(&app));
    app.services.notification.grant();
    try notification.requestPushToken(&app);
    try std.testing.expectEqual(notification.Entry.push_request, app.services.notification.entries()[0]);
}

// ---- schedule: the fire date is the OS's, and the past is refused ----

test "schedule records the instant; a past or present one is refused" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{
            .notification = .mock(.{ .status = .granted }),
            .clock = .mock(.{ .millis = 1_700_000_000_000 }),
        },
    });
    defer app.deinit();

    const now = clock.now(&app);
    try notification.schedule(&app, ok, now + 60_000);
    // The same instant is not the future: iOS rejects a non-positive
    // interval outright, so the refusal is nokre's everywhere.
    try std.testing.expectError(error.FireDateInPast, notification.schedule(&app, ok, now));
    try std.testing.expectError(error.FireDateInPast, notification.schedule(&app, ok, now - 1));

    const entries = app.services.notification.entries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(now + 60_000, entries[0].posted.at_millis);
    // A device correcting its clock backwards can strand a fire date in
    // the past, which is the app's to notice — the service reports the
    // refusal rather than firing something the user did not ask for now.
    app.services.clock.advance(120_000);
    try std.testing.expectError(error.FireDateInPast, notification.schedule(&app, ok, now + 60_000));
}

test "post and schedule are one journal, told apart by at_millis" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();

    try notification.post(&app, .{ .id = "now.1", .title = "Now" });
    try notification.schedule(&app, .{ .id = "later.1", .title = "Later" }, clock.now(&app) + 1000);

    const entries = app.services.notification.entries();
    try std.testing.expectEqual(@as(i64, 0), entries[0].posted.at_millis);
    try std.testing.expect(entries[1].posted.at_millis != 0);
}

// ---- the journal: what the app asked for, in order, with owned bytes ----

test "the journal keeps every field, in request order" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();

    try notification.authorize(&app);
    try notification.post(&app, .{
        .id = "msg.42",
        .title = "Two new messages",
        .body = "from Dariush",
        .route = "thread~42",
        .important = true,
    });
    try notification.cancel(&app, "msg.42");

    const entries = app.services.notification.entries();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqual(notification.Entry.authorize, entries[0]);
    const posted = entries[1].posted;
    try std.testing.expectEqualStrings("msg.42", posted.id);
    try std.testing.expectEqualStrings("Two new messages", posted.title);
    try std.testing.expectEqualStrings("from Dariush", posted.body);
    try std.testing.expectEqualStrings("thread~42", posted.route);
    try std.testing.expect(posted.important);
    try std.testing.expectEqualStrings("msg.42", entries[2].cancel);
    try std.testing.expect(app.services.notification.askedForAuthorization());
}

test "cancel is idempotent and needs no prior post, but still checks the id" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();

    // Never posted: "already gone" is the state the caller asked for.
    try notification.cancel(&app, "never.posted");
    try notification.cancel(&app, "never.posted");
    try std.testing.expectError(error.InvalidId, notification.cancel(&app, "Nope"));
    try std.testing.expectEqual(@as(usize, 2), app.services.notification.entries().len);
}

// ---- the one lane: taps, tokens, and the authorization event ----

const Recorder = struct {
    opened: u32 = 0,
    arrived: u32 = 0,
    tokens: u32 = 0,
    authorized: u32 = 0,
    last_id: [64]u8 = undefined,
    last_id_len: usize = 0,
    last_route: [64]u8 = undefined,
    last_route_len: usize = 0,
    last_status: notification.Status = .not_determined,

    fn onEvent(ctx: ?*anyopaque, event: notification.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .authorized => |s| {
                self.authorized += 1;
                self.last_status = s;
            },
            .opened => |o| {
                self.opened += 1;
                @memcpy(self.last_id[0..o.id.len], o.id);
                self.last_id_len = o.id.len;
                @memcpy(self.last_route[0..o.route.len], o.route);
                self.last_route_len = o.route.len;
            },
            .received => |p| {
                self.arrived += 1;
                @memcpy(self.last_id[0..p.id.len], p.id);
                self.last_id_len = p.id.len;
                @memcpy(self.last_route[0..p.route.len], p.route);
                self.last_route_len = p.route.len;
            },
            .push_token => self.tokens += 1,
        }
    }

    fn id(self: *const Recorder) []const u8 {
        return self.last_id[0..self.last_id_len];
    }

    fn route(self: *const Recorder) []const u8 {
        return self.last_route[0..self.last_route_len];
    }
};

test "one handler carries taps, tokens, and the authorization answer" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    notification.setHandler(&app, &rec, Recorder.onEvent);

    app.services.notification.open(.{ .id = "msg.42", .route = "thread~42" });
    app.services.notification.deliverToken("a1b2c3");
    app.services.notification.deny();

    try std.testing.expectEqual(@as(u32, 1), rec.opened);
    try std.testing.expectEqualStrings("msg.42", rec.id());
    try std.testing.expectEqualStrings("thread~42", rec.route());
    try std.testing.expectEqual(@as(u32, 1), rec.tokens);
    try std.testing.expectEqual(@as(u32, 1), rec.authorized);
    try std.testing.expectEqual(notification.Status.denied, rec.last_status);
}

test "a foreground arrival is its own event, never a tap" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    notification.setHandler(&app, &rec, Recorder.onEvent);

    // The reminder fires while the app is on screen. The OS draws no
    // banner over the app, so this event is the whole delivery — and it
    // must not be reported as the user having chosen to open it.
    app.services.notification.arrive(.{ .id = "remind.1", .route = "note~7" });
    try std.testing.expectEqual(@as(u32, 1), rec.arrived);
    try std.testing.expectEqual(@as(u32, 0), rec.opened);
    try std.testing.expectEqualStrings("remind.1", rec.id());
    try std.testing.expectEqualStrings("note~7", rec.route());

    app.services.notification.open(.{ .id = "remind.1", .route = "note~7" });
    try std.testing.expectEqual(@as(u32, 1), rec.arrived);
    try std.testing.expectEqual(@as(u32, 1), rec.opened);
}

test "an event before setHandler reaches nothing, and the status still moves" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .notification = .mock(.{}) },
    });
    defer app.deinit();

    try std.testing.expect(!app.services.notification.hasHandler());
    // The user granting before the app wired anything: the cache is the
    // OS's answer, not the handler's, so `build` reads it either way.
    app.services.notification.grant();
    try std.testing.expectEqual(notification.Status.granted, notification.status(&app));

    var rec: Recorder = .{};
    notification.setHandler(&app, &rec, Recorder.onEvent);
    try std.testing.expect(app.services.notification.hasHandler());
    try std.testing.expectEqual(@as(u32, 0), rec.authorized);
}

test "registering again replaces the handler" {
    var app = try grantedApp(std.testing.allocator);
    defer app.deinit();

    var first: Recorder = .{};
    var second: Recorder = .{};
    notification.setHandler(&app, &first, Recorder.onEvent);
    notification.setHandler(&app, &second, Recorder.onEvent);
    app.services.notification.open(.{ .id = "n.1", .route = "" });

    try std.testing.expectEqual(@as(u32, 0), first.opened);
    try std.testing.expectEqual(@as(u32, 1), second.opened);
}

// ---- two apps in one process stay disjoint (the injection rule) ----

test "each app carries its own notification centre" {
    var a = try grantedApp(std.testing.allocator);
    defer a.deinit();
    var b = try grantedApp(std.testing.allocator);
    defer b.deinit();

    try notification.post(&a, ok);
    try std.testing.expectEqual(@as(usize, 1), a.services.notification.entries().len);
    try std.testing.expectEqual(@as(usize, 0), b.services.notification.entries().len);

    a.services.notification.deny();
    try std.testing.expectEqual(notification.Status.denied, notification.status(&a));
    try std.testing.expectEqual(notification.Status.granted, notification.status(&b));
}
