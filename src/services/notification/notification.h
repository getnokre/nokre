// C contract between the notification native side and Zig. Two
// directions on one header: the app asks the OS to show, schedule, or
// take back a message (outbound, secure_store's shape), and the OS
// reports a decision, a tap, or a token (inbound, deep_link's shape).
//
// The native side holds no policy and no state beyond what the OS makes
// it hold. Every argument check — the id charset, the byte caps, the
// authorization gate, a fire date in the past — has already run in Zig,
// so a shell posts what it is handed. The one thing a shell must buffer
// is a tap that arrives before nokre_notification_install: the OS may
// launch the process *because* of the tap, and that event is the reason
// the launch happened, so dropping it is not an option. Everything after
// install is buffered on the Zig side, where one implementation serves
// all six platforms.
#ifndef NOKRE_SVC_NOTIFICATION_H
#define NOKRE_SVC_NOTIFICATION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Event kinds fired through nokre_notification_cb.
#define NOKRE_NOTIFICATION_AUTHORIZED 0
#define NOKRE_NOTIFICATION_OPENED 1
#define NOKRE_NOTIFICATION_PUSH_TOKEN 2
#define NOKRE_NOTIFICATION_RECEIVED 3

// Authorization states. Three, not two: "not determined" is a fresh
// install where asking is still legal, and "denied" is a decision no
// platform lets an app re-prompt its way out of.
#define NOKRE_NOTIFICATION_NOT_DETERMINED 0
#define NOKRE_NOTIFICATION_GRANTED 1
#define NOKRE_NOTIFICATION_DENIED 2

// One callback for every kind, so the native side carries no union and
// no per-kind state. Both string arguments are UTF-8, NOT NUL-terminated
// (each has its length), and borrowed for the call only:
//   AUTHORIZED  status = one of the three above; a and b empty.
//   OPENED      a = the notification id, b = its route reference
//               (either may be empty; the route is empty when the app
//               posted none).
//   PUSH_TOKEN  a = the device token as the platform renders it, b empty.
//   RECEIVED    a = id, b = route — a notification that came due while
//               the app was on screen. The shell must suppress the OS
//               banner for this case and fire this instead: drawing a
//               lock-screen card over the app the user is looking at is
//               the OS interrupting on nokre's behalf.
// A zero-length string may carry any pointer, including one that must
// not be dereferenced — check the length first.
typedef void (*nokre_notification_cb)(void* ctx, int32_t kind, int32_t status,
                                      const char* a, size_t a_len,
                                      const char* b, size_t b_len);

// Zig calls this once, from App.init. The shell stores ctx + cb and fires
// cb ON THE MAIN THREAD for: the authorization prompt being answered (or
// the user changing it in Settings while the app runs), every tap —
// including the buffered one that launched the process — and every push
// token the transport mints or rotates.
void nokre_notification_install(void* ctx, nokre_notification_cb cb);

// Forget the stored ctx + cb. Called from App.deinit: the ctx is per-app
// state the app is about to free, so an event landing after this must be
// dropped or re-buffered, never delivered through a dangling pointer.
void nokre_notification_uninstall(void);

// Boot probes, read once inside App.init so the first build can answer
// synchronously. Non-zero is true.
//   available       is there a notification system here at all (a Linux
//                   session with no daemon on the bus answers 0)
//   schedule_avail  can a fire date be handed over (see below)
//   push_available  is there a push transport (the Linux desktop and an
//                   unpackaged Windows app answer 0)
//   status          one of the three NOKRE_NOTIFICATION_* states
int32_t nokre_notification_available(void);
int32_t nokre_notification_push_available(void);
// Can a fire date be handed over? Four platforms answer 1. The Wayland
// desktop answers 0 (org.freedesktop.Notifications posts and nothing
// more — no daemon holds a date for an app that is not running) and so
// does the web (the scheduling trigger never shipped). nokre will not
// fill either in with a timer of its own: a schedule nokre keeps dies
// with the process, which is exactly when a reminder matters.
int32_t nokre_notification_schedule_available(void);
int32_t nokre_notification_status(void);

// Raise the platform's permission prompt. Fire-and-forget: the answer
// comes back through the callback as an AUTHORIZED event, because the
// same event also fires when nobody asked.
void nokre_notification_authorize(void);

// Show a notification, or schedule one. `at_millis` is 0 for "now" and
// otherwise the wall-clock instant to fire at, in milliseconds since the
// Unix epoch, UTC — the clock service's unit. Zig has already refused a
// past instant, so a shell may hand the number straight to the OS.
// Posting an id that is already showing replaces it rather than stacking
// a second one. `important` is 0 or 1 and selects the platform's
// interrupting presentation (on Android, the high-importance channel).
void nokre_notification_post(const char* id, size_t id_len,
                             const char* title, size_t title_len,
                             const char* body, size_t body_len,
                             const char* route, size_t route_len,
                             int32_t important, int64_t at_millis);

// Remove a shown notification and cancel a scheduled one with this id.
// Idempotent: an id that was never posted is success, because "already
// gone" is the state the caller asked for.
void nokre_notification_cancel(const char* id, size_t id_len);

// Ask the push transport for this device's token. Fire-and-forget: the
// token arrives through the callback as a PUSH_TOKEN event, this launch
// and on every rotation. A platform with no push transport implements
// this as an empty function — push_available already answered 0.
//
// `key` is the VAPID application server key, and only the web reads it:
// a browser refuses pushManager.subscribe without one, while APNs and FCM
// identify the sender by the app's own registration. It is empty on every
// other platform, and every other platform ignores it.
void nokre_notification_request_push(const char* key, size_t key_len);

// Android's inbound leg, and Android's alone: the event arrives in Java
// (NokreNotifications) and crosses through NokreView.nativeNotification
// Event, which the shell declares and the service's android.c implements
// — oauth's split, where a shell routes an event without learning what it
// means. Every other platform's native side calls the installed callback
// directly, so nothing else declares this.
void nokre_notification_dispatch(int32_t kind, int32_t status, const char *a, size_t a_len,
                                 const char *b, size_t b_len);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_NOTIFICATION_H
