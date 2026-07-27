// C contract between the deep_link native side and Zig. Inbound, so it
// inverts secure_store's: the OS calls the app, not the app the OS. The
// Zig side owns every policy — the handler, the URL bytes, when to route;
// the shell holds only the ctx + callback this hands it, and the small
// buffer for a launch URL that arrives before install.
#ifndef NOKRE_SVC_DEEP_LINK_H
#define NOKRE_SVC_DEEP_LINK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The app's per-service state, passed straight back as `ctx`; the shell
// treats it as opaque.
typedef void (*nokre_deep_link_cb)(void* ctx, const char* url, size_t len);

// Zig calls this once, on the first setHandler. The shell stores ctx + cb
// and, ON THE MAIN THREAD:
//   - fires cb for the launch URL if the app was opened by a link,
//     buffered until this install so it is never dropped when it lands
//     before boot finishes;
//   - fires cb for every URL delivered while running (iOS
//     scene:openURLContexts / continueUserActivity, Android
//     onNewIntent, macOS application:openURLs).
// `url` is UTF-8, not NUL-terminated (len is the length); it is borrowed
// for the call, so the shell need keep nothing after cb returns. A shell
// with no deep-link source (Linux until it lands) implements this as an
// empty function — the honest posture of the clipboard no-op.
//
// The web has no C shell: live.js plays this role and the Zig side
// exports nokre_deep_link_receive(url, len) for it to call
// (docs/internals/platform-shells.md).
void nokre_deep_link_install(void* ctx, nokre_deep_link_cb cb);

// Forget the stored ctx + cb. Called from App.deinit: the ctx is per-app
// state the app is about to free, so a URL landing after this must be
// buffered for the next install (the pre-install posture), never
// delivered through a dangling pointer.
void nokre_deep_link_uninstall(void);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_DEEP_LINK_H
