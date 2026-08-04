# Renderer editions

Why the door is open, which seams keep it open, and what a second
edition owes the first — so a future change doesn't close the door by
accident.

This was a design note before it was anything else (a game-engine
edition was the motivating thought experiment). One edition has since
walked through the door: the **DOM edition**
([dom-edition.md](dom-edition.md)), which interprets the tree as markup.
What follows is still the general contract; that document is the
particular one.

## The tree is the contract

An app expresses zero visual intent — the refusals in
[introduction.md](../introduction.md) (no styling hooks, no custom
widgets) mean no app can depend on presentation. That is what makes a
second renderer possible by construction: a renderer is an
*interpretation* of the semantic tree, the way a browser interprets HTML.
It may draw each element however it likes, with capabilities the Skia
edition refuses, so long as the semantics — element set, behavior, focus
model, a11y tree — are conveyed faithfully.

Consequently the guarantees split:

- **Per-edition:** grayscale, CPU raster, pixel determinism, byte-exact
  goldens. These belong to the Skia edition, which remains the reference
  implementation ([pixel-model.md](pixel-model.md) is its contract). An
  edition on a platform that will not be told what to do adds to this
  column rather than pretending — the DOM edition moves *no fractional
  scaling* and *no system fonts* into it, and says so.
- **Cross-edition:** the semantic tree, event behavior, focus traversal,
  the accessibility snapshot, and the validate/audit rules — all of which
  live on the tree, so they hold regardless of renderer.

## The seams, and the disciplines that keep them

- Elements ([element.zig](../../src/core/element.zig)) are pure data.
  [renderer.zig](../../src/render/renderer.zig)'s `drawNode` switch *is*
  the Skia edition's interpretation. A second edition is a sibling
  renderer walking the same tree — never draw methods on elements.
  **Renderer owns drawing; core never learns a backend exists.**
- Geometry stays in core. Layout rects feed hit testing, scroll, focus,
  and a11y bounds, so a new edition's freedom is *within* each element's
  rect, not over the boxes themselves. Edition-owned layout inverts the
  event flow — the backend resolves hits and delivers semantic events —
  which the DOM edition needed and `App.deliver` now answers: a press, a
  focus move, a choice. The inversion is only about *which element was
  meant*. Everything else an input carries stays in core, and an edition
  that restated any of it would be keeping a second copy of a rule with
  one home ([dom-edition.md](dom-edition.md) has the bug that taught
  this).
- Shells name no backend. A shell's job is events in and blit the buffer
  it is handed ([platform-shells.md](platform-shells.md)), so
  [c_shell.zig](../../src/platform/c_shell.zig) holds a
  `FrameSource` — one `render` call plus `deinit` — and the platform file
  names the installer its Runner runs before the loop starts.
  [skia_frame.zig](../../src/platform/skia_frame.zig) is the reference
  edition's: surface lifecycle, the staleness check, `renderer.render`. A
  second edition installs its own and touches no shell. This seam was
  added late — the surface used to live on the shell state, which would
  have meant forking five shells per edition.
- Pixel goldens cannot apply to a non-reference edition. Its conformance
  test is a **renderer contract**: per element, what MUST be conveyed
  (disabled visible, focus always indicated, notice prominence ordering,
  …). The audit rules are the seed of that contract. Where an edition's
  output is itself deterministic text, it gets the golden discipline
  back one layer out: the DOM edition diffs *markup* byte for byte,
  which a human reads instead of a picture.

## The cost, named honestly

Every new element is one draw implementation *per edition*. The
contributing checklist multiplies. This is the recurring tax of a second
renderer, and it is bearable only because the element set is closed —
which is one more reason it stays closed.
