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
