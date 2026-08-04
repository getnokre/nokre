# HANDOFF — the second ergonomics round (2026-08-04, evening)

Status: **in execution** (started 2026-08-05). Landed so far: A1
(revision 6) — bind/bindAt on all four action types, `nokre.ctx`
deleted, both apps + site + docs migrated; A2 (revision 7) —
`App.refresh` + the `reload_in_build` refusal, 39 hand policies and
every `issuing` guard deleted (refresh declines quietly in-build; bare
`reload` is the recorded refusal); A3 (revision 8) — `tag: u64` on
`RequestOptions`, echoed structurally by the delivery slot below all
transports; consumer client-array collapse examined and correctly
declined (every slot is a distinct named adapter, not correlation
plumbing — the doctrine change in PORTING.md is the consumer payoff);
A6 scope decided by owner
2026-08-04: minimal as written. Everything else below is unexecuted. The first
handoff (deleted at `b3518a2`) was executed whole; this one comes from a
full vocabulary-and-ergonomics review of nokre against its three real
consumers — the rokovski user app (44.6k lines), the rokovski org app
(18.9k), and the site generator (2.7k) — after that execution. Every
item cites consumer evidence; counts are grep-verified against the trees
as of nokre `b3518a2`, rokovski `eff2608d`, site `f7b7d7b`.

Execution protocol stays the standing one: **one item per pass, owner
review between, never chain.** Contract changes bump `revision` and move
all three pins in the same pass.

The single most important fact the survey produced: the consumers
contain **zero TODO/FIXME/HACK comments about nokre** — every gap is
instead carried as disciplined prose and duplicated code. The prose is
where the framework's costs went to live. The counts below are those
costs made visible.

---

## Part A — ranked redesigns

### A1. Typed action binding — retire `?*anyopaque` from consumer code

The single largest consumer cost, and the cheapest to remove.

Evidence: **924 sites across the two apps** — 393 (user) + 159 (org)
hand-written trampoline functions of the shape

```zig
fn onVerify(ctx: ?*anyopaque) void {
    cast(ctx).entry.sendCreateOtp();
}
```

plus 70 local `fn cast(ctx: ?*anyopaque) *T` definitions and 272 raw
`@ptrCast(@alignCast(ctx.?))`. Roughly 1,700 lines that carry no
decision. Meanwhile `nokre.ctx(T, ptr)` — added for exactly this — has
**zero adoptions** in either app: shipping the cast did not remove the
trampoline, which is the actual ritual. PORTING.md even teaches the
trampoline as house style ("every handler starts with
`const state: *State = @ptrCast(...)`").

Change: comptime constructors on the action types that synthesize the
trampoline from a typed function.

```zig
// element.zig — beside Action
pub fn bind(comptime f: anytype, state: anytype) Action {
    const T = @typeInfo(@TypeOf(state)).pointer.child;
    return .{ .ctx = state, .call = struct {
        fn call(c: ?*anyopaque) void {
            f(@as(*T, @ptrCast(@alignCast(c.?))));
        }
    }.call };
}
// and bindAt(f, state, index) for call_indexed,
// ToggleAction.bind / ChangeAction.bind / SelectAction.bind alike.
```

Before / after at a call site:

```zig
// before — three declarations away from the element
fn onRetry(ctx: ?*anyopaque) void { cast(ctx).retry(); }
...
.on_press = .{ .ctx = state, .call = onRetry },

// after — one expression, statically typed
.on_press = .bind(State.retry, state),
```

Compile cost is one tiny generated fn per bound method — the same fns
the consumers write by hand today, minus the source lines. `nokre.ctx`
becomes unnecessary and should be deleted in the same pass rather than
kept as a second way.

Deletes: ~1,700 consumer lines; the `?*anyopaque` boundary disappears
from app code entirely (it survives inside nokre, where it belongs).

### A2. One refresh verb — retire the hand-composed reload policy

Evidence: the "polite reload" is re-derived in **22 functions** across
the apps, all the same five lines:

```zig
fn reload(self: *Settings) void {
    if (self.issuing) return;
    if (self.sheet != .none) return self.present();
    if (!self.app.reloadSafe()) return;
    self.app.reload() catch {};
}
```

plus route-scoped variants (`reloadRoute`, `reloadIfCurrent`,
`reloadIfEither`, …) and **142 occurrences of an `issuing: bool`
re-entrancy guard across 20+ controllers**, protecting against the one
hazard nokre permits silently: `reload()` called from inside a route
builder duplicates the screen being built.

Change, two halves:

1. **`reload()` during a build is a recorded refusal.** The router
   knows it is inside `rebuild`; a re-entrant reload becomes a no-op
   recorded like `Router.refused`, and the audit surfaces it. Every
   `issuing` guard exists to say this; the framework can say it once.
2. **`App.refresh(opts)` — the composed verb.** "This state changed;
   update whatever is showing, politely":

```zig
pub const Refresh = struct {
    /// Only refresh if this route is on top; "" means any.
    route: []const u8 = "",
};
/// Re-runs the open sheet's builder if one owns the screen, else
/// reloads unless an editable holds focus. The deliberate-gesture
/// path stays `reload()`, which never asks.
pub fn refresh(self: *App, opts: Refresh) void { ... }
```

Before / after:

```zig
// before: 5–8 lines × 22 copies, each a policy the author re-derived
// after:
self.app.refresh(.{ .route = "library" });
```

Deletes: 22 functions (~160 lines), 142 guard mentions and their
fields, and closes the duplicated-screen bug class structurally.

### A3. Request identity on the http callback

Evidence: `RequestOptions.on_result` is `fn (ctx, result)` — the reply
does not say which request it answers. Consequences in the user app:
**81 pre-allocated single-flight `ApiClient` instances**
(`clients: [14]ApiClient` on one controller), six `*_inflight`
staleness-correlation fields, and a 134-callback fan-out where each
callback's only identity is its `ctx`. The org app mirrors it at 5
slots per controller. PORTING.md codifies "one transport per concurrent
call" as doctrine — a doctrine transcribing this gap.

Change: hand the callback an identity.

```zig
// http.zig — before
on_result: *const fn (ctx: ?*anyopaque, result: Result) void,
// after
/// Echoed to `on_result` untouched. The caller's correlation tag:
/// a generation, an index, a packed pair — the receiver's business.
tag: u64 = 0,
on_result: *const fn (ctx: ?*anyopaque, tag: u64, result: Result) void,
```

Migration is mechanical (every consumer callback gains `_: u64`), and
then the apps can collapse client arrays and staleness fields at their
own pace. Mirror the same tag through the harness (`fulfillHttpPath`
already addresses by path; the journal keeps the tag).

### A4. A tree builder — retire the double-brace ritual

Evidence: **1,240 append sites** across the three consumers
(user 823 + 113, org 276 + 24, site 64 + 23). In the user app the
append statements are 39.6% of all screen-source bytes, averaging 151
characters per element. The site wrote a 16-helper facade
(`heading`/`text`/`plain`/`strong`/`mono`/`tiles`/`tableOf`/…) whose
only content is deleting the wrapper syntax. Parent threading is manual
everywhere (`fn appendSection(state, app, root, ...)`).

Change: a closed builder cursor, one method per element, additive — the
raw `Tree` API stays the one underneath.

```zig
pub const Cursor = struct {
    tree: *Tree,
    at: NodeId,
    pub fn text(c: Cursor, content: []const u8) !void { ... }
    pub fn heading(c: Cursor, level: HeadingLevel, content: []const u8) !void { ... }
    pub fn button(c: Cursor, b: element.Button) !void { ... }
    /// Containers hand back the child cursor.
    pub fn stack(c: Cursor, s: element.Stack) !Cursor { ... }
    pub fn box(c: Cursor, b: element.Box) !Cursor { ... }
    ...
};
pub fn root(app: *App) Cursor { ... }
```

Before / after:

```zig
// before
const actions = try app.tree.appendId(box, .{ .stack = .{ .axis = .horizontal } });
try app.tree.append(actions, .{ .button = .{
    .label = c.tr(.retry),
    .form = .{ .secondary = null },
    .on_press = .{ .ctx = state, .call = onRetry },
} });

// after
const actions = try b.stack(.{ .axis = .horizontal });
try actions.button(.{ .label = c.tr(.retry), .form = .{ .secondary = null },
                      .on_press = .bind(State.retry, state) });
```

The method set is closed exactly as the element set is: a new element
adds its method in the same pass (the contributing checklist grows one
line). ~43 short methods, mechanical to write, exhaustively derivable
from `Role`.

### A5. Format-into-the-tree — retire the guessed scratch buffers

Evidence: **149 fixed scratch buffers** in the user app alone (106 in
screens), sizes hand-guessed from `[48]u8` to `[512]u8`, feeding 89
`L.fmt` + 41 `bufPrint` calls whose results the tree then copies
*again* into its arena. Seven repetitions of the same `"{s} — {s}"`
disambiguation pattern. The org app: 21 `bufPrint` + 41 `L.fmt` + 16
screen-local buffers.

Change: let the label be formatted where it will live — the tree's
arena, which already owns every string.

```zig
/// Formats into the tree arena; the slice is valid for the tree's
/// lifetime like every other stored string. The double copy and the
/// guessed cap both disappear.
pub fn fmt(self: *Tree, comptime f: []const u8, args: anytype) ![]const u8
```

Before / after:

```zig
// before
var label_buf: [96]u8 = undefined;
.label = try std.fmt.bufPrint(&label_buf, "{s} — {s}", .{ tr(.delete), code }),
// after
.label = try app.tree.fmt("{s} — {s}", .{ tr(.delete), code }),
```

This is one of the few items where ergonomics and performance point the
same way: one copy instead of two, no truncation-by-guess failure mode.
(An `l10n` twin — `L.fmtIn(tree, locale, key, args)` — rides along.)

### A6. The load-phase primitive

Evidence: both apps hand-rolled the same `Load = enum { idle, loading,
ready, failed }`, **51 phase switches** rendering the same
loading/failed/retry scaffold, 30 `ensure*` load-on-first-render
functions, and 11 fixed-capacity list structs with `phase + len + rows +
items() + push()`. This is the largest remaining conceptual gap, and
the most doctrine-sensitive: nokre deliberately owns no app data.

Proposal, deliberately minimal — a pure library type plus one screen
idiom, no framework state:

```zig
/// nokre.Load — the four-phase async value vocabulary, so two apps
/// stop declaring it. Pure data; nokre never reads it.
pub const Load = enum { idle, loading, ready, failed };
```

plus a documented builder idiom (with A4, the loading/failed/retry
scaffold becomes a 3-line helper on the cursor, e.g.
`b.loadGate(phase, .{ .loading = tr(.loading), .failed = tr(.eFailed), .retry = ... })`
returning whether to continue). Owner call: whether to go further
(a generation-stamped `Remote(T)` with staleness) or stop at the shared
vocabulary. **Decide at session start.**

### A7. l10n binding, runtime keys, and the chrome catalog keys

Evidence: **46 identical `tr`/`locale` wrapper definitions** across the
apps (1,341 `.tr(.` call sites) all re-deriving
`L.tr(L.resolve(self.app.locale()), key)`; a 12-arm month-name switch
duplicated in both apps because `L.tr` takes a comptime key; two
hand-transcribed civil-date modules ("nokre's ARB refuses `DateTime`
placeholders"); and a 17-field `chromeFor` literal **identical
line-for-line in both apps**.

Changes, all in `l10n`:

1. `Bundle.of(app)` — a bound view resolving the locale once:
   `L.of(app).tr(.key)`; controllers keep at most one two-line wrapper
   instead of two.
2. `Bundle.trAny(locale, key: Key)` — the runtime-key reader (a
   generated dense table, not a comptime map), killing the month
   switches.
3. A `date` placeholder kind in ARB (`{when,date,yMd}` subset —
   deterministic, integer civil-date math nokre already has twice in
   consumer trees).
4. **Reserved chrome keys**: `Bundle.chrome(locale) Chrome`
   comptime-checks that the catalog declares `chromeBack`,
   `chromeClose`, … (one key per `Chrome` field, names derived from the
   field names) and builds the struct. The 17-field literal and its
   duplicate die; a new chrome word becomes a missing-key compile error
   in every localized app, which is the existing `Catalog` guarantee
   moved to where the words actually live.

### A8. Harness: one door in, and the verbs consumers rebuilt

Evidence: five constructors (`init`, `initWith`, `initWithRoutes`,
`initWithNav`, `initWithStore`) where one options struct exists;
both apps' fixtures open with the identical comment "the harness verbs
a test reaches for constantly, at one hop" over 10–13 pure
pass-throughs; both apps wrote the same `press` (visibility- and
fold-fallback), `goTab` (the nav's three shapes), `typeInto`,
`expectDisabled`; the e2e drivers duplicate six 12-line poll loops for
want of `waitUntil`. Fixture scaffolding: 1,149 + 594 lines, plus
~1,000 more in e2e drivers that are 90% shared.

Changes:

1. Collapse construction to `init(gpa, viewport, opts: InitOptions)` —
   routes/nav/store/ctx/build all fields of `InitOptions`. Delete the
   other four. (`With` currently means both "with options" and "with
   this one positional extra"; after this it means nothing because
   there is one door.)
2. Add the verbs the apps proved out: `press(role, label)` with the
   fold/visibility fallbacks, `typeInto(label, text)`, `goTab(title)`,
   `expectPresent(role, name)`, `expectDisabled(label)`.
3. A deadline-bounded `waitUntil` for live-transport drivers (pump +
   predicate + deadline + tree dump on failure), so the six hand poll
   loops become calls.

### A9. Sheet identity — close the shadow state machine

Evidence: 13 `Sheet` enums/unions across the apps mirror "which sheet
is open" beside the framework's own `sheet_builder`; 33 `sheet = .none`
resets; 11 `onDismiss` shims exist only to zero the mirror. The
framework knows a sheet is open but not *which*, so every controller
keeps the answer next door.

Change: let `openSheet` carry a small identity and answer it back.

```zig
pub const SheetBuilder = struct {
    ctx: ?*anyopaque = null,
    /// The consumer's name for this sheet; `App.openSheetTag()`
    /// answers it while the sheet is up. 0 = unnamed.
    tag: u32 = 0,
    call: ...,
    on_dismiss: ...,
};
pub fn openSheetTag(self: *const App) ?u32
```

Controllers keep their enum but stop mirroring its *liveness*; most
`onDismiss` shims disappear (the mirror they reset no longer exists).

### A10. The site seam (four small items, one pass)

1. **`Refs.write` returns a destination instead of writing bytes.**
   Today the site closes nokre's `href="` quote by hand and re-slices
   `rel="noopener"` to splice attributes in — the sharpest bypass in
   any consumer. Change the hook to
   `fn resolve(ctx, route: []const u8) Dest` with
   `Dest = union(enum) { internal: []const u8, external: []const u8 }`
   and let the emitter (which already has a private `hrefExternal`)
   write both forms. Deletes the quote-splicing and one of the two
   duplicated `writeHref` bodies.
2. **Audit rule filter.** The site re-implements the audit loop minus
   `unresolvable_route` (its resolver is links.zig, not the router).
   `audit.Options{ .skip: []const Violation.Rule = &.{} }` on
   `collect`, and the copied loop dies.
3. **The driver file set as data.** The site re-types nokre's web
   driver file list and got it wrong: the published site ships
   `live.js` + `services.js` but not `sw.js` (registered
   unconditionally by live.js — a silent 404 on every page load) or
   `live-worker.js`. Export the list nokre's `addWebSite` already owns
   (`pub const driver_files: []const []const u8` beside `dom.live`),
   and fix the site to copy it whole. **The 404 is a live defect
   today; fixing the site's list is worth doing even before the
   export exists.**
4. **A document-shell helper.** 142 lines of raw HTML string literals
   in the site reproduce nokre-internal contract strings
   (`class="nokre has-chrome page"`, `#chrome`/`#content`, the
   mount-JSON's `addressing: "documents"`). A
   `dom.document(em, .{ .title, .lang, .head_extra, ... })` owning
   doctype, mount points and the skip link keeps those strings in one
   home. (A full static-site driver — the per-route loop, anchor
   harvest, stale-prune — is a larger owner decision; log it, don't
   assume it.)

### A11. `notify` becomes infallible

Evidence: the user app wraps `app.notify` in a 36-line module whose
main job is `catch {}` (59 call sites); nothing a consumer can do with
the error. Pre-reserve the notice list (bounded ring, drop-oldest — the
banner already shows only the front) and `notify` returns `void`.

---

## Part B — vocabulary

Renames judged worth their churn. Everything else surveyed (ink/gray at
the canvas boundary, draw* vs bare nouns across the two editions,
pointer `down/up` vs pan `begin/end`) was examined and deliberately
kept — those splits track real layer or concept boundaries; a note in
the code where each boundary sits is the fix, not a rename.

| Now | Proposed | Why |
| --- | --- | --- |
| `App.navigate(route:)` / `App.switchTo(ref:)` / `Router.push(reference:)` | one param word: `ref` everywhere | three names for the same argument; `ref` is the concept's short true name (`routeRef`, `currentRef`, `max_ref_bytes` already agree). Param-name-only — zero consumer breakage. |
| `App.presentSheet` | keep name, **assert a builder is installed** | it is the primitive a `SheetBuilder` calls; called ad hoc it makes a sheet that silently dies on reload. `std.debug.assert(app.sheet_builder != null)` makes the wrong path unwritable instead of renaming it. |
| `Harness.initWith*` quartet | deleted (A8) | five doors, one options struct. |
| `NavHere.label` | `NavHere.title` | it holds `RouteDef.title`'s value; its sibling `NavCurrent.section` names its source. The name/value split then reads the same way in both structs (`title`/`name`, `section`/`name`). |
| oauth `Mock` `Outcome` | `Delivery` (or fold into `Result`) | `Outcome` in oauth/iap means "what the OS did" while `http.Outcome` is "the handler's decision"; inside oauth.zig `Outcome` and `Result` are near-duplicates one screen apart. |
| `error.InvalidListItemChild` / `InvalidBlockquoteChild` / `InvalidPickerChild` | `ListItemChildMustBeBlock` etc. — the `XChildMustBeY` family | two spellings of one rule shape; pick the family that names the fix. |
| `workers.Vt` | `VTable` | `canvas.zig` and `c_shell.zig` already say `VTable`; three spellings of one idea. |
| `Runtime.ref`/`unref` | `retain`/`release` | `ref` now collides with the router's reference vocabulary (`Router.ref` formats one) — the same word for refcounting and route references in one framework. |
| `askedToNotify` (harness) vs `askedForAuthorization` (mock) | one spelling (`askedToNotify` both) | the same question, two past-participle forms. |
| `text.Scale{h4,h3,h2,h1}` | *log only* — candidate `{small, body, large, xlarge, xxlarge, huge}` or similar | HTML heading names for a type scale, truncated at h4 while `HeadingLevel` runs to h6; churn ~40 sites; owner taste call. |

Also from the sweep, worth a comment rather than a change: `frame` means
three things (worker envelope, rendered image, byte tag); `Provider`
means two (button form, oauth backend); the a11y role table is a
deliberate second vocabulary (ARIA fidelity) — each deserves one
sentence at its declaration naming its namesakes.

## Part C — internal simplifications

1. **Triplicated `std.Io.Threaded` refcount** — `workers/thread.zig`,
   `oauth/loopback.zig`, `http/native.zig` carry the same
   `io_backend/io_refs/acquireIo/releaseIo` block (`releaseIo`
   byte-identical). One `src/services/io_ref.zig` with the init options
   as a parameter.
2. **Nine near-identical service mock lifecycles** —
   `mock/init/deinit` byte-identical in open_url/haptic/clipboard and
   1–3 lines off in five more. A `services.StatelessMock(Journal)`
   generic beside the `Journal` they already share.
3. **Duplicated header-copy loop** in `http.zig` and `http/native.zig`;
   the restated C-callback signatures in oauth/iap (extern + definition
   pairs) — derive one from the other with a shared `pub const`
   signature type.
4. **Android shell** re-implements the 18 shell handlers `Runner`
   already contains (the Activity-owns-the-loop split is deliberate;
   the *handler bodies* need not be). Extract the handlers from
   `Runner` into shared fns both instantiate.
5. The renderer/stylesheet double truth (visual rules once in Zig, once
   in 1,785 lines of CSS text) is logged as a structural risk, not an
   item: any unification is a redesign of the DOM edition and needs its
   own argument.

## Part D — performance notes

No hot-path defects found; the design's determinism keeps the frame
model cheap (no ticker, dirty-flagged layout, at-rest zero CPU).
Real items:

- **A5 (tree-arena formatting)** is the one change that is both an
  ergonomics and an allocation win: today every formatted label is
  written twice (scratch buffer, then arena copy).
- **`IconName` comptime cost**: `std.meta.stringToEnum` on the
  1,748-name enum trips the eval-branch quota (site evidence — it wrote
  a linear scan instead). If runtime name→icon lookup is ever wanted,
  ship a generated sorted table beside the enum. Not urgent.
- `Router.find` is a linear scan (≤42 routes today) and
  `Tree.reclaim` re-copies surviving strings per navigation — both fine
  at real scales and load-bearing for memory bounds; leave them.
- `Element` union is ~140 bytes/node by its widest members; thousands
  of nodes are nothing. No action.

## Part E — logged costs, not defects

Closed-set consequences the consumers pay and the doctrine accepts;
recorded so the next survey doesn't re-litigate them: no disabled
text field (both apps swap the field for a text line), no destructive
button emphasis, no accordion, no interactive badge, no per-icon
ink/size, checkbox label not a tap target, notices dedup by title, no
debounce (the user app made search a button — arguably the doctrine
working as intended). If any is ever reconsidered it needs the
owner-level argument oauth.md's reversal record sets the precedent for.
One exception worth surfacing now: **`TextInput.disabled`** is
semantics, not styling (ARIA has it; both apps fake it) — candidate for
the element set on the set's own terms.

## Part F — migration order

Ordered so nothing lands twice and no compatibility layer exists at any
point. Each item: change nokre → bump `revision` if contract-visible →
migrate both apps + site in the same pass → full gates (nokre test +
goldens byte-identical + check-targets + web; both app suites + golden
+ e2e; site rebuild).

1. **A1 bind** (additive + delete `nokre.ctx`; consumers migrate all
   924 sites mechanically — fork-parallelizable like the label-lookup
   migration was).
2. **A2 refresh** (deletes the 22 policies and 142 guards; the
   in-build-reload refusal lands first so the migration can't
   reintroduce the bug it guards).
3. **A3 http tag** (signature flip, mechanical; consumer client-array
   collapse can trail within the pass).
4. **A8 harness** (one door + verbs; fixture shrink in the same pass).
5. **A4 builder + A5 tree.fmt** (additive; screens migrate
   opportunistically — the raw Tree API remains the substrate, so no
   dual-API period exists: the cursor *is* Tree calls).
6. **A7 l10n** (of/trAny/date/chrome-keys; deletes wrappers, month
   switches, date modules, chromeFor).
7. **A9 sheet tag + A11 infallible notify.**
8. **A10 site seam** (Refs → Dest, audit skip, driver_files export,
   document shell) — plus the immediate consumer-side 404 fix, which
   should not wait for the nokre export.
9. **A6 Load** (after A4, so the gate idiom has the cursor to hang on;
   scope decided by owner first).
10. **Part B vocabulary + Part C dedups** (one sweep pass at the end,
    when no in-flight migration can collide with renames).
