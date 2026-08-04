//! The capstone proof of the injected-services design: two Apps, each
//! constructed with its own mocks, driven concurrently from two
//! std.Threads through interleaved http/store/worker/clipboard traffic.
//! No test_scope, no registries, no app-stamping — every piece of
//! mutable service state hangs off one app, so this test is safe *by
//! construction*, and it is executable: what a data race would corrupt
//! here is exactly what the per-app design makes unreachable.
//!
//! It also documents what tests may now do that they couldn't before:
//! drive two apps at once (from two threads, even), flip one app's
//! worker transport to real threads without touching the other, and
//! tear everything down with two deinits.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../core/app.zig");
const workers = @import("../workers/workers.zig");
const http = @import("http/http.zig");
const iap = @import("iap/iap.zig");
const oauth = @import("oauth/oauth.zig");
const open_url = @import("open_url/open_url.zig");
const services = @import("services.zig");
const secure_store = @import("secure_store/secure_store.zig");
const share = @import("share/share.zig");

const App = app_mod.App;

// package_info and open_url keep their design-proof tests inline (both
// are small modules); referencing them here is what makes the test
// build compile them at all — the carve-outs being provable is the
// point. share is small too, but its proofs all need an App (the caps
// and the availability gate are observed through the journal), so they
// live below instead.
test {
    _ = @import("package_info/package_info.zig");
    _ = @import("open_url/open_url.zig");
    _ = @import("share/share.zig");
}

// The design proof for the roster's one failure shape: identity, not
// structural likeness — a consumer helper taking `services.Failure`
// accepts all three, which three identical declarations never gave.
test "one Failure: http, oauth, and iap answer with the same type" {
    comptime {
        std.debug.assert(http.Failure == services.Failure);
        std.debug.assert(oauth.Failure == services.Failure);
        std.debug.assert(iap.Failure == services.Failure);
    }
}

const Doubler = struct {
    pub const Msg = union(enum) { double: u32 };
    pub const Reply = union(enum) { doubled: u64 };

    pub fn init(_: std.mem.Allocator) !Doubler {
        return .{};
    }
    pub fn deinit(_: *Doubler) void {}
    pub fn handle(_: *Doubler, msg: Msg, out: *workers.Outbox(Reply)) !void {
        switch (msg) {
            .double => |v| try out.send(.{ .doubled = 2 * @as(u64, v) }),
        }
    }
};

const Session = struct {
    gpa: std.mem.Allocator,
    /// Distinguishes the two sessions' data end to end: any cross-app
    /// bleed shows up as the wrong tag in an assertion.
    tag: u8,
    rounds: u32,
    failed: ?anyerror = null,

    last_doubled: ?u64 = null,
    http_status: ?u16 = null,

    fn onReply(ctx: ?*anyopaque, reply: Doubler.Reply) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.last_doubled = reply.doubled;
    }

    fn onResult(ctx: ?*anyopaque, _: u64, result: http.Result) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.http_status = switch (result) {
            .response => |r| r.status,
            .failure => null,
        };
    }

    fn run(self: *Session) void {
        self.drive() catch |e| {
            self.failed = e;
        };
    }

    fn drive(self: *Session) !void {
        // The whole session — construction included — happens on this
        // thread; the other thread has its own everything.
        var app = try App.init(self.gpa, .{
            .viewport = .{ .w = 320, .h = 240 },
            .services = .{ .secure_store = .mock(.{
                .seeds = &.{.{ .key = "session.tag", .value = &.{'0' + self.tag} }},
            }) },
        });
        defer app.deinit();
        // Real worker threads for this app alone: per-app state, so
        // flipping it cannot leak into the sibling session.
        if (!builtin.single_threaded) app.runtime.mode = .platform;

        const w = try workers.spawn(Doubler, .{ .app = &app, .ctx = self, .on_reply = Session.onReply });

        var round: u32 = 0;
        while (round < self.rounds) : (round += 1) {
            // Store: the seeded tag survives, and per-round writes stay ours.
            var buf: secure_store.ValueBuf = undefined;
            const tag = (try secure_store.get(&app, "session.tag", &buf)).?;
            try std.testing.expectEqual(1, tag.len);
            try std.testing.expectEqual('0' + self.tag, tag[0]);
            var key_buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "round.{d}", .{round % 8});
            var val_buf: [16]u8 = undefined;
            const val = try std.fmt.bufPrint(&val_buf, "{d}:{d}", .{ self.tag, round });
            try secure_store.set(&app, key, val);
            try std.testing.expectEqualStrings(val, (try secure_store.get(&app, key, &buf)).?);

            // Network: park in our mock, answer with a tag-stamped
            // status, land it on our runtime.
            self.http_status = null;
            _ = try http.request(.{ .app = &app, .url = "https://capstone.test/", .ctx = self, .on_result = Session.onResult });
            try std.testing.expectEqual(1, app.services.http.pendingCount());
            try app.services.http.fulfill(.{ .status = 200 + @as(u16, self.tag) });
            app.runtime.pumpAll();
            try std.testing.expectEqual(200 + @as(u16, self.tag), self.http_status.?);

            // Worker: a real thread on native — the reply crosses back
            // into this session's runtime and nobody else's.
            self.last_doubled = null;
            try w.send(.{ .double = round });
            var tries: u32 = 0;
            while (self.last_doubled == null and tries < 100_000_000) : (tries += 1) {
                app.runtime.pumpAll();
                if (!builtin.single_threaded) std.Thread.yield() catch {};
            }
            try std.testing.expectEqual(2 * @as(u64, round), self.last_doubled.?);

            // Clipboard: the journal is ours alone.
            app.copyText(tag);
        }

        const copies = app.services.clipboard.copies();
        try std.testing.expectEqual(self.rounds, copies.len);
        for (copies) |c| try std.testing.expectEqual('0' + self.tag, c[0]);
        // deinit (deferred) retires the worker thread and frees every
        // mock — per app, in any order relative to the other session.
    }
};

test "open_url: opens journal in request order; a scheme off the allowlist errors and journals nothing" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .mocks(),
    });
    defer app.deinit();

    try open_url.open(&app, "https://example.com/terms");
    try open_url.open(&app, "mailto:help@example.com");
    // The error is uniform and pre-OS: the journal — the mock's whole
    // observable effect — must show the OS was never asked.
    try std.testing.expectError(error.UnsupportedScheme, open_url.open(&app, "file:///etc/passwd"));
    try std.testing.expectError(error.UnsupportedScheme, open_url.open(&app, "javascript:alert(1)"));

    const requested = app.services.open_url.opens();
    try std.testing.expectEqual(2, requested.len);
    try std.testing.expectEqualStrings("https://example.com/terms", requested[0]);
    try std.testing.expectEqualStrings("mailto:help@example.com", requested[1]);
}

test "share: shares journal in request order; empty and over-cap refuse before the OS is asked" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .mocks(),
    });
    defer app.deinit();

    try std.testing.expect(share.available(&app));
    try share.show(&app, "Look at this: https://example.com/n/42");
    try share.show(&app, "a second share");
    // The refusals are uniform and pre-OS: the journal — the mock's
    // whole observable effect — must show the sheet was never asked
    // for. open_url's rejected-scheme rule.
    try std.testing.expectError(error.EmptyText, share.show(&app, ""));
    const over = [_]u8{'x'} ** (share.max_text_bytes + 1);
    try std.testing.expectError(error.TextTooLarge, share.show(&app, &over));
    // Exactly at the cap is legal — the cap is a bound, not a fence.
    const at = [_]u8{'y'} ** share.max_text_bytes;
    try share.show(&app, &at);

    const shown = app.services.share.shares();
    try std.testing.expectEqual(3, shown.len);
    try std.testing.expectEqualStrings("Look at this: https://example.com/n/42", shown[0]);
    try std.testing.expectEqualStrings("a second share", shown[1]);
    try std.testing.expectEqual(share.max_text_bytes, shown[2].len);
}

test "share: a sheetless boot answers available false, show is Unavailable, and nothing journals" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        // The Linux desktop, or a browser without navigator.share.
        .services = .{ .share = .mock(.{ .available = false }) },
    });
    defer app.deinit();

    try std.testing.expect(!share.available(&app));
    try std.testing.expectError(error.Unavailable, share.show(&app, "nowhere to go"));
    // The pure checks still run first, identically — EmptyText on a
    // sheetless target too, so the error means one thing everywhere.
    try std.testing.expectError(error.EmptyText, share.show(&app, ""));
    try std.testing.expectEqual(0, app.services.share.shares().len);
}

test "capstone: two apps, two threads, interleaved service traffic, disjoint by construction" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var a: Session = .{ .gpa = gpa, .tag = 1, .rounds = 24 };
    var b: Session = .{ .gpa = gpa, .tag = 2, .rounds = 24 };

    const ta = try std.Thread.spawn(.{}, Session.run, .{&a});
    const tb = try std.Thread.spawn(.{}, Session.run, .{&b});
    ta.join();
    tb.join();

    if (a.failed) |e| return e;
    if (b.failed) |e| return e;
}
