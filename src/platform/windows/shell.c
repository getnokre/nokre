// Win32 shell. Thin by charter: window, RGBX blit, input forwarding,
// IMM32 for IME. No timers, no compositor hooks — nokre repaints only
// when state changes.
#define WINVER 0x0A00
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <imm.h>
#include <shellapi.h>
#include <limits.h>
#include <wchar.h>
#include <stdlib.h>
#include <string.h>

#include "../shell.h"
#include "../../services/deep_link/deep_link.h"
#include "../../services/locale/locale.h"
#include "../../services/notification/notification.h"
#include "../../services/open_url/open_url.h"
#include "../../services/share/share.h"

// Marks the view dirty from any thread (WPARAM/LPARAM unused).
#define NOKRE_WM_REQUEST_FRAME (WM_APP + 0)
// Runs a callback on the UI thread: WPARAM is the function, LPARAM its
// context. Posted by nokre_shell_post_main from worker threads.
#define NOKRE_WM_POST_MAIN (WM_APP + 1)

// Tags the WM_COPYDATA a second launch sends the running instance to hand
// off a deep-link URL (COPYDATASTRUCT.dwData), so an unrelated WM_COPYDATA
// is ignored. 'HALD'.
#define NOKRE_DEEP_LINK_COPYDATA 0x48414C44

// One window by design; module state instead of per-window allocations.
static struct {
    nokre_shell_config config;
    HWND hwnd;
    int32_t scale; // integer device scale, >= 1
    uint32_t *blit; // RGBX swizzled to BGRX for SetDIBitsToDevice
    size_t blit_cap;
    int composing; // inside an IME composition
    int wheel_rem_x, wheel_rem_y; // sub-notch wheel remainders, in delta units
    WCHAR pending_high_surrogate;
    int space_activated; // a Space already sent as a key; its WM_CHAR is an echo
    // Our own ReleaseCapture also raises WM_CAPTURECHANGED; this marks
    // the expected one so an orderly release is not read as the system
    // taking the press away.
    int releasing_capture;
} g;

static void maybe_repaint(void) {
    if (g.config.wants_frame(g.config.ctx)) InvalidateRect(g.hwnd, NULL, FALSE);
}

// Rounds the DPI to the nearest integer scale (125% → 1, 150% → 2), the
// same policy as the web shell: the buffer maps 1:1 onto device pixels,
// so text stays crisp at every DPI at the cost of slightly-off logical
// sizing on fractional scales.
static int32_t scale_of(UINT dpi) {
    int32_t scale = (int32_t)((dpi + 48) / 96);
    return scale < 1 ? 1 : scale;
}

// ---- appearance ----

static int is_dark_appearance(void) {
    DWORD light = 1, size = sizeof(light);
    if (RegGetValueW(HKEY_CURRENT_USER,
                     L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &light,
                     &size) != ERROR_SUCCESS)
        return 0;
    return light == 0;
}

static void report_appearance(void) {
    int dark = is_dark_appearance();
    // The window frame is OS chrome, so it may follow the OS theme even
    // though nokre content never animates or recolors itself.
    BOOL dark_frame = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(g.hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_frame,
                          sizeof(dark_frame));
    g.config.on_appearance(g.config.ctx, dark);
}

// ---- paint ----

static void paint(HDC hdc) {
    RECT rc;
    GetClientRect(g.hwnd, &rc);
    if (rc.right < 1 || rc.bottom < 1) return;
    // Ceil so logical * scale covers the client area; the blit crops the
    // sub-scale remainder at the right/bottom edge.
    int32_t logical_w = (rc.right + g.scale - 1) / g.scale;
    int32_t logical_h = (rc.bottom + g.scale - 1) / g.scale;
    int32_t w = 0, h = 0;
    const uint8_t *pixels = g.config.on_frame(g.config.ctx, logical_w, logical_h, 0,
                                              g.scale, &w, &h);
    if (!pixels || w <= 0 || h <= 0) return;

    // GDI wants BGRX and the frame arrives RGBX (shell.h); the swizzle
    // keeps the blit the same one unconditional memcpy-shaped loop the
    // gray8 expansion was.
    size_t count = (size_t)w * (size_t)h;
    if (count > g.blit_cap) {
        free(g.blit);
        g.blit = malloc(count * 4);
        g.blit_cap = g.blit ? count : 0;
        if (!g.blit) return;
    }
    for (size_t i = 0; i < count; i++) {
        const uint8_t *px = pixels + i * 4;
        g.blit[i] = (uint32_t)px[2] | ((uint32_t)px[1] << 8) | ((uint32_t)px[0] << 16);
    }

    BITMAPINFO bi = {0};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h; // top-down, matching nokre's y-down origin
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    SetDIBitsToDevice(hdc, 0, 0, w, h, 0, 0, 0, h, g.blit, &bi, DIB_RGB_COLORS);
}

// ---- text ----

static char *utf8_dup(const WCHAR *wide, int wide_len, int *out_len) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wide, wide_len, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char *utf8 = malloc((size_t)len);
    if (!utf8) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, wide, wide_len, utf8, len, NULL, NULL);
    *out_len = len;
    return utf8;
}

// The deep-link URL a custom-scheme protocol activation puts on our
// command line, as freshly malloc'd UTF-8 (len in *out_len, no trailing
// NUL counted), or NULL when launched without one. CommandLineToArgvW
// splits argv the way the CRT would; the URL is the first argument that
// carries a scheme (`://`) — everything else is a flag or a path.
static char *launch_deep_link_utf8(int *out_len) {
    int argc = 0;
    WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return NULL;
    char *url = NULL;
    for (int i = 1; i < argc; i++) {
        if (wcsstr(argv[i], L"://")) {
            url = utf8_dup(argv[i], (int)wcslen(argv[i]), out_len);
            break;
        }
    }
    LocalFree(argv);
    return url;
}

static void send_char(WCHAR wch) {
    // The echo of a Space that WM_KEYDOWN already spent on activation
    // (shell.h: one press, one leg). The latch clears on whatever char
    // arrives next, so a Space whose WM_CHAR never comes cannot mute the
    // one after it.
    const int echo = g.space_activated;
    g.space_activated = 0;
    // Control characters travel as keys (WM_KEYDOWN), never as text —
    // the macOS shell's keyDown/insertText split.
    if (wch < 0x20 || wch == 0x7F) return;
    if (echo && wch == L' ') return;
    WCHAR pair[2];
    int wide_len = 1;
    if (wch >= 0xD800 && wch <= 0xDBFF) {
        g.pending_high_surrogate = wch;
        return;
    }
    if (wch >= 0xDC00 && wch <= 0xDFFF) {
        if (g.pending_high_surrogate == 0) return;
        pair[0] = g.pending_high_surrogate;
        pair[1] = wch;
        wide_len = 2;
        g.pending_high_surrogate = 0;
    } else {
        pair[0] = wch;
    }
    char utf8[8];
    int len = WideCharToMultiByte(CP_UTF8, 0, pair, wide_len, utf8, sizeof(utf8), NULL, NULL);
    if (len <= 0) return;
    g.config.on_text(g.config.ctx, utf8, (size_t)len);
    maybe_repaint();
}

// ---- keyboard ----

static int32_t key_from_vk(WPARAM vk) {
    switch (vk) {
        case VK_TAB: return NOKRE_KEY_TAB;
        case VK_RETURN: return NOKRE_KEY_ENTER;
        case VK_SPACE: return NOKRE_KEY_SPACE;
        case VK_ESCAPE: return NOKRE_KEY_ESCAPE;
        case VK_BACK: return NOKRE_KEY_BACKSPACE;
        case VK_DELETE: return NOKRE_KEY_DELETE;
        case VK_LEFT: return NOKRE_KEY_LEFT;
        case VK_RIGHT: return NOKRE_KEY_RIGHT;
        case VK_UP: return NOKRE_KEY_UP;
        case VK_DOWN: return NOKRE_KEY_DOWN;
        case VK_HOME: return NOKRE_KEY_HOME;
        case VK_END: return NOKRE_KEY_END;
        case VK_PRIOR: return NOKRE_KEY_PAGE_UP;
        case VK_NEXT: return NOKRE_KEY_PAGE_DOWN;
        default: return 0;
    }
}

static uint8_t current_mods(void) {
    uint8_t mods = 0;
    if (GetKeyState(VK_SHIFT) & 0x8000) mods |= NOKRE_MOD_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000) mods |= NOKRE_MOD_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000) mods |= NOKRE_MOD_ALT;
    if ((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) mods |= NOKRE_MOD_META;
    return mods;
}

// ---- IME (IMM32) ----

static void ime_composition(LPARAM lparam) {
    HIMC himc = ImmGetContext(g.hwnd);
    if (!himc) return;
    if (lparam & GCS_RESULTSTR) {
        LONG bytes = ImmGetCompositionStringW(himc, GCS_RESULTSTR, NULL, 0);
        if (bytes > 0) {
            WCHAR *wide = malloc((size_t)bytes);
            if (wide) {
                ImmGetCompositionStringW(himc, GCS_RESULTSTR, wide, (DWORD)bytes);
                int len = 0;
                char *utf8 = utf8_dup(wide, (int)(bytes / sizeof(WCHAR)), &len);
                if (utf8) {
                    g.config.on_ime_commit(g.config.ctx, utf8, (size_t)len);
                    free(utf8);
                }
                free(wide);
            }
        }
        g.composing = 0;
    }
    if (lparam & GCS_COMPSTR) {
        LONG bytes = ImmGetCompositionStringW(himc, GCS_COMPSTR, NULL, 0);
        if (bytes > 0) {
            WCHAR *wide = malloc((size_t)bytes);
            if (wide) {
                ImmGetCompositionStringW(himc, GCS_COMPSTR, wide, (DWORD)bytes);
                int wide_len = (int)(bytes / sizeof(WCHAR));
                // IMM reports the caret in UTF-16 units; convert to the
                // UTF-8 byte offset core renders the caret at.
                LONG cur = ImmGetCompositionStringW(himc, GCS_CURSORPOS, NULL, 0);
                if (cur < 0) cur = 0;
                if (cur > wide_len) cur = wide_len;
                int cursor = cur == 0 ? 0
                                      : WideCharToMultiByte(CP_UTF8, 0, wide, (int)cur,
                                                            NULL, 0, NULL, NULL);
                int len = 0;
                char *utf8 = utf8_dup(wide, wide_len, &len);
                if (utf8) {
                    g.config.on_ime_update(g.config.ctx, utf8, (size_t)len, (size_t)cursor);
                    free(utf8);
                }
                free(wide);
            }
            g.composing = 1;
        } else if (g.composing) {
            g.config.on_ime_update(g.config.ctx, "", 0, 0);
        }
    }
    ImmReleaseContext(g.hwnd, himc);
    maybe_repaint();
}

// Defined with the other service hooks below; wnd_proc forwards to them.
static void nokre_deep_link_dispatch(const char *utf8, size_t len);
static void locale_settings_changed(void);

// ---- window procedure ----

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            paint(hdc);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1; // every pixel is painted; skipping the erase avoids flicker
        case WM_SIZE:
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        case WM_DPICHANGED: {
            g.scale = scale_of(HIWORD(wparam));
            const RECT *suggested = (const RECT *)lparam;
            SetWindowPos(hwnd, NULL, suggested->left, suggested->top,
                         suggested->right - suggested->left,
                         suggested->bottom - suggested->top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        }
        case NOKRE_WM_REQUEST_FRAME:
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        case NOKRE_WM_POST_MAIN:
            ((void (*)(void *))(uintptr_t)wparam)((void *)lparam);
            return 0;
        case WM_COPYDATA: {
            // A second launch (protocol activation while we run) forwarded
            // a deep-link URL rather than stacking a duplicate window —
            // Android's onNewIntent, done with the tools an unpackaged
            // Win32 app has. Route it and surface the window the OS just
            // "opened", restoring it if the user had it minimized.
            const COPYDATASTRUCT *cds = (const COPYDATASTRUCT *)lparam;
            if (cds && cds->dwData == NOKRE_DEEP_LINK_COPYDATA && cds->lpData &&
                cds->cbData > 0) {
                nokre_deep_link_dispatch((const char *)cds->lpData, cds->cbData);
                if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
                SetForegroundWindow(hwnd);
            }
            return TRUE;
        }

        case WM_LBUTTONDOWN:
            SetFocus(hwnd);
            // Capture for the whole press: without it a release outside
            // the window never arrives, and the press would hang armed
            // until the next unrelated click landed on it.
            SetCapture(hwnd);
            g.config.on_pointer(g.config.ctx, GET_X_LPARAM(lparam) / g.scale,
                                GET_Y_LPARAM(lparam) / g.scale, NOKRE_POINTER_DOWN);
            maybe_repaint();
            return 0;
        case WM_MOUSEMOVE:
            // Only between a press and its release: a bare pointer
            // crossing the window is not an event nokre has.
            if (GetCapture() == hwnd) {
                g.config.on_pointer(g.config.ctx, GET_X_LPARAM(lparam) / g.scale,
                                    GET_Y_LPARAM(lparam) / g.scale, NOKRE_POINTER_MOVE);
                maybe_repaint();
            }
            return 0;
        case WM_LBUTTONUP:
            g.releasing_capture = 1;
            ReleaseCapture();
            g.releasing_capture = 0;
            g.config.on_pointer(g.config.ctx, GET_X_LPARAM(lparam) / g.scale,
                                GET_Y_LPARAM(lparam) / g.scale, NOKRE_POINTER_UP);
            maybe_repaint();
            return 0;
        // The system took the capture away (an Alt+Tab, a system modal):
        // the press is over and it activates nothing.
        case WM_CAPTURECHANGED:
            if (!g.releasing_capture) {
                g.config.on_pointer(g.config.ctx, 0, 0, NOKRE_POINTER_CANCEL);
                maybe_repaint();
            }
            return 0;
        case WM_MOUSEWHEEL:
        case WM_MOUSEHWHEEL: {
            POINT p = { GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam) };
            ScreenToClient(hwnd, &p);
            // 48 logical px per 120-unit notch (three body-text lines);
            // remainders accumulate so precision wheels never drop motion.
            int *rem = msg == WM_MOUSEWHEEL ? &g.wheel_rem_y : &g.wheel_rem_x;
            // Wheel-forward is negative content motion, like macOS
            // negates scrollingDeltaY; the horizontal wheel already
            // reports rightward tilt as positive.
            int sign = msg == WM_MOUSEWHEEL ? -1 : 1;
            *rem += sign * GET_WHEEL_DELTA_WPARAM(wparam) * 48;
            int delta = *rem / WHEEL_DELTA;
            *rem -= delta * WHEEL_DELTA;
            if (delta != 0) {
                g.config.on_scroll(g.config.ctx, p.x / g.scale, p.y / g.scale,
                                   msg == WM_MOUSEHWHEEL ? delta : 0,
                                   msg == WM_MOUSEWHEEL ? delta : 0, NOKRE_SCROLL_FREE);
                maybe_repaint();
            }
            return 0;
        }

        case WM_KEYDOWN:
        case WM_SYSKEYDOWN: {
            int32_t key = key_from_vk(wparam);
            // Mid-composition control keys belong to the IME.
            if (key == 0 || g.composing) break;
            if (key == NOKRE_KEY_SPACE) {
                // Space goes down one leg per press (shell.h). A focused
                // field takes the WM_CHAR that follows, so the key is not
                // sent at all; otherwise the key activates and that
                // WM_CHAR is latched off. The choice must be made here,
                // before activation can move focus into a field of its
                // own (a `select` opening a filtered picker) and make the
                // WM_CHAR look wanted.
                if (g.config.wants_text_input(g.config.ctx)) break;
                // Only an unmodified Space echoes as a plain space worth
                // dropping; Ctrl+Space yields NUL and Alt+Space is the
                // system menu, neither of which reaches send_char.
                if (!(current_mods() & (NOKRE_MOD_CTRL | NOKRE_MOD_ALT | NOKRE_MOD_META)))
                    g.space_activated = 1;
            }
            g.config.on_key(g.config.ctx, key, current_mods());
            maybe_repaint();
            // Printable text still arrives via WM_CHAR after
            // TranslateMessage; send_char filters the control characters
            // these keys would echo, so nothing fires twice.
            return msg == WM_KEYDOWN ? 0 : DefWindowProcW(hwnd, msg, wparam, lparam);
        }
        case WM_CHAR:
        case WM_SYSCHAR:
            if (!g.composing) send_char((WCHAR)wparam);
            return 0;

        case WM_IME_STARTCOMPOSITION:
            g.composing = 1;
            return 0; // suppress the IME's own composition window; core renders inline
        case WM_IME_COMPOSITION:
            ime_composition(lparam);
            return 0; // handled fully; DefWindowProc would echo WM_IME_CHARs
        case WM_IME_ENDCOMPOSITION:
            if (g.composing) {
                g.composing = 0;
                g.config.on_ime_cancel(g.config.ctx);
                maybe_repaint();
            }
            break;
        case WM_IME_SETCONTEXT:
            // Keep the candidate list, drop the composition window.
            return DefWindowProcW(hwnd, msg, wparam,
                                  lparam & ~ISC_SHOWUICOMPOSITIONWINDOW);

        case WM_SETFOCUS:
            g.config.on_window_focus(g.config.ctx, 1);
            return 0;
        case WM_KILLFOCUS:
            g.config.on_window_focus(g.config.ctx, 0);
            return 0;
        case WM_SETTINGCHANGE:
            if (lparam != 0 && lstrcmpW((const WCHAR *)lparam, L"ImmersiveColorSet") == 0) {
                report_appearance();
                maybe_repaint();
            } else if (lparam != 0 && lstrcmpW((const WCHAR *)lparam, L"intl") == 0) {
                // The one locale signal Win32 broadcasts, and it covers
                // the whole regional page — date order, decimal
                // separator, display language. locale_settings_changed
                // sorts out which of those we actually care about.
                locale_settings_changed();
            }
            break;

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        default:
            break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---- shell.h free functions ----

void nokre_shell_request_frame(void *view) {
    PostMessageW((HWND)view, NOKRE_WM_REQUEST_FRAME, 0, 0);
}

void nokre_shell_post_main(void *view, void (*work)(void *ctx), void *ctx) {
    PostMessageW((HWND)view, NOKRE_WM_POST_MAIN, (WPARAM)(uintptr_t)work, (LPARAM)ctx);
}

void nokre_shell_write_clipboard(const char *utf8, size_t len) {
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, NULL, 0);
    // 0 is the failure return (never negative); an empty write also
    // lands here, and skipping it beats allocating a zero-char global.
    if (wide_len <= 0) return;
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, ((size_t)wide_len + 1) * sizeof(WCHAR));
    if (!handle) return;
    WCHAR *wide = GlobalLock(handle);
    if (!wide) {
        GlobalFree(handle);
        return;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, wide, wide_len);
    wide[wide_len] = 0;
    GlobalUnlock(handle);
    if (!OpenClipboard(g.hwnd)) {
        GlobalFree(handle);
        return;
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, handle)) GlobalFree(handle);
    CloseClipboard();
}

// The platform's one launcher — oauth's loopback leg names this symbol
// rather than keeping a second ShellExecuteW copy (open_url.h states
// the coupling).
int nokre_open_url_open(const char *url, size_t len) {
    if (len == 0 || len > INT_MAX) return 1;
    // ShellExecuteW, not ShellExecuteA: the URL is UTF-8 and the ANSI
    // entry point would mangle any non-ASCII byte in a state parameter.
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, url, (int)len, NULL, 0);
    if (wide_len <= 0) return 1;
    WCHAR *wide = (WCHAR *)calloc((size_t)wide_len + 1, sizeof(WCHAR));
    if (wide == NULL) return 1;
    MultiByteToWideChar(CP_UTF8, 0, url, (int)len, wide, wide_len);
    wide[wide_len] = L'\0';
    // The documented success test: a return value above 32. Anything at
    // or below it is one of the legacy error codes, and none of them is
    // worth distinguishing — the caller gets "no browser could be
    // launched" either way, which is the only thing it can act on.
    HINSTANCE rc = ShellExecuteW(NULL, L"open", wide, NULL, NULL, SW_SHOWNORMAL);
    free(wide);
    return ((INT_PTR)rc > 32) ? 0 : 1;
}

// ---- share service outbound hook ----
// (docs/services.md; src/services/share/share.h). The share pane is
// WinRT UI, reachable from Win32 through IDataTransferManagerInterop —
// the OS's own bridge for exactly this HWND-hosted case, no packaging
// identity required (unlike the store, which is why iap answers false
// here and share does not). Two costs follow, both taken in the open:
//
// - mingw ships no Windows.ApplicationModel.DataTransfer header and no
//   combase import library, so the four combase entry points are bound
//   at first use and the five interfaces are declared here, answering
//   to the SDK IDL (Windows.ApplicationModel.datatransfer.idl) — the
//   uuids are copied digit-for-digit, and the one GUID the IDL cannot
//   state, the parameterized TypedEventHandler<DataTransferManager,
//   DataRequestedEventArgs>, is the RFC 4122 v5 hash the WinRT
//   pinterface rules define (namespace 11f47ad5-7b73-42c0-abae-
//   878b1e16adee over the pinterface signature). A machine without
//   combase.dll simply never shows the pane — fire-and-forget's line.
// - the pane pulls: ShowShareUI raises DataRequested and the handler
//   fills the package then, after this hook returned. So the text is
//   copied into one pending slot the static handler serves — in-flight
//   call data at file scope, the deep_link-pending shape, replaced at
//   the next share and never read by anything else.

typedef void *NokreHstring; // HSTRING: an opaque handle, per hstring.h
typedef struct {
    __int64 value;
} NokreEventToken;

static const GUID nokre_iid_iunknown = {
    0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID nokre_iid_agile_object = {
    0x94EA2B94, 0xE9CC, 0x49E0, {0xC0, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90}};
static const GUID nokre_iid_dtm_interop = {
    0x3A3DCD6C, 0x3EAB, 0x43DC, {0xBC, 0xDE, 0x45, 0x67, 0x1C, 0xE8, 0x00, 0xC8}};
static const GUID nokre_iid_dtm = {
    0xA5CAEE9B, 0x8708, 0x49D1, {0x8D, 0x36, 0x67, 0xD2, 0x5A, 0x8D, 0xA0, 0x0C}};
static const GUID nokre_iid_data_requested_handler = {
    0xEC6F9CC8, 0x46D0, 0x5E0E, {0xB4, 0xD2, 0x7D, 0x77, 0x73, 0xAE, 0x37, 0xA0}};

// Only the slots this leg calls are typed; the rest are position-holding
// void pointers, because a vtable is an array and the array's shape is
// the whole contract.
typedef struct NokreShareInterop NokreShareInterop;
typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreShareInterop *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreShareInterop *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreShareInterop *);
    HRESULT(STDMETHODCALLTYPE *GetForWindow)(NokreShareInterop *, HWND, const GUID *, void **);
    HRESULT(STDMETHODCALLTYPE *ShowShareUIForWindow)(NokreShareInterop *, HWND);
} NokreShareInteropVtbl;
struct NokreShareInterop {
    const NokreShareInteropVtbl *vtbl;
};

typedef struct NokreShareDtm NokreShareDtm;
typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreShareDtm *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreShareDtm *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreShareDtm *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel; // IInspectable
    HRESULT(STDMETHODCALLTYPE *add_DataRequested)(NokreShareDtm *, void *, NokreEventToken *);
    HRESULT(STDMETHODCALLTYPE *remove_DataRequested)(NokreShareDtm *, NokreEventToken);
    void *add_TargetApplicationChosen, *remove_TargetApplicationChosen;
} NokreShareDtmVtbl;
struct NokreShareDtm {
    const NokreShareDtmVtbl *vtbl;
};

typedef struct NokreShareArgs NokreShareArgs;
typedef struct NokreShareRequest NokreShareRequest;
typedef struct NokreSharePackage NokreSharePackage;
typedef struct NokreShareProps NokreShareProps;

typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreShareArgs *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreShareArgs *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreShareArgs *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel; // IInspectable
    HRESULT(STDMETHODCALLTYPE *get_Request)(NokreShareArgs *, NokreShareRequest **);
} NokreShareArgsVtbl;
struct NokreShareArgs {
    const NokreShareArgsVtbl *vtbl;
};

typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreShareRequest *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreShareRequest *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreShareRequest *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel; // IInspectable
    HRESULT(STDMETHODCALLTYPE *get_Data)(NokreShareRequest *, NokreSharePackage **);
    void *put_Data, *get_Deadline, *FailWithDisplayText, *GetDeferral;
} NokreShareRequestVtbl;
struct NokreShareRequest {
    const NokreShareRequestVtbl *vtbl;
};

typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreSharePackage *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreSharePackage *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreSharePackage *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel; // IInspectable
    void *GetView;
    HRESULT(STDMETHODCALLTYPE *get_Properties)(NokreSharePackage *, NokreShareProps **);
    void *get_RequestedOperation, *put_RequestedOperation;
    void *add_OperationCompleted, *remove_OperationCompleted;
    void *add_Destroyed, *remove_Destroyed;
    void *SetData, *SetDataProvider;
    HRESULT(STDMETHODCALLTYPE *SetText)(NokreSharePackage *, NokreHstring);
    void *SetUri, *SetHtmlFormat, *get_ResourceMap, *SetRtf, *SetBitmap;
    void *SetStorageItemsReadOnly, *SetStorageItems;
} NokreSharePackageVtbl;
struct NokreSharePackage {
    const NokreSharePackageVtbl *vtbl;
};

typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreShareProps *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreShareProps *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreShareProps *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel; // IInspectable
    void *get_Title;
    HRESULT(STDMETHODCALLTYPE *put_Title)(NokreShareProps *, NokreHstring);
    void *get_Description, *put_Description, *get_Thumbnail, *put_Thumbnail;
    void *get_FileTypes, *get_ApplicationName, *put_ApplicationName;
    void *get_ApplicationListingUri, *put_ApplicationListingUri;
} NokreSharePropsVtbl;
struct NokreShareProps {
    const NokreSharePropsVtbl *vtbl;
};

// The DataRequested delegate: a static singleton, so AddRef/Release are
// bookkeeping-free constants — the object's lifetime is the process's,
// the macOS leg's picker posture.
typedef struct NokreShareHandler {
    const struct NokreShareHandlerVtbl *vtbl;
} NokreShareHandler;
typedef struct NokreShareHandlerVtbl {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreShareHandler *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreShareHandler *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreShareHandler *);
    HRESULT(STDMETHODCALLTYPE *Invoke)(NokreShareHandler *, NokreShareDtm *, NokreShareArgs *);
} NokreShareHandlerVtbl;

static struct {
    int tried; // combase bind attempted (success or not)
    HRESULT(WINAPI *ro_initialize)(int);
    HRESULT(WINAPI *ro_get_activation_factory)(NokreHstring, const GUID *, void **);
    HRESULT(WINAPI *windows_create_string)(const WCHAR *, UINT32, NokreHstring *);
    HRESULT(WINAPI *windows_delete_string)(NokreHstring);
    NokreShareDtm *dtm;   // GetForWindow'd once, handler attached for good
    WCHAR *pending;       // what the next DataRequested serves; NUL-terminated
    UINT32 pending_len;   // in WCHARs, excluding the NUL
} g_share;

static HRESULT STDMETHODCALLTYPE share_handler_qi(NokreShareHandler *self, const GUID *iid,
                                                  void **out) {
    if (out == NULL) return E_POINTER;
    // IAgileObject honestly: everything here happens on the UI thread's
    // STA, and declaring agility is what keeps COM from trying to
    // marshal a static object with no proxy.
    if (IsEqualGUID(iid, &nokre_iid_iunknown) || IsEqualGUID(iid, &nokre_iid_agile_object) ||
        IsEqualGUID(iid, &nokre_iid_data_requested_handler)) {
        *out = self;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE share_handler_addref(NokreShareHandler *self) {
    (void)self;
    return 2;
}

static ULONG STDMETHODCALLTYPE share_handler_release(NokreShareHandler *self) {
    (void)self;
    return 1;
}

static HRESULT STDMETHODCALLTYPE share_handler_invoke(NokreShareHandler *self, NokreShareDtm *dtm,
                                                      NokreShareArgs *args) {
    (void)self;
    (void)dtm;
    if (args == NULL || g_share.pending == NULL) return S_OK;
    NokreShareRequest *request = NULL;
    if (FAILED(args->vtbl->get_Request(args, &request)) || request == NULL) return S_OK;
    NokreSharePackage *package = NULL;
    if (SUCCEEDED(request->vtbl->get_Data(request, &package)) && package != NULL) {
        // The pane refuses a package without a title; the window text is
        // the app's own declared name, not an invented string.
        NokreShareProps *props = NULL;
        if (SUCCEEDED(package->vtbl->get_Properties(package, &props)) && props != NULL) {
            WCHAR title[256];
            int title_len = GetWindowTextW(g.hwnd, title, 256);
            NokreHstring title_h = NULL;
            if (SUCCEEDED(g_share.windows_create_string(title, (UINT32)(title_len < 0 ? 0 : title_len),
                                                        &title_h))) {
                props->vtbl->put_Title(props, title_h);
                g_share.windows_delete_string(title_h);
            }
            props->vtbl->Release(props);
        }
        NokreHstring text_h = NULL;
        if (SUCCEEDED(g_share.windows_create_string(g_share.pending, g_share.pending_len, &text_h))) {
            package->vtbl->SetText(package, text_h);
            g_share.windows_delete_string(text_h);
        }
        package->vtbl->Release(package);
    }
    request->vtbl->Release(request);
    return S_OK;
}

static const NokreShareHandlerVtbl g_share_handler_vtbl = {
    share_handler_qi, share_handler_addref, share_handler_release, share_handler_invoke};
static NokreShareHandler g_share_handler = {&g_share_handler_vtbl};

// One-time setup: bind combase, init WinRT, GetForWindow, attach the
// handler. NULL dtm afterwards means some step refused and the pane
// stays silent forever — this session has no share host, xdg-open's
// failure signal.
static NokreShareDtm *share_dtm(void) {
    if (g_share.tried) return g_share.dtm;
    g_share.tried = 1;
    HMODULE combase = LoadLibraryW(L"combase.dll");
    if (combase == NULL) return NULL;
    g_share.ro_initialize = (HRESULT(WINAPI *)(int))(void *)GetProcAddress(combase, "RoInitialize");
    g_share.ro_get_activation_factory =
        (HRESULT(WINAPI *)(NokreHstring, const GUID *, void **))(void *)GetProcAddress(
            combase, "RoGetActivationFactory");
    g_share.windows_create_string = (HRESULT(WINAPI *)(const WCHAR *, UINT32, NokreHstring *))(
        void *)GetProcAddress(combase, "WindowsCreateString");
    g_share.windows_delete_string =
        (HRESULT(WINAPI *)(NokreHstring))(void *)GetProcAddress(combase, "WindowsDeleteString");
    if (!g_share.ro_initialize || !g_share.ro_get_activation_factory ||
        !g_share.windows_create_string || !g_share.windows_delete_string)
        return NULL;
    // S_FALSE (already initialized) and RPC_E_CHANGED_MODE (the thread
    // is COM-initialized in another mode) both leave activation working.
    HRESULT hr = g_share.ro_initialize(0 /* RO_INIT_SINGLETHREADED */);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return NULL;
    static const WCHAR class_name[] = L"Windows.ApplicationModel.DataTransfer.DataTransferManager";
    NokreHstring class_h = NULL;
    if (FAILED(g_share.windows_create_string(class_name, (UINT32)(wcslen(class_name)), &class_h)))
        return NULL;
    NokreShareInterop *interop = NULL;
    hr = g_share.ro_get_activation_factory(class_h, &nokre_iid_dtm_interop, (void **)&interop);
    g_share.windows_delete_string(class_h);
    if (FAILED(hr) || interop == NULL) return NULL;
    NokreShareDtm *dtm = NULL;
    if (SUCCEEDED(interop->vtbl->GetForWindow(interop, g.hwnd, &nokre_iid_dtm, (void **)&dtm)) &&
        dtm != NULL) {
        NokreEventToken token = {0};
        if (FAILED(dtm->vtbl->add_DataRequested(dtm, &g_share_handler, &token))) {
            dtm->vtbl->Release(dtm);
            dtm = NULL;
        }
    }
    interop->vtbl->Release(interop);
    g_share.dtm = dtm;
    return dtm;
}

void nokre_share_show(const char *text, size_t len) {
    if (len == 0 || len > INT_MAX || g.hwnd == NULL) return;
    NokreShareDtm *dtm = share_dtm();
    if (dtm == NULL) return;
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, text, (int)len, NULL, 0);
    if (wide_len <= 0) return;
    WCHAR *wide = (WCHAR *)calloc((size_t)wide_len + 1, sizeof(WCHAR));
    if (wide == NULL) return;
    MultiByteToWideChar(CP_UTF8, 0, text, (int)len, wide, wide_len);
    wide[wide_len] = L'\0';
    free(g_share.pending);
    g_share.pending = wide;
    g_share.pending_len = (UINT32)wide_len;
    // The pane raises DataRequested — usually inside this call, but the
    // contract is only "after it" — and the handler serves `pending`.
    NokreShareInterop *interop = NULL;
    NokreHstring class_h = NULL;
    static const WCHAR class_name[] = L"Windows.ApplicationModel.DataTransfer.DataTransferManager";
    if (FAILED(g_share.windows_create_string(class_name, (UINT32)(wcslen(class_name)), &class_h)))
        return;
    HRESULT hr = g_share.ro_get_activation_factory(class_h, &nokre_iid_dtm_interop, (void **)&interop);
    g_share.windows_delete_string(class_h);
    if (FAILED(hr) || interop == NULL) return;
    interop->vtbl->ShowShareUIForWindow(interop, g.hwnd);
    interop->vtbl->Release(interop);
}

// ---- deep_link service inbound hook ----
// (docs/services.md; src/services/deep_link/deep_link.h). The single-app
// anchor, like the macOS shell: one app per process, so the installed
// ctx + callback live at file scope. A URL that arrives before the app
// registers its handler — the launch URL, parsed off the command line in
// nokre_shell_run before the first paint runs the app's build/setHandler —
// is buffered here and flushed on install, so it is never dropped. Windows
// has no verified https App-Link for an unpackaged app (that is MSIX's
// windows.appUriHandler, a different packaging model); the URL arrives via
// a custom scheme the developer registers, so packaging derives nothing
// here — the scheme-agnostic posture docs/services.md states.
static void *g_deep_link_ctx = NULL;
static nokre_deep_link_cb g_deep_link_cb = NULL;
static char *g_deep_link_pending = NULL; // heap UTF-8, or NULL
static size_t g_deep_link_pending_len = 0;

static void nokre_deep_link_dispatch(const char *utf8, size_t len) {
    if (g_deep_link_cb == NULL) {
        // Not yet installed: keep the most recent URL until the app wires
        // its handler. malloc(1) for an empty URL so the pointer is a
        // buffered-present marker, never a mistaken NULL.
        free(g_deep_link_pending);
        g_deep_link_pending = malloc(len ? len : 1);
        if (!g_deep_link_pending) {
            g_deep_link_pending_len = 0;
            return;
        }
        memcpy(g_deep_link_pending, utf8, len);
        g_deep_link_pending_len = len;
        return;
    }
    g_deep_link_cb(g_deep_link_ctx, utf8, len);
    // The handler routed and invalidated like any action; mark the view
    // dirty so the on-demand loop paints the result (worker-pump rule).
    if (g.hwnd) InvalidateRect(g.hwnd, NULL, FALSE);
}

void nokre_deep_link_install(void *ctx, nokre_deep_link_cb cb) {
    g_deep_link_ctx = ctx;
    g_deep_link_cb = cb;
    if (g_deep_link_pending != NULL) {
        char *url = g_deep_link_pending;
        size_t len = g_deep_link_pending_len;
        g_deep_link_pending = NULL;
        g_deep_link_pending_len = 0;
        cb(ctx, url, len);
        free(url);
    }
}

void nokre_deep_link_uninstall(void) {
    // Back to the pre-install posture: a URL that arrives now is
    // buffered for the next install, never delivered into per-app state
    // the app has already freed.
    g_deep_link_ctx = NULL;
    g_deep_link_cb = NULL;
}

// ---- locale service inbound hook ----
// (docs/services.md; src/services/locale/locale.h). The same single-app
// anchor as deep_link, minus the pending buffer: unlike a launch URL
// there is nothing here to miss, because the device locale is readable
// on demand. That is what lets install answer synchronously, which is
// the whole contract — the app's first build must already know which
// language to render.
static void *g_locale_ctx = NULL;
static nokre_locale_cb g_locale_cb = NULL;
// The last tag handed to Zig, kept only so the WM_SETTINGCHANGE leg can
// tell a real language change from the unrelated regional edits that
// message also carries. Sized by the Win32 ceiling on a locale name, not
// by the service's own cap — that cap is Zig's policy and has one home.
static char g_locale_tag[LOCALE_NAME_MAX_LENGTH * 4];
static size_t g_locale_tag_len = 0;

// The user's preferred UI language as a BCP 47 tag in UTF-8, written to
// `out`, returning its length — or 0 when Windows names none, which is
// the contract's empty "unknown" tag. Never substitutes an "en": which
// language an unknown locale means is the app's decision, not ours.
static size_t current_locale_utf8(char *out, size_t cap) {
    // The MUI language list, not GetUserDefaultLocaleName: that one is
    // the *formatting* locale (dates, numbers, currency), which a user
    // may set independently of the language they read — an English UI
    // with German formats is an ordinary setup — and it is the reading
    // language that must choose the bundle. MUI_LANGUAGE_NAME spells the
    // entries as BCP 47 names ("en-US", "zh-Hans-CN"), most preferred
    // first, double-NUL terminated.
    WCHAR wide[512];
    ULONG count = 0, chars = (ULONG)(sizeof(wide) / sizeof(wide[0]));
    const WCHAR *name = NULL;
    if (GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, wide, &chars) &&
        count > 0 && wide[0] != 0) {
        name = wide; // the first entry, NUL-terminated inside the list
    } else if (GetUserDefaultLocaleName(wide, LOCALE_NAME_MAX_LENGTH) > 0 &&
               wide[0] != 0) {
        // Only when that list is unreadable (an over-long preference
        // list overflows the buffer): the formatting locale names the
        // same language often enough to beat reporting nothing.
        name = wide;
    }
    if (!name) return 0;
    int len = WideCharToMultiByte(CP_UTF8, 0, name, (int)wcslen(name), out,
                                  (int)cap, NULL, NULL);
    // A name too long for the buffer comes back as 0, and empty is the
    // right answer for it: an empty tag resolves to the app's template
    // language, where a truncated one could resolve to a wrong one.
    return len > 0 ? (size_t)len : 0;
}

// WM_SETTINGCHANGE "intl" fires for any edit on the regional page, most
// of which leave the display language alone, so re-read and report only
// when the bytes actually differ — otherwise a change to the short-date
// format would wake a frame and re-run the app's handler for nothing.
static void locale_settings_changed(void) {
    if (g_locale_cb == NULL) return;
    char tag[sizeof(g_locale_tag)];
    size_t len = current_locale_utf8(tag, sizeof(tag));
    if (len == g_locale_tag_len && memcmp(tag, g_locale_tag, len) == 0) return;
    memcpy(g_locale_tag, tag, len);
    g_locale_tag_len = len;
    g_locale_cb(g_locale_ctx, tag, len);
    // wnd_proc is the UI thread, so the handler has already run and
    // invalidated whatever it owns; mark the view dirty so the on-demand
    // loop paints the result, as the deep-link dispatch does.
    if (g.hwnd) InvalidateRect(g.hwnd, NULL, FALSE);
}

void nokre_locale_install(void *ctx, nokre_locale_cb cb) {
    g_locale_ctx = ctx;
    g_locale_cb = cb;
    g_locale_tag_len = current_locale_utf8(g_locale_tag, sizeof(g_locale_tag));
    // Synchronously, before returning, as the header promises. This runs
    // inside App.init, so there is no window yet and nothing to
    // invalidate — the first paint is already on its way.
    cb(ctx, g_locale_tag, g_locale_tag_len);
}

void nokre_locale_uninstall(void) {
    // WM_SETTINGCHANGE keeps arriving; with the callback gone,
    // locale_settings_changed drops the change instead of calling into
    // per-app state the app has already freed.
    g_locale_ctx = NULL;
    g_locale_cb = NULL;
}

// ---- notification service (docs/internals/notifications.md) ----
// Toasts through WinRT, reached the way the share pane above is reached:
// mingw ships no Windows.UI.Notifications header and no combase import
// library, so the entry points bind at first use and the interfaces are
// declared here against the SDK IDL, uuids copied digit-for-digit. The
// share pane's two costs, paid once more — and, unlike the share pane,
// one cost that is nokre's own.
//
// **This shell registers itself, and that is a narrowing of deep_link's
// refusal.** An unpackaged Win32 app has no toast identity: Windows keys
// notifications to an AppUserModelID, and a tap can only reach a
// *closed* app through a COM server registered under a CLSID. deep_link
// declined to write `HKCU\Software\Classes` and said the registration
// belongs to the app or its installer — which is right for a URL scheme
// any app may claim, and wrong here, because this identity is the app's
// own name for its own notifications and nothing else can claim it. The
// reversal is recorded, owner-decided, in docs/internals/notifications.md,
// and it is scoped to exactly these two keys: a shell that grows a third
// registration is a bug.
//
// The activator is what makes the tap work when the app is closed, and
// it is also why no `Activated` event handler is attached to individual
// toasts: Windows delivers a tap to the registered callback whether the
// process is running or not, so one path serves both.

typedef struct {
    __int64 UniversalTime;
} NokreDateTime;

static const GUID nokre_iid_inspectable = {
    0xAF86E2E0, 0xB12D, 0x4C6A, {0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90}};
static const GUID nokre_iid_class_factory = {
    0x00000001, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID nokre_iid_notification_activation_callback = {
    0x53E31837, 0x6600, 0x4A81, {0x93, 0x95, 0x75, 0xCF, 0xFE, 0x74, 0x6F, 0x94}};
static const GUID nokre_iid_toast_manager_statics = {
    0x50AC103F, 0xD235, 0x4598, {0xBB, 0xEF, 0x98, 0xFE, 0x4D, 0x1A, 0x3A, 0xD4}};
static const GUID nokre_iid_toast_notifier = {
    0x75927B93, 0x03F3, 0x41EC, {0x91, 0xD3, 0x6E, 0x5B, 0xAC, 0x1B, 0x38, 0xE7}};
static const GUID nokre_iid_toast_factory = {
    0x04124B20, 0x82C6, 0x4229, {0xB1, 0x09, 0xFD, 0x9E, 0xD4, 0x66, 0x2B, 0x53}};
static const GUID nokre_iid_scheduled_toast_factory = {
    0xE7B7CE3D, 0xA8DA, 0x45BD, {0x9F, 0x0C, 0x5D, 0xBC, 0x3A, 0x6D, 0x0F, 0xD3}};
static const GUID nokre_iid_xml_document_io = {
    0x6CD0E74E, 0xEE65, 0x4489, {0x9E, 0xBF, 0xCA, 0x43, 0xE8, 0x7B, 0xA6, 0x37}};

// nokre's own activator CLSID. A fixed uuid rather than one derived from
// the app id: the CLSID names *this shell's* callback implementation,
// which is the same code in every nokre app, and the AppUserModelID —
// which is the app's — is what keeps two nokre apps' notifications
// apart. Windows looks the callback up by CLSID only after matching the
// AUMID, so one is an implementation and the other is the identity.
static const GUID nokre_clsid_activator = {
    0x6E6F6B72, 0x6531, 0x4E6F, {0x74, 0x69, 0x66, 0x79, 0x41, 0x63, 0x74, 0x76}};

// Only the slots this leg calls are typed; the rest are position-holding
// void pointers, because a vtable is an array and the array's shape is
// the whole contract (the share pane's rule).
typedef struct NokreXmlDoc NokreXmlDoc;
typedef struct {
    void *QueryInterface, *AddRef;
    ULONG(STDMETHODCALLTYPE *Release)(NokreXmlDoc *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel;
    HRESULT(STDMETHODCALLTYPE *LoadXml)(NokreXmlDoc *, NokreHstring);
} NokreXmlDocIoVtbl;
struct NokreXmlDoc {
    const NokreXmlDocIoVtbl *vtbl;
};

typedef struct NokreToast NokreToast;
struct NokreToast {
    void *vtbl;
};

typedef struct NokreToastFactory NokreToastFactory;
typedef struct {
    void *QueryInterface, *AddRef;
    ULONG(STDMETHODCALLTYPE *Release)(NokreToastFactory *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel;
    HRESULT(STDMETHODCALLTYPE *CreateToastNotification)(NokreToastFactory *, void *, NokreToast **);
} NokreToastFactoryVtbl;
struct NokreToastFactory {
    const NokreToastFactoryVtbl *vtbl;
};

typedef struct NokreSchedFactory NokreSchedFactory;
typedef struct {
    void *QueryInterface, *AddRef;
    ULONG(STDMETHODCALLTYPE *Release)(NokreSchedFactory *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel;
    HRESULT(STDMETHODCALLTYPE *CreateScheduledToastNotification)(NokreSchedFactory *, void *,
                                                                 NokreDateTime, NokreToast **);
} NokreSchedFactoryVtbl;
struct NokreSchedFactory {
    const NokreSchedFactoryVtbl *vtbl;
};

typedef struct NokreToastManager NokreToastManager;
typedef struct {
    void *QueryInterface, *AddRef;
    ULONG(STDMETHODCALLTYPE *Release)(NokreToastManager *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel;
    void *CreateToastNotifier;
    HRESULT(STDMETHODCALLTYPE *CreateToastNotifierWithId)(NokreToastManager *, NokreHstring,
                                                          void **);
    void *GetTemplateContent;
} NokreToastManagerVtbl;
struct NokreToastManager {
    const NokreToastManagerVtbl *vtbl;
};

typedef struct NokreNotifier NokreNotifier;
typedef struct {
    void *QueryInterface, *AddRef;
    ULONG(STDMETHODCALLTYPE *Release)(NokreNotifier *);
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel;
    HRESULT(STDMETHODCALLTYPE *Show)(NokreNotifier *, NokreToast *);
    HRESULT(STDMETHODCALLTYPE *Hide)(NokreNotifier *, NokreToast *);
    void *get_Setting;
    HRESULT(STDMETHODCALLTYPE *AddToSchedule)(NokreNotifier *, NokreToast *);
    HRESULT(STDMETHODCALLTYPE *RemoveFromSchedule)(NokreNotifier *, NokreToast *);
    void *GetScheduledToastNotifications;
} NokreNotifierVtbl;
struct NokreNotifier {
    const NokreNotifierVtbl *vtbl;
};

// One live notification per id, so `cancel` has something to Hide and a
// repeat post replaces rather than stacks. 32 is the Linux table's
// number and the same argument: more than this showing at once is a
// notification centre, not a slot shortage.
#define NOKRE_NOTE_SLOTS 32

static struct {
    int tried;
    HRESULT(WINAPI *ro_get_activation_factory)(NokreHstring, const GUID *, void **);
    HRESULT(WINAPI *ro_activate_instance)(NokreHstring, void **);
    NokreNotifier *notifier;
    void *ctx;
    nokre_notification_cb cb;
    WCHAR aumid[128];
    DWORD registration; // CoRegisterClassObject cookie, 0 = not registered
    struct {
        char id[64];
        size_t id_len;
        NokreToast *toast;
        int scheduled;
    } live[NOKRE_NOTE_SLOTS];
    // The tap that started the process: Windows activates the COM server
    // before nokre_shell_run has reached the app's first build, so the
    // event waits here — the deep_link launch-URL buffer, one service
    // over.
    char pending_id[64];
    size_t pending_id_len;
    char pending_route[256];
    size_t pending_route_len;
    int has_pending;
} g_note;

static void note_dispatch(int32_t kind, int32_t status, const char *a, size_t a_len, const char *b,
                          size_t b_len) {
    if (g_note.cb == NULL) {
        if (kind != NOKRE_NOTIFICATION_OPENED) return;
        if (a_len >= sizeof g_note.pending_id || b_len >= sizeof g_note.pending_route) return;
        memcpy(g_note.pending_id, a, a_len);
        g_note.pending_id_len = a_len;
        memcpy(g_note.pending_route, b, b_len);
        g_note.pending_route_len = b_len;
        g_note.has_pending = 1;
        return;
    }
    g_note.cb(g_note.ctx, kind, status, a, a_len, b, b_len);
}

// The toast's `launch` string, parsed back: "<id>\x1f<route>". A unit
// separator rather than a URL query, because neither half is a URL and
// percent-encoding a route reference would be inventing a format for a
// string that crosses only nokre's own two ends.
static void note_activated(const WCHAR *args) {
    if (args == NULL) return;
    char utf8[512];
    int len = WideCharToMultiByte(CP_UTF8, 0, args, -1, utf8, (int)sizeof utf8, NULL, NULL);
    if (len <= 1) return;
    size_t total = (size_t)len - 1; // drop the NUL WideCharToMultiByte wrote
    const char *sep = memchr(utf8, 0x1F, total);
    size_t id_len = sep == NULL ? total : (size_t)(sep - utf8);
    const char *route = sep == NULL ? utf8 + total : sep + 1;
    size_t route_len = sep == NULL ? 0 : total - id_len - 1;
    note_dispatch(NOKRE_NOTIFICATION_OPENED, NOKRE_NOTIFICATION_GRANTED, utf8, id_len, route,
                  route_len);
    // The tap may have started this process, in which case there is no
    // window yet and the frame request is a no-op; when there is one, the
    // handler routed and invalidated like any action.
    nokre_shell_request_frame(NULL);
}

// INotificationActivationCallback: the whole reason the CLSID exists.
// Windows calls this for a tap whether the app is running (in-process,
// through the class object registered below) or closed (a fresh process,
// started from LocalServer32).
typedef struct NokreActivator NokreActivator;
typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreActivator *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreActivator *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreActivator *);
    HRESULT(STDMETHODCALLTYPE *Activate)(NokreActivator *, LPCWSTR, LPCWSTR, const void *, ULONG);
} NokreActivatorVtbl;
struct NokreActivator {
    const NokreActivatorVtbl *vtbl;
};

static HRESULT STDMETHODCALLTYPE activator_qi(NokreActivator *self, const GUID *iid, void **out) {
    if (out == NULL) return E_POINTER;
    if (IsEqualGUID(iid, &nokre_iid_iunknown) ||
        IsEqualGUID(iid, &nokre_iid_notification_activation_callback)) {
        *out = self;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

// Static lifetime, like the share handler's: refcounts that never reach
// zero are the honest answer for an object that lives as long as the
// process and is owned by this file.
static ULONG STDMETHODCALLTYPE activator_addref(NokreActivator *self) {
    (void)self;
    return 2;
}

static ULONG STDMETHODCALLTYPE activator_release(NokreActivator *self) {
    (void)self;
    return 1;
}

static HRESULT STDMETHODCALLTYPE activator_activate(NokreActivator *self, LPCWSTR app_id,
                                                    LPCWSTR args, const void *data, ULONG count) {
    (void)self;
    (void)app_id;
    (void)data;
    (void)count; // no input fields: nokre draws no text box in a toast
    note_activated(args);
    return S_OK;
}

static const NokreActivatorVtbl g_activator_vtbl = {activator_qi, activator_addref,
                                                    activator_release, activator_activate};
static NokreActivator g_activator = {&g_activator_vtbl};

// The class object COM asks for the activator through.
typedef struct NokreActivatorFactory NokreActivatorFactory;
typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(NokreActivatorFactory *, const GUID *, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(NokreActivatorFactory *);
    ULONG(STDMETHODCALLTYPE *Release)(NokreActivatorFactory *);
    HRESULT(STDMETHODCALLTYPE *CreateInstance)(NokreActivatorFactory *, IUnknown *, const GUID *,
                                               void **);
    HRESULT(STDMETHODCALLTYPE *LockServer)(NokreActivatorFactory *, BOOL);
} NokreActivatorFactoryVtbl;
struct NokreActivatorFactory {
    const NokreActivatorFactoryVtbl *vtbl;
};

static HRESULT STDMETHODCALLTYPE factory_qi(NokreActivatorFactory *self, const GUID *iid,
                                            void **out) {
    if (out == NULL) return E_POINTER;
    if (IsEqualGUID(iid, &nokre_iid_iunknown) || IsEqualGUID(iid, &nokre_iid_class_factory)) {
        *out = self;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE factory_addref(NokreActivatorFactory *self) {
    (void)self;
    return 2;
}

static ULONG STDMETHODCALLTYPE factory_release(NokreActivatorFactory *self) {
    (void)self;
    return 1;
}

static HRESULT STDMETHODCALLTYPE factory_create(NokreActivatorFactory *self, IUnknown *outer,
                                                const GUID *iid, void **out) {
    (void)self;
    if (outer != NULL) return CLASS_E_NOAGGREGATION;
    return activator_qi(&g_activator, iid, out);
}

static HRESULT STDMETHODCALLTYPE factory_lock(NokreActivatorFactory *self, BOOL lock) {
    (void)self;
    (void)lock;
    return S_OK;
}

static const NokreActivatorFactoryVtbl g_factory_vtbl = {factory_qi, factory_addref, factory_release,
                                                         factory_create, factory_lock};
static NokreActivatorFactory g_factory = {&g_factory_vtbl};

// The two registry keys, and the only two this shell will ever write.
// Both under HKCU, so no elevation and no machine-wide state: the
// notifications belong to this user's copy of this app.
//   Software\Classes\AppUserModelId\<aumid>  — the identity Windows keys
//       notifications to, plus the CLSID of the callback a tap reaches.
//   Software\Classes\CLSID\{clsid}\LocalServer32 — the exe to start when
//       a tap arrives and nothing is running.
// Written on every run rather than once: an app that moved on disk has a
// stale LocalServer32, and rewriting two small values costs less than
// the bug of a tap that starts the wrong binary.
static void note_register(const WCHAR *aumid, const WCHAR *display) {
    WCHAR clsid_text[64];
    if (StringFromGUID2(&nokre_clsid_activator, clsid_text,
                        (int)(sizeof clsid_text / sizeof clsid_text[0])) == 0)
        return;

    WCHAR key[512];
    HKEY h = NULL;
    _snwprintf(key, sizeof key / sizeof key[0], L"Software\\Classes\\AppUserModelId\\%ls", aumid);
    if (RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_WRITE, NULL, &h, NULL) ==
        ERROR_SUCCESS) {
        RegSetValueExW(h, L"DisplayName", 0, REG_SZ, (const BYTE *)display,
                       (DWORD)((wcslen(display) + 1) * sizeof(WCHAR)));
        RegSetValueExW(h, L"CustomActivator", 0, REG_SZ, (const BYTE *)clsid_text,
                       (DWORD)((wcslen(clsid_text) + 1) * sizeof(WCHAR)));
        RegCloseKey(h);
    }

    WCHAR exe[MAX_PATH];
    DWORD exe_len = GetModuleFileNameW(NULL, exe, MAX_PATH);
    if (exe_len == 0 || exe_len >= MAX_PATH) return;
    _snwprintf(key, sizeof key / sizeof key[0], L"Software\\Classes\\CLSID\\%ls\\LocalServer32",
               clsid_text);
    if (RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_WRITE, NULL, &h, NULL) ==
        ERROR_SUCCESS) {
        RegSetValueExW(h, NULL, 0, REG_SZ, (const BYTE *)exe,
                       (DWORD)((wcslen(exe) + 1) * sizeof(WCHAR)));
        RegCloseKey(h);
    }
}

// One-time setup: the AUMID, the two keys, the class object, and the
// notifier. A NULL notifier afterwards means some step refused and this
// session posts nothing — xdg-open's failure signal, which `available`
// reports before an app draws anything.
static NokreNotifier *note_notifier(void) {
    if (g_note.tried) return g_note.notifier;
    g_note.tried = 1;

    // The AUMID is the declared app id. An app with no identity gets no
    // notifications rather than a made-up name: two unidentified apps
    // sharing one AUMID would share each other's notification settings.
    if (g.config.app_id == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, g.config.app_id, -1, g_note.aumid,
                            (int)(sizeof g_note.aumid / sizeof g_note.aumid[0])) == 0)
        return NULL;

    HMODULE shell32 = LoadLibraryW(L"shell32.dll");
    if (shell32 != NULL) {
        HRESULT(WINAPI * set_aumid)(PCWSTR) = (HRESULT(WINAPI *)(PCWSTR))(void *)GetProcAddress(
            shell32, "SetCurrentProcessExplicitAppUserModelID");
        if (set_aumid != NULL) set_aumid(g_note.aumid);
    }

    WCHAR name[128];
    // The window title is the app's display name here — the same string
    // the taskbar shows — and the shell already has it.
    if (g.config.title == NULL ||
        MultiByteToWideChar(CP_UTF8, 0, g.config.title, -1, name,
                            (int)(sizeof name / sizeof name[0])) == 0) {
        wcscpy(name, g_note.aumid);
    }
    note_register(g_note.aumid, name);

    // In-process activation while the app runs. Failure is not fatal: the
    // LocalServer32 registration still carries a tap to a fresh process,
    // which is the harder half.
    CoRegisterClassObject(&nokre_clsid_activator, (IUnknown *)&g_factory, CLSCTX_LOCAL_SERVER,
                          REGCLS_MULTIPLEUSE, &g_note.registration);

    HMODULE combase = LoadLibraryW(L"combase.dll");
    if (combase == NULL) return NULL;
    g_note.ro_get_activation_factory =
        (HRESULT(WINAPI *)(NokreHstring, const GUID *, void **))(void *)GetProcAddress(
            combase, "RoGetActivationFactory");
    g_note.ro_activate_instance = (HRESULT(WINAPI *)(NokreHstring, void **))(void *)GetProcAddress(
        combase, "RoActivateInstance");
    if (!g_note.ro_get_activation_factory || !g_note.ro_activate_instance) return NULL;
    // The share pane's binder already ran RoInitialize if it was used;
    // running it again is S_FALSE, and the two legs share one apartment.
    if (share_dtm() == NULL && g_share.ro_initialize == NULL) {
        HMODULE cb2 = LoadLibraryW(L"combase.dll");
        HRESULT(WINAPI * ro_init)(int) =
            (HRESULT(WINAPI *)(int))(void *)GetProcAddress(cb2, "RoInitialize");
        if (ro_init != NULL) {
            HRESULT hr = ro_init(0 /* RO_INIT_SINGLETHREADED */);
            if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return NULL;
        }
    }

    static const WCHAR manager_class[] = L"Windows.UI.Notifications.ToastNotificationManager";
    NokreHstring class_h = NULL;
    if (!g_share.windows_create_string) return NULL;
    if (FAILED(g_share.windows_create_string(manager_class, (UINT32)wcslen(manager_class),
                                             &class_h)))
        return NULL;
    NokreToastManager *manager = NULL;
    HRESULT hr =
        g_note.ro_get_activation_factory(class_h, &nokre_iid_toast_manager_statics, (void **)&manager);
    g_share.windows_delete_string(class_h);
    if (FAILED(hr) || manager == NULL) return NULL;

    NokreHstring aumid_h = NULL;
    if (SUCCEEDED(g_share.windows_create_string(g_note.aumid, (UINT32)wcslen(g_note.aumid),
                                                &aumid_h))) {
        NokreNotifier *notifier = NULL;
        if (SUCCEEDED(manager->vtbl->CreateToastNotifierWithId(manager, aumid_h,
                                                               (void **)&notifier)))
            g_note.notifier = notifier;
        g_share.windows_delete_string(aumid_h);
    }
    manager->vtbl->Release(manager);
    return g_note.notifier;
}

// XML escaping into the toast payload. The four that matter in element
// text and attribute values; the payload is UTF-16 by the time it gets
// here, and the caps ran in Zig, so this only has to be correct.
static size_t note_xml_append(WCHAR *out, size_t cap, size_t at, const WCHAR *src) {
    for (; *src != L'\0' && at + 8 < cap; src++) {
        const WCHAR *rep = NULL;
        switch (*src) {
        case L'&': rep = L"&amp;"; break;
        case L'<': rep = L"&lt;"; break;
        case L'>': rep = L"&gt;"; break;
        case L'"': rep = L"&quot;"; break;
        default: out[at++] = *src; continue;
        }
        for (const WCHAR *r = rep; *r != L'\0'; r++) out[at++] = *r;
    }
    out[at] = L'\0';
    return at;
}

static WCHAR *note_widen(const char *utf8, size_t len, WCHAR *out, size_t cap) {
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, out, (int)cap - 1);
    out[n < 0 ? 0 : n] = L'\0';
    return out;
}

static int note_slot_of(const char *id, size_t len) {
    for (int i = 0; i < NOKRE_NOTE_SLOTS; i++) {
        if (g_note.live[i].toast != NULL && g_note.live[i].id_len == len &&
            memcmp(g_note.live[i].id, id, len) == 0)
            return i;
    }
    return -1;
}

void nokre_notification_install(void *ctx, nokre_notification_cb cb) {
    g_note.ctx = ctx;
    g_note.cb = cb;
    if (g_note.has_pending) {
        g_note.has_pending = 0;
        cb(ctx, NOKRE_NOTIFICATION_OPENED, NOKRE_NOTIFICATION_GRANTED, g_note.pending_id,
           g_note.pending_id_len, g_note.pending_route, g_note.pending_route_len);
    }
}

void nokre_notification_uninstall(void) {
    g_note.ctx = NULL;
    g_note.cb = NULL;
}

int32_t nokre_notification_available(void) { return note_notifier() != NULL ? 1 : 0; }

int32_t nokre_notification_push_available(void) {
    // WNS needs a package identity and a Store-registered app — the MSIX
    // model nokre does not emit, which is why iap answers false here too.
    return 0;
}

int32_t nokre_notification_schedule_available(void) {
    // AddToSchedule holds the date in the platform's own notification
    // queue, so it survives the app closing.
    return note_notifier() != NULL ? 1 : 0;
}

int32_t nokre_notification_status(void) {
    // Windows has no prompt and no per-app permission an app may ask
    // for: notifications are on unless the user turned them off in
    // Settings, and `IToastNotifier.Setting` reports that only as a
    // best-effort hint. So a working notifier is granted, and there is
    // never a prompt for the app to draw.
    return note_notifier() != NULL ? NOKRE_NOTIFICATION_GRANTED
                                   : NOKRE_NOTIFICATION_NOT_DETERMINED;
}

void nokre_notification_authorize(void) {
    // Nothing to ask. Reporting the state keeps the app's one path
    // working — it asked, and an answer arrives, as everywhere else.
    if (g_note.cb == NULL) return;
    g_note.cb(g_note.ctx, NOKRE_NOTIFICATION_AUTHORIZED, nokre_notification_status(), "", 0, "", 0);
}

void nokre_notification_post(const char *id, size_t id_len, const char *title, size_t title_len,
                             const char *body, size_t body_len, const char *route, size_t route_len,
                             int32_t important, int64_t at_millis) {
    NokreNotifier *notifier = note_notifier();
    if (notifier == NULL || id_len >= 64) return;

    WCHAR wid[64], wtitle[256], wbody[1024], wroute[512];
    note_widen(id, id_len, wid, sizeof wid / sizeof wid[0]);
    note_widen(title, title_len, wtitle, sizeof wtitle / sizeof wtitle[0]);
    note_widen(body, body_len, wbody, sizeof wbody / sizeof wbody[0]);
    note_widen(route, route_len, wroute, sizeof wroute / sizeof wroute[0]);

    // ToastGeneric with two text lines, and `launch` carrying what the
    // activator hands back. `scenario="reminder"` is deliberately not
    // used for `important`: it demands dismissal and survives Focus
    // Assist, which is more than "this one may interrupt" asks for — the
    // Linux leg refuses `urgency=critical` for the same reason.
    WCHAR xml[4096];
    size_t at = 0;
    static const WCHAR head[] = L"<toast launch=\"";
    for (const WCHAR *p = head; *p; p++) xml[at++] = *p;
    at = note_xml_append(xml, sizeof xml / sizeof xml[0], at, wid);
    xml[at++] = 0x1F; // the unit separator note_activated splits on
    at = note_xml_append(xml, sizeof xml / sizeof xml[0], at, wroute);
    static const WCHAR mid1[] = L"\"><visual><binding template=\"ToastGeneric\"><text>";
    for (const WCHAR *p = mid1; *p; p++) xml[at++] = *p;
    at = note_xml_append(xml, sizeof xml / sizeof xml[0], at, wtitle);
    static const WCHAR mid2[] = L"</text><text>";
    for (const WCHAR *p = mid2; *p; p++) xml[at++] = *p;
    at = note_xml_append(xml, sizeof xml / sizeof xml[0], at, wbody);
    static const WCHAR tail[] = L"</text></binding></visual></toast>";
    for (const WCHAR *p = tail; *p; p++) xml[at++] = *p;
    xml[at] = L'\0';
    (void)important;

    static const WCHAR xml_class[] = L"Windows.Data.Xml.Dom.XmlDocument";
    NokreHstring class_h = NULL;
    if (FAILED(g_share.windows_create_string(xml_class, (UINT32)wcslen(xml_class), &class_h)))
        return;
    void *doc_unknown = NULL;
    HRESULT hr = g_note.ro_activate_instance(class_h, &doc_unknown);
    g_share.windows_delete_string(class_h);
    if (FAILED(hr) || doc_unknown == NULL) return;

    NokreXmlDoc *io = NULL;
    IUnknown *unk = (IUnknown *)doc_unknown;
    hr = unk->lpVtbl->QueryInterface(unk, &nokre_iid_xml_document_io, (void **)&io);
    if (FAILED(hr) || io == NULL) {
        unk->lpVtbl->Release(unk);
        return;
    }
    NokreHstring xml_h = NULL;
    if (SUCCEEDED(g_share.windows_create_string(xml, (UINT32)at, &xml_h))) {
        hr = io->vtbl->LoadXml(io, xml_h);
        g_share.windows_delete_string(xml_h);
    } else {
        hr = E_FAIL;
    }
    io->vtbl->Release(io);
    if (FAILED(hr)) {
        unk->lpVtbl->Release(unk);
        return;
    }

    NokreToast *toast = NULL;
    static const WCHAR toast_class[] = L"Windows.UI.Notifications.ToastNotification";
    NokreHstring toast_class_h = NULL;
    if (SUCCEEDED(g_share.windows_create_string(toast_class, (UINT32)wcslen(toast_class),
                                                &toast_class_h))) {
        if (at_millis == 0) {
            NokreToastFactory *factory = NULL;
            if (SUCCEEDED(g_note.ro_get_activation_factory(toast_class_h, &nokre_iid_toast_factory,
                                                           (void **)&factory)) &&
                factory != NULL) {
                factory->vtbl->CreateToastNotification(factory, doc_unknown, &toast);
                factory->vtbl->Release(factory);
            }
        } else {
            static const WCHAR sched_class[] = L"Windows.UI.Notifications.ScheduledToastNotification";
            NokreHstring sched_h = NULL;
            if (SUCCEEDED(g_share.windows_create_string(sched_class, (UINT32)wcslen(sched_class),
                                                        &sched_h))) {
                NokreSchedFactory *factory = NULL;
                if (SUCCEEDED(g_note.ro_get_activation_factory(
                        sched_h, &nokre_iid_scheduled_toast_factory, (void **)&factory)) &&
                    factory != NULL) {
                    // Unix milliseconds to a FILETIME-based DateTime: 100ns
                    // ticks since 1601-01-01, which is 11644473600 seconds
                    // before the Unix epoch.
                    NokreDateTime when = {(__int64)at_millis * 10000 + 116444736000000000LL};
                    factory->vtbl->CreateScheduledToastNotification(factory, doc_unknown, when,
                                                                    &toast);
                    factory->vtbl->Release(factory);
                }
                g_share.windows_delete_string(sched_h);
            }
        }
        g_share.windows_delete_string(toast_class_h);
    }
    unk->lpVtbl->Release(unk);
    if (toast == NULL) return;

    // Replace rather than stack, the contract's rule: an id already
    // showing is hidden first, and its slot is reused.
    int slot = note_slot_of(id, id_len);
    if (slot >= 0) {
        IUnknown *old = (IUnknown *)g_note.live[slot].toast;
        if (g_note.live[slot].scheduled)
            notifier->vtbl->RemoveFromSchedule(notifier, g_note.live[slot].toast);
        else
            notifier->vtbl->Hide(notifier, g_note.live[slot].toast);
        old->lpVtbl->Release(old);
        g_note.live[slot].toast = NULL;
    } else {
        for (int i = 0; i < NOKRE_NOTE_SLOTS; i++) {
            if (g_note.live[i].toast == NULL) {
                slot = i;
                break;
            }
        }
    }
    HRESULT shown = at_millis == 0 ? notifier->vtbl->Show(notifier, toast)
                                   : notifier->vtbl->AddToSchedule(notifier, toast);
    if (FAILED(shown) || slot < 0) {
        IUnknown *t = (IUnknown *)toast;
        t->lpVtbl->Release(t);
        return;
    }
    memcpy(g_note.live[slot].id, id, id_len);
    g_note.live[slot].id_len = id_len;
    g_note.live[slot].toast = toast;
    g_note.live[slot].scheduled = at_millis != 0;
}

void nokre_notification_cancel(const char *id, size_t id_len) {
    NokreNotifier *notifier = note_notifier();
    if (notifier == NULL) return;
    int slot = note_slot_of(id, id_len);
    if (slot < 0) return; // never posted, or already gone: idempotent
    if (g_note.live[slot].scheduled)
        notifier->vtbl->RemoveFromSchedule(notifier, g_note.live[slot].toast);
    else
        notifier->vtbl->Hide(notifier, g_note.live[slot].toast);
    IUnknown *t = (IUnknown *)g_note.live[slot].toast;
    t->lpVtbl->Release(t);
    g_note.live[slot].toast = NULL;
}

void nokre_notification_request_push(const char *key, size_t key_len) {
    (void)key;
    (void)key_len;
    // No push transport here; push_available already answered 0.
}

int32_t nokre_shell_run(const nokre_shell_config *config) {
    g.config = *config;

    // Deep-link protocol activation. Windows launches a fresh process with
    // the URL on the command line; if this app is already running, forward
    // the URL to that instance and exit, so a link routes to the one
    // window instead of stacking a duplicate — Android's
    // singleTask/onNewIntent bargain. Match class *and* title so we only
    // forward to the same app, never another nokre window sharing the
    // "NokreWindow" class. A plain launch (no URL) skips all of this, so two
    // ordinary launches still both run. This runs before RegisterClassW,
    // so FindWindowW can only see a pre-existing instance, never our own.
    int launch_len = 0;
    char *launch = launch_deep_link_utf8(&launch_len);
    if (launch) {
        int title_wlen = MultiByteToWideChar(CP_UTF8, 0, config->title, -1, NULL, 0);
        WCHAR *title_w = malloc((size_t)(title_wlen > 0 ? title_wlen : 1) * sizeof(WCHAR));
        HWND existing = NULL;
        if (title_w) {
            title_w[0] = 0;
            if (title_wlen > 0)
                MultiByteToWideChar(CP_UTF8, 0, config->title, -1, title_w, title_wlen);
            existing = FindWindowW(L"NokreWindow", title_w);
        }
        free(title_w);
        if (existing) {
            COPYDATASTRUCT cds = { NOKRE_DEEP_LINK_COPYDATA, (DWORD)launch_len, launch };
            SendMessageW(existing, WM_COPYDATA, 0, (LPARAM)&cds);
            SetForegroundWindow(existing);
            free(launch);
            return 0;
        }
        // No running instance: we are it. Buffer the URL as the launch
        // link (the callback is installed later, on the first build), the
        // way the macOS shell buffers openURLs that beat the handler.
        nokre_deep_link_dispatch(launch, (size_t)launch_len);
        free(launch);
    }

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HINSTANCE instance = GetModuleHandleW(NULL);

    WNDCLASSW wc = {0};
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(NULL, (const WCHAR *)IDC_ARROW);
    wc.lpszClassName = L"NokreWindow";
    if (!RegisterClassW(&wc)) return 1;

    int title_len = MultiByteToWideChar(CP_UTF8, 0, config->title, -1, NULL, 0);
    WCHAR *title = malloc((size_t)(title_len > 0 ? title_len : 1) * sizeof(WCHAR));
    if (!title) return 1;
    title[0] = 0;
    if (title_len > 0)
        MultiByteToWideChar(CP_UTF8, 0, config->title, -1, title, title_len);

    UINT dpi = GetDpiForSystem();
    g.scale = scale_of(dpi);
    DWORD style = WS_OVERLAPPEDWINDOW;
    RECT rect = { 0, 0, config->logical_w * g.scale, config->logical_h * g.scale };
    AdjustWindowRectExForDpi(&rect, style, FALSE, 0, dpi);
    int w = rect.right - rect.left, h = rect.bottom - rect.top;
    RECT work = {0};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int x = work.left + ((work.right - work.left) - w) / 2;
    int y = work.top + ((work.bottom - work.top) - h) / 2;

    g.hwnd = CreateWindowExW(0, wc.lpszClassName, title, style, x, y, w, h,
                             NULL, NULL, instance, NULL);
    free(title);
    if (!g.hwnd) return 1;

    // Before ShowWindow: the AccessKit subclassing adapter (attached in
    // on_ready) must wrap the window procedure while the window is
    // still hidden.
    config->on_ready(config->ctx, g.hwnd, "NokreWindow");
    report_appearance();

    ShowWindow(g.hwnd, SW_SHOW);
    config->on_window_focus(config->ctx, GetForegroundWindow() == g.hwnd ? 1 : 0);

    // Zeroed up front: GetMessageW's -1 error return leaves msg
    // untouched, and the exit code below must be defined either way.
    MSG msg = {0};
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    free(g.blit);
    g.blit = NULL;
    g.blit_cap = 0;
    return (int32_t)msg.wParam;
}
