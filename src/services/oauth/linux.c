// Desktop Linux side of the oauth service, and like Windows it is one
// function: hand the URL to the user's browser. The loopback listener
// that catches the redirect is Zig (loopback.zig) and shared with
// Windows — the xdg desktop portal has no auth-session API worth
// binding, so both desktops answer RFC 8252 §7.3 the same way.
//
// xdg-open rather than a portal call: opening a URI is the one desktop
// integration every environment has agreed on for two decades, it is
// present on any system with a browser, and the portal's OpenURI would
// add a D-Bus round trip to reach the same handler.

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "oauth.h"

int nokre_oauth_open_url(const char *url, size_t len) {
    if (len == 0) return 1;
    char *arg = (char *)malloc(len + 1);
    if (arg == NULL) return 1;
    memcpy(arg, url, len);
    arg[len] = '\0';

    // Double fork, so the app never acquires a child it must reap: the
    // intermediate exits immediately and is waited for here, and
    // xdg-open is re-parented to init. A single fork would leave a
    // zombie for the life of the process — a GUI app has no event loop
    // slot for SIGCHLD, and installing a handler for one would be a
    // service reaching into process-wide state.
    pid_t middle = fork();
    if (middle < 0) {
        free(arg);
        return 1;
    }
    if (middle == 0) {
        pid_t grandchild = fork();
        if (grandchild == 0) {
            execlp("xdg-open", "xdg-open", arg, (char *)NULL);
            _exit(127); // xdg-open is not installed
        }
        _exit(grandchild < 0 ? 1 : 0);
    }

    int status = 0;
    while (waitpid(middle, &status, 0) < 0 && errno == EINTR) {
    }
    free(arg);
    // What this can honestly report is whether the launch *started*: the
    // grandchild's own exit code is init's to collect, not ours. A
    // browser that opens and then fails to reach the provider is the
    // user's to see, and a redirect that never arrives ends as a flow
    // the user cancels — which the service already reports as a value.
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 1;
}
