# HANDOFF — what is open

Only unfinished work lives here. An item leaves this file when it ships, is
refused, or turns out already solved — the reasoning goes with it, into the
commit that settled it and into whichever doc now owns the fact.

Nothing below has been scoped by an owner decision. Each moves on its own
argument, and none of those arguments has been made yet.

Where a receipt has rotted, the item is still real: check the symbol before
quoting the fact. Counts in this file have been wrong in every round that
measured them.

---

## Performance

Never surveyed properly. Four findings, all verified present at the time they
were written and none since re-checked:

- **`hsk_surface_pixels` (`shim/nokre_skia.cpp`) `readPixels` the whole surface
  into a persistent buffer every frame** — about 15 MB per frame at 1200×800@2× —
  where a CPU raster surface can hand its pixels out directly.
- **The `widths` cache behind `src/render/dom/services.js`'s `measure` is cleared
  only on `loadingdone`**, so a long editing session grows it without bound.
- **The DOM edition ignores `needs_frame`.**
- **`hsk_dither` rebuilds a 2×2 bitmap and a shader per scrim call.**

## Evidence filed, never proposed

Named in the third ergonomics round and left as evidence rather than items:
`Remote(T)` and staleness, the ApiClient `= undefined` wiring and its two-phase
init, number formatting, `.table()`'s absence from the org app, the notification
mock's one-sided journal, and rokovski's own placement debt.

## Residue from the third ergonomics round

Full receipts at `git show 3855adf:HANDOFF.md`.

- **`http.Handle.cancel` is discarded at every call site.** It was an A8 receipt
  but never one of its three menu items, so the decision that closed A8 did not
  reach it. One `.cancel()` exists in the consumer tree.
- **`truncated` reaches no user-facing surface.** The disclosure shipped and the
  migration wired it nowhere, because neither app owns a string that could say
  it — about 30 sites need catalog copy. **Two are not ceilings**: a member's
  fifth permission silently loses the control it grants, and a dropped
  `tags.Library` entry makes a real tag fail `knows()` and vanish. Two unexploded
  caps beside them: `family_cap = 4` against a format that permits `industry`,
  and an exact `id_cap = 8` whose overflow *collides* rather than truncates.
- **`setHandler(app, ctx, fn)` and `Asker.ask(msg, ctx, fn)` take the context and
  the function as two positional arguments**, so no pair exists for `bindAs` to
  fill. The largest remaining `?*anyopaque` surface in nokre's own API — 9 sites
  on the published services page, 4 in the tutorial, 6 live casts in the apps.
- **`overflow.closeTailSheet` is the fourth dismissal door and does not
  rebuild**, so a folded action writes state the screen never shows. The other
  three were fixed; this one's fix is structurally different.
- **`emptyGate` folds "not ready" into "ready and empty"**, so four sites that
  append a hint or a control only in the empty case cannot use it. And `Gate` has
  no bare `raise`, so two paths that legitimately re-raise discard `begin`'s
  answer.
- **Six sites hand-roll `in_progress` as a boolean that must also turn off**,
  which `patchProgress(id, pct)` cannot express. A `patchBusy` was declined as a
  third verb.
- **Two consumer-side defects, both flagged and neither fixed.** Org `Invites`
  serves two routes and resets its notice only on organization change, so a
  failure leaks across navigation and is reported out of context. And org
  `organizations_sheets.zig`'s `render` builds the join-code sheet with
  `.error_copy` but no `.busy`, so its submit has no in-flight representation
  where its sibling does.

## Left open by the comment pass

A repository-wide read of every first-party file (both repos, ~82k lines) fixed
comments that had stopped being true. These are what it found and did not fix,
each deliberately: none is a comment defect, so none belonged in a comment commit.

- **`nav.zig`'s private `clearChildren` re-implements `Tree.clearChildren`**
  (tree.zig:223) with an O(n²) restart-the-iterator loop, and the same inline loop
  is written out again at `overlays.zig:470-474`. `Tree.clearChildren` has no
  non-test caller in `src/core` today. Consolidating touches tree mutation and node
  lifetime, so it wants a golden run, not a reading pass.
- **`overlays.zig:573-576` and `input.zig:414-421` re-seat nav focus differently
  under comments that claim the same intent.** input searches for the `nav_item`
  whose route `isCurrent`; overlays takes `children(nav).next()` unconditionally,
  which is only right while the nav is still collapsed after the push. Neither uses
  `nav.reseatNavFocus`, which exists for this. Whether the divergence is deliberate
  could not be determined.
- **`iap.zig:760-763`** — `MockState.postUpdate` does not clear `buying` when
  `openOneShotOn`/`deliverOneShot` fails, where `PlatformState.postUpdate:512-528`
  does. Possibly deliberate (under `zig test` an allocator failure is a crash by
  house rule), but the asymmetry is undocumented.
- **`shim/nokre_skia.cpp:36, :71`** — the `__EMSCRIPTEN__` arms are dead; nothing
  defines the macro since the web stopped linking Skia. Removing them is a
  preprocessor change on a file three platforms compile.
- **`build.zig:2049-2051`** says `xcrun` runs "up to six times per `zig build`
  (three linked check objects × two Apple SDKs, plus the iOS app path)". The loop
  now creates five linked check objects, but the count is gated on `pkg != null`
  and an Apple `os_tag`, and `store-dev` is macOS/Linux-only, so the intended
  arithmetic is not recoverable by reading. Left rather than guessed.
- **A fourth copy of the "linking needs identity" argument** lives in `addSecureStore`,
  `addDeepLink`, `addOauth`, `addIap` and `addNotification`, with a second full set
  of `addFail` strings for the `b.default_step` path. The `checkXNeedsPkg` layer was
  collapsed; this one was not.
- **`crowded_nav` may be weaker than intended.** Its comment claimed the roster
  clears a row at no viewport width; `layout_test.zig:817-824` proves the row reopens
  at 651. The comment was corrected and the fixture deliberately left alone — every
  test using it runs at 375. If it was *meant* to be uncollapsible at any width it
  needs a fifth destination, which changes what ~15 tests exercise.
- **Three docs facts with more than one home.** `dom-edition.md:698-709` restates the
  lastmod/changefreq argument it explicitly delegates to `sitemap.zig`'s module
  comment; `:717` and `:727` speak of the canvas shell in the present tense against
  `:11`'s "the canvas shell it replaced … is deleted"; and `skia-build.md:73` carries
  the same false PNG-config contrast that `build-skia-android.sh` had — both FreeType
  configs define `FT_CONFIG_OPTION_USE_PNG`, and the real divergence is
  `skia_use_system_libpng`.
- **The nav-roster measurement story has four homes** — `services.js`,
  `stylesheet.zig:911`, `live.js`, and `dom-edition.md:250-257`. The docs page looks
  like the owner and the three code sites should cite it.

## No gate runs an example's route builders

`zig build test -Dskia` links the examples, which is the desktop link
`check-targets` cannot do — and linking is where it stops. A builder that
compiles and raises when it runs is invisible to every gate in this repository,
and reportedly has been: three kitchen-sink screens are said to have raised at
build time and passed everything. That half is second-hand — recorded here
because the hole itself is checkable and the receipt is not.

It is the same species as the two closed at revisions 53 and 54 and the one
`docs/testing.md` already names one line below the tier table ("the examples link
two of them; nothing runs them"): something linked, never executed, and
therefore green. The examples have no `Device` driver and no harness of their
own; what a gate would need is to build each screen once, off the route table,
against a real `App` — which `tests/capture.zig` already does for one app and
could do for the examples' route tables without a window.

Deferred rather than open-ended: it was scoped beside the revision gate and lost
to it.

## The static-site API is unvalidated where it matters most

`getnokre.github.io` exercises it at one locale, in LTR, with English Markdown
bodies. That covers the axis, the per-locale loop, the path-scheme boundary,
`lang`/`dir` on a generated document, the chooser stub and `L.chrome`'s
compile-time completeness.

It did **not** cover the hydration handover, and the sentence that used to claim
it here is this section's own receipt. A reference site publishes pages and
watches none of them boot; the one gate that boots the shipped `live.js` over a
generated page booted over the *first* page its generator ever wrote — the only
page whose node ids a browser could ever have matched. Every page after it
handed over by replacing the reader's document, on every static site nokre has
published, and nothing reported it, because the markup afterwards is identical
either way. Closed at revision 54, and the case no gate reached is now
`hydrationOutlivesTheGeneratorsHistory` (docs/testing.md).

It cannot cover an alternate set with two real languages, `x-default` in its
multi-locale form, RTL served statically, or a translated document body. Those
meet a consumer for the first time at `rokovski.com` — three locales, one of them
RTL, and roughly 4,250 generated pages. **A green reference site is not evidence
for any of them**, and the first migration is where the API gets its real test.

## A bundle's own tag faces no grammar, and now two paths disagree about that

Revision 50 gave `Link` and `Span` a `lang`, held at `append` to
`element.validLangTag` — a BCP 47 tag, `-` separators, `error.InvalidLangTag`.
An ARB `@@locale` faces no such rule: `l10n.localeIdent` accepts letters, digits
and *either* separator, so `"@@locale": "pt_BR"` compiles and `L.tag` hands the
underscore straight back out.

Nothing in the bundle is wrong about that — `resolve` and `directionOfTag` both
ignore the separator deliberately. What is wrong is where the tag lands as
**markup**: `document.localeStub` writes `L.tag(loc)` into `hreflang` and `lang`
on every choice, and `alternates.Alternates` writes it into every
`<link rel="alternate" hreflang>`; neither checks it, and `pt_BR` is not a value
a crawler or a screen reader parses. So one path in the library now refuses a tag
the other two publish.

Three ways out, none obviously right: hold `@@locale` to the same grammar at
`Bundle` (a compile error for any consumer spelling one with `_`, which is a
contract change and wants its own round), normalize `_` to `-` where a tag
becomes an attribute (two writers, one silent rewrite), or leave it and say so in
`localization.md`. The bug is unexploded — every ARB in this repo spells its tag
with `-`, `fa-AF` included — which is exactly why it should be settled before a
locale is added by someone reading the ARB spec rather than this file.

## Two writers of a boot call, and they just got much closer together

Revision 53 moved the static writer's boot and its locale chooser out of
inline `<script>` blocks and into files
([dom-edition.md](docs/internals/dom-edition.md), "Neither script on a
generated page is an inline one"). Which leaves
`packaging.webBootJs` — the app shell's `boot.js` — as the second writer
of a `mount` call, and the argument that kept the two apart is thinner
than it was: it used to be *one is a file and one is a block*, and now
both are files loading the same module. What is actually different is
only that a shell has one page per site with two arguments out of the
declaration, so it writes them into the file, where a generated page has
one per screen and states them as data.

**The candidate is deleting `webBootJs` and `web_page_files`' `boot.js`
outright**: `index.html` would carry a `data-nokre="boot"` block and a
`<script type="module" src="live-boot.js">`, and there would be one boot
module in the repository. It is not free and that is why it is here
rather than done. `live-boot.js` resolves `content` with
`document.getElementById(config.content)`, and a shell has no content
mount — `mount` reads an *absent* `content` and an absent `locale` as
real answers, so an explicit `null` from a missing key is not the same
value, and the file would need to say so. That is a change to the one
file every generated page loads, weighed against removing an emitter,
its testdata golden, a `web_page_files` entry and one of two writers.
Nobody has made the case either way.

## Store screenshots are a preset nobody has asked for yet

Revision 51 built the engine and stopped there, deliberately.
`render.skia.capture(io, dir, gpa, app, path, .{ .scale, .format })` is
one frame of a live app through the production renderer at a path the
caller names, in a process with no window; `PixelSink` is that per step.
A store submission is the same call in a loop over journeys × device
sizes × locales, and `App.setViewport` and `Bundle.resolve` are what
such a loop turns.

**Whose half is whose was decided in rokovski's `HANDOFF.md`, not
here**: nokre owes device-sized rendering plus optional hi-DPI off the
e2e path — which is what shipped — and rokovski owes the journeys, the
naming and the output paths. So what is open on this side is a question,
not a task: whether that loop deserves a preset *in nokre* at all, or
whether a consumer's device table and locale set are its own and the
one-shot is the whole of nokre's contribution. Nothing argues for the
preset yet, because there is exactly one consumer and it has not asked.

What is known: it is release-blocking for a store submission, and it is
blocked on rokovski's side rather than this one — that half wants seeded
locale-tagged fixture data, and the seeding is itself an open blocker
there. A preset designed before that data exists would be a shape
argued from none.

## Two consumers want a link with a size

Recorded as an observation. Nothing here has been designed, no shape has been
argued, and this is not a request for a styling hook — it is two data points
filed where the next round can find them.

**What both hit.** `Link` carries no style: `element.Link` is a label, a
destination, a `lang` and layout's own `folded` — no ink, no scale. So a
`stack` of `link`s is body-scale ink, and a footer built the way this library
tells consumers to build one cannot be the small dimmed type a footer is set in
almost everywhere. Two repos, one week, neither agent aware of the other:

- **getnokre.github.io**, in the comment it left beside its `footer` builder.
  It drew a `divider` because the licence sentence "is set in exactly the same
  face at exactly the same size" as the paragraph above it — "which is what the
  small dimmed type behind a border used to prevent and what moving into the
  tree gave up. The type is the library's to decide and this is not asking for
  it back."
- **rokovski.com**, reported by the agent that adopted revision 50 and *not*
  written down in that repo, so this half is second-hand. What is checkable
  there: the footer row — the site's name, four links, the language row — is
  the one body-scale block in a builder that reaches for
  `.{ .scale = .small, .ink = .mid }` on captions, eyebrows and detail lines
  throughout. Circumstantial, and stated as such.

Two consumers asking is this library's own bar for an element earning its place
([contributing.md](docs/internals/contributing.md)).

**The ask is narrower than it was reported**, which is the part worth having on
file. "The cursor has no spans-plus-style call" is a missing *verb*, not a
missing capability: `Text` already carries a `style` beside its `spans` —
`validateSpans` reads `t.style.ink` as the base every span inherits — and a
span already carries `route`, `external`, `lang` and its own `ink`, serialized
as a real anchor with its own tab stop (`serialize.zig`'s `inlines`). A small,
muted row of links is therefore expressible today, as one `text` element built
through `tree.append` directly, because `Cursor.spanned` is the one door and it
drops the style. What that form cannot do is what a `stack` does: gaps,
wrapping as a row, and the nested group a language row is.

So there are three questions here and a decision on none of them — the cursor
verb (the smallest thing that would have unblocked both), a `scale` on `Span`
(it has an `ink` and no scale, which is why the workaround can only be
paragraph-wide), and a style on `Link` itself. Whether any of them is the
styling hook the refusals forbid is the argument nobody has made: the refusal
names colour and custom widgets, and a scale is neither — but that is an
assertion, not a case.
