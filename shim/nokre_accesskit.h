// C contract between Zig (src/a11y/accesskit.zig) and the AccessKit
// binding (nokre_accesskit.c). Zig hands over the flattened semantic
// snapshot; the binding turns it into AccessKit tree updates and owns the
// platform adapter. Kept accesskit.h-free so Zig never mirrors foreign
// enums.
#ifndef NOKRE_ACCESSKIT_H
#define NOKRE_ACCESSKIT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors src/a11y/semantics.zig A11yRole, same order.
enum {
    NOKRE_A11Y_ROLE_DOCUMENT = 0,
    NOKRE_A11Y_ROLE_STATIC_TEXT = 1,
    NOKRE_A11Y_ROLE_HEADING = 2,
    NOKRE_A11Y_ROLE_GROUP = 3,
    NOKRE_A11Y_ROLE_SEPARATOR = 4,
    NOKRE_A11Y_ROLE_BUTTON = 5,
    NOKRE_A11Y_ROLE_LINK = 6,
    NOKRE_A11Y_ROLE_TOGGLE = 7,
    NOKRE_A11Y_ROLE_TEXT_FIELD = 8,
    NOKRE_A11Y_ROLE_TABLE = 9,
    NOKRE_A11Y_ROLE_ROW = 10,
    NOKRE_A11Y_ROLE_CELL = 11,
    NOKRE_A11Y_ROLE_SCROLL_AREA = 12,
    NOKRE_A11Y_ROLE_RADIO_GROUP = 13,
    NOKRE_A11Y_ROLE_NAVIGATION = 14,
    NOKRE_A11Y_ROLE_DIALOG = 15,
    NOKRE_A11Y_ROLE_STATUS = 16,
    NOKRE_A11Y_ROLE_COMBO_BOX = 17,
    NOKRE_A11Y_ROLE_OPTION = 18,
    NOKRE_A11Y_ROLE_MULTILINE_TEXT_FIELD = 19,
    NOKRE_A11Y_ROLE_IMAGE = 20,
    NOKRE_A11Y_ROLE_PASSWORD_FIELD = 21,
    NOKRE_A11Y_ROLE_CHECKBOX = 22,
    NOKRE_A11Y_ROLE_LIST = 23,
    NOKRE_A11Y_ROLE_LIST_ITEM = 24,
    NOKRE_A11Y_ROLE_CODE = 25,
    NOKRE_A11Y_ROLE_BLOCKQUOTE = 26,
};

// Requests assistive tech can make of the app.
enum {
    NOKRE_A11Y_ACTION_CLICK = 1,
    NOKRE_A11Y_ACTION_FOCUS = 2,
};

// One flattened a11y node; mirrors src/a11y/accesskit.zig CNode exactly.
typedef struct nokre_a11y_node {
    uint64_t id;
    int32_t role;
    const char *label;
    size_t label_len;
    const char *value;
    size_t value_len;
    // Layout rect in logical pixels, view-relative, y-down.
    double x, y, w, h;
    // Index of the parent within the array; SIZE_MAX for the root.
    // Parents always precede children (document order).
    size_t parent;
    uint8_t focusable;
    uint8_t focused;
    uint8_t disabled;
    uint8_t modal;
    uint8_t clickable;
    int8_t checked;  // -1 not checkable, else 0/1
    int8_t selected; // -1 not selectable, else 0/1
    uint8_t heading_level; // 0 when not a heading
    // The action this node started is still running (a button's
    // in_progress). Always paired with disabled: busy means named and
    // present but not operable yet.
    uint8_t busy;
    // aria-invalid: what this field holds was refused. Never paired
    // with disabled — the field still takes input, which is the whole
    // difference from busy.
    uint8_t invalid;
    // The accessible description: words that are neither the name nor
    // the value. Today a text field's problem, and always non-empty
    // when `invalid` is set — an invalid control with no reason given
    // is the state the slot exists to abolish.
    const char *description;
    size_t description_len;
} nokre_a11y_node;

// Returns the current UI as a flat array (root first, document order),
// valid until the next call; sets *count and *focus_id (the AccessKit id
// of the focused node, or the root id when nothing is focused). May
// return NULL on allocation failure.
typedef const nokre_a11y_node *(*nokre_a11y_fill_fn)(void *ctx, size_t *count,
                                                 uint64_t *focus_id);

// Delivers an assistive-tech request (NOKRE_A11Y_ACTION_*) for a node.
typedef void (*nokre_a11y_action_fn)(void *ctx, uint64_t target,
                                   int32_t action);

#ifdef __APPLE__
// Attaches AccessKit to the NSView backing the window; `window_class`
// must name the NSWindow subclass so window-level focus queries forward
// to the view. Returns an opaque adapter handle, or NULL on failure.
void *nokre_a11y_macos_attach(void *ns_view, const char *window_class,
                            nokre_a11y_fill_fn fill, void *fill_ctx,
                            nokre_a11y_action_fn action, void *action_ctx);
// Pushes fresh state to assistive tech if any is listening.
void nokre_a11y_macos_update(void *adapter);
// Reports whether the window is key (1) or not (0).
void nokre_a11y_macos_focus_state(void *adapter, int32_t focused);
void nokre_a11y_macos_detach(void *adapter);

// iOS: no AccessKit — UIKit's UIAccessibility natively consumes a flat
// element list, so the iOS shell (src/platform/ios/shell.m) implements
// these itself over the same nokre_a11y_node array. `view` is the UIView
// the elements attach to; the handle is the view.
void *nokre_a11y_ios_attach(void *view, nokre_a11y_fill_fn fill, void *fill_ctx,
                          nokre_a11y_action_fn action, void *action_ctx);
void nokre_a11y_ios_update(void *adapter);
#endif

#ifdef _WIN32
// Attaches AccessKit's subclassing adapter to the window; must run on
// the window's thread while the window is still hidden (it wraps the
// window procedure). Returns an opaque adapter handle, or NULL.
void *nokre_a11y_windows_attach(void *hwnd, nokre_a11y_fill_fn fill,
                              void *fill_ctx, nokre_a11y_action_fn action,
                              void *action_ctx);
// Pushes fresh state to assistive tech if any is listening.
void nokre_a11y_windows_update(void *adapter);
void nokre_a11y_windows_detach(void *adapter);
#endif

#if defined(__linux__) && !defined(__ANDROID__)
// Registers the process on the AT-SPI bus (AccessKit's Unix adapter).
// There is no window handle — the adapter runs its handlers on its own
// thread — so `view` is only the surface off-thread actions marshal back
// through (nokre_shell_post_main). Returns an opaque handle, or NULL.
void *nokre_a11y_unix_attach(void *view, nokre_a11y_fill_fn fill, void *fill_ctx,
                           nokre_a11y_action_fn action, void *action_ctx);
// Pushes fresh state to assistive tech if any is listening.
void nokre_a11y_unix_update(void *adapter);
// Reports whether the window is focused (1) or not (0).
void nokre_a11y_unix_focus_state(void *adapter, int32_t focused);
void nokre_a11y_unix_detach(void *adapter);
#endif

#ifdef __cplusplus
}
#endif

#endif // NOKRE_ACCESSKIT_H
