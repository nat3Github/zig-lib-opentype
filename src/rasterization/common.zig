const std = @import("std");
pub const IPoint = struct { x: i32, y: i32 };
pub const ScaledPoint = struct { p: IPoint, on: bool };
pub const DrawOp = struct { bitmap: Bitmap8bit, paint: CoverageMaskFillSource };

pub const RasterizeColrError = parsing.Font.ParseError || RasterizeError || error{ColrPaintNestingTooDeep};

const mask_gamma = @import("mask_gamma.zig");
const Rasterizer = @import("rasterizer.zig").Rasterizer;
const parsing = @import("../parsing.zig");
const rasterization = @import("../rasterization.zig");
const CoverageContrast = mask_gamma.CoverageContrast;
const Bitmap8bit = rasterization.Bitmap8bit;
const RasterizeError = rasterization.RasterizeError;
const SubpixelOffset = rasterization.SubpixelOffset;
const BitmapRgba8bit = rasterization.BitmapRgba8bit;
const GradientStop = rasterization.GradientStop;
const Rgba = rasterization.Rgba;
const CoverageMaskFillSource = rasterization.CoverageMaskFillSource;
const GradientPoint = rasterization.GradientPoint;
const GradientGeometry = rasterization.GradientGeometry;

pub const pixel_bits: u5 = 8;
pub const one_pixel: i32 = 1 << pixel_bits;

pub fn trunc(x: i32) i32 {
    return x >> pixel_bits;
}

pub fn fract(x: i32) i32 {
    return x & (one_pixel - 1);
}

pub fn upscale(x: i32) i32 {
    return x * (one_pixel >> 6);
}

/// Composites a flat op list (painter's-algorithm order, src-over) into a
/// single RGBA canvas sized to the union of all layers — shared by
/// `rasterizeColr`'s top-level result and `renderSubgraph`'s
/// `PaintComposite` sub-graph rendering.
pub fn compositeOpsToCanvas(
    allocator: std.mem.Allocator,
    ops: []const DrawOp,
    coverage_contrast: CoverageContrast,
) RasterizeColrError!BitmapRgba8bit {
    const coverage_lut = coverage_contrast.lut();
    if (ops.len == 0) {
        return .{ .width = 0, .rows = 0, .left = 0, .top = 0, .pixels_row_major = try allocator.alloc(u8, 0) };
    }

    var union_left: i32 = std.math.maxInt(i32);
    var union_top: i32 = std.math.minInt(i32);
    var union_right: i32 = std.math.minInt(i32);
    var union_bottom: i32 = std.math.maxInt(i32);
    for (ops) |op| {
        const b = op.bitmap;
        union_left = @min(union_left, b.left);
        union_top = @max(union_top, b.top);
        union_right = @max(union_right, b.left + @as(i32, @intCast(b.width)));
        union_bottom = @min(union_bottom, b.top - @as(i32, @intCast(b.rows)));
    }

    const width: u32 = @intCast(union_right - union_left);
    const rows: u32 = @intCast(union_top - union_bottom);
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, rows) * 4);
    @memset(pixels, 0);

    for (ops) |op| {
        const b = op.bitmap;
        const dst_x0: usize = @intCast(b.left - union_left);
        const dst_y0: usize = @intCast(union_top - b.top);
        var row: usize = 0;
        while (row < b.rows) : (row += 1) {
            var col: usize = 0;
            while (col < b.width) : (col += 1) {
                const coverage = coverage_lut[b.pixels_row_major[row * b.width + col]];
                if (coverage == 0) continue;

                const sample: ?ColorSample = switch (op.paint) {
                    .solid => |s| .{ .color = s.color, .alpha = s.alpha },
                    .gradient => |g| blk: {
                        // Pixel-center device coords, matching `rasterizeGlyfAffine`/
                        // `rasterizeCffAffine`'s bitmap convention (row 0 = top,
                        // `b.top` is the y-max pixel boundary, `b.left` the x-min one).
                        const device_x = @as(f64, @floatFromInt(b.left + @as(i32, @intCast(col)))) + 0.5;
                        const device_y = @as(f64, @floatFromInt(b.top - @as(i32, @intCast(row)))) - 0.5;
                        const local = g.inverse.apply(device_x, device_y);
                        const t = gradientT(g.geometry, local.x, local.y) orelse break :blk null;
                        break :blk resolveColorLine(g.stops, g.extend, t);
                    },
                    .image => |im| blk: {
                        const px = (row * b.width + col) * 4;
                        const rgba: Rgba = .{ .r = im.rgba[px], .g = im.rgba[px + 1], .b = im.rgba[px + 2], .a = im.rgba[px + 3] };
                        break :blk .{ .color = rgba, .alpha = @as(f32, @floatFromInt(rgba.a)) / 255.0 };
                    },
                    .pattern => |p| blk: {
                        if (p.width == 0 or p.height == 0) break :blk null;
                        const device_x = @as(f64, @floatFromInt(b.left + @as(i32, @intCast(col)))) + 0.5;
                        const device_y = @as(f64, @floatFromInt(b.top - @as(i32, @intCast(row)))) - 0.5;
                        const local = p.inverse.apply(device_x, device_y);
                        const pw: f64 = @floatFromInt(p.width);
                        const ph: f64 = @floatFromInt(p.height);
                        const sx = extendPatternCoord(local.x, pw, p.extend);
                        const sy = extendPatternCoord(local.y, ph, p.extend);
                        const ix: usize = @intFromFloat(std.math.clamp(@floor(sx), 0, pw - 1));
                        const iy: usize = @intFromFloat(std.math.clamp(@floor(sy), 0, ph - 1));
                        const src_px = (iy * p.width + ix) * 4;
                        const rgba: Rgba = .{ .r = p.rgba[src_px], .g = p.rgba[src_px + 1], .b = p.rgba[src_px + 2], .a = p.rgba[src_px + 3] };
                        break :blk .{ .color = rgba, .alpha = @as(f32, @floatFromInt(rgba.a)) / 255.0 };
                    },
                };
                const resolved = sample orelse continue;
                if (resolved.alpha <= 0) continue;

                const src_alpha = resolved.alpha * (@as(f32, @floatFromInt(coverage)) / 255.0);
                const px = ((dst_y0 + row) * width + (dst_x0 + col)) * 4;
                const dst: Rgba = .{
                    .r = pixels[px],
                    .g = pixels[px + 1],
                    .b = pixels[px + 2],
                    .a = pixels[px + 3],
                };
                const blended = srcOver(dst, resolved.color, src_alpha);
                pixels[px] = blended.r;
                pixels[px + 1] = blended.g;
                pixels[px + 2] = blended.b;
                pixels[px + 3] = blended.a;
            }
        }
    }

    return .{ .width = width, .rows = rows, .left = union_left, .top = union_top, .pixels_row_major = pixels };
}

/// `FT_MulFix`: `round(|a * b| / 65536)`, sign of `a * b`.
pub fn ftMulFix(a: i32, b: i32) i32 {
    const sign: i64 = if ((a < 0) != (b < 0)) -1 else 1;
    const ua: i64 = @abs(a);
    const ub: i64 = @abs(b);
    const mag: i64 = @divFloor(ua * ub + 0x8000, 0x10000);
    return @intCast(sign * mag);
}

/// `FT_DivFix`: `round(|a| * 65536 / |b|)`, sign of `a * b`.
pub fn ftDivFix(a: i32, b: i32) i32 {
    const sign: i64 = if ((a < 0) != (b < 0)) -1 else 1;
    const ua: i64 = @abs(a);
    const ub: i64 = @abs(b);
    const mag: i64 = @divFloor(ua * 0x10000 + @divFloor(ub, 2), ub);
    return @intCast(sign * mag);
}

/// `FT_PIX_ROUND`: nearest-pixel grid-fit of an F26Dot6 coordinate.
pub fn ftPixRound(x: i32) i32 {
    return (x + 32) & ~@as(i32, 63);
}
/// Coverage byte from accumulated cell area, non-zero winding fill rule
/// (`FT_FILL_RULE` with `fill = INT_MIN`). `glyf` never sets even-odd fill.
pub fn fillRuleNonZero(area: i64) u8 {
    var coverage = area >> (pixel_bits * 2 + 1 - 8);
    if (coverage < 0) coverage = ~coverage;
    if (coverage > 255) coverage = 255;
    return @intCast(coverage);
}

pub const IScaledCffSegment = union(enum) {
    move_to: IPoint,
    line_to: IPoint,
    curve_to: struct { c1: IPoint, c2: IPoint, to: IPoint },
};

pub fn scaleCffPoint(p: parsing.Table.cff.Point, scale: i32, phase: SubpixelOffset) IPoint {
    return .{ .x = ftMulFix(p.x, scale) + phase.x, .y = ftMulFix(p.y, scale) + phase.y };
}
/// Grid-fits the control box of already-scaled (F26Dot6) `points` and
/// sweeps them into an AA coverage bitmap — the common tail of
/// `rasterizeGlyf`/`rasterizeGlyfAffine`/`rasterizeGlyfHinted` once each has
/// produced its own scaled point set.
pub fn renderScaledPoints(
    allocator: std.mem.Allocator,
    points: []ScaledPoint,
    end_points_of_contours: []const u16,
) RasterizeError!Bitmap8bit {
    var cbox_min_x: i32 = std.math.maxInt(i32);
    var cbox_min_y: i32 = std.math.maxInt(i32);
    var cbox_max_x: i32 = std.math.minInt(i32);
    var cbox_max_y: i32 = std.math.minInt(i32);
    for (points) |sp| {
        cbox_min_x = @min(cbox_min_x, sp.p.x);
        cbox_min_y = @min(cbox_min_y, sp.p.y);
        cbox_max_x = @max(cbox_max_x, sp.p.x);
        cbox_max_y = @max(cbox_max_y, sp.p.y);
    }

    const x_min_px = cbox_min_x >> 6;
    const y_min_px = cbox_min_y >> 6;
    const x_max_px = (cbox_max_x + 63) >> 6;
    const y_max_px = (cbox_max_y + 63) >> 6;

    const width = x_max_px - x_min_px;
    const height = y_max_px - y_min_px;
    if (width <= 0 or height <= 0) {
        return .{ .width = 0, .rows = 0, .left = x_min_px, .top = y_max_px, .pixels_row_major = try allocator.alloc(u8, 0) };
    }

    for (points) |*sp| {
        sp.p.x -= 64 * x_min_px;
        sp.p.y -= 64 * y_min_px;
    }

    var raster = try Rasterizer.init(allocator, width, height);
    defer raster.deinit();

    // end_points_of_contours isn't validated at parse time (parsing.zig only
    // checks the last entry against points.len); a malformed glyf table can
    // ship non-monotonic or out-of-range entries here, so skip rather than
    // slice-panic on those instead of trusting the index math.
    var contour_start: usize = 0;
    for (end_points_of_contours) |end_index| {
        defer contour_start = @as(usize, end_index) + 1;
        if (end_index < contour_start or end_index >= points.len) continue;
        const contour = points[contour_start .. @as(usize, end_index) + 1];
        try decomposeContour(&raster, contour);
    }

    const pixels = try allocator.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    @memset(pixels, 0);
    raster.sweep(pixels, width);

    return .{
        .width = @intCast(width),
        .rows = @intCast(height),
        .left = x_min_px,
        .top = y_max_px,
        .pixels_row_major = pixels,
    };
}

/// Grid-fits the control box of already-scaled (F26Dot6) cubic `segments`
/// and sweeps them into an AA coverage bitmap — the CFF/cubic analogue of
/// `renderScaledPoints`, shared by `rasterizeCff` and `rasterizeCffHinted`
/// once each has produced its own scaled segment list.
pub fn renderScaledCffSegments(allocator: std.mem.Allocator, segments: []IScaledCffSegment) RasterizeError!Bitmap8bit {
    var cbox_min_x: i32 = std.math.maxInt(i32);
    var cbox_min_y: i32 = std.math.maxInt(i32);
    var cbox_max_x: i32 = std.math.minInt(i32);
    var cbox_max_y: i32 = std.math.minInt(i32);
    for (segments) |segment| {
        switch (segment) {
            .move_to => |p| trackBox(p, &cbox_min_x, &cbox_min_y, &cbox_max_x, &cbox_max_y),
            .line_to => |p| trackBox(p, &cbox_min_x, &cbox_min_y, &cbox_max_x, &cbox_max_y),
            .curve_to => |c| {
                trackBox(c.c1, &cbox_min_x, &cbox_min_y, &cbox_max_x, &cbox_max_y);
                trackBox(c.c2, &cbox_min_x, &cbox_min_y, &cbox_max_x, &cbox_max_y);
                trackBox(c.to, &cbox_min_x, &cbox_min_y, &cbox_max_x, &cbox_max_y);
            },
        }
    }

    const x_min_px = cbox_min_x >> 6;
    const y_min_px = cbox_min_y >> 6;
    const x_max_px = (cbox_max_x + 63) >> 6;
    const y_max_px = (cbox_max_y + 63) >> 6;

    const width = x_max_px - x_min_px;
    const height = y_max_px - y_min_px;
    if (width <= 0 or height <= 0) {
        return .{ .width = 0, .rows = 0, .left = x_min_px, .top = y_max_px, .pixels_row_major = try allocator.alloc(u8, 0) };
    }

    for (segments) |*segment| {
        switch (segment.*) {
            .move_to => |*p| translateBox(p, x_min_px, y_min_px),
            .line_to => |*p| translateBox(p, x_min_px, y_min_px),
            .curve_to => |*c| {
                translateBox(&c.c1, x_min_px, y_min_px);
                translateBox(&c.c2, x_min_px, y_min_px);
                translateBox(&c.to, x_min_px, y_min_px);
            },
        }
    }

    var raster = try Rasterizer.init(allocator, width, height);
    defer raster.deinit();

    try Rasterizer.decomposeCffSegments(&raster, segments);

    const pixels = try allocator.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    @memset(pixels, 0);
    raster.sweep(pixels, width);

    return .{
        .width = @intCast(width),
        .rows = @intCast(height),
        .left = x_min_px,
        .top = y_max_px,
        .pixels_row_major = pixels,
    };
}

fn trackBox(p: IPoint, min_x: *i32, min_y: *i32, max_x: *i32, max_y: *i32) void {
    min_x.* = @min(min_x.*, p.x);
    min_y.* = @min(min_y.*, p.y);
    max_x.* = @max(max_x.*, p.x);
    max_y.* = @max(max_y.*, p.y);
}

fn translateBox(p: *IPoint, x_min_px: i32, y_min_px: i32) void {
    p.x -= 64 * x_min_px;
    p.y -= 64 * y_min_px;
}

/// `COLR` spec, "Extend" modes (pad/repeat/reflect), applied over stops
/// assumed sorted by `offset` ascending (true for any spec-conformant
/// font; a font with unsorted stops is out of scope, NOTE: no sort).
/// Duplicate-offset "first stop below / last stop at-or-above" tie-break
/// is not special-cased — real fonts essentially never hit it.
const ColorSample = struct { color: Rgba, alpha: f32 };

fn resolveColorLine(stops: []const GradientStop, extend: u8, t_in: f64) ColorSample {
    if (stops.len == 1) return .{ .color = stops[0].color, .alpha = stops[0].alpha };

    const lo = stops[0].offset;
    const hi = stops[stops.len - 1].offset;
    var t = t_in;
    if (hi <= lo) {
        t = if (t < lo) lo - 1 else hi;
    } else {
        const span = hi - lo;
        switch (extend) {
            1 => t = lo + @mod(t - lo, span), // repeat
            2 => { // reflect
                const m = @mod(t - lo, 2.0 * span);
                t = if (m <= span) lo + m else lo + (2.0 * span - m);
            },
            else => t = std.math.clamp(t, lo, hi), // pad (also the fallback for an invalid extend value)
        }
    }

    var i: usize = 1;
    while (i < stops.len and stops[i].offset < t) : (i += 1) {}
    if (i >= stops.len) return .{ .color = stops[stops.len - 1].color, .alpha = stops[stops.len - 1].alpha };
    if (i == 0) return .{ .color = stops[0].color, .alpha = stops[0].alpha };

    const a = stops[i - 1];
    const b = stops[i];
    if (b.offset == a.offset) return .{ .color = b.color, .alpha = b.alpha };
    const f = (t - a.offset) / (b.offset - a.offset);
    const lerpU8 = struct {
        fn lerpU8(x: u8, y: u8, w: f64) u8 {
            return @intFromFloat(@round(@as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(x))) * w));
        }
    }.lerpU8;
    return .{
        .color = .{
            .r = lerpU8(a.color.r, b.color.r, f),
            .g = lerpU8(a.color.g, b.color.g, f),
            .b = lerpU8(a.color.b, b.color.b, f),
            .a = lerpU8(a.color.a, b.color.a, f),
        },
        .alpha = lerp(a.alpha, b.alpha, f),
    };
}

/// Same pad(0)/repeat(1)/reflect(2) family as `resolveColorLine`'s extend
/// handling, but over a `[0, size)` pixel-index range instead of a
/// `[lo, hi]` stop-offset range. Nearest-neighbor sampling only (NOTE:
/// no bilinear — add if tiled-pattern aliasing at small ppem shows up).
fn extendPatternCoord(v: f64, size: f64, extend: u8) f64 {
    return switch (extend) {
        1 => @mod(v, size), // repeat
        2 => blk: { // reflect
            const period = 2.0 * size;
            const m = @mod(v, period);
            break :blk if (m < size) m else period - m;
        },
        else => std.math.clamp(v, 0, size - 1e-6), // pad (also the fallback for an invalid extend value)
    };
}

pub fn lerp(a: f32, b: f32, f: f64) f32 {
    return @floatCast(@as(f64, a) + (@as(f64, b) - @as(f64, a)) * f);
}

/// TrueType on/off-curve contour decoding (implied on-curve midpoints
/// between consecutive off-curve points), matching `FT_Outline_Decompose`'s
/// conic handling specialized to `glyf`'s quadratic-only outlines.
fn decomposeContour(raster: *Rasterizer, points: []const ScaledPoint) !void {
    const n = points.len;
    if (n == 0) return;

    var walk_start: usize = 0;
    const start: IPoint = blk: {
        if (points[n - 1].on) {
            break :blk points[n - 1].p;
        } else if (points[0].on) {
            walk_start = 1;
            break :blk points[0].p;
        } else {
            const a = points[0].p;
            const b = points[n - 1].p;
            break :blk .{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2) };
        }
    };

    try raster.moveTo(start);

    var pending_control: ?IPoint = null;
    var i: usize = walk_start;
    while (i < n) : (i += 1) {
        const pt = points[i];
        if (pt.on) {
            if (pending_control) |ctrl| {
                try raster.conicTo(ctrl, pt.p);
                pending_control = null;
            } else {
                try raster.lineTo(pt.p);
            }
        } else {
            if (pending_control) |ctrl| {
                const mid = IPoint{ .x = @divTrunc(ctrl.x + pt.p.x, 2), .y = @divTrunc(ctrl.y + pt.p.y, 2) };
                try raster.conicTo(ctrl, mid);
            }
            pending_control = pt.p;
        }
    }

    if (pending_control) |ctrl| {
        try raster.conicTo(ctrl, start);
    } else {
        try raster.lineTo(start);
    }
}

/// `COLR` spec, "Linear gradients": color-line offset 0 aligns to `p0`,
/// offset 1.0 aligns to the projection of `p1` onto the line through `p0`
/// perpendicular to `p0`-`p2` (`p2` only ever matters via that
/// perpendicular direction — "neither the magnitude ... nor the
/// direction ... has significance").
fn linearGradientT(p0: GradientPoint, p1: GradientPoint, p2: GradientPoint, x: f64, y: f64) ?f64 {
    const d1 = GradientPoint{ .x = p1.x - p0.x, .y = p1.y - p0.y };
    const d2 = GradientPoint{ .x = p2.x - p0.x, .y = p2.y - p0.y };
    if ((d1.x == 0 and d1.y == 0) or (d2.x == 0 and d2.y == 0)) return null; // p1 or p2 == p0: ill-formed
    const cross = d1.x * d2.y - d1.y * d2.x;
    if (@abs(cross) < 1e-9) return null; // p0p2 parallel to p0p1: ill-formed

    const perp = GradientPoint{ .x = -d2.y, .y = d2.x };
    const perp_len2 = perp.x * perp.x + perp.y * perp.y;
    const comp = (d1.x * perp.x + d1.y * perp.y) / perp_len2;
    const d3 = GradientPoint{ .x = perp.x * comp, .y = perp.y * comp };
    const denom = d3.x * d3.x + d3.y * d3.y;
    if (denom == 0) return null;

    return ((x - p0.x) * d3.x + (y - p0.y) * d3.y) / denom;
}

/// `COLR` spec, "Radial gradients": the two circles sweep a cone in
/// (x, y, r) as omega goes from 0 to 1; for a given pixel, the visible
/// color is the one at the omega nearest +infinity with r(omega) >= 0
/// (later omegas paint over earlier ones per the spec's algorithm).
fn radialGradientT(c0: GradientPoint, r0: f64, c1: GradientPoint, r1: f64, x: f64, y: f64) ?f64 {
    const dcx = c1.x - c0.x;
    const dcy = c1.y - c0.y;
    const dr = r1 - r0;
    if (dcx == 0 and dcy == 0 and dr == 0) return null; // identical circles: paint nothing

    const pcx = x - c0.x;
    const pcy = y - c0.y;
    const a = dcx * dcx + dcy * dcy - dr * dr;
    const b = -2.0 * (pcx * dcx + pcy * dcy + r0 * dr);
    const c = pcx * pcx + pcy * pcy - r0 * r0;

    if (@abs(a) < 1e-9) {
        if (@abs(b) < 1e-9) return null;
        const t = -c / b;
        return if (r0 + t * dr >= 0) t else null;
    }

    const disc = b * b - 4.0 * a * c;
    if (disc < 0) return null;
    const sq = @sqrt(disc);
    const t1 = (-b + sq) / (2.0 * a);
    const t2 = (-b - sq) / (2.0 * a);
    const hi = @max(t1, t2);
    const lo = @min(t1, t2);
    if (r0 + hi * dr >= 0) return hi;
    if (r0 + lo * dr >= 0) return lo;
    return null;
}

/// `COLR` spec, "Sweep gradients": counter-clockwise degrees from the
/// positive x-axis, offset 0 aligned to `start_deg` and offset 1 to
/// `end_deg`. Real-valued `t` outside `[0, 1]` (the common case, since
/// the physical angle wraps every 360 degrees) is handled generically by
/// `resolveColorLine`'s extend-mode logic, same as linear/radial.
fn sweepGradientT(center: GradientPoint, start_deg: f64, end_deg: f64, x: f64, y: f64) ?f64 {
    if (start_deg == end_deg) return null;
    const dx = x - center.x;
    const dy = y - center.y;
    if (dx == 0 and dy == 0) return 0.5; // angle undefined at the exact center

    var deg = std.math.radiansToDegrees(std.math.atan2(dy, dx));
    if (deg < 0) deg += 360.0;
    return (deg - start_deg) / (end_deg - start_deg);
}

pub fn gradientT(geometry: GradientGeometry, x: f64, y: f64) ?f64 {
    return switch (geometry) {
        .linear => |g| linearGradientT(g.p0, g.p1, g.p2, x, y),
        .radial => |g| radialGradientT(g.c0, g.r0, g.c1, g.r1, x, y),
        .sweep => |g| sweepGradientT(g.center, g.start_deg, g.end_deg, x, y),
    };
}

pub fn srcOver(dst: Rgba, src_rgb: Rgba, src_alpha: f32) Rgba {
    const dst_a: f32 = @as(f32, @floatFromInt(dst.a)) / 255.0;
    const out_a = src_alpha + dst_a * (1.0 - src_alpha);
    if (out_a <= 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    const mix = struct {
        fn f(s: u8, d: u8, sa: f32, da: f32, oa: f32) f32 {
            return (@as(f32, @floatFromInt(s)) * sa + @as(f32, @floatFromInt(d)) * da * (1.0 - sa)) / oa;
        }
    }.f;

    return .{
        .r = @intFromFloat(@round(std.math.clamp(mix(src_rgb.r, dst.r, src_alpha, dst_a, out_a), 0, 255))),
        .g = @intFromFloat(@round(std.math.clamp(mix(src_rgb.g, dst.g, src_alpha, dst_a, out_a), 0, 255))),
        .b = @intFromFloat(@round(std.math.clamp(mix(src_rgb.b, dst.b, src_alpha, dst_a, out_a), 0, 255))),
        .a = @intFromFloat(@round(std.math.clamp(out_a * 255.0, 0, 255))),
    };
}

/// `PaintComposite`: blends `source` over `backdrop` per `mode`
/// (`porterDuffBlend`) across the union of both canvases' bounding boxes,
/// treating out-of-bounds pixels as fully transparent. Caller owns the
/// returned canvas's `pixels`.
pub fn blendCanvases(allocator: std.mem.Allocator, backdrop: BitmapRgba8bit, source: BitmapRgba8bit, mode: u8) RasterizeColrError!BitmapRgba8bit {
    if (backdrop.width == 0 and source.width == 0) {
        return .{ .width = 0, .rows = 0, .left = 0, .top = 0, .pixels_row_major = try allocator.alloc(u8, 0) };
    }

    var left: i32 = std.math.maxInt(i32);
    var top: i32 = std.math.minInt(i32);
    var right: i32 = std.math.minInt(i32);
    var bottom: i32 = std.math.maxInt(i32);
    for ([_]BitmapRgba8bit{ backdrop, source }) |c| {
        if (c.width == 0 or c.rows == 0) continue;
        left = @min(left, c.left);
        top = @max(top, c.top);
        right = @max(right, c.left + @as(i32, @intCast(c.width)));
        bottom = @min(bottom, c.top - @as(i32, @intCast(c.rows)));
    }

    const width: u32 = @intCast(right - left);
    const rows: u32 = @intCast(top - bottom);
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, rows) * 4);

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const device_x = left + @as(i32, @intCast(col));
            const device_y = top - @as(i32, @intCast(row));
            const blended = porterDuffBlend(rgbaAt(backdrop, device_x, device_y), rgbaAt(source, device_x, device_y), mode);
            const px = (@as(usize, row) * width + col) * 4;
            pixels[px] = blended.r;
            pixels[px + 1] = blended.g;
            pixels[px + 2] = blended.b;
            pixels[px + 3] = blended.a;
        }
    }

    return .{ .width = width, .rows = rows, .left = left, .top = top, .pixels_row_major = pixels };
}

fn rgbaAt(canvas: BitmapRgba8bit, device_x: i32, device_y: i32) Rgba {
    if (canvas.width == 0 or canvas.rows == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const col = device_x - canvas.left;
    const row = canvas.top - device_y;
    if (col < 0 or row < 0 or col >= canvas.width or row >= canvas.rows) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const px = (@as(usize, @intCast(row)) * canvas.width + @as(usize, @intCast(col))) * 4;
    return .{ .r = canvas.pixels_row_major[px], .g = canvas.pixels_row_major[px + 1], .b = canvas.pixels_row_major[px + 2], .a = canvas.pixels_row_major[px + 3] };
}
/// `PaintComposite`'s Porter-Duff coefficients (`CompositeMode` 0-12 of
/// the `COLR` spec's 28-value enum; modes 13-27 are the separable/HSL
/// blend modes, handled by `separableOrHslBlend`). `as`/`ab` are the
/// source/backdrop straight alphas in `[0, 1]`.
fn porterDuffCoeffs(mode: u8, as: f32, ab: f32) struct { fa: f32, fb: f32 } {
    return switch (mode) {
        0 => .{ .fa = 0, .fb = 0 }, // Clear
        1 => .{ .fa = 1, .fb = 0 }, // Src
        2 => .{ .fa = 0, .fb = 1 }, // Dest
        3 => .{ .fa = 1, .fb = 1 - as }, // SrcOver
        4 => .{ .fa = 1 - ab, .fb = 1 }, // DestOver
        5 => .{ .fa = ab, .fb = 0 }, // SrcIn
        6 => .{ .fa = 0, .fb = as }, // DestIn
        7 => .{ .fa = 1 - ab, .fb = 0 }, // SrcOut
        8 => .{ .fa = 0, .fb = 1 - as }, // DestOut
        9 => .{ .fa = ab, .fb = 1 - as }, // SrcAtop
        10 => .{ .fa = 1 - ab, .fb = as }, // DestAtop
        11 => .{ .fa = 1 - ab, .fb = 1 - as }, // Xor
        12 => .{ .fa = 1, .fb = 1 }, // Plus
        else => .{ .fa = 0, .fb = 0 },
    };
}

/// CSS Compositing/Blending separable blend functions, operating on
/// straight (non-premultiplied) channel values in `[0, 1]`.
fn blendChannel(mode: u8, cb: f32, cs: f32) f32 {
    return switch (mode) {
        13 => cb + cs - cb * cs, // Screen
        14 => if (cb <= 0.5) 2 * cb * cs else 1 - 2 * (1 - cb) * (1 - cs), // Overlay = HardLight(cs, cb)
        15 => @min(cb, cs), // Darken
        16 => @max(cb, cs), // Lighten
        17 => if (cb == 0) 0 else if (cs == 1) 1 else @min(1, cb / (1 - cs)), // ColorDodge
        18 => if (cb == 1) 1 else if (cs == 0) 0 else 1 - @min(1, (1 - cb) / cs), // ColorBurn
        19 => if (cs <= 0.5) cb * (2 * cs) else cb + (2 * cs - 1) - cb * (2 * cs - 1), // HardLight
        20 => softLight(cb, cs), // SoftLight
        21 => @abs(cb - cs), // Difference
        22 => cb + cs - 2 * cb * cs, // Exclusion
        23 => cb * cs, // Multiply
        else => unreachable,
    };
}

fn softLight(cb: f32, cs: f32) f32 {
    if (cs <= 0.5) return cb - (1 - 2 * cs) * cb * (1 - cb);
    const d: f32 = if (cb <= 0.25) ((16 * cb - 12) * cb + 4) * cb else @sqrt(cb);
    return cb + (2 * cs - 1) * (d - cb);
}

const Rgb3 = struct { r: f32, g: f32, b: f32 };

fn lum(c: Rgb3) f32 {
    return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b;
}

fn clipColor(c: Rgb3) Rgb3 {
    const l = lum(c);
    const n = @min(c.r, @min(c.g, c.b));
    const x = @max(c.r, @max(c.g, c.b));
    var out = c;
    if (n < 0) {
        out = .{
            .r = l + (out.r - l) * l / (l - n),
            .g = l + (out.g - l) * l / (l - n),
            .b = l + (out.b - l) * l / (l - n),
        };
    }
    if (x > 1) {
        out = .{
            .r = l + (out.r - l) * (1 - l) / (x - l),
            .g = l + (out.g - l) * (1 - l) / (x - l),
            .b = l + (out.b - l) * (1 - l) / (x - l),
        };
    }
    return out;
}

fn setLum(c: Rgb3, l: f32) Rgb3 {
    const d = l - lum(c);
    return clipColor(.{ .r = c.r + d, .g = c.g + d, .b = c.b + d });
}

fn sat(c: Rgb3) f32 {
    return @max(c.r, @max(c.g, c.b)) - @min(c.r, @min(c.g, c.b));
}

fn setSat(c: Rgb3, s: f32) Rgb3 {
    var arr = [3]f32{ c.r, c.g, c.b };
    var order = [3]usize{ 0, 1, 2 };
    if (arr[order[0]] > arr[order[1]]) std.mem.swap(usize, &order[0], &order[1]);
    if (arr[order[1]] > arr[order[2]]) std.mem.swap(usize, &order[1], &order[2]);
    if (arr[order[0]] > arr[order[1]]) std.mem.swap(usize, &order[0], &order[1]);
    const min_i = order[0];
    const mid_i = order[1];
    const max_i = order[2];
    if (arr[max_i] > arr[min_i]) {
        arr[mid_i] = (arr[mid_i] - arr[min_i]) * s / (arr[max_i] - arr[min_i]);
        arr[max_i] = s;
    } else {
        arr[mid_i] = 0;
        arr[max_i] = 0;
    }
    arr[min_i] = 0;
    return .{ .r = arr[0], .g = arr[1], .b = arr[2] };
}

/// `CompositeMode` 13-27: the separable (screen/multiply/darken/lighten/
/// color-dodge/color-burn/hard-light/soft-light/difference/exclusion) and
/// non-separable HSL (hue/saturation/color/luminosity) blend modes from
/// the CSS Compositing and Blending spec. Per that spec, the blended
/// color replaces the source color in an otherwise-ordinary SrcOver
/// composite, so this returns straight-alpha `Cs'` for `porterDuffBlend`
/// (mode 3, SrcOver) to composite as usual.
fn separableOrHslBlend(backdrop: Rgba, source: Rgba, mode: u8) Rgb3 {
    const cb = Rgb3{
        .r = @as(f32, @floatFromInt(backdrop.r)) / 255.0,
        .g = @as(f32, @floatFromInt(backdrop.g)) / 255.0,
        .b = @as(f32, @floatFromInt(backdrop.b)) / 255.0,
    };
    const cs = Rgb3{
        .r = @as(f32, @floatFromInt(source.r)) / 255.0,
        .g = @as(f32, @floatFromInt(source.g)) / 255.0,
        .b = @as(f32, @floatFromInt(source.b)) / 255.0,
    };
    return switch (mode) {
        13...23 => .{
            .r = blendChannel(mode, cb.r, cs.r),
            .g = blendChannel(mode, cb.g, cs.g),
            .b = blendChannel(mode, cb.b, cs.b),
        },
        24 => setLum(setSat(cs, sat(cb)), lum(cb)), // HslHue
        25 => setLum(setSat(cb, sat(cs)), lum(cb)), // HslSaturation
        26 => setLum(cs, lum(cb)), // HslColor
        27 => setLum(cb, lum(cs)), // HslLuminosity
        else => unreachable,
    };
}

fn porterDuffBlend(backdrop: Rgba, source: Rgba, mode: u8) Rgba {
    const as: f32 = @as(f32, @floatFromInt(source.a)) / 255.0;
    const ab: f32 = @as(f32, @floatFromInt(backdrop.a)) / 255.0;

    if (mode >= 13 and mode <= 27) {
        const ab_backdrop = ab;
        const blended = separableOrHslBlend(backdrop, source, mode);
        const mixed = Rgba{
            .r = @intFromFloat(@round(std.math.clamp(((1 - ab_backdrop) * @as(f32, @floatFromInt(source.r)) / 255.0 + ab_backdrop * blended.r) * 255.0, 0, 255))),
            .g = @intFromFloat(@round(std.math.clamp(((1 - ab_backdrop) * @as(f32, @floatFromInt(source.g)) / 255.0 + ab_backdrop * blended.g) * 255.0, 0, 255))),
            .b = @intFromFloat(@round(std.math.clamp(((1 - ab_backdrop) * @as(f32, @floatFromInt(source.b)) / 255.0 + ab_backdrop * blended.b) * 255.0, 0, 255))),
            .a = source.a,
        };
        return porterDuffBlend(backdrop, mixed, 3);
    }

    const c = porterDuffCoeffs(mode, as, ab);
    const out_a = std.math.clamp(as * c.fa + ab * c.fb, 0, 1);
    if (out_a <= 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    const mix = struct {
        fn f(s: u8, d: u8, sa: f32, fa: f32, da: f32, fb: f32, oa: f32) f32 {
            return (@as(f32, @floatFromInt(s)) * sa * fa + @as(f32, @floatFromInt(d)) * da * fb) / oa;
        }
    }.f;

    return .{
        .r = @intFromFloat(@round(std.math.clamp(mix(source.r, backdrop.r, as, c.fa, ab, c.fb, out_a), 0, 255))),
        .g = @intFromFloat(@round(std.math.clamp(mix(source.g, backdrop.g, as, c.fa, ab, c.fb, out_a), 0, 255))),
        .b = @intFromFloat(@round(std.math.clamp(mix(source.b, backdrop.b, as, c.fa, ab, c.fb, out_a), 0, 255))),
        .a = @intFromFloat(@round(out_a * 255.0)),
    };
}
