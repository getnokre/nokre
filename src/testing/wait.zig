//! Deadline-bounded waiting, for the driver tier only.
//!
//! Under the harness nothing ever waits: every mock settles at a verb
//! (`settleWorkers`, `settleHttp`, `fulfillHttp`), so a harness test
//! that polled would be rehearsing a race the mocks cannot produce.
//! A *driver* — an ordinary executable holding a real `App` against
//! real transports (docs/testing.md, "Driving an app outside
//! `zig test`") — has no settle verb, because a real server answers
//! when it answers. Its whole synchronization story is "pump until the
//! screen says what it came to say, or a deadline passes", and before
//! this module every driver hand-wrote that loop once per thing it
//! could wait for.
//!
//! nokre itself reads no clock and sleeps no thread here — that would
//! smuggle wall-clock nondeterminism into a library whose tests are
//! deterministic to the byte. The driver owns the real transports, so
//! the driver owns real time: it hands both reads and naps in as a
//! `Pacer`, and a test of this module hands in a fake one, which is
//! how a deadline failure is itself testable without waiting.

const std = @import("std");
const diag = @import("diag.zig");
const trace = @import("trace.zig");
const app_mod = @import("../core/app.zig");

const App = app_mod.App;

/// The driver's time, injected. `now_ms` is whatever clock the driver
/// already bounds its run with; `nap` yields between polls so the
/// transport threads this wait is waiting on get the core.
pub const Pacer = struct {
    ctx: ?*anyopaque = null,
    now_ms: *const fn (ctx: ?*anyopaque) i64,
    nap: *const fn (ctx: ?*anyopaque, ns: u64) void,
    /// How long a screen has to answer. The shipped drivers' figure: a
    /// leg there is a proof of work, a round trip and a rebuild.
    timeout_ms: i64 = 60_000,
    /// How long to yield between polls.
    poll_ns: u64 = 200 * std.time.ns_per_us,

    fn nowMs(self: Pacer) i64 {
        return self.now_ms(self.ctx);
    }

    fn rest(self: Pacer) void {
        self.nap(self.ctx, self.poll_ns);
    }
};

/// What a wait watches: asked once per pump, against the app as it
/// stands. Return true to end the wait.
pub const Predicate = *const fn (ctx: ?*anyopaque, app: *App) bool;

/// Pumps the delivery queue until `ready` holds or the pacer's deadline
/// passes. On timeout it prints what was waited for (`what`, the
/// caller's words) and the whole screen as it stands — the dump that
/// turns "waited 60000ms" into a diagnosis — then returns
/// `error.WaitTimeout`. The predicate runs after each pump, so a result
/// that is already on screen returns without a single nap.
pub fn waitUntil(app: *App, pacer: Pacer, what: []const u8, ctx: ?*anyopaque, ready: Predicate) error{WaitTimeout}!void {
    const deadline = pacer.nowMs() + pacer.timeout_ms;
    while (true) {
        _ = app.runtime.pump();
        if (ready(ctx, app)) return;
        if (pacer.nowMs() > deadline) {
            diag.print("waited {d}ms for {s}; the screen stands at:\n", .{ pacer.timeout_ms, what });
            dumpScreen(app);
            return error.WaitTimeout;
        }
        pacer.rest();
    }
}

/// The failure dump, printed through the diag gate: route, every
/// labeled element with the state a user would notice (working,
/// disabled, folded), the pending notices the snapshot cannot speak
/// for, then the laid-out tree in the trace format. Public because a
/// driver's own failure paths (a refused tap, say) owe the same
/// picture waitUntil prints.
pub fn dumpScreen(app: *App) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    writeScreen(app.gpa, &out, app) catch return;
    diag.print("{s}", .{out.items});
}

/// `dumpScreen`'s body, into a caller-owned list — the seam that makes
/// the dump assertable without capturing stderr.
pub fn writeScreen(gpa: std.mem.Allocator, out: *std.ArrayList(u8), app: *App) !void {
    app.performLayout();
    try out.print(gpa, "  on route \"{s}\"\n", .{app.router.current() orelse "(none)"});
    var it = app.tree.dfs();
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.label().len == 0) continue;
        const state: []const u8 = switch (el.*) {
            .button => |b| if (b.in_progress) " (working)" else if (b.disabled) " (disabled)" else if (b.folded) " (folded)" else "",
            else => if (el.isFolded()) " (folded)" else "",
        };
        try out.print(gpa, "  {s} \"{s}\"{s}\n", .{ @tagName(el.role()), el.label(), state });
    }
    for (app.notices.items) |n| try out.print(gpa, "  notice \"{s}\"\n", .{n.title});
    try trace.dump(gpa, out, app);
}

// ---- tests ----
// Small module, design-proof tests inline (CLAUDE.md). The pacer is a
// fake clock that only moves when the wait naps, so both the success
// and the timeout path run deterministically, with no real time read
// and no thread slept.

const testing = std.testing;

const FakePacer = struct {
    millis: i64 = 0,
    naps: usize = 0,
    step_ms: i64 = 10,

    fn now(ctx: ?*anyopaque) i64 {
        return @as(*FakePacer, @ptrCast(@alignCast(ctx.?))).millis;
    }

    fn nap(ctx: ?*anyopaque, ns: u64) void {
        _ = ns;
        const self: *FakePacer = @ptrCast(@alignCast(ctx.?));
        self.naps += 1;
        self.millis += self.step_ms;
    }

    fn pacer(self: *FakePacer, timeout_ms: i64) Pacer {
        return .{ .ctx = self, .now_ms = now, .nap = nap, .timeout_ms = timeout_ms };
    }
};

fn testApp(gpa: std.mem.Allocator, w: i32, h: i32) !App {
    return App.init(gpa, .{ .viewport = .{ .w = w, .h = h }, .services = .mocks() });
}

test "waitUntil returns as soon as the predicate holds" {
    var app = try testApp(testing.allocator, 320, 240);
    defer app.deinit();

    const Counter = struct {
        asked: usize = 0,
        fn readyOnThird(ctx: ?*anyopaque, _: *App) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.asked += 1;
            return self.asked >= 3;
        }
    };
    var counter: Counter = .{};
    var fake: FakePacer = .{};
    try waitUntil(&app, fake.pacer(60_000), "the third poll", &counter, Counter.readyOnThird);
    try testing.expectEqual(@as(usize, 3), counter.asked);
    // One nap per miss, none after the hit.
    try testing.expectEqual(@as(usize, 2), fake.naps);
}

test "waitUntil deadline failure errors after polling to the deadline and dumps the tree" {
    var app = try testApp(testing.allocator, 320, 240);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save" } });

    const Never = struct {
        fn ready(_: ?*anyopaque, _: *App) bool {
            return false;
        }
    };
    var fake: FakePacer = .{}; // 10ms per nap
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(
        error.WaitTimeout,
        waitUntil(&app, fake.pacer(35), "a label that never comes", null, Never.ready),
    );
    // The wait held to its deadline — four polls at 10ms crossed 35ms —
    // rather than giving up early or spinning forever.
    try testing.expectEqual(@as(usize, 4), fake.naps);
}

test "the failure dump names the route, element states, notices, and the laid-out tree" {
    var app = try testApp(testing.allocator, 400, 640);
    defer app.deinit();
    // A row too narrow for its actions, so the tail folds — the state a
    // driver most needs the dump to explain, because the folded action
    // is invisible to every query.
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Publish", "Save draft", "Duplicate", "Archive", "Delete" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Submit", .disabled = true } });
    try app.notify(.{ .title = "Sync failed", .important = true });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeScreen(testing.allocator, &out, &app);

    try testing.expect(std.mem.indexOf(u8, out.items, "on route \"(none)\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "button \"Delete\" (folded)") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "button \"Submit\" (disabled)") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "notice \"Sync failed\"") != null);
    // The trace-format tree rides along, laid out.
    try testing.expect(std.mem.indexOf(u8, out.items, "viewport 400x640") != null);
}
