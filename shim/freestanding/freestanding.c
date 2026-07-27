// The definitions behind this directory's headers. Four functions,
// each the obvious one — they exist because wasm32-freestanding has no
// libc, not because nokre wants a different implementation.

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

size_t strlen(const char *s) {
	const char *p = s;
	while (*p != '\0') p++;
	return (size_t)(p - s);
}

char *strchr(const char *s, int c) {
	const char needle = (char)c;
	for (;; s++) {
		if (*s == needle) return (char *)s;
		if (*s == '\0') return NULL;
	}
}

int abs(int v) {
	return v < 0 ? -v : v;
}

long labs(long v) {
	return v < 0 ? -v : v;
}
