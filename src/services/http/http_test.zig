//! http service tests: the request contract driven through the per-app
//! mock — park, inspect, answer — with delivery under explicit test
//! control, the workers bargain applied to the network.
//! docs/internals/http.md is the contract held here.

const std = @import("std");
const http = @import("http.zig");
const app_mod = @import("../../core/app.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;

const Sink = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayList(u8) = .empty,
    kept: ?[]u8 = null,

    fn deinit(self: *Sink) void {
        self.log.deinit(self.gpa);
        if (self.kept) |b| self.gpa.free(b);
    }

    fn append(self: *Sink, comptime fmt: []const u8, args: anytype) void {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.log.appendSlice(self.gpa, s) catch {};
    }

    fn onResult(ctx: ?*anyopaque, result: http.Result) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .response => |r| self.append("{d} \"{s}\" h{d};", .{ r.status, r.body.view(), r.headers.len }),
            .failure => |f| self.append("failure {s};", .{f.name}),
        }
    }

    /// A callback that keeps the body past the call — the Bytes.take
    /// contract.
    fn onResultTake(ctx: ?*anyopaque, result: http.Result) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .response => |r| self.kept = r.body.take(),
            .failure => {},
        }
    }
};

fn testApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{ .viewport = .{ .w = 320, .h = 240 }, .services = .mocks() });
}

test "a request parks in the app's mock until the test answers it; slices were copied" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    // Mutable buffers prove request() copies: the caller scribbles
    // over them afterwards and the parked request must not notice.
    var url_buf = "https://example.test/data".*;
    var body_buf = "payload".*;
    _ = try http.request(.{
        .app = &app,
        .url = &url_buf,
        .method = .POST,
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
        .body = &body_buf,
        .ctx = &sink,
        .on_result = Sink.onResult,
    });
    @memset(&url_buf, 'x');
    @memset(&body_buf, 'x');

    const mock = app.services.http;
    try std.testing.expectEqual(1, mock.pendingCount());
    const p = mock.pendingAt(0);
    try std.testing.expectEqual(http.Method.POST, p.method);
    try std.testing.expectEqualStrings("https://example.test/data", p.url);
    try std.testing.expectEqualStrings("payload", p.body);
    try std.testing.expectEqual(1, p.headers.len);
    try std.testing.expectEqualStrings("accept", p.headers[0].name);
    try std.testing.expectEqualStrings("application/json", p.headers[0].value);

    // Nothing lands before the pump — delivery is the test's move.
    try mock.fulfill(.{ .status = 201, .body = "made", .headers = &.{
        .{ .name = "content-type", .value = "text/plain" },
    } });
    try std.testing.expectEqualStrings("", sink.log.items);
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("201 \"made\" h1;", sink.log.items);
    try std.testing.expectEqual(0, mock.pendingCount());
}

test "failure is a value, not an exception" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://down.test/", .ctx = &sink, .on_result = Sink.onResult });
    try app.services.http.fail("ConnectionRefused");
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("failure ConnectionRefused;", sink.log.items);
}

test "cancel: the callback never runs, and the handle is spent" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const handle = try http.request(.{ .app = &app, .url = "https://slow.test/", .ctx = &sink, .on_result = Sink.onResult });
    handle.cancel();
    try std.testing.expectEqual(0, app.services.http.pendingCount());
    try std.testing.expectError(error.NoPendingRequest, app.services.http.fulfill(.{}));
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("", sink.log.items);
    handle.cancel(); // idempotent: a spent handle is a no-op
}

test "answers deliver oldest-first, in order" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://a.test/", .ctx = &sink, .on_result = Sink.onResult });
    _ = try http.request(.{ .app = &app, .url = "https://b.test/", .ctx = &sink, .on_result = Sink.onResult });
    const mock = app.services.http;
    try std.testing.expectEqualStrings("https://a.test/", mock.pendingAt(0).url);
    try std.testing.expectEqualStrings("https://b.test/", mock.pendingAt(1).url);
    try mock.fulfill(.{ .status = 200, .body = "a" });
    try mock.fulfill(.{ .status = 404, .body = "b" });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("200 \"a\" h0;404 \"b\" h0;", sink.log.items);
}

test "completion order is the test's: fulfillAt answers out of order" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    // The stale-response race, written down: the request issued first
    // finishes last (guarantee 2 in docs/internals/http.md).
    _ = try http.request(.{ .app = &app, .url = "https://slow.test/", .ctx = &sink, .on_result = Sink.onResult });
    _ = try http.request(.{ .app = &app, .url = "https://fast.test/", .ctx = &sink, .on_result = Sink.onResult });
    const mock = app.services.http;
    try mock.fulfillAt(1, .{ .status = 200, .body = "fast" });
    try mock.failAt(0, "ConnectionTimedOut");
    try std.testing.expectError(error.NoPendingRequest, mock.fulfillAt(0, .{}));
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("200 \"fast\" h0;failure ConnectionTimedOut;", sink.log.items);
}

test "max_body holds against the canned network too" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://big.test/", .max_body = 4, .ctx = &sink, .on_result = Sink.onResult });
    try app.services.http.fulfill(.{ .body = "12345" });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("failure BodyTooLarge;", sink.log.items);
}

test "the body is a Bytes: take keeps the buffer past the call" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://blob.test/", .ctx = &sink, .on_result = Sink.onResultTake });
    try app.services.http.fulfill(.{ .body = "0123456789" });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("0123456789", sink.kept.?);
}

test "the journal survives the answers: request order, past fulfill/fail/cancel" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://api.test/save", .method = .POST, .body = "x", .ctx = &sink, .on_result = Sink.onResult });
    _ = try http.request(.{ .app = &app, .url = "https://api.test/list", .ctx = &sink, .on_result = Sink.onResult });
    const handle = try http.request(.{ .app = &app, .url = "https://api.test/aborted", .ctx = &sink, .on_result = Sink.onResult });

    // Empty the pending list three different ways; the journal must
    // not notice — it records asks, not outcomes.
    handle.cancel();
    try app.services.http.fulfill(.{ .status = 201 });
    try app.services.http.fail("ConnectionRefused");
    app.runtime.pumpAll();
    try std.testing.expectEqual(0, app.services.http.pendingCount());

    const ops = app.services.http.journal();
    try std.testing.expectEqual(3, ops.len);
    try std.testing.expectEqual(http.Method.POST, ops[0].method);
    try std.testing.expectEqualStrings("https://api.test/save", ops[0].url);
    try std.testing.expectEqual(http.Method.GET, ops[1].method);
    try std.testing.expectEqualStrings("https://api.test/list", ops[1].url);
    try std.testing.expectEqualStrings("https://api.test/aborted", ops[2].url);

    // The per-phase reset: the next action's requests stand alone.
    app.services.http.clearJournal();
    try std.testing.expectEqual(0, app.services.http.journal().len);
    _ = try http.request(.{ .app = &app, .url = "https://api.test/next", .ctx = &sink, .on_result = Sink.onResult });
    try std.testing.expectEqual(1, app.services.http.journal().len);
}

test "the transport deadline is a contract constant, and the mock ignores it" {
    // 30 seconds is contract (docs/services.md): transports enforce
    // it, the mock does not — a parked request stays parked, which is
    // the testing point. Nothing here can wait; there is nothing to
    // wait for.
    try std.testing.expectEqual(30, http.deadline_seconds);
}

test "a handler from construction is the fake server, no harness required" {
    const gpa = std.testing.allocator;
    const Serve = struct {
        fn serve(_: ?*anyopaque, req: http.PendingRequest) ?http.Outcome {
            if (std.mem.endsWith(u8, req.url, "/greet")) return .{ .respond = .{ .status = 200, .body = "hi" } };
            return .{ .fail = "FetchFailed" };
        }
    };
    var app = try App.init(gpa, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .http = .mock(.{ .handler = Serve.serve }) },
    });
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://api.test/greet", .ctx = &sink, .on_result = Sink.onResult });
    _ = try http.request(.{ .app = &app, .url = "https://api.test/other", .ctx = &sink, .on_result = Sink.onResult });
    try app.services.http.settle();
    try std.testing.expectEqualStrings("200 \"hi\" h0;failure FetchFailed;", sink.log.items);
}

test "two apps are two disjoint networks" {
    const gpa = std.testing.allocator;
    var a = try testApp(gpa);
    defer a.deinit();
    var b = try testApp(gpa);
    defer b.deinit();
    var sink_a: Sink = .{ .gpa = gpa };
    defer sink_a.deinit();
    var sink_b: Sink = .{ .gpa = gpa };
    defer sink_b.deinit();

    _ = try http.request(.{ .app = &a, .url = "https://a.test/", .ctx = &sink_a, .on_result = Sink.onResult });
    _ = try http.request(.{ .app = &b, .url = "https://b.test/", .ctx = &sink_b, .on_result = Sink.onResult });

    // Each mock sees exactly its own app's traffic — no stamping, no
    // filtering: the state is disjoint by construction.
    try std.testing.expectEqual(1, a.services.http.pendingCount());
    try std.testing.expectEqual(1, b.services.http.pendingCount());
    try std.testing.expectEqualStrings("https://a.test/", a.services.http.pendingAt(0).url);
    try std.testing.expectEqualStrings("https://b.test/", b.services.http.pendingAt(0).url);

    // Answering b's network delivers on b's runtime; a hears nothing.
    try b.services.http.fulfill(.{ .status = 200, .body = "b" });
    b.runtime.pumpAll();
    a.runtime.pumpAll();
    try std.testing.expectEqualStrings("", sink_a.log.items);
    try std.testing.expectEqualStrings("200 \"b\" h0;", sink_b.log.items);

    try a.services.http.fail("ConnectionRefused");
    a.runtime.pumpAll();
    try std.testing.expectEqualStrings("failure ConnectionRefused;", sink_a.log.items);

    // Disjoint journals too: each app's history is its own.
    try std.testing.expectEqual(1, a.services.http.journal().len);
    try std.testing.expectEqualStrings("https://a.test/", a.services.http.journal()[0].url);
    try std.testing.expectEqual(1, b.services.http.journal().len);
    try std.testing.expectEqualStrings("https://b.test/", b.services.http.journal()[0].url);
}

test "harness: fulfillHttp and failHttp land the result at the call" {
    const gpa = std.testing.allocator;
    const Ctx = struct {
        sink: Sink,
        fn build(_: ?*anyopaque, app: *App) !void {
            const root = app.tree.rootId();
            try app.tree.append(root, .{ .heading = .{ .content = "Fetch", .level = .h1 } });
        }
    };
    var ctx: Ctx = .{ .sink = .{ .gpa = gpa } };
    defer ctx.sink.deinit();

    var t = try harness_mod.Harness.init(gpa, .{ .w = 320, .h = 240 }, &ctx, Ctx.build);
    defer t.deinit();

    _ = try http.request(.{ .app = &t.app, .url = "https://one.test/", .ctx = &ctx.sink, .on_result = Sink.onResult });
    _ = try http.request(.{ .app = &t.app, .url = "https://two.test/", .ctx = &ctx.sink, .on_result = Sink.onResult });
    try t.fulfillHttp(.{ .status = 200, .body = "one" });
    try std.testing.expectEqualStrings("200 \"one\" h0;", ctx.sink.log.items);
    try t.failHttp("UnknownHostName");
    try std.testing.expectEqualStrings("200 \"one\" h0;failure UnknownHostName;", ctx.sink.log.items);

    // The harness reads the journal straight off the mock: both asks,
    // in request order, though nothing is parked anymore.
    try std.testing.expectEqual(2, t.httpJournal().len);
    try std.testing.expectEqualStrings("https://one.test/", t.httpJournal()[0].url);
    try std.testing.expectEqualStrings("https://two.test/", t.httpJournal()[1].url);
}

test "harness: onHttp is the fake server; settleHttp answers to quiescence" {
    const gpa = std.testing.allocator;
    const Ctx = struct {
        sink: Sink,
        app: *App = undefined,
        chained: bool = false,

        fn build(_: ?*anyopaque, app: *App) !void {
            const root = app.tree.rootId();
            try app.tree.append(root, .{ .heading = .{ .content = "Fetch", .level = .h1 } });
        }

        // First response in hand, the app asks a follow-up question —
        // settleHttp must see the new request within the same settle.
        fn onChain(ctx_: ?*anyopaque, result: http.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_.?));
            Sink.onResult(&self.sink, result);
            if (!self.chained) {
                self.chained = true;
                _ = http.request(.{ .app = self.app, .url = "https://api.test/second", .ctx = self, .on_result = onChain }) catch {};
            }
        }

        fn serve(_: ?*anyopaque, req: http.PendingRequest) ?harness_mod.HttpOutcome {
            if (std.mem.endsWith(u8, req.url, "/first")) return .{ .respond = .{ .status = 200, .body = "one" } };
            if (std.mem.endsWith(u8, req.url, "/second")) return .{ .respond = .{ .status = 200, .body = "two" } };
            if (std.mem.endsWith(u8, req.url, "/offline")) return .{ .fail = "FetchFailed" };
            return null; // declined: stays parked, the test's to answer by hand
        }
    };
    var ctx: Ctx = .{ .sink = .{ .gpa = gpa } };
    defer ctx.sink.deinit();

    var t = try harness_mod.Harness.init(gpa, .{ .w = 320, .h = 240 }, &ctx, Ctx.build);
    defer t.deinit();
    ctx.app = &t.app;

    {
        // Settling without a handler is refused loudly, not a no-op.
        harness_mod.diag.quiet = true;
        defer harness_mod.diag.quiet = false;
        try std.testing.expectError(error.NoHttpHandler, t.settleHttp());
    }
    t.onHttp(&ctx, Ctx.serve);

    _ = try http.request(.{ .app = &t.app, .url = "https://api.test/first", .ctx = &ctx, .on_result = Ctx.onChain });
    _ = try http.request(.{ .app = &t.app, .url = "https://api.test/offline", .ctx = &ctx.sink, .on_result = Sink.onResult });
    _ = try http.request(.{ .app = &t.app, .url = "https://api.test/manual", .ctx = &ctx.sink, .on_result = Sink.onResult });

    try t.settleHttp();
    try std.testing.expectEqualStrings("200 \"one\" h0;failure FetchFailed;200 \"two\" h0;", ctx.sink.log.items);

    // Left parked: the declined request — which the test now answers
    // by hand.
    try std.testing.expectEqual(1, t.app.services.http.pendingCount());
    try std.testing.expectEqualStrings("https://api.test/manual", t.app.services.http.pendingAt(0).url);
    try t.fulfillHttpAt(0, .{ .status = 204 });
    try std.testing.expectEqualStrings("200 \"one\" h0;failure FetchFailed;200 \"two\" h0;204 \"\" h0;", ctx.sink.log.items);
    try std.testing.expectEqual(0, t.app.services.http.pendingCount());
}
