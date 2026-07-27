#!/usr/bin/env bash
# Fetches nokre's native dependencies into deps/:
#   deps/skia — prebuilt Skia static library + headers.
#   deps/accesskit — prebuilt AccessKit C bindings (accessibility).
#   deps/harfbuzz — HarfBuzz source (shaping); compiled into the shim
#     by build.zig, never into Skia, so the pinned Skia builds stay
#     untouched.
#
# Skia bootstrap source: aseprite/skia prebuilts (m124). These are
# per-platform builds (CoreText on macOS), which is fine for development
# but not yet cross-platform pixel-identical for text — see
# docs/internals/skia-build.md for the plan to publish nokre's own
# FreeType-everywhere builds.
set -euo pipefail

# SKIA_TAG and the per-platform SKIA_SHA256_* pins live in versions.sh,
# shared with the build-skia-*.sh source builds so all Skia consumers
# move in lockstep.
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
ACCESSKIT_VERSION="0.22.3"
ACCESSKIT_SHA256="b652e380fb78efe6721ad892f15b2224f38f661c3fb20436ef4c5b3ce0fe8177"
# Shaping is version-sensitive: glyph choices and advances feed the
# pixel model, so the release is pinned and hash-checked like the rest.
HARFBUZZ_VERSION="10.1.0"
HARFBUZZ_SHA256="6ce3520f2d089a33cef0fc48321334b8e0b72141f6a763719aaaecd2779ecb82"
DEPS_DIR="$(cd "$(dirname "$0")/.." && pwd)/deps"

# On Windows (Git Bash / MSYS) the prebuilts are MSVC-ABI: Skia ships as
# split COFF archives and AccessKit's static lib comes from the msvc
# directory — matching build.zig, which targets x86_64-windows-msvc for
# -Dskia builds.
HOST_WINDOWS=0
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) SKIA_ZIP="Skia-macOS-Release-arm64.zip"; SKIA_SHA256="${SKIA_SHA256_MACOS_ARM64}"; SKIA_LIB_DIR="out/Release-arm64"; AK_LIB_DIR="macos/arm64" ;;
  Darwin-x86_64) SKIA_ZIP="Skia-macOS-Release-x64.zip"; SKIA_SHA256="${SKIA_SHA256_MACOS_X64}"; SKIA_LIB_DIR="out/Release-x64"; AK_LIB_DIR="macos/x86_64" ;;
  Linux-x86_64) SKIA_ZIP="Skia-Linux-Release-x64.zip"; SKIA_SHA256="${SKIA_SHA256_LINUX_X64}"; SKIA_LIB_DIR="out/Release-x64"; AK_LIB_DIR="linux/x86_64" ;;
  MINGW64_NT*-x86_64|MSYS_NT*-x86_64|CYGWIN_NT*-x86_64)
    SKIA_ZIP="Skia-Windows-Release-x64.zip"; SKIA_SHA256="${SKIA_SHA256_WINDOWS_X64}"; SKIA_LIB_DIR="out/Release-x64"; AK_LIB_DIR="windows/x86_64/msvc"; HOST_WINDOWS=1 ;;
  *) echo "unsupported host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

SKIA_URL="https://github.com/aseprite/skia/releases/download/${SKIA_TAG}/${SKIA_ZIP}"
ACCESSKIT_URL="https://github.com/AccessKit/accesskit-c/releases/download/${ACCESSKIT_VERSION}/accesskit-c-${ACCESSKIT_VERSION}.zip"

mkdir -p "${DEPS_DIR}"

if [ -f "${DEPS_DIR}/skia/lib/libskia.a" ] || [ -f "${DEPS_DIR}/skia/lib/skia.lib" ]; then
  echo "deps/skia already present — delete deps/skia to re-fetch"
else
  echo "fetching ${SKIA_URL}"
  TMP_ZIP="${DEPS_DIR}/skia.zip"
  curl -fL --retry 3 -o "${TMP_ZIP}" "${SKIA_URL}"
  echo "${SKIA_SHA256}  ${TMP_ZIP}" | shasum -a 256 -c -

  rm -rf "${DEPS_DIR}/skia.extract" "${DEPS_DIR}/skia"
  mkdir -p "${DEPS_DIR}/skia.extract"
  unzip -q "${TMP_ZIP}" -d "${DEPS_DIR}/skia.extract"
  rm "${TMP_ZIP}"

  # Normalize layout: deps/skia/{include,modules,src,lib/…}
  mkdir -p "${DEPS_DIR}/skia/lib"
  mv "${DEPS_DIR}/skia.extract/include" "${DEPS_DIR}/skia/include"
  [ -d "${DEPS_DIR}/skia.extract/modules" ] && mv "${DEPS_DIR}/skia.extract/modules" "${DEPS_DIR}/skia/modules"
  [ -d "${DEPS_DIR}/skia.extract/src" ] && mv "${DEPS_DIR}/skia.extract/src" "${DEPS_DIR}/skia/src"
  if [ "${HOST_WINDOWS}" = "1" ]; then
    mv "${DEPS_DIR}/skia.extract/${SKIA_LIB_DIR}/"*.lib "${DEPS_DIR}/skia/lib/"
  else
    mv "${DEPS_DIR}/skia.extract/${SKIA_LIB_DIR}/libskia.a" "${DEPS_DIR}/skia/lib/libskia.a"
  fi
  rm -rf "${DEPS_DIR}/skia.extract"

  echo "deps/skia ready"
fi

if [ -f "${DEPS_DIR}/accesskit/lib/libaccesskit.a" ] || [ -f "${DEPS_DIR}/accesskit/lib/accesskit.lib" ]; then
  echo "deps/accesskit already present — delete deps/accesskit to re-fetch"
else
  echo "fetching ${ACCESSKIT_URL}"
  TMP_ZIP="${DEPS_DIR}/accesskit.zip"
  curl -fL --retry 3 -o "${TMP_ZIP}" "${ACCESSKIT_URL}"
  echo "${ACCESSKIT_SHA256}  ${TMP_ZIP}" | shasum -a 256 -c -

  rm -rf "${DEPS_DIR}/accesskit.extract" "${DEPS_DIR}/accesskit"
  mkdir -p "${DEPS_DIR}/accesskit.extract"
  unzip -q "${TMP_ZIP}" -d "${DEPS_DIR}/accesskit.extract"
  rm "${TMP_ZIP}"

  # Normalize layout: deps/accesskit/{include/accesskit.h,lib/…}
  AK_SRC="${DEPS_DIR}/accesskit.extract/accesskit-c-${ACCESSKIT_VERSION}"
  mkdir -p "${DEPS_DIR}/accesskit/lib"
  mv "${AK_SRC}/include" "${DEPS_DIR}/accesskit/include"
  if [ "${HOST_WINDOWS}" = "1" ]; then
    mv "${AK_SRC}/lib/${AK_LIB_DIR}/static/accesskit.lib" "${DEPS_DIR}/accesskit/lib/accesskit.lib"
  else
    mv "${AK_SRC}/lib/${AK_LIB_DIR}/static/libaccesskit.a" "${DEPS_DIR}/accesskit/lib/libaccesskit.a"
  fi
  rm -rf "${DEPS_DIR}/accesskit.extract"

  echo "deps/accesskit ready"
fi

HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"

if [ -f "${DEPS_DIR}/harfbuzz/src/harfbuzz.cc" ]; then
  echo "deps/harfbuzz already present — delete deps/harfbuzz to re-fetch"
else
  echo "fetching ${HARFBUZZ_URL}"
  TMP_TAR="${DEPS_DIR}/harfbuzz.tar.xz"
  curl -fL --retry 3 -o "${TMP_TAR}" "${HARFBUZZ_URL}"
  echo "${HARFBUZZ_SHA256}  ${TMP_TAR}" | shasum -a 256 -c -

  rm -rf "${DEPS_DIR}/harfbuzz.extract" "${DEPS_DIR}/harfbuzz"
  mkdir -p "${DEPS_DIR}/harfbuzz.extract"
  tar xf "${TMP_TAR}" -C "${DEPS_DIR}/harfbuzz.extract"
  rm "${TMP_TAR}"

  # Normalize layout: deps/harfbuzz/{src/…, COPYING}. Only src/ is kept —
  # the amalgamated src/harfbuzz.cc is the entire build.
  mkdir -p "${DEPS_DIR}/harfbuzz"
  mv "${DEPS_DIR}/harfbuzz.extract/harfbuzz-${HARFBUZZ_VERSION}/src" "${DEPS_DIR}/harfbuzz/src"
  mv "${DEPS_DIR}/harfbuzz.extract/harfbuzz-${HARFBUZZ_VERSION}/COPYING" "${DEPS_DIR}/harfbuzz/COPYING"
  rm -rf "${DEPS_DIR}/harfbuzz.extract"

  echo "deps/harfbuzz ready"
fi
