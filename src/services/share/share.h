// C contract between the share native legs and Zig. One verb, outbound,
// fire-and-forget: put the OS share sheet on screen with `text` on it,
// and report nothing back — the sheet belongs to the user, and which
// destination they pick, or whether they dismiss it, is deliberately
// unobservable (docs/services.md).
//
// Policy stays in Zig, as everywhere else: the empty-text and size caps
// have already run when a call lands here, and `available` has already
// answered true — a shell that exports this hook shows what it is
// handed, verbatim. The hook rides the shell files the way clipboard's
// does — nothing links — but it answers to this header, not shell.h
// (deep_link's rule). The Wayland shell exports nothing: the Linux
// desktop has no share sheet, and the service says so at runtime
// instead of inventing one out of a file manager and hope.
#ifndef NOKRE_SVC_SHARE_H
#define NOKRE_SVC_SHARE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// `text` is UTF-8, not NUL-terminated (len is the length), borrowed for
// the call — a leg whose sheet reads it later (the WinRT data-requested
// callback) copies it first. Main thread only, like all input
// callbacks — it is called from activation. Anchoring is the shell's:
// the service API carries no geometry, so a leg that needs a rect (the
// iPad popover, NSSharingServicePicker) centers on the app's one view.
// A show that fails — no sheet host on a bare Windows session — fails
// silently: fire-and-forget has no error lane, open_url's line.
void nokre_share_show(const char *text, size_t len);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_SHARE_H
