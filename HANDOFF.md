# HANDOFF — the third ergonomics round (2026-08-05, evening)

Status: **EXECUTING**, one pass at a time, in Part F's order. Part 0 is
finished: 0.1–0.3 shipped the evening this file was written, and
0.4–0.7 shipped as passes 1–3 (revisions 16, 17, 18 — commits on each
item's heading and in Part F). Part A begins at A1. Each item's body
below is left as it was surveyed, so a DONE heading marks a claim that
was true when written and a fix that has since landed; where execution
contradicted the survey, Part F's entry says so. This file succeeds the second
handoff (executed whole, revisions 6→15, deleted in the working tree)
at the same home. Counts are grep-verified against the trees as of
nokre `627ceda` (+ this worktree), rokovski `e4698e12`, site
`f73799b`. Survey method: six independent full reads — nokre core,
nokre services/l10n/workers/testing, nokre render/platform/build, the
rokovski user app (42.8k lines), the rokovski org app (17.9k) with a
line-level org-vs-user diff, and the site generator + all 27 docs —
each briefed on the doctrine and both kill lists, hunting only for
what rounds one and two missed.

Execution protocol stays the standing one: **one item per pass, owner
review between, never chain.** Contract changes bump `revision` and
move all three pins in the same pass. Nothing here re-proposes an
owner-killed item; where a finding sits *near* one, the adjacency is
flagged inline so the owner can kill it on sight if it reads as the
same thing.

The round's headline: the rounds worked. `.bind` has 99 org uses and
zero manual action wirings; `openSheetTag` is adopted 7/7; `refresh`
outnumbers residual `reload` 70:8; the site's facade is gone; the
consumers' remaining duplication has moved *up* a level — from syntax
ritual to missing *containers, verbs, and identities*. That is what
Part A is made of. Part 0 is different in kind: five real defects the
surveys found on the way, three already fixed in this pass.

---

## Part 0 — defects (fix before ergonomics)

### 0.1 FIXED — the home page promised the identity the owner refused
`site/src/content.zig:137` shipped "Same logical viewport, same bytes
— across runs, machines **and platforms**" — the exact claim the
2026-08-03 editions ruling refused, contradicted by the same page's
own opening paragraph ("Identity across platforms is not the goal")
and by introduction.md, pixel-model.md, and roadmap.md. Live on the
published tree (`docs/index.html`). Changed to introduction.md's exact
words: "across runs and machines, on the platform that drew them."
**The rebuild is not run** — publish order is nokre commit → rebuild →
site commit, and this round's nokre changes should land first.

### 0.2 FIXED — append admitted a caret that panics on the first keystroke
`Tree.setContent` clamps a stale caret to a codepoint boundary
(tree.zig:285-297, with the rationale comment) but the append path
never did: `validateAppend` checks `selected` for three elements and
`cursor` for none, and `dupeStringsInto` copied `value` leaving
`cursor` untouched. Pointer-activation masks it (`activate` rewrites
the cursor), Tab-focus does not — then `insertText` → `splice` →
`@memcpy` with `start > old.len`: bounds panic in safe builds, UB in
ReleaseFast; an in-bounds mid-codepoint caret quietly stores invalid
UTF-8, breaking the invariant every downstream scan trusts
(tree.zig:10-13). Fixed by clamping in both editable arms of
`dupeStringsInto` with the same `codepointFloor`, plus a pinning test
("append clamps the caret the way setContent does", tree_test.zig).
No consumer appends a nonzero cursor today; no golden moves.

### 0.3 FIXED — emit_css.zig documented a build step that does not exist
`src/render/dom/emit_css.zig:8` told its stated audience ("a build
step in another language") to run `zig build dom-css`; no such step
exists — `emitStylesheet` compiles and runs the tool inside site
assembly. The comment now says that, and keeps the correct
`./emit-css` usage line.

### 0.4 DONE (nokre `d7073e3`, revision 16) — the DOM edition announced four framework-chrome names in English, always
`serialize.zig` hard-codes `aria-label="Back"` (:632),
`aria-label="Close"` (:654), `Section: ` (:617) and
`Current screen: ` (:626) — while revision 11 put the localized words
*on the elements themselves* (`app.zig:523-524` syncs
`back.label`/`sheet_close.label` from `Chrome`; `element.label()`
returns them; that is what VoiceOver hears natively). A Persian app
announces بازگشت on macOS and "Back" on the web. The serializer even
does it right two lines away (`:578` reads `em.app.chrome.sections`
for the nav landmark). The tests pin the English literals
(serialize_test.zig:809, :835), so a localized app never exercises the
drift.

Fix: emit the element's own label/name in all four arms —
```zig
// before                                   // after
try em.raw("... aria-label=\"Back\"");      try em.raw("... aria-label=\"");
                                            try em.text(bk.label);
try em.raw("...>Section: </span>");         try em.raw("...>"); try em.text(chrome.section_prefix-equivalent);
```
— with the two visually-hidden prefixes taken from the same `Chrome`
fields the a11y tree uses, and the tests re-pinned against the catalog
rather than English. Contract-visible markup change: revision bump,
site rebuild (published pages churn where those strings appear).
Restores "two editions consult one catalog" — the guarantee the
chrome-keys item existed to establish.

### 0.5 DONE (nokre `65e4ac6`, revision 17) — a routeless notice grew a live control that pressed into a recorded programmer error
`Notify.route` defaults to `""` and that is the overwhelmingly normal
case — 55 of 59 `notify` calls in the user app are routeless. But
`installBanner` (notices.zig:250-258) appends the `.open` icon_button
unconditionally when one notice is up, and `installPane` (:309-312)
one per row. Pressing it runs `activateIcon .open` → `navigate("")` →
`unknown_route` lands in `Router.refused` — the record documented as
"programmer errors", which the harness audit turns into a failing
test. So most notices in both real apps carry a focusable, announced
"Open: {title}" control that collapses the banner and plants a
phantom refusal. The audit already treats routeless notices as legal
(`n.route.len > 0 and ...`, audit.zig:330); only the chrome disagrees.
No nokre test covers a routeless notice's controls — every banner
test passes `.route = "home"`.

Fix: gate both `.open` appends on `front.route().len > 0` (and per-row
in the pane). Visual change where a routeless banner shows: regenerate
goldens (nokre + both apps), review. Rider worth taking in the same
pass, since the file is open: pick **one** spelling of "no route" —
today `Span.route` is `?[]const u8 = null` while `Link`/`Tile`/
`Notify` use `""` and `Notice.route` has no default at all
(element.zig:200, :556, :821, :1150; notices.zig:89). Routeless being
legal is the argument for the optional form on Notice/Notify; either
way, one spelling.

### 0.6 DONE (nokre `aebe154`, revision 18) — `Style.family` let body text into the icon and brand faces, against a documented guarantee
text.zig:19-26 states `brand` "is **not a face consumers may set on a
span or a text element, and the element set gives them no way to name
it**." But `text.Style` carries the full four-member `Family`, and
`Cursor.styled` hands it straight to append — zero checks anywhere
(`grep family tree.zig`: no hits; no audit rule). So
`.{ .family = .brand }` renders trademark artwork as prose, and
`.icons` bypasses `Icon`'s decorative-vs-labeled discipline. No
consumer sets `.family` today. Fix at the door, the framework's own
pattern:
```zig
// tree.zig validateAppend, .text arm (and heading spans):
switch (t.style.family) { .icons, .brand => return error.ReservedFamily, else => {} }
```
(The stronger form — `Style` gets its own `enum { prose, mono }`
mapped to `Family` at the render seam — makes the state
unrepresentable at comptime; more churn, same guarantee. Owner picks.)

### 0.7 DONE (nokre `aebe154`, revision 18) — three smaller admission gaps, one shape: input the seam trusts
- **wasm exports trust `len`**: `live.zig`'s seven string-carrying
  exports (`boot`:222, `text`:413, `imeUpdate`:424, `imeCommit`:429,
  `navigate`:446, `href`:350, `seedBytes`:242) slice
  `scratch.items[0..len]` from the caller in a ReleaseSmall build.
  The C seam already got the drop-at-the-door pass; this seam didn't.
  One `scratchSlice(len)` helper clamping to `scratch.items.len`,
  used by all seven.
- **The three focus doors vet differently and none vets the span**:
  `c_shell.a11yAction` checks `isFocusable` only when span == null;
  `live.setFocus` checks the node only; `App.deliver(.focus)` checks
  nothing (app.zig:753-760) — while the *activation* path vets fully
  (input.zig:310-315). Vet once inside `deliver(.focus)` (node exists;
  span in range and `isLink`; else `isFocusable`) and delete the two
  partial copies — one home, and the seams get simpler, not longer.
- **`iap.purchase`/`restore` are legal with no stream handler** — the
  one service where a forgotten registration eats money-shaped events:
  `dispatchUpdate` drops on null handler (iap.zig:373), and unlike
  notification (buffers pre-handler, :480-523) or deep_link (journals
  every delivery), nothing records the loss. Cheapest honest guard:
  `if (st.handler == null) return error.NoHandler;` in both verbs —
  the mock then catches the mistake in any harness run. Rokovski
  registers inside `build` and is unaffected.

---

## Part A — ranked redesigns

### A1 DONE (nokre `9ec8836` + `120bed8`, revisions 19–20) — the borrow model's missing containers: `Str(cap)` and `Rows(T, cap)`
The single largest remaining consumer cost. nokre's callback-borrow
discipline ("copy a borrowed slice into a bounded field", nokre's own
queue.zig:12) forces every surviving string and list into fixed-cap
storage — and ships neither type.

Evidence: `Str(cap)` is hand-defined **three times** (user
channels.zig:94, user forms.zig:26 as `Field`, org rows.zig:5 — a
file misnamed after its only content) with **244 + 88 uses** across
18 + N files. The bounded row list — `{ phase: Load, len: usize,
rows: [N]T, items(), push() }` — is hand-rolled **25 times** (11 user
+ 8 org `pub fn items(` structs and their kin), every fill an
undisclosed `self.len = @min(max, replies.len)` truncation, the same
ceiling comment copy-pasted at 4+ sites, the same
`if (phase != .idle) return` ensure-guard 15×, and each with its own
capacity-refusal test. Three org billing screens differ from each
other by ~24 identifier lines around this scaffold.

Change: two pure-data types beside `Load`, same doctrine slot (nokre
never reads them):
```zig
pub fn Str(comptime cap: usize) type   // set (truncating, says so), get, eql, blank
pub fn Rows(comptime T: type, comptime cap: usize) type
// items(), clear(), push() ?*T, fill(slice) — and `truncated: bool`,
// so the ceiling is disclosable instead of silent.
```
Before / after at a declaration:
```zig
// before: a 20-line struct + its refusal test, × 25
// after:
invites: nokre.Rows(InviteRow, 16) = .{},
```
The `phase` stays app-side (whether `Rows` carries `Load` is an owner
call; leaving it out avoids even brushing load.zig's recorded
"nothing further" stance). Deletes on the order of 700–900 consumer
lines and closes the silent-truncation class. Meets queue.zig's own
bar for existing ("every consumer was hand-rolling the same ring") —
twenty-five times over.

### A2 DONE (nokre `c858cb6`, revision 21) — `.bind` stopped at Action; the trampoline door is exported
Revision 6 removed the trampoline ritual for the four action types.
Everything else that carries `{ctx, call}` still pays it:
**12 identical `Signal` structs** across the apps (each 8 lines,
byte-copies of `Action` minus `bind` — user transfer.zig:43,
settings.zig:115 ×2, billing.zig:54, read.zig:58, write.zig:237; org
×7), **30 port `Callback` types** in the two domain libs (zero have
bind → 154 org + ~106 user `@ptrCast(@alignCast(ctx.?))` rituals and
19 local `fn cast` shims survive), ~50 route builders each opening
with the identical cast prologue, and the wait-predicate plumbing of
A5. The lib side matters: the domain packages are deliberately
nokre-free, so they *cannot* borrow `Action.bind`'s machinery today.

Change, two independent pieces:
1. **Export the factory**: `nokre.bindAs(CallbackT, f, state)` —
   comptime duck-typed over any struct with
   `{ ctx: ?*anyopaque, call: *const fn (?*anyopaque, ...) R }`,
   which is exactly what `Action.bind` already synthesizes privately
   (element.zig:70). One public fn; the 12 Signals become `Action` (or
   keep their name and gain bind for free), and consumer ports bind
   without importing anything but the type shape.
2. **A typed route table** (owner-scoped — this is the bigger design):
   `RouteDef.build(ctx, app)` is the last framework-owned
   `?*anyopaque` consumers touch. A comptime `Routes(State)` wrapper
   that types the ctx once would delete all ~50 prologues:
   ```zig
   // before, × 50 screens:
   fn build(ctx: ?*anyopaque, app: *App) !void {
       const state: *State = @ptrCast(@alignCast(ctx.?)); ...
   // after:
   fn build(state: *State, app: *App) !void { ...
   ```
   Decide scope at session start; piece 1 alone is worth the pass.

### A3 DONE (nokre `3a5a6c6`, revision 22) — finish the sheet door: the typed half, the close verb, the confirm idiom
Revision 12's tag removed the liveness mirrors; six controllers per
app then rebuilt the *typed* layer around the raw `u32` identically:
five hand `enum(u32)` starting at `= 1` to dodge tag 0; six
`present()` wrappers packing `@intFromEnum` + ctx + `catch {}`; ten
render prologues (cast → `@enumFromInt(openSheetTag() orelse return)`
→ `presentSheet` → switch — same explanatory comment copy-pasted in
four); **13 declarations of `closeSheet`** = `dismissSheet();
reload() catch {}` — an error `App.refresh` already swallows
internally as unactionable (app.zig:420-425), left in consumer hands
at this one door; three `represent()` shims; and **17 hand-assembled
confirm sheets** (title → body → optional error → primary
`in_progress` → secondary Cancel) on which the two apps disagree
about whether Cancel disables while busy.

Also a verified hazard in the flat tag namespace: five enums all
minting from 0-adjacent values means cross-controller reads collide —
`billing.zig:511` re-presents its gift sheet over *whatever* sheet is
open; `settings_sheets.zig:13` does `@enumFromInt` on a tag any other
controller might own. The workaround comments ("its subject, not its
liveness") are the shadow state the tag was shipped to kill.

Change, one pass:
```zig
// overlays.zig
pub fn openSheetAs(app: *App, tag: anytype, comptime render: anytype, state: anytype) !void
// packs @intFromEnum (comptime-refusing enums whose ordinals hit 0),
// binds ctx like Action.bind, keeps the builder.
pub fn sheetTagAs(app: *const App, comptime E: type, ctx: ?*anyopaque) ?E
// answers only when the kept builder's ctx matches — "is MY sheet
// up", the question every cross-fire site is actually asking.
pub fn closeSheet(app: *App) void  // dismiss + the quiet rebuild, one home
```
plus `Cursor.confirmSheet(.{ .title, .body, .error_copy, .confirm,
.cancel, .busy })` as the second member of cursor.zig's idiom family
(the first being `loadGate`), settling the Cancel-while-busy question
once. Narrow `openSheet`'s error from `anyerror` while the file is
open: today a failed *four-eyes deletion* confirm sheet vanishes into
`catch {}` ×7. (Not the killed presentSheet assert: nothing here
asserts at the primitive; it types the door above it.)

### A4 DONE (nokre `28ba1fc`, revision 24) — the harness's missing half: asserting what was sent
Round 2 gave the *answering* side suffix verbs (`fulfillHttpPath`,
`failHttpPath`, `httpIndexOf`). The *observing* side never landed, so
tests reach four levels deep: **72 `pendingAt(` + 31 `headerValue(` +
123 `indexOfPath`/`httpIndexOf`** sites across both apps' tests, 51
bare `fixture.harness.app.services.http.pendingCount()` reaches, and
both fixtures carrying identical sugar (`hasPath`/`countPath`, user
fixture.zig:470-487; `fulfillPath`/`tap` twins byte-identical in both
apps, comments included). A failed count today prints two integers;
the harness's own miss path already knows how to print what's parked
(harness.zig:465-483).

Change (harness.zig, beside the fulfill family):
```zig
pub fn httpPending(h: *const Harness, suffix: ?[]const u8) usize
pub fn expectNoPendingHttp(h: *Harness) !void      // loud: lists every parked URL
pub fn expectRequest(h: *Harness, suffix: []const u8, expect: struct {
    method: ?http.Method = null, body: ?[]const u8 = null,
    body_contains: ?[]const u8 = null, header: ?[2][]const u8 = null,
}) !void
pub fn takeRequest(h: *Harness, suffix: []const u8) !PendingRequest  // free-form cases
```
Riders while the file is open, each with a consumer receipt:
`expectEnabled` (its twin exists; forced raw-tree assert at org
create_organization_test.zig:168), and value expectations covering
`tile.detail`/`qr.value`/`copyable.value` (9 raw tree reads). Deletes
the largest remaining per-test block; fixture boot is already 3 lines.

### A5. The driver tier never got its round: two ~570-line Devices re-implement the harness
`e2e/device.zig` is 563 (org) / 581 (user) lines with a shared
23-verb surface: five `waitFor*` wrappers hand-plumbing anyopaque
predicates over `wait.waitUntil` (byte-same in both apps, ~140 lines
each), plus re-implementations of `Harness.press`'s
folded/keyboard/More-sheet ladder and `goTab`'s nav walk — under
**gratuitously divergent names** (`fill` vs `typeInto`, `expect` vs
`expectPresent`, `choose` vs `selectOption`). Root cause is
structural: `Harness` is welded to mocks (`Service = if (is_test)
Mock else Platform`), so its verbs are unreachable against a live
`App`; `wait.zig` ships only the raw loop; testing.md:844 blesses the
tier without populating it.

Change: promote the wait predicates nokre can already evaluate —
```zig
// testing/wait.zig
pub fn untilLabel(app: *App, pacer: Pacer, label: []const u8) error{WaitTimeout}!NodeId
pub fn untilRole(app: *App, pacer: Pacer, role: Role, name: []const u8) error{WaitTimeout}!NodeId
pub fn untilRoute(app: *App, pacer: Pacer, ref: []const u8) error{WaitTimeout}!void
```
— and a mock-free driver verb set sharing the Harness's *names and
algorithms* (the ladders already live in `testing/driver.zig`/
`queries.zig`; what's missing is the wait-composed layer). Each app
keeps `idle()` (PoW-specific) and its domain verbs. Also:
`waitUntil`'s predicate sees only `*App`, which forced three more
hand loops for app-state conditions — either a ctx-carrying overload
or `bindAs` (A2) covers it. Deletes ~700+ duplicated driver lines and
ends the two-name-per-verb split; a third edition's driver would have
been a third copy.

### A6. One-shot in-flight gate — the mutation twin of `Load`
`Load` is deliberately display-only; `Button.in_progress` renders
busy; nothing *produces* busy. So every mutation hand-rolls
`if (self.x) return; self.x = true; ... self.x = false;` — **22 flags
across 12 org files** under one name, **10 user flags under seven
names** (`busy`, `gift_busy`, `redeem_busy`, `refreshing`,
`exporting`, `sharing`, `submitting`), ~38 guard/assign sites, and
user manage.zig resets at **8 distinct return paths** — one missed
path wedges the screen forever. 92 build sites feed these into
`in_progress`.

Change: the smallest honest primitive, pure data like `Load`:
```zig
pub const Gate = struct {
    up: bool = false,
    pub fn begin(g: *Gate) bool { if (g.up) return false; g.up = true; return true; }
    pub fn end(g: *Gate) void { g.up = false; }
};
// if (!self.op.begin()) return;  defer-friendly, one name, one polarity
```
Doesn't reopen load.zig's non-goal (no phases, no staleness — a
latch, not a machine). The vocabulary win is half the point: seven
names collapse into one.

### A7. `loadGate` has no ready-but-empty branch
30 empty-state sites across the apps render **six visual variants**
of "nothing here" (org: plain `b.text`; user: four screens styled
small+dark, three plain). Strongest convergent evidence in the
survey: both apps independently invented a private section struct
with the same fields (org organization.zig:88-101
`{heading, empty, failed, route, icon, create}`; user home.zig:249-261
the same idea, one field more). `loadGate` returns `true` on `.ready`
and says nothing about zero rows — exactly the missing branch.

Change: `LoadGate.empty: ?[]const u8 = null` plus a count (or a
sibling `emptyGate(phase, count, opts)`) rendering the one blessed
empty line when ready-and-zero; pairs with `Rows.truncated` (A1) for
the disclosure line. The full section idiom (heading + gate + list +
create link) is a candidate second step — log, owner decides.

### A8. The stale-reply surface: shipped verbs, unreachable pit of success
Filed as one item because the fixes are small but the *decision* is
one posture question. Receipts, all verified today:
- `refresh(.{ .route })` — the option built for "a reply landed after
  the user walked away" — has **0 route-scoped adoptions in the org
  app's 70 calls** (user app similar). The polite verb exists; nothing
  steers a callback author toward scoping it.
- Callbacks bind the controller, never the request: org detail.zig
  fires 4 concurrent loads with `.ctx = self`; re-opening org B while
  org A replies are in flight lets A's callbacks overwrite B and mark
  it `.ready`. The `organization_id` guard exists at all 8 `open()`
  sites and **zero** callback sites. No walk-away race has a test.
- Late-reply navigation: `navigate`/`navigateBack` from callbacks
  (org invites.zig:236-260, user state.zig:910-944) can yank the user
  off an unrelated screen; `refresh` got a route guard, navigation
  didn't.
- `bindAt` carries a position, not an identity: org security.zig:80
  bakes an index consumed after arbitrary refetches — bounds-checked,
  so the failure is *removing the wrong admin*, not a crash. The same
  app keys the same shape by code elsewhere (invites.zig:68): two
  policies in one app because the API offers only position.
- `http.Handle.cancel` is discarded at every call site — the port
  `Callback` chains have nowhere to carry it.

Menu (owner picks the posture; none of this proposes `Remote(T)` —
the load.zig stance predates these receipts and deserves to see
them): (a) a route-scoped `navigate` twin for callback use; (b) make
`.route` the default-visible field in `refresh`'s doc example and add
an audit note when a controller calls routeless `refresh` from an
http callback (harness-detectable); (c) `bindAt` gaining a second
comptime form that carries a small stable identity (`bindKey`) so
position-vs-identity is a choice made in vocabulary, not re-derived
per controller.

### A9. `L.of` is one hop short, twice
- `Bound` carries only tr/trAny/fmt/fmtIn (l10n.zig:405-423);
  everything else re-unwraps: **24 × `L.of(app).locale`** feeding
  `L.chrome(...)`/`L.tag(...)`/`L.dir(...)` in both apps' state.zig.
  Add `tag()`, `dir()`, `chrome()` to `Bound` (three inline
  one-liners; `.locale` stays pub for the comparison sites).
- The most-copied line in the consumer codebase is still a wrapper:
  **13 identical `tr` shims** (`return L.of(self.app).tr(key)`), and
  formatted keys read `try L.of(state.app).fmtIn(&app.tree, .key,
  args)` — the tree re-passed though `of()` had the app in hand.
  Either `L.in(app)` (a second binder keeping `{locale, tree}`, so
  `.fmt(.key, args)` lands in the arena) or an exported mixin
  (`pub const tr = L.mixinTr;`) — one line per controller instead of
  three, or zero.

### A10. Mid-flight patches: the last `tree.get` ritual
Nine clusters across the user app (transfer.zig:310, write.zig:711,
state.zig:744-983) hand-roll recorded-NodeId → `tree.get` → field
poke → `invalidate()` for progress/status that must not rebuild under
the user's fingers, carried by **12 `NodeId = .invalid` fields**; six
`tree.appendId` escapes exist in the org app only because no `Cursor`
leaf returns its id. Two small moves close it: leaf cursor methods
gain an `...Id` twin where a receipt is real (or `Cursor.appendId`
generally), and a sanctioned patch pair —
`app.patchText(id, copy)` / `app.patchProgress(id, pct)` — that
composes get+set+invalidate and *no-ops on a stale id*, the same
polite-decline shape `refresh` established. Residue rider: org
`refreshConsent` (state.zig:554) still node-pokes a screen with no
editable — plain `refresh` residue, delete consumer-side.

### A11. The field-error slot — semantics the element set is missing
Org declares `Notice = enum` **11 times**, user `Trouble` 5 more —
per-controller enums mapping server codes to copy rendered as an
anonymous `text()` *beside* the form control, with no structural
association to the field: no `aria-describedby`, no `aria-invalid`,
nothing the a11y tree can hand an AT. In a framework whose first
guarantee is a11y-derived-from-the-tree, field errors are the one
form concept with no semantic home. This is an element-set argument
(semantics, not styling — same lane as the flagged
`TextInput.disabled` candidate, for which this round adds a receipt:
user create.zig:119 *restructures its layout* around the missing
field). Proposal to argue on the set's own terms:
`TextInput.trouble: []const u8 = ""` (name open) rendered in both
editions with the ARIA association, plus the same on `TextArea`.
Rider: the consumer word `Notice` colliding with nokre's notices ring
dissolves the day the slot exists.

### A12. Smaller, each with one receipt
- **Chrome at boot**: `OptionsRelease` has `locale` and `direction`
  but not `chrome`, so a restored-RTL boot ships English chrome until
  a separate `setChrome` — the correct path is longer than the wrong
  one; one field closes it (app.zig:215-231).
- **Route args format-into-tree**: 17 non-test `routeRef(&buf...)`
  sites with 19 hand `[N]u8` buffers, org inventing its own
  `max_route_len = 96` twice while its third file uses
  `router.max_ref_bytes`. A `(route, args)` overload on
  `Tile`/`Link` cursor methods formatting into the arena —
  `Tree.fmt`'s precedent, applied to refs.
- **Single-flight adapter doctrine, written once**: 17 `pending: ?`
  single-flight copies + the DevClock two-step POST machine
  byte-identical in both apps. Not the killed array collapse —
  one-transport-per-call stands; the ask is one documented (or typed)
  chaining idiom so 17 adapters stop re-deriving the discipline.
  Doctrine home: PORTING equivalent in docs/services.md.
- **Worker codec and the error string round-trip**: the codec refuses
  error sets, so both apps' identical pow_worker.zig re-derives
  errors by string table. Encoding an error set as its tag is
  mechanical and typed. *Adjacency flag*: the killed B5 was an error
  **rename**; this is codec capability — kill on sight if the owner
  reads it as the same item.
- **`Queue.done` double-call**: mis-delivers the *next* submitter's
  callback instead of failing loudly (queue.zig:66-79). A
  debug-assert `started` flag; zero release cost.
- **Golden-test recipe** (build surface): both consumer build.zigs
  hand-copy the same ~20 lines nokre's own build writes (the
  `"build_options"` name contract, `update_goldens`, `linkSkia`,
  `setCwd`). `nokre.addGoldenTests(dep, .{...})` would own the
  contract. Candidate only — the owner has killed convenience
  wrappers before.

---

## Part B — vocabulary and consistency

Renames and consistency fixes judged worth their churn. Nothing here
touches an owner-killed rename.

| Now | Proposed | Why |
| --- | --- | --- |
| `secure_store.Fake` | `MockState` | eleven services spell the pair `Mock`+`MockState`; the twelfth says `Fake`. Zero consumer references to the type name (grep: both apps touch only `harness.store.*`); one internals doc updates. |
| `element.Glyph` | `ChromeGlyph` | it is the chrome-behavior enum (`activateIcon` switches on it); `Button.Form.glyph` holds an `IconName`, and `IconButton.glyph` reads identically but holds the other type. Consumers never name it (grep: 0). Rider: tighten root `icon_button` in validateAppend to framework construction — today a consumer can smuggle a working `dismiss_all` control through a "chrome only" element. |
| `http.request` inferred error set | named `RequestError` | the one service verb with an open set; every sibling closes and names its sets (`secure_store.GetError`, `iap.Error`, …). Wire failures already ride `Result.failure`; this closes the issue-time set so the roster reads uniformly. Member list needs a transport audit first. |
| `iap.available(*App)` etc. | `*const App` on all read-only verbs | `share`/`notification` probes take const, `iap.available` and `secure_store.get/list` don't — same cached-bool read, so a const-holding helper can call one and not another. Trivial, mechanical. |
| journal views `[]const []u8` | `[]const []const u8` | `shares()`, `copies()`, `opens()`, `received()`, `seen()` and four harness twins hand out mutable bytes into mock-owned memory. The honest borrow; mechanical. |
| `Router.replace` | alias `App.replaceWith` — or a doc line saying why not | the one navigation verb without an App alias, zero uses anywhere; a consumer needing it rediscovers the condemned `app.router.X(app)` shape. Either resolution is fine; today it is silently neither. |
| shell.h haptic "kind 0/kind 1" | `NOKRE_HAPTIC_ARMED/DISARMED` enum | the only unnamed wire values left in the header; the Zig side is wire-pinned and named, ios/shell.m compares raw `0`. |
| `hsk_` ABI prefix | *log only* — candidate `nokre_skia_` | the one non-`nokre_` symbol family in every consumer link, exported by a file named nokre_skia. Mechanical but leaks into getting-started.md's literal linker transcript; owner weighs doc churn. |
| `ImeEvent.update.cursor` | *decide* — store it or drop it | plumbed through all five shells and live.js, then dropped by `handleIme`; renderers cannot draw the in-composition caret the wire pretends to carry. (a) store on the editables and draw, honoring the "day one" claim; (b) delete from the wire in a pinned pass. Doing neither leaves a contract nobody can observe. |
| journal `clear` roster | add the five or write the rule down | services.zig:109 names per-phase `clear` a convention; five services answer it, five don't (oauth, iap, notification, deep_link, locale). Consumer pressure today is 3 sites — the cheap fix is a sentence saying boot-scoped journals deliberately don't reset. |

Consumer-side vocabulary the apps invented that A-items would retire:
`Signal` (→ `Action`/bind, A2), `Trouble`/`Notice` (→ field slot,
A11), seven busy-flag names (→ `Gate`, A6), `rows.zig`'s misnomer
(→ `Str` in nokre, A1). The site's `describe(payload)` improvement in
org expect.zig:224 (absent from the user copy) is drift *proving* the
duplication cost — it rides whichever pass touches the driver tier.

## Part C — one-home consolidations (new evidence; not the killed dedups)

1. **Focus vetting** — one home in `deliver(.focus)`, two partial
   copies deleted (Part 0.7). The rare dedup that shortens the seams.
2. **Site: `links.zig` re-implements `Router.current()`**
   (links.zig:134-138 splits on `arg_separator` by hand;
   router.zig:296 exports exactly the answer). Adopting it also
   retires the `Resolver.page` side-band — one resolution mechanism
   for both site drivers instead of one and a half.
3. **Site build: the pkg-web quartet** — build.zig:764's
   `inline for (.{ "index.html", "page.css", "boot.js",
   "manifest.webmanifest" })` re-types what `addPkgTree` writes;
   icons and drivers already dodged this via data. A
   `packaging.web_page_files` const consumed by both, matching the
   `driver_files` pattern — the manifest's whole purpose is deploy
   verification, so the double truth is the one place it shouldn't
   live.
4. **Emitter anchors** — the site keeps `em.ids.items` past the
   emitter with a two-step deep dupe to run its cross-page anchor
   audit; `ids` is documented as suffix-dedup bookkeeping, appears in
   no doc. For a documents-mode edition, "which anchors does this
   page export" deserves a sanctioned answer:
   `Emitter.takeAnchors(gpa)`, documented in dom-edition.md. (Short
   of the killed static-site driver; this is one getter.)
5. **Driver bytes, not just names** — `dom.driver_files` made the
   set the library's statement; the site still hardcodes
   `"src/render/dom"` to find them. `@embedFile` the four in dom.zig
   (`driver_sources: name+bytes`) and the site writes bytes it never
   locates.
6. **Docs one-home gaps**: the heading-slug rule (GitHub's) lives
   only in a serialize.zig comment while nokre's own docs use
   fragment links — zero doc homes; `audit.Options.skip` (rev 13) is
   documented nowhere; site README still says the driver set is two
   files (README.md:57,121) and omits the two newest build-failure
   modes; the "No color" refusal card omits introduction.md's Google-G
   asterisk. Each is one short paragraph in its one home.
7. **Site guards worth one test each** (site-side, no nokre ask):
   CSS `var(--x)` coverage check at generation (the footer already
   shipped unpadded once from exactly this — main.zig:569's own
   comment); an icon-scan round-trip through a real Emitter (pins the
   PUA-entity spelling the check silently depends on); derive the
   `\e04d` arrow and the `external_attrs` pair instead of re-typing
   them.

## Part D — performance

The frame model stays cheap and the prior verdicts stand (linear
route find, reclaim re-copy, 140-byte Element, at-rest zero CPU).
Four real items, none touching design:

1. **Full-frame `readPixels` copy per frame** — `hsk_surface_pixels`
   (nokre_skia.cpp:269-278) allocates a persistent buffer and copies
   the whole surface every frame; the shell then blits again. A CPU
   raster surface hands out its pixels directly (`peekPixels`) —
   same bytes, satisfying shell.h's "valid until the next callback"
   contract, with a rowBytes assert and the copy as fallback. At
   1200×800@2× that is ~15 MB/frame of pure copy removed. Goldens
   byte-identical by construction.
2. **`services.js` measure cache is unbounded** (:351-368) — keyed
   `font\0text`, cleared only on font-load; a long editing session
   grows it monotonically (every wrap prefix, every keystroke's
   value). It is a pure memo: `if (widths.size > 65536)
   widths.clear();` is always correct.
3. **The DOM edition ignores the dirty flag** — the one shell of six
   that never consults `needs_frame`; live.js then UTF-8-decodes and
   string-compares the whole document per event. A frame generation
   counter exported beside `markup` (bumped at the single swap site,
   live.zig:290-296) lets the glue skip decode-and-compare when
   nothing moved, and `render` may early-return. Modest, honest win;
   closes the six-shells-five-behaviors asymmetry.
4. **`hsk_dither` builds a 2×2 bitmap + shader per scrim call**
   (nokre_skia.cpp:396-414), up to three per frame, for what is
   always `.paper`'s two bytes — a two-entry cache. Ride-along if
   0.4/D1 opens the file.

Recorded so nobody re-litigates blind: wasm 232 KB ReleaseSmall;
desktop 15–18 MB (static Skia + AccessKit + 2.9 MB faces — the link
model's price); lucide.ttf is 843 KB of the site payload and
per-app subsetting is refused (would break "every glyph placeable");
`IconName` comptime verdict unchanged.

## Part E — evidence filed, not proposed

- **Staleness/`Remote(T)`**: load.zig's "nothing further" stance
  predates A8's receipts; A8 presents the evidence and three fixes
  *short of* generation stamps. If the owner holds the line, A8(b)'s
  doc-and-audit steer still applies.
- **ApiClient arrays and `= undefined` wiring**: one-transport-per-
  call stands (doctrine, PORTING/services docs); the 179 `= undefined`
  decls and 35 `wire/unwire` pairs trace to App construction order
  (ctx pointer needed before `App.init` returns). A late
  `app.setBuildCtx` / two-phase init would delete the ritual
  everywhere — logged as a design question, not queued: it reshapes
  every consumer's boot.
- **Number formatting**: org money.zig hand-maintains a per-locale
  decimal-separator table under the comment "nokre formats no
  numbers" — while nokre now ships `dateFromMillis`. The date half of
  that refusal was walked back on evidence; the number half now has
  the same shape of evidence. Policy decision, one owner argument.
- **`.table()` asymmetry**: user app 4 uses, org (admin!) app 0 —
  worth one conversation about whether tables are wrong-shaped or
  undiscoverable for admin lists before any list-idiom work (A7).
- **Notification mock journals only the outbound half** — a tap
  delivered pre-registration leaves no trace, where deep_link
  journals deliberately. No consumer uses notifications yet; add the
  `delivered()` twin or a sentence saying the asymmetry is meant.
- **Consumer placement debt (rokovski's, not nokre's)**: ~1.3k lines
  byte-identical across the two apps with zero nokre imports
  (rules_authz 207, scenario/audit 162, scenario/email 134, more) —
  shared-package moves; plus `fixture.headerValue` vestige, the org
  `open_url` swallow inconsistency (billing loses "portal didn't
  open" while detail.zig handles it), and the dead `refreshConsent`
  node-poke. One rokovski errand pass.

## Part F — migration order

Ordered so nothing lands twice and no compatibility layer exists at
any point. One item per pass, owner review between; contract-visible
passes bump `revision` and move all three pins.

0. **Already applied this pass (uncommitted)**: 0.1 site identity
   line (rebuild deferred to publish order), 0.2 caret clamp + test,
   0.3 emit_css comment. Gates green.
1. ~~**0.4 DOM chrome a11y from the catalog**~~ — DONE, revision 16
   (nokre `d7073e3`, rokovski `599b9b2f`, site `6f76a07`). All four
   arms read the element's own field; no new `Chrome` field and no new
   catalog key — the colon stays markup punctuation. Tests re-pinned
   against `app.chrome.*` plus a Turkish pass over all four arms. The
   predicted published-page churn did not happen: this site runs the
   default chrome, so every one of those strings is byte-identical and
   only `data-n` moved.
2. ~~**0.5 routeless-notice gate**~~ — DONE, revision 17 (nokre
   `65e4ac6`, rokovski `ea7a2c69`, site `cfa2eac`). Owner picked the
   empty string as the one spelling: `Span.route` is `[]const u8 = ""`
   and `Notice.route` gained the default, so `error.EmptySpanRoute` is
   gone — an empty span route *is* how a run says it is prose. No
   golden regeneration was needed anywhere: every existing notice
   golden in all three trees passes a route, so one new golden
   (`notice-banner-routeless`) was minted to give the change a picture.
   Two invariants made literally true on the way: `dupeSpans` no longer
   retains a zero-length consumer pointer, and `tree.zig`'s header
   names the `App.Chrome` strings it borrows by contract instead of
   claiming it never borrows.
3. ~~**0.6 + 0.7 admission sweep**~~ — DONE, revision 18 (nokre
   `aebe154`, rokovski `da58593d`, site `fffd8ed`). Owner picked 0.6's
   stronger form, so there is no family *refusal*: `Style.family` is a
   two-member `BodyFamily` widened at one seam in `Style.face()`, and
   the misuse is a compile error. The wasm clamp is pinned in the node
   harness (the one gate those exports run in); the focus vet lives in
   `deliver(.focus)` and both seams shrank, with assistive-tech focus
   now routed through core instead of writing `focused` directly.
4. ~~**A1 containers**~~ — DONE, revisions 19 and 20 (nokre `9ec8836`
   + `120bed8`, rokovski `e1e8c160`, site `eb5c51e` + `64921a7`).
   −583 consumer lines. The counts were low: 3 named `Str` copies plus
   **22** inline `x_len`/`x_buf` pairs of the same shape, and **46**
   row lists rather than 25 — the handoff counted only the ones with an
   `items()` method. `phase` stayed app-side per the owner steer, which
   costs a second field at each of the 11 lists that embedded it
   (`<field>_phase`). Three parallel-array sites were zipped into row
   structs; `billing`'s `query_ids` deliberately was not (scratch
   derived from the rows, and folding it in would store a pointer into
   a row's own `Str` for `fill`/`removeAt` to invalidate).

   Revision 20 exists because the migration found a defect in the
   container shipped in 19: `Str.set`/`Rows.fill` used `@memcpy` and so
   panicked on a self-aliasing source, which is the natural way to trim
   a field in place — and is what both apps were already doing, using
   `copyForwards` for exactly that reason. The container had quietly
   taken away a safety its hand-rolled predecessor had.

   **Left open, and each needs its own decision:**
   - `truncated` is wired to no user-facing surface. Neither app owns a
     string that could say it, and inventing English inline breaks the
     ARB rule, so ~30 sites are listed in the migration commit for a
     copy pass. Two of them are **not display truncation**: a member's
     fifth permission (`channels.zig`, cap 4) silently loses the
     control it grants, and a dropped `tags.Library` entry (cap 128)
     makes a real tag fail `knows()` and vanish from every channel
     carrying it. Those two are defects, not ceilings.
   - Two caps are unexploded: `family_cap = 4` holds every shipped
     three-letter family, but `compile-tags.go` accepts any non-empty
     family and the testdata already carries `industry` — the fix
     belongs in that Go package's validation. `id_cap = 8` is exact for
     `cat-0001`, so a five-digit id would truncate into a **collision**
     with an existing tag rather than merely losing bytes.
   - `adapters/api_client.zig:371` `keep()` is the same silent-`@min`
     class in the transport, untouched.
5. ~~**A2.1 `bindAs` export**~~ and ~~**A2.2 typed route table**~~ —
   DONE, revision 21 (nokre `c858cb6`, rokovski `93eb6f15`, site
   `1653c39`). Owner scoped both pieces into one pass. The survey said
   30 port callbacks; there are **202**, and all 202 spell the pair the
   same way — which is the argument for hardcoding the field names
   rather than parameterizing them. `bind`/`bindAt` now route through
   `bindAs`, so there is one generator and four hand-written
   trampolines left `element.zig`.

   A2.2 turned out additive and `RouteDef` never moved: `def.build` has
   exactly one call site (`router.zig:596`) passing a single app-wide
   `app.ctx`, and all 91 builders across the three trees cast to their
   tree's one state type — the erasure was never carrying polymorphism.
   `Routes(State).Def` is *reified* from `RouteDef`'s own fields rather
   than mirroring them, so a field added later arrives carrying its
   default instead of being silently dropped. `app.ctx` stays erased:
   typing it means `App` generic over consumer state, and `*App` is in
   the signature of every element call, every service, all six shells
   and the harness.

   **Decided, not deferred**: `dom.Refs` keeps its `{ctx, resolve}`
   spelling and the site keeps its two casts — renaming a contract
   field to fit a helper, or widening the public surface with
   `bindField` for two call sites in one tree, are both worse. The
   reasoning is recorded in `bind.zig`'s module doc so it is not
   re-opened.

   **Left open**: `setHandler(app, ctx, fn)` on five services and
   `workers.Asker.ask(msg, ctx, fn)` take the context and the function
   as two positional arguments, so no pair exists for `bindAs` to fill.
   That is now the largest remaining `?*anyopaque` surface in nokre's
   own API — 9 sites on the published services page, 4 in the tutorial,
   and 6 live casts in the two apps. It wants its own item. Separately,
   `Action`, `Role` and `Span` are reached as `h.element.X` because
   nokre's root re-export roster omits them; the Part B sweep should
   judge that roster as a set rather than promoting one name.
6. ~~**A3 sheet completion**~~ — DONE, revision 22 (nokre `3a5a6c6`,
   rokovski `09fb750a`, site `63f6b18`). Owner decision encoded:
   **Cancel stays enabled while busy** — a disabled Cancel prevented
   nothing, since the × stays live and Esc and the scrim still dismiss,
   so it was a control that lied about what the sheet permits. 21
   confirm sheets converted (not 17); 10 stay hand-written because
   `confirmSheet` requires both a primary and a secondary and a receipt
   or an explainer has only one — converting them would invent a
   control. `closeSheet` needed no new binding: the App is the only
   state the verb takes.

   Three consumer defects fixed in the same pass: a gift code created
   and charged but shown only if a sheet happened to still be up (now
   in the notices ring, code in the title because notices dedup by
   title; regression test pins it), five org failure paths invisible
   after a gesture dismissal, and two `in_progress` flags that could
   never draw because the handler dismissed before raising them.

   **The migration disproved part of its own brief**, which is the
   valuable part: the org failure notices *were* rendered by the screen
   behind. The real mechanism is nokre's — see 6b.
6b. ~~**The three framework dismissals do not rebuild**~~ — DONE,
   revision 23 (nokre `f20e961`, site `c5b7a4c`). Found by A3's
   migration. `App.refresh` declines to rebuild behind a live sheet on
   the stated assumption that "whatever closes the sheet rebuilds"
   (app.zig:438-444), but only `closeSheet` does: the scrim
   (input.zig:264), the pinned × (:387) and Esc (:592) all call
   `dismissSheet`, which does not reload. State written while a sheet
   was up therefore surfaces at a later unrelated reload, detached from
   the action that caused it. An invariant stated in nokre's own
   comment and not enforced anywhere. The three doors now close rather
   than dismiss, and the invariant moved to `closeSheet`, where it is
   enforced. `dismissSheet` stays public and unchanged — it is the
   honest verb for "take the sheet down, I am about to build the screen
   myself", which is how eight consumer sites use it.

   Consumer follow-through (rokovski `a17edcf5`): with the screen
   rebuilding, all seven org failure arms moved back off the notices
   ring — a refusal leaves no residue to carry away, so the surface it
   was refused on is the one that reports it, while the gift code stays
   on the ring because something did happen. `danger.zig` lost its
   notify outright: the two states thought to need it cannot reach it.
   Pre-existing defect found there and left for a decision — `Invites`
   serves two routes and resets its notice only on organization change,
   so a failure leaks across navigation and the org section reports it
   out of context. That is about notice *lifetime*, not channel.

   **A fourth door of the same class, reported and left**:
   `overflow.closeTailSheet` (overflow.zig:283) dismisses without
   rebuilding, so pressing a folded action in the More sheet writes
   state the screen never shows. Its fix is structurally different —
   `closePicker` avoids the bug by removing the layer *before* invoking
   `on_select`, while `activate` must read the element out of the sheet
   it is about to remove — and routing it through `closeSheet` would
   make a folded button behave differently from the same button
   standing. It wants its own item.

   **Also noted, not guarded**: a route builder that unconditionally
   calls `presentSheet` now has an unescapable sheet — Esc closes it,
   the rebuild runs the builder, the builder puts it back. Not new
   (`closeSheet` on a Cancel already had this property, and the
   framework already says a bare `presentSheet` dies on reload), so no
   refusal was added. Owner's call whether it wants one.

7. ~~**A4 harness expect verbs**~~ — nokre DONE, revision 24 (nokre
   `28ba1fc`, site `0b753bb`); consumer test migration in the same
   pass. `takeRequest` became `httpRequest` and *peeks*: none of the
   104 read sites wants removal and 45 answer the request two lines
   later, so taking it out unanswered would strand the app's one-shot
   slot with its busy flag up — the bug the harness exists to catch.
   `body_contains` is a list with an `excludes` twin, and headers are
   three fields, because twelve sites assert an `Authorization` is
   absent and six assert a PoW nonce rode along without asserting its
   random value.

   The value riders needed **no new verb**: `expectValue` already read
   `tile.detail`, `copyable.value` and `qr.value`, and nobody found it
   because its own doc and testing.md both said it only read text
   inputs and segmented controls. Ten raw tree reads existed to work
   around a wrong sentence. Two failure headings that printed
   themselves over silence when nothing was parked now say so.
8. **A5 driver tier** (wait.until* + shared verb names; both Devices
   collapse; org's `describe` improvement lands in the shared home).
9. **A6 Gate + A7 empty branch** (one pass — both are loadGate-family
   vocabulary).
10. **A9 L completion** (Bound.tag/dir/chrome + the fmt binder or
    mixin; the 13 wrappers and 24 unwraps delete).
11. **A8 posture pass** (owner decides the menu first) and **A10
    patch verbs** (owner picks leaf-id vs patch-pair shape).
12. **A11 field-error slot** — element-set argument on its own terms,
    with A12's smaller items and **Part B + C sweeps** closing the
    round once no in-flight migration can collide with renames.

Part E items move only on their own owner-level arguments.
