// nokre Skia shim — the complete C surface between nokre and Skia.
// CPU raster only, RGB with no alpha (kRGB_888x), no antialiased
// geometry (crisp 1px lines), grayscale-antialiased text with fixed
// hinting. Every op but hsk_draw_text_rgb paints r=g=b, so the frame
// stays gray by construction except where the renderer's one sanctioned
// color caller — the vendor sign-in mark — drew. Deterministic per font
// binary + Skia build; see docs/internals/pixel-model.md.
//
// Text goes through HarfBuzz (deps/harfbuzz, compiled into this shim,
// never into Skia): every call shapes one direction run into glyphs and
// 26.6 fixed-point positions — integer math, so advances and therefore
// wrap points are identical on every platform even while glyph
// rasterization still differs per scaler (see skia-build.md). Skia only
// ever sees resolved glyph IDs via drawGlyphs.

#include "nokre_skia.h"

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkRRect.h"
#include "include/core/SkShader.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTileMode.h"
#include "include/core/SkTypeface.h"

#include "hb.h"

#if defined(__APPLE__)
#include "include/ports/SkFontMgr_mac_ct.h"
#elif defined(__EMSCRIPTEN__) || defined(_WIN32) || defined(__ANDROID__) || defined(__linux__)
#include "include/ports/SkFontMgr_empty.h"
#endif

#include <cassert>
#include <cstring>
#include <memory>
#include <vector>

namespace {

// Face-index order (see nokre_skia.h; matches canvas_skia.zig).
sk_sp<SkTypeface> g_typefaces[HSK_FACE_COUNT];
// The same binaries as HarfBuzz faces. Immutable after load, so shaping
// from two apps on two threads shares them safely; the cheap mutable
// hb_font is created per call instead.
hb_face_t *g_hb_faces[HSK_FACE_COUNT];

// Rolls a mid-failure hsk_fonts_load back to empty, so a retry starts
// clean instead of leaking the hb faces created so far. Returns 0 for
// the caller's tail position.
int32_t fontsUnload() {
    for (int32_t i = 0; i < HSK_FACE_COUNT; i++) {
        g_typefaces[i] = nullptr;
        if (g_hb_faces[i]) {
            hb_face_destroy(g_hb_faces[i]);
            g_hb_faces[i] = nullptr;
        }
    }
    return 0;
}

sk_sp<SkFontMgr> fontMgr() {
#if defined(__APPLE__)
    static sk_sp<SkFontMgr> mgr = SkFontMgr_New_CoreText(nullptr);
#elif defined(__EMSCRIPTEN__) || defined(_WIN32) || defined(__ANDROID__) || defined(__linux__)
    // FreeType rasterizes the embedded faces from memory alone: Android
    // builds it that way on purpose (skia_enable_fontmgr_custom_empty in
    // tools/build-skia-android.sh, skipping the system fontmgr and its
    // expat dependency); on Windows the prebuilt compiles FreeType in,
    // and using it instead of DirectWrite keeps one text stack per
    // docs/internals/skia-build.md; desktop Linux (Wayland shell) takes
    // the same FreeType path. One text stack across the three, and
    // pixels that match each other and not the CoreText platforms —
    // chosen, not pending (docs/internals/pixel-model.md). RefEmpty()
    // below cannot make a typeface from the embedded font bytes, so it
    // must never be Linux.
    static sk_sp<SkFontMgr> mgr = SkFontMgr_New_Custom_Empty();
#else
    static sk_sp<SkFontMgr> mgr = SkFontMgr::RefEmpty();
#endif
    return mgr;
}

// A face index is an enum ordinal from canvas_skia.zig, so anything
// outside [0, HSK_FACE_COUNT) is a caller bug — including a negative,
// whose C `%` stays negative and would index out of bounds. Clamp to
// face 0 rather than UB: a wrong-but-real face is legible, a stray read
// is not.
int32_t clampFace(int32_t face) {
    return (face >= 0 && face < HSK_FACE_COUNT) ? face : 0;
}

SkFont makeFont(int32_t face, int32_t size_px) {
    SkFont font(g_typefaces[clampFace(face)], (SkScalar)size_px);
    font.setEdging(SkFont::Edging::kAntiAlias); // grayscale AA, never subpixel
    font.setHinting(SkFontHinting::kNone);      // metrics identical at all scales
    font.setSubpixel(false);
    return font;
}

SkPaint grayPaint(uint8_t gray) {
    SkPaint paint;
    paint.setAntiAlias(false); // geometry snaps to the integer pixel grid
    paint.setColor(SkColorSetARGB(0xFF, gray, gray, gray));
    return paint;
}

bool isArabicScript(uint32_t cp) {
    // Mirrors core/bidi.zig isArabicScript — the blocks the companion
    // face is responsible for.
    return (cp >= 0x0600 && cp <= 0x06FF) || (cp >= 0x0750 && cp <= 0x077F) ||
           (cp >= 0x0870 && cp <= 0x08FF) || (cp >= 0xFB50 && cp <= 0xFDFF) ||
           (cp >= 0xFE70 && cp <= 0xFEFF);
}

// Arabic-script digits: the Arabic-Indic set, its two separators, and
// the extended (Persian/Urdu) set. Mirrors the AN and EN rows of
// core/bidi_tables.zig for these blocks, and the distinction is the
// whole of this file's bug history here — they need the companion face
// like every other codepoint in the block, and they are *not* strong
// RTL. A number runs left to right inside a right-to-left line; that is
// the bidi algorithm's answer for AN and EN alike, and shaping a digit
// run right-to-left prints it backwards.
bool isArabicDigit(uint32_t cp) {
    return (cp >= 0x0660 && cp <= 0x0669) || (cp >= 0x066B && cp <= 0x066C) ||
           (cp >= 0x06F0 && cp <= 0x06F9);
}

// One scan, two answers: which face this run needs, and which direction
// it shapes in. They are different questions about the same bytes and
// were one question until a Persian balance rendered as its own
// reverse.
void scanArabic(const uint8_t *utf8, size_t len, bool *any_script, bool *any_letter) {
    // Decode only far enough to classify; malformed sequences can't
    // produce an Arabic lead byte pattern and just advance one byte.
    size_t i = 0;
    while (i < len) {
        uint8_t b = utf8[i];
        uint32_t cp = 0;
        size_t n = 1;
        if (b < 0x80) {
            cp = b;
        } else if ((b & 0xE0) == 0xC0 && i + 1 < len) {
            cp = ((b & 0x1F) << 6) | (utf8[i + 1] & 0x3F);
            n = 2;
        } else if ((b & 0xF0) == 0xE0 && i + 2 < len) {
            cp = ((b & 0x0F) << 12) | ((utf8[i + 1] & 0x3F) << 6) | (utf8[i + 2] & 0x3F);
            n = 3;
        } else if ((b & 0xF8) == 0xF0 && i + 3 < len) {
            cp = ((b & 0x07) << 18) | ((utf8[i + 1] & 0x3F) << 12) |
                 ((utf8[i + 2] & 0x3F) << 6) | (utf8[i + 3] & 0x3F);
            n = 4;
        }
        if (isArabicScript(cp)) {
            *any_script = true;
            if (!isArabicDigit(cp)) {
                *any_letter = true;
                return;
            }
        }
        i += n;
    }
}

// Any Arabic-script codepoint selects the companion face (regular or
// bold — the script has no italic tradition, so italics resolve to their
// upright weight). Direction is the *other* question: a run shapes
// right-to-left only if something in it is strongly right-to-left, which
// a digit is not. core/bidi.zig guarantees a call never mixes
// directions, so one answer per run is enough — but the answer has to be
// about direction and not about which face the bytes happen to want.
int32_t resolveFace(int32_t face, const uint8_t *utf8, size_t len, bool *rtl) {
    face = clampFace(face);
    bool any_script = false;
    bool any_letter = false;
    scanArabic(utf8, len, &any_script, &any_letter);
    *rtl = any_letter;
    if (any_script) {
        const bool bold = face < HSK_FACE_ICONS && (face % 4 == 1 || face % 4 == 3);
        return bold ? HSK_FACE_ARABIC_BOLD : HSK_FACE_ARABIC;
    }
    return face;
}

// Shapes one run at 26.6 fixed point. Script and language are always set
// explicitly: hb's guess consults the process locale, which would make
// shaping environment-dependent. Every non-Arabic run is tagged
// Latin/"en" wholesale — an assumption, stated rather than asserted,
// because the thing it rests on (that the embedded faces carry no
// script- or `locl`-sensitive substitutions outside Arabic) lives in
// the font tables, and probing GSUB per call is not a cheap assert.
// Embedding a face where those tags change shaping — CJK `locl`
// variants, Turkish dotted-i casing, an Indic script — would invalidate
// it and require real script itemization here.
hb_buffer_t *shapeRun(int32_t face, int32_t size_px, const uint8_t *utf8, size_t len,
                      bool rtl) {
    hb_font_t *font = hb_font_create(g_hb_faces[face]);
    hb_font_set_scale(font, size_px * 64, size_px * 64);
    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, (const char *)utf8, (int)len, 0, (int)len);
    hb_buffer_set_direction(buf, rtl ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
    hb_buffer_set_script(buf, rtl ? HB_SCRIPT_ARABIC : HB_SCRIPT_LATIN);
    hb_buffer_set_language(buf, hb_language_from_string(rtl ? "fa" : "en", -1));
    hb_shape(font, buf, nullptr, 0);
    hb_font_destroy(font);
    return buf;
}

} // namespace

struct hsk_surface {
    sk_sp<SkSurface> surface;
    int32_t logical_w;
    int32_t logical_h;
    int32_t scale;
    int32_t clip_depth;
    std::unique_ptr<uint8_t[]> readback; // RGBX snapshot for hsk_surface_pixels
};

extern "C" {

int32_t hsk_fonts_load(const uint8_t *const *faces, const size_t *lens, int32_t count) {
    if (count != HSK_FACE_COUNT) return 0;
    // Loaded at most once per process: the faces are immutable after
    // load and shared by every surface and shaping call, so a second
    // load must not swap them mid-use — and overwriting g_hb_faces
    // without destroying the old ones would leak them. A repeat call is
    // simply the already-loaded answer.
    static bool loaded = false;
    if (loaded) return 1;
    sk_sp<SkFontMgr> mgr = fontMgr();
    for (int32_t i = 0; i < HSK_FACE_COUNT; i++) {
        g_typefaces[i] = mgr->makeFromData(SkData::MakeWithCopy(faces[i], lens[i]));
        if (!g_typefaces[i]) return fontsUnload();
        // Same bytes for HarfBuzz, so shaped glyph IDs and Skia's
        // rasterization can never disagree about the font.
        hb_blob_t *blob = hb_blob_create_or_fail((const char *)faces[i], (unsigned)lens[i],
                                                 HB_MEMORY_MODE_DUPLICATE, nullptr, nullptr);
        if (!blob) return fontsUnload();
        g_hb_faces[i] = hb_face_create(blob, 0);
        hb_blob_destroy(blob);
        if (g_hb_faces[i] == hb_face_get_empty()) {
            g_hb_faces[i] = nullptr;
            return fontsUnload();
        }
        hb_face_make_immutable(g_hb_faces[i]);
    }
    loaded = true;
    return 1;
}

int32_t hsk_text_width(int32_t face, int32_t size_px, const uint8_t *utf8, size_t len) {
    if (len == 0) return 0;
    bool rtl = false;
    const int32_t resolved = resolveFace(face, utf8, len, &rtl);
    hb_buffer_t *buf = shapeRun(resolved, size_px, utf8, len, rtl);
    unsigned n = 0;
    const hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, &n);
    int64_t total = 0; // 26.6
    for (unsigned i = 0; i < n; i++) total += pos[i].x_advance;
    hb_buffer_destroy(buf);
    // Ceil to integer px so layout never underestimates.
    return (int32_t)((total + 63) >> 6);
}

hsk_surface *hsk_surface_create(int32_t w, int32_t h, int32_t scale) {
    if (w <= 0 || h <= 0 || scale < 1) return nullptr;
    // kRGB_888x, not kRGBA/kBGRA: rgb is unlocked for the shim, alpha is
    // not — nokre composites nothing, and an alpha channel would be a
    // blending vocabulary waiting to be used. The x byte is padding.
    SkImageInfo info = SkImageInfo::Make(w * scale, h * scale, kRGB_888x_SkColorType,
                                         kOpaque_SkAlphaType);
    sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
    if (!surface) return nullptr;

    auto *s = new hsk_surface();
    s->surface = surface;
    s->logical_w = w;
    s->logical_h = h;
    s->scale = scale;
    s->clip_depth = 0;
    // All draw calls are in logical px; the integer scale is a transform.
    surface->getCanvas()->scale((SkScalar)scale, (SkScalar)scale);
    return s;
}

void hsk_surface_destroy(hsk_surface *s) {
    delete s;
}

const uint8_t *hsk_surface_pixels(hsk_surface *s) {
    const int32_t pw = s->logical_w * s->scale;
    const int32_t ph = s->logical_h * s->scale;
    if (!s->readback) {
        s->readback.reset(new uint8_t[(size_t)pw * (size_t)ph * 4]);
    }
    SkImageInfo info = SkImageInfo::Make(pw, ph, kRGB_888x_SkColorType, kOpaque_SkAlphaType);
    s->surface->readPixels(info, s->readback.get(), (size_t)pw * 4, 0, 0);
    return s->readback.get();
}

void hsk_clear(hsk_surface *s, uint8_t gray) {
    s->surface->getCanvas()->clear(SkColorSetARGB(0xFF, gray, gray, gray));
}

void hsk_fill_rect(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h,
                   int32_t radius, uint8_t gray) {
    SkPaint paint = grayPaint(gray);
    SkCanvas *c = s->surface->getCanvas();
    if (radius <= 0) {
        c->drawIRect(SkIRect::MakeXYWH(x, y, w, h), paint);
        return;
    }
    paint.setAntiAlias(true); // corners only round acceptably with AA
    SkRRect rr = SkRRect::MakeRectXY(SkRect::MakeXYWH(x, y, w, h),
                                     (SkScalar)radius, (SkScalar)radius);
    c->drawRRect(rr, paint);
}

void hsk_stroke_rect(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h,
                     int32_t radius, int32_t thickness, uint8_t gray) {
    SkPaint paint = grayPaint(gray);
    SkCanvas *c = s->surface->getCanvas();
    if (radius <= 0) {
        // Four fills instead of a stroked path: stroke centering would land on
        // half-pixels and break determinism.
        c->drawIRect(SkIRect::MakeXYWH(x, y, w, thickness), paint);
        c->drawIRect(SkIRect::MakeXYWH(x, y + h - thickness, w, thickness), paint);
        c->drawIRect(SkIRect::MakeXYWH(x, y + thickness, thickness, h - 2 * thickness), paint);
        c->drawIRect(SkIRect::MakeXYWH(x + w - thickness, y + thickness, thickness, h - 2 * thickness), paint);
        return;
    }
    paint.setAntiAlias(true);
    paint.setStyle(SkPaint::kStroke_Style);
    paint.setStrokeWidth((SkScalar)thickness);
    const SkScalar half = thickness * 0.5f;
    SkScalar r = (SkScalar)radius - half;
    if (r < 0) r = 0;
    SkRRect rr = SkRRect::MakeRectXY(
        SkRect::MakeXYWH(x + half, y + half, w - thickness, h - thickness), r, r);
    c->drawRRect(rr, paint);
}

void hsk_line(hsk_surface *s, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
              int32_t thickness, uint8_t gray) {
    // nokre draws only axis-aligned lines; a diagonal here is a bug in
    // the core, not a request to fall back. Loud in debug so the bug is
    // found; in release the refusal stays a silent no-op — a missing
    // rule beats a crashed app.
    assert(x0 == x1 || y0 == y1);
    SkPaint paint = grayPaint(gray);
    SkCanvas *c = s->surface->getCanvas();
    if (y0 == y1) {
        c->drawIRect(SkIRect::MakeXYWH(x0 < x1 ? x0 : x1, y0, x0 < x1 ? x1 - x0 : x0 - x1, thickness), paint);
    } else if (x0 == x1) {
        c->drawIRect(SkIRect::MakeXYWH(x0, y0 < y1 ? y0 : y1, thickness, y0 < y1 ? y1 - y0 : y0 - y1), paint);
    }
}

// Shared by the gray and rgb text entry points: shaping, positioning
// and rasterization are identical — the two may only ever differ in
// paint color, or the mark's arcs would not land on the gray text grid.
static void drawTextColor(hsk_surface *s, int32_t face, int32_t size_px, int32_t x,
                          int32_t baseline, const uint8_t *utf8, size_t len, SkColor color) {
    if (len == 0) return;
    bool rtl = false;
    const int32_t resolved = resolveFace(face, utf8, len, &rtl);
    hb_buffer_t *buf = shapeRun(resolved, size_px, utf8, len, rtl);
    unsigned n = 0;
    const hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buf, &n);
    const hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, &n);

    std::vector<SkGlyphID> ids(n);
    std::vector<SkPoint> points(n);
    int64_t pen = (int64_t)x << 6; // 26.6; integer accumulation, then an
                                   // exact /64 into float per glyph
    for (unsigned i = 0; i < n; i++) {
        ids[i] = (SkGlyphID)info[i].codepoint; // glyph ID after shaping
        points[i] = SkPoint::Make((SkScalar)(pen + pos[i].x_offset) / 64.0f,
                                  (SkScalar)baseline - (SkScalar)pos[i].y_offset / 64.0f);
        pen += pos[i].x_advance;
    }
    hb_buffer_destroy(buf);

    SkFont font = makeFont(resolved, size_px);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor(color);
    s->surface->getCanvas()->drawGlyphs((int)n, ids.data(), points.data(),
                                        SkPoint::Make(0, 0), font, paint);
}

void hsk_draw_text(hsk_surface *s, int32_t face, int32_t size_px, int32_t x,
                   int32_t baseline, const uint8_t *utf8, size_t len, uint8_t gray) {
    drawTextColor(s, face, size_px, x, baseline, utf8, len, SkColorSetARGB(0xFF, gray, gray, gray));
}

void hsk_draw_text_rgb(hsk_surface *s, int32_t face, int32_t size_px, int32_t x,
                       int32_t baseline, const uint8_t *utf8, size_t len,
                       uint8_t r, uint8_t g, uint8_t b) {
    drawTextColor(s, face, size_px, x, baseline, utf8, len, SkColorSetARGB(0xFF, r, g, b));
}

void hsk_clip_push(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h) {
    SkCanvas *c = s->surface->getCanvas();
    c->save();
    c->clipIRect(SkIRect::MakeXYWH(x, y, w, h));
    s->clip_depth += 1;
}

void hsk_clip_pop(hsk_surface *s) {
    if (s->clip_depth > 0) {
        s->surface->getCanvas()->restore();
        s->clip_depth -= 1;
    }
}

void hsk_dither(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h,
                uint8_t gray) {
    // A repeating 2x2 bitmap sampled nearest: deterministic, no blending
    // math on the covered pixels, the others untouched.
    SkBitmap tile;
    tile.allocN32Pixels(2, 2);
    const SkColor c = SkColorSetARGB(0xFF, gray, gray, gray);
    *tile.getAddr32(0, 0) = SkPreMultiplyColor(c);
    *tile.getAddr32(1, 1) = SkPreMultiplyColor(c);
    *tile.getAddr32(1, 0) = SK_ColorTRANSPARENT;
    *tile.getAddr32(0, 1) = SK_ColorTRANSPARENT;
    tile.setImmutable();

    SkPaint paint;
    paint.setAntiAlias(false);
    paint.setShader(tile.makeShader(SkTileMode::kRepeat, SkTileMode::kRepeat,
                                    SkSamplingOptions(SkFilterMode::kNearest)));
    s->surface->getCanvas()->drawIRect(SkIRect::MakeXYWH(x, y, w, h), paint);
}

} // extern "C"
