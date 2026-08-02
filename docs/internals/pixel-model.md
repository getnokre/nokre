# The pixel model

nokre's promise: **same logical viewport ⇒ same bytes**, every run and
every machine, on the platform that drew them. Why that promise is worth
making — and why it deliberately stops at the platform's edge — is
[introduction.md](../introduction.md)'s story; this document is the
normative contract that makes it true.

## Logical pixels, integer scale

- All layout happens in integer logical pixels (`i32`). There are no
  fractional coordinates anywhere in the API.
- HiDPI is an integer scale factor applied as a transform at the raster
  surface (`Surface.init(w, h, scale)`). A 2× frame is exactly the 1× frame
  with every logical pixel rendered into a 2×2 block (text re-rasterizes at
  the larger size but at identical logical metrics — hinting is off).
- Fractional OS scale factors are rounded to the nearest integer —
  125% → 1×, 150% → 2× (the Windows shell computes `(dpi + 48) / 96`,
  and every shell applies the same policy). No shell letterboxes:
  logical size is the ceiling, and the sub-scale remainder is cropped
  at the window's edge.

## Grayscale, thirteen steps, two ramps

The full palette, from [src/core/color.zig](../../src/core/color.zig): thirteen
steps `g0`–`g12`. A step is a *semantic* position, not a byte — each appearance
supplies its own ramp, and the dark one is deliberately not the light one
reversed.

| Name | Light | Dark |
| --- | --- | --- |
| `g0` | `0x00` | `0xDE` |
| `g1` | `0x15` | `0xCD` |
| `g2` | `0x2B` | `0xB8` |
| `g3` | `0x40` | `0xA5` |
| `g4` | `0x55` | `0x91` |
| `g5` | `0x6A` | `0x80` |
| `g6` | `0x80` | `0x6B` |
| `g7` | `0x94` | `0x5A` |
| `g8` | `0xAA` | `0x49` |
| `g9` | `0xBF` | `0x3B` |
| `g10` | `0xD4` | `0x2C` |
| `g11` | `0xEA` | `0x15` |
| `g12` | `0xFF` | `0x00` |

The light ramp is thirteen evenly spaced bytes across the full range, `g6` (the
middle) being the 50-50 gray. `g7` is the one exception: even spacing puts it at
`0x95`, which is 2.995:1 against paper and so misses the non-text-contrast floor
it exists to satisfy, and it is pulled one byte to `0x94` (3.03:1) instead. The
dark ramp descends — that descent *is* the inversion, which is why no draw site
inverts anything.

Semantic aliases: `ink` = `g2`, `dark` = `g3`, `mid` = `g5`, `light` = `g9`,
`paper` = `g12`.

The aliases sit where WCAG compliance holds by construction, in both
appearances: `mid` on `paper` is 5.4:1 light / 5.3:1 dark (AA body text), `dark`
is 10.4:1 / 8.5:1 (AAA), and `g7` — the lightest step permitted for an
interactive border — is 3.0:1 / 3.0:1 (non-text contrast).

Boundaries come in three tones, and the difference is always which ground they
sit on — the rule is one line: the lightest step that clears 3:1 on *both* sides
of the stroke. The labeled fields (`text_input`, `text_area`, `select`,
`copyable`) outline in `g7`: their borders run the full width of the pane, where
a heavier tone reads as a box rather than a hairline. The compact controls
(toggle, checkbox, radio ring, segmented chips) stay at `g6`, because their
borders sit against the `g11` track, where `g7` falls to 2.5:1. The nav's current
chip goes one further to `mid`: with the bar's track gone the chip carries its
own `g10` fill, and `g6` is only 2.7:1 against that. `g10` is separately the
grouping tone used by `box`, `tile_group`, `badge`, and the separators — that use
carries no state and is not subject to 1.4.11 at all.

The focus indicator is a third thing again: one 2px stroke in `ink`, in one of
two placements, and never two lines at once. Where the element already owns an
outline — the labeled fields, the radio-group box, an outlined button, the rows
and chips packed into groups — focus *takes that outline over*: the box does not
move, its boundary thickens and darkens. Everything else gets the outset ring,
held two pixels clear of the rect. The clear is structural rather than
decorative: two anti-aliased arcs sharing a boundary do not sum to full
coverage, and the shortfall reads as a light hairline tracing the corner —
which is what a ring drawn flush against a filled pill produced. The one
exception is an inline link, whose ring hugs the line box, because the lines
above and below leave no room for the clear and a line box paints nothing at its
own edge anyway.

`ink` and not `dark` is forced by the first placement: WCAG 2.4.13 asks for 3:1
between the focused and unfocused states of the indicator's own pixels, and over
a field's `g7` outline `dark` is 2.8:1 in the dark ramp where `ink` is 3.5:1. One
case is left short deliberately — a chip that is both selected and focused
starts from a `g6` outline, which `ink` clears in light (3.6:1) but not in dark
(2.7:1), so half its perimeter carries the change rather than all of it. The
selection fill states it a second way, and the alternative is a 3px stroke on a
44px row.

Contrast is bounded *above* as well: `ink` on `paper` is 14.2:1 light and 10.6:1
dark, not the 21:1 that `g0` on `g12` would give. WCAG 2.x has only a floor
because it treats contrast as monotonically good; APCA and the WCAG 3 draft do
not. Past roughly this point more contrast stops buying legibility and starts
costing comfort — halation at the extremes is worst for astigmatic readers, and
worse light-on-dark than dark-on-light.

That asymmetry is the whole reason for two ramps. Light-on-dark stems read
heavier (irradiation), so dark should be *gentler* than light at equal authored
intent — and a mirror cannot do that, because it moves every ratio together. The
dark ramp eases the body-text pair by a quarter while holding the secondary-text
and boundary ratios within a percent of their light values, and keeps enough
elevation spacing that a raised surface still reads as raised.

The dark page is true black, which is a choice rather than a leftover. The ramp
is solved as ratios *against the page*, so the page byte sets the whole ramp's
altitude and the easing holds either way — pinning it at `0x00` is paid for at
the text end, where `ink` comes down from `0xC6` to `0xB8` to keep the same
10.6:1. Pure black costs nothing on a raster display and switches OLED pixels
off outright, which is most of nokre's mobile surface. What matters for
halation is the luminance step at the glyph edge, and that is set by the *text*
byte, not the page — which is why `ink` is nowhere near `0xFF`.

`g0` and `g12` survive as the two steps the design system itself never draws.
They are reachable only through a light-pinned canvas (`Canvas.light`), for the
two surfaces that want maximum modulation whatever the appearance: the QR tile,
because a scanner wants it and a photo-negative code is a different code, and
the vendor sign-in marks, because Apple's HIG sanctions black / white /
white-outlined and nothing between. `Tree.append` rejects text at that contrast
(`error.ExcessiveTextContrast`), so an app cannot reach it by hand.

Tests in `color.zig` prove all of this; a ramp byte that breaks compliance —
in either direction, in either appearance — fails the build.

### The one colored artwork

One thing on any nokre screen is not gray: the multicolour G on the
Google sign-in button, drawn because Google's branding rules refuse a
gray variant of their trademark. This is an *infrastructure* fact, not
an API one — the four colour values live in the renderer's `google_g`
table, reach pixels through the canvas's single rgb operation
(`drawTextRgb`), and are not reachable from any element: no element
carries a colour, no consumer call accepts one, and the palette an app
authors in remains the thirteen grays above. The colours resolve
through no ramp and follow no appearance — a trademark has no dark
mode. The decision record (this was a refusal for a long time, and the
reversal was the owner's) is in [oauth.md](oauth.md).

Surfaces are `kRGB_888x` — rgb with no alpha channel, because nokre
composites nothing. Every canvas operation except `drawTextRgb` paints
r=g=b, so the frame is grayscale by construction everywhere that one
mark is not. `on_frame` hands shells tightly packed RGBX (4 bytes per
pixel; the padding byte is outside the promise and readers ignore it).
Anti-aliased text and rounded corners produce intermediate bytes;
square-cornered geometry never does.

## Geometry: anti-aliased only at rounded corners

Rects take a corner radius. At radius 0 they are integer-aligned fills with
AA off; square strokes are decomposed into four fills (see `hsk_stroke_rect`
in [shim/nokre_skia.cpp](../../shim/nokre_skia.cpp)) so no stroke ever
straddles a half-pixel. Rounded rects are drawn with grayscale AA — still
deterministic per Skia build, like text. Lines are axis-aligned only —
the shim ignores anything else by design.

## Text: shaped, grayscale AA, no hinting, no subpixel

- Bundled fonts only ([src/assets/fonts](../../src/assets/fonts)):
  twelve faces — mono and prose each in regular, bold, italic,
  and bold-italic, the icon face, the Arabic-script companion
  (Vazirmatn regular and bold; the script has no italic tradition, so
  italic requests resolve to the upright weight), and the brand face
  (five glyphs — Apple's logo and the Google G's four arcs;
  renderer-only, `text.Family.brand`, which no app text can reach).
  Variants are real
  drawn faces from the same upstream builds as the regulars (Skia's
  fake-bold and oblique are never enabled — synthesis is
  rasterizer-dependent); the system font stack is never consulted for
  rendering. Face selection is the shim's face index,
  `family * 4 + variant`, icons at 8, the companion at 9/10, the brand
  face at 11
  ([canvas_skia.zig](../../src/render/skia/canvas_skia.zig) is the
  authority; the shim header's comment stops at the companion). Core
  never requests the companion: any
  Arabic-script codepoint in a run makes the shim substitute it.
- Every text call is shaped by HarfBuzz (pinned in
  `tools/fetch-deps.sh`, compiled into the shim — never into Skia).
  Each call is one direction run; the shim shapes it as a single buffer
  with explicit script and language (HarfBuzz's guesses read the
  process locale, which a deterministic renderer cannot allow) and
  draws resolved glyph IDs at positions accumulated in 26.6 fixed
  point. Advances are integer math from the font's own units, so
  measured widths — and therefore wrap points — are identical on every
  platform, independent of the platform scaler.
- Run order is core's: [bidi.zig](../../src/core/bidi.zig) implements
  UAX #9 in full (validated against the UCD's BidiCharacterTest) and
  the renderer hands the shim visual-order pieces. Direction is derived
  from content — first strong character per hard paragraph — and an RTL
  paragraph right-aligns its lines. Kerning across piece boundaries
  (face changes, digit runs amid RTL) is forfeited exactly as it is
  across span boundaries, which is what keeps every width a sum of
  identically shaped pieces.
- `SkFont` settings are fixed: grayscale anti-aliasing, hinting off,
  subpixel positioning off. Hinting off is what keeps 2× exactly
  proportional to 1×.
- Run widths are ceiled to integers (`hsk_text_width`), so layout never
  underestimates and wrap points are integer-stable.

## The type scale

Fixed, from [src/core/text.zig](../../src/core/text.zig):

| Scale | Size px | Line height px |
| --- | --- | --- |
| `small` | 12 | 16 |
| `body` | 16 | 24 |
| `h4` | 18 | 26 |
| `h3` | 20 | 28 |
| `h2` | 24 | 32 |
| `h1` | 32 | 40 |

Word wrap is greedy at spaces, honors `\n`, never hyphenates; over-long
words overflow their box rather than break (deterministic and obvious).

## Where the guarantee stops, and why there

Text glyph rasterization is determined by the font binary **and the Skia
build**, and each platform links the font backend it has (CoreText on
macOS and iOS, FreeType elsewhere). So the promise above is a
per-platform one: cross-*run* and cross-*machine* identity, not
cross-*platform*. That boundary is chosen, not pending. A tree carries no
visual intent, an edition is entitled to draw it as its device draws
things ([renderer-editions.md](renderer-editions.md)), and a library that
forced one rasterization onto every screen would be overruling the only
party that knows what the screen is — the same argument that lets the DOM
edition wrap text where the reader's settings say and not where a golden
says.

What *is* identical everywhere is everything upstream of the scaler:
shaping, glyph choice, advances, and therefore all layout come from
HarfBuzz's integer math over the bundled binaries. Two platforms
disagree about the ink inside a glyph's box; they do not disagree about
where the box is, what wrapped, or what a screen reader is told.

Goldens follow from that: a golden set belongs to the platform that
generated it. The committed set is macOS-generated, so `-Dgolden` on
Windows or Linux mismatches by design and a shell validates against its
own regenerated set ([../testing.md](../testing.md)).

## Enforcement

Golden tests ([testing.md](../testing.md)) compare full frames byte-for-byte —
no tolerance, no perceptual diff. If a byte changes, a human reviews a
picture.
