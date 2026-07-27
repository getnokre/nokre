// nokre Skia shim — C API. The complete rendering surface nokre needs
// from Skia: raster surface, rects, axis-aligned lines, text, clip.
// face: family * 4 + variant (variant: 0 regular, 1 bold, 2 italic,
// 3 bold-italic; family: 0 mono, 1 prose), 8 = icons, then the
// Arabic-script companion 9 = arabic, 10 = arabic-bold — must match
// canvas_skia.zig. All coordinates are logical pixels.
//
// Text calls receive one direction run at a time (core/bidi.zig owns
// ordering); the shim shapes each call's bytes as a single HarfBuzz
// buffer. Any Arabic-script codepoint in the buffer selects the
// companion face and right-to-left shaping.
#ifndef NOKRE_SKIA_H
#define NOKRE_SKIA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hsk_surface hsk_surface;

#define HSK_FACE_COUNT 12
// First face past the variant-carrying text families, so an index below
// it is the only kind that can be bold.
#define HSK_FACE_ICONS 8
#define HSK_FACE_ARABIC 9
#define HSK_FACE_ARABIC_BOLD 10
// The vendor sign-in marks (src/assets/fonts/LICENSE-Brand.txt). Last,
// so every index above it is unmoved, and excluded from script fallback
// below: a mark is addressed by codepoint from one element, never
// reached by resolving a run of text.
#define HSK_FACE_BRAND 11

// Loads the font binaries in face-index order; count must be
// HSK_FACE_COUNT. Returns 1 on success. Must be called before any text
// call.
int32_t hsk_fonts_load(const uint8_t *const *faces, const size_t *lens, int32_t count);
// Advance width in logical px, ceiled.
int32_t hsk_text_width(int32_t face, int32_t size_px, const uint8_t *utf8, size_t len);

// CPU raster surface of (w*scale) x (h*scale) gray8 pixels; draw calls
// take logical px and are scaled by the integer factor.
hsk_surface *hsk_surface_create(int32_t w, int32_t h, int32_t scale);
void hsk_surface_destroy(hsk_surface *s);
// Tightly packed gray8 snapshot; valid until the next shim call.
const uint8_t *hsk_surface_pixels(hsk_surface *s);

void hsk_clear(hsk_surface *s, uint8_t gray);
void hsk_fill_rect(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h,
                   int32_t radius, uint8_t gray);
void hsk_stroke_rect(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h,
                     int32_t radius, int32_t thickness, uint8_t gray);
// Axis-aligned only.
void hsk_line(hsk_surface *s, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
              int32_t thickness, uint8_t gray);
void hsk_draw_text(hsk_surface *s, int32_t face, int32_t size_px, int32_t x,
                   int32_t baseline, const uint8_t *utf8, size_t len, uint8_t gray);
void hsk_clip_push(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h);
void hsk_clip_pop(hsk_surface *s);
// 1px (logical) checkerboard of gray over the rect; the other pixels are
// left untouched.
void hsk_dither(hsk_surface *s, int32_t x, int32_t y, int32_t w, int32_t h,
                uint8_t gray);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SKIA_H
