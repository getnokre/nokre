#pragma once
#include <stddef.h>

// The integer-absolute pair, and nothing else: no allocator is declared
// here because nothing nokre compiles for this target allocates through
// one — the Zig side owns the heap.
int abs(int v);
long labs(long v);
