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

One hard sequencing constraint: the test-identity migration (item 1)
lands **before or alongside** the chosen-locale work (item 2), because
hardcoded-label lookups get strictly more fragile once labels can
change language at runtime.

## Execution order

### 1. Test identity — refusal affirmed, migrate the consumer

**Decided: the refusal stands.** nokre's query surface stays label and
role+name only; no stable key will be added. The work is entirely on
the consumer side: its ~1,634 control lookups by hardcoded English
label (re-count) migrate to role+name per the consumer's own written
rule, and its tests pin a locale explicitly so name-based lookups stay
deterministic when item 2 makes the chosen locale switchable. This was
the survey's largest single coupling; it is now a migration, not a
question.

### 2. The chosen locale, and route titles

nokre owns the *device* locale but not the app's *chosen* one, so the
apps fan the choice out by hand (17 controller assignments in one app,
12 in the other — forget one line and that screen stays in the old
language forever) and maintain a positional parallel array of title
functions re-stamped onto `RouteDef.title` on every locale change. The
app already holds `Chrome` and direction; holding the chosen locale,
and letting `RouteDef.title` be a function of it, deletes both
fan-outs. No design fork here — the sketch is the plan.

### 3. `App.Chrome` without silent English

**Decided: comptime-checked catalogue, opt-in.** The English defaults
stay for the zero-config hello-world case. An app that opts into
localization hands over a catalogue, and the hand-off is
comptime-checked: all 17 chrome strings (re-count) covered or it does
not compile. Missing coverage becomes a compile error, not a runtime
drift — the failure mode the survey caught (the two apps already
disagreed on one key) becomes unrepresentable for any app that has
opted in.

### 4. Worker queueing

**Decided: the handle grows a small bounded FIFO.** A second ask
queues instead of answering `error.Interrupted`; a mutation can no
longer fail because an unrelated solve happened to be in flight. Both
apps' byte-identical 220-line `QueuedPowSolver` (and the corpus-read
sibling) are deleted in the same pass. The deciding evidence: a
refusal that every consumer papers over with the same code was not
buying determinism, it was exporting complexity. Document the queue's
bound and overflow behavior as the contract.

### 5. `expectGolden` on the harness

Taking a golden from consumer code is a five-step incantation (set the
module-global `testing.golden.update`, build a Skia surface at the
viewport, swap the measurer, render, unpack four accessors into
`expectMatches`) — both apps carry the same 19-line wrapper. One
harness verb, and the module-global update flag becomes an argument.

### 6. A recording headless shell

A consumer building a headless native binary (system tests, e2e
drivers) hand-declares nokre ABI symbols — 21 extern declarations
across 4 files in the consumer, with exact `callconv(.c)` signatures.
A rename here is at best a link error there. nokre ships the
null/recording shell it is currently forcing every consumer to write.

### 7. Vendoring

**Decided: revision constant plus published manifest.** A `revision`
constant in nokre source that consumers assert (replacing the prose
pin in two markdown files that already disagreed when surveyed), and
the web site's file list published as data — emitted by the build the
way `zig build pkg` already emits manifests — so the consumer's CLI
reads it instead of re-typing it with a comment admitting it is
nokre's contract. Hand-bumped constant, no CI; the no-CI stance is not
in question.

## Structural, nokre-internal

One session each, any order, interleaved with the list above wherever
they don't collide. No consumer API changes except where noted.

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
- **Two C copies of "open a URL" per desktop.** **Decided: dedupe.**
  One launcher per platform, owned by the shell; oauth's loopback leg
  names the shell symbol. The coupling is deliberate and
  owner-approved — document it as such where the symbol lives, so the
  next reader doesn't "fix" it back into two copies.
- **One `services.Failure`.** http, oauth and iap each declare the
  identical `struct { name: []const u8 }`; a consumer's shared
  failure-surface helper cannot take one type. Unifying changes
  published type identity — still an owner call to confirm at that
  session's start, not yet decided.
- **`render.dom` has one word for two things.** `dom.Options` is the
  serializer's options, `dom.stylesheet.Options` the CSS options, and
  the live driver bypasses `dom.zig` to import the serializer
  directly. Rename one, or make the re-export the only path.

## Shipped from this list (2026-08-04, for the record)

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
