// C contract between the locale native side and Zig. Inbound like
// deep_link's — the OS calls the app — but with a value the app reads
// synchronously inside `build`, so this hook carries one extra promise
// the deep_link one does not: the FIRST callback happens during the
// install call itself, before it returns. The Zig side owns every
// policy (the cache, the cap, what an unknown locale means); the shell
// holds only the ctx + callback this hands it.
#ifndef NOKRE_SVC_LOCALE_H
#define NOKRE_SVC_LOCALE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The app's per-service state, passed straight back as `ctx`; the shell
// treats it as opaque.
typedef void (*nokre_locale_cb)(void* ctx, const char* tag, size_t len);

// Zig calls this once, from App.init. The shell stores ctx + cb and:
//   - fires cb SYNCHRONOUSLY, before this function returns, with the
//     current device locale. That is the boot read: it must be warm
//     before the app's first `build` runs, and nokre has no ticker to
//     retire a loading frame an async answer would strand;
//   - fires cb again, ON THE MAIN THREAD, on every OS locale change the
//     platform actually reports (macOS and iOS
//     NSCurrentLocaleDidChangeNotification, Android the Activity
//     recreate a language switch causes plus onConfigurationChanged,
//     Windows WM_SETTINGCHANGE "intl"). A platform with no such signal
//     fires once and never again, which is the Wayland shell's case:
//     the tag comes from the environment, and the environment is fixed
//     at exec(). Reporting a tag that never moves is in contract;
//     inventing a poll for it is not.
// `tag` is a BCP 47 language tag in UTF-8, not NUL-terminated (len is
// the length); it is borrowed for the call, so the shell need keep
// nothing after cb returns. A shell that cannot name the current
// locale fires cb once with len 0 — the empty tag is the contract's
// "unknown", and Zig turns it into the app's own template language.
// Never invent "en" natively; that decision is not the shell's.
//
// The web has no C shell: live.js plays this role, seeding the boot tag
// into wasm before boot through nokre_locale_scratch/nokre_locale_seed and
// pushing changes through nokre_locale_receive(tag, len)
// (docs/internals/platform-shells.md).
void nokre_locale_install(void* ctx, nokre_locale_cb cb);

// Forget the stored ctx + cb. Called from App.deinit: the ctx is per-app
// state the app is about to free, so a locale change landing after this
// must find no callback rather than a dangling pointer. A later install
// re-arms the same shell.
void nokre_locale_uninstall(void);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_LOCALE_H
