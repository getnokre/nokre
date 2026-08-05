//! Tests for the l10n bundle: parsing, plural selection across CLDR
//! rule families, select, escaping, resolution, digit shapes, and the
//! buffer contract. Everything a consumer can hit at runtime is here; the
//! compile-time rejections (missing keys, dead plural branches, bad
//! placeholder types) are exercised by their being impossible to write
//! in these bundles — each would fail this file's compilation.

const std = @import("std");
const l10n = @import("l10n.zig");

const en_arb =
    \\{
    \\  "@@locale": "en",
    \\  "@@author": "nokre tests",
    \\  "appTitle": "Notes",
    \\  "@appTitle": { "description": "App bar title" },
    \\  "greeting": "Hello, {name}!",
    \\  "@greeting": {
    \\    "description": "Greets the signed-in user",
    \\    "placeholders": { "name": { "type": "String", "example": "Ada" } }
    \\  },
    \\  "nItems": "{count, plural, =0{no items} one{# item} other{# items}}",
    \\  "@nItems": { "placeholders": { "count": { "type": "num" } } },
    \\  "pronoun": "{gender, select, male{he} female{she} other{they}}",
    \\  "score": "Score: {points}",
    \\  "@score": { "placeholders": { "points": { "type": "int" } } },
    \\  "quoted": "Isn''t this '{'braces'}' fine? # stays",
    \\  "uni": "😀 Á tab\there",
    \\  "farewell": "Bye"
    \\}
;

const fa_arb =
    \\{
    \\  "@@locale": "fa",
    \\  "appTitle": "یادداشت‌ها",
    \\  "greeting": "سلام {name}!",
    \\  "nItems": "{count, plural, one{# مورد} other{# مورد}}",
    \\  "pronoun": "{gender, select, male{او} female{او} other{ایشان}}",
    \\  "score": "امتیاز: {points}",
    \\  "quoted": "بدون نقل‌قول",
    \\  "uni": "سلام",
    \\  "farewell": "خداحافظ"
    \\}
;

const L = l10n.Bundle(&.{ en_arb, fa_arb });

test "tr returns constant message text per locale" {
    try std.testing.expectEqualStrings("Notes", L.tr(.en, .appTitle));
    try std.testing.expectEqualStrings("یادداشت‌ها", L.tr(.fa, .appTitle));
    try std.testing.expectEqualStrings("Bye", L.tr(.en, .farewell));
}

test "fmt substitutes string and int placeholders" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Hello, Ada!",
        try L.fmt(&buf, .en, .greeting, .{ .name = "Ada" }),
    );
    try std.testing.expectEqualStrings(
        "سلام دریوش!",
        try L.fmt(&buf, .fa, .greeting, .{ .name = "دریوش" }),
    );
    try std.testing.expectEqualStrings(
        "Score: -12",
        try L.fmt(&buf, .en, .score, .{ .points = -12 }),
    );
    // The fa catalog shapes its digits — see the digit-shapes section.
    try std.testing.expectEqualStrings(
        "امتیاز: ۴۰۰",
        try L.fmt(&buf, .fa, .score, .{ .points = 400 }),
    );
}

test "plural: exacts beat categories, # renders the count" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "no items",
        try L.fmt(&buf, .en, .nItems, .{ .count = 0 }),
    );
    try std.testing.expectEqualStrings(
        "1 item",
        try L.fmt(&buf, .en, .nItems, .{ .count = 1 }),
    );
    try std.testing.expectEqualStrings(
        "7 items",
        try L.fmt(&buf, .en, .nItems, .{ .count = 7 }),
    );
    // Farsi puts zero in `one`: "۰ مورد" via the one branch, not other.
    try std.testing.expectEqualStrings(
        "۰ مورد",
        try L.fmt(&buf, .fa, .nItems, .{ .count = 0 }),
    );
}

test "negative counts: category from |n|, # renders the sign" {
    var buf: [64]u8 = undefined;
    // ICU selects the category on the absolute value, and `#` writes
    // the count as given — sign included.
    try std.testing.expectEqualStrings(
        "-1 item",
        try L.fmt(&buf, .en, .nItems, .{ .count = -1 }),
    );
    try std.testing.expectEqualStrings(
        "-5 items",
        try L.fmt(&buf, .en, .nItems, .{ .count = -5 }),
    );
}

test "writeDecimal at minInt(i64) does not trap on the unnegatable value" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Score: -9223372036854775808",
        try L.fmt(&buf, .en, .score, .{ .points = @as(i64, std.math.minInt(i64)) }),
    );
}

test "select matches case-sensitively and falls back to other" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "she",
        try L.fmt(&buf, .en, .pronoun, .{ .gender = "female" }),
    );
    try std.testing.expectEqualStrings(
        "they",
        try L.fmt(&buf, .en, .pronoun, .{ .gender = "nonbinary" }),
    );
    try std.testing.expectEqualStrings(
        "they",
        try L.fmt(&buf, .en, .pronoun, .{ .gender = "MALE" }),
    );
}

test "ICU quoting: '' apostrophe, quoted braces, bare # outside plural" {
    try std.testing.expectEqualStrings(
        "Isn't this {braces} fine? # stays",
        L.tr(.en, .quoted),
    );
}

test "JSON escapes: surrogate pairs, \\u, tabs" {
    try std.testing.expectEqualStrings("\u{1F600} A\u{0301} tab\there", L.tr(.en, .uni));
}

test "locale metadata: tag and default" {
    try std.testing.expectEqualStrings("en", L.tag(.en));
    try std.testing.expectEqualStrings("fa", L.tag(.fa));
    try std.testing.expectEqual(L.Locale.en, L.default_locale);
}

test "resolve: exact, separators and case, language, fallback" {
    try std.testing.expectEqual(L.Locale.fa, L.resolve("fa"));
    try std.testing.expectEqual(L.Locale.fa, L.resolve("FA"));
    try std.testing.expectEqual(L.Locale.fa, L.resolve("fa-IR"));
    try std.testing.expectEqual(L.Locale.fa, L.resolve("fa_IR"));
    try std.testing.expectEqual(L.Locale.en, L.resolve("en-GB"));
    try std.testing.expectEqual(L.Locale.en, L.resolve("de"));
    try std.testing.expectEqual(L.Locale.en, L.resolve(""));
}

test "fmt reports NoSpace instead of truncating" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(
        error.NoSpace,
        L.fmt(&buf, .en, .greeting, .{ .name = "Ada" }),
    );
}

// --- writing direction -----------------------------------------------------

test "Bundle.dir reads each locale's direction from its tag" {
    // The en/fa bundle: English is LTR, Persian RTL — the bridge a
    // consumer feeds to App.setDirection(L.dir(loc)).
    try std.testing.expectEqual(l10n.Direction.ltr, L.dir(.en));
    try std.testing.expectEqual(l10n.Direction.rtl, L.dir(.fa));
}

test "directionOfTag: RTL languages, LTR default, script subtag decides" {
    const dir = l10n.directionOfTag;
    // RTL by primary language subtag.
    try std.testing.expectEqual(l10n.Direction.rtl, dir("ar"));
    try std.testing.expectEqual(l10n.Direction.rtl, dir("fa-IR"));
    try std.testing.expectEqual(l10n.Direction.rtl, dir("he"));
    try std.testing.expectEqual(l10n.Direction.rtl, dir("ur_PK"));
    try std.testing.expectEqual(l10n.Direction.rtl, dir("ckb"));
    // Case and separators are ignored, as in resolve.
    try std.testing.expectEqual(l10n.Direction.rtl, dir("FA"));
    // LTR languages and unknown tags default to LTR.
    try std.testing.expectEqual(l10n.Direction.ltr, dir("en"));
    try std.testing.expectEqual(l10n.Direction.ltr, dir("de-DE"));
    try std.testing.expectEqual(l10n.Direction.ltr, dir("zz"));
    try std.testing.expectEqual(l10n.Direction.ltr, dir(""));
    // An explicit script subtag overrides the language default, both ways.
    try std.testing.expectEqual(l10n.Direction.rtl, dir("az-Arab"));
    try std.testing.expectEqual(l10n.Direction.ltr, dir("az-Latn"));
    try std.testing.expectEqual(l10n.Direction.rtl, dir("ku-Arab-IQ"));
    // A region subtag in the script slot is not a script (2 letters).
    try std.testing.expectEqual(l10n.Direction.ltr, dir("en-US"));
}

// --- CLDR rule families ----------------------------------------------------

const ru_arb =
    \\{
    \\  "@@locale": "ru",
    \\  "nBooks": "{count, plural, one{# книга} few{# книги} many{# книг} other{# книги}}"
    \\}
;

const Ru = l10n.Bundle(&.{ru_arb});

test "russian one/few/many across the teens" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1 книга", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 1 }));
    try std.testing.expectEqualStrings("21 книга", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 21 }));
    try std.testing.expectEqualStrings("3 книги", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 3 }));
    try std.testing.expectEqualStrings("102 книги", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 102 }));
    try std.testing.expectEqualStrings("5 книг", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 5 }));
    try std.testing.expectEqualStrings("11 книг", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 11 }));
    try std.testing.expectEqualStrings("111 книг", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 111 }));
    try std.testing.expectEqualStrings("0 книг", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 0 }));
}

const ar_arb =
    \\{
    \\  "@@locale": "ar",
    \\  "nDays": "{count, plural, zero{z} one{o} two{t} few{f} many{m} other{x}}",
    \\  "score": "{points}",
    \\  "@score": { "placeholders": { "points": { "type": "int" } } }
    \\}
;

const Ar = l10n.Bundle(&.{ar_arb});

test "arabic selects all six categories" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("z", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 0 }));
    try std.testing.expectEqualStrings("o", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 1 }));
    try std.testing.expectEqualStrings("t", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 2 }));
    try std.testing.expectEqualStrings("f", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 3 }));
    try std.testing.expectEqualStrings("f", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 103 }));
    try std.testing.expectEqualStrings("m", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 11 }));
    try std.testing.expectEqualStrings("m", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 99 }));
    try std.testing.expectEqualStrings("x", try Ar.fmt(&buf, .ar, .nDays, .{ .count = 100 }));
}

// English `one` is finite ({1}), so `=1` covers it with no `one` branch —
// the same file with a bare `other` only would not compile.
const exact_arb =
    \\{
    \\  "@@locale": "en",
    \\  "nThings": "{count, plural, =1{one thing} other{# things}}"
    \\}
;

const Exact = l10n.Bundle(&.{exact_arb});

test "=N exact coverage satisfies a finite category" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("one thing", try Exact.fmt(&buf, .en, .nThings, .{ .count = 1 }));
    try std.testing.expectEqualStrings("0 things", try Exact.fmt(&buf, .en, .nThings, .{ .count = 0 }));
}

// A select nested in a plural: # still means the enclosing count.
const nested_arb =
    \\{
    \\  "@@locale": "en",
    \\  "owned": "{count, plural, one{{gender, select, male{his # thing} female{her # thing} other{their # thing}}} other{# things}}"
    \\}
;

const Nested = l10n.Bundle(&.{nested_arb});

test "select inside plural keeps # bound to the count" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "her 1 thing",
        try Nested.fmt(&buf, .en, .owned, .{ .count = 1, .gender = "female" }),
    );
    try std.testing.expectEqualStrings(
        "4 things",
        try Nested.fmt(&buf, .en, .owned, .{ .count = 4, .gender = "female" }),
    );
}

// Region-specific plural rules: pt_PT counts like Spanish (1 only),
// pt like French (0..1) — and resolve prefers the exact tag.
const pt_arb =
    \\{
    \\  "@@locale": "pt",
    \\  "n": "{count, plural, one{um} other{#}}"
    \\}
;
const pt_pt_arb =
    \\{
    \\  "@@locale": "pt_PT",
    \\  "n": "{count, plural, one{um} other{#}}"
    \\}
;

const Pt = l10n.Bundle(&.{ pt_arb, pt_pt_arb });

test "pt vs pt_PT rules and resolution" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("um", try Pt.fmt(&buf, .pt, .n, .{ .count = 0 }));
    try std.testing.expectEqualStrings("0", try Pt.fmt(&buf, .pt_PT, .n, .{ .count = 0 }));
    try std.testing.expectEqual(Pt.Locale.pt_PT, Pt.resolve("pt-PT"));
    try std.testing.expectEqual(Pt.Locale.pt, Pt.resolve("pt-BR"));
    try std.testing.expectEqual(Pt.Locale.pt, Pt.resolve("pt"));
}

// Script subtags match only exactly (resolve's doc): a zh bundle that
// cares about Hant lists it, and an unlisted script falls back to the
// bare language, never to a sibling script.
const zh_arb =
    \\{
    \\  "@@locale": "zh",
    \\  "hello": "你好"
    \\}
;
const zh_hant_arb =
    \\{
    \\  "@@locale": "zh_Hant",
    \\  "hello": "你好"
    \\}
;

const Zh = l10n.Bundle(&.{ zh_arb, zh_hant_arb });

test "resolve: script subtag matches exactly, else bare language" {
    try std.testing.expectEqual(Zh.Locale.zh_Hant, Zh.resolve("zh-Hant"));
    try std.testing.expectEqual(Zh.Locale.zh_Hant, Zh.resolve("zh_hant"));
    // The region variant is not the listed script tag: exact match
    // fails, and the bare language wins over the "closer" script.
    try std.testing.expectEqual(Zh.Locale.zh, Zh.resolve("zh-Hant-TW"));
    try std.testing.expectEqual(Zh.Locale.zh, Zh.resolve("zh-CN"));
    try std.testing.expectEqual(Zh.Locale.zh, Zh.resolve("zh"));
}

// --- digit shapes ----------------------------------------------------------
//
// The shapes come from the formatting catalog's locale (its language
// subtag), never from a setting: fa is Extended Arabic-Indic, ar is
// Arabic-Indic, everything else ASCII. These assert exact bytes — the
// digits are weak bidi types, so their on-screen ordering is UAX #9's
// job in core; l10n's whole contract is these bytes in this order.

test "fa catalog renders Extended Arabic-Indic digits, exact bytes" {
    var buf: [64]u8 = undefined;
    const out = try L.fmt(&buf, .fa, .nItems, .{ .count = 3 });
    // U+06F3 is DB B3 in UTF-8 — the literal below is those bytes.
    try std.testing.expectEqualStrings("۳ مورد", out);
    try std.testing.expectEqualStrings("\u{06F3} \u{0645}\u{0648}\u{0631}\u{062F}", out);
}

test "ar catalog renders Arabic-Indic digits, exact bytes" {
    var buf: [16]u8 = undefined;
    // U+0661..U+0664, not U+06F1..: Arabic proper and Persian shape
    // 4, 5, and 6 differently, so the sets must not be conflated.
    try std.testing.expectEqualStrings(
        "\u{0661}\u{0662}\u{0663}\u{0664}",
        try Ar.fmt(&buf, .ar, .score, .{ .points = 1234 }),
    );
}

test "digit shape follows the resolved catalog, not the device tag" {
    // fa-IR resolves to the .fa catalog, and that catalog shapes.
    var buf: [64]u8 = undefined;
    const loc = L.resolve("fa-IR");
    try std.testing.expectEqual(L.Locale.fa, loc);
    try std.testing.expectEqualStrings("۷ مورد", try L.fmt(&buf, loc, .nItems, .{ .count = 7 }));
}

// A region-qualified @@locale shapes by its language subtag alone.
const fa_ir_arb =
    \\{
    \\  "@@locale": "fa_IR",
    \\  "n": "{count, plural, one{#} other{#}}"
    \\}
;

const FaIr = l10n.Bundle(&.{fa_ir_arb});

test "digit shape reads the language subtag: fa_IR shapes like fa" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("۴۲", try FaIr.fmt(&buf, .fa_IR, .n, .{ .count = 42 }));
}

test "everything else stays ASCII: en and ru catalogs are unshaped" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("7 items", try L.fmt(&buf, .en, .nItems, .{ .count = 7 }));
    try std.testing.expectEqualStrings("11 книг", try Ru.fmt(&buf, .ru, .nBooks, .{ .count = 11 }));
}

test "negative counts keep the ASCII sign before shaped digits" {
    var buf: [64]u8 = undefined;
    // Digits are the decided scope; the minus stays '-' in every set.
    try std.testing.expectEqualStrings(
        "-۵ مورد",
        try L.fmt(&buf, .fa, .nItems, .{ .count = -5 }),
    );
    try std.testing.expectEqualStrings(
        "امتیاز: -۹۲۲۳۳۷۲۰۳۶۸۵۴۷۷۵۸۰۸",
        try L.fmt(&buf, .fa, .score, .{ .points = @as(i64, std.math.minInt(i64)) }),
    );
}

// Persian `one` covers 0..1, `other` the rest — distinct branch texts
// make the chosen category observable alongside the shaped count.
const fa_sel_arb =
    \\{
    \\  "@@locale": "fa",
    \\  "n": "{count, plural, one{یک: #} other{چند: #}}"
    \\}
;

const FaSel = l10n.Bundle(&.{fa_sel_arb});

test "plural selection stays numeric; shaping touches output bytes only" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("یک: ۰", try FaSel.fmt(&buf, .fa, .n, .{ .count = 0 }));
    try std.testing.expectEqualStrings("یک: ۱", try FaSel.fmt(&buf, .fa, .n, .{ .count = 1 }));
    try std.testing.expectEqualStrings("چند: ۲", try FaSel.fmt(&buf, .fa, .n, .{ .count = 2 }));
}

// A placeholder declared in metadata but absent from the template text:
// still part of the interface, usable by any locale.
const declared_arb =
    \\{
    \\  "@@locale": "en",
    \\  "saved": "Saved",
    \\  "@saved": { "placeholders": { "name": { "type": "String" } } }
    \\}
;
const declared_de_arb =
    \\{
    \\  "@@locale": "de",
    \\  "saved": "{name} gespeichert"
    \\}
;

const Declared = l10n.Bundle(&.{ declared_arb, declared_de_arb });

test "metadata-declared placeholder is usable by translations only" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Saved",
        try Declared.fmt(&buf, .en, .saved, .{ .name = "x" }),
    );
    try std.testing.expectEqualStrings(
        "Notiz gespeichert",
        try Declared.fmt(&buf, .de, .saved, .{ .name = "Notiz" }),
    );
}

// --- the bound view ---------------------------------------------------------

test "of resolves an app-shaped locale() once into a bound view" {
    // `of` takes anything that answers locale() with a tag — the App in
    // production, this stand-in here — so the pure module stays pure.
    const FakeApp = struct {
        tag: []const u8,
        pub fn locale(self: *const @This()) []const u8 {
            return self.tag;
        }
    };
    var app: FakeApp = .{ .tag = "fa-IR" };
    const b = L.of(&app);
    try std.testing.expectEqual(L.Locale.fa, b.locale);

    // Never-chosen ("") resolves to the template, as resolve documents.
    var fresh: FakeApp = .{ .tag = "" };
    try std.testing.expectEqual(L.Locale.en, L.of(&fresh).locale);
}

test "the bound calls are the unbound calls to the byte" {
    const FakeApp = struct {
        tag: []const u8,
        pub fn locale(self: *const @This()) []const u8 {
            return self.tag;
        }
    };
    var app: FakeApp = .{ .tag = "fa" };
    const b = L.of(&app);
    try std.testing.expectEqualStrings(L.tr(.fa, .appTitle), b.tr(.appTitle));
    try std.testing.expectEqualStrings(L.trAny(.fa, .farewell), b.trAny(.farewell));

    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try L.fmt(&buf1, .fa, .nItems, .{ .count = 3 }),
        try b.fmt(&buf2, .nItems, .{ .count = 3 }),
    );

    const Tree = @import("../core/tree.zig").Tree;
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectEqualStrings(
        try L.fmt(&buf1, .fa, .greeting, .{ .name = "دریوش" }),
        try b.fmtIn(&tree, .greeting, .{ .name = "دریوش" }),
    );
}

// --- trAny ------------------------------------------------------------------

test "trAny answers a runtime key with tr's constant bytes" {
    // Comptime-key parity, both locales, across the paramless keys.
    inline for (.{ .appTitle, .quoted, .uni, .farewell }) |k| {
        try std.testing.expectEqualStrings(L.tr(.en, k), L.trAny(.en, k));
        try std.testing.expectEqualStrings(L.tr(.fa, k), L.trAny(.fa, k));
    }
    // And a key that exists only at runtime — the case tr cannot serve,
    // and the reason the table exists.
    var key: L.Key = .appTitle;
    _ = &key;
    try std.testing.expectEqualStrings("Notes", L.trAny(.en, key));
    try std.testing.expectEqualStrings("یادداشت‌ها", L.trAny(.fa, key));
    // A key with placeholders panics naming itself — the runtime twin
    // of tr's compile error; not exercisable under `zig test`, and the
    // slot being null (never message text) is the table's guarantee.
}

// --- the date placeholder ---------------------------------------------------
//
// The catalogs below carry the exact month words and message shapes the
// two rokovski apps shipped in their hand-written date modules; the
// expected strings are those modules' own test expectations, verbatim —
// the byte-identity this placeholder promised when it subsumed them.

const date_en_arb =
    \\{
    \\  "@@locale": "en",
    \\  "dateLabel": "{when, date, d} {when, date, MMM} {when, date, y}",
    \\  "@dateLabel": {
    \\    "description": "A calendar date, in each locale's own order",
    \\    "placeholders": { "when": { "type": "date" } }
    \\  },
    \\  "cycleLabel": "{when, date, MMM} {when, date, y}",
    \\  "iso": "{when, date, yMd}",
    \\  "numeric": "{when, date, M}/{when, date, d}",
    \\  "monthJan": "Jan", "monthFeb": "Feb", "monthMar": "Mar", "monthApr": "Apr",
    \\  "monthMay": "May", "monthJun": "Jun", "monthJul": "Jul", "monthAug": "Aug",
    \\  "monthSep": "Sep", "monthOct": "Oct", "monthNov": "Nov", "monthDec": "Dec"
    \\}
;

const date_fa_arb =
    \\{
    \\  "@@locale": "fa",
    \\  "dateLabel": "{when, date, d} {when, date, MMM} {when, date, y}",
    \\  "cycleLabel": "{when, date, MMM} {when, date, y}",
    \\  "iso": "{when, date, yMd}",
    \\  "numeric": "{when, date, M}/{when, date, d}",
    \\  "monthJan": "ژانویه", "monthFeb": "فوریه", "monthMar": "مارس", "monthApr": "آوریل",
    \\  "monthMay": "مه", "monthJun": "ژوئن", "monthJul": "ژوئیه", "monthAug": "اوت",
    \\  "monthSep": "سپتامبر", "monthOct": "اکتبر", "monthNov": "نوامبر", "monthDec": "دسامبر"
    \\}
;

const date_tr_arb =
    \\{
    \\  "@@locale": "tr",
    \\  "dateLabel": "{when, date, d} {when, date, MMM} {when, date, y}",
    \\  "cycleLabel": "{when, date, MMM} {when, date, y}",
    \\  "iso": "{when, date, yMd}",
    \\  "numeric": "{when, date, M}/{when, date, d}",
    \\  "monthJan": "Oca", "monthFeb": "Şub", "monthMar": "Mar", "monthApr": "Nis",
    \\  "monthMay": "May", "monthJun": "Haz", "monthJul": "Tem", "monthAug": "Ağu",
    \\  "monthSep": "Eyl", "monthOct": "Eki", "monthNov": "Kas", "monthDec": "Ara"
    \\}
;

const D = l10n.Bundle(&.{ date_en_arb, date_fa_arb, date_tr_arb });

test "dateFromMillis: integer civil math, UTC, floor division before 1970" {
    // The epoch's own day (the org app's test), a leap day, and the
    // instant one millisecond into 2026.
    try std.testing.expectEqual(l10n.Date{ .year = 1970, .month = 1, .day = 1 }, l10n.dateFromMillis(0));
    try std.testing.expectEqual(l10n.Date{ .year = 2024, .month = 2, .day = 29 }, l10n.dateFromMillis(1_709_164_800_000));
    try std.testing.expectEqual(l10n.Date{ .year = 2026, .month = 1, .day = 1 }, l10n.dateFromMillis(1_767_225_600_000));
    // @divFloor, not @divTrunc: the millisecond before the epoch is
    // still the last day of 1969, not a day zero.
    try std.testing.expectEqual(l10n.Date{ .year = 1969, .month = 12, .day = 31 }, l10n.dateFromMillis(-1));
}

test "an instant reads as the calendar date it falls on, per locale" {
    // The org app's own expectations for 2026-01-01, en and tr; the fa
    // line is the user app's dateLabel under the same catalog words.
    var buf: [64]u8 = undefined;
    const when = l10n.dateFromMillis(1_767_225_600_000);
    try std.testing.expectEqualStrings("1 Jan 2026", try D.fmt(&buf, .en, .dateLabel, .{ .when = when }));
    try std.testing.expectEqualStrings("1 Oca 2026", try D.fmt(&buf, .tr, .dateLabel, .{ .when = when }));
    try std.testing.expectEqualStrings("۱ ژانویه ۲۰۲۶", try D.fmt(&buf, .fa, .dateLabel, .{ .when = when }));
}

test "a month-year label takes any year/month/day-shaped value" {
    // The user app's monthly cycle: the domain answers (month, year),
    // and any struct carrying integer year/month/day fields is a date —
    // no conversion ritual between a domain model and its label.
    var buf: [64]u8 = undefined;
    const march = .{ .year = 2026, .month = 3, .day = 1 };
    try std.testing.expectEqualStrings("Mar 2026", try D.fmt(&buf, .en, .cycleLabel, .{ .when = march }));
    try std.testing.expectEqualStrings("Mar 2026", try D.fmt(&buf, .tr, .cycleLabel, .{ .when = march }));
    try std.testing.expectEqualStrings("مارس ۲۰۲۶", try D.fmt(&buf, .fa, .cycleLabel, .{ .when = march }));
}

test "every month has its own word, read through the reserved keys" {
    var buf: [64]u8 = undefined;
    var seen: [12][64]u8 = undefined;
    var lens: [12]usize = undefined;
    for (1..13) |m| {
        const out = try D.fmt(&buf, .tr, .cycleLabel, .{
            .when = l10n.Date{ .year = 2026, .month = @intCast(m), .day = 1 },
        });
        @memcpy(seen[m - 1][0..out.len], out);
        lens[m - 1] = out.len;
    }
    for (0..12) |a| {
        for (0..a) |b| {
            try std.testing.expect(!std.mem.eql(u8, seen[a][0..lens[a]], seen[b][0..lens[b]]));
        }
    }
    // The keys are ordinary messages too: a runtime month indexes a
    // table of keys and trAny reads the word — the pattern that
    // replaced the twelve-arm switches.
    const month_keys = [12]D.Key{
        .monthJan, .monthFeb, .monthMar, .monthApr, .monthMay, .monthJun,
        .monthJul, .monthAug, .monthSep, .monthOct, .monthNov, .monthDec,
    };
    try std.testing.expectEqualStrings("Şub", D.trAny(.tr, month_keys[1]));
    try std.testing.expectEqualStrings("فوریه", D.trAny(.fa, month_keys[1]));
}

test "MMM is total: an out-of-range month reads as December" {
    // The consumer modules mapped `else` to December; the placeholder
    // keeps that totality rather than trapping mid-frame.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Dec 1", try D.fmt(&buf, .en, .cycleLabel, .{
        .when = l10n.Date{ .year = 1, .month = 13, .day = 1 },
    }));
}

test "yMd is ISO 8601, zero-padded, in the catalog's digit shapes" {
    var buf: [64]u8 = undefined;
    const when: l10n.Date = .{ .year = 2026, .month = 1, .day = 2 };
    try std.testing.expectEqualStrings("2026-01-02", try D.fmt(&buf, .en, .iso, .{ .when = when }));
    // Digit shaping is the catalog's, exactly as for counts.
    try std.testing.expectEqualStrings("۲۰۲۶-۰۱-۰۲", try D.fmt(&buf, .fa, .iso, .{ .when = when }));
    // Components stay unpadded — the message owns its separators.
    try std.testing.expectEqualStrings("1/2", try D.fmt(&buf, .en, .numeric, .{ .when = when }));
}

test "date placeholders come out of fmtIn byte-identical to fmt" {
    const Tree = @import("../core/tree.zig").Tree;
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    var buf: [64]u8 = undefined;
    const when = l10n.dateFromMillis(1_767_225_600_000);
    try std.testing.expectEqualStrings(
        try D.fmt(&buf, .fa, .dateLabel, .{ .when = when }),
        try D.fmtIn(&tree, .fa, .dateLabel, .{ .when = when }),
    );
}

// --- reserved chrome keys ---------------------------------------------------
//
// Each key's value is its own name (second locale: prefixed), so a
// crossed wire between a Chrome field and its derived key would name
// itself in the failure. The compile-error side — a catalog *missing*
// a chrome key — cannot be a `zig test` (it is a build failure, which
// is the point); it is the same missing-key diagnostic every other
// catalog error uses, naming the key and the field it serves.

const chrome_en_arb =
    \\{
    \\  "@@locale": "en",
    \\  "chromeBack": "chromeBack", "chromeClose": "chromeClose",
    \\  "chromeSection": "chromeSection", "chromeCurrentScreen": "chromeCurrentScreen",
    \\  "chromeSections": "chromeSections", "chromeNotices": "chromeNotices",
    \\  "chromeShowNotices": "chromeShowNotices", "chromeShowAllNotices": "chromeShowAllNotices",
    \\  "chromeMinimizeNotices": "chromeMinimizeNotices",
    \\  "chromeDismissAllNotices": "chromeDismissAllNotices",
    \\  "chromeOpenPrefix": "chromeOpenPrefix", "chromeDismissPrefix": "chromeDismissPrefix",
    \\  "chromeImportant": "chromeImportant", "chromeOther": "chromeOther",
    \\  "chromeCopied": "chromeCopied", "chromeMore": "chromeMore"
    \\}
;

const chrome_tr_arb =
    \\{
    \\  "@@locale": "tr",
    \\  "chromeBack": "tr-chromeBack", "chromeClose": "tr-chromeClose",
    \\  "chromeSection": "tr-chromeSection", "chromeCurrentScreen": "tr-chromeCurrentScreen",
    \\  "chromeSections": "tr-chromeSections", "chromeNotices": "tr-chromeNotices",
    \\  "chromeShowNotices": "tr-chromeShowNotices", "chromeShowAllNotices": "tr-chromeShowAllNotices",
    \\  "chromeMinimizeNotices": "tr-chromeMinimizeNotices",
    \\  "chromeDismissAllNotices": "tr-chromeDismissAllNotices",
    \\  "chromeOpenPrefix": "tr-chromeOpenPrefix", "chromeDismissPrefix": "tr-chromeDismissPrefix",
    \\  "chromeImportant": "tr-chromeImportant", "chromeOther": "tr-chromeOther",
    \\  "chromeCopied": "tr-chromeCopied", "chromeMore": "tr-chromeMore"
    \\}
;

const C = l10n.Bundle(&.{ chrome_en_arb, chrome_tr_arb });

test "chrome derives one reserved key per Chrome field, per locale" {
    const element = @import("../core/element.zig");
    const en = C.chrome(.en);
    const tr_chrome = C.chrome(.tr);
    // Every field, not a sample: the derivation (camel-casing at the
    // underscores under a `chrome` prefix) is proven for each field the
    // struct has today and any it grows — a new field fails the C
    // bundle's compile before this loop can even run.
    inline for (@typeInfo(element.Chrome).@"struct".fields) |f| {
        var expected: [64]u8 = undefined;
        var n: usize = "chrome".len;
        @memcpy(expected[0..n], "chrome");
        var upper = true;
        for (f.name) |ch| {
            if (ch == '_') {
                upper = true;
                continue;
            }
            expected[n] = if (upper) std.ascii.toUpper(ch) else ch;
            upper = false;
            n += 1;
        }
        try std.testing.expectEqualStrings(expected[0..n], @field(en, f.name));
        try std.testing.expectEqualStrings("tr-", @field(tr_chrome, f.name)[0..3]);
        try std.testing.expectEqualStrings(expected[0..n], @field(tr_chrome, f.name)[3..]);
    }
    // The zero-config side of the contract: every Chrome field keeps a
    // default, so the bare literal (the English-only app) stays whole
    // when a field is added — the half `Chrome.Catalog` used to assert.
    inline for (@typeInfo(element.Chrome).@"struct".fields) |f| {
        comptime std.debug.assert(f.default_value_ptr != null);
    }
}

test "fmtIn is fmt into the tree arena: identical bytes, no cap" {
    const Tree = @import("../core/tree.zig").Tree;
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    var buf: [64]u8 = undefined;

    // One emitter behind one Sink: string and int placeholders, plural
    // with #, select fallback, and shaped Persian digits all come out
    // byte-identical to fmt's answer.
    try std.testing.expectEqualStrings(
        try L.fmt(&buf, .en, .greeting, .{ .name = "Ada" }),
        try L.fmtIn(&tree, .en, .greeting, .{ .name = "Ada" }),
    );
    try std.testing.expectEqualStrings(
        try L.fmt(&buf, .fa, .score, .{ .points = 400 }),
        try L.fmtIn(&tree, .fa, .score, .{ .points = 400 }),
    );
    try std.testing.expectEqualStrings(
        try L.fmt(&buf, .en, .nItems, .{ .count = 7 }),
        try L.fmtIn(&tree, .en, .nItems, .{ .count = 7 }),
    );
    try std.testing.expectEqualStrings(
        try L.fmt(&buf, .en, .pronoun, .{ .gender = "nonbinary" }),
        try L.fmtIn(&tree, .en, .pronoun, .{ .gender = "nonbinary" }),
    );

    // Where fmt reports NoSpace, fmtIn has no cap to run out of: the
    // counting walk sized the allocation, so the long value comes out
    // whole — the truncation-by-guess failure mode gone, not enlarged.
    const long_name = "x" ** 300;
    try std.testing.expectError(
        error.NoSpace,
        L.fmt(&buf, .en, .greeting, .{ .name = long_name }),
    );
    const whole = try L.fmtIn(&tree, .en, .greeting, .{ .name = long_name });
    try std.testing.expectEqual(@as(usize, "Hello, ".len + 300 + 1), whole.len);

    // Arena lifetime, not call lifetime: an earlier answer survives
    // later calls and appends, unlike the caller buffer fmt reuses.
    const first = try L.fmtIn(&tree, .en, .greeting, .{ .name = "Ada" });
    _ = try L.fmtIn(&tree, .en, .greeting, .{ .name = "Grace" });
    try tree.append(tree.rootId(), .{ .text = .{ .content = first } });
    try std.testing.expectEqualStrings("Hello, Ada!", first);
}
