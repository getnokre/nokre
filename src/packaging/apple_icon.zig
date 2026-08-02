//! apple_icon — the Icon Composer bundle a consumer declares, carried
//! into the packaging tree untouched.
//!
//! The derived mark (icon.zig) is what every app gets for nothing, and
//! it stays the default. An app that has real art brings Apple's own
//! format instead: a `.icon` bundle — a directory holding `icon.json`
//! and the layer images it names under `Assets/`. That format is the
//! one Apple icon nokre can carry at all, because it is a
//! *declaration*, not pixels: appearance (light, dark, tinted),
//! lighting, shadow, translucency and the glass material are values in
//! a JSON document over vector or bitmap layers, and every idiom's
//! rendering is Xcode's job. nokre resamples nothing, re-encodes
//! nothing, and models none of the schema — the same refusal that keeps
//! icon.zig's own PNG writer honest, applied from the other side.
//!
//! What is left is delivery, and delivery has one failure mode worth
//! catching: a bundle naming a layer image it does not carry, which
//! otherwise surfaces as an actool error deep inside an Xcode build, on
//! a machine that is not the one that declared it. `check` catches that
//! and the three cruder shapes (not a directory, no `icon.json`,
//! unparseable `icon.json`) at build-graph construction — packaging's
//! standing rule, the one `validate` applies to an id no store would
//! accept.
//!
//! Consumed by build.zig alone, like the rest of packaging; nothing
//! here compiles into an app.

const std = @import("std");
const Io = std.Io;

/// The extension Xcode recognizes. Checked on the declared path
/// because a directory of the right shape under the wrong name is not
/// an app icon to actool, and the mistake is invisible until then.
pub const extension = ".icon";

/// The manifest at the bundle root: the file that *is* the icon.
pub const manifest_name = "icon.json";

/// Layer images live here, named by `icon.json`'s `image-name`.
pub const assets_dir = "Assets";

/// The key naming a layer's image file. nokre knows this one word of
/// the schema and no more (see the module comment).
const image_name_key = "image-name";

/// Icon Composer manifests are a page of JSON over a handful of
/// layers; a megabyte is already three orders of magnitude of slack,
/// and the cap keeps a mistyped path from reading a disk image into
/// the build.
const manifest_limit: Io.Limit = .limited(1024 * 1024);

/// The name the bundle takes in the packaging tree, whatever it is
/// called in the consumer's source. Xcode finds an app icon by name —
/// `ASSETCATALOG_COMPILER_APPICON_NAME`, which the shipped project
/// template pins to `AppIcon` — so normalizing here is what lets that
/// setting be a constant instead of a second place identity is spelled.
pub const bundle_name = "AppIcon" ++ extension;

/// Where the declared bundle lands, one path per Apple platform that
/// reads it. The same bytes twice on purpose: the tree is addressed by
/// the platform that consumes it (`ios/`, `android/`, `web/`), and an
/// Xcode project for one Apple platform must never have to reach into
/// another's subtree to find its icon. Icon Composer's whole premise
/// is that these two are one icon — that is the format's claim, not a
/// duplication nokre invented.
pub const delivery_paths = [_][]const u8{
    "ios/" ++ bundle_name,
    "macos/" ++ bundle_name,
};

/// Everything a declared bundle can be wrong about, in the order
/// `check` can discover it. build.zig turns each into the sentence
/// naming the fix — the messages are build-speak and live there, with
/// the other refusals.
pub const Problem = union(enum) {
    /// The declared path does not end in `.icon`.
    not_dot_icon,
    missing,
    /// A file where a bundle directory was declared. Finder and Xcode
    /// both draw a `.icon` as a single item, so this is the honest
    /// mistake of the set.
    not_a_directory,
    /// Present, but the build cannot read it (permissions, a broken
    /// symlink, a truncated read).
    unreadable,
    no_manifest,
    malformed_manifest,
    /// The `image-name` the manifest names with no file under
    /// `Assets/`. Allocated from `check`'s allocator.
    missing_asset: []const u8,
};

/// The declared bundle at `parent`/`sub_path`, or null when it is
/// deliverable. Never rejects on schema: an unknown key, a new
/// specialization, a layer shape from a future Icon Composer are all
/// actool's business, and a nokre release must not become the reason a
/// consumer cannot use the icon Apple's tool just wrote.
pub fn check(
    gpa: std.mem.Allocator,
    io: Io,
    parent: Io.Dir,
    sub_path: []const u8,
) error{OutOfMemory}!?Problem {
    if (!std.mem.endsWith(u8, sub_path, extension)) return .not_dot_icon;

    var dir = parent.openDir(io, sub_path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        error.NotDir => .not_a_directory,
        else => .unreadable,
    };
    defer dir.close(io);

    const manifest = dir.readFileAlloc(io, manifest_name, gpa, manifest_limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .no_manifest,
        else => return .unreadable,
    };
    defer gpa.free(manifest);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, manifest, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .malformed_manifest,
    };
    defer parsed.deinit();

    return firstMissingAsset(gpa, io, dir, parsed.value);
}

/// Every `image-name` in the document, wherever it sits. Walking the
/// whole value tree rather than `groups[].layers[]` is the point: the
/// nesting is Apple's to change, the reference is what must resolve,
/// and a manifest whose layers moved must not silently stop being
/// checked. A non-string value under the key is left to actool — this
/// file judges no schema.
fn firstMissingAsset(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    value: std.json.Value,
) error{OutOfMemory}!?Problem {
    switch (value) {
        .object => |obj| {
            if (obj.get(image_name_key)) |named| switch (named) {
                .string => |name| {
                    const path = try std.fs.path.join(gpa, &.{ assets_dir, name });
                    defer gpa.free(path);
                    dir.access(io, path, .{}) catch
                        return .{ .missing_asset = try gpa.dupe(u8, name) };
                },
                else => {},
            };
            for (obj.values()) |child| {
                if (try firstMissingAsset(gpa, io, dir, child)) |problem| return problem;
            }
        },
        .array => |items| for (items.items) |child| {
            if (try firstMissingAsset(gpa, io, dir, child)) |problem| return problem;
        },
        else => {},
    }
    return null;
}

// ---- tests ----
//
// The fixture is a hand-written bundle in the shape Icon Composer
// exports (testdata/AppIcon.icon): a fill specialization per
// appearance, one group, one SVG layer. It is written into a temp
// directory rather than checked in place so the tests never depend on
// the process's working directory, and the checked-in copy stays the
// single description of the shape.

const testing = std.testing;
const fixture_manifest = @embedFile("testdata/AppIcon.icon/icon.json");
const fixture_asset = @embedFile("testdata/AppIcon.icon/Assets/mark.svg");

/// Write a bundle into `dir` under `name`, with the given manifest and
/// the fixture layer asset when `with_asset`.
fn writeBundle(dir: Io.Dir, name: []const u8, manifest: ?[]const u8, with_asset: bool) !void {
    try dir.createDirPath(testing.io, name);
    var bundle = try dir.openDir(testing.io, name, .{});
    defer bundle.close(testing.io);
    if (manifest) |bytes| {
        try bundle.writeFile(testing.io, .{ .sub_path = manifest_name, .data = bytes });
    }
    if (with_asset) {
        try bundle.createDirPath(testing.io, assets_dir);
        try bundle.writeFile(testing.io, .{
            .sub_path = assets_dir ++ "/mark.svg",
            .data = fixture_asset,
        });
    }
}

test "a complete bundle is deliverable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeBundle(tmp.dir, bundle_name, fixture_manifest, true);
    try testing.expectEqual(
        @as(?Problem, null),
        try check(testing.allocator, testing.io, tmp.dir, bundle_name),
    );
}

test "the shapes that are not a bundle at all" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The extension is checked before the filesystem: a directory of
    // the right contents under the wrong name is not an app icon.
    try writeBundle(tmp.dir, "AppIcon", fixture_manifest, true);
    try testing.expectEqual(
        @as(?Problem, .not_dot_icon),
        try check(testing.allocator, testing.io, tmp.dir, "AppIcon"),
    );

    try testing.expectEqual(
        @as(?Problem, .missing),
        try check(testing.allocator, testing.io, tmp.dir, "Nothing.icon"),
    );

    // A file, not a directory — the mistake Finder invites by drawing
    // the bundle as one item.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Flat.icon", .data = fixture_manifest });
    try testing.expectEqual(
        @as(?Problem, .not_a_directory),
        try check(testing.allocator, testing.io, tmp.dir, "Flat.icon"),
    );

    try writeBundle(tmp.dir, "Empty.icon", null, true);
    try testing.expectEqual(
        @as(?Problem, .no_manifest),
        try check(testing.allocator, testing.io, tmp.dir, "Empty.icon"),
    );

    try writeBundle(tmp.dir, "Broken.icon", "{ \"groups\": [", true);
    try testing.expectEqual(
        @as(?Problem, .malformed_manifest),
        try check(testing.allocator, testing.io, tmp.dir, "Broken.icon"),
    );
}

test "a layer image that does not ship is named, wherever it is nested" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The fixture manifest, without the asset it names: the failure
    // that would otherwise wait for actool on someone else's machine.
    try writeBundle(tmp.dir, bundle_name, fixture_manifest, false);
    const dangling = (try check(testing.allocator, testing.io, tmp.dir, bundle_name)).?;
    defer testing.allocator.free(dangling.missing_asset);
    try testing.expectEqualStrings("mark.svg", dangling.missing_asset);

    // Nesting nokre does not model: the reference resolves or it does
    // not, at any depth the format grows.
    try writeBundle(tmp.dir, "Deep.icon",
        \\{ "groups": [ { "groups": [ { "layers": [ { "image-name": "buried.png" } ] } ] } ] }
    , true);
    const deep = (try check(testing.allocator, testing.io, tmp.dir, "Deep.icon")).?;
    defer testing.allocator.free(deep.missing_asset);
    try testing.expectEqualStrings("buried.png", deep.missing_asset);
}

test "a manifest that names no layer image needs no Assets directory" {
    // Icon Composer can describe a fill with no layer at all, and the
    // check is about references resolving — not about a directory
    // existing for its own sake.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeBundle(tmp.dir, bundle_name,
        \\{ "fill-specializations": [ { "value": { "solid": "gray:1.00000,1.00000" } } ] }
    , false);
    try testing.expectEqual(
        @as(?Problem, null),
        try check(testing.allocator, testing.io, tmp.dir, bundle_name),
    );
}

test "the bundle is delivered to every Apple platform, under one name" {
    // The normalization the Xcode setting depends on: whatever the
    // consumer called their bundle, the tree carries AppIcon.icon.
    for (delivery_paths) |path| {
        try testing.expect(std.mem.endsWith(u8, path, "/" ++ bundle_name));
    }
    try testing.expectEqual(@as(usize, 2), delivery_paths.len);
}
