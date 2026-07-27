// Windows side of the oauth service, and it is one function: open a URL
// in the user's default browser. Everything else about the flow — the
// loopback listener, the request parse, the delivery — is Zig
// (src/services/oauth/loopback.zig), because a blocking socket accept is
// exactly what the service layer already knows how to own and a second C
// implementation of it would be a second thing to get wrong.
//
// There is no Windows equivalent of ASWebAuthenticationSession to bind:
// WebAuthenticationBroker is a WinRT/UWP surface a Win32 desktop app
// cannot use, and an embedded WebView2 is the thing RFC 8252 exists to
// forbid. So the desktop answer is the same one the RFC gives — the
// system browser plus a loopback redirect (§7.3).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <limits.h>
#include <stdlib.h>

#include "oauth.h"

int nokre_oauth_open_url(const char *url, size_t len) {
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
    // worth distinguishing here — the app gets "no browser could be
    // launched" either way, which is the only thing it can act on.
    HINSTANCE rc = ShellExecuteW(NULL, L"open", wide, NULL, NULL, SW_SHOWNORMAL);
    free(wide);
    return ((INT_PTR)rc > 32) ? 0 : 1;
}
