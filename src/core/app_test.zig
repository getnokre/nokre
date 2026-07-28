//! Tests for the App: dispatch, focus, editing, scrolling, overlays,
//! and notices — everything a shell can drive.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const event_mod = @import("event.zig");
const focus = @import("focus.zig");
const geometry = @import("geometry.zig");
const haptic = @import("../services/haptic/haptic.zig");
const input_mod = @import("input.zig");
const layout = @import("layout.zig");
const nav_mod = @import("nav.zig");
const overflow = @import("overflow.zig");
const router_mod = @import("router.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");
const test_app = @import("test_app.zig");

const App = app_mod.App;
const Element = element_mod.Element;
const NodeId = tree_mod.NodeId;

const testing = std.testing;

const PressCounter = struct {
    count: u32 = 0,
    fn onPress(ctx: ?*anyopaque) void {
        const self: *PressCounter = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
    }
};

test "tap activates a button through hit testing" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{
        .label = "Go",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });

    app.performLayout();
    const center = app.tree.rectOf(btn).center();
    try app.tap(center);

    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expect(app.focused.?.on(btn));
}

// ---- press and release (WCAG 2.5.2; docs/introduction.md) ----

fn pressCounterApp(app: *App, counter: *PressCounter) !NodeId {
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{
        .label = "Go",
        .on_press = .{ .ctx = counter, .call = PressCounter.onPress },
    } });
    app.performLayout();
    return btn;
}

fn down(app: *App, p: geometry.Point) !void {
    try app.dispatch(.{ .pointer = .{ .at = p, .phase = .down } });
}

fn up(app: *App, p: geometry.Point) !void {
    try app.dispatch(.{ .pointer = .{ .at = p, .phase = .up } });
}

test "a press does not activate; the release does" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try pressCounterApp(&app, &counter);
    const center = app.tree.rectOf(btn).center();

    try down(&app, center);
    // Focus lands on the press — that is what every platform's pointer
    // does, and why the ring appears while a control is held.
    try testing.expect(app.focused.?.on(btn));
    try testing.expectEqual(@as(u32, 0), counter.count);

    try up(&app, center);
    try testing.expectEqual(@as(u32, 1), counter.count);
}

test "a release somewhere else abandons the press" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try pressCounterApp(&app, &counter);

    try down(&app, app.tree.rectOf(btn).center());
    try up(&app, .{ .x = 399, .y = 399 }); // dead space

    // The abort a press-time activation could not offer: moving off
    // before letting go is the universal "never mind".
    try testing.expectEqual(@as(u32, 0), counter.count);
    // Focus stays where the press put it — the control was reached,
    // just not activated.
    try testing.expect(app.focused.?.on(btn));
}

test "a cancelled press activates nothing" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try pressCounterApp(&app, &counter);
    const center = app.tree.rectOf(btn).center();

    try down(&app, center);
    // The recognizer lost the touch, or the window lost capture.
    try app.dispatch(.{ .pointer = .{ .at = center, .phase = .cancel } });
    try up(&app, center);

    try testing.expectEqual(@as(u32, 0), counter.count);
}

test "a scroll claiming the finger cancels the press under it" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try pressCounterApp(&app, &counter);
    const center = app.tree.rectOf(btn).center();

    try down(&app, center);
    // A shell brackets a touch drag once its recognizer decides; the
    // press that started it must not also activate what it began on.
    try app.dispatch(.{ .scroll = .{ .at = center, .delta_y = 0, .phase = .begin } });
    try up(&app, center);

    try testing.expectEqual(@as(u32, 0), counter.count);
}

test "only a press that began on the scrim dismisses a sheet" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sheet = try app.presentSheet("Filter");
    _ = try app.tree.append(sheet, .{ .toggle = .{ .label = "Only unread" } });
    app.performLayout();
    const inside = app.tree.rectOf(sheet).center();

    // Started inside, finished past the edge: the sheet is being used,
    // not dismissed.
    try down(&app, inside);
    try up(&app, .{ .x = 2, .y = 2 });
    try testing.expect(layout.findSheet(&app.tree) != null);

    // Started on the scrim and stayed there: pointer parity with Esc.
    try down(&app, .{ .x = 2, .y = 2 });
    try up(&app, .{ .x = 2, .y = 2 });
    try testing.expect(layout.findSheet(&app.tree) == null);
}

test "a button with work in progress takes no second press, and keeps the focus it had" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{
        .label = "Count primes",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });

    app.performLayout();
    const center = app.tree.rectOf(btn).center();
    try app.tap(center);
    try testing.expectEqual(@as(u32, 1), counter.count);

    // What the press handler would do: the work is now outstanding.
    app.tree.get(btn).?.button.in_progress = true;

    // Neither a second tap nor a second Enter starts it again…
    try app.tap(center);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expectEqual(@as(u32, 1), counter.count);
    // …and focus stays on the button the user pressed, rather than
    // falling back to the top of the screen.
    try testing.expect(app.focused.?.on(btn));

    // When the work lands, the button is a button again.
    app.tree.get(btn).?.button.in_progress = false;
    try app.tap(center);
    try testing.expectEqual(@as(u32, 2), counter.count);
}

test "tap activates an action tile" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.append(app.tree.rootId(), .{ .tile_group = .{} });
    const tile = try app.tree.append(group, .{ .tile = .{
        .label = "Sign out",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });

    app.performLayout();
    try app.tap(app.tree.rectOf(tile).center());

    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expect(app.focused.?.on(tile));
}

test "tap on empty space does nothing" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Go" } });
    try app.tap(.{ .x = 399, .y = 399 });
    try testing.expect(app.focused == null);
}

test "tab cycles focus, shift-tab reverses" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const a = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "a" } });
    const b = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "b" } });

    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(a));
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(b));
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(a));
    try app.dispatch(.{ .key_down = .{ .key = .tab, .mods = .{ .shift = true } } });
    try testing.expect(app.focused.?.on(b));
}

test "enter activates focused toggle" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const tg = try app.tree.append(app.tree.rootId(), .{ .toggle = .{ .label = "opt" } });
    app.focused = .of(tg);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(app.tree.getConst(tg).?.toggle.on);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(!app.tree.getConst(tg).?.toggle.on);
}

test "enter activates focused checkbox" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const cb = try app.tree.append(app.tree.rootId(), .{ .checkbox = .{ .label = "I agree" } });
    app.focused = .of(cb);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(app.tree.getConst(cb).?.checkbox.checked);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(!app.tree.getConst(cb).?.checkbox.checked);
}

test "typing edits the focused input with utf-8 aware cursor" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Name" } });
    app.focused = .of(input);

    try app.dispatch(.{ .text = .{ .bytes = "héllo" } });
    try testing.expectEqualStrings("héllo", app.tree.getConst(input).?.text_input.value);

    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try testing.expectEqualStrings("hél", app.tree.getConst(input).?.text_input.value);

    // é is 2 bytes; backspacing over it must remove the whole codepoint.
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try testing.expectEqualStrings("h", app.tree.getConst(input).?.text_input.value);

    try app.dispatch(.{ .key_down = .{ .key = .home } });
    try app.dispatch(.{ .text = .{ .bytes = "o" } });
    try testing.expectEqualStrings("oh", app.tree.getConst(input).?.text_input.value);
}

// The core half of shell.h's one-press-one-leg rule for Space: whichever
// leg a shell picks, only one of them can do anything, so a shell that
// picks wrong loses the character or double-types it — never both at once.
test "space is text in a field and a key everywhere else" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Note" } });
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{
        .label = "Go",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });

    app.focused = .of(input);
    try app.dispatch(.{ .text = .{ .bytes = "a" } });
    try app.dispatch(.{ .text = .{ .bytes = " " } });
    try app.dispatch(.{ .key_down = .{ .key = .space } }); // inert: the text leg owns it
    try app.dispatch(.{ .text = .{ .bytes = "b" } });
    try testing.expectEqualStrings("a b", app.tree.getConst(input).?.text_input.value);

    // Outside a field the key leg activates, and a stray space of text
    // with nothing editable focused lands nowhere.
    app.focused = .of(btn);
    try app.dispatch(.{ .key_down = .{ .key = .space } });
    try app.dispatch(.{ .text = .{ .bytes = " " } });
    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expectEqualStrings("a b", app.tree.getConst(input).?.text_input.value);
}

test "ime composition updates then commits" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Search" } });
    app.focused = .of(input);

    try app.dispatch(.{ .ime = .start });
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほ", .cursor = 2 } } });
    try testing.expectEqualStrings("にほ", app.tree.getConst(input).?.text_input.composition);
    try testing.expectEqualStrings("", app.tree.getConst(input).?.text_input.value);

    try app.dispatch(.{ .ime = .{ .commit = .{ .text = "日本" } } });
    try testing.expectEqualStrings("日本", app.tree.getConst(input).?.text_input.value);
    try testing.expectEqualStrings("", app.tree.getConst(input).?.text_input.composition);
}

test "text area: enter inserts a newline instead of submitting" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const ta = try app.tree.append(app.tree.rootId(), .{ .text_area = .{ .label = "Notes" } });
    app.focused = .of(ta);

    try app.dispatch(.{ .text = .{ .bytes = "ab" } });
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .text = .{ .bytes = "c" } });
    try testing.expectEqualStrings("ab\nc", app.tree.getConst(ta).?.text_area.value);

    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try testing.expectEqualStrings("ab", app.tree.getConst(ta).?.text_area.value);
}

test "text area: arrows move the caret across lines; home/end bound the line" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const ta = try app.tree.append(app.tree.rootId(), .{ .text_area = .{ .label = "Notes", .value = "abc\nde" } });
    app.focused = .of(ta);

    // Caret after 'a'; down keeps the column and lands after 'd'.
    app.tree.get(ta).?.text_area.cursor = 1;
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expectEqual(@as(usize, 5), app.tree.getConst(ta).?.text_area.cursor);
    try app.dispatch(.{ .key_down = .{ .key = .up } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(ta).?.text_area.cursor);

    // Past the last line the caret clamps to the end; past the first, to 0.
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expectEqual(@as(usize, 6), app.tree.getConst(ta).?.text_area.cursor);
    try app.dispatch(.{ .key_down = .{ .key = .up } });
    try app.dispatch(.{ .key_down = .{ .key = .up } });
    try testing.expectEqual(@as(usize, 0), app.tree.getConst(ta).?.text_area.cursor);

    app.tree.get(ta).?.text_area.cursor = 5;
    try app.dispatch(.{ .key_down = .{ .key = .home } });
    try testing.expectEqual(@as(usize, 4), app.tree.getConst(ta).?.text_area.cursor);
    try app.dispatch(.{ .key_down = .{ .key = .end } });
    try testing.expectEqual(@as(usize, 6), app.tree.getConst(ta).?.text_area.cursor);
}

test "text area: ime composition commits through the shared protocol" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const ta = try app.tree.append(app.tree.rootId(), .{ .text_area = .{ .label = "Notes" } });
    app.focused = .of(ta);

    try app.dispatch(.{ .ime = .start });
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほ", .cursor = 2 } } });
    try testing.expectEqualStrings("にほ", app.tree.getConst(ta).?.text_area.composition);

    try app.dispatch(.{ .ime = .{ .commit = .{ .text = "日本" } } });
    try testing.expectEqualStrings("日本", app.tree.getConst(ta).?.text_area.value);
    try testing.expectEqualStrings("", app.tree.getConst(ta).?.text_area.composition);
}

test "scroll clamps to content bounds" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sr = try app.tree.append(app.tree.rootId(), .{ .scroll_region = .{ .height = 50 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try app.tree.append(sr, .{ .text = .{ .content = "line" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(sr).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 10000 } });
    const el = app.tree.getConst(sr).?;
    const max = el.scroll_region.content_height - 50;
    try testing.expectEqual(max, el.scroll_region.offset);

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = -10000 } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(sr).?.scroll_region.offset);
}

test "window content scrolls without a wrapper" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const first = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
    app.performLayout();
    const y_before = app.tree.rectOf(first).y;

    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 50 }, .delta_y = 30 } });
    try testing.expectEqual(@as(i32, 30), app.root_scroll);
    app.performLayout();
    try testing.expectEqual(y_before - 30, app.tree.rectOf(first).y);

    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 50 }, .delta_y = 100000 } });
    try testing.expectEqual(app.root_content_height - 100, app.root_scroll);

    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 50 }, .delta_y = -100000 } });
    try testing.expectEqual(@as(i32, 0), app.root_scroll);
}

test "wheel over a non-overflowing region falls through to the window" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const sr = try app.tree.append(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    _ = try app.tree.append(sr, .{ .text = .{ .content = "fits" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(sr).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 30 } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(sr).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 30), app.root_scroll);
}

test "wheel past a region's limit chains to the enclosing scroller" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const outer = try app.tree.append(app.tree.rootId(), .{ .scroll_region = .{ .height = 80 } });
    const inner = try app.tree.append(outer, .{ .scroll_region = .{ .height = 40 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try app.tree.append(inner, .{ .text = .{ .content = "line" } });
    }
    while (i < 20) : (i += 1) {
        _ = try app.tree.append(outer, .{ .text = .{ .content = "line" } });
    }
    while (i < 40) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
    app.performLayout();

    const inner_max = app.tree.getConst(inner).?.scroll_region.content_height - 40;
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(inner).center(), .delta_y = inner_max + 10 } });
    try testing.expectEqual(inner_max, app.tree.getConst(inner).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 10), app.tree.getConst(outer).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(inner).center(), .delta_y = 100000 } });
    const outer_max = app.tree.getConst(outer).?.scroll_region.content_height - 80;
    try testing.expectEqual(outer_max, app.tree.getConst(outer).?.scroll_region.offset);
    try testing.expect(app.root_scroll > 0);
}

test "a touch drag locks to the region under the initial touch" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const sr = try app.tree.append(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try app.tree.append(sr, .{ .text = .{ .content = "line" } });
    }
    while (i < 30) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(sr).center();
    const max = app.tree.getConst(sr).?.scroll_region.content_height - 40;

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .begin } });
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = max + 50, .phase = .move } });
    // The region clamps; the excess dies instead of chaining outward.
    try testing.expectEqual(max, app.tree.getConst(sr).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    // A move keeps following the lock after the finger leaves the region.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 90 }, .delta_y = -10, .phase = .move } });
    try testing.expectEqual(max - 10, app.tree.getConst(sr).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .end } });
    // Released: a free wheel event chains past the clamp again.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 30 } });
    try testing.expectEqual(max, app.tree.getConst(sr).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 20), app.root_scroll);
}

test "a touch drag begun over a fitting region scrolls the window" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const sr = try app.tree.append(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    _ = try app.tree.append(sr, .{ .text = .{ .content = "fits" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(sr).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .begin } });
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 30, .phase = .move } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(sr).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 30), app.root_scroll);
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .end } });
}

test "keyboard scrolls the window when nothing consumes the keys" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }

    try app.dispatch(.{ .key_down = .{ .key = .down, .mods = .{} } });
    try testing.expectEqual(text.Scale.body.lineHeight(), app.root_scroll);

    try app.dispatch(.{ .key_down = .{ .key = .end, .mods = .{} } });
    try testing.expectEqual(app.root_content_height - 100, app.root_scroll);

    try app.dispatch(.{ .key_down = .{ .key = .home, .mods = .{} } });
    try testing.expectEqual(@as(i32, 0), app.root_scroll);
}

test "keyboard does not scroll the window under an open picker" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
    } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
    app.performLayout();
    try app.tap(app.tree.rectOf(sel).center());
    try testing.expect(layout.findPicker(&app.tree) != null);

    // The pointer path keeps everything under the scrim still
    // (`modalOpen`); the key path must agree even when nothing has
    // focus to consume the key first.
    app.focused = null;
    try app.dispatch(.{ .key_down = .{ .key = .page_down, .mods = .{} } });
    try testing.expectEqual(@as(i32, 0), app.root_scroll);
}

test "tab scrolls the focused element into view" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const a = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "A" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    const b = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "B" } });

    try app.dispatch(.{ .key_down = .{ .key = .tab, .mods = .{} } });
    try testing.expect(app.focused.?.on(a));
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    try app.dispatch(.{ .key_down = .{ .key = .tab, .mods = .{} } });
    try testing.expect(app.focused.?.on(b));
    app.performLayout();
    const rb = app.tree.rectOf(b);
    try testing.expect(app.root_scroll > 0);
    try testing.expect(rb.y >= 0 and rb.bottom() <= 100);

    // Shift-tab back to the top reveals A again.
    try app.dispatch(.{ .key_down = .{ .key = .tab, .mods = .{ .shift = true } } });
    app.performLayout();
    const ra = app.tree.rectOf(a);
    try testing.expect(ra.y >= 0 and ra.bottom() <= 100);
}

const CtxData = struct { built: u32 = 0 };

fn buildHome(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *CtxData = @ptrCast(@alignCast(ctx.?));
    data.built += 1;
    _ = try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Details", .route = "details" } });
}

fn buildDetails(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Details" } });
}

const home_and_details = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildHome },
    .{ .name = "details", .title = "Details", .build = buildDetails },
};

/// The router fixture's app: two screens and the counter `buildHome`
/// bumps, so a test can say how many times a screen was rebuilt.
fn routedApp(data: *CtxData) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &home_and_details,
        .ctx = data,
        .services = .mocks(),
    });
}

test "link activation navigates through the router" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();

    try app.navigate("home");
    try testing.expectEqual(@as(u32, 1), data.built);
    app.performLayout();

    const link = focus.firstFocusable(&app.tree, app.tree.rootId()).?.node;
    try app.tap(app.tree.rectOf(link).center());

    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expect(app.focused == null);

    try app.navigateBack();
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expectEqual(@as(u32, 2), data.built);
}

test "pushed screens get framework back chrome; the root does not" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();

    try app.navigate("home");
    try testing.expect(firstChild(&app).role() != .back);

    try app.navigate("details");
    var it = app.tree.children(app.tree.rootId());
    const back = it.next().?;
    const title = it.next().?;
    const first = app.tree.getConst(back).?;
    try testing.expect(first.role() == .back);
    try testing.expectEqualStrings("Back", first.label());

    // The control shares the title's line: indented title, same row.
    app.performLayout();
    const br = app.tree.rectOf(back);
    const tr = app.tree.rectOf(title);
    try testing.expectEqual(br.x + br.w + layout.metrics.icon_gap, tr.x);
    // The target is taller than the line it marks, so it hangs past the
    // title's box on both sides — including *above* it. What has to hold
    // is the exact thing the eye checks: the glyph's center sits on the
    // title's cap center, not on its line box, which reads low.
    const scale = text.Scale.h1;
    const cap_center = tr.y + scale.baseline() - @divTrunc(3 * scale.px(), 8);
    try testing.expectEqual(cap_center, br.center().y);
    try testing.expect(br.y < tr.y);

    try app.tap(br.center());
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expectEqual(@as(usize, 1), app.router.depth());
    try testing.expect(firstChild(&app).role() != .back);
}

fn firstChild(app: *App) Element {
    var it = app.tree.children(app.tree.rootId());
    return app.tree.getConst(it.next().?).?.*;
}

/// The framework-installed Back control, or null at a stack root. Not
/// `firstChild`: app chrome installed before the content (a nav) leads
/// the root's children and outlives every rebuild.
fn backControl(app: *App) ?NodeId {
    var it = app.tree.children(app.tree.rootId());
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .back) return c;
    }
    return null;
}

fn buildTileHome(ctx: ?*anyopaque, app: *App) anyerror!void {
    const data: *CtxData = @ptrCast(@alignCast(ctx.?));
    data.built += 1;
    const group = try app.tree.append(app.tree.rootId(), .{ .tile_group = .{} });
    _ = try app.tree.append(group, .{ .tile = .{ .label = "Details", .route = "details" } });
}

test "tile with a route navigates like a link" {
    var data: CtxData = .{};
    const routes = [_]router_mod.RouteDef{
        .{ .name = "home", .title = "Home", .build = buildTileHome },
        .{ .name = "details", .title = "Details", .build = buildDetails },
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &routes,
        .ctx = &data,
        .services = .mocks(),
    });
    defer app.deinit();

    try app.navigate("home");
    app.performLayout();

    const tile = focus.firstFocusable(&app.tree, app.tree.rootId()).?.node;
    try app.tap(app.tree.rectOf(tile).center());

    try testing.expectEqualStrings("details", app.router.current().?);
}

test "nav survives rebuilds; activation pushes the destination" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "details", .icon = .info },
    });
    try app.navigate("home");
    try app.navigate("details"); // push: depth 2
    try testing.expectEqual(@as(usize, 2), app.router.depth());

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 2), app.tree.childCount(nav));

    app.performLayout();
    var it = app.tree.children(nav);
    const home_item = it.next().?;
    try app.tap(app.tree.rectOf(home_item).center());

    try testing.expectEqualStrings("home", app.router.current().?);
    // The destination goes *on* the stack: the screen it was reached
    // from is still behind it, and now has a way back to it.
    try testing.expectEqual(@as(usize, 3), app.router.depth());
    try testing.expect(app.focused.?.on(home_item));
    try testing.expect(layout.findNav(&app.tree).?.eql(nav));

    // The way back is the framework's own control, and it leads to the
    // screen the nav was crossed from — not to a section root nobody
    // was standing on.
    try testing.expect(backControl(&app) != null);
    try app.navigateBack();
    try testing.expectEqualStrings("details", app.router.current().?);
}

test "crossing to the destination already showing is the one no-op" {
    var data: CtxData = .{};
    var app = try routedApp(&data);
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "details", .icon = .info },
    });
    try app.navigate("home");
    app.performLayout();

    var it = app.tree.children(layout.findNav(&app.tree).?);
    const home_item = it.next().?;
    try app.tap(app.tree.rectOf(home_item).center());

    // Not "home" on top of "home": that would grow a Back control out of
    // nowhere, leading to the screen you are looking at.
    try testing.expectEqual(@as(usize, 1), app.router.depth());
    try testing.expect(backControl(&app) == null);
    try testing.expect(app.focused.?.on(home_item));
}

// ---- the collapsed nav (docs/elements.md#navigation-chrome) ----

// Four sections whose widest title ("Subscriptions", from the route
// table below) clears a row at no viewport width, so the shape is
// decided by the fixture, not by luck.
const crowded_nav = [_]nav_mod.Destination{
    .{ .route = "library", .icon = .library },
    .{ .route = "settings", .icon = .settings },
    .{ .route = "explore", .icon = .compass },
    .{ .route = "subs", .icon = .user },
};

fn buildNavSection(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Section" } });
}

const crowded_routes = [_]router_mod.RouteDef{
    .{ .name = "library", .title = "Library", .build = buildNavSection },
    .{ .name = "settings", .title = "Settings", .build = buildNavSection },
    .{ .name = "explore", .title = "Explore", .build = buildNavSection },
    .{ .name = "subs", .title = "Subscriptions", .build = buildNavSection },
    .{ .name = "account", .title = "Account", .build = buildNavSection },
};

/// The nav-collapse fixture's app: a phone-width viewport and the
/// crowded roster's routes, which is what every test below turns on.
fn crowdedApp() !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 375, .h = 600 },
        .routes = &crowded_routes,
        .services = .mocks(),
    });
}

fn navChip(app: *App) ?NodeId {
    const nav = layout.findNav(&app.tree) orelse return null;
    var it = app.tree.children(nav);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .nav_current) return c;
    }
    return null;
}

test "a nav too wide for its labels collapses to the current section" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("settings");

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 1), app.tree.childCount(nav));
    const chip = navChip(&app).?;
    // The roster is intact behind it — the shape changed, not the set.
    try testing.expectEqual(@as(usize, 4), app.nav_items.items.len);
    try testing.expectEqualStrings("Settings", app.tree.getConst(chip).?.nav_current.section);
    // Its name is the framework's and stays put; the section is its value.
    try testing.expectEqualStrings("Section", app.tree.getConst(chip).?.label());
}

test "the collapsed chip follows the router without being rebuilt for nothing" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");

    const first = navChip(&app).?;
    try testing.expectEqualStrings("Library", app.tree.getConst(first).?.nav_current.section);

    // A rebuild that lands on the same section leaves the node alone:
    // replacing it would drop whatever names it.
    try app.router.reload(&app);
    try testing.expect(navChip(&app).?.eql(first));

    try app.router.switchTo(&app, "explore");
    try testing.expectEqualStrings("Explore", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

test "the nav reshapes as the viewport crosses the threshold" {
    var app = try crowdedApp();
    defer app.deinit();
    // Two short titles fit anywhere; four long ones fit nowhere. This
    // set sits between: collapsed in portrait, a row in landscape.
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
        .{ .route = "explore", .icon = .compass },
        .{ .route = "account", .icon = .user },
    });
    try app.navigate("library");
    try testing.expect(navChip(&app) != null);

    app.setViewport(.{ .w = 900, .h = 400 });
    try testing.expect(navChip(&app) == null);
    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 4), app.tree.childCount(nav));

    app.setViewport(.{ .w = 375, .h = 600 });
    try testing.expect(navChip(&app) != null);
}

test "the chip's picker lists every section with the current one selected" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("explore");
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    const picker = layout.findPicker(&app.tree).?;
    try testing.expectEqualStrings("Sections", app.tree.getConst(picker).?.picker.title);

    var rows: [8]NodeId = undefined;
    var n: usize = 0;
    var it = app.tree.dfsUnder(picker);
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() == .picker_item) {
            rows[n] = id;
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("Library", app.tree.getConst(rows[0]).?.picker_item.label);
    try testing.expect(app.tree.getConst(rows[2]).?.picker_item.selected);
    // Focus opens on the current row, as the select's picker does.
    try testing.expect(app.focused.?.on(rows[2]));
}

test "choosing a section pushes it and keeps focus in the chrome" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    try app.navigate("settings"); // depth 2 inside the section
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    var target: ?NodeId = null;
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.role() == .picker_item and el.picker_item.index == 3) target = id;
    }
    try app.tap(app.tree.rectOf(target.?).center());

    try testing.expectEqualStrings("subs", app.router.current().?);
    // A push, exactly as the row's items make: the two screens behind
    // it stay behind it. The chip and the row are one behavior in two
    // shapes, and the shape must not decide what a choice costs.
    try testing.expectEqual(@as(usize, 3), app.router.depth());
    try testing.expect(layout.findPicker(&app.tree) == null);
    // The chip the picker was opened from is gone with the resync;
    // focus follows the chrome rather than dangling.
    const chip = navChip(&app).?;
    try testing.expect(app.focused.?.on(chip));
    try testing.expectEqualStrings("Subscriptions", app.tree.getConst(chip).?.nav_current.section);

    try app.navigateBack();
    try testing.expectEqualStrings("settings", app.router.current().?);
    try testing.expectEqualStrings("Settings", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

test "re-choosing the current section is a no-op, stack and all" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    try app.navigate("settings"); // depth 2, and worth keeping
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    var target: ?NodeId = null;
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        // "settings" is the roster's index 1, and the screen we are on.
        if (el.role() == .picker_item and el.picker_item.index == 1) target = id;
    }
    try app.tap(app.tree.rectOf(target.?).center());

    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("settings", app.router.current().?);
    // Confirming where you are is not a navigation: no second copy of
    // this screen, and the way back still leads where it did.
    try testing.expectEqual(@as(usize, 2), app.router.depth());
}

// ---- the section menu's geometry ----

/// The open menu and the chip it came out of, laid out.
fn openSectionMenu(app: *App) !struct { menu: geometry.Rect, chip: geometry.Rect } {
    try app.tap(app.tree.rectOf(navChip(app).?).center());
    app.performLayout();
    return .{
        .menu = app.tree.rectOf(layout.findPicker(&app.tree).?),
        .chip = app.tree.rectOf(navChip(app).?),
    };
}

test "the section menu stands on the bar rather than spanning the pane" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    const r = try openSectionMenu(&app);
    // Centered on the bar's group and resting a gap above it — the card
    // stands on that bar, so it is measured from it and not from a pane.
    // Never narrower than the chip (a menu that came out of a wider
    // control reads as clipped), never wider than the margins the chip
    // itself is placed inside.
    try testing.expectEqual(layout.navGroupX(app.viewport, r.menu.w), r.menu.x);
    try testing.expectEqual(r.chip.y - layout.metrics.nav_item_gap, r.menu.bottom());
    try testing.expect(r.menu.w >= r.chip.w);
    try testing.expect(r.menu.w <= layout.navContentWidth(app.viewport));
    // The bar's cap, not the sheet's, and no header: the pane's title
    // bar and its 560px span both went with the pane.
    try testing.expect(r.menu.w < layout.paneWidth(app.viewport));

    // Four rows flush inside the 1px edge, and every one of them fits:
    // the roster caps at six, so this list can never want to scroll.
    const rows: i32 = 4;
    const content = rows * layout.pickerItemHeight() + (rows - 1) * layout.metrics.border;
    try testing.expectEqual(content + 2 * layout.metrics.border, r.menu.h);
    var it = app.tree.children(layout.findPicker(&app.tree).?);
    const region = it.next().?;
    try testing.expectEqual(content, app.tree.rectOf(region).h);
}

test "the section menu clears the bar whatever the safe band costs" {
    var app = try crowdedApp();
    defer app.deinit();
    app.setSafeBottom(34); // a home-indicator phone
    try crowdedNavApp(&app);

    const r = try openSectionMenu(&app);
    // The regression this shape replaced: the menu was a bottom-anchored
    // pane, so it bled its fill `safe_bottom` px past its own rect and
    // let the clip square the edge off — over the chip it was supposed
    // to leave visible. Nothing of it may reach the chip's band now.
    try testing.expect(r.menu.bottom() < r.chip.y);
    try testing.expect(r.menu.bottom() + app.safe_bottom < app.viewport.h);
    try testing.expect(r.menu.y >= layout.metrics.sheet_min_top);
}

test "the section menu is its own mirror, being centered on the bar" {
    var rtl_app = try crowdedApp();
    defer rtl_app.deinit();
    rtl_app.setDirection(.rtl);
    try crowdedNavApp(&rtl_app);
    const rtl = try openSectionMenu(&rtl_app);

    var ltr_app = try crowdedApp();
    defer ltr_app.deinit();
    try crowdedNavApp(&ltr_app);
    const ltr = try openSectionMenu(&ltr_app);

    // A centered card has no leading edge to swap, so mirroring the
    // chrome moves it nowhere: the same rect either way. What the two
    // directions still disagree about is inside the rows, which is where
    // the words are.
    try testing.expectEqual(ltr.menu, rtl.menu);
    try testing.expectEqual(rtl.chip.y - layout.metrics.nav_item_gap, rtl.menu.bottom());
}

// ---- press-drag-release through the section menu ----

fn crowdedNavApp(app: *App) !void {
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    app.performLayout();
}

fn sectionRow(app: *App, index: usize) NodeId {
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.role() == .picker_item and el.picker_item.index == index) return id;
    }
    unreachable;
}

test "the section menu opens on the press, not the release" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    try down(&app, app.tree.rectOf(navChip(&app).?).center());
    // The whole point: the same press can now travel to a row.
    try testing.expect(layout.findPicker(&app.tree) != null);
}

test "the open menu leaves the chip that opened it uncovered" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?);

    try down(&app, chip.center());
    app.performLayout();

    // A menu drawn over its own control would put a row under the
    // finger still holding it, and letting go without moving would
    // choose a section nobody aimed at.
    const picker = app.tree.rectOf(layout.findPicker(&app.tree).?);
    try testing.expect(picker.bottom() <= chip.y);
}

test "dragging to a row and releasing chooses that section" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?).center();

    try down(&app, chip);
    app.performLayout();
    const row = app.tree.rectOf(sectionRow(&app, 2)).center();
    try app.dispatch(.{ .pointer = .{ .at = row, .phase = .move } });
    // Motion moves focus and nothing else — the state the arrow keys
    // move, not a second kind of highlight.
    try testing.expect(app.focused.?.on(sectionRow(&app, 2)));

    try up(&app, row);
    try testing.expectEqualStrings("explore", app.router.current().?);
    try testing.expect(layout.findPicker(&app.tree) == null);
}

test "releasing back on the chip leaves the menu open for a second press" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?).center();

    // The sticky menu: this is what keeps the drag an addition rather
    // than a replacement — a plain click still works, in two presses.
    try app.tap(chip);
    try testing.expect(layout.findPicker(&app.tree) != null);
    try testing.expectEqualStrings("library", app.router.current().?);

    app.performLayout();
    try app.tap(app.tree.rectOf(sectionRow(&app, 3)).center());
    try testing.expectEqualStrings("subs", app.router.current().?);
}

test "releasing away from both chip and rows chooses nothing" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    try down(&app, app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    try up(&app, .{ .x = 4, .y = 4 }); // the scrim, above the menu

    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("library", app.router.current().?);
}

test "a cancelled section drag chooses nothing and closes" {
    var app = try crowdedApp();
    defer app.deinit();
    try crowdedNavApp(&app);

    try down(&app, app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    const row = app.tree.rectOf(sectionRow(&app, 2)).center();
    try app.dispatch(.{ .pointer = .{ .at = row, .phase = .move } });
    try app.dispatch(.{ .pointer = .{ .at = row, .phase = .cancel } });
    try up(&app, row);

    // A recognizer taken away mid-drag must never commit a navigation
    // the user did not finish — the edge pan's rule, same reasoning.
    try testing.expectEqualStrings("library", app.router.current().?);
}

test "only the collapsed chip asks the touch shells for the raw stream" {
    var app = try crowdedApp();
    defer app.deinit();

    // Nothing wants it before there is a nav at all.
    try testing.expect(input_mod.pointerStreamRect(&app) == null);

    try crowdedNavApp(&app);
    const chip = app.tree.rectOf(navChip(&app).?);
    try testing.expectEqual(chip, input_mod.pointerStreamRect(&app).?);
    try testing.expect(input_mod.wantsPointerStream(&app, chip.center()));
    // Everything else takes the shells' ordinary recognized-tap path,
    // so their scrolling and tap detection are untouched.
    try testing.expect(!input_mod.wantsPointerStream(&app, .{ .x = 8, .y = 8 }));

    // Inert while the menu it opened is up: the next press belongs to
    // the scrim, which closes rather than reopens.
    try down(&app, chip.center());
    try testing.expect(input_mod.pointerStreamRect(&app) == null);
}

test "a nav wide enough for its row asks for nothing" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 400 },
        .routes = &crowded_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "explore", .icon = .compass },
    });
    try app.navigate("library");
    app.performLayout();

    // Row items are plain links: a press-drag has nothing to open, and
    // every touch shell keeps its own recognizer for them.
    try testing.expect(input_mod.pointerStreamRect(&app) == null);
}

test "a select still opens on release and is chosen by a second press" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
    } });
    app.performLayout();

    // The drag is the nav's alone: pressing a select opens nothing
    // until the release, and nothing follows the pointer after it.
    try down(&app, app.tree.rectOf(sel).center());
    try testing.expect(layout.findPicker(&app.tree) == null);
    try up(&app, app.tree.rectOf(sel).center());
    try testing.expect(layout.findPicker(&app.tree) != null);
}

test "Esc leaves the section picker without navigating" {
    var app = try crowdedApp();
    defer app.deinit();
    try app.setNav(&crowded_nav);
    try app.navigate("library");
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    try testing.expect(layout.findPicker(&app.tree) != null);
    try app.dispatch(.{ .key_down = .{ .key = .escape } });

    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("library", app.router.current().?);
}

// ---- a screen that is none of the destinations ----

// Two sections, and two routes the roster does not name — one plain, one
// carrying an argument, because the marker has to name a route whose
// reference is not its name.
const offroster_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildNavSection },
    .{ .name = "settings", .title = "Settings", .build = buildNavSection },
    .{ .name = "terms", .title = "Terms", .build = buildNavSection },
    .{ .name = "ticket", .title = "Ticket", .args = 1, .build = buildNavSection },
};

const offroster_nav = [_]nav_mod.Destination{
    .{ .route = "home", .icon = .house },
    .{ .route = "settings", .icon = .settings },
};

fn offRosterApp(w: i32) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = w, .h = 600 },
        .routes = &offroster_routes,
        .services = .mocks(),
    });
}

fn navHere(app: *App) ?NodeId {
    const nav = layout.findNav(&app.tree) orelse return null;
    var it = app.tree.children(nav);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .nav_here) return c;
    }
    return null;
}

test "the row names a screen that is none of its destinations" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(usize, 2), app.tree.childCount(nav));
    try testing.expect(navHere(&app) == null);

    // Off the roster: the screen joins the row, at the end, naming
    // itself from the route table — not silently marking Home current,
    // which is where the visitor is not.
    try app.navigate("terms");
    try testing.expectEqual(@as(usize, 3), app.tree.childCount(nav));
    const here = navHere(&app).?;
    try testing.expectEqualStrings("Terms", app.tree.getConst(here).?.nav_here.label);
    var it = app.tree.children(nav);
    _ = it.next();
    _ = it.next();
    try testing.expect(it.next().?.eql(here)); // last, so the roster keeps its indices

    // And back: crossing onto a destination drops the marker again.
    try app.navigate("settings");
    try testing.expect(navHere(&app) == null);
    try testing.expectEqual(@as(usize, 2), app.tree.childCount(nav));
}

test "the marker names the route, arguments and all" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("ticket~42");

    // The title names the route, not the instance: `ticket~42` and
    // `ticket~43` are both "Ticket" (router.zig).
    try testing.expectEqualStrings("Ticket", app.tree.getConst(navHere(&app).?).?.nav_here.label);
}

test "the marker is a label, not a destination" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("terms");
    app.performLayout();

    const here = navHere(&app).?;
    const el = app.tree.getConst(here).?;
    try testing.expect(!el.isInteractive());
    try testing.expect(!el.isFocusable());
    // Its name is the framework's and the title is its value, the split
    // the collapsed chip already makes.
    try testing.expectEqualStrings("Current screen", el.label());

    // A press lands on nothing: no focus moves, no navigation happens.
    const before = app.router.depth();
    try app.tap(app.tree.rectOf(here).center());
    try testing.expectEqual(before, app.router.depth());
    try testing.expect(app.focused == null);

    // And the keyboard walks past it. The tab order wraps, so one lap
    // is every stop there is — bounded, or a marker in the order would
    // hang this test rather than fail it.
    var stop = focus.firstFocusable(&app.tree, app.tree.rootId());
    const first = stop.?;
    for (0..16) |_| {
        try testing.expect(!stop.?.node.eql(here));
        stop = focus.nextFocusable(&app.tree, app.tree.rootId(), stop.?);
        if (stop.?.node.eql(first.node)) break;
    }
}

test "the chip names an off-roster screen instead of the first section" {
    var app = try offRosterApp(300);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("terms");

    // The old answer here was "Home" — the first destination, standing
    // in for a screen the visitor had not opened.
    try testing.expectEqualStrings("Terms", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

test "the screen's own entry is measured like any other destination" {
    // A width that holds the two destinations and not a third pill.
    var app = try offRosterApp(380);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    try testing.expect(navChip(&app) == null);

    // Nothing in the collapse threshold knows this feature exists: the
    // row simply has one more pill in it (`nav.effectiveRoster`).
    try app.navigate("terms");
    try testing.expect(navChip(&app) != null);
    try testing.expectEqualStrings("Terms", app.tree.getConst(navChip(&app).?).?.nav_current.section);

    try app.navigate("settings");
    try testing.expect(navChip(&app) == null);
}

test "the picker offers the screen you are on, selected, and declines it" {
    // Narrow enough that the shape is the chip whichever screen is on
    // top: this is a test about the picker, not about reshaping.
    var app = try offRosterApp(300);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");
    try app.navigate("terms"); // depth 2, and worth keeping
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    var rows: [8]NodeId = undefined;
    var n: usize = 0;
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() == .picker_item) {
            rows[n] = id;
            n += 1;
        }
    }
    // A combo box whose value is one of its own options: the chip says
    // "Terms" and the list it opens contains Terms.
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("Terms", app.tree.getConst(rows[2]).?.picker_item.label);
    try testing.expect(app.tree.getConst(rows[2]).?.picker_item.selected);

    // Choosing it is the no-op every current destination gets: the
    // entry carries the current reference, so `isCurrent` catches it.
    try app.tap(app.tree.rectOf(rows[2]).center());
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqualStrings("terms", app.router.current().?);
    try testing.expectEqual(@as(usize, 2), app.router.depth());
}

test "the picker still crosses to a destination from an off-roster screen" {
    var app = try offRosterApp(300);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("terms");
    app.performLayout();

    try app.tap(app.tree.rectOf(navChip(&app).?).center());
    app.performLayout();
    var target: ?NodeId = null;
    var it = app.tree.dfsUnder(layout.findPicker(&app.tree).?);
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.role() == .picker_item and el.picker_item.index == 1) target = id;
    }
    try app.tap(app.tree.rectOf(target.?).center());

    try testing.expectEqualStrings("settings", app.router.current().?);
    try testing.expectEqualStrings("Settings", app.tree.getConst(navChip(&app).?).?.nav_current.section);
}

test "setNav must precede content" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "early" } });
    try testing.expectError(error.NavMustComeFirst, app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "settings", .icon = .settings },
    }));
}

test "setNav rejects too few or too many destinations" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try testing.expectError(error.NavItemCount, app.setNav(&.{
        .{ .route = "only", .icon = .circle },
    }));
    try testing.expectError(error.NavItemCount, app.setNav(&.{
        .{ .route = "a", .icon = .circle }, .{ .route = "b", .icon = .circle },
        .{ .route = "c", .icon = .circle }, .{ .route = "d", .icon = .circle },
        .{ .route = "e", .icon = .circle }, .{ .route = "f", .icon = .circle },
    }));
}

test "a destination is a route the table has, taking no arguments" {
    var app = try offRosterApp(900);
    defer app.deinit();
    // Nothing names it, so nothing could draw it: a roster the route
    // table has never heard of is refused whole, not drawn blank.
    try testing.expectError(error.UnknownRoute, app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "nowhere", .icon = .circle },
    }));
    // `ticket` takes one: the row has no argument to press with, so the
    // destination would be inert rather than merely unnamed.
    try testing.expectError(error.RouteArgCount, app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "ticket", .icon = .circle },
    }));
    // Neither attempt left half a roster behind.
    try testing.expectEqual(@as(usize, 0), app.nav_items.items.len);
    try app.setNav(&offroster_nav);
    try testing.expectEqual(@as(usize, 2), app.nav_items.items.len);
}

test "the roster's labels are the route table's titles" {
    var app = try offRosterApp(900);
    defer app.deinit();
    try app.setNav(&offroster_nav);
    try app.navigate("home");

    var it = app.tree.children(layout.findNav(&app.tree).?);
    // Declared once, at the route table, and never restated by the nav.
    try testing.expectEqualStrings("Home", app.tree.getConst(it.next().?).?.nav_item.label);
    try testing.expectEqualStrings("Settings", app.tree.getConst(it.next().?).?.nav_item.label);
}

// ---- what leaves the router: the current route (docs/routing.md) ----

fn buildLeaf(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Leaf" } });
}

const observed_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildHome },
    .{ .name = "details", .title = "Details", .build = buildDetails },
    .{ .name = "leaf", .title = "Leaf", .build = buildLeaf },
};

const RouteRecorder = struct {
    count: usize = 0,
    refs: [8][32]u8 = undefined,
    lens: [8]usize = undefined,
    changes: [8]router_mod.Change = undefined,

    fn observe(ctx: ?*anyopaque, route: []const u8, change: router_mod.Change) void {
        const self: *RouteRecorder = @ptrCast(@alignCast(ctx.?));
        if (self.count == self.lens.len) return;
        // Copied, not kept: the reference belongs to the stack entry and
        // dies with it, which is what "borrowed only for the call" means.
        @memcpy(self.refs[self.count][0..route.len], route);
        self.lens[self.count] = route.len;
        self.changes[self.count] = change;
        self.count += 1;
    }

    fn at(self: *const RouteRecorder, i: usize) []const u8 {
        return self.refs[i][0..self.lens[i]];
    }
};

test "every change announces the screen on top, with the motion that made it" {
    var data: CtxData = .{};
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &observed_routes,
        .ctx = &data,
        .services = .mocks(),
    });
    defer app.deinit();
    var rec: RouteRecorder = .{};
    app.router.installObserver(&rec, RouteRecorder.observe);

    try app.navigate("home"); // push
    try app.navigate("details"); // push
    try app.navigateBack(); // pop
    try app.router.replace(&app, "leaf"); // replace
    try app.router.switchTo(&app, "home"); // switch_to

    try testing.expectEqual(@as(usize, 5), rec.count);
    const want_names = [_][]const u8{ "home", "details", "home", "leaf", "home" };
    const want_changes = [_]router_mod.Change{ .push, .push, .pop, .replace, .switch_to };
    for (want_names, want_changes, 0..) |n, c, i| {
        try testing.expectEqualStrings(n, rec.at(i));
        try testing.expectEqual(c, rec.changes[i]);
    }

    // The depth the app came through is the router's alone: `home` is
    // announced identically whether it was pushed, popped back to, or
    // switched to — one screen, one name.
    try testing.expectEqualStrings(rec.at(0), rec.at(4));

    // A pop at the root is a no-op, so it announces nothing.
    const before = rec.count;
    try app.navigateBack();
    try testing.expectEqual(before, rec.count);
}

// ---- route arguments: `note~42` (docs/routing.md) ----

fn buildTicket(_: ?*anyopaque, app: *App) anyerror!void {
    // A parameterized screen reads its own identity, not app state —
    // which is what makes the entry, not the app, remember it.
    _ = try app.tree.append(app.tree.rootId(), .{
        .heading = .{ .content = app.routeArg(0) orelse "?" },
    });
}

const arg_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildHome },
    .{ .name = "ticket", .title = "Ticket", .args = 1, .build = buildTicket },
    .{ .name = "sum", .title = "Sum", .args = 2, .build = buildLeaf },
};

fn argApp(data: *CtxData) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &arg_routes,
        .ctx = data,
        .services = .mocks(),
    });
}

/// The screen's own first element, past the framework's back control —
/// every reference below is pushed, so the control is always there.
fn pushedTitle(app: *App) []const u8 {
    var it = app.tree.children(app.tree.rootId());
    _ = it.next(); // .back
    return app.tree.getConst(it.next().?).?.label();
}

test "a reference carries its arguments to the screen" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();

    try app.navigate("home");
    try app.navigate("ticket~2938");
    try testing.expectEqualStrings("ticket", app.router.current().?); // the name
    try testing.expectEqualStrings("ticket~2938", app.router.currentRef().?);
    try testing.expectEqualStrings("2938", app.routeArg(0).?);
    try testing.expect(app.routeArg(1) == null);
    // The builder read it, so it reached the tree.
    try testing.expectEqualStrings("2938", pushedTitle(&app));

    try app.navigate("sum~10~5");
    try testing.expectEqualStrings("10", app.routeArg(0).?);
    try testing.expectEqualStrings("5", app.routeArg(1).?);
}

test "arguments belong to the stack entry, so a pop restores them" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("ticket~41");
    try app.navigate("ticket~42");
    try testing.expectEqualStrings("42", app.routeArg(0).?);

    // The whole point of owning the reference per entry: the screen
    // underneath is a *different* ticket, and popping back proves the
    // entry remembered which — app state never held it.
    try app.navigateBack();
    try testing.expectEqualStrings("41", app.routeArg(0).?);
    try testing.expectEqualStrings("41", pushedTitle(&app));

    // And a reload rebuilds this entry with its own arguments —
    // `replace(app, current())` would drop them, since `current` is the
    // bare name.
    try app.router.reload(&app);
    try testing.expectEqualStrings("41", app.routeArg(0).?);
    try testing.expectEqual(@as(usize, 2), app.router.depth());
}

// ---- an entry remembers a viewport, not just a name (docs/routing.md) ----

/// Knobs a rebuild turns: the screen that comes back is built from
/// scratch, so it can legitimately come back a different shape.
const ScrollCtx = struct {
    rows: usize = 40,
    regions: usize = 0,
};

fn buildScrolled(ctx: ?*anyopaque, app: *App) anyerror!void {
    const c: *ScrollCtx = @ptrCast(@alignCast(ctx.?));
    var r: usize = 0;
    while (r < c.regions) : (r += 1) {
        const region = try app.tree.append(app.tree.rootId(), .{ .scroll_region = .{ .height = 60 } });
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            _ = try app.tree.append(region, .{ .text = .{ .content = "row" } });
        }
    }
    var i: usize = 0;
    while (i < c.rows) : (i += 1) {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    }
}

const scroll_routes = [_]router_mod.RouteDef{
    .{ .name = "list", .title = "List", .build = buildScrolled },
    .{ .name = "detail", .title = "Detail", .build = buildDetails },
};

fn scrollApp(c: *ScrollCtx) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 200 },
        .routes = &scroll_routes,
        .ctx = c,
        .services = .mocks(),
    });
}

fn regionAt(app: *App, n: usize) NodeId {
    var seen: usize = 0;
    var it = app.tree.dfs();
    while (it.next()) |id| {
        if (app.tree.getConst(id).?.role() != .scroll_region) continue;
        if (seen == n) return id;
        seen += 1;
    }
    unreachable;
}

test "popping back returns the screen to where it was scrolled" {
    var c: ScrollCtx = .{};
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 120 } });
    try testing.expectEqual(@as(i32, 120), app.root_scroll);

    try app.navigate("detail");
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    // The rebuild is still from scratch; what came back is the viewport.
    try app.navigateBack();
    try testing.expectEqual(@as(i32, 120), app.root_scroll);
}

test "regions come back by position, and do not swap" {
    var c: ScrollCtx = .{ .regions = 2 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 0)).center(), .delta_y = 30 } });
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 1)).center(), .delta_y = 70 } });

    try app.navigate("detail");
    try app.navigateBack();
    app.performLayout();

    // NodeIds are generational and the freelist reuses them, so this is
    // the DFS ordinal doing the matching and nothing else.
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 70), app.tree.getConst(regionAt(&app, 1)).?.scroll_region.offset);
}

test "a screen that comes back a different shape restores what lines up" {
    var c: ScrollCtx = .{ .regions = 2 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 0)).center(), .delta_y = 30 } });
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 1)).center(), .delta_y = 70 } });
    try app.navigate("detail");

    // Fewer regions than were saved: the second position no longer
    // exists, which is a screen answering to changed state, not an error.
    c.regions = 1;
    try app.navigateBack();
    app.performLayout();
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);

    // And more regions than were saved: the extras start at the top.
    try app.navigate("detail");
    c.regions = 3;
    try app.navigateBack();
    app.performLayout();
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(regionAt(&app, 2)).?.scroll_region.offset);
}

test "a restored offset past the new content is clamped, not stranded" {
    var c: ScrollCtx = .{ .rows = 60 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 100000 } });
    const deep = app.root_scroll;
    try testing.expect(deep > 0);

    try app.navigate("detail");
    c.rows = 12; // the list shrank while the detail screen was up
    try app.navigateBack();
    app.performLayout();
    try testing.expect(app.root_scroll < deep);
    try testing.expectEqual(@max(0, app.root_content_height - app.viewport.h), app.root_scroll);
}

test "only pop and reload restore; replace and switchTo start at the top" {
    var c: ScrollCtx = .{};
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 90 } });

    // A reload is the same screen answering to changed state, so the
    // viewport is the user's, not the builder's.
    try app.router.reload(&app);
    try testing.expectEqual(@as(i32, 90), app.root_scroll);

    // A replace is a different screen at the same depth, and switchTo is
    // a different section: neither inherits a position it never had.
    try app.router.replace(&app, "list");
    try testing.expectEqual(@as(i32, 0), app.root_scroll);
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 100 }, .delta_y = 90 } });
    try app.router.switchTo(&app, "list");
    try testing.expectEqual(@as(i32, 0), app.root_scroll);
}

test "the saved positions are bounded, like the reference is" {
    var c: ScrollCtx = .{ .regions = router_mod.max_saved_regions + 2 };
    var app = try scrollApp(&c);
    defer app.deinit();
    try app.navigate("list");
    app.performLayout();
    const last = router_mod.max_saved_regions + 1;
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, 0)).center(), .delta_y = 30 } });
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(regionAt(&app, last)).center(), .delta_y = 30 } });

    try app.navigate("detail");
    try app.navigateBack();
    app.performLayout();
    // Past the bound a region comes back at the top — what every screen
    // did before any of this, not a failure.
    try testing.expectEqual(@as(i32, 30), app.tree.getConst(regionAt(&app, 0)).?.scroll_region.offset);
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(regionAt(&app, last)).?.scroll_region.offset);
}

// ---- the one gesture: an edge pan goes back (docs/routing.md) ----

const pan_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildHome },
    .{ .name = "details", .title = "Details", .build = buildDetails },
};

fn panApp(data: *CtxData) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &pan_routes,
        .ctx = data,
        .services = .mocks(),
    });
}

fn panThreshold(app: *const App) i32 {
    return @max(
        layout.metrics.back_gesture_min,
        @divTrunc(app.viewport.w, layout.metrics.back_gesture_divisor),
    );
}

fn pan(app: *App, from: event_mod.EdgePan.Edge, dx: i32, phase: event_mod.EdgePan.Phase) !void {
    try app.dispatch(.{ .edge_pan = .{ .from = from, .dx = dx, .phase = phase } });
}

test "a pan past the threshold knocks, and releasing there goes back" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    const t = panThreshold(&app);

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, t - 1, .move);
    // Short of it, nothing has been promised and nothing is drawn.
    try testing.expect(!app.back_gesture.?.armed);
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);

    try pan(&app, .left, t, .move);
    try testing.expect(app.back_gesture.?.armed);
    try testing.expectEqualSlices(haptic.Knock, &.{.armed}, app.services.haptic.fired());
    // The knock is the promise, not the act: still on the same screen.
    try testing.expectEqualStrings("details", app.router.current().?);

    try pan(&app, .left, t, .end);
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expect(app.back_gesture == null);
}

test "releasing short of the threshold goes nowhere" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, panThreshold(&app) - 1, .move);
    try pan(&app, .left, panThreshold(&app) - 1, .end);
    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);
}

test "a finger at the threshold settles instead of rattling" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    const t = panThreshold(&app);
    const band = layout.metrics.back_gesture_hysteresis;

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, t, .move);
    // Retreating inside the band keeps the promise: this is the jitter
    // of a hand holding still, not a decision.
    try pan(&app, .left, t - 1, .move);
    try pan(&app, .left, t - band + 1, .move);
    try testing.expect(app.back_gesture.?.armed);
    try testing.expectEqualSlices(haptic.Knock, &.{.armed}, app.services.haptic.fired());

    // Past the band it is a decision, and it is taken back.
    try pan(&app, .left, t - band, .move);
    try testing.expect(!app.back_gesture.?.armed);
    try testing.expectEqualSlices(haptic.Knock, &.{ .armed, .disarmed }, app.services.haptic.fired());

    // And it can be made again — the gesture is not spent.
    try pan(&app, .left, t, .move);
    try testing.expectEqualSlices(
        haptic.Knock,
        &.{ .armed, .disarmed, .armed },
        app.services.haptic.fired(),
    );
    try pan(&app, .left, t, .end);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "a cancelled pan commits nothing, however far it got" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, panThreshold(&app), .move);
    // The system took the gesture away; there is no release to honour,
    // and no knock either — the user did not do this.
    try pan(&app, .left, panThreshold(&app), .cancel);
    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expect(app.back_gesture == null);
    try testing.expectEqualSlices(haptic.Knock, &.{.armed}, app.services.haptic.fired());

    // And the release that follows a cancel is not a second chance.
    try pan(&app, .left, panThreshold(&app), .end);
    try testing.expectEqualStrings("details", app.router.current().?);
}

test "with nothing to go back to, the gesture promises nothing" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");

    try pan(&app, .left, 0, .begin);
    try testing.expect(app.back_gesture == null);
    try pan(&app, .left, 10000, .move);
    try pan(&app, .left, 10000, .end);
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expectEqual(@as(usize, 1), app.router.depth());
    // The point of refusing at `.begin`: no knock announced a navigation
    // that was never going to happen.
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);
}

test "an open sheet keeps the gesture inert" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    _ = try app.presentSheet("Options");

    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, 10000, .move);
    try pan(&app, .left, 10000, .end);
    // The sheet dismisses itself, by its own close control and Escape.
    try testing.expectEqualStrings("details", app.router.current().?);
    try testing.expect(layout.findSheet(&app.tree) != null);
    try testing.expectEqual(@as(usize, 0), app.services.haptic.fired().len);
}

test "mirrored chrome mirrors its gesture" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    app.setDirection(.rtl);
    try app.navigate("home");
    try app.navigate("details");

    // Back runs against the reading direction, like the chevron.
    try pan(&app, .left, 0, .begin);
    try testing.expect(app.back_gesture == null);
    try pan(&app, .left, 10000, .end);
    try testing.expectEqualStrings("details", app.router.current().?);

    try pan(&app, .right, 0, .begin);
    try pan(&app, .right, panThreshold(&app), .move);
    try pan(&app, .right, panThreshold(&app), .end);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "the gesture and the Back control are the same act" {
    var data: CtxData = .{};
    var app = try panApp(&data);
    defer app.deinit();
    try app.navigate("home");
    try app.navigate("details");
    app.performLayout();

    // Armed, the framework's Back control says so — the threshold has
    // to be visible to someone whose device cannot buzz.
    try pan(&app, .left, 0, .begin);
    try pan(&app, .left, panThreshold(&app), .move);
    try testing.expect(app.back_gesture.?.armed);
    try testing.expect(firstChild(&app).role() == .back);

    // And what it commits is a pop like any other, scroll memory
    // included — not a second way to leave a screen.
    try pan(&app, .left, panThreshold(&app), .end);
    try testing.expectEqualStrings("home", app.router.current().?);
    try testing.expect(firstChild(&app).role() != .back);
}

test "a reference with the wrong number of arguments is refused" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");

    try testing.expectError(error.RouteArgCount, app.navigate("ticket")); // too few
    try testing.expectError(error.RouteArgCount, app.navigate("ticket~1~2")); // too many
    try testing.expectError(error.RouteArgCount, app.navigate("home~1")); // takes none
    try testing.expectError(error.UnknownRoute, app.navigate("nope~1"));

    // Refused before anything is committed, exactly like UnknownRoute.
    try testing.expectEqualStrings("home", app.router.currentRef().?);
    try testing.expectEqual(@as(usize, 1), app.router.depth());
}

test "an argument is an identifier, not a payload" {
    var data: CtxData = .{};
    var app = try argApp(&data);
    defer app.deinit();
    try app.navigate("home");

    // Free text is a URL's business, not a route's (docs/services.md).
    try testing.expectError(error.RouteArgCharset, app.navigate("ticket~has space"));
    try testing.expectError(error.RouteArgCharset, app.navigate("ticket~a/b"));
    try testing.expectError(error.RouteArgCharset, app.navigate("ticket~%20"));
    // A trailing separator is a missing argument, not an empty one.
    try testing.expectError(error.RouteArgCharset, app.navigate("ticket~"));

    // But `.` and `-` are in, which is why they are not the separator:
    // versions, ids and slugs are arguments without escaping.
    try app.navigate("ticket~1.2.3-rc1");
    try testing.expectEqualStrings("1.2.3-rc1", app.routeArg(0).?);

    // A reference arrives from outside the app, so its length is bounded
    // even when the arity checks out.
    var long: [router_mod.max_ref_bytes + 8]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..7], "ticket~");
    try testing.expectError(error.RouteRefTooLong, app.navigate(&long));
}

test "the route table is validated at init, not at first navigation" {
    try testing.expectError(error.EmptyRouteName, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "", .title = "Untitled", .build = buildLeaf }},
        .services = .mocks(),
    }));
    // Without this, `find` resolves every reference to the first of them.
    try testing.expectError(error.DuplicateRouteName, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{
            .{ .name = "home", .title = "Home", .build = buildLeaf },
            .{ .name = "home", .title = "Home", .build = buildLeaf },
        },
        .services = .mocks(),
    }));
    // A name carrying the argument separator would make every reference
    // to it ambiguous; the rest of the charset is the same rule
    // arguments obey.
    try testing.expectError(error.RouteNameCharset, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "note~42", .title = "Note~42", .build = buildLeaf }},
        .services = .mocks(),
    }));
    try testing.expectError(error.RouteNameCharset, App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "two words", .title = "Two Words", .build = buildLeaf }},
        .services = .mocks(),
    }));
}

test "tap on content scrolled under the bottom bar hits the nav item" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 200 },
        .routes = &.{
            .{ .name = "home", .title = "Home", .build = buildDetails },
            .{ .name = "away", .title = "Away", .build = buildDetails },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "away", .icon = .circle },
    });
    try app.navigate("home");
    // Overflowing content: its rects extend into the bar region.
    for (0..20) |_| {
        _ = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "filler" } });
    }
    app.performLayout();

    const nav = layout.findNav(&app.tree).?;
    var it = app.tree.children(nav);
    const first = it.next().?;
    try app.tap(app.tree.rectOf(first).center());
    try testing.expect(app.focused.?.on(first));
}

const SegCtx = struct {
    selected: usize = 99,
    fn onSelect(ctx: ?*anyopaque, selected: usize) void {
        const self: *SegCtx = @ptrCast(@alignCast(ctx.?));
        self.selected = selected;
    }
};

test "segmented: arrows move the selection and commit" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid", "Map" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(seg);

    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(seg).?.segmented.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);

    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try app.dispatch(.{ .key_down = .{ .key = .right } }); // clamps at the end
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);

    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);
}

test "segmented: tap selects the segment under the point" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.performLayout();
    const r = app.tree.rectOf(seg);

    try app.tap(.{ .x = r.right() - 4, .y = r.center().y });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(seg).?.segmented.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expect(app.focused.?.on(seg));

    // Re-tapping the selected segment does not re-fire the action.
    ctx.selected = 99;
    try app.tap(.{ .x = r.right() - 4, .y = r.center().y });
    try testing.expectEqual(@as(usize, 99), ctx.selected);
}

test "segmented: arrows scroll an overflowing track to reveal the selection" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    // 5 chips * 60px = 300 content in a 168px slot (164 inside the pads).
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    app.focused = .of(seg);

    for (0..4) |_| try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 4), app.tree.getConst(seg).?.segmented.selected);
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);

    try app.dispatch(.{ .key_down = .{ .key = .left } });
    // Chip 3 (180..240) was already visible at offset 136; no movement.
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);
}

// ---- inline links ----------------------------------------------------------

fn buildLinkHome(_: ?*anyopaque, app: *App) anyerror!void {
    // 9px per codepoint at the body scale. In a 168px content span the
    // greedy wrap breaks after "and", so the link straddles two lines:
    //   line 1 "Read the terms and"  — link bytes 9..18
    //   line 2 "conditions now."     — link bytes 19..29
    _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "terms and conditions", .route = "terms" },
        .{ .text = " now." },
    } } });
}

fn buildLinkTerms(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Terms" } });
}

const link_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = "Home", .build = buildLinkHome },
    .{ .name = "terms", .title = "Terms", .build = buildLinkTerms },
};

test "an inline link is hit on every line it wraps across, and nowhere else" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 200, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();

    const para = focus.firstFocusable(&app.tree, app.tree.rootId()).?.node;
    var buf: [layout.max_span_rects]@import("geometry.zig").Rect = undefined;
    const rects = input_mod.spanRectsOf(&app, para, 1, &buf);
    // Two rects, because the link crosses a wrap: one box around their
    // union would enclose "Read the " and claim to be the link.
    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(@as(i32, 16 + 81), rects[0].x); // past "Read the "
    try testing.expectEqual(@as(i32, 9 * 9), rects[0].w); // "terms and"
    try testing.expectEqual(@as(i32, 16), rects[1].x); // "conditions" starts the line
    try testing.expectEqual(@as(i32, 10 * 9), rects[1].w);
    try testing.expectEqual(rects[0].y + text.Scale.body.lineHeight(), rects[1].y);

    // The words before the link are prose, not a target — and both of
    // the link's own rects are.
    try testing.expectEqual(@as(?focus.Focus, null), app.hitTest(.{ .x = 20, .y = rects[0].center().y }));
    const stop: focus.Focus = .{ .node = para, .span = 1 };
    try testing.expect(app.hitTest(rects[0].center()).?.eql(stop));
    try testing.expect(app.hitTest(rects[1].center()).?.eql(stop));

    try app.tap(rects[1].center());
    try testing.expectEqualStrings("terms", app.router.current().?);
}

test "tab reaches an inline link and Enter navigates" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 200, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();
    var kids = app.tree.children(app.tree.rootId());
    const para = kids.next().?;

    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    // The paragraph is not focusable; the link inside it is.
    try testing.expect(!app.tree.getConst(para).?.isFocusable());
    try testing.expect(app.focused.?.eql(.{ .node = para, .span = 1 }));

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expectEqualStrings("terms", app.router.current().?);
}

test "an inline link to an unknown route fails where every other route does" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    const para = try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Go ", .route = "nowhere" },
        .{ .text = "please." },
    } } });
    app.performLayout();
    app.focused = .{ .node = para, .span = 0 };
    // The parser needs no router access to stay honest: the name is
    // resolved at activation, like a `link` element's.
    try testing.expectError(error.UnknownRoute, app.dispatch(.{ .key_down = .{ .key = .enter } }));
}

test "an external link span hands its URL to the browser and navigates nowhere" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    const para = try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Mail " },
        .{ .text = "us", .external = "mailto:help@example.com" },
        .{ .text = "." },
    } } });
    app.performLayout();
    app.focused = .{ .node = para, .span = 1 };
    try app.dispatch(.{ .key_down = .{ .key = .enter } });

    // The press left the app: the journal shows the handoff, and the
    // router — which never saw a destination — still stands where it
    // stood.
    const requested = app.services.open_url.opens();
    try testing.expectEqual(1, requested.len);
    try testing.expectEqualStrings("mailto:help@example.com", requested[0]);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "an external link element activates through the open_url service" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    const link = try app.tree.append(app.tree.rootId(), .{ .link = .{
        .label = "Full terms",
        .external = "https://example.com/terms",
    } });
    app.performLayout();
    try input_mod.activate(&app, link);

    const requested = app.services.open_url.opens();
    try testing.expectEqual(1, requested.len);
    try testing.expectEqualStrings("https://example.com/terms", requested[0]);
    try testing.expectEqualStrings("home", app.router.current().?);
}

test "rtl: an inline link mirrors with the paragraph it sits in" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .direction = .rtl,
        .routes = &link_routes,
        .services = .mocks(),
    });
    defer app.deinit();
    // A Persian paragraph aligns by its own bytes, so its line hangs
    // from the right margin and the runs read right to left.
    const para = try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "سلام " },
        .{ .text = "شرایط", .route = "terms" },
        .{ .text = " را بخوانید" },
    } } });
    app.performLayout();

    var buf: [layout.max_span_rects]@import("geometry.zig").Rect = undefined;
    const rects = input_mod.spanRectsOf(&app, para, 1, &buf);
    try testing.expectEqual(@as(usize, 1), rects.len);
    const r = rects[0];
    // Not at the leading (left) edge: the line hangs from the right
    // margin and the link sits inside it, one run in from the end.
    try testing.expect(r.x > 16);
    try testing.expect(r.right() < 400 - 16);

    try testing.expect(app.hitTest(r.center()).?.eql(.{ .node = para, .span = 1 }));
    // The greeting precedes it logically and therefore sits to its
    // right; it is prose, so nothing there is a target.
    try testing.expectEqual(@as(?focus.Focus, null), app.hitTest(.{ .x = r.right() + 20, .y = r.center().y }));
}

// ---- code blocks -----------------------------------------------------------

test "code block: focusable, arrows walk it sideways, up/down still page" {
    var app = try test_app.init(200, 100);
    defer app.deinit();
    // 60 codepoints at 9px = 540 in a 168px span.
    const cb = try app.tree.append(app.tree.rootId(), .{ .code_block = .{ .content = "z" ** 60 } });
    for (0..40) |_| {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    app.performLayout();
    // It scrolls, so it is a tab stop — but it never activates.
    try testing.expect(app.tree.getConst(cb).?.isFocusable());
    try testing.expect(!app.tree.getConst(cb).?.isInteractive());

    app.focused = .of(cb);
    // Four mono advances per press: 4 * 9 = 36.
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(i32, 36), app.tree.getConst(cb).?.code_block.offset);
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(cb).?.code_block.offset);
    // Already at the leading end: the clamp holds, nothing wraps.
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(cb).?.code_block.offset);

    // A focused block must not trap the page's scroll keys.
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expect(app.root_scroll > 0);
}

test "code block: horizontal wheel scrolls it; vertical passes through" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const cb = try app.tree.append(app.tree.rootId(), .{ .code_block = .{ .content = "q" ** 60 } });
    for (0..40) |_| {
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(cb).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .delta_x = 50 } });
    try testing.expectEqual(@as(i32, 50), app.tree.getConst(cb).?.code_block.offset);
    // Past the end it clamps: 540 content in the 168px window.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .delta_x = 10000 } });
    try testing.expectEqual(@as(i32, 540 - 168), app.tree.getConst(cb).?.code_block.offset);

    // Vertical delta over it belongs to the page: a code block scrolls
    // one axis, and the other is not its business.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 30 } });
    try testing.expectEqual(@as(i32, 30), app.root_scroll);
}

test "code block: the offset does not mirror, because the lines do not" {
    var app = try test_app.mirrored(200, 400);
    defer app.deinit();
    const cb = try app.tree.append(app.tree.rootId(), .{ .code_block = .{ .content = "w" ** 60 } });
    app.performLayout();

    // Verbatim content is defined by its own bytes (the QR rule), so a
    // rightward drag reveals later columns under either chrome — unlike
    // a segmented track, whose chips do lay out mirrored.
    try app.dispatch(.{ .scroll = .{ .at = app.tree.rectOf(cb).center(), .delta_y = 0, .delta_x = 40 } });
    try testing.expectEqual(@as(i32, 40), app.tree.getConst(cb).?.code_block.offset);
}

// ---- RTL chrome direction (App.setDirection) -------------------------------

test "rtl: setDirection mirrors an intrinsic block and re-lays out" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "OK" } });
    app.performLayout();
    try testing.expectEqual(@as(i32, 16), app.tree.rectOf(btn).x); // left in LTR

    app.setDirection(.rtl);
    try testing.expect(app.layout_dirty); // the switch invalidates layout
    app.performLayout();
    try testing.expectEqual(@as(i32, 400 - 16), app.tree.rectOf(btn).right()); // right in RTL

    // Setting the same direction is a no-op — no needless relayout.
    app.layout_dirty = false;
    app.setDirection(.rtl);
    try testing.expect(!app.layout_dirty);
}

test "rtl: an app can be constructed right-to-left up front" {
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "OK" } });
    app.performLayout();
    try testing.expectEqual(@as(i32, 400 - 16), app.tree.rectOf(btn).right());
}

test "rtl: segmented arrows follow the pressed direction, not the index" {
    var ctx: SegCtx = .{};
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid", "Map" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(seg);

    // Options lay out right-to-left, so the next chip is to the LEFT:
    // ← advances the selection, → steps back — the reverse of LTR.
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(seg).?.segmented.selected);
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);
    try app.dispatch(.{ .key_down = .{ .key = .left } }); // clamps
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);
}

test "rtl: radio arrows mirror horizontally but keep the vertical axis" {
    var ctx: SegCtx = .{};
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const rg = try app.tree.append(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS", "None" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(rg);

    // ↓ still advances (rows never mirror); ← advances in RTL, → steps back.
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(rg).?.radio_group.selected);
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try app.dispatch(.{ .key_down = .{ .key = .up } });
    try testing.expectEqual(@as(usize, 0), ctx.selected);
}

test "rtl: a right-edge tap on segmented selects the first (rightmost) chip" {
    var ctx: SegCtx = .{};
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(seg);
    app.performLayout();
    const r = app.tree.rectOf(seg);

    // The first option holds the right end when mirrored — the reverse
    // of the LTR "right-edge tap selects the last chip" test above.
    try app.tap(.{ .x = r.right() - 4, .y = r.center().y });
    try testing.expectEqual(@as(usize, 0), app.tree.getConst(seg).?.segmented.selected);
}

test "rtl: the sheet close control pins to the left corner" {
    var app = try test_app.mirrored(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    _ = try app.tree.append(sheet, .{ .text = .{ .content = "body" } });
    app.performLayout();

    var it = app.tree.children(sheet);
    const close = while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .sheet_close) break c;
    } else unreachable;
    try testing.expectEqual(layout.paneX(app.viewport) + layout.pane_edge, app.tree.rectOf(close).x);
}

test "rtl: a lone minimized-notices indicator centers, having no edge to swap" {
    var app = try test_app.mirrored(400, 600);
    defer app.deinit();
    try app.notify("Saved", "", "home");
    app.minimizeNotices();
    app.performLayout();
    const ind = layout.findIndicator(&app.tree).?;
    // No nav here, so the square is the whole of the bar's group and
    // centers as one — the same place under either direction, because a
    // centered control is its own mirror image. It is the pane's corner
    // it no longer keeps: the sheet cap governs prose, and this is a
    // control.
    try testing.expectEqual(
        layout.navGroupX(app.viewport, layout.metrics.touch_target),
        app.tree.rectOf(ind).x,
    );

    var ltr = try test_app.init(400, 600);
    defer ltr.deinit();
    try ltr.notify("Saved", "", "home");
    ltr.minimizeNotices();
    ltr.performLayout();
    try testing.expectEqual(
        ltr.tree.rectOf(layout.findIndicator(&ltr.tree).?),
        app.tree.rectOf(ind),
    );
}

test "segmented: horizontal scroll moves the track without changing the selection" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    app.performLayout();
    const at = app.tree.rectOf(seg).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = 60, .delta_y = 0 } });
    try testing.expectEqual(@as(i32, 60), app.tree.getConst(seg).?.segmented.offset);
    try testing.expectEqual(@as(usize, 0), app.tree.getConst(seg).?.segmented.selected);

    // Free scroll survives an unrelated relayout: no snap back.
    app.invalidate();
    app.performLayout();
    try testing.expectEqual(@as(i32, 60), app.tree.getConst(seg).?.segmented.offset);

    // Clamped at both ends.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = 10000, .delta_y = 0 } });
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = -10000, .delta_y = 0 } });
    try testing.expectEqual(@as(i32, 0), app.tree.getConst(seg).?.segmented.offset);
}

test "segmented: a touch drag keeps the track after the finger drifts off it" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    app.performLayout();
    const at = app.tree.rectOf(seg).center();

    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .begin } });
    // The move's point is far below the track; the lock still routes to it.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 100, .y = 300 }, .delta_x = 60, .delta_y = 0, .phase = .move } });
    try testing.expectEqual(@as(i32, 60), app.tree.getConst(seg).?.segmented.offset);
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .end } });
}

test "scroll: the dominant axis wins and the minor one is dropped" {
    var app = try test_app.init(200, 100);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{ .label = "K", .options = opts } });
    // Tall filler so the window itself can scroll vertically.
    for (0..20) |_| _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Filler" } });
    app.performLayout();
    const at = app.tree.rectOf(seg).center();

    // Mostly horizontal: the slight vertical jitter must not move the page.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = 40, .delta_y = 3 } });
    try testing.expectEqual(@as(i32, 40), app.tree.getConst(seg).?.segmented.offset);
    try testing.expectEqual(@as(i32, 0), app.root_scroll);

    // Mostly vertical: the slight horizontal jitter must not move the track.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_x = -3, .delta_y = 40 } });
    try testing.expectEqual(@as(i32, 40), app.tree.getConst(seg).?.segmented.offset);
    try testing.expectEqual(@as(i32, 40), app.root_scroll);
}

test "segmented: tap honors the scroll offset" {
    var app = try test_app.init(200, 400);
    defer app.deinit();
    const opts: []const []const u8 = &.{ "AAAA", "AAAA", "AAAA", "AAAA", "AAAA" };
    const seg = try app.tree.append(app.tree.rootId(), .{ .segmented = .{
        .label = "K",
        .options = opts,
        .selected = 4,
    } });
    app.performLayout();
    try testing.expectEqual(@as(i32, 136), app.tree.getConst(seg).?.segmented.offset);
    const r = app.tree.rectOf(seg);

    // At offset 136 the track's left edge shows chip 2 (content 120..180).
    try app.tap(.{ .x = r.x + 6, .y = r.center().y });
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(seg).?.segmented.selected);
    // The tapped chip, clipped at the edge, scrolls fully into view.
    try testing.expectEqual(@as(i32, 120), app.tree.getConst(seg).?.segmented.offset);
}

test "radio group: arrows move the selection and commit" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const rg = try app.tree.append(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS", "None" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(rg);

    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);

    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .down } }); // clamps at the end
    try testing.expectEqual(@as(usize, 2), app.tree.getConst(rg).?.radio_group.selected);

    try app.dispatch(.{ .key_down = .{ .key = .up } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);

    // ←/→ mirror ↑/↓, matching ARIA radio-group practice.
    try app.dispatch(.{ .key_down = .{ .key = .left } });
    try testing.expectEqual(@as(usize, 0), ctx.selected);
    try app.dispatch(.{ .key_down = .{ .key = .right } });
    try testing.expectEqual(@as(usize, 1), ctx.selected);
}

test "radio group: tap selects the row under the point" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const rg = try app.tree.append(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.performLayout();
    const r = app.tree.rectOf(rg);

    try app.tap(.{ .x = r.x + 4, .y = r.bottom() - 4 });
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(rg).?.radio_group.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expect(app.focused.?.on(rg));

    // Re-tapping the selected row does not re-fire the action.
    ctx.selected = 99;
    try app.tap(.{ .x = r.x + 4, .y = r.bottom() - 4 });
    try testing.expectEqual(@as(usize, 99), ctx.selected);

    try app.tap(.{ .x = r.x + 4, .y = r.y + layout.radioRowY(0) + 4 });
    try testing.expectEqual(@as(usize, 0), ctx.selected);
}

test "select: enter opens the picker focused on the current choice" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch", "Français" },
        .selected = 1,
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const picker = layout.findPicker(&app.tree).?;
    try testing.expectEqualStrings("Language", app.tree.getConst(picker).?.picker.title);
    const item = app.tree.getConst(app.focused.?.node).?.picker_item;
    try testing.expectEqualStrings("Deutsch", item.label);
    try testing.expect(item.selected);
}

test "picker: escape closes without committing and restores focus" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 0), app.tree.getConst(sel).?.select.selected);
    try testing.expectEqual(@as(usize, 99), ctx.selected);
    try testing.expect(app.focused.?.on(sel));
}

test "picker: activating a row commits the choice and closes" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch", "Français" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(sel).?.select.selected);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expect(app.focused.?.on(sel));

    // Re-choosing the current option does not re-fire the action.
    ctx.selected = 99;
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expectEqual(@as(usize, 99), ctx.selected);
}

const filter_test_options: []const []const u8 = &.{
    "Argentina", "Australia", "Austria", "Brazil",  "Canada",
    "Denmark",   "Germany",   "Iceland", "Ireland",
};

test "picker: long option lists gain a filter field, focused on open" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Country",
        .options = filter_test_options,
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const input = app.tree.getConst(app.focused.?.node).?.text_input;
    try testing.expectEqualStrings("Filter", input.label);

    // Short lists stay bare and keep focus on the current choice.
    var short = try test_app.init(400, 600);
    defer short.deinit();
    const s = try short.tree.append(short.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    short.focused = .of(s);
    try short.dispatch(.{ .key_down = .{ .key = .enter } });
    const picker = layout.findPicker(&short.tree).?;
    var it = short.tree.children(picker);
    while (it.next()) |c| {
        try testing.expect(short.tree.getConst(c).?.role() != .text_input);
    }
    try testing.expect(short.tree.getConst(short.focused.?.node).?.role() == .picker_item);
}

test "picker: typing filters rows and a filtered row commits its option index" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Country",
        .options = filter_test_options,
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .text = .{ .bytes = "ice" } }); // case-insensitive: Iceland
    const picker = layout.findPicker(&app.tree).?;
    var region: ?NodeId = null;
    var it = app.tree.children(picker);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .scroll_region) region = c;
    }
    try testing.expectEqual(@as(usize, 1), app.tree.childCount(region.?));

    // Tab to the lone row and commit: the original option index fires.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expectEqualStrings("Iceland", app.tree.getConst(app.focused.?.node).?.picker_item.label);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 7), ctx.selected);
    try testing.expectEqual(@as(usize, 7), app.tree.getConst(sel).?.select.selected);
}

test "picker: backspace re-widens the filter and no matches leaves words" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Country",
        .options = filter_test_options,
    } });
    app.focused = .of(sel);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });

    const regionOf = struct {
        fn call(a: *App) NodeId {
            const picker = layout.findPicker(&a.tree).?;
            var it = a.tree.children(picker);
            while (it.next()) |c| {
                if (a.tree.getConst(c).?.role() == .scroll_region) return c;
            }
            unreachable;
        }
    }.call;

    try app.dispatch(.{ .text = .{ .bytes = "xyz" } });
    const region = regionOf(&app);
    try testing.expectEqual(@as(usize, 1), app.tree.childCount(region));
    var it = app.tree.children(region);
    const lone = app.tree.getConst(it.next().?).?;
    try testing.expect(lone.role() == .text);
    try testing.expectEqualStrings("No matches", lone.text.content);

    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try app.dispatch(.{ .key_down = .{ .key = .backspace } });
    try testing.expectEqual(filter_test_options.len, app.tree.childCount(regionOf(&app)));
}

test "picker: arrows clamp at the option list ends" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try app.dispatch(.{ .key_down = .{ .key = .up } }); // already first: stays
    try testing.expectEqualStrings("English", app.tree.getConst(app.focused.?.node).?.picker_item.label);
    try app.dispatch(.{ .key_down = .{ .key = .down } });
    try app.dispatch(.{ .key_down = .{ .key = .down } }); // clamps at the end
    try testing.expectEqualStrings("Deutsch", app.tree.getConst(app.focused.?.node).?.picker_item.label);
}

test "picker: taps commit on a row and cancel on the scrim" {
    var ctx: SegCtx = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.append(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
        .on_select = .{ .ctx = &ctx, .call = SegCtx.onSelect },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    app.performLayout();
    try app.tap(.{ .x = 4, .y = 4 }); // scrim: cancels
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 99), ctx.selected);
    try testing.expect(app.focused.?.on(sel));

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    app.performLayout();
    const picker = layout.findPicker(&app.tree).?;
    var region_it = app.tree.children(picker);
    const region = region_it.next().?;
    var it = app.tree.children(region);
    _ = it.next();
    const second = it.next().?;
    try app.tap(app.tree.rectOf(second).center());
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expectEqual(@as(usize, 1), ctx.selected);
    try testing.expectEqual(@as(usize, 1), app.tree.getConst(sel).?.select.selected);
}

test "picker stacks above an open sheet and escape peels one layer" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    const sel = try app.tree.append(sheet, .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    app.focused = .of(sel);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const picker = layout.findPicker(&app.tree).?;
    try testing.expect(app.focusScope().eql(picker));

    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findPicker(&app.tree) == null);
    try testing.expect(layout.findSheet(&app.tree) != null);
    try testing.expect(app.focused.?.on(sel));

    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findSheet(&app.tree) == null);
}

test "presentSheet focuses its close button and confines tab to the sheet" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Behind" } });
    app.focused = .of(behind);

    const sheet = try app.presentSheet("Options");
    const close = focus.firstFocusable(&app.tree, sheet).?.node;
    try testing.expect(app.focused.?.on(close));

    const extra = try app.tree.append(sheet, .{ .toggle = .{ .label = "Wrap text" } });
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(extra));
    // Wraps inside the sheet; "Behind" is unreachable while it is open.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.focused.?.on(close));
}

test "escape dismisses the sheet and restores focus to the invoker" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Behind" } });
    app.focused = .of(behind);

    _ = try app.presentSheet("Options");
    try app.dispatch(.{ .key_down = .{ .key = .escape } });

    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.focused.?.on(behind));
}

test "tap on the scrim dismisses the sheet; background is not hittable" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const behind = try app.tree.append(app.tree.rootId(), .{ .button = .{
        .label = "Behind",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });
    app.performLayout();
    const behind_center = app.tree.rectOf(behind).center();

    _ = try app.presentSheet("Options");
    // The background button sits under the scrim: tapping it must not
    // activate it, only dismiss the sheet.
    try app.tap(behind_center);
    try testing.expectEqual(@as(u32, 0), counter.count);
    try testing.expect(layout.findSheet(&app.tree) == null);

    try app.tap(behind_center);
    try testing.expectEqual(@as(u32, 1), counter.count);
}

test "notify shows the front notice as a banner and dedups by title" {
    var app = try test_app.init(400, 600);
    defer app.deinit();

    try app.notify("Saved", "", "home");
    try app.notify("Sync failed", "Changes kept locally.", "details");
    try app.notify("Saved", "", "home"); // duplicate: dropped
    try testing.expectEqual(@as(usize, 2), app.notices.items.len);
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);

    const first = layout.findNotice(&app.tree).?;
    try testing.expectEqualStrings("Saved", app.tree.getConst(first).?.notice.title);

    app.dismissNotice();
    const second = layout.findNotice(&app.tree).?;
    try testing.expectEqualStrings("Sync failed", app.tree.getConst(second).?.notice.title);

    app.dismissNotice();
    try testing.expect(layout.findNotice(&app.tree) == null);
    try testing.expectEqual(App.NoticeState.none, app.notice_state);
}

test "the banner reserves its band at the viewport bottom" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Go" } });

    app.performLayout();
    const before = app.tree.rectOf(btn).y;

    try app.notify("Saved", "", "home");
    app.performLayout();
    const banner = app.tree.rectOf(layout.findNotice(&app.tree).?);
    try testing.expect(banner.h > 0);
    try testing.expectEqual(@as(i32, 600), banner.bottom());
    try testing.expectEqual(banner.y, layout.contentArea(&app.tree, app.viewport, app.safe_bottom).bottom());
    try testing.expectEqual(before, app.tree.rectOf(btn).y);
}

test "notice never steals focus and dismissal keeps focus sane" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Go" } });
    app.focused = .of(btn);

    try app.notify("Saved", "", "home");
    try testing.expect(app.focused.?.on(btn));

    // Focus a banner control, then dismiss: focus must not dangle.
    const notice = layout.findNotice(&app.tree).?;
    app.focused = focus.firstFocusable(&app.tree, notice).?;
    app.dismissNotice();
    try testing.expect(app.focused == null);
}

test "notices expand to the pane, minimize to the indicator, and reopen" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    try app.notify("Saved", "", "home");
    try app.notify("Sync failed", "", "details");

    // With several pending, the banner leads with the expand control.
    const banner = layout.findNotice(&app.tree).?;
    const expand = focus.firstFocusable(&app.tree, banner).?.node;
    try testing.expectEqual(element_mod.Glyph.expand, app.tree.getConst(expand).?.icon_button.glyph);
    try app.activate(expand);
    try testing.expect(layout.findNoticesPane(&app.tree) != null);
    try testing.expectEqual(App.NoticeState.pane, app.notice_state);

    // Esc minimizes; the notices stay pending behind the indicator.
    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expect(layout.findNoticesPane(&app.tree) == null);
    try testing.expectEqual(@as(usize, 2), app.notices.items.len);
    const indicator = layout.findIndicator(&app.tree).?;

    try app.activate(indicator);
    try testing.expect(layout.findNoticesPane(&app.tree) != null);
}

/// The pane's scroll region, and the rows it holds.
fn noticesRegion(app: *App) ?NodeId {
    const pane = layout.findNoticesPane(&app.tree) orelse return null;
    var it = app.tree.children(pane);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .scroll_region) return c;
    }
    return null;
}

test "the notices pane keeps its rows reachable on a landscape viewport" {
    // A phone on its side: `sheet_min_top` is a bigger share of 390 than
    // of 844, so the pane runs out of room after very few notices. The
    // rows used to be flowed into it unbounded and simply clipped at its
    // edge, which lost them — no wheel, no drag, no tab stop reached
    // them, and the pane gave no sign there was more.
    var app = try test_app.init(844, 390);
    defer app.deinit();
    for ([_][]const u8{ "Settings saved", "Sync failed", "Primes counted", "Payload hashed", "Export ready" }) |t| {
        try app.notify(t, "This notice stays until dismissed or minimized.", "home");
    }
    try app.openNoticesPane();
    app.performLayout();

    const pane = layout.findNoticesPane(&app.tree).?;
    const pr = app.tree.rectOf(pane);
    const reg = noticesRegion(&app).?;
    const rr = app.tree.rectOf(reg);

    // The pane still honours its cap and the region still sits inside it.
    try testing.expect(pr.y >= layout.metrics.sheet_min_top);
    try testing.expect(pr.bottom() <= 390);
    try testing.expect(rr.bottom() <= pr.bottom());

    // There is more content than room, and the region says so — which is
    // what makes it scrollable and what draws the indicator.
    const sr = app.tree.getConst(reg).?.scroll_region;
    try testing.expect(sr.content_height > rr.h);

    // And it is reachable: a scroll region is focusable precisely so the
    // hidden rows have a keyboard route (WCAG 2.1.1).
    try testing.expect(app.tree.getConst(reg).?.isFocusable());
    const before = app.tree.getConst(reg).?.scroll_region.offset;
    try app.dispatch(.{ .scroll = .{ .at = rr.center(), .delta_y = 80 } });
    try testing.expect(app.tree.getConst(reg).?.scroll_region.offset > before);
    // The last row lands inside the region once scrolled to the end.
    try app.dispatch(.{ .scroll = .{ .at = rr.center(), .delta_y = 10000 } });
    app.performLayout();
    var rows = app.tree.children(reg);
    var last: ?NodeId = null;
    while (rows.next()) |c| last = c;
    try testing.expect(app.tree.rectOf(last.?).bottom() <= app.tree.rectOf(reg).bottom());
}

test "a notices pane that fits takes only the height it needs" {
    var app = try test_app.init(400, 800);
    defer app.deinit();
    try app.notify("Saved", "", "home");
    try app.openNoticesPane();
    app.performLayout();

    const pr = app.tree.rectOf(layout.findNoticesPane(&app.tree).?);
    const reg = noticesRegion(&app).?;
    const sr = app.tree.getConst(reg).?.scroll_region;
    // Nothing hidden, nothing to scroll, and the pane is far short of the
    // cap: the region is exactly its content.
    try testing.expectEqual(sr.content_height, app.tree.rectOf(reg).h);
    try testing.expect(pr.h < 800 - layout.metrics.sheet_min_top);
    try testing.expectEqual(@as(i32, 800), pr.bottom());
}

test "the pane's dismiss controls remove one notice or all" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    try app.notify("Saved", "", "home");
    try app.notify("Sync failed", "", "details");
    try app.openNoticesPane();

    const pane = layout.findNoticesPane(&app.tree).?;
    var dismiss: ?NodeId = null;
    var it = app.tree.dfsUnder(pane);
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.* == .icon_button and el.icon_button.glyph == .dismiss) {
            dismiss = id;
            break;
        }
    }
    try app.activate(dismiss.?);
    try testing.expectEqual(@as(usize, 1), app.notices.items.len);
    try testing.expectEqualStrings("Sync failed", app.notices.items[0].title);
    try testing.expect(layout.findNoticesPane(&app.tree) != null);

    app.dismissAllNotices();
    try testing.expectEqual(App.NoticeState.none, app.notice_state);
    try testing.expect(layout.findNoticesPane(&app.tree) == null);
    try testing.expect(layout.findIndicator(&app.tree) == null);
}

test "a new notice re-surfaces minimized ones as the banner" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    try app.notify("Saved", "", "home");
    app.minimizeNotices();
    try testing.expect(layout.findIndicator(&app.tree) != null);

    try app.notify("Sync failed", "", "details");
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);
    try testing.expect(layout.findNotice(&app.tree) != null);
    try testing.expect(layout.findIndicator(&app.tree) == null);
}

test "a sheet suppresses notice chrome to the indicator until dismissed" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    try app.notify("Saved", "", "home");

    _ = try app.presentSheet("Options");
    try testing.expect(layout.findNotice(&app.tree) == null);
    try testing.expect(layout.findIndicator(&app.tree) != null);
    try testing.expectEqual(App.NoticeState.banner, app.notice_state);

    app.dismissSheet();
    try testing.expect(layout.findNotice(&app.tree) != null);
    try testing.expect(layout.findIndicator(&app.tree) == null);
}

test "the banner hides the nav from pointer and keyboard alike" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 600 },
        .routes = &.{
            .{ .name = "home", .title = "Home", .build = buildDetails },
            .{ .name = "away", .title = "Away", .build = buildDetails },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "away", .icon = .circle },
    });
    try app.navigate("home");
    try app.notify("Saved", "", "home");
    app.performLayout();

    const nav = layout.findNav(&app.tree).?;
    try testing.expectEqual(@as(i32, 0), app.tree.rectOf(nav).w);

    // Tab cycles through banner controls and content, never nav items.
    var hops: usize = 0;
    while (hops < 16) : (hops += 1) {
        try app.dispatch(.{ .key_down = .{ .key = .tab } });
        const f = app.focused.?.node;
        try testing.expect(!app.tree.isDescendant(f, nav));
    }
}

test "copyText journals into the app's clipboard mock" {
    const Copier = struct {
        app: *App,
        fn onPress(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.app.copyText("XKCD-1234");
        }
    };

    var app = try test_app.init(400, 400);
    defer app.deinit();
    var copier: Copier = .{ .app = &app };
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{
        .label = "Copy code",
        .on_press = .{ .ctx = &copier, .call = Copier.onPress },
    } });
    app.performLayout();

    try app.tap(app.tree.rectOf(btn).center());
    const copies = app.services.clipboard.copies();
    try testing.expectEqual(1, copies.len);
    try testing.expectEqualStrings("XKCD-1234", copies[0]);
}

test "activating a copyable writes its value to the clipboard" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const c = try app.tree.append(app.tree.rootId(), .{ .copyable = .{
        .label = "Recovery code",
        .value = "XKCD-1234",
    } });
    app.performLayout();

    // Tap copies; so do Enter and Space on the focused field. The
    // journal keeps program order, so both writes are on the record.
    try app.tap(app.tree.rectOf(c).center());
    try testing.expectEqualStrings("XKCD-1234", app.services.clipboard.copies()[0]);
    try testing.expect(app.focused.?.on(c));

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    const copies = app.services.clipboard.copies();
    try testing.expectEqual(2, copies.len);
    try testing.expectEqualStrings("XKCD-1234", copies[1]);
}

test "acknowledgement latches on the copyable that just copied" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const a = try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
    const b = try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Invite link", .value = "nok.re/x" } });
    const btn = try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Done" } });
    app.performLayout();
    try testing.expect(app.ack == null);

    try app.tap(app.tree.rectOf(a).center());
    try testing.expect(app.ack.?.eql(a));

    // Only one element is ever marked: the second copyable takes it.
    try app.tap(app.tree.rectOf(b).center());
    try testing.expect(app.ack.?.eql(b));
    try testing.expectEqual(2, app.services.clipboard.copies().len);

    // Activating the marked element again copies again and toggles the
    // mark off — the only visible sign the second copy happened.
    try app.tap(app.tree.rectOf(b).center());
    try testing.expect(app.ack == null);
    const copies = app.services.clipboard.copies();
    try testing.expectEqual(3, copies.len);
    try testing.expectEqualStrings("nok.re/x", copies[2]);

    // ...and a third activation marks it once more: the toggle is on the
    // mark, never on the copy.
    try app.tap(app.tree.rectOf(b).center());
    try testing.expect(app.ack.?.eql(b));
    try testing.expectEqual(4, app.services.clipboard.copies().len);

    // Anything else on the screen releases it.
    try app.tap(app.tree.rectOf(btn).center());
    try testing.expect(app.ack == null);
}

test "any input releases the acknowledgement, scrolling included" {
    var app = try test_app.init(400, 120);
    defer app.deinit();
    const c = try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    app.performLayout();

    // Enter on the focused field arms it exactly as a tap does.
    try app.tap(app.tree.rectOf(c).center());
    try testing.expect(app.ack.?.eql(c));

    // Unlike `scroll_hot` there is no scroll exemption: nothing arms this
    // latch but activation, so every event releases it.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 60 }, .delta_y = 20 } });
    try testing.expect(app.ack == null);

    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(app.ack.?.eql(c));

    // Tab moves focus and takes the mark with it.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    try testing.expect(app.ack == null);
}

test "navigating away leaves no acknowledgement behind" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "home", .title = "Home", .build = buildCopyScreen },
            .{ .name = "next", .title = "Next", .build = buildLeaf },
        },
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();
    var kids = app.tree.children(app.tree.rootId());
    const c = kids.next().?;
    try app.tap(app.tree.rectOf(c).center());
    try testing.expect(app.ack != null);

    // The mark names a node, and a rebuild retires every node it named —
    // so it is dropped there, like the other latched ids.
    try app.navigate("next");
    app.performLayout();
    try testing.expect(app.ack == null);
}

fn buildCopyScreen(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
}

test "scroll emphasis latches on the moved surface until other input" {
    var app = try test_app.init(400, 100);
    defer app.deinit();
    const sr = try app.tree.append(app.tree.rootId(), .{ .scroll_region = .{ .height = 50 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try app.tree.append(sr, .{ .text = .{ .content = "line" } });
        _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    app.performLayout();
    const at = app.tree.rectOf(sr).center();
    try testing.expect(app.scroll_hot == .none);

    // A touch drag: the latch survives the gesture's end — there is no
    // timer to fade the bar, only the next non-scroll input.
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .begin } });
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 20, .phase = .move } });
    try app.dispatch(.{ .scroll = .{ .at = at, .delta_y = 0, .phase = .end } });
    try testing.expect(app.scroll_gesture == null);
    try testing.expect(app.scroll_hot.node.eql(sr));

    // A tap that scrolls nothing releases it.
    try app.tap(.{ .x = 5, .y = 95 });
    try testing.expect(app.scroll_hot == .none);

    // Wheel outside the region moves the window: the latch follows the
    // surface that actually moved.
    try app.dispatch(.{ .scroll = .{ .at = .{ .x = 200, .y = 90 }, .delta_y = 30 } });
    try testing.expect(app.scroll_hot == .window);
}

// ---- the folded tail of a row of actions (overflow.zig) ---------------------

/// The same five buttons the layout tests use — 373px of row in a 368px
/// span — with a counter on the last one, which is where the fold puts
/// the interesting question: it is reachable only through the sheet.
fn buildOverflowingRow(app: *App, counter: *PressCounter) !NodeId {
    const row = try app.tree.append(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "One", "Two", "Three", "Four" }) |label| {
        _ = try app.tree.append(row, .{ .button = .{ .label = label } });
    }
    _ = try app.tree.append(row, .{ .button = .{
        .label = "Five",
        .on_press = .{ .ctx = counter, .call = PressCounter.onPress },
    } });
    return row;
}

fn childOfRole(app: *const App, parent: NodeId, role: element_mod.Role) ?NodeId {
    var it = app.tree.children(parent);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == role) return c;
    }
    return null;
}

fn labelsUnder(app: *const App, parent: NodeId, role: element_mod.Role, out: [][]const u8) usize {
    var n: usize = 0;
    var it = app.tree.children(parent);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.role() == role) {
            out[n] = el.label();
            n += 1;
        }
    }
    return n;
}

test "an overflowing row grows a More control that opens the rest" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();

    // One pass decides the fold, the sync installs the control, and the
    // second pass places it — all inside `performLayout`, so a shell
    // never sees the half-built shape.
    const more = childOfRole(&app, row, .more) orelse return error.NoMoreControl;
    try testing.expect(app.tree.rectOf(more).w > 0);
    try testing.expect(!app.layout_dirty);

    // A tap, not a synthetic activation: the control is a real target at
    // the trailing end of the row.
    try app.tap(app.tree.rectOf(more).center());
    const sheet = layout.findSheet(&app.tree) orelse return error.NoSheet;
    try testing.expectEqualStrings("More", app.tree.getConst(sheet).?.sheet.title);

    // The button that gave up its slot leads the sheet, then the ones
    // that had actually overflowed — the row's own order.
    var labels: [5][]const u8 = undefined;
    const n = labelsUnder(&app, sheet, .button, &labels);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Four", labels[0]);
    try testing.expectEqualStrings("Five", labels[1]);
}

test "pressing a folded button runs its action and closes the tail sheet" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);

    const sheet = layout.findSheet(&app.tree).?;
    var restated: ?NodeId = null;
    var it = app.tree.children(sheet);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.role() == .button and std.mem.eql(u8, el.label(), "Five")) restated = c;
    }
    app.performLayout();
    try app.tap(app.tree.rectOf(restated.?).center());

    // The action the row declared, run through the sheet's copy of it —
    // and the sheet goes, the way choosing a row closes a picker.
    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.more_sheet == null);
}

test "a widened viewport gives the folded buttons back" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    try testing.expect(childOfRole(&app, row, .more) != null);

    app.setViewport(.{ .w = 800, .h = 400 });
    app.performLayout();
    // No control, nothing folded, five buttons standing again.
    try testing.expect(childOfRole(&app, row, .more) == null);
    var labels: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 5), labelsUnder(&app, row, .button, &labels));
    var it = app.tree.children(row);
    while (it.next()) |c| {
        try testing.expect(!app.tree.getConst(c).?.button.folded);
        try testing.expect(app.tree.rectOf(c).w > 0);
    }
}

test "focus follows the fold rather than being dropped by it" {
    var counter: PressCounter = .{};
    var app = try test_app.init(800, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    var it = app.tree.children(row);
    var last: NodeId = undefined;
    while (it.next()) |c| last = c;
    app.focused = .of(last); // "Five", standing on the wide viewport

    // The viewport narrows and the button the user was on folds away.
    // Focus lands on the control that now holds it — not back at the top
    // of the tab order (WCAG 3.2.2).
    app.setViewport(.{ .w = 400, .h = 400 });
    app.performLayout();
    const more = childOfRole(&app, row, .more).?;
    try testing.expect(app.focused.?.on(more));

    // Wide again: the control goes, and focus stays at the row's
    // trailing end instead of following it out of the tree.
    app.setViewport(.{ .w = 800, .h = 400 });
    app.performLayout();
    try testing.expect(app.tree.getConst(more) == null);
    try testing.expect(app.focused.?.on(last));
}

test "a folded button is neither a focus stop nor a target" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();

    var folded: NodeId = undefined;
    var it = app.tree.children(row);
    while (it.next()) |c| {
        const el = app.tree.getConst(c).?;
        if (el.* == .button and el.button.folded) folded = c;
    }
    try testing.expect(!app.tree.getConst(folded).?.isFocusable());
    // Tab from the last standing button reaches the control, never the
    // buttons behind it.
    const more = childOfRole(&app, row, .more).?;
    app.focused = null;
    var stops: usize = 0;
    var stop = focus.nextFocusable(&app.tree, app.tree.rootId(), null);
    while (stop) |s| : (stop = focus.nextFocusable(&app.tree, app.tree.rootId(), s)) {
        stops += 1;
        if (stops == 4) break;
    }
    try testing.expect(stop.?.on(more)); // One, Two, Three, then More
}

test "a row of actions inside a sheet does not fold" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Share");
    const row = try app.tree.append(sheet, .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "One", "Two", "Three", "Four", "Five" }) |label| {
        _ = try app.tree.append(row, .{ .button = .{
            .label = label,
            .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
        } });
    }
    app.performLayout();

    // A sheet is the one layer a sheet cannot open over, so the tail has
    // nowhere to go and the row keeps every button it was given.
    try testing.expect(childOfRole(&app, row, .more) == null);
    var it = app.tree.children(row);
    while (it.next()) |c| {
        try testing.expect(!app.tree.getConst(c).?.button.folded);
    }
}

test "focus follows a second fold, when the control is already standing" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    // Three standing, "Four"/"Five" folded, the control already there.
    const more = childOfRole(&app, row, .more).?;
    var it = app.tree.children(row);
    _ = it.next();
    _ = it.next();
    const third = it.next().?; // "Three"
    app.focused = .of(third);

    // Narrower still: "Three" folds too, into a control that was
    // installed passes ago. Focus has to follow it there anyway.
    app.setViewport(.{ .w = 260, .h = 400 });
    app.performLayout();
    try testing.expect(app.tree.getConst(third).?.button.folded);
    try testing.expect(app.focused.?.on(more));
}

test "the tail sheet closes when the fold behind it moves" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);
    try testing.expect(app.more_sheet != null);

    // The window grew and the buttons are standing on the row again. A
    // sheet still listing them would show each of them twice — and
    // press the copy.
    app.setViewport(.{ .w = 900, .h = 400 });
    app.performLayout();
    try testing.expect(layout.findSheet(&app.tree) == null);
    try testing.expect(app.more_sheet == null);
    try testing.expect(!app.layout_dirty); // the dismissal was laid out, not deferred

    // The other direction: a deeper fold means the open list no longer
    // names everything hidden behind it, which is the same lie.
    app.setViewport(.{ .w = 400, .h = 400 });
    app.performLayout();
    try app.activate(childOfRole(&app, row, .more).?);
    try testing.expect(app.more_sheet != null);
    app.setViewport(.{ .w = 260, .h = 400 });
    app.performLayout();
    try testing.expect(layout.findSheet(&app.tree) == null);
}

test "a settled row reports no further chrome changes" {
    var counter: PressCounter = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try buildOverflowingRow(&app, &counter);
    app.performLayout();
    // The second pass inside `performLayout` must find nothing left to
    // do, or every frame would rebuild the row's chrome.
    try testing.expect(!overflow.syncOverflowChrome(&app));
    try testing.expect(!app.layout_dirty);
}

test "a row of buttons and a link folds, and the link is still a link in the sheet" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 480, .h = 640 },
        .routes = &.{ .{ .name = "home", .title = "Home", .build = buildHomeWithActionRow }, .{ .name = "details", .title = "Details", .build = buildEmpty } },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.navigate("home");
    app.performLayout();

    // The shape a real screen has: actions, and a link among them. One
    // trailing link must not be what decides whether a row of actions
    // gets the fold at all.
    const row = app.tree.rootChild(.stack) orelse blk: {
        var it = app.tree.children(app.tree.rootId());
        break :blk it.next().?;
    };
    const more = childOfRole(&app, row, .more) orelse return error.NoMoreControl;
    try app.activate(more);

    // Restated whole: the link arrives as a link carrying its route, not
    // as a button wearing its words.
    const sheet = layout.findSheet(&app.tree).?;
    var link: ?NodeId = null;
    var it = app.tree.children(sheet);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.* == .link) link = c;
    }
    const el = app.tree.getConst(link.?).?.link;
    try testing.expectEqualStrings("More details", el.label);
    try testing.expectEqualStrings("details", el.route);

    // And it navigates from there like any other link.
    try app.activate(link.?);
    try testing.expectEqualStrings("details", app.router.current().?);
}

fn buildHomeWithActionRow(_: ?*anyopaque, app: *App) anyerror!void {
    const row = try app.tree.append(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    _ = try app.tree.append(row, .{ .button = .{ .label = "Save" } });
    _ = try app.tree.append(row, .{ .button = .{ .label = "Cancel", .secondary = true } });
    _ = try app.tree.append(row, .{ .button = .{ .label = "Add reminder" } });
    _ = try app.tree.append(row, .{ .button = .{ .label = "Disabled", .disabled = true } });
    _ = try app.tree.append(row, .{ .link = .{ .label = "More details", .route = "details" } });
}

fn buildEmpty(_: ?*anyopaque, app: *App) anyerror!void {
    _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Details" } });
}
