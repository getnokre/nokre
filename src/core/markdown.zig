//! Markdown, expanded into ordinary elements at `append`.
//!
//! Nothing else in nokre learns about Markdown: this module turns a
//! source string into `heading`, `text`, `list`, `code_block`,
//! `blockquote`, `table` and `divider` children, and every one of them
//! goes through `Tree.append`. So the element set stays closed, and
//! every construction rule — contrast, structure, labels — applies to
//! parsed content for free. The parser's error path *is* append's.
//!
//! Two rules make it safe to point at bytes nobody reviewed:
//!
//! **Unsupported syntax degrades to its literal source text**, markers
//! included, rather than being dropped or raising. That keeps the error
//! path genuinely rare — an error means the tree refused the content,
//! not that the parser met something new — and it is a property, not a
//! hope: every byte of a degraded construct appears exactly once, in
//! source order (see the test of the same name).
//!
//! **Heading levels are rebased onto a gapless sequence.** Fetched
//! Markdown routinely opens at `##` or jumps h2 → h4, which would trip
//! the `heading_level_skipped` audit on content the app cannot fix.
//! Rebasing keeps the real outline and leaves the rule intact for
//! app-authored trees. Where that sequence *starts* is the one thing a
//! rebased source can no longer say, so the element says it —
//! `Document.base_level`, `h1` unless the screen already drew one.
//!
//! Pure Zig, no dependencies, integer-only — `core/qr.zig` is the
//! precedent for a content module living in core.

const std = @import("std");
const element_mod = @import("element.zig");
// For the external-destination decision only: the allowlist is the
// open_url service's one fact, consulted here so a link the parser
// builds is a link the service will open (tree.zig's rule).
const open_url = @import("../services/open_url/open_url.zig");
const tree_mod = @import("tree.zig");

const Span = element_mod.Span;
const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;

/// Spans per paragraph. Past it the tail merges into the last span:
/// the words all survive, only the markup of the overflow is dropped —
/// the same deterministic truncation bidi's line budgets take.
pub const max_inline_spans = 128;

/// Expands `doc.source` as Markdown into children of `parent`. Bounded
/// allocation: one scratch arena for the intermediate strings, released
/// here; everything that survives was copied by `Tree.append`.
///
/// The whole element rather than its source, because the rebase reads
/// `base_level` too — and a second parameter for it would be the one
/// field a caller could pass out of step with the node it belongs to.
///
/// The error set is `anyerror` on purpose. `Tree.append` calls this to
/// expand a `document`, and this calls `Tree.append` for every block it
/// produces — which is the whole point, since the parser's error path
/// *is* append's — so an inferred set would be a cycle. It never
/// panics; every failure arrives here as an error.
pub fn expand(tree: *Tree, parent: NodeId, doc: element_mod.Document) anyerror!void {
    var scratch = std.heap.ArenaAllocator.init(tree.gpa);
    defer scratch.deinit();
    var state: State = .{ .a = scratch.allocator(), .tree = tree, .base_level = doc.base_level };
    try state.blocks(parent, doc.source, .{});
}

/// What a container permits. Both exclusions mirror `Tree.append`'s
/// document block set: a heading inside a list or a quote would claim
/// an outline position its container cannot own, and a grid at that
/// depth reads as a mistake. Neither raises — they degrade.
const Allow = struct {
    headings: bool = true,
    tables: bool = true,
    breaks: bool = true,
    /// Enclosing lists. `element.max_list_depth` is a construction
    /// rule, so deeper levels flatten onto the last one rather than
    /// failing — exactly as heading levels rebase.
    list_depth: usize = 0,
};

const State = struct {
    a: std.mem.Allocator,
    tree: *Tree,
    /// Source depths of the headings still open, innermost last. The
    /// rendered level is this stack's height counted from `base_level`,
    /// so the outline is gapless however the source numbered itself.
    heading_stack: [max_heading_stack]u8 = undefined,
    heading_len: usize = 0,
    /// Where the document's own top heading lands (`element.Document`).
    base_level: element_mod.HeadingLevel = .h1,

    const max_heading_stack = 6;
    /// The deepest level HTML and `HeadingLevel` both have. A base past
    /// `h1` spends part of the ladder before the document's first
    /// heading, so a deep source flattens onto `h6` sooner — the same
    /// deterministic flattening a 7-deep source already takes, and the
    /// only alternative is refusing content the app cannot fix.
    const deepest_level = 6;

    fn headingLevel(self: *State, source_depth: u8) element_mod.HeadingLevel {
        while (self.heading_len > 0 and self.heading_stack[self.heading_len - 1] >= source_depth) {
            self.heading_len -= 1;
        }
        if (self.heading_len < max_heading_stack) {
            self.heading_stack[self.heading_len] = source_depth;
            self.heading_len += 1;
        }
        const depth = @min(self.heading_len, max_heading_stack);
        const level = @as(usize, @intFromEnum(self.base_level)) + depth - 1;
        return @enumFromInt(@as(u8, @intCast(@min(level, deepest_level))));
    }

    fn blocks(self: *State, parent: NodeId, source: []const u8, allow: Allow) anyerror!void {
        var lines: Lines = .{ .src = source };
        while (lines.peek()) |line| {
            if (isBlank(line)) {
                _ = lines.next();
                continue;
            }
            if (fenceMarker(line)) |fence| {
                _ = lines.next();
                try self.fencedCode(parent, &lines, fence);
                continue;
            }
            if (allow.breaks and isThematicBreak(line)) {
                _ = lines.next();
                try self.tree.append(parent, .{ .divider = .{} });
                continue;
            }
            if (allow.headings) {
                if (atxHeading(line)) |h| {
                    _ = lines.next();
                    try self.heading(parent, h);
                    continue;
                }
            }
            if (quotePrefix(line) != null) {
                try self.blockquote(parent, &lines, allow);
                continue;
            }
            if (listMarker(line) != null) {
                try self.list(parent, &lines, allow);
                continue;
            }
            if (allow.tables and tableStarts(&lines) and tableFits(&lines)) {
                try self.table(parent, &lines);
                continue;
            }
            try self.paragraph(parent, &lines, allow);
        }
    }

    fn heading(self: *State, parent: NodeId, h: Atx) !void {
        var spans: std.ArrayList(Span) = .empty;
        try inlines(self.a, h.text, &spans);
        const level = self.headingLevel(h.depth);
        if (spans.items.len == 1 and plain(spans.items[0])) {
            try self.tree.append(parent, .{ .heading = .{ .content = spans.items[0].text, .level = level } });
        } else {
            try self.tree.append(parent, .{ .heading = .{ .spans = spans.items, .level = level } });
        }
    }

    /// A fenced block runs to its closing fence or to the end of the
    /// source — an unterminated fence at the end of a truncated
    /// response is the common case, and it reads fine as code.
    fn fencedCode(self: *State, parent: NodeId, lines: *Lines, fence: Fence) !void {
        var body: std.ArrayList(u8) = .empty;
        // The separator keys on "a line came before", not on bytes
        // accumulated: a leading blank line is verbatim content, and
        // keying on length would swallow it.
        var any = false;
        while (lines.next()) |line| {
            if (closesFence(line, fence)) break;
            if (any) try body.append(self.a, '\n');
            try body.appendSlice(self.a, line);
            any = true;
        }
        // An empty block cannot be appended, and there is nothing
        // verbatim in it to show anyway.
        if (body.items.len == 0) return;
        try self.tree.append(parent, .{ .code_block = .{ .content = body.items } });
    }

    fn blockquote(self: *State, parent: NodeId, lines: *Lines, allow: Allow) !void {
        var body: std.ArrayList(u8) = .empty;
        while (lines.peek()) |line| {
            const rest = quotePrefix(line) orelse {
                // Lazy continuation: a plain line under a quote line
                // stays in the quote, as CommonMark says.
                if (isBlank(line)) break;
                if (body.items.len == 0) break;
                try body.append(self.a, '\n');
                try body.appendSlice(self.a, line);
                _ = lines.next();
                continue;
            };
            _ = lines.next();
            if (body.items.len > 0) try body.append(self.a, '\n');
            try body.appendSlice(self.a, rest);
        }
        const quote = try self.tree.appendId(parent, .{ .blockquote = .{} });
        try self.blocks(quote, body.items, .{
            .headings = false,
            .tables = false,
            .breaks = false,
            .list_depth = allow.list_depth,
        });
    }

    fn list(self: *State, parent: NodeId, lines: *Lines, allow: Allow) !void {
        const first = listMarker(lines.peek().?).?;
        // A list past the depth cap is flattened onto the last legal
        // level: its items join the enclosing item's flow rather than
        // opening a list `Tree.append` would refuse.
        const flattened = allow.list_depth >= element_mod.max_list_depth;
        const list_id = if (flattened) parent else try self.tree.appendId(parent, .{ .list = .{
            .ordered = first.ordered,
            .start = first.start,
        } });
        const depth = if (flattened) allow.list_depth else allow.list_depth + 1;

        while (lines.peek()) |line| {
            const marker = listMarker(line) orelse {
                if (isBlank(line)) {
                    // One blank line inside a list is spacing; two end
                    // it. Peeking past the blank is what tells them
                    // apart.
                    var ahead = lines.*;
                    _ = ahead.next();
                    const following = ahead.peek() orelse break;
                    if (listMarker(following) == null and !isIndented(following)) break;
                    _ = lines.next();
                    continue;
                }
                break;
            };
            // A different kind of marker starts a different list.
            if (marker.ordered != first.ordered) break;
            _ = lines.next();

            var body: std.ArrayList(u8) = .empty;
            try body.appendSlice(self.a, marker.rest);
            // Indented lines and lazy continuations belong to the item.
            while (lines.peek()) |cont| {
                if (isBlank(cont)) break;
                if (listMarker(cont) != null and !isIndented(cont)) break;
                try body.append(self.a, '\n');
                try body.appendSlice(self.a, dedent(cont, marker.indent));
                _ = lines.next();
            }
            const item = if (flattened) list_id else try self.tree.appendId(list_id, .{ .list_item = .{} });
            try self.blocks(item, body.items, .{
                .headings = false,
                .tables = false,
                .breaks = false,
                .list_depth = depth,
            });
        }
    }

    /// A GFM table: header row, delimiter row, body rows. Cells hold
    /// inline content but no blocks — a table inside a table is not a
    /// thing the grammar can express here.
    fn table(self: *State, parent: NodeId, lines: *Lines) !void {
        const header = lines.next().?;
        _ = lines.next(); // the delimiter row
        const table_id = try self.tree.appendId(parent, .{ .table = .{} });
        try self.tableRow(table_id, header, true);
        while (lines.peek()) |line| {
            if (isBlank(line) or std.mem.indexOfScalar(u8, line, '|') == null) break;
            _ = lines.next();
            try self.tableRow(table_id, line, false);
        }
    }

    fn tableRow(self: *State, table_id: NodeId, line: []const u8, header: bool) !void {
        const row = try self.tree.appendId(table_id, .{ .row = .{ .header = header } });
        var cells = tableCells(line);
        while (cells.next()) |cell_src| {
            const cell = try self.tree.appendId(row, .{ .cell = .{} });
            var spans: std.ArrayList(Span) = .empty;
            try inlines(self.a, cell_src, &spans);
            if (spans.items.len == 0) continue;
            if (spans.items.len == 1 and plain(spans.items[0])) {
                try self.tree.append(cell, .{ .text = .{ .content = spans.items[0].text } });
            } else {
                try self.tree.append(cell, .{ .text = .{ .spans = spans.items } });
            }
        }
    }

    fn paragraph(self: *State, parent: NodeId, lines: *Lines, allow: Allow) !void {
        var body: std.ArrayList(u8) = .empty;
        while (lines.peek()) |line| {
            if (isBlank(line)) break;
            if (fenceMarker(line) != null) break;
            if (quotePrefix(line) != null) break;
            if (listMarker(line) != null) break;
            if (allow.headings and atxHeading(line) != null) break;
            if (allow.breaks and isThematicBreak(line)) break;
            _ = lines.next();
            if (body.items.len > 0) {
                // A soft break is a space; two trailing spaces or a
                // trailing backslash make it hard, and layout already
                // honours '\n' inside a paragraph.
                try body.append(self.a, if (hardBreakBefore(body.items)) '\n' else ' ');
                trimHardBreakMarker(&body);
            }
            try body.appendSlice(self.a, line);
        }
        if (body.items.len == 0) return;
        var spans: std.ArrayList(Span) = .empty;
        try inlines(self.a, body.items, &spans);
        if (spans.items.len == 0) return;
        if (spans.items.len == 1 and plain(spans.items[0])) {
            try self.tree.append(parent, .{ .text = .{ .content = spans.items[0].text } });
        } else {
            try self.tree.append(parent, .{ .text = .{ .spans = spans.items } });
        }
    }
};

fn plain(span: Span) bool {
    return !span.strong and !span.emphasis and !span.code and !span.strike and !span.isLink();
}

// ---- lines ----

const Lines = struct {
    src: []const u8,
    i: usize = 0,

    fn next(self: *Lines) ?[]const u8 {
        if (self.i >= self.src.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.src, self.i, '\n') orelse self.src.len;
        var line = self.src[self.i..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        self.i = end + 1;
        return line;
    }

    fn peek(self: *const Lines) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }
};

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn isIndented(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '\t');
}

fn offsetIn(line: []const u8, tail: []const u8) usize {
    return @intFromPtr(tail.ptr) - @intFromPtr(line.ptr);
}

/// Strips one item's worth of indentation, so a nested marker is found
/// where the recursion looks for it and a doubly nested one keeps the
/// indent that makes it doubly nested.
fn dedent(line: []const u8, indent: usize) []const u8 {
    var i: usize = 0;
    while (i < line.len and i < indent and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[i..];
}

fn isThematicBreak(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    for (t) |b| {
        if (b != c and b != ' ') return false;
    }
    var n: usize = 0;
    for (t) |b| n += @intFromBool(b == c);
    return n >= 3;
}

const Atx = struct { depth: u8, text: []const u8 };

fn atxHeading(line: []const u8) ?Atx {
    const t = std.mem.trimStart(u8, line, " ");
    var depth: u8 = 0;
    while (depth < t.len and t[depth] == '#') depth += 1;
    if (depth == 0 or depth > 6) return null;
    // `#hashtag` is not a heading; the marker needs a space after it.
    if (depth < t.len and t[depth] != ' ' and t[depth] != '\t') return null;
    // Trailing `###` is closing punctuation, not words.
    const body = std.mem.trim(u8, t[depth..], " \t");
    return .{ .depth = depth, .text = std.mem.trimEnd(u8, std.mem.trimEnd(u8, body, "#"), " \t") };
}

const Fence = struct { char: u8, len: usize };

fn fenceMarker(line: []const u8) ?Fence {
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len < 3) return null;
    const c = t[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < t.len and t[n] == c) n += 1;
    if (n < 3) return null;
    // The info string (```zig) is dropped: nokre has no syntax
    // highlighting to feed it to, and inventing one would be styling.
    return .{ .char = c, .len = n };
}

fn closesFence(line: []const u8, fence: Fence) bool {
    const marker = fenceMarker(line) orelse return false;
    if (marker.char != fence.char or marker.len < fence.len) return false;
    return std.mem.trim(u8, std.mem.trimStart(u8, line, " ")[marker.len..], " \t").len == 0;
}

/// The content of a `>` line, or null when it is not one.
fn quotePrefix(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len == 0 or t[0] != '>') return null;
    const rest = t[1..];
    return if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
}

const Marker = struct {
    ordered: bool,
    start: i32,
    rest: []const u8,
    /// The column the item's content starts at. Continuation lines are
    /// stripped by exactly this much, so a deeper marker keeps the
    /// indentation that makes it deeper — stripping a fixed amount
    /// would flatten every level into the first.
    indent: usize,
};

fn listMarker(line: []const u8) ?Marker {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len < 2) return null;
    if ((t[0] == '-' or t[0] == '*' or t[0] == '+') and (t[1] == ' ' or t[1] == '\t')) {
        // A thematic break wins: `- - -` is a rule, not an item.
        if (isThematicBreak(line)) return null;
        const body = std.mem.trimStart(u8, t[1..], " \t");
        return .{ .ordered = false, .start = 1, .rest = body, .indent = offsetIn(line, body) };
    }
    var digits: usize = 0;
    while (digits < t.len and digits < 9 and t[digits] >= '0' and t[digits] <= '9') digits += 1;
    if (digits == 0) return null;
    if (digits + 1 >= t.len) return null;
    if (t[digits] != '.' and t[digits] != ')') return null;
    if (t[digits + 1] != ' ' and t[digits + 1] != '\t') return null;
    const n = std.fmt.parseInt(i32, t[0..digits], 10) catch return null;
    const body = std.mem.trimStart(u8, t[digits + 1 ..], " \t");
    return .{ .ordered = true, .start = n, .rest = body, .indent = offsetIn(line, body) };
}

/// Whether a GFM table starts here: a row of cells followed by a
/// delimiter row. Both are required — a lone line with a pipe in it is
/// prose about pipes.
fn tableStarts(lines: *const Lines) bool {
    const header = lines.peek() orelse return false;
    if (std.mem.indexOfScalar(u8, header, '|') == null) return false;
    var ahead = lines.*;
    _ = ahead.next();
    const delim = ahead.peek() orelse return false;
    if (std.mem.indexOfScalar(u8, delim, '-') == null) return false;
    if (std.mem.indexOfScalar(u8, delim, '|') == null) return false;
    for (delim) |b| {
        switch (b) {
            '-', ':', '|', ' ', '\t' => {},
            else => return false,
        }
    }
    return true;
}

/// Whether every row of the table starting here fits the tree's column
/// cap (`Tree.append` refuses the cell past `max_table_columns`). A
/// wider one degrades to its literal source text — the standing rule
/// for what the parser cannot build — rather than surface a
/// construction error for bytes nobody reviewed.
fn tableFits(lines: *const Lines) bool {
    var ahead = lines.*;
    const header = ahead.next() orelse return true;
    if (countCells(header) > element_mod.max_table_columns) return false;
    _ = ahead.next(); // the delimiter row
    while (ahead.peek()) |line| {
        if (isBlank(line) or std.mem.indexOfScalar(u8, line, '|') == null) break;
        _ = ahead.next();
        if (countCells(line) > element_mod.max_table_columns) return false;
    }
    return true;
}

fn countCells(line: []const u8) usize {
    var n: usize = 0;
    var it = tableCells(line);
    while (it.next()) |_| n += 1;
    return n;
}

const CellIterator = struct {
    rest: []const u8,
    done: bool = false,

    fn next(self: *CellIterator) ?[]const u8 {
        if (self.done) return null;
        if (std.mem.indexOfScalar(u8, self.rest, '|')) |i| {
            const cell = self.rest[0..i];
            self.rest = self.rest[i + 1 ..];
            return std.mem.trim(u8, cell, " \t");
        }
        self.done = true;
        return std.mem.trim(u8, self.rest, " \t");
    }
};

fn tableCells(line: []const u8) CellIterator {
    var t = std.mem.trim(u8, line, " \t");
    // The outer pipes are decoration; only the inner ones separate.
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    return .{ .rest = t };
}

fn hardBreakBefore(body: []const u8) bool {
    if (body.len >= 1 and body[body.len - 1] == '\\') return true;
    return body.len >= 2 and body[body.len - 1] == ' ' and body[body.len - 2] == ' ';
}

fn trimHardBreakMarker(body: *std.ArrayList(u8)) void {
    // The joining character has already been pushed; the marker sits
    // just under it.
    if (body.items.len < 2) return;
    const sep = body.items[body.items.len - 1];
    if (sep != '\n') return;
    var end = body.items.len - 1;
    if (body.items[end - 1] == '\\') {
        end -= 1;
    } else {
        while (end > 0 and body.items[end - 1] == ' ') end -= 1;
    }
    body.items[end] = '\n';
    body.shrinkRetainingCapacity(end + 1);
}

// ---- inline ----

/// Splits `src` into styled runs. Anything the subset does not cover
/// stays in the text exactly as written, markers included: no byte is
/// invented and none is lost.
pub fn inlines(a: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Span)) !void {
    var w: Writer = .{ .a = a, .out = out };
    var i: usize = 0;
    while (i < src.len) {
        switch (src[i]) {
            '`' => {
                if (codeSpan(src, i)) |cs| {
                    try w.flush();
                    const saved = w.style;
                    w.style.code = true;
                    try w.text(src[cs.start..cs.end]);
                    try w.flush();
                    w.style = saved;
                    i = cs.next;
                    continue;
                }
            },
            '*', '_' => {
                const run = delimiterRun(src, i);
                const open = if (run.len == 2) w.style.strong else w.style.emphasis;
                if (run.opens or (run.closes and open)) {
                    try w.flush();
                    if (run.len == 2) w.style.strong = !w.style.strong else w.style.emphasis = !w.style.emphasis;
                } else {
                    // A run the subset does not cover degrades whole:
                    // emitting one byte and rescanning would let the
                    // tail of `***` be read as a `**`, and two of the
                    // three markers would vanish.
                    try w.text(src[i .. i + run.len]);
                }
                i += run.len;
                continue;
            },
            // Strikethrough is the one delimiter that is only ever
            // doubled: a single `~` is punctuation people write.
            '~' => {
                const run = delimiterRun(src, i);
                if ((run.opens or (run.closes and w.style.strike)) and run.len == 2) {
                    try w.flush();
                    w.style.strike = !w.style.strike;
                } else {
                    try w.text(src[i .. i + run.len]);
                }
                i += run.len;
                continue;
            },
            '[' => {
                if (linkAt(src, i)) |link| {
                    try w.flush();
                    const saved = w.style;
                    switch (link.dest) {
                        .route => |r| w.style.route = r,
                        .external => |u| w.style.external = u,
                    }
                    try w.text(src[link.label_start..link.label_end]);
                    try w.flush();
                    w.style = saved;
                    i = link.next;
                    continue;
                }
            },
            '!' => {
                // An image is outside the subset (see docs/markdown.md:
                // a picture cannot carry information grayscale words
                // can't). Emitting the `![` here is what keeps the rest
                // of the construct from being read as a link, so every
                // byte of it comes through as written.
                if (i + 1 < src.len and src[i + 1] == '[') {
                    try w.text(src[i .. i + 2]);
                    i += 2;
                    continue;
                }
            },
            '\\' => {
                // A backslash escape is the one place a marker byte is
                // dropped, because that is what it is there to do.
                if (i + 1 < src.len and isMarkerByte(src[i + 1])) {
                    try w.byte(src[i + 1]);
                    i += 2;
                    continue;
                }
            },
            else => {},
        }
        try w.byte(src[i]);
        i += 1;
    }
    // An unclosed `**` leaves the style set; the words are already in
    // the buffer either way, so nothing is lost.
    try w.flush();
}

const Writer = struct {
    a: std.mem.Allocator,
    out: *std.ArrayList(Span),
    buf: std.ArrayList(u8) = .empty,
    style: Style = .{},

    const Style = struct {
        strong: bool = false,
        emphasis: bool = false,
        code: bool = false,
        strike: bool = false,
        /// Spelled as the span field it becomes: empty is prose
        /// (`Span.route`), so the writer carries no second way to say
        /// the run has no destination.
        route: []const u8 = "",
        external: ?[]const u8 = null,
    };

    fn byte(self: *Writer, b: u8) !void {
        try self.buf.append(self.a, b);
    }

    fn text(self: *Writer, bytes: []const u8) !void {
        try self.buf.appendSlice(self.a, bytes);
    }

    fn flush(self: *Writer) !void {
        if (self.buf.items.len == 0) return;
        const span: Span = .{
            .text = self.buf.items,
            .strong = self.style.strong,
            .emphasis = self.style.emphasis,
            .code = self.style.code,
            .strike = self.style.strike,
            .route = self.style.route,
            .external = self.style.external,
        };
        // Past the budget the tail merges into the last span: the words
        // all survive, only the markup of the overflow is dropped.
        if (self.out.items.len >= max_inline_spans) {
            const last = &self.out.items[self.out.items.len - 1];
            var merged: std.ArrayList(u8) = .empty;
            try merged.appendSlice(self.a, last.text);
            try merged.appendSlice(self.a, span.text);
            last.text = merged.items;
        } else {
            try self.out.append(self.a, span);
        }
        self.buf = .empty;
    }
};

fn isMarkerByte(b: u8) bool {
    return switch (b) {
        '\\', '`', '*', '_', '[', ']', '(', ')', '#', '+', '-', '.', '!', '>', '|', '~' => true,
        else => false,
    };
}

const CodeSpan = struct { start: usize, end: usize, next: usize };

fn codeSpan(src: []const u8, at: usize) ?CodeSpan {
    var ticks: usize = 0;
    while (at + ticks < src.len and src[at + ticks] == '`') ticks += 1;
    var i = at + ticks;
    while (i < src.len) {
        if (src[i] != '`') {
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i + run < src.len and src[i + run] == '`') run += 1;
        if (run == ticks) return .{ .start = at + ticks, .end = i, .next = i + run };
        i += run;
    }
    return null; // unclosed: the backticks stay as written
}

const DelimiterRun = struct { len: usize, opens: bool, closes: bool };

/// A run of `*`, `_` or `~`. For `*`/`_`, one is emphasis and two are
/// strong; three or more is `***both***`, which the subset does not
/// cover. For `~`, only two open (the caller checks), because a lone
/// tilde is punctuation people write. A run with nothing after it opens
/// nothing — there is nothing left to mark — but it may still close a
/// style that is open, or `**bold**` could never end a block, a cell or
/// a heading. Whether one *is* open is the caller's knowledge, so the
/// caller consults `closes` against its own state; a run that neither
/// opens nor closes is literal text.
fn delimiterRun(src: []const u8, at: usize) DelimiterRun {
    const c = src[at];
    var n: usize = 0;
    while (at + n < src.len and src[at + n] == c) n += 1;
    const marks = (n == 1 or n == 2) and !(c == '_' and intraword(src, at, n));
    return .{ .len = n, .opens = marks and at + n < src.len, .closes = marks };
}

/// Whether the run at `at` has a word character on both sides.
///
/// It is the whole of the difference between the two emphasis markers,
/// and it belongs to `_` alone — CommonMark's rule, for the reason
/// CommonMark has it: `snake_case`, `__init__` and `plural_rules.zig`
/// are words people write in prose, and a parser that reads the middle
/// of an identifier as a marker turns a file name into italics. `a*b*c`
/// is nobody's identifier, so `*` keeps no such exception and stays the
/// marker that always marks.
///
/// A run against either end of the source is not intraword: there is no
/// word on that side to be inside of. Bytes past ASCII count as word
/// bytes, so a marker between two Persian letters is intraword too —
/// the alternative is a rule that reads one script's identifiers and
/// not another's.
fn intraword(src: []const u8, at: usize, len: usize) bool {
    if (at == 0 or at + len >= src.len) return false;
    return isWordByte(src[at - 1]) and isWordByte(src[at + len]);
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b >= 0x80;
}

const Dest = union(enum) { route: []const u8, external: []const u8 };
const Link = struct { label_start: usize, label_end: usize, dest: Dest, next: usize };

/// `[label](destination)`, with a plain label. Inline markup inside a
/// label would need either nested spans (which the element set does not
/// have) or several spans sharing one route (which would be several tab
/// stops for one link), so a marked-up label degrades whole.
///
/// The destination test is **syntactic**, never a route lookup: a
/// destination carrying a URI scheme is not an in-app route. One whose
/// scheme is on open_url's allowlist (https/http/mailto — fetched legal
/// text realistically carries a `mailto:` and third-party references)
/// becomes an external link span, opened in the system browser at
/// activation; any other scheme, and a protocol-relative `//host`,
/// degrades to literal text — the closed set holds, and what falls
/// outside it stays visible rather than active. Everything else becomes
/// a route name, and the router decides at activation whether it exists
/// — which is why the parser needs no router access.
fn linkAt(src: []const u8, at: usize) ?Link {
    const close = std.mem.indexOfScalarPos(u8, src, at + 1, ']') orelse return null;
    if (close + 1 >= src.len or src[close + 1] != '(') return null;
    const paren = std.mem.indexOfScalarPos(u8, src, close + 2, ')') orelse return null;
    const label = src[at + 1 .. close];
    if (label.len == 0) return null;
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        switch (label[i]) {
            '`', '*', '[', ']' => return null,
            // An underscore inside a word is punctuation, not markup
            // (`intraword`), so a label may carry one: `secure_store.md`
            // is a file name and stays a link. One that would open
            // emphasis still degrades the label whole.
            '_' => {
                const run = delimiterRun(label, i);
                if (run.opens) return null;
                i += run.len - 1;
            },
            else => {},
        }
    }
    const dest = std.mem.trim(u8, src[close + 2 .. paren], " \t");
    if (dest.len == 0) return null;
    if (hasUriScheme(dest)) {
        if (!open_url.schemeAllowed(dest)) return null;
        return .{ .label_start = at + 1, .label_end = close, .dest = .{ .external = dest }, .next = paren + 1 };
    }
    return .{ .label_start = at + 1, .label_end = close, .dest = .{ .route = dest }, .next = paren + 1 };
}

/// Whether a destination names something outside the app: a scheme
/// (`scheme:`) or a protocol-relative `//host`. These are never
/// routes; whether one becomes an external link is open_url's
/// allowlist's answer (see `linkAt`).
pub fn hasUriScheme(dest: []const u8) bool {
    if (std.mem.startsWith(u8, dest, "//")) return true;
    for (dest, 0..) |b, i| {
        if (b == ':') return i > 0;
        const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
            (i > 0 and ((b >= '0' and b <= '9') or b == '+' or b == '.' or b == '-'));
        if (!ok) return false;
    }
    return false;
}

comptime {
    _ = element_mod;
}
