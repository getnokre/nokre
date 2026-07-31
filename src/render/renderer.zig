//! Turns the laid-out tree into canvas calls. Pure with respect to the
//! canvas interface: production uses the Skia canvas, renderer tests use
//! the recording canvas, goldens compare the rasterized result.

const std = @import("std");
const bidi = @import("../core/bidi.zig");
const editing = @import("../core/editing.zig");
const geometry = @import("../core/geometry.zig");
const input = @import("../core/input.zig");
const color = @import("../core/color.zig");
const text = @import("../core/text.zig");
const tree_mod = @import("../core/tree.zig");
const element_mod = @import("../core/element.zig");
const layout = @import("../core/layout.zig");
const app_mod = @import("../core/app.zig");
const canvas_mod = @import("canvas.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;
const Gray = color.Gray;
const NodeId = tree_mod.NodeId;
const App = app_mod.App;
const Canvas = canvas_mod.Canvas;
const metrics = layout.metrics;

/// Canvas plus draw-site conveniences. Draw code names a *step* in the
/// palette; which byte that step becomes is the canvas's business, and
/// the two ramps differ by more than a sign — see color.zig. Nothing
/// here inverts anything, which is why dark mode can be gentler than
/// light instead of merely opposite.
const Painter = struct {
    canvas: Canvas,
    app: *App,
    /// Replaces the requested text gray; set for table header rows.
    text_ink: ?Gray = null,

    fn clear(self: Painter, gray: Gray) void {
        self.canvas.clear(gray);
    }
    fn fillRect(self: Painter, rect: Rect, radius: i32, gray: Gray) void {
        self.canvas.fillRect(rect, radius, gray);
    }
    fn strokeRect(self: Painter, rect: Rect, radius: i32, thickness: i32, gray: Gray) void {
        self.canvas.strokeRect(rect, radius, thickness, gray);
    }
    fn line(self: Painter, from: Point, to: Point, thickness: i32, gray: Gray) void {
        self.canvas.line(from, to, thickness, gray);
    }
    /// Draws a label-sized string. Complex text (Arabic script, strong
    /// RTL) is its own little paragraph here: resolved, reordered, and
    /// drawn as visual pieces starting at x — so every element label in
    /// the system is bidi-correct without its draw site knowing. Wrapped
    /// paragraphs don't come through this; they resolve per hard
    /// paragraph in drawWrapped/drawSpanWrapped.
    fn drawText(self: Painter, x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, gray: Gray) void {
        if (!bidi.isComplex(bytes)) {
            self.drawPiece(x, baseline, face, size_px, bytes, gray);
            return;
        }
        const para = bidi.resolve(self.app.bidi_scratch, bytes, bidi.paragraphDirection(bytes));
        _ = drawComplexLine(self.app, self, x, baseline, face, size_px, &para, 0, bytes.len, gray);
    }

    /// One already-segmented run straight to the canvas — the only call
    /// that reaches a backend, which shapes its bytes as a single run.
    fn drawPiece(self: Painter, x: i32, baseline: i32, face: text.Face, size_px: i32, bytes: []const u8, gray: Gray) void {
        self.canvas.drawText(x, baseline, face, size_px, bytes, self.text_ink orelse gray);
    }
    fn pushClip(self: Painter, rect: Rect) void {
        self.canvas.pushClip(rect);
    }
    fn popClip(self: Painter) void {
        self.canvas.popClip();
    }
    fn dither(self: Painter, rect: Rect, gray: Gray) void {
        self.canvas.dither(rect, gray);
    }

    /// A painter onto the light ramp whatever the appearance — the QR
    /// tile and the vendor sign-in marks (see `Canvas.light`).
    fn lightPinned(self: Painter) Painter {
        return .{ .canvas = self.canvas.light(), .app = self.app, .text_ink = self.text_ink };
    }
};

/// Whether the chrome is mirrored (`App.setDirection(.rtl)`). Draw code
/// consults this for every leading/trailing choice; text alignment stays
/// content-derived (see drawWrapped) regardless.
fn mirrored(app: *const App) bool {
    return app.direction == .rtl;
}

/// The x of a run of `w` px anchored to the leading edge of a span —
/// left in LTR, right when mirrored. The chrome-label counterpart of
/// layout's `Ctx.startX`.
fn startX(app: *const App, x: i32, avail_w: i32, w: i32) i32 {
    return if (mirrored(app)) x + avail_w - w else x;
}

/// Measures `bytes` and draws it anchored to the leading edge of the
/// span `[x, x + avail_w)`. Single-line chrome — labels, option names,
/// values — follows the chrome's direction rather than its own bytes,
/// so it all places itself this way.
fn drawLeading(app: *App, canvas: Painter, x: i32, avail_w: i32, baseline: i32, face: text.Face, size: i32, bytes: []const u8, ink: Gray) void {
    const w = app.measurer.measure(face, size, bytes);
    canvas.drawText(startX(app, x, avail_w, w), baseline, face, size, bytes, ink);
}

/// A labeled element's caption: small text on the leading edge of the
/// rect's first line. The labeled fields, the radio group, the meter,
/// and the QR tile all open with one.
fn drawSmallLabel(app: *App, canvas: Painter, r: Rect, label: []const u8) void {
    drawLeading(app, canvas, r.x, r.w, r.y + text.Scale.small.baseline(), .prose, text.Scale.small.px(), label, .ink);
}

/// The baseline that centers a glyph's em box in `r`. Icon ink hangs
/// centered in the em box instead of standing on the baseline, so
/// centering the *line* box leaves every glyph riding high — which is
/// why chevrons, marks and bare glyphs all come through here rather
/// than sharing the label baseline beside them.
fn emCenterBaseline(r: Rect, size: i32) i32 {
    return r.y + @divTrunc(r.h + size, 2);
}

/// The 1px `.g6` boundary a compact control's state rides on. Paper or
/// a knob against the dim `.g11` track is ~1.3:1, so the fill alone
/// never carries the state — this stroke is what satisfies WCAG 1.4.11.
/// Shared by meter, toggle, checkbox, the selected segmented chip, and
/// the outlined button.
fn strokeStateEdge(canvas: Painter, r: Rect, radius: i32) void {
    canvas.strokeRect(r, radius, metrics.border, .g6);
}

/// The 1px `.g10` boundary that groups rather than states: box,
/// tile_group, radio group, badge. Structure is never state, so it
/// never borrows the `.g6` carrier above.
fn strokeGroupEdge(canvas: Painter, r: Rect, radius: i32) void {
    canvas.strokeRect(r, radius, metrics.border, .g10);
}

/// A `.g10` hairline from `x0` to `x1` at `y` — the separator between
/// tile rows, picker rows, radio options, and table rows, and the rule
/// a `divider` is.
fn hairline(canvas: Painter, x0: i32, x1: i32, y: i32) void {
    canvas.line(.{ .x = x0, .y = y }, .{ .x = x1, .y = y }, 1, .g10);
}

pub fn render(app: *App, target: Canvas) void {
    app.performLayout();
    var surface = target;
    surface.appearance = app.appearance();
    const canvas: Painter = .{ .canvas = surface, .app = app };
    canvas.clear(.paper);
    var nav: ?NodeId = null;
    var indicator: ?NodeId = null;
    var notice: ?NodeId = null;
    var pane: ?NodeId = null;
    var sheet: ?NodeId = null;
    var picker: ?NodeId = null;
    var it = app.tree.children(app.tree.rootId());
    while (it.next()) |child| {
        switch (app.tree.getConst(child).?.role()) {
            .nav => nav = child,
            .icon_button => indicator = child,
            .notice => notice = child,
            .notices_pane => pane = child,
            .sheet => sheet = child,
            .picker => picker = child,
            else => drawNode(app, canvas, child),
        }
    }
    const area = layout.contentArea(&app.tree, app.viewport, app.safe_bottom);
    drawScrollIndicator(canvas, area, app.root_scroll, app.root_content_height, scrollEngaged(app, null), mirrored(app));
    // Chrome paints last: content scrolled past the area edge must sit
    // under the bottom pane, never over it. The nav has no pane to sit
    // under any more — only its items, each on a plate of its own — so
    // what shows between them is the page still going, which is the
    // point (see `layout.contentArea`).
    if (notice) |n| {
        drawNode(app, canvas, n);
    } else {
        if (nav) |n| drawNode(app, canvas, n);
        if (indicator) |n| drawNode(app, canvas, n);
    }
    // Each modal layer arrives over a scrim of its own, in the order
    // they may stack: a picker opened from a sheet dims the sheet too.
    if (pane) |p| drawOverScrim(app, canvas, p);
    if (sheet) |s| drawOverScrim(app, canvas, s);
    if (picker) |p| drawOverScrim(app, canvas, p);
    app.needs_frame = false;
}

/// A modal layer and the scrim under it: a paper checkerboard that
/// visibly mutes the inert layer without leaving the thirteen grays.
fn drawOverScrim(app: *App, canvas: Painter, layer: NodeId) void {
    canvas.dither(.{ .x = 0, .y = 0, .w = app.viewport.w, .h = app.viewport.h }, .paper);
    drawNode(app, canvas, layer);
}

/// The notice banner's surface — the last bottom pane that draws one,
/// the nav having given its ground up for its items. A banner is a
/// surface holding words, so it keeps what the nav dropped: rounded top
/// corners when narrower than the viewport, extended past the bottom so
/// the clip squares off the lower edge. The .g6 outline is the WCAG
/// 1.4.11 boundary — carried
/// by the top hairline alone at full width, where side borders would
/// only hug the screen edge; the body extends past the sides so the
/// clip removes them. The fill also bleeds through `safe_bottom` to
/// the physical edge — the band holds no content, only surface.
fn drawPaneChrome(app: *App, canvas: Painter, r: Rect, fill: Gray) void {
    const full = r.w >= app.viewport.w;
    const radius: i32 = if (full) 0 else metrics.radius_card;
    const side: i32 = if (full) metrics.border else 0;
    const body: Rect = .{
        .x = r.x - side,
        .y = r.y,
        .w = r.w + 2 * side,
        .h = r.h + app.safe_bottom + metrics.radius_card,
    };
    canvas.pushClip(paneClipRect(app, r));
    canvas.fillRect(body, radius, fill);
    canvas.strokeRect(body, radius, metrics.border, .g6);
    canvas.popClip();
}

fn drawNode(app: *App, canvas: Painter, id: NodeId) void {
    const el = app.tree.getConst(id) orelse return;
    const r = app.tree.rectOf(id);
    const focused = if (app.focused) |f| f.on(id) else false;
    // The drawn indicator is origin-gated (`App.focus_visible`):
    // keyboard focus shows it, a tap's does not. `focused` itself is
    // not gated — the caret, the engaged scroll bar, and the picker
    // row's under-finger highlight are focus *state*, wanted whichever
    // input put it there. Text fields keep their whole indicator on
    // `focused` too: an element taking text input shows its focus
    // regardless of origin (the :focus-visible carve-out every UA
    // ships), and its thickened edge is where the caret lives.
    const ring = focused and app.focus_visible;

    switch (el.*) {
        .text, .heading => {
            const run = el.textRun().?;
            if (run.spans.len == 0)
                drawWrapped(app, canvas, r, run.face, run.scale, run.content, run.ink)
            else
                drawSpanWrapped(app, canvas, r, run.face, run.scale, run.content, run.spans, run.ink);
            drawLinkFocusRing(app, canvas, id);
        },
        .icon => |ic| drawIcon(app, canvas, r, ic),
        .divider => hairline(canvas, r.x, r.right(), r.y),
        .badge => |b| {
            strokeGroupEdge(canvas, r, metrics.radius);
            canvas.drawText(
                r.x + metrics.border + metrics.badge_pad_h,
                r.y + metrics.border + metrics.badge_pad_v + text.Scale.small.baseline(),
                .prose,
                text.Scale.small.px(),
                b.label,
                .ink,
            );
        },
        .meter => |m| drawMeter(app, canvas, r, m),
        .qr => |q| drawQr(app, canvas, r, q),
        .stack, .list, .document => drawChildren(app, canvas, id),
        .blockquote => {
            // A 1px rule down the leading edge, the full height of what
            // is quoted, in the grouping tone: a quote is structure,
            // never state. The left/right branch is explicit because the
            // rule is an edge, not a centered block.
            const rx = if (mirrored(app)) r.right() - metrics.border else r.x;
            canvas.fillRect(.{ .x = rx, .y = r.y, .w = metrics.border, .h = r.h }, 0, .g10);
            drawChildren(app, canvas, id);
        },
        .list_item => {
            drawListMarker(app, canvas, id, r);
            drawChildren(app, canvas, id);
        },
        .box => |b| {
            if (b.fill) |f| canvas.fillRect(r, metrics.radius_card, f);
            if (b.border) strokeGroupEdge(canvas, r, metrics.radius_card);
            drawChildren(app, canvas, id);
        },
        // A folded action is not on the row any more (see
        // `Button.folded`): the `more` beside it is what stands there.
        .button => |b| if (!b.folded) drawButton(app, canvas, r, b, ring),
        // Drawn *as* one of the buttons it stands among — the same
        // outlined pill, the same geometry — so the row keeps reading as
        // one row. Quiet emphasis on purpose: it is the way to the
        // actions, never one of them.
        .more => drawButton(app, canvas, r, .{
            .label = element_mod.more_label,
            .icon = .ellipsis,
            .secondary = true,
        }, ring),
        .link => |l| if (!l.folded) {
            canvas.drawText(r.x, r.y + text.Scale.body.baseline(), .prose, text.Scale.body.px(), l.label, .ink);
            const uy = r.bottom() - 1;
            canvas.line(.{ .x = r.x, .y = uy }, .{ .x = r.right(), .y = uy }, 1, .ink);
            if (ring) drawFocusRing(canvas, r, metrics.radius);
        },
        .toggle => |t| drawToggle(app, canvas, r, t, ring),
        .checkbox => |c| drawCheckbox(app, canvas, r, c, ring),
        .text_input => |inp| drawTextInput(app, canvas, r, inp, focused),
        .text_area => |area| drawTextArea(app, canvas, r, area, focused),
        .select => |sel| drawSelect(app, canvas, r, sel, ring),
        .copyable => |c| drawCopyable(app, canvas, r, id, c, ring),
        .table => drawTable(app, canvas, id, r),
        .code_block => |cb| {
            drawCodeBlock(app, canvas, r, cb, focused or scrollEngaged(app, id));
            if (ring) drawFocusRing(canvas, r, metrics.radius);
        },
        .row, .cell => drawChildren(app, canvas, id),
        .segmented => |s| {
            drawSegmented(app, canvas, r, s, focused or scrollEngaged(app, id));
            if (ring) drawFocusRing(canvas, r, metrics.radius);
        },
        .tile_group => |tg| drawTileGroup(app, canvas, id, r, tg),
        .tile => |t| drawTile(app, canvas, id, r, t, ring),
        .radio_group => |rg| drawRadioGroup(app, canvas, r, rg, ring),
        .picker => |p| if (p.above_nav) drawNavMenu(app, canvas, id, r) else {
            canvas.pushClip(paneClipRect(app, r));
            drawModalSurface(app, canvas, r, p.title, 0);
            drawChildren(app, canvas, id);
            drawPickerSeparators(app, canvas, id);
            canvas.popClip();
        },
        .picker_item => |item| drawPickerItem(app, canvas, r, item, focused),
        // No ground, no border, no track: the nav is its items and
        // nothing else. What used to be a pane is now only the box they
        // are arranged in — the page runs on behind and between them.
        .nav => drawChildren(app, canvas, id),
        .nav_item => |n| drawNavItem(app, canvas, r, n, ring),
        .nav_current => |n| drawNavCurrent(app, canvas, r, n, ring),
        .nav_here => |n| drawNavHere(app, canvas, r, n),
        .sheet => |s| {
            canvas.pushClip(paneClipRect(app, r));
            // The header corner is reserved for the close control.
            drawModalSurface(app, canvas, r, s.title, metrics.touch_target + 8);
            drawChildren(app, canvas, id);
            canvas.popClip();
        },
        .sheet_close => {
            drawGlyph(app, canvas, r, element_mod.Glyph.dismiss.utf8(), .ink);
            if (ring) drawFocusRing(canvas, r, metrics.radius);
        },
        .back => drawBack(app, canvas, r, ring),
        .icon_button => |ib| drawIconButton(app, canvas, id, r, ib, ring),
        .notice => |n| drawNotice(app, canvas, id, r, n),
        .notices_pane => {
            canvas.pushClip(paneClipRect(app, r));
            // The header corner is reserved for the minimize control.
            drawModalSurface(app, canvas, r, "Notices", 2 * metrics.touch_target + metrics.icon_gap);
            drawChildren(app, canvas, id);
            canvas.popClip();
        },
        .scroll_region => |sr| {
            canvas.pushClip(r);
            drawChildren(app, canvas, id);
            canvas.popClip();
            drawScrollIndicator(canvas, r, sr.offset, sr.content_height, focused or scrollEngaged(app, id), mirrored(app));
            if (ring) drawFocusRing(canvas, r, metrics.radius);
        },
    }
}

/// shadcn tables: the grid is horizontal separators only — no outer
/// border, no vertical rules — laid down under the rows, whose header
/// draws its ink one step back in `mid`.
fn drawTable(app: *App, canvas: Painter, id: NodeId, r: Rect) void {
    var first = true;
    var grid = app.tree.children(id);
    while (grid.next()) |row| {
        if (!first) hairline(canvas, r.x, r.right(), app.tree.rectOf(row).y - 1);
        first = false;
    }
    var rows = app.tree.children(id);
    while (rows.next()) |row| {
        const rel = app.tree.getConst(row) orelse continue;
        var row_canvas = canvas;
        if (rel.* == .row and rel.row.header) row_canvas.text_ink = .mid;
        drawNode(app, row_canvas, row);
    }
}

/// The border wraps only the rows; a description hangs below it, dimmed
/// at the small scale like a tile's detail.
fn drawTileGroup(app: *App, canvas: Painter, id: NodeId, r: Rect, tg: element_mod.TileGroup) void {
    const desc_h = layout.tileGroupDescHeight(app.measurer, tg.description, r.w);
    const box: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h - desc_h };
    strokeGroupEdge(canvas, box, metrics.radius_card);
    drawChildren(app, canvas, id);
    drawTileSeparators(app, canvas, id);
    if (desc_h == 0) return;
    const caption: Rect = .{ .x = r.x, .y = box.bottom() + metrics.input_label_gap, .w = r.w, .h = desc_h };
    drawWrapped(app, canvas, caption, .prose, .small, tg.description, .dark);
}

/// The collapsed nav's section list: the tile group's card, not the
/// modal pane's surface. It floats clear of every edge, so all four of
/// its corners are its own and all four are drawn — where the pane
/// bleeds its fill through `safe_bottom` and lets the clip square off
/// the lower edge, which is a bottom-anchored move that turns into a
/// hard-edged tail the moment the surface stops short of the frame.
///
/// The title goes with the pane. "Sections" named a dialog that arrived
/// from nowhere; a card standing on the chip is named by the chip. The
/// string stays on the element, where it is still what a screen reader
/// is told this layer is called.
///
/// `.g6`, not the group edge's `.g10`: this is the boundary between the
/// live layer and the dimmed one under it, the same WCAG 1.4.11 call
/// `drawModalSurface` makes, and the scrim it is read against is paper
/// dithered over content rather than plain paper.
/// The clip is the card's own rect and nothing more — where the panes
/// clip to `paneClipRect` so their fill can reach past the frame. It is
/// still doing the panes' other job: a row is drawn at the width layout
/// gave it, and a section name longer than the cap
/// (`layout.navMenuInnerWidth`) would otherwise run out through the edge.
fn drawNavMenu(app: *App, canvas: Painter, id: NodeId, r: Rect) void {
    canvas.pushClip(r);
    canvas.fillRect(r, metrics.radius_card, .paper);
    canvas.strokeRect(r, metrics.radius_card, metrics.border, .g6);
    drawChildren(app, canvas, id);
    drawPickerSeparators(app, canvas, id);
    canvas.popClip();
}

/// One option row. The current choice is a dim chip on paper, its state
/// carried by the boundary as everywhere else. Focus reuses that chip
/// geometry — the indicator on the row's own edge, replacing the border
/// — instead of the outset ring, which would collide with the
/// separators and the picker's own border.
///
/// The nav's sections keep their glyphs here: the row is the same
/// destination the bar would have drawn, and a mark that appeared in
/// only one of the two shapes would be a mark nobody could learn.
fn drawPickerItem(app: *App, canvas: Painter, r: Rect, item: element_mod.PickerItem, focused: bool) void {
    if (item.selected) canvas.fillRect(r, metrics.radius, .g11);
    if (focused) {
        drawFocusEdge(canvas, r, metrics.radius);
    } else if (item.selected) {
        strokeStateEdge(canvas, r, metrics.radius);
    }
    const ink: Gray = if (item.selected) .ink else .dark;
    const avail = r.w - 2 * metrics.tile_pad_h;
    if (item.icon) |ic| {
        const gw = layout.navItemWidth(app.measurer, ic, item.label);
        drawNavGroup(app, canvas, r, ic, item.label, ink, startX(app, r.x + metrics.tile_pad_h, avail, gw), metrics.tile_pad_v);
    } else {
        const baseline = r.y + metrics.tile_pad_v + text.Scale.body.baseline();
        drawLeading(app, canvas, r.x + metrics.tile_pad_h, avail, baseline, .prose, text.Scale.body.px(), item.label, ink);
    }
}

/// The Back control. Armed by the edge pan, releasing now goes back:
/// the mark changes and nothing else does — a chevron points the way
/// navigation goes, an arrow *is* the going, so the armed state reads as
/// the outcome it promises rather than as a button being held. It is the
/// same swap `copy_glyph` → `copy_check` makes for `App.ack`: on a glyph
/// control the mark is the state, and a ground under it would be the one
/// painted edge on the screen sitting outside the text column (the
/// target hangs into the page margin so the glyph can line up — see
/// layout's `layoutRow`).
///
/// A latch, not motion: one repaint as the threshold is crossed, one as
/// it is crossed back (input.zig's `handleEdgePan`). It is drawn at all
/// because a threshold that is only felt is no threshold on a device
/// with haptics off. Both marks point back along the reading direction.
fn drawBack(app: *App, canvas: Painter, r: Rect, focused: bool) void {
    const armed = if (app.back_gesture) |g| g.armed else false;
    const glyph = if (armed)
        (if (mirrored(app)) element_mod.back_arrow_rtl else element_mod.back_arrow)
    else
        (if (mirrored(app)) element_mod.back_chevron_rtl else element_mod.back_chevron);
    drawGlyph(app, canvas, r, glyph, .ink);
    if (focused) drawFocusRing(canvas, r, metrics.radius);
}

/// The minimized-notices indicator shares the nav's bar, and the bar has
/// no ground: standing there it plates itself on the same `.g11` a
/// destination does, being one more thing in that row, and takes the
/// destinations' corner — a circle, being a pill as tall as it is wide —
/// so the bar reads as one family of shapes. Inside the notices pane
/// there is already a surface under it, so a plate would only be a smudge.
fn drawIconButton(app: *App, canvas: Painter, id: NodeId, r: Rect, ib: element_mod.IconButton, focused: bool) void {
    const in_bar = if (app.tree.parentOf(id)) |p| p.eql(app.tree.rootId()) else false;
    const radius: i32 = if (in_bar) @divTrunc(r.h, 2) else metrics.radius;
    if (in_bar) canvas.fillRect(r, radius, .g11);
    drawGlyph(app, canvas, r, ib.glyph.utf8(), .ink);
    if (focused) drawFocusRing(canvas, r, radius);
}

/// One notice, as the banner or as a row of the pane. The banner is a
/// surface of its own; a row inside the pane already has one under it,
/// so the dim track carries it instead.
fn drawNotice(app: *App, canvas: Painter, id: NodeId, r: Rect, n: element_mod.Notice) void {
    // A row inside the pane has a surface under it already, so it takes
    // the dim fill alone; the banner stands on the page and needs the
    // pane chrome's outline to say so. The pane holds its rows in a
    // scroll region, so the parent to test against is either
    // (`Tree.inNoticesPane`) — the DOM edition says the same thing with a
    // descendant selector, which never had to be told.
    const in_pane = if (app.tree.parentOf(id)) |p| app.tree.inNoticesPane(p) else false;
    if (in_pane) canvas.fillRect(r, metrics.radius, .g11) else drawPaneChrome(app, canvas, r, .g11);

    const col = layout.noticeTextRegion(&app.tree, id, mirrored(app));
    if (n.icon) |name| {
        // The words' column already gave the icon its slot
        // (`noticeTextBand`): a `lineHeight` square on the leading side,
        // sharing the title's first line box so the two center together.
        const box = text.Scale.body.lineHeight();
        const ix = if (mirrored(app)) col.x + col.w + metrics.icon_gap else col.x - metrics.icon_gap - box;
        drawIcon(app, canvas, .{ .x = ix, .y = r.y + metrics.notice_pad, .w = box, .h = box }, .{ .name = name });
    }
    const size = text.Scale.body.px();
    var y = r.y + metrics.notice_pad;
    var lines = layout.wrap(app.measurer, .prose, size, n.title, col.w);
    while (lines.next()) |line| {
        // The title is single-voice chrome: it anchors to the leading
        // edge of its column, like field labels.
        drawLeading(app, canvas, col.x, col.w, y + text.Scale.body.baseline(), .prose, size, line, .ink);
        y += text.Scale.body.lineHeight();
    }
    if (n.description.len > 0) {
        drawWrapped(app, canvas, .{ .x = col.x, .y = y, .w = col.w, .h = r.h }, .prose, .small, n.description, .dark);
    }
    drawChildren(app, canvas, id);
}

/// A bottom-anchored pane's clip: the layout rect plus the safe band
/// beneath it, so the surface fill can reach the physical edge while
/// content stays clipped to the rect the band was excluded from.
fn paneClipRect(app: *const App, r: Rect) Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h + app.safe_bottom };
}

/// The shared modal-pane surface (sheet, picker, notices pane): a paper
/// body with rounded top corners — extended past the viewport bottom so
/// the caller's clip squares off the lower edge — a .g6 outline (the
/// WCAG 1.4.11 boundary against the dimmed layer beneath), and the h2
/// title at the header edge, narrowed by `title_reserve` for a pinned
/// corner control.
fn drawModalSurface(app: *App, canvas: Painter, r: Rect, title: []const u8, title_reserve: i32) void {
    const body: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h + app.safe_bottom + metrics.radius_card };
    canvas.fillRect(body, metrics.radius_card, .paper);
    canvas.strokeRect(body, metrics.radius_card, metrics.border, .g6);
    const title_w = r.w - 2 * layout.pane_edge_h - title_reserve;
    // The pinned corner controls mirror with the chrome, so the title's
    // box steps aside on the matching side.
    const title_x = if (mirrored(app)) r.x + layout.pane_edge_h + title_reserve else r.x + layout.pane_edge_h;
    drawWrapped(app, canvas, .{ .x = title_x, .y = r.y + layout.pane_edge, .w = title_w, .h = r.h }, .prose, .h2, title, .ink);
}

/// The labeled-field prologue shared by text_input, text_area, select,
/// and copyable: the label at the small scale above a bordered field
/// that takes the rest of the rect. The label anchors to the leading
/// edge — a single-line piece of chrome, so it follows the chrome's
/// direction, not its own bytes. Returns the field.
///
/// `.g7`, not the `.g6` the compact controls use. The border is still
/// the whole affordance — an empty field has nothing else to say it can
/// be typed into, so 1.4.11 applies and `.g10` grouping is out — but a
/// field's outline is a full-width run, and the same tone that reads as
/// a hairline around a 20px radio ring reads as a heavy box at 600px.
/// `.g7` is the lightest step that still clears 3:1 against paper. The
/// compact controls cannot follow: their borders sit on the `.g11`
/// track, where `.g7` is 2.5:1 (proven in `color.zig`).
///
/// Focus takes that outline over instead of ringing it: the field keeps
/// its exact box and the boundary thickens and darkens in place. A
/// full-width field ringed at an offset carried two strokes in two
/// tones two pixels apart, which is a seam, not a state.
/// The inset from a field's outline to its content — its own padding
/// plus the border that padding sits inside.
const field_pad = metrics.input_pad + metrics.border;

fn drawFieldChrome(app: *App, canvas: Painter, r: Rect, label: []const u8, focused: bool) Rect {
    drawSmallLabel(app, canvas, r, label);
    const label_h = text.Scale.small.lineHeight();
    const field: Rect = .{
        .x = r.x,
        .y = r.y + label_h + metrics.input_label_gap,
        .w = r.w,
        .h = r.h - label_h - metrics.input_label_gap,
    };
    if (focused)
        drawFocusEdge(canvas, field, metrics.radius)
    else
        canvas.strokeRect(field, metrics.radius, metrics.border, .g7);
    return field;
}

/// The ring around a focused inline link. A link that wraps — or that a
/// bidi line splits — occupies several rects, and every one of them
/// gets a ring: one box drawn around their union would enclose the
/// unrelated prose between them and claim to be the link.
fn drawLinkFocusRing(app: *App, canvas: Painter, id: NodeId) void {
    // Origin-gated like every other drawn indicator (`App.focus_visible`).
    if (!app.focus_visible) return;
    const stop = app.focused orelse return;
    if (!stop.node.eql(id)) return;
    const span_index = stop.span orelse return;
    var buf: [layout.max_span_rects]Rect = undefined;
    for (input.spanRectsOf(app, id, span_index, &buf)) |r| {
        // Flush around the line box, not held clear of it: the lines
        // above and below leave no room for the clear, and no need for
        // it either — a line box paints nothing at its own edge but the
        // words, which is what the ring is pointing at.
        strokeRingAround(canvas, r, metrics.radius);
    }
}

/// The focus indicator: one 2px stroke in `ink`, in one of two
/// placements, and never a second line beside an existing one.
///
/// - `drawFocusEdge` — on the element's own edge, *replacing* the
///   outline it draws at rest. For the elements that own one (the
///   labeled fields, the radio-group box, an outlined button, and the
///   chips and rows packed into groups), that outline is the boundary,
///   so focus takes it over: the box does not move, it thickens and
///   darkens. Drawing both gave two strokes in two tones two pixels
///   apart, which reads as a seam, not a state.
/// - `drawFocusRing` — everything else, held `focus_clear` off the
///   rect. The clear is not decoration: two anti-aliased arcs that share
///   a boundary do not sum to full coverage, and the shortfall reads as
///   a light hairline tracing the corner, plainly visible wherever the
///   ring and what it rings are both dark (the filled button, the
///   checkbox's box). It is also why nothing here ever draws a ring
///   touching a border.
///
/// `ink` rather than the `dark` this used to be, because of the first
/// placement: WCAG 2.4.13 wants 3:1 between the focused and unfocused
/// states of the indicator's own pixels, and over a field's `g7` outline
/// `dark` is 2.8:1 in the dark ramp where `ink` is 3.5:1 (proven in
/// `color.zig`).
fn drawFocusRing(canvas: Painter, r: Rect, radius: i32) void {
    strokeRingAround(canvas, r.inset(-metrics.focus_clear), radius + metrics.focus_clear);
}

fn drawFocusEdge(canvas: Painter, r: Rect, radius: i32) void {
    canvas.strokeRect(r, radius, metrics.focus_stroke, .ink);
}

/// The band flush around `r`. Everything but a link goes through
/// `drawFocusRing`, which is this with the clear already applied.
fn strokeRingAround(canvas: Painter, r: Rect, radius: i32) void {
    canvas.strokeRect(
        r.inset(-metrics.focus_stroke),
        radius + metrics.focus_stroke,
        metrics.focus_stroke,
        .ink,
    );
}

fn drawChildren(app: *App, canvas: Painter, id: NodeId) void {
    var it = app.tree.children(id);
    while (it.next()) |child| drawNode(app, canvas, child);
}

/// An item's derived marker, in the leading band layout reserved for
/// it. The band mirrors with the chrome (`startX`), and inside it the
/// marker hugs the trailing edge of the band — flush against the words,
/// so a two-digit ordinal grows away from them and the text column
/// stays put. It rides the baseline of the item's first line, taken
/// from that line's own scale so a marker never floats off a heading-
/// sized or small-print item.
fn drawListMarker(app: *App, canvas: Painter, id: NodeId, r: Rect) void {
    const parent = app.tree.parentOf(id) orelse return;
    if (app.tree.getConst(parent).?.* != .list) return;
    const gutter = layout.listGutter(app.measurer, &app.tree, parent);
    if (gutter <= 0) return;

    // Layout derived and stamped the marker; the renderer never
    // re-derives it, so the column it measured and the glyphs drawn here
    // cannot disagree.
    const marker = app.tree.getConst(id).?.list_item.marker();
    if (marker.len == 0) return;
    const size = text.Scale.body.px();
    const mw = app.measurer.measure(.prose, size, marker);

    // The band's own leading edge, then the marker pushed to its
    // trailing end within it.
    const band_x = startX(app, r.x, r.w, gutter);
    const gap = metrics.list_marker_gap;
    const mx = if (mirrored(app)) band_x else band_x + gutter - gap - mw;
    const scale = firstLineScale(app, id);
    canvas.drawText(mx, r.y + scale.baseline(), .prose, size, marker, .ink);
}

/// The scale of an item's first line: its first text-bearing
/// descendant's, so the marker sits on the same baseline as the words
/// it introduces. Body when the item opens with something else.
fn firstLineScale(app: *App, id: NodeId) text.Scale {
    var it = app.tree.dfsUnder(id);
    while (it.next()) |n| {
        if (app.tree.getConst(n).?.textRun()) |run| return run.scale;
    }
    return .body;
}

/// Tile-group hairlines between the picker's option rows, drawn in the
/// 1px flow gap layout leaves between them, clipped like the rows.
fn drawTile(app: *App, canvas: Painter, id: NodeId, r: Rect, t: element_mod.Tile, focused: bool) void {
    // Focus reuses the picker-item pattern — the indicator on the row's
    // own edge — since an outset ring would collide with the separators
    // and the group border. Corners follow the shape they sit in: a row
    // touching the group's rounded corner curves with it (the border's
    // inner radius); corners against a hairline stay at the row radius.
    if (focused) {
        const group_id = app.tree.parentOf(id).?;
        const group = app.tree.rectOf(group_id);
        // The group's rect includes any description below the border;
        // the corner test needs the border box.
        const desc_h = layout.tileGroupDescHeight(app.measurer, app.tree.getConst(group_id).?.tile_group.description, group.w);
        const outer = metrics.radius_card - metrics.border;
        const top_radius: i32 = if (r.y == group.y + metrics.border) outer else metrics.radius;
        const bottom_radius: i32 = if (r.bottom() == group.bottom() - desc_h - metrics.border) outer else metrics.radius;
        strokeMixedRect(canvas, r, top_radius, bottom_radius, metrics.focus_stroke, .ink);
    }
    const tx = r.x + metrics.tile_pad_h;
    const inner_w = r.w - 2 * metrics.tile_pad_h;
    const ty = r.y + metrics.tile_pad_v + text.Scale.body.baseline();
    drawLeading(app, canvas, tx, inner_w, ty, .prose, text.Scale.body.px(), t.label, .ink);
    if (t.detail.len > 0) {
        const dy = r.y + metrics.tile_pad_v + text.Scale.body.lineHeight() + text.Scale.small.baseline();
        drawLeading(app, canvas, tx, inner_w, dy, .prose, text.Scale.small.px(), t.detail, .dark);
    }
    if (t.route.len > 0) {
        const size = text.Scale.body.px();
        // The chevron points where navigation goes, from the trailing edge.
        const chevron = if (mirrored(app)) element_mod.tile_chevron_rtl else element_mod.tile_chevron;
        const cw = app.measurer.measure(.icons, size, chevron);
        const cy = emCenterBaseline(r, size);
        const cx = if (mirrored(app)) r.x + metrics.tile_pad_h else r.right() - metrics.tile_pad_h - cw;
        canvas.drawText(cx, cy, .icons, size, chevron, .ink);
    }
}

/// A rounded stroke whose top and bottom corner radii differ, composed
/// from two clipped strokes that join along the straight side edges.
fn strokeMixedRect(canvas: Painter, r: Rect, top_radius: i32, bottom_radius: i32, thickness: i32, gray: Gray) void {
    if (top_radius == bottom_radius) return canvas.strokeRect(r, top_radius, thickness, gray);
    const mid = r.y + @divTrunc(r.h, 2);
    canvas.pushClip(.{ .x = r.x, .y = r.y, .w = r.w, .h = mid - r.y });
    canvas.strokeRect(r, top_radius, thickness, gray);
    canvas.popClip();
    canvas.pushClip(.{ .x = r.x, .y = mid, .w = r.w, .h = r.bottom() - mid });
    canvas.strokeRect(r, bottom_radius, thickness, gray);
    canvas.popClip();
}

/// Hairlines between tile rows; a focused row carries its own stroke,
/// so separators abutting it are skipped (as in the picker).
fn drawTileSeparators(app: *App, canvas: Painter, group: NodeId) void {
    var prev_focused = true; // no separator above the first row
    var it = app.tree.children(group);
    while (it.next()) |row| {
        const rr = app.tree.rectOf(row);
        // Gated exactly as the row's own stroke is: a separator must
        // be skipped only where a stroke is actually drawn.
        const row_focused = app.focus_visible and (if (app.focused) |f| f.on(row) else false);
        if (!prev_focused and !row_focused) {
            hairline(canvas, rr.x, rr.right(), rr.y - metrics.border);
        }
        prev_focused = row_focused;
    }
}

fn drawPickerSeparators(app: *App, canvas: Painter, picker: NodeId) void {
    var rit = app.tree.children(picker);
    const region = while (rit.next()) |c| {
        if (app.tree.getConst(c).?.role() == .scroll_region) break c;
    } else return;
    canvas.pushClip(app.tree.rectOf(region));
    var prev_chip = true; // no separator above the first row
    var it = app.tree.children(region);
    while (it.next()) |row| {
        const rr = app.tree.rectOf(row);
        // Chip rows (selected or focused) carry their own outline; a
        // hairline abutting it reads as a glitch, so skip both sides.
        // The filtered-empty "No matches" text row takes no separator.
        const el = app.tree.getConst(row).?;
        if (el.role() != .picker_item) continue;
        const chip = el.picker_item.selected or
            (if (app.focused) |f| f.on(row) else false);
        if (!prev_chip and !chip) {
            hairline(canvas, rr.x, rr.right(), rr.y - metrics.border);
        }
        prev_chip = chip;
    }
    canvas.popClip();
}

/// Tile-group geometry: a bordered card of full-width rows, one
/// hairline between them. The border groups; the circle glyphs — filled
/// in `ink` against the state edge's ring — carry the selection.
fn drawRadioGroup(app: *App, canvas: Painter, r: Rect, rg: element_mod.RadioGroup, focused: bool) void {
    drawSmallLabel(app, canvas, r, rg.label);
    const group_top = r.y + text.Scale.small.lineHeight() + metrics.input_label_gap;
    const group: Rect = .{ .x = r.x, .y = group_top, .w = r.w, .h = r.bottom() - group_top };
    // Like the labeled fields, focus takes the group box, not the label
    // — and takes it the same way, on the box's own edge. A radio group
    // is a labeled field whose control happens to be three rows, so a
    // ring floating around the card would be the odd one out.
    const edge: i32 = if (focused) metrics.focus_stroke else metrics.border;
    if (focused)
        drawFocusEdge(canvas, group, metrics.radius_card)
    else
        strokeGroupEdge(canvas, group, metrics.radius_card);
    const row_h = layout.radioRowHeight();
    const size = text.Scale.body.px();
    for (rg.options, 0..) |opt, i| {
        const row_y = r.y + layout.radioRowY(i);
        if (i > 0) {
            // Flush against whatever the box's edge currently is, so a
            // focused group's heavier edge leaves no nick at either end.
            const sep_y = row_y - metrics.border;
            canvas.line(
                .{ .x = group.x + edge, .y = sep_y },
                .{ .x = group.right() - edge, .y = sep_y },
                1,
                .g10,
            );
        }
        const glyph: Rect = .{
            .x = if (mirrored(app)) r.right() - metrics.tile_pad_h - metrics.radio_glyph else r.x + metrics.tile_pad_h,
            .y = row_y + @divTrunc(row_h - metrics.radio_glyph, 2),
            .w = metrics.radio_glyph,
            .h = metrics.radio_glyph,
        };
        const round = @divTrunc(metrics.radio_glyph, 2); // full radius: a circle
        if (i == rg.selected) {
            canvas.fillRect(glyph, round, .ink);
            const dot = glyph.inset(metrics.radio_dot_inset);
            canvas.fillRect(dot, @divTrunc(dot.w, 2), .paper);
        } else {
            strokeStateEdge(canvas, glyph, round);
        }
        const ox = if (mirrored(app))
            glyph.x - metrics.control_gap - app.measurer.measure(.prose, size, opt)
        else
            glyph.right() + metrics.control_gap;
        canvas.drawText(
            ox,
            row_y + metrics.tile_pad_v + text.Scale.body.baseline(),
            .prose,
            size,
            opt,
            .ink,
        );
    }
}

/// A verbatim block, one line per newline, no wrapping. Overflow clips
/// at the bleed edge over a 2px indicator — the same pair segmented and
/// scroll_region use.
///
/// The lines themselves never mirror. Verbatim content is defined by
/// its own bytes, like the QR symbol's modules: source is written
/// left-to-right and its leading whitespace is the structure, so
/// right-anchoring the lines under a mirrored chrome would shred the
/// indentation and put every line's *end* on screen first. So offset 0
/// shows the start of the lines in both directions, and the offset
/// always reveals rightward. What does mirror is the indicator, which
/// hugs the trailing edge like every other scroll bar here.
fn drawCodeBlock(app: *App, canvas: Painter, r: Rect, cb: element_mod.CodeBlock, engaged: bool) void {
    const size = text.Scale.body.px();
    const line_h = text.Scale.body.lineHeight();
    const window = layout.codeWindow(r, cb.bleed);
    const overflowing = cb.content_width > window.w;
    if (overflowing) canvas.pushClip(r);

    var y = r.y;
    var it = std.mem.splitScalar(u8, cb.content, '\n');
    while (it.next()) |line| {
        canvas.drawText(window.x - cb.offset, y + text.Scale.body.baseline(), .mono, size, line, .ink);
        y += line_h;
    }

    if (overflowing) {
        canvas.popClip();
        drawHScrollIndicator(app, canvas, window, r.bottom() - 2, cb.offset, cb.content_width, engaged);
    }
}

/// The sideways twin of `drawScrollIndicator`, in the same two states:
/// a 2px bar across `window`, its length the visible share of the
/// content and its position the offset within it, with `y` the top of
/// the 2px it occupies. Mirrored, the bar starts at the right end and
/// travels left, the window's trailing edge being on the left there.
fn drawHScrollIndicator(app: *const App, canvas: Painter, window: layout.Band, y: i32, offset: i32, content_w: i32, engaged: bool) void {
    const bar_w = @max(8, @divTrunc(window.w * window.w, content_w));
    const travel = @divTrunc((window.w - bar_w) * offset, content_w - window.w);
    const bar_x = if (mirrored(app)) window.x + (window.w - bar_w) - travel else window.x + travel;
    canvas.fillRect(.{ .x = bar_x, .y = y, .w = bar_w, .h = 2 }, 1, if (engaged) .g6 else .g8);
}

fn drawSegmented(app: *App, canvas: Painter, r: Rect, s: element_mod.Segmented, engaged: bool) void {
    // A bled rect reaches drawn edges on both sides; the corners square
    // off there — the band continues past the edge, like safe_bottom's
    // fill bleed — instead of rounding against nothing.
    canvas.fillRect(r, if (s.bleed > 0) 0 else metrics.radius, .g11);
    const size = text.Scale.body.px();
    const window = layout.segTrackWindow(r, s.bleed);
    const content_w = layout.segContentWidth(app.measurer, s.options);
    // Overflow scrolls: chips clip mid-chip at the bleed edge — the
    // screen for a bled track, the track pad for one boxed in (the
    // static "more here" affordance) — over a 2px indicator bar.
    const overflowing = content_w > window.w;
    // The chip band is the same height whether the track scrolls or
    // not; an overflowing rect is taller by the head above it and the
    // indicator's gutter below (see `seg_scroll_head`), so the chips
    // stand in the band rather than moving inside it.
    const head: i32 = if (overflowing) metrics.seg_scroll_head else 0;
    const band_y = r.y + head;
    const band_h = r.h - head - @as(i32, if (overflowing) metrics.seg_scroll_gutter else 0);
    if (overflowing) canvas.pushClip(if (s.bleed > 0) r else .{
        .x = window.x,
        .y = r.y,
        .w = window.w,
        .h = r.h,
    });
    // Chips run leading-to-trailing: mirrored, the first option holds
    // the right end of the window and offset reveals chips leftward —
    // the offset itself stays in content coordinates either way, so
    // clamping, reveal, and scroll state are direction-blind.
    const rtl = mirrored(app);
    var x = if (rtl) window.x + window.w + s.offset else window.x - s.offset;
    for (s.options, 0..) |opt, i| {
        const w = app.measurer.measure(.prose, size, opt) + 2 * metrics.seg_pad_h;
        if (rtl) x -= w;
        const seg: Rect = .{
            .x = x,
            .y = band_y + metrics.seg_track_pad,
            .w = w,
            .h = band_h - 2 * metrics.seg_track_pad,
        };
        const selected = i == s.selected;
        if (selected) {
            canvas.fillRect(seg, metrics.radius - metrics.seg_track_pad, .paper);
            strokeStateEdge(canvas, seg, metrics.radius - metrics.seg_track_pad);
        }
        canvas.drawText(
            seg.x + metrics.seg_pad_h,
            seg.y + metrics.seg_pad_v + text.Scale.body.baseline(),
            .prose,
            size,
            opt,
            if (selected) .ink else .dark,
        );
        if (!rtl) x += w;
    }
    if (overflowing) {
        canvas.popClip();
        // Unlike a region's bar this one is inset by the track pad
        // rather than flush at the bottom: the track is a filled band,
        // so the pad is its edge and the bar sits inside it, leaving
        // the same 2px below as above the chips. It stays in the
        // resting window, so a bled track's bar keeps the content
        // margins.
        drawHScrollIndicator(app, canvas, window, r.bottom() - metrics.seg_track_pad - 2, s.offset, content_w, engaged);
    }
}

/// One destination: a plate, its glyph, its words. The bar it used to
/// sit on is gone, so each item carries the ground it needs and no more.
///
/// The chip inverted when the track went away. It used to be `.paper`
/// lifted off a `.g11` bar; with the bar gone the destinations climb one
/// step each instead: the rest sit on the `.g11` every other dim track
/// in the library uses, and current rises to `.g10` with a border that
/// steps down to `mid` to stay legible on it. Three levels — page,
/// destination, current —
/// which is what a bar of chips wants to say and what a single elevation
/// could not.
///
/// Plating the others in `.paper` was the first attempt and read as
/// nothing at all: an item indistinguishable from the page is an item
/// nobody sees until they look for it. Marking current by ink alone was
/// the other alternative and is not one — a single step of gray, with no
/// shape behind it, is exactly the carrier WCAG 1.4.11 says cannot be
/// the whole story.
fn drawNavItem(app: *App, canvas: Painter, r: Rect, n: element_mod.NavItem, focused: bool) void {
    if (r.w == 0) return; // hidden while the banner owns the pane
    const current = if (app.router.current()) |c| std.mem.eql(u8, c, n.route) else false;
    // The plate is drawn inside the slot, half a gap in on each side,
    // so the page shows between one destination and the next. Plates
    // that met edge to edge would re-form the continuous bar the nav
    // just gave up — and the *slot* keeps its full width, so nothing a
    // thumb can land on stops being a destination.
    const plate = layout.navItemPlate(r);
    const radius = layout.navItemRadius();
    // Every item is a plate, current or not — which is also what keeps
    // the page from sliding through the words as it scrolls behind.
    canvas.fillRect(plate, radius, if (current) .g10 else .g11);
    // Focus reuses the chip geometry — the indicator on the plate's own
    // edge, replacing that border, as in the picker — instead of the
    // outset ring, which would bleed into the adjacent slots.
    if (focused) {
        drawFocusEdge(canvas, plate, radius);
    } else if (current) {
        // `mid`, not the `g6` every other chip outlines in: against a
        // g10 fill g6 is 2.7:1, under the 1.4.11 floor. The boundary
        // steps down with the surface it sits on.
        canvas.strokeRect(plate, radius, metrics.border, .mid);
    }
    const group = layout.navItemWidth(app.measurer, n.icon, n.label);
    // Centered in the slot, which is this item's own pill plus the
    // half-gap on either side — so centering on it centers on the pill.
    drawNavGroup(app, canvas, r, n.icon, n.label, if (current) .ink else .dark, r.x + @divTrunc(r.w - group, 2), metrics.nav_item_pad_v);
}

/// The row's marker for a screen that is none of the destinations: the
/// current plating, and none of the affordances.
///
/// Identical to a current `nav_item` on purpose — same plate, same
/// outline, same ink. The thing it says is "you are here", and the row
/// already has a way of saying that; a second visual language for the
/// same fact would be two things to learn. What is missing is what it
/// cannot do: no focus edge, because it takes no focus (`NavHere`).
fn drawNavHere(app: *App, canvas: Painter, r: Rect, n: element_mod.NavHere) void {
    if (r.w == 0) return; // hidden while the banner owns the pane
    const plate = layout.navItemPlate(r);
    canvas.fillRect(plate, layout.navItemRadius(), .g10);
    canvas.strokeRect(plate, layout.navItemRadius(), metrics.border, .mid);
    const group = layout.navItemWidth(app.measurer, element_mod.nav_here_icon, n.label);
    drawNavGroup(app, canvas, r, element_mod.nav_here_icon, n.label, .ink, r.x + @divTrunc(r.w - group, 2), metrics.nav_item_pad_v);
}

/// Glyph, gap, words, starting at `gx` — mirrored whole under RTL so
/// the mark stays on the leading side. The group's width is
/// `layout.navItemWidth`, the same sum the collapse threshold measures,
/// so what fits is what is drawn.
fn drawNavGroup(app: *App, canvas: Painter, r: Rect, icon: element_mod.IconName, label: []const u8, ink: Gray, gx: i32, pad_v: i32) void {
    const size = text.Scale.body.px();
    const glyph = icon.utf8();
    const gw = app.measurer.measure(.icons, size, glyph);
    const lw = app.measurer.measure(.prose, size, label);
    const total = gw + metrics.icon_gap + lw;
    const ty = r.y + pad_v + text.Scale.body.baseline();
    // The glyph centers in its em box while the label stands on its
    // baseline — an icon is not a letter, the same split `button` makes
    // for its leading mark.
    const iy = emCenterBaseline(r, size);
    if (mirrored(app)) {
        canvas.drawText(gx + total - gw, iy, .icons, size, glyph, ink);
        canvas.drawText(gx, ty, .prose, size, label, ink);
    } else {
        canvas.drawText(gx, iy, .icons, size, glyph, ink);
        canvas.drawText(gx + gw + metrics.icon_gap, ty, .prose, size, label, ink);
    }
}

/// The collapsed nav: the current section wearing the same chip its row
/// item would — glyph, words, and the chevron that says a list opens
/// above. It is always "current" — it is the only thing there — so the
/// chip is unconditional where `drawNavItem` earns it by matching the
/// router.
///
/// The group sits at the leading edge rather than centered: centering
/// would put it under the chevron at short widths, and a control that
/// opens something reads left-to-right as name-then-affordance, the way
/// `select` already does.
fn drawNavCurrent(app: *App, canvas: Painter, r: Rect, n: element_mod.NavCurrent, focused: bool) void {
    if (r.w == 0) return; // hidden while the banner owns the pane
    const radius = layout.navItemRadius();
    canvas.fillRect(r, radius, .g10);
    if (focused) {
        drawFocusEdge(canvas, r, radius);
    } else {
        canvas.strokeRect(r, radius, metrics.border, .mid);
    }
    const size = text.Scale.body.px();
    const pad = metrics.nav_item_pad_h;
    const chevron = element_mod.nav_chevron;
    const cw = app.measurer.measure(.icons, size, chevron);
    const group = layout.navItemWidth(app.measurer, n.icon, n.section);
    // Name at the leading edge, affordance at the trailing one, each
    // measured from its own side — not from a share of the width. The
    // chip is as wide as it needs now (`layout.navChipWidth`), so a
    // leftover-based placement would put both on the same edge and draw
    // the section straight through its own chevron.
    const gx = if (mirrored(app)) r.right() - pad - group else r.x + pad;
    drawNavGroup(app, canvas, r, n.icon, n.section, .ink, gx, metrics.nav_item_pad_v);
    const cx = if (mirrored(app)) r.x + pad else r.right() - pad - cw;
    canvas.drawText(cx, emCenterBaseline(r, size), .icons, size, chevron, .ink);
}

/// A quiet Lucide glyph on the ambient surface, drawn at the icon
/// family's own 24px grid; the rect around it is the touch target and
/// the focus-ring anchor, and carries the rest as padding.
fn drawGlyph(app: *App, canvas: Painter, r: Rect, bytes: []const u8, ink: Gray) void {
    const size = metrics.icon_glyph;
    const gw = app.measurer.measure(.icons, size, bytes);
    canvas.drawText(r.x + @divTrunc(r.w - gw, 2), emCenterBaseline(r, size), .icons, size, bytes, ink);
}

/// Baseline for a body line centered in a rect taller than it — the
/// checkbox and toggle rows, sized to the touch target while their
/// control and their words are one line tall, and the pill a working
/// button draws its `…` in.
fn labelBaseline(r: Rect) i32 {
    return r.y + @divTrunc(r.h - text.Scale.body.lineHeight(), 2) + text.Scale.body.baseline();
}

/// Body text centered in `r`, both ways. What a button draws while its
/// work runs: in the pill this lands on the same baseline the label had
/// (the pill's height *is* the line box plus its pad), and on a
/// glyph-form target it replaces the icon `drawGlyph` centers.
fn drawCenteredText(app: *App, canvas: Painter, r: Rect, bytes: []const u8, ink: Gray) void {
    const size = text.Scale.body.px();
    const w = app.measurer.measure(.prose, size, bytes);
    canvas.drawText(r.x + @divTrunc(r.w - w, 2), labelBaseline(r), .prose, size, bytes, ink);
}

/// Running work swaps the words for `…` — layout's own elision mark —
/// and changes nothing else: same pill, same fill, same measured size,
/// so nothing on the screen moves when the press starts or when the
/// result lands. It does not dim: `disabled` is unavailable,
/// `in_progress` is busy, and the ellipsis is the only sign the work is
/// happening. A leading icon or vendor mark stands down with the words
/// — it names the action, and the action is already underway.
fn drawButton(app: *App, canvas: Painter, r: Rect, b: element_mod.Button, focused: bool) void {
    // icon_only without an icon can't be appended; if mutation degrades
    // one, it falls back to the pill rather than vanish.
    if (b.icon_only and b.icon != null) {
        const ink: Gray = if (b.disabled) .g6 else .ink;
        // The glyph form has no pill, so the ellipsis stands on the bare
        // tap target exactly where the glyph did.
        if (b.in_progress)
            drawCenteredText(app, canvas, r, layout.ellipsis, ink)
        else
            drawGlyph(app, canvas, r, b.icon.?.utf8(), ink);
    } else {
        drawPillButton(app, canvas, r, b, focused);
    }
    // The outlined pill took its own edge inside `drawPillButton`; a
    // filled one and a bare glyph get the ring.
    if (focused and !b.secondary) drawFocusRing(canvas, r, metrics.radius);
}

/// The mark that leads a pill's label: a vendor logotype or an icon.
/// The two are mutually exclusive (`tree.validateAppend`) and sit
/// differently — the mark aligns with the *words*, standing on the text
/// baseline at cap height the way it does in the vendor's own button
/// art, while an icon centres in its em box, because an icon is not a
/// letter. Unlike a chevron a mark does NOT mirror under RTL — a
/// logotype is not directional, the same reason a QR symbol never flips
/// — but its *position* does, because leading is leading.
const Lead = struct { face: text.Face, glyph: []const u8, baseline: i32 };

fn drawPillButton(app: *App, canvas: Painter, r: Rect, b: element_mod.Button, focused: bool) void {
    const size = text.Scale.body.px();
    // A vendor sign-in button is the one place a store-facing rule
    // outranks the palette. Apple's HIG sanctions black, white, and
    // white-outlined — nothing between — so the filled brand pill draws
    // through a light-pinned canvas at `.g0`/`.g12`, the true endpoints
    // the softened `ink` and `paper` no longer reach. It still flips
    // with the appearance: the dark screen *is* Apple's white button,
    // with no second style and no palette escape hatch.
    const branded = b.provider != null and !b.secondary and !b.disabled;
    const pen = if (branded) canvas.lightPinned() else canvas;
    var fg: Gray = undefined;
    if (b.secondary) {
        // An outline is a boundary focus can take over, so a focused one
        // thickens in place and no ring is drawn — 10.6:1 where the
        // outline was 3:1, and the pill stays exactly the size it was.
        // Disabled drops to the grouping tone: 1.4.11 exempts inactive
        // components, which is the only reason it may dim at all.
        if (focused)
            drawFocusEdge(canvas, r, metrics.radius)
        else if (b.disabled)
            strokeGroupEdge(canvas, r, metrics.radius)
        else
            strokeStateEdge(canvas, r, metrics.radius);
        fg = if (b.disabled) .g6 else .ink;
    } else if (branded) {
        const on_dark = app.appearance() == .dark;
        pen.fillRect(r, metrics.radius, if (on_dark) .g12 else .g0);
        fg = if (on_dark) .g0 else .g12;
    } else {
        canvas.fillRect(r, metrics.radius, if (b.disabled) .g6 else .ink);
        fg = if (b.disabled) .g11 else .paper;
    }
    const ty = r.y + metrics.border + metrics.button_pad_v + text.Scale.body.baseline();
    const lead: ?Lead = if (b.provider) |p|
        .{ .face = .brand, .glyph = p.mark(), .baseline = ty }
    else if (b.icon) |ic|
        .{ .face = .icons, .glyph = ic.utf8(), .baseline = emCenterBaseline(r, size) }
    else
        null;
    if (b.in_progress) {
        // Centered, because `…` is not the words: it stands in the
        // middle of the pill the label sized, not at the leading pad
        // where a label starts. Centered text needs no mirroring — it is
        // already both. A known percentage takes the same slot: the mark
        // changes, the pill does not. A dimmed pill is the one ground
        // the track cannot sit on — its tones exist to be read, and
        // disabled is deliberately not for reading — so it keeps the
        // `…`, and the number still reaches assistive tech on the node.
        if (b.progress_percent != null and !b.disabled)
            drawButtonProgress(app, canvas, r, b.progress_percent.?, b.secondary)
        else
            drawCenteredText(app, pen, r, layout.ellipsis, fg);
        return;
    }
    if (mirrored(app)) {
        // The pill's contents mirror: mark leading (right), label after
        // it, walked from the trailing pad in.
        var tx = r.right() - metrics.border - metrics.button_pad_h;
        if (lead) |l| {
            tx -= app.measurer.measure(l.face, size, l.glyph);
            pen.drawText(tx, l.baseline, l.face, size, l.glyph, fg);
            tx -= metrics.icon_gap;
        }
        tx -= app.measurer.measure(.prose, size, b.label);
        pen.drawText(tx, ty, .prose, size, b.label, fg);
    } else {
        var tx = r.x + metrics.border + metrics.button_pad_h;
        if (lead) |l| {
            pen.drawText(tx, l.baseline, l.face, size, l.glyph, fg);
            tx += app.measurer.measure(l.face, size, l.glyph) + metrics.icon_gap;
        }
        pen.drawText(tx, ty, .prose, size, b.label, fg);
    }
}

/// The meter a working button draws when it knows how far along it is,
/// in the slot the `…` would have taken: `meter`'s own track geometry,
/// centered in the pill, growing from the leading edge like reading.
///
/// Two grounds, two tone pairs, and the palette picked both. On the
/// filled pill the track is `.g7` with a `.paper` fill: `g7` is the only
/// step that clears WCAG 1.4.11 (3:1) against the `ink` ground *and*
/// against the fill inside it, in both appearances — `g6` fails on the
/// ground in dark, `g8` fails on the fill. On the outlined pill the
/// ground is the ambient one, so it reuses the standalone meter's proven
/// tones exactly: a `.g11` track carrying the `.g6` boundary stroke,
/// filled in `.ink`. `renderer_test.zig` pins all of it.
fn drawButtonProgress(app: *App, canvas: Painter, r: Rect, pct: u8, on_ambient: bool) void {
    const track: Rect = .{
        .x = r.x + metrics.border + metrics.button_pad_h,
        .y = r.y + @divTrunc(r.h - metrics.meter_h, 2),
        .w = r.w - 2 * (metrics.border + metrics.button_pad_h),
        .h = metrics.meter_h,
    };
    if (track.w <= 2 * metrics.border) return; // a pill too narrow to say anything
    const round = @divTrunc(metrics.meter_h, 2);
    canvas.fillRect(track, round, if (on_ambient) .g11 else .g7);
    // The filled pill's `.g7` track already clears the ground it sits
    // on; only the ambient one needs the boundary stroke, exactly as a
    // standalone meter does.
    if (on_ambient) strokeStateEdge(canvas, track, round);
    const inner_w = track.w - 2 * metrics.border;
    const fill_w = @divTrunc(inner_w * @min(pct, 100), 100);
    if (fill_w > 0) canvas.fillRect(.{
        .x = startX(app, track.x + metrics.border, inner_w, fill_w),
        .y = track.y + metrics.border,
        .w = fill_w,
        .h = track.h - 2 * metrics.border,
    }, round, if (on_ambient) .ink else .paper);
}

/// The words beside a compact control. The control leads and the label
/// trails, both mirroring together as platform switches and boxes do.
/// The row is sized to the touch target while the control and its words
/// are one line tall, so the label centers in it rather than sitting on
/// the row's own top line.
fn drawControlLabel(app: *App, canvas: Painter, r: Rect, control_w: i32, label: []const u8) void {
    const tx = if (mirrored(app)) r.x else r.x + control_w + metrics.control_gap;
    canvas.drawText(tx, labelBaseline(r), .prose, text.Scale.body.px(), label, .ink);
}

/// An iOS-style pill switch: the knob travels toward the trailing edge
/// as it switches on, so it mirrors with the chrome.
fn drawToggle(app: *App, canvas: Painter, r: Rect, t: element_mod.Toggle, focused: bool) void {
    const track: Rect = .{
        .x = startX(app, r.x, r.w, metrics.toggle_track_w),
        .y = r.y + @divTrunc(r.h - metrics.toggle_track_h, 2),
        .w = metrics.toggle_track_w,
        .h = metrics.toggle_track_h,
    };
    const round = @divTrunc(metrics.toggle_track_h, 2);
    const side = metrics.toggle_track_h - 2 * metrics.toggle_knob_inset;
    const left_x = track.x + metrics.toggle_knob_inset;
    const right_x = track.right() - metrics.toggle_knob_inset - side;
    // The two ends are absolute; only which one `on` parks at mirrors.
    // On is the track's *trailing* end — right in LTR, left in RTL.
    const knob_x = if (t.on != mirrored(app)) right_x else left_x;
    const knob: Rect = .{ .x = knob_x, .y = track.y + metrics.toggle_knob_inset, .w = side, .h = side };
    const knob_round = @divTrunc(side, 2);
    if (t.on) {
        canvas.fillRect(track, round, .ink);
        canvas.fillRect(knob, knob_round, .paper);
    } else {
        canvas.fillRect(track, round, .g11);
        strokeStateEdge(canvas, track, round);
        canvas.fillRect(knob, knob_round, .paper);
        strokeStateEdge(canvas, knob, knob_round);
    }
    drawControlLabel(app, canvas, r, metrics.toggle_track_w, t.label);
    if (focused) drawFocusRing(canvas, r, metrics.radius);
}

fn drawCheckbox(app: *App, canvas: Painter, r: Rect, c: element_mod.Checkbox, focused: bool) void {
    const box: Rect = .{
        .x = startX(app, r.x, r.w, metrics.checkbox_box),
        .y = r.y + @divTrunc(r.h - metrics.checkbox_box, 2),
        .w = metrics.checkbox_box,
        .h = metrics.checkbox_box,
    };
    const round = @divTrunc(metrics.checkbox_box, 4);
    if (c.checked) {
        canvas.fillRect(box, round, .ink);
        const size = text.Scale.body.px();
        const mark = element_mod.checkbox_check;
        const gw = app.measurer.measure(.icons, size, mark);
        canvas.drawText(
            box.x + @divTrunc(box.w - gw, 2),
            inkCenterBaseline(box, size, 250, 791),
            .icons,
            size,
            mark,
            .paper,
        );
    } else {
        canvas.fillRect(box, round, .g11);
        strokeStateEdge(canvas, box, round);
    }
    drawControlLabel(app, canvas, r, metrics.checkbox_box, c.label);
    if (focused) drawFocusRing(canvas, r, metrics.radius);
}

/// The baseline that centers a glyph whose ink spans `top`..`bottom`
/// per mille of the em above the baseline, rather than filling it.
/// `emCenterBaseline` assumes ink centered in the em box; the marks that
/// sit inside a filled control (the checkbox's check, `copyable`'s copy
/// and check) are not, and the figures come from the lucide.ttf outline
/// points — the glyph headers' bboxes disagree and are wrong.
fn inkCenterBaseline(r: Rect, size: i32, top: i32, bottom: i32) i32 {
    return r.y + @divTrunc(r.h, 2) + @divTrunc(size * (top + bottom), 2000);
}

/// A gauge under the words that state it: a dim track carrying the
/// state edge, filled from the leading edge like reading.
fn drawMeter(app: *App, canvas: Painter, r: Rect, m: element_mod.Meter) void {
    drawSmallLabel(app, canvas, r, m.label);
    const track: Rect = .{ .x = r.x, .y = r.bottom() - metrics.meter_h, .w = r.w, .h = metrics.meter_h };
    const round = @divTrunc(metrics.meter_h, 2);
    canvas.fillRect(track, round, .g11);
    strokeStateEdge(canvas, track, round);
    if (m.max <= 0 or m.value <= 0) return;
    const inner_w = track.w - 2 * metrics.border;
    // Widened before the multiply, as `serialize.zig`'s meter is: value
    // and max are arbitrary i32, so the product can overflow i32 while
    // the quotient — at most `inner_w` — always fits.
    const fill_w: i32 = @intCast(@divTrunc(@as(i64, inner_w) * @min(m.value, m.max), m.max));
    if (fill_w > 0) canvas.fillRect(.{
        .x = startX(app, track.x + metrics.border, inner_w, fill_w),
        .y = track.y + metrics.border,
        .w = fill_w,
        .h = track.h - 2 * metrics.border,
    }, round - metrics.border, .ink);
}

/// The scannable twin of `copyable`. Scanners want maximum modulation
/// on a light ground, and a photo-negative code is a different code —
/// so the tile draws through a light-pinned canvas at the two steps the
/// design system itself no longer uses (`.g12`/`.g0`, true paper and
/// true ink) whatever the appearance. The tile snaps to the leading
/// edge; the modules inside never mirror, because a mirrored QR code
/// doesn't scan. The quiet zone is the paper margin inside the tile.
fn drawQr(app: *App, canvas: Painter, r: Rect, q: element_mod.Qr) void {
    drawSmallLabel(app, canvas, r, q.label);
    const side = layout.qrSide(q.size, r.w);
    const px = @divTrunc(side, q.size + 2 * metrics.qr_quiet);
    const tile: Rect = .{ .x = startX(app, r.x, r.w, side), .y = r.bottom() - side, .w = side, .h = side };
    const scan = canvas.lightPinned();
    scan.fillRect(tile, 0, .g12);
    var my: i32 = 0;
    while (my < q.size) : (my += 1) {
        var mx: i32 = 0;
        while (mx < q.size) {
            if (!q.module(mx, my)) {
                mx += 1;
                continue;
            }
            // Consecutive dark modules merge into one rect.
            var run: i32 = 1;
            while (mx + run < q.size and q.module(mx + run, my)) run += 1;
            scan.fillRect(.{
                .x = tile.x + (metrics.qr_quiet + mx) * px,
                .y = tile.y + (metrics.qr_quiet + my) * px,
                .w = run * px,
                .h = px,
            }, 0, .g0);
            mx += run;
        }
    }
}

fn drawIcon(app: *App, canvas: Painter, r: Rect, ic: element_mod.Icon) void {
    const size = ic.scale.px();
    const bytes = ic.name.utf8();
    const gw = app.measurer.measure(.icons, size, bytes);
    const tx = r.x + @divTrunc(r.w - gw, 2);
    const ty = r.y + @divTrunc(r.h - ic.scale.lineHeight(), 2) + ic.scale.baseline();
    canvas.drawText(tx, ty, .icons, size, bytes, ic.ink);
}

/// Draws one visual line of a resolved paragraph, pen starting at x;
/// returns the pen after. Each piece (see bidi.linePieces) is a
/// single-face, single-direction run, drawn left to right in visual
/// order with the pen advanced by its measured width.
fn drawComplexLine(app: *App, canvas: Painter, x: i32, baseline: i32, face: text.Face, size_px: i32, para: *const bidi.Paragraph, line_start: usize, line_end: usize, ink: Gray) i32 {
    var runs_buf: [bidi.max_line_runs]bidi.Run = undefined;
    var edges_buf: [bidi.max_line_edges]u32 = undefined;
    var it = bidi.linePieces(para, line_start, line_end, &runs_buf, &edges_buf);
    var pen = x;
    while (it.next()) |piece| {
        const bytes = para.bytes[piece.start..piece.end];
        canvas.drawPiece(pen, baseline, face, size_px, bytes, ink);
        pen += app.measurer.measureRun(face, size_px, bytes);
    }
    return pen;
}

fn drawWrapped(app: *App, canvas: Painter, r: Rect, face: text.Face, scale: text.Scale, content: []const u8, ink: Gray) void {
    var y = r.y;
    var it = layout.wrap(app.measurer, face, scale.px(), content, r.w);
    if (!bidi.isComplex(content)) {
        while (it.next()) |line| {
            canvas.drawText(r.x, y + scale.baseline(), face, scale.px(), line, ink);
            y += scale.lineHeight();
        }
        return;
    }
    var cursor: layout.ParagraphCursor = .{ .content = content };
    while (it.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(content.ptr);
        cursor.advanceTo(app.bidi_scratch, start);
        if (!cursor.complex) {
            canvas.drawPiece(r.x, y + scale.baseline(), face, scale.px(), line, ink);
        } else {
            // An RTL paragraph's lines start from the right margin —
            // alignment is derived from direction, not declared.
            const line_w = app.measurer.measure(face, scale.px(), line);
            const lx = if (cursor.rtl) r.x + r.w - line_w else r.x;
            _ = drawComplexLine(app, canvas, lx, y + scale.baseline(), face, scale.px(), &cursor.para, start - cursor.start, start - cursor.start + line.len, ink);
        }
        y += scale.lineHeight();
    }
}

/// `drawWrapped` for spanned text: the same lines (wrapSpans measures
/// with the same per-face widths drawn here), each decomposed into its
/// span segments — one draw call per piece, the pen advanced by the
/// measured width so drawing and measurement cannot drift apart.
fn drawSpanWrapped(app: *App, canvas: Painter, r: Rect, base: text.Face, scale: text.Scale, content: []const u8, spans: []const element_mod.Span, base_ink: Gray) void {
    var y = r.y;
    var pieces: [layout.max_line_pieces]layout.LinePiece = undefined;
    var cursor: layout.ParagraphCursor = .{ .content = content };
    var it = layout.wrapSpans(app.measurer, base, scale.px(), content, spans, r.w);
    while (it.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(content.ptr);
        cursor.advanceTo(app.bidi_scratch, start);
        const baseline = y + scale.baseline();
        const origin = if (cursor.complex and cursor.rtl)
            r.x + r.w - layout.spanLineWidth(app.measurer, base, scale.px(), content, spans, start, start + line.len)
        else
            r.x;
        const line_pieces = layout.linePieces(
            app.measurer,
            base,
            scale.px(),
            content,
            spans,
            start,
            start + line.len,
            origin,
            if (cursor.complex) &cursor.para else null,
            cursor.start,
            &pieces,
        );
        for (line_pieces) |piece| {
            const span = spans[piece.span_index];
            const ink = span.ink orelse base_ink;
            canvas.drawPiece(piece.x, baseline, span.face(base), scale.px(), piece.bytes, ink);
            // Rules are drawn piece by piece wherever the run lands:
            // pieces of one span are consecutive, so they meet and read
            // as one line across it.
            // External links draw exactly as routed ones: where a link
            // goes is semantics, not a visual variant.
            if (span.isLink()) {
                const uy = y + scale.lineHeight() - 2;
                canvas.line(.{ .x = piece.x, .y = uy }, .{ .x = piece.x + piece.w, .y = uy }, 1, ink);
            }
            // A quarter of the em above the baseline puts the rule
            // through the middle of the lowercase band, where a struck
            // word reads as struck rather than underscored twice.
            if (span.strike) {
                const sy = baseline - @divTrunc(scale.px(), 4);
                canvas.line(.{ .x = piece.x, .y = sy }, .{ .x = piece.x + piece.w, .y = sy }, 1, ink);
            }
        }
        y += scale.lineHeight();
    }
}

/// An empty field's stand-in words, dim like the punctuation they are.
/// A complex RTL placeholder starts from the right edge, like the value
/// it stands in for will.
fn drawPlaceholder(app: *App, canvas: Painter, x: i32, baseline: i32, avail_w: i32, placeholder: []const u8) void {
    const size = text.Scale.body.px();
    const px = if (bidi.isComplex(placeholder) and bidi.paragraphDirection(placeholder) == .rtl)
        x + avail_w - app.measurer.measure(.prose, size, placeholder)
    else
        x;
    canvas.drawText(px, baseline, .prose, size, placeholder, .mid);
}

fn drawTextInput(app: *App, canvas: Painter, r: Rect, inp: element_mod.TextInput, focused: bool) void {
    const field = drawFieldChrome(app, canvas, r, inp.label, focused);
    const tx = field.x + field_pad;
    const ty = field.y + field_pad + text.Scale.body.baseline();
    const size = text.Scale.body.px();
    const inner_w = field.w - 2 * field_pad;

    if (inp.value.len == 0 and inp.composition.len == 0) {
        drawPlaceholder(app, canvas, tx, ty, inner_w, inp.placeholder);
    } else if (bidi.isComplex(inp.value) and !inp.obscured and inp.composition.len == 0) {
        // Complex text draws whole — splitting at the caret would snap
        // joined letters into their standalone forms as the caret moves
        // through a word. The caret maps through the visual pieces
        // instead. (An active composition falls back to the split path:
        // the preedit must render inline at the caret, and mid-word
        // joining across an uncommitted preedit is not a stable thing to
        // promise anyway.)
        const rtl = bidi.paragraphDirection(inp.value) == .rtl;
        const vw = app.measurer.measure(.prose, size, inp.value);
        const vx = if (rtl) tx + inner_w - vw else tx;
        canvas.drawText(vx, ty, .prose, size, inp.value, .ink);
        if (focused) {
            const cx = vx + editing.caretX(app, inp.value, 0, inp.value.len, inp.cursor, size);
            canvas.line(
                .{ .x = cx, .y = field.y + field_pad },
                .{ .x = cx, .y = field.bottom() - field_pad },
                1,
                .ink,
            );
        }
    } else {
        const pre = inp.value[0..inp.cursor];
        const post = inp.value[inp.cursor..];
        var x = tx;
        x = drawRun(app, canvas, x, ty, size, pre, .ink, inp.obscured);
        if (inp.composition.len > 0) {
            const cx = drawRun(app, canvas, x, ty, size, inp.composition, .dark, inp.obscured);
            canvas.line(.{ .x = x, .y = ty + 3 }, .{ .x = cx, .y = ty + 3 }, 1, .dark);
            x = cx;
        }
        if (focused) {
            canvas.line(
                .{ .x = x, .y = field.y + field_pad },
                .{ .x = x, .y = field.bottom() - field_pad },
                1,
                .ink,
            );
        }
        _ = drawRun(app, canvas, x, ty, size, post, .ink, inp.obscured);
    }
}

/// One bullet per codepoint at a fixed advance keeps caret math exact
/// without allocating a masked copy of the value.
pub const obscure_bullet = "•";

/// Draws a run of input text, masked when obscured; returns the x after it.
fn drawRun(app: *App, canvas: Painter, x: i32, ty: i32, size: i32, bytes: []const u8, ink: Gray, obscured: bool) i32 {
    if (!obscured) {
        canvas.drawText(x, ty, .prose, size, bytes, ink);
        return x + app.measurer.measure(.prose, size, bytes);
    }
    const bw = app.measurer.measure(.prose, size, obscure_bullet);
    var bx = x;
    for (bytes) |b| {
        if (b & 0xC0 == 0x80) continue; // UTF-8 continuation byte
        canvas.drawText(bx, ty, .prose, size, obscure_bullet, ink);
        bx += bw;
    }
    return bx;
}

/// One wrapped line of a text area, resolved against its hard paragraph
/// (never the line alone — sos/eos context at a soft wrap would differ
/// from what editing.caretX computes for the same line).
fn drawAreaLine(app: *App, canvas: Painter, x: i32, baseline: i32, size: i32, value: []const u8, span: editing.LineSpan, ink: Gray) void {
    const pstart = if (std.mem.lastIndexOfScalar(u8, value[0..span.start], '\n')) |i| i + 1 else 0;
    const pend = std.mem.indexOfScalarPos(u8, value, span.end, '\n') orelse value.len;
    const pb = value[pstart..pend];
    if (!bidi.isComplex(pb)) {
        canvas.drawPiece(x, baseline, .prose, size, value[span.start..span.end], ink);
        return;
    }
    const para = bidi.resolve(app.bidi_scratch, pb, bidi.paragraphDirection(pb));
    _ = drawComplexLine(app, canvas, x, baseline, .prose, size, &para, span.start - pstart, span.end - pstart, ink);
}

fn drawTextArea(app: *App, canvas: Painter, r: Rect, area: element_mod.TextArea, focused: bool) void {
    const field = drawFieldChrome(app, canvas, r, area.label, focused);
    const size = text.Scale.body.px();
    const line_h = text.Scale.body.lineHeight();
    const tx = field.x + field_pad;
    const inner_w = field.w - 2 * field_pad;

    if (area.value.len == 0 and area.composition.len == 0) {
        drawPlaceholder(app, canvas, tx, field.y + field_pad + text.Scale.body.baseline(), inner_w, area.placeholder);
        return;
    }

    if (bidi.isComplex(area.value) and area.composition.len == 0) {
        // Complex text: whole-line drawing (no caret split — see
        // drawTextInput), per-paragraph alignment, caret mapped through
        // the visual pieces. An active composition falls back below.
        var y = field.y + field_pad;
        var caret_drawn = false;
        var last_span: editing.LineSpan = .{ .start = 0, .end = 0 };
        var it = layout.wrap(app.measurer, .prose, size, area.value, inner_w);
        while (it.next()) |line| {
            const start = @intFromPtr(line.ptr) - @intFromPtr(area.value.ptr);
            const span: editing.LineSpan = .{ .start = start, .end = start + line.len };
            const ty = y + text.Scale.body.baseline();
            const origin = tx + editing.lineOriginX(app, area.value, span, inner_w);
            drawAreaLine(app, canvas, origin, ty, size, area.value, span, .ink);
            if (focused and !caret_drawn and area.cursor <= span.end) {
                // caretX resolves the same paragraph drawText just did;
                // the scratch reuse is benign because the resolve is
                // identical.
                const cx = origin + editing.caretX(app, area.value, span.start, span.end, area.cursor, size);
                canvas.line(.{ .x = cx, .y = y }, .{ .x = cx, .y = y + line_h }, 1, .ink);
                caret_drawn = true;
            }
            last_span = span;
            y += line_h;
        }
        if (focused and !caret_drawn) {
            // Cursor rides in trailing hanging whitespace past the last line.
            const origin = tx + editing.lineOriginX(app, area.value, last_span, inner_w);
            const cx = origin + editing.caretX(app, area.value, last_span.start, area.value.len, area.cursor, size);
            canvas.line(.{ .x = cx, .y = y - line_h }, .{ .x = cx, .y = y }, 1, .ink);
        }
        return;
    }

    var y = field.y + field_pad;
    var caret_drawn = false;
    var last_start: usize = 0;
    var it = layout.wrap(app.measurer, .prose, size, area.value, field.w - 2 * field_pad);
    while (it.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(area.value.ptr);
        const end = start + line.len;
        const ty = y + text.Scale.body.baseline();
        if (focused and !caret_drawn and area.cursor <= end) {
            const pre = area.value[start..area.cursor];
            canvas.drawText(tx, ty, .prose, size, pre, .ink);
            var cx = tx + app.measurer.measure(.prose, size, pre);
            if (area.composition.len > 0) {
                canvas.drawText(cx, ty, .prose, size, area.composition, .dark);
                const cw = app.measurer.measure(.prose, size, area.composition);
                canvas.line(.{ .x = cx, .y = ty + 3 }, .{ .x = cx + cw, .y = ty + 3 }, 1, .dark);
                cx += cw;
            }
            canvas.line(.{ .x = cx, .y = y }, .{ .x = cx, .y = y + line_h }, 1, .ink);
            canvas.drawText(cx, ty, .prose, size, area.value[area.cursor..end], .ink);
            caret_drawn = true;
        } else {
            canvas.drawText(tx, ty, .prose, size, line, .ink);
        }
        last_start = start;
        y += line_h;
    }
    if (focused and !caret_drawn) {
        // Cursor rides in trailing hanging whitespace past the last line.
        const cx = tx + app.measurer.measure(.prose, size, area.value[last_start..area.cursor]);
        canvas.line(.{ .x = cx, .y = y - line_h }, .{ .x = cx, .y = y }, 1, .ink);
    }
}

fn drawSelect(app: *App, canvas: Painter, r: Rect, sel: element_mod.Select, focused: bool) void {
    const field = drawFieldChrome(app, canvas, r, sel.label, focused);
    const size = text.Scale.body.px();
    const ty = field.y + field_pad + text.Scale.body.baseline();
    if (sel.selected < sel.options.len) {
        const opt = sel.options[sel.selected];
        drawLeading(app, canvas, field.x + field_pad, field.w - 2 * field_pad, ty, .prose, size, opt, .ink);
    }
    const chevron = element_mod.select_chevron;
    const cw = app.measurer.measure(.icons, size, chevron);
    const cx = if (mirrored(app)) field.x + field_pad else field.right() - field_pad - cw;
    const cy = emCenterBaseline(field, size);
    canvas.drawText(cx, cy, .icons, size, chevron, .ink);
}

fn drawCopyable(app: *App, canvas: Painter, r: Rect, id: NodeId, c: element_mod.Copyable, focused: bool) void {
    const field = drawFieldChrome(app, canvas, r, c.label, focused);
    const size = text.Scale.body.px();
    const ty = field.y + field_pad + text.Scale.body.baseline();
    // The acknowledgement: this field's activation was the last thing
    // that happened, so the affordance stands in as a check until the
    // next input takes it back (see `App.ack`).
    const acked = if (app.ack) |a| a.eql(id) else false;
    const copy_w = app.measurer.measure(.icons, size, element_mod.copy_glyph);
    const check_w = app.measurer.measure(.icons, size, element_mod.copy_check);
    const glyph = if (acked) element_mod.copy_check else element_mod.copy_glyph;
    const gw = if (acked) check_w else copy_w;
    // Verbatim values read in mono; the copy glyph is the affordance,
    // sitting where select's chevron does. The glyph's slot is reserved
    // at the wider of the two marks, so the value's room is a property
    // of the field and not of what happened to it: swapping the copy
    // glyph for the check must never reflow — let alone re-elide — the
    // value underneath. A value that would run under the slot elides in
    // the middle instead: the display is a receipt, not the value's
    // channel (activation copies the whole value, semantics announce it
    // whole). The marker draws dim like placeholder text: mono ink here
    // must stay readable as verbatim, so the field's own punctuation
    // steps back. The value anchors to the leading edge; the glyph holds
    // the trailing slot on either side.
    const avail = field.w - 2 * field_pad - @max(copy_w, check_w) - metrics.icon_gap;
    if (layout.elideMiddle(app.measurer, .mono, size, c.value, avail)) |e| {
        const head_w = app.measurer.measure(.mono, size, c.value[0..e.head_end]);
        const ell_w = app.measurer.measure(.mono, size, layout.ellipsis);
        const tail_w = app.measurer.measure(.mono, size, c.value[e.tail_start..]);
        var x = startX(app, field.x + field_pad, avail, head_w + ell_w + tail_w);
        canvas.drawText(x, ty, .mono, size, c.value[0..e.head_end], .ink);
        x += head_w;
        canvas.drawText(x, ty, .mono, size, layout.ellipsis, .mid);
        x += ell_w;
        canvas.drawText(x, ty, .mono, size, c.value[e.tail_start..], .ink);
    } else {
        const vw = app.measurer.measure(.mono, size, c.value);
        canvas.drawText(startX(app, field.x + field_pad, avail, vw), ty, .mono, size, c.value, .ink);
    }
    // Each mark centers on its *own* ink, as `checkbox` does. Sharing
    // one figure would make the mark jump vertically as it swaps.
    const gy = if (acked) inkCenterBaseline(field, size, 250, 791) else inkCenterBaseline(field, size, 42, 959);
    const gx = if (mirrored(app)) field.x + field_pad else field.right() - field_pad - gw;
    canvas.drawText(gx, gy, .icons, size, glyph, .ink);
}

/// The two indicator states: .g6 while the surface is engaged —
/// focused, touch-locked, or the last thing scrolling input moved
/// (see `App.scroll_hot`) — .g8 at rest. The overlay scrollbar's
/// prominent-when-relevant behavior rebuilt on state instead of time:
/// with no timers there is no fade, so emphasis latches until the
/// next non-scroll input. The resting bar may sit under the 3:1
/// non-text boundary tone because it is a redundant cue there: at
/// rest, overflow is announced by content clipped mid-element — the
/// audit's cleanly_clipped_scroll_region rule keeps that cut visible.
fn drawScrollIndicator(canvas: Painter, r: Rect, offset: i32, content_h: i32, engaged: bool, rtl: bool) void {
    if (content_h <= r.h) return;
    const bar_h = @max(8, @divTrunc(r.h * r.h, content_h));
    const max_offset = content_h - r.h;
    const bar_y = r.y + @divTrunc((r.h - bar_h) * offset, max_offset);
    // The bar hugs the trailing edge — where a platform scrollbar sits,
    // which mirrors with the chrome.
    const bar_x = if (rtl) r.x else r.right() - 2;
    canvas.fillRect(.{ .x = bar_x, .y = bar_y, .w = 2, .h = bar_h }, 1, if (engaged) .g6 else .g8);
}

/// Whether a scroll surface owns the current engagement: the live
/// touch lock or the emphasis latch. `null` asks about the window.
/// Keyboard focus also engages, but only elements know their focus —
/// callers add it.
fn scrollEngaged(app: *const App, id: ?NodeId) bool {
    if (app.scroll_gesture) |g| {
        if (id) |i| {
            if (g.region) |reg| if (reg.eql(i)) return true;
            if (g.horizontal) |h| if (h.eql(i)) return true;
        } else if (g.region == null) return true;
    }
    return switch (app.scroll_hot) {
        .none => false,
        .window => id == null,
        .node => |n| if (id) |i| n.eql(i) else false,
    };
}
