# Notifications

Consumer contract: [services.md](../services.md#notification-the-oss-surface-and-the-interrupt-you-have-to-ask-for).
This file is the wiring, the two reversals the service required, and the
per-platform asymmetries a consumer reads as `available`,
`scheduleAvailable` and `pushAvailable`.

## Two reversals, both owner-decided

nokre's refusals are guarantees, and the way one moves is that it is
argued and then written down — the Google sign-in G's record in
[oauth.md](oauth.md) is the precedent this file follows.

**Push notifications left the Not-planned list.** They were there for
the honest reason that list exists: no current requirement. What changed
is the requirement, not the argument, and the argument turned out to
have nothing to defend. The refusals that look adjacent all survive
intact:

- *No ticker; an app at rest costs zero CPU.* The OS runs the countdown
  and, for push, the process is usually not alive at all. nokre still
  waits on nothing.
- *Deterministic to the pixel.* A notification draws no pixel in nokre's
  frame. It is OS chrome, the same category as the share sheet and the
  payment sheet, both already accepted.
- *No styling hooks.* The OS draws it; there is nothing to style, and
  the one semantic that crosses (`important`) is one `notices.Notify`
  already carries.

The one genuinely philosophical question — *who decides to interrupt
someone* — was already answered by the in-app notice: quiet by default,
`important` is the opt-in. This service aims the same decision outside
the app and refuses to derive one from the other, which is why
`app.notify` never raises an OS notification and never will.

**deep_link's registry refusal was narrowed, for Windows and by two
keys.** deep_link declines to register anything in
`HKCU\Software\Classes`, saying the registration belongs to the app or
its installer — right for a URL scheme any installed app may also claim,
and the reason nokre derives only *verified* links. Notifications are
not that case. An unpackaged Win32 app has no toast identity at all:
Windows keys notifications to an AppUserModelID, and a tap can only
reach a *closed* app through a COM server registered under a CLSID.
Nothing else can claim that identity — it is the app's own name for its
own notifications — and without it the platform has no notification
support to offer.

So the Windows shell writes exactly two keys, at first run, under HKCU:

| Key | Value |
| --- | --- |
| `Software\Classes\AppUserModelId\<app id>` | `DisplayName`, and `CustomActivator` naming the CLSID below |
| `Software\Classes\CLSID\{…}\LocalServer32` | this executable, so a tap can start it |

The scope is the whole of the reversal. A shell that grows a third
registration is a bug, and deep_link's refusal is otherwise unchanged.
Both keys are rewritten on every run rather than once, because an app
that moved on disk has a stale `LocalServer32`, and a tap that starts
the wrong binary is worse than two registry writes.

The activator CLSID is fixed rather than derived from the app id: it
names *this shell's* callback implementation, which is the same code in
every nokre app, while the AppUserModelID — which is the app's — is what
keeps two nokre apps' notifications apart. Windows resolves the callback
only after matching the AUMID, so one is an implementation and the other
is the identity.

## The fire date is the OS's, or it does not exist

`schedule` hands an instant to the platform and returns. That is what
keeps the no-ticker rule true rather than merely re-worded: no thread,
no timerfd, no wake, and the process is usually gone when it fires.

Two platforms have nothing to hand it to. The Wayland desktop's
`org.freedesktop.Notifications` posts and nothing more, and the web's
scheduling trigger never shipped. Both could be papered over with a
timer nokre owns — and that timer would die with the process or the tab,
which is precisely when a reminder matters. So `scheduleAvailable`
answers false there and `schedule` is `error.Unavailable`: share's
posture on the Linux desktop, applied to the half of this service the
platform genuinely lacks.

Android holds the date in `AlarmManager`, which survives the app closing
but not a reboot. Re-arming after boot would mean nokre keeping its own
durable copy of the schedule — a schedule nokre owns, which is the thing
`schedule` exists not to be — so the posture is stated in
[services.md](../services.md) instead, and no
`RECEIVE_BOOT_COMPLETED` is derived. The alarm is deliberately the
inexact one: `USE_EXACT_ALARM` is policed by Play to alarm-clock and
calendar apps and `SCHEDULE_EXACT_ALARM` is user-revocable, so demanding
either would make every consumer justify nokre's choice to Google for a
fire date that reads "remind me in the morning".

## Where each leg lives, and why

The placement is split, and each half earns it.

**Apple is oauth's placement** — one service-owned file,
[apple.m](../../src/services/notification/apple.m), for macOS and iOS
both. `UNUserNotificationCenter`'s delegate is any object rather than the
app delegate, so nothing here needs to be the shell, and one file beats
the verbatim duplication the locale hook pays across the same two shells.
Each shell carries exactly one delegate method, for one reason: an APNs
token is handed to the *application* delegate by UIKit/AppKit and nowhere
else, so it is forwarded from there. That is oauth's Android-intent
exception, restated on Apple.

The forwarding points *into* the shell, not out of it. Each shell defines
`nokre_notification_apple_set_push_token_sink` (declared in
[notification.h](../../src/services/notification/notification.h)) and
apple.m installs itself from `nokre_notification_install`; the sink is
NULL in an app that links no notifications, which is exactly when the
delegate method is dead code — only apple.m ever asks AppKit/UIKit to
register. The direction is not cosmetic. A shell links in *every* app
and apple.m links in some, so a shell that named a symbol apple.m defines
would fail at link time in every app that skips the service — which it
did, until the sink replaced it. An optional service may name the shell;
the shell may never name the service. `weak_import` is not a way around
this: zig's MachO linker rejects an undefined weak symbol that no input
defines, so the guard the two delegates carried was never reached.

**Android, Linux and Windows are deep_link's placement**, because there
the object the OS calls back really is the shell's:

- **Android** — `NokreNotifications` lives in the shell's Java source
  set (the local half needs no coordinate) and `NokrePushService` lives
  outside it in [java/](../../src/services/notification/java) (FCM needs
  one — iap's split). Nothing in the first names the second, so an app
  that links notifications without push still compiles. The JNI bridge
  is the service's own
  [android.c](../../src/services/notification/android.c), reached through
  `NokreView.nativeNotificationEvent`, which the shell declares and the
  service implements: a shell routes the event without learning what it
  means.
- **Linux** — the leg is in the Wayland shell because the session bus it
  needs is the one the shell already holds and already polls. One
  connection has one queue, so notification signals are drained in the
  same pump the appearance portal uses; a second pump would race the
  first for the same messages.
- **Windows** — the toast is WinRT, reached from Win32 the way the share
  pane already is: mingw ships no `Windows.UI.Notifications` header and
  no combase import library, so the entry points bind at first use and
  the interfaces are declared against the SDK IDL with the uuids copied
  digit-for-digit. No per-toast `Activated` handler is attached, because
  the registered activator receives a tap whether the process is running
  or not — one path serves both, and it avoids a parameterized
  `TypedEventHandler` GUID.

**The web** needs a service worker, and it is the reason
[sw.js](../../src/render/dom/sw.js) ships with every site whether or not
the app links the service. Chrome on Android refuses `new Notification()`
outright and serves only
`ServiceWorkerRegistration.showNotification`, so a page-only leg would
work on desktop and silently not on the platform where notifications
matter most; and a push arrives with no page open at all, which is what
push *is*. A worker has to be registerable by URL, so leaving it out of
the emitted site would make the leg unimplementable after the fact. It
carries no app logic and no cache: a tap is forwarded to whatever nokre
client is open, or opens one with the payload in the query string, which
live.js delivers as a tap and then strips so a reload is not a second
tap.

## macOS needed a bundle, so packaging grew one

`UNUserNotificationCenter` refuses to post for a binary with no bundle
identifier. nokre's macOS build was a bare Mach-O, so notifications were
not merely unimplemented there — they were unimplementable.

Packaging now emits `macos/Info.plist` and `macos/AppIcon.icns`, and
build.zig assembles `Contents/{Info.plist,MacOS/nokre_app,Resources}`
around the artifact. `zig build run-…` drives the binary *inside* the
bundle, so the development loop matches a shipping app rather than being
the one place notifications cannot work — the goldens' argument, one
layer down. NSBundle resolves the bundle from the executable's own path,
so no launcher and no `open(1)` is involved and stdout still attaches to
the terminal.

Two details are load-bearing. The plist is a separate emitter from the
iOS one rather than the same emitter with a flag: the scene manifest is
UIKit's and means nothing here, and `NSHighResolutionCapable` is the
pixel model's stake in the file — without it AppKit hands the shell a 1×
backing store on a Retina display and every glyph resamples. And the
`.icns` is a container, not an image format: a magic, a big-endian total
length, then `(type, length, PNG)` entries, so the same derived mark
every other platform gets goes in unresampled and un-re-encoded.

## The event lane, and what it costs

One handler, four kinds, deep_link's shape carrying iap's argument: a
tap on a notification this launch never posted, a token minted before
the first `build`, a token the OS rotates on its own, an authorization
revoked in Settings — none was requested by a call that could own the
callback.

Install happens in `App.init` rather than at the first `setHandler`,
which is locale's placement and locale's reason inverted: the three boot
probes must be readable inside the first `build`, and a tap that
launched the app must have somewhere to land before that build runs.
Events arriving between install and the handler buffer on the Zig side,
capped at eight, dropping the *newest* past that — the launch tap is the
oldest and the one that must survive a shell that floods.

The one thing a native side buffers is the tap that arrives before
install, because on Apple, Android and Windows the OS may start the
process *because* of the tap. Everything after install is Zig's, where
one implementation serves all six platforms instead of six C buffers.

`received` — a notification coming due with the app on screen — exists
because without it a reminder that fires mid-session, and every push
during a session, would be silently nothing. The OS banner is suppressed
for that case on every platform that would otherwise draw one, which is
the same judgment the rest of the service makes: a lock-screen card over
the app someone is already looking at is the OS interrupting on nokre's
behalf.

## What this service does not do

- **No silent push.** A `content-available` payload that wakes an app to
  run code with no UI is background execution: a different contract,
  with a different owner, and nothing in nokre's model (no ticker, no
  background frame) to receive it.
- **No notification content beyond title, body and a route reference.**
  No images, no action buttons, no reply fields, no badges, no grouping.
  Each is a styling hook wearing a lanyard, and the ones that are not
  (actions, replies) are UI nokre would then have to model twice.
- **No token policy.** Refresh, expiry and de-registration are the app's
  backend's, the line oauth already draws.
- **No route table.** The tap hands over a reference and stops; routing
  is the app's, as it is for a deep link.
