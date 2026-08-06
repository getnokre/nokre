//! Every URL one page also exists at, in another language — the
//! `hreflang` set, which the document's head and the sitemap both
//! spend.
//!
//! **The set is the same for every page in it, and that is the whole
//! design.** A page's alternates are its *own* variants, so the English
//! copy and the Persian copy of one route carry byte-identical blocks.
//! One value therefore serves the whole family: reciprocity — the
//! property a search console complains about months later, when one
//! page lists a sibling that does not list it back — is not a rule
//! anybody can break here, because there is one set and every variant
//! is handed it. Self-inclusion is the other half and is checked, since
//! only the document knows which of the paths is its own
//! (document.zig's `checkMeta`).
//!
//! **What is derived and what is stated.** The tags are derived: they
//! come out of the catalog (`L.tag`) and a driver never types a BCP 47
//! string. The completeness of the set is derived too, and it is a
//! *type* — one required field per bundled locale — so a locale in the
//! ARB set and missing from an alternate set is a compile error, and
//! one the bundle does not carry cannot be written down. Everything
//! else is stated: the origin, the prefix scheme, whether a path ends
//! in a slash, what a route's path even looks like. nokre computes no
//! path here and carries no prefix anywhere
//! (docs/internals/dom-edition.md, "The locale axis").

const std = @import("std");

const serialize = @import("serialize.zig");

const Emitter = serialize.Emitter;

/// The reserved `hreflang` value for the page a reader whose language
/// this site does not carry is sent to.
///
/// **It is not a language, and it is not the default locale's URL** —
/// which is the one mistake this whole block is written wrong by. Under
/// this edition's scheme it is the address of the sniffing stub
/// (`localeStub`): the one URL in the set that is about the *reader*
/// rather than about a language, standing at the unprefixed path, and
/// the only one that may answer two readers differently. The default
/// locale is a locale and has a path in `Alternates.paths` beside every
/// other; nothing here reads `L.default_locale`.
pub const x_default = "x-default";

/// One copy of one page: what language it is in, and where it is.
pub const Alternate = struct {
    /// The `hreflang` value — a tag out of the bundle, or `x_default`.
    /// Never a string a driver typed: `Alternates.set` fills these from
    /// `L.tag`, which is the catalog's own answer.
    hreflang: []const u8,
    /// Where that copy is published: a path on the document's origin,
    /// leading slash included. The site resolver's answer, copied —
    /// `Meta.path` draws the same line and for the same reason.
    path: []const u8,
};

/// The alternate set of one page, stated per bundled locale.
///
/// Takes the bundle rather than a list of tags, for `LocaleStub`'s
/// reason: a declared locale list is a second source of truth that can
/// silently disagree with the ARB set — one listed and not bundled
/// publishes a `hreflang` at a tree of template strings, one bundled
/// and not listed is a language no crawler is ever told about. Here
/// neither is statable.
///
/// A generator with thousands of pages writes the literal once, in a
/// helper of its own, and spends `L.tag` for the prefix so the segment
/// in the path and the tag in the attribute are one fact:
///
/// ```zig
/// fn altsFor(gpa: std.mem.Allocator, path: []const u8) !dom.Alternates(L).Set {
///     var spec: dom.Alternates(L) = .{ .stub = path, .paths = undefined };
///     inline for (comptime std.enums.values(L.Locale)) |loc| {
///         @field(spec.paths, @tagName(loc)) =
///             try std.fmt.allocPrint(gpa, "/{s}{s}", .{ L.tag(loc), path });
///     }
///     return spec.set();
/// }
/// ```
pub fn Alternates(comptime L: type) type {
    return struct {
        const Self = @This();
        const locales = std.enums.values(L.Locale);

        /// One path per bundled locale, named by it. The type is
        /// generated from `L.Locale`, so this cannot be short, long, or
        /// spelled for a locale the bundle does not have — the
        /// completeness invariant as a type rather than a runtime
        /// sweep (`LocaleStub.choices` is the same shape, and on the
        /// stub it is literally the same data with a label attached).
        paths: std.enums.EnumFieldStruct(L.Locale, []const u8, null),

        /// The unprefixed path this page's sniffing stub stands at —
        /// where `x-default` points, because that is what a stub is
        /// (`localeStub`).
        ///
        /// **Not the default locale's URL.** Required and separate for
        /// exactly that reason: a driver cannot leave it out and get
        /// the template's path by default, which is how `x-default`
        /// comes to name a page that is in one particular language.
        /// See `x_default`.
        stub: []const u8,

        /// One entry per bundled locale, in the bundle's order, then
        /// the `x-default`. A fixed-size array by value: the caller
        /// keeps it in a local and hands `&it` to `Meta.alternates` and
        /// to `Sitemap.url`, which is what makes the head and the
        /// sitemap literally the same set rather than two derivations
        /// that agree today.
        pub const Set = [locales.len + 1]Alternate;

        /// The derivation, and the only place tags meet paths.
        pub fn set(self: Self) Set {
            var out: Set = undefined;
            inline for (locales, 0..) |loc, i| {
                out[i] = .{
                    .hreflang = comptime L.tag(loc),
                    .path = @field(self.paths, @tagName(loc)),
                };
            }
            out[locales.len] = .{ .hreflang = x_default, .path = self.stub };
            return out;
        }
    };
}

/// What a driver can get wrong about a set it did not derive — every
/// one of them impossible when `Alternates.set` built it, and every one
/// of them reachable, because `Meta.alternates` is a plain slice a
/// generator may assemble itself.
///
/// A subset of both `MetaError` and `SitemapError`, so the two writers
/// answer the same mistake with the same name.
pub const Error = error{
    /// A path here does not begin with `/`, so joining it to an origin
    /// produces something that is not the URL anybody meant.
    PathNotRooted,
    /// **The page is not among its own alternates.** An alternate set
    /// is the set of URLs one page exists at, so the page belongs to
    /// it: a block that names its siblings and not itself tells a
    /// crawler this document is a copy of something else. It is also
    /// what a document with no URL of its own (`Meta.path` null) gets,
    /// which is correct — a page nobody is meant to arrive at cannot be
    /// a member of a set.
    AlternatesOmitThisPage,
    /// Two entries claim one `hreflang`. A second `x-default` lands
    /// here too, which is the shape a driver reaches for when it wants
    /// two "default" pages and there is only ever one.
    AlternateHreflangRepeated,
    /// Two languages at one address — which makes one of them
    /// unreachable and hands its readers the other's, the failure
    /// `LocaleStub`'s `ChoiceHrefsCollide` names on the other page. The
    /// `x-default` is exempt: pointing it at a language copy is a
    /// sanctioned configuration, and pointing it at the stub is this
    /// edition's.
    AlternatePathRepeated,
};

/// Scheme, and no trailing slash for the path that follows to supply.
/// One statement of the rule, spent by `Meta`, by the stub and by the
/// sitemap, so a site cannot be strict about its head and lax about its
/// sitemap.
pub fn checkOrigin(origin: []const u8) error{ OriginNotAbsolute, OriginEndsInSlash }!void {
    if (std.mem.indexOf(u8, origin, "://") == null) return error.OriginNotAbsolute;
    if (std.mem.endsWith(u8, origin, "/")) return error.OriginEndsInSlash;
}

pub fn checkPath(path: []const u8) error{PathNotRooted}!void {
    if (!std.mem.startsWith(u8, path, "/")) return error.PathNotRooted;
}

/// The set's own rules, plus self-inclusion against the path of the
/// page carrying it. `own` is `null` for a document with no URL.
///
/// An empty set is not checked and is not a defect: a page that exists
/// in one language has no choice of URLs to describe, and its canonical
/// already says everything there is to say about where it lives.
pub fn check(set: []const Alternate, own: ?[]const u8) Error!void {
    if (set.len == 0) return;
    for (set, 0..) |a, i| {
        try checkPath(a.path);
        for (set[0..i]) |seen| {
            if (std.mem.eql(u8, seen.hreflang, a.hreflang))
                return error.AlternateHreflangRepeated;
            if (!isDefault(seen.hreflang) and !isDefault(a.hreflang) and
                std.mem.eql(u8, seen.path, a.path)) return error.AlternatePathRepeated;
        }
    }
    const p = own orelse return error.AlternatesOmitThisPage;
    for (set) |a| {
        // Against a *language* entry: a page whose only appearance in
        // its own set is the `x-default` is the chooser stub, and that
        // page is written by `localeStub`, not by `document`.
        if (!isDefault(a.hreflang) and std.mem.eql(u8, a.path, p)) return;
    }
    return error.AlternatesOmitThisPage;
}

fn isDefault(hreflang: []const u8) bool {
    return std.mem.eql(u8, hreflang, x_default);
}

/// The head's half: one `<link rel="alternate">` per entry, joined to
/// the document's own origin.
///
/// Shared by `document` and `localeStub` so the two pages a locale axis
/// publishes — the copies and the chooser they all point back at —
/// carry one block written by one function. A second writer on the stub
/// would be a second chance to disagree with the set.
pub fn links(em: *Emitter, origin: []const u8, set: []const Alternate) !void {
    for (set) |a| {
        try em.raw("<link rel=\"alternate\" hreflang=\"");
        try em.text(a.hreflang);
        try em.raw("\" href=\"");
        try em.text(origin);
        try em.text(a.path);
        try em.raw("\">\n");
    }
}
