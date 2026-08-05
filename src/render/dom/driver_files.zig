//! The web driver's file set, as data.
//!
//! One list, three readers: build.zig's `addWebSite` copies these
//! files into every web build, its js-parse gate parses each of them,
//! and a consumer whose own generator publishes the driver (the nokre
//! site does) copies the same list through `dom.driver_files`. This is
//! a leaf module with no imports because build.zig is one of the
//! readers — the build script cannot import anything that reaches the
//! rest of the library.
//!
//! Every file here ships or the edition breaks quietly: live.js is the
//! module the page boots, services.js the shell hooks it imports,
//! live-worker.js the compute actor services.js spawns, and sw.js the
//! service worker services.js registers *by URL* — a page can only ask
//! the origin for it, so a missing one is a silent 404 at runtime, not
//! a build error, which is exactly why the set is data rather than
//! prose (docs/internals/dom-edition.md). The one consumer that
//! re-typed this list shipped two of the four.

pub const driver_files: []const []const u8 = &.{
    "live.js",
    "live-worker.js",
    "services.js",
    "sw.js",
};
