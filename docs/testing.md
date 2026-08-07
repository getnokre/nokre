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
    // A screen is written against your state (routing.md), so a fixture
    // lowers it exactly as a route table does.
    var t = try nok.testing.Harness.init(gpa, .{ .w = 480, .h = 640 }, .{
        .ctx = &state,
        .build = nok.Routes(State).builder(buildCheckout),
    });
    // or routed: .{ .routes = &routes, .ctx = &state, .initial_route = "home" }
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

Four verbs sit above those primitives, because every consumer ends up
wanting exactly them — both shipped apps wrote the same ones, with
the same fallbacks, before they moved here. Each names its control by
**role plus accessible name**: a bare label stops being an identity
the moment the chosen locale can change under it.

They live one layer below the harness, in `testing.driver`, as free
functions over `*App` that name no mock — because a *driver* against a
real server needs the same four and can never hold a `Harness`
([below](#driving-an-app-outside-zig-test)). The harness adds a trace
step and a re-audit around each; a driver adds a wait in front. The
ladder itself is written once.

- `press(role, label)` presses a control the way a user would: a tap
  where it is on screen, Tab-and-Enter where a long screen has pushed
  it past the fold (stepping is what scrolls it into view), and
  More-then-the-action where a narrow row folded it away
  ([elements.md](elements.md#the-folded-tail-more)). Not for text
  fields — the keyboard fallback's Enter in a field it just focused is
  a submit, not a focus; that is `typeInto`'s job. `tap`'s other
  refusals stand: an obscured, disabled, or busy control is still a
  loud failure, because no fallback reaches one of those.
- `typeInto(label, text)` puts the caret in the named field and types,
  appending like typing does. The label is looked up among the two
  text-entry roles only (`text_input`, `text_area`), so the words can
  never land on a control that merely shares them.
- `clearField(label)` empties that field the way a user empties one: to
  the end, then back over what is there. `clearField` then `typeInto`
  is "leave this field holding exactly this" — two acts, because they
  are two acts for a user, and a fixture whose fields start empty needs
  only the second. It counts *bytes* as its budget, so a field holding
  multi-byte text is emptied rather than nearly emptied, and it re-reads
  the field by label between keystrokes, so a screen that rebuilds on
  every edit does not strand it on a stale node.
- `goTab(title)` crosses the nav to the destination with that title,
  whichever shape the nav is in
  ([elements.md](elements.md#navigation-chrome)): the
  row of destinations where the labels fit, the collapsed chip's
  picker where they do not, and the `nav_here` marker when the title
  is the screen already under foot — that marker is deliberately not a
  control, so going where you stand is a no-op, not a refusal. The
  chip is addressed through the app's chrome, so a localized app
  crosses its bar in its own words.

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
watching for `on_select` sees exactly what it would in the app — and
the control is re-found by role and name between steps, so a screen
that reloads itself on every commit does not strand the walk on a node
id that commit retired. Choosing the option already chosen is the no-op
it is for a user. The refusals are
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

The observing side names a request the same way — and refuses the same
way, with the queue printed rather than a bare integer:

```zig
try t.expectRequest("/api/notes", .{});          // it was asked at all
try t.expectRequest("https://api.test/api/notes/n-1/share", .{
    .method = .POST,                              // a whole URL is a suffix
    .body_contains = &.{"\"to\":\"bob@acme.com\""}, // of itself, so the locator
    .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    .headers_present = &.{"X-PoW-Nonce"},         // …is also the assertion
    .headers_absent = &.{"Authorization"},        // anonymous: no token rode along
});
try t.expectNoRequest("/api/circles");            // the refusal sent nothing
try t.expectNoPendingHttp();                      // everything asked was answered
```

`RequestExpectation`'s fields are lists because one request routinely
earns several: `body` pins it whole, `body_contains` /`body_excludes`
probe the fragments that carry the decision, and the three header
fields are exact pair, name-that-must-have-ridden (a proof-of-work
nonce, whose value is random), and name-that-must-not-have. Every
failure names the request first — `POST https://…/share: expected no
"Authorization" header, but it carries "Bearer jwt-1"` — because the
queue position the test did not write down cannot say which call this
was.

Two more for the arithmetic assertions cannot make:
`httpPending(suffix)` counts what is parked, all of it (`null`) or one
path's share — "the retry asked once, not once per attempt" —  and
`httpRequest(suffix)` hands the request over for what no field can
spell: a digest over the body, a header parsed as a number, the
proof-of-work a server would verify. It **peeks** — reading what was
sent is what a test does immediately before answering it, and taking
the request out of the queue would leave the app waiting on a result
that can never arrive.

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
    var t = try nok.testing.Harness.init(gpa, .{ .w = 480, .h = 640 }, .{ .ctx = &state, .build = nok.Routes(State).builder(buildNotes) });
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

Boot state goes in at construction: `init(gpa, viewport, opts)` takes
a `.store` of type `secure_store.Mock.Config` (seeds plus
availability) alongside `build`/`routes` and the `.locale`
below — one options struct, one door, nothing to choose between.
Seeds apply inside
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
    var t = try nok.testing.Harness.init(std.testing.allocator, .{ .w = 480, .h = 640 }, .{ .store = .{ .seeds = &.{.{ .key = "auth.token", .value = "tk_123" }} }, .ctx = &state, .build = nok.Routes(State).builder(State.build) });
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
them: `init`'s `.locale` applies inside `App.init`, so the first
`build` already reads the tag. There is no frame before the locale
arrives — no shell produces one — so there is no such state for a test
to rehearse.

```zig
var t = try nok.testing.Harness.init(gpa, .{ .w = 480, .h = 640 }, .{
    .ctx = &state,
    .build = nok.Routes(State).builder(State.build),
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
var t = try nok.testing.Harness.init(gpa, .{ .w = 320, .h = 480 }, .{
    .ctx = &state,
    .build = nok.Routes(State).builder(State.build),
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
`init`'s `.oauth` carries the seeds — and, optionally, `.auto`,
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

var t = try Harness.init(gpa, .{ .w = 320, .h = 480 }, .{
    .ctx = &state,
    .build = nok.Routes(State).builder(buildPaywall),
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
- `expectValue(label, expected)` — whatever the control's a11y node
  reports as its *value*, which is more than a field's text: the
  selected option of a segmented control, a select or a radio group, a
  tile's detail line, the string a `copyable` puts on the clipboard,
  the URL a `qr` encodes, the section a collapsed nav chip stands on.
  If a screen reader would announce it as the value, this reads it —
  reaching into `tree.getConst(id).?.tile.detail` asserts the same
  bytes through a door the audit does not watch.
- `expectProblem(label, expected)` — what a field says is wrong with
  its value (`TextInput.problem`), read the way assistive tech gets it:
  the node's *description*, with `invalid` asserted alongside. Both,
  because the pair is the point — a test that compared only the words
  would pass on a message nothing was told to associate with the field,
  which is the whole state the slot exists to abolish. The empty string
  is the assertion that a field is **clean**, which is the shape the
  other half of every validation test wants: a form that refused a
  value and then accepted the correction.
- `expectRoute(route)` — the screen on top ([routing.md](routing.md));
  pair it with `app.router.depth()` when the depth is the point, since
  a push and a `switchTo` land on the same route
- `expectAbsent(label)`
- `expectPresent(role, name)` — absence's positive twin, by semantic
  identity: presence claimed by role plus accessible name, and a miss
  lists every labeled node on screen.
- `expectDisabled(label)` — a control that declines rather than acts,
  read off the node instead of pressed or typed into: the driver
  refuses a disabled control loudly, and a diagnostic from a passing
  test reads as a failure to whoever is watching the build. Located
  **by label across element kinds**, the way `expectBusy` is: a button
  is not the only thing that can be disabled — the two text fields
  carry `TextInput.disabled` — and a form that stands its fields down
  while the submission is on the wire had no assertion to make about
  them while this verb was buttons-only. An element that cannot be
  disabled at all says so rather than reporting a placid "enabled".
- `expectEnabled(label)` — its twin, for the assertion that a form
  armed: proving "the last field enabled Save" by pressing Save would
  submit the form to prove it. Also the assertion that a reply came
  back and handed the fields to the user again.
- `expectBusy(label, expected)` — a control with work in flight: the
  state `in_progress` draws and a `nokre.Gate` produces. Located **by
  label across element kinds**, the way `expectValue` and
  `expectDisabled` are, because buttons are not the only things that work —
  a toggle and a checkbox carry `in_progress` too, and half the tests
  that used to reach into the raw tree for it were reading toggles. The
  polarity is an argument, like `expectChecked`'s, because both answers
  are assertions: that the press started the work, and that the reply
  landed and cleared it. An element that cannot be busy at all — a
  paragraph wearing the control's words — says so rather than reporting
  a placid "not busy".

  Busy is not disabled and not a value. A control with work in flight
  keeps its focus stop and still reads what the server holds, so
  `expectBusy("Share snapshot", true)` and
  `expectChecked("Share snapshot", false)` are the honest pair for a
  switch that has been flipped but not yet answered.

  **`Device` has no twin for this one**, and the omission is the
  decision. The harness owns the clock — a mock reply lands at a
  `fulfill*` verb and not before — so "busy" is a state a unit test
  *holds*. A live driver holds nothing: the work may finish before the
  driver looks, so a wait for busy is a wait on a transient — the flake
  the `Device` section's wait rule was written to end. A scenario
  against a real server waits for what the work produced.
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

Every refusal above prints its diagnostic through `testing.diag`, the
one stderr gate — so a test that *expects* a failure mutes it
(`diag.quiet = true;` in a block scope) and `zig build test` stays
silent when green. A test that wants to assert the words rather than
only the error installs a `diag.Capture` instead: `said.start();`,
`defer said.stop();`, then `said.text()`. Muting proves a verb failed;
capturing proves it said something a reader could act on.

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
frame per step through the production renderer, with identical
numbering, so the two pair file-for-file. Its `take` says on what terms
— `.{ .scale = 2, .format = .png }`; PNG by default, because the reader
this exists for often cannot open a PPM, and `scale` is the hi-DPI knob
`Surface.init` has always had. A take also installs the Skia measurer if
the app is not already on it, for `expectGolden`'s reason: the fixed
measurer's glyph positions match no device.

`startTrace` takes one observer, so both instruments on one run go
through `trace.Tee`, which fans a step out in order:

```zig
var tee: nok.testing.trace.Tee = .{ .sinks = &.{ trees.observer(), frames.observer() } };
try t.startTrace(tee.observer());
```

Custom sinks implement `trace.StepObserver`.

## Golden screenshot tests

Byte-exact frame comparison against committed PPM (P6) files — viewable
with almost any image tool. PPM rather than PGM because the frame is
RGB for the one colored mark nokre draws (the Google G — see
[internals/pixel-model.md](internals/pixel-model.md)); everything else
is r=g=b, so diffs read like the gray ones did.

Goldens need the Skia prebuilt linked into the *test* binary — a link
`addApp` does not make, because a test binary is not the app binary. One
call in `build.zig` does all of it (`nokre.addGoldenTests`: the module,
that link, and the run), and the whole recipe — the call, the `-Dgolden`
/ `-Dupdate-goldens` options, and what each of them is for — is
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

That tier now has six gates, five on every `zig build test` and one on
every `zig build test -Dskia`:

| gate | what reaches a real implementation |
| --- | --- |
| `tests/dev_store.zig` | the secure_store verbs, against a store the OS answers (desktop POSIX) |
| `src/services/http/native_test.zig` | the native http transport's six verbs, over a real loopback socket inside the test binary |
| `tests/http_stress.zig` | the native http transport's threads, against a loopback socket |
| `tests/capture.zig` | a `Device`-driven app's artifacts, out of a process with no window — and the PNG read back by a decoder that is not the encoder (`-Dskia`, desktop) |
| `node --check` × 5 | every JavaScript file a web build ships, parsed by the engine that runs it |
| `tests/web_services.mjs` | the three service legs that exist **only** on the web, executed |

The web one is the least obvious, so it is spelled out below.
What no gate reaches is still a real list: the native backends of
secure_store (Keychain, CredMan, libsecret, the Android Keystore),
oauth's `ASWebAuthenticationSession` and its Android and loopback legs,
all four notification systems, StoreKit and Play Billing, and every
shell's event translation. `zig build check-targets` compiles them; the
examples link two of them; nothing runs them.

### The web's own gate

`zig build test` builds `tests/web_services.zig` — an ordinary nokre app
with deep_link, oauth and secure_store linked, a two-locale ARB bundle
behind its screens and a nav roster over them — into a site the same way
`addApp` builds a consumer's, then boots that site in node against
`tests/web_browser.mjs`, a browser stub carrying nothing but platform
APIs (a document, a location, a session storage, a window that can open
another and be posted to) — plus the one security model a *page* can
state, since a served file's Content-Security-Policy is read at
`openPage` and enforced on everything requested after it. The JavaScript under test is the site's own
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
- **locale** — the seed lane reaches the first `build`, and the two
  sources are held against each other: a page that says nothing about a
  language boots in the browser's; a page that pins one boots in *its*
  own, words and direction both, in a browser set to another; the empty
  tag pins the catalog's template rather than meaning "ask the device";
  a pinned tag the bundle does not carry falls back exactly where the
  same tag falls back on the device lane; and a `languagechange` after
  boot moves a page that was following the device and never a pinned
  one. The assertions read the rendered words out of the document and
  the direction off `documentElement`, so the claim is what a reader
  would see and not what an export returned.
- **the document** — the arrangement every static consumer boots in,
  which nothing else here has: two mount points and `addressing:
  "documents"`, over a page that already shows the screen. Two module
  instances run as the pair the two drivers are: the first writes the
  file with `dom.document` out of its own tree, the second boots over
  the parsed result. The assertion is **node identity** — every child
  the file put in both mounts is the same object afterwards — because
  that is what "boot is a patch rather than a repaint" means and the
  markup afterwards looks identical either way. Then a press on a
  segmented chip, which must reach the app *and* land a repaint: the
  probe says which chip core believes is chosen, and the sentence under
  the control is written by `build`, so it only moves if the screen was
  rebuilt and patched in.
- **the document, from a generator with a history** — the same handover
  where the generator has *already written other pages*, which is every
  page of a static site but the first and the case the scenario above
  cannot reach. A generator is one app and one tree, and each screen it
  publishes spends the tree's slot allocator, so the `data-n` in the
  file it writes second is not the one a browser booting that file
  arrives at — the handover was a replacement on 3,377 of rokovski.com's
  3,378 pages and looked perfectly right afterwards. What is asserted is
  the contract rather than the mechanism, deliberately: the ids in the
  frame **must** differ from the ids in the file — that is what proves
  the app rebuilt its tree at all, and reading id equality as health
  gets it exactly backwards — *and* the control the reader had tabbed to
  before the module landed must still be `document.activeElement`. Focus
  survives only if the element does, so the second assertion is the
  scroll, selection and caret claim as well, made on the one term this
  harness can observe directly.
- **the boot** — the same page again, booted by *the file the page asks
  for* rather than by a `mount` call the harness typed. Every scenario
  above hands `mount` an option object written in JavaScript, so until
  this one the page's own half of the boot — the `<script src>` it
  names, the `application/json` block it states, and the module that
  reads them — was the half nothing executed. Here the file is swept for
  any `<script` that is neither a `src` nor a data block, the named
  module is resolved to a file the site actually serves, and it is
  imported with nothing passed in; when the import resolves the app is
  running, and a press on the segmented chip has to change the sentence
  `build` writes under it. It is the gate on the claim that a site of
  these pages can be served under `script-src 'self'`: the arrangement
  is checked by reading in Zig and *run* here, and the two together are
  what say the page still boots with no executable byte in it.

  It is also the gate on the **policy** that claim was made for. The
  page these scenarios open states one (`Document.csp`), and the browser
  stub reads it off the file it is served and holds every request after
  it against the directives — so both boots above happen *under* the
  policy their page published, and a directive dropped from nokre's
  derivation stops being an argument about a string and becomes
  `Refused to load app.wasm` in a scenario that was mounting an app.
  That is the failure a derived policy has, and it is the one thing
  about it no Zig test can reach.

- **the nav's two shapes** — the one place the *tree* and the *sheet*
  are held against each other, which is where three releases running
  shipped a nav that passed its tests and looked wrong in a browser. The
  stylesheet the build just wrote is parsed and its cascade resolved at
  a width, the way a browser resolves it; the app is booted at the same
  width through the shipped `live.js` and re-measured by the resize
  event a reader's drag fires; and the assertion is that the two agree
  about what is on screen. Above the pane cap, at six widths, the sheet
  wraps the header and the tree must be a row of six — a sweep rather
  than one number, because the defect lived in a *band* of widths and
  any single one could have missed it. Below the cap the sheet is the
  band and the tree is the chip, and dragging back must reopen the row,
  because what a reader hits is a drag and not a load. Then the band's
  overflow answer from both sides: the row must resolve to a scroll
  container packed to the start — a centred one's leading overflow
  cannot be reached — and the file a generator published must hold every
  destination as a link with an address of its own, six of them, all
  distinct, none of them bare `#`. And the derivation: the screen
  holding a button and a segmented control cannot be published without a
  runtime (`PageNeedsBoot`), the screen of prose and links publishes
  whole with no script at all, and a module on a page that needs none is
  never refused.
- **the tile's two forms** — the derivation's own input, on the shape
  that caught it out. A hub of rows that all carry routes must publish
  with no module at all and three anchors in it, each reaching
  somewhere; the same group with one `on_press` row must be
  `PageNeedsBoot`, and booted must hold the button and the anchor beside
  each other. Both halves, because either alone is the wrong fix — a
  `tile` that never needed a runtime would publish a page of dead rows.
- **the footer, and the reserve under it** — the sheet's arithmetic
  against the sheet's own geometry, and the second place the tree and
  the sheet are held against each other. The band's height is computed
  from the resolved `:root` properties (`var()` followed, `calc()`
  evaluated, `env()` standing down to its fallback), and the reserve
  must exceed it by the gap nothing may rest inside. Then the file: a
  page whose footer is a `stack` of `link`s must have three elements in
  its body and no class on it — nothing stands outside the screen in a
  page nokre wrote whole — with the stack last inside the screen, every
  anchor in it carrying nokre's own classes and a `data-n` the tree
  knows, the two internal destinations resolved through `Refs` and the
  external one wearing the new-tab pair. And at 375px the reserve must
  resolve onto the screen the footer is inside. It is one scenario
  because it is one claim: a footer in the tree is styled, cleared,
  resolved and audited, and no rule in the library grants any of it.
  The footer carries a **language row** too — what a footer actually has
  on a site published in more than one language — and it is asserted
  here rather than only in a unit test because an attribute in a string
  comparison is a string and an attribute on a parsed document is an
  anchor with a language: each of the three must carry the tag of the
  language its own words are in (`element.Link.lang`, WCAG 3.1.2), the
  document root must still carry the page's own and not any of theirs,
  and the links beside them that are not part of the set must carry no
  `lang` at all.
- **a link and the keyboard, under `documents`** — the one scenario
  about two handlers *agreeing*. The click handler passed every
  `a[href]` to the browser and the keydown handler passed none, so a
  press reached the file and Enter reached core, which refuses a
  destination the route table cannot spell. The footer's language row is
  that destination on every real site — a locale's copy of a page is not
  a route — so the row worked with a pointer and did nothing with a
  keyboard: WCAG 2.1.1 Keyboard, level A. The assertion is what a
  browser would do next, read off the event: a `focusin` puts the reader
  on the anchor the way Tab does, and the keydown that follows must come
  back **uncancelled**, which is the browser following the href and the
  only way that page is ever reached. Then the three boundaries, because
  a fix that took more than it should would pass the first line and fail
  a reader anyway: the click on the same anchor is uncancelled too,
  Space over it is still core's — no browser activates a link with it,
  so handing it over would navigate nothing and cost every link core
  *can* honor its activation — and the same screen mounted as an app
  shell still cancels Enter and still lands on `#terms`, because there
  the destination was always core's to reach.

What that gate is **not** is a browser. Layout, styling, the real event
loop, a real popup's window management and a real storage's quota
behaviour are the stub's approximations, and nothing there asserts how a
page *looks* or where text wrapped — the golden tests are that, on the
desktop editions. The nav and reserve scenarios are the nearest thing to
an exception and the line is worth stating exactly: they resolve the
cascade and evaluate the lengths the sheet declares, both of which are
facts about the sheet's own bytes, and they compute **no box**. That an
`overflow-x: auto` row *scrolls* is the browser's business; that the row
is one, and that every destination is in the markup with somewhere to
go, is nokre's. That 96px of padding renders as 96 pixels is the
browser's; that the number the sheet asks for covers the band the sheet
also describes is nokre's. Still uncovered on the web
specifically: the compute
worker (`live-worker.js` in a real `Worker`), the service worker
(`sw.js`, and therefore the notification leg), the http leg's `fetch`,
and IME and scrolling, which belong to the browser rather than to a
service. Those remain browser-only, asserted by no test on either side.

### The locale stub's own gate

The other JavaScript nokre ships is one function, and it is the only
place in the library where a decision nokre owns is stated *twice*.
`dom.localeStub` writes the page at an unprefixed path on a
locale-prefixed site, and the script in it has to resolve the reader's
`navigator.language` against the bundled locale set exactly the way
`Bundle.resolve` does — but it cannot call it. `resolve` is comptime
Zig, and the stub loads no wasm on purpose: a redirect that first
fetches an app is a redirect nobody waits for. So
`src/render/dom/locale-stub.js` transcribes the algorithm, and a
transcription with nothing under it is two policies waiting to disagree.

`zig build test` runs both halves against each other.
`tests/locale_stub.zig` — a native program, host-run like the dev store
and the http stress — writes one real stub page and, beside it, the
locale `L.resolve` gives for each of 27 device tags: exact matches in
both cases and both separators, region and script subtags under a
bundled language, languages the bundle does not carry, and the shapes a
browser with nothing to say produces. `tests/locale_stub.mjs` then
executes **that page's own script** once per tag, against a `location`
and a `navigator` of its own, and asserts it navigates where Zig said it
would.

"That page's own script" is now two halves, and the gate takes both the
way a browser does. The chooser is a *file* the site serves, so the
check resolves the `<script src>` the page wrote, holds that name
against the file this repository ships, and executes those bytes; its
one argument is the `application/json` block the emitter wrote above the
tag, read out of the page and parsed rather than restated. So a stub
that named a file nobody publishes, or escaped its data wrongly, fails
here — and the gate also sweeps every `<script` on the page and refuses
one that is neither a `src` nor a data block, which is the page's half
of the claim that a site of these can be served under
`script-src 'self'`.

Neither file states an expected locale. The bundle states them, so a
change to the resolution rule moves both sides at once and a change to
one of them alone fails the build.

**The bundle is three locales and its own, and the third one is the
whole reason.** `resolve`'s middle pass is bare language **in bundle
order**, and with no two locales sharing a language that loop has a
single candidate — so `findIndex`, `findLastIndex` and an object's own
key order all answer alike, and the one line most likely to drift is
the one line nothing executes. So `tests/l10n/stub_*.arb` lists `fa-AF`
*before* `fa`, and a browser reporting `fa-IR` has two candidates and
must land on the earlier — deliberately the answer a transcription that
scanned backwards, or that preferred the bare tag, would get wrong.
That the bundle can still pose the question is itself asserted, so a
later edit cannot quietly return the branch to being uncovered. It is a
bundle of its own rather than the web harness's pair because that one
is the locale service's gate and is about something else.

The same run asserts what the page owes a reader whose script never ran
— a plain link per locale, marked with its `hreflang` — and the two
properties the script carries that a hand-rolled redirect drops
silently: the query and the fragment reach the destination, and a stub
standing at one of its own choices navigates nowhere rather than
spinning the browser.

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
  `testing.queries`, `testing.audit`, `testing.trace`, `testing.wait`,
  `testing.device` and `testing.golden` name no `builtin.is_test` at
  all and are exported unconditionally. `driver.tap(app, id)`,
  `queries.queryByLabel(&app.tree, …)` and `audit.audit(app)` work on
  any `*App`, in any build — and so, therefore, do the four verbs the
  harness builds on them ([above](#input-driver)).

### Waiting is the only real difference

A driver's synchronization story is different from the harness's, and
`testing.wait` owns it. Under the mocks nothing ever waits — every
settle is a verb — but a real server answers when it answers, so a
driver's only move is "pump until the screen says what it came to say,
or a deadline passes". `wait.waitUntil(app, pacer, what, ready)` is
that loop, once: it pumps the delivery queue, asks the predicate after
each pump, and on timeout prints what was waited for plus the whole
screen as it stands — route, every labeled element with its
user-visible state (working, disabled, folded), pending notices, and
the laid-out tree — then returns `error.WaitTimeout`. The `Pacer` is
the driver's own clock and its own nap, handed in as function
pointers: nokre reads no wall clock and sleeps no thread itself, which
keeps the library deterministic and makes the timeout path itself
testable against a fake clock.

The conditions **nokre can evaluate for itself** are shipped, one verb
each, so no driver writes them again. Each answers what it found, so
the wait and the lookup are one call:

| verb | holds when |
| --- | --- |
| `untilLabel(app, pacer, label) !NodeId` | an element carries exactly that accessible label |
| `untilRole(app, pacer, role, name) !NodeId` | a control of that role carries that name — the wait `press` synchronizes on |
| `untilLabelContaining(app, pacer, needle) !NodeId` | some label contains the needle |
| `untilEither(app, pacer, a, b) ![]const u8` | either label is there; answers which, so a fork can branch |
| `untilAnyRole(app, pacer, roles, name) !NodeId` | any of those roles carries that name — a control *family*, which is what the acting verbs address |
| `untilGone(app, pacer, label)` | that label has left the screen |
| `untilRoute(app, pacer, ref)` | the router stands on that route |
| `untilNotice(app, pacer, title)` | a notice with that title is pending |
| `untilDestination(app, pacer, title)` | the nav can answer for that destination — `nav_item`, `nav_here`, or the collapsed chip |
| `untilEnabled` / `untilDisabled(app, pacer, label)` | that button takes presses, or has stopped |
| `untilValue(app, pacer, label, expected)` | the control with that label *reads* that value on the a11y snapshot |
| `untilProblem(app, pacer, label, expected)` | the field with that label states that problem — or, for `""`, has come clean |

Everything else is a condition about **your** state — a work queue
draining, a prefetch sweep finishing — and reaches the same loop
through `wait.Ready`, a `{ ctx, call }` pair that
[`bindAs`](elements.md#binding-callbacks-nokre-never-sees) fills from an
ordinary method. There is no `@ptrCast` to write and no wrapper struct
per condition:

```zig
// fn quiet(self: *State, _: *nokre.App) bool { return self.solver.pending() == 0; }
try wait.waitUntil(&app, pacer, "the proof queue to drain",
    nokre.bindAs(wait.Ready, State.quiet, &state));
```

A timeout owes two things, and every one of these pays both — what it
was waiting for, in the caller's own words, and the screen that stood
there instead:

```
waited 60000ms for a button named "Continue"; the screen stands at:
  on route "circle~4821"
  heading "Ada's circle"
  button "Retry" (working)
  text "Something went wrong."
  notice "Sync failed"
  …the laid-out tree…
```

`wait.dumpScreen(app)` is that same picture on demand, for the driver's
own refusal paths — a tap that could not land owes the reader the
screen it could not land on.

### `Device`: the harness's verbs over a live app

`testing.Device` is what a driver holds where a test holds a
`Harness`: a `*App`, a `Pacer`, and **the harness's own verb names
running the harness's own ladders**, each with a wait in front. It is
not a copy of the harness and not a parallel vocabulary — `press`,
`typeInto`, `clearField`, `selectOption`, `goTab`, `expectPresent`,
`expectAbsent`, `expectGone`, `expectRoute`, `expectValue`,
`expectProblem`, `expectDisabled`, `expectEnabled`, `expectNotified`
mean here exactly
what they mean in a unit test,
because the ladder under each is the same function in `testing.driver`.
A third edition's driver is a `Device` and a domain vocabulary, not a
third transcription of this file.

```zig
pub const Device = struct {
    app: *nokre.App,
    pacer: nokre.testing.wait.Pacer,
    notes: ?nokre.testing.device.Notes = null,
};

var d: nokre.testing.Device = .{ .app = &self.app, .pacer = self.pacer() };
try d.press(.button, "Sign in");
try d.clearField("Email");
try d.typeInto("Email", "ada@example.com");
try d.expectPresent(.heading, "Your circles");
try d.expectRoute("circles");
```

Three rules the set follows, each of them a decision:

- **Every acting verb re-audits**, exactly as the harness's do. That is
  what makes driving by accessible name safe: two live controls sharing
  a label fail at the audit rather than silently taking the first.
- **`press` checks the fold without waiting.** A control its row folded
  away is invisible to every query, so waiting a full deadline to
  discover that — and another for a "More" that is not there either —
  is how one missing label costs an hour. Folded first, then the wait.
- **`expectAbsent` never waits, `expectGone` does.** A label that is
  *going* to appear would satisfy a waiting absence check for as long
  as it took to arrive; the only absence it is honest to wait for is
  one that was on screen when the action was taken.
- **Every other verb waits for the thing it acts on or asserts
  against**, not for something weaker nearby. `typeInto` and
  `clearField` wait for a `text_input` or `text_area` with that label,
  never for the label — prose carrying the same words would end the
  wait and strand the verb. Both then refuse a field that is
  `disabled` by name rather than letting the tab walk time out: a field
  out of the focus order is not unreachable by accident, and a test
  that meant to fill it is asserting against a form still in flight. `selectOption` waits for a choice control
  the same way. `goTab` waits for the bar to be able to answer for the
  destination in any of its three shapes. `expectValue` waits for the
  **value**, `expectProblem` for the **reason**, and
  `expectEnabled`/`expectDisabled` for the **state**: a
  screen revisited against a real server stands there with the last
  answer in it, a field is unmarked and plausible for the whole time
  the submission that will refuse it is in flight, and the control —
  button or field — is on screen for the whole time the reply that
  hands it back is in flight. `settled` and `quiesce` are the two that
  deliberately do not wait — one audits the frame an action produced,
  the other is a bare deadline.

One lifetime rule, because it has already caught a caller.
`labelContaining` hands back bytes **borrowed from the tree**, and
every verb on this type pumps — a pump delivers a reply, a reply
rebuilds the screen, and the rebuild frees them. Copy the slice before
the next call, not "eventually". `valueOf` is the verb that allocates
into an allocator you name and hands you memory you own; `untilEither`
answers one of the two slices you passed it, so it is yours already;
and a `NodeId` from a `until*` verb is a tree position with a
generation on it, so one used after a rebuild reads back as absent
rather than as the wrong control.

`Device.notes` is the seam for what nokre cannot know. Bind it to a
method of your own and it prints under the framework's screen dump on
any refusal — the proofs still queued, the load phases behind a screen
that never filled in. nokre says what is on the screen; the driver says
what is behind it.

Two verbs a driver keeps for itself. `quiesce(millis)` ships (it is a
deadline, not a condition — the verb of last resort, and every use of
it is a screen that should have said something), but "the app is
finished working" is app state: a proof-of-work queue, a background
sweep, a retry ladder. That is a `waitUntil` with your own bound
predicate, and it belongs in your driver beside your domain verbs.

Two things a driver owes that a test does not. It owes the hooks a
shell owes — the free C functions the services name, which a binary
with no shell must still resolve. nokre ships that shell:
`testing.shell` defines all of them, and naming it in the driver is the
whole install —

```zig
comptime {
    _ = nokre.testing.shell;
}
```

Each hook answers the way a shell with nothing to report does, except
the three where a screen's outcome would otherwise vanish: what was
last written to the clipboard, handed to a share sheet, or opened as an
outbound URL is recorded, and the driver reads it back with
`testing.shell.lastCopied()`, `lastShared()`, and `lastOpened()` —
empty when the hook never fired, last write wins, matching the platform
mocks' recordings under `zig test`. Never name it in a windowed build:
its definitions and the real shell's collide at link time, which is
exactly the guard. It also owns no loop — pumping `app.runtime.pump()`
stays the driver's job, on the driver's own deadlines. And a driver
owes the `App` a fixed address: a
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

### Seeing a screen nobody watched

Every other instrument in this document is a comparison or an assertion.
`expectGolden` is byte-exact against a committed baseline, the verbs
above assert and refuse, and all of them answer *whether* — none of them
can show you an unexpected state. For anything surprising — a screen
that renders a heading and then nothing — the answer used to be to
launch the windowed app and look at it, which is not an answer at all
for a driver on a machine with no display, or for an agent that cannot
close the window it opened.

`Device.startTrace` is the same seam a `Harness` has, one tier up, and
it is the answer. The observers are the same ones ([above](#step-traces)),
the numbering is the same, and the step names are the harness's for the
same verbs — a `Device` scenario's trace reads like a unit test's.

```zig
var trees  = try nok.testing.trace.TreeSink.init(io, .cwd(), gpa, "zig-out/inspect");
var frames = try nok.render.skia.PixelSink.init(io, .cwd(), gpa, "zig-out/inspect");
frames.take = .{ .scale = 2, .format = .png };
var tee: nok.testing.trace.Tee = .{ .sinks = &.{ trees.observer(), frames.observer() } };
try d.startTrace(tee.observer());          // 0000-init.txt + 0000-init.png

try d.typeInto("Email", "ada@example.com"); // 0001-type-into-Email.*
try d.press(.button, "Continue");           // 0002-press-Continue.*
try d.step("after the reply landed");       // 0003-after-the-reply-landed.*
```

Four things about this are decisions rather than defaults:

- **The artifacts are kept unconditionally**, pass or fail, at a path
  the driver names. This is the opposite of a golden, and deliberately:
  a golden writes nothing on success because it answers "did this
  match", and there is nothing to keep when the answer is yes. The
  question here is "what is on the screen", it has no baseline, and the
  run worth reading is usually the one that failed. `zig-out/inspect` is
  the convention nokre's own gate follows; the library imposes none, so
  a driver that wants one directory per scenario writes one.
- **The text tree is the primary instrument.** A raster says something
  looks wrong; the tree says *what* — whether the screen mounted,
  whether a subtree is empty, whether a node exists with no size — and
  it is greppable, diffable, and small enough to paste into a report.
  Take the raster when the tree is not enough, not the other way round.
- **PNG, not PPM, by default.** A person's image viewer opens either; an
  agent's image-reading tool opens PNG and JPEG and cannot open a P6
  PPM, and an artifact its reader cannot open is not an instrument.
  Goldens stay PPM — they are compared, not looked at, and their
  byte-exactness is load-bearing.
- **`step` is for the gaps.** The acting verbs number their own steps;
  `step(action)` is how a driver marks a moment those do not cover —
  after a wait with no action behind it, or at the top of a scenario.

**What this costs a consumer's build.** The tree half costs nothing:
`testing.trace` is pure Zig and rides in on the nokre module a driver
already imports. The raster half needs the Skia prebuilt *on the driver
binary*, which `addApp` does not link — for `expectGolden`'s reason, a
driver binary is not the app binary. One line in the consumer's
`build.zig`, beside where the e2e executable is created:

```zig
nokre.linkSkia(nokre_dep, e2e_exe);
```

That is the whole change, and it is the consumer's to make: a driver
that never names `PixelSink` should not carry a 40 MB archive it does
not use, so nokre cannot make the link on its behalf. Everything about
the raster path is the golden path's machinery — `SkSurfaces::Raster`,
no window, no display server, CoreText/CoreGraphics on macOS — so a
driver that already runs headless keeps running headless.
`render.skia.capture` is the one-shot underneath `PixelSink`: one app,
one path, one `Take`, no numbering, for a driver that wants a named
frame rather than a trace.

`tests/capture.zig` is the worked example and the gate, on every
`zig build test -Dskia`.

What nokre tests for *itself* — and the guarantees those tests prove on
your behalf — is catalogued in
[internals/contributing.md](internals/contributing.md).
