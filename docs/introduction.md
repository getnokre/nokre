# Introduction

nokre is a deliberately limited GUI library: text, lines, and boxes.
Grayscale only. Written in Zig, rasterized on the CPU by Skia, as
expressive as Markdown — literally: a `document` element takes a
Markdown source and expands it into ordinary elements
([markdown.md](markdown.md)) — plus actions and navigation. Think: apps
for a grayscale Kindle.

The limitation is the product. Every capability a UI toolkit offers is
also a way to ship a broken app — inaccessible, inconsistent across
machines, untestable without a screenshot farm. nokre keeps only what it
can guarantee correct, and turns each removed capability into a promise
that holds for every app built on it.

## Three promises

**Accessible by construction.** Every element is semantic — a heading is
structure, a button is a button, a label is mandatory. The accessibility
tree and the pixels are both projections of the same semantic tree, so
accessibility cannot be added and cannot be omitted. What can't be
verified at construction is caught by an automatic audit. The full
contract is [accessibility.md](accessibility.md).

**Deterministic to the pixel.** Same logical viewport ⇒ same bytes,
across runs, machines, and (once nokre ships its own Skia builds)
platforms. This one is the *Skia edition's* promise — the five native
shells. On the web the tree is rendered as markup and the browser
draws it, which trades these bytes for an accessibility tree that is
the page rather than a copy of it
([internals/dom-edition.md](internals/dom-edition.md)).
Layout is integer math; rendering has no GPU, no hinting, no subpixel
tricks. Screenshots are therefore *tests* — byte-exact, no tolerance, no
perceptual diffing. The normative rules are
[internals/pixel-model.md](internals/pixel-model.md).

**Testable end to end, headless.** nokre ships its own e2e framework
driving the real `App` through the real event pipeline — no browser
driver, no window, no flakiness. Interactions go through the user's
pipeline; assertions read the screen reader's snapshot. End to end means
your whole app: the harness stops at the platform shell, which is the
boundary that buys the determinism —
[testing.md](testing.md#where-the-harness-stops) names it exactly.

## What nokre refuses to do

Most are load-bearing for a promise above: remove one and it collapses.
The rest take away a question the framework never needed answered. They
are guarantees, not gaps — an app built on nokre cannot have these
problems, because the library cannot express them.

- **No hover states.** Interaction is press and release, key, focus, and
  one gesture — a drag in from the leading screen edge, which goes back.
  Nothing changes because a pointer floated over it: an affordance that
  only pointer users can discover is information withheld from touch and
  keyboard users, so the entire category is absent. The gesture is not
  an exception to that rule but an illustration of it — it is a shortcut
  for a control that is always on screen, focusable, and announced, and
  it reaches nothing the Back control does not.

  The pointer has a press and a release rather than a single tap because
  **activation belongs on the release**: moving off a control before
  letting go must abort it (WCAG 2.5.2), and a lone tap cannot say so.
  Two things use the gap between them, both on the same terms as the
  gesture. Holding the collapsed nav's chip opens its section list so
  the same press can choose a row by releasing on it — a shortcut for a
  list that a plain click, the keyboard, and a screen reader all reach
  anyway (WCAG 2.5.1). And while that list is open, moving the pointer
  moves *focus* to the row beneath it. That last one is the line worth
  watching: it looks like hover and is not, because hover is a state
  with no keyboard equivalent and this is the very state ↑/↓ move.
  Nothing else on screen follows a pointer, and nothing else may.
- **No transitions or animation.** State changes are instant. Motion is a
  vestibular hazard (WCAG 2.3.3), an untestable intermediate state, and a
  tax on determinism; nokre has none to configure or to disable. A
  spinner is animation too — waiting is written in words. The back
  gesture is where this gets tested hardest and holds: the finger moves
  and *the screen does not*, because a screen half-slid has no tree
  behind it to describe or to golden, and finishing the slide after the
  finger lifts would need frames nobody asked for. What replaces the
  motion is a threshold, marked as it is crossed —
  [routing.md](routing.md#the-back-gesture) has the mechanics.
- **No color.** Thirteen fixed steps of gray, five semantic aliases
  (`ink`, `dark`, `mid`, `light`, `paper`). Color as information excludes
  color-blind users, so information must survive grayscale anyway —
  nokre makes that the only mode, and proves the whole palette against
  WCAG contrast in unit tests, floor *and* ceiling: body text is 14.2:1,
  not the 21:1 of true black on true paper, because past a point more
  contrast stops buying legibility and starts costing comfort. Dark mode
  is a second ramp rather than an inversion of the first, so it can be
  gentler than light where light-on-dark reads heavier — a mirror moves
  every ratio together and cannot. A palette you can enumerate is a
  palette you can prove.

  One honest asterisk, framework-drawn: the Google sign-in button's
  multicolour G — a trademark whose owner refuses a gray variant. The
  framework paints it from its own renderer; there is no way for an app
  to color anything, no element that takes a color, and nothing else on
  any screen that is not gray. The refusal an app builds against is
  intact — *your* information still has to survive grayscale, because
  grayscale is still all you can author.
  [internals/oauth.md](internals/oauth.md) records why this one mark
  crossed the line and nothing else may follow it.
- **No system fonts.** Four bundled families — one mono, one
  proportional, one icon face, and one Arabic-script companion every
  family falls back to for Persian and Arabic — every variant a real
  drawn face from the same upstream build (bold, italic, and
  bold-italic for the two text families; the companion has no italic,
  because the script has none), and app text can reach nothing else.
  No synthetic
  emboldening or shearing either: faked variants are
  rasterizer-dependent, which is the variance the bundling exists to
  close. The moment the OS font stack participates, byte-identity
  across machines is gone. Shaping and bidirectional layout are built
  in the same spirit: HarfBuzz pinned in the shim, UAX #9 in core,
  direction derived from the text itself — never a knob.
- **No GPU.** CPU rasterization only. No driver variance, no flicker,
  no capability matrix — the same bytes everywhere is only promisable
  when no driver is involved.
- **No fractional scaling.** Layout is integer logical pixels; hidpi is
  an integer scale factor, so a 2× frame is exactly the 1× frame at
  double density. Fractional coordinates are where "looks slightly
  different on my machine" comes from.
- **No custom widgets, no styling system.** The element set is closed.
  Semantics can only be derived from elements whose meaning the framework
  knows, and contrast, target size, and labeling can only be enforced on
  elements the framework owns. A styling hook is an accessibility
  loophole. New capability means arguing a new *semantic* element into
  the set — see [elements.md](elements.md).
- **No paths.** A reference names a screen: `note~42`. It does not say
  where the screen sits, because screens do not sit anywhere. A note is
  reached from the list, from a search, from a tag, from what you
  starred. A path would have to call one of those the parent, and it
  would be wrong from the other three. The author picks one anyway,
  picks again whenever a new way in is added, and the pick goes in the
  URL, where it will not match how most people arrived. Where someone
  came from is what nav chrome, links, and the back stack already show,
  and they can differ from visit to visit because the app remembers the
  trail. A reference is only a name, so one screen has one reference,
  whoever is looking. URLs stay short as a side effect —
  [routing.md](routing.md).

The refusals also buy something quieter: a nokre app at rest costs zero
CPU. No ticker, no vsync loop, no animation frames — a frame renders when
state changes, and otherwise nothing runs.

## The vocabulary

What a consumer actually touches is small:

- **Elements** — the closed set: static text and images, containers,
  interactive controls, navigation chrome, and layers. Every one is
  specified in [elements.md](elements.md), semantics first.
- **The tree** — a retained tree you append elements to. Malformed
  structure is rejected at `append`; an invalid screen never exists.
- **Routes and actions** — screens are named builder functions; behavior
  is plain context + function-pointer pairs. No closures are allocated,
  ever.
- **Grays and scales** — thirteen grays (you will mostly use the five
  aliases) and six type scales. Exact bytes and metrics live in the
  [pixel model](internals/pixel-model.md); you pick names, the framework
  guarantees they are legible where you put them.

## Is nokre for you?

nokre suits tools, dashboards, settings-heavy utilities, readers,
forms — apps whose value is *what they say and do*, and which want
accessibility, cross-platform pixel fidelity, and real e2e tests more
than they want brand expression.

If the product needs color, motion, media, custom visual identity, or
free-form canvases, nokre is the wrong library — and will not grow the
features to become the right one.

## Where next

[README.md](README.md) is the full map. The usual path:

- [getting-started.md](getting-started.md) — the course: one app, every
  feature, tested and shipped to five platforms
- [elements.md](elements.md) — every element, its semantics, when to use it
- [accessibility.md](accessibility.md) — how a11y is derived and enforced
- [localization.md](localization.md) — catalogs, ICU messages, right-to-left
- [testing.md](testing.md) — the harness, queries, golden screenshots
- [services.md](services.md) — OS capabilities beyond the window
- [roadmap.md](roadmap.md) — what's coming next
- [internals/](internals/README.md) — how it works inside, for
  contributors
