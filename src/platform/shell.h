// C contract between a native shell (macos/shell.m, ios/shell.m,
// windows/shell.c) and its Zig side (src/platform/c_shell.zig). Kept
// intentionally tiny: surface out, events in.
#ifndef NOKRE_SHELL_H
#define NOKRE_SHELL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Key protocol shared by all shells; mirrors src/core/event.zig Key.
enum {
    NOKRE_KEY_TAB = 1,
    NOKRE_KEY_ENTER = 2,
    NOKRE_KEY_SPACE = 3,
    NOKRE_KEY_ESCAPE = 4,
    NOKRE_KEY_BACKSPACE = 5,
    NOKRE_KEY_DELETE = 6,
    NOKRE_KEY_LEFT = 7,
    NOKRE_KEY_RIGHT = 8,
    NOKRE_KEY_UP = 9,
    NOKRE_KEY_DOWN = 10,
    NOKRE_KEY_HOME = 11,
    NOKRE_KEY_END = 12,
    NOKRE_KEY_PAGE_UP = 13,
    NOKRE_KEY_PAGE_DOWN = 14,
};

// Modifier bits; mirrors src/core/event.zig Modifiers.
enum {
    NOKRE_MOD_SHIFT = 1 << 0,
    NOKRE_MOD_CTRL = 1 << 1,
    NOKRE_MOD_ALT = 1 << 2,
    NOKRE_MOD_META = 1 << 3,
};

// Scroll phases; mirrors src/core/event.zig ScrollPhase. Wheel shells
// pass FREE with every event; touch shells bracket a drag: BEGIN locks
// core's routing to the scrollers under (x, y) for the whole gesture,
// MOVE carries the deltas, END (finger up, momentum spent) releases.
enum {
    NOKRE_SCROLL_FREE = 0,
    NOKRE_SCROLL_BEGIN = 1,
    NOKRE_SCROLL_MOVE = 2,
    NOKRE_SCROLL_END = 3,
};

// Pointer phases; mirrors src/core/event.zig Pointer.Phase. Nothing
// activates on DOWN: core records the press, and UP decides — landing
// where the press landed activates, landing anywhere else abandons it
// (WCAG 2.5.2). CANCEL is not UP, for the same reason it is not END
// below: a recognizer taken away mid-press, or a window losing capture,
// must never activate what the user did not finish pressing.
//
// MOVE is reported only between a DOWN and its UP, and core uses it for
// exactly one thing: moving focus inside a menu the press already
// opened. Shells send it; they do not interpret it.
enum {
    NOKRE_POINTER_DOWN = 0,
    NOKRE_POINTER_MOVE = 1,
    NOKRE_POINTER_UP = 2,
    NOKRE_POINTER_CANCEL = 3,
};

// Edge-pan phases and edges; mirrors src/core/event.zig EdgePan. CANCEL
// is not END: the system can take a recognizer away mid-drag, and that
// must never commit a navigation the user did not finish.
enum {
    NOKRE_EDGE_LEFT = 0,
    NOKRE_EDGE_RIGHT = 1,
};
enum {
    NOKRE_PAN_BEGIN = 0,
    NOKRE_PAN_MOVE = 1,
    NOKRE_PAN_END = 2,
    NOKRE_PAN_CANCEL = 3,
};

// The two ends of the back gesture's commit threshold; mirrors
// src/core/haptic.zig's `Knock`, which pins the same two values. The
// only argument nokre passes a shell that used to travel as a bare
// number.
enum {
    NOKRE_HAPTIC_ARMED = 0,
    NOKRE_HAPTIC_DISARMED = 1,
};

typedef struct nokre_shell_config {
    int32_t logical_w;
    int32_t logical_h;
    const char *title; // NUL-terminated UTF-8
    // The desktop-entry basename (the reverse-DNS packaging id), or NULL
    // when the app declared no identity. Consumed only by the Linux
    // shell, as the Wayland xdg_toplevel app_id — the key compositors
    // match against `<app_id>.desktop` for the icon, grouping, and the
    // deep-link handler registration. NULL means set no app_id at all: a
    // wrong id breaks the association worse than none. Other shells
    // ignore it — their platforms take identity from the bundle or
    // package, never from the window.
    const char *app_id; // NUL-terminated UTF-8, or NULL
    void *ctx;

    // Asks Zig for the current frame at the view's current logical size.
    // Returns a tightly packed RGBX8888 buffer (4 bytes per pixel: R, G,
    // B, then a padding byte the shell must ignore) of logical size *
    // scale, valid until the next callback. RGB and not gray8 because
    // the renderer's vendor sign-in mark is the one thing on any screen
    // drawn in color; everything else arrives with r=g=b, and the shell
    // neither knows nor cares — it blits, it does not interpret.
    // `safe_bottom` is the height (in logical pixels) of the OS-drawn
    // band at the view's bottom edge (the iPhone home indicator); pass 0
    // where there is none.
    const uint8_t *(*on_frame)(void *ctx, int32_t logical_w, int32_t logical_h, int32_t safe_bottom,
                               int32_t scale, int32_t *out_w, int32_t *out_h);
    // Input; coordinates are logical pixels. `phase` is NOKRE_POINTER_*.
    void (*on_pointer)(void *ctx, int32_t x, int32_t y, int32_t phase);
    // The control keys of the NOKRE_KEY_* enum, as pressed. Printable
    // characters never come this way: they are `on_text`, composed by
    // the platform's own text system.
    //
    // Space is the one key that is both — it activates a button and it
    // types a character — so it travels as exactly ONE of the two legs
    // per press, chosen by `wants_text_input` *at press time*: `on_text`
    // while a field has focus, `on_key` everywhere else.
    //
    // Never both. Activation can move focus into a field (a `select`
    // opens a picker whose long lists carry a filter), and the second
    // leg would then land in a field the user never typed into. Never
    // neither, either: a shell that maps Space to a key and stops there
    // is a shell whose space bar does nothing in text fields.
    void (*on_key)(void *ctx, int32_t key, uint8_t mods);
    // Committed UTF-8 text — a keystroke the text system resolved, or an
    // IME commit. Borrowed for the call; `len` is authoritative.
    void (*on_text)(void *ctx, const char *utf8, size_t len);
    void (*on_scroll)(void *ctx, int32_t x, int32_t y, int32_t delta_x, int32_t delta_y,
                      int32_t phase); // NOKRE_SCROLL_*
    // One step of a drag inward from a screen edge — the gesture that
    // goes back, and the only gesture there is. `from` is NOKRE_EDGE_*,
    // the physical side the finger started on; `dx` is how far in from
    // it the finger has come, in logical pixels, never negative. A shell
    // reports geometry and nothing else: which edge means back, how far
    // is far enough, and whether there is anything to go back to are all
    // decided in core, so five shells cannot answer them five ways.
    //
    // Implemented only where the platform leaves the edge to the app:
    // iOS. Android's own gesture navigation owns both edges and delivers
    // the system back instead (on_back), and no desktop platform has an
    // equivalent — those shells leave this callback unused.
    void (*on_edge_pan)(void *ctx, int32_t from, int32_t dx, int32_t phase); // NOKRE_EDGE_*, NOKRE_PAN_*
    // The platform's own back command (Android's gesture or button).
    // Returns 1 if nokre consumed it — there was a screen to go back
    // to — and 0 if the app should do whatever it does with an
    // unhandled back, which on Android means finishing the activity.
    int32_t (*on_back)(void *ctx);
    // IME composition (NSTextInputClient on macOS).
    void (*on_ime_update)(void *ctx, const char *utf8, size_t len, size_t cursor);
    void (*on_ime_commit)(void *ctx, const char *utf8, size_t len);
    void (*on_ime_cancel)(void *ctx);
    // Whether the app changed state and wants a repaint.
    int32_t (*wants_frame)(void *ctx);
    // Whether the focused element accepts typed text. Shells that own a
    // software keyboard (iOS, Android, web) ask after every event and
    // show or hide it; every shell asks to route the Space key (on_key).
    int32_t (*wants_text_input)(void *ctx);
    // Whether the control at (x, y) needs the raw pointer stream — DOWN,
    // MOVE, UP as they happen — instead of the single recognized tap a
    // touch shell normally reports. Touch shells ask at touch-down and
    // route that one gesture accordingly; the three mouse shells always
    // send the stream and never call this.
    //
    // The same bargain as `wants_text_input`: the shell asks at press
    // time, core owns the answer, and no shell learns *what* is there.
    // A shell that always got 0 back would behave exactly as it did
    // before this existed — which is the point. Whatever says yes gives
    // up its recognizer's arbitration against scrolling, so core only
    // says yes for fixed chrome with nothing scrollable beneath it.
    int32_t (*wants_pointer_stream)(void *ctx, int32_t x, int32_t y);
    // OS appearance, reported at startup and on change. dark: 0 = light, 1 = dark.
    void (*on_appearance)(void *ctx, int32_t dark);
    // Called once after the window exists, before the event loop (and
    // before the window is shown, where the platform can — AccessKit's
    // Windows adapter demands a hidden window); `view` is the platform
    // view (NSView* on macOS, HWND on Windows) — where the a11y adapter
    // attaches. `window_class` names the shell's NSWindow subclass or
    // Win32 window class.
    void (*on_ready)(void *ctx, void *view, const char *window_class);
    // Whether the window has focus (is key), at startup and on change.
    void (*on_window_focus)(void *ctx, int32_t focused);
} nokre_shell_config;

// Runs the platform event loop; returns when the window closes (never
// returns on iOS — the OS owns process exit).
int32_t nokre_shell_run(const nokre_shell_config *config);

// Marks the view dirty from outside the input stream (a11y actions
// mutate app state without a shell event). Safe from any thread.
void nokre_shell_request_frame(void *view);

// Replaces the system clipboard contents with the given UTF-8 text
// (not NUL-terminated). Main thread only, like all input callbacks.
void nokre_shell_write_clipboard(const char *utf8, size_t len);

// One haptic knock: the back gesture crossing its commit threshold
// (NOKRE_HAPTIC_ARMED) or crossing back out of it
// (NOKRE_HAPTIC_DISARMED). Implemented by the one shell that has the
// gesture — iOS — and named by no other, so the symbol does not exist
// elsewhere (docs/internals/haptics.md). Main thread only.
void nokre_shell_haptic(int32_t kind);

// Runs `work(ctx)` on the UI thread soon. Safe from any thread — this is
// the worker service's delivery hop (docs/internals/workers.md): a
// worker thread queued a reply and needs the pump run where app code
// lives. Implemented only by shells whose main queue the Zig side cannot
// reach directly (Windows posts a window message); on Apple platforms
// c_shell.zig calls dispatch_async_f itself and never links this symbol.
void nokre_shell_post_main(void *view, void (*work)(void *ctx), void *ctx);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SHELL_H
