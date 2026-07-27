#pragma once
#include <stddef.h>

// memset/memcpy/memmove come from Zig's compiler-rt; only strlen has to
// be written (freestanding.c).
void *memset(void *dst, int value, size_t len);
void *memcpy(void *dst, const void *src, size_t len);
void *memmove(void *dst, const void *src, size_t len);
size_t strlen(const char *s);
char *strchr(const char *s, int c);
