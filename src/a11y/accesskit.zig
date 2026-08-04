//! AccessKit adapter boundary. AccessKit (via its C bindings, bound in
//! shim/nokre_accesskit.c) delivers the semantic snapshot to UIA
//! (Windows), NSAccessibility (macOS), AT-SPI (Linux), and Android's
//! accessibility framework; the web target mirrors the snapshot into ARIA
//! attributes instead — on the web the DOM *is* the accessibility
//! tree, so that platform derives no snapshot at all
//! (docs/internals/dom-edition.md).
//!
//! The macOS (VoiceOver), Windows (UIA), and Linux (AT-SPI — Orca)
//! bindings are live; other platforms wire the same `flatten` output
//! into their shells as they land (docs/roadmap.md).

const std = @import("std");
const semantics = @import("semantics.zig");
const focus_mod = @import("../core/focus.zig");
const tree_mod = @import("../core/tree.zig");

/// Mirrors nokre_a11y_node in shim/nokre_accesskit.h exactly.
pub const CNode = extern struct {
    id: u64,
    role: i32,
    label: ?[*]const u8,
    label_len: usize,
    value: ?[*]const u8,
    value_len: usize,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    parent: usize,
    focusable: u8,
    focused: u8,
    disabled: u8,
    modal: u8,
    clickable: u8,
    checked: i8,
    selected: i8,
    heading_level: u8,
    /// Appended after `heading_level`, where the struct already had
    /// padding: every offset before it — and the 80-byte size the web
    /// mirror reads by hand — stays exactly what it was.
    busy: u8,
};

pub const action_click: i32 = 1;
pub const action_focus: i32 = 2;

pub fn nodeIdU64(id: tree_mod.NodeId) u64 {
    return @as(u32, @bitCast(id));
}

/// A node's AccessKit id. An inline link is not a tree node, so it
/// borrows its element's id with the span index (biased by one) in the
/// high half — the low 32 bits stay exactly what they always were, so
/// nothing already on the wire moves. A derived node (the acknowledgement
/// status) borrows its element's id the same way, keyed by a high half no
/// span index can reach: `Span.index` is a u16, so everything above that
/// is free, and AccessKit demands ids be unique per node.
pub fn a11yIdOf(n: semantics.A11yNode) u64 {
    const base = nodeIdU64(n.id);
    if (n.derived) return base | derived_key << 32;
    return if (n.span) |s| base | (@as(u64, s) + 1) << 32 else base;
}

const derived_key: u64 = std.math.maxInt(u32);

/// The tree node an AccessKit id names. The high half carries the
/// inline-link index, so it is masked off here — every id names some
/// node, and `Tree.get` is what decides whether that node still exists.
pub fn nodeIdFromU64(id: u64) tree_mod.NodeId {
    return @bitCast(@as(u32, @truncate(id)));
}

/// The focus target an AccessKit id names: the element, or one of its
/// inline links.
pub fn focusFromU64(id: u64) ?focus_mod.Focus {
    const node = nodeIdFromU64(id);
    const high: u64 = id >> 32;
    if (high == 0) return .of(node);
    if (high - 1 > std.math.maxInt(u16)) return null;
    return .{ .node = node, .span = @intCast(high - 1) };
}

/// Flattens a snapshot into the C bridge representation. Strings borrow
/// from the tree; the result is valid until the next tree mutation.
/// Returns the AccessKit id of the focused node (root when none).
pub fn flatten(
    snap: *const semantics.Snapshot,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(CNode),
) !u64 {
    var focus: u64 = if (snap.nodes.items.len > 0) a11yIdOf(snap.nodes.items[0]) else 0;
    try out.ensureUnusedCapacity(gpa, snap.nodes.items.len);
    for (snap.nodes.items) |n| {
        if (n.focused) focus = a11yIdOf(n);
        out.appendAssumeCapacity(.{
            .id = a11yIdOf(n),
            .role = @intFromEnum(n.role),
            .label = if (n.label.len > 0) n.label.ptr else null,
            .label_len = n.label.len,
            .value = if (n.value.len > 0) n.value.ptr else null,
            .value_len = n.value.len,
            .x = @floatFromInt(n.rect.x),
            .y = @floatFromInt(n.rect.y),
            .w = @floatFromInt(n.rect.w),
            .h = @floatFromInt(n.rect.h),
            .parent = n.parent orelse std.math.maxInt(usize),
            .focusable = @intFromBool(n.focusable),
            .focused = @intFromBool(n.focused),
            .disabled = @intFromBool(n.disabled),
            .modal = @intFromBool(n.modal),
            .clickable = @intFromBool(n.activatable),
            .checked = if (n.checked) |c| @intFromBool(c) else -1,
            .selected = if (n.selected) |s| @intFromBool(s) else -1,
            .heading_level = n.heading_level,
            .busy = @intFromBool(n.busy),
        });
    }
    return focus;
}

pub const FillFn = *const fn (ctx: ?*anyopaque, count: *usize, focus_id: *u64) callconv(.c) ?[*]const CNode;
pub const ActionFn = *const fn (ctx: ?*anyopaque, target: u64, action: i32) callconv(.c) void;

extern fn nokre_a11y_macos_attach(
    ns_view: *anyopaque,
    window_class: [*:0]const u8,
    fill: FillFn,
    fill_ctx: ?*anyopaque,
    action: ActionFn,
    action_ctx: ?*anyopaque,
) ?*anyopaque;
extern fn nokre_a11y_macos_update(adapter: *anyopaque) void;
extern fn nokre_a11y_macos_focus_state(adapter: *anyopaque, focused: i32) void;
extern fn nokre_a11y_macos_detach(adapter: *anyopaque) void;

/// The macOS (VoiceOver) adapter; pull-based, as AccessKit demands:
/// `fill` is invoked whenever assistive tech needs the current tree.
pub const Macos = struct {
    handle: *anyopaque,

    pub fn attach(
        ns_view: *anyopaque,
        window_class: [*:0]const u8,
        fill: FillFn,
        fill_ctx: ?*anyopaque,
        action: ActionFn,
        action_ctx: ?*anyopaque,
    ) ?Macos {
        const handle = nokre_a11y_macos_attach(ns_view, window_class, fill, fill_ctx, action, action_ctx) orelse return null;
        return .{ .handle = handle };
    }

    pub fn update(self: Macos) void {
        nokre_a11y_macos_update(self.handle);
    }

    pub fn focusState(self: Macos, focused: bool) void {
        nokre_a11y_macos_focus_state(self.handle, @intFromBool(focused));
    }

    pub fn detach(self: Macos) void {
        nokre_a11y_macos_detach(self.handle);
    }
};

extern fn nokre_a11y_windows_attach(
    hwnd: *anyopaque,
    fill: FillFn,
    fill_ctx: ?*anyopaque,
    action: ActionFn,
    action_ctx: ?*anyopaque,
) ?*anyopaque;
extern fn nokre_a11y_windows_update(adapter: *anyopaque) void;
extern fn nokre_a11y_windows_detach(adapter: *anyopaque) void;

/// The Windows (UIA — Narrator, NVDA, JAWS) adapter. AccessKit's
/// subclassing adapter wraps the window procedure, so it must attach
/// while the window is still hidden (shell.c orders on_ready before
/// ShowWindow) and it observes window focus itself — no focusState.
pub const Windows = struct {
    handle: *anyopaque,

    pub fn attach(
        hwnd: *anyopaque,
        fill: FillFn,
        fill_ctx: ?*anyopaque,
        action: ActionFn,
        action_ctx: ?*anyopaque,
    ) ?Windows {
        const handle = nokre_a11y_windows_attach(hwnd, fill, fill_ctx, action, action_ctx) orelse return null;
        return .{ .handle = handle };
    }

    pub fn update(self: Windows) void {
        nokre_a11y_windows_update(self.handle);
    }

    pub fn detach(self: Windows) void {
        nokre_a11y_windows_detach(self.handle);
    }
};

extern fn nokre_a11y_ios_attach(
    view: *anyopaque,
    fill: FillFn,
    fill_ctx: ?*anyopaque,
    action: ActionFn,
    action_ctx: ?*anyopaque,
) ?*anyopaque;
extern fn nokre_a11y_ios_update(adapter: *anyopaque) void;

/// The iOS (VoiceOver) adapter. No AccessKit library here: UIKit's own
/// UIAccessibility already speaks flat element lists, so the shell
/// (src/platform/ios/shell.m) consumes the same `flatten` output
/// directly. Pull-based like macOS: `fill` runs when VoiceOver asks.
pub const Ios = struct {
    handle: *anyopaque,

    pub fn attach(
        view: *anyopaque,
        fill: FillFn,
        fill_ctx: ?*anyopaque,
        action: ActionFn,
        action_ctx: ?*anyopaque,
    ) ?Ios {
        const handle = nokre_a11y_ios_attach(view, fill, fill_ctx, action, action_ctx) orelse return null;
        return .{ .handle = handle };
    }

    pub fn update(self: Ios) void {
        nokre_a11y_ios_update(self.handle);
    }
};

extern fn nokre_a11y_unix_attach(
    view: *anyopaque,
    fill: FillFn,
    fill_ctx: ?*anyopaque,
    action: ActionFn,
    action_ctx: ?*anyopaque,
) ?*anyopaque;
extern fn nokre_a11y_unix_update(adapter: *anyopaque) void;
extern fn nokre_a11y_unix_focus_state(adapter: *anyopaque, focused: i32) void;
extern fn nokre_a11y_unix_detach(adapter: *anyopaque) void;

/// The Linux (AT-SPI — Orca, and any AT on the freedesktop bus) adapter.
/// Unlike the macOS/Windows subclassing adapters it takes no window: the
/// AccessKit Unix adapter registers the process on the accessibility bus
/// and runs its handlers on its own thread. `view` is the shell surface
/// the action marshal posts back through — assistive-tech actions arrive
/// off-thread, so the shim hops them to the UI thread via
/// `nokre_shell_post_main` (the worker-wake lane), the Windows
/// message-only-window marshal relocated to Wayland. Pull-based like the
/// others: `fill` runs whenever the tree is needed.
pub const Unix = struct {
    handle: *anyopaque,

    pub fn attach(
        view: *anyopaque,
        fill: FillFn,
        fill_ctx: ?*anyopaque,
        action: ActionFn,
        action_ctx: ?*anyopaque,
    ) ?Unix {
        const handle = nokre_a11y_unix_attach(view, fill, fill_ctx, action, action_ctx) orelse return null;
        return .{ .handle = handle };
    }

    pub fn update(self: Unix) void {
        nokre_a11y_unix_update(self.handle);
    }

    pub fn focusState(self: Unix, focused: bool) void {
        nokre_a11y_unix_focus_state(self.handle, @intFromBool(focused));
    }

    pub fn detach(self: Unix) void {
        nokre_a11y_unix_detach(self.handle);
    }
};

// ---- tests ----

const testing = std.testing;
const test_app = @import("../core/test_app.zig");

test "flatten mirrors the snapshot into the C bridge representation" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Settings", .level = .h2 } });
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{ .label = "Dark ink", .on = true } });
    app.focused = .of(cb);

    var snap = try semantics.snapshot(testing.allocator, &app);
    defer snap.deinit();
    var nodes: std.ArrayList(CNode) = .empty;
    defer nodes.deinit(testing.allocator);
    const focus = try flatten(&snap, testing.allocator, &nodes);

    try testing.expectEqual(snap.nodes.items.len, nodes.items.len);
    try testing.expectEqual(nodeIdU64(cb), focus);

    const root = nodes.items[0];
    try testing.expectEqual(@intFromEnum(semantics.A11yRole.document), root.role);
    try testing.expectEqual(std.math.maxInt(usize), root.parent);

    const h = nodes.items[1];
    try testing.expectEqual(@intFromEnum(semantics.A11yRole.heading), h.role);
    try testing.expectEqual(@as(u8, 2), h.heading_level);
    try testing.expectEqualStrings("Settings", h.label.?[0..h.label_len]);
    try testing.expectEqual(@as(usize, 0), h.parent);
    try testing.expectEqual(@as(i8, -1), h.checked);

    const c = nodes.items[2];
    try testing.expectEqual(@as(i8, 1), c.checked);
    try testing.expectEqual(@as(u8, 1), c.focused);
    try testing.expectEqual(@as(u8, 1), c.focusable);
    try testing.expectEqual(@as(u8, 1), c.clickable);
    try testing.expect(c.w > 0 and c.h > 0);
}

test "busy crosses the bridge beside disabled, and takes the click away" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save changes", .in_progress = true } });

    var snap = try semantics.snapshot(testing.allocator, &app);
    defer snap.deinit();
    var nodes: std.ArrayList(CNode) = .empty;
    defer nodes.deinit(testing.allocator);
    _ = try flatten(&snap, testing.allocator, &nodes);

    const b = nodes.items[1];
    try testing.expectEqual(@as(u8, 1), b.busy);
    try testing.expectEqual(@as(u8, 1), b.disabled);
    // Assistive tech must not be able to press what a finger cannot…
    try testing.expectEqual(@as(u8, 0), b.clickable);
    // …and must still be able to land on it.
    try testing.expectEqual(@as(u8, 1), b.focusable);
}

test "node ids round-trip through the u64 bridge encoding" {
    const id: tree_mod.NodeId = .{ .index = 42, .gen = 7 };
    try testing.expectEqual(id, nodeIdFromU64(nodeIdU64(id)));
    try testing.expect(focusFromU64(nodeIdU64(id)).?.eql(.of(id)));

    // An inline link borrows its element's id and rides in the high
    // half, so the low 32 bits stay byte-identical to what the bridge
    // has always sent for the element itself.
    const link = a11yIdOf(.{ .id = id, .span = 3, .role = .link, .label = "terms", .rect = .zero, .focusable = true, .focused = false });
    try testing.expectEqual(nodeIdU64(id), link & 0xffff_ffff);
    try testing.expectEqual(id, nodeIdFromU64(link));
    const stop = focusFromU64(link).?;
    try testing.expectEqual(@as(?u16, 3), stop.span);
    try testing.expectEqual(id, stop.node);
}

test "a derived node's id stays clear of the element it belongs to" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
    app.performLayout();
    try app.tap(app.tree.rectOf(c).center());

    var snap = try semantics.snapshot(testing.allocator, &app);
    defer snap.deinit();
    var nodes: std.ArrayList(CNode) = .empty;
    defer nodes.deinit(testing.allocator);
    _ = try flatten(&snap, testing.allocator, &nodes);

    // AccessKit ids are unique per node, and the acknowledgement shares
    // its element's NodeId: the high half is what separates them.
    for (nodes.items, 0..) |n, i| {
        for (nodes.items[i + 1 ..]) |m| try testing.expect(n.id != m.id);
    }
    // Nothing can target it: it is neither focusable nor clickable, and
    // its id names no focus stop.
    const ack = nodes.items[nodes.items.len - 1];
    try testing.expectEqual(@intFromEnum(semantics.A11yRole.status), ack.role);
    try testing.expectEqual(@as(u8, 0), ack.focusable);
    try testing.expectEqual(@as(u8, 0), ack.clickable);
    try testing.expect(focusFromU64(ack.id) == null);
}
