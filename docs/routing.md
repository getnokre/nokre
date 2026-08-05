# Routing

Screens are **named builder functions** and navigation is a **stack** of
them. The whole router is that: a table of `RouteDef`, a stack of entries
pointing into it, and a rebuild on every change. There are no path
patterns, no wildcards, and no transitions.

```zig
const routes = [_]h.RouteDef{
    .{ .name = "notes", .title = .{ .fixed = "Notes" }, .build = buildNotes },
    .{ .name = "note", .title = .{ .fixed = "Note" }, .args = 1, .build = buildNote },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildSettings },
};

var app = try h.App.init(gpa, .{ .viewport = ..., .routes = &routes, .ctx = &state });
try app.navigate("notes");
```

**Every route declares a `title`.** The field has no default, so a screen
that cannot be named is a compile error at the table rather than a blank
chip at run time. It is what chrome calls the screen: every line of the nav's roster is
labelled from it — the declared destinations, and the screen itself when
it is none of them ([elements.md](elements.md#navigation-chrome)). A nav
destination is therefore a route and a glyph, with no label of its own;
one screen has one name, wherever it is being named from.

The title is *declared*, and nothing derives it. Not from `name`, which
is an identifier and reads like one (`sign_in`). Not from the screen's
first heading, which is **content**: a builder may lead with anything,
may localize it, may not have a heading at all, and nothing obliges the
one it has to still be there after the next edit. A heading is written
for the page; a title is declared for the chrome. Neither is the other's
source, and a screen is free to show both — the way a nav item's title
already sits beside that section's own heading.

It names the *route*, not the screen: `note~42` and `note~43` are both
"Note". A `.of_locale` title is a function of the app's chosen locale
and of nothing else — never of the reference — so a per-instance title
stays refused: that would be a callback asking the router to find out
per screen what to draw.

A title is the words themselves or the words as a function of the
app's **chosen locale**: `.{ .fixed = "Notes" }` for an app in one
language, `.{ .of_locale = notesTitle }` for one in several. The
chosen locale is app state — `Options.locale` at boot, `App.setLocale`
after, "" until chosen, `App.locale()` to read — and choosing it
re-says every `.of_locale` title where it stands: one screen keeps one
name in every language, and the nav's row, chip and marker change
together. There is no second table to hand over.
[localization.md](localization.md#the-chrome-nokre-writes) has the
wiring, along with `App.Chrome` — the framework's own words, which are
nokre's rather than any route's.

Four motions move the stack, and every one of them rebuilds the current
screen's subtree from scratch:

| | |
|---|---|
| `App.navigate(ref)` / `router.push` | a screen deeper — gains a Back control |
| `App.navigateBack()` / `router.pop` | up one; a no-op at the root |
| `router.replace(app, ref)` | the same depth, a different screen |
| `router.switchTo(app, ref)` | arriving with no trail: **the stack resets to depth 1** |
| `App.reload()` / `router.reload` | this screen, rebuilt from its own reference — the *deliberate* answer to changed state |
| `App.refresh(opts)` | the *polite* one: the open sheet rebuilt if one owns the screen, else a reload unless the user holds something a rebuild would take |

**Going back returns the screen, not just its name.** Each entry
remembers where its screen was scrolled to — the window and every
`scroll_region` in it — and `pop` puts that back before the first frame
of the rebuilt screen, so a list you were halfway down comes back halfway
down. `reload` does the same, since a screen redrawing one row should not
also move the viewport. `replace` and `switchTo` do not: neither is the
screen you left. The rebuild itself is unchanged — still from scratch,
still instant — and a screen that comes back a different shape restores
what lines up and clamps the rest; positions are matched by order, not by
identity. Focus is not restored by `pop`: the element it named is gone,
and guessing would move a screen reader's cursor somewhere nobody asked
for.

**An open sheet survives `reload` too, by the same argument.** A sheet
is declared to the app as a builder (`App.openSheet` —
docs/elements.md, "sheet"), and after a reload rebuilds the screen the
framework runs that builder again, so a dialog is never the reason
state cannot be answered. The other four motions drop it — each is a
different screen, and a sheet belongs to the state of the one that
opened it — and tell the builder's `on_dismiss` so.

**`reload` alone carries focus, and by name, not position.** The node
focus held goes with the rebuilt content, and an ordinal would land a
screen reader's cursor on whatever took that place — but the
accessible name survives, and the audit forbids two interactive
elements in one layer from sharing one
([accessibility.md](accessibility.md)), so within the active layer —
the rebuilt screen, or the re-presented sheet — the same name is the
same control. A control that kept its very node keeps focus outright
(chrome survives rebuilds). When nothing answers to the carried name,
focus starts over rather than guess, and a link inside prose starts
over always: its paragraph has no name of its own, and a span index is
exactly the ordinal the restore refuses to trust.

What no carry can save is an edit in flight: caret, composition, and
the unwritten value die with the field's node, and the on-screen
keyboard follows them down. `app.reloadSafe()` is that question asked
before the fact — false while an overlay owns the screen (a sheet, a
picker, the notices pane) or while an editable holds focus. `reload`
itself never asks it: a deliberate gesture — retry, pull-to-refresh, a
locale change — must be honored even mid-edit. The check belongs to
the rebuilds nobody asked for, and those say **`App.refresh`**, which
composes it once:

```zig
fn onSaved(state: *State, result: Result) void {
    state.apply(result);                      // the state is written either way
    state.app.refresh(.{ .route = "note" });  // the screen follows, politely
}
```

`refresh` is "this state changed; update whatever is showing,
politely." If an open sheet owns the screen its builder runs again — a
sheet is a tree node a reload would take with it, so the state change
re-presents it instead, and the content behind it waits for whatever
closes the sheet. Otherwise it reloads, unless `reloadSafe` says the
user holds something a rebuild would take — then it declines, and
declining is fine by construction: the state is already written, and
the next navigation or gesture rebuilds from it. `Refresh.route` scopes
the whole thing to a screen: a reply that lands after the user has
walked away leaves the screen it no longer owns alone (`""`, the
default, means whatever is on top; the comparison is by route *name*,
so `"note"` covers `note~42`). Called from inside a builder — a load
the builder issued, answered synchronously — it declines quietly too:
the builder reads the answered state the line after. Every consumer
used to compose all of this by hand, per controller; the survey found
22 copies.

`reload` from inside a route builder is different: the deliberate verb
has no polite decline, so tearing down the half-built screen to run its
builder again — which would duplicate the screen — is **refused and
recorded** (`reload_in_build` below), and the audit fails the first
test that trips it.

### The back gesture

On iOS a drag inward from the leading screen edge also goes back — the
left edge, or the right under RTL chrome, mirrored like the Back
chevron. It is the framework's, not the app's: nothing to enable,
nothing to configure, and it reaches nothing the Back control does not.

**Nothing slides.** The finger moves and the screen does not, because a
half-transitioned screen is an intermediate state nokre cannot describe
to assistive tech or render byte-exactly, and finishing the slide after
the finger lifts would need frames nobody asked for. Instead there is a
*threshold*, a quarter of the viewport's width and never less than
64px: crossing it fires a haptic knock
and turns the Back control's chevron into an arrow, crossing back knocks
again and gives it up, and releasing past it pops the stack exactly as
tapping Back does. Position decides and only position — a fast flick short of the
threshold is not a back, because velocity needs a clock. The gesture is
inert at depth 1 and under an open sheet or picker, and it never arms in
either case: a knock that promises a navigation nothing will perform is
worse than no feedback at all. The design record is
[internals/haptics.md](internals/haptics.md).

Android has the same command by a different road: gesture navigation
owns both screen edges there, so the system's own back — predictive
animation, haptics and all — arrives already decided and nokre routes
it, popping one screen or finishing the activity at the root. On the web
the browser's Back does the same through the address bar. The other
three shells have no equivalent gesture, and their Back control is the
whole story.

**Crossing the nav is a push**, like every other move: the destination
goes on top of the screen you were looking at, which therefore still has
a way back to it — the framework's Back control, the iOS edge drag, the
Android system back, the browser's Back. Reaching a section by mistake
costs one press to undo, and reaching one deliberately does not silently
discard where you were. Activating the destination you are already
standing on is the one no-op: a screen stacked on itself would grow a
Back control leading to a screen indistinguishable from the one showing.

There is still no *per-section* history — one stack, not one per
destination, and coming back to a section arrives at its root rather
than at whatever you last had open there. A bottom nav is a set of
places and the stack is the order you walked them in; nokre keeps one
of those, not both. That is also why the nav can collapse to the current
section without losing anything ([elements.md](elements.md#navigation-chrome)):
a set has no order to show, so showing one member and keeping the rest a
press away costs nothing. The nav chrome and the framework-installed
Back control are [elements.md](elements.md#navigation-chrome)'s;
[getting-started.md](getting-started.md) Part 3 walks the whole thing.

The stack itself is memory and stays memory: `router.current()` names the
screen on top, `router.currentRef()` gives its full reference, and
`router.depth()` counts the stack.

## References

What a `link`, a route-carrying `tile`, a `nav_item`, a `notice`, a
Markdown `[label](destination)` span and `App.navigate` all carry is a
**reference**: a route name, optionally followed by positional arguments.

```
notes              a screen
note~42            the same route, a specific note
sum~10~5           two arguments, in order
```

Every one of them resolves through the same table, so a reference that
does not name a route is refused the same way wherever it appears.
Resolution is the only place that parses — the Markdown parser, the
elements, and the input layer all pass the reference through untouched.

**The arguments belong to the stack entry**, not to app state. That is
the point of having them: push `note~41`, push `note~42`, pop, and the
screen you land on still knows it is note 41. With the selection in app
state the depth is remembered and the identity is not.

Read them back inside the builder:

```zig
fn buildNote(_: ?*anyopaque, app: *h.App) !void {
    const id = app.routeArg(0) orelse return;   // "42"
    // ...
}
```

`routeArg` borrows from the entry, and the tree copies everything it is
given, so a builder may format a reference into a stack buffer and append
it — the same rule labels already follow.

### Building a reference

Writing one is `routeArg`'s mirror — `App.routeRef` (`router.writeRef`
underneath) formats a name and its arguments into a buffer you hand it,
validated against the same table `navigate` resolves through:

```zig
var buf: [h.router.max_ref_bytes]u8 = undefined;
const ref = try app.routeRef(&buf, "note", &.{id});   // "note~42"
try list.link(.{ .label = title, .route = ref });
```

Everything resolution would refuse is refused here, at the site that
*builds* the reference rather than the one that later opens it: an
unknown name, the wrong arity, an argument outside the charset — a `~`
inside an argument included, so content can never read as a second
separator — or a result past `max_ref_bytes`. A failed call writes
nothing. `[h.router.max_ref_bytes]u8` always fits, so there is no
buffer size to guess and no separator literal to hold; a reference this
returns is one `navigate` will take.

### Arity is declared

`RouteDef.args` says how many arguments a screen takes, defaulting to
none. A reference carrying the wrong number is refused rather than
building a screen with nothing to show, so `#note` and `#note~1~2` both
fail where a missing id would otherwise render as a blank.

### The separator is `~`

Not `/`. A path puts the way you got here into the name of the screen. A
stack in the URL does the same, just more of it. Neither is kept, and
both leave the same thing behind: one screen, one reference. That is the
**no paths** refusal ([introduction.md](introduction.md)), and `~`
carries none of the conventions a slash does — nothing about a reference
is truncatable, so `note~42` cut back to `note` is a missing argument
rather than a parent.

It is also one of the few characters `encodeURIComponent` leaves alone
(the whole set is `. ! ~ * ' ( ) - _` and alphanumerics), so a reference
and its rendering in an address bar are the same bytes, always.

### Names are flat

Names are flat and unique, so two sections cannot both have a
`settings`. Give them different names. `settings.billing` is a name, and
the router never reads the dot as a level.

### Arguments are identifiers, not payloads

Names and arguments may contain `[a-zA-Z0-9_.-]`. `.` and `-` are in
deliberately — that is why they are not the separator — so versions,
UUIDs and slugs are arguments with no escaping:
`ticket~1.2.3-rc1` is fine.

Everything else is out. An argument says *which* thing a screen is
about; free text and structure are a URL's business, which is
`deep_link`'s ([services.md](services.md)).

**A reference must stay safe to open.** Arguments identify, they never
command: `#sum~10~5` is fine, `#delete~42` is not. Anything in an address
bar gets opened by link previewers, history restores, and people pasting,
none of which intended to act.

### Errors, and refusals

The table is validated once, in `App.init`, rather than leaving a bad
name to surface as a mystery at first navigation:

| | |
|---|---|
| `error.EmptyRouteName` | a route with no name |
| `error.RouteNameCharset` | a name outside `[a-zA-Z0-9_.-]` — including one carrying a `~`, which would make every reference to it ambiguous |
| `error.DuplicateRouteName` | two routes sharing a name — otherwise every reference would quietly resolve to the first |

A reference is validated at resolution — but a bad one is a **refusal,
not an error**. `navigate`, `switchTo`, `router.replace` — and
`reload`, for the one thing it can refuse — leave the stack exactly as
it was, return normally, and record what they refused in
`router.refused`: the reference (bounded to `max_ref_bytes`) and a
reason —

| | |
|---|---|
| `unknown_route` | no route by that name |
| `arg_count` | not the number of arguments the route declares |
| `arg_charset` | an argument outside the charset, or empty (a trailing `~` is a *missing* argument, not an empty one) |
| `ref_too_long` | past 256 bytes — a reference can arrive from outside the app, and one enormous argument would pass the arity check |
| `reload_in_build` | a `reload` issued while the screen's builder was already running — honoring it would rebuild the screen over its own half-built output, duplicating it. The record carries the reference of the screen being built. (`refresh` never trips this: the polite verb declines the same call quietly.) |

Every one of these is a programmer error, and nothing at a navigation
call site can do about one but drop it — so no error asks to be
handled. What is left in the verbs' error sets is the machine failing:
allocation, and your own screen builder's errors. The record is how the
mistake still surfaces: the test harness checks it after every action
(and audits every route a `link`, `tile`, span or `notice` carries —
the `unresolvable_route` rule), so a mistyped reference fails the first
test that shows or presses it, with the reference in the diagnostic.

The same taxonomy *is* an error set on `App.routeRef`, because there
the caller is the site building the reference and can act on it.

**Bytes from outside the program are different.** An address bar, a
deep-link fragment, a notification payload — a stranger's typo there is
not a programmer error, and it must not read as one. Ask first:

```zig
if (app.router.vet(route) == null) try app.navigate(route);
```

`vet` answers what a verb would refuse — same checks, same reasons —
and records nothing. The web shell already vets the fragment at its own
door, which is what keeps the bar restored and the app unmoved.

## The address bar

On the **web**, the URL fragment names the screen the app is on, in both
directions and without configuration:

- navigating writes it — `#notes`, `#note~42`;
- typing one, opening a shared link, or pressing the browser's Back and
  Forward puts the app on it;
- a fragment the router cannot honor — an unknown name, the wrong number
  of arguments, a byte an argument may not contain — leaves the app where
  it is and puts the bar back, so the bar never describes a screen nobody
  is on.

The fragment is a reference, unencoded: every byte a name or argument may
contain is one `encodeURIComponent` leaves alone, so what the app writes
is what a user copies and what comes back.

**The fragment is the current screen, never the stack.** A reference is
an identity for a screen: one screen, one URL, whoever is looking and
however they got there. Encoding the stack would break exactly that —
`note~42` would be reachable as `notes/note~42`, `settings/note~42`, or
`note~42`, three strings for one screen, none of them a stable link. The
trail that led to a screen is the app's own memory, and the browser
already keeps a history of its own; nokre does not keep a second one in
the URL.

So arriving by link **resets the stack** to that one screen — `switchTo`,
not `push`. A visitor has nothing to go back to inside the app, and the
framework's Back control is correctly absent; the browser's Back takes
them where they actually came from.

The corollary, stated plainly: **depth does not survive the URL.**
Reloading two screens deep comes back one screen deep, without the Back
control, and so does walking browser Back and then Forward — Forward is
an arrival like any other. That is the trade for a URL that means one
thing, and it is the same trade every web app makes.

Browser Back and the in-app Back control are otherwise the same motion,
deliberately. A pushed screen adds a history entry and nothing else does
— a section switch and a `replace` are the router saying *this is the
same place*, so they replace the entry rather than stacking one. In-app
Back rewinds only history this app added: opening a link straight into a
pushed screen and pressing Back moves up a screen instead of leaving the
site.

On **every other platform** nothing is rendered, because a native window
has no address bar — the router announces each change either way, and
those shells simply do not listen. Nothing to enable, nothing to turn
off, no platform branching in app code. The wiring is
[internals/platform-shells.md](internals/platform-shells.md).

**Not to be confused with `deep_link`** ([services.md](services.md)),
which delivers an inbound URL it deliberately does not interpret and
leaves routing to the app. The two answer different questions — *a URL
arrived* versus *which screen is showing*. A reference reaches as far as
identifiers reach; a link carrying free text, a query, a path, or a
claimed domain is a real URL, and that is `deep_link`'s. An app that both
links `deep_link` and routes on the fragment itself will see the fragment
twice, once through its handler and once through the mirror; route on one
or the other.
