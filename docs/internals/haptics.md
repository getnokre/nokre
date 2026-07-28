# Haptics, and the one gesture

nokre has exactly one gesture — a drag inward from the leading screen
edge, which goes back — and exactly one haptic: the **knock** that
gesture fires as it crosses the point where releasing would commit, and
again if it crosses back out. This doc is why both exist in a framework
that refuses animation, and what each platform does with them.

Consumer surface for the gesture: [../routing.md](../routing.md). The
service row: [../services.md](../services.md).

## Why a gesture at all

The obvious way to do iOS-style back is the interactive slide: two
screens on screen at an offset, tracking the finger, settling under its
own power on release. Every part of that is something nokre cannot have.
The settle needs frames nobody asked for — a display link in each of five
shells, which retires "an app at rest costs zero CPU" and, with a ticker
in the building, the argument against a spinner with it. A screen 40%
slid has no tree behind it, so it has no accessible description and no
byte-exact frame to golden. And the timing would be wall-clock, which the
core is not allowed to read.

So the gesture is kept and the motion is dropped. **Nothing moves.** The
finger travels, a threshold is crossed, and the feedback for that
crossing is a haptic knock plus the Back control's chevron becoming an
arrow — a chevron points the way navigation goes, an arrow is the going,
so the armed control states the outcome rather than looking like a button
being held (the `copy_glyph` → `copy_check` swap `App.ack` already
makes). On release past the threshold the screen changes the way it
changes when the Back control is tapped: instantly. What is left is the *affordance* — the
thing a thumb reaches for on a large phone — without the animation that
usually carries it.

Two consequences follow from that trade and are load-bearing:

- **No velocity.** A flick that commits below the threshold needs a
  speed, which needs a clock. Position decides, and only position.
- **The gesture is never the only way.** The framework installs a Back
  control on every pushed screen, and it stays the discoverable,
  focusable, screen-reader-reachable path. The gesture is a shortcut for
  people who already know it, not a route to anything the chrome does not
  already offer.

## The threshold

Core owns every decision; a shell reports geometry (`event.zig`'s
`EdgePan`: which physical edge, how far in, which phase) and nothing
else. `input.zig`'s `handleEdgePan` decides:

| | |
| --- | --- |
| eligible | stack depth > 1, no modal open, and the edge is the *leading* one — the left in LTR, the right in RTL, mirrored with the chrome like the Back chevron itself |
| threshold | the numbers are the consumer contract's ([../routing.md](../routing.md#the-back-gesture)); in code, `layout.metrics.back_gesture_*`. A ratio with a floor, because "most of the way across this screen" is a different pixel count on a phone and in a desktop window |
| hysteresis | 8px. Arming takes the full distance; giving it up takes a retreat past the band, so a hand holding still at the boundary settles instead of rattling the taptic engine at the touch stream's sample rate |
| release | past the threshold, `navigateBack()`; short of it, nothing |
| cancel | never commits, and never knocks — the system took the gesture away, and the user did not undo anything |

Eligibility is answered once, at `.begin`, and a gesture that fails it
stays dead for its whole life. That is deliberate: a knock announcing a
navigation that will not happen is worse than no feedback.

## The knock, per platform

Only iOS has a threshold of nokre's own to cross, so only iOS exports
`nokre_shell_haptic`. Everywhere else the extern is never named
(clipboard's `has_shell_hook` rule) and `knock` compiles to nothing.

- **iOS** — a process-wide `UIImpactFeedbackGenerator` at
  `UIImpactFeedbackStyleRigid`: the sharpest impact style, a knock rather
  than a thud. `prepare` runs when a pan begins, because the Taptic
  Engine idles and a generator asked cold can miss the moment by enough
  to feel late; it runs once more at the first idle moment after launch,
  because the *first* generator of a process also pays for the framework
  and its daemon connection, and that bill should not arrive attached to a
  gesture (`nokreSchedulePrewarm`, which warms the keyboard for the same
  reason and cannot leave the main thread, only wait for it to be idle).
  Arming and disarming are opposite events, so they must
  not feel identical: the same knock at intensity 1.0 and 0.6, rather
  than a second vocabulary for a finger to learn.
- **Android** — no knock, because no threshold. Gesture navigation owns
  both screen edges, so the app never sees the drag; the OS runs its own
  threshold, draws its own predictive-back preview, and delivers a
  decided command. nokre's share is routing it (`on_back`).
- **macOS, Windows, Linux, web** — no gesture and no knock. The web's
  back is the browser's own, already mirrored through the route observer
  and `hashchange` (a fragment the router cannot honor is put back with
  `history.replaceState`).

There is no nokre-side setting for any of this, because iOS already
honours the system haptics toggle. A framework switch would be a second
answer to a question the OS has asked.

## Why it is a service

`haptic` is a field on `Services` with a journaling mock, and no
consumer-facing verb whatsoever — no `App.haptic(...)`, now or later.
Those two facts are not in tension:

- It is **not a capability** apps get. Firing a buzz on demand is a
  feedback hook in the same family as a styling hook, and the roster
  `iap` closed stays closed to things apps can reach.
- It is **platform-flavored state**, so the injection rule applies
  anyway: nothing platform-flavored may be a module-global extern that
  no test can observe ([architecture.md](architecture.md)). The knock
  *is* the feature here, so a version of it that tests cannot see would
  be a feature with no tests.

Under `zig test` the mock journals every knock in order, which is what
makes "crossed the threshold once, crossed back once, crossed again"
assertable without a finger (`Harness.knocks()`).

## What is testable, and what is not

Everything above the shell boundary: eligibility, the threshold, the
hysteresis band, the knock sequence, cancel-versus-release, the RTL
mirror, and the armed Back control (a golden — `back-armed.pgm` differs
from `back-chrome.pgm` by one glyph, which is the whole visual footprint
of this feature).

Below it, one thing is not: on iOS the edge recognizers must win the
touch against the hidden `UIScrollView` that feeds scrolling, and
`requireGestureRecognizerToFail:` is what arranges that. No headless test
reaches recognizer arbitration — it is verified in the Simulator or not
at all ([shell test tier](platform-shells.md)).
