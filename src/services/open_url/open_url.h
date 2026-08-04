// C contract between the open_url native legs and Zig. One verb,
// outbound: hand `url` to the system browser (or the OS's default
// handler for its scheme). After the handoff the page belongs to the
// user, so the only thing left to say is whether the handoff *started*
// — and that one bit is said, because it has exactly one consumer.
//
// Policy stays in Zig, as everywhere else: the scheme allowlist
// (https/http/mailto) has already run when a call lands here, so a
// shell opens what it is handed, verbatim, and never re-judges it.
// The hook rides the shell files the way clipboard's does — every
// shell exports it, nothing links — but it answers to this header,
// not shell.h (deep_link's rule).
//
// This is also oauth's desktop launcher, deliberately. Windows and
// desktop Linux answer RFC 8252 §7.3 with the system browser plus a
// loopback listener, and "open the browser" is this verb — so oauth's
// loopback leg (src/services/oauth/open_url.zig) externs this symbol
// rather than keeping the second ShellExecuteW/xdg-open copy each
// shell.c used to mirror. The coupling crosses the service/shell line
// on purpose and is owner-approved (HANDOFF 2026-08-04): one launcher
// per platform, owned by the shell. Do not "fix" it back into two
// copies.
#ifndef NOKRE_SVC_OPEN_URL_H
#define NOKRE_SVC_OPEN_URL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// `url` is UTF-8, not NUL-terminated (len is the length), borrowed for
// the call. Main thread only, like all input callbacks — it is called
// from activation. Returns 0 when the handoff started, nonzero when it
// certainly did not (no browser on a headless session, a malformed
// URL the OS rejected). "Started" is the honest ceiling: a browser
// that opens and then fails to load is the user's to see, so a shell
// that cannot know more answers 0 once the OS was asked. The open_url
// *service* stays fire-and-forget and ignores the value — its user
// pressed a link and is looking at the screen; oauth's loopback leg is
// the value's one consumer, because a launch that never started means
// a redirect that will never arrive, and a listener thread to unblock.
int nokre_open_url_open(const char *url, size_t len);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_OPEN_URL_H
