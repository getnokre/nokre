# Markdown

A `document` element takes a label and a Markdown source, parses it at
`append`, and expands it into ordinary child elements. The motivating
case is legal content — terms, a privacy policy — fetched over HTTP and
rendered in-app:

```zig
const body = try fetchTerms(gpa); // bytes you did not write
defer gpa.free(body);             // the tree copied them; free at once
try app.tree.append(root, .{ .document = .{
    .label = "Terms of Service",
    .source = body,
} });
```

Nothing else in nokre learns about Markdown.

## Why an element, not a renderer

`document` is a regular element that expands into children, not a
renderer with private drawing rules. The expansion produces only
elements the framework already knows — `heading`, `text`, `list`,
`code_block`, `blockquote`, `table`, `divider` — so the element set
stays closed, and every append-time gate (contrast, structure, labels)
applies to parsed content for free. **The parser's error path is
`append`'s.** A document the tree refuses fails at the call site, whole,
leaving nothing half-built behind.

The label is explicit and mandatory. Deriving a name from the first `h1`
fails on documents that do not open with one, and legal text often does
not. The source is copied like every other string ([tree.zig](../src/core/tree.zig)
never borrows consumer memory), so an app may free its response buffer
the moment `append` returns.

## The subset

| Markdown | Becomes |
| --- | --- |
| `# ` … `###### ` | `heading`, levels rebased (below) |
| paragraph | `text`; source line breaks become spaces |
| two trailing spaces, or a trailing `\` | a hard break inside the paragraph |
| `---`, `***`, `___` | `divider` |
| `**strong**`, `__strong__` | a `strong` span |
| `*emphasis*`, `_emphasis_` | an `emphasis` span (underscores, inside a word, are literal — below) |
| `~~strike~~` | a `strike` span (doubled only — a lone `~` is punctuation) |
| `` `code` `` | a `code` span |
| `[label](destination)` | an inline link span — a route, or an external URL on the allowlist (below) |
| `- ` / `* ` / `+ ` | an unordered `list` |
| `1. ` / `1) ` | an ordered `list`, starting at the first number |
| ` ``` ` / `~~~` fences | `code_block` |
| `> ` | `blockquote` |
| GFM tables | `table` / `row` / `cell` |

## The two emphasis markers are not interchangeable

An `_` run with a word character on **both** sides is punctuation, not a
marker: `snake_case`, `__init__` and `plural_rules.zig` come through as
written. `*` keeps no such exception — `a*b*c` emphasizes the `b`,
because that is nobody's identifier. The asymmetry is CommonMark's, and
it is here for the reason CommonMark has it: a parser that reads the
middle of an identifier as a marker turns a file name into italics, and
prose about code is full of file names.

The rule is about the run's neighbors, not its position, so it composes:
`_foo_bar_` emphasizes `foo_bar`, since the middle run is inside a word
and the outer two are not. Bytes past ASCII count as word characters, so
a marker between two Persian letters is intraword too — a rule that read
one script's identifiers and not another's would be a worse rule.

A link label may carry an intraword underscore for the same reason:
`[secure_store.md](internals/secure_store.md)` is a link. One that would
open emphasis still degrades the whole link, per the label rule below.

## Everything else degrades to its literal source text

Unsupported syntax comes through **as written, markers included**,
rather than being dropped or raising. That is what makes parsing bytes
you do not control safe: the error path stays genuinely rare, because an
error means the tree refused the content, never that the parser met
something new.

It is a property, not a hope — every byte of a degraded construct
appears exactly once, in source order, and
[markdown_test.zig](../src/core/markdown_test.zig) asserts it over a
corpus. So `<div>x</div>` renders as `<div>x</div>`, and a reader loses
the formatting but never the words.

### The subset is closed

What the table above leaves out is refused, not pending. Like the
element set, the subset is closed on purpose, and additions are argued
on semantics — the table is the whole of it:

- **Images.** nokre draws text, lines, and boxes. A picture is not a
  thing this library can render, so there is nothing for the syntax to
  produce.
- **Task lists, footnotes, definition lists.** Each wants an element the
  set does not have, and each is argued on presentation rather than
  meaning. A checklist is `checkbox`es; a footnote is a `link` to a
  section.
- **Inline HTML.** A second, unbounded language inside the first. The
  entire value of parsing a subset is that its output is bounded, and
  bounded output is what lets every append-time gate apply to content
  nobody reviewed.
- **External destinations off the allowlist.** A destination whose
  scheme is `https`, `http`, or `mailto` becomes a real external link
  (below); every other scheme stays literal — the closed set is
  [open_url](services.md)'s, applied here.
- **Setext headings** (`===` underlines), **reference links**, **HTML
  entities.** Alternative spellings of constructs the subset already
  covers — more parser for no more meaning.
- **Marked-up link labels** (`[**Terms**](terms)`). See below: one link
  is one focus stop, and that is the constraint, not an omission.

Three more things degrade rather than fail, because content nokre does
not control must never be able to raise:

- **A heading or a table inside a list item or a blockquote.** Both are
  outside the document block set `Tree.append` enforces (see
  [elements.md](elements.md)), so they come through as literal text.
- **A table wider than 32 columns.** `Tree.append` refuses the cell
  that would open a 33rd ([elements.md](elements.md)), so the whole
  table comes through as literal text.
- **List nesting past three levels.** The fourth level's items join the
  third level's item rather than opening a list `append` would refuse.

## Heading levels are rebased

The first heading depth in a document becomes `h1`, and each distinct
deeper depth the next level:

| Source | Rendered |
| --- | --- |
| `## Opening` | `h1` |
| `#### Jumped` | `h2` |
| `##### Deeper` | `h3` |
| `## Back up` | `h1` |

Fetched Markdown routinely opens at `##` or jumps `h2` → `h4`, which
would trip the `heading_level_skipped` audit rule
([accessibility.md](accessibility.md)) on content the app cannot fix.
Rebasing preserves the real outline and leaves the rule intact for
app-authored trees — it is not a loophole, because it only applies
inside a `document`.

## Destinations: routes, and the external allowlist

A destination without a URI scheme is a route reference:
`[label](destination)` becomes an inline link span resolved by the
router at activation exactly like a `link` element's — so one that does
not resolve is refused where every other bad route is
([routing.md](routing.md), errors and refusals), and the parser needs
no router access.

A destination may carry route arguments, since `~` is not a URI scheme:
`[the flaky build](ticket~2938)` is an in-app link to that ticket
([routing.md](routing.md)). The parser does not look at them — arguments
are resolution's business, like the name.

A destination whose scheme is on the
[open_url](services.md) allowlist — `https`, `http`, `mailto` —
becomes an **external link span**: same underline, same tab stop, same
announced role, and activation hands the URL to the system browser
through that service. The motivating content is exactly this file's:
fetched legal text realistically carries a `mailto:` and third-party
references, and rendering them as raw syntax served no one. nokre still
renders no external content — the page opens where the user's own
chrome and trust live, the same posture [oauth](services.md) already
takes for sign-in.

Everything else keeps the degradation rule, and that boundary is
pinned by tests: a scheme off the allowlist (`ftp://…`,
`javascript:…`, `file://…`) and a protocol-relative `//host` degrade
the whole link to literal text. `[it](ftp://example.com/x)` renders as
`[it](ftp://example.com/x)`. Which side a destination falls on is
decided **syntactically**, never by a route lookup or a fetch — the
closed scheme set is open_url's one fact, consulted by the parser and
enforced again at `append`, so a link that can be built is a link the
service will open.

A link's label must be plain text. Inline markup inside one would need
either nested spans (which the element set does not have) or several
spans sharing a route — which would make one link several tab stops, and
a control that is three tab stops is three controls to everyone
navigating by keyboard. So `[**Terms**](terms)` degrades whole: the
words survive, the markers show, and the link stays one thing.

## Determinism

The parser is pure Zig with no dependencies, integer-only, and lives in
core ([markdown.zig](../src/core/markdown.zig)) — `core/qr.zig` is the
precedent for a content module there. Allocation is bounded: one scratch
arena per `append`, released before it returns, plus fixed per-paragraph
and per-heading budgets whose overflow merges rather than truncating.
The contract is `!void` and only `!void`: the input is remote bytes, so
the fuzz target in
[markdown_test.zig](../src/core/markdown_test.zig) exists to keep it
that way. Encoding is the tree's boundary, not the parser's: every
string entering the tree is validated during the copy, invalid
sequences becoming U+FFFD
([accessibility.md](accessibility.md#invalid-trees-cannot-be-built)),
so arbitrary bytes render as text, never crash.
