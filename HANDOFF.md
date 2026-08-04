# Handoff — deferred work

State as of the 2026-08-04 tidy pass. That pass took everything
mechanical: one home per shared fact, comptime pins on every wire
ordinal, exhaustive switches where an `else` was silently absorbing new
elements, and the small contract renames (mirrored into the consumer in
the same breath). What is written down here is what the pass
deliberately did **not** take: each item is an API redesign or a
structural move that deserves its own pass, with the consumer updated
alongside. Nothing here is in flight.

The evidence throughout is a survey of nokre's one real consumer — the
two rokovski apps (`packages/feedback_fe_user_nokre`,
`packages/feedback_fe_org_nokre`). The counts are that survey's, as of
this writing; re-count before acting, the apps move. (The append-flip
pass already caught the survey's blind spot once: the site generator,
`getnokre.github.io/src/content.zig`, is a third consumer — check it
too.)

## How to execute this file

Every open question below was decided by the owner on 2026-08-04; what
remains is execution. The cadence, unchanged from the earlier passes:
**one item per session**, and each item lands whole — the nokre change,
both rokovski apps (and the site generator where it is touched)
migrated in the same pass, `zig fmt src/`, `zig build test` green on
both sides (`-Dskia -Dgolden` when anything visual moved, goldens
byte-identical unless the change is intentionally visual), e2e where
the apps have it, site rebuilt last per the publish order. Stop for
owner review before the next item — never chain.

The one hard sequencing constraint this file carried — test identity
before the chosen locale — was discharged when the test-identity
migration shipped (2026-08-04, below): the consumer's lookups are
role+name and its fixtures pin `en`, so the chosen-locale work was
free to move labels at runtime — and did, the same day (below).

## Structural, nokre-internal

Nothing remains. The execution-order list and the structural list are
both done; everything below is the record.

## Shipped from this list (2026-08-04, for the record)

- `render.dom` says Options once: the serializer's options moved to
  where they are consumed — `dom.Emitter.Options`, beside
  `dom.stylesheet.Options`, each scoped to the thing it configures —
  and the flattened `dom.Options` re-export is deleted. The live
  driver's bypass import went with it: both drivers name the walk
  through `dom.zig`, so what the edition exports and what its own
  drivers use cannot drift (the sibling `serialize_test.zig` keeps its
  direct imports, the sibling-test convention's way, and dom.zig says
  so). A published name moved, so `nokre.revision` bumped to 5 and all
  three pins with it — the survey found neither app touches
  `render.dom` and the site generator builds its Emitter options as
  anonymous literals, so the pin is the whole consumer migration.
  Tests, goldens (byte-identical), and check-targets green on all
  three builds; site rebuilt against the clean commit.
  docs/internals/dom-edition.md keeps the edition's facts (nokre
  `c3c5f40`, rokovski `eff2608d`, site `f7b7d7b`).

- One `services.Failure`, owner-confirmed at the session's start: the
  three structurally identical `struct { name }` declarations http,
  oauth, and iap carried are one type, declared in `services.zig`
  beside `Stateless` and `Journal` and re-exported by each service as
  its own `Failure` with its own name roster — so per-service code
  reads unchanged, `nokre.services.Failure` is the consumer's one
  name, and a shared failure surface takes one type. A comptime
  identity proof pins it in `services_test.zig`. The survey found both
  apps consume the payloads structurally (`|failure|`, `failure.name`)
  and the site generator never touches them, so the consumer migration
  is the pin alone. Published type identity moved: `nokre.revision`
  bumped to 4, all three pins with it. Tests, goldens (byte-identical),
  and check-targets green on all three builds. docs/services.md "One
  failure shape" is the home (nokre `80f5598`, rokovski `b366b539`,
  site `9e70e05`).
- One URL launcher per desktop, owned by the shell: the second
  ShellExecuteW / double-fork xdg-open each desktop carried under
  `src/services/oauth` is deleted (windows.c, linux.c, and oauth.h's
  `nokre_oauth_open_url` with them), and oauth's loopback leg names the
  shell's own `nokre_open_url_open` — which now returns the honest "did
  the handoff start" bit that leg's `BrowserUnavailable` (and its
  blocked listener thread) needs, while the open_url service discards
  the value by its fire-and-forget doctrine. The service→shell coupling
  is deliberate and owner-approved, and open_url.h says so where the
  symbol lives. All six shells and `testing.shell` moved to the
  int-returning signature; shell32 moved onto the Windows shell's own
  lib list, where ShellExecuteW always lived. `nokre.revision` bumped
  to 3 — the site generator authors a shell of its own, so the hook's
  signature is consumer-visible — and all three pins moved. Goldens
  byte-identical on all three builds; check-targets green. open_url.h
  owns the coupling, docs/internals/oauth.md the flow-side record
  (nokre `1a50ac1`, rokovski `4a531865`, site `2807faf`).
- `Button`'s form, as a tagged union: `form: union(enum) { filled,
  secondary, glyph, provider }` replaces the `secondary` / `icon` /
  `icon_only` / `provider` quartet, and the five illegal pairings the
  flags permitted — a glyph form without a glyph or with an emphasis,
  an icon beside the vendor mark, a glyph-only sign-in, an outlined
  Google — are now unspellable rather than refused: the pill forms
  carry their optional lead glyph as the payload, the glyph form's
  glyph *is* the payload, and the vendor styles are spelled per vendor
  (`.apple`, `.apple_outlined`, `.google`), so Apple's sanctioned
  outlined third is a member and Google's unsanctioned one simply is
  not. The vendor-label and progress refusals stay — they cross `form`
  and the fields beside it. Every consumer call site moved (the one
  computed emphasis, the credits sheet, selects between forms);
  goldens byte-identical on all three builds; `nokre.revision` bumped
  to 2 and all three pins moved with it. docs/elements.md "button"
  owns the contract (nokre `3b858ff`, rokovski `a5f3c6b7`, site
  `5a2a896`).
- The four desktop shells, as one Runner:
  `c_shell.Runner(Adapter, install_frame)` is the whole `run` for the
  four shells whose loop `nokre_shell_run` owns — every formerly
  invisible asymmetry (window-focus forwarding, the post-main worker
  wake, Wayland's `app_id`, macOS's window-class attach argument) now a
  comptime branch derived from the adapter's own surface (`@hasDecl`
  for `detach`/`focusState`, attach's arity for the window class) or
  the platform predicates c_shell already had. Each platform file
  drops to naming its a11y adapter and frame-source installer; the
  frame-source seam survives as the Runner's second parameter, so
  c_shell still names no backend. Android stays its own wiring by
  design — its loop is the Activity's, not `nokre_shell_run`'s. No
  consumer surface moved, revision stays 1, goldens byte-identical,
  both apps and the site generator green untouched.
  docs/internals/platform-shells.md owns the shell-side facts (nokre
  `5bbdae9`).
- Vendoring, as the library's own contract: `nokre.revision` is the
  hand-bumped constant (no CI, deliberately) consumers assert at
  comptime — both apps and the site generator carry the assert in
  their root modules, and a moved checkout fails the build naming both
  numbers — replacing the consumer's prose pins, which had already
  drifted apart (rokovski's HANDOFF.md carried `f7c6c08` and `9a08714`
  at once). And the site's file list is published as data:
  `addWebSite` writes `site.manifest` — one relative path per line,
  sorted, naming the servable content, not itself — so `unf`'s
  `VerifySite` reads the copied site's own list and the CLI's re-typed
  `SiteFiles` is deleted with its comment admitting the list was
  nokre's. The manifest's font lines are read from the same directory
  the copy reads, and the web-services gate holds manifest and site
  directory identical both ways. docs/getting-started.md owns the
  consumer story, docs/internals/dom-edition.md the site-set table
  (nokre `9762b8b`, rokovski `7cadd81b`, site: assert + rebuild).
- The recording headless shell, as the library's own:
  `testing.shell` is every free C hook a driver owes, defined once —
  the deep-link and locale pairs answering as a shell with nothing to
  report (locale fires its callback synchronously with the empty tag,
  its contract's way), and the three hooks where a screen's outcome
  would otherwise vanish — clipboard, share sheet, outbound URL —
  recording last-write-wins into slots read back with
  `lastCopied`/`lastShared`/`lastOpened`. Naming the module
  (`comptime { _ = nokre.testing.shell; }`) is the whole install, and
  a windowed build that names it collides with the real shell at link
  time — the intended guard. The consumer's 21 hand-written exports
  across 4 files deleted (both `e2e/shell.zig` files whole), nokre's
  own three drivers ride the same module, and the site generator keeps
  its own shell deliberately: it truthfully reports `en`, not nothing.
  The pump stays the driver's job by design. docs/testing.md owns the
  driver contract, docs/internals/platform-shells.md the shell-side
  facts (nokre `92ef0ba`, rokovski `d91a3eef`).
- The golden take, as a harness verb: `Harness.expectGolden` is the
  whole five-step incantation — a Skia surface at the app's viewport,
  the real measurer swapped in, one render through the production
  pipeline, the byte-exact compare — and the module-global
  `golden.update` became the assertion's `Options.update` argument,
  threaded from `-Dupdate-goldens` through each consumer's options
  module, so two suites in one process cannot fight over a global.
  Skia is imported inside the verb and nowhere else in the harness, so
  a suite that never takes a golden still links nothing. Both apps'
  19-line `render()` wrappers shrink to the path and the flag, nokre's
  own suite rides the same verb, goldens byte-identical on all three
  builds. docs/testing.md owns the contract, docs/getting-started.md
  the build recipe (nokre `f6ae27e`, rokovski `8f81a7ef`).
- Worker queueing, as the ask surface: `workers.spawnAsker`/`ask`
  answer every question exactly once, in ask order, from a bounded
  FIFO on the slot — `max_pending_asks` (32) counting the one in
  flight, a full queue refusing with `error.TooManyAsks`, `retire`
  draining so every accepted ask is answered. Only the front question
  is ever in the worker's inbox, so `interrupted()` mid-answer means
  retirement and an unrelated ask can no longer make in-flight work
  stale. `h.Queue` is the same FIFO for single-flight ports without a
  worker. Both apps' 220-line `QueuedPowSolver` deleted — the solver
  adapter keeps a lockstep ring of the port's two-word callbacks,
  which the ask-order contract makes state-machine-free — and the
  corpus-read sibling rides `h.Queue`; e2e idle probes read
  `pending()`. docs/services.md owns the consumer contract,
  docs/internals/workers.md the machinery (nokre `6d09a90`, rokovski
  `64acc8e8`).
- The chrome catalogue: `Chrome.Catalog` is `Chrome` field for field
  with the defaults stripped — generated from `Chrome` itself, so the
  two cannot drift — and `Chrome.fromCatalog` is the hand-off. An
  opted-in app that misses a chrome string (16 at this writing, or one
  nokre grows later) stops compiling instead of shipping English
  mid-nav; the bare literal and its English defaults stay for the
  zero-config app. Both apps' `chromeFor` opted in, words unchanged;
  goldens byte-identical on all three builds. docs/localization.md
  owns the wiring (nokre `f9e484c`, rokovski `cdc544da`).
- The chosen locale, and route titles: the App owns the chosen locale
  (`Options.locale` / `setLocale` / `locale()`, a bounded tag copy,
  validated whole before commit) and `RouteDef.title` is a union —
  `.fixed`, or `.of_locale`, a function of the chosen tag —
  so `setRouteTitles`/`retitle` retired with the second table they
  handed over. Both consumer fan-outs deleted: the parallel title
  arrays and every controller's locale copy (17 + 11, plus the user
  app's duplicate wire-time set) became live reads through the App;
  write/read/library keep change hooks for their locale-keyed caches;
  the harness's `initial_route` may now be empty so a fixture wires
  state before the first build, main's order. docs/routing.md owns the
  title contract, docs/localization.md the wiring (nokre `4876c99`,
  rokovski `e1983629`, site `.fixed` one-liner).
- Test identity: the stable-key refusal affirmed; nokre unchanged. The
  consumer's ~1,650 label lookups (both apps' fixtures, tests, and e2e
  drivers) migrated to role+name, `getByLabel` removed from the
  fixture surfaces, fixture locales pinned to `en` ahead of the
  chosen-locale item; absence/focus assertions, notice titles, e2e
  content waits, and inline link spans stay name-based by design
  (rokovski `ae0e47a9`).
- Navigation error surface: bad references are recorded refusals
  (`Router.refused`, `vet`, the `unresolvable_route` audit rule);
  docs/routing.md "Errors, and refusals" is the home.
- Sheets as declared builders, anchored on the App (`App.openSheet` +
  `SheetBuilder`), re-run after `reload`, dropped with notice on
  navigation and dismissal; docs/elements.md "sheet" is the home.
- Payload-carrying `Action`: `index` + `call_indexed`, both-set
  refused at append, index in fold identity, receiver bounds-checks;
  docs/elements.md "Actions" is the home. (~950 generated consumer
  functions deleted.)
- Reload safety and focus across reload: `App.reloadSafe` at the
  consumer's unprompted-reply sites, `reload` carries focus by
  identity then accessible name; docs/routing.md owns the contract.
