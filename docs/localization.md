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

// In a build function or action: the app's chosen locale (App.setLocale)
// picks the catalog.
const loc = L.resolve(app.locale());
const b = app.root();
try b.heading(.h1, L.tr(loc, .inboxTitle));
try b.text(try L.fmtIn(&app.tree, loc, .nUnread, .{ .count = unread }));
```

`Bundle` returns a type: `Locale` (one enum field per source, named by
its `@@locale` — `"pt-BR"` becomes `.pt_BR`), `Key` (one field per
message id), and the calls:

| Call | Contract |
| --- | --- |
| `tr(locale, .key)` | A message with no placeholders, as a slice of constant data. No buffer, no error. Calling it on a message *with* placeholders is a compile error pointing at `fmt`. |
| `trAny(locale, key)` | `tr` for a key that exists only at **runtime** — a table-driven label (month words, enum-indexed captions) where `tr`'s comptime key would force a switch per arm. One read of a comptime-generated dense table, the same constant bytes `tr` returns. A key whose message has placeholders is a programming error and panics naming the key — the runtime twin of `tr`'s compile error. |
| `fmt(buf, locale, .key, args)` | Formats into the caller's buffer, returns the written slice. `args` is an anonymous struct with exactly the message's placeholders — a missing, extra, or mistyped field is a compile error naming the message. The only runtime error is `NoSpace`: text is never silently truncated. |
| `fmtIn(tree, locale, .key, args)` | `fmt` into the tree arena — `Tree.fmt`'s contract for a catalog message, and the form for a label the tree is about to store: no buffer to size, no `NoSpace`, the slice valid for the tree's lifetime. Placeholders are checked exactly as `fmt` checks them. `fmt` remains the form for bytes that outlive the tree (storage keys, worker messages). |
| `resolve(tag)` | Runtime tag → bundled locale: exact match first (case and `-`/`_` ignored), then bare-language match in source order, then the template. `"fa-IR"` finds `.fa`; `"de"` against an en/fa bundle yields `.en`. |
| `of(app)` | `resolve(app.locale())`, made once, as a **bound view**: `L.of(app).tr(.key)`, and likewise `trAny`/`fmt`/`fmtIn`/`tag`/`dir`/`chrome` with the locale argument gone and the resolved locale readable as `.locale`. A value, not a reference — honest because a build or an action is one moment in one locale. Takes anything that answers `locale()` with a tag (the App, a test harness). |
| `in(app)` | `of`'s twin for the one call that allocates: the locale **and** the tree the bytes land in, both from the app. `try L.in(app).fmt(.key, args)` is `fmtIn` with nothing re-passed — at a build site the tree is always `&app.tree` (a `Cursor`'s `tree` is that pointer), so naming it beside the app was only a chance to name the wrong one. `fmt` here means the arena; the lifetime is `fmtIn`'s, unchanged. A second binder rather than a wider `of`, because `of` needs only `locale()` and nothing that knows just its locale should lose a call. |
| `chrome(locale)` | nokre's own words (`App.Chrome`) out of this catalog, via one **reserved key per field** — see [The framework's own words](#the-frameworks-own-words). |
| `tag(locale)` | The `@@locale` string back — what `App.setLocale` takes, and what storage keeps. |
| `dir(locale)` | The locale's writing direction (`l10n.Direction`), read from its tag at comptime. Feed it to `App.setDirection` to mirror the chrome — see [Right-to-left](#right-to-left). |

There is no allocation anywhere, and no state in the bundle: which
locale the app is *in* is the **App's own state** — chosen with
`App.setLocale` (or `Options.locale` at boot), read back as a tag with
`App.locale()`, "" until chosen — so every screen, controller, and
route title reads one live fact instead of keeping a copy a change
could miss. Which locale the *device* wants is the `locale` service
([services.md](services.md)) — on a page nokre generated it is the
language that page was written in, reported on the same lane and
resolved by the same line — and `resolve` is the bridge:

```zig
// The device picks the catalog, the catalog decides the rest.
const dev = h.services.locale.tag(app);  // "fa-IR", or "" if it won't say
const loc = L.resolve(dev);              // "" and unbundled → the template
try app.setLocale(L.tag(loc));           // the app is now *in* that locale
app.setDirection(L.dir(loc));            // see Right-to-left, below
```

A device tag nokre's bundle doesn't carry is not an error state, it is
the template — the fallback `resolve` was written for. A language
switched mid-session runs the same lines from the service's change
handler; the chosen tag is App state, so reading it per frame costs
nothing.

`setLocale` is also what a *generated* page says it is in: the third
line above is where the `lang` attribute on a serialized document comes
from, so an app that renders pages without it publishes them claiming a
language it may not be speaking.

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

- **Placeholders** — `{name}`, typed by metadata: `String`,
  `int`/`num` (both are integers here; counts are integers, and
  fractional plurals would drag float formatting into core), or
  nokre's own `date` (below). An undeclared placeholder defaults to
  String, or to the kind its usage implies (a plural count is an int,
  a `{name, date, …}` reference a date).
- **Dates** — `{when, date, skeleton}` over a **civil date the caller
  supplies**: any struct with integer `year`, `month`, `day` fields —
  `l10n.Date`, `l10n.dateFromMillis(millis)` for the epoch
  milliseconds servers speak (integer Hinnant math, UTC), or a domain
  model that already carries the three. The skeleton set is closed:
  `y`, `M`, `d` render one unpadded component; `MMM` renders the
  month's *word*; `yMd` is ISO 8601 `y-MM-dd`, the locale-blind
  numeric form. Order and separators belong to the message — each
  locale writes the components where it wants them, the same authority
  translators hold over every other word — which is why the combined
  text skeletons (`yMMMd`) don't exist: they would fix an order the
  message can already state.

  ```json
  "dateLabel": "{when, date, d} {when, date, MMM} {when, date, y}",
  "@dateLabel": { "placeholders": { "when": { "type": "date" } } }
  ```

  `MMM`'s words are the catalog's, not nokre's: the twelve **reserved
  keys** `monthJan` … `monthDec`, ordinary messages required (at
  compile time) the moment any message uses `MMM`, in every locale the
  bundle carries. Digit shaping applies to date numbers exactly as to
  counts. A bare reference to a date placeholder (`{when}` with no
  skeleton) is a compile error — a date without a format would have to
  guess one, which is the locale-library behavior this kind exists to
  refuse. No clock and no zone anywhere: the value is the caller's,
  so the same arguments are the same bytes forever.
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
// On locale change (and once at startup), beside setLocale:
app.setDirection(L.dir(loc));   // L.dir(.fa) is .rtl, L.dir(.en) .ltr
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
fn applyLocale(state: *State, loc: L.Locale) void {
    state.app.setLocale(L.tag(loc)) catch {}; // what each screen is called
    state.app.setChrome(L.chrome(loc));       // nokre's own words
    state.app.setDirection(L.dir(loc));       // which way the chrome runs
}
```

**A screen's name is the route table's** — `RouteDef.title`, which every
line of the nav is labelled from ([routing.md](routing.md)): the
destinations, the collapsed chip's section, the rows of the picker it
opens, and the marker for a screen that is none of them. That is one
home on purpose, so a nav and a screen's own chrome cannot disagree. A
translated app declares each title as a **function of the chosen
locale** and the one table serves every language:

```zig
const routes = nok.Routes(State).table(&.{
    .{ .name = "notes", .title = .{ .of_locale = notesTitle }, .build = buildNotes },
    .{ .name = "note", .title = .{ .of_locale = noteTitle }, .args = 1, .build = buildNote },
    .{ .name = "settings", .title = .{ .of_locale = settingsTitle }, .build = buildSettings },
});

fn notesTitle(tag: []const u8) []const u8 {
    return L.tr(L.resolve(tag), .notesTitle);
}
```

The **chosen locale is the App's own state**: `Options.locale` for an
app that knows it at boot, `App.setLocale(L.tag(loc))` whenever it
changes, `App.locale()` to read it back, and `""` — the tag of an app
that never chose — until then, which `resolve` already reads as the
template. Pass the tag of the locale actually on screen (the *resolved*
one), so the titles and the catalog agree. A title function must answer
**every** tag with constant data — `tr` hands back exactly that — and
`setLocale` verifies it before committing: a tag some title answers
with nothing is `error.EmptyRouteTitle` and the app is left exactly as
it was, the same footing as the empty `.fixed` title `App.init`
refuses. The nav re-says itself on the spot: a row of destinations, a
collapsed chip and the marker beside them all change together, with no
second table to hold and no positional re-stamp to forget.

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
app.setChrome(L.chrome(loc)); // every word, from the catalog, or no build
```

`L.chrome(locale)` is the localized app's opt-in, and the shape to
reach for the moment a second language exists. It reads one **reserved
key per `Chrome` field**, the name derived from the field's — `chrome`
plus the field camel-cased at its underscores:

| Field | Reserved key |
| --- | --- |
| `back` | `chromeBack` |
| `close` | `chromeClose` |
| `section` | `chromeSection` |
| `current_screen` | `chromeCurrentScreen` |
| `sections` | `chromeSections` |
| `notices` | `chromeNotices` |
| `show_notices` | `chromeShowNotices` |
| `show_all_notices` | `chromeShowAllNotices` |
| `minimize_notices` | `chromeMinimizeNotices` |
| `dismiss_all_notices` | `chromeDismissAllNotices` |
| `open_prefix` | `chromeOpenPrefix` |
| `dismiss_prefix` | `chromeDismissPrefix` |
| `important` / `other` | `chromeImportant` / `chromeOther` |
| `copied` | `chromeCopied` |
| `more` | `chromeMore` |

A catalog missing one of them does not compile — the posture the rest
of this document already holds, a catalog mistake is a build error,
extended to the one place it could not reach: a bare `Chrome` literal
compiles with a field missing, and the miss ships as English in the
middle of a translated nav bar, silently, until a reader of that
language hears it. The bare literal stays for what its defaults are
for: the zero-config app, or one saying a word or two. Nothing to
re-declare when nokre grows a chrome string, either — the key is
derived from the field, so the new field simply stops every opted-in
app compiling until its catalogs say the new word, in every locale
they carry (key parity does the fanning out). The reserved keys are
ordinary messages otherwise — placeholder-free, required, translated
where every other word lives.

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
- **Reserved keys.** A message using `{…, date, MMM}` requires
  `monthJan`…`monthDec`; an app calling `chrome(locale)` requires one
  `chrome…` key per `App.Chrome` field. Both are ordinary messages —
  required placeholder-free, translated everywhere by key parity — and
  a miss is a build error naming the key. A bare `{when}` reference to
  a date placeholder, and an unknown date skeleton, fail the same way.
- **Call sites.** `fmt` args are matched against the message: missing
  argument, unknown argument, string where a count belongs, a
  non-civil-date value where a date belongs — each is a compile error
  naming the message and the field.

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
  different bytes on different OS versions — and `DateTime` needs a
  clock, which nokre's core does not have. Format decimals in app code
  and pass a String; pass counts as integers; pass calendar dates as
  the `date` kind's civil value — the one date shape admitted, because
  the caller owns the value and fixed skeletons own the bytes.
- **No `{n, number}` / `{n, time}` argument types**, for the same
  reason. A bare `{n}` renders an int deterministically, and
  `{n, date, skeleton}` is the deterministic date (its skeleton set is
  closed; there is no freeform pattern to vary by platform).
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
- **No localized route arguments** — the one refusal here that lands at
  the call rather than at compile time. A route argument is an
  identifier, so `router.zig`'s `validIdent` admits `[A-Za-z0-9_.-]` and
  nothing else: a Persian or Turkish slug is refused outright by
  `Router.writeRef` (`error.RouteArgCharset`) and by the same check on
  the way back in (an `.arg_charset` refusal), never transliterated,
  percent-encoded or otherwise quietly repaired. The ground is the
  router's own — *"an argument is an identifier and not a payload. Free
  text is a URL, which is deep_link's business"* — and it does not move
  for a locale. What this costs a multi-locale surface is the localized
  *slug*, not the localized page: key the route by an ASCII id and
  localize the words the screen puts on it, the way route titles are
  localized under [The chrome nokre writes](#the-chrome-nokre-writes)
  above. A BCP 47 locale tag is itself ASCII, so a per-locale route
  argument is fine; `note~fa` is a reference, `note~یادداشت` is not.

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
| Number formats | intl NumberFormat | Refused; integers only |
| Dates | intl DateFormat over a `DateTime` | A caller-supplied civil date, closed skeleton set, month words as reserved catalog keys |
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
