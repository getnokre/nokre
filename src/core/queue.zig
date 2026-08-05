//! A bounded FIFO in front of a single-flight operation. Some ports
//! are one-at-a-time by design — an adapter that holds its caller's
//! callback can hold exactly one — and every consumer that queued in
//! front of one was hand-rolling the same ring buffer: busy flag,
//! head, wrap, overflow rule. This is that ring, once. Submissions
//! past the in-flight one wait their turn, so contention costs latency
//! rather than correctness; a full queue refuses at the call, so the
//! bound is the contract, not a hidden drop.
//!
//! Pure state machine, UI-thread only, no allocation: `Request`s and
//! callbacks are stored by value, so a request must own what it
//! carries (copy a borrowed slice into a bounded field before
//! submitting). The consumer wires two shims: a `starter` that begins
//! the operation, and a completion hook that calls `done` exactly once
//! per started request. `done` delivers to the submitter first and
//! starts the next request after, so a synchronous completion recurses
//! at most `capacity` deep and a re-entrant `submit` from inside a
//! callback joins the back of the line instead of jumping it.
//!
//! The worker ask surface (`workers.spawnAsker`) is this idea grown
//! into the slot table, where frames and faults need owning; a
//! non-worker port takes this one off the shelf instead.

const std = @import("std");

pub fn Queue(comptime Request: type, comptime Result: type, comptime capacity: usize) type {
    return struct {
        pub const Callback = struct {
            ctx: ?*anyopaque = null,
            call: *const fn (ctx: ?*anyopaque, result: Result) void,
        };
        pub const Starter = struct {
            ctx: ?*anyopaque = null,
            call: *const fn (ctx: ?*anyopaque, request: Request) void,
        };

        const Entry = struct { request: Request, callback: Callback };

        starter: Starter,
        /// True from a request's start until `done` has both delivered
        /// its result and found nothing next — it spans the callback,
        /// which is what keeps a re-entrant submit in line.
        busy: bool = false,
        current: ?Callback = null,
        head: usize = 0,
        len: usize = 0,
        waiting: [capacity]Entry = undefined,
        /// Whether the started request is still unanswered — the flag
        /// `busy` cannot be. `busy` deliberately spans the callback and
        /// the next start, so it is still true when a completion shim
        /// calls `done` twice, and the second call would deliver the
        /// *next* submitter's result to the next submitter's callback:
        /// a wrong answer, in order, with nothing to see. Debug only —
        /// the field is `void` where safety is off, so a release build
        /// carries neither the byte nor the branch.
        started: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},

        /// Start now if idle, otherwise wait in line. `error.Full`
        /// refuses — nothing was queued and no callback will fire.
        pub fn submit(self: *@This(), request: Request, callback: Callback) error{Full}!void {
            if (!self.busy) {
                self.busy = true;
                self.current = callback;
                // Marked before the start, not after: a starter that
                // answers synchronously calls `done` before this
                // returns.
                self.mark(true);
                self.starter.call(self.starter.ctx, request);
                return;
            }
            if (self.len == capacity) return error.Full;
            self.waiting[(self.head + self.len) % capacity] = .{ .request = request, .callback = callback };
            self.len += 1;
        }

        /// The single-flight operation finished: called by the
        /// consumer's completion shim, exactly once per started
        /// request. Delivers, then starts the next in line.
        pub fn done(self: *@This(), result: Result) void {
            if (comptime std.debug.runtime_safety) std.debug.assert(self.started); // done called twice for one request
            self.mark(false);
            const callback = self.current orelse return;
            self.current = null;
            callback.call(callback.ctx, result);
            if (self.len > 0) {
                const next = self.waiting[self.head];
                self.head = (self.head + 1) % capacity;
                self.len -= 1;
                self.current = next.callback;
                self.mark(true);
                self.starter.call(self.starter.ctx, next.request);
            } else {
                self.busy = false;
            }
        }

        fn mark(self: *@This(), in_flight: bool) void {
            if (comptime std.debug.runtime_safety) self.started = in_flight;
        }

        /// Requests not yet answered, counting the one in flight.
        pub fn pending(self: *const @This()) usize {
            return self.len + @intFromBool(self.busy);
        }
    };
}

// ---- design-proof tests ----

const TestQueue = Queue(u32, u32, 4);

/// A single-flight fake: holds one started request, finishes on
/// command — or instantly, when `sync` mimics a cached answer.
const Flight = struct {
    q: *TestQueue = undefined,
    started: std.ArrayList(u32) = .empty,
    inflight: ?u32 = null,
    sync: bool = false,

    fn start(ctx: ?*anyopaque, request: u32) void {
        const self: *Flight = @ptrCast(@alignCast(ctx.?));
        self.started.append(std.testing.allocator, request) catch unreachable;
        if (self.sync) {
            self.q.done(request * 10);
        } else {
            self.inflight = request;
        }
    }

    fn finish(self: *Flight) void {
        const request = self.inflight.?;
        self.inflight = null;
        self.q.done(request * 10);
    }

    fn deinit(self: *Flight) void {
        self.started.deinit(std.testing.allocator);
    }
};

const Taker = struct {
    got: std.ArrayList(u32) = .empty,

    fn take(ctx: ?*anyopaque, result: u32) void {
        const self: *Taker = @ptrCast(@alignCast(ctx.?));
        self.got.append(std.testing.allocator, result) catch unreachable;
    }

    fn callback(self: *Taker) TestQueue.Callback {
        return .{ .ctx = self, .call = take };
    }

    fn deinit(self: *Taker) void {
        self.got.deinit(std.testing.allocator);
    }
};

test "a second submit waits its turn instead of failing" {
    var flight: Flight = .{};
    defer flight.deinit();
    var taker: Taker = .{};
    defer taker.deinit();
    var q: TestQueue = .{ .starter = .{ .ctx = &flight, .call = Flight.start } };
    flight.q = &q;

    try q.submit(1, taker.callback());
    try q.submit(2, taker.callback());
    try q.submit(3, taker.callback());
    // Only the first started; the rest wait, none were refused.
    try std.testing.expectEqualSlices(u32, &.{1}, flight.started.items);
    try std.testing.expectEqual(@as(usize, 3), q.pending());

    flight.finish();
    flight.finish();
    flight.finish();
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, taker.got.items);
    try std.testing.expectEqual(@as(usize, 0), q.pending());
}

test "a full queue refuses at the call; the line is never dropped" {
    var flight: Flight = .{};
    defer flight.deinit();
    var taker: Taker = .{};
    defer taker.deinit();
    var q: TestQueue = .{ .starter = .{ .ctx = &flight, .call = Flight.start } };
    flight.q = &q;

    try q.submit(1, taker.callback()); // in flight
    for (0..4) |i| try q.submit(@intCast(2 + i), taker.callback());
    try std.testing.expectError(error.Full, q.submit(9, taker.callback()));

    for (0..5) |_| flight.finish();
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40, 50 }, taker.got.items);
}

test "a synchronous completion drains the whole line in order" {
    var flight: Flight = .{};
    defer flight.deinit();
    var taker: Taker = .{};
    defer taker.deinit();
    var q: TestQueue = .{ .starter = .{ .ctx = &flight, .call = Flight.start } };
    flight.q = &q;

    try q.submit(1, taker.callback());
    try q.submit(2, taker.callback());
    try q.submit(3, taker.callback());
    flight.sync = true; // from now on every started request answers inside start
    flight.finish();
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, taker.got.items);
    try std.testing.expectEqual(@as(usize, 0), q.pending());
}

test "a second done for one request trips the assert instead of answering the next" {
    // The bug the flag exists for: with a request already waiting,
    // `busy` is still true and `current` holds the *next* submitter's
    // callback by the time a stray second `done` arrives — so without
    // the flag that call delivers a duplicate result to somebody else's
    // question, in order, with nothing to see. An assert cannot be
    // caught in-process, so what is pinned here is the flag's own truth
    // at each point: it is exactly the predicate the assert reads.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    var flight: Flight = .{};
    defer flight.deinit();
    var taker: Taker = .{};
    defer taker.deinit();
    var q: TestQueue = .{ .starter = .{ .ctx = &flight, .call = Flight.start } };
    flight.q = &q;

    try std.testing.expect(!q.started); // idle: `done` here would assert
    try q.submit(1, taker.callback());
    try std.testing.expect(q.started);
    try q.submit(2, taker.callback());
    flight.finish(); // 1 answered, 2 started in the same call
    try std.testing.expect(q.started); // legal — but for 2, not for 1
    flight.finish();
    try std.testing.expect(!q.started); // nothing in flight; a third `done` asserts
    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, taker.got.items);
}

test "a re-entrant submit from a callback joins the back of the line" {
    const Resubmitter = struct {
        q: *TestQueue = undefined,
        taker: Taker = .{},
        fed: bool = false,

        fn take(ctx: ?*anyopaque, result: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.taker.got.append(std.testing.allocator, result) catch unreachable;
            if (!self.fed) {
                self.fed = true;
                self.q.submit(7, .{ .ctx = self, .call = take }) catch unreachable;
            }
        }
    };
    var flight: Flight = .{};
    defer flight.deinit();
    var re: Resubmitter = .{};
    defer re.taker.deinit();
    var q: TestQueue = .{ .starter = .{ .ctx = &flight, .call = Flight.start } };
    flight.q = &q;
    re.q = &q;

    try q.submit(1, .{ .ctx = &re, .call = Resubmitter.take });
    try q.submit(2, .{ .ctx = &re, .call = Resubmitter.take });
    flight.finish(); // 1 answers, resubmits 7 — behind 2, not ahead of it
    flight.finish();
    flight.finish();
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 70 }, re.taker.got.items);
}
