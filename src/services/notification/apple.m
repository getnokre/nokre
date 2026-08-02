// notification, Apple's half — macOS and iOS from one file
// (docs/internals/notifications.md).
//
// oauth's placement, not deep_link's: UNUserNotificationCenter's delegate
// is any object, not the app delegate, so nothing here needs to be the
// shell — and one file serving both Apple platforms beats the verbatim
// duplication the locale hook pays across the same two shells. The shells
// get involved in exactly one place, for one reason: an APNs token is
// delivered to the *application* delegate by UIKit/AppKit and nowhere
// else, so each shell owns that delegate method and hands the bytes to
// the sink this file installs (nokre_notification_apple_set_push_token_
// sink, notification.h). That is oauth's Android-intent exception,
// restated on Apple — and it is *this* file that names the shell, never
// the other way round, because a shell links in every app and this one
// does not.
//
// UNUserNotificationCenter is both halves on both platforms: a local
// request and a remote push land in the same delegate, which is why push
// costs this file almost nothing beyond the token.
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#include "notification.h"

// The route reference rides userInfo under a key nobody else writes. Not
// the notification's body and not its threadIdentifier: those are the
// user's to see, and a route is nokre's own reference (docs/routing.md).
static NSString *const kNokreRouteKey = @"dev.nokre.route";

static void *g_ctx = NULL;
static nokre_notification_cb g_cb = NULL;
// The tap that launched the process arrives before App.init has had a
// chance to install, so it waits here — the one thing notification.h asks
// a native side to buffer, for deep_link's launch-URL reason.
static NSString *g_pending_id = nil;
static NSString *g_pending_route = nil;
// Read once at install and refreshed whenever the app comes forward:
// UNUserNotificationCenter answers settings asynchronously, and the boot
// probe is synchronous by contract.
static int32_t g_status = NOKRE_NOTIFICATION_NOT_DETERMINED;

// Defined at the bottom, beside the wire format it owns; installed into
// the shell from nokre_notification_install below.
static void nokre_notification_apple_push_token(const uint8_t *bytes, size_t len);

static int32_t nokre_notification_status_of(UNAuthorizationStatus s) {
    switch (s) {
    case UNAuthorizationStatusNotDetermined:
        return NOKRE_NOTIFICATION_NOT_DETERMINED;
    case UNAuthorizationStatusDenied:
        return NOKRE_NOTIFICATION_DENIED;
    // Authorized, provisional, and ephemeral all post something the user
    // can see, which is the only distinction this service draws. A
    // provisional grant delivers quietly to the notification centre —
    // still granted, and reporting it as anything else would send an app
    // into a prompt the user has already been spared.
    default:
        return NOKRE_NOTIFICATION_GRANTED;
    }
}

// Settings are async-only on Apple, and the boot probe is synchronous by
// contract — nokre has no ticker to retire a loading frame an async
// answer would strand (secure_store's argument, and the reason its
// Keychain calls block too). The wait is bounded rather than trusted: the
// query answers in microseconds off a system queue, and a timeout reports
// "not determined", which is the state that makes an app ask.
static void nokre_notification_refresh_status(BOOL notify) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int32_t fresh = NOKRE_NOTIFICATION_NOT_DETERMINED;
    [UNUserNotificationCenter.currentNotificationCenter
        getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
          fresh = nokre_notification_status_of(settings.authorizationStatus);
          dispatch_semaphore_signal(done);
        }];
    // The completion runs on an unspecified background queue, never the
    // main one, so waiting here cannot deadlock against ourselves.
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)) != 0) {
        return; // timed out: leave the cache alone rather than invent an answer
    }
    if (fresh == g_status) return;
    g_status = fresh;
    // Only a *change* is an event. The install read is not one: it
    // happens inside App.init, before any handler exists, and the value
    // is already readable synchronously through the probe.
    if (notify && g_cb != NULL) {
        g_cb(g_ctx, NOKRE_NOTIFICATION_AUTHORIZED, g_status, "", 0, "", 0);
    }
}

static void nokre_notification_emit(int32_t kind, NSString *ident, NSString *route) {
    if (g_cb == NULL) return;
    const char *a = ident != nil ? ident.UTF8String : "";
    const char *b = route != nil ? route.UTF8String : "";
    if (a == NULL) a = "";
    if (b == NULL) b = "";
    g_cb(g_ctx, kind, g_status, a, strlen(a), b, strlen(b));
}

// The delegate is nokre's own object, owned by this file and living for
// the process — it is the notification centre's, not a view's, and a
// weak reference would leave taps landing on nil.
@interface NokreNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation NokreNotificationDelegate

// A notification coming due while the app is on screen. The banner is
// suppressed deliberately (UNNotificationPresentationOptionNone): drawing
// a lock-screen card over the app the user is already looking at is the
// OS interrupting someone on nokre's behalf, and the screen that would
// carry the news is right there. The event goes to the app instead.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    UNNotificationRequest *req = notification.request;
    nokre_notification_emit(NOKRE_NOTIFICATION_RECEIVED, req.identifier,
                            req.content.userInfo[kNokreRouteKey]);
    completionHandler(UNNotificationPresentationOptionNone);
}

// The tap. Buffered when it arrives before install, which on a cold
// launch it does: the OS hands the response to the delegate as the app
// starts, and App.init has not run yet.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    UNNotificationRequest *req = response.notification.request;
    NSString *route = req.content.userInfo[kNokreRouteKey];
    if (g_cb == NULL) {
        g_pending_id = req.identifier;
        g_pending_route = route;
    } else {
        nokre_notification_emit(NOKRE_NOTIFICATION_OPENED, req.identifier, route);
    }
    completionHandler();
}

@end

static NokreNotificationDelegate *g_delegate = nil;

void nokre_notification_install(void *ctx, nokre_notification_cb cb) {
    g_ctx = ctx;
    g_cb = cb;
    // Strictly before any registerForRemoteNotifications, which only
    // nokre_notification_request_push below ever calls — so a token can
    // never arrive at a shell holding no sink.
    nokre_notification_apple_set_push_token_sink(nokre_notification_apple_push_token);
    if (g_delegate == nil) {
        g_delegate = [[NokreNotificationDelegate alloc] init];
        UNUserNotificationCenter.currentNotificationCenter.delegate = g_delegate;
        // The user can flip the switch in Settings while the app is
        // backgrounded, and coming forward is the only moment that is
        // observable — so the cache is refreshed there, and a change
        // fires the event the app writes its one path against.
#if TARGET_OS_IPHONE
        NSNotificationName forward = UIApplicationDidBecomeActiveNotification;
#else
        NSNotificationName forward = NSApplicationDidBecomeActiveNotification;
#endif
        [NSNotificationCenter.defaultCenter addObserverForName:forward
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
                                                      (void)note;
                                                      nokre_notification_refresh_status(YES);
                                                    }];
    }
    nokre_notification_refresh_status(NO);
    if (g_pending_id != nil) {
        NSString *ident = g_pending_id;
        NSString *route = g_pending_route;
        g_pending_id = nil;
        g_pending_route = nil;
        nokre_notification_emit(NOKRE_NOTIFICATION_OPENED, ident, route);
    }
}

void nokre_notification_uninstall(void) {
    // Back to the pre-install posture: a tap that arrives now buffers for
    // the next install rather than reaching per-app state the app has
    // already freed. The delegate and the observer stay — they belong to
    // the process, and one app per process is the charter.
    g_ctx = NULL;
    g_cb = NULL;
    // The shell outlives this service's interest in it, so it is handed
    // back the NULL it started with rather than a pointer into a file
    // that no longer wants the call.
    nokre_notification_apple_set_push_token_sink(NULL);
}

int32_t nokre_notification_available(void) {
    // Apple has a notification centre on every version nokre targets, and
    // an app that is denied still *has* one — that is `status`, not this.
    return 1;
}

int32_t nokre_notification_push_available(void) {
    // APNs needs the aps-environment entitlement, which the app either
    // signed with or did not; registering without it fails at runtime on
    // a real device. Zig gates this on the linked push option before it
    // ever asks, so reaching here means the entitlement was declared.
    return 1;
}

int32_t nokre_notification_schedule_available(void) {
    // UNUserNotificationCenter holds the request itself, so a scheduled
    // notification survives the app being closed and the device being
    // restarted. The one platform family where a fire date costs nothing
    // to keep.
    return 1;
}

int32_t nokre_notification_status(void) { return g_status; }

void nokre_notification_authorize(void) {
    UNAuthorizationOptions opts =
        UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:opts
                      completionHandler:^(BOOL granted, NSError *error) {
                        (void)granted;
                        (void)error;
                        // The prompt's own answer is not read here:
                        // `granted` reports what the user pressed, while
                        // the settings report what the app *has*, and
                        // those differ for a provisional grant. Re-read
                        // the authority, on the main thread, then let the
                        // one lane carry it.
                        dispatch_async(dispatch_get_main_queue(), ^{
                          nokre_notification_refresh_status(YES);
                        });
                      }];
}

void nokre_notification_post(const char *id, size_t id_len, const char *title, size_t title_len,
                             const char *body, size_t body_len, const char *route, size_t route_len,
                             int32_t important, int64_t at_millis) {
    NSString *ident = [[NSString alloc] initWithBytes:id length:id_len encoding:NSUTF8StringEncoding];
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [[NSString alloc] initWithBytes:title length:title_len encoding:NSUTF8StringEncoding];
    if (body_len != 0) {
        content.body = [[NSString alloc] initWithBytes:body length:body_len encoding:NSUTF8StringEncoding];
    }
    if (route_len != 0) {
        NSString *r = [[NSString alloc] initWithBytes:route length:route_len encoding:NSUTF8StringEncoding];
        content.userInfo = @{kNokreRouteKey : r};
    }
    // Quiet by default, and the important one interrupts: `active` posts
    // without breaking through a Focus, `timeSensitive` asks to. The
    // sound follows the same split — an unimportant notification that
    // makes a noise is interrupting by another route.
    if (important) {
        content.sound = UNNotificationSound.defaultSound;
        if (@available(iOS 15.0, macOS 12.0, *)) {
            content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
        }
    } else if (@available(iOS 15.0, macOS 12.0, *)) {
        content.interruptionLevel = UNNotificationInterruptionLevelActive;
    }

    UNNotificationTrigger *trigger = nil;
    if (at_millis != 0) {
        // Zig already refused a past instant, so this interval is
        // positive — but clamp anyway: the check ran a few instructions
        // ago against the same wall clock this reads, and a
        // non-positive interval is an exception on Apple, not an error
        // return.
        NSTimeInterval seconds =
            ((NSTimeInterval)at_millis / 1000.0) - NSDate.date.timeIntervalSince1970;
        if (seconds < 0.001) seconds = 0.001;
        trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:seconds repeats:NO];
    }
    // Posting the same identifier replaces rather than stacks, which is
    // the contract's own rule and Apple's default behaviour for a
    // repeated request identifier — nothing to arrange.
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:ident
                                                                     content:content
                                                                     trigger:trigger];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:req
                                                        withCompletionHandler:^(NSError *error){
                                                            // Fire-and-forget past Zig's checks: the
                                                            // only failures left are the OS's own, and
                                                            // there is no lane to report them on that
                                                            // an app could act differently for.
                                                            (void)error;
                                                        }];
}

void nokre_notification_cancel(const char *id, size_t id_len) {
    NSString *ident = [[NSString alloc] initWithBytes:id length:id_len encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *ids = @[ ident ];
    // Both halves, because the contract's cancel is one verb: a pending
    // request that has not fired, and a delivered one still sitting in
    // the notification centre.
    [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:ids];
    [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:ids];
}

void nokre_notification_request_push(const char *key, size_t key_len) {
    (void)key;
    (void)key_len; // APNs identifies the sender by the app's own registration
    // Must run on the main thread on both platforms, and the token comes
    // back to the *application* delegate — which is why the shells carry
    // the two methods, and why install handed them a sink first.
    dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_IPHONE
      [UIApplication.sharedApplication registerForRemoteNotifications];
#else
      [NSApplication.sharedApplication registerForRemoteNotifications];
#endif
    });
}

// The sink the two shells forward to: APNs hands the app delegate 32
// opaque bytes, and every push service on earth wants them hex. Rendering
// here rather than in each shell keeps the two delegates to a forwarding
// call, and keeps the wire format's owner in one place. Static — the
// shell reaches it through the pointer install handed over, so no app
// that skips this service has a symbol to resolve.
static void nokre_notification_apple_push_token(const uint8_t *bytes, size_t len) {
    if (g_cb == NULL || bytes == NULL || len == 0) return;
    NSMutableString *hex = [NSMutableString stringWithCapacity:len * 2];
    for (size_t i = 0; i < len; i++) [hex appendFormat:@"%02x", bytes[i]];
    const char *utf8 = hex.UTF8String;
    if (utf8 == NULL) return;
    g_cb(g_ctx, NOKRE_NOTIFICATION_PUSH_TOKEN, g_status, utf8, strlen(utf8), "", 0);
}
