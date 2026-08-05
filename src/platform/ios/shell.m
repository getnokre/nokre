// iOS UIKit shell. Thin by charter: full-screen view, RGBX blit, input
// forwarding, UITextInput for the software keyboard + IME, VoiceOver via
// UIAccessibility elements built from the flattened a11y snapshot. No
// timers, no CADisplayLink — nokre repaints only when state changes.
// Scroll momentum looks like an exception but isn't: a hidden
// UIScrollView is the scroll engine (drag tracking, flick deceleration),
// and each offset change it produces arrives here as an ordinary event.
//
// Two responders share the view controller: NokreView is first responder
// exactly while the focused element accepts text (`wants_text_input`),
// which is what shows and hides the software keyboard; the rest of the
// time the view controller holds first responder and forwards hardware
// keys via pressesBegan.
#import <UIKit/UIKit.h>
#include "../shell.h"
#include "../../services/deep_link/deep_link.h"
#include "../../services/locale/locale.h"
#include "../../services/open_url/open_url.h"
#include "../../services/share/share.h"
#include "../../services/notification/notification.h"
#include "../../../shim/nokre_accesskit.h"
#include <string.h>

// Where an APNs token goes, installed by the notification service's Apple
// half (src/services/notification/apple.m) and NULL in every app that
// links no notifications — in which case the delegate method below is
// dead code, since only that file ever asks UIKit to register. The shell
// defines this rather than calling into the service, for the reason
// notification.h states at length: the shell is always linked and
// apple.m is not, so a call the other way is a link error for every app
// that skips the service.
static nokre_notification_push_token_fn g_push_token_sink = NULL;

void nokre_notification_apple_set_push_token_sink(nokre_notification_push_token_fn fn) {
    g_push_token_sink = fn;
}

static nokre_shell_config g_config;

// ---- UITextInput plumbing: integer positions into the marked text ----
//
// The shell's "document" is only the in-progress IME composition; the
// real value lives in core (shells may not know it). Autocorrection and
// friends are disabled, so the keyboard never needs more context than
// this — the same bargain the macOS NSTextInputClient port makes.

@interface NokreTextPosition : UITextPosition
@property(nonatomic) NSInteger index;
+ (instancetype)position:(NSInteger)index;
@end

@implementation NokreTextPosition
+ (instancetype)position:(NSInteger)index {
    NokreTextPosition *p = [[NokreTextPosition alloc] init];
    p.index = index;
    return p;
}
@end

@interface NokreTextRange : UITextRange
@property(nonatomic) NSRange range;
+ (instancetype)range:(NSRange)range;
@end

@implementation NokreTextRange
+ (instancetype)range:(NSRange)range {
    NokreTextRange *r = [[NokreTextRange alloc] init];
    r.range = range;
    return r;
}
- (UITextPosition *)start {
    return [NokreTextPosition position:(NSInteger)self.range.location];
}
- (UITextPosition *)end {
    return [NokreTextPosition position:(NSInteger)NSMaxRange(self.range)];
}
- (BOOL)isEmpty {
    return self.range.length == 0;
}
@end

// ---- accessibility ----

@class NokreView;

@interface NokreA11yElement : UIAccessibilityElement
@property(nonatomic) uint64_t nodeId;
@property(nonatomic) BOOL clickable;
@property(nonatomic) BOOL focusable;
@end

@interface NokreView : UIView <UITextInput, UIScrollViewDelegate, UIGestureRecognizerDelegate> {
  @public
    nokre_shell_config config;
    nokre_a11y_fill_fn a11yFill;
    void *a11yFillCtx;
    nokre_a11y_action_fn a11yAction;
    void *a11yActionCtx;
    NSMutableString *markedText;
    NSRange selectedRange;
    NSArray *a11yCache;
    UIScrollView *scrollFeeder;
    // The raw-stream recognizer, gated per touch by wants_pointer_stream.
    UILongPressGestureRecognizer *pressDrag;
    CGPoint feederLastOffset;
    CGPoint scrollAnchor;
    CGFloat scrollCarryX;
    CGFloat scrollCarryY;
}
@property(nonatomic, weak) id<UITextInputDelegate> inputDelegate;
// UITextInputTraits is an informal protocol: the properties only exist
// if the adopter declares them.
@property(nonatomic) UITextAutocorrectionType autocorrectionType;
@property(nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property(nonatomic) UITextSpellCheckingType spellCheckingType;
@property(nonatomic) UITextSmartQuotesType smartQuotesType;
@property(nonatomic) UITextSmartDashesType smartDashesType;
@property(nonatomic) UITextSmartInsertDeleteType smartInsertDeleteType;
- (void)a11yPerform:(uint64_t)nodeId action:(int32_t)action;
- (void)prewarmKeyboard;
- (void)prewarmHaptics;
@end

@implementation NokreA11yElement

- (BOOL)accessibilityActivate {
    NokreView *view = (NokreView *)self.accessibilityContainer;
    if (self.clickable) {
        [view a11yPerform:self.nodeId action:NOKRE_A11Y_ACTION_CLICK];
        return YES;
    }
    if (self.focusable) {
        [view a11yPerform:self.nodeId action:NOKRE_A11Y_ACTION_FOCUS];
        return YES;
    }
    return NO;
}

// Keep nokre's focus ring under the VoiceOver cursor, matching what
// AccessKit does for the macOS shell.
- (void)accessibilityElementDidBecomeFocused {
    if (self.focusable) {
        NokreView *view = (NokreView *)self.accessibilityContainer;
        [view a11yPerform:self.nodeId action:NOKRE_A11Y_ACTION_FOCUS];
    }
}

@end

// Feeder content span: large enough that no realistic flick sequence
// reaches an edge before an idle moment lets recentering run, small
// enough that CGFloat keeps sub-point offset precision.
static const CGFloat kFeederSpan = 4000000;

// The back gesture's knock (docs/internals/haptics.md). Rigid is the
// sharpest of the impact styles — a knock, not a thud. One generator
// for the process: it is a handle on a system resource, not shell state,
// and the alternative is a fresh cold generator at every crossing.
static UIImpactFeedbackGenerator *nokreKnockGenerator(void) {
    static UIImpactFeedbackGenerator *generator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
    });
    return generator;
}

// Warming the system services nokre uses lazily (see prewarmKeyboard).
// None of it can leave the main thread — every object involved is a UIKit
// object, and there is no background variant of loading the keyboard — so
// the cost cannot be removed, only spent where nothing is waiting for the
// thread. `kCFRunLoopBeforeWaiting` is exactly that moment: the queue has
// drained and the runloop is about to sleep. nokre paints on demand and
// runs no ticker, so unlike a game loop it genuinely reaches sleep, and
// reaches it early — the first frame is up and launch work is done.
//
// Default mode only, never the common modes: a warm-up that landed inside
// touch tracking would stall the very gesture it exists to smooth. And one
// service per visit, so neither block is long enough to swallow a touch
// that arrives while it runs.
static void nokrePrewarmVisit(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    (void)activity;
    NokreView *view = (__bridge NokreView *)info;
    static int step = 0;
    if (step++ == 0) {
        [view prewarmKeyboard];
        return;
    }
    [view prewarmHaptics];
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, kCFRunLoopDefaultMode);
    CFRelease(observer);
}

// Unretained context: the single scene's view outlives the two visits it
// takes to retire the observer.
static void nokreSchedulePrewarm(NokreView *view) {
    CFRunLoopObserverContext ctx = {0, (__bridge void *)view, NULL, NULL, NULL};
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(
        kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0, nokrePrewarmVisit, &ctx);
    if (observer == NULL) return;
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopDefaultMode);
}

@implementation NokreView

@synthesize markedTextStyle;
@synthesize tokenizer = _tokenizer;

- (instancetype)initWithFrame:(CGRect)frame config:(const nokre_shell_config *)cfg {
    self = [super initWithFrame:frame];
    if (self) {
        config = *cfg;
        markedText = [[NSMutableString alloc] init];
        selectedRange = NSMakeRange(0, 0);
        self.opaque = YES;
        _tokenizer = [[UITextInputStringTokenizer alloc] initWithTextInput:self];

        // The keyboard gets no document context (see above), so every
        // "smart" mutation must be off or typing stops being faithful.
        self.autocorrectionType = UITextAutocorrectionTypeNo;
        self.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.spellCheckingType = UITextSpellCheckingTypeNo;
        self.smartQuotesType = UITextSmartQuotesTypeNo;
        self.smartDashesType = UITextSmartDashesTypeNo;
        self.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];

        // The raw pointer stream, for the rare control that needs a press
        // and its release as separate events (`wants_pointer_stream`).
        // A long press with no minimum duration is a *continuous*
        // recognizer that begins immediately: began/changed/ended/
        // cancelled is the stream verbatim, with no tap detection to
        // reimplement and nothing to renegotiate with the feeder.
        //
        // It is gated in gestureRecognizerShouldBegin: to the points core
        // says yes for, so everywhere else it never begins and the tap
        // above runs exactly as it always has — no added latency, no
        // second code path reaching ordinary controls.
        pressDrag = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                  action:@selector(handlePressDrag:)];
        pressDrag.minimumPressDuration = 0;
        pressDrag.delegate = self;
        [self addGestureRecognizer:pressDrag];
        // When it does begin, it owns the touch: the tap must not also
        // fire on release. The feeder is told the same below, once it
        // exists — the construction the edge pan uses.
        [tap requireGestureRecognizerToFail:pressDrag];

        // Native scroll feel without native content: a hidden UIScrollView
        // is the scroll engine. Its pan gesture is transplanted onto this
        // view; UIKit runs the drag/deceleration physics against a vast
        // empty content area, and the resulting contentOffset deltas are
        // forwarded to core, which owns clamping and routing (the scroll
        // chain — a single scroll view cannot model core's per-region
        // extents, so edge bounce is deliberately absent, matching the
        // macOS shell). The offset starts centered; extents are
        // unreachable in practice, and idle recentering keeps it there.
        scrollFeeder = [[UIScrollView alloc] initWithFrame:CGRectZero];
        scrollFeeder.hidden = YES;
        scrollFeeder.contentSize = CGSizeMake(kFeederSpan, kFeederSpan);
        scrollFeeder.contentOffset = CGPointMake(kFeederSpan / 2, kFeederSpan / 2);
        feederLastOffset = scrollFeeder.contentOffset;
        // The delegate attaches only after the offset is centered so the
        // initial jump never reaches core as a scroll.
        scrollFeeder.delegate = self;
        // Safe-area inset adjustments would move the offset outside any
        // gesture; disabled so every delta is user motion.
        scrollFeeder.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        // A status-bar tap would teleport the offset to the top of the
        // feeder area and arrive as one enormous delta.
        scrollFeeder.scrollsToTop = NO;
        scrollFeeder.directionalLockEnabled = YES;
        // iPad trackpads and mice scroll through the same feeder, so
        // they get the same momentum the macOS shell gets from AppKit.
        scrollFeeder.panGestureRecognizer.allowedScrollTypesMask = UIScrollTypeMaskAll;
        [self addSubview:scrollFeeder];
        [self addGestureRecognizer:scrollFeeder.panGestureRecognizer];
        // A press core claimed must not also scroll: the chip lives in
        // fixed bottom chrome with nothing scrollable beneath it, so a
        // drag from it is a menu drag and nothing else.
        [scrollFeeder.panGestureRecognizer requireGestureRecognizerToFail:pressDrag];

        // The back gesture: a drag in from a screen edge. Both edges are
        // recognized and core decides which one means back (the leading
        // one, mirrored with the chrome) — a shell knows where a finger
        // landed and nothing about reading direction.
        //
        // Nothing here animates. Core answers with a haptic knock at its
        // threshold and the Back control drawing engaged; there is no
        // partially-slid screen, which is why this needs no transition
        // coordinator and no interactive-transition machinery.
        for (NSNumber *edge in @[ @(UIRectEdgeLeft), @(UIRectEdgeRight) ]) {
            UIScreenEdgePanGestureRecognizer *pan =
                [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self
                                                                  action:@selector(handleEdgePan:)];
            pan.edges = (UIRectEdge)edge.unsignedIntegerValue;
            [self addGestureRecognizer:pan];
            // Without this an inward drag from the edge scrolls *and*
            // pans: the feeder's transplanted pan would claim the same
            // touch, and the screen would move under a gesture that is
            // supposed to move nothing.
            [scrollFeeder.panGestureRecognizer requireGestureRecognizerToFail:pan];
        }
    }
    return self;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        self.contentScaleFactor = self.window.screen.scale;
        [self setNeedsDisplay];
    }
}

- (void)maybeRepaint {
    if (config.wants_frame(config.ctx)) {
        [self setNeedsDisplay];
    }
}

// First responder follows the focused element: NokreView (keyboard up)
// while editing, the view controller (hardware keys only) otherwise.
- (void)syncKeyboard {
    BOOL wants = config.wants_text_input(config.ctx) != 0;
    if (wants && !self.isFirstResponder) {
        [self becomeFirstResponder];
    } else if (!wants && self.isFirstResponder) {
        [self resignFirstResponder];
        [self.window.rootViewController becomeFirstResponder];
    }
}

- (void)inputChanged {
    [self syncKeyboard];
    [self maybeRepaint];
}

// First use of a UIKit system service costs far more than every later
// use, and the cost is paid on the main thread. The keyboard stack loads
// on the first `becomeFirstResponder` of the process — implementation,
// input-mode list, and the layout bundle for the active mode. A framework
// with transitions hides that behind an animation; nokre has nothing to
// hide it behind, so the freeze is the whole experience: the frame that
// should show the caret simply waits. Paid once at an idle moment
// instead (nokreSchedulePrewarm).
//
// The warm-up goes through the real text input rather than a throwaway
// field, so the mode that loads is the one with nokre's traits (every
// "smart" behavior off, see init): UIKit builds the stack on the way in
// and abandons the unstarted show animation on the way out, so no
// keyboard ever appears. Nothing here reaches core — with no editing
// session the UITextInput surface is an empty document, and the keyboard
// only reads it.
- (void)prewarmKeyboard {
    // An app that boots straight into a focused field is already warming
    // the keyboard for real; stepping on that would resign it.
    if (config.wants_text_input(config.ctx) != 0) return;
    [self becomeFirstResponder];
    [self resignFirstResponder];
    [self.window.rootViewController becomeFirstResponder];
}

// Not a substitute for the pan-begin `prepare` (see handleEdgePan): that
// one wakes an idle Taptic Engine, this one pays for the framework and its
// daemon connection, and the engine goes back to idle long before the
// first gesture.
- (void)prewarmHaptics {
    [nokreKnockGenerator() prepare];
}

- (void)reportAppearance {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    config.on_appearance(config.ctx, dark ? 1 : 0);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self reportAppearance];
    [self maybeRepaint];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    scrollFeeder.frame = self.bounds;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)dirtyRect {
    int32_t scale = (int32_t)lround(self.contentScaleFactor);
    if (scale < 1) scale = 1;
    int32_t logical_w = (int32_t)lround(self.bounds.size.width);
    int32_t logical_h = (int32_t)lround(self.bounds.size.height);
    if (logical_w < 1 || logical_h < 1) return;
    // The view underlaps the home-indicator band (see
    // viewDidLayoutSubviews); report its height so layout stays clear
    // of it while pane fills paint through it.
    int32_t safe_bottom = (int32_t)lround(self.safeAreaInsets.bottom);
    int32_t w = 0, h = 0;
    const uint8_t *pixels = config.on_frame(config.ctx, logical_w, logical_h, safe_bottom, scale, &w, &h);
    if (!pixels || w <= 0 || h <= 0) return;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(NULL, pixels, (size_t)w * (size_t)h * 4, NULL);
    // RGBX: 32 bpp, the padding byte after B skipped, per shell.h.
    CGImageRef image = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, space,
                                     kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGContextRef cg = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
    // UIKit's context is flipped for top-left origin; un-flip for
    // CGContextDrawImage.
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

// A touch during a fling stops the fling, like a real scroll view — and
// must not also activate whatever it happens to land on. The tap is
// refused at touch delivery, before any recognizer can halt the scroll
// view and erase the evidence. The feeder's pan keeps its own delegate.
//
// The press-drag recognizer is exempt, and the asymmetry is the point:
// that refusal exists because a finger stopping a fling landed on
// whatever the content had drifted under it, which is nobody's choice.
// Core only claims fixed chrome with nothing scrollable beneath it
// (`wants_pointer_stream`), so a touch there never was a stop-the-scroll
// touch — the chip does not move, and it is where the user aimed.
// Refusing it would leave the one control that opens on the press dead
// for as long as a fling anywhere on screen happened to still be
// running. The fling still stops: `touchesBegan` below halts the feeder
// for every touch, whatever any recognizer decides afterwards.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == pressDrag) return YES;
    return !scrollFeeder.decelerating;
}

// The gate. Core is asked, once per touch, whether whatever is under it
// needs the raw stream; everywhere else this recognizer never begins and
// the tap recognizer's behavior is untouched. With minimumPressDuration
// of 0 a refusal costs nothing — there is no delay to fail out of.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != pressDrag) return YES;
    CGPoint p = [gestureRecognizer locationInView:self];
    return config.wants_pointer_stream(config.ctx, (int32_t)p.x, (int32_t)p.y) != 0;
}

- (void)handlePressDrag:(UILongPressGestureRecognizer *)gesture {
    CGPoint p = [gesture locationInView:self];
    int32_t phase;
    switch (gesture.state) {
    case UIGestureRecognizerStateBegan:
        phase = NOKRE_POINTER_DOWN;
        break;
    case UIGestureRecognizerStateChanged:
        phase = NOKRE_POINTER_MOVE;
        break;
    case UIGestureRecognizerStateEnded:
        phase = NOKRE_POINTER_UP;
        break;
    // Failed and cancelled both mean the gesture is over without a
    // release the user made: whatever it opened closes, choosing nothing.
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        phase = NOKRE_POINTER_CANCEL;
        break;
    default:
        return;
    }
    config.on_pointer(config.ctx, (int32_t)p.x, (int32_t)p.y, phase);
    [self inputChanged];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (scrollFeeder.decelerating) {
        [scrollFeeder setContentOffset:scrollFeeder.contentOffset animated:NO];
        // A manual halt skips scrollViewDidEndDecelerating, so the
        // gesture must be closed here or the lock would leak into
        // whatever scrolls next.
        [self endScrollGesture];
    }
    [super touchesBegan:touches withEvent:event];
}

// The recognizer owns tap detection for everything core did not claim,
// and a recognized tap is a press and a release at one point. The raw
// stream is `handlePressDrag:` above, reached only where
// `wants_pointer_stream` said so — which is why this path, the feeder,
// and the fling refusal all keep working exactly as they did.
- (void)handleTap:(UITapGestureRecognizer *)gesture {
    CGPoint p = [gesture locationInView:self];
    config.on_pointer(config.ctx, (int32_t)p.x, (int32_t)p.y, NOKRE_POINTER_DOWN);
    config.on_pointer(config.ctx, (int32_t)p.x, (int32_t)p.y, NOKRE_POINTER_UP);
    [self inputChanged];
}

// ---- the back gesture (see init) ----

- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture {
    int32_t phase;
    switch (gesture.state) {
    case UIGestureRecognizerStateBegan:
        phase = NOKRE_PAN_BEGIN;
        // The Taptic Engine idles, and a generator asked cold can miss
        // the moment by enough to feel late. A pan beginning is the only
        // thing that ever leads to a knock, so this is where it wakes.
        [nokreKnockGenerator() prepare];
        break;
    case UIGestureRecognizerStateChanged:
        phase = NOKRE_PAN_MOVE;
        break;
    case UIGestureRecognizerStateEnded:
        phase = NOKRE_PAN_END;
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        phase = NOKRE_PAN_CANCEL;
        break;
    default:
        return;
    }
    int32_t from = (gesture.edges & UIRectEdgeRight) ? NOKRE_EDGE_RIGHT : NOKRE_EDGE_LEFT;
    // Distance travelled *inward*, whichever edge that is, and never
    // negative: a finger that drags back past where it started is a
    // gesture at zero, not one running backwards.
    CGFloat inward = [gesture translationInView:self].x;
    if (from == NOKRE_EDGE_RIGHT) inward = -inward;
    config.on_edge_pan(config.ctx, from, inward > 0 ? (int32_t)inward : 0, phase);
    [self inputChanged];
}

// ---- scroll (fed by the hidden UIScrollView; see init) ----

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    // The region under the initial touch owns the whole gesture,
    // momentum included — iOS semantics, and stronger than the macOS
    // wheel path, which re-routes every event at the cursor. BEGIN
    // locks core's routing to the scrollers under the anchor until
    // the matching END; the anchor alone would not survive the drag
    // leaving the region or the region running out of content.
    scrollAnchor = [scrollView.panGestureRecognizer locationInView:self];
    config.on_scroll(config.ctx, (int32_t)scrollAnchor.x, (int32_t)scrollAnchor.y, 0, 0,
                     NOKRE_SCROLL_BEGIN);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Content follows the finger: a finger moving up raises the feeder
    // offset, and a positive delta scrolls the content down — the same
    // sign convention as the macOS scroll wheel path. Offsets move in
    // sub-point steps, so the integer remainder carries over rather
    // than truncating away slow drags.
    CGFloat fx = scrollView.contentOffset.x - feederLastOffset.x + scrollCarryX;
    CGFloat fy = scrollView.contentOffset.y - feederLastOffset.y + scrollCarryY;
    feederLastOffset = scrollView.contentOffset;
    int32_t dx = (int32_t)fx;
    int32_t dy = (int32_t)fy;
    scrollCarryX = fx - (CGFloat)dx;
    scrollCarryY = fy - (CGFloat)dy;
    if (dx != 0 || dy != 0) {
        config.on_scroll(config.ctx, (int32_t)scrollAnchor.x, (int32_t)scrollAnchor.y, dx, dy,
                         NOKRE_SCROLL_MOVE);
        [self maybeRepaint];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self endScrollGesture];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self endScrollGesture];
}

- (void)endScrollGesture {
    config.on_scroll(config.ctx, (int32_t)scrollAnchor.x, (int32_t)scrollAnchor.y, 0, 0,
                     NOKRE_SCROLL_END);
    [self recenterFeeder];
}

- (void)recenterFeeder {
    if (scrollFeeder.dragging || scrollFeeder.decelerating) return;
    CGPoint off = scrollFeeder.contentOffset;
    if (fabs(off.x - kFeederSpan / 2) < kFeederSpan / 4 &&
        fabs(off.y - kFeederSpan / 2) < kFeederSpan / 4) {
        return;
    }
    // Pre-setting the bookkeeping makes the synchronous
    // scrollViewDidScroll from this assignment compute a zero delta.
    scrollCarryX = 0;
    scrollCarryY = 0;
    feederLastOffset = CGPointMake(kFeederSpan / 2, kFeederSpan / 2);
    scrollFeeder.contentOffset = feederLastOffset;
}

// ---- hardware keyboard ----

uint8_t nokre_mods_from_flags(UIKeyModifierFlags flags) {
    uint8_t mods = 0;
    if (flags & UIKeyModifierShift) mods |= NOKRE_MOD_SHIFT;
    if (flags & UIKeyModifierControl) mods |= NOKRE_MOD_CTRL;
    if (flags & UIKeyModifierAlternate) mods |= NOKRE_MOD_ALT;
    if (flags & UIKeyModifierCommand) mods |= NOKRE_MOD_META;
    return mods;
}

int32_t nokre_key_from_press(UIPress *press) {
    if (press.key == nil) return 0;
    switch (press.key.keyCode) {
        case UIKeyboardHIDUsageKeyboardTab: return NOKRE_KEY_TAB;
        case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        case UIKeyboardHIDUsageKeypadEnter: return NOKRE_KEY_ENTER;
        case UIKeyboardHIDUsageKeyboardSpacebar: return NOKRE_KEY_SPACE;
        case UIKeyboardHIDUsageKeyboardEscape: return NOKRE_KEY_ESCAPE;
        case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return NOKRE_KEY_BACKSPACE;
        case UIKeyboardHIDUsageKeyboardDeleteForward: return NOKRE_KEY_DELETE;
        case UIKeyboardHIDUsageKeyboardLeftArrow: return NOKRE_KEY_LEFT;
        case UIKeyboardHIDUsageKeyboardRightArrow: return NOKRE_KEY_RIGHT;
        case UIKeyboardHIDUsageKeyboardUpArrow: return NOKRE_KEY_UP;
        case UIKeyboardHIDUsageKeyboardDownArrow: return NOKRE_KEY_DOWN;
        case UIKeyboardHIDUsageKeyboardHome: return NOKRE_KEY_HOME;
        case UIKeyboardHIDUsageKeyboardEnd: return NOKRE_KEY_END;
        case UIKeyboardHIDUsageKeyboardPageUp: return NOKRE_KEY_PAGE_UP;
        case UIKeyboardHIDUsageKeyboardPageDown: return NOKRE_KEY_PAGE_DOWN;
        default: return 0;
    }
}

// While editing, only the keys the text system won't turn into
// insertText/deleteBackward are taken here; the rest must fall through
// or every space would arrive twice.
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses) {
        int32_t key = nokre_key_from_press(press);
        switch (key) {
            case NOKRE_KEY_TAB:
            case NOKRE_KEY_ESCAPE:
            case NOKRE_KEY_LEFT:
            case NOKRE_KEY_RIGHT:
            case NOKRE_KEY_UP:
            case NOKRE_KEY_DOWN:
            case NOKRE_KEY_HOME:
            case NOKRE_KEY_END:
            case NOKRE_KEY_PAGE_UP:
            case NOKRE_KEY_PAGE_DOWN:
                // Composition-phase control keys belong to the IME.
                if (markedText.length > 0) break;
                config.on_key(config.ctx, key, nokre_mods_from_flags(press.key.modifierFlags));
                handled = YES;
                break;
            default:
                break;
        }
    }
    if (handled) {
        [self inputChanged];
    } else {
        [super pressesBegan:presses withEvent:event];
    }
}

// ---- UIKeyInput ----

- (BOOL)hasText {
    // The keyboard uses this only to decide whether delete is
    // meaningful; core knows the truth, so never starve the key.
    return YES;
}

- (void)insertText:(NSString *)text {
    if (markedText.length > 0) {
        [markedText setString:@""];
        const char *utf8 = text.UTF8String;
        config.on_ime_commit(config.ctx, utf8, strlen(utf8));
    } else if ([text isEqualToString:@"\n"]) {
        // The software keyboard's return key arrives as text.
        config.on_key(config.ctx, NOKRE_KEY_ENTER, 0);
    } else {
        const char *utf8 = text.UTF8String;
        config.on_text(config.ctx, utf8, strlen(utf8));
    }
    [self inputChanged];
}

- (void)deleteBackward {
    config.on_key(config.ctx, NOKRE_KEY_BACKSPACE, 0);
    [self inputChanged];
}

// ---- UITextInput (IME composition; the document is the marked text) ----

- (NSString *)textInRange:(UITextRange *)range {
    NSRange r = NSIntersectionRange(((NokreTextRange *)range).range,
                                    NSMakeRange(0, markedText.length));
    return [markedText substringWithRange:r];
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    [self insertText:text];
}

- (UITextRange *)selectedTextRange {
    return [NokreTextRange range:selectedRange];
}

- (void)setSelectedTextRange:(UITextRange *)range {
    selectedRange = NSIntersectionRange(((NokreTextRange *)range).range,
                                        NSMakeRange(0, markedText.length));
}

- (UITextRange *)markedTextRange {
    return markedText.length > 0 ? [NokreTextRange range:NSMakeRange(0, markedText.length)] : nil;
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

- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)range {
    NSString *s = text ?: @"";
    if (s.length == 0 && markedText.length > 0) {
        [markedText setString:@""];
        selectedRange = NSMakeRange(0, 0);
        config.on_ime_cancel(config.ctx);
    } else {
        [markedText setString:s];
        selectedRange = NSIntersectionRange(range, NSMakeRange(0, s.length));
        const char *utf8 = s.UTF8String;
        size_t len = strlen(utf8);
        config.on_ime_update(config.ctx, utf8, len, nokre_caret_utf8(s, range.location, len));
    }
    [self inputChanged];
}

- (void)unmarkText {
    // UITextInput semantics: unmark commits — the macOS shell's
    // unmarkText follows the same rule under NSTextInputClient.
    if (markedText.length > 0) {
        const char *utf8 = markedText.UTF8String;
        config.on_ime_commit(config.ctx, utf8, strlen(utf8));
        [markedText setString:@""];
        selectedRange = NSMakeRange(0, 0);
        [self inputChanged];
    }
}

- (UITextPosition *)beginningOfDocument {
    return [NokreTextPosition position:0];
}

- (UITextPosition *)endOfDocument {
    return [NokreTextPosition position:(NSInteger)markedText.length];
}

- (NSInteger)clampIndex:(NSInteger)index {
    if (index < 0) return 0;
    if (index > (NSInteger)markedText.length) return (NSInteger)markedText.length;
    return index;
}

- (UITextRange *)textRangeFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)to {
    NSInteger a = ((NokreTextPosition *)from).index;
    NSInteger b = ((NokreTextPosition *)to).index;
    if (a > b) {
        NSInteger t = a;
        a = b;
        b = t;
    }
    return [NokreTextRange range:NSMakeRange((NSUInteger)a, (NSUInteger)(b - a))];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position offset:(NSInteger)offset {
    return [NokreTextPosition position:[self clampIndex:((NokreTextPosition *)position).index + offset]];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position
                             inDirection:(UITextLayoutDirection)direction
                                  offset:(NSInteger)offset {
    NSInteger delta = direction == UITextLayoutDirectionLeft ? -offset : offset;
    return [self positionFromPosition:position offset:delta];
}

- (NSComparisonResult)comparePosition:(UITextPosition *)position toPosition:(UITextPosition *)other {
    NSInteger a = ((NokreTextPosition *)position).index;
    NSInteger b = ((NokreTextPosition *)other).index;
    if (a < b) return NSOrderedAscending;
    if (a > b) return NSOrderedDescending;
    return NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)to {
    return ((NokreTextPosition *)to).index - ((NokreTextPosition *)from).index;
}

- (UITextPosition *)positionWithinRange:(UITextRange *)range
                    farthestInDirection:(UITextLayoutDirection)direction {
    return direction == UITextLayoutDirectionLeft ? range.start : range.end;
}

- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)position
                                       inDirection:(UITextLayoutDirection)direction {
    NSInteger i = ((NokreTextPosition *)position).index;
    if (direction == UITextLayoutDirectionLeft) {
        return [self textRangeFromPosition:[NokreTextPosition position:[self clampIndex:i - 1]]
                                toPosition:position];
    }
    return [self textRangeFromPosition:position
                            toPosition:[NokreTextPosition position:[self clampIndex:i + 1]]];
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)position
                                          inDirection:(UITextStorageDirection)direction {
    return NSWritingDirectionNatural;
}

- (void)setBaseWritingDirection:(NSWritingDirection)direction forRange:(UITextRange *)range {
}

- (CGRect)firstRectForRange:(UITextRange *)range {
    // TODO(ime): report the focused text input's caret rect so the
    // candidate bar can dock next to it (same gap as the macOS shell).
    return CGRectZero;
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    return CGRectZero;
}

- (NSArray<UITextSelectionRect *> *)selectionRectsForRange:(UITextRange *)range {
    return @[];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    return [NokreTextPosition position:0];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range {
    return range.start;
}

- (UITextRange *)characterRangeAtPoint:(CGPoint)point {
    return nil;
}

// ---- accessibility (semantic snapshot → UIAccessibility) ----

- (void)a11yPerform:(uint64_t)nodeId action:(int32_t)action {
    if (a11yAction == NULL) return;
    a11yAction(a11yActionCtx, nodeId, action);
    [self syncKeyboard];
}

- (BOOL)isAccessibilityElement {
    return NO;
}

- (NSArray *)accessibilityElements {
    if (a11yFill == NULL) return nil;
    if (a11yCache != nil) return a11yCache;

    size_t count = 0;
    uint64_t focus_id = 0;
    const nokre_a11y_node *nodes = a11yFill(a11yFillCtx, &count, &focus_id);
    if (nodes == NULL) return nil;

    // A modal overlay makes everything outside it inert; mirror that by
    // exposing only the topmost modal's subtree, like the core input
    // path and the AccessKit adapter both do.
    size_t modal = SIZE_MAX;
    for (size_t i = 0; i < count; i++) {
        if (nodes[i].modal) modal = i;
    }

    NSMutableArray *elements = [NSMutableArray array];
    for (size_t i = 0; i < count; i++) {
        const nokre_a11y_node *n = &nodes[i];
        if (n->role == NOKRE_A11Y_ROLE_DOCUMENT) continue;
        if (!n->focusable && !n->clickable && n->label_len == 0 && n->value_len == 0) continue;
        if (modal != SIZE_MAX) {
            size_t p = i;
            while (p != SIZE_MAX && p != modal) p = nodes[p].parent;
            if (p != modal) continue;
        }

        NokreA11yElement *el = [[NokreA11yElement alloc] initWithAccessibilityContainer:self];
        el.nodeId = n->id;
        el.clickable = n->clickable != 0;
        el.focusable = n->focusable != 0;
        if (n->label_len > 0) {
            el.accessibilityLabel = [[NSString alloc] initWithBytes:n->label
                                                             length:n->label_len
                                                           encoding:NSUTF8StringEncoding];
        }
        if (n->value_len > 0) {
            el.accessibilityValue = [[NSString alloc] initWithBytes:n->value
                                                             length:n->value_len
                                                           encoding:NSUTF8StringEncoding];
        } else if (n->checked >= 0) {
            el.accessibilityValue = n->checked == 1 ? @"on" : @"off";
        } else if (n->busy) {
            // UIAccessibility has no busy trait — NotEnabled (set below
            // from disabled) only gets VoiceOver as far as "dimmed",
            // which is not what happened. The value slot is where the
            // shell already spells a state out in words, as it does for
            // on/off, so busy says so there.
            el.accessibilityValue = @"in progress";
        }
        // UIKit has no invalid trait either, and unlike busy there is
        // nothing for the shell to spell out: the app's own words are
        // the statement that the value was refused. The hint is where
        // VoiceOver reads them — after the label and the value, which
        // is the order a reason belongs in.
        if (n->description_len > 0) {
            el.accessibilityHint = [[NSString alloc] initWithBytes:n->description
                                                            length:n->description_len
                                                          encoding:NSUTF8StringEncoding];
        }

        UIAccessibilityTraits traits = UIAccessibilityTraitNone;
        switch (n->role) {
            case NOKRE_A11Y_ROLE_STATIC_TEXT:
            case NOKRE_A11Y_ROLE_STATUS:
            case NOKRE_A11Y_ROLE_CELL: traits |= UIAccessibilityTraitStaticText; break;
            case NOKRE_A11Y_ROLE_HEADING: traits |= UIAccessibilityTraitHeader; break;
            case NOKRE_A11Y_ROLE_BUTTON:
            case NOKRE_A11Y_ROLE_TOGGLE:
            case NOKRE_A11Y_ROLE_CHECKBOX:
            case NOKRE_A11Y_ROLE_OPTION: traits |= UIAccessibilityTraitButton; break;
            case NOKRE_A11Y_ROLE_LINK: traits |= UIAccessibilityTraitLink; break;
            case NOKRE_A11Y_ROLE_IMAGE: traits |= UIAccessibilityTraitImage; break;
            default: break;
        }
        if (n->disabled) traits |= UIAccessibilityTraitNotEnabled;
        if (n->selected == 1) traits |= UIAccessibilityTraitSelected;
        el.accessibilityTraits = traits;
        el.accessibilityFrameInContainerSpace = CGRectMake(n->x, n->y, n->w, n->h);
        [elements addObject:el];
    }
    a11yCache = elements;
    return a11yCache;
}

- (void)a11yInvalidate {
    a11yCache = nil;
    if (UIAccessibilityIsVoiceOverRunning()) {
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
    }
}

@end

// ---- view controller: safe-area layout + non-editing hardware keys ----

@interface NokreViewController : UIViewController {
  @public
    NokreView *nokreView;
}
@end

@implementation NokreViewController

- (void)loadView {
    self.view = [[UIView alloc] init];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    nokreView = [[NokreView alloc] initWithFrame:CGRectZero config:&g_config];
    [self.view addSubview:nokreView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Integral frame: fractional sizes would resample the blit and break
    // the pixel guarantee. Top and sides respect the safe area; the
    // bottom runs to the physical edge — nokre owns the home-indicator
    // band and keeps content out of it via safe_bottom (on_frame).
    CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
    CGFloat top = ceil(safe.origin.y);
    nokreView.frame = CGRectMake(ceil(safe.origin.x), top,
                               floor(safe.size.width),
                               floor(CGRectGetMaxY(self.view.bounds) - top));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
    // Once per process: this controller is the single scene's, and a second
    // observer would warm what is already warm.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      nokreSchedulePrewarm(nokreView);
    });
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    // While editing, NokreView is first responder and owns key handling.
    if (nokreView.isFirstResponder) {
        [super pressesBegan:presses withEvent:event];
        return;
    }
    BOOL handled = NO;
    for (UIPress *press in presses) {
        int32_t key = nokre_key_from_press(press);
        if (key != 0) {
            g_config.on_key(g_config.ctx, key, nokre_mods_from_flags(press.key.modifierFlags));
            handled = YES;
        }
    }
    if (handled) {
        [nokreView inputChanged];
    } else {
        [super pressesBegan:presses withEvent:event];
    }
}

@end

// deep_link service inbound hook (docs/services.md;
// src/services/deep_link/deep_link.h). Single-app anchor like g_config —
// one scene, ever. A Universal Link arrives as a browsing user activity,
// a custom scheme as a URL context; both forward the whole URL to the
// service, which extracts what the app routes on. A URL that arrives
// before the app registers its handler is buffered and flushed on install
// so a cold-launch link is never dropped (on iOS the app is built — and
// setHandler run — before UIApplicationMain, so this is belt-and-braces).
static void *g_deep_link_ctx = NULL;
static nokre_deep_link_cb g_deep_link_cb = NULL;
static NSString *g_deep_link_pending = nil;
// The one view, held for every inbound service hook — not deep_link's
// alone, hence the neutral name.
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
    // The handler routed and invalidated like any action; repaint on the
    // next runloop turn (the on-demand loop, worker-pump rule).
    [g_main_view setNeedsDisplay];
}

void nokre_deep_link_install(void *ctx, nokre_deep_link_cb cb) {
    g_deep_link_ctx = ctx;
    g_deep_link_cb = cb;
    if (g_deep_link_pending != nil) {
        NSString *s = g_deep_link_pending;
        g_deep_link_pending = nil;
        const char *bytes = s.UTF8String;
        cb(ctx, bytes, strlen(bytes));
        [g_main_view setNeedsDisplay];
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
// src/services/locale/locale.h). No pending buffer, unlike deep_link:
// a launch URL can be missed, the device locale never is — it is
// readable on demand, which is exactly what lets the contract promise a
// first fire inside the install call.
//
// preferredLanguages, not [NSLocale currentLocale].localeIdentifier: the
// former is the user's ordered *display language* list and already BCP 47
// with hyphens ("en-US", "zh-Hans-CN"), which is what the app's message
// bundle resolves against; the latter is the *formatting* locale in POSIX
// flavor ("en_US"). nokre's resolve folds case and '-'/'_' either way,
// but locale.h promises a language tag, so hand over the tag. An empty
// list reports the empty tag — Zig turns that into the app's own template
// language; inventing "en" here is not the shell's decision to make.
static void *g_locale_ctx = NULL;
static nokre_locale_cb g_locale_cb = NULL;

static void nokre_locale_dispatch(BOOL repaint) {
    if (g_locale_cb == NULL) return;
    NSString *tag = NSLocale.preferredLanguages.firstObject;
    const char *bytes = tag != nil ? tag.UTF8String : "";
    if (bytes == NULL) bytes = "";
    g_locale_cb(g_locale_ctx, bytes, strlen(bytes));
    if (repaint) {
        // The handler re-resolved its bundle and invalidated like any
        // action; repaint on the next runloop turn (the on-demand loop,
        // worker-pump rule).
        [g_main_view setNeedsDisplay];
    }
}

void nokre_locale_install(void *ctx, nokre_locale_cb cb) {
    g_locale_ctx = ctx;
    g_locale_cb = cb;
    // Synchronously, before returning: install runs inside App.init, and
    // the boot tag must be warm before the first `build` — nokre has no
    // ticker to retire a loading frame an async answer would strand. No
    // frame requested here; the scene has not connected yet, so there is
    // no view to dirty and the boot frame follows anyway.
    nokre_locale_dispatch(NO);
    // iOS normally terminates a backgrounded app when the system
    // language changes, so in practice the boot read is what runs; region
    // and calendar changes do arrive live, and this observer is the cheap
    // correctness backstop for them. mainQueue *is* the marshal the
    // contract's "on the main thread" asks for — no dispatch_async
    // bookkeeping. Registered once: a re-install replaces ctx + cb, and a
    // second observer would double-fire the same callback.
    static BOOL observing = NO;
    if (!observing) {
        observing = YES;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSCurrentLocaleDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                      (void)note;
                      nokre_locale_dispatch(YES);
                    }];
    }
}

void nokre_locale_uninstall(void) {
    // The observer stays (registered once per process); with the
    // callback gone, nokre_locale_dispatch drops the change instead of
    // calling into per-app state the app has already freed.
    g_locale_ctx = NULL;
    g_locale_cb = NULL;
}

// UIScene lifecycle: required by current SDKs (legacy window-on-the-app-
// delegate launches are slated to stop working). One scene, ever — the
// Info.plist manifest declares no multi-scene support, matching the
// framework's single-window charter.
@interface NokreSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation NokreSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    NokreViewController *vc = [[NokreViewController alloc] init];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    NokreView *view = vc->nokreView;
    g_main_view = view;
    g_config.on_ready(g_config.ctx, (__bridge void *)view, "");
    g_config.on_window_focus(g_config.ctx, 1);
    [view reportAppearance];
    [view setNeedsDisplay];

    // deep_link: a link that launched the app arrives in the connection
    // options — a Universal Link as a browsing activity, a custom scheme
    // as a URL context. This is the launch URL, delivered once.
    for (NSUserActivity *activity in connectionOptions.userActivities) {
        if ([activity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] &&
            activity.webpageURL != nil) {
            nokre_deep_link_dispatch(activity.webpageURL);
        }
    }
    for (UIOpenURLContext *urlContext in connectionOptions.URLContexts) {
        nokre_deep_link_dispatch(urlContext.URL);
    }
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    g_config.on_window_focus(g_config.ctx, 1);
}

- (void)sceneWillResignActive:(UIScene *)scene {
    g_config.on_window_focus(g_config.ctx, 0);
}

// deep_link while running: a Universal Link tapped in another app.
- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity {
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] &&
        userActivity.webpageURL != nil) {
        nokre_deep_link_dispatch(userActivity.webpageURL);
    }
}

// deep_link while running: a custom-scheme URL opened into the app.
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *urlContext in URLContexts) {
        nokre_deep_link_dispatch(urlContext.URL);
    }
}

@end

@interface NokreAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation NokreAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    return YES;
}

// The notification service's one line into this shell, and the whole of
// it (docs/internals/notifications.md). Everything else about
// notifications is service-owned in src/services/notification/apple.m,
// because UNUserNotificationCenter's delegate is any object — but an APNs
// token is handed to the *application* delegate by UIKit and nowhere
// else, so it crosses here — into the sink above, which is NULL until the
// service installs one (the shell's zero-services contract).
- (void)application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    if (g_push_token_sink != NULL) {
        g_push_token_sink(deviceToken.bytes, deviceToken.length);
    }
}

- (void)application:(UIApplication *)application
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    // No token, and nothing to report: the service's contract has one
    // token lane and no failure lane, because an app cannot act
    // differently on "APNs is unreachable right now" — it re-registers on
    // the next launch, which UIKit does for it.
    (void)error;
}

// The Info.plist manifest only opts in to scenes; the configuration
// lives here so the shell stays code-only.
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config =
        [[UISceneConfiguration alloc] initWithName:@"nokre"
                                       sessionRole:connectingSceneSession.role];
    config.delegateClass = [NokreSceneDelegate class];
    return config;
}

@end

void nokre_shell_write_clipboard(const char *utf8, size_t len) {
    NSString *text = [[NSString alloc] initWithBytes:utf8
                                              length:len
                                            encoding:NSUTF8StringEncoding];
    if (text == nil) return;
    UIPasteboard.generalPasteboard.string = text;
}

int nokre_open_url_open(const char *url, size_t len) {
    NSString *str = [[NSString alloc] initWithBytes:url
                                             length:len
                                           encoding:NSUTF8StringEncoding];
    NSURL *target = str == nil ? nil : [NSURL URLWithString:str];
    if (target == nil) return 1;
    // The app-switch to Safari (or Mail): the OS animates away and the
    // user comes back through their own multitasking. The outcome
    // arrives only through the async completion handler, so the honest
    // synchronous answer is "the OS was asked" (open_url.h's ceiling) —
    // and nobody on this platform reads more: oauth's browser leg is
    // ASWebAuthenticationSession, not the loopback flow.
    [UIApplication.sharedApplication openURL:target options:@{} completionHandler:nil];
    return 0;
}

void nokre_share_show(const char *text, size_t len) {
    NSString *str = [[NSString alloc] initWithBytes:text
                                             length:len
                                           encoding:NSUTF8StringEncoding];
    NokreView *view = g_main_view;
    UIViewController *vc = view == nil ? nil : view.window.rootViewController;
    if (str == nil || vc == nil) return;
    // Present from whatever is topmost, not the root: the share can be
    // asked for while a system sheet the shell cannot see is already up,
    // and presenting from a covered controller is a silent no-op.
    while (vc.presentedViewController != nil) vc = vc.presentedViewController;
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[ str ]
                                          applicationActivities:nil];
    // iPad shows this as a popover and requires an anchor; the service
    // API carries no geometry (share.h), so center it on the app's one
    // view, arrowless — app-level, not element-anchored. iPhone ignores
    // the popover controller and presents the sheet.
    UIPopoverPresentationController *pop = avc.popoverPresentationController;
    if (pop != nil) {
        pop.sourceView = vc.view;
        pop.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds),
                                    CGRectGetMidY(vc.view.bounds), 1, 1);
        pop.permittedArrowDirections = 0;
    }
    [vc presentViewController:avc animated:YES completion:nil];
}

void nokre_shell_haptic(int32_t kind) {
    // Arming and disarming are opposite events and must not feel
    // identical. The same knock at a lower intensity says "taken back"
    // without inventing a second vocabulary for the finger to learn —
    // and iOS honours the system haptics setting for both, which is the
    // whole opt-out (nokre adds none of its own).
    [nokreKnockGenerator()
        impactOccurredWithIntensity:(kind == NOKRE_HAPTIC_ARMED ? 1.0 : 0.6)];
}

void nokre_shell_request_frame(void *view) {
    NokreView *v = (__bridge NokreView *)view;
    dispatch_async(dispatch_get_main_queue(), ^{
      [v setNeedsDisplay];
      [v syncKeyboard];
    });
}

void *nokre_a11y_ios_attach(void *view, nokre_a11y_fill_fn fill, void *fill_ctx,
                          nokre_a11y_action_fn action, void *action_ctx) {
    NokreView *v = (__bridge NokreView *)view;
    v->a11yFill = fill;
    v->a11yFillCtx = fill_ctx;
    v->a11yAction = action;
    v->a11yActionCtx = action_ctx;
    return view;
}

void nokre_a11y_ios_update(void *adapter) {
    NokreView *v = (__bridge NokreView *)adapter;
    dispatch_async(dispatch_get_main_queue(), ^{
      [v a11yInvalidate];
    });
}

int32_t nokre_shell_run(const nokre_shell_config *config) {
    g_config = *config;
    // The real argc/argv stayed with the Zig entry; UIKit only reads
    // them for legacy launch options.
    static char *argv[] = {"nokre", 0};
    @autoreleasepool {
        // Never returns; iOS owns process exit.
        return UIApplicationMain(1, argv, nil, NSStringFromClass([NokreAppDelegate class]));
    }
}
