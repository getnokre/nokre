//! Accessibility audit: the residue that construction-time validation
//! cannot cover. `Tree.append` rejects malformed structure outright; the
//! audit checks whole-tree content rules and state that mutation could
//! have degraded since. The harness runs it automatically at init and
//! after every driver action — consumers never opt in.

const std = @import("std");
const diag = @import("diag.zig");
const app_mod = @import("../core/app.zig");
const tree_mod = @import("../core/tree.zig");
const element_mod = @import("../core/element.zig");
const color = @import("../core/color.zig");
const focus = @import("../core/focus.zig");
const layout = @import("../core/layout.zig");
const text = @import("../core/text.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

pub const Violation = struct {
    id: NodeId,
    rule: Rule,

    pub const Rule = enum {
        /// Interactive elements must keep a non-empty accessible label.
        /// Append rejects empty ones; this catches later mutation.
        unlabeled_interactive,
        /// Heading levels must not skip (h1 → h3 with no h2 before it).
        heading_level_skipped,
        /// A screen has one top-level heading or none. A second `h1`
        /// says the page has two tops, and every reader that navigates
        /// by heading level — screen readers first, then the outline a
        /// search engine builds — is told the second section starts a
        /// second document.
        ///
        /// The producer worth naming is not a hand-built tree, where
        /// the mistake is visible in the code that made it: it is a
        /// `document` still carrying the default `base_level` under a
        /// title the screen already drew, which renders one `h1` *per
        /// section* of fetched content. That is what makes the field's
        /// answer checkable at all — a base too deep is
        /// `heading_level_skipped`, a base too shallow is this, and
        /// between them no wrong base is silent.
        ///
        /// Whole-tree, like `heading_level_skipped` and unlike the
        /// duplicate-label rule: layers decide what can be *invoked*,
        /// and this is not about invoking anything. A sheet over a
        /// screen is one document to the markup and to the outline.
        multiple_h1,
        /// Two interactive elements with the same accessible label are
        /// ambiguous to voice control and to test queries alike. Judged
        /// within the active layer only (`App.focusScope`): everything
        /// behind an open sheet, picker, or notices pane is inert —
        /// unreachable by tap, key, or voice — so a duplicate across
        /// that boundary can never be invoked ambiguously, and the
        /// audit re-runs after every action, catching the pair the
        /// moment the layer closes and both become live. One shape of
        /// duplicate is exempt: two controls that both navigate to the
        /// same route. "Docs" said twice about one destination is
        /// repetition, not ambiguity — whichever the user invokes lands
        /// exactly where the other would. Action-bearing controls never
        /// qualify: even an identical function pointer closes over a
        /// different context pointer, so sameness cannot be read off
        /// the tree.
        duplicate_interactive_label,
        /// A nav needs 2–5 destinations. `App.setNav` enforces this up
        /// front; removal can degrade it afterwards.
        nav_item_count,
        /// Options and selection can be mutated after append; a segmented
        /// control must keep ≥2 labeled options and a selection in range.
        malformed_segmented,
        /// Same rule for radio groups: ≥2 labeled options, selection in
        /// range.
        malformed_radio_group,
        /// Same rule for selects.
        malformed_select,
        /// Text ink vs the fill behind it must stay ≥4.5:1 (WCAG AA) in
        /// both appearances — the two ramps are independent, so a pair
        /// can be legible in one and not the other. Append rejects
        /// illegible pairs; ink and fill can be mutated.
        insufficient_text_contrast,
        /// …and ≤16:1. Contrast is not monotonically good: true ink on
        /// true paper is a glare source, not a legibility win, which is
        /// why the palette's own aliases stop well short of it.
        excessive_text_contrast,
        /// An open sheet must keep its close control or at least one
        /// enabled button; without
        /// one, pointer users on platforms with no Esc key are stuck.
        sheet_missing_dismiss,
        /// Append rejects empty sheet titles; mutation can erase one.
        untitled_sheet,
        /// The row's off-roster marker names the screen you are on; a
        /// blank one is a plate saying you are nowhere. Append rejects
        /// it (`EmptyNavHere`); mutation can empty it afterwards.
        empty_nav_here,
        /// Same for a `document`: its label is its accessible name, and
        /// nothing else in a parsed document can stand in for one.
        untitled_document,
        /// Append rejects empty notices; mutation can erase the title.
        empty_notice,
        /// Append rejects empty badges; mutation can erase the label.
        empty_badge,
        /// A button's `progress_percent` describes work in flight and
        /// must stay 0–100 with `in_progress` set. Append rejects both
        /// mistakes; a percentage climbing past 100, or work cleared
        /// while a number is left behind, happens afterwards — and a
        /// meter measuring nothing is the one thing worse than no meter.
        malformed_progress,
        /// Append rejects wordless or out-of-range meters; mutation can
        /// break either afterwards.
        malformed_meter,
        /// Append rejects valueless copyables; mutation can empty one,
        /// leaving a control that copies nothing.
        empty_copyable,
        /// Append rejects unlabeled/valueless qr codes and encodes their
        /// modules; mutation can empty the words afterwards.
        malformed_qr,
        /// A list must hold at least one item. `append` cannot catch
        /// this — a list is appended before its items exist — so the
        /// whole-tree pass is the only place it can live. An empty one
        /// announces a sequence to assistive tech and then has nothing
        /// to say, and draws a marker column over nothing.
        empty_list,
        /// Append rejects a verbatim block with no content; mutation
        /// can empty one, leaving a tab stop over blank space.
        ///
        /// There is deliberately no horizontal twin of
        /// `cleanly_clipped_scroll_region` here. That rule is fixable:
        /// a region's height is the consumer's, and a few px either way
        /// moves the edge onto ink. A code block's overflow is decided
        /// by its longest line — for parsed Markdown, bytes the app
        /// never chose — so the same rule would fire on content nobody
        /// can adjust, which is exactly what that rule's own viewport
        /// exemption refuses.
        empty_code_block,
        /// A control's route destination must resolve against the route
        /// table — a link, tile, inline span, or notice whose reference
        /// nobody can honor is a control that does nothing when pressed,
        /// which to any user is a dead end wearing an interactive face.
        /// Append cannot catch it (the tree has no router); this pass
        /// has the whole App and asks `router.vet`. Together with the
        /// refusal record (`audit`, below) this is what lets the
        /// navigating verbs stop returning errors nobody handled:
        /// a mistyped reference fails the first test that shows it.
        unresolvable_route,
        /// A field's `problem` is what makes it invalid — the snapshot
        /// derives the flag from these bytes rather than storing one
        /// beside them, so the two can never disagree. What they *can*
        /// be is present and wordless: a string of spaces draws nothing,
        /// announces nothing, and still tells every assistive technology
        /// the value was refused. That is precisely the state the slot
        /// exists to abolish, arrived at from the other side.
        ///
        /// Here and not in `append`, because whitespace-only is not a
        /// refusal nokre makes anywhere else — no other string field
        /// looks past `dupeValid`'s UTF-8 check — and one field inventing
        /// a stricter door would be a rule the rest of the set does not
        /// keep. The audit is where content rules live, and it runs
        /// after every driver action, which is exactly when a problem
        /// formatted from an empty catalog entry first appears.
        wordless_problem,
        /// The same defect from the third side: a field that states what
        /// is wrong with its value and refuses the correction. The user
        /// is told the address is already in use and cannot touch the
        /// address — a dead end no keystroke leaves, which is what
        /// `problem`'s own contract says it will never be ("it is not
        /// `disabled` … saying otherwise would trap the user in the
        /// value that was refused", element.zig).
        ///
        /// The pair has no honest producer. A form disables on submit,
        /// the server refuses, and the field is re-enabled *and* given
        /// its problem in the same frame — the two states are adjacent
        /// in time and never overlap. What does produce it is a
        /// controller that sets the reason but forgets to lower the
        /// flag, which is a bug the app cannot see and every screen
        /// reader can.
        ///
        /// A rule rather than an append refusal, for `wordless_problem`'s
        /// reason: both fields are legal on their own and it is the
        /// *combination* that is wrong, so the door is the wrong place —
        /// the audit runs after every driver action, which is exactly
        /// when a reply lands.
        unfixable_problem,
        /// An overflowing scroll region must visibly cut an element at
        /// its offset-0 viewport edge. The resting indicator is
        /// deliberately quiet (see the renderer), so the mid-element
        /// cut is what makes overflow perceivable at rest; a region
        /// whose edge lands in a gap, on an element boundary, or in a
        /// text line's leading reads as complete and hides its own
        /// content. The fix is the region's height: a few px either
        /// way puts the edge through visible ink.
        cleanly_clipped_scroll_region,
    };
};

/// Fails with diagnostics on stderr if any rule is violated.
///
/// Two navigation checks ride along with the tree rules, here because
/// this gate already runs after every action and they are not about any
/// node: the router's refusal record — a navigating verb was handed a
/// reference it could not honor (router.zig says why that is a record
/// and not an error) — and the raised notices' routes, which `notify`
/// accepts unchecked and which a quiet notice keeps out of the tree
/// until its pane opens.
pub fn audit(app: *App) !void {
    if (app.router.refused) |r| {
        diag.print("navigation refused: \"{s}\" ({s})\n", .{ r.ref(), @tagName(r.reason) });
        return error.NavigationRefused;
    }
    for (app.notices.items) |*n| {
        if (n.route().len > 0 and app.router.vet(n.route()) != null) {
            diag.print("notice \"{s}\" routes to \"{s}\", which resolves to no screen\n", .{ n.title(), n.route() });
            return error.NavigationRefused;
        }
    }
    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(app.gpa);
    try collect(app, &violations, .{});
    if (violations.items.len == 0) return;

    for (violations.items) |v| {
        diag.print("a11y audit: {s} (node label: \"{s}\")\n", .{
            @tagName(v.rule),
            app.tree.getConst(v.id).?.label(),
        });
    }
    return error.A11yAuditFailed;
}

/// The one knob `collect` takes.
pub const Options = struct {
    /// Rules whose authority the caller has deliberately replaced —
    /// findings under them are dropped from `out`, everything else
    /// stays fatal-grade. The known case is a static-site generator
    /// skipping `unresolvable_route`: there a document destination is
    /// the *site resolver's* to honor, not the route table's, and that
    /// resolver already fails the build harder than this rule would.
    /// The default skips nothing, which is what `audit` (and so the
    /// harness gate) always runs with.
    skip: []const Violation.Rule = &.{},
};

pub fn collect(app: *App, out: *std.ArrayList(Violation), options: Options) !void {
    // Which findings this call is answerable for: a caller may hand in
    // a list it has already put findings in, and the skip below must
    // not touch those.
    const start = out.items.len;
    // The clipping rule reads laid-out rects; at harness init nothing
    // has laid out yet. Cheap when clean.
    app.performLayout();
    var prev_heading_level: u8 = 0;
    var seen_h1 = false;
    // Each first-seen label with its route destination (null for
    // anything but a pure route navigation) — the destination is what
    // decides whether a later holder of the same label is a collision
    // or a second door to the same room.
    const Seen = struct { label: []const u8, route: ?[]const u8 };
    var seen_labels: std.ArrayList(Seen) = .empty;
    defer seen_labels.deinit(app.gpa);
    // The duplicate rule's jurisdiction: only labels in the active
    // layer can collide, because only they can be invoked at all.
    const active_layer = app.focusScope();

    var it = app.tree.dfs();
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        switch (el.*) {
            .button, .link, .toggle, .checkbox, .text_input, .text_area, .segmented, .tile, .radio_group, .select, .copyable, .nav_item, .icon_button, .back, .picker_item => {
                if (el.label().len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .unlabeled_interactive });
                } else if (el.isInteractive() and inLayer(app, id, active_layer)) {
                    const route = routeDestination(el);
                    var duplicate = false;
                    var exempt = false;
                    for (seen_labels.items) |seen| {
                        if (!std.mem.eql(u8, seen.label, el.label())) continue;
                        // A shared label is ambiguous unless both
                        // holders navigate to the same route (see the
                        // rule's rationale above).
                        if (route != null and seen.route != null and std.mem.eql(u8, route.?, seen.route.?)) {
                            exempt = true;
                        } else {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) {
                        try out.append(app.gpa, .{ .id = id, .rule = .duplicate_interactive_label });
                    } else if (!exempt) {
                        try seen_labels.append(app.gpa, .{ .label = el.label(), .route = route });
                    }
                }
            },
            else => {},
        }
        switch (el.*) {
            .button => |b| {
                if (b.progress_percent) |pct| {
                    if (pct > 100 or !b.in_progress) {
                        try out.append(app.gpa, .{ .id = id, .rule = .malformed_progress });
                    }
                }
            },
            .heading => |h| {
                const level = @intFromEnum(h.level);
                // Against the *previous* heading, not the deepest level
                // ever seen: the outline position resets as levels come
                // back up, so h1,h2,h3 then h1,h3 skips h2 even though
                // an h3 appeared earlier. Descending may only go one
                // step; ascending any distance is fine.
                if (level > prev_heading_level + 1) {
                    try out.append(app.gpa, .{ .id = id, .rule = .heading_level_skipped });
                }
                // Reported at the *second* h1 and every one after it:
                // the first is the page's top and the innocent party,
                // and a driver reading the node label wants the one
                // that has to move.
                if (level == 1) {
                    if (seen_h1) try out.append(app.gpa, .{ .id = id, .rule = .multiple_h1 });
                    seen_h1 = true;
                }
                prev_heading_level = level;
            },
            .nav => {
                // Two ways to end up with a nav that leads nowhere. The
                // roster itself can be out of range; or the rendering
                // can stop matching it — the shape is the framework's to
                // choose (`nav.syncNavChrome`), so a tree that shows
                // fewer destinations than the app declares is chrome
                // that has been edited out from under it. Counting only
                // the children would call the collapsed chip a nav with
                // one destination, which is the whole point of it.
                const roster = app.nav_items.items.len;
                // Destinations only: the row may also carry the marker
                // for a screen that is none of them (`element.NavHere`),
                // and counting that as a destination would report every
                // off-roster screen as a nav with one too many.
                var destinations: usize = 0;
                var kids = app.tree.children(id);
                while (kids.next()) |c| {
                    if (app.tree.getConst(c).?.role() == .nav_item) destinations += 1;
                }
                const rendered = if (collapsedNav(app, id)) roster else destinations;
                if (rendered < 2 or rendered > 5 or roster != rendered) {
                    try out.append(app.gpa, .{ .id = id, .rule = .nav_item_count });
                }
            },
            .nav_here => |n| {
                if (n.value.len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .empty_nav_here });
                }
            },
            .segmented => |s| {
                var ok = s.options.len >= 2 and s.selected < s.options.len;
                for (s.options) |opt| {
                    if (opt.len == 0) ok = false;
                }
                if (!ok) {
                    try out.append(app.gpa, .{ .id = id, .rule = .malformed_segmented });
                }
            },
            .radio_group => |rg| {
                var ok = rg.options.len >= 2 and rg.selected < rg.options.len;
                for (rg.options) |opt| {
                    if (opt.len == 0) ok = false;
                }
                if (!ok) {
                    try out.append(app.gpa, .{ .id = id, .rule = .malformed_radio_group });
                }
            },
            .select => |s| {
                var ok = s.options.len >= 2 and s.selected < s.options.len;
                for (s.options) |opt| {
                    if (opt.len == 0) ok = false;
                }
                if (!ok) {
                    try out.append(app.gpa, .{ .id = id, .rule = .malformed_select });
                }
            },
            .sheet => |s| {
                if (s.title.len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .untitled_sheet });
                }
                if (!dismissable(app, id)) {
                    try out.append(app.gpa, .{ .id = id, .rule = .sheet_missing_dismiss });
                }
            },
            .notices_pane => {
                if (!dismissable(app, id)) {
                    try out.append(app.gpa, .{ .id = id, .rule = .sheet_missing_dismiss });
                }
            },
            .notice => |n| {
                if (n.title.len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .empty_notice });
                }
                if (n.route.len > 0 and app.router.vet(n.route) != null) {
                    try out.append(app.gpa, .{ .id = id, .rule = .unresolvable_route });
                }
            },
            // The three pure route destinations `routeDestination` names,
            // plus the inline spans below: everything whose activation is
            // a reference the router must honor.
            .link => |l| {
                if (l.external == null and l.route.len > 0 and app.router.vet(l.route) != null) {
                    try out.append(app.gpa, .{ .id = id, .rule = .unresolvable_route });
                }
            },
            .tile => |t| {
                if (t.route.len > 0 and app.router.vet(t.route) != null) {
                    try out.append(app.gpa, .{ .id = id, .rule = .unresolvable_route });
                }
            },
            .nav_item => |n| {
                if (app.router.vet(n.route) != null) {
                    try out.append(app.gpa, .{ .id = id, .rule = .unresolvable_route });
                }
            },
            .badge => |b| {
                if (b.label.len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .empty_badge });
                }
            },
            .meter => |m| {
                if (m.label.len == 0 or m.max <= 0 or m.value < 0 or m.value > m.max) {
                    try out.append(app.gpa, .{ .id = id, .rule = .malformed_meter });
                }
            },
            .text_input => |t| try fieldRules(app, out, id, t.problem, t.disabled),
            .text_area => |t| try fieldRules(app, out, id, t.problem, t.disabled),
            .copyable => |c| {
                if (c.value.len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .empty_copyable });
                }
            },
            .qr => |q| {
                if (q.label.len == 0 or q.value.len == 0 or q.size <= 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .malformed_qr });
                }
            },
            .list => {
                if (app.tree.childCount(id) == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .empty_list });
                }
            },
            .document => |d| {
                if (d.label.len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .untitled_document });
                }
            },
            .code_block => |c| {
                if (c.content.len == 0) {
                    try out.append(app.gpa, .{ .id = id, .rule = .empty_code_block });
                }
            },
            .scroll_region => |sr| {
                if (cleanlyClipped(app, id, sr)) {
                    try out.append(app.gpa, .{ .id = id, .rule = .cleanly_clipped_scroll_region });
                }
            },
            else => {},
        }
        if (el.ambientTextInk()) |ink| {
            const parent = app.tree.parentOf(id) orelse continue;
            if (contrastRule(ink, app.tree.backgroundBehind(parent))) |rule| {
                try out.append(app.gpa, .{ .id = id, .rule = rule });
            }
        }
        // Span inks are mutable like the element's own ink; every run
        // faces the same gate (append rejects illegible ones up front).
        const spans: []const element_mod.Span = switch (el.*) {
            .text => |t| t.spans,
            .heading => |h| h.spans,
            else => &.{},
        };
        if (spans.len > 0) {
            // Not inside a `document`: there a destination belongs to
            // the document lane — the site generator's own resolver,
            // the browser under `addressing: "documents"` — and the
            // route table is not its authority. An in-app document
            // whose spans do route is still covered at activation, by
            // the refusal record this same gate fails on.
            if (!insideDocument(app, id)) for (spans) |span| {
                if (span.route.len == 0) continue;
                if (app.router.vet(span.route) != null) {
                    try out.append(app.gpa, .{ .id = id, .rule = .unresolvable_route });
                    break;
                }
            };
            const base_ink: color.Gray = switch (el.*) {
                .text => |t| t.style.ink,
                else => .ink,
            };
            const parent = app.tree.parentOf(id) orelse continue;
            const bg = app.tree.backgroundBehind(parent);
            for (spans) |span| {
                if (std.mem.trim(u8, span.text, " \t\n\r").len == 0) continue;
                if (contrastRule(span.ink orelse base_ink, bg)) |rule| {
                    try out.append(app.gpa, .{ .id = id, .rule = rule });
                    break;
                }
            }
        }
    }
    // Skipped rules are dropped after the walk rather than tested at
    // every append: one filter instead of twenty guard sites, and the
    // walk stays rule-complete — a skipped rule still costs its check,
    // which is cheap, and cannot be half-skipped by a missed guard.
    if (options.skip.len == 0) return;
    var kept = start;
    for (out.items[start..]) |v| {
        if (std.mem.indexOfScalar(Violation.Rule, options.skip, v.rule) != null) continue;
        out.items[kept] = v;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
}

/// Present but with nothing to say. Empty is the ordinary state — a
/// field with no problem — so only bytes that exist and draw nothing
/// qualify. The same trim the span-contrast check uses, for the same
/// reason: whitespace is not ink.
fn wordless(problem: []const u8) bool {
    return problem.len > 0 and std.mem.trim(u8, problem, " \t\n\r").len == 0;
}

/// Both field rules, asked once for the two elements that carry the
/// pair. One function rather than two copies of the same two `if`s: the
/// single-line and multi-line fields are refused for identical reasons
/// (`TextArea.problem`, `TextArea.disabled`), and a rule that grew a
/// third clause on one of them only would be the drift this shape
/// exists to prevent.
fn fieldRules(app: *App, out: *std.ArrayList(Violation), id: NodeId, problem: []const u8, disabled: bool) !void {
    if (wordless(problem)) {
        try out.append(app.gpa, .{ .id = id, .rule = .wordless_problem });
    }
    // Order matters only for reading a failure list: a wordless problem
    // on a disabled field is two separate mistakes, and reporting both
    // is what tells the author the second one is not a consequence of
    // the first.
    if (disabled and problem.len > 0) {
        try out.append(app.gpa, .{ .id = id, .rule = .unfixable_problem });
    }
}

/// The route a control's activation navigates to, or null when pressing
/// it does anything else. Only a pure route push qualifies — a
/// `nav_item`, a routed `link`, a `tile` whose route wins over its
/// action (`input.zig` activates in exactly this order) — because a
/// route reference carries its arguments in the string (`note~42`,
/// docs/routing.md), so byte equality is destination equality. An
/// `Action` never qualifies (see the rule's rationale), and neither
/// does a link's external URL: the audit's exemption exists for the
/// nav-chip-and-tile shape inside one app, not for vouching that two
/// URLs open the same page.
fn routeDestination(el: *const element_mod.Element) ?[]const u8 {
    return switch (el.*) {
        .link => |l| if (l.external == null and l.route.len > 0) l.route else null,
        .tile => |t| if (t.route.len > 0) t.route else null,
        .nav_item => |n| n.route,
        else => null,
    };
}

/// Whether `id` sits under a `document` node — the subtree whose
/// destinations the route table does not govern (see the span check in
/// `collect`).
fn insideDocument(app: *App, id: NodeId) bool {
    var node: ?NodeId = app.tree.parentOf(id);
    while (node) |n| : (node = app.tree.parentOf(n)) {
        if (app.tree.getConst(n).?.role() == .document) return true;
    }
    return false;
}

/// Whether `id` sits inside the active layer rooted at `scope`. With no
/// modal open the scope is the tree root and everything qualifies; with
/// one open, only its subtree does — the rest is under the scrim.
fn inLayer(app: *App, id: NodeId, scope: NodeId) bool {
    var node: ?NodeId = id;
    while (node) |n| : (node = app.tree.parentOf(n)) {
        if (n.eql(scope)) return true;
    }
    return false;
}

/// Whether the nav is standing in its collapsed shape: the one chip
/// that speaks for the whole roster.
fn collapsedNav(app: *App, nav: NodeId) bool {
    if (app.tree.childCount(nav) != 1) return false;
    var it = app.tree.children(nav);
    return app.tree.getConst(it.next().?).?.role() == .nav_current;
}

/// The audit's view of the append-time gate: same two-appearance check,
/// reported as a finding rather than raised, because the audit exists
/// for the pairs that only *became* wrong through later mutation.
fn contrastRule(ink: color.Gray, bg: color.Gray) ?Violation.Rule {
    color.checkTextPair(ink, bg) catch |err| return switch (err) {
        error.InsufficientTextContrast => .insufficient_text_contrast,
        error.ExcessiveTextContrast => .excessive_text_contrast,
    };
    return null;
}

/// Only consumer-chosen heights are checked: a fill (null) height and
/// the picker's own list resolve against the viewport, which no
/// consumer can portably control — a rule firing on some devices and
/// not others would be unfixable.
fn cleanlyClipped(app: *App, id: NodeId, sr: element_mod.ScrollRegion) bool {
    if (sr.height == null) return false;
    if (app.tree.parentOf(id)) |p| {
        if (app.tree.getConst(p).?.role() == .picker) return false;
    }
    const r = app.tree.rectOf(id);
    if (sr.content_height <= r.h) return false;
    // Child rects carry the live offset; the offset-0 clip edge in
    // screen space is the region bottom shifted back up by it.
    return !visiblyCut(app, id, r.y - sr.offset + r.h);
}

/// Whether the horizontal line at `edge` slices through visible ink of
/// some descendant: a glyph band, a border, a fill. A cut through
/// blank space — flow gaps, container padding, a text line's leading —
/// is invisible on the ambient background.
fn visiblyCut(app: *App, id: NodeId, edge: i32) bool {
    var it = app.tree.children(id);
    while (it.next()) |child| {
        const el = app.tree.getConst(child).?;
        const r = app.tree.rectOf(child);
        if (r.y >= edge or r.y + r.h <= edge) continue;
        const cut = switch (el.*) {
            // Text is cut only when the edge crosses the glyph band;
            // slicing the leading above or below leaves whole letters
            // and a clean look.
            .text => |t| glyphCut(t.style.scale, edge - r.y),
            .heading => |h| glyphCut(h.level.scale(), edge - r.y),
            // Containers that draw nothing themselves defer to what
            // is inside them.
            .stack, .list, .list_item => visiblyCut(app, child, edge),
            // The quote's rule runs the full height of what it marks,
            // so any edge crossing the quote crosses drawn ink.
            .blockquote => true,
            // Verbatim lines are cut like text, at the body scale.
            .code_block => glyphCut(.body, edge - r.y),
            .box => |b| b.border or b.fill != null or visiblyCut(app, child, edge),
            else => true,
        };
        // Horizontal flows can put several children on the edge; any
        // one visibly cut is enough.
        if (cut) return true;
    }
    return false;
}

fn glyphCut(scale: text.Scale, rel: i32) bool {
    const line = scale.lineHeight();
    const top = @divTrunc(line - scale.px(), 2);
    const in_line = @mod(rel, line);
    return in_line > top and in_line < top + scale.px();
}

fn dismissable(app: *App, id: NodeId) bool {
    var inner = app.tree.dfsUnder(id);
    while (inner.next()) |sub| {
        const sub_el = app.tree.getConst(sub).?;
        switch (sub_el.*) {
            .sheet_close, .icon_button => return true,
            // A button whose work is running is no way out either: it
            // takes no press until the work lands, which is exactly when
            // the user wants out.
            .button => |b| if (!b.disabled and !b.in_progress) return true,
            else => {},
        }
    }
    return false;
}
