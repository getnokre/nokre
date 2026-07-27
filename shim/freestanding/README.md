# Freestanding C support

The three headers `deps/qrcodegen/qrcodegen.c` includes that a
`wasm32-freestanding` target has no libc to supply, plus the handful of
functions behind them.

Clang ships `stdbool.h`, `stddef.h`, `stdint.h` and `limits.h` itself,
and Zig's compiler-rt supplies `memset`, `memcpy` and `memmove` — so
what is left is four declarations and three definitions. Everything
here exists to keep nokre's one vendored C file compiling where there
is no C library, which is what the DOM edition's live driver targets
(`docs/internals/dom-edition.md`): no Skia, no emscripten, no libc.

It is not a libc and will not grow into one. A second C dependency that
wanted more than this would be an argument about the dependency, not a
reason to add headers.
