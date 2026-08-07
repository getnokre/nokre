//! The scroll chain: vertical regions chaining out to the window, the
//! horizontal scrollers (segmented tracks, verbatim blocks), the
//! gesture lock a touch drag holds across events, and the keyboard's
//! root scrolling. Split from input.zig the way editing.zig and
//! overlays.zig were: free functions over `*App`, dispatched from
//! there.

const std = @import("std");
const app_mod = @import("app.zig");
const event_mod = @import("event.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;
const Point = geometry.Point;

/// The targets a touch drag locked at `.begin` (see event.zig
/// `ScrollPhase`); held on the App so the lock spans events.
pub const ScrollGesture = struct {
    /// Vertical owner: a scroll region, or null — the window.
    region: ?NodeId,
    /// Horizontal owner: the overflowing track or verbatim block under
    /// the initial touch.
    horizontal: ?NodeId,
};

pub fn handleScroll(app: *App, s: event_mod.Scroll) void {
    switch (s.phase) {
        .begin => {
            app.scroll_gesture = .{
                .region = gestureRegionAt(app, s.at),
                .horizontal = hScrollTargetAt(app, s.at),
            };
            // The finger that is about to scroll was pressing something
            // a moment ago: a shell brackets a touch drag only once its
            // recognizer has decided, so this is where "that was a
            // scroll, not a tap" is expressed — once, here, instead of
            // five times in five shells.
            app.press = null;
            return;
        },
        .end => {
            app.scroll_gesture = null;
            return;
        },
        .move, .free => {},
    }
    // A scroll moves one axis at a time: the dominant delta wins
    // and the minor one is hand jitter, dropped. Ties go vertical,
    // the primary scroll direction. Dominance is per event, even
    // inside a gesture — the lock fixes the targets, not the axis.
    var dx = s.delta_x;
    var dy = s.delta_y;
    if (@abs(dy) >= @abs(dx)) dx = 0 else dy = 0;
    if (s.phase == .move) {
        // A `.move` whose `.begin` was never delivered falls through
        // to free routing rather than being dropped.
        if (app.scroll_gesture) |g| {
            if (dx != 0) if (g.horizontal) |id| scrollHorizontallyBy(app, id, dx);
            if (dy != 0) scrollGestureVertical(app, g.region, dy);
            return;
        }
    }
    if (dx != 0) if (hScrollTargetAt(app, s.at)) |id| scrollHorizontallyBy(app, id, dx);
    // Unconsumed delta chains outward: region → enclosing regions → window.
    // An open modal keeps the window (and everything under the scrim) still.
    var remaining = dy;
    var node = innermostRegionAt(app, s.at);
    while (node) |id| : (node = app.tree.parentOf(id)) {
        if (app.tree.getConst(id).?.role() != .scroll_region) continue;
        remaining -= scrollRegionBy(app, id, remaining);
        if (remaining == 0) return;
    }
    if (!layout.modalOpen(&app.tree)) scrollRootBy(app, remaining);
}

/// The deepest scroll region in the active layer whose visible geometry
/// contains `at`, whether or not it has anything to scroll. Where a
/// vertical scroll starts, both for a locked gesture and a free one.
fn innermostRegionAt(app: *App, at: Point) ?NodeId {
    var found: ?NodeId = null;
    var it = app.tree.dfsUnder(app.focusScope());
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() != .scroll_region) continue;
        if (!input.visibleRect(app, id).contains(at)) continue;
        found = id;
    }
    return found;
}

/// The region a touch drag starting at `at` locks to: the innermost
/// scroll region under the point with content to scroll, else the
/// nearest enclosing one that has, else null — the window. A region
/// whose content fits cannot own a gesture; a native scroll view in
/// its place would not even track it.
fn gestureRegionAt(app: *App, at: Point) ?NodeId {
    var node = innermostRegionAt(app, at);
    while (node) |id| : (node = app.tree.parentOf(id)) {
        const el = app.tree.getConst(id).?;
        if (el.role() != .scroll_region) continue;
        if (el.scroll_region.content_height > app.tree.rectOf(id).h) return id;
    }
    return null;
}

/// One vertical step of a locked gesture: the owner consumes what it
/// can and the rest dies at its clamp (there is no rubber band to
/// spend it on). Chaining here would yank the enclosing scroller the
/// moment the region ran dry — the mid-gesture jump the lock exists
/// to prevent.
fn scrollGestureVertical(app: *App, region: ?NodeId, delta: i32) void {
    if (region) |id| {
        // The tree can be rebuilt mid-gesture; a stale or reused id
        // releases the delta rather than scrolling a stranger.
        const el = app.tree.getConst(id) orelse return;
        if (el.role() != .scroll_region) return;
        _ = scrollRegionBy(app, id, delta);
        return;
    }
    if (!layout.modalOpen(&app.tree)) scrollRootBy(app, delta);
}

/// Horizontal scroll goes to the deepest sideways scroller under the
/// pointer — an overflowing segmented track or a verbatim block. The
/// sideways sibling of the vertical region chain, with no outward
/// chaining: two horizontal scrollers never nest.
fn hScrollTargetAt(app: *App, at: Point) ?NodeId {
    var target: ?NodeId = null;
    var it = app.tree.dfsUnder(app.focusScope());
    while (it.next()) |id| {
        switch (app.tree.getConst(id).?.role()) {
            .segmented, .code_block => {},
            else => continue,
        }
        if (!input.visibleRect(app, id).contains(at)) continue;
        target = id;
    }
    return target;
}

pub fn scrollHorizontallyBy(app: *App, id: NodeId, delta: i32) void {
    const el = app.tree.get(id) orelse return;
    switch (el.*) {
        .segmented => |*s| {
            const inner_w = layout.segTrackWindow(app.tree.rectOf(id), s.bleed).w;
            const max_offset = layout.segContentWidth(app.measurer, s.options) - inner_w;
            if (max_offset <= 0) return;
            // The offset counts revealed content from the leading edge,
            // so a rightward drag that advances an LTR track rewinds a
            // mirrored one.
            const d = if (app.direction == .rtl) -delta else delta;
            setHOffset(app, id, &s.offset, std.math.clamp(s.offset + d, 0, max_offset));
        },
        // A verbatim block's lines do not mirror (see drawCodeBlock),
        // so its offset does not either: the drag always moves the
        // content the way the finger goes.
        .code_block => |*cb| {
            const max_offset = cb.content_width - layout.codeWindow(app.tree.rectOf(id), cb.bleed).w;
            if (max_offset <= 0) return;
            setHOffset(app, id, &cb.offset, std.math.clamp(cb.offset + delta, 0, max_offset));
        },
        else => {},
    }
}

fn setHOffset(app: *App, id: NodeId, offset: *i32, new_offset: i32) void {
    if (new_offset == offset.*) return;
    offset.* = new_offset;
    app.scroll_hot = .{ .node = id };
    app.needs_frame = true;
}

/// Scrolls an overflowing track minimally so the selected chip is
/// fully visible. Called at selection changes; free scrolling in
/// between is left where the user put it.
pub fn revealSegSelected(app: *App, id: NodeId) void {
    const el = app.tree.get(id) orelse return;
    const s = &el.segmented;
    const inner_w = layout.segTrackWindow(app.tree.rectOf(id), s.bleed).w;
    const content_w = layout.segContentWidth(app.measurer, s.options);
    if (content_w <= inner_w) return;
    const chip = layout.segChipSpan(app.measurer, s.options, s.selected);
    var offset = std.math.clamp(s.offset, 0, content_w - inner_w);
    if (chip.x + chip.w > offset + inner_w) offset = chip.x + chip.w - inner_w;
    if (chip.x < offset) offset = chip.x;
    s.offset = std.math.clamp(offset, 0, content_w - inner_w);
    app.needs_frame = true;
}

pub fn handleRootScrollKey(app: *App, key: event_mod.Key) void {
    if (layout.modalOpen(&app.tree)) return; // background is inert
    const line = text.Scale.body.lineHeight();
    const page = layout.contentArea(&app.tree, app.viewport, app.safe_bottom, app.medium).h;
    switch (key) {
        .up => scrollRootBy(app, -line),
        .down => scrollRootBy(app, line),
        .page_up => scrollRootBy(app, -(page - line)),
        .page_down => scrollRootBy(app, page - line),
        .home => scrollRootBy(app, -app.root_content_height),
        .end => scrollRootBy(app, app.root_content_height),
        else => {},
    }
}

/// Returns the consumed part of `delta`; the rest hit a clamp.
pub fn scrollRegionBy(app: *App, id: NodeId, delta: i32) i32 {
    const el = app.tree.get(id) orelse return delta;
    const sr = &el.scroll_region;
    const max_offset = @max(0, sr.content_height - app.tree.rectOf(id).h);
    const new_offset = std.math.clamp(sr.offset + delta, 0, max_offset);
    const consumed = new_offset - sr.offset;
    sr.offset = new_offset;
    // Movement arms the emphasis latch — whatever caused it, including
    // a focus reveal: the indicator marks the surface that just moved.
    if (consumed != 0) app.scroll_hot = .{ .node = id };
    app.needs_frame = true;
    app.layout_dirty = true;
    return consumed;
}

pub fn scrollRootBy(app: *App, delta: i32) void {
    const limit = layout.contentArea(&app.tree, app.viewport, app.safe_bottom, app.medium).h;
    const max_offset = @max(0, app.root_content_height - limit);
    const new_offset = std.math.clamp(app.root_scroll + delta, 0, max_offset);
    if (new_offset != app.root_scroll) app.scroll_hot = .window;
    app.root_scroll = new_offset;
    app.needs_frame = true;
    app.layout_dirty = true;
}
