//! deep_link service tests: the consumer surface driven through the
//! per-app mock — the only link source under `zig test`, so what holds
//! here is the whole contract. One lane: deliver is the launch URL as
//! the first call, then any runtime link, routed to the registered
//! handler on this thread. docs/services.md is the contract held here.

const std = @import("std");
const deep_link = @import("deep_link.zig");
const app_mod = @import("../../core/app.zig");
const router_mod = @import("../../core/router.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;
const Harness = harness_mod.Harness;

fn testApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{ .viewport = .{ .w = 320, .h = 240 }, .services = .mocks() });
}

// ---- fragment: the web deep link, and a helper on every platform ----

test "fragment: the bytes after the first #, or null when there is none" {
    try std.testing.expectEqual(@as(?[]const u8, null), deep_link.fragment("https://example.com/notes"));
    try std.testing.expectEqualStrings("/note/42", deep_link.fragment("https://example.com/#/note/42").?);
    // An empty fragment ("…#") is present and empty — distinct from null,
    // the way secure_store separates an empty value from absence.
    try std.testing.expectEqualStrings("", deep_link.fragment("https://example.com/#").?);
    // Only the first # splits; later ones live in the fragment.
    try std.testing.expectEqualStrings("a#b", deep_link.fragment("x#a#b").?);
    try std.testing.expectEqualStrings("tab=1", deep_link.fragment("#tab=1").?);
}

// ---- the mock: journal, routing, and the pre-handler window ----

const Recorder = struct {
    count: u32 = 0,
    last: [128]u8 = undefined,
    last_len: usize = 0,

    fn onLink(ctx: ?*anyopaque, url: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        @memcpy(self.last[0..url.len], url);
        self.last_len = url.len;
    }

    fn lastUrl(self: *const Recorder) []const u8 {
        return self.last[0..self.last_len];
    }
};

test "deliver journals every URL in order and routes to the handler" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    deep_link.setHandler(&app, &rec, Recorder.onLink);

    app.services.deep_link.deliver("https://example.com/#/a");
    app.services.deep_link.deliver("https://example.com/#/b");

    try std.testing.expectEqual(@as(u32, 2), rec.count);
    try std.testing.expectEqualStrings("https://example.com/#/b", rec.lastUrl());

    const seen = app.services.deep_link.received();
    try std.testing.expectEqual(@as(usize, 2), seen.len);
    try std.testing.expectEqualStrings("https://example.com/#/a", seen[0]);
    try std.testing.expectEqualStrings("https://example.com/#/b", seen[1]);
}

test "a URL delivered before a handler is journaled but unhandled" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    // The launch URL arrives before the app has wired anything to route
    // it: it is not lost — it is journaled — but nothing runs.
    try std.testing.expect(!app.services.deep_link.hasHandler());
    app.services.deep_link.deliver("https://example.com/#/launch");
    try std.testing.expectEqual(@as(usize, 1), app.services.deep_link.received().len);

    var rec: Recorder = .{};
    deep_link.setHandler(&app, &rec, Recorder.onLink);
    try std.testing.expect(app.services.deep_link.hasHandler());
    // The already-delivered URL does not replay; only URLs from here on
    // reach the handler.
    try std.testing.expectEqual(@as(u32, 0), rec.count);
    app.services.deep_link.deliver("https://example.com/#/after");
    try std.testing.expectEqual(@as(u32, 1), rec.count);
    try std.testing.expectEqualStrings("https://example.com/#/after", rec.lastUrl());
}

test "setHandler replaces the previous handler" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var first: Recorder = .{};
    var second: Recorder = .{};
    deep_link.setHandler(&app, &first, Recorder.onLink);
    deep_link.setHandler(&app, &second, Recorder.onLink);
    app.services.deep_link.deliver("https://example.com/#/x");
    try std.testing.expectEqual(@as(u32, 0), first.count);
    try std.testing.expectEqual(@as(u32, 1), second.count);
}

test "two apps keep disjoint link state by construction" {
    var a = try testApp(std.testing.allocator);
    defer a.deinit();
    var b = try testApp(std.testing.allocator);
    defer b.deinit();

    var ra: Recorder = .{};
    var rb: Recorder = .{};
    deep_link.setHandler(&a, &ra, Recorder.onLink);
    deep_link.setHandler(&b, &rb, Recorder.onLink);

    a.services.deep_link.deliver("https://a.example/#/1");
    a.services.deep_link.deliver("https://a.example/#/2");
    b.services.deep_link.deliver("https://b.example/#/1");

    try std.testing.expectEqual(@as(u32, 2), ra.count);
    try std.testing.expectEqual(@as(u32, 1), rb.count);
    try std.testing.expectEqual(@as(usize, 2), a.services.deep_link.received().len);
    try std.testing.expectEqual(@as(usize, 1), b.services.deep_link.received().len);
    try std.testing.expectEqualStrings("https://b.example/#/1", b.services.deep_link.received()[0]);
}

// ---- through the harness: a link routes, asserted via a11y ----

const RouteCtx = struct {
    app: ?*App = null,

    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home" } });
        // Register once at boot, inside build (docs/services.md). The app
        // pointer routing needs is filled after init, when its address is
        // stable — the launch URL is delivered no earlier than that.
        deep_link.setHandler(app, ctx, onLink);
    }

    fn onLink(ctx: ?*anyopaque, url: []const u8) void {
        const self: *RouteCtx = @ptrCast(@alignCast(ctx.?));
        const app = self.app orelse return;
        const route = deep_link.fragment(url) orelse return;
        app.navigate(route) catch {};
    }
};

fn buildNote(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Note" } });
}

fn buildHome(ctx: ?*anyopaque, app: *App) anyerror!void {
    try RouteCtx.build(ctx, app);
}

test "harness: an inbound link routes the app" {
    var ctx: RouteCtx = .{};
    const routes = [_]router_mod.RouteDef{
        .{ .name = "home", .title = "Home", .build = buildHome },
        .{ .name = "note", .title = "Note", .build = buildNote },
    };
    var t = try Harness.initWithRoutes(std.testing.allocator, .{ .w = 320, .h = 480 }, &routes, &ctx, "home");
    defer t.deinit();
    // Now that init has returned, the app address is stable: wire it, the
    // way a real shell hands the booted *App to the routing state.
    ctx.app = &t.app;

    // The launch URL (or a runtime link): fragment "note" routes there.
    try t.deliverDeepLink("https://example.com/#note");
    try t.expectRoute("note");
    try std.testing.expectEqual(@as(usize, 1), t.deepLinksReceived().len);

    // A second link routes back — a runtime deep link mid-session.
    try t.deliverDeepLink("https://example.com/#home");
    try t.expectRoute("home");
}
