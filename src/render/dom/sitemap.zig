//! The sitemap: every URL a generator published, and — where a page
//! exists in more than one language — the same alternate set its head
//! carries.
//!
//! **A home of its own, because a sitemap is not a document.** It has
//! no screen, no head, no locale and no `Emitter`; it is one file
//! *about* a whole tree rather than the page around one. What it shares
//! with document.zig is the derivation
//! ([alternates.zig](alternates.zig)) and the two rules about joining a
//! path to an origin — and sharing exactly those is the point: the
//! head's alternates and the sitemap's must not end up on opposite
//! sides of the boundary, and under `Alternates.set` they are not
//! merely derived alike, they are the same value handed to two writers.
//!
//! **It writes bytes, not a file.** The caller's buffer is the
//! destination and the caller does the `writeFile`, which is where the
//! line drawn when the per-locale generation loop was refused still
//! runs: nothing under `src/render/dom` reaches a filesystem, and
//! output paths, directory layout and what a build does with the bytes
//! stay the driver's (docs/internals/dom-edition.md, "The locale
//! axis"). `stylesheet.write` has the same shape for the same reason.
//!
//! **What it owns is what one file can see and one page cannot.**
//! `<loc>` and `<xhtml:link>` escaped as XML rather than pasted, the
//! `xhtml` namespace declared exactly when something uses it, no URL
//! listed twice, and the alternate graph **closed**: every language
//! copy any entry names is itself an entry. That last one is the check
//! no per-page function could run — a page's own set is complete by
//! construction, but whether the sibling it names was actually
//! published is a fact about the tree.
//!
//! **`lastmod` and `changefreq` are refused, and not for symmetry.**
//! `changefreq` is publishing policy and Google has said for years that
//! it does not use it; a static generator emitting `weekly` for
//! everything is stating a schedule nobody keeps. `lastmod` is a
//! filesystem or VCS fact this library cannot know, and — unlike every
//! destination `Meta` carries — cannot *check* either: its grammar is
//! W3C-datetime, an unparseable one is dropped in silence by every
//! crawler, and the shape a hand-rolled generator actually ships is the
//! build's own clock stamped on every URL, which tells a crawler the
//! whole site changed every deploy. That is worse than absent, and
//! Google's own guidance is to omit `lastmod` unless it is accurate. A
//! consumer that has real per-page timestamps and wants them is a
//! receipt this library does not have yet.

const std = @import("std");

const alternates = @import("alternates.zig");

const Alternate = alternates.Alternate;
const Allocator = std.mem.Allocator;

/// The two the specification states, both as hard errors rather than as
/// warnings: a `<urlset>` past either is rejected whole, so a generator
/// that quietly crossed one publishes a sitemap nothing reads.
pub const max_urls = 50_000;
pub const max_bytes = 50 << 20;

/// What a driver can get wrong about a sitemap, returned before any of
/// it reaches the caller's buffer — the posture `document` takes with
/// `Meta`, and for the same reason: a half-written file is worse than
/// none, and every one of these is a build-time mistake.
pub const SitemapError = alternates.Error || error{
    /// `origin` carries no scheme, so nothing joined to it is a URL a
    /// crawler can fetch. Sitemaps are the one place a relative URL is
    /// not merely wrong but meaningless — the file may be served from
    /// anywhere.
    OriginNotAbsolute,
    /// `origin` ends in `/`, which every path here begins with.
    OriginEndsInSlash,
    /// Two entries claim one URL. Harmless to a crawler and a real
    /// defect in the generator that wrote it: two routes are publishing
    /// to one file, so one of them is not on the site at all.
    UrlRepeated,
    /// An entry names a language copy that is not itself in this
    /// sitemap. Either the sibling was never published, or its path is
    /// misspelled in the set — and both are the failure that shows up
    /// months later as a search console reporting a one-sided
    /// annotation.
    AlternateNotListed,
    /// Past `max_urls`.
    TooManyUrls,
    /// Past `max_bytes`.
    TooLarge,
};

/// One `<urlset>`, built up a URL at a time and serialized at the end.
///
/// It accumulates rather than streaming because both of the things it
/// is for need the whole file in view: the namespace declaration
/// belongs on the opening tag and is only owed if some later entry
/// carries alternates, and the closure check is a question about every
/// entry at once. The strings are copied for the same reason — the
/// alternate set of a page is a fixed-size array a generation loop
/// keeps in a local, and a builder holding borrowed slices across the
/// next iteration is a use-after-free waiting for a driver to write the
/// obvious loop.
///
/// **One file.** A site large enough to want a sitemap index splits the
/// alternate graph across files, and nothing can then check that it
/// closes — which is most of what this type is for. `max_urls` is where
/// that trade actually arrives.
pub const Sitemap = struct {
    gpa: Allocator,
    /// Scheme and host, no trailing slash — `Meta.origin`'s rule, and
    /// checked by the same two lines.
    origin: []const u8,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        path: []const u8,
        alts: []Alternate,
    };

    pub fn init(gpa: Allocator, origin: []const u8) Sitemap {
        return .{ .gpa = gpa, .origin = origin };
    }

    pub fn deinit(self: *Sitemap) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.path);
            for (e.alts) |a| {
                self.gpa.free(a.hreflang);
                self.gpa.free(a.path);
            }
            self.gpa.free(e.alts);
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// One published page and, if it has them, its alternates — the
    /// same `Alternates.set` value its own head was written from.
    ///
    /// Pass `&.{}` for a page that exists in one language only. That is
    /// not a degenerate set to be filled in later: alternates describe
    /// a *choice between URLs*, and a page with one URL has none to
    /// describe — its canonical already says everything there is.
    pub fn url(self: *Sitemap, path: []const u8, alts: []const Alternate) !void {
        try alternates.checkPath(path);
        // The page must be among its own alternates, the rule
        // `checkMeta` runs on the head. Asked again here rather than
        // assumed: a driver may build this slice by hand, and the two
        // writers do not check each other.
        try alternates.check(alts, path);

        const copy = try self.gpa.alloc(Alternate, alts.len);
        errdefer self.gpa.free(copy);
        var made: usize = 0;
        errdefer for (copy[0..made]) |a| {
            self.gpa.free(a.hreflang);
            self.gpa.free(a.path);
        };
        for (alts, 0..) |a, i| {
            const tag = try self.gpa.dupe(u8, a.hreflang);
            errdefer self.gpa.free(tag);
            copy[i] = .{ .hreflang = tag, .path = try self.gpa.dupe(u8, a.path) };
            made = i + 1;
        }

        const p = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(p);
        try self.entries.append(self.gpa, .{ .path = p, .alts = copy });
    }

    /// Checks the whole set, then writes the file into the caller's
    /// buffer. Nothing is appended if any check fails.
    pub fn write(self: *const Sitemap, out: *std.ArrayList(u8)) !void {
        try alternates.checkOrigin(self.origin);
        if (self.entries.items.len > max_urls) return error.TooManyUrls;
        try self.checkClosed();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);

        var carries_alternates = false;
        for (self.entries.items) |e| {
            if (e.alts.len != 0) carries_alternates = true;
        }

        try body.appendSlice(self.gpa,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        );
        // Declared exactly when something below uses the prefix. A
        // sitemap with no alternates and the namespace on it is valid
        // and pointless; one *with* alternates and without it is not
        // well-formed XML at all, and is rejected whole — which is the
        // half a hand-written file gets wrong, because the tag that
        // needs the declaration is nowhere near the tag that carries
        // it.
        if (carries_alternates) {
            try body.appendSlice(self.gpa, " xmlns:xhtml=\"http://www.w3.org/1999/xhtml\"");
        }
        try body.appendSlice(self.gpa, ">\n");

        for (self.entries.items) |e| {
            try body.appendSlice(self.gpa, "<url><loc>");
            try self.xml(&body, self.origin);
            try self.xml(&body, e.path);
            try body.appendSlice(self.gpa, "</loc>");
            for (e.alts) |a| {
                try body.appendSlice(self.gpa, "\n<xhtml:link rel=\"alternate\" hreflang=\"");
                try self.xml(&body, a.hreflang);
                try body.appendSlice(self.gpa, "\" href=\"");
                try self.xml(&body, self.origin);
                try self.xml(&body, a.path);
                try body.appendSlice(self.gpa, "\"/>");
            }
            if (e.alts.len != 0) try body.appendSlice(self.gpa, "\n");
            try body.appendSlice(self.gpa, "</url>\n");
        }
        try body.appendSlice(self.gpa, "</urlset>\n");

        if (body.items.len > max_bytes) return error.TooLarge;
        try out.appendSlice(self.gpa, body.items);
    }

    /// No URL twice, and every language copy anybody names is itself
    /// published here.
    ///
    /// The `x-default` is deliberately outside the closure rule. It is
    /// not a language copy — it is the chooser page, and whether a
    /// chooser is itself indexed is publishing policy, which is the
    /// site resolver's in exactly the sense audit.zig's `Options.skip`
    /// draws it (`x_default`).
    /// Both questions are "is this path among the entries", asked
    /// `entries + entries × alts` times, so the paths go into a set
    /// once and each question is a lookup. Two nested scans over string
    /// compares read fine at the 22 URLs this library's own site has
    /// and is tens of millions of `memcmp`s at the ~3,500 × 4 the first
    /// real consumer arrived with — a build-time cost that grows as the
    /// square of a site the whole point of the type is to let grow.
    ///
    /// The set borrows: keys are the entries' own paths, which outlive
    /// the call, and it is freed before returning — `url()`'s copies
    /// stay the only owned strings here. Bounded by `max_urls`, which
    /// is checked before this runs, so the worst case is a 50,000-key
    /// map and one allocation to hold it. Sorting would have cost an
    /// allocation too and kept a log factor plus the string compares.
    fn checkClosed(self: *const Sitemap) (SitemapError || Allocator.Error)!void {
        var listed: std.StringHashMapUnmanaged(void) = .empty;
        defer listed.deinit(self.gpa);
        try listed.ensureTotalCapacity(self.gpa, @intCast(self.entries.items.len));

        // Both loops stay whole and stay in this order: a sitemap with
        // a repeat *and* a one-sided annotation reports the repeat, as
        // it did when this was two nested scans.
        for (self.entries.items) |e| {
            if (listed.getOrPutAssumeCapacity(e.path).found_existing) return error.UrlRepeated;
        }
        for (self.entries.items) |e| {
            for (e.alts) |a| {
                if (std.mem.eql(u8, a.hreflang, alternates.x_default)) continue;
                if (!listed.contains(a.path)) return error.AlternateNotListed;
            }
        }
    }

    /// The five characters XML reserves, and the reason this file does
    /// not paste URLs in. A query string joins its parameters with `&`,
    /// which opens an entity reference — so one `?a=1&b=2` in a `<loc>`
    /// is a sitemap no parser reads past, and the generator that wrote
    /// it is told nothing.
    fn xml(self: *const Sitemap, out: *std.ArrayList(u8), s: []const u8) !void {
        for (s) |c| switch (c) {
            '&' => try out.appendSlice(self.gpa, "&amp;"),
            '<' => try out.appendSlice(self.gpa, "&lt;"),
            '>' => try out.appendSlice(self.gpa, "&gt;"),
            '"' => try out.appendSlice(self.gpa, "&quot;"),
            '\'' => try out.appendSlice(self.gpa, "&#39;"),
            else => try out.append(self.gpa, c),
        };
    }
};

// ------------------------------------------------------------- tests

const testing = std.testing;

fn built(sm: *const Sitemap) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try sm.write(&out);
    return out.toOwnedSlice(testing.allocator);
}

test "a single-language site gets a flat urlset and no namespace it does not use" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    try sm.url("/", &.{});
    try sm.url("/docs/", &.{});
    const xml = try built(&sm);
    defer testing.allocator.free(xml);

    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\<url><loc>https://example.com/</loc></url>
        \\<url><loc>https://example.com/docs/</loc></url>
        \\</urlset>
        \\
    , xml);
}

test "alternates bring the namespace with them, and every copy is listed" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    const set = [_]Alternate{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = "fa", .path = "/fa/docs/" },
        .{ .hreflang = alternates.x_default, .path = "/docs/" },
    };
    try sm.url("/en/docs/", &set);
    try sm.url("/fa/docs/", &set);
    const xml = try built(&sm);
    defer testing.allocator.free(xml);

    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
        \\<url><loc>https://example.com/en/docs/</loc>
        \\<xhtml:link rel="alternate" hreflang="en" href="https://example.com/en/docs/"/>
        \\<xhtml:link rel="alternate" hreflang="fa" href="https://example.com/fa/docs/"/>
        \\<xhtml:link rel="alternate" hreflang="x-default" href="https://example.com/docs/"/>
        \\</url>
        \\<url><loc>https://example.com/fa/docs/</loc>
        \\<xhtml:link rel="alternate" hreflang="en" href="https://example.com/en/docs/"/>
        \\<xhtml:link rel="alternate" hreflang="fa" href="https://example.com/fa/docs/"/>
        \\<xhtml:link rel="alternate" hreflang="x-default" href="https://example.com/docs/"/>
        \\</url>
        \\</urlset>
        \\
    , xml);
}

test "an alternate nothing published is the one-sided annotation, and it fails the build" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    const set = [_]Alternate{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = "fa", .path = "/fa/docs/" },
        .{ .hreflang = alternates.x_default, .path = "/docs/" },
    };
    // The Persian copy is annotated everywhere and published nowhere —
    // exactly the shape a search console reports months later.
    try sm.url("/en/docs/", &set);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.AlternateNotListed, sm.write(&out));
    // And nothing was written on the way to finding out.
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "the x-default is not held to that rule, because it is not a language copy" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    const set = [_]Alternate{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = alternates.x_default, .path = "/docs/" },
    };
    try sm.url("/en/docs/", &set);
    const xml = try built(&sm);
    defer testing.allocator.free(xml);
    // Whether the chooser page is itself indexed is the site's call, so
    // the stub may be absent from the sitemap and the file still holds.
    try testing.expect(std.mem.indexOf(u8, xml, "hreflang=\"x-default\"") != null);
}

test "a page that is not among its own alternates never reaches the file" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    try testing.expectError(error.AlternatesOmitThisPage, sm.url("/tr/docs/", &.{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = "fa", .path = "/fa/docs/" },
    }));
    try testing.expectEqual(@as(usize, 0), sm.entries.items.len);
}

test "two routes publishing to one URL is a generator defect, not a duplicate line" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    try sm.url("/docs/", &.{});
    try sm.url("/docs/", &.{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.UrlRepeated, sm.write(&out));
}

test "an ampersand in a URL is escaped, because one unescaped ends the file" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    try sm.url("/search/?q=a&r=b", &.{});
    const xml = try built(&sm);
    defer testing.allocator.free(xml);
    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\<url><loc>https://example.com/search/?q=a&amp;r=b</loc></url>
        \\</urlset>
        \\
    , xml);
}

// The closure check answers "is this path an entry" once per entry and
// once per alternate, which is where a set replaced two nested scans.
// A set built from the wrong entries — the first page's, the last
// page's, one locale's — passes every small case above and every one
// of these. The size is arbitrary and small enough to stay a unit test;
// what matters is that the defect is far from the start of the list.
const bench_groups = 300;

fn manyPages(sm: *Sitemap, groups: usize, skip: ?usize) !void {
    var buf: [4][64]u8 = undefined;
    for (0..groups) |g| {
        var set: [4]Alternate = undefined;
        for ([_][]const u8{ "en", "fa", "tr", "ar" }, 0..) |tag, i| {
            set[i] = .{
                .hreflang = tag,
                .path = try std.fmt.bufPrint(&buf[i], "/{s}/s/{d}/", .{ tag, g }),
            };
        }
        for (0..set.len) |i| {
            // The one copy annotated everywhere and published nowhere.
            if (skip) |s| if (g == s and i == 1) continue;
            try sm.url(set[i].path, &set);
        }
    }
}

test "a closed graph of thousands of URLs writes, and every entry is in it" {
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    try manyPages(&sm, bench_groups, null);
    const xml = try built(&sm);
    defer testing.allocator.free(xml);

    try testing.expectEqual(@as(usize, bench_groups * 4), sm.entries.items.len);
    // The first page, the last page, and the alternate annotation of
    // the last — the three places a set built from a prefix breaks.
    try testing.expect(std.mem.indexOf(u8, xml, "<loc>https://example.com/en/s/0/</loc>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<loc>https://example.com/ar/s/299/</loc>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "href=\"https://example.com/fa/s/299/\"") != null);
}

test "a repeat and a one-sided annotation far down a long list both still fail" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    var repeated: Sitemap = .init(testing.allocator, "https://example.com");
    defer repeated.deinit();
    try manyPages(&repeated, bench_groups, null);
    try repeated.url("/ar/s/299/", &.{});
    try testing.expectError(error.UrlRepeated, repeated.write(&out));
    try testing.expectEqual(@as(usize, 0), out.items.len);

    var open_graph: Sitemap = .init(testing.allocator, "https://example.com");
    defer open_graph.deinit();
    try manyPages(&open_graph, bench_groups, 150);
    try testing.expectError(error.AlternateNotListed, open_graph.write(&out));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a sitemap with both defects reports the repeat" {
    // Which one a driver is told about is behavior, not an accident of
    // loop order: every URL is checked for a twin before any alternate
    // is looked up, and a page published twice is the defect that makes
    // the other reading unreliable.
    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    const set = [_]Alternate{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = "fa", .path = "/fa/docs/" },
    };
    try sm.url("/en/docs/", &set);
    try sm.url("/en/docs/", &set);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.UrlRepeated, sm.write(&out));
}

test "the origin and every path take the rules the head takes" {
    var bad: Sitemap = .init(testing.allocator, "example.com");
    defer bad.deinit();
    try bad.url("/", &.{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.OriginNotAbsolute, bad.write(&out));

    var slashed: Sitemap = .init(testing.allocator, "https://example.com/");
    defer slashed.deinit();
    try slashed.url("/", &.{});
    try testing.expectError(error.OriginEndsInSlash, slashed.write(&out));

    var sm: Sitemap = .init(testing.allocator, "https://example.com");
    defer sm.deinit();
    try testing.expectError(error.PathNotRooted, sm.url("docs/", &.{}));
}
