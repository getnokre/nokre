// Linked only into the iOS build. (The codec-free SkPngEncoder stub the
// iOS link also needs lives in nokre_skia_nocodec_stub.cpp, shared
// with the Android NDK build.)
//
// _dyld_get_image_header_containing_address: referenced by Zig's stack
// -trace symbolization (start code and panic plumbing), but the iOS SDK
// no longer exposes it to the linker. Returning null makes Zig report
// "missing debug info" instead of a symbolized trace — the correct
// degradation for a phone.
extern "C" const void *_dyld_get_image_header_containing_address(const void *) {
    return nullptr;
}
