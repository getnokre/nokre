//! package_info — app identity as one struct (docs/services.md).
//!
//! Identity is declared, not discovered: name, reverse-DNS id, display
//! version, and build number are declared once in build.zig and baked in
//! here at comptime — the same four values on every platform, wasm
//! included. Nothing is read back from Info.plist / AndroidManifest /
//! a web manifest at runtime; those files are packaging *outputs*,
//! generated from the same declaration (src/packaging/packaging.zig,
//! `zig build pkg`), so they can never become a second source of truth
//! (and never need to be hand-written per platform, or committed). The
//! native side answers only the question the build cannot: how this
//! binary was installed.

const builtin = @import("builtin");
const options = @import("nokre_package_info_options");

/// How the running binary reached the machine. `dev` is a bare binary
/// outside any bundle (`zig build run-…`); `direct` is a bundle
/// installed without a store.
pub const Installer = enum { dev, direct, app_store, testflight, web };

pub const PackageInfo = struct {
    /// Human-readable app name.
    name: []const u8,
    /// Reverse-DNS identifier (bundle id / application id).
    id: []const u8,
    /// Display version, e.g. "1.2.0".
    version: []const u8,
    /// Monotonic build number.
    build: u32,
    installer: Installer,
};

/// The whole service. Identity fields are comptime constants; only
/// `installer` costs a native query — stateless and synchronous, so
/// there is no boot handshake and nothing to cache.
pub fn get() PackageInfo {
    // Tests run with no declared identity and no shell to ask, the same
    // carve-out every stateful service takes through its mock — here the
    // service is constants, so the mock collapses to fixed dev values a
    // screen test can assert on without a build flag.
    if (comptime builtin.is_test) {
        return .{
            .name = "nokre",
            .id = "dev.nokre.test",
            .version = "0.0.0",
            .build = 0,
            .installer = .dev,
        };
    } else {
        comptime if (!options.linked) @compileError(
            \\the package_info service is not linked. Declare the app's identity
            \\once in build.zig — pass .pkg_id (plus optional .pkg_name,
            \\.pkg_version, .pkg_build) to the nokre dependency. docs/services.md.
        );
        return .{
            .name = options.name,
            .id = options.id,
            .version = options.version,
            .build = options.build,
            .installer = installer(),
        };
    }
}

// Mirrors NOKRE_PKG_INSTALLER_* in package_info.h.
extern fn nokre_pkg_installer() i32;

fn installer() Installer {
    return switch (builtin.os.tag) {
        // One mapping for both Apple legs; iOS's native side never
        // answers `direct` (ios.m says why), the shared switch just
        // spells the whole contract once.
        .macos, .ios => switch (nokre_pkg_installer()) {
            1 => .direct,
            2 => .app_store,
            3 => .testflight,
            else => .dev,
        },
        .freestanding, .emscripten, .wasi => .web,
        // Windows, desktop Linux, Android: store detection lands with
        // each platform's native leg; until then a query answers `dev`.
        else => .dev,
    };
}

test "test builds answer with fixed dev identity, no linking required" {
    const std = @import("std");
    const info = get();
    try std.testing.expectEqualStrings("dev.nokre.test", info.id);
    try std.testing.expectEqualStrings("0.0.0", info.version);
    try std.testing.expectEqual(Installer.dev, info.installer);
}
