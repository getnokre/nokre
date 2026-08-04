//! Line breaking for text that layout positions and the renderer
//! draws: greedy word wrap, span segmentation, bidi-aware line
//! decomposition, and middle elision. Pure functions of a measurer and
//! bytes — no tree, no rects-in-progress — split out of layout.zig so
//! the two consumers that must agree to the pixel (layout's heights,
//! the renderer's pens) read one small module. Integer math only, like
//! everything that produces coordinates.

const std = @import("std");
const bidi = @import("bidi.zig");
const geometry = @import("geometry.zig");
const text = @import("text.zig");
const element_mod = @import("element.zig");

const Rect = geometry.Rect;

/// Greedy word wrap. Splits on spaces, honors '\n' as a hard break, and
/// lets an unbreakable over-long word overflow rather than splitting it
/// mid-word. The renderer iterates the exact same lines as layout.
pub fn wrap(measurer: text.Measurer, face: text.Face, size_px: i32, content: []const u8, max_w: i32) WrapIterator {
    return wrapSpans(measurer, face, size_px, content, &.{}, max_w);
}

/// `wrap` over spanned text: the same lines, the same greedy rule, but
/// every candidate is measured run by run with each span's face — bold
/// is wider than regular, so breaking with the regular's widths would
/// desynchronize layout from what the renderer draws. Spans are ranges
/// over `content` (append guarantees it), so a word crossing a span
/// boundary is still one unbreakable word; only its measurement splits.
pub fn wrapSpans(measurer: text.Measurer, base: text.Face, size_px: i32, content: []const u8, spans: []const element_mod.Span, max_w: i32) WrapIterator {
    return .{
        .measurer = measurer,
        .face = base,
        .size_px = size_px,
        .max_w = max_w,
        .content = content,
        .spans = spans,
        .rest = content,
        .yielded_any = false,
    };
}

pub const WrapIterator = struct {
    measurer: text.Measurer,
    face: text.Face,
    size_px: i32,
    max_w: i32,
    /// The full text; lines and spans are slices of it, so byte offsets
    /// recovered from pointers are exact.
    content: []const u8,
    spans: []const element_mod.Span = &.{},
    rest: []const u8,
    yielded_any: bool,
    /// A swallowed final '\n' still owes one empty line — the caret in a
    /// text area must be able to land there.
    pending_line: bool = false,

    pub fn next(self: *WrapIterator) ?[]const u8 {
        if (self.rest.len == 0) {
            if (self.yielded_any and !self.pending_line) return null;
            self.yielded_any = true;
            self.pending_line = false;
            // Lines are always slices of `content` so callers can
            // recover byte offsets from pointers.
            return self.rest;
        }
        self.yielded_any = true;

        const hard_end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        const hard_line = self.rest[0..hard_end];

        if (self.measureText(hard_line) <= self.max_w) {
            self.advance(hard_end);
            return hard_line;
        }

        // Greedy: longest word-boundary prefix that fits.
        var fit_end: usize = 0;
        var search: usize = 0;
        while (search < hard_line.len) {
            const next_space = std.mem.indexOfScalarPos(u8, hard_line, search, ' ') orelse hard_line.len;
            if (self.measureText(hard_line[0..next_space]) <= self.max_w) {
                fit_end = next_space;
                search = next_space + 1;
            } else break;
        }
        if (fit_end == 0) {
            // First word alone exceeds max_w: emit it whole (overflow).
            fit_end = std.mem.indexOfScalar(u8, hard_line, ' ') orelse hard_line.len;
        }
        const line = hard_line[0..fit_end];
        self.advance(fit_end);
        return line;
    }

    fn measureText(self: *const WrapIterator, bytes: []const u8) i32 {
        if (self.spans.len == 0) return self.measurer.measure(self.face, self.size_px, bytes);
        const start = @intFromPtr(bytes.ptr) - @intFromPtr(self.content.ptr);
        var w: i32 = 0;
        var it = segments(self.content, self.spans, start, start + bytes.len);
        while (it.next()) |seg| {
            w += self.measurer.measure(seg.span.face(self.face), self.size_px, seg.bytes);
        }
        return w;
    }

    fn advance(self: *WrapIterator, consumed: usize) void {
        var i = consumed;
        var newline = false;
        // Swallow exactly one break character (space or newline).
        if (i < self.rest.len and (self.rest[i] == ' ' or self.rest[i] == '\n')) {
            newline = self.rest[i] == '\n';
            i += 1;
        }
        self.rest = self.rest[i..];
        self.pending_line = newline and self.rest.len == 0;
    }
};

/// One same-styled run within a byte range of spanned text.
pub const Segment = struct {
    bytes: []const u8,
    span: element_mod.Span,
    /// Which span this run came from. Link geometry needs the identity,
    /// not just the styling: two spans can be styled alike and route
    /// differently.
    index: usize,
};

/// Iterates the span runs intersecting `content[start..end)` — how a
/// wrapped line decomposes into draw calls. Layout's measurement and
/// the renderer's drawing both walk these exact segments, so advances
/// and widths agree by construction. Kerning across a span boundary is
/// forfeited on both sides equally: each segment is measured and drawn
/// alone, which is also what keeps the split deterministic.
pub fn segments(content: []const u8, spans: []const element_mod.Span, start: usize, end: usize) SegmentIterator {
    return .{ .content = content, .spans = spans, .pos = start, .end = end };
}

pub const SegmentIterator = struct {
    content: []const u8,
    spans: []const element_mod.Span,
    pos: usize,
    end: usize,

    pub fn next(self: *SegmentIterator) ?Segment {
        if (self.pos >= self.end) return null;
        var off: usize = 0;
        for (self.spans, 0..) |span, i| {
            const span_end = off + span.text.len;
            if (self.pos < span_end) {
                const seg_end = @min(self.end, span_end);
                const bytes = self.content[self.pos..seg_end];
                self.pos = seg_end;
                return .{ .bytes = bytes, .span = span, .index = i };
            }
            off = span_end;
        }
        return null;
    }
};

/// The paragraph a wrap line belongs to, resolved lazily as a caller
/// walks lines in order. Direction and levels are per hard paragraph —
/// the unit UAX #9 defines them on — so a Persian paragraph
/// right-aligns while its English neighbour in the same text element
/// keeps left.
pub const ParagraphCursor = struct {
    content: []const u8,
    start: usize = 0,
    end: usize = 0,
    rtl: bool = false,
    complex: bool = false,
    para: bidi.Paragraph = undefined,
    primed: bool = false,

    pub fn advanceTo(self: *ParagraphCursor, scratch: *bidi.Scratch, line_start: usize) void {
        while (!self.primed or (line_start > self.end and self.end < self.content.len)) {
            self.start = if (self.primed) self.end + 1 else 0;
            self.end = std.mem.indexOfScalarPos(u8, self.content, self.start, '\n') orelse self.content.len;
            self.primed = true;
            const bytes = self.content[self.start..self.end];
            self.complex = bidi.isComplex(bytes);
            const dir = bidi.paragraphDirection(bytes);
            self.rtl = dir == .rtl;
            if (self.complex) self.para = bidi.resolve(scratch, bytes, dir);
        }
    }
};

/// One drawn piece of a wrapped line of spanned text: the bytes, which
/// span they came from, and where the pen puts them. Everything that
/// must agree to the pixel reads this one walk — the renderer's
/// drawing, a link span's underline and focus rects, and hit testing —
/// so what is drawn is exactly what is underlined and hit.
pub const LinePiece = struct {
    bytes: []const u8,
    span_index: usize,
    x: i32,
    w: i32,
};

/// Budget for one line's decomposition; past it the tail is dropped,
/// the same deterministic truncation `bidi`'s own line budgets take,
/// and far past what a rendered line of UI text needs.
pub const max_line_pieces = 192;

/// Fills `out` with the drawn pieces of `content[line_start..line_end)`
/// in draw order, pen starting at `origin_x`. `para` is the line's
/// resolved paragraph when the text is complex (Arabic script or strong
/// RTL present) and null when it is not; `para_start` is that
/// paragraph's byte offset in `content`.
pub fn linePieces(
    measurer: text.Measurer,
    base: text.Face,
    size_px: i32,
    content: []const u8,
    spans: []const element_mod.Span,
    line_start: usize,
    line_end: usize,
    origin_x: i32,
    para: ?*const bidi.Paragraph,
    para_start: usize,
    out: []LinePiece,
) []LinePiece {
    var n: usize = 0;
    var pen = origin_x;

    const p = para orelse {
        var it = segments(content, spans, line_start, line_end);
        while (it.next()) |seg| {
            if (n == out.len) break;
            const w = measurer.measure(seg.span.face(base), size_px, seg.bytes);
            out[n] = .{ .bytes = seg.bytes, .span_index = seg.index, .x = pen, .w = w };
            n += 1;
            pen += w;
        }
        return out[0..n];
    };

    // Complex: level runs in visual order, each run's segments in run
    // order, each segment's own measure runs inside that. Segment
    // context (not whole-line) is deliberate — `wrapSpans` measured
    // each segment alone, so the pen must be built the same way or the
    // line drifts from the width the wrap decided.
    var runs_buf: [bidi.max_line_runs]bidi.Run = undefined;
    const runs = bidi.lineRuns(p, line_start - para_start, line_end - para_start, &runs_buf);
    for (runs) |run| {
        const abs_start = para_start + run.start;
        const abs_end = para_start + run.end;
        var count: usize = 0;
        var counter = segments(content, spans, abs_start, abs_end);
        while (counter.next()) |_| count += 1;

        var k: usize = 0;
        while (k < count) : (k += 1) {
            const want = if (run.rtl()) count - 1 - k else k;
            var it = segments(content, spans, abs_start, abs_end);
            var i: usize = 0;
            while (it.next()) |seg| : (i += 1) {
                if (i != want) continue;
                const face = seg.span.face(base);
                var edges: [bidi.max_line_edges]u32 = undefined;
                const seg_off = @intFromPtr(seg.bytes.ptr) - @intFromPtr(content.ptr);
                var edge_count: usize = 0;
                var eit = bidi.measureRuns(seg.bytes);
                while (eit.next()) |mrun| {
                    if (edge_count == bidi.max_line_edges) break;
                    edges[edge_count] = @intCast(@intFromPtr(mrun.bytes.ptr) - @intFromPtr(content.ptr));
                    edge_count += 1;
                }
                var pi: usize = 0;
                while (pi < edge_count) : (pi += 1) {
                    if (n == out.len) break;
                    const idx = if (run.rtl()) edge_count - 1 - pi else pi;
                    const pstart = edges[idx];
                    const pend = if (idx + 1 < edge_count) edges[idx + 1] else seg_off + seg.bytes.len;
                    const piece = content[pstart..pend];
                    const w = measurer.measureRun(face, size_px, piece);
                    out[n] = .{ .bytes = piece, .span_index = seg.index, .x = pen, .w = w };
                    n += 1;
                    pen += w;
                }
                break;
            }
        }
    }
    return out[0..n];
}

/// The drawn width of one wrapped line of spanned text — what an RTL
/// paragraph's origin is measured back from.
pub fn spanLineWidth(measurer: text.Measurer, base: text.Face, size_px: i32, content: []const u8, spans: []const element_mod.Span, line_start: usize, line_end: usize) i32 {
    var w: i32 = 0;
    var it = segments(content, spans, line_start, line_end);
    while (it.next()) |seg| w += measurer.measure(seg.span.face(base), size_px, seg.bytes);
    return w;
}

/// Where one span's ink actually lands inside a laid-out text element:
/// consecutive drawn pieces of that span, merged. A span that wraps —
/// or that a bidi line splits into separate visual runs — is several
/// rectangles, and every one of them must underline, ring, and hit, so
/// underlining, focus rings, and hit testing all read this list.
/// Rects are `scale.lineHeight()` tall, the line box the span sits in.
pub fn spanRects(
    measurer: text.Measurer,
    scratch: *bidi.Scratch,
    base: text.Face,
    scale: text.Scale,
    content: []const u8,
    spans: []const element_mod.Span,
    span_index: usize,
    rect: Rect,
    out: []Rect,
) []Rect {
    var n: usize = 0;
    var y = rect.y;
    var pieces: [max_line_pieces]LinePiece = undefined;
    var cursor: ParagraphCursor = .{ .content = content };
    var it = wrapSpans(measurer, base, scale.px(), content, spans, rect.w);
    while (it.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(content.ptr);
        cursor.advanceTo(scratch, start);
        const origin = if (cursor.complex and cursor.rtl)
            rect.x + rect.w - spanLineWidth(measurer, base, scale.px(), content, spans, start, start + line.len)
        else
            rect.x;
        const line_pieces = linePieces(
            measurer,
            base,
            scale.px(),
            content,
            spans,
            start,
            start + line.len,
            origin,
            if (cursor.complex) &cursor.para else null,
            cursor.start,
            &pieces,
        );
        var open: ?Rect = null;
        for (line_pieces) |piece| {
            if (piece.span_index != span_index) {
                if (open) |r| {
                    if (n < out.len) {
                        out[n] = r;
                        n += 1;
                    }
                    open = null;
                }
                continue;
            }
            if (open) |*r| {
                // Pieces of one span run consecutively in draw order,
                // so extending the open rect is exact — no gap can hide
                // inside it.
                r.w = piece.x + piece.w - r.x;
            } else {
                open = .{ .x = piece.x, .y = y, .w = piece.w, .h = scale.lineHeight() };
            }
        }
        if (open) |r| {
            if (n < out.len) {
                out[n] = r;
                n += 1;
            }
        }
        y += scale.lineHeight();
    }
    return out[0..n];
}

/// Budget for one span's rects: a link crossing this many wrapped lines
/// and bidi runs has stopped being a link.
pub const max_span_rects = 32;

/// The single-line width of spanned text: what `intrinsicSize` is to
/// plain content.
pub fn spanTextWidth(measurer: text.Measurer, base: text.Face, size_px: i32, spans: []const element_mod.Span) i32 {
    var w: i32 = 0;
    for (spans) |span| {
        w += measurer.measure(span.face(base), size_px, span.text);
    }
    return w;
}

/// The elision marker `elideMiddle` budgets for; the renderer draws it
/// between the surviving ends.
pub const ellipsis = "\u{2026}";

/// Byte offsets of the ends that survive a middle elision: the value
/// displays as `value[0..head_end] ++ ellipsis ++ value[tail_start..]`.
pub const Elision = struct { head_end: usize, tail_start: usize };

/// Middle elision for a verbatim single-line value (`copyable`): null
/// when the whole value fits `max_w`, else the longest head and tail
/// that fit around the ellipsis. The middle goes — not the tail —
/// because both ends are what a human checks a pasted value against
/// (the convention for fingerprints and share links). Grown a codepoint
/// at a time, head first, so the split lands on codepoint boundaries
/// and an odd budget favors the head. Codepoints, not grapheme
/// clusters: the values are codes and URLs, and cluster segmentation
/// would drag in Unicode tables for a boundary case that reads fine
/// split.
pub fn elideMiddle(measurer: text.Measurer, face: text.Face, size_px: i32, value: []const u8, max_w: i32) ?Elision {
    if (measurer.measure(face, size_px, value) <= max_w) return null;
    const ell_w = measurer.measure(face, size_px, ellipsis);
    var head_end: usize = 0;
    var tail_start: usize = value.len;
    while (true) {
        var grew = false;
        if (head_end < tail_start) {
            const nh = head_end + (std.unicode.utf8ByteSequenceLength(value[head_end]) catch 1);
            if (nh < tail_start and fitsAround(measurer, face, size_px, value, nh, tail_start, ell_w, max_w)) {
                head_end = nh;
                grew = true;
            }
        }
        if (head_end < tail_start) {
            var nt = tail_start - 1;
            while (nt > head_end and (value[nt] & 0xC0) == 0x80) nt -= 1;
            if (nt > head_end and fitsAround(measurer, face, size_px, value, head_end, nt, ell_w, max_w)) {
                tail_start = nt;
                grew = true;
            }
        }
        if (!grew) return .{ .head_end = head_end, .tail_start = tail_start };
    }
}

fn fitsAround(measurer: text.Measurer, face: text.Face, size_px: i32, value: []const u8, head_end: usize, tail_start: usize, ell_w: i32, max_w: i32) bool {
    const head_w = measurer.measure(face, size_px, value[0..head_end]);
    const tail_w = measurer.measure(face, size_px, value[tail_start..]);
    return head_w + ell_w + tail_w <= max_w;
}
