// macOS and iOS side of the oauth service: the three verbs of oauth.h
// (docs/services.md; design in docs/internals/oauth.md).
//
// Two legs, one framework. `nokre_oauth_start` is
// ASWebAuthenticationSession — the system browser in a sheet, with the
// cookie jar Safari already has, which is exactly what RFC 8252 asks a
// native app to use and what an embedded WKWebView must never be.
// `nokre_oauth_apple_start` is ASAuthorizationController, which Apple
// requires for a conforming Sign in with Apple flow on its own
// platforms. AuthenticationServices.framework is first-party, in the
// same class as the Security.framework secure_store links — not a
// vendored SDK, which matters because nokre has no dependency manager
// to host one.
//
// Policy stays in Zig, as everywhere else: the redirect string, the
// scheme, the one-flow rule, and the synthetic callback URL Apple's leg
// reports through are all decided before a call lands here. This file
// ferries bytes and owns exactly one thing — the session object, which
// cannot live anywhere else, and which it hands back as the opaque
// handle oauth.h describes.
//
// The presentation anchor comes from the app's own window rather than
// from the shell: a service that reached into shell state would be the
// shell/service split leaking, and both platforms can name their key
// window without help.

#import <Foundation/Foundation.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

#include <string.h>

#include "oauth.h"

API_AVAILABLE(macos(10.15), ios(13.0))
static ASPresentationAnchor nokre_oauth_anchor(void) {
#if TARGET_OS_OSX
    NSWindow *key = NSApplication.sharedApplication.keyWindow;
    if (key != nil) return key;
    return NSApplication.sharedApplication.windows.firstObject;
#else
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
#endif
}

// A failure name, in the shape the rest of nokre uses: a stable
// identifier the app can switch on, never a localized sentence. The
// domain-and-code pair is what actually distinguishes the cases; the
// description is for a log, not for a contract.
static const char *nokre_oauth_failure_name(NSError *error) {
    if (error == nil) return "AuthFailed";
    if ([error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain]) {
        switch (error.code) {
            case ASWebAuthenticationSessionErrorCodePresentationContextNotProvided:
            case ASWebAuthenticationSessionErrorCodePresentationContextInvalid:
                return "NoPresentationAnchor";
            default:
                return "SessionFailed";
        }
    }
    if ([error.domain isEqualToString:ASAuthorizationErrorDomain]) {
        switch (error.code) {
            case ASAuthorizationErrorInvalidResponse: return "InvalidResponse";
            case ASAuthorizationErrorNotHandled: return "NotHandled";
            case ASAuthorizationErrorFailed: return "AuthFailed";
            default: return "AuthFailed";
        }
    }
    return "AuthFailed";
}

// ---- the browser leg ----

API_AVAILABLE(macos(10.15), ios(13.0))
@interface NokreWebAuth : NSObject <ASWebAuthenticationPresentationContextProviding>
@property(nonatomic, strong) ASWebAuthenticationSession *session;
// YES once a result has been reported (or the app cancelled), so a
// second completion — which Apple does not promise cannot happen — is
// dropped rather than delivered twice.
@property(nonatomic, assign) BOOL done;
- (void)cancelFlow;
@end

@implementation NokreWebAuth
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return nokre_oauth_anchor();
}
- (void)cancelFlow {
    // Apple's contract: the completion handler does not run after this.
    [self.session cancel];
}
@end

void *nokre_oauth_start(void *ctx, nokre_oauth_cb cb,
                      const char *url, size_t url_len,
                      const char *scheme, size_t scheme_len) {
    if (@available(macOS 10.15, iOS 13.0, *)) {
        NSString *url_str = [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding];
        NSString *scheme_str = [[NSString alloc] initWithBytes:scheme length:scheme_len encoding:NSUTF8StringEncoding];
        NSURL *authorize = url_str == nil ? nil : [NSURL URLWithString:url_str];
        if (authorize == nil || scheme_str == nil) return NULL;

        NokreWebAuth *box = [NokreWebAuth new];
        // The +1 the Zig side holds: the object stays alive for exactly
        // as long as the flow, and the release below is what ends it.
        void *handle = (void *)CFBridgingRetain(box);

        // The block captures `handle` as a bare pointer, never the box:
        // capturing the box would close a cycle (box → session → block →
        // box) that nothing could break.
        ASWebAuthenticationSession *session = [[ASWebAuthenticationSession alloc]
            initWithURL:authorize
            callbackURLScheme:scheme_str
            completionHandler:^(NSURL *callback_url, NSError *error) {
                NokreWebAuth *self_box = (__bridge NokreWebAuth *)handle;
                if (self_box.done) return;
                self_box.done = YES;
                if (callback_url != nil) {
                    const char *bytes = callback_url.absoluteString.UTF8String;
                    cb(ctx, NOKRE_OAUTH_CALLBACK, bytes, bytes == NULL ? 0 : strlen(bytes));
                } else if ([error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain] &&
                           error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                    cb(ctx, NOKRE_OAUTH_CANCELLED, "", 0);
                } else {
                    const char *name = nokre_oauth_failure_name(error);
                    cb(ctx, NOKRE_OAUTH_FAILURE, name, strlen(name));
                }
                // Deferred, not immediate: releasing the box here would
                // release the session, and with it the very block that
                // is still executing. One hop to the main queue puts the
                // teardown safely past this frame.
                dispatch_async(dispatch_get_main_queue(), ^{
                    CFRelease(handle);
                });
            }];
        session.presentationContextProvider = box;
        // Deliberately NOT ephemeral: reusing Safari's session is the
        // whole point of the system browser — it is what makes "you are
        // already signed in to Google" one tap instead of a password.
        box.session = session;
        if (![session start]) {
            CFRelease(handle);
            return NULL;
        }
        return handle;
    }
    // Below the AuthenticationServices floor there is no trustworthy
    // browser session to open, and an embedded web view is not a
    // substitute — the Zig side reports SessionUnavailable.
    return NULL;
}

void nokre_oauth_cancel(void *session) {
    if (@available(macOS 10.15, iOS 13.0, *)) {
        // Either box type may be behind the handle; both answer -done
        // and -cancelFlow, so the dispatch is on the selector, not on a
        // tag the two would have to keep in sync.
        id box = (__bridge id)session;
        [box setDone:YES];
        [box cancelFlow];
        CFRelease(session);
    }
}

// ---- Apple's native leg ----
// The grant comes back as fields; Zig composes the synthetic callback
// URL from them (percent-encoding is policy). Both scopes are requested
// unconditionally: Apple offers exactly two, an app that wants a name
// and an email is every app that has a sign-in, and the user gets the
// per-field choice in Apple's own sheet either way — so a knob here
// would buy nothing the platform does not already give the person who
// matters.

API_AVAILABLE(macos(10.15), ios(13.0))
@interface NokreAppleAuth : NSObject <ASAuthorizationControllerDelegate,
                                    ASAuthorizationControllerPresentationContextProviding>
@property(nonatomic, strong) ASAuthorizationController *controller;
@property(nonatomic, assign) BOOL done;
@property(nonatomic, assign) void *ctx;
@property(nonatomic, assign) nokre_oauth_apple_cb cb;
@property(nonatomic, assign) void *handle;
@end

@implementation NokreAppleAuth

- (ASPresentationAnchor)presentationAnchorForAuthorizationController:(ASAuthorizationController *)controller {
    return nokre_oauth_anchor();
}

- (void)finish {
    dispatch_async(dispatch_get_main_queue(), ^{
        CFRelease(self.handle);
    });
}

- (void)cancelFlow {
    // ASAuthorizationController has no cancel: the sheet is the system's
    // and only the user dismisses it. Marking the flow done is what
    // honours oauth.h's "the callback must not fire afterwards" — the
    // delegate still runs, and drops what it was going to report.
}

- (void)authorizationController:(ASAuthorizationController *)controller
    didCompleteWithAuthorization:(ASAuthorization *)authorization {
    if (self.done) return;
    self.done = YES;
    ASAuthorizationAppleIDCredential *credential = nil;
    if ([authorization.credential isKindOfClass:ASAuthorizationAppleIDCredential.class]) {
        credential = (ASAuthorizationAppleIDCredential *)authorization.credential;
    }
    if (credential == nil) {
        const char *name = "InvalidResponse";
        self.cb(self.ctx, NOKRE_OAUTH_FAILURE, "", 0, "", 0, name, strlen(name));
        [self finish];
        return;
    }
    // Both arrive as UTF-8 NSData: the code is an opaque grant, the
    // identity token a JWT. Neither is decoded here — nokre returns
    // bytes, and the signature check needs the server's JWKS anyway.
    NSString *code = credential.authorizationCode == nil
                         ? @""
                         : [[NSString alloc] initWithData:credential.authorizationCode
                                                 encoding:NSUTF8StringEncoding];
    NSString *token = credential.identityToken == nil
                          ? @""
                          : [[NSString alloc] initWithData:credential.identityToken
                                                  encoding:NSUTF8StringEncoding];
    const char *code_bytes = code == nil ? "" : code.UTF8String;
    const char *token_bytes = token == nil ? "" : token.UTF8String;
    self.cb(self.ctx, NOKRE_OAUTH_CALLBACK,
            code_bytes, strlen(code_bytes),
            token_bytes, strlen(token_bytes),
            "", 0);
    [self finish];
}

- (void)authorizationController:(ASAuthorizationController *)controller
           didCompleteWithError:(NSError *)error {
    if (self.done) return;
    self.done = YES;
    if ([error.domain isEqualToString:ASAuthorizationErrorDomain] &&
        error.code == ASAuthorizationErrorCanceled) {
        self.cb(self.ctx, NOKRE_OAUTH_CANCELLED, "", 0, "", 0, "", 0);
    } else {
        const char *name = nokre_oauth_failure_name(error);
        self.cb(self.ctx, NOKRE_OAUTH_FAILURE, "", 0, "", 0, name, strlen(name));
    }
    [self finish];
}

@end

void *nokre_oauth_apple_start(void *ctx, nokre_oauth_apple_cb cb,
                            const char *nonce, size_t nonce_len) {
    if (@available(macOS 10.15, iOS 13.0, *)) {
        NokreAppleAuth *box = [NokreAppleAuth new];
        box.ctx = ctx;
        box.cb = cb;
        void *handle = (void *)CFBridgingRetain(box);
        box.handle = handle;

        ASAuthorizationAppleIDProvider *provider = [ASAuthorizationAppleIDProvider new];
        ASAuthorizationAppleIDRequest *request = [provider createRequest];
        request.requestedScopes = @[ ASAuthorizationScopeFullName, ASAuthorizationScopeEmail ];
        if (nonce_len > 0) {
            request.nonce = [[NSString alloc] initWithBytes:nonce length:nonce_len encoding:NSUTF8StringEncoding];
        }

        ASAuthorizationController *controller =
            [[ASAuthorizationController alloc] initWithAuthorizationRequests:@[ request ]];
        controller.delegate = box;
        controller.presentationContextProvider = box;
        box.controller = controller;
        [controller performRequests];
        return handle;
    }
    return NULL;
}
