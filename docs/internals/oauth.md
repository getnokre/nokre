# The oauth service

Status: **working** — the service, on all six platforms. The roster row
in [../services.md](../services.md) is the status of record and carries
the consumer contract; this file is the design behind it, written before
the code so the expensive decisions were argued once, and amended after
it with what the code actually settled. Two parts: the service itself,
then the brand marks a sign-in button needs on screen — which is where
nokre's grayscale refusal met two vendors' branding rules. That second
part is now settled both ways: **Apple's mark is built** — one monochrome
glyph and a `button` field, no colour anywhere — and **Google's is
refused permanently**. No palette exception is pending; the cost of the
one that was considered is recorded there so the question stays closed.

## What is already covered

Most of a sign-in flow needs nothing new. The gap is one primitive.

| Step | Covered by | Status |
| --- | --- | --- |
| Build the authorize URL | app code | — |
| Open it where the user can trust it | **missing** | this plan |
| Get the callback URL back | **missing** | this plan |
| Exchange code → tokens | `http` | Working |
| Persist the refresh token | `secure_store` (already namespaced by `pkg_id`) | Working |
| A link re-entering the app | `deep_link` | Working |
| Anything slow off the UI thread | `worker` | Working |

## The shape: one browser primitive, not two vendor SDKs

The plan opened by disputing the then-roadmap's grouping of
OAuth with IAP as "both drag in per-platform SDKs." That is true of IAP
and was overstated for OAuth: **neither provider requires a third-party
SDK.** The sequencing followed from the correction — OAuth landed first
and cheaply, IAP after it — and that roadmap grouping is gone.

- **Google** supports the RFC 8252 native-app flow — system browser plus
  PKCE, public client, no client secret. The GoogleSignIn / Play Services
  SDKs are a UX convenience, not a requirement. Skipping them costs one
  thing, named plainly: no Android Credential Manager one-tap: the user
  sees a Custom Tab.
- **Apple** requires `ASAuthorizationController` on Apple platforms for a
  good flow, but that is `AuthenticationServices.framework` — first-party,
  in the same class as the `Security.framework` `secure_store` already
  links, not a vendored dependency.

That matters because nokre has no dependency manager to host a vendored
SDK: no CocoaPods, no SPM, no Gradle third-party coordinates. Taking
either SDK would mean inventing one. The browser flow needs none.

So the service is **one verb** — plus one query, which the plan did not
foresee and the loopback leg forced (see "What the redirect changed"
below) — and the whole per-platform surface is where that verb lands:

```zig
var buf: oauth.RedirectBuf = undefined;
const redirect = try oauth.redirectUri(app, "com.example.notes", &buf);
// …build the authorize URL from `redirect`, the PKCE challenge, scopes…

_ = try nokre.services.oauth.start(.{
    .app = app,
    .url = authorize_url,            // built by the app: scopes, PKCE challenge, state
    .redirect = redirect,
    .ctx = state,
    .on_result = onAuth,
});

fn onAuth(ctx: ?*anyopaque, result: nokre.services.oauth.Result) void {
    switch (result) {
        // The OS handed the callback URL back. Parse it, exchange the
        // code over `http`, store the refresh token in `secure_store`.
        .callback => |url| exchange(ctx, url),
        // The user dismissed the sheet. A first-class value, not an
        // error: cancelling a login is a normal thing to do.
        .cancelled => dismiss(ctx),
        // Transport or configuration failure, as a stable name —
        // http's `.failure` posture.
        .failure => |f| showAuthError(ctx, f.name),
    }
}
```

| Platform | Implementation | Notes |
| --- | --- | --- |
| macOS / iOS | `ASWebAuthenticationSession` | Already this exact shape: ctx, completion, `canceledLogin`. The reference leg. |
| Android | Custom Tabs, callback returns as an intent | Reuses the deep_link intake path; the scheme is registered, not a claimed domain. |
| Windows | Default browser (`ShellExecuteW`) + loopback listener | RFC 8252 §7.3. The listener is Zig, off the UI thread — see the open question below, which this settled. |
| Linux | `xdg-open` + loopback listener | Same implementation as Windows, byte for byte; the desktop portal has no auth session API worth binding. |
| Web | Popup on the app's own origin (services.js) | A top-level redirect would tear down the wasm instance mid-flow; the popup lands on the app's own page, which posts its URL to its opener and closes (live.js's first act on boot). |

**Apple's native leg** is the one addition beyond the primitive: on
`.macos` and `.ios`, `oauth.start` with `.provider = .apple` routes to
`ASAuthorizationController` instead of the browser — and only when the
build declared `.oauth_apple`, which is what carries the entitlement
and compiles the leg. Everywhere else Apple
is the web flow through the same primitive. One consumer-facing call,
two implementations behind it, chosen at comptime — `secure_store`'s
dispatch, not a consumer branch.

## Where the service stops

`deep_link`'s line, applied again: nokre hands over the result and
stops. Not in scope, and each for a stated reason:

- **No token refresh policy.** When to refresh is the app's session
  model, and a timer is a ticker — nokre has none.
- **No user model.** An idToken is a JWT the app decodes and trusts (or
  sends to its backend to verify). nokre does not define a `User`.
- **No route table.** Post-login navigation is the router's, which the
  app owns.
- **No JWT verification.** Signature checking needs the provider's
  rotating JWKS — a network fetch with a cache policy and a clock. The
  server does it. nokre returns bytes.
- **Apple's token exchange needs the app's backend regardless**: the
  client secret is a JWT signed with the developer's `.p8` key, which
  must never ship in a binary. The roster row's "returning an idToken" is
  already the right boundary.

## PKCE, and the one determinism carve-out

The verifier needs cryptographic randomness and the challenge needs
SHA-256 + base64url. [contributing.md](contributing.md) forbids
randomness *in core*, because it breaks the [pixel model](pixel-model.md);
a service is not core, and `std.crypto` is available. Two consequences to
honor:

- **The mock is seeded, not random.** `oauth.Mock` takes a fixed verifier
  in its config, so a test that renders a login screen stays byte-stable.
  Under `zig test` the mock is the only path — locale's rule.
- **wasm needs a randomness hook.** `std.crypto.random` on
  `freestanding` has no `getrandom`; the web leg routes to
  `crypto.getRandomValues` through services.js
  (`nokre_oauth_js_random`) — a known gap closed in the web leg, not a
  surprise discovered at link time. Both instances implement it — the
  app's on the main thread, the compute actor's in its Worker
  (live-worker.js) — because the browser's CSPRNG is available and
  synchronous in either, so nothing hops.

## Linking and packaging

Links, and linking requires `pkg_id` — `deep_link`'s argument holds
verbatim: the entitlement and the redirect registration are keyed to the
app's identity.

```zig
const nokre = b.dependency("nokre", .{
    .pkg_id = @as([]const u8, "com.example.notes"),
    // The redirect schemes the OS must route back to this app. On iOS a
    // Google OAuth client redirects to its reversed client id, which is
    // why one of these usually looks like one.
    .oauth = @as([]const []const u8, &.{
        "com.example.notes",
        "com.googleusercontent.apps.NNN-xxx",
    }),
    .oauth_apple = true, // the applesignin entitlement + the native leg
});
```

**No client-id options**, which is where this differs from the sketch
above it. The plan listed `.oauth_google_client_ios` and friends and
asked whether they should be three options or one struct; the answer the
code found is neither. The app builds its own authorize URL, so the
client id never reaches nokre — and the only value the *build* has to
know is the redirect *scheme*, which on iOS is the reversed client id
anyway. Three options would have been three ways to state one string.

Packaging footprint, per the service checklist's requirement that it be
stated rather than implied ([contributing.md](contributing.md)) and shown
as a reviewable manifest-golden diff:

| Platform | Derived from the declaration |
| --- | --- |
| iOS / macOS | `com.apple.developer.applesignin` entitlement; `CFBundleURLTypes` carrying the reversed-client-id scheme |
| Android | `intent-filter` with `scheme=` for the redirect; no new permission (`INTERNET` already rides `http`) |
| Windows / Linux | Nothing — the loopback listener registers nothing |
| Web | Nothing — the origin is the registration |

This is the moment [../services.md](../services.md) anticipated when it
deferred custom schemes from `deep_link`: *"a custom scheme is a
different, underived manifest declaration… its own opt-in if a need
appears."* OAuth is that need. The refusal that stands is unchanged —
`deep_link` still derives only verified `https://` domains; the custom
scheme is derived here, for a redirect, where the two-way `.well-known/`
proof is neither available nor what the flow relies on.

## What the redirect changed

The plan's signature took a `.callback_scheme` and said nothing more,
which works on four of the six platforms and cannot work on the other
two. A loopback redirect's port is the OS's to pick (RFC 8252 §7.3), so
the listener has to bind *before* the authorize URL can be written down
— and the URL is the app's to build. There is no arrangement in which
`start` alone suffices.

So the surface is one verb plus one query: `redirectUri(app, scheme,
&buf)` returns the string this platform will actually receive on, and
`start` takes it back. Three benefits fell out of what looked like a
cost:

- The token exchange needs the same redirect string byte for byte.
  Exposing it was going to be necessary regardless; hiding it inside
  `start` would have meant exposing it a second way.
- `start` can *verify* it. A `redirect` that is not the prepared one is
  `error.RedirectMismatch` at the call, instead of a flow that hangs
  because the listener and the URL disagree.
- The scheme is validated on every platform, including the two that
  ignore it — so a scheme that is legal on the developer's macOS and
  illegal on the CI Linux box fails in both places.

The cost is one line of consumer code per flow, and a rule to state:
call it once per flow, immediately before building the URL. A settled
flow clears its redirect, so a second sign-in prepares a second one —
which on a loopback platform is a second port, and that is exactly
right.

## The mock and the harness

Canonical fake, journaling, no transport semantics for the consumer to
implement:

- Config seeds what the OS does: a canned callback URL, `.cancelled`, or
  a named failure — plus the fixed PKCE verifier.
- `authorizations()` journals every `start` in order, with the URL the
  app built, so "the app requested the wrong scopes" and "the app never
  sent a PKCE challenge" are assertions rather than hopes.
- Harness: `t.completeAuth(url)` / `t.cancelAuth()` / `t.failAuth(name)`
  as settle verbs, routing to the handler and re-auditing —
  `changeLocale`'s shape, with `failAuth` as `failHttp`'s twin for the
  flow's first half.

## Phases — as built

1. The primitive: `oauth.h`, the Zig policy layer, the mock, the harness
   verbs, unit tests. **Done.**
2. PKCE helpers + the wasm randomness hook. **Done.**
3. All six legs. **Done** — and not in the planned order: the loopback
   pair (Windows, Linux) landed as one Zig implementation, so "remaining
   legs in shell order" collapsed to four distinct implementations, not
   five.
4. Apple's native `ASAuthorizationController` leg. **Done.** It reports
   its grant as a *synthetic* callback URL — the plan left this
   unspecified, and one `Result` shape for six platforms is worth more
   than an arm the other five never carry. `code` and `id_token` come
   back as fields, the app's own `state` is echoed from Zig, and the
   percent-encoding happens in Zig because encoding is policy.
5. Packaging derivation + manifest goldens. **Done**
   (`Info.oauth.plist`, `AndroidManifest.oauth.xml`,
   `App.oauth.entitlements`).
6. Consumer docs: the roster row is Working and
   [../services.md](../services.md) carries the contract. **Done**,
   except the kitchen-sink screen — the example links zero services by
   contract ([contributing.md](contributing.md)), and a sign-in screen
   without a brand mark is a plain `button`, which the sink already has.

What is built below this line is **Apple's mark only**, and the split
turned out sharper than the plan drew it: the entire frame-format cost —
the extra canvas op, the shim's patch rendering, the `on_frame` contract,
five shells — was *Google's*, because Apple's mark is monochrome and
therefore just a `drawText` call with `.ink` into the plane that already
exists. So Apple's conforming button landed as `brand.ttf` (one glyph),
`text.Family.brand`, and `Button.provider`, with no colour, no shell
change, and no golden-format fork. Google's is not unbuilt-for-now; it is
refused, and the section below is why.

One finding worth recording: the a11y audit already refuses two sign-in
buttons with the same accessible name on one screen
(`duplicate_interactive_label`), which is the most likely way an app
would misuse this — a filled and an outlined "Sign in with Apple" side
by side, indistinguishable to a screen reader. Nothing was added for
that; the existing rule caught it while the golden was being written.

The glyph is Apple's own artwork, transcribed verbatim from the SVG they
publish for this purpose and inlined in `tools/make-brand-font.py` —
so the committed outline can be diffed against Apple's source, and
nothing about it was redrawn. The script does the mechanical half: the
y-flip into font coordinates, the scale to cap height, the side
bearings, and the cubic-to-quadratic conversion TrueType requires. It is
deterministic, so the font changes in a commit only when the artwork
does.

The mark is placed like a **letter, not an icon**, and that is the one
non-obvious thing in the renderer: it stands on the *text* baseline at
exactly the label's cap height, where a Lucide icon centres in its em
box instead. Measured on the golden, the mark's top and bottom rows are
the same rows as the label's capitals. An icon is decoration beside
words; a logotype is a word.

### Verification honesty

Only the mock path is exercised by `zig build test`; `zig build
check-targets` compile-checks every leg's Zig (including the loopback
listener) per target. The native halves — `apple.m`, the Custom Tab,
the two `open_url` implementations, the popup JS in services.js — are
compile-checked where the host allows it and **otherwise unverified on
a macOS host**, the
same posture the Linux shell landed under (see
[platform-shells.md](platform-shells.md)). iOS's `apple.m` is compiled
by the consumer's Xcode project rather than by zig, beside
`src/platform/ios/shell.m` and for the same reason:
AuthenticationServices pulls in UIKit, whose headers do not survive
zig's clang against a current iOS SDK.

---

# The brand marks: one built, one refused

Both providers' branding rules govern the button that starts the flow.
This is the only place where a store-facing requirement collided with a
[refusal](../introduction.md) rather than a mere convention, so it was
argued in full — and both halves are decided: **Apple's mark ships,
Google's never will.** What follows is the record of why, kept whole so
that the absent button reads as an answer rather than as an omission.

Two facts about the pipeline set the price of everything below.
The vocabulary is [eight operations](../../src/render/canvas.zig), none
of which draws an image; the only path-rendering op is `drawText`, which
is why the icon set is a font ([lucide.ttf](../../src/assets/fonts),
`IconName` in [element.zig](../../src/core/element.zig)) rather than
vectors. And the surface is 8-bit gray from end to end:
`kGray_8_SkColorType` in [nokre_skia.cpp](../../shim/nokre_skia.cpp),
a gray8 readback out of `hsk_surface_pixels`, a gray8 buffer returned by
`on_frame` in [shell.h](../../src/platform/shell.h), five shells blitting
gray8, and PGM goldens.

## Apple needs no color at all

The most useful finding here, and it halves the problem. Apple's HIG
sanctions three button styles: **black**, **white**, and **white with a
black outline**. nokre has `g0` and `g12`, and their contrast is proven
at build time in [color.zig](../../src/core/color.zig). A conforming
Sign in with Apple button is *already* expressible in the palette.

One wrinkle since the palette gained a ceiling: `ink` and `paper` are no
longer the true endpoints (they are `g2` and `g12`, 14.2:1 rather than
21:1 — see the [pixel model](pixel-model.md)), and `g12` is the *page* in
light and a near-black in dark. So the filled brand pill does not ride
the aliases. It draws through `Canvas.light`, a canvas pinned to the
light ramp, at `g0`/`g12` explicitly — the two steps the design system
itself never draws. It still flips with the appearance, so the dark
screen *is* Apple's white button, with no second style and no palette
escape hatch. The QR tile takes the same exit for the same reason
(a scanner wants maximum modulation), and both are asserted on bytes,
not steps, in [tests/golden.zig](../../tests/golden.zig).

What was missing is only the Apple logotype, and that mark is monochrome
— a single path, exactly what a font glyph is. So Apple cost:

- One glyph in a new **`brand` face** (see below).
- One `button` field. No canvas change, no format change, no palette
  change, no golden format change.

Both are built; the semantics are in
[elements.md](../elements.md#button).

## Google: refused, and not on a schedule

Google's guidelines require the official multicolor **G** mark, in one of
two sanctioned buttons: the light button (white background, `#1F1F1F`
label, 4-color G) or the blue button (`#4285F4` background, white label,
white G). A gray G is not a sanctioned variant, so unlike Apple this
cannot be resolved inside the palette. Either nokre puts colour on
screen or it deviates from the guidelines; there is no third reading.

**It deviates.** `AuthProvider` has one arm and gains no second one —
closed in the sense hover and animation are closed
([introduction.md](../introduction.md)), not a backlog entry. An app that
signs in with Google still gets the entire flow, because the service
never knew which provider it was talking to: `start` takes the authorize
URL the app built, and the button beside it is a plain `button` carrying
the app's own words. What the app does not get is Google's mark on
nokre's canvas.

The exposure is named rather than waved away: Google brand review of the
OAuth client can object to a text-only button. That is a materially
smaller risk than what compliance costs — which is byte-exact grayscale
determinism, the guarantee the whole project is organized around. App
Store review is not in play at all; the mark is Google's rule, not
Apple's.

### What compliance would have cost

Recorded because the cost is the argument — not because the number might
one day come down.

**The part that looked cheap.** The G decomposes into four monochrome
arcs, so the mark could have arrived as four glyphs in the brand face and
four `drawText` calls at one origin, each in its own colour: no
COLR/CPAL font, no bitmap, no decoder (Skia here is built codec-free —
see
[nokre_skia_nocodec_stub.cpp](../../shim/nokre_skia_nocodec_stub.cpp)),
no new geometry primitive. The canvas would have gained exactly one
operation — `drawText` with a closed four-value colour type,
constructible nowhere else. Contained, and still not enough.

**The accessibility half, which picked the variant.** Of the two
sanctioned buttons only the light one is admissible: white on `#4285F4`
is about **3.6:1**, which clears WCAG 1.4.11 non-text contrast (3:1) but
*fails* AA for body text (4.5:1). nokre's palette is contrast-proven by
construction and its a11y is derived automatically, so admitting that
background would mean either exempting a vendor's colour from the
framework's own text gate or shipping a button the audit must flag. The
light button avoids it — `g0`-class text on `g12` is the palette's
strongest pair, and the mark itself carries an empty label beside a real
one, so it is decorative and exempt by the existing rule in
[elements.md](../elements.md). The colour would have shrunk to one
glyph-sized square, touching a11y not at all.

**The part that killed it: the frame format.** A single non-gray pixel is
not a small change, because gray8 is a format commitment through five
layers. Four options existed, and none is cheap:

- **A. Widen the surface to RGB/RGBA everywhere.** Five shell blits, the
  shim, `on_frame`'s contract, `tests/golden.zig`, and every committed
  golden regenerated. Also the wrong shape: it makes colour *possible*
  framework-wide, which is the refusal itself, not a side effect.
- **B. A native overlay view per shell.** Fails the layer rule — the
  shell gains intelligence, the mark leaves the tree, and a11y derivation
  and goldens both lose sight of it.
- **C. Two-plane frame: gray8 as today, plus a small brand plane the
  shell composites.** Keeps every existing pixel byte-identical and keeps
  the mark in the tree, at the cost of a second buffer in the shell
  contract, five shells learning to composite it, and a forked golden set
  (PGM by default, PPM for screens carrying a mark) maintained forever.
- **D. Ship no Google mark.** Text-only button in the palette. Passes
  every gate, costs nothing, deviates from Google's branding rules.

**D, and D is final.** An earlier draft of this file held C open behind a
`-Dbrand_color` flag, so a consumer needing strict compliance would have
a designed path rather than an improvised one. That is withdrawn. A flag
that forks the golden set is a second product with a second determinism
story, and "grayscale, byte-exact, everywhere" stops being true the
moment the flag exists — a guarantee with an opt-out is not a guarantee,
it is a default. So there is no `-Dbrand_color`, the canvas stays at
eight operations, and the frame stays gray8 through all five layers.
Apple's compliant button needs none of it and ships regardless.

## Font and licensing

The one asset decision that outlived the plan. The mark is Apple's
trademark, used under their brand guidelines, and it must **not** be
merged into `lucide.ttf` — Lucide is ISC-licensed and a trademark glyph
inside it would misrepresent that license. So: a separate `brand.ttf`, a
separate `text.Family` arm (`.brand`), and its own
[LICENSE-Brand.txt](../../src/assets/fonts/LICENSE-Brand.txt) stating
plainly that the mark is not nokre's and is used per the vendor's
published guidelines. The glyph set is closed at one, for the same reason
it was going to be closed at five: an open brand font is a trademark
liability, not a feature.

## Open questions, and how they closed

- **Google's per-platform client ids: three build options or one
  struct?** Neither. The app builds its own authorize URL, so the client
  id never reaches nokre; the build needs only the redirect *scheme*,
  which on iOS *is* the reversed client id. See "Linking and packaging".
- **Is the loopback listener a `worker` or does it live inside the
  service?** Inside the service, as a detached Zig thread delivering
  through the same one-shot ticket `http`'s native transport uses
  ([http.md](http.md)). That is what "a worker, not a shell thread"
  actually asked for — off the UI thread, result as a callback — without
  making `oauth` the first service to compose the worker registry, which
  would have dragged `nokreWorkers` membership into every consumer that
  signs in. The listener is `loopback.zig`; Windows and Linux share it
  byte for byte, and their whole C surface shrinks to one
  `nokre_oauth_open_url`.
- **Is `auth_button` a distinct element or a `button` variant?** A
  variant, and closed. `Button.provider` carries the mark, so the element
  set grew by a field rather than a row, and nothing reopens it — the
  colour work that might have wanted its own element is refused above,
  not deferred.
