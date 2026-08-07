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
| the mount ids, the content class, the addressing mode, the skip link's words, the URL you published the stylesheet at, the directory you published the driver set under | nothing — they are names you invented, and a library default would be a guess |
| the title, the description, the labels, a language's name in its own language | the escaping, on every one of them |
| the address a section is linked to by, where something outside the page names one (`Heading.anchor`) | that it can be an `id`, a fragment and a CSS selector at once; that it is unique in the document; that a collision fails the build rather than renaming it; and that it is on the roster `takeAnchors` exports |
| the language a run of words is in, where it is not the page's (`Link.lang`, `Span.lang` — the chooser's anchors) | that the tag is a tag: `error.InvalidLangTag` at `append`, before a document can carry an attribute a browser would drop |
| the structured data you serialized | that no byte of it can end the `<script>` block it lands in — `Emitter.json`, one escape and no opinion about the graph, which is why it does not write the tag either |

And what the library writes without asking is what it already holds:
`lang` and both direction attributes from `App.locale()` and
`App.direction`, `data-appearance` when the app pinned a scheme, the
locale the boot script pins, the route from `Router.current`, the class
list from `rootClass`, the names of the two scripts a page loads from
`driver_files`, and the charset in the first bytes of the head. A driver restating any of those
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
construction. The proposal was the obvious one: `body_end` took
"whatever stands below the app but inside the document", so give the
document a `body_start` for whatever stands above it.

**It is refused, and the ground is that a header of destinations is not
markup.** Eight links to eight sections are eight places the site has,
which is the one thing `App.setNav` models, and putting them through a
seam would hand the library a string. Everything the library could
otherwise say about them would go with it: which one you are standing on
(`aria-current`), what to call a screen that is none of them, whether
every destination resolves against the route table at build time, and
that the set is a navigation landmark rather than a row of anchors. The
seam answers "where do I put it" by throwing away "what is it".

This round said the footer at the other end of the page was the case a
byte seam *was* for. That was wrong, and two revisions later the same
sentence deleted `body_end` too ("A seam is for what does not render",
below). The reasoning here is untouched; what it got wrong is that it
looked at the destination rather than at the thing, and a footer is a
set of links whatever it is called.

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
- **The placement did not move in that round, and the ground it stood
  on was half right.** The bar was the bottom band in both editions and
  on both sides of a boot, because the file that renders the roster is
  the file the live driver patches: a header drawn at the top before
  boot and at the bottom after would move a site's navigation out from
  under the reader one frame in. That much still holds and is what the
  next section is built to keep. What did not hold is the conclusion —
  the shape a *reader* gets is not the shape a *driver* stated, and the
  argument above only ever ruled out the second. There is still no
  placement API here for the reason there is none anywhere else
  ([elements.md](elements.md)).

Which leaves what the finding actually reported. The header was below
the `h1` in *document order*, and that is what a roster fixes outright:
a nav is a chrome layer, so the title seats after it, and the chrome
mount is written before the content mount — the destinations lead the
page's title in the markup and in the focus order. Nothing is reordered
by CSS, which is the posture that ruled out the other workaround in the
first place.

## The semantics were right and the material was wrong

The site that asked for the seam adopted the roster, and what its
readers got was six filled capsules centred above an `h1`, on a page
whose every other line is ranged left in a column. On a phone they wrapped
into a grid of buttons. The site had worked the placement around with a
stylesheet of its own that stood `.nav` up out of the fixed band, plus
two tripwires: one failing the build if nokre's sheet ever stopped
declaring `.nav { position: fixed`, and one failing it if any page's
roster came out collapsed. Both existed because the override had no
contract behind it.

**A pill in a band across the bottom is a thumb affordance.** It is
right for a phone, where reach is worst at the far edge, and it is the
oddity anywhere else. The material was not a static-site problem: an app
shell's web build wears the same capsules in a 1400px browser window.

### The discriminator is the reader's window, not the writer

The obvious seam was the attribute from the section below — `document.zig`
stamps `data-nokre="document"` on exactly the pages a generator writes.
It is refused, and the ground is worth keeping: **a browser is a
browser.** Whether nokre's static writer or its packaging wrote the file
is invisible to the reader and says nothing about how a nav should look.
What says something is width. So the rule is one width rule in the DOM
edition's stylesheet — band at a phone's width, header above it — and it
holds for a generated page and an app shell alike.

Everything a build-time answer would have cost is what a stylesheet does
not spend. There is **one markup**, so the wasm side needs to know
nothing and cannot disagree with the file. **Nothing is measured against
a window nobody is looking at**: a generator hands core a viewport it
invented, and the shape a reader gets no longer follows from it. And a
page that boots carries exactly the nodes its first live frame rebuilds,
so the handover stays a patch.

**The breakpoint is derived, not picked** — a magic pixel value is what
the round before this refused when it turned down a viewport-derived
cap. It is `sheet_max_w`, the pane cap, which is already the sheet's only
breakpoint: at and below it every bottom-anchored surface nokre draws
*is* the screen, edge to edge with no side edges to round; above it each
is a pane standing in a window with room beside it. A bar sorts on the
same fact and spends the same number, so the two cannot drift.

### The header wraps, so nothing above the cap may collapse it

The width rule above was half-applied for one release, and the half that
was missing is the one core owns. The sheet wraps the header; core went
on measuring the roster against a single line and swapping the row for
the collapsed chip when it did not fit — so a browser window between the
breakpoint and wherever the pills happened to fit again showed **one
plated capsule where a site's sections should be**. Two mechanisms, one
question, opposite answers.

A row that wraps has no width at which it fails, so there is nothing to
reshape for. Core declines before it measures. The condition is not a
width, though, and this is why it could not simply be deleted: **the
reference renderer does not reflow.** A native desktop window at 600px
would clip an over-wide row, and clipping is what collapse is there to
prevent. So the input is the *medium* — `layout.Medium`, `clips` or
`reflows` — and it is a driver's word, installed exactly like the text
measurer and for the same reason: the thing that will actually draw the
page is the thing to ask. `live.zig` declares it at boot, `dom.document`
declares it at the top of a file it is about to write, and **no consumer
states it**, because a consumer that could state it would be a second
place for it to be wrong.

### The retraction: a page with no boot script was held out of the band

The paragraph that used to stand here said the opposite of what follows,
and the correction is worth keeping visible rather than editing out. It
reasoned: which shape fits is a question a *driver* re-asks every time
the window moves, and the answer it falls back to when a row will not
make a line is a chip that opens a list; a page with no `boot` has
neither; so the markup it was served in has to be the one shape that
answers every width, and the sheet's band excluded it with a `no-boot`
class.

**What a reader got was a published page with no bottom bar on a phone.**
The reasoning smuggled a fact about the *file* into a question about the
*window*, which is the move the section above refuses — and the section
above was right the first time. It also mis-stated the problem. The band
did not need a driver; it needed **an answer for a row that will not
fit**, and it had only ever had one because a driver's was the only one
anybody had written down.

There are three answers and the band can carry one:

- **Clipping.** What a nowrap row in a fixed layer does left alone: the
  ends hang past both screen edges and no gesture reaches them. Not an
  answer, and what shipped before the band existed.
- **Wrapping.** Ruled out by arithmetic rather than taste. The band's
  height is `nav_bar_pad + nav_slot + bar_bottom + safe_bottom` and the
  screen reserves exactly that much beneath itself; a second line makes
  the band taller than the number the reserve repeats, and the page's
  last line ends up behind the destinations.
- **Scrolling.** What the band does now. The row is a scroll container,
  it packs to the start when it overflows instead of centring — a
  centred scroll container's leading overflow cannot be reached — and it
  is *one line tall either way*, so the reserve stays exact. Every
  destination is a link with an address of its own, in document order,
  and a browser scrolls a focused one into view, so a keyboard, a screen
  reader and a crawler reach all of them whatever a pointer finds. The
  one thing it gives up is the scrollbar: a scrollbar in a fixed band is
  height the reserve cannot see, so there is none, and what carries the
  affordance is the pill cut off at the screen edge.

The chip is then what a driver **upgrades** that shape to, not what the
shape depends on. `no-boot` is gone, nothing in the sheet asks whether
anything is running, and one markup takes the band at a phone's width
whoever published it.

### Whether a page needs a runtime is derived, and `boot` is a floor

`Document.boot` was a driver's declaration, and the failure a
declaration invites is the silent one: a file that renders, shows its
controls, and does nothing when they are pressed. Nobody should be
typing that fact, because it is not a fact about intent — it is a fact
about **what is on the page**, and nokre has just built the tree.

So nokre derives it. `Element.needsRuntime` is exhaustive over a closed
element set, which makes the derivation total rather than a heuristic,
and it draws one line: **a link is answered by the browser and a control
is answered by an app.** Prose, headings, images, tables, code blocks,
QR codes, `link`, `nav_item`, the roster's own row and a `tile` that
navigates publish and work with nothing running. A `button`,
`icon_button`, `more`, `back` or a `tile` that acts; a `toggle`,
`checkbox`, `text_input`, `text_area`, `segmented`, `radio_group` or
`select`, every one of which keeps its state in the tree and only
mirrors it into the DOM; a `copyable`, whose press writes the clipboard;
and every layer that exists because something is running — `sheet`,
`picker`, `notice`, and the collapsed roster's `nav_current` among them
— need one.

Two consequences worth stating outright.

- **A generator must arrive at each page rather than push to it.** A
  pushed screen wears the framework's Back control, and Back pops a
  stack no published file has. `switchTo` per page, which is also what
  the live driver boots a document with.
- **`error.NavChipNeedsBoot` is gone** and no rule replaced it. The
  collapsed chip is a `nav_current`, a `nav_current` needs a runtime
  like every other combobox, and the case is now one row of a table. Its
  remedy is unchanged: generate at a width the row fits, which costs a
  document nothing.

**What is still the driver's is `Boot` itself.** nokre does not know
where a site published its wasm module, its driver directory or its
seed, and cannot invent any of them — the doctrine `Meta` already states
for URLs. So the pair is a **floor, not a ceiling**:

```zig
.boot = if (dom.needsRuntime(&app) != null) boot_options else null,
```

A page whose tree needs a runtime and carries no `boot` is
`error.PageNeedsBoot`, refused before a byte. A page whose tree needs
none may still carry one, for a need no tree can show — a screen whose
static shape is deliberately inert because what it will draw has not
been fetched yet. Only the missing direction is refused, because it is
the only one where being wrong is silent.

**What is still the driver's is the column.** nokre puts the header on
the page's own 16px margin, inside whatever element the driver mounted
the chrome into. Where the driver mounted the chrome and the screen into
*two* boxes and centred one of them in a reading column, its own
stylesheet has to bring the header into that column — the content class
is a name the driver invented (the table above), and a library that
guessed at the column would be styling a box it has never heard of.

**One thing this does not fix, stated so it is not read as fixed.** Core
measures the roster in *pills* whatever shape it is about to be drawn
in, so the width at which a band's row begins to scroll is a pill's
width rather than a word's. That is the same residue it always was: one
measurement, one viewport, two shapes. What is gone is the residue that
mattered.

## A generated document has no host, so it has no unstyled half

A footer spliced into `body_end` used to render in the browser's default
serif. It sat outside the screen's own element, and every rule carrying
the library's type is scoped to nokre's surfaces — deliberately, on the
ground that *the page around an embedded app is not this edition's to
turn around*. That seam is gone two sections down and the footer is
inside the screen now; the block it produced stayed, because what it
turns around is the page itself.

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
font-smoothing hints and the tap highlight the screen already carries.
The paper is what earns it now — a driver that centred the screen in a
reading column of its own leaves a band of `body` down each side, and
unpainted that band is the UA canvas, which on the dark ramp is a white
margin around a black page. The type reaches the one element outside
both mounts, which is the skip link.

**Where it stops is inheritance.** Every declaration in it is inherited
or paints the page; none reaches into a shape somebody else chose. That
was the line while a driver could splice a list into the body and keep
its markers, and it is the line still — the head takes markup nokre did
not write, and nothing in a head renders.

## The writer knew, and the reader beside it assumed

The site that produced every section above adopted the round they landed
in and came back with two findings. They are **one item**, because they
are one defect twice. In each of them a fact was already written down
correctly by one part of this edition, and a second part a few hundred
lines away answered a question about the same fact on a coarser input —
and got a different answer.

Neither is a missing feature and neither is a refusal. Both are the
library disagreeing with itself, which is the failure this page has been
about since its first paragraph: **two writers of one fact, and the
second one is where it goes wrong.** What is new is that the second
writer need not be a *copy*. It can be a derivation reading one level up
from where the fact lives — the kind instead of the thing, the screen
instead of the document — and at that altitude it cannot see the case
that would have changed its answer.

The test both of these failed, and the one to run on the next
derivation: **what is the finest thing this is a fact about, and is that
what it reads?**

### A tile is an anchor when it navigates and a button when it acts

`needsRuntime` took a `Role`, and `.tile` was unconditionally a control.
But a `tile` is *the row-shaped form of `link` and `button`*, and the
serializer beside it had always said so out loud — `<a class="tile"
href>` when it carries a route, `<button class="tile">` when it carries
a press. One file could tell an anchor from a button and the file next
to it could not.

What that cost is the ordinary shape of a static site. A home page and a
section hub are tile groups of pure navigation; both derived a need
neither had, and both shipped a **575 KB module their readers never
ran** — boot going from two pages to four. There was no remedy, either,
and that is the part worth keeping in view: `boot` is a floor, so a
driver may add a runtime and may never take one away. The correct
answer, "this page needs nothing", was unstatable. The consumer
published the module and reported it rather than gut its main navigation
surface into plain links, which is exactly right and is what a floor
should cost when the floor is wrong.

So the census asks the **element**. `Tile.route` decides it, for the
same reason it decides the tag, and it decides it *totally*: a tile
carries exactly one destination or it does not enter the tree
(`TileHasOneDestination`, `TileNeedsDestination`), so route-or-press is
a partition rather than a guess. `Span.route` was the precedent and it
is the same precedent it always was — a field that says whether a thing
navigates or acts, read by whoever needs to know.

**The rest of the table was re-read against that and none of it moved.**
It is worth saying which nearly did:

- **`notice`** carries a `route` too, and its open control genuinely is
  an anchor. But a notice is installed by `App.notify` and arrives with
  its dismiss and expand controls beside that one, so the *layer* needs
  an app whatever the row links to.
- **`button`** could have read `Action.wired` and answered "no" for an
  unwired one. It does not. An unwired button is inert with or without a
  runtime, and deriving "this page needs nothing" from it would turn
  *you forgot to wire it* into a published page of dead controls — the
  silent direction, which is the whole reason this derivation exists.
- **`copyable`, `back`, `nav_current`, `more`** and the modal layers are
  facts about the kind. A copyable's press is intrinsic and writes the
  clipboard; Back pops a stack; a chip opens a list. None of them has a
  field that could say otherwise.
- **`link`, `nav_item`, `scroll_region`, `code_block`** were already on
  the browser's side whole, and stay there.

### A footer in the seam is the last thing in the document

The clear space below bottom chrome — the band's own height plus the
24px nothing may rest inside — was `padding-bottom` on the screen. That
is correct exactly while the screen is the last thing in the document,
which is true of every app mounted in a page it did not write and false
of the page this library also writes: `Document.body_end` is a seam
whose stated job is *whatever stands below the app but inside the
document*.

So a driver putting a footer there — doing precisely what the seam is
for — got 73px of copyright, links and a language row under a 72px fixed
band, at 375px, on every page in every locale. Padding is inside the box
it is on, and the footer was outside it. Nothing in the library could
say so and nothing did.

The consumer fixed it in a stylesheet of its own, and that fix is the
diagnosis: it **re-derived five of nokre's `:root` properties and its
breakpoint literal** to work out a number the library already knew. A
consumer coupled to nokre's arithmetic is a consumer that breaks
silently the next time a metric moves.

**The space went at the bottom of whatever was last, and nokre was told
which that was rather than guessing.** `document.zig` was handed the
seam's bytes; where they were non-empty it wrote one class on `<body>`
(`has-seam`), and the reserve landed on the document instead of on the
screen. The arithmetic never left the library, and a driver spent
nothing.

Two things fell out of that and one of them survived the section below.

- **`--chrome-reserve` is published.** The sum had been written out
  twice in longhand, which is the drift this file exists to rule out, so
  it is a `:root` property spent by all four of its rules. It is still
  there, for the case that outlived the seam: a *host* page with an app
  of nokre's mounted in it, which may have something below that mount
  and which this edition may not touch.
- **The class did not survive**, and the next section is why. It asked
  *is this string non-empty?* as a proxy for *is there content below the
  screen?* — a fact about bytes the library could not read.

## A seam is for what does not render

The section above and "A site's header is a roster" are the same finding
approached from two ends of one page, and the round after them collapsed
both into a rule that can be applied before the fact:

> **A byte seam is legitimate exactly where the thing in it is not
> content.**

`Document.head` passes and always did. A `<meta>`, a CSP, a JSON-LD
block, a preload, a favicon: nothing in a head is a thing a reader sees,
so nothing in it is a thing the library could have styled, cleared,
audited or resolved, and handing it over as bytes gives up nothing. It
is a real need with no element behind it and there never will be one.

`Document.body_end` failed. Every consumer that ever used it put a
**footer** through — a stack of links and a line of text — which is
content wearing markup's clothes, and the disguise was billed to this
repo over three revisions:

- The footer rendered in the browser's default serif, because bytes
  outside `.nokre` are styled by nobody. Fixed with a document reset.
- The fixed band covered 73px of it at 375px on every page, because the
  reserve is padding *inside* the screen and the seam was outside it.
  Fixed with a class and a second set of rules.
- And what was never fixed, because no round had been bitten by it yet:
  no landmark, no a11y audit coverage, no route resolution through
  `Refs`, and nothing anywhere checking what was in there at all.

So `body_end` is deleted, and a footer is what it always was — a `stack`
of `link`s and a `text`, appended last by the page builder, exactly as
that consumer's header became `App.setNav`. It is then inside `.nokre`
(styled), inside the reserve (cleared), in the tree (audited), and its
destinations resolve against the route table at build time. `has-seam`
went with it, the paired reserve rules collapsed back to one, and the
comptime check keeping the live driver off the class went too.

**Nothing in the library grants any of that**, which is the part worth
keeping. They are not four features the footer was given; they are four
things that were already true of everything in the tree and that a seam
was the only way to opt out of.

### The `contentinfo` landmark is the loss, and it is a small one

A `stack` serialises as a `div`, so a footer that used to be `<footer>`
no longer announces itself as `contentinfo`. That is a real thing to
give up and it is weighed on what it does for a reader rather than on
whether the tag is standard.

It does little here. No WCAG success criterion requires it; the
sufficient technique that names landmarks (ARIA11) is one route to
**2.4.1 Bypass Blocks**, and a page this writer produces already
satisfies 2.4.1 twice — a skip link straight to the content mount, and
the roster as a `nav` landmark ahead of it. What `contentinfo` adds on
top is a shortcut to the *end* of a page a reader has already been given
two ways past. This is the same class of claim `multiple_h1` was retired
for carrying no citation of ([accessibility.md](accessibility.md)), and
it is measured the same way.

Against that: an element for it would be the full checklist — layout,
markup, a11y, validate/audit, input, tests, golden, renderer contract,
docs — for something meaningless on five of the six platforms nokre
draws on. A native app has no page footer. The doctrine's answer is the
right one: **an element earns its place if an app needs it, and
document furniture is ceremony.**

### What the deletion cost, and what answered it

One thing, and the round after named it rather than being quiet about
it. A site's footer often carries a **language row** — each language
named in its own language — and the anchors under it want `hreflang`,
`lang` and `dir`. Measured one at a time:

- `hreflang` is already the library's and already correct: the head
  carries the whole `<link rel="alternate" hreflang>` set from
  `Meta.alternates`, checked for reciprocity and self-inclusion
  ([alternates.zig](../src/render/dom/alternates.zig)). The copy on the
  anchor told a crawler nothing new.
- `dir` on a run that is wholly right-to-left is what the bidi algorithm
  answers anyway, in both editions.
- **`lang` was the residue, and it was real**: WCAG 2.2 **3.1.2 Language
  of Parts** (AA), and a language chooser is that criterion's textbook
  case. Without it a screen reader says `فارسی` with English phonemes,
  which is not an accent — it is noise where the one word a reader who
  cannot read this page was looking for should have been.

That was never a reason to keep a general byte escape hatch for one
attribute. The seam did not make the attribute *correct* — nothing in
the library ever read it, so a footer claiming `lang="fs"` would have
published — it only made it unchecked. It is a **field** now:
`element.Link.lang` and `element.Span.lang`, a BCP 47 tag on the two
elements a run of words can be, empty on every run that is in the
document's own language.

**The library reads it, which is the whole of the difference.** The tag
faces `element.validLangTag` at `append`, in the same seat and on the
same argument as `Heading.anchor`'s grammar and an external link's
scheme: `error.InvalidLangTag`, and a page that would have carried a
malformed attribute does not build. It is question 2 above, answered the
way the origin answers it — nokre cannot know your language, it can see
that `Persian`, `pt_BR` and `tr-` are not tags — and it stops exactly
where question 3 starts. `fs` is well-formed and is not a language, and
telling the two apart takes the IANA subtag registry, which nokre will
no more ship than it ships `lastmod`'s clock. The difference between the
two refusals is the failure mode: a wrong tag degrades to the page's own
voice, which is what the reader had before the attribute existed, while
a *malformed* one is markup a browser drops on the floor without saying
so.

There is no `dir` beside it and there will not be a second field for
one. 49 measured it redundant; if a mixed-direction label ever proves
the measurement wrong, the direction is **derived** from the tag
(`l10n.directionOfTag`, which is exactly that function and is what
`L.dir` already calls), never stated a second time.

And the fact underneath is still one nokre holds twice — `Alternates` is
one path per bundled locale, `localeStub` writes `<a hreflang lang dir>`
over exactly that set — so the value a driver passes is `L.tag(loc)`
off its own bundle, the same way the alternate set takes its tags. A tag
typed by hand is where this goes wrong, and typing one is already the
mistake.

Two things it deliberately is not. It is not on `text` or `heading`: a
whole passage in another language is one span over the whole content,
which the set already spells, and a field would be a second spelling.
And it is not an audit rule — the only rule anyone could write is *this
run's script disagrees with the document's language and states nothing*,
which is script inference standing in for language, and the library
guessing is what question 3 refuses.

### The rest of `Document`, against the same test

Asked of every other field, and none of them fails:

- `head` passes, above, and is the only seam left.
- `title`, `description`, `meta` are head content: a `<title>` and a
  string of `<meta>` tags, none of which renders.
- `chrome_id`, `content_id`, `content_class`, `stylesheet`, `boot` are
  names and destinations the driver invented. `content_class` is the
  nearest call — it is a class list, so it is *styling* — and it passes
  because a driver that mounted the screen in a reading column of its
  own is the authority on that column's name, which is the same ground
  the two ids stand on.
- `skip` is the interesting one, because it **is** content: words a
  reader can see, in the document's language. It is not a seam, and the
  difference is the whole distinction. nokre writes the anchor, its
  class, its target and its rule; the driver supplies a string into an
  element the library owns. A parameter is not a hole.

## Two scripts run on your pages, and neither is written into them

A page that boots runs one script and a chooser stub runs another. Both
are the library's own JavaScript, and for three revisions both were
`<script>` blocks written into every page.

**That is a policy your site cannot afford.** `script-src 'self'` is the
largest single thing a Content-Security-Policy buys — it is what turns
an injected `<script>` from a compromise into a console message — and it
refuses an inline block whatever wrote it. The usual escape is a
per-block hash, and a static site has none available: a boot block
carries that page's route and that page's locale, a chooser block
carries that page's destinations, so the number of distinct bodies is
the number of pages you publish. The first site to publish one had 1,132
of them behind a single response header, which cannot carry a per-page
hash, and turned the whole directive over to `'unsafe-inline'` — for
scripts the library had written itself.

So the bytes that differ per page are stated as **data** and the code is
a **file you already publish**:

```html
<script type="application/json" data-nokre="boot">{"wasm":"/app.wasm", …}</script>
<script type="module" src="/live-boot.js"></script>
```

**What this costs you is one field and one habit.** `Boot.driver_dir`
already said where you published `dom.driver_files`; `LocaleStub` now
takes the same field, because a stub loads a file too. And the set has
two more members in it — `live-boot.js` and `locale-stub.js` — which
costs nothing at all if you install `App.web` whole or copy
`dom.driver_sources`, and is a page that renders and never boots if you
re-typed the list. That set is data for exactly this reason.

**What you get is a directive you can actually write.** A page out of
this writer carries no executable byte of its own: every `<script>` on
it is a `src` or an `application/json` data block, and a browser never
runs a data block — HTML calls it a data block and stops before the
policy is consulted, which is why `application/ld+json` has always
ridden under a strict policy and why your own structured data in the
head seam is free too. `script-src 'self' 'wasm-unsafe-eval'` is
reachable, and the wasm keyword is the module rather than a loosening.

`style-src` is the one that does not follow, and it is unrelated: the
serializer writes inline style *attributes* carrying numbers layout just
computed — a list's measured gutter, a QR's whole-pixel side — which
cannot be hashed and cannot move into script, since a page that never
boots must still render right. The narrow pair is `style-src-elem
'self'` with `'unsafe-inline'` left only where an attribute needs it
([internals/dom-edition.md](internals/dom-edition.md)).

## A default is not an opinion about your site

A handful of these fields do carry defaults, and the rule is worth
stating because it is what keeps a default from becoming a decision the
library made for you: **where a field has one, the default is a fact
about nokre — never a guess about your site.** `Boot.addressing` is
`.fragments` because that is `mount`'s own default in the live driver,
not because a site should prefer it. `Boot.driver_dir` — and
`LocaleStub.driver_dir` beside it — is `/` because that is where
installing `App.web` whole puts the driver set.
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
be a page that renders and is wrong. The two `driver_dir`s are the
near miss and they land on the other side for a stated reason: `/` is
not a guess about where you put things, it is where `App.web` puts them
if you did nothing.

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
