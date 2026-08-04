//! CLDR cardinal plural rules, restricted to integer operands. nokre
//! counts are integers (docs/localization.md), which collapses the CLDR
//! rule grammar dramatically: the v/w/f/t operands (visible fraction
//! digits) are all zero, and the compact-notation exponent e is zero, so
//! each language reduces to arithmetic on n alone. Rules follow CLDR 45;
//! where CLDR has changed recently the current form is used (Hebrew lost
//! `many` in CLDR 43; French/Spanish/Italian/Portuguese gained `many`
//! for whole millions in CLDR 42).
//!
//! Each rule also states, per category, whether the set of integers it
//! selects is finite. That powers a compile-time check Flutter's
//! gen_l10n never makes: a Russian plural without `few` is rejected at
//! build time, while an English `=1{...} other{...}` still passes
//! because `=1` provably covers everything `one` can select. The
//! validation lives in [l10n.zig](l10n.zig); this table is only data.
//!
//! A language not listed is an error only when one of its messages
//! actually uses `plural` — add a row here (langs, category coverage,
//! selector) with the rule from
//! https://www.unicode.org/cldr/charts/45/supplemental/language_plural_rules.html

const arb = @import("arb.zig");

pub const Category = arb.Category;

pub const Coverage = union(enum) {
    /// Only the keyword branch can satisfy the category.
    infinite,
    /// The category selects exactly these integers; `=N` exact branches
    /// covering all of them satisfy it just as well.
    finite: []const u64,
};

pub const Cat = struct {
    cat: Category,
    cover: Coverage,
    /// Whether a catalog must answer the category. The one exception to
    /// strictness is the Romance `many` (whole millions, CLDR 42): it is
    /// real grammar but almost no catalog writes it, so a missing branch
    /// falls back to `other` at runtime — exactly what intl does —
    /// instead of failing the build.
    required: bool = true,
    /// A concrete integer the category selects, for diagnostics; null
    /// only where `cover` is finite (the first member serves) or the
    /// category is `other` (never reported missing).
    sample: ?u64 = null,
};

pub const Rule = struct {
    /// Language subtags (or full tags like "pt_PT" where a region
    /// genuinely changes the rule — checked before the bare language).
    langs: []const []const u8,
    /// The categories reachable for integer operands. `other` may be
    /// absent (Russian integers never select it) — the mandatory
    /// `other` branch is ICU syntax, enforced separately.
    cats: []const Cat,
    select: *const fn (n: u64) Category,
};

const one_1 = Cat{ .cat = .one, .cover = .{ .finite = &.{1} } };
const one_01 = Cat{ .cat = .one, .cover = .{ .finite = &.{ 0, 1 } } };
const one_inf = Cat{ .cat = .one, .cover = .infinite, .sample = 1 };
const two_2 = Cat{ .cat = .two, .cover = .{ .finite = &.{2} } };
const two_inf = Cat{ .cat = .two, .cover = .infinite, .sample = 2 };
const zero_0 = Cat{ .cat = .zero, .cover = .{ .finite = &.{0} } };
const zero_inf = Cat{ .cat = .zero, .cover = .infinite, .sample = 0 };
const few_inf = Cat{ .cat = .few, .cover = .infinite, .sample = 3 };
const many_inf = Cat{ .cat = .many, .cover = .infinite, .sample = 11 };
const many_e6 = Cat{ .cat = .many, .cover = .infinite, .required = false, .sample = 1_000_000 };
const other_inf = Cat{ .cat = .other, .cover = .infinite };

pub const table = [_]Rule{
    // No plural distinctions.
    .{
        .langs = &.{ "ja", "zh", "yue", "ko", "th", "vi", "id", "ms", "lo", "km", "my", "bo" },
        .cats = &.{other_inf},
        .select = selOther,
    },
    // one ⇔ n = 1.
    .{
        .langs = &.{
            "en", "de", "nl", "sv", "da", "nb", "nn", "no", "et", "fi", "el", "hu",
            "tr", "az", "bg", "sq", "eu", "ka", "kk", "ky", "uz", "mn", "ne", "sw",
            "af", "ur", "ta", "te", "ml", "so",
        },
        .cats = &.{ one_1, other_inf },
        .select = selOneOther,
    },
    // one ⇔ n = 0..1 (i = 0 or n = 1 in CLDR terms).
    .{
        .langs = &.{ "fa", "hi", "bn", "am", "as", "gu", "kn", "zu", "hy" },
        .cats = &.{ one_01, other_inf },
        .select = selZeroOne,
    },
    // French: one for 0..1, many for whole millions.
    .{
        .langs = &.{"fr"},
        .cats = &.{ one_01, many_e6, other_inf },
        .select = selFrench,
    },
    // Spanish shape: one for 1, many for whole millions. European
    // Portuguese counts like Spanish, not like Brazilian pt.
    .{
        .langs = &.{ "es", "it", "ca", "gl", "pt_PT" },
        .cats = &.{ one_1, many_e6, other_inf },
        .select = selSpanish,
    },
    // (Brazilian) Portuguese: one for 0..1, many for whole millions.
    .{
        .langs = &.{"pt"},
        .cats = &.{ one_01, many_e6, other_inf },
        .select = selPortuguese,
    },
    .{
        .langs = &.{"ar"},
        .cats = &.{ zero_0, one_1, two_2, few_inf, many_inf, other_inf },
        .select = selArabic,
    },
    .{
        .langs = &.{ "he", "iw" },
        .cats = &.{ one_1, two_2, other_inf },
        .select = selHebrew,
    },
    // East Slavic: for integers every n lands in one/few/many — `other`
    // exists only for fractions, which nokre's integer counts never are.
    .{
        .langs = &.{ "ru", "uk", "be" },
        .cats = &.{ one_inf, few_inf, many_inf },
        .select = selEastSlavic,
    },
    // South Slavic keeps the same one/few split but the tail is other.
    .{
        .langs = &.{ "sr", "hr", "bs", "sh" },
        .cats = &.{ one_inf, few_inf, other_inf },
        .select = selSerboCroatian,
    },
    .{
        .langs = &.{"pl"},
        .cats = &.{ one_1, few_inf, many_inf },
        .select = selPolish,
    },
    .{
        .langs = &.{ "cs", "sk" },
        .cats = &.{ one_1, .{ .cat = .few, .cover = .{ .finite = &.{ 2, 3, 4 } } }, other_inf },
        .select = selCzech,
    },
    .{
        .langs = &.{"lt"},
        .cats = &.{ one_inf, few_inf, other_inf },
        .select = selLithuanian,
    },
    .{
        .langs = &.{"lv"},
        .cats = &.{ zero_inf, one_inf, other_inf },
        .select = selLatvian,
    },
    .{
        .langs = &.{ "ro", "mo" },
        .cats = &.{ one_1, few_inf, other_inf },
        .select = selRomanian,
    },
    .{
        .langs = &.{"sl"},
        .cats = &.{ one_inf, two_inf, few_inf, other_inf },
        .select = selSlovenian,
    },
    .{
        .langs = &.{"ga"},
        .cats = &.{
            one_1,
            two_2,
            .{ .cat = .few, .cover = .{ .finite = &.{ 3, 4, 5, 6 } } },
            .{ .cat = .many, .cover = .{ .finite = &.{ 7, 8, 9, 10 } } },
            other_inf,
        },
        .select = selIrish,
    },
    .{
        .langs = &.{"cy"},
        .cats = &.{
            zero_0,
            one_1,
            two_2,
            .{ .cat = .few, .cover = .{ .finite = &.{3} } },
            .{ .cat = .many, .cover = .{ .finite = &.{6} } },
            other_inf,
        },
        .select = selWelsh,
    },
    .{
        .langs = &.{ "is", "mk" },
        .cats = &.{ one_inf, other_inf },
        .select = selTeenSkippingOne,
    },
};

/// Resolves a locale tag to its rule: full tag first (so "pt_PT" beats
/// "pt"), then the bare language subtag. Null when the language is not
/// in the table — an error only if the locale actually uses `plural`.
pub fn forLocale(comptime tag: []const u8) ?Rule {
    for (table) |r| for (r.langs) |l| if (tagEql(l, tag)) return r;
    const lang = languageOf(tag);
    for (table) |r| for (r.langs) |l| if (tagEql(l, lang)) return r;
    return null;
}

// Locale-tag identity: case-insensitive, `-` and `_` one separator.
// The one home for the rule — the comptime bundle machinery and
// l10n.zig's runtime `resolve` both compare tags with exactly these,
// so the two can never disagree about which locale a tag is.

pub fn languageOf(tag: []const u8) []const u8 {
    for (tag, 0..) |c, i| if (c == '_' or c == '-') return tag[0..i];
    return tag;
}

pub fn tagEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (normTagByte(ca) != normTagByte(cb)) return false;
    }
    return true;
}

fn normTagByte(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    if (c == '-') return '_';
    return c;
}

// --- selectors -------------------------------------------------------------

fn selOther(n: u64) Category {
    _ = n;
    return .other;
}

fn selOneOther(n: u64) Category {
    return if (n == 1) .one else .other;
}

fn selZeroOne(n: u64) Category {
    return if (n <= 1) .one else .other;
}

fn selFrench(n: u64) Category {
    if (n <= 1) return .one;
    if (n % 1_000_000 == 0) return .many;
    return .other;
}

fn selSpanish(n: u64) Category {
    if (n == 1) return .one;
    if (n != 0 and n % 1_000_000 == 0) return .many;
    return .other;
}

fn selPortuguese(n: u64) Category {
    if (n <= 1) return .one;
    if (n % 1_000_000 == 0) return .many;
    return .other;
}

fn selArabic(n: u64) Category {
    return switch (n) {
        0 => .zero,
        1 => .one,
        2 => .two,
        else => switch (n % 100) {
            3...10 => .few,
            11...99 => .many,
            else => .other,
        },
    };
}

fn selHebrew(n: u64) Category {
    return switch (n) {
        1 => .one,
        2 => .two,
        else => .other,
    };
}

fn selEastSlavic(n: u64) Category {
    const m10 = n % 10;
    const m100 = n % 100;
    if (m10 == 1 and m100 != 11) return .one;
    if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) return .few;
    return .many;
}

fn selSerboCroatian(n: u64) Category {
    const m10 = n % 10;
    const m100 = n % 100;
    if (m10 == 1 and m100 != 11) return .one;
    if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) return .few;
    return .other;
}

fn selPolish(n: u64) Category {
    if (n == 1) return .one;
    const m10 = n % 10;
    const m100 = n % 100;
    if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) return .few;
    return .many;
}

fn selCzech(n: u64) Category {
    return switch (n) {
        1 => .one,
        2, 3, 4 => .few,
        else => .other,
    };
}

fn selLithuanian(n: u64) Category {
    const m10 = n % 10;
    const m100 = n % 100;
    if (m100 >= 11 and m100 <= 19) return .other;
    if (m10 == 1) return .one;
    if (m10 >= 2 and m10 <= 9) return .few;
    return .other;
}

fn selLatvian(n: u64) Category {
    const m10 = n % 10;
    const m100 = n % 100;
    if (m10 == 0 or (m100 >= 11 and m100 <= 19)) return .zero;
    if (m10 == 1 and m100 != 11) return .one;
    return .other;
}

fn selRomanian(n: u64) Category {
    if (n == 1) return .one;
    const m100 = n % 100;
    if (n == 0 or (m100 >= 2 and m100 <= 19)) return .few;
    return .other;
}

fn selSlovenian(n: u64) Category {
    return switch (n % 100) {
        1 => .one,
        2 => .two,
        3, 4 => .few,
        else => .other,
    };
}

fn selIrish(n: u64) Category {
    return switch (n) {
        1 => .one,
        2 => .two,
        3...6 => .few,
        7...10 => .many,
        else => .other,
    };
}

fn selWelsh(n: u64) Category {
    return switch (n) {
        0 => .zero,
        1 => .one,
        2 => .two,
        3 => .few,
        6 => .many,
        else => .other,
    };
}

/// Icelandic and Macedonian: one ⇔ n ends in 1 but not 11.
fn selTeenSkippingOne(n: u64) Category {
    const m10 = n % 10;
    const m100 = n % 100;
    return if (m10 == 1 and m100 != 11) .one else .other;
}
