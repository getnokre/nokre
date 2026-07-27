// C contract between the package_info service native side and Zig, in
// the shape of src/platform/macos/shell.h: thin, stateless, synchronous.
//
// Identity (name / id / version / build) never crosses this boundary —
// it is declared once in build.zig and baked into the Zig side at
// comptime, so it cannot drift per platform. The native side answers
// the one question only the OS can: how this binary was installed.
#ifndef NOKRE_SVC_PACKAGE_INFO_H
#define NOKRE_SVC_PACKAGE_INFO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors src/services/package_info/package_info.zig Installer.
enum {
    NOKRE_PKG_INSTALLER_DEV = 0, // bare binary, no bundle (zig build run-…)
    NOKRE_PKG_INSTALLER_DIRECT = 1, // bundled, but no store receipt
    NOKRE_PKG_INSTALLER_APP_STORE = 2,
    NOKRE_PKG_INSTALLER_TESTFLIGHT = 3,
};

// Pure query: no state, no callbacks, safe from any thread.
int32_t nokre_pkg_installer(void);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_PACKAGE_INFO_H
