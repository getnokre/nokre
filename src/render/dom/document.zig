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
//! **Neither of the two scripts here is an inline one.** The boot and
//! the locale chooser are both files the site already serves
//! (`driver_files`), and what a page states is the *data* each of them
//! reads — an `application/json` block a browser never executes. That
//! is what lets a site published out of this writer carry
//! `script-src 'self'`, which is the largest single thing a policy
//! buys; it is the move packaging.zig made for the app shell's page two
//! revisions earlier, and this writer was the half that had not made
//! it.
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
//! **The one seam is bytes, not a hook, and it takes nothing that
//! renders.** `head` is markup the driver already built, spliced where
//! its name says. A `fn (em)` hook would hand the driver `em.out` and
//! re-open the door `Refs`'s signature closed — and `Emitter.raw`
//! writes wherever the emitter is currently pointed, which is exactly
//! why a driver could not otherwise say "into the head". A field says
//! it. A driver that wants the emitter's escaping while building those
//! bytes points a second `Emitter` at a buffer of its own; nothing here
//! needs the first one to be somewhere else.
//!
//! There was a second seam at the other end of the body for three
//! revisions, and what every consumer put through it was a footer —
//! links and a line of text, which is *content* (docs/static-sites.md,
//! "A seam is for what does not render"). It is gone: a footer is a
//! `stack` of `link`s appended last by the page builder, inside the
//! screen, where the sheet styles it, the reserve clears it, the audit
//! reads it and its routes resolve.

const std = @import("std");

const alternates_mod = @import("alternates.zig");
const app_mod = @import("../../core/app.zig");
const class_names = @import("class_names.zig");
const color = @import("../../core/color.zig");
const csp_mod = @import("csp.zig");
const driver_files = @import("driver_files.zig");
const element_mod = @import("../../core/element.zig");
const layout = @import("../../core/layout.zig");
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

/// The upgrade, two tags wide — the library's own module, and the data
/// this page hands it: the same `App` over the same route table, booting
/// on top of the file it wrote.
///
/// Present or absent, never half — a page with no `Boot` is a complete
/// document that reads, navigates and prints, which is the whole point
/// of the pair (dom-edition.md, "Live over a generated page").
///
/// **Whether a page needs one is not this field's to say.** nokre reads
/// that off the tree — `needsRuntime`, over a closed element set — and
/// what stays here is the half nokre cannot know: *where the driver
/// published the module*, which is `Meta.origin`'s doctrine again. So
/// the pair is a floor and not a ceiling. A page whose tree holds a
/// control an app has to answer and no `boot` is `error.PageNeedsBoot`
/// rather than a file that renders and does nothing; a page whose tree
/// shows no such need may still carry one, for a need no tree can show
/// — a screen deliberately inert until it has fetched what it will
/// draw. Nothing here reads the *absence*: one markup, whatever the
/// page will or will not do, and the shape its nav wears is the
/// reader's window's (`stylesheet.zig`).
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
    /// to type: `driver_files.boot_entry` is the module a page loads,
    /// and a consumer that spelled it here would be one more writer of a
    /// set that is data precisely so it cannot be re-typed.
    driver_dir: []const u8 = "/",
    addressing: Addressing = .fragments,
    /// The bytes the page was generated from, for the app to read
    /// inside its first build — a URL, fetched before boot. Empty for a
    /// screen whose builder needs nothing it did not compile in.
    seed: []const u8 = "",
};

/// The page's own Content-Security-Policy, as a `<meta http-equiv>` —
/// asked for, then **derived from what the page contains**.
///
/// **Why it is not the head seam.** `Document.head` takes a `<meta>`,
/// and docs/static-sites.md names a CSP as the kind of thing a byte
/// seam is legitimately for. That is true of every other tag in a head
/// and false of exactly this one, on a fact about *position*: a policy
/// applies only to what the parser meets after it, and the seam is
/// spliced at the end of the head — after the stylesheet link, after
/// the whole `Meta` block, and on a stub after the chooser script
/// itself. A policy written there governs the body and lets through
/// every subresource the head already asked for, which is a policy that
/// reads correct and is not. So the tag goes where packaging.zig's has
/// always gone, immediately behind the charset, and that seat is not
/// one a seam can offer.
///
/// **Why it is derived and not a string.** The directive set is an
/// inventory of what this edition fetches (csp.zig), and no consumer
/// holds that inventory: whether a page compiles a module, whether a
/// driver behind it can start a worker, whether anything on it fetches
/// at all. nokre has just built the tree and knows all three. A string
/// would be the second copy of a library fact, and the second copy is
/// the one that goes stale — the argument that took `boot`'s own
/// derivation off the driver, one field up.
///
/// **What is left is the one source nokre cannot know**, and it is the
/// same one the app shell's page leaves: a fetch is the only outbound
/// request an app's own code can make here, so the hosts it talks to
/// are a field, checked by the function that checks the shell's
/// (`csp.badConnectSrc`). A parameter is not a hole
/// (docs/static-sites.md).
///
/// **Absent is a real answer and the default.** Whether a document
/// carries its policy in its own bytes or takes one from the edge that
/// serves it is a fact about a deployment, not about nokre — and the
/// three directives a `<meta>` cannot carry at all (`frame-ancestors`,
/// `report-to`, `sandbox`) are the edge's either way. A site behind an
/// edge that already sends the header states nothing here.
pub const Csp = struct {
    /// Hosts the app fetches beyond the origin this page is served
    /// from — `http.request`'s URLs, an OAuth provider's token
    /// endpoint. They join `connect-src` and nothing else, so an added
    /// host grants exactly one power; the default is empty, which is
    /// this origin and nothing else.
    ///
    /// **Only a page that boots may state one.** Nothing on a page with
    /// no runtime fetches, so a host on one is a power granted to
    /// nobody — `error.ConnectSrcWithoutBoot`, for the reason
    /// `default-src 'none'` is the floor at all.
    connect_src: []const []const u8 = &.{},
};

/// What a driver can get wrong about a `Csp`, refused before a byte.
///
/// All three are relationships rather than values, which is the only
/// kind of thing this library checks: a source that is not a source, a
/// power granted on a page that cannot spend it, and an asset published
/// somewhere the policy has no way to name.
pub const CspError = error{
    /// A `connect_src` entry is not a plain source expression, so it
    /// could end the directive it lands in and start a friendlier one
    /// (`csp.badConnectSrc`).
    InvalidConnectSrc,
    /// A host was declared on a page that boots nothing. Nothing on it
    /// can fetch, so the directive would be granted to no one — and a
    /// driver writing that has one of the two facts wrong.
    ConnectSrcWithoutBoot,
    /// The stylesheet, the wasm module, the driver directory or the
    /// seed is published off this origin, and every source in this
    /// policy but the declared hosts is `'self'` — so the browser would
    /// refuse an asset the page itself names. It is a blank page with a
    /// console message, which is the silent direction, and the only one
    /// refused here.
    AssetOffOrigin,
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
    /// Markup spliced at the end of `<head>` — the one seam, and the
    /// test it passes is that **none of it renders**. Structured data, a
    /// preload, a favicon, a robots directive: everything whose
    /// destination is the site's and whose *shape* nokre has no element
    /// and no opinion for. Written after the tags above so the charset
    /// stays in the first bytes, where a browser stops looking for it.
    ///
    /// A byte seam anywhere a reader can see is refused, and the ground
    /// is one this file has now paid for twice: markup nokre did not
    /// place is markup it cannot style, clear, audit or resolve
    /// (docs/static-sites.md).
    ///
    /// **The one thing it cannot carry is the policy beside it.** A
    /// `<meta http-equiv="Content-Security-Policy">` here would sit
    /// after the stylesheet link it has to govern, because a policy
    /// only ever applies to what the parser meets past it. That is
    /// `csp` below, and it is the one head tag with a seat rather than
    /// a place in a list.
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
    boot: ?Boot = null,
    /// The policy this page carries about itself, or `null` for a page
    /// whose edge states one (`Csp`). Its directives are derived from
    /// the rest of this value — what the page loads is what it grants.
    csp: ?Csp = null,
};

/// Writes the whole file: the screen, the chrome, and the document
/// around them.
///
/// The chrome goes first, before the content, because the nav leads the
/// focus order — a property of the tree, not of where CSS puts the bar.
pub fn document(em: *Emitter, doc: Document) !void {
    // The medium, declared before the tree is read: this file is about
    // to become a browser's, and a browser reflows. An app a generator
    // built assumed the cautious answer (`App.medium`), and the nav's
    // shape is decided against it — so declaring it here is what keeps
    // a *generated* page from wearing a chip an app shell in the same
    // window would never have shown. Idempotent, and a no-op for an app
    // the live driver already declared for.
    em.app.setMedium(.reflows);

    // Before a byte, not as it goes: a document that fails halfway
    // leaves a truncated file behind, and every one of these is a
    // config mistake a build should die on rather than publish.
    if (doc.meta) |m| try checkMeta(m);
    try checkRuntime(em, doc);
    try checkCsp(doc);

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
    try documentAttr(em);
    try em.raw(">\n");

    // The policy, if this page carries one — derived here and nowhere
    // else, because every input to it is a field of the value being
    // written. A page that boots is a page that loads a module, compiles
    // it, may reach the driver's two workers and fetches at least the
    // module itself; a page that does not is prose and links, and grants
    // none of the four. The screen going into the body below is what
    // spends the inline style attributes (csp.zig).
    var policy: std.ArrayList(u8) = .empty;
    defer policy.deinit(em.gpa);
    if (doc.csp) |c| try csp_mod.write(em.gpa, &policy, .{
        .scripts = doc.boot != null,
        .wasm = doc.boot != null,
        .workers = doc.boot != null,
        .connects = doc.boot != null,
        .style_attrs = true,
    }, c.connect_src);

    try headOpen(em, policy.items, doc.title, doc.description, doc.stylesheet);
    if (doc.meta) |m| try metaTags(em, doc, m);
    try em.raw(doc.head);
    // A bare `<body>`, and it stays bare. It carried one class for three
    // revisions — written from a body seam's bytes, so the bottom
    // reserve could land under a footer standing outside the screen —
    // and that class was the library inferring *is there content below
    // the screen?* from *is this string non-empty?*, about bytes it
    // could not read. The footer is in the tree now, so the screen is
    // the last thing in the document again and the reserve is back to
    // one rule (`stylesheet.zig`'s reserve block).
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
    //
    // **Not one byte of whitespace inside either mount**, which reads
    // like formatting and is the handover. A mount's children are what
    // the live driver diffs its frame against, node by node, under one
    // identity rule — same kind of thing, same `data-n` (live.js's
    // `sameNode`). A newline after the open tag is a text node the
    // frame does not have, so the walk pairs the file's *first* child
    // against the frame's second, disagrees, and replaces it — and
    // every sibling after it, down both mounts. The page still renders,
    // which is why this survived: what it costs is exactly what the
    // handover was for — the reader's scroll offset, their selection,
    // their caret, and the node the fragment they arrived on names
    // (dom-edition.md, "boot is a patch rather than a repaint"). The
    // newlines *between* the mounts are the file's own and cost
    // nothing, being outside both.
    try em.raw("<div id=\"");
    try em.text(doc.chrome_id);
    try em.raw("\">");
    try serialize.chrome(em);
    try em.raw("</div>\n");

    try em.raw("<main id=\"");
    try em.text(doc.content_id);
    try em.print("\" class=\"{s}", .{serialize.rootClass(em)});
    if (doc.content_class.len != 0) {
        try em.raw(" ");
        try em.text(doc.content_class);
    }
    try em.raw("\">");
    try serialize.content(em);
    try em.raw("</main>\n");

    if (doc.boot) |b| try bootScript(em, doc, b, chosen);
    try em.raw("</body>\n</html>\n");
}

/// The root attribute that is about the *file* rather than the app in
/// it: nokre wrote this whole document, so the page around the screen
/// is nokre's to style as well as the screen.
///
/// The sheet's type base and its paper are scoped to nokre's own
/// surfaces on the ground that *the page around an embedded app is not
/// this edition's to turn around* (stylesheet.zig). That ground holds
/// and is not weakened here — it has nothing to protect in a file nokre
/// wrote end to end, which is the same reading of the same rule that
/// makes this writer stamp `dir` where the live driver stamps only
/// `data-direction`.
///
/// What it covers is `body`: the skip link above the mounts, and the
/// band of page beside a screen whose driver centred it in a reading
/// column — unpainted, that band is the UA canvas, which on a dark
/// ramp is a white margin around a black page.
///
/// Unconditional on both writers here, and written by nobody else —
/// `class_names.document_attr` carries the name and the comptime check
/// that keeps the live driver off it.
fn documentAttr(em: *Emitter) !void {
    try em.print(" {s}=\"{s}\"", .{ class_names.document_attr, class_names.document_value });
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
///
/// **The policy takes the second seat and it is not a preference.** A
/// Content-Security-Policy governs only what the parser meets after it,
/// so it leads every link, script and style below — which is also the
/// whole reason it is a field rather than something a driver splices
/// through `Document.head`, spliced as that is at the *end* of the head
/// (`Csp`). It comes after the charset because that rule is older and
/// narrower: a browser stops looking for the encoding after the first
/// bytes, and a policy is not a fetch.
fn headOpen(
    em: *Emitter,
    policy: []const u8,
    title: []const u8,
    description: []const u8,
    sheet: []const u8,
) !void {
    try em.raw(
        \\<head>
        \\<meta charset="utf-8">
        \\
    );
    try em.raw(policy);
    try em.raw(
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

/// What a page asking for a policy owes it, checked before a byte for
/// `checkMeta`'s reason: every one of these is a build-time mistake
/// whose runtime shape is a browser refusing something silently.
///
/// The same three questions on both writers, which is why it takes the
/// pieces rather than a `Document`: a stub has a stylesheet and a
/// driver directory too, and no boot at all.
fn checkCsp(doc: Document) CspError!void {
    const c = doc.csp orelse return;
    try checkCspParts(c, doc.stylesheet, doc.boot);
}

fn checkCspParts(c: Csp, sheet: []const u8, boot: ?Boot) CspError!void {
    if (csp_mod.badConnectSrc(c.connect_src) != null) return error.InvalidConnectSrc;
    if (boot == null and c.connect_src.len != 0) return error.ConnectSrcWithoutBoot;
    // Every source in the emitted policy but the declared hosts is
    // `'self'`, so an asset this page names off this origin is one the
    // browser refuses. The one input to that claim nothing here can see
    // is where the *faces* are published — `stylesheet.Options.fonts`,
    // a different call with a rooted default — and it is stated in
    // docs/static-sites.md rather than guessed at.
    if (csp_mod.offOrigin(sheet)) return error.AssetOffOrigin;
    if (boot) |b| {
        if (csp_mod.offOrigin(b.wasm)) return error.AssetOffOrigin;
        if (csp_mod.offOrigin(b.driver_dir)) return error.AssetOffOrigin;
        if (b.seed.len != 0 and csp_mod.offOrigin(b.seed)) return error.AssetOffOrigin;
    }
}

/// The first control on this page that an app has to answer, or null
/// for a page that is whole without one — the derived half of `boot`,
/// and a question a driver should ask rather than answer.
///
/// **Whether a page needs a runtime is a fact about what is on it.** It
/// was a driver's declaration for exactly one release, and a
/// declaration is a thing to get wrong in the silent direction: a file
/// that renders, shows its controls, and does nothing when they are
/// pressed. The element set is closed, so nokre can read the answer off
/// the tree it just built (`element.Element.needsRuntime`, where the
/// line between a control and a link is drawn and argued).
///
/// It asks each *element*, not each role, and the role it hands back is
/// the answer's name rather than its input: a `tile` with a route is an
/// anchor and a `tile` with a press is a button, and a census that
/// could not tell them apart made a page of navigating rows carry a
/// module nobody on it would run.
///
/// A generator's own use is the one this is public for:
///
/// ```zig
/// .boot = if (dom.needsRuntime(&app) != null) boot_options else null,
/// ```
///
/// …which is the whole of what a driver used to have to know per page.
pub fn needsRuntime(app: *const App) ?element_mod.Role {
    var it = app.tree.dfs();
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.needsRuntime()) return el.role();
    }
    return null;
}

/// The one check this writer makes about the page as a whole, and it is
/// the same kind of thing `checkMeta` is: a relationship between what
/// the tree holds and what the driver declared, refused before a byte
/// rather than published.
///
/// **The derivation is a floor, not a ceiling.** nokre reads the tree
/// and says a runtime is needed; a driver may publish one anyway, for a
/// need no tree can show — a screen whose static shape is deliberately
/// inert because the thing it will show has not been fetched yet. What
/// a driver may not do is take one away, and that is the only direction
/// this refuses in, because it is the only direction where being wrong
/// is silent.
///
/// **What is still the driver's is `Boot` itself**, and for `Meta`'s
/// reason: nokre does not know where a site published its wasm, its
/// driver directory or its seed, and cannot invent any of them. It owns
/// what a driver gets *wrong* about them — here, leaving all three off a
/// page that cannot work without them.
///
/// The nav is one row of this and no longer a rule of its own. A roster
/// too wide for the viewport a generator ran at comes out as the
/// collapsed chip (`nav.syncNavChrome`), the chip is a `nav_current`,
/// and a `nav_current` needs a runtime like every other combobox — so
/// the case `error.NavChipNeedsBoot` was written for is now one entry in
/// a table, with the same remedy it always had: generate at a width the
/// row fits, which for a document is free, since the shape it wears past
/// that point is the reader's window's to pick (stylesheet.zig).
fn checkRuntime(em: *const Emitter, doc: Document) error{PageNeedsBoot}!void {
    if (doc.boot != null) return;
    if (needsRuntime(em.app) != null) return error.PageNeedsBoot;
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

/// Exactly `mount`'s option set, as one value — which is the whole
/// reason it is a struct here rather than lines of JavaScript written
/// out one field at a time. `live-boot.js` spreads the parsed object
/// straight into `mount`, so the names below *are* the option names, and
/// an option that grows on one side reaches the other with no second
/// list to keep in step.
///
/// The two mounts travel as **ids** rather than elements, because a
/// document is text: they are the two names the markup above already
/// used, and the boot resolves them the way any reader of that markup
/// would.
///
/// The optionals are absent when null, and absence is a value `mount`
/// reads: no `seed` is a builder that needs nothing fetched, no `route`
/// is an app on no screen, and no `addressing` is `mount`'s own default
/// — a driver reading its own output should see the choice it made and
/// not the one it did not.
const BootConfig = struct {
    wasm: []const u8,
    into: []const u8,
    content: []const u8,
    addressing: ?[]const u8 = null,
    route: ?[]const u8 = null,
    locale: []const u8,
    seed: ?[]const u8 = null,
};

/// The boot, in two tags: the data this page states, then the module
/// that reads it.
///
/// **Neither of them is an inline script**, and that is the whole shape.
/// A `<script>` block with the call written into it is exactly what
/// `script-src 'self'` exists to refuse, and a static site cannot hash
/// its way out of one — each page's block carries that page's route and
/// that page's locale, so a policy would have to name one hash per
/// published page, which a response header cannot carry and a consumer
/// cannot maintain. The first migration to meet it turned the whole
/// directive over to `'unsafe-inline'` for 1,132 blocks the library had
/// written itself.
///
/// So the code is a file the site already serves
/// (`driver_files.boot_entry`) and the per-page bytes are an
/// `application/json` **data block**, which a browser never executes —
/// HTML's own script preparation calls a non-JavaScript type a data
/// block and returns before the policy is ever consulted — so no policy
/// has to admit one. It is the same move packaging.zig made when its
/// `<style>` and its inline mount became page.css and boot.js, for the
/// same reason, and this writer was the half that had not made it.
fn bootScript(em: *Emitter, doc: Document, b: Boot, chosen: []const u8) !void {
    const config = try std.json.Stringify.valueAlloc(em.gpa, BootConfig{
        .wasm = b.wasm,
        .into = doc.chrome_id,
        .content = doc.content_id,
        .addressing = if (b.addressing == .documents) @tagName(b.addressing) else null,
        // The route is the app's, not the driver's: the screen this
        // document holds is the one the router is on, and a boot
        // argument that named some other one would build and paint a
        // screen on the way past.
        .route = em.app.router.current(),
        // The language this file was written in, so the module that
        // boots on top of it rebuilds the same words. Unconditional,
        // and the empty tag is a value here rather than an omission:
        // `mount` reads an absent `locale` as "follow the device",
        // which is right for an app shell booting into an empty body
        // and wrong for every page that already has a screen in it. A
        // document generated by an app that chose no locale was
        // rendered from its catalog's *template*, and "" is the tag
        // that resolves back to exactly that.
        //
        // It is `App.locale()` raw, and not the `lang` above: the
        // fallback that attribute takes is `Chrome`'s own language, a
        // stand-in for a browser that cannot act on "" — pinning it
        // here would boot an English catalog over a page a
        // Persian-template app rendered, which is the defect this line
        // exists to close.
        .locale = chosen,
        .seed = if (b.seed.len != 0) b.seed else null,
    }, .{ .emit_null_optional_fields = false });
    defer em.gpa.free(config);

    try configBlock(em, class_names.boot_value, config);
    try em.raw("<script type=\"module\" src=\"");
    try em.text(b.driver_dir);
    try em.text(driver_files.boot_entry);
    try em.raw("\"></script>\n");
}

/// One `application/json` block, named for what reads it.
///
/// Shared by the two writers here so that the arrangement is one thing
/// rather than two that happen to look alike: a script of nokre's finds
/// its argument by `data-nokre`, whose value says which of the library's
/// pages this is — the same attribute the root element carries and the
/// same vocabulary (`class_names`), so a driver's own ids and classes
/// are never a term in it.
///
/// The bytes go out through `Emitter.json`, which is the escape a JSON
/// document written into raw text needs: a `<` becomes `\u003C`, and
/// that one rule closes `</script`, `<script` and `<!--` together. An
/// HTML escape would be the wrong answer — a `<script>`'s contents are
/// raw text, and `&lt;` there is four characters of nothing.
fn configBlock(em: *Emitter, value: []const u8, json_doc: []const u8) !void {
    try em.print("<script type=\"application/json\" {s}=\"{s}\">", .{
        class_names.document_attr, value,
    });
    try em.json(json_doc);
    try em.raw("</script>\n");
}

// ------------------------------------------------------- the locale stub

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
        /// The directory the driver published `driver_files` under,
        /// with its trailing slash — `Boot.driver_dir` asked of the one
        /// page here that boots nothing. The chooser is a file the site
        /// already serves (`driver_files.stub_entry`) rather than bytes
        /// written into the page, so a stub costs a policy nothing; the
        /// file name inside the directory is not the driver's to type.
        driver_dir: []const u8 = "/",
        /// The words above the list, if the driver wants any. Empty
        /// writes no heading — a stub is a list of languages and reads
        /// as one without a sentence over it.
        heading: []const u8 = "",
        /// Markup spliced at the end of `<head>`. A robots directive
        /// goes here: what an unprefixed address is *for* is indexing
        /// policy, which is the site resolver's.
        head: []const u8 = "",
        /// The policy this page carries about itself (`Csp`), derived
        /// the same way and from a much shorter page: a stub loads one
        /// classic script of the library's, compiles no module, boots
        /// no driver and fetches nothing at all, so it grants none of
        /// the three powers a booting document needs. Declaring a
        /// `connect_src` on one is `error.ConnectSrcWithoutBoot`.
        csp: ?Csp = null,
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
/// So the algorithm is transcribed into locale-stub.js *once, in the
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
/// **The script is a file the site serves, not bytes in the page**, and
/// it is the same change `bootScript` made beside it and for the same
/// reason. A stub per published page is a stub per published page's
/// worth of distinct inline blocks; there is no hashing a policy out of
/// that, and the one migration to meet it spent `script-src` on
/// `'unsafe-inline'` for a script the library had written itself. What
/// differs from stub to stub is the destinations, which are *data*, so
/// they go in an `application/json` block a browser never executes and
/// the chooser reads its argument out of that. Every driver-supplied
/// byte in it is a string inside JSON and goes through `Emitter.json`.
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
    try em.print("\" dir=\"{s}\" data-direction=\"{s}\"", .{ dir, dir });
    // A whole file of nokre's too, and one that is almost nothing but
    // seam: a `head` the driver wrote and a list of links.
    try documentAttr(em);
    try em.raw(">\n");

    // A chooser and nothing else: one classic script the site serves,
    // over data in the page. No module is compiled, no driver boots, and
    // `location.replace` is a navigation rather than a fetch — so the
    // three directives a document spends on running an app are three
    // this page does not carry (csp.zig).
    var policy: std.ArrayList(u8) = .empty;
    defer policy.deinit(em.gpa);
    if (stub.csp) |c| try csp_mod.write(em.gpa, &policy, .{ .scripts = true }, c.connect_src);

    try headOpen(em, policy.items, stub.title, "", stub.stylesheet);

    // In the head, and blocking, because everything below it is a page
    // the reader is not meant to see: a redirect that waits for the
    // body is a chooser that flashes up and disappears. That is also
    // why the file is a classic script and not a module — a module is
    // deferred, and a deferred chooser runs after the page it was meant
    // to replace has been laid out and painted.
    //
    // The data leads the script for the same reason the charset leads
    // the head: a classic script runs where it stands, so the block it
    // reads has to be behind it in the parse.
    //
    // No `data-appearance` above either of them for the reason
    // stylesheet.zig's `write` gives: no app boots on this page, so the
    // media query is all it has to go on and is exactly right.
    {
        const data = try stubData(em.gpa, L, stub);
        defer em.gpa.free(data);
        try configBlock(em, class_names.locale_value, data);
    }
    try em.raw("<script src=\"");
    try em.text(stub.driver_dir);
    try em.text(driver_files.stub_entry);
    try em.raw("\"></script>\n");

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

fn checkStub(comptime L: type, stub: LocaleStub(L)) (LocaleStubError || MetaError || CspError)!void {
    const locales = comptime std.enums.values(L.Locale);
    // The same three questions the other writer asks, on the two
    // destinations this page has: it links a stylesheet and it loads a
    // chooser out of `driver_dir`, and a policy naming only this origin
    // cannot reach either of them anywhere else.
    if (stub.csp) |c| {
        try checkCspParts(c, stub.stylesheet, null);
        if (csp_mod.offOrigin(stub.driver_dir)) return error.AssetOffOrigin;
    }
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

/// The chooser's one argument: the bundle's tags in the bundle's order,
/// the driver's destinations beside them, and the index the bundle
/// falls back to.
///
/// The fallback travels as an index rather than being assumed to be
/// zero: it is `L.default_locale`'s position, read from the bundle, and
/// a reader of the emitted page can see which one it is.
///
/// It returns bytes rather than writing them because it is the *data*
/// half of the pair `configBlock` writes — the same relationship
/// `BootConfig` has to the other one.
fn stubData(gpa: std.mem.Allocator, comptime L: type, stub: LocaleStub(L)) ![]u8 {
    const locales = comptime std.enums.values(L.Locale);
    var tags: [locales.len][]const u8 = undefined;
    var hrefs: [locales.len][]const u8 = undefined;
    var fallback: usize = 0;
    inline for (locales, 0..) |loc, i| {
        tags[i] = comptime L.tag(loc);
        hrefs[i] = @field(stub.choices, @tagName(loc)).href;
        if (loc == L.default_locale) fallback = i;
    }
    return std.json.Stringify.valueAlloc(gpa, .{
        .tags = tags[0..],
        .hrefs = hrefs[0..],
        .fallback = fallback,
    }, .{});
}
