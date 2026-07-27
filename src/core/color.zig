//! Grayscale-only color. Thirteen fixed steps — the entire palette.
//! There is deliberately no way to construct any other value.
//!
//! A step is a *semantic* position, not a byte: each appearance supplies
//! its own ramp. Dark mode used to be a byte-exact inversion of light,
//! which is wrong twice over. Light-on-dark stems read heavier
//! (irradiation) and halation at the extremes is worst for astigmatic
//! readers, so dark should be *gentler* than light at equal authored
//! intent — and a mirror cannot do that, because it moves every ratio
//! together. The dark ramp below eases the body-text pair by a quarter
//! while holding the secondary-text and component-boundary ratios where
//! they already work.
//!
//! The semantic aliases are placed so that WCAG contrast holds by
//! construction in *both* appearances: `mid` on `paper` clears AA body
//! text (4.5:1), `dark` clears AAA, and `g7` is the lightest step that
//! clears non-text contrast (3:1) for component boundaries — the floor
//! a control's outline sits on. Contrast is also bounded *above* —
//! `ink` on `paper` is 14.2:1 light and 10.6:1 dark, not the 21:1 that
//! pure black on pure white would give. Tests below prove all of it;
//! changing a byte fails the build.

pub const Gray = enum(u8) {
    g0 = 0,
    g1 = 1,
    g2 = 2,
    g3 = 3,
    g4 = 4,
    g5 = 5,
    g6 = 6,
    g7 = 7,
    g8 = 8,
    g9 = 9,
    g10 = 10,
    g11 = 11,
    g12 = 12,

    /// Body text. `g2`, not `g0`: true black on true white is 21:1, past
    /// the point where contrast still buys legibility and into the range
    /// where it costs comfort. `g0` and `g12` remain in the palette for
    /// the escapes that genuinely want maximum modulation — the QR tile
    /// and the vendor sign-in marks, both of which draw through a
    /// light-pinned canvas (see `Canvas.light`).
    pub const ink: Gray = .g2;
    pub const dark: Gray = .g3;
    pub const mid: Gray = .g5;
    pub const light: Gray = .g9;
    pub const paper: Gray = .g12;

    /// Light ramp: thirteen evenly spaced bytes across the full range,
    /// with one deliberate exception. Even spacing puts `g7` at 0x95,
    /// which is 2.995:1 against paper — under the 1.4.11 floor by five
    /// thousandths. A step that fails the gate it exists to satisfy is
    /// worse than an uneven ramp, so `g7` is pulled one byte to 0x94
    /// (3.03:1). It is the only step placed by contrast rather than
    /// arithmetic, and it stays inside the spacing tolerance below.
    const light_ramp = [13]u8{
        0x00, 0x15, 0x2B, 0x40, 0x55, 0x6A, 0x80, 0x94, 0xAA, 0xBF, 0xD4, 0xEA, 0xFF,
    };

    /// Dark ramp: descending, and deliberately *not* the light ramp
    /// reversed. Solved against per-pair ratio targets — the text end is
    /// eased hard (ink 14.2:1 → 10.6:1), the secondary and boundary
    /// steps are held within a percent of their light values, and the
    /// surface steps keep enough elevation spacing that a raised surface
    /// still reads as raised.
    ///
    /// The page is true black. That is a choice, not an oversight: these
    /// targets are ratios *against the page*, so the page byte sets the
    /// whole ramp's altitude and the easing survives either way — it is
    /// the text end that had to come down to keep it (ink 0xC6 → 0xB8).
    /// Pure black costs nothing on a raster display and switches OLED
    /// pixels off outright, which is most of nokre's mobile surface.
    /// Note this is the *page*, never the text: light-on-dark halation
    /// scales with the luminance step at the glyph edge, and 10.6:1 is
    /// where that step was argued down to.
    const dark_ramp = [13]u8{
        0xDE, 0xCD, 0xB8, 0xA5, 0x91, 0x80, 0x6B, 0x5A, 0x49, 0x3B, 0x2C, 0x15, 0x00,
    };

    pub fn byte(self: Gray, appearance: Appearance) u8 {
        const ramp = switch (appearance) {
            .light => light_ramp,
            .dark => dark_ramp,
        };
        return ramp[@intFromEnum(self)];
    }

    /// WCAG 2.x contrast ratio between two steps in one appearance,
    /// 1.0–21.0. Ratios are *not* preserved across appearances — the two
    /// ramps are independent — so anything that gates on contrast must
    /// ask about both (see `Tree.validateAppend`).
    pub fn contrastWith(self: Gray, other: Gray, appearance: Appearance) f64 {
        const la = luminance(self.byte(appearance));
        const lb = luminance(other.byte(appearance));
        const hi = @max(la, lb);
        const lo = @min(la, lb);
        return (hi + 0.05) / (lo + 0.05);
    }

    fn luminance(b: u8) f64 {
        const c = @as(f64, @floatFromInt(b)) / 255.0;
        return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
    }
};

/// Minimum contrast for text against its background (WCAG AA, body size).
pub const min_text_contrast: f64 = 4.5;
/// Maximum contrast for text against its background. WCAG 2.x only has a
/// floor, because it treats contrast as monotonically good; APCA and the
/// WCAG 3 draft do not, and neither does anyone who has read body text
/// at 21:1. The palette cannot express a text pair above this, and
/// `Tree.validateAppend` rejects one an app authors by hand.
pub const max_text_contrast: f64 = 16.0;
/// Minimum contrast for component boundaries and state indicators
/// (WCAG 1.4.11 non-text contrast).
pub const min_component_contrast: f64 = 3.0;

/// The gate every element drawing text on an ambient ground faces, at
/// append and again in the audit. It asks about *both* appearances on
/// purpose: the ramps are independent, so a pair can clear the floor in
/// light and fall under it in dark — twenty such pairs exist — and
/// checking one appearance is checking half the app.
pub fn checkTextPair(ink: Gray, bg: Gray) error{ InsufficientTextContrast, ExcessiveTextContrast }!void {
    for ([_]Appearance{ .light, .dark }) |a| {
        const c = ink.contrastWith(bg, a);
        if (c < min_text_contrast) return error.InsufficientTextContrast;
        if (c > max_text_contrast) return error.ExcessiveTextContrast;
    }
}

/// What the OS reports.
pub const Appearance = enum { light, dark };

/// What the app asks for; `.auto` follows the OS.
pub const Scheme = enum {
    light,
    dark,
    auto,

    pub fn resolve(self: Scheme, system: Appearance) Appearance {
        return switch (self) {
            .light => .light,
            .dark => .dark,
            .auto => system,
        };
    }
};

const std = @import("std");

const appearances = [_]Appearance{ .light, .dark };

test "light ramp is evenly spaced across the full range" {
    // Tolerance is a byte, which is what rounding needs — and what the
    // one contrast-placed step (g7, see `light_ramp`) fits inside.
    inline for (@typeInfo(Gray).@"enum".fields, 0..) |f, i| {
        const g: Gray = @enumFromInt(f.value);
        const ideal = @as(f64, @floatFromInt(i)) * 255.0 / 12.0;
        try std.testing.expect(@abs(@as(f64, @floatFromInt(g.byte(.light))) - ideal) <= 1.0);
    }
}

test "both ramps are monotone and use thirteen distinct bytes" {
    for (appearances) |a| {
        var seen: [256]bool = @splat(false);
        var prev: i32 = -1;
        inline for (@typeInfo(Gray).@"enum".fields) |f| {
            const g: Gray = @enumFromInt(f.value);
            const b: i32 = g.byte(a);
            try std.testing.expect(!seen[@intCast(b)]);
            seen[@intCast(b)] = true;
            if (prev >= 0) switch (a) {
                // Light ascends from ink to paper; dark descends — that
                // descent *is* the inversion, so no draw site inverts.
                .light => try std.testing.expect(b > prev),
                .dark => try std.testing.expect(b < prev),
            };
            prev = b;
        }
    }
}

test "middle step is the 50-50 gray in light" {
    try std.testing.expectEqual(@as(u8, 0x80), Gray.g6.byte(.light));
}

test "design proof: text aliases sit inside the readable band, both appearances" {
    for (appearances) |a| {
        for ([_]Gray{ .ink, .dark, .mid }) |text_ink| {
            const c = text_ink.contrastWith(.paper, a);
            try std.testing.expect(c >= min_text_contrast);
            try std.testing.expect(c <= max_text_contrast);
        }
        try std.testing.expect(Gray.dark.contrastWith(.paper, a) >= 7.0); // AAA
    }
}

test "design proof: dark eases text, it does not mirror it" {
    // The whole reason dark carries its own ramp. Every text alias must
    // be *gentler* against paper in dark than in light — an inversion
    // gives equality at best, and for the pairs that matter here it gave
    // worse. Component boundaries are exempt: they are hairlines, not
    // reading surfaces, and are held near their light values instead.
    for ([_]Gray{ .ink, .dark, .mid }) |text_ink| {
        const l = text_ink.contrastWith(.paper, .light);
        const d = text_ink.contrastWith(.paper, .dark);
        try std.testing.expect(d <= l);
    }
    // …and eased by a real margin at the body-text pair, not a rounding.
    try std.testing.expect(Gray.ink.contrastWith(.paper, .dark) <= 0.85 * Gray.ink.contrastWith(.paper, .light));
}

test "design proof: component boundaries clear WCAG non-text contrast" {
    // g7 is the lightest step permitted for a border on paper — the
    // field outlines use it; the focus indicator is `ink` (below).
    for (appearances) |a| {
        for ([_]Gray{ .g6, .g7, .dark }) |boundary| {
            try std.testing.expect(boundary.contrastWith(.paper, a) >= min_component_contrast);
        }
        // "Lightest permitted" is a claim, so prove the next step up is
        // not: nothing may reach for g8 as a control boundary.
        try std.testing.expect(Gray.g8.contrastWith(.paper, a) < min_component_contrast);
        // Selected chips (segmented, nav): paper fill on the .g11 track is
        // non-compliant alone, so the .g6 border must clear 1.4.11 against
        // both the chip and the track. This is why the field outlines'
        // lighter g7 cannot be adopted everywhere — against g11 it is
        // 2.5:1, and only g6 clears the track on both sides.
        for ([_]Gray{ .paper, .g11 }) |side| {
            try std.testing.expect(Gray.g6.contrastWith(side, a) >= min_component_contrast);
        }
        try std.testing.expect(Gray.g7.contrastWith(.g11, a) < min_component_contrast);
        // A raised surface must stay off the page it sits on, or the
        // notice band and the segmented track vanish into it.
        try std.testing.expect(Gray.g11.contrastWith(.paper, a) > 1.1);

        // The nav's bar is three levels — page, destination, current —
        // because it has no track to lift a chip off any more. Each step
        // must stay visible from the one below it.
        try std.testing.expect(Gray.g10.contrastWith(.g11, a) > 1.1);
        // Its current chip climbs to g10, and g6 does not survive the
        // move: 2.7:1 against that fill, under the floor. The border
        // steps down with the surface — `mid` is the lightest tone that
        // clears 1.4.11 on *both* of the chip's sides, which is the same
        // rule that picked g6 for a chip on the g11 track.
        for ([_]Gray{ .g10, .paper }) |side| {
            try std.testing.expect(Gray.mid.contrastWith(side, a) >= min_component_contrast);
        }
        try std.testing.expect(Gray.g6.contrastWith(.g10, a) < min_component_contrast);
    }
}

test "design proof: the focus indicator survives replacing an outline" {
    // The indicator is one stroke in `ink` — where an element owns an
    // outline at rest, focus *replaces* it rather than drawing a second
    // line beside it (renderer.zig). That makes WCAG 2.4.13's
    // focused-vs-unfocused 3:1 a question about the same pixel changing
    // tone, not about a stroke appearing on bare ground, and it is what
    // rules `dark` out: over a field's `g7` outline the old ring tone is
    // 2.8:1 in the dark ramp.
    for (appearances) |a| {
        try std.testing.expect(Gray.g7.contrastWith(.ink, a) >= min_component_contrast);
        try std.testing.expect(Gray.dark.contrastWith(.g7, .dark) < min_component_contrast);
        // And 1.4.11 against every ground it is drawn on: the page and
        // the raised track the nav and picker chips sit in.
        for ([_]Gray{ .paper, .g11 }) |ground| {
            try std.testing.expect(Gray.ink.contrastWith(ground, a) >= min_component_contrast);
        }
        // The one place that delta is not met: a chip that is *both*
        // selected and focused starts from a `g6` outline, which `ink`
        // clears by 3.6:1 in light and only 2.7:1 in dark — so half of
        // that indicator's 2px perimeter carries the change instead of
        // all of it. The selection fill states it a second way, and the
        // alternative is a 3px stroke on a 44px row.
        try std.testing.expect(Gray.g6.contrastWith(.ink, .light) >= min_component_contrast);
        try std.testing.expect(Gray.g6.contrastWith(.ink, .dark) < min_component_contrast);
    }
}

test "design proof: the escapes still reach true ink and true paper" {
    // QR tiles and vendor sign-in marks draw through a light-pinned
    // canvas precisely so these two hold; see renderer.zig.
    try std.testing.expectEqual(@as(u8, 0x00), Gray.g0.byte(.light));
    try std.testing.expectEqual(@as(u8, 0xFF), Gray.g12.byte(.light));
    try std.testing.expectEqual(@as(f64, 21.0), @round(Gray.g0.contrastWith(.g12, .light)));
}

test "scheme resolution" {
    try std.testing.expectEqual(Appearance.light, Scheme.light.resolve(.dark));
    try std.testing.expectEqual(Appearance.dark, Scheme.dark.resolve(.light));
    try std.testing.expectEqual(Appearance.dark, Scheme.auto.resolve(.dark));
    try std.testing.expectEqual(Appearance.light, Scheme.auto.resolve(.light));
}
