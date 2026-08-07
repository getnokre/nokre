//! The Content-Security-Policy a page nokre wrote whole can state about
//! itself, as one inventory with two writers.
//!
//! Both HTML writers in this repository ship one: packaging.zig's app
//! shell (`webIndexHtml`) and this directory's static writer
//! (document.zig's `document` and `localeStub`). A site nokre assembles
//! whole is a site nokre can tell the truth about — it loads its own
//! module, its own scripts, its own stylesheets, its own faces, and it
//! talks to no host it was not told about — and that truth is the same
//! truth on both pages. Written out twice it would be two truths, and
//! the second one is the one that goes stale the next time this edition
//! learns to fetch something.
//!
//! **It is an inventory, not a template.** `default-src 'none'` is what
//! makes that claim checkable rather than decorative: a fetch nobody
//! named is a fetch nobody makes, so the day a driver here needs a new
//! kind of request the page fails loudly in a browser instead of
//! quietly widening. Every directive below is here because something
//! the *library* does would break without it:
//!
//! - `script-src 'self'` and `'wasm-unsafe-eval'` — the site's own boot
//!   module and the driver's modules behind it. Compiling a wasm module
//!   is script execution to a browser, and under any `script-src`
//!   Chrome and Firefox refuse it without the keyword.
//!   `'wasm-unsafe-eval'` and not `'unsafe-eval'`: nokre calls neither
//!   `eval` nor `new Function`, and the narrow keyword says so. Neither
//!   writer emits an inline `<script>` — that is what the directive
//!   exists to refuse, and the per-page bytes are an
//!   `application/json` data block a browser never executes
//!   (document.zig, packaging.zig's `webBootJs`).
//! - `worker-src 'self'` — two of them, both the site's own files:
//!   live-worker.js, the compute actor (docs/services.md), and sw.js,
//!   the service worker the notification service registers
//!   (docs/internals/notifications.md). Stated because `worker-src`
//!   falls back to `child-src` and then to `default-src`, which is
//!   `'none'`; the service worker's own execution context is governed
//!   by the headers its file is served with, not by a page's policy.
//! - `style-src 'self' 'unsafe-inline'` with `style-src-elem 'self'` —
//!   every stylesheet on either page is a file, so no `<style>` block is
//!   admitted anywhere. The inline part is *attributes*, which the
//!   serializer writes on element after element: a list's measured
//!   gutter, a QR's whole-pixel side, a track's bleed, a container's own
//!   gap and padding (docs/internals/dom-edition.md says why each is a
//!   measured number and not a stylesheet's guess). They cannot be
//!   hashed — every one is a value layout just computed — and they
//!   cannot move into script, since the static driver writes pages that
//!   run none. So the pair splits the directive instead of widening it,
//!   and a browser too old for the split falls back to the `style-src`
//!   line, which a page shipping no `<style>` block never spends.
//! - `img-src 'self'` — the shell page's two icons. Nothing the element
//!   set draws: nokre has no image element and the QR is inline `<svg>`
//!   markup rather than a request. It is unconditional all the same,
//!   and the ground is the *other* writer's one seam: `Document.head`
//!   takes markup nokre did not write, what a head fetches is an icon,
//!   and a policy that blocked a favicon would be one no page could
//!   carry (docs/static-sites.md).
//! - `font-src 'self'` — the bundled faces, which every page linking
//!   this edition's stylesheet fetches through its `@font-face` block
//!   (stylesheet.zig).
//! - `connect-src 'self'` plus the declared hosts — the wasm module and
//!   any seed arrive by fetch, which is this directive and not
//!   `script-src`; so does every request the http service makes.
//! - `manifest-src 'self'` — the web-app manifest, which likewise falls
//!   back to `default-src`. Only a shell links one.
//! - `base-uri 'none'` and `form-action 'none'` — neither falls back to
//!   `default-src`, so `'none'` has to be said. An injected `<base>`
//!   would re-point every relative URL in the page, and nokre emits no
//!   form.
//!
//! **What differs between two pages is what is on them, never which
//! writer produced them.** A shell boots a module and may spawn a
//! worker; a locale stub loads one classic script and redirects,
//! fetching nothing and compiling nothing; a published page of prose
//! and links runs no script at all. So the set is derived from `Needs`
//! — facts each writer already holds about the page it is emitting —
//! and a directive a page cannot spend is a directive it does not
//! carry. `default-src 'none'` is the answer for every one that is
//! absent, which is why leaving one out is a *narrowing* and never a
//! hole.
//!
//! **One source here is not the library's**, and it is the one an app
//! outgrows: a fetch is the only outbound request an app's own code can
//! make in this edition — no app supplies script, style, faces or
//! images — so the hosts it talks to are the single thing a consumer
//! states, and `badConnectSrc` checks each one before it reaches a page.
//! A string that lands inside a policy is a string that could end the
//! directive it landed in and start a friendlier one.
//!
//! **What a `<meta>` cannot carry, whatever it says.**
//! `frame-ancestors`, `report-uri`/`report-to` and `sandbox` are ignored
//! in one by specification, so they are the deploying edge's —
//! docs/getting-started.md tells a consumer so in as many words, because
//! a page that looked like the whole story would be worse than no policy
//! at all. serve.zig sends the first of them as a header on every
//! response, which is nokre saying at its own dev server what it tells a
//! consumer's edge to say. One directive an edge must *not* add:
//! `require-trusted-types-for 'script'` would break the live driver,
//! whose whole write path is parsing a frame off-document
//! (`template.innerHTML`) and patching it in.
//!
//! A leaf module with no imports, for driver_files.zig's reason:
//! packaging.zig is one of the two readers, and build.zig reads
//! packaging, so nothing here may reach the rest of the library.

const std = @import("std");

/// What a page about to be written can spend — the derived half, asked
/// of the page rather than of the writer.
///
/// Every field is a fact the writer already holds at the moment it
/// emits the head: whether it is about to write a `<script src>`,
/// whether a module will be compiled, whether the driver behind that
/// module can start a worker, whether anything on the page fetches, and
/// whether a screen is going into the body. None of them is a
/// declaration a consumer makes, because a declaration is the thing to
/// get wrong in the direction nobody notices — the same argument that
/// took `Document.boot`'s "does this page need a runtime" off the
/// driver (document.zig's `needsRuntime`).
pub const Needs = struct {
    /// The page loads a script of the site's own — a boot module, or the
    /// locale chooser. False writes no `script-src` at all, so
    /// `default-src 'none'` answers for it: a published page of prose
    /// and links executes nothing, and says so.
    scripts: bool = false,
    /// A WebAssembly module is compiled on this page. Never true where
    /// `scripts` is false — nothing but the driver compiles one — and
    /// it is a separate fact because the keyword is a real widening of
    /// `script-src` and a stub has no use for it.
    wasm: bool = false,
    /// The driver on this page may instantiate the compute actor or
    /// register the service worker. It is not asked of the app, and
    /// cannot be: which services a *wasm* build links is a fact of a
    /// different compile than the one that wrote the page. What is true
    /// of any page the driver boots is that both files it could reach
    /// for are the site's own, which is what `'self'` grants and all it
    /// grants.
    workers: bool = false,
    /// Something on this page fetches: the module, a seed, or the app's
    /// own requests once it is running.
    connects: bool = false,
    /// A serialized screen is going into this page, so the serializer's
    /// inline style attributes are on it. False for a page whose markup
    /// is written by hand in this library — a stub is a list of links
    /// and carries none — and that page takes the undivided
    /// `style-src 'self'` rather than the split pair.
    style_attrs: bool = false,
    /// The page links a web-app manifest. Only the shell does.
    manifest: bool = false,
};

/// The whole `<meta>` tag, with its trailing newline — one line per
/// directive inside one attribute, which is how both writers have
/// always spelled it.
///
/// The tag rather than the attribute value, because *where* it goes is
/// as much a part of the contract as what is in it: a policy only ever
/// applies to what the parser meets after it, so this belongs
/// immediately behind the charset and ahead of every link, script and
/// style the page carries. A caller that splices it later has written a
/// policy that does not govern its own stylesheet.
pub fn write(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    needs: Needs,
    connect_src: []const []const u8,
) error{OutOfMemory}!void {
    try out.appendSlice(gpa,
        \\<meta http-equiv="Content-Security-Policy" content="
        \\  default-src 'none';
        \\
    );
    if (needs.scripts) {
        try out.appendSlice(gpa, "  script-src 'self'");
        if (needs.wasm) try out.appendSlice(gpa, " 'wasm-unsafe-eval'");
        try out.appendSlice(gpa, ";\n");
    }
    if (needs.workers) try out.appendSlice(gpa, "  worker-src 'self';\n");
    if (needs.style_attrs) {
        try out.appendSlice(gpa,
            \\  style-src 'self' 'unsafe-inline';
            \\  style-src-elem 'self';
            \\
        );
    } else {
        try out.appendSlice(gpa, "  style-src 'self';\n");
    }
    try out.appendSlice(gpa,
        \\  img-src 'self';
        \\  font-src 'self';
        \\
    );
    if (needs.connects) {
        try out.appendSlice(gpa, "  connect-src 'self'");
        // One space per source, on the line `connect-src` already owns:
        // the consumer's own hosts are the only part of this policy that
        // is not the same in every page nokre writes. `badConnectSrc`
        // has already refused anything that could close the attribute or
        // the directive.
        for (connect_src) |src| {
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, src);
        }
        try out.appendSlice(gpa, ";\n");
    }
    if (needs.manifest) try out.appendSlice(gpa, "  manifest-src 'self';\n");
    try out.appendSlice(gpa,
        \\  base-uri 'none';
        \\  form-action 'none'
        \\">
        \\
    );
}

/// The first `connect_src` entry a page will not carry, or null when
/// every one of them is a plain source expression. Two refusals. Anything
/// a source cannot contain — whitespace, a quote, a semicolon, a comma —
/// because that is exactly how one declared origin becomes a second
/// directive. And the bare wildcard, because "every host there is" names
/// no host at all: it is the directive's absence, and a consumer who
/// truly wants that can say so in their own edge configuration rather
/// than have nokre generate it into every page they ship.
///
/// It is deliberately not a URL parser. What it establishes is that a
/// consumer's string cannot *reach past the directive it was written
/// into*; whether the host it names exists, resolves or is the one they
/// meant is not a fact this library can check, and a check that pretended
/// to would be the invention docs/static-sites.md's third question
/// refuses.
pub fn badConnectSrc(sources: []const []const u8) ?[]const u8 {
    for (sources) |src| {
        if (src.len == 0 or std.mem.eql(u8, src, "*")) return src;
        for (src) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', ':', '/', '*', '+', '[', ']' => {},
            else => return src,
        };
    }
    return null;
}

/// Whether a URL a page names is one this policy's `'self'` cannot
/// promise to admit: a URL carrying a scheme, or a protocol-relative
/// one.
///
/// **The policy names exactly one origin, and never learns a second.**
/// Every source above is `'self'` but the declared hosts, and the
/// declared hosts join `connect-src` alone — so a stylesheet, a wasm
/// module, a driver directory or a seed published somewhere else is an
/// asset the page would ask for and the browser would refuse. That is a
/// blank page with a console message, which is the silent direction, so
/// the writers ask this before a byte and refuse instead
/// (document.zig's `CspError`).
///
/// A scheme is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"`, so the
/// first byte that is none of those settles it — every rooted path
/// answers on its first.
pub fn offOrigin(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "//")) return true;
    for (url, 0..) |c, i| switch (c) {
        ':' => return i != 0,
        'a'...'z', 'A'...'Z' => {},
        '0'...'9', '+', '-', '.' => if (i == 0) return false,
        else => return false,
    };
    return false;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

/// The policy as a browser reads it: the content attribute, split into
/// directives. Asserting on lines would be asserting on how it was
/// written; a directive is what the page grants.
fn directives(gpa: std.mem.Allocator, needs: Needs, hosts: []const []const u8) ![][]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try write(gpa, &out, needs, hosts);

    const open = "content=\"";
    const at = std.mem.indexOf(u8, out.items, open).?;
    const rest = out.items[at + open.len ..];
    const body = rest[0..std.mem.indexOfScalar(u8, rest, '"').?];

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |raw| {
        try list.append(gpa, try gpa.dupe(u8, std.mem.trim(u8, raw, " \n")));
    }
    return list.toOwnedSlice(gpa);
}

fn free(gpa: std.mem.Allocator, set: [][]const u8) void {
    for (set) |d| gpa.free(d);
    gpa.free(set);
}

test "the shell's page grants eleven powers and no twelfth" {
    // The shell is the widest page this library writes, and its set is
    // the whole inventory. Written out here rather than left implied,
    // because a consumer trusting nokre to emit a policy is trusting
    // this list — the same assertion packaging_test.zig makes of the
    // file, kept here as a fact about the emitter.
    const set = try directives(testing.allocator, .{
        .scripts = true,
        .wasm = true,
        .workers = true,
        .connects = true,
        .style_attrs = true,
        .manifest = true,
    }, &.{});
    defer free(testing.allocator, set);
    try testing.expectEqualDeep(&[_][]const u8{
        "default-src 'none'",
        "script-src 'self' 'wasm-unsafe-eval'",
        "worker-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "style-src-elem 'self'",
        "img-src 'self'",
        "font-src 'self'",
        "connect-src 'self'",
        "manifest-src 'self'",
        "base-uri 'none'",
        "form-action 'none'",
    }, set);
}

test "a page that runs nothing grants nothing to run it with" {
    // The published page a static site mostly is: prose, links, and no
    // module. Every executable and outbound power is absent, which
    // `default-src 'none'` answers as a refusal — this is the narrowing
    // the derivation exists for.
    const set = try directives(testing.allocator, .{ .style_attrs = true }, &.{});
    defer free(testing.allocator, set);
    try testing.expectEqualDeep(&[_][]const u8{
        "default-src 'none'",
        "style-src 'self' 'unsafe-inline'",
        "style-src-elem 'self'",
        "img-src 'self'",
        "font-src 'self'",
        "base-uri 'none'",
        "form-action 'none'",
    }, set);
}

test "a chooser loads a script, compiles nothing and reaches nowhere" {
    // The locale stub: one classic script of the library's, a list of
    // links, and a `location.replace`. No module is compiled, no worker
    // can exist, nothing fetches, and the markup is written by hand in
    // document.zig with no style attribute in it — so the split pair
    // collapses back to one directive.
    const set = try directives(testing.allocator, .{ .scripts = true }, &.{});
    defer free(testing.allocator, set);
    try testing.expectEqualDeep(&[_][]const u8{
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self'",
        "img-src 'self'",
        "font-src 'self'",
        "base-uri 'none'",
        "form-action 'none'",
    }, set);
}

test "a declared host is a source and never a directive" {
    const hosts = [_][]const u8{ "https://api.example.com", "wss://live.example.com:8443" };
    const with = try directives(testing.allocator, .{
        .scripts = true,
        .wasm = true,
        .workers = true,
        .connects = true,
        .style_attrs = true,
    }, &hosts);
    defer free(testing.allocator, with);
    const without = try directives(testing.allocator, .{
        .scripts = true,
        .wasm = true,
        .workers = true,
        .connects = true,
        .style_attrs = true,
    }, &.{});
    defer free(testing.allocator, without);

    try testing.expectEqual(without.len, with.len);
    for (with, without) |a, b| {
        if (std.mem.startsWith(u8, b, "connect-src")) {
            try testing.expectEqualStrings(
                "connect-src 'self' https://api.example.com wss://live.example.com:8443",
                a,
            );
            continue;
        }
        try testing.expectEqualStrings(b, a);
    }
}

test "a source that could end its own directive is refused" {
    try testing.expectEqual(null, badConnectSrc(&.{
        "https://api.example.com", "*.example.com", "wss://live.example.com:8443", "self.example.com",
    }));
    try testing.expectEqualStrings("x.com; script-src *", badConnectSrc(&.{"x.com; script-src *"}).?);
    try testing.expectEqualStrings("x.com 'unsafe-inline'", badConnectSrc(&.{"x.com 'unsafe-inline'"}).?);
    try testing.expectEqualStrings("x.com\">", badConnectSrc(&.{"x.com\">"}).?);
    try testing.expectEqualStrings("*", badConnectSrc(&.{"*"}).?);
    try testing.expectEqualStrings("", badConnectSrc(&.{""}).?);
}

test "an origin the policy cannot name is told apart from a path" {
    // What a driver publishes on the site itself, which is every
    // default this library has.
    try testing.expect(!offOrigin("/style.css"));
    try testing.expect(!offOrigin("/"));
    try testing.expect(!offOrigin("style.css"));
    try testing.expect(!offOrigin("../assets/app.wasm"));
    try testing.expect(!offOrigin("/md/docs.md?v=2"));
    // And what it publishes somewhere `'self'` does not reach.
    try testing.expect(offOrigin("https://cdn.example.com/style.css"));
    try testing.expect(offOrigin("http://example.com/app.wasm"));
    try testing.expect(offOrigin("//cdn.example.com/style.css"));
}
