//! The names this edition's markup and its stylesheet both write — the
//! classes it puts on elements, and the one attribute that says who
//! wrote the page around them and which of the library's own nodes a
//! node is — as data.
//!
//! The root pair, four writers: [stylesheet.zig](stylesheet.zig)
//! selects on them, [live.zig](live.zig)'s `buildFrame` writes them onto
//! the `<main>` it emits, [live.js](live.js) toggles the modifier from
//! the browser side, and a host document that wrote its own `<main>`
//! writes them a fourth time — outside this compile, where no compiler
//! reads them at all.
//!
//! That fourth writer is why the names are data rather than prose. A
//! class list nothing in the sheet matches is not a build error: with
//! the root name misspelt the page renders as unstyled markup, and with
//! the modifier written alone — the compound selector wants both on the
//! one element — a screen carrying bottom chrome silently loses the
//! clear space the nav stands in. Neither fails anywhere near where it
//! was typed (docs/internals/dom-edition.md, "The document is the
//! library's; the names in it are the driver's" — a driver taking the
//! whole file from `document.zig` never writes the list at all, and one
//! placing `content` itself still does). So the pair is exported, and
//! exported only as the finished
//! class list: `serialize.zig`'s `rootClass` picks the branch from the
//! same predicate both editions ask, so a consumer never assembles a
//! list and never chooses the wrong one.

const std = @import("std");

/// The tree root. A driver puts this on whatever it wraps the screen
/// in; every rule in the sheet that reaches the screen hangs off it.
pub const root = "nokre";

/// Whether the bottom reserve is owed at all, conditional on
/// `layout.hasBottomChrome`. Written beside `root` on the same element,
/// never alone. Which *box* the space then lands in is `seam` below.
pub const has_chrome = "has-chrome";

/// The skip link's, on the anchor `document.zig` writes past the chrome
/// to the content mount. Unlike the pair above it has one writer inside
/// this compile and one rule in the sheet — it is here because the two
/// are in different files and a name that lives in only one of them is
/// how the pair above got into trouble.
pub const skip = "skip";

// There was a `no_boot` modifier here for one release, written from
// `Document.boot` and read by the band's every rule, so that a page
// nothing would ever mount over kept the header at every width. It is
// gone, and its going is the point rather than a tidy-up: a reader
// narrowing their window on such a page got no bottom bar, because the
// class had made *who published the file* a term in a question that is
// the reader's window's alone. What the band actually needed was an
// answer for a row that will not fit, and it has one that costs no
// driver — the row scrolls (stylesheet.zig). One markup, one band, and
// nothing in the sheet asks whether anything is running.

// There was a `has-seam` here for three releases, on `<body>`, written
// from `Document.body_end`'s bytes so the bottom reserve could land
// under a footer standing outside the screen. Both are gone together
// and the class is the tell: it asked *is this string non-empty?* as a
// proxy for *is there content below the screen?* — an inference about
// bytes nokre could not read. A footer is a `stack` of `link`s in the
// tree now, so the screen is the last thing in the document again and
// the reserve is one rule (docs/static-sites.md, "A seam is for what
// does not render").

/// The root attribute a page nokre wrote **whole** carries, and the
/// only thing that distinguishes one from an app mounted in someone
/// else's document.
///
/// Every scoped rule in the sheet is scoped for one reason: *the page
/// around an embedded app is not this edition's to turn around*
/// (stylesheet.zig). That reason runs out where there is no page
/// around it — `document.zig` wrote the doctype, the head and the body,
/// and everything in that body is the library's own: the skip link, the
/// two mounts, and the paper between them. It is the same asymmetry
/// `dir` already resolved in the library's favour: the live driver
/// stamps `data-direction` and deliberately never `dir`; a generated
/// document stamps both.
///
/// So the sheet keeps its scoping and gains one block behind this
/// attribute, and neither half moves for the other. The live driver
/// never writes it, and that absence is the guarantee rather than a
/// habit: an attribute a mounted app could stamp would be an edition
/// restyling its host, so the comptime block below refuses a live.js
/// that names it at all.
pub const document_attr = "data-nokre";

/// Its value. An attribute rather than a bare boolean one so that what
/// the page is saying is legible in the markup, and named for the thing
/// it asserts: nokre wrote this document.
pub const document_value = "document";

/// The same attribute on the `application/json` block a page hands its
/// boot (`document.zig`'s `configBlock`), and the value `live-boot.js`
/// looks for.
///
/// **One attribute and not an id**, because an id would be a name in the
/// driver's own namespace: the mount points, the heading anchors and the
/// skip target are all ids a consumer invented or a heading derived, and
/// a library reserving a word in that space is a collision waiting for
/// the page that spells it. `data-nokre` is already the attribute that
/// says *this node is the library's*; a value saying which is a
/// vocabulary rather than a second mechanism.
pub const boot_value = "boot";

/// The same, on the block a locale stub hands `locale-stub.js`. A stub
/// has no boot and a booting page has no chooser, so the two never stand
/// in one document — they are two values because what reads them are two
/// files, and a script that found the wrong block would be a page that
/// redirected somewhere it was never told about.
pub const locale_value = "locale";

comptime {
    // The browser half cannot import a Zig constant, so it is checked
    // against one instead: live.js keeps the modifier's spelling in a
    // string literal of its own, and a rename here that did not reach
    // it would leave the live driver toggling a class the sheet stopped
    // matching — at runtime, in a browser, with no build to fail.
    const js = @embedFile("live.js");
    // One comptime branch per byte scanned, and the file is tens of
    // kilobytes.
    @setEvalBranchQuota(8 * js.len);
    if (std.mem.indexOf(u8, js, "\"" ++ has_chrome ++ "\"") == null) {
        @compileError("live.js no longer names the \"" ++ has_chrome ++ "\" class it toggles; the two spellings have drifted");
    }
    // And the inverse, for the attribute below it. `document_attr` says
    // nokre wrote the whole file, which is exactly what a mounted app
    // cannot say — stamping it from the browser side would turn the
    // sheet's one unscoped block loose on somebody else's page. There
    // is no runtime test that would catch it there, so the absence is
    // checked here, where the file is already being read.
    if (std.mem.indexOf(u8, js, document_attr) != null) {
        @compileError("live.js stamps \"" ++ document_attr ++ "\", which claims a host page the live driver did not write");
    }
    // And the two files that *do* name it, each looking for its own
    // value in a selector no compiler reads. A rename here that did not
    // reach them is a page whose boot never fires and a chooser that
    // never chooses, in a browser, with nothing failing anywhere.
    selects("live-boot.js", @embedFile("live-boot.js"), boot_value);
    selects("locale-stub.js", @embedFile("locale-stub.js"), locale_value);
}

/// One of those two, held to the selector it has to carry.
fn selects(comptime file: []const u8, comptime bytes: []const u8, comptime value: []const u8) void {
    @setEvalBranchQuota(8 * bytes.len + 1000);
    const selector = "script[" ++ document_attr ++ "=\"" ++ value ++ "\"]";
    if (std.mem.indexOf(u8, bytes, selector) == null) {
        @compileError("nokre: " ++ file ++ " no longer selects '" ++ selector ++
            "', so it cannot find the block a document writes for it");
    }
}
