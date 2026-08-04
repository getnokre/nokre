//! Pointer and keyboard interaction: hit testing, activation, focus
//! reveal, and the one gesture — the edge pan that goes back.
//! Everything arrives through `App.dispatch`; text-field editing is
//! delegated to editing.zig, the modal layers to overlays.zig, the
//! scroll chain to scrolling.zig.

const app_mod = @import("app.zig");
const editing = @import("editing.zig");
const element_mod = @import("element.zig");
const event_mod = @import("event.zig");
const focus = @import("focus.zig");
const geometry = @import("geometry.zig");
const haptic = @import("../services/haptic/haptic.zig");
const layout = @import("layout.zig");
const wrap = @import("wrap.zig");
const nav_mod = @import("nav.zig");
const notices = @import("notices.zig");
const open_url = @import("../services/open_url/open_url.zig");
const overflow_mod = @import("overflow.zig");
const overlays = @import("overlays.zig");
const scrolling = @import("scrolling.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;
const Point = geometry.Point;

// ---- the pointer ----

/// A press in flight: what it landed on, and what the release owes it.
/// Null between presses.
pub const Press = struct {
    /// The focus stop under the press, or null when it landed on
    /// nothing — dead space, or a modal's scrim.
    stop: ?focus.Focus = null,
    /// The press landed outside an open modal layer. Only such a press
    /// may dismiss one, so a drag that starts inside a sheet and
    /// finishes past its edge does not close what it was using.
    scrim: bool = false,
    /// This press opened the collapsed nav's section picker, so it owns
    /// the menu until it lets go: motion moves the focused row and the
    /// release chooses one. Set for the nav chip and nothing else — a
    /// `select` opens its picker on release and is chosen by a second
    /// press, exactly as before.
    opened_nav_picker: bool = false,
    /// The acknowledgement mark as it stood when the finger went down.
    /// A tap is two events now, and the mark an activation "found" is
    /// the one from the press — read again at the release it would
    /// always look cleared, and copying the same value twice would
    /// re-arm the check instead of toggling it off (`App.ack`).
    ack_before: ?NodeId = null,
};

pub fn handlePointer(app: *App, p: event_mod.Pointer) !void {
    switch (p.phase) {
        .down => try pressDown(app, p.at),
        .move => pressMove(app, p.at),
        .up => try pressUp(app, p.at),
        // The recognizer lost the touch or the window lost capture:
        // whatever the press was going to do, it does not do it.
        .cancel => app.press = null,
    }
}

/// Whether the control at `p` needs the raw pointer stream — a press,
/// its motion, and its release as separate events — rather than the
/// tap a touch recognizer reports once it has decided.
///
/// Touch shells ask this at touch-down and route that one gesture
/// accordingly (`wants_pointer_stream` in shell.h). It is the same
/// bargain `wants_text_input` strikes: the shell asks a question at
/// press time and core owns the answer, so no shell learns what a nav
/// is or when a menu is open. Answering false everywhere would leave
/// every touch shell behaving exactly as it did before this existed.
///
/// Today exactly one control says yes — the collapsed nav's chip, whose
/// press opens the section list the same press can then choose from
/// (docs/elements.md#navigation-chrome). Anything that says yes is
/// taking on the whole burden of that gesture: no recognizer will
/// arbitrate it against scrolling, so it had better be chrome with
/// nothing scrollable beneath it.
pub fn wantsPointerStream(app: *App, p: Point) bool {
    const r = pointerStreamRect(app) orelse return false;
    return r.contains(p);
}

/// The same answer as geometry: the region that wants the raw stream, or
/// null when none does. Both forms come from this one so no shell can be
/// told something a different shell would not be.
///
/// It exists because not every shell can ask a synchronous question at
/// touch-down: the web shell runs core in a worker, so the main thread
/// is handed this rect after every frame and answers from it locally.
pub fn pointerStreamRect(app: *App) ?geometry.Rect {
    app.performLayout();
    // Inert under an open layer — a menu, a sheet, the notices pane. A
    // press on the chip then belongs to the scrim, which closes what is
    // open rather than reopening it.
    if (!app.focusScope().eql(app.tree.rootId())) return null;
    const nav = layout.findNav(&app.tree) orelse return null;
    var it = app.tree.children(nav);
    const child = it.next() orelse return null;
    if (app.tree.getConst(child).?.role() != .nav_current) return null;
    const r = app.tree.rectOf(child);
    // Zero-sized while the notices banner owns the bottom pane.
    return if (r.w == 0 or r.h == 0) null else r;
}

/// A tap: press and release at one point. What a touch recognizer
/// reports, and what the a11y default action and tests send for a
/// control they cannot drag to.
pub fn tap(app: *App, p: Point) !void {
    try app.dispatch(.{ .pointer = .{ .at = p, .phase = .down } });
    try app.dispatch(.{ .pointer = .{ .at = p, .phase = .up } });
}

/// Records the press and moves focus to it — what every platform's own
/// pointer does, and the reason the focus ring appears the instant a
/// control is held rather than when it is let go. Nothing activates
/// here; `pressUp` decides (WCAG 2.5.2).
fn pressDown(app: *App, at: Point) !void {
    app.press = .{ .scrim = onScrim(app, at), .ack_before = app.ack };
    if (app.press.?.scrim) return;
    const stop = hitTest(app, at) orelse return;
    app.press.?.stop = stop;
    app.focused = stop;
    // Pointer-origin focus: the finger knows where it pressed, so the
    // drawn indicator stands down until the keyboard moves focus again
    // (`App.focus_visible`).
    app.focus_visible = false;
    app.needs_frame = true;
    // The one control that acts on the press rather than the release,
    // and it is not activation: the menu opens under the finger so the
    // same press can travel to a row and choose it on release, the way
    // a menu bar has always worked. Nothing is committed here — letting
    // go somewhere harmless still commits nothing.
    if (app.tree.getConst(stop.node).?.role() == .nav_current) {
        try overlays.openNavPicker(app, stop.node);
        app.press.?.opened_nav_picker = true;
    }
}

/// Motion only matters to a press already holding the section menu, and
/// only to move *focus* to the row under it — the state the arrow keys
/// move, drawn the way they draw it, announced the way they announce
/// it. Nothing else on screen follows the pointer (docs/introduction.md
/// on why there is no hover).
fn pressMove(app: *App, at: Point) void {
    const press = app.press orelse return;
    if (!press.opened_nav_picker) return;
    if (layout.findPicker(&app.tree) == null) return;
    const stop = hitTest(app, at) orelse return;
    if (app.tree.getConst(stop.node).?.role() != .picker_item) return;
    if (app.focused) |f| {
        if (f.eql(stop)) return; // already there; no frame to ask for
    }
    app.focused = stop;
    // Still the finger: the row under it draws its focus state (the
    // menu highlight is focus, not a ring), but the origin stays
    // pointer for whatever is focused when the menu closes.
    app.focus_visible = false;
    app.needs_frame = true;
    revealFocused(app);
}

/// The release decides. Landing where the press landed activates;
/// landing anywhere else abandons it silently — that is the abort a
/// press-time activation could not offer, and it is why moving off a
/// control before letting go is the universal "never mind".
fn pressUp(app: *App, at: Point) !void {
    const press = app.press orelse return;
    app.press = null;
    if (press.scrim) {
        // Still outside on release: dismiss with pointer parity to Esc.
        if (onScrim(app, at)) dismissLayer(app);
        return;
    }
    if (press.opened_nav_picker) return navRelease(app, press, at);
    const stop = press.stop orelse {
        // Tap-out: the press began on nothing and the release still
        // lands on nothing. If an editable held focus this clears it —
        // the one gesture a touch user has to put the on-screen
        // keyboard away, since the shell drops it through the existing
        // `wants_text_input` sync the moment no editable is focused.
        // Only an editable: clearing a button's focus for a stray tap
        // would throw a keyboard user's place away for nothing. A
        // scroll that claimed the finger never gets here (the press is
        // cleared at scroll `.begin`), so a drag is not a tap-out.
        if (hitTest(app, at) == null) blurEditable(app);
        return;
    };
    const now = hitTest(app, at) orelse return;
    if (!now.eql(stop)) return;
    app.needs_frame = true;
    const target = stop.node;
    if (stop.span == null) {
        // Both pick by coordinate, and the coordinate that counts is
        // where the finger left — the segment you release over is the
        // one you chose.
        if (app.tree.getConst(target).?.role() == .segmented) {
            selectSegmentAt(app, target, at.x);
            return;
        }
        if (app.tree.getConst(target).?.role() == .radio_group) {
            selectRadioAt(app, target, at.y);
            return;
        }
    }
    try activateStop(app, stop);
}

/// Where a press that opened the section menu lets go, and what that
/// means. Three outcomes, and the middle one is what makes the drag an
/// addition rather than a replacement: releasing back on the chip
/// **leaves the menu open**, so the same control also works as
/// press-then-tap for anyone who does not drag — a keyboard user, a
/// screen-reader user, or anyone who simply clicked.
fn navRelease(app: *App, press: Press, at: Point) void {
    if (layout.findPicker(&app.tree) == null) return;
    if (hitTest(app, at)) |stop| {
        if (app.tree.getConst(stop.node).?.role() == .picker_item) {
            return overlays.closePicker(app, overlays.pickerIndexOf(app, stop.node));
        }
    }
    if (press.stop) |chip| {
        // The chip is outside the picker's focus scope now, so this is
        // a rect test rather than a hit test.
        if (app.tree.getConst(chip.node) != null and app.tree.rectOf(chip.node).contains(at)) return;
    }
    // Anywhere else: the same "never mind" a release off a button is.
    overlays.closePicker(app, null);
}

/// Clears focus from a focused `text_input` or `text_area` — the
/// tap-out above, and nothing else. Core clears the state; shells learn
/// only that `wants_text_input` went false, which is what dismisses the
/// on-screen keyboard without any shell knowing why.
fn blurEditable(app: *App) void {
    const stop = app.focused orelse return;
    const el = app.tree.getConst(stop.node) orelse return;
    switch (el.*) {
        .text_input, .text_area => {},
        else => return,
    }
    app.focused = null;
    app.needs_frame = true;
}

/// Whether `p` falls outside the open modal layer — on the scrim, where
/// a press means "leave this".
fn onScrim(app: *App, p: Point) bool {
    const layer = layout.topModalLayer(&app.tree) orelse return false;
    return !app.tree.rectOf(layer).contains(p);
}

/// Leaves the open layer the way Esc does: the picker closes without
/// committing, the sheet dismisses, the notices pane minimizes with its
/// notices still pending.
fn dismissLayer(app: *App) void {
    const layer = layout.topModalLayer(&app.tree) orelse return;
    switch (app.tree.getConst(layer).?.role()) {
        .picker => overlays.closePicker(app, null),
        .sheet => overlays.dismissSheet(app),
        .notices_pane => notices.minimizeNotices(app),
        // topModalLayer returns nothing else.
        else => unreachable,
    }
}

/// Deepest focus stop in the active layer whose visible
/// (scroll-clipped) geometry contains p. Anything outside an open sheet
/// is inert and cannot be hit. A link span is hit through the very
/// rects the renderer underlined — `wrap.spanRects` is the one walk
/// both consult — so a link that wraps is tappable on every line it
/// crosses and nowhere in between.
pub fn hitTest(app: *App, p: Point) ?focus.Focus {
    var best: ?focus.Focus = null;
    var it = app.tree.dfsUnder(app.focusScope());
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (focus.hasLinkSpans(el.*)) {
            if (linkSpanAt(app, id, p)) |span| best = .{ .node = id, .span = span };
            continue;
        }
        if (!el.isFocusable()) continue;
        if (visibleRect(app, id).contains(p)) best = .of(id);
    }
    return best;
}

/// Which link span of `id` (if any) `p` lands on.
fn linkSpanAt(app: *App, id: NodeId, p: Point) ?u16 {
    const clip = visibleRect(app, id);
    if (!clip.contains(p)) return null;
    const spans = focus.spansOf(app.tree.getConst(id).?.*);
    var buf: [wrap.max_span_rects]geometry.Rect = undefined;
    for (spans, 0..) |span, i| {
        if (!span.isLink()) continue;
        for (spanRectsOf(app, id, @intCast(i), &buf)) |r| {
            if (r.intersect(clip).contains(p)) return @intCast(i);
        }
    }
    return null;
}

/// Activates a focus stop: an inline link navigates, anything else
/// activates as its element. Public because a backend that resolves
/// its own hits delivers stops rather than points (`App.deliver`).
pub fn activateStop(app: *App, stop: focus.Focus) !void {
    const span_index = stop.span orelse return activate(app, stop.node);
    const el = app.tree.getConst(stop.node) orelse return;
    const spans = focus.spansOf(el.*);
    if (span_index >= spans.len) return;
    const span = spans[span_index];
    if (span.route) |route| {
        // The router resolves the name, so a bad one fails as
        // `error.UnknownRoute` exactly where every other bad route does —
        // the parser needs no router access to stay honest.
        app.needs_frame = true;
        try app.navigate(route);
    } else if (span.external) |url| {
        // The scheme passed the allowlist at append, so this cannot
        // fail; the screen does not change — the browser is where the
        // press lands — so no frame is requested.
        try open_url.open(app, url);
    }
}

pub fn visibleRect(app: *App, id: NodeId) geometry.Rect {
    var r = app.tree.rectOf(id);
    var parent = app.tree.parentOf(id);
    while (parent) |pid| : (parent = app.tree.parentOf(pid)) {
        const el = app.tree.getConst(pid).?;
        switch (el.role()) {
            // A sheet clips like a viewport: overflow past its cap is
            // invisible, so it must not be tappable either.
            .scroll_region, .sheet, .notices_pane, .picker => r = r.intersect(app.tree.rectOf(pid)),
            else => {},
        }
    }
    // Content scrolled under chrome must not steal its taps.
    if (!inChrome(app, id)) r = r.intersect(layout.contentArea(&app.tree, app.viewport, app.safe_bottom));
    return r;
}

fn inChrome(app: *App, id: NodeId) bool {
    var cur: ?NodeId = id;
    while (cur) |c| : (cur = app.tree.parentOf(c)) {
        switch (app.tree.getConst(c).?.role()) {
            .nav, .notice, .notices_pane, .icon_button, .sheet, .picker => return true,
            else => {},
        }
    }
    return false;
}

/// Activates an element exactly as a tap or Enter would.
pub fn activate(app: *App, id: NodeId) !void {
    const el = app.tree.get(id) orelse return;
    app.needs_frame = true;
    // Read before the action runs: it may navigate, and afterwards
    // there is no telling which layer the press came from (overflow.zig).
    const tail_sheet = overflow_mod.tailSheetOf(app, id);
    switch (el.*) {
        .button => |b| {
            // Work already running swallows the press: the button is
            // still focused and still takes Enter, and the whole point
            // of the state is that the second press does not start the
            // action a second time.
            if (!b.disabled and !b.in_progress) b.on_press.invoke();
        },
        // Running work swallows the press here for the same reason it
        // does above: the switch keeps its stop and still takes Enter,
        // and a second flip would start the action a second time —
        // against a value that has not landed yet.
        .toggle => |*t| if (!t.in_progress) {
            t.on = !t.on;
            t.on_toggle.invoke(t.on);
        },
        .checkbox => |*c| if (!c.in_progress) {
            c.checked = !c.checked;
            c.on_toggle.invoke(c.checked);
        },
        .link => |l| if (l.external) |url| try open_url.open(app, url) else try app.navigate(l.route),
        .tile => |t| if (t.route.len > 0) try app.navigate(t.route) else t.on_press.invoke(),
        .sheet_close => overlays.dismissSheet(app),
        .back => try app.navigateBack(),
        .icon_button => |ib| try activateIcon(app, id, ib.glyph),
        .select => try overlays.openPicker(app, id),
        .nav_current => try overlays.openNavPicker(app, id),
        .copyable => |c| {
            app.copyText(c.value);
            // Arming is all this does; `App.dispatch` owns the release,
            // so activation stays one direction (see `App.ack`).
            app.ack = id;
        },
        .picker_item => overlays.closePicker(app, overlays.pickerIndexOf(app, id)),
        .nav_item => |n| {
            // A push, not a switch: crossing to another destination is a
            // move like any other, and the trail that led to it is worth
            // the same as any other trail. The framework's Back control
            // and every shell's back road then reach the section you
            // came from, which is what a visitor who crossed by mistake
            // reaches for. Standing on it already is the one no-op.
            if (!nav_mod.isCurrent(app, n.route)) try app.router.push(app, n.route);
            // The row usually survives the rebuild, but crossing the
            // on/off-roster boundary resyncs the chrome and `id` names
            // a dead generation — so the keyboard user's place is
            // re-found in the row standing there now, the same move
            // `overlays.closePicker` makes for the chip. The pressed
            // destination is current after the push, which is how its
            // row is recognized without the old node's strings.
            app.focused = if (layout.findNav(&app.tree)) |nav| blk: {
                var it = app.tree.children(nav);
                while (it.next()) |c| {
                    const item = app.tree.getConst(c).?;
                    if (item.* == .nav_item and nav_mod.isCurrent(app, item.nav_item.route)) break :blk .of(c);
                }
                break :blk null;
            } else null;
        },
        .text_input => |*i| {
            i.cursor = i.value.len;
        },
        .text_area => |*a| {
            a.cursor = a.value.len;
        },
        .more => try overflow_mod.presentMoreSheet(app, id),
        else => {},
    }
    if (tail_sheet) |sheet| overflow_mod.closeTailSheet(app, sheet);
}

/// Icon controls carry their behavior in the glyph: chrome cannot
/// be miswired.
fn activateIcon(app: *App, id: NodeId, glyph: element_mod.Glyph) !void {
    switch (glyph) {
        .expand => try notices.openNoticesPane(app),
        .minimize => notices.minimizeNotices(app),
        .open => {
            const idx = notices.noticeIndexOf(app, id) orelse return;
            const route = app.notices.items[idx].route;
            // Deep-link: minimize (the notice stays pending), then go.
            notices.minimizeNotices(app);
            try app.navigate(route);
            // Keyboard users land back on the reopen control.
            app.focused = if (layout.findIndicator(&app.tree)) |i| .of(i) else null;
        },
        .dismiss => {
            const idx = notices.noticeIndexOf(app, id) orelse return;
            notices.dismissNoticeAt(app, idx);
        },
        .dismiss_all => notices.dismissAllNotices(app),
    }
}

fn selectSegmentAt(app: *App, id: NodeId, px: i32) void {
    const el = app.tree.get(id) orelse return;
    const s = &el.segmented;
    if (s.options.len == 0) return;
    const r = app.tree.rectOf(id);
    const window = layout.segTrackWindow(r, s.bleed);
    // Chips run leading-to-trailing; the walk mirrors exactly as the
    // renderer's does, so taps land on what was drawn.
    const rtl = app.direction == .rtl;
    var cx = if (rtl) window.x + window.w + s.offset else window.x - s.offset;
    var idx: usize = s.options.len - 1;
    for (s.options, 0..) |opt, i| {
        const w = app.measurer.measure(.prose, text.Scale.body.px(), opt) + 2 * layout.metrics.seg_pad_h;
        if (rtl) {
            if (px >= cx - w) {
                idx = i;
                break;
            }
            cx -= w;
        } else {
            if (px < cx + w) {
                idx = i;
                break;
            }
            cx += w;
        }
    }
    selectOption(app, id, idx);
}

/// Commit option `index` of an exclusive-choice control.
///
/// The semantic form of the two geometric walks above, and the one an
/// edition that resolves hits for itself calls instead of them — the
/// DOM edition's browser knows which chip was pressed without any rect
/// being consulted (see render/dom/live.zig). Selection commits
/// immediately either way: radiogroup semantics say a move *is* the
/// choice, and there is no submit to wait for.
pub fn selectOption(app: *App, id: NodeId, index: usize) void {
    const el = app.tree.get(id) orelse return;
    app.needs_frame = true;
    switch (el.*) {
        .segmented => |*s| {
            if (index >= s.options.len or index == s.selected) return;
            s.selected = index;
            // A chip chosen where it clips at the track edge scrolls
            // fully into view.
            scrolling.revealSegSelected(app, id);
            s.on_select.invoke(index);
        },
        .radio_group => |*rg| {
            if (index >= rg.options.len or index == rg.selected) return;
            rg.selected = index;
            rg.on_select.invoke(index);
        },
        .select => |*sel| {
            if (index >= sel.options.len or index == sel.selected) return;
            sel.selected = index;
            sel.on_select.invoke(index);
        },
        else => {},
    }
}

fn selectRadioAt(app: *App, id: NodeId, py: i32) void {
    const el = app.tree.get(id) orelse return;
    const rg = &el.radio_group;
    if (rg.options.len == 0) return;
    const r = app.tree.rectOf(id);
    var idx: usize = rg.options.len - 1;
    var i: usize = 0;
    while (i + 1 < rg.options.len) : (i += 1) {
        if (py < r.y + layout.radioRowY(i + 1)) {
            idx = i;
            break;
        }
    }
    selectOption(app, id, idx);
}

// ---- keys ----

pub fn handleKey(app: *App, key: event_mod.Key, mods: event_mod.Modifiers) !void {
    app.needs_frame = true;
    // Keyboard interaction reveals the focus indicator — for the focus
    // a key moves directly (Tab, arrows) and for wherever a key-driven
    // activation lands it (Enter opening a picker, choosing a section).
    // Set once here rather than at each of those, so no key path can
    // leave keyboard focus invisible (`App.focus_visible`).
    app.focus_visible = true;
    switch (key) {
        .tab => {
            const scope = app.focusScope();
            var next = if (mods.shift)
                focus.prevFocusable(&app.tree, scope, app.focused)
            else
                focus.nextFocusable(&app.tree, scope, app.focused);
            // While the banner owns the bottom pane the nav is hidden
            // and must be unreachable by keyboard too.
            if (layout.findNotice(&app.tree) != null) {
                if (layout.findNav(&app.tree)) |nav| {
                    var hops: usize = 0;
                    while (next) |stop| : (hops += 1) {
                        // Every stop the walk can reach is inside the
                        // hidden nav: keeping the current focus beats
                        // parking it on a control nobody can see.
                        if (hops > app.tree.nodes.items.len) return;
                        if (!app.tree.isDescendant(stop.node, nav)) break;
                        next = if (mods.shift)
                            focus.prevFocusable(&app.tree, scope, stop)
                        else
                            focus.nextFocusable(&app.tree, scope, stop);
                    }
                }
            }
            app.focused = next;
            revealFocused(app);
            return;
        },
        .escape => {
            // An in-progress composition claims Esc first — the
            // picker's filter field composes like any input.
            const composing = if (editing.focusedEditable(app)) |e| e.composition.len > 0 else false;
            if (!composing and layout.findPicker(&app.tree) != null) {
                overlays.closePicker(app, null);
                return;
            }
            if (!composing and layout.findSheet(&app.tree) != null) {
                overlays.dismissSheet(app);
                return;
            }
            if (!composing and layout.findNoticesPane(&app.tree) != null) {
                notices.minimizeNotices(app);
                return;
            }
        },
        else => {},
    }

    const stop = app.focused orelse {
        scrolling.handleRootScrollKey(app, key);
        return;
    };
    const focused_id = stop.node;
    const el = app.tree.get(focused_id) orelse {
        app.focused = null;
        return;
    };

    switch (el.*) {
        .text_input => |*inp| try editing.handleInputKey(app, inp, key),
        .text_area => |*area| try editing.handleAreaKey(app, focused_id, area, key),
        // ←/→ move the selection the way it looks: toward the pressed
        // arrow. Mirrored chrome lays options right-to-left, so the
        // arrows swap roles with it (↑/↓ in radio groups do not — the
        // vertical axis never mirrors).
        .segmented => |*s| switch (key) {
            .left, .right => {
                const forward = (key == .right) != (app.direction == .rtl);
                if (forward) {
                    if (s.selected + 1 < s.options.len) {
                        s.selected += 1;
                        scrolling.revealSegSelected(app, focused_id);
                        s.on_select.invoke(s.selected);
                    }
                } else if (s.selected > 0) {
                    s.selected -= 1;
                    scrolling.revealSegSelected(app, focused_id);
                    s.on_select.invoke(s.selected);
                }
            },
            else => scrolling.handleRootScrollKey(app, key),
        },
        .radio_group => |*rg| switch (key) {
            .up, .down, .left, .right => {
                const forward = switch (key) {
                    .down => true,
                    .up => false,
                    .right => app.direction != .rtl,
                    .left => app.direction == .rtl,
                    else => unreachable,
                };
                if (forward) {
                    if (rg.selected + 1 < rg.options.len) {
                        rg.selected += 1;
                        rg.on_select.invoke(rg.selected);
                    }
                } else if (rg.selected > 0) {
                    rg.selected -= 1;
                    rg.on_select.invoke(rg.selected);
                }
            },
            else => scrolling.handleRootScrollKey(app, key),
        },
        // ←/→ walk the hidden columns; everything else falls through to
        // the page, so a focused block never traps the scroll keys.
        // The step is four mono advances — a code indent, the unit the
        // content is actually written in.
        .code_block => switch (key) {
            .left, .right => {
                const step = 4 * app.measurer.measure(.mono, text.Scale.body.px(), " ");
                scrolling.scrollHorizontallyBy(app, focused_id, if (key == .right) step else -step);
            },
            else => scrolling.handleRootScrollKey(app, key),
        },
        .picker_item => switch (key) {
            .up => overlays.movePickerFocus(app, focused_id, -1),
            .down => overlays.movePickerFocus(app, focused_id, 1),
            .enter, .space => try activateStop(app, stop),
            else => {},
        },
        .scroll_region => |sr| {
            const line = text.Scale.body.lineHeight();
            const h = app.tree.rectOf(focused_id).h;
            switch (key) {
                .up => _ = scrolling.scrollRegionBy(app, focused_id, -line),
                .down => _ = scrolling.scrollRegionBy(app, focused_id, line),
                .page_up => _ = scrolling.scrollRegionBy(app, focused_id, -(h - line)),
                .page_down => _ = scrolling.scrollRegionBy(app, focused_id, h - line),
                .home => _ = scrolling.scrollRegionBy(app, focused_id, -sr.content_height),
                .end => _ = scrolling.scrollRegionBy(app, focused_id, sr.content_height),
                else => {},
            }
        },
        else => switch (key) {
            .enter, .space => try activateStop(app, stop),
            else => scrolling.handleRootScrollKey(app, key),
        },
    }
}

// ---- the back gesture ----

/// A live edge pan. `armed` is the whole of it: how far the finger has
/// come is the shell's to report and nothing nokre keeps, because
/// nothing is drawn from it.
pub const BackGesture = struct { armed: bool = false };

/// How far in the pan has to travel before releasing goes back.
fn backThreshold(app: *const App) i32 {
    return @max(
        layout.metrics.back_gesture_min,
        @divTrunc(app.viewport.w, layout.metrics.back_gesture_divisor),
    );
}

/// One step of the drag that goes back (event.zig's `EdgePan`).
///
/// The shape of this is deliberate and worth stating, because the
/// obvious version of this gesture is the one nokre refuses. Nothing
/// slides. The screen does not track the finger, there is no
/// half-transitioned state to render, to describe to assistive tech, or
/// to golden — and no frame is drawn that some event did not ask for, so
/// the settle animation that would need a ticker never exists. What
/// replaces the moving screen as feedback is a *threshold*: cross it and
/// the framework knocks, cross back and it knocks again, and the Back
/// control draws engaged in between. Position decides, and only
/// position: a flick that commits below the threshold would need a
/// velocity, which needs a clock, which the deterministic core does not
/// have (docs/introduction.md).
pub fn handleEdgePan(app: *App, pan: event_mod.EdgePan) !void {
    switch (pan.phase) {
        .begin => app.back_gesture = if (eligibleForBack(app, pan.from)) .{} else null,
        .move => {
            if (app.back_gesture == null) return; // never eligible
            const g = &app.back_gesture.?;
            const threshold = backThreshold(app);
            // Hysteresis is asymmetric on purpose: it takes the full
            // distance to arm, and a retreat past the band to give it
            // up, so a finger held at the boundary settles instead of
            // rattling.
            const armed = if (g.armed)
                pan.dx > threshold - layout.metrics.back_gesture_hysteresis
            else
                pan.dx >= threshold;
            if (armed == g.armed) return;
            g.armed = armed;
            haptic.knock(app, if (armed) .armed else .disarmed);
            app.needs_frame = true;
        },
        .end => {
            const g = app.back_gesture orelse return;
            app.back_gesture = null;
            if (!g.armed) return;
            // The armed control has to stop being drawn even if the pop
            // itself changes nothing visible (a rebuild that lands on an
            // identical screen).
            app.needs_frame = true;
            try app.navigateBack();
        },
        // Not `end`: the system took the gesture away, so there is no
        // release to honour — and no knock either, because the user did
        // not do this and nothing they did was undone.
        .cancel => {
            const was_armed = if (app.back_gesture) |g| g.armed else false;
            app.back_gesture = null;
            if (was_armed) app.needs_frame = true;
        },
    }
}

/// Whether a pan from this edge may become a back at all. Answered once,
/// at `.begin`, and remembered as a null gesture for the rest of the
/// drag: a knock that promises a navigation nothing will perform is
/// worse than no feedback.
fn eligibleForBack(app: *App, from: event_mod.EdgePan.Edge) bool {
    // Nothing to go back to. `pop` would no-op at the root anyway; what
    // this prevents is the promise.
    if (app.router.depth() <= 1) return false;
    // An open overlay dismisses itself, by its own close control and its
    // own Escape. One gesture that means "back" on one layer and
    // "dismiss" on another is a gesture nobody can predict.
    if (layout.modalOpen(&app.tree)) return false;
    // Back runs against the reading direction, like the chevron the
    // Back control draws: the mirrored chrome mirrors its gesture too.
    const leading: event_mod.EdgePan.Edge = if (app.direction == .rtl) .right else .left;
    return from == leading;
}

/// Scrolls enclosing regions and the window so the focused node's
/// focus ring is visible: keyboard focus never lands offscreen.
pub fn revealFocused(app: *App) void {
    const stop = app.focused orelse return;
    const id = stop.node;
    app.performLayout();
    // The widest the indicator ever reaches past the rect: a ring held
    // clear of an element that paints its own edge, plus a pixel so it
    // is not flush against the region it was revealed into.
    const margin = layout.metrics.focus_clear + layout.metrics.focus_stroke + 1;
    // A link inside a long paragraph is revealed by its own line, not
    // by the whole paragraph: scrolling a ten-line block into view says
    // nothing about where the link in it went.
    var parent = app.tree.parentOf(id);
    while (parent) |pid| : (parent = app.tree.parentOf(pid)) {
        if (app.tree.getConst(pid).?.role() != .scroll_region) continue;
        const delta = revealDelta(focusRect(app, stop).inset(-margin), app.tree.rectOf(pid));
        if (delta != 0) {
            _ = scrolling.scrollRegionBy(app, pid, delta);
            app.performLayout();
        }
    }
    // Chrome sits at fixed positions, always visible; only content
    // participates in window scroll.
    if (inChrome(app, id)) return;
    const window = layout.contentArea(&app.tree, app.viewport, app.safe_bottom);
    const delta = revealDelta(focusRect(app, stop).inset(-margin), window);
    if (delta != 0) scrolling.scrollRootBy(app, delta);
}

/// The rect keyboard focus should bring into view: the element's, or —
/// for an inline link — the first of the rects it actually occupies.
fn focusRect(app: *App, stop: focus.Focus) geometry.Rect {
    const span_index = stop.span orelse return app.tree.rectOf(stop.node);
    var buf: [wrap.max_span_rects]geometry.Rect = undefined;
    const rects = spanRectsOf(app, stop.node, span_index, &buf);
    return if (rects.len > 0) rects[0] else app.tree.rectOf(stop.node);
}

/// The rects a link span occupies, for whoever needs its geometry:
/// focus reveal here, the focus ring in the renderer, hit testing
/// above. All three read `wrap.spanRects`, so they cannot disagree.
pub fn spanRectsOf(app: *App, id: NodeId, span_index: u16, out: []geometry.Rect) []geometry.Rect {
    const el = app.tree.getConst(id) orelse return out[0..0];
    const run = el.textRun() orelse return out[0..0];
    if (span_index >= run.spans.len) return out[0..0];
    return wrap.spanRects(app.measurer, app.bidi_scratch, run.face, run.scale, run.content, run.spans, span_index, app.tree.rectOf(id), out);
}

fn revealDelta(target: geometry.Rect, viewport: geometry.Rect) i32 {
    if (target.y < viewport.y) return target.y - viewport.y;
    const overflow = target.bottom() - viewport.bottom();
    // Top edge wins when the target is taller than the viewport.
    if (overflow > 0) return @min(overflow, target.y - viewport.y);
    return 0;
}
