# Testing

nokre ships its own app-level e2e framework because the library controls
the whole pipeline — there is nothing a browser-driver-style tool could
reach that the harness can't reach more faithfully. It spans your whole
app; where it stops, and why that is the right place to stop, is
[below](#where-the-harness-stops).

The framework is asymmetric on purpose: **interactions go through the
user's pipeline, assertions go through the screen reader's.** Input is
dispatched exactly as a shell would dispatch it; state is asserted from
the a11y snapshot, so a test can only verify what assistive tech could
perceive. And the a11y audit is not a habit — the harness runs it at init
and after every action.

Everything below runs headless. Only golden tests need Skia.

## Harness

```zig
const nok = @import("nokre");

test "checkout flow" {
    var t = try nok.testing.Harness.init(gpa, .{ .w = 480, .h = 640 }, &state, buildCheckout);
    // or: initWithRoutes(gpa, viewport, &routes, &state, "home")
    defer t.deinit();
    // The a11y audit already ran; a screen that fails it never builds.

    try t.tapLabel("Add to cart");
    try t.focusVia(try t.getByLabel("Coupon"));   // Tab-cycles like a real user
    try t.typeText("SAVE10");
    try t.pressKey(.enter, .{});
    try t.expectValue("Coupon", "SAVE10");
}
```

The harness owns a real `App` — the identical layout, focus, and event
dispatch used in production. Layout uses the deterministic fixed measurer
by default, so structural tests need no native code at all.

Every app is constructed with its services — the harness builds the
mocks from its init options. A bare non-harness test constructs them
itself, and under `zig test` omitting them is a compile error, so no
test depends on state it didn't declare:

```zig
var app = try nok.App.init(gpa, .{
    .viewport = .{ .w = 480, .h = 640 },
    .services = .mocks(),   // default mocks; configure per-service to seed
});
defer app.deinit();
```

Release builds keep the default — shells and examples never name
`.services`.

## Queries

Queries address elements by their **semantics** — if an element is hard
to query, it is also inaccessible, and construction or the audit will
have already told you so.

- `getByLabel(label)` (exact), `getByLabelContaining(needle)`,
  `getByRole(role, name)` — role plus accessible name, never an index:
  users don't perceive tree positions. A failed `get*` returns
  `error.NoSuchElement` after printing every labeled node on screen, so
  a typo diagnoses itself.
- `queryByLabel` / `queryByRole` return `null` instead of failing — the
  tool for asserting absence (or use `expectAbsent`).
- `focusedLabel()` names the focused node — or, when an inline link
  holds focus, the link's own words.
- `queryLink(words)` finds an inline link (a span with a destination,
  see [markdown.md](markdown.md)). Link spans are controls without nodes of
  their own, so they come back as focus stops rather than `NodeId`s;
  the `get*` diagnostics list them alongside everything else, so a link
  never goes missing from a failure message.

## Input driver

`tap(id)`, `tapLabel`, `tapLink(stop)`, `pressKey`, `typeText`,
`composeText(composition, committed)` (full IME start→update→commit
sequence), `scroll(id, delta)`, `focusVia(id)`, `edgePanBack()`.

`edgePanBack` is the whole back gesture — in from the leading edge, past
the threshold, released ([routing.md](routing.md#the-back-gesture)). A
test about the *threshold* rather than the navigation dispatches
`.edge_pan` steps itself and reads `knocks()`, the journal of haptic
crossings the gesture fired.

`tapLabel` reaches inline links too: to a user a link is just a control
with those words on it, so it answers to the same verb as a button.

The driver refuses actions a user couldn't perform — a synthetic input
that silently lands elsewhere is a lie, not a test:

- `tap` hit-tests the target's center through real dispatch and fails
  with `error.NotInteractive` (static or disabled), `error.NotVisible`
  (scrolled out of view or clipped — scroll first, like a user would),
  `error.Obscured` (the tap would land on another element, which the
  diagnostic names), or `error.Folded` (its row ran out of width and
  folded it behind "More" — press More first, like a user would; see
  [elements.md](elements.md#the-folded-tail-more)). A folded action is
  off the screen, so `getByLabel` does not return it either — the
  listing that comes back says where it went.
- `focusVia` fails with `error.NotKeyboardReachable` if Tab can't reach
  the node — a test that passes only with a mouse is a bug.

One action is not an input: `settleWorkers()` runs every queued worker
message and delivers every queued reply
([internals/workers.md](internals/workers.md)). Workers run inline under
the harness, so async work lands exactly when the test says — send, then
type, then settle *is* the race, reproduced identically every run.

The network gets the same treatment: under the harness an
`http.request` parks instead of touching any socket, and the test
supplies the response — the canned answer *is* the network
([internals/http.md](internals/http.md)). `fulfillHttp(.{ .status,
.headers, .body })` answers the oldest parked request and lands the
result at that exact moment; `failHttp(name)` is the offline case in
one call; `t.app.services.http.pendingAt(i)` asserts what the app
actually sent (method, URL, headers, body — owned copies). The parked
requests live in this app's mock — its fake network, constructed with
the app — so two concurrently-driven apps are two disjoint networks,
no filtering required. A test that taps, types, and *then* fulfills
has reproduced the slow-server race, every run:

```zig
try t.tapLabel("Reload");            // issues http.request — and parks it
_ = try t.getByLabel("Loading…");    // the in-flight state is real UI, assert it
const req = t.app.services.http.pendingAt(0);
try std.testing.expectEqualStrings("https://api.example.com/notes", req.url);
try t.fulfillHttp(.{ .status = 200, .body = "[\"milk\"]" });
_ = try t.getByLabel("milk");        // the response landed exactly here

try t.tapLabel("Reload");
try t.failHttp("FetchFailed");       // the offline case, one line
_ = try t.getByLabel("You're offline");
```

`fulfillHttpAt(i, ...)` and `failHttpAt(i, name)` answer by index
instead of oldest-first, so completion order is the test's to choose —
the stale-response race is answering index 1 before index 0, and the
app must cope:

```zig
try t.typeText("a");                 // request 0: results for "a"
try t.typeText("b");                 // request 1: results for "ab"
try t.fulfillHttpAt(1, .{ .status = 200, .body = "[\"abacus\"]" });
try t.fulfillHttpAt(0, .{ .status = 200, .body = "[\"apple\", \"abacus\"]" });
_ = try t.getByLabel("abacus");      // the stale answer arrived last —
try t.expectAbsent("apple");         // — and lost
```

For flows with many requests, `onHttp(ctx, handler)` installs a fake
server: a function from a parked request to a canned response, a
failure name, or null — leave it parked. `settleHttp()` runs it over
this app's pending requests to quiescence, each answer landing before
the next ask, so a callback that issues a follow-up request has it
served in the same settle:

```zig
fn serve(_: ?*anyopaque, req: nok.services.http.PendingRequest) ?nok.testing.HttpOutcome {
    if (std.mem.endsWith(u8, req.url, "/notes"))
        return .{ .respond = .{ .status = 200, .body = "[\"milk\"]" } };
    if (req.method == .POST)
        return .{ .respond = .{ .status = 201 } };
    return .{ .fail = "FetchFailed" };   // everything unrouted: offline
}

test "sync round-trip" {
    var t = try nok.testing.Harness.init(gpa, .{ .w = 480, .h = 640 }, &state, buildNotes);
    defer t.deinit();
    t.onHttp(null, serve);

    try t.tapLabel("Sync");   // however many requests the flow issues,
    try t.settleHttp();       // chained follow-ups included, serve answers now
    _ = try t.getByLabel("Synced");
}
```

Delivery stays an explicit move — the handler never answers on its
own, and what it declines stays parked for `fulfillHttpAt` to answer
by hand. A bare test can skip the harness entirely: construct the app
with `.services = .{ .http = .mock(.{ .handler = serve }) }` and the
fake server is defined where the app is; `app.services.http.settle()`
runs it.

## The store

`secure_store` gets the opposite treatment, because its contract is
the opposite of http's: the store is synchronous, so a call completes
at the call — there is nothing to park, settle, or reorder, and the
harness deliberately offers no `onStore` handler and no
`fulfillStoreAt`. An out-of-order surface here would let tests
rehearse interleavings production cannot produce.

Configure nothing and the fake is simply a working, empty keychain:
`set`/`get`/`delete`/`list` round-trip for real, keys come back sorted,
and the real caps apply. An app that merely *uses* the store needs no
setup at all — a bare `Harness.init` already gives it somewhere to keep a
token. The seeds, journal, and knobs below are what you add when the
store is the *subject* of the test rather than a dependency of it.

Every app owns a fake store — constructed with it, dead with it at
`deinit` — and the harness aliases it as `t.store`. Two
concurrently-driven apps get two fakes with disjoint entries,
journals, and knobs, by construction: the state is a field of the app,
not a module, so nothing *can* leak across tests. Under `zig test` the
fake is the only store that exists, on every platform; the real
keychain is never an option.

Boot state goes in at construction: the general `initWith(gpa,
viewport, opts)` takes a `.store` of type `secure_store.Mock.Config`
(seeds plus availability) alongside `build`/`routes` and the `.locale`
below, and `initWithStore(gpa, viewport, boot, ctx, build)` is the
shorthand for the common plain-screen case. Seeds apply inside
`App.init`, so a seeded token is readable inside `build`,
synchronously — harness or no harness; `.available = false` boots the
app into a locked keychain. After boot:

- `seedStore(key, value)` — the token that appears mid-session. It
  enforces the real caps, so a test cannot seed a state no device
  could hold; a forbidden seed is a test bug, loudly.
- `expectStored(key, expected)` / `expectStoredAbsent(key)` — assert
  persisted state directly off the fake. No app code runs and nothing
  settles: sync means there is nothing to settle.
- `setStoreAvailable(bool)` — the keychain locks (or recovers) under
  the running app. Only `error.Unavailable` is injectable, because
  only `Unavailable` is environmental — the other three errors are
  pure functions of the arguments and occur organically: produce
  `InvalidKey` by passing `"Bad Key!"`, `StoreFull` by seeding 64
  entries.
- `t.store.journal()` — every call the app made, in program order, so
  tests assert behavior, not just final state: "signs out without
  rewriting the token" is a journal assertion. Calls that fail
  validation (`InvalidKey`, `ValueTooLarge`) never reach the store on
  any platform and are never journaled; calls the availability knobs
  fail and a `StoreFull` set are.

The `setStoreAvailable(false)` test is table stakes, not an edge case:
a locked keychain, an absent Secret Service session on Linux, or a
Keystore fault on Android all surface as `Unavailable`, and an app
that degrades gracefully under it is ready everywhere.

```zig
test "stored token skips sign-in; sign-out deletes it; locked keychain degrades" {
    var state: State = .{};
    var t = try nok.testing.Harness.initWithStore(std.testing.allocator, .{ .w = 480, .h = 640 },
        .{ .seeds = &.{.{ .key = "auth.token", .value = "tk_123" }} }, &state, State.build);
    defer t.deinit(); // the fake dies here — nothing leaks to the next test

    _ = try t.getByLabel("Inbox");             // boot read is sync: no settle, no loading frame

    try t.tapLabel("Sign out");
    try t.expectStoredAbsent("auth.token");    // the delete really landed
    // one get at boot, one delete — the app never rewrote the secret:
    try std.testing.expectEqual(@as(usize, 2), t.store.journal().len);

    try t.setStoreAvailable(false);            // keychain locks mid-session
    try t.tapLabel("Sign in");                 // the handler's set fails -> error.Unavailable
    _ = try t.getByLabel("Signed in — couldn't save your session");
    try t.expectStoredAbsent("auth.token");    // and nothing leaked into the store
}
```

Bare non-harness tests construct the same thing directly — the mock
is the binding, nothing to install or pair:

```zig
var app = try App.init(gpa, .{
    .viewport = .{ .w = 480, .h = 640 },
    .services = .{ .secure_store = .mock(.{
        .seeds = &.{.{ .key = "auth.token", .value = "tk_123" }},
    }) },
});
defer app.deinit(); // the fake dies with the app
const fake = app.services.secure_store.state.?; // journal, knobs, peek
```

Why a sync store needs no settle at all is
[internals/secure_store.md](internals/secure_store.md).

## The device locale

`locale` is boot state like the store's seeds, and synchronous like
them: `initWith`'s `.locale` applies inside `App.init`, so the first
`build` already reads the tag. There is no frame before the locale
arrives — no shell produces one — so there is no such state for a test
to rehearse.

```zig
var t = try nok.testing.Harness.initWith(gpa, .{ .w = 480, .h = 640 }, .{
    .ctx = &state,
    .build = State.build,
    .locale = .{ .tag = "fa-IR" },       // the device at boot; the default
});                                      // "" is "the platform said nothing"
_ = try t.getByLabel("صندوق ورودی");      // resolve picked .fa in the first build

try t.changeLocale("de-CH");             // the OS switches mid-session
try std.testing.expectEqualStrings("de-CH", t.deviceLocale());
try std.testing.expectEqual(nok.l10n.Direction.ltr, t.app.direction); // un-mirrored
try std.testing.expectEqual(@as(usize, 2), t.localesSeen().len);  // boot + 1
```

`changeLocale` routes to the app's registered handler on the spot,
then traces and re-audits like any driver action — nothing parks and
nothing settles. What the handler re-resolved reaches the *screen* on
the next rebuild, though, not on the call: a device gets one from the
shell's next frame, a routed harness from its next `navigate`, and a
single-screen `.build` harness builds once — so assert the state and
direction the handler set, and re-render where a rebuild actually
happens. `localesSeen()` is every tag the device reported,
boot tag first, which is what turns "the app never read the boot
locale" into an assertion; it records the *effective* tag, so one past
the 64-byte cap appears as the `""` the app actually saw
([services.md](services.md)). An app that only reads the tag registers
no handler at all — `t.app.services.locale.hasHandler()` is false, and
a `changeLocale` then is a change nothing was wired to notice, exactly
as on a device. A bare test constructs the same fake directly:
`.services = .{ .locale = .mock(.{ .tag = "fa-IR" }) }`, with
`app.services.locale.change(tag)` as the untraced verb.

Under `zig test` the mock is the only locale source, on every
platform — the machine's real locale is unreachable — so even a
locale-dependent screen stays byte-deterministic in a golden test. A
*running* app is a different matter, which is why nokre's own
examples carry their locale in state instead of asking the device.

## Sign-in

`oauth` parks like `http` and settles like it: `start` leaves from an
action, the flow waits in this app's mock, and nothing moves until the
test says what the user did. The browser is a test input.

```zig
try t.tapLabel("Sign in");                 // the app's handler called oauth.start

// What the app actually asked for — the assertion surface for scopes
// and the PKCE challenge, not a hope.
const asked = t.authorizations();
try std.testing.expectEqual(@as(usize, 1), asked.len);
try std.testing.expect(std.mem.indexOf(u8, asked[0].url, "code_challenge=") != null);

try t.completeAuth("com.example.notes:/callback?code=granted&state=s");
_ = try t.getByLabel("Inbox");             // the screen the handler produced
```

Three verbs for the three ways a flow ends: `completeAuth(url)` is the
browser redirecting, `cancelAuth()` is the user dismissing the sheet
(a first-class outcome — an app that strands its user on a spinner
afterwards fails here rather than in a bug report), and
`failAuth(name)` is the offline case, `failHttp`'s twin for the flow's
first half. Each lands the result now and re-audits, so the screen the
app's handler produced is asserted through the a11y snapshot like any
other action.

PKCE is seeded, not random: `pkce.verifier(app, &buf)` and
`pkce.state(app, &buf)` read the mock, so a screen that renders an
authorize URL renders the same one every run and goldens byte-match.
`initWith`'s `.oauth` carries the seeds — and, optionally, `.auto`,
which answers every flow without a settle verb for tests where the
sign-in is setup rather than subject:

```zig
.oauth = .{ .auto = .{ .callback = "com.example.notes:/callback?code=seeded" } },
```

A bare test constructs the same fake directly: `.services = .{ .oauth =
.mock(.{}) }`, with `app.services.oauth.complete(url)` as the untraced
verb (followed by `app.runtime.pumpAll()`, which the harness verbs do
for you).

## Purchases

`iap` seeds like the store and settles like `http`. The catalog is
config — prices are strings the test writes down, so a paywall renders
byte-identically every run — and the payment sheet is a test input.

```zig
const shelf = [_]nokre.services.iap.Product{.{
    .id = "coins.100",
    .title = "100 coins",
    .description = "A hundred coins.",
    .price = "$4.99",          // the store's formatting; nokre's never
    .currency = "USD",
    .offer = "",
    .price_micros = 4_990_000,
    .kind = .consumable,
}};

var t = try Harness.initWith(gpa, .{ .w = 320, .h = 480 }, .{
    .ctx = &state,
    .build = buildPaywall,
    .iap = .{ .catalog = &shelf },    // a seeded catalog answers queries
});

_ = try t.getByLabel("$4.99");        // the price the store formatted
try t.tapLabel("Buy coins");          // the app's handler called iap.purchase
try t.deliverPurchase(.{ .id = "txn-1", .product = "coins.100",
                         .token = "opaque", .state = .purchased });

// The assertion that catches the bug nobody sees until a refund.
try t.expectFinished("txn-1", .consumed);
try std.testing.expectEqualStrings("coins.100", t.purchases()[0].product);
```

The verbs name what a *store* does, never what the app asked for —
because a purchase arrives whether or not this launch requested one:
`deliverPurchase(p)` is both the answer to a live sheet and the
unsolicited case (an Ask-to-Buy approval, a renewal, a restore replay, an
interrupted purchase redelivered at launch — write that test),
`cancelPurchase()` is the user dismissing the sheet, `failPurchase(name)`
is the declined card, and `deliverProducts(rows)` / `failProducts(name)`
answer a query the seeded catalog left parked. Each lands the result now
and re-audits.

Nothing here says "store": that word is `secure_store`'s in this harness,
and two services sharing it would read as one.

`.iap`'s other two knobs are the ones a paywall test needs:
`.available = false` boots the app onto a storeless platform — Windows,
Linux, the web, a restricted device — where `available` is false and
every verb is `error.Unavailable`, which is the branch an app most often
forgets; and `.auto` answers every sheet without a settle verb, with a
seeded transaction id (`nokre-test-txn-1`) for tests where the purchase
is setup rather than subject:

```zig
.iap = .{ .catalog = &shelf, .auto = .purchased },
```

A bare test constructs the same fake directly: `.services = .{ .iap =
.mock(.{}) }`, with `app.services.iap.deliverPurchase(p)` as the untraced
verb (followed by `app.runtime.pumpAll()`).

## Assertions

State assertions read the **a11y snapshot**, not element internals: if an
expectation can't be met there, a screen reader user can't meet it either.

- `expectFocused(label)`
- `expectChecked(label, expected)`
- `expectValue(label, expected)` — text-input value or the selected
  option of a segmented control
- `expectRoute(route)` — the screen on top ([routing.md](routing.md));
  pair it with `app.router.depth()` when the depth is the point, since
  a push and a `switchTo` land on the same route
- `expectAbsent(label)`
- `expectCopied(text)` — the most recent clipboard write, read from
  the app's journaling clipboard mock: "activating this copyable wrote
  X", first class. Sync, like the store — nothing settles.
- `urlsOpened()` — every URL the app handed to the system browser, in
  order, from the journaling open_url mock: "pressing this external
  link asked the OS for X". Sync and fire-and-forget — the journal is
  the whole observable effect, and a scheme the allowlist rejected
  never appears in it.
- `sharesShown()` — every text the app put on the OS share sheet, in
  order, from the journaling share mock — open_url's rules exactly: a
  refused share (empty, over-cap, or a sheetless boot) never appears.
  Boot a sheetless target with `.share = .{ .available = false }` (the
  Linux desktop, a browser without `navigator.share`) and assert the
  app drew no share affordance.
- `expectTree(expected)` — inline snapshot of the whole laid-out tree in
  the trace format below. On mismatch both trees print; review the
  actual, then paste it into the test.

`a11ySnapshot(gpa)` returns the raw snapshot for anything bespoke.

## A11y audit

Automatic: it runs at harness init and after every driver action — rules
in [accessibility.md](accessibility.md). Most misuse is already
unrepresentable (`tree.append` rejects malformed structure at the call
site); the audit covers whole-tree content rules and post-construction
mutation. Diagnostics name the offending node; `collect()` returns
violations programmatically. Call `t.audit()` manually only after
mutating the tree by hand.

## Step traces

Optional per-step observability, replacing what headful debugging or
screen recording would give: every driver action emits a numbered,
action-named snapshot. Off by default — a step costs one null check —
and because tests are deterministic, you re-run a failing test with
tracing on and get the identical run.

```zig
var sink = try nok.testing.trace.TreeSink.init(io, dir, gpa, "trace");
try t.startTrace(sink.observer());   // writes 0000-init.txt
try t.tapLabel("Show done");         // writes 0001-tap-Show-done.txt
```

`TreeSink` (pure Zig, no Skia) writes the laid-out tree per step — role,
rect, label, state, focus marker per node — diffable with plain `diff`:

```
viewport 480x640 light
stack [0,0,480,640]
  heading [16,16,448,29] "Todo" level=1
  text_input [16,53,448,58] "New item" value="" cursor=0
  toggle [16,119,125,24] "Show done" on focused
```

`nok.render.skia.PixelSink` (requires `-Dskia`) is the pixel twin: one
PGM frame per step through the production renderer, with identical
numbering, so `.txt` and `.pgm` traces pair file-for-file. Custom sinks
implement `trace.StepObserver`.

## Golden screenshot tests

Byte-exact frame comparison against committed PGM (P5) files — viewable
with almost any image tool.

```zig
var surface = try nok.render.skia.Surface.init(480, 640, 1);
defer surface.deinit();
t.app.measurer = nok.render.skia.measurer();  // real text metrics
t.app.invalidate();
t.renderTo(surface.canvas());
try nok.testing.golden.expectMatches(gpa, surface.pixels(),
    surface.pixelWidth(), surface.pixelHeight(), "tests/goldens/checkout.pgm");
```

Workflow:

1. Creation and regeneration are explicit: only a run with
   `-Dupdate-goldens` (alongside `-Dskia -Dgolden`) creates a missing
   golden or rewrites a mismatched one in place. Without the flag a
   missing golden **fails** with `error.GoldenMissing` — so CI, which
   never passes the flag, can neither mint a new baseline nor silently
   heal a lost one into a pass.
2. First run with the flag creates the golden and reports it — review
   the image, commit it.
3. On mismatch the test fails and writes `<name>.actual.pgm` next to the
   golden for eyeball diffing. If the change is intended, rerun with
   `-Dupdate-goldens` to rewrite the golden, then review the diff and
   commit.
4. There is no tolerance and no perceptual diffing, deliberately. The
   pixel model ([internals/pixel-model.md](internals/pixel-model.md))
   makes exactness cheap; any variance is a bug by definition.

## Where the harness stops

"End to end" is relative to whose system is under test. For **your app**
the harness is exactly that: routing, focus, editing, IME, layout, scroll,
overlays, worker scheduling, and network races all run for real, and
nokre underneath is a dependency the way Chrome is a dependency of a
browser test. For **nokre itself** the same harness is an integration
test, because two hops are substituted rather than executed:

- **The shell.** The driver delivers events to `App.dispatch` and reads
  the frame back, which is precisely where a platform shell would sit.
  What a shell does either side of that line — translating an
  `NSEvent`/`MSG`/Wayland callback into an `Event`, and blitting the
  returned buffer — no test executes. `zig build check-targets`
  compile-checks all six; that is the whole of it.
- **The real services.** Under `zig test` a service *is* its mock:
  `Service = if (builtin.is_test) Mock else PlatformService`. The real
  keychain, socket, and browser-session code is not merely unused, it is
  not compiled into the test binary. So the mocks are contracts asserted
  against themselves — their fidelity to the platform is asserted by
  nothing here.

This is a deliberate boundary, not an oversight. The determinism this
document keeps promising — no flakiness, byte-exact frames, races
reproduced identically every run — holds *because* the nondeterministic
layer is excluded. Widening the harness to reach through a real window
and a real socket would buy a little coverage and lose the property the
whole design is built on. The gap is real, and it is nokre's to close on
its own side, in its own tier — never by making your tests heavier.

Practically, for your app: an integration bug in nokre's shell or in a
real service backend will not fail your test suite. Everything above
`App.dispatch` will.

What nokre tests for *itself* — and the guarantees those tests prove on
your behalf — is catalogued in
[internals/contributing.md](internals/contributing.md).
