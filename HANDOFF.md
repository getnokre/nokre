# HANDOFF — what a static, multi-locale site needs from nokre (2026-08-06)

Status: **IN EXECUTION.** Part F was answered whole on 2026-08-06 — the round's
premises are settled and recorded there; read it before anything else. The
survey's *claims* are still claims and still want checking, but its open
*questions* are closed. The execution queue is at the foot of this file, and
items are deleted from it as they land.

This file succeeds the third ergonomics round (executed whole; recoverable at
`git show 3855adf:HANDOFF.md`). Parts 0 and A of that round are done through
revision 32 plus `TextInput.disabled`. What was still open there is carried
forward in Part E below, one line each, with pointers rather than copies.

**Verification basis.** Citations here are by **symbol and section, never by
line number** — deliberately, so they survive the next pass moving code. A code
fact is named by its file plus the narrowest symbol containing it; a doc fact by
its file plus its heading, or by a quoted sentence distinctive enough to grep.
Counts and commit hashes stay as written: both are facts, not coordinates. Line
numbers were tried for two rounds and re-resolving them cost more than they
bought — about sixty of them moved in a single day.

Everything below was grep- and read-verified against nokre `682b839`
(`nokre.revision` is 32) and the site at `b93a2d4`; downstream consumer facts
come from the rokovski tree as of `eea6de1a`. Every symbol name used as a
citation was re-resolved against nokre `63a837c`, the site at `b93a2d4`, and
rokovski `e4db89c0` — a symbol that does not exist is a wrong claim, not a stale
pointer, so check the name before quoting the fact. Several claims in the first
version were wrong outright, not merely stale. Where a reading changed, the old
one is named in place — a reader who saw the first version needs to know what
moved, and there is deliberately no changelog section to consult instead.

**Execution protocol.** Contract changes bump `revision` and move all three pins
in the same pass. Beyond that:

**Default: keep going.** Finish an item, verify it, commit it, take the next
one. Do not stop to report good news, and do not stop to ask permission for
something the code or a recorded doctrine already answers.

**Batch the human decisions up front.** Part F is the set of questions only the
owner can answer. Answer those *first, together*, before execution starts — then
run the whole queue without further pauses. That is the one interruption this
round plans for.

**Stop only when one of these is true.** This list is the whole test, and it is
closed:

1. A decision changes *what gets built*, two shapes are both defensible, and
   neither the code nor a recorded doctrine picks between them.
2. The work would reverse a recorded owner decision or violate a stated refusal.
3. The step is irreversible or outward-facing — publishing, deleting, anything a
   reader outside the repo would see before review.
4. A discovery invalidates the premise of the remaining queue, so continuing
   would build on something known to be wrong.

**Do not stop for** — these are the expensive false positives — a stale
reference, a wrong count, a receipt that has rotted, an item that turns out
already solved, an item that turns out wrong (kill it on the recorded ground and
continue), or a proposed shape the code argues against (take the better shape,
record why, continue).

**What replaces the pause is the record.** Every item's outcome — shipped,
killed, already-solved, reshaped — gets written down with its ground at the
moment it is decided, so the owner reviews a finished trail rather than gating
each step. A killed item with no recorded reason is the one thing that must not
happen: it is exactly what forces the next round to re-derive it.

---

## How to read this file

This is a brief, not a work order. It was written by an agent working in the
*consuming* repo, which means it is well-informed about what a static site needs
and comparatively ignorant about why nokre is shaped the way it is. Treat every
item as a claim to be checked, not an instruction to be executed.

Specifically:

- **If an item is already solved, say so and close it.** Several near-misses in
  this file are one export or one commit away from things that exist; the survey
  may have missed the export that already answers it.
- **If an item is wrong, say why and kill it.** The doctrine arguments live in
  this repo, not in the consumer. An item that violates one should die on that
  ground, and the ground should be written down where the next round can find it.
- **If an item is right but the shape proposed is wrong, propose the better
  shape.** Every sketch below is illustrative. None is a design.
- **Do not adopt items as a package to "finish the theme."** The value of most
  of these is independent; the cost of a wrong one is a contract that consumers
  build on. Judge each on its own merits — which is not the same as pausing
  between them.

The single most likely failure mode for this round is an agent reading it as a
list of features to add and adding all of them. Most of the argument's weight is
in Part C, which asks whether the *category* belongs here at all — and the answer
may legitimately be "some of it, and not the rest."

---

## The killed item, recovered — and it is not the one this file assumed

*Written 2026-08-06, answering this file's own instruction to recover the kill
argument first. It did not end the round, but it moves it.*

**No full static-site driver was ever killed.** Round two's handoff
(`git show c80c65c:HANDOFF.md`, item A10.4) proposed something much narrower —
`dom.document(em, .{ .title, .lang, .head_extra, … })`, a helper owning
"doctype, mount points and the skip link" — and about the larger thing said, in
its own parenthesis:

> *"(A full static-site driver — the per-route loop, anchor harvest, stale-prune
> — is a larger owner decision; log it, don't assume it.)"*

So the larger question was never decided, in either direction. What the owner
killed, in round two's status block (`git show 627ceda:HANDOFF.md`), was A10.4,
in a list of items killed after an evidence review, each with a one-clause
ground. A10.4's ground:

> **"A10.4's contract-string premise half-wrong"**

**That kill was evidentiary, not doctrinal**, and re-checking it at HEAD shows
it was exactly right — "half" is literal. A10.4 claimed the site's raw HTML
reproduced three nokre-internal contract strings. Checked today:

| cited string | who owns it | verdict |
|---|---|---|
| `class="nokre has-chrome"` | nokre writes it (`live.zig`'s `buildFrame`) and styles it (`stylesheet.zig`'s `sheet`, the `.nokre.has-chrome` rule) | **real duplication** |
| `#chrome` / `#content` / `.page` | nokre: **zero hits** | the site's own |
| `addressing: "documents"` | nokre: **zero hits** | the site's own |

Two of the three are the *driver's* inventions that nokre has never heard of. A
helper owning "mount points" would have made nokre own ids and an addressing
mode belonging to the consumer — the precise boundary `stylesheet.zig`'s `sheet`
states in its mirrored-chrome comment and this file quotes approvingly. The owner was
declining to move that boundary on evidence that half the reason offered for
moving it was not true.

**Consequences for this round, and they cut three ways:**

1. **Parts A and B are not re-proposals of a killed item.** They are new
   questions about a question that was deferred. Refusing them on adjacency
   grounds would be refusing something that was never refused.
2. ~~**The kill's surviving half is a real, still-live item, and it is small.**~~
   **SHIPPED, revision 33 — as a function, not a constant.** See "Landed" below.
3. **The precedent to honour is the *shape* of that kill, not its verdict.**
   Round two killed a document helper because two thirds of what it proposed to
   own belonged to the driver. Any Part A item that asks nokre to own something
   the consumer invents — an id, an addressing mode, a path scheme — should die
   the same way and for the same stated reason. Any item where nokre already
   owns the fact and merely fails to export it is the opposite case, and A10.4's
   surviving half is the model for it.

## Why now: the second consumer

`getnokre.github.io` has been nokre's only static consumer. A second is
arriving — `rokovski.com`, the public marketing site — and it is materially
bigger:

| | getnokre.github.io | rokovski.com |
|---|---|---|
| locales | 1 (en) | 3 — `en`, `fa` (RTL), `tr` |
| static routes | ~20 | 20 × 3 = 60 |
| generated pages | ~20 | **~4,250** (locale × category × dimension × statement) |
| markdown collections | docs | articles (4/locale) + docs (3/locale) |
| structured data | none | FAQPage, Service + AggregateOffer (EUR), ItemList, WebPage, Article |
| JSON endpoints | none | 2 per locale, consumed by three other packages |
| interactive surfaces | none | rankings, statement search (both via public API) |

It is today an Astro site. Everything above already works there, which is the
uncomfortable part: the migration has to *not lose* things nokre currently cannot
express.

The pages are the product. Those ~4,250 statement pages are a content-SEO
surface, not a nicety — they are the reason the site exists in its current shape.
A static generator that cannot emit correct `lang`, canonical, hreflang and
structured data for them is not a viable target, and the consumer will hand-roll
all four in its own driver if nokre does not.

That hand-rolling is the actual question this round decides. Not "would these
features be nice" — **"should the second driver re-implement the first driver's
document shell, or is that the library's job now?"**

---

## The unwritten rule this round should write down

There is no stated position anywhere in `docs/` on whether SSG and SEO concerns
belong to the framework or the app — **the survey said "three times by instance";
there is a fourth, and it is the most rule-like of them**, which changes where
this round should start:

1. `docs/internals/dom-edition.md`, *"What the host document owes, and what it
   keeps"*, then an enumeration. Says what the app owes; does not generalise.
2. `src/render/dom/stylesheet.zig`'s `sheet` — the mirrored-chrome comment
   above the `:root[data-direction="rtl"]` rule, closing on *"the attribute is
   the driver's to stamp, but the page around an embedded app is not this
   edition's to turn around"*. Closest thing to a rule among the three, and it
   is about `data-direction`.
3. `docs/localization.md`, "The refusals" — its *no runtime catalog loading*
   bullet, on a neighbouring question, is the sharpest phrasing of the instinct:
   *"Downloadable translations are a distribution feature with a cache, a
   version skew story, and a failure mode on first launch — that is an app, not
   a GUI library."*
4. **`src/testing/audit.zig`'s `Options.skip`** — its doc comment, which names
   the static-site generator by name and then says what it is entitled to:
   *"The known case is a static-site generator skipping `unresolvable_route`:
   there a document destination is the* site resolver's *to honor, not the route
   table's, and that resolver already fails the build harder than this rule
   would."* This is not an instance, it is a rule with a subject: **a document
   destination belongs to the generator, and nokre stands down where the
   generator is the stricter authority.**

That fourth sentence cuts, and it cuts unevenly. It is an argument *against* A2
and A3 — a canonical URL, an `og:url`, a JSON-LD `@id` are all document
destinations, and nokre has already written down that those are the site
resolver's. It leaves A1a and A1b completely untouched: `lang` and `dir` are not
destinations, they are facts about the text nokre itself put on the page.
Whatever doc this round writes should start from that sentence rather than
re-derive it.

**How the two items it cut at actually resolved, which is what item 10 should
write from.** Neither overruled it. A3 shipped as `Emitter.json` — an escape,
not a graph, so no `@id` is nokre's. A2 and A4 shipped as `Document.meta` with
**every destination a required field carrying no default and no derivation**: the
library took the *relationships between* destinations (the canonical is the
`og:url`; both are absolute; a page with no URL has neither) and left the
destinations themselves exactly where that sentence put them. The rule the round
found is therefore sharper than "the generator owns destinations" — it is **the
generator states them; the library is what keeps them from disagreeing.**

The consuming site states the boundary in the plainest words either repo has for
it — `getnokre.github.io/src/main.zig`'s module doc comment: "Everything below is
the *driver*: which screens exist, what a reference resolves to, and the document
a browser needs around a screen. The markup and the stylesheet are the
library's." The emphasis on *driver* is the source's own.

**Whatever this round decides, the outcome belongs in a doc.** A rule that lives
in a test helper's doc comment, with three instances around it and no
consumer-facing statement, is exactly what let a consumer-side agent confidently
brief the owner on the opposite of what the code says. If the answer is "the
document is the driver's, permanently," that sentence is worth more than any item
in Part A.

---

## Part B — per-locale generation

**The owner has flagged this as the part that most needs real support.** It is
also the part where nokre has already moved furthest, which is why it is
tractable at all.

### What already exists

`4876c99` changed `RouteDef.title` to
`Title = union(enum) { fixed: []const u8, of_locale: *const fn([]const u8) []const u8 }`
(`src/core/router.zig`'s `Title`), resolved through `Title.text(locale_tag)`,
and gave the App the chosen locale — `App.setLocale`, `App.locale()`, and
`Options.locale`, a declared field on `App.OptionsRelease` (what `App.Options`
aliases) consumed by `App.init` (`src/core/app.zig`); the survey knew only the
`init` half.
`setRouteTitles` and `Router.retitle` retired. `128ef2b` added `L.of(app)`
(`src/l10n/l10n.zig`), `trAny` for runtime keys, and `L.chrome(locale)`
deriving one reserved key per `Chrome` field at comptime — so a missing chrome
word is a compile error rather than shipped English. `408d77b` added
`Bound.tag()/.dir()/.chrome()` and `L.in(app)`.

**And the bundle already owns the locale *set*, at comptime.** In
`src/l10n/l10n.zig`: `L.Locale` is an exhaustive enum over the bundled locales,
`L.tag(loc)` gives each one its BCP 47 tag, `L.dir(loc)` its
direction, `L.default_locale` the template, and `L.resolve(tag)`
maps a device tag onto them. This is load-bearing for B1 below and the
survey did not have it.

**An earlier sentence in `RouteDef.title`'s doc comment (`src/core/router.zig`)
reading "Comptime, and a locale is not" is gone** — `4876c99` deleted it. A
consumer-side brief quoted it as current doctrine last week; it
was already false. Worth knowing that this area moved recently and quickly.

### What is still missing

Routes carry no locale segment and there is no per-locale route *set*. Nothing
generates a tree once per locale, and nothing derives the relationship *between*
locale variants of one page. Concretely:

### B1. The locale axis

A three-locale static site regenerates the whole tree per locale, and each page
needs to know both its own locale and the full set. Today that loop is entirely
driver code.

**The survey's sketch was this, and two of its four fields should not exist:**

```zig
// The survey's sketch. Kept for the record; see below for why .locales
// and .default_locale are wrong.
const site: nok.render.dom.Site = .{
    .origin = "https://rokovski.com",     // config, app's
    .locales = &.{ "en", "fa", "tr" },    // app's
    .default_locale = "en",
    .path = .prefix_all,                  // /en/… /fa/… /tr/… vs. bare-default
};
```

**`.locales` and `.default_locale` invent a locale set nokre already owns at
comptime.** `L.Locale`, `L.tag`, `L.dir` and `L.default_locale` are derived from
the ARB bundle itself (receipts in the section above). A `Site.locales` field is
a **second source of truth that can silently disagree with the ARB set** — a
locale listed there and missing from the bundle generates a tree of template
strings under a `/de/` prefix; a locale in the bundle and missing there is simply
never published. That is the exact failure `dom.driver_files` was created to
kill, and this file cites that commit approvingly two sections later. An item
that re-commits it while praising the fix should not survive review in that
shape. If a generator needs the set, it needs `L.Locale`, not a literal.

**`.origin` and `.path` are the app's, and they are real** — but note the URL
half of B1 is *already expressible*. `Refs.resolve` returns a `Dest`
(`Refs` and `Dest`, `src/render/dom/serialize.zig`), and a driver's resolver can return
`/fa/…` for any route today; that is precisely what the reference site's
`Resolver` does with its own scheme. Nothing in the library stands between a
driver and a locale-prefixed href.

**So B1 shrinks.** What is genuinely missing is *the loop* — regenerate the tree
once per locale, hand each page its locale — plus B2's derivation, which is the
part a second driver will actually get wrong. Everything else in the sketch is
either owned already or belongs to the driver. The interesting design question
is now the narrow one: **is the loop worth owning at all**, given it is four
lines over a set nokre can already enumerate?

### B2 and B3. hreflang, `x-default`, sitemap alternates

**SHIPPED, revision 39** — as one derivation both writers spend. See "Landed"
below. The survey's pure-function sketch was superseded by a type; the
completeness invariant is a compile error rather than a runtime sweep, and
reciprocity turned out not to need enforcing at all.

### B4. The output-path scheme

The reference driver maps home → `index.html`, 404 → `404.html`, else
`<route>/index.html` (`main.zig`'s `outPath`; the survey pointed at
`failOnStale` instead). A locale axis
multiplies that, and the default-locale question (`/en/…` versus bare) is a real
fork the consumer has already answered one way (Astro's
`prefixDefaultLocale: true`).

Worth deciding alongside B1 rather than after: it determines whether the
canonical for the home page is `/` or `/en/`, which determines what the redirect
stub at `/` must say, which the consumer already has two of.

### B5. Route references are ASCII-only

**SHIPPED, revision 33** — documented, not relaxed. See "Landed" below. The
constraint itself stands exactly as it was: a route argument is an identifier
and not a payload, and that does not move for a locale. Still binding on
everything below — a locale prefix is a BCP 47 tag and therefore ASCII, so the
locale axis does not hit it, but any *localized-slug* proposal is already
answered.

---

## Part C — the scope question, which is the actual round

Parts A and B are individually defensible and collectively amount to something
larger: **nokre shipping a static-site driver.** That is the killed item.

The honest case for reopening is not any single item. It is the pattern in the
last round's own commits, every one of which moved something from the driver into
the library, and every one of which was justified by the driver having gotten it
wrong:

- `4044e66` — `dom.driver_files` became the library's statement of the file set.
  The survey quoted this as *"this site once re-typed two of the four and shipped
  a service-worker registration that 404ed on every page load"*; that sentence is
  nowhere in the repo. The real words are `driver_files.zig`'s module doc
  comment: sw.js is
  registered *by URL*, so *"a missing one is a silent 404 at runtime, not a build
  error, which is exactly why the set is data rather than prose"*, closing with
  *"The one consumer that re-typed this list shipped two of the four."* Same
  argument; it is worth having it in the words the repo actually uses.
- `Refs.write` → `Refs.resolve` returning `Dest` — because *"closing `href="` by
  hand to smuggle attributes in was the sharpest bypass any consumer had, and
  this shape is what removes it"* (`Refs`'s doc comment, `serialize.zig` — this
  one the survey
  quoted accurately, just clipped). The signature's other half is the harder
  rule, at the close of that same comment: *"a hook that writes `em.out` is
  re-opening the door this signature closed"*.
- `86e73e6` — `Router.ref` replaced ~20 hand-rolled reference formatters. **It is
  `Router.writeRef` now** (`src/core/router.zig`), renamed by `627ceda`'s
  vocabulary sweep; anyone grepping for `Router.ref` will find
  nothing.
- `92ef0ba` — `testing.shell` shipped: *"The shell a driver links instead of
  writing… Before this module every driver wrote the same block by hand"*
  (`src/testing/shell.zig`'s module doc comment), and a static-site generator is one of the
  drivers it names. **The survey attributed to this commit a quote — "a generator
  is a platform shell and gets its shell from nokre" — that appears nowhere in
  the repo.** The commit is real and the direction is right; the sentence was
  invented.
- `9762b8b` — the vendoring pin became a library constant.

**Five moves in one round, all one direction** — the survey said six, counting
`dom.driver_sources` among them. That one is real but it is not from that round:
it landed in **`e1e9f43`**, the closing sweep of the round *this file succeeds*
(the driver JS `@embedFile`d, so a generator stops joining a checkout path to
find bytes a stale copy could outlive — `dom.zig`'s `driver_sources`). It strengthens the
pattern; it does not belong in that round's tally.

**The survey then said the previous handoff's own Part C carried two more that
"remain open." Both shipped, and the Part E it pointed at never listed them.**
The site calls `app.router.current()` (`getnokre.github.io/src/links.zig`'s
`currentPage`, under a doc comment saying *"the router has already answered the
question"*), and
`packaging.web_page_files` (`src/packaging/packaging.zig`) is the one
statement of the pkg-web quartet, consumed exhaustively in `build.zig`'s
`addPkgTree` with a `@compileError` for any name lacking a writer. Nothing in
`build.zig` re-types it: `addWebSite` appends that same list into
`site.manifest`. There is no live item here — only a dangling
pointer, now removed.

**The counter-argument deserves equal weight**, and it is the one that killed
this before: a GUI library that emits sitemaps and structured data has stopped
being a GUI library. `docs/localization.md`, "The refusals", already refuses a
smaller thing on exactly this ground. The document a browser needs around a screen is a
publishing concern, and publishing concerns have opinions — about origins,
redirects, canonicalisation, indexing policy — that a framework should not hold.

**A middle position exists and may be the right one:** nokre owns the
*derivations* (alternate sets, canonical construction, escaping, `lang`/`dir`
from a locale it already knows) and refuses the *policy* (which routes exist,
what the origin is, whether the default locale is prefixed, what goes in the
sitemap). That splits Parts A and B roughly down the middle, ships the pieces
that are wrong-by-hand, and keeps the framework out of the publishing business.

The round's real deliverable is a decision on that line, written down.

---

## Part D — already yours; do not rebuild

Verified present. An item proposing any of these is a survey miss.

- **The static+hydrate pair is real, documented, and shipping.**
  `nokreWebRefs` exists precisely for pages pre-published as files
  (`live.zig`'s module doc comment states it; `live.zig`'s `boot` installs it);
  the site declares all three decls — `nokreWebSeed`, `nokreWebBuild` and
  `nokreWebRefs`, in `web.zig`. The hydration
  contract is explicit — `dom-edition.md`, "The seams", the **Node ids**
  bullet: match is tag + `data-n`,
  *"the ids are a hydration contract, not decoration"*, and it
  carries scroll, focus and caret through the handover. `dom-edition.md`, "Two
  drivers, one walk",
  calls a static page *"the useful degenerate case of the pair."* The consumer's
  two interactive surfaces need exactly this.

  **Two qualifications the survey's "no new mechanism is required" glosses
  over.** First, A1a: the pair carried no locale, and the same `data-n` match
  quoted above is what made booting the wrong one silent — **shipped, revision
  35**; the pair carries one now (`mount({ locale })`, written by
  `dom.document` from the same `App.locale()` its `lang` comes from), and a
  driver still supplies none. Second, **the seed
  costs a network fetch per page** — `live.js`'s `mount` builds its `seeding`
  promise as `fetch(seed).then((r) => r.text())`, a URL, not inline bytes. That is the right
  trade for two interactive surfaces and for a doc site handing over its
  Markdown; it is not free at 4,250 pages, and a consumer reading "no new
  mechanism is required" should know which mechanism it is getting.
- **Build-time gates**, all four reached from `main.zig`'s `main`: the a11y
  audit per screen, inside its "every screen" loop, now calling `audit.collect`
  with `Options{ .skip = &.{.unresolvable_route} }`; the "link check" banner's
  pass over broken references including `#anchor` targets, whose anchors are
  harvested per page with `em.takeAnchors`; the "icon check" banner's
  subset/tofu coverage; and stale output, in `failOnStale`. These are stronger than the Astro site's
  equivalents and are a reason to migrate, not a gap to fill.
- **Heading anchors already handle Persian and Arabic, deliberately** — so
  nobody should propose slug work for the RTL locale. `serialize.zig`'s
  `headingId`
  keeps Unicode word characters byte-wise, because *"dropping these bytes would
  slug every Persian or Arabic heading to 'section' — one anchor for a whole
  document"*, with only General Punctuation (U+2000–U+206F) carved out to match
  what GitHub's slug drops. A three-locale docs collection gets working
  per-heading anchors in all three with nothing asked for.
- **Colour is refused, permanently.** Thirteen grays — `src/core/color.zig`'s
  `Gray`, `g0` through `g12` — and `docs/elements.md`, in the Google button's
  paragraph on its G: *"your app remains grayscale-only"*.
  The consumer has been told; it is a brand decision on their side, not a request
  on yours.
- **No image element.** Settled: `Role` (`src/core/element.zig`) has
  forty-three members and none of them is an image — the count is right, checked
  member by member. A4 is a `<meta>` URL and nothing more. The stale sentence in
  `docs/introduction.md` that promised one is fixed (revision 33).
- **Locale-aware route titles, App-owned locale, `L.of`/`L.in`/`Bound`, and the
  bundled locale set itself.** See Part B's opening.

**One bullet the survey filed here does not belong in a *nokre* handoff.** It
read:

> *"One route→href mapping spent by both drivers — `links.zig` (417 LOC),
> `Resolver` (`:71`) for the generator, `Live` (`:118`) for wasm. This is the
> pattern the second driver should copy, not a gap."*

`links.zig` is **`getnokre.github.io/src/links.zig`** — a consumer file, 417 LOC
of the reference driver's own resolution policy, which has never existed in
nokre. Listing it under "already yours" in a brief addressed to nokre's owner
reads as an offer of something nokre does not have. What nokre ships is `Refs`
and `Dest` (`src/render/dom/serialize.zig`, about thirty lines including
the doc comment) — the seam; the 417 lines are what a driver writes against it.
The quote's second citation lands on `Live.refs`, the method, rather than on
`Live` itself.

The bullet's closing sentence is right and worth keeping on those terms: **one
resolver spent by both the generator and the wasm build is the pattern the
second driver should copy**, and copying it is a consumer-side job with no
library change behind it.

---

## Part E — carried forward from the ergonomics round, still open

Re-checked against HEAD 2026-08-06. **Three bullets that stood here were already
executed and have been deleted**: A8 (the owner took `bindKey` and declined the
other two menu items; shipped revision 29), the whole Part B rename table
(revision 31), and all of Part C (revision 31 — items 2 and 3 shipped alongside
4 and 5, item 6's four doc gaps closed, and item 7 shipped except the
`external_attrs` half, whose receipt was stale: it was already one home). The
header above is right that Parts 0 and A are done through revision 32; the
carried bullets contradicted it.

What is genuinely still open:

- **Part D — performance.** Untouched; Part F item 12 of the old round did not
  scope it. Verified still true at HEAD: `shim/nokre_skia.cpp`'s
  `hsk_surface_pixels` still
  `readPixels` the whole surface into a persistent buffer every frame
  (~15 MB/frame at 1200×800@2×) where a CPU raster surface can hand its pixels
  out directly, and the `widths` cache behind `src/render/dom/services.js`'s
  `measure` is
  still cleared only on `loadingdone`, so a long editing session grows it
  without bound. Plus the DOM edition ignoring `needs_frame`, and `hsk_dither`
  rebuilding a 2×2 bitmap and shader per scrim call.
- **Part E of that round — evidence filed, not proposed.** `Remote(T)` and
  staleness, the ApiClient `= undefined` wiring and two-phase init, number
  formatting, `.table()`'s org-app absence, the notification mock's one-sided
  journal, and rokovski's own placement debt. These move only on their own
  owner-level arguments, and none has been made.

Residue the executed round left behind, none of it carried by the bullets that
were deleted. Full receipts at `git show 3855adf:HANDOFF.md`:

- **`http.Handle.cancel` is still discarded at every call site.** It was an A8
  *receipt* but never one of the three menu items, so the decision that closed
  A8 did not touch it. One `.cancel()` exists in the consumer tree.
- **`truncated` reaches no user-facing surface.** A1 shipped the disclosure and
  the migration wired it nowhere, because neither app owns a string that could
  say it — ~30 sites need catalog copy. **Two of them are not ceilings**: a
  member's fifth permission silently loses the control it grants, and a dropped
  `tags.Library` entry makes a real tag fail `knows()` and vanish. Also two
  unexploded caps: `family_cap = 4` against a format that permits `industry`,
  and an exact `id_cap = 8` whose overflow *collides* rather than truncates.
- **`setHandler(app, ctx, fn)` and `Asker.ask(msg, ctx, fn)`** take the context
  and the function as two positional arguments, so no pair exists for `bindAs`
  to fill. That is the largest remaining `?*anyopaque` surface in nokre's own
  API — 9 sites on the published services page, 4 in the tutorial, 6 live casts
  in the apps.
- **`overflow.closeTailSheet` is the fourth dismissal door** and still does not
  rebuild, so a folded action writes state the screen never shows. 6b fixed the
  other three; this one's fix is structurally different.
- **`emptyGate` folds "not ready" into "ready and empty"**, so four sites that
  append a hint or a control only in the empty case cannot use it; and `Gate`
  has no bare `raise`, so two paths that legitimately re-raise discard
  `begin`'s answer.
- **Six sites hand-roll `in_progress` as a boolean that must also turn off**,
  which `patchProgress(id, pct)` cannot express; a `patchBusy` was declined as a
  third verb.
- **Two consumer-side defects**, both flagged and neither fixed: org `Invites`
  serves two routes and resets its notice only on organization change, so a
  failure leaks across navigation and is reported out of context; and org
  `organizations_sheets.zig`'s `render` builds the join-code sheet with
  `.error_copy` but no
  `.busy`, so its submit has no in-flight representation where its sibling does.

---

## Part G — dogfood on this site, and give it a locale axis of one

*Owner-raised 2026-08-06. Not a proposal for a feature; a proposal for how the
features in Parts A and B get proven before a second consumer bets on them.*

**The ordering argument.** `getnokre.github.io` is the only static consumer that
moves in lockstep with nokre — same session, same pin, same reviewer — and this
round has already shown what that buys. Every pass of the third round that
shipped a door made nokre's own examples and tutorial walk through it first, on
the stated ground that *if nokre's own house keeps writing the ritual, the door
is not real*. Twice that caught defects a reading would not have: a container
that panicked on the obvious call, and a driver verb that did not wait. An SSG
API validated only against `rokovski.com` is validated against a tree that
cannot move until nokre commits, which is the wrong order.

**Give it a locale axis with exactly one locale — and keep its URLs where they
are.** That last clause is the whole point, and it makes the degenerate case a
sharper test than it first looks:

- A single-locale site that stays at `/accessibility/` rather than moving to
  `/en/accessibility/` proves the locale axis **does not force a path scheme**,
  which is precisely what B4 says the driver owns. If the API cannot express
  "one locale, identity mapping", it is wrong, and one locale is the only
  configuration in which that is unambiguous.
- It forces the one-locale case to work *without a special case*. An API first
  exercised at three locales tends to grow a `if (locales.len == 1)` branch
  later, in a consumer, unreviewed.
- Moving the published URLs is a real cost with no test value: every inbound
  link and every cross-doc fragment in `docs/` breaks, and the round would be
  paying it to learn nothing it could not learn from the identity mapping.

**What it would cost here**, verified: ~20 page titles are hardcoded English —
the `.title` field of every entry in `src/pages.zig`'s `all` — and would become
catalog keys against a one-locale
bundle; the origin was hardcoded at **four** sites (in `src/main.zig`:
`writeDocument`'s canonical and `og:url`, and `writeExtras`'s sitemap `<loc>`
and `robots.txt`) and wanted one constant whatever
else happens — **done in item 5**, `main.zig`'s `origin`, which also records why
`content.zig`'s `qr` example is a fifth occurrence and not a fifth copy; and the
site today has no l10n surface at all, so the bundle is new. Nothing else moves.

**Be honest about which half this proves.** A one-locale dogfood exercises the
axis, the loop, the path-scheme boundary, `lang` on a generated document, and
A1a's hydration handover — that last one is testable here the moment the site
declares a locale, because the failure is a mismatch between the page's locale
and `navigator.language`, and an `en` page in a `de` browser reproduces it
today. It **cannot** exercise hreflang alternates (nothing to alternate with),
`x-default` in its meaningful form, or RTL — `en` is LTR, and the unmirrored
serialized page A1a argues from is invisible until something RTL is served
statically. Those need a second locale or the second consumer, and a green site
must not be read as a validated API for them.

**The cheap first step, independent of every verdict above.** The origin
constant and `lang="en"` on the generated document are worth doing on this site
whether or not nokre grows a single SSG export — the first is four copies of one
string, and the second is the attribute a serialized page needs regardless of
who ends up owning it. *(Both have since landed: `lang` in item 2, the origin
constant in item 5.)*

---

## Part F — ANSWERED 2026-08-06. These are the round's premises.

Every question below is closed. Nothing in Parts A–D or G reopens one; an item
that appears to is misreading a decision, not finding a gap.

1. ~~**Does the original static-site-driver kill still stand?**~~ **No such kill
   existed** — see "The killed item, recovered" above. Round two logged the full
   driver as an undecided owner call and killed only A10.4, a narrow
   document-shell helper, because two thirds of what it proposed to own were the
   driver's own inventions. What that kill supplies is a *test*, not a verdict:
   an item asking nokre to own something the consumer invents dies the way A10.4
   died; an item where nokre already owns the fact and merely fails to export it
   is the opposite case. **That test still binds even under 2 below** — a full
   driver may own the document, but mount-point ids, an addressing mode and a
   path scheme are still driver-supplied *parameters*, never nokre's inventions.

2. **Where is the line? — FULL STATIC-SITE DRIVER.** nokre grows the per-route
   loop, the document shell, meta/canonical/OG emission, the locale axis,
   hreflang and sitemap alternates. Part C's middle position was considered and
   declined; the derivations-only split is not this round's shape. The
   counter-argument in Part C — that a GUI library emitting sitemaps has stopped
   being a GUI library — was heard and overruled, and the ground is Part C's own
   evidence: five moves in one round, all one direction, every one justified by a
   driver having gotten it wrong. The second consumer is not going to get 4,250
   pages of hreflang right by hand either.

3. **`lang`/`dir` on a generated document — a DIFFERENT question, and nokre
   stamps BOTH.** The embedded-app refusal (`stylesheet.zig`'s `sheet`,
   mirrored-chrome comment) is unchanged and still binds: an app must not turn
   its host around. A generated document has no host — nokre wrote the whole
   file — so Part A's asymmetry note is the resolution, not a loophole.
   `docs/localization.md`'s "Right-to-left" line stands as written about runs of
   text; it was never about a document nokre authored end to end.

4. **Default-locale path scheme — PREFIX ALL, including the default**, plus a
   sniffing stub at every unprefixed path. Settled after checking what a prefix
   actually costs deep links, which is **nothing on the static web path**: the
   web leg of `deep_link` is fragment-only (`src/services/deep_link/web.zig`'s
   `nokre_deep_link_receive`, fired from `live.js` at load and on `hashchange`),
   and under `addressing: "documents"` `live.js`'s `hashchange` handler returns
   immediately — *"a fragment there names a heading on the page the reader is
   already on."* The path is the screen and it comes from the driver's `Refs`.
   The rules, in full:

   - Every page lives at `/{locale}/…`. No bare-default variant exists.
   - **A prefixed URL is never redirected.** `/en/x` stays English in a Persian
     browser. Anything else means one URL shows different content to different
     readers, which breaks sharing and canonicalisation both.
   - **An unprefixed path gets a sniffing stub**: resolve `navigator.language`
     against the bundled locale set (`L.resolve`, the same function `mount`'s
     boot already runs the device tag through), fall back to `L.default_locale`,
     `location.replace`. Static hosting can neither read `Accept-Language` nor
     serve a 301 — GitHub Pages has no redirect rules — so the stub is a page,
     not a header.
   - The stub renders plain per-locale links behind the script, so a reader with
     no JS is offered a choice rather than stranded on a blank page.
   - `x-default` points at the stub.
   - **Native App Links are the one place a prefix does bite**, and the answer is
     consumer-side: rokovski's handler strips a leading locale segment and
     honours it via `App.setLocale`, falling back to the device locale when
     absent, so a shared link opens in the sharer's language in the app exactly
     as it does on the web. No nokre change; `L.resolve` already exists.

   The deciding argument is that hreflang and canonical *require* one URL per
   locale variant. A locale-less URL for 4,250 statement pages has nothing to
   alternate with.

5. **Yes — the boundary rule gets a consumer-facing doc.** `src/testing/audit.zig`'s
   `Options.skip` doc comment already states it as a rule; it gets promoted out
   of a test helper and restated beside what this round actually shipped. Written
   last, describing built code rather than intent.

**Part E is out of scope for this round** — both groups. Round three's
performance work and the residue bullets stay filed as evidence, untouched. They
are not deferred *by* this round's decisions; they simply were not taken up.

**Part G runs, with the URL move.** Decision 4's sniffing stubs dissolve Part G's
one stated cost — the objection was that *"every inbound link and every cross-doc
fragment in `docs/` breaks"*, and a stub at each old unprefixed path means none
of them do; they land on the right locale instead. So `getnokre.github.io` takes
a locale axis of one, its pages move to `/en/…`, and ~20 stubs preserve the old
paths. Part G's honest-about-which-half paragraph still stands: this exercises
the axis, the loop, the path scheme, `lang` on a generated document and A1a's
hydration handover, and it exercises **neither** real alternates nor RTL.

---

## The execution queue

Ten items, strictly sequential, one commit each. Contract changes bump
`nokre.revision` and move all three pins in the same pass. Each item is deleted
from this file as it lands, with its outcome recorded.

9. **Part G** — `getnokre.github.io` onto all of it. **What items 6 and 7 left
   ready for it:** the ~20 stubs are `dom.localeStub` calls over a single-locale
   bundle, and the identity case needs no special branch — the self-address guard
   is what stops a stub at its own address from spinning. The `/en/…` prefix is
   entirely `links.zig`'s and `outPath`'s; nokre computes no path. `failOnStale`'s
   walk is scoped to two shapes that both gain a locale segment. `writeExtras`
   already calls `dom.Sitemap` and its call does not change when the axis
   arrives — only the `&.{}` alternate set becomes a real one. The ~20 hardcoded
   English titles in `src/pages.zig`'s `all` become catalog keys against a
   one-locale bundle, which is the part with no precedent yet in this round.
10. **The boundary doc** — F.5, written from what shipped.

---

## Landed

### 8. `webIndexHtml`'s `lang` — SHIPPED as `Web.lang`, revision 40. Unification refused.

**The open question is answered no, and the ground is layering rather than
taste.** `webIndexHtml` is not called from an app or a driver — it is called
from **build.zig itself** (`addPkgTree`), which does
`const packaging = @import("src/packaging/packaging.zig")` and runs it in the
build runner. `driver_files.zig`'s own module doc already states the rule that
follows: *"a leaf module with no imports because build.zig is one of the readers
— the build script cannot import anything that reaches the rest of the
library."* `document.zig` imports `core/app.zig`, `serialize.zig`, `color.zig`,
`class_names.zig` and `element.zig`. Unifying would put the whole core+render
stack inside the build script.

**The "no `App` in hand" obstacle is not an obstacle, it is the shape of the
thing.** `Emitter` holds an `*App`; `App.init` wants a text measurer, a `Router`
over a route table, a `workers.Runtime` with threads, and a `Services`. There is
no App to be had at build-graph time and no honest null one to make, and
`document` then calls `serialize.chrome`/`serialize.content` over it — so
`Document` would need a no-screen mode on top of a one-mount mode, which is
exactly *"a shape that exists only to serve a page with no screen in it."*

**A third obstacle the queue entry did not name, and on its own it is
decisive.** The shell page's whole reason for existing is a
Content-Security-Policy that must precede everything it governs — including the
two `<link rel="stylesheet">` tags. `Document`'s one head seam is spliced at the
*end* of the head, after `headOpen` writes the title and the stylesheet link,
and it is documented that way for the charset-first rule. Unifying would mean a
second head seam whose only user is this page.

**Precedent, already recorded in the file itself.** `document.zig`'s module doc
explains why `localeStub` — a page far *closer* to `Document`, sharing
`headOpen` and holding a real `Emitter` — is *"a second writer instead of a flag
on `Document`."* The shell is one step further out.

**The boot script had drifted, and finding that was worth more than the
`lang`.** `webIndexHtml` writes no boot script — the CSP forbids inline
`<script>`, so it links `boot.js`, which `webBootJs` writes. That file typed
`"./live.js"` by hand, which is precisely the failure `driver_files.entry` is
data to prevent (*"the only file name that ever leaves the set… a driver joining
it to its own directory never types it"*). It now imports `driver_files.zig` —
legal exactly because that module is the documented zero-import leaf build.zig
already reads. The emitted bytes do not move.

**What is *not* drift, checked and recorded:** `webBootJs` escapes through
`jsonEscapedAlloc` where `document.zig` uses its private `js` with `\x3C`. That
difference is correct — `boot.js` is a module *file*, where `</script>` is three
characters of nothing; the `<` rule exists for an inline block. And the call
pins no `locale`, `content`, `route` or `addressing`: all four are right for a
one-mount page with no screen in it.

**The device-lane check: item 3's claim holds, verified in `live.js`.**
`const pinned = typeof locale === "string"` — an absent `locale` reads
`navigator.language`, and the `languagechange` listener is installed only on
that lane. The shell boots into an empty body, so there is no generated markup
for the device to disagree with, and following the reader is right. The
*residual* is the attribute, not the boot: `syncRoot` stamps `data-appearance`
and `data-direction` and never `lang` (zero hits in that file), so a static
`lang` cannot follow a boot that resolved elsewhere. One shell serves every
reader; no single value is right for all of them. That is stated at the field.

**`lang` lives on `Web`, not `Decl`.** `Decl` is the cross-platform identity
twelve emitters read; a language tag would be a field eleven of them ignore.
`Web` is already *"the web half of the declaration, as packaging reads it."*
`build.zig`'s `AppOptions` gains `web_lang`, whose default is
`(packaging.Web{}).lang` rather than a third literal.

**The default is `element.default_chrome_tag`'s claim, not a second answer.**
`"en"` here means what `langTag` says it means — the language nokre's own nav
bar, close control and notices pane are in on an app that never localized —
which is the narrowest true statement a page with no app behind it can make.
The constant cannot be imported (build.zig reads packaging), so the two
spellings are held equal by a test that can see both, the way `class_names.zig`
handles a fact the compiler cannot follow. The value is escaped through
`xmlEscapedAlloc` like `Decl.name` beside it.

**Every HANDOFF claim in the item checked out**, including "nothing in the site
tree imports `packaging`" and "no rokovski app reaches it" — the only hit in
either tree is the word "packaging" in one of the site's own blurbs. The
emitted `zig-out/web/index.html` and `boot.js` are byte-identical to the
previous revision, which is what a default that changes nothing should look
like. Three tests added: the default against core's constant, a declared tag
that moves exactly one line of the page, and an attribute-closing tag that does
not escape it.

### 7. hreflang, `x-default`, sitemap alternates — SHIPPED, revision 39

**The survey's pure function became a type, and the reason is item 6's
precedent.** `Alternates(L)` (`src/render/dom/alternates.zig`) takes
`paths: EnumFieldStruct(L.Locale, []const u8, null)` — one required field per
bundled locale — so a locale in the ARB set and missing from an alternate set is
a **compile error**, and one the bundle does not carry cannot be written down at
all. The completeness invariant B2 asked nokre to own is therefore not checked;
it is unstatable-wrongly. `LocaleStub.choices` is literally the same shape with a
label attached, which is what made the precedent obvious.

**Reciprocity turned out not to need enforcing.** B2 named it as the invisible
failure — one page listing a sibling that does not list it back. But a page's
alternates are its *own* variants, so one `Set` value serves the whole family and
every copy of a route carries a byte-identical block. There is no per-page
derivation left to disagree with itself. Self-inclusion is the other half and
*is* checked (`alternates.check`), because only the document knows which of the
paths is its own.

**`x-default` is a required field separate from `paths`**, and that separation is
the item's sharpest decision. The mistake this whole block gets written wrong by
is treating `x-default` as the default locale's URL; making `stub` required means
a driver cannot omit it and silently inherit the template's path. Nothing in the
module reads `L.default_locale`.

**The sitemap landed on the derivation side without crossing item 6's line.**
`Sitemap` (`src/render/dom/sitemap.zig`) builds bytes into the caller's buffer
and the driver does the `writeFile` — the shape `stylesheet.write` already has,
and the line drawn when the per-locale generation loop was refused: nothing under
`src/render/dom` reaches a filesystem. B3's constraint is satisfied more strongly
than it asked: the head's block and the sitemap's `<xhtml:link>`s are not two
derivations that agree today, they are one `Set` value handed to two writers.
What the sitemap owns beyond that is what one file can see and one page cannot —
XML escaping, the `xhtml` namespace declared exactly when used, the spec's two
limits, and the alternate graph **closed**: every sibling any entry names is
itself an entry. No per-page function could run that check.

**`lastmod` and `changefreq` refused, and the ground is recorded so the next
round does not re-propose them.** `changefreq` is publishing policy Google has
said for years it does not use. `lastmod` is a filesystem or VCS fact the library
cannot know *and cannot check* — its grammar is W3C-datetime, an unparseable one
is dropped in silence by every crawler, and the shape a hand-rolled generator
actually ships is the build's own clock stamped on all 4,250 URLs, telling a
crawler the whole site changed every deploy. Worse than absent. A consumer with
real per-page timestamps is a receipt this library does not have yet.

**Single-locale sites emit no alternates, and that is principled.** An empty set
is not checked and is not a defect: a page that exists in one language has no
choice of URLs to describe, and its canonical already says everything there is to
say about where it lives. `getnokre.github.io` passes `&.{}` and its
`writeExtras` call is already shaped so the locale axis does not change it.

**Process note, recorded because it cost time.** The implementing agent died to
API errors twice — once after finishing the code and the consumer migration but
before reporting, once before writing the record. The code was reviewed directly
from the diff instead of from a report, and the doc track was finished by a
second agent with the source frozen. Nothing was accepted unread.


One entry per finished item, with the ground for anything that changed shape.
The queue above shrinks as this grows.

### 6. The locale axis — SHIPPED as one page, revision 38. The loop was refused.

**The open question this item asked — "is the loop worth owning at all?" — is
answered no, and the stub is what was worth owning.** B1's own arithmetic is
right: a generation pass is four lines over a set nokre already enumerates
(`std.enums.values(L.Locale)`, `setLocale`/`setDirection`/`setChrome`, write).
What a library loop would have had to own beyond those four lines is the
output paths, the directory layout and the file writing — which is not a
document shell, it is the build — plus a callback for everything a real
generator does per page: the a11y audit, `takeAnchors` for the link check, the
per-page canonical, the seed URL, the stale sweep. What it would have saved is
the `for`. F.2 put the document in the library and this does not reopen that;
it draws the line at the file system, where nothing in `src/render/dom` has
ever reached.

**B4 is decided and not built, deliberately.** Prefix-all is settled (F.4) and
it is *policy the driver executes*: `Refs.resolve` already returns `/fa/…` for
any route, so the URL half was expressible before this item, and F.1's test —
an item asking nokre to own something the consumer invents dies the way A10.4
died — applies to a path scheme by name. nokre computes no path here and
carries no prefix anywhere. The refusal is recorded in dom-edition.md rather
than only here, since the next round will otherwise re-derive it.

**What shipped is `dom.localeStub(em, L, …)`** — the page at every unprefixed
path, the one thing on the axis that has no home in a driver and is
wrong-by-hand in ways nothing reports. `document.zig` writes it (the same
file, sharing `headOpen` so the charset-first rule keeps one enforcer), and it
is a second writer rather than a flag on `Document`: no mount points, no
`data-n`, no boot, no screen, and no locale of its own.

**It takes the bundle, not a list of tags, and that is the whole answer to
B1's sharpest constraint.** `choices` is `std.enums.EnumFieldStruct(L.Locale,
Choice, null)` — one required field per bundled locale — so the completeness
invariant is a *type*, not a check: a bundled locale missing from a stub is a
compile error, and a locale the ARB set does not carry cannot be written down
at all. The tags themselves are never re-typed by the driver; `L.tag`/`L.dir`
supply them. There is no `Site.locales` anywhere and no second source of truth
to disagree with the catalog.

**The destinations and the words stay the driver's**, item 5's line held
exactly: an href per locale (the resolver's answer, copied) and a label per
locale (a language's name in its own language is content, and this library has
no catalog of them). What nokre checks is what a driver gets wrong about the
pair it supplied — a choice with no destination, a choice with no words, and
**two locales at one address**, which makes one language unreachable and hands
its readers the other's. All three refuse before the doctype, `checkMeta`'s
reason, and a test asserts the buffer is empty after a refusal.

**The resolution is the bundle's, transcribed once and gated.** This is the
one place in the library where a decision nokre owns is stated in two
languages, and it could not be avoided: `Bundle.resolve` is comptime Zig and
the stub loads no wasm on purpose — a redirect that first fetches an app is a
redirect nobody waits for. So `src/render/dom/locale_stub.js` repeats the
algorithm *in the library* (exact tag, then bare language in bundle order,
then `L.default_locale`) over tags the bundle hands it, and the driver states
no part of it. Three alternatives were considered and refused:
`Intl.DateTimeFormat.supportedLocalesOf` with `localeMatcher: "lookup"`, which
is RFC 4647 truncation and genuinely disagrees — `zh-Hans` against an
`en`/`zh-Hant` bundle is `zh-Hant` under `resolve` and the template under
lookup; a driver-supplied matcher, which is a second policy by construction;
and shipping the function as a fifth `driver_file`, which costs a network
round trip before a redirect and a 404 that fails silently.

**What holds the transcription is a gate, not a comment.**
`tests/locale_stub.zig` (native, host-run like the dev store and the http
stress) writes one real stub page plus the locale `L.resolve` gives for 27
device tags; `tests/locale_stub.mjs` executes **that page's own script** once
per tag against a `location` and `navigator` of its own and asserts it
navigates where Zig said. Neither file states an expected locale, so a change
to the resolution rule moves both sides at once and a change to one alone
fails the build. The same run asserts the no-JS half (a plain link per locale,
marked with its `hreflang`) and two properties a hand-rolled redirect drops
silently: the query and the fragment reach the destination, and a stub
standing at one of its own choices navigates nowhere rather than spinning the
browser. `zig build test`'s new line is
`locale stub: 27 device tags, 3 locales — all ok`.

**Three locales, and the third is what makes the gate a gate.** The first cut
of this reused the web harness's `en`/`fa` pair, and that bundle cannot reach
`resolve`'s middle pass in any interesting way: bare language **in bundle
order** has one candidate when no two locales share a language, so
`findIndex`, `findLastIndex` and an object's own key order all pass — and the
one branch where a transcription could silently disagree was the one branch
nothing executed. It is also exactly the branch where `Intl`'s lookup matcher
was cited above as differing. So the gate has a bundle of its own,
`tests/l10n/stub_*.arb`, listing **`fa-AF` before `fa`**: a browser reporting
`fa-IR` then has two candidates and must land on the *earlier*, which is the
answer a backwards scan or a bare-tag preference gets wrong. Not folded into
`webcheck_*.arb`, on the owner's ground: that pair is item 3's locale-service
gate and giving it a third locale would change a test to serve this one.
Proven by breaking the ordering and watching it fire —
`a browser reporting "fa-IR" was sent to https://nokre.test/fa/docs/, where
L.resolve says https://nokre.test/fa-AF/docs/` — and, because a gap like this
must not be able to return silently, the mjs also asserts that some probe
*reaches* the contested pass at all and that Zig's answer for it really is the
earliest candidate. That guard was proven too, against a thinned table: `no
device tag in the table reaches the bundle-order pass with more than one
candidate — the branch is untested, whatever the assertions above say`.

**Three smaller calls worth recording.** The stub is in *no* locale, so its
root element takes the template's — the language the script falls back to, so
the document a reader passes through claims the language they are about to be
sent to — and a test pins that against an app left in `fa` by a generation
loop. It reads `navigator.language` and not `navigator.languages`, because the
single tag is what live.js's boot pours into the locale service and the list
would be a *disagreeing* answer between the stub and the page it lands on. And
it stamps no `data-appearance`: no app boots here, so the media query is all
the page has and is exactly right (`stylesheet.zig`'s `write`).

**Considered and left out: a `L.select(app, loc)` for the loop's three
setters.** Forgetting `setDirection` is a real silent defect — item 3's own
finding — but `chrome(locale)` is a compile error in any bundle without the
reserved chrome keys, so a three-in-one call would force chrome keys on every
catalog whose app wanted it. A two-line version was not worth an export the
documented three lines already give.

**The script's bytes.** `@embedFile`d and written inline, so it ships in no
site directory (the site's driver byte count is unchanged) and is parsed by
the existing js gate as a sixth file. Its comments were cut to a nine-line
header on the one-home rule — every argument in them was already in
`localeStub`'s doc comment, and these bytes are on *every* stub page, where a
paragraph is a paragraph per page. A stub is 1,934 bytes.

**No consumer change beyond the pin, and that is correct.**
`getnokre.github.io` takes its locale axis at item 9; migrating it here would
have been item 9 done early and its URLs moved twice. **Site: 32 screens, 803
references (798 → 803, the five new links being this pass's own doc
cross-links), 1,051,573 bytes of markup.** Every byte accounted for: **+7,226**
on the dom-edition page and **+2,126** on the testing page and **+668** on
localization — this pass's documentation — plus **+5,835 / +1,909 / +575** on
their copied Markdown; **+27** on the colophon's provenance stamp; and **+3**
net across six pages from NodeId-derived values changing digit count, because
a longer doc moves the pool's generation for the pages built after it.
Normalizing `data-n`, `aria-labelledby="field-…"` and the radio groups' `name`
leaves a diff of exactly the three doc pages and the colophon stamp.
`sitemap.xml`, `robots.txt`, `style.css` and `favicon.svg` are byte-identical
and **no file was added, removed or renamed** — which is the proof the URLs did
not move.

**What item 7 needs to know.** The stub is where `x-default` points, and its
head seam is how a driver puts alternates on it today — if item 7 grows an
alternates block for `Meta`, the stub wants the same treatment rather than a
second shape, and it already holds the bundle needed to derive the set. The
completeness invariant item 7 owes ("every bundled locale, exactly once") has a
precedent here and it is a type rather than a check: prefer
`EnumFieldStruct(L.Locale, …)` over a slice plus a runtime sweep. **What item 9
needs to know**: the site's ~20 stubs are `localeStub` calls with a
single-locale bundle, so every stub resolves to the one locale and the guard
against a stub at its own address is what keeps the identity case from
spinning; the `/en/…` prefix is entirely `links.zig`'s and `outPath`'s to
write, and `failOnStale`'s walk is scoped to two shapes that both gain a
locale segment.

### 5. Canonical, Open Graph, the Twitter card, `og:image` — SHIPPED, revision 37

**`Document.meta: ?Meta`**, written by `document.zig`'s `metaTags` into the head
before the driver's seam. A2 and A4, one struct.

**The objection was honoured, not overruled, and this is the whole design.**
`audit.zig`'s `Options.skip` says a document destination is the site resolver's;
F.2 says nokre grows the document shell. Both hold, because **nokre took the
invariants and left every destination a required field with no default and no
derivation**. `Meta.origin` is config this library cannot know or guess;
`Meta.path` is the resolver's answer, copied; `Meta.Image.path` likewise. The
word "route" does not appear in the block, no path is computed from anything,
and grepping nokre for the reference site's host still returns zero. What the
library owns is the four things a driver gets *wrong* about destinations it
supplied:

- **`og:url` is the canonical**, because `path` is one field written twice.
  There is no second field to keep in step, so "they must match" is not a rule
  anybody can break.
- **Both are absolute**, because both are `origin ++ path` — and `checkMeta`
  runs *before the doctype*, so a missing scheme, a trailing slash on the origin
  or an unrooted path is `MetaError` and an empty buffer rather than a
  half-written file.
- **A page with no URL of its own has neither tag.** `path: ?[]const u8`, and
  the shape is the point: a string with an `indexable` flag beside it is exactly
  how a 404 keeps claiming `/notfound/` after somebody flips the boolean and
  leaves the string. Here there is nothing left to leave.
- **`property=` for Open Graph, `name=` for Twitter**, asserted as a sweep over
  the finished head so a tag added later cannot arrive with the wrong one.

Enforced by construction: the identity, the absence, the vocabulary, and
"no image ⇒ `summary`" (the shape lives *on* the image, so a large-image card
with an empty frame is unstatable). Enforced by check: the origin's scheme and
the paths' leading slash. Enforced by documentation only: that the path a driver
supplies is the one the site actually publishes — which is the resolver's
authority and stays there.

**The Twitter card is one tag, and that is the finding.** Twitter documents an
Open Graph fallback for `twitter:title`, `twitter:description` and
`twitter:image`, so the four-tag block every hand-rolled head carries — the
incoming consumer's `Base.astro` included — is four more copies of strings
already on the page, and the copy is the defect. `twitter:card` has no `og:`
twin and is the reason a card renders at all, so it is written whenever Open
Graph is. The one exception is `twitter:image:alt`: Twitter documents no `og:`
fallback for the alternative text, and a reader who cannot see the picture being
told nothing is not a trade this library makes to save a line.

**`og:image` is `Meta.Image`, nested deliberately.** A4 insisted this is not an
image-element request; `dom.Image` at the edition's surface would have read like
exactly that, so the type is reachable only as `Meta.Image` and `dom.zig` says
why. Its `shape` (`banner` / `thumbnail`) is stated rather than derived from
`size` — which crop an asset survives is editorial, and a threshold on the aspect
ratio would be this library guessing at someone else's artwork. `size` is one
optional `Pixels` pair rather than two numbers, so a width without a height is
not statable; it exists because a crawler that has fetched neither the file nor
the dimensions can show a first share with no picture at all, and losing it would
have been the migration losing something Astro expresses.

**`og:locale` was considered and refused, on a nokre-shaped ground.** The page's
language is a fact `document.zig` already holds — it is on `<html lang>` four
lines up — so this looked like A10.4's surviving half. It is not: Open Graph's
locale is `language_TERRITORY`, and a BCP 47 tag need not carry a territory, so
`fa` would have to become `fa_IR` or `fa_AF` and picking is inventing a fact
nobody stated. `og:locale:alternate` would have been item 7's anyway.

**Consumer migrated in the same pass, and the head seam is now two lines.**
`writeHead` is a favicon and a font preload; the canonical, the four `og:` tags
and the `not_found` guard went into the `dom.document` call. The site gained a
Twitter card it never had (`summary`) and **no `og:image`**, which is the honest
answer and worth having as a proof: the favicon is a 32px SVG and no card
renderer draws one, so `image = null` is the API expressing "this site has no
artwork" rather than a gap.

**Part G's count of four is right, and there is a fifth occurrence that is not
one.** `const origin` in `main.zig` now serves the canonical, the `og:url`, the
sitemap `<loc>` and robots.txt's `Sitemap:` — four copies collapsed, taken here
because `Meta.origin` needed one anyway. `content.zig`'s `qr` example also
carries the string: that draws a QR code *of* this site on the elements page,
which is content a reader points a camera at and not a destination the document
claims. It is deliberately not wired to the constant, and there is a comment at
the constant saying so.

**Considered and left out: `noindex` on a path-less page.** It is derivable from
`path == null` and it is the natural companion — but a robots directive is
crawling policy, which is the site resolver's in exactly the sense the rule
protects, and this item was not asked for it. Filed here rather than skipped
silently.

**Site numbers.** 32 screens, 798 references (797 → 798, the one new link being
this pass's citation of `audit.zig` in dom-edition.md), 1,041,550 bytes of markup
(1,036,655 → 1,041,550). Every byte accounted for: **+45 on all 32 pages**
(`<meta name="twitter:card" content="summary">` plus its newline) and a head
reordering with no additions or removals, since nokre's block now precedes the
driver's seam; **+3,489** on the dom-edition page and **+2,770** on its copied
Markdown, which is this pass's own documentation; **+28** on the colophon's
provenance stamp; and NodeId-derived values shifting on `gallery` — the radio
groups' `name="c…"` and the select's `field-…` ids — because a longer doc moves
the pool's generation for the pages built after it. Normalizing those three
classes leaves a diff of exactly the colophon stamp and the dom-edition content.
`404.html` gained the card and **neither** destination tag, which is the
`path = null` branch read out of the published file. `sitemap.xml`, `robots.txt`
and `favicon.svg` are byte-identical.

### 4. `Emitter.json` — SHIPPED, revision 36

**One method, one byte, and no new type.** `Emitter.json` takes a JSON
document the caller already serialized and writes it wherever the emitter
points, with every `<` as `\u003C`. That is the whole export. A3's own
"Against" paragraph predicted this shape — *"a documented one-liner is a fine
resolution"* — and having read the alternatives it is also the right one.

**What was rejected, and why.** A wrapper that takes a *Zig value* and
serializes it was the bigger contract on offer, and it buys nothing: it would
put this library in charge of whitespace, `escape_unicode`, field naming and
optional-field policy, all of which `std.json.Stringify` already decides better
than a GUI library has any business deciding. So the contract is the narrow
half — you serialize, nokre makes it safe to put in a `<script>`. A free
function was the other candidate and lost to discoverability: the whole lesson
of the item is that the escape belongs to the *destination*, which is a
statement about the emitter, and a driver author reads `text` and `raw` before
it reads anything else. And the method deliberately does **not** write the
`<script>` tags. `href`'s precedent does not transfer — that seam was closed
because the emitter had opened a quote the driver would have had to close,
where here the driver opens and closes a tag nokre never touches — and owning
the tag would have forced either a `type` parameter (a driver passing a
JavaScript type gets its structured data *executed*) or a hardcoded MIME, which
is a decision this item does not need to make.

**`js` stays private, and the two do not collapse.** They share the second half
of one argument and nothing else: `js` writes the inside of a *JavaScript
string literal*, where the escape is `\x3C`; JSON has no `\x` escape at all,
so the same character is `\u003C` here. One function would produce output valid
in exactly one of its two destinations. There is also no caller to export it
for — the boot script is the library's own, and a driver handing it executable
JavaScript would be writing a `<script>` this edition supports no other way.
That is now written at `js` itself, so the next reader does not re-open it.

**Exactly one byte, and the evidence is the tokenizer's.** A `<script>` block's
data state is left on `<` and on nothing else, so every way out starts with one:
`</script` ends the element, `<!--` opens the escaped state — in which a later
`</script>` *stops* ending it, so two innocent strings on one page swallow the
rest of the document between them — and `<script` inside that opens the
double-escaped one. That last pair is why the rule is `<` and not `</`. Two
bytes are deliberately left alone: `&`, because raw text decodes no character
reference (which is the same fact that makes `Emitter.text` the wrong escape
here, not merely a redundant one), and U+2028/U+2029, because what they break is
JavaScript *source*, and only before ES2019 — a block whose type is not a script
type is never parsed as source, and in JSON they are ordinary characters.

**`std.json` checked, not assumed.** Zig 0.16's `Stringify.encodeJsonStringChars`
escapes `"`, `\` and `0x00`–`0x1F`, plus everything above `0x7E` under
`escape_unicode`. `<` is in neither branch. So the premise A3 stated — that
`</script>` survives `std.json` intact — is exactly true, and the test asserts
it as a receipt rather than repeating it as a claim.

**The test is the CSP sweep, asked at a different destination**
(`serialize_test.zig`, *"no byte a consumer supplies can end a script block"*).
The three hazards by name; then every codepoint the low 256 hold, in the middle
of a string value, through a real `std.json` document — two properties per byte:
no `<` survives, **and** the output parses back to the value that went in. The
round trip is what makes the first property worth having, because it proves the
escape is value-preserving and not just safe. Plus a key carrying `</script>`
(the pass is over the finished document, not over one value) and the two
non-escapes asserted as bytes. Checked by breaking `json` and watching it fire.

**Nothing in either consumer tree uses it, and that is correct.** Zero
occurrences of `ld+json` in `getnokre.github.io` or in either rokovski app,
before this item and after it. The reference site emits no structured data and
has no reason to; inventing a JSON-LD block for it to exercise the escape would
have put content on that site to justify a library function, which is backwards.
This is a capability shipped for the second consumer, and the sweep is the proof.
The only consumer change in this pass is the three pins.

**The doc line, reshaped by item 2 as the brief said it would be.**
`dom-edition.md`'s "The seams" gains the statement that `raw` is the sanctioned
writer for a block the library has no element for — *inside a fragment handed
over at `Document.head`*, which is the honest guidance now that the head seam is
bytes. The sanction is the seam's and not the function's: `raw` on the document
emitter between two elements the walk wrote is going around an escape, not
reaching a place they do not go. The byte-level argument stays in one home, the
`json` doc comment; the seam statement stays in the other.

### 3. The boot handover carries the page's locale — SHIPPED, revision 35

**`mount({ locale })`**, and `document.zig`'s boot script writes it. A page
generated in Persian and opened in an English browser now boots in Persian —
words, `L.dir` and all — because the tag `live.js` pours into the locale
service's seed lane before boot is the page's where the page named one, and
`navigator.language` only where it did not.

**Every claim in the brief checked out**, with one correction and one addition.
`mount` had no locale option; the boot section poured `navigator.language`
through `nokre_locale_scratch` / `nokre_locale_seed` strictly before
`nokre_dom_boot`; `services/locale/web.zig` is where it lands and what
`App.init`'s install fires with; `sameNode` returns `true` for every text node
before it looks at anything else and `patchNode` then assigns `a.data = b.data`,
so the diff succeeds and every string is swapped in silence.

**The correction is the direction half, and it is worse than "reverts to
LTR".** `live.js` writes `data-direction` and never `dir` (item 2's finding,
unchanged), so a wrong-locale boot over a Persian page left `dir="rtl"` standing
in the markup and flipped `data-direction` to `ltr` underneath it — the page
announced right-to-left to a screen reader and laid out left-to-right, which is
neither of the two states and is the one no reader can explain. The same channel
closes it, because direction is `App.setDirection(L.dir(loc))` and follows
whatever locale the app resolved.

**Where the override enters, and why it could not be anywhere later.** The app's
own three lines are `L.resolve(locale.tag(app))` → `setLocale` → `setDirection`
(docs/localization.md). Anything entering *downstream* of that — a boot argument
calling `App.setLocale` for the app, a `Options.locale` — is overwritten by the
app's next build, which re-resolves from the service and wins. So the channel is
the service's own seed lane: the shell's answer to "what language is this app
in", which on the web is the page when the page is nokre's own. `L.resolve` is
therefore untouched and no second resolution policy exists — a pinned tag the
bundle does not carry falls back exactly where the same tag falls back on the
device lane, and there is a scenario asserting the two land on the same value.

**One fact, spent twice, in one place.** `document` reads `App.locale()` once
and hands the same slice to the root element's `lang` and to the boot call.
There is deliberately **no `Boot.locale` field**: a driver has no second locale
to state, so the two cannot disagree by construction rather than by a driver
keeping them in sync — which is the defect one layer up.

**The one place they legitimately differ, and it is not a hole.** `lang` keeps
item 2's fallback (`element.default_chrome_tag`) because `lang=""` is not
something a browser, a screen reader or a hyphenation table can act on. The boot
pins `App.locale()` **raw**, empty tag included. Pinning `"en"` there would boot
the *English* catalog of a bundle whose template is Persian over a page that was
rendered from that template — the exact defect, re-introduced by the fallback.
`""` is the tag `L.resolve` answers with the template, so it reproduces the page.

**And it is written even when empty**, which is the call worth recording. An
*absent* `locale` is `mount`'s "follow the device", and that is right for exactly
one page: the app shell that boots into an empty body (`packaging.zig`'s
`webIndexHtml`, which pins nothing and is unchanged). Every generated document
has a screen in it already, so the device can never be the right answer there —
including for an app that never called `setLocale`, whose page was rendered from
its catalog's template. `typeof locale === "string"` is the test, so `""` is a
value and `undefined` is the only absence.

**`languagechange` is not delivered on a pinned page.** The listener is
installed only on the device lane. A reader changing their browser's language is
not a reason for `/fa/…` to become English — F.4's "a prefixed URL is never
redirected", read from inside the page.

**Proved at the web gate, not argued.** `tests/web_browser.mjs` already took a
`language`; it now also has `languageChange(tag)`, and `page(env, options)`
splits the browser from what the page hands `mount` — the two are separate
because the whole question is what happens when they disagree.
`tests/web_services.zig` grew a real two-locale ARB bundle (en template, fa for
RTL) and writes the documented three lines, so the assertions read the rendered
Persian out of the document and the direction off `documentElement` rather than
asking an export what it returned. Six scenarios: the device lane unchanged; the
page's language beating the browser's, direction included; an `en` page holding
in a Persian browser; the empty tag resolving to the template rather than
meaning "ask the device"; an unbundled pin landing where the device lane lands;
and a post-boot `languagechange` moving the unpinned page and never the pinned
one. The gate's line is now `deep_link, oauth, secure_store, locale — all ok`,
and locale's web leg — which every scenario had been executing unasserted since
it shipped — is a named leg of that gate.

**The queue's line that the site is the reproduction Part G promised is not yet
true**, and the reason is Part G's own: the site has no l10n surface at all, so
its pages render the same bytes in a `de` browser as in an `en` one and there is
nothing to boot wrongly. A reproduction needs an app with a catalog, which is
why it lives in the gate's harness app. The site becomes that reproduction at
item 9, and the channel it will use is already in its published `live.js`.

**What could not be proved here.** Nothing hydrates a *generated document* in
any gate: the harness mounts into an empty body, so the patch over real
generated markup — the silent text swap itself — is still browser-only, and
`docs/testing.md`'s uncovered list now says so precisely instead of listing the
whole handover. What is proved is the fact the handover carries and what the app
does with it, on both lanes, in the real driver.

**The consumer needed no change, and that is the design working.**
`getnokre.github.io` invents no locale, so there was nothing for it to pass:
`dom.document` derives the boot's locale from the same `App.locale()` it derives
`lang` from, and the site's app has never chosen one. Its 32 pages gained exactly
one line each — `locale: "",` — which is that app's honest answer and, until
item 9, the only one it has. Site: 32 screens, 796 references (791 → 796 from
this pass's five new doc cross-links), 1,034,624 bytes of markup.

**Found while writing the test, and fixed.** `docs/services.md`'s `onLocale`
example ended in `state.app.invalidate()`. That does not put a new language on
screen: the words came out of the catalog *inside* `build`, so they are in the
tree the last build left, and `invalidate` only marks it for another layout and
another paint — the same sentences, re-measured. `App.reload`'s own doc names a
locale change as one of its deliberate gestures. The example now says `reload`
and says why. The harness app hit this exactly once, on the one scenario that
changes the language after boot.

### 2. The document shell — SHIPPED, revision 34

**`dom.document(em, Document)`**, a new leaf module
`src/render/dom/document.zig`, writes the whole file: doctype, `<html>` with
`lang` and *both* direction attributes, the head, the two mount points with
`chrome` and `content` inside them, the skip link, and the boot script. Under
F.2 this is a driver, not a helper — the reference site's `writeDocument` went
from ~80 lines of markup to one call plus the two seams' worth of bytes it
actually invented.

**What stayed the driver's, and it is exactly F.1's list.** Every name and every
destination the consumer invented is a field: `chrome_id`, `content_id`,
`content_class`, `stylesheet` (the URL it published the sheet at), `title`,
`description`, `skip`'s words, `Boot.wasm`, `Boot.driver_dir`,
`Boot.addressing`, `Boot.seed`. None of them has a default with an opinion —
`addressing` defaults to `.fragments` because that is `mount`'s own default in
`live.js`, not because nokre prefers it. What nokre writes is the structure and
the facts it holds: the locale, the direction, `rootClass`, `Gray.paper`,
`Router.current` for the boot route, and `driver_files.entry` for the module
name.

**`lang` and `dir`, derived.** `lang` is `App.locale()`. That is `""` until an
app calls `setLocale`, so the fallback is new and is named:
`element.default_chrome_tag = "en"`, beside the existing `default_chrome` — the
language nokre's own nav bar, close control and notices pane are actually in on
a page that never localized. It is a fact about `Chrome`'s defaults, not an
invented default. The reference site (no locale surface until item 9) therefore
still emits `lang="en"`, and now says why.

`dir` is `App.direction`, and **it is two attributes**. `dir` is what browsers
and assistive tech read; `data-direction` is the only thing
`:root[data-direction="rtl"]` matches, so a page stamping one is announced right
and laid out backwards, or the reverse. There is no media query for direction
the way there is for appearance, which is A1a's second argument and is now
answered.

**A claim in the brief was wrong.** The design note said *"`live.js`'s
`syncRoot` stamps both on `documentElement` and is the model."* It does not:
`syncRoot` stamps `data-appearance` and `data-direction`, and **`live.js` never
writes `dir` or `lang` at all** — grep either in that file and there are zero
hits. So there was no model to copy, and the asymmetry is sharper than F.3
stated: the mount case stamps `data-direction` *only*, because `dir` on
`documentElement` turns the host's whole document around and `data-direction`
reaches nokre's own surfaces and nothing else. The static path stamps both
because there is no host. That is now a comment at the write site and a
paragraph in dom-edition.md.

**The head seam is a field of bytes, not a hook** — `Document.head`, with
`Document.body_end` as its twin below the screen. A `fn (em)` hook was refused
on `Refs`'s stated ground (*"a hook that writes `em.out` is re-opening the door
this signature closed"*), and bytes answer A3's actual complaint better anyway:
the complaint was that *nothing in the type distinguishes "into `<head>`" from
"into the body"*, and a named field is that distinction. To build those bytes
with the same escaping the document gets, **`Emitter.fragment(&out)`** returns a
second emitter over a buffer of the caller's own — same app, same allocator,
different `out`.

**The skip link came with its rule, and that was the interesting call.** nokre
writes the anchor (words from the driver, target from `content_id`, class from
the new `class_names.skip`) *and* the sheet now parks it — because an anchor
with no rule behind it is a permanent link across the top of every page, which
is precisely the silent failure `class_names.zig` exists to prevent, and half a
seam is worse than none. Alongside it the sheet gained the only other
document-level rules it has: `@media print` hiding `.nav` and `.skip` and
dropping the chromed root's bottom reserve, which the reference site had been
writing for itself — including one rule that re-typed nokre's `#content` reserve
by id. The modal layers are deliberately left printable.

**`driver_files.entry`** names `live.js` as the one member of the set a page
imports, and the list is built from it. Same argument as the set itself: the one
file name that leaves the library is not re-typed by a fifth writer.

**One thing found by writing it.** The boot script's route was going through
`Emitter.text` in the reference driver — HTML escaping, inside a `<script>`,
where a `&amp;` is five characters of nothing and `</script>` in any of those
strings ends the block. Route names are ASCII identifiers so it never bit, but
the ids and URLs beside it are arbitrary driver bytes. `document.zig` has a
private `js` writer instead: `\\`, `\"`, and `<` as `\x3C`, which closes
`</script>`, `<!--` and `<script` in one rule. Item 4's JSON writer wants the
same treatment and should decide whether to take this public.

**Consumer migrated in the same pass**, per standing practice, and it kept
everything it owns: `#chrome`/`#content`, `addressing: "documents"`, its skip
target, its footer, its `page` class. Every byte of the generated diff is
accounted for: `+31` per page (`dir="ltr" data-direction="ltr"`), a head
reordering with no additions or removals (nokre's fixed tags now precede the
seam so the charset stays in the first bytes), and `+27` on the colophon from
its own provenance stamp. 32 screens before and after; references 791 → 792, the
one new link being this file's own citation of `document.zig` in dom-edition.md.
`docs/style.css` moved exactly the `.skip` block and the two print rules across
the boundary, with `- 16px` becoming `- var(--page-pad)` (same value, now
derived).

**`data-appearance` came along, on the owner's call, and the reasoning is worth
keeping.** It was first filed here as out of scope; it is the same defect as the
direction one, found in the same place, and fixing one and not the other would
have been arbitrary. It is stamped **only when `App.scheme` is not `.auto`**.
The sheet's dark ramp already stands down when the attribute is present
(`:root:not([data-appearance])`), so an `auto` app stamps nothing and keeps the
fallback `stylesheet.zig`'s `write` designed — *"the media query is all a page
with no app behind it has to go on"* — while an app that pinned light or dark
stops having the query overrule it. Both branches are covered, including that
the attribute's spelling is the sheet's own selector rather than a literal
agreeing with itself.

**One carried forward.** `Document` requires both mount ids, which is what
stands between it and `webIndexHtml` (item 8).

### 1. Small exports and stale docs — SHIPPED, revision 33

**Reshaped, and the reshaping is the interesting part.** The class name went out
as **`dom.rootClass(em)`, a function returning the finished attribute value** —
not the one-or-two exported constants this file proposed. Two bare names fail
the criterion they were meant to serve: the sheet's selector is *compound*
(`.nokre.has-chrome`), so a consumer writing the modifier alone matches nothing
at all, and one choosing the wrong branch gets either 96px of dead space under a
plain screen or a nav standing on the text. Handing back the whole list means a
consumer never assembles one; taking the branch from `layout.hasBottomChrome` —
whose own doc comment says *"One predicate, so the two answers cannot drift"* —
means it cannot choose the wrong one either. New leaf module
`src/render/dom/class_names.zig` holds the names as data with the argument in
its module doc, `driver_files`-style.

**The receipt was incomplete in a way that mattered.** This file cited only
*"`stylesheet.zig`'s `sheet`, the `.nokre.has-chrome` rule"*. The sheet names
the root class **seventeen** times — the type base, the tap-highlight, the bidi
and RTL scoping, `min-width`, `overflow-x: clip`, the back control's four rules,
plus two in `writeDerived`'s `comptimePrint`. Splicing only the cited rule would
have left thirteen live transcriptions. All seventeen now derive from the
constants, verified byte-for-byte against the published `docs/style.css`.

**`live.js` is a fourth writer and cannot import a Zig constant**, so
`class_names.zig` carries a `comptime` block that greps the `@embedFile`d JS for
the modifier's spelling and fails the build on drift. The guard was checked by
renaming the constant and watching it fire, not assumed.

**Two claims corrected.** `Router.resolve` is private — what is public is the
`Refusal.Reason.arg_charset` it produces, and B5's doc bullet is worded
accordingly. `dom.zig`'s export list also carries the `serialize` / `stylesheet`
submodules and `DriverSource` beyond the eight named here; the substantive claim
(no class name) was right.

**Consumer migrated in the same pass**, per standing practice.
`getnokre.github.io`'s `writeDocument` takes the list from `rootClass`, and its
print rule — which had retyped nokre's compound selector as
`.nokre.has-chrome` — now names `#content`, the mount point's own id, which is
the site's to name and outranks the class selector anyway.

**B5 and the `introduction.md` phrase shipped alongside**, both as documentation
only. `docs/localization.md`'s "The refusals" gained a **No localized route
arguments** bullet — flagged as the one refusal in that list landing at the call
rather than at compile time, and closing on what it actually costs: the
localized *slug*, not the localized page. `docs/introduction.md`'s *"static text
and images"* is now *"static text and icons"*; `icon` is a real `Role` member
and an image never was.

**One-home violation found and closed while in there.**
`docs/internals/dom-edition.md` stated the class fact in *two* places — "What
the host document owes" and a "The `nokre` class" bullet under "The seams". The
seams bullet is now the home (it is where a driver author reads the API
surface); the host-document bullet states only what is specific to `mount` and
points at it.

---

*Written from the consuming side. Everything above is checkable; check it.*
