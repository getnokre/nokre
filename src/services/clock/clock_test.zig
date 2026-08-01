//! clock service tests: the one verb driven through the per-app mock —
//! the only clock under `zig test`, so what holds here is the whole
//! contract. The through-line is that time is an *input*: it starts at a
//! value the test named, it moves only where the test moves it, and the
//! screen it reaches is a screen built from app state like any other.
//! docs/services.md is the contract held here.

const std = @import("std");
const clock = @import("clock.zig");
const app_mod = @import("../../core/app.zig");
const tree_mod = @import("../../core/tree.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;
const Harness = harness_mod.Harness;

fn testApp(gpa: std.mem.Allocator, millis: i64) !App {
    return App.init(gpa, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .clock = .mock(.{ .millis = millis }) },
    });
}

// ---- the read ----

test "the default instant is fixed, sane, and obviously fake" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .mocks(),
    });
    defer app.deinit();

    // A test that never mentions time still gets the same number every
    // run — the property a golden of a stamped screen rests on.
    try std.testing.expectEqual(clock.default_millis, clock.now(&app));
    // 2020-01-01T00:00:00Z: plausible enough for app-side date
    // arithmetic, and midnight on a New Year to the millisecond, which
    // no device's clock has ever read.
    try std.testing.expectEqual(@as(i64, 1_577_836_800_000), clock.default_millis);
}

test "a stopped clock answers every read identically" {
    var app = try testApp(std.testing.allocator, 1_700_000_000_000);
    defer app.deinit();

    // Nothing ticks under a nokre app, here least of all: two reads with
    // no `advance` between them are the same instant, which is what
    // makes "stamp it twice and compare" a test about the app.
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), clock.now(&app));
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), clock.now(&app));
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), app.services.clock.now());
}

test "reads are counted, and zero is a state" {
    var app = try testApp(std.testing.allocator, clock.default_millis);
    defer app.deinit();

    // "This code path never asked the time" is assertable — the
    // app-side spelling of core's own clocklessness.
    try std.testing.expectEqual(@as(usize, 0), app.services.clock.reads());
    _ = clock.now(&app);
    _ = clock.now(&app);
    try std.testing.expectEqual(@as(usize, 2), app.services.clock.reads());
    // Moving the clock is the test's doing, not the app's: it reads
    // nothing and so counts nothing.
    app.services.clock.advance(1000);
    try std.testing.expectEqual(@as(usize, 2), app.services.clock.reads());
}

// ---- moving it ----

test "advance moves the clock forward, and backward, because wall time does" {
    var app = try testApp(std.testing.allocator, 1_000_000);
    defer app.deinit();

    app.services.clock.advance(std.time.ms_per_hour);
    try std.testing.expectEqual(@as(i64, 1_000_000 + 3_600_000), clock.now(&app));

    // The NTP correction a real device really performs: an app that
    // subtracts two stamps has to survive a negative difference, and
    // this is the verb that produces one. There is no monotonic clock
    // to hide behind — that is the point of not having one.
    app.services.clock.advance(-std.time.ms_per_hour * 2);
    try std.testing.expectEqual(@as(i64, 1_000_000 - 3_600_000), clock.now(&app));
    try std.testing.expect(clock.now(&app) < 1_000_000);
}

test "two apps carry disjoint clocks by construction" {
    var a = try testApp(std.testing.allocator, 1_000);
    defer a.deinit();
    var b = try testApp(std.testing.allocator, 2_000);
    defer b.deinit();

    a.services.clock.advance(500);
    _ = clock.now(&a);

    // Nothing global to leak through: b's instant and read count are
    // untouched by anything a did. b is read through the mock, which
    // does not count — a test looking at the clock is not the app
    // asking for it, which is the whole reason the count means
    // something.
    try std.testing.expectEqual(@as(i64, 1_500), clock.now(&a));
    try std.testing.expectEqual(@as(i64, 2_000), b.services.clock.now());
    try std.testing.expectEqual(@as(usize, 2), a.services.clock.reads());
    try std.testing.expectEqual(@as(usize, 0), b.services.clock.reads());
}

// ---- the capstone: a stamp on the screen, through the harness ----

const Notes = struct {
    app: ?*App = null,
    status: tree_mod.NodeId = undefined,
    buf: [64]u8 = undefined,

    /// The screen itself never asks the time — the stamp is state, and
    /// the state is empty until the user does something.
    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *Notes = @ptrCast(@alignCast(ctx.?));
        const root = app.tree.rootId();
        _ = try app.tree.append(root, .{ .heading = .{ .content = "Notes" } });
        self.status = try app.tree.append(root, .{ .text = .{ .content = "Never saved" } });
        _ = try app.tree.append(root, .{ .button = .{
            .label = "Save",
            .on_press = .{ .ctx = self, .call = Notes.onSave },
        } });
    }

    /// Where a clock read belongs: in the action, once, kept as the
    /// app's own state. What renders it afterwards is a frame built from
    /// state, exactly like every other frame.
    fn onSave(ctx: ?*anyopaque) void {
        const self: *Notes = @ptrCast(@alignCast(ctx.?));
        const app = self.app orelse return;
        const stamp = std.fmt.bufPrint(&self.buf, "Saved at {d}", .{clock.now(app)}) catch return;
        app.tree.setContent(self.status, stamp) catch return;
        app.invalidate();
    }
};

test "capstone: the app stamps a screen, and the harness owns when time moves" {
    var ctx: Notes = .{};
    var t = try Harness.initWith(std.testing.allocator, .{ .w = 320, .h = 480 }, .{
        .ctx = &ctx,
        .build = Notes.build,
        .clock = .{ .millis = 1_700_000_000_000 },
    });
    defer t.deinit();
    ctx.app = &t.app;

    // The first frame is clockless, and provably so.
    try std.testing.expectEqual(@as(usize, 0), t.clockReads());
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), t.clockNow());

    try t.tapLabel("Save");
    _ = try t.getByLabel("Saved at 1700000000000");
    try std.testing.expectEqual(@as(usize, 1), t.clockReads());

    // An hour passes because the test said so; nothing on the app's
    // side ran, so the screen still reads what it last saved.
    try t.advanceClock(std.time.ms_per_hour);
    _ = try t.getByLabel("Saved at 1700000000000");

    try t.tapLabel("Save");
    _ = try t.getByLabel("Saved at 1700003600000");
    try t.expectAbsent("Never saved");
    try std.testing.expectEqual(@as(usize, 2), t.clockReads());
}
