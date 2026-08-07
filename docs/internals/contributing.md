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
  Keep that voice; don't add narration. The checklist for keeping one true
  is [below](#comments).
- Integer math in layout, geometry, and anything that produces
  coordinates or bytes. The one sanctioned float user is the contrast
  check in [color.zig](../../src/core/color.zig) — deterministic
  IEEE-754, a construction-time gate that never positions a pixel. No
  clocks, no randomness — anything nondeterministic breaks the
  [pixel model](pixel-model.md). Both carve-outs live in services and
  nowhere else (`oauth`'s CSPRNG, `clock`'s wall time), for the reason
  stated at each: a service is not core, and neither one may be reached
  from `src/core` or `src/render`.

## Comments

A comment earns its place by carrying what the code cannot: a constraint, an
invariant, a rejected alternative, a contract a signature does not spell. That
much is the voice, and it is already the house style. What this codebase
actually accumulates is not narration — it is comments that were true once.
Treat a comment as code: it is reviewed and updated with the behavior it
describes, in the same change, and a comment touched by a change gets read even
when the change is not about comments.

Before leaving a comment in place, check it against each of these. Every one
has caught a live defect here.

- **It sits on what it describes.** A doc block runs to the *next* declaration,
  so a missing blank line silently reassigns it — a contract reading "returns
  the field" can end up on a `const`, leaving the function it belonged to
  undocumented. When two declarations sit close together, check which one the
  compiler thinks the doc is on.
- **Its references resolve.** Symbols get renamed and `docs/` pages get
  rewritten. Never quote another document verbatim: restate the fact and cite
  the page, so a rewrite there cannot leave a lie here. Point at symbols by the
  name they have today.
- **Its checkable claims still check.** Counts, widths, ordinals, "N of them",
  "four lines up". If a test proves otherwise, the test wins and the comment is
  wrong — fix the words, and do not touch a fixture to make a sentence true.
- **It states the library's fact, not a consumer's.** A downstream site's page
  count or route names in a library comment will rot on someone else's schedule.
- **It has one home.** Each fact lives in one place and is pointed at from the
  others; a second copy is a future contradiction, and the two will not drift
  together. Where a `docs/` page, a sibling module, or the declaration above
  already owns the fact, reference it instead of restating it.

Delete on sight: dead plan labels from a finished round ("Part E", "B3"),
tombstones for symbols that no longer exist, and a section heading with no
section under it. A `// ---- label ----` divider over a real API surface in a
long module is not ceremony — keep it, and keep any docs anchor it carries.

Comment count is not a metric in either direction. Do not thin rationale to
make a file look lean, and do not add a line that the names and types already
say.

## Adding an element

The element set is closed on purpose; additions are argued on semantics,
never styling ([introduction.md](../introduction.md) has the argument).
If a proposed element can't state its semantics in one sentence, it
doesn't go in. When one does, it is a cross-cutting commitment:

1. Struct + `Element` union arm + `Role` in
   [element.zig](../../src/core/element.zig)
   (`role()`, `isInteractive()`, `isFocusable()`, `label()`,
   `needsRuntime()` — that last one decides whether a page holding the
   element can be published as a file with nothing running behind it,
   and its switch is exhaustive so the answer cannot be skipped; it
   switches on the *element*, so where a field of yours decides whether
   the thing navigates or acts, read that field the way `tile` reads
   `route` rather than answering for the kind), and its
   cursor method in [cursor.zig](../../src/core/cursor.zig) in the same
   pass — the builder is closed exactly as the element set is, and the
   comptime check there refuses to compile a union member the cursor
   cannot spell. No `...Id` twin: those four exist for the leaves real
   screens patch mid-flight, and a new one earns its twin from a call
   site, not from symmetry.
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
- **A service may name the shell; the shell may never name the service.**
  A shell links into every app and an optional service's native leg links
  into some, so a shell that calls a service's C function is a link error
  in every app that does not link that service — which is most of them,
  and which no compile-only check can see. Where the OS hands something
  to the shell that only a service can interpret, the shell defines the
  entry and the service installs itself into it: a function pointer
  (notification's Apple push-token sink) or a dispatch the service
  implements (`nokre_notification_dispatch`, `nokre_oauth_dispatch` on
  Android). `__attribute__((weak_import))` is not a substitute — zig's
  MachO linker rejects an undefined weak symbol no input defines, so the
  null check such a shell writes is never reached.
- **Callbacks arrive on the main thread**, interleaved with shell events.
  A service that does async work (OAuth, IAP) delivers results as
  callbacks, never blocks.
- **Optional means optional**, in one of two shapes. A service that
  links something (secure_store's Keychain, deep_link's URL
  registration) gates on its `nokre_*_options.linked` and is a curated
  comptime error at the call site when unlinked. A service that links
  *nothing* — clipboard, clock, haptic, http, locale, open_url, share,
  worker — has no unlinked state to error on, so
  it gets no options module and no build flag: adding one would be
  ceremony over a decision the app never makes. For those, "optional"
  means costing nothing where the platform has no hook (a comptime
  `has_shell_hook` switch, so stub targets never name the extern) and
  having an honest answer where it does — the empty value, never an
  invented one (share's honest answer is `available` false, because a
  missing share sheet is a fact the app draws around, not an empty
  value it can render). Either way core and the shells never depend on a
  service, and the kitchen-sink example runs with zero services linked
  and must keep running that way.
- **A permission a user answers is never derived silently.** Every
  permission nokre derived before `notification` was normal and
  install-time — invisible at runtime, so the emitter could add it
  without saying so anywhere a consumer reads
  ([packaging.zig](../../src/packaging/packaging.zig)'s BILLING row
  states that rule). A *dangerous* permission is not that: it is
  prompted, refusable and revocable, and it changes what the app's users
  see. A service that derives one states it in its consumer section, and
  models the answer as a tri-state — not-determined, granted, denied —
  because collapsing the first two makes "ask again" the app's most
  tempting bug (`notification`'s `Status`).
- **Web parity is part of the contract.** Each service defines its web
  behavior up front: a services.js implementation, an explicit "absent on
  web" (IAP), or an explicit weaker posture (secure storage → browser
  storage).
- **Injected, never installed.** A new service is a field on
  `Services` ([services.zig](../../src/services/services.zig)):
  define `Service = if (builtin.is_test) Mock else PlatformService`
  (`services.Stateless` where the release half holds nothing, as
  clipboard, clock, haptic and open_url do — writing your own `init`/
  `deinit` pair is then how a service says it *does* keep state, which
  is secure_store's shape: its release half carries the `CountCache`),
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
  `wasm32-freestanding` — and *links* the last of them. Compiling is not
  linking: an object never resolves a symbol, so a declaration with no
  definition passes this step silently, which is how an Apple shell
  naming a symbol only the notification service defines reached a
  consumer's build. The web is the one target a link can be attempted on
  from any host (no Skia, no AccessKit, no SDK, no C shell), so it is
  linked here with every service it has a leg for. The other five are
  covered by the desktop link below.
- **A real parse of the shipped JavaScript**, in `zig build test`. Four
  files in [src/render/dom](../../src/render/dom) ride into every
  consumer's site verbatim and a fifth (`boot.js`) is emitted by
  [packaging.zig](../../src/packaging/packaging.zig); Zig only copies
  them, so the first thing that reads them is a browser, and a browser
  answers a syntax error by refusing to boot the app at all. Each is
  parsed by node in the goal it is loaded with — module for the three
  the driver imports, classic script for `sw.js`. Two notes, both
  load-bearing: `node --check` on a bare `.js` exits *zero* on a file
  that parses as neither CommonJS nor ESM, so the check copies each file
  under `.mjs`/`.cjs` first; and node missing from PATH **fails** the
  build rather than skipping, because a gate that stands aside quietly
  reports a green nobody can interpret. `-Djs-parse=false` is the way to
  decline it out loud.
- **One transport on a real socket**, in `zig build test`:
  [native_test.zig](../../src/services/http/native_test.zig) binds a
  loopback origin in the test process and puts all six verbs through
  the native http transport, asserting the bytes that go out. Every
  other service is proven against its mock, and a mock answers whatever
  it is asked — which is how a send path that `std.http.Client` asserts
  on shipped choosing itself by the body's length, panicking every
  bodiless POST. Where a service's real leg is pure Zig over a socket,
  a fake is not enough; the threads around it are the next tier's, not
  this one's, because a gate cannot wait out a 30-second watchdog.
- **The desktop link**, in `zig build test -Dskia`: the examples are
  built, not just installed. hello links the services that need an
  identity and the kitchen sink links none at all — the shape every app
  starts in, and the shape an undefined symbol in an always-linked shell
  breaks first.
- **One service's verbs outside `zig test`**, in `zig build test` on a
  macOS or desktop-Linux host:
  [tests/dev_store.zig](../../tests/dev_store.zig) is built as an
  *executable* and run. Under `zig test` a service *is* its mock, so no
  unit test anywhere reaches secure_store's release dispatch, its
  `CountCache`, or a store the OS answers — the boundary
  [testing.md](../testing.md) names. This program constructs a real
  `App`, drives its screens through `testing.driver`, and puts all four
  verbs through the dev file store (`.secure_store_dev`,
  [secure_store.md](secure_store.md)), asserting a boot read, a write
  that outlives the app that made it, and a delete. It does not make
  macos.m or windows.c any more executed than they were; it makes the
  Zig above them so, which was previously proven by nothing.

- **That transport's threads**, in `zig build test` on a native desktop
  host: [tests/http_stress.zig](../../tests/http_stress.zig) is built as
  an *executable* and run. Two `App`s in one process put 1920 requests
  through the real transport at a loopback origin listening on both
  families, so nokre's delivery pump, its detached transfer and watchdog
  threads, and std's connect machinery run together — the one
  arrangement in which the transport's concurrency is the subject rather
  than the setting. It is sized by measurement, not by taste, because
  what it holds off is a race: restore the async pool it refuses
  ([http.md](http.md#no-pool-under-the-native-transport)) and this load
  crashes the process on 20 runs out of 20. Failures the *machine*
  produces — no thread to spawn, no ephemeral port left — are counted
  and reported, never failed on; a resource limit is not a defect.
- **The three web-only service legs, executed**, in `zig build test`:
  [tests/web_services.zig](../../tests/web_services.zig) is an ordinary
  nokre app with deep_link, oauth and secure_store linked, built into a
  site by the same `addApp` path a consumer takes, and booted by node
  against [tests/web_browser.mjs](../../tests/web_browser.mjs). What
  the stub carries, what the site's own modules prove, and what the
  gate still does not cover is [testing.md](../testing.md)'s "The web's
  own gate". The design rule is that every assertion reads back what
  the wasm app recorded through probe exports: a harness that restated
  a line of the driver would prove that line twice and the real one
  never. Those three legs exist on no other platform, so `zig test`
  reaches none of them and `check-targets` compiles them into objects
  it never runs — the fragment that arrives, the popup that reports to
  its opener, and the seed that beats the first `build` were, until
  this gate, asserted by nothing. It rides `-Djs-parse`, because that
  is one question asked once — node, and the shipped JavaScript really
  read.

Goldens are byte-exact and must stay byte-identical unless a change is
intentionally visual — then regenerate, eyeball the image, and commit it
with the change ([testing.md](../testing.md) has the workflow; CI never
creates goldens).
