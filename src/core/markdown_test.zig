//! Tests for markdown.zig: the block and inline subset, the degrade
//! property, heading rebasing, and the promise that remote bytes can
//! never crash the parser.

const std = @import("std");
const element_mod = @import("element.zig");
const markdown = @import("markdown.zig");
const tree_mod = @import("tree.zig");

const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const testing = std.testing;

/// Renders a parsed document as an indented outline: the shape the
/// tests assert on, and the shape a reviewer can read. `.h2` is the
/// element's own default: level 1 is the screen's title's, so a body
/// appended to a page opens one below it.
fn outline(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    return outlineAt(gpa, .h2, source);
}

/// The same, for a document that states where its outline starts.
fn outlineAt(gpa: std.mem.Allocator, base: element_mod.HeadingLevel, source: []const u8) ![]u8 {
    var tree = try Tree.init(gpa);
    defer tree.deinit();
    const doc = try tree.appendId(tree.rootId(), .{ .document = .{
        .label = "Doc",
        .source = source,
        .base_level = base,
    } });
    return dump(gpa, &tree, doc);
}

fn dump(gpa: std.mem.Allocator, tree: *Tree, root: NodeId) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try dumpChildren(gpa, &out, tree, root, 0);
    return out.toOwnedSlice(gpa);
}

fn dumpChildren(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tree: *Tree, parent: NodeId, depth: usize) !void {
    var it = tree.children(parent);
    while (it.next()) |child| {
        const el = tree.getConst(child).?;
        try out.appendNTimes(gpa, ' ', depth * 2);
        try out.appendSlice(gpa, @tagName(el.role()));
        switch (el.*) {
            .heading => |hd| try out.print(gpa, " h{d} \"{s}\"", .{ @intFromEnum(hd.level), hd.content }),
            .text => |t| {
                try out.print(gpa, " \"{s}\"", .{t.content});
                for (t.spans) |span| {
                    if (span.route.len > 0) try out.print(gpa, " link(\"{s}\"->{s})", .{ span.text, span.route });
                    if (span.external) |u| try out.print(gpa, " ext(\"{s}\"->{s})", .{ span.text, u });
                    if (span.strong) try out.print(gpa, " strong(\"{s}\")", .{span.text});
                    if (span.emphasis) try out.print(gpa, " em(\"{s}\")", .{span.text});
                    if (span.code) try out.print(gpa, " code(\"{s}\")", .{span.text});
                    if (span.strike) try out.print(gpa, " strike(\"{s}\")", .{span.text});
                }
            },
            .code_block => |c| try out.print(gpa, " \"{s}\"", .{c.content}),
            .list => |l| if (l.ordered) try out.print(gpa, " ordered start={d}", .{l.start}),
            else => {},
        }
        try out.append(gpa, '\n');
        try dumpChildren(gpa, out, tree, child, depth + 1);
    }
}

/// Every byte of `source` that reaches the tree, concatenated in
/// document order. Text, code blocks, and headings all contribute their
/// words; nothing else carries source bytes.
fn allText(gpa: std.mem.Allocator, tree: *Tree, parent: NodeId, out: *std.ArrayList(u8)) !void {
    var it = tree.children(parent);
    while (it.next()) |child| {
        switch (tree.getConst(child).?.*) {
            .text => |t| try out.appendSlice(gpa, t.content),
            .heading => |hd| try out.appendSlice(gpa, hd.content),
            .code_block => |c| try out.appendSlice(gpa, c.content),
            else => {},
        }
        try allText(gpa, tree, child, out);
    }
}

test "blocks: headings, paragraphs, rules, quotes, code, lists, tables" {
    const got = try outline(testing.allocator,
        \\# Title
        \\
        \\A paragraph
        \\wrapped over two source lines.
        \\
        \\---
        \\
        \\> Quoted words.
        \\
        \\```
        \\fn main() void {}
        \\```
        \\
        \\- one
        \\- two
        \\
        \\| A | B |
        \\| --- | --- |
        \\| 1 | 2 |
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\heading h2 "Title"
        \\text "A paragraph wrapped over two source lines."
        \\divider
        \\blockquote
        \\  text "Quoted words."
        \\code_block "fn main() void {}"
        \\list
        \\  list_item
        \\    text "one"
        \\  list_item
        \\    text "two"
        \\table
        \\  row
        \\    cell
        \\      text "A"
        \\    cell
        \\      text "B"
        \\  row
        \\    cell
        \\      text "1"
        \\    cell
        \\      text "2"
        \\
    , got);
}

test "heading levels rebase onto a gapless sequence" {
    // Fetched Markdown opens at ## and jumps ## -> ####. Rebased from
    // the default base, the outline is h2/h3/h4/h2 — real structure
    // under the page's own title, and the heading_level_skipped audit
    // stays intact for app-authored trees.
    const got = try outline(testing.allocator,
        \\## Opening
        \\
        \\#### Jumped
        \\
        \\##### Deeper
        \\
        \\## Back up
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\heading h2 "Opening"
        \\heading h3 "Jumped"
        \\heading h4 "Deeper"
        \\heading h2 "Back up"
        \\
    , got);
}

test "a stated base level moves the whole outline down, still gapless" {
    // The default already puts a body under the page's title; this is
    // the case that stays editorial — a body subordinate to a *section*
    // rather than to the page. The source's numbering cannot say it,
    // being rebased either way, so the element does.
    const got = try outlineAt(testing.allocator, .h3,
        \\## Opening
        \\
        \\#### Jumped
        \\
        \\##### Deeper
        \\
        \\## Back up
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\heading h3 "Opening"
        \\heading h4 "Jumped"
        \\heading h5 "Deeper"
        \\heading h3 "Back up"
        \\
    , got);
}

test "a base level deep enough to run out of ladder flattens onto h6" {
    // Six source depths from a base of h4: h4, h5, h6, then h6 for the
    // rest. The same deterministic flattening a 7-deep source takes
    // from h1 — descending never skips, which is what the audit checks.
    const got = try outlineAt(testing.allocator, .h4,
        \\# A
        \\
        \\## B
        \\
        \\### C
        \\
        \\#### D
        \\
        \\##### E
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\heading h4 "A"
        \\heading h5 "B"
        \\heading h6 "C"
        \\heading h6 "D"
        \\heading h6 "E"
        \\
    , got);
}

test "inline: strong, emphasis, code, and in-app links" {
    const got = try outline(testing.allocator,
        \\Read the **terms**, *maybe* the `code`, or the [policy](privacy).
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\text "Read the terms, maybe the code, or the policy." strong("terms") em("maybe") code("code") link("policy"->privacy)
        \\
    , got);
}

test "inline: an underscore inside a word is punctuation, not a marker" {
    // CommonMark's rule, and the reason the two emphasis markers are
    // not interchangeable. Identifiers are ordinary prose in these docs.
    const got = try outline(testing.allocator,
        \\Call plural_rules.zig from __init__, never a_b_c.
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\text "Call plural_rules.zig from init, never a_b_c." strong("init")
        \\
    , got);
}

test "inline: the asterisk keeps no such exception" {
    // `a*b*c` is nobody's identifier, so `*` stays the marker that
    // always marks — the asymmetry is the point.
    const got = try outline(testing.allocator,
        \\Emphasis a*b*c lands mid-word.
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\text "Emphasis abc lands mid-word." em("b")
        \\
    , got);
}

test "a link label may carry an intraword underscore" {
    const got = try outline(testing.allocator,
        \\See [secure_store.md](internals/secure_store.md) and [a_](x).
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\text "See secure_store.md and a_." link("secure_store.md"->internals/secure_store.md) link("a_"->x)
        \\
    , got);
}

test "a link label that would open emphasis still degrades whole" {
    // One link is one focus stop; a label carrying markup would need
    // several spans sharing a route, which is several controls.
    const got = try outline(testing.allocator,
        \\Read the [_terms_](terms) and the [**policy**](privacy).
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\text "Read the [terms](terms) and the [policy](privacy)." em("terms") strong("policy")
        \\
    , got);
}

test "inline: strikethrough, doubled only" {
    const got = try outline(testing.allocator,
        \\Fees are ~~£20~~ £0 from May.
    );
    defer testing.allocator.free(got);
    // The words still read correctly without the mark — which is the
    // duty the span rule places on every styling span, and strike most
    // of all, since assistive tech hears one plain string.
    try testing.expectEqualStrings(
        \\text "Fees are £20 £0 from May." strike("£20")
        \\
    , got);
}

test "inline: a run at the end of the source still closes an open style" {
    // A closing run needs nothing after it — `**bold**` routinely ends
    // a paragraph, a heading, a cell, or a list item, and its closer
    // must be consumed there, not printed. Only an *opening* run at the
    // end is literal text (the degrade suite holds that side).
    const got = try outline(testing.allocator,
        \\## Status **Important**
        \\
        \\The field is **required**
        \\
        \\| **Yes** | no |
        \\| --- | --- |
        \\
        \\- maybe *later*
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\heading h2 "Status Important"
        \\text "The field is required" strong("required")
        \\table
        \\  row
        \\    cell
        \\      text "Yes" strong("Yes")
        \\    cell
        \\      text "no"
        \\list
        \\  list_item
        \\    text "maybe later" em("later")
        \\
    , got);
}

test "a destination carrying a URI scheme is never a route; the allowlist decides external versus literal" {
    // The test is syntactic, never a route lookup — which is why the
    // parser needs no router access.
    try testing.expect(markdown.hasUriScheme("https://example.com"));
    try testing.expect(markdown.hasUriScheme("mailto:x@example.com"));
    try testing.expect(markdown.hasUriScheme("//cdn.example.com/x"));
    try testing.expect(!markdown.hasUriScheme("privacy"));
    try testing.expect(!markdown.hasUriScheme("terms/section-2"));

    // On the allowlist (https/http/mailto — open_url's closed set): a
    // real external link span, beside a route span in the same
    // paragraph.
    const linked = try outline(testing.allocator,
        \\Mail [us](mailto:x@example.com), read the [terms](terms) or the [site](https://example.com/terms).
    );
    defer testing.allocator.free(linked);
    try testing.expectEqualStrings(
        \\text "Mail us, read the terms or the site." ext("us"->mailto:x@example.com) link("terms"->terms) ext("site"->https://example.com/terms)
        \\
    , linked);
}

test "a destination whose scheme is off the allowlist stays literal — the degradation boundary" {
    // The closed set is the boundary: what open_url would refuse to
    // open, the parser refuses to make active — the words stay visible
    // as written instead (the degrade property, not an error).
    const cases = [_][]const u8{
        "Fetch [it](ftp://example.com/file)",
        "Never [this](javascript:alert(1))",
        "Nor [files](file:///etc/passwd)",
        "A protocol-relative [ref](//cdn.example.com/x) is no scheme at all",
    };
    for (cases) |case| {
        var tree = try Tree.init(testing.allocator);
        defer tree.deinit();
        const doc = try tree.appendId(tree.rootId(), .{ .document = .{ .label = "Doc", .source = case } });
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        try allText(testing.allocator, &tree, doc, &got);
        try testing.expectEqualStrings(case, got.items);
    }
}

test "unsupported syntax degrades: every byte survives, exactly once, in order" {
    // The property that makes parsing bytes nobody reviewed safe. Each
    // of these is outside the subset; each must come through whole.
    const cases = [_][]const u8{
        "A lone ~tilde~ is punctuation, not a mark",
        "A trailing run that opens nothing stays literal: **",
        "![an image](photo.png)",
        "***both at once***",
        "A [ ] and an [x] are not task boxes",
        "A footnote[^1] and its marker",
        "<div>inline html</div>",
        "Term\n: a definition list",
        "An [unclosed link](terms",
        "An `unclosed code span",
        "https://example.com in bare text",
        "| a table | with no delimiter row |",
    };
    for (cases) |case| {
        var tree = try Tree.init(testing.allocator);
        defer tree.deinit();
        const doc = try tree.appendId(tree.rootId(), .{ .document = .{ .label = "Doc", .source = case } });
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        try allText(testing.allocator, &tree, doc, &got);

        // Source order, every byte once: the only difference the parser
        // may make is joining source lines with a single space.
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(testing.allocator);
        var it = std.mem.splitScalar(u8, case, '\n');
        while (it.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            if (want.items.len > 0) try want.append(testing.allocator, ' ');
            try want.appendSlice(testing.allocator, line);
        }
        try testing.expectEqualStrings(want.items, got.items);
    }
}

test "a task list is a plain list; the checkbox stays literal" {
    // The list is supported, so its marker is derived and the source
    // `- ` is gone by design. The checkbox is not supported, so it
    // survives exactly as written.
    const got = try outline(testing.allocator,
        \\- [ ] unchecked
        \\- [x] checked
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\list
        \\  list_item
        \\    text "[ ] unchecked"
        \\  list_item
        \\    text "[x] checked"
        \\
    , got);
}

test "list nesting past the cap flattens instead of failing" {
    // `Tree.append` refuses a fourth level; content nokre does not
    // control must not be able to raise, so the parser saturates.
    const got = try outline(testing.allocator,
        \\- one
        \\  - two
        \\    - three
        \\      - four
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\list
        \\  list_item
        \\    text "one"
        \\    list
        \\      list_item
        \\        text "two"
        \\        list
        \\          list_item
        \\            text "three"
        \\            text "four"
        \\
    , got);
}

test "an ordered list keeps the number it started on" {
    const got = try outline(testing.allocator,
        \\3. third
        \\4. fourth
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\list ordered start=3
        \\  list_item
        \\    text "third"
        \\  list_item
        \\    text "fourth"
        \\
    , got);
}

test "a heading or a table inside a list or a quote degrades to text" {
    // Both are outside the document block set `Tree.append` enforces.
    // Degrading keeps the words; raising would lose the whole document.
    const got = try outline(testing.allocator,
        \\> # Not a heading here
        \\
        \\- ## Nor here
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\blockquote
        \\  text "# Not a heading here"
        \\list
        \\  list_item
        \\    text "## Nor here"
        \\
    , got);
}

test "a table wider than the column cap degrades to its source text" {
    // `Tree.append` refuses the cell past `element.max_table_columns`,
    // and remote bytes must never surface a construction error — so a
    // wider table is one more thing the parser cannot build, degraded
    // whole like a nested one: every byte survives as prose.
    const header = "|" ++ ("a|" ** 33);
    const delim = "|" ++ ("-|" ** 33);
    const got = try outline(testing.allocator, header ++ "\n" ++ delim);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("text \"" ++ header ++ " " ++ delim ++ "\"\n", got);

    // At the cap it is still a table.
    const wide_ok = try outline(testing.allocator, "|" ++ ("a|" ** 32) ++ "\n|" ++ ("-|" ** 32));
    defer testing.allocator.free(wide_ok);
    try testing.expect(std.mem.startsWith(u8, wide_ok, "table\n"));
}

test "hard breaks survive as newlines; soft breaks become spaces" {
    const got = try outline(testing.allocator,
        \\line one  
        \\line two
        \\line three
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\text "line one
        \\line two line three"
        \\
    , got);
}

test "an unterminated fence still reads as code" {
    // The common shape of a truncated response.
    const got = try outline(testing.allocator,
        \\```
        \\const x = 1;
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\code_block "const x = 1;"
        \\
    , got);
}

test "a fence's leading blank line is verbatim, not swallowed" {
    const got = try outline(testing.allocator,
        \\```
        \\
        \\const x = 1;
        \\```
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\code_block "
        \\const x = 1;"
        \\
    , got);
}

test "the parser never panics on arbitrary bytes" {
    // The input is remote bytes, so the contract is `!void` and only
    // `!void`: no index may run off an end, whatever the markers do.
    const seeds = [_][]const u8{
        "",         "#",                                      "##########", "`",        "```",          "[",   "[]", "[](", "[](x", "*",  "**",   "***",
        ">",        ">>>>",                                   "-",          "- ",       "1.",           "1. ", "|",  "||",  "|-|",  "\\", "\\\\", "\n\n\n",
        "\r\n\r\n", "- \n  - \n    - \n      - \n        - ", "#\t",        "> - # `x", "\x00\x01\x02",
    };
    for (seeds) |seed| {
        var tree = try Tree.init(testing.allocator);
        defer tree.deinit();
        tree.append(tree.rootId(), .{ .document = .{ .label = "Doc", .source = seed } }) catch |err| {
            // An error is allowed; a crash is not.
            try testing.expect(err != error.OutOfMemory);
        };
    }
}

test "fuzz: arbitrary bytes never crash the parser" {
    // The input is remote bytes by design, so this is the contract that
    // matters most: whatever the fuzzer produces, an error is a fine
    // outcome and a crash is not.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var tree = try Tree.init(std.testing.allocator);
            defer tree.deinit();
            tree.append(tree.rootId(), .{ .document = .{ .label = "Doc", .source = input } }) catch {};
        }
    }.one, .{});
}

// ---- the document element ----

test "a document copies its source, so the app may free it at once" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    var source = "# Title\n\nSome words.".*;
    const doc = try tree.appendId(tree.rootId(), .{ .document = .{ .label = "Terms", .source = &source } });
    @memset(&source, 0);

    const got = try dump(testing.allocator, &tree, doc);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\heading h2 "Title"
        \\text "Some words."
        \\
    , got);
    try testing.expectEqualStrings("Terms", tree.getConst(doc).?.document.label);
}

test "a document needs a label; it is never derived from the first heading" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    // Deriving a name from the first h1 fails on documents that do not
    // open with one, and legal text often does not.
    try testing.expectError(error.UntitledDocument, tree.append(tree.rootId(), .{
        .document = .{ .label = "", .source = "# Terms" },
    }));
}

test "a parse the tree refuses surfaces as an append error, leaving nothing behind" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    const box = try tree.appendId(tree.rootId(), .{ .box = .{ .fill = .ink } });
    // Ink text on an ink fill is illegible, so `append` rejects the
    // paragraph — the parser's error path is append's. The half-built
    // document must not survive it.
    try testing.expectError(error.InsufficientTextContrast, tree.append(box, .{
        .document = .{ .label = "Terms", .source = "Words nobody could read." },
    }));
    try testing.expectEqual(@as(usize, 0), tree.childCount(box));
}
