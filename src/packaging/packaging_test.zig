//! Golden tests for the packaging emitters: the expected files are
//! embedded byte-for-byte from testdata/, the manifest counterpart of
//! tests/goldens — a formatting or derivation change must show up as a
//! reviewable diff of the actual artifact, not as a mutated string
//! literal. The fixture name carries an `&` so every emitter proves its
//! escaping on the one field consumers control freely.

const std = @import("std");
const packaging = @import("packaging.zig");

const fixture: packaging.Decl = .{
    .name = "Kitchen & Sink",
    .id = "dev.nokre.kitchensink_test",
    .version = "1.2.0",
    .build = 42,
};

test "ios Info.plist is byte-exact" {
    const actual = try packaging.iosInfoPlist(std.testing.allocator, fixture, .{});
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/Info.plist"), actual);
}

test "ios Info.plist escapes the version like the name" {
    var decl = fixture;
    decl.version = "1.2.0 <beta & candidate>";
    const actual = try packaging.iosInfoPlist(std.testing.allocator, decl, .{});
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(
        u8,
        actual,
        "<string>1.2.0 &lt;beta &amp; candidate&gt;</string>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "<beta") == null);
}

test "AndroidManifest.xml is byte-exact" {
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, .{}, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.xml"), actual);
}

// deep_link derivations: two claimed domains prove the App-Links
// intent-filter, the associated-domains entitlement, and both server
// files. The order in `deep_link_domains` is the developer's and must
// survive verbatim into every artifact — a reordered array is a
// reviewable diff, never a silent shuffle.
const deep_link_services: packaging.Services = .{
    .deep_link_domains = &.{ "example.com", "app.example.com" },
};

test "AndroidManifest.xml grows the App-Links intent-filter when deep_link claims domains" {
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, deep_link_services, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.deeplink.xml"), actual);
}

test "iOS entitlements is byte-exact when deep_link claims domains" {
    const actual = (try packaging.iosEntitlements(std.testing.allocator, fixture, deep_link_services)).?;
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/App.entitlements"), actual);
}

test "apple-app-site-association is byte-exact when deep_link claims domains" {
    const actual = (try packaging.appleAppSiteAssociation(std.testing.allocator, fixture, deep_link_services)).?;
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/apple-app-site-association"), actual);
}

test "assetlinks.json is byte-exact when deep_link claims domains" {
    const actual = (try packaging.androidAssetLinks(std.testing.allocator, fixture, deep_link_services)).?;
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/assetlinks.json"), actual);
}

test "no deep_link domains emits no association files, and the manifest is unchanged" {
    // The unlinked row: silence is a value, not a gap. The three server
    // artifacts are null and the manifest is byte-identical to the
    // zero-service golden — proof the intent-filter is purely additive.
    try std.testing.expectEqual(@as(?[]u8, null), try packaging.iosEntitlements(std.testing.allocator, fixture, .{}));
    try std.testing.expectEqual(@as(?[]u8, null), try packaging.appleAppSiteAssociation(std.testing.allocator, fixture, .{}));
    try std.testing.expectEqual(@as(?[]u8, null), try packaging.androidAssetLinks(std.testing.allocator, fixture, .{}));
    const manifest = try packaging.androidManifest(std.testing.allocator, fixture, .{}, "nokre_app");
    defer std.testing.allocator.free(manifest);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.xml"), manifest);
}

// oauth derivations: two schemes prove the CFBundleURLTypes entry and
// the Android VIEW intent-filter, and `oauth_apple` proves the
// entitlement. Order is the developer's here too. Both schemes are
// realistic shapes — the app's own reverse-DNS id, and Google's reversed
// client id, which is what an iOS OAuth client actually redirects to.
const oauth_services: packaging.Services = .{
    .oauth_schemes = &.{ "dev.nokre.kitchensink_test", "com.googleusercontent.apps.1234-abcd" },
};

test "ios Info.plist registers the redirect schemes when oauth is linked" {
    const actual = try packaging.iosInfoPlist(std.testing.allocator, fixture, oauth_services);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/Info.oauth.plist"), actual);
}

test "AndroidManifest.xml grows the redirect intent-filter when oauth is linked" {
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, oauth_services, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.oauth.xml"), actual);
}

test "iOS entitlements carries applesignin, alongside associated-domains" {
    // Both services at once: the entitlement file is one document, the
    // keys are alphabetical, and neither derivation may displace the
    // other — the failure mode a per-service file would never catch.
    var both = deep_link_services;
    both.oauth_apple = true;
    const actual = (try packaging.iosEntitlements(std.testing.allocator, fixture, both)).?;
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/App.oauth.entitlements"), actual);
}

test "Sign in with Apple alone still emits an entitlement" {
    const actual = (try packaging.iosEntitlements(std.testing.allocator, fixture, .{ .oauth_apple = true })).?;
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "com.apple.developer.applesignin") != null);
    // …and nothing of deep_link's, which claims no domains here.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, actual, "associated-domains"));
}

test "unlinked oauth derives nothing anywhere" {
    // The unlinked row, stated rather than assumed: with no schemes and
    // no Sign in with Apple, both manifests are byte-identical to the
    // zero-service goldens — proof every oauth derivation is additive.
    // Windows, Linux, and the web have no row at all: a loopback
    // listener registers nothing, and on the web the origin is the
    // registration.
    const plist = try packaging.iosInfoPlist(std.testing.allocator, fixture, .{ .secure_store = true });
    defer std.testing.allocator.free(plist);
    try std.testing.expectEqualStrings(@embedFile("testdata/Info.plist"), plist);
    const manifest = try packaging.androidManifest(std.testing.allocator, fixture, .{ .secure_store = true }, "nokre_app");
    defer std.testing.allocator.free(manifest);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.xml"), manifest);
    try std.testing.expectEqual(@as(?[]u8, null), try packaging.iosEntitlements(std.testing.allocator, fixture, .{}));
}

// iap derivations: one permission, on one platform. The smallest
// footprint of any linking service, and the only one that is a
// permission rather than a registration.
test "AndroidManifest.xml grows the BILLING permission when iap is linked" {
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, .{ .iap = true }, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.iap.xml"), actual);
}

test "iap derives nothing on Apple, and that silence is the row" {
    // In-App Purchase is a capability on the App ID, enabled in Apple's
    // console and carried by the provisioning profile — there is no
    // plist key and no entitlement for it, so both artifacts must be
    // byte-identical to the zero-service goldens. Asserted rather than
    // assumed: "we emit nothing" is a claim a future edit can break
    // silently.
    const plist = try packaging.iosInfoPlist(std.testing.allocator, fixture, .{ .iap = true });
    defer std.testing.allocator.free(plist);
    try std.testing.expectEqualStrings(@embedFile("testdata/Info.plist"), plist);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try packaging.iosEntitlements(std.testing.allocator, fixture, .{ .iap = true }),
    );
}

test "the BILLING permission is additive, and rides beside every other service" {
    // Two services deriving into the same manifest at once: the
    // permission block and the intent-filter are independent, and
    // neither may displace the other.
    var both = oauth_services;
    both.iap = true;
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, both, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "com.android.vending.BILLING") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "android:scheme=\"dev.nokre.kitchensink_test\"") != null);
}

// notification derivations: the local half is one permission, and it is
// the only *dangerous* one on the roster — prompted at runtime, refusable
// and revocable — so unlike BILLING its arrival is something a user sees.
// The push half adds an entitlement on Apple and a service on Android.
const notification_services: packaging.Services = .{ .notification = true };
const push_services: packaging.Services = .{ .notification = true, .notification_push = true };

test "AndroidManifest.xml grows POST_NOTIFICATIONS when notification is linked" {
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, notification_services, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.notification.xml"), actual);
}

test "push adds the FCM service, and only push does" {
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, push_services, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/AndroidManifest.notification_push.xml"), actual);
    // The local half declares no service: a push arrives with no
    // activity, which is the whole reason that <service> exists, and an
    // app that only reminds locally has nothing for Firebase to bind.
    const local = try packaging.androidManifest(std.testing.allocator, fixture, notification_services, "nokre_app");
    defer std.testing.allocator.free(local);
    try std.testing.expect(std.mem.indexOf(u8, local, "MESSAGING_EVENT") == null);
}

test "no exact-alarm permission is ever derived" {
    // The refusal is the row: an app whose fire date reads "remind me in
    // the morning" must not make its consumer justify USE_EXACT_ALARM to
    // Play, and RECEIVE_BOOT_COMPLETED would mean nokre keeping a durable
    // schedule of its own — the thing `schedule` exists not to be.
    const actual = try packaging.androidManifest(std.testing.allocator, fixture, push_services, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "EXACT_ALARM") == null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "RECEIVE_BOOT_COMPLETED") == null);
}

test "push derives the aps-environment entitlement; local derives none" {
    const ents = (try packaging.iosEntitlements(std.testing.allocator, fixture, push_services)).?;
    defer std.testing.allocator.free(ents);
    try std.testing.expectEqualStrings(@embedFile("testdata/App.push.entitlements"), ents);
    // Local notifications ask at runtime through UNUserNotificationCenter
    // — no plist key, no entitlement — so the file must not exist at all.
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try packaging.iosEntitlements(std.testing.allocator, fixture, notification_services),
    );
    const plist = try packaging.iosInfoPlist(std.testing.allocator, fixture, push_services);
    defer std.testing.allocator.free(plist);
    try std.testing.expectEqualStrings(@embedFile("testdata/Info.plist"), plist);
}

test "aps-environment rides beside the other entitlements, alphabetically first" {
    var both = deep_link_services;
    both.notification = true;
    both.notification_push = true;
    both.oauth_apple = true;
    const ents = (try packaging.iosEntitlements(std.testing.allocator, fixture, both)).?;
    defer std.testing.allocator.free(ents);
    const aps = std.mem.indexOf(u8, ents, "aps-environment").?;
    const signin = std.mem.indexOf(u8, ents, "applesignin").?;
    const domains = std.mem.indexOf(u8, ents, "associated-domains").?;
    try std.testing.expect(aps < signin);
    try std.testing.expect(signin < domains);
}

// The macOS bundle: packaging emitted no plist for this platform until a
// service needed the bundle identifier one describes
// (docs/internals/notifications.md).
test "macOS Info.plist is byte-exact" {
    const actual = try packaging.macosInfoPlist(std.testing.allocator, fixture, .{}, "nokre_app");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/Info.macos.plist"), actual);
}

test "the macOS plist is not the iOS one" {
    // Two emitters rather than one with a flag: the scene manifest is
    // UIKit's and means nothing on the desktop, and NSHighResolution
    // Capable is the pixel model's stake in the file — without it AppKit
    // hands the shell a 1x backing store and every glyph resamples.
    const mac = try packaging.macosInfoPlist(std.testing.allocator, fixture, .{}, "nokre_app");
    defer std.testing.allocator.free(mac);
    try std.testing.expect(std.mem.indexOf(u8, mac, "NSHighResolutionCapable") != null);
    try std.testing.expect(std.mem.indexOf(u8, mac, "UIApplicationSceneManifest") == null);
    const ios = try packaging.iosInfoPlist(std.testing.allocator, fixture, .{});
    defer std.testing.allocator.free(ios);
    try std.testing.expect(std.mem.indexOf(u8, ios, "NSHighResolutionCapable") == null);
}

test "the icns container is well-formed and every entry is a PNG" {
    const actual = try packaging.icon.icns(std.testing.allocator, fixture.id);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("icns", actual[0..4]);
    // The header's length covers the whole file, entries included: a
    // container whose own size disagrees with its bytes is one Finder
    // silently ignores.
    const total = std.mem.readInt(u32, actual[4..8], .big);
    try std.testing.expectEqual(actual.len, total);

    var at: usize = 8;
    var seen: usize = 0;
    while (at + 8 <= actual.len) : (seen += 1) {
        const tag = actual[at..][0..4];
        const len = std.mem.readInt(u32, actual[at + 4 ..][0..4], .big);
        try std.testing.expectEqualStrings(packaging.icon.icns_entries[seen].tag, tag);
        try std.testing.expect(len > 8 and at + len <= actual.len);
        // The payload is the same PNG every other platform's icon is —
        // nothing is resampled or re-encoded for Apple.
        try std.testing.expectEqualStrings("\x89PNG", actual[at + 8 ..][0..4]);
        at += len;
    }
    try std.testing.expectEqual(packaging.icon.icns_entries.len, seen);
    try std.testing.expectEqual(actual.len, at);
}

test "android package.properties is byte-exact" {
    const actual = try packaging.androidProperties(std.testing.allocator, fixture);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/package.properties"), actual);
}

test "android package.properties escapes what java.util.Properties would mis-parse" {
    var decl = fixture;
    // A newline would smuggle an extra key, a backslash starts an escape
    // sequence, and leading whitespace is silently trimmed on load.
    decl.version = " 1.2\\0\nsneaky=true\r";
    const actual = try packaging.androidProperties(std.testing.allocator, decl);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(
        u8,
        actual,
        "version=\\ 1.2\\\\0\\nsneaky=true\\r\n",
    ) != null);
    // Exactly the three declared keys survive — nothing was smuggled in.
    try std.testing.expect(std.mem.count(u8, actual, "\n") == 4);
}

test "web manifest is byte-exact" {
    const actual = try packaging.webManifest(std.testing.allocator, fixture);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/manifest.webmanifest"), actual);
}

test "web index.html is byte-exact" {
    const actual = try packaging.webIndexHtml(std.testing.allocator, fixture, .{});
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/index.html"), actual);
}

test "declared hosts join connect-src and no other directive" {
    const actual = try packaging.webIndexHtml(std.testing.allocator, fixture, .{
        .connect_src = &.{ "https://api.example.com", "wss://live.example.com" },
    });
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/index.connect.html"), actual);

    // The golden above is the contract; this is the property it exists
    // for. Every other directive is byte-identical to the page an app
    // that declared nothing gets — a consumer adding a host must never
    // be adding anything else.
    const plain = try packaging.webIndexHtml(std.testing.allocator, fixture, .{});
    defer std.testing.allocator.free(plain);
    var declared = std.mem.splitScalar(u8, actual, '\n');
    var none = std.mem.splitScalar(u8, plain, '\n');
    while (none.next()) |line| {
        const other = declared.next().?;
        if (std.mem.indexOf(u8, line, "connect-src") != null) {
            try std.testing.expectEqualStrings("  connect-src 'self' https://api.example.com wss://live.example.com;", other);
            continue;
        }
        try std.testing.expectEqualStrings(line, other);
    }
    try std.testing.expectEqual(null, declared.next());
}

/// The policy as a browser reads it: the content attribute of the one
/// meta tag that carries it. Everything below asserts against this
/// rather than against the file, because a directive is what the page
/// grants and a line is only how it was written.
fn policyOf(html: []const u8) []const u8 {
    const open = "<meta http-equiv=\"Content-Security-Policy\" content=\"";
    const at = std.mem.indexOf(u8, html, open).?;
    const rest = html[at + open.len ..];
    return rest[0..std.mem.indexOfScalar(u8, rest, '"').?];
}

test "the page's policy is the stated directive set, once each" {
    const html = try packaging.webIndexHtml(std.testing.allocator, fixture, .{});
    defer std.testing.allocator.free(html);

    // The set every nokre page carries, in order — a consumer trusting
    // nokre to emit this is trusting *this list*, so it is written out
    // here rather than left implied by a golden that a regeneration
    // could quietly rewrite. Each entry's rationale is webIndexHtml's
    // doc comment; what this asserts is that the page grants these
    // eleven powers and no twelfth.
    const directives = [_][]const u8{
        "default-src 'none'",
        "script-src 'self' 'wasm-unsafe-eval'",
        "worker-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "style-src-elem 'self'",
        "img-src 'self'",
        "font-src 'self'",
        "connect-src 'self'",
        "manifest-src 'self'",
        "base-uri 'none'",
        "form-action 'none'",
    };
    var it = std.mem.splitScalar(u8, policyOf(html), ';');
    var seen: usize = 0;
    while (it.next()) |raw| : (seen += 1) {
        try std.testing.expect(seen < directives.len);
        try std.testing.expectEqualStrings(directives[seen], std.mem.trim(u8, raw, " \n"));
    }
    try std.testing.expectEqual(directives.len, seen);

    // One policy on the page, and it is in the head before anything it
    // governs: a second meta tag would be a second policy, and the
    // intersection of two is not what either says.
    try std.testing.expectEqual(1, std.mem.count(u8, html, "Content-Security-Policy"));
    try std.testing.expect(std.mem.indexOf(u8, html, "Content-Security-Policy").? < std.mem.indexOf(u8, html, "<title>").?);
}

test "connect-src carries 'self', the declared origins, and nothing else" {
    const declared = [_][]const u8{ "https://api.example.com", "wss://live.example.com:8443", "*.example.com" };
    const html = try packaging.webIndexHtml(std.testing.allocator, fixture, .{ .connect_src = &declared });
    defer std.testing.allocator.free(html);

    const policy = policyOf(html);
    const at = std.mem.indexOf(u8, policy, "connect-src").?;
    const line = policy[at..][0..std.mem.indexOfScalar(u8, policy[at..], ';').?];

    // Token by token, because that is how the directive is parsed: the
    // origin the page was served from, then the declaration's own, in
    // the order it was declared and with nothing between them.
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    try std.testing.expectEqualStrings("connect-src", tokens.next().?);
    try std.testing.expectEqualStrings("'self'", tokens.next().?);
    for (declared) |src| try std.testing.expectEqualStrings(src, tokens.next().?);
    try std.testing.expectEqual(null, tokens.next());

    // And the directive count did not move: a declared host is a
    // source, never a directive.
    const plain = try packaging.webIndexHtml(std.testing.allocator, fixture, .{});
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqual(
        std.mem.count(u8, policyOf(plain), ";"),
        std.mem.count(u8, policy, ";"),
    );
}

test "a source that could end its own directive is refused" {
    // The shapes a policy carries.
    try std.testing.expectEqual(null, packaging.badConnectSrc(&.{
        "https://api.example.com", "*.example.com", "wss://live.example.com:8443", "self.example.com",
    }));
    // A second directive smuggled in behind the first, the space that
    // would start one, and the quote that would close the attribute the
    // policy lives in — each is the whole point of checking at all.
    try std.testing.expectEqualStrings("x.com; script-src *", packaging.badConnectSrc(&.{"x.com; script-src *"}).?);
    try std.testing.expectEqualStrings("x.com 'unsafe-inline'", packaging.badConnectSrc(&.{"x.com 'unsafe-inline'"}).?);
    try std.testing.expectEqualStrings("x.com\">", packaging.badConnectSrc(&.{"x.com\">"}).?);
    // And the one that needs no smuggling: every host there is.
    try std.testing.expectEqualStrings("*", packaging.badConnectSrc(&.{"*"}).?);
    try std.testing.expectEqualStrings("", packaging.badConnectSrc(&.{""}).?);
}

test "no byte a consumer supplies can smuggle a directive" {
    // The policy is written on one line inside one attribute, so three
    // bytes end it and every one of them has a name: `;` starts the
    // next directive, a space starts the next *source* — which is how
    // `'unsafe-inline'` arrives — and `"` closes the attribute. A
    // newline is the same story told by a config file: a value read out
    // of YAML or an environment variable carries the line break with
    // it, and the page's policy is line-oriented to read.
    for ("; \"\n\r\t,'\\<>&") |c| {
        var buf: [4]u8 = .{ 'x', '.', c, 0 };
        try std.testing.expectEqualStrings(buf[0..3], packaging.badConnectSrc(&.{buf[0..3]}).?);
    }

    // The sweep the three cases above are examples of: for every byte
    // there is, the answer is the charset's — a source expression is
    // letters, digits and the punctuation a scheme, host, port, path
    // and wildcard need, and nothing outside it reaches a page. Checked
    // in the middle of a source rather than alone, because that is
    // where a smuggled byte would hide.
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        const in_charset = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', ':', '/', '*', '+', '[', ']' => true,
            else => false,
        };
        const src = [_]u8{ 'x', c, 'y' };
        try std.testing.expectEqual(in_charset, packaging.badConnectSrc(&.{&src}) == null);
    }

    // The refusal is the whole gate: `webIndexHtml` writes what it is
    // handed, and `build.zig` runs `badConnectSrc` over the declaration
    // before any emitter sees it (the `web_connect_src` failure there
    // names the option and the rule). So this test is what stands
    // between a consumer's string and a second directive — the reason
    // it sweeps every byte instead of naming the ones someone thought
    // of.
    try std.testing.expectEqual(null, packaging.badConnectSrc(&.{}));
}

test "web boot.js is byte-exact" {
    const actual = try packaging.webBootJs(std.testing.allocator, .{});
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/boot.js"), actual);
}

test "a module name is escaped as the JavaScript string it lands in" {
    const actual = try packaging.webBootJs(std.testing.allocator, .{ .module_wasm = "a\".wasm" });
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "\"./a\\\".wasm\"") != null);
}

test "app icon png is byte-exact" {
    // The mark is a pure function of the id and the PNG writer is fully
    // specified in icon.zig, so icon bytes golden like any manifest.
    // Regenerate by deleting the file and re-emitting via icon.png
    // (48, cell 6 — the mdpi launcher row in packaging.icon_files).
    const actual = try packaging.icon.png(std.testing.allocator, fixture.id, 48, 6);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/icon-48.png"), actual);
}

test "a declared Icon Composer bundle takes Apple's slot, and only Apple's" {
    // Omitted, the tree is exactly what it has always been: the option
    // costs existing consumers not one byte.
    try std.testing.expectEqual(packaging.icon_files.len, packaging.derivedIcons(false).len);

    // Declared, the derived appiconset gives way — actool resolves the
    // app icon by name, so two answers named AppIcon is one too many —
    // and nothing under ios/ is derived any more.
    const with_bundle = packaging.derivedIcons(true);
    try std.testing.expectEqual(packaging.icon_files.len - 1, with_bundle.len);
    for (with_bundle) |f| try std.testing.expect(!std.mem.startsWith(u8, f.path, "ios/"));

    // Android and the web keep the mark either way: `.icon` is an Apple
    // format and nothing else can read it.
    for (packaging.icon_files) |f| {
        if (std.mem.startsWith(u8, f.path, "ios/")) continue;
        var kept = false;
        for (with_bundle) |g| kept = kept or std.mem.eql(u8, f.path, g.path);
        try std.testing.expect(kept);
    }

    // The bundle lands where each Apple project looks, under the name
    // the Xcode setting is pinned to.
    try std.testing.expectEqualStrings("ios/AppIcon.icon", packaging.apple_icon.delivery_paths[0]);
    try std.testing.expectEqualStrings("macos/AppIcon.icon", packaging.apple_icon.delivery_paths[1]);
}

test "icon size table divides exactly — no icon depends on a rounding rule" {
    for (packaging.icon_files) |f| {
        // Cells fit and centre: the margin comment in icon.zig only
        // ever absorbs the odd remainder pixel.
        try std.testing.expect(packaging.icon.grid * f.cell <= f.size);
        // Every emitted icon actually encodes: derivation + encoding
        // hold for each (size, cell) the tree ships.
        const bytes = try packaging.icon.png(std.testing.allocator, fixture.id, f.size, f.cell);
        std.testing.allocator.free(bytes);
    }
}

test "json escaping covers quotes, backslashes, and control bytes" {
    const tricky: packaging.Decl = .{
        .name = "a \"b\" \\ c\n",
        .id = "dev.nokre.tricky",
        .version = "0.0.1",
        .build = 1,
    };
    const actual = try packaging.webManifest(std.testing.allocator, tricky);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "\"name\": \"a \\\"b\\\" \\\\ c\\u000a\"") != null);
}

test "id validation is the platform-rule intersection" {
    // Two or more dot-separated [a-z][a-z0-9_]* segments — Android's
    // applicationId charset, lowercased for Apple's case-insensitive
    // comparisons. UTF-8 passes through names, never ids.
    try packaging.validate(.{ .name = "x", .id = "dev.nokre.app_2", .version = "1", .build = 1 });
    const bad_ids = [_][]const u8{
        "single", // one segment is not reverse-DNS
        "Dev.app", // uppercase: Apple compares ids case-insensitively
        "dev.kitchen-sink", // dash: rejected by Android's applicationId
        "dev..app", // empty segment
        "dev.9app", // segments must start with a letter (Java package rule)
        "",
    };
    for (bad_ids) |id| {
        try std.testing.expectError(
            error.InvalidId,
            packaging.validate(.{ .name = "x", .id = id, .version = "1", .build = 1 }),
        );
    }
    // Android rejects versionCode 0; stores count builds from 1.
    try std.testing.expectError(
        error.InvalidBuild,
        packaging.validate(.{ .name = "x", .id = "dev.nokre.app", .version = "1", .build = 0 }),
    );
}
