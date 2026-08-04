//! Tests for wrap.zig: greedy word wrap, span segmentation, and middle
//! elision.

const std = @import("std");
const element = @import("element.zig");
const text = @import("text.zig");
const wrap = @import("wrap.zig");

const testing = std.testing;

fn collectLines(content: []const u8, max_w: i32, out: [][]const u8) usize {
    var it = wrap.wrap(text.Measurer.fixed, .prose, 10, content, max_w);
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) out[n] = line;
    return n;
}

// Fixed measurer at size 10 → every codepoint is 6px wide.

test "wrap: fits on one line" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("hello world", 100, &lines);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("hello world", lines[0]);
}

test "wrap: breaks at word boundary" {
    var lines: [8][]const u8 = undefined;
    // 60px = 10 chars. "hello world" = 11 chars.
    const n = collectLines("hello world", 60, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("hello", lines[0]);
    try testing.expectEqualStrings("world", lines[1]);
}

test "wrap: hard newline" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("a\nb", 600, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("b", lines[1]);
}

test "wrap: trailing newline yields an empty final line" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("a\n", 600, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("", lines[1]);
    // A trailing space is hanging whitespace, not a new line.
    try testing.expectEqual(@as(usize, 1), collectLines("a ", 600, &lines));
}

test "wrap: over-long word overflows without splitting" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("abcdefghijkl x", 30, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("abcdefghijkl", lines[0]);
    try testing.expectEqualStrings("x", lines[1]);
}

test "wrap: empty content yields one empty line" {
    var lines: [8][]const u8 = undefined;
    const n = collectLines("", 100, &lines);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("", lines[0]);
}

// A measurer whose bold face is visibly wider (10px vs 6px per
// codepoint): wide enough apart to prove wrapping consults each span's
// face rather than the base one.
fn variantMeasure(_: ?*anyopaque, face: text.Face, _: i32, bytes: []const u8) i32 {
    var n: i32 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (it.nextCodepoint()) |_| n += 1;
    return n * @as(i32, if (face.bold) 10 else 6);
}
const variant_measurer: text.Measurer = .{ .measureFn = variantMeasure };

test "spans: segments split a byte range at span boundaries" {
    const content = "abcdef";
    const spans = [_]element.Span{
        .{ .text = content[0..3] },
        .{ .text = content[3..], .strong = true },
    };
    var it = wrap.segments(content, &spans, 1, 5);
    const first = it.next().?;
    try testing.expectEqualStrings("bc", first.bytes);
    try testing.expect(!first.span.strong);
    const second = it.next().?;
    try testing.expectEqualStrings("de", second.bytes);
    try testing.expect(second.span.strong);
    try testing.expect(it.next() == null);
}

test "spans: wrap breaks with each span's face widths" {
    const content = "aaa bbb";
    const spans = [_]element.Span{
        .{ .text = content[0..4] },
        .{ .text = content[4..], .strong = true },
    };
    // Regular widths alone would fit the line — prove the premise first.
    var plain = wrap.wrap(variant_measurer, .prose, 10, content, 45);
    try testing.expectEqualStrings("aaa bbb", plain.next().?);
    // The bold run's real width forces the break.
    var it = wrap.wrapSpans(variant_measurer, .prose, 10, content, &spans, 45);
    try testing.expectEqualStrings("aaa", it.next().?);
    try testing.expectEqualStrings("bbb", it.next().?);
    try testing.expect(it.next() == null);
}

test "spans: a word crossing a span boundary stays unbreakable" {
    const content = "aabb cc";
    const spans = [_]element.Span{
        .{ .text = content[0..2] },
        .{ .text = content[2..], .strong = true },
    };
    // "aabb" (12 + 20 = 32px) exceeds 20px: it overflows whole, never
    // splitting at the style boundary inside it.
    var it = wrap.wrapSpans(variant_measurer, .prose, 10, content, &spans, 20);
    try testing.expectEqualStrings("aabb", it.next().?);
    try testing.expectEqualStrings("cc", it.next().?);
    try testing.expect(it.next() == null);
}

test "spans: spanTextWidth sums per-face widths" {
    const content = "aabb";
    const spans = [_]element.Span{
        .{ .text = content[0..2] },
        .{ .text = content[2..], .strong = true },
    };
    try testing.expectEqual(@as(i32, 32), wrap.spanTextWidth(variant_measurer, .prose, 10, &spans));
}

// elideMiddle under Measurer.fixed at size 10: every codepoint (the
// ellipsis included) is 6px wide, so max_w budgets are exact codepoint
// counts.

test "elideMiddle returns null when the value fits" {
    try testing.expectEqual(@as(?wrap.Elision, null), wrap.elideMiddle(text.Measurer.fixed, .mono, 10, "abcdefghij", 60));
}

test "elideMiddle keeps both ends and drops the middle" {
    // 10 codepoints in 30px: ellipsis (6) + 4 codepoints (24) fit,
    // split evenly.
    const e = wrap.elideMiddle(text.Measurer.fixed, .mono, 10, "abcdefghij", 30).?;
    try testing.expectEqual(@as(usize, 2), e.head_end);
    try testing.expectEqual(@as(usize, 8), e.tail_start);
}

test "elideMiddle gives an odd budget's extra codepoint to the head" {
    // 27px holds ellipsis + 3 codepoints: head 2, tail 1.
    const e = wrap.elideMiddle(text.Measurer.fixed, .mono, 10, "abcdefghij", 27).?;
    try testing.expectEqual(@as(usize, 2), e.head_end);
    try testing.expectEqual(@as(usize, 9), e.tail_start);
}

test "elideMiddle splits on codepoint boundaries" {
    // Five 2-byte codepoints in 24px: head 2, tail 1 — offsets land
    // between sequences, so both slices stay valid UTF-8.
    const value = "ééééé";
    const e = wrap.elideMiddle(text.Measurer.fixed, .mono, 10, value, 24).?;
    try testing.expectEqual(@as(usize, 4), e.head_end);
    try testing.expectEqual(@as(usize, 8), e.tail_start);
    try testing.expect(std.unicode.utf8ValidateSlice(value[0..e.head_end]));
    try testing.expect(std.unicode.utf8ValidateSlice(value[e.tail_start..]));
}

test "elideMiddle never reassembles the whole value around the marker" {
    // One codepoint over budget: eliding must still drop something —
    // head + tail stay short of the full value.
    const e = wrap.elideMiddle(text.Measurer.fixed, .mono, 10, "abcd", 18).?;
    try testing.expect(e.head_end < e.tail_start);
}
