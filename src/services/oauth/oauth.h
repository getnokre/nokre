// C contract between the oauth native side and Zig (docs/services.md;
// design in docs/internals/oauth.md). Outbound-then-inbound, unlike
// deep_link's pure inbound: the app asks for a browser session, and one
// result comes back later, on the main thread.
//
// The native side holds no table. `nokre_oauth_start` returns an opaque
// session pointer that Zig keeps for exactly as long as the flow is
// live; the native side owns the object behind it and releases it
// itself, either as it invokes the callback or inside
// `nokre_oauth_cancel`. Zig therefore never dereferences the pointer and
// never holds it past the callback — the stateless-native charter with
// the one unavoidable handle made explicit rather than hidden in a
// static.
//
// Only ONE session is live per app at a time (the Zig side enforces it,
// error.AuthInFlight): a system browser sheet is modal and a user can
// only be signing in once. That is what lets this contract carry a bare
// pointer instead of a request id.
#ifndef NOKRE_SVC_OAUTH_H
#define NOKRE_SVC_OAUTH_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Callback status codes. Mirrored by `status_*` in oauth.zig.
#define NOKRE_OAUTH_CALLBACK 0  // `text` is the whole callback URL
#define NOKRE_OAUTH_CANCELLED 1 // the user dismissed the sheet; `text` empty
#define NOKRE_OAUTH_FAILURE 2   // `text` is a stable failure name, may be empty

// The app's per-service state, passed straight back as `ctx`; the shell
// treats it as opaque. `text` is UTF-8, not NUL-terminated (len is the
// length), borrowed for the call only — Zig copies before returning.
// ALWAYS called on the main thread, exactly once per session, and never
// after `nokre_oauth_cancel` has been called for that session.
typedef void (*nokre_oauth_cb)(void *ctx, int status, const char *text, size_t len);

// Open `url` in a system browser the user can trust (RFC 8252: the
// system browser or an in-app browser tab, never an embedded web view —
// an embedded view can read the password field, which is the whole
// reason the native-app flow exists), and watch for a redirect to
// `scheme`. Returns an opaque session pointer, or NULL if the platform
// could not start a session at all — Zig turns NULL into the failure
// "SessionUnavailable" without ever calling the callback.
void *nokre_oauth_start(void *ctx, nokre_oauth_cb cb,
                      const char *url, size_t url_len,
                      const char *scheme, size_t scheme_len);

// Dismiss a live session. The callback must NOT fire afterwards — the
// app already knows it cancelled. Releases the session; the pointer is
// dead on return. Never called with NULL, never called twice.
void nokre_oauth_cancel(void *session);

// ---- Apple's native leg (macOS and iOS only) ----
// `oauth.start` with `.provider = .apple` routes here instead of the
// browser, because Apple requires ASAuthorizationController for a
// conforming Sign in with Apple flow on its own platforms. Everywhere
// else Apple is the plain web flow through `nokre_oauth_start` above.
//
// The grant comes back as fields, not a URL: Zig composes the synthetic
// callback URL from them so the app parses one shape on every platform
// (percent-encoding is policy, and policy stays in Zig). `state` is not
// carried back here — Zig already holds the value the app passed and
// echoes it into the synthetic URL itself.
typedef void (*nokre_oauth_apple_cb)(void *ctx, int status,
                                   const char *code, size_t code_len,
                                   const char *id_token, size_t id_token_len,
                                   const char *err, size_t err_len);

// `nonce` is the app's replay guard: Apple hashes it into the idToken's
// `nonce` claim, so the caller passes the raw value and verifies the
// SHA-256 of it server-side. Empty means "no nonce" — legal, and worse.
void *nokre_oauth_apple_start(void *ctx, nokre_oauth_apple_cb cb,
                            const char *nonce, size_t nonce_len);

// ---- Android's inbound leg ----
// The redirect does not come back to the tab that opened it: Android
// routes it to the app as an intent, through the same activity path
// deep_link uses. The shell's JNI entry point calls this, and the
// service's own android.c routes it to the live flow — a shell never
// learns what a flow is. `status` is one of the NOKRE_OAUTH_* codes above.
void nokre_oauth_dispatch(int status, const char *text, size_t len);

// ---- desktop ----
// Windows and Linux have no auth-session API worth binding, so their
// browser handoff is the shell's own launcher, `nokre_open_url_open`
// (src/services/open_url/open_url.h — the coupling is stated there),
// and the redirect comes back to a loopback listener that lives in
// Zig (RFC 8252 §7.3, loopback.zig). oauth declares no desktop C of
// its own.

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_OAUTH_H
