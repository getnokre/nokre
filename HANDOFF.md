# HANDOFF — what a static, multi-locale site needs from nokre (2026-08-06)

Status: **SURVEY. Nothing here is executed, and nothing here is settled.**

This file succeeds the third ergonomics round (executed whole; recoverable at
`git show 3855adf:HANDOFF.md`). Parts 0 and A of that round are done through
revision 32 plus `TextInput.disabled`. What was still open there is carried
forward in Part E below, one line each, with pointers rather than copies.

**Verification basis.** The findings below were grep- and read-verified against
nokre `7934318` *plus its working tree* — which has since been committed through
`3855adf` — and against the site at `8db26a7`. Two consequences: line numbers in
`serialize.zig`, `stylesheet.zig` and `element.zig` may have moved under the
`TextInput.disabled` pass, and `nokre.revision` was 32 when surveyed. Check both
before quoting either. Downstream consumer facts come from the rokovski tree as
of `eea6de1a`.

Execution protocol is the standing one: **one item per pass, owner review
between, never chain.** Contract changes bump `revision` and move all three pins
in the same pass.

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
- **Do not chain items to "finish the theme."** The value of most of these is
  independent; the cost of a wrong one is a contract that consumers build on.

The single most likely failure mode for this round is an agent reading it as a
list of features to add and adding all of them. Most of the argument's weight is
in Part C, which asks whether the *category* belongs here at all — and the answer
may legitimately be "some of it, and not the rest."

---

## The owner has reopened a killed item

The previous handoff refers, in Part C item 4, to *"the killed static-site
driver."* A static-site driver in nokre was proposed in an earlier round and the
owner refused it.

**The owner has reopened that question**, and this file exists because of it.
That is a deliberate departure from this file's own standing convention that
nothing re-proposes an owner-killed item.

Two things follow, and both matter:

1. The reopening is real. Do not treat Parts A and B as accidental re-proposals
   and refuse them on adjacency grounds alone.
2. The reopening is *not* a decision. The owner reopened the question after
   seeing a second consumer about to hand-roll the same document shell. If the
   original kill rationale still holds — and this file cannot see it, because it
   lived in a handoff that has since been deleted — then **the right outcome is
   to restate that rationale and kill the items again**, this time in a doc where
   the next round will find it.

If you can recover the original kill argument from git history, do that first.
It is the highest-value ten minutes in this round, and it may end the round.

---

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
belong to the framework or the app. The boundary is drawn three times by
instance and never once by rule:

1. `docs/internals/dom-edition.md:268` — *"What the host document owes, and what
   it keeps"*, then an enumeration. Says what the app owes; does not generalise.
2. `src/render/dom/stylesheet.zig:541-543` — *"the attribute is the driver's to
   stamp, but the page around an embedded app is not this edition's to turn
   around."* Closest thing to a rule, and it is about `data-direction`.
3. `docs/localization.md:400-403`, on a neighbouring question, is the sharpest
   phrasing of the instinct: *"Downloadable translations are a distribution
   feature with a cache, a version skew story, and a failure mode on first
   launch — that is an app, not a GUI library."*

The consuming site states the boundary more plainly than nokre does —
`getnokre.github.io/src/main.zig:4-7`: *"Everything below is the driver: which
screens exist, what a reference resolves to, and the document a browser needs
around a screen. The markup and the stylesheet are the library's."*

**Whatever this round decides, the outcome belongs in a doc.** An unwritten rule
carried by three instances is exactly what let a consumer-side agent confidently
brief the owner on the opposite of what the code says. If the answer is "the
document is the driver's, permanently," that sentence is worth more than any item
in Part A.

---

## Part A — the document shell

Each item: the claim, the receipt, the argument for the library, the strongest
argument against, and what "already solved" would look like.

### A1. `lang` and `dir` are emitted by nobody

**Receipt.** `serialize.zig` emits no `lang` and no `dir` — grep for `lang=`,
`dir=`, `<html`, `doctype` returns nothing; it emits no document at all.
`getnokre.github.io/src/main.zig:372` hardcodes `<html lang="en">`. And
**nokre hardcodes it too**: `src/packaging/packaging.zig:1017` (`webIndexHtml`,
the shell `addWebSite` emits) writes `lang="en"` with nothing parameterising it.

RTL is otherwise nearly complete. `App.direction` (`core/app.zig:69`),
`App.setDirection`, `l10n.directionOfTag` / `L.dir(loc)` (`l10n.zig:302,1106`),
the generated stylesheet mirrors on `:root[data-direction="rtl"]`
(`stylesheet.zig:544`), and the serializer flips chevrons off `em.app.direction`
(`serialize.zig:693,903`). **Nothing stamps `data-direction`.**

**For the library.** A Persian page served as `lang="en"` is wrong for screen
readers, for browser translation, for hyphenation and for search engines — and
nokre already knows the direction. The stylesheet it generates has an RTL branch
that nothing can currently activate. That reads as an incomplete seam rather than
a scope boundary.

**Against.** `stylesheet.zig:541-543` states the refusal deliberately: an
embedded app must not turn the page around it. And `docs/localization.md:155-157`
takes a stronger line — *"There is no `dir` attribute and no per-locale direction
flag in ARB — a Persian string in an English locale and an English string in a
Persian locale each lay out correctly on their own evidence."* If direction is a
property of runs of text rather than of documents, then a document-level `dir` is
the wrong idea and the driver is the right place for the one line that
nevertheless has to exist.

**Note the asymmetry**, because it may be the whole resolution: an *embedded*
app must not restyle its host, but a *generated document* has no host — nokre
wrote the whole file. The refusal may simply not apply to the static path, in
which case this is a one-line fix in `webIndexHtml` plus a stamp in the static
document writer, and the doctrine is unchanged.

**Already solved if:** something parameterises `webIndexHtml`'s `lang`, or a
sanctioned `data-direction` stamp exists that the survey missed.

### A2. Canonical, Open Graph, Twitter card

**Receipt.** The reference driver emits canonical with a **hardcoded origin**
(`main.zig:440`, skipped on 404 at `:436-438`), `og:type` (`:452`),
`og:site_name` (`:453`), `og:url` (`:460`), `og:title` (`:462`),
`og:description` (`:464`), plus `theme-color` for both schemes from
`nok.Gray.paper` (`:447-451`). **No `og:image`. No Twitter card.**

**For the library.** These tags are mechanical, their invariants are easy to get
wrong (`og:url` must equal canonical; canonical must be absolute; both must be
absent on a 404), and the second driver will re-derive all of them. The reference
driver already had to learn "skip canonical on 404" — a second driver gets to
learn it again, or not.

**Against.** It is eight `print` calls. A library that emits `<meta>` tags on the
app's behalf is a website framework, which nokre is not. And the origin is
necessarily config, so the app is in the loop regardless.

**Already solved if:** `packaging.zig` grew a head-writer the survey did not find.

### A3. JSON-LD

**Receipt.** Zero occurrences of `application/ld+json`, `json-ld` or
`schema.org` in either repo, `src/` or `docs/`.

**Split this one.** The consumer needs five graph types (FAQPage, Service +
AggregateOffer with EUR, ItemList, WebPage, Article). Those are content, and
belong to the app. What is *not* content is the emission: a
`<script type="application/ld+json">` block whose payload must be escaped such
that a `</script>` inside a string cannot end the block early.

That escaping is the same class of problem as the CSP `connect-src` injection
you swept 0–255 for in `packaging_test.zig` — and it has the same failure mode: a
consumer building the string by hand gets it right until one statement's text
contains the wrong bytes. Statement text is user-adjacent content in three
languages across 4,250 pages.

**For the library.** The escaper. One function, one test sweep, matching a
precedent this repo already set.

**Against.** Nothing here is nokre-shaped. It is a JSON writer and a `<script>`
tag; `std.json` already escapes. If the answer is "use `std.json.Stringify` and
write the tag yourself," say so in `dom-edition.md` and close it — a documented
one-liner is a fine resolution.

**Already solved if:** the emitter can express a raw `<script>` block safely
today, in which case this reduces to a doc line.

### A4. `og:image`

The reference site emits none. The consumer has one (`/og-image.png`) referenced
only from `<meta>` — no on-page imagery, which costs nothing because the Astro
site has none either. **This is not an image-element request** and must not be
read as one; nokre has no image element and that is settled (Part D).

It is a URL in a tag. It rides on whatever A2 decides.

---

## Part B — per-locale generation

**The owner has flagged this as the part that most needs real support.** It is
also the part where nokre has already moved furthest, which is why it is
tractable at all.

### What already exists

`4876c99` changed `RouteDef.title` to
`Title = union(enum) { fixed: []const u8, of_locale: *const fn([]const u8) []const u8 }`
(`router.zig:213-230`), resolved through `Title.text(locale_tag)` (`:224`), and
gave the App the chosen locale — `App.setLocale` (`core/app.zig:737`),
`App.locale()` (`:758`), `Options.locale` at boot (`:345`). `setRouteTitles` and
`Router.retitle` retired. `128ef2b` added `L.of(app)`, `trAny` for runtime keys,
and `L.chrome(locale)` deriving one reserved key per `Chrome` field at comptime —
so a missing chrome word is a compile error rather than shipped English.
`408d77b` added `Bound.tag()/.dir()/.chrome()` and `L.in(app)`.

**An earlier line in `router.zig:56` reading "Comptime, and a locale is not" is
gone.** A consumer-side brief quoted it as current doctrine last week; it was
already false. Worth knowing that this area moved recently and quickly.

### What is still missing

Routes carry no locale segment and there is no per-locale route *set*. Nothing
generates a tree once per locale, and nothing derives the relationship *between*
locale variants of one page. Concretely:

### B1. The locale axis

A three-locale static site regenerates the whole tree per locale, and each page
needs to know both its own locale and the full set. Today that loop is entirely
driver code.

**The sketch, illustrative only** — the generator declares a locale set and a
path scheme; nokre supplies the per-locale walk and hands each page its locale
plus its siblings:

```zig
// Not a design. The shape of the question.
const site: nok.render.dom.Site = .{
    .origin = "https://rokovski.com",     // config, app's
    .locales = &.{ "en", "fa", "tr" },    // app's
    .default_locale = "en",
    .path = .prefix_all,                  // /en/… /fa/… /tr/… vs. bare-default
};
```

The interesting design question is **whether nokre should own the loop at all**,
or only the per-page derivations (B2, B3) with the driver keeping the loop. The
loop is four lines; the derivations are where a second driver will diverge from
the first. A library that owns only the derivations is a much smaller ask and may
get most of the value.

### B2. hreflang and `x-default`

**Receipt.** Zero `hreflang`, zero `x-default` anywhere in either repo.

Given a route, a locale set and an origin, the alternate set is
`{origin}/{locale}{suffix}` for every locale plus `x-default` — fully derivable,
no app input beyond what B1 already declares. The consumer's existing test
asserts the alternate href set matches *exactly*, both directions, which is
precisely the kind of invariant that is easy to half-implement by hand.

This is the strongest single candidate in the file: mechanical, derivable, no
content dependency, and wrong-by-hand in ways that are invisible until an
international search console complains months later.

### B3. Sitemap alternates

**Receipt.** `main.zig:692-702` emits a flat `<urlset>` of `<loc>` only — no
`lastmod`, no `changefreq`, no `<xhtml:link>` alternates. `robots.txt` at
`:707-708`.

For a multi-locale site the sitemap should carry `<xhtml:link rel="alternate">`
per locale per URL. Same derivation as B2 from the same inputs. If B2 lands in
the library, this is nearly free; if B2 stays in the driver, this should too —
they should not end up on opposite sides of the boundary.

### B4. The output-path scheme

The reference driver maps home → `index.html`, 404 → `404.html`, else
`<route>/index.html` (`main.zig:345-357`). A locale axis multiplies that, and
the default-locale question (`/en/…` versus bare) is a real fork the consumer has
already answered one way (Astro's `prefixDefaultLocale: true`).

Worth deciding alongside B1 rather than after: it determines whether the
canonical for the home page is `/` or `/en/`, which determines what the redirect
stub at `/` must say, which the consumer already has two of.

---

## Part C — the scope question, which is the actual round

Parts A and B are individually defensible and collectively amount to something
larger: **nokre shipping a static-site driver.** That is the killed item.

The honest case for reopening is not any single item. It is the pattern in the
last round's own commits, every one of which moved something from the driver into
the library, and every one of which was justified by the driver having gotten it
wrong:

- `4044e66` — `dom.driver_files` became the library's statement of the file set,
  because *"this site once re-typed two of the four and shipped a service-worker
  registration that 404ed on every page load."*
- `dom.driver_sources` — the driver JS `@embedFile`d, so a generator stops
  joining a checkout path to find bytes a stale copy could outlive.
- `Refs.write` → `Refs.resolve` returning `Dest` — because *"closing `href="` by
  hand to smuggle attributes in was the sharpest bypass any consumer had."*
- `86e73e6` — `Router.ref` replaced ~20 hand-rolled reference formatters.
- `92ef0ba` — `testing.shell` shipped because *a generator is a platform shell
  and gets its shell from nokre.*
- `9762b8b` — the vendoring pin became a library constant.

Six moves in one round, all one direction. The previous handoff's own Part C
carries two more that point the same way and remain open (Part E below): the site
re-implementing `Router.current()`, and `build.zig:764` re-typing the pkg-web
quartet that `addPkgTree` writes.

**The counter-argument deserves equal weight**, and it is the one that killed
this before: a GUI library that emits sitemaps and structured data has stopped
being a GUI library. `docs/localization.md:400` already refuses a smaller thing
on exactly this ground. The document a browser needs around a screen is a
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
  (`live.zig:50-54`, wired `:226`); the site declares all three decls
  (`web.zig:66,73,94`). The hydration contract is explicit —
  `dom-edition.md:580-592`: match is tag + `data-n`, *"the ids are a hydration
  contract, not decoration"*, and it carries scroll, focus and caret through the
  handover. `dom-edition.md:78` calls a static page *"the useful degenerate case
  of the pair."* The consumer's two interactive surfaces need exactly this; no
  new mechanism is required for them.
- **One route→href mapping spent by both drivers** — `links.zig` (417 LOC),
  `Resolver` (`:71`) for the generator, `Live` (`:118`) for wasm. This is the
  pattern the second driver should copy, not a gap.
- **Build-time gates**: a11y audit per screen (`main.zig:141-152`, now with
  `audit.collect` `Options{skip}`), broken-reference check including `#anchor`
  targets (`:184-216`, anchors via `em.takeAnchors` at `:179`), icon-subset/tofu
  (`:244-253`), stale-output (`failOnStale` `:348-380`). These are stronger than
  the Astro site's equivalents and are a reason to migrate, not a gap to fill.
- **Colour is refused, permanently.** Thirteen grays (`core/color.zig:23-36`),
  `docs/elements.md:792`. The consumer has been told; it is a brand decision on
  their side, not a request on yours.
- **No image element.** Settled. A4 is a `<meta>` URL and nothing more.
- **Locale-aware route titles, App-owned locale, `L.of`/`L.in`/`Bound`.** See
  Part B's opening.

---

## Part E — carried forward from the ergonomics round, still open

Not re-surveyed. Full receipts at `git show 3855adf:HANDOFF.md`.

- **A8 — the stale-reply surface.** *Owner decision still pending.* A three-way
  posture menu: (a) a route-scoped `navigate` twin for callback use; (b) make
  `.route` the default-visible field in `refresh`'s doc example plus a
  harness-detectable audit note; (c) `bindKey` so position-vs-identity is a
  vocabulary choice. Receipts: 0 route-scoped `refresh` adoptions in 70 org
  calls, callbacks binding controller-not-request, `bindAt` carrying position
  where a sibling screen keys by code, `http.Handle.cancel` discarded at every
  call site.
- **Part B — the rename table.** `secure_store.Fake` → `MockState`
  (owner-confirmed), `element.Glyph` → `ChromeGlyph`, `http.request`'s inferred
  error set → named, `*const App` on read-only service verbs, journal views'
  mutable-bytes borrow, `Router.replace` alias-or-doc-line, shell.h haptic enum,
  `hsk_` prefix (log only).
- **Part C — consolidations. Two are directly relevant to this round:**
  item 2, the site's `links.zig:134-138` re-implementing `router.zig:296`
  `Router.current()`; and item 3, `build.zig:764`'s pkg-web quartet re-typing
  what `addPkgTree` writes, wanting a `packaging.web_page_files` const in the
  `driver_files` pattern. Both are the same driver-re-derives-the-library shape
  Part C above argues from. Items 4–7 (Emitter anchors — since shipped as
  `takeAnchors`; driver bytes — since shipped as `driver_sources`; docs one-home
  gaps; site-side guards) should be re-checked against current HEAD before
  being carried again.
- **Part D — performance.** Full-frame `readPixels` copy per frame
  (~15 MB/frame at 1200×800@2×), unbounded `services.js` measure cache, plus two
  more.
- **Part E — evidence filed, not proposed.** `Remote(T)`/staleness, ApiClient
  `= undefined` wiring and two-phase init, number formatting. *"Part E items move
  only on their own owner-level arguments."*

---

## Part F — questions only the owner can answer

1. **Does the original static-site-driver kill still stand?** If yes, Parts A
   and B collapse to "write the rule down and close them." Recover the rationale
   from history before anything else.
2. **Where is the line** — full driver, derivations-only (Part C's middle
   position), or nothing?
3. **Is `lang`/`dir` on a generated document the same refusal as `data-direction`
   on an embedded app,** or a different question that the embedded-app refusal
   was never about?
4. **Default-locale path scheme** — `/en/…` or bare? It cascades into canonical,
   redirects and the sitemap.
5. **Does the framework-vs-app boundary get a doc this round?** The consumer-side
   brief that triggered this round asserted the opposite of the code and was
   believed, because three instances and an analogy are not a rule.

---

*Written from the consuming side. Everything above is checkable; check it.*
