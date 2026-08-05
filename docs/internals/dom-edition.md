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
| `live.js`, `live-worker.js`, `services.js`, `sw.js` | `src/render/dom`, copied by the build graph; the set is also exported as data for a generator that publishes the driver itself — `dom.driver_files` for the names, `dom.driver_sources` for the names *and* the embedded bytes, so such a generator writes files it never had to locate |
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
Content-Security-Policy, and the page carries it as a `<meta>` — the
per-directive inventory is `packaging.webIndexHtml`, which is the
emitter, so the policy cannot fall behind the page it rides in.

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
one seam a consumer gets — `web_connect_src` on `addApp`, a list of
hosts that joins that directive and no other — and the entries are
checked before they reach the page (`packaging.badConnectSrc`), because
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

What the host document owes, and what it keeps:

- **Its own `<main>`.** `mount({ into, content })` patches the
  framework's layers into one element and the screen into another — the
  same seam `chrome` / `content` are split at above — so a generated page
  keeps the id its skip link names and the class its stylesheet caps.
  The driver still owns `has-chrome`, because whether a screen owes the
  bottom reserve is layout's answer and not the page's.
- **The route.** `mount({ route })`, delivered as a *boot* argument
  rather than a navigation afterwards: the file already shows that
  screen, and switching to it after the first frame would build and paint
  some other screen on the way past.
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

And what it hands back: with `addressing: "documents"` a link is the
browser's. It has a file behind it, so intercepting it would take the one
navigation a reader can middle-click, copy, open in a tab and come Back
from, and turn it into a redraw. It also settles the destinations core
has no opinion about — a heading on this page, a source file on someone
else's host — which are legal hrefs and not routes at all. A route change
the app makes *itself* still navigates, through the href its own `Refs`
writes.

External links are the browser's on *every* driver, for the same
modifier-key reasons: serialize.zig writes them as real anchors
(`target="_blank" rel="noopener noreferrer"` — same-tab would tear the
running instance down), and the live driver's click handler passes any
anchor whose href is not a `#fragment`. Keyboard activation still
crosses into core and reaches the open_url service, whose web leg is
services.js's `window.open` ([../services.md](../services.md)).

The reader's side of the bargain: the page is complete before the module
arrives, every link works with the script blocked, and boot is a patch
rather than a repaint — node ids are stated in both drivers' output, so
the heading the reader landed on is the same node afterwards and their
scroll position survives.

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
frames that did not touch it.

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

What a document *exports* — the anchors another page may name — is
`Emitter.takeAnchors(gpa)`. The emitter keeps the same list internally
as the suffix bookkeeping above, but "which anchors does this page
publish" is a question about the document, and a generator that answers
it by reaching into an emitter's field and deep-copying it before
`deinit` is holding bookkeeping and calling it an answer. Ownership
transfers on the call, and it is called once, when the document is
finished.

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
- **Node ids.** With `Emitter.Options.node_ids`, every focus stop carries its
  `NodeId` as `data-n` (and an inline link its span as `data-s`) — the
  live driver's way of naming the node the reader meant. A page written
  to a file has nobody to tell and leaves it off, *unless* that file is
  going to be booted over: identity across frames is what makes the boot
  a patch instead of a replacement, and a replacement throws away the
  scroll position the reader arrived at. The match is tag plus
  `data-n` — two nodes are the same node when they are the same kind
  of thing carrying the same id — and the live driver's first frame
  diffs the static page by exactly that rule, which is what carries
  the reader's scroll, focus, and caret through the handover. The ids
  are a hydration contract, not decoration.
- **`Refs`.** How a route reference becomes an `href`, as a `ctx` +
  function pointer like every other action in nokre. The hook resolves
  a route to a `Dest` — `internal` (a plain href) or `external` (the
  new-tab pair every external anchor carries) — and the emitter writes
  the whole attribute for both forms, so no driver ever writes a byte
  of one. The default resolves to the fragment the web shell already
  mirrors routes into (`#note~42`), so a link in a serialized page and
  a link in a running app point at the same screen. A driver publishing
  one file per screen installs its own.
- **The `nokre` class.** A driver puts it on whatever it wraps the
  screen in; the stylesheet hangs the root stack's padding, gap and
  bottom-chrome reserve off that one class.
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
