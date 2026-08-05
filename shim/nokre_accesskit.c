// AccessKit binding: translates nokre's flattened semantic snapshot into
// AccessKit tree updates. Role/action mapping lives here so it is
// compile-checked against the real accesskit.h.
#include "nokre_accesskit.h"

#include <stdlib.h>

#ifdef _WIN32
#include <windows.h>
#endif

#include "accesskit.h"

typedef struct nokre_a11y {
    nokre_a11y_fill_fn fill;
    void *fill_ctx;
    nokre_a11y_action_fn action;
    void *action_ctx;
#ifdef ACCESSKIT_MACOS
    accesskit_macos_subclassing_adapter *macos;
#endif
#ifdef _WIN32
    accesskit_windows_subclassing_adapter *windows;
    HWND action_hwnd; // message-only window marshalling actions to the UI thread
#endif
} nokre_a11y;

static accesskit_role role_of(int32_t role) {
    switch (role) {
        case NOKRE_A11Y_ROLE_DOCUMENT: return ACCESSKIT_ROLE_DOCUMENT;
        case NOKRE_A11Y_ROLE_STATIC_TEXT: return ACCESSKIT_ROLE_LABEL;
        case NOKRE_A11Y_ROLE_HEADING: return ACCESSKIT_ROLE_HEADING;
        case NOKRE_A11Y_ROLE_GROUP: return ACCESSKIT_ROLE_GROUP;
        case NOKRE_A11Y_ROLE_SEPARATOR: return ACCESSKIT_ROLE_SPLITTER;
        case NOKRE_A11Y_ROLE_BUTTON: return ACCESSKIT_ROLE_BUTTON;
        case NOKRE_A11Y_ROLE_LINK: return ACCESSKIT_ROLE_LINK;
        case NOKRE_A11Y_ROLE_TOGGLE: return ACCESSKIT_ROLE_SWITCH;
        case NOKRE_A11Y_ROLE_TEXT_FIELD: return ACCESSKIT_ROLE_TEXT_INPUT;
        case NOKRE_A11Y_ROLE_TABLE: return ACCESSKIT_ROLE_TABLE;
        case NOKRE_A11Y_ROLE_ROW: return ACCESSKIT_ROLE_ROW;
        case NOKRE_A11Y_ROLE_CELL: return ACCESSKIT_ROLE_CELL;
        case NOKRE_A11Y_ROLE_SCROLL_AREA: return ACCESSKIT_ROLE_SCROLL_VIEW;
        case NOKRE_A11Y_ROLE_RADIO_GROUP: return ACCESSKIT_ROLE_RADIO_GROUP;
        case NOKRE_A11Y_ROLE_NAVIGATION: return ACCESSKIT_ROLE_NAVIGATION;
        case NOKRE_A11Y_ROLE_DIALOG: return ACCESSKIT_ROLE_DIALOG;
        case NOKRE_A11Y_ROLE_STATUS: return ACCESSKIT_ROLE_STATUS;
        case NOKRE_A11Y_ROLE_COMBO_BOX: return ACCESSKIT_ROLE_COMBO_BOX;
        case NOKRE_A11Y_ROLE_OPTION: return ACCESSKIT_ROLE_LIST_BOX_OPTION;
        case NOKRE_A11Y_ROLE_MULTILINE_TEXT_FIELD: return ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT;
        case NOKRE_A11Y_ROLE_IMAGE: return ACCESSKIT_ROLE_IMAGE;
        case NOKRE_A11Y_ROLE_PASSWORD_FIELD: return ACCESSKIT_ROLE_PASSWORD_INPUT;
        case NOKRE_A11Y_ROLE_CHECKBOX: return ACCESSKIT_ROLE_CHECK_BOX;
        case NOKRE_A11Y_ROLE_LIST: return ACCESSKIT_ROLE_LIST;
        case NOKRE_A11Y_ROLE_LIST_ITEM: return ACCESSKIT_ROLE_LIST_ITEM;
        case NOKRE_A11Y_ROLE_CODE: return ACCESSKIT_ROLE_CODE;
        case NOKRE_A11Y_ROLE_BLOCKQUOTE: return ACCESSKIT_ROLE_BLOCKQUOTE;
        default: return ACCESSKIT_ROLE_GROUP;
    }
}

static accesskit_node *build_node(const nokre_a11y_node *n) {
    accesskit_node *node = accesskit_node_new(role_of(n->role));
    accesskit_node_set_bounds(
        node, accesskit_rect_new(n->x, n->y, n->x + n->w, n->y + n->h));
    // AccessKit's Label role carries its text as value, not label.
    if (n->role == NOKRE_A11Y_ROLE_STATIC_TEXT) {
        if (n->label_len > 0)
            accesskit_node_set_value_with_length(node, n->label, n->label_len);
    } else {
        if (n->label_len > 0)
            accesskit_node_set_label_with_length(node, n->label, n->label_len);
        if (n->value_len > 0)
            accesskit_node_set_value_with_length(node, n->value, n->value_len);
    }
    if (n->heading_level > 0)
        accesskit_node_set_level(node, n->heading_level);
    if (n->checked >= 0)
        accesskit_node_set_toggled(
            node, n->checked ? ACCESSKIT_TOGGLED_TRUE : ACCESSKIT_TOGGLED_FALSE);
    if (n->selected >= 0) accesskit_node_set_selected(node, n->selected != 0);
    if (n->description_len > 0)
        accesskit_node_set_description_with_length(node, n->description,
                                                   n->description_len);
    // ACCESSKIT_INVALID_TRUE, not the grammar/spelling variants: those
    // are about a word inside the text, and this is about the value.
    if (n->invalid) accesskit_node_set_invalid(node, ACCESSKIT_INVALID_TRUE);
    if (n->disabled) accesskit_node_set_disabled(node);
    if (n->busy) accesskit_node_set_busy(node);
    if (n->modal) accesskit_node_set_modal(node);
    if (n->role == NOKRE_A11Y_ROLE_STATUS)
        accesskit_node_set_live(node, ACCESSKIT_LIVE_POLITE);
    if (n->focusable) accesskit_node_add_action(node, ACCESSKIT_ACTION_FOCUS);
    if (n->clickable) accesskit_node_add_action(node, ACCESSKIT_ACTION_CLICK);
    return node;
}

// Factories must never return NULL; a bare root keeps AT consistent
// until the next successful fill.
static accesskit_tree_update *fallback_update(void) {
    accesskit_tree_update *update =
        accesskit_tree_update_with_capacity_and_focus(1, 0);
    accesskit_tree_update_set_tree(update, accesskit_tree_new(0));
    accesskit_tree_update_push_node(update, 0,
                                    accesskit_node_new(ACCESSKIT_ROLE_GROUP));
    return update;
}

// Builds an AccessKit tree update from a flattened node array. Pure — it
// touches no app state — so it is safe to call on any thread as long as
// the caller owns `nodes` (the macOS/Windows path passes the live fill
// output on the UI thread; the Unix path passes a locked cache).
static accesskit_tree_update *build_update_from_nodes(const nokre_a11y_node *nodes,
                                                      size_t count, uint64_t focus) {
    if (nodes == NULL || count == 0) return fallback_update();

    accesskit_node **built = calloc(count, sizeof(accesskit_node *));
    if (built == NULL) return fallback_update();
    for (size_t i = 0; i < count; i++) built[i] = build_node(&nodes[i]);
    for (size_t i = 0; i < count; i++) {
        if (nodes[i].parent != SIZE_MAX)
            accesskit_node_push_child(built[nodes[i].parent], nodes[i].id);
    }

    accesskit_tree_update *update =
        accesskit_tree_update_with_capacity_and_focus(count, focus);
    accesskit_tree_update_set_tree(update, accesskit_tree_new(nodes[0].id));
    for (size_t i = 0; i < count; i++)
        accesskit_tree_update_push_node(update, nodes[i].id, built[i]);
    free(built);
    return update;
}

static accesskit_tree_update *build_update(void *userdata) {
    nokre_a11y *a = userdata;
    size_t count = 0;
    uint64_t focus = 0;
    const nokre_a11y_node *nodes = a->fill(a->fill_ctx, &count, &focus);
    return build_update_from_nodes(nodes, count, focus);
}

#ifdef ACCESSKIT_MACOS
// The direct action handler: macOS delivers actions on the UI thread, so
// dispatch is immediate. Windows (UIA, off-thread) marshals through a
// message-only window and Linux (AT-SPI, off-thread) through
// nokre_shell_post_main — each swaps in its own handler below.
static void handle_action(accesskit_action_request *request, void *userdata) {
    nokre_a11y *a = userdata;
    int32_t action = 0;
    switch (request->action) {
        case ACCESSKIT_ACTION_CLICK: action = NOKRE_A11Y_ACTION_CLICK; break;
        case ACCESSKIT_ACTION_FOCUS: action = NOKRE_A11Y_ACTION_FOCUS; break;
        default: break;
    }
    if (action != 0) a->action(a->action_ctx, request->target_node, action);
    accesskit_action_request_free(request);
}
#endif // ACCESSKIT_MACOS

#ifdef ACCESSKIT_MACOS

void *nokre_a11y_macos_attach(void *ns_view, const char *window_class,
                            nokre_a11y_fill_fn fill, void *fill_ctx,
                            nokre_a11y_action_fn action, void *action_ctx) {
    nokre_a11y *a = calloc(1, sizeof(nokre_a11y));
    if (a == NULL) return NULL;
    a->fill = fill;
    a->fill_ctx = fill_ctx;
    a->action = action;
    a->action_ctx = action_ctx;
    accesskit_macos_add_focus_forwarder_to_window_class(window_class);
    a->macos = accesskit_macos_subclassing_adapter_new(
        ns_view, build_update, a, handle_action, a);
    if (a->macos == NULL) {
        free(a);
        return NULL;
    }
    return a;
}

void nokre_a11y_macos_update(void *adapter) {
    nokre_a11y *a = adapter;
    accesskit_macos_queued_events *events =
        accesskit_macos_subclassing_adapter_update_if_active(a->macos,
                                                             build_update, a);
    if (events != NULL) accesskit_macos_queued_events_raise(events);
}

void nokre_a11y_macos_focus_state(void *adapter, int32_t focused) {
    nokre_a11y *a = adapter;
    accesskit_macos_queued_events *events =
        accesskit_macos_subclassing_adapter_update_view_focus_state(
            a->macos, focused != 0);
    if (events != NULL) accesskit_macos_queued_events_raise(events);
}

void nokre_a11y_macos_detach(void *adapter) {
    nokre_a11y *a = adapter;
    accesskit_macos_subclassing_adapter_free(a->macos);
    free(a);
}

#endif // ACCESSKIT_MACOS

#ifdef _WIN32

// UIA may deliver actions off the UI thread; every downstream consumer
// (App.dispatch, nokre_shell_request_frame's PostMessage target lookup)
// assumes the UI thread, so actions bounce through a message-only
// window owned by it. WPARAM carries the 64-bit node id, LPARAM the
// NOKRE_A11Y_ACTION_* code.
#define NOKRE_WM_A11Y_ACTION (WM_APP + 1)

static LRESULT CALLBACK action_wnd_proc(HWND hwnd, UINT msg, WPARAM wparam,
                                        LPARAM lparam) {
    if (msg == NOKRE_WM_A11Y_ACTION) {
        nokre_a11y *a = (nokre_a11y *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (a != NULL) a->action(a->action_ctx, (uint64_t)wparam, (int32_t)lparam);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static void handle_action_windows(accesskit_action_request *request,
                                  void *userdata) {
    nokre_a11y *a = userdata;
    int32_t action = 0;
    switch (request->action) {
        case ACCESSKIT_ACTION_CLICK: action = NOKRE_A11Y_ACTION_CLICK; break;
        case ACCESSKIT_ACTION_FOCUS: action = NOKRE_A11Y_ACTION_FOCUS; break;
        default: break;
    }
    if (action != 0)
        PostMessageW(a->action_hwnd, NOKRE_WM_A11Y_ACTION,
                     (WPARAM)request->target_node, (LPARAM)action);
    accesskit_action_request_free(request);
}

void *nokre_a11y_windows_attach(void *hwnd, nokre_a11y_fill_fn fill,
                              void *fill_ctx, nokre_a11y_action_fn action,
                              void *action_ctx) {
    nokre_a11y *a = calloc(1, sizeof(nokre_a11y));
    if (a == NULL) return NULL;
    a->fill = fill;
    a->fill_ctx = fill_ctx;
    a->action = action;
    a->action_ctx = action_ctx;

    static const WCHAR class_name[] = L"NokreA11yAction";
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = action_wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = class_name;
    RegisterClassW(&wc); // idempotent: re-registration fails harmlessly
    a->action_hwnd = CreateWindowExW(0, class_name, L"", 0, 0, 0, 0, 0,
                                     HWND_MESSAGE, NULL, wc.hInstance, NULL);
    if (a->action_hwnd == NULL) {
        free(a);
        return NULL;
    }
    SetWindowLongPtrW(a->action_hwnd, GWLP_USERDATA, (LONG_PTR)a);

    a->windows = accesskit_windows_subclassing_adapter_new(
        (HWND)hwnd, build_update, a, handle_action_windows, a);
    if (a->windows == NULL) {
        DestroyWindow(a->action_hwnd);
        free(a);
        return NULL;
    }
    return a;
}

void nokre_a11y_windows_update(void *adapter) {
    nokre_a11y *a = adapter;
    accesskit_windows_queued_events *events =
        accesskit_windows_subclassing_adapter_update_if_active(a->windows,
                                                               build_update, a);
    if (events != NULL) accesskit_windows_queued_events_raise(events);
}

void nokre_a11y_windows_detach(void *adapter) {
    nokre_a11y *a = adapter;
    accesskit_windows_subclassing_adapter_free(a->windows);
    DestroyWindow(a->action_hwnd);
    free(a);
}

#endif // _WIN32

#if defined(__linux__) && !defined(__ANDROID__)

#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// The AccessKit Unix adapter (AT-SPI — Orca and the freedesktop bus) has
// no window handle and, unlike the macOS/Windows subclassing adapters,
// calls its activation and action handlers on its OWN thread, never the
// UI thread (accesskit.h states this). The app's semantic tree and its
// allocator belong to the UI thread, so NOTHING off-thread may touch
// them. This binding therefore keeps a UI-thread-refreshed cache of the
// flattened node array (labels/values deep-copied), and the off-thread
// handlers read only that:
//
//   - build_update_unix (the activation factory, off-thread; and the
//     UI-thread update below) builds the AccessKit tree from the cache
//     under a mutex — never from a->fill, which would snapshot the live
//     tree on the wrong thread.
//   - the UI thread refreshes the cache (nokre_a11y_unix_update, after each
//     frame) before pushing, and once on activation via a posted job so a
//     screen reader that connects while the app is at rest still gets the
//     real tree.
//   - actions (click/focus) must run where app code lives, so the handler
//     hops them to the UI thread through nokre_shell_post_main — the
//     worker-wake lane — the Windows message-only-window marshal
//     relocated to the Wayland shell's eventfd.
//
// set_root_window_bounds is skipped: it only makes sense under X11 (a
// Wayland client cannot know its own window position), and this shell is
// Wayland-only.

// shell.h's UI-thread hop; the Wayland shell (src/platform/linux/shell.c)
// implements it over an eventfd the display loop already waits on.
extern void nokre_shell_post_main(void *view, void (*work)(void *ctx), void *ctx);

typedef struct nokre_a11y_unix {
    nokre_a11y_fill_fn fill;
    void *fill_ctx;
    nokre_a11y_action_fn action;
    void *action_ctx;
    void *view; // the surface nokre_shell_post_main posts through
    accesskit_unix_adapter *adapter;
    pthread_mutex_t lock; // guards the cache fields below

    // An AT is connected. Atomic: the adapter's activation/deactivation
    // handlers set and clear it on their own thread while the UI
    // thread's update reads it — the cache below has a lock, this flag
    // rides outside it.
    atomic_int active;
    // Deep-copied flattened snapshot the off-thread factory reads. Owned
    // here (malloc), so it outlives any app-side buffer and never aliases
    // the tree.
    nokre_a11y_node *cache;
    size_t cache_count;
    uint64_t cache_focus;
    // Backing store the cached label/value/description point into. Every
    // borrowed string on the node has to be in here: one left pointing
    // at the tree is a use-after-mutation the AT thread reads.
    char *cache_strings;
} nokre_a11y_unix;

// One marshalled action in flight, freed after it runs on the UI thread.
typedef struct nokre_a11y_unix_action {
    nokre_a11y_unix *a;
    uint64_t target;
    int32_t action;
} nokre_a11y_unix_action;

// UI thread only: pull a fresh flatten from the app and deep-copy it into
// the cache. a->fill touches app.tree/app.gpa, so this MUST run on the UI
// thread; only the swap into the cache is locked.
static void unix_refresh_cache(nokre_a11y_unix *a) {
    size_t count = 0;
    uint64_t focus = 0;
    const nokre_a11y_node *nodes = a->fill(a->fill_ctx, &count, &focus);

    nokre_a11y_node *nc = NULL;
    char *ns = NULL;
    size_t ncount = 0;
    if (nodes != NULL && count > 0) {
        size_t sbytes = 0;
        for (size_t i = 0; i < count; i++)
            sbytes += nodes[i].label_len + nodes[i].value_len + nodes[i].description_len;
        nc = malloc(count * sizeof(nokre_a11y_node));
        ns = sbytes ? malloc(sbytes) : NULL;
        if (nc != NULL && (sbytes == 0 || ns != NULL)) {
            size_t off = 0;
            for (size_t i = 0; i < count; i++) {
                nc[i] = nodes[i];
                if (nodes[i].label_len > 0) {
                    memcpy(ns + off, nodes[i].label, nodes[i].label_len);
                    nc[i].label = ns + off;
                    off += nodes[i].label_len;
                } else {
                    nc[i].label = NULL;
                }
                if (nodes[i].value_len > 0) {
                    memcpy(ns + off, nodes[i].value, nodes[i].value_len);
                    nc[i].value = ns + off;
                    off += nodes[i].value_len;
                } else {
                    nc[i].value = NULL;
                }
                if (nodes[i].description_len > 0) {
                    memcpy(ns + off, nodes[i].description, nodes[i].description_len);
                    nc[i].description = ns + off;
                    off += nodes[i].description_len;
                } else {
                    nc[i].description = NULL;
                }
            }
            ncount = count;
        } else {
            free(nc);
            free(ns);
            nc = NULL;
            ns = NULL;
        }
    }

    pthread_mutex_lock(&a->lock);
    free(a->cache);
    free(a->cache_strings);
    a->cache = nc;
    a->cache_strings = ns;
    a->cache_count = ncount;
    a->cache_focus = focus;
    pthread_mutex_unlock(&a->lock);
}

// The tree-update factory AccessKit calls, off-thread on activation and on
// the UI thread from nokre_a11y_unix_update. Builds only from the locked
// cache — never the live app.
static accesskit_tree_update *build_update_unix(void *userdata) {
    nokre_a11y_unix *a = userdata;
    pthread_mutex_lock(&a->lock);
    accesskit_tree_update *update =
        build_update_from_nodes(a->cache, a->cache_count, a->cache_focus);
    pthread_mutex_unlock(&a->lock);
    return update;
}

// Posted to the UI thread on activation: refresh the cache and push it, so
// a screen reader connecting while the app is idle sees the real tree
// without waiting for the next frame.
static void unix_post_refresh(void *ctx) {
    nokre_a11y_unix *a = ctx;
    unix_refresh_cache(a);
    accesskit_unix_adapter_update_if_active(a->adapter, build_update_unix, a);
}

static accesskit_tree_update *activation_unix(void *userdata) {
    nokre_a11y_unix *a = userdata;
    a->active = 1;
    // Ask the UI thread to refresh + re-push; this off-thread call returns
    // whatever the cache holds now (a bare root until the first refresh).
    nokre_shell_post_main(a->view, unix_post_refresh, a);
    return build_update_unix(userdata);
}

static void deactivation_unix(void *userdata) {
    nokre_a11y_unix *a = userdata;
    a->active = 0;
}

static void run_action_ui(void *ctx) {
    nokre_a11y_unix_action *req = ctx;
    req->a->action(req->a->action_ctx, req->target, req->action);
    free(req);
}

static void handle_action_unix(accesskit_action_request *request,
                               void *userdata) {
    nokre_a11y_unix *a = userdata;
    int32_t action = 0;
    switch (request->action) {
        case ACCESSKIT_ACTION_CLICK: action = NOKRE_A11Y_ACTION_CLICK; break;
        case ACCESSKIT_ACTION_FOCUS: action = NOKRE_A11Y_ACTION_FOCUS; break;
        default: break;
    }
    if (action != 0) {
        nokre_a11y_unix_action *req = malloc(sizeof(*req));
        if (req != NULL) {
            req->a = a;
            req->target = request->target_node;
            req->action = action;
            nokre_shell_post_main(a->view, run_action_ui, req);
        }
    }
    accesskit_action_request_free(request);
}

void *nokre_a11y_unix_attach(void *view, nokre_a11y_fill_fn fill, void *fill_ctx,
                           nokre_a11y_action_fn action, void *action_ctx) {
    nokre_a11y_unix *a = calloc(1, sizeof(nokre_a11y_unix));
    if (a == NULL) return NULL;
    atomic_init(&a->active, 0); // calloc zeroes bytes, not atomics, formally
    a->fill = fill;
    a->fill_ctx = fill_ctx;
    a->action = action;
    a->action_ctx = action_ctx;
    a->view = view;
    pthread_mutex_init(&a->lock, NULL);
    a->adapter = accesskit_unix_adapter_new(activation_unix, a,
                                            handle_action_unix, a,
                                            deactivation_unix, a);
    if (a->adapter == NULL) {
        pthread_mutex_destroy(&a->lock);
        free(a);
        return NULL;
    }
    return a;
}

void nokre_a11y_unix_update(void *adapter) {
    nokre_a11y_unix *a = adapter;
    // Only pay for a snapshot when an AT is actually listening (the
    // update_if_active factory would otherwise not be called anyway, but
    // the cache refresh has a real cost every frame).
    if (!a->active) return;
    unix_refresh_cache(a);
    accesskit_unix_adapter_update_if_active(a->adapter, build_update_unix, a);
}

void nokre_a11y_unix_focus_state(void *adapter, int32_t focused) {
    nokre_a11y_unix *a = adapter;
    accesskit_unix_adapter_update_window_focus_state(a->adapter, focused != 0);
}

void nokre_a11y_unix_detach(void *adapter) {
    nokre_a11y_unix *a = adapter;
    accesskit_unix_adapter_free(a->adapter); // stops the handler thread first
    pthread_mutex_destroy(&a->lock);
    free(a->cache);
    free(a->cache_strings);
    free(a);
}

#endif // __linux__ && !__ANDROID__
