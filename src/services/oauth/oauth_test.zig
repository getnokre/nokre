//! oauth service tests: the consumer surface driven through the per-app
//! mock — the only browser under `zig test`, so what holds here is the
//! whole contract. docs/services.md is the contract; the design behind
//! it is docs/internals/oauth.md.

const std = @import("std");
const oauth = @import("oauth.zig");
const pkce = @import("pkce.zig");
const app_mod = @import("../../core/app.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;
const Harness = harness_mod.Harness;

fn testApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{ .viewport = .{ .w = 320, .h = 240 }, .services = .mocks() });
}

const Tag = enum { none, callback, cancelled, failure };

/// The flow's landing pad: one result, recorded verbatim.
const Recorder = struct {
    calls: u32 = 0,
    tag: Tag = .none,
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn onResult(ctx: ?*anyopaque, result: oauth.Result) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        switch (result) {
            .callback => |url| {
                self.tag = .callback;
                self.take(url);
            },
            .cancelled => {
                self.tag = .cancelled;
                self.len = 0;
            },
            .failure => |f| {
                self.tag = .failure;
                self.take(f.name);
            },
        }
    }

    fn take(self: *Recorder, bytes: []const u8) void {
        self.len = @min(bytes.len, self.buf.len);
        @memcpy(self.buf[0..self.len], bytes[0..self.len]);
    }

    fn text(self: *const Recorder) []const u8 {
        return self.buf[0..self.len];
    }
};

fn beginFlow(app: *App, rec: *Recorder) !oauth.Handle {
    var buf: oauth.RedirectBuf = undefined;
    const redirect = try oauth.redirectUri(app, "com.example.notes", &buf);
    return oauth.start(.{
        .app = app,
        .url = "https://accounts.example.com/authorize?client_id=abc",
        .redirect = redirect,
        .ctx = rec,
        .on_result = Recorder.onResult,
    });
}

// ---- redirectUri: the string the authorize URL and the token
// exchange must agree on ----

test "redirectUri is the custom scheme plus the fixed callback path" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var buf: oauth.RedirectBuf = undefined;
    const redirect = try oauth.redirectUri(&app, "com.example.notes", &buf);
    try std.testing.expectEqualStrings("com.example.notes:/callback", redirect);
}

test "redirectUri rejects schemes a platform registration would not accept" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();
    var buf: oauth.RedirectBuf = undefined;

    // Uppercase: legal per RFC 3986 (schemes are case-insensitive) and
    // refused here, because the OS registrations are written lowercase
    // and a mixed-case one works on exactly one platform.
    try std.testing.expectError(error.InvalidScheme, oauth.redirectUri(&app, "Com.Example", &buf));
    // Must start with a letter, and carries no path characters.
    try std.testing.expectError(error.InvalidScheme, oauth.redirectUri(&app, "1notes", &buf));
    try std.testing.expectError(error.InvalidScheme, oauth.redirectUri(&app, "com/example", &buf));
    try std.testing.expectError(error.InvalidScheme, oauth.redirectUri(&app, "", &buf));
    // The legal punctuation of RFC 3986 §3.1 stays legal.
    try std.testing.expectEqualStrings("a+b-c.d:/callback", try oauth.redirectUri(&app, "a+b-c.d", &buf));
}

test "start without a prepared redirect refuses rather than hanging" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    try std.testing.expectError(error.NoRedirect, oauth.start(.{
        .app = &app,
        .url = "https://accounts.example.com/authorize",
        .redirect = "com.example.notes:/callback",
        .ctx = &rec,
        .on_result = Recorder.onResult,
    }));
}

test "start refuses a redirect that is not the prepared one" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var buf: oauth.RedirectBuf = undefined;
    _ = try oauth.redirectUri(&app, "com.example.notes", &buf);
    var rec: Recorder = .{};
    // The authorize URL would have named a redirect the platform never
    // listens on: the flow would hang, so it fails at the call instead.
    try std.testing.expectError(error.RedirectMismatch, oauth.start(.{
        .app = &app,
        .url = "https://accounts.example.com/authorize",
        .redirect = "com.example.other:/callback",
        .ctx = &rec,
        .on_result = Recorder.onResult,
    }));
}

// ---- the flow: park, answer, land on the UI thread ----

test "a completed flow delivers the callback URL, once, at the pump" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    _ = try beginFlow(&app, &rec);
    try std.testing.expect(app.services.oauth.inFlight());
    // Nothing has landed yet: the browser is a test input, and the test
    // decides exactly when it answers.
    try std.testing.expectEqual(@as(u32, 0), rec.calls);

    try app.services.oauth.complete("com.example.notes:/callback?code=xyz&state=s1");
    try std.testing.expectEqual(@as(u32, 0), rec.calls);
    app.runtime.pumpAll();

    try std.testing.expectEqual(@as(u32, 1), rec.calls);
    try std.testing.expectEqual(Tag.callback, rec.tag);
    try std.testing.expectEqualStrings("com.example.notes:/callback?code=xyz&state=s1", rec.text());
    try std.testing.expect(!app.services.oauth.inFlight());
}

test "cancelling is a value, not an error" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    _ = try beginFlow(&app, &rec);
    try app.services.oauth.cancel();
    app.runtime.pumpAll();

    try std.testing.expectEqual(@as(u32, 1), rec.calls);
    try std.testing.expectEqual(Tag.cancelled, rec.tag);
}

test "a failure arrives as a stable name, http's posture" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    _ = try beginFlow(&app, &rec);
    try app.services.oauth.fail("BrowserUnavailable");
    app.runtime.pumpAll();

    try std.testing.expectEqual(Tag.failure, rec.tag);
    try std.testing.expectEqualStrings("BrowserUnavailable", rec.text());
}

test "one flow at a time; the next one starts once the first lands" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    _ = try beginFlow(&app, &rec);
    try std.testing.expectError(error.AuthInFlight, beginFlow(&app, &rec));

    try app.services.oauth.complete("com.example.notes:/callback?code=one");
    app.runtime.pumpAll();
    // The redirect is spent with the flow: a second sign-in prepares its
    // own, which on a loopback platform is a second port.
    _ = try beginFlow(&app, &rec);
    try app.services.oauth.complete("com.example.notes:/callback?code=two");
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 2), rec.calls);
    try std.testing.expectEqualStrings("com.example.notes:/callback?code=two", rec.text());
}

test "the app cancelling means no callback at all" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    const handle = try beginFlow(&app, &rec);
    handle.cancel();
    // The browser answers anyway — a redirect already in flight. The
    // generation check drops it: the app said it was done.
    try std.testing.expectError(error.NoPendingAuth, app.services.oauth.complete("com.example.notes:/callback?code=late"));
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 0), rec.calls);
    // Cancelling twice is a no-op, like every other spent handle.
    handle.cancel();
}

test "a seeded outcome answers every flow without a settle verb" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .oauth = .mock(.{
            .auto = .{ .callback = "com.example.notes:/callback?code=seeded" },
        }) },
    });
    defer app.deinit();

    var rec: Recorder = .{};
    _ = try beginFlow(&app, &rec);
    app.runtime.pumpAll();
    try std.testing.expectEqualStrings("com.example.notes:/callback?code=seeded", rec.text());
}

// ---- the journal: what the app actually asked the browser for ----

test "authorizations journal every start in order, with the URL the app built" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var rec: Recorder = .{};
    var buf: oauth.RedirectBuf = undefined;
    const redirect = try oauth.redirectUri(&app, "com.example.notes", &buf);
    _ = try oauth.start(.{
        .app = &app,
        .url = "https://accounts.example.com/authorize?scope=openid%20email&code_challenge=abc",
        .redirect = redirect,
        .provider = .apple,
        .nonce = "n-1",
        .state = "s-1",
        .ctx = &rec,
        .on_result = Recorder.onResult,
    });

    const journal = app.services.oauth.authorizations();
    try std.testing.expectEqual(@as(usize, 1), journal.len);
    // "the app requested the wrong scopes" and "the app never sent a
    // PKCE challenge" are assertions, not hopes.
    try std.testing.expect(std.mem.indexOf(u8, journal[0].url, "code_challenge=abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, journal[0].url, "scope=openid%20email") != null);
    try std.testing.expectEqualStrings("com.example.notes:/callback", journal[0].redirect);
    try std.testing.expectEqual(oauth.Provider.apple, journal[0].provider);
    try std.testing.expectEqualStrings("n-1", journal[0].nonce);
    try std.testing.expectEqualStrings("s-1", journal[0].state);
}

// ---- param: reading a callback URL without a URL parser ----

test "param reads the query and the fragment, and nothing else" {
    try std.testing.expectEqualStrings("xyz", oauth.param("app:/callback?code=xyz&state=s", "code").?);
    try std.testing.expectEqualStrings("s", oauth.param("app:/callback?code=xyz&state=s", "state").?);
    // The implicit-flow shape: providers that answer on the fragment.
    try std.testing.expectEqualStrings("t", oauth.param("https://app.example/#id_token=t", "id_token").?);
    // A query that ends where the fragment begins.
    try std.testing.expectEqualStrings("q", oauth.param("app:/cb?code=q#frag", "code").?);
    // Absent, empty, and "the name is a prefix of another name" are
    // three different answers.
    try std.testing.expectEqual(@as(?[]const u8, null), oauth.param("app:/cb?code=q", "error"));
    try std.testing.expectEqualStrings("", oauth.param("app:/cb?code=", "code").?);
    try std.testing.expectEqual(@as(?[]const u8, null), oauth.param("app:/cb?codeword=q", "code"));
    try std.testing.expectEqual(@as(?[]const u8, null), oauth.param("app:/cb", "code"));
    // The error case a real callback carries.
    try std.testing.expectEqualStrings("access_denied", oauth.param("app:/cb?error=access_denied", "error").?);
}

// ---- PKCE: seeded under test, so a login screen stays byte-stable ----

test "the verifier and state are the seeds, not randomness" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var vbuf: pkce.VerifierBuf = undefined;
    var sbuf: pkce.StateBuf = undefined;
    const v = pkce.verifier(&app, &vbuf);
    const s = pkce.state(&app, &sbuf);
    try std.testing.expectEqualStrings(oauth.Mock.default_verifier, v);
    try std.testing.expectEqualStrings(oauth.Mock.default_state, s);
    // Twice is the same value — the whole point of the seed.
    var vbuf2: pkce.VerifierBuf = undefined;
    try std.testing.expectEqualStrings(v, pkce.verifier(&app, &vbuf2));
}

test "a seeded verifier overrides the default" {
    var app = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .oauth = .mock(.{ .verifier = "seeded-verifier" }) },
    });
    defer app.deinit();

    var vbuf: pkce.VerifierBuf = undefined;
    try std.testing.expectEqualStrings("seeded-verifier", pkce.verifier(&app, &vbuf));
}

test "challenge is base64url(SHA-256(verifier)), RFC 7636 A.1" {
    // The RFC's own appendix vector, so the encoding is checked against
    // the standard rather than against ourselves.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    var buf: pkce.ChallengeBuf = undefined;
    try std.testing.expectEqualStrings(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        pkce.challenge(verifier, &buf),
    );
    try std.testing.expectEqualStrings("S256", pkce.method);
}

// ---- per-app isolation: two apps, two browsers ----

test "each app carries its own flow" {
    var a = try testApp(std.testing.allocator);
    defer a.deinit();
    var b = try App.init(std.testing.allocator, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .oauth = .mock(.{ .verifier = "b-verifier" }) },
    });
    defer b.deinit();

    var rec_a: Recorder = .{};
    var rec_b: Recorder = .{};
    _ = try beginFlow(&a, &rec_a);
    // b is unaffected by a's live flow: the state is on the App, never
    // in a module-global.
    _ = try beginFlow(&b, &rec_b);

    try b.services.oauth.complete("com.example.notes:/callback?code=b");
    b.runtime.pumpAll();
    a.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 0), rec_a.calls);
    try std.testing.expectEqualStrings("com.example.notes:/callback?code=b", rec_b.text());

    var vbuf: pkce.VerifierBuf = undefined;
    try std.testing.expectEqualStrings("b-verifier", pkce.verifier(&b, &vbuf));
    try std.testing.expectEqualStrings(oauth.Mock.default_verifier, pkce.verifier(&a, &vbuf));
}

test "an app torn down mid-flow drops its callback instead of landing it" {
    var rec: Recorder = .{};
    {
        var app = try testApp(std.testing.allocator);
        defer app.deinit();
        _ = try beginFlow(&app, &rec);
        try app.services.oauth.complete("com.example.notes:/callback?code=x");
        // No pump: the delivery is still queued when the app goes away.
    }
    try std.testing.expectEqual(@as(u32, 0), rec.calls);
}

// ---- the harness verbs (docs/testing.md) ----

const Screen = struct {
    app: *App,
    signed_in: bool = false,
    code_buf: [64]u8 = undefined,
    code_len: usize = 0,

    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        self.app = app;
        const root = app.tree.rootId();
        if (self.signed_in) {
            try app.tree.append(root, .{ .text = .{ .content = self.code_buf[0..self.code_len] } });
        } else {
            try app.tree.append(root, .{ .button = .{
                .label = "Sign in",
                .on_press = .{ .ctx = self, .call = press },
            } });
        }
    }

    fn press(ctx: ?*anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        var buf: oauth.RedirectBuf = undefined;
        const redirect = oauth.redirectUri(self.app, "com.example.notes", &buf) catch return;
        _ = oauth.start(.{
            .app = self.app,
            .url = "https://accounts.example.com/authorize",
            .redirect = redirect,
            .ctx = self,
            .on_result = onResult,
        }) catch return;
    }

    fn rebuild(self: *Screen) void {
        self.app.tree.clearChildren(self.app.tree.rootId()) catch return;
        self.app.focused = null;
        build(self, self.app) catch {};
        self.app.invalidate();
    }

    fn onResult(ctx: ?*anyopaque, result: oauth.Result) void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .callback => |url| {
                const code = oauth.param(url, "code") orelse return;
                self.code_len = @min(code.len, self.code_buf.len);
                @memcpy(self.code_buf[0..self.code_len], code[0..self.code_len]);
                self.signed_in = true;
                self.rebuild();
            },
            else => {},
        }
    }
};

test "harness: tap sign in, complete the auth, assert the screen it produced" {
    var screen: Screen = .{ .app = undefined };
    var t = try Harness.init(std.testing.allocator, .{ .w = 320, .h = 480 }, .{ .ctx = &screen, .build = Screen.build });
    defer t.deinit();
    // The harness moved out of init by value; handlers reach the app
    // through the ctx, bound here (secure_store_test's pattern).
    screen.app = &t.app;

    try t.tapLabel("Sign in");
    try std.testing.expectEqual(@as(usize, 1), t.authorizations().len);
    try t.completeAuth("com.example.notes:/callback?code=granted&state=s");
    // The assertion reads the a11y snapshot: if a screen reader could
    // not perceive the signed-in screen, this could not either.
    _ = try t.getByLabel("granted");
}

test "harness: cancelling leaves the screen where it was" {
    var screen: Screen = .{ .app = undefined };
    var t = try Harness.init(std.testing.allocator, .{ .w = 320, .h = 480 }, .{ .ctx = &screen, .build = Screen.build });
    defer t.deinit();
    // The harness moved out of init by value; handlers reach the app
    // through the ctx, bound here (secure_store_test's pattern).
    screen.app = &t.app;

    try t.tapLabel("Sign in");
    try t.cancelAuth();
    _ = try t.getByLabel("Sign in");
}

test "harness: a named failure is the offline case, one call" {
    var screen: Screen = .{ .app = undefined };
    var t = try Harness.init(std.testing.allocator, .{ .w = 320, .h = 480 }, .{ .ctx = &screen, .build = Screen.build });
    defer t.deinit();
    // The harness moved out of init by value; handlers reach the app
    // through the ctx, bound here (secure_store_test's pattern).
    screen.app = &t.app;

    try t.tapLabel("Sign in");
    try t.failAuth("SessionUnavailable");
    _ = try t.getByLabel("Sign in");
}
