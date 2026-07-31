// Win32 shell. Thin by charter: window, gray8 blit, input forwarding,
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
    uint32_t *blit; // gray8 expanded to BGRX for SetDIBitsToDevice
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

    // GDI has no gray8 DIB without palette bookkeeping (and 8bpp rows
    // would need DWORD alignment); expanding to BGRX keeps the blit one
    // unconditional memcpy-shaped loop.
    size_t count = (size_t)w * (size_t)h;
    if (count > g.blit_cap) {
        free(g.blit);
        g.blit = malloc(count * 4);
        g.blit_cap = g.blit ? count : 0;
        if (!g.blit) return;
    }
    for (size_t i = 0; i < count; i++) {
        uint32_t v = pixels[i];
        g.blit[i] = v | (v << 8) | (v << 16);
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

void nokre_open_url_open(const char *url, size_t len) {
    if (len == 0 || len > INT_MAX) return;
    // ShellExecuteW, not ShellExecuteA: the URL is UTF-8 and the ANSI
    // entry point would mangle any non-ASCII byte — oauth's desktop leg
    // (src/services/oauth/windows.c), minus the result nobody gets.
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, url, (int)len, NULL, 0);
    if (wide_len <= 0) return;
    WCHAR *wide = (WCHAR *)calloc((size_t)wide_len + 1, sizeof(WCHAR));
    if (wide == NULL) return;
    MultiByteToWideChar(CP_UTF8, 0, url, (int)len, wide, wide_len);
    wide[wide_len] = L'\0';
    ShellExecuteW(NULL, L"open", wide, NULL, NULL, SW_SHOWNORMAL);
    free(wide);
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
