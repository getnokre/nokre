//! The two containers the borrow discipline forces on every consumer.
//! Pure data in the same doctrine slot as `Load` (core/load.zig): nokre
//! never reads either type. They exist because every slice a port hands
//! a callback is borrowed for that callback — "copy a borrowed slice
//! into a bounded field", core/queue.zig — so a string a screen
//! outlives the call with, and a list of rows it draws next frame, have
//! to land in fixed-capacity storage the app owns. Two consumer apps
//! wrote `Str` three times and the same bounded row list twenty-five
//! times before this file existed; queue.zig's bar for a container
//! earning its place ("every consumer was hand-rolling the same ring")
//! is met several times over.
//!
//! No allocator, no growth, no `phase`. A `Load` *inside* `Rows` would
//! make a framework container carry app lifecycle, which is the growth
//! load.zig declined (owner decision, 2026-08-04: the vocabulary and
//! the `loadGate` idiom, nothing further). The phase stays a field
//! beside the list, written by the app that owns the request.
//!
//! The behavior worth stating up front: **a ceiling that is reached is
//! visible**. Every hand-rolled fill these replace was an undisclosed
//! `@min(cap, reply.len)`, so a list that ran over drew a plausible
//! prefix and said nothing — the class of bug this file closes. Both
//! types carry `truncated`, so "there was more than fit" is a field a
//! screen can read instead of a fact only the server knows.

const std = @import("std");

/// A string the consumer owns, up to `cap` bytes. `set` copies, so the
/// borrowed slice it came from may die with its callback.
///
/// A cut at `cap` never splits a UTF-8 sequence. The tree stores only
/// well-formed UTF-8 and every scan downstream of it trusts
/// `utf8ByteSequenceLength` (core/tree.zig, `dupeValid`); a `Str` that
/// handed back half a codepoint would push the cost of its own cut into
/// whatever the consumer passed it to next — most often straight back
/// into `append`. The cut backs up to the start of the sequence it
/// landed inside instead, and `truncated` says it happened.
///
/// Not a builder: there is no `append`, no `fmt`. A string assembled
/// from parts is assembled in a stack buffer and `set` once — one
/// truncation point is one thing to disclose, and the tree's own
/// `fmt` already owns formatting.
pub fn Str(comptime cap: usize) type {
    return struct {
        /// Bytes held. Read it freely; write through `set`.
        len: usize = 0,
        /// Whether the last `set` stored less than it was handed —
        /// because the value was longer than `cap`, or because the cut
        /// backed up to a codepoint boundary. `set` is the only writer
        /// and it overwrites: each one answers for the value it just
        /// installed, so this is the state of the value now, never a
        /// high-water mark.
        truncated: bool = false,
        buf: [cap]u8 = undefined,

        const Self = @This();

        /// The ceiling, for the copy that wants to name it.
        pub const capacity = cap;

        /// Take a copy of `value`, replacing whatever was held.
        ///
        /// `value` may be a slice of this `Str`'s own bytes — trimming,
        /// re-parsing or normalizing in place is the obvious call and
        /// it is a legal one. `copyForwards`, not `@memcpy`, is what
        /// makes it legal: the destination is `buf[0..]`, the lowest
        /// address in the buffer, so an aliasing source is always at or
        /// above it and a forward copy can never overwrite a byte it
        /// has yet to read. Nothing here can want `copyBackwards`.
        pub fn set(self: *Self, value: []const u8) void {
            self.len = boundaryAt(value, @min(cap, value.len));
            self.truncated = self.len != value.len;
            std.mem.copyForwards(u8, self.buf[0..self.len], value[0..self.len]);
        }

        /// The bytes, borrowed from the `Str` — valid as long as it is
        /// not `set` again, which is the whole frame in practice.
        pub fn get(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        /// Byte equality against anything sliceable. Two `Str`s compare
        /// as `a.eql(b.get())`; there is no separate verb for it,
        /// because a `Str` is only ever its bytes.
        pub fn eql(self: *const Self, value: []const u8) bool {
            return std.mem.eql(u8, self.get(), value);
        }

        /// The bytes without their surrounding ASCII whitespace: what a
        /// form submits, and what a search box queries with. A separate
        /// verb rather than trimming inside `set`, because the field is
        /// also what the input element draws — a `text_input` whose
        /// trailing space vanished as it was typed is an input that
        /// fights the typist.
        ///
        /// Deliberately ASCII: these are addresses, codes and names
        /// typed into `text_input`, and recognizing U+00A0 and its
        /// relatives would mean a Unicode space table nokre needs
        /// nowhere else.
        pub fn trimmed(self: *const Self) []const u8 {
            return std.mem.trim(u8, self.get(), &std.ascii.whitespace);
        }

        /// Nothing a form would accept: empty, or whitespace only.
        pub fn blank(self: *const Self) bool {
            return self.trimmed().len == 0;
        }
    };
}

/// Where a cut at `limit` may land without splitting a UTF-8 sequence:
/// the byte at `limit` is the first one dropped, so while it continues
/// a sequence that started earlier, that whole sequence goes with it.
/// Bounded at three steps — no sequence is longer than four bytes — so
/// input that was already ill-formed costs a constant walk and then
/// gets the cut it asked for; making it well-formed is the tree's job
/// at its own boundary, not a fixed-capacity buffer's.
fn boundaryAt(value: []const u8, limit: usize) usize {
    if (limit >= value.len) return value.len;
    var n = limit;
    while (n > 0 and limit - n < 3 and value[n] & 0xC0 == 0x80) n -= 1;
    if (value[n] & 0xC0 == 0x80) return limit;
    return n;
}

/// Whether `T{}` builds — what `push` needs to hand back a clean slot.
fn defaultable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    for (info.@"struct".fields) |f| {
        if (f.default_value_ptr == null) return false;
    }
    return true;
}

/// A list of rows the consumer owns, up to `cap` of them. The shape
/// every screen over a fetched collection was hand-writing: a length, a
/// fixed array, and the verbs below.
///
/// Two ways in, because consumers had two. `push` hands back an empty
/// slot to fill field by field — the form a reply handler wants, since
/// a row is assembled from a wire struct that is not this type. `append`
/// takes a whole `T` — the form a row already built wants. `push` needs
/// `T{}` to build, so it is a compile error on a row whose fields lack
/// defaults, and on a scalar or enum row; `append` works for any `T`.
pub fn Rows(comptime T: type, comptime cap: usize) type {
    return struct {
        /// Rows held. Read it freely; write through the verbs.
        len: usize = 0,
        /// Whether anything was offered and did not fit. Two writers
        /// reset it and two only ever raise it: `clear` clears it, and
        /// `fill` overwrites it — a `fill` replaces the whole list, so
        /// like `Str.set` it answers for the list it just installed,
        /// not for one a previous load overran. `push` and `append`
        /// raise it on every refusal, so it accumulates across a
        /// `clear`-then-fill-loop, which is the shape that needs it.
        /// `removeAt` leaves it alone: making room after the fact does
        /// not bring back rows that never arrived.
        ///
        /// A bool, not a count of what was dropped: the honest fill
        /// loop stops at the first refusal (`push() orelse break`), so
        /// a count would read `1` whether one row was lost or a
        /// thousand. "There was more than fits" is the whole truth this
        /// container has, and a screen that says "showing the first 24"
        /// needs nothing else.
        truncated: bool = false,
        rows: [cap]T = undefined,

        const Self = @This();

        /// The ceiling, for the meter or the copy that names it.
        pub const capacity = cap;

        /// The rows, for reading — what a screen loops over.
        pub fn items(self: *const Self) []const T {
            return self.rows[0..self.len];
        }

        /// The rows, for writing: `std.mem.sort`, or an edit in place
        /// after a reply lands. Screens take `items`.
        pub fn itemsMut(self: *Self) []T {
            return self.rows[0..self.len];
        }

        /// The row at `index`, or `null` past the end. The verb for a
        /// screen holding an index into a list — a sheet's target, a
        /// tapped tile — where the index came from a frame the reply
        /// that shrank the list has since rebuilt. Every hand-written
        /// version of this was `&list.rows[index]`, some with the
        /// bounds check and some without.
        pub fn at(self: *const Self, index: usize) ?*const T {
            if (index >= self.len) return null;
            return &self.items()[index];
        }

        /// Empty, and no ceiling reached — where a reload starts.
        pub fn clear(self: *Self) void {
            self.len = 0;
            self.truncated = false;
        }

        /// A new row at the end, reset to `T{}`, for the caller to
        /// fill through the pointer. `null` when the list is full, and
        /// a refusal is a truncation: the ceiling was reached with
        /// something still to store.
        ///
        /// The pointer is into the list's own storage, so it stays good
        /// until the next `clear`, `fill`, or `removeAt` — long enough
        /// for the callback that is filling it, which is the only place
        /// it is meant to live.
        pub fn push(self: *Self) ?*T {
            comptime if (!defaultable(T))
                @compileError("Rows(" ++ @typeName(T) ++ ", …).push: a pushed slot is reset to `" ++ @typeName(T) ++ "{}` first, so every field of the row needs a default — a row type without one (or a scalar row) is `append(value)` instead");
            if (self.len == cap) {
                self.truncated = true;
                return null;
            }
            // Through a slice, not `self.rows[self.len]`: a `cap` of
            // zero makes the array indexing a compile error even though
            // the guard above has already returned, and a container
            // whose zero case does not compile is a trap for the
            // comptime-computed capacity that lands on zero.
            const all: []T = &self.rows;
            all[self.len] = .{};
            self.len += 1;
            return &all[self.len - 1];
        }

        /// A row already built, stored at the end. `false` when the
        /// list is full — and, like a refused `push`, that is a
        /// truncation. The form for a row assembled elsewhere, and the
        /// only form for a row that is a scalar or an enum.
        pub fn append(self: *Self, value: T) bool {
            if (self.len == cap) {
                self.truncated = true;
                return false;
            }
            const all: []T = &self.rows;
            all[self.len] = value;
            self.len += 1;
            return true;
        }

        /// Replace the whole list with `src`, keeping the first `cap`
        /// and disclosing the rest. The form for a reply that already
        /// speaks in `T`; a reply in the wire's own row type is
        /// `clear` plus a `push` loop, which discloses the same way.
        ///
        /// `src` may be a slice of this list's own rows — dropping a
        /// head is `list.fill(list.items()[k..])` — for the reason
        /// `Str.set` states: the destination starts at `rows[0]`, so an
        /// aliasing source is never below it and a forward copy is
        /// always correct.
        pub fn fill(self: *Self, src: []const T) void {
            self.len = @min(cap, src.len);
            self.truncated = src.len > cap;
            std.mem.copyForwards(T, self.rows[0..self.len], src[0..self.len]);
        }

        /// Drop the row at `index`, closing the gap and keeping order —
        /// what a list edited by the user (a draft, a chosen set) does
        /// on every removal. Out of range is a no-op rather than a
        /// panic: the index a screen holds came from a frame that may
        /// have been rebuilt under it. Leaves `truncated` where it
        /// stands, for the reason that field states.
        pub fn removeAt(self: *Self, index: usize) void {
            if (index >= self.len) return;
            const all: []T = &self.rows;
            var i = index;
            while (i + 1 < self.len) : (i += 1) all[i] = all[i + 1];
            self.len -= 1;
        }

        /// Whether the next `push` or `append` would refuse.
        pub fn full(self: *const Self) bool {
            return self.len == cap;
        }
    };
}

// ---- design-proof tests ----

const testing = std.testing;

test "a value longer than the capacity is truncated, and says so" {
    var s: Str(4) = .{};
    s.set("abcdefg");
    try testing.expectEqualStrings("abcd", s.get());
    try testing.expect(s.truncated);
}

test "truncated is the state of the value now, not a high-water mark" {
    var s: Str(4) = .{};
    s.set("abcdefg");
    try testing.expect(s.truncated);
    s.set("ab");
    try testing.expectEqualStrings("ab", s.get());
    try testing.expect(!s.truncated);
}

test "a shorter value replaces the whole of a longer one" {
    var s: Str(8) = .{};
    s.set("original");
    s.set("new");
    try testing.expectEqualStrings("new", s.get());
}

test "a cut inside a codepoint drops the whole sequence, never half of it" {
    // "aé" — 'é' is two bytes, so a three-byte ceiling lands inside it.
    var two: Str(2) = .{};
    two.set("aé");
    try testing.expectEqualStrings("a", two.get());
    try testing.expect(two.truncated);
    try testing.expect(std.unicode.utf8ValidateSlice(two.get()));

    // A four-byte sequence cut at every interior offset.
    inline for (.{ 1, 2, 3 }) |ceiling| {
        var s: Str(ceiling) = .{};
        s.set("🙂x");
        try testing.expectEqualStrings("", s.get());
        try testing.expect(s.truncated);
    }
    var whole: Str(4) = .{};
    whole.set("🙂x");
    try testing.expectEqualStrings("🙂", whole.get());
    try testing.expect(whole.truncated);

    // Three bytes of a three-byte sequence still fit exactly.
    var exact: Str(3) = .{};
    exact.set("€");
    try testing.expectEqualStrings("€", exact.get());
    try testing.expect(!exact.truncated);
}

test "an ill-formed source is cut where the ceiling fell, not walked back forever" {
    // A run of bare continuation bytes has no lead to back up to; the
    // cut stands, and making it well-formed is the tree's job.
    var s: Str(4) = .{};
    s.set("\x80\x80\x80\x80\x80\x80");
    try testing.expectEqual(@as(usize, 4), s.len);
    try testing.expect(s.truncated);
}

test "eql compares bytes, and a truncated value is not the value it came from" {
    var s: Str(8) = .{};
    s.set("hello");
    try testing.expect(s.eql("hello"));
    try testing.expect(!s.eql("hell"));

    var cut: Str(4) = .{};
    cut.set("hello");
    try testing.expect(!cut.eql("hello"));
    try testing.expect(cut.eql("hell"));
}

test "blank is empty or ascii whitespace only" {
    var s: Str(16) = .{};
    try testing.expect(s.blank());
    s.set("   \t\n ");
    try testing.expect(s.blank());
    s.set("  a  ");
    try testing.expect(!s.blank());
}

test "trimmed hands back the value without its edges; set keeps them" {
    var s: Str(16) = .{};
    s.set("  hello \n");
    try testing.expectEqualStrings("  hello \n", s.get());
    try testing.expectEqualStrings("hello", s.trimmed());
    s.set("");
    try testing.expectEqualStrings("", s.trimmed());
}

test "a Str may be set from its own bytes" {
    // `@memcpy` panics on aliasing arguments in a safe build, so every
    // call below is a live tripwire, not a shape argument.

    // Trim in place — the natural way to normalize a typed field.
    var s: Str(32) = .{};
    s.set("  hello  ");
    s.set(std.mem.trim(u8, s.get(), " "));
    try testing.expectEqualStrings("hello", s.get());

    // The same move through the container's own verb: the shape both
    // consumer apps had, where a parse hands back a subslice of the
    // buffer it was given.
    var field: Str(32) = .{};
    field.set("\t user@example.com \n");
    field.set(field.trimmed());
    try testing.expectEqualStrings("user@example.com", field.get());

    // Identity: same pointer, same length, still a copy that must not
    // be undefined behavior.
    field.set(field.get());
    try testing.expectEqualStrings("user@example.com", field.get());

    // The worst overlap there is: a source one byte above the
    // destination, so every read is of a byte the write is about to
    // reach. Forward order is what keeps it ahead.
    var shift: Str(16) = .{};
    shift.set("abcdefgh");
    shift.set(shift.get()[1..]);
    try testing.expectEqualStrings("bcdefgh", shift.get());

    // An aliasing `set` can never truncate — the source lives in the
    // buffer, so it is at most `cap` long — which is why the disclosure
    // stays false through all of the above.
    try testing.expect(!shift.truncated);
}

test "a zero-capacity Str holds nothing and reports the loss" {
    var s: Str(0) = .{};
    s.set("anything");
    try testing.expectEqualStrings("", s.get());
    try testing.expect(s.truncated);
    s.set("");
    try testing.expect(!s.truncated);
}

test "a one-capacity Str takes one ascii byte, and no part of a wider codepoint" {
    var s: Str(1) = .{};
    s.set("ab");
    try testing.expectEqualStrings("a", s.get());
    s.set("é");
    try testing.expectEqualStrings("", s.get());
    try testing.expect(s.truncated);
}

const Row = struct {
    id: Str(8) = .{},
    count: u32 = 0,
};

test "push fills from the end and clear takes it all back" {
    var list: Rows(Row, 4) = .{};
    try testing.expectEqual(@as(usize, 0), list.items().len);

    for (0..3) |i| {
        const row = list.push().?;
        row.id.set("r");
        row.count = @intCast(i);
    }
    try testing.expectEqual(@as(usize, 3), list.items().len);
    try testing.expectEqual(@as(u32, 2), list.items()[2].count);
    try testing.expect(!list.truncated);
    try testing.expect(!list.full());

    list.clear();
    try testing.expectEqual(@as(usize, 0), list.items().len);
}

test "a push at capacity refuses, discloses, and corrupts nothing" {
    var list: Rows(Row, 2) = .{};
    list.push().?.count = 1;
    list.push().?.count = 2;
    try testing.expect(list.full());

    try testing.expect(list.push() == null);
    try testing.expect(list.truncated);
    try testing.expectEqual(@as(usize, 2), list.items().len);
    try testing.expectEqual(@as(u32, 1), list.items()[0].count);
    try testing.expectEqual(@as(u32, 2), list.items()[1].count);
}

test "a reused slot never shows the previous row" {
    var list: Rows(Row, 2) = .{};
    const first = list.push().?;
    first.id.set("gone");
    first.count = 9;
    list.clear();

    const again = list.push().?;
    try testing.expectEqualStrings("", again.id.get());
    try testing.expectEqual(@as(u32, 0), again.count);
}

test "clear resets the disclosure; the next load starts clean" {
    var list: Rows(Row, 1) = .{};
    _ = list.push();
    try testing.expect(list.push() == null);
    try testing.expect(list.truncated);

    list.clear();
    try testing.expect(!list.truncated);
    try testing.expect(list.push() != null);
}

test "fill keeps the first cap rows and says there were more" {
    const src = [_]Row{
        .{ .count = 0 },
        .{ .count = 1 },
        .{ .count = 2 },
        .{ .count = 3 },
    };
    var list: Rows(Row, 2) = .{};
    list.fill(&src);
    try testing.expectEqual(@as(usize, 2), list.items().len);
    try testing.expectEqual(@as(u32, 1), list.items()[1].count);
    try testing.expect(list.truncated);

    // A fill that fits answers for itself, the way `Str.set` does.
    list.fill(src[0..2]);
    try testing.expect(!list.truncated);
    try testing.expectEqual(@as(usize, 2), list.items().len);
}

test "the fill loop that replaces an undisclosed @min discloses instead" {
    // The shape every consumer hand-wrote: a reply in the wire's row
    // type, copied field by field into bounded storage.
    const Reply = struct { name: []const u8, count: u32 };
    const replies = [_]Reply{
        .{ .name = "alpha", .count = 1 },
        .{ .name = "beta", .count = 2 },
        .{ .name = "gamma", .count = 3 },
    };

    var list: Rows(Row, 2) = .{};
    list.clear();
    for (replies) |reply| {
        const row = list.push() orelse break;
        row.id.set(reply.name);
        row.count = reply.count;
    }
    try testing.expect(list.truncated);
    try testing.expectEqual(@as(usize, 2), list.items().len);
    try testing.expectEqualStrings("beta", list.items()[1].id.get());
}

test "a list may be filled from its own rows" {
    // `fill`'s destination is `rows[0..]`, so `src` aliasing the list
    // is the same forward-copy case `Str.set` is — and dropping a head
    // is the shape that reaches it.
    var list: Rows(Row, 4) = .{};
    for (0..4) |i| list.push().?.count = @intCast(i);

    list.fill(list.items()[1..]);
    try testing.expectEqual(@as(usize, 3), list.items().len);
    try testing.expectEqual(@as(u32, 1), list.items()[0].count);
    try testing.expectEqual(@as(u32, 3), list.items()[2].count);
    try testing.expect(!list.truncated);

    // Identity, the degenerate alias.
    list.fill(list.items());
    try testing.expectEqual(@as(usize, 3), list.items().len);
    try testing.expectEqual(@as(u32, 1), list.items()[0].count);
}

test "a zero-capacity list refuses the first push" {
    var list: Rows(Row, 0) = .{};
    try testing.expect(list.full());
    try testing.expect(list.push() == null);
    try testing.expect(list.truncated);
    try testing.expectEqual(@as(usize, 0), list.items().len);

    list.clear();
    try testing.expect(!list.truncated);

    // fill of nothing into nothing is not a truncation.
    list.fill(&.{});
    try testing.expect(!list.truncated);
    list.fill(&.{.{}});
    try testing.expect(list.truncated);
}

test "a one-capacity list holds the first row and refuses the second" {
    var list: Rows(Row, 1) = .{};
    list.push().?.count = 7;
    try testing.expect(list.push() == null);
    try testing.expectEqual(@as(u32, 7), list.items()[0].count);
    try testing.expect(list.truncated);
}

test "removeAt closes the gap, keeps order, and ignores an index that is gone" {
    var list: Rows(Row, 4) = .{};
    for (0..3) |i| list.push().?.count = @intCast(i);

    list.removeAt(1);
    try testing.expectEqual(@as(usize, 2), list.items().len);
    try testing.expectEqual(@as(u32, 0), list.items()[0].count);
    try testing.expectEqual(@as(u32, 2), list.items()[1].count);

    list.removeAt(9);
    try testing.expectEqual(@as(usize, 2), list.items().len);
}

test "removing does not un-truncate: the rows that never fit are still missing" {
    var list: Rows(Row, 2) = .{};
    _ = list.push();
    _ = list.push();
    try testing.expect(list.push() == null);

    list.removeAt(0);
    try testing.expect(list.truncated);
}

test "itemsMut is what sorting takes" {
    var list: Rows(Row, 4) = .{};
    for ([_]u32{ 3, 1, 2 }) |n| list.push().?.count = n;

    const byCount = struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            return a.count < b.count;
        }
    }.lessThan;
    std.mem.sort(Row, list.itemsMut(), {}, byCount);

    try testing.expectEqual(@as(u32, 1), list.items()[0].count);
    try testing.expectEqual(@as(u32, 3), list.items()[2].count);
}

test "at is bounds-checked; an index the list has outgrown is null" {
    var list: Rows(Row, 4) = .{};
    for (0..2) |i| list.push().?.count = @intCast(i);

    try testing.expectEqual(@as(u32, 1), list.at(1).?.count);
    try testing.expect(list.at(2) == null);

    list.clear();
    try testing.expect(list.at(0) == null);
}

test "append takes a whole row, and refuses the same way push does" {
    var list: Rows(Row, 2) = .{};
    try testing.expect(list.append(.{ .count = 1 }));
    try testing.expect(list.append(.{ .count = 2 }));
    try testing.expect(!list.append(.{ .count = 3 }));
    try testing.expect(list.truncated);
    try testing.expectEqual(@as(u32, 2), list.items()[1].count);
}

test "a row that is not a struct still appends" {
    // `push` cannot serve these — there is no `usize{}` — which is why
    // there are two doors.
    var counts: Rows(usize, 2) = .{};
    try testing.expect(counts.append(7));
    try testing.expect(counts.append(9));
    try testing.expect(!counts.append(11));
    try testing.expect(counts.truncated);
    try testing.expectEqualSlices(usize, &.{ 7, 9 }, counts.items());

    const Dim = enum { one, two };
    var dims: Rows(Dim, 3) = .{};
    try testing.expect(dims.append(.two));
    try testing.expectEqual(Dim.two, dims.items()[0]);
}

test "a list of strings is a list of rows like any other" {
    var names: Rows(Str(8), 2) = .{};
    for ([_][]const u8{ "one", "two", "three" }) |name| {
        const slot = names.push() orelse break;
        slot.set(name);
    }
    try testing.expectEqualStrings("one", names.items()[0].get());
    try testing.expect(names.truncated);
}
