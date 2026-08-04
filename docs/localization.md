# Localization

nokre reads the same catalog format Flutter does — ARB, one JSON file
per locale, ICU message syntax — and then takes a different road: no
`l10n.yaml`, no generated file, no runtime parsing. The `.arb` sources
are embedded and compiled at comptime; the catalog *is* the code.

```zig
const L = h.l10n.Bundle(&.{
    @embedFile("l10n/app_en.arb"), // first source = the template
    @embedFile("l10n/app_fa.arb"),
});

// Somewhere in app state:
locale: L.Locale = L.default_locale,

// In a build function or action:
try tree.append(root, .{ .heading = .{ .content = L.tr(state.locale, .inboxTitle), .level = .h1 } });

var buf: [128]u8 = undefined;
const line = try L.fmt(&buf, state.locale, .nUnread, .{ .count = unread });
try tree.append(root, .{ .text = .{ .content = line } });
```

`Bundle` returns a type: `Locale` (one enum field per source, named by
its `@@locale` — `"pt-BR"` becomes `.pt_BR`), `Key` (one field per
message id), and five functions:

| Call | Contract |
| --- | --- |
| `tr(locale, .key)` | A message with no placeholders, as a slice of constant data. No buffer, no error. Calling it on a message *with* placeholders is a compile error pointing at `fmt`. |
| `fmt(buf, locale, .key, args)` | Formats into the caller's buffer, returns the written slice. `args` is an anonymous struct with exactly the message's placeholders — a missing, extra, or mistyped field is a compile error naming the message. The only runtime error is `NoSpace`: text is never silently truncated. |
| `resolve(tag)` | Runtime tag → bundled locale: exact match first (case and `-`/`_` ignored), then bare-language match in source order, then the template. `"fa-IR"` finds `.fa`; `"de"` against an en/fa bundle yields `.en`. |
| `tag(locale)` | The `@@locale` string back, for display or storage. |
| `dir(locale)` | The locale's writing direction (`l10n.Direction`), read from its tag at comptime. Feed it to `App.setDirection` to mirror the chrome — see [Right-to-left](#right-to-left). |

There is no allocation anywhere, and no state: which locale is current
is one field in *your* app state, changed like any other state — set it,
rebuild, done. Which locale the *device* wants is the `locale` service
([services.md](services.md)), and `resolve` is the bridge:

```zig
// In build: the device picks the catalog, the catalog decides the rest.
const dev = h.services.locale.tag(app);  // "fa-IR", or "" if it won't say
state.locale = L.resolve(dev);           // "" and unbundled → the template
app.setDirection(L.dir(state.locale));   // see Right-to-left, below
```

A device tag nokre's bundle doesn't carry is not an error state, it is
the template — the fallback `resolve` was written for. A language
switched mid-session runs the same three lines from the service's
change handler; the tag is cached app state, so reading it per frame
costs nothing.

## The format

An ARB file is a JSON object. `@@locale` is required — nokre embeds
file contents, so there is no filename to infer from. `@@`-prefixed
provenance (`@@author`, `@@last_modified`, `@@x-…`) is accepted and
ignored. Each message may carry `@message` metadata; nokre reads only
`placeholders`, and only from the template — `description` and
`example` are for translators and tooling.

```json
{
  "@@locale": "en",
  "inboxTitle": "Inbox",
  "nUnread": "{count, plural, =0{All caught up} one{# unread message} other{# unread messages}}",
  "@nUnread": {
    "description": "Unread badge line under the inbox heading",
    "placeholders": { "count": { "type": "num" } }
  },
  "fromSender": "From {name}",
  "@fromSender": {
    "placeholders": { "name": { "type": "String", "example": "Ada" } }
  },
  "pronoun": "{gender, select, male{he} female{she} other{they}}"
}
```

Supported message syntax, deliberately Flutter-compatible:

- **Placeholders** — `{name}`, typed by metadata: `String`, or
  `int`/`num` (both are integers here; counts are integers, and
  fractional plurals would drag float formatting into core). An
  undeclared placeholder defaults to String, or to int when it is used
  as a plural count.
- **Plurals** — `{count, plural, =0{...} one{...} other{...}}`: `=N`
  exact matches (which win over categories, per ICU), the six CLDR
  category keywords, and `#` for the count. Nesting is allowed, and `#`
  inside a select nested in a plural still means the enclosing count.
- **Selects** — `{gender, select, male{...} female{...} other{...}}`:
  case-sensitive match, `other` mandatory, unmatched values fall to it.
- **Escaping** — ICU quoting as Flutter's `use-escaping: true`, always
  on: `''` is a literal apostrophe; `'` opens a quoted run only
  immediately before `{`, `}`, or a plural's `#`, so prose apostrophes
  (`Isn't`) pass through unquoted. A literal brace is `'{'`.

Integers render with no grouping separators, in the digit shapes of the
catalog doing the formatting: a `fa` catalog writes Extended
Arabic-Indic digits (۰–۹, U+06F0–U+06F9), an `ar` catalog Arabic-Indic
(٠–٩, U+0660–U+0669), and every other locale ASCII. The shape is read
from the language subtag of the `@@locale` tag against a fixed table —
there is no setting, because the locale already is the decision — and
each set is a ten-codepoint substitution, so the same count is still
the same bytes on every platform; the determinism argument that refuses
NumberFormat does not reach it. Digits only: the minus sign stays ASCII
`-`, and there are no separators to localize. Plural categories are
selected on the numeric value, never on the shaped string.

## Right-to-left

There are two questions here, and nokre keeps them separate: which way
the *text* reads, and which way the *chrome* is laid out.

**Text is decided by the text.** Persian and Arabic render correctly
with nothing declared: direction is derived from the string itself (UAX
#9's first-strong rule, per hard paragraph), an RTL paragraph
right-aligns its lines, embedded Latin and numbers take their own
left-to-right runs, and Arabic script shapes through the bundled
companion face. There is no `dir` attribute and no per-locale direction
flag in ARB — a Persian string in an English locale and an English
string in a Persian locale each lay out correctly on their own evidence.
This never depends on the setting below.

**Chrome is decided by you.** Whether the interface mirrors —
navigation order, field labels, chevrons, toggle knobs, scrollbars,
table columns — is `App.setDirection(dir)`, one call, defaulting to
`.ltr`. It is not inferred from the strings on screen, because the same
screen can carry both scripts; it is a property of the locale, which the
locale knows. The bridge is in the bundle:

```zig
// On locale change (and once at startup):
app.setDirection(L.dir(state.locale));   // L.dir(.fa) is .rtl, L.dir(.en) .ltr
```

`L.dir(locale)` reads the direction from the `@@locale` tag at comptime,
and is what the three lines above pass on: the chrome mirrors the
language actually on screen — the *resolved* locale — not the one the
device asked for. For a tag that never passes through a bundle (a saved
preference, a tag echoed back by a server, the device tag when you
branch on it before resolving), `l10n.directionOfTag("fa-IR")` does the
same at runtime: an explicit script subtag decides (`az-Arab` is RTL,
`az-Latn` LTR), otherwise the primary language subtag's default script
does, and anything unknown — the empty tag included — is `.ltr`. Both
return `l10n.Direction`, which is what `setDirection` takes.

Under `.rtl` every leading/trailing choice flips together: intrinsic
blocks and tables snap to the right, horizontal stacks and nav slots run
right-to-left, field labels and values lead from the right, the back and
tile chevrons point the other way, toggle knobs travel the other way,
and the overlay scrollbar moves to the left. Two things deliberately do
*not* follow the chrome: paragraph text still aligns by its own content
(an English caption stays left-aligned inside a mirrored screen), and a
QR code's modules never mirror — a mirrored symbol does not scan. The
vertical axis is direction-blind throughout, so `↑`/`↓` in a radio group
mean the same thing in both, while `←`/`→` swap with the layout.

## The chrome nokre writes

Two things on a screen carry words the app never typed at the point they
appear: what a **screen** is called, and what nokre's **own controls**
are called. Both are localizable, from their own home, and a locale
change says all of it in three lines beside `setDirection`:

```zig
fn applyLocale(state: *State, loc: L.Locale) !void {
    state.locale = loc;
    state.app.setChrome(chromeFor(loc));   // nokre's own words
    state.routes = routesFor(loc);          // borrowed: it outlives the call
    try state.app.setRouteTitles(&state.routes); // what each screen is called
    state.app.setDirection(L.dir(loc));     // which way the chrome runs
}
```

**A screen's name is the route table's** — `RouteDef.title`, which every
line of the nav is labelled from ([routing.md](routing.md)): the
destinations, the collapsed chip's section, the rows of the picker it
opens, and the marker for a screen that is none of them. That is one
home on purpose, so a nav and a screen's own chrome cannot disagree. But
the table is comptime and a locale is not, so a translated app hands the
**same table** over again with translated titles:

```zig
fn routesFor(loc: L.Locale) [3]nok.RouteDef {
    return .{
        .{ .name = "notes", .title = L.tr(loc, .notesTitle), .build = buildNotes },
        .{ .name = "note", .title = L.tr(loc, .noteTitle), .args = 1, .build = buildNote },
        .{ .name = "settings", .title = L.tr(loc, .settingsTitle), .build = buildSettings },
    };
}
```

The table is **borrowed**, as it is at `App.init` — the router keeps the
slice — so hold it in your own state (or make it a comptime array per
locale). The titles inside it need no such care: `tr` hands back
constant data.

`setRouteTitles` accepts a retitling and nothing else — same length,
same names, same arities, same builders, position for position, or
`error.RouteTablesDiffer`. A stack entry holds an *index* into the
table, so a table that reordered or replaced a route would silently
rename every screen already on the stack, in one language only. Nothing
is committed until the whole table passes, and the nav's roster
re-borrows from the new one on the spot: a row of destinations, a
collapsed chip and the marker beside them all change together.

### The framework's own words

Everything else nokre puts on a screen is nokre's, and no consumer's
*data* can name it — only their catalog. `App.Chrome` is the whole list,
English until an app says otherwise:

| Field | English | Where it appears |
| --- | --- | --- |
| `back` | "Back" | the back control's accessible name; nothing draws it |
| `close` | "Close" | the sheet's close control |
| `section` | "Section" | the collapsed nav chip's *name* (its section is its value) |
| `current_screen` | "Current screen" | the marker for a screen that is no destination |
| `sections` | "Sections" | the chip's picker, as a dialog name and as the nav landmark's |
| `notices` | "Notices" | the notices pane's heading and its name |
| `show_notices` | "Show notices" | the minimized indicator |
| `show_all_notices` | "Show all notices" | the banner's expand control |
| `minimize_notices` | "Minimize notices" | the banner's and the pane's |
| `dismiss_all_notices` | "Dismiss all notices" | the pane's header |
| `open_prefix` | "Open: " | joined to a notice's title, on its open control |
| `dismiss_prefix` | "Dismiss: " | joined the same way, on its dismiss control |
| `important` / `other` | "Important" / "Other" | the pane's two group captions |
| `copied` | "Copied" | the live region an acknowledged `copyable` grows |
| `more` | "More" | the control an overflowing row of actions folds into |

```zig
fn chromeFor(loc: L.Locale) nok.App.Chrome {
    return .{
        .back = L.tr(loc, .back),
        .close = L.tr(loc, .close),
        // …and the rest; anything left out stays English.
    };
}
```

One struct and one call, not a setter per control: these are one fact —
what nokre calls its own chrome — and a locale changes every one of them
at once, so a half-translated nav bar is not a state that can be
reached. Chrome already standing is re-said on the spot, so the call
does not wait for the rebuild that follows a locale change. The strings
are **borrowed**, exactly as `RouteDef.title` is: `tr` hands back
constant data, which is what these are for.

The two prefixes are prefixes and not format strings, deliberately. A
runtime `"Open: {title}"` is a placeholder a translator can drop,
reorder, or mistype, and this document's whole posture is that such a
mistake is a *build* error — but there is no comptime left to check a
string written into a struct at run time. Joining costs the reordering a
few languages would want and buys a string that cannot be wrong.

One of them is also *measured*: `more`, the control an overflowing row
of actions folds into ([elements.md](elements.md#the-folded-tail-more)).
Every other string here rides on the node it names, but layout claims
that control's width while *deciding* the fold — before the control
exists — so this word reaches layout on its own. The consequence is
worth knowing: it is the one chrome string whose translation changes a
layout. A long word takes its room from the row and folds it an action
deeper, rather than clipping the pill that carries it.

## What the compiler checks

Everything below is a build failure with the locale, message, and line
in the error — the categories Flutter's gen_l10n reports at generation
time, plus several it never checks:

- **Key parity, both directions.** A locale missing a template key
  fails; a locale carrying a key the template dropped fails too. There
  is no `untranslated-messages-file`, because there is no such state:
  an untranslated message cannot build, so template text can never leak
  into another locale's screen.
- **Placeholder interface.** The template (its text plus its
  `@`-metadata) defines each message's placeholders. A translation
  using a name outside that set is rejected — the typo is caught in the
  catalog, not at the call site of some other locale. A placeholder
  used both as a count and as a select value is rejected as
  contradictory.
- **Plural completeness, per locale.** Each locale's plural is checked
  against *its own* CLDR integer categories: Russian without `few`
  fails naming a number it would mishandle; English with a `few`
  branch fails too, because that branch can never be selected — dead
  translation work. `=1{...} other{...}` still passes in English:
  `one` selects exactly {1} there, and the exact provably covers it.
  (One deliberate exception: the Romance `many` for whole millions —
  CLDR 42 grammar that almost no catalog writes — falls back to
  `other` at runtime instead of failing the build.)
- **Select case parity.** The template's case set is part of the
  message's interface; every locale must carry exactly those cases. A
  dropped case would fall to `other` silently — in production, in one
  language.
- **Call sites.** `fmt` args are matched against the message: missing
  argument, unknown argument, string where a count belongs — each is a
  compile error naming the message and the field.

The plural rules live in
[src/l10n/plural_rules.zig](../src/l10n/plural_rules.zig) — some fifty
languages across nineteen rule families, integer operands only (which
is what collapses CLDR's grammar to plain arithmetic). A language not
in the table errors only when one of its messages actually uses
`plural`, and the error says where to add the row.

## The refusals

Same posture as everywhere else in nokre
([introduction.md](introduction.md)): what would break determinism is
refused loudly, at compile time, with the reason in the error.

- **No `DateTime`, no `double`, no `format:`.** NumberFormat and
  DateFormat delegate to the platform's locale library, which means
  different bytes on different OS versions — and dates need a clock,
  which nokre's core does not have. Format dates and decimals in app
  code and pass a String; pass counts as integers.
- **No `{n, number}` / `{n, date}` / `{n, time}` argument types**, for
  the same reason. A bare `{n}` renders an int deterministically.
- **No `offset:`** — restate the message with `=N` branches, which say
  the same thing without the arithmetic. **No `selectordinal`** — a
  second CLDR table no consumer has needed yet.
- **No runtime catalog loading.** Catalogs ship inside the binary.
  Downloadable translations are a distribution feature with a cache, a
  version skew story, and a failure mode on first launch — that is an
  app, not a GUI library.
- **No fallback chains.** A bundle has one fallback: the template, and
  only in `resolve`, for a *device* locale nokre doesn't carry.
  Between catalog entries there is no falling back, because parity is
  enforced instead — fallback is what silent untranslated text is made
  of.

## Against gen_l10n

For a reader arriving from Flutter:

| | Flutter gen_l10n | nokre |
| --- | --- | --- |
| Pipeline | `l10n.yaml` → generated Dart class | `@embedFile` → comptime |
| Untranslated key | Falls back to template at runtime; optional report file | Build failure |
| Stale key in a translation | Ignored | Build failure |
| Plural categories | Whatever branches you wrote; misses fall to `other` | Validated against the locale's CLDR set, both directions |
| Select cases | Per-locale freeform | Template's set enforced everywhere |
| Placeholder args | Typed method parameters | Comptime-checked anonymous struct |
| Number/date formats | intl NumberFormat/DateFormat | Refused; integers only |
| Runtime | Parse + lookup through intl | Straight-line writes into your buffer |

The through-line: Flutter treats the catalog as data checked by a tool
you remember to run; nokre treats it as source. If it builds, every
locale is whole.

## Testing

Nothing special is needed: `tr` and `fmt` are pure functions, and the
harness drives the same `App` your shells do ([testing.md](testing.md)).
Assert on rendered text with the locale set in your state, as the
kitchen sink's localization section does
([examples/kitchen_sink/main.zig](../examples/kitchen_sink/main.zig) —
its Russian catalog exists precisely because four plural forms prove
the validation is real). nokre's own coverage is
[src/l10n/l10n_test.zig](../src/l10n/l10n_test.zig).
