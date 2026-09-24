const std = @import("std");

/// Remaps linear rasterizer coverage so black-on-white AA looks darker once
/// composited: a quadratic mid-coverage boost, strongest below ~24 device ppem.
pub const CoverageContrast = struct {
    enabled: bool = true,
    /// Artificial contrast in `[0, 1]`.
    contrast: f32 = 0.5,
    /// Device pixels per em; scales the effective contrast (stronger below
    /// ~24 ppem, gentler at Retina/display sizes).
    ppem: f32 = 24,

    pub fn effectiveContrast(self: CoverageContrast) f32 {
        if (!self.enabled) return 0;
        const base = std.math.clamp(self.contrast, 0, 1);
        if (self.ppem >= 28) return base * 0.65;
        if (self.ppem >= 24) return base * 0.85;
        return base;
    }

    pub fn lut(self: CoverageContrast) [256]u8 {
        if (!self.enabled) return identityLut();
        return buildContrastLut(self.effectiveContrast());
    }

    /// `lut()` at the default `contrast` for `ppem`, prebuilt: the
    /// effective contrast only takes three values across all ppem.
    pub fn defaultLut(ppem: f32) *const [256]u8 {
        return &default_luts[if (ppem >= 28) 2 else if (ppem >= 24) 1 else 0];
    }

    pub fn remap(self: CoverageContrast, coverage: u8) u8 {
        if (coverage == 0 or !self.enabled) return coverage;
        return self.lut()[coverage];
    }

    pub fn remapInPlace(self: CoverageContrast, pixels: []u8) void {
        if (!self.enabled) return;
        const table = self.lut();
        for (pixels) |*pixel| {
            if (pixel.* != 0) pixel.* = table[pixel.*];
        }
    }
};

const default_luts = default_luts: {
    @setEvalBranchQuota(20_000);
    var tables: [3][256]u8 = undefined;
    for (&tables, [_]f32{ 16, 24, 28 }) |*table, ppem| table.* = (CoverageContrast{ .ppem = ppem }).lut();
    break :default_luts tables;
};

fn identityLut() [256]u8 {
    var table: [256]u8 = undefined;
    for (0..256) |i| table[i] = @intCast(i);
    return table;
}

fn applyContrast(raw_alpha: f32, contrast: f32) f32 {
    return raw_alpha + (1.0 - raw_alpha) * contrast * raw_alpha;
}

fn buildContrastLut(contrast: f32) [256]u8 {
    var table: [256]u8 = undefined;
    var ii: f32 = 0;
    for (&table) |*entry| {
        const raw = ii / 255.0;
        ii += 1.0;
        const boosted = applyContrast(raw, contrast);
        entry.* = @intFromFloat(@round(std.math.clamp(boosted * 255.0, 0, 255)));
    }
    return table;
}

test "coverage contrast boosts mid coverage for black on white" {
    const cc: CoverageContrast = .{ .ppem = 16 };
    const lut = cc.lut();
    try std.testing.expectEqual(@as(u8, 0), lut[0]);
    try std.testing.expectEqual(@as(u8, 255), lut[255]);
    try std.testing.expect(lut[128] > 128);
    try std.testing.expect(lut[64] > 64);
}

test "coverage contrast disabled is identity" {
    const cc: CoverageContrast = .{ .enabled = false };
    const lut = cc.lut();
    for (0..256) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), lut[i]);
}

test "coverage contrast tapers at high ppem" {
    const small = (CoverageContrast{ .ppem = 16 }).effectiveContrast();
    const large = (CoverageContrast{ .ppem = 32 }).effectiveContrast();
    try std.testing.expect(small > large);
}

test "prebuilt default luts match lut()" {
    var ppem: f32 = 1;
    while (ppem < 100) : (ppem += 0.25) {
        const cc: CoverageContrast = .{ .ppem = ppem };
        try std.testing.expectEqualSlices(u8, &cc.lut(), CoverageContrast.defaultLut(ppem));
    }
}
