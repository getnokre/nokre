# nokre documentation

nokre is a deliberately limited GUI library: text, lines, and boxes,
grayscale only (one framework-drawn trademark excepted — see
[introduction.md](introduction.md)), deterministic to the pixel,
accessibility derived automatically from the tree. This directory is
the whole story.

The docs come in **two tracks**, by audience:

- **Consumer** (this folder) — everything you need to *build and ship an
  app*: the philosophy, the course, and one reference per surface.
- **Contributor** ([internals/](internals/)) — how the promises are kept
  inside: the layer cake, the pixel contract, the shells, and the
  per-service wiring.

Each fact has exactly one home. The two tracks complement — they never
duplicate — so a consumer section states the contract and its internals
twin states how it's wired, each linking the other.

New here? Read [introduction.md](introduction.md), then work through
[getting-started.md](getting-started.md); reach for the reference docs as
you need them.

## Build an app (consumer)

**Start here**

- [introduction.md](introduction.md) — the philosophy: what nokre
  refuses, what each refusal buys, and the small vocabulary you actually
  touch. Read this first.
- [getting-started.md](getting-started.md) — the course: build one app
  (Notes) that uses every feature, test each part as you go, and ship it
  to five platforms.

**Reference** — one per surface, semantics first

- [elements.md](elements.md) — the closed element set: each element's
  meaning, its visual spec, and when to reach for it over its neighbors.
- [routing.md](routing.md) — screens as named builders and navigation as
  a stack: the motions, the scroll positions an entry remembers, the
  references that name a screen and its arguments, the address bar they
  mirror into on the web, and the one gesture — an edge pan that goes
  back without anything sliding.
- [markdown.md](markdown.md) — the `document` element: the subset it
  parses, the rule that everything else degrades to its literal source
  text, heading rebasing, and how links map to in-app routes.
- [accessibility.md](accessibility.md) — the a11y contract: how the
  snapshot is derived, what construction refuses to build, and what the
  automatic audit catches.
- [localization.md](localization.md) — ARB catalogs compiled at comptime,
  ICU message syntax, right-to-left chrome, the two homes a translated
  nav bar comes from (the route table's titles and the framework's own
  words), and everything the compiler checks so a build that passes has
  every locale whole.
- [testing.md](testing.md) — the headless e2e harness: semantic queries,
  the input driver, service fakes, step traces, and byte-exact golden
  screenshots.
- [services.md](services.md) — optional OS capabilities beyond the window
  (secure storage, clipboard, http, deep links, identity, device locale,
  workers, sign-in, purchases, external URLs): the roster and each
  service's consumer contract.

**Project**

- [roadmap.md](roadmap.md) — what's built and what remains: the editions
  a semantic tree still deserves, tooling, Skia packaging.

## Work on nokre (contributor)

Start with [internals/architecture.md](internals/architecture.md) for the
layer rules, then [internals/contributing.md](internals/contributing.md)
for the checklists. The full index — core contracts, the five platform
shells and the shell-less web, and the per-service wiring — is
[internals/README.md](internals/README.md).
