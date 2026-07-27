#!/usr/bin/env bash
# Builds Skia for iOS into deps/skia-ios/{iphoneos,iphonesimulator}/libskia.a.
#
# No prebuilts exist for iOS (aseprite publishes macOS/Linux/Windows only),
# so this compiles the same pinned source tag from source — a first step
# toward the nokre-owned builds planned in docs/internals/skia-build.md.
# The build is CPU raster only: no GPU backends, no codecs, no shaping
# modules; CoreText supplies fonts exactly like the macOS prebuilt, so the
# shim's Skia surface is identical. Headers keep coming from deps/skia
# (same tag), fetched by tools/fetch-deps.sh.
#
# Takes a few minutes on Apple Silicon; requires Xcode and python3.
# Apple Silicon only: both slices are arm64, and an Intel Mac's
# simulator is x86_64 — see the check below.
set -euo pipefail

# Fail before minutes of compiling: the simulator slice built here is
# arm64-only, and the iOS Simulator on an Intel Mac runs x86_64, so the
# result could never load there. (Device slices are arm64 regardless of
# host — it is only the simulator half an Intel Mac cannot use.)
if [ "$(uname -m)" = "x86_64" ]; then
  echo "error: this script builds an arm64-only simulator slice; the iOS Simulator on an Intel Mac is x86_64 and cannot load it. Intel Macs are unsupported (device builds are arm64 regardless)." >&2
  exit 1
fi

# SKIA_TAG and the IOS_MIN deployment floor live in versions.sh, shared
# with fetch-deps.sh and build-skia-android.sh so every Skia consumer
# moves in lockstep.
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
SIM_TARGET="arm64-apple-ios${IOS_MIN}-simulator"
DEPS_DIR="$(cd "$(dirname "$0")/.." && pwd)/deps"
# skia-ios-src doubles as the generic Skia source checkout —
# build-skia-android.sh reuses it (the name predates the non-Apple
# builds; the tag itself is platform-neutral).
SRC_DIR="${DEPS_DIR}/skia-ios-src"
OUT_DIR="${DEPS_DIR}/skia-ios"

if [ -f "${OUT_DIR}/iphoneos/libskia.a" ] && [ -f "${OUT_DIR}/iphonesimulator/libskia.a" ]; then
  echo "deps/skia-ios already present — delete deps/skia-ios to rebuild"
  exit 0
fi

if [ ! -d "${SRC_DIR}" ]; then
  echo "cloning skia ${SKIA_TAG}"
  git clone --depth 1 --branch "${SKIA_TAG}" https://github.com/aseprite/skia.git "${SRC_DIR}"
fi

cd "${SRC_DIR}"
python3 bin/fetch-gn
python3 bin/fetch-ninja

# CPU raster only. Everything a nokre build never calls is off; what
# remains needs no third-party checkouts (git-sync-deps not required).
COMMON_ARGS='
is_official_build=true
is_debug=false
target_os="ios"
target_cpu="arm64"
skia_enable_ganesh=false
skia_enable_graphite=false
skia_use_metal=false
skia_use_gl=false
skia_use_angle=false
skia_use_vulkan=false
skia_use_expat=false
skia_use_freetype=false
skia_use_harfbuzz=false
skia_use_icu=false
skia_use_client_icu=false
skia_use_libgrapheme=false
skia_enable_skshaper=false
skia_enable_skparagraph=false
skia_enable_pdf=false
skia_enable_skottie=false
skia_enable_svg=false
skia_use_libjpeg_turbo_decode=false
skia_use_libjpeg_turbo_encode=false
skia_use_libpng_decode=false
skia_use_libpng_encode=false
skia_use_libwebp_decode=false
skia_use_libwebp_encode=false
skia_use_wuffs=false
skia_use_piex=false
skia_use_dng_sdk=false
skia_use_zlib=false
skia_use_xps=false
skia_enable_fontmgr_custom_directory=false
skia_enable_fontmgr_custom_embedded=false
skia_enable_fontmgr_custom_empty=false
skia_enable_tools=false
'

build() {
  local out="$1" extra_args="$2" platform="$3"
  ./bin/gn gen "out/${out}" --args="${COMMON_ARGS} ${extra_args}"
  ./third_party/ninja/ninja -C "out/${out}" skia
  mkdir -p "${OUT_DIR}/${platform}"
  cp "out/${out}/libskia.a" "${OUT_DIR}/${platform}/libskia.a"
}

# Device: -miphoneos-version-min carries the platform. Simulator: that
# flag would stamp the objects as device iOS (m124 sets no -target), so
# the simulator triple goes in via extra_cflags instead.
build ios-arm64 "ios_min_target=\"${IOS_MIN}\"" iphoneos
build iossim-arm64 "ios_use_simulator=true ios_min_target=\"\" extra_cflags=[\"-target\",\"${SIM_TARGET}\"] extra_asmflags=[\"-target\",\"${SIM_TARGET}\"] extra_ldflags=[\"-target\",\"${SIM_TARGET}\"]" iphonesimulator

echo "deps/skia-ios ready"
