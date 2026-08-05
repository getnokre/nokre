//! The one-shot in-flight latch. Pure data in the same doctrine slot as
//! `Load` (core/load.zig) and the bounded containers (core/bounded.zig):
//! nokre never reads a `Gate`, and no element field takes one. It exists
//! because `Load` is display-only and `Button.in_progress` is a pixel —
//! nothing in the framework *produces* busy, so every mutation in both
//! real consumer apps hand-rolled the same three lines:
//!
//! ```zig
//! if (self.creating) return;   // refuse the second press
//! self.creating = true;        // and every callback path must clear it
//! ```
//!
//! Surveyed 2026-08-05 across the two apps: 36 guard-then-raise sites
//! and 52 lowerings, under twenty-one field names for one idea —
//! `busy`, `pending`, `refreshing`, `generating`, `requesting`,
//! `creating`, `joining`, `deleting`, `rotating`, `objecting`,
//! `removing`, `submitting`, `saving`, `sending`, `sharing`,
//! `sponsoring`, `exporting`, `buying`, `unlocking`, `walking`,
//! `redeem_busy`. The vocabulary is half the win: one word, one
//! polarity, in both apps and in whatever reads them next.
//!
//! What this is *not* is a state machine, for the same reason
//! `load.zig` is not one. No phases, no generation stamp, no staleness,
//! no "which row" — a latch. A flow with more words than up/down keeps
//! its own enum, and several already do: an OTP form's
//! `phase == .submitting`, a transfer's `stage == .sealing`, a search's
//! `search_phase == .searching` are richer facts that happen to be fed
//! into `in_progress`, and folding them in here would be the growth
//! `Load` declined.
//!
//! ### Why there is no `defer` helper
//!
//! The obvious sugar would be a scope guard. It would have served one
//! site out of fifty-two. The work these latches cover is *dispatched*,
//! not performed: `begin` runs on the press and `end` runs in a
//! callback that lands frames later, on paths the raising function
//! cannot see — one app's member-management screen lowers its latch at
//! eight distinct places. `defer` composes with the wrong lifetime, so
//! it is not offered; the shape that would help is a discipline about
//! where the lowering lives, and that is the app's to keep.

/// A single unit of work either in flight or not.
///
/// ```zig
/// pending_delete: nokre.Gate = .{},
///
/// pub fn deleteInvite(self: *Invites, id: []const u8) void {
///     if (!self.pending_delete.begin()) return;
///     self.port.deleteInvite(id, nokre.bindAs(Callback, onDeleted, self));
/// }
/// fn onDeleted(self: *Invites, result: Result) void {
///     self.pending_delete.end();     // on *every* arm, failure included
///     ...
/// }
/// ```
///
/// and the screen reads the field:
/// `.in_progress = self.pending_delete.up`.
pub const Gate = struct {
    /// Whether work is in flight. Public because reading it is the
    /// whole consumer story — this is the bit a builder feeds to
    /// `Button.in_progress`, `Toggle.in_progress`,
    /// `Checkbox.in_progress` or `ConfirmSheet.busy`, and a second
    /// spelling (`fn busy()`) would be two names for one fact. Write it
    /// through `begin`/`end`: a bare `= true` is exactly the
    /// check-then-set race the type exists to fuse.
    up: bool = false,

    /// Raises the gate and answers whether the caller may proceed —
    /// `false` means work is already in flight and this press is the
    /// second one. Fused on purpose: the two halves written apart are
    /// what let a handler raise a gate it had not first tested.
    ///
    /// **Put it last in a compound guard.** It mutates, so a screen's
    /// own preconditions go in front of it, where `or` short-circuits
    /// past this call instead of leaving the gate up on a path that
    /// then returns:
    ///
    /// ```zig
    /// if (!self.ready() or !self.creating.begin()) return;
    /// ```
    pub fn begin(g: *Gate) bool {
        if (g.up) return false;
        g.up = true;
        return true;
    }

    /// Lowers the gate. Idempotent, and deliberately says nothing about
    /// whether it was up: the reply paths that call it include ones
    /// that never raised it (a 428 that parks the action and re-dispatches
    /// later), and a latch that complained about its own recovery path
    /// would be reported as a bug in the recovery.
    pub fn end(g: *Gate) void {
        g.up = false;
    }
};

const std = @import("std");

test "begin admits the first caller and refuses the second" {
    var g: Gate = .{};
    try std.testing.expect(!g.up);
    try std.testing.expect(g.begin());
    try std.testing.expect(g.up);
    // The receipt: 36 guard-then-raise sites across the two apps exist
    // to make this second press do nothing.
    try std.testing.expect(!g.begin());
    try std.testing.expect(g.up);
}

test "end lowers, and lowering twice is not an error" {
    var g: Gate = .{};
    _ = g.begin();
    g.end();
    try std.testing.expect(!g.up);
    // The 428-replay path lowers a gate it did not raise.
    g.end();
    try std.testing.expect(!g.up);
    try std.testing.expect(g.begin());
}

test "a gate is down by default, so a screen's first build reads false" {
    // Every one of the fifty-two consumer fields this replaces was
    // `= false`-initialized; a Gate that had to be constructed would
    // have been a worse trade than the bool it replaces.
    const Screen = struct { creating: Gate = .{}, deleting: Gate = .{} };
    var s: Screen = .{};
    try std.testing.expect(!s.creating.up);
    try std.testing.expect(!s.deleting.up);
    // Independent latches: one screen with two acts is the common shape.
    try std.testing.expect(s.creating.begin());
    try std.testing.expect(!s.deleting.up);
}

test "the compound guard is safe only with the gate last" {
    // The one hazard `begin` introduces, pinned so the doc comment above
    // is checkable: ten consumer guards read `if (self.x or !cond())`.
    const Form = struct {
        gate: Gate = .{},
        ready: bool = false,

        fn safe(self: *@This()) bool {
            if (!self.ready or !self.gate.begin()) return false;
            return true;
        }
    };
    var f: Form = .{};
    try std.testing.expect(!f.safe());
    // Refused for not being ready — and the gate is still down, so the
    // act is reachable once the form fills in.
    try std.testing.expect(!f.gate.up);
    f.ready = true;
    try std.testing.expect(f.safe());
    try std.testing.expect(f.gate.up);
}
