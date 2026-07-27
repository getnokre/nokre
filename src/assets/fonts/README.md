# Bundled fonts

Eleven faces — the complete set nokre can ever render (see
`docs/internals/pixel-model.md`). Variants are real drawn faces from the
same upstream build as their regular, never synthesized:

- `mono*` — JetBrains Mono, internal version 2.305. Byte-identical to
  `fonts/ttf/` in JetBrains/JetBrainsMono@1937130 (regular verified
  byte-equal; variants from the same tree).
- `prose*` — IBM Plex Sans, internal version 3.201. Instanced from the
  Google Fonts variable masters (`google/fonts` `ofl/ibmplexsans`,
  IBMPlexSans[wdth,wght] and IBMPlexSans-Italic[wdth,wght]) at
  wdth=100 with fonttools varLib.instancer, the same pipeline the
  bundled regular came from (metrics verified identical).
- `lucide.ttf` — the Lucide icon font; one face, no variants. Byte-identical
  to `font/lucide.ttf` in lucide-static 1.25.0. `IconName`
  (`src/core/icon_names.zig`) is generated from that same package version
  and its values are this file's codepoints, so the two move together —
  `tools/gen-icon-names.py` refuses to name a glyph the font does not map,
  but nothing catches a font swapped in on its own.
- `arabic*` — Vazirmatn, internal version 33.003
  (rastikerdar/vazirmatn v33.003 `fonts/ttf/`, byte-identical). The
  Arabic-script companion: every family's Arabic runs fall back to it,
  so Persian and Arabic render in one voice regardless of the requested
  family. Regular and bold only — the script has no italic tradition,
  so italic variants resolve to their upright weight rather than
  synthesizing a shear.

Replacing any binary changes glyph rasterization and therefore goldens;
keep versions matched within a family.
