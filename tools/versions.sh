# Pinned dependency and platform-floor constants, stated once.
#
# Sourced (never executed) by tools/fetch-deps.sh, tools/build-skia-ios.sh,
# and tools/build-skia-android.sh, so the prebuilt fetch and both
# source builds cannot drift onto different Skia revisions — rendering
# is version-sensitive (glyph rasterization feeds the pixel model), and
# a tag mismatch between platforms would surface as golden-screenshot
# noise long after the cause.

# The aseprite/skia release tag: names both the prebuilt zips
# fetch-deps.sh downloads and the git branch the build-skia-*.sh
# scripts compile from source. Bumping it means recomputing the
# SKIA_SHA256_* values below against the new release assets.
SKIA_TAG="m124-08a5439a6b"

# SHA256 of each per-platform prebuilt zip at SKIA_TAG, so a tampered
# or truncated download fails loudly before anything links it — the
# same pin-and-verify treatment fetch-deps.sh gives AccessKit and
# HarfBuzz. Recompute with `shasum -a 256 <zip>` on the release assets.
SKIA_SHA256_MACOS_ARM64="22663000967fc2c3f1a78190082228474955de02ffd13a352b39a48b204dac9a"
SKIA_SHA256_MACOS_X64="c11c5fbfa3f8cdefa2255d37cdd1eca823d195ff61929f457a4714f1b6db500a"
SKIA_SHA256_LINUX_X64="a327e89b244f24cecaa34eb37544bae00d447b96c583d26ed29d6a3ad2e8a8b8"
SKIA_SHA256_WINDOWS_X64="5a371a4b2819bb4eb96e36cd75fa623585e1d5477e253a970302b6f2471b6934"

# iOS deployment floor, used for both the device build's
# ios_min_target and the simulator triple in build-skia-ios.sh. Must
# agree with IPHONEOS_DEPLOYMENT_TARGET in
# examples/kitchen_sink/ios/KitchenSink.xcodeproj/project.pbxproj —
# Xcode does not read this file, so a bump here is a by-hand bump
# there too.
IOS_MIN="15.0"

# Android NDK API level for the Skia build. Must agree with minSdk in
# examples/kitchen_sink/android/app/build.gradle — Gradle does not
# read this file, so a bump here is a by-hand bump there too.
# (Choreographer, ANativeWindow, and ALooper are all far older; 26
# keeps one number.)
NDK_API=26
