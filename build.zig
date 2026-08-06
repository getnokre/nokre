const std = @import("std");
const builtin = @import("builtin");
const packaging = @import("src/packaging/packaging.zig");
/// The web driver's file set, from its one home: `addWebSite` copies
/// it, the js-parse gate parses it, and consumers read the same list
/// as `dom.driver_files` (driver_files.zig).
const dom_driver_files = @import("src/render/dom/driver_files.zig").driver_files;

// ---------------------------------------------------------------------------
// Consumer-facing build API (docs/getting-started.md). A consumer's
// build.zig imports this file by package name —
//
//     const nokre = @import("nokre");
//
// — and calls `addApp` to get the full windowed-app wiring for the
// current target: the nokre module configured for that platform, the
// Skia shim, the platform shell, AccessKit on desktop, and the
// generated packaging tree. nokre's own examples are built through the
// same functions below, so the consumer path is exercised by every
// `zig build run-…` in this repository.
// ---------------------------------------------------------------------------

/// App identity — declared once, baked into every platform at comptime
/// and fed to the packaging emitters (docs/services.md). The struct
/// lives with the emitters; this is the same declaration both consume.
pub const PackageDecl = packaging.Decl;

pub const AppOptions = struct {
    /// Artifact name: the executable on desktop, the wasm module on
    /// the web (the DOM edition's one artifact), the static library
    /// the Xcode/Gradle link consumes on mobile.
    name: []const u8,
    /// The app's root source file (the one with `pub fn main`, or the
    /// wasm/mobile entry exports).
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Declaring identity is what links the package_info service and
    /// what makes the packaging tree (`App.pkg`) exist — manifests are
    /// outputs of this declaration, never hand-written.
    pkg: ?PackageDecl = null,
    /// Linking the secure_store service; requires `pkg` — the id is
    /// the store's namespace (docs/services.md).
    secure_store: bool = false,
    /// Swap the platform store for the **dev file store**: a plaintext
    /// file under `$HOME/.nokre-dev-store` (or `$NOKRE_SECURE_STORE_DEV`)
    /// instead of the Keychain or the Secret Service. It is for the
    /// binary that drives a real app end to end outside `zig test`,
    /// where the OS store is not a driver's to use: macOS refuses the
    /// data-protection keychain to an unentitled process and leaves only
    /// the deprecated legacy keychain — the developer's own login
    /// keychain, which can raise a modal — and a headless Linux CI
    /// machine runs no keyring daemon at all.
    ///
    /// Not a fallback and not a runtime choice: a build-time swap a
    /// build file has to say out loud, refused unless the build is Debug
    /// and the target is macOS or desktop Linux, and announced on stderr
    /// at every launch of the binary that carries it. Requires
    /// `.secure_store` — it is a backend for the linked service, not a
    /// second service (docs/services.md).
    secure_store_dev: bool = false,
    /// Linking the deep_link service: the domains the app claims for App
    /// Links / Universal Links (empty = unlinked). Requires `pkg` — the
    /// entitlement and assetlinks are keyed to the app's identity — and
    /// grows the packaging tree with the association artifacts
    /// (docs/services.md).
    deep_link_domains: []const []const u8 = &.{},
    /// Linking the oauth service: the custom URL schemes the app's OAuth
    /// redirects use (empty = unlinked, unless `oauth_apple` is set).
    /// Requires `pkg` — the URL-type registration and the intent-filter
    /// are keyed to the app's identity — and grows the packaging tree
    /// with those two client-side registrations (docs/services.md).
    oauth_schemes: []const []const u8 = &.{},
    /// Sign in with Apple: adds the `com.apple.developer.applesignin`
    /// entitlement and routes `.provider = .apple` to the native
    /// controller on macOS and iOS. Links oauth on its own, because
    /// Apple's native leg needs no redirect scheme at all.
    oauth_apple: bool = false,
    /// Linking the iap service. Requires `pkg` — both stores resolve
    /// products against the app's identity — and derives Android's
    /// BILLING permission. On Android the Play Billing Library is one
    /// Gradle coordinate the consumer adds themselves; nokre has no
    /// dependency manager to add it for them (docs/internals/iap.md).
    iap: bool = false,
    /// Linking the notification service. Requires `pkg` — the Android
    /// channel, the Windows AppUserModelID and Apple's entitlement are
    /// all keyed to the app's identity — and derives Android's
    /// POST_NOTIFICATIONS, the one *dangerous* permission any service
    /// asks for (docs/services.md).
    notification: bool = false,
    /// Remote push on top of `notification`: adds Apple's
    /// `aps-environment` entitlement and Android's FCM service
    /// declaration. On Android the Firebase messaging library is one
    /// Gradle coordinate the consumer adds themselves — iap's exception,
    /// stated in the consumer's own build file rather than hidden
    /// (docs/internals/notifications.md). Links notification on its own.
    notification_push: bool = false,
    /// The VAPID application server key web push subscribes with — the
    /// public half, base64url, from the pair the app's own push backend
    /// holds. Only the web reads it (APNs and FCM identify the sender by
    /// the app's registration), and without it `pushAvailable` answers
    /// false there rather than offering a switch that cannot subscribe.
    notification_push_key: []const u8 = "",
    /// The app's Apple icon: an Icon Composer bundle — the `.icon`
    /// *directory* Icon Composer exports, holding `icon.json` and its
    /// layer images. Requires `pkg` (the icon rides the tree the
    /// declaration creates); omitted, the tree carries the mark
    /// derived from the app id, which is what every app gets for
    /// nothing. Declared, the same bundle serves iOS and macOS, and
    /// Xcode 26 or newer compiles it — nokre delivers it untouched and
    /// checks only that it is a bundle whose layer images ship
    /// (docs/services.md).
    apple_icon: ?std.Build.LazyPath = null,
    /// Web only: the name the app's module carries inside the site
    /// (`App.web`), and therefore the name the generated page loads.
    /// The default is a name a page can state without knowing the
    /// artifact's; nothing outside the site refers to it either way.
    web_wasm: []const u8 = "app.wasm",
    /// Web only: the hosts this app's own code talks to — its API, its
    /// OAuth token endpoint, anything the http service fetches. They
    /// join the generated page's `connect-src` and nothing else, so one
    /// declared host grants one power and leaves the rest of the page's
    /// policy where it was. Empty is the default and the common case: a
    /// page still reaches the origin it was served from, which is where
    /// its module, its faces and a same-host API already live.
    ///
    /// Entries are CSP source expressions — `https://api.example.com`,
    /// `*.example.com`, `wss://live.example.com`. A bare `*` is refused,
    /// as is anything carrying whitespace, a quote or a semicolon: a
    /// string that could end its own directive fails the build instead
    /// of reaching a page (the consumer story is
    /// docs/getting-started.md, the policy it joins is
    /// docs/internals/dom-edition.md).
    web_connect_src: []const []const u8 = &.{},
    /// Web only: the `lang` on the generated shell page. The default is
    /// the language nokre's own chrome words are in, which is the
    /// narrowest claim a page with no app behind it can make; a
    /// localized app says its own. The whole argument — including the
    /// one case where any single value here is wrong — is
    /// `packaging.Web.lang`, and the default comes from there rather
    /// than being typed a second time.
    web_lang: []const u8 = (packaging.Web{}).lang,
};

pub const App = struct {
    /// The configured nokre module — import it from test modules too,
    /// so tests exercise the same instance the app links.
    nokre: *std.Build.Module,
    /// The app's root module, already importing "nokre".
    module: *std.Build.Module,
    /// Desktop: the windowed executable, ready to install and run.
    /// iOS/Android/web: the static library the platform project links
    /// (docs/internals/platform-shells.md has each split).
    artifact: *std.Build.Step.Compile,
    /// iOS only: the Skia shim static library the Xcode project links
    /// beside the app library; null elsewhere (desktop links it into
    /// the executable, Android compiles the shim in the NDK world so
    /// all C++ shares one toolchain, and the web's DOM edition links
    /// no Skia at all — docs/internals/dom-edition.md).
    shim: ?*std.Build.Step.Compile = null,
    /// The generated packaging tree (Info.plist, AndroidManifest + res,
    /// web page + manifest + icons) when `pkg` is declared. Install it
    /// wherever the platform project expects it:
    ///
    ///     b.installDirectory(.{ .source_dir = app.pkg.?, .install_dir = .prefix, .install_subdir = "pkg" });
    pkg: ?std.Build.LazyPath = null,
    /// The **site**: everything a browser needs to run this app, in one
    /// directory — the wasm module under the name the page loads, the
    /// live driver's modules and the service worker, the generated
    /// stylesheet, the faces, and the page, manifest and icons the
    /// declaration produces. Non-null exactly when the target is the web; the rest
    /// of the platforms have a shell instead. Install it like `pkg`,
    /// and what lands is servable and uploadable as it stands:
    ///
    ///     if (app.web) |site| b.installDirectory(.{ .source_dir = site, .install_dir = .prefix, .install_subdir = "web" });
    ///
    /// It is a directory rather than a list of files because half a
    /// site is not a smaller site: a missing services.js is a blank
    /// page at run time, not a build error. There is nothing here to
    /// copy and nothing to keep in step — the whole of it is generated
    /// from nokre's own sources on every build (docs/getting-started.md).
    web: ?std.Build.LazyPath = null,
};

/// The one consumer entry point: the windowed-app link wiring as a
/// build step. Dispatches on the target the way nokre's own build
/// does; artifacts are created on nokre's builder (so its source and
/// deps/ paths resolve) and are installable from the consumer's.
///
/// Native rendering needs the Skia + AccessKit prebuilts in the nokre
/// checkout's deps/ — run tools/fetch-deps.sh (and the per-platform
/// tools/build-skia-*.sh) inside the dependency once; a missing dep
/// fails the app's build step with the command to run.
pub fn addApp(nokre_dep: *std.Build.Dependency, options: AppOptions) App {
    return addAppTo(nokre_dep.builder, options);
}

/// The second consumer entry point, and the only other one: the Skia
/// link wiring for a **test** artifact, so `nokre.render.skia.Surface`
/// resolves and golden screenshots can be taken
/// (docs/getting-started.md, docs/testing.md).
///
/// It is a separate call rather than an option on `addApp` because a
/// test binary is a separate *link*. `addApp` wires the app's own
/// executable and hands back its modules; the module a consumer's tests
/// are built from is one they create, and nothing links into a module
/// that does not exist yet. There is deliberately no `skia` bool to
/// forward either: `addApp` already links Skia into every windowed app
/// it builds — a nokre app draws through it — so a flag there would name
/// a choice no app makes, and setting `.skia = true` on the dependency
/// only ever configured nokre's *own* steps.
///
/// `-Dgolden` — whether the golden tests are in the `test` step at all
/// — stays the consumer's own build option, because it is their test
/// suite; everything below the flag is `addGoldenTests`.
///
/// Needs the Skia prebuilt in the nokre checkout's deps/ —
/// tools/fetch-deps.sh, run once inside the dependency — and fails the
/// test artifact's build step with the command to run when it is absent,
/// exactly as `addApp` does.
pub fn linkSkia(nokre_dep: *std.Build.Dependency, tests: *std.Build.Step.Compile) void {
    linkSkiaTo(nokre_dep.builder, tests);
}

/// What `addGoldenTests` builds a consumer's screenshot suite from.
pub const GoldenTestOptions = struct {
    /// The test root — the file holding the golden tests.
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The nokre module the tests import: `App.nokre` off `addApp`, so
    /// the goldens are rendered by the same library instance the app
    /// links. (`Dependency.module("nokre")` is the unconfigured one and
    /// would render through a different set of linked services.)
    nokre: *std.Build.Module,
    /// Everything else the test root imports. `"nokre"` and
    /// `"build_options"` are added by this call and must not appear
    /// here — a duplicate import name is a build error, which is the
    /// honest answer to naming one twice.
    imports: []const std.Build.Module.Import = &.{},
    /// Whether this run may mint a missing baseline or rewrite a
    /// mismatched one. Wire it to a build option that defaults to
    /// false: it reaches `expectGolden`'s `.update` and nothing else,
    /// so a run that does not pass it cannot heal a golden.
    update_goldens: bool = false,
    /// What golden paths in the test root are relative to. Defaults to
    /// the package root (`b.path(".")` on the *consumer's* builder is
    /// what you want here) because that is where committed PPMs live;
    /// without it the run's cwd is the cache directory.
    cwd: std.Build.LazyPath,
};

/// The pieces, so the consumer wires the steps: a `golden` step, the
/// `test` step under their own `-Dgolden`, or both.
pub const GoldenTests = struct {
    module: *std.Build.Module,
    artifact: *std.Build.Step.Compile,
    /// Already `setCwd`-ed to `GoldenTestOptions.cwd`.
    run: *std.Build.Step.Run,
};

/// The third consumer entry point: a golden screenshot suite, wired.
///
/// It exists because two of the four lines it replaces are a *contract*
/// with nokre rather than a consumer's own arrangement — the options
/// module must be imported under the name `"build_options"`, which is
/// what `tests/golden.zig`-shaped roots read `update_goldens` from, and
/// the run must have its cwd set to the package root or every golden
/// path resolves into the cache. Both real consumers had hand-copied
/// the same twenty lines, and a hand copy that drifts on either fails
/// somewhere far from the mistake: a wrong import name is a missing-decl
/// error inside the test root, and a missing `setCwd` mints a fresh
/// baseline tree in a directory nobody looks at.
///
/// ```zig
/// const golden = nokre.addGoldenTests(nokre_dep, .{
///     .root_source_file = b.path("src/golden_test.zig"),
///     .target = target,
///     .optimize = optimize,
///     .nokre = app.nokre,
///     .imports = &.{.{ .name = "shared", .module = shared }},
///     .update_goldens = b.option(bool, "update-goldens", "…") orelse false,
///     .cwd = b.path("."),
/// });
/// b.step("golden", "Run the golden screenshot tests").dependOn(&golden.run.step);
/// ```
pub fn addGoldenTests(nokre_dep: *std.Build.Dependency, options: GoldenTestOptions) GoldenTests {
    return addGoldenTestsTo(nokre_dep.builder, options);
}

fn addGoldenTestsTo(hb: *std.Build, options: GoldenTestOptions) GoldenTests {
    const gpa = hb.allocator;
    var imports = std.ArrayList(std.Build.Module.Import).initCapacity(gpa, options.imports.len + 2) catch @panic("OOM");
    imports.appendAssumeCapacity(.{ .name = "nokre", .module = options.nokre });
    // The name is the contract, which is the whole reason this call
    // exists: a golden root reads `@import("build_options").update_goldens`.
    const opts = hb.addOptions();
    opts.addOption(bool, "update_goldens", options.update_goldens);
    imports.appendAssumeCapacity(.{ .name = "build_options", .module = opts.createModule() });
    imports.appendSlice(gpa, options.imports) catch @panic("OOM");

    const module = hb.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .imports = imports.items,
    });
    const artifact = hb.addTest(.{ .root_module = module });
    // Goldens render through the production renderer, so the *test*
    // binary needs the link `addApp` never makes.
    linkSkiaTo(hb, artifact);
    const run = hb.addRunArtifact(artifact);
    run.setCwd(options.cwd);
    return .{ .module = module, .artifact = artifact, .run = run };
}

/// The web target: bare wasm32. There is no C++ archive to match
/// features with any more — the web's edition is the DOM one, which
/// links no Skia and no emscripten — so this is the plain query, and
/// it stays a function so a consumer's build file names nokre's answer
/// rather than restating it.
pub fn webTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
}

pub const ServeOptions = struct {
    /// The loopback port the site is served on.
    port: u16 = 8000,
};

/// Serve an app's site (`App.web`) over http on this machine, as a
/// build step:
///
///     const serve = nokre.addWebServe(nokre_dep, app, .{});
///     b.step("serve", "Serve the web build at http://localhost:8000").dependOn(&serve.step);
///
/// It exists because a built site cannot be opened: neither a wasm
/// module nor an ES module loads from a `file://` URL, so the last step
/// of "see it in a browser" is a server, and every nokre project would
/// otherwise pick a different one. nokre's own `zig build serve` runs
/// this same binary over this same directory
/// (src/render/dom/serve.zig), so a consumer's browser and nokre's are
/// looking at the site through the same window.
///
/// The step is returned rather than named here, because a step name
/// belongs to the build file that owns it — but name it unconditionally
/// on either side of `-Dweb`: an app built for a native target hands
/// back a step that says so when it runs, which is a better answer than
/// a `serve` that exists only under a flag.
pub fn addWebServe(nokre_dep: *std.Build.Dependency, app: App, options: ServeOptions) *std.Build.Step.Run {
    return addWebServeTo(nokre_dep.builder, app.web, options);
}

fn addAppTo(hb: *std.Build, options: AppOptions) App {
    const result = options.target.result;
    if (result.cpu.arch == .wasm32) return addWebApp(hb, options);
    if (result.os.tag == .ios) return addIosApp(hb, options);
    if (result.abi.isAndroid()) return addAndroidApp(hb, options);
    return addDesktopApp(hb, options);
}

/// The generated packaging tree for a declared app, or null when no
/// identity is declared — an app without an id has nothing to put in a
/// manifest, and that absence should be loud at the consumer's install
/// site, not papered over with placeholder identity.
fn appPkgTree(hb: *std.Build, options: AppOptions) ?std.Build.LazyPath {
    const decl = options.pkg orelse return null;
    const wf = hb.addWriteFiles();
    addPkgTree(hb, wf, decl, appServices(options), appWeb(options), options.apple_icon);
    return wf.getDirectory();
}

/// The web half of the declaration, as packaging reads it: the module's
/// name in the site, the hosts the app is allowed to reach from it, and
/// the language its shell page claims.
fn appWeb(options: AppOptions) packaging.Web {
    return .{
        .module_wasm = options.web_wasm,
        .connect_src = options.web_connect_src,
        .lang = options.web_lang,
    };
}

/// Everything an `addApp` call can declare that needs the app's
/// identity, checked as one group: the five services below plus the
/// Apple icon. Why each one needs it is on its own `AppOptions` field
/// and in docs/services.md; what this layer decides is where the
/// refusal lands — on the artifact the consumer will actually build,
/// because hb.default_step belongs to the dependency and a consumer
/// never depends on it. So an artifact either carries a declaration
/// all six can read, or it fails naming the one that wanted it.
fn checkServicesNeedPkg(hb: *std.Build, options: AppOptions, artifact: *std.Build.Step.Compile) void {
    checkStoreNeedsPkg(hb, options, artifact);
    checkDeepLinkNeedsPkg(hb, options, artifact);
    checkOauthNeedsPkg(hb, options, artifact);
    checkIapNeedsPkg(hb, options, artifact);
    checkNotificationNeedsPkg(hb, options, artifact);
    checkAppleIconNeedsPkg(hb, options, artifact);
}

fn checkNotificationNeedsPkg(hb: *std.Build, options: AppOptions, artifact: *std.Build.Step.Compile) void {
    if ((options.notification or options.notification_push) and options.pkg == null) {
        const fail = hb.addFail("notification needs the app's identity — its Android channel, Windows AppUserModelID and Apple entitlement are keyed to the app id, so declare .pkg alongside .notification (docs/services.md)");
        artifact.step.dependOn(&fail.step);
    }
}

fn checkStoreNeedsPkg(hb: *std.Build, options: AppOptions, artifact: *std.Build.Step.Compile) void {
    if (options.secure_store and options.pkg == null) {
        const fail = hb.addFail("secure_store needs the app's identity for its namespace — declare .pkg alongside .secure_store (docs/services.md)");
        artifact.step.dependOn(&fail.step);
    }
}

fn checkDeepLinkNeedsPkg(hb: *std.Build, options: AppOptions, artifact: *std.Build.Step.Compile) void {
    if (options.deep_link_domains.len != 0 and options.pkg == null) {
        const fail = hb.addFail("deep_link needs the app's identity — its entitlement and assetlinks are keyed to the app id, so declare .pkg alongside .deep_link_domains (docs/services.md)");
        artifact.step.dependOn(&fail.step);
    }
}

fn checkOauthNeedsPkg(hb: *std.Build, options: AppOptions, artifact: *std.Build.Step.Compile) void {
    if ((options.oauth_schemes.len != 0 or options.oauth_apple) and options.pkg == null) {
        const fail = hb.addFail("oauth needs the app's identity — its URL-type registration and intent-filter are keyed to the app id, so declare .pkg alongside .oauth_schemes (docs/services.md)");
        artifact.step.dependOn(&fail.step);
    }
}

fn checkIapNeedsPkg(hb: *std.Build, options: AppOptions, artifact: *std.Build.Step.Compile) void {
    if (options.iap and options.pkg == null) {
        const fail = hb.addFail("iap needs the app's identity — both stores resolve products against the app id, so declare .pkg alongside .iap (docs/services.md)");
        artifact.step.dependOn(&fail.step);
    }
}

/// The one member of this group that is not a service. The `.pkg`
/// requirement is all that is checked here; the icon's own shape is
/// checked where the tree is written (`addAppleIcon`).
fn checkAppleIconNeedsPkg(hb: *std.Build, options: AppOptions, artifact: *std.Build.Step.Compile) void {
    if (options.apple_icon != null and options.pkg == null) {
        const fail = hb.addFail("apple_icon has no packaging tree to ride — the icon is delivered beside the manifests, so declare .pkg alongside .apple_icon (docs/services.md)");
        artifact.step.dependOn(&fail.step);
    }
}

fn depMissing(hb: *std.Build, artifact: *std.Build.Step.Compile, comptime probe: []const u8, comptime message: []const u8) bool {
    hb.build_root.handle.access(hb.graph.io, probe, .{}) catch {
        const fail = hb.addFail(message ++ " (in the nokre checkout: " ++ probe ++ ")");
        artifact.step.dependOn(&fail.step);
        return true;
    };
    return false;
}

/// macOS and Windows: the windowed executable — app + nokre + shell +
/// Skia shim + AccessKit in one link.
fn addDesktopApp(hb: *std.Build, options: AppOptions) App {
    const target = options.target;
    const os_tag = target.result.os.tag;
    const is_msvc = target.result.abi == .msvc;
    // MSVC ABI: the AccessKit Rust static library supplies compiler
    // intrinsics in place of zig's compiler-rt, and that set lacks the
    // x87 f128 conversions Debug-mode UBSan's runtime wants — trap mode
    // keeps C undefined behavior fatal without the runtime.
    const sanitize_c: ?std.zig.SanitizeC = if (is_msvc) .trap else null;

    const nokre_mod = hb.createModule(.{
        .root_source_file = hb.path("src/nokre.zig"),
        .target = target,
        .optimize = options.optimize,
        .link_libc = true,
        .sanitize_c = sanitize_c,
    });
    configureNokre(hb, nokre_mod, options.pkg, appServices(options), options.secure_store_dev);

    const app_mod = hb.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
        .sanitize_c = sanitize_c,
        .imports = &.{.{ .name = "nokre", .module = nokre_mod }},
    });
    const exe = hb.addExecutable(.{ .name = options.name, .root_module = app_mod });
    checkServicesNeedPkg(hb, options, exe);
    const app: App = .{ .nokre = nokre_mod, .module = app_mod, .artifact = exe, .pkg = appPkgTree(hb, options) };

    if (os_tag == .windows and !is_msvc) {
        const fail = hb.addFail("Windows builds link the MSVC-ABI Skia prebuilt — build with -Dtarget=x86_64-windows-msvc");
        exe.step.dependOn(&fail.step);
        return app;
    }
    const accesskit_lib = switch (os_tag) {
        .macos, .linux => "deps/accesskit/lib/libaccesskit.a",
        .windows => "deps/accesskit/lib/accesskit.lib",
        // No shell, no AccessKit prebuilt, and no Skia prebuilt exist
        // for any other desktop OS, so the app's build step fails
        // naming the supported set. This used to be `unreachable`,
        // which panicked the whole build script at graph construction
        // for e.g. -Dtarget=x86_64-freebsd — before the dep checks
        // below, so it must run first or a missing deps/skia would
        // misdiagnose an unsupported OS as an unfetched dependency.
        else => {
            const fail = hb.addFail(hb.fmt("no desktop shell for {s} — nokre's desktop targets are macOS, Windows (x86_64-windows-msvc), and Linux (Wayland); iOS, Android, and wasm32 take their own paths (docs/getting-started.md)", .{@tagName(os_tag)}));
            exe.step.dependOn(&fail.step);
            return app;
        },
    };
    if (depMissing(hb, exe, skia_probe, "deps/skia not found — run tools/fetch-deps.sh first")) return app;
    if (depMissing(hb, exe, "deps/accesskit/include/accesskit.h", "deps/accesskit not found — run tools/fetch-deps.sh first")) return app;

    app_mod.linkLibrary(desktopSkiaShim(hb, target, is_msvc));
    linkSkiaPrebuilt(hb, app_mod, os_tag);

    const ak_mod = hb.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const ak = hb.addLibrary(.{
        .name = "nokre_accesskit",
        .linkage = .static,
        .root_module = ak_mod,
    });
    ak_mod.addCSourceFile(.{
        .file = hb.path("shim/nokre_accesskit.c"),
        .flags = &.{"-std=c11"},
    });
    ak_mod.addIncludePath(hb.path("deps/accesskit/include"));

    switch (os_tag) {
        .macos => {
            app_mod.addCSourceFile(.{
                .file = hb.path("src/platform/macos/shell.m"),
                .flags = &.{"-fobjc-arc"},
            });
            app_mod.linkFramework("AppKit", .{});
            app_mod.linkFramework("QuartzCore", .{});
            app_mod.linkLibrary(ak);
            app_mod.addObjectFile(hb.path(accesskit_lib));
        },
        .windows => {
            app_mod.addCSourceFile(.{
                .file = hb.path("src/platform/windows/shell.c"),
                .flags = &.{"-std=c11"},
            });
            // user32/gdi32/imm32/advapi32/dwmapi/shell32 are the shell's
            // (shell32 is ShellExecuteW — the URL launcher, which used to
            // ride oauth's link and is the shell's own dependency now);
            // the rest back the AccessKit Rust static library (UIA plus
            // the Rust std runtime).
            for ([_][]const u8{ "user32", "gdi32", "imm32", "advapi32", "dwmapi", "shell32", "uiautomationcore", "oleaut32", "ole32", "ws2_32", "userenv", "bcrypt", "ntdll" }) |lib|
                app_mod.linkSystemLibrary(lib, .{});
            app_mod.linkLibrary(ak);
            app_mod.addObjectFile(hb.path(accesskit_lib));
            // GUI subsystem (no console window behind the app's own), but
            // keep the console CRT entry so zig's plain main runs — the
            // WinMain the GUI entry would demand adds nothing here.
            exe.subsystem = .Windows;
            exe.entry = .{ .symbol_name = "mainCRTStartup" };
            // accesskit.lib (Rust) bundles compiler_builtins — the same
            // intrinsics as zig's compiler-rt, and lld-link rejects the
            // duplicates; let the Rust copy serve both.
            exe.bundle_compiler_rt = false;
        },
        .linux => {
            // The Wayland shell: wayland-scanner turns the system protocol
            // XML into client glue, compiled with shell.c; xkbcommon does
            // keyboard, dbus-1 backs appearance detection (the portal
            // Settings read). The AccessKit Unix adapter (Rust, AT-SPI over
            // its own zbus socket) needs the Rust std runtime's libc deps.
            addWaylandShell(hb, app_mod);
            app_mod.linkLibrary(ak);
            app_mod.addObjectFile(hb.path(accesskit_lib));
            for ([_][]const u8{ "wayland-client", "xkbcommon", "dbus-1", "m", "dl" }) |lib|
                app_mod.linkSystemLibrary(lib, .{});
        },
        // Truly unreachable: every other desktop OS already
        // failed-and-returned at the accesskit_lib switch above.
        else => unreachable,
    }
    return app;
}

/// The Wayland shell's native side: generate xdg-shell and text-input-v3
/// client glue from the system protocol XML with wayland-scanner (present
/// on any Wayland dev host, like Windows needs the VS Build Tools), then
/// compile that glue and shell.c. Committing generated code is the
/// anti-pattern the qrcodegen/harfbuzz vendoring avoids; the toolchain
/// regenerates it into a private dir the shell includes.
fn addWaylandShell(hb: *std.Build, app_mod: *std.Build.Module) void {
    // Where the protocol XML lives is the wayland-protocols package's
    // own answer (its .pc exports pkgdatadir), and it varies by distro —
    // prefix installs and NixOS put it nowhere near /usr/share. The
    // hardcoded FHS path stays as the fallback for hosts where
    // pkg-config or the .pc file is missing: it is still correct on the
    // mainstream distros, and a wrong dir surfaces immediately as
    // wayland-scanner failing on a nonexistent XML path.
    const protocols_dir: []const u8 = blk: {
        var code: u8 = undefined;
        const out = hb.runAllowFail(
            &.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" },
            &code,
            .ignore,
        ) catch break :blk "/usr/share/wayland-protocols";
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        break :blk if (trimmed.len == 0) "/usr/share/wayland-protocols" else trimmed;
    };
    const Proto = struct { xml: []const u8, base: []const u8 };
    const protocols = [_]Proto{
        .{ .xml = hb.pathJoin(&.{ protocols_dir, "stable/xdg-shell/xdg-shell.xml" }), .base = "xdg-shell" },
        .{ .xml = hb.pathJoin(&.{ protocols_dir, "unstable/text-input/text-input-unstable-v3.xml" }), .base = "text-input-unstable-v3" },
    };
    // One write-files dir co-locates every generated header so shell.c's
    // #include "<base>-client-protocol.h" resolves from a single -I.
    const gen = hb.addWriteFiles();
    for (protocols) |proto| {
        const header_cmd = hb.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header_cmd.addArg(proto.xml);
        const header = header_cmd.addOutputFileArg(hb.fmt("{s}-client-protocol.h", .{proto.base}));
        _ = gen.addCopyFile(header, hb.fmt("{s}-client-protocol.h", .{proto.base}));

        const code_cmd = hb.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code_cmd.addArg(proto.xml);
        const code = code_cmd.addOutputFileArg(hb.fmt("{s}-protocol.c", .{proto.base}));
        // The generated code is self-contained (only wayland-util); compile
        // it straight from its cache path.
        app_mod.addCSourceFile(.{ .file = code, .flags = &.{"-std=c11"} });
    }
    app_mod.addIncludePath(gen.getDirectory());
    app_mod.addCSourceFile(.{
        .file = hb.path("src/platform/linux/shell.c"),
        // NOKRE_HAVE_DBUS turns on the xdg-desktop-portal appearance read;
        // dbus-1 is linked in the caller.
        .flags = &.{ "-std=c11", "-DNOKRE_HAVE_DBUS" },
    });
}

/// iOS produces static libraries, not a runnable artifact: zig owns the
/// Zig code and the C/C++ it already compiles elsewhere (qrcodegen, the
/// Skia shim); the consumer's Xcode project compiles the UIKit shell,
/// links Skia, and signs for the simulator or a device
/// (examples/kitchen_sink/ios is the template). Cross-compiled C needs
/// the SDK's libc headers; `-isystem` keeps them behind zig's bundled
/// libc++ headers.
fn addIosApp(hb: *std.Build, options: AppOptions) App {
    const target = options.target;

    const nokre_mod = hb.createModule(.{
        .root_source_file = hb.path("src/nokre.zig"),
        .target = target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    configureNokre(hb, nokre_mod, options.pkg, appServices(options), options.secure_store_dev);

    const app_mod = hb.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "nokre", .module = nokre_mod }},
    });
    const lib = hb.addLibrary(.{
        .name = options.name,
        .linkage = .static,
        .root_module = app_mod,
    });
    checkServicesNeedPkg(hb, options, lib);
    var app: App = .{ .nokre = nokre_mod, .module = app_mod, .artifact = lib, .pkg = appPkgTree(hb, options) };

    if (builtin.os.tag != .macos) {
        const fail = hb.addFail("iOS builds need a macOS host (xcrun locates the SDK)");
        lib.step.dependOn(&fail.step);
        return app;
    }
    if (depMissing(hb, lib, skia_probe, "deps/skia not found — run tools/fetch-deps.sh and tools/build-skia-ios.sh first")) return app;

    const sdk_name = if (target.result.abi == .simulator) "iphonesimulator" else "iphoneos";
    const sdk_path = appleSdkPath(hb, sdk_name);
    const sdk_include: std.Build.LazyPath = .{ .cwd_relative = hb.pathJoin(&.{ sdk_path, "usr", "include" }) };
    const sdk_frameworks: std.Build.LazyPath = .{ .cwd_relative = hb.pathJoin(&.{ sdk_path, "System", "Library", "Frameworks" }) };
    nokre_mod.addSystemIncludePath(sdk_include);
    // The framework path serves the services that link one (a
    // secure_store app records -framework Security even in a static
    // archive); the frameworks themselves resolve at the Xcode link.
    nokre_mod.addSystemFrameworkPath(sdk_frameworks);

    const shim_mod = hb.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libcpp = true,
    });
    const shim = hb.addLibrary(.{
        .name = "nokre_skia",
        .linkage = .static,
        .root_module = shim_mod,
    });
    shim_mod.addCSourceFiles(.{
        .files = &.{ "shim/nokre_skia.cpp", "shim/nokre_skia_nocodec_stub.cpp", "shim/nokre_skia_ios_stub.cpp" },
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" },
    });
    shim_mod.addIncludePath(hb.path(skia_root));
    addHarfBuzz(hb, shim_mod);
    shim_mod.addSystemIncludePath(sdk_include);
    shim_mod.addSystemFrameworkPath(sdk_frameworks);
    app.shim = shim;
    return app;
}

/// Android produces one static library of all the Zig, and nothing
/// else: the consumer's Gradle project compiles the JNI shell, the Skia
/// shim, and qrcodegen with the NDK toolchain (one C/C++ toolchain with
/// the NDK-built Skia) and links the .so
/// (examples/kitchen_sink/android is the template). No C rides along —
/// qrcodegen and the shim need bionic headers zig does not bundle.
/// link_libc marks bionic as the libc so std.heap.c_allocator resolves
/// to the malloc Skia already uses; with no C compiled and no link step
/// here, no NDK is needed.
fn addAndroidApp(hb: *std.Build, options: AppOptions) App {
    const target = options.target;
    // pic: the archive's destination is a shared library (the APK's
    // .so), and without it zig emits local-exec TLS relocations lld
    // rightly refuses under -shared.
    const nokre_mod = hb.createModule(.{
        .root_source_file = hb.path("src/nokre.zig"),
        .target = target,
        .optimize = options.optimize,
        .link_libc = true,
        .pic = true,
    });
    configureServices(hb, nokre_mod, options.pkg, appServices(options), options.secure_store_dev);

    const app_mod = hb.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "nokre", .module = nokre_mod }},
        .pic = true,
    });
    const lib = hb.addLibrary(.{
        .name = options.name,
        .linkage = .static,
        .root_module = app_mod,
    });
    checkServicesNeedPkg(hb, options, lib);
    return .{ .nokre = nokre_mod, .module = app_mod, .artifact = lib, .pkg = appPkgTree(hb, options) };
}

/// A web app: one wasm module, entry disabled, exports rdynamic. The
/// browser is already mid-event-loop when it instantiates, so there is
/// no `main` to run — the app arrives through `nokreWebBuild` and the
/// DOM edition's live driver drives it
/// (docs/internals/dom-edition.md).
fn addWebApp(hb: *std.Build, options: AppOptions) App {
    const nokre_mod = hb.createModule(.{
        .root_source_file = hb.path("src/nokre.zig"),
        .target = options.target,
        // Layout and the markup walk run on every frame; Debug wasm is
        // slow enough to read as jank, and Small is what a page pays
        // for in download.
        .optimize = .ReleaseSmall,
    });
    configureNokre(hb, nokre_mod, options.pkg, appServices(options), options.secure_store_dev);

    const app_mod = hb.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = .ReleaseSmall,
        // The name section is most of an unstripped wasm and nothing
        // reads it here.
        .strip = true,
        .imports = &.{.{ .name = "nokre", .module = nokre_mod }},
    });
    const exe = hb.addExecutable(.{ .name = options.name, .root_module = app_mod });
    exe.entry = .disabled;
    exe.rdynamic = true;
    checkServicesNeedPkg(hb, options, exe);
    // One tree, read twice: the manifests a consumer installs as `pkg`,
    // and — the `web/` corner of it — the page, manifest and icons the
    // site is assembled around.
    const pkg = appPkgTree(hb, options);
    return .{
        .nokre = nokre_mod,
        .module = app_mod,
        .artifact = exe,
        .pkg = pkg,
        .web = addWebSite(hb, exe.getEmittedBin(), options.web_wasm, pkg),
    };
}

/// The site: the app's own module plus the half that makes it run, in
/// one directory (`App.web`). Both halves are outputs — the stylesheet
/// is generated out of color.zig/text.zig/layout.zig on every build, the
/// glue and the faces are copied from nokre's own sources by the build
/// graph, and the page comes from the declaration — so nothing in a
/// site can be older than the nokre it was built against.
///
/// The set of files lives here and only here, and nokre's own web step
/// assembles through this same function: a fourth module added to
/// src/render/dom is one edit, not one per consumer. That is the whole
/// reason this is a function rather than a paragraph in a doc — a
/// paragraph is what a consumer was left with, and a site missing one
/// of these files is a blank page rather than a build error.
///
/// The site also states that set as data: `site.manifest`, one
/// relative path per line, sorted. It exists for whatever deploys the
/// site — a consumer's tooling verifying a copy landed whole reads the
/// list instead of re-typing this function's contents and drifting
/// (tests/web_services.mjs holds the two identical). The manifest
/// names the servable content, not itself.
fn addWebSite(
    hb: *std.Build,
    wasm: std.Build.LazyPath,
    web_wasm: []const u8,
    pkg_tree: ?std.Build.LazyPath,
) std.Build.LazyPath {
    const gpa = hb.allocator;
    const wf = hb.addWriteFiles();
    var files: std.ArrayList([]const u8) = .empty;
    _ = wf.addCopyFile(wasm, web_wasm);
    files.append(gpa, web_wasm) catch @panic("OOM");
    // The live driver's browser half (docs/internals/dom-edition.md),
    // the set `dom.driver_files` states as data: the page loads live.js
    // alone, which imports the others. sw.js rides the same copy: the
    // notification service's web half is a *file the origin serves*,
    // not a module import — a service worker has to be registerable by
    // URL — so the site carries it whether or not this app links
    // notifications. An unregistered worker costs a 404 the driver
    // already swallows; a missing one would make the leg
    // unimplementable after the fact (docs/internals/notifications.md).
    inline for (dom_driver_files) |f| {
        _ = wf.addCopyFile(hb.path("src/render/dom/" ++ f), f);
        files.append(gpa, f) catch @panic("OOM");
    }
    _ = wf.addCopyFile(emitStylesheet(hb), "style.css");
    files.append(gpa, "style.css") catch @panic("OOM");
    // The bundled faces, and nothing else in that directory: the
    // licenses beside them are a fact about this repository, not a file
    // anyone's site should answer a request for. The manifest's font
    // lines come from the same directory the copy reads, so neither can
    // drift from the other.
    _ = wf.addCopyDirectory(hb.path("src/assets/fonts"), "fonts", .{ .include_extensions = &.{".ttf"} });
    appendFontNames(hb, &files);
    if (pkg_tree) |tree| {
        // The declaration's own web corner — index.html, the
        // manifest, the icons — lands at the site root, where the page
        // expects the module and the stylesheet beside it.
        _ = wf.addCopyDirectory(tree.path(hb, "web"), "", .{});
        // The corner's contents, as addPkgTree writes them: the page in
        // its three CSP-mandated pieces and the webmanifest, out of
        // packaging's own list, and the web icons out of its table.
        for (packaging.web_page_files) |f| {
            files.append(gpa, f) catch @panic("OOM");
        }
        for (packaging.icon_files) |f| {
            if (std.mem.startsWith(u8, f.path, "web/"))
                files.append(gpa, f.path["web/".len..]) catch @panic("OOM");
        }
    } else {
        // The invalid-declaration rule (addPkgTree): the fix rides the
        // tree's step, so a build that never installs the site
        // proceeds and one that does fails saying what to declare.
        wf.step.dependOn(&hb.addFail("a web app needs the app's identity — its page title, its manifest and its icons are outputs of the declaration, so declare .pkg alongside a web target (docs/getting-started.md)").step);
    }
    std.mem.sort([]const u8, files.items, {}, stringLessThan);
    var manifest: std.ArrayList(u8) = .empty;
    for (files.items) |f| {
        manifest.appendSlice(gpa, f) catch @panic("OOM");
        manifest.append(gpa, '\n') catch @panic("OOM");
    }
    _ = wf.add("site.manifest", manifest.items);
    return wf.getDirectory();
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The `fonts/*.ttf` lines of `site.manifest`, read from the directory
/// `addWebSite` copies: the faces on disk are the fact, and both the
/// copy and the list derive from it.
fn appendFontNames(hb: *std.Build, files: *std.ArrayList([]const u8)) void {
    const io = hb.graph.io;
    var dir = hb.build_root.handle.openDir(io, "src/assets/fonts", .{ .iterate = true }) catch
        @panic("src/assets/fonts is unreadable");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("src/assets/fonts is unreadable")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ttf")) continue;
        files.append(hb.allocator, hb.fmt("fonts/{s}", .{entry.name})) catch @panic("OOM");
    }
}

/// The DOM edition's stylesheet, generated by the library itself on the
/// host: thirteen grays, six type scales and every metric read out of
/// core rather than transcribed (docs/internals/dom-edition.md). A
/// palette byte that changes is in the next site; a copy would not be.
fn emitStylesheet(hb: *std.Build) std.Build.LazyPath {
    const host_nokre = hb.createModule(.{
        .root_source_file = hb.path("src/nokre.zig"),
        .target = hb.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    configureNokre(hb, host_nokre, null, .{}, false);
    const tool = hb.addExecutable(.{
        .name = "emit-css",
        .root_module = hb.createModule(.{
            .root_source_file = hb.path("src/render/dom/emit_css.zig"),
            .target = hb.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "nokre", .module = host_nokre }},
        }),
    });
    const run = hb.addRunArtifact(tool);
    const css = run.addOutputFileArg("style.css");
    // Where the faces are, as the page will ask for them.
    run.addArgs(&.{ "./fonts", ".ttf" });
    return css;
}

/// `addWebServe`'s inside, shared with nokre's own `serve` step. A site
/// that does not exist — the app was built for a native target — is not
/// a missing step but a step that says so, `blockedRunSteps`' rule:
/// naming it only under `-Dweb` turns a forgotten flag into "no step
/// named 'serve'".
fn addWebServeTo(hb: *std.Build, site: ?std.Build.LazyPath, options: ServeOptions) *std.Build.Step.Run {
    const tool = hb.addExecutable(.{
        .name = "nokre-serve",
        .root_module = hb.createModule(.{
            .root_source_file = hb.path("src/render/dom/serve.zig"),
            .target = hb.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = hb.addRunArtifact(tool);
    if (site) |dir| {
        run.addDirectoryArg(dir);
        run.addArg(hb.fmt("{d}", .{options.port}));
    } else {
        run.step.dependOn(&hb.addFail("there is no site to serve — this app was built for a native target; pass nokre.webTarget(b) as .target to build it for the browser (docs/getting-started.md)").step);
    }
    return run;
}

const skia_root = "deps/skia";
const skia_probe = skia_root ++ "/include/core/SkCanvas.h";
const harfbuzz_root = "deps/harfbuzz";

/// HarfBuzz rides in the shim, never in Skia: one amalgamated
/// translation unit compiled alongside nokre_skia.cpp wherever that
/// file is compiled, so the pinned Skia builds (prebuilt and
/// source-built alike) stay untouched. HB_NO_MT because the shim is the
/// only caller and its shared hb objects are immutable after load.
fn addHarfBuzz(hb: *std.Build, shim_mod: *std.Build.Module) void {
    shim_mod.addCSourceFile(.{
        .file = hb.path(harfbuzz_root ++ "/src/harfbuzz.cc"),
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-DHB_NO_MT" },
    });
    shim_mod.addIncludePath(hb.path(harfbuzz_root ++ "/src"));
}

/// The Skia shim for desktop targets (requires deps/skia from
/// tools/fetch-deps.sh). MSVC ABI (the Windows prebuilt): C++ headers
/// and runtime come from the Visual Studio installation via link_libc,
/// not zig's libc++.
fn desktopSkiaShim(hb: *std.Build, target: std.Build.ResolvedTarget, is_msvc: bool) *std.Build.Step.Compile {
    const shim_mod = hb.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libcpp = !is_msvc,
        .link_libc = is_msvc,
    });
    const shim = hb.addLibrary(.{
        .name = "nokre_skia",
        .linkage = .static,
        .root_module = shim_mod,
    });
    shim_mod.addCSourceFile(.{
        .file = hb.path("shim/nokre_skia.cpp"),
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" },
    });
    if (target.result.os.tag == .windows) {
        // Plain-named zlib entry points FreeType's gzip path references
        // but the prebuilt leaves to the consumer; rationale in the file.
        shim_mod.addCSourceFile(.{
            .file = hb.path("shim/nokre_skia_zlib_stub.c"),
            .flags = &.{"-std=c11"},
        });
    }
    shim_mod.addIncludePath(hb.path(skia_root));
    addHarfBuzz(hb, shim_mod);
    return shim;
}

/// The shim plus the prebuilt, onto one artifact's root module — the
/// pair `addDesktopApp` spends on an executable, spent on a test binary
/// instead. Public as `linkSkia`; nokre's own golden tests take the same
/// road, so the consumer path is exercised by every `-Dgolden` run here.
///
/// The two ways it can't work are refused on the artifact the consumer
/// will actually build, `addApp`'s rule: an unfetched prebuilt, and the
/// Windows ABI mismatch (the prebuilt is MSVC clang-cl, so a test binary
/// linking it must be too).
fn linkSkiaTo(hb: *std.Build, artifact: *std.Build.Step.Compile) void {
    const mod = artifact.root_module;
    const target = mod.resolved_target orelse {
        const fail = hb.addFail("nokre.linkSkia needs a test module with a resolved target — pass .target to createModule (docs/getting-started.md)");
        artifact.step.dependOn(&fail.step);
        return;
    };
    const os_tag = target.result.os.tag;
    const is_msvc = target.result.abi == .msvc;
    if (os_tag == .windows and !is_msvc) {
        const fail = hb.addFail("goldens on Windows link the MSVC-ABI Skia prebuilt — build with -Dtarget=x86_64-windows-msvc");
        artifact.step.dependOn(&fail.step);
        return;
    }
    if (depMissing(hb, artifact, skia_probe, "deps/skia not found — run tools/fetch-deps.sh first")) return;
    mod.linkLibrary(desktopSkiaShim(hb, target, is_msvc));
    linkSkiaPrebuilt(hb, mod, os_tag);
}

fn linkSkiaPrebuilt(hb: *std.Build, mod: *std.Build.Module, os: std.Target.Os.Tag) void {
    switch (os) {
        .windows => {
            // Unlike its filename suggests, skia.lib is the same
            // everything-bundled archive as macOS's libskia.a
            // (FreeType, zlib, libpng, skcms objects included); the
            // sibling .libs the zip ships are for modules nokre
            // doesn't use.
            mod.addObjectFile(hb.path(skia_root ++ "/lib/skia.lib"));
            // The prebuilt compiles with -MT: Visual Studio's static
            // C++ runtime, not zig's libc++.
            mod.linkSystemLibrary("libcpmt", .{});
            mod.link_libc = true;
        },
        else => {
            mod.addObjectFile(hb.path(skia_root ++ "/lib/libskia.a"));
            mod.linkSystemLibrary("z", .{});
            if (os == .macos) {
                mod.linkFramework("CoreFoundation", .{});
                mod.linkFramework("CoreGraphics", .{});
                mod.linkFramework("CoreText", .{});
                mod.linkFramework("CoreServices", .{});
            }
            mod.link_libcpp = true;
        },
    }
}

pub fn build(b: *std.Build) void {
    const enable_skia = b.option(bool, "skia", "Link the Skia shim for real rendering (run tools/fetch-deps.sh first)") orelse false;
    const enable_golden = b.option(bool, "golden", "Run golden screenshot tests (requires -Dskia)") orelse false;
    const update_goldens = b.option(bool, "update-goldens", "Create missing goldens and rewrite mismatched ones in place (requires -Dgolden)") orelse false;
    const port = b.option(u16, "port", "The port `zig build serve` serves the web build on") orelse 8000;
    const js_parse = b.option(bool, "js-parse", "Parse the shipped JavaScript with node during `zig build test`, and run the web services check through it (default true; false ships it unparsed and unrun)") orelse true;

    // The Windows Skia prebuilt is MSVC-ABI (clang-cl), so -Dskia builds
    // must be too; defaulting the ABI here keeps `zig build run-… -Dskia`
    // working without a -Dtarget, while pure builds keep the native
    // default and stay free of any MSVC installation.
    const default_target: std.Target.Query =
        if (builtin.os.tag == .windows and enable_skia) .{ .abi = .msvc } else .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const is_msvc = target.result.abi == .msvc;
    const sanitize_c: ?std.zig.SanitizeC = if (is_msvc) .trap else null;

    // App identity for the package_info service (docs/services.md):
    // declared once here by the consumer, baked into every platform at
    // comptime. Setting pkg_id is what links the service.
    const pkg_id = b.option([]const u8, "pkg_id", "Link the package_info service: reverse-DNS app id");
    const pkg_name = b.option([]const u8, "pkg_name", "package_info: human-readable app name (defaults to pkg_id)");
    const pkg_version = b.option([]const u8, "pkg_version", "package_info: display version (defaults to 0.0.0)");
    const pkg_build = b.option(u32, "pkg_build", "package_info: monotonic build number (defaults to 0)");
    const pkg_decl: ?PackageDecl = if (pkg_id) |id| .{
        .id = id,
        .name = pkg_name orelse id,
        .version = pkg_version orelse "0.0.0",
        .build = pkg_build orelse 0,
    } else null;

    // Deliberately not http's "always available" shape: linking costs
    // something real (Security.framework, advapi32, a static table on
    // wasm), and the store is meaningless without an identity to
    // namespace it — hence the pkg_id requirement (docs/services.md).
    const secure_store_opt = b.option(bool, "secure_store", "Link the secure_store service (requires pkg_id — the app id is the store's namespace)") orelse false;

    // The dev file store: the backend a driver binary gets instead of the
    // Keychain or the Secret Service, neither of which is a driver's to
    // use (AppOptions.secure_store_dev,
    // docs/internals/secure_store.md). Off by default, refused outside
    // Debug and outside macOS / desktop Linux, and the binary that
    // carries it says so on stderr at every launch.
    const secure_store_dev_opt = b.option(bool, "secure_store_dev", "Swap secure_store's platform backend for the plaintext dev file store — Debug, macOS or desktop Linux, and never a shipping build (requires -Dsecure_store)") orelse false;

    // deep_link: the domains the app claims for App Links / Universal
    // Links (repeat -Ddeep_link to claim more). Same "linking needs
    // identity" shape as the store — the entitlement and assetlinks are
    // keyed to the app id — and the claimed set drives the packaging
    // association files below (docs/services.md).
    const deep_link_domains = b.option([]const []const u8, "deep_link", "Link the deep_link service: a claimed domain for App Links / Universal Links (repeat for more; requires pkg_id)") orelse &[_][]const u8{};

    // oauth: the custom URL schemes the app's OAuth redirects land on
    // (repeat -Doauth to register more), and Sign in with Apple's
    // entitlement. Same "linking needs identity" shape as the store and
    // deep_link, and the declared set drives the CFBundleURLTypes entry
    // and the Android intent-filter below (docs/services.md). This is
    // the custom-scheme opt-in deep_link deferred: deep_link still
    // derives only verified https domains.
    const oauth_schemes = b.option([]const []const u8, "oauth", "Link the oauth service: a custom URL scheme the app's redirect uses (repeat for more; requires pkg_id)") orelse &[_][]const u8{};
    const oauth_apple = b.option(bool, "oauth_apple", "Link oauth with Sign in with Apple: adds the applesignin entitlement and the native ASAuthorizationController leg (requires pkg_id)") orelse false;

    // iap: the same "linking needs identity" shape again — both stores
    // resolve products against the app id — deriving Android's BILLING
    // permission below. The only service with no leg at all on three of
    // the six targets (docs/internals/iap.md).
    const iap_opt = b.option(bool, "iap", "Link the iap service: StoreKit on Apple, Play Billing on Android, no store elsewhere (requires pkg_id)") orelse false;

    // notification: "linking needs identity" for three platforms at once
    // — Android names its channel after the app, Windows derives its
    // AppUserModelID from the id, and Apple keys the entitlement to it —
    // and it derives the first dangerous permission any service has asked
    // for, POST_NOTIFICATIONS. Push is the second flag rather than a
    // wider first one: local notifications derive one permission and no
    // entitlement, and an app that only reminds locally should ship
    // neither the entitlement nor the FCM declaration
    // (docs/internals/notifications.md).
    const notification_opt = b.option(bool, "notification", "Link the notification service: local notifications on all six platforms (requires pkg_id)") orelse false;
    const notification_push_opt = b.option(bool, "notification_push", "Link notification with remote push: APNs, FCM, and web push (implies -Dnotification; requires pkg_id)") orelse false;
    const notification_push_key = b.option([]const u8, "notification_push_key", "The VAPID application server key (public half, base64url) web push subscribes with; the web needs it, APNs and FCM ignore it") orelse "";

    // The linked-service set the -D options above describe, in the one
    // shape both the module wiring and the packaging emitters read —
    // appServices' twin for nokre's own build, stated once so the two
    // consumers below cannot drift.
    const services: packaging.Services = .{
        .secure_store = secure_store_opt,
        .deep_link_domains = deep_link_domains,
        .oauth_schemes = oauth_schemes,
        .oauth_apple = oauth_apple,
        .iap = iap_opt,
        .notification = notification_opt or notification_push_opt,
        .notification_push = notification_push_opt,
        .notification_push_key = notification_push_key,
    };

    // The kitchen sink on iOS: both static libraries plus the pkg tree
    // on the install prefix the Xcode build phase fills (-p …) — the
    // project's INFOPLIST_FILE and asset catalog point into it, so
    // identity and the icon flow from the declaration with no extra
    // step. The app itself keeps its zero-services contract, so the
    // manifest tree is added separately from its declaration below.
    if (target.result.os.tag == .ios) {
        if (!enable_skia) {
            const fail = b.addFail("iOS builds require -Dskia (run tools/fetch-deps.sh and tools/build-skia-ios.sh first)");
            b.default_step.dependOn(&fail.step);
            return;
        }
        const app = addAppTo(b, .{
            .name = "kitchen-sink",
            .root_source_file = b.path("examples/kitchen_sink/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(app.artifact);
        if (app.shim) |shim| b.installArtifact(shim);
        installKitchenSinkPkg(b, b.getInstallStep());
        return;
    }

    // The kitchen sink on Android: one static library of all the Zig
    // (the Gradle project regenerates the pkg tree itself, at
    // configuration time).
    if (target.result.abi.isAndroid()) {
        const app = addAppTo(b, .{
            .name = "kitchen-sink",
            .root_source_file = b.path("examples/kitchen_sink/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(app.artifact);
        return;
    }

    const nokre = b.addModule("nokre", .{
        .root_source_file = b.path("src/nokre.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = sanitize_c,
    });
    configureNokre(b, nokre, pkg_decl, services, secure_store_dev_opt);

    // ---- Pure unit tests: no dependencies, run anywhere. ----
    const unit_tests = b.addTest(.{ .root_module = nokre });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests (pure Zig; add -Dskia -Dgolden for screenshot tests)");
    test_step.dependOn(&run_unit_tests.step);

    // The dev server is a tool rather than a part of the library, so it
    // is not in the module above — but the two questions it answers
    // (what a target names, what a browser is told a file is) are
    // exactly the kind that fail as a blank page, so they are tested
    // here with everything else.
    const serve_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/render/dom/serve.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(serve_tests).step);

    // The one thing `zig test` structurally cannot check: a real
    // executable driving a real app against a real store. Under
    // `zig test` a service *is* its mock, so the store the unit suite
    // exercises is never one the OS answers — the boundary
    // docs/testing.md names, and the tier nokre owes on its own side.
    addDevStoreCheck(b, test_step, target);

    // And the other one: the native http transport's threads, which no
    // `zig test` can reach either — under it the service is its mock,
    // and native_test.zig drives `perform` without them.
    addHttpStressCheck(b, test_step, target);

    // The other half of the web edition, which no Zig test can reach.
    addJsParseCheck(b, test_step, js_parse);

    // And the question a parse cannot answer: do the three legs that
    // exist only on the web actually work when the shipped JavaScript
    // calls them? A wasm app, the site's own live.js, and node.
    addWebServicesCheck(b, test_step, js_parse);

    // And the one decision this library states twice, in two languages:
    // the locale a stub sends a reader to.
    addLocaleStubCheck(b, test_step, target, js_parse);

    if (update_goldens and !enable_golden) {
        const fail = b.addFail("-Dupdate-goldens requires -Dgolden: `zig build test -Dskia -Dgolden -Dupdate-goldens`");
        test_step.dependOn(&fail.step);
    }

    // ---- Cross-compile check for platform stubs. ----
    const check_step = b.step("check-targets", "Compile-check the library for all supported targets");
    const check_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .ios },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android },
        .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
    };
    const check_decl: PackageDecl = .{ .name = "check", .id = "dev.nokre.check", .version = "0.0.0", .build = 0 };
    for (check_targets) |query| {
        // The bare library: nothing linked, so every platform stub and
        // the comptime dispatch must analyze on their own.
        addCheckObject(b, check_step, query, optimize, "nokre-check", null, .{}, false);

        // The linked twin: secure_store and deep_link enabled under a
        // dummy identity so native.zig / web.zig and the comptime
        // dispatch are semantically analyzed per OS tag (the force blocks
        // at the end of secure_store.zig / deep_link.zig). Objects
        // compile but never link, so the extern nokre_ss_* /
        // nokre_deep_link_install symbols need no definition here — the C
        // backends and shell hooks compile in where their system headers
        // exist.
        addCheckObject(b, check_step, query, optimize, "nokre-check-store", check_decl, .{
            .secure_store = true,
            .deep_link_domains = &.{"nokre.dev"},
        }, false);

        // The dev file store's own object, on the two targets it is
        // allowed on (devStoreAllowed refuses the other four, and a
        // refusal is a failed build — so this loop must not ask for one).
        // dev.c is plain POSIX with no framework and no daemon behind it,
        // which is what lets it compile from any host and makes this the
        // one backend `check-targets` can analyze without an SDK. Debug
        // rather than the build's optimize, for the same reason: Debug is
        // the gate, and the object honors it instead of dodging it.
        if (query.os_tag == .macos or (query.os_tag == .linux and query.abi != .android)) {
            addCheckObject(b, check_step, query, .Debug, "nokre-check-store-dev", check_decl, .{
                .secure_store = true,
            }, true);
        }

        // oauth gets its own object rather than riding the one above: a
        // compile-only object links nothing, and on COFF zig refuses to
        // fold two C sources into one — secure_store's windows.c and
        // oauth's would collide. One service per object also makes a
        // failure name the leg that broke.
        addCheckObject(b, check_step, query, optimize, "nokre-check-oauth", check_decl, .{
            .oauth_schemes = &.{"dev.nokre.check"},
            .oauth_apple = true,
        }, false);

        // iap gets its own for oauth's reason, and for a second one this
        // service alone has: three of these six targets compile the
        // policy layer with no leg behind it, and "the storeless build
        // still analyzes" is exactly what would rot unnoticed.
        addCheckObject(b, check_step, query, optimize, "nokre-check-iap", check_decl, .{ .iap = true }, false);

        // notification gets its own for iap's second reason, sharpened:
        // it is the one service every target has a leg for, so what needs
        // analyzing per OS tag is the *whole* surface — the install, the
        // three boot probes, the post/cancel path and the wasm export —
        // rather than a policy layer standing in for absent backends.
        // Push is on, so the entitlement-and-FCM half compiles too.
        addCheckObject(b, check_step, query, optimize, "nokre-check-notification", check_decl, .{
            .notification = true,
            .notification_push = true,
        }, false);
    }

    // The one target of the six that can be *linked* from any host, and
    // therefore the only place this step can ask the question objects
    // cannot answer: does every symbol the linked services name have a
    // definition? The other five need a prebuilt, an SDK, or a shell
    // whose system headers exist on one OS — so they stay compile-only,
    // and the desktop link that covers them is the examples hanging off
    // `test -Dskia`. The web needs none of that: no Skia, no AccessKit,
    // no libc, no C shell — services.js and this module are the whole
    // edition. Every service the web has a leg for is on, so a web half
    // that is declared and never defined fails here rather than in a
    // consumer's `zig build -Dweb`. iap is absent on the web by contract
    // (docs/services.md) and stays off.
    {
        const app = addAppTo(b, .{
            .name = "nokre-check-web",
            .root_source_file = b.path("examples/kitchen_sink/main.zig"),
            .target = webTarget(b),
            .optimize = optimize,
            .pkg = check_decl,
            .secure_store = true,
            .deep_link_domains = &.{"nokre.dev"},
            .oauth_schemes = &.{"dev.nokre.check"},
            .notification = true,
            .notification_push = true,
        });
        check_step.dependOn(&app.artifact.step);
    }

    // ---- Web: the kitchen sink as a servable site. ----
    // The web's edition is the DOM one (docs/internals/dom-edition.md):
    // no Skia, no emscripten, no libc — wasm32-freestanding and the
    // browser's own rasterizer. The directory is what a consumer's
    // `App.web` is, assembled by the same function, so nokre's own site
    // and every consumer's are the same set of files by construction.
    {
        // Through the same consumer path an app takes: addAppTo sees a
        // wasm target and hands back one module, entry disabled.
        const app = addAppTo(b, .{
            .name = "kitchen-sink",
            .root_source_file = b.path("examples/kitchen_sink/main.zig"),
            .target = webTarget(b),
            .optimize = optimize, // addWebApp forces ReleaseSmall
        });

        // The kitchen sink declares no identity to `addApp` — declaring
        // one links package_info, and this example runs with zero
        // services linked by contract (docs/internals/contributing.md)
        // — so its page, manifest and icons come from the declaration
        // handed straight to the tree, exactly as installKitchenSinkPkg
        // does for the manifests. `app.web` is therefore not the one
        // installed here; this is the same assembly around the same
        // module.
        const pkg = b.addWriteFiles();
        addPkgTree(b, pkg, kitchen_sink_pkg, .{}, .{}, null);
        const site = addWebSite(b, app.artifact.getEmittedBin(), "app.wasm", pkg.getDirectory());

        const web_step = b.step("web", "Build the kitchen sink for the browser into zig-out/web/");
        web_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = site,
            .install_dir = .prefix,
            .install_subdir = "web",
        }).step);

        // A site cannot be opened, only served (src/render/dom/serve.zig
        // says why), so the second half of "see it in a browser" is a
        // step and not a sentence in a doc telling the reader to find a
        // static server.
        const serve_step = b.step("serve", b.fmt("Build the kitchen sink for the browser and serve it at http://localhost:{d}", .{port}));
        serve_step.dependOn(&addWebServeTo(b, site, .{ .port = port }).step);
    }

    // ---- Packaging manifests: build outputs of the declaration. ----
    // The tree docs/services.md describes: `zig build pkg` →
    // zig-out/pkg, and the Android example's Gradle runs it at every
    // configuration. A consumer that declares pkg_* gets the same tree
    // carrying its own identity as named write-files "pkg" (consumers
    // using addApp get it as App.pkg instead).
    {
        const pkg_step = b.step("pkg", "Generate platform packaging manifests into zig-out/pkg");
        installKitchenSinkPkg(b, pkg_step);
        // The web defaults: app.wasm as the module the generated page
        // boots, and no extra connect-src host — a `-D` build here
        // declares an identity, not a site, and both are `addApp`'s
        // surface. No apple_icon either: a `-D` option carries
        // strings, and a path resolved against nokre's own build root
        // is not the consumer's icon — declaring one is `addApp`'s
        // surface, and this tree carries the derived mark
        // (docs/services.md).
        if (pkg_decl) |decl|
            addPkgTree(b, b.addNamedWriteFiles("pkg"), decl, services, .{}, null);
    }

    // The run-* step names exist whatever the flags and dep state say:
    // registering them only when the examples can actually build turned
    // `zig build run-hello` into "no step named 'run-hello'" with no
    // hint, and hid the steps from `zig build -l`. When the examples
    // cannot build, each name instead carries a failure that says why
    // (blockedRunSteps below).
    if (!enable_skia) {
        if (enable_golden) {
            const fail = b.addFail("-Dgolden requires -Dskia");
            test_step.dependOn(&fail.step);
        }
        blockedRunSteps(b, b.addFail("the run-* examples require -Dskia: `zig build run-hello -Dskia` (run tools/fetch-deps.sh once first)"));
        return;
    }

    b.build_root.handle.access(b.graph.io, skia_probe, .{}) catch {
        const fail = b.addFail("deps/skia not found — run tools/fetch-deps.sh first");
        b.default_step.dependOn(&fail.step);
        blockedRunSteps(b, fail);
        return;
    };
    if (target.result.os.tag == .windows and !is_msvc) {
        const fail = b.addFail("Windows -Dskia builds link the MSVC-ABI Skia prebuilt — build with -Dtarget=x86_64-windows-msvc (the default when -Dskia is set on a Windows host)");
        b.default_step.dependOn(&fail.step);
        blockedRunSteps(b, fail);
        return;
    }

    // ---- Examples, through the same consumer path (addAppTo). ----
    for (examples) |ex| {
        const app = addAppTo(b, .{
            .name = ex.name,
            .root_source_file = b.path(ex.src),
            .target = target,
            .optimize = optimize,
            .pkg = ex.pkg,
            // Only identity-carrying examples link secure_store —
            // hello alone today.
            .secure_store = ex.pkg != null,
            // Same rule, same example: notifications need identity too
            // (the channel, the AppUserModelID and the entitlement are
            // all keyed to the app id). The kitchen sink stays at zero
            // linked services by contract (docs/internals/contributing.md),
            // so hello is where a service that links gets shown.
            .notification = ex.pkg != null,
        });
        b.installArtifact(app.artifact);
        // The link `check-targets` cannot do. That step compiles objects
        // and never links, so a declaration with no definition is
        // invisible to it — which is exactly how a shell naming a symbol
        // that only an optional service defines reached a consumer's
        // build. These two artifacts are the two ends of the service
        // spectrum on the one target this machine can actually link: the
        // kitchen sink at zero linked services, which is the shape every
        // app starts in and the shape that broke, and hello with the
        // ones that need an identity. Hanging them on `test` costs
        // nothing — `-Dskia` already builds both for the install step —
        // and makes `zig build test -Dskia -Dgolden` the gate that
        // would have caught it.
        test_step.dependOn(&app.artifact.step);
        // On macOS the run step drives the binary inside an assembled
        // bundle: without one there is no bundle identifier, and a
        // notification cannot be posted at all (addMacosBundle).
        const run = if (target.result.os.tag == .macos and ex.pkg != null) blk: {
            const inside = addMacosBundle(b, app.artifact, ex.pkg.?, .{
                .secure_store = true,
                .notification = true,
            }, ex.name);
            const r = std.Build.Step.Run.create(b, b.fmt("run {s}", .{ex.name}));
            r.addFileArg(inside);
            break :blk r;
        } else b.addRunArtifact(app.artifact);
        const run_step = b.step(
            b.fmt("run-{s}", .{ex.name}),
            b.fmt("Run the {s} example", .{ex.name}),
        );
        run_step.dependOn(&run.step);
    }

    // ---- Golden screenshot tests (headless, need Skia for text). ----
    if (enable_golden) {
        // Through the consumer path, like the examples above: nokre's
        // own goldens are the exercise for the recipe `addGoldenTests`
        // hands a consumer, so the two cannot drift. Baseline
        // maintenance stays explicit — -Dupdate-goldens reaches
        // `expectGolden`'s `.update` only through the options module
        // that call builds, so CI, which never passes the flag, can
        // neither mint nor heal a golden.
        const goldens = addGoldenTestsTo(b, .{
            .root_source_file = b.path("tests/golden.zig"),
            .target = target,
            .optimize = optimize,
            .nokre = nokre,
            .update_goldens = update_goldens,
            .cwd = b.path("."),
        });
        test_step.dependOn(&goldens.run.step);
    }
}

/// The runnable examples, built through the consumer path (addAppTo).
/// hello links package_info and secure_store, so it gets its own nokre
/// instance carrying the example's identity; kitchen-sink runs with
/// zero services linked, per the contract in docs/services.md.
const Example = struct { name: []const u8, src: []const u8, pkg: ?PackageDecl = null };
const examples = [_]Example{
    .{
        .name = "hello",
        .src = "examples/hello/main.zig",
        .pkg = .{ .name = "hello", .id = "dev.nokre.hello", .version = "0.1.0", .build = 1 },
    },
    .{ .name = "kitchen-sink", .src = "examples/kitchen_sink/main.zig" },
};

/// Register every run-<example> step name carrying only `fail`. The
/// names are registered on every invocation so `zig build -l` always
/// lists them and a blocked `zig build run-hello` fails with the actual
/// requirement instead of "no step named 'run-hello'"; the descriptions
/// match the real steps' so the step listing reads the same either way.
fn blockedRunSteps(b: *std.Build, fail: *std.Build.Step.Fail) void {
    for (examples) |ex| {
        const run_step = b.step(
            b.fmt("run-{s}", .{ex.name}),
            b.fmt("Run the {s} example", .{ex.name}),
        );
        run_step.dependOn(&fail.step);
    }
}

/// The kitchen sink's packaging identity. The app itself keeps its
/// zero-services contract (docs/internals/contributing.md): packaging
/// consumes the declaration, never the package_info service, so the
/// manifests exist while the nokre module links nothing.
const kitchen_sink_pkg: PackageDecl = .{
    .name = "nokre — kitchen sink",
    .id = "dev.nokre.kitchensink",
    .version = "0.1.0",
    .build = 1,
};

fn installKitchenSinkPkg(b: *std.Build, into: *std.Build.Step) void {
    const wf = b.addWriteFiles();
    // The default module name matches the web step's, so the pkg tree's
    // index.html and `zig build web`'s directory agree when merged.
    // No apple_icon: nokre ships no art, so the kitchen sink's icon is
    // the mark derived from its id, like any app that declares none.
    addPkgTree(b, wf, kitchen_sink_pkg, .{}, .{}, null);
    into.dependOn(&b.addInstallDirectory(.{
        .source_dir = wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "pkg",
    }).step);
}

/// Populate a write-files step with the generated packaging tree
/// (docs/services.md): platform manifests are build outputs of the
/// declaration, never hand-written or committed. An invalid declaration
/// attaches a fail step to the tree, so plain builds proceed and
/// anything consuming the manifests fails with the message.
fn addPkgTree(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    decl: PackageDecl,
    services: packaging.Services,
    web: packaging.Web,
    apple_icon: ?std.Build.LazyPath,
) void {
    packaging.validate(decl) catch |err| {
        const fail = b.addFail(switch (err) {
            error.InvalidId => "pkg_id must be two or more dot-separated [a-z][a-z0-9_]* segments — the intersection of Apple and Android identifier rules (docs/services.md)",
            error.InvalidBuild => "pkg_build must be >= 1 — Android rejects a versionCode of 0",
        });
        wf.step.dependOn(&fail.step);
        return;
    };
    // The same invalid-declaration rule, for the page's policy: a
    // connect-src source that could end the directive it lands in never
    // reaches a page — it fails the tree, naming the entry.
    if (packaging.badConnectSrc(web.connect_src)) |bad| {
        wf.step.dependOn(&b.addFail(b.fmt(
            "web_connect_src takes hosts the app talks to — \"https://api.example.com\", \"*.example.com\" — and \"{s}\" is not one: no spaces, quotes or semicolons, and never a bare \"*\" (docs/getting-started.md)",
            .{bad},
        )).step);
        return;
    }
    const gpa = b.allocator;
    // nokre_app is the CMake target the Android shell loads
    // (examples/kitchen_sink/android/app/src/main/cpp/CMakeLists.txt).
    _ = wf.add("ios/Info.plist", packaging.iosInfoPlist(gpa, decl, services) catch @panic("OOM"));
    _ = wf.add("android/AndroidManifest.xml", packaging.androidManifest(gpa, decl, services, "nokre_app") catch @panic("OOM"));
    _ = wf.add("android/package.properties", packaging.androidProperties(gpa, decl) catch @panic("OOM"));
    // macOS's bundle, which packaging emitted for nobody until a service
    // needed it: UNUserNotificationCenter refuses to post for a binary
    // with no bundle identifier, so an unbundled nokre app cannot own a
    // notification at all (docs/internals/notifications.md). The
    // executable name is the tree's one convention — `addMacosBundle`
    // renames the artifact into place under it.
    _ = wf.add("macos/Info.plist", packaging.macosInfoPlist(gpa, decl, services, macos_executable) catch @panic("OOM"));
    _ = wf.add("macos/AppIcon.icns", packaging.icon.icns(gpa, decl.id) catch @panic("OOM"));
    // The manifest, the page, and the two files it names. Page and
    // scripts are one artifact in three pieces — the split is the page's
    // policy, which admits no inline script and no inline `<style>`
    // block (packaging.zig's webIndexHtml states it directive by
    // directive). The four names are `packaging.web_page_files`, which
    // is what `addWebSite` lists in `site.manifest`; the switch below is
    // exhaustive over that list, so a file added there without a writer
    // here is a compile error rather than a manifest line pointing at
    // nothing.
    inline for (packaging.web_page_files) |f| {
        _ = wf.add("web/" ++ f, if (comptime std.mem.eql(u8, f, "manifest.webmanifest"))
            packaging.webManifest(gpa, decl) catch @panic("OOM")
        else if (comptime std.mem.eql(u8, f, "index.html"))
            packaging.webIndexHtml(gpa, decl, web) catch @panic("OOM")
        else if (comptime std.mem.eql(u8, f, "page.css"))
            packaging.web_page_css
        else if (comptime std.mem.eql(u8, f, "boot.js"))
            packaging.webBootJs(gpa, web) catch @panic("OOM")
        else
            @compileError("packaging.web_page_files names \"" ++ f ++ "\", which addPkgTree does not write"));
    }
    // The app icon set, derived from the id (src/packaging/icon.zig):
    // the asset-catalog scaffolding Xcode compiles, the adaptive-icon
    // resources Gradle merges, and the PNGs themselves. A declared Icon
    // Composer bundle takes Apple's slot instead — checked and copied
    // whole, never generated.
    const apple_bundle = addAppleIcon(b, wf, apple_icon);
    _ = wf.add("ios/Assets.xcassets/Contents.json", packaging.ios_assets_contents_json);
    if (!apple_bundle)
        _ = wf.add("ios/Assets.xcassets/AppIcon.appiconset/Contents.json", packaging.ios_appicon_contents_json);
    _ = wf.add("android/res/mipmap-anydpi-v26/ic_launcher.xml", packaging.android_adaptive_icon_xml);
    _ = wf.add("android/res/values/ic_launcher.xml", packaging.android_icon_values_xml);
    for (packaging.derivedIcons(apple_bundle)) |f|
        _ = wf.add(f.path, packaging.icon.png(gpa, decl.id, f.size, f.cell) catch @panic("OOM"));
    // deep_link association files (docs/services.md): the client halves
    // ride the Info.plist entitlement + the manifest intent-filter above;
    // these three are emitted only when the service claims domains. The
    // two server files go under .well-known/ at the tree root — the
    // developer copies that directory to each domain's web root. null
    // means unlinked: nothing to add.
    if (packaging.iosEntitlements(gpa, decl, services) catch @panic("OOM")) |ent|
        _ = wf.add("ios/App.entitlements", ent);
    if (packaging.appleAppSiteAssociation(gpa, decl, services) catch @panic("OOM")) |aasa|
        _ = wf.add(".well-known/apple-app-site-association", aasa);
    if (packaging.androidAssetLinks(gpa, decl, services) catch @panic("OOM")) |links|
        _ = wf.add(".well-known/assetlinks.json", links);
}

/// The declared Icon Composer bundle: checked while the graph is
/// built, then copied whole into the tree once per Apple platform
/// (src/packaging/apple_icon.zig). Returns whether the tree carries it.
/// A bundle nokre would not deliver leaves the derived mark in place
/// and attaches the fix to the tree's step — the invalid-declaration
/// rule: plain builds proceed, anything consuming the manifests fails
/// with the sentence naming what to fix.
fn addAppleIcon(b: *std.Build, wf: *std.Build.Step.WriteFile, apple_icon: ?std.Build.LazyPath) bool {
    const src = apple_icon orelse return false;
    // Reading the bundle at construction time is what makes the check
    // possible at all, and a build output has no path yet. An app icon
    // is art in a source tree; say so rather than let a LazyPath panic
    // say it worse.
    switch (src) {
        .generated => return refuseAppleIcon(b, wf, "apple_icon must point at a .icon bundle in your source tree — nokre reads it while the build graph is built, so a build output cannot be one (docs/services.md)"),
        else => {},
    }
    const path = src.getPath2(b, null);
    const problem = packaging.apple_icon.check(b.allocator, b.graph.io, .cwd(), path) catch @panic("OOM");
    if (problem) |p| return refuseAppleIcon(b, wf, switch (p) {
        .not_dot_icon => b.fmt("apple_icon must name an Icon Composer bundle — a directory ending in {s}, which is what Icon Composer exports and what Xcode's app-icon setting resolves; {s} does not (docs/services.md)", .{ packaging.apple_icon.extension, path }),
        .missing => b.fmt("apple_icon points at {s}, which does not exist (docs/services.md)", .{path}),
        .not_a_directory => b.fmt("apple_icon points at {s}, which is a file — a .icon bundle is a directory, drawn as one item by Finder and Xcode; pass the directory itself (docs/services.md)", .{path}),
        .unreadable => b.fmt("apple_icon points at {s}, which the build cannot read (docs/services.md)", .{path}),
        .no_manifest => b.fmt("{s} carries no {s} — that file is the icon; re-export the bundle from Icon Composer (docs/services.md)", .{ path, packaging.apple_icon.manifest_name }),
        .malformed_manifest => b.fmt("{s}/{s} is not valid JSON — nokre hands the bundle to Xcode's actool untouched and cannot repair it (docs/services.md)", .{ path, packaging.apple_icon.manifest_name }),
        .missing_asset => |name| b.fmt("{s}/{s} names the layer image \"{s}\", but {s}/{s}/{s} is not there — copy the layer asset into the bundle (docs/services.md)", .{ path, packaging.apple_icon.manifest_name, name, path, packaging.apple_icon.assets_dir, name }),
    });
    // Delivery is a copy, and only a copy: no resampling, no
    // re-encoding, no second reading of a format Apple's tool owns.
    for (packaging.apple_icon.delivery_paths) |dest| _ = wf.addCopyDirectory(src, dest, .{});
    return true;
}

/// The refusal half of `addAppleIcon`: the fix rides the tree's step,
/// and the tree keeps the derived mark so it stays well-formed.
fn refuseAppleIcon(b: *std.Build, wf: *std.Build.Step.WriteFile, message: []const u8) bool {
    wf.step.dependOn(&b.addFail(message).step);
    return false;
}

/// The executable name inside every nokre `.app`. Fixed rather than the
/// artifact's own name so the emitted Info.plist is a pure function of
/// the declaration — the same rule that keeps every other manifest a
/// function of `pkg_*` alone.
const macos_executable = "nokre_app";

/// Assembles `Contents/{Info.plist,MacOS/<exe>,Resources/AppIcon.icns}`
/// around a macOS artifact and returns the executable inside it.
///
/// This is what the notification service's macOS leg needs and what no
/// other service ever did: a bundle identifier. `zig build run-…` runs
/// the binary *inside* the bundle rather than the bare artifact, so the
/// development loop matches a shipping app — the goldens' argument, one
/// layer down. NSBundle resolves the bundle from the executable's own
/// path, so no launcher and no `open(1)` is involved and stdout still
/// attaches to the terminal that started it.
///
/// Signing is left alone deliberately: an ad-hoc signature changes every
/// rebuild and buys nothing here (secure_store's dev-build note says what
/// that costs and why it is dev-only posture, not contract).
fn addMacosBundle(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    decl: PackageDecl,
    services: packaging.Services,
    app_name: []const u8,
) std.Build.LazyPath {
    const gpa = b.allocator;
    const wf = b.addWriteFiles();
    _ = wf.add("Contents/Info.plist", packaging.macosInfoPlist(gpa, decl, services, macos_executable) catch @panic("OOM"));
    _ = wf.add("Contents/Resources/AppIcon.icns", packaging.icon.icns(gpa, decl.id) catch @panic("OOM"));
    const exe = wf.addCopyFile(artifact.getEmittedBin(), "Contents/MacOS/" ++ macos_executable);
    const install = b.addInstallDirectory(.{
        .source_dir = wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = b.fmt("{s}.app", .{app_name}),
    });
    b.getInstallStep().dependOn(&install.step);
    return exe;
}

/// The linked-service set an `addApp` call implies, in the one shape
/// both the module wiring and the packaging emitters read.
fn appServices(options: AppOptions) packaging.Services {
    return .{
        .secure_store = options.secure_store,
        .deep_link_domains = options.deep_link_domains,
        .oauth_schemes = options.oauth_schemes,
        .oauth_apple = options.oauth_apple,
        .iap = options.iap,
        .notification = options.notification or options.notification_push,
        .notification_push = options.notification_push,
        .notification_push_key = options.notification_push_key,
    };
}

fn configureNokre(b: *std.Build, mod: *std.Build.Module, pkg: ?PackageDecl, services: packaging.Services, secure_store_dev: bool) void {
    // The one C dependency in the core module: Nayuki's qrcodegen
    // (vendored, single file, no heap). Everything else stays pure Zig.
    mod.addCSourceFile(.{
        .file = b.path("deps/qrcodegen/qrcodegen.c"),
        .flags = &.{"-std=c99"},
    });
    // A bare wasm target has no libc to supply the three headers that
    // file includes, and no reason to link one: the DOM edition's live
    // driver is Zig plus the browser's own rasterizer. The headers and
    // the definitions behind them close the gap
    // (shim/freestanding/README.md).
    if (mod.resolved_target) |target| {
        const t = target.result;
        if (t.cpu.arch == .wasm32 and t.os.tag == .freestanding) {
            mod.addIncludePath(b.path("shim/freestanding"));
            mod.addCSourceFile(.{
                .file = b.path("shim/freestanding/freestanding.c"),
                .flags = &.{"-std=c99"},
            });
        }
    }
    configureServices(b, mod, pkg, services, secure_store_dev);
}

/// Every JavaScript file that reaches a browser, and the goal each one is
/// loaded with. The four in `src/render/dom` are copied verbatim into
/// every consumer's site by `addWebSite`; `boot.js` is emitted by
/// packaging.zig into the generated page's directory, and the testdata
/// copy checked here is the byte-exact golden of that emitter
/// (packaging_test.zig's "web boot.js is byte-exact"), so parsing it
/// parses what ships. One more reaches a browser without ever being a
/// file a site serves — `locale_stub.js` is written inline into a
/// generated page, stated at the entry that adds it below.
///
/// The goal is not decoration. live.js, live-worker.js and services.js
/// are ES modules — the driver imports them and the compute actor is a
/// `{ type: "module" }` Worker — while sw.js is a classic script,
/// because `navigator.serviceWorker.register` is called without that
/// option. A module is strict-mode and a classic script is not, so
/// checking one as the other would be checking a file no browser loads.
const JsShipped = struct {
    path: []const u8,
    /// The extension the check copies the file under, which is the only
    /// way to tell node the goal reliably: `node --check` on a bare
    /// `.js` runs its CommonJS-then-ESM detection and *exits zero on a
    /// file that parses as neither* — it reported the unterminated block
    /// in live.js as success. `.mjs` and `.cjs` take the detection out
    /// of the loop, and the copy keeps the original name in front of the
    /// extension so the error names the file a reader can open.
    ext: []const u8,
};

/// Derived from `dom.driver_files` rather than re-typed: the copy in
/// `addWebSite` and the parse here must cover the same set, and a file
/// added to one list but not the other would ship unparsed — or be
/// parsed and never shipped. Only the *goal* is stated here, because
/// only this check needs it.
const js_shipped: [dom_driver_files.len + 2]JsShipped = blk: {
    var list: [dom_driver_files.len + 2]JsShipped = undefined;
    for (dom_driver_files, 0..) |f, i| {
        list[i] = .{
            .path = "src/render/dom/" ++ f,
            // sw.js is the one classic script of the set (the goal note
            // in the doc comment above says why that distinction is the
            // whole point of `ext`).
            .ext = if (std.mem.eql(u8, f, "sw.js")) ".cjs" else ".mjs",
        };
    }
    list[dom_driver_files.len] = .{ .path = "src/packaging/testdata/boot.js", .ext = ".mjs" };
    // The stub's script is the one file here that ships in no site: it
    // is `@embedFile`d and written *inline* into every page
    // `dom.localeStub` produces, which is why it is not in
    // `driver_files` and why it is a classic script — a module in a
    // `<script>` with no `type` is not what a browser would run.
    list[dom_driver_files.len + 1] = .{ .path = "src/render/dom/locale_stub.js", .ext = ".cjs" };
    break :blk list;
};

/// Parse the shipped JavaScript, as part of `zig build test`.
///
/// nokre's own tests are Zig, and Zig cannot see a syntax error in a file
/// it only copies: the four driver files and the emitted boot script ride
/// into every web build untouched, and the first thing that reads them is
/// a browser, which answers a bad one by refusing to boot the app at all.
/// That is a whole edition dark, and until this step nothing between the
/// edit and the browser looked.
///
/// A real parse, by the engine that will run them — a brace count would
/// have caught the case that prompted this and nothing subtler. node is
/// not a nokre dependency and never becomes one: nothing here links it,
/// ships it, or reads it at runtime, and it is asked one question per
/// file through the interface every JavaScript engine has.
///
/// **When node is absent this step fails.** A gate that quietly stands
/// aside on the machine where the tool is missing is worse than no gate,
/// because the build still reports green and the reader has no way to
/// know which green they got. So the two honest outcomes are the only
/// two available: the files were parsed, or someone said in the command
/// line that they would not be.
fn addJsParseCheck(b: *std.Build, step: *std.Build.Step, enabled: bool) void {
    if (!enabled) return;
    const node = b.findProgram(&.{"node"}, &.{}) catch {
        step.dependOn(&b.addFail(
            "the JavaScript that ships in every web build went unparsed: `node` is not on PATH. " ++
                "live.js, live-worker.js, services.js, sw.js and the generated boot.js are copied " ++
                "into a consumer's site verbatim, no Zig test reads them, and a browser answers a " ++
                "syntax error in any of them by refusing to boot the app — so this build fails " ++
                "rather than reporting a green it did not earn. Install node, or pass " ++
                "-Djs-parse=false to say that this run ships them unparsed.",
        ).step);
        return;
    };
    // One copy directory for the set: the check needs the goal in the
    // extension (see `ext` above), and the sources cannot carry it —
    // their names are the names the page and the worker registration
    // ask for.
    const copies = b.addWriteFiles();
    for (js_shipped) |js| {
        const named = b.fmt("{s}{s}", .{ std.fs.path.basename(js.path), js.ext });
        const run = b.addSystemCommand(&.{ node, "--check" });
        run.addFileArg(copies.addCopyFile(b.path(js.path), named));
        // The step's name carries the source path, because node's error
        // can only name the copy.
        run.setName(b.fmt("parse {s}", .{js.path}));
        step.dependOn(&run.step);
    }
}

/// The web's own gate, and the only step in this repository where the
/// three legs that exist *only* on the web actually run:
/// `tests/web_services.zig` built as a site — the same site a consumer
/// gets from `App.web` — and booted by node against
/// `tests/web_browser.mjs`, a browser stub that owns nothing but the
/// platform APIs (a document, a location, a session storage, a window
/// that can open another).
///
/// The JavaScript under test is not restated anywhere: the harness
/// imports the site's own `live.js`, which imports the site's own
/// `services.js`, and every assertion is about what the wasm app
/// recorded. So `deliverDeepLink` really reaches
/// `nokre_deep_link_receive`, a popup's `postMessage` really ends the
/// flow the opener started, and a seed really lands in the in-wasm
/// table before the first `build` reads it — the seam that breaks,
/// executed rather than analyzed (docs/testing.md).
///
/// It rides `-Djs-parse` because it asks for exactly what that option
/// already promises: node, and the shipped JavaScript actually read. A
/// machine without node fails in `addJsParseCheck` with the message
/// that names the fix, so this step stands aside quietly rather than
/// repeating it. ReleaseSmall is not taken from `-Doptimize`: every
/// path a consumer has builds a web app ReleaseSmall (`addWebApp`
/// forces it), so the gate honors the one build a browser will see.
fn addWebServicesCheck(b: *std.Build, step: *std.Build.Step, enabled: bool) void {
    if (!enabled) return;
    const node = b.findProgram(&.{"node"}, &.{}) catch return;

    const decl: PackageDecl = .{
        .name = "web services check",
        .id = "dev.nokre.webcheck",
        .version = "0.0.0",
        .build = 1,
    };
    // Every web-only leg linked at once, under one identity: the store
    // is namespaced by it, and oauth's scheme is the app's own — which
    // is also what the harness asserts the seeded redirect is *not*, in
    // a browser the origin being the registration.
    const app = addAppTo(b, .{
        .name = "web-services-check",
        .root_source_file = b.path("tests/web_services.zig"),
        .target = webTarget(b),
        .optimize = .ReleaseSmall,
        .pkg = decl,
        .secure_store = true,
        .deep_link_domains = &.{"nokre.dev"},
        .oauth_schemes = &.{"dev.nokre.webcheck"},
    });

    const run = b.addSystemCommand(&.{node});
    run.addFileArg(b.path("tests/web_services.mjs"));
    // The site, not the sources: what a consumer deploys is a copy of
    // those files, and a copy is what this boots.
    run.addDirectoryArg(app.web.?);
    // Imported by the harness, so an edit to it is an edit to this
    // step's inputs.
    run.addFileInput(b.path("tests/web_browser.mjs"));
    run.setName("run tests/web_services.mjs");
    // A substring, on stderr, for addDevStoreCheck's reason: asserting
    // the program's last line asserts every scenario before it ran.
    run.expectStdErrMatch("web services: deep_link, oauth, secure_store, locale — all ok");
    run.expectExitCode(0);
    step.dependOn(&run.step);
}

/// The locale stub's gate, and the reason it is a gate rather than a
/// comment: `dom.localeStub` writes a page whose script has to make the
/// same decision `l10n`'s `Bundle.resolve` makes, in a language that
/// cannot call it. Two implementations of one policy is exactly the
/// arrangement this repository refuses everywhere else — so the one
/// place it is unavoidable gets the strongest available substitute, a
/// gate that runs both and compares.
///
/// `tests/locale_stub.zig` (native, host-run like the dev store and the
/// http stress) writes one real stub page and the answers `L.resolve`
/// gives for a table of device tags; `tests/locale_stub.mjs` executes
/// *that page's own script* per tag and asserts it lands where Zig said.
/// Neither file states an expected locale: the bundle states them.
///
/// It rides `-Djs-parse` for `addWebServicesCheck`'s reason — it asks
/// for node and for the shipped JavaScript actually executed — and it
/// needs the host to be the target, since the writer is run, not
/// merely built.
fn addLocaleStubCheck(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, enabled: bool) void {
    if (!enabled) return;
    const t = target.result;
    if (t.os.tag != builtin.os.tag or t.cpu.arch != builtin.cpu.arch) return;
    const node = b.findProgram(&.{"node"}, &.{}) catch return;

    const nokre_mod = b.createModule(.{
        .root_source_file = b.path("src/nokre.zig"),
        .target = target,
        .optimize = .Debug,
    });
    configureNokre(b, nokre_mod, null, .{}, false);
    const exe = b.addExecutable(.{ .name = "locale-stub-check", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/locale_stub.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "nokre", .module = nokre_mod }},
    }) });

    // The page and the table are outputs of the run, so the two halves
    // cannot drift by one being regenerated without the other.
    const write = b.addRunArtifact(exe);
    const page = write.addOutputFileArg("stub.html");
    const answers = write.addOutputFileArg("resolve.json");

    const run = b.addSystemCommand(&.{node});
    run.addFileArg(b.path("tests/locale_stub.mjs"));
    run.addFileArg(page);
    run.addFileArg(answers);
    run.setName("run tests/locale_stub.mjs");
    // A substring, on stderr, for addDevStoreCheck's reason: asserting
    // the program's last line asserts every case before it ran.
    run.expectStdErrMatch("locale stub:");
    run.expectExitCode(0);
    step.dependOn(&run.step);
}

/// One compile-check object: the library built for `query` with exactly
/// `services` linked under `pkg`. Package info stays unlinked whatever
/// `pkg` says — these objects check that the service legs analyze, not
/// that a package derives.
fn addCheckObject(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    pkg: ?PackageDecl,
    services: packaging.Services,
    secure_store_dev: bool,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/nokre.zig"),
        .target = b.resolveTargetQuery(query),
        .optimize = optimize,
    });
    addPackageInfo(b, mod, null);
    addSecureStore(b, mod, pkg, services.secure_store, secure_store_dev);
    addDeepLink(b, mod, pkg, services.deep_link_domains.len != 0);
    addOauth(b, mod, pkg, services);
    addIap(b, mod, pkg, services.iap);
    addNotification(b, mod, pkg, services);
    // An explicit target query is never "native", so zig adds no SDK
    // paths of its own — macos.m and the -framework args need them wired
    // by hand, the addIosApp way. Only the linked objects need it, and
    // only on macOS: Apple SDKs exist nowhere else.
    if (pkg != null and builtin.os.tag == .macos and (query.os_tag == .macos or query.os_tag == .ios)) {
        const sdk_name = if (query.os_tag == .ios) "iphoneos" else "macosx";
        const sdk_path = appleSdkPath(b, sdk_name);
        mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "include" }) });
        mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System", "Library", "Frameworks" }) });
    }
    const obj = b.addObject(.{ .name = name, .root_module = mod });
    step.dependOn(&obj.step);
}

/// `xcrun --show-sdk-path` answers per SDK name and cannot change
/// mid-invocation, but graph construction was asking up to six times
/// per `zig build` (three linked check objects × two Apple SDKs, plus
/// the iOS app path) at a process spawn each — so the answer is
/// memoized per SDK name. Keys are string literals; nothing needs
/// freeing.
var apple_sdk_paths: std.StringHashMapUnmanaged([]const u8) = .empty;

fn appleSdkPath(b: *std.Build, sdk_name: []const u8) []const u8 {
    const gop = apple_sdk_paths.getOrPut(b.allocator, sdk_name) catch @panic("OOM");
    if (!gop.found_existing)
        gop.value_ptr.* = std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" }), " \t\r\n");
    return gop.value_ptr.*;
}

/// The service half of `configureNokre`, on its own for Android — the
/// one target whose qrcodegen C arrives from someone else's link: the
/// consumer's CMake compiles it alongside the Skia shim in the NDK
/// world. (The web's DOM edition takes configureNokre whole:
/// wasm32-freestanding compiles qrcodegen against shim/freestanding,
/// no emscripten involved — docs/internals/dom-edition.md.)
fn configureServices(b: *std.Build, mod: *std.Build.Module, pkg: ?PackageDecl, services: packaging.Services, secure_store_dev: bool) void {
    addPackageInfo(b, mod, pkg);
    addSecureStore(b, mod, pkg, services.secure_store, secure_store_dev);
    addDeepLink(b, mod, pkg, services.deep_link_domains.len != 0);
    addOauth(b, mod, pkg, services);
    addIap(b, mod, pkg, services.iap);
    addNotification(b, mod, pkg, services);
}

/// The native http transport's own gate: `tests/http_stress.zig` built
/// as an executable — not a `zig test` binary — and run. Two `App`s in
/// one process drive nearly two thousand real requests at a loopback
/// origin, which is the only way nokre's detached transfer and watchdog
/// threads, its delivery pump, and std.http.Client's connect machinery
/// are ever put in a room together: under `zig test` the service is its
/// mock, and native_test.zig drives `perform` without the threads on
/// purpose.
///
/// It is a race gate, so it is sized by measurement, not by taste — the
/// file says what the numbers buy. Native desktop only, and quietly so,
/// for addDevStoreCheck's reasons: a cross-compiled binary is one this
/// machine could not run, and the phones and the web reach the network
/// through a transport this program does not contain. Debug is
/// hard-coded rather than taken from `-Doptimize`, for
/// addDevStoreCheck's reason and one of its own: the crash this holds
/// off is a Debug-only panic — a release build turns the same errno
/// into `error.Unexpected` and the request merely fails — so a gate
/// built any other way would watch for something that cannot happen.
fn addHttpStressCheck(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget) void {
    const t = target.result;
    const desktop = switch (t.os.tag) {
        .macos, .windows => true,
        .linux => !t.abi.isAndroid(),
        else => false,
    };
    if (!desktop or t.os.tag != builtin.os.tag or t.cpu.arch != builtin.cpu.arch) return;

    const decl: PackageDecl = .{ .name = "http-stress", .id = "dev.nokre.httpstress", .version = "0.0.0", .build = 0 };
    const nokre_mod = b.createModule(.{
        .root_source_file = b.path("src/nokre.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    configureNokre(b, nokre_mod, decl, .{}, false);
    const exe = b.addExecutable(.{ .name = "http-stress-check", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/http_stress.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "nokre", .module = nokre_mod }},
    }) });

    const run = b.addRunArtifact(exe);
    // A substring, on stderr, for addDevStoreCheck's reason: asserting
    // the program's last line asserts every step before it ran.
    run.expectStdErrMatch("http stress: 1920 requests");
    run.expectExitCode(0);
    step.dependOn(&run.step);
}

// The options module is ALWAYS added (package_info's rule): an unlinked
// call site must hit the curated @compileError in notification.zig, never
// a missing-module error. Placement is split, and each half earns it.
// Apple is oauth's: UNUserNotificationCenter's delegate is any object
// rather than the app delegate, so one service-owned file serves both
// Apple platforms instead of duplicating ~250 lines across two shells the
// way the locale hook does. The other three native legs are deep_link's,
// because there the object the OS calls back really is the shell's —
// NokreActivity on Android, the window procedure and its COM activator on
// Windows, and on Linux the very D-Bus connection the Wayland loop
// already polls. Linking requires the identity: the Android channel is
// named for the app, the Windows AppUserModelID is derived from its id,
// and Apple's entitlement is keyed to it.
fn addNotification(b: *std.Build, mod: *std.Build.Module, decl: ?PackageDecl, services: packaging.Services) void {
    var enabled = services.notification;
    if (enabled and decl == null) {
        const fail = b.addFail("notification needs the app's identity — its Android channel, Windows AppUserModelID and Apple entitlement are keyed to the app id, so set .pkg_id alongside .notification. docs/services.md");
        b.default_step.dependOn(&fail.step);
        enabled = false;
    }
    const opts = b.addOptions();
    opts.addOption(bool, "linked", enabled);
    // Not decoration, iap's reason: an options module carrying only
    // `linked` is byte-identical to deep_link's, and zig refuses one
    // generated file in two modules.
    opts.addOption([]const u8, "service", "notification");
    // Gates the push half at comptime rather than at runtime: an app that
    // ships no `aps-environment` entitlement would have `registerFor
    // RemoteNotifications` fail on a real device, so the honest answer is
    // `pushAvailable` false — decided here, where the entitlement is.
    opts.addOption(bool, "push", enabled and services.notification_push);
    opts.addOption([]const u8, "push_key", services.notification_push_key);
    mod.addImport("nokre_notification_options", opts.createModule());
    if (!enabled) return;
    switch (mod.resolved_target.?.result.os.tag) {
        .macos, .ios => {
            // First-party, in the class of Security.framework and
            // StoreKit: UNUserNotificationCenter is both halves on both
            // platforms, and the push registration rides UIKit/AppKit,
            // which the shells already link.
            mod.linkFramework("UserNotifications", .{});
            mod.linkFramework("Foundation", .{});
            // macOS compiles apple.m here; iOS compiles the same file in
            // the consumer's Xcode project beside shell.m, oauth's split
            // and for oauth's reason — UIKit's headers do not survive
            // zig's clang against a current iOS SDK. Framework headers
            // exist only on a macOS host (secure_store's gate).
            if (mod.resolved_target.?.result.os.tag == .macos and builtin.os.tag == .macos) {
                mod.addCSourceFile(.{
                    .file = b.path("src/services/notification/apple.m"),
                    .flags = &.{ "-fobjc-arc", "-I", "src/services/notification" },
                });
                mod.linkFramework("AppKit", .{});
            }
        },
        // Windows binds combase at first use inside the shell, the way
        // the share pane already does since mingw ships no WinRT headers;
        // Linux rides the shell's dbus-1; Android's half is Java compiled
        // by the consumer's Gradle (secure_store's Android rule); and the
        // web links nothing (services.js and the service worker carry it).
        else => {},
    }
}

// The declaration is always present — an unlinked call site must hit the
// curated @compileError in package_info.zig, never a missing-module
// error. The native side is compiled in only when linked.
fn addPackageInfo(b: *std.Build, mod: *std.Build.Module, decl: ?PackageDecl) void {
    const opts = b.addOptions();
    opts.addOption(bool, "linked", decl != null);
    const d = decl orelse PackageDecl{ .name = "", .id = "", .version = "", .build = 0 };
    opts.addOption([]const u8, "name", d.name);
    opts.addOption([]const u8, "id", d.id);
    opts.addOption([]const u8, "version", d.version);
    opts.addOption(u32, "build", d.build);
    mod.addImport("nokre_package_info_options", opts.createModule());
    if (decl == null) return;
    switch (mod.resolved_target.?.result.os.tag) {
        .macos => {
            mod.addCSourceFile(.{
                .file = b.path("src/services/package_info/macos.m"),
                .flags = &.{"-fobjc-arc"},
            });
            mod.linkFramework("Foundation", .{});
        },
        .ios => {
            // Framework headers exist only on a macOS host — the
            // secure_store gate: check-targets' compile-only objects
            // analyze the extern from any host, and a real iOS build
            // always runs on macOS.
            if (builtin.os.tag == .macos) {
                mod.addCSourceFile(.{
                    .file = b.path("src/services/package_info/ios.m"),
                    .flags = &.{"-fobjc-arc"},
                });
                mod.linkFramework("Foundation", .{});
            }
        },
        else => {},
    }
}

// The options module is ALWAYS added — an unlinked call site must hit
// the curated @compileError in secure_store.zig, never a
// missing-module error (package_info's rule). Composition is comptime
// only: the namespace bakes into secure_store's own options module,
// and at runtime the service never calls package_info.
fn addSecureStore(b: *std.Build, mod: *std.Build.Module, decl: ?PackageDecl, enabled_in: bool, dev_in: bool) void {
    var enabled = enabled_in;
    if (enabled and decl == null) {
        const fail = b.addFail("secure_store needs the app's identity for its namespace — set .pkg_id (package_info) alongside .secure_store. docs/services.md");
        b.default_step.dependOn(&fail.step);
        // The fail lands either way; meanwhile no module may carry an
        // empty namespace, so the store stays unlinked for the rest of
        // this function.
        enabled = false;
    }
    const opts = b.addOptions();
    opts.addOption(bool, "linked", enabled);
    opts.addOption([]const u8, "namespace", if (decl) |d| d.id else "");
    mod.addImport("nokre_secure_store_options", opts.createModule());
    if (dev_in and !enabled) {
        const fail = b.addFail("the secure_store dev store is a backend for the linked service, not a second one — set .secure_store = true alongside .secure_store_dev (docs/services.md)");
        b.default_step.dependOn(&fail.step);
    }
    if (!enabled) return;
    const target = mod.resolved_target.?.result;
    // The three gates on the dev store, all here, all at build time, and
    // each one a failed build rather than a quieter store. There is no
    // runtime path to this backend at all: which C file compiles is
    // decided below, so a binary either carries the platform store or
    // carries the file one, and nothing it reads at runtime can change
    // which (docs/internals/secure_store.md).
    const dev = dev_in and devStoreAllowed(b, mod, target, dev_in);
    if (dev) {
        // POSIX, no framework, no daemon, no host gate: it compiles for
        // macOS and desktop Linux from any host, which is also what lets
        // check-targets analyze it.
        mod.link_libc = true;
        mod.addCSourceFile(.{ .file = b.path("src/services/secure_store/dev.c"), .flags = &.{"-std=c11"} });
        return;
    }
    switch (target.os.tag) {
        .macos, .ios => {
            // Framework headers exist only on a macOS host. The
            // check-targets linked objects still analyze native.zig
            // from any host — a compile-only object leaves the extern
            // nokre_ss_* undefined — and real Apple builds always run on
            // macOS, so the gate never bites a shipping app.
            if (builtin.os.tag == .macos) {
                mod.addCSourceFile(.{ .file = b.path("src/services/secure_store/macos.m"), .flags = &.{"-fobjc-arc"} });
                mod.linkFramework("Security", .{});
                mod.linkFramework("Foundation", .{});
            }
        },
        .windows => {
            // zig's bundled mingw headers include wincred.h, so this
            // compiles host-independently, check objects included —
            // but those headers ride along with libc linkage, which
            // the compile-only check modules don't otherwise request.
            mod.link_libc = true;
            mod.addCSourceFile(.{ .file = b.path("src/services/secure_store/windows.c"), .flags = &.{"-std=c11"} });
            mod.linkSystemLibrary("advapi32", .{}); // CredRead/Write/Delete/EnumerateW
        },
        .linux => {
            // Android reports os.tag == .linux, but its Keystore-backed
            // store rides the Gradle/CMake build (android.c → the Java
            // backend), so build.zig adds no C for it. Desktop Linux uses
            // the Secret Service via libsecret; those headers exist only on
            // a Linux host, so a cross-build from elsewhere leaves the
            // nokre_ss_* externs undefined in the compile-only check object
            // and resolves them at a real Linux link — the macOS/.m gate.
            if (!mod.resolved_target.?.result.abi.isAndroid() and builtin.os.tag == .linux) {
                mod.link_libc = true;
                mod.addCSourceFile(.{ .file = b.path("src/services/secure_store/linux.c"), .flags = &.{"-std=c11"} });
                // libsecret-1 Requires glib/gobject; name them so the link
                // resolves even where pkg-config's transitive deps do not.
                mod.linkSystemLibrary("libsecret-1", .{});
                mod.linkSystemLibrary("glib-2.0", .{});
                mod.linkSystemLibrary("gobject-2.0", .{});
            }
        },
        else => {}, // wasm links nothing (live.js/services.js carry the mirror)
    }
}

/// Where the secure_store dev file store can exist at all: a native
/// desktop POSIX build of the host that is building it. The quiet
/// ahead-of-time answer for a consumer's build.zig deciding whether to
/// wire a dev-store step — `devStoreAllowed` below stays the loud gate
/// that explains each refusal once a build actually asks for the store.
pub fn devStoreHost(target: std.Build.ResolvedTarget) bool {
    const t = target.result;
    const desktop_posix = switch (t.os.tag) {
        .macos => true,
        .linux => !t.abi.isAndroid(),
        else => false,
    };
    return desktop_posix and t.os.tag == builtin.os.tag and t.cpu.arch == builtin.cpu.arch;
}

/// May this build have the dev file store? Three refusals, and a build
/// that trips any of them fails — the flag is never quietly downgraded
/// to the platform store either, because a driver that thinks it has a
/// writable store and does not is the failure this whole backend exists
/// to end.
///
/// The shape is deliberate: nothing here is a property of the machine
/// running the build, so a refusal reproduces everywhere, and there is
/// no combination of environment, signature or runtime state that turns
/// a shipping build's store into this one.
fn devStoreAllowed(b: *std.Build, mod: *std.Build.Module, target: std.Target, dev: bool) bool {
    if (!dev) return false;
    var ok = true;
    // 1. It is a backend for the linked service, not a second service —
    //    refused by the caller, which never reaches this function with
    //    an unlinked store.
    // 2. Debug only. A driver binary is built the way a developer builds
    //    everything they are iterating on; an optimized artifact is one
    //    somebody is preparing to hand out.
    if (mod.optimize != .Debug) {
        const fail = b.addFail("the secure_store dev store builds only in Debug: it is the store of a binary that drives an app, and an optimized artifact is one somebody ships. Drop .secure_store_dev, or build with -Doptimize=Debug (docs/services.md)");
        b.default_step.dependOn(&fail.step);
        ok = false;
    }
    // 3. macOS and desktop Linux only — the two platforms where the OS
    //    store is not a driver's to use (dev.c says what each one does
    //    instead). iOS and Android artifacts exist only to be installed
    //    from a store, the web's table already answers any build, and
    //    Windows' Credential Manager answers any process in a logon
    //    session: on those four the dev store would be a weaker store
    //    solving nothing.
    const desktop_posix = switch (target.os.tag) {
        .macos => true,
        .linux => !target.abi.isAndroid(),
        else => false,
    };
    if (!desktop_posix) {
        const fail = b.addFail("the secure_store dev store exists for macOS and desktop Linux, where the OS store is not a driver's to use. iOS, Android and the web ship through a store that answers already, and Windows' Credential Manager answers any logon session (docs/services.md)");
        b.default_step.dependOn(&fail.step);
        ok = false;
    }
    return ok;
}

/// The dev store's own gate: `tests/dev_store.zig` built as an
/// executable — not a `zig test` binary — and run. It is the only step
/// in this repository where the secure_store verbs a consumer calls
/// reach a store the OS actually answers: everywhere else they reach the
/// per-app Fake (`zig test`), a compile-only object (`check-targets`),
/// or a linked artifact nothing runs (the examples).
///
/// Native desktop POSIX only, and quietly so: the four other targets
/// have no dev store to gate (devStoreAllowed says why), and a
/// cross-compiled binary is one this machine could not run. Debug is
/// hard-coded rather than taken from `-Doptimize`, because Debug is one
/// of the gates — the step honors it instead of asking for an exemption.
fn addDevStoreCheck(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget) void {
    if (!devStoreHost(target)) return;

    const decl: PackageDecl = .{ .name = "dev-store", .id = "dev.nokre.devstore", .version = "0.0.0", .build = 0 };
    const nokre_mod = b.createModule(.{
        .root_source_file = b.path("src/nokre.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    configureNokre(b, nokre_mod, decl, .{ .secure_store = true }, true);
    const exe = b.addExecutable(.{ .name = "dev-store-check", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/dev_store.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "nokre", .module = nokre_mod }},
    }) });

    const run = b.addRunArtifact(exe);
    // The store file goes in the cache, never in the developer's
    // $HOME/.nokre-dev-store: this gate runs on every `zig build test`,
    // and a check that litters a home directory is a check people learn
    // to resent. It also makes the run independent of whatever a real
    // driver session on this machine has stored.
    run.setEnvironmentVariable("NOKRE_SECURE_STORE_DEV", b.cache_root.join(b.allocator, &.{"nokre-dev-store"}) catch @panic("OOM"));
    // A substring, on stderr, because stderr is where the dev store's
    // own launch banner lands — and asserting the program's last line
    // asserts every step before it ran.
    run.expectStdErrMatch("dev store: boot read, set, relaunch, get, list, delete — all ok");
    run.expectExitCode(0);
    step.dependOn(&run.step);
}

// The options module is ALWAYS added (package_info's rule): an unlinked
// call site must hit the curated @compileError in deep_link.zig, never a
// missing-module error. No C rides along here — the inbound hook
// (nokre_deep_link_install) is defined by each platform's shell, not by a
// service-owned native file, and the web leg (web.zig) is Zig compiled
// into the module on wasm and export-forced only when linked
// (src/services/deep_link/deep_link.zig). Linking requires the identity:
// the entitlement and assetlinks are keyed to the app id.
fn addDeepLink(b: *std.Build, mod: *std.Build.Module, decl: ?PackageDecl, enabled_in: bool) void {
    var enabled = enabled_in;
    if (enabled and decl == null) {
        const fail = b.addFail("deep_link needs the app's identity — its entitlement and assetlinks are keyed to the app id, so set .pkg_id alongside .deep_link. docs/services.md");
        b.default_step.dependOn(&fail.step);
        enabled = false;
    }
    const opts = b.addOptions();
    opts.addOption(bool, "linked", enabled);
    mod.addImport("nokre_deep_link_options", opts.createModule());
}

// The options module is ALWAYS added (package_info's rule). Unlike
// deep_link, oauth owns native files of its own: the browser session is
// a service capability, not something a shell has any business knowing
// about, so ASWebAuthenticationSession lives under src/services/oauth —
// secure_store's placement, not deep_link's. Android compiles android.c
// through the consumer's CMake (the Android split), and the web leg is
// Zig plus services.js. The desktops add no C here at all: their
// browser handoff is the shell's own launcher, `nokre_open_url_open`
// (src/services/open_url/open_url.h states the coupling), and the
// listener is Zig (loopback.zig).
fn addOauth(b: *std.Build, mod: *std.Build.Module, decl: ?PackageDecl, services: packaging.Services) void {
    var enabled = services.oauth_schemes.len != 0 or services.oauth_apple;
    if (enabled and decl == null) {
        const fail = b.addFail("oauth needs the app's identity — its URL-type registration and intent-filter are keyed to the app id, so set .pkg_id alongside .oauth. docs/services.md");
        b.default_step.dependOn(&fail.step);
        enabled = false;
    }
    const opts = b.addOptions();
    opts.addOption(bool, "linked", enabled);
    // Not decoration: without the entitlement, ASAuthorizationController
    // fails at runtime on a real device, so an app that did not declare
    // Sign in with Apple gets the browser flow for `.provider = .apple`
    // instead — the outcome that works — and never compiles the native
    // leg at all (oauth.zig).
    opts.addOption(bool, "apple", enabled and services.oauth_apple);
    mod.addImport("nokre_oauth_options", opts.createModule());
    if (!enabled) return;
    const target = mod.resolved_target.?.result;
    switch (target.os.tag) {
        .macos, .ios => {
            // AuthenticationServices carries both legs:
            // ASWebAuthenticationSession and, for Sign in with Apple,
            // ASAuthorizationController. First-party, in the same class
            // as the Security.framework secure_store links — not a
            // vendored SDK, which is the whole reason the browser flow
            // was chosen over an SDK (docs/internals/oauth.md).
            mod.linkFramework("AuthenticationServices", .{});
            mod.linkFramework("Foundation", .{});
            // iOS compiles apple.m in the consumer's Xcode project,
            // beside src/platform/ios/shell.m and for the same reason:
            // AuthenticationServices pulls in UIKit, and UIKit's headers
            // do not survive zig's clang against a current iOS SDK. The
            // Apple split already puts UIKit code on Xcode's side of the
            // line, so this stays consistent rather than special.
            if (target.os.tag == .macos and builtin.os.tag == .macos) {
                // Framework headers exist only on a macOS host — the
                // secure_store gate, for the same reason: the
                // check-targets objects still analyze the extern surface
                // from any host, and a real Apple build runs on macOS.
                mod.addCSourceFile(.{ .file = b.path("src/services/oauth/apple.m"), .flags = &.{"-fobjc-arc"} });
                mod.linkFramework("AppKit", .{});
            }
        },
        // Windows and desktop Linux add nothing: the browser handoff is
        // the shell's launcher (nokre_open_url_open — ShellExecuteW /
        // xdg-open, already compiled with the shell), and the listener
        // is Zig. Android's Custom Tab rides the Gradle/CMake build
        // (android.c → NokreOAuth.java), so build.zig adds no C for it
        // either — secure_store's Android rule.
        else => {}, // wasm links nothing (services.js carries the popup)
    }
}

// The options module is ALWAYS added (package_info's rule). Unlike every
// other service, three of the six targets have no leg at all — Windows
// and Linux have no store nokre can reach and the web was committed to
// "absent on web" by the service checklist — so linking there compiles
// the policy layer and nothing native, and `available` answers false
// (docs/internals/iap.md).
fn addIap(b: *std.Build, mod: *std.Build.Module, decl: ?PackageDecl, linked: bool) void {
    var enabled = linked;
    if (enabled and decl == null) {
        const fail = b.addFail("iap needs the app's identity — both stores resolve products against the app id, so set .pkg_id alongside .iap. docs/services.md");
        b.default_step.dependOn(&fail.step);
        enabled = false;
    }
    const opts = b.addOptions();
    opts.addOption(bool, "linked", enabled);
    // Not decoration: `addOptions` names its generated file by content
    // hash, so an options module carrying only `linked` is byte-identical
    // to deep_link's — and zig refuses one file in two modules. Naming
    // the service is the smallest honest way to differ, and it makes a
    // generated options file self-identifying when a link goes wrong.
    opts.addOption([]const u8, "service", "iap");
    mod.addImport("nokre_iap_options", opts.createModule());
    if (!enabled) return;
    switch (mod.resolved_target.?.result.os.tag) {
        .macos, .ios => {
            // StoreKit 1, in Objective-C: StoreKit 2 is Swift-only and
            // zig cannot compile Swift, so taking it would mean two
            // Apple implementations (docs/internals/iap.md). No
            // entitlement and no plist key — In-App Purchase is a
            // capability on the App ID, enabled in Apple's console — so
            // the whole cost is this framework.
            mod.linkFramework("StoreKit", .{});
            mod.linkFramework("Foundation", .{});
            // iOS compiles storekit.m in the consumer's Xcode project,
            // beside src/platform/ios/shell.m and oauth's apple.m: the
            // payment sheet is presented from UIKit, whose headers do
            // not survive zig's clang against a current iOS SDK. Named
            // for the framework rather than the vendor because Xcode
            // names object files by basename, and a second `apple.m` in
            // one target is a duplicate-output error.
            if (mod.resolved_target.?.result.os.tag == .macos and builtin.os.tag == .macos) {
                // Framework headers exist only on a macOS host — the
                // secure_store gate, for the same reason.
                mod.addCSourceFile(.{ .file = b.path("src/services/iap/storekit.m"), .flags = &.{"-fobjc-arc"} });
                mod.linkFramework("AppKit", .{});
            }
        },
        // Android's Billing leg rides the Gradle/CMake build
        // (android.c → NokreBilling.java), so build.zig adds no C for it —
        // secure_store's Android rule. Desktop Linux, Windows, and wasm
        // have no store and therefore no native half to compile.
        else => {},
    }
}
