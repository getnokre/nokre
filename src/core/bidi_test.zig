//! Tests for core/bidi.zig: targeted cases for each consumer-facing
//! surface, plus a checked-in subset of the UCD BidiCharacterTest (see
//! bidi_character_test_data.txt for how to run the full 91,707-case
//! suite; it passes in full as of UCD 16.0.0).

const std = @import("std");
const bidi = @import("bidi.zig");

// The kitchen sink's Persian greeting: Arabic script, a ZWNJ (in
// می‌آید), an all-Latin acronym, and Latin punctuation.
const greeting = "سلام! این بند از یک کاتالوگ ARB می‌آید که در خود باینری کامپایل شده است.";

test "classOf spot checks" {
    try std.testing.expectEqual(bidi.Class.L, bidi.classOf('A'));
    try std.testing.expectEqual(bidi.Class.EN, bidi.classOf('7'));
    try std.testing.expectEqual(bidi.Class.AL, bidi.classOf(0x0633)); // س
    try std.testing.expectEqual(bidi.Class.AN, bidi.classOf(0x0661)); // ١ Arabic-Indic
    try std.testing.expectEqual(bidi.Class.EN, bidi.classOf(0x06F1)); // ۱ Persian (extended)
    try std.testing.expectEqual(bidi.Class.R, bidi.classOf(0x05D0)); // א
    try std.testing.expectEqual(bidi.Class.NSM, bidi.classOf(0x064B)); // fathatan
    try std.testing.expectEqual(bidi.Class.BN, bidi.classOf(0x200C)); // ZWNJ
    try std.testing.expectEqual(bidi.Class.WS, bidi.classOf(' '));
    try std.testing.expectEqual(bidi.Class.ON, bidi.classOf('('));
    try std.testing.expectEqual(bidi.Class.B, bidi.classOf('\n'));
}

test "paragraph direction derives from the first strong character" {
    try std.testing.expectEqual(bidi.Direction.rtl, bidi.paragraphDirection(greeting));
    try std.testing.expectEqual(bidi.Direction.ltr, bidi.paragraphDirection("hello دنیا"));
    // Leading weak characters don't decide: digits and punctuation
    // before the first strong Arabic letter still yield RTL.
    try std.testing.expectEqual(bidi.Direction.rtl, bidi.paragraphDirection("12 (سلام)"));
    // No strong character at all defaults to LTR.
    try std.testing.expectEqual(bidi.Direction.ltr, bidi.paragraphDirection("123 — 456"));
    try std.testing.expectEqual(bidi.Direction.ltr, bidi.paragraphDirection(""));
}

test "hasRtl gates the fast path" {
    try std.testing.expect(bidi.hasRtl(greeting));
    try std.testing.expect(!bidi.hasRtl("plain latin, 123."));
    try std.testing.expect(!bidi.hasRtl(""));
}

test "measure runs: pure latin is one base run" {
    var it = bidi.measureRuns("hello, world 123");
    const run = it.next().?;
    try std.testing.expectEqualStrings("hello, world 123", run.bytes);
    try std.testing.expectEqual(bidi.RunKind.base, run.kind);
    try std.testing.expectEqual(@as(?bidi.MeasureRun, null), it.next());
}

test "measure runs: face changes split, neutrals stay behind" {
    // "سلام ABC" — the space after the Arabic word extends the Arabic
    // run (it is drawn from the companion face there), ABC anchors base.
    var it = bidi.measureRuns("سلام ABC");
    const first = it.next().?;
    try std.testing.expectEqual(bidi.RunKind.arabic, first.kind);
    try std.testing.expectEqualStrings("سلام ", first.bytes);
    const second = it.next().?;
    try std.testing.expectEqual(bidi.RunKind.base, second.kind);
    try std.testing.expectEqualStrings("ABC", second.bytes);
    try std.testing.expectEqual(@as(?bidi.MeasureRun, null), it.next());
}

test "measure runs: ZWNJ stays inside its Arabic run" {
    var it = bidi.measureRuns("می‌آید");
    const run = it.next().?;
    try std.testing.expectEqual(bidi.RunKind.arabic, run.kind);
    try std.testing.expectEqualStrings("می‌آید", run.bytes);
    try std.testing.expectEqual(@as(?bidi.MeasureRun, null), it.next());
}

test "measure runs: digits split only in RTL text" {
    // With RTL present, digits take their own run (their own level).
    var it = bidi.measureRuns("سال 1404 بود");
    try std.testing.expectEqual(bidi.RunKind.arabic, it.next().?.kind);
    const digits = it.next().?;
    try std.testing.expectEqual(bidi.RunKind.number, digits.kind);
    try std.testing.expectEqualStrings("1404", std.mem.trim(u8, digits.bytes, " "));
    try std.testing.expectEqual(bidi.RunKind.arabic, it.next().?.kind);
    try std.testing.expectEqual(@as(?bidi.MeasureRun, null), it.next());
    // Without RTL, digits ride with the base run — no reordering, no
    // reason to forfeit kerning around them.
    var lt = bidi.measureRuns("year 1404 was");
    try std.testing.expectEqualStrings("year 1404 was", lt.next().?.bytes);
}

test "resolve + lineRuns: the Persian greeting reorders around ARB" {
    const scratch = try std.testing.allocator.create(bidi.Scratch);
    defer std.testing.allocator.destroy(scratch);

    const para = bidi.resolve(scratch, greeting, bidi.paragraphDirection(greeting));
    try std.testing.expect(!para.degraded);
    try std.testing.expectEqual(@as(u8, 1), para.level);

    var buf: [16]bidi.Run = undefined;
    const runs = bidi.lineRuns(&para, 0, greeting.len, &buf);
    // Visual order (left to right): trailing Arabic text, "ARB", leading
    // Arabic text — three runs, RTL / LTR / RTL.
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try std.testing.expect(runs[0].rtl());
    try std.testing.expect(!runs[1].rtl());
    try std.testing.expect(runs[2].rtl());
    // The LTR run is exactly the acronym; the RTL runs cover the rest.
    const arb = std.mem.indexOf(u8, greeting, "ARB").?;
    try std.testing.expectEqual(arb, runs[1].start);
    try std.testing.expectEqual(arb + 3, runs[1].end);
    try std.testing.expectEqual(arb + 3, runs[0].start);
    try std.testing.expectEqual(greeting.len, runs[0].end);
    try std.testing.expectEqual(@as(u32, 0), runs[2].start);
    try std.testing.expectEqual(arb, runs[2].end);
}

test "lineRuns: line-level reordering differs from paragraph-level" {
    const scratch = try std.testing.allocator.create(bidi.Scratch);
    defer std.testing.allocator.destroy(scratch);

    // A wrap may split between the Arabic text and the acronym; each
    // line reorders independently, and the trailing space before the
    // break resets to the paragraph level (L1).
    const text = "کتاب good بود";
    const para = bidi.resolve(scratch, text, .rtl);
    const break_at = std.mem.indexOf(u8, text, "good").?;
    var buf: [8]bidi.Run = undefined;
    const first_line = bidi.lineRuns(&para, 0, break_at, &buf);
    try std.testing.expectEqual(@as(usize, 1), first_line.len);
    try std.testing.expect(first_line[0].rtl());
    const second_line = bidi.lineRuns(&para, break_at, text.len, &buf);
    try std.testing.expectEqual(@as(usize, 2), second_line.len);
    try std.testing.expect(second_line[0].rtl()); // بود drawn leftmost
    try std.testing.expect(!second_line[1].rtl()); // good drawn rightmost
}

test "degraded paragraphs stay deterministic" {
    const scratch = try std.testing.allocator.create(bidi.Scratch);
    defer std.testing.allocator.destroy(scratch);

    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, (bidi.max_paragraph + 1) * 2);
    defer alloc.free(big);
    // Alternating Arabic letters, two bytes each — one over the budget.
    var i: usize = 0;
    while (i < big.len) : (i += 2) {
        big[i] = 0xD8;
        big[i + 1] = 0xB3; // س
    }
    const para = bidi.resolve(scratch, big, .rtl);
    try std.testing.expect(para.degraded);
    var buf: [4]bidi.Run = undefined;
    const runs = bidi.lineRuns(&para, 0, big.len, &buf);
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expect(runs[0].rtl());
    try std.testing.expectEqual(@as(u32, 0), runs[0].start);
    try std.testing.expectEqual(big.len, runs[0].end);
}

// ---------------------------------------------------------------------------
// UCD BidiCharacterTest subset.
// ---------------------------------------------------------------------------

const ucd_data = @embedFile("bidi_character_test_data.txt");

fn isRemovedClass(c: bidi.Class) bool {
    return switch (c) {
        .RLE, .LRE, .RLO, .LRO, .PDF, .BN => true,
        else => false,
    };
}

// L1 resets these; their levels are validated through the visual-order
// check instead (lineRuns applies L1 internally).
fn l1Sensitive(c: bidi.Class) bool {
    return switch (c) {
        .WS, .S, .B, .LRI, .RLI, .FSI, .PDI => true,
        else => false,
    };
}

test "UCD BidiCharacterTest subset" {
    const scratch = try std.testing.allocator.create(bidi.Scratch);
    defer std.testing.allocator.destroy(scratch);

    var failures: usize = 0;
    var lines = std.mem.splitScalar(u8, ucd_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const f_cps = fields.next().?;
        const f_dir = fields.next().?;
        _ = fields.next().?; // paragraph level (implied by direction)
        const f_levels = fields.next().?;
        const f_order = std.mem.trimEnd(u8, fields.next().?, "\r");

        var bytes_buf: [2048]u8 = undefined;
        var bytes_len: usize = 0;
        var cps: [512]u21 = undefined;
        var n: usize = 0;
        var cp_it = std.mem.tokenizeScalar(u8, f_cps, ' ');
        while (cp_it.next()) |h| {
            const cp = try std.fmt.parseInt(u21, h, 16);
            cps[n] = cp;
            n += 1;
            bytes_len += try std.unicode.utf8Encode(cp, bytes_buf[bytes_len..]);
        }
        const bytes = bytes_buf[0..bytes_len];

        const dir: bidi.Direction = switch (f_dir[0]) {
            '0' => .ltr,
            '1' => .rtl,
            '2' => bidi.paragraphDirection(bytes),
            else => unreachable,
        };

        const para = bidi.resolve(scratch, bytes, dir);
        try std.testing.expect(!para.degraded);

        var ok = true;

        var lev_it = std.mem.tokenizeScalar(u8, f_levels, ' ');
        var i: usize = 0;
        while (lev_it.next()) |tok| : (i += 1) {
            if (tok[0] == 'x') continue;
            const expect = try std.fmt.parseInt(u8, tok, 10);
            if (l1Sensitive(bidi.classOf(cps[i]))) continue;
            if (para.levels[i] != expect) ok = false;
        }

        var runs_buf: [512]bidi.Run = undefined;
        const runs = bidi.lineRuns(&para, 0, bytes.len, &runs_buf);
        var got_order: [512]usize = undefined;
        var got_n: usize = 0;
        for (runs) |r| {
            var first: usize = 0;
            while (para.offsets[first] != r.start) first += 1;
            var last = first;
            while (para.offsets[last] != r.end) last += 1;
            if (r.rtl()) {
                var k = last;
                while (k > first) {
                    k -= 1;
                    if (!isRemovedClass(bidi.classOf(cps[k]))) {
                        got_order[got_n] = k;
                        got_n += 1;
                    }
                }
            } else {
                for (first..last) |k| {
                    if (!isRemovedClass(bidi.classOf(cps[k]))) {
                        got_order[got_n] = k;
                        got_n += 1;
                    }
                }
            }
        }
        var want_order: [512]usize = undefined;
        var want_n: usize = 0;
        var ord_it = std.mem.tokenizeScalar(u8, f_order, ' ');
        while (ord_it.next()) |tok| {
            want_order[want_n] = try std.fmt.parseInt(usize, tok, 10);
            want_n += 1;
        }
        if (got_n != want_n or !std.mem.eql(usize, got_order[0..got_n], want_order[0..want_n])) {
            ok = false;
        }

        if (!ok) {
            failures += 1;
            if (failures <= 5) std.debug.print("bidi case failed: {s}\n", .{line});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
