const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");
const ScaledPoint = common.ScaledPoint;
const IPoint = common.IPoint;

const rasterization = @import("../rasterization.zig");
const parsing = @import("../parsing.zig");
const Rgba = rasterization.Rgba;
const OutlineSource = rasterization.OutlineSource;
const DrawOp = common.DrawOp;

const Rasterizer = @import("rasterizer.zig").Rasterizer;
const RasterizeError = rasterization.RasterizeError;
const RasterizeColrError = rasterization.RasterizeColrError;
const CoverageMaskFillSource = rasterization.CoverageMaskFillSource;
const Bitmap8bit = rasterization.Bitmap8bit;
const GradientGeometry = rasterization.GradientGeometry;
const GradientStop = rasterization.GradientStop;
const BitmapRgba8bit = rasterization.BitmapRgba8bit;
const freeOps = rasterization.freeOps;

pub const ColrWalker = struct {
    scratch_allocator: Allocator,
    colr_data: []const u8,
    cpal_data: []const u8,
    palette_index: u16,
    foreground_color: Rgba,
    source: OutlineSource,
    coverage_contrast: rasterization.CoverageContrast = .{},
    ops: std.ArrayList(DrawOp) = .empty,

    pub fn deinit(self: *ColrWalker) void {
        freeOps(self.scratch_allocator, self.ops.items);
        self.ops.deinit(self.scratch_allocator);
    }

    /// `palette_entry_index == 0xFFFF` is the spec's sentinel for "use the
    /// caller-supplied foreground/text color instead of a CPAL lookup"
    /// (`COLR`/`CPAL` spec, `LayerRecord.paletteIndex`/`PaintSolid.
    /// PaletteIndex`) — real fonts commonly use it for outline/ink layers
    /// meant to always match surrounding text color.
    pub fn resolvedColor(self: ColrWalker, palette_entry_index: u16, alpha_raw: i16) parsing.Font.ParseError!struct { color: Rgba, alpha: f32 } {
        const color = if (palette_entry_index == 0xFFFF) blk: {
            break :blk self.foreground_color;
        } else blk: {
            const colors = try parsing.Table.CPAL.paletteColors(self.cpal_data, self.palette_index);
            if (palette_entry_index >= colors.len) return error.InvalidTableFormat;
            break :blk Rgba.fromCpal(colors[palette_entry_index]);
        };
        var alpha: f32 = @as(f32, @floatFromInt(alpha_raw)) / 16384.0;
        alpha = @max(0.0, @min(1.0, alpha));
        return .{ .color = color, .alpha = alpha };
    }

    fn outlineBitmap(self: ColrWalker, glyph_id: u16, matrix: Affine) RasterizeColrError!Bitmap8bit {
        switch (self.source) {
            .glyf => |g| {
                const outline = try parsing.Table.glyf.outline(self.scratch_allocator, g.glyf_data, g.loca_data, g.index_to_loc_format, glyph_id);
                defer self.scratch_allocator.free(outline.points);
                defer self.scratch_allocator.free(outline.end_points_of_contours);
                return rasterizeGlyfAffine(self.scratch_allocator, outline, matrix);
            },
            .cff => |c| {
                const outline = try parsing.Table.cff.outline(self.scratch_allocator, c.cff_data, glyph_id);
                defer self.scratch_allocator.free(outline.segments);
                return rasterizeCffAffine(self.scratch_allocator, outline, matrix);
            },
        }
    }

    pub fn drawGlyph(self: *ColrWalker, glyph_id: u16, matrix: Affine, paint: CoverageMaskFillSource) RasterizeColrError!void {
        if (paint == .solid and paint.solid.alpha <= 0) return;
        const bitmap = try self.outlineBitmap(glyph_id, matrix);
        if (bitmap.width == 0 or bitmap.rows == 0) {
            bitmap.deinit(self.scratch_allocator);
            paint.free(self.scratch_allocator);
            return;
        }
        try self.ops.append(self.scratch_allocator, .{ .bitmap = bitmap, .paint = paint });
    }

    /// Renders `reader`'s paint sub-graph to its own offscreen RGBA canvas
    /// (`PaintComposite`'s source/backdrop children need to be composited
    /// as a unit via a blend-mode formula before joining the parent
    /// canvas, unlike every other paint which draws straight into the
    /// shared op list). Swaps `self.ops` out for a scratch list so the
    /// recursive `walkPaint` call collects into it instead of the caller's
    /// ops, same alloc/depth-cap machinery throughout.
    fn renderSubgraph(self: *ColrWalker, reader: parsing.Table.COLR.PaintReader, matrix: Affine, depth: u32) RasterizeColrError!BitmapRgba8bit {
        const saved_ops = self.ops;
        self.ops = .empty;
        defer {
            freeOps(self.scratch_allocator, self.ops.items);
            self.ops.deinit(self.scratch_allocator);
            self.ops = saved_ops;
        }
        try self.walkPaint(reader, matrix, depth);
        return common.compositeOpsToCanvas(self.scratch_allocator, self.ops.items, self.coverage_contrast);
    }

    /// `ColorLine` (`COLR` spec): extend mode (pad/repeat/reflect) + a
    /// `ColorStop[numColorStops]` array, `stopOffset`(F2Dot14) +
    /// `paletteIndex`(uint16) + `alpha`(F2Dot14) each, 6 bytes/stop.
    /// `null` for an invalid extend value or zero stops — spec's
    /// "ill-formed, must not be rendered" case for a gradient's color
    /// line. Caller owns the returned slice.
    fn readColorLine(self: *ColrWalker, reader: parsing.Table.COLR.PaintReader) RasterizeColrError!?struct { extend: u8, stops: []const GradientStop } {
        const extend = try reader.u8At(0);
        if (extend > 2) return null;
        const num_stops = try reader.u16At(1);
        if (num_stops == 0) return null;

        var stops: std.ArrayList(GradientStop) = try .initCapacity(self.scratch_allocator, num_stops);
        errdefer stops.deinit(self.scratch_allocator);
        var i: u32 = 0;
        while (i < num_stops) : (i += 1) {
            const rel = 3 + i * 6;
            const stop_offset = f2dot14(try reader.i16At(rel));
            const palette_index = try reader.u16At(rel + 2);
            const alpha_raw = try reader.i16At(rel + 4);
            const resolved = try self.resolvedColor(palette_index, alpha_raw);
            stops.appendAssumeCapacity(.{ .offset = stop_offset, .color = resolved.color, .alpha = resolved.alpha });
        }
        return .{ .extend = extend, .stops = try stops.toOwnedSlice(self.scratch_allocator) };
    }

    /// Builds the `Paint.gradient` for a `PaintLinearGradient` (format 4),
    /// `PaintRadialGradient` (6), or `PaintSweepGradient` (8) color source
    /// under `PaintGlyph` — geometry field layout and byte offsets per
    /// `ttcolr.c`'s `tt_face_get_paint` (linear ~L724, radial ~L772,
    /// sweep ~L834). `null` if the color line is ill-formed or the
    /// accumulated transform isn't invertible (both: skip the layer).
    fn gradientPaintFor(self: *ColrWalker, format: u8, reader: parsing.Table.COLR.PaintReader, matrix: Affine) RasterizeColrError!?CoverageMaskFillSource {
        const inverse = matrix.invert() orelse return null;
        const colorline_off = (try reader.childOffsetAt(1)) orelse return null;
        const line = (try self.readColorLine(reader.at(colorline_off))) orelse return null;
        errdefer self.scratch_allocator.free(line.stops);

        const geometry: GradientGeometry = switch (format) {
            4 => .{ .linear = .{
                .p0 = .{ .x = @floatFromInt(try reader.i16At(4)), .y = @floatFromInt(try reader.i16At(6)) },
                .p1 = .{ .x = @floatFromInt(try reader.i16At(8)), .y = @floatFromInt(try reader.i16At(10)) },
                .p2 = .{ .x = @floatFromInt(try reader.i16At(12)), .y = @floatFromInt(try reader.i16At(14)) },
            } },
            6 => .{ .radial = .{
                .c0 = .{ .x = @floatFromInt(try reader.i16At(4)), .y = @floatFromInt(try reader.i16At(6)) },
                .r0 = @floatFromInt(try reader.i16At(8)),
                .c1 = .{ .x = @floatFromInt(try reader.i16At(10)), .y = @floatFromInt(try reader.i16At(12)) },
                .r1 = @floatFromInt(try reader.i16At(14)),
            } },
            8 => .{ .sweep = .{
                .center = .{ .x = @floatFromInt(try reader.i16At(4)), .y = @floatFromInt(try reader.i16At(6)) },
                .start_deg = f2dot14(try reader.i16At(8)) * 180.0,
                .end_deg = f2dot14(try reader.i16At(10)) * 180.0,
            } },
            else => unreachable,
        };

        return .{ .gradient = .{ .geometry = geometry, .extend = line.extend, .stops = line.stops, .inverse = inverse } };
    }

    fn localAffineFor(self: ColrWalker, format: u8, reader: parsing.Table.COLR.PaintReader) parsing.Font.ParseError!?Affine {
        _ = self;
        return switch (format) {
            12 => blk: { // PaintTransform
                const transform_off = (try reader.childOffsetAt(4)) orelse break :blk null;
                const t = reader.at(transform_off);
                break :blk Affine{
                    .xx = @as(f64, @floatFromInt(try t.i32At(0))) / 65536.0,
                    .yx = @as(f64, @floatFromInt(try t.i32At(4))) / 65536.0,
                    .xy = @as(f64, @floatFromInt(try t.i32At(8))) / 65536.0,
                    .yy = @as(f64, @floatFromInt(try t.i32At(12))) / 65536.0,
                    .dx = @as(f64, @floatFromInt(try t.i32At(16))) / 65536.0,
                    .dy = @as(f64, @floatFromInt(try t.i32At(20))) / 65536.0,
                };
            },
            14 => Affine.translate( // PaintTranslate
                @floatFromInt(try reader.i16At(4)),
                @floatFromInt(try reader.i16At(6)),
            ),
            16 => blk: { // PaintScale
                const sx = f2dot14(try reader.i16At(4));
                const sy = f2dot14(try reader.i16At(6));
                break :blk Affine.scale(sx, sy);
            },
            18 => blk: { // PaintScaleAroundCenter
                const sx = f2dot14(try reader.i16At(4));
                const sy = f2dot14(try reader.i16At(6));
                const cx: f64 = @floatFromInt(try reader.i16At(8));
                const cy: f64 = @floatFromInt(try reader.i16At(10));
                break :blk Affine.aroundCenter(cx, cy, Affine.scale(sx, sy));
            },
            20 => blk: { // PaintScaleUniform
                const s = f2dot14(try reader.i16At(4));
                break :blk Affine.scale(s, s);
            },
            22 => blk: { // PaintScaleUniformAroundCenter
                const s = f2dot14(try reader.i16At(4));
                const cx: f64 = @floatFromInt(try reader.i16At(6));
                const cy: f64 = @floatFromInt(try reader.i16At(8));
                break :blk Affine.aroundCenter(cx, cy, Affine.scale(s, s));
            },
            24 => Affine.rotate(f2dot14Angle(try reader.i16At(4))), // PaintRotate
            26 => blk: { // PaintRotateAroundCenter
                const angle = f2dot14Angle(try reader.i16At(4));
                const cx: f64 = @floatFromInt(try reader.i16At(6));
                const cy: f64 = @floatFromInt(try reader.i16At(8));
                break :blk Affine.aroundCenter(cx, cy, Affine.rotate(angle));
            },
            28 => Affine.skew( // PaintSkew
                f2dot14Angle(try reader.i16At(4)),
                f2dot14Angle(try reader.i16At(6)),
            ),
            30 => blk: { // PaintSkewAroundCenter
                const xa = f2dot14Angle(try reader.i16At(4));
                const ya = f2dot14Angle(try reader.i16At(6));
                const cx: f64 = @floatFromInt(try reader.i16At(8));
                const cy: f64 = @floatFromInt(try reader.i16At(10));
                break :blk Affine.aroundCenter(cx, cy, Affine.skew(xa, ya));
            },
            else => null,
        };
    }

    /// `PaintColrGlyph` can reference another base glyph's paint graph, which
    /// can itself reference a `PaintColrGlyph` back — CLAUDE.md flags this as
    /// the same infinite-recursion class as composite-glyf/CFF-subroutine
    /// self-reference. Every recursive edge in the walk below (`PaintColrLayers`
    /// layers, transform-wrapper children, `PaintColrGlyph`) is bounded by this
    /// depth cap, matching the `max_nesting_level` pattern already used for
    /// GSUB/GPOS chaining-context recursion in shaping.zig.
    const max_paint_nesting: u32 = 64;

    pub fn walkPaint(self: *ColrWalker, reader: parsing.Table.COLR.PaintReader, matrix: Affine, depth: u32) RasterizeColrError!void {
        if (depth > max_paint_nesting) return error.ColrPaintNestingTooDeep;
        const format = try reader.format();

        switch (format) {
            1 => { // PaintColrLayers
                const num_layers = try reader.u8At(1);
                const first_layer_index = try reader.u32At(2);
                var i: u32 = 0;
                while (i < num_layers) : (i += 1) {
                    const off = try parsing.Table.COLR.layerListPaintOffset(self.colr_data, first_layer_index, i);
                    try self.walkPaint(try parsing.Table.COLR.paintAt(self.colr_data, off), matrix, depth + 1);
                }
            },
            10 => { // PaintGlyph: clip-shape glyph ID + its color-source child.
                const color_off = (try reader.childOffsetAt(1)) orelse return;
                const glyph_id = try reader.u16At(4);

                // A PaintGlyph's color source isn't necessarily a leaf
                // PaintSolid/gradient directly — real fonts nest transform
                // nodes (PaintScale etc.) around a gradient to reshape it
                // independently of the clip-shape outline (seen in this repo's
                // `colr_v1.ttf` fixture: PaintGlyph -> PaintScale ->
                // PaintRadialGradient). Transform nodes are format-agnostic
                // in the spec, so unwrap them here the same way the general
                // `else` branch below does for the outline's own matrix,
                // accumulating into a matrix that starts at the outline's
                // `matrix` (both share the same coordinate frame at this
                // paint-graph level).
                var color_reader = reader.at(color_off);
                var color_matrix = matrix;
                var color_depth: u32 = 0;
                const paint: CoverageMaskFillSource = while (true) {
                    if (color_depth > max_paint_nesting) return error.ColrPaintNestingTooDeep;
                    const color_format = try color_reader.format();
                    switch (color_format) {
                        2 => { // PaintSolid
                            const resolved = try self.resolvedColor(try color_reader.u16At(1), try color_reader.i16At(3));
                            break .{ .solid = .{ .color = resolved.color, .alpha = resolved.alpha } };
                        },
                        4, 6, 8 => break (try self.gradientPaintFor(color_format, color_reader, color_matrix)) orelse return,
                        else => {
                            const local = (try self.localAffineFor(color_format, color_reader)) orelse return; // var-solid/var-gradient/PaintComposite/unrecognized: unsupported.
                            const child_off = (try color_reader.childOffsetAt(1)) orelse return;
                            color_matrix = color_matrix.compose(local);
                            color_reader = color_reader.at(child_off);
                            color_depth += 1;
                        },
                    }
                };
                try self.drawGlyph(glyph_id, matrix, paint);
            },
            11 => { // PaintColrGlyph: renders another base glyph's paint graph at the same transform.
                const glyph_id = try reader.u16At(1);
                const paint_offset = (try parsing.Table.COLR.baseGlyphPaintOffset(self.colr_data, glyph_id)) orelse return;
                try self.walkPaint(try parsing.Table.COLR.paintAt(self.colr_data, paint_offset), matrix, depth + 1);
            },
            32 => { // PaintComposite: Offset24 sourcePaint, uint8 compositeMode, Offset24 backdropPaint.
                const source_off = (try reader.childOffsetAt(1)) orelse return;
                const mode = try reader.u8At(4);
                const backdrop_off = (try reader.childOffsetAt(5)) orelse return;
                if (mode > 27) return;

                const source_canvas = try self.renderSubgraph(reader.at(source_off), matrix, depth + 1);
                defer self.scratch_allocator.free(source_canvas.pixels_row_major);
                const backdrop_canvas = try self.renderSubgraph(reader.at(backdrop_off), matrix, depth + 1);
                defer self.scratch_allocator.free(backdrop_canvas.pixels_row_major);

                const composited = try common.blendCanvases(self.scratch_allocator, backdrop_canvas, source_canvas, mode);
                if (composited.width == 0 or composited.rows == 0) {
                    self.scratch_allocator.free(composited.pixels_row_major);
                    return;
                }
                const mask = try self.scratch_allocator.alloc(u8, @as(usize, composited.width) * composited.rows);
                @memset(mask, 255);
                try self.ops.append(self.scratch_allocator, .{
                    .bitmap = .{ .width = composited.width, .rows = composited.rows, .left = composited.left, .top = composited.top, .pixels_row_major = mask },
                    .paint = .{ .image = .{ .rgba = composited.pixels_row_major } },
                });
            },
            else => {
                const local = (try self.localAffineFor(format, reader)) orelse return; // unsupported format (gradient/composite/var-*): skip layer.
                const child_off = (try reader.childOffsetAt(1)) orelse return;
                try self.walkPaint(reader.at(child_off), matrix.compose(local), depth + 1);
            },
        }
    }

    fn f2dot14(raw: i16) f64 {
        return @as(f64, @floatFromInt(raw)) / 16384.0;
    }

    /// COLR's `Angle` encoding: value is a fraction of a half-circle
    /// (`F2Dot14` raw/16384 == degrees/180), so radians = (raw/16384) * pi.
    fn f2dot14Angle(raw: i16) f64 {
        return f2dot14(raw) * std.math.pi;
    }
};

/// 2x3 affine transform in `f64`, used only by the COLRv1 paint-graph
/// compositor below. Deliberately not fixed-point like the rest of this
/// file's `FT_MulFix`/`FT_DivFix` machinery: there is no FreeType bitmap
/// output for COLRv1 to bit-match against (`ttcolr.c` only decodes the
/// paint graph — compositing is spec'd as a client responsibility, see
/// `FT_Get_Paint`'s docs), so exact fixed-point rounding parity with a
/// reference is not a real constraint here, and floats keep the
/// rotate/skew matrix composition legible.
///
/// Field/formula convention (`x' = xx*x + xy*y + dx`, `y' = yx*x + yy*y +
/// dy`) and every builder below (`translate`/`scale`/`rotate`/`skew`)
/// matches the OpenType COLR spec's `Affine2x3` formula, cross-checked
/// against `fontTools.ttLib.tables.otTables.Paint.getTransform` (the
/// widely-used reference implementation of this exact conversion,
/// `fontTools/ttLib/tables/otTables.py`).
pub const Affine = struct {
    xx: f64 = 1,
    xy: f64 = 0,
    yx: f64 = 0,
    yy: f64 = 1,
    dx: f64 = 0,
    dy: f64 = 0,

    pub fn apply(self: Affine, x: f64, y: f64) struct { x: f64, y: f64 } {
        return .{ .x = self.xx * x + self.xy * y + self.dx, .y = self.yx * x + self.yy * y + self.dy };
    }

    /// `outer.compose(inner).apply(p) == outer.apply(inner.apply(p))` —
    /// i.e. `inner` (the paint node closer to the leaf) is applied first.
    fn compose(outer: Affine, inner: Affine) Affine {
        return .{
            .xx = outer.xx * inner.xx + outer.xy * inner.yx,
            .xy = outer.xx * inner.xy + outer.xy * inner.yy,
            .yx = outer.yx * inner.xx + outer.yy * inner.yx,
            .yy = outer.yx * inner.xy + outer.yy * inner.yy,
            .dx = outer.xx * inner.dx + outer.xy * inner.dy + outer.dx,
            .dy = outer.yx * inner.dx + outer.yy * inner.dy + outer.dy,
        };
    }

    fn translate(dx: f64, dy: f64) Affine {
        return .{ .dx = dx, .dy = dy };
    }

    pub fn scale(sx: f64, sy: f64) Affine {
        return .{ .xx = sx, .yy = sy };
    }

    fn rotate(radians: f64) Affine {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .xx = c, .xy = -s, .yx = s, .yy = c };
    }

    /// `x_radians`/`y_radians` are the raw `xSkewAngle`/`ySkewAngle`
    /// values (not pre-negated) — the spec's asymmetric sign convention
    /// (x skews one way, y the other) is baked into this formula itself.
    fn skew(x_radians: f64, y_radians: f64) Affine {
        return .{ .xx = 1, .xy = -@tan(x_radians), .yx = @tan(y_radians), .yy = 1 };
    }

    fn aroundCenter(center_x: f64, center_y: f64, inner: Affine) Affine {
        return translate(center_x, center_y).compose(inner).compose(translate(-center_x, -center_y));
    }

    /// `null` for a singular (non-invertible) matrix — callers treat that
    /// as an ill-formed gradient paint and skip the layer, same as the
    /// spec's other "ill-formed, must not be rendered" gradient cases.
    pub fn invert(self: Affine) ?Affine {
        const det = self.xx * self.yy - self.xy * self.yx;
        if (@abs(det) < 1e-12) return null;
        const ixx = self.yy / det;
        const ixy = -self.xy / det;
        const iyx = -self.yx / det;
        const iyy = self.xx / det;
        return .{
            .xx = ixx,
            .xy = ixy,
            .yx = iyx,
            .yy = iyy,
            .dx = -(ixx * self.dx + ixy * self.dy),
            .dy = -(iyx * self.dx + iyy * self.dy),
        };
    }
};

/// Same pipeline as `rasterizeGlyf`, but under an arbitrary `Affine`
/// (COLRv1 paint-graph transform composed with the ppem/upm pixel scale)
/// instead of `rasterizeGlyf`'s isotropic fixed-point `ppem` scale —
/// COLRv1 layers can be rotated/skewed/non-uniformly scaled per glyph.
fn rasterizeGlyfAffine(alloc: Allocator, outline: parsing.Table.glyf.Outline, matrix: Affine) RasterizeError!Bitmap8bit {
    const empty = Bitmap8bit{ .width = 0, .rows = 0, .left = 0, .top = 0, .pixels_row_major = try alloc.alloc(u8, 0) };
    if (outline.points.len == 0 or outline.end_points_of_contours.len == 0) return empty;

    const scaled_points = try alloc.alloc(ScaledPoint, outline.points.len);
    defer alloc.free(scaled_points);

    for (outline.points, 0..) |pt, i| {
        const sp = transformToScaledPoint(matrix, pt.x, pt.y);
        scaled_points[i] = .{ .p = sp, .on = pt.on_curve };
    }

    return common.renderScaledPoints(alloc, alloc, scaled_points, outline.end_points_of_contours, true, null);
}

/// Same pipeline as `rasterizeCff`, under an arbitrary `Affine` — see
/// `rasterizeGlyfAffine`.
fn rasterizeCffAffine(alloc: Allocator, outline: parsing.Table.cff.Outline, matrix: Affine) RasterizeError!Bitmap8bit {
    const empty = Bitmap8bit{ .width = 0, .rows = 0, .left = 0, .top = 0, .pixels_row_major = try alloc.alloc(u8, 0) };
    if (outline.segments.len == 0) return empty;

    var cbox_min_x: i32 = std.math.maxInt(i32);
    var cbox_min_y: i32 = std.math.maxInt(i32);
    var cbox_max_x: i32 = std.math.minInt(i32);
    var cbox_max_y: i32 = std.math.minInt(i32);

    const scaled = try alloc.alloc(common.IScaledCffSegment, outline.segments.len);
    defer alloc.free(scaled);

    for (outline.segments, 0..) |segment, i| {
        switch (segment) {
            .move_to => |p| {
                const sp = transformToScaledPoint(matrix, p.x, p.y);
                cbox_min_x = @min(cbox_min_x, sp.x);
                cbox_min_y = @min(cbox_min_y, sp.y);
                cbox_max_x = @max(cbox_max_x, sp.x);
                cbox_max_y = @max(cbox_max_y, sp.y);
                scaled[i] = .{ .move_to = sp };
            },
            .line_to => |p| {
                const sp = transformToScaledPoint(matrix, p.x, p.y);
                cbox_min_x = @min(cbox_min_x, sp.x);
                cbox_min_y = @min(cbox_min_y, sp.y);
                cbox_max_x = @max(cbox_max_x, sp.x);
                cbox_max_y = @max(cbox_max_y, sp.y);
                scaled[i] = .{ .line_to = sp };
            },
            .curve_to => |c| {
                const c1 = transformToScaledPoint(matrix, c.c1.x, c.c1.y);
                const c2 = transformToScaledPoint(matrix, c.c2.x, c.c2.y);
                const to = transformToScaledPoint(matrix, c.to.x, c.to.y);
                for ([_]IPoint{ c1, c2, to }) |sp| {
                    cbox_min_x = @min(cbox_min_x, sp.x);
                    cbox_min_y = @min(cbox_min_y, sp.y);
                    cbox_max_x = @max(cbox_max_x, sp.x);
                    cbox_max_y = @max(cbox_max_y, sp.y);
                }
                scaled[i] = .{ .curve_to = .{ .c1 = c1, .c2 = c2, .to = to } };
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
        return .{ .width = 0, .rows = 0, .left = x_min_px, .top = y_max_px, .pixels_row_major = try alloc.alloc(u8, 0) };
    }

    for (scaled) |*segment| {
        switch (segment.*) {
            .move_to => |*p| {
                p.x -= 64 * x_min_px;
                p.y -= 64 * y_min_px;
            },
            .line_to => |*p| {
                p.x -= 64 * x_min_px;
                p.y -= 64 * y_min_px;
            },
            .curve_to => |*c| {
                c.c1.x -= 64 * x_min_px;
                c.c1.y -= 64 * y_min_px;
                c.c2.x -= 64 * x_min_px;
                c.c2.y -= 64 * y_min_px;
                c.to.x -= 64 * x_min_px;
                c.to.y -= 64 * y_min_px;
            },
        }
    }

    const pixels = try alloc.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    errdefer alloc.free(pixels);
    @memset(pixels, 0);
    try Rasterizer.render(alloc, pixels, width, height, common.CffSegments{ .segments = scaled }, &common.identity_coverage_lut);

    return .{ .width = @intCast(width), .rows = @intCast(height), .left = x_min_px, .top = y_max_px, .pixels_row_major = pixels };
}

fn transformToScaledPoint(m: Affine, x: i32, y: i32) IPoint {
    const t = m.apply(@floatFromInt(x), @floatFromInt(y));
    return .{ .x = @intFromFloat(@round(t.x * 64.0)), .y = @intFromFloat(@round(t.y * 64.0)) };
}
