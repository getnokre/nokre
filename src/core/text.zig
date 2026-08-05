//! Typography. Three bundled font families (two for text, one for the
//! framework's icon glyphs), six fixed scales. The text families carry
//! bold, italic, and bold-italic variants — real drawn faces from the
//! same upstream builds as the regulars, never synthetic emboldening or
//! shearing, which would re-open the rasterizer variance the bundled
//! fonts exist to close.
//! All metrics are fixed integers — text layout is deterministic by
//! construction. Width measurement goes through a `Measurer` so the pure
//! core never depends on Skia; the real measurer is backed by the shim,
//! tests use `Measurer.fixed`.

const geometry = @import("geometry.zig");
const bidi = @import("bidi.zig");

pub const Family = enum {
    mono,
    prose,
    icons,
    /// The vendor sign-in marks, and nothing else
    /// (src/assets/fonts/LICENSE-Brand.txt). A closed set of trademark
    /// glyphs — five: Apple's logo and the Google G's four arcs —
    /// reachable only from the renderer's provider-form button arm. A
    /// span or a text element cannot name it, in the strong sense: the
    /// style they carry is a `BodyFamily`, which has no such member, so
    /// the misuse is a compile error rather than a rule to police.
    brand,
};

// The ordinals are a wire contract: the DOM driver sends
// `@intFromEnum(face.family)` across the wasm boundary and services.js
// indexes its FAMILIES table with it. Append only; a reorder here
// without services.js re-fonts every measured run.
comptime {
    const assert = @import("std").debug.assert;
    assert(@intFromEnum(Family.mono) == 0 and @intFromEnum(Family.brand) == 3 and @typeInfo(Family).@"enum".fields.len == 4);
}

/// The families app text may name. Two of `Family`'s four are the
/// framework's own — `icons` is reached through the `Icon` element,
/// which carries the decorative-vs-labeled discipline, and `brand` only
/// through the renderer's provider-button arm — so a `Style` carries
/// this instead of `Family` and the guarantee needs no door to enforce
/// it: `.family = .brand` is a name that does not exist. Nothing here
/// crosses a wire; `Family`'s ordinals are the pinned ones.
pub const BodyFamily = enum { mono, prose };

/// A concrete drawable face: family plus variant. This is what the
/// measurer and the canvas speak — spans resolve to it, everything else
/// uses the regular decl literals (`.prose`, `.mono`, `.icons`). The
/// icon and brand families have no variants; their flags are ignored by
/// the backend.
pub const Face = struct {
    family: Family = .prose,
    bold: bool = false,
    italic: bool = false,

    pub const mono: Face = .{ .family = .mono };
    pub const prose: Face = .{ .family = .prose };
    pub const icons: Face = .{ .family = .icons };
    pub const brand: Face = .{ .family = .brand };
};

pub const Scale = enum {
    small,
    body,
    h4,
    h3,
    h2,
    h1,

    pub fn px(self: Scale) i32 {
        return switch (self) {
            .small => 12,
            .body => 16,
            .h4 => 18,
            .h3 => 20,
            .h2 => 24,
            .h1 => 32,
        };
    }

    pub fn lineHeight(self: Scale) i32 {
        return switch (self) {
            .small => 16,
            .body => 24,
            .h4 => 26,
            .h3 => 28,
            .h2 => 32,
            .h1 => 40,
        };
    }

    /// Baseline offset from the top of the line box.
    pub fn baseline(self: Scale) i32 {
        return self.lineHeight() - @divTrunc(self.lineHeight() - self.px(), 2) - @divTrunc(self.px(), 5);
    }
};

pub const Style = struct {
    family: BodyFamily = .prose,
    scale: Scale = .body,
    ink: @import("color.zig").Gray = .ink,

    /// The style's regular face; spans derive their variants from it.
    /// The one seam between what an app may name and the full bundled
    /// set — widening happens here or nowhere, which is what keeps the
    /// two reserved faces the renderer's alone.
    pub fn face(self: Style) Face {
        return .{ .family = switch (self.family) {
            .mono => .mono,
            .prose => .prose,
        } };
    }
};

pub const Measurer = struct {
    ctx: ?*anyopaque = null,
    measureFn: *const fn (ctx: ?*anyopaque, face: Face, size_px: i32, bytes: []const u8) i32,

    /// Width of arbitrary text. Complex text (Arabic script or strong
    /// RTL present) is segmented into measure runs — the same runs the
    /// renderer draws — and summed, so every width in the system is a
    /// sum over identically shaped pieces; see bidi.measureRuns. Plain
    /// text is a single run and costs one scan extra.
    pub fn measure(self: Measurer, face: Face, size_px: i32, bytes: []const u8) i32 {
        if (!bidi.isComplex(bytes)) return self.measureRun(face, size_px, bytes);
        var w: i32 = 0;
        var it = bidi.measureRuns(bytes);
        while (it.next()) |run| w += self.measureRun(face, size_px, run.bytes);
        return w;
    }

    /// Width of one already-segmented run: the bytes must not mix
    /// scripts or directions (backends shape the whole buffer as a
    /// single run — the Skia shim picks face and direction per call).
    pub fn measureRun(self: Measurer, face: Face, size_px: i32, bytes: []const u8) i32 {
        return self.measureFn(self.ctx, face, size_px, bytes);
    }

    /// Deterministic stand-in used by unit tests and the headless harness:
    /// every codepoint is 3/5 of the font size wide.
    pub const fixed: Measurer = .{ .measureFn = fixedMeasure };

    fn fixedMeasure(_: ?*anyopaque, _: Face, size_px: i32, bytes: []const u8) i32 {
        var n: i32 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (it.nextCodepoint()) |_| n += 1;
        return n * @divTrunc(size_px * 3, 5);
    }
};

const std = @import("std");

test "fixed measurer counts codepoints, not bytes" {
    const w_ascii = Measurer.fixed.measure(.prose, 20, "ab");
    const w_multi = Measurer.fixed.measure(.prose, 20, "éé");
    try std.testing.expectEqual(w_ascii, w_multi);
    try std.testing.expectEqual(@as(i32, 24), w_ascii);
}

test "a style can name only the two app families" {
    // The refusal itself is comptime — `.{ .family = .brand }` does not
    // compile — so what runs here is the shape that makes it so: the
    // field's type, whatever it is called, offers two members and
    // neither is a reserved face. Widen it back to `Family` and this
    // fails before any renderer is asked to draw a trademark as prose.
    const Named = @FieldType(Style, "family");
    const fields = @typeInfo(Named).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    inline for (fields) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.name, "icons"));
        try std.testing.expect(!std.mem.eql(u8, f.name, "brand"));
    }
    // And the seam still widens what it may: both app faces reach the
    // drawable set unchanged.
    try std.testing.expectEqual(Face.prose, (Style{}).face());
    try std.testing.expectEqual(Face.mono, (Style{ .family = .mono }).face());
}

test "scales are monotonic" {
    try std.testing.expect(Scale.small.px() < Scale.body.px());
    try std.testing.expect(Scale.body.px() < Scale.h4.px());
    try std.testing.expect(Scale.h4.px() < Scale.h3.px());
    try std.testing.expect(Scale.h3.px() < Scale.h2.px());
    try std.testing.expect(Scale.h2.px() < Scale.h1.px());
}

comptime {
    _ = geometry;
}
