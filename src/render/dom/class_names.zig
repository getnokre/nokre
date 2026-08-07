//! The names this edition's markup and its stylesheet both write — the
//! classes it puts on elements, and the one attribute that says who
//! wrote the page around them — as data.
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

/// The bottom reserve, conditional on `layout.hasBottomChrome`. Written
/// beside `root` on the same element, never alone.
pub const has_chrome = "has-chrome";

/// The skip link's, on the anchor `document.zig` writes past the chrome
/// to the content mount. Unlike the pair above it has one writer inside
/// this compile and one rule in the sheet — it is here because the two
/// are in different files and a name that lives in only one of them is
/// how the pair above got into trouble.
pub const skip = "skip";

/// The nav's, on a page that carries no boot script — the one thing
/// that keeps the bar out of the bottom band at a phone's width.
///
/// Which shape the roster wears is the reader's window's to decide
/// (stylesheet.zig, "two shapes and the reader's window picks"): the
/// band at a phone's width, a header above the page anywhere wider.
/// Deciding is something a *driver* does, though — it re-asks the
/// question every time the window moves, and the shape it can fall back
/// to when a row will not fit is a chip that opens a list. A page with
/// no boot has neither. The markup it was served in is the whole of what
/// its reader will ever get, at every width, so the shape it is served
/// in has to be the one that answers every width — the header, which
/// wraps.
///
/// It is not a claim about who wrote the file. `document_attr` is that
/// claim and it is a different one: a generated page that *does* boot
/// carries no `no-boot` and wears the band on a phone exactly as an app
/// shell does, because there is a driver on it to work the chip.
/// `document.zig` sets it from `Document.boot` and nothing else writes
/// it — a live frame cannot, since the driver emitting the frame is the
/// boot whose absence this names.
pub const no_boot = "no-boot";

/// The root attribute a page nokre wrote **whole** carries, and the
/// only thing that distinguishes one from an app mounted in someone
/// else's document.
///
/// Every scoped rule in the sheet is scoped for one reason: *the page
/// around an embedded app is not this edition's to turn around*
/// (stylesheet.zig). That reason runs out where there is no page
/// around it — `document.zig` wrote the doctype, the head and the body,
/// and everything in that body is either the screen or bytes a driver
/// handed to a seam. It is the same asymmetry `dir` already resolved in
/// the library's favour: the live driver stamps `data-direction` and
/// deliberately never `dir`; a generated document stamps both.
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
}
