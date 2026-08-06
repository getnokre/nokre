//! The whole HTML document around a serialized screen.
//!
//! [serialize.zig](serialize.zig) writes the screen; this writes the
//! file. Doctype, the root element and its two locale attributes, the
//! head, the two mount points, the skip link and the boot script that
//! turns the file into the app's first frame — everything a browser
//! needs around `content` and `chrome`, in one call.
//!
//! **Why the library and not the driver.** The reference site wrote
//! this by hand and a second static consumer was about to write it
//! again. Half of what is here is not a preference: the charset has to
//! be in the first bytes, the skip link has to name the content mount,
//! the boot script has to name the same two ids the markup used and the
//! same module file the edition ships (`driver_files.entry`), and the
//! root element has to carry the locale the screen was built in. A
//! driver that gets any of them wrong gets no error — a page that
//! renders, and is wrong about what it says or how it reads
//! (docs/internals/dom-edition.md, "The document is the library's; the
//! names in it are the driver's").
//!
//! **What is still the driver's**, and the line is the one round two
//! drew when it declined a document helper that crossed it: every name
//! and every destination the driver invented. The mount-point ids, the
//! addressing mode, the URL the stylesheet was published at, the words
//! on the skip link, the title, the description — all parameters here,
//! none of them defaults with an opinion. nokre writes the structure
//! and the facts it already holds: the locale, the direction, the class
//! list, the paper of both ramps, the module the page boots.
//!
//! **The two seams are bytes, not hooks.** `head` and `body_end` are
//! markup the driver already built, spliced where their names say. A
//! `fn (em)` hook would hand the driver `em.out` and re-open the door
//! `Refs`'s signature closed — and `Emitter.raw` writes wherever the
//! emitter is currently pointed, which is exactly why a driver could
//! not otherwise say "into the head". A field says it. A driver that
//! wants the emitter's escaping while building those bytes points a
//! second `Emitter` at a buffer of its own; nothing here needs the
//! first one to be somewhere else.

const std = @import("std");

const app_mod = @import("../../core/app.zig");
const class_names = @import("class_names.zig");
const color = @import("../../core/color.zig");
const driver_files = @import("driver_files.zig");
const element_mod = @import("../../core/element.zig");
const serialize = @import("serialize.zig");

const App = app_mod.App;
const Emitter = serialize.Emitter;
const Gray = color.Gray;

/// How a link resolves in the browser once the app is running — the
/// `addressing` half of `mount`. The vocabulary is the edition's; which
/// of the two a site is, is the driver's (live.js's `mount`).
pub const Addressing = enum {
    /// A screen is a fragment on one page: the driver intercepts the
    /// click and redraws. `mount`'s own default.
    fragments,
    /// A screen is a file with a URL of its own, so a link is the
    /// browser's — middle-clickable, copyable, Back-able.
    documents,
};

/// The upgrade, one script tag wide: the same `App` over the same route
/// table, booting on top of the file it wrote.
///
/// Present or absent, never half — a page with no `Boot` is a complete
/// document that reads, navigates and prints, which is the whole point
/// of the pair (dom-edition.md, "Live over a generated page").
pub const Boot = struct {
    /// Where the driver published the wasm module.
    wasm: []const u8,
    /// The directory the driver published `driver_files` under, with
    /// its trailing slash. The file name inside it is not the driver's
    /// to type: `driver_files.entry` is the module a page boots, and a
    /// consumer that spelled it here would be the fifth writer of a set
    /// that is data precisely so it cannot be re-typed.
    driver_dir: []const u8 = "/",
    addressing: Addressing = .fragments,
    /// The bytes the page was generated from, for the app to read
    /// inside its first build — a URL, fetched before boot. Empty for a
    /// screen whose builder needs nothing it did not compile in.
    seed: []const u8 = "",
};

/// Everything the driver invented, and nothing it did not.
pub const Document = struct {
    /// The `<title>`, escaped here. A driver that wants a suffix joins
    /// it first: what a page is called is the site's sentence, not a
    /// format string of the library's.
    title: []const u8,
    /// `<meta name="description">`, omitted when empty.
    description: []const u8 = "",
    /// Where the driver published the edition's stylesheet
    /// (`stylesheet.write`). Required: a page that does not link it is
    /// unstyled markup, and no check anywhere would say so.
    stylesheet: []const u8,
    /// Markup spliced at the end of `<head>` — the head seam. Canonical,
    /// alternates, structured data, a preload, a favicon: everything
    /// whose destination is the site's. Written after the tags above so
    /// the charset stays in the first bytes, where a browser stops
    /// looking for it.
    head: []const u8 = "",
    /// The id of the element the framework's layers mount into
    /// (`mount({ into })`).
    chrome_id: []const u8,
    /// The id of the element the screen mounts into
    /// (`mount({ content })`), and what the skip link names.
    content_id: []const u8,
    /// The driver's own classes on the content mount, beside the ones
    /// `rootClass` hands over — `.page`'s reading column here.
    content_class: []const u8 = "",
    /// The skip link's words, in the document's language. Empty writes
    /// no skip link: an app shell whose body is one mount point has
    /// nothing to skip past. The library styles it (`stylesheet.zig`,
    /// the `.skip` rules) because a driver that wrote the element and
    /// forgot the rule ships a permanent link across the top of every
    /// page.
    skip: []const u8 = "",
    /// Markup spliced after the screen and before the boot script — a
    /// footer, a colophon line, whatever stands below the app but
    /// inside the document.
    body_end: []const u8 = "",
    boot: ?Boot = null,
};

/// Writes the whole file: the screen, the chrome, and the document
/// around them.
///
/// The chrome goes first, before the content, because the nav leads the
/// focus order — a property of the tree, not of where CSS puts the bar.
pub fn document(em: *Emitter, doc: Document) !void {
    try em.raw("<!doctype html>\n<html lang=\"");
    try em.text(langTag(em.app));
    // Two attributes and not one. `dir` is what a browser and assistive
    // tech read; `data-direction` is what the sheet's one mirroring rule
    // matches (`stylesheet.zig`'s `sheet`), and a page that stamped only
    // `dir` would be announced correctly and laid out backwards. The
    // live driver stamps `data-direction` and deliberately never `dir`
    // (live.js's `syncRoot`): an app mounted in someone else's document
    // may claim nokre's own surfaces and not the page around them. Here
    // there is no page around them — nokre wrote the file — which is why
    // this is the same refusal rather than a hole in it.
    const dir = @tagName(em.app.direction);
    try em.print("\" dir=\"{s}\" data-direction=\"{s}\"", .{ dir, dir });
    // The third attribute, and the one that is conditional.
    //
    // `stylesheet.zig`'s `write` says the design out loud: the dark
    // ramp's media query is *"all a page with no app behind it has to go
    // on"*, and it stands down the moment `data-appearance` appears
    // (`:root:not([data-appearance])`). That is exactly right for
    // `Scheme.auto`, where the query and the app would answer the same
    // question the same way — so a page from an `auto` app stamps
    // nothing and keeps the designed fallback whole.
    //
    // It is exactly wrong for an app that *pinned* one. There the query
    // is answering a question the app already answered, and answering it
    // differently: an app pinned to `.dark` serialized a page that went
    // light on a light desktop, which is the same defect as the
    // unmirrored RTL page above — a fact core owns that no markup
    // carried. `App.appearance()` resolves the pin, so this is the app's
    // own answer and not a second reading of the enum.
    if (em.app.scheme != .auto) {
        try em.print(" data-appearance=\"{s}\"", .{@tagName(em.app.appearance())});
    }
    try em.raw(">\n");

    try em.raw(
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>
    );
    try em.text(doc.title);
    try em.raw("</title>\n");
    if (doc.description.len != 0) {
        try em.raw("<meta name=\"description\" content=\"");
        try em.text(doc.description);
        try em.raw("\">\n");
    }
    try em.raw("<link rel=\"stylesheet\" href=\"");
    try em.text(doc.stylesheet);
    try em.raw("\">\n");
    // The browser chrome around the page, painted in the page's own
    // paper — both ramps, because a hardcoded pair would sit still while
    // a ramp change moved every page behind it. It is the same fact the
    // sheet's `--paper` carries, said in the one place CSS cannot reach.
    try em.print(
        \\<meta name="theme-color" media="(prefers-color-scheme: light)" content="#{x:0>2}{x:0>2}{x:0>2}">
        \\<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#{x:0>2}{x:0>2}{x:0>2}">
        \\
    , .{
        Gray.paper.byte(.light), Gray.paper.byte(.light), Gray.paper.byte(.light),
        Gray.paper.byte(.dark),  Gray.paper.byte(.dark),  Gray.paper.byte(.dark),
    });
    try em.raw(doc.head);
    try em.raw("</head>\n<body>\n");

    if (doc.skip.len != 0) {
        try em.print("<a class=\"{s}\" href=\"#", .{class_names.skip});
        try em.text(doc.content_id);
        try em.raw("\">");
        try em.text(doc.skip);
        try em.raw("</a>\n");
    }

    // The chrome goes in a mount point of its own rather than loose in
    // the body: the live driver patches the framework's layers as one
    // region and the screen as another, and a region is an element. It
    // costs the document nothing — every layer inside it is fixed, so
    // the element has no size and no effect on where any of them land.
    try em.raw("<div id=\"");
    try em.text(doc.chrome_id);
    try em.raw("\">\n");
    try serialize.chrome(em);
    try em.raw("\n</div>\n");

    try em.raw("<main id=\"");
    try em.text(doc.content_id);
    try em.print("\" class=\"{s}", .{serialize.rootClass(em)});
    if (doc.content_class.len != 0) {
        try em.raw(" ");
        try em.text(doc.content_class);
    }
    try em.raw("\">\n");
    try serialize.content(em);
    try em.raw("\n</main>\n");

    try em.raw(doc.body_end);
    if (doc.boot) |b| try bootScript(em, doc, b);
    try em.raw("</body>\n</html>\n");
}

/// The document's language, as a BCP 47 tag.
///
/// `App.locale()` is the app's own answer (`setLocale`), and `""` is
/// "not chosen yet" — the common boot. An app that never chose is an app
/// speaking the language every other default in `App.Options` speaks:
/// `Chrome`'s words are English, and they are what the nav bar, the
/// sheet's close control and the notices pane say on that page. So the
/// un-chosen state has a language and this is it, rather than an
/// invented default or an empty attribute no browser can use.
///
/// It is a fallback and not a guess in one direction only: a *localized*
/// app that set the direction and forgot the locale gets an `en` page
/// laid out right-to-left, which is visibly wrong on the first screen
/// rather than silently wrong forever.
pub fn langTag(app: *const App) []const u8 {
    const chosen = app.locale();
    if (chosen.len != 0) return chosen;
    return element_mod.default_chrome_tag;
}

fn bootScript(em: *Emitter, doc: Document, b: Boot) !void {
    try em.raw("<script type=\"module\">\nimport { mount } from \"");
    try js(em, b.driver_dir);
    try js(em, driver_files.entry);
    try em.raw("\";\nmount({\n  wasm: \"");
    try js(em, b.wasm);
    try em.raw("\",\n  into: document.getElementById(\"");
    try js(em, doc.chrome_id);
    try em.raw("\"),\n  content: document.getElementById(\"");
    try js(em, doc.content_id);
    try em.raw("\"),\n");
    // Omitted when it is `mount`'s own default: a driver reading its own
    // output should see the choice it made, not the one it did not.
    if (b.addressing == .documents) {
        try em.print("  addressing: \"{s}\",\n", .{@tagName(b.addressing)});
    }
    // The route is the app's, not the driver's: the screen this document
    // holds is the one the router is on, and a boot argument that named
    // some other one would build and paint a screen on the way past.
    if (em.app.router.current()) |route| {
        try em.raw("  route: \"");
        try js(em, route);
        try em.raw("\",\n");
    }
    if (b.seed.len != 0) {
        try em.raw("  seed: \"");
        try js(em, b.seed);
        try em.raw("\",\n");
    }
    try em.raw("});\n</script>\n");
}

/// One driver-supplied string, inside a JavaScript string literal
/// inside a `<script>` block — which is *not* the escape `Emitter.text`
/// does. A `<script>`'s contents are raw text: `&amp;` there is four
/// characters of URL, not an ampersand, and the tag ends at the first
/// `</script>` the bytes contain whether or not it is inside a quote.
///
/// So: the two the literal needs, and `<` as a hex escape, which is what
/// closes the block-ending case whole — `</script>`, `<!--` and
/// `<script` all start with it, and `\x3C` is the same character to
/// every JavaScript engine.
fn js(em: *Emitter, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try em.raw("\\\\"),
        '"' => try em.raw("\\\""),
        '<' => try em.raw("\\x3C"),
        '\n' => try em.raw("\\n"),
        '\r' => try em.raw("\\r"),
        else => try em.out.append(em.gpa, c),
    };
}
