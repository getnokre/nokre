//! The DOM edition: a renderer that interprets the semantic tree as
//! markup instead of pixels.
//!
//! [renderer-editions.md](../../../docs/internals/renderer-editions.md)
//! wrote the terms this edition is built on, and the guarantees split
//! exactly as that document said they would: grayscale, CPU raster,
//! pixel determinism and byte-exact goldens stay with the Skia edition;
//! the semantic tree, the focus order, the a11y snapshot and the
//! validate/audit rules live on the tree, so they hold here too.
//!
//! Two drivers share the one walk:
//!
//! - **static** — [serialize.zig](serialize.zig) writes the screen out
//!   as markup at build time. No server is involved at any point: the
//!   output is files.
//! - **live** — [live.zig](live.zig) runs the app in a browser and
//!   patches the document with the same walk's output, splitting at the
//!   seam `content` and `chrome` already stand on.
//!
//! Both drivers name the walk through this module — the facade is the
//! one path, so what the edition exports and what its own drivers use
//! cannot drift apart. Only the sibling `serialize_test.zig` reaches
//! past it, the sibling-test convention's way.
//!
//! Its conformance test is not a pixel golden, which cannot apply to a
//! non-reference edition. It is the **renderer contract**: per element,
//! what must be conveyed — the role the snapshot gives it, its label,
//! its state, its place in the focus order. The audit rules are the
//! seed of that contract, and `serialize_test.zig` is where it is
//! asserted. What replaces the byte-exact screenshot is a byte-exact
//! *markup* diff: the walk is deterministic, so two runs over one tree
//! produce identical output, and a human reviews a text diff instead of
//! a picture.

pub const serialize = @import("serialize.zig");
pub const stylesheet = @import("stylesheet.zig");

pub const Emitter = serialize.Emitter;
pub const Refs = serialize.Refs;
pub const Dest = serialize.Dest;

/// The JavaScript a web build ships beside the wasm module — the live
/// driver's whole browser half, as data. `addWebSite` copies exactly
/// this list; a consumer whose own generator publishes the driver
/// copies it too, so neither can drift from the set the edition
/// actually needs (driver_files.zig says why it lives in a leaf file).
pub const driver_files = @import("driver_files.zig").driver_files;

pub const DriverSource = struct { name: []const u8, bytes: []const u8 };

/// The same set, with the files themselves. `driver_files` made *which
/// files* the library's statement; this makes *where they live* one too
/// — a consumer's generator no longer joins `"src/render/dom"` onto a
/// checkout path to find bytes the library could simply hand it, and a
/// file moved inside this directory stops being a runtime read that
/// fails at generation time.
///
/// Embedded, not read: `@embedFile` puts the bytes in the same compile
/// as the list, so a stale copy cannot outlive the binary that publishes
/// it — the argument icons.zig makes for embedding the subset script.
/// It costs nothing where it is not named: a `pub const` nothing
/// references is never analyzed, so the six shells and every app carry
/// none of this.
pub const driver_sources: []const DriverSource = blk: {
    var list: [driver_files.len]DriverSource = undefined;
    for (driver_files, 0..) |f, i| list[i] = .{ .name = f, .bytes = @embedFile(f) };
    const frozen = list;
    break :blk &frozen;
};

/// The class list for the element a driver wraps `content` in, picked
/// for this screen — the whole attribute value, so a host document
/// cannot write a list the sheet does not match (class_names.zig).
pub const rootClass = serialize.rootClass;
/// The screen: every root child that is not framework chrome.
pub const content = serialize.content;
/// The layers the framework installs: notice banner, nav, sheet, picker.
pub const chrome = serialize.chrome;
/// One node and its subtree, for a driver that places things itself.
pub const node = serialize.node;
