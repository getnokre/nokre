//! Deterministic block-flow layout. Integer math only, single measure
//! source (`text.Measurer`), no floats, no rounding ambiguity: the same
//! tree and viewport always produce the same rects, on every platform.
//!
//! The model is Markdown-like block flow, not a constraint solver:
//! - Children of a vertical stack flow top-to-bottom; block elements
//!   (text, headings, boxes, dividers, inputs) take the full available
//!   width, intrinsic elements (buttons, toggles, links, tables) take
//!   their natural width, flush with the leading edge.
//! - Horizontal stacks place intrinsic-width children in document
//!   order along the flow direction, breaking to a new line when the
//!   next child will not fit — except a row of actions, which stays on
//!   one line and folds its tail instead (`rowOverflow`).
//! - There is no alignment system. Everything is leading/top — left in
//!   LTR, right under `App.setDirection(.rtl)`, which mirrors every
//!   leading/trailing choice here and in the renderer. Opinionated.

const std = @import("std");
const bidi = @import("bidi.zig");
const geometry = @import("geometry.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");
const element_mod = @import("element.zig");
const wrap_mod = @import("wrap.zig");

const Size = geometry.Size;
const Rect = geometry.Rect;
const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const Element = element_mod.Element;

/// A horizontal extent — an x and a width, in whatever coordinates the
/// function producing it names. The shape of every answer here that is
/// about the leading/trailing axis alone: a scrolling element's resting
/// window, one chip's place in a track, a notice's text column.
pub const Band = struct { x: i32, w: i32 };

pub const metrics = struct {
    /// WCAG 2.5.8 minimum target size; no interactive rect may be smaller.
    /// This is a floor a control derived from text must clear, never a
    /// size to lay out at — see `touch_target`.
    pub const tap_target = 24;
    /// What a control that is *nothing but a target* gets: a bare glyph
    /// with no pill and no words to widen it (`icon_button`, `back`,
    /// `sheet_close`, an `icon_only` button, the notices indicator), and
    /// a checkbox or toggle row, whose 20px control is likewise the whole
    /// affordance. WCAG 2.5.5 (AAA) and Apple's 44pt both land here;
    /// Material asks for 48dp and is knowingly 4px short of it, because
    /// one number has to serve every shell and 44 is the one two of the
    /// three agree on. The 24px floor is what conformance allows, not
    /// what a finger can hit: at one logical px per point it is under
    /// 4mm of glass, and a bare glyph draws no border to say where it
    /// ends. Adjacent glyph targets therefore pack flush
    /// — each already carries `(touch_target - icon_glyph) / 2` of its
    /// own padding, so the air between two of them is visual, not spacing
    /// that has to be spent — and `icon_gap` separates the group from the
    /// words, not the targets from each other.
    pub const touch_target = 44;
    pub const button_pad_h = 16;
    pub const button_pad_v = 5;
    pub const border = 1;
    pub const radio_glyph = 16;
    /// How far the selected radio's dot sits inside its ring. Named
    /// because two editions draw it: the renderer insets the glyph by
    /// it, and the DOM edition sizes a pseudo-element from the same
    /// number rather than transcribing the 6px that falls out.
    pub const radio_dot_inset = 5;
    pub const control_gap = 8;
    pub const toggle_track_w = 36;
    pub const toggle_track_h = 20;
    pub const toggle_knob_inset = 2;
    pub const checkbox_box = 20;
    /// Tile-row geometry: the shared look of grouped full-width rows
    /// (radio groups, the select picker). 24px text + 2*10 = 44px rows.
    pub const tile_pad_h = 12;
    pub const tile_pad_v = 10;
    pub const input_pad = 5;
    pub const input_label_gap = 6;
    pub const text_area_min_rows = 3;
    pub const cell_pad = 8;
    /// The focus indicator's stroke. Two pixels is WCAG 2.4.13's
    /// perimeter, and it doubles as the ring's outset: the ring sits
    /// immediately outside the rect, so it covers exactly these pixels.
    pub const focus_stroke = 2;
    /// Clear paper an outset ring keeps from an element that paints to
    /// its own edge — a filled pill, the segmented track, a group
    /// border. See `drawClearFocusRing`.
    pub const focus_clear = 2;
    pub const radius = 8;
    pub const radius_card = 12;
    pub const seg_pad_h = 12;
    pub const seg_pad_v = 4;
    pub const badge_pad_h = 8;
    pub const badge_pad_v = 2;
    pub const meter_h = 12;
    /// The QR spec's quiet zone: 4 light modules on every side.
    pub const qr_quiet = 4;
    /// Cap on the rendered QR square; below this, width decides.
    pub const qr_max_side = 240;
    /// List items sit tighter than free-flowing blocks: they are one
    /// run of prose broken into pieces, not separate thoughts.
    pub const list_gap = 4;
    /// Between an item's marker and its words.
    pub const list_marker_gap = 8;
    /// A blockquote's leading band: the 1px rule plus the gap to the
    /// quoted words.
    pub const quote_indent = 16;
    pub const seg_track_pad = 2;
    /// The strip an overflowing track grows below its chips to stand
    /// the scroll indicator in. Without it the bar would sit in the
    /// 2px track pad, sharing the chips' own bottom edge, and a track
    /// that scrolls would read tighter than the same track when it
    /// fits. This is the bar's own ground — 4px of clear, then its 2px.
    pub const seg_scroll_gutter = 6;
    /// The matching strip above the chips. Deepening only the bottom
    /// leaves 2px over the chips against 8 under them, and a band that
    /// lopsided reads as chips shoved at its top edge rather than
    /// standing in it. Half the gutter is the compromise: the clear
    /// space is 6 above and 4 below, the remaining 4 being the bar and
    /// the pad it stands on — ink, not padding, so counting it as
    /// breathing room is what made the track look wrong in the first
    /// place.
    pub const seg_scroll_head = 4;
    /// How far in from the leading edge a back gesture has to travel
    /// before releasing goes back: a quarter of the viewport, floored here
    /// so a narrow window cannot arm on contact. A fraction rather than
    /// a fixed distance because the gesture is "most of the way across
    /// this screen", which is a different number of pixels on a phone
    /// and on a desktop window (see input.zig's `handleEdgePan`).
    pub const back_gesture_min = 64;
    pub const back_gesture_divisor = 4;
    /// The band the threshold has to be re-crossed by before it flips
    /// back. Without it a finger resting on the boundary rattles the
    /// arm/disarm knock at the sample rate of the touch stream.
    pub const back_gesture_hysteresis = 8;
    /// A nav slot is the one place the library grows a control past
    /// `touch_target` rather than up to it: it is the chrome a thumb
    /// reaches for without looking, on every screen the app has, and it
    /// is stacked against the bottom edge where reach is worst. 52px.
    pub const nav_item_pad_v = 14;
    /// Air on either side of a destination's words, inside its pill —
    /// see `navItemPillWidth` for why it is the button's 16 plus 4.
    pub const nav_item_pad_h = 20;
    pub const nav_bar_pad = 4;
    /// Clear space below the items — see `navBarBottomPad`, which is
    /// what reads it. Matches the page's own 16px margin: the nav is
    /// inset from the frame by the same amount the words are.
    pub const nav_bar_pad_b = 16;
    /// Page showing between one destination's plate and the next.
    /// Without it the plates meet along their edges and the row reads as
    /// the single continuous bar the nav just stopped being — the gap is
    /// what makes them items. It is drawn, not laid out: the *slots*
    /// stay flush so a thumb landing between two destinations still
    /// lands on one of them (`drawNavItem`).
    pub const nav_item_gap = 8;
    /// Clear space between the last thing on a page and the bottom
    /// chrome, reserved on every screen that has such chrome. The nav
    /// draws no ground of its own, so distance is the only thing
    /// separating the words from the destinations: at rest, nothing may
    /// sit behind the items. Wider than the page's own 16px margin
    /// because a margin separates content from an edge, and this
    /// separates content from a control.
    pub const nav_content_gap = 24;
    /// Horizontal inset of the bar's items: matches the root stack's
    /// 16px content padding so nav labels align with the page, and
    /// keeps them clear of rounded device corners at full width.
    pub const nav_bar_pad_h = 16;
    /// One pane geometry for the bottom surfaces that hold prose — the
    /// sheet, the notices pane, a select's picker, the notice banner:
    /// centered, capped at this width. It is a line-length cap, and the
    /// reason a sheet does not become a 2000px slab of prose.
    ///
    /// The bar is not one of them, on any platform. Nothing in it is
    /// prose — it is destinations, a chip, a notices control — and
    /// capping it froze those slots at a width some rosters could never
    /// fit into on any display. Whatever shape the bar wears is a group
    /// of its own width, centered on the viewport (`navGroupX`).
    pub const sheet_max_w = 560;
    /// Minimum clear space above an open sheet; also its height cap.
    pub const sheet_min_top = 48;
    pub const sheet_pad = 16;
    /// A modal pane's *horizontal* inset splits the vertical one in
    /// half: `sheet_margin` outside the pane, `sheet_pad_h` inside it.
    /// The sum stays `sheet_pad`, so the content column sits exactly
    /// where a flush pane put it — the pane stands off the viewport
    /// sides without costing the words a pixel. Vertical keeps the
    /// whole 16: the pane meets the bottom edge, so there is no outer
    /// half to give it to, and halving it would only cramp the header.
    pub const sheet_pad_h = 8;
    pub const sheet_margin = sheet_pad - sheet_pad_h;
    pub const notice_pad = 16;
    pub const icon_gap = 8;
    /// The ink a bare glyph control draws: Lucide's own 24px design
    /// grid, so the strokes land on whole pixels. Body size (16) is
    /// right for the glyph inside a pill, which sits beside words and
    /// must match them; a control that *is* the glyph has nothing to
    /// match and read as a hairline at that size.
    pub const icon_glyph = 24;
};

/// How far the back control's target hangs past the leading edge: the
/// padding it carries around its own 24px glyph, spent in the page
/// margin rather than inside the text column. Public because an
/// edition that lays the control out itself needs the same number —
/// the DOM edition spends it as a negative inset.
pub const back_bleed: i32 = @divTrunc(metrics.touch_target - metrics.icon_glyph, 2);

pub fn findNav(tree: *const Tree) ?NodeId {
    return tree.rootChild(.nav);
}

pub fn findSheet(tree: *const Tree) ?NodeId {
    return tree.rootChild(.sheet);
}

pub fn findNotice(tree: *const Tree) ?NodeId {
    return tree.rootChild(.notice);
}

pub fn findNoticesPane(tree: *const Tree) ?NodeId {
    return tree.rootChild(.notices_pane);
}

pub fn findPicker(tree: *const Tree) ?NodeId {
    return tree.rootChild(.picker);
}

/// The minimized-notices indicator: a root-level icon button placed at
/// the trailing edge of the bottom pane.
pub fn findIndicator(tree: *const Tree) ?NodeId {
    return tree.rootChild(.icon_button);
}

/// The topmost open modal layer, in the one precedence the modal stack
/// has: a picker opened from a sheet sits over it, and either sits over
/// the notices pane. Focus scoping, scrim hit-testing, Esc, root-scroll
/// gating, and the DOM chrome pass all take the order from here — five
/// askers, one answer.
pub fn topModalLayer(tree: *const Tree) ?NodeId {
    return findPicker(tree) orelse findSheet(tree) orelse findNoticesPane(tree);
}

pub fn modalOpen(tree: *const Tree) bool {
    return topModalLayer(tree) != null;
}

/// The bottom pane's width: full viewport up to the sheet cap. For the
/// prose surfaces only — the bar measures itself with `navGroupX`.
pub fn paneWidth(viewport: Size) i32 {
    return @min(viewport.w, metrics.sheet_max_w);
}

pub fn paneX(viewport: Size) i32 {
    return @divTrunc(viewport.w - paneWidth(viewport), 2);
}

/// A *modal* pane's width: like `paneWidth`, but never touching the
/// viewport sides — `sheet_margin` stands between them. The banner
/// stays on `paneWidth`: it is a band like the bar, not a layer over
/// one, and a band meets the edges it belongs to.
pub fn modalPaneWidth(viewport: Size) i32 {
    return @min(viewport.w - 2 * metrics.sheet_margin, metrics.sheet_max_w);
}

pub fn modalPaneX(viewport: Size) i32 {
    return @divTrunc(viewport.w - modalPaneWidth(viewport), 2);
}

/// Where a group of the bar's own width sits: centered on the viewport,
/// which is the bar's frame on every platform — never the pane's width
/// (`metrics.sheet_max_w` says why). The one place that centering is
/// derived: the row of destinations, the collapsed chip, a lone notices
/// indicator and the chip's section card are four shapes of one rule,
/// and deriving it four times is how they came to disagree about where
/// the bar's middle was.
pub fn navGroupX(viewport: Size, group_w: i32) i32 {
    return @divTrunc(viewport.w - group_w, 2);
}

/// The widest anything in the bar may draw: the viewport less the inset
/// its items are placed at. A cap on ink rather than on line length, so
/// an overlong section name stops where a destination would instead of
/// running off the display.
pub fn navContentWidth(viewport: Size) i32 {
    return viewport.w - 2 * metrics.nav_bar_pad_h;
}

/// The inset from a modal pane's rect to its content: the pane's own
/// padding plus the border that padding sits inside. Layout and the
/// renderer both measure the header and the body from this. Vertical
/// only — the sides use `pane_edge_h`, whose other half stands outside
/// the pane (`metrics.sheet_margin`).
pub const pane_edge = metrics.sheet_pad + metrics.border;
pub const pane_edge_h = metrics.sheet_pad_h + metrics.border;

pub fn navItemHeight() i32 {
    return text.Scale.body.lineHeight() + 2 * metrics.nav_item_pad_v;
}

/// Whether the roster fits a row of pills, or the nav has to collapse
/// to the single chip (`nav.syncNavChrome`).
///
/// **Each destination is as wide as its own words.** Equal slots were
/// the first rule here, on the reasoning that per-label widths would
/// make the bar a ransom note; with plates under the labels that reads
/// the other way round. A pill stretched to a share of the bar is a
/// pill with its words adrift in the middle of it, and five of them
/// side by side make a strip of identical lozenges that says nothing
/// about the destinations inside. Sized to their labels they are five
/// distinct shapes, which is what a set of places should look like.
///
/// Each is measured with its glyph and the gap after it, because that
/// is what the pill has to hold. Icons therefore push rosters into the
/// collapsed shape sooner — a mark beside every label is worth the chip
/// appearing at widths where the row used to survive, and the chip
/// carries the current section's mark too.
///
/// The question is asked of the **viewport**, not of the shared 560px
/// pane. That cap is a line-length argument, and it governs the bottom
/// chrome that is a surface holding prose — the banner, the notices
/// pane, the sheet. A row of destinations is not prose: capping it froze
/// the slots, so a roster one word too wide for that stayed collapsed on
/// a 5K display, which is not a reasoning anyone could follow from the
/// outside. The row now takes exactly the width its items need and
/// reopens the moment the window can hold it.
///
/// The indicator's slot is reserved whether or not one is present. A
/// nav that changed shape because a notice arrived — and changed back
/// when it was dismissed — would move the only navigation on screen for
/// a reason that has nothing to do with navigation.
pub fn navCollapses(measurer: text.Measurer, items: anytype, viewport: Size) bool {
    if (items.len == 0) return false;
    var row: i32 = 0;
    for (items) |item| {
        row += navItemPillWidth(measurer, item.icon, item.label) + metrics.nav_item_gap;
    }
    // Reserved unconditionally, hence not `if (indicator)`: see above.
    row += metrics.touch_target;
    return row + 2 * metrics.nav_bar_pad_h > viewport.w;
}

/// The collapsed chip's natural width: a destination's pill plus the
/// chevron that says a list opens above it, and the gap before it.
pub fn navChipWidth(measurer: text.Measurer, icon: element_mod.IconName, section: []const u8) i32 {
    return navItemPillWidth(measurer, icon, section) + metrics.icon_gap +
        measurer.measure(.icons, text.Scale.body.px(), element_mod.nav_chevron);
}

/// One destination's drawn pill: its ink plus the air on either side.
/// The padding is the button's 16 with 4 added back, because a pill's
/// ends curve away from the words — the flat ground beside a label is
/// shorter than the number suggests, and 16 that reads as 16 on a
/// square-cornered control reads as less than that here.
pub fn navItemPillWidth(measurer: text.Measurer, icon: element_mod.IconName, label: []const u8) i32 {
    return navItemWidth(measurer, icon, label) + 2 * metrics.nav_item_pad_h;
}

/// A nav plate's corner: half its height, so the destinations are
/// pills. Derived rather than a constant — the shape follows the slot,
/// and a fixed corner would drift back toward a rounded rectangle the
/// next time the row grows. Nothing else in the library is a pill: the
/// nav is the one place a control is *only* a target, with no field,
/// no group and no track around it to square up against.
pub fn navItemRadius() i32 {
    return @divTrunc(navItemHeight(), 2);
}

/// The plate drawn inside a nav slot: half of `nav_item_gap` in on each
/// side, so the page shows between one destination and the next while
/// the slot a thumb lands on stays flush with its neighbours. The
/// renderer fills, outlines, and focuses this rect; the tree's rect
/// stays the target.
pub fn navItemPlate(slot: Rect) Rect {
    return .{
        .x = slot.x + @divTrunc(metrics.nav_item_gap, 2),
        .y = slot.y,
        .w = slot.w - metrics.nav_item_gap,
        .h = slot.h,
    };
}

/// The ink a nav slot holds: glyph, gap, words. The row's collapse
/// threshold and the renderer both derive the group from this, so what
/// layout calls "fits" is exactly what gets drawn.
pub fn navItemWidth(measurer: text.Measurer, icon: element_mod.IconName, label: []const u8) i32 {
    const size = text.Scale.body.px();
    return measurer.measure(.icons, size, icon.utf8()) + metrics.icon_gap +
        measurer.measure(.prose, size, label);
}

/// A labeled field's height: the label at the small scale, the gap,
/// then `content_h` inside the field's own pad and border. The shape
/// `text_input`, `select`, `copyable` and `text_area` all take, and
/// what the picker reserves for its filter.
pub fn labeledFieldHeight(content_h: i32) i32 {
    return text.Scale.small.lineHeight() + metrics.input_label_gap +
        content_h + 2 * (metrics.input_pad + metrics.border);
}

/// Height a field's problem adds beneath the field's own outline: a
/// label gap plus the wrapped small text, zero when there is none. The
/// caption shape `tileGroupDescHeight` already establishes — layout and
/// the renderer split the rect with this one number, so the outline
/// never strays onto the words and the words never float free of the
/// field. It hangs at `input_label_gap`, the same distance the label
/// stands above, because that is what makes the three read as one
/// field instead of three things stacked.
pub fn fieldProblemHeight(measurer: text.Measurer, problem: []const u8, avail_w: i32) i32 {
    if (problem.len == 0) return 0;
    var lines: i32 = 0;
    var it = wrap_mod.wrap(measurer, .prose, text.Scale.small.px(), problem, avail_w);
    while (it.next()) |_| lines += 1;
    return metrics.input_label_gap + @max(lines, 1) * text.Scale.small.lineHeight();
}

pub fn radioRowHeight() i32 {
    return text.Scale.body.lineHeight() + 2 * metrics.tile_pad_v;
}

/// Top of option row `i` inside a radio group's rect: below the label
/// and the group's top border, one hairline per preceding row. Layout,
/// the renderer, and tap hit-testing all derive row geometry from this;
/// `radioRowY(options.len)` is the group's total height.
pub fn radioRowY(i: usize) i32 {
    return text.Scale.small.lineHeight() + metrics.input_label_gap + metrics.border +
        @as(i32, @intCast(i)) * (radioRowHeight() + metrics.border);
}

/// What a tile's leading mark takes from its words: a `lineHeight`
/// square plus `icon_gap`, zero when the row carries none. The same box
/// `noticeTextBand` reserves, and for the same reason — a fixed band,
/// not the glyph's own advance, so every row of a group starts its words
/// on one column whatever glyphs it was given. The DOM edition spends
/// the same two numbers as a `.icon.square` in the row's flex gap.
pub fn tileIconBand(has_icon: bool) i32 {
    return if (has_icon) text.Scale.body.lineHeight() + metrics.icon_gap else 0;
}

/// What a chip's leading mark adds to its width: the glyph's own advance
/// at the chip's scale plus `icon_gap`, zero when there is none.
///
/// A `mark` and not the `tileIconBand` square, and the difference is the
/// whole reason both exist. A tile's band is fixed because a *column* of
/// rows has to start its words on one x; chips are intrinsic-width and
/// flow inline, so there is no column, no band to hold, and no reason to
/// charge a chip for space its own glyph does not occupy. This is the
/// same number `intrinsicSize`'s button arm spends on a leading icon.
pub fn badgeIconWidth(measurer: text.Measurer, icon: ?element_mod.IconName) i32 {
    const name = icon orelse return 0;
    return measurer.measure(.icons, text.Scale.small.px(), name.utf8()) + metrics.icon_gap;
}

/// Height a description adds beneath a tile group's border: a label gap
/// plus the wrapped small text, zero when there is none. Layout and the
/// renderer both split the rect into border box and description with
/// this, so the border never strays onto the caption.
pub fn tileGroupDescHeight(measurer: text.Measurer, description: []const u8, avail_w: i32) i32 {
    if (description.len == 0) return 0;
    var lines: i32 = 0;
    var it = wrap_mod.wrap(measurer, .prose, text.Scale.small.px(), description, avail_w);
    while (it.next()) |_| lines += 1;
    return metrics.input_label_gap + @max(lines, 1) * text.Scale.small.lineHeight();
}

/// The rendered QR square for a symbol of `size` modules: whole pixels
/// per module (fractional modules blur and break scanning), quiet zone
/// included, capped at `qr_max_side`. Layout and the renderer both
/// derive the square from this.
pub fn qrSide(size: i32, avail_w: i32) i32 {
    const m = size + 2 * metrics.qr_quiet;
    const px = @max(1, @divTrunc(@min(avail_w, metrics.qr_max_side), m));
    return px * m;
}

pub const list_marker_max = element_mod.ListItem.max_marker_len;

/// The marker for item `index` of `list`, written into `buf`. Derived
/// from the list and the position — there is nothing to author, so a
/// list can never number itself wrongly. Ordinals are computed in i64
/// so a `start` near the i32 ceiling widens rather than overflowing.
pub fn listMarker(buf: *[list_marker_max]u8, list: element_mod.List, index: usize) []const u8 {
    if (!list.ordered) return element_mod.list_bullet;
    const n = @as(i64, list.start) + @as(i64, @intCast(index));
    return std.fmt.bufPrint(buf, "{d}.", .{n}) catch element_mod.list_bullet;
}

/// The leading band a list's items reserve for their markers: the
/// widest marker in the list plus the gap after it. Uniform across the
/// list, so item words align down the column however the ordinals grow
/// — the number that gets wider is "10.", and only once. Layout and the
/// renderer both derive the marker column from this.
pub fn listGutter(measurer: text.Measurer, tree: *const Tree, list_id: NodeId) i32 {
    const el = tree.getConst(list_id) orelse return 0;
    if (el.* != .list) return 0;
    const list = el.list;
    const count = tree.childCount(list_id);
    var buf: [list_marker_max]u8 = undefined;
    var w: i32 = 0;
    if (!list.ordered or count == 0) {
        w = measurer.measure(.prose, text.Scale.body.px(), listMarker(&buf, list, 0));
    } else {
        // Only the first and last ordinals can be widest: the printed
        // width of an integer run grows monotonically except across the
        // sign, which the ends bracket.
        w = @max(
            measurer.measure(.prose, text.Scale.body.px(), listMarker(&buf, list, 0)),
            measurer.measure(.prose, text.Scale.body.px(), listMarker(&buf, list, count - 1)),
        );
    }
    return w + metrics.list_marker_gap;
}

pub fn pickerItemHeight() i32 {
    return text.Scale.body.lineHeight() + 2 * metrics.tile_pad_v;
}

/// Clear space kept below the items, between them and the physical
/// bottom edge. The OS band counts toward it: a home-indicator strip is
/// already clear space, so on a phone the bar sits `nav_bar_pad` above
/// the band rather than adding a second margin on top of it, while a
/// desktop window — which has no band — gets the whole inset from the
/// bar itself. Without this the items very nearly touch the frame.
pub fn navBarBottomPad(safe_bottom: i32) i32 {
    return @max(metrics.nav_bar_pad, metrics.nav_bar_pad_b - safe_bottom);
}

pub fn navBarHeight(safe_bottom: i32) i32 {
    return navItemHeight() + metrics.nav_bar_pad + navBarBottomPad(safe_bottom);
}

/// The viewport rect remaining for routed content once the bottom pane
/// is carved out. The banner reserves its own height; the nav pane (or
/// the bare minimized-notices indicator) reserves the bar height. The
/// notices pane and the sheet overlay instead — they reserve nothing.
/// `safe_bottom` (see `App.safe_bottom`) comes off unconditionally:
/// content may never *rest* under the OS band.
///
/// This is where content comes to rest, not a wall it cannot cross.
/// Mid-scroll, lines pass behind the nav and down into the safe band —
/// the bar has no ground to hide them any more, and that glimpse of a
/// half-covered line is the only thing telling a reader there is more
/// below. What the reservation guarantees is the resting state: at
/// either end of the scroll, nothing sits behind the chrome.
pub fn contentArea(tree: *const Tree, viewport: Size, safe_bottom: i32) Rect {
    var h = viewport.h - safe_bottom;
    if (findNotice(tree)) |n| {
        h -= tree.getConst(n).?.notice.height;
    } else if (findNav(tree) != null or findIndicator(tree) != null) {
        h -= navBarHeight(safe_bottom);
    }
    return .{ .x = 0, .y = 0, .w = viewport.w, .h = h };
}

/// Space the root's flow keeps below its last element — the empty band
/// every page ends with, whether or not it scrolls. Reserved by layout
/// rather than appended as a node: it is geometry, and a node would
/// show up in child counts, the a11y tree, and the audits as an element
/// no consumer wrote.
///
/// With bottom chrome present it is `nav_content_gap`, so the reserved
/// tail comes to `safe_bottom` + the bar + 24 and a fully scrolled page
/// leaves the destinations standing clear of the words. With none it is
/// the stack's own padding, exactly as before — the 24 is clearance
/// from a control, and there is no control.
pub fn trailingSpace(tree: *const Tree, padding: i32) i32 {
    if (hasBottomChrome(tree)) return metrics.nav_content_gap;
    return padding;
}

/// Whether this screen carries bottom chrome — a notice, a nav pane, or
/// the bare minimized-notices indicator. Both editions ask this one
/// question: the reference edition to reserve the trailing band, the
/// DOM edition to decide `has-chrome`. One predicate, so the two
/// answers cannot drift.
pub fn hasBottomChrome(tree: *const Tree) bool {
    return findNotice(tree) != null or findNav(tree) != null or findIndicator(tree) != null;
}

/// Computes and stores the absolute rect of every node, left-to-right,
/// with the framework's own English on the one control that is measured
/// before it exists (`more_label`, below).
pub fn compute(tree: *Tree, measurer: text.Measurer, viewport: Size) void {
    _ = computeScrolled(tree, measurer, viewport, 0, 0, .ltr, element_mod.default_chrome.more);
}

/// Same, with the window content shifted up by `scroll` px. Returns the
/// root content height so the caller can clamp the offset. Chrome (nav,
/// notice, sheet) is laid out at fixed viewport positions; only content
/// scrolls. All rects stay above `safe_bottom` — chrome anchors to the
/// shrunk viewport; only the renderer's fills reach into the band.
/// `dir` is the app's declared chrome direction (`App.setDirection`):
/// under `.rtl` every leading/trailing choice mirrors — intrinsic
/// blocks and back controls snap right, horizontal stacks and nav
/// slots run right-to-left, pinned corner controls swap corners.
/// Vertical geometry is direction-blind, so `.ltr` output is
/// byte-identical to what this function always produced.
/// `more_label` is the app's word for the folded tail
/// (`App.Chrome.more`), threaded in for the same reason `dir` is: it is
/// app state layout must know and cannot read off the tree. Every other
/// framework string rides on the node it names, but the fold claims that
/// control's width before the control is built, so this one arrives on
/// its own.
pub fn computeScrolled(tree: *Tree, measurer: text.Measurer, viewport: Size, scroll: i32, safe_bottom: i32, dir: bidi.Direction, more_label: []const u8) i32 {
    const root = tree.rootId();
    const rtl = dir == .rtl;
    const nav = findNav(tree);
    const notice = findNotice(tree);
    const pane = findNoticesPane(tree);
    const indicator = findIndicator(tree);
    const sheet = findSheet(tree);
    const picker = findPicker(tree);
    const anchored: Size = .{ .w = viewport.w, .h = viewport.h - safe_bottom };
    if (nav == null and notice == null and pane == null and indicator == null and sheet == null and picker == null) {
        var ctx: Ctx = .{ .tree = tree, .measurer = measurer, .bottom = anchored.h, .scroll = scroll, .rtl = rtl, .more_label = more_label };
        const content_h = ctx.layoutBlock(root, 0, -scroll, viewport.w);
        tree.setRect(root, .{ .x = 0, .y = 0, .w = viewport.w, .h = viewport.h });
        return content_h;
    }

    if (nav) |n| layoutNavChrome(tree, measurer, n, anchored, safe_bottom, rtl);
    if (indicator) |n| layoutIndicator(tree, measurer, n, anchored, safe_bottom, rtl);
    if (notice) |n| layoutNoticeChrome(tree, measurer, n, anchored, rtl);
    const area = contentArea(tree, viewport, safe_bottom);
    const s = tree.getConst(root).?.stack;
    const trailing = trailingSpace(tree, s.padding);
    var ctx: Ctx = .{ .tree = tree, .measurer = measurer, .bottom = area.bottom() - trailing, .scroll = scroll, .rtl = rtl, .more_label = more_label };
    const inner_h = ctx.flowChildren(root, area.x + s.padding, area.y + s.padding - scroll, area.w - 2 * s.padding, s.gap, s.padding);
    tree.setRect(root, .{ .x = 0, .y = 0, .w = viewport.w, .h = viewport.h });
    if (pane) |p| layoutNoticesPane(tree, measurer, p, anchored, rtl);
    if (sheet) |sh| layoutSheet(tree, measurer, sh, anchored, rtl);
    if (picker) |p| layoutPicker(tree, measurer, p, anchored, safe_bottom, rtl);
    return inner_h + s.padding + trailing;
}

fn layoutNavChrome(tree: *Tree, measurer: text.Measurer, nav: NodeId, viewport: Size, safe_bottom: i32, rtl: bool) void {
    // The banner owns the bottom pane; the nav is hidden and inert
    // until the notices minimize.
    if (findNotice(tree) != null) {
        tree.setRect(nav, .{ .x = 0, .y = 0, .w = 0, .h = 0 });
        var it = tree.children(nav);
        while (it.next()) |item| tree.setRect(item, .{ .x = 0, .y = 0, .w = 0, .h = 0 });
        return;
    }
    const item_h = navItemHeight();
    const bar_h = navBarHeight(safe_bottom);
    const top = viewport.h - bar_h;
    const items_top = top + metrics.nav_bar_pad;
    const n: i32 = @intCast(tree.childCount(nav));
    if (n == 0) {
        // Nothing in the bar and no ground under it, so there is no
        // width to claim — a mark on the band, where the group would
        // have been centered.
        tree.setRect(nav, .{ .x = navGroupX(viewport, 0), .y = top, .w = 0, .h = bar_h });
        return;
    }

    // The collapsed chip is one control standing in for the bar, not a
    // row, and like the destinations it stands in for it is as wide as
    // what it holds. It is still the bar's group, so it centers as one:
    // the chip with the indicator's square counted after it, exactly as
    // the row counts it. Pinned to an edge instead, the two ended up at
    // opposite ends of a wide display with nothing between them.
    if (soleNavCurrent(tree, nav)) |chip| {
        const reserve: i32 = if (findIndicator(tree) != null) metrics.nav_item_gap + metrics.touch_target else 0;
        const el = tree.getConst(chip).?.nav_current;
        // Capped at what is left: a section name too long for the bar
        // still runs up to its chevron rather than under the indicator.
        const chip_w = @min(navContentWidth(viewport) - reserve, navChipWidth(measurer, el.icon, el.section));
        const group_w = chip_w + reserve;
        const x = navGroupX(viewport, group_w);
        tree.setRect(nav, .{ .x = x, .y = top, .w = group_w, .h = bar_h });
        tree.setRect(chip, .{
            // Mirrored, the chip takes the group's other end — still the
            // end the reading starts from, with the square beyond it.
            .x = if (rtl) x + group_w - chip_w else x,
            .y = items_top,
            .w = chip_w,
            .h = item_h,
        });
        return;
    }

    // Every destination is as wide as its own words (`navCollapses`),
    // so the row is measured before it is placed and then centered on
    // the viewport as one group. The indicator, when there is one,
    // travels at the trailing end of that group rather than in a corner
    // of a pane nothing draws any more.
    const indicator_w: i32 = if (findIndicator(tree) != null) metrics.nav_item_gap + metrics.touch_target else 0;
    var row_w: i32 = indicator_w;
    var it = tree.children(nav);
    var first = true;
    while (it.next()) |item| {
        const pill_w = navRowPillWidth(measurer, tree.getConst(item).?) orelse continue;
        if (!first) row_w += metrics.nav_item_gap;
        first = false;
        row_w += pill_w;
    }
    const row_x = navGroupX(viewport, row_w);
    tree.setRect(nav, .{ .x = row_x, .y = top, .w = row_w, .h = bar_h });

    // Each item's *rect* is its pill grown by half a gap on each side,
    // so the targets stay flush end to end while the plates the
    // renderer draws inside them (`navItemPlate`) do not.
    const half = @divTrunc(metrics.nav_item_gap, 2);
    var pen = row_x;
    var items = tree.children(nav);
    while (items.next()) |item| {
        const pill_w = navRowPillWidth(measurer, tree.getConst(item).?) orelse continue;
        // Mirrored, the row runs from the trailing edge inward — the
        // same walk, measured from the other end.
        const pill_x = if (rtl) row_x + row_w - (pen - row_x) - pill_w else pen;
        tree.setRect(item, .{ .x = pill_x - half, .y = items_top, .w = pill_w + 2 * half, .h = item_h });
        pen += pill_w + metrics.nav_item_gap;
    }
}

/// What one nav child occupies in the row, or null for a child the row
/// does not place. The off-roster marker measures exactly as a
/// destination does — it is one entry of the same roster
/// (`nav.effectiveRoster`), so the width the collapse threshold counted
/// is the width the row lays out.
fn navRowPillWidth(measurer: text.Measurer, el: *const element_mod.Element) ?i32 {
    return switch (el.*) {
        .nav_item => |n| navItemPillWidth(measurer, n.icon, n.label),
        .nav_here => |n| navItemPillWidth(measurer, element_mod.nav_here_icon, n.value),
        else => null,
    };
}

/// The chip when the nav is wearing its collapsed shape: its only child,
/// and a `nav_current`. Null for a row (or for a nav mid-rebuild).
fn soleNavCurrent(tree: *const Tree, nav: NodeId) ?NodeId {
    if (tree.childCount(nav) != 1) return null;
    var it = tree.children(nav);
    const only = it.next().?;
    return if (tree.getConst(only).?.* == .nav_current) only else null;
}

/// Whether the notices indicator belongs to the bar's group — the
/// centered thing of its own width that `layoutNavChrome` measures, wide
/// enough to hold the square because it counts `indicator_w` before it
/// centers. True of both shapes the bar has: a row of destinations and
/// the collapsed chip. False only where there is no group to ride — no
/// nav at all, a nav mid-rebuild, or a banner that has zeroed the bar
/// (`layoutNavChrome`), whose rect would otherwise be read as a group at
/// the origin.
///
/// Both editions ask this one question. The reference places the square
/// at the group's trailing edge by it; the DOM edition emits the control
/// *inside* the row by it, which is how a browser centres the same
/// group. Answered separately, one of them would centre the
/// destinations alone and leave the control wherever the page's edge
/// happened to fall.
pub fn indicatorRidesNavGroup(tree: *const Tree) bool {
    const nav = findNav(tree) orelse return false;
    if (findNotice(tree) != null) return false;
    return tree.childCount(nav) != 0;
}

/// The trailing end of the bar, on the items' own band. Not centered in
/// the bar: its padding is asymmetric (more below, where the frame is),
/// and centering in that box would leave the indicator riding low
/// against the destinations it sits beside.
///
/// Where the bar has a group the indicator rides at the end of *it* —
/// the group is centered at its own width, and a notice control marooned
/// in the corner of a pane nothing draws would read as belonging to the
/// page instead of to the bar. Standing alone it is the bar's only
/// content, so it is the group: one square, centered.
fn layoutIndicator(tree: *Tree, measurer: text.Measurer, indicator: NodeId, viewport: Size, safe_bottom: i32, rtl: bool) void {
    _ = measurer;
    const bar_h = navBarHeight(safe_bottom);
    const items_top = viewport.h - bar_h + metrics.nav_bar_pad;
    const y = items_top + @divTrunc(navItemHeight() - metrics.touch_target, 2);
    if (indicatorRidesNavGroup(tree)) {
        // `layoutNavChrome` already reserved this square inside the
        // group's own width, so the two cannot disagree about it.
        const group = tree.rectOf(findNav(tree).?);
        tree.setRect(indicator, .{
            .x = if (rtl) group.x else group.right() - metrics.touch_target,
            .y = y,
            .w = metrics.touch_target,
            .h = metrics.touch_target,
        });
        return;
    }
    // Its own mirror image: a single centered control has no leading
    // edge to swap, so direction does not enter into it.
    tree.setRect(indicator, .{
        .x = navGroupX(viewport, metrics.touch_target),
        .y = y,
        .w = metrics.touch_target,
        .h = metrics.touch_target,
    });
}

/// The banner: the front notice as a row inside the bottom pane,
/// anchored to the viewport bottom. Writes the element's `height`.
fn layoutNoticeChrome(tree: *Tree, measurer: text.Measurer, notice: NodeId, viewport: Size, rtl: bool) void {
    const w = paneWidth(viewport);
    const x = paneX(viewport);
    var ctx: Ctx = .{ .tree = tree, .measurer = measurer, .bottom = viewport.h, .scroll = 0, .rtl = rtl };
    const h = ctx.layoutNoticeRow(notice, x, 0, w);
    _ = ctx.layoutNoticeRow(notice, x, viewport.h - h, w);
}

/// The modal notices pane: sheet geometry, listing every pending notice
/// as a row in a scroll region. Its minimize control pins to the header
/// corner like the sheet's close.
///
/// The rows are the only part that moves. The pane is as tall as it needs
/// up to the same `sheet_min_top` cap the sheet keeps, and past that the
/// region takes what is left and scrolls — the rows used to be flowed
/// into the pane unbounded, so anything past the cap was drawn outside it
/// and clipped away with no route to it at all. Two passes for the same
/// reason `layoutSheet` needs two: what the rows come to decides the
/// pane's height, and the pane's height decides where the rows go.
fn layoutNoticesPane(tree: *Tree, measurer: text.Measurer, pane: NodeId, viewport: Size, rtl: bool) void {
    const w = modalPaneWidth(viewport);
    const x = modalPaneX(viewport);
    const inner_w = w - 2 * pane_edge_h;
    const max_h = viewport.h - metrics.sheet_min_top;

    var ctx: Ctx = .{ .tree = tree, .measurer = measurer, .bottom = viewport.h - pane_edge, .scroll = 0, .rtl = rtl };
    // Two pinned corner controls — dismiss-all and minimize — narrow
    // the title; they pack flush like a notice row's trailing pair, so
    // only the group as a whole is held off the words.
    const title_w = inner_w - 2 * metrics.touch_target - metrics.icon_gap;
    // Read off the pane: the framework's word for it is the app's to
    // translate (`App.Chrome.notices`) and rides on the node, so the
    // header is measured from the bytes that will be drawn and announced
    // rather than from a second copy that could drift.
    const title_h = ctx.wrappedHeight(.prose, .h2, tree.getConst(pane).?.notices_pane.title, &.{}, title_w);
    const header_h = pane_edge + title_h + 8;

    var region: ?NodeId = null;
    var it = tree.children(pane);
    while (it.next()) |c| {
        if (tree.getConst(c).?.role() == .scroll_region) region = c;
    }
    const reg = region orelse {
        const bare = header_h + pane_edge;
        tree.setRect(pane, .{ .x = x, .y = viewport.h - bare, .w = w, .h = bare });
        if (tree.get(pane)) |el| el.notices_pane.height = bare;
        pinHeaderControl(tree, pane, .icon_button, rtl);
        return;
    };

    // Measured before the pane has a place to be: the rows' height
    // decides the pane's, and the pane's decides where the rows go. The
    // rows are flowed through `flowChildren` rather than through the
    // region itself, whose own branch would clamp a reader's scroll
    // offset to a height this pass has not decided yet.
    const content_h = ctx.flowChildren(reg, x + pane_edge_h, 0, inner_w, metrics.control_gap, 0);

    const room = max_h - header_h - pane_edge;
    const region_h = @min(content_h, @max(0, room));
    if (tree.get(reg)) |el| el.scroll_region.height = region_h;
    const h = header_h + region_h + pane_edge;
    const top = viewport.h - h;
    tree.setRect(pane, .{ .x = x, .y = top, .w = w, .h = h });
    if (tree.get(pane)) |el| el.notices_pane.height = h;
    ctx.bottom = top + h - pane_edge;
    _ = ctx.layoutBlock(reg, x + pane_edge_h, top + header_h, inner_w);

    pinHeaderControl(tree, pane, .icon_button, rtl);
}

/// The select picker: sheet geometry over everything, its option rows
/// in a scroll region sized to the content up to the height cap. The
/// collapsed nav's list is a different shape entirely (`layoutNavMenu`),
/// because its owner is the bottom bar rather than something in the page.
fn layoutPicker(tree: *Tree, measurer: text.Measurer, picker: NodeId, viewport: Size, safe_bottom: i32, rtl: bool) void {
    if (tree.getConst(picker).?.picker.above_nav)
        return layoutNavMenu(tree, measurer, picker, viewport, safe_bottom, rtl);
    const w = modalPaneWidth(viewport);
    const x = modalPaneX(viewport);
    const inner_w = w - 2 * pane_edge_h;
    const bottom = viewport.h;
    const max_h = bottom - metrics.sheet_min_top;

    var ctx: Ctx = .{ .tree = tree, .measurer = measurer, .bottom = bottom - pane_edge, .scroll = 0, .rtl = rtl };
    const title = tree.getConst(picker).?.picker.title;
    const title_h = ctx.wrappedHeight(.prose, .h2, title, &.{}, inner_w);
    const header_h = pane_edge + title_h + 8;

    var filter: ?NodeId = null;
    var region: ?NodeId = null;
    var it = tree.children(picker);
    while (it.next()) |c| switch (tree.getConst(c).?.role()) {
        .text_input => filter = c,
        .scroll_region => region = c,
        else => {},
    };
    const reg = region orelse {
        tree.setRect(picker, .{ .x = x, .y = bottom - header_h - pane_edge, .w = w, .h = header_h + pane_edge });
        return;
    };
    const filter_block: i32 = if (filter != null)
        labeledFieldHeight(text.Scale.body.lineHeight()) + 8
    else
        0;
    // With a filter, size to the full option count so the picker's
    // geometry stays put while typing narrows the rows.
    const n: i32 = if (filter != null)
        @intCast(tree.getConst(picker).?.picker.option_count)
    else
        @intCast(tree.childCount(reg));
    const content_h = if (n == 0) 0 else n * pickerItemHeight() + (n - 1) * metrics.border;
    const region_h = @min(content_h, @max(0, max_h - header_h - filter_block - pane_edge));
    if (tree.get(reg)) |el| el.scroll_region.height = region_h;
    const h = header_h + filter_block + region_h + pane_edge;
    const top = bottom - h;
    tree.setRect(picker, .{ .x = x, .y = top, .w = w, .h = h });
    ctx.bottom = top + h - pane_edge;
    if (filter) |f| _ = ctx.layoutBlock(f, x + pane_edge_h, top + header_h, inner_w);
    _ = ctx.layoutBlock(reg, x + pane_edge_h, top + header_h + filter_block, inner_w);
}

/// The collapsed nav's section list: a card of rows hanging off the chip
/// that opened it, in the tile group's shape rather than the sheet's.
///
/// The select's picker is a bottom-anchored pane because its owner is
/// somewhere in the page and the list has nowhere better to be. This
/// one's owner is on screen, a gap below it — and the nav gave its
/// ground up so its items could stand on plates of their own, so a
/// pane-width surface with a title bar, floating clear of the bottom
/// edge, answers a chip in a register the chip never used. The card is
/// as wide as its longest row and centered on the bar's group, which is
/// the surface it stands on.
///
/// Centered on the *group* rather than on the chip inside it, which
/// differ by half the indicator's square when there is one. Two reasons,
/// and they agree: the group is the visual unit — the card stands on the
/// bar, not on one control in it — and the group's center is the
/// viewport's center, which is a number the DOM edition can reach with
/// `margin-inline: auto`. Aligned to the chip, that edition would need
/// the chip's measured width to place a fixed layer, and no rect crosses
/// into it (`docs/internals/dom-edition.md`); the two would have drifted
/// apart by those 26px in exactly this state.
///
/// It never scrolls. `nav.max_nav_items` plus the screen's own entry is
/// six rows, and six rows over the bar fit every viewport nokre lays
/// out; the `sheet_min_top` clamp below is a guard against pathology,
/// not a scrolling story. There is likewise no header to subtract and no
/// filter to reserve — `overlays.openNavPicker` builds neither.
fn layoutNavMenu(tree: *Tree, measurer: text.Measurer, picker: NodeId, viewport: Size, safe_bottom: i32, rtl: bool) void {
    // Rows flush inside the 1px edge, exactly as a `tile_group` seats
    // its tiles — the shape is the point, so it is the same number.
    const pad = metrics.border;
    const anchor = navMenuAnchor(tree, viewport, safe_bottom);
    var region: ?NodeId = null;
    var it = tree.children(picker);
    while (it.next()) |c| {
        if (tree.getConst(c).?.role() == .scroll_region) region = c;
    }
    const reg = region orelse {
        tree.setRect(picker, .{ .x = anchor.x, .y = anchor.y, .w = 0, .h = 0 });
        return;
    };

    const inner_w = navMenuInnerWidth(tree, measurer, reg, viewport, anchor);
    const w = inner_w + 2 * pad;
    // Its own mirror image, like every centered thing in the bar.
    const x = navGroupX(viewport, w);

    const bottom = anchor.y - metrics.nav_item_gap;
    const n: i32 = @intCast(tree.childCount(reg));
    const content_h = if (n == 0) 0 else n * pickerItemHeight() + (n - 1) * metrics.border;
    const region_h = @min(content_h, @max(0, bottom - metrics.sheet_min_top - 2 * pad));
    if (tree.get(reg)) |el| el.scroll_region.height = region_h;
    const h = region_h + 2 * pad;
    const top = bottom - h;
    tree.setRect(picker, .{ .x = x, .y = top, .w = w, .h = h });

    var ctx: Ctx = .{ .tree = tree, .measurer = measurer, .bottom = bottom - pad, .scroll = 0, .rtl = rtl };
    _ = ctx.layoutBlock(reg, x + pad, top + pad, inner_w);
}

/// The chip the section list hangs off. `layoutNavChrome` has already
/// run this pass, so this is a read of the rect the menu must align
/// with — not a second derivation that could disagree with it.
///
/// The fallback covers the one case where that rect is not the chip's:
/// a notice banner owns the bottom pane and zeroes the whole nav. The
/// menu then measures from the band the chip would have occupied, as a
/// zero-width mark where the bar's group would have been centered.
fn navMenuAnchor(tree: *const Tree, viewport: Size, safe_bottom: i32) Rect {
    if (findNav(tree)) |nav| {
        if (soleNavCurrent(tree, nav)) |chip| {
            const r = tree.rectOf(chip);
            if (r.w > 0) return r;
        }
    }
    return .{
        .x = navGroupX(viewport, 0),
        .y = viewport.h - navBarHeight(safe_bottom) + metrics.nav_bar_pad,
        .w = 0,
        .h = navItemHeight(),
    };
}

/// The card's content width: its longest row, floored at the chip's
/// width and capped inside the bar's own margins.
///
/// The floor is why the card cannot read as a mistake — a menu narrower
/// than the control it drops out of looks like a clipping bug, whatever
/// its rows measure. The cap is the same one the chip is capped at
/// (`navContentWidth`), so an overlong section name stops where a
/// destination would and the row's own overflow handling takes it from
/// there. The indicator's square is *not* reserved: it sits in the bar,
/// and the card is above the bar.
fn navMenuInnerWidth(tree: *const Tree, measurer: text.Measurer, region: NodeId, viewport: Size, anchor: Rect) i32 {
    var widest: i32 = 0;
    var it = tree.children(region);
    while (it.next()) |row| {
        const el = tree.getConst(row).?;
        if (el.* != .picker_item) continue;
        const item = el.picker_item;
        const ink = if (item.icon) |ic|
            navItemWidth(measurer, ic, item.label)
        else
            measurer.measure(.prose, text.Scale.body.px(), item.label);
        widest = @max(widest, ink + 2 * metrics.tile_pad_h);
    }
    const edges = 2 * metrics.border;
    const cap = navContentWidth(viewport) - edges;
    return @min(cap, @max(anchor.w - edges, widest));
}

/// Where a notice row's title and description go, given the icon
/// controls it carries. The renderer draws with the exact same column.
/// `rtl` mirrors the flanks: the leading open/expand control and the
/// trailing minimize/dismiss stack swap sides with the chrome.
pub fn noticeTextRegion(tree: *const Tree, notice: NodeId, rtl: bool) Band {
    var lead = false;
    var trail: i32 = 0;
    var it = tree.children(notice);
    while (it.next()) |c| {
        const el = tree.getConst(c).?;
        if (el.role() != .icon_button) continue;
        switch (el.icon_button.glyph) {
            .open, .expand => lead = true,
            .minimize, .dismiss => trail += 1,
            // Header chrome, never a row's control.
            .dismiss_all => {},
        }
    }
    const has_icon = tree.getConst(notice).?.notice.icon != null;
    return noticeTextBand(tree.rectOf(notice), lead, trail, has_icon, rtl);
}

/// The same column, from a row's geometry and its control census rather
/// than from the tree — what `layoutNoticeRow` needs before the rect it
/// is computing exists. The trailing controls pack flush against each
/// other (see `touch_target`); only the group as a whole is held off
/// the words. The notice's own icon stands between the leading control
/// and the words, a `lineHeight` square plus `icon_gap` — a fixed box
/// rather than a measured advance, so this stays free of the measurer.
fn noticeTextBand(r: Rect, lead: bool, trail: i32, icon: bool, rtl: bool) Band {
    const pad = metrics.notice_pad;
    const t = metrics.touch_target;
    const lead_w: i32 = if (lead) t + metrics.icon_gap else 0;
    const trail_w: i32 = if (trail > 0) trail * t + metrics.icon_gap else 0;
    const icon_w: i32 = if (icon) text.Scale.body.lineHeight() + metrics.icon_gap else 0;
    return .{
        .x = r.x + pad + (if (rtl) trail_w else lead_w + icon_w),
        .w = r.w - 2 * pad - lead_w - trail_w - icon_w,
    };
}

/// The controls pinned in a modal header's trailing corner — the
/// sheet's close, the notices pane's dismiss-all and minimize. Centered
/// on the title's first line; the targets are wider than that line, so
/// they grow symmetrically into the header's pad. More than one packs
/// flush from the corner inward, outermost-last in document order, the
/// same stacking a notice row's trailing pair keeps. Called once the
/// pane's own rect is stored.
fn pinHeaderControl(tree: *Tree, pane: NodeId, role: element_mod.Role, rtl: bool) void {
    const r = tree.rectOf(pane);
    const t = metrics.touch_target;
    const y = r.y + pane_edge + @divTrunc(text.Scale.h2.lineHeight() - t, 2);
    var count: i32 = 0;
    var census = tree.children(pane);
    while (census.next()) |child| {
        if (tree.getConst(child).?.role() == role) count += 1;
    }
    var i: i32 = 0;
    var it = tree.children(pane);
    while (it.next()) |child| {
        if (tree.getConst(child).?.role() != role) continue;
        tree.setRect(child, .{
            .x = if (rtl)
                r.x + pane_edge_h + (count - 1 - i) * t
            else
                r.right() - pane_edge_h - (count - i) * t,
            .y = y,
            .w = t,
            .h = t,
        });
        i += 1;
    }
}

/// Bottom-anchored, centered, capped at `viewport.h - sheet_min_top`.
/// Two passes: measure content at the max-height origin, then flow at
/// the real one — a fill scroll region therefore makes the sheet take
/// its maximum height, which is the stable fixed point.
fn layoutSheet(tree: *Tree, measurer: text.Measurer, sheet: NodeId, viewport: Size, rtl: bool) void {
    const w = modalPaneWidth(viewport);
    const x = modalPaneX(viewport);
    const inner_w = w - 2 * pane_edge_h;
    const max_h = viewport.h - metrics.sheet_min_top;

    var ctx: Ctx = .{ .tree = tree, .measurer = measurer, .bottom = viewport.h - pane_edge, .scroll = 0, .rtl = rtl };
    const title = tree.getConst(sheet).?.sheet.title;
    // The header corner is reserved for the close control.
    const title_w = inner_w - metrics.touch_target - 8;
    const title_h = ctx.wrappedHeight(.prose, .h2, title, &.{}, title_w);
    const header_h = pane_edge + title_h + 8;
    const content_h = ctx.flowChildren(sheet, x + pane_edge_h, (viewport.h - max_h) + header_h, inner_w, 8, 0);
    const h = @min(header_h + content_h + pane_edge, max_h);
    const top = viewport.h - h;
    tree.setRect(sheet, .{ .x = x, .y = top, .w = w, .h = h });
    _ = ctx.flowChildren(sheet, x + pane_edge_h, top + header_h, inner_w, 8, 0);

    pinHeaderControl(tree, sheet, .sheet_close, rtl);
}

const Ctx = struct {
    tree: *Tree,
    measurer: text.Measurer,
    /// Lowest y content may reach in the nearest scroll viewport; fill
    /// scroll regions resolve their height against it.
    bottom: i32,
    /// Scroll offsets accumulated above the current flow position.
    scroll: i32,
    /// The advised margin: how far the current flow span may be
    /// exceeded on each side before hitting a drawn edge. Advice, not
    /// force — the flow still insets children by it, but an element
    /// that must reach an edge to work (an overflowing segmented
    /// track) may decline it and bleed. It accumulates through
    /// borderless vertical stacks and is consumed to zero by anything
    /// that draws or clips an edge (box, tile group, scroll region,
    /// sheet, table cell), so bleeding can never cross a border. This
    /// is also why negative padding cannot exist: the only thing it
    /// ever buys — escaping a forced inset — is what declining the
    /// advice already does, bounded by an edge instead of a number.
    margin: i32 = 0,
    /// Mirrored chrome (`App.setDirection(.rtl)`): leading means right.
    rtl: bool = false,
    /// The app's word for the folded tail (`App.Chrome.more`), threaded
    /// in as a value like `rtl` and `bottom` are — layout is still handed
    /// a tree, a measurer, and plain values, never the App. It is here
    /// because `foldButtonRow` claims that control's width before the
    /// control exists, which is the one framework string no node on the
    /// tree can supply. Defaulted so an internal `Ctx` that lays out
    /// chrome (no button row folds inside a modal layer) states only what
    /// it uses.
    more_label: []const u8 = element_mod.default_chrome.more,
    /// A back control handed down into a transparent container so it
    /// pairs with the first line *inside* it (see `layoutRow`). Set by
    /// the row that hands it over and consumed by the very next
    /// `flowChildren`, so it never survives a block.
    handed_back: ?NodeId = null,

    /// The x of an intrinsic-width block within its flow span: flush
    /// with the leading edge — left, or right when mirrored.
    fn startX(self: *const Ctx, x: i32, avail_w: i32, w: i32) i32 {
        return if (self.rtl) x + avail_w - w else x;
    }

    /// Stores a full-width rect of `h` at (x, y) and hands `h` back —
    /// the shape of every block that takes the whole flow span and
    /// computes only its own height.
    fn fullWidth(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32, h: i32) i32 {
        self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = h });
        return h;
    }

    /// Lays out `id` at (x, y) given `avail_w`; stores its rect and
    /// returns the height consumed.
    fn layoutBlock(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32) i32 {
        const el = self.tree.get(id) orelse return 0;
        const h: i32 = switch (el.*) {
            .text, .heading => blk: {
                const run = el.textRun().?;
                break :blk self.fullWidth(id, x, y, avail_w, self.wrappedHeight(run.face, run.scale, run.content, run.spans, avail_w));
            },
            .divider => self.fullWidth(id, x, y, avail_w, 1),
            // Labeled-field geometry: the words at the small scale, the
            // bar below, full width like divider.
            .meter => self.fullWidth(id, x, y, avail_w, text.Scale.small.lineHeight() + metrics.input_label_gap + metrics.meter_h),
            // Labeled-field geometry like meter: the words at the small
            // scale, the code square below, full width for the rect.
            .qr => |q| self.fullWidth(id, x, y, avail_w, text.Scale.small.lineHeight() + metrics.input_label_gap + qrSide(q.size, avail_w)),
            .icon => |ic| blk: {
                const side = ic.scale.lineHeight();
                const w = @min(side, avail_w);
                self.tree.setRect(id, .{ .x = self.startX(x, avail_w, w), .y = y, .w = w, .h = side });
                break :blk side;
            },
            .stack => |s| switch (s.axis) {
                // A borderless stack has no edge to stop at, so its
                // padding joins the advice rather than becoming a wall.
                .vertical => self.layoutVerticalFlow(id, x, y, avail_w, s.padding, s.gap, self.margin + s.padding),
                .horizontal => self.layoutHorizontalFlow(id, x, y, avail_w, s.padding, s.gap),
            },
            .box => |bx| blk: {
                const border_w: i32 = if (bx.border) metrics.border else 0;
                const edge = bx.padding + border_w;
                const saved_bottom = self.bottom;
                self.bottom -= edge;
                const inner_h = self.flowChildren(id, x + edge, y + edge, avail_w - 2 * edge, 8, 0);
                self.bottom = saved_bottom;
                const height = inner_h + 2 * edge;
                self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = height });
                break :blk height;
            },
            .button, .toggle, .checkbox, .link, .badge, .more => blk: {
                const size = self.intrinsicSize(id, avail_w);
                const w = @min(size.w, avail_w);
                self.tree.setRect(id, .{ .x = self.startX(x, avail_w, w), .y = y, .w = w, .h = size.h });
                break :blk size.h;
            },
            // A track wider than the parent scrolls. It declines the
            // advised margin: the rect bleeds to the nearest drawn
            // edge so chips clip at the screen, not mid-page — while
            // the margin becomes a content inset, so resting chips
            // stay aligned with the content around them and the
            // offset space is identical to the unbled track's. The
            // offset is scroll state like `scroll_region`'s —
            // horizontal scroll input and selection reveals write it —
            // so layout only clamps it, except for the -1
            // never-positioned sentinel, which asks for the selected
            // chip to be revealed.
            .segmented => |s| blk: {
                const size = self.intrinsicSize(id, avail_w);
                if (size.w <= avail_w) { // fits: the margin applies, like any block
                    self.tree.setRect(id, .{ .x = self.startX(x, avail_w, size.w), .y = y, .w = size.w, .h = size.h });
                    if (self.tree.get(id)) |el2| {
                        el2.segmented.offset = 0;
                        el2.segmented.bleed = 0;
                    }
                    break :blk size.h;
                }
                const bleed = self.margin;
                // Scrolling costs height: the indicator gets its own
                // strip below the chips rather than the track pad they
                // already stand on (`seg_scroll_gutter`), and the chips
                // keep some of it above them (`seg_scroll_head`).
                const h = size.h + metrics.seg_scroll_head + metrics.seg_scroll_gutter;
                const rect: Rect = .{ .x = x - bleed, .y = y, .w = avail_w + 2 * bleed, .h = h };
                self.tree.setRect(id, rect);
                const window = segTrackWindow(rect, bleed);
                const content_w = size.w - 2 * metrics.seg_track_pad;
                var offset: i32 = 0;
                if (s.offset < 0) {
                    const chip = segChipSpan(self.measurer, s.options, s.selected);
                    if (chip.x + chip.w > window.w) offset = chip.x + chip.w - window.w;
                    if (chip.x < offset) offset = chip.x;
                } else {
                    offset = s.offset;
                }
                offset = std.math.clamp(offset, 0, content_w - window.w);
                if (self.tree.get(id)) |el2| {
                    el2.segmented.offset = offset;
                    el2.segmented.bleed = bleed;
                }
                break :blk h;
            },
            // Rows flush inside the 1px group border, one hairline gap
            // between them for the separator. A description extends the
            // rect below the border so scrolling and clipping carry it
            // with the group.
            .tile_group => |tg| blk: {
                const box_h = self.layoutVerticalFlow(id, x, y, avail_w, metrics.border, metrics.border, 0);
                const desc_h = tileGroupDescHeight(self.measurer, tg.description, avail_w);
                if (desc_h == 0) break :blk box_h;
                self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = box_h + desc_h });
                break :blk box_h + desc_h;
            },
            .tile => |t| blk: {
                var height = text.Scale.body.lineHeight() + 2 * metrics.tile_pad_v;
                if (t.detail.len > 0) height += text.Scale.small.lineHeight();
                break :blk self.fullWidth(id, x, y, avail_w, height);
            },
            // Tile-group geometry: a full-width bordered group of rows
            // under the label, one hairline between rows.
            .radio_group => |rg| self.fullWidth(id, x, y, avail_w, radioRowY(rg.options.len)),
            .select, .copyable => self.fullWidth(id, x, y, avail_w, labeledFieldHeight(text.Scale.body.lineHeight())),
            // A problem extends the rect below the field's outline, the
            // way a description extends a tile group's: the words then
            // scroll, clip and hit-test with the field they belong to
            // instead of being a sibling that happens to sit nearby.
            .text_input => |i| self.fullWidth(id, x, y, avail_w, labeledFieldHeight(text.Scale.body.lineHeight()) +
                fieldProblemHeight(self.measurer, i.problem, avail_w)),
            .text_area => |ta| blk: {
                const inner_w = avail_w - 2 * (metrics.input_pad + metrics.border);
                const min_h = metrics.text_area_min_rows * text.Scale.body.lineHeight();
                const content_h = @max(min_h, self.wrappedHeight(.prose, .body, ta.value, &.{}, inner_w));
                break :blk self.fullWidth(id, x, y, avail_w, labeledFieldHeight(content_h) +
                    fieldProblemHeight(self.measurer, ta.problem, avail_w));
            },
            // A list draws no edge of its own, so the advice passes
            // straight through to the items — a code block inside one
            // can still bleed to whatever edge the list is standing on.
            .list => blk: {
                self.writeMarkers(id);
                break :blk self.layoutVerticalFlow(id, x, y, avail_w, 0, metrics.list_gap, self.margin);
            },
            // The marker occupies the item's leading band, so the advice
            // no longer reaches an edge on that side; consume it, as
            // `layoutRow` does for the back control. The band mirrors:
            // under RTL the marker holds the right end and the words
            // start where they always did.
            .list_item => blk: {
                const gutter = if (self.tree.parentOf(id)) |p| listGutter(self.measurer, self.tree, p) else 0;
                const saved_margin = self.margin;
                self.margin = 0;
                defer self.margin = saved_margin;
                const inner_w = @max(0, avail_w - gutter);
                const inner_x = if (self.rtl) x else x + gutter;
                const h = self.flowChildren(id, inner_x, y, inner_w, metrics.list_gap, 0);
                self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = h });
                break :blk h;
            },
            // A document is a plain vertical flow of the blocks it
            // parsed into: it draws nothing itself, so the advice
            // passes straight through — a code block inside one still
            // bleeds to whatever edge the document is standing on.
            .document => self.layoutVerticalFlow(id, x, y, avail_w, 0, 8, self.margin),
            // The rule is a drawn edge, so a blockquote consumes the
            // advice: an overflowing code block inside one clips at the
            // rule, never across it. The band is leading, so it mirrors.
            .blockquote => blk: {
                const indent = metrics.quote_indent;
                const inner_w = @max(0, avail_w - indent);
                const inner_x = if (self.rtl) x else x + indent;
                const h = self.flowChildren(id, inner_x, y, inner_w, 8, 0);
                self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = h });
                break :blk h;
            },
            // A verbatim block never reflows, so its width comes from
            // its longest line, not the span it is given. Wider than
            // the parent, it takes the overflowing `segmented` track's
            // deal: decline the advised margin, bleed to the nearest
            // drawn edge so the clip lands at the screen rather than
            // mid-page, and keep the resting content span — so lines
            // stay aligned with the prose around them and the offset
            // space is identical to the unbled block's.
            .code_block => |cb| blk: {
                const size = text.Scale.body.px();
                const metrics_line = text.Scale.body.lineHeight();
                var lines: i32 = 0;
                var content_w: i32 = 0;
                var it = std.mem.splitScalar(u8, cb.content, '\n');
                while (it.next()) |line| : (lines += 1) {
                    content_w = @max(content_w, self.measurer.measure(.mono, size, line));
                }
                const height = @max(lines, 1) * metrics_line;
                const bleed: i32 = if (content_w <= avail_w) 0 else self.margin;
                self.tree.setRect(id, .{ .x = x - bleed, .y = y, .w = avail_w + 2 * bleed, .h = height });
                if (self.tree.get(id)) |el2| {
                    const cb2 = &el2.code_block;
                    cb2.content_width = content_w;
                    cb2.bleed = bleed;
                    cb2.offset = std.math.clamp(cb2.offset, 0, @max(0, content_w - avail_w));
                }
                break :blk height;
            },
            .table => self.layoutTable(id, x, y, avail_w),
            .row, .cell => 0, // laid out by layoutTable, never in free flow
            .nav, .nav_item, .nav_current, .nav_here => 0, // laid out by layoutNavChrome, never in free flow
            .sheet, .notices_pane, .picker => 0, // chrome, laid out at fixed positions, never in free flow
            // A notice is chrome in the same way — the banner is placed
            // by `layoutNoticeChrome`, and it is a root child, so it has
            // to measure zero in the root's own flow or it would reserve
            // space in the page. Inside the notices pane's scroll region
            // the same element is a row, and that region flows what it
            // holds generically, so this is where such a row is measured.
            .notice => if (self.isRegionRow(id)) self.layoutNoticeRow(id, x, y, avail_w) else 0,
            .sheet_close, .icon_button => 0, // pinned by chrome layout, never in free flow
            // A bare touch-target square; the flow loops pair it with the
            // element that follows so it shares the title's line. Unpaired
            // it keeps the same margin bleed, so the chevron does not
            // move depending on what came after it.
            .back => blk: {
                self.placeBack(id, x, y, avail_w);
                break :blk metrics.touch_target;
            },
            .picker_item => blk: {
                const height = pickerItemHeight();
                self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = height });
                break :blk height;
            },
            .scroll_region => |*sr| blk: {
                const region_h = sr.height orelse @max(0, self.bottom - (y + self.scroll));
                self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = region_h });
                const saved_bottom = self.bottom;
                const saved_scroll = self.scroll;
                self.bottom = y + region_h;
                self.scroll = saved_scroll + sr.offset;
                // Picker rows are tiles: flush but for the hairline
                // separator, not gapped like free-flowing content.
                const in_picker = if (self.tree.parentOf(id)) |p|
                    self.tree.getConst(p).?.role() == .picker
                else
                    false;
                const gap: i32 = if (in_picker) metrics.border else 8;
                var offset = sr.offset;
                var content_h = self.flowChildren(id, x, y - offset, avail_w, gap, 0);
                const clamped = std.math.clamp(offset, 0, @max(0, content_h - region_h));
                if (clamped != offset) {
                    offset = clamped;
                    self.scroll = saved_scroll + offset;
                    content_h = self.flowChildren(id, x, y - offset, avail_w, gap, 0);
                }
                self.bottom = saved_bottom;
                self.scroll = saved_scroll;
                if (self.tree.get(id)) |el2| {
                    el2.scroll_region.offset = offset;
                    el2.scroll_region.content_height = content_h;
                }
                break :blk region_h;
            },
        };
        return h;
    }

    /// Pins the back control at the line start, hanging its surplus into
    /// the page margin. Alone among the glyph controls this one shares a
    /// leading edge with the prose under it: centering a 44px box on the
    /// column would push the chevron a full glyph inboard of that edge
    /// and break the rag. The target reaches toward the screen edge
    /// instead, which is where the thumb holding the device already is.
    /// Mirrored, it holds the trailing end and the words indent away.
    fn placeBack(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32) void {
        const t = metrics.touch_target;
        const bx = self.startX(x, avail_w, t) + if (self.rtl) back_bleed else -back_bleed;
        self.tree.setRect(id, .{ .x = bx, .y = y, .w = t, .h = t });
    }

    /// Stamps each item of `list` with its derived marker, in one walk
    /// so the ordinals cost a pass rather than a scan per item.
    fn writeMarkers(self: *Ctx, list_id: NodeId) void {
        const list = (self.tree.getConst(list_id) orelse return).list;
        var buf: [list_marker_max]u8 = undefined;
        var index: usize = 0;
        var it = self.tree.children(list_id);
        while (it.next()) |child| : (index += 1) {
            const el = self.tree.get(child) orelse continue;
            if (el.* != .list_item) continue;
            el.list_item.setMarker(listMarker(&buf, list, index));
        }
    }

    fn layoutVerticalFlow(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32, padding: i32, gap: i32, margin: i32) i32 {
        const saved_bottom = self.bottom;
        self.bottom -= padding;
        const inner_h = self.flowChildren(id, x + padding, y + padding, avail_w - 2 * padding, gap, margin);
        self.bottom = saved_bottom;
        const height = inner_h + 2 * padding;
        self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = height });
        return height;
    }

    fn layoutHorizontalFlow(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32, padding: i32, gap: i32) i32 {
        // Rows place children at intrinsic widths off the flow span;
        // the symmetric advice doesn't survive that, so it stops here.
        const saved_margin = self.margin;
        self.margin = 0;
        defer self.margin = saved_margin;
        switch (rowOverflow(self.tree, id)) {
            .fold => return self.layoutFoldingRow(id, x, y, avail_w, padding, gap),
            .wrap => return self.layoutWrappingRow(id, x, y, avail_w, padding, gap),
        }
    }

    /// A row of actions: one line, however narrow the viewport gets, with
    /// the tail folded behind the `more` control (`foldButtonRow`).
    fn layoutFoldingRow(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32, padding: i32, gap: i32) i32 {
        // How many buttons a row too narrow for all of them keeps; null
        // while everything fits (overflow.zig turns this into the tree's
        // `more` control after the pass).
        const visible = self.foldButtonRow(id, avail_w, padding, gap);
        // Document order runs leading-to-trailing: mirrored, the first
        // child sits rightmost and the row grows leftward.
        var cx = if (self.rtl) x + avail_w - padding else x + padding;
        var max_h: i32 = 0;
        var actions: usize = 0;
        var it = self.tree.children(id);
        while (it.next()) |child| {
            const el = self.tree.get(child).?;
            if (el.foldable()) {
                const folded = if (visible) |v| actions >= v else false;
                el.setFolded(folded);
                actions += 1;
                // Folded is off the row entirely: no slot, no advance,
                // and a zero rect so nothing hit-tests or draws where it
                // used to stand.
                if (folded) {
                    self.tree.setRect(child, .zero);
                    continue;
                }
            }
            // The control is the last child, so the folded actions it
            // stands for have already been skipped and it lands exactly
            // where the first of them would have. It is present for a
            // frame after the row grows back wide enough (the sync
            // removes it next pass), and takes no space in the meantime.
            if (el.* == .more and visible == null) {
                self.tree.setRect(child, .zero);
                continue;
            }
            const size = self.intrinsicSize(child, avail_w);
            _ = self.layoutBlock(child, if (self.rtl) cx - size.w else cx, y + padding, size.w);
            max_h = @max(max_h, self.tree.rectOf(child).h);
            const advance = self.tree.rectOf(child).w + gap;
            cx += if (self.rtl) -advance else advance;
        }
        // Center shorter children on the cross axis.
        it = self.tree.children(id);
        while (it.next()) |child| {
            // Nothing on the row: a folded button, or the control before
            // there is anything for it to stand in for. A rect that
            // means "not here" stays exactly zero.
            if (self.tree.rectOf(child).h == 0) continue;
            const dy = @divTrunc(max_h - self.tree.rectOf(child).h, 2);
            if (dy <= 0) continue;
            var walk = self.tree.dfsUnder(child);
            while (walk.next()) |n| {
                var r = self.tree.rectOf(n);
                r.y += dy;
                self.tree.setRect(n, r);
            }
        }
        const height = max_h + 2 * padding;
        self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = height });
        return height;
    }

    /// Every other row: children flow along the line and the line breaks
    /// when the next one will not fit beside what is already standing
    /// there — greedy, first-fit, in document order, so the break points
    /// are a function of the widths alone and no child ever moves
    /// backward past one.
    ///
    /// Nothing is added, removed or hidden by wrapping: each line is the
    /// single-line row again, one under the next, `gap` apart and
    /// cross-centered on its own tallest. That is why this is where marks
    /// land and not what is announced — the semantic tree cannot tell.
    fn layoutWrappingRow(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32, padding: i32, gap: i32) i32 {
        const span = avail_w - 2 * padding;
        // Document order runs leading-to-trailing: mirrored, the first
        // child sits rightmost and each line grows leftward. Vertical
        // geometry is direction-blind — lines always stack downward.
        const line_x = if (self.rtl) x + avail_w - padding else x + padding;
        var cx = line_x;
        var line_y = y + padding;
        var line_w: i32 = 0;
        var line_h: i32 = 0;
        // Children walked on this line, `more` included: what `centerLine`
        // re-walks. `on_line` counts only the ones that took a slot.
        var line_len: usize = 0;
        var on_line: usize = 0;
        var line_first = self.tree.children(id);
        var pending = self.tree.children(id);
        while (true) {
            // Copied before the step, so it stands *at* the child a break
            // is about to move to the next line.
            const cursor = pending;
            const child = pending.next() orelse break;
            const el = self.tree.get(child).?;
            // A control the fold left behind on a row that stopped being
            // a row of actions, or grew wide enough again: it stands for
            // nothing here, so it takes no space until the sync removes
            // it (overflow.zig).
            if (el.* == .more) {
                self.tree.setRect(child, .zero);
                line_len += 1;
                continue;
            }
            // Wrapping hides nothing, so nothing on this row is folded —
            // including an action that was, on a row that has since
            // stopped folding.
            if (el.foldable()) el.setFolded(false);
            const size = self.intrinsicSize(child, span);
            // The break. A line never breaks before its *first* child: one
            // wider than the span alone gets the line to itself and
            // overflows it, which is the one case wrapping cannot rescue
            // and does not pretend to (docs/elements.md).
            if (on_line > 0 and line_w + gap + size.w > span) {
                self.centerLine(line_first, line_len, line_h);
                line_y += line_h + gap;
                cx = line_x;
                line_w = 0;
                line_h = 0;
                line_len = 0;
                on_line = 0;
                line_first = cursor;
            }
            if (on_line > 0) {
                line_w += gap;
                cx += if (self.rtl) -gap else gap;
            }
            _ = self.layoutBlock(child, if (self.rtl) cx - size.w else cx, line_y, size.w);
            const placed = self.tree.rectOf(child);
            line_h = @max(line_h, placed.h);
            line_w += placed.w;
            cx += if (self.rtl) -placed.w else placed.w;
            line_len += 1;
            on_line += 1;
        }
        self.centerLine(line_first, line_len, line_h);
        const height = (line_y - (y + padding)) + line_h + 2 * padding;
        self.tree.setRect(id, .{ .x = x, .y = y, .w = avail_w, .h = height });
        return height;
    }

    /// Centers one line's children on the line's tallest — the cross-axis
    /// rule a row has always had, applied per line. `len` is how many
    /// children the line consumed, so the walk stops where the line did;
    /// a rect that means "not here" stays exactly zero.
    fn centerLine(self: *Ctx, from: Tree.ChildIterator, len: usize, line_h: i32) void {
        var it = from;
        var seen: usize = 0;
        while (seen < len) : (seen += 1) {
            const child = it.next() orelse break;
            const h = self.tree.rectOf(child).h;
            if (h == 0) continue;
            const dy = @divTrunc(line_h - h, 2);
            if (dy <= 0) continue;
            var walk = self.tree.dfsUnder(child);
            while (walk.next()) |n| {
                var r = self.tree.rectOf(n);
                r.y += dy;
                self.tree.setRect(n, r);
            }
        }
    }

    /// How many actions of a row too narrow to hold all of them stay
    /// standing — null when they all fit. Only ever asked of a row
    /// `rowOverflow` already called a row of actions.
    ///
    /// The rule the count comes from: the *last completely visible*
    /// action gives up its slot to the `more` control. Handing the
    /// control the space of the one that was already half off the screen
    /// would put it at the very edge it is meant to rescue, and a row
    /// that ends in a clipped pill beside "More" reads as two different
    /// failures. So the fold is deliberately one deeper than the
    /// overflow itself, and that one is the first thing the sheet lists.
    ///
    fn foldButtonRow(self: *Ctx, id: NodeId, avail_w: i32, padding: i32, gap: i32) ?usize {
        const span = avail_w - 2 * padding;
        var count: usize = 0;
        var total: i32 = 0;
        var it = self.tree.children(id);
        while (it.next()) |child| {
            const el = self.tree.getConst(child).?;
            // The framework's own control never counts as content: it is
            // what the fold produces, not what it measures.
            if (el.* == .more) continue;
            if (count > 0) total += gap;
            total += self.intrinsicSize(child, span).w;
            count += 1;
        }
        if (total <= span) return null;
        // What fits whole, before the control asks for room of its own.
        var fits: usize = 0;
        var run: i32 = 0;
        it = self.tree.children(id);
        while (it.next()) |child| {
            if (!self.tree.getConst(child).?.foldable()) continue;
            const w = self.intrinsicSize(child, span).w;
            run += if (fits == 0) w else gap + w;
            if (run > span) break;
            fits += 1;
        }
        var visible = if (fits == 0) 0 else fits - 1;
        // The control is not the width of the action it replaced, so
        // taking that one slot may not be enough: keep giving up slots
        // until what stays and the control fit together.
        const more_w = moreSize(self.measurer, self.more_label).w;
        while (visible > 0 and self.actionRunWidth(id, visible, span, gap) + gap + more_w > span) {
            visible -= 1;
        }
        return visible;
    }

    /// The width the first `count` actions of a row occupy, gaps
    /// included — what has to leave room for the `more` control beside
    /// them.
    fn actionRunWidth(self: *Ctx, id: NodeId, count: usize, span: i32, gap: i32) i32 {
        var w: i32 = 0;
        var seen: usize = 0;
        var it = self.tree.children(id);
        while (it.next()) |child| {
            if (seen == count) break;
            if (!self.tree.getConst(child).?.foldable()) continue;
            if (seen > 0) w += gap;
            w += self.intrinsicSize(child, span).w;
            seen += 1;
        }
        return w;
    }

    /// Flows children vertically with `gap` between them; a pending back
    /// control shares the next row (see `layoutRow`). Fixed-position
    /// chrome is skipped — it can only exist at the root (`Tree.append`
    /// enforces that) and is laid out at viewport positions instead.
    /// `margin` is the advice children flow under (see `Ctx.margin`) —
    /// explicit at every call site so a container that draws an edge
    /// cannot forget to consume it.
    fn flowChildren(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32, gap: i32, margin: i32) i32 {
        const saved_margin = self.margin;
        self.margin = margin;
        defer self.margin = saved_margin;
        var cy = y;
        var first = true;
        var back: ?NodeId = self.handed_back;
        self.handed_back = null;
        var prev: ?element_mod.Role = null;
        var it = self.tree.children(id);
        while (it.next()) |child| {
            const role = self.tree.getConst(child).?.role();
            switch (role) {
                .nav, .notices_pane, .icon_button, .sheet, .picker, .sheet_close => continue,
                // Chrome at the root, a row inside the notices pane's
                // scroll region. Only the first kind is skipped — the
                // second is what that region is holding.
                .notice => if (!self.isRegionRow(child)) continue,
                .back => {
                    back = child;
                    continue;
                },
                else => {},
            }
            if (!first) cy += if (selfPadded(prev.?) and selfPadded(role)) 0 else gap;
            first = false;
            prev = role;
            cy += self.layoutRow(child, &back, x, cy, avail_w);
        }
        if (back) |b| { // nothing followed; the control gets its own line
            if (!first) cy += gap;
            cy += self.layoutBlock(b, x, cy, avail_w);
        }
        return cy - y;
    }

    /// A row sized to `touch_target` while its words are one line tall,
    /// so it already carries `(touch_target - lineHeight) / 2` of clear
    /// space above and below. Two of them in a row would otherwise be
    /// held apart by both pads *and* the stack's gap — three gaps' worth
    /// of air for what reads as one — so stacked they collapse against
    /// each other and sit exactly like the tile rows in `radio_group`.
    /// It is the vertical half of the packing rule on `touch_target`:
    /// padding a control already owns is not spacing to be spent again.
    /// Only between two of them; a pill or a field beside one is a
    /// different weight and keeps the full gap.
    fn selfPadded(role: element_mod.Role) bool {
        return role == .checkbox or role == .toggle;
    }

    /// Lays out `child` at (x, cy); a pending back control shares the
    /// row, pinned at the line start and centered on the visible text of
    /// the child's first line, with the child indented past it.
    fn layoutRow(self: *Ctx, child: NodeId, back: *?NodeId, x: i32, cy: i32, avail_w: i32) i32 {
        const b = back.* orelse return self.layoutBlock(child, x, cy, avail_w);
        back.* = null;
        // A container that draws nothing and insets nothing does not own
        // the row's first line — the block inside it does. Hand the
        // control down so the indent lands on that line alone. Indenting
        // the container instead pushes its every paragraph into the
        // chevron's band, which is what a screen built as one `document`
        // used to look like: a page ragged 42px in from every other
        // screen's edge.
        if (self.handsDownBack(child)) {
            self.handed_back = b;
            return self.layoutBlock(child, x, cy, avail_w);
        }
        // The back control occupies the row's leading band, so the
        // advice no longer reaches an edge on that side; consume it.
        const saved_margin = self.margin;
        self.margin = 0;
        defer self.margin = saved_margin;
        const t = metrics.touch_target;
        const first_scale: ?text.Scale = if (self.tree.getConst(child).?.textRun()) |run| run.scale else null;
        // Center on the cap region (caps ≈ 3/4 of the font size above
        // the baseline), not the line box: a title rarely has
        // descenders, so the line-box center reads visibly low.
        //
        // The offset is *negative* at every scale, and has to be: a 44px
        // target is taller than any line it marks (40px at h1, 24 at
        // body), so centering it on that line hangs it above the row's
        // top. That is the vertical twin of the leading bleed below —
        // the control reaches into the page margin on both axes, and the
        // margin is where a control's own padding belongs. Clamping this
        // at zero instead is what left the chevron sitting 4px low under
        // an h1 and 11px low under body text: the correction was written
        // but never applied.
        const yoff = if (first_scale) |s|
            s.baseline() - @divTrunc(3 * s.px(), 8) - @divTrunc(t, 2)
        else
            0;
        self.placeBack(b, x, cy + yoff, avail_w);
        const indent = t + metrics.icon_gap - back_bleed;
        const h = self.layoutBlock(child, if (self.rtl) x else x + indent, cy, avail_w - indent);
        return @max(h, yoff + t);
    }

    /// Whether a paired block passes the back control through to its own
    /// first child rather than taking the indent itself: a `document`,
    /// which is a bare flow of what it parsed, and a vertical stack that
    /// pads nothing. Anything that pads, draws an edge, or holds words of
    /// its own starts the line where it stands and keeps the indent.
    fn handsDownBack(self: *const Ctx, child: NodeId) bool {
        const el = self.tree.getConst(child) orelse return false;
        return switch (el.*) {
            .document => true,
            .stack => |s| s.axis == .vertical and s.padding == 0,
            else => false,
        };
    }

    /// One notice as a row: icon controls flank a title + description
    /// column. Shared by the banner and the pane's rows. Writes the
    /// element's `height`; returns it.
    /// Whether this node is a row inside a scroll region rather than a
    /// layer of its own. The one thing that distinguishes the notices
    /// pane's rows from the banner, which is the same element.
    fn isRegionRow(self: *const Ctx, id: NodeId) bool {
        const parent = self.tree.parentOf(id) orelse return false;
        return self.tree.getConst(parent).?.role() == .scroll_region;
    }

    fn layoutNoticeRow(self: *Ctx, notice: NodeId, x: i32, y: i32, w: i32) i32 {
        const pad = metrics.notice_pad;
        const t = metrics.touch_target;
        var left: ?NodeId = null;
        var minimize: ?NodeId = null;
        var dismiss: ?NodeId = null;
        var it = self.tree.children(notice);
        while (it.next()) |c| {
            const el = self.tree.getConst(c).?;
            if (el.role() != .icon_button) continue;
            switch (el.icon_button.glyph) {
                .open, .expand => left = c,
                .minimize => minimize = c,
                .dismiss => dismiss = c,
                // Header chrome, never a row's control.
                .dismiss_all => {},
            }
        }

        const n = self.tree.getConst(notice).?.notice;
        var trail: i32 = 0;
        if (minimize != null) trail += 1;
        if (dismiss != null) trail += 1;
        const text_w = noticeTextBand(.{ .x = x, .y = y, .w = w, .h = 0 }, left != null, trail, n.icon != null, self.rtl).w;
        const title_h = self.wrappedHeight(.prose, .body, n.title, &.{}, text_w);
        const desc_h: i32 = if (n.description.len > 0) self.wrappedHeight(.prose, .small, n.description, &.{}, text_w) else 0;
        // The icons stay centered on the title's first line, so a target
        // taller than that line hangs into the padding above and below
        // rather than pushing the words down; the row only has to be
        // tall enough that the overhang still lands inside it.
        const icon_dy = @divTrunc(text.Scale.body.lineHeight() - t, 2);
        const h = @max(title_h + desc_h, icon_dy + t) + 2 * pad;
        const iy = y + pad + icon_dy;

        // Mirrored, the flanks swap sides but keep their outermost-first
        // stacking (dismiss stays at the far edge). The trailing pair
        // packs flush: their own padding is the space between them.
        if (left) |c| self.tree.setRect(c, .{ .x = if (self.rtl) x + w - pad - t else x + pad, .y = iy, .w = t, .h = t });
        if (self.rtl) {
            var rx = x + pad;
            if (dismiss) |c| {
                self.tree.setRect(c, .{ .x = rx, .y = iy, .w = t, .h = t });
                rx += t;
            }
            if (minimize) |c| {
                self.tree.setRect(c, .{ .x = rx, .y = iy, .w = t, .h = t });
            }
        } else {
            var rx = x + w - pad;
            if (dismiss) |c| {
                rx -= t;
                self.tree.setRect(c, .{ .x = rx, .y = iy, .w = t, .h = t });
            }
            if (minimize) |c| {
                rx -= t;
                self.tree.setRect(c, .{ .x = rx, .y = iy, .w = t, .h = t });
            }
        }
        self.tree.setRect(notice, .{ .x = x, .y = y, .w = w, .h = h });
        if (self.tree.get(notice)) |el| el.notice.height = h;
        return h;
    }

    /// The notices pane's content flow: notice children become rows, the
    /// pinned minimize control is skipped, everything else (the Dismiss
    /// all button) flows normally.
    fn layoutTable(self: *Ctx, id: NodeId, x: i32, y: i32, avail_w: i32) i32 {
        // Column widths: max intrinsic cell width per column. The array
        // is the capacity `Tree.append` enforces, so every cell that
        // can exist has a column here.
        var col_widths: [element_mod.max_table_columns]i32 = @splat(0);
        var ncols: usize = 0;
        var rows = self.tree.children(id);
        while (rows.next()) |row| {
            var col: usize = 0;
            var cells = self.tree.children(row);
            while (cells.next()) |cell| : (col += 1) {
                if (col >= col_widths.len) break;
                const w = self.cellIntrinsicWidth(cell, avail_w) + 2 * metrics.cell_pad;
                col_widths[col] = @max(col_widths[col], w);
                ncols = @max(ncols, col + 1);
            }
        }

        // Never clamped to `avail_w`: the cells below are laid at their
        // intrinsic column widths, so a clamped rect would claim a fit
        // while trailing columns render past it — and hit testing,
        // focus reveal, and the a11y snapshot all read this rect, so
        // they must be told the truth about where the cells are.
        var table_w: i32 = metrics.border;
        for (col_widths[0..ncols]) |w| table_w += w + metrics.border;

        // The table is an intrinsic-width block, so it snaps to the
        // leading edge and its columns run leading-to-trailing.
        const tx = self.startX(x, avail_w, table_w);
        var cy = y + metrics.border;
        rows = self.tree.children(id);
        while (rows.next()) |row| {
            var row_h: i32 = 0;
            var col: usize = 0;
            var cx = if (self.rtl) tx + table_w - metrics.border else tx + metrics.border;
            var cells = self.tree.children(row);
            while (cells.next()) |cell| : (col += 1) {
                if (col >= ncols) break;
                const cw = col_widths[col];
                const cell_x = if (self.rtl) cx - cw else cx;
                const inner_h = self.flowChildren(cell, cell_x + metrics.cell_pad, cy + metrics.cell_pad, cw - 2 * metrics.cell_pad, 4, 0);
                const ch = inner_h + 2 * metrics.cell_pad;
                self.tree.setRect(cell, .{ .x = cell_x, .y = cy, .w = cw, .h = ch });
                row_h = @max(row_h, ch);
                cx += if (self.rtl) -(cw + metrics.border) else cw + metrics.border;
            }
            // Normalize cell heights so grid lines are straight.
            cells = self.tree.children(row);
            while (cells.next()) |cell| {
                var r = self.tree.rectOf(cell);
                r.h = row_h;
                self.tree.setRect(cell, r);
            }
            self.tree.setRect(row, .{ .x = tx, .y = cy, .w = table_w, .h = row_h });
            cy += row_h + metrics.border;
        }

        const height = cy - y;
        self.tree.setRect(id, .{ .x = tx, .y = y, .w = table_w, .h = height });
        return height;
    }

    fn cellIntrinsicWidth(self: *Ctx, cell: NodeId, avail_w: i32) i32 {
        var w: i32 = 0;
        var it = self.tree.children(cell);
        while (it.next()) |child| {
            w = @max(w, self.intrinsicSize(child, avail_w).w);
        }
        return w;
    }

    /// Natural size of an element when it is not stretched (hstack
    /// children, buttons in vertical flow, table cell content).
    fn intrinsicSize(self: *Ctx, id: NodeId, avail_w: i32) Size {
        const el = self.tree.getConst(id) orelse return .{ .w = 0, .h = 0 };
        return switch (el.*) {
            .text, .heading => blk: {
                const run = el.textRun().?;
                const w = if (run.spans.len == 0)
                    self.measure(run.face, run.scale, run.content)
                else
                    wrap_mod.spanTextWidth(self.measurer, run.face, run.scale.px(), run.spans);
                break :blk .{ .w = @min(w, avail_w), .h = run.scale.lineHeight() };
            },
            // The square line-height box keeps icons baseline-compatible
            // with same-scale text beside them.
            .icon => |ic| .{ .w = ic.scale.lineHeight(), .h = ic.scale.lineHeight() },
            // A box unstretched hugs what it groups: the widest child
            // plus its own edges. The fallback share of the parent
            // would make a row of small boxes — swatches, chips —
            // overflow after two, and a box in a table cell would set
            // the column width from nothing. Stretched (vertical flow)
            // it still takes the full span; that path never asks here.
            .box => |bx| blk: {
                const border_w: i32 = if (bx.border) metrics.border else 0;
                const edge = bx.padding + border_w;
                const inner_avail = @max(0, avail_w - 2 * edge);
                var w: i32 = 0;
                var h: i32 = 0;
                var n: i32 = 0;
                var it = self.tree.children(id);
                while (it.next()) |child| : (n += 1) {
                    const size = self.intrinsicSize(child, inner_avail);
                    w = @max(w, size.w);
                    h += size.h;
                }
                break :blk .{
                    .w = @min(w + 2 * edge, avail_w),
                    .h = h + @max(0, n - 1) * 8 + 2 * edge, // 8: the box's inner flow gap
                };
            },
            // The glyph form is the bare touch-target square, like `back`.
            // A pill carrying an icon grows by the glyph and its gap.
            // `in_progress` is deliberately absent from the measure: the
            // button keeps the size its label and icon asked for while
            // the work runs, so the press does not reflow the screen out
            // from under the finger that made it. The renderer draws the
            // `…` centered in exactly this box.
            .button => |b| if (b.form == .glyph) .{
                .w = metrics.touch_target,
                .h = metrics.touch_target,
            } else blk: {
                var w = self.measure(.prose, .body, b.label) + 2 * (metrics.button_pad_h + metrics.border);
                if (b.form.icon()) |ic| w += self.measurer.measure(.icons, text.Scale.body.px(), ic.utf8()) + metrics.icon_gap;
                // A vendor mark sits where an icon would — the form has
                // one slot, so the two cannot both be asked for. The
                // pill's height already clears Apple's 30pt floor —
                // body line height plus the pad is 36 — so the mark
                // costs width and nothing else.
                if (b.form.vendor()) |v| w += self.measurer.measure(.brand, text.Scale.body.px(), v.mark()) + metrics.icon_gap;
                break :blk .{
                    .w = w,
                    .h = text.Scale.body.lineHeight() + 2 * (metrics.button_pad_v + metrics.border),
                };
            },
            // The control's own words once it is standing — the same word
            // the fold reserved room for a pass earlier, because both
            // come from `App.chrome.more`.
            .more => |m| moreSize(self.measurer, m.label),
            .link => |l| .{
                .w = @max(self.measure(.prose, .body, l.label), metrics.tap_target),
                .h = text.Scale.body.lineHeight() + 2, // room for the underline
            },
            // A row deep enough for a finger, like the radio and picker
            // tiles it sits beside: the track and the box are 20px
            // controls with no pill to grow them, so the row *is* the
            // target and the line box alone leaves it at the 24px floor.
            // The renderer centers both the control and its label in it.
            .toggle => |t| .{
                .w = metrics.toggle_track_w + metrics.control_gap + self.measure(.prose, .body, t.label),
                .h = @max(text.Scale.body.lineHeight(), metrics.touch_target),
            },
            .checkbox => |c| .{
                .w = metrics.checkbox_box + metrics.control_gap + self.measure(.prose, .body, c.label),
                .h = @max(text.Scale.body.lineHeight(), metrics.touch_target),
            },
            .segmented => |s| .{
                .w = 2 * metrics.seg_track_pad + segContentWidth(self.measurer, s.options),
                .h = text.Scale.body.lineHeight() + 2 * (metrics.seg_pad_v + metrics.seg_track_pad),
            },
            .radio_group => |rg| .{
                .w = avail_w,
                .h = radioRowY(rg.options.len),
            },
            // A list is prose: it takes the span it is given rather
            // than hugging its longest item, so wrapping stays the
            // paragraph's business.
            .list, .list_item, .blockquote, .document => .{ .w = avail_w, .h = text.Scale.body.lineHeight() },
            .badge => |b| .{
                .w = self.measure(.prose, .small, b.label) + badgeIconWidth(self.measurer, b.icon) +
                    2 * (metrics.badge_pad_h + metrics.border),
                .h = text.Scale.small.lineHeight() + 2 * (metrics.badge_pad_v + metrics.border),
            },
            // The half-width, one-line guess, for every element whose
            // real size some other path decides (chrome is laid out by
            // its own pass; the full-span controls are stretched, never
            // asked here). Enumerated rather than defaulted: a new
            // element must claim its intrinsic size or fail to compile,
            // the same discipline the draw walks keep.
            .divider, .meter, .qr, .stack, .text_input, .text_area, .code_block, .table, .row, .cell, .scroll_region, .tile_group, .tile, .select, .copyable, .nav, .nav_item, .nav_current, .nav_here, .sheet, .sheet_close, .back, .notice, .notices_pane, .icon_button, .picker, .picker_item => .{ .w = @divTrunc(avail_w, 2), .h = text.Scale.body.lineHeight() },
        };
    }

    fn measure(self: *Ctx, face: text.Face, scale: text.Scale, bytes: []const u8) i32 {
        return self.measurer.measure(face, scale.px(), bytes);
    }

    /// How tall `content` stands wrapped to `max_w`, never less than one
    /// line. `spans` is empty for plain text — the styled runs only
    /// change how candidate lines are measured, never how they are
    /// counted.
    fn wrappedHeight(self: *Ctx, base: text.Face, scale: text.Scale, content: []const u8, spans: []const element_mod.Span, max_w: i32) i32 {
        var lines: i32 = 0;
        var it = wrap_mod.wrapSpans(self.measurer, base, scale.px(), content, spans, max_w);
        while (it.next()) |_| lines += 1;
        return @max(lines, 1) * scale.lineHeight();
    }
};

/// What a horizontal `stack` does when its children exceed the line.
/// Two behaviours, and the row's own contents pick which — there is no
/// field, so a consumer cannot be handed the wrong one.
pub const RowOverflow = enum {
    /// A row of *actions* — every child a `button` or a `link`
    /// (`Element.foldable`), two or more of them, outside a modal layer.
    /// Actions have to stay reachable, and one row of them plus a control
    /// that opens the rest is how they do (`overflow.zig`).
    fold,
    /// Everything else. Content that describes rather than acts is all
    /// there already; breaking it onto a second line moves it, while
    /// putting it behind a control named `More` would hide state behind a
    /// press. This is also the answer for the rows that *cannot* fold —
    /// a lone action, and a row of them inside a sheet.
    wrap,
};

/// Which one `id` gets. Width is not an input: a row is a row of actions
/// or it isn't, at every viewport, so widening the window can change
/// where a line breaks or how deep a tail folds but never which of the
/// two the reader is looking at. Layout and the DOM edition's serializer
/// both ask here, so the two editions cannot disagree.
pub fn rowOverflow(tree: *const Tree, id: NodeId) RowOverflow {
    // Not inside a modal layer. The tail's whole answer is a sheet, and
    // one sheet is all there is (`tree.validateAppend`) — a control that
    // could not open anything is worse than a row that wraps, and a
    // *second* kind of layer, chosen by where the row happens to sit, is
    // worse than both. A sheet is a handful of controls, not a toolbar.
    var cur: ?NodeId = id;
    while (cur) |c| : (cur = tree.parentOf(c)) {
        switch (tree.getConst(c).?.role()) {
            .sheet, .picker, .notices_pane => return .wrap,
            else => {},
        }
    }
    var count: usize = 0;
    var it = tree.children(id);
    while (it.next()) |child| {
        const el = tree.getConst(child).?;
        // The framework's own control never counts as content: it is what
        // the fold produces, not what it measures.
        if (el.* == .more) continue;
        if (!el.foldable()) return .wrap;
        count += 1;
    }
    // A row of one does not fold: hiding the only action behind a control
    // named "More" hides it twice. It has nothing to wrap either — one
    // child is one line — so this is where the two behaviours agree.
    return if (count < 2) .wrap else .fold;
}

/// The folded-tail control's box: exactly the outlined button it is
/// drawn as, carrying the ellipsis and the framework's word for itself.
///
/// Layout reserves this width while deciding the fold, whether or not
/// the control is standing in the tree yet — `overflow.syncOverflowChrome`
/// installs it only after a pass has measured the row. So the fold the
/// second pass reaches is the one the first pass decided, and the shape
/// cannot oscillate between them: `label` is the app's chrome either
/// way, threaded in for the pass that has no node to read it from and
/// read off the control for the pass that does (`App.setChrome` keeps
/// the two the same word).
pub fn moreSize(measurer: text.Measurer, label: []const u8) Size {
    const size = text.Scale.body.px();
    return .{
        .w = measurer.measure(.prose, size, label) +
            measurer.measure(.icons, size, element_mod.IconName.ellipsis.utf8()) +
            metrics.icon_gap + 2 * (metrics.button_pad_h + metrics.border),
        .h = text.Scale.body.lineHeight() + 2 * (metrics.button_pad_v + metrics.border),
    };
}

/// The resting content span of a code block: where its lines sit at
/// offset 0 and the width the offset clamps against. `bleed` (the
/// element's, written by layout) collapses a bled rect back to the
/// unbled block's geometry, exactly as `segTrackWindow` does for a
/// track. Layout, the renderer, and scroll input all derive from this.
pub fn codeWindow(rect: Rect, bleed: i32) Band {
    return .{ .x = rect.x + bleed, .w = rect.w - 2 * bleed };
}

/// The resting window of a segmented track: where chips sit at offset
/// 0 and the width the offset clamps against. `bleed` (the element's,
/// written by layout) collapses a bled rect back to the unbled track's
/// geometry — the rect is wider only so chips stay visible, and
/// tappable, through the margin on their way to the edge. Layout, the
/// renderer, and hit-testing all derive chip positions from this.
pub fn segTrackWindow(rect: Rect, bleed: i32) Band {
    const inset = bleed + metrics.seg_track_pad;
    return .{ .x = rect.x + inset, .w = rect.w - 2 * inset };
}

/// The summed chip widths of a segmented track's options — its content
/// width, in content coordinates (track pads excluded).
pub fn segContentWidth(measurer: text.Measurer, options: []const []const u8) i32 {
    var w: i32 = 0;
    for (options) |opt| w += measurer.measure(.prose, text.Scale.body.px(), opt) + 2 * metrics.seg_pad_h;
    return w;
}

/// The horizontal span of chip `idx` in a segmented track's content
/// coordinates (0 at the first chip's leading edge).
pub fn segChipSpan(measurer: text.Measurer, options: []const []const u8, idx: usize) Band {
    var cx: i32 = 0;
    var w: i32 = 0;
    for (options, 0..) |opt, i| {
        w = measurer.measure(.prose, text.Scale.body.px(), opt) + 2 * metrics.seg_pad_h;
        if (i == idx) break;
        cx += w;
    }
    return .{ .x = cx, .w = w };
}
