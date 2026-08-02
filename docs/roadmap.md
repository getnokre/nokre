# Roadmap

The foundation is done and tested: the core model, layout, events, focus,
router, renderer, a11y derivation, testing framework, the five platform
shells and the web's shell-less browser build, packaging, deep links, and IME on every platform, the web included — the support matrix
is in the [README](../README.md), the per-shell contract in
[internals/platform-shells.md](internals/platform-shells.md), and the
service roster with its per-platform status in
[services.md](services.md). What follows is what remains, ordered by
leverage.

## 1. More editions

An app is a semantic tree; what draws it is an *edition*, and an edition
is entitled to an opinion. The Skia edition rasterizes a grayscale frame
that is the same bytes every run on the platform that produced it; the
DOM edition hands the tree to the browser and lets it wrap where the
reader's text size says it wraps. Same app, same semantics, two
renderings, and neither is the other's fallback — the contract a third
one inherits is
[internals/renderer-editions.md](internals/renderer-editions.md).

Byte-identity *across* platforms is not on this list and is not coming.
It would mean deciding, from here, that an e-reader and a phone owe
their readers the same picture, which is the one judgement the device is
better placed to make than the library
([internals/pixel-model.md](internals/pixel-model.md) draws the line the
guarantee actually stops at). The tree travels; the drawing is local.
The editions worth building are the ones whose native mode nokre already
describes:

- **E-ink.** No animation, no color, no ticker, no frame until state
  changes — the refusals read like an e-paper datasheet written from the
  other side. What such an edition adds is what the panel wants back: a
  damage region per commit, so a screen that changed one row refreshes
  one row instead of flashing whole.
- **Terminals.** A cell grid is integer layout with a coarser pixel, the
  element set is already rows and text, and the interaction model is
  keyboard-first with nothing that a pointer alone can reach. Line and
  box drawing land on box-drawing characters; the accessibility snapshot
  is close to what the renderer would emit anyway.
- **Watches and monochrome heads-up displays.** A glance-sized viewport
  with one gesture and no room for chrome — where the nav's collapse,
  the closed element set, and *waiting is written in words* stop being
  constraints and start being the only thing that fits.

The bar is the one the DOM edition set: the renderer's element switch has
no `else`, so a second edition draws every element or fails to compile,
and the focus model, the validate/audit rules, and the a11y tree hold
unchanged because they live on the tree rather than on any renderer.

## 2. Tooling

- Semantic-tree dump (debug print of any screen from a test)
- Golden diff visualizer (side-by-side PPM compare)

## 3. Skia, smaller and published

The desktop builds link a pinned third-party prebuilt that carries far
more Skia than the ~15-function shim asks for; iOS and Android already
compile the minimal profile from source. Building that same profile for
every Skia target and publishing the archives as release artifacts —
plan in [internals/skia-build.md](internals/skia-build.md) — removes a
setup step and a dependency on someone else's release cadence. It is a
packaging errand, not a determinism one: each platform keeps the text
scaler it has.
