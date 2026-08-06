//! The Zig half of the locale stub's gate: writes one real stub page
//! and, beside it, the answer `L.resolve` gives for every device tag the
//! JavaScript in that page will be asked about.
//!
//! It exists because the stub is the one place in this library where a
//! decision nokre owns has to be *transcribed* into another language.
//! `Bundle.resolve` is comptime Zig; the page that has to make the same
//! decision loads no wasm, on purpose — a redirect that first fetches an
//! app is a redirect nobody waits for. So locale_stub.js repeats the
//! algorithm, and a repeat with no gate under it is two policies waiting
//! to disagree.
//!
//! The shape is `tests/web_services.zig`'s: nothing here asserts
//! anything. It produces the two files, and tests/locale_stub.mjs runs
//! the page's own script against the table — so what is compared is the
//! bytes that ship, not a restatement of them.
//!
//! `zig build test` runs both (build.zig's `addLocaleStubCheck`).

const std = @import("std");
const nok = @import("nokre");

const dom = nok.render.dom;

comptime {
    // A program that links the library owes the hooks a shell owes
    // (docs/testing.md, "Where the harness stops").
    _ = nok.testing.shell;
}

/// **Three locales, and the order of the last two is the point.**
///
/// `resolve`'s three passes are exact tag, then **bare language in
/// bundle order**, then the template. A two-locale `en`/`fa` bundle
/// cannot reach the middle one in any interesting way: no two locales
/// share a language, so its loop has one candidate and `findIndex`,
/// `findLast` and an object's own key order all answer alike. The one
/// branch where the transcription could silently disagree would then be
/// the one branch nothing executes.
///
/// So `fa-AF` is listed **before** `fa`, and a reader asking for
/// `fa-IR` has two candidates and must land on the *earlier* — which is
/// deliberately the answer a JavaScript that scanned backwards, or that
/// preferred the bare tag, would get wrong. Order decides, and nothing
/// else does.
///
/// It is a bundle of its own rather than the web harness's pair: that
/// one is the locale service's gate and is about something else, and
/// giving it a third locale would change a test to serve this one.
/// Here the catalog carries exactly one key, the name each language
/// calls itself — which is what the stub's links say, so the labels
/// below come out of the catalog instead of being typed twice.
const L = nok.l10n.Bundle(&.{
    @embedFile("l10n/stub_en.arb"),
    @embedFile("l10n/stub_fa_AF.arb"),
    @embedFile("l10n/stub_fa.arb"),
});

/// Where the stub's choices point: paths that differ only in their
/// locale segment, which is what the prefix-all scheme produces — and
/// which nokre had no hand in, since the path scheme is the driver's
/// whole.
fn href(loc: L.Locale) []const u8 {
    return switch (loc) {
        .en => "/en/docs/",
        .fa_AF => "/fa-AF/docs/",
        .fa => "/fa/docs/",
    };
}

/// Device tags a browser can report, chosen for every answer `resolve`
/// has and for the seam between them.
///
/// The *expected* answer is deliberately not written here. Whatever
/// `L.resolve` says is the truth this gate holds the JavaScript to, so a
/// change to the resolution rule moves both sides at once and a change
/// to only one of them fails.
const probes = [_][]const u8{
    // Exact, in both cases and both separators.
    "en",
    "fa",
    "fa-AF",
    "FA",
    "EN",
    "fa_AF",
    "FA_af",
    "Fa-Af",
    // Bare-language matches with **two** candidates, where only bundle
    // order can decide and the earlier — `fa-AF` — has to win.
    "fa-IR",
    "fa_IR",
    "fa-Arab",
    "fa-Arab-IR",
    "FA-ir",
    "fa-",
    // Bare-language matches with one candidate, and region and script
    // subtags under the template.
    "en-US",
    "en_GB",
    "en-Latn-US",
    // Languages the bundle does not carry, which are the template.
    "de",
    "de-DE",
    "az-Arab",
    "zh-Hant",
    "pt-BR",
    "eng",
    "f",
    "x",
    // What a browser with nothing to say produces.
    "",
    "-fa",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const page_path = args.next() orelse return error.MissingPageArgument;
    const table_path = args.next() orelse return error.MissingTableArgument;

    var app = try nok.App.init(gpa, .{ .viewport = .{ .w = 1280, .h = 1024 } });
    defer app.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var em: dom.Emitter = .{ .gpa = gpa, .app = &app, .out = &out };
    defer em.deinit();

    try dom.localeStub(&em, L, .{
        .title = "nokre",
        .stylesheet = "/style.css",
        .heading = "Choose a language",
        .choices = .{
            .en = .{ .href = href(.en), .label = L.tr(.en, .language) },
            .fa_AF = .{ .href = href(.fa_AF), .label = L.tr(.fa_AF, .language) },
            .fa = .{ .href = href(.fa), .label = L.tr(.fa, .language) },
        },
    });

    // The table: one row per probe, the href *the bundle* sends that
    // reader to. Both sides read the destination out of `href` above, so
    // nothing here can agree with the page by accident.
    var rows: [probes.len]Row = undefined;
    for (probes, 0..) |tag, i| {
        rows[i] = .{ .language = tag, .href = href(L.resolve(tag)) };
    }

    const locales = comptime std.enums.values(L.Locale);
    var tags: [locales.len][]const u8 = undefined;
    var hrefs: [locales.len][]const u8 = undefined;
    inline for (locales, 0..) |loc, i| {
        tags[i] = comptime L.tag(loc);
        hrefs[i] = href(loc);
    }

    const table = try std.json.Stringify.valueAlloc(gpa, .{
        .tags = tags[0..],
        .hrefs = hrefs[0..],
        .cases = rows[0..],
    }, .{});

    const cwd: std.Io.Dir = .cwd();
    try cwd.writeFile(io, .{ .sub_path = page_path, .data = out.items });
    try cwd.writeFile(io, .{ .sub_path = table_path, .data = table });
}

const Row = struct { language: []const u8, href: []const u8 };
