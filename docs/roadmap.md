# Roadmap

The foundation is done and tested: the core model, layout, events, focus,
router, renderer, a11y derivation, testing framework, the five platform
shells and the web's shell-less browser build, packaging, deep links, and IME on every platform, the web included — the support matrix
is in the [README](../README.md), the per-shell contract in
[internals/platform-shells.md](internals/platform-shells.md). What follows
is what remains, ordered by leverage.

## 1. Tooling

- Semantic-tree dump (debug print of any screen from a test)
- Golden diff visualizer (side-by-side PGM compare)
- CI golden regeneration workflow with image review artifacts

## 2. nokre-owned Skia builds

FreeType on every platform + published artifacts — the last
cross-platform text-determinism gap. Shaping and bidi are already
byte-identical (HarfBuzz in the shim, UAX #9 in core); only
rasterization still differs, a function of each platform's Skia build
([internals/pixel-model.md](internals/pixel-model.md)). Plan in
[internals/skia-build.md](internals/skia-build.md). iOS and Android build
from source already, and the web builds none at all now; remaining:
macOS and Windows source builds, with macOS/iOS text switched from
CoreText to FreeType so every platform shares one scaler, published as
GitHub release artifacts, then collapse to a single golden set.
