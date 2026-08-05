# Elements

The complete, closed set. Every element carries its semantics with it —
role, label, and state are intrinsic, which is why accessibility can be
derived rather than annotated. Layout metrics live in
[src/core/layout.zig](../src/core/layout.zig) (`metrics`).

There is no styling API. If an element doesn't do what you want, the answer
is a different composition of these elements, not a customization hook.

## Building with the cursor

Screens are written through the builder **cursor** — `app.root()`
hands one back, standing at the tree root. One method per element,
closed exactly as the element set is: a leaf method takes its element
struct (`b.button(.{ .label = … })`) or, for the content-only elements,
the content itself (`b.text(…)`, `b.heading(.h2, …)`,
`b.codeBlock(…)`; a styled or spanned paragraph is `b.styled(content,
style)` / `b.spanned(&.{…})`). A container method returns the child
cursor, so nesting is the return value:

```zig
const b = app.root();
try b.heading(.h1, "Inbox");
const row = try b.stack(.{ .axis = .horizontal });
try row.button(.{ .label = "Refresh", .on_press = .bind(State.refresh, state) });
```

Every method **is** a `tree.append` call — same validation, same string
copy, same contrast gates; there is no second truth about the tree. The
raw `Tree` API stays public as the substrate, and is the form for what
the cursor does not carry: a spanned *heading*, and a leaf's `NodeId`
outside the four twins below (`tree.appendId(b.at, …)` — a container's
own id is `b.at`). A sheet builder starts from
`app.at(try app.presentSheet(title))`, the cursor standing on the node
the framework handed back.

### Patching one node instead of rebuilding

Most screens are rebuilt from state: `app.reload()` for a gesture the
user made, `app.refresh(.{})` for a reply that landed (see
[routing.md](routing.md)). Two things are wrong to rebuild for, because
they move *while* work is running and the screen underneath is being
read, scrolled, or typed into — a status line's words, and a control's
percentage. For those, hold the node and patch it:

```zig
// in the builder — the leaf methods that hand their node back:
state.status_id = try b.textId(state.statusCopy());
state.button_id = try b.buttonId(.{ .label = tr(.exportKeys), .on_press = … });

// in the callback, with the user mid-form:
app.patchText(state.status_id, state.statusCopy());
app.patchProgress(state.button_id, percent);
```

`textId`, `styledId`, `buttonId` and `meterId` are the four leaves that
hand back a `NodeId` — the ones real screens address again, not one per
element. `patchText` replaces a text-bearing node's content;
`patchProgress` takes 0–100 and moves either a `button`'s
`progress_percent` (setting `in_progress` with it, since that pair is
one state) or a `meter`'s `value` as that fraction of its own `max`.
Both mark the frame, so the `invalidate()` that used to follow every
one of these is gone.

**Both decline on a stale id, silently.** A recorded id outlives its
node by construction — every rebuild frees the tree it named — so a
reply arriving one frame late is the ordinary case, not a programmer
error, and the state it wanted on screen is already there: the rebuild
put it there. Nothing reports, for the same reason `refresh` reports
nothing. A patch also cannot get a value past a gate `append` would
have refused (a percentage on a glyph or vendor button, a number over
100); those decline too.

### The load gate

Screens over async values keep their phase in `nokre.Load` — `idle`,
`loading`, `ready`, `failed`. It is pure vocabulary: the app writes it,
the app's screens read it, nokre never does (there is no framework
fetch, no staleness, no `Remote(T)` — a deliberate stop). The one
composition every consumer wrote at every such screen — say we're
loading, or say it failed and offer a retry, else build the content —
is the cursor's `loadGate`:

```zig
if (!try b.loadGate(state.view.phase, .{
    .loading = tr(.loading),
    .failed = tr(.couldNotLoad),
    .retry = .{ .label = tr(.retry), .on_press = .bind(State.retry, state) },
})) return;
// … build the ready content …
```

It returns whether to continue: `true` on `.ready` (having appended
nothing), `false` otherwise (having rendered the phase). `.idle` and
`.loading` render identically — an app that requests on first build
shows `.idle` for at most one frame, and distinct words for it would
flash. Every option defaults to appending nothing, so each state keeps
only what the screen actually says: drop `.retry` where retrying can't
help (a revoked invite), drop `.failed` where the failure is silent,
drop both copies and the gate is a bare phase check. `.title` adds an
`h1` over the loading and failed states alone, for screens that gate
their whole body and head the ready state with a loaded value (a row's
own name). The retry renders as a secondary-form button — recovery
beside the failure copy, never the screen's primary act. All copy is
the app's: nokre ships no words it would then have to translate.
A phase switch whose states say more than this (styled copy, extra
controls) stays a hand-written `switch` — the gate is the common
scaffold, not a required door.

#### … and the branch after it: ready, but nothing to show

`loadGate` answers `true` on `.ready` and says nothing about zero rows.
That branch is `emptyGate`, and it goes where the list would have gone:

```zig
if (!try b.loadGate(c.phase, .{ .loading = tr(.loading), .failed = tr(.eFailed) })) return;
try b.heading(.h2, tr(.invoices));
if (!try b.emptyGate(c.phase, c.invoices.len, tr(.noInvoicesYet))) return;
for (c.invoices.items()) |*row| try appendInvoice(b, row);
```

It answers "there are rows — go on", and on ready-and-zero appends the
one line the screen has for that and answers `false`.

It takes the phase **again**, deliberately. The empty line belongs
beside the rows, which is usually a heading and a tile group past the
`loadGate` that admitted the build; a count-only verb standing there
would print "No invoices yet" over a request still in flight. So a
not-ready phase gets `false` with nothing appended — this verb never
speaks before the phase is settled, and never speaks *about* the phase
either, which is the other gate's job.

The line is **plain body text**. An empty state is the whole of what
that region says, not a footnote under something else, so it is not
dimmed or shrunk. `null` copy is the section that vanishes silently
when it has nothing, the same floor `loadGate`'s optional copy has. A
screen that wants more than one line — a hint under it, a control that
fills the emptiness — appends those itself; this is the common floor,
not a required door.

### The in-flight gate

`Load` is display-only and `Button.in_progress` is a pixel: nothing in
the framework *produces* busy. `nokre.Gate` is that missing bit, in the
same slot as `Load` — pure data nokre never reads.

```zig
pub const Invites = struct {
    deleting: nokre.Gate = .{},

    pub fn deleteInvite(self: *Invites, id: []const u8) void {
        if (!self.deleting.begin()) return;         // the second press does nothing
        self.port.deleteInvite(id, nokre.bindAs(Port.DeleteCallback, onDeleted, self));
    }

    fn onDeleted(self: *Invites, result: Port.Result) void {
        self.deleting.end();                        // on every arm, failure included
        …
    }
};

// and the screen reads the one bit:
try b.button(.{ .label = tr(.delete), .in_progress = c.deleting.up, .on_press = … });
```

`begin` fuses the check and the set and answers whether to proceed;
`end` lowers and is idempotent, because the reply paths that call it
include ones that never raised it. `up` is the public field, because
reading it is the whole consumer story and a second spelling would be
two names for one fact — but write it through the two verbs: a bare
`= true` is exactly the race the type exists to close.

**Put `begin` last in a compound guard.** It mutates, so a screen's own
preconditions go in front of it, where `or` short-circuits past it
instead of leaving the gate up on a path that then returns:

```zig
if (!self.form.ready() or !self.creating.begin()) return;
```

There is **no `defer` helper**, and that is not an omission. The work
these latches cover is dispatched, not performed: `begin` runs on the
press and `end` runs in a callback landing frames later, on paths the
raising function cannot see. `defer` composes with the wrong lifetime.

A latch, not a machine — no phases, no staleness, no "which row", for
the reason `Load` is not a machine either. A flow with more words than
up and down keeps its own enum, and a phase that happens to feed
`in_progress` (`stage == .sealing`, `search_phase == .searching`) is a
richer fact that stays the app's.

### The confirm sheet

The other composition every consumer wrote identically: a sheet that
asks before it acts. Title, what is about to happen, what went wrong
last time, the act, the way out — `confirmSheet` is the four appends
after the title, on the sheet's own cursor:

```zig
const sheet = app.at(try app.presentSheet(tr(.removeMemberTitle)));
try sheet.confirmSheet(.{
    .body = tr(.removeMemberBody),
    .error_copy = if (self.failed) tr(.couldNotRemove) else null,
    .confirm = .{ .label = tr(.remove), .on_press = .bind(Members.confirmRemove, self) },
    .cancel = .{ .label = tr(.cancel), .on_press = .bind(nokre.App.closeSheet, app) },
    .busy = self.removing,
});
```

The question is the sheet's *title*, so it stays `presentSheet`'s
argument; `.body` and `.error_copy` are optional, and a confirmation
with more to show — a continuity warning, a checkbox that gates the
act — appends that itself first and then calls this for the tail.
`.busy` marks the primary `in_progress`; `.confirm.disabled` is the
sheet's own precondition (a box not ticked), which is a different fact
and stays a different field.

**Cancel stays enabled while the act is running.** nokre has no spinner
and no animation, so a busy confirmation shows a static `…` primary and
nothing else moves: a user who cannot tell whether anything is
happening must keep the way out. It is reachable anyway — Esc, the
scrim, and the close control the framework pins are all live — so a
disabled Cancel would be a control lying about what the sheet permits.
What a cancelled act owes, a reply landing on a sheet that is gone,
belongs to the handler that started it.

### Holding what a callback borrowed

Every slice a service or a port hands a callback is borrowed **for that
callback**. A screen that draws it next frame has to own a copy, and
owning without an allocator means a fixed capacity. `nokre.Str(cap)`
and `nokre.Rows(T, cap)` are those two shapes, in the same slot as
`Load`: pure data the framework never reads.

```zig
const max_invoices = 24; // a ceiling, not a business rule

const InvoiceRow = struct {
    id: nokre.Str(64) = .{},
    amount_cents: i64 = 0,
};

pub const Billing = struct {
    app: *nokre.App = undefined,
    phase: nokre.Load = .idle,      // the phase stays beside the list
    name: nokre.Str(96) = .{},
    invoices: nokre.Rows(InvoiceRow, max_invoices) = .{},
};

// Bound into the port's own callback type — see "Binding callbacks
// nokre never sees" below; the port need not know nokre exists.
// port.dashboard(id, nokre.bindAs(Port.DashboardCallback, onDashboard, self));
fn onDashboard(self: *Billing, result: Port.DashboardResult) void {
    switch (result) {
        .ok => |dashboard| {
            self.name.set(dashboard.name);        // copied out of the reply
            self.invoices.clear();
            for (dashboard.invoices) |invoice| {
                const row = self.invoices.push() orelse break;
                row.id.set(invoice.id);
                row.amount_cents = invoice.amount_cents;
            }
            self.phase = .ready;
        },
        .err => {
            self.invoices.clear();
            self.phase = .failed;
        },
    }
    self.app.refresh(.{});
}
```

**`Str(cap)`** — `set` copies and replaces; `get` hands the bytes back;
`eql` compares against any slice (two `Str`s are `a.eql(b.get())`);
`trimmed` drops surrounding ASCII whitespace and `blank` is that trim
coming up empty. `len` is a public field, so `name.len != 0` is the
idiom for "there is one". Not a builder: no `append`, no `fmt` — build
a string in a stack buffer and `set` it once, or use `tree.fmt` for
strings the tree will own anyway.

`set` accepts a slice of the `Str`'s **own** bytes, so trimming,
re-parsing or normalizing in place is one line
(`field.set(field.trimmed())`) rather than a round trip through a
scratch buffer. `Rows.fill` takes the same guarantee —
`list.fill(list.items()[1..])` drops a head.

A `set` past the ceiling truncates, and **never splits a UTF-8
sequence**: the cut backs up to the start of the codepoint it landed
inside, so what comes back is always something you can hand straight to
`append` again.

**`Rows(T, cap)`** — `items()` to draw, `at(i)` for a screen holding an
index (`null` past the end, so a stale index is not a crash),
`itemsMut()` for `std.mem.sort` or an edit in place. Filling is
`clear()` then either `push()`, which hands back an empty slot to write
field by field (`null` at the ceiling), or `append(row)` for a row
already built; `fill(slice)` replaces the whole list at once. `removeAt`
closes the gap and keeps order, and `full()` says the next push would
refuse. Both types re-state their ceiling as a declaration
(`@TypeOf(list).capacity`), for the `meter` max or the copy that names
it where the constant is not in scope.

**The ceiling is disclosable.** Both types carry `truncated`: on a
`Str` it means the last `set` stored less than it was given, on a
`Rows` it means something was offered and did not fit. Each verb that
installs a whole value answers for that value — `set` and `fill`
overwrite the flag, `clear` clears it — while `push` and `append` raise
it on every refusal, so a `clear`-then-fill loop accumulates one honest
answer. A screen that wants to say "showing the first 24" reads it; one
that does not, ignores it. What neither type does is truncate in
silence, which is what every hand-rolled `@min(cap, reply.len)` did.

`Rows` carries no `Load`. The phase is the app's — one request may fill
two lists, and one list may be filled by two requests — so it stays a
field beside it, exactly as the example above has it.

## Static

### `text`
Body copy. Wraps greedily at word boundaries within the parent width.
Options: `style` (family `mono`/`prose`, scale, one of the thirteen grays).

Inline structure comes from `spans` — Markdown's inline vocabulary, not
a styling hook: each span is a run of the content with `strong` (bold),
`emphasis` (italic), `code` (the mono family, verbatim voice), `strike`
(struck through), and optionally its own gray, which faces the same
append-time contrast gate as the element's ink. Give either `content` or
`spans`, never both: with spans, `append` writes the concatenation into
`content`, so assistive tech announces one plain text node — span
boundaries are invisible to it by design. That places the same duty on
spans that grayscale places on color: a span may restate emphasis the
words carry, never be information's only carrier. **`strike` is where
that duty bites hardest**: a struck price is heard as a price, so the
words around it have to say which one applies ("Fees are ~~£20~~ £0"
reads correctly struck or not; a bare struck list of options does not).
Wrapping treats the spanned text as one flow — a word crossing a span
boundary never breaks there — and measures each run with its real face;
bold and italic are drawn faces bundled per family, never synthesized.
`strike` is not a face: no bundled family ships a struck variant and
synthesizing one would re-open the rasterizer variance the bundled fonts
exist to close, so it is a 1px rule drawn a quarter of the em above the
baseline — through the lowercase band — and it costs the measurement
nothing. Scale stays element-level: mixed sizes inside a line would
break the uniform line box.

A span with a destination is an **inline link**, and the one carve-out
from everything above. It is a control, not styling: underlined, its
own tab stop in document order, activated by tap/Enter/Space, and
announced to assistive tech as a link inside the paragraph — a link
nobody can hear is worse than no link at all, so the invisibility rule
stops exactly where behavior starts. A destination is exactly one of
two kinds, and the split is semantic, never visual: a `route` resolves
through the router like a `link` element's, so a bad one is refused
where every other bad route is and the audit names the node
([routing.md](routing.md), errors and refusals); an `external`
URL is handed to the system browser through the
[open_url](services.md) service, whose closed scheme allowlist
(https/http/mailto) is checked at `append` — nokre still renders no
external content. `append` holds both kinds to the rules every other
control obeys: never both destinations at once, and words that aren't
only whitespace. A span with **no** destination is simply prose, and
an empty `route` is how a span says so — every route-carrying field in
the set is a plain `[]const u8` defaulting to `""`, never an optional,
so "no route" has one spelling and every reader asks one question
(`route.len > 0`).

A link that wraps — or that a bidi line splits into separate visual
runs — occupies several rectangles, and every one of them underlines,
rings when focused, and takes taps; the prose between them does none of
those. Drawing, hit testing, and the focus ring (drawn on
keyboard-origin focus only — [accessibility.md](accessibility.md#focus))
all read the same geometry walk, so what you see underlined is exactly
what you can tap.

### `heading`
`h1` through `h6`, mapped to fixed sizes on the type scale. Headings are
structure, not styling — the a11y audit fails if you skip levels.

| Level | px | Level | px |
| --- | --- | --- | --- |
| `h1` | 32 | `h4` | 18 |
| `h2` | 24 | `h5` | 16 (body) |
| `h3` | 20 | `h6` | 12 (small) |

Only three sizes sit above the 16px body, so size alone cannot carry six
levels. Every level draws **bold**, in the family's real bundled bold
face — never synthetic emboldening — which is what keeps `h5` and `h6`
reading as headings beside the prose they share a size with. Contrast is
unaffected: nokre holds all text to 4.5:1 regardless of size, declining
WCAG's large-text exemption, so the scale carries no palette consequences.
Takes `spans` like `text` (base face bold
prose, base ink `.ink`) for the `code` word inside a title; because the
base is already bold, a span's `strong` adds nothing to a heading and a
span without it does not drop back to regular — span variants compose
onto the element's face rather than replacing it.

### `icon`
One named Lucide glyph, laid out as a square line-height box so it
aligns with same-scale text beside it. Options: `name` (the `IconName`
enum — its value is the icon-font codepoint), `scale` (the six text
scales), `ink` (the thirteen grays), `label`. `IconName` holds every
glyph in the bundled font, under Lucide's current name for it — the
retired aliases are absent (`square_activity`, never `activity_square`),
and so are the brand marks Lucide dropped from the font. An empty label means
decorative: hidden from assistive tech, any ink allowed. A non-empty
label makes it a meaningful image: it is announced by name and its ink
must clear the same contrast gate as text.

### `divider`
A 1px horizontal rule across the parent width.

### `badge`
A static inline status label: small-scale text inside a rounded 1px
`.g10` border, sized to its content. Where color-coded chips carry state
by hue elsewhere, here the words carry it — "Active", "Owner",
"3 pending". The border is grouping, not state, so it draws `.g10` like
`box`, not the `.g6` state carrier of selected chips. Never interactive
(an actionable chip is a `button`), and the label must be non-empty —
an empty badge is a floating border saying nothing. For status inside a
`tile` row, use the tile's `detail` line instead of nesting a badge.
Semantics: plain static text; assistive tech hears the words, which is
everything the badge *says*.

An optional `icon` (any [`IconName`](#icon)) leads the chip, on a
`tile`'s terms: decorative, a field rather than a child node, so the
mandatory `label` stays the accessible name and no glyph can enter the
tree to double it. It draws at the chip's own scale and ink (`small`,
`.ink`), so it opens no styling surface and reaches the contrast gate
exactly where the label already cleared it.

**It restates; it never states.** "The words carry it" was never about
whether a chip may hold a glyph — it was the refusal of *state conveyed
by ornament instead of language*, the same refusal that keeps hue out.
A mark that means something the words do not is that refusal broken: the
chip then says less to a reader than to a looker. The check is one
deletion — take every mark off the screen, and nothing on it has stopped
being true or knowable. What a glyph buys is recognition in a row that
gets scanned; a dimension chip's mark restates the dimension its label
names, a tag chip's restates the family its set is organised by. A chip
whose words are the whole story and whose glyph is the only clue that
something failed is the case this paragraph refuses.

Unlike a `tile`, chips carry **no all-or-nothing rule** and no fixed
band: a tile's mark reserves a `lineHeight` square so a *column* of rows
starts its words on one x, and chips are intrinsic-width and flow
inline, where there is no column to hold. So a chip is charged only the
glyph's own advance plus the icon gap — a flat **20px** at the small
scale, the same for every glyph in the bundled face (pinned by a test,
since the guidance below rests on the number).

Twenty pixels is 15% of a long chip and over a third of a short one, on
an element that is often several across in a row on a 320pt screen. That
row [wraps](#a-row-too-narrow-for-its-children) rather than clipping, so
the width a mark takes is spent in *lines* now rather than in pixels off
the edge — cheaper, and still spent. So: **a mark earns its width where chips are read as a
set** — a row of tags, a row of dimensions, where the glyphs are what
lets the eye sort them — and not on a lone chip beside prose, where it
is 20px spent on a picture of a word already visible next to it.

**A number with a name on it is a badge.** "3 credits", "12 active
keys", "2 pending" — a quantity and the thing it counts, formatted by
you (nokre does no number formatting; that is
[localization.md](localization.md)'s refusal) and handed over as one
label. That is what the element is: the chip whose *words* carry the
state, so a labelled scalar is its central case rather than an
afterthought. Reaching for `text` instead is the mistake this paragraph
exists to prevent — plain text puts the figure in the prose column at
prose weight, where nothing distinguishes a live count from a sentence
about one, and the border a badge draws is exactly what says "this is a
reading, and it changes".

The one to hand it to `meter` instead is a **fraction of a whole you
want seen as a fraction**: "5 of 10 uses", "12 of 30 days". Both
elements put the state in the words, and the split is whether there is a
whole to be part of and whether being three-quarters through it is worth
a glance. A count with no ceiling ("3 credits") has no bar to draw and
takes the chip; a count against a ceiling you are meant to feel takes
the bar and the full width it needs. Where the ceiling exists but the
fill would say nothing — "1 of 4 seats", in a row of other chips — the
badge is still the honest answer, and the words still say all of it.

### `meter`
How much of a whole is filled: a full-width bar under words that state
it, at `text_input`'s label scale. As with `badge`, the words carry the
state — `label` ("12 of 30 days") is mandatory, rendered above the bar,
and is what assistive tech hears; the `value`/`max` fill only restates
it visually. `append` rejects an empty label or a value outside
0...max. The track is the `segmented` pattern: dimmed `.g11` with a 1px
`.g6` border carrying WCAG 1.4.11, an `.ink` fill inside. Never
interactive, never animated — for indeterminate waiting, write
"Loading…" as `text`; a spinner is animation, which nokre refuses.
Semantics: plain static text, the words.

### `qr`
A verbatim value restated as a scannable QR code — `copyable`'s visual
twin for the value that leaves through a camera instead of the
clipboard. `label` (mandatory, rendered above at `text_input`'s label
scale) is what assistive tech announces; `value` (mandatory, and
carried alongside the label) is the encoded text. Encoding happens once
at `append` — medium error correction, no knobs — via the vendored
reference implementation ([deps/qrcodegen](../deps/qrcodegen/),
Nayuki's C library: single file, no heap, deterministic); a value that
cannot encode is rejected there (`QrValueTooLong`, `QrValueNotText`).

The square renders at a whole number of pixels per module (fractional
modules blur and break scanning) with the spec's 4-module quiet zone,
capped at `metrics.qr_max_side`. It is the one surface that ignores the
appearance: scanners want dark modules on a light ground, so the code
draws ink-on-paper from the light palette in dark mode too — a
deliberately light tile. Never interactive; put a `copyable` beside it
carrying the same value for the clipboard path. Semantics: an image
named by the label, carrying the value.

## Containers

### `stack`
Vertical (default) or horizontal flow. `gap` (default 8), `padding`
(default 0). The tree root is a vertical stack with padding 16.

A borderless stack's padding is an advised margin, not a wall: children
are inset by it as usual, but an element that must reach an edge to
work — today only an overflowing `segmented` track — may decline the
advice and bleed through it, never past the nearest drawn edge. Which
element bleeds is the framework's decision, not a knob. Negative
`padding` and `gap` are rejected at `append`: the escape a negative
inset buys elsewhere is exactly what declining the advice provides,
bounded by an edge instead of a number.

#### A row too narrow for its children

A horizontal stack that runs out of line does one of exactly two things,
and **the row's own children pick which**. There is no field, no wrapper
and nothing to opt into, so there is no way to be handed the wrong one:

- **A row of actions folds.** Every child a `button` or a `link`, two or
  more of them: the tail collapses into a `More` control and the row
  stays one line. [The folded tail](#the-folded-tail-more) has the
  mechanics.
- **Every other row wraps.** Children flow along the line and break onto
  a new one when the next will not fit — greedy, first-fit, in document
  order, each line `gap` below the last and centered on its own tallest.

The split is what the row *is*. Actions have to stay reachable and a user
needs all of them, so one row plus a control that opens the rest is the
honest shape; folding three status chips behind `More` would hide state
behind a press, and clipping them would hide it outright. Wrapping is
also the answer for the rows that cannot fold — a lone action, and a row
of actions inside a sheet, which has no second sheet to fold into.

Width is not an input to the choice. A row is a row of actions or it
isn't, at every viewport, so resizing the window can change where a line
breaks or how deep a tail folds, but never which of the two the reader is
looking at.

Wrapping bounds the problem the way shortening the words never could:
**a row can always fit, as long as each child fits a line on its own.**
One that does not — a chip whose label alone exceeds the span — gets a
line to itself and overflows it. Nothing ahead of it pushes it further
out and nothing behind it is dragged along, but nokre does not shrink it,
elide it or refuse it: an oversized chip is over-long *words*, and the
words are the whole element ([badge](#badge)).

Wrapping changes where marks land and nothing else. No node is added,
removed or hidden, the focus order is document order either way, and the
accessibility snapshot of a row that wrapped is identical to the same
row's on a wider screen. A reader is never told a line broke — because
nothing about the app did.

### `box`
Grouping container: vertical flow, optional 1px border (default on),
`padding` (default 12), optional `fill` gray. Boxes group; they do not
decorate. A box's edge is a wall: the margin advice stops at it, so
nothing ever bleeds across a border.

In vertical flow a box takes the full width. Unstretched — as a child of
a horizontal `stack`, or inside a table cell — it hugs its widest child
plus its own padding, so a row of small boxes stays a row instead of
running off the edge after two.

### `scroll_region`
A viewport over vertically flowing children. `height` fixes the viewport
height; leave it null to fill the space remaining below the region.
Content is clipped; a 2px indicator bar reflects the offset. Focusable:
arrow keys, page up/down, home/end scroll it. `content_height` is written
by layout.

The bar has two tones, switched by state, never by time: emphasized
while its surface is engaged — focused, held by a touch drag, or the
last thing scrolling input moved — and quiet at rest. The overlay
scrollbar's prominent-when-relevant behavior without its two failures:
"fade after the scroll stops" needs the wall-clock timer the
deterministic core refuses, and a bar that vanishes at rest takes the
only sign the content scrolls with it. So emphasis latches until the
next non-scroll input, and the resting bar stays readable. At rest the
primary "more is there" affordance is the content itself, cut
mid-element at the viewport edge; the audit fails a fixed-height region
whose offset-0 edge cuts nothing visible (see
[accessibility](accessibility.md)) — adjust the height a few px so the
edge crosses ink, not a gap or a text line's leading.

The window itself needs no wrapper: content taller than the viewport
scrolls implicitly — wheel outside any scroll region, scroll keys when no
widget consumes them — and Tab always scrolls the focused element into
view. The implicit window scroll is not a tab stop.

Wheel scrolling routes at the pointer, event by event: delta a region
cannot consume chains outward to enclosing regions and then the window.
A touch drag instead belongs to the scroller it starts in — momentum
included — even when the finger leaves it or its content runs out;
nothing else moves until the finger lifts.

## Interactive

Every interactive element **requires a label**. That is not a convention
and not a lint: `tree.append` refuses to construct an interactive element
with an empty label — an inaccessible control cannot exist.

### `button`
`label`, `on_press`, `disabled`, `in_progress`, `form`. A filled pill —
ink fill, paper text — ringed on keyboard-origin focus
([accessibility.md](accessibility.md#focus)). Activated by tap, Enter,
or Space.

`form` says which button this is, as a tagged union with four faces:
`.filled` (the default), `.secondary`, `.glyph`, and `.provider`. One
field rather than four flags, because the flags' illegal combinations —
a glyph form without a glyph or with an emphasis, an icon beside a
vendor mark, a glyph-only sign-in, an outlined Google — used to be five
separate refusals at `append`; as a union they are not states the type
can spell, and what compiles, appends.

`.secondary` is the one emphasis: an outlined pill — ambient
background, 1px `.g6` border (the segmented/toggle WCAG 1.4.11
carrier), `.ink` text — beside the filled primary. Identical geometry,
so the pair aligns; identical semantics, so assistive tech hears no
difference. Because its text draws on the ambient, it passes the same
contrast gate as `text` — a secondary button on a dark box fill is
rejected at `append`. There is no tertiary and no danger variant: one
filled, one outlined, and the words carry the rest.

`in_progress` says the button has been pressed and the work it started
is still running — not "loading", because nothing is being loaded, and
not a spinner, because a spinner is animation this frame model does not
have. The words stand down for `…`, the literal form of suspense and the
same mark nokre elides text with, centered in the pill at the size the
label and icon already bought it: the button does not resize when the
press starts or when the result lands, so nothing under the finger
moves. It does not dim. `disabled` is unavailable and dims; `in_progress`
is busy and stays at full strength, because the `…` is the only sign the
work is happening. A leading icon or vendor mark stands down with the
words; the glyph form has no pill, so the `…` takes the bare touch target
where the glyph was.

The button stops activating — tap, Enter, and Space all pass over it, so
a second press cannot start the work twice — but unlike `disabled` it
**keeps its focus stop**. The user pressed this button, usually with the
keyboard; taking the stop out from under their own focus is the loss
WCAG 3.2.2 is about. Assistive tech is told what the pixels say: same
accessible name (the `…` is a state, not a name — a voice-control user
keeps the phrase they were about to say), disabled *and* busy
(`aria-disabled` + `aria-busy`, AccessKit's `busy`), still reachable.

Setting both flags is allowed and is not a redundancy to reconcile: an
app deriving one from its form and the other from its work is doing the
normal thing. `in_progress` wins the pixels, `disabled` wins the focus
stop. In tests, `tap` on a button with work in progress fails with
`error.InProgress` rather than pressing nothing quietly.

```zig
// In the press handler: send the work, then say so.
app.tree.get(state.save_id).?.button.in_progress = true;

// In the reply handler, when it lands:
app.tree.get(state.save_id).?.button.in_progress = false;
```

Nothing clears it for you. nokre runs no timer and has no notion of what
your work is, so the state is yours to end — as ordinary a field as the
label beside it. Clear it on **every** path that ends the work, not just
the one that succeeds: a button cleared only by the success reply sits
at `…` forever the first time the work fails, times out, or is
cancelled, and it is the one control on screen that cannot be pressed
to recover.

`progress_percent` (0–100) is the same state with a number attached.
Set it and the `…` gives way to a meter track in that same slot —
`meter`'s own geometry, centered, growing from the leading edge and
mirroring under RTL. The pill does not change size, fill, or tone: only
what stands in the middle changes, so a button at 0% is still visibly
the button, which is exactly what a pill that filled itself could not
manage. Leave it null when the work cannot say — `…` means *no
estimate*, and a bar moving on a guess is worse than no bar.

The two tone pairs are the palette's, not a choice: inside the filled
pill the track is `.g7` with a `.paper` fill, because `g7` is the only
step clearing WCAG 1.4.11 (3:1) against the `ink` ground *and* against
the fill inside it in both appearances; the outlined pill sits on the
ambient ground and so reuses a standalone `meter`'s proven `.g11` track,
`.g6` boundary, `.ink` fill. A **disabled** button keeps its `…` even
with a number set: 1.4.11 exempts inactive components, which is the only
reason the pill may dim at all, and a dim pill is not a ground a meter
can be read on.

Rejected at `append`: a percentage without `in_progress` (it measures
nothing), past 100, on the glyph form (a bare glyph target has nowhere
to read a bar), or on a `provider` button (no vendor sanctions a bar
inside their artwork). Mutating into any of those afterwards is the
audit's `malformed_progress`.

The words and the accessible name do not change. Assistive tech gets the
number as the node's *value* — "Save changes, 60%" — rather than a
`progressbar` role the node cannot have while it is a button: the same
trade `meter` makes, where the state is in the words and the fill only
restates it.

```zig
// From a worker's progress reply:
const btn = &app.tree.get(state.save_id).?.button;
btn.progress_percent = pct;   // in_progress already true

// And when it lands — clear both; a number outliving the work is
// what `malformed_progress` catches.
btn.in_progress = false;
btn.progress_percent = null;
```

The pill forms carry an optional Lucide glyph as their payload —
`.form = .{ .filled = .alarm_clock_plus }` or
`.{ .secondary = .refresh }` — drawn inside the pill, leading the label;
both stay visible. An icon never hides the words by itself; the pill
just grows by one glyph advance. A pill with no icon says so with
`null`: `.{ .secondary = null }`.

`.glyph` drops the pill: only its glyph renders, quiet on the ambient
surface, centered on the standard 44px touch target — the exact
control framework chrome already uses for Back and the sheet close,
opened to consumers. The glyph *is* the payload
(`.form = .{ .glyph = .chevron_right }`), so a glyph form without one
cannot be written, and there is no pill for an emphasis to vary.
Nothing else changes — the label stays mandatory, is what assistive
tech announces, and is how tests reach it (`tapLabel("Next cycle")`);
disabled dims the glyph as the pill dims its text. Reach for it where
a compact repeated control sits beside the words that explain it — a
prev/next pager flanking a heading, a row's trailing action. A glyph
button whose meaning isn't obvious from its surroundings should have
kept its words — the labeled pill is the default, the bare glyph is
the exception.

`.provider` makes it a conforming vendor sign-in button: the vendor's
mark leads the label — occupying the glyph slot, which is why the type
offers no icon beside it and no glyph-only sign-in — and the label
stays yours to supply. `append` rejects an empty one
(`error.AuthButtonNeedsVendorLabel`), because nokre ships the mark and
no translation of the vendor's mandated string (see the localization
note below). This is the one place in nokre where the visual spec is
**not nokre's to choose** — every detail of these buttons is the
vendor's, which is exactly why the vendor style is the whole API.
There is no size, no ink, no corner radius: a knob here would be an
invitation to violate the guidelines the button exists to satisfy.

```zig
try b.button(.{
    .label = "Sign in with Apple", // the vendor's published wording, your locale
    .form = .{ .provider = .apple },
    .on_press = .bind(State.startSignIn, state),
});
```

Nothing else changes. Role is `button`, activation is a plain button's,
the label is what assistive tech announces and how tests reach it, and
the mark is decorative — it carries no accessible name of its own, so it
is hidden from assistive tech and exempt from the contrast gate, the same
rule an unlabeled `icon` follows. It does **not** mirror under RTL: a
logotype is not directional, the same reason a `qr` symbol never flips.
Its *position* does mirror, because leading is leading.

The vendor styles are spelled out per vendor instead of composed from
an emphasis flag. Apple sanctions three — black, white, and white with
a black outline: `.apple` is the filled pair (the black button in
light appearance and, because the endpoints flip, the white one in
dark) and `.apple_outlined` is the outlined third. Google sanctions
*themes* rather than emphases — a light button (white, hairline
border) and a dark one — so the appearance picks the theme and the
outlined Google button no guideline describes is simply not a member
the type has.

The Google button's G is drawn in the vendor's four colors — the one
colored thing nokre ever puts on screen, painted by the renderer from
its own table. Nothing about it is yours to configure, which is the
`provider` field's whole design: there is no color API here or anywhere
else, and your app remains grayscale-only. The decision record — this
was a refusal for a long time, and reversing it meant widening the
frame format itself — is in [internals/oauth.md](internals/oauth.md).

One thing this does not do for you. **Localization**: the vendors
require their mandated string translated to the app's language, and
nokre ships no translation of it — inventing one would be fabricating a
mandated string. A translated app sets `label` itself, to the vendor's
own published wording for that locale.

The marks themselves are not nokre's work and are not covered by its
license — see
[LICENSE-Brand.txt](../src/assets/fonts/LICENSE-Brand.txt).

#### The folded tail (`More`)

Put actions in a horizontal `stack` and nokre shows as many as fit. When
they don't all fit, the row **folds**: the last completely visible one
gives up its slot to a control labelled "More" (the framework's own word,
`App.Chrome.more` — see [localization.md](localization.md)), and pressing
that opens a sheet holding it and everything after it, in the row's own
order.

This is not opt-in and takes no setup — no flag on the stack, no wrapper,
no width to declare. Any row of actions you have already written folds
the moment it runs out of room.

```zig
const row = try b.stack(.{ .axis = .horizontal, .gap = 8 });
try row.button(.{ .label = "Publish", .on_press = ... });
try row.button(.{ .label = "Save draft", .on_press = ... });
try row.button(.{ .label = "Archive", .on_press = ... });
try row.link(.{ .label = "More details", .route = "details" });
// Narrow enough, this renders: Publish · More
```

There is no API for it — no `overflow` knob, no "collapse at" width, no
way to nominate which action folds first. How many actions a row can show
is the framework's decision, like the nav's shape: you declare them,
nokre draws as many as the viewport allows and reshapes as it changes.

**What counts as a row of actions:** every child is a `button` or a
`link`. Those are the two press-me leaves whose whole state is what they
call or where they go, so the sheet can restate one *whole* — same
action or route, same emphasis, same disabled and in-progress state — and
the press means the same thing in both places. A `toggle`, `checkbox`,
`select`, or field keeps its state in the node, and a restatement of one
would take the press and leave the original saying the old thing.

Anything else in the row and it doesn't fold: two arrows with a month
between them is a pager, not a menu, and folding "March" behind a control
named for having more would be nonsense. A row of one action doesn't fold
either — that hides the only action twice. Those rows
[wrap](#a-row-too-narrow-for-its-children) instead, which is the other
half of the same rule.

The fold is deliberately one action deeper than the overflow itself. The
one that was already half off the screen is not the one to replace:
put the control there and it stands at the very edge it exists to
rescue, and the row reads as two failures at once.

Details worth knowing:

- **Folded is gone, not dimmed.** A folded action draws nothing, takes no
  tap, keeps no focus stop, and is invisible to assistive tech. Tab goes
  from the last standing one to More.
- **Your nodes survive.** The actions stay in the tree with their ids and
  their state; a wider viewport puts them straight back. Mutating a
  folded button (`in_progress`, `disabled`) is fine and shows up when it
  returns.
- **Focus follows the shape.** If the action you were on folds away,
  focus lands on the control that now holds it; when the row grows back,
  focus moves off the departing control to the row's trailing end
  (WCAG 3.2.2).
- **Pressing an action in the sheet closes it**, the way choosing a row
  closes a picker — unless the press did nothing (disabled, or work
  already running), in which case the sheet stays where it is.
- **Not inside a sheet.** There is one sheet at a time, so a row already
  inside one has nowhere to fold to; it keeps every action it was given
  and [wraps](#a-row-too-narrow-for-its-children) to a second line. A
  sheet is a handful of controls, not a toolbar.
- **The sheet closes if what it lists stops being true.** The window
  grew and the actions are back on the row; it folded deeper and the
  open list no longer names everything hidden; or a folded original
  changed *state* — its words, `disabled`, `in_progress`, progress,
  form (emphasis, icon, or provider mark), a link's destination, or the action
  itself. The sheet restates each action whole, so on any of these it
  is dismissed rather than left saying something untrue.
- **In tests**, a folded action is not addressable by its words:
  `getByLabel` reports it as folded, and `tap` on a node id you kept
  fails with `error.Folded`. Reach it the way a user does — `tapLabel("More")`,
  then the action.

### `link`
`label` + exactly one destination: `route` or `external`. Underlined.
Links never carry arbitrary actions; if you want an action, use a
button. The `route` is a reference: a route name, optionally with
arguments (`note~42`, see [routing.md](routing.md)) — same for every
other `route` field below. `external` is a URL handed to the system
browser on activation, held to the [open_url](services.md) scheme
allowlist (https/http/mailto) at `append`; it draws identically to a
routed link, because where a link goes is semantics, not a visual
variant. Setting both, or neither, is rejected at `append`.

### `toggle`
On/off state as an iOS-style pill switch: `label`, `on`, `on_toggle`,
`in_progress`. Flipped by tap/Enter/Space; the change applies
immediately — a toggle never needs a submit button beside it, and one
whose change has to reach a server before it is true says so with
`in_progress` rather than borrowing one. On: `.ink` track, `.paper` knob
at the trailing edge. Off: dimmed `.g11` track, knob at the leading
edge, both outlined `.g6` — as in `segmented`, the border is what
carries the WCAG 1.4.11 state. Semantics: a switch (announced on/off),
not a checkbox — a choice that waits for a submit control is a
`checkbox`. The row is `metrics.touch_target` (44px) deep — the switch
and its words centered in it — because the 20px track is the whole
affordance and a one-line row would leave it at the WCAG floor; it
matches the tile rows in `radio_group` and the select picker. Stack two
of these (or a toggle and a checkbox) and the flow gap between them
collapses: each already carries its own padding, and counting the
stack's gap on top would hold them three gaps apart. Anything else
beside one — a pill, a field — keeps the full gap.

`in_progress` is `button`'s state on a switch, and it differs from the
button's in exactly one place: what stands down is not the words but the
**switch**. A button's words say what the press will do; a track says
what the value *is*, and while the work is in flight neither is
knowable. So the track and its knob give way to `…` — the same mark, the
same reason — in the slot they occupied, at the size layout already gave
the row. Nothing else changes: the words stay where they were, the row
keeps its height and width, and the flip does not reflow the screen out
from under the finger that made it. It does not dim; busy is not
unavailable.

The switch stops flipping — tap, Enter, and Space all pass over it — but
**keeps its focus stop**, for the reason `button`'s does. Assistive tech
hears the same pair (disabled *and* busy, still named, still reachable)
and, unlike the button, still hears the **value**: the `…` is a
rendering, and a reader who cannot see it is owed the state the app
still holds. In tests, `tap` fails with `error.InProgress` rather than
flipping nothing quietly.

```zig
// In the toggle handler: the flip is a request, not a fact — put the
// value back where the server still has it and say work is running.
const t = &app.tree.get(state.notify_id).?.toggle;
t.on = !wanted;
t.in_progress = true;

// In the reply handler: clear it on every path that ends the work, and
// move the value only on the one that succeeded.
t.in_progress = false;
if (ok) t.on = wanted;
```

Nothing clears it for you, and a switch left at `…` is worse than a
button left there: it is the one control on the row that cannot be
pressed to recover. Clear it on failure and cancellation too.

There is deliberately no `progress_percent` twin: a 20px track has
nowhere to read a bar, which is the same reason a glyph-form button is
refused one. And no `disabled`, still — a switch that cannot be flipped
at all is a screen that should not be drawing one.

### `checkbox`
On/off state as a square check box: `label`, `checked`, `on_toggle`,
`in_progress`. The same interaction as `toggle` — flipped by
tap/Enter/Space — but the
opposite contract: checking commits nothing by itself; the choice waits
for a nearby control to gather it (consent-then-submit, picking members
from a list). If flipping it takes effect immediately, it should have
been a `toggle`. Checked: `.ink` box with a `.paper` check glyph.
Unchecked: dimmed `.g11` box outlined `.g6` — the toggle/segmented
WCAG 1.4.11 pattern. There is no indeterminate state; a "some of these"
summary is a screen problem, not a control problem. Semantics: a
checkbox (announced checked/unchecked). Its row is 44px deep for the
same reason `toggle`'s is.

`in_progress` is `toggle`'s, box for track: the box and its mark stand
down for `…` in the slot they had, with the same lockout, the same kept
focus stop, and the same busy announcement. It is the rarer of the two,
because checking commits nothing by itself — but a box whose row is
gathered the moment it is ticked has work in flight like any other, and
nothing else on the row can say so.

### `radio_group`
The same exclusive-choice semantics as `segmented` in a different form:
a full-width tile group under a visible group label (small scale, like
`text_input`'s) — a rounded 1px `.g10` border around 44px option rows,
one hairline between them. Same fields — `label`, `options` (2+),
`selected`, `on_select`. One tab stop (focus takes the group's own
border, not the label); ↑/↓ (and ←/→) move the selection and commit
immediately; tapping a row selects it. Reach for it when every option
should stay visible at once — a choice made once and submitted — where
`segmented`'s scrolling track would hide some. The
group border is grouping, not state: the selected row's filled circle
with a paper dot (unselected rows show a `.g6` ring) carries the
selection.

### `text_input`
Single-line. `label` is mandatory and rendered above the field (small
scale). `value`, `placeholder`, `cursor` (byte offset), `on_change`,
`on_submit` (Enter). Editing is UTF-8 codepoint-aware (backspace/delete,
←/→, Home/End). `composition` holds in-progress IME text, rendered dark
with an underline; IME is live on every platform, the web included
([internals/platform-shells.md](internals/platform-shells.md) has the
per-shell contract).

While the field holds focus, a pointer release that lands on nothing
interactive clears it, and on-screen keyboards follow focus down. That
is dismissal without spending a pixel of chrome — no Done bar, no
tap-catching scrim — the least intrusive answer, the same restraint
that keeps content from scrolling itself.

`obscured` makes it a password field: every codepoint (composition
included) renders as a bullet at a fixed advance, and the value is
withheld from assistive tech (announced as a secure field) and from
test traces. Editing, placeholder, and caret behavior are unchanged.
The placeholder stays plain — it is a hint, not the secret.

#### `problem`: what is wrong with the value

`problem` holds the reason the field's value was refused, in your own
words. Empty is the ordinary state; any words at all make the field
**invalid**. The message hangs under the field's outline at the same
gap the label stands above it — small scale, full ink, no mark — so
the label, the field and the reason read as one thing.

```zig
try b.textInput(.{
    .label = state.tr(.email),
    .value = form.email.get(),
    .problem = if (form.rejected) state.tr(.emailNotAnAddress) else "",
    .on_change = .bind(onEmail, state),
});
```

nokre validates nothing and has no opinion about what a valid value
is. What it owns is the *association*, and the association is the part
you cannot build from outside: a message appended beside a field is
prose that happens to sit nearby, and prose carries no relation — no
`aria-describedby`, no `aria-invalid`, nothing an assistive technology
can follow from the control to the reason. Both editions state the
pair (`aria-invalid` plus a reference on the web, AccessKit's `invalid`
and description natively, `setContentInvalid`/`setError` on Android),
and it is announced after the name and the value, which is where a
reason belongs: what the control is, what it holds, then why that is
not accepted.

A field with a problem is **not disabled and not busy**. It takes every
keystroke it took before — a control the user cannot edit is a control
that traps them in the value that was just refused. That is the whole
difference from `Button.in_progress`, which really is both.

Two things that are not this field. A failure that belongs to the
*form* rather than to one of its values — a rate limit, a server that
declined, a permission the account lacks — is not a field error; it is
either the screen's own prose or a [notice](#notice), and putting it on
an arbitrary field would point the user at a value that is fine. And
the framework never writes these words: an empty-looking problem (only
spaces) marks the field invalid with nothing to say, which the
[audit](testing.md) fails as `wordless_problem`.

### `text_area`
Multi-line `text_input`: same fields minus `on_submit`, because Enter
inserts a newline — a field that swallows Enter to submit loses the one
key a multi-line editor cannot give up. Submission belongs to an
explicit `button` next to it.

The value wraps exactly like prose (greedy, word-boundary, hard `\n`
breaks) and the field grows with its content, never below three rows —
there is no inner scrollbar to fight the page's own scrolling. ↑/↓ move
the caret between visual lines preserving its horizontal position;
Home/End go to the bounds of the caret's line (the whole value is a ↑/↓
walk away). Everything else — codepoint-aware editing, placeholder, IME
composition — matches `text_input`, `problem` included: the words hang
under the field the same way and the field is announced invalid the
same way. Semantics: a multiline text field carrying the value.

### `select`
An exclusive choice among many options, in `text_input`'s clothing: the
same labeled-field geometry, showing the current option with a chevron
affordance. Same fields as `radio_group` — `label`, `options` (2+),
`selected`, `on_select`. Reach for it when the options are too many to
lay out in place; for a handful, prefer `radio_group`, which shows
every choice at once, or `segmented` for a choice the user switches
repeatedly.

Activation (tap/Enter/Space) opens the framework's picker: a modal
bottom panel with the select's label as its title and one 44px tile row
per option — hairline-separated, like `radio_group`'s rows — scrolling
when they overflow. It uses the sheet's geometry and
scrim and may stack above an open sheet. The current option is
focused on open and rendered as a dimmed `.g11` chip with a 1px `.g6`
border (the `segmented` pattern); ↑/↓ move between rows without
wrapping, Enter/Space or a tap commits — closing the picker, updating
the field, and firing `on_select`. Esc or a tap on the scrim closes
without committing. Focus always returns to the field. Nothing is
committed until a row is chosen, unlike `radio_group`'s immediate
arrow-key commits — a closed dropdown is a promise, an open list is
a preview.

Long lists (8+ options) get a filter: a labeled `text_input` pinned
between the title and the rows, focused on open — a list that long
wants typing, not scanning. Typing narrows the rows to the options
containing the query (ASCII-case-insensitive substring); a query
matching nothing leaves the words "No matches" where the rows were.
The picker keeps the full list's height while the rows come and go, so
the field never moves under the typing. This is framework chrome, like
the picker itself — there is nothing to configure and no API. Short
lists stay bare: fewer than eight rows scan faster by eye than by
typing, and open with the current option focused as before.

Semantics: the field is a combo box carrying the current option as its
value; the picker is a modal dialog of option rows with selection
state, its filter a plain labeled text field. There is no multi-select;
if a choice needs more than one answer, the screen wants rethinking
more than the widget wants features.

### `copyable`
A verbatim value the user carries away — a recovery code, an invite
link — in `text_input`'s labeled-field clothing: `label` above, `value`
in mono inside the field, a copy glyph at the trailing edge. Both are
mandatory; `append` rejects an empty value — a control that copies
nothing cannot exist. One tab stop; activation (tap/Enter/Space) writes
the value to the platform clipboard through the shell — the behavior is
intrinsic, there is no action to wire.

So is the reaction: the copy glyph becomes a check, and stays one until
the next input. A copy leaves the screen identical, so without a mark
activation looks inert — and the screen cannot supply the mark either,
because clearing it after a moment needs the wall-clock timer the
deterministic core refuses. It latches instead, exactly as the scroll
indicator's emphasis does. Only one control in the app is ever marked:
copying somewhere else moves the mark there. Activating the marked
field copies again and returns the glyph — with no animation to replay,
the mark leaving is the only visible sign the second copy happened, and
a check that just sat there would read as a dead control. The glyph's
slot is reserved at the wider of the two marks, so nothing under it
moves when they swap. Assistive tech hears "Copied" from a polite live
region on the field, arriving and leaving with the mark.

Not an editor — the value cannot be changed in place; a value that
needs editing is a `text_input`, and prose worth reading is `text`.
A value wider than the field elides in the middle (`ab…yz`, marker
dimmed): both ends survive because both ends are what a human checks a
pasted value against, and the display is only a receipt — activation
copies the whole value, semantics announce it whole. Semantics: a
button named by the label, carrying the value — assistive tech hears
both.

### `tile_group` / `tile`
A bordered vertical group of tappable rows — the list-row form of
`button` and `link`. `tile_group` children must be `tile`s; a tile
anywhere else is rejected at `append`. The group draws `radio_group`'s
geometry — a rounded 1px `.g10` border, 44px rows, one hairline between
them — but here the border is pure grouping: no selection, no state.
An optional `description` hangs below the border in dimmed small print,
wrapped at the group width: the group-level counterpart of a tile's
`detail`, for a caption that belongs to the set of rows rather than any
one of them. Assistive tech hears it as the group's value.

Each `tile` is its own tab stop carrying `label`, an optional dimmed
`detail` line beneath it (the row grows by one small line to fit), and
either a `route` or an `on_press`: a `route` tile renders a trailing
chevron and navigates like a `link`; an `on_press` tile acts like a
`button`. Its accessible role follows the same split. Exactly one of
the two, held at `append` the way a `link`'s destinations are: setting
both, or neither, is rejected — with both the route wins and the press
is never called, and with neither the row is a tab stop that answers
nothing. Focus is the picker's pattern — a heavier stroke hugging the
row — because an outset ring would collide with the separators.

An optional `icon` (any [`IconName`](#icon)) leads the row. It is
**decorative**: the `label` stays the accessible name, and the glyph
enters no accessibility tree at all — it is a field on the tile, not a
child node, the shape a `notice`'s icon has and for the same reason
(nothing there takes focus or answers a press). A row that announced
both would say its own name twice, and the second saying would be a
guess: no glyph means one thing, which is why naming a mark is
deliberate on the standalone `icon` element (its `label`) rather than
inferred anywhere. Ink and size are the row's — `.ink`, one body line —
so a mark adds no styling surface and nothing new for the contrast gate
to prove.

**All the rows of a group carry one or none**; a mixed group is rejected
at `append` (`TileGroupMixedIcons`), beside the destination rule. The
mark takes a fixed leading band — a `lineHeight` square plus the icon
gap, the same box whatever glyph it holds — so a group's words start on
one column, exactly as a `list`'s marker band makes its items do. Give
the band to some rows and not others and the column goes ragged, with
the rows that stepped in reading as subordinate to the ones that did
not. A `list` cannot have that bug because its markers are derived; a
tile group's are authored, so the check has to exist.

Reach for tiles where a screen is a list of destinations or row-shaped
actions (settings screens, detail screens). For an exclusive choice
among options, that is `radio_group`, not a tile group.

### `list` / `list_item`
An ordered or unordered sequence of peer items. `list` children must be
`list_item`s; a `list_item` outside a list is rejected at `append`.
Options: `ordered` (default false) and `start` (the first ordinal of an
ordered list, so a list resumed after a paragraph keeps counting).

**Markers are derived, never authored.** An unordered list takes the
bullet at every depth; an ordered one numbers from `start`. There is no
field to set one, so a list can never number itself wrongly, and no
marker ever contradicts the order assistive tech announces. The marker
sits in a leading band sized for the widest marker in the list and
right-aligned inside it, so every item's words start on the same column
even when the count crosses into double digits; a wrapped line hangs
under those words, never back under the marker. The band is leading, so
it mirrors under `App.setDirection(.rtl)`.

A `list_item` holds document blocks — `text` and nested lists — not
arbitrary content. A `heading` inside one would claim an outline
position the list cannot own, and a `table` reads as a mistake at list
depth; both are rejected at `append`. Nesting is capped at three levels,
also at `append`: past that the indent has eaten the line without saying
anything the words don't. Parsed Markdown flattens deeper levels onto
the third rather than failing, the way it rebases heading levels (see
[markdown.md](markdown.md)).

Items flow tighter than free-standing blocks — they are one run of prose
broken into pieces, not separate thoughts. A list draws no edge, so the
margin advice passes through it (see `stack`). Never interactive: a list
of destinations is a `tile_group`, not a list with links in it. The
audit fails a list with no items — `append` cannot catch that, since a
list is built before its items exist. Semantics: `list` / `listitem`;
assistive tech renders positions from the structure itself, so nokre's
derived marker stays out of the announced text.

### `blockquote`
An attributed quotation: words that belong to someone other than the
surrounding prose. Marked by a 1px `.g10` rule down the leading edge —
the grouping tone `box` and `tile_group` use, not the `.g6` state
carrier, because a quote is structure and never state — spanning the
full height of what it holds, plus an indent past it.

The attribution is words *inside* the quote, not a field on it: a quote
whose source only a border implies is a quote whose source nobody
hears. Children are the document block set — `text`, lists, code
blocks, and nested quotes — with headings and tables rejected at
`append`, exactly as in a `list_item`.

The rule is an edge it draws, so unlike `list` a blockquote **consumes**
the advised margin (see `stack`): an overflowing `code_block` inside one
clips at the rule, never across it. The rule and the indent both mirror
under `App.setDirection(.rtl)`. Semantics: `blockquote`.

### `code_block`
A verbatim block: whitespace preserved, never reflowed. `content` is
mandatory (`append` rejects an empty block). It renders in the mono
family, one line per newline, with **no word wrap** — a wrapped code
line lies about where the code breaks and re-indents the one after it.

It draws no fill and no border. A frame would be decoration, and would
move the text onto a surface the contrast gate then has to re-prove; a
block that wants one goes inside a `box`. What marks it is the mono
voice and the preserved whitespace.

A block wider than its parent scrolls horizontally — framework
behavior, no API — on the overflowing `segmented` track's terms: it
declines the advised margin and bleeds to the nearest drawn edge (the
screen at the root, a box's border otherwise), so lines clip mid-glyph
at that edge rather than mid-page, while resting lines keep the content
alignment. A 2px indicator in the `scroll_region` pattern rides the
bottom, quiet at rest and emphasized while the block is engaged.
Focusable, because it scrolls: ←/→ walk it four mono advances at a time
(a code indent), and every other key falls through to the page. A
horizontal wheel or drag over it scrolls it; vertical delta belongs to
the page — a code block scrolls one axis and the other is not its
business.

**The lines never mirror.** Verbatim content is defined by its own
bytes, like a `qr` symbol's modules: source is written left-to-right and
its leading whitespace *is* its structure, so right-anchoring lines
under `App.setDirection(.rtl)` would shred the indentation and put every
line's end on screen first. Offset 0 shows the start of the lines in
both directions. The indicator does mirror, hugging the trailing edge
like every other scroll bar.

There is deliberately no horizontal twin of the
`cleanly_clipped_scroll_region` audit rule: a region's height is the
consumer's to nudge, but a code block's overflow comes from its longest
line — for parsed Markdown, bytes the app never chose — so the rule
would fire on content nobody can fix.

Semantics: `code`, announced whole as one node — a verbatim block is
read out, not navigated line by line.

### `table` / `row` / `cell`
`table` children must be `row`s; row children must be `cell`s — `append`
rejects anything else at construction. A row refuses more than 32 cells
at `append` (`error.TooManyColumns` on the cell that would open a 33rd
column) — the construction refusal every other malformed structure
gets. Column widths are per-column
intrinsic maxima; the grid is
drawn with 1px lines, and a table's rect reports its true width: one
wider than its parent overflows honestly rather than clamping silently.
Mark header rows with `.header = true`.

### `document`
Markdown source in, ordinary elements out — `append` expands it into
the elements above, so nothing after construction knows a document was
involved. The subset it parses, the rule that everything else degrades
to literal source text, and how links resolve are all
[markdown.md](markdown.md)'s — its one home.

### `segmented`
An exclusive choice among 2+ fixed options — radiogroup semantics, not
tabs. `label` (the group's accessible name), `options`, `selected`,
`on_select`. One tab stop; ←/→ move the selection and commit immediately;
tapping a segment selects it. If activating a choice should navigate,
that is the nav's job, not this element's.

Reach for segmented when the user switches between the options
repeatedly in place — views, filters, content sections. A choice made
once and gathered by a form reads better as `radio_group` or `select`.

A track wider than its parent scrolls horizontally. This is framework
behavior with no API.

- **The bleed.** Margins in nokre are advice, not walls (see `stack`),
  and an overflowing track is the element that must decline them: it
  bleeds through the surrounding padding to the nearest drawn edge —
  the screen at the root; a box's border stops it — squaring the
  track's corners where it reaches one. Resting chips keep the content
  alignment (the declined margin becomes a content inset), so the
  scroll positions are exactly the unbled track's; what changes is
  where chips clip: mid-chip at the screen edge, not mid-page — the
  static "more is there" affordance, nokre having no animation to hint
  with — scrolling through the margin band on their way there.
- **The indicator.** A 2px bar in the `scroll_region` pattern — both
  tones included, quiet at rest and emphasized while the track is
  engaged — rides the bottom of the track, within the content span. It
  stands in a strip the track grows for it rather than in the chips'
  own padding, so a scrolling track is deeper than the same track when
  it fits — deeper above the chips as well as below, or the band would
  read as chips pushed against its top edge.
- **Input.** The offset is scroll state like `scroll_region`'s —
  consumers never write it. Horizontal wheel/trackpad input over the
  track scrolls it freely without touching the selection; a selection
  change scrolls minimally to bring its chip fully into view: ←/→ walk
  it a chip at a time (committing each step, as radiogroup semantics
  say they must), and tapping a chip clipped at the edge selects it
  and reveals the next.
- **Assistive tech is unaffected** — every option is announced whether
  or not it is on screen.

There is deliberately no tablist element: nokre rebuilds subtrees
instantly, so co-existing tab panels never exist and tablist semantics
would be a lie to screen readers. Content-switching is a `segmented`
whose change action rebuilds, or it is navigation.

Visually, segmented is a track/chip pair: the track fills `.g11`
(dimmed), the selected option is an elevated `.paper` chip with `.ink`
text and a 1px `.g6` border. The border is what carries WCAG non-text
contrast (1.4.11) — paper on the track alone is ~1.3:1, but `.g6`
clears 3:1 against both the chip and the track in both appearances.
`nav` reuses the exact same pattern — see below.

## Navigation chrome

The stack these controls move — the route table, the four motions, and
the path that encodes it — is [routing.md](routing.md); what follows is
the chrome.

### `nav` / `nav_item`
App-level navigation — a set of places the app always has, declared in
one call and never placed in route builders:

```zig
try app.setNav(&.{
    .{ .route = "library", .icon = .library },
    .{ .route = "settings", .icon = .settings },
});
try app.navigate("library");

app.clearNav(); // and the bar is gone, roster and all
```

The nav survives every router rebuild and leads the focus order as the
navigation landmark. Placement and shape are both the framework's
decisions, not the consumer's, and there is no API for either: the bar
is always the bottom band of the viewport, and whatever it holds — the
row of destinations, the collapsed chip, the minimized-notices square —
is measured at its own width and centered there.

**`clearNav` is the counterpart**, and an app needs one whenever its bar
belongs to a *session* rather than to the app: a rebuild preserves the
nav deliberately, so nothing short of this takes it down. It removes the
roster and the node — every destination unreachable, because there is
nothing left to press — along with whatever was pointing at the bar (an
open section menu is the collapsed chip's own; focus does not outlive
the node that held it). Infallible and idempotent: signing out twice
costs nothing, and neither does clearing a bar that was never
installed. A later `setNav` puts one back.

**Call both at the transition, not from a builder.** `setNav` installs
the node first among the root's children wherever the call lands — the
landmark leads by position, so neither half needs a bare tree, and the
sign-in and the sign-out can each say their piece. An install that
lives inside a screen builder runs again on every rebuild of that
screen, so a rebuild landing after the clear puts the bar back up;
nokre cannot tell that reinstall from a wanted one, and moving both
halves out to the transitions is what makes the order stop mattering.

A destination is a `route` — never an action — and an `icon` (any
[`IconName`](#icon)), and nothing else. **It carries no label**: what a
screen is called is its route's [`title`](routing.md), declared once at
the route table, so the nav and the screen cannot disagree about where
you are. `setNav` accepts 2–5 destinations, and refuses a route the
table does not have or one that takes arguments — a destination is a
place the app always has, and an argument would make it one particular
screen. The glyph is **required**, not optional: a row where some
destinations have marks and others do not is worse than either uniform
answer. It leads the label at the label's own 16px, both always
visible; it is decorative to assistive tech, which hears the words.

**The bar has no ground.** There is no track, no fill, no hairline —
the nav is its items and nothing else, each on a plate of its own, with
`metrics.nav_item_gap` (8px) of page showing between them. The plates
are three levels: the page, the destinations on `.g11` (the dim track
tone every other control uses), and the current route one step above
them on `.g10`, outlined in `mid` and lettered in `.ink` — `mid` rather
than the `.g6` other chips use, because `.g6` is 2.7:1 against `.g10`,
under the 1.4.11 floor, and `mid` is the lightest tone that clears it
on both of the chip's sides. The current item is exposed as
`aria-current`; consumers never manage selected state. Activating an
item **pushes** its destination, so crossing the nav leaves a way back
to the screen you crossed from ([routing.md](routing.md)); activating
the destination already showing does nothing.

**Each destination is as wide as its own words** — its glyph, the gap
after it, the label, and `metrics.nav_item_pad_h` (20px) on either
side: the button's 16 with 4 added back, because a pill's ends curve
away from the words. Equal slots would stretch each pill to a share of
the bar and set its words adrift in a strip of identical lozenges. The
row is measured, then centered on the viewport as one group, the
notices indicator — when there is one — riding at its trailing end. The
gap between plates is drawn, not laid out: each item's *rect* is its
pill grown half a gap on either side, so the targets meet end to end
and a thumb landing between two destinations still lands on one of
them.

Plates are **pills** — the corner is half the slot's height, derived
rather than fixed, so the shape follows the slot instead of drifting
back to a rounded rectangle the next time the row grows. Nothing else
in the library is a pill: the nav is the one place a control is *only*
a target, with nothing around it to square up against. The collapsed
chip takes the same corner, and the notices indicator beside them — a
pill as tall as it is wide — is a circle.

Because nothing hides what passes behind it, every screen with bottom
chrome reserves `metrics.nav_content_gap` (24px) below its last element,
on top of the bar and the OS safe band. Scrolled to the end, a page
stands clear of the nav; mid-scroll, lines pass behind the items and
down into the safe band — that glimpse of a half-covered line is the
only thing left saying there is more below.

A slot is 52px tall, the one control in the library that grows *past*
`touch_target` rather than up to it: it is the chrome a thumb reaches
for without looking, stacked against the bottom edge where reach is
worst. Below it the bar keeps `metrics.nav_bar_pad_b` (16px) of clear
space, the same inset the page's own margin takes from the frame —
except that the OS band counts toward it, so on a phone the items sit
just above the home-indicator strip rather than 16px above a strip that
is already empty.

Where the labels fit, the nav is that row. Where they do not, it
**collapses**: the bar shows the current section alone, as the same
chip wearing that section's glyph with a chevron-up at its trailing
edge, and the other destinations move behind a picker that opens above
it — carrying their glyphs into the list, so a mark means the same
thing in both shapes.

The threshold is measured, not a breakpoint:

- **What "fits" means.** The row fits when its pills, the gaps between
  them, the bar's insets, and the indicator's reserved square fit the
  **viewport** — a longer word costs the row that word and nothing
  more, and the reserve is counted whether or not an indicator is
  showing, so the nav never changes shape because a notice arrived.
- **The viewport, not the 560px pane.** That cap is a line-length
  argument, governing the bottom chrome that holds prose — the banner,
  the notices pane, the sheet, a select's picker — and nothing in the
  bar is prose, so the row grows past the cap to exactly the width its
  items need and no further.
- **What moves the answer.** Icons cost width, so they push rosters
  into the chip sooner; a set that fits in landscape and not in
  portrait reshapes as the device turns, one too wide for a laptop
  reopens the moment the window reaches the width it asked for, and
  translations change it too — the same app can be a row in English
  and a chip in German, which is the point of measuring.

The collapsed chip does not grow at all: it is one control, and a
control that widened to hold one word would be its own kind of wrong.
It is centered like the row, with the minimized-notices square counted
into the same group and riding at its trailing end, so the two read as
one bar. A lone square with no destinations beside it is that group by
itself, centered — the one piece of chrome that does not move under
[right-to-left](localization.md) mirroring, since a centered control
has no leading edge to swap. The section card the chip opens is
centered on the same group.

The chip is a `combo_box` to assistive tech, not a link: it opens a list
and takes a choice. Its accessible name is the framework's own word for
it ("Section" in English, `App.Chrome.section` in yours) and the
current section is its *value*, so the control a screen-reader user
looks for does not rename itself every time it is used. The list is the
select's picker in behavior and a card in shape: it stands on the chip's
leading edge, as wide as its longest row rather than as wide as the
pane, with the current section marked. A select's picker is
bottom-anchored because its owner is somewhere in the page; this one's
owner is right below it, so the list is measured from the chip and
draws no title — "Sections" stays as the dialog's accessible name,
which is the only place it was ever needed. Choosing one navigates
exactly as tapping a row item does — a push — and choosing the screen
you are already on does nothing: the shape must not decide what a
choice costs.

**The chip is the one control that acts on the press.** Holding it opens
the list, so the same press can travel to a row and choose it by letting
go — the menu-bar gesture, without a menu bar. Three releases, three
outcomes: over a row it goes there, back on the chip it *leaves the menu
open* so a second press can choose by tap, and anywhere else it closes
having chosen nothing. Nothing is committed by the press itself.

That middle outcome is what makes the drag an addition rather than a
replacement: a plain click, the Tab/↑/↓/Enter path, and a screen
reader's own activation all reach every section without dragging
anything (WCAG 2.5.1), and moving off before letting go always aborts
(WCAG 2.5.2). The list opens *above* the chip rather than over it —
a menu covering its own control would put a row under the finger still
holding it, with nowhere to release that means "never mind". While the
menu is open, moving the pointer moves **focus** to the row under it:
the state ↑/↓ already move and assistive tech already announces — not
hover returning by another door, because hover is a state with no
keyboard equivalent and this is precisely the keyboard's.

### `nav_here`
**A screen that is none of the destinations names itself.** Most apps
have more routes than nav sections — a detail screen, a legal page, a
screen reached from a notice. On one of those, the roster matches
nothing, and both shapes have to answer "where am I" anyway.

They answer it with one extra entry, appended to the roster the chrome
draws from: the current route's [`title`](routing.md), wearing the shared
`file_text` mark. In the row it is a `nav_here` — a plate at the trailing
end, in the current destination's plating. Collapsed, it is what the chip
carries, so the answer does not depend on the shape. Consumers append
neither, and name neither: every line of the roster — the destinations
and this one alike — is labelled from the route table.

The mark is one glyph for every off-roster screen, not a per-route field.
A destination earns a recognizable mark by being somewhere you return to;
this is only ever *here*, and a mark of its own would make each of these
look like a destination the roster forgot.

**The marker is a label, not a destination.** It is `static_text` to
assistive tech — named "Current screen", with the title as its value,
the same split the chip makes — takes no focus, is not in the tab order,
and answers no press. A destination is a link that goes somewhere; this
one goes where you already are. In the picker, though, it *is* a row:
last, selected, so the chip's value is one of its own options rather
than a name the list does not contain. Choosing it is declined by the
rule that already declines the current destination.

**Nothing is inherited.** A screen pushed from Settings is not "in"
Settings, and the nav does not mark Settings while you are on it. nokre
never asked consumers to declare a hierarchy, so it has none to walk, and
guessing one from the stack would light a section on the strength of how
the visitor happened to arrive: two doors to the same screen would light
different sections, and a shared link opening it directly would light
none. What used to happen here was worse and simpler — the chip fell back
to the *first* destination, naming a section the visitor may never have
opened.

The extra entry is measured like any other, so the collapse threshold
needed no rule for it: a row with one more pill in it collapses at a
wider viewport, which is the threshold working, not an exception to it.
Crossing back onto a destination drops the entry and the row returns to
the roster alone.

### Back control
A pushed screen always has a way back, and the framework installs it:
whenever the route stack is deeper than one screen, the rebuild places
a back control ahead of anything the route's builder appends — a
chevron-left glyph on the sheet-close's 44px touch target, sharing the
first content element's line (a heading, by convention) with
that element indented past it. The target hangs into the page margin on
both axes so the *glyph* is what lines up: its leading edge sits on the
text column, and it centers on that first line's cap region rather than
its line box, which a heading without descenders reads low against.
Its accessible name is the framework's own word for it ("Back" in
English, `App.Chrome.back` in yours —
[localization.md](localization.md#the-frameworks-own-words)); activation
pops one screen
(`App.navigateBack`). There is nothing to configure and nothing to wire
— consumers never build their own back control, and a pushed screen
without one cannot exist. The stack root (depth 1) has nothing to go
back to and gets none — including the first section the app opens on,
until the nav is crossed; a screen that must not be returned to is a stack
problem — enter it with `replace` or `switchTo`, not `push`.

The one state it draws is **armed**: a back gesture is in progress and
past the point where releasing would commit
([routing.md](routing.md#the-back-gesture)). The chevron becomes an
**arrow** — the mark changes and nothing else does, the same move an
acknowledged `copyable` makes when its copy glyph becomes a check. A
chevron points the way navigation goes; an arrow is the going, so the
armed control states the outcome it is promising rather than looking
like a button being held. It is a latch, not an animation — one repaint
as the threshold is crossed, one as it is crossed back — and it is drawn
at all because a threshold that can only be felt is no threshold on a
device with haptics turned off.

## Layers

### `sheet`
The only modal surface, declared to the app as a *builder* — a fn the
framework calls to build the sheet, and calls again whenever it must be
built again — never appended directly to build content:

```zig
const Sheet = enum(u32) { filter = 1, saved_views }; // this controller's sheets, named

fn buildDialog(c: *Filters, app: *nokre.App, which: Sheet) !void {
    switch (which) {
        .filter => {
            const sheet = app.at(try app.presentSheet("Filter results"));
            try sheet.toggle(.{ .label = "Only unread" });
        },
        .saved_views => try c.buildSavedViews(app),
    }
}

// at the point the user asks for it:
try app.openSheetAs(Sheet.filter, buildDialog, c);
```

`openSheetAs` runs the builder at once and keeps it — as data, for as
long as the sheet is up — with the sheet's name typed and the context
bound, exactly as `Routes(State)` does for a screen. The name arrives
at the builder because the framework knows it: the builder it is
running is the one it just installed, so the cast, the tag unwrap and
the `@enumFromInt` that used to open every one of these functions say
nothing the `openSheetAs` line did not already say.

A builder with nothing to tell apart drops the last parameter and is
`fn (c: *Filters, app: *nokre.App) !void` — a sheet builder is written
like a screen builder. Nothing chooses between the two forms but the
builder's own parameter list, and Zig refuses an unused parameter, so
the form that compiles is the honest one. Name the sheet either way:
that is what lets

```zig
if (app.sheetTagAs(Sheet, c)) |which| { … }   // is *mine* up, and which?
```

answer for **this** controller. The tag namespace is flat — every
controller in an app mints into the same `u32` — so the raw
`App.openSheetTag()` cannot say whether the number it hands back is
yours, and two controllers on one screen whose enums both start at 1
read each other's sheets as their own. The context disambiguates them,
and `sheetTagAs` is that question. (`0` is how a sheet says it has no
name at all, which is why an enum with a member at 0 is refused where
you write it.)

That one declaration is the whole lifecycle:

- **State changed under the open sheet?** Call `openSheetAs` again with
  the same name and builder — the sheet is rebuilt in place, never
  stacked. (`App.refresh` does it for you when a sheet owns the
  screen.) The builder always starts from a tree with no sheet in it
  (the framework takes the open one down first), so building is always
  building from scratch, and a builder never calls `dismissSheet`
  itself.
- **The screen reloaded?** The builder runs again over the rebuilt
  screen, unasked: a sheet survives `reload` the way scroll does,
  because a reload is the same screen answering changed state. A real
  navigation is a different screen, and drops the sheet.
- **Done with it?** `App.closeSheet()` — the sheet comes down and the
  screen behind is rebuilt from the state the sheet just changed. That
  pair is one verb because it was one pair at every close handler ever
  written; the rebuild is the deliberate `reload` (closing a sheet is
  the user's own gesture) and its error is unactionable, so it is
  swallowed there rather than at your call site. A Cancel button wires
  straight to it — `.on_press = .bind(nokre.App.closeSheet, app)`, the
  App being the only state the verb takes — so a controller declares no
  close of its own. The framework's own dismissals go through the same
  verb (Esc, the scrim, the ×), which is what lets `App.refresh` leave
  the content behind a live sheet alone: whatever the user writes under
  their own dialog is on screen the moment the dialog goes.
- **The sheet closed?** However it happened — Esc, the close control, a
  tap outside, `closeSheet`, `dismissSheet`, a navigation — the builder
  is dropped (so `sheetTagAs` already answers null) and its optional
  `on_dismiss` told. That callback is for *work* a closure owes — free
  a held row, cancel a request the dialog was waiting on — not for
  recording that the sheet closed, which is now the framework's answer.
  A sheet that owes such work declares the `SheetBuilder` struct itself
  and hands it to `App.openSheet`, the untyped door underneath:
  `on_dismiss` is a second function over the same context, and binding
  fills a pair, not a struct. A builder that presents nothing has
  *declined* — its subject vanished — and is dropped quietly, with no
  `on_dismiss`: the state already knows.

Both doors answer a **declared** error set, `App.OpenSheetError`:
`OutOfMemory`, or `SheetBuildFailed` when the builder itself said no.
Two members because a caller acts on two things — a dialog that did not
open, and a process out of room; against `anyerror` every call site
wrote `catch {}` and a failed confirmation vanished with it.

Inside the builder, `presentSheet` is the verb that makes the node: it
returns the sheet to fill with content. A confirmation fills it with
[the confirm-sheet idiom](#the-confirm-sheet).

A bottom-anchored panel (top corners rounded, `.g6` outline), at most
`metrics.sheet_max_w` (560px) wide and never closer than
`metrics.sheet_min_top` (48px) to the top edge. The framework pins a
close control — a quiet Lucide square-x glyph with the accessible name "Close",
occupying the full 44px touch target — in the header corner and moves
focus to it; everything
behind the sheet is inert — unreachable by Tab, tap, and scroll — and is
dimmed by a 1px `.paper` checkerboard scrim, which keeps the pixels
inside the thirteen-gray palette. The close control, Esc and a tap on
the scrim all take the `App.closeSheet` road — one user gesture, one
outcome, screen behind rebuilt — and focus returns to the element that
had it. (`App.dismissSheet` is the same closure *without* the rebuild,
for a caller that is about to build the screen itself.) One sheet at a
time; a second `presentSheet` is rejected at the call site.

It appears in place, fully formed — no slide, no fade (WCAG 2.3.3, and
nokre has no animation to begin with).

### `notice`
A persistent notice, raised through the app:

```zig
app.notify(.{
    .title = "Sync failed",
    .description = "Changes are kept locally.",
    .route = "sync",
    .icon = .cloud_off,
    .important = true,
});
```

`notify` cannot fail: the pending list is a bounded ring whose slots
`App.init` reserves whole, so raising a notice is a copy, not an
allocation — there was never anything an app could do with the old
error but swallow it. The bound is generous (32 pending, and titles are
identity, so that is 32 *distinct* notices); past it the ring evicts
drop-oldest, quiet notices first — the banner's important front is the
last thing to go.

A notice is a title, an optional description, the route its open
control deep-links to (optional, and usually absent — a notice that
reports without sending anyone anywhere grows no open control at all),
an optional leading icon (decorative — the title stays the accessible
name), and an importance. The importance is
behavioral, not visual: an **important** notice interrupts as the
banner and re-surfaces minimized ones; a **quiet** one (the default)
joins the pending list behind the indicator without taking the screen.
Quiet is the default because interrupting is the thing a notice should
have to ask for. Pending notices surface in exactly one of three
states, all living in the bottom pane:

- **Banner** — the front notice as a row anchored to the viewport
  bottom, hiding the nav while it shows. It reserves its own band, so it
  can never obscure content. Leading control: *expand* (opens the
  notices pane) when more than one notice is pending; *open*
  (deep-links to the notice's route, minimizing first) when it is the
  only one *and* it carries a route; nothing at all when it is the only
  one and routeless, and the words take the room. Trailing controls:
  *minimize* and *dismiss*.
- **Notices pane** — a modal, sheet-like panel listing every pending
  notice with a per-row dismiss control (and an open control on the
  rows that carry a route), plus a dismiss-all control
  (the trash glyph) beside the minimize control in its header. Minimize
  keeps the trailing corner — the slot where a modal closes — so the
  reflex press parks the notices rather than destroying them.
  Important notices lead the list, and when both kinds are pending each
  group sits under a small label ("Important" / "Other") — plain text,
  not headings, so two words of chrome never enter a screen reader's
  heading navigation ahead of the page.
  Esc or a tap on the scrim minimizes it. It keeps the sheet's height cap
  (`metrics.sheet_min_top` clear of the top edge), and the rows sit in a
  scroll region inside it, so a list longer than the cap allows — which a
  landscape phone reaches after very few notices — scrolls by wheel,
  drag, or keyboard rather than being clipped at the pane's edge. The
  header stays put, dismiss-all with it: the control that empties the
  list should not scroll away as the list grows.
- **Minimized** — an indicator glyph that reopens the pane. It belongs to
  the bar rather than to the pane: it rides at the trailing end of
  whatever the bar is centering — the row of destinations, or the
  collapsed chip — and centers alone when there is no nav.

All controls are Lucide glyphs on 44px targets with accessible names.
Notices never steal focus and **never time out** (WCAG 2.2.1 — there is
no auto-dismiss API to misuse). Duplicates (by title) are dropped; a new
important notice re-surfaces minimized ones as the banner, and the
banner is always an important notice while any is pending — dismissing
the last important one collapses to the indicator rather than promoting
a quiet notice that never asked to interrupt. An open sheet takes the
bottom pane, parking notices behind the indicator until it closes.
Notices survive navigation. Screen readers announce the banner politely
as a status live region.

## Actions

Actions are context + function-pointer pairs (`Action`, `ToggleAction`,
`ChangeAction`, `SelectAction`) — nokre never allocates closures.
`bind` builds the pair from a typed method, so the handler is written
against your state type and the `?*anyopaque` plumbing never appears in
app code:

```zig
.on_press = .bind(State.save, state)

// in State:
pub fn save(self: *State) void { ... }
```

The payload-carrying actions hand their payload to the bound method —
`ToggleAction` a `bool`, `ChangeAction` the `[]const u8` value,
`SelectAction` the selected `usize`:

```zig
.on_toggle = .bind(State.setNotify, state)   // fn (self: *State, checked: bool)
.on_change = .bind(State.editName, state)    // fn (self: *State, value: []const u8)
.on_select = .bind(State.chooseScheme, state) // fn (self: *State, selected: usize)
```

### A row's action carries the row

Two forms do that, and choosing between them is the one decision this
part of the API asks you to make: **where the row was** or **which row
it is**.

```zig
.on_press = .bindAt(State.accept, state, i)          // fn (self, index: usize)
.on_press = .bindKey(State.remove, state, row.id.get()) // fn (self, key: []const u8)
```

Both put the datum on the element, so it is exactly as fresh as the
tree it rides in — rebuilt with the screen, never baked into code.
(`ToggleAction` has the indexed form only, and adds the index *before*
the checked state: `fn (self, index, checked)`. It has no keyed twin
until a real toggle row needs one; see `element.zig`.) An action names
one function: setting more than one of `call`, `call_indexed` and
`call_keyed` is refused at `append`.

Neither form is a claim about the present. A press is delivered against
the tree the user *saw*, and the list that tree was built from may have
moved by the time the handler runs — a reply landed, a row was removed,
the screen was not rebuilt because the user was holding it. What
differs is what a stale one can do:

- **`bindAt` hands back a position, and a position is always occupied
  by somebody.** A stale index that is still in range names a live row
  — the wrong one — so the contract is one sentence: **the receiver
  bounds-checks**, and a check that passes is not proof the row is the
  one that was pressed.
- **`bindKey` hands back an identity, and an identity that is gone
  matches nothing.** There is no index to index with, so the handler's
  only move is to look the key up; the lookup finds the row the user
  pressed or it finds nothing, and nothing is a no-op. There is no
  wrong row to land on.

```zig
pub fn remove(self: *State, key: []const u8) void {
    const row = self.findByKey(key) orelse return; // gone: decline
    ...
}
```

nokre does neither check for you — it knows the tree, not your data —
and it never interprets a key: whatever bytes you bind come back
verbatim. It does **copy** them at append, like every other string an
element carries, and that copy is what makes the guarantee hold: the
natural key is a field of the row it names, so a borrowed one would
still be pointing into that row when a reply refills the list, at which
moment the pressed row's key has quietly become its successor's.

Use `bindAt` where the row *is* the position — a fixed comptime list of
settings, a table of steps, options that cannot reorder. Use `bindKey`
where the rows came from a reply. An empty key is legal and means the
row had no identity to give; it matches nothing, so it declines.

### Binding callbacks nokre never sees

The four `bind` methods are one generator with four faces, and it is
exported: `nokre.bindAs(CallbackT, handler, state)` fills **any**
`{ ctx, call }` pair the same way.

```zig
port.loadRows(.{ .id = id }, nokre.bindAs(Port.RowsCallback, Screen.onRows, screen));

// in Screen — no cast, no null unwrap, no forwarding shim:
fn onRows(self: *Screen, result: Port.RowsResult) void { ... }
```

`CallbackT` is duck-typed at comptime: a struct with `ctx: ?*anyopaque`
and a `call` that is a (possibly optional) pointer to a function taking
`?*anyopaque` first. Everything past the context is forwarded by
position and by value — whatever it is, however many — and the return
value comes back the same way, so a callback that answers a `bool` or a
struct binds like one that answers nothing. Fields beside the pair keep
their declared defaults; a pair with a field that has none is not a pair,
and says so.

The point is what `CallbackT` may be. **A callback type does not have to
come from nokre**: a domain package that models its ports as
`{ ctx, call }` pairs stays framework-free, and the app — which does
import nokre — binds handlers into them. That asymmetry is why this is a
free function over a type rather than a method on one.

A handler whose signature does not fit fails *at the bind*, with the
signature it should have had and the one it has:

```
bind.zig: bindAs: this handler does not fit `Port.RowsCallback.call`.
  expected: fn (*app.Screen, port.RowsResult) void
  found:    fn (*app.Screen, u32) void
```

What `bindAs` is not is a way to reach a callback field riding on a
larger struct — an http `Request` carrying a URL and a tag, a
`SheetBuilder` carrying its tag and its `on_dismiss`. Binding fills a
whole value; a struct with more in it is built by the code that has the
rest, which for a sheet is `App.openSheetAs` (it has the tag).

## Proposing an element

The set is closed, but not frozen: a new element is argued in on
semantics — one sentence stating what it *means*, or it doesn't go in —
and lands via the maintainer checklist in
[internals/contributing.md](internals/contributing.md).
