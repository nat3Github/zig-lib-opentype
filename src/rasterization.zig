//! AA scanline rasterizer for OpenType outlines. Port of FreeType's
//! `smooth` module (`vendor/freetype/src/smooth/ftgrays.c`): exact-coverage
//! cell accumulation along edges, swept into a per-scanline gray bitmap.
//!
//! Ports the `FT_INT64` line/conic path (real FreeType builds take this
//! one, not the bisection/DDA-free fallback also in ftgrays.c, since
//! 64-bit ints are available on essentially every target) — matching it
//! exactly, including `FT_UDIV`'s deliberately-approximate reciprocal
//! division, was necessary to bit-match FreeType's actual coverage output
//! (verified against `test/fixtures/rasterization/manifest.json`).
//!
//! Deviation from ftgrays.c: FreeType uses a fixed-size cell pool with
//! band-splitting on overflow (`gray_convert_glyph`'s bisection loop),
//! because it targets a bounded render pool. We have a real alloc, so
//! cells are stored in a growable, sorted-by-x list per scanline row
//! instead — same accumulation math and sort invariant, no pool/overflow
//! machinery. Cubic (`gray_render_cubic`) is not ported: `glyf` outlines
//! are quadratic-only (CFF/cubic rasterization is a later addition once
//! CFF glyph rasterization is needed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const parsing = @import("parsing.zig");
const hinting = @import("hinting.zig");

pub const cff_hint = @import("rasterization/cff_hints.zig");

pub const ftMulFix = common.ftMulFix;
pub const ftDivFix = common.ftDivFix;

pub const CoverageContrast = mask_gamma.CoverageContrast;

const colr = @import("rasterization/colr.zig");
const common = @import("rasterization/common.zig");
const mask_gamma = @import("rasterization/mask_gamma.zig");
const Rasterizer = @import("rasterization/rasterizer.zig").Rasterizer;

const ColrWalker = colr.ColrWalker;
const Affine = colr.Affine;
const ScaledPoint = common.ScaledPoint;
const DrawOp = common.DrawOp;
const IPoint = common.IPoint;

pub const Bitmap8bit = struct {
    width: u32,
    rows: u32,
    left: i32,
    top: i32,
    pixels_row_major: []u8,

    pub const empty = Bitmap8bit{ .width = 0, .rows = 0, .left = 0, .top = 0, .pixels_row_major = zero_len_slice: {
        var b: []u8 = undefined;
        b.len = 0;
        break :zero_len_slice b;
    } };
    pub fn deinit(self: Bitmap8bit, alloc: Allocator) void {
        alloc.free(self.pixels_row_major);
    }
};

pub const RasterizeError = Allocator.Error;

pub const SubpixelOffset = struct { x: i32 = 0, y: i32 = 0 };

/// `want_pixels` false stops after the grid fit: the result carries the real
/// `width`/`rows`/`left`/`top` but no pixels, for callers that only need a
/// glyph's box (text layout/atlas placement) and not its coverage.
pub fn rasterizeCffOutline(
    alloc: Allocator,
    outline: parsing.Table.cff.Outline,
    units_per_em: u16,
    ppem: f32,
    phase: SubpixelOffset,
    want_pixels: bool,
) RasterizeError!Bitmap8bit {
    if (outline.segments.len == 0) return .empty;
    const scale = common.ftDivFix(@as(i32, @intFromFloat(@round(ppem))) * 64, units_per_em);

    var cbox_min_x: i32 = std.math.maxInt(i32);
    var cbox_min_y: i32 = std.math.maxInt(i32);
    var cbox_max_x: i32 = std.math.minInt(i32);
    var cbox_max_y: i32 = std.math.minInt(i32);

    const scaled = try alloc.alloc(common.IScaledCffSegment, outline.segments.len);
    defer alloc.free(scaled);

    for (outline.segments, 0..) |segment, i| {
        switch (segment) {
            .move_to => |p| {
                const sp = common.scaleCffPoint(p, scale, phase);
                cbox_min_x = @min(cbox_min_x, sp.x);
                cbox_min_y = @min(cbox_min_y, sp.y);
                cbox_max_x = @max(cbox_max_x, sp.x);
                cbox_max_y = @max(cbox_max_y, sp.y);
                scaled[i] = .{ .move_to = sp };
            },
            .line_to => |p| {
                const sp = common.scaleCffPoint(p, scale, phase);
                cbox_min_x = @min(cbox_min_x, sp.x);
                cbox_min_y = @min(cbox_min_y, sp.y);
                cbox_max_x = @max(cbox_max_x, sp.x);
                cbox_max_y = @max(cbox_max_y, sp.y);
                scaled[i] = .{ .line_to = sp };
            },
            .curve_to => |c| {
                const c1 = common.scaleCffPoint(c.c1, scale, phase);
                const c2 = common.scaleCffPoint(c.c2, scale, phase);
                const to = common.scaleCffPoint(c.to, scale, phase);
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

    return common.renderScaledCffSegments(alloc, scaled, want_pixels);
}

pub const CffHintError = RasterizeError || cff_hint.interp.InterpError || parsing.Font.ParseError;

fn cffHintPointToF26Dot6(p: cff_hint.glyphpath.Point, phase: SubpixelOffset) IPoint {
    return .{ .x = fixed16ToF26Dot6(p.x) + phase.x, .y = fixed16ToF26Dot6(p.y) + phase.y };
}

fn fixed16ToF26Dot6(x: i32) i32 {
    return x >> 10;
}

pub fn rasterizeCffOutlineHinted(
    alloc: Allocator,
    cff_data: []const u8,
    glyph_id: u16,
    units_per_em: u16,
    ppem: f32,
    phase: SubpixelOffset,
    darken: bool,
    want_pixels: bool,
) CffHintError!Bitmap8bit {
    var ctx = try parsing.Table.cff.Context.init(cff_data);
    return rasterizeCffOutlineHintedWithContext(alloc, &ctx, glyph_id, units_per_em, ppem, phase, darken, want_pixels);
}

/// Like `rasterizeCffOutlineHinted`, but reuses a caller-owned per-font CFF
/// context instead of re-parsing the font's INDEXes/DICTs for every glyph.
pub fn rasterizeCffOutlineHintedWithContext(
    alloc: Allocator,
    ctx: *parsing.Table.cff.Context,
    glyph_id: u16,
    units_per_em: u16,
    ppem: f32,
    phase: SubpixelOffset,
    darken: bool,
    want_pixels: bool,
) CffHintError!Bitmap8bit {
    const empty: Bitmap8bit = .empty;

    const charstring_data = try ctx.charstringAndSubrs(glyph_id);
    const private_hints = try ctx.privateHints(glyph_id);

    const cf2_ppem = cff_hint.intToFixed(@intFromFloat(@round(ppem)));
    const scale = cff_hint.divFix(cf2_ppem, cff_hint.intToFixed(@as(i32, units_per_em)));

    const result = try cff_hint.interp.render(alloc, charstring_data, private_hints, units_per_em, .{
        .scale_x = scale,
        .scale_y = scale,
        .ppem = cf2_ppem,
        .darken = darken,
    });
    defer alloc.free(result.segments);
    if (result.segments.len == 0) return empty;

    const scaled = try alloc.alloc(common.IScaledCffSegment, result.segments.len);
    defer alloc.free(scaled);

    for (result.segments, 0..) |segment, i| {
        scaled[i] = switch (segment) {
            .move_to => |p| .{ .move_to = cffHintPointToF26Dot6(p, phase) },
            .line_to => |p| .{ .line_to = cffHintPointToF26Dot6(p, phase) },
            .cube_to => |c| .{ .curve_to = .{
                .c1 = cffHintPointToF26Dot6(c.c1, phase),
                .c2 = cffHintPointToF26Dot6(c.c2, phase),
                .to = cffHintPointToF26Dot6(c.to, phase),
            } },
        };
    }

    return common.renderScaledCffSegments(alloc, scaled, want_pixels);
}

pub fn rasterizeTrueTypeGlyfOutline(
    alloc: Allocator,
    outline: parsing.Table.glyf.Outline,
    units_per_em: u16,
    ppem: f32,
    phase: SubpixelOffset,
    want_pixels: bool,
) RasterizeError!Bitmap8bit {
    const empty: Bitmap8bit = .empty;
    if (outline.points.len == 0 or outline.end_points_of_contours.len == 0) return empty;

    const scale = common.ftDivFix(@as(i32, @intFromFloat(@round(ppem))) * 64, units_per_em);

    const scaled_points = try alloc.alloc(ScaledPoint, outline.points.len);
    defer alloc.free(scaled_points);

    for (outline.points, 0..) |pt, i| {
        const sx = common.ftMulFix(pt.x, scale) + phase.x;
        const sy = common.ftMulFix(pt.y, scale) + phase.y;
        scaled_points[i] = .{ .p = .{ .x = sx, .y = sy }, .on = pt.on_curve };
    }

    return common.renderScaledPoints(alloc, scaled_points, outline.end_points_of_contours, want_pixels);
}

pub const HintError = RasterizeError || hinting.Error || parsing.Font.ParseError;

pub fn ppemScale(units_per_em: u16, ppem: f32) i32 {
    return common.ftDivFix(@as(i32, @intFromFloat(@round(ppem))) * 64, units_per_em);
}

pub fn scaleCvtFwordTableToF26Dot6Pixels(alloc: Allocator, cvt_data: []const u8, units_per_em: u16, ppem: f32) Allocator.Error![]i32 {
    const scale = ppemScale(units_per_em, ppem);
    const count = parsing.Table.cvt.count(cvt_data);
    const out = try alloc.alloc(i32, count);
    for (out, 0..) |*v, i| v.* = common.ftMulFix(parsing.Table.cvt.entry(cvt_data, @intCast(i)), scale);
    return out;
}

fn buildPtsVmHintZone(
    alloc: Allocator,
    outline: parsing.Table.glyf.Outline,
    bounds: parsing.Table.glyf.HeaderBounds,
    h_metric: parsing.Table.hmtx.Metric,
    v_metric: parsing.Table.vmtx.Metric,
    scale: i32,
    phase: SubpixelOffset,
) Allocator.Error!hinting.Zone {
    const n_real = outline.points.len;
    const n_total = n_real + 4;

    const point_bufs = try alloc.alloc(hinting.Point, n_total * 3);
    errdefer alloc.free(point_bufs);
    const cur = point_bufs[0..n_total];
    const org = point_bufs[n_total .. n_total * 2];
    const orus = point_bufs[n_total * 2 .. n_total * 3];
    const tags = try alloc.alloc(u8, n_total);
    errdefer alloc.free(tags);

    for (outline.points, 0..) |pt, i| {
        orus[i] = .{ .x = pt.x, .y = pt.y };
        const scaled: hinting.Point = .{
            .x = common.ftMulFix(pt.x, scale) + phase.x,
            .y = common.ftMulFix(pt.y, scale) + phase.y,
        };
        cur[i] = scaled;
        org[i] = scaled;
        tags[i] = if (pt.on_curve) hinting.on_curve else 0;
    }

    const phantom_orus = phantomOrusPositions(bounds, h_metric, v_metric);
    const phantom_cur = scaleAndRoundPhantomToF26Dot6Pixels(phantom_orus, scale, phase);
    for (phantom_orus, phantom_cur, 0..) |orus_p, cur_p, k| {
        orus[n_real + k] = orus_p;
        cur[n_real + k] = cur_p;
        org[n_real + k] = cur_p;
        tags[n_real + k] = 0;
    }

    return .{
        .n_points = @intCast(n_total),
        .n_contours = @intCast(outline.end_points_of_contours.len),
        .cur = cur,
        .org = org,
        .orus = orus,
        .tags = tags,
        .contours = outline.end_points_of_contours,
    };
}

fn freePtsVmHintZone(alloc: Allocator, zone: hinting.Zone) void {
    alloc.free(zone.cur.ptr[0 .. zone.cur.len * 3]);
    alloc.free(zone.tags);
}

fn phantomOrusPositions(bounds: parsing.Table.glyf.HeaderBounds, h_metric: parsing.Table.hmtx.Metric, v_metric: parsing.Table.vmtx.Metric) [4]hinting.Point {
    const pp1x: i32 = @as(i32, bounds.x_min) - h_metric.left_side_bearing;
    return .{
        .{ .x = pp1x, .y = 0 },
        .{ .x = pp1x + h_metric.advance_width, .y = 0 },
        .{ .x = 0, .y = @as(i32, bounds.y_max) + v_metric.top_side_bearing },
        .{ .x = 0, .y = @as(i32, bounds.y_max) + v_metric.top_side_bearing - v_metric.advance_height },
    };
}

fn scaleAndRoundPhantomToF26Dot6Pixels(phantom_orus: [4]hinting.Point, scale: i32, phase: SubpixelOffset) [4]hinting.Point {
    var cur: [4]hinting.Point = undefined;
    for (phantom_orus, 0..) |p, k| {
        cur[k] = .{ .x = common.ftMulFix(p.x, scale) + phase.x, .y = common.ftMulFix(p.y, scale) + phase.y };
    }
    cur[0].x = common.ftPixRound(cur[0].x);
    cur[1].x = common.ftPixRound(cur[1].x);
    cur[2].y = common.ftPixRound(cur[2].y);
    cur[3].y = common.ftPixRound(cur[3].y);
    return cur;
}

fn allocTwilightZone(alloc: Allocator, n: u16) Allocator.Error!hinting.Zone {
    const point_bufs = try alloc.alloc(hinting.Point, @as(usize, n) * 2);
    errdefer alloc.free(point_bufs);
    const cur = point_bufs[0..n];
    const org = point_bufs[n .. @as(usize, n) * 2];
    const tags = try alloc.alloc(u8, n);
    @memset(point_bufs, .{});
    @memset(tags, 0);
    return .{ .n_points = n, .n_contours = 0, .cur = cur, .org = org, .tags = tags };
}

fn freeTwilightZone(alloc: Allocator, zone: hinting.Zone) void {
    alloc.free(zone.cur.ptr[0 .. zone.cur.len * 2]);
    alloc.free(zone.tags);
}

const HintedComponent = struct {
    points: []hinting.Point,
    tags: []u8,
    contours: []u16,
    pp1: hinting.Point,
    pp2: hinting.Point,
    pp3: hinting.Point,
    pp4: hinting.Point,

    fn deinit(self: HintedComponent, alloc: Allocator) void {
        alloc.free(self.points);
        alloc.free(self.tags);
        alloc.free(self.contours);
    }
};

const max_component_depth = 8;

fn hintGlyphComponentRek(
    alloc: Allocator,
    interp: *hinting.Interpreter,
    glyf_data: []const u8,
    loca_data: []const u8,
    index_to_loc_format: i16,
    hmtx_data: []const u8,
    number_of_h_metrics: u16,
    vmtx_data: []const u8,
    number_of_v_metrics: u16,
    glyph_id: u16,
    max_twilight_points: u16,
    scale: i32,
    phase: SubpixelOffset,
    depth: u32,
) HintError!HintedComponent {
    if (depth > max_component_depth) return error.RecursionLimitExceeded;

    const glyph_data = try parsing.Table.glyf.readGlyph(alloc, glyf_data, loca_data, index_to_loc_format, glyph_id);
    defer parsing.Table.glyf.freeGlyphData(alloc, glyph_data);

    switch (glyph_data) {
        .empty => return .{ .points = &.{}, .tags = &.{}, .contours = &.{}, .pp1 = .{}, .pp2 = .{}, .pp3 = .{}, .pp4 = .{} },

        .simple => |outline| {
            if (outline.points.len == 0) return .{ .points = &.{}, .tags = &.{}, .contours = &.{}, .pp1 = .{}, .pp2 = .{}, .pp3 = .{}, .pp4 = .{} };

            const bounds = (try parsing.Table.glyf.headerBounds(glyf_data, loca_data, index_to_loc_format, glyph_id)) orelse
                return error.InvalidTableFormat;
            const h_metric = parsing.Table.hmtx.metricForGlyph(hmtx_data, glyph_id, number_of_h_metrics);
            const v_metric = if (vmtx_data.len != 0)
                parsing.Table.vmtx.metricForGlyph(vmtx_data, glyph_id, number_of_v_metrics)
            else
                parsing.Table.vmtx.Metric{ .advance_height = 0, .top_side_bearing = 0 };

            const pts = try buildPtsVmHintZone(alloc, outline, bounds, h_metric, v_metric, scale, phase);
            defer freePtsVmHintZone(alloc, pts);

            const twilight_n = @min(max_twilight_points, interp.limits.max_twilight_points);
            const twilight = try allocTwilightZone(alloc, twilight_n);
            defer freeTwilightZone(alloc, twilight);

            try interp.runGlyphProgram(outline.instructions, pts, twilight, false);

            const n_real = outline.points.len;
            return .{
                .points = try alloc.dupe(hinting.Point, pts.cur[0..n_real]),
                .tags = try alloc.dupe(u8, pts.tags[0..n_real]),
                .contours = try alloc.dupe(u16, outline.end_points_of_contours),
                .pp1 = pts.cur[n_real + 0],
                .pp2 = pts.cur[n_real + 1],
                .pp3 = pts.cur[n_real + 2],
                .pp4 = pts.cur[n_real + 3],
            };
        },

        .composite => |composite| {
            const bounds = (try parsing.Table.glyf.headerBounds(glyf_data, loca_data, index_to_loc_format, glyph_id)) orelse
                return error.InvalidTableFormat;
            const h_metric = parsing.Table.hmtx.metricForGlyph(hmtx_data, glyph_id, number_of_h_metrics);
            const v_metric = if (vmtx_data.len != 0)
                parsing.Table.vmtx.metricForGlyph(vmtx_data, glyph_id, number_of_v_metrics)
            else
                parsing.Table.vmtx.Metric{ .advance_height = 0, .top_side_bearing = 0 };
            const own_phantom = scaleAndRoundPhantomToF26Dot6Pixels(phantomOrusPositions(bounds, h_metric, v_metric), scale, phase);
            var pp1 = own_phantom[0];
            var pp2 = own_phantom[1];
            var pp3 = own_phantom[2];
            var pp4 = own_phantom[3];

            var points_list: std.ArrayList(hinting.Point) = .empty;
            defer points_list.deinit(alloc);
            var tags_list: std.ArrayList(u8) = .empty;
            defer tags_list.deinit(alloc);
            var contours_list: std.ArrayList(u16) = .empty;
            defer contours_list.deinit(alloc);

            for (composite.components) |c| {
                var child = try hintGlyphComponentRek(
                    alloc,
                    interp,
                    glyf_data,
                    loca_data,
                    index_to_loc_format,
                    hmtx_data,
                    number_of_h_metrics,
                    vmtx_data,
                    number_of_v_metrics,
                    c.glyph_index,
                    max_twilight_points,
                    scale,
                    phase,
                    depth + 1,
                );
                defer child.deinit(alloc);
                if (child.points.len == 0) continue;

                const xx: i32 = @intFromFloat(@round(c.xx * 65536.0));
                const xy: i32 = @intFromFloat(@round(c.xy * 65536.0));
                const yx: i32 = @intFromFloat(@round(c.yx * 65536.0));
                const yy: i32 = @intFromFloat(@round(c.yy * 65536.0));

                // NOTE: point-matching composite args (ARGS_ARE_XY_VALUES unset) are rare/deprecated; treated as a zero offset = `decodeCompositeGlyph`'s existing simplification.
                var ox: i32 = 0;
                var oy: i32 = 0;
                if (c.args_are_xy) {
                    ox = common.ftMulFix(@intFromFloat(c.arg1), scale);
                    oy = common.ftMulFix(@intFromFloat(c.arg2), scale);
                    if (c.round_xy_to_grid) {
                        ox = common.ftPixRound(ox);
                        oy = common.ftPixRound(oy);
                    }
                }

                const base_point_count: u16 = @intCast(points_list.items.len);
                for (child.points, child.tags) |p, tag| {
                    var nx = p.x;
                    var ny = p.y;
                    if (c.has_scale) {
                        nx = common.ftMulFix(p.x, xx) + common.ftMulFix(p.y, xy);
                        ny = common.ftMulFix(p.x, yx) + common.ftMulFix(p.y, yy);
                    }
                    try points_list.append(alloc, .{ .x = nx + ox, .y = ny + oy });
                    try tags_list.append(alloc, tag);
                }
                for (child.contours) |e|
                    try contours_list.append(alloc, e + base_point_count);
            }

            if (composite.instructions.len != 0 and points_list.items.len != 0) {
                const n_real = points_list.items.len;
                const n_total = n_real + 4;

                const point_bufs = try alloc.alloc(hinting.Point, n_total * 3);
                defer alloc.free(point_bufs);
                const cur = point_bufs[0..n_total];
                @memcpy(cur[0..n_real], points_list.items);
                cur[n_real..][0..4].* = .{ pp1, pp2, pp3, pp4 };

                const tags = try alloc.alloc(u8, n_total);
                defer alloc.free(tags);
                @memcpy(tags[0..n_real], tags_list.items);
                @memset(tags[n_real..], 0);

                // `TT_Hint_Glyph`'s undocumented composite special-case:
                // `org`/`orus` are just a copy of the already-hinted `cur`
                // (there's no font-unit space left to refer back to at this
                // point), and `interp.scale` is forced to identity for the
                // duration of this run so opcodes that rescale an
                // org/orus-derived distance by it (e.g. `SDPVTL`) leave
                // pixel-space distances unchanged.
                const org = point_bufs[n_total .. n_total * 2];
                @memcpy(org, cur);
                const orus = point_bufs[n_total * 2 .. n_total * 3];
                @memcpy(orus, cur);
                const contours = try alloc.dupe(u16, contours_list.items);
                defer alloc.free(contours);

                const zone: hinting.Zone = .{
                    .n_points = @intCast(n_total),
                    .n_contours = @intCast(contours.len),
                    .cur = cur,
                    .org = org,
                    .orus = orus,
                    .tags = tags,
                    .contours = contours,
                };

                const twilight_n = @min(max_twilight_points, interp.limits.max_twilight_points);
                const twilight = try allocTwilightZone(alloc, twilight_n);
                defer freeTwilightZone(alloc, twilight);

                const saved_scale = interp.scale;
                interp.scale = 0x10000;
                defer interp.scale = saved_scale;

                try interp.runGlyphProgram(composite.instructions, zone, twilight, true);

                for (points_list.items, 0..) |*p, i| p.* = zone.cur[i];
                pp1 = zone.cur[n_real + 0];
                pp2 = zone.cur[n_real + 1];
                pp3 = zone.cur[n_real + 2];
                pp4 = zone.cur[n_real + 3];
            }

            const points = try points_list.toOwnedSlice(alloc);
            errdefer alloc.free(points);
            const tags = try tags_list.toOwnedSlice(alloc);
            errdefer alloc.free(tags);
            const contours = try contours_list.toOwnedSlice(alloc);
            errdefer alloc.free(contours);

            return .{
                .points = points,
                .tags = tags,
                .contours = contours,
                .pp1 = pp1,
                .pp2 = pp2,
                .pp3 = pp3,
                .pp4 = pp4,
            };
        },
    }
}

/// `max_twilight_points` is the font's declared `maxp.maxTwilightPoints`,
/// clamped against `interp.limits.max_twilight_points` before allocating —
/// the hard cap always wins regardless of what the (attacker-controlled)
/// font claims. `vmtx_data`/`number_of_v_metrics` may be empty/0 for fonts
/// without vertical metrics (phantom points 3/4 then default to `{0, 0}`).
pub fn rasterizeGlyfHinted(
    alloc: Allocator,
    interp: *hinting.Interpreter,
    glyf_data: []const u8,
    loca_data: []const u8,
    index_to_loc_format: i16,
    hmtx_data: []const u8,
    number_of_h_metrics: u16,
    vmtx_data: []const u8,
    number_of_v_metrics: u16,
    glyph_id: u16,
    max_twilight_points: u16,
    units_per_em: u16,
    ppem: f32,
    phase: SubpixelOffset,
    want_pixels: bool,
) HintError!Bitmap8bit {
    const scale = ppemScale(units_per_em, ppem);
    interp.cur_ppem = @intFromFloat(@round(ppem));
    interp.scale = scale;

    var result = try hintGlyphComponentRek(
        alloc,
        interp,
        glyf_data,
        loca_data,
        index_to_loc_format,
        hmtx_data,
        number_of_h_metrics,
        vmtx_data,
        number_of_v_metrics,
        glyph_id,
        max_twilight_points,
        scale,
        phase,
        0,
    );
    defer result.deinit(alloc);
    if (result.points.len == 0 or result.contours.len == 0) return .empty;

    const pp1_x = result.pp1.x;
    const scaled_points = try alloc.alloc(ScaledPoint, result.points.len);
    defer alloc.free(scaled_points);
    for (result.points, result.tags, 0..) |p, tag, i| {
        scaled_points[i] = .{ .p = .{ .x = p.x - pp1_x, .y = p.y }, .on = (tag & hinting.on_curve) != 0 };
    }

    return common.renderScaledPoints(alloc, scaled_points, result.contours, want_pixels);
}

pub const VerticalOrigin = struct {
    /// Where the vertical pen's y-position sits, in the same pixel space
    /// (origin at the bitmap's top-left, y increases downward from there)
    /// as `Bitmap.top` - place the bitmap at `pen_y - origin_y + bitmap.top`.
    origin_y: i32,
    /// Pixel distance to advance the pen for the next glyph (subtract from
    /// `pen_y`, since vertical text flows top-to-bottom).
    advance_height: i32,
};

pub fn verticalOrigin(bitmap: Bitmap8bit, vertical_metric: parsing.Table.vmtx.Metric, units_per_em: u16, ppem: f32) VerticalOrigin {
    const scale = common.ftDivFix(@as(i32, @intFromFloat(@round(ppem))) * 64, units_per_em);
    return .{
        .origin_y = bitmap.top + (common.ftMulFix(vertical_metric.top_side_bearing, scale) >> 6),
        .advance_height = common.ftMulFix(vertical_metric.advance_height, scale) >> 6,
    };
}

pub const BitmapRgba8bit = Bitmap8bit;
pub const RasterizeSbixError = parsing.Font.ParseError || parsing.Table.sbix.GraphicError || parsing.PngDecodeError || Allocator.Error;

pub const SbixFallbackOutline = struct {
    glyf_data: []const u8,
    loca_data: []const u8,
    index_to_loc_format: i16,
    hmtx_data: []const u8,
    number_of_h_metrics: u16,
    units_per_em: u16,
};

/// Bilinear-resamples an RGBA8 image to `new_width`x`new_height`, allocated
/// with `alloc` (the caller frees `src` and owns the result).
fn resizeImageBilinear(alloc: Allocator, src: parsing.png.Image, new_width: u32, new_height: u32) Allocator.Error!parsing.png.Image {
    if (new_width == 0 or new_height == 0 or src.width == 0 or src.height == 0) {
        return .{ .width = 0, .height = 0, .pixels = try alloc.alloc(u8, 0) };
    }
    const pixels = try alloc.alloc(u8, @as(usize, new_width) * new_height * 4);
    const src_w_f: f32 = @floatFromInt(src.width);
    const src_h_f: f32 = @floatFromInt(src.height);
    const dst_w_f: f32 = @floatFromInt(new_width);
    const dst_h_f: f32 = @floatFromInt(new_height);
    const src_w_max: i32 = @as(i32, @intCast(src.width)) - 1;
    const src_h_max: i32 = @as(i32, @intCast(src.height)) - 1;

    var dy: u32 = 0;
    while (dy < new_height) : (dy += 1) {
        const sy_f = (@as(f32, @floatFromInt(dy)) + 0.5) * src_h_f / dst_h_f - 0.5;
        const sy0f = @floor(sy_f);
        const wy = sy_f - sy0f;
        const sy0: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(sy0f)), 0, src_h_max));
        const sy1: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(sy0f)) + 1, 0, src_h_max));

        var dx: u32 = 0;
        while (dx < new_width) : (dx += 1) {
            const sx_f = (@as(f32, @floatFromInt(dx)) + 0.5) * src_w_f / dst_w_f - 0.5;
            const sx0f = @floor(sx_f);
            const wx = sx_f - sx0f;
            const sx0: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(sx0f)), 0, src_w_max));
            const sx1: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(sx0f)) + 1, 0, src_w_max));

            const p00 = src.pixels[(sy0 * src.width + sx0) * 4 ..][0..4];
            const p10 = src.pixels[(sy0 * src.width + sx1) * 4 ..][0..4];
            const p01 = src.pixels[(sy1 * src.width + sx0) * 4 ..][0..4];
            const p11 = src.pixels[(sy1 * src.width + sx1) * 4 ..][0..4];
            const out = pixels[(dy * new_width + dx) * 4 ..][0..4];
            inline for (0..4) |c| {
                const top_v = @as(f32, @floatFromInt(p00[c])) * (1 - wx) + @as(f32, @floatFromInt(p10[c])) * wx;
                const bot_v = @as(f32, @floatFromInt(p01[c])) * (1 - wx) + @as(f32, @floatFromInt(p11[c])) * wx;
                out[c] = @intFromFloat(std.math.clamp(@round(top_v * (1 - wy) + bot_v * wy), 0, 255));
            }
        }
    }
    return .{ .width = new_width, .height = new_height, .pixels = pixels };
}

/// `scratch_alloc` backs temp buffers freed before this returns; `alloc`
/// backs the returned pixels (exactly `width * rows * 4` bytes), owned by
/// the caller.
pub fn rasterizeSbix(
    scratch_alloc: Allocator,
    alloc: Allocator,
    sbix_data: []const u8,
    ppem: u16,
    glyph_id: u16,
    fallback_outline: ?SbixFallbackOutline,
) RasterizeSbixError!?BitmapRgba8bit {
    const strike = try parsing.Table.sbix.findStrike(sbix_data, ppem) orelse return null;
    var decoded = try parsing.Table.sbix.decodeGlyph(scratch_alloc, alloc, sbix_data, strike, glyph_id) orelse return null;
    errdefer decoded.image.deinit(alloc);

    // sbix only embeds a handful of fixed-size strikes; scale the nearest
    // one (picked by findStrike) to the requested ppem.
    if (strike.ppem != ppem) {
        const scale: f32 = @as(f32, @floatFromInt(ppem)) / @as(f32, @floatFromInt(strike.ppem));
        const new_width: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(decoded.image.width)) * scale));
        const new_height: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(decoded.image.height)) * scale));
        const resized = try resizeImageBilinear(alloc, decoded.image, new_width, new_height);
        decoded.image.deinit(alloc);
        decoded.image = resized;
        decoded.origin_offset_x = @intFromFloat(@round(@as(f32, @floatFromInt(decoded.origin_offset_x)) * scale));
        decoded.origin_offset_y = @intFromFloat(@round(@as(f32, @floatFromInt(decoded.origin_offset_y)) * scale));
    }

    var left: i32 = decoded.origin_offset_x;
    var top: i32 = @as(i32, decoded.origin_offset_y) + @as(i32, @intCast(decoded.image.height));

    if (fallback_outline) |fo| {
        const header = try parsing.Table.glyf.headerBounds(fo.glyf_data, fo.loca_data, fo.index_to_loc_format, glyph_id);
        if (header) |h| {
            if (h.number_of_contours > 0) {
                const scale = common.ftDivFix(@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(ppem))))) * 64, fo.units_per_em);
                const lsb = parsing.Table.hmtx.metricForGlyph(fo.hmtx_data, glyph_id, fo.number_of_h_metrics).left_side_bearing;
                left += common.ftMulFix(lsb, scale) >> 6;
                top += common.ftMulFix(h.y_min, scale) >> 6;
            }
        }
    }

    return .{
        .width = decoded.image.width,
        .rows = decoded.image.height,
        .left = left,
        .top = top,
        .pixels_row_major = decoded.image.pixels,
    };
}

pub const RasterizeCbdtError = parsing.Font.ParseError || parsing.Table.CBLC.GraphicError || parsing.PngDecodeError || Allocator.Error;

/// `scratch_alloc` backs temp buffers freed before this returns; `alloc`
/// backs the returned pixels (exactly `width * rows * 4` bytes), owned by
/// the caller.
pub fn rasterizeCbdt(
    scratch_alloc: Allocator,
    alloc: Allocator,
    cblc_data: []const u8,
    cbdt_data: []const u8,
    ppem: u16,
    glyph_id: u16,
) RasterizeCbdtError!?BitmapRgba8bit {
    const strike = try parsing.Table.CBLC.findStrike(cblc_data, ppem) orelse return null;
    const decoded = try parsing.Table.CBLC.decodeGlyph(scratch_alloc, alloc, cblc_data, cbdt_data, strike, glyph_id) orelse return null;

    return .{
        .width = decoded.image.width,
        .rows = decoded.image.height,
        .left = decoded.hori_bearing_x,
        .top = decoded.hori_bearing_y,
        .pixels_row_major = decoded.image.pixels,
    };
}

pub const OutlineSource = union(enum) {
    glyf: struct { glyf_data: []const u8, loca_data: []const u8, index_to_loc_format: i16 },
    cff: struct { cff_data: []const u8 },
};

pub const RasterizeColrError = parsing.Font.ParseError || RasterizeError || error{ColrPaintNestingTooDeep};

pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn fromCpal(c: parsing.Table.CPAL.Color) Rgba {
        return .{ .r = c.red, .g = c.green, .b = c.blue, .a = c.alpha };
    }
};

pub const GradientPoint = struct { x: f64, y: f64 };

pub const GradientStop = struct { offset: f64, color: Rgba, alpha: f32 };

pub const GradientGeometry = union(enum) {
    linear: struct { p0: GradientPoint, p1: GradientPoint, p2: GradientPoint },
    radial: struct { c0: GradientPoint, r0: f64, c1: GradientPoint, r1: f64 },
    sweep: struct { center: GradientPoint, start_deg: f64, end_deg: f64 },
};

pub const CoverageMaskFillSource = union(enum) {
    solid: struct { color: Rgba, alpha: f32 },
    /// `inverse` maps device pixels (bitmap-local, `.left`/`.top`-relative
    /// coordinates as documented on `Bitmap`) back into the space `geometry`
    /// is expressed in — pass `Affine{}` (identity) to give `geometry` in
    /// device-pixel space directly.
    gradient: struct { geometry: GradientGeometry, extend: u8, stops: []const GradientStop, inverse: Affine },
    /// A fully pre-composited RGBA8 source (`PaintComposite`'s rendered
    /// sub-graph result) — the owning `DrawOp.bitmap` is an all-255 mask
    /// the same size as `rgba`, so the shared per-pixel loop in
    /// `compositeOpsToCanvas` reads color straight from `rgba` instead of
    /// resolving a solid/gradient.
    image: struct { rgba: []const u8 },
    /// A tileable RGBA8 source sampled through `inverse` the same way
    /// `gradient` is, but indexed into a `width` x `height` pixel grid
    /// (row-major, straight alpha) instead of evaluated along a color
    /// line — `extend` reuses the gradient pad(0)/repeat(1)/reflect(2)
    /// convention, applied independently to both axes. Not a COLRv1 paint
    /// format; for callers building their own `Paint` (e.g.
    /// `fillMaskedOutline`) that want a raster pattern fill.
    pattern: struct { rgba: []const u8, width: u32, height: u32, extend: u8, inverse: Affine },

    pub fn free(paint: CoverageMaskFillSource, alloc: Allocator) void {
        switch (paint) {
            .gradient => |g| alloc.free(g.stops),
            .image => |im| alloc.free(im.rgba),
            .pattern => |p| alloc.free(p.rgba),
            .solid => {},
        }
    }
};

pub fn recolorCoverageMask(
    alloc: Allocator,
    mask: Bitmap8bit,
    paint: CoverageMaskFillSource,
    coverage_contrast: CoverageContrast,
) RasterizeColrError!BitmapRgba8bit {
    return common.compositeOpsToCanvas(alloc, &.{.{ .bitmap = mask, .paint = paint }}, coverage_contrast);
}

pub fn freeOps(alloc: Allocator, ops: []const DrawOp) void {
    for (ops) |op| {
        op.bitmap.deinit(alloc);
        op.paint.free(alloc);
    }
}

pub const RasterizeColrOptions = struct {
    palette_index: u16 = 0,
    foreground_color: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    coverage_contrast: CoverageContrast = .{},
};

/// Returns `null` if `glyph_id` isn't a color glyph in this `COLR` table.
/// `scratch_allocator` backs the per-layer paint ops (freed before this
/// returns); `output_allocator` backs the returned pixels (exactly
/// `width * rows * 4` bytes), owned by the caller.
pub fn rasterizeColr(
    scratch_allocator: Allocator,
    output_allocator: Allocator,
    colr_data: []const u8,
    cpal_data: []const u8,
    source: OutlineSource,
    units_per_em: u16,
    ppem: f32,
    glyph_id: u16,
    options: RasterizeColrOptions,
) RasterizeColrError!?BitmapRgba8bit {
    var coverage_contrast = options.coverage_contrast;
    coverage_contrast.ppem = ppem;

    var walker: ColrWalker = .{
        .scratch_allocator = scratch_allocator,
        .colr_data = colr_data,
        .cpal_data = cpal_data,
        .palette_index = options.palette_index,
        .foreground_color = options.foreground_color,
        .source = source,
        .coverage_contrast = coverage_contrast,
    };
    defer walker.deinit();

    const pixel_scale = @as(f64, ppem) / @as(f64, @floatFromInt(units_per_em));
    const root_matrix = Affine.scale(pixel_scale, pixel_scale);

    if (try parsing.Table.COLR.baseGlyphPaintOffset(colr_data, glyph_id)) |paint_offset| {
        try walker.walkPaint(try parsing.Table.COLR.paintAt(colr_data, paint_offset), root_matrix, 0);
    } else if (try parsing.Table.COLR.baseGlyphV0(colr_data, glyph_id)) |base| {
        var i: u16 = 0;
        while (i < base.num_layers) : (i += 1) {
            const layer = try parsing.Table.COLR.layerV0At(colr_data, base.first_layer_index, i);
            const resolved = try walker.resolvedColor(layer.palette_index, 16384);
            try walker.drawGlyph(layer.glyph_id, root_matrix, .{ .solid = .{ .color = resolved.color, .alpha = resolved.alpha } });
        }
    } else {
        return null;
    }

    return try common.compositeOpsToCanvas(output_allocator, walker.ops.items, walker.coverage_contrast);
}
