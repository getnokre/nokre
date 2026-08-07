//! Golden screenshot tests: render real screens through the production
//! Skia pipeline and compare output byte-for-byte against committed
//! PPM files. Run with `zig build test -Dskia -Dgolden`.
//! PPM and not PGM since the frame widened to RGB for the Google G —
//! every pixel outside that one mark is still r=g=b by construction
//! (docs/internals/pixel-model.md), and the auth-button goldens are
//! where the exception is visible and reviewed.
//! Baselines are explicit: add -Dupdate-goldens to create missing goldens
//! or rewrite mismatched ones, then review (any PPM viewer) and commit.
//! Without it a missing golden fails — CI can never mint a baseline —
//! and a mismatch lands a .actual.ppm next to the golden.

const std = @import("std");
const build_options = @import("build_options");
const h = @import("nokre");

const skia = h.render.skia;
const golden = h.testing.golden;

fn noopPress(_: ?*anyopaque) void {}

// -Dupdate-goldens reaches the library as `.update` on each assertion:
// the flag is a property of this build, not of any one test, so every
// take applies it.
fn renderGolden(harness: *h.testing.Harness, comptime name: []const u8) !void {
    try harness.expectGolden("tests/goldens/" ++ name ++ ".ppm", .{ .update = build_options.update_goldens });
}

fn buildElements(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Elements");
    try tree.append(root, .{ .heading = .{ .content = "Section", .level = .h2 } });
    try tree.append(root, .{ .heading = .{ .content = "Subsection", .level = .h3 } });
    try tree.append(root, .{ .text = .{ .content = "Prose text that is long enough to wrap onto a second line inside this viewport." } });
    try tree.append(root, .{ .text = .{ .content = "mono: fn main() !void", .style = .{ .family = .mono } } });
    try tree.append(root, .{ .divider = .{} });
    const box = try tree.appendId(root, .{ .box = .{} });
    try tree.append(box, .{ .text = .{ .content = "Boxed." } });
    try tree.append(root, .{ .button = .{ .label = "Press me" } });
    try tree.append(root, .{ .button = .{ .label = "Disabled", .disabled = true } });
    try tree.append(root, .{ .toggle = .{ .label = "On", .on = true } });
}

test "golden: elements screen" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 480 }, .{ .build = buildElements });
    defer harness.deinit();
    try renderGolden(&harness, "elements");
}

fn buildForm(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Form");
    try tree.append(root, .{ .text_input = .{ .label = "Name", .placeholder = "Your name" } });
    try tree.append(root, .{ .text_input = .{ .label = "City", .value = "Berlin", .cursor = 6 } });
    try tree.append(root, .{ .button = .{ .label = "Submit" } });
}

fn buildSpans(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    // A spanned *heading*, at the level a builder may write: a title
    // is plain words (`Tree.setTitle`), like every other title here.
    try tree.append(root, .{ .heading = .{ .level = .h2, .spans = &.{
        .{ .text = "Rokovski " },
        .{ .text = "Feedback", .strong = true },
    } } });
    try tree.append(root, .{
        .text = .{
            .spans = &.{
                .{ .text = "Plain, " },
                .{ .text = "strong", .strong = true },
                .{ .text = ", " },
                .{ .text = "emphasis", .emphasis = true },
                .{ .text = ", " },
                .{ .text = "both", .strong = true, .emphasis = true },
                .{ .text = ", and " },
                .{ .text = "code()", .code = true },
                .{ .text = ", " },
                // A drawn rule, not a face: it must sit through the lowercase
                // band and stop exactly where the run does, on both lines when
                // one wraps.
                .{ .text = "struck through", .strike = true },
                .{ .text = " — wrapping across faces onto further lines without breaking words." },
            },
        },
    });
    try tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "Prose with " },
        .{ .text = "bold italic", .strong = true, .emphasis = true },
        .{ .text = " and a " },
        .{ .text = "dark run", .ink = .dark },
        .{ .text = "." },
    } } });
    try tree.append(root, .{ .text = .{ .style = .{ .family = .mono }, .spans = &.{
        .{ .text = "mono " },
        .{ .text = "bold", .strong = true },
        .{ .text = " " },
        .{ .text = "italic", .emphasis = true },
    } } });
}

test "golden: span faces across families" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 320 }, .{ .build = buildSpans });
    defer harness.deinit();
    try renderGolden(&harness, "spans");
}

test "golden: form with focused input caret" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 280 }, .{ .build = buildForm });
    defer harness.deinit();
    // Focus the second input so the golden pins caret + focus ring drawing.
    try harness.pressKey(.tab, .{});
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "form-focused");
}

fn buildFieldProblem(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Sign up");
    // Refused *and* focused, in one picture: the outline is focus's to
    // change and the words are the problem's, so the two states have to
    // be legible at the same time.
    try tree.append(root, .{ .text_input = .{
        .label = "Email",
        .value = "not-an-address",
        .cursor = 14,
        .problem = "That is not an email address.",
    } });
    // A clean field between them: nothing about it moves.
    try tree.append(root, .{ .text_input = .{ .label = "City", .value = "Berlin", .cursor = 6 } });
    try tree.append(root, .{ .text_area = .{
        .label = "Why you are joining",
        .problem = "Please say a little more than that — a sentence is plenty, and it is the only thing the reviewers read.",
    } });
    try tree.append(root, .{ .button = .{ .label = "Create account" } });
}

test "golden: a refused field carries its reason under the outline" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 420 }, .{ .build = buildFieldProblem });
    defer harness.deinit();
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "field-problem");
}

fn buildFieldDisabled(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Verify");
    // The submit-in-flight form, whole: the fields are standing down
    // and the button that sent them says so. What the picture has to
    // settle is the split — the label and the outline take the disabled
    // secondary button's two steps, and the *value* does not move.
    try tree.append(root, .{ .text_input = .{
        .label = "Verification code",
        .value = "481923",
        .disabled = true,
    } });
    // A live field between them, so the difference is a difference and
    // not an absolute: same geometry, darker outline, ink label.
    try tree.append(root, .{ .text_input = .{ .label = "City", .value = "Berlin", .cursor = 6 } });
    // Empty and disabled, which is where the placeholder's own step
    // shows: it goes with the label, being prose about typing.
    try tree.append(root, .{ .text_area = .{
        .label = "Why you are joining",
        .placeholder = "A sentence is plenty",
        .disabled = true,
    } });
    try tree.append(root, .{ .button = .{ .label = "Verify", .in_progress = true } });
}

test "golden: a field whose submission is in flight stands its affordance down" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 420 }, .{ .build = buildFieldDisabled });
    defer harness.deinit();
    // Tab once. The first field is out of the order, so focus jumps
    // past it to the live one — which the picture then shows beside its
    // disabled neighbour: same geometry, darker outline, ink label, and
    // a caret. The proof of the focus rule is in the image.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "field-disabled");
}

fn buildPassword(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Sign in");
    try tree.append(root, .{ .text_input = .{
        .label = "Passphrase",
        .value = "hunter2",
        .cursor = 7,
        .obscured = true,
    } });
}

test "golden: obscured input draws a bullet run with the caret after it" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 200 }, .{ .build = buildPassword });
    defer harness.deinit();
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "password");
}

fn buildGlyphButtons(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Cycle");
    const pager = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(pager, .{ .button = .{ .label = "Previous month", .form = .{ .glyph = .chevron_left } } });
    try tree.append(pager, .{ .text = .{ .content = "March" } });
    try tree.append(pager, .{ .button = .{ .label = "Next month", .form = .{ .glyph = .chevron_right }, .disabled = true } });
}

test "golden: glyph-form buttons flanking words, focused and disabled" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 160 }, .{ .build = buildGlyphButtons });
    defer harness.deinit();
    // Focus the enabled glyph button: pins the ring on the bare square.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "glyph-button");
}

fn buildButtonForms(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Emphasis");
    const pair = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(pair, .{ .button = .{ .label = "Save" } });
    try tree.append(pair, .{ .button = .{ .label = "Cancel", .form = .{ .secondary = null } } });
    // Icon pill and icon-only side by side; icon-only has no emphasis
    // variants by design (no pill to outline — append rejects it).
    const icon_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(icon_row, .{ .button = .{ .label = "Add reminder", .form = .{ .filled = .alarm_clock_plus } } });
    try tree.append(icon_row, .{ .button = .{ .label = "Next month", .form = .{ .glyph = .chevron_right } } });
    const dimmed = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(dimmed, .{ .button = .{ .label = "Filled off", .disabled = true } });
    try tree.append(dimmed, .{ .button = .{ .label = "Outlined off", .form = .{ .secondary = null }, .disabled = true } });
}

test "golden: button emphasis — filled, outlined, icon pill, icon-only, disabled pair" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 280 }, .{ .build = buildButtonForms });
    defer harness.deinit();
    // Focus the secondary: pins the ring against the outline, not a fill.
    try harness.pressKey(.tab, .{});
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "button-forms");
}

test "golden: the ring around a filled button keeps its gap" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 280 }, .{ .build = buildButtonForms });
    defer harness.deinit();
    // The other half of the pair: focus the filled pill. Two rounded
    // shapes at the same corner is where an abutting ring used to leave
    // an anti-aliasing seam, so the gap needs pinning here specifically.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "button-focused-fill");
}

fn buildActionRow(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Draft");
    const row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    for ([_][]const u8{ "Publish", "Save draft", "Duplicate", "Archive", "Delete" }) |label| {
        try tree.append(row, .{ .button = .{ .label = label } });
    }
}

test "golden: an overflowing button row folds its tail behind More" {
    // Too narrow for five actions: pins the pills that stay standing,
    // the outlined control at the row's trailing end, and the fact that
    // nothing is left clipped at the edge.
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 200 }, .{ .build = buildActionRow });
    defer harness.deinit();
    try renderGolden(&harness, "button-row-folded");
    // The sheet it opens: the button that gave up its slot leading the
    // ones that had overflowed, each restated whole.
    try harness.tapLabel("More");
    try renderGolden(&harness, "button-row-folded-sheet");
}

fn buildInProgressButtons(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("At work");
    // A resting pill beside a running one: same form, same fill, same
    // full-strength ink — busy is not unavailable, and the only
    // difference is the words standing down for the `…`.
    const pair = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(pair, .{ .button = .{ .label = "Save changes" } });
    try tree.append(pair, .{ .button = .{ .label = "Send changes", .in_progress = true } });
    // The other three forms at work: the outline still carries its
    // border, the icon pill holds the width its glyph and words bought,
    // and the glyph form stands the `…` on the bare tap target.
    const forms = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(forms, .{ .button = .{ .label = "Cancel upload", .form = .{ .secondary = null }, .in_progress = true } });
    try tree.append(forms, .{ .button = .{ .label = "Add reminder", .form = .{ .filled = .alarm_clock_plus }, .in_progress = true } });
    try tree.append(forms, .{ .button = .{ .label = "Next month", .form = .{ .glyph = .chevron_right }, .in_progress = true } });
    // Both flags at once: `in_progress` wins the pixels, `disabled` wins
    // the focus stop — so this one dims and Tab passes it by.
    try tree.append(root, .{ .button = .{ .label = "Retry", .disabled = true, .in_progress = true } });
    // With a number, the track takes the ellipsis's slot — filled pill
    // and outlined, so both tone pairs are on the page. A dimmed pill
    // keeps its `…` (above): the meter's tones exist to be read.
    const measured = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(measured, .{ .button = .{ .label = "Upload photos", .in_progress = true, .progress_percent = 60 } });
    try tree.append(measured, .{ .button = .{ .label = "Sync library", .form = .{ .secondary = null }, .in_progress = true, .progress_percent = 25 } });
}

test "golden: buttons at work — the ellipsis in every form, each holding its size" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 440, .h = 300 }, .{ .build = buildInProgressButtons });
    defer harness.deinit();
    // Two tabs: past the resting pill and onto the running one. A busy
    // button keeps its focus stop, so the ring has to draw on it — that
    // is the whole reason it stays reachable.
    try harness.pressKey(.tab, .{});
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "button-in-progress");
}

fn buildAuthButtons(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Sign in");
    // The words are the app's on both — nokre ships the mark and no
    // translation of the vendor's string, so every sign-in button names
    // its own wording.
    try tree.append(root, .{ .button = .{ .label = "Sign in with Apple", .form = .{ .provider = .apple } } });
    // The outlined emphasis — Apple's third sanctioned style — with the
    // same button localized, which is how a translated app renders it.
    // Two *identically* named sign-in buttons on one screen would fail
    // the a11y audit, and rightly: a screen reader user could not tell
    // them apart.
    try tree.append(root, .{ .button = .{
        .label = "Mit Apple anmelden",
        .form = .{ .provider = .apple_outlined },
    } });
    // Beside an ordinary pill, so the mark's optical size against a
    // Lucide glyph at the same scale is reviewable in one image.
    try tree.append(root, .{ .button = .{ .label = "Add reminder", .form = .{ .filled = .alarm_clock_plus } } });
    // The Google button: the four G arcs are the only colored pixels
    // any golden carries, and this pair of images (light and dark) is
    // where a reviewer sees them — white pill with the hairline border
    // in light, near-black pill in dark, the G identical in both.
    try tree.append(root, .{ .button = .{ .label = "Sign in with Google", .form = .{ .provider = .google } } });
}

test "golden: sign-in buttons carry the vendor mark in both emphases" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 300 }, .{ .build = buildAuthButtons });
    defer harness.deinit();
    try renderGolden(&harness, "auth-button");
}

test "golden: the filled sign-in button inverts with the appearance" {
    // Apple sanctions black, white, and white-outlined. The filled pill
    // is `.ink` on `.paper`, and both flip with the appearance — so the
    // dark screen *is* Apple's white button, with no second style and no
    // colour anywhere.
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 300 }, .{ .build = buildAuthButtons });
    defer harness.deinit();
    harness.app.setScheme(.dark);
    try renderGolden(&harness, "auth-button-dark");
}

fn buildLists(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Steps");

    // Ordered from 9, so the marker column has to widen for "10." and
    // every item's words still start on the same x.
    const ordered = try tree.appendId(root, .{ .list = .{ .ordered = true, .start = 9 } });
    for ([_][]const u8{
        "Open the case.",
        "Disconnect the battery before touching anything else.",
        "Lift the tray straight out.",
    }) |line| {
        const item = try tree.appendId(ordered, .{ .list_item = .{} });
        try tree.append(item, .{ .text = .{ .content = line } });
    }

    try tree.append(root, .{ .heading = .{ .content = "Notes", .level = .h2 } });
    // Unordered, with a nested level: the indent is what carries depth.
    const bullets = try tree.appendId(root, .{ .list = .{} });
    const first = try tree.appendId(bullets, .{ .list_item = .{} });
    try tree.append(first, .{ .text = .{ .content = "Torque to spec." } });
    const nested = try tree.appendId(first, .{ .list = .{} });
    const inner = try tree.appendId(nested, .{ .list_item = .{} });
    try tree.append(inner, .{ .text = .{ .content = "4 Nm on the corners." } });
    const second = try tree.appendId(bullets, .{ .list_item = .{} });
    try tree.append(second, .{ .text = .{ .content = "Keep the shim." } });
}

test "golden: ordered and unordered lists with a shared marker column" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 400 }, .{ .build = buildLists });
    defer harness.deinit();
    try renderGolden(&harness, "lists");
}

fn buildCodeBlock(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Verbatim");
    // Fits: no clip, no indicator, indentation preserved.
    try tree.append(root, .{ .code_block = .{
        .content = "fn main() !void {\n    log(\"hi\");\n}",
    } });
    try tree.append(root, .{ .text = .{ .content = "Prose keeps the page margin." } });
    // Overflows: declines the margin, bleeds to the screen edges, clips
    // mid-glyph there, and rides the 2px indicator.
    try tree.append(root, .{ .code_block = .{
        .content = "const long = try allocator.dupe(u8, \"a line far wider than the viewport\");\n    indented();",
    } });
}

test "golden: a code block that fits, and one that bleeds and clips" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 280 }, .{ .build = buildCodeBlock });
    defer harness.deinit();
    try renderGolden(&harness, "code-block");
}

fn buildBlockquote(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Quoted");
    const quote = try tree.appendId(root, .{ .blockquote = .{} });
    try tree.append(quote, .{ .text = .{ .content = "Everything should be made as simple as possible, but no simpler." } });
    // The attribution is words inside the quote, not a field on it.
    try tree.append(quote, .{ .text = .{ .content = "\u{2014} attributed", .style = .{ .scale = .small, .ink = .dark } } });
    try tree.append(root, .{ .text = .{ .content = "Surrounding prose keeps the page margin." } });
}

test "golden: a blockquote's leading rule spans everything it quotes" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 240 }, .{ .build = buildBlockquote });
    defer harness.deinit();
    try renderGolden(&harness, "blockquote");
}

/// The screen a fixture's destinations lead to, never visited: the
/// audit resolves every route a control carries against the table
/// (`unresolvable_route`), so a fixture that links somewhere needs the
/// somewhere to exist.
fn buildUnvisited(_: ?*anyopaque, app: *h.App) !void {
    try app.tree.setTitle("Unvisited");
}

const inline_link_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildInlineLinks },
    .{ .name = "terms", .title = .{ .fixed = "Terms" }, .build = buildUnvisited },
    .{ .name = "privacy", .title = .{ .fixed = "Privacy" }, .build = buildUnvisited },
};

fn buildInlineLinks(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Consent");
    try tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "By continuing you accept the " },
        .{ .text = "terms of service", .route = "terms" },
        .{ .text = " and the " },
        .{ .text = "privacy policy", .route = "privacy" },
        .{ .text = ", which explain what we keep." },
    } } });
}

test "golden: inline links underline, and a focused one rings every line" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 220 }, .{ .routes = &inline_link_routes, .initial_route = "home" });
    defer harness.deinit();
    // Tab to the first link: it wraps, so the ring is two boxes.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "inline-links");
}

fn buildDocument(_: ?*anyopaque, app: *h.App) !void {
    // Legal content fetched at runtime: opens at `##`, jumps to `####`,
    // and mixes every part of the subset. The app hands over bytes it
    // did not write and gets ordinary elements back.
    //
    // This screen states no title, which is a shape a page may have:
    // the body carries its own heading, and the outline opens at h2 —
    // one below the level a title would have held.
    try app.tree.append(app.tree.rootId(), .{ .document = .{
        .label = "Terms of Service",
        .source =
        \\## Terms of Service
        \\
        \\Effective **today**. By continuing you accept these terms and
        \\the [privacy policy](privacy).
        \\
        \\#### What we keep
        \\
        \\1. Your account name.
        \\2. Anything you type into a `note`.
        \\
        \\> We never sell it.
        \\
        \\Contact us at [support](mailto:help@example.com) — an external
        \\link, drawn exactly like a routed one; the split is semantic.
        ,
    } });
}

test "golden: a fetched Markdown document expands into ordinary elements" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 460 }, .{ .build = buildDocument });
    defer harness.deinit();
    try renderGolden(&harness, "document");
}

fn buildBadges(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Badges");
    const row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(row, .{ .badge = .{ .label = "Active" } });
    try tree.append(row, .{ .badge = .{ .label = "3 pending" } });
    try tree.append(root, .{ .text = .{ .content = "Inline status chips: words in a border, no hue." } });
}

test "golden: badges are intrinsic-width chips in a horizontal row" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 160 }, .{ .build = buildBadges });
    defer harness.deinit();
    try renderGolden(&harness, "badge");
}

fn buildMarkedBadges(_: ?*anyopaque, app: *h.App) !void {
    // The case a mark on a chip is for: a row of them, scanned together,
    // each glyph restating a grouping the words already carry. The chips
    // still hug their content — the mark is the glyph's own advance, not
    // a band — so the row is 20px per chip wider and nothing else moved.
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Tags");
    const row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(row, .{ .badge = .{ .label = "Istanbul", .icon = .map_pin } });
    try tree.append(row, .{ .badge = .{ .label = "Coffee", .icon = .sparkles } });
    try tree.append(row, .{ .badge = .{ .label = "Turkish", .icon = .languages } });
    try tree.append(root, .{ .text = .{ .content = "The mark restates; the words still say all of it." } });
}

test "golden: a row of chips carrying decorative marks" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 160 }, .{ .build = buildMarkedBadges });
    defer harness.deinit();
    try renderGolden(&harness, "badge-marked");
}

/// The case wrapping exists for: a member row's state chips at the
/// narrowest viewport nokre targets. Three of them do not fit one line
/// and they are not actions, so the row breaks instead of folding — a
/// fold would hide state behind a press, and clipping would hide it
/// outright. Nothing about the tree changed; only where the marks land.
fn buildWrappedChips(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    // A member box, which is where the row actually sits: the box's edge
    // takes 13px off each side, and that is the width the third chip
    // runs out of.
    const box = try tree.appendId(root, .{ .box = .{} });
    try tree.append(box, .{ .text = .{ .content = "bob@acme.com" } });
    const row = try tree.appendId(box, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(row, .{ .badge = .{ .label = "Admin" } });
    try tree.append(row, .{ .badge = .{ .label = "Until cycle end" } });
    try tree.append(row, .{ .badge = .{ .label = "Held for review" } });
    // A button beside chips: each line centers on its own tallest, so
    // the chips below are not held to the taller line above them.
    const mixed = try tree.appendId(root, .{ .box = .{} });
    const mixed_row = try tree.appendId(mixed, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(mixed_row, .{ .button = .{ .label = "Manage" } });
    try tree.append(mixed_row, .{ .badge = .{ .label = "Pending review" } });
    try tree.append(mixed_row, .{ .badge = .{ .label = "Invited" } });
}

test "golden: a row of chips too wide for the line wraps instead of folding" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 320, .h = 220 }, .{ .build = buildWrappedChips });
    defer harness.deinit();
    try renderGolden(&harness, "chips-wrapped");
}

fn buildWrappedChipsRtl(_: ?*anyopaque, app: *h.App) !void {
    // Mirrored, each line fills from the right and breaks in the same
    // places: the lines are the LTR ones reflected, not a different
    // arrangement. Vertical geometry is direction-blind, so they still
    // stack downward.
    app.setDirection(.rtl);
    const tree = &app.tree;
    const root = tree.rootId();
    const box = try tree.appendId(root, .{ .box = .{} });
    try tree.append(box, .{ .text = .{ .content = "بهرام" } });
    const row = try tree.appendId(box, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(row, .{ .badge = .{ .label = "مدیر" } });
    try tree.append(row, .{ .badge = .{ .label = "در پایان دوره ترک می‌کند" } });
    try tree.append(row, .{ .badge = .{ .label = "در انتظار بررسی" } });
}

test "golden: a wrapped row mirrors, filling each line from the right" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 320, .h = 160 }, .{ .build = buildWrappedChipsRtl });
    defer harness.deinit();
    try renderGolden(&harness, "chips-wrapped-rtl");
}

fn buildCheckboxes(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Consent");
    try tree.append(root, .{ .checkbox = .{ .label = "I agree to the terms", .checked = true } });
    try tree.append(root, .{ .checkbox = .{ .label = "Email me updates" } });
    try tree.append(root, .{ .button = .{ .label = "Continue" } });
}

test "golden: checkboxes checked, unchecked, and focused" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 240 }, .{ .build = buildCheckboxes });
    defer harness.deinit();
    // Focus the first checkbox: pins the check mark under the focus ring.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "checkbox");
}

fn buildSwitchesAtWork(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Notifications");
    // A resting switch above a busy one: same row height, words in the
    // same place, and only the track standing down for the `…` — the new
    // value is not a fact until the server says so.
    try tree.append(root, .{ .toggle = .{ .label = "Email me", .on = true } });
    try tree.append(root, .{ .toggle = .{ .label = "Push to phone", .on = true, .in_progress = true } });
    // The box says it the same way, in its own narrower slot.
    try tree.append(root, .{ .checkbox = .{ .label = "Weekly digest", .checked = true, .in_progress = true } });
}

test "golden: switches at work — the ellipsis in the control's slot, the row unmoved" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 240 }, .{ .build = buildSwitchesAtWork });
    defer harness.deinit();
    // Two tabs: past the resting switch and onto the busy one. A busy
    // control keeps its focus stop, so the ring has to draw on it — that
    // is the whole reason it stays reachable.
    try harness.pressKey(.tab, .{});
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "switch-in-progress");
}

fn buildMeters(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Cycle");
    try tree.append(root, .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });
    // Empty and full pin the fill's edge cases against the track border.
    try tree.append(root, .{ .meter = .{ .label = "0 of 30 days", .value = 0, .max = 30 } });
    try tree.append(root, .{ .meter = .{ .label = "30 of 30 days", .value = 30, .max = 30 } });
}

test "golden: meters at empty, partial, and full fill" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 240 }, .{ .build = buildMeters });
    defer harness.deinit();
    try renderGolden(&harness, "meter");
}

fn buildQr(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Invite");
    try tree.append(root, .{ .qr = .{ .label = "Invite link", .value = "https://example.com/invite/XKCD-1234" } });
    try tree.append(root, .{ .copyable = .{ .label = "Or copy it", .value = "https://example.com/invite/XKCD-1234" } });
}

test "golden: qr code with its copyable twin" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 480 }, .{ .build = buildQr });
    defer harness.deinit();
    try renderGolden(&harness, "qr");
}

test "golden: qr code stays ink-on-paper in dark appearance" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 480 }, .{ .build = buildQr });
    defer harness.deinit();
    harness.app.setScheme(.dark);
    try renderGolden(&harness, "qr-dark");
}

fn buildTiles(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Circle");
    const group = try tree.appendId(root, .{
        .tile_group = .{
            // Long enough to wrap at this viewport: pins the multi-line
            // description layout, not just the single-line case.
            .description = "Manage who belongs to this circle, invite new members, or leave it entirely when you are done.",
        },
    });
    try tree.append(group, .{ .tile = .{ .label = "Members", .detail = "12 people", .route = "members" } });
    try tree.append(group, .{ .tile = .{ .label = "Invites", .route = "invites" } });
    try tree.append(group, .{ .tile = .{ .label = "Leave circle", .on_press = .{ .call = noopPress } } });
}

const tile_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildTiles },
    .{ .name = "members", .title = .{ .fixed = "Members" }, .build = buildUnvisited },
    .{ .name = "invites", .title = .{ .fixed = "Invites" }, .build = buildUnvisited },
};

test "golden: tile group with focused row, details, chevrons, and description" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 280 }, .{ .routes = &tile_routes, .initial_route = "home" });
    defer harness.deinit();
    // Focus the first tile: pins the mixed-radius stroke (top corners
    // curving with the group border, bottom at the row radius) and the
    // skipped separator beneath it.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "tiles");
}

fn buildMarkedTiles(_: ?*anyopaque, app: *h.App) !void {
    // A settings screen is a list of destinations, and a destination
    // wears a mark: the case the field exists for. Every row carries one
    // (`append` allows no mix), the glyphs differ in width, and the row
    // with a detail line is in the set — so the golden pins the two
    // things the band is for: words on one column whatever the glyph,
    // and a mark centred on the *row* rather than on the title's line.
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Settings");
    const group = try tree.appendId(root, .{ .tile_group = .{} });
    try tree.append(group, .{ .tile = .{ .label = "Members", .detail = "12 people", .route = "members", .icon = .users } });
    try tree.append(group, .{ .tile = .{ .label = "Invites", .route = "invites", .icon = .mail } });
    try tree.append(group, .{ .tile = .{ .label = "Leave circle", .on_press = .{ .call = noopPress }, .icon = .log_out } });
}

const marked_tile_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildMarkedTiles },
    .{ .name = "members", .title = .{ .fixed = "Members" }, .build = buildUnvisited },
    .{ .name = "invites", .title = .{ .fixed = "Invites" }, .build = buildUnvisited },
};

test "golden: a tile group's marks share one leading band" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 220 }, .{ .routes = &marked_tile_routes, .initial_route = "home" });
    defer harness.deinit();
    try renderGolden(&harness, "tiles-marked");
}

fn buildRadioGroup(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Choices");
    try tree.append(root, .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS", "None" },
        .selected = 1,
    } });
}

fn buildIcons(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Icons");
    const row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(row, .{ .icon = .{ .name = .accessibility, .label = "Accessibility" } });
    try tree.append(row, .{ .icon = .{ .name = .activity } });
    try tree.append(row, .{ .icon = .{ .name = .airplay, .scale = .h3 } });
    try tree.append(row, .{ .icon = .{ .name = .alarm_clock_check, .scale = .h2, .ink = .dark } });
    try tree.append(row, .{ .icon = .{ .name = .air_vent, .scale = .h1 } });
    // Beside same-scale text: pins the shared line-height alignment.
    const inline_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(inline_row, .{ .icon = .{ .name = .alarm_clock_plus } });
    try tree.append(inline_row, .{ .text = .{ .content = "Add an alarm" } });
}

test "golden: icons across scales and beside text" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 200 }, .{ .build = buildIcons });
    defer harness.deinit();
    try renderGolden(&harness, "icons");
}

test "golden: radio group with focus ring" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 240 }, .{ .build = buildRadioGroup });
    defer harness.deinit();
    // Focused so the golden pins selected dot, unselected rings, and ring.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "radio-group");
}

fn buildSelect(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Preferences");
    try tree.append(root, .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch", "Français" },
        .selected = 1,
    } });
    try tree.append(root, .{ .button = .{ .label = "Save" } });
}

test "golden: select field and its open picker" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 400 }, .{ .build = buildSelect });
    defer harness.deinit();
    // Focused field: pins the chevron, value text, and field-hugging ring.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "select");
    // Open picker: pins scrim dither, title, and the selected option chip.
    try harness.pressKey(.enter, .{});
    try renderGolden(&harness, "select-picker");
}

fn buildCountrySelect(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Shipping");
    try tree.append(root, .{ .select = .{
        .label = "Country",
        .options = &.{ "Argentina", "Australia", "Austria", "Brazil", "Canada", "Denmark", "Germany", "Iceland", "Ireland" },
    } });
}

test "golden: long select picker carries a filter that narrows the rows" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 560 }, .{ .build = buildCountrySelect });
    defer harness.deinit();
    try harness.pressKey(.tab, .{});
    try harness.pressKey(.enter, .{});
    // Open: pins the filter field (focused) above the full row list.
    try renderGolden(&harness, "select-picker-filter");
    // Narrowed: pins filtered rows under an unmoved field and the
    // picker's unchanged height.
    try harness.typeText("ir");
    try renderGolden(&harness, "select-picker-filtered");
}

fn buildCopyable(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Emergency codes");
    try tree.append(root, .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234-QRST" } });
    try tree.append(root, .{ .copyable = .{ .label = "Invite link", .value = "nokre.app/i/9f3k2" } });
    // Wider than the field: pins the middle elision and the glyph's
    // reserved slot.
    try tree.append(root, .{ .copyable = .{ .label = "Signed link", .value = "https://nokre.app/i/9f3k2?sig=4f1fe2f0a9c04d2e8b7a" } });
}

test "golden: copyable fields with mono value, copy glyph, and focus ring" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 300 }, .{ .build = buildCopyable });
    defer harness.deinit();
    // Focused first field: pins the field-hugging ring, the mono value,
    // and the trailing copy glyph.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "copyable");
    // Acknowledged: pins the check standing in for the copy glyph, and —
    // against the frame above — that reserving the slot at the wider mark
    // keeps every value pixel where it was.
    try harness.pressKey(.enter, .{});
    try harness.expectCopied("XKCD-1234-QRST");
    try renderGolden(&harness, "copyable-acknowledged");
}

fn buildComposing(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Compose");
    // A committed prefix and suffix around the caret, so the pre-edit is
    // visibly spliced into the value rather than appended to it.
    try tree.append(root, .{ .text_input = .{
        .label = "Message",
        .value = "ab cd",
        .cursor = 3,
    } });
}

test "golden: the IME caret sits where the IME put it inside the pre-edit" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 200 }, .{ .build = buildComposing });
    defer harness.deinit();
    try harness.pressKey(.tab, .{});
    // Romaji rather than kana, and not for want of an IME: the bundled
    // faces are Latin, mono and Arabic (no system fallback, ever — see
    // introduction.md), so kana would draw as tofu and pin nothing. It
    // is also the honest first phase of a Japanese composition, before
    // conversion.
    //
    // The caret at the end of the run: where an engine leaves it until
    // the user moves, and what nokre drew unconditionally before.
    try harness.composing("nihongo", 7);
    try renderGolden(&harness, "ime-caret-end");
    // The same pre-edit, the user having moved back to fix the reading.
    // The underline is unchanged — it spans the whole pre-edit — and the
    // committed halves do not move either: only the caret does, which is
    // the whole picture this pins.
    try harness.composing("nihongo", 3);
    try renderGolden(&harness, "ime-caret-inside");
}

fn buildTextArea(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Feedback");
    try tree.append(root, .{ .text_area = .{
        .label = "Comments",
        .value = "First line.\nA second line long enough to wrap onto another row of the field.",
        .cursor = 12,
    } });
    try tree.append(root, .{ .text_area = .{
        .label = "Anything else",
        .placeholder = "Optional",
    } });
}

test "golden: text area grows with content, sibling shows the empty minimum" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 400 }, .{ .build = buildTextArea });
    defer harness.deinit();
    // Focused first area: pins wrapped lines, hard break, and the caret
    // on the second line's start.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "text-area");
}

fn buildTableScroll(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    const table = try tree.appendId(root, .{ .table = .{} });
    const header = try tree.appendId(table, .{ .row = .{ .header = true } });
    for ([_][]const u8{ "Name", "Kind" }) |label| {
        const cell = try tree.appendId(header, .{ .cell = .{} });
        try tree.append(cell, .{ .text = .{ .content = label } });
    }
    for ([_][2][]const u8{ .{ "alpha", "mono" }, .{ "beta", "prose" } }) |r| {
        const row = try tree.appendId(table, .{ .row = .{} });
        for (r) |cell_text| {
            const cell = try tree.appendId(row, .{ .cell = .{} });
            try tree.append(cell, .{ .text = .{ .content = cell_text } });
        }
    }
    // 108 puts the offset-0 edge mid-glyph through line 4 (spans start
    // every 32px): the cut itself is the "more here" affordance the
    // audit's cleanly_clipped_scroll_region rule demands. Offset 32
    // keeps a mid-glyph cut at the bottom edge in the rendered frame
    // too, so the golden pins the affordance, not just the geometry.
    const scroll = try tree.appendId(root, .{ .scroll_region = .{ .height = 108, .offset = 32 } });
    for (0..8) |i| {
        var buf: [24]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "Line {d}", .{i + 1});
        try tree.append(scroll, .{ .text = .{ .content = line } });
    }
}

test "golden: table and scrolled region" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 320 }, .{ .build = buildTableScroll });
    defer harness.deinit();
    try renderGolden(&harness, "table-scroll");
}

test "golden: 2x integer scale is pixel-doubled" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 200, .h = 120 }, .{ .build = buildForm });
    defer harness.deinit();
    harness.app.setMeasurer(skia.measurer());

    var surface = try skia.Surface.init(200, 120, 2);
    defer surface.deinit();
    harness.renderTo(surface.canvas());
    try golden.expectMatches(std.testing.allocator, surface.pixels(), surface.pixelWidth(), surface.pixelHeight(), "tests/goldens/form-2x.ppm", .{ .update = build_options.update_goldens });
}

fn buildNavScreen(_: ?*anyopaque, app: *h.App) anyerror!void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Library");
    try tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
        .selected = 1,
    } });
    try tree.append(root, .{ .text = .{ .content = "Content flows in the area the nav leaves behind." } });
}

const nav_routes = [_]h.RouteDef{
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildNavScreen },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildNavScreen },
};

const nav_items = [_]h.Destination{
    .{ .route = "library", .icon = .library },
    .{ .route = "settings", .icon = .settings },
};

test "golden: wide viewport centers the capped bottom pane" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 640, .h = 300 }, .{ .routes = &nav_routes, .nav = &nav_items, .initial_route = "library" });
    defer harness.deinit();
    try renderGolden(&harness, "nav-wide");
}

test "golden: narrow viewport gives the bottom pane the full width" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &nav_routes, .nav = &nav_items, .initial_route = "library" });
    defer harness.deinit();
    try renderGolden(&harness, "nav-bottom");
}

// The other uniform answer a roster may wear — no marks, which is what
// a generated site's header usually is (docs/static-sites.md). Same
// three plate levels at the same slot height; what is gone is the glyph
// and the gap that stood after it, so each destination is exactly as
// wide as its own word.
const unmarked_nav_items = [_]h.Destination{
    .{ .route = "library" },
    .{ .route = "settings" },
};

test "golden: an unmarked roster leaves no room where a mark would be" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &nav_routes, .nav = &unmarked_nav_items, .initial_route = "library" });
    defer harness.deinit();
    try renderGolden(&harness, "nav-unmarked");
}

// A page long enough to scroll under a nav that no longer hides
// anything: the two states the groundless bar has to get right.
fn buildLongNavScreen(_: ?*anyopaque, app: *h.App) anyerror!void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Library");
    for (0..12) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "Line {d} of the long page.", .{i + 1});
        try tree.append(root, .{ .text = .{ .content = line } });
    }
}

const long_nav_routes = [_]h.RouteDef{
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildLongNavScreen },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildLongNavScreen },
};

test "golden: mid-scroll, the page runs on behind and between the items" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &long_nav_routes, .nav = &nav_items, .initial_route = "library" });
    defer harness.deinit();
    harness.app.setSafeBottom(34);
    try harness.scroll(harness.app.tree.rootId(), 40);
    try renderGolden(&harness, "nav-scroll-mid");
}

test "golden: scrolled to the end, the page stands clear of the items" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &long_nav_routes, .nav = &nav_items, .initial_route = "library" });
    defer harness.deinit();
    harness.app.setSafeBottom(34);
    // Past the end: the clamp lands on the last line, `nav_content_gap`
    // above the destinations, with nothing behind them.
    try harness.scroll(harness.app.tree.rootId(), 10_000);
    try renderGolden(&harness, "nav-scroll-end");
}

test "golden: safe_bottom keeps nav items above the band, fill runs through it" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &nav_routes, .nav = &nav_items, .initial_route = "library" });
    defer harness.deinit();
    // The iPhone home-indicator inset: 34 logical px.
    harness.app.setSafeBottom(34);
    try renderGolden(&harness, "nav-safe-bottom");
}

// Five destinations whose titles cannot make a row on a phone: the nav
// collapses to the chip that stands in for all of them.
const crowded_nav_routes = [_]h.RouteDef{
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildNavScreen },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildNavScreen },
    .{ .name = "explore", .title = .{ .fixed = "Explore" }, .build = buildNavScreen },
    .{ .name = "downloads", .title = .{ .fixed = "Downloads" }, .build = buildNavScreen },
    .{ .name = "subs", .title = .{ .fixed = "Subscriptions" }, .build = buildNavScreen },
};

const crowded_nav_items = [_]h.Destination{
    .{ .route = "library", .icon = .library },
    .{ .route = "settings", .icon = .settings },
    .{ .route = "explore", .icon = .compass },
    .{ .route = "downloads", .icon = .download },
    .{ .route = "subs", .icon = .user },
};

test "golden: a nav too crowded for a row collapses to the current section" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 375, .h = 300 }, .{ .routes = &crowded_nav_routes, .nav = &crowded_nav_items, .initial_route = "explore" });
    defer harness.deinit();
    try renderGolden(&harness, "nav-collapsed");
}

test "golden: the crowded roster reopens as a row once the window can hold it" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 1000, .h = 300 }, .{ .routes = &crowded_nav_routes, .nav = &crowded_nav_items, .initial_route = "explore" });
    defer harness.deinit();
    // Past the 560px cap the row takes its natural width and centers —
    // the shape a wide window has always been able to hold, and used to
    // be denied because the pane stopped growing.
    try renderGolden(&harness, "nav-row-reopened");
}

test "golden: the collapsed chip stops short of the notices indicator" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 375, .h = 300 }, .{ .routes = &crowded_nav_routes, .nav = &crowded_nav_items, .initial_route = "explore" });
    defer harness.deinit();
    harness.app.notify(.{ .title = "Sync failed", .description = "Changes are kept locally.", .route = "library" });
    harness.app.minimizeNotices();
    // The chip is as wide as what it holds, so the bar between it and
    // the indicator is page — not a stretched control with a button
    // sitting on top of it.
    try renderGolden(&harness, "nav-collapsed-indicator");
}

test "golden: the collapsed nav's picker lists the sections above the chip" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 375, .h = 420 }, .{ .routes = &crowded_nav_routes, .nav = &crowded_nav_items, .initial_route = "explore" });
    defer harness.deinit();
    harness.app.setMeasurer(skia.measurer());
    harness.app.performLayout();
    // Press the chip: the section list opens *above* it — the chip stays
    // visible, because a menu over its own control would sit under the
    // finger still holding it. Current row marked, screen behind dimmed.
    const nav = h.layout.findNav(&harness.app.tree).?;
    var it = harness.app.tree.children(nav);
    try harness.app.tap(harness.app.tree.rectOf(it.next().?).center());
    try renderGolden(&harness, "nav-collapsed-picker");
}

test "golden: the section menu clears the home-indicator band" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 375, .h = 420 }, .{ .routes = &crowded_nav_routes, .nav = &crowded_nav_items, .initial_route = "explore" });
    defer harness.deinit();
    // The phone the shape was got wrong on. Every other picker golden
    // runs at `safe_bottom = 0`, where a bottom-anchored pane's fill
    // bleeds off-screen and the mistake cannot show: this menu stood on
    // the bar, so the same bleed came down over the chip instead.
    harness.app.setSafeBottom(34);
    harness.app.setMeasurer(skia.measurer());
    harness.app.performLayout();
    const nav = h.layout.findNav(&harness.app.tree).?;
    var it = harness.app.tree.children(nav);
    try harness.app.tap(harness.app.tree.rectOf(it.next().?).center());
    try renderGolden(&harness, "nav-menu-safe-bottom");
}

test "golden: the collapsed nav mirrors under RTL chrome" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 375, .h = 300 }, .{ .routes = &crowded_nav_routes, .nav = &crowded_nav_items, .initial_route = "explore" });
    defer harness.deinit();
    // The label leads from the right and the chevron takes the left —
    // the chevron itself does not flip, being vertically symmetric.
    harness.app.setDirection(.rtl);
    try renderGolden(&harness, "nav-collapsed-rtl");
}

// A route the roster does not name: the screen joins the chrome as its
// own entry rather than leaving the nav marking nothing — or marking a
// section the visitor never opened (`nav.effectiveRoster`).
const offroster_nav_routes = [_]h.RouteDef{
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildNavScreen },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildNavScreen },
    .{ .name = "terms", .title = .{ .fixed = "Terms" }, .build = buildNavScreen },
};

test "golden: the row names a screen that is none of its destinations" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 640, .h = 300 }, .{ .routes = &offroster_nav_routes, .nav = &nav_items, .initial_route = "terms" });
    defer harness.deinit();
    // The marker wears a current destination's plating and the shared
    // file-text mark — the same chip, minus the focus ring it can never
    // take (`element.NavHere`).
    try renderGolden(&harness, "nav-here-row");
}

test "golden: the collapsed chip carries the off-roster screen too" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 375, .h = 300 }, .{ .routes = &offroster_nav_routes, .nav = &nav_items, .initial_route = "terms" });
    defer harness.deinit();
    try renderGolden(&harness, "nav-here-collapsed");
}

test "golden: the off-roster marker mirrors under RTL chrome" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 640, .h = 300 }, .{ .routes = &offroster_nav_routes, .nav = &nav_items, .initial_route = "terms" });
    defer harness.deinit();
    // The whole row runs from the trailing edge, marker last — which
    // under RTL is the leftmost plate, its glyph on the right of its
    // words like every other destination's.
    harness.app.setDirection(.rtl);
    try renderGolden(&harness, "nav-here-rtl");
}

fn buildSegmentedOverflow(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Months");
    try tree.append(root, .{ .segmented = .{
        .label = "Month",
        .options = &.{ "January", "February", "March", "April", "May", "June" },
        .selected = 3,
    } });
}

test "golden: overflowing segmented scrolls to the selected chip" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 320, .h = 140 }, .{ .build = buildSegmentedOverflow });
    defer harness.deinit();
    try renderGolden(&harness, "segmented-overflow");
}

test "golden: the focused track's ring clears the fill and the selected chip" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 320, .h = 140 }, .{ .build = buildSegmentedOverflow });
    defer harness.deinit();
    // The other rounded fill a ring has to stand off from, and the one
    // case where a chip's own outline sits inside a focused element.
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "segmented-focused");
}

fn buildSheetScreen(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Behind");
    try tree.append(root, .{ .text = .{ .content = "Content under the scrim: dimmed by the checkerboard, still legible as context." } });
    const sheet = try app.presentSheet("Sheet");
    try tree.append(sheet, .{ .toggle = .{ .label = "A choice", .on = true } });
}

test "golden: modal sheet over a dithered scrim" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 360 }, .{ .build = buildSheetScreen });
    defer harness.deinit();
    try renderGolden(&harness, "sheet");
}

fn buildNoticeScreen(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Content");
    try tree.append(root, .{ .text = .{ .content = "Flows above the banner, never under it." } });
    app.notify(.{ .title = "Sync failed", .description = "Changes are kept locally.", .route = "library", .icon = .cloud_off, .important = true });
}

const notice_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildNoticeScreen },
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildUnvisited },
};

test "golden: notice banner in the bottom pane" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &notice_routes, .initial_route = "home" });
    defer harness.deinit();
    try renderGolden(&harness, "notice-banner");
}

fn buildRoutelessNoticeScreen(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Content");
    try tree.append(root, .{ .text = .{ .content = "Flows above the banner, never under it." } });
    // The ordinary notice: it reports, and has nowhere to send anyone.
    // The take beside `notice-banner` is where the missing open control
    // — and the words spreading into the room it would have taken — is
    // reviewable as a picture.
    app.notify(.{ .title = "Sync failed", .description = "Changes are kept locally.", .icon = .cloud_off, .important = true });
}

const routeless_notice_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildRoutelessNoticeScreen },
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildUnvisited },
};

test "golden: a routeless notice banner, with no open control to offer" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &routeless_notice_routes, .initial_route = "home" });
    defer harness.deinit();
    try renderGolden(&harness, "notice-banner-routeless");
}

fn buildNoticesPaneScreen(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Content");
    try tree.append(root, .{ .text = .{ .content = "Muted under the scrim while the pane is open." } });
    app.notify(.{ .title = "Sync failed", .description = "Changes are kept locally.", .route = "library", .icon = .cloud_off, .important = true });
    app.notify(.{ .title = "Update ready", .description = "Restart to apply.", .route = "library" });
    try app.openNoticesPane();
}

const notices_pane_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildNoticesPaneScreen },
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildUnvisited },
};

test "golden: notices pane lists every pending notice" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 360 }, .{ .routes = &notices_pane_routes, .initial_route = "home" });
    defer harness.deinit();
    try renderGolden(&harness, "notices-pane");
}

fn buildCrowdedNoticesPaneScreen(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    try tree.setTitle("Content");
    for ([_][2][]const u8{
        .{ "Settings saved", "This notice stays until dismissed or minimized." },
        .{ "Sync failed", "Changes are kept locally. Open to review them." },
        .{ "Primes counted", "1270607 primes below 20000000." },
        .{ "Payload hashed", "Digest written beside the archive." },
        .{ "Export ready", "The file is in your downloads." },
    }) |n| app.notify(.{ .title = n[0], .description = n[1], .route = "library" });
    try app.openNoticesPane();
}

const crowded_pane_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildCrowdedNoticesPaneScreen },
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildUnvisited },
};

test "golden: a notices pane past its cap scrolls instead of clipping its rows" {
    // A phone on its side. `sheet_min_top` is a far bigger share of 390
    // than of 844, so five notices come to more than the pane may be
    // tall; the rows go in a scroll region and the last visible one is
    // cut by the region's edge with the indicator beside it, rather than
    // drawn past the pane and lost.
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 844, .h = 390 }, .{ .routes = &crowded_pane_routes, .initial_route = "home" });
    defer harness.deinit();
    try renderGolden(&harness, "notices-pane-scrolled");
}

fn buildIndicatorScreen(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("Content");
    try tree.append(root, .{ .text = .{ .content = "Minimized notices wait behind the indicator." } });
    app.notify(.{ .title = "Sync failed", .description = "Changes are kept locally.", .route = "library" });
    app.minimizeNotices();
}

const indicator_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildIndicatorScreen },
    .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildUnvisited },
};

test "golden: minimized notices leave only the indicator" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 300 }, .{ .routes = &indicator_routes, .initial_route = "home" });
    defer harness.deinit();
    try renderGolden(&harness, "notices-minimized");
}

test "golden: the indicator rides at the end of the destinations' row" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 500, .h = 300 }, .{ .routes = &nav_routes, .nav = &nav_items, .initial_route = "library" });
    defer harness.deinit();
    harness.app.notify(.{ .title = "Sync failed", .description = "Changes are kept locally.", .route = "library" });
    harness.app.minimizeNotices();
    // The row is a centered group of its own width, so the indicator
    // travels with it rather than sitting in the corner of a pane
    // nothing draws.
    try renderGolden(&harness, "nav-with-indicator");
}

fn buildBackHome(_: ?*anyopaque, app: *h.App) !void {
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Detail", .route = "detail" } });
}

fn buildBackDetail(_: ?*anyopaque, app: *h.App) !void {
    const root = app.tree.rootId();
    try app.tree.setTitle("Detail");
    try app.tree.append(root, .{ .text = .{ .content = "A pushed screen: the framework installed the back control beside the title." } });
}

test "golden: pushed screen gets back chrome on the title line" {
    const routes = [_]h.RouteDef{
        .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildBackHome },
        .{ .name = "detail", .title = .{ .fixed = "Detail" }, .build = buildBackDetail },
    };
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 200 }, .{ .routes = &routes, .initial_route = "home" });
    defer harness.deinit();
    try harness.app.navigate("detail");
    try renderGolden(&harness, "back-chrome");
}

test "golden: the back gesture past its threshold draws the control engaged" {
    const routes = [_]h.RouteDef{
        .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildBackHome },
        .{ .name = "detail", .title = .{ .fixed = "Detail" }, .build = buildBackDetail },
    };
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 200 }, .{ .routes = &routes, .initial_route = "home" });
    defer harness.deinit();
    try harness.app.navigate("detail");
    // Mid-gesture, past the point of no return: the only thing on screen
    // that a back gesture ever changes. Nothing has slid — this frame and
    // "back-chrome" differ by one glyph (docs/introduction.md).
    try harness.app.dispatch(.{ .edge_pan = .{ .from = .left, .dx = 0, .phase = .begin } });
    try harness.app.dispatch(.{ .edge_pan = .{ .from = .left, .dx = 360, .phase = .move } });
    try renderGolden(&harness, "back-armed");
}

fn buildPersian(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("سلام دنیا");
    // The l10n course's greeting: Arabic script with a ZWNJ join
    // (می‌آید), a Latin acronym mid-sentence, and Latin punctuation —
    // the full reordering surface in one paragraph.
    try tree.append(root, .{ .text = .{ .content = "سلام! این بند از یک کاتالوگ ARB می‌آید که در خود باینری کامپایل شده است." } });
    // Digits take their own LTR runs inside the RTL sentence.
    try tree.append(root, .{ .text = .{ .content = "سال 1404 است و 42 مورد باقی مانده." } });
    try tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "متن " },
        .{ .text = "پررنگ", .strong = true },
        .{ .text = " در میان جمله." },
    } } });
    try tree.append(root, .{ .button = .{ .label = "افزودن مورد" } });
    try tree.append(root, .{ .text_input = .{ .label = "نام", .value = "دریوش" } });
    try tree.append(root, .{ .text = .{ .content = "English keeps its own left-aligned paragraph beside them." } });
}

test "golden: Persian text is shaped, reordered, and right-aligned" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 480 }, .{ .build = buildPersian });
    defer harness.deinit();
    // Focus the input: pins the RTL value at the field's right edge.
    // Focus homes the cursor to the value's end (input.zig), which in
    // RTL is the value's visual *left* — the caret lands there.
    try harness.pressKey(.tab, .{});
    try harness.pressKey(.tab, .{});
    try renderGolden(&harness, "persian");
}

/// Persian digits, which are Arabic *script* and bidi class EN: they
/// need the companion face and they run left to right, and for as long
/// as this renderer has existed it took the first fact for the second
/// and shaped them right-to-left. `۷۴` printed as `۴۷` — a consumer's
/// Persian balance screen showed 47 credits to a reader holding 74,
/// beside an ASCII transaction table that was correct, on every frame of
/// a store submission. Nothing here saw it: the byte-exact tests assert
/// logical strings and pass either way, and the one Persian golden spells
/// its numbers `1404` and `42`.
fn buildPersianDigits(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("ارقام");
    // A bare number, a number after a word, and the ASCII pair whose
    // correctness is what made the Persian one look deliberate.
    try tree.append(root, .{ .text = .{ .content = "۷۴" } });
    try tree.append(root, .{ .text = .{ .content = "۷۴ اعتبار" } });
    try tree.append(root, .{ .text = .{ .content = "مارس ۲۰۲۶" } });
    try tree.append(root, .{ .text = .{ .content = "74 credits" } });
}

test "golden: Persian digits read in the order they were written" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 240 }, .{ .build = buildPersianDigits });
    defer harness.deinit();
    try renderGolden(&harness, "persian-digits");
}

// The same claim without a baseline, and the reason this one is the gate
// rather than the golden beside it: a golden is only as good as the eye
// that reviewed it, and a reversed number is a perfectly plausible
// picture. This asks the question directly instead — which digit is
// drawn first — and answers it in pixels.
//
// The first glyph of a run starts at the pen, so its raster is the same
// whether it was shaped alone or in company; only the glyphs after it
// accumulate advances. So the leading columns of `۲۰۲۶` must be `۲`
// drawn by itself. Reverse the run and they are `۶`. Nothing here
// depends on a screen, a layout or a committed file, and it fails on the
// defect rather than on anything around it.
test "the first digit of a Persian number is the one that was written first" {
    const size = 32;
    const w = 200;
    const hgt = 60;
    const pen = 4;

    var run_surface = try skia.Surface.init(w, hgt, 1);
    defer run_surface.deinit();
    run_surface.canvas().clear(.g0);
    run_surface.canvas().drawText(pen, 40, .prose, size, "۲۰۲۶", .g11);

    var lead_surface = try skia.Surface.init(w, hgt, 1);
    defer lead_surface.deinit();
    lead_surface.canvas().clear(.g0);
    lead_surface.canvas().drawText(pen, 40, .prose, size, "۲", .g11);

    const lead_w: usize = @intCast(pen + skia.measurer().measureRun(.prose, size, "۲"));
    // RGBX, four bytes a pixel, as the surface hands them back.
    const stride = run_surface.pixelWidth() * 4;
    const run_px = run_surface.pixels();
    const lead_px = lead_surface.pixels();
    var inked: usize = 0;
    for (0..run_surface.pixelHeight()) |row| {
        const from = row * stride;
        const cols = lead_w * 4;
        for (run_px[from .. from + cols]) |p| inked += @intFromBool(p != run_px[from]);
        try std.testing.expectEqualSlices(
            u8,
            lead_px[from .. from + cols],
            run_px[from .. from + cols],
        );
    }
    // A blank crop would pass the comparison above and prove nothing.
    try std.testing.expect(inked != 0);
}

fn buildPersianRtl(_: ?*anyopaque, app: *h.App) !void {
    // The same evidence, now with the chrome mirrored (setDirection):
    // labels lead from the right, the toggle knob and track sit at the
    // trailing edge, the tile chevron points back, the tile's leading
    // mark leads from the right with its band, a chip's mark leads from
    // the right without one, the segmented runs right-to-left — while
    // the paragraph still aligns by its own bytes.
    app.setDirection(.rtl);
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.setTitle("تنظیمات");
    try tree.append(root, .{ .text_input = .{ .label = "نام", .value = "دریوش" } });
    try tree.append(root, .{ .toggle = .{ .label = "اعلان‌ها", .on = true } });
    try tree.append(root, .{ .segmented = .{ .label = "نما", .options = &.{ "فهرست", "شبکه" }, .selected = 0 } });
    const group = try tree.appendId(root, .{ .tile_group = .{} });
    try tree.append(group, .{ .tile = .{ .label = "حساب کاربری", .route = "account", .icon = .user } });
    const chips = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(chips, .{ .badge = .{ .label = "استانبول", .icon = .map_pin } });
    try tree.append(chips, .{ .badge = .{ .label = "قهوه", .icon = .sparkles } });
    try tree.append(root, .{ .button = .{ .label = "ذخیره" } });
    try tree.append(root, .{ .text = .{ .content = "English keeps its own left-aligned paragraph beside them." } });
}

const rtl_routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildPersianRtl },
    .{ .name = "account", .title = .{ .fixed = "Account" }, .build = buildUnvisited },
};

test "golden: RTL locale mirrors the chrome; text still aligns by content" {
    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 400, .h = 480 }, .{ .routes = &rtl_routes, .initial_route = "home" });
    defer harness.deinit();
    try renderGolden(&harness, "persian-rtl-chrome");
}

test "trace: PixelSink writes a frame per step, and installs the measurer a device has" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 280 }, .{ .build = buildForm });
    defer harness.deinit();

    var sink = try skia.PixelSink.init(std.testing.io, tmp.dir, std.testing.allocator, "frames");
    sink.take = .{ .format = .ppm };
    try harness.startTrace(sink.observer());

    try harness.pressKey(.tab, .{});
    try harness.typeText("Ada");

    for ([_][]const u8{ "frames/0000-init.ppm", "frames/0001-key-tab.ppm", "frames/0002-type-Ada.ppm" }) |path| {
        const frame = try golden.readPpm(std.testing.io, tmp.dir, std.testing.allocator, path);
        defer frame.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 360), frame.w);
        try std.testing.expectEqual(@as(usize, 280), frame.h);
    }

    // No `setMeasurer` above, deliberately: a take installs the Skia one
    // itself, for `expectGolden`'s reason — the fixed measurer's glyph
    // positions match no device, so a frame laid out with it is a picture
    // of a screen that does not exist.
    try std.testing.expect(harness.app.measurer.measureFn == skia.measurer().measureFn);
}

test "trace: a take carries its scale and its container into the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 280 }, .{ .build = buildForm });
    defer harness.deinit();

    // The hi-DPI knob `Surface.init` always had. A golden pins it at 1
    // and must — a baseline that changed resolution is a different
    // baseline — but nothing compares an inspection frame, so this is
    // free to be 2.
    var sink = try skia.PixelSink.init(std.testing.io, tmp.dir, std.testing.allocator, "frames");
    sink.take = .{ .scale = 2, .format = .ppm };
    try harness.startTrace(sink.observer());

    const frame = try golden.readPpm(std.testing.io, tmp.dir, std.testing.allocator, "frames/0000-init.ppm");
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 720), frame.w);
    try std.testing.expectEqual(@as(usize, 560), frame.h);

    // And the default container, which is the one a CLI agent's image
    // reader can open at all. The bytes are decoded by a decoder that is
    // not the encoder in `tests/capture.zig`; here it is the extension
    // and the header, because what this test owns is the plumbing.
    var png_sink = try skia.PixelSink.init(std.testing.io, tmp.dir, std.testing.allocator, "shots");
    try harness.startTrace(png_sink.observer());
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "shots/0000-init.png", std.testing.allocator, .limited(64 << 20));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }, bytes[0..8]);
    try std.testing.expectEqual(@as(u32, 360), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u8, 2), bytes[25]); // color type 2: RGB
}

test "trace: capture takes one frame of a live app, at a path the caller names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var harness = try h.testing.Harness.init(std.testing.allocator, .{ .w = 360, .h = 280 }, .{ .build = buildForm });
    defer harness.deinit();

    // The engine under the sink, and the one a store-screenshot preset
    // loops over: no numbering, no step, a path the caller owns.
    try skia.capture(std.testing.io, tmp.dir, std.testing.allocator, &harness.app, "shots/sign-in.png", .{ .scale = 3 });
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "shots/sign-in.png", std.testing.allocator, .limited(64 << 20));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u32, 1080), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u32, 840), std.mem.readInt(u32, bytes[20..24], .big));
}

test "a chip's mark costs the same width whatever glyph it is" {
    // The number the badge guidance in elements.md rests on. Every glyph
    // in the bundled icon face advances the same at a given size, so a
    // mark costs a chip exactly `advance + icon_gap` — 20px at the chip's
    // `small` scale — no matter which one it holds. That uniformity is
    // what makes the advice sayable ("a mark adds ~20px, so it earns its
    // width in a row that gets scanned and not on a lone chip"); if the
    // face ever ships a wider glyph the advice needs rewriting, and this
    // is where that shows up rather than in a narrow-screen bug report.
    const m = skia.measurer();
    const expected = h.layout.badgeIconWidth(m, .tag);
    try std.testing.expectEqual(@as(i32, 20), expected);
    for ([_]h.element.IconName{
        .map_pin,     .layout_grid,  .briefcase,      .languages,
        .trophy,      .sparkles,     .heart,          .handshake,
        .shield,      .circle_check, .message_circle, .users,
        .credit_card, .key_round,    .a_arrow_down,   .zoom_out,
    }) |name| {
        try std.testing.expectEqual(expected, h.layout.badgeIconWidth(m, name));
    }
    try std.testing.expectEqual(@as(i32, 0), h.layout.badgeIconWidth(m, null));
}
