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
//! root element and the boot call have to carry the same locale the
//! screen was built in. A driver that gets any of them wrong gets no
//! error — a page that renders, and is wrong about what it says or how
//! it reads
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
//! **The one page here with no screen in it** is `localeStub`, and it
//! is in this file rather than beside it because it is the same
//! document minus everything: the doctype, the head's fixed tags and
//! the charset-first rule are shared (`headOpen`), and what is left is
//! a list of links and a script. It has no mount points, no `data-n`,
//! no boot and no locale of its own — a page *about* the locale set
//! rather than one written in a locale — which is why it is a second
//! writer instead of a flag on `Document`.
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

const alternates_mod = @import("alternates.zig");
const app_mod = @import("../../core/app.zig");
const class_names = @import("class_names.zig");
const color = @import("../../core/color.zig");
const driver_files = @import("driver_files.zig");
const element_mod = @import("../../core/element.zig");
const serialize = @import("serialize.zig");

const Alternate = alternates_mod.Alternate;
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
///
/// There is no locale field here, deliberately. The language the boot
/// pins is the language the file was written in — `App.locale()`, the
/// same read the root element's `lang` comes from — so a driver has no
/// second one to state and no way to state it differently.
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

/// What the page says about *itself* to something that is not a
/// browser: a crawler, a link preview, a share sheet.
///
/// **The line, and it is the one `audit.zig`'s `Options.skip` drew.**
/// That doc comment says a document destination belongs to the site's
/// resolver and that nokre stands down where the generator is the
/// stricter authority — which is an argument against this type owning
/// any URL, and it is honoured rather than overruled: **every
/// destination here is a field with no default and no derivation.**
/// nokre does not know where a site is published, does not turn a route
/// into a path, and cannot invent either. What it owns is what a driver
/// gets *wrong* about them, which is a different list:
///
/// - `og:url` is the canonical URL. Not "should equal" — there is one
///   `path` and two writes of it, so no second field exists to disagree.
/// - Both are absolute, because both are `origin ++ path` and `origin`
///   is checked for a scheme before a byte is written.
/// - A page with no URL of its own has neither. `path` is `null` and
///   there is nothing to write; the flag-plus-string shape that lets a
///   404 keep claiming `/notfound/` is not statable.
/// - Open Graph is `property=`, Twitter is `name=`. Two vocabularies,
///   one of them RDFa, and a head written by hand mixes them.
/// - The set is complete: a page with Open Graph on it gets a
///   `twitter:card`, because a driver that emits the first and forgets
///   the second has a preview on one network and a bare link on the
///   other.
/// - **A page is among its own alternates**, and every `hreflang` in
///   them is a tag the catalog handed over. The set itself is complete
///   by type and reciprocal by construction, one layer down
///   ([alternates.zig](alternates.zig)); what this type adds is that
///   the page carrying it belongs to it.
///
/// Absent (`Document.meta` is `null`) writes none of it — a page that
/// is not a page on a site, which is what an app shell booting into an
/// empty body is.
pub const Meta = struct {
    /// Scheme and host, no trailing slash — `"https://example.com"`.
    ///
    /// Config, and required: this library has no idea where anything is
    /// published and no default that could stand in. One field, spent
    /// by every URL below and by item-7's alternates after them, so a
    /// document cannot come to carry two origins.
    origin: []const u8,

    /// This document's own path on that origin, leading slash included
    /// — the site resolver's answer, copied and never computed. `"/"`
    /// for a home page.
    ///
    /// **`null` is a document with no URL of its own**, and the reason
    /// this is one nullable field rather than a string with a boolean
    /// beside it. The 404 body is served at whatever address missed, so
    /// a canonical or an `og:url` naming `/notfound/` claims a URL
    /// nobody is meant to arrive at — and a driver holding the pair
    /// writes exactly that the first time it flips the flag and leaves
    /// the string. Here there is nothing left to leave.
    path: ?[]const u8 = null,

    /// Every URL this page also exists at in another language, plus the
    /// `x-default` — `Alternates(L).set`'s answer, which is where the
    /// tags come from and why the set is complete.
    ///
    /// **Empty is the honest answer for a page with one URL**, and the
    /// default. A single-language site has no choice of addresses to
    /// annotate; its canonical already says where the page lives, and a
    /// one-entry `hreflang` block says nothing a crawler did not know.
    /// Alternates start earning their bytes at the second URL — which
    /// under this edition's scheme is the moment a locale prefix and a
    /// stub appear, even at one locale.
    ///
    /// The whole set is one value, shared by every locale's copy of
    /// this page: that is what makes the annotations reciprocal without
    /// anybody checking (alternates.zig). What is checked here is
    /// self-inclusion, since only the document knows which of those
    /// paths is its own.
    alternates: []const Alternate = &.{},

    /// `og:site_name` — what the *site* is called, beside what the page
    /// is called. Omitted when empty.
    site_name: []const u8 = "",

    /// `og:type`. The vocabulary is Open Graph's and open-ended
    /// (`website`, `article`, `profile`, and namespaced verticals past
    /// them), which is why it is a string: which one a page is, is the
    /// site's content, and this library has no opinion about content —
    /// the same verdict `Emitter.json` reached about graph types.
    kind: []const u8 = "website",

    /// `og:title`, when the preview's headline is not the tab's.
    /// Empty takes `Document.title`.
    ///
    /// They legitimately differ: a `<title>` usually carries the site's
    /// name as a suffix, and a card already shows `site_name` beside
    /// the headline, so the suffix there is the site's name twice.
    title: []const u8 = "",

    /// `og:description`. Empty takes `Document.description`, which is
    /// the usual case — and if that is empty too, no description tag is
    /// written at all rather than an empty one.
    description: []const u8 = "",

    /// The card's picture. Absent is a real answer and a common one:
    /// a site with no artwork gets a text card rather than a broken
    /// one.
    image: ?Image = null,

    /// The preview image, which is **not an image element** and does
    /// not become one. nokre has no image element, that refusal is
    /// settled, and this type is nested inside `Meta` so that
    /// `dom.Image` — which would read like the opposite — does not
    /// exist. It is a URL in a `<meta>` tag.
    pub const Image = struct {
        /// A path on `Meta.origin`, leading slash included. Joined here
        /// for the reason `Meta.path` is: Open Graph requires an
        /// absolute URL and a relative one is the mistake that ships,
        /// because it renders fine in every browser and only a crawler
        /// ever notices.
        path: []const u8,
        /// What a reader who cannot see the picture is told about it —
        /// `og:image:alt`. Empty writes no alt, which is honest for a
        /// picture that is the site's wordmark and nothing else.
        alt: []const u8 = "",
        /// How the picture wants to be shown, which is the one thing
        /// `twitter:card` says that Open Graph does not.
        ///
        /// Stated rather than derived from `size`: the choice is
        /// editorial — a banner is cropped to 2:1 and a thumbnail to a
        /// square, and which one an asset survives is something only
        /// whoever drew it knows. A threshold on the aspect ratio would
        /// be this library guessing at someone else's artwork.
        shape: Shape,
        /// The picture's pixel dimensions, if the driver knows them —
        /// `og:image:width` and `og:image:height`. One optional pair
        /// rather than two numbers, so a width without a height is not
        /// statable.
        ///
        /// Worth stating: a crawler that has not fetched the file yet
        /// lays the card out from these, and one that has neither may
        /// show the first share with no picture at all.
        size: ?Pixels = null,

        pub const Shape = enum {
            /// Across the top of the card, cropped to about 2:1 —
            /// `twitter:card: summary_large_image`. The 1200×630 house
            /// style.
            banner,
            /// Beside the text, cropped square — `twitter:card:
            /// summary`.
            thumbnail,
        };

        /// Not `geometry.Size`: that type is layout's, it is signed,
        /// and a negative pixel count has no meaning here.
        pub const Pixels = struct { w: u32, h: u32 };
    };
};

/// What a driver can get wrong about `Meta`, checked before the
/// document writes a byte rather than as it goes — a half-written file
/// is worse than none, and a generator's answer to any of these is to
/// fail the build (docs/internals/dom-edition.md).
pub const MetaError = error{
    /// `Meta.origin` carries no scheme, so nothing joined to it is an
    /// absolute URL.
    OriginNotAbsolute,
    /// `Meta.origin` ends in `/`, which every path here begins with.
    OriginEndsInSlash,
    /// A path in `Meta` — the document's, the image's, or an
    /// alternate's — does not begin with `/`, so joining it to the
    /// origin would produce something that is not the URL anybody
    /// meant.
    PathNotRooted,
} || alternates_mod.Error;

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
    /// What this page tells a crawler, a link preview and a share sheet
    /// — canonical, Open Graph, the Twitter card. `null` writes none of
    /// it. Every destination inside is the driver's; what is nokre's is
    /// that they cannot disagree (`Meta`).
    meta: ?Meta = null,
    /// Markup spliced at the end of `<head>` — the head seam. Structured
    /// data, a preload, a favicon: everything whose destination is the
    /// site's and whose *shape* nokre has no element and no opinion for.
    /// Written after the tags above so the charset stays in the first
    /// bytes, where a browser stops looking for it.
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
    // Before a byte, not as it goes: a document that fails halfway
    // leaves a truncated file behind, and every one of these is a
    // config mistake a build should die on rather than publish.
    if (doc.meta) |m| try checkMeta(m);

    // One read of the app's locale, spent twice: the attribute a
    // browser, a screen reader and a hyphenation table act on, and the
    // tag the boot script pins so the module that lands on this file
    // rebuilds it in the language it was written in. Two writers of one
    // fact is how a page comes to say `fa` and boot `en`, so there is
    // one, here, and neither is a field a driver could set apart.
    const chosen = em.app.locale();
    try em.raw("<!doctype html>\n<html lang=\"");
    try em.text(fallbackTag(chosen));
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

    try headOpen(em, doc.title, doc.description, doc.stylesheet);
    if (doc.meta) |m| try metaTags(em, doc, m);
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
    if (doc.boot) |b| try bootScript(em, doc, b, chosen);
    try em.raw("</body>\n</html>\n");
}

/// `<head>` and the tags every page this module writes carries,
/// whatever else is in it — the charset first, because a browser stops
/// looking for it after the first bytes, and everything else that is a
/// fact rather than a destination.
///
/// Shared by the two writers here so that the rule about the first
/// bytes has one enforcer rather than one per page shape. Neither the
/// element nor the seam is closed: the caller writes its own tags after
/// this and closes the head itself.
fn headOpen(em: *Emitter, title: []const u8, description: []const u8, sheet: []const u8) !void {
    try em.raw(
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>
    );
    try em.text(title);
    try em.raw("</title>\n");
    if (description.len != 0) {
        try em.raw("<meta name=\"description\" content=\"");
        try em.text(description);
        try em.raw("\">\n");
    }
    try em.raw("<link rel=\"stylesheet\" href=\"");
    try em.text(sheet);
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
}

/// The document's language, as a BCP 47 tag.
///
/// `App.locale()` is the app's own answer (`setLocale`), and `""` is
/// "not chosen yet" — the common boot. What stands in for it is
/// `element.default_chrome_tag`: the language *core's own* words are in
/// — the nav bar, the sheet's close control, the notices pane — which
/// is a narrower claim than "the app is English" and is the only one
/// this layer can make. An empty attribute is not a language a browser,
/// a screen reader or a hyphenation table can act on, and any other
/// value would be invented.
///
/// **Where the stand-in and the page diverge, and why nothing here can
/// see it.** An app with a catalog usually says
/// `app.setChrome(L.chrome(loc))`, so the words above are not the ones
/// on its screens. If that app also never calls `setLocale`, everything
/// it renders comes from its catalog's *template* — Persian, say — and
/// so does the boot, which pins `""` and resolves to that same template
/// (`L.resolve`). The markup and the module that lands on it therefore
/// agree, and the attribute alone is wrong. Nothing at this layer can
/// tell: `l10n.Bundle` is a comptime type the *app* instantiates, no
/// module under `render/` names l10n at all, and `App` holds a tag
/// rather than a catalog. It is a misuse — the documented three lines
/// choose the locale (docs/localization.md), and a per-locale
/// generation loop chooses it per page — but a silent one, and this
/// comment is where it is written down.
///
/// It is a fallback and not a guess in one direction only: a *localized*
/// app that set the direction and forgot the locale gets an `en` page
/// laid out right-to-left, which is visibly wrong on the first screen
/// rather than silently wrong forever.
pub fn langTag(app: *const App) []const u8 {
    return fallbackTag(app.locale());
}

fn fallbackTag(chosen: []const u8) []const u8 {
    if (chosen.len != 0) return chosen;
    return element_mod.default_chrome_tag;
}

fn checkMeta(m: Meta) MetaError!void {
    try alternates_mod.checkOrigin(m.origin);
    if (m.path) |p| try alternates_mod.checkPath(p);
    if (m.image) |img| try alternates_mod.checkPath(img.path);
    // The set's own rules, and this page's membership in it. A `null`
    // path with alternates on it lands here as `AlternatesOmitThisPage`
    // and is exactly that: a document with no URL of its own cannot be
    // one of the URLs a page exists at.
    try alternates_mod.check(m.alternates, m.path);
}

/// Canonical, Open Graph and the Twitter card, in one pass so the
/// things that must agree are written from one value.
///
/// **What is deliberately not here: `og:locale`.** The page's language
/// is a fact this file already holds — it is on `<html lang>` — and it
/// still does not become a tag, because Open Graph's locale is
/// `language_TERRITORY` and a BCP 47 tag need not carry a territory at
/// all. `fa` would have to become `fa_IR` or `fa_AF`, and picking is
/// inventing a fact about the reader nobody stated. The tag a machine
/// can act on is `lang`, and it is written correctly.
fn metaTags(em: *Emitter, doc: Document, m: Meta) !void {
    // The canonical and `og:url` come from this one optional, which is
    // the whole of "they cannot disagree": there is no second string to
    // keep in step and no flag to leave behind.
    if (m.path) |p| {
        try em.raw("<link rel=\"canonical\" href=\"");
        try url(em, m.origin, p);
        try em.raw("\">\n");
    }
    // Beside the canonical, because they answer one question together:
    // the canonical says which URL *this* content lives at, and these
    // say which languages that URL has siblings in. A crawler that has
    // one without the other picks a copy at random for every reader.
    try alternates_mod.links(em, m.origin, m.alternates);
    // `property`, not `name`: Open Graph is RDFa, and a head written by
    // hand mixes the two vocabularies about as often as not.
    try em.raw("<meta property=\"og:type\" content=\"");
    try em.text(m.kind);
    try em.raw("\">\n");
    if (m.site_name.len != 0) {
        try em.raw("<meta property=\"og:site_name\" content=\"");
        try em.text(m.site_name);
        try em.raw("\">\n");
    }
    try em.raw("<meta property=\"og:title\" content=\"");
    try em.text(if (m.title.len != 0) m.title else doc.title);
    try em.raw("\">\n");
    const desc = if (m.description.len != 0) m.description else doc.description;
    if (desc.len != 0) {
        try em.raw("<meta property=\"og:description\" content=\"");
        try em.text(desc);
        try em.raw("\">\n");
    }
    if (m.path) |p| {
        try em.raw("<meta property=\"og:url\" content=\"");
        try url(em, m.origin, p);
        try em.raw("\">\n");
    }
    if (m.image) |img| {
        try em.raw("<meta property=\"og:image\" content=\"");
        try url(em, m.origin, img.path);
        try em.raw("\">\n");
        if (img.alt.len != 0) {
            try em.raw("<meta property=\"og:image:alt\" content=\"");
            try em.text(img.alt);
            try em.raw("\">\n");
        }
        if (img.size) |px| {
            try em.print(
                \\<meta property="og:image:width" content="{d}">
                \\<meta property="og:image:height" content="{d}">
                \\
            , .{ px.w, px.h });
        }
    }
    // The card, and **only** the card. Twitter's own documentation
    // states the fallback: with no `twitter:title`, `twitter:description`
    // or `twitter:image`, its crawler reads `og:title`, `og:description`
    // and `og:image`. So the other four tags every hand-rolled head
    // carries are four more copies of strings already on this page, and
    // the copy is the bug — a driver that edits one description and not
    // its twin ships two.
    //
    // This one has no `og:` twin, which is why it is written at all:
    // whether the picture is a banner or a thumbnail is a distinction
    // Open Graph does not make, and a network told nothing shows a bare
    // link. A document with no image is `summary` and cannot be
    // anything else, because the choice lives on the image.
    const card = if (m.image) |img| switch (img.shape) {
        .banner => "summary_large_image",
        .thumbnail => "summary",
    } else "summary";
    try em.print("<meta name=\"twitter:card\" content=\"{s}\">\n", .{card});
    // The one duplicate the fallback does not cover. Twitter documents
    // `og:` fallbacks for the title, the description and the image and
    // none for the picture's alternative text — so a reader who cannot
    // see it would be told nothing on that network, which is not a
    // trade this library makes to save a line.
    if (m.image) |img| {
        if (img.alt.len != 0) {
            try em.raw("<meta name=\"twitter:image:alt\" content=\"");
            try em.text(img.alt);
            try em.raw("\">\n");
        }
    }
}

/// One absolute URL out of the two halves the driver stated: config,
/// and the resolver's answer. Concatenation is the whole function — the
/// origin is not parsed, the path is not rewritten, and nothing here
/// knows what a route is. `checkMeta` has already established that the
/// join lands on a scheme and exactly one slash.
fn url(em: *Emitter, origin: []const u8, path: []const u8) !void {
    try em.text(origin);
    try em.text(path);
}

fn bootScript(em: *Emitter, doc: Document, b: Boot, chosen: []const u8) !void {
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
    // The language this file was written in, so the module that boots
    // on top of it rebuilds the same words. Unconditional, and the
    // empty tag is a value here rather than an omission: `mount` reads
    // an absent `locale` as "follow the device", which is right for an
    // app shell booting into an empty body and wrong for every page
    // that already has a screen in it. A document generated by an app
    // that chose no locale was rendered from its catalog's *template*,
    // and "" is the tag that resolves back to exactly that.
    //
    // It is `App.locale()` raw, and not the `lang` above: the fallback
    // that attribute takes is `Chrome`'s own language, a stand-in for a
    // browser that cannot act on "" — pinning it here would boot an
    // English catalog over a page a Persian-template app rendered,
    // which is the defect this line exists to close.
    try em.raw("  locale: \"");
    try js(em, chosen);
    try em.raw("\",\n");
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
///
/// **It stays private, and `Emitter.json` is not it.** They share the
/// second half of that argument and nothing else. This one writes the
/// inside of a *JavaScript string literal*, where `\x3C` is the escape;
/// a JSON document has no `\x` escape at all, so the public writer
/// spells the same character `\u003C`. Collapsing them would mean one
/// function whose output is valid in exactly one of its two
/// destinations. And there is no second caller to export it for: the
/// boot script is the library's own, the strings above are ids and URLs
/// the driver stated as *parameters*, and a driver that wanted to hand
/// this function executable JavaScript would be writing a `<script>`
/// this edition has no other support for.
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

// ------------------------------------------------------- the locale stub

/// The whole browser half of the stub, inlined into every one of them.
/// It is `Bundle.resolve` transcribed into the one language that cannot
/// call it — see `localeStub` for why a transcription is the only shape
/// available here, and tests/locale_stub.mjs for the gate that holds the
/// two identical.
const locale_stub_js = @embedFile("locale_stub.js");

comptime {
    // These bytes go *inline* into a `<script>`, where three sequences
    // end or re-open the block (serialize.zig's `json` carries the
    // tokenizer's argument). Driver strings reach it through `json`,
    // which escapes them; this file is the library's own and is checked
    // instead — the class_names.zig arrangement, where a fact the
    // compiler cannot follow into a `.js` file is grepped at comptime.
    @setEvalBranchQuota(8 * locale_stub_js.len + 1000);
    for ([_][]const u8{ "</script", "<!--", "<script" }) |hazard| {
        if (std.mem.indexOf(u8, locale_stub_js, hazard) != null)
            @compileError("nokre: locale_stub.js carries '" ++ hazard ++
                "', which ends or re-opens the script block it is written into");
    }
}

/// What a driver can get wrong about a `LocaleStub`, returned before it
/// writes a byte — a page that fails halfway is worse than none, and
/// every one of these is a build-time mistake rather than a reader's.
pub const LocaleStubError = error{
    /// A locale's choice names no destination, so the reader who picks
    /// it — or is sent there — arrives nowhere.
    ChoiceHrefEmpty,
    /// A locale's choice has no words, so the link with the script
    /// blocked is an anchor a reader cannot read and a screen reader
    /// cannot name.
    ChoiceLabelEmpty,
    /// Two locales point at the same page. One of them is then
    /// unreachable from here and its readers are silently handed the
    /// other's language — the failure a stub exists to prevent.
    ChoiceHrefsCollide,
};

/// The page at an *unprefixed* path: no screen, no boot, no data — the
/// per-locale copies of one page and a script that picks between them.
///
/// **Why it is a page at all.** Static hosting can neither read
/// `Accept-Language` nor answer with a 301 — GitHub Pages has no
/// redirect rules — so the only place the choice can be made is in the
/// document the reader already got. Every page a locale axis publishes
/// lives at `/{locale}/…` and **is never redirected away from**: one
/// URL showing different content to different readers is what breaks
/// sharing and canonicalisation both. The stub is the other side of
/// that rule — the one address that is allowed to be about the reader,
/// because it has no locale of its own to be wrong about.
///
/// **What the driver supplies is every destination and every word**:
/// where each locale's copy of this page is published, and what that
/// language is called. Neither is derivable — nokre does not know where
/// a site puts anything (`Meta` draws the same line), and a locale's
/// name in its own language is content this library has no catalog for.
///
/// **What it cannot supply is the locale set.** `choices` has one field
/// per bundled locale, generated from `L.Locale` itself, so a locale in
/// the bundle and missing here is a compile error and a locale here
/// that the bundle does not carry cannot be written down. That is the
/// completeness invariant stated as a type rather than checked at run
/// time — and it is the whole reason this call takes the bundle instead
/// of a list of tags, which would be a second source of truth that can
/// disagree with the ARB set (`dom.driver_files` exists for the same
/// failure).
pub fn LocaleStub(comptime L: type) type {
    return struct {
        /// The `<title>`, escaped here. In whatever language the driver
        /// judges a reader arriving with no locale reads best; the root
        /// element says the template's, which is where the script sends
        /// a reader it cannot place.
        title: []const u8,
        /// Where the driver published the edition's stylesheet.
        /// Required for `Document`'s reason: a page that does not link
        /// it is unstyled markup and nothing says so.
        stylesheet: []const u8,
        /// The words above the list, if the driver wants any. Empty
        /// writes no heading — a stub is a list of languages and reads
        /// as one without a sentence over it.
        heading: []const u8 = "",
        /// Markup spliced at the end of `<head>`. A robots directive
        /// goes here: what an unprefixed address is *for* is indexing
        /// policy, which is the site resolver's.
        head: []const u8 = "",
        /// Where this stub itself is published — which is the whole of
        /// what it takes to put the alternate set on it. Absent writes
        /// none of it, which is right for a stub nobody indexes.
        ///
        /// The set is not stated twice: `choices` is already one path
        /// per bundled locale, so it *is* `Alternates.paths` with a
        /// label attached, and the `x-default` is this page's own
        /// address because this page is what `x-default` means
        /// (`alternates.x_default`). A driver restating either would be
        /// the second source of truth the type exists to prevent.
        published: ?Published = null,
        /// One per bundled locale, named by it. The type is generated
        /// from `L.Locale`, so this cannot be short, long, or spelled
        /// for a locale the bundle does not have.
        choices: std.enums.EnumFieldStruct(L.Locale, Choice, null),

        /// One locale's copy of the page this stub stands at.
        pub const Choice = struct {
            /// Where that copy is published — absolute or relative to
            /// this page, since the script resolves it against
            /// `location` either way. The path scheme is the driver's
            /// whole: nokre computes no path here and no prefix.
            href: []const u8,
            /// The language's name **in that language**, which is the
            /// only form a reader who cannot read this page's language
            /// can act on. It is also the anchor's `lang`, so a screen
            /// reader says it in the right voice.
            label: []const u8,
        };

        /// A stub's own URL, split the way `Meta` splits one and
        /// checked by the same two lines.
        pub const Published = struct {
            /// Scheme and host, no trailing slash.
            origin: []const u8,
            /// The unprefixed path this page stands at, leading slash
            /// included. It is also where `x-default` points, and there
            /// is one field rather than two because those are the same
            /// address by definition.
            path: []const u8,
        };
    };
}

/// Writes the stub: the document, the links a reader with no JavaScript
/// chooses from, and the script that chooses for everyone else.
///
/// **The resolution is the bundle's, and there is no second policy.**
/// The script cannot call `L.resolve` — that function is comptime Zig
/// in a wasm module this page deliberately does not load, since a
/// redirect that first fetches an app is a redirect nobody waits for.
/// So the algorithm is transcribed into locale_stub.js *once, in the
/// library*, over the tags the bundle itself hands out here: exact tag
/// (case and `-`/`_` ignored), then bare language in bundle order, then
/// `L.default_locale`. A driver states none of it and cannot state it
/// differently. What holds the transcription honest is a gate rather
/// than a comment — tests/locale_stub.mjs runs *this* page's script
/// against `L.resolve`'s own answers over a table of device tags, so a
/// change to either side that the other does not follow fails the build
/// (docs/testing.md, "The locale stub's own gate").
///
/// **`navigator.language`, not `navigator.languages`.** The single tag
/// is what live.js's boot pours into the locale service, so the stub
/// and the page it lands on read the reader the same way. The list
/// would be a better answer to a different question and a *disagreeing*
/// answer to this one.
///
/// **It carries the alternate set too, when it says where it is.**
/// `published` is the only thing needed for it: `choices` already holds
/// one path per bundled locale, which is what an alternate set is, and
/// `x-default` is this page's own address because a stub is what
/// `x-default` *means* (alternates.zig). One shape, one writer, and no
/// restatement — the block on a locale's copy and the block here are
/// the same function over the same set, which is what keeps the
/// annotation two-sided.
///
/// **The links are not a fallback anyone should have to think about.**
/// They are the document; the script is what saves a reader from
/// reading it. A stub whose script does not run — blocked, unsupported,
/// a crawler — is a page offering a choice rather than a blank frame,
/// which is the whole reason this is a page and not a
/// `<meta http-equiv="refresh">`.
///
/// **Two things the script carries across, and both are losses a
/// hand-rolled redirect takes silently.** The query and the fragment
/// are the *reader's* — a shared `/docs/#the-seams` has to arrive at
/// `/en/docs/#the-seams` or the link no longer names what it named — so
/// they are copied onto the destination unless it states its own. And a
/// stub whose own address is one of its choices navigates nowhere: the
/// comparison is against the resolved URL, so a driver that published a
/// stub over a locale's page gets a page that stands still rather than
/// a browser that spins.
///
/// The script's own bytes are the library's, written to the page
/// unescaped — a comptime check refuses a `locale_stub.js` carrying
/// anything that could end the block. Every driver-supplied byte in
/// there is a string inside the JSON argument, and goes through
/// `Emitter.json`.
pub fn localeStub(em: *Emitter, comptime L: type, stub: LocaleStub(L)) !void {
    const locales = comptime std.enums.values(L.Locale);
    try checkStub(L, stub);

    // The stub is in no locale — that is what it is for — so the root
    // element takes the template's, which is the language the script
    // falls back to. A reader it cannot place lands on that page, and
    // the document they were served on the way there claims the same
    // language rather than the last one the generator happened to be
    // in.
    const def = L.default_locale;
    try em.raw("<!doctype html>\n<html lang=\"");
    try em.text(L.tag(def));
    const dir = @tagName(L.dir(def));
    try em.print("\" dir=\"{s}\" data-direction=\"{s}\">\n", .{ dir, dir });

    try headOpen(em, stub.title, "", stub.stylesheet);

    // In the head, and blocking, because everything below it is a page
    // the reader is not meant to see: a redirect that waits for the
    // body is a chooser that flashes up and disappears. Nothing here
    // touches the DOM — `location` and `navigator` are all it reads —
    // so there is nothing to wait for either.
    //
    // No `data-appearance` above it for the reason stylesheet.zig's
    // `write` gives: no app boots on this page, so the media query is
    // all it has to go on and is exactly right.
    try em.raw("<script>\n");
    try em.raw(locale_stub_js);
    try em.raw("nokreLocaleStub(");
    try stubData(em, L, stub);
    try em.raw(");\n</script>\n");

    // The same block the copies carry, written by the same function
    // over the same shape — `choices` is one path per bundled locale,
    // which is what an alternate set is, and the `x-default` is this
    // page. A crawler that reads a locale's copy is told the stub
    // exists; without this it would not be told the reverse, and a
    // one-sided annotation is the failure the whole set exists to
    // avoid.
    if (stub.published) |pub_at| {
        var set: [locales.len + 1]Alternate = undefined;
        inline for (locales, 0..) |loc, i| {
            set[i] = .{
                .hreflang = comptime L.tag(loc),
                .path = @field(stub.choices, @tagName(loc)).href,
            };
        }
        set[locales.len] = .{ .hreflang = alternates_mod.x_default, .path = pub_at.path };
        try alternates_mod.links(em, pub_at.origin, &set);
    }
    try em.raw(stub.head);
    try em.raw("</head>\n<body>\n");

    // `class_names.root` and nothing else: `rootClass`'s conditional
    // half is `layout.hasBottomChrome` over a screen, and there is no
    // screen here. The two class names inside are the sheet's own,
    // spelled the way serialize.zig spells them — one compile, one
    // stylesheet.
    try em.print("<main class=\"{s}\">\n", .{class_names.root});
    if (stub.heading.len != 0) {
        try em.raw("<h1 class=\"s-h1\">");
        try em.text(stub.heading);
        try em.raw("</h1>\n");
    }
    try em.raw("<nav class=\"stack\">\n");
    inline for (locales) |loc| {
        const choice = @field(stub.choices, @tagName(loc));
        const tag = comptime L.tag(loc);
        try em.raw("<a class=\"link\" href=\"");
        try em.text(choice.href);
        // `hreflang` is what the destination is in; `lang` is what the
        // words in the anchor are in. They are the same tag here and
        // they are not the same claim — one is for a crawler deciding
        // which copy to index, the other for a screen reader deciding
        // how to pronounce "فارسی".
        try em.print("\" hreflang=\"{s}\" lang=\"{s}\" dir=\"{s}\">", .{
            tag, tag, @tagName(comptime L.dir(loc)),
        });
        try em.text(choice.label);
        try em.raw("</a>\n");
    }
    try em.raw("</nav>\n</main>\n</body>\n</html>\n");
}

fn checkStub(comptime L: type, stub: LocaleStub(L)) (LocaleStubError || MetaError)!void {
    const locales = comptime std.enums.values(L.Locale);
    var hrefs: [locales.len][]const u8 = undefined;
    inline for (locales, 0..) |loc, i| {
        const choice = @field(stub.choices, @tagName(loc));
        if (choice.href.len == 0) return error.ChoiceHrefEmpty;
        if (choice.label.len == 0) return error.ChoiceLabelEmpty;
        for (hrefs[0..i]) |taken| {
            if (std.mem.eql(u8, taken, choice.href)) return error.ChoiceHrefsCollide;
        }
        hrefs[i] = choice.href;
    }
    // A stub that says where it is has to say it the way every other
    // URL here is said. The hrefs are free to be relative *until* this
    // page claims an address — an `hreflang` is absolute or it is
    // nothing, so the same slices then owe the rooted-path rule.
    if (stub.published) |pub_at| {
        try alternates_mod.checkOrigin(pub_at.origin);
        try alternates_mod.checkPath(pub_at.path);
        for (hrefs) |h| try alternates_mod.checkPath(h);
    }
}

/// The script's one argument: the bundle's tags in the bundle's order,
/// the driver's destinations beside them, and the index the bundle
/// falls back to.
///
/// Serialized with `std.json` and written through `Emitter.json`,
/// because every string in it is a driver's — a label carrying
/// `</script>` would otherwise end the block, and the same label
/// through `Emitter.text` would arrive as five characters of nothing
/// inside raw text.
///
/// The fallback travels as an index rather than being assumed to be
/// zero: it is `L.default_locale`'s position, read from the bundle, and
/// a reader of the emitted page can see which one it is.
fn stubData(em: *Emitter, comptime L: type, stub: LocaleStub(L)) !void {
    const locales = comptime std.enums.values(L.Locale);
    var tags: [locales.len][]const u8 = undefined;
    var hrefs: [locales.len][]const u8 = undefined;
    var fallback: usize = 0;
    inline for (locales, 0..) |loc, i| {
        tags[i] = comptime L.tag(loc);
        hrefs[i] = @field(stub.choices, @tagName(loc)).href;
        if (loc == L.default_locale) fallback = i;
    }
    const doc = try std.json.Stringify.valueAlloc(em.gpa, .{
        .tags = tags[0..],
        .hrefs = hrefs[0..],
        .fallback = fallback,
    }, .{});
    defer em.gpa.free(doc);
    try em.json(doc);
}
