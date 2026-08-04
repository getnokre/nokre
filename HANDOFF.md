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

1. **The navigation error surface.** `router.resolve` answers
   `UnknownRoute` / `RouteArgCharset` / `RouteArgCount` /
   `RouteRefTooLong` — all programmer errors, none actionable at the
   call site — and `rebuild` adds the screen builder's own error on
   top. The consumer's verdict is 87 `catch {}` navigation sites:
   every mistyped route reference is a silent no-op in production.
   Route-reference validity against the route table is decidable at
   `Router.init`; a redesign would leave allocation as the only
   runtime error and surface a bad ref as a diagnostic, not an error
   nobody has ever handled.

2. **A payload-carrying `Action`.** `Action` carries no data, so a
   list row's identity must be baked into a generated function: the
   apps hold 21 comptime handler tables (`[max]*const fn` filled by an
   inline loop), two of them byte-identical copies of a `handlerTable`
   helper. Worse than the ceremony: the baked index outlives the row
   list, and the apps disagree about who bounds-checks a stale press —
   some screens guard, some hand the raw index to the controller. An
   index-carrying call (`fn (ctx, index)`) deletes the tables and makes
   the staleness question answerable once.

3. **Sheets as declared builders.** A sheet is a tree node, so every
   controller with a modal carries
   `render_sheet: *const fn (…) anyerror!void = undefined`, assigned
   in one wiring function and invoked at 29 `catch {}` sites. The
   `= undefined` default is the sharpest footgun the survey found: a
   controller added without its wiring line compiles, passes every
   test that never opens its sheet, and calls a garbage pointer the
   first time a user does. Giving sheets a declared builder in
   `RouteDef`'s shape (a fn the framework calls on present and on
   state change) turns the pointer into data nokre owns.

4. **Reload safety, and focus across reload.** `router.reload` starts
   focus over by design — and both apps carry byte-identical modules
   to cope: `reloads.zig` (25 lines re-deriving "is a reload safe
   right now" from `focusScope`, the focused node's role, and a
   text-input switch) and `sheets.zig` (48 lines that copy the focused
   element's *label*, reload, then walk the tree comparing labels to
   re-focus — correct only because the a11y audit forbids duplicate
   labels). Both are questions nokre should answer: a
   reload-safety predicate, and a reload that can carry focus.

5. **A route-reference builder.** `router.arg_separator` exists and is
   referenced zero times: the `~` is hardcoded in ~20 consumer format
   strings over four different ad-hoc buffer sizes, with overflow
   landing as a dead tile in controllers and a failed screen in
   builders. `Router.ref(buf, name, args)` — separator, charset and
   arity validated inside — removes the literal, the size guesses, and
   the split failure behaviour in one move.

6. **`App.Chrome` without silent English.** All 17 chrome strings
   default to English literals, so a mapping a consumer forgets
   compiles and ships English — the audit cannot object to a valid
   label in the wrong language, and the survey caught the two apps
   already drifted on one key. The trade is real (defaults are why a
   hello-world needs no catalogue); the options are a no-default
   `Chrome` for l10n'd apps or a comptime-checked catalogue hand-off.

7. **The chosen locale, and route titles.** nokre owns the *device*
   locale but not the app's *chosen* one, so the apps fan the choice
   out by hand (17 controller assignments in one app, 12 in the other
   — forget one line and that screen stays in the old language
   forever) and maintain a positional parallel array of title
   functions re-stamped onto `RouteDef.title` on every locale change.
   The app already holds `Chrome` and direction; holding the chosen
   locale, and letting `RouteDef.title` be a function of it, deletes
   both fan-outs.

8. **Worker queueing.** A worker handle answers a second ask with
   `error.Interrupted`, so a mutation can fail because an unrelated
   solve happened to be in flight. Both apps carry a byte-identical
   220-line `QueuedPowSolver` (and a sibling for corpus reads) that
   exists only to turn "refuses" into "queues". Either the handle
   grows a small FIFO or the refusal is documented as a guarantee with
   the queue as the blessed consumer pattern — today it is neither.

9. **A recording headless shell.** A consumer building a headless
   native binary (system tests, e2e drivers) hand-declares nokre ABI
   symbols — 21 extern declarations across 4 files in the consumer,
   with exact `callconv(.c)` signatures. A rename here is at best a
   link error there. nokre should ship the null/recording shell it is
   forcing every consumer to write.

10. **`expectGolden` on the harness.** Taking a golden from consumer
    code is a five-step incantation (set the module-global
    `testing.golden.update`, build a Skia surface at the viewport,
    swap the measurer, render, unpack four accessors into
    `expectMatches`) — both apps carry the same 19-line wrapper. One
    harness verb, and the module-global update flag can become an
    argument.

11. **`Tree.append` returns a `NodeId` 986 of 1123 consumer calls
    discard.** A `void`-returning sibling (or flipping which form
    gets the short name) deletes a thousand `_ = try` prefixes and
    the reflex of discarding a value.

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
- **File splits, pure moves:** `layout.zig`'s line-breaking tail
  (~420 lines, no `Tree`/`Ctx` references) → `core/wrap.zig`;
  `input.zig`'s scroll block (~220 lines) → `core/scrolling.zig`
  matching the editing/overlays/nav split; `app_test.zig` (4288
  lines) split along its own section headers, giving `input.zig` and
  `router.zig` the sibling `_test.zig` files the convention promises.
  `serialize.node`'s largest arms (button 72 lines, tile 42) extracted
  to named emitters like the file's existing four.
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
