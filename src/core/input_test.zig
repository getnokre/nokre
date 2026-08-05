//! Tests for input.zig and scrolling.zig, driven the way a shell
//! drives them — through `App.dispatch`: press and release (WCAG
//! 2.5.2), the keyboard, typing and IME, and the scroll chain.
//! Split from app_test.zig; the dispatch tests that cross into other
//! concerns (overlays, notices, the nav) stay there.

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const focus = @import("focus.zig");
const geometry = @import("geometry.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");
const test_app = @import("test_app.zig");

const App = app_mod.App;
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
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Go",
        .on_press = .{ .ctx = &counter, .call = PressCounter.onPress },
    } });

    app.performLayout();
    const center = app.tree.rectOf(btn).center();
    try app.tap(center);

    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expect(app.focused.?.on(btn));
}

const RowRecorder = struct {
    presses: u32 = 0,
    index: usize = std.math.maxInt(usize),
    checked: bool = false,
    fn onPress(ctx: ?*anyopaque, index: usize) void {
        const self: *RowRecorder = @ptrCast(@alignCast(ctx.?));
        self.presses += 1;
        self.index = index;
    }
    fn onToggle(ctx: ?*anyopaque, index: usize, checked: bool) void {
        const self: *RowRecorder = @ptrCast(@alignCast(ctx.?));
        self.presses += 1;
        self.index = index;
        self.checked = checked;
    }
};

test "an indexed press delivers the row it was appended with" {
    var rec: RowRecorder = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // Two rows share the function and the context — only `index` tells
    // them apart, which is the point of carrying it as data instead of
    // baking it into a generated function per row.
    _ = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Accept Ada",
        .on_press = .{ .ctx = &rec, .call_indexed = RowRecorder.onPress, .index = 0 },
    } });
    const second = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
        .label = "Accept Grace",
        .on_press = .{ .ctx = &rec, .call_indexed = RowRecorder.onPress, .index = 1 },
    } });

    app.performLayout();
    try app.tap(app.tree.rectOf(second).center());

    try testing.expectEqual(@as(u32, 1), rec.presses);
    try testing.expectEqual(@as(usize, 1), rec.index);
}

test "an indexed toggle delivers its row alongside the new state" {
    var rec: RowRecorder = .{};
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const tg = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{
        .label = "Mentions",
        .on_toggle = .{ .ctx = &rec, .call_indexed = RowRecorder.onToggle, .index = 3 },
    } });

    app.focused = .of(tg);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });

    try testing.expectEqual(@as(usize, 3), rec.index);
    try testing.expect(rec.checked);
}

// ---- press and release (WCAG 2.5.2; docs/introduction.md) ----

fn pressCounterApp(app: *App, counter: *PressCounter) !NodeId {
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
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
    try app.tree.append(sheet, .{ .toggle = .{ .label = "Only unread" } });
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
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
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
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    const tile = try app.tree.appendId(group, .{ .tile = .{
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
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Go" } });
    try app.tap(.{ .x = 399, .y = 399 });
    try testing.expect(app.focused == null);
}

test "tab cycles focus, shift-tab reverses" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const a = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "a" } });
    const b = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "b" } });

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
    const tg = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{ .label = "opt" } });
    app.focused = .of(tg);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(app.tree.getConst(tg).?.toggle.on);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(!app.tree.getConst(tg).?.toggle.on);
}

test "enter activates focused checkbox" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .checkbox = .{ .label = "I agree" } });
    app.focused = .of(cb);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(app.tree.getConst(cb).?.checkbox.checked);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    try testing.expect(!app.tree.getConst(cb).?.checkbox.checked);
}

test "typing edits the focused input with utf-8 aware cursor" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Name" } });
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
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Note" } });
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{
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
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Search" } });
    app.focused = .of(input);

    try app.dispatch(.{ .ime = .start });
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほ", .cursor = 2 } } });
    try testing.expectEqualStrings("にほ", app.tree.getConst(input).?.text_input.composition);
    try testing.expectEqualStrings("", app.tree.getConst(input).?.text_input.value);

    try app.dispatch(.{ .ime = .{ .commit = .{ .text = "日本" } } });
    try testing.expectEqualStrings("日本", app.tree.getConst(input).?.text_input.value);
    try testing.expectEqualStrings("", app.tree.getConst(input).?.text_input.composition);
}

test "the IME's caret is kept where the IME put it, and vetted on the way in" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const input = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "Search" } });
    app.focused = .of(input);
    const inp = struct {
        fn get(a: *App, id: NodeId) element_mod.TextInput {
            return a.tree.getConst(id).?.text_input;
        }
    }.get;

    // "にほんご" mid-conversion, the user having moved back two
    // codepoints to fix a syllable: the caret belongs there and not at
    // the end of the run.
    try app.dispatch(.{ .ime = .start });
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほんご", .cursor = 6 } } });
    try testing.expectEqual(@as(usize, 6), inp(&app, input).composition_cursor);
    // …and the value's own caret is untouched: they index different
    // strings.
    try testing.expectEqual(@as(usize, 0), inp(&app, input).cursor);

    // Past the end (Wayland's "hidden" cursor arrives as the length)
    // clamps to the end.
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほ", .cursor = 99 } } });
    try testing.expectEqual(@as(usize, 6), inp(&app, input).composition_cursor);

    // Mid-codepoint snaps back to a boundary — a shell converting
    // UTF-16 units by hand can land there, and the renderer must never
    // slice a codepoint to measure the prefix.
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほ", .cursor = 4 } } });
    try testing.expectEqual(@as(usize, 3), inp(&app, input).composition_cursor);

    // Every way a pre-edit ends clears the pair together, so the offset
    // can never outlive the string it indexes.
    try app.dispatch(.{ .ime = .cancel });
    try testing.expectEqual(@as(usize, 0), inp(&app, input).composition_cursor);
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほ", .cursor = 3 } } });
    try app.dispatch(.{ .key_down = .{ .key = .escape } });
    try testing.expectEqual(@as(usize, 0), inp(&app, input).composition_cursor);
    try app.dispatch(.{ .ime = .{ .update = .{ .composition = "にほ", .cursor = 3 } } });
    try app.dispatch(.{ .ime = .{ .commit = .{ .text = "日本" } } });
    try testing.expectEqual(@as(usize, 0), inp(&app, input).composition_cursor);
    try testing.expectEqualStrings("", inp(&app, input).composition);
}

test "text area: enter inserts a newline instead of submitting" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const ta = try app.tree.appendId(app.tree.rootId(), .{ .text_area = .{ .label = "Notes" } });
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
    const ta = try app.tree.appendId(app.tree.rootId(), .{ .text_area = .{ .label = "Notes", .value = "abc\nde" } });
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
    const ta = try app.tree.appendId(app.tree.rootId(), .{ .text_area = .{ .label = "Notes" } });
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
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 50 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try app.tree.append(sr, .{ .text = .{ .content = "line" } });
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
    const first = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .content = "line" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
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
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    try app.tree.append(sr, .{ .text = .{ .content = "fits" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
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
    const outer = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 80 } });
    const inner = try app.tree.appendId(outer, .{ .scroll_region = .{ .height = 40 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try app.tree.append(inner, .{ .text = .{ .content = "line" } });
    }
    while (i < 20) : (i += 1) {
        try app.tree.append(outer, .{ .text = .{ .content = "line" } });
    }
    while (i < 40) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
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
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try app.tree.append(sr, .{ .text = .{ .content = "line" } });
    }
    while (i < 30) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
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
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    try app.tree.append(sr, .{ .text = .{ .content = "fits" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
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
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
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
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
    } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "line" } });
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
    const a = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "A" } });
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "filler" } });
    }
    const b = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "B" } });

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
