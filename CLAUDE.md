# nokre

A deliberately limited GUI library: text, lines, and boxes. Zig 0.16 + Skia
(CPU raster), grayscale only, deterministic to the pixel, accessibility
derived automatically from the tree. The frame is RGB (`kRGB_888x`,
RGBX out of `on_frame`, PPM goldens) but every canvas op except one
writes r=g=b: the single exception is the Google sign-in G, drawn by
the renderer from its own color table. rgb is infrastructure only —
no element carries a color and no consumer call accepts one.

The refusals (no hover, no animation, no color for apps, no custom
widgets, no GPU, no styling hooks) are guarantees, not gaps — never
"fix" them; their rationale is `docs/introduction.md`, and the one
recorded reversal (the G, owner-decided) is
`docs/internals/oauth.md`. Docs are two tracks: consumer-facing
(`docs/*.md`) and contributor internals (`docs/internals/*.md`) — each
fact has one home; complement, never duplicate. Start with
`docs/internals/architecture.md` (layers + module map).

## Commands

- `zig build test` — pure unit tests, no dependencies
- `zig build test -Dskia -Dgolden` — golden screenshot tests, byte-exact
  (run `tools/fetch-deps.sh` once first; add `-Dupdate-goldens` to
  create missing goldens or regenerate after an intentional visual
  change — a missing golden fails otherwise)
- `zig build run-hello -Dskia` / `run-kitchen-sink` — examples (macOS /
  Windows / Linux; Windows needs VS C++ Build Tools; goldens stay
  CoreText-generated and byte-identity is per-platform, so `-Dgolden`
  mismatches on Windows and Linux by design; Linux is
  Wayland and needs `wayland-protocols` + the `wayland-client` (>= 1.21
  for `.axis_value120` — Ubuntu 22.04+), `libxkbcommon`, `dbus-1`, and
  `libsecret-1` dev packages)
- `tools/build-skia-ios.sh` once, then `open examples/kitchen_sink/ios/KitchenSink.xcodeproj` —
  kitchen sink on the iOS Simulator / an iPhone (Apple Silicon only —
  the simulator slice is arm64, so the script refuses Intel Macs)
- `tools/build-skia-android.sh` once (needs an NDK), then open
  `examples/kitchen_sink/android` in Android Studio (or `./gradlew installDebug`
  there) — kitchen sink on an Android emulator / device
- `zig build web` and serve `zig-out/web/` — kitchen sink in the
  browser. The web's edition is the DOM one: wasm32-freestanding, no
  Skia, no emscripten (`docs/internals/dom-edition.md`)
- `zig build pkg` — generate the platform packaging manifests into
  `zig-out/pkg` (the Android example's Gradle runs it per configuration)
- `zig build check-targets` — compile-check all platform stubs

## Conventions

- Modules past a few hundred lines keep their tests in a sibling
  `*_test.zig`, wired in `src/nokre.zig`'s test block; small modules keep
  design-proof tests inline.
- App behavior is split by concern: `input.zig` (tap/key/scroll),
  `editing.zig` (text + IME), `overlays.zig` (sheet + picker),
  `nav.zig` (roster + collapse), `notices.zig` — free functions over
  `*App`; `app.zig` aliases the
  consumer-facing ones as methods.
- New element = the full checklist in `docs/internals/contributing.md`
  (element, layout, **DOM markup**, a11y, validate/audit, input, tests,
  golden, renderer contract, docs). Two editions draw now, and the DOM
  one's switch has no `else` — the second draw is a compile error until
  it is written. The set is closed; argue for semantics, not styling.
- New service = the injected-service checklist in
  `docs/internals/contributing.md`: a field on `Services`, state on the
  App, a journaling mock — a module-global `var` in `src/services` or
  `src/workers` is a bug.
- Comments carry design rationale (WCAG citations, why-not-the-obvious).
  Keep that voice; don't add narration.
- Integer math in anything that produces coordinates or bytes — no
  floats in layout, geometry, or rendering, no `Date`-like
  nondeterminism. The one sanctioned float user is `color.zig`'s
  contrast check: deterministic IEEE-754, a construction-time gate that
  never positions a pixel.
  Goldens must stay byte-identical unless the change is intentionally
  visual (then regenerate and review).
- After any change: `zig fmt src/`, then `zig build test`.
