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

/// The screen: every root child that is not framework chrome.
pub const content = serialize.content;
/// The layers the framework installs: notice banner, nav, sheet, picker.
pub const chrome = serialize.chrome;
/// One node and its subtree, for a driver that places things itself.
pub const node = serialize.node;
