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
//! module a boot imports, live-boot.js the boot itself, services.js the
//! shell hooks live.js imports, live-worker.js the compute actor
//! services.js spawns, locale-stub.js the chooser a locale axis's
//! unprefixed page runs, and sw.js the service worker services.js
//! registers *by URL* — a page can only ask the origin for it, so a
//! missing one is a silent 404 at runtime, not a build error, which is
//! exactly why the set is data rather than prose
//! (docs/internals/dom-edition.md). The one consumer that re-typed this
//! list shipped two of the four it then had.
//!
//! **A site carries the whole set whether or not it spends all of it**,
//! which is the same posture sw.js has always had: an app shell runs no
//! chooser and a single-locale site publishes no stub, and both carry
//! locale-stub.js, because one list a consumer installs whole is what
//! makes a missing file unreachable. A file nobody requests costs a
//! kilobyte on the origin and nothing at any reader.

const std = @import("std");

/// The module a boot imports `mount` from. It is named in exactly two
/// places outside this file — `live-boot.js`'s own import, checked
/// below, and packaging.zig's emitted boot script — and in neither of
/// them by a consumer.
pub const entry = "live.js";

/// The one file name a *generated document* names: the module a page
/// `dom.document` wrote loads, which reads its options out of the JSON
/// block beside it and calls `mount`. A driver joins it to the directory
/// it published the set under and never types it (document.zig).
pub const boot_entry = "live-boot.js";

/// The one file name a *stub* names, for `boot_entry`'s reason: the
/// chooser `dom.localeStub`'s page runs, over the JSON block beside it.
pub const stub_entry = "locale-stub.js";

pub const driver_files: []const []const u8 = &.{
    entry,
    boot_entry,
    "live-worker.js",
    "services.js",
    stub_entry,
    "sw.js",
};

comptime {
    // The boot module imports its sibling by name, and no compiler
    // follows a string in a `.js` file — so the two spellings are held
    // together here, the way class_names.zig holds the class live.js
    // toggles. A rename of `entry` that did not reach the import would
    // be a page that fetches its boot and gets a 404 for the driver, in
    // a browser, with no build to fail.
    const boot_js = @embedFile(boot_entry);
    @setEvalBranchQuota(8 * boot_js.len + 1000);
    if (std.mem.indexOf(u8, boot_js, "\"./" ++ entry ++ "\"") == null) {
        @compileError("nokre: " ++ boot_entry ++ " no longer imports \"./" ++ entry ++
            "\"; the two spellings of the driver's entry module have drifted");
    }
}
