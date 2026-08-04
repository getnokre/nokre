//! locale service tests: the consumer surface driven through the per-app
//! mock — the only locale source under `zig test`, so what holds here is
//! the whole contract. Two lanes, and their asymmetry is the design: the
//! *read* lane is warm before the first `build` and needs nothing
//! registered, the *change* lane is opt-in. docs/services.md is the
//! contract held here; the l10n bridge it exists for is the last test.

const std = @import("std");
const locale = @import("locale.zig");
const l10n = @import("../../l10n/l10n.zig");
const app_mod = @import("../../core/app.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;
const Harness = harness_mod.Harness;

fn testApp(gpa: std.mem.Allocator, boot: []const u8) !App {
    return App.init(gpa, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .locale = .mock(.{ .tag = boot }) },
    });
}

// ---- the read lane: a value, not an event ----

const BootReader = struct {
    tag: [locale.max_tag_bytes]u8 = undefined,
    len: usize = 0,
    builds: u32 = 0,

    /// Reads the device tag where a real app reads it — inside `build`,
    /// on the first frame, with nothing registered and nothing awaited.
    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *BootReader = @ptrCast(@alignCast(ctx.?));
        const t = locale.tag(app);
        @memcpy(self.tag[0..t.len], t);
        self.len = t.len;
        self.builds += 1;
        try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home" } });
    }

    fn seen(self: *const BootReader) []const u8 {
        return self.tag[0..self.len];
    }
};

test "the boot tag is readable inside the first build" {
    var ctx: BootReader = .{};
    var t = try Harness.initWith(std.testing.allocator, .{ .w = 320, .h = 480 }, .{
        .ctx = &ctx,
        .build = BootReader.build,
        .locale = .{ .tag = "fa-IR" },
    });
    defer t.deinit();

    // The whole promise of installing in App.init: the first frame is a
    // real frame, never a "loading the locale" one — nokre has no
    // ticker that could retire such a frame.
    try std.testing.expectEqual(@as(u32, 1), ctx.builds);
    try std.testing.expectEqualStrings("fa-IR", ctx.seen());
    try std.testing.expectEqualStrings("fa-IR", t.deviceLocale());
}

test "an app that registers no handler still reads the boot tag" {
    var app = try testApp(std.testing.allocator, "de-CH");
    defer app.deinit();

    // The change lane is optional: reading is not subscribing.
    try std.testing.expect(!app.services.locale.hasHandler());
    try std.testing.expectEqualStrings("de-CH", locale.tag(&app));
    // Journaled all the same, so "the app booted with no locale" and
    // "the app booted with this one" are distinguishable after the fact.
    const seen = app.services.locale.seen();
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("de-CH", seen[0]);
}

test "an absent platform locale is the empty tag, and is still a boot report" {
    var app = try testApp(std.testing.allocator, "");
    defer app.deinit();

    try std.testing.expectEqualStrings("", locale.tag(&app));
    // Empty is a value, not a hole: the journal has an entry, and
    // `resolve("")` is the bundle's template (the capstone below).
    try std.testing.expectEqual(@as(usize, 1), app.services.locale.seen().len);
}

// ---- the change lane ----

const Recorder = struct {
    count: u32 = 0,
    thread: ?std.Thread.Id = null,
    last: [locale.max_tag_bytes]u8 = undefined,
    last_len: usize = 0,

    fn onLocale(ctx: ?*anyopaque, tag: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        self.thread = std.Thread.getCurrentId();
        @memcpy(self.last[0..tag.len], tag);
        self.last_len = tag.len;
    }

    fn lastTag(self: *const Recorder) []const u8 {
        return self.last[0..self.last_len];
    }
};

test "a locale change calls the handler once, on this thread, and updates the cache" {
    var app = try testApp(std.testing.allocator, "en-US");
    defer app.deinit();

    var rec: Recorder = .{};
    locale.setHandler(&app, &rec, Recorder.onLocale);
    // Registering does not replay the boot tag: that was never a change.
    try std.testing.expectEqual(@as(u32, 0), rec.count);

    app.services.locale.change("fa-IR");
    try std.testing.expectEqual(@as(u32, 1), rec.count);
    try std.testing.expectEqualStrings("fa-IR", rec.lastTag());
    // Delivery is synchronous on the caller's thread — the shell's
    // main-thread promise, so a handler may touch the app directly.
    try std.testing.expectEqual(std.Thread.getCurrentId(), rec.thread.?);
    // The handler's argument and the cache are the same answer.
    try std.testing.expectEqualStrings("fa-IR", locale.tag(&app));
}

test "setHandler replaces the previous handler" {
    var app = try testApp(std.testing.allocator, "en");
    defer app.deinit();

    var first: Recorder = .{};
    var second: Recorder = .{};
    locale.setHandler(&app, &first, Recorder.onLocale);
    locale.setHandler(&app, &second, Recorder.onLocale);
    app.services.locale.change("ja-JP");
    // Handlers do not stack, so a `build` that re-registers every frame
    // is idempotent rather than a fan-out.
    try std.testing.expectEqual(@as(u32, 0), first.count);
    try std.testing.expectEqual(@as(u32, 1), second.count);
}

test "a change before any handler still lands in the cache and the journal" {
    var app = try testApp(std.testing.allocator, "en-US");
    defer app.deinit();

    // The OS can change the locale before the first `build` has wired
    // anything to it (deep_link's launch-URL window). Nothing runs, but
    // the value is not lost — the next read sees it.
    app.services.locale.change("ar-EG");
    try std.testing.expectEqualStrings("ar-EG", locale.tag(&app));
    try std.testing.expectEqual(@as(usize, 2), app.services.locale.seen().len);

    var rec: Recorder = .{};
    locale.setHandler(&app, &rec, Recorder.onLocale);
    // No replay: only changes from here on reach the handler.
    try std.testing.expectEqual(@as(u32, 0), rec.count);
    app.services.locale.change("he-IL");
    try std.testing.expectEqual(@as(u32, 1), rec.count);
    try std.testing.expectEqualStrings("he-IL", rec.lastTag());
}

// ---- the cap ----

test "a tag over the cap becomes empty, never a prefix that resolves wrong" {
    var app = try testApp(std.testing.allocator, "fa-IR");
    defer app.deinit();

    var rec: Recorder = .{};
    locale.setHandler(&app, &rec, Recorder.onLocale);

    // Exactly at the cap still fits — the boundary is inclusive.
    const at_cap = "de-DE-u-" ++ ("x" ** (locale.max_tag_bytes - 8));
    try std.testing.expectEqual(locale.max_tag_bytes, at_cap.len);
    app.services.locale.change(at_cap);
    try std.testing.expectEqualStrings(at_cap, locale.tag(&app));

    // One byte over drops the whole tag. Truncating would leave
    // "fa-IR-…"-shaped bytes that `resolve` happily matches, shipping a
    // language nobody chose; "" resolves to the bundle's template.
    const over_cap = at_cap ++ "x";
    app.services.locale.change(over_cap);
    try std.testing.expectEqualStrings("", locale.tag(&app));
    // The handler and the journal report the effective tag, not the
    // argument — a test cannot be fooled into asserting a value the app
    // could never have read.
    try std.testing.expectEqualStrings("", rec.lastTag());
    const seen = app.services.locale.seen();
    try std.testing.expectEqualStrings("", seen[seen.len - 1]);
}

// ---- per-app state ----

test "two apps carry disjoint locales by construction" {
    var a = try testApp(std.testing.allocator, "fa-IR");
    defer a.deinit();
    var b = try testApp(std.testing.allocator, "en-GB");
    defer b.deinit();

    var ra: Recorder = .{};
    var rb: Recorder = .{};
    locale.setHandler(&a, &ra, Recorder.onLocale);
    locale.setHandler(&b, &rb, Recorder.onLocale);

    try std.testing.expectEqualStrings("fa-IR", locale.tag(&a));
    try std.testing.expectEqualStrings("en-GB", locale.tag(&b));

    a.services.locale.change("ar-EG");
    // Nothing global to leak through: b's tag, journal, and handler are
    // untouched by a's change.
    try std.testing.expectEqualStrings("ar-EG", locale.tag(&a));
    try std.testing.expectEqualStrings("en-GB", locale.tag(&b));
    try std.testing.expectEqual(@as(u32, 1), ra.count);
    try std.testing.expectEqual(@as(u32, 0), rb.count);
    try std.testing.expectEqual(@as(usize, 2), a.services.locale.seen().len);
    try std.testing.expectEqual(@as(usize, 1), b.services.locale.seen().len);
}

// ---- the capstone: a device tag through l10n and onto the screen ----

const en_arb =
    \\{
    \\  "@@locale": "en",
    \\  "appTitle": "Notes"
    \\}
;

const fa_arb =
    \\{
    \\  "@@locale": "fa",
    \\  "appTitle": "یادداشت‌ها"
    \\}
;

const Strings = l10n.Bundle(&.{ en_arb, fa_arb });

const Screen = struct {
    app: ?*App = null,
    locale: Strings.Locale = .en,

    /// The whole reason the service exists, in the three lines a
    /// consumer writes: resolve the device tag against the bundle, mirror
    /// the chrome to match, render the resolved catalog.
    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        self.locale = Strings.resolve(locale.tag(app));
        app.setDirection(Strings.dir(self.locale));
        try app.tree.append(app.tree.rootId(), .{
            .heading = .{ .content = Strings.tr(self.locale, .appTitle) },
        });
        locale.setHandler(app, ctx, onLocale);
    }

    /// The change lane doing the same work again. The service does not
    /// invalidate for us — what a new locale means is the app's call.
    fn onLocale(ctx: ?*anyopaque, tag: []const u8) void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        self.locale = Strings.resolve(tag);
        const app = self.app orelse return;
        app.setDirection(l10n.directionOfTag(tag));
    }
};

test "capstone: the device tag resolves the bundle and mirrors the chrome" {
    var ctx: Screen = .{};
    var t = try Harness.initWith(std.testing.allocator, .{ .w = 320, .h = 480 }, .{
        .ctx = &ctx,
        .build = Screen.build,
        .locale = .{ .tag = "fa-IR" },
    });
    defer t.deinit();
    ctx.app = &t.app;

    // The device said fa-IR; the bundle has no fa-IR, so the bare
    // language wins and the Persian catalog is what a screen reader
    // reads back.
    try std.testing.expectEqual(Strings.Locale.fa, ctx.locale);
    _ = try t.getByLabel("یادداشت‌ها");
    try std.testing.expectEqual(l10n.Direction.rtl, t.app.direction);

    // The OS switches to a language the bundle does not carry: the
    // template answers, and the chrome un-mirrors with it.
    try t.changeLocale("de-DE");
    try std.testing.expectEqual(Strings.Locale.en, ctx.locale);
    try std.testing.expectEqual(l10n.Direction.ltr, t.app.direction);

    // And the "this platform has no locale" case is the same path, not a
    // special one: "" resolves to the template, `directionOfTag("")` is
    // .ltr — the reason the service never invents "en".
    try t.changeLocale("");
    try std.testing.expectEqual(Strings.Locale.en, ctx.locale);
    try std.testing.expectEqual(l10n.Direction.ltr, t.app.direction);

    // Every tag the device ever reported, boot first.
    const seen = t.localesSeen();
    try std.testing.expectEqual(@as(usize, 3), seen.len);
    try std.testing.expectEqualStrings("fa-IR", seen[0]);
    try std.testing.expectEqualStrings("de-DE", seen[1]);
    try std.testing.expectEqualStrings("", seen[2]);
}

test "the cap is the documented one" {
    // RFC 5646 puts no useful bound on a tag; 64 is the service's, and
    // the mock truncates by exactly the same rule as the platform.
    try std.testing.expectEqual(@as(usize, 64), locale.max_tag_bytes);
}
