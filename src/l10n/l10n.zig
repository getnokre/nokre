//! ARB-based localization, compiled instead of generated. Flutter's
//! gen_l10n reads the same file format and emits Dart; nokre reads it
//! at comptime and emits nothing — the catalog *is* the code:
//!
//!     const L = nokre.l10n.Bundle(&.{
//!         @embedFile("l10n/app_en.arb"), // first source = the template
//!         @embedFile("l10n/app_fa.arb"),
//!     });
//!
//!     L.tr(loc, .refresh)                          // no placeholders
//!     L.trAny(loc, key)                            // key chosen at runtime
//!     try L.fmt(&buf, loc, .greeting, .{ .name = user })
//!     try L.fmt(&buf, loc, .nItems, .{ .count = 3 })
//!     L.resolve("fa-IR")                           // → .fa (or the default)
//!     L.of(app).tr(.refresh)                       // locale resolved once
//!     app.setChrome(L.chrome(loc))                 // reserved chrome keys
//!
//! What Flutter checks at generation time — and much it never checks —
//! nokre checks at compile time, because the whole catalog is in view:
//! - Key parity is total: a locale missing a message, or carrying one
//!   the template lost, fails the build. No untranslated-messages file,
//!   no silent English in the Farsi build.
//! - Placeholders are call-site-checked: a missing, extra, or
//!   mistyped argument to fmt is a compile error naming the message.
//! - Plurals are validated against each locale's own CLDR categories:
//!   a Russian message without `few` is rejected; an English message
//!   with a dead `few` branch is rejected too. `=1{...} other{...}`
//!   still passes in English because `=1` provably covers `one`.
//! - Select case sets are part of a message's interface: every locale
//!   must carry the template's cases exactly.
//! The runtime cost is a switch and some memcpys into a caller buffer —
//! no parsing, no allocation, no ICU library, and therefore the same
//! bytes on every platform.
//!
//! The refusals (docs/localization.md): no DateTime or double
//! placeholders, no NumberFormat/DateFormat, no runtime catalog
//! loading, no fallback locale chains inside a bundle. Floats and
//! grouping are app-side formatting; counts are integers, rendered
//! in the catalog locale's own digit shapes (fa ۰–۹, ar ٠–٩, ASCII
//! otherwise — a fixed table, no knob; see `digitsOfTag`). Calendar
//! dates are the one date shape admitted, as `{when, date, skeleton}`
//! over a caller-supplied civil `Date` (`dateFromMillis`) — integer
//! math on a value the caller owns, never a clock read here.
//!
//! This is a core-adjacent pure module, not a service: it binds no
//! externs and holds no state, per-app or otherwise. The `locale`
//! service (docs/services.md) reports the *device* locale; feeding its
//! tag through `resolve` into `App.setLocale` is the app's three lines.

const std = @import("std");
const bidi = @import("../core/bidi.zig");
const element_mod = @import("../core/element.zig");
const tree_mod = @import("../core/tree.zig");

pub const arb = @import("arb.zig");
pub const plural_rules = @import("plural_rules.zig");

/// Re-exported so a consumer writes one direction type everywhere:
/// `app.setDirection(L.dir(loc))` and `app.setDirection(
/// l10n.directionOfTag(device_tag))` both speak this.
pub const Direction = bidi.Direction;

pub const Kind = arb.Kind;

/// What a `date` placeholder is fed: a civil (proleptic Gregorian)
/// calendar date, already computed by the caller. A plain value on
/// purpose — no clock, no zone, no notion of "now" — so the same
/// arguments are the same bytes forever. `month` and `day` are
/// 1-based; a `month` outside 1–12 reads as December at the `MMM`
/// skeleton rather than trapping mid-frame, the totality both
/// consumer date modules shipped before this subsumed them.
pub const Date = struct { year: i64, month: u8, day: u8 };

/// Epoch milliseconds (UTC) to the civil date the instant falls on —
/// Howard Hinnant's days-from-civil algorithm, inverted; `@divFloor`
/// keeps pre-1970 instants on the right day. UTC and nothing else:
/// servers speak epoch millis, and a surface precise enough for a
/// zone to matter should not be a formatted label. This is the
/// integer-only civil-date math both rokovski apps had transcribed
/// by hand, moved to the one place every catalog can reach it.
pub fn dateFromMillis(millis: i64) Date {
    const days = @divFloor(millis, 86_400_000);
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    return .{
        .year = yoe + era * 400 + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

const Param = struct { name: []const u8, kind: Kind };

/// The reserved keys a `{…, date, MMM}` reference reads its words
/// from, in month order. Words, so they live where words live — the
/// catalog, one per locale, checked at compile time like every other
/// message — rather than in a table here that would make nokre the
/// translator of twelve nouns.
const month_key_names = [12][]const u8{
    "monthJan", "monthFeb", "monthMar", "monthApr", "monthMay", "monthJun",
    "monthJul", "monthAug", "monthSep", "monthOct", "monthNov", "monthDec",
};

/// Builds the bundle type from embedded ARB sources. The first source
/// is the template: it defines the key set, the placeholder metadata,
/// and the default locale (what `resolve` falls back to).
pub fn Bundle(comptime arb_sources: []const []const u8) type {
    if (arb_sources.len == 0)
        @compileError("nokre l10n: Bundle needs at least one ARB source (the template)");
    comptime var total_bytes: usize = 0;
    inline for (arb_sources) |s| total_bytes += s.len;
    // Parsing is a few passes over each byte; validation is quadratic
    // only in tiny dimensions (params, branches). 400/byte is roomy.
    @setEvalBranchQuota(@intCast(@min(400 * total_bytes + 200_000, std.math.maxInt(u32))));

    const n_locales = arb_sources.len;
    comptime var files_v: [n_locales]arb.File = undefined;
    inline for (arb_sources, 0..) |src, i|
        files_v[i] = arb.parseFile(std.fmt.comptimePrint("ARB source #{d}", .{i + 1}), src);
    const files = files_v;

    comptime {
        for (files, 0..) |f, i| for (files[0..i]) |g| {
            if (std.mem.eql(u8, f.locale, g.locale))
                @compileError("nokre l10n: locale '" ++ f.locale ++ "' appears twice");
        };
    }

    const template = files[0];
    const n_keys = template.entries.len;
    comptime var keys_v: [n_keys][]const u8 = undefined;
    inline for (template.entries, 0..) |e, j| keys_v[j] = e.key;
    const keys = keys_v;

    comptime var tags_v: [n_locales][]const u8 = undefined;
    inline for (files, 0..) |f, i| tags_v[i] = f.locale;
    const locale_tags = tags_v;

    // Key parity, both directions. Refusing fallback is the point: an
    // untranslated message is a build error, never silent template text.
    comptime var catalog_v: [n_locales][n_keys]arb.Segs = undefined;
    comptime {
        for (files, 0..) |f, i| {
            for (f.entries) |e| {
                if (keyIndex(&keys, e.key) == null)
                    @compileError("nokre l10n: locale '" ++ f.locale ++ "' has message '" ++
                        e.key ++ "' that the template ('" ++ template.locale ++
                        "') doesn't — every key lives in the template first");
            }
            for (keys, 0..) |k, j| {
                catalog_v[i][j] = entrySegs(f, k) orelse
                    @compileError("nokre l10n: locale '" ++ f.locale ++ "' is missing message '" ++
                        k ++ "' — nokre refuses locale fallback; translate it (the template is " ++
                        "locale '" ++ template.locale ++ "')");
            }
        }
    }
    const catalog = catalog_v;

    // Placeholder interface per key: template metadata plus template
    // usage. Other locales may only use what the template defines —
    // a translation-only placeholder is a typo until the template
    // declares it.
    comptime var params_v: [n_keys][]const Param = undefined;
    comptime {
        for (keys, 0..) |k, j| {
            var rps: []const RParam = &.{};
            if (metaFor(template, k)) |m| {
                for (m.placeholders) |ph|
                    rps = rps ++ &[_]RParam{.{ .name = ph.name, .declared = ph.kind, .usage = null }};
            }
            const tctx = "locale '" ++ template.locale ++ "', message '" ++ k ++ "'";
            rps = collectUsage(tctx, catalog[0][j], rps, true);
            for (files[1..], 1..) |f, i| {
                const ctx = "locale '" ++ f.locale ++ "', message '" ++ k ++ "'";
                rps = collectUsage(ctx, catalog[i][j], rps, false);
            }
            var ps: []const Param = &.{};
            for (rps) |rp| {
                if (rp.declared != null and rp.usage != null and rp.declared.? != rp.usage.?)
                    @compileError("nokre l10n: message '" ++ k ++ "': placeholder '" ++ rp.name ++
                        "' is declared " ++ kindName(rp.declared.?) ++ " but used as " ++
                        kindName(rp.usage.?));
                ps = ps ++ &[_]Param{.{
                    .name = rp.name,
                    .kind = rp.declared orelse (rp.usage orelse .string),
                }};
            }
            params_v[j] = ps;
        }
    }
    const params_table = params_v;

    // The month words, resolved once per locale iff some message uses
    // `{…, date, MMM}` — a catalog that never writes a textual date
    // owes no month keys. When one does, all twelve reserved keys must
    // exist (key parity then makes every locale carry them), and each
    // must be a plain message: a placeholder inside a month word has
    // no arguments to draw from where the word is emitted.
    comptime var month_names_v: [n_locales][]const []const u8 = @splat(&.{});
    comptime {
        var uses_mmm = false;
        for (catalog) |per_locale| for (per_locale) |segs| {
            if (segsUseMonthNames(segs)) uses_mmm = true;
        };
        if (uses_mmm) {
            var idx: [12]usize = undefined;
            for (month_key_names, 0..) |mk, m| {
                idx[m] = keyIndex(&keys, mk) orelse
                    @compileError("nokre l10n: a message uses '{…, date, MMM}', which reads its " ++
                        "month words from the reserved keys monthJan…monthDec — the template is " ++
                        "missing '" ++ mk ++ "'");
                if (params_table[idx[m]].len != 0)
                    @compileError("nokre l10n: reserved month key '" ++ mk ++
                        "' must be a plain message with no placeholders");
            }
            for (0..n_locales) |i| {
                var names: []const []const u8 = &.{};
                for (idx) |j| names = names ++ &[_][]const u8{joinLiterals(catalog[i][j])};
                month_names_v[i] = names;
            }
        }
    }
    const month_names = month_names_v;

    // trAny's answer, generated dense: one slot per (locale, key),
    // filled at comptime with the same joined constant `tr` returns —
    // O(1) at a runtime key, no map, no hashing. A message with
    // placeholders has no whole text to store, so its slot is null and
    // reading it is the runtime twin of `tr`'s compile error.
    comptime var any_table_v: [n_locales][n_keys]?[]const u8 = undefined;
    comptime {
        for (0..n_locales) |i| for (0..n_keys) |j| {
            any_table_v[i][j] = if (params_table[j].len == 0) joinLiterals(catalog[i][j]) else null;
        };
    }
    const any_table = any_table_v;

    // Structural validation per locale: plural categories against the
    // locale's own CLDR rules, select case sets against the template,
    // and no bare reference to a date placeholder — a date without a
    // skeleton has no format to render.
    comptime {
        for (keys, 0..) |k, j| {
            const tmpl_selects = collectSelects(catalog[0][j], &.{});
            for (files, 0..) |f, i| {
                const ctx = "locale '" ++ f.locale ++ "', message '" ++ k ++ "'";
                validateSegs(ctx, f.locale, catalog[i][j], tmpl_selects);
                rejectBareDateArgs(ctx, catalog[i][j], params_table[j]);
            }
        }
    }

    const LocaleInt = std.math.IntFittingRange(0, n_locales - 1);
    comptime var locale_names_v: [n_locales][]const u8 = undefined;
    comptime var locale_vals_v: [n_locales]LocaleInt = undefined;
    inline for (files, 0..) |f, i| {
        locale_names_v[i] = localeIdent(f.locale);
        locale_vals_v[i] = i;
    }
    const locale_names = locale_names_v;
    const locale_vals = locale_vals_v;

    const KeyInt = std.math.IntFittingRange(0, if (n_keys == 0) 0 else n_keys - 1);
    comptime var key_vals_v: [n_keys]KeyInt = undefined;
    inline for (0..n_keys) |j| key_vals_v[j] = j;
    const key_vals = key_vals_v;

    return struct {
        const Self = @This();

        /// One field per ARB source, named by its @@locale ('-' becomes
        /// '_', so "pt-BR" is `.pt_BR`). Field order is source order.
        pub const Locale = @Enum(LocaleInt, .exhaustive, &locale_names, &locale_vals);

        /// One field per template message id, verbatim.
        pub const Key = @Enum(KeyInt, .exhaustive, &keys, &key_vals);

        /// The template's locale: what `resolve` returns when nothing
        /// matches. There is no other fallback anywhere in the bundle.
        pub const default_locale: Locale = @enumFromInt(0);

        /// The @@locale tag as written in the ARB source.
        pub fn tag(locale: Locale) []const u8 {
            switch (locale) {
                inline else => |loc| return comptime locale_tags[@intFromEnum(loc)],
            }
        }

        /// The writing direction of a bundled locale, from its @@locale
        /// tag (see `directionOfTag`) — resolved at comptime, so it is a
        /// constant per locale. Feed it to `App.setDirection` to mirror
        /// the chrome with the language: `app.setDirection(L.dir(loc))`.
        pub fn dir(locale: Locale) Direction {
            switch (locale) {
                inline else => |loc| return comptime directionOfTag(locale_tags[@intFromEnum(loc)]),
            }
        }

        /// A message with no placeholders, as a slice into the binary's
        /// constant data — no buffer, no failure path. A message *with*
        /// placeholders is redirected to `fmt` at compile time.
        pub fn tr(locale: Locale, comptime key: Key) []const u8 {
            const j = comptime @intFromEnum(key);
            comptime {
                if (params_table[j].len != 0)
                    @compileError("nokre l10n: message '" ++ keys[j] ++
                        "' has placeholders — use fmt(buf, locale, ." ++ keys[j] ++ ", args)");
            }
            switch (locale) {
                inline else => |loc| {
                    return comptime joinLiterals(catalog[@intFromEnum(loc)][j]);
                },
            }
        }

        /// `tr` for a key that exists only at runtime — a table-driven
        /// label (month words, enum-indexed captions) where `tr`'s
        /// comptime key would force a hand-written switch per arm. One
        /// dense table read, same constant bytes as `tr`. Reading a
        /// message *with* placeholders is a programming error — the
        /// runtime twin of the compile error `tr` gives — and panics
        /// naming the key; there is no argument struct here to render
        /// it with.
        pub fn trAny(locale: Locale, key: Key) []const u8 {
            return any_table[@intFromEnum(locale)][@intFromEnum(key)] orelse
                std.debug.panic("nokre l10n: message '{s}' has placeholders — trAny reads whole " ++
                    "messages; use fmt with a comptime key", .{@tagName(key)});
        }

        /// Formats a message into `buf`, returning the written slice.
        /// `args` must carry exactly the message's placeholders — one
        /// field per name, integers for counts, slices for strings —
        /// checked at compile time. The only runtime failure is a
        /// too-small buffer: message text is never truncated silently.
        pub fn fmt(buf: []u8, locale: Locale, comptime key: Key, args: anytype) error{NoSpace}![]const u8 {
            const j = comptime @intFromEnum(key);
            comptime checkArgs(@TypeOf(args), params_table[j], keys[j]);
            var sink: Sink = .{ .buf = buf };
            switch (locale) {
                inline else => |loc| {
                    const i = comptime @intFromEnum(loc);
                    try emitSegs(catalog[i][j], locale_tags[i], params_table[j], month_names[i], args, 0, &sink);
                },
            }
            return buf[0..sink.pos];
        }

        /// `fmt` into the tree arena instead of a caller buffer — the
        /// catalog-message twin of `Tree.fmt`, with the same lifetime
        /// contract: valid until the tree's next `reclaim`, which is
        /// after every builder that could have called this has run.
        /// Placeholders are checked at compile time exactly as `fmt`
        /// checks them (`checkArgs` is shared), and the emitted bytes
        /// are `fmt`'s to the byte (one emitter behind one `Sink`);
        /// what changes is only where they land — sized by a counting
        /// walk, so no cap exists to guess and no `NoSpace` to handle.
        pub fn fmtIn(tree: *tree_mod.Tree, locale: Locale, comptime key: Key, args: anytype) error{OutOfMemory}![]const u8 {
            const j = comptime @intFromEnum(key);
            comptime checkArgs(@TypeOf(args), params_table[j], keys[j]);
            switch (locale) {
                inline else => |loc| {
                    const i = comptime @intFromEnum(loc);
                    // A counting sink cannot run out of anything, so
                    // the emitter's one error is unreachable here.
                    var count: Sink = .{ .buf = null };
                    emitSegs(catalog[i][j], locale_tags[i], params_table[j], month_names[i], args, 0, &count) catch unreachable;
                    const out = try tree.strings().alloc(u8, count.pos);
                    var sink: Sink = .{ .buf = out };
                    emitSegs(catalog[i][j], locale_tags[i], params_table[j], month_names[i], args, 0, &sink) catch unreachable;
                    return out;
                },
            }
        }

        /// Maps a runtime locale tag (BCP 47 or POSIX flavored — case
        /// and '-'/'_' are ignored) to a bundled locale: exact tag
        /// match, then bare-language match in source order, then the
        /// template. "fa-IR" finds .fa; "de" against an en/fa bundle
        /// falls back to the template. Script subtags match only
        /// exactly — a zh bundle should list its scripts explicitly.
        pub fn resolve(tag_str: []const u8) Locale {
            inline for (locale_tags, 0..) |t, i| {
                if (plural_rules.tagEql(t, tag_str)) return @enumFromInt(i);
            }
            const lang = plural_rules.languageOf(tag_str);
            inline for (locale_tags, 0..) |t, i| {
                if (plural_rules.tagEql(comptime plural_rules.languageOf(t), lang)) return @enumFromInt(i);
            }
            return default_locale;
        }

        /// The bundle's calls with the locale already in hand — what a
        /// controller holds instead of re-deriving
        /// `resolve(app.locale())` beside every message. A value, not
        /// a reference: it is the resolution, made once, and it stays
        /// honest because a build or an action is one moment in one
        /// locale — anything that changes the locale rebuilds anyway.
        pub const Bound = struct {
            locale: Locale,

            pub inline fn tr(self: Bound, comptime key: Key) []const u8 {
                return Self.tr(self.locale, key);
            }

            pub inline fn trAny(self: Bound, key: Key) []const u8 {
                return Self.trAny(self.locale, key);
            }

            pub inline fn fmt(self: Bound, buf: []u8, comptime key: Key, args: anytype) error{NoSpace}![]const u8 {
                return Self.fmt(buf, self.locale, key, args);
            }

            pub inline fn fmtIn(self: Bound, tree: *tree_mod.Tree, comptime key: Key, args: anytype) error{OutOfMemory}![]const u8 {
                return Self.fmtIn(tree, self.locale, key, args);
            }
        };

        /// `L.of(app).tr(.key)` — the app's chosen locale
        /// (`App.locale()`, "" until chosen), resolved once into a
        /// `Bound`. `anytype` and not `*App` on purpose: this module
        /// is pure and binds no App; anything that answers `locale()`
        /// with a tag — the App, a test harness — can stand here.
        pub fn of(app: anytype) Bound {
            return .{ .locale = resolve(app.locale()) };
        }

        /// nokre's own words (`App.Chrome`) out of this catalog: one
        /// reserved key per field, its name derived from the field's —
        /// `back` is `chromeBack`, `current_screen` is
        /// `chromeCurrentScreen`. Feed it straight to `App.setChrome`.
        /// The derivation is the whole point: a chrome string nokre
        /// grows is a missing-key compile error in every app that
        /// calls this, in every locale it ships — the guarantee the
        /// old `Chrome.Catalog` literal gave, moved to where the words
        /// live, with the field to key spelling no longer an app's to
        /// get wrong. The strings are constant data, borrowed like
        /// every `tr` answer.
        pub fn chrome(locale: Locale) element_mod.Chrome {
            switch (locale) {
                inline else => |loc| return comptime chromeAt(@intFromEnum(loc)),
            }
        }

        fn chromeAt(comptime i: usize) element_mod.Chrome {
            comptime {
                // Evaluated outside Bundle()'s own quota (chrome() is
                // analyzed only when an app references it), so it
                // budgets for itself: a linear key scan per field.
                @setEvalBranchQuota(@intCast(@min(4_000 * @as(u64, n_keys) + 100_000, std.math.maxInt(u32))));
                var out: element_mod.Chrome = undefined;
                for (@typeInfo(element_mod.Chrome).@"struct".fields) |f| {
                    const key_name = chromeKeyName(f.name);
                    const j = keyIndex(&keys, key_name) orelse
                        @compileError("nokre l10n: the template is missing '" ++ key_name ++
                            "' — Bundle.chrome derives one reserved key per App.Chrome field " ++
                            "(here '" ++ f.name ++ "'), so a localized app says every chrome " ++
                            "word or does not build");
                    if (params_table[j].len != 0)
                        @compileError("nokre l10n: reserved chrome key '" ++ key_name ++
                            "' must be a plain message with no placeholders — chrome strings " ++
                            "are constant data, re-said whole on locale change");
                    @field(out, f.name) = joinLiterals(catalog[i][j]);
                }
                return out;
            }
        }
    };
}

// ---------------------------------------------------------------------------
// comptime helpers (Bundle construction)

const RParam = struct { name: []const u8, declared: ?Kind, usage: ?Kind };

fn kindName(comptime k: Kind) []const u8 {
    return switch (k) {
        .string => "a String",
        .int => "an integer (a plural count or int placeholder)",
        .date => "a date (a {name, date, skeleton} civil date)",
    };
}

/// The reserved chrome key a `Chrome` field reads from: `chrome` plus
/// the field name camel-cased at its underscores — `back` is
/// `chromeBack`, `current_screen` `chromeCurrentScreen`. Derived, not
/// listed, so a field nokre grows names its key in the same breath.
fn chromeKeyName(comptime field: []const u8) []const u8 {
    comptime var out: []const u8 = "chrome";
    comptime var upper = true;
    inline for (field) |c| {
        if (c == '_') {
            upper = true;
            continue;
        }
        out = out ++ &[_]u8{if (upper) std.ascii.toUpper(c) else c};
        upper = false;
    }
    return out;
}

/// Does any reference in these segments render a month *word* (the
/// `MMM` skeleton)? Decides whether the bundle owes the reserved
/// monthJan…monthDec keys at all.
fn segsUseMonthNames(comptime segs: arb.Segs) bool {
    for (segs) |seg| switch (seg) {
        .literal, .pound, .arg => {},
        .date => |d| if (d.skeleton == .MMM) return true,
        .plural => |p| for (p.branches) |b| {
            if (segsUseMonthNames(b.segs)) return true;
        },
        .select => |s| for (s.branches) |b| {
            if (segsUseMonthNames(b.segs)) return true;
        },
    };
    return false;
}

fn keyIndex(comptime keys: []const []const u8, comptime key: []const u8) ?usize {
    for (keys, 0..) |k, j| if (std.mem.eql(u8, k, key)) return j;
    return null;
}

fn entrySegs(comptime f: arb.File, comptime key: []const u8) ?arb.Segs {
    for (f.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.segs;
    return null;
}

fn metaFor(comptime f: arb.File, comptime key: []const u8) ?arb.Meta {
    for (f.metas) |m| if (std.mem.eql(u8, m.key, key)) return m;
    return null;
}

fn constrain(comptime ctx: []const u8, comptime rps: []const RParam, comptime name: []const u8, comptime need: ?Kind, comptime allow_new: bool) []const RParam {
    for (rps, 0..) |rp, idx| {
        if (!std.mem.eql(u8, rp.name, name)) continue;
        const merged: ?Kind = if (need == null) rp.usage else blk: {
            if (rp.usage != null and rp.usage.? != need.?)
                @compileError("nokre l10n: " ++ ctx ++ ": placeholder '" ++ name ++
                    "' is used both as " ++ kindName(rp.usage.?) ++ " and as " ++ kindName(need.?));
            break :blk need;
        };
        var out: []const RParam = rps[0..idx];
        out = out ++ &[_]RParam{.{ .name = rp.name, .declared = rp.declared, .usage = merged }};
        return out ++ rps[idx + 1 ..];
    }
    if (!allow_new)
        @compileError("nokre l10n: " ++ ctx ++ ": placeholder '" ++ name ++
            "' does not exist in the template — the template defines a message's interface; " ++
            "declare it there (in the @-metadata if the template text doesn't use it)");
    return rps ++ &[_]RParam{.{ .name = name, .declared = null, .usage = need }};
}

fn collectUsage(comptime ctx: []const u8, comptime segs: arb.Segs, comptime rps_in: []const RParam, comptime allow_new: bool) []const RParam {
    var rps = rps_in;
    for (segs) |seg| switch (seg) {
        .literal, .pound => {},
        .arg => |name| rps = constrain(ctx, rps, name, null, allow_new),
        .date => |d| rps = constrain(ctx, rps, d.arg, .date, allow_new),
        .plural => |p| {
            rps = constrain(ctx, rps, p.arg, .int, allow_new);
            for (p.branches) |b| rps = collectUsage(ctx, b.segs, rps, allow_new);
        },
        .select => |s| {
            rps = constrain(ctx, rps, s.arg, .string, allow_new);
            for (s.branches) |b| rps = collectUsage(ctx, b.segs, rps, allow_new);
        },
    };
    return rps;
}

const SelectSet = struct { arg: []const u8, names: []const []const u8 };

fn collectSelects(comptime segs: arb.Segs, comptime acc_in: []const SelectSet) []const SelectSet {
    var acc = acc_in;
    for (segs) |seg| switch (seg) {
        .literal, .pound, .arg, .date => {},
        .plural => |p| for (p.branches) |b| {
            acc = collectSelects(b.segs, acc);
        },
        .select => |s| {
            var names: []const []const u8 = &.{};
            for (s.branches) |b| names = names ++ &[_][]const u8{b.name};
            acc = acc ++ &[_]SelectSet{.{ .arg = s.arg, .names = names }};
            for (s.branches) |b| acc = collectSelects(b.segs, acc);
        },
    };
    return acc;
}

fn selectSetFor(comptime sets: []const SelectSet, comptime a: []const u8) ?[]const []const u8 {
    for (sets) |s| if (std.mem.eql(u8, s.arg, a)) return s.names;
    return null;
}

fn validateSegs(comptime ctx: []const u8, comptime tag: []const u8, comptime segs: arb.Segs, comptime tmpl_selects: []const SelectSet) void {
    for (segs) |seg| switch (seg) {
        .literal, .pound, .arg, .date => {},
        .plural => |p| {
            const rule = plural_rules.forLocale(tag) orelse
                @compileError("nokre l10n: " ++ ctx ++ ": no integer plural rules for '" ++ tag ++
                    "' in nokre's table — add its CLDR row to src/l10n/plural_rules.zig");
            var has_other = false;
            for (p.branches) |b| {
                if (b.selector == .category and b.selector.category == .other) has_other = true;
            }
            if (!has_other)
                @compileError("nokre l10n: " ++ ctx ++ ": plural on '" ++ p.arg ++
                    "' needs an 'other' branch (ICU's mandatory fallback)");
            // A branch that can never be selected is a translator error
            // hiding as coverage — gen_l10n ships it silently; nokre
            // won't.
            for (p.branches) |b| {
                if (b.selector != .category) continue;
                const c = b.selector.category;
                if (c == .other) continue;
                var reachable = false;
                for (rule.cats) |rc| {
                    if (rc.cat == c) reachable = true;
                }
                if (!reachable)
                    @compileError("nokre l10n: " ++ ctx ++ ": plural branch '" ++ @tagName(c) ++
                        "' can never be selected for integers in '" ++ tag ++
                        "' — use =N for exact numbers, or remove it");
            }
            // Every category this language can actually select must be
            // answered — by its keyword, or by =N exacts that provably
            // cover it (a finite category like English `one` = {1}).
            for (rule.cats) |rc| {
                if (rc.cat == .other) continue;
                if (!rc.required) continue; // the Romance whole-millions `many`
                var present = false;
                for (p.branches) |b| {
                    if (b.selector == .category and b.selector.category == rc.cat) present = true;
                }
                if (present) continue;
                const covered = switch (rc.cover) {
                    .infinite => false,
                    .finite => |values| blk: {
                        for (values) |v| {
                            var hit = false;
                            for (p.branches) |b| {
                                if (b.selector == .exact and b.selector.exact == v) hit = true;
                            }
                            if (!hit) break :blk false;
                        }
                        break :blk true;
                    },
                };
                if (!covered)
                    @compileError("nokre l10n: " ++ ctx ++ ": plural on '" ++ p.arg ++
                        "' is missing the '" ++ @tagName(rc.cat) ++ "' form, which '" ++ tag ++
                        "' selects for some integers (e.g. " ++
                        std.fmt.comptimePrint("{d}", .{sampleFor(rc)}) ++ ")");
            }
            for (p.branches) |b| validateSegs(ctx, tag, b.segs, tmpl_selects);
        },
        .select => |s| {
            var has_other = false;
            for (s.branches) |b| {
                if (std.mem.eql(u8, b.name, "other")) has_other = true;
            }
            if (!has_other)
                @compileError("nokre l10n: " ++ ctx ++ ": select on '" ++ s.arg ++
                    "' needs an 'other' branch");
            if (selectSetFor(tmpl_selects, s.arg)) |tmpl_names| {
                var mismatch = s.branches.len != tmpl_names.len;
                for (s.branches) |b| {
                    var found = false;
                    for (tmpl_names) |n| {
                        if (std.mem.eql(u8, n, b.name)) found = true;
                    }
                    if (!found) mismatch = true;
                }
                if (mismatch)
                    @compileError("nokre l10n: " ++ ctx ++ ": select on '" ++ s.arg ++
                        "' must carry exactly the template's cases — the case set is part of " ++
                        "the message's interface, and a dropped case falls to 'other' silently");
            }
            for (s.branches) |b| validateSegs(ctx, tag, b.segs, tmpl_selects);
        },
    };
}

/// A date placeholder is only readable through a skeleton: `{when}`
/// bare would have to pick a format on its own, which is exactly the
/// locale-library guessing nokre refuses. Caught here, per locale, so
/// the translation carrying it fails the build even before any call
/// site formats the message.
fn rejectBareDateArgs(comptime ctx: []const u8, comptime segs: arb.Segs, comptime params: []const Param) void {
    for (segs) |seg| switch (seg) {
        .literal, .pound, .date => {},
        .arg => |name| if (paramKind(params, name) == .date)
            @compileError("nokre l10n: " ++ ctx ++ ": '{" ++ name ++ "}' is a date placeholder " ++
                "and a bare reference has no format — write {" ++ name ++ ", date, skeleton} " ++
                "(y, M, d, MMM, or yMd)"),
        .plural => |p| for (p.branches) |b| rejectBareDateArgs(ctx, b.segs, params),
        .select => |s| for (s.branches) |b| rejectBareDateArgs(ctx, b.segs, params),
    };
}

/// A concrete integer the category selects, for the missing-form
/// diagnostic: the first member of a finite category, the table's
/// stated sample otherwise.
fn sampleFor(comptime rc: plural_rules.Cat) u64 {
    return switch (rc.cover) {
        .finite => |values| values[0],
        .infinite => rc.sample.?,
    };
}

fn joinLiterals(comptime segs: arb.Segs) []const u8 {
    comptime var out: []const u8 = "";
    inline for (segs) |seg| out = out ++ seg.literal;
    return out;
}

fn localeIdent(comptime tag: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (tag, 0..) |c, i| {
        const mapped = if (c == '-') '_' else c;
        const ok = switch (mapped) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9' => i != 0,
            else => false,
        };
        if (!ok)
            @compileError("nokre l10n: '" ++ tag ++ "' is not a usable @@locale tag " ++
                "(letters, digits, '-' or '_' subtag separators)");
        out = out ++ &[_]u8{mapped};
    }
    if (out.len == 0) @compileError("nokre l10n: empty @@locale");
    return out;
}

fn checkArgs(comptime A: type, comptime params: []const Param, comptime key_name: []const u8) void {
    const info = @typeInfo(A);
    if (info != .@"struct")
        @compileError("nokre l10n: message '" ++ key_name ++
            "': args must be a struct literal like .{ .name = value }");
    for (params) |p| {
        if (!@hasField(A, p.name))
            @compileError("nokre l10n: message '" ++ key_name ++ "' needs argument '." ++
                p.name ++ "' (" ++ kindName(p.kind) ++ ")");
    }
    inline for (info.@"struct".fields) |f| {
        const p = for (params) |p| {
            if (std.mem.eql(u8, p.name, f.name)) break p;
        } else @compileError("nokre l10n: message '" ++ key_name ++ "' has no placeholder '" ++
            f.name ++ "'");
        switch (p.kind) {
            .int => switch (@typeInfo(f.type)) {
                // Counts travel as i64 (writeDecimal, `#`); a type whose
                // values can exceed it (u64, u128, i128 …) would trap at
                // the runtime @intCast instead of failing here, where
                // the message can name the argument.
                .int => |int| {
                    if (int.bits > 64 or (int.signedness == .unsigned and int.bits >= 64))
                        @compileError("nokre l10n: message '" ++ key_name ++ "': argument '." ++
                            p.name ++ "' must fit in i64 (u64 and wider integers can exceed it)");
                },
                .comptime_int => {},
                else => @compileError("nokre l10n: message '" ++ key_name ++ "': argument '." ++
                    p.name ++ "' must be an integer"),
            },
            .string => if (!isStringy(f.type))
                @compileError("nokre l10n: message '" ++ key_name ++ "': argument '." ++
                    p.name ++ "' must be []const u8"),
            .date => if (!isCivilDate(f.type))
                @compileError("nokre l10n: message '" ++ key_name ++ "': argument '." ++
                    p.name ++ "' must be a civil date — a struct with integer year, month, " ++
                    "and day fields (l10n.Date; l10n.dateFromMillis for epoch milliseconds)"),
        }
    }
}

/// A civil date by shape, not by name: `l10n.Date`, an anonymous
/// `.{ .year = …, .month = …, .day = … }`, or a domain struct that
/// already carries the three fields — anything whose year, month, and
/// day are integers.
fn isCivilDate(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    inline for (.{ "year", "month", "day" }) |name| {
        if (!@hasField(T, name)) return false;
        switch (@typeInfo(@FieldType(T, name))) {
            .int, .comptime_int => {},
            else => return false,
        }
    }
    return true;
}

fn isStringy(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

// ---------------------------------------------------------------------------
// runtime emission — comptime-unrolled straight-line writes

/// Where emission lands: a caller buffer (`fmt` — `NoSpace` when it
/// runs out) or nowhere (`fmtIn`'s counting walk, `buf` null, which
/// cannot fail). One sink under one emitter, rather than a counting
/// emitter beside a writing one, so the length a count promises and the
/// bytes a write produces cannot drift.
const Sink = struct {
    buf: ?[]u8,
    pos: usize = 0,

    fn write(self: *Sink, bytes: []const u8) error{NoSpace}!void {
        if (self.buf) |b| {
            if (b.len - self.pos < bytes.len) return error.NoSpace;
            @memcpy(b[self.pos..][0..bytes.len], bytes);
        }
        self.pos += bytes.len;
    }
};

/// The digit shapes a catalog's numbers render in. Each non-ASCII set
/// is a fixed ten-codepoint substitution of '0'–'9' — byte-determined
/// by the value alone, so the argument that refuses NumberFormat
/// (platform locale libraries, different bytes per OS) does not apply.
const Digits = enum { ascii, arabic_indic, extended_arabic_indic };

/// Digit shapes from the language subtag of a catalog's @@locale tag.
/// Persian convention is Extended Arabic-Indic (۰–۹, U+06F0–U+06F9);
/// Arabic proper is Arabic-Indic (٠–٩, U+0660–U+0669); everything else
/// — including Arabic-script locales like Urdu whose CLDR default is
/// Western digits — stays ASCII. A closed table and no override,
/// deliberately: the locale already is the decision, and a knob would
/// let two apps disagree about what "3" looks like in the same
/// language. Extending it is one row here plus a test.
fn digitsOfTag(comptime tag: []const u8) Digits {
    const lang = plural_rules.languageOf(tag);
    if (plural_rules.tagEql(lang, "fa")) return .extended_arabic_indic;
    if (plural_rules.tagEql(lang, "ar")) return .arabic_indic;
    return .ascii;
}

/// Decimal, hand-rolled: integer math only, identical bytes on every
/// platform, and no dependency on std.fmt's evolving surface. The
/// digit shapes are the catalog locale's (`digitsOfTag`); the minus
/// sign stays ASCII '-' in every set — digits are the decided scope,
/// and localized punctuation would be a separate argument to have.
/// `min_digits` zero-pads the magnitude (the sign stays outside the
/// pad): 1 everywhere except the date `yMd` skeleton's ISO fields.
fn writeDecimal(comptime digits: Digits, sink: *Sink, v: i64, comptime min_digits: usize) error{NoSpace}!void {
    var tmp: [20]u8 = undefined;
    var n: u64 = @abs(v);
    var i: usize = tmp.len;
    while (true) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
        if (n == 0) break;
    }
    while (tmp.len - i < min_digits) {
        i -= 1;
        tmp[i] = '0';
    }
    if (v < 0) try sink.write("-");
    switch (digits) {
        .ascii => try sink.write(tmp[i..]),
        .arabic_indic, .extended_arabic_indic => {
            // Both blocks are contiguous, so each shaped digit is the
            // ASCII digit re-based onto a fixed two-byte UTF-8 pair.
            const lead: u8, const base: u8 = switch (digits) {
                .arabic_indic => .{ 0xD9, 0xA0 }, // U+0660 is D9 A0
                .extended_arabic_indic => .{ 0xDB, 0xB0 }, // U+06F0 is DB B0
                .ascii => unreachable,
            };
            for (tmp[i..]) |c|
                try sink.write(&.{ lead, base + (c - '0') });
        },
    }
}

fn intValue(v: anytype) i64 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => @intCast(v),
        else => unreachable, // checkArgs already rejected it
    };
}

fn paramKind(comptime params: []const Param, comptime name: []const u8) Kind {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.kind;
    unreachable; // usage collection put every used name in params
}

fn emitSegs(comptime segs: arb.Segs, comptime tag: []const u8, comptime params: []const Param, comptime months: []const []const u8, args: anytype, pound: i64, sink: *Sink) error{NoSpace}!void {
    inline for (segs) |seg| switch (seg) {
        .literal => |s| try sink.write(s),
        .arg => |name| switch (comptime paramKind(params, name)) {
            .string => try sink.write(@field(args, name)),
            .int => try writeDecimal(comptime digitsOfTag(tag), sink, intValue(@field(args, name)), 1),
            .date => unreachable, // a date arg is always a `.date` seg
        },
        .pound => try writeDecimal(comptime digitsOfTag(tag), sink, pound, 1),
        .date => |d| try emitDate(d, tag, months, @field(args, d.arg), sink),
        .plural => |p| try emitPlural(p, tag, params, months, args, sink),
        .select => |s| try emitSelect(s, tag, params, months, args, pound, sink),
    };
}

/// One civil-date component (or the ISO composite) in the catalog
/// locale's digit shapes. Deterministic by construction: the value is
/// the caller's, the words are the catalog's reserved month keys, and
/// the only arithmetic is a decimal write.
fn emitDate(comptime d: arb.DateRef, comptime tag: []const u8, comptime months: []const []const u8, v: anytype, sink: *Sink) error{NoSpace}!void {
    const digits = comptime digitsOfTag(tag);
    switch (comptime d.skeleton) {
        .y => try writeDecimal(digits, sink, @intCast(v.year), 1),
        .M => try writeDecimal(digits, sink, @intCast(v.month), 1),
        .d => try writeDecimal(digits, sink, @intCast(v.day), 1),
        .MMM => {
            // Total over u8, as the consumer switches this subsumed
            // were: 1–11 name their month, everything else reads as
            // December rather than trapping mid-frame.
            const month: i64 = @intCast(v.month);
            const m: usize = if (month >= 1 and month <= 12) @intCast(month) else 12;
            try sink.write(months[m - 1]);
        },
        .yMd => {
            // ISO 8601, zero-padded — the one composed skeleton, for
            // the locale-blind numeric date; digit shapes still apply,
            // like every other number the catalog renders.
            try writeDecimal(digits, sink, @intCast(v.year), 4);
            try sink.write("-");
            try writeDecimal(digits, sink, @intCast(v.month), 2);
            try sink.write("-");
            try writeDecimal(digits, sink, @intCast(v.day), 2);
        },
    }
}

fn emitPlural(comptime p: arb.Plural, comptime tag: []const u8, comptime params: []const Param, comptime months: []const []const u8, args: anytype, sink: *Sink) error{NoSpace}!void {
    const count = intValue(@field(args, p.arg));
    const n: u64 = @abs(count);
    // ICU precedence: =N exacts win over categories.
    inline for (p.branches) |br| {
        if (comptime br.selector == .exact) {
            if (n == comptime br.selector.exact)
                return emitSegs(br.segs, tag, params, months, args, count, sink);
        }
    }
    const rule = comptime plural_rules.forLocale(tag).?; // validated at Bundle time
    const cat = rule.select(n);
    inline for (p.branches) |br| {
        if (comptime br.selector == .category and br.selector.category != .other) {
            if (cat == comptime br.selector.category)
                return emitSegs(br.segs, tag, params, months, args, count, sink);
        }
    }
    // The mandatory other — also the landing spot for a finite category
    // whose members were all peeled off by exacts above.
    const other = comptime otherBranch(p);
    return emitSegs(other, tag, params, months, args, count, sink);
}

fn otherBranch(comptime p: arb.Plural) arb.Segs {
    for (p.branches) |br| {
        if (br.selector == .category and br.selector.category == .other) return br.segs;
    }
    unreachable; // validateSegs required it
}

fn emitSelect(comptime s: arb.Select, comptime tag: []const u8, comptime params: []const Param, comptime months: []const []const u8, args: anytype, pound: i64, sink: *Sink) error{NoSpace}!void {
    const v: []const u8 = @field(args, s.arg);
    inline for (s.branches) |br| {
        if (comptime !std.mem.eql(u8, br.name, "other")) {
            if (std.mem.eql(u8, v, br.name))
                return emitSegs(br.segs, tag, params, months, args, pound, sink);
        }
    }
    const other = comptime selectOther(s);
    return emitSegs(other, tag, params, months, args, pound, sink);
}

fn selectOther(comptime s: arb.Select) arb.Segs {
    for (s.branches) |br| {
        if (std.mem.eql(u8, br.name, "other")) return br.segs;
    }
    unreachable; // validateSegs required it
}

// ---------------------------------------------------------------------------
// runtime tag matching (resolve)

// Tag identity (case, separator) is plural_rules.zig's one rule —
// `tagEql`/`languageOf` there — shared by this file's runtime resolve
// and the comptime bundle machinery alike.

// ---------------------------------------------------------------------------
// writing direction

/// ISO 15924 codes for the right-to-left scripts of living languages,
/// lowercased for comparison. An explicit script subtag is decisive, so
/// this is what makes `az-Arab` RTL and `az-Latn` LTR.
const rtl_scripts = [_][]const u8{
    "arab", "aran", // Arabic (and Nastaliq)
    "hebr", // Hebrew
    "syrc", // Syriac
    "thaa", // Thaana (Divehi)
    "nkoo", // N'Ko
    "adlm", // Adlam (Fulani)
    "rohg", // Hanifi Rohingya
    "mand", // Mandaic
    "samr", // Samaritan
    "mend", // Mende Kikakui
    "yezi", // Yezidi
};

/// Primary language subtags whose default script is right-to-left, for
/// tags that carry no explicit script. Ambiguous languages written in
/// more than one script (Kurdish `ku`, Punjabi `pa`) are deliberately
/// absent — tag them with a script subtag (`ku-Arab`) to place them.
const rtl_languages = [_][]const u8{
    "ar", // Arabic
    "fa", "prs", // Persian, Dari
    "he", "iw", // Hebrew (and its legacy code)
    "ur", // Urdu
    "ps", // Pashto
    "sd", // Sindhi
    "ug", // Uyghur
    "yi", "ji", // Yiddish (and its legacy code)
    "dv", // Divehi
    "ckb", // Central Kurdish (Sorani)
    "nqo", // N'Ko
    "syr", "arc", // Syriac, Aramaic
};

/// The writing direction CLDR assigns a locale tag, from its subtags:
/// an explicit script subtag decides (`az-Arab` is `.rtl`, `az-Latn`
/// `.ltr`); with none, the primary language subtag's default script
/// does. Case and '-'/'_' separators are ignored, as in `resolve`.
/// Unknown or Latin-script tags are `.ltr` — the safe default. Runtime
/// (feed a device tag from the future locale service) and comptime (how
/// `Bundle.dir` reads its own tags) both call this.
pub fn directionOfTag(tag_str: []const u8) Direction {
    var lang: []const u8 = tag_str;
    var script: ?[]const u8 = null;
    var start: usize = 0;
    var index: usize = 0;
    var i: usize = 0;
    while (i <= tag_str.len) : (i += 1) {
        if (i != tag_str.len and tag_str[i] != '-' and tag_str[i] != '_') continue;
        const sub = tag_str[start..i];
        if (index == 0) {
            lang = sub;
        } else if (index == 1 and sub.len == 4 and allAlpha(sub)) {
            script = sub; // BCP 47: a 4-alpha second subtag is the script
        }
        index += 1;
        start = i + 1;
    }
    if (script) |s| {
        for (rtl_scripts) |rs| if (plural_rules.tagEql(rs, s)) return .rtl;
        return .ltr;
    }
    for (rtl_languages) |rl| if (plural_rules.tagEql(rl, lang)) return .rtl;
    return .ltr;
}

fn allAlpha(s: []const u8) bool {
    for (s) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'))) return false;
    }
    return true;
}
