//! secure_store service tests: the contract driven through the
//! per-app Fake — the only store that exists under `zig test`, on
//! every platform, so what holds here is the whole consumer surface.
//! docs/internals/secure_store.md is the contract held here.

const std = @import("std");
const secure_store = @import("secure_store.zig");
const app_mod = @import("../../core/app.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;
const Fake = secure_store.Fake;
const Harness = harness_mod.Harness;
const diag = harness_mod.diag;

fn testApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{ .viewport = .{ .w = 320, .h = 240 }, .services = .mocks() });
}

/// A bare non-harness test's whole setup: one app, whose construction
/// already carries its own fake — no install, no registry, no pairing;
/// `fake` aliases the app-owned store (heap, so it survives the
/// by-value move out of init).
const Bare = struct {
    app: App,
    fake: *Fake,

    fn init(gpa: std.mem.Allocator) !Bare {
        const app = try testApp(gpa);
        return .{ .app = app, .fake = app.services.secure_store.state.? };
    }

    fn deinit(self: *Bare) void {
        self.app.deinit();
    }
};

test "validKey: 1..128 of [a-z0-9._-], nothing else" {
    try std.testing.expect(secure_store.validKey("a"));
    try std.testing.expect(secure_store.validKey("auth.token"));
    try std.testing.expect(secure_store.validKey("k-2_x.9"));
    try std.testing.expect(secure_store.validKey("a" ** 128));
    try std.testing.expect(!secure_store.validKey(""));
    try std.testing.expect(!secure_store.validKey("a" ** 129));
    // Uppercase is out because CredMan target lookup is
    // case-insensitive — "Token" and "token" would alias on Windows.
    try std.testing.expect(!secure_store.validKey("Token"));
    try std.testing.expect(!secure_store.validKey("has space"));
    try std.testing.expect(!secure_store.validKey("sla/sh"));
    try std.testing.expect(!secure_store.validKey("ünïcode"));
}

test "caps hold organically: InvalidKey and ValueTooLarge are argument errors" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;

    try std.testing.expectError(error.InvalidKey, secure_store.get(&t.app, "Bad Key!", &buf));
    try std.testing.expectError(error.InvalidKey, secure_store.set(&t.app, "", "v"));
    try std.testing.expectError(error.InvalidKey, secure_store.delete(&t.app, "a" ** 129));

    const too_large = "x" ** (secure_store.max_value_bytes + 1);
    try std.testing.expectError(error.ValueTooLarge, secure_store.set(&t.app, "k", too_large));
    // Exactly at the cap is in contract.
    try secure_store.set(&t.app, "k", too_large[0..secure_store.max_value_bytes]);
    try std.testing.expectEqual(secure_store.max_value_bytes, (try secure_store.get(&t.app, "k", &buf)).?.len);
}

test "design proof: the value ceiling is a platform's number, the entry cap is nokre's" {
    // 2560 is not a round number by choice: it is exactly Windows'
    // CRED_MAX_CREDENTIAL_BLOB_SIZE, the tightest bound any linked
    // backend imposes on a value. windows.c `#error`s if the C copy
    // ever drifts off it; this pins the Zig half of the same fact, so
    // a number changed here has to be argued against the platform that
    // set it (docs/services.md's per-platform table).
    try std.testing.expectEqual(5 * 512, secure_store.max_value_bytes);

    // The entry cap answers to no platform — no backend counts entries
    // — so what makes it a number at all is the caller-owned buffer a
    // listing lands in: ListBuf holds exactly one full store of
    // longest-legal keys, and the test below spends it.
    const lb: secure_store.ListBuf = undefined;
    try std.testing.expectEqual(secure_store.max_entries * secure_store.max_key_bytes, lb.bytes.len);
    try std.testing.expectEqual(secure_store.max_entries, lb.slices.len);
}

test "the caps fit the caller's buffers: a full store of longest keys and largest values" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;
    var lb: secure_store.ListBuf = undefined;

    // Every key the longest legal one, distinct by its tail, and every
    // value the largest legal one: the store at its worst case, which
    // is the case the two buffers are sized for.
    var key_buf: [secure_store.max_key_bytes]u8 = undefined;
    const value = "v" ** secure_store.max_value_bytes;
    for (0..secure_store.max_entries) |i| {
        @memset(&key_buf, 'k');
        _ = try std.fmt.bufPrint(key_buf[key_buf.len - 3 ..], "{d:0>3}", .{i});
        try secure_store.set(&t.app, &key_buf, value);
    }
    try std.testing.expectError(error.StoreFull, secure_store.set(&t.app, "over", "v"));

    const keys = try secure_store.list(&t.app, &lb);
    try std.testing.expectEqual(secure_store.max_entries, keys.len);
    for (keys, 0..) |k, i| {
        try std.testing.expectEqual(secure_store.max_key_bytes, k.len);
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, keys[i - 1], k));
    }
    // And a largest-legal value round-trips through ValueBuf.
    try std.testing.expectEqualStrings(value, (try secure_store.get(&t.app, keys[0], &buf)).?);
}

test "absence is null; an empty value is present and empty" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;

    try std.testing.expectEqual(null, try secure_store.get(&t.app, "flag", &buf));
    try secure_store.set(&t.app, "flag", "");
    const value = (try secure_store.get(&t.app, "flag", &buf)).?;
    try std.testing.expectEqualStrings("", value);
}

test "delete is idempotent: the postcondition, not the transition" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;

    try secure_store.delete(&t.app, "never.was"); // absent -> success
    try secure_store.set(&t.app, "token", "tk");
    try secure_store.delete(&t.app, "token");
    try secure_store.delete(&t.app, "token"); // sign-out-twice costs nothing
    try std.testing.expectEqual(null, try secure_store.get(&t.app, "token", &buf));
}

test "set upserts — never StoreFull on an existing key; the one past the cap fails" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;

    var name_buf: [8]u8 = undefined;
    for (0..secure_store.max_entries) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "k{d:0>3}", .{i});
        try t.fake.seed(name, "v");
    }
    try secure_store.set(&t.app, "k000", "rewritten"); // full store, existing key: fine
    try std.testing.expectEqualStrings("rewritten", (try secure_store.get(&t.app, "k000", &buf)).?);
    try std.testing.expectError(error.StoreFull, secure_store.set(&t.app, "over", "v"));
    try secure_store.delete(&t.app, "k000");
    try secure_store.set(&t.app, "over", "v"); // room again
    try std.testing.expectEqual(secure_store.max_entries, t.fake.count());
}

test "the cap holds when the store is filled through set alone" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();

    // Filled through the verb, not seeded: the count the cap consults
    // must track the app's own writes exactly — 65th insert refused,
    // room again the moment a delete lands.
    var name_buf: [8]u8 = undefined;
    for (0..secure_store.max_entries) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "k{d:0>3}", .{i});
        try secure_store.set(&t.app, name, "v");
    }
    try std.testing.expectError(error.StoreFull, secure_store.set(&t.app, "over", "v"));
    try secure_store.delete(&t.app, "k010");
    try secure_store.set(&t.app, "over", "v");
    try std.testing.expectEqual(secure_store.max_entries, t.fake.count());
}

test "list is bytewise ascending; an empty store lists empty" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var lb: secure_store.ListBuf = undefined;

    try std.testing.expectEqual(0, (try secure_store.list(&t.app, &lb)).len);

    // Bytewise, not human-numeric: "a10" sorts before "a2".
    try secure_store.set(&t.app, "z", "1");
    try secure_store.set(&t.app, "a2", "2");
    try secure_store.set(&t.app, "a10", "3");
    try secure_store.set(&t.app, "b", "4");
    const keys = try secure_store.list(&t.app, &lb);
    try std.testing.expectEqual(4, keys.len);
    const expected = [_][]const u8{ "a10", "a2", "b", "z" };
    for (expected, keys) |e, k| try std.testing.expectEqualStrings(e, k);
    // The fake's inspection view shows the app's exact list order.
    for (expected, t.fake.keys()) |e, k| try std.testing.expectEqualStrings(e, k);
}

test "journal: program order, validation failures excluded, knob failures included" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;
    var lb: secure_store.ListBuf = undefined;

    // Seeding is the test's move, not the app's — never journaled.
    try t.fake.seed("boot.token", "tk");
    try std.testing.expectEqual(0, t.fake.journal().len);

    // InvalidKey / ValueTooLarge never reach the store on any
    // platform, so they leave no journal entry either.
    try std.testing.expectError(error.InvalidKey, secure_store.get(&t.app, "NOPE", &buf));
    try std.testing.expectError(error.ValueTooLarge, secure_store.set(&t.app, "k", "x" ** (secure_store.max_value_bytes + 1)));
    try std.testing.expectEqual(0, t.fake.journal().len);

    _ = try secure_store.get(&t.app, "boot.token", &buf);
    try secure_store.set(&t.app, "k", "v");
    try secure_store.delete(&t.app, "boot.token");
    _ = try secure_store.list(&t.app, &lb);

    // A knob-failed call reached the store and is on the record.
    t.fake.fail_next = 1;
    try std.testing.expectError(error.Unavailable, secure_store.set(&t.app, "k", "v2"));

    const ops = t.fake.journal();
    try std.testing.expectEqual(5, ops.len);
    try std.testing.expectEqualStrings("boot.token", ops[0].get);
    try std.testing.expectEqualStrings("k", ops[1].set.key);
    try std.testing.expectEqualStrings("v", ops[1].set.value);
    try std.testing.expectEqualStrings("boot.token", ops[2].delete);
    try std.testing.expect(ops[3] == .list);
    try std.testing.expectEqualStrings("v2", ops[4].set.value);

    t.fake.clearJournal();
    try std.testing.expectEqual(0, t.fake.journal().len);
}

test "a StoreFull set reached the store: journaled, and nothing was written" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();

    var name_buf: [8]u8 = undefined;
    for (0..secure_store.max_entries) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "k{d:0>3}", .{i});
        try t.fake.seed(name, "v");
    }
    try std.testing.expectError(error.StoreFull, secure_store.set(&t.app, "over", "v"));
    try std.testing.expectEqual(1, t.fake.journal().len);
    try std.testing.expectEqual(null, t.fake.peek("over"));
}

test "availability knobs: available, fail_writes, fail_next" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;
    var lb: secure_store.ListBuf = undefined;

    try t.fake.seed("k", "v");

    t.fake.available = false; // the whole store is down
    try std.testing.expectError(error.Unavailable, secure_store.get(&t.app, "k", &buf));
    try std.testing.expectError(error.Unavailable, secure_store.set(&t.app, "k", "v"));
    try std.testing.expectError(error.Unavailable, secure_store.delete(&t.app, "k"));
    try std.testing.expectError(error.Unavailable, secure_store.list(&t.app, &lb));
    t.fake.available = true;

    t.fake.fail_writes = true; // reads fine, writes refused
    try std.testing.expectEqualStrings("v", (try secure_store.get(&t.app, "k", &buf)).?);
    try std.testing.expectEqual(1, (try secure_store.list(&t.app, &lb)).len);
    try std.testing.expectError(error.Unavailable, secure_store.set(&t.app, "k", "v2"));
    try std.testing.expectError(error.Unavailable, secure_store.delete(&t.app, "k"));
    try std.testing.expectEqualStrings("v", t.fake.peek("k").?); // nothing moved
    t.fake.fail_writes = false;

    t.fake.fail_next = 2; // a transient outage, exactly two calls wide
    try std.testing.expectError(error.Unavailable, secure_store.get(&t.app, "k", &buf));
    try std.testing.expectError(error.Unavailable, secure_store.set(&t.app, "k", "v2"));
    try secure_store.set(&t.app, "k", "v3"); // the outage cleared itself
    try std.testing.expectEqualStrings("v3", t.fake.peek("k").?);
}

test "design proof: only Unavailable is injectable" {
    const gpa = std.testing.allocator;
    var t = try Bare.init(gpa);
    defer t.deinit();
    var buf: secure_store.ValueBuf = undefined;

    // The other three names are pure functions of the arguments and
    // the caps — produced by passing such arguments, knobs untouched
    // (the caps test, the StoreFull test). The knobs are two bools and
    // a counter; every one of them yields exactly error.Unavailable —
    // there is no callback, no error picker, nothing else to inject.
    try std.testing.expect(t.fake.available and !t.fake.fail_writes and t.fake.fail_next == 0);
    try std.testing.expectError(error.InvalidKey, secure_store.get(&t.app, "Bad Key!", &buf));
    t.fake.fail_next = 1;
    _ = secure_store.get(&t.app, "k", &buf) catch |e| {
        try std.testing.expectEqual(error.Unavailable, e);
        return;
    };
    return error.TestUnexpectedResult;
}

test "two apps, two fakes: disjoint entries, journals, and knobs" {
    const gpa = std.testing.allocator;
    var a = try Bare.init(gpa);
    defer a.deinit();
    var b = try Bare.init(gpa);
    defer b.deinit();
    var buf: secure_store.ValueBuf = undefined;

    try secure_store.set(&a.app, "shared.name", "from-a");
    b.fake.available = false;
    // b's locked store neither sees a's entry nor blocks a's calls.
    try std.testing.expectError(error.Unavailable, secure_store.get(&b.app, "shared.name", &buf));
    try std.testing.expectEqualStrings("from-a", (try secure_store.get(&a.app, "shared.name", &buf)).?);
    try std.testing.expectEqual(null, b.fake.peek("shared.name"));
    try std.testing.expectEqual(2, a.fake.journal().len);
    try std.testing.expectEqual(1, b.fake.journal().len);
}

test "construction is the binding: mock seeds and knobs arrive with the app" {
    const gpa = std.testing.allocator;
    var buf: secure_store.ValueBuf = undefined;

    // Seeds apply inside App.init — a boot-time read sees them
    // synchronously, no harness required.
    var seeded = try App.init(gpa, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .secure_store = .mock(.{
            .seeds = &.{.{ .key = "auth.token", .value = "tk" }},
        }) },
    });
    defer seeded.deinit();
    try std.testing.expectEqualStrings("tk", (try secure_store.get(&seeded, "auth.token", &buf)).?);

    // A locked keychain is boot state too.
    var locked = try App.init(gpa, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .secure_store = .mock(.{ .available = false }) },
    });
    defer locked.deinit();
    try std.testing.expectError(error.Unavailable, secure_store.get(&locked, "auth.token", &buf));
}

// ---- the harness surface (docs/testing.md "The store") ----

/// The docs' session scenario, workable: a boot read inside build, a
/// sign-out that deletes, a sign-in against a locked keychain that
/// degrades instead of failing the session.
const SessionCtx = struct {
    app: *App = undefined,
    booted: bool = false,
    signed_in: bool = false,
    save_failed: bool = false,

    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *SessionCtx = @ptrCast(@alignCast(ctx.?));
        if (!self.booted) {
            // The boot read is one sync call inside build — no
            // handshake, no loading frame to retire.
            var buf: secure_store.ValueBuf = undefined;
            self.signed_in = (try secure_store.get(app, "auth.token", &buf)) != null;
            self.booted = true;
        }
        const root = app.tree.rootId();
        if (self.signed_in) {
            _ = try app.tree.append(root, .{ .heading = .{ .content = "Inbox", .level = .h1 } });
            if (self.save_failed) {
                _ = try app.tree.append(root, .{ .text = .{ .content = "Signed in — couldn't save your session" } });
            }
            _ = try app.tree.append(root, .{ .button = .{ .label = "Sign out", .on_press = .{ .ctx = self, .call = onSignOut } } });
        } else {
            _ = try app.tree.append(root, .{ .heading = .{ .content = "Welcome", .level = .h1 } });
            _ = try app.tree.append(root, .{ .button = .{ .label = "Sign in", .on_press = .{ .ctx = self, .call = onSignIn } } });
        }
    }

    fn rebuild(self: *SessionCtx) void {
        self.app.tree.clearChildren(self.app.tree.rootId()) catch return;
        self.app.focused = null;
        build(self, self.app) catch {};
        self.app.invalidate();
    }

    fn onSignOut(ctx: ?*anyopaque) void {
        const self: *SessionCtx = @ptrCast(@alignCast(ctx.?));
        self.signed_in = false;
        self.save_failed = false;
        // Idempotent delete: nothing to check, the postcondition holds.
        secure_store.delete(self.app, "auth.token") catch {};
        self.rebuild();
    }

    fn onSignIn(ctx: ?*anyopaque) void {
        const self: *SessionCtx = @ptrCast(@alignCast(ctx.?));
        self.signed_in = true;
        secure_store.set(self.app, "auth.token", "tk_456") catch {
            // The session lives in memory either way; only
            // reload-survival is lost, and the user is told.
            self.save_failed = true;
        };
        self.rebuild();
    }
};

test "harness: stored token skips sign-in; sign-out deletes it; locked keychain degrades" {
    var state: SessionCtx = .{};
    var h = try Harness.initWithStore(std.testing.allocator, .{ .w = 480, .h = 640 }, .{
        .seeds = &.{.{ .key = "auth.token", .value = "tk_123" }},
    }, &state, SessionCtx.build);
    defer h.deinit(); // the fake dies here — nothing leaks to the next test
    // The harness moved out of init by value; handlers hold the app
    // through the ctx, bound here (http_test's pattern).
    state.app = &h.app;

    _ = try h.getByLabel("Inbox"); // boot read is sync: no settle, no loading frame

    try h.tapLabel("Sign out");
    try h.expectStoredAbsent("auth.token"); // the delete really landed
    // one get at boot, one delete — the app never rewrote the secret:
    try std.testing.expectEqual(2, h.store.journal().len);

    try h.lockStore(); // keychain locks mid-session
    try h.tapLabel("Sign in"); // the handler's set fails -> error.Unavailable
    _ = try h.getByLabel("Signed in — couldn't save your session");
    try h.expectStoredAbsent("auth.token"); // and nothing leaked into the store
}

test "harness: initWith boots a routed app reading the seeded store inside its route" {
    const Routed = struct {
        fn home(_: ?*anyopaque, app: *App) anyerror!void {
            var buf: secure_store.ValueBuf = undefined;
            const label: []const u8 = if (try secure_store.get(app, "auth.token", &buf) != null)
                "Signed in"
            else
                "Signed out";
            _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = label, .level = .h1 } });
        }
    };
    var h = try Harness.initWith(std.testing.allocator, .{ .w = 320, .h = 240 }, .{
        .routes = &.{.{ .name = "home", .title = "Home", .build = Routed.home }},
        .initial_route = "home",
        .store = .{ .seeds = &.{.{ .key = "auth.token", .value = "tk" }} },
    });
    defer h.deinit();
    _ = try h.getByLabel("Signed in");
    try h.expectRoute("home");
}

test "harness: initWith refuses an ambiguous shape, loudly" {
    diag.quiet = true;
    defer diag.quiet = false;
    // Neither build nor routes: nothing to boot.
    try std.testing.expectError(error.InitOptionsShape, Harness.initWith(
        std.testing.allocator,
        .{ .w = 320, .h = 240 },
        .{},
    ));
}

test "harness: seedStore, expectStored, expectStoredAbsent" {
    const Minimal = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home", .level = .h1 } });
        }
    };
    var h = try Harness.init(std.testing.allocator, .{ .w = 320, .h = 240 }, null, Minimal.build);
    defer h.deinit();

    try h.expectStoredAbsent("session.id");
    try h.seedStore("session.id", "s-1"); // the token that appears mid-session
    try h.expectStored("session.id", "s-1");

    // What the app writes through the service is what the fake shows.
    try secure_store.set(&h.app, "session.id", "s-2");
    try h.expectStored("session.id", "s-2");

    {
        diag.quiet = true;
        defer diag.quiet = false;
        try std.testing.expectError(error.StoredMismatch, h.expectStored("session.id", "s-1"));
        try std.testing.expectError(error.StoredMismatch, h.expectStored("no.such", "v"));
        try std.testing.expectError(error.UnexpectedlyStored, h.expectStoredAbsent("session.id"));
    }
}
