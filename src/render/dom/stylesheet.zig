//! The DOM edition's stylesheet, written out of nokre's own source.
//!
//! Every number here that could disagree with the library is read from
//! the library instead: the thirteen grays and both ramps from
//! [color.zig](../../core/color.zig), the six type scales from
//! [text.zig](../../core/text.zig), every padding, radius, target and
//! stroke from [layout.zig](../../core/layout.zig)'s `metrics`, each
//! container's own default gap and padding from the element structs in
//! [element.zig](../../core/element.zig), and the page margin from the
//! root stack in [tree.zig](../../core/tree.zig). Nothing is
//! transcribed, so nothing can drift — which is the only honest way to
//! run an edition that claims to look like the one it is standing
//! beside.
//!
//! Where the reference composes a number rather than naming one — a
//! chip's ink plus its pad, a target centred on a line it is taller
//! than — the composition is written here as the same arithmetic over
//! the same constants, not as the integer it happens to come to. The
//! rule this file follows throughout: **if `renderer.zig` computes it,
//! compute it; if `layout.zig` names it, name it.**
//!
//! Two structural facts about CSS shape most of what follows.
//!
//! - **Custom properties inherit.** A `--pad` set once on the page
//!   reaches every descendant, so a container that reads one has to
//!   *declare* its own default first or it silently adopts its
//!   ancestor's. Every container that spends `--pad` or `--gap` opens
//!   its rule by setting them, and an element field arrives as an
//!   inline style that outranks that declaration.
//! - **`border-box` puts the border inside the box.** The reference
//!   strokes a rect *within* its own bounds (`hsk_stroke_rect` insets by
//!   half the thickness), so a 1px border here is the same pixel the
//!   reference paints — which is also why a padding written beside a
//!   border must be the reference's inset *minus* that border.
//!
//! It is not a styling API and no app may add to it. What a consumer
//! writes is elements; what this file decides is how one is drawn, in
//! exactly the sense `renderer.zig` decides it for the Skia edition.

const std = @import("std");

const class_names = @import("class_names.zig");
const color = @import("../../core/color.zig");
const element = @import("../../core/element.zig");
const layout = @import("../../core/layout.zig");
const text_mod = @import("../../core/text.zig");
const tree_mod = @import("../../core/tree.zig");

const Gray = color.Gray;
const Scale = text_mod.Scale;
const metrics = layout.metrics;
const root_stack = tree_mod.root_stack;

// The root element's two classes, as selectors. Spliced into the sheet
// wherever they appear rather than typed into it, for the reason every
// other number here is read from the library instead of transcribed: a
// host document is handed this same pair through `serialize.rootClass`,
// and a sheet that spelled them itself would be the second statement of
// them the export exists to remove (class_names.zig).
const root_sel = "." ++ class_names.root;
const root_sel_chromed = root_sel ++ "." ++ class_names.has_chrome;

// The attribute test for a page nokre wrote whole, spliced for the same
// reason the classes are: `document.zig` stamps it and this file is the
// only thing that reads it, so the two spellings are one constant or
// they are a rule that silently matches nothing.
const document_sel = class_names.document_attr ++ "=\"" ++ class_names.document_value ++ "\"";

pub const Options = struct {
    /// Where the bundled faces are served from. The edition ships no
    /// font stack and no fallback list: nokre renders in these and
    /// nothing else, and a page that quietly fell back to the system UI
    /// font would be describing a different library.
    fonts: []const u8 = "/assets/fonts",
    /// The faces' file extension. woff2 is what a site should serve —
    /// a TTF over HTTP is the same outlines without the compression —
    /// but a page pointing straight at nokre's bundled binaries says
    /// `.ttf`, and the format hint follows the suffix rather than
    /// being asserted beside it.
    font_suffix: []const u8 = ".woff2",
    /// Emit the `@font-face` block at all. A driver that has already
    /// declared the faces — or that is embedding this sheet in a page
    /// which does — turns it off.
    font_faces: bool = true,
};

pub fn write(gpa: std.mem.Allocator, out: *std.ArrayList(u8), options: Options) !void {
    if (options.font_faces) try writeFaces(gpa, out, options.fonts, options.font_suffix);

    // ---- the palette, both ramps ----
    //
    // Which ramp a page paints in is `App.appearance()`: the app's own
    // `scheme` resolved against what the OS reports (color.zig). A
    // scheme is a consumer API on every other platform, so it is one
    // here — a driver running the app stamps the resolved answer on the
    // document root as `data-appearance`, and the second ramp below
    // hangs off it.
    try out.appendSlice(gpa, "\n:root {\n  color-scheme: light dark;\n");
    try writeRamp(gpa, out, .light, "  ");
    try out.appendSlice(gpa,
        \\  --ink: var(--g2);
        \\  --dark: var(--g3);
        \\  --mid: var(--g5);
        \\  --light: var(--g9);
        \\  --paper: var(--g12);
        \\
    );

    // ---- the metrics, named for the CSS that spends them ----
    //
    // `--pad` and `--gap` are deliberately *absent* from this list. They
    // are the element fields `Stack` and `Box` carry, so they belong to
    // whichever container is being drawn — declared by its own rule and
    // overridden by an inline style — and a page-wide value under those
    // names would be inherited by every nested container that never set
    // one. That was exactly the bug: a stack whose padding is zero drew
    // the page's 16.
    inline for (.{
        .{ "pane", metrics.sheet_max_w },
        // The root stack's own two numbers (tree.zig): the page margin,
        // and the space between two blocks.
        .{ "page-pad", root_stack.padding },
        .{ "page-gap", root_stack.gap },
        .{ "control-gap", metrics.control_gap },
        .{ "border", metrics.border },
        .{ "radius", metrics.radius },
        .{ "radius-card", metrics.radius_card },
        .{ "touch", metrics.touch_target },
        .{ "tap-target", metrics.tap_target },
        .{ "focus", metrics.focus_stroke },
        .{ "focus-clear", metrics.focus_clear },
        .{ "tile-pad-h", metrics.tile_pad_h },
        .{ "tile-pad-v", metrics.tile_pad_v },
        .{ "cell-pad", metrics.cell_pad },
        .{ "list-gap", metrics.list_gap },
        .{ "list-marker-gap", metrics.list_marker_gap },
        .{ "quote-indent", metrics.quote_indent },
        .{ "icon-gap", metrics.icon_gap },
        .{ "icon-glyph", metrics.icon_glyph },
        .{ "badge-pad-h", metrics.badge_pad_h },
        .{ "badge-pad-v", metrics.badge_pad_v },
        .{ "meter-h", metrics.meter_h },
        .{ "seg-pad-h", metrics.seg_pad_h },
        .{ "seg-pad-v", metrics.seg_pad_v },
        .{ "seg-track-pad", metrics.seg_track_pad },
        .{ "seg-scroll-head", metrics.seg_scroll_head },
        .{ "seg-scroll-gutter", metrics.seg_scroll_gutter },
        .{ "button-pad-h", metrics.button_pad_h },
        .{ "button-pad-v", metrics.button_pad_v },
        .{ "input-pad", metrics.input_pad },
        .{ "input-label-gap", metrics.input_label_gap },
        .{ "toggle-w", metrics.toggle_track_w },
        .{ "toggle-h", metrics.toggle_track_h },
        .{ "toggle-inset", metrics.toggle_knob_inset },
        .{ "checkbox", metrics.checkbox_box },
        .{ "radio-glyph", metrics.radio_glyph },
        .{ "radio-dot-inset", metrics.radio_dot_inset },
        .{ "sheet-pad", metrics.sheet_pad },
        // The horizontal split: half the pad inside the pane, the
        // other half outside it (`metrics.sheet_pad_h`'s rationale).
        .{ "sheet-pad-h", metrics.sheet_pad_h },
        .{ "sheet-margin", metrics.sheet_margin },
        .{ "sheet-min-top", metrics.sheet_min_top },
        .{ "notice-pad", metrics.notice_pad },
        .{ "nav-item-pad-h", metrics.nav_item_pad_h },
        .{ "nav-bar-pad", metrics.nav_bar_pad },
        .{ "nav-bar-pad-h", metrics.nav_bar_pad_h },
        .{ "nav-item-gap", metrics.nav_item_gap },
        .{ "nav-bar-pad-b", metrics.nav_bar_pad_b },
        .{ "nav-content-gap", metrics.nav_content_gap },
        // How far the back control's target hangs past the leading
        // edge, so its *glyph* lines up with the text column.
        .{ "back-bleed", layout.back_bleed },
        // The one slot the library grows *past* `touch_target` rather
        // than up to it: its own vertical padding around one line.
        .{ "nav-slot", layout.navItemHeight() },
        // A radio's dot and a toggle's knob: the reference derives both
        // from the ring and the track it sits in, so the derivation is
        // what travels rather than the pixel it lands on.
        .{ "radio-dot", metrics.radio_glyph - 2 * metrics.radio_dot_inset },
        .{ "toggle-knob", metrics.toggle_track_h - 2 * metrics.toggle_knob_inset },
        // A checkbox's corner (`checkbox_box / 4` in `drawCheckbox`) and
        // a radio's, which is the full half — a circle.
        .{ "checkbox-radius", @divTrunc(metrics.checkbox_box, 4) },
    }) |m| {
        try out.print(gpa, "  --{s}: {d}px;\n", .{ m[0], m[1] });
    }

    // A count rather than a length: the rows a `text_area` opens at.
    try out.print(gpa, "  --text-area-rows: {d};\n", .{metrics.text_area_min_rows});

    // The clear space kept below the bar, exactly as `navBarBottomPad`
    // computes it: the OS band counts toward the inset rather than
    // stacking under it, so a home-indicator strip already *is* that
    // clear space and only a desktop window pays the whole 16.
    try out.appendSlice(gpa,
        \\  --safe-b: env(safe-area-inset-bottom, 0px);
        \\  --bar-bottom: max(var(--nav-bar-pad), calc(var(--nav-bar-pad-b) - var(--safe-b)));
        \\
    );

    // …and the whole of the clear space bottom chrome owes the page,
    // named once. It is `trailingSpace` plus `navBarHeight` to the pixel
    // (layout.zig), and it was written out twice in longhand — once for
    // the screen at every width and once inside the band's own block —
    // which is two copies of a five-term sum in a file whose whole point
    // is that a derivation travels rather than the pixel it lands on.
    //
    // Published rather than private, and that is deliberate: a driver
    // that puts something of its own below the app can spend this
    // instead of re-deriving it from the five properties under it. It
    // should not have to — `class_names.seam` is how the seam gets the
    // space without asking — but a name a consumer can read is the
    // difference between a stylesheet that couples to nokre's arithmetic
    // and one that couples to nokre's answer.
    try out.appendSlice(gpa,
        \\  --chrome-reserve: calc(
        \\    var(--nav-content-gap) + var(--nav-bar-pad) + var(--nav-slot) + var(--bar-bottom) + var(--safe-b)
        \\  );
        \\
    );

    // ---- the type scale ----
    inline for (@typeInfo(Scale).@"enum".fields) |f| {
        const s: Scale = @enumFromInt(f.value);
        try out.print(gpa, "  --px-{s}: {d}px;\n  --lh-{s}: {d}px;\n", .{
            f.name, s.px(), f.name, s.lineHeight(),
        });
    }
    try out.appendSlice(gpa, "}\n");

    // ---- the second ramp ----
    // Not an inversion of the first: light-on-dark stems read heavier,
    // so the dark ramp is solved separately as ratios against a true
    // black page (internals/pixel-model.md).
    //
    // It is written under two selectors, from one loop so neither can
    // drift. The media query is all a page with no app behind it — a
    // screen serialized to a file — has to go on. `data-appearance` is
    // core's own answer, and it already *contains* the system's, since
    // that is what `Scheme.auto` resolves through. So the query stands
    // down the moment the attribute appears: an app pinned to light
    // must stay light on a dark desktop, and a media query that kept
    // its say would overrule the very setting the reader chose.
    try out.appendSlice(gpa, "\n@media (prefers-color-scheme: dark) {\n  :root:not([data-appearance]) {\n");
    try writeRamp(gpa, out, .dark, "    ");
    try out.appendSlice(gpa, "  }\n}\n");
    // `color-scheme` narrows to the one appearance too, so the form
    // controls, the scrollbars and the canvas the browser draws on its
    // own account follow the app rather than the desktop.
    try out.appendSlice(gpa, "\n:root[data-appearance=\"light\"] { color-scheme: light; }\n");
    try out.appendSlice(gpa, ":root[data-appearance=\"dark\"] {\n  color-scheme: dark;\n");
    try writeRamp(gpa, out, .dark, "  ");
    try out.appendSlice(gpa, "}\n");

    try out.appendSlice(gpa, sheet);
    try writeDerived(gpa, out);
}

/// The thirteen grays of one appearance, as custom properties. A
/// function rather than an inline loop at each site because the dark
/// ramp is spent under two selectors — the system query and core's own
/// answer — and two hand-written copies of thirteen bytes is exactly
/// the drift this file exists to rule out.
fn writeRamp(gpa: std.mem.Allocator, out: *std.ArrayList(u8), appearance: color.Appearance, indent: []const u8) !void {
    inline for (@typeInfo(Gray).@"enum".fields) |f| {
        const g: Gray = @enumFromInt(f.value);
        const b = g.byte(appearance);
        try out.print(gpa, "{s}--{s}: #{x:0>2}{x:0>2}{x:0>2};\n", .{ indent, f.name, b, b, b });
    }
    // The vendor sign-in pill rides the light ramp's true endpoints
    // whatever the appearance — the reference's pinned pen
    // (renderer.zig) — and flips which endpoint is the fill: Apple's
    // button is black on the light screen and white on the dark one,
    // Google's the reverse (the `.btn.auth` rules in `sheet` spend
    // these crossed). Emitted by the ramp writer so the pair can never
    // drift from the appearance the ramp answers to.
    switch (appearance) {
        .light => try out.print(gpa, "{s}--auth-fill: #000000;\n{s}--auth-ink: #ffffff;\n", .{ indent, indent }),
        .dark => try out.print(gpa, "{s}--auth-fill: #ffffff;\n{s}--auth-ink: #000000;\n", .{ indent, indent }),
    }
}

/// The rules whose *values* are computed rather than named — a mark's
/// codepoint, a breakpoint, and the six placements of the back control.
/// They sit after the static sheet so each is the last word on its
/// selector.
fn writeDerived(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    // The two container defaults, read off the element structs: a stack
    // pads nothing and gaps by `Stack.gap`, a box pads by `Box.padding`.
    // Declared rather than inherited — see the note on custom properties
    // at the top of this file — and outranked by the inline style the
    // serializer writes when the field differs from these.
    const stack: element.Stack = .{};
    const box: element.Box = .{};
    try out.print(gpa,
        \\
        \\.stack {{ --pad: {d}px; --gap: {d}px; }}
        \\.box {{ --pad: {d}px; }}
        \\
    , .{ stack.padding, stack.gap, box.padding });

    // The checked box's mark, from `element.zig` rather than typed out:
    // it is a private-use codepoint in the icon face, and a raw one in
    // the byte stream is at the mercy of whatever decides the sheet's
    // encoding.
    try out.print(
        gpa,
        "\ninput.check::after {{ content: \"\\{x}\"; }}\n",
        .{try std.unicode.utf8Decode(element.checkbox_check)},
    );

    // The phone's width, and the one breakpoint this sheet has. It is
    // the pane cap itself, so it cannot drift from `--pane` above, and
    // what it sorts is a single fact about the reader's window: at and
    // below it a bottom-anchored surface *is* the screen, edge to edge;
    // above it every one of them is a pane standing in a window with
    // room beside it.
    //
    // Both things behind it are that fact spent twice. A banner as wide
    // as the viewport has no side edges to round — the reference squares
    // the corners and drops the side borders there, keeping the boundary
    // on the top hairline alone (`drawPaneChrome`). And the destinations
    // are a band a thumb reaches for rather than a header above the
    // page: `sheet`'s nav block is the header, this is the exception,
    // and every declaration here is one the header's own rule left it to
    // state.
    //
    // **Every roster is in it.** For one release a page with no boot
    // script was held out, on the ground that a band needs a driver to
    // answer a row that will not fit — and what that produced was a
    // reader narrowing their window on a published page and getting no
    // bottom bar, because a fact about the file had been made a term in
    // a question that is the reader's window's alone. The row's answer
    // when it will not fit is below, it needs nobody running, and the
    // chip is what a driver *upgrades* it to rather than what the shape
    // depends on.
    try out.print(gpa, "\n@media (max-width: {d}px) {{\n", .{metrics.sheet_max_w});
    try out.appendSlice(gpa,
        \\  /* No side border left to be part of the inset, so the words
        \\     take the whole pad from the screen edge — which is where
        \\     the reference puts them either way. */
        \\  .notice { border-radius: 0; border-inline: 0; padding-inline: var(--notice-pad); }
        \\
        \\  /* The bar has no ground: no track, no fill, no hairline. The
        \\     nav is its items and nothing else, each on a plate of its
        \\     own, with 8px of page showing between them. */
        \\  .nav {
        \\    position: fixed;
        \\    inset-inline: 0;
        \\    bottom: 0;
        \\    z-index: 2;
        \\    justify-content: center;
        \\    padding-top: var(--nav-bar-pad);
        \\    padding-bottom: calc(var(--bar-bottom) + var(--safe-b));
        \\    /* The layer spans the screen to centre one group in it, so
        \\       it has to let the page through either side of that
        \\       group. */
        \\    pointer-events: none;
        \\  }
        \\  /* A *row* of destinations is measured and centred on the
        \\     viewport as one group, and here it does not wrap. The band
        \\     is a fixed one-line strip over the page and the reserve
        \\     below repeats its height to the pixel, so a second line is
        \\     the page's last line standing behind the destinations.
        \\
        \\     Which leaves the row that will not make a line, and the
        \\     answer is that it scrolls. Not clipping, which is what a
        \\     nowrap row in a fixed layer does left alone — the ends hang
        \\     past both screen edges and no gesture reaches them, and
        \\     that is what a phone got on any page whose roster was
        \\     measured against a wider window than the reader's. Not
        \\     wrapping, for the reserve. A driver still has the better
        \\     answer at this width and takes it — `navCollapses` gives
        \\     the nav its chip, and a chip always fits — but that is an
        \\     upgrade over a shape that already works, not the thing the
        \\     shape depends on. Nothing in this block asks whether
        \\     anything is running.
        \\
        \\     `justify-content` comes off the row for it. A centred
        \\     scroll container overflows *both* ends and the leading one
        \\     is unreachable: the classic way a scrolling row loses its
        \\     first item. The layer above centres the row as a whole
        \\     instead, which is the same picture while it fits — a flex
        \\     item is its content's width — and packs to the start the
        \\     moment it does not. */
        \\  .nav-row {
        \\    flex-wrap: nowrap;
        \\    gap: var(--nav-item-gap);
        \\    pointer-events: auto;
        \\    overflow-x: auto;
        \\    /* One axis non-visible makes the other `auto`. The row is
        \\       exactly its pills' height and the focus ring is drawn
        \\       *inside* the plate (below), so there is nothing here to
        \\       scroll or to clip on that axis. */
        \\    overflow-y: hidden;
        \\    /* A swipe that runs out of strip is not a swipe back
        \\       through the browser's history. */
        \\    overscroll-behavior-inline: contain;
        \\    /* The one thing this answer gives up. A scrollbar in here is
        \\       height, and height in a fixed band is content resting
        \\       behind the bar: the reserve is arithmetic and cannot see
        \\       it, where `.seg-track`'s own gutter is in the page and is
        \\       simply taller. What is left carries it — a pill cut off
        \\       at the screen edge, which is the affordance
        \\       `.seg-track.bled` argues for at its own edge — and a
        \\       browser scrolls a focused destination into view, so the
        \\       keyboard reaches every one of them whatever a pointer
        \\       finds. */
        \\    scrollbar-width: none;
        \\  }
        \\  .nav-row::-webkit-scrollbar { display: none; }
        \\  /* Pills: the corner is half the slot's height, derived rather
        \\     than fixed, so the shape follows the slot instead of
        \\     drifting back to a rounded rectangle the next time the row
        \\     grows. Nothing else in the library is a pill. The pad is
        \\     the reference's, less the border drawn inside it.
        \\
        \\     Three levels: the page, the destinations on .g11, and the
        \\     current route one step above them on .g10, outlined in mid
        \\     and lettered in ink — mid because .g6 is 2.7:1 against
        \\     .g10, under the 1.4.11 floor. The plate is the mark here,
        \\     so the regular face carries the words: bold *and* a fill
        \\     would be two marks for one state. */
        \\  .chip {
        \\    height: var(--nav-slot);
        \\    padding-inline: calc(var(--nav-item-pad-h) - var(--border));
        \\    border: var(--border) solid transparent;
        \\    border-radius: calc(var(--nav-slot) / 2);
        \\    background: var(--g11);
        \\    font-weight: 400;
        \\  }
        \\  .chip.current { background: var(--g10); border-color: var(--mid); }
        \\  /* A plate has an edge of its own, so focus takes it over
        \\     rather than drawing a second line beside it — the rule the
        \\     header leaves to the band (`sheet`, the focus block). It is
        \\     drawn *inside* that edge, which is also what lets the row
        \\     above be a scroll container without clipping a ring. */
        \\  .chip:focus-visible {
        \\    outline: var(--focus) solid var(--ink);
        \\    outline-offset: calc(-1 * var(--focus));
        \\    border-color: transparent;
        \\  }
        \\  /* The section list is the tile group's card, not the modal
        \\     pane's surface: it floats clear of every edge, so all four
        \\     corners are its own and all four are drawn. It is sized to
        \\     its longest row rather than to the pane — a card standing
        \\     on a chip, not a slab across the screen — and its rows sit
        \\     flush inside the 1px edge, exactly as a `tile_group` seats
        \\     its tiles, so the border is the whole of its padding. */
        \\  .picker.above-nav {
        \\    bottom: calc(var(--bar-bottom) + var(--safe-b) + var(--nav-slot) + var(--nav-item-gap));
        \\    width: max-content;
        \\    /* Capped where the chip is capped — the bar's own inset off
        \\       the viewport, not the pane's width: this card stands on
        \\       the bar. */
        \\    max-width: calc(100% - 2 * var(--nav-bar-pad-h));
        \\    max-height: calc(100dvh - var(--sheet-min-top));
        \\    padding: 0;
        \\    /* Centred on the bar's group, which is centred on the
        \\       viewport — so `auto` margins are the whole of it, and
        \\       this layer needs no measured width from anywhere to land
        \\       where `layoutNavMenu` puts it. Aligned to the chip's
        \\       leading edge instead, it would have needed the chip's own
        \\       width, which is a rect, and no rect reaches this
        \\       edition. */
        \\    inset-inline: 0;
        \\    margin-inline: auto;
        \\    /* The pane above gave every picker a bottom edge it did not
        \\       draw, this one floating clear having four. */
        \\    border-bottom: var(--border) solid var(--g6);
        \\    border-radius: var(--radius-card);
        \\  }
        \\}
        \\
    );

    // The back control's vertical placement, per the scale of the line
    // it marks. `layoutRow` centres the 44px target on the *cap region*
    // of that line — caps run about three eighths of the font size above
    // the baseline — which is above the row's own top at every scale,
    // because no line the library sets is as tall as the target. The
    // offset is therefore negative throughout, and the control reaches
    // into the page margin on this axis exactly as it does on the other.
    //
    // Six rules rather than one, because the number is the scale's: an
    // h1 wants -4 where body text wants -11, and a control that used one
    // figure for both sits visibly low under half the screens in an app.
    // A container that draws and insets nothing hands the pairing down
    // to its own first block (`handsDownBack`), so each selector asks
    // about that child too.
    try out.appendSlice(gpa, "\n/* The back control, centred on the cap region of the line it marks. */\n");
    inline for (.{
        .{ "h1", Scale.h1 },
        .{ "h2", Scale.h2 },
        .{ "h3", Scale.h3 },
        .{ "h4", Scale.h4 },
        .{ "h5, p", Scale.body },
        .{ "h6", Scale.small },
    }, .{ "h1", "h2", "h3", "h4", "body", "small" }) |row, scale_name| {
        const s: Scale = row[1];
        const yoff = s.baseline() - @divTrunc(3 * s.px(), 8) - @divTrunc(metrics.touch_target, 2);
        try out.print(
            gpa,
            root_sel ++ " > .icon-button.back:has(+ :is({s}, .s-{s}))," ++
                " " ++ root_sel ++ " > .icon-button.back:has(+ :is(.document, .stack.hands-back) > :first-child:is({s}, .s-{s}))" ++
                " {{ top: calc(var(--page-pad) + {d}px); }}\n",
            .{ row[0], scale_name, row[0], scale_name, yoff },
        );
    }

    // ---- the bottom reserve ------------------------------------------
    //
    // The whole of it, last, so each of these four is the final word on
    // its selector — and in one place, which is the correction. It used
    // to be two rules in the static sheet and one inside the band's
    // media query, three hand-written copies of a question none of them
    // asked the same way.
    //
    // What the reserve is: `trailingSpace` plus `navBarHeight` to the
    // pixel (layout.zig), so nothing may *rest* behind the destinations
    // — a fully scrolled page still leaves the content gap above the
    // bar, the bar's own top pad, its slot, and the clear space below
    // it, with the OS band inside `--bar-bottom` exactly as
    // `navBarBottomPad` puts it there.
    try out.appendSlice(gpa, "\n/* The clear space bottom chrome owes the page, at the four widths it is asked. */\n");
    // Owed: a bottom-anchored layer is on the page at every width.
    // `has-chrome` is one class over three of them (`hasBottomChrome`),
    // so the test is which is present — a notice banner and the bare
    // notices indicator are bottom-anchored whatever the window is.
    try writeReserve(gpa, out, "", "", true);
    // Not owed: a bar standing *above* the page in flow took its space
    // where it stands. The nav is the only layer this can be true of,
    // and it is never on the page beside a banner (`chrome` emits the
    // banner instead of it).
    try writeReserve(gpa, out, "", ":has(.nav)", false);
    // Owed again, at the width the bar is back in the band.
    try out.print(gpa, "\n@media (max-width: {d}px) {{\n", .{metrics.sheet_max_w});
    try writeReserve(gpa, out, "  ", ":has(.nav)", true);
    try out.appendSlice(gpa, "}\n");
    // And not owed on paper, where the nav is `display: none` and a
    // reserve is an inch of nothing at the end of every printout. Both
    // quals, because the second has to outrank the band's rule above:
    // a page box narrower than the pane cap is a paper size, not a
    // phone, and the sheet had been letting the phone's answer win it.
    try out.appendSlice(gpa, "\n@media print {\n");
    try writeReserve(gpa, out, "  ", "", false);
    try writeReserve(gpa, out, "  ", ":has(.nav)", false);
    try out.appendSlice(gpa, "}\n");
}

/// One statement of the bottom reserve, at both of the boxes it can land
/// in. `qual` is what else must be true of `:root` for this to be the
/// answer; `owed` is whether the clear space is owed at all.
///
/// **Two selectors because the last thing in the document is not always
/// the screen.** The reserve is `padding-bottom`, and padding is inside
/// the box it is on — so putting it on the screen reserved the space
/// *above* anything standing below the screen. For an app mounted in a
/// page it did not write there is nothing below the screen this edition
/// may touch, and the screen is right. For a page nokre wrote whole
/// there is: `Document.body_end` is a seam by design, documented as
/// "whatever stands below the app but inside the document", and a
/// driver's footer put there sat under the fixed band at a phone's
/// width on every page it published — the band covered it whole, and
/// the arithmetic could not see it because the arithmetic was inside
/// the wrong box.
///
/// So the space goes at the bottom of whatever *is* last, and the sheet
/// is told which that is rather than guessing: `class_names.seam` on
/// `<body>`, written from the seam's own bytes (`document.zig`). A page
/// with no seam takes the first selector and is what it always was, to
/// the byte; a page with one takes the second, the screen keeps its
/// ordinary page pad above the footer, and the footer gets the clear
/// space it is the last thing before.
///
/// A driver spends nothing for this. `--chrome-reserve` is published
/// beside it for the case no seam can reach, but the seam is the case
/// there was, and a consumer re-deriving five of nokre's custom
/// properties and its breakpoint literal to fix its own footer is the
/// coupling this removes.
fn writeReserve(gpa: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, qual: []const u8, owed: bool) !void {
    // `:root` for the qual because the two mounts are siblings at best
    // and the sheet does not know what a driver wrapped them in: the nav
    // is somewhere in the page, and the page is what every document has.
    // `body` on both sides because it is the one element between the
    // root and the screen in every arrangement either writer makes.
    try out.print(
        gpa,
        "{s}:root{s} body:not(.{s}) " ++ root_sel_chromed ++ " {{ padding-bottom: {s}; }}\n" ++
            "{s}:root{s} body.{s}:has(" ++ root_sel_chromed ++ ") {{ padding-bottom: {s}; }}\n",
        .{
            indent,
            qual,
            class_names.seam,
            // Not the reserve is the page's own pad, which is what the
            // screen's `padding` shorthand already says — restated so
            // this rule is the last word rather than a rule that has to
            // be absent to be right.
            if (owed) "var(--chrome-reserve)" else "var(--pad)",
            indent,
            qual,
            class_names.seam,
            // …and zero for the document, which owes the space only
            // while something is anchored over the bottom of it. The
            // screen keeps its own pad in this branch, so the footer
            // still stands clear of the words above it.
            if (owed) "var(--chrome-reserve)" else "0",
        },
    );
}

fn writeFaces(gpa: std.mem.Allocator, out: *std.ArrayList(u8), dir: []const u8, ext: []const u8) !void {
    // The format hint must match the container or browsers skip the
    // source outright; anything that is neither woff flavor is served as
    // raw TrueType/OpenType.
    const format = if (std.mem.eql(u8, ext, ".woff2"))
        "woff2"
    else if (std.mem.eql(u8, ext, ".woff"))
        "woff"
    else
        "truetype";
    const Face = struct { family: []const u8, style: []const u8, weight: u16, file: []const u8, arabic: bool };
    // The same faces the Skia edition selects by index — mono and prose
    // in four variants each, the icon face, and the Arabic-script
    // companion every family falls back to.
    const faces = [_]Face{
        .{ .family = "prose", .style = "normal", .weight = 400, .file = "prose", .arabic = false },
        .{ .family = "prose", .style = "normal", .weight = 700, .file = "prose-bold", .arabic = false },
        .{ .family = "prose", .style = "italic", .weight = 400, .file = "prose-italic", .arabic = false },
        .{ .family = "prose", .style = "italic", .weight = 700, .file = "prose-bolditalic", .arabic = false },
        .{ .family = "mono", .style = "normal", .weight = 400, .file = "mono", .arabic = false },
        .{ .family = "mono", .style = "normal", .weight = 700, .file = "mono-bold", .arabic = false },
        .{ .family = "mono", .style = "italic", .weight = 400, .file = "mono-italic", .arabic = false },
        .{ .family = "mono", .style = "italic", .weight = 700, .file = "mono-bolditalic", .arabic = false },
        // Core never requests the companion: in the Skia edition any
        // Arabic-script codepoint in a run makes the shim substitute it.
        // `unicode-range` is a browser doing the same substitution, and
        // it carries no italic — the script has no italic tradition, so
        // an italic request resolves to the upright weight. That
        // resolution is what `font-synthesis: none` in the reset below
        // guarantees: without it a browser shears the upright face and
        // invents the variant the bundle deliberately does not ship.
        .{ .family = "prose", .style = "normal", .weight = 400, .file = "arabic", .arabic = true },
        .{ .family = "prose", .style = "normal", .weight = 700, .file = "arabic-bold", .arabic = true },
        .{ .family = "mono", .style = "normal", .weight = 400, .file = "arabic", .arabic = true },
        .{ .family = "mono", .style = "normal", .weight = 700, .file = "arabic-bold", .arabic = true },
    };
    for (faces) |f| {
        try out.print(
            gpa,
            "@font-face {{ font-family: {s}; font-style: {s}; font-weight: {d}; font-display: swap;" ++
                " src: url({s}/{s}{s}) format(\"{s}\"){s}; }}\n",
            .{
                f.family,                                                                                    f.style, f.weight, dir, f.file, ext, format,
                if (f.arabic) "; unicode-range: U+0600-06FF, U+200C-200D, U+FB50-FDFF, U+FE70-FEFF" else "",
            },
        );
    }
    try out.print(
        gpa,
        "@font-face {{ font-family: icons; font-weight: 400; font-display: block;" ++
            " src: url({s}/{s}{s}) format(\"{s}\"); }}\n",
        // The icon face keeps its upstream name where a page points at
        // nokre's own bundle; a site that subset it named it for what
        // it is.
        .{ dir, if (std.mem.eql(u8, ext, ".woff2")) "icons" else "lucide", ext, format },
    );
    // The vendor sign-in marks (LICENSE-Brand.txt). `block` like the
    // icon face: a trademark flashing as fallback tofu is worse than a
    // beat of nothing.
    try out.print(
        gpa,
        "@font-face {{ font-family: brand; font-weight: 400; font-display: block;" ++
            " src: url({s}/brand{s}) format(\"{s}\"); }}\n",
        .{ dir, ext, format },
    );
}

/// The four arc rules, printed at comptime from the one home the
/// trademark colors have (`element.google_g_rgb`): this file no longer
/// holds a color byte of its own, so the stylesheet and the reference
/// renderer cannot disagree about the G.
const google_arc_rules = blk: {
    var s: []const u8 = "";
    for (element.google_g_rgb, 1..) |c, i| {
        if (i > 1) s = s ++ "\n";
        s = s ++ std.fmt.comptimePrint(
            ".btn.auth.google:not(.secondary):not([disabled]) .brand-mark.g > span:nth-child({d}) {{ color: #{x:0>2}{x:0>2}{x:0>2}; }}",
            .{ i, c.r, c.g, c.b },
        );
    }
    break :blk s;
};

const sheet =
    \\
    \\/* ---- reset ------------------------------------------------------ */
    \\
    \\/* A reset here is not tidiness, it is the edition's half of pixel
    \\   determinism. Everything below removes a decision some browser
    \\   makes on the library's behalf and the reference does not make at
    \\   all — a UA margin, a synthesized face, a subpixel-smoothed stem.
    \\   What is left is the tree's own geometry, drawn the same way in
    \\   every engine. */
    \\
    \\*, *::before, *::after { box-sizing: border-box; }
    \\
    \\/* The reference strokes a rect *inside* its own bounds, so a
    \\   border-box border is the same pixel it paints — and a padding
    \\   written beside a border is the reference's inset less that
    \\   border. Every such subtraction below says so where it appears. */
    \\
    \\html {
    \\  -webkit-text-size-adjust: 100%;
    \\  -moz-text-size-adjust: 100%;
    \\  text-size-adjust: 100%;
    \\}
    \\body { margin: 0; }
    \\
    \\/* Nothing nokre draws carries a margin. Spacing between blocks is
    \\   the stack's `gap` and the padding an element declares, both of
    \\   which are fields on the tree — a UA margin is a layout value the
    \\   browser decided on the library's behalf.
    \\
    \\   It is not cosmetic. `hr`'s UA rule includes `margin-inline: auto`,
    \\   and an auto inline margin on a flex item beats `stretch`: the
    \\   divider collapsed to zero width and vanished, taking the UA's
    \\   block margins with it as a gap where a rule should have been.
    \\
    \\   Zero specificity (`:where`), so every rule below still wins —
    \\   the code block's bleed and the panes' centring are margins the
    \\   *edition* chose, which is a different thing. */
++ "\n:where(" ++ root_sel ++ ", .nav, .notice, .notices-pane, .sheet, .picker),\n" ++
    ":where(" ++ root_sel ++ ", .nav, .notice, .notices-pane, .sheet, .picker) :where(*) {\n" ++
    \\  margin: 0;
    \\  padding: 0;
    \\}
    \\
    \\/* A fieldset is the grouping `radio_group` and `segmented` are, and
    \\   a legend is their label — but a legend is not an ordinary child:
    \\   every engine pulls it out of its parent's formatting context and
    \\   into the border, so a flex fieldset's `gap` never reaches it and
    \\   the label sits at a different distance in each browser. Block
    \\   flow with an explicit margin is the arrangement all three agree
    \\   on, which is why neither group lays itself out with flex. */
    \\fieldset { display: block; border: 0; min-width: 0; }
    \\legend { display: block; float: none; }
    \\
    \\/* Form controls inherit the page's type. `font` covers family,
    \\   size, weight and line height; the spacing properties and the
    \\   alignment are separate UA decisions and Safari keeps its own
    \\   unless told otherwise. */
    \\button, input, select, textarea {
    \\  font: inherit;
    \\  color: inherit;
    \\  letter-spacing: inherit;
    \\  word-spacing: inherit;
    \\  text-align: inherit;
    \\  text-transform: inherit;
    \\}
    \\
    \\/* No synthesized faces, ever. The bundle ships real drawn bold and
    \\   italic (core/text.zig), and the Arabic companion ships neither —
    \\   so a browser left to its own devices shears an upright face into
    \\   a fake oblique and smears the stems of a fake bold, which is the
    \\   rasterizer variance the bundling exists to close. */
    \\* { font-synthesis: none; }
    \\
    \\/* Grayscale antialiasing, to match the reference exactly: the shim
    \\   sets `SkFont::Edging::kAntiAlias` and `setSubpixel(false)`, while
    \\   a browser on macOS defaults to subpixel-smoothed text that reads
    \\   a weight heavier than what every other platform draws. */
++ "\n" ++ root_sel ++ ", .nav, .notice, .notices-pane, .sheet, .picker {\n" ++
    \\  -webkit-font-smoothing: antialiased;
    \\  -moz-osx-font-smoothing: grayscale;
    \\}
    \\
    \\/* There is no pressed state in nokre, so there is none to flash:
    \\   the grey wash a mobile browser paints over a tapped control is a
    \\   state the library does not have. */
++ "\n" ++ root_sel ++ ", .nav, .notice, .notices-pane, .sheet, .picker { -webkit-tap-highlight-color: transparent; }\n" ++
    \\
    \\/* A rule the reference draws is a rule: one unbroken line from the
    \\   run's start to its end. `skip-ink` cuts gaps around descenders,
    \\   which is a typographic opinion no draw call here expresses. */
    \\a, s, u, ins, del { text-decoration-skip-ink: none; }
    \\
    \\/* ---- direction --------------------------------------------------- */
    \\
    \\/* Every string takes its base direction from its own first strong
    \\   character, which is what `plaintext` means — UAX #9 P2/P3, the
    \\   rule `bidi.paragraphDirection` implements and every text path in
    \\   the reference runs through, so a Persian paragraph reads right to
    \\   left in an otherwise left-to-right screen without its draw site
    \\   knowing (`Painter.drawText`, `ParagraphCursor`). One rule rather
    \\   than an attribute per emitted element, for the same reason the
    \\   reference put it in the painter rather than at each call.
    \\
    \\   The list is *what holds one of core's strings* — a paragraph, a
    \\   cell, a control's label — and not every element: `plaintext` on
    \\   an inline box isolates it, and core resolves a run and the spans
    \\   inside it as one paragraph, so isolating each `<strong>` would
    \\   reorder a mixed-direction sentence differently from the edition
    \\   standing beside this one. Hence the second rule, which hands the
    \\   decorations back to the paragraph they belong to.
    \\
    \\   A code block is named in neither: its lines do not mirror,
    \\   because a verbatim block is bytes in the order they were
    \\   written (`drawCodeBlock`). */
++ "\n:is(" ++ root_sel ++ ", .nav, .notice, .notices-pane, .sheet, .picker)\n" ++
    \\  :is(p, h1, h2, h3, h4, h5, h6, li, td, th, legend, label, button, a, span,
    \\      input, textarea, select, option) {
    \\  unicode-bidi: plaintext;
    \\}
    \\:is(p, h1, h2, h3, h4, h5, h6) :is(a, span, strong, em, s, code) {
    \\  unicode-bidi: normal;
    \\}
    \\
    \\/* Mirrored chrome (`App.setDirection`) — the rows, the leading
    \\   edges, the nav. Text is not this question and never was; it
    \\   aligns by its content above, which is why an app never has to
    \\   call `setDirection` to get RTL *text* right.
    \\
    \\   The whole sheet is written in logical properties, so this one
    \\   declaration is the mirroring. It is scoped to nokre's own
    \\   surfaces rather than set on the document: the attribute is the
    \\   driver's to stamp, but the page around an embedded app is not
    \\   this edition's to turn around. */
++ "\n:root[data-direction=\"rtl\"] :is(" ++ root_sel ++ ", .nav, .notice, .notices-pane, .sheet, .picker) {\n" ++
    \\  direction: rtl;
    \\}
    \\
    \\/* No transition and no animation, anywhere, ever. Motion is a
    \\   vestibular hazard (WCAG 2.3.3), an untestable intermediate state,
    \\   and a tax on determinism; nokre has none to configure or to
    \\   disable, so there is none here to disable either. The rule is a
    \\   guard, not a preference — which is why it is not behind
    \\   prefers-reduced-motion. */
    \\*, *::before, *::after {
    \\  transition: none !important;
    \\  animation: none !important;
    \\  scroll-behavior: auto !important;
    \\}
    \\
    \\/* There are no :hover rules in this file. Not one. An affordance
    \\   only a pointer can discover is information withheld from touch
    \\   and keyboard users, so the whole category is absent — here as in
    \\   the library. */
    \\
    \\/* ---- the root ---------------------------------------------------- */
    \\
    \\/* The type base, and every surface it has to reach. The chrome
    \\   layers are siblings of the screen rather than children of it —
    \\   a fixed bar inside a scrolling column would scroll — so they
    \\   inherit nothing from it and are named here instead. A page that
    \\   set this on `body` would be styling its host, which an edition
    \\   mounted into someone else's document has no business doing. */
++ "\n" ++ root_sel ++ ", .nav, .notice, .notices-pane, .sheet, .picker {\n" ++
    \\  color: var(--ink);
    \\  font-family: prose;
    \\  font-size: var(--px-body);
    \\  line-height: var(--lh-body);
    \\}
    \\
    \\/* …and the one page where "its host" names nobody. `dom.document`
    \\   writes the doctype, the head and the body, so there is no
    \\   surrounding authority to defer to: the page is nokre's, and it
    \\   says so on the root element (`class_names.document_attr`). The
    \\   live driver never stamps it, so the refusal above is untouched
    \\   for every app mounted in a document it did not write — this is
    \\   the same asymmetry `dir` already has, read the same way.
    \\
    \\   What it turns around is exactly the block above, plus the paper
    \\   under it: a `body_end` footer inherits nokre's ink, family, size
    \\   and measure instead of the browser's default serif, and the band
    \\   of page beside it is `--paper` rather than the UA canvas.
    \\
    \\   And it stops at inheritance, deliberately. A driver's own list
    \\   keeps its markers, its own anchor keeps the UA's underline and
    \\   colour, its own table keeps the UA's borders — those are the
    \\   browser's decisions about markup nokre neither wrote nor has an
    \\   element for, and normalizing them would make this file a second
    \\   stylesheet a consumer has to reason about rather than one block
    \\   that hands a seam the page's type. Every declaration here is
    \\   inherited or paints the page; none of them reaches into a shape
    \\   the driver chose. */
++ "\n:root[" ++ document_sel ++ "] body {\n" ++
    \\  color: var(--ink);
    \\  font-family: prose;
    \\  font-size: var(--px-body);
    \\  line-height: var(--lh-body);
    \\  background: var(--paper);
    \\  -webkit-font-smoothing: antialiased;
    \\  -moz-osx-font-smoothing: grayscale;
    \\  -webkit-tap-highlight-color: transparent;
    \\}
    \\
    \\/* The tree root is a vertical stack; a driver puts `rootClass` on
    \\   whatever it wraps the screen in. Its padding and gap are the root
    \\   stack's own fields, not a page style — `tree.root_stack` is where
    \\   both numbers live. */
++ "\n" ++ root_sel ++ " {\n" ++
    \\  --pad: var(--page-pad);
    \\  --gap: var(--page-gap);
    \\  position: relative;
    \\  display: flex;
    \\  flex-direction: column;
    \\  gap: var(--gap);
    \\  padding: var(--pad);
    \\  background: var(--paper);
    \\}
    \\
    \\/* The bottom reserve is not here. It was, in longhand, with a
    \\   second copy inside the band's own block — so `writeReserve`
    \\   writes all four of its rules together, at the end of this
    \\   file. */
    \\
    \\/* A flex item will not shrink below its own min-content unless it
    \\   is told it may, and a code block's min-content is its longest
    \\   line — which is the thing that is supposed to scroll rather than
    \\   push the pane wider. */
++ "\n" ++ root_sel ++ " > *, .stack > *, .box > *, blockquote > *, li > *, .scroll > * { min-width: 0; }\n" ++
    \\
    \\/* Every surface that scrolls sideways, told the same thing
    \\   directly. A segmented track's min-content is all of its chips
    \\   laid end to end, and a track nested in a fieldset never reached
    \\   the rule above — so the *page* grew to fit the chips, which on a
    \\   phone is a document wider than the screen. Everything downstream
    \\   of that reads as broken: a horizontally scrolled page leaves
    \\   every fixed layer — the nav, a sheet, the scrim — covering the
    \\   viewport it was measured against rather than the part you are
    \\   looking at. */
    \\.seg-track, pre.code, .table-wrap { min-width: 0; max-width: 100%; }
    \\
    \\/* And the page cannot be widened from inside in the first place.
    \\   `clip`, not `hidden`: it establishes no scroll container, so the
    \\   page still scrolls vertically and nothing here becomes a
    \\   containing block for the chrome. What it clips at is the screen
    \\   edge, which is where an element that declines the advised margin
    \\   was told to stop anyway. */
++ "\n" ++ root_sel ++ " { overflow-x: clip; }\n" ++
    \\
    \\/* ---- containers -------------------------------------------------- */
    \\
    \\/* Each opens by declaring the two element fields it spends. Without
    \\   that declaration it would inherit its parent's — custom
    \\   properties do — and a stack whose padding is zero would draw the
    \\   page's margin instead. An inline style carrying the field
    \\   outranks the declaration, which is exactly the precedence
    \\   wanted. */
    \\.stack {
    \\  display: flex;
    \\  flex-direction: column;
    \\  gap: var(--gap);
    \\  padding: var(--pad);
    \\}
    \\/* Rows place children at their intrinsic widths. Which of the two
    \\   things an over-wide one does is `layout.rowOverflow`, asked in the
    \\   serializer so both editions read one answer rather than a selector
    \\   guessing at it: a run of actions folds its tail into the `more`
    \\   control (overflow.zig) and stays on one line, everything else
    \\   wraps. `align-content` because the default stretches the lines
    \\   apart to fill a height the row does not have — they stack at the
    \\   top, one `gap` apart, the way `layoutWrappingRow` stacks them. */
    \\.stack.row { flex-direction: row; flex-wrap: nowrap; align-items: center; }
    \\.stack.row.wrap { flex-wrap: wrap; align-content: flex-start; }
    \\/* And each child takes its own width. `layoutHorizontalFlow` places
    \\   them at `intrinsicSize` — capped at the row's span, never
    \\   *shared* down to fit it — so a row too full overflows rather than
    \\   squeezing every item in it a little. A wrapping row's line breaks
    \\   are the browser's here, and greedy first-fit in core: the same
    \\   rule over the same intrinsic widths, which is as close as the two
    \\   editions get on geometry (renderer-editions.md). */
    \\.stack.row > * { flex: none; max-width: 100%; }
    \\
    \\/* A box groups; it does not decorate. Its edge is a wall — the
    \\   margin advice stops at it, so nothing bleeds across a border.
    \\   Its inner flow gap is the library's, not a field: `layoutBlock`
    \\   flows a box's children at `control_gap` and a box carries no gap
    \\   to override it with. */
    \\.box {
    \\  display: flex;
    \\  flex-direction: column;
    \\  gap: var(--control-gap);
    \\  border: var(--border) solid var(--g10);
    \\  border-radius: var(--radius-card);
    \\  padding: calc(var(--pad) - var(--border));
    \\}
    \\/* Borderless, the padding is the whole inset again. */
    \\.box.bare { border: 0; padding: var(--pad); }
    \\
    \\.document { --pad: 0px; display: flex; flex-direction: column; gap: var(--control-gap); }
    \\.scroll { --pad: 0px; overflow-y: auto; overscroll-behavior: contain; display: flex; flex-direction: column; gap: var(--control-gap); }
    \\
    \\/* ---- type -------------------------------------------------------- */
    \\
    \\/* Every level draws bold, in the family's real bundled bold face —
    \\   which is what keeps h5 and h6 reading as headings beside the
    \\   prose they share a size with. Only three sizes sit above the body,
    \\   so size alone was never going to carry six levels. */
    \\h1, h2, h3, h4, h5, h6 { font-weight: 700; }
    \\h1 { font-size: var(--px-h1); line-height: var(--lh-h1); }
    \\h2 { font-size: var(--px-h2); line-height: var(--lh-h2); }
    \\h3 { font-size: var(--px-h3); line-height: var(--lh-h3); }
    \\h4 { font-size: var(--px-h4); line-height: var(--lh-h4); }
    \\h5 { font-size: var(--px-body); line-height: var(--lh-body); }
    \\h6 { font-size: var(--px-small); line-height: var(--lh-small); }
    \\/* No tracking anywhere in the type, and no margins. The reference
    \\   measures a string with the face's own advances and nothing else,
    \\   so a letter-spacing here would put every wrap point in this
    \\   edition one word away from the other's; spacing between blocks is
    \\   the stack's `gap`, and an element that added its own margin would
    \\   be deciding a layout value the tree already carries. */
    \\
    \\/* Whitespace is content. nokre wraps greedily at spaces and honours
    \\   `\n`, and it measures the string it was given — so a run of
    \\   spaces is a run of spaces and a lone one still owns a line box.
    \\   `normal` collapses all of that: it dropped embedded newlines,
    \\   and it collapsed the single space that gives a swatch its height
    \\   until thirteen shades came out as circles. */
    \\p, h1, h2, h3, h4, h5, h6 { white-space: pre-wrap; }
    \\/* And a word too long for the column overflows rather than
    \\   breaking: `wrap` splits at spaces and lets an unbreakable run
    \\   run on, which is what keeps a URL one selectable token. The page
    \\   clips it at the screen edge, exactly as the reference does. */
    \\p { overflow-wrap: normal; }
    \\strong { font-weight: 700; }
    \\em { font-style: italic; }
    \\/* No bundled family ships a struck variant and synthesizing one
    \\   would reopen the rasterizer variance the bundling exists to
    \\   close, so it is a rule, not a face. */
    \\s { text-decoration-thickness: var(--border); }
    \\/* A span changes the *face*, never the scale: mixed sizes inside a
    \\   line would break the uniform line box, which is why `scale`
    \\   stays element-level in the element set. `font-size: inherit`
    \\   is the one that matters — a UA shrinks `code` to a fraction of
    \\   its parent, and the reference draws it at the run's own size. */
    \\code { font-family: mono; font-size: inherit; }
    \\
    \\.mono { font-family: mono; }
    \\.s-small { font-size: var(--px-small); line-height: var(--lh-small); }
    \\.s-body  { font-size: var(--px-body);  line-height: var(--lh-body); }
    \\.s-h4    { font-size: var(--px-h4);    line-height: var(--lh-h4); }
    \\.s-h3    { font-size: var(--px-h3);    line-height: var(--lh-h3); }
    \\.s-h2    { font-size: var(--px-h2);    line-height: var(--lh-h2); }
    \\.s-h1    { font-size: var(--px-h1);    line-height: var(--lh-h1); }
    \\
    \\.g0 { color: var(--g0); } .g1 { color: var(--g1); } .g2 { color: var(--g2); }
    \\.g3 { color: var(--g3); } .g4 { color: var(--g4); } .g5 { color: var(--g5); }
    \\.g6 { color: var(--g6); } .g7 { color: var(--g7); } .g8 { color: var(--g8); }
    \\.g9 { color: var(--g9); } .g10 { color: var(--g10); } .g11 { color: var(--g11); }
    \\.g12 { color: var(--g12); }
    \\
    \\/* Whitespace preserved, never reflowed: a wrapped code line lies
    \\   about where the code breaks and re-indents the one after it. It
    \\   draws no fill and no border — a frame would be decoration, and
    \\   would move the text onto a surface the contrast gate then has to
    \\   re-prove. Wider than its parent it declines the advised margin
    \\   and bleeds to the nearest drawn edge, then scrolls — while the
    \\   margin comes back as a content inset, so its lines stay aligned
    \\   with the prose around them.
    \\
    \\   `--bleed` is `CodeBlock.bleed`, which layout wrote after
    \\   accumulating `Ctx.margin` down the tree: zero for a block that
    \\   fits, and the whole advice for one that does not. It arrives as
    \\   an inline style rather than a cascade, because the accumulation
    \\   is a walk and CSS has no way to run one — a custom property that
    \\   added its own parent's value to itself is a cycle, and a cycle
    \\   resolves to nothing at all. */
    \\pre.code {
    \\  font-family: mono;
    \\  font-size: var(--px-body);
    \\  line-height: var(--lh-body);
    \\  white-space: pre;
    \\  overflow-x: auto;
    \\  /* One axis, and the other is not its business. Left at `visible`,
    \\     CSS promotes it to `auto` and the block eats the page's
    \\     vertical scroll. */
    \\  overflow-y: hidden;
    \\  margin-inline: calc(-1 * var(--bleed, 0px));
    \\  padding-inline: var(--bleed, 0px);
    \\  scrollbar-width: thin;
    \\  scrollbar-color: var(--g9) transparent;
    \\}
    \\
    \\/* The 2px indicator that rides the bottom of anything overflowing
    \\   horizontally, in the scroll_region pattern: quiet at rest, and
    \\   never fading on a timer, because a bar that vanishes takes the
    \\   only sign the content scrolls with it. */
    \\pre.code::-webkit-scrollbar, .table-wrap::-webkit-scrollbar, .seg-track::-webkit-scrollbar { height: 2px; }
    \\pre.code::-webkit-scrollbar-track, .table-wrap::-webkit-scrollbar-track, .seg-track::-webkit-scrollbar-track { background: transparent; }
    \\pre.code::-webkit-scrollbar-thumb, .table-wrap::-webkit-scrollbar-thumb, .seg-track::-webkit-scrollbar-thumb { background: var(--g9); }
    \\
    \\/* The 1px rule is the grouping tone, not the state carrier: a quote
    \\   is structure and never state. It draws an edge, so unlike a list
    \\   it consumes the advised margin — nothing bleeds across it. The
    \\   band is `quote_indent` measured from the quote's own edge, and
    \\   the rule is drawn *inside* that band, so the padding is the
    \\   indent less the rule. */
    \\blockquote {
    \\  display: flex;
    \\  flex-direction: column;
    \\  gap: var(--control-gap);
    \\  border-inline-start: var(--border) solid var(--g10);
    \\  padding-inline-start: calc(var(--quote-indent) - var(--border));
    \\}
    \\
    \\/* Items flow tighter than free-standing blocks: one run of prose
    \\   broken into pieces, not separate thoughts. A list draws no edge,
    \\   so the margin advice passes through it.
    \\
    \\   `--list-gutter` is layout's own `listGutter` — the widest marker
    \\   in the list plus the gap after it — written onto the element by
    \\   the serializer, because it is a *measured* width and no constant
    \\   can stand in for it. Uniform across the list, so item words align
    \\   down one column however the ordinals grow. */
    \\ul.list, ol.list {
    \\  --pad: 0px;
    \\  display: flex;
    \\  flex-direction: column;
    \\  gap: var(--list-gap);
    \\  padding-inline-start: var(--list-gutter, calc(var(--quote-indent) + var(--list-marker-gap)));
    \\}
    \\ul.list { list-style: disc; }
    \\ol.list { list-style: decimal; }
    \\li { display: list-item; }
    \\li::marker { color: var(--ink); }
    \\li > ul.list, li > ol.list { margin-top: var(--list-gap); }
    \\
    \\/* shadcn tables: the grid is horizontal separators only — no outer
    \\   border and no vertical rules, one hairline above every row but
    \\   the first, spanning the table's whole width. Column widths are
    \\   per-column intrinsic maxima, which is what `auto` layout already
    \\   computes. */
    \\/* No bleed: `layoutTable` never takes the advised margin. A table
    \\   is an intrinsic-width block on the leading edge, and one too wide
    \\   for its column scrolls where it stands. */
    \\.table-wrap {
    \\  overflow-x: auto;
    \\  overflow-y: hidden;
    \\  scrollbar-width: thin;
    \\  scrollbar-color: var(--g9) transparent;
    \\}
    \\table { border-collapse: collapse; }
    \\th, td { border: 0; padding: var(--cell-pad); text-align: start; vertical-align: top; }
    \\tr + tr > th, tr + tr > td { border-top: var(--border) solid var(--g10); }
    \\/* A cell is a flow of its own, with the tighter gap layout gives it
    \\   (`layoutTable` flows cell children at 4px). A table cell cannot
    \\   be a flex container without leaving the table formatting context,
    \\   so the gap is spent as a margin between siblings instead. */
    \\th > * + *, td > * + * { margin-top: 4px; }
    \\/* A header row is marked by tone, not by weight: the reference
    \\   swaps the row's text ink to `mid` and changes nothing else. */
    \\th { font-weight: 400; color: var(--mid); }
    \\
    \\hr { border: 0; border-top: var(--border) solid var(--g10); }
    \\
    \\/* Where color-coded chips carry state by hue elsewhere, here the
    \\   words carry it — so the border is grouping and draws .g10, not
    \\   the .g6 the state carriers use. */
    \\.badge {
    \\  display: inline-flex;
    \\  align-self: flex-start;
    \\  align-items: center;
    \\  gap: var(--icon-gap);
    \\  font-size: var(--px-small);
    \\  line-height: var(--lh-small);
    \\  padding: var(--badge-pad-v) var(--badge-pad-h);
    \\  border: var(--border) solid var(--g10);
    \\  border-radius: var(--radius);
    \\}
    \\
    \\/* The track is a pill — its corner is half its height, derived
    \\   rather than chosen — and the fill sits *inside* the boundary,
    \\   one border in on every side, with the corner it has room for.
    \\   The border alone is that inset: `border-box` already holds the
    \\   fill off by it, so a padding here would inset it twice. */
    \\.meter { display: flex; flex-direction: column; gap: var(--input-label-gap); }
    \\.meter-track {
    \\  height: var(--meter-h);
    \\  background: var(--g11);
    \\  border: var(--border) solid var(--g6);
    \\  border-radius: calc(var(--meter-h) / 2);
    \\}
    \\.meter-fill {
    \\  height: 100%;
    \\  background: var(--ink);
    \\  border-radius: calc(var(--meter-h) / 2 - var(--border));
    \\}
    \\
    \\/* Label above, code below — the order `drawQr` draws them in, the
    \\   labeled-field shape every element with a caption takes. The
    \\   square's side is layout's `qrSide`: whole pixels per module, so
    \\   the serializer writes it and CSS never scales it to a fraction,
    \\   which is what stops a symbol scanning. */
    \\.qr { display: flex; flex-direction: column; gap: var(--input-label-gap); align-items: flex-start; }
    \\.qr svg { max-width: 100%; height: auto; }
    \\
    \\/* One line-height tall, so it aligns with same-scale text beside
    \\   it: the glyph is drawn at the scale's size and centred in that
    \\   box rather than standing on the baseline like a letter. `1lh` is
    \\   the element's own line height, which the scale classes set.
    \\
    \\   Its *width* is the glyph's advance and nothing more. A mark
    \\   inside a control costs exactly that plus `icon_gap` everywhere
    \\   the library measures one — `navItemWidth`, `intrinsicSize`'s
    \\   button arm, `navChipWidth` — so a square box here would be
    \\   wider than the width core measured the control at. That gap does
    \\   not show as a stretched pill; it shows in every decision made
    \\   against a measured width, and the nav's row is where it showed
    \\   worst: eight pixels a destination, so the roster ran past both
    \\   screen edges before `navCollapses` agreed it no longer fitted. */
    \\.icon {
    \\  font-family: icons;
    \\  font-style: normal;
    \\  font-weight: 400;
    \\  display: inline-flex;
    \\  align-items: center;
    \\  justify-content: center;
    \\  flex: none;
    \\  height: 1lh;
    \\  vertical-align: bottom;
    \\}
    \\/* The `icon` *element* is the exception, and the only one:
    \\   `intrinsicSize` gives it a `lineHeight` box on both axes, because
    \\   standing on its own it is a block in the flow rather than a mark
    \\   in a run. */
    \\.icon.square { width: 1lh; }
    \\
    \\/* ---- links and controls ------------------------------------------ */
    \\
    \\/* Underlined, always: a link nobody can see is a link only a
    \\   pointer finds, and there is no pointer state to find it with.
    \\   Inside a paragraph that underline is the browser's, drawn along
    \\   whatever lines the run happens to occupy. */
    \\a.link { color: inherit; text-decoration: underline; text-underline-offset: 2px; text-decoration-thickness: var(--border); }
    \\
    \\/* A `link` element is not a run inside a paragraph: it is a block of
    \\   its own, one line tall with the rule on the last of the two
    \\   pixels below it — which is exactly what `intrinsicSize` reserves
    \\   ("room for the underline") and `drawNode` then draws. A border is
    \\   how that lands on the pixel the reference picks, where a text
    \\   decoration would land wherever the face's own underline metric
    \\   says. The 24px floor is the WCAG 2.5.8 target a bare word has to
    \\   clear. */
    \\a.link.block {
    \\  align-self: flex-start;
    \\  display: inline-block;
    \\  min-width: var(--tap-target);
    \\  white-space: nowrap;
    \\  text-decoration: none;
    \\  padding-bottom: calc(2px - var(--border));
    \\  border-bottom: var(--border) solid currentColor;
    \\}
    \\
    \\.btn {
    \\  align-self: flex-start;
    \\  display: inline-flex;
    \\  align-items: center;
    \\  gap: var(--icon-gap);
    \\  /* Body line height plus the pad is 36, and the reference says so
    \\     in as many words. The 44px target is for a control that is
    \\     *nothing but* a target — the bare glyph below — not for a pill
    \\     with words in it, which clears the 24px floor on its own. */
    \\  padding: var(--button-pad-v) var(--button-pad-h);
    \\  border: var(--border) solid transparent;
    \\  border-radius: var(--radius);
    \\  background: var(--ink);
    \\  color: var(--paper);
    \\}
    \\/* An outline is the boundary a state carrier draws, so it is `.g6`,
    \\   the same tone every compact control's edge takes. */
    \\.btn.secondary { background: transparent; color: var(--ink); border-color: var(--g6); }
    \\/* Disabled is the one place a tone may dim: 1.4.11 exempts inactive
    \\   components. The filled pill drops to `.g6` under `.g11` words;
    \\   the outlined one gives up the state carrier for the grouping
    \\   tone, because an inactive control states nothing. */
    \\.btn[disabled] { background: var(--g6); color: var(--g11); border-color: transparent; }
    \\.btn.secondary[disabled] { background: transparent; color: var(--g6); border-color: var(--g10); }
    \\/* No pill. An icon-only button is the glyph and the target it
    \\   stands on — the reference draws the mark and nothing else, at
    \\   Lucide's own 24px design grid so the strokes land on whole
    \\   pixels, centred in a 44px square. */
    \\.btn.icon-only {
    \\  width: var(--touch);
    \\  height: var(--touch);
    \\  padding: 0;
    \\  justify-content: center;
    \\  background: transparent;
    \\  border-color: transparent;
    \\  color: var(--ink);
    \\}
    \\.btn.icon-only[disabled] { background: transparent; color: var(--g6); }
    \\
    \\/* A vendor sign-in pill rides the light ramp's true endpoints, not
    \\   the softened aliases — the reference draws it through a pinned
    \\   pen (renderer.zig), and `--auth-fill`/`--auth-ink` are that pin,
    \\   flipping with the appearance so the dark screen gets Apple's
    \\   white button. `secondary` is exempt: the outlined third style is
    \\   the ordinary outlined pill. Disabled is exempt too — an inactive
    \\   control dims into the palette like any other. */
    \\.btn.auth:not(.secondary):not([disabled]) { background: var(--auth-fill); color: var(--auth-ink); }
    \\/* Google's themes cross the pin — white pill on the light screen,
    \\   near-black on the dark — with the hairline border its light
    \\   button carries. The border byte is the mid gray of the *light*
    \\   ramp on both themes, exactly the pinned `.g6` stroke the
    \\   reference draws. */
    \\.btn.auth.google:not(.secondary):not([disabled]) {
    \\  background: var(--auth-ink);
    \\  color: var(--auth-fill);
    \\  border-color: #808080;
    \\}
    \\
    \\/* The mark that leads a sign-in label: brand-face glyphs standing
    \\   on the text baseline at cap height, the way the vendor's own
    \\   button art relates the logo to the words — an icon centres in
    \\   its em box instead, because an icon is not a letter. */
    \\.brand-mark { font-family: brand; font-weight: 400; font-style: normal; }
    \\/* Google's G: four arc glyphs on one advance, overlaid by the grid
    \\   into one drawing. The colors are the vendor's trademark spec —
    \\   the ONLY color literals in this stylesheet, printed from the one
    \\   table both editions read (`element.google_g_rgb`) — and they
    \\   apply only on the live branded pill: a dimmed button's G falls
    \\   back to currentColor and reads as a silhouette, like the
    \\   reference. */
    \\.brand-mark.g { display: inline-grid; }
    \\.brand-mark.g > span { grid-area: 1 / 1; }
++ "\n" ++ google_arc_rules ++ "\n" ++
    \\
    \\/* A percentage fills the pill as the work goes. On a filled button
    \\   the track is `.g7` — already clear of the ground it sits on —
    \\   and the fill is paper; on an outlined one it is the dim `.g11`
    \\   track with the boundary stroke a standalone meter carries, and
    \\   the fill is ink. */
    \\.btn { position: relative; }
    \\/* In flow, taking the width layout measured; hidden, because what
    \\   stands in its place is drawn over it. */
    \\.btn-strut { visibility: hidden; }
    \\.btn-wait { position: absolute; inset: 0; display: grid; place-content: center; }
    \\.btn-track {
    \\  position: absolute;
    \\  inset: 0 var(--button-pad-h);
    \\  margin-block: auto;
    \\  height: var(--meter-h);
    \\  border-radius: calc(var(--meter-h) / 2);
    \\  background: var(--g7);
    \\}
    \\.btn-fill { display: block; height: 100%; border-radius: calc(var(--meter-h) / 2 - var(--border)); background: var(--paper); }
    \\.btn.secondary .btn-track { background: var(--g11); border: var(--border) solid var(--g6); }
    \\.btn.secondary .btn-fill { background: var(--ink); }
    \\
    \\/* A bordered vertical group of tappable rows: 44px rows, one
    \\   hairline between them, the border pure grouping. */
    \\.tiles { border: var(--border) solid var(--g10); border-radius: var(--radius-card); overflow: hidden; }
    \\.tile {
    \\  display: flex;
    \\  align-items: center;
    \\  gap: var(--icon-gap);
    \\  width: 100%;
    \\  padding: var(--tile-pad-v) var(--tile-pad-h);
    \\  border: 0;
    \\  border-top: var(--border) solid var(--g10);
    \\  background: transparent;
    \\  color: inherit;
    \\  text-align: start;
    \\  text-decoration: none;
    \\}
    \\.tiles > *:first-child, .tiles > *:first-child .tile { border-top: 0; }
    \\.tile-text { display: flex; flex-direction: column; flex: 1; min-width: 0; }
    \\/* Body prose in ink, in the regular face: the row is a
    \\   destination, not a heading. */
    \\.tile-label { font-weight: 400; }
    \\.tile-detail, .tiles-desc { font-size: var(--px-small); line-height: var(--lh-small); color: var(--dark); }
    \\/* The caption hangs below the group's border at the labeled-field
    \\   gap, not the stack's — `tileGroupDescHeight` spends
    \\   `input_label_gap` on it — so the two are wrapped and spaced
    \\   together rather than left to the page's flow. */
    \\.tile-group { display: flex; flex-direction: column; gap: var(--input-label-gap); }
    \\
    \\/* The row is the control and the row is the target: 44px tall,
    \\   as wide as the control plus its words and no wider. */
    \\.ctl {
    \\  display: flex;
    \\  align-self: flex-start;
    \\  align-items: center;
    \\  gap: var(--control-gap);
    \\  min-height: var(--touch);
    \\}
    \\.ctl-label { flex: none; }
    \\/* Two of them stacked collapse against each other: a row already
    \\   carries `(touch_target - lineHeight) / 2` of clear space above
    \\   and below, and spending the stack's gap on top of that is three
    \\   gaps' worth of air for what reads as one (`selfPadded`). Only
    \\   between two of them — a pill or a field beside one is a
    \\   different weight and keeps the full gap. */
    \\.ctl + .ctl { margin-top: calc(-1 * var(--gap, var(--page-gap))); }
    \\
    \\/* The box, the ring and the track are *drawings of state*; the row
    \\   is the control. So no press ever lands on one of them.
    \\
    \\   This is not tidiness. A checkbox flips itself *before* the click
    \\   event is dispatched and un-flips itself *after* every listener
    \\   has run — so a driver that toggles the tree during the event and
    \\   writes the answer back finds the browser undoing it a moment
    \\   later, and the control sits one press behind for good. Cancelling
    \\   the press on the row stops the activation before it starts, which
    \\   is the only version of this with no race in it. Keyboard focus is
    \\   untouched: Tab still reaches them, and Space goes through core
    \\   like every other key. */
    \\input.check, input.toggle, .radios input[type="radio"], .seg input { pointer-events: none; }
    \\
    \\/* The compact controls keep their borders at .g6: they sit against
    \\   the .g11 track, where .g7 falls to 2.5:1. */
    \\input.check {
    \\  appearance: none;
    \\  width: var(--checkbox);
    \\  height: var(--checkbox);
    \\  flex: none;
    \\  background: var(--g11);
    \\  border: var(--border) solid var(--g6);
    \\  border-radius: var(--checkbox-radius);
    \\  display: grid;
    \\  place-content: center;
    \\}
    \\/* The mark is drawn at the body size, like every other glyph that
    \\   sits beside words rather than standing alone.
    \\
    \\   It centres by *text* metrics — centred alignment on a line as
    \\   tall as the box's inside — not by the grid alignment above:
    \\   engines lay an <input>'s pseudo-element out with the control's
    \\   own inner layout, and Chrome stretches it across the box and
    \\   starts its line at the inline edge, which put the check visibly
    \\   left of centre. The glyph's ink is centred in its advance (per
    \\   the outline points — the glyf bboxes are wrong, the note on
    \\   `inkCenterBaseline` in renderer.zig), so centring the advance
    \\   centres the mark, exactly as `drawCheckbox` centres the
    \\   measured advance. Both rules hold in an engine that *does* run
    \\   the grid: there the item is already the advance wide and the
    \\   line already fills the track, and both declarations are
    \\   no-ops. */
    \\input.check::after {
    \\  font-family: icons;
    \\  font-size: var(--px-body);
    \\  line-height: calc(var(--checkbox) - 2 * var(--border));
    \\  text-align: center;
    \\  color: var(--paper);
    \\  visibility: hidden;
    \\}
    \\input.check:checked { background: var(--ink); border-color: var(--ink); }
    \\input.check:checked::after { visibility: visible; }
    \\
    \\/* The knob is the track less its inset on both sides, and it sits
    \\   at that inset from the track's edge — the border is drawn *on*
    \\   the track rather than added to it, so the padding here is the
    \\   inset less the border `border-box` already spent. */
    \\input.toggle {
    \\  appearance: none;
    \\  width: var(--toggle-w);
    \\  height: var(--toggle-h);
    \\  flex: none;
    \\  display: flex;
    \\  align-items: center;
    \\  padding: calc(var(--toggle-inset) - var(--border));
    \\  border: var(--border) solid var(--g6);
    \\  border-radius: calc(var(--toggle-h) / 2);
    \\  background: var(--g11);
    \\}
    \\input.toggle::after {
    \\  content: "";
    \\  width: var(--toggle-knob);
    \\  aspect-ratio: 1;
    \\  border-radius: 50%;
    \\  /* Off, the knob is paper carrying the same state edge the track
    \\     does; on, the track is ink and the knob needs no boundary of
    \\     its own against it. */
    \\  background: var(--paper);
    \\  border: var(--border) solid var(--g6);
    \\}
    \\input.toggle:checked { background: var(--ink); border-color: var(--ink); }
    \\input.toggle:checked::after { border-color: transparent; margin-inline-start: auto; }
    \\
    \\/* Work in flight: the track or the box stands down for `…` in the
    \\   slot it occupied — the reference's `drawControlWait`. The input
    \\   keeps its box, because the row must not resize when the flip
    \\   starts or when the result lands, and it keeps being the control:
    \\   the role, the value and aria-busy all ride on it, and only its
    \\   *drawing* steps aside. Undoing that drawing is a list of denials
    \\   because the two controls state so much (the knob is a sized flex
    \\   item, the check a glyph in the icon face); the rules win on
    \\   specificity and on order alike. No dimming — busy is not
    \\   unavailable, and the mark is the only sign the work is happening. */
    \\.ctl.busy input { background: none; border-color: transparent; padding: 0; }
    \\.ctl.busy input::after {
    \\  content: "\2026";
    \\  visibility: visible;
    \\  width: 100%;
    \\  aspect-ratio: auto;
    \\  margin-inline-start: 0;
    \\  background: none;
    \\  border: 0;
    \\  border-radius: 0;
    \\  font-family: prose;
    \\  font-size: var(--px-body);
    \\  line-height: 1;
    \\  text-align: center;
    \\  color: var(--ink);
    \\}
    \\
    \\/* A column of tile rows under a label, in the tile group's shape.
    \\   Block flow, not flex: the legend is the label and no engine puts
    \\   a legend in its parent's flex line (see the reset). */
    \\.radios > .tiles { margin-top: var(--input-label-gap); }
    \\.radios input[type="radio"] {
    \\  appearance: none;
    \\  width: var(--radio-glyph);
    \\  height: var(--radio-glyph);
    \\  flex: none;
    \\  border: var(--border) solid var(--g6);
    \\  border-radius: 50%;
    \\  display: grid;
    \\  place-content: center;
    \\}
    \\/* Selected is a filled ring with a paper centre — not an ink dot on
    \\   bare ground: `drawRadioGroup` fills the whole glyph and insets
    \\   the dot out of it, so the state is the ring, and the dot is what
    \\   is left of the ground. */
    \\.radios input[type="radio"]:checked { background: var(--ink); border-color: var(--ink); }
    \\.radios input[type="radio"]:checked::after {
    \\  content: "";
    \\  width: var(--radio-dot);
    \\  height: var(--radio-dot);
    \\  border-radius: 50%;
    \\  background: var(--paper);
    \\}
    \\
    \\/* Track and chip: the track fills .g11, the selected option is an
    \\   elevated .paper chip with an .ink label and a .g6 border — the
    \\   border is what carries WCAG 1.4.11, since paper on the track
    \\   alone is ~1.3:1. Chips sit end to end with no gap between them;
    \\   `segContentWidth` sums their widths and nothing else. */
    \\.seg-track {
    \\  display: flex;
    \\  gap: 0;
    \\  padding: var(--seg-track-pad);
    \\  background: var(--g11);
    \\  border-radius: var(--radius);
    \\  width: max-content;
    \\  max-width: 100%;
    \\  overflow-x: auto;
    \\  overflow-y: hidden;
    \\  scrollbar-width: thin;
    \\}
    \\/* A track wider than its column declines the advised margin and
    \\   reaches the nearest drawn edge, so its chips clip at the screen
    \\   rather than mid-page — and the corners square off there, because
    \\   the band continues past the edge instead of rounding against
    \\   nothing (`drawSegmented` fills at radius 0 for the same reason).
    \\   The margin comes straight back as content padding, so a resting
    \\   chip stays aligned with the prose above it and the space the
    \\   offset travels through is the unbled track's.
    \\
    \\   `--bleed` is `Segmented.bleed`, which layout wrote: zero for a
    \\   track that fits, and zero for one boxed in with no clear path to
    \\   an edge, so the class is on the element only when core decided
    \\   both that the chips overflow and that there is somewhere to
    \\   overflow to. CSS cannot ask either question — it can see neither
    \\   the measured content width nor how far the advice accumulated —
    \\   which is why the answer arrives from the tree.
    \\
    \\   `max-width` has to be released as well as `width` set: it
    \\   resolves against the containing block, so the cap from the rule
    \\   above would take back exactly what the negative margin bought. */
    \\.seg-track.bled {
    \\  width: auto;
    \\  max-width: none;
    \\  border-radius: 0;
    \\  margin-inline: calc(-1 * var(--bleed));
    \\  padding-inline: calc(var(--bleed) + var(--seg-track-pad));
    \\  /* Scrolling costs height, exactly as it does in `layoutBlock`:
    \\     the scroll affordance gets its own strip below the chips
    \\     rather than the 2px track pad they already stand on, and the
    \\     chips keep some of it above them — otherwise a track that
    \\     scrolls reads tighter than the same track when it fits. */
    \\  padding-block:
    \\    calc(var(--seg-track-pad) + var(--seg-scroll-head))
    \\    calc(var(--seg-track-pad) + var(--seg-scroll-gutter));
    \\}
    \\.seg { flex: none; }
    \\.seg input { position: absolute; opacity: 0; }
    \\.seg span {
    \\  display: flex;
    \\  align-items: center;
    \\  /* The chip is the track less its pad on both sides: body line
    \\     height plus the chip's own, and the border is drawn *on* that
    \\     box rather than added to it. The track is then 36. */
    \\  height: calc(var(--lh-body) + 2 * var(--seg-pad-v));
    \\  padding-inline: calc(var(--seg-pad-h) - var(--border));
    \\  border: var(--border) solid transparent;
    \\  /* The chip's corner is the track's, less the pad it sits in. */
    \\  border-radius: calc(var(--radius) - var(--seg-track-pad));
    \\  color: var(--dark);
    \\  white-space: nowrap;
    \\}
    \\.seg input:checked + span { background: var(--paper); border-color: var(--g6); color: var(--ink); }
    \\
    \\/* The labelled fields outline in .g7: their borders run the full
    \\   width of the pane, where a heavier tone reads as a box rather
    \\   than a hairline. */
    \\.field { display: flex; flex-direction: column; gap: var(--input-label-gap); }
    \\/* Small scale, but full ink: it is the field's name, and the
    \\   library dims the *detail* lines, never the labels. */
    \\.field-label { font-size: var(--px-small); line-height: var(--lh-small); color: var(--ink); }
    \\/* A field is sized by what it holds, not by the 44px target: one
    \\   line of body text inside its own pad and border, which is the
    \\   36px `labeledFieldHeight` computes. The big target belongs to a
    \\   control that is *nothing but* a target — a bare glyph — and a
    \\   field derived from text clears the 24px floor on its own. */
    \\.field-box {
    \\  display: flex;
    \\  align-items: center;
    \\  gap: var(--icon-gap);
    \\  width: 100%;
    \\  padding: var(--input-pad);
    \\  border: var(--border) solid var(--g7);
    \\  border-radius: var(--radius);
    \\  background: transparent;
    \\  text-align: start;
    \\}
    \\.field-box input, .field-box textarea { flex: 1; min-width: 0; border: 0; padding: 0; background: transparent; appearance: none; }
    \\.field-value { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    \\.field-box input:focus, .field-box textarea:focus { outline: none; }
    \\/* `text_area_min_rows` of body text — the field's own pad is the
    \\   box's, so the control inside it is exactly the rows. */
    \\.field-box textarea { resize: vertical; height: calc(var(--text-area-rows) * var(--lh-body)); }
    \\.field-box input::placeholder, .field-box textarea::placeholder { color: var(--mid); }
    \\/* A field that is not taking edits (`TextInput.disabled`). The
    \\   reference draws the disabled *secondary button's* two steps —
    \\   its words at `--g6`, its outline at `--g10` — on the two parts
    \\   of a field that are affordance: the box and the label naming
    \\   what would be typed. The placeholder goes with the label; it is
    \\   prose about typing, and there is no typing. */
    \\.field:has(:disabled) .field-label { color: var(--g6); }
    \\.field-box:has(:disabled) { border-color: var(--g10); }
    \\.field-box input:disabled::placeholder, .field-box textarea:disabled::placeholder { color: var(--g6); }
    \\/* And the value does *not* go with them — the one place this
    \\   edition has to argue with its own engine. Every browser greys a
    \\   disabled control's text by default (WebKit through
    \\   `-webkit-text-fill-color`, which `color` alone does not beat,
    \\   and iOS through an opacity of its own), because on a button the
    \\   words are the offer. Here they are the user's own text, and this
    \\   state exists precisely while that text is on the wire: dimming
    \\   the one thing worth checking would make the pattern's purpose
    \\   hardest to read at the moment it matters. Same rule as the
    \\   reference (`drawFieldChrome`), so the two editions agree. */
    \\.field-box input:disabled, .field-box textarea:disabled {
    \\  color: var(--ink);
    \\  -webkit-text-fill-color: var(--ink);
    \\  opacity: 1;
    \\}
    \\/* A field's problem hangs below its outline at the labeled-field
    \\   gap, not the page's flow — `fieldProblemHeight` spends
    \\   `input_label_gap` on it — so the field and the words about it
    \\   are wrapped and spaced together, the same move `.tile-group`
    \\   makes for its caption. */
    \\.field-group { display: flex; flex-direction: column; gap: var(--input-label-gap); }
    \\/* Small scale in full ink, like the field's own label: this is not
    \\   a detail line, and the library dims only those. Nothing else
    \\   marks it — the reference has no red to spend and neither does
    \\   this edition, so the words are the whole indicator, which is
    \\   what WCAG 1.4.1 asks for anyway. The box is left alone: focus
    \\   already darkens that border, and one appearance cannot carry
    \\   two states. */
    \\.field-problem { font-size: var(--px-small); line-height: var(--lh-small); color: var(--ink); }
    \\.copyable code { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    \\/* The affordance is quiet; the acknowledgement is not — the check
    \\   arrives in ink, because it is the only visible sign the copy
    \\   happened. */
    \\.copyable .icon.mid { color: var(--mid); }
    \\
    \\/* A bare glyph control: the whole affordance is the target, so it
    \\   gets the 44px one rather than the 24px floor. */
    \\.icon-button {
    \\  display: inline-flex;
    \\  /* A flex item stretches to the column's width unless it says
    \\     otherwise, and a bare glyph control stretched across the page
    \\     is a 44px target pretending to be a banner. */
    \\  align-self: flex-start;
    \\  align-items: center;
    \\  justify-content: center;
    \\  width: var(--touch);
    \\  height: var(--touch);
    \\  flex: none;
    \\  padding: 0;
    \\  border: 0;
    \\  background: transparent;
    \\  border-radius: var(--radius);
    \\}
    \\.icon-button .icon, .btn.icon-only .icon {
    \\  font-size: var(--icon-glyph);
    \\  width: var(--icon-glyph);
    \\  height: var(--icon-glyph);
    \\}
    \\
    \\/* The framework's back control shares the first content element's
    \\   line — a heading, by convention — with that element indented
    \\   past it. Its target hangs into the page margin on both axes so
    \\   the *glyph* is what lines up: the leading edge of the mark sits
    \\   on the text column, not the leading edge of the target. The
    \\   vertical half is generated per scale at the end of this sheet. */
    \\/* Offsets are measured from the containing block's *padding box*,
    \\   which is inside the border and outside the padding — so the page
    \\   margin is still ahead of them and every inset here spends it
    \\   before the bleed comes off. */
++ "\n" ++ root_sel ++ " > .icon-button.back {\n" ++
    \\  position: absolute;
    \\  inset-inline-start: calc(var(--page-pad) - var(--back-bleed));
    \\  /* Nothing to centre on: `layoutRow` takes no offset when the
    \\     block it pairs with holds no words of its own, and the control
    \\     opens the row where it stands. */
    \\  top: var(--page-pad);
    \\}
++ "\n" ++ root_sel ++ " > .icon-button.back + * { padding-inline-start: calc(var(--touch) + var(--icon-gap) - var(--back-bleed)); }\n" ++
    \\/* A container that draws and insets nothing does not own the row's
    \\   first line — the block inside it does, so the indent lands there
    \\   (`handsDownBack`). Indenting the container instead pushes its
    \\   every paragraph into the chevron's band. */
++ "\n" ++ root_sel ++ " > .icon-button.back + :is(.document, .stack.hands-back) { padding-inline-start: 0; }\n" ++
    root_sel ++ " > .icon-button.back + :is(.document, .stack.hands-back) > :first-child {\n" ++
    \\  padding-inline-start: calc(var(--touch) + var(--icon-gap) - var(--back-bleed));
    \\}
    \\
    \\/* Standing alone the indicator is the bar's only content, so it is
    \\   the group: one square, centred, like every other shape the bar
    \\   wears. Where the bar has a group already — a row of destinations
    \\   or the collapsed chip — it is not this layer at all but a child
    \\   of that row (`indicatorRidesNavGroup`), so the two centre as one
    \\   instead of each finding its own edge. */
    \\.nav-indicator {
    \\  position: fixed;
    \\  bottom: calc(var(--bar-bottom) + var(--safe-b));
    \\  inset-inline: 0;
    \\  z-index: 2;
    \\  height: var(--nav-slot);
    \\  display: flex;
    \\  justify-content: center;
    \\  align-items: center;
    \\  /* The layer spans the bar to centre one control in it, so it has
    \\     to let the page through either side of that control — the same
    \\     discipline `.nav` keeps for the same reason. */
    \\  pointer-events: none;
    \\}
    \\/* In the bar it plates itself on the same .g11 a destination does,
    \\   being one more thing in that row, and takes the destinations'
    \\   corner — a circle, being a pill as tall as it is wide. */
    \\/* Centred on the items' own band, not on the bar: that padding is
    \\   asymmetric — more below, where the frame is — and centring in
    \\   the bar's box would leave the indicator riding low against the
    \\   destinations it sits beside. */
    \\.nav-indicator .icon-button, .nav-row > .icon-button {
    \\  align-self: center;
    \\  background: var(--g11);
    \\  border-radius: 50%;
    \\  pointer-events: auto;
    \\}
    \\
    \\/* ---- focus ------------------------------------------------------- */
    \\
    \\/* One 2px stroke in ink, in one of two placements, and never a
    \\   second line beside an existing one.
    \\
    \\   `:focus-visible` throughout, never bare `:focus`. Whether a
    \\   *pointer* press shows the ring is a modality question, and the
    \\   browser's own heuristic is this platform's answer: keyboard
    \\   focus draws the ring, a tap or a click does not — while a text
    \\   field, which keyboard input is about to land in, draws it
    \\   however focus arrived. That is the same rule the reference
    \\   states with `App.focus_visible` (`drawNode`'s `ring`, and the
    \\   text fields kept on ungated `focused`); here the browser
    \\   already tracks the origin, so nothing crosses the driver to
    \\   restate it.
    \\
    \\   Held two pixels clear of the rect, by default. The clear is
    \\   structural rather than decorative: two anti-aliased arcs sharing
    \\   a boundary do not sum to full coverage, and the shortfall reads
    \\   as a light hairline tracing the corner.
    \\
    \\   Where an element already owns an outline, focus *takes it over*:
    \\   the stroke lands on the element's own edge — a negative offset,
    \\   because the reference strokes a rect from the inside — so the box
    \\   does not move, its boundary thickens and darkens. Drawing both
    \\   gave two strokes in two tones two pixels apart, which reads as a
    \\   seam, not a state. */
    \\:focus-visible { outline: var(--focus) solid var(--ink); outline-offset: var(--focus-clear); }
    \\/* `:has(:focus-visible)`, not `:focus-within`: the box carries the
    \\   ring for the control inside it, so it must carry it under the
    \\   same modality rule — `:focus-within` lit a mouse-pressed select
    \\   while every other button stayed quiet. A text input or textarea
    \\   matches `:focus-visible` however it was focused, so the typing
    \\   fields keep their ring either way. */
    \\/* A destination is not in this list, and is added to it with the
    \\   rest of the band (`writeDerived`): there it is a plate with an
    \\   edge of its own to take over, and as a header it is a word — a
    \\   stroke laid *inside* a word's box crosses the letters. So the
    \\   header's destinations take the default two pixels of clear
    \\   instead, which is this same rule read the same way. */
    \\.field-box:has(:focus-visible),
    \\.tile:focus-visible,
    \\.picker-item:focus-visible,
    \\.btn.secondary:focus-visible {
    \\  outline: var(--focus) solid var(--ink);
    \\  outline-offset: calc(-1 * var(--focus));
    \\}
    \\.field-box:has(:focus-visible) { border-color: var(--ink); }
    \\.btn.secondary:focus-visible { border-color: transparent; }
    \\
    \\/* Where the row is the control, the row is what carries the
    \\   indicator: the reference rings the whole checkbox or toggle row,
    \\   the whole radio group's card, and the whole segmented track —
    \\   never the 20px drawing of state inside one. */
    \\.ctl:has(:focus-visible), .seg-track:has(:focus-visible) {
    \\  outline: var(--focus) solid var(--ink);
    \\  outline-offset: var(--focus-clear);
    \\}
    \\.radios > .tiles:has(:focus-visible) {
    \\  outline: var(--focus) solid var(--ink);
    \\  outline-offset: calc(-1 * var(--focus));
    \\}
    \\.ctl :focus-visible, .seg input:focus-visible, .radios input:focus-visible { outline: none; }
    \\
    \\.visually-hidden {
    \\  position: absolute;
    \\  width: 1px; height: 1px;
    \\  margin: -1px; padding: 0; border: 0;
    \\  overflow: hidden;
    \\  clip-path: inset(50%);
    \\  white-space: nowrap;
    \\}
    \\
    \\/* ---- bottom chrome ----------------------------------------------- */
    \\
    \\/* The roster has two shapes and the *reader's window* picks, which
    \\   is one rule and not a placement API: nothing about it reaches a
    \\   consumer call, and the tree it renders is the same tree either
    \\   way (`nav.zig`, "There is no placement API and no shape API").
    \\
    \\   A pill in a band across the bottom is a thumb affordance. It is
    \\   right for a phone, where reach is worst at the far edge and the
    \\   bar is the chrome a hand goes to without looking, and it is the
    \\   oddity anywhere else: a page read with a pointer, at a width that
    \\   leaves room beside its own text column, wants its destinations
    \\   where a document's are — a row of words above the page, in the
    \\   page's own margin, wrapping when there are more of them than fit.
    \\
    \\   So this block is the header, and the band is the exception, held
    \\   behind the one width the sheet already turns on (`writeDerived`).
    \\   At and below that width every bottom-anchored surface here *is*
    \\   the screen, edge to edge with no side edges to round; above it
    \\   each of them is a pane standing in a window. The bar sorts the
    \\   same way, so it spends the same number and cannot drift from it.
    \\
    \\   Nothing is reordered to do it. The chrome mount is written before
    \\   the content mount and the nav leads the focus order (`document`,
    \\   `chrome`), so *in flow* the header is already above the page's
    \\   own title — the band was the thing that had to take it out of
    \\   flow, not this. */
    \\.nav {
    \\  display: flex;
    \\  justify-content: flex-start;
    \\  /* The page's own top margin, above the page's first block. The
    \\     inline inset is the row's (`nav_bar_pad_h`), which is the same
    \\     16 for the same reason: nav labels align with the page. */
    \\  padding-top: var(--page-pad);
    \\}
    \\/* It wraps, and that is the whole of what the header needs the
    \\   collapsed chip for elsewhere: a second line is a shape a document
    \\   has and a fixed one-line band does not. The row gap is the root
    \\   stack's, the column gap the page's margin — words a reader scans
    \\   as one set, spaced like the page rather than like plates. */
    \\.nav-row {
    \\  display: flex;
    \\  flex-wrap: wrap;
    \\  align-items: center;
    \\  gap: var(--page-gap) var(--page-pad);
    \\  padding-inline: var(--nav-bar-pad-h);
    \\}
    \\/* Words, not capsules. The destinations take the step-back tone the
    \\   plated row already gave them, and the one you are standing on
    \\   takes ink and the bold face — weight and tone, which is how a
    \\   grayscale system says "this one". A fill would have been the
    \\   weakest mark available here and it is what the band uses only
    \\   because a band has plates to fill.
    \\
    \\   No underline, though `link` carries one: an underline in prose
    \\   says *this word is a destination* among words that are not, and
    \\   in a row where every word is one it distinguishes nothing. */
    \\.chip {
    \\  display: inline-flex;
    \\  align-items: center;
    \\  gap: var(--icon-gap);
    \\  color: var(--dark);
    \\  text-decoration: none;
    \\  white-space: nowrap;
    \\}
    \\.chip.current { color: var(--ink); font-weight: 700; }
    \\
    \\/* The collapsed chip needs no rule of its own in either shape: it
    \\   is one control standing in for the bar, and the bar lays out what
    \\   it holds the same way whether that is a whole roster or one chip.
    \\   Pinned to the pane's leading edge instead, it sat at one end of
    \\   a wide display with the notices control at the other.
    \\   `layoutNavChrome` centres the same group. */
    \\
    \\/* The banner owns the bottom pane — the nav is hidden and inert
    \\   until the notices minimize, so this stands where the bar would
    \\   have. Its fill bleeds through the OS band to the physical edge,
    \\   like every bottom-anchored surface here: the band holds no
    \\   content, only surface. */
    \\.notice {
    \\  position: fixed;
    \\  inset-inline: 0;
    \\  bottom: 0;
    \\  z-index: 2;
    \\  display: flex;
    \\  align-items: flex-start;
    \\  gap: var(--icon-gap);
    \\  width: min(100%, var(--pane));
    \\  margin-inline: auto;
    \\  /* `notice_pad` is measured from the rect, and the outline is
    \\     drawn inside it — so the border is part of that inset, not
    \\     added to it. */
    \\  padding: calc(var(--notice-pad) - var(--border));
    \\  padding-bottom: calc(var(--notice-pad) - var(--border) + var(--safe-b));
    \\  /* A banner is the dim track tone, not paper: it is a surface
    \\     sitting on the page, and `.g6` is the boundary that says so. */
    \\  background: var(--g11);
    \\  border: var(--border) solid var(--g6);
    \\  border-bottom: 0;
    \\  border-radius: var(--radius-card) var(--radius-card) 0 0;
    \\}
    \\.notice-words { flex: 1; min-width: 0; }
    \\/* Regular face: the title is a line of body prose, and the
    \\   description under it is what steps back. */
    \\.notice-desc { font-size: var(--px-small); line-height: var(--lh-small); color: var(--dark); }
    \\/* The controls stay centred on the title's *first line*, so a
    \\   target taller than that line hangs into the padding above and
    \\   below rather than pushing the words down. */
    \\.notice > .icon-button { margin-block-start: calc((var(--lh-body) - var(--touch)) / 2); }
    \\/* The trailing pair packs flush: each already carries its own
    \\   padding around a 24px glyph, so the air between two of them is
    \\   visual, and `icon_gap` separates the group from the words rather
    \\   than the targets from each other. */
    \\.notice > .icon-button + .icon-button { margin-inline-start: calc(-1 * var(--icon-gap)); }
    \\
    \\/* A notice inside the pane is a row, not the banner: there is a
    \\   surface under it already, so the dim track carries it and it
    \\   flows with its siblings. */
    \\.notices-pane .notice {
    \\  position: static;
    \\  width: auto;
    \\  margin-inline: 0;
    \\  /* No outline to hold the words off, so the pad is the whole
    \\     inset again. */
    \\  padding: var(--notice-pad);
    \\  border: 0;
    \\  border-radius: var(--radius);
    \\}
    \\
    \\/* ---- layers ------------------------------------------------------ */
    \\
    \\/* While a modal layer is open the rest of the tree is inert, and
    \\   the scrim is what says so. It is a 1px checkerboard of *paper*
    \\   — `canvas.dither(viewport, .paper)` — not a black wash: no
    \\   alpha, so no off-palette gray can appear, and it mutes the
    \\   inert layer by half-covering it rather than by tinting it. A
    \\   2px repeating conic gradient is the same checkerboard.
    \\
    \\   One z-index for the scrims *and* the surfaces they sit under,
    \\   on purpose: equal z resolves by document order, and the
    \\   serializer emits each layer's scrim immediately before its
    \\   surface, in the order the reference paints them (`render`:
    \\   notices pane, sheet, picker — `drawOverScrim` each). That is
    \\   what makes the layers stack per layer: a picker opened from a
    \\   sheet arrives over a scrim of its own, which dims the sheet
    \\   too. Splitting the pair across two z levels put every scrim
    \\   under every surface, and the sheet was never muted. */
    \\.scrim {
    \\  position: fixed;
    \\  inset: 0;
    \\  width: 100dvw;
    \\  height: 100dvh;
    \\  z-index: 3;
    \\  /* Two offset 45° gradients are the checkerboard, and unlike a
    \\     conic one they say so in a form every engine agrees on. */
    \\  background-image:
    \\    linear-gradient(45deg, var(--paper) 25%, transparent 25% 75%, var(--paper) 75%),
    \\    linear-gradient(45deg, var(--paper) 25%, transparent 25% 75%, var(--paper) 75%);
    \\  background-size: 2px 2px;
    \\  background-position: 0 0, 1px 1px;
    \\}
    \\/* One surface for all three: a paper body with rounded top
    \\   corners, standing on the bottom edge, outlined in `.g6`. That
    \\   tone is not the grouping `.g10` a box draws — it is the WCAG
    \\   1.4.11 boundary between the live layer and the dimmed one under
    \\   it, read against a scrim that is paper over content rather than
    \\   plain paper. */
    \\.sheet, .notices-pane, .picker {
    \\  --pad: 0px;
    \\  position: fixed;
    \\  /* The scrims' own z, not one above it — the note on `.scrim`
    \\     says why document order is the stacking here. */
    \\  z-index: 3;
    \\  display: flex;
    \\  flex-direction: column;
    \\  gap: var(--control-gap);
    \\  background: var(--paper);
    \\  border: var(--border) solid var(--g6);
    \\  overflow-y: auto;
    \\  overscroll-behavior: contain;
    \\  inset-inline: 0;
    \\  bottom: 0;
    \\  /* Never flush with the viewport sides: `sheet_margin` stands
    \\     outside the pane, and the pad it was carved from shrinks by
    \\     the same amount, so the content column has not moved. */
    \\  width: min(100% - 2 * var(--sheet-margin), var(--pane));
    \\  margin-inline: auto;
    \\  /* Dynamic units, because a phone's viewport is not a constant:
    \\     the URL bar comes and goes, and a pane measured against the
    \\     large viewport hides its own bottom edge under it. */
    \\  max-height: calc(100% - var(--sheet-min-top));
    \\  max-height: calc(100dvh - var(--sheet-min-top));
    \\  /* `pane_edge` is the pad plus the border it sits inside, and
    \\     `border-box` has already spent the border. */
    \\  padding: var(--sheet-pad) var(--sheet-pad-h);
    \\  padding-bottom: calc(var(--sheet-pad) + var(--safe-b));
    \\  /* The body extends past the bottom and the clip squares it off;
    \\     here the same thing is said by rounding only the top. */
    \\  border-radius: var(--radius-card) var(--radius-card) 0 0;
    \\  border-bottom: 0;
    \\}
    \\/* h2 *scale*, regular face. A pane's title is chrome the framework
    \\   writes, not a `heading` element the app appended — the reference
    \\   draws it with the plain prose face, and every heading level
    \\   drawing bold is a rule about headings. */
    \\.pane-title { font-size: var(--px-h2); line-height: var(--lh-h2); font-weight: 400; }
    \\/* Only the two panes that pin controls to the header corner narrow
    \\   their title for them. A select's picker has none, so its title
    \\   takes the full width; the notices pane pins two, so it steps
    \\   twice as far aside. */
    \\.sheet > .pane-title { padding-inline-end: calc(var(--touch) + var(--icon-gap)); }
    \\.notices-pane > .pane-title { padding-inline-end: calc(2 * var(--touch) + var(--icon-gap)); }
    \\/* Centred on the title's first line; the target is wider than that
    \\   line, so it grows symmetrically into the header's pad. */
    \\.sheet > .icon-button.sheet-close, .notices-pane > .icon-button {
    \\  position: absolute;
    \\  inset-inline-end: var(--sheet-pad-h);
    \\  top: calc(var(--sheet-pad) + (var(--lh-h2) - var(--touch)) / 2);
    \\}
    \\/* The notices pane pins a pair — dismiss-all, then minimize
    \\   outermost-last in document order, packing flush from the corner
    \\   inward exactly as a notice row's trailing pair does. Minimize
    \\   keeps the corner: that slot is where a modal closes, and the
    \\   reflex press it collects must park the notices, not destroy
    \\   them. */
    \\.notices-pane > .icon-button:first-of-type {
    \\  inset-inline-end: calc(var(--sheet-pad-h) + var(--touch));
    \\}
    \\
    \\/* A picker is a bottom-anchored pane because its owner is somewhere
    \\   in the page and the pane cannot be beside it. The nav's section
    \\   list is the exception *where the bar is in the band*: there its
    \\   owner is on screen right below it, so it stands on the bar rather
    \\   than covering it. That exception is written at the width the bar
    \\   is in the band (`writeDerived`) and nowhere else — with the bar
    \\   standing above the page, a card floated over the bottom edge
    \\   would be a list at the far end of the screen from the control
    \\   that opened it, so the section list is a pane like every other
    \\   picker. */
    \\.picker, .notices-pane {
    \\  /* One scroller per layer. The pane is a surface with a height
    \\     cap; what moves inside it is the scroll_region the framework
    \\     put there, and a pane that also scrolled would give a list two
    \\     places to be halfway down. The sheet is not here: it holds
    \\     whatever the app appended and has no region of its own, so the
    \\     surface is the scroller. */
    \\  overflow: hidden;
    \\}
    \\/* The region takes the height the header leaves, and
    \\   `min-height: 0` is what lets it be shorter than its rows —
    \\   without it a flex item floors at its content and the pane grows
    \\   past its own cap instead of scrolling. */
    \\.picker > .scroll, .notices-pane > .scroll { flex: 1; min-height: 0; }
    \\/* Picker rows are tiles: flush but for the hairline separator, not
    \\   gapped like free-flowing content — `layoutBlock` flows them at
    \\   `border` where a free region uses the control gap. */
    \\.picker > .scroll { gap: var(--border); }
    \\/* The row is 44px tall with its outline drawn *inside* that box —
    \\   the chip is a state, not an extra pixel of height — so the pad
    \\   is the tile's less the border it is drawn beside. */
    \\.picker-item {
    \\  position: relative;
    \\  display: flex;
    \\  align-items: center;
    \\  gap: var(--icon-gap);
    \\  padding: calc(var(--tile-pad-v) - var(--border)) calc(var(--tile-pad-h) - var(--border));
    \\  border: var(--border) solid transparent;
    \\  border-radius: var(--radius);
    \\  color: var(--dark);
    \\}
    \\/* The current choice is a dim chip on paper, its state carried by
    \\   the boundary as everywhere else — not by weight. */
    \\.picker-item[aria-selected="true"] {
    \\  background: var(--g11);
    \\  border-color: var(--g6);
    \\  color: var(--ink);
    \\}
    \\/* Hairlines between plain rows only, drawn in the 1px flow gap
    \\   layout leaves between them rather than taken out of a row's own
    \\   height: a chip carries its own outline, and a rule abutting it
    \\   reads as a glitch. */
    \\.picker-item + .picker-item { box-shadow: 0 calc(-1 * var(--border)) 0 var(--g10); }
    \\/* The shadow a row carries is the one *above* it, so both halves of
    \\   `drawPickerSeparators`'s test — neither this row nor the one
    \\   before it may be a chip — are rules about the row that owns the
    \\   line. Written as `:has(+ chip)` this reached one row too high: it
    \\   took the line above the chip's *predecessor* and left the line
    \\   abutting the chip itself, which is the one thing the reference
    \\   goes out of its way not to draw. */
    \\.picker-item[aria-selected="true"],
    \\.picker-item[aria-selected="true"] + .picker-item,
    \\.picker-item:focus-visible,
    \\.picker-item:focus-visible + .picker-item { box-shadow: none; }
    \\
    \\/* ---- the document ------------------------------------------------ */
    \\
    \\/* Two rules that are about the *page*, not about an element, and the
    \\   only two: they exist because `document.zig` writes a page. An
    \\   edition mounted into someone else's document still emits them and
    \\   they still match nothing there — a host that wrote no skip link
    \\   has no `.skip`, and print has always been allowed to say a fixed
    \\   bar is not on paper. Neither reaches `body` or `:root`, which is
    \\   where restyling a host would start. */
    \\
    \\/* The skip link: off-screen until it is focused, then the first
    \\   thing on the page. It is the library's element (`document.zig`)
    \\   and therefore the library's rule — a driver that wrote the anchor
    \\   and forgot the CSS ships a permanent link across the top of every
    \\   page, which is a failure nothing in a build would catch. Its
    \\   parked position is one target plus the page margin above the top
    \\   edge, both read rather than guessed, so a taller target cannot
    \\   leave a sliver of it showing. */
++ "\n." ++ class_names.skip ++ " {\n" ++
    \\  position: absolute;
    \\  inset-inline-start: var(--page-pad);
    \\  top: calc(-1 * var(--touch) - var(--page-pad));
    \\  /* Above every framework layer: the bars sit at 2 and the modal
    \\     surfaces with their scrims at 3, and a skip link the nav covers
    \\     is a skip link that does not exist. */
    \\  z-index: 5;
    \\  padding: var(--button-pad-v) var(--button-pad-h);
    \\  border-radius: var(--radius);
    \\  background: var(--ink);
    \\  color: var(--paper);
    \\  text-decoration: none;
    \\}
++ "\n." ++ class_names.skip ++ ":focus { top: var(--page-pad); }\n" ++
    \\
    \\/* Print. Nothing `position: fixed` belongs on paper — it lands on
    \\   the first sheet over the content and on no other sheet at all —
    \\   so the nav goes, and the reserve the screen kept for it goes with
    \\   it or every printout ends in an inch of nothing (the reserve's own
    \\   print rules are in `writeDerived` with the rest of the group). The
    \\   skip link goes because there is no keyboard on paper. The modal
    \\   layers are deliberately left: a sheet that is open is content the
    \\   reader is looking at, and a printout that dropped it would be
    \\   printing a screen nobody is on. */
    \\@media print {
++ "\n  .nav, ." ++ class_names.skip ++ " { display: none; }\n" ++
    \\}
    \\
;
