# The DOM edition

The second renderer. It walks the same semantic tree
[renderer.zig](../../src/render/renderer.zig) walks and writes **markup**
where that one writes draw calls.

[renderer-editions.md](renderer-editions.md) is why this was possible;
this document is what it actually is, what it owes the reference
edition, and where it stops short.

It **is** the web now. The canvas shell it replaced — the wasm module
blitting Skia into a canvas, the ARIA mirror beside it, the from-source
Skia build and the project-local emscripten SDK — is deleted, along
with `tools/build-skia-wasm.sh` and `tools/build-web.sh`. `zig build
web` produces this.

## Why a browser is a strange platform to rasterize for

On every other platform nokre draws pixels and hands a parallel
accessibility tree to the OS. On the web that parallel tree is an ARIA
mirror of the snapshot, painted beside a canvas.

But the DOM **is** an accessibility tree. Rendering into it means the
a11y tree is not a mirror of the pixels — it is the thing the pixels are
made from, which is exactly what [introduction.md](../introduction.md)
claims for every nokre platform and only this one gets for free. A
heading is `<h1>`, a switch is `role="switch"`, a list renders its own
ordinals, and none of it can drift from what the app built, because
there is only one tree.

The other half is what Skia was buying. What makes nokre's layout
deterministic is core's integer math and HarfBuzz's advances, not the
rasterizer — [pixel-model.md](pixel-model.md) says so outright:
everything upstream of the scaler is identical everywhere, and platforms
disagree only about the ink inside a glyph's box. Skia rasterizes text,
axis-aligned lines and rounded boxes. A browser already rasterizes those.

What a browser also gives, and a canvas forfeits: text selection,
find-in-page, translation, reader mode, print, native IME in a real
field, user stylesheets, and links that a crawler and a link previewer
can see.

## The split, as renderer-editions.md wrote it

| Stays with the Skia edition | Travels to any edition |
| --- | --- |
| grayscale ramps as *painted bytes* | the semantic tree |
| CPU raster, no driver variance | event behavior and focus traversal |
| **pixel determinism** | the accessibility snapshot |
| byte-exact screenshot goldens | the validate / audit rules |

Two refusals move to the per-edition column, and they should be named
rather than quietly dropped:

- **No fractional scaling** is unenforceable here. A browser will hand
  out a 1.1 device pixel ratio and fractional CSS pixels, and no edition
  can refuse them on its behalf.
- **No system fonts** holds for everything the bundled faces cover
  and no further. A codepoint outside them falls back to whatever the
  reader has, because a browser will not be told otherwise.

Everything else survives intact. There is not one `:hover` rule in the
generated stylesheet, no transition and no animation. The appearance is
`App.appearance()` here as everywhere else — the app's own `scheme`
resolved against what the OS reports — so the sheet carries both ramps
and a driver stamps the resolved one; `prefers-color-scheme` is the
fallback for a page with no app behind it, not the answer.

## Two drivers, one walk

- **Static** — [serialize.zig](../../src/render/dom/serialize.zig)
  writes a screen out as markup. No server is involved at any point:
  the driver runs at build time and the output is files.
- **Live** — [live.zig](../../src/render/dom/live.zig) and
  [live.js](../../src/render/dom/live.js) run the app in a browser: the
  identical `App`, the identical tree, the identical serializer,
  re-rendered when state changes.

A static page is the useful degenerate case of the pair: it navigates
with real links and zero JavaScript, and the live driver is the upgrade
rather than the requirement. Running *both* over one page is the next
section; it is what [getnokre.github.io](https://getnokre.github.io)
does, and it is the arrangement the two drivers were split for.

### What the live driver costs

`zig build web` produces the kitchen sink as **one ~200 KB `.wasm`**,
35 KB of glue in three modules, and the generated stylesheet. No Skia, no
emscripten, no libc: `wasm32-freestanding` and `std.heap.wasm_allocator`
are the whole platform requirement, because the rasterizer this edition
needs is the one already in the browser. (The three headers nokre's
vendored qrcodegen wants where there is no C library are
[shim/freestanding](../../shim/freestanding/README.md) — four
declarations and four definitions.)

Which edition a wasm build carries is not a discovery either: wasm32 is
this edition, and `src/nokre.zig` forces the live driver's exports on
that target. Nothing on the consumer's side reaches them — the browser
drives exports — so lazy analysis would otherwise drop the whole driver.
The one thing a consumer's root still owes is a reference to the library
(`comptime { _ = nokre; }`), because `main` never runs here and without
it nothing pulls nokre into the build at all.

### The unit is the site, and there is one assembler

The module is half of what a browser needs; the other half is the glue
that instantiates it, the stylesheet, the faces, and a page. Those are
not the app's, so they cannot be the app's build's — and for a while
they were nobody's on the consumer's side: `zig build web` assembled
them here, `addApp` handed a consumer a bare `.wasm`, and the recipe
for the rest was a paragraph in getting-started.md. A paragraph is a
poor place for it. Miss `services.js` out of the set and the failure is
a blank page in someone's browser, not an error in anyone's build.

So the set lives in exactly one function — `addWebSite` in
[build.zig](../../build.zig) — which `addApp` calls for every wasm
target and which nokre's own `web` step calls for the kitchen sink.
What it writes:

| in the site | where it comes from |
| --- | --- |
| the app's module, under `web_wasm` | the consumer's own compile |
| `live.js`, `live-boot.js`, `live-worker.js`, `services.js`, `locale-stub.js`, `sw.js` | `src/render/dom`, copied by the build graph; the set is also exported as data for a generator that publishes the driver itself — `dom.driver_files` for the names, `dom.driver_sources` for the names *and* the embedded bytes, so such a generator writes files it never had to locate |
| `style.css` | *generated*, by running `emit_css.zig` on the host |
| `fonts/*.ttf` | `src/assets/fonts` |
| `index.html`, `page.css`, `boot.js`, `manifest.webmanifest`, `icon-*.png` | the packaging tree's `web/` corner (packaging.zig) |
| `site.manifest` | *generated*: every row above as data — one path per line, sorted |

Two properties follow, and they are the reason for the shape. Nothing
in a site can be stale, because nothing in it is a copy a human made:
the stylesheet is generated from `color.zig`/`text.zig`/`layout.zig` on
every build, the glue and the faces are graph inputs, and the page is
an output of the app's declaration. And nothing in a site can be
*partial*, because a consumer installs one directory rather than
assembling a list — `App.web`, exactly as they install `App.pkg`. A
new module added to `src/render/dom` is one edit here and it is in
every consumer's next build. (`sw.js` is the one member that is not a
module import but a file the origin serves — why every site carries it
is [notifications.md](notifications.md).)

`site.manifest` is the same set, stated as data for whatever *deploys*
the site: tooling that copies `App.web` somewhere and wants to verify
the copy landed whole reads the list instead of re-typing this table
and drifting — the consumer story is getting-started.md's web section.
It names the servable content, not itself, and the web services gate
(tests/web_services.mjs) holds it identical to the directory it ships
in, both ways.

The page is the declaration's, which is why a web target without one
fails: `packaging.webIndexHtml` needs a title, and the manifest and
icons need an identity. The refusal follows the invalid-declaration
rule the packaging tree already uses — the fail rides the tree's step,
so a build that never installs the site proceeds and one that does
fails naming `.pkg`. The kitchen sink is the exception that proves the
rule: it links zero services by contract, so it cannot declare `.pkg`
to `addApp` at all, and its site is assembled around the declaration
handed straight to `addPkgTree` — the arrangement `zig build pkg`
already used for its manifests.

There is no second host page anywhere. The hand-written one this
directory used to keep was the same page `webIndexHtml` emits, minus
an identity, and two of a thing that must agree is one too many.

### The page states what it is allowed to fetch

A site nokre assembles whole is a site nokre can tell the truth about,
and the truth is short: it loads its own module, four of its own
scripts, two of its own stylesheets, its own faces and its own icons,
and it talks to no host it was not told about. That is a
Content-Security-Policy, and the page carries it as a `<meta>`.

The per-directive inventory is [csp.zig](../../src/render/dom/csp.zig),
which is a leaf beside `driver_files.zig` and for its reason: both
writers of HTML here spend it — `packaging.webIndexHtml` for the shell
page and `document.zig` for a generated one — and build.zig reads
packaging, so nothing in it may reach the rest of the library. One
inventory rather than two because the *edition* is what it describes,
not the page: what a shell fetches and what a published page fetches are
the same list of things, and written twice the second copy is the one
that falls behind the day this edition learns to fetch something new.

It belongs here rather than in a consumer's hands for the reason
`services.js` does. A page a build regenerates is a poor place for a
hand edit, an app's edge is a different piece of software on every
consumer's side, and every one of them needs the same policy — so the
one that is derived from what the edition *does* is worth more than
whichever one each consumer would have written. `default-src 'none'` is
what makes it an inventory rather than a wish: a fetch nobody named is
a fetch nobody makes, and the day this edition needs a new kind of
request the page fails loudly in a browser rather than quietly widening.

**Two things in the edition moved rather than the policy.** The page
used to carry its column in a `<style>` block and its mount in an inline
`<script>`; both are files now (`page.css`, `boot.js`), because
`script-src 'self'` refusing an inline script is the largest single
thing a policy buys, and a page that hashed its own two blocks would be
one no consumer could lift to their edge without carrying hashes that
change under them.

**And two revisions later the static writer made the same move**, which
is the section below. This page had one inline block and could have
hashed it; a generated site has one per published page, each carrying
that page's own route and locale, so hashing was never available there
at all — and the whole `script-src` of the first site to publish one went
to `'unsafe-inline'` for scripts nokre had written itself.

**One loosening stayed, and it is `style-src`'s.** The serializer writes
inline style *attributes* on element after element — a list's measured
gutter, a QR's whole-pixel side, a track's bleed, a container's own gap
and padding — and every one of them is a number layout just computed,
so none can be hashed and none can be a stylesheet's guess (the four
seams above say why each is measured). Nor can they move into script:
the static driver writes pages that run none, and they must render
right with the module blocked. So the page splits the directive instead
of widening it — `style-src-elem 'self'` for the two `<link>`ed sheets,
which is what refuses an injected `<style>`, and `'unsafe-inline'` left
only where an attribute needs it.

**`connect-src` is the one directive an app outgrows**, because a fetch
is the only outbound request an app's own code can make here: no app
supplies script, style, faces or images to this edition. So it is the
one seam a consumer gets — `web_connect_src` on `addApp` for a shell,
`Csp.connect_src` on a `Document` for a generated page, a list of hosts
that joins that directive and no other — and the entries are checked
before they reach the page (`csp.badConnectSrc` on both paths), because
a string that lands inside a policy is a string that could end the
directive it landed in. The default is empty, which is the app's own
origin and nothing else.

**What a `<meta>` cannot carry, whatever it says.** `frame-ancestors`,
`report-uri`/`report-to` and `sandbox` are ignored in one by spec, so
they are the deploying edge's — getting-started.md tells a consumer so
in as many words, because a page that looked like the whole story would
be worse than no policy at all. `serve.zig` sends the first of them as a
header on every response, which is nokre saying at its own dev server
what it tells a consumer's edge to say. One directive an edge must
*not* add: `require-trusted-types-for 'script'` would break the live
driver, whose whole write path is parsing a frame off-document
(`template.innerHTML`) and patching it in.

### Serving it, which is not optional

A site cannot be opened, only served: `WebAssembly.instantiateStreaming`
wants `application/wasm` and an ES module import wants a JavaScript
type, and a `file://` URL supplies neither — both fail as a blank page
rather than as a message. So the server is part of the edition, not an
errand left to the reader:
[serve.zig](../../src/render/dom/serve.zig) is a host tool beside
`emit_css.zig`, `zig build serve` runs it here, and
`nokre.addWebServe` gives a consumer the same binary over their own
`App.web`. It binds loopback only, states the two content types a
browser refuses to guess, answers `no-store` so a rebuild is one
refresh away, and resolves a target to a path inside the site or to
nothing at all. Its two decisions are unit-tested in the file, and
`main` is referenced by a test so a broken server is caught by
`zig build test` rather than by a developer who wanted to look at their
app.

### Live over a generated page

The two drivers over one page, which is the pairing the split exists
for: the file a reader is served is the app's **first frame**, and the
module that boots on top of it is the same `App` over the same route
table, re-rendering the same screen.

It is not an optimization. A generated page is a screen measured with a
ruler that is not the reader's — a build has no font metrics and no
window, so `text.Measurer.fixed` answers every measured question against
whatever viewport the generator declared. Prose wraps somewhere else, a
row of actions never folds its tail, and `navCollapses` is asked about a
window nobody is looking at, so a roster that cannot fit a phone runs off
the edge of one instead of collapsing. Those answers cannot be fixed by
CSS, because they are not style: they are decisions core made from a
number. The only repair is to ask again with the right number, which is
what booting does.

A **wrapping** row is the one that comes out right anyway, for a reason
worth naming. *Which* rows wrap is `layout.rowOverflow`, a question about
the children and not about a width, so the serializer answers it with no
ruler at all; *where* the lines then break is `flex-wrap`'s, which is the
reader's own metrics in the reader's own window. The fold needs a
measurement a generator does not have. Wrapping needs none.

#### Neither script on a generated page is an inline one

`dom.document` writes a boot and `dom.localeStub` writes a chooser, and
both used to be `<script>` blocks with the library's own JavaScript in
them. That is what `script-src 'self'` exists to refuse, and the refusal
is not one a static site can buy its way out of with hashes: a boot
block carries `route` and `locale`, a chooser block carries that page's
destinations, so the count of distinct bodies is the count of published
pages. The first migration to meet it — 1,126 stubs and six boots on one
distribution, behind one response header, which cannot carry a per-page
hash at all — turned `script-src` over to `'unsafe-inline'` for scripts
that were the library's from the first byte.

**The bytes that differ per page are data, not code.** So each of them
is two tags:

```html
<script type="application/json" data-nokre="boot">{"wasm":"/app.wasm","into":"chrome","content":"content","addressing":"documents","route":"docs","locale":"fa","seed":"/md/docs.md"}</script>
<script type="module" src="/live-boot.js"></script>
```

- **The code is a file the site already serves.** `live-boot.js` and
  `locale-stub.js` are members of `driver_files`, so a consumer that
  installs the driver set whole has them, and a consumer that copies
  `dom.driver_sources` gets them with no list to extend. One file, one
  cache entry, one parse, however many pages import it — where 1,132
  inline blocks were none of those things.
- **The data is a block a browser never executes.** HTML's script
  preparation calls a `<script>` whose type is neither a JavaScript MIME
  type nor `module` a *data block* and returns before the policy is ever
  consulted, which is why `application/ld+json` has always ridden under
  a strict policy. So the block costs the directive nothing, and there
  is no third thing to allow.
- **It is found by `data-nokre`, not by an `id`.** Ids on these pages
  belong to the driver: the two mount points are names a consumer
  invented and every heading id is derived from words. A library
  reserving a word in that space is a collision waiting for the page
  that spells it. `data-nokre` is already the attribute that says *this
  node is the library's*, and the value says which — `document` on the
  root element, `boot` and `locale` on the two blocks
  ([class_names.zig](../../src/render/dom/class_names.zig), where a
  comptime check holds each JavaScript selector against the Zig
  constant, exactly as it holds the class live.js toggles).
- **The block is `mount`'s option set, not a translation of it.**
  `live-boot.js` spreads the parsed object straight into `mount` and
  overrides only the two mounts, which travel as the ids the markup
  already used. So there is no second list of names to keep in step, and
  an option that grows on the Zig side arrives on the JavaScript side
  with nothing to update. Absence is a value: no `seed` is a builder
  that needs nothing fetched, no `route` is an app on no screen, no
  `addressing` is `mount`'s own default, and a written-but-empty
  `locale` is the catalog's template — which is why the key is always
  present and the other three are not.
- **The boot is a module and the chooser is not.** A module is deferred,
  which is right for a boot that has to find the mounts the page
  finished parsing, and wrong for a chooser: everything under a stub's
  script is a page the reader is not meant to see, so it is a classic
  script in the head with its data block immediately above it, where a
  script that runs *where it stands* can reach it.

What it costs is one request on a page that had none — a cold stub now
fetches a kilobyte before it redirects, and warms the cache for every
other stub on the site. That is the price of the directive, and the
directive is what the whole arrangement is for.

The one page that did not move is [packaging.zig](../../src/packaging/packaging.zig)'s
`webIndexHtml`: its boot already was a file, and there is exactly one of
it per site with two arguments out of the declaration, so it writes them
into `boot.js` and has no per-page data to state.

#### And then the page that could carry the policy did not carry one

The round above made `script-src 'self'` **reachable** for a published
page and stopped there. `dom.Document` had no way to state a policy at
all, so the site that adopted it shipped with none: no meta on any page,
no `_headers`, and nothing an edge could be pointed at — because
GitHub Pages serving a committed tree permits no custom response header,
and for that class of consumer a `<meta http-equiv>` is the only vehicle
there is.

**The head seam is not the answer, and the reason is position rather
than doctrine.** [static-sites.md](../static-sites.md) names a CSP among
the things `Document.head` is legitimately for, and for every other tag
in a head that is right. This one is different: a policy governs only
what the parser meets *after* it, and the seam is spliced at the end of
the head — after the stylesheet link, after the whole `Meta` block, and
on a stub after the chooser script itself. A policy written there reads
correct and lets through every subresource the head already asked for.
`webIndexHtml` has said so in a comment since it was written; what was
missing was the seat, and `Document.csp` is that seat: immediately
behind the charset, ahead of everything it governs.

**What it is, is derived.** A consumer passing a string would be passing
a copy of a library fact — whether a module is compiled, whether the
driver behind it can reach a worker, whether anything on the page
fetches at all — and the copy is what goes stale. So `Csp` is asked for
and then read off the `Document`:

| the page | what it grants past the floor |
| --- | --- |
| a booting document | `script-src 'self' 'wasm-unsafe-eval'`, `worker-src 'self'`, `connect-src 'self'` + declared hosts, the split `style-src` pair |
| a document with no boot | the `style-src` pair and nothing executable — `default-src 'none'` answers for every absence |
| a locale stub | `script-src 'self'` for its chooser, and an undivided `style-src 'self'`: its markup is written in document.zig and carries no style attribute |

`img-src 'self'` and `font-src 'self'` are on all three, and the second
of those is the interesting one: nokre's own markup spends neither. The
faces are the *stylesheet's*, fetched through its `@font-face` block,
and the icon is the head seam's — which is the one place a policy here
cannot see what it is granting, and is therefore granted the narrowest
thing that works. The one input to the whole derivation that no page can
see is where a driver published the faces (`stylesheet.Options.fonts`, a
different call, with a rooted default); that is stated in
[static-sites.md](../static-sites.md) rather than guessed at.

**Every source but the declared hosts is `'self'`, so the assets have to
be there.** A stylesheet, a wasm module, a driver directory or a seed
published off-origin is one the browser refuses on a page that would
otherwise have booted — a blank page with a console message, which is
the silent direction — so `error.AssetOffOrigin` refuses it before a
byte, along with a host declared on a page that boots nothing
(`error.ConnectSrcWithoutBoot`) and a source that could end its own
directive (`error.InvalidConnectSrc`).

**The obvious failure is a policy that blocks its own boot, and it is
gated where a boot actually happens.** tests/web_browser.mjs reads the
policy off the file `openPage` is served and enforces it on every
`fetch` and every service-worker registration after it, so the two
scenarios that boot the shipped `live.js` over a generated page boot
*under* the policy that page states. A directive dropped from the
derivation stops being a Zig test's opinion about a string and becomes
`Refused to load app.wasm` in a run that was mounting an app.

#### The document is the library's; the names in it are the driver's

This used to be a list of what a host document *owed*, and every static
consumer paid it by hand. It is now a list of what
[document.zig](../../src/render/dom/document.zig) writes, because the
first driver got some of it wrong and a second one was about to write
the same file again:

```zig
try dom.document(&em, .{
    .title = "Accessibility — nokre",
    .description = "The a11y contract…",
    .stylesheet = "/style.css",
    .meta = .{                   // canonical, Open Graph, the card
        .origin = "https://getnokre.github.io",
        .path = "/en/accessibility/",  // null on a 404: no URL of its own
        .alternates = &alts,           // one per locale, plus the chooser
        .site_name = "nokre",
        .title = "Accessibility",
    },
    .head = head.items,          // structured data, a preload, a favicon
    .chrome_id = "chrome",
    .content_id = "content",
    .content_class = "page",
    .skip = "Skip to content",
    .boot = .{ .wasm = "/app.wasm", .addressing = .documents, .seed = "/md/…" },
});
```

That call writes the whole file — doctype, `<html>`, both mount points,
the screen and the chrome inside them, and the boot script. **What the
driver supplies is every name and destination it invented**: the mount
ids, the URLs it published things at, the addressing mode, the words on
its skip link. That line is the one round two drew when it declined a
document helper that would have owned ids and an addressing mode
belonging to the consumer, and it did not move — what moved is the
structure around them. That line stated for the driver author who has to
work against it, with the test for a case neither half names, is
[static-sites.md](../static-sites.md); what follows here is why each
half sits where it does.

**The library's half is the facts it already holds.**

- **`lang` and `dir`.** The root element carries the locale the screen
  was built in: `App.locale()`, or — for an app that never chose —
  `element.default_chrome_tag`, the language nokre's own nav bar and
  close control are actually in, since `""` is not something a browser,
  a screen reader or a hyphenation table can act on. The direction is
  `App.direction`, and it is **two** attributes. `dir` is what browsers
  and assistive tech read; `data-direction` is the only thing the
  sheet's one mirroring rule matches, so a page stamping one of them is
  announced correctly and laid out backwards, or the reverse.

  The live driver stamps `data-direction` and deliberately never `dir`
  (live.js's `syncRoot`, which also does the appearance): an app mounted
  in someone else's document may claim nokre's own surfaces and not the
  page around them. Here there is no page around them — nokre wrote the
  file — which is the same refusal read from the other side rather than
  a hole in it. There is no media query for direction the way there is
  for appearance, so before this a serialized Persian page stayed
  left-to-right until, and unless, a driver booted over it.
- **The page's locale, not the reader's.** The same `App.locale()` that
  becomes `lang` is also written into the boot call —
  `mount({ locale })` — because the module landing on this file has to
  rebuild the screen the file already shows, and it would not have.
  `mount` seeds `navigator.language` where a page says nothing about a
  language, so a `/fa/…` page opened in an English browser hydrated
  **English over Persian markup**, silently: the handover matches by tag
  and position ("The seams" below), nothing in that rule looks at text,
  and a tree rebuilt in another language has exactly the same shape.
  The diff therefore *succeeds* — every string swapped, the
  direction flipped back under a document still announcing `dir="rtl"`,
  the reader's scroll position faithfully preserved on a page that now
  says something else.

  It is one fact and not two: there is no `Boot.locale` field, so a
  driver has no second locale to state and no way to state it
  differently from the attribute. The empty tag is written too, and
  means it — a document from an app that never called `setLocale` was
  rendered from its catalog's *template*, and `""` is the tag
  `L.resolve` answers with exactly that. Only an *absent* `locale`
  means "follow the device", which is right for the one page that has
  no screen in it yet ([packaging.zig](../../src/packaging/packaging.zig)'s
  `webIndexHtml`, whose `mount` call pins nothing).

  That page is the other side of this whole arrangement and the reason
  it is a second writer rather than a `Document` with the screen left
  out. It has no `App` to read a locale off — the build script emits it
  out of the declaration, and packaging imports nothing that reaches the
  library — so its `lang` is a declared field (`packaging.Web.lang`,
  defaulting to the same `element.default_chrome_tag` stand-in) rather
  than a derivation. Its head order settles it independently: the CSP
  meta has to precede the stylesheet link it governs, and `Document`'s
  one head seam splices at the *end* of the head. Its boot call is the
  set's second writer too, and the one difference left is a fact about
  the page rather than drift: there is exactly one host page per site
  and its two arguments are the declaration's, so they are written into
  `boot.js`, where a generated page's — which differ per page — are a
  data block ("Neither script on a generated page is an inline one"
  above). The module name is `driver_files.entry` on both paths.

  Resolution stays where it was. Nothing in the driver maps a tag to a
  catalog: the pinned tag lands in the `locale` service exactly where
  the device tag landed ([services.md](../services.md)), and the app's
  own `L.resolve` answers it — so a page pinning a locale the bundle
  does not carry falls back the same way a device asking for it does.
  What the driver does drop is the change lane: `languagechange` moves a
  page that was following the device and never a page that pinned, since
  one URL that shows two languages is what per-locale pages exist to
  prevent.
- **`data-appearance`, and only when the app pinned one.** The other
  page-level fact core owns. The sheet's dark ramp is written under a
  media query *and* under this attribute, and the query already stands
  down when the attribute appears (`:root:not([data-appearance])`) — so
  a `Scheme.auto` app stamps nothing and keeps the fallback
  stylesheet.zig's `write` describes, where the query and the app would
  answer alike anyway. An app that *pinned* light or dark is the case
  the query gets wrong: it was answering a question the app had already
  answered, and answering it differently. `App.appearance()` resolves
  the pin, so the attribute is core's own answer.
- **`data-nokre="document"`, unconditionally, and it is about the file
  rather than the app.** It says nokre wrote this whole page, which is
  the one thing an app mounted in someone else's document can never
  say. The sheet's type base is scoped to nokre's own surfaces because
  *the page around an embedded app is not this edition's to turn
  around* — right, and with nothing to protect in a file the library
  wrote end to end. So the sheet keeps its scoping and gains one block
  behind this attribute: ink, family, size, measure and paper on
  `body`. The paper is the half that earns it — a driver that centred
  the screen in a reading column leaves a band of `body` down each
  side, and unpainted that band is the UA canvas. It is the `dir` asymmetry a second time, and the live
  driver's never stamping it is checked at comptime rather than trusted
  (`class_names.zig`). What the block covers and where it stops is
  [static-sites.md](../static-sites.md), "A generated document has no
  host".
- **The class list, the paper and the module.** `rootClass` on the
  content mount ("The seams" below), `Gray.paper` in the two
  `theme-color` metas, and `driver_files.entry` in the boot script's
  import — so the one file name that ever leaves the driver set is not
  re-typed either.
- **The charset first, the seam last.** A browser stops looking for the
  charset after the first bytes, so nokre's own head tags are written
  before `head`, whose length is the driver's business — and the head is
  the only seam there is.
- **What the page says about itself** — `Document.meta`, and it is the
  one place in this call where the boundary needed stating rather than
  applying. [audit.zig](../../src/testing/audit.zig)'s `Options.skip`
  had already written the rule: *a document destination is the site
  resolver's to honor*, and a canonical URL is exactly that. It still
  is. **Every destination in `Meta` is a required field with no default
  and no derivation** — the origin is config nokre cannot know, the path
  is the resolver's answer nokre does not compute, and no route name is
  read anywhere in the block. What moved into the library is not the
  destinations but what a driver gets *wrong* about them:

  - `og:url` **is** the canonical, because `path` is one field written
    twice. Not two fields that ought to match.
  - Both are absolute, because both are `origin ++ path` and the origin
    is checked for a scheme before the doctype is written.
  - A page with no URL of its own — the 404 body, served at whatever
    address missed — has `path = null` and gets neither tag. The
    string-plus-flag shape that lets a `/notfound/` canonical survive a
    flipped boolean does not exist here.
  - Open Graph is `property=`; Twitter is `name=`. One is RDFa and one
    is not, and a hand-written head mixes them.
  - The set is complete. A page carrying Open Graph gets a
    `twitter:card`, so no site ships a preview on one network and a bare
    link on the other. It is the **only** `twitter:` tag written, save
    the image's alt: Twitter documents an `og:` fallback for the title,
    the description and the image, so the usual four are four more
    copies of strings already on the page — and it documents none for
    the alternative text, which is why that one is written twice.
  - `og:image` is a URL in a tag and nothing else. It is nested as
    `Meta.Image` rather than exported beside it, so `dom.Image` — which
    would read like an image *element* — does not exist. Its `shape`
    (`banner` or `thumbnail`) is stated by the driver rather than
    guessed from the pixel size: which crop an asset survives is
    editorial, and a document with no image is a `summary` card and
    cannot be made into anything else.
  - The `hreflang` block is a field here — `Meta.alternates` — and not
    markup a driver splices through the head seam. What the document
    checks about it is the one rule only a document can, that the page
    is among its own alternates. Where the set comes from, and why it
    cannot come out one-sided, is "The alternate set, and the two
    writers that spend it" below.

  What is deliberately absent: `og:locale`. The page's language is a
  fact this file holds — it is on `<html lang>` — but Open Graph's
  locale is `language_TERRITORY`, and a BCP 47 tag need not carry a
  territory; turning `fa` into `fa_IR` is inventing one.
- **The skip link, with its rule.** Words from the driver, target from
  `content_id`, class from `class_names.skip` — and the CSS from the
  same sheet, because a driver that wrote the anchor and forgot the rule
  ships a permanent link across the top of every page and no build
  anywhere says so. Empty words write no link: an app shell whose body
  is one mount point has nothing to skip past.
- **The route.** `mount({ route })` comes from `Router.current`, not
  from a second copy the driver holds, and it is a *boot* argument
  rather than a navigation afterwards: the file already shows that
  screen, and switching to it after the first frame would build and
  paint some other screen on the way past.

**The one seam is bytes, not a hook.** `head` is markup the driver
already built, spliced where its name says. `Emitter.raw` writes
wherever the emitter is currently pointed and nothing in the type
distinguishes "into `<head>`" from "into the body" — a field does. A
`fn (em)` hook would have said it too, and would have handed the driver
`em.out`, which is the door `Refs`'s signature closed. To build those
bytes with the same escaping the document gets, point a second emitter
at a buffer of your own: `em.fragment(&out)`.

**One, at the head, and the test it passes is that nothing in it
renders.** `<meta>`, a CSP, JSON-LD, a preload, a favicon: none of it is
a thing a reader sees, so nothing about it is a thing the library could
have styled, cleared, audited or resolved. Both refusals at the other
end of the file are that one sentence read twice
([static-sites.md](../static-sites.md), "A seam is for what does not
render"):

- There is no `body_start`. What wants to stand *above* the app on a
  generated page is a site's header, which is a set of destinations
  rather than markup, and a set of destinations is `App.setNav`. A seam
  there takes a string and throws away which link you are standing on,
  what the screen that is none of them is called, whether the routes
  resolve, and that the set is a landmark at all.
- There is no `body_end` either, and there was for three revisions. What
  every consumer put through it was a footer — a stack of links and a
  line of text — which is the same content in the same disguise, and the
  library paid for it twice before deleting it: once when the footer
  came out in the browser's default serif, and once when the bottom
  chrome's clear space landed above it instead of below. A footer is a
  `stack` of `link`s the page builder appends last, inside the screen,
  where all four of those things are already true of it.

What the driver still owes when it boots over the page it wrote:

- **The seed.** `mount({ seed })` fetches the bytes the page was
  generated from and hands them over through `nokre_dom_seed` before
  boot, for the reason the locale tag arrives before boot: the app reads
  it *inside* the first `build`, and a build cannot wait for a fetch.
  Content the module does not carry — a documentation site's Markdown —
  is otherwise a screen that renders empty for one frame and then
  refills, which is worse than the page the reader already had.
- **`nokreWebRefs`.** The static driver installed a `Refs` to resolve
  `routing` to `/routing/` where the default answers `#routing`; the live one has to
  install the *same* one, or the first frame rewrites every link on the
  page into a URL the site publishes nothing at. One mapping, stated
  once, spent by both drivers — and `nokre_dom_href` asks it again for
  the address bar, so the bar and the links cannot disagree.
- **The class list after boot.** The live driver keeps the conditional
  half of `rootClass` true as the screen changes underneath, toggling
  the modifier the bottom reserve is selected on. It stays on the
  element the file wrote it on; which *box* the reserve then lands in is
  the body's seam class, and that one no driver touches after the file
  is written, because a seam cannot appear at runtime.

And what it hands back: with `addressing: "documents"` a link is the
browser's. It has a file behind it, so intercepting it would take the one
navigation a reader can middle-click, copy, open in a tab and come Back
from, and turn it into a redraw. It also settles the destinations core
has no opinion about — a heading on this page, a source file on someone
else's host — which are legal hrefs and not routes at all. A route change
the app makes *itself* still navigates, through the href its own `Refs`
writes.

**A link is the browser's under the keyboard too**, and for one revision
it was not. The click handler passed every `a[href]` and the keydown
handler passed none: it cancelled the keystroke and handed Enter to
core, which refuses a destination the route table cannot spell — and a
locale's copy of this page is exactly that, because a reference names a
screen and its arguments and has no slot a locale could ride in. So a
footer's language chooser switched language under a pointer and did
nothing at all under a keyboard or a switch, which is WCAG 2.1.1
Keyboard at level A: a harder failure than the 3.1.2 the `lang` on the
anchor had just fixed, on the same six words. The branch is **Enter's
alone**. Space activates no anchor in any browser, so handing it over
would navigate nothing and would take the activation away from the links
core *can* honor; it stays core's, where a focus stop takes both keys on
every platform. Modifiers ride along with Enter for the click handler's
reason — `Ctrl+Enter` is the reader's "open in a new tab", and core has
no way to mean it.

External links are the browser's on *every* driver, for the same
modifier-key reasons: serialize.zig writes them as real anchors
(`target="_blank" rel="noopener noreferrer"` — same-tab would tear the
running instance down), and the live driver's click handler passes any
anchor whose href is not a `#fragment`. Where the app shell addresses
its screens, keyboard activation still crosses into core and reaches the
open_url service, whose web leg is services.js's `window.open`
([../services.md](../services.md)); under `documents` the Enter branch
above takes it first and the anchor's own `target="_blank"` opens the
tab, which is the same new window by the browser's own hand.

The reader's side of the bargain: the page is complete before the module
arrives, every link works with the script blocked, and boot is a patch
rather than a repaint — node ids are stated in both drivers' output, so
the heading the reader landed on is the same node afterwards and their
scroll position survives.

#### The locale axis, and the one page that is about the reader

A multi-locale site regenerates its whole tree once per bundled locale.
Almost none of that is this library's. What is, is one page and one
value: the chooser standing at the unprefixed address, and the set of
addresses every copy of a page annotates its siblings with.

**What the driver owns, and it is nearly all of it.** The loop, the
output paths, the prefix scheme, which routes exist, where each locale's
copy is published. A generation pass is four lines over a set nokre can
already enumerate —

```zig
inline for (comptime std.enums.values(L.Locale)) |loc| {
    try app.setLocale(L.tag(loc));      // the page's language, and its `lang`
    app.setDirection(L.dir(loc));       // and how it is laid out
    app.setChrome(L.chrome(loc));       // nokre's own words, if the catalog has them
    try writeEveryPage(&app, loc);      // the driver's, entirely
}
```

— and every line of it is either an existing call or a decision about
where files go. A loop in the library would have had to own the output
paths, the directory layout and the file writing, which is not a
document shell: it is the build. It would also have had to call back
into everything a real generator does per page — the a11y audit, the
anchor harvest for the link check, the per-page canonical, the seed URL
— so what it saved would be the `for`, and what it cost is a callback
interface for the rest. `Refs.resolve` already lets a driver answer
`/fa/…` for any route, which is the URL half; the path scheme stays
where round two put ids and addressing modes, in the driver's hands.

**What the library owns is `dom.localeStub`** — the page at every
*unprefixed* path. Every page a locale axis publishes lives at
`/{locale}/…` and **is never redirected away from**: one URL showing
different content to different readers breaks sharing and
canonicalisation both, and hreflang and canonical require one URL per
locale variant to point at. That leaves the reader who arrives with no
locale in the address, and static hosting can answer them nowhere else
— GitHub Pages reads no `Accept-Language` and has no redirect rules —
so the answer is a page:

```zig
try dom.localeStub(&em, L, .{
    .title = "nokre",
    .stylesheet = "/style.css",
    .heading = "Choose a language",
    .published = .{                    // where this page is; the rest follows
        .origin = "https://example.com",
        .path = "/docs/",
    },
    .choices = .{                      // one field per bundled locale
        .en = .{ .href = "/en/docs/", .label = "English" },
        .fa = .{ .href = "/fa/docs/", .label = "فارسی" },
    },
});
```

- **The locale set is the bundle's, by type.** `choices` is an
  `EnumFieldStruct` over `L.Locale`, so a bundled locale missing here is
  a compile error and a locale the bundle does not carry cannot be
  written down at all. This is why the call takes the bundle instead of
  a list of tags: a declared list is a second source of truth that can
  silently disagree with the ARB set — a locale in the list and not the
  bundle publishes a tree of template strings under its prefix, one in
  the bundle and not the list is never published — which is exactly the
  failure [driver_files.zig](../../src/render/dom/driver_files.zig)
  exists to prevent.
- **The destinations and the words are the driver's.** Where each
  locale's copy lives is the resolver's answer, copied; a language's
  name in its own language is content, and this library has no catalog
  of them. What it checks is what a driver gets wrong about the pair: a
  choice with no destination, a choice with no words, and **two locales
  at one address**, which makes one language unreachable and hands its
  readers the other's — refused before a byte is written, `checkMeta`'s
  reason.
- **The resolution is `Bundle.resolve`, and there is no second policy.**
  The script cannot call it — that is comptime Zig, and this page loads
  no wasm on purpose, since a redirect that first fetches an app is a
  redirect nobody waits for — so
  [locale-stub.js](../../src/render/dom/locale-stub.js) transcribes it
  *once, in the library*, over tags the bundle itself hands out: exact
  tag (case and `-`/`_` ignored), then bare language in bundle order,
  then `L.default_locale`. It reads `navigator.language`, the same one
  live.js's boot pours into the locale service, so the stub and the page
  it lands on read the reader alike; `navigator.languages` would be a
  better answer to a different question and a disagreeing answer to this
  one. What keeps a transcription honest is a gate rather than a comment
  — [testing.md](../testing.md)'s "The locale stub's own gate" runs the
  emitted page's own script against `L.resolve`'s answers.
- **The links are the document; the script is what saves a reader from
  reading it.** With the script blocked, unsupported, or a crawler, the
  page offers a choice instead of a blank frame — which is the reason
  this is a page and not a `<meta http-equiv="refresh">`. Each anchor
  carries `hreflang` (what the destination is in) *and* `lang` (what the
  words in it are in, so "فارسی" is pronounced in the right voice), plus
  the direction the bundle gives that locale.
- **The stub is in no locale**, so its root element takes the
  template's — the language the script falls back to, which is where a
  reader it cannot place is going anyway. It stamps no
  `data-appearance` either: no app boots here, so the media query is
  all the page has to go on and is exactly right.
- **The query and the fragment are carried across.** A shared
  `/docs/#the-seams` arrives at `/en/docs/#the-seams`; a stub that
  resolves to its own address navigates nowhere rather than spinning.

What the stub does *not* say is what an unprefixed address is for. A
`noindex` is indexing policy — the site resolver's, in exactly the sense
[audit.zig](../../src/testing/audit.zig)'s `Options.skip` draws it — and
goes in through the head seam, which on this page is what that seam is
there for.

The `hreflang` block is neither of those. It is `published`, one field
naming where this page stands, and the stub derives the rest from the
`choices` it is already holding: one path per bundled locale is what an
alternate set is, and the `x-default` is this page's own address because
a stub is what `x-default` *means*. A driver restating either would be
the second source of truth the type exists to prevent. Left out, no
block is written — which is a decision about indexing again, and so
belongs beside the `noindex` rather than beside the set.

#### The alternate set, and the two writers that spend it

A page published in three languages exists at three URLs and each of
them has to name the other two. Nothing about getting that wrong is
loud: the pages render, the links work, and the failure is a line in
somebody's search console months later saying one page annotates a
sibling that does not annotate it back.

[alternates.zig](../../src/render/dom/alternates.zig) answers it by
removing the opportunity rather than by checking for the mistake. **A
page's alternates are its own variants, so the set is one value for
every page in the family** — the English copy and the Persian copy of
one route are handed the same array and write byte-identical blocks out
of it. Reciprocity is therefore not a rule a
driver keeps but a shape it cannot get out of, and what is left over is
self-inclusion, the one question the set cannot answer about itself.
That one is asked of every page carrying a set: on a locale's copy by
`checkMeta`, and again in the sitemap, because the two writers do not
check each other.

`Alternates(L)` takes the bundle for the reason `choices` above does —
one required field per bundled locale, so completeness is a compile
error rather than a runtime sweep, and the tags are `L.tag`'s rather
than BCP 47 strings a driver typed. Everything around them stays
stated: the origin, the prefix scheme, whether a path ends in a slash.
This edition still computes no path anywhere.

**`x-default` is an address, not a language.** It is the stub's — the
one URL in the set that is about the *reader* rather than about a
language, which is precisely what stands at the unprefixed path. It is
also **not the default locale's URL**, which is the single mistake this
block is usually written wrong by: the default locale is a locale and
has a path beside every other. That is why the stub's address is a
required field of its own (`Alternates.stub`) rather than something a
driver could omit and have defaulted to the template's page.

**The head's block and the sitemap's are one value, not two derivations
that agree today.** `Alternates.set` hands back a fixed-size array the
caller keeps in a local and passes to both `Meta.alternates` and
`Sitemap.url`; one function writes the `<link rel="alternate">` form for
a locale's copy and for the stub alike, and the sitemap writes the
`<xhtml:link>` form from the same entries. The builder copies what it is
given, so a generation loop's local may die with its iteration and the
file still holds what it said.

**What a sitemap knows that no page can.** `dom.Sitemap` is not a
document — no screen, no head, no locale, no `Emitter` — because it is
one file *about* a tree rather than the page around one, and what it
owns is the questions that need the whole tree in view: that no URL is
listed twice, and that the alternate graph **closes**, every language
copy any entry names being itself an entry. That last one is the
one-sided annotation, failed at build time instead of reported in a
console a year on, and no per-page function could ever run it. Beside
those it owns what a hand-written file gets wrong at a distance: the
`xhtml` namespace declared exactly when something below uses the prefix,
and the XML escape, since one unescaped `&` out of a query string is a
file no parser reads past. The specification's two ceilings — 50,000
URLs and 50 MB, `max_urls` and `max_bytes` — are hard errors rather than
warnings, since a `<urlset>` past either is a file nothing reads. The
first of them is where the single-file trade actually arrives: a site
large enough to want a sitemap index splits the alternate graph across
files, and then nothing can check that it closes, which is most of what
this type is for.

**It writes bytes, not a file.** The caller's buffer is the destination
and the caller does the `writeFile`, the shape `stylesheet.write`
already has. That is the line the refused per-locale generation loop
left behind, read from the other side: output paths, directory layout
and what a build does with the bytes are the driver's, so the part of a
build this edition could most easily have taken over is the part it
declines. Nothing is appended if any check fails, `document`'s posture
for `Meta` — a half-written file is worse than none.

**`lastmod` and `changefreq` are refused, and not for symmetry.** The
argument is in [sitemap.zig](../../src/render/dom/sitemap.zig)'s module
comment, written down so it does not have to be had again: `changefreq`
is publishing policy Google has said for years it does not use, and a
generator stamping `weekly` on everything is stating a schedule nobody
keeps. `lastmod` is a filesystem or VCS fact this library cannot know
and — alone among the destinations `Meta` carries — cannot check either,
so what a generator actually ships is the build's own clock on every
URL, telling a crawler the whole site changed on every deploy. That is
worse than absent. A consumer holding real per-page timestamps is a
receipt this library has not been handed, not an omission waiting to be
filled in.

### Services are not the edition's business

A compute worker has no more to do with markup than it has with Skia,
and neither does a fetch. So the ferry those services land through —
`nokre_worker_scratch` / `_boot` / `_handle` / `_deliver` / `_died`,
`nokre_http_scratch` / `_deliver` / `_fail` — is exported here under
the *same names* the canvas shell exports it by, forwarding into the
same `workers/post.zig` and `services/http/web.zig`. One ABI, so glue
written against either build says the same thing.

The browser half is [services.js](../../src/render/dom/services.js),
shared by both instances the driver runs: the app on the main thread,
and a compute actor in a Worker
([live-worker.js](../../src/render/dom/live-worker.js)), which is the
same module instantiated a second time with no app in it. `fetch` runs
on the main thread here rather than beside the wasm as it does under
the canvas shell — this driver has no worker to hide in, and that is
the only difference.

The other web legs export their own doorways from their service files
rather than through live.zig — [oauth](oauth.md)'s redirect seed and
popup receiver, [secure_store](secure_store.md)'s snapshot seed and
sessionStorage mirror, deep_link's `nokre_deep_link_receive`, and
locale's seed/receive pair. services.js implements the imports they
call out through; live.js seeds the pre-boot values (locale tag, oauth
redirect, secure_store snapshot) and delivers the boot-time and
`hashchange` deep links, per each file's stated ordering. share is the
degenerate case that needs no doorway and no seed: both directions are
plain imports — the `nokre_share_available` probe App.init calls (a
bool needs no scratch buffer) and the fire-and-forget
`nokre_share_show` — so services.js is its entire web leg. clock is
that case reduced once more: one import, `nokre_clock_js_now`, wired to
`Date.now()` in *both* instances for pkce's reason (an actor runs the
app's code, so it may stamp what it computes), and named by nothing
unless an app asks the time — so a module that never reads a clock has
no clock in its import table at all.

Two rules the glue keeps, because both are silent corruption if broken:
a pointer handed across is borrowed for the call and anything outliving
it is *copied* (`slice`, never `subarray`, or a transfer drags the whole
heap's ArrayBuffer along); and a view into wasm memory is never held
across a call back into the module, because growing the heap detaches
it. The module keeps a third of its own, for the same reason: a length
that crosses in is cut to the buffer the glue actually filled
(live.zig's `scratchSlice`, used by every export that reads a string).
A web build is ReleaseSmall, so there is no bounds check behind the
slice — the door has to be the check.

### The event flow inverts, and that was foreseen

[renderer-editions.md](renderer-editions.md) states the seam:
edition-owned layout inverts the event flow — the backend resolves hits
and delivers semantic events. This edition is the case that needed it,
and here the inversion is not optional: the browser lays the
page out, so core's rects describe a picture the reader is not looking
at, and hit testing against them would answer about the wrong one.

So the browser resolves the hit and hands core a *semantic* event —
`App.deliver`, which takes a press, a focus move or a choice. Which
element was meant is the **only** thing this backend knows better than
core — and even that is checked: `deliver` vets the stop it is handed
(the node exists; a span is in range and is a link; otherwise the
element is focusable), so a driver that mis-hears the document moves
nothing. Everything else an input carries — the focus a press moves,
what activation means, the latches an input releases — stays where it
already was, and `deliver` applies exactly what `dispatch` applies.

That boundary is worth stating sharply, because getting it wrong is
subtle rather than loud. This driver once released the acknowledgement
latch itself, in the driver, because its presses did not pass through
`dispatch`. It read correctly and it was wrong twice over: the rule now
had two homes, and the driver made *two* calls for one press — focus,
then activate — so a rule written to run once per input ran twice, and
a copyable's check re-armed instead of toggling off. One press is one
call, and the rule is core's.

Core gained two things for this, both semantic twins of geometry it
already had: `App.deliver` beside `App.dispatch`, and
`input.selectOption` beside the two walks that resolved a choice by
measuring chips.

Four things follow from the browser owning the page:

- **Focus traversal is core's, deliberately.** The markup *is* the
  tree, so document order already is focus order — but the live driver
  still intercepts Tab and forwards it into wasm, because core's
  traversal knows the focus *scope* (an open sheet holds focus inside
  it, the page behind a scrim is inert) and a browser tabbing on its
  own would walk straight out of a modal layer. Where focus lands
  crosses back into wasm either way, so core's own focus state stays
  true. The drawn *ring* is the one focus decision left to the
  browser: `:focus-visible` throughout, the same keyboard-origin rule
  the skia edition states with `App.focus_visible`
  ([../accessibility.md](../accessibility.md#focus)) — a platform
  answers the modality question, the tree never carries it.
- **Scrolling is the browser's.** The content is real, so a
  `scroll_region` is a real scroll container. No offset round-trips,
  and that element's `offset` simply goes unread here.
- **Paint order is document order.** The reference branches — a notice
  banner owns the bottom pane and the nav is hidden and inert behind
  it — and layout says the same thing by zeroing every nav rect. This
  edition reads no rects, so `chrome` has to make that branch itself;
  without it a screen showed two bottom bars stacked on each other.
  The same applies inside a row: a notice's leading control is emitted
  *before* its words because there is no rect to place it by. Modal
  layering holds to the rule as well: scrims and surfaces share one
  z-index, so equal z resolves by document order, and `chrome` emits
  each layer's scrim immediately before its surface in the order the
  reference paints them (`render`'s `drawOverScrim` sequence: notices
  pane, sheet, picker) — which is what stacks the layers *per layer*,
  a picker opened from a sheet arriving over a scrim of its own that
  dims the sheet too.

- **Focus and the caret are the tree's.** `focus.zig` moves one and
  `editing.zig` the other, so after a re-render the glue puts both back
  from there rather than letting the DOM keep its own idea. Typing goes
  through `beforeinput`: the DOM's own edit is refused, the bytes go to
  core, and the field then shows what core decided.

### The two facts no markup carries

The appearance and the chrome direction belong to the app, not to any
element in it, so they arrive as attributes on the document root —
`data-appearance` and `data-direction` — and the generated sheet spends
them **on nokre's own surfaces only**. A page around an embedded app is
not this edition's to restyle.

Both are read back out of core rather than decided here. The OS
appearance goes *in* through `nokre_dom_system_appearance`, the same
report `on_appearance` makes on every native shell, and what comes back
is `App.appearance()` — which already contains the system's answer,
because that is what `Scheme.auto` resolves through. So the media query
in the sheet stands down the moment the attribute appears: an app pinned
to light must stay light on a dark desktop.

Direction is the mirroring only. Text takes its base direction from its
own first strong character in both editions — UAX #9 P2/P3, which is
`bidi.paragraphDirection` in the reference and one `unicode-bidi:
plaintext` rule here, so a Persian paragraph reads right to left in an
otherwise left-to-right screen and an app never has to call
`setDirection` for RTL *text* to be right.

### Framework names come off the element, never out of this file

Four controls are named by nokre rather than by an app — the back
control, the sheet's close, the collapsed nav chip and the off-roster
marker. Each carries its own copy of the word
([localization.md](../localization.md#the-frameworks-own-words) owns the
list and where it comes from), and this edition reads that copy: the two
icon-only buttons spend it as `aria-label`, and the two chips, which
have a name *and* a value where HTML gives them one accessible name,
write it into a visually-hidden span ahead of the value so the computed
name comes out in the same two parts AccessKit carries in two fields. A
literal here would be a second catalog, and a second catalog is one that
can only ever say English — the whole point of the words riding on the
elements is that both editions read one. What this edition does supply
is the colon between the two parts: punctuation joining a name to a
value, not a word a catalog should have to re-type per locale.

### A measured answer is only as old as the faces behind it

Measurement is the shell's job on every platform, and here it is the
engine that will draw the run ([services.js](../../src/render/dom/services.js)
rules a canvas). Layout asks thousands of times a frame, so the answers
are cached — but only for as long as the font set they were measured
against. The faces are bundled and fixed and still arrive over the
network, and a ruler asked before one lands answers in the fallback:
narrower stems, a tofu box where a private-use icon codepoint belongs.
The text repaints itself when the face arrives; a cached width does not,
so core would go on deciding from it. `loadingdone` drops the cache and
the driver re-reports the viewport, which is what makes the decision
retaken rather than kept.

### The viewport is the container, not the window

`nokre_dom_boot` and `nokre_dom_resize` are handed the width of the
element the app is mounted in. A host page may hold the screen to a
readable column — the one this edition ships does, at 560px stepping to
760px past a 900px window, a number of its own rather than a library
constant borrowed — and core measuring against `innerWidth` instead
would answer every
measured question against a width nobody is looking at: prose wrapped
somewhere else, a row of actions that never folded its tail because it
had room to spare, a track that fitted in a column it overflows. The
height stays the window's, which is what "how much is visible" means.

### The write is a diff; the frame never is

A frame is still built whole: nokre rebuilds subtrees instantly and
has no animation to preserve, so "build it again" is the model rather
than a shortcut. The *write* is not. The glue keeps the last frame's
bytes and does nothing when the new frame matches, which is what most
frames are; a frame that differs is parsed off-document and patched in
node by node, under the identity rule the node-ids seam states below —
same tag, same `data-n`, same node. So the write is proportional to
what changed, and everything the browser keeps beside the document —
scroll offsets, text selection, an open IME session — survives the
frames that did not touch it. That rule is about two frames of *one*
tree. The first frame, which meets a page some other process wrote, has
no shared tree to name a node with and matches positionally instead;
the seam below has the argument.

### A heading is an address, and the address is GitHub's

`Options.heading_ids` (on by default) gives every heading an `id`
derived from its own words, so a section can be linked to. **The rule is
GitHub's slug**, and deliberately so: the Markdown a `document` element
carries was written against GitHub's anchors — nokre's own docs link
`elements.md#text_input` and are read on GitHub as often as here — so
any other rule would break the links in the very documents this edition
exists to render. Lowercase; spaces to hyphens; Unicode word characters
kept whole (dropping them would slug every Persian heading to
`section`); punctuation dropped, ASCII and the General Punctuation block
alike, so an em dash leaves the two hyphens GitHub leaves; repeats
numbered `-1`, `-2`. It is a pure function of the words, so the same
heading is the same address on every run — which is what makes a
cross-document `#fragment` checkable at build time rather than at 404
time.

Ids only, never an anchor control beside the heading: a control the tree
does not have is a control assistive tech would announce that the app
never wrote, and the element set is closed here too.

**Derived is the default, not the only way.** A pure function of the
words is a different address in every language a page is published in,
which is fine until something outside the document names one — an app
store's account-deletion policy pointing at `#delete-account` in three
locales at once. A heading may state its own address instead
(`element.Heading.anchor`; the argument and the shape it beat are
[static-sites.md](../static-sites.md), "A heading id is a destination").
Two things change here and nothing else does:

- The stated value goes in verbatim, and `Options.heading_ids` does not
  suppress it. That flag governs a guess the library was making; a
  destination the driver stated is not the flag's to drop.
- `headingId` mints it into the same roster, and a name already there is
  `AnchorError.AnchorTaken` rather than a `-1`. Only *derived* slugs
  take the suffix. Document order is the whole of the arbitration: a
  stated anchor reached after its name is gone fails the build, and a
  derived slug reaching a name a stated anchor already took gets
  numbered as any repeat would. Neither order moves a stated address,
  which is the only property being defended.

The grammar a stated anchor has to satisfy — an ASCII letter, then ASCII
letters, digits, `-`, `_`, `.` (`element.Heading.validAnchor`) — is
checked at `Tree.append`, not here: it is a fact about one element, and
every construction rule in nokre runs at the append that builds it.
What *this* file can see, and no single append can, is whether the name
is free.

What a document *exports* — the anchors another page may name — is
`Emitter.takeAnchors(gpa)`, derived and stated alike. The emitter keeps
the same list internally as the suffix bookkeeping above, but "which
anchors does this page publish" is a question about the document, and a
generator that answers it by reaching into an emitter's field and
deep-copying it before `deinit` is holding bookkeeping and calling it an
answer. Ownership transfers on the call, and it is called once, when the
document is finished.

### A run may be in a language of its own, and only this edition hears it

`<html lang>` is the document's, written from `App.locale()` and never
from a driver ("The document is the library's" above). What sits inside
a page of that language and is *not* in it is a **part**, and WCAG 2.2
**3.1.2 Language of Parts** (AA) is about exactly that: a language
chooser naming `English`, `فارسی` and `Türkçe` in a page of a fourth,
where an untagged endonym is read out with the wrong phonemes and the
one word the reader wanted is the one word that came out wrong.

The tag is on the element (`element.Link.lang`, `element.Span.lang`),
and this edition is the only reader — `Heading.anchor`'s situation
exactly. It lands on the run's **own** element, so there is one place
per run and no wrapper invented for the occasion:

| The run | The element it lands on |
| --- | --- |
| a `link` element | its `<a class="link block">` |
| a span with a destination | its `<a class="link">` |
| a prose span | a `<span>` written for it, shared with the ink wrapper when the run is also tinted |

It is written after the destination and before the node's own name, so
an anchor here reads the way an anchor `document.localeStub` writes does
— what it is, where it goes, what language its words are in. Empty
writes **nothing**: `lang=""` is a claim in HTML, and the claim a run in
the page's own language is making is the one it inherits by staying
quiet.

The prose wrapper is the only element `inlines` writes for a reason
other than Markdown's inline vocabulary, and it earns the exception on
the test that matters here: it draws nothing. It is also the only
`<span>` in this edition whose presence is decided by something other
than a class, which is why a tinted run shares it rather than nesting
inside a second one — a run cannot become two elements because it
happened to say two things.

Nothing native reads it. AccessKit carries no per-node language, so on
the five drawing platforms the field is inert; the reference edition
draws the same pixels with it and without it, which is why the goldens
did not move when it shipped.

### IME

Composition is the browser's while it lasts and the tree's when it
resolves. The preedit lives in the real field — the native IME a real
field buys is on the list of what this edition traded pixel goldens
for — so an open session owns that field outright: the driver forwards
none of its keys (Enter takes a candidate, Escape dismisses), refuses
none of its edits, and a frame that lands mid-session leaves the
field's value and caret alone. What crosses into core is the same
three legs every shell sends
([platform-shells.md](platform-shells.md#ime)): the preedit streams as
`update`, so the tree's `composition` — and the a11y and test traces
built from it — is true here too, and the session ends as `commit` or,
empty, `cancel`. The frame after resolution shows what core decided,
as it does after every other input.

## The seams

```zig
var out: std.ArrayList(u8) = .empty;
var em: dom.Emitter = .{ .gpa = gpa, .app = &app, .out = &out };
defer em.deinit();
app.performLayout();    // layout first, though no rect is read here:
                        // the pass is where a too-wide row folds its
                        // tail and gains its `more` control (live.zig
                        // documents the bug of skipping it)
try dom.content(&em);   // the screen
try dom.chrome(&em);    // notice, nav, sheet, picker
```

- **`content` / `chrome`.** Content is every root child that is not
  framework chrome; chrome is the layers the framework installs, in
  paint order. Split because a driver decides where a page's document
  structure puts them — the nav leads the focus order, and a driver that
  wants it first in the markup can have it.
- **`document`.** The two above with the whole file around them, for a
  driver publishing one page per screen — doctype, `lang` and `dir`, the
  head and its seam, both mount points, the skip link and the boot
  script. What it takes and what it refuses to invent is "The document
  is the library's; the names in it are the driver's" above; `content`
  and `chrome` stay separately callable for a driver placing them
  itself, which is what the live one does.
- **`Sitemap`** ([sitemap.zig](../../src/render/dom/sitemap.zig)) is the
  one thing here that is about a whole tree rather than one page, and it
  is a builder rather than a seam: URLs and their alternates go in, the
  `<urlset>` comes out into a buffer of the caller's ("The alternate set,
  and the two writers that spend it" above).
- **`Emitter.fragment`.** A second emitter over a buffer of the caller's
  own — how the bytes `Document.head` takes get the escaping the rest of
  the document gets.
- **`Emitter.raw`, and when it is not a bypass.** Some of what a head
  needs is a block this library has no element for and never will —
  structured data, a preload, a favicon. Build it into a fragment and
  hand it over at `Document.head`; inside that fragment
  `raw` is the sanctioned writer, because those bytes are markup the
  driver invented end to end and no element of nokre's stands for them.
  The sanction is the seam's, not the function's: `raw` on the document
  emitter, between two elements the walk wrote, is not reaching a place
  the escapes do not go — it is going around one.

  Two escapes are on the emitter for what does pass through it, and
  which one a string takes is a question about its *destination*.
  `text` is markup: a text node or a quoted attribute. **`json`** is the
  one destination whose escape is neither `text`'s nor `std.json`'s — a
  `<script>` block's contents are raw text, so `&amp;` in one is five
  characters of nothing and the block ends at the first `</script>` the
  bytes contain, inside a JSON string or not. It takes a document you
  already serialized and re-escapes the one byte that can end the block;
  what the graph in it says stays yours, and so does serializing it
  ([serialize.zig](../../src/render/dom/serialize.zig)'s `json` has the
  bytes and the evidence).
- **Node ids.** With `Emitter.Options.node_ids`, every focus stop carries its
  `NodeId` as `data-n` (and an inline link its span as `data-s`) — the
  live driver's way of naming the node the reader meant. A page written
  to a file has nobody to tell and leaves it off, *unless* that file is
  going to be booted over: identity across frames is what makes the boot
  a patch instead of a replacement, and a replacement throws away the
  scroll position the reader arrived at. Between two frames of one
  running app the match is tag plus `data-n` — two nodes are the same
  node when they are the same kind of thing carrying the same id.

  **Across the handover it is not, and cannot be.** A `data-n` is a
  handle into the tree that wrote it: a slot index and that slot's
  generation ([tree.zig](../../src/core/tree.zig)'s `NodeId`). A
  generator has one app and one tree and publishes a page per screen per
  locale; every `switchTo` releases the content subtree and takes the
  slots back off a free list, so by the second page both halves of the
  id have moved — the generation has climbed and the index comes back in
  release order rather than the order it was first handed out in. A
  browser booting *one* page has none of that history behind it and no
  way to acquire it. **The two agree only on the very first page a
  generator writes, and by coincidence there.** So the first frame
  matches **positionally**: the file and the frame are the same tree
  serialized twice by the same walk in the same order, and position plus
  tag is the whole of what two processes share. The frame's own ids
  arrive as attributes — adopted, not matched — and from the second
  frame on the document carries the running tree's ids and the rule
  above is the rule again ([live.js](../../src/render/dom/live.js)'s
  `sameNode`).

  Making the ids agree instead was the obvious move and is the wrong
  one, twice over. Resetting the generation per page removes the only
  thing that stops a stale handle from addressing a recycled slot, which
  a driver holding ids across rebuilds actually needs; and numbering the
  nodes per frame would shift every node after an insertion, destroying
  exactly the mid-session identity the diff exists for. The ids are a
  hydration contract, not decoration — but the contract they carry is
  *within* one running app, and across the boot the contract is the
  walk.

  **And the ids are only half of it: a mount's children have to *be*
  the frame's nodes.** Positional matching makes that stricter, not
  looser. The diff walks siblings in order, so one newline written
  inside a mount for the file's own readability is a text node the frame
  does not have — the walk pairs the file's first child against the
  frame's second, disagrees on the node *type*, and replaces it, and
  every sibling after it. Nothing looks wrong afterwards, which is how a
  driver ships it: the markup is right and the boot was a repaint. So
  `document` writes both mounts tight —
  `<div id="chrome">` and `<main …>` are followed immediately by the
  region and closed immediately after it — and
  [document_test.zig](../../src/render/dom/document_test.zig) asserts
  the two seams as bytes against `chrome` and `content` themselves. A
  driver placing the regions itself owes the same tightness.
- **`Refs`.** How a route reference becomes an `href`, as a `ctx` +
  function pointer like every other action in nokre. The hook resolves
  a route to a `Dest` — `internal` (a plain href) or `external` (the
  new-tab pair every external anchor carries) — and the emitter writes
  the whole attribute for both forms, so no driver ever writes a byte
  of one. The default resolves to the fragment the web shell already
  mirrors routes into (`#note~42`), so a link in a serialized page and
  a link in a running app point at the same screen. A driver publishing
  one file per screen installs its own.
- **`rootClass`.** The class list for whatever a driver wraps the screen
  in, as the whole attribute value rather than the names to build one
  from — a driver's own classes stand beside it (`class="{s} page"`).
  The stylesheet hangs the root stack's padding, gap and bottom-chrome
  reserve off it, and the reserve half is conditional on
  `layout.hasBottomChrome`, the same predicate the reference edition
  asks to reserve its trailing band: layout's answer, not the page's.
  Handed over whole because the selector it has to match is compound —
  both names on the one element — so a list assembled by hand can name
  the modifier alone and match nothing at all
  ([class_names.zig](../../src/render/dom/class_names.zig) says what
  each way of getting it wrong costs).
- **The stylesheet** ([stylesheet.zig](../../src/render/dom/stylesheet.zig))
  is generated: thirteen grays in two ramps out of `core/color.zig`, six
  type scales out of `core/text.zig`, every padding, radius, target and
  stroke out of `core/layout.zig`, each container's own default gap and
  padding off the structs in `core/element.zig`, the brand mark's four
  arc colours off `element.zig`'s `google_g_rgb`, and the page margin
  off `tree.root_stack`. Nothing is transcribed, so nothing can drift.
  It is
  not a styling API and no app may add to it — it is this edition's
  `renderer.zig`.

  Where the reference *composes* a number rather than naming one, the
  sheet writes the same arithmetic over the same constants instead of
  the integer it comes to: a nav plate's corner is `--nav-slot / 2`, a
  radio's dot is its ring less twice `radio_dot_inset`, the bottom
  reserve is `trailingSpace` plus `navBarHeight` term by term. Two
  facts about CSS shape the rest of it. Custom properties **inherit**,
  so a container that spends `--pad` or `--gap` declares its own
  default first or silently adopts an ancestor's — which is why the
  element fields are named `--pad`/`--gap` and the page's own numbers
  are `--page-pad`/`--page-gap`. And `border-box` puts the border
  *inside* the box, which is exactly where `hsk_stroke_rect` puts it —
  so a border here is the same pixel the reference paints, and a
  padding written beside one is the reference's inset **less** that
  border. Nearly every off-by-one this edition had was one of those two.

- **One breakpoint, and the two things that turn on it.** This edition
  is the only one whose window resizes under a reader, so it is the only
  one that answers a question about the *reader's* window rather than
  the app's. The width is `sheet_max_w`, derived like everything else
  here: at and below it a bottom-anchored surface *is* the screen — the
  notice banner squares its corners and drops its side borders, the way
  the reference does in `drawPaneChrome` — and above it each of them is
  a pane standing in a window. The nav sorts on the same fact. Below the
  width it is the bottom band, pills and all, with the section list
  standing on it as a card and the screen keeping the reserve
  underneath; above it the same markup is a header in flow above the
  page, wrapping, its destinations words rather than plates and marked
  by weight and tone, reserving nothing at the bottom and letting the
  section list fall back to the ordinary bottom pane.

  Both shapes are **one markup**, which is the whole reason this is a
  sheet rule and not a tree decision: the wasm side knows nothing about
  it, a served file cannot disagree with the frame that patches it, and
  no fact about who published a page is a term in it. The reference
  edition has no such rule and draws the band always: it lays out rects,
  and what it laid out is what the reader sees.

  **What core does have to be told is the medium.** Which shape a nav
  wears is the sheet's, but whether the roster *collapses* is a tree
  decision — `nav.syncNavChrome` picks between a row of links and a
  combobox, and `semantics.roleOf` reads the element kind — so it cannot
  move into a renderer. Above the cap this edition wraps the header, and
  a row that wraps has no width at which it fails, so
  `layout.navCollapses` declines before it measures, on the one input
  core cannot see: `layout.Medium`, `reflows` here and `clips` on every
  rastering edition. The driver installs it, beside the measurer and for
  the same reason (`live.zig`'s boot, `document.zig`'s first line).
  Below the cap the band is one line by construction, the measurement is
  live again, and the chip is what a narrow window gets.

  **The band's own overflow answer needs nobody running.** A nowrap row
  in a fixed layer clips at both screen edges, and the band cannot wrap
  out of that — its height is arithmetic the content reserve repeats to
  the pixel. So the row is a scroll container, packed to the start
  rather than centred (a centred one's leading overflow cannot be
  scrolled to) and one line tall either way, with no scrollbar, because
  a scrollbar in a fixed band is height the reserve cannot see. A driver
  upgrades that to the chip; a page with none keeps a shape that already
  works.

- **The reset is not tidiness.** It is the edition's half of matching
  the reference: `font-synthesis: none`, because the bundle ships real
  bold and italic and the Arabic companion ships no italic, so a
  browser left alone would shear the one variant the bundling resolves
  to an upright weight instead; grayscale antialiasing, because the shim sets
  `kAntiAlias` with `setSubpixel(false)` and a browser on macOS
  defaults to a stem one weight heavier; `text-decoration-skip-ink:
  none`, because a rule the reference draws is unbroken; no
  letter-spacing and no `overflow-wrap: break-word`, because `wrap`
  measures with the face's own advances and lets an unbreakable word
  run on. Ligatures are left **on**, which is the match: the shim
  calls `hb_shape` with no feature list, and HarfBuzz's defaults are
  the browser's defaults.

- **The advised margin** (`Ctx.margin`) arrives as an inline
  `--bleed`, not a cascade. It accumulates down the tree and is
  consumed by anything that draws an edge, and a custom property that
  added its parent's value to its own name is a cycle — which resolves
  to nothing at all. Layout has already walked it and written the
  answer onto the two elements that spend it (`CodeBlock.bleed`,
  `Segmented.bleed`), so the serializer copies that number and CSS does
  no arithmetic. It is also the *whole* condition: layout writes a
  bleed only where the content overflows its column **and** an edge is
  within reach, and CSS can see neither of those, so a track reaches
  the screen exactly when core said it may.

- **A measured width cannot be a constant.** A list's marker column is
  the widest marker in it plus the gap after — `layout.listGutter` —
  and a QR's side is whole pixels per module up to the cap
  (`layout.qrSide`). Both are written onto the element by the
  serializer; a stylesheet guess would put the words in a different
  column and scale the symbol to a fraction of a module, which is what
  stops one scanning.

Roles come from `semantics.roleOf`, never a second table. An element
whose HTML tag already carries the right implicit role gets no ARIA;
everything else states what that function returns. Two editions that
ask one function cannot disagree about what an element *is*.

## What replaces the golden

A pixel golden cannot apply to a non-reference edition. Two things
stand in its place, and both are in
[serialize_test.zig](../../src/render/dom/serialize_test.zig):

- **The renderer contract**, per element: the role, the label, the
  state, the place in the focus order. A tile with a route is a link and
  one with an action is a button — asserted against `roleOf`, not
  against a screenshot. The audit rules are the seed of this list.
- **Markup determinism.** The walk is deterministic, so two runs over
  one tree are byte-identical and a review is a *text* diff. That is the
  golden discipline one layer out, and more diffable than a picture.

Both of those stop at the seam. The markup is the serializer's output;
what the *driver* does with it, and what the service legs on the far
side of the wasm boundary do, is JavaScript that no Zig test can read.
A third gate covers that half and only that half:
[tests/web_services.mjs](../../tests/web_services.mjs) boots a real wasm
app into the shipped `live.js` under a browser stub and asserts what the
app recorded — the deep link that arrived, the popup message that ended
an oauth flow, the seed that beat the first `build`. It asserts nothing
about how the page looks, which is the one thing this edition traded
away; [../testing.md](../testing.md#the-webs-own-gate) has the whole
list, including what it still does not reach (the compute worker, the
service worker, `fetch`, and the hydration handover).

The closed set is enforced by the language: the switch in `node` has no
`else`. An element added to `Element` without a case here fails to
compile rather than rendering as a `<div>`.

## What the decision cost, stated once

The README used to promise byte-for-byte identical frames on six
platforms including the web. It now promises five, and says what the
web trades instead. That sentence was the decision, and this is what
each side of it bought:

**Given up.** A web app wraps its lines where the browser wraps them,
so its screenshots are not its macOS sibling's. Pixel goldens cover the
five native shells and stop there. Two refusals — no fractional
scaling, no system fonts — hold everywhere else and only mostly here.

**Bought.** The accessibility tree stopped being a mirror and became
the page. The app is one ~200 KB wasm module rather than megabytes of
Skia behind an emscripten toolchain nobody wanted to install. Text
selection, find-in-page, translation, reader mode, print and real links
came back. `tools/build-skia-wasm.sh`, `tools/build-web.sh`,
`src/platform/web/` and the ARIA mirror stopped needing maintenance —
and one target came off the nokre-owned-Skia list, because the web now
builds none.

Keeping both would have been a capability matrix, which nokre refuses
everywhere else. It refused it here too.
