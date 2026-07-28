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
rasterizer — [pixel-model.md](pixel-model.md) says so outright: "the gap
is now rasterization alone". Skia rasterizes text, axis-aligned lines
and rounded boxes. A browser already rasterizes those.

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
- **No system fonts** holds for everything the four bundled faces cover
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
- **`nokreWebRefs`.** The static driver installed a `Refs` to write
  `/routing/` where the default writes `#routing`; the live one has to
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
`hashchange` deep links, per each file's stated ordering.

Two rules the glue keeps, because both are silent corruption if broken:
a pointer handed across is borrowed for the call and anything outliving
it is *copied* (`slice`, never `subarray`, or a transfer drags the whole
heap's ArrayBuffer along); and a view into wasm memory is never held
across a call back into the module, because growing the heap detaches
it.

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
core. Everything else an input carries — the focus a press moves, what
activation means, the latches an input releases — stays where it
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
  true.
- **Scrolling is the browser's.** The content is real, so a
  `scroll_region` is a real scroll container. No offset round-trips,
  and that element's `offset` simply goes unread here.
- **Paint order is document order.** The reference branches — a notice
  banner owns the bottom pane and the nav is hidden and inert behind
  it — and layout says the same thing by zeroing every nav rect. This
  edition reads no rects, so `chrome` has to make that branch itself;
  without it a screen showed two bottom bars stacked on each other.
  The same applies inside a row: a notice's leading control is emitted
  *before* its words because there is no rect to place it by.

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

### What the live driver has not taken over

- **Whole-screen re-render.** nokre rebuilds subtrees instantly and has
  no animation to preserve, so "build it again" is the model rather
  than a shortcut — and the glue compares the bytes and does nothing
  when they match, which is what most frames are. A node diff would
  buy a smaller write on the frames that do change. It is the next
  thing to build, not a correctness gap.
- **IME** is unhandled. Composition needs the `ime` events the canvas
  shell already sends, and this driver sends none yet.

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
- **Node ids.** With `Options.node_ids`, every focus stop carries its
  `NodeId` as `data-n` (and an inline link its span as `data-s`) — the
  live driver's way of naming the node the reader meant. A page written
  to a file has nobody to tell and leaves it off, *unless* that file is
  going to be booted over: identity across frames is what makes the boot
  a patch instead of a replacement, and a replacement throws away the
  scroll position the reader arrived at.
- **`Refs`.** How a route reference becomes an `href`, as a `ctx` +
  function pointer like every other action in nokre. The default writes
  the fragment the web shell already mirrors routes into (`#note~42`),
  so a link in a serialized page and a link in a running app point at
  the same screen. A driver publishing one file per screen installs its
  own.
- **The `nokre` class.** A driver puts it on whatever it wraps the
  screen in; the stylesheet hangs the root stack's padding, gap and
  bottom-chrome reserve off that one class.
- **The stylesheet** ([stylesheet.zig](../../src/render/dom/stylesheet.zig))
  is generated: thirteen grays in two ramps out of `core/color.zig`, six
  type scales out of `core/text.zig`, every padding, radius, target and
  stroke out of `core/layout.zig`, each container's own default gap and
  padding off the structs in `core/element.zig`, and the page margin off
  `tree.root_stack`. Nothing is transcribed, so nothing can drift. It is
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
