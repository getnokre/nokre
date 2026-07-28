// macOS AppKit shell. Thin by charter: window, gray8 blit, input
// forwarding, NSTextInputClient for IME. No timers, no CADisplayLink —
// nokre repaints only when state changes.
#import <Cocoa/Cocoa.h>
#include "../shell.h"
#include "../../services/deep_link/deep_link.h"
#include "../../services/locale/locale.h"
#include "../../services/open_url/open_url.h"

@interface NokreView : NSView <NSTextInputClient> {
  @public
    nokre_shell_config config;
    NSMutableAttributedString *markedText;
}
@end

@implementation NokreView

- (instancetype)initWithFrame:(NSRect)frame config:(const nokre_shell_config *)cfg {
    self = [super initWithFrame:frame];
    if (self) {
        config = *cfg;
        markedText = [[NSMutableAttributedString alloc] init];
        self.wantsLayer = NO;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES; // nokre's origin is top-left
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)maybeRepaint {
    if (config.wants_frame(config.ctx)) {
        [self setNeedsDisplay:YES];
    }
}

- (void)reportAppearance {
    NSAppearanceName name = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    config.on_appearance(config.ctx, [name isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0);
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self reportAppearance];
    [self maybeRepaint];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    // Redraw synchronously with the resize so content tracks the window
    // edge instead of stretching.
    self.needsDisplay = YES;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    int32_t scale = (int32_t)self.window.backingScaleFactor;
    if (scale < 1) scale = 1;
    int32_t logical_w = (int32_t)lround(self.bounds.size.width);
    int32_t logical_h = (int32_t)lround(self.bounds.size.height);
    if (logical_w < 1 || logical_h < 1) return;
    int32_t w = 0, h = 0;
    const uint8_t *pixels = config.on_frame(config.ctx, logical_w, logical_h, 0, scale, &w, &h);
    if (!pixels || w <= 0 || h <= 0) return;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(NULL, pixels, (size_t)w * (size_t)h, NULL);
    CGImageRef image = CGImageCreate((size_t)w, (size_t)h, 8, 8, (size_t)w, space,
                                     kCGBitmapByteOrderDefault, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
    CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
    // The view is flipped; un-flip for CGContextDrawImage.
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, 0, self.bounds.size.height);
    CGContextScaleCTM(cg, 1, -1);
    CGContextDrawImage(cg, self.bounds, image);
    CGContextRestoreGState(cg);
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
}

// ---- pointer ----

- (void)pointer:(NSEvent *)event phase:(int32_t)phase {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    config.on_pointer(config.ctx, (int32_t)p.x, (int32_t)p.y, phase);
    [self maybeRepaint];
}

- (void)mouseDown:(NSEvent *)event {
    [self pointer:event phase:NOKRE_POINTER_DOWN];
}

// AppKit delivers drags to the view that took the mouseDown for the
// whole press, so a release past the window's edge still arrives — no
// explicit capture needed here, unlike Win32.
- (void)mouseDragged:(NSEvent *)event {
    [self pointer:event phase:NOKRE_POINTER_MOVE];
}

- (void)mouseUp:(NSEvent *)event {
    [self pointer:event phase:NOKRE_POINTER_UP];
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    // scrollingDelta is fractional for trackpads, and a slow two-finger
    // scroll arrives as a stream of sub-pixel deltas — truncating each
    // one to 0 makes slow scrolling dead. Accumulate and flush whole
    // pixels, keeping the remainder (the Wayland/Windows shells' wheel
    // remainder, in floating point because AppKit's deltas are).
    static CGFloat rem_x = 0, rem_y = 0;
    rem_x += -event.scrollingDeltaX;
    rem_y += -event.scrollingDeltaY;
    int32_t dx = (int32_t)rem_x; // trunc toward zero keeps the sign exact
    int32_t dy = (int32_t)rem_y;
    rem_x -= dx;
    rem_y -= dy;
    if (dx != 0 || dy != 0) {
        config.on_scroll(config.ctx, (int32_t)p.x, (int32_t)p.y, dx, dy, NOKRE_SCROLL_FREE);
        [self maybeRepaint];
    }
}

// ---- keyboard ----

static uint8_t modsFromFlags(NSEventModifierFlags flags) {
    uint8_t mods = 0;
    if (flags & NSEventModifierFlagShift) mods |= NOKRE_MOD_SHIFT;
    if (flags & NSEventModifierFlagControl) mods |= NOKRE_MOD_CTRL;
    if (flags & NSEventModifierFlagOption) mods |= NOKRE_MOD_ALT;
    if (flags & NSEventModifierFlagCommand) mods |= NOKRE_MOD_META;
    return mods;
}

static int32_t keyFromEvent(NSEvent *event) {
    switch (event.keyCode) {
        case 48: return NOKRE_KEY_TAB;
        case 36: case 76: return NOKRE_KEY_ENTER;
        case 49: return NOKRE_KEY_SPACE;
        case 53: return NOKRE_KEY_ESCAPE;
        case 51: return NOKRE_KEY_BACKSPACE;
        case 117: return NOKRE_KEY_DELETE;
        case 123: return NOKRE_KEY_LEFT;
        case 124: return NOKRE_KEY_RIGHT;
        case 126: return NOKRE_KEY_UP;
        case 125: return NOKRE_KEY_DOWN;
        case 115: return NOKRE_KEY_HOME;
        case 119: return NOKRE_KEY_END;
        case 116: return NOKRE_KEY_PAGE_UP;
        case 121: return NOKRE_KEY_PAGE_DOWN;
        default: return 0;
    }
}

- (void)keyDown:(NSEvent *)event {
    int32_t key = keyFromEvent(event);
    // The input context owns the event whenever its result is text: mid
    // composition, for every key outside the portable enum (dead keys
    // and IME starts included), and — per shell.h's one-press-one-leg
    // rule — for Space while a field has focus, where it must arrive as
    // insertText and not as a key nothing in a field consumes. Space
    // over anything else is activation and stays a key.
    if (markedText.length > 0 || key == 0 ||
        (key == NOKRE_KEY_SPACE && config.wants_text_input(config.ctx))) {
        [self.inputContext handleEvent:event];
        [self maybeRepaint];
        return;
    }
    config.on_key(config.ctx, key, modsFromFlags(event.modifierFlags));
    [self maybeRepaint];
}

// ---- NSTextInputClient (IME) ----

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
    if (markedText.length > 0) {
        [markedText deleteCharactersInRange:NSMakeRange(0, markedText.length)];
        const char *utf8 = text.UTF8String;
        config.on_ime_commit(config.ctx, utf8, strlen(utf8));
    } else {
        const char *utf8 = text.UTF8String;
        config.on_text(config.ctx, utf8, strlen(utf8));
    }
    [self maybeRepaint];
}

// The shell contract's caret is a UTF-8 byte offset into the marked
// text (docs/internals/platform-shells.md), but Apple reports UTF-16
// code units — convert, as the Windows shell does. A location inside a
// surrogate pair cannot convert (the length comes back 0), so the
// caret clamps to the end rather than jump to the start.
static size_t nokre_caret_utf8(NSString *s, NSUInteger loc, size_t utf8_len) {
    if (loc >= s.length) return utf8_len;
    NSUInteger bytes = [[s substringToIndex:loc] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (bytes == 0 && loc > 0) return utf8_len;
    return bytes < utf8_len ? (size_t)bytes : utf8_len;
}

- (void)setMarkedText:(id)string
        selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
    [markedText replaceCharactersInRange:NSMakeRange(0, markedText.length) withString:text];
    const char *utf8 = text.UTF8String;
    size_t len = strlen(utf8);
    config.on_ime_update(config.ctx, utf8, len,
                         nokre_caret_utf8(text, selectedRange.location, len));
    [self maybeRepaint];
}

- (void)unmarkText {
    // NSTextInputClient semantics: unmark accepts the composition as
    // input — a commit, not a cancel (the iOS shell's UITextInput
    // unmark is the same rule).
    if (markedText.length > 0) {
        const char *utf8 = markedText.string.UTF8String;
        config.on_ime_commit(config.ctx, utf8, strlen(utf8));
        [markedText deleteCharactersInRange:NSMakeRange(0, markedText.length)];
        [self maybeRepaint];
    }
}

- (BOOL)hasMarkedText {
    return markedText.length > 0;
}

- (NSRange)markedRange {
    return markedText.length > 0 ? NSMakeRange(0, markedText.length) : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange {
    return NSMakeRange(NSNotFound, 0);
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actualRange {
    return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // TODO(ime): report the focused text input's caret rect so the
    // candidate window docks next to it.
    NSRect frame = self.window.frame;
    return NSMakeRect(frame.origin.x, frame.origin.y, 0, 0);
}

- (void)doCommandBySelector:(SEL)selector {
    // Composition-phase control keys (escape cancels, etc.) arrive here;
    // NSTextInputClient protocol requires the method to exist.
}

@end

// Defined with the other service hooks below; the delegate forwards to it.
static void nokre_deep_link_dispatch(NSURL *url);

@interface NokreAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
  @public
    nokre_shell_config config;
}
@end

@implementation NokreAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    config.on_window_focus(config.ctx, 1);
}

- (void)windowDidResignKey:(NSNotification *)notification {
    config.on_window_focus(config.ctx, 0);
}

// deep_link: custom-scheme URLs (CFBundleURLTypes) and re-opens arrive
// here; Universal Links arrive as a browsing user activity. Both forward
// the whole URL to the service, which extracts what the app routes on.
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) nokre_deep_link_dispatch(url);
}

- (BOOL)application:(NSApplication *)application
    continueUserActivity:(NSUserActivity *)userActivity
      restorationHandler:(void (^)(NSArray<id<NSUserActivityRestoring>> *))restorationHandler {
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] &&
        userActivity.webpageURL != nil) {
        nokre_deep_link_dispatch(userActivity.webpageURL);
        return YES;
    }
    return NO;
}
@end

// Dedicated subclass so the a11y adapter can add a focus forwarder to
// this window class without touching NSWindow itself.
@interface NokreWindow : NSWindow
@end

@implementation NokreWindow
@end

// deep_link service inbound hook (docs/services.md;
// src/services/deep_link/deep_link.h). The single-app anchor: this shell
// runs one app per process, so the installed ctx + callback live at file
// scope — the web shell's one-app rule, native. A URL that arrives before
// the app registers its handler (rare on macOS — openURLs fires after
// launch — but possible) is buffered and flushed on install, so a launch
// URL is never dropped.
static void *g_deep_link_ctx = NULL;
static nokre_deep_link_cb g_deep_link_cb = NULL;
static NSString *g_deep_link_pending = nil;
// The one view, held for every inbound service hook — not deep_link's
// alone, hence the neutral name. Weak and file-scope like the iOS
// shell's: [NSApp mainWindow] is nil while the app is inactive, which
// is exactly when a launch URL or locale change can arrive.
static __weak NokreView *g_main_view = nil;

static void nokre_deep_link_dispatch(NSURL *url) {
    if (url == nil) return;
    NSString *s = url.absoluteString;
    if (g_deep_link_cb == NULL) {
        g_deep_link_pending = s;
        return;
    }
    const char *bytes = s.UTF8String;
    g_deep_link_cb(g_deep_link_ctx, bytes, strlen(bytes));
    // The handler routed and invalidated like any action; mark the view
    // dirty so the on-demand loop paints the result (worker-pump rule).
    g_main_view.needsDisplay = YES;
}

void nokre_deep_link_install(void *ctx, nokre_deep_link_cb cb) {
    g_deep_link_ctx = ctx;
    g_deep_link_cb = cb;
    if (g_deep_link_pending != nil) {
        NSString *s = g_deep_link_pending;
        g_deep_link_pending = nil;
        const char *bytes = s.UTF8String;
        cb(ctx, bytes, strlen(bytes));
    }
}

void nokre_deep_link_uninstall(void) {
    // Back to the pre-install posture: a URL that arrives now is
    // buffered for the next install, never delivered into per-app state
    // the app has already freed.
    g_deep_link_ctx = NULL;
    g_deep_link_cb = NULL;
}

// locale service inbound hook (docs/services.md;
// src/services/locale/locale.h). Same single-app anchor as deep_link,
// minus the pending buffer: unlike a launch URL there is nothing here to
// miss, the device locale is readable on demand, so install reads it
// itself and the shell keeps no copy of the tag. The cache, the length
// cap and what an unknown locale means are Zig's policy.
static void *g_locale_ctx = NULL;
static nokre_locale_cb g_locale_cb = NULL;

// preferredLanguages, not [NSLocale currentLocale].localeIdentifier: the
// former is the user's ordered *display-language* list, already BCP 47
// with '-' ("en-US", "zh-Hans-CN"), which is the preference a message
// bundle should resolve against; the latter is the *formatting* locale
// in POSIX flavor ("en_US"), a different setting that merely looks
// alike. An empty list means macOS cannot name a language: hand over the
// empty tag rather than guessing, per locale.h.
static void nokre_locale_report(void) {
    // The notification observer outlives an uninstall (one app per
    // process, and re-registering would double-fire), so a change after
    // teardown lands here with no callback: drop it.
    if (g_locale_cb == NULL) return;
    // Install runs from App.init, before nokre_shell_run's pool exists, so
    // the autoreleased NSArray/NSString need one of their own here.
    @autoreleasepool {
        NSString *first = NSLocale.preferredLanguages.firstObject;
        if (first == nil) {
            g_locale_cb(g_locale_ctx, "", 0);
            return;
        }
        const char *bytes = first.UTF8String;
        g_locale_cb(g_locale_ctx, bytes, strlen(bytes));
    }
}

void nokre_locale_install(void *ctx, nokre_locale_cb cb) {
    g_locale_ctx = ctx;
    g_locale_cb = cb;
    nokre_locale_report(); // the boot read, synchronous before we return
    // mainQueue *is* the marshal the contract asks for, so the block
    // needs no dispatch hop of its own. Never removed: one app per
    // process, and it outlives every locale change. A display-language
    // switch usually restarts the app anyway, so in practice the boot
    // read is what runs; region and format changes do arrive live, and
    // the observer is the cheap correctness backstop for them.
    // Registered once: a re-install (a second App lifetime) replaces
    // ctx + cb, and a second observer would double-fire the callback.
    static BOOL observing = NO;
    if (observing) return;
    observing = YES;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSCurrentLocaleDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                  (void)note;
                  nokre_locale_report();
                  // The handler re-resolved its bundle like any action;
                  // mark the view dirty so the on-demand loop paints it.
                  // Change fires only — at install time there is no
                  // window yet and the view reference is nil.
                  g_main_view.needsDisplay = YES;
                }];
}

void nokre_locale_uninstall(void) {
    g_locale_ctx = NULL;
    g_locale_cb = NULL;
}

void nokre_shell_write_clipboard(const char *utf8, size_t len) {
    NSString *text = [[NSString alloc] initWithBytes:utf8
                                              length:len
                                            encoding:NSUTF8StringEncoding];
    if (text == nil) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}

void nokre_open_url_open(const char *url, size_t len) {
    NSString *str = [[NSString alloc] initWithBytes:url
                                             length:len
                                           encoding:NSUTF8StringEncoding];
    NSURL *target = str == nil ? nil : [NSURL URLWithString:str];
    if (target == nil) return;
    // The default handler for the scheme: Safari-or-whatever for https,
    // the user's mail client for mailto. Fire-and-forget by contract,
    // so the BOOL result is not consulted.
    [NSWorkspace.sharedWorkspace openURL:target];
}

void nokre_shell_request_frame(void *view) {
    NSView *v = (__bridge NSView *)view;
    dispatch_async(dispatch_get_main_queue(), ^{
      v.needsDisplay = YES;
    });
}

int32_t nokre_shell_run(const nokre_shell_config *config) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NokreAppDelegate *delegate = [[NokreAppDelegate alloc] init];
        delegate->config = *config;
        [app setDelegate:delegate];

        NSRect frame = NSMakeRect(0, 0, config->logical_w, config->logical_h);
        NokreWindow *window = [[NokreWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = [NSString stringWithUTF8String:config->title];
        window.delegate = delegate;
        [window center];

        NokreView *view = [[NokreView alloc] initWithFrame:frame config:config];
        window.contentView = view;
        [window makeFirstResponder:view];
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        g_main_view = view;
        config->on_ready(config->ctx, (__bridge void *)view, "NokreWindow");
        config->on_window_focus(config->ctx, window.isKeyWindow ? 1 : 0);

        [view reportAppearance];
        [view setNeedsDisplay:YES];
        [app run];
    }
    return 0;
}
