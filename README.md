# nokre

A deliberately limited GUI library: text, lines, and boxes. Zig + Skia
(CPU raster), accessibility built in, deterministic to the pixel.

nokre is roughly as expressive as Markdown, plus actions and navigation.
Every element is semantic — accessibility is derived automatically from
the tree you build, never opted into. Two devices on the same platform
with the same logical screen size render byte-for-byte identical
frames, run after run and machine after machine. Identity *across*
platforms is not the goal and never becomes one: an app is a semantic
tree, and how a device draws that tree is the device's business
([docs/roadmap.md](docs/roadmap.md)).

The web is the same app and not the same picture: there nokre renders
the tree as **markup** and lets the browser draw it
([docs/internals/dom-edition.md](docs/internals/dom-edition.md)). The
semantics, the focus model and the audit hold; the pixels are the
browser's, so lines wrap where it wraps them. In exchange the
accessibility tree stops being a mirror and becomes the page itself,
and the app ships as one small wasm module with no Skia in it. That
trade is the rule rather than the exception: a renderer is an *edition*,
free to draw the tree the way its device draws things, so long as the
semantics arrive whole
([docs/internals/renderer-editions.md](docs/internals/renderer-editions.md)).

Think: apps for a grayscale Kindle — and, on the same tree, for a
terminal, a watch face, a panel that refreshes one row at a time.

No hover, no animation, no color, no system fonts, no GPU, no custom
widgets. These are guarantees, not gaps — each one is what makes an app
built on nokre provably accessible, pixel-deterministic, and testable
headlessly. The argument is
[docs/introduction.md](docs/introduction.md).

```zig
const nok = @import("nokre");

fn buildHome(_: ?*anyopaque, app: *nok.App) !void {
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Notes", .level = .h1 } });
    _ = try app.tree.append(root, .{ .text = .{ .content = "Everything here is accessible by construction." } });
    _ = try app.tree.append(root, .{ .button = .{
        .label = "New note",
        .on_press = .{ .call = onNewNote },
    } });
}
```

That's a valid, keyboard-navigable, screen-reader-complete screen — and a
button without a label would have refused to construct. The element set is
closed and small: some thirty semantic elements from `Text` to `Table`
to `Nav`, every one specified in [docs/elements.md](docs/elements.md).

nokre also ships its own headless e2e framework: synthetic input through
the real event pipeline, assertions read from the accessibility snapshot,
and byte-exact golden screenshots — no browser driver, no flakiness. It is
app-level: it drives the real `App` and stops at the platform shell, which
is what keeps it deterministic
([docs/testing.md](docs/testing.md#where-the-harness-stops) is explicit
about the boundary).

## Documentation

The full map, both tracks, is [docs/README.md](docs/README.md). Start here:

- [docs/introduction.md](docs/introduction.md) — the philosophy: what's
  refused, and what each refusal buys
- [docs/getting-started.md](docs/getting-started.md) — the course: build
  one app that uses everything, test it as you go, ship it to five
  platforms
- [docs/elements.md](docs/elements.md) — every element, its semantics and
  behavior
- [docs/accessibility.md](docs/accessibility.md) — the a11y contract:
  derivation, enforcement, the audit
- [docs/localization.md](docs/localization.md) — ARB catalogs at comptime,
  ICU messages, right-to-left, what the compiler checks
- [docs/testing.md](docs/testing.md) — harness, queries, golden tests
- [docs/services.md](docs/services.md) — optional OS capabilities beyond
  the window
- [docs/roadmap.md](docs/roadmap.md) — what's next: more editions,
  tooling, Skia packaging

How it works inside — layers, the pixel-determinism spec, shell and Skia
strategy, contributor checklists — is
[docs/internals/](docs/internals/README.md).

## Platforms

Five shells, all working with full parity — window, input, IME,
clipboard, and a screen reader on each — plus the web, which has no
shell because the browser is one. The columns below carry only what
differs at a glance: the text scaler (macOS and iOS on CoreText, the
rest on FreeType — each platform keeps the one it has, which is why
goldens belong to the platform that made them) and the accessibility
backend. The complete per-shell contract
is [docs/internals/platform-shells.md](docs/internals/platform-shells.md).

| Platform | Shell | Text | Accessibility |
| --- | --- | --- | --- |
| macOS | AppKit | CoreText | VoiceOver via AccessKit |
| iOS | UIKit | CoreText | VoiceOver via UIAccessibility |
| Windows | Win32 | FreeType | Narrator/NVDA/JAWS via AccessKit (UIA) |
| Linux | Wayland | FreeType | Orca/AT-SPI via AccessKit |
| Android | JNI + SurfaceView | FreeType | TalkBack via AccessibilityNodeProvider |
| Web | wasm32, no shell | the browser's | the DOM itself — nothing to mirror |

What's next — more editions (e-ink, terminals, watches and monochrome
heads-up displays), tooling — is [docs/roadmap.md](docs/roadmap.md).

MIT licensed.
