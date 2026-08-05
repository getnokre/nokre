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
