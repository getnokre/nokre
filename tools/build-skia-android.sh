#!/usr/bin/env bash
# Builds Skia for Android into deps/skia-android/arm64-v8a/libskia.a
# (add x86_64 with `ABIS="arm64-v8a x86_64" tools/build-skia-android.sh`
# for Intel-host emulators; Apple Silicon emulators run arm64 images).
#
# Same pinned source tag as every other platform, reusing the
# deps/skia-ios-src checkout (the directory name predates the non-Apple
# builds; the tag itself is platform-neutral). Android takes the wasm
# profile, not the Apple one: there is no CoreText, and the system
# fontmgr would drag in expat and per-device font files — so this is
# another FreeType-from-memory build (SkFontMgr_New_Custom_Empty,
# docs/internals/skia-build.md). Pixels match the web and Windows
# builds, not yet the CoreText platforms.
#
# Requires an NDK (ANDROID_NDK_ROOT, or auto-detected under the SDK's
# ndk/ directory) and python3. A few minutes per ABI on Apple Silicon.
set -euo pipefail

# SKIA_TAG and NDK_API (which must match the example's minSdk) live in
# versions.sh, shared with fetch-deps.sh and build-skia-ios.sh so every
# Skia consumer moves in lockstep.
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
ABIS="${ABIS:-arm64-v8a}"
DEPS_DIR="$(cd "$(dirname "$0")/.." && pwd)/deps"
SRC_DIR="${DEPS_DIR}/skia-ios-src"
OUT_DIR="${DEPS_DIR}/skia-android"

if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
  for sdk in "${ANDROID_HOME:-}" "${HOME}/Library/Android/sdk" "${HOME}/Android/Sdk"; do
    [ -n "${sdk}" ] && [ -d "${sdk}/ndk" ] || continue
    ANDROID_NDK_ROOT="${sdk}/ndk/$(ls "${sdk}/ndk" | sort -V | tail -1)"
    break
  done
fi
if [ -z "${ANDROID_NDK_ROOT:-}" ] || [ ! -d "${ANDROID_NDK_ROOT}" ]; then
  echo "error: no NDK found — set ANDROID_NDK_ROOT" >&2
  exit 1
fi
echo "using NDK ${ANDROID_NDK_ROOT}"

done_all=1
for abi in ${ABIS}; do
  [ -f "${OUT_DIR}/${abi}/libskia.a" ] || done_all=0
done
if [ "${done_all}" = 1 ]; then
  echo "deps/skia-android already present — delete deps/skia-android to rebuild"
  exit 0
fi

if [ ! -d "${SRC_DIR}" ]; then
  echo "cloning skia ${SKIA_TAG}"
  git clone --depth 1 --branch "${SKIA_TAG}" https://github.com/aseprite/skia.git "${SRC_DIR}"
fi

cd "${SRC_DIR}"
python3 bin/fetch-gn
python3 bin/fetch-ninja

# FreeType and its build-graph companions at the revisions Skia's DEPS
# pins for this tag — the same trio the wasm build clones and for the
# same reasons (freetype2 hard-depends on libpng, which needs zlib).
for ext in freetype zlib libpng; do
  EXT_DIR="third_party/externals/${ext}"
  [ -d "${EXT_DIR}" ] && continue
  SPEC=$(python3 - "$ext" <<'EOF'
import re, sys
name = sys.argv[1]
spec = re.search(r'"third_party/externals/%s"\s*:\s*"([^"]+)"' % name,
                 open('DEPS').read()).group(1)
print(spec)
EOF
  )
  git clone "${SPEC%@*}" "${EXT_DIR}"
  git -C "${EXT_DIR}" checkout --quiet "${SPEC##*@}"
done

# CPU raster only — the wasm args with the emscripten bits swapped for
# the NDK toolchain. fontmgr_android must be off explicitly (its
# target_os="android" default is on and would require expat plus
# /system/etc/fonts at runtime); custom_empty on for the embedded faces.
# One divergence from wasm: non-wasm targets get the freetype-android
# config, whose ftoption.h enables PNG color glyphs, so libpng must
# really be in the archive — and official builds default to a *system*
# libpng Android does not have (only wasm defaults it off), hence the
# explicit skia_use_system_libpng=false. Bundled libpng pulls the
# bundled zlib along, exactly the wasm archive's shape.
common_args() {
  local cpu="$1"
  cat <<EOF
is_official_build=true
is_debug=false
werror=false
target_os="android"
target_cpu="${cpu}"
ndk="${ANDROID_NDK_ROOT}"
ndk_api=${NDK_API}
skia_enable_ganesh=false
skia_enable_graphite=false
skia_use_gl=false
skia_use_angle=false
skia_use_vulkan=false
skia_use_expat=false
skia_use_freetype=true
skia_use_system_freetype2=false
skia_use_freetype_woff2=false
skia_use_freetype_zlib=false
skia_use_fontconfig=false
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
skia_use_zlib=true
skia_use_system_zlib=false
skia_use_system_libpng=false
skia_use_xps=false
skia_enable_fontmgr_android=false
skia_enable_fontmgr_custom_directory=false
skia_enable_fontmgr_custom_embedded=false
skia_enable_fontmgr_custom_empty=true
skia_enable_tools=false
EOF
}

for abi in ${ABIS}; do
  case "${abi}" in
    arm64-v8a) cpu=arm64 ;;
    x86_64) cpu=x64 ;;
    *)
      echo "error: unsupported ABI '${abi}' (arm64-v8a or x86_64)" >&2
      exit 1
      ;;
  esac
  ./bin/gn gen "out/android-${abi}" --args="$(common_args "${cpu}")"
  ./third_party/ninja/ninja -C "out/android-${abi}" skia
  mkdir -p "${OUT_DIR}/${abi}"
  cp "out/android-${abi}/libskia.a" "${OUT_DIR}/${abi}/libskia.a"
done

echo "deps/skia-android ready"
