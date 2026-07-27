# nokre internals

Contributor track: how the promises the consumer docs state
([../README.md](../README.md)) are kept inside. The layer rules here are
enforced in review, not aspirational.

**Start with [architecture.md](architecture.md)** — the layer cake and the
module map orient everything below — then
[contributing.md](contributing.md) for the checklists that keep a change
honest across every layer.

Each service and shell doc is the internals twin of a consumer section;
they link both ways and never restate each other.

## Orientation

- [architecture.md](architecture.md) — the strict layer cake, the module
  map, the one-loop data flow, and the design rules review enforces.
- [contributing.md](contributing.md) — conventions, the add-an-element
  checklist, the write-a-service checklist, and what nokre tests for
  itself.

## Core contracts

- [pixel-model.md](pixel-model.md) — the normative determinism contract:
  integer logical pixels, the thirteen grays, shaped grayscale text, and
  the type scale.
- [renderer-editions.md](renderer-editions.md) — why a non-Skia renderer
  stays possible by construction, which seams keep the door open, and
  what a second edition owes the first.
- [dom-edition.md](dom-edition.md) — the one that walked through it: the
  same tree walk written as markup, what it keeps, what it hands back,
  and the open question of whether it replaces Skia on the web.

## Platform

- [platform-shells.md](platform-shells.md) — the one dumb shell contract
  and the five shells' specifics: blit, input, IME, deep links, and the
  accessibility bridge per platform.
- [skia-build.md](skia-build.md) — how Skia is vendored or built per
  platform, and the path to nokre-owned FreeType-everywhere builds that
  close the last cross-platform text gap.

## Services

Consumer roster and philosophy: [../services.md](../services.md). The
wiring behind each Working service:

- [workers.md](workers.md) — the compute-actor design and its
  per-platform delivery: the model, guarantees, the wire codec,
  transports, and the inline testing story (the consumer API — spawn,
  send, retire — is in [../services.md](../services.md)).
- [http.md](http.md) — how one-API-everywhere rides the workers delivery
  lane instead of building a second cross-thread structure.
- [secure_store.md](secure_store.md) — the pouch wired on each backend
  (Keychain, Credential Manager, Keystore, libsecret, the wasm table) and
  the one-fake-per-app test story.
- [oauth.md](oauth.md) — the sign-in browser session: one primitive
  instead of two vendor SDKs, why the redirect is a call and not a
  constant, and the brand marks — Apple's built in one monochrome glyph,
  Google's refused for good, with the record of what building it would
  have cost.
- [haptics.md](haptics.md) — the one gesture and its one haptic: why an
  edge pan that goes back is allowed where a sliding transition is not,
  where the threshold and its hysteresis live, and why a service nobody
  can call is still a service.
- [iap.md](iap.md) — the platform stores: four verbs over two real
  stores, why money is a string the store hands over, the one Maven
  coordinate nokre asks for, and why three platforms answer "there is no
  store here" at runtime rather than at compile time.
