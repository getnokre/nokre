//! Worker tests: the codec grammar, then the actor contract driven
//! through the inline transport — the same init/handle/deinit
//! production runs, with delivery under explicit test control — plus
//! one crossing of a real thread. docs/internals/workers.md is the
//! contract these tests hold.

const std = @import("std");
const builtin = @import("builtin");
const workers = @import("workers.zig");
const codec = @import("codec.zig");
const app_mod = @import("../core/app.zig");
const harness_mod = @import("../testing/harness.zig");

const App = app_mod.App;

test "codec round-trips the message grammar" {
    const gpa = std.testing.allocator;
    const Mods = packed struct(u8) { x: bool = false, y: bool = false, _pad: u6 = 0 };
    const Msg = union(enum) {
        none,
        scalar: struct { a: i16, b: ?u8, c: [3]u8, mods: Mods, f: f64, tiny: u7 },
        named: struct { name: []const u8, vals: []const i64, nested: []const []const u8 },
    };

    const cases = [_]Msg{
        .none,
        .{ .scalar = .{ .a = -12345, .b = null, .c = .{ 1, 2, 3 }, .mods = .{ .y = true }, .f = -0.5, .tiny = 127 } },
        .{ .named = .{ .name = "nokre", .vals = &.{ -1, 0, std.math.maxInt(i64) }, .nested = &.{ "a", "", "bc" } } },
    };
    for (cases) |case| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var atts: std.ArrayList([]u8) = .empty;
        defer atts.deinit(gpa);
        try codec.encode(Msg, gpa, &buf, &atts, case);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        try std.testing.expectEqualDeep(case, try codec.decode(Msg, arena.allocator(), buf.items, &.{}));
    }
}

test "codec rejects trailing and truncated bytes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var atts: std.ArrayList([]u8) = .empty;
    defer atts.deinit(gpa);
    try codec.encode(u32, gpa, &buf, &atts, 7);
    try std.testing.expectError(error.Corrupt, codec.decode(u32, arena.allocator(), buf.items[0..2], &.{}));
    try buf.append(gpa, 0);
    try std.testing.expectError(error.Corrupt, codec.decode(u32, arena.allocator(), buf.items, &.{}));
}

test "codec borrows []const u8 from the frame; mutable slices still copy" {
    const gpa = std.testing.allocator;
    const Msg = struct { name: []const u8, scratch: []u8 };
    var mutable = [_]u8{ 1, 2, 3 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var atts: std.ArrayList([]u8) = .empty;
    defer atts.deinit(gpa);
    try codec.encode(Msg, gpa, &buf, &atts, .{ .name = "nokre", .scratch = &mutable });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try codec.decode(Msg, arena.allocator(), buf.items, &.{});

    // The zero-copy contract: a const byte slice is a view into the
    // frame — and stays const, so no mutation of the frame is implied.
    try std.testing.expectEqual(@intFromPtr(buf.items.ptr) + 4, @intFromPtr(decoded.name.ptr));
    comptime std.debug.assert(@TypeOf(decoded.name) == []const u8);
    try std.testing.expectEqualStrings("nokre", decoded.name);

    // A mutable slice must not alias the (const) frame: arena-copied.
    const frame_start = @intFromPtr(buf.items.ptr);
    const frame_end = frame_start + buf.items.len;
    const scratch_at = @intFromPtr(decoded.scratch.ptr);
    try std.testing.expect(scratch_at < frame_start or scratch_at >= frame_end);
    try std.testing.expectEqualSlices(u8, &mutable, decoded.scratch);
}

test "codec: Bytes rides out-of-band and moves whole" {
    const gpa = std.testing.allocator;
    const Msg = struct { tag: u32, blob: codec.Bytes, name: []const u8 };
    const payload = try gpa.dupe(u8, "0123456789");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var atts: std.ArrayList([]u8) = .empty;
    defer atts.deinit(gpa);
    try codec.encode(Msg, gpa, &buf, &atts, .{ .tag = 7, .blob = .adopt(payload), .name = "n" });
    try std.testing.expectEqual(1, atts.items.len);
    try std.testing.expectEqual(payload.ptr, atts.items[0].ptr); // moved, never copied

    var slots = [_]?[]u8{atts.items[0]};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try codec.decode(Msg, arena.allocator(), buf.items, &slots);
    try std.testing.expectEqual(payload.ptr, decoded.blob.data.ptr);
    const kept = decoded.blob.take();
    defer gpa.free(kept);
    try std.testing.expectEqual(null, slots[0]); // take emptied the slot
    try std.testing.expectEqualStrings("0123456789", kept);
}

test "codec: attachment bookkeeping is strict" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var blob = [_]u8{ 1, 2, 3 };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var atts: std.ArrayList([]u8) = .empty;
    defer atts.deinit(gpa);
    try codec.encode(codec.Bytes, gpa, &buf, &atts, .adopt(&blob));

    // A frame naming a blob its transport did not carry is corrupt…
    try std.testing.expectError(error.Corrupt, codec.decode(codec.Bytes, arena.allocator(), buf.items, &.{}));
    // …as is a blob whose length disagrees with the frame…
    var short = [_]u8{ 1, 2 };
    var wrong = [_]?[]u8{&short};
    try std.testing.expectError(error.Corrupt, codec.decode(codec.Bytes, arena.allocator(), buf.items, &wrong));
    // …and a transported blob no field accounts for.
    var stray = [_]?[]u8{&blob};
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try codec.encode(u32, gpa, &plain, &atts, 9);
    try std.testing.expectError(error.Corrupt, codec.decode(u32, arena.allocator(), plain.items, &stray));
}

test "web envelope: attachments concat out and parse back owned" {
    const gpa = std.testing.allocator;
    var a0 = [_]u8{ 1, 2, 3 };
    var a1 = [_]u8{};
    var atts = [_]?[]u8{ &a0, &a1 };
    const env = try workers.buildEnvelope(gpa, workers.reply_attach_frame, "payload", &atts);
    defer gpa.free(env);

    const frame = workers.frameFromEnvelope(gpa, workers.reply_frame, env) orelse return error.TestUnexpectedResult;
    defer frame.free(gpa);
    try std.testing.expectEqual(workers.reply_frame, frame.bytes[0]);
    try std.testing.expectEqualStrings("payload", frame.bytes[1..]);
    try std.testing.expectEqual(2, frame.attachments.len);
    try std.testing.expectEqualSlices(u8, &a0, frame.attachments[0].?);
    try std.testing.expectEqual(0, frame.attachments[1].?.len);
    // The landing copy is real: the parsed blob owns fresh memory.
    try std.testing.expect(frame.attachments[0].?.ptr != @as([]u8, &a0).ptr);

    // Truncation anywhere is rejected or re-owned — never a crash or
    // an out-of-bounds read (the bytes are trusted in origin only).
    for (0..env.len) |cut| {
        if (workers.frameFromEnvelope(gpa, workers.reply_frame, env[0..cut])) |f| f.free(gpa);
    }
}

test "web envelope: oversized declared blob lengths reject, never wrap" {
    const gpa = std.testing.allocator;
    // Hand-built: two blob lengths near maxInt(u32) whose sum wraps a
    // 32-bit usize. The wrap would slip under the bound check and read
    // out of bounds on wasm; the checked sum must read it as malformed
    // (null) instead — "never a crash".
    var env: [13]u8 = undefined;
    env[0] = workers.reply_attach_frame;
    std.mem.writeInt(u32, env[1..5], 2, .little);
    std.mem.writeInt(u32, env[5..9], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, env[9..13], std.math.maxInt(u32), .little);
    try std.testing.expect(workers.frameFromEnvelope(gpa, workers.reply_frame, &env) == null);
}

// ---- the test worker ----

const Doubler = struct {
    pub const Msg = union(enum) {
        double: u32,
        sum: []const u32,
        /// Streams one progress per chunk — unless a newer message is
        /// already waiting, in which case the work is stale and skipped.
        chunks: u32,
        boom,
    };
    pub const Reply = union(enum) {
        doubled: u64,
        summed: u64,
        progress: u32,
        skipped,
    };

    pub fn init(_: std.mem.Allocator) !Doubler {
        return .{};
    }
    pub fn deinit(self: *Doubler) void {
        _ = self;
    }
    pub fn handle(self: *Doubler, msg: Msg, out: *workers.Outbox(Reply)) !void {
        _ = self;
        switch (msg) {
            .double => |v| try out.send(.{ .doubled = 2 * @as(u64, v) }),
            .sum => |vs| {
                var total: u64 = 0;
                for (vs) |v| total += v;
                try out.send(.{ .summed = total });
            },
            .chunks => |n| {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    if (out.interrupted()) return out.send(.skipped);
                    try out.send(.{ .progress = i });
                }
            },
            .boom => return error.Kaboom,
        }
    }
};

/// Reply handlers log into one string, so a test asserts content *and*
/// order with a single compare.
const Sink = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayList(u8) = .empty,

    fn deinit(self: *Sink) void {
        self.log.deinit(self.gpa);
    }
    fn append(self: *Sink, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.log.appendSlice(self.gpa, s) catch {};
    }
    fn onReply(ctx: ?*anyopaque, reply: Doubler.Reply) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        switch (reply) {
            .doubled => |v| self.append("doubled {d};", .{v}),
            .summed => |v| self.append("summed {d};", .{v}),
            .progress => |v| self.append("progress {d};", .{v}),
            .skipped => self.append("skipped;", .{}),
        }
    }
    fn onFault(ctx: ?*anyopaque, fault: workers.Fault) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        switch (fault) {
            .err => |name| self.append("fault {s};", .{name}),
            .died => self.append("died;", .{}),
        }
    }
};

fn testApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{ .viewport = .{ .w = 320, .h = 240 }, .services = .mocks() });
}

test "inline worker: replies land in order, only when pumped" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const w = try workers.spawn(Doubler, .{ .app = &app, .ctx = &sink, .on_reply = Sink.onReply });
    try w.send(.{ .double = 21 });
    try w.send(.{ .sum = &.{ 1, 2, 3 } });
    // Nothing lands until the test says so — that is the whole point.
    try std.testing.expectEqualStrings("", sink.log.items);
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("doubled 42;summed 6;", sink.log.items);
}

test "interrupted: a queued newer message marks in-flight work stale" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const w = try workers.spawn(Doubler, .{ .app = &app, .ctx = &sink, .on_reply = Sink.onReply });
    try w.send(.{ .chunks = 3 }); // stale before it runs: `double` is already behind it
    try w.send(.{ .double = 1 });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("skipped;doubled 2;", sink.log.items);

    sink.log.clearRetainingCapacity();
    try w.send(.{ .chunks = 2 }); // alone in the inbox: runs to completion
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("progress 0;progress 1;", sink.log.items);
}

test "retire: queued messages drain, deinit runs, the handle goes stale" {
    const gpa = std.testing.allocator;
    // Its own worker type with its own counter: the deinit-ran proof is
    // this test's alone — no counter shared across tests.
    const RetireProbe = struct {
        var deinits: u32 = 0;
        pub const Msg = Doubler.Msg;
        pub const Reply = Doubler.Reply;
        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {
            deinits += 1;
        }
        pub fn handle(_: *@This(), msg: Msg, out: *workers.Outbox(Reply)) !void {
            switch (msg) {
                .double => |v| try out.send(.{ .doubled = 2 * @as(u64, v) }),
                else => {},
            }
        }
    };
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const w = try workers.spawn(RetireProbe, .{ .app = &app, .ctx = &sink, .on_reply = Sink.onReply });
    try w.send(.{ .double = 5 });
    w.retire();
    try std.testing.expectError(error.WorkerRetired, w.send(.{ .double = 6 }));
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("doubled 10;", sink.log.items);
    try std.testing.expectEqual(1, RetireProbe.deinits);
    w.retire(); // idempotent on a dead handle
}

test "a handler error is a fault message; the worker lives on" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const w = try workers.spawn(Doubler, .{
        .app = &app,
        .ctx = &sink,
        .on_reply = Sink.onReply,
        .on_fault = Sink.onFault,
    });
    try w.send(.boom);
    try w.send(.{ .double = 2 });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("fault Kaboom;doubled 4;", sink.log.items);
}

test "two workers of one type are independent actors" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var a: Sink = .{ .gpa = gpa };
    defer a.deinit();
    var b: Sink = .{ .gpa = gpa };
    defer b.deinit();

    const wa = try workers.spawn(Doubler, .{ .app = &app, .ctx = &a, .on_reply = Sink.onReply });
    const wb = try workers.spawn(Doubler, .{ .app = &app, .ctx = &b, .on_reply = Sink.onReply });
    try wa.send(.{ .double = 1 });
    try wb.send(.{ .double = 2 });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("doubled 2;", a.log.items);
    try std.testing.expectEqualStrings("doubled 4;", b.log.items);
}

test "thread transport: a reply crosses a real thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    app.runtime.mode = .platform;

    const w = try workers.spawn(Doubler, .{ .app = &app, .ctx = &sink, .on_reply = Sink.onReply });
    try w.send(.{ .double = 21 });
    // No wake is installed here; poll the pump the way a shell's main
    // thread would run it. Bounded by tries, not wall time.
    var tries: u32 = 0;
    while (sink.log.items.len == 0 and tries < 10_000_000) : (tries += 1) {
        _ = app.runtime.pump();
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqualStrings("doubled 42;", sink.log.items);
    w.retire(); // shutdown (deferred) joins the thread either way
}

// ---- the ask surface ----

/// Answers every probe with whether it ran calm — `interrupted()`
/// false — so a test can prove queued asks never make in-flight work
/// stale (the exact failure the ask FIFO exists to delete).
const Prober = struct {
    pub const Msg = union(enum) { probe: u32 };
    pub const Reply = union(enum) { probed: struct { id: u32, calm: bool } };

    pub fn init(_: std.mem.Allocator) !Prober {
        return .{};
    }
    pub fn deinit(_: *Prober) void {}
    pub fn handle(_: *Prober, msg: Msg, out: *workers.Outbox(Reply)) !void {
        switch (msg) {
            .probe => |id| try out.send(.{ .probed = .{ .id = id, .calm = !out.interrupted() } }),
        }
    }
};

/// Answer handlers log into one string, like Sink: content and order
/// in a single compare.
const AskSink = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayList(u8) = .empty,

    fn deinit(self: *AskSink) void {
        self.log.deinit(self.gpa);
    }
    fn append(self: *AskSink, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.log.appendSlice(self.gpa, s) catch {};
    }
    fn onProbe(ctx: ?*anyopaque, answer: workers.Answer(Prober)) void {
        const self: *AskSink = @ptrCast(@alignCast(ctx.?));
        switch (answer) {
            .reply => |r| switch (r) {
                .probed => |p| self.append("probed {d} {s};", .{ p.id, if (p.calm) @as([]const u8, "calm") else "interrupted" }),
            },
            .fault => |f| self.appendFault(f),
        }
    }
    fn onDoubler(ctx: ?*anyopaque, answer: workers.Answer(Doubler)) void {
        const self: *AskSink = @ptrCast(@alignCast(ctx.?));
        switch (answer) {
            .reply => |r| switch (r) {
                .doubled => |v| self.append("doubled {d};", .{v}),
                else => self.append("other;", .{}),
            },
            .fault => |f| self.appendFault(f),
        }
    }
    fn appendFault(self: *AskSink, fault: workers.Fault) void {
        switch (fault) {
            .err => |name| self.append("fault {s};", .{name}),
            .died => self.append("died;", .{}),
        }
    }
};

test "ask: answers arrive in ask order, and no question interrupts another" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: AskSink = .{ .gpa = gpa };
    defer sink.deinit();

    const a = try workers.spawnAsker(Prober, &app);
    // Three at once. Through `send` the first two would run interrupted
    // (anything queued behind marks them stale); through `ask` only the
    // front question is ever in the worker's inbox.
    try a.ask(.{ .probe = 1 }, &sink, AskSink.onProbe);
    try a.ask(.{ .probe = 2 }, &sink, AskSink.onProbe);
    try a.ask(.{ .probe = 3 }, &sink, AskSink.onProbe);
    try std.testing.expectEqual(@as(usize, 3), a.pending());
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("probed 1 calm;probed 2 calm;probed 3 calm;", sink.log.items);
    try std.testing.expectEqual(@as(usize, 0), a.pending());
}

test "ask: a full queue refuses, and nothing queued is lost" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: AskSink = .{ .gpa = gpa };
    defer sink.deinit();

    const a = try workers.spawnAsker(Prober, &app);
    var i: u32 = 0;
    while (i < workers.max_pending_asks) : (i += 1)
        try a.ask(.{ .probe = i }, &sink, AskSink.onProbe);
    try std.testing.expectError(error.TooManyAsks, a.ask(.{ .probe = 99 }, &sink, AskSink.onProbe));
    try std.testing.expectEqual(@as(usize, workers.max_pending_asks), a.pending());
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(usize, 0), a.pending());
    try std.testing.expectEqual(workers.max_pending_asks, std.mem.count(u8, sink.log.items, "probed "));
    try std.testing.expect(std.mem.indexOf(u8, sink.log.items, "probed 99") == null);
}

test "ask: a handler error answers only its own question" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: AskSink = .{ .gpa = gpa };
    defer sink.deinit();

    const a = try workers.spawnAsker(Doubler, &app);
    try a.ask(.boom, &sink, AskSink.onDoubler);
    try a.ask(.{ .double = 2 }, &sink, AskSink.onDoubler);
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("fault Kaboom;doubled 4;", sink.log.items);
}

test "ask: retire drains — every accepted question is answered" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: AskSink = .{ .gpa = gpa };
    defer sink.deinit();

    const a = try workers.spawnAsker(Doubler, &app);
    try a.ask(.{ .double = 1 }, &sink, AskSink.onDoubler);
    try a.ask(.{ .double = 2 }, &sink, AskSink.onDoubler);
    try a.ask(.{ .double = 3 }, &sink, AskSink.onDoubler);
    a.retire();
    try std.testing.expectError(error.WorkerRetired, a.ask(.{ .double = 4 }, &sink, AskSink.onDoubler));
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("doubled 2;doubled 4;doubled 6;", sink.log.items);
    try std.testing.expectEqual(@as(usize, 0), a.pending());
    a.retire(); // idempotent on a dead asker
}

test "ask: an answer may ask again; it joins the back of the line" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();

    const Reasker = struct {
        asker: workers.Asker(Doubler) = undefined,
        sink: AskSink,
        fed: bool = false,

        fn onAnswer(ctx: ?*anyopaque, answer: workers.Answer(Doubler)) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            AskSink.onDoubler(&self.sink, answer);
            if (!self.fed) {
                self.fed = true;
                self.asker.ask(.{ .double = 30 }, self, onAnswer) catch unreachable;
            }
        }
    };
    var re: Reasker = .{ .sink = .{ .gpa = gpa } };
    defer re.sink.deinit();

    re.asker = try workers.spawnAsker(Doubler, &app);
    try re.asker.ask(.{ .double = 1 }, &re, Reasker.onAnswer);
    try re.asker.ask(.{ .double = 2 }, &re, Reasker.onAnswer);
    app.runtime.pumpAll();
    // The re-entrant ask (fired from the first answer) lands behind the
    // already-queued second question, not ahead of it.
    try std.testing.expectEqualStrings("doubled 2;doubled 4;doubled 60;", re.sink.log.items);
}

test "ask: thread transport answers across a real thread, in order" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: AskSink = .{ .gpa = gpa };
    defer sink.deinit();

    app.runtime.mode = .platform;

    const a = try workers.spawnAsker(Doubler, &app);
    try a.ask(.{ .double = 21 }, &sink, AskSink.onDoubler);
    try a.ask(.{ .double = 30 }, &sink, AskSink.onDoubler); // queued: the advance crosses threads too
    var tries: u32 = 0;
    while (a.pending() > 0 and tries < 10_000_000) : (tries += 1) {
        _ = app.runtime.pump();
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqualStrings("doubled 42;doubled 60;", sink.log.items);
    a.retire(); // shutdown (deferred) joins the thread either way
}

// ---- transferable blobs (docs/internals/workers.md) ----

const Blober = struct {
    gpa: std.mem.Allocator,

    pub const Msg = union(enum) {
        /// Sum the blob, then move the very same buffer back out.
        bounce: workers.Bytes,
        /// Drop the blob untaken: the frame's cleanup must free it.
        ignore: workers.Bytes,
        /// Allocate worker-side and move the buffer to the app.
        make: u32,
        plain: u32,
    };
    pub const Reply = union(enum) {
        bounced: struct { sum: u64, blob: workers.Bytes },
        ignored,
        made: workers.Bytes,
        plained: u32,
    };

    pub fn init(gpa: std.mem.Allocator) !Blober {
        return .{ .gpa = gpa };
    }
    pub fn deinit(_: *Blober) void {}
    pub fn handle(self: *Blober, msg: Msg, out: *workers.Outbox(Reply)) !void {
        switch (msg) {
            .bounce => |b| {
                var sum: u64 = 0;
                for (b.view()) |v| sum += v;
                try out.send(.{ .bounced = .{ .sum = sum, .blob = .adopt(b.take()) } });
            },
            .ignore => try out.send(.ignored),
            .make => |n| {
                const buf = try self.gpa.alloc(u8, n);
                @memset(buf, 7);
                try out.send(.{ .made = .adopt(buf) });
            },
            .plain => |v| try out.send(.{ .plained = v }),
        }
    }
};

const BlobSink = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayList(u8) = .empty,
    taken: ?[]u8 = null,

    fn deinit(self: *BlobSink) void {
        self.log.deinit(self.gpa);
        if (self.taken) |t| self.gpa.free(t);
    }
    fn append(self: *BlobSink, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.log.appendSlice(self.gpa, s) catch {};
    }
    fn onReply(ctx: ?*anyopaque, reply: Blober.Reply) void {
        const self: *BlobSink = @ptrCast(@alignCast(ctx.?));
        switch (reply) {
            .bounced => |b| {
                self.append("bounced {d};", .{b.sum});
                if (self.taken) |t| self.gpa.free(t);
                self.taken = b.blob.take();
            },
            .ignored => self.append("ignored;", .{}),
            // Deliberately untaken: freed with the delivery.
            .made => self.append("made;", .{}),
            .plained => |v| self.append("plained {d};", .{v}),
        }
    }
};

test "Bytes: one buffer end to end, app to worker and back" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: BlobSink = .{ .gpa = gpa };
    defer sink.deinit();

    const w = try workers.spawn(Blober, .{ .app = &app, .ctx = &sink, .on_reply = BlobSink.onReply });
    const blob = try gpa.alloc(u8, 1 << 20);
    @memset(blob, 3);
    const original_ptr = blob.ptr;
    try w.send(.{ .bounce = .adopt(blob) });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("bounced 3145728;", sink.log.items);
    // The zero-copy claim itself: what the app kept is the very
    // allocation it adopted — moved through both directions untouched.
    try std.testing.expectEqual(original_ptr, sink.taken.?.ptr);
    try std.testing.expectEqual(1 << 20, sink.taken.?.len);
}

test "Bytes: untaken blobs are freed with their frame and delivery" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: BlobSink = .{ .gpa = gpa };
    defer sink.deinit();

    const w = try workers.spawn(Blober, .{ .app = &app, .ctx = &sink, .on_reply = BlobSink.onReply });
    // Worker leaves the incoming blob untaken; app leaves the made one
    // untaken. The leak-checking allocator is the assertion.
    try w.send(.{ .ignore = .adopt(try gpa.dupe(u8, "dropped")) });
    try w.send(.{ .make = 64 });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("ignored;made;", sink.log.items);
}

test "Bytes: blobs interleave with plain messages in order" {
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: BlobSink = .{ .gpa = gpa };
    defer sink.deinit();

    const w = try workers.spawn(Blober, .{ .app = &app, .ctx = &sink, .on_reply = BlobSink.onReply });
    try w.send(.{ .plain = 1 });
    const blob = try gpa.dupe(u8, &[_]u8{ 10, 20 });
    try w.send(.{ .bounce = .adopt(blob) });
    try w.send(.{ .plain = 2 });
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("plained 1;bounced 30;plained 2;", sink.log.items);
}

test "thread transport: a blob moves across a real thread untouched" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var app = try testApp(gpa);
    defer app.deinit();
    var sink: BlobSink = .{ .gpa = gpa };
    defer sink.deinit();

    app.runtime.mode = .platform;

    const w = try workers.spawn(Blober, .{ .app = &app, .ctx = &sink, .on_reply = BlobSink.onReply });
    const blob = try gpa.alloc(u8, 1 << 20);
    @memset(blob, 1);
    const original_ptr = blob.ptr;
    try w.send(.{ .bounce = .adopt(blob) });
    var tries: u32 = 0;
    while (sink.log.items.len == 0 and tries < 10_000_000) : (tries += 1) {
        _ = app.runtime.pump();
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqualStrings("bounced 1048576;", sink.log.items);
    try std.testing.expectEqual(original_ptr, sink.taken.?.ptr);
    w.retire();
}

test "harness: settleWorkers is the moment async work lands" {
    const gpa = std.testing.allocator;
    const Ctx = struct {
        sink: Sink,
        handle: workers.Handle(Doubler) = undefined,
        fn build(ctx: ?*anyopaque, app: *App) !void {
            _ = ctx;
            const root = app.tree.rootId();
            try app.tree.append(root, .{ .heading = .{ .content = "Search", .level = .h1 } });
        }
    };
    var ctx: Ctx = .{ .sink = .{ .gpa = gpa } };
    defer ctx.sink.deinit();

    var t = try harness_mod.Harness.init(gpa, .{ .w = 320, .h = 240 }, .{ .ctx = &ctx, .build = Ctx.build });
    defer t.deinit(); // harness deinit shuts workers down

    ctx.handle = try workers.spawn(Doubler, .{ .app = &t.app, .ctx = &ctx.sink, .on_reply = Sink.onReply });
    try ctx.handle.send(.{ .double = 3 });
    try std.testing.expectEqualStrings("", ctx.sink.log.items);
    try t.settleWorkers();
    try std.testing.expectEqualStrings("doubled 6;", ctx.sink.log.items);
}
