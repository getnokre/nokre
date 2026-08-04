# The iap service

Status: **working** — this file is the design, written before the code so the
expensive decisions were argued once, and amended after it with what the code
actually settled ([oauth.md](oauth.md)'s method). The roster row in
[../services.md](../services.md) is the status of record and carries the
consumer contract.

`iap` is alone on the roster for a reason the other rows do not share:
it is the only service that genuinely requires a per-platform SDK.
[oauth.md](oauth.md) opened by disputing the then-roadmap's grouping of
OAuth with IAP as "both drag in per-platform SDKs" — the correction was that
OAuth needs none. This one does, and most of what follows is what that costs and
where the cost is refused.

## What is already covered

| Step | Covered by | Status |
| --- | --- | --- |
| Ask the store what it sells | **this service** | Working |
| Put the payment sheet on screen | **this service** | Working |
| Learn that a purchase happened — including one this launch never asked for | **this service** | Working |
| Tell the store the goods were delivered | **this service** | Working |
| Verify the receipt | the app's backend, over `http` | Working |
| Remember what the user owns between launches | the app's backend, `secure_store` for the session token | Working |
| Draw the paywall | `tile`, `button`, `text` — the element set is untouched | Working |

The last row is worth stating plainly: **this service adds no element, no
renderer change, and no `A11yRole`.** OAuth grew a brand mark, a font face, and
a `button` field; this one touches nothing below `Services`. A paywall is a
screen an app already knows how to build.

## The surface: four verbs, one query, one stream

```zig
if (!nokre.services.iap.available(app)) return;      // the boot query
nokre.services.iap.setHandler(app, state, onPurchase); // the stream
_ = try nokre.services.iap.products(.{ … });         // verb: catalog
try nokre.services.iap.purchase(.{ … });             // verb: sheet up
nokre.services.iap.finish(app, txn_id, .consumed);   // verb: delivered
try nokre.services.iap.restore(app);                 // verb: Apple's control
```

Each line's contract — when the query is legal, why the stream is the
only place a purchase arrives, what `finish` promises — is
[../services.md](../services.md); this file is why the surface has this
shape and what each platform does under it.

### Money is a string the store hands over

`Product.price` arrives formatted and is drawn verbatim; the refusal to
reformat it, and the `price_micros` + `currency` pair beside it, are
consumer contract, argued once in [../services.md](../services.md).
Nothing about it is wiring — no leg formats, converts, or reads the
value.

### `pending` is first class

`Purchase.state` is `purchased`, `pending`, or `restored`. `pending` is Play's
cash-at-a-kiosk flow and Apple's Ask-to-Buy deferral: the user has committed and
the money has not moved. The real purchase arrives on the stream later — possibly
days later, in a different process launch, with no call from the app to trigger
it. An app that treats `pending` as a failure has shipped a bug that only appears
for the customers least able to work around it.

### Why the purchase result is a stream, not `purchase`'s callback

`deep_link`'s argument verbatim: the store pushes unsolicited, and the
five arrival paths that make one handler the only workable shape are
stated with the contract in [../services.md](../services.md). The
wiring the shape demands is the buffer behind the flush guarantee:
StoreKit delivers unfinished transactions the moment an observer is
added, which is *before* the app has finished booting if the install
order is wrong.

### `finish` is the crash-safety mechanism, and it is not symmetric

Redelivery-until-finished, the one-word disposition, Play's three-day
auto-refund, and why the word is the caller's to say are consumer
contract, argued in [../services.md](../services.md). The wiring is one
mapping:

| | `.consumed` | `.kept` |
| --- | --- | --- |
| Apple | `finishTransaction` | `finishTransaction` |
| Play | `consumeAsync` | `acknowledgePurchase` |

Apple collapses the pair because it decides consumable-versus-not from
the product type it already knows; Play does not.

## Where the service stops

`oauth`'s line, applied again:

- **No receipt verification.** The `token` (Apple's JWS, Play's purchase token)
  is opaque bytes nokre never reads. The app sends it to its backend, which
  calls the App Store Server API or the Play Developer API. Verifying on the
  device is verifying with the attacker's copy of the key, and doing it in the
  framework was already excluded for `oauth` — the JWKS argument in
  [../services.md](../services.md).
- **No entitlement or expiry model.** `isActive`, renewal windows, grace periods,
  and billing retry are all schedules, and a schedule is a timer, which is a
  ticker nokre has none of — the `clock` service reads the time, it does not
  keep one.
  The app asks its backend what the user owns. `restore` reports what the store
  says is owned *right now* — a list, no dates, no arithmetic.
- **No catalog and no price cache.** The ids are the app's, the store owns the
  prices, and a cache would need an invalidation policy nobody asked for.
- **No paywall layout and no route table.** The app owns both, as it owns
  post-login navigation.

## The legs

| Platform | Implementation | Notes |
| --- | --- | --- |
| macOS / iOS | **StoreKit 1**, Objective-C (`storekit.m`): `SKProductsRequest`, `SKPaymentQueue` + `SKPaymentTransactionObserver`, `finishTransaction`, `restoreCompletedTransactions` | zig compiles the `.m` on macOS; Xcode compiles it on iOS, beside `oauth/apple.m` and for the same reason. |
| Android | Play Billing Library, through `NokreBilling.java` + a JNI leg | The one Maven coordinate nokre has ever asked for. See below. |
| Windows / Linux / Web | No store | `available()` is false; every other verb is `error.Unavailable`, which is a pure function of state known at the call. |

### StoreKit 1, not StoreKit 2

StoreKit 2 is Swift-only. zig cannot compile Swift, and the macOS shell is built
by zig, so StoreKit 2 would mean either two Apple implementations or an
Xcode-built macOS app — a toolchain nokre does not otherwise need.

The cost is named rather than waved away: **StoreKit 1 is deprecated as of iOS
18.** Deprecated, not removed, and Apple has given no removal date; the API still
transacts. The exit, written down now so it is a decision and not a surprise: if
Apple withdraws it, the leg becomes Swift, compiled by Xcode on both Apple
platforms, and macOS gains the Xcode dependency it currently avoids. Nothing in
the consumer contract above changes when that happens — which is the point of
having the contract sit above the leg.

### The one Maven coordinate

`NokreOAuth.java` refuses one, explicitly and for a good reason: *"nokre has no
dependency manager of its own, so every third-party artifact would become the
consumer's problem to add."* Custom Tabs let it keep that promise, because the
protocol is a set of extras on a plain intent rather than a library.

Play Billing has no such escape. The old `IInAppBillingService` AIDL interface —
the one that was genuinely a protocol — is gone: Google requires the Billing
Library and enforces it at the Play Console. There is no wire format to
reimplement, and a fake would fail review rather than fail at runtime.

So the promise is amended rather than quietly contradicted. The service's Java
half lives **outside the shell's source set** — `src/services/iap/java`, not
`src/platform/android/java` — and linking `.iap` documents two lines the consumer
adds to their own `app/build.gradle`:

```groovy
android { sourceSets { main { java.srcDirs += '<nokre>/src/services/iap/java' } } }
dependencies { implementation 'com.android.billingclient:billing:7.1.1' }
```

The placement is what keeps the promise true for everyone else: an app that links
no `iap` never compiles `NokreBilling.java`, so the kitchen sink's zero-services
contract survives and the shell's own Java still builds against nothing but the
platform. It costs one indirection — `NokreActivity` cannot name a class outside
its source set, so `NokreBilling` reaches back through `NokreActivity.current()`, the
single-app anchor every Android leg already relies on.

That is the same posture `secure_store` already takes with the iOS Xcode project
adding `Security.framework` itself: the consumer owns the Gradle project — nokre
generates the manifest and the icon tree into it, not the build file — so a
coordinate is a line on their side of a boundary that already exists.
`NokreOAuth.java`'s comment names this exception, and
[contributing.md](contributing.md) states the bar any future dependency must
clear, so the two statements do not have to be reconciled by a reader who finds
them a year apart.

### Windows, Linux, and the web have no store, and say so

Microsoft Store's `StoreContext` requires MSIX packaging with a Store identity;
nokre emits no MSIX ([platform-shells.md](platform-shells.md) notes the same
packaging gap for App Links), so on a bare `.exe` the API cannot even activate.
Linux has no store. The web was already committed by
[contributing.md](contributing.md)'s web-parity rule, which names IAP as its
example of *"an explicit 'absent on web'"* — a browser page cannot charge through
an app store, and the payment processors that would work there are exactly the
"payments outside the platform stores" that [../services.md](../services.md)
lists as not planned.

`available(app)` is therefore a **runtime query, not a comptime error**. An app
ships one build tree to all six platforms; a compile error on three of them would
force per-target source branches for a screen the app simply should not draw
there. This is `locale`'s rule — the honest empty answer, never an invented one —
and the honest answer here is "there is no store, do not show a Buy button."

The query is two facts ANDed: the leg exists at comptime, and the platform said
yes at runtime. It is read once during `App.init` and cached, `locale`'s
boot-tag pattern, so a `build` can branch on it with no OS call per frame and no
error path for a question that cannot usefully fail — which forced the runtime
half to be something *synchronous*. Apple has one:
`SKPaymentQueue.canMakePayments`, false under parental restriction. Play does
not — `BillingClient` connects asynchronously — so the honest synchronous
question there is whether the Play Store is installed at all, and a connection
that later fails to come up surfaces as a named failure on the verb that needed
it rather than as a boot answer that would have to lie for a moment first.

## Delivery and threading

- `products` is request/response, so it is `http`'s shape: one `openOneShot`
  ticket, one `Result` on the UI thread, a generation-checked handle whose
  `cancel()` guarantees the callback never runs.
- Every stream update opens a **fresh one-shot at delivery time** and delivers
  immediately, so the app's handler runs at a pump rather than inside a StoreKit
  delegate or a Billing listener frame. This is `oauth`'s argument rather than
  `deep_link`'s: `deep_link`'s callback is fired by the shell at a contractually
  safe point, and a store's is not. It needs `workers.openOneShotOn(runtime, …)`,
  a sibling of `openOneShot` that takes the runtime instead of the `*App` the
  service does not hold at delivery time; `openOneShot` becomes a one-line
  wrapper over it and nothing about its behavior changes.
- **One payment sheet at a time** per app: a second `purchase` is
  `error.PurchaseInFlight` — `oauth`'s `AuthInFlight` reasoning, verbatim
  ([../services.md](../services.md)).

## Linking and packaging

Links, and linking requires `pkg_id` — `secure_store`'s argument: a store catalog
is meaningless without the identity it is keyed to, since both stores resolve
products against the app's bundle id / applicationId.

```zig
const nokre = b.dependency("nokre", .{
    .pkg_id = @as([]const u8, "com.example.notes"),
    .iap = true,
});
```

Packaging footprint, per the checklist's requirement that it be stated rather
than implied ([contributing.md](contributing.md)) and shown as a reviewable
manifest-golden diff:

| Platform | Derived from the declaration |
| --- | --- |
| Android | `<uses-permission android:name="com.android.vending.BILLING" />` |
| iOS / macOS | **Nothing** — why Apple's side needs no plist key or entitlement is the consumer section ([../services.md](../services.md)). The cost is link-time only: `-framework StoreKit` on macOS, and the iOS Xcode project links it by Clang module auto-linking. |
| Windows / Linux / Web | Nothing — there is no store to declare. |

## The mock and the harness

Canonical fake, journaling, no transport semantics for the consumer to implement:

- **Config** seeds the catalog: a `[]const Product` with **fixed price strings**,
  so a paywall screen renders byte-identically every run. Plus `available` (false
  boots the app onto a storeless platform, `lockStore`'s twin for a
  different store) and an optional auto-outcome for `purchase`.
- **Journals**: `queries()` (the id sets asked for), `purchases()` (every
  `purchase` call, in order), `completions()` (id + disposition), `restores()`. So
  "the app charged for the wrong SKU", "the app never finished the transaction",
  and "the app has no Restore control" are assertions rather than hopes.
- **Harness verbs**, named away from `secure_store`'s `store` vocabulary so the
  two never read as one service: `deliverPurchase`, `cancelPurchase`,
  `failPurchase`, `deliverProducts`, `failProducts`, `expectFinished`. Each pumps
  and re-audits, as `completeAuth` does.

No kitchen-sink screen. The example links zero services by contract
([contributing.md](contributing.md)) and must keep running that way, which is
where `oauth`'s sign-in screen also landed.

## Verification honesty

Only the mock path is exercised by `zig build test`; `zig build check-targets`
compile-checks every leg's Zig per target, including the three storeless ones, so
`.none` cannot silently name an extern that was never compiled.

The native halves split by how far this host can actually take them:

- **Apple is genuinely testable here.** An Xcode *StoreKit Configuration file*
  drives real `SKProductsRequest`, a real payment sheet, `finishTransaction`, and
  Ask-to-Buy simulation against a local catalog in the Simulator, with no App
  Store Connect account. This is the one native leg that can be exercised
  end-to-end on a macOS host, and it should be.
- **Android will land unverified.** Play Billing answers nothing useful without a
  signed upload to an internal testing track and a license-tester account, which
  is not reachable from this repo. Same posture as the Linux shell and `oauth`'s
  native halves ([platform-shells.md](platform-shells.md)) — stated, not implied
  by silence.

## What the code settled

Four things the plan above left open or got wrong, recorded where the next
reader meets them:

- **The caps are 20 ids and 128 bytes of `[a-z0-9._]`**, both enforced in Zig
  on every platform — `secure_store`'s rule for a value cap, applied to a
  query. The values and the argument for each are the contract table in
  [../services.md](../services.md).
- **A purchase must be priced first**, and this was not foreseen — the
  contract and its argument are [../services.md](../services.md)'s. What it
  forced here: each native leg keeps the rows its last query returned — the
  one piece of native state this service has, made explicit in `iap.h` rather
  than hidden in a static.
- **On Play the transaction id is the purchase token.** `getOrderId()` is absent
  for pending and test purchases, and Google's Developer API is keyed by token,
  so the token is what the backend verifies with, what it deduplicates on, and
  what `finish` needs. One honest value beats a nullable one that vanishes
  exactly when a purchase is most interesting. Apple's id is its own
  `transactionIdentifier`, and its token is the *app receipt* — StoreKit 1 has
  no per-transaction JWS, so one receipt covers every purchase and can be briefly
  absent in a fresh sandbox install, which arrives as an empty token rather than
  a fabricated one.
- **A catalog query runs twice on Play.** `queryProductDetailsAsync` is per
  product type and Play will not say which type an id is, so both are asked and
  one merged answer is reported. Apple needs one request for the same question.
- **The Apple file is `storekit.m`, not `apple.m`.** Xcode names object files by
  basename, so a second `apple.m` beside `oauth/apple.m` in one target is a
  duplicate-output error. Naming it for the framework is also more accurate:
  unlike oauth's, this leg has no vendor-specific arm.

Neither store reports consumable versus non-consumable — `SKProduct` has no
product type and Play's `INAPP` covers both — so `Kind.unknown` is what most
products report, and the `finish` disposition is the app's precisely because
nothing else knows.

One question stayed open and is answered by silence: **a dropped Play Billing
connection is not an update.** Reporting it would hand an app a condition it
cannot act on, and the next verb reconnects. The cost is that `available` can be
stale in one direction — true when the store is momentarily unreachable — which
surfaces as a named failure on the verb that needed it, where an app can
actually show something.
