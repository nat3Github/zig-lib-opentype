/// How a width-driven break search picks its final glyph when the
/// requested width falls between two glyph boundaries.
pub const EndMetric = enum { before, nearest };

/// Device-pixel extent of a measured glyph range.
pub const Size = struct { w: f32, h: f32 };

/// Bounding-box + ink-origin metrics for one glyph, independent of any
/// rasterization/texture-cache backing -- callers duck-type against this
/// shape (any type with these four f32 fields works, see
/// `ShapedLine.measureGlyphs`).
pub const GlyphMetrics = struct {
    leftBearing: f32,
    topBearing: f32,
    w: f32,
    h: f32,
};
