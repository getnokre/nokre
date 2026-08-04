# Platform shells

One contract, five shells — the web has none, because the browser is
one and nokre's edition there renders into it
([dom-edition.md](dom-edition.md)). (That is the count of record, the
one other docs point at: six platforms, five shells — the web is a
platform without a shell.) Per-platform status lives in the
[README](../../README.md)'s support matrix; this is the
contract a shell implements.
A shell's complete job description:

1. Create a window/surface and report its logical size and integer scale.
2. Deliver input: tap, key, text, IME, scroll.
3. When the app has a dirty frame, fetch the rendered RGBX buffer and
   blit it.
4. Write text to the system clipboard when asked — the one C hook
   behind the clipboard service ([../services.md](../services.md)),
   which backs the `copyable` element and `App.copyText`. Hand a URL to
   the system browser when asked — open_url's hook, the same shape
   (outbound, nothing links; it answers only "did the handoff start",
   and only oauth's loopback leg reads even that).
5. Report the device locale at install and on every change — the one C
   hook behind the locale service, which is what a localized app
   resolves its strings against.

Anything smarter than that belongs above the platform line and is rejected
in review. This is what keeps six platforms maintainable by very few
people. OS capabilities beyond this contract (secure storage, inbound
links, sign-in, …) are separate optional modules — see
[services.md](../services.md).

Selection is comptime in
[src/platform/platform.zig](../../src/platform/platform.zig) — dead shells
cost nothing.

Note what job 3 does *not* include: the shell never draws. Each platform
file names a **frame-source installer** — `skia_frame.install`, which the
Runner calls right before `c_shell.config` — and the shared code delegates
to it, reconciling only the viewport and safe area the OS reported. So no
shell names a rendering backend, and a second renderer edition installs
its own source instead of forking all five
([renderer-editions.md](renderer-editions.md)).

## The C shell contract (macOS, iOS, Windows, Linux, and Android)

[src/platform/shell.h](../../src/platform/shell.h) defines
`nokre_shell_config`: logical size, title, and callbacks —
`on_frame` (returns the RGBX pixel buffer for the current scale, and
carries `safe_bottom` — the height of any OS-drawn band at the view's
bottom edge, 0 where there is none; core keeps layout above it and
extends bottom-pane fills through it),
`on_pointer` (a press, its motion, and its release, with a
`NOKRE_POINTER_*` phase — core activates on the release so a press that
leaves before letting go aborts, WCAG 2.5.2, and reports motion only
between the two), `on_key` (portable keycode enum + modifier bits), `on_text`
(committed UTF-8), `on_ime_update/commit/cancel`, `on_scroll` (deltas
plus a `NOKRE_SCROLL_*` phase: wheel shells send free events routed at
the pointer; touch shells bracket a drag begin/move/end so core locks
the gesture to the scrollers under the initial touch),
`on_edge_pan` (one step of the drag that goes back: which physical edge
the finger started on, how far in it has come, and a `NOKRE_PAN_*` phase
whose `CANCEL` is deliberately not `END` — implemented only by iOS,
the one platform that leaves the screen edge to the app),
`on_back` (the platform's *decided* back command, returning whether
nokre consumed it — Android's leg, where gesture navigation owns both
edges and there is no drag to report),
`wants_frame`, `wants_text_input` (drives the software keyboard on
shells that own one), `on_appearance` (OS light/dark), `on_ready`
(native view handle, for attaching the a11y adapter), and
`on_window_focus`. `nokre_shell_request_frame` lets the Zig side mark the
view dirty from outside the input stream — assistive-tech actions need
it. `nokre_shell_write_clipboard` replaces the system clipboard with UTF-8
text (NSPasteboard on macOS, UIPasteboard on iOS, the Win32 clipboard
as CF_UNICODETEXT on Windows); the clipboard service calls it
directly — no install step. `nokre_shell_haptic` fires the back gesture's
threshold knock and exists on iOS alone, since no other shell runs a
threshold of nokre's own ([haptics.md](haptics.md)). `nokre_shell_post_main` runs a
callback on the UI thread from any thread — the worker service's
delivery hop ([workers.md](workers.md)); only shells whose main queue
the Zig side cannot reach directly implement it (Windows posts a
window message; Apple platforms call libdispatch from Zig and never
link the symbol).

**Space goes down one leg per press.** It is the one key that is also a
character — it activates a button *and* it types — so the contract makes
the shell choose, at the moment of the press, off `wants_text_input`:
`on_text` while a field has focus, `on_key` everywhere else. Neither half
is optional. A shell that maps Space to a key and stops there has no
space bar in its text fields; a shell that sends both legs types a stray
space into whatever the activation just focused — for a `select`, that is
the filter field of the picker it opened. Each shell reaches the rule
through the machinery it already has: macOS hands the event to
`NSTextInputContext` rather than mapping it, iOS lets `pressesBegan` fall
through to `UIKeyInput`, the web's fields are real DOM inputs so the
browser owns the choice,
Linux and Android ask `wants_text_input` before picking a leg, and
Windows — where `WM_CHAR` follows `WM_KEYDOWN` whether anyone wanted it
or not — decides in `WM_KEYDOWN` and latches the echo off. Core is the
backstop, never the decision: a Space key inside a field is inert and
text with nothing editable focused is dropped
([editing.zig](../../src/core/editing.zig)).

A few *service* hooks ride the same native files without being part of
this dumb contract — the shell implements them, but they answer to a
service header, not shell.h. `nokre_shell_write_clipboard` above is one
(clipboard, outbound). open_url's `nokre_open_url_open`
([src/services/open_url/open_url.h](../../src/services/open_url/open_url.h))
is its sibling, outbound: the scheme allowlist has already run in Zig,
so every shell opens what it is handed (`NSWorkspace` on macOS,
`UIApplication openURL` on iOS, ShellExecuteW on Windows, an
ACTION_VIEW intent via `NokreView.openUrl` on Android, a double-fork
`xdg-open` on the Wayland shell; the web has no C shell — services.js
implements the import as `window.open(…, "_blank", "noopener")`,
reached only by keyboard activation, since the live driver leaves
pointer clicks on external anchors to the browser). This hook is each
desktop's *one* URL launcher: oauth's loopback leg names the same
symbol instead of keeping its own ShellExecuteW/xdg-open copy, which
is why the hook returns "did the handoff start" — the open_url service
discards it (fire-and-forget at that surface), oauth's
`BrowserUnavailable` reads it, and the coupling is deliberate and
owner-approved (the header states it). share's `nokre_share_show`
([src/services/share/share.h](../../src/services/share/share.h)) is the
same shape with one asymmetry: the Wayland shell does not export it —
the Linux desktop has no share sheet, and the service answers
`available` false there instead of the shell faking one. Where it
exists, each shell hosts its own sheet (`NSSharingServicePicker`
anchored to the view's center on macOS, `UIActivityViewController` from
the topmost controller — centered arrowless popover on iPad — on iOS,
an ACTION_SEND chooser via `NokreView.showShare` on Android, the WinRT
share pane through `IDataTransferManagerInterop` on Windows — combase
bound at first use, the interfaces declared against the SDK IDL in
shell.c since mingw ships neither — and `navigator.share` on the web,
where the same services.js instance answers the boot-time
`nokre_share_available` probe). deep_link's `nokre_deep_link_install` is the inbound
twin: the OS hands the app a URL (iOS `scene:openURLContexts` /
`continueUserActivity`, Android `onNewIntent`, macOS
`application:openURLs:`), and the shell forwards it on the main thread to
the ctx + callback the service installed, buffering a launch URL that
arrives before install. The contract is
[src/services/deep_link/deep_link.h](../../src/services/deep_link/deep_link.h);
it is wired on all five shells — macOS, iOS, Windows, Linux, and
Android. The web has no C shell: the Zig side keeps the receiver and
exports `nokre_deep_link_receive`
([src/services/deep_link/web.zig](../../src/services/deep_link/web.zig)),
and live.js calls it with `location.href` after boot when the page
loaded with a fragment — by then the handler the app registered inside
its first build is installed, which is the launch-URL contract — and on
every `hashchange`. That delivery runs alongside the live driver's own
reading of the fragment as route navigation, deliberately: the two
answer different questions (*a URL arrived* versus *which screen is
showing*, [docs/routing.md](../routing.md)), and an app that both links
deep_link and routes on the fragment sees it twice — routing.md says to
route on one or the other. The export exists only when the app linked
the service, so a page that never claims a deep link pays nothing.

notification's hooks
([src/services/notification/notification.h](../../src/services/notification/notification.h))
are the roster's only two-directional pair: the app asks the OS to show,
schedule or take back a message, and the OS reports a decision, a tap, an
arrival or a push token. Placement is split rather than uniform, and each
half earns it — Apple's leg is service-owned like oauth's (a
`UNUserNotificationCenter` delegate need not be the app delegate, so one
file serves macOS and iOS both, and each shell carries only the APNs
token line UIKit/AppKit hands nowhere else), while Android, Linux and
Windows are shell-owned like deep_link's, because there the object the OS
calls back really is the shell's: `NokreActivity` and `NokreView` on
Android, the very D-Bus connection this Wayland loop already polls on
Linux, and on Windows a COM activator the shell registers so a tap can
reach a *closed* app. That Windows registration is a deliberate,
recorded narrowing of deep_link's refusal to write the registry, scoped
to two keys ([notifications.md](notifications.md)). The web has no C
shell: services.js implements the imports and the site's own service
worker carries what a page cannot — Chrome for Android refuses
`new Notification()`, and a push arrives with no page open at all.

One service on the roster deliberately asks the shells for *nothing*:
`clock`. Wall time is a call every OS exposes to the process directly —
`clock_gettime` on the POSIX family, `GetSystemTimePreciseAsFileTime` on
Windows, `Date.now()` through services.js on the web — so it has no
header and no shell hook, and a new shell owes it no line. It is
recorded here only so the omission reads as a decision rather than a
gap: a shell that grew a `nokre_clock_*` export would be answering a
question the process can already answer, which is the redirection this
document's last paragraph makes in the other direction
([../services.md](../services.md)).

locale's `nokre_locale_install`
([src/services/locale/locale.h](../../src/services/locale/locale.h)) is
the second inbound hook, and the one a new shell cannot skip: it links
nothing — no framework, no entitlement, no permission — so it has no
build flag to sit unlinked behind, and every native build names the
symbol. A target joins locale.zig's `has_shell_hook` switch only once
its shell defines the function; stub targets never name the extern, and
that switch is the whole of "optional" here (clipboard's posture). The
shell stores ctx + cb like deep_link's and buffers nothing: a launch URL
can be missed, a device locale cannot, because it is readable on demand.
That is what pays for the promise deep_link's hook does not make — **the
first callback fires synchronously, inside the install call.** Install
runs in `App.init` and the app reads the tag inside its first `build`;
nokre has no ticker to retire a loading frame an async answer would
strand. Every later OS locale change fires again, on the main thread,
and *those* fires request a frame — the install fire does not, since no
window exists yet. The tag is UTF-8 BCP 47, not NUL-terminated, borrowed
for the call; a shell that cannot name a language fires with length 0,
and the Zig side turns that empty tag into the app's own template
language. Never substitute an "en" natively: which language an unknown
locale means is the app's decision, not the shell's. macOS is the
reference implementation — `NSLocale.preferredLanguages.firstObject`
(the user's ordered *display-language* preference, already hyphenated
BCP 47, not `localeIdentifier`'s POSIX-flavored *formatting* locale)
plus an `NSCurrentLocaleDidChangeNotification` observer on
`[NSOperationQueue mainQueue]`, which *is* the marshal the main-thread
rule asks for. The other four shells' sources are in their sections
below, and the web's is `navigator.language`, seeded by the live driver
([live.js](../../src/render/dom/live.js)); only Linux has no change
source at all.

oauth is the one service whose native halves deliberately do **not** ride
the shell files, and the exception is worth stating because it looks like
an omission. A browser session is not something a shell has any business
knowing about, so `nokre_oauth_start` lives under
[src/services/oauth](../../src/services/oauth) — secure_store's placement,
not deep_link's — and each leg is a service-owned file the build compiles
beside the shell (`apple.m`, `windows.c`, `linux.c`, the Android JNI
shim). The shell gets involved in exactly one place, for one platform:
Android's redirect arrives as an intent, so `NokreActivity` routes it and
`NokreView.nativeAuthResult` hands it to the service — the same doorway
`nativeDeepLink` uses, and the shell still learns nothing about what a
flow is. Contract in
[src/services/oauth/oauth.h](../../src/services/oauth/oauth.h).

The Zig half of the contract is shared:
[c_shell.zig](../../src/platform/c_shell.zig) owns all state, every
callback adapter, and — for the four shells whose loop `nokre_shell_run`
owns — the whole `run`: `c_shell.Runner(Adapter, install_frame)`. A
platform file ([macos.zig](../../src/platform/macos/macos.zig),
[ios.zig](../../src/platform/ios/ios.zig),
[windows.zig](../../src/platform/windows/windows.zig),
[linux.zig](../../src/platform/linux/linux.zig)) only names its a11y
adapter and frame-source installer. What used to differ invisibly
across four `run` wirings — who forwards window focus, who lends its
loop for worker wakes, who consumes `RunOptions.app_id`, whether attach
wants the window class — is now a comptime branch in the Runner,
derived from the adapter's own surface (`@hasDecl` for
`detach`/`focusState`, attach's arity for the window class) or the
platform predicates c_shell already had. Android is not a Runner
instantiation: its loop is the Activity's, so android.zig keeps its own
wiring over the same shared adapters. The native side (~300–900 lines
of Objective-C or C per platform) holds no state.

Frames are rendered **on demand**: the shell asks `wants_frame` and only
repaints when true. No ticker, no vsync loop, zero idle CPU.

## iOS specifics

[ios/shell.m](../../src/platform/ios/shell.m) is a UIKit port of the
same contract with four twists:

- **Safe area.** The view respects the safe area's top and sides but
  runs to the physical bottom edge, reporting the home-indicator band's
  height as `safe_bottom` — so a bottom pane's surface (the notice
  banner, the notices pane) reaches the true bottom instead of floating
  above a letterbox, and the nav, which paints no surface at all, still
  anchors its items above the band while the page scrolls through it.
- **Software keyboard.** Two responders share the screen: the view is
  first responder exactly while `wants_text_input` says the focused
  element accepts text — which is what shows and hides the keyboard —
  and the view controller holds it otherwise, forwarding hardware keys
  via `pressesBegan`. The keyboard runs with every "smart" mutation
  (autocorrect, capitalization, smart quotes) disabled: the shell's
  UITextInput document is only the IME composition, so the keyboard has
  no context to be smart with — and nokre would not want it anyway.
- **Touch.** A tap gesture sends `on_pointer` DOWN then UP at the
  recognized point. A second recognizer — a long press with no minimum
  duration, which is continuous and so begins immediately — carries the
  raw stream, but only for touches core claims: it is gated in
  `gestureRecognizerShouldBegin:` on `wants_pointer_stream`, so
  everywhere else it never begins and the tap recognizer is untouched.
  When it does begin, the tap and the feeder's pan both
  `requireGestureRecognizerToFail:` it. It is also the one recognizer
  exempt from the fling refusal below: that refusal exists because a
  finger stopping a fling lands on whatever the content drifted under
  it, and core claims only fixed chrome with nothing scrollable beneath
  it — so the chip is where the user aimed, and refusing it would leave
  the one press-activated control dead while any fling ran. The fling
  still stops; `touchesBegan` halts the feeder for every touch.
  Scrolling borrows a hidden
  UIScrollView as its physics engine (see the feeder comment in
  shell.m): UIKit runs drag and flick-deceleration against a vast empty
  content area, and the offset deltas stream to `on_scroll` bracketed
  begin/move/end — one drag, momentum included, stays locked to the
  scroller under the initial touch.
- **The back gesture.** Two `UIScreenEdgePanGestureRecognizer`s, left
  and right, reporting translation to `on_edge_pan`; core picks the
  leading edge for the chrome's direction and ignores the other. The
  feeder's transplanted pan `requireGestureRecognizerToFail:` both of
  them — without that, an inward drag from the edge would scroll *and*
  pan, and the screen would move under a gesture whose entire point is
  that nothing moves. The knock at the threshold is
  `UIImpactFeedbackGenerator`, prepared when the pan begins
  ([haptics.md](haptics.md)). This is the one shell behaviour no
  headless test reaches: recognizer arbitration is verified in the
  Simulator or not at all.
- **Deep links** ([services.md](../services.md)). The scene delegate
  forwards inbound URLs to `nokre_deep_link_install`'s callback: a
  Universal Link arrives as a `NSUserActivityTypeBrowsingWeb` activity
  (`scene:continueUserActivity:`, plus the connection options at launch),
  a custom scheme as `scene:openURLContexts:`. The launch URL is buffered
  until the app registers its handler — belt-and-braces, since on iOS the
  app is built (and `setHandler` run) before `UIApplicationMain`.
- **Locale** ([services.md](../services.md)). macOS's `preferredLanguages`
  read and main-queue observer, verbatim. In practice the boot read is
  what runs: iOS terminates a backgrounded app when the display language
  changes, so the observer earns its keep on the region and calendar
  edits that do arrive live. Both inbound hooks now share one weak
  `g_main_view` — it was `g_deep_link_view`, a deep_link name on a global
  the scene delegate sets for whichever hook needs to dirty the view.
- **Packaging.** UIApplicationMain owns the process, so `zig build
  -Dtarget=aarch64-ios[-simulator] -Dskia` produces static libraries and
  the example's own [Xcode project](../../examples/kitchen_sink/ios)
  compiles the shell, links Skia ([skia-build.md](skia-build.md)), and
  signs — the same wiring a consumer app would keep next to its own
  code. Run instructions: [getting-started.md](../getting-started.md).

## Windows specifics

[windows/shell.c](../../src/platform/windows/shell.c) is a Win32 port
of the same contract — plain C, message loop, no framework. Its twists:

- **Blit.** GDI wants BGRX and the frame arrives RGBX, so the shell
  swizzles the channels
  once per frame and `SetDIBitsToDevice` maps it 1:1 onto device
  pixels. Repaints stay on demand: events call `wants_frame` and
  invalidate; `WM_PAINT` renders. Per-monitor-v2 DPI awareness, with
  the DPI rounded to an integer scale (125% → 1, 150% → 2) — the
  policy every shell shares — so glyphs never resample.
- **Input.** `WM_LBUTTONDOWN` is the tap; wheel messages send `FREE`
  scrolls at the pointer, 48 logical px per notch with sub-notch
  remainders accumulated for precision wheels. Keys map in
  `WM_KEYDOWN`; printable text arrives via `WM_CHAR` (surrogate pairs
  reassembled, control characters filtered — they already traveled as
  keys, so nothing fires twice). A Space spent on activation latches its
  echoing `WM_CHAR` off: the pair arrives whether or not core wanted
  both, and the choice belongs to the press, not to the echo.
- **IME.** IMM32: `WM_IME_COMPOSITION` streams `GCS_COMPSTR` as
  `on_ime_update` (caret converted from UTF-16 units to the UTF-8 byte
  offset the contract asks for), `GCS_RESULTSTR` as `on_ime_commit`, and an end
  without a result cancels. The IME's own composition window is
  suppressed — core renders the composition inline — while the
  candidate list stays.
- **Deep links** ([services.md](../services.md)). The one shell with no
  packaging derivation: an unpackaged Win32 app has no verified https
  App-Link (that is MSIX's `windows.appUriHandler`, a different packaging
  model nokre does not produce), so the URL arrives through a custom
  scheme the developer registers in the registry — the scheme-agnostic
  posture services.md already states. That launches a fresh process with
  the URL on the command line; `nokre_shell_run` parses it off
  `GetCommandLineW` (`CommandLineToArgvW`, the first `://` argument) and
  buffers it until the app's first build registers its handler, the macOS
  launch-URL bargain. A link tapped while the app runs launches a *second*
  process, which finds the running window by class **and** title and hands
  the URL over with `WM_COPYDATA` before exiting — Android's
  singleTask/onNewIntent, done with the tools an unpackaged app has —
  rather than stacking a duplicate. A plain launch (no `://` argument)
  forwards nothing, so two ordinary launches still both run.
- **Locale** ([services.md](../services.md)).
  `GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, …)` — the reading
  language, not `GetUserDefaultLocaleName`'s formatting locale (an
  English UI with German number formats is an ordinary setup, and it is
  the reading language that has to choose the bundle); the formatting
  locale is the fallback only when that preference list will not fit the
  buffer. The change signal is `WM_SETTINGCHANGE`'s `intl`, the
  dark-mode leg's neighbor below, and it fires for *any* edit on the
  regional page — so the leg re-reads and reports only when the bytes
  moved, or changing the short-date format would wake a frame and re-run
  the app's handler for nothing.
- **Dark mode.** `AppsUseLightTheme` in the registry, re-read on
  `WM_SETTINGCHANGE`'s `ImmersiveColorSet`; the title bar follows via
  `DWMWA_USE_IMMERSIVE_DARK_MODE` (frame chrome is the OS's to theme —
  nokre content itself never recolors).
- **Toolchain.** The Skia prebuilt is MSVC-ABI, so `-Dskia` builds
  target `x86_64-windows-msvc` (build.zig defaults the ABI; Visual
  Studio's C++ Build Tools required) and text rasterizes through the
  prebuilt's FreeType from memory — pixels match the Linux and Android
  builds, not the CoreText platforms, which is the intended shape
  ([pixel-model.md](pixel-model.md)). Two
  consequences wired in build.zig: AccessKit's Rust static library
  supplies the compiler intrinsics zig's compiler-rt would duplicate,
  and FreeType's gzip references resolve to a never-runs stub
  ([shim/nokre_skia_zlib_stub.c](../../shim/nokre_skia_zlib_stub.c)).

## Android specifics

[android/android.zig](../../src/platform/android/android.zig) speaks
the contract with the boundary inverted: Android owns the event loop
(the Activity), so instead of a blocking `nokre_shell_run` the Zig side
exports `nokre_android_*` functions that forward into the shared c_shell
adapters, and the native side is
[android/shell.c](../../src/platform/android/shell.c) (JNI plumbing +
ANativeWindow blit, compiled by the example's CMake) plus the Java half
in [android/java](../../src/platform/android/java) — `NokreView` (the
shell proper) and `NokreActivity` (lifecycle), which the consumer's
manifest declares directly, the way the iOS app delegate lives in
shell.m. Its twists:

- **Boot.** `main` never runs — the consumer's root module exports
  `nokreAndroidBuild(gpa) !*App` and `nokre_android_boot` calls it (the
  `nokreWebBuild` bargain), with one comptime line forcing the export
  block into the build. The allocator is bionic's malloc
  (`std.heap.c_allocator`) — the same heap the NDK-linked Skia uses.
- **Blit.** `SurfaceView`: shell.c locks the `ANativeWindow`, copies
  the RGBX rows straight into the window buffer (the one shell whose
  format matches the frame's), and posts. The buffer stays at
  the window's own pixel size so the compositor never scales; density
  rounds to an integer scale and logical size is the ceiling, remainder
  cropped at the edge (the Windows policy). Edge-to-edge on API
  30+: the gesture-nav band's height is `safe_bottom`, the IME inset
  shrinks the view, and pre-30 devices run inside system windows with
  `adjustResize`.
- **Touch.** A `GestureDetector` tap sends `on_pointer` DOWN then UP at
  the recognized point. `onTouchEvent` asks `wants_pointer_stream` on
  `ACTION_DOWN` first: a claimed gesture is forwarded raw for its whole
  life and never reaches the detector, so tap detection, scrolling and
  flings are untouched for everything else. A running fling is halted in
  that branch, since the detector's `onDown` never runs for it — but
  unlike `onDown` the press is not also swallowed, the iOS exemption by
  the same reasoning. Unclaimed drags bracket
  `BEGIN`/`MOVE`/`END` with the anchor locking core's routing, and
  flings hand off to `OverScroller` — the platform's own physics, the
  iOS hidden-UIScrollView bargain — with a Choreographer callback
  running only while decelerating. A touch during a fling stops it
  without also activating what it lands on.
- **Back.** Android's gesture navigation owns both screen edges, so
  there is no drag for the app to see and no `on_edge_pan` leg here:
  the OS runs its own threshold, draws its own predictive-back preview,
  and delivers a decision. `NokreActivity` routes it to `on_back` and
  finishes the activity when nokre had nothing to pop. Both roads are
  wired — the API 33+ `OnBackInvokedDispatcher` and the older
  `onBackPressed` — because which one is live is the consumer
  manifest's `enableOnBackInvokedCallback` choice and, from API 36, the
  platform's default; the system never uses both.
- **Text input.** The view's `InputConnection` document is only the
  in-progress composition (suggestions off, no extract UI):
  `setComposingText` streams `on_ime_update`, commits and
  `finishComposingText` land as `on_ime_commit`, an emptied composition
  cancels. The keyboard shows and hides off `wants_text_input` after
  every event, and text crosses JNI as standard-UTF-8 `byte[]` — never
  `GetStringUTFChars`, whose *modified* UTF-8 would mangle emoji.
  Hardware keys map in `onKeyDown`, with printable characters sent as
  text instead — Space by whichever leg `wants_text_input` selects.
- **Deep links** ([services.md](../services.md)). `NokreActivity` reads the
  App-Links intent's data URI — `getIntent()` at launch, `onNewIntent`
  while running — and hands it to `NokreView.deepLink`, which crosses JNI
  as standard-UTF-8 `byte[]` (the text path's rule) to
  `nokre_deep_link_install`'s callback on the UI thread. The launch URL is
  buffered in C until the app boots and registers its handler. The
  generated manifest adds `android:launchMode="singleTask"` when
  deep_link is claimed, so a link routes to the one running instance
  rather than stacking a duplicate.
- **Locale** ([services.md](../services.md)). The tag comes from Java —
  `Configuration.getLocales().get(0).toLanguageTag()`, not
  `Locale.getDefault()`, because the `LocaleList` honors the Android 13
  per-app language override that the app's own resources already follow
  — and crosses JNI as standard-UTF-8 `byte[]`, the text path's rule.
  Its change lane is unlike every other shell's: the generated manifest's
  `configChanges` ([packaging.zig](../../src/packaging/packaging.zig))
  deliberately does not claim `locale`, so an OS language change
  *recreates the Activity* instead of calling `onConfigurationChanged`.
  The shell reboots, the app does not (`nokre_android_boot` is idempotent,
  so install runs once per process), so `NokreView`'s constructor reports
  the tag again right after `nativeBoot` and the C side drops the report
  when the bytes have not moved — a recreate for any other reason costs
  nothing. Claiming `locale` in the manifest would be cheaper at runtime
  and is still not done: the recreate path has to be correct regardless
  (the system recreates for reasons no `configChanges` list opts out
  of), and one lane that always works beats two that mostly do.
- **Packaging.** `zig build -Dtarget=aarch64-linux-android` produces
  one static library of all the Zig (no C rides along — qrcodegen and
  the shim need bionic headers zig does not bundle); the example's
  [Gradle project](../../examples/kitchen_sink/android) compiles the
  JNI shell, shim, and qrcodegen with the NDK — one C/C++ toolchain
  with the NDK-built Skia
  ([tools/build-skia-android.sh](../../tools/build-skia-android.sh),
  FreeType from memory, so pixels match the Windows and Linux builds) —
  and links `libnokre_app.so`. Worker wakes ride
  `nokre_shell_post_main`, implemented as a pipe on the main thread's
  ALooper (the Windows message-loop lend, relocated).

## Linux specifics

[linux/shell.c](../../src/platform/linux/shell.c) is a Wayland port of
the same contract — plain C against libwayland, one poll loop, no
framework. X11 is deliberately absent: Wayland is the modern default,
and one backend per platform is the charter. Its twists:

- **Blit.** `wl_shm`: the shell swizzles RGBX to XRGB8888 into a
  double-buffered memfd pool and commits the free buffer, tracking
  `wl_buffer.release` so it never overwrites one the compositor still
  holds. Integer buffer scale from the `wl_output` the surface is on, the
  logical size from `xdg_toplevel.configure` — the Windows integer-DPI
  policy, so glyphs never resample. The generated `xdg-shell` and
  `text-input-unstable-v3` client glue is produced by `wayland-scanner`
  at build time (build.zig), never committed — the qrcodegen/harfbuzz
  vendoring rule.
- **Window identity.** `RunOptions.app_id` is set as the
  `xdg_toplevel` app_id — the key compositors match against
  `<app_id>.desktop` for the icon, task grouping, and deep-link handler
  registration. It defaults to the packaging declaration's id, so it
  cannot drift from the `.desktop` file `zig build pkg` names; null (no
  declared identity) sets none at all, because a wrong id breaks the
  association worse than none. This is the one shell that consumes the
  field — every other platform derives identity from the bundle or
  package, not the window.
- **On demand.** The loop blocks in `poll()` over the display fd, a
  worker/a11y wake `eventfd`, a keyboard-repeat `timerfd`, the
  single-instance socket, and the D-Bus fd; it renders only when the
  frame is dirty (a configure, an input event whose `wants_frame` is
  true, a wake). No frame-callback ticker — an app at rest costs zero
  CPU, and the `wl_display_prepare_read`/`read_events` handshake keeps
  the sleep race-free.
- **Input.** `BTN_LEFT` press is the tap; `wl_pointer.axis_value120`
  sends `FREE` scrolls at 48 logical px per detent with sub-notch
  remainders (the Windows `WHEEL_DELTA` parity), falling back to `axis`
  below v8. Keys map through xkbcommon (`XKB_KEY_*` → `NOKRE_KEY_*`);
  printable text arrives via `xkb_state_key_get_utf8`, control
  characters filtered — they already traveled as keys, so nothing fires
  twice. Space, having no text system here to defer the choice to, is
  routed by `wants_text_input` in `dispatch_key` itself: a focused field
  makes it a character like any other. The compositor delegates
  key repeat, so the shell drives one `timerfd` for the held key.
- **IME.** `zwp_text_input_v3`: `preedit_string` streams `on_ime_update`
  (the caret is a UTF-8 byte offset by contract — core currently draws
  the caret at the composition's end and holds the offset for the day
  it renders it), `commit_string` lands
  as `on_ime_commit`, and the batch applies on `done` — the enable/disable
  follows `wants_text_input` after every event, which is what raises an
  on-screen keyboard where the compositor offers one.
- **Deep links** ([services.md](../services.md)). Like the Windows leg,
  no packaging derivation: an unpackaged app has no verified https
  association, so the URL arrives through a custom scheme the developer
  registers in a `.desktop` `x-scheme-handler`. The OS launches a fresh
  process with the URL in argv (read from `/proc/self/cmdline`); if this
  app already runs, the new process forwards the URL over an abstract
  Unix socket named for the app and exits — the WM_COPYDATA / onNewIntent
  bargain — rather than stacking a duplicate. The launch URL is buffered
  until the app's first build registers its handler.
- **Locale** ([services.md](../services.md)). POSIX keeps it in the
  environment, in the precedence `setlocale` itself obeys: `LC_ALL`, else
  `LC_MESSAGES` (the message-catalog category — the one that decides
  which language a user *reads*, as against `LC_NUMERIC` and friends),
  else `LANG` — read with `getenv` and never through `setlocale`, whose
  job is to mutate the C library's global state, not to answer a
  question. The value is a POSIX locale name, so the codeset and modifier
  are stripped and `_` becomes `-`
  (`fa_IR.UTF-8@calendar=persian` → `fa-IR`); that strip is load-bearing
  rather than cosmetic, since l10n's tag compare starts with the length,
  so an unstripped value would miss the exact match and silently demote
  `fa_IR` to whatever bare `fa` bundle exists. `C`, `POSIX`, and unset
  all report the empty tag. **No change source, which is the honest
  answer and not the lazy one:** the environment is fixed at `exec` and
  cannot move under a running process, Wayland has no locale event, and
  the portal Settings namespace this shell already speaks carries
  `org.freedesktop.appearance` keys and nothing about language. The
  callback fires exactly once, inside install; a user who switches
  language restarts the app, as they must for the GTK and Qt programs
  beside it.
- **Clipboard & appearance.** Copy is a `wl_data_source` offering the
  text mime-types and set as the selection; nokre never reads the
  clipboard (write-only by charter). Dark mode is the
  `org.freedesktop.appearance color-scheme` value read from
  xdg-desktop-portal over D-Bus, re-read on the portal's `SettingChanged`
  signal; absent a portal the shell reports light, the honest default.
- **Accessibility.** AccessKit's Unix adapter (AT-SPI — Orca) registers
  the process on the a11y bus. Unlike the macOS/Windows subclassing
  adapters it has no window handle and runs its handlers on its own
  thread, so the shim (shim/nokre_accesskit.c) marshals assistive-tech
  actions to the UI thread through `nokre_shell_post_main` — the Windows
  message-only-window marshal relocated to the wake eventfd.
- **Toolchain.** `zig build … -Dtarget=x86_64-linux -Dskia` links the
  Linux Skia + AccessKit prebuilts (tools/fetch-deps.sh) with the system
  `wayland-client`, `xkbcommon`, `dbus-1`, and `libsecret-1`; text
  rasterizes through the prebuilt's FreeType, so pixels match the
  Windows/Android builds.

## The web has no shell

It had one: a wasm module driven from a Worker, blitting Skia's buffer
into a canvas and mirroring the a11y snapshot into a hidden ARIA tree.
That shell is gone, and so is the Skia build behind it.

What replaced it is not a shell at all. The browser already *is* one —
it owns the event loop, the window, the input, the text rasterizer and
an accessibility tree — so nokre's edition there renders the semantic
tree into that document rather than beside it
([dom-edition.md](dom-edition.md)). There is no surface to blit, no
frame to request, no ARIA to mirror, and nothing on this page to
specify: the contract below describes the five shells that drive a
`FrameSource`, and the web drives none.

What the web still shares with them is everything above the shell line:
the same `App`, the same tree, the same services. The service hooks a
linked service calls out through are the same free functions this
document names, answered in JavaScript
([services.js](../../src/render/dom/services.js)) instead of in C.

## The headless shell

One more program sits in the shell's seat: a *driver* — a headless
native binary (nokre's own `tests/dev_store.zig` and
`tests/http_stress.zig`, a consumer's system-test or e2e runner) that
links the library and therefore owes the same free functions. nokre
ships that shell as
[src/testing/shell.zig](../../src/testing/shell.zig), and its doc
comment is the contract: which hooks it defines, why three of them
record instead of staying silent, and why naming the module
(`comptime { _ = nokre.testing.shell; }`) is the whole install. Two
shell-side facts belong here rather than there. It is `export`s only —
linking it into a windowed build collides with the real shell's
definitions, and that loud duplicate-symbol error is the intended
guard. And it installs no wake and owns no loop: worker and http
replies queue until the driver's own `app.runtime.pump()` runs
([workers.md](workers.md)), which is the pump the platform shells wire
into their main loops and a driver runs by hand — the consumer-facing
half of that story is [testing.md](../testing.md)'s "Driving an app
outside `zig test`".

## IME

The IME protocol (start/update/commit/cancel) is part of core
([src/core/event.zig](../../src/core/event.zig)) and the composition string
renders identically everywhere. Shell-side IME is implemented on macOS
(NSTextInputClient), iOS (UITextInput), Windows (IMM32), Android
(InputConnection), and Linux (text-input-v3) — every shell. The web's
fields are real DOM inputs, so the preedit is composed *in the field*
by the browser itself; the live driver forwards the same
update/commit/cancel legs into core off the composition events, and
what an open session owns on that platform is
[dom-edition.md](dom-edition.md)'s to say.

## The accessibility bridge

The semantic `Snapshot` ([accessibility.md](../accessibility.md)) is
produced and tested platform-independently; a shell only attaches an
adapter:

- **Desktop/mobile:** the snapshot feeds [AccessKit](https://accesskit.dev),
  which fans out to VoiceOver, NVDA/JAWS (UIA), Orca (AT-SPI), TalkBack.
  The binding is live on macOS (VoiceOver), Windows (UIA — Narrator,
  NVDA, JAWS), and Linux (AT-SPI — Orca) via accesskit-c:
  [src/a11y/accesskit.zig](../../src/a11y/accesskit.zig) flattens the
  snapshot into a plain-C node array, and
  [shim/nokre_accesskit.c](../../shim/nokre_accesskit.c) translates it
  into AccessKit tree updates — role and action mapping is
  compile-checked against the real `accesskit.h`. Click and focus actions
  from assistive tech dispatch back into the same core event path as
  pointer input, marking the view dirty via `nokre_shell_request_frame`.
  Two Windows wrinkles live in the shim: the subclassing adapter wraps
  the window procedure, so it attaches while the window is still hidden
  (shell.c orders `on_ready` before `ShowWindow`), and UIA may deliver
  actions off the UI thread, so they marshal through a message-only
  window before dispatch. The Linux Unix adapter has the same off-thread
  wrinkle without a window: it holds no HWND and runs its handlers on its
  own thread, so the shim marshals actions to the UI thread through
  `nokre_shell_post_main` (the wake eventfd) and serializes its tree reads
  with a mutex. Other desktop shells reuse the shim and add only the
  per-platform adapter glue.
- **iOS:** no AccessKit — UIKit's UIAccessibility natively consumes a
  flat element list, so the shell builds `UIAccessibilityElement`s
  straight from the same flattened node array (roles → traits, the
  topmost modal's subtree only, activate/VoiceOver-focus dispatching
  back like clicks). Same fill/action callbacks, no extra library.
- **Android:** no AccessKit either — `NokreView`'s
  `AccessibilityNodeProvider` serves virtual `AccessibilityNodeInfo`s
  from the same flattened array (shell.c walks it and hands each node
  across JNI; roles → class names, the topmost modal's subtree only,
  flat under the host view like iOS). TalkBack's click and
  accessibility-focus dispatch back through the same fill/action
  callbacks, and a content-changed event fires after frames while
  assistive tech listens.
- **Web:** nothing to bridge — the DOM edition renders the semantic
  tree as the document, so the browser's accessibility tree is the
  output, not a mirror ([dom-edition.md](dom-edition.md)).

## Writing a new shell

Port `shell.h` to the platform's windowing API (~300–500 lines of native
code), map keycodes to the `NOKRE_KEY_*` enum — Space by the one-leg rule
above, which no golden can catch for you — blit RGBX. Add
`nokre_locale_install` with it — the one service hook that has no unlinked
path, so an omission is an unresolved symbol rather than a missing
feature (the contract, including the fire-before-you-return clause, is
above). Then run the kitchen-sink example and the golden suite; if
goldens pass, the platform renders byte-identically and the job is done
— remembering that byte-identity is per-platform by design
([pixel-model.md](pixel-model.md)): the committed goldens are
macOS-generated, so a new shell validates against its own regenerated
set, permanently, rather than waiting for one set to serve everything.
