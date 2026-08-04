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
this writing; re-count before acting, the apps move.

## Contract redesigns, ranked by measured consumer cost

(The list's original #1, the navigation error surface, shipped
2026-08-04: a bad reference is now a recorded refusal the audit fails
tests over — `Router.refused`, `vet`, the `unresolvable_route` rule —
and docs/routing.md "Errors, and refusals" is the contract's home.)

(The original #2, sheets as declared builders, shipped 2026-08-04 as
well — anchored on the App rather than `RouteDef`, because the survey
showed sheets are not route-shaped in either direction. `App.openSheet`
takes a `SheetBuilder` (ctx, build fn, optional `on_dismiss`); the
framework keeps it as data, re-runs it after `reload`, drops it — with
notice — on navigation and every dismissal, and takes a failed build
down whole. The `= undefined` pointer, all 13 of it, and both apps'
wiring lines are deleted; docs/elements.md "sheet" is the contract's
home.)

(The payload-carrying `Action` shipped 2026-08-04. Additive, so no
existing literal moved: `Action` and `ToggleAction` each grew an
`index` plus a `call_indexed` that receives it at dispatch — the row is
data on the element, exactly as fresh as the tree, the same shape
`PickerItem.index` already had. Both calls set is refused at append
(`ActionHasOneCall`), the index is part of an action's fold identity,
and the staleness question got its one answer — the receiver
bounds-checks, docs/elements.md "Actions" is the home. The re-count
before acting was right to demand: the survey's 21 tables were 30 plus
a one-off by ship time — all three `handlerTable` copies byte-identical,
not two — some 950 generated functions, all deleted from both apps;
the one genuinely unguarded stale press, read's `toggleEntry`, now
guards like its siblings.)

(The previous #1, reload safety and focus across reload, shipped
2026-08-04. `App.reloadSafe` is the predicate — false while an overlay
owns the screen or an editable holds focus — and `reload` alone now
carries focus: by node identity when the node survived (chrome), else
by accessible name within the active layer, leaning on the same
duplicate-label refusal the consumers' walk did; link-span stops and
over-long labels start over rather than guess. `reload` itself never
asks the predicate — deliberate gestures must land mid-edit — so the
check stays at the consumer's unprompted-reply sites. Both apps'
`reloads.zig` and `sheets.zig` are deleted; docs/routing.md owns the
contract.)

1. **`App.Chrome` without silent English.** All 17 chrome strings
   default to English literals, so a mapping a consumer forgets
   compiles and ships English — the audit cannot object to a valid
   label in the wrong language, and the survey caught the two apps
   already drifted on one key. The trade is real (defaults are why a
   hello-world needs no catalogue); the options are a no-default
   `Chrome` for l10n'd apps or a comptime-checked catalogue hand-off.

2. **The chosen locale, and route titles.** nokre owns the *device*
   locale but not the app's *chosen* one, so the apps fan the choice
   out by hand (17 controller assignments in one app, 12 in the other
   — forget one line and that screen stays in the old language
   forever) and maintain a positional parallel array of title
   functions re-stamped onto `RouteDef.title` on every locale change.
   The app already holds `Chrome` and direction; holding the chosen
   locale, and letting `RouteDef.title` be a function of it, deletes
   both fan-outs.

3. **Worker queueing.** A worker handle answers a second ask with
   `error.Interrupted`, so a mutation can fail because an unrelated
   solve happened to be in flight. Both apps carry a byte-identical
   220-line `QueuedPowSolver` (and a sibling for corpus reads) that
   exists only to turn "refuses" into "queues". Either the handle
   grows a small FIFO or the refusal is documented as a guarantee with
   the queue as the blessed consumer pattern — today it is neither.

4. **A recording headless shell.** A consumer building a headless
   native binary (system tests, e2e drivers) hand-declares nokre ABI
   symbols — 21 extern declarations across 4 files in the consumer,
   with exact `callconv(.c)` signatures. A rename here is at best a
   link error there. nokre should ship the null/recording shell it is
   forcing every consumer to write.

5. **`expectGolden` on the harness.** Taking a golden from consumer
    code is a five-step incantation (set the module-global
    `testing.golden.update`, build a Skia surface at the viewport,
    swap the measurer, render, unpack four accessors into
    `expectMatches`) — both apps carry the same 19-line wrapper. One
    harness verb, and the module-global update flag can become an
    argument.

## Structural, nokre-internal

- **`Button`'s form as a tagged union.** `secondary`, `icon`,
  `icon_only`, `provider` interact under five `validateAppend` rules —
  five illegal states the type permits and checks at runtime. A
  `form: union(enum) { filled, secondary, glyph, provider }` makes
  them unrepresentable. Touches every consumer call site and the
  goldens; the largest single runtime-check-that-could-be-comptime
  left in the public surface.
- **The four desktop platform shells are one file.** macOS, Windows,
  Linux, iOS differ only in adapter type, one attach argument, and
  which of them call `workersViewReady` — invisible asymmetries unless
  all four are diffed. A `Runner(comptime Adapter)` in `c_shell.zig`
  drops each to ~12 lines.
- **Two C copies of "open a URL" per desktop.** The desktop shells
  transcribe oauth's `windows.c`/`linux.c` launchers (their comments
  say so). Deduping means oauth's loopback leg names the shell symbol
  — a deliberate coupling that needs an owner's yes, which is why it
  was not taken mechanically.
- **One `services.Failure`.** http, oauth and iap each declare the
  identical `struct { name: []const u8 }`; a consumer's shared
  failure-surface helper cannot take one type. Unifying changes
  published type identity, so it is a call, not a patch.
- **`render.dom` has one word for two things.** `dom.Options` is the
  serializer's options, `dom.stylesheet.Options` the CSS options, and
  the live driver bypasses `dom.zig` to import the serializer
  directly. Rename one, or make the re-export the only path.

## Decisions, not patches

- **Stable test identity.** The consumer holds 1,634 control lookups
  by hardcoded English label, against its own written rule to locate
  by semantic identity — because nokre's query surface deliberately
  offers label and role+name only. Either the refusal is affirmed and
  the consumer's rule changes, or nokre grows a stable key. The
  survey's largest single coupling; it should be decided, not
  inherited.
- **Vendoring.** The consumer reaches nokre by bare relative path; the
  only revision pin is prose in two markdown files (already
  disagreeing when surveyed), and the consumer's CLI re-types the web
  site's file list with a comment admitting it is nokre's contract. A
  revision constant consumers can assert, and the site manifest
  published as data, close both — at the cost of build-time machinery
  nokre has so far refused. The no-CI stance is not in question.
