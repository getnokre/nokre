// C contract between the open_url native legs and Zig. One verb,
// outbound, fire-and-forget: hand `url` to the system browser (or the
// OS's default handler for its scheme) and report nothing back — after
// the handoff the page belongs to the user, so there is nothing honest
// left to say (docs/services.md).
//
// Policy stays in Zig, as everywhere else: the scheme allowlist
// (https/http/mailto) has already run when a call lands here, so a
// shell opens what it is handed, verbatim, and never re-judges it.
// The hook rides the shell files the way clipboard's does — every
// shell exports it, nothing links — but it answers to this header,
// not shell.h (deep_link's rule).
#ifndef NOKRE_SVC_OPEN_URL_H
#define NOKRE_SVC_OPEN_URL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// `url` is UTF-8, not NUL-terminated (len is the length), borrowed for
// the call. Main thread only, like all input callbacks — it is called
// from activation. A launch that fails (no browser on a headless
// session) fails silently: fire-and-forget has no error lane, and the
// user who pressed the link is looking at the screen that did not
// change, which is the same signal a failed xdg-open gives.
void nokre_open_url_open(const char *url, size_t len);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_OPEN_URL_H
