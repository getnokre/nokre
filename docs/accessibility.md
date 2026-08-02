# Accessibility

nokre inverts the usual model: you cannot add accessibility, because you
cannot omit it. The semantic tree *is* the UI; the pixels and the
accessibility tree are both projections of it.

## Derivation

[src/a11y/semantics.zig](../src/a11y/semantics.zig) walks the element tree
and produces a flat, parent-linked `Snapshot` in document order. Roles map
1:1:

| Element | A11y role | Carried state |
| --- | --- | --- |
| root stack | `document` | — |
| `text` | `static_text` | content as label; styling spans are invisible — one node announcing the concatenation |
| span with a destination (`route` or `external`) | `link` | a link child of its paragraph, named by its own words, focusable |
| `heading` | `heading` | level 1–6; spans invisible as on `text` |
| `icon` (labeled) | `image` | label as name; decorative icons are omitted |
| `badge`, `meter` | `static_text` | the words carry all state; a badge's leading mark is decorative and is never announced |
| `qr` | `image` | label as name, encoded value carried |
| `stack`, `box` | `group` | — |
| `tile_group` | `group` | description as value |
| `divider` | `separator` | — |
| `button` | `button` | focused, disabled, busy (`in_progress`: disabled *and* busy, and still a focus stop); `progress_percent` as the value |
| `button` / `link` (folded) | — | absent: the row folded it away and its `more` speaks for it |
| `sheet_close`, `back`, `icon_button`, `more` | `button` | focused |
| `link` | `link` | focused |
| `tile` | `link` (route) / `button` (action) | detail as value, focused; its leading mark is decorative — the label is the name |
| `toggle` | `switch` | on (carried as checked), focused; `in_progress`: disabled *and* busy, the value still carried, still a focus stop |
| `checkbox` | `checkbox` | checked, focused; `in_progress` as `toggle` |
| `copyable` | `button` | copied value carried, focused; a `status` child while acknowledged |
| `text_input` | `text_field` | value, composition, focused |
| `text_input` (obscured) | `password_field` | value withheld |
| `text_area` | `multiline_text_field` | value, composition, focused |
| `list` / `list_item` | `list` / `listitem` | —; the derived marker is presentation and is never announced |
| `code_block` | `code` | content announced whole, focused |
| `blockquote` | `blockquote` | —; the attribution is words inside it |
| `table` / `row` / `cell` | `table` / `row` / `cell` | header rows |
| `scroll_region` | `scroll_area` | focused |
| `segmented` | `radio_group` | selected option as value, focused |
| `radio_group` | `radio_group` | selected option as value, focused |
| `select` | `combo_box` | selected option as value, focused |
| picker (framework) | `dialog` | modal; `picker_item` → `option`, selected |
| `nav` | `navigation` | — |
| `nav_item` | `link` | selected (aria-current), focused; its icon is decorative — the label is the name |
| `nav_current` (framework) | `combo_box` | named by the framework ("Section" in English — [localization.md](localization.md#the-frameworks-own-words)), current section as value, focused |
| `nav_here` (framework) | `static_text` | named by the framework ("Current screen"), the route's title as value; no focus stop — it names where you are, it does not go there |
| `sheet` | `dialog` | modal |
| `notice` | `status` | title as label |
| `notices_pane` | `dialog` | modal |

Each node carries its layout rect, so screen readers get correct hit
geometry for free.

A button with work in progress ([elements.md](elements.md#button)) is
the one state that rides as a pair: **disabled and busy**, never one
without the other. Not operable — a second press must not start the
action twice — but present, named, and still a focus stop, which is the
combination the ARIA practices prescribe and the reason the state is not
simply `disabled`: the user who pressed it keeps their place, and hears
what the button is doing rather than finding it gone. Each backend says
it in its own words — `aria-busy` beside `aria-disabled` on the web,
AccessKit's `busy` on macOS/Windows/Linux, a state description on
Android (API 30+), and, because UIKit has no busy trait at all, the
value slot on iOS, where the shell already spells `on`/`off` out. What
the pixels show is `…`; what assistive tech gets is the state itself.

When that button also carries a `progress_percent`, the number rides in
the node's **value** — "Save changes, 60%" — and the role stays
`button`. A `progressbar` role would be the ARIA-shaped answer and is
the wrong one here: it is a different role, and this node is a control
that was pressed, not a bar. Putting the number in the value is the
trade `meter` already makes, and it needs nothing new on the wire, so
every backend carries it today. It is also why the bar being absent on a
disabled button costs a screen reader nothing: the pixels drop the
track, the value keeps the number.

One node is derived rather than mirrored from an element: an
acknowledged `copyable` (see [elements](elements.md#copyable)) gains a
`status` child labeled `Copied`, the same polite live region a notice
gets, arriving and leaving with the check in the field. A mark with no
words needs a voice, and it cannot be the element's own: the label and
value stay untouched, because they are what a screen-reader user reads
back to check the value they just copied. The words are the framework's
own — English until an app translates them, like `Close` and `Back`
([localization.md](localization.md#the-frameworks-own-words)).

**Layout is not in the snapshot.** A horizontal row too narrow for its
children [wraps](elements.md#a-row-too-narrow-for-its-children), and a
wrapped row's snapshot is identical to the same row's on a screen wide
enough — same nodes, same order, same names, same states, only the rects
moved. Where a line broke is not a fact about the app, so nobody is told
one. Its counterpart is the exception that proves it: a row of actions
that *folds* does change what is announced, because a folded action is
not on the screen at all (see [elements](elements.md#the-folded-tail-more)),
and that is exactly why folding is reserved for the rows where a control
stands in for what it hid.

## Focus

Focus is a first-class core concept, not a platform afterthought: Tab and
Shift-Tab traverse focus stops in document order with wraparound
([src/core/focus.zig](../src/core/focus.zig)). A stop is usually a whole
element; the exception is a paragraph carrying inline links, which is
not focusable itself but contributes one stop per link, in span order —
so a link inside prose is reached by Tab like any other control, and a
focus target is a node plus an optional span index rather than a bare
node. Traversal is scoped to the
active layer: normally the whole window, but while a sheet or the notices
pane is open, only that layer — the background is inert, so there is
nothing outside the
scope to reach. This is not a focus trap in the WCAG 2.1.2 sense: Esc
always dismisses the sheet (or minimizes the pane), and focus returns to
the element that opened
it. The focus indicator — one 2px `ink` stroke, either standing 2px
clear of the element or taking over the outline the element already
draws, never both at once — comes from the renderer, identically on
every platform. The focus *position* always exists and is always
announced; the drawn indicator is keyboard-origin only — it appears
when focus last moved by keyboard and not when a pointer or touch took
it, because a pointer user knows where they pressed, and a ring there
is redundant noise. Two carve-outs, and only these: a text field
(`text_input`, `text_area`) shows its thickened edge and caret however
focus arrived — keyboard input is about to land there, the same
carve-out every browser's `:focus-visible` ships — and a picker's row
highlight follows focus whichever input moved it, because it marks the
row about to be chosen, not how focus got there. The DOM edition gets
the rule from
`:focus-visible`; the Skia edition tracks the origin in core, so the
two agree by construction. There is exactly one focus model to test.

**No gesture is ever the only way to anything.** nokre has one gesture
at all — the edge pan that goes back ([routing.md](routing.md)) — and
what it activates is the Back control the framework already installed on
that screen: a real focus stop, named by the framework, reachable by Tab and by
every screen reader's own navigation. A pushed screen without that
control cannot exist, so there is no state a user reaches the gesture's
destination *only* by dragging. Its threshold is drawn as well as felt,
because a device with haptics off would otherwise leave a sighted user
committing blind, and screen-reader users never need it: VoiceOver and
TalkBack have their own back conventions, and the control is there for
both.

## Enforcement

nokre's position is that a consumer should never face an accessibility
decision at all — the framework already made it. Enforcement therefore
happens in two tiers, and neither is opt-in.

### Invalid trees cannot be built

`Tree.append` rejects malformed structure at the call site — detection
after the fact would mean the bad state existed:

- interactive elements (button/link/toggle/input/segmented/nav item)
  with an empty label — `error.UnlabeledInteractive`
- non-row children of tables, non-cell children of rows, rows outside
  tables, cells outside rows, a row past 32 cells
- a nav off the root, a second nav, non-item children of a nav, nav items
  outside a nav, or a nav mixing its two shapes — the row of destinations
  and the collapsed chip cannot both stand, or the same section would be
  in the focus order twice
- a sheet or notice off the root, a second one of either, an untitled
  sheet, an empty notice
- a `more` control anywhere but on a horizontal stack, or a second one on
  the same row — the folded tail of a row of actions is the framework's
  to install (`error.MoreOutsideButtonRow`, `error.MultipleMoreControls`)
- choice controls (segmented, radio group, select) with fewer than two
  options, empty option labels, or a selection out of range
- empty badges, valueless copyables, wordless or out-of-range meters,
  unlabeled/valueless/unencodable QR codes
- text that would be illegible where it sits: any element drawing text on
  the ambient background (text, headings, links, toggles, inputs) must
  clear WCAG AA contrast (4.5:1) against the nearest box fill, **in both
  appearances** — the two ramps are independent, so a pair can clear the
  floor in light and fall under it in dark — `error.InsufficientTextContrast`
- text that would be a glare source: the same pair must also stay at or
  below 16:1. True ink on true paper is 21:1, which is past the point
  where contrast buys legibility — `error.ExcessiveTextContrast`

Structure is refused; encoding is repaired. Every string entering
tree-owned memory — append fields and spans, choice options,
`setContent`, an IME update, typed text — is validated during the copy
the tree already makes, each invalid sequence becoming one U+FFFD
(maximal subparts, deterministically). The tree holds only well-formed
UTF-8, so a fetched document carrying arbitrary bytes renders as text
and every scan downstream trusts sequence lengths instead of
re-checking them.

Mutation faces the same gates: `setContent` on a `text` element re-runs
the append contrast check once the new content has visible words
(`error.InsufficientTextContrast`, the element untouched on refusal),
and on a field it clamps a stale caret to a codepoint boundary rather
than leave it dangling mid-sequence.

`App.setNav` additionally rejects fewer than 2 or more than 5 destinations
(`error.NavItemCount`), a destination the route table does not have
(`error.UnknownRoute`), and one whose route takes arguments
(`error.RouteArgCount`) — an unnamed or unpressable destination is
refused at the roster rather than drawn.

The design system itself is proven, not reviewed: unit tests in
[src/core/color.zig](../src/core/color.zig) assert that every text alias
sits inside the readable band — at or above WCAG AA and at or below 16:1
— on paper in both appearances, that component boundaries clear non-text
contrast (3:1), and that the dark ramp *eases* text rather than mirroring
it (an inversion would leave dark exactly as harsh as light, which is the
wrong answer for the appearance where halation is worse); a test in
[src/core/layout_test.zig](../src/core/layout_test.zig) asserts that no
interactive element can lay out below the 24×24 minimum target size
(WCAG 2.5.8), and a second one that every control which is *nothing but
a target* — a bare glyph (`icon_button`, `back`, `sheet_close`, an
`icon_only` button, the notices indicator) or a `checkbox`/`toggle` row —
lays out at the full 44×44 of WCAG 2.5.5 (AAA), which is also Apple's
44pt. The 24px floor is what conformance permits; it is not a size a
finger can reliably hit, and a control with no pill and no words draws
no border to say where it ends.
Changing a palette byte or a metric that breaks compliance fails the build.

### The audit

[src/testing/audit.zig](../src/testing/audit.zig) covers the residue that
construction cannot see: whole-tree content rules, and state that later
mutation or removal could degrade. The harness runs it automatically at
init and after every driver action — there is nothing to remember. It
fails on:

- `heading_level_skipped` — a heading more than one level deeper than
  the previous heading (h1 → h3 with no h2 between)
- `duplicate_interactive_label` — two enabled interactive elements with
  the same accessible name are ambiguous to voice control, to screen
  reader users, and to test queries alike. Judged within the active
  layer only: everything behind an open sheet, picker, or notices pane
  is inert and cannot collide with what is in front of it — and the
  audit re-runs when the layer closes, catching a pair the moment both
  are live
- `unlabeled_interactive` — a label emptied by mutation after append
- `nav_item_count` — a nav whose destinations fell outside 2–5, or whose
  rendered shape stopped matching the set it was given (removal). The
  off-roster marker is not a destination and is not counted
- `empty_nav_here` — the off-roster marker's title emptied by mutation
  after append; a plate with no words says you are nowhere
- `malformed_segmented` / `malformed_radio_group` / `malformed_select` —
  options or selection mutated into an invalid state
- `insufficient_text_contrast` / `excessive_text_contrast` — an ink or box
  fill mutated after append into a pair that is illegible in either
  appearance, or harsh enough to glare
- `sheet_missing_dismiss` — an open sheet with no enabled button left in
  it; Esc still works, but pointer users need a visible way out
- `untitled_document` — a `document`'s label emptied by mutation after
  append; the label is its accessible name, and nothing else in a
  parsed document can stand in for one
- `malformed_progress` — a button's `progress_percent` pushed past 100,
  or work cleared while a number is left behind: a meter measuring
  nothing is the one thing worse than no meter
- `untitled_sheet` / `empty_notice` / `empty_badge` / `empty_copyable` /
  `malformed_meter` / `malformed_qr` — content emptied or degraded by
  mutation after append
- `empty_code_block` — a verbatim block emptied by mutation, leaving a
  tab stop over blank space
- `empty_list` — a `list` with no items. This one is not about
  mutation: a list is appended before its items exist, so `append` has
  nothing to check and the whole-tree pass is the only place the rule
  can live
- `cleanly_clipped_scroll_region` — an overflowing fixed-height scroll
  region whose offset-0 edge cuts nothing visible. The resting
  indicator is deliberately quiet, so the mid-element cut is what makes
  the overflow perceivable; an edge landing in a gap, on an element
  boundary, or in a text line's leading reads as complete content.
  Fill (null) heights and the picker's list resolve against the
  viewport and are exempt — a rule firing only on some devices would
  be unfixable

Because the audit inspects the same tree that renders, a passing audit is a
real guarantee, not a lint heuristic.

## Reaching assistive tech

The `Snapshot` is produced and tested platform-independently; each
platform shell attaches an adapter that feeds it to the OS —
[AccessKit](https://accesskit.dev) on desktop, UIAccessibility on iOS,
an `AccessibilityNodeProvider` on Android. On the web there is nothing
to feed: the DOM the app renders *is* the accessibility tree, not a
mirror of one. Bridge work touches zero application code, so the
backend is a shell property: the [README](../README.md) support matrix
lists each platform's, and
[internals/platform-shells.md](internals/platform-shells.md) shows how
the bridges are built.
