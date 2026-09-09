const std = @import("std");
const common = @import("common.zig");
const GlyphInfo = common.GlyphInfo;
const GlyphPosition = common.GlyphPosition;

/// How a width-driven break search picks its final glyph when the
/// requested width falls between two glyph boundaries.
pub const EndMetric = enum { before, nearest };

/// Bounding-box + ink-origin metrics for one glyph, independent of any
/// rasterization/texture-cache backing -- callers duck-type against this
/// shape (any type with these four f32 fields works, see `measureGlyphRange`).
pub const GlyphMetrics = struct {
    leftBearing: f32,
    topBearing: f32,
    w: f32,
    h: f32,
};

/// Size (device pixels) of shaped glyphs `info[0..glyph_limit]`/`pos[0..glyph_limit]`
/// -- no reshaping, no width-break search. `provider` supplies per-glyph ink
/// metrics and font-unit-to-pixel conversion via duck typing: it must expose
/// `glyphInfoGet(gpa, codepoint: u32) !T` (T with `GlyphMetrics`'s fields) and
/// `toPixels(font_units: i32) f32`.
pub fn measureGlyphRange(
    gpa: std.mem.Allocator,
    provider: anytype,
    ascent: f32,
    height: f32,
    info: []const GlyphInfo,
    pos: []const GlyphPosition,
    glyph_limit: usize,
    snap: bool,
) !struct { w: f32, h: f32 } {
    var x: f32 = 0;
    var minx: f32 = 0;
    var maxx: f32 = 0;
    var miny: f32 = 0;
    var maxy: f32 = height;
    const limit = @min(glyph_limit, info.len);
    for (info[0..limit], pos[0..limit]) |gi_in, p| {
        const gi = try provider.glyphInfoGet(gpa, gi_in.codepoint);
        const off_x = provider.toPixels(p.x_offset);
        const adv = provider.toPixels(p.x_advance);
        const adv_used = if (snap) @round(adv) else adv;

        minx = @min(minx, x + off_x + gi.leftBearing);
        maxx = @max(maxx, x + off_x + gi.leftBearing + gi.w);
        maxx = @max(maxx, x + adv_used);

        miny = @min(miny, ascent - gi.topBearing);
        maxy = @max(maxy, ascent - gi.topBearing + gi.h);

        x += adv_used;
    }
    return .{ .w = maxx - minx, .h = maxy - miny };
}
