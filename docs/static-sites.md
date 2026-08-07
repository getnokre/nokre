# Static sites

A generator is an ordinary nokre app run at build time: it builds a
screen, audits it, resolves every reference against its own route table,
and writes a file. What goes in that file is the library's. `dom.document`
writes the whole document around the screen — doctype, `lang` and `dir`,
the head, the two mount points, the skip link, the boot script that turns
the file into the app's first frame. `dom.Alternates` derives the set of
URLs a page published in several languages annotates its siblings with,
`dom.Sitemap` writes the `<urlset>` over the whole tree, and
`dom.localeStub` writes the one page a locale axis needs that no screen
answers for.

None of them knows where any of it is published, and none of them will.

That is the line, and this page is where it is written down: what your
driver states, what the library derives from it, and — the part worth
more than either list — how to tell which side a question neither list
answers falls on. The calls themselves and the argument behind each are
[internals/dom-edition.md](internals/dom-edition.md); the locale axis a
multi-locale generator runs is
[localization.md](localization.md).

## The line

**Your driver states every destination. The library is what keeps them
from disagreeing** — with each other, with the page they are written on,
and with the tree a sitemap describes.

The first half of that was first written at a test helper, where
[audit.zig](../src/testing/audit.zig)'s `Options.skip` sanctions a static
generator turning off the `unresolvable_route` rule: *a document
destination is the site resolver's to honor, not the route table's*. It
is the same rule everywhere else the library writes a URL. What the
library took is not the destinations but the relationships between them,
because those are what a hand-written head gets wrong:

| Your driver states | The library holds you to |
| --- | --- |
| the origin — config nokre cannot know | that it carries a scheme and no trailing slash, and that one document has one origin |
| this page's path, `null` for a page with no URL of its own | that a path is rooted, and that a page with no URL claims neither a canonical nor an `og:url` |
| the same path once | that the canonical **is** the `og:url` — one field written twice, so there is no second field to keep in step |
| each locale's copy, and the chooser's address | that the set is complete — one required field per bundled locale, so a missing one is a compile error and an unbundled one is unstatable — that the tags are `L.tag`'s and not strings you typed, that the page is among its own alternates, and that the graph closes across the sitemap |
| the mount ids, the content class, the addressing mode, the skip link's words, the URL you published the stylesheet at | nothing — they are names you invented, and a library default would be a guess |
| the title, the description, the labels, a language's name in its own language | the escaping, on every one of them |
| the address a section is linked to by, where something outside the page names one (`Heading.anchor`) | that it can be an `id`, a fragment and a CSS selector at once; that it is unique in the document; that a collision fails the build rather than renaming it; and that it is on the roster `takeAnchors` exports |
| the structured data you serialized | that no byte of it can end the `<script>` block it lands in — `Emitter.json`, one escape and no opinion about the graph, which is why it does not write the tag either |

And what the library writes without asking is what it already holds:
`lang` and both direction attributes from `App.locale()` and
`App.direction`, `data-appearance` when the app pinned a scheme, the
locale the boot script pins, the route from `Router.current`, the class
list from `rootClass`, the module name from `driver_files.entry`, and the
charset in the first bytes of the head. A driver restating any of those
is a second copy of a fact the app already answered, and the second copy
is the one that goes stale.

Between those two halves there is no third category: **no writer here
computes a path, and none of them reaches a filesystem.**
`Meta` never reads a route name. `Alternates` never reads
`L.default_locale`. `Sitemap` fills a buffer you write yourself. Which
routes exist, what a URL for one looks like, where the files land and
whether the default locale is prefixed are all yours, and stay yours.

## Which side a new question falls on

Three questions, in order. They settle every case the table above
settles, which is the only reason to trust them on one it does not.

**1. Does nokre already hold the fact?** Then it is the library's, and a
driver being made to restate it is the defect — `lang` was that defect,
so was the class list, so was the module a page imports. What makes this
question answerable is that it is about the *app*: the language a screen
was built in, the route the router is on, whether this screen reserves
room for bottom chrome. If you would have to ask the app for it, do not
ask the driver.

**2. If you state it, can nokre check your answer?** Then the library
takes the relationship and leaves the value. It cannot know your origin
and does not try; it can see that `example.com` has no scheme, and it
refuses before the doctype rather than writing a document with a
half-formed URL in it. It cannot know where you published a page; it can
see that the page is missing from its own alternate set, which is the
annotation failure nothing else reports — the pages render, the links
work, and a search console says so months later.

**3. Would nokre have to invent an answer?** Then it is refused, and the
refusal holds even where the invention would be easy.

`lastmod` is the worked example, and it is worth following because the
obvious reason is the wrong one. It is not refused for being an SEO
concern: nokre emits the sitemap it would go in, with the alternate
annotations and the two spec limits enforced. It is refused because it is
the one destination-adjacent fact the library can neither know **nor
check**. Its grammar is W3C-datetime, and a crawler drops an unparseable
one in silence; the value a generator actually has to hand is the build's
own clock, which stamped on every URL tells a crawler the whole site
changed on every deploy. An origin nokre also cannot know — but *can*
check — is a required field. A fact it cannot check is not a field at
all, because a wrong answer nobody catches is worse than an absent one.

The third question has a second blade, and `noindex` is where it cuts. A
page with no URL of its own is `Meta.path = null`, so a `noindex` would
be *derivable* — and it is still not written, because whether an address
is indexed is a decision about your site rather than a fact about your
document. Derivability is not ownership. A robots directive goes through
the head seam, where the rest of your indexing policy goes.

Two more refusals fall out of the same question, and they are worth
naming so they are not re-proposed as omissions. `og:locale` is absent
though the page's language is on `<html lang>` four lines up: Open
Graph's locale is `language_TERRITORY`, and a BCP 47 tag need not carry a
territory, so `fa` would have to become `fa_IR` or `fa_AF` and picking is
inventing. `Meta.Image.shape` is stated by you rather than derived from
the pixel size: which crop an asset survives is editorial, and a
threshold on the aspect ratio would be the library guessing at your
artwork.

## A heading id is a destination, and it was invented for one round

The three questions were run against a fact that had been on the wrong
side of the line since the edition shipped, and they moved it. Heading
ids are derived from the heading's words (GitHub's slug, "A heading is
an address" in
[internals/dom-edition.md](internals/dom-edition.md)), and for the
overwhelming majority of headings that is exactly right: nothing outside
the page names them, so no address needs to exist before the words do.

It stops being right the moment something outside the document writes
one down. The first migration to meet this had a privacy policy whose
rights section is linked by an app store's account-deletion policy, at
one address specified across three locales. Derivation makes that
`your-rights`, `حقوق-شما` and `haklariniz` — three addresses for one
contractual destination, none of them the one in the contract. The
questions answer cleanly: nokre does not hold the fact (the content
does), nokre can check the answer, and the alternative is nokre
inventing one. So a heading may **state** its address —
`element.Heading.anchor`, spelled `b.anchored(.h2, "delete-account", …)`
at the cursor — and the library goes on owning everything around it.

**A field on the heading, not a verb on the emitter.** The rejected
alternative was an `Emitter` option or verb stamping the next heading,
and it fails on the same ground `lang` did: a driver never emits
heading-by-heading — `document` walks the whole tree in one call — so a
stamp would have to name its heading by position or by words, which is a
second copy of a fact stated somewhere else, and the second copy is the
one that goes stale. A bare `anchor` *element* was rejected too: every
element here is semantic, and a node with no role, no words and nothing
to draw is markup wearing an element's clothes.

**Stating an address buys no exemption from the rules around it.**
Uniqueness stays the library's, and a stated anchor that collides — with
a derived slug or with another stated one — is `AnchorError.AnchorTaken`
rather than the numeric suffix a repeated heading takes: suffixing the
one address someone else was told to use is precisely the failure the
field exists to prevent. Document order decides which of the two is
refused, and neither order can move a stated address. The grammar — an
ASCII letter, then ASCII letters, digits, `-`, `_`, `.` — is checked at
`Tree.append` with every other construction rule, and it is narrower
than an `id` needs because a stated address is also a fragment nobody
should have to percent-encode and a selector a stylesheet should be able
to name.

**Where the two failures land, and why they land differently.** The
grammar is a fact about one element, so it fails at the append that
builds the heading — before layout, before a byte. Uniqueness is a fact
about a whole document, which no append can see, so it fails at the
heading during the walk rather than pre-write the way `MetaError` does.
That is not a weaker posture, it is the one this kind of destination
already has: a `Refs` hook that cannot honor a route fails mid-walk too,
and a generator's error path is the same either way — the buffer is
discarded and the build stops, because a driver that writes a file
without checking the error had that bug before anchors existed.

**Across locales it is safe by construction up to one step.** The value
is a literal beside a translated title, and the ASCII floor turns the
likeliest accident — running the anchor through the translation table —
into a build failure in the first non-Latin locale rather than a broken
link discovered by a store review. What the library cannot see is a
translation table whose entries all happen to be ASCII; that last step
is discipline, and the roster is what makes it checkable: stated
anchors are in `takeAnchors`'s answer beside the derived ones, so a
generator's own reference gate resolves `#delete-account` per locale and
fails the build where it does not.

## The same three questions, on something that is not a destination

The procedure is written here because destinations are where it was
needed first, but nothing in it is about URLs, and the next thing it
moved was heading *depth*. The same migration's article pages draw
their title as an `h1` and then render fetched Markdown whose sections
are `##`. Markdown rebases every document's first heading depth to the
top of the outline ([markdown.md](markdown.md)), so those sections came
out as four to six more `h1`s beside the title's — and no editing of
the source could change it, since `#` and `##` rebase alike.

Question 1 is the one that looks answerable and is not. nokre holds the
tree, so it could read the heading before the document and start one
level deeper — but headings here are flat, so a body that is a
*sibling* of the preceding section would be filed as its child. That is
an invention, which is question 3, and the invention would be silent.

Question 2 is where it lands: the driver states the depth its body
starts at (`Document.base_level`), and the library keeps the
relationship it can check — a base too deep is
`heading_level_skipped`, added with the field because a field nokre
cannot check is not a field at all. Structure is not automatically the
library's; a value it can only guess and can fully check is the
driver's, whatever the value describes.

### And then question 1 turned out to have an answer

The round after that put the same three questions to the *page's own
title* — the visible top of the outline, which the pages above were
drawing as an `h1` and the audit was finding by counting. Question 1 is
the one that answers, and it answers loudly: **nokre already holds what
the screen is called.** `RouteDef.title` is required, has no default,
is localized, and is what every piece of chrome already names the
screen by. A driver drawing an `h1` beside it was restating a fact the
app had answered, and the second copy is the one that goes stale.

So the library draws it, and asks where it cannot know: `App.setTitle`
for a screen whose reader-facing title is per-reference, `setTitle("")`
for one that draws none ([routing.md](routing.md)). Level 1 became the
library's — `error.HeadingAtTitleLevel` on every other append — which
retired `multiple_h1` outright: the shape it reported is now
unbuildable ([accessibility.md](accessibility.md)).

The lesson worth keeping is about question 1, not about headings.
Twice in a row it was read as "does nokre hold the tree?" and answered
*yes* when the real question is the one the procedure states: **is it
about the app?** The tree is a rendering; the route table is the app.
Reading a value off the rendering is derivation, and derivation was
never what question 1 asks about.

And `base_level` survived the change with its job narrowed rather than
its field removed: it no longer says where the outline starts, only how
far under the title a body hangs. That is question 2 doing what it is
supposed to — the part nokre can check stayed the library's, and the
part it could only guess stayed the driver's, even as the value around
them moved sides.

## A site's header is a roster, not a seam

The migration that produced the two sections above came back with a page
whose top is eight links across it — a public site's header bar, drawn
by the generator as an ordinary row of links. Since the round where the
library began drawing the page's own `h1`, those links come out *under*
the title, because a screen's content starts under the title by
construction. The proposal was the obvious one: `body_end` already takes
"whatever stands below the app but inside the document", so give the
document a `body_start` for whatever stands above it.

**It is refused, and the ground is that a header of destinations is not
markup.** A byte seam is where a *footer* goes — a copyright line, a
colophon, cross-locale links that reference nothing the route table
knows — because none of that is a place the site has. Eight links to
eight sections are eight places the site has, which is the one thing
`App.setNav` models, and putting them through a seam would hand the
library a string. Everything the library could otherwise say about them
would go with it: which one you are standing on (`aria-current`), what
to call a screen that is none of them, whether every destination
resolves against the route table at build time, and that the set is a
navigation landmark rather than a row of anchors. The seam answers
"where do I put it" by throwing away "what is it".

The three questions say the same thing from the other end.
**Question 1 answers**, and it answers the way it did for the title: the
set of places a site always has is the *route table*, which is the app,
and the words on them are `RouteDef.title` in the reader's language. A
driver spelling those into markup restates a fact the app already holds,
and the second copy is the one that goes stale — a renamed section keeps
its old word in the header until somebody notices.

**What did move is the roster's shape**, because the constraints that
made a seam look necessary were a phone's rather than the library's:

- **The glyph is uniform rather than required.** The rule was always
  that a row where some destinations have marks and others do not is
  worse than either uniform answer — and requiring one was only the
  first way of reaching a uniform row. `Destination.icon` is optional
  and the *mixture* is what `setNav` refuses
  (`error.NavIconsMixed`), which is the rule that sentence always
  stated.
- **The cap is derived rather than chosen.** It was five, on the ground
  that more does not fit a bottom bar at any width — and that ground was
  never doing the work, since whether a row fits is asked of the
  reader's own viewport, and a roster of two with long enough labels
  collapses on a phone just the same. What a constant *can* bound is the
  collapsed shape: there the whole roster is the section picker's list,
  and the picker already names the count at which a list stops being
  scanned and starts being typed into. So `nav.max_nav_items` is that
  number less the row an off-roster screen may add, and it moves only if
  that one does. A site with more destinations than the bound
  restructures.
- **The placement did not move, and will not.** The bar is the bottom
  band in both editions and on both sides of a boot. It is not the
  medium's to choose: the file that renders the roster is the file the
  live driver patches, so a header drawn at the top before boot and at
  the bottom after would move a site's navigation out from under the
  reader one frame in — and the reference edition, drawing the same
  tree, would disagree with both. There is no placement API here for the
  reason there is none anywhere else
  ([elements.md](elements.md)).

Which leaves what the finding actually reported. The header was below
the `h1` in *document order*, and that is what a roster fixes outright:
a nav is a chrome layer, so the title seats after it, and the chrome
mount is written before the content mount — the destinations lead the
page's title in the markup and in the focus order. Nothing is reordered
by CSS, which is the posture that ruled out the other workaround in the
first place.

## A generated document has no host, so it has no unstyled half

A footer spliced into `body_end` used to render in the browser's default
serif. It sits outside the screen's own element, and every rule carrying
the library's type is scoped to nokre's surfaces — deliberately, on the
ground that *the page around an embedded app is not this edition's to
turn around*.

That ground is right and it is untouched. It also has nothing to protect
here: `dom.document` wrote the doctype, the head and the body, so there
is no surrounding authority whose page could be restyled. It is the
`lang`/`dir` asymmetry again and it is resolved the same way — a
generated document stamps `data-nokre="document"` on its root element,
the live driver stamps the appearance and the direction and deliberately
never this, and the sheet gains one block behind the attribute. An app
mounted in someone else's page cannot reach it, which a compile-time
check on the live driver's own file keeps true.

**What the block covers is the page's type and its paper**: ink, family,
size, line height and the paper colour on `body`, plus the two
font-smoothing hints and the tap highlight the screen already carries. A
footer inherits the page it is on rather than the browser's defaults,
and the band of page beside it is the same paper the screen is drawn on.

**Where it stops is inheritance.** A list you splice keeps its markers,
an anchor keeps the UA's underline and colour, a table keeps the UA's
borders. Those are the browser's decisions about markup nokre neither
wrote nor has an element for, and normalizing them would turn one block
into a second stylesheet to reason about — which is the failure a reset
invites, not a gap in this one. It is the line the rest of this page
draws: the library takes what it holds, and a shape you chose stays
yours.

## A default is not an opinion about your site

A handful of these fields do carry defaults, and the rule is worth
stating because it is what keeps a default from becoming a decision the
library made for you: **where a field has one, the default is a fact
about nokre — never a guess about your site.** `Boot.addressing` is
`.fragments` because that is `mount`'s own default in the live driver,
not because a site should prefer it. `Boot.driver_dir` is `/` because
that is where installing `App.web` whole puts the driver set.
`packaging.Web.lang` is `"en"` because that is the language nokre's own
nav bar, close control and notices pane are in on an app that never
localized — the same stand-in `langTag` takes for an empty tag, and a
claim about the framework's words rather than about your content. Even
`Meta.kind`'s `"website"` is the one `og:type` that says nothing: any
value past it is a claim about what a page *is*, which is content, and
content is yours.

Everything a driver invents is required and has no default at all —
`Meta.origin`, `Alternates.stub`, both mount ids, the stylesheet URL. A
default there would be a URL the library made up, and the failure would
be a page that renders and is wrong.

## The rule runs in both directions

The sentence that keeps the library out of your resolver's business also
stands the library's own rules down where your resolver is the stricter
authority — it was written for that case first. That is what `Options.skip`
is for and the only thing it is for. A generator resolving a document's
destinations against its own table already fails the build on a reference
it cannot honor, harder than `unresolvable_route` would, so the rule is
skipped — and skipping a rule nothing else checks is turning the
guarantee off ([accessibility.md](accessibility.md)).

The mirror case is an app mounted in a page it did not write. There the
live driver stamps `data-direction` and deliberately never `dir`, because
the page around an embedded app is not this edition's to turn around. A
generated document has no page around it — nokre wrote the file — so it
stamps both. One rule, read from two sides: **the library writes what it
owns and stops where the surrounding authority is someone else's.** It is
the same reason your driver states the ids, and the same reason it will
go on stating them.
