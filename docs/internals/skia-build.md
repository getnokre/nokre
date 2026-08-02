# Skia: dependency strategy

nokre uses Skia strictly as a CPU rasterizer behind a ~15-function C shim
([shim/nokre_skia.h](../../shim/nokre_skia.h)). No GPU backends, no SkSL,
no PDF, no animation modules — the shim is the entire contract, which is
what makes swapping or shrinking Skia later a contained problem.

## Today: prebuilts

`tools/fetch-deps.sh` downloads a pinned prebuilt
([aseprite/skia](https://github.com/aseprite/skia/releases), tag
`m124-08a5439a6b`) into `deps/skia/` (gitignored):

```
deps/skia/
  include/   modules/   src/      # headers
  lib/libskia.a                   # + bundled freetype, harfbuzz, etc.
```

Link requirements (wired in [build.zig](../../build.zig)): `libskia.a`,
libc++, system `zlib` (the bundled FreeType inflates gzipped tables), and
on macOS the CoreFoundation/CoreGraphics/CoreText/CoreServices frameworks.
The Windows prebuilt differs in shape, not idea: `skia.lib` is the same
everything-bundled archive, MSVC-ABI (so build.zig targets
`x86_64-windows-msvc` and links Visual Studio's static C++ runtime), its
zlib is Chromium-prefixed so FreeType's plain-named gzip references
resolve to a never-runs stub
([shim/nokre_skia_zlib_stub.c](../../shim/nokre_skia_zlib_stub.c)),
and text goes through FreeType with the memory-only font manager
rather than DirectWrite.

The shim compiles with `-std=c++17 -fno-exceptions -fno-rtti` and is the
only C++ in the project.

## iOS: built from source

No prebuilts exist for iOS, so `tools/build-skia-ios.sh` compiles the
same pinned tag from source into
`deps/skia-ios/{iphoneos,iphonesimulator}/libskia.a` — CPU raster only
(no GPU backends, codecs, or shaping modules; none need third-party
checkouts, so the build takes minutes). CoreText still supplies fonts,
matching the macOS prebuilt, and headers keep coming from `deps/skia`.
One consequence of compiling the codecs out: Skia's image-flattening
path still names the PNG encoder.
[shim/nokre_skia_nocodec_stub.cpp](../../shim/nokre_skia_nocodec_stub.cpp)
satisfies it (shared with Android's build);
[shim/nokre_skia_ios_stub.cpp](../../shim/nokre_skia_ios_stub.cpp)
adds the one other symbol Apple's static linker demands. Both are
definitions that must never run; the rationale for each is in the file.

## The web builds no Skia at all

It used to: a from-source wasm build with FreeType and a memory-only
font manager, and a project-local emscripten SDK to link it. All of
that is gone. The web's edition renders the tree as markup and the
browser rasterizes it ([dom-edition.md](dom-edition.md)), so there is
no Skia in that build to configure, pin, or carry — and one fewer
target on the list below.

What the web kept is the part that was never Skia's: layout comes from
core's integer math over HarfBuzz's advances, which is the half of
determinism that travels. What it gave up is the other half, knowingly.

## Android: built from source, FreeType from memory

`tools/build-skia-android.sh` compiles the same minimal profile with the
NDK's toolchain into `deps/skia-android/<abi>/libskia.a` (arm64-v8a by
default; `ABIS="arm64-v8a x86_64"` for Intel-host emulators). Android
*has* a platform fontmgr, but using it would mean expat plus whatever
fonts the device ships — so the build keeps the memory-only manager
(the shim selects it under `__ANDROID__`) and the same three pinned
externals. Two Android-only wrinkles, explained in the script: the
non-wasm FreeType config enables PNG color glyphs, so
`skia_use_system_libpng=false` must fold libpng (and with it the
bundled zlib) into the archive — official builds otherwise assume a
system libpng that Android lacks. The example's CMake
([examples/kitchen_sink/android](../../examples/kitchen_sink/android))
compiles the shim with the same NDK and links everything, reusing the
nocodec stub.

## Which scaler, and why it is not one scaler

These prebuilts use the platform font manager (CoreText on macOS,
FreeType on Linux/Windows). Glyph rasterization therefore matches across
runs and machines *per platform*, and differs across platforms — which is
where the pixel model's guarantee stops on purpose, not a gap it is
waiting to close ([pixel-model.md](pixel-model.md)). Text that looks like
the platform's text is text the platform's users can read; a build that
imposed one rasterizer everywhere would buy an identity nobody asked for
at the cost of the only thing the device knows better.

Text *shaping* is deliberately not Skia's problem: every build above
keeps `skia_use_harfbuzz=false`, `skia_enable_skshaper=false`, and
friends. HarfBuzz is fetched by `fetch-deps.sh` (pinned, hash-checked)
and compiled straight into the shim as one amalgamated translation unit
wherever `nokre_skia.cpp` is compiled — build.zig for desktop and iOS,
the kitchen sink's CMakeLists for the NDK. That keeps the pinned Skia archives untouched, gives shaping
one code path on every platform, and makes glyph choice and advances
(integer 26.6 math) platform-identical while rasterization stays each
scaler's own.

## Next: nokre-owned builds

A packaging errand ([../roadmap.md](../roadmap.md)): the desktop targets
depend on someone else's release cadence for an archive carrying far more
Skia than the shim asks for, while iOS and Android already compile the
minimal profile from source. The plan, in order:

1. Build the same minimal profile for the remaining targets — macOS and
   Windows — stripped to CPU raster, no GPU (`skia_use_gl=false` etc.),
   no image codecs, keeping each target's existing font backend.
2. Publish as GitHub release artifacts; point `fetch-deps.sh` at them.
3. Regenerate the golden set once, on macOS, if the new archive moves a
   byte.

The shim API does not change at any step, and neither does the scaler
question above: this is about what nokre ships, not about making every
platform draw the same picture.
