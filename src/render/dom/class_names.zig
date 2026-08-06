//! The two class names the edition's root element carries, as data.
//!
//! One pair, four writers: [stylesheet.zig](stylesheet.zig) selects on
//! them, [live.zig](live.zig)'s `buildFrame` writes them onto the
//! `<main>` it emits, [live.js](live.js) toggles the modifier from the
//! browser side, and a host document that wrote its own `<main>` writes
//! them a fourth time — outside this compile, where no compiler reads
//! them at all.
//!
//! That fourth writer is why the names are data rather than prose. A
//! class list nothing in the sheet matches is not a build error: with
//! the root name misspelt the page renders as unstyled markup, and with
//! the modifier written alone — the compound selector wants both on the
//! one element — a screen carrying bottom chrome silently loses the
//! clear space the nav stands in. Neither fails anywhere near where it
//! was typed (docs/internals/dom-edition.md, "What the host document
//! owes"). So the pair is exported, and exported only as the finished
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
}
