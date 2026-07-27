// Linked wherever Skia is nokre-built with every codec compiled out
// (iOS and wasm today): Skia's image-flattening path still names the
// PNG encoder at link time — and nokre never serializes an SkImage —
// so eager linkers get this definition instead of a codec.
#include "include/core/SkStream.h"
#include "include/encode/SkPngEncoder.h"

bool SkPngEncoder::Encode(SkWStream *, const SkPixmap &, const Options &) {
    return false;
}
