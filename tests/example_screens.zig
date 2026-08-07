//! Every screen of an example, built — the one gate that runs one.
//!
//! `zig build test -Dskia` has always *linked* the examples: the desktop
//! link `check-targets` cannot do, hung on the test step so a shell
//! naming an undefined symbol fails here. Linking is where it stopped.
//! A route builder is called by nothing until a window opens, so one
//! that raises compiles, links, installs and passes every gate in this
//! repository — which was measured before this file existed, by making
//! `buildHome` raise unconditionally and watching `zig build test`,
//! `zig build test -Dskia -Dgolden` and `zig build check-targets` all
//! stay green.
//!
//! So this is an executable rather than a `zig test` root, for
//! `tests/capture.zig`'s reason: what is under test is a consumer's own
//! program, stood up the way its own entry point stands it up. It calls
//! the example's `nokreWebBuild` — the library contract a driver already
//! uses to hand an app back on the heap — and then walks the route table
//! that app is carrying, so the screens it builds are the screens the
//! example declares rather than a list restated here. A route added to
//! an example is covered by having been added.
//!
//! Each screen is laid out and audited, because "did not raise" is a low
//! bar for a screen and the a11y audit is the one nokre already applies
//! everywhere else.

const std = @import("std");
const h = @import("nokre");
const example = @import("example");

/// Every argument-taking route gets the same placeholder. What a screen
/// does with an id it cannot resolve is the screen's business — an
/// example that raised on one would be raising in a reader's window too.
const placeholder = "1";

/// Higher than any screen here takes. `RouteDef.args` is a `u8` with no
/// stated ceiling, so this one is the driver's, and a route past it
/// fails rather than being built with the wrong arity.
const max_args = 8;

pub fn main() !void {
    // An arena, not a leak-checking allocator: `nokreWebBuild` is the
    // web's entry and a web app never exits, so everything it puts on
    // the heap is deliberately never freed. Teardown is not what this
    // gate is about.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const app = try example.nokreWebBuild(arena.allocator());
    var built: usize = 0;
    for (app.router.routes) |def| {
        var buf: [h.router.max_ref_bytes]u8 = undefined;
        if (def.args > max_args) return error.RouteTakesMoreArgumentsThanThisDriverSupplies;
        const args: [max_args][]const u8 = @splat(placeholder);
        const reference = try app.routeRef(&buf, def.name, args[0..def.args]);
        try app.router.switchTo(app, reference);
        app.performLayout();
        try h.testing.audit.audit(app);
        built += 1;
    }
    if (built == 0) return error.ExampleDeclaresNoScreens;
    std.debug.print("example-screens: {d} screen(s) built and audited\n", .{built});
}
