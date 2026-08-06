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

**Corrected 2026-08-06** against nokre `682b839` (revision is still 32) and the
site at `b93a2d4`. Every line number below has been re-resolved against those
two trees; several claims were wrong outright, not merely stale. Where a reading
changed, the old one is named in place — a reader who saw the first version
needs to know what moved, and there is deliberately no changelog section to
consult instead.

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
| `class="nokre has-chrome"` | nokre writes it (`live.zig:313`) and styles it (`stylesheet.zig:601`) | **real duplication** |
| `#chrome` / `#content` / `.page` | nokre: **zero hits** | the site's own |
| `addressing: "documents"` | nokre: **zero hits** | the site's own |

Two of the three are the *driver's* inventions that nokre has never heard of. A
helper owning "mount points" would have made nokre own ids and an addressing
mode belonging to the consumer — the precise boundary
`stylesheet.zig:535-543` states and this file quotes approvingly. The owner was
declining to move that boundary on evidence that half the reason offered for
moving it was not true.

**Consequences for this round, and they cut three ways:**

1. **Parts A and B are not re-proposals of a killed item.** They are new
   questions about a question that was deferred. Refusing them on adjacency
   grounds would be refusing something that was never refused.
2. **The kill's surviving half is a real, still-live item, and it is small.**
   `nokre has-chrome` is a genuine shared contract string that a host document
   must write and nokre never exports — `dom.zig` exports `driver_files`,
   `driver_sources`, `Emitter`, `Refs`, `Dest`, `content`, `chrome`, `node`, and
   no class name at all. Both static consumers will retype it. That is one
   exported constant, not a document shell, and it is worth doing whatever else
   this round decides.
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

1. `docs/internals/dom-edition.md:268` — *"What the host document owes, and what
   it keeps"*, then an enumeration. Says what the app owes; does not generalise.
2. `src/render/dom/stylesheet.zig:535-543` — *"the attribute is the driver's to
   stamp, but the page around an embedded app is not this edition's to turn
   around"* (`:542-543`; the survey cited `:541-543`). Closest thing to a rule
   among the three, and it is about `data-direction`.
3. `docs/localization.md:400-403`, on a neighbouring question, is the sharpest
   phrasing of the instinct: *"Downloadable translations are a distribution
   feature with a cache, a version skew story, and a failure mode on first
   launch — that is an app, not a GUI library."*
4. **`src/testing/audit.zig:212-219`** — the `Options.skip` doc, which names the
   static-site generator by name and then says what it is entitled to:
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

The consuming site states the boundary in the plainest words either repo has for
it — `getnokre.github.io/src/main.zig:5-7` (the survey cited `:4-7`): "Everything
below is the *driver*: which screens exist, what a reference resolves to, and the
document a browser needs around a screen. The markup and the stylesheet are the
library's." The emphasis on *driver* is the source's own.

**Whatever this round decides, the outcome belongs in a doc.** A rule that lives
in a test helper's doc comment, with three instances around it and no
consumer-facing statement, is exactly what let a consumer-side agent confidently
brief the owner on the opposite of what the code says. If the answer is "the
document is the driver's, permanently," that sentence is worth more than any item
in Part A.

---

## Part A — the document shell

Each item: the claim, the receipt, the argument for the library, the strongest
argument against, and what "already solved" would look like.

### A1a. `lang` on a generated document, and what boots over it

**The survey argued this one from the outside — screen readers, browser
translation, hyphenation, search engines — under a section header ("Why now")
that frames the whole round as content-SEO. Those are the weakest arguments
available for it.** Two stronger ones were sitting in nokre's own design notes
and in the mount signature, and both are about the library's own machinery
failing rather than about a crawler's opinion. Lead with these.

**Lead: hydration boots the wrong locale, silently, and the diff succeeds.**
`mount({ wasm, into, worker, content, route, seed, addressing })`
(`src/render/dom/live.js:57`) has no locale option. The only locale that reaches
a wasm app in a browser is the device's: `live.js:613-618` pours
`navigator.language` through the scratch/seed pair strictly before boot, and
`src/services/locale/web.zig` is where it lands and what `App.init`'s install
fires with. The driver entry points have no channel either — the reference
site's `nokreWebBuild(gpa)` (`getnokre.github.io/src/web.zig:73`) takes an
allocator and nothing else; `route`, `seed` and `addressing` are the whole of
what `mount` carries per page. So a `/fa/…` page opened in an `en` browser
hydrates **English over Persian markup**.

And it does so without a single visible fault, because the hydration match is
tag plus `data-n` (`docs/internals/dom-edition.md:587-592`): *"two nodes are the
same node when they are the same kind of thing carrying the same id."* Nothing
in that rule looks at text. The tree the app rebuilds in English has the same
shape and the same ids as the tree the generator wrote in Persian, so the diff
*succeeds*, every string is swapped, direction reverts to LTR, and the scroll
position is faithfully preserved on a page that now says something else. There
is no error and no warning; the pair's own contract guarantees the silence.

`lang` on the generated document is the only thing that could carry the page's
locale to the driver mounting over it. That makes A1a a correctness item for the
static+hydrate pair Part D calls *"real, documented, and shipping"* — not a
metadata item.

**Second: appearance has a designed static fallback and direction has none.**
`stylesheet.zig:201-208` states the design out loud — *"The media query is all a
page with no app behind it — a screen serialized to a file — has to go on"* —
and `live.js:174-176` says the same thing from the other side. So the sheet is
built to answer appearance for a page with no app behind it. **No media query
can answer direction.** Only the attribute can, and on a serialized page nothing
writes it, so `:root[data-direction="rtl"]` (`stylesheet.zig:544`) never matches
and the mirroring never happens. A file nokre wrote for a Persian reader stays
LTR until — and unless — a driver boots over it. That is nokre's own note
describing the static case as a case it serves, next to the one axis where it
does not.

**Receipt, corrected.** The survey said *"Nothing stamps `data-direction`."*
**That is false.** `src/render/dom/live.js:184` does
`if (root.dataset.direction !== direction) root.dataset.direction = direction;`
on `documentElement` (`:177`), backed by the `nokre_dom_direction` export
(`src/render/dom/live.zig:171`) — a literal-string grep for `data-direction`
missed it because JS spells it camelCase through `dataset`. The true claim is
narrower and is the one above: **nothing stamps it on a statically serialized
page.** The live driver stamps both attributes, in the same three lines.

What stands from the original receipt: `serialize.zig` emits no `lang`, no `dir`
and no document at all. `getnokre.github.io/src/main.zig:420` hardcodes
`<html lang="en">` (the survey said `:372`; `writeDocument` is `:413-487` now).
The rest of RTL is complete — `App.direction` (`src/core/app.zig:69`),
`App.setDirection` (`:767`), `L.dir(loc)` (`src/l10n/l10n.zig:302`) and
`l10n.directionOfTag` (`:1106`) — the survey had those two the wrong way round —
and the serializer flips chevrons off `em.app.direction`
(`src/render/dom/serialize.zig:693,903`), which is the one piece of mirroring a
static page *does* get, since it is markup rather than CSS.

**For the library.** Nokre knows the locale and the direction; it wrote the
whole file; and the one axis it declines to write is the one axis with no
fallback and the one the boot handover cannot recover. A Persian page served as
`lang="en"` is also wrong for screen readers, browser translation, hyphenation
and search engines, but that is now the fourth reason, not the first.

**Against.** `stylesheet.zig:535-543` states the refusal deliberately: an
embedded app must not turn the page around it. And `docs/localization.md:155-158`
takes a stronger line — *"There is no `dir` attribute and no per-locale direction
flag in ARB — a Persian string in an English locale and an English string in a
Persian locale each lay out correctly on their own evidence. This never depends
on the setting below."* If direction is a property of runs of text rather than of
documents, then a document-level `dir` is the wrong idea and the driver is the
right place for the one line that nevertheless has to exist. Note this cuts at
`dir` only: it has nothing to say about `lang`, which is what the hydration
argument actually needs.

**Note the asymmetry**, because it may be the whole resolution: an *embedded*
app must not restyle its host, but a *generated document* has no host — nokre
wrote the whole file. The refusal may simply not apply to the static path, in
which case this is a stamp in the static document writer and the doctrine is
unchanged.

**Already solved if:** a sanctioned per-page locale channel into `mount` exists
that the survey missed. (`data-direction` has a stamp — just not on the static
path, which is the item.)

### A1b. `webIndexHtml`'s hardcoded `lang` — a different ask, and a smaller one

**The survey filed this as the same item as A1a. It is not, and merging them
hides that they have different answers.** `webIndexHtml`
(`src/packaging/packaging.zig:1008`, the `lang="en"` at `:1017`) is the
**app-shell page `addWebSite` emits** — one document, for a wasm app that boots
into an empty body. A static generator writes its own document
(`getnokre.github.io/src/main.zig:413-487`) and never calls `webIndexHtml`;
nothing in the site tree imports `packaging` at all.

So: parameterising `webIndexHtml`'s `lang` does nothing for 4,250 static pages,
and stamping the static path does nothing for a wasm app shell. **Two items,
two verdicts**, and they can legitimately differ — A1b is a `Decl` field on a
page nokre wholly owns, with no consumer boundary anywhere near it; A1a is the
question of whether nokre writes into a document the driver authored.

A1b is also the weaker of the two on its own merits: the shell page is a boot
stub with no prose in it, so `lang` there is nearly decorative. It is cheap, and
it is not urgent.

### A2. Canonical, Open Graph, Twitter card

**Receipt.** The reference driver emits canonical with a **hardcoded origin**
(`main.zig:440`, under the 404 guard at `:439` — the survey cited `:436-438`,
which is the comment explaining the guard), `og:type` (`:452`), `og:site_name`
(`:453`), `og:url` (`:460`, under the same guard at `:459`), `og:title`
(`:462`), `og:description` (`:464`), plus `theme-color` for both schemes at
`:450-451`, read from `nok.Gray.paper` at `:445`. **No `og:image`. No Twitter
card.**

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
`schema.org` in either repo, `src/` or `docs/`. That much stands.

**The survey then asked for two things and only one of them is missing.** It
closed with *"already solved if the emitter can express a raw `<script>` block
safely today"* — **it can, and does.** `Emitter.raw`
(`src/render/dom/serialize.zig:166`) and `Emitter.print` (`:170`) are public and
write straight through to `out` with no escaping whatever; `Emitter.text`
(`:177`) is the *single* escape in the type, and it is opt-in per call. A driver
can emit a `<script type="application/ld+json">` block today, with nothing new
in the library and nothing bypassed. The reference driver already does exactly
this for its whole head — every `<meta>` in A2's receipt is a `raw` or a `print`.

**So the emission half is closed.** What survives is narrower and should be
stated as two separate residues:

1. **A `</script>`-safe JSON string writer.** `std.json` escapes JSON, which is
   not the same question: `</script>` is legal JSON and fatal inside a `<script>`
   block. This is the same class of problem as the CSP `connect-src` injection
   this repo swept 0–255 for (`packaging_test.zig:448-485`, *"no byte a consumer
   supplies can smuggle a directive"*), and it has the same failure mode — a
   consumer building the string by hand gets it right until one statement's text
   carries the wrong bytes. Statement text is user-adjacent content in three
   languages across 4,250 pages.
2. **There is still no head seam.** `raw` writes wherever the emitter is
   currently pointed; nothing in the type distinguishes "into `<head>`" from
   "into the body". A driver that wants JSON-LD in the head has to be writing
   the head at that moment, which the reference driver is and a per-route helper
   would not be. Worth naming, because a JSON-LD *emitter* would have needed one
   and a JSON-LD *escaper* does not.

**The reshaped ask** is therefore a doc line naming `Emitter.raw` as the
sanctioned seam for a block the library has no element for — stated where a
driver author reads it, so the second driver does not have to conclude from an
unescaped writer's existence that it is allowed to use one — plus, at most, the
string writer. Not a JSON-LD emitter. The five graph types (FAQPage, Service + AggregateOffer with EUR,
ItemList, WebPage, Article) are content and belong to the app, which the survey
had right.

**Against, on the residue that is left.** It is a JSON writer and a `<script>`
tag. If the answer is "use `std.json.Stringify`, escape `</` yourself, and write
the tag with `Emitter.raw`," say so in `dom-edition.md` and close it — a
documented one-liner is a fine resolution, and given that `raw` already exists it
may be the whole of what this item deserves.

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
(`src/core/router.zig:213-230`), resolved through `Title.text(locale_tag)`
(`:224`), and gave the App the chosen locale — `App.setLocale`
(`src/core/app.zig:737`), `App.locale()` (`:758`), `Options.locale` declared at
`:236` and consumed by `init` at `:345` (the survey cited only `:345`).
`setRouteTitles` and `Router.retitle` retired. `128ef2b` added `L.of(app)`
(`src/l10n/l10n.zig:450`), `trAny` for runtime keys, and `L.chrome(locale)`
deriving one reserved key per `Chrome` field at comptime — so a missing chrome
word is a compile error rather than shipped English. `408d77b` added
`Bound.tag()/.dir()/.chrome()` and `L.in(app)` (`:482`).

**And the bundle already owns the locale *set*, at comptime.** `L.Locale`
(`src/l10n/l10n.zig:282`) is an exhaustive enum over the bundled locales,
`L.tag(loc)` (`:292`) gives each one its BCP 47 tag, `L.dir(loc)` (`:302`) its
direction, `L.default_locale` (`:289`) the template, and `L.resolve(tag)`
(`:390`) maps a device tag onto them. This is load-bearing for B1 below and the
survey did not have it.

**An earlier line in `src/core/router.zig:56` reading "Comptime, and a locale is
not" is gone.** A consumer-side brief quoted it as current doctrine last week; it
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
(`src/render/dom/serialize.zig:65-93`), and a driver's resolver can return
`/fa/…` for any route today; that is precisely what the reference site's
`Resolver` does with its own scheme. Nothing in the library stands between a
driver and a locale-prefixed href.

**So B1 shrinks.** What is genuinely missing is *the loop* — regenerate the tree
once per locale, hand each page its locale — plus B2's derivation, which is the
part a second driver will actually get wrong. Everything else in the sketch is
either owned already or belongs to the driver. The interesting design question
is now the narrow one: **is the loop worth owning at all**, given it is four
lines over a set nokre can already enumerate?

### B2. hreflang and `x-default`

**Receipt.** Zero `hreflang`, zero `x-default` anywhere in either repo.

Given a route, a locale set and an origin, the alternate set is
`{origin}/{locale}{suffix}` for every locale plus `x-default` — fully derivable.
The consumer's existing test asserts the alternate href set matches *exactly*,
both directions, which is precisely the kind of invariant that is easy to
half-implement by hand.

This is the strongest single candidate in the file: mechanical, derivable, no
content dependency, and wrong-by-hand in ways that are invisible until an
international search console complains months later.

**The better shape, since this file's sketches are illustrative.** Not a config
struct — a **pure function** over three inputs:

- the locale set, taken from the bundle (`L.Locale`), not declared;
- the current locale;
- a driver-supplied `fn(locale, route) → path`.

returning the alternate set. Nokre then owns exactly two things — the
**completeness invariant** (every bundled locale appears, exactly once) and the
**`x-default` rule** — and the driver owns **every byte of policy**: the origin,
the prefix scheme, whether the default locale is bare, what a route's path even
looks like. That is Part C's middle position expressed as a signature rather than
argued for in prose, and it is the same shape `Refs` already has: nokre owns the
attribute, the driver answers where it points.

It also keeps B3 on the same side of the line **for free**, which this file
already insists on: the sitemap writer calls the same function with the same
driver callback and gets the same set, so the two cannot disagree.

### B3. Sitemap alternates

**Receipt.** `main.zig:688-704` (`writeExtras`) emits a flat `<urlset>` of
`<loc>` only — the `<loc>` line is `:698` — with no `lastmod`, no `changefreq`
and no `<xhtml:link>` alternates. `robots.txt` at `:706-709`. (The survey cited
`:692-702` and `:707-708`.)

For a multi-locale site the sitemap should carry `<xhtml:link rel="alternate">`
per locale per URL. Same derivation as B2 from the same inputs — and under B2's
reshaped signature above, literally the same call. If B2 lands in the library,
this is nearly free; if B2 stays in the driver, this should too — they should not
end up on opposite sides of the boundary.

### B4. The output-path scheme

The reference driver maps home → `index.html`, 404 → `404.html`, else
`<route>/index.html` (`outPath`, `main.zig:393-400`; the survey cited `:345-357`,
which now lands inside `failOnStale`). A locale axis
multiplies that, and the default-locale question (`/en/…` versus bare) is a real
fork the consumer has already answered one way (Astro's
`prefixDefaultLocale: true`).

Worth deciding alongside B1 rather than after: it determines whether the
canonical for the home page is `/` or `/en/`, which determines what the redirect
stub at `/` must say, which the consumer already has two of.

### B5. Route references are ASCII-only — a constraint the survey did not find

**Receipt.** `validIdent` (`src/core/router.zig:261-268`) permits exactly
`[A-Za-z0-9_.-]`; `Router.writeRef` refuses everything else with
`error.RouteArgCharset` (`:462`), and `resolve` refuses the same set on the way
back in (`:626`). `arg_separator` is `'~'` (`:241`) and `max_ref_bytes` is 256
(`:246`). The rule is stated on purpose — *"an argument is an identifier and not
a payload. Free text is a URL, which is deep_link's business"* (`:255-260`).

**Benign for the incoming consumer as built.** Its generated paths are ASCII
even under `/fa/` — the locale prefix is a BCP 47 tag and the statement slugs
below it are ASCII identifiers. Nothing about the migration hits this today.

**It kills one thing outright, and quietly.** Any *localized-slug* scheme — a
Persian or Turkish route argument, the obvious next ask for a content-SEO
surface in three languages — refuses at `writeRef` rather than degrading. And
**`docs/localization.md` never mentions it**: the doc that tells a consumer how
to be multi-locale has nothing to say about the one place a locale's own script
is rejected. Whatever this round decides about Parts A and B, that omission is
worth one sentence in that file regardless, because it is where someone will
look.

Note this is a real refusal with a stated ground, not an oversight — the
argument for it is the same argument `Refs`/`Dest` makes, that a reference is a
name and not bytes. The item is documenting it, not relaxing it.

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
  nowhere in the repo. The real lines are `driver_files.zig:11-18`: sw.js is
  registered *by URL*, so *"a missing one is a silent 404 at runtime, not a build
  error, which is exactly why the set is data rather than prose"*, closing with
  *"The one consumer that re-typed this list shipped two of the four."* Same
  argument; it is worth having it in the words the repo actually uses.
- `Refs.write` → `Refs.resolve` returning `Dest` — because *"closing `href="` by
  hand to smuggle attributes in was the sharpest bypass any consumer had, and
  this shape is what removes it"* (`serialize.zig:49-51` — this one the survey
  quoted accurately, just clipped). The signature's other half is the harder
  rule: *"a hook that writes `em.out` is re-opening the door this signature
  closed"* (`:63-64`).
- `86e73e6` — `Router.ref` replaced ~20 hand-rolled reference formatters. **It is
  `Router.writeRef` now** (`src/core/router.zig:457`), renamed by `627ceda`'s
  vocabulary sweep; anyone grepping for `Router.ref` on this line will find
  nothing.
- `92ef0ba` — `testing.shell` shipped: *"The shell a driver links instead of
  writing… Before this module every driver wrote the same block by hand"*
  (`src/testing/shell.zig:1-9`), and a static-site generator is one of the
  drivers it names. **The survey attributed to this commit a quote — "a generator
  is a platform shell and gets its shell from nokre" — that appears nowhere in
  the repo.** The commit is real and the direction is right; the sentence was
  invented.
- `9762b8b` — the vendoring pin became a library constant.

**Five moves in one round, all one direction** — the survey said six, counting
`dom.driver_sources` among them. That one is real but it is not from that round:
it landed in **`e1e9f43`**, the closing sweep of the round *this file succeeds*
(the driver JS `@embedFile`d, so a generator stops joining a checkout path to
find bytes a stale copy could outlive — `dom.zig:51-69`). It strengthens the
pattern; it does not belong in that round's tally.

**The survey then said the previous handoff's own Part C carried two more that
"remain open." Both shipped, and the Part E it pointed at never listed them.**
The site calls `app.router.current()` (`getnokre.github.io/src/links.zig:141-142`,
under a comment saying *"the router has already answered the question"*), and
`packaging.web_page_files` (`src/packaging/packaging.zig:867`) is the one
statement of the pkg-web quartet, consumed exhaustively at
`build.zig:1609-1619` with a `@compileError` for any name lacking a writer;
`build.zig:764` re-types nothing. There is no live item here — only a dangling
pointer, now removed.

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
  (`web.zig:67,73,94` — `nokreWebSeed` is `:67`, not `:66`). The hydration
  contract is explicit — `dom-edition.md:581-592`: match is tag + `data-n`
  (`:587-592`), *"the ids are a hydration contract, not decoration"*, and it
  carries scroll, focus and caret through the handover. `dom-edition.md:79`
  calls a static page *"the useful degenerate case of the pair."* The consumer's
  two interactive surfaces need exactly this.

  **Two qualifications the survey's "no new mechanism is required" glosses
  over.** First, A1a: the pair carries no locale, and the same `data-n` match
  quoted above is what makes booting the wrong one silent. Second, **the seed
  costs a network fetch per page** — `live.js:83` does
  `fetch(seed).then((r) => r.text())`, a URL, not inline bytes. That is the right
  trade for two interactive surfaces and for a doc site handing over its
  Markdown; it is not free at 4,250 pages, and a consumer reading "no new
  mechanism is required" should know which mechanism it is getting.
- **Build-time gates**: a11y audit per screen (`main.zig:140-154`, now with
  `audit.collect` `Options{skip}` — the survey cited `:141-152`),
  broken-reference check including `#anchor` targets (`:184-216`, anchors via
  `em.takeAnchors` at `:179`), icon-subset/tofu (`:244-255`), stale-output
  (`failOnStale` `:348-382`). These are stronger than the Astro site's
  equivalents and are a reason to migrate, not a gap to fill.
- **Heading anchors already handle Persian and Arabic, deliberately** — so
  nobody should propose slug work for the RTL locale. `serialize.zig:1276-1290`
  keeps Unicode word characters byte-wise, because *"dropping these bytes would
  slug every Persian or Arabic heading to 'section' — one anchor for a whole
  document"*, with only General Punctuation (U+2000–U+206F) carved out to match
  what GitHub's slug drops. A three-locale docs collection gets working
  per-heading anchors in all three with nothing asked for.
- **Colour is refused, permanently.** Thirteen grays — the `Gray` enum at
  `src/core/color.zig:23`, `g0`–`g12` at `:24-36` — and `docs/elements.md:792`.
  The consumer has been told; it is a brand decision on their side, not a request
  on yours.
- **No image element.** Settled: `Role` (`src/core/element.zig:1467-1511`) has
  forty-three members and none of them is an image. A4 is a `<meta>` URL and
  nothing more. One stale line to fix while someone is nearby, though:
  `docs/introduction.md:180` still describes the closed set as *"static text and
  images"* — the one place in the consumer-facing docs that promises an element
  that does not exist, on the exact question a site migration will ask.
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
and `Dest` (`src/render/dom/serialize.zig:65-93`, about thirty lines including
the doc comment) — the seam; the 417 lines are what a driver writes against it.
`Live` is at `links.zig:111`, not `:118` (`:118` is `Live.refs`).

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
  scope it. Verified still true at HEAD: `shim/nokre_skia.cpp:276` still
  `readPixels` the whole surface into a persistent buffer every frame
  (~15 MB/frame at 1200×800@2×) where a CPU raster surface can hand its pixels
  out directly, and `src/render/dom/services.js:351-355`'s measure cache is
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
  `organizations_sheets.zig:13`'s join-code sheet carries `.error_copy` but no
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

**What it would cost here**, verified: ~20 page titles are hardcoded English in
`src/pages.zig:64,71,78,…` and would become catalog keys against a one-locale
bundle; the origin is hardcoded at **four** sites (`src/main.zig:440` canonical,
`:460` `og:url`, `:698` sitemap, `:708` robots) and wants one constant whatever
else happens; and the site today has no l10n surface at all, so the bundle is
new. Nothing else moves.

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
who ends up owning it.

---

## Part F — questions only the owner can answer

1. ~~**Does the original static-site-driver kill still stand?**~~ **Answered
   2026-08-06 — see "The killed item, recovered" above, and re-read this
   question in its light.** There was no static-site-driver kill: round two
   logged the full driver as an undecided owner call and killed only A10.4, a
   narrow document-shell helper, because two thirds of what it proposed to own
   were the driver's own inventions. So Parts A and B do **not** collapse on
   that ground, and the question that is actually left is 2 below. What the
   recovered kill supplies is a *test* rather than a verdict: an item asking
   nokre to own something the consumer invents dies the way A10.4 died; an item
   where nokre already owns the fact and merely fails to export it is the
   opposite case.
2. **Where is the line** — full driver, derivations-only (Part C's middle
   position), or nothing?
3. **Is `lang`/`dir` on a generated document the same refusal as `data-direction`
   on an embedded app,** or a different question that the embedded-app refusal
   was never about? Note the refusal's own note says the media query is what a
   serialized page *"has to go on"* — for appearance. Direction has no such
   fallback, and the boot handover has no locale channel at all (A1a). Ask this
   about the static path only; the app-shell page (A1b) is a separate and much
   smaller question.
4. **Default-locale path scheme** — `/en/…` or bare? It cascades into canonical,
   redirects and the sitemap.
5. **Does the framework-vs-app boundary get a doc this round?** The consumer-side
   brief that triggered this round asserted the opposite of the code and was
   believed, because instances and an analogy are not a rule. There are four
   instances, not the three the survey found, and the fourth
   (`src/testing/audit.zig:212-219`) is already written as a rule — so the
   question is narrower than it looked: does that sentence get promoted out of a
   test helper's doc comment into a place a consumer reads?

---

*Written from the consuming side. Everything above is checkable; check it.*
