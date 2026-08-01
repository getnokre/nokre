# Architecture

nokre is a strict layer cake. Each layer knows only the layer below it.

```
┌────────────────────────────────────────────────────────┐
│ your app: route builders + actions                     │
├────────────────────────────────────────────────────────┤
│ core (pure Zig, zero dependencies)                     │
│   tree · element · layout · event · focus · router     │
│   app — the one object shells and tests both drive     │
│   (behavior: input · editing · overlays · notices)     │
├──────────────────────────┬─────────────────────────────┤
│ render                   │ a11y                        │
│   Canvas vtable          │   semantics snapshot        │
│   renderer (tree→canvas) │   accesskit adapter         │
├──────────────────────────┴─────────────────────────────┤
│ render/skia — Zig bindings over shim/nokre_skia.cpp   │
│   (only linked with -Dskia)                            │
│ render/dom  — the same walk, as markup (links nothing) │
├────────────────────────────────────────────────────────┤
│ platform shells — one per OS, deliberately dumb        │
│   surface + input events + blit; nothing else          │
└────────────────────────────────────────────────────────┘
```

## Module map

| Path | Responsibility |
| --- | --- |
| [src/core/geometry.zig](../../src/core/geometry.zig) | `Point`, `Size`, `Rect` — integers only |
| [src/core/color.zig](../../src/core/color.zig) | `Gray`: the thirteen permitted shades |
| [src/core/text.zig](../../src/core/text.zig) | families, type scale, `Measurer` interface |
| [src/core/bidi.zig](../../src/core/bidi.zig) | UAX #9 in full: paragraph direction, embedding levels, visual run order — pure integer Zig, UCD-validated |
| [src/core/element.zig](../../src/core/element.zig) | the closed element set (`Element` union) |
| [src/core/tree.zig](../../src/core/tree.zig) | retained tree, generational `NodeId`s |
| [src/core/layout.zig](../../src/core/layout.zig) | block-flow layout, word wrap, metrics |
| [src/core/event.zig](../../src/core/event.zig) | pointer (press/release) / key / text / IME / scroll — no hover |
| [src/core/focus.zig](../../src/core/focus.zig) | document-order focus traversal |
| [src/core/router.zig](../../src/core/router.zig) | named-screen stack with per-entry arguments, instant rebuilds, the current-route observer |
| [src/core/app.zig](../../src/core/app.zig) | the App struct: state, lifecycle, dispatch |
| [src/core/input.zig](../../src/core/input.zig) | press/release, key and scroll handling, hit testing |
| [src/core/editing.zig](../../src/core/editing.zig) | text-field editing, IME protocol |
| [src/core/overlays.zig](../../src/core/overlays.zig) | modal sheet + select and section pickers |
| [src/core/nav.zig](../../src/core/nav.zig) | the nav roster (plus the current screen when it is off it) and its two shapes: row of items → collapsed chip |
| [src/core/notices.zig](../../src/core/notices.zig) | notices → banner / pane / indicator |
| [src/core/overflow.zig](../../src/core/overflow.zig) | the folded tail of an overflowing row of actions: the `more` control and its sheet |
| [src/core/qr.zig](../../src/core/qr.zig) | QR encoding over vendored qrcodegen |
| [src/core/markdown.zig](../../src/core/markdown.zig) | the `document` element's parser: the Markdown subset, literal degradation of the rest ([../markdown.md](../markdown.md)) |
| [src/l10n/l10n.zig](../../src/l10n/l10n.zig) | ARB catalogs compiled at comptime: `Bundle`, cross-locale validation, `tr`/`fmt`/`resolve` ([../localization.md](../localization.md)) |
| [src/l10n/arb.zig](../../src/l10n/arb.zig) / [plural_rules.zig](../../src/l10n/plural_rules.zig) | comptime ARB + ICU-subset parsing; CLDR integer plural rules |
| [src/workers/workers.zig](../../src/workers/workers.zig) | compute actors: registry, framing, UI-thread delivery ([workers.md](workers.md)) |
| [src/workers/codec.zig](../../src/workers/codec.zig) | comptime-checked message codec |
| [src/workers/thread.zig](../../src/workers/thread.zig) / [post.zig](../../src/workers/post.zig) | native / web worker transports |
| [src/render/canvas.zig](../../src/render/canvas.zig) | `Canvas` vtable + `Recording` canvas |
| [src/render/renderer.zig](../../src/render/renderer.zig) | tree → canvas draw calls |
| [src/render/skia/canvas_skia.zig](../../src/render/skia/canvas_skia.zig) | Skia-backed `Canvas` + `Measurer` |
| [src/render/dom/serialize.zig](../../src/render/dom/serialize.zig) | `node`, `drawNode`'s counterpart: tree → markup ([dom-edition.md](dom-edition.md)) |
| [src/render/dom/stylesheet.zig](../../src/render/dom/stylesheet.zig) | that edition's stylesheet, generated from color/text/layout |
| [src/render/dom/live.zig](../../src/render/dom/live.zig) / [live.js](../../src/render/dom/live.js) | that edition's live driver: the app in a browser, wasm32-freestanding, no Skia |
| [shim/freestanding](../../shim/freestanding/README.md) | the three headers vendored qrcodegen wants where there is no libc |
| [src/a11y/semantics.zig](../../src/a11y/semantics.zig) | tree → flat accessibility snapshot |
| [src/a11y/accesskit.zig](../../src/a11y/accesskit.zig) | adapter over the AccessKit C bindings — VoiceOver, UIA, and AT-SPI are live; iOS (`UIAccessibilityElement`s) and Android (`AccessibilityNodeProvider`) consume the same `flatten` output without AccessKit, and the web needs no bridge at all |
| [src/testing/harness.zig](../../src/testing/harness.zig) | headless e2e framework |
| [src/core/test_app.zig](../../src/core/test_app.zig) | the mocked App nokre's *own* unit tests build on — internal, not the consumer fixture above |
| [src/platform/platform.zig](../../src/platform/platform.zig) | comptime backend selection |
| [src/platform/c_shell.zig](../../src/platform/c_shell.zig) | shared Zig side of the C shell contract ([shell.h](../../src/platform/shell.h)); names no rendering backend |
| [src/platform/skia_frame.zig](../../src/platform/skia_frame.zig) | the Skia frame source the shells install: surface lifecycle and the render call ([renderer-editions.md](renderer-editions.md)) |
| [src/services/services.zig](../../src/services/services.zig) | the `Services` struct: per-app service injection at `App.init` ([../services.md](../services.md)) |
| [src/services/package_info/package_info.zig](../../src/services/package_info/package_info.zig) | app identity, declared once in build.zig ([services.md](../services.md)) |
| [src/services/http/http.zig](../../src/services/http/http.zig) | request/response client, one API per platform ([http.md](http.md)) |
| [src/services/secure_store/secure_store.zig](../../src/services/secure_store/secure_store.zig) | encrypted key/value for small secrets, sync, namespaced by `pkg_id` ([secure_store.md](secure_store.md)) |
| [src/packaging/packaging.zig](../../src/packaging/packaging.zig) | platform manifests and the derived app icon ([icon.zig](../../src/packaging/icon.zig)) generated from the build declaration — build-time only, never compiled into apps ([../services.md](../services.md)) |
| [src/services/clipboard/clipboard.zig](../../src/services/clipboard/clipboard.zig) | one verb: copy text out, via the shell's C hook ([services.md](../services.md)) |
| [src/services/deep_link/deep_link.zig](../../src/services/deep_link/deep_link.zig) | inbound URLs at launch and while running, delivered on the UI thread; routing stays the app's ([services.md](../services.md)) |
| [src/services/locale/locale.zig](../../src/services/locale/locale.zig) | the device's BCP 47 tag, cached at boot and re-reported on change; feeds `l10n.Bundle.resolve` ([services.md](../services.md)) |
| [src/services/oauth/oauth.zig](../../src/services/oauth/oauth.zig) | the sign-in browser session: one authorize URL out, one callback URL back, plus PKCE ([oauth.md](oauth.md)) |
| [src/services/haptic/haptic.zig](../../src/services/haptic/haptic.zig) | the back gesture's threshold knock — injected like every service, callable by no app ([haptics.md](haptics.md)) |
| [src/services/iap/iap.zig](../../src/services/iap/iap.zig) | the platform stores: catalog, payment sheet, purchase stream, finish, restore — and `available` where there is no store ([iap.md](iap.md)) |
| [src/services/open_url/open_url.zig](../../src/services/open_url/open_url.zig) | one verb: hand a URL to the system browser, behind a closed scheme allowlist; external link activation lands here ([services.md](../services.md)) |
| [src/services/share/share.zig](../../src/services/share/share.zig) | one verb: put the OS share sheet up with UTF-8 text on it — and `available` where there is no sheet ([services.md](../services.md)) |
| [shim/nokre_skia.cpp](../../shim/nokre_skia.cpp) | the entire C surface over Skia |

## Data flow

One loop, everywhere:

1. A shell (or the test driver) delivers an `Event` to `App.dispatch`.
2. Dispatch mutates semantic state: focus, toggle on, input value,
   scroll offset — or invokes an app `Action`, which edits the tree and
   calls `app.invalidate()`.
3. When `app.needs_frame` is set, the shell asks its installed frame source
   for one: `performLayout` (dirty-flagged) then `renderer.render(app,
   canvas)`. The shell reconciles the viewport and safe area the OS
   reported and blits the buffer it gets back; what is *in* the buffer is
   the source's business, never the shell's.
4. The shell blits the RGBX buffer. That's the entire frame story — there
   is no ticker; a nokre app at rest costs zero CPU.

The testing harness drives step 1 and reads state after step 2, and can run
step 3 against either the `Recording` canvas (pure) or a Skia surface
(golden tests). Because it is the same `App`, e2e tests are faithful by
construction.

## Design rules

- **Core stays pure.** `src/core` and `src/testing` import nothing outside
  the repo; the one extern surface is vendored qrcodegen, isolated in
  [core/qr.zig](../../src/core/qr.zig). `zig build test` runs on any machine
  with only a Zig toolchain.
- **Shells stay dumb.** A platform shell may not measure text, walk the
  tree, or interpret input beyond keycode mapping. If a shell needs
  intelligence, the design is wrong.
- **The element set is closed.** New capability means a new semantic
  element with layout, rendering, a11y, and audit rules — not a styling
  hook. The checklist is in [contributing.md](contributing.md); the
  argument for closure is in [introduction.md](../introduction.md).
- **Tree strings are arena'd; the router rebuild is the reclaim point.**
  Every string handed to the tree is copied into a tree-owned arena
  (validated on the way in — [tree.zig](../../src/core/tree.zig)'s
  module doc), and nothing is freed on node removal. Each navigation's
  rebuild (`Tree.reclaim`) re-copies the surviving chrome's strings
  into a fresh arena — node identity untouched, so focus and the picker
  hold — and frees the old one, taking the removed screen's strings and
  every editing splice and IME copy since the last rebuild with it.
  Typing accumulates memory only until the next rebuild.
- **Service state lives on the App.** Every App is constructed with its
  services (`Options.services`; mocks in test builds, enforced at
  compile time) and owns their state — the workers `Runtime`, each
  mock's heap half. A module-global `var` in `src/services` or
  `src/workers` is a bug: two apps in one process must be disjoint by
  construction, not by the test runner's serialization. The documented
  exemptions — wasm shell singletons (the instance *is* one app) and
  the refcounted native Io backends — each carry a guard and a comment.

Code conventions (test layout, formatting, comment voice) are in
[contributing.md](contributing.md). Why the render seam is shaped to
permit non-Skia renderer editions is
[renderer-editions.md](renderer-editions.md); the one that exists is
[dom-edition.md](dom-edition.md).
