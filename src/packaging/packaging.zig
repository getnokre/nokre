//! packaging — platform manifests generated from the build declaration
//! (docs/services.md).
//!
//! The inversion that makes declare-once real: Info.plist,
//! AndroidManifest.xml, the Gradle identity properties, the web shell
//! page, the app icon set, and the deep-link association files are
//! *outputs* of the build.zig declaration — the same one
//! that bakes package_info — never hand-written, so they cannot drift
//! into a second source of truth. Emitters are pure functions of
//! (declaration, linked services): deterministic to the byte and
//! golden-tested like everything else here (packaging_test.zig embeds
//! the expected files). One artifact travels the other way — the
//! Icon Composer bundle an app may declare (apple_icon.zig), which is
//! validated and carried, never generated — and it is the exception
//! that proves the rule: nokre takes an input only where the input is
//! itself a declaration Apple's own tool compiles.
//!
//! Permissions are derived, not declared — linking a service *is* the
//! statement of intent, the a11y rule (derive from the tree) applied to
//! packaging. The derivation table lives on `Services`; silence is
//! never a row — every service states its per-platform footprint, even
//! when that footprint is nothing (docs/internals/contributing.md).
//!
//! Consumed by build.zig alone; nothing here compiles into an app. The
//! runtime window into the same declaration is
//! src/services/package_info.

const std = @import("std");

/// The derived app icon — mark derivation and PNG serialization
/// (icon.zig); the per-platform size tables live below with the other
/// derivation policy.
pub const icon = @import("icon.zig");

/// The declared Apple icon — an Icon Composer `.icon` bundle the tree
/// carries whole (apple_icon.zig). The one packaging artifact that is
/// an *input* rather than a derivation, and it earns that by being a
/// declaration itself: nokre validates and delivers it, Xcode's actool
/// compiles it.
pub const apple_icon = @import("apple_icon.zig");

/// App identity as build.zig declares it (the `pkg_*` options alias
/// this struct). Packaging consumes the declaration directly, never the
/// package_info service, so manifests can exist for an app that links
/// zero services — the kitchen sink's contract.
pub const Decl = struct {
    /// Human-readable app name: the home-screen label on every platform.
    name: []const u8,
    /// Reverse-DNS identifier. Declare-once forces the charset to the
    /// intersection of every platform's rules — Android's applicationId
    /// (Java package segments: no dashes) is the narrowest — plus
    /// all-lowercase, because Apple compares bundle ids
    /// case-insensitively and Android does not: two or more
    /// dot-separated `[a-z][a-z0-9_]*` segments. Loosening later is
    /// compatible; tightening never is.
    id: []const u8,
    /// Display version. Free-form (Android's versionName is free text);
    /// App Store validation wants dotted numerals, but that is Apple's
    /// rule to enforce once, not one to duplicate here.
    version: []const u8,
    /// Monotonic build number, >= 1: Android rejects a versionCode of 0
    /// and both stores treat build numbers as 1-based.
    build: u32,
};

/// The linked-service set as packaging sees it. Always-on services have
/// no flag — their derivations are unconditional: http implies
/// Android's INTERNET permission (a normal, install-time permission;
/// the emitters cannot see call sites, and the client is always
/// linked); workers, clipboard, and locale imply nothing anywhere —
/// the device's language is not a protected value on any of the six
/// platforms, so reading it needs no permission, entitlement, or
/// manifest entry, and locale therefore has no flag to add here rather
/// than a footprint left unstated. haptic is the same, and doubly so:
/// it is not consumer-facing at all, and its one leg derives nothing —
/// UIImpactFeedbackGenerator is plain UIKit, with no entitlement and no
/// plist key. (Nothing here needs Android's VIBRATE either: that
/// permission is for driving the motor directly, which nokre never
/// does — docs/internals/haptics.md.) Opt-in
/// services add a flag when they land, even a no-op one — the
/// contributing checklist requires every service to state its manifest
/// footprint explicitly.
pub const Services = struct {
    /// Emits nothing on every platform, and that fact is the row:
    /// Keychain's default access group needs no entitlement, Android's
    /// Keystore and Windows' Credential Manager need no permission —
    /// the store's cost is link-time only (build.zig). A future backend
    /// choice (iCloud keychain sync = an entitlement) would light up
    /// here.
    secure_store: bool = false,

    /// The domains the deep_link service claims for App Links / Universal
    /// Links (docs/services.md). Empty is the unlinked row — nothing
    /// derives; a non-empty set lights up four artifacts, every one a
    /// pure function of the declared id and these domains: the iOS
    /// associated-domains entitlement and its server half
    /// (apple-app-site-association), and the Android VIEW intent-filter
    /// and its server half (assetlinks.json). Two values the declaration
    /// genuinely cannot know — Apple's Team ID and the Android signing
    /// cert's SHA-256 — are the developer's to fill at signing time, so
    /// the two server files carry a loud `REPLACE_…` placeholder rather
    /// than a fabricated value. Order is the developer's and preserved:
    /// the emitted arrays stay a reviewable diff.
    deep_link_domains: []const []const u8 = &.{},

    /// The custom URL schemes the oauth service's redirects land on
    /// (docs/services.md). Empty is the unlinked row. This is the
    /// custom-scheme opt-in `deep_link` deferred — *"a custom scheme is
    /// a different, underived manifest declaration… its own opt-in if a
    /// need appears"* — and OAuth is that need: a redirect is not a
    /// public link, so the two-way `.well-known/` proof an App Link
    /// relies on is neither available nor what the flow depends on
    /// (PKCE is). deep_link's refusal is unchanged; it still derives
    /// only verified `https://` domains, and nothing here touches it.
    ///
    /// Two client-side artifacts, both pure functions of these strings:
    /// a `CFBundleURLTypes` entry on Apple and a VIEW intent-filter on
    /// Android — deliberately *without* `autoVerify`, which exists to
    /// check a domain nobody owns here. No server half: there is no
    /// domain to prove ownership of. Windows and Linux derive nothing (a
    /// loopback listener registers nothing), and neither does the web
    /// (the origin is the registration). Order is the developer's and
    /// preserved.
    oauth_schemes: []const []const u8 = &.{},

    /// Sign in with Apple. Lights up exactly one artifact — the
    /// `com.apple.developer.applesignin` entitlement — and only on
    /// Apple's platforms; everywhere else the same `.provider = .apple`
    /// call is the plain browser flow, which registers nothing beyond
    /// whatever scheme it already redirects to.
    oauth_apple: bool = false,

    /// The iap service (docs/services.md). One artifact, on one
    /// platform: Android's `com.android.vending.BILLING` permission,
    /// which the Play Billing Library refuses to work without.
    ///
    /// Apple derives nothing, and the silence is the row rather than an
    /// omission: In-App Purchase is a capability on the App ID, toggled
    /// in Apple's own console and carried by the provisioning profile —
    /// there is no plist key and no entitlement file entry for it, so
    /// the cost is link-time only (StoreKit.framework). Windows, Linux,
    /// and the web derive nothing because they have no store to declare;
    /// `available` answers false there.
    iap: bool = false,

    /// The notification service (docs/services.md). One artifact for the
    /// local half, and it is the first *dangerous* permission any service
    /// has derived: Android's `POST_NOTIFICATIONS`, prompted at runtime
    /// from API 33, refusable, and revocable in Settings afterwards. The
    /// BILLING row above states why a normal permission may be derived
    /// silently; this one may not, which is why it is spelled out in the
    /// consumer section rather than only here.
    ///
    /// Apple derives nothing for the local half — asking is
    /// `UNUserNotificationCenter`'s runtime prompt, with no plist key and
    /// no entitlement behind it. Windows derives nothing into a manifest
    /// either: an unpackaged app's toast identity is an AppUserModelID
    /// the shell registers at first run (docs/internals/notifications.md
    /// records that narrowing of deep_link's registry refusal). Linux
    /// derives nothing at all — org.freedesktop.Notifications is a bus
    /// name, not a declaration. The web's one artifact, the service
    /// worker, is emitted with the site whether or not this is linked,
    /// because the page needs it to exist before it can ask.
    notification: bool = false,

    /// Remote push, on top of `notification`. Two more artifacts, on two
    /// platforms: Apple's `aps-environment` entitlement — `development`,
    /// because the value is a signing-time choice and the one a
    /// developer's build actually uses is the honest default; Xcode
    /// rewrites it to `production` for a distribution build — and
    /// Android's FCM `<service>` declaration with its intent-filter.
    /// Windows would need WNS and the packaged Store identity nokre does
    /// not emit, and the Linux desktop has no push service at all, so
    /// both answer `pushAvailable` false at runtime rather than deriving
    /// anything (iap's shape, one roster row over).
    notification_push: bool = false,

    /// The VAPID application server key web push subscribes with. It
    /// derives nothing into any manifest — it is not an identity the OS
    /// checks, it is the sender's public half, which the browser only
    /// ever compares against what the app's own backend signs with. It
    /// rides this struct because the linked-service set is the one shape
    /// both the module wiring and the emitters read, and the wiring needs
    /// it.
    notification_push_key: []const u8 = "",
};

/// The web build's third input, beside the declaration and the linked
/// services: what the *site* is assembled around. Nothing in it is
/// identity — a page carries a title because the app has a name, and it
/// carries these because a browser needs them — so it rides beside
/// `Decl` rather than inside it.
pub const Web = struct {
    /// The name the app's module carries inside the site, and therefore
    /// the name the page's boot module asks for.
    module_wasm: []const u8 = "app.wasm",
    /// The hosts the app's own code talks to: its API, its OAuth token
    /// endpoint, anything the http service will fetch. They are added to
    /// the page's `connect-src` and to nothing else, so declaring one
    /// grants exactly one power rather than loosening the policy around
    /// it (the consumer contract is docs/getting-started.md, the
    /// derivation docs/internals/dom-edition.md). Empty is both the
    /// default and the common case — an app that talks to nothing but
    /// the origin it was served from declares nothing.
    ///
    /// Each entry is a CSP source expression — `https://api.example.com`,
    /// `*.example.com`, `wss://live.example.com` — and is checked by
    /// `badConnectSrc` before it reaches the page: a string that lands
    /// inside a policy is a string that could end the directive it landed
    /// in and start a friendlier one.
    connect_src: []const []const u8 = &.{},
};

/// The first `connect_src` entry a page will not carry, or null when
/// every one of them is a plain source expression. Two refusals. Anything
/// a source cannot contain — whitespace, a quote, a semicolon, a comma —
/// because that is exactly how one declared origin becomes a second
/// directive. And the bare wildcard, because "every host there is" names
/// no host at all: it is the directive's absence, and a consumer who
/// truly wants that can say so in their own edge configuration rather
/// than have nokre generate it into every page they ship.
pub fn badConnectSrc(sources: []const []const u8) ?[]const u8 {
    for (sources) |src| {
        if (src.len == 0 or std.mem.eql(u8, src, "*")) return src;
        for (src) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', ':', '/', '*', '+', '[', ']' => {},
            else => return src,
        };
    }
    return null;
}

pub const Error = error{ InvalidId, InvalidBuild };

/// The declare-once contract's teeth, run by build.zig before any
/// emitter. An id that any platform would reject must fail here, at the
/// declaration, not months later in a store submission.
pub fn validate(decl: Decl) Error!void {
    if (decl.build == 0) return error.InvalidBuild;
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, decl.id, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidId;
        if (!std.ascii.isLower(seg[0])) return error.InvalidId;
        for (seg[1..]) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return error.InvalidId;
        }
        segments += 1;
    }
    if (segments < 2) return error.InvalidId;
}

/// macOS's Info.plist, and the reason there is a bundle at all.
///
/// A bare Mach-O executable has no bundle identifier, and without one
/// `UNUserNotificationCenter` refuses to post: the notification centre
/// keys everything to the bundle, so an unbundled binary cannot own a
/// notification. That is the whole argument for assembling a `.app` —
/// packaging emitted this plist for nobody until a service needed the
/// bundle it describes (docs/internals/notifications.md).
///
/// Deliberately not iosInfoPlist: that one carries the scene manifest,
/// which is UIKit's and means nothing here, and this one carries
/// `NSHighResolutionCapable`, without which AppKit hands the shell a 1×
/// backing store on a Retina display and every glyph resamples — the
/// pixel model's own stake in the file. Keys alphabetical, like its
/// sibling: determinism is a feature.
///
/// `executable` is the binary's filename inside `Contents/MacOS`, which
/// build.zig knows and a declaration cannot — androidManifest takes its
/// native library's name for the same reason.
pub fn macosInfoPlist(gpa: std.mem.Allocator, decl: Decl, services: Services, executable: []const u8) error{OutOfMemory}![]u8 {
    _ = services; // no macOS key derives from a service yet; stated, not implied
    const name_xml = try xmlEscapedAlloc(gpa, decl.name);
    defer gpa.free(name_xml);
    const version_xml = try xmlEscapedAlloc(gpa, decl.version);
    defer gpa.free(version_xml);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleIconFile</key>
        \\    <string>AppIcon</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>{d}</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>11.0</string>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ name_xml, executable, decl.id, name_xml, version_xml, decl.build });
    return out.toOwnedSlice(gpa);
}

/// The complete Info.plist — Xcode's own plist generation is turned off
/// (GENERATE_INFOPLIST_FILE=NO) because it hardcodes multi-scene
/// support to true and nokre is one window by design; owning the whole
/// file is what lets the scene manifest say so. The scene configuration
/// name and delegate class must match src/platform/ios/shell.m, which
/// also supplies them in code. CFBundleExecutable stays an Xcode
/// variable (expanded by default at plist processing); CFBundleIdentifier
/// is the literal declared id — Xcode fails the build if the project's
/// PRODUCT_BUNDLE_IDENTIFIER (which Apple's signing machinery insists
/// on owning) disagrees, so the one forced duplication drifts loudly,
/// never silently. Keys are alphabetical: determinism is a feature.
pub fn iosInfoPlist(gpa: std.mem.Allocator, decl: Decl, services: Services) error{OutOfMemory}![]u8 {
    // secure_store: no entitlement for the default keychain access
    // group. deep_link: its client half is the entitlement, not a plist
    // key. oauth: the custom-scheme registration below.
    const name_xml = try xmlEscapedAlloc(gpa, decl.name);
    defer gpa.free(name_xml);
    // The version is consumer-controlled free text, exactly like the
    // name; it gets the same escaping (the id is charset-validated and
    // needs none).
    const version_xml = try xmlEscapedAlloc(gpa, decl.version);
    defer gpa.free(version_xml);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>$(EXECUTABLE_NAME)</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{s}</string>
        \\
    , .{ name_xml, decl.id, name_xml, version_xml });
    // oauth's client-side registration: the schemes the OS routes back
    // to this app after a redirect. One URL type carrying every declared
    // scheme, named by the app id — Apple keys nothing off the name, and
    // one entry per scheme would only multiply a value the declaration
    // already owns. `Editor` is the role for a scheme the app itself
    // defines. Alphabetical between ShortVersionString and Version, like
    // every other key here.
    if (services.oauth_schemes.len != 0) {
        try out.print(gpa,
            \\    <key>CFBundleURLTypes</key>
            \\    <array>
            \\        <dict>
            \\            <key>CFBundleTypeRole</key>
            \\            <string>Editor</string>
            \\            <key>CFBundleURLName</key>
            \\            <string>{s}</string>
            \\            <key>CFBundleURLSchemes</key>
            \\            <array>
            \\
        , .{decl.id});
        for (services.oauth_schemes) |scheme| {
            const scheme_xml = try xmlEscapedAlloc(gpa, scheme);
            defer gpa.free(scheme_xml);
            try out.print(gpa, "                <string>{s}</string>\n", .{scheme_xml});
        }
        try out.appendSlice(gpa,
            \\            </array>
            \\        </dict>
            \\    </array>
            \\
        );
    }
    try out.print(gpa,
        \\    <key>CFBundleVersion</key>
        \\    <string>{d}</string>
        \\    <key>LSRequiresIPhoneOS</key>
        \\    <true/>
        \\    <key>UIApplicationSceneManifest</key>
        \\    <dict>
        \\        <key>UIApplicationSupportsMultipleScenes</key>
        \\        <false/>
        \\        <key>UISceneConfigurations</key>
        \\        <dict>
        \\            <key>UIWindowSceneSessionRoleApplication</key>
        \\            <array>
        \\                <dict>
        \\                    <key>UISceneConfigurationName</key>
        \\                    <string>nokre</string>
        \\                    <key>UISceneDelegateClassName</key>
        \\                    <string>NokreSceneDelegate</string>
        \\                </dict>
        \\            </array>
        \\        </dict>
        \\    </dict>
        \\    <key>UILaunchScreen</key>
        \\    <dict/>
        \\    <key>UISupportedInterfaceOrientations</key>
        \\    <array>
        \\        <string>UIInterfaceOrientationPortrait</string>
        \\        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        \\        <string>UIInterfaceOrientationLandscapeLeft</string>
        \\        <string>UIInterfaceOrientationLandscapeRight</string>
        \\    </array>
        \\</dict>
        \\</plist>
        \\
    , .{decl.build});
    return out.toOwnedSlice(gpa);
}

/// The shell owns the Activity (dev.nokre.shell.NokreActivity — the app
/// delegate rule from ios/shell.m); the declaration contributes
/// identity and the derived permission set. configChanges keeps uiMode
/// and size changes out of the recreate path — the app boots once per
/// process, the web shell's rule — and windowSoftInputMode covers
/// pre-API-30 devices, where the activity handles insets the legacy
/// way. allowBackup=false: the only durable app state is secure_store
/// secrets, which must not ride device-transfer backups.
/// versionCode/versionName are deliberately absent — Gradle owns them
/// at configuration time via androidProperties. `native_lib` names the
/// .so the shell loads (the CMake target).
pub fn androidManifest(gpa: std.mem.Allocator, decl: Decl, services: Services, native_lib: []const u8) error{OutOfMemory}![]u8 {
    // INTERNET is unconditional (http is always linked); secure_store:
    // Keystore needs no permission. deep_link contributes an
    // App-Links intent-filter to the one activity when it claims domains.
    // iap contributes BILLING — the one permission any service derives.
    const name_xml = try xmlEscapedAlloc(gpa, decl.name);
    defer gpa.free(name_xml);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\
    );
    // Play Billing refuses to connect without it. A normal permission —
    // granted at install, never prompted — so it changes nothing the
    // user sees at runtime, which is why the derivation can be silent
    // where a dangerous permission's could not be.
    if (services.iap) {
        try out.appendSlice(gpa,
            \\    <uses-permission android:name="com.android.vending.BILLING" />
            \\
        );
    }
    // The exception to the rule the line above states, and the only one
    // on the roster: POST_NOTIFICATIONS is *dangerous* — from API 33 it
    // is prompted at runtime, the user can refuse it, and they can revoke
    // it afterwards in Settings. So the derivation cannot be silent the
    // way BILLING's is: an app that links this service gets a permission
    // its users will see and answer, which is stated in docs/services.md
    // where a consumer reads it, not only here where the emitter does.
    // Declaring it is still what makes asking possible — the runtime
    // request has nothing to request without the manifest entry.
    if (services.notification) {
        try out.appendSlice(gpa,
            \\    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
            \\
        );
    }
    // Two permissions scheduling could have derived and deliberately does
    // not. USE_EXACT_ALARM and SCHEDULE_EXACT_ALARM ration the
    // to-the-second alarm: Play polices the first to alarm-clock and
    // calendar apps, and the second is user-revocable from API 33 — so
    // deriving either would make every consumer justify nokre's choice to
    // Google for a fire date that reads "remind me in the morning". The
    // inexact alarm fires inside the OS's batching window, which is the
    // right trade for a framework that draws no clock.
    // RECEIVE_BOOT_COMPLETED is the other: alarms do not survive a reboot
    // on Android, and re-arming them would mean nokre keeping its own
    // durable copy of the schedule — a schedule nokre owns, which is the
    // thing `schedule` exists *not* to be. So the honest answer is the
    // stated posture in docs/services.md (a scheduled notification is
    // lost to a reboot on Android alone), not a permission backing a
    // receiver that would contradict the design.
    try out.print(gpa,
        \\    <application
        \\        android:label="{s}"
        \\        android:icon="@mipmap/ic_launcher"
        \\        android:theme="@style/NokreTheme"
        \\        android:allowBackup="false">
        \\        <activity
        \\            android:name="dev.nokre.shell.NokreActivity"
        \\            android:exported="true"
        \\
    , .{name_xml});
    // singleTask when any inbound URL is claimed: a link tapped while
    // the app runs routes to the one existing instance
    // (NokreActivity.onNewIntent) instead of stacking a duplicate — the
    // single-window charter the configChanges line already commits to,
    // made explicit for the App-Links path. An oauth redirect needs it
    // for a sharper reason: the Custom Tab launched *from* this task, so
    // without singleTask the redirect would start a second copy of the
    // activity and the callback would land in an app instance that never
    // began the flow. Absent when neither claims anything, so an app with
    // no inbound URLs keeps the default launch behavior.
    if (services.deep_link_domains.len != 0 or services.oauth_schemes.len != 0) {
        try out.appendSlice(gpa,
            \\            android:launchMode="singleTask"
            \\
        );
    }
    try out.print(gpa,
        \\            android:configChanges="uiMode|orientation|screenSize|screenLayout|smallestScreenSize|keyboard|keyboardHidden|navigation|density"
        \\            android:windowSoftInputMode="adjustResize">
        \\            <meta-data
        \\                android:name="dev.nokre.lib"
        \\                android:value="{s}" />
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.MAIN" />
        \\                <category android:name="android.intent.category.LAUNCHER" />
        \\            </intent-filter>
        \\
    , .{native_lib});
    // App Links: one autoVerify filter, https only, a <data> host per
    // claimed domain (order preserved). autoVerify makes Android check
    // assetlinks.json at each host and open the app without the chooser
    // when it matches. VIEW + DEFAULT + BROWSABLE is the web-link
    // contract; the scheme stays https because a Universal/App Link is an
    // https URL, never a custom scheme (the service delivers the URL, the
    // app routes it — docs/services.md).
    if (services.deep_link_domains.len != 0) {
        try out.appendSlice(gpa,
            \\            <intent-filter android:autoVerify="true">
            \\                <action android:name="android.intent.action.VIEW" />
            \\                <category android:name="android.intent.category.DEFAULT" />
            \\                <category android:name="android.intent.category.BROWSABLE" />
            \\
        );
        for (services.deep_link_domains) |domain| {
            const host_xml = try xmlEscapedAlloc(gpa, domain);
            defer gpa.free(host_xml);
            try out.print(gpa,
                \\                <data android:scheme="https" android:host="{s}" />
                \\
            , .{host_xml});
        }
        try out.appendSlice(gpa,
            \\            </intent-filter>
            \\
        );
    }
    // oauth's redirect filter: one <data> per declared scheme, no
    // autoVerify (there is no domain to verify — the scheme *is* the
    // registration) and no BROWSABLE-only subtlety to it. Separate from
    // the App-Links filter above rather than merged, because Android
    // takes the cross product of every scheme and host in one filter:
    // merged, an https://claimed-domain URL would also match the custom
    // scheme's host set and vice versa.
    if (services.oauth_schemes.len != 0) {
        try out.appendSlice(gpa,
            \\            <intent-filter>
            \\                <action android:name="android.intent.action.VIEW" />
            \\                <category android:name="android.intent.category.DEFAULT" />
            \\                <category android:name="android.intent.category.BROWSABLE" />
            \\
        );
        for (services.oauth_schemes) |scheme| {
            const scheme_xml = try xmlEscapedAlloc(gpa, scheme);
            defer gpa.free(scheme_xml);
            try out.print(gpa,
                \\                <data android:scheme="{s}" />
                \\
            , .{scheme_xml});
        }
        try out.appendSlice(gpa,
            \\            </intent-filter>
            \\
        );
    }
    try out.appendSlice(gpa,
        \\        </activity>
        \\
    );
    // Scheduling's receiver: Android is the one platform where the
    // notification system does not hold a fire date itself, so an alarm
    // wakes the smallest possible thing and that thing posts. Not
    // exported — only the OS's own alarm, delivered to this package,
    // may fire it, and an exported receiver would let any app on the
    // device post a notification as this one.
    if (services.notification) {
        try out.appendSlice(gpa,
            \\        <receiver
            \\            android:name="dev.nokre.shell.NokreNotificationAlarm"
            \\            android:exported="false" />
            \\
        );
    }
    // FCM's inbound half: a service the Firebase library binds to when a
    // push arrives. Declared here rather than merged into NokreActivity
    // because a push can arrive with no activity at all — that is the
    // whole point of push — and the class is nokre's own
    // (src/services/notification/java), on the source-set split iap
    // established: the consumer adds the Maven coordinate to their own
    // build.gradle, so the dependency's cost stays in the open.
    // `exported="false"`: only the Firebase library in this process binds
    // it, and an exported service would let any app on the device deliver
    // a fake push to it.
    if (services.notification_push) {
        try out.appendSlice(gpa,
            \\        <service
            \\            android:name="dev.nokre.shell.NokrePushService"
            \\            android:exported="false">
            \\            <intent-filter>
            \\                <action android:name="com.google.firebase.MESSAGING_EVENT" />
            \\            </intent-filter>
            \\        </service>
            \\
        );
    }
    try out.appendSlice(gpa,
        \\    </application>
        \\</manifest>
        \\
    );
    return out.toOwnedSlice(gpa);
}

/// The identity in Gradle-readable form. Gradle must know
/// applicationId/versionCode/versionName at configuration time — before
/// any task runs — so build.gradle regenerates this file via
/// `zig build pkg` during configuration and loads it back (with a UTF-8
/// reader: java.util.Properties streams default to latin-1). Only what
/// Gradle consumes lives here; the label reaches Android through the
/// generated manifest instead.
pub fn androidProperties(gpa: std.mem.Allocator, decl: Decl) error{OutOfMemory}![]u8 {
    // The version is consumer-controlled free text (the id is
    // charset-validated, the build a number), so it gets the escaping
    // this format owes, as every XML/JSON emitter here escapes its own.
    const version_props = try propertiesValueEscapedAlloc(gpa, decl.version);
    defer gpa.free(version_props);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\# Generated from the build.zig declaration (zig build pkg) — do not edit.
        \\id={s}
        \\version={s}
        \\build={d}
        \\
    , .{ decl.id, version_props, decl.build });
    return out.toOwnedSlice(gpa);
}

/// java.util.Properties value escaping. Only what Properties would
/// otherwise mis-parse: a backslash starts an escape sequence, a bare
/// newline ends the entry (smuggling the rest in as new keys), and
/// leading whitespace is trimmed silently — each would hand Gradle a
/// version different from the declared one.
fn propertiesValueEscapedAlloc(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s, 0..) |c, i| switch (c) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        ' ' => if (i == 0)
            try out.appendSlice(gpa, "\\ ")
        else
            try out.append(gpa, ' '),
        else => try out.append(gpa, c),
    };
    return out.toOwnedSlice(gpa);
}

// ---- deep_link association files (docs/services.md) ----
// Emitted only when the deep_link service claims domains; `null` is the
// unlinked answer, and build.zig writes nothing for it — an app without
// deep links carries no entitlement and no server file. The two client
// artifacts (this entitlement, the Android intent-filter above) are
// fully derived; the two server artifacts each mark the one signing-time
// secret they cannot know with a `REPLACE_…` placeholder, never a
// fabricated value that would silently fail verification.

pub const placeholder_apple_team_id = "REPLACE_WITH_YOUR_APPLE_TEAM_ID";
pub const placeholder_android_cert_sha256 = "REPLACE_WITH_YOUR_APP_SIGNING_CERT_SHA256";

/// The associated-domains entitlement — the client half of iOS Universal
/// Links, signed into the app. One `applinks:` line per claimed domain,
/// order preserved. `webcredentials:`/`activitycontinuation:` are other
/// associated-domain services nokre does not use, so the array carries
/// applinks alone. Keys alphabetical, like Info.plist. Xcode points
/// CODE_SIGN_ENTITLEMENTS at this file; absent domains → no file, and an
/// app signs fine without one.
pub fn iosEntitlements(gpa: std.mem.Allocator, decl: Decl, services: Services) error{OutOfMemory}!?[]u8 {
    _ = decl;
    if (services.deep_link_domains.len == 0 and !services.oauth_apple and !services.notification_push) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    // Remote push. `development` is the honest default: the value picks
    // which APNs environment the app's token is minted against, a build
    // *and signing* choice rather than a source one, and the build a
    // developer runs from this tree is the development one. Xcode
    // rewrites it to `production` for a distribution build, which is the
    // one duplication Apple's signing machinery insists on owning — the
    // PRODUCT_BUNDLE_IDENTIFIER bargain, restated. Alphabetically first.
    if (services.notification_push) {
        try out.appendSlice(gpa,
            \\    <key>aps-environment</key>
            \\    <string>development</string>
            \\
        );
    }
    // Sign in with Apple. `Default` is the only value that exists — the
    // alternative, `Default with Apple Watch`, is for watchOS
    // companions, which nokre does not target. Alphabetically before
    // associated-domains.
    if (services.oauth_apple) {
        try out.appendSlice(gpa,
            \\    <key>com.apple.developer.applesignin</key>
            \\    <array>
            \\        <string>Default</string>
            \\    </array>
            \\
        );
    }
    if (services.deep_link_domains.len != 0) {
        try out.appendSlice(gpa,
            \\    <key>com.apple.developer.associated-domains</key>
            \\    <array>
            \\
        );
        for (services.deep_link_domains) |domain| {
            const domain_xml = try xmlEscapedAlloc(gpa, domain);
            defer gpa.free(domain_xml);
            try out.print(gpa, "        <string>applinks:{s}</string>\n", .{domain_xml});
        }
        try out.appendSlice(gpa,
            \\    </array>
            \\
        );
    }
    try out.appendSlice(gpa,
        \\</dict>
        \\</plist>
        \\
    );
    return try out.toOwnedSlice(gpa);
}

/// The server half of iOS Universal Links: the file the developer hosts
/// at `https://<domain>/.well-known/apple-app-site-association` on every
/// claimed domain (the same content serves them all — it identifies the
/// app, not the host). `components: [{ "/": "*" }]` claims every path;
/// scoping paths is routing, and routing is the app's job. The `appID`
/// is `<TeamID>.<bundleId>`: the bundle id is the declared id, the Team
/// ID is a signing-time value the declaration cannot know, so it stays a
/// placeholder. No file extension — Apple serves it as raw JSON.
pub fn appleAppSiteAssociation(gpa: std.mem.Allocator, decl: Decl, services: Services) error{OutOfMemory}!?[]u8 {
    if (services.deep_link_domains.len == 0) return null;
    const id_json = try jsonEscapedAlloc(gpa, decl.id);
    defer gpa.free(id_json);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\{{
        \\  "applinks": {{
        \\    "details": [
        \\      {{
        \\        "appIDs": [ "{s}.{s}" ],
        \\        "components": [ {{ "/": "*" }} ]
        \\      }}
        \\    ]
        \\  }}
        \\}}
        \\
    , .{ placeholder_apple_team_id, id_json });
    return try out.toOwnedSlice(gpa);
}

/// The server half of Android App Links: the file the developer hosts at
/// `https://<domain>/.well-known/assetlinks.json` on every claimed
/// domain, which `android:autoVerify` fetches to confirm the app owns
/// the host. `package_name` is the declared id (Android's applicationId
/// is the same reverse-DNS string); the SHA-256 of the signing cert is a
/// signing-time value the declaration cannot know, so it stays a
/// placeholder the developer replaces (from `keytool`/`gradlew
/// signingReport`, or the Play Console's App-signing key).
pub fn androidAssetLinks(gpa: std.mem.Allocator, decl: Decl, services: Services) error{OutOfMemory}!?[]u8 {
    if (services.deep_link_domains.len == 0) return null;
    const id_json = try jsonEscapedAlloc(gpa, decl.id);
    defer gpa.free(id_json);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\[
        \\  {{
        \\    "relation": [ "delegate_permission/common.handle_all_urls" ],
        \\    "target": {{
        \\      "namespace": "android_app",
        \\      "package_name": "{s}",
        \\      "sha256_cert_fingerprints": [ "{s}" ]
        \\    }}
        \\  }}
        \\]
        \\
    , .{ id_json, placeholder_android_cert_sha256 });
    return try out.toOwnedSlice(gpa);
}

/// No `id` field on purpose: a web-app manifest id is a URL resolved
/// against the origin — the one platform where reverse-DNS identity has
/// no home (package_info reports installer=.web for the same reason) —
/// and the spec default (start_url) is exactly right. The colors paint
/// the browser chrome around the app, never app pixels, so black stays
/// inside the grayscale guarantee and matches the page background.
pub fn webManifest(gpa: std.mem.Allocator, decl: Decl) error{OutOfMemory}![]u8 {
    const name_json = try jsonEscapedAlloc(gpa, decl.name);
    defer gpa.free(name_json);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\{{
        \\  "name": "{s}",
        \\  "short_name": "{s}",
        \\  "start_url": ".",
        \\  "display": "standalone",
        \\  "background_color": "#000000",
        \\  "theme_color": "#000000",
        \\  "icons": [
        \\    {{ "src": "icon-192.png", "sizes": "192x192", "type": "image/png" }},
        \\    {{ "src": "icon-512.png", "sizes": "512x512", "type": "image/png" }}
        \\  ]
        \\}}
        \\
    , .{ name_json, name_json });
    return out.toOwnedSlice(gpa);
}

/// The page's own stylesheet, and the whole of what a page around a
/// nokre app has to say: everything on screen comes out of the tree, so
/// the one thing left over is what the tree cannot say — how wide a
/// window may get before its prose stops being readable.
///
/// That number is the page's own, not `--pane`: that variable is
/// `sheet_max_w`, which the library spends on the surfaces holding prose
/// *inside* an app — a sheet, the notices pane, a select's picker.
/// Borrowing it would make this cap look like a library rule rather than
/// a page agreeing with one, and retuning it would move all of those
/// panes. 560 is the phone's answer; a desktop window reading 560px of
/// 1400 looks like a phone emulator, so it steps once and no further.
///
/// It goes on the mount container rather than on the screen inside it,
/// because the driver reports that container's width to core as the
/// viewport (docs/internals/dom-edition.md): a cap the page kept to
/// itself would be a column core never heard of, and every measured
/// decision core makes — where prose wraps, whether a row of actions
/// folds, whether a track has to bleed — would be answered against a
/// width nobody is looking at. Which is also why the step at 900px is
/// not a page style: it hands core a wider viewport and has it answer
/// those questions again.
///
/// A file rather than the `<style>` block this used to be, for the
/// reason webBootJs is a file: a policy that admitted inline blocks
/// would admit every other one too, and a policy that hashed them would
/// be one no consumer could lift to their own edge without carrying
/// hashes that change under them (`webIndexHtml` states the policy).
pub const web_page_css: []const u8 =
    \\:root { --page-col: 560px; }
    \\@media (min-width: 900px) { :root { --page-col: 760px; } }
    \\body { margin: 0; background: var(--paper); }
    \\#app { max-width: calc(var(--page-col) + 2 * var(--page-pad)); margin-inline: auto; }
    \\
;

/// The page's boot module: the live driver's `mount` over the module the
/// site carries, which is the only line of JavaScript a nokre site has
/// that is not nokre's own (docs/internals/dom-edition.md).
///
/// It is a file for one reason, and the reason is the policy: an inline
/// `<script>` is what `script-src 'self'` exists to refuse, and refusing
/// it is worth more than the request this file costs — a page that could
/// run one inline script could run the one an injection wrote. The name
/// is escaped as a JSON string because JSON's escapes are JavaScript's,
/// and a module name is a consumer's string.
pub fn webBootJs(gpa: std.mem.Allocator, web: Web) error{OutOfMemory}![]u8 {
    const wasm_js = try jsonEscapedAlloc(gpa, web.module_wasm);
    defer gpa.free(wasm_js);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\import {{ mount }} from "./live.js";
        \\await mount({{ wasm: "./{s}", into: document.getElementById("app") }});
        \\
    , .{wasm_js});
    return out.toOwnedSlice(gpa);
}

/// The whole web host page, so a consumer authors no HTML at all: the
/// title and the manifest come from the declaration, and the two files
/// beside it — `page.css` and `boot.js`, emitted above — carry the
/// column and the mount. live.js, services.js, live-worker.js, sw.js,
/// style.css and the fonts ride along in the same directory (build.zig's
/// `addWebSite` writes the set); the page names only live.js's boot,
/// which imports the rest itself. It is the only host page nokre has —
/// the kitchen sink's own site is served from this same emitter — so
/// there is no second one to drift from.
///
/// ## The policy
///
/// The page ships a Content-Security-Policy, because a site nokre
/// generates whole is a site nokre can say the truth about: the edition
/// knows every request its own page makes, and a consumer hand-editing
/// a generated page would lose the policy on their next build.
///
/// It is an inventory of what the DOM edition actually does, not a
/// template — every directive below is here because something would
/// break without it, and `default-src 'none'` is what makes that
/// claim checkable: a fetch nobody named is a fetch nobody makes.
///
/// - `script-src 'self' 'wasm-unsafe-eval'` — boot.js and the driver's
///   three modules are the site's own files. The wasm keyword is the
///   module itself: compiling one is script execution to a browser, and
///   under any script-src Chrome and Firefox refuse it without this.
///   `'wasm-unsafe-eval'` and not `'unsafe-eval'` — nokre calls neither
///   `eval` nor `new Function`, and the narrow keyword says so.
/// - `worker-src 'self'` — two of them, both the site's own files:
///   live-worker.js, the compute actor, which is the same module
///   instantiated a second time (docs/services.md), and sw.js, the
///   service worker the notification service registers
///   (docs/internals/notifications.md — Chrome for Android serves
///   `showNotification` from nowhere else, and a push arrives with no
///   page open at all). Stated because worker-src falls back to
///   child-src and then to default-src, which is 'none'; the service
///   worker's own execution context is governed by the headers its file
///   is served with, not by this page's policy.
/// - `style-src 'self' 'unsafe-inline'` with `style-src-elem 'self'` —
///   the generated stylesheet and this page's own are files, so no
///   `<style>` block is admitted anywhere. The inline part is
///   *attributes*, which the serializer writes on element after element:
///   a list's measured gutter, a QR's whole-pixel side, a track's bleed,
///   a container's own gap and padding (docs/internals/dom-edition.md
///   says why each is a measured number and not a stylesheet guess).
///   They cannot be hashed — every one of them is a value layout just
///   computed — and they cannot be moved to script, because the static
///   driver writes pages that run none. So the narrower pair carries the
///   loosening: elements are files only, attributes are inline, and a
///   browser too old for the split falls back to the style-src line,
///   which a page shipping no `<style>` block never spends.
/// - `img-src 'self'` — the two icons the page links. Nothing else: the
///   QR is inline `<svg>` markup rather than an image request, and the
///   element set has no image in it.
/// - `font-src 'self'` — the four bundled faces, from `fonts/` beside
///   the page.
/// - `connect-src 'self'` plus `Web.connect_src` — the wasm module and
///   any seed arrive by fetch, which is this directive and not
///   script-src; so does every request the http service makes, and that
///   is the one place an app outgrows what nokre can know. It is
///   also the only directive a consumer extends, because a fetch is the
///   only outbound request an app's own code can make: no app supplies
///   script, style, fonts or images to this edition.
/// - `manifest-src 'self'` — the web-app manifest, which likewise falls
///   back to default-src.
/// - `base-uri 'none'` and `form-action 'none'` — neither falls back to
///   default-src, so 'none' has to be said. An injected `<base>` would
///   re-point every relative URL in the page, and nokre emits no form.
///
/// What a meta tag cannot carry, whatever it says: `frame-ancestors`,
/// `report-uri`/`report-to` and `sandbox` are ignored in one by spec, so
/// they stay the deploying edge's — getting-started.md tells a consumer
/// so in as many words, because a page that looked like the whole story
/// would be worse than no policy at all.
pub fn webIndexHtml(gpa: std.mem.Allocator, decl: Decl, web: Web) error{OutOfMemory}![]u8 {
    const name_html = try xmlEscapedAlloc(gpa, decl.name);
    defer gpa.free(name_html);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // First in the head, before anything it governs: a policy only ever
    // applies to what the parser meets after it.
    try out.appendSlice(gpa,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta http-equiv="Content-Security-Policy" content="
        \\  default-src 'none';
        \\  script-src 'self' 'wasm-unsafe-eval';
        \\  worker-src 'self';
        \\  style-src 'self' 'unsafe-inline';
        \\  style-src-elem 'self';
        \\  img-src 'self';
        \\  font-src 'self';
        \\  connect-src 'self'
    );
    // One space per source, on the line connect-src already owns: the
    // consumer's own hosts are the only part of this policy that is not
    // the same in every site nokre builds. `badConnectSrc` has already
    // refused anything that could close the attribute or the directive.
    for (web.connect_src) |src| {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, src);
    }
    try out.appendSlice(gpa,
        \\;
        \\  manifest-src 'self';
        \\  base-uri 'none';
        \\  form-action 'none'
        \\">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>
    );
    try out.appendSlice(gpa, name_html);
    try out.appendSlice(gpa,
        \\</title>
        \\<link rel="manifest" href="manifest.webmanifest">
        \\<link rel="icon" type="image/png" href="icon-192.png">
        \\<link rel="apple-touch-icon" href="icon-192.png">
        \\<link rel="stylesheet" href="style.css">
        \\<link rel="stylesheet" href="page.css">
        \\<meta name="theme-color" media="(prefers-color-scheme: light)" content="#ffffff">
        \\<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#000000">
        \\</head>
        \\<body>
        \\<div id="app"></div>
        \\<script type="module" src="boot.js"></script>
        \\</body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(gpa);
}

/// One row per icon file the pkg tree carries, path relative to the
/// tree root. `cell` is chosen per platform mask, not per taste:
/// square icons (iOS, Android legacy, web) use size/8 — the mark spans
/// 62.5%, whose corners sit inside iOS's superellipse crop — and
/// Android adaptive foregrounds use 2·size/27, putting the mark at
/// 40 dp of the 108 dp canvas: Google's keyline for a square logo,
/// with the mark's diagonal inside the 66 dp always-visible circle no
/// matter which mask an OEM picks. Every (size, cell) pair divides
/// exactly, so no icon depends on a rounding rule. Apple's row leads
/// the table because a declared Icon Composer bundle displaces it —
/// `derivedIcons` below.
pub const IconFile = struct { path: []const u8, size: u32, cell: u32 };
pub const icon_files = [_]IconFile{
    .{ .path = "ios/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png", .size = 1024, .cell = 128 },
    .{ .path = "android/res/mipmap-mdpi/ic_launcher.png", .size = 48, .cell = 6 },
    .{ .path = "android/res/mipmap-hdpi/ic_launcher.png", .size = 72, .cell = 9 },
    .{ .path = "android/res/mipmap-xhdpi/ic_launcher.png", .size = 96, .cell = 12 },
    .{ .path = "android/res/mipmap-xxhdpi/ic_launcher.png", .size = 144, .cell = 18 },
    .{ .path = "android/res/mipmap-xxxhdpi/ic_launcher.png", .size = 192, .cell = 24 },
    .{ .path = "android/res/mipmap-mdpi/ic_launcher_fg.png", .size = 108, .cell = 8 },
    .{ .path = "android/res/mipmap-hdpi/ic_launcher_fg.png", .size = 162, .cell = 12 },
    .{ .path = "android/res/mipmap-xhdpi/ic_launcher_fg.png", .size = 216, .cell = 16 },
    .{ .path = "android/res/mipmap-xxhdpi/ic_launcher_fg.png", .size = 324, .cell = 24 },
    .{ .path = "android/res/mipmap-xxxhdpi/ic_launcher_fg.png", .size = 432, .cell = 32 },
    .{ .path = "web/icon-192.png", .size = 192, .cell = 24 },
    .{ .path = "web/icon-512.png", .size = 512, .cell = 64 },
};

/// The derived icons the tree carries. A declared Icon Composer bundle
/// (apple_icon.zig) takes Apple's slot whole: actool resolves the app
/// icon by name, so a derived `AppIcon.appiconset` shipping beside an
/// `AppIcon.icon` would be a second answer to one question — and the
/// derived mark is the *default*, never a fallback layered under real
/// art. Android and the web keep it either way; the bundle is an Apple
/// format and nothing else can read it.
pub fn derivedIcons(apple_bundle_declared: bool) []const IconFile {
    return if (apple_bundle_declared) icon_files[1..] else &icon_files;
}

/// The asset-catalog scaffolding around the one iOS icon: Xcode 14+
/// accepts a single 1024 image and derives every slot, so the catalog
/// is two constant JSON files and one PNG — no per-size table on
/// Apple's side. Constant because nothing identity-shaped lives here.
/// The catalog itself ships either way — the Xcode template compiles
/// it as a resource — but the appiconset inside is the derived mark's,
/// and gives way to a declared `.icon` bundle (`derivedIcons`).
pub const ios_assets_contents_json: []const u8 =
    \\{
    \\  "info" : {
    \\    "author" : "xcode",
    \\    "version" : 1
    \\  }
    \\}
    \\
;
pub const ios_appicon_contents_json: []const u8 =
    \\{
    \\  "images" : [
    \\    {
    \\      "filename" : "AppIcon1024.png",
    \\      "idiom" : "universal",
    \\      "platform" : "ios",
    \\      "size" : "1024x1024"
    \\    }
    \\  ],
    \\  "info" : {
    \\    "author" : "xcode",
    \\    "version" : 1
    \\  }
    \\}
    \\
;

/// Adaptive icon (API 26+, the example's minSdk): paper background
/// layer as a color resource, the mark as an opaque foreground bitmap.
/// Opaque on purpose — a transparent foreground would need an alpha
/// channel the PNG deliberately lacks, and since the foreground covers
/// the canvas, the background layer only ever shows through OEM
/// parallax cropping, where it is the same paper. The legacy
/// `ic_launcher.png` mipmaps beside it serve any consumer that lowers
/// minSdk below 26.
pub const android_adaptive_icon_xml: []const u8 =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    \\    <background android:drawable="@color/nokre_icon_background" />
    \\    <foreground android:drawable="@mipmap/ic_launcher_fg" />
    \\</adaptive-icon>
    \\
;
pub const android_icon_values_xml: []const u8 =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<resources>
    \\    <color name="nokre_icon_background">#FFFFFFFF</color>
    \\</resources>
    \\
;

fn xmlEscapedAlloc(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        '\'' => try out.appendSlice(gpa, "&apos;"),
        else => try out.append(gpa, c),
    };
    return out.toOwnedSlice(gpa);
}

fn jsonEscapedAlloc(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        else => if (c < 0x20)
            try out.print(gpa, "\\u{x:0>4}", .{c})
        else
            try out.append(gpa, c),
    };
    return out.toOwnedSlice(gpa);
}
