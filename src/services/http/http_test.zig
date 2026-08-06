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

    fn onResult(ctx: ?*anyopaque, _: u64, result: http.Result) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .response => |r| self.append("{d} \"{s}\" h{d};", .{ r.status, r.body.view(), r.headers.len }),
            .failure => |f| self.append("failure {s};", .{f.name}),
        }
    }

    /// onResult with the tag in the log — for the tests where *which*
    /// request an answer belongs to is the subject.
    fn onResultTagged(ctx: ?*anyopaque, tag: u64, result: http.Result) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .response => |r| self.append("t{d} {d};", .{ tag, r.status }),
            .failure => |f| self.append("t{d} failure {s};", .{ tag, f.name }),
        }
    }

    /// A callback that keeps the body past the call — the Bytes.take
    /// contract.
    fn onResultTake(ctx: ?*anyopaque, _: u64, result: http.Result) void {
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

test "the tag rides the request and is echoed untouched, whatever the answer order" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    // Two tags no index arithmetic would produce, so an echo of the
    // wrong request's tag cannot pass by coincidence.
    _ = try http.request(.{ .app = &app, .url = "https://a.test/", .tag = 7001, .ctx = &sink, .on_result = Sink.onResultTagged });
    _ = try http.request(.{ .app = &app, .url = "https://b.test/", .tag = 42, .ctx = &sink, .on_result = Sink.onResultTagged });

    // The mock records the tag on the parked request and in the
    // journal — the fake-server and these-requests-in-this-order
    // surfaces both know which ask is which.
    const mock = app.services.http;
    try std.testing.expectEqual(7001, mock.pendingAt(0).tag);
    try std.testing.expectEqual(42, mock.pendingAt(1).tag);
    try std.testing.expectEqual(7001, mock.journal()[0].tag);
    try std.testing.expectEqual(42, mock.journal()[1].tag);

    // Answered out of order: the tag is the request's, not the
    // delivery position's.
    try mock.fulfillAt(1, .{ .status = 200 });
    try mock.fulfillAt(0, .{ .status = 201 });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("t42 200;t7001 201;", sink.log.items);
}

test "the tag is echoed on failure too — transport names and BodyTooLarge alike" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://down.test/", .tag = 9, .ctx = &sink, .on_result = Sink.onResultTagged });
    _ = try http.request(.{ .app = &app, .url = "https://big.test/", .max_body = 4, .tag = 10, .ctx = &sink, .on_result = Sink.onResultTagged });
    try app.services.http.fail("ConnectionRefused");
    // The oversized canned body fails inside the mock's own max_body
    // enforcement — a failure the fulfiller did not spell, and the tag
    // still rides it.
    try app.services.http.fulfill(.{ .body = "12345" });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("t9 failure ConnectionRefused;t10 failure BodyTooLarge;", sink.log.items);
}

test "the default tag is 0 — a caller that never asked for one is undisturbed" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    _ = try http.request(.{ .app = &app, .url = "https://plain.test/", .ctx = &sink, .on_result = Sink.onResultTagged });
    try std.testing.expectEqual(0, app.services.http.journal()[0].tag);
    try app.services.http.fulfill(.{ .status = 200 });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("t0 200;", sink.log.items);
}

test "harness: fulfillHttp and failHttp land the result at the call" {
    const gpa = std.testing.allocator;
    const Ctx = struct {
        sink: Sink,
        fn build(_: ?*anyopaque, app: *App) !void {
            try app.tree.setTitle("Fetch");
        }
    };
    var ctx: Ctx = .{ .sink = .{ .gpa = gpa } };
    defer ctx.sink.deinit();

    var t = try harness_mod.Harness.init(gpa, .{ .w = 320, .h = 240 }, .{ .ctx = &ctx, .build = Ctx.build });
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
            try app.tree.setTitle("Fetch");
        }

        // First response in hand, the app asks a follow-up question —
        // settleHttp must see the new request within the same settle.
        fn onChain(ctx_: ?*anyopaque, tag: u64, result: http.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_.?));
            Sink.onResult(&self.sink, tag, result);
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

    var t = try harness_mod.Harness.init(gpa, .{ .w = 320, .h = 240 }, .{ .ctx = &ctx, .build = Ctx.build });
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

test "harness: answering by path echoes each request's own tag, and the journal keeps it" {
    const gpa = std.testing.allocator;
    const Ctx = struct {
        sink: Sink,
        fn build(_: ?*anyopaque, app: *App) !void {
            try app.tree.setTitle("Fetch");
        }
    };
    var ctx: Ctx = .{ .sink = .{ .gpa = gpa } };
    defer ctx.sink.deinit();

    var t = try harness_mod.Harness.init(gpa, .{ .w = 320, .h = 240 }, .{ .ctx = &ctx, .build = Ctx.build });
    defer t.deinit();

    // The test addresses requests by path — issue order stays the
    // app's business — and each answer must land with the tag *its*
    // request carried, response and failure alike.
    _ = try http.request(.{ .app = &t.app, .url = "https://api.test/notes", .tag = 3, .ctx = &ctx.sink, .on_result = Sink.onResultTagged });
    _ = try http.request(.{ .app = &t.app, .url = "https://api.test/profile", .tag = 8, .ctx = &ctx.sink, .on_result = Sink.onResultTagged });
    try t.fulfillHttpPath("/profile", .{ .status = 200 });
    try t.failHttpPath("/notes", "ConnectionRefused");
    try std.testing.expectEqualStrings("t8 200;t3 failure ConnectionRefused;", ctx.sink.log.items);

    // The journal outlives the answers, tag included.
    try std.testing.expectEqual(2, t.httpJournal().len);
    try std.testing.expectEqual(3, t.httpJournal()[0].tag);
    try std.testing.expectEqual(8, t.httpJournal()[1].tag);
}

// ---- the observing side ----
// What the app *sent*, asserted by the same name the answering verbs
// use. Each verb here is tested twice: once for what it accepts, once
// for the words its refusal prints. An assertion whose failure says
// nothing actionable has only moved the debugging — the two-integer
// count these replace is exactly that bug, so the message is pinned
// like any other contract.

const diag = @import("../../testing/diag.zig");

/// A harness with three requests parked, spanning what the expectation
/// fields exist for: a plain GET, a POST carrying a body and two
/// headers, and a third whose tail is nobody else's.
const Observed = struct {
    sink: Sink,
    t: harness_mod.Harness = undefined,

    fn build(_: ?*anyopaque, app: *App) !void {
        try app.tree.setTitle("Fetch");
    }

    fn init(self: *Observed) !void {
        self.t = try harness_mod.Harness.init(self.sink.gpa, .{ .w = 320, .h = 240 }, .{ .ctx = self, .build = build });
        _ = try http.request(.{ .app = &self.t.app, .url = "https://api.test/api/notes", .ctx = &self.sink, .on_result = Sink.onResult });
        _ = try http.request(.{
            .app = &self.t.app,
            .url = "https://api.test/api/notes/n-1/share",
            .method = .POST,
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "X-PoW-Nonce", .value = "8f31" },
            },
            .body = "{\"to\":\"bob@acme.com\",\"note\":\"n-1\"}",
            .ctx = &self.sink,
            .on_result = Sink.onResult,
        });
        _ = try http.request(.{ .app = &self.t.app, .url = "https://cdn.test/en/terms.json", .ctx = &self.sink, .on_result = Sink.onResult });
    }

    fn deinit(self: *Observed) void {
        self.t.deinit();
        self.sink.deinit();
    }
};

const share_url = "https://api.test/api/notes/n-1/share";

test "harness: httpPending counts the queue, all of it or one path's share" {
    var o: Observed = .{ .sink = .{ .gpa = std.testing.allocator } };
    try o.init();
    defer o.deinit();

    try std.testing.expectEqual(3, o.t.httpPending(null));
    try std.testing.expectEqual(1, o.t.httpPending("/api/notes"));
    try std.testing.expectEqual(1, o.t.httpPending(".json"));
    try std.testing.expectEqual(0, o.t.httpPending("/api/circles"));

    // The count is the point of the path form: "asked once, not once
    // per attempt" is an assertion no presence check can make.
    _ = try http.request(.{ .app = &o.t.app, .url = "https://api.test/api/notes", .ctx = &o.sink, .on_result = Sink.onResult });
    try std.testing.expectEqual(2, o.t.httpPending("/api/notes"));

    // The count follows the queue, not the journal: an answered ask is
    // no longer in flight, though it is still on the record.
    try o.t.fulfillHttpPath("/api/notes", .{ .status = 200 });
    try std.testing.expectEqual(3, o.t.httpPending(null));
    try std.testing.expectEqual(1, o.t.httpPending("/api/notes"));
    try std.testing.expectEqual(4, o.t.httpJournal().len);
}

test "harness: expectNoPendingHttp names every request instead of a count" {
    var o: Observed = .{ .sink = .{ .gpa = std.testing.allocator } };
    try o.init();
    defer o.deinit();

    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try std.testing.expectError(error.PendingHttp, o.t.expectNoPendingHttp());
    try std.testing.expectEqualStrings(
        \\expected nothing in flight, but these are parked:
        \\  GET https://api.test/api/notes
        \\  POST https://api.test/api/notes/n-1/share
        \\  GET https://cdn.test/en/terms.json
        \\
    , said.text());
    said.stop();

    // Answered to the last one, it passes — the shape of a test that
    // meant to serve everything it asked.
    try o.t.fulfillHttpPath("/api/notes", .{ .status = 200 });
    try o.t.fulfillHttpPath("/share", .{ .status = 204 });
    try o.t.failHttpPath("/terms.json", "FetchFailed");
    try o.t.expectNoPendingHttp();
}

test "harness: expectRequest reads method, body, and headers off the named ask" {
    var o: Observed = .{ .sink = .{ .gpa = std.testing.allocator } };
    try o.init();
    defer o.deinit();

    // The empty expectation is the whole assertion "this was asked".
    try o.t.expectRequest("/api/notes", .{});

    // The whole URL is a suffix of itself, so the locator doubles as
    // the address assertion.
    try o.t.expectRequest(share_url, .{
        .method = .POST,
        .body = "{\"to\":\"bob@acme.com\",\"note\":\"n-1\"}",
        .body_contains = &.{ "\"to\":\"bob@acme.com\"", "\"note\":\"n-1\"" },
        .body_excludes = &.{"\"from\""},
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .headers_present = &.{"X-PoW-Nonce"},
        .headers_absent = &.{"Authorization"},
    });

    // Reading it changed nothing: the app is still waiting, and the
    // answer still lands.
    try std.testing.expectEqual(3, o.t.httpPending(null));
    try o.t.fulfillHttpPath("/share", .{ .status = 204 });
    try std.testing.expectEqualStrings("204 \"\" h0;", o.sink.log.items);
}

test "harness: every expectRequest refusal names the request and what it carried" {
    var o: Observed = .{ .sink = .{ .gpa = std.testing.allocator } };
    try o.init();
    defer o.deinit();

    const cases = [_]struct { expect: harness_mod.RequestExpectation, want: []const u8 }{
        .{
            .expect = .{ .method = .PUT },
            .want = "POST " ++ share_url ++ ": expected method PUT\n",
        },
        .{
            .expect = .{ .body = "{}" },
            .want = "POST " ++ share_url ++ ": body mismatch\n" ++
                "---- expected ----\n{}\n" ++
                "---- actual ----\n{\"to\":\"bob@acme.com\",\"note\":\"n-1\"}\n" ++
                "------------------\n",
        },
        .{
            .expect = .{ .body_contains = &.{"\"cc\""} },
            .want = "POST " ++ share_url ++ ": expected the body to contain \"\"cc\"\", " ++
                "but it is {\"to\":\"bob@acme.com\",\"note\":\"n-1\"}\n",
        },
        .{
            .expect = .{ .body_excludes = &.{"bob@acme.com"} },
            .want = "POST " ++ share_url ++ ": expected the body not to mention \"bob@acme.com\", " ++
                "but it is {\"to\":\"bob@acme.com\",\"note\":\"n-1\"}\n",
        },
        .{
            .expect = .{ .headers = &.{.{ .name = "Content-Type", .value = "text/plain" }} },
            .want = "POST " ++ share_url ++ ": expected \"Content-Type: text/plain\", got \"application/json\"\n",
        },
        .{
            .expect = .{ .headers = &.{.{ .name = "Accept", .value = "application/json" }} },
            .want = "POST " ++ share_url ++ ": expected \"Accept: application/json\", but no such header rode along" ++
                "; it carries:\n  Content-Type\n  X-PoW-Nonce\n",
        },
        .{
            .expect = .{ .headers_present = &.{"X-PoW-Timestamp"} },
            .want = "POST " ++ share_url ++ ": expected a \"X-PoW-Timestamp\" header; it carries:\n" ++
                "  Content-Type\n  X-PoW-Nonce\n",
        },
        .{
            .expect = .{ .headers_absent = &.{"X-PoW-Nonce"} },
            .want = "POST " ++ share_url ++ ": expected no \"X-PoW-Nonce\" header, but it carries \"8f31\"\n",
        },
    };
    for (cases) |case| {
        var said: diag.Capture = .{};
        said.start();
        defer said.stop();
        try std.testing.expectError(error.RequestMismatch, o.t.expectRequest("/share", case.expect));
        try std.testing.expectEqualStrings(case.want, said.text());
    }

    // A path nobody asked for is the queries' loud miss: what was
    // actually in flight, never a bare "false".
    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try std.testing.expectError(error.NoSuchRequest, o.t.expectRequest("/api/circles", .{}));
    try std.testing.expectEqualStrings(
        \\no parked request ending in "/api/circles"; in flight:
        \\  GET https://api.test/api/notes
        \\  POST https://api.test/api/notes/n-1/share
        \\  GET https://cdn.test/en/terms.json
        \\
    , said.text());
}

test "harness: a miss with an empty queue says the queue is empty" {
    var o: Observed = .{ .sink = .{ .gpa = std.testing.allocator } };
    try o.init();
    defer o.deinit();

    try o.t.fulfillHttpPath("/api/notes", .{ .status = 200 });
    try o.t.fulfillHttpPath("/share", .{ .status = 204 });
    try o.t.fulfillHttpPath("/terms.json", .{ .status = 200 });

    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try std.testing.expectError(error.NoSuchRequest, o.t.expectRequest("/api/notes", .{}));
    try std.testing.expectEqualStrings(
        \\no parked request ending in "/api/notes"; in flight:
        \\  (nothing is parked)
        \\
    , said.text());
}

test "harness: expectNoRequest passes on silence and prints the calls that broke it" {
    var o: Observed = .{ .sink = .{ .gpa = std.testing.allocator } };
    try o.init();
    defer o.deinit();

    try o.t.expectNoRequest("/api/circles");

    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try std.testing.expectError(error.UnexpectedRequest, o.t.expectNoRequest(".json"));
    try std.testing.expectEqualStrings(
        \\expected nothing parked for ".json", but these are:
        \\  GET https://cdn.test/en/terms.json
        \\
    , said.text());
}

test "harness: httpRequest hands the request over for what no field can spell" {
    var o: Observed = .{ .sink = .{ .gpa = std.testing.allocator } };
    try o.init();
    defer o.deinit();

    // The free-form case: a value *derived* from the body rather than
    // compared to it, and a header read as something other than text.
    const req = try o.t.httpRequest("/share");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(req.body, &digest, .{});
    try std.testing.expectEqual(
        0x8f31,
        try std.fmt.parseInt(u32, req.headerValue("X-PoW-Nonce").?, 16),
    );

    // It peeked: the request is still the app's, still answerable.
    try std.testing.expectEqual(3, o.t.httpPending(null));
    try o.t.expectRequest("/share", .{ .method = .POST });

    // Its miss is the same refusal, in the same words.
    var said: diag.Capture = .{};
    said.start();
    defer said.stop();
    try std.testing.expectError(error.NoSuchRequest, o.t.httpRequest("/api/circles"));
    try std.testing.expect(std.mem.startsWith(u8, said.text(), "no parked request ending in \"/api/circles\""));
}
