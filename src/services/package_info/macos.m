// macOS side of the package_info service: installer provenance only.
#import <Foundation/Foundation.h>

#include "package_info.h"

int32_t nokre_pkg_installer(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    // appStoreReceiptURL is deprecated in favor of StoreKit 2's
    // AppTransaction, but that replacement is Swift-only — the receipt
    // URL remains the ObjC-reachable source for provenance.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSURL *receipt = bundle.appStoreReceiptURL;
#pragma clang diagnostic pop
    if (receipt != nil && [NSFileManager.defaultManager fileExistsAtPath:receipt.path]) {
        // TestFlight installs carry a sandbox receipt at the same URL.
        if ([receipt.lastPathComponent isEqualToString:@"sandboxReceipt"]) {
            return NOKRE_PKG_INSTALLER_TESTFLIGHT;
        }
        return NOKRE_PKG_INSTALLER_APP_STORE;
    }
    return [bundle.bundlePath hasSuffix:@".app"] ? NOKRE_PKG_INSTALLER_DIRECT
                                                 : NOKRE_PKG_INSTALLER_DEV;
}
