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
sequence), `selectOption(group_label, option)`, `scroll(id, delta)`,
`focusVia(id)`, `edgePanBack()`.

`selectOption` makes an exclusive choice in a `segmented`, a
`radio_group`, or a `select`, both ends named — the control by its label,
the option by the words on it, never by index:

```zig
try t.selectOption("View", "Compact");     // a track
try t.selectOption("Delivery", "Email");   // a radio group
try t.selectOption("Country", "Japan");    // a select: opens the picker,
                                           // then chooses in it
try t.expectValue("Country", "Japan");
```

It takes the **keyboard** route for all three, and that is the point: a
chip scrolled out of an overflowing track and a picker row below the fold
are both unreachable by a tap at their center, and both are reached by
stepping, because stepping is what scrolls them into view. Every step
goes through real dispatch and commits like a user's, so a handler
watching for `on_select` sees exactly what it would in the app. Choosing
the option already chosen is the no-op it is for a user. The refusals are
the usual ones: `error.NotKeyboardReachable` if Tab can't get to the
control, `error.NotAChoiceControl` if it has no options to choose among
(tap that one instead), and `error.NoSuchOption` — whose diagnostic lists
the options that *are* there, so a renamed option reads as a rename.

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
- `error.InProgress` is the one refusal that is not about reaching the
  control: a `button`, `toggle`, or `checkbox` with `in_progress` set
  keeps its focus stop on purpose, so the check above lets it through and
  the press would land nowhere. Settle the work first, or clear the flag
  if the test meant to press it again.
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

When several requests leave together, a test that names one by its
queue position is asserting issue order it never meant to:
`fulfillHttpPath(suffix, ...)` and `failHttpPath(suffix, name)` answer
the oldest parked request whose URL ends in `suffix`, and
`fulfillHttpLastPath` the newest — the screen that re-asks an endpoint
a sweep behind it already asked. A miss prints every parked URL, so
the failure says what was actually in flight. A request in hand
answers header questions itself: `req.headerValue("Authorization")`.

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
journals, and knobs; why leakage across tests is unrepresentable
rather than merely checked is
[internals/secure_store.md](internals/secure_store.md). Under `zig
test` the fake is the only store that exists, on every platform; the
real keychain is never an option.

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
- `lockStore()` / `unlockStore()` — the keychain locks (or recovers)
  under the running app. Only `error.Unavailable` is injectable, because
  only `Unavailable` is environmental — the other three errors are
  pure functions of the arguments and occur organically: produce
  `InvalidKey` by passing `"Bad Key!"`, `StoreFull` by seeding 256
  entries.
- `t.store.journal()` — every call the app made, in program order, so
  tests assert behavior, not just final state: "signs out without
  rewriting the token" is a journal assertion. Calls that fail
  validation (`InvalidKey`, `ValueTooLarge`) never reach the store on
  any platform and are never journaled; calls the availability knobs
  fail and a `StoreFull` set are.

The `lockStore()` test is table stakes, not an edge case:
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

    try t.lockStore();                         // keychain locks mid-session
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

## The wall clock

`clock` is boot state like the locale, and it is the only clock a test
can reach: under `zig test` the machine's real time is unreachable on
every platform, so a screen that stamps an instant renders identically
every run and goldens byte-for-byte. Time moves where the test moves it
and nowhere else — there is no ticker to move it behind your back.

```zig
var t = try nok.testing.Harness.initWith(gpa, .{ .w = 320, .h = 480 }, .{
    .ctx = &state,
    .build = State.build,
    // The device's clock at boot; the default is a fixed, fake instant.
    .clock = .{ .millis = 1_700_000_000_000 },
});

// "This screen is clockless" — assertable, and true of most of them.
try std.testing.expectEqual(@as(usize, 0), t.clockReads());

try t.tapLabel("Save");      // the action reads it, and keeps what it read
_ = try t.getByLabel("Saved at 1700000000000");

try t.advanceClock(std.time.ms_per_hour);   // an hour passes, because we said
_ = try t.getByLabel("Saved at 1700000000000");  // nothing ran; nothing moved
try t.tapLabel("Save");
_ = try t.getByLabel("Saved at 1700003600000");
```

`advanceClock` takes a **signed** delta, because wall time is not
monotonic: an NTP correction moves a real device backwards, and an app
that subtracts two stamps has to survive a negative difference — this is
the verb that produces one, and the reason there is no monotonic clock
to hide behind ([services.md](services.md)). Nothing on the app's side
runs when it is called: a clock has no handler to route to, so the new
time is simply what the next `now` answers. It still traces and
re-audits like any driver action, so a trace shows *when* time moved.

`clockNow()` is what `clock.now(&app)` would answer, and `clockReads()`
is how many times the app has asked — a count, not a journal, since a
stopped clock answers every read identically. Zero is the interesting
value: "this build never read the clock" is the app-side spelling of
what core promises about itself, and looking through the harness does
not disturb it. A bare test constructs the same fake directly:
`.services = .{ .clock = .mock(.{ .millis = 1_700_000_000_000 }) }`,
with `app.services.clock.advance(ms)` as the untraced verb.

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

## Notices

Notices are the one piece of app state the a11y snapshot cannot speak
for. What is *shown* it covers exactly — the banner, the pane's rows and
the indicator are elements, and `getByLabel` reaches all three — but a
**quiet** notice is pending and unrendered, a title `notify` dropped as a
duplicate leaves no mark at all, and dismiss-all is asserted by an
absence. So these verbs read the app's own pending list, the way
`knocks()` and `urlsOpened()` read a mock's journal: it is the whole
observable effect ([elements.md](elements.md#notice)).

```zig
try t.tapLabel("Sync");
try t.failHttp("FetchFailed");            // the app raised a notice

try t.expectNotified("Sync failed");      // raised — banner, pane, or quiet
_ = try t.getByLabel("Sync failed");      // …and this one is on screen

// Quiet notices never claim the banner: the only thing rendered is the
// chrome's own indicator, so the title is assertable *only* here.
try t.expectNotified("Draft saved");
try t.expectAbsent("Draft saved");
_ = try t.getByLabel("Show notices");

const pending = t.noticesPending();        // important first, then arrival
try std.testing.expectEqualStrings("Sync failed", pending[0].title);
try std.testing.expect(pending[0].important);
try std.testing.expectEqualStrings("Changes kept locally.", pending[0].description);
try std.testing.expectEqualStrings("home", pending[0].route);
```

`expectNotified(title)` is the whole of "was it raised": titles are the
identity — `notify` dedups on them — so a second `notify` under a title
already pending is dropped in silence, and the count is the only witness
that it was:

```zig
try std.testing.expectEqual(@as(usize, 1), t.noticesPending().len);
```

`dismissNotice(title)` and `dismissAllNotices()` are the **app-side**
dismissals — `App.dismissNoticeAt` and `App.dismissAllNotices`, the
notice that clears itself when the state behind it resolves. Both trace
and re-audit, so the chrome the dismissal reshaped is asserted like any
other screen. A dismissal a *user* performs is a press like any other and
stays one: `tapLabel("Dismiss: Sync failed")` on the control the chrome
puts on every notice, `tapLabel("Dismiss all notices")` in the pane's
header. Dismissing by title and never by index is the query rule again —
an index is a position in a list nobody perceives.

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
- `notificationsRequested()` — everything the app asked the OS to do,
  in order, from the journaling notification mock: posts and schedules
  (told apart by `at_millis`), cancels, the permission prompt, and the
  token request. A refused call never appears, because the OS was never
  asked, and `askedToNotify()` is the assertion behind "this screen
  posted without ever asking". What the *user* did is the test's to
  drive: `grantNotifications()` and `denyNotifications()` answer the
  prompt — or flip the switch in Settings without one, which is legal
  and worth testing — `deliverNotificationTap(.{ .id = …, .route = … })` is the tap
  (call it first to write the launch that started from one),
  `deliverNotification` the same payload coming due with the app on
  screen, and `deliverPushToken(token)` is the transport minting one.
  Boot a device that cannot notify, cannot schedule, or cannot push with
  `.notification = .{ .available = false }` and its siblings, and assert
  the app drew around it.
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
PPM frame per step through the production renderer, with identical
numbering, so `.txt` and `.ppm` traces pair file-for-file. Custom sinks
implement `trace.StepObserver`.

## Golden screenshot tests

Byte-exact frame comparison against committed PPM (P6) files — viewable
with almost any image tool. PPM rather than PGM because the frame is
RGB for the one colored mark nokre draws (the Google G — see
[internals/pixel-model.md](internals/pixel-model.md)); everything else
is r=g=b, so diffs read like the gray ones did.

Goldens need the Skia prebuilt linked into the *test* binary — a link
`addApp` does not make, because a test binary is not the app binary. One
line of `build.zig` does it (`nokre.linkSkia`), and the whole recipe —
that line, the `-Dgolden` / `-Dupdate-goldens` options, and the module
that carries them — is
[getting-started.md](getting-started.md#part-12--proof-tree-snapshots-step-traces-goldens).

```zig
try t.expectGolden("tests/goldens/checkout.ppm",
    .{ .update = build_options.update_goldens });
```

One verb does the whole take: a Skia surface at the app's viewport, the
real Skia measurer swapped in (the fixed measurer's glyph positions
match no device), one render through the production pipeline, and the
byte-exact comparison. `.update` is how `-Dupdate-goldens` reaches the
library — an argument on the assertion, not module state, threaded from
your build through an options module (the recipe linked above). A
custom surface — another scale, pixels you produced yourself — drops
one layer to `nok.testing.golden.expectMatches`, which takes the same
options.

Workflow:

1. Creation and regeneration are explicit: only a run with
   `-Dupdate-goldens` (alongside `-Dskia -Dgolden`) creates a missing
   golden or rewrites a mismatched one in place. Without the flag a
   missing golden **fails** with `error.GoldenMissing` — so CI, which
   never passes the flag, can neither mint a new baseline nor silently
   heal a lost one into a pass.
2. First run with the flag creates the golden and reports it — review
   the image, commit it.
3. On mismatch the test fails and writes `<name>.actual.ppm` next to the
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
  keychain and browser-session code is not merely unused, it is
  not compiled into the test binary. So the mocks are contracts asserted
  against themselves — their fidelity to the platform is asserted by
  nothing *in this harness*. (The one exception is http's native
  transport, which is pure Zig over a socket and gets its own gate
  below.)

This is a deliberate boundary, not an oversight. The determinism this
document keeps promising — no flakiness, byte-exact frames, races
reproduced identically every run — holds *because* the nondeterministic
layer is excluded. Widening the harness to reach through a real window
and a real socket would buy a little coverage and lose the property the
whole design is built on. The gap is nokre's to close on its own side,
in its own tier — never by making your tests heavier.

That tier now has five gates, all of them on every `zig build test`:

| gate | what reaches a real implementation |
| --- | --- |
| `tests/dev_store.zig` | the secure_store verbs, against a store the OS answers (desktop POSIX) |
| `src/services/http/native_test.zig` | the native http transport's six verbs, over a real loopback socket inside the test binary |
| `tests/http_stress.zig` | the native http transport's threads, against a loopback socket |
| `node --check` × 5 | every JavaScript file a web build ships, parsed by the engine that runs it |
| `tests/web_services.mjs` | the three service legs that exist **only** on the web, executed |

The last one is the newest and the least obvious, so it is spelled out
below. What no gate reaches is still a real list: the native backends of
secure_store (Keychain, CredMan, libsecret, the Android Keystore),
oauth's `ASWebAuthenticationSession` and its Android and loopback legs,
all four notification systems, StoreKit and Play Billing, and every
shell's event translation. `zig build check-targets` compiles them; the
examples link two of them; nothing runs them.

### The web's own gate

`zig build test` builds `tests/web_services.zig` — an ordinary nokre app
with deep_link, oauth and secure_store linked — into a site the same way
`addApp` builds a consumer's, then boots that site in node against
`tests/web_browser.mjs`, a browser stub carrying nothing but platform
APIs (a document, a location, a session storage, a window that can open
another and be posted to). The JavaScript under test is the site's own
`live.js` and `services.js`, imported unmodified; every assertion reads
back what the *wasm app* recorded through probe exports. So the seam
that breaks — bytes crossing between Zig and JavaScript — is executed
rather than analyzed:

- **deep_link** — a launch fragment reaches the handler the app
  registered in its first `build`, exactly once; every later
  `hashchange` reaches it too; and a percent-encoded payload with
  multi-byte characters arrives byte for byte.
- **oauth** — a press opens the popup with the app's authorize URL and
  the page's own address as the redirect; the popup's `postMessage` ends
  the flow and the callback URL lands whole; a message from another
  origin, from another window on this origin, or of another shape is
  refused, and the genuine one after them still works; a blocked popup
  arrives as `PopupBlocked` a task later and never synchronously; a
  popup the user closes arrives as `cancelled` after the poll's grace;
  `Handle.cancel` closes the popup and delivers nothing; and a page URL
  over the redirect cap seeds nothing, so the first sign-in fails with
  `RedirectTooLong` instead of sending a truncated URI.
- **secure_store** — the sessionStorage snapshot lands in the in-wasm
  table before the first `build` reads it; entries from another
  namespace, out-of-contract keys and values that do not decode are
  dropped at the door; writes and deletes mirror out under the one
  prefix, with base64 carrying bytes a string cannot; a value survives a
  reload and a deleted one does not come back; and a storage that is
  blocked or full costs reload-survival and nothing else — the table
  still answers, which is why this leg has no `Unavailable`.

What that gate is **not** is a browser. Layout, styling, the real event
loop, a real popup's window management and a real storage's quota
behaviour are the stub's approximations, and nothing there asserts how a
page *looks* or where text wrapped — the golden tests are that, on the
desktop editions. Still uncovered on the web specifically: the compute
worker (`live-worker.js` in a real `Worker`), the service worker
(`sw.js`, and therefore the notification leg), the http leg's `fetch`,
the static driver's hydration handover, and IME and scrolling, which
belong to the browser rather than to a service. Those remain
browser-only, asserted by no test on either side.

Practically, for your app: an integration bug in nokre's shell or in a
native service backend will not fail your test suite. Everything above
`App.dispatch` will.

## Driving an app outside `zig test`

That own tier is a *driver*: an ordinary executable that constructs a
real `App`, drives it, and reaches the real services — the program
shape a shell is, minus the window. It is not the harness with a flag
turned on, and deliberately not:

- **`Harness` stays inside `zig test`.** Its whole value is that every
  field is a mock (`t.store`, `lockStore`, the http handler),
  and mocks exist only under `builtin.is_test` — `Service =
  if (is_test) Mock else PlatformService` is the roster's rule, not one
  service's. A `Harness` that compiled in a release build would have to
  carry every mock into it, which is the exact thing that rule exists to
  make unrepresentable. So the seam is one layer down.
- **The driver layer already is that seam.** `testing.driver`,
  `testing.queries`, `testing.audit`, `testing.trace` and
  `testing.golden` name no `builtin.is_test` at all and are exported
  unconditionally. `driver.tap(app, id)`,
  `queries.queryByLabel(&app.tree, …)` and `audit.audit(app)` work on
  any `*App`, in any build.

Two things a driver owes that a test does not. It owes the hooks a
shell owes — `nokre_locale_install` and its pair at minimum, plus
`nokre_open_url_open` and `nokre_shell_write_clipboard` if its screens
reach them — exported by the program itself, answering the way a shell
with nothing to report does. And it owes the `App` a fixed address: a
press handler holds a `*App`, so build the app into storage that
outlives the call rather than returning one by value (`Harness` keeps it
as a field for exactly that reason).

A driver may hold **more than one `App` at a time**, and often should:
two devices in one process is how a scenario signs out as one user and
in as another. Nothing in nokre is process-global on an app's behalf —
the exemptions are the shared `std.Io.Threaded` backends
([internals/architecture.md](internals/architecture.md) lists them),
and they are refcounted so that two apps share one and the last one out
tears it down. Two apps' networks, stores and worker rosters are
disjoint by construction. The concurrency a second app adds is the same
concurrency one app fanning out requests adds, and the http transport
carries a gate of its own for it
([internals/http.md](internals/http.md#no-pool-under-the-native-transport)):
`tests/http_stress.zig`, two apps at 1920 real requests, on every
`zig build test`.

The one service a driver cannot simply use as it stands is
`secure_store`, and it has its own answer: `.secure_store_dev = true`
swaps the Keychain or the Secret Service for a plaintext file the driver
owns, because an unentitled binary is refused the data-protection
keychain and a headless CI machine runs no keyring daemon
([services.md](services.md) has the gates that keep it out of a shipping
build). nokre's own `tests/dev_store.zig` is a worked example of the
whole shape, and it runs on every `zig build test` on a desktop POSIX
host — the one place in the repository where the store verbs reach a
store the OS answers. `tests/http_stress.zig` is the second worked
example, and the other half of the same tier: the one place where the
http verbs reach a socket the OS answers. `tests/web_services.zig` is
the third, in the one place a driver cannot be a Zig program at all —
the browser, where half of every service leg is JavaScript, so the
driver is `tests/web_services.mjs` and the app it drives is a wasm site.

What nokre tests for *itself* — and the guarantees those tests prove on
your behalf — is catalogued in
[internals/contributing.md](internals/contributing.md).
