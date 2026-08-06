#!/usr/bin/env python3
"""Generates src/core/icon_names.zig from an extracted lucide-static package.

    npm pack lucide-static@<version> && tar xzf lucide-static-*.tgz
    python3 tools/gen-icon-names.py package > src/core/icon_names.zig

The output is checked in; regenerate only on a deliberate Lucide upgrade,
and only together with src/assets/fonts/lucide.ttf from the same package
version — the enum value IS the codepoint, so a font swap without a
regeneration silently renames every icon a consumer placed.

Three upstream files decide the set, and each answers a question the
others cannot:

- `font/codepoints.json` is name -> codepoint, and it is the only file
  that carries codepoints at all. It is NOT the icon set: it holds every
  name Lucide has ever shipped, aliases included, so 2017 names collapse
  onto 1770 codepoints. Generating straight from it (or from lucide.css,
  which is the same data one regex removed) is what produces the
  duplicate-enum-value error, and the tempting fixes — @"kebab-case"
  fields, alias decls pointing at the survivor — encode a name Lucide has
  already retired into a public API that outlives it.

- `tags.json` is keyed by exactly the live icons, one entry per glyph, no
  aliases. So membership there is the canonical-name oracle: of the 237
  codepoints with more than one name, it resolves 236 to a single winner.
  It is also the only thing that distinguishes "the current name" from
  "a name that still works" — the font is silent about it, since an alias
  and its canonical name are one outline reached by one codepoint.

- `../src/assets/fonts/lucide.ttf` decides what is actually renderable.
  Lucide kept the codepoints of the brand marks it removed (github,
  slack, twitter, and 16 more) mapped in codepoints.json with no outline
  behind them, so a name-only pipeline emits fields that draw tofu. This
  script reads the bundled font's cmap and refuses to emit a name whose
  codepoint has no glyph. That nokre has no brand marks here is a
  policy, not an accident (docs/internals/oauth.md): trademark artwork
  lives in brand.ttf under its own license, never in ISC-licensed Lucide.

The three checks are hard errors rather than skips. A silent skip on a
Lucide upgrade would delete a consumer's icon without a compile error at
the call site, which is precisely the failure this enum exists to make
impossible.
"""
import json
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "src", "assets", "fonts", "lucide.ttf")


def font_codepoints(path):
    """The codepoints the bundled font maps, from its (3,1) format 4 cmap.

    Hand-parsed rather than via fontTools: the subset needed is one BMP
    subtable — Lucide's glyphs live in the private use area, so nothing
    here reaches past U+FFFF — and reading it inline keeps this script
    runnable with nothing installed.
    """
    with open(path, "rb") as f:
        data = f.read()
    num_tables = struct.unpack(">H", data[4:6])[0]
    cmap_off = None
    for i in range(num_tables):
        rec = 12 + i * 16
        if data[rec:rec + 4] == b"cmap":
            cmap_off = struct.unpack(">I", data[rec + 8:rec + 12])[0]
    if cmap_off is None:
        sys.exit("no cmap table in %s" % path)

    sub_off = None
    for i in range(struct.unpack(">H", data[cmap_off + 2:cmap_off + 4])[0]):
        rec = cmap_off + 4 + i * 8
        plat, enc, off = struct.unpack(">HHI", data[rec:rec + 8])
        if (plat, enc) == (3, 1):
            sub_off = cmap_off + off
    if sub_off is None:
        sys.exit("no (3,1) cmap subtable in %s" % path)
    if struct.unpack(">H", data[sub_off:sub_off + 2])[0] != 4:
        sys.exit("(3,1) cmap subtable is not format 4")

    seg_x2 = struct.unpack(">H", data[sub_off + 6:sub_off + 8])[0]
    segs = seg_x2 // 2
    ends = struct.unpack(">%dH" % segs, data[sub_off + 14:sub_off + 14 + seg_x2])
    starts_off = sub_off + 16 + seg_x2
    starts = struct.unpack(">%dH" % segs, data[starts_off:starts_off + seg_x2])
    deltas_off = starts_off + seg_x2
    deltas = struct.unpack(">%dh" % segs, data[deltas_off:deltas_off + seg_x2])
    ranges_off = deltas_off + seg_x2
    ranges = struct.unpack(">%dH" % segs, data[ranges_off:ranges_off + seg_x2])

    mapped = set()
    for i in range(segs):
        for cp in range(starts[i], ends[i] + 1):
            if cp == 0xFFFF:
                continue
            if ranges[i] == 0:
                gid = (cp + deltas[i]) & 0xFFFF
            else:
                # The idRangeOffset indirection is relative to its own slot.
                idx = ranges_off + i * 2 + ranges[i] + (cp - starts[i]) * 2
                gid = struct.unpack(">H", data[idx:idx + 2])[0]
                if gid:
                    gid = (gid + deltas[i]) & 0xFFFF
            if gid:
                mapped.add(cp)
    return mapped


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    pkg = sys.argv[1]
    with open(os.path.join(pkg, "font", "codepoints.json")) as f:
        codepoints = json.load(f)
    with open(os.path.join(pkg, "tags.json")) as f:
        canonical = json.load(f)
    with open(os.path.join(pkg, "package.json")) as f:
        version = json.load(f)["version"]
    mapped = font_codepoints(FONT)

    icons = {}
    for name in sorted(canonical):
        if name not in codepoints:
            sys.exit("%s is a live icon with no codepoint" % name)
        cp = codepoints[name]
        if cp not in mapped:
            sys.exit("%s (0x%04x) has no glyph in lucide.ttf — font and "
                     "package version disagree" % (name, cp))
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
            sys.exit("%s does not fit a Zig identifier" % name)
        field = name.replace("-", "_")
        if field in icons:
            sys.exit("%s collides with %s once kebab becomes snake"
                     % (name, icons[field][0]))
        icons[field] = (name, cp)

    out = sys.stdout.write
    out('//! Generated by tools/gen-icon-names.py from lucide-static %s —\n'
        '//! do not edit. Regenerate only alongside\n'
        '//! src/assets/fonts/lucide.ttf from that same version.\n\n'
        % version)
    out('/// Every Lucide glyph consumers can place, named. The enum value IS\n'
        '/// the icon-font codepoint, which is why the set is generated rather\n'
        '/// than curated: a hand-kept subset drifts from the bundled font, and\n'
        '/// a wrong value is a rendered glyph, not a compile error.\n'
        '///\n'
        '/// One name per glyph — Lucide\'s retired aliases (`activity-square`\n'
        '/// for `square-activity`) share a codepoint with their replacement, so\n'
        '/// admitting both would not even compile. The brand marks Lucide\n'
        '/// removed are absent for a second reason as well: nokre keeps\n'
        '/// trademark artwork in brand.ttf, never in Lucide\'s ISC-licensed\n'
        '/// file (docs/internals/oauth.md).\n')
    out("pub const IconName = enum(u21) {\n")
    for field, (_, cp) in icons.items():
        out("    %s = 0x%04x,\n" % (field, cp))
    out("""
    /// The glyph's UTF-8 bytes. Every Lucide codepoint sits in the basic
    /// multilingual plane's private use area, so each encodes to exactly
    /// three bytes; the table is that encoding, laid out dense by
    /// codepoint so the lookup is an index rather than a switch over a
    /// few thousand arms.
    pub fn utf8(self: IconName) []const u8 {
        const i = (@intFromEnum(self) - first) * 3;
        return encoded[i..][0..3];
    }

    const first: u21 = 0x%04x;
    const last: u21 = 0x%04x;

    const encoded = blk: {
        @setEvalBranchQuota((last - first + 1) * 4);
        var bytes: [(last - first + 1) * 3]u8 = undefined;
        for (first..last + 1) |cp| {
            const i = (cp - first) * 3;
            bytes[i] = @intCast(0xe0 | (cp >> 12));
            bytes[i + 1] = @intCast(0x80 | ((cp >> 6) & 0x3f));
            bytes[i + 2] = @intCast(0x80 | (cp & 0x3f));
        }
        const out = bytes;
        break :blk out;
    };
};
""" % (min(cp for _, cp in icons.values()), max(cp for _, cp in icons.values())))


if __name__ == "__main__":
    main()
