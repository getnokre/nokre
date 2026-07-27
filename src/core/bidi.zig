//! UAX #9, the Unicode bidirectional algorithm, in integer Zig.
//!
//! Persian (and Arabic) text is the reason this exists; the algorithm is
//! implemented in full — explicit embeddings and isolates, weak and
//! neutral resolution including paired brackets — because a partial bidi
//! is worse than none: it moves pixels in ways no spec predicts. The
//! implementation is validated against the UCD's BidiCharacterTest in
//! `bidi_test.zig`.
//!
//! It lives in core, not the shim, deliberately: layout (line origin,
//! wrap widths), the renderer (visual run order), and editing (caret
//! geometry) all depend on run boundaries, and those must be identical
//! under the headless harness and the Skia backend. The shim only ever
//! sees single-direction runs and never re-derives order.
//!
//! Two tiers, matching how nokre consumes it:
//!
//! - Allocation-free scans: `paragraphDirection` (UAX #9 P2/P3 — a
//!   paragraph's direction is derived from its first strong character,
//!   never declared; there is no dir attribute to get wrong) and
//!   `measureRuns`, the segmentation every width measurement uses.
//! - Full resolution: `resolve` computes per-codepoint embedding levels
//!   into caller scratch (`Scratch`, one per App — a module-global would
//!   be a bug); `lineRuns` applies the line rules L1–L2 to any byte
//!   range of the paragraph and yields runs in visual order.
//!
//! Paragraphs beyond `max_paragraph` codepoints degrade deterministically
//! to a single run of the paragraph direction — the same bytes degrade
//! the same way on every machine.

const std = @import("std");
const tables = @import("bidi_tables.zig");

pub const Class = tables.Class;

/// Bidi class of a codepoint. Binary search over the generated ranges;
/// codepoints outside every range are L (the generator omits L ranges).
pub fn classOf(cp: u21) Class {
    const ranges = &tables.class_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return r.class;
        }
    }
    return .L;
}

pub const Direction = enum { ltr, rtl };

fn isIsolateInitiator(c: Class) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}

/// True for the classes the N rules treat as resolvable neutrals
/// ("NI" in the spec): neutrals plus isolate formatting characters.
fn isNeutralOrIsolate(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI => true,
        else => false,
    };
}

/// UAX #9 P2/P3: the direction of the first strong character, skipping
/// characters between an isolate initiator and its matching PDI. No
/// strong character means LTR.
pub fn paragraphDirection(bytes: []const u8) Direction {
    var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    var isolate_depth: u32 = 0;
    while (it.nextCodepoint()) |cp| {
        switch (classOf(cp)) {
            .LRI, .RLI, .FSI => isolate_depth += 1,
            .PDI => {
                if (isolate_depth > 0) isolate_depth -= 1;
            },
            .L => {
                if (isolate_depth == 0) return .ltr;
            },
            .R, .AL => {
                if (isolate_depth == 0) return .rtl;
            },
            else => {},
        }
    }
    return .ltr;
}

/// The gate every text path shares: true when the bytes need run
/// segmentation at all — any Arabic-script codepoint (face change) or
/// any strong RTL class (reordering). One scan; the overwhelmingly
/// common all-Latin string costs nothing else.
pub fn isComplex(bytes: []const u8) bool {
    var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (isArabicScript(cp)) return true;
        switch (classOf(cp)) {
            .R, .AL, .AN, .RLE, .RLO, .RLI => return true,
            else => {},
        }
    }
    return false;
}

/// True when the bytes contain any strong right-to-left codepoint. The
/// fast-path gate: without one there is nothing to reorder and nothing
/// the companion face is needed for.
pub fn hasRtl(bytes: []const u8) bool {
    var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        switch (classOf(cp)) {
            .R, .AL, .AN, .RLE, .RLO, .RLI => return true,
            else => {},
        }
    }
    return false;
}

/// Arabic-script codepoints — the blocks the bundled companion face is
/// responsible for. Script, not bidi class, decides the face: Hebrew is
/// strong RTL but has no bundled face, so it stays with the family face
/// (and its tofu is honest — there is no face that could render it).
pub fn isArabicScript(cp: u21) bool {
    return (cp >= 0x0600 and cp <= 0x06FF) // Arabic
    or (cp >= 0x0750 and cp <= 0x077F) // Arabic Supplement
    or (cp >= 0x0870 and cp <= 0x08FF) // Extended-B, Extended-A
    or (cp >= 0xFB50 and cp <= 0xFDFF) // Presentation Forms-A
    or (cp >= 0xFE70 and cp <= 0xFEFF); // Presentation Forms-B
}

/// The face and shaping direction a measurement run resolves to.
pub const RunKind = enum { base, arabic, number };

pub const MeasureRun = struct {
    bytes: []const u8,
    kind: RunKind,
};

/// Splits text into the runs that are measured — and therefore shaped —
/// independently. Boundaries fall where the required face changes
/// (Arabic script vs. the requested family) and, when the text contains
/// strong RTL, around digit runs, which take their own embedding level
/// under the I rules and so are drawn as separate pieces. Weak and
/// neutral characters extend the run before them; a leading stretch
/// joins the first anchored run.
///
/// This is deliberately a pure function of the bytes — no paragraph
/// context, no scratch — so that layout's width sums, the renderer's pen
/// advances, and editing's caret prefixes all segment identically. The
/// cost is measured kerning across these boundaries, which is forfeited
/// exactly as it already is across span boundaries.
pub const MeasureRunIterator = struct {
    bytes: []const u8,
    i: usize = 0,
    split_numbers: bool,

    pub fn init(bytes: []const u8) MeasureRunIterator {
        return .{ .bytes = bytes, .split_numbers = hasRtl(bytes) };
    }

    /// Anchor kind of a codepoint, or null for characters that extend
    /// whatever run they sit in.
    fn anchor(self: *const MeasureRunIterator, cp: u21) ?RunKind {
        if (isArabicScript(cp)) {
            // Arabic-Indic digits are Arabic script but class AN: they
            // are placed like numbers yet drawn from the companion face,
            // so they anchor as numbers only when reordering is live.
            if (self.split_numbers) {
                const c = classOf(cp);
                if (c == .AN or c == .EN) return .number;
            }
            return .arabic;
        }
        const c = classOf(cp);
        return switch (c) {
            .L, .R => .base,
            .EN, .AN => if (self.split_numbers) .number else .base,
            else => null,
        };
    }

    pub fn next(self: *MeasureRunIterator) ?MeasureRun {
        if (self.i >= self.bytes.len) return null;
        const start = self.i;
        var it = std.unicode.Utf8Iterator{ .bytes = self.bytes, .i = self.i };
        var kind: ?RunKind = null;
        var end = start;
        while (true) {
            const before = it.i;
            const cp = it.nextCodepoint() orelse break;
            const a = self.anchor(cp);
            if (a) |k| {
                if (kind != null and k != kind.?) {
                    end = before;
                    break;
                }
                kind = k;
            }
            end = it.i;
        }
        self.i = end;
        return .{ .bytes = self.bytes[start..end], .kind = kind orelse .base };
    }
};

pub fn measureRuns(bytes: []const u8) MeasureRunIterator {
    return MeasureRunIterator.init(bytes);
}

// ---------------------------------------------------------------------------
// Full resolution: explicit levels (X), weak (W), neutral (N), implicit (I).
// ---------------------------------------------------------------------------

/// Codepoint budget of one paragraph resolution. Beyond it, ordering
/// degrades to a single run of the paragraph direction — deterministic,
/// documented, and far past what one screen of text holds.
pub const max_paragraph = 4096;

const max_depth = 125; // spec constant: maximum explicit embedding depth
const removed_level = 0xFF; // X9-removed characters, patched after I rules

/// Working memory for one paragraph resolution. One per App; contents
/// are only valid between `resolve` and the next `resolve` on the same
/// scratch. ~100 KB — bounded, embedded (not on the stack: wasm stacks
/// are small), never allocated per frame.
pub const Scratch = struct {
    classes: [max_paragraph]Class = undefined,
    levels: [max_paragraph]u8 = undefined,
    /// Byte offset of each codepoint, plus one trailing sentinel.
    offsets: [max_paragraph + 1]u32 = undefined,
    /// Every non-removed codepoint index, grouped by isolating run
    /// sequence — the W/N/I rules run over slices of this.
    seq_indices: [max_paragraph]u16 = undefined,
    /// Level-run workspace for X10.
    build_runs: [max_paragraph]BuildRun = undefined,
};

const BuildRun = struct { start: u16, end: u16, level: u8, used: bool };

pub const Paragraph = struct {
    bytes: []const u8,
    level: u8,
    /// Per-codepoint resolved embedding levels; empty when degraded.
    levels: []const u8 = &.{},
    /// Byte offset per codepoint plus end sentinel; empty when degraded.
    offsets: []const u32 = &.{},
    degraded: bool = false,

    pub fn direction(self: *const Paragraph) Direction {
        return if (self.level & 1 == 1) .rtl else .ltr;
    }
};

const StackEntry = struct {
    level: u8,
    override: enum { neutral, ltr, rtl },
    isolate: bool,
};

const IsoMatch = struct { initiator: u16, pdi: u16 };
const max_iso_matches = 64;

const Sequence = struct {
    start: u16, // into scratch.seq_indices
    len: u16,
    level: u8,
    sos: Direction,
    eos: Direction,
};
const max_sequences = 256;

/// Resolves one paragraph's embedding levels (rules X1–I2). `dir` is the
/// paragraph direction — normally `paragraphDirection(bytes)`.
pub fn resolve(s: *Scratch, bytes: []const u8, dir: Direction) Paragraph {
    const para_level: u8 = if (dir == .rtl) 1 else 0;
    var para: Paragraph = .{ .bytes = bytes, .level = para_level };

    // Decode: classes and byte offsets per codepoint.
    var n: usize = 0;
    {
        var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (true) {
            const off = it.i;
            const cp = it.nextCodepoint() orelse break;
            if (n == max_paragraph) {
                para.degraded = true;
                return para;
            }
            s.offsets[n] = @intCast(off);
            s.classes[n] = classOf(cp);
            n += 1;
        }
        s.offsets[n] = @intCast(bytes.len);
    }
    if (n == 0) {
        para.levels = s.levels[0..0];
        para.offsets = s.offsets[0..1];
        return para;
    }

    var iso_matches: [max_iso_matches]IsoMatch = undefined;
    const matches = matchIsolates(s.classes[0..n], &iso_matches);

    explicitLevels(s, n, para_level, matches);

    // X10: isolating run sequences, then the character rules over each.
    var seqs: [max_sequences]Sequence = undefined;
    const seq_count = buildSequences(s, n, para_level, matches, &seqs);
    for (seqs[0..seq_count]) |seq| {
        const idx = s.seq_indices[seq.start .. seq.start + seq.len];
        resolveWeak(s, idx, seq);
        resolveBrackets(s, bytes, idx, seq);
        resolveNeutral(s, idx, seq);
        resolveImplicit(s, idx);
    }

    // X9-removed characters take the level of their left neighbor (the
    // paragraph level at the start): ZWNJ keeps riding with the letters
    // it joins, and formatting characters vanish into an adjacent run.
    var prev_level: u8 = para_level;
    for (0..n) |i| {
        if (s.levels[i] == removed_level) {
            s.levels[i] = prev_level;
        } else {
            prev_level = s.levels[i];
        }
    }

    para.levels = s.levels[0..n];
    para.offsets = s.offsets[0 .. n + 1];
    return para;
}

/// BD9: match isolate initiators to their PDIs (one linear pass). Pairs
/// beyond the fixed budget go unmatched — overflow already means the
/// text is adversarial, and unmatched is the spec's own fallback there.
fn matchIsolates(classes: []const Class, out: *[max_iso_matches]IsoMatch) []const IsoMatch {
    var stack: [max_depth + 1]u16 = undefined;
    var depth: usize = 0;
    var count: usize = 0;
    for (classes, 0..) |c, i| {
        if (isIsolateInitiator(c)) {
            if (depth < stack.len) {
                stack[depth] = @intCast(i);
                depth += 1;
            }
        } else if (c == .PDI and depth > 0) {
            depth -= 1;
            if (count < max_iso_matches) {
                out[count] = .{ .initiator = stack[depth], .pdi = @intCast(i) };
                count += 1;
            }
        }
    }
    return out[0..count];
}

fn matchingPdi(matches: []const IsoMatch, initiator: usize) ?usize {
    for (matches) |m| {
        if (m.initiator == initiator) return m.pdi;
    }
    return null;
}

fn matchingInitiator(matches: []const IsoMatch, pdi: usize) ?usize {
    for (matches) |m| {
        if (m.pdi == pdi) return m.initiator;
    }
    return null;
}

/// Rules X1–X9: explicit embedding and isolate levels via the
/// directional status stack. Leaves per-codepoint levels in s.levels
/// (removed_level for X9-removed characters) and applies directional
/// overrides to s.classes.
fn explicitLevels(s: *Scratch, n: usize, para_level: u8, matches: []const IsoMatch) void {
    var stack: [max_depth + 2]StackEntry = undefined;
    stack[0] = .{ .level = para_level, .override = .neutral, .isolate = false };
    var top: usize = 0;
    var overflow_isolate: u32 = 0;
    var overflow_embedding: u32 = 0;
    var valid_isolate: u32 = 0;

    for (0..n) |i| {
        const class = s.classes[i];
        switch (class) {
            .RLE, .LRE, .RLO, .LRO => {
                s.levels[i] = removed_level;
                const rtl = class == .RLE or class == .RLO;
                const new_level: u8 = if (rtl)
                    (stack[top].level + 1) | 1
                else
                    (stack[top].level + 2) & ~@as(u8, 1);
                if (new_level <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    top += 1;
                    stack[top] = .{
                        .level = new_level,
                        .override = switch (class) {
                            .RLO => .rtl,
                            .LRO => .ltr,
                            else => .neutral,
                        },
                        .isolate = false,
                    };
                } else if (overflow_isolate == 0) {
                    overflow_embedding += 1;
                }
                s.classes[i] = .BN;
            },
            .RLI, .LRI, .FSI => {
                // FSI acts as RLI or LRI per the first strong class of
                // its own isolated content (P2/P3 scoped to the isolate).
                var acts_rtl = class == .RLI;
                if (class == .FSI) {
                    acts_rtl = fsiDirection(s.classes[0..n], i, matches) == .rtl;
                }
                s.levels[i] = stack[top].level;
                applyOverride(s, i, stack[top].override);
                const new_level: u8 = if (acts_rtl)
                    (stack[top].level + 1) | 1
                else
                    (stack[top].level + 2) & ~@as(u8, 1);
                if (new_level <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    valid_isolate += 1;
                    top += 1;
                    stack[top] = .{ .level = new_level, .override = .neutral, .isolate = true };
                } else {
                    overflow_isolate += 1;
                }
            },
            .PDI => {
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate > 0) {
                    overflow_embedding = 0;
                    while (!stack[top].isolate) top -= 1;
                    top -= 1;
                    valid_isolate -= 1;
                }
                s.levels[i] = stack[top].level;
                applyOverride(s, i, stack[top].override);
            },
            .PDF => {
                s.levels[i] = removed_level;
                if (overflow_isolate == 0) {
                    if (overflow_embedding > 0) {
                        overflow_embedding -= 1;
                    } else if (!stack[top].isolate and top >= 1) {
                        top -= 1;
                    }
                }
                s.classes[i] = .BN;
            },
            .B => {
                // X8. Paragraph separators inside the text nokre hands
                // over (it splits on \n before wrapping) reset to the
                // paragraph level.
                s.levels[i] = para_level;
                top = 0;
                overflow_isolate = 0;
                overflow_embedding = 0;
                valid_isolate = 0;
            },
            .BN => s.levels[i] = removed_level,
            else => {
                s.levels[i] = stack[top].level;
                applyOverride(s, i, stack[top].override);
            },
        }
    }
}

fn applyOverride(s: *Scratch, i: usize, override: anytype) void {
    switch (override) {
        .ltr => s.classes[i] = .L,
        .rtl => s.classes[i] = .R,
        .neutral => {},
    }
}

/// P2/P3 scoped to an FSI's content: first strong class between the
/// initiator and its matching PDI, skipping nested isolates.
fn fsiDirection(classes: []const Class, fsi: usize, matches: []const IsoMatch) Direction {
    const end = matchingPdi(matches, fsi) orelse classes.len;
    var depth: u32 = 0;
    for (classes[fsi + 1 .. end]) |c| {
        if (isIsolateInitiator(c)) {
            depth += 1;
        } else if (c == .PDI) {
            if (depth > 0) depth -= 1;
        } else if (depth == 0) {
            switch (c) {
                .L => return .ltr,
                .R, .AL => return .rtl,
                else => {},
            }
        }
    }
    return .ltr;
}

/// X10: group the level runs into isolating run sequences and compute
/// sos/eos for each. Fills scratch.seq_indices with every non-removed
/// codepoint index, sequence by sequence.
fn buildSequences(s: *Scratch, n: usize, para_level: u8, matches: []const IsoMatch, out: *[max_sequences]Sequence) usize {
    // Level runs over non-removed codepoints.
    const runs = &s.build_runs;
    var run_count: usize = 0;
    {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (s.levels[i] == removed_level) continue;
            if (run_count > 0 and
                runs[run_count - 1].level == s.levels[i] and
                contiguousAfter(s, runs[run_count - 1].end, i))
            {
                runs[run_count - 1].end = @intCast(i + 1);
            } else {
                runs[run_count] = .{ .start = @intCast(i), .end = @intCast(i + 1), .level = s.levels[i], .used = false };
                run_count += 1;
            }
        }
    }

    var seq_count: usize = 0;
    var fill: usize = 0;
    for (0..run_count) |first| {
        if (runs[first].used) continue;
        // A run starting with a matched PDI continues its initiator's
        // sequence; it is picked up by the chain walk below.
        const first_cp = firstCodepoint(s, runs[first]);
        if (s.classes[first_cp] == .PDI and matchingInitiator(matches, first_cp) != null) continue;
        if (seq_count == max_sequences) break;

        const seq_start = fill;
        const level = runs[first].level;
        var last_run = first;
        var r = first;
        while (true) {
            runs[r].used = true;
            last_run = r;
            var i = runs[r].start;
            while (i < runs[r].end) : (i += 1) {
                if (s.levels[i] == removed_level) continue;
                s.seq_indices[fill] = i;
                fill += 1;
            }
            // Chain: run ends with a matched isolate initiator → the run
            // beginning at its PDI continues the sequence.
            const last_cp = lastCodepoint(s, runs[r]);
            if (!isIsolateInitiator(s.classes[last_cp])) break;
            const pdi = matchingPdi(matches, last_cp) orelse break;
            var found: ?usize = null;
            for (0..run_count) |cand| {
                if (!runs[cand].used and firstCodepoint(s, runs[cand]) == pdi) {
                    found = cand;
                    break;
                }
            }
            r = found orelse break;
        }

        // sos: the higher of the sequence level and the level before it;
        // eos symmetrical, with the paragraph level standing in at the
        // edges and after an unmatched isolate initiator.
        const before = prevLevel(s, runs[first].start, para_level);
        const last_cp = lastCodepoint(s, runs[last_run]);
        const ends_open = isIsolateInitiator(s.classes[last_cp]) and
            matchingPdi(matches, last_cp) == null;
        const after = if (ends_open) para_level else nextLevel(s, runs[last_run].end, n, para_level);
        out[seq_count] = .{
            .start = @intCast(seq_start),
            .len = @intCast(fill - seq_start),
            .level = level,
            .sos = if (@max(level, before) & 1 == 1) .rtl else .ltr,
            .eos = if (@max(level, after) & 1 == 1) .rtl else .ltr,
        };
        seq_count += 1;
    }
    return seq_count;
}

fn contiguousAfter(s: *const Scratch, end: usize, i: usize) bool {
    var j = end;
    while (j < i) : (j += 1) {
        if (s.levels[j] != removed_level) return false;
    }
    return true;
}

fn firstCodepoint(s: *const Scratch, run: anytype) usize {
    var i: usize = run.start;
    while (s.levels[i] == removed_level) i += 1;
    return i;
}

fn lastCodepoint(s: *const Scratch, run: anytype) usize {
    var i: usize = run.end - 1;
    while (s.levels[i] == removed_level) i -= 1;
    return i;
}

fn prevLevel(s: *const Scratch, start: usize, para_level: u8) u8 {
    var i = start;
    while (i > 0) {
        i -= 1;
        if (s.levels[i] != removed_level) return s.levels[i];
    }
    return para_level;
}

fn nextLevel(s: *const Scratch, end: usize, n: usize, para_level: u8) u8 {
    var i = end;
    while (i < n) : (i += 1) {
        if (s.levels[i] != removed_level) return s.levels[i];
    }
    return para_level;
}

/// Rules W1–W7 over one isolating run sequence.
fn resolveWeak(s: *Scratch, idx: []const u16, seq: Sequence) void {
    const sos_class: Class = if (seq.sos == .rtl) .R else .L;

    // W1: NSM takes the class before it; after an isolate boundary, ON.
    var prev: Class = sos_class;
    for (idx) |i| {
        const c = s.classes[i];
        if (c == .NSM) {
            s.classes[i] = if (isIsolateInitiator(prev) or prev == .PDI) .ON else prev;
        }
        prev = s.classes[i];
    }

    // W2: EN with a preceding strong AL becomes AN.
    var strong: Class = sos_class;
    for (idx) |i| {
        switch (s.classes[i]) {
            .L, .R, .AL => strong = s.classes[i],
            .EN => if (strong == .AL) {
                s.classes[i] = .AN;
            },
            else => {},
        }
    }

    // W3: AL becomes R.
    for (idx) |i| {
        if (s.classes[i] == .AL) s.classes[i] = .R;
    }

    // W4: a single ES between EN becomes EN; a single CS between a
    // matching number pair becomes that number class.
    for (idx, 0..) |i, k| {
        const c = s.classes[i];
        if (k == 0 or k + 1 == idx.len) continue;
        const before = s.classes[idx[k - 1]];
        const after = s.classes[idx[k + 1]];
        if (c == .ES and before == .EN and after == .EN) {
            s.classes[i] = .EN;
        } else if (c == .CS and before == after and (before == .EN or before == .AN)) {
            s.classes[i] = before;
        }
    }

    // W5: a run of ET adjacent to EN becomes EN.
    var k: usize = 0;
    while (k < idx.len) : (k += 1) {
        if (s.classes[idx[k]] != .ET) continue;
        var end = k;
        while (end < idx.len and s.classes[idx[end]] == .ET) end += 1;
        const before: Class = if (k > 0) s.classes[idx[k - 1]] else sos_class;
        const after: Class = if (end < idx.len) s.classes[idx[end]] else .ON;
        if (before == .EN or after == .EN) {
            for (idx[k..end]) |i| s.classes[i] = .EN;
        }
        k = end - 1;
    }

    // W6: leftover separators and terminators become ON.
    for (idx) |i| {
        switch (s.classes[i]) {
            .ES, .ET, .CS => s.classes[i] = .ON,
            else => {},
        }
    }

    // W7: EN with a preceding strong L becomes L.
    strong = sos_class;
    for (idx) |i| {
        switch (s.classes[i]) {
            .L, .R => strong = s.classes[i],
            .EN => if (strong == .L) {
                s.classes[i] = .L;
            },
            else => {},
        }
    }
}

/// N0: paired brackets (BD16). A bracket pair takes the embedding
/// direction when it encloses a strong character of that direction,
/// or the opposite direction when it encloses only opposite-strong
/// characters and the context before it is also opposite.
fn resolveBrackets(s: *Scratch, bytes: []const u8, idx: []const u16, seq: Sequence) void {
    const embedding: Class = if (seq.level & 1 == 1) .R else .L;
    const opposite: Class = if (embedding == .R) .L else .R;

    const Pair = struct { open: usize, close: usize }; // positions in idx
    var pairs: [63]Pair = undefined;
    var pair_count: usize = 0;
    var stack: [63]struct { cp: u21, pos: usize } = undefined;
    var depth: usize = 0;

    scan: for (idx, 0..) |i, k| {
        if (s.classes[i] != .ON) continue;
        const cp = codepointAt(s, bytes, i);
        const b = bracketOf(cp) orelse continue;
        if (b.open) {
            if (depth == 63) break; // BD16: stop when the stack is full
            stack[depth] = .{ .cp = canonicalBracket(@intCast(b.pair)), .pos = k };
            depth += 1;
        } else {
            const canon = canonicalBracket(cp);
            var d = depth;
            while (d > 0) {
                d -= 1;
                if (stack[d].cp == canon) {
                    // BD16: stop when the pair list is full. Sequential
                    // pairs `()()...` fill it without ever deepening the
                    // stack, so the guard above does not imply this one.
                    if (pair_count == pairs.len) break :scan;
                    pairs[pair_count] = .{ .open = stack[d].pos, .close = k };
                    pair_count += 1;
                    depth = d;
                    break;
                }
            }
        }
    }

    // Sort by opening position (insertion sort; the list is tiny).
    if (pair_count == 0) return;
    for (1..pair_count) |a| {
        const p = pairs[a];
        var b = a;
        while (b > 0 and pairs[b - 1].open > p.open) : (b -= 1) {
            pairs[b] = pairs[b - 1];
        }
        pairs[b] = p;
    }

    for (pairs[0..pair_count]) |pair| {
        var has_embedding = false;
        var has_opposite = false;
        for (idx[pair.open + 1 .. pair.close]) |i| {
            const c = strongClass(s.classes[i]) orelse continue;
            if (c == embedding) has_embedding = true else has_opposite = true;
        }
        var set: ?Class = null;
        if (has_embedding) {
            set = embedding;
        } else if (has_opposite) {
            // Context before the opening bracket: the previous strong
            // class in the sequence, or sos.
            var context: Class = if (seq.sos == .rtl) .R else .L;
            var k = pair.open;
            while (k > 0) {
                k -= 1;
                if (strongClass(s.classes[idx[k]])) |c| {
                    context = c;
                    break;
                }
            }
            set = if (context == opposite) opposite else embedding;
        }
        if (set) |c| {
            s.classes[idx[pair.open]] = c;
            s.classes[idx[pair.close]] = c;
            // Combining marks on a resolved bracket follow it.
            trailNsm(s, bytes, idx, pair.open, c);
            trailNsm(s, bytes, idx, pair.close, c);
        }
    }
}

/// After N0 changes a bracket, any NSM-originated characters directly
/// following it change with it (the W1 rewrite is re-based).
fn trailNsm(s: *Scratch, bytes: []const u8, idx: []const u16, pos: usize, c: Class) void {
    var k = pos + 1;
    while (k < idx.len) : (k += 1) {
        const i = idx[k];
        if (classOf(codepointAt(s, bytes, i)) != .NSM) break;
        s.classes[i] = c;
    }
}

fn strongClass(c: Class) ?Class {
    return switch (c) {
        .L => .L,
        .R, .EN, .AN => .R, // N rules: numbers count as R
        else => null,
    };
}

fn codepointAt(s: *const Scratch, bytes: []const u8, i: usize) u21 {
    var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = s.offsets[i] };
    return it.nextCodepoint().?;
}

fn bracketOf(cp: u21) ?tables.BracketPair {
    const pairs = &tables.bracket_pairs;
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < pairs[mid].cp) {
            hi = mid;
        } else if (cp > pairs[mid].cp) {
            lo = mid + 1;
        } else {
            return pairs[mid];
        }
    }
    return null;
}

/// BD16's canonical-equivalence carve-out: U+3008/3009 match U+2329/232A.
fn canonicalBracket(cp: u21) u21 {
    return switch (cp) {
        0x3008 => 0x2329,
        0x3009 => 0x232A,
        else => cp,
    };
}

/// N1–N2: neutrals between matching strong directions take that
/// direction; the rest take the embedding direction.
fn resolveNeutral(s: *Scratch, idx: []const u16, seq: Sequence) void {
    const embedding: Class = if (seq.level & 1 == 1) .R else .L;
    var k: usize = 0;
    while (k < idx.len) : (k += 1) {
        if (!isNeutralOrIsolate(s.classes[idx[k]])) continue;
        var end = k;
        while (end < idx.len and isNeutralOrIsolate(s.classes[idx[end]])) end += 1;
        var before: Class = if (seq.sos == .rtl) .R else .L;
        if (k > 0) before = strongClass(s.classes[idx[k - 1]]) orelse embedding;
        var after: Class = if (seq.eos == .rtl) .R else .L;
        if (end < idx.len) after = strongClass(s.classes[idx[end]]) orelse embedding;
        const c: Class = if (before == after) before else embedding;
        for (idx[k..end]) |i| s.classes[i] = c;
        k = end;
    }
}

/// I1–I2: strong and numeric classes bump their run's level.
fn resolveImplicit(s: *Scratch, idx: []const u16) void {
    for (idx) |i| {
        const level = s.levels[i];
        if (level & 1 == 0) {
            switch (s.classes[i]) {
                .R => s.levels[i] = level + 1,
                .AN, .EN => s.levels[i] = level + 2,
                else => {},
            }
        } else {
            switch (s.classes[i]) {
                .L, .AN, .EN => s.levels[i] = level + 1,
                else => {},
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Line rules: L1 (trailing resets) and L2 (visual reordering).
// ---------------------------------------------------------------------------

/// One visual run of a line: a byte range of the paragraph, drawn
/// left-to-right at increasing x, its innards shaped RTL when the level
/// is odd.
pub const Run = struct {
    start: u32,
    end: u32,
    level: u8,

    pub fn rtl(self: Run) bool {
        return self.level & 1 == 1;
    }
};

/// Visual-order runs for the line bytes[line_start..line_end). Both
/// bounds must fall on codepoint boundaries (wrap lines and span
/// segments always do). `out` bounds the run count; lines that alternate
/// direction more times than it holds merge their tail into the final
/// run — deterministically, and far past anything a screen shows.
pub fn lineRuns(p: *const Paragraph, line_start: usize, line_end: usize, out: []Run) []Run {
    if (line_start >= line_end or out.len == 0) return out[0..0];
    if (p.degraded or p.levels.len == 0) {
        out[0] = .{
            .start = @intCast(line_start),
            .end = @intCast(line_end),
            .level = p.level,
        };
        return out[0..1];
    }

    const first = cpIndexOf(p, line_start);
    const last = cpIndexOf(p, line_end);
    // line_end may equal the paragraph end sentinel.
    std.debug.assert(p.offsets[first] == line_start);
    std.debug.assert(p.offsets[last] == line_end);

    // L1: segment and paragraph separators, plus any whitespace or
    // isolate formatting run before one of them or at the line's end,
    // reset to the paragraph level — an RTL line's trailing space sits
    // at the margin, not mid-line. Marked in a bitset, walking the line
    // backwards; classes come from the bytes (the working classes were
    // consumed by the W/N rules).
    var reset = std.bit_set.ArrayBitSet(usize, max_paragraph).initEmpty();
    {
        var resettable = true; // at line end, or only WS/isolates behind us
        var i = last;
        while (i > first) {
            i -= 1;
            const c = classOf(cpAt(p, i));
            if (c == .B or c == .S) {
                reset.set(i - first);
                resettable = true;
            } else if (resettable and
                (c == .WS or c == .BN or isIsolateInitiator(c) or c == .PDI))
            {
                reset.set(i - first);
            } else {
                resettable = false;
            }
        }
    }
    const levelOf = struct {
        fn get(para: *const Paragraph, bits: anytype, base: usize, i: usize) u8 {
            return if (bits.isSet(i - base)) para.level else para.levels[i];
        }
    }.get;

    // Maximal same-level runs, in logical order. Lines that alternate
    // beyond out.len merge their tail into the final run.
    var count: usize = 0;
    var i = first;
    while (i < last) {
        const level = levelOf(p, &reset, first, i);
        var j = i + 1;
        while (j < last and levelOf(p, &reset, first, j) == level) j += 1;
        if (count == out.len) {
            out[count - 1].end = p.offsets[last];
            out[count - 1].level = p.level;
            break;
        }
        out[count] = .{
            .start = p.offsets[i],
            .end = p.offsets[j],
            .level = level,
        };
        count += 1;
        i = j;
    }

    // L2: from the highest level down to the lowest odd level, reverse
    // every maximal contiguous stretch of runs at or above it.
    var max_level: u8 = 0;
    var min_odd: u8 = max_depth + 1;
    for (out[0..count]) |r| {
        max_level = @max(max_level, r.level);
        if (r.level & 1 == 1) min_odd = @min(min_odd, r.level);
    }
    if (min_odd <= max_level) {
        var lvl = max_level;
        while (lvl >= min_odd) : (lvl -= 1) {
            var a: usize = 0;
            while (a < count) {
                if (out[a].level < lvl) {
                    a += 1;
                    continue;
                }
                var b = a;
                while (b < count and out[b].level >= lvl) b += 1;
                std.mem.reverse(Run, out[a..b]);
                a = b;
            }
        }
    }
    return out[0..count];
}

/// Fixed budgets for one line's decomposition; beyond them the tail
/// merges into the final piece — deterministic, and far past what a
/// rendered line of UI text alternates.
pub const max_line_runs = 64;
pub const max_line_edges = 96;

/// One draw piece: a byte range (paragraph-relative) that is a single
/// face and a single direction. Pieces come out in visual order, left
/// to right; consumers draw each and advance a pen by its measured
/// width.
pub const Piece = struct { start: u32, end: u32, rtl: bool };

/// Decomposes one line into visual-order pieces: the L1/L2 level runs
/// intersected with the line's measure-run boundaries (whole-line
/// context — the segmentation `Measurer.measure` sums, so pen extents
/// equal measured widths by construction). Within an RTL run the
/// logically-later pieces sit further left, so they come out back to
/// front.
pub fn linePieces(p: *const Paragraph, line_start: usize, line_end: usize, runs_buf: *[max_line_runs]Run, edges_buf: *[max_line_edges]u32) PieceIterator {
    const runs = lineRuns(p, line_start, line_end, runs_buf);
    var edge_count: usize = 0;
    var it = measureRuns(p.bytes[line_start..line_end]);
    while (it.next()) |run| {
        if (edge_count == max_line_edges) break;
        const off = @intFromPtr(run.bytes.ptr) - @intFromPtr(p.bytes.ptr);
        edges_buf[edge_count] = @intCast(off);
        edge_count += 1;
    }
    return .{ .runs = runs, .edges = edges_buf[0..edge_count] };
}

pub const PieceIterator = struct {
    runs: []const Run,
    edges: []const u32,
    run_i: usize = 0,
    cuts: [max_line_edges + 2]u32 = undefined,
    cut_count: usize = 0,
    piece_i: usize = 0,

    pub fn next(self: *PieceIterator) ?Piece {
        while (true) {
            if (self.cut_count == 0) {
                if (self.run_i == self.runs.len) return null;
                const run = self.runs[self.run_i];
                var n: usize = 0;
                self.cuts[n] = run.start;
                n += 1;
                for (self.edges) |e| {
                    if (e > run.start and e < run.end) {
                        self.cuts[n] = e;
                        n += 1;
                    }
                }
                self.cuts[n] = run.end;
                self.cut_count = n;
                self.piece_i = 0;
            }
            const run = self.runs[self.run_i];
            if (self.piece_i == self.cut_count) {
                self.run_i += 1;
                self.cut_count = 0;
                continue;
            }
            const idx = if (run.rtl()) self.cut_count - 1 - self.piece_i else self.piece_i;
            self.piece_i += 1;
            return .{ .start = self.cuts[idx], .end = self.cuts[idx + 1], .rtl = run.rtl() };
        }
    }
};

fn cpAt(p: *const Paragraph, i: usize) u21 {
    var it = std.unicode.Utf8Iterator{ .bytes = p.bytes, .i = p.offsets[i] };
    return it.nextCodepoint().?;
}

/// Codepoint index of a byte offset (binary search over offsets).
fn cpIndexOf(p: *const Paragraph, byte_offset: usize) usize {
    const offsets = p.offsets;
    var lo: usize = 0;
    var hi: usize = offsets.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (offsets[mid] < byte_offset) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

test "N0: sequential bracket pairs past the pair budget resolve without panic" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);
    // One Arabic letter makes the paragraph RTL, then 70 sequential
    // `()` pairs — more pairs than the BD16 list holds, at depth one,
    // so only the pair-list guard stands between this and the write.
    const text = "س" ++ "()" ** 70;
    const para = resolve(scratch, text, paragraphDirection(text));
    try std.testing.expect(!para.degraded);
    try std.testing.expectEqual(Direction.rtl, para.direction());
}
