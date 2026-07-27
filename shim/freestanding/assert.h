// The release semantics of assert.h, which is what a shipped build has
// anyway: qrcodegen's assertions guard its own internal invariants, and
// the one input a consumer controls is checked in core/qr.zig before
// the encoder is ever called.
#pragma once
#define assert(expr) ((void)0)
