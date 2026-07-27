# Contributing

The consumer docs ([introduction](../introduction.md) onward) state what
nokre promises; this directory is how the promises are kept. Start with
[architecture.md](architecture.md) for the layer rules — they are enforced
in review, not aspirational.

## Conventions

- After any change: `zig fmt src/`, then `zig build test`.
- Modules past a few hundred lines keep their tests in a sibling
  `*_test.zig`, wired from the test block in
  [src/nokre.zig](../../src/nokre.zig); small modules keep design-proof
  tests inline. Implementation files should read in one pass.
- Comments carry design rationale — WCAG citations, why-not-the-obvious.
  Keep that voice; don't add narration.
- Integer math in layout, geometry, and anything that produces
  coordinates or bytes. The one sanctioned float user is the contrast
  check in [color.zig](../../src/core/color.zig) — deterministic
  IEEE-754, a construction-time gate that never positions a pixel. No
  clocks, no randomness — anything nondeterministic breaks the
  [pixel model](pixel-model.md).

## Adding an element

The element set is closed on purpose; additions are argued on semantics,
never styling ([introduction.md](../introduction.md) has the argument).
If a proposed element can't state its semantics in one sentence, it
doesn't go in. When one does, it is a cross-cutting commitment:

1. Struct + `Element` union arm + `Role` in
   [element.zig](../../src/core/element.zig)
   (`role()`, `isInteractive()`, `isFocusable()`, `label()`).
2. Layout rules in [layout.zig](../../src/core/layout.zig) — including
   the element's stance on the advised margin (`Ctx.margin`): apply it,
   the default; or, only if the element must reach an edge to work,
   decline it and bleed. A new container must state whether it passes
   the advice through (borderless flow) or consumes it (anything that
   draws or clips an edge) — `flowChildren` demands the choice at every
   call site. Any leading/trailing geometry mirrors under `Ctx.rtl`:
   place intrinsic blocks with `startX`, not a bare `x`, and give each
   corner control a left/right branch. Vertical geometry is
   direction-blind — don't touch it.
3. Drawing in [renderer.zig](../../src/render/renderer.zig) — mirror the
   same leading/trailing choices with the renderer's `mirrored(app)` /
   `startX(app, …)`. Content that must not mirror (paragraph text aligns
   by its own bytes; a QR symbol never flips) stays put — say why in a
   comment, as the QR and radio cases do.
4. Markup in [render/dom/serialize.zig](../../src/render/dom/serialize.zig)
   — the second edition's draw, and the recurring tax
   [renderer-editions.md](renderer-editions.md) named: the switch there
   has no `else`, so this step is a compile error until it is done. Pick
   the tag whose implicit role is already the one `roleOf` gives the
   element, and state the role explicitly only when no tag carries it.
5. A11y mapping in [semantics.zig](../../src/a11y/semantics.zig), and its
   row in the table in [accessibility.md](../accessibility.md). A new
   `A11yRole` **appends** — the enum's ordinals are a wire contract that
   `accesskit.flatten` sends straight to the shim, and the C header
   (the `NOKRE_A11Y_ROLE_*` enum in
   [nokre_accesskit.h](../../shim/nokre_accesskit.h))
   plus the Android and iOS tables mirror it position by
   position (the DOM edition takes no copy — it derives its roles in
   Zig from `roleOf`). Inserting or reordering silently renames every role after
   it; a comptime check in semantics.zig pins the boundary.
6. Construction rules in [tree.zig](../../src/core/tree.zig)
   (`validateAppend`) for structure that must never exist, audit rules in
   [audit.zig](../../src/testing/audit.zig) for content and mutable
   state.
7. Event handling in [input.zig](../../src/core/input.zig) if interactive
   (activation, keys; [editing.zig](../../src/core/editing.zig) if it
   edits text).
8. Unit tests for each of the above (in the module's sibling
   `*_test.zig`), a kitchen-sink entry, a golden, and the element's row
   of the renderer contract in
   [render/dom/serialize_test.zig](../../src/render/dom/serialize_test.zig)
   — what the second edition must convey, which a pixel golden cannot
   check for it.
9. Its section in [elements.md](../elements.md) — semantics first, then
   the visual spec, then when to reach for it over its neighbors.

## Writing a service

Consumer-facing roster and philosophy: [services.md](../services.md).
The authoring rules that keep the shell/service split honest:

- **One header per service.** No shared "misc" surface. A service that
  needs another service composes on the Zig side, never natively.
- **No third-party dependency, with one argued exception.** nokre has no
  dependency manager, so a vendored SDK would mean inventing one — which
  is why `oauth` takes the browser flow over two vendor SDKs and names
  Custom Tabs' extras by their string constants rather than linking
  androidx. The exception is `iap` on Android: Google removed the AIDL
  interface that was once a protocol and requires the Play Billing
  Library, so there is nothing to reimplement. It is handled by moving
  the cost into the open rather than hiding it — the service's Java half
  lives outside the shell's source set
  ([src/services/iap/java](../../src/services/iap/java)), and a consumer
  who links the service adds the source directory and the coordinate to
  their own `build.gradle`. Any future proposal to take a dependency
  meets this bar: no protocol to speak, the cost stated in the consumer's
  own build file, and the shell unchanged.
- **Native side holds no state.** Same as shells: callbacks carry a
  `ctx`, Zig owns everything.
- **Callbacks arrive on the main thread**, interleaved with shell events.
  A service that does async work (OAuth, IAP) delivers results as
  callbacks, never blocks.
- **Optional means optional**, in one of two shapes. A service that
  links something (secure_store's Keychain, deep_link's URL
  registration) gates on its `nokre_*_options.linked` and is a curated
  comptime error at the call site when unlinked. A service that links
  *nothing* — clipboard, locale, open_url — has no unlinked state to error on, so
  it gets no options module and no build flag: adding one would be
  ceremony over a decision the app never makes. For those, "optional"
  means costing nothing where the platform has no hook (a comptime
  `has_shell_hook` switch, so stub targets never name the extern) and
  having an honest answer where it does — the empty value, never an
  invented one. Either way core and the shells never depend on a
  service, and the kitchen-sink example runs with zero services linked
  and must keep running that way.
- **Web parity is part of the contract.** Each service defines its web
  behavior up front: a services.js implementation, an explicit "absent on
  web" (IAP), or an explicit weaker posture (secure storage → browser
  storage).
- **Injected, never installed.** A new service is a field on
  `Services` ([services.zig](../../src/services/services.zig)):
  define `Service = if (builtin.is_test) Mock else PlatformService`
  (`services.Stateless` where the release half holds nothing, as
  clipboard, haptic and secure_store do — writing your own `init`/
  `deinit` pair is then how a service says it *does* keep state),
  give the mock a `mock(config)` constructor plus `init(gpa)`/`deinit`
  that own its heap state, and wire both into `Services.init`/`deinit`
  — the state lives on the App, applied before `build` runs. The mock
  is nokre's canonical fake: it journals what the app did (the
  clipboard's `copies()`, the store's `journal()`) and takes seeds,
  handlers, and knobs from its config — consumers configure it, they
  never implement transport semantics. Harness integration follows
  (an assertion or settle verb, an `InitOptions` mapping if the config
  is boot state). A module-global `var` is a bug — the design rule in
  [architecture.md](architecture.md). Finally, state the service's
  packaging footprint in
  [packaging.zig](../../src/packaging/packaging.zig) — what manifest
  entries, permissions, or entitlements linking it implies per platform.
  "Emits nothing" is stated in a comment on `Services`, never implied by
  silence, and the manifest goldens
  ([packaging_test.zig](../../src/packaging/packaging_test.zig)) must
  show the derivation as a reviewable diff of the actual artifact.

Any proposal to add intelligence to a shell gets redirected to a service;
any proposal to add rendering or input to a service is rejected the same
way. The shell's complete job description is in
[platform-shells.md](platform-shells.md).

## What nokre tests for itself

- Pure unit tests across core/render/a11y/testing (`zig build test`),
  including construction-time rejection of malformed structure.
- Design-system proofs: palette contrast and minimum target size are
  asserted in unit tests — a palette byte or metric that breaks WCAG
  compliance fails the build ([accessibility.md](../accessibility.md)).
- Harness self-tests: keyboard-only form fill, IME composition, tap
  actionability failures, query diagnostics, inline tree snapshots — the
  framework is exercised as a consumer would use it.
- Golden coverage of every element, focus/caret rendering, scroll offset,
  and 2× integer scaling. nokre's own goldens live in
  [tests/goldens](../../tests/goldens) and run with
  `zig build test -Dskia -Dgolden`.
- `zig build check-targets` compile-checks six targets: macOS, iOS,
  Windows, Linux, Android (`aarch64-linux-android`), and
  `wasm32-freestanding`.

Goldens are byte-exact and must stay byte-identical unless a change is
intentionally visual — then regenerate, eyeball the image, and commit it
with the change ([testing.md](../testing.md) has the workflow; CI never
creates goldens).
