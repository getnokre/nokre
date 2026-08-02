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
    const actual = try packaging.webIndexHtml(std.testing.allocator, fixture, "app.wasm");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(@embedFile("testdata/index.html"), actual);
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
