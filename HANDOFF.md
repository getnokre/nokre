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

## The static-site API is unvalidated where it matters most

`getnokre.github.io` exercises it at one locale, in LTR, with English Markdown
bodies. That covers the axis, the per-locale loop, the path-scheme boundary,
`lang`/`dir` on a generated document, the chooser stub, `L.chrome`'s
compile-time completeness and the hydration handover.

It cannot cover an alternate set with two real languages, `x-default` in its
multi-locale form, RTL served statically, or a translated document body. Those
meet a consumer for the first time at `rokovski.com` — three locales, one of them
RTL, and roughly 4,250 generated pages. **A green reference site is not evidence
for any of them**, and the first migration is where the API gets its real test.
