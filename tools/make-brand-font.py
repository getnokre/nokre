#!/usr/bin/env python3
"""Build src/assets/fonts/brand.ttf — the vendor sign-in marks.

    python3 tools/make-brand-font.py

Why a font at all: the canvas vocabulary has eight operations and only
one of them renders paths (`drawText`), which is why nokre's icon set is
a font rather than vector art. A brand mark is a path, so it arrives the
same way.

Why its OWN font, and not a glyph added to lucide.ttf: Lucide is
ISC-licensed and the other bundled faces carry their own upstream
licenses. A trademark glyph inside any of them would misrepresent that
license to everyone who redistributes nokre. So the marks live in one
file with one license note (LICENSE-Brand.txt), and the glyph set is
closed — an open brand font is a trademark liability, not a feature.

Deterministic by construction: the outline is inlined below rather than
read from disk, there are no timestamps, and the cubic-to-quadratic
conversion is a pure function of its error bound. Re-running produces a
byte-identical file, so the goldens that embed it stay byte-identical.

The outline is Apple's own artwork, transcribed verbatim from the asset
they publish for this purpose — never redrawn. Apple's guidelines say
explicitly not to recreate the mark, and a redraw is exactly that:

    developer.apple.com/design/human-interface-guidelines/sign-in-with-apple

There is exactly one glyph here and there will not be a second. Google's
four G arcs are the only other mark that was ever considered, and they
are refused for good: drawing them compliantly means colour in the frame,
which is the grayscale guarantee itself (docs/internals/oauth.md).
"""

import os
import sys

try:
    from fontTools.fontBuilder import FontBuilder
    from fontTools.misc.transform import Transform
    from fontTools.pens.boundsPen import BoundsPen
    from fontTools.pens.cu2quPen import Cu2QuPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.svgLib.path import parse_path
except ImportError:
    sys.exit("needs fontTools: python3 -m pip install fonttools")

# ---- the em frame every glyph in this file is drawn in ----------------
# 1000 units per em, baseline at 0. The ascent and descent are the icon
# face's, so the two faces measure alike; where the mark differs is that
# it is drawn to stand on the baseline like a letter, not to centre in
# the em box like an icon (see MARK_HEIGHT).
UPM = 1000
ASCENT, DESCENT = 800, -200

# The mark's drawn height, and where it sits. Both are set so the logo
# behaves like a capital letter in the label rather than like an icon:
# it stands ON the text baseline at the label's cap height, which is how
# it relates to the words in the vendor's own button art. 750/1000 em is
# the prose face's cap height at every size nokre renders, and being a
# whole number of em units keeps it stable under the integer scales the
# pixel model allows.
#
# The renderer draws it at the text baseline for exactly this reason —
# a Lucide icon centres in its em box instead, because an icon is not a
# letter (renderer.zig's button arm).
MARK_HEIGHT = 750
# The round-bottomed overshoot every circular letterform takes, so the
# apple does not read as sitting high beside flat-bottomed capitals.
MARK_OVERSHOOT = 15
SIDE_BEARING = 60

# Flatness of the cubic-to-quadratic conversion, in font units. TrueType
# `glyf` has no cubics, and Apple's artwork is drawn in them. 0.6 units
# is well under a thousandth of the em — far below one device pixel at
# any size nokre renders — and it is a fixed bound, so the conversion is
# reproducible.
CURVE_ERROR = 0.6

# The codepoint the mark answers to. Private Use Area, like Lucide's:
# this is not a character, it is a drawing addressed by name from exactly
# one element. Nothing outside a `provider` button may reach it.
APPLE_CP = 0xE900

# ---- Apple's artwork ------------------------------------------------
# Verbatim from Apple's published SVG, in its own 814 x 1000 frame with
# y growing downward (the flip into font coordinates happens below). Two
# contours: the body, then the leaf. Not modified, not simplified, not
# re-traced — the numbers are Apple's.
APPLE_SRC_WIDTH, APPLE_SRC_HEIGHT = 814, 1000
APPLE_PATH = (
    # body
    "M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2"
    "-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5"
    "c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57-155.5-127C46.7 790.7 0 663 0 541.8"
    "c0-194.4 126.4-297.5 250.8-297.5 66.1 0 121.2 43.4 162.7 43.4 39.5 0 101.1-46 176.3-46"
    "c28.5 0 130.9 2.6 198.3 99.2z"
    # leaf
    "m-234-181.5c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1"
    "-50.6 1.9-110.8 33.7-147.1 75.8-28.5 32.4-55.1 83.6-55.1 135.5 0 7.8 1.3 15.6 1.9 18.1"
    "3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 135.5-71.3z"
)


def draw_apple(pen):
    """Normalise Apple's path into the em frame and draw it into `pen`.

    Two passes. The first measures the artwork's real *ink* bounds with
    the y-flip applied; the second scales that box to MARK_HEIGHT and
    places it. Measuring ink rather than trusting the source frame
    matters — published logo assets carry padding, and a mark sized to
    its canvas instead of its ink comes out visibly small beside the
    label.
    """
    # SVG y grows downward, a font's grows upward. This flip is the
    # whole difference between the mark and the mark upside down, and it
    # has to be part of BOTH passes — measuring with it and drawing
    # without it produces a glyph whose height and baseline are correct
    # and whose orientation is not, which no size check would catch.
    flip = Transform(1, 0, 0, -1, 0, APPLE_SRC_HEIGHT)

    bounds = BoundsPen(None)
    parse_path(APPLE_PATH, TransformPen(bounds, flip))
    x_min, y_min, x_max, y_max = bounds.bounds

    scale = MARK_HEIGHT / (y_max - y_min)
    place = Transform(scale, 0, 0, scale, SIDE_BEARING - x_min * scale, -MARK_OVERSHOOT - y_min * scale)
    # Composed so the flip happens first and the placement second —
    # never hand-multiplied, which is how the flip got lost once.
    parse_path(APPLE_PATH, TransformPen(pen, place.transform(flip)))
    return round((x_max - x_min) * scale) + 2 * SIDE_BEARING


def check(glyph):
    """Assert the things a size measurement cannot see.

    The orientation check is the point: a mark can be exactly cap-height
    and exactly on the baseline while being upside down, so the only
    honest test is one that knows what the drawing *is*. Apple's mark has
    two contours, and the leaf is the smaller one and sits above the
    body — invert the glyph and that stops being true.
    """
    glyph.recalcBounds(None)
    assert glyph.numberOfContours == 2, f"expected body + leaf, got {glyph.numberOfContours}"
    assert glyph.yMin == -MARK_OVERSHOOT, f"ink bottom {glyph.yMin} != {-MARK_OVERSHOOT}"
    assert glyph.yMax - glyph.yMin == MARK_HEIGHT, f"ink height {glyph.yMax - glyph.yMin} != {MARK_HEIGHT}"

    ends = glyph.endPtsOfContours
    spans = [(0, ends[0]), (ends[0] + 1, ends[1])]
    boxes = []
    for lo, hi in spans:
        ys = [glyph.coordinates[i][1] for i in range(lo, hi + 1)]
        boxes.append((len(ys), sum(ys) / len(ys)))
    body, leaf = max(boxes), min(boxes)  # the leaf has fewer points
    assert leaf[1] > body[1], f"leaf sits below the body — the mark is upside down ({leaf[1]:.0f} <= {body[1]:.0f})"


def build(out_path):
    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder([".notdef", "apple"])
    fb.setupCharacterMap({APPLE_CP: "apple"})

    tt_pen = TTGlyphPen(None)
    advance = draw_apple(TransformPen(Cu2QuPen(tt_pen, CURVE_ERROR), (1, 0, 0, 1, 0, 0)))
    # Built exactly once: TTGlyphPen.glyph() *resets* the pen, so asking
    # it twice hands the second caller an empty glyph.
    apple = tt_pen.glyph()

    check(apple)
    fb.setupGlyf({".notdef": TTGlyphPen(None).glyph(), "apple": apple})
    fb.setupHorizontalMetrics({".notdef": (advance, 0), "apple": (advance, SIDE_BEARING)})
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    fb.setupOS2(
        sTypoAscender=ASCENT,
        sTypoDescender=DESCENT,
        sCapHeight=MARK_HEIGHT,
        usWinAscent=ASCENT,
        usWinDescent=-DESCENT,
    )
    # A fixed name table: nothing here may vary run to run, or the
    # embedded bytes change and every golden carrying a mark churns for
    # no visual reason.
    fb.setupNameTable({
        "familyName": "nokre Brand",
        "styleName": "Regular",
        "uniqueFontIdentifier": "nokre Brand 1.000",
        "fullName": "nokre Brand",
        "psName": "nokreBrand-Regular",
        "version": "Version 1.000",
        "copyright": "Contains third-party trademarks; see LICENSE-Brand.txt.",
    })
    fb.setupPost(keepGlyphNames=False)
    # The one source of run-to-run variance fontTools introduces: `head`
    # stamps the build time. Pinned to the 1904 epoch, so the file only
    # ever changes in a commit when the artwork did.
    fb.font["head"].created = 0
    fb.font["head"].modified = 0
    fb.save(out_path)
    print(f"wrote {out_path} ({os.path.getsize(out_path)} bytes, advance {advance})")


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    build(os.path.join(here, "..", "src", "assets", "fonts", "brand.ttf"))
