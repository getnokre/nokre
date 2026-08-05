//! Comptime ARB parsing: the JSON subset an Application Resource Bundle
//! actually uses, plus the ICU MessageFormat subset nokre admits
//! (placeholders, plural, select). Everything here runs at compile time —
//! a malformed catalog is a build failure with a line number, never a
//! runtime surprise. The consumer surface built on this IR is
//! [l10n.zig](l10n.zig); the format contract is docs/localization.md.
//!
//! The subset is deliberate, matching Flutter's gen_l10n where the
//! feature is deterministic and refusing where it is not:
//! - `{name}` placeholders typed by @-metadata (String, int, num, or
//!   nokre's own `date`); `double`, `DateTime`, and `format:` are
//!   refused — float formatting and platform DateFormat are
//!   locale-library behavior that varies by OS, and nokre's core is
//!   integer math with no clock.
//! - `{when, date, skeleton}` with a closed skeleton set (`y`, `M`,
//!   `d`, `MMM`, `yMd`) over a caller-supplied *civil* date — no clock,
//!   no zone, no platform table; `MMM` reads its words from the
//!   catalog's reserved `monthJan`…`monthDec` keys (l10n.zig).
//! - `{n, plural, ...}` with `=N` exacts, CLDR category keywords, and
//!   `#`; `offset:` and `selectordinal` are refused until someone
//!   argues a case.
//! - `{v, select, ...}` with a mandatory `other`.
//! - ICU quoting as Flutter's `use-escaping: true`: `''` is a literal
//!   apostrophe; `'` opens a quoted run only before a syntax character
//!   (`{`, `}`, or `#` inside plural), so plain English apostrophes
//!   never need doubling.
//!
//! Every function takes `comptime` parameters on purpose: nothing here
//! may exist at runtime, and the qualifier is what lets the diagnostics
//! interpolate the offending key and locale into @compileError.

const std = @import("std");

pub const Kind = enum { string, int, date };

pub const Category = enum { zero, one, two, few, many, other };

/// The date formats a `{when, date, …}` reference may ask for — a
/// closed set, ICU-skeleton-named so a reader arriving from Flutter
/// recognizes them, each with one fixed expansion (l10n.zig's
/// emitter): the components `y`/`M`/`d` (unpadded) and `MMM` (the
/// month's word from the reserved `monthJan`…`monthDec` keys) let each
/// locale's *message* choose its own order and separators — the same
/// authority translators already hold over every other word — while
/// `yMd` is the one composed form, ISO 8601 `y-MM-dd`, for the places
/// that want a locale-blind numeric date. Combined text skeletons
/// (`yMMMd`) are refused on purpose: they would fix an order the
/// message can already state, a second way to say the same label.
pub const DateSkeleton = enum { y, M, d, MMM, yMd };

pub const DateRef = struct { arg: []const u8, skeleton: DateSkeleton };

pub const Seg = union(enum) {
    literal: []const u8,
    /// A bare `{name}` placeholder. Its kind (string vs int) is resolved
    /// by the bundle from @-metadata and cross-message usage, not here.
    arg: []const u8,
    /// `#` inside a plural branch: the nearest enclosing plural's count.
    pound,
    /// `{name, date, skeleton}`: one component (or ISO form) of a civil
    /// date the caller supplies.
    date: DateRef,
    plural: Plural,
    select: Select,
};

pub const Segs = []const Seg;

pub const PluralSelector = union(enum) { exact: u64, category: Category };
pub const PluralBranch = struct { selector: PluralSelector, segs: Segs };
pub const Plural = struct { arg: []const u8, branches: []const PluralBranch };

pub const SelectBranch = struct { name: []const u8, segs: Segs };
pub const Select = struct { arg: []const u8, branches: []const SelectBranch };

/// `kind` is null when the metadata has no "type": the bundle then
/// infers it from usage (a plural count is an int; anything else
/// defaults to string), matching Flutter's untyped-placeholder default.
pub const DeclaredPlaceholder = struct { name: []const u8, kind: ?Kind };
pub const Meta = struct { key: []const u8, placeholders: []const DeclaredPlaceholder };

pub const Entry = struct { key: []const u8, segs: Segs };

pub const File = struct {
    locale: []const u8,
    entries: []const Entry,
    metas: []const Meta,
};

// ---------------------------------------------------------------------------
// Error reporting: every @compileError carries the file label and the
// 1-based line of the offending byte, so a bad catalog reads like a
// compiler diagnostic, not a stack trace.

fn lineOf(comptime src: []const u8, comptime i: usize) usize {
    var line: usize = 1;
    for (src[0..@min(i, src.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn fail(comptime label: []const u8, comptime src: []const u8, comptime i: usize, comptime msg: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint("nokre l10n: {s}: line {d}: {s}", .{
        label, lineOf(src, i), msg,
    }));
}

// ---------------------------------------------------------------------------
// JSON subset

fn skipWs(comptime src: []const u8, comptime start: usize) usize {
    var i = start;
    while (i < src.len) : (i += 1) switch (src[i]) {
        ' ', '\t', '\r', '\n' => {},
        else => break,
    };
    return i;
}

const StringResult = struct { value: []const u8, end: usize };

/// Parses a JSON string starting at the opening quote, returning the
/// decoded value. Slices the source directly when no escape appears.
fn parseString(comptime label: []const u8, comptime src: []const u8, comptime start: usize) StringResult {
    if (start >= src.len or src[start] != '"') fail(label, src, start, "expected a string");
    var i = start + 1;
    var out: []const u8 = "";
    var run_start = i;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            return .{ .value = out ++ src[run_start..i], .end = i + 1 };
        }
        if (c == '\\') {
            out = out ++ src[run_start..i];
            if (i + 1 >= src.len) fail(label, src, i, "unterminated escape");
            const esc = src[i + 1];
            i += 2;
            switch (esc) {
                '"' => out = out ++ "\"",
                '\\' => out = out ++ "\\",
                '/' => out = out ++ "/",
                'b' => out = out ++ "\x08",
                'f' => out = out ++ "\x0c",
                'n' => out = out ++ "\n",
                'r' => out = out ++ "\r",
                't' => out = out ++ "\t",
                'u' => {
                    if (i + 4 > src.len) fail(label, src, i, "truncated \\u escape");
                    var cp: u21 = parseHex4(label, src, i);
                    i += 4;
                    // Surrogate pair: a high surrogate must be followed by
                    // \uDC00-\uDFFF; anything else is a malformed file.
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (i + 6 > src.len or src[i] != '\\' or src[i + 1] != 'u')
                            fail(label, src, i, "high surrogate without a low surrogate");
                        const low: u21 = parseHex4(label, src, i + 2);
                        if (low < 0xDC00 or low > 0xDFFF)
                            fail(label, src, i, "invalid low surrogate");
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        i += 6;
                    } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                        fail(label, src, i, "unpaired low surrogate");
                    }
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8) catch
                        fail(label, src, i, "invalid \\u escape");
                    out = out ++ utf8[0..len];
                },
                else => fail(label, src, i, "unknown escape character"),
            }
            run_start = i;
            continue;
        }
        i += 1;
    }
    fail(label, src, start, "unterminated string");
}

fn parseHex4(comptime label: []const u8, comptime src: []const u8, comptime at: usize) u21 {
    var v: u21 = 0;
    for (src[at .. at + 4]) |c| {
        const d: u21 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => fail(label, src, at, "invalid hex digit in \\u escape"),
        };
        v = v * 16 + d;
    }
    return v;
}

/// Skips any JSON value; used for metadata fields nokre ignores
/// (description, example, @@last_modified, ...).
fn skipValue(comptime label: []const u8, comptime src: []const u8, comptime start: usize) usize {
    const i = skipWs(src, start);
    if (i >= src.len) fail(label, src, i, "expected a value");
    switch (src[i]) {
        '"' => return parseString(label, src, i).end,
        '{' => {
            var j = skipWs(src, i + 1);
            if (j < src.len and src[j] == '}') return j + 1;
            while (true) {
                j = parseString(label, src, skipWs(src, j)).end;
                j = skipWs(src, j);
                if (j >= src.len or src[j] != ':') fail(label, src, j, "expected ':'");
                j = skipValue(label, src, j + 1);
                j = skipWs(src, j);
                if (j < src.len and src[j] == ',') {
                    j += 1;
                    continue;
                }
                if (j < src.len and src[j] == '}') return j + 1;
                fail(label, src, j, "expected ',' or '}'");
            }
        },
        '[' => {
            var j = skipWs(src, i + 1);
            if (j < src.len and src[j] == ']') return j + 1;
            while (true) {
                j = skipValue(label, src, j);
                j = skipWs(src, j);
                if (j < src.len and src[j] == ',') {
                    j += 1;
                    continue;
                }
                if (j < src.len and src[j] == ']') return j + 1;
                fail(label, src, j, "expected ',' or ']'");
            }
        },
        't' => return expectWord(label, src, i, "true"),
        'f' => return expectWord(label, src, i, "false"),
        'n' => return expectWord(label, src, i, "null"),
        '-', '0'...'9' => {
            var j = i + 1;
            while (j < src.len) : (j += 1) switch (src[j]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => break,
            };
            return j;
        },
        else => fail(label, src, i, "unexpected character"),
    }
}

fn expectWord(comptime label: []const u8, comptime src: []const u8, comptime i: usize, comptime word: []const u8) usize {
    if (i + word.len > src.len or !std.mem.eql(u8, src[i .. i + word.len], word))
        fail(label, src, i, "unexpected token");
    return i + word.len;
}

// ---------------------------------------------------------------------------
// @-metadata

const PlaceholderMetaResult = struct { ph: DeclaredPlaceholder, end: usize };

fn parsePlaceholderMeta(comptime label: []const u8, comptime src: []const u8, comptime start: usize, comptime name: []const u8) PlaceholderMetaResult {
    var i = skipWs(src, start);
    if (i >= src.len or src[i] != '{') fail(label, src, i, "placeholder metadata must be an object");
    i = skipWs(src, i + 1);
    var kind: ?Kind = null;
    if (i < src.len and src[i] == '}') return .{ .ph = .{ .name = name, .kind = kind }, .end = i + 1 };
    while (true) {
        const field = parseString(label, src, i);
        i = skipWs(src, field.end);
        if (i >= src.len or src[i] != ':') fail(label, src, i, "expected ':'");
        i += 1;
        if (std.mem.eql(u8, field.value, "type")) {
            const t = parseString(label, src, skipWs(src, i));
            i = t.end;
            if (std.mem.eql(u8, t.value, "String")) {
                kind = .string;
            } else if (std.mem.eql(u8, t.value, "int") or std.mem.eql(u8, t.value, "num")) {
                // `num` is what Flutter templates write for plural counts;
                // nokre reads it as an integer — counts are integers, and
                // fractional plurals would drag float formatting into core.
                kind = .int;
            } else if (std.mem.eql(u8, t.value, "date")) {
                // nokre's own kind, not Flutter's: a civil date the
                // caller computed (l10n.Date), rendered by the fixed
                // skeletons — no clock and no platform DateFormat.
                kind = .date;
            } else if (std.mem.eql(u8, t.value, "DateTime")) {
                fail(label, src, i, "placeholder type 'DateTime' is refused: it drags a clock, a " ++
                    "zone, and the platform's DateFormat into the catalog. Declare " ++
                    "\"type\": \"date\" and write {name, date, skeleton}: nokre formats a civil " ++
                    "date the caller supplies (l10n.dateFromMillis) with integer math");
            } else if (std.mem.eql(u8, t.value, "double")) {
                fail(label, src, i, "placeholder type 'double' is refused: float formatting is " ++
                    "locale-library behavior that varies by platform, and nokre renders the same " ++
                    "bytes everywhere. Format the value in app code and pass a String or int");
            } else {
                fail(label, src, i, "unknown placeholder type '" ++ t.value ++ "' (String, int, num, or date)");
            }
        } else if (std.mem.eql(u8, field.value, "format") or std.mem.eql(u8, field.value, "optionalParameters")) {
            fail(label, src, i, "placeholder 'format' is refused: NumberFormat/DateFormat output " ++
                "depends on the platform's ICU data, which breaks pixel determinism. Format the " ++
                "value in app code and pass the result");
        } else {
            // description, example, isCustomDateFormat, x- extensions: fine, ignored.
            i = skipValue(label, src, i);
        }
        i = skipWs(src, i);
        if (i < src.len and src[i] == ',') {
            i = skipWs(src, i + 1);
            continue;
        }
        if (i < src.len and src[i] == '}') return .{ .ph = .{ .name = name, .kind = kind }, .end = i + 1 };
        fail(label, src, i, "expected ',' or '}'");
    }
}

const MetaResult = struct { meta: Meta, end: usize };

fn parseMeta(comptime label: []const u8, comptime src: []const u8, comptime start: usize, comptime key: []const u8) MetaResult {
    var i = skipWs(src, start);
    if (i >= src.len or src[i] != '{') fail(label, src, i, "@-metadata must be an object");
    i = skipWs(src, i + 1);
    var placeholders: []const DeclaredPlaceholder = &.{};
    if (i < src.len and src[i] == '}')
        return .{ .meta = .{ .key = key, .placeholders = placeholders }, .end = i + 1 };
    while (true) {
        const field = parseString(label, src, i);
        i = skipWs(src, field.end);
        if (i >= src.len or src[i] != ':') fail(label, src, i, "expected ':'");
        i += 1;
        if (std.mem.eql(u8, field.value, "placeholders")) {
            i = skipWs(src, i);
            if (i >= src.len or src[i] != '{') fail(label, src, i, "'placeholders' must be an object");
            i = skipWs(src, i + 1);
            if (i < src.len and src[i] == '}') {
                i += 1;
            } else while (true) {
                const name = parseString(label, src, i);
                i = skipWs(src, name.end);
                if (i >= src.len or src[i] != ':') fail(label, src, i, "expected ':'");
                const ph = parsePlaceholderMeta(label, src, i + 1, name.value);
                for (placeholders) |p| if (std.mem.eql(u8, p.name, name.value))
                    fail(label, src, i, "duplicate placeholder '" ++ name.value ++ "'");
                placeholders = placeholders ++ &[_]DeclaredPlaceholder{ph.ph};
                i = skipWs(src, ph.end);
                if (i < src.len and src[i] == ',') {
                    i = skipWs(src, i + 1);
                    continue;
                }
                if (i < src.len and src[i] == '}') {
                    i += 1;
                    break;
                }
                fail(label, src, i, "expected ',' or '}'");
            }
        } else {
            i = skipValue(label, src, i);
        }
        i = skipWs(src, i);
        if (i < src.len and src[i] == ',') {
            i = skipWs(src, i + 1);
            continue;
        }
        if (i < src.len and src[i] == '}')
            return .{ .meta = .{ .key = key, .placeholders = placeholders }, .end = i + 1 };
        fail(label, src, i, "expected ',' or '}'");
    }
}

// ---------------------------------------------------------------------------
// ICU MessageFormat subset

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

const SegsResult = struct { segs: Segs, end: usize };

fn failMsg(comptime ctx: []const u8, comptime msg: []const u8) noreturn {
    @compileError("nokre l10n: " ++ ctx ++ ": " ++ msg);
}

fn skipMsgWs(comptime msg: []const u8, comptime start: usize) usize {
    var i = start;
    while (i < msg.len) : (i += 1) switch (msg[i]) {
        ' ', '\t', '\r', '\n' => {},
        else => break,
    };
    return i;
}

fn parseIdent(comptime ctx: []const u8, comptime msg: []const u8, comptime start: usize) StringResult {
    var i = start;
    while (i < msg.len and isIdentChar(msg[i])) i += 1;
    if (i == start) failMsg(ctx, "expected a name");
    return .{ .value = msg[start..i], .end = i };
}

/// `ctx` names the message ("locale 'fa', message 'nItems'") for
/// diagnostics. `in_plural` gates `#`; it survives into nested select
/// branches so a gendered variant inside a plural can still write the
/// count.
fn parseSegs(comptime ctx: []const u8, comptime msg: []const u8, comptime start: usize, comptime in_plural: bool, comptime stop_at_brace: bool) SegsResult {
    var segs: []const Seg = &.{};
    var lit: []const u8 = "";
    var run_start = start;
    var i = start;
    while (i < msg.len) {
        const c = msg[i];
        switch (c) {
            '}' => {
                if (!stop_at_brace)
                    failMsg(ctx, "unmatched '}' — a literal brace must be quoted: '}'");
                lit = lit ++ msg[run_start..i];
                if (lit.len != 0) segs = segs ++ &[_]Seg{.{ .literal = lit }};
                return .{ .segs = segs, .end = i + 1 };
            },
            '{' => {
                lit = lit ++ msg[run_start..i];
                if (lit.len != 0) segs = segs ++ &[_]Seg{.{ .literal = lit }};
                lit = "";
                const argr = parseArg(ctx, msg, i + 1, in_plural);
                segs = segs ++ &[_]Seg{argr.seg};
                i = argr.end;
                run_start = i;
            },
            '#' => {
                if (in_plural) {
                    lit = lit ++ msg[run_start..i];
                    if (lit.len != 0) segs = segs ++ &[_]Seg{.{ .literal = lit }};
                    lit = "";
                    segs = segs ++ &[_]Seg{.pound};
                    i += 1;
                    run_start = i;
                } else {
                    i += 1;
                }
            },
            '\'' => {
                // ICU quoting, Flutter use-escaping semantics: '' is an
                // apostrophe; ' quotes a run only when a syntax character
                // follows, so prose apostrophes pass through untouched.
                if (i + 1 < msg.len and msg[i + 1] == '\'') {
                    lit = lit ++ msg[run_start..i] ++ "'";
                    i += 2;
                    run_start = i;
                } else if (i + 1 < msg.len and (msg[i + 1] == '{' or msg[i + 1] == '}' or
                    (msg[i + 1] == '#' and in_plural)))
                {
                    lit = lit ++ msg[run_start..i];
                    i += 1;
                    var q_start = i;
                    while (true) {
                        if (i >= msg.len)
                            failMsg(ctx, "unterminated quote — a ' before {, }, or # opens " ++
                                "a quoted run that must be closed with another '");
                        if (msg[i] == '\'') {
                            if (i + 1 < msg.len and msg[i + 1] == '\'') {
                                lit = lit ++ msg[q_start..i] ++ "'";
                                i += 2;
                                q_start = i;
                                continue;
                            }
                            lit = lit ++ msg[q_start..i];
                            i += 1;
                            break;
                        }
                        i += 1;
                    }
                    run_start = i;
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }
    if (stop_at_brace) failMsg(ctx, "unterminated argument — missing '}'");
    lit = lit ++ msg[run_start..i];
    if (lit.len != 0) segs = segs ++ &[_]Seg{.{ .literal = lit }};
    return .{ .segs = segs, .end = i };
}

const ArgResult = struct { seg: Seg, end: usize };

fn parseArg(comptime ctx: []const u8, comptime msg: []const u8, comptime start: usize, comptime in_plural: bool) ArgResult {
    var i = skipMsgWs(msg, start);
    const name = parseIdent(ctx, msg, i);
    i = skipMsgWs(msg, name.end);
    if (i < msg.len and msg[i] == '}')
        return .{ .seg = .{ .arg = name.value }, .end = i + 1 };
    if (i >= msg.len or msg[i] != ',')
        failMsg(ctx, "expected '}' or ',' after '{" ++ name.value ++ "'");
    i = skipMsgWs(msg, i + 1);
    const kind = parseIdent(ctx, msg, i);
    i = skipMsgWs(msg, kind.end);
    if (i >= msg.len or msg[i] != ',')
        failMsg(ctx, "expected ',' after '{" ++ name.value ++ ", " ++ kind.value ++ "'");
    i = skipMsgWs(msg, i + 1);

    if (std.mem.eql(u8, kind.value, "plural")) {
        if (std.mem.startsWith(u8, msg[i..], "offset:"))
            failMsg(ctx, "'offset:' is refused — restate the message with =N exact branches, " ++
                "which say the same thing without the arithmetic");
        var branches: []const PluralBranch = &.{};
        while (true) {
            i = skipMsgWs(msg, i);
            if (i < msg.len and msg[i] == '}') {
                if (branches.len == 0) failMsg(ctx, "plural needs at least an 'other' branch");
                return .{ .seg = .{ .plural = .{ .arg = name.value, .branches = branches } }, .end = i + 1 };
            }
            if (i >= msg.len) failMsg(ctx, "unterminated plural");
            var selector: PluralSelector = undefined;
            if (msg[i] == '=') {
                i += 1;
                var v: u64 = 0;
                const d_start = i;
                while (i < msg.len and msg[i] >= '0' and msg[i] <= '9') : (i += 1)
                    v = v * 10 + (msg[i] - '0');
                if (i == d_start) failMsg(ctx, "expected digits after '='");
                selector = .{ .exact = v };
            } else {
                const kw = parseIdent(ctx, msg, i);
                i = kw.end;
                selector = .{ .category = std.meta.stringToEnum(Category, kw.value) orelse
                    failMsg(ctx, "unknown plural selector '" ++ kw.value ++
                        "' (=N, zero, one, two, few, many, other)") };
            }
            for (branches) |b| if (selectorEql(b.selector, selector))
                failMsg(ctx, "duplicate plural branch");
            i = skipMsgWs(msg, i);
            if (i >= msg.len or msg[i] != '{') failMsg(ctx, "expected '{' after plural selector");
            const body = parseSegs(ctx, msg, i + 1, true, true);
            branches = branches ++ &[_]PluralBranch{.{ .selector = selector, .segs = body.segs }};
            i = body.end;
        }
    }

    if (std.mem.eql(u8, kind.value, "select")) {
        var branches: []const SelectBranch = &.{};
        while (true) {
            i = skipMsgWs(msg, i);
            if (i < msg.len and msg[i] == '}') {
                if (branches.len == 0) failMsg(ctx, "select needs at least an 'other' branch");
                return .{ .seg = .{ .select = .{ .arg = name.value, .branches = branches } }, .end = i + 1 };
            }
            if (i >= msg.len) failMsg(ctx, "unterminated select");
            const kw = parseIdent(ctx, msg, i);
            i = skipMsgWs(msg, kw.end);
            for (branches) |b| if (std.mem.eql(u8, b.name, kw.value))
                failMsg(ctx, "duplicate select branch '" ++ kw.value ++ "'");
            if (i >= msg.len or msg[i] != '{') failMsg(ctx, "expected '{' after select key");
            const body = parseSegs(ctx, msg, i + 1, in_plural, true);
            branches = branches ++ &[_]SelectBranch{.{ .name = kw.value, .segs = body.segs }};
            i = body.end;
        }
    }

    if (std.mem.eql(u8, kind.value, "date")) {
        const sk = parseIdent(ctx, msg, i);
        i = skipMsgWs(msg, sk.end);
        if (i >= msg.len or msg[i] != '}')
            failMsg(ctx, "expected '}' after '{" ++ name.value ++ ", date, " ++ sk.value ++ "'");
        const skeleton = std.meta.stringToEnum(DateSkeleton, sk.value) orelse
            failMsg(ctx, "unknown date skeleton '" ++ sk.value ++ "' — the set is closed: " ++
                "y, M, d (unpadded components), MMM (the reserved monthJan…monthDec words), " ++
                "or yMd (ISO 8601 y-MM-dd). Order and separators belong to the message: " ++
                "write the components where the locale wants them");
        return .{ .seg = .{ .date = .{ .arg = name.value, .skeleton = skeleton } }, .end = i + 1 };
    }

    if (std.mem.eql(u8, kind.value, "selectordinal"))
        failMsg(ctx, "'selectordinal' is not supported — ordinal rules are a second CLDR table " ++
            "no nokre consumer has needed; ask for it with a use case");
    if (std.mem.eql(u8, kind.value, "number") or std.mem.eql(u8, kind.value, "time"))
        failMsg(ctx, "'{" ++ name.value ++ ", " ++ kind.value ++ "}' is refused: locale-library " ++
            "formatting varies by platform. Use a bare {" ++ name.value ++ "} and format in app code");
    failMsg(ctx, "unknown argument type '" ++ kind.value ++ "' (plural, select, or date)");
}

fn selectorEql(comptime a: PluralSelector, comptime b: PluralSelector) bool {
    return switch (a) {
        .exact => |av| b == .exact and b.exact == av,
        .category => |ac| b == .category and b.category == ac,
    };
}

/// Parses one decoded message string into segments.
pub fn parseMessage(comptime ctx: []const u8, comptime msg: []const u8) Segs {
    return parseSegs(ctx, msg, 0, false, false).segs;
}

// ---------------------------------------------------------------------------
// ARB file

pub fn parseFile(comptime label: []const u8, comptime src: []const u8) File {
    var i = skipWs(src, 0);
    if (i >= src.len or src[i] != '{') fail(label, src, i, "an ARB file is a JSON object");
    i = skipWs(src, i + 1);
    var locale: ?[]const u8 = null;
    var entries: []const Entry = &.{};
    const Pending = struct { key: []const u8, msg: []const u8 };
    var pending: []const Pending = &.{};
    var metas: []const Meta = &.{};
    if (i < src.len and src[i] == '}') {
        i += 1;
    } else while (true) {
        const key = parseString(label, src, i);
        i = skipWs(src, key.end);
        if (i >= src.len or src[i] != ':') fail(label, src, i, "expected ':'");
        i += 1;
        if (std.mem.eql(u8, key.value, "@@locale")) {
            // Duplicates fail like duplicate messages do: silently
            // keeping the second tag would re-home every message in the
            // file to a locale half the file never named.
            if (locale != null) fail(label, src, i, "duplicate '@@locale'");
            const v = parseString(label, src, skipWs(src, i));
            locale = v.value;
            i = v.end;
        } else if (std.mem.startsWith(u8, key.value, "@@")) {
            // @@last_modified, @@author, @@context, @@x-…: provenance, ignored.
            i = skipValue(label, src, i);
        } else if (std.mem.startsWith(u8, key.value, "@")) {
            for (metas) |m| if (std.mem.eql(u8, m.key, key.value[1..]))
                fail(label, src, i, "duplicate metadata '" ++ key.value ++ "'");
            const m = parseMeta(label, src, i, key.value[1..]);
            metas = metas ++ &[_]Meta{m.meta};
            i = m.end;
        } else {
            if (key.value.len == 0) fail(label, src, i, "empty message id");
            for (pending) |p| if (std.mem.eql(u8, p.key, key.value))
                fail(label, src, i, "duplicate message '" ++ key.value ++ "'");
            const v = parseString(label, src, skipWs(src, i));
            pending = pending ++ &[_]Pending{.{ .key = key.value, .msg = v.value }};
            i = v.end;
        }
        i = skipWs(src, i);
        if (i < src.len and src[i] == ',') {
            i = skipWs(src, i + 1);
            continue;
        }
        if (i < src.len and src[i] == '}') {
            i += 1;
            break;
        }
        fail(label, src, i, "expected ',' or '}'");
    }
    if (skipWs(src, i) != src.len) fail(label, src, i, "trailing content after the object");
    const loc = locale orelse fail(label, src, 0, "missing \"@@locale\" — nokre never infers " ++
        "a locale from a filename it cannot see");

    for (pending) |p| {
        const ctx = std.fmt.comptimePrint("locale '{s}', message '{s}'", .{ loc, p.key });
        entries = entries ++ &[_]Entry{.{ .key = p.key, .segs = parseMessage(ctx, p.msg) }};
    }
    // An orphan "@foo" with no "foo" is a typo nine times out of ten —
    // and a silently dropped translator note the tenth. Both deserve noise.
    for (metas) |m| {
        var found = false;
        for (entries) |e| {
            if (std.mem.eql(u8, e.key, m.key)) found = true;
        }
        if (!found) fail(label, src, 0, "metadata '@" ++ m.key ++ "' has no matching message");
    }
    return .{ .locale = loc, .entries = entries, .metas = metas };
}
