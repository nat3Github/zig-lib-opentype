//! Library entry point for rasterizing a shaped glyph run. Owns the render
//! policy that decides *how* to rasterize each glyph (colr/sbix/cbdt/glyf/
//! CFF/CFF2 dispatch, CFF hinting below 28ppem, auto-opsz instancing,
//! subpixel phase from pen position, coverage-contrast darkening) so callers
//! don't have to reimplement it — `rasterization.zig`'s functions are the
//! primitives this composes, not something callers pick among directly.

const std = @import("std");
const parsing = @import("parsing.zig");
const shaping = @import("shaping.zig");
const rasterization = @import("rasterization.zig");
const hinting = @import("hinting.zig");

pub const UserCoord = struct { tag: parsing.Font.Tag, value: f32 };

/// `Renderer.init` options.
pub const RenderOptions = struct {
    user_coords: []const UserCoord = &.{},
    /// Opt-in: run `glyf` outlines through the classic (v35) TrueType
    /// bytecode hinter below `glyf_hinting_ppem_threshold`. Off by default —
    /// browsers mostly don't run this hinter either (CoreText on Mac,
    /// DirectWrite's own hinter on Windows; even Linux's fontconfig default
    /// is closer to a Y-only "slight" autohint than full v35), and it can
    /// look boxy on fonts that weren't authored/tested against it. Turn it
    /// on for content actually hinted for v35, or to match FreeType.
    hint_glyf: bool = false,
};

/// `renderGlyph`'s result: the rasterized bitmap plus which family of
/// source produced it. Callers compositing text need this to tell a
/// pre-colored glyph (COLR/sbix/CBDT — `width * rows * 4` straight RGBA,
/// draw as-is) from a coverage mask (glyf/CFF/CFF2 — `width * rows`
/// contrast-mapped coverage bytes, tinted by the caller) apart; the bitmap
/// type alone can't tell the two layouts apart.
pub const RenderedGlyph = struct {
    bitmap: rasterization.BitmapRgba8bit,
    is_color: bool,

    pub fn deinit(self: RenderedGlyph, allocator: std.mem.Allocator) void {
        self.bitmap.deinit(allocator);
    }
};

/// `Renderer.glyphBounds`' result: the same `width`/`rows`/`left`/`top` the
/// `RenderedGlyph` bitmap would carry, with no pixels behind them.
pub const GlyphBounds = struct {
    width: u32,
    rows: u32,
    left: i32,
    top: i32,
    is_color: bool,
};

pub const PositionedGlyph = struct {
    bitmap: rasterization.BitmapRgba8bit,
    origin_x: i32,
    origin_y: i32,
    is_color: bool,

    pub fn deinit(self: PositionedGlyph, allocator: std.mem.Allocator) void {
        self.bitmap.deinit(allocator);
    }
};

pub const Run = struct {
    glyphs: []PositionedGlyph,

    pub fn deinit(self: Run, allocator: std.mem.Allocator) void {
        for (self.glyphs) |g| g.deinit(allocator);
        allocator.free(self.glyphs);
    }
};

pub const InitError = parsing.Font.ParseError || std.mem.Allocator.Error;
pub const RenderError = rasterization.RasterizeColrError ||
    rasterization.RasterizeSbixError ||
    rasterization.RasterizeCbdtError ||
    rasterization.CffHintError ||
    rasterization.HintError;

/// Below this device ppem, CFF glyphs route through the cf2 hinting engine
/// (blue-zone snapping + stem darkening) instead of the unhinted direct
/// scale — matches FreeType/CoreText quality at small sizes; large sizes
/// stay unhinted like Chrome/Skia do.
const cff_hinting_ppem_threshold: f32 = 28;

/// Below this device ppem, `glyf` outlines route through the classic v35
/// hinter (when `RenderOptions.hint_glyf` opts in) instead of unhinted
/// direct scaling. Matches how browsers actually spend their hinting
/// budget: full bytecode hinting is a low-DPI-body-text crutch, not
/// something applied at display/2x sizes. Since callers pass true device
/// ppem (`css_px * dpi_scale`), a 2x-scaled 16px glyph already lands at
/// 32 device ppem and clears this threshold on its own — no separate DPI
/// signal needed on top of the ppem check.
const glyf_hinting_ppem_threshold: f32 = 20;

/// Rasterizes glyphs from one (font, ppem, variation-coords) combination —
/// construct once per distinct combination, then call `renderGlyph`/
/// `renderBuffer` for every glyph shaped at that size.
// Allocators are never stored on `Renderer` — every function that needs one
// takes it as an explicit argument, so the caller decides per call (not
// per-Renderer-lifetime) where memory comes from. Three roles show up
// throughout this file:
//   - `state_allocator`: backs `Renderer`'s own fields (`normalized`,
//     `gvar_header`, the hinting interpreter's buffers). Passed to `init`
//     and must be passed again, unchanged, to `deinit`.
//   - `scratch_allocator`: backs memory that's allocated and freed again
//     within the same call — outline points, coverage masks, temp CVT
//     tables. Never observed by the caller, so it can be an arena reset
//     after every call.
//   - `output_allocator`: backs the bitmap pixels and `Run`/`PositionedGlyph`
//     slices handed back to the caller. Lives past the call that produced
//     it; the caller frees it explicitly via `Run.deinit`/`PositionedGlyph.deinit`
//     with this same allocator.
pub const Renderer = struct {
    font: parsing.Font,
    head: parsing.Table.head,
    /// Outline/color table blobs resolved once in `init` -- `tableData` is a
    /// linear scan of the table directory, and `renderGlyph` would otherwise
    /// repeat it per glyph.
    glyf_data: ?[]const u8,
    loca_data: ?[]const u8,
    cff_data: ?[]const u8,
    /// Heap-allocated rather than inline: `Renderer` is copied by value by
    /// consumers (dvui's `Font.Entry.toPixels`), and the context's cached
    /// Private DICT hints are several hundred bytes.
    cff_context: ?*parsing.Table.cff.Context,
    cff2_data: ?[]const u8,
    colr_data: ?[]const u8,
    cpal_data: ?[]const u8,
    sbix_data: ?[]const u8,
    cblc_data: ?[]const u8,
    cbdt_data: ?[]const u8,
    ppem: f32,
    normalized: []const f32,
    gvar_header: ?parsing.Table.gvar.Header,
    gvar_data: []const u8,
    hmtx_data: []const u8,
    number_of_h_metrics: u16,
    vmtx_data: []const u8,
    number_of_v_metrics: u16,
    /// True when this instance is away from the font's default (i.e.
    /// `outlineVaried` is in play). TT hinting programs assume the
    /// font-unit outline they were authored against; running them on a
    /// gvar-interpolated instance fights the interpolation instead of
    /// complementing it, so hinting is skipped whenever this is set —
    /// matches FreeType/Chrome's own default instance-only hinting.
    vary: bool,
    /// Non-null only when `RenderOptions.hint_glyf` was requested and this
    /// (font, ppem, coords) combination is actually eligible (glyf table
    /// present, `ppem < glyf_hinting_ppem_threshold`, default instance) —
    /// `fpgm`/`prep` have already run against it by the time `init`
    /// returns, so `renderGlyph` only has to run each glyph's own program.
    glyf_interp: ?hinting.Interpreter,
    max_twilight_points: u16,
    /// From `maxp` -- guards `renderGlyph` against a glyph id from a
    /// mismatched font (stale cache entry, wrong fallback pairing upstream)
    /// that would otherwise read past `loca`/a charstring offset array.
    num_glyphs: u16,

    pub fn init(
        state_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        font: parsing.Font,
        ppem: f32,
        options: RenderOptions,
    ) (InitError || hinting.Error)!Renderer {
        const head_data = font.tableData(.{ 'h', 'e', 'a', 'd' }) orelse return error.InvalidTableFormat;
        const head = try parsing.Table.head.parse(head_data);

        const maxp_data = font.tableData(.{ 'm', 'a', 'x', 'p' }) orelse return error.InvalidTableFormat;
        const maxp = try parsing.Table.maxp.parse(maxp_data);

        var gvar_header: ?parsing.Table.gvar.Header = null;
        const gvar_data = font.tableData(.{ 'g', 'v', 'a', 'r' }) orelse &.{};
        if (gvar_data.len != 0) gvar_header = try parsing.Table.gvar.parseHeader(state_allocator, gvar_data);
        errdefer if (gvar_header) |h| {
            state_allocator.free(h.glyph_offsets);
            if (h.shared_tuples.len != 0) state_allocator.free(h.shared_tuples);
        };

        var hmtx_data: []const u8 = &.{};
        var number_of_h_metrics: u16 = 0;
        if (font.tableData(.{ 'h', 'm', 't', 'x' })) |hmtx_table| {
            hmtx_data = hmtx_table;
            if (font.tableData(.{ 'h', 'h', 'e', 'a' })) |hhea_table| {
                number_of_h_metrics = (try parsing.Table.hhea.parse(hhea_table)).number_of_h_metrics;
            }
        }

        var vmtx_data: []const u8 = &.{};
        var number_of_v_metrics: u16 = 0;
        if (font.tableData(.{ 'v', 'm', 't', 'x' })) |vmtx_table| {
            vmtx_data = vmtx_table;
            if (font.tableData(.{ 'v', 'h', 'e', 'a' })) |vhea_table| {
                number_of_v_metrics = (try parsing.Table.vhea.parse(vhea_table)).number_of_long_ver_metrics;
            }
        }

        var cff_context: ?*parsing.Table.cff.Context = null;
        if (font.tableData(.{ 'C', 'F', 'F', ' ' })) |cff_table| {
            if (parsing.Table.cff.Context.init(cff_table) catch null) |ctx| {
                cff_context = try state_allocator.create(parsing.Table.cff.Context);
                cff_context.?.* = ctx;
            }
        }
        errdefer if (cff_context) |ctx| state_allocator.destroy(ctx);

        var renderer: Renderer = .{
            .font = font,
            .head = head,
            .glyf_data = font.tableData(.{ 'g', 'l', 'y', 'f' }),
            .loca_data = font.tableData(.{ 'l', 'o', 'c', 'a' }),
            .cff_data = font.tableData(.{ 'C', 'F', 'F', ' ' }),
            .cff_context = cff_context,
            .cff2_data = font.tableData(.{ 'C', 'F', 'F', '2' }),
            .colr_data = font.tableData(.{ 'C', 'O', 'L', 'R' }),
            .cpal_data = font.tableData(.{ 'C', 'P', 'A', 'L' }),
            .sbix_data = font.tableData(.{ 's', 'b', 'i', 'x' }),
            .cblc_data = font.tableData(.{ 'C', 'B', 'L', 'C' }),
            .cbdt_data = font.tableData(.{ 'C', 'B', 'D', 'T' }),
            .ppem = ppem,
            .num_glyphs = maxp.num_glyphs,
            .normalized = &.{},
            .gvar_header = gvar_header,
            .gvar_data = gvar_data,
            .hmtx_data = hmtx_data,
            .number_of_h_metrics = number_of_h_metrics,
            .vmtx_data = vmtx_data,
            .number_of_v_metrics = number_of_v_metrics,
            .vary = false,
            .glyf_interp = null,
            .max_twilight_points = maxp.max_twilight_points,
        };
        // gvar/cff unwind through their own errdefers above; this covers only
        // what `setPpem` itself allocates.
        errdefer {
            if (renderer.normalized.len != 0) state_allocator.free(renderer.normalized);
            if (renderer.glyf_interp) |*interp| interp.deinit();
        }

        try renderer.setPpem(state_allocator, scratch_allocator, ppem, options);
        return renderer;
    }

    /// Re-targets an existing `Renderer` at a different ppem, keeping the
    /// parsed tables, gvar header, CFF context and hinting allocation —
    /// only the normalized coords (auto-opsz depends on ppem) and the
    /// hinter's scaled CVT/`prep` state actually depend on it. `options`
    /// must be the ones `init` was called with. `state_allocator` must be
    /// the one passed to `init`.
    pub fn setPpem(
        self: *Renderer,
        state_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        ppem: f32,
        options: RenderOptions,
    ) (InitError || hinting.Error)!void {
        const normalized = try normalizedCoords(state_allocator, scratch_allocator, self.font, options.user_coords, ppem);
        if (self.normalized.len != 0) state_allocator.free(self.normalized);
        self.normalized = normalized;
        self.ppem = ppem;
        self.vary = self.gvar_header != null and anyNonDefault(normalized);

        if (options.hint_glyf and self.glyf_data != null and ppem < glyf_hinting_ppem_threshold and !self.vary) {
            if (self.glyf_interp == null) self.glyf_interp = try hinting.Interpreter.init(state_allocator, .{});
            const interp = &self.glyf_interp.?;

            // `fpgm`/`prep` persist storage and FDEFs, so a re-target has to
            // replay them from a zeroed storage area to land where a freshly
            // constructed interpreter would.
            @memset(interp.storage, 0);
            try interp.runFontProgram(self.font.tableData(.{ 'f', 'p', 'g', 'm' }) orelse &.{});

            interp.cur_ppem = @intFromFloat(@round(ppem));
            interp.scale = rasterization.ppemScale(self.head.units_per_em, ppem);
            const cvt_data = self.font.tableData(.{ 'c', 'v', 't', ' ' }) orelse &.{};
            const scaled_cvt = try rasterization.scaleCvtFwordTableToF26Dot6Pixels(scratch_allocator, cvt_data, self.head.units_per_em, ppem);
            defer scratch_allocator.free(scaled_cvt);
            try interp.setCvt(scaled_cvt);
            try interp.runCvtProgram(self.font.tableData(.{ 'p', 'r', 'e', 'p' }) orelse &.{});
        } else if (self.glyf_interp) |*interp| {
            interp.deinit();
            self.glyf_interp = null;
        }
    }

    /// Converts a raw font-unit value (e.g. an `hhea` ascender or a GPOS
    /// `x_advance`) to pixels using the same 26.6 fixed-point rounding
    /// `renderBuffer`/rasterization use internally, so callers computing
    /// their own text metrics stay pixel-consistent with what actually
    /// gets rasterized.
    pub fn unitsToPixels(self: *const Renderer, font_units: i32) f32 {
        const scale = rasterization.ftDivFix(@as(i32, @intFromFloat(@round(self.ppem))) * 64, self.head.units_per_em);
        return @as(f32, @floatFromInt(rasterization.ftMulFix(font_units, scale))) / 64.0;
    }

    /// `state_allocator` must be the same allocator passed to `init`.
    pub fn deinit(self: *Renderer, state_allocator: std.mem.Allocator) void {
        if (self.normalized.len != 0) state_allocator.free(self.normalized);
        if (self.gvar_header) |h| {
            state_allocator.free(h.glyph_offsets);
            if (h.shared_tuples.len != 0) state_allocator.free(h.shared_tuples);
        }
        if (self.glyf_interp) |*interp| interp.deinit();
        if (self.cff_context) |ctx| state_allocator.destroy(ctx);
    }

    fn anyNonDefault(coords: []const f32) bool {
        for (coords) |c| {
            if (c != 0) return true;
        }
        return false;
    }

    fn contrastedCoverage(self: Renderer, mask: rasterization.Bitmap8bit, output_allocator: std.mem.Allocator) std.mem.Allocator.Error!rasterization.Bitmap8bit {
        const contrast: rasterization.CoverageContrast = .{ .ppem = self.ppem };
        const lut = contrast.lut();
        const pixels = try output_allocator.alloc(u8, @as(usize, mask.width) * mask.rows);
        for (pixels, mask.pixels_row_major[0..pixels.len]) |*pixel, coverage| {
            pixel.* = if (coverage == 0) 0 else lut[coverage];
        }
        return .{ .width = mask.width, .rows = mask.rows, .left = mask.left, .top = mask.top, .pixels_row_major = pixels };
    }

    fn colrOutlineSource(self: Renderer) ?rasterization.OutlineSource {
        if (self.glyf_data) |glyf_table| {
            const loca_table = self.loca_data orelse return null;
            return .{ .glyf = .{
                .glyf_data = glyf_table,
                .loca_data = loca_table,
                .index_to_loc_format = self.head.index_to_loc_format,
            } };
        }
        if (self.cff_data) |cff_table| {
            return .{ .cff = .{ .cff_data = cff_table } };
        }
        return null;
    }

    /// Metrics-only callers get the grid-fit box the rasterizer computes
    /// before scan conversion; the coverage-contrast pass and the pixel
    /// allocation only happen when `want_pixels` is set.
    fn finishOutlineMask(
        self: Renderer,
        mask: rasterization.Bitmap8bit,
        output_allocator: std.mem.Allocator,
        want_pixels: bool,
    ) std.mem.Allocator.Error!rasterization.Bitmap8bit {
        if (!want_pixels) return .{
            .width = mask.width,
            .rows = mask.rows,
            .left = mask.left,
            .top = mask.top,
            .pixels_row_major = rasterization.Bitmap8bit.empty.pixels_row_major,
        };
        return self.contrastedCoverage(mask, output_allocator);
    }

    fn renderOutline(
        self: *Renderer,
        glyph_id: u16,
        phase: rasterization.SubpixelOffset,
        scratch_allocator: std.mem.Allocator,
        output_allocator: std.mem.Allocator,
        want_pixels: bool,
    ) RenderError!rasterization.Bitmap8bit {
        const units_per_em = self.head.units_per_em;
        const vary = self.vary;

        if (self.glyf_data) |glyf_table| {
            const loca_table = self.loca_data.?;
            if (self.glyf_interp) |*interp| {
                const mask = try rasterization.rasterizeGlyfHinted(
                    scratch_allocator,
                    interp,
                    glyf_table,
                    loca_table,
                    self.head.index_to_loc_format,
                    self.hmtx_data,
                    self.number_of_h_metrics,
                    self.vmtx_data,
                    self.number_of_v_metrics,
                    glyph_id,
                    self.max_twilight_points,
                    units_per_em,
                    self.ppem,
                    phase,
                    want_pixels,
                );
                defer mask.deinit(scratch_allocator);
                return self.finishOutlineMask(mask, output_allocator, want_pixels);
            }
            const outline = if (vary) try parsing.Table.glyf.outlineVaried(
                scratch_allocator,
                glyf_table,
                loca_table,
                self.head.index_to_loc_format,
                self.hmtx_data,
                self.number_of_h_metrics,
                self.gvar_header.?,
                self.gvar_data,
                glyph_id,
                self.normalized,
            ) else try parsing.Table.glyf.outline(
                scratch_allocator,
                glyf_table,
                loca_table,
                self.head.index_to_loc_format,
                glyph_id,
            );
            defer scratch_allocator.free(outline.points);
            defer scratch_allocator.free(outline.end_points_of_contours);
            const mask = try rasterization.rasterizeTrueTypeGlyfOutline(scratch_allocator, outline, units_per_em, self.ppem, phase, want_pixels);
            defer mask.deinit(scratch_allocator);
            return self.finishOutlineMask(mask, output_allocator, want_pixels);
        } else if (self.cff_context) |ctx| {
            if (self.ppem < cff_hinting_ppem_threshold) {
                const mask = try rasterization.rasterizeCffOutlineHintedWithContext(scratch_allocator, ctx, glyph_id, units_per_em, self.ppem, phase, true, want_pixels);
                defer mask.deinit(scratch_allocator);
                return self.finishOutlineMask(mask, output_allocator, want_pixels);
            }
            const outline = try ctx.outline(scratch_allocator, glyph_id);
            defer scratch_allocator.free(outline.segments);
            const mask = try rasterization.rasterizeCffOutline(scratch_allocator, outline, units_per_em, self.ppem, phase, want_pixels);
            defer mask.deinit(scratch_allocator);
            return self.finishOutlineMask(mask, output_allocator, want_pixels);
        } else if (self.cff2_data) |cff2_table| {
            const outline = try parsing.Table.cff2.outline(scratch_allocator, cff2_table, glyph_id);
            defer scratch_allocator.free(outline.segments);
            const mask = try rasterization.rasterizeCffOutline(scratch_allocator, outline, units_per_em, self.ppem, phase, want_pixels);
            defer mask.deinit(scratch_allocator);
            return self.finishOutlineMask(mask, output_allocator, want_pixels);
        } else {
            return error.InvalidTableFormat;
        }
    }

    /// Rasterizes one glyph, dispatching across color-table sources (COLR,
    /// sbix, CBDT) before falling back to the outline rasterizer
    /// (glyf/CFF/CFF2, with the CFF-hinted-below-28ppem switch).
    /// `scratch_allocator` backs temp buffers freed before this returns;
    /// `output_allocator` backs the returned bitmap's pixels, which the
    /// caller owns and must free with the same allocator (`RenderedGlyph.deinit`).
    /// Pixel layout follows `is_color`: `false` is exactly `width * rows`
    /// coverage bytes, `true` is exactly `width * rows * 4` straight RGBA
    /// bytes, so callers may keep the slice as-is.
    pub fn renderGlyph(
        self: *Renderer,
        glyph_id: u16,
        phase: rasterization.SubpixelOffset,
        scratch_allocator: std.mem.Allocator,
        output_allocator: std.mem.Allocator,
    ) RenderError!RenderedGlyph {
        // A glyph id past this font's own glyph count can't belong to it --
        // treat the same as .notdef rather than let it read garbage out of
        // `loca`/a charstring offset array. Callers can end up here handing
        // over a glyph id shaped against a *different* font (fallback/cache
        // mismatch upstream); the graceful fallback matches FreeType's own
        // out-of-range handling instead of surfacing a parse error for what
        // is really a caller bug elsewhere.
        if (glyph_id >= self.num_glyphs) return .{ .bitmap = .empty, .is_color = false };

        const ppem_u16: u16 = @intFromFloat(@round(self.ppem));

        if (self.colr_data) |colr_table| {
            if (self.cpal_data) |cpal_table| {
                if (self.colrOutlineSource()) |source| {
                    if (try rasterization.rasterizeColr(
                        scratch_allocator,
                        output_allocator,
                        colr_table,
                        cpal_table,
                        source,
                        self.head.units_per_em,
                        self.ppem,
                        glyph_id,
                        .{},
                    )) |bitmap| return .{ .bitmap = bitmap, .is_color = true };
                }
            }
        }

        if (self.sbix_data) |sbix_table| {
            var fallback: ?rasterization.SbixFallbackOutline = null;
            if (self.glyf_data) |glyf_table| {
                if (self.loca_data) |loca_table| {
                    fallback = .{
                        .glyf_data = glyf_table,
                        .loca_data = loca_table,
                        .index_to_loc_format = self.head.index_to_loc_format,
                        .hmtx_data = self.hmtx_data,
                        .number_of_h_metrics = self.number_of_h_metrics,
                        .units_per_em = self.head.units_per_em,
                    };
                }
            }
            if (try rasterization.rasterizeSbix(scratch_allocator, output_allocator, sbix_table, ppem_u16, glyph_id, fallback)) |bitmap| {
                return .{ .bitmap = bitmap, .is_color = true };
            }
        }

        if (self.cblc_data) |cblc_table| {
            if (self.cbdt_data) |cbdt_table| {
                if (try rasterization.rasterizeCbdt(scratch_allocator, output_allocator, cblc_table, cbdt_table, ppem_u16, glyph_id)) |bitmap| {
                    return .{ .bitmap = bitmap, .is_color = true };
                }
            }
        }

        const bitmap = try self.renderOutline(glyph_id, phase, scratch_allocator, output_allocator, true);
        return .{ .bitmap = bitmap, .is_color = false };
    }

    /// Just the box `renderGlyph` would produce, without scan-converting the
    /// glyph or allocating its pixels -- for callers that lay out text (or
    /// pack an atlas) before deciding which glyphs actually get drawn. The
    /// box is computed by the same grid fit the rasterizer uses, so it is
    /// identical to the one `renderGlyph` reports.
    /// Color glyphs (COLR/sbix/CBDT) have no outline to measure, so they are
    /// rasterized into `scratch_allocator` and thrown away; only outline
    /// fonts actually skip the work.
    pub fn glyphBounds(
        self: *Renderer,
        glyph_id: u16,
        phase: rasterization.SubpixelOffset,
        scratch_allocator: std.mem.Allocator,
    ) RenderError!GlyphBounds {
        if (glyph_id >= self.num_glyphs) return .{ .width = 0, .rows = 0, .left = 0, .top = 0, .is_color = false };

        if (self.colr_data != null or self.sbix_data != null or self.cbdt_data != null) {
            const rendered = try self.renderGlyph(glyph_id, phase, scratch_allocator, scratch_allocator);
            defer rendered.deinit(scratch_allocator);
            return .{
                .width = rendered.bitmap.width,
                .rows = rendered.bitmap.rows,
                .left = rendered.bitmap.left,
                .top = rendered.bitmap.top,
                .is_color = rendered.is_color,
            };
        }

        const mask = try self.renderOutline(glyph_id, phase, scratch_allocator, scratch_allocator, false);
        return .{ .width = mask.width, .rows = mask.rows, .left = mask.left, .top = mask.top, .is_color = false };
    }

    /// Rasterizes and positions every glyph in a shaped `buffer`, walking
    /// the pen the same way FreeType/HarfBuzz consumers do: F26Dot6 fixed-
    /// point advances, with the fractional pen remainder baked into each
    /// glyph's outline (`SubpixelPhase`) rather than snapped to the pixel
    /// grid. Caller owns the returned `Run` and must free it with
    /// `output_allocator` (`Run.deinit`).
    pub fn renderBuffer(
        self: *Renderer,
        buffer: shaping.Buffer,
        scratch_allocator: std.mem.Allocator,
        output_allocator: std.mem.Allocator,
    ) RenderError!Run {
        const glyphs = try output_allocator.alloc(PositionedGlyph, buffer.len());
        errdefer output_allocator.free(glyphs);
        var built: usize = 0;
        errdefer for (glyphs[0..built]) |g| g.deinit(output_allocator);

        const scale = rasterization.ftDivFix(@as(i32, @intFromFloat(@round(self.ppem))) * 64, self.head.units_per_em);
        var pen_x: i32 = 0;
        var pen_y: i32 = 0;

        for (0..buffer.len()) |i| {
            const glyph_id: u16 = @intCast(buffer.info.items[i].codepoint);
            const pos = buffer.pos.items[i];
            const offset_x = rasterization.ftMulFix(pos.x_offset, scale);
            const offset_y = rasterization.ftMulFix(pos.y_offset, scale);
            const total_x = pen_x + offset_x;
            const total_y = pen_y + offset_y;
            const origin_x_px = total_x >> 6;
            const origin_y_px = total_y >> 6;
            const phase: rasterization.SubpixelOffset = .{ .x = total_x & 63, .y = total_y & 63 };

            pen_x += rasterization.ftMulFix(pos.x_advance, scale);
            pen_y += rasterization.ftMulFix(pos.y_advance, scale);

            const rendered = try self.renderGlyph(glyph_id, phase, scratch_allocator, output_allocator);
            glyphs[i] = .{ .bitmap = rendered.bitmap, .origin_x = origin_x_px, .origin_y = origin_y_px, .is_color = rendered.is_color };
            built += 1;
        }

        return .{ .glyphs = glyphs };
    }
};

fn userValueForAxis(axis: parsing.Table.fvar.Axis, user_coords: []const UserCoord, ppem: f32) f32 {
    for (user_coords) |c| {
        if (std.mem.eql(u8, &c.tag, &axis.tag)) return c.value;
    }
    // Auto opsz: browsers instance the optical-size axis from the rendered
    // size rather than leaving it at its default, so small text gets the
    // sturdier low-opsz outlines and large text the finer high-opsz ones.
    // Only kicks in when the caller didn't pin opsz explicitly.
    if (std.mem.eql(u8, &axis.tag, "opsz")) return std.math.clamp(ppem, axis.min_value, axis.max_value);
    return axis.default_value;
}

/// Computes per-axis normalized coordinates ([-1, 1], `fvar` axis order,
/// through `avar` remapping and auto-opsz instancing) for `font` at
/// `user_coords`/`ppem`. Shared by `Renderer.init` and by callers that need
/// the same coords for shaping (HVAR advance-width variation via
/// `shaping.shapeVaried`/`shapeBidiParagraphVaried`) independent of
/// constructing a `Renderer` - shaping and rendering are separate stages
/// (a buffer can be shaped once and rendered at several sizes), so this is
/// exposed standalone rather than only reachable through `Renderer.normalized`.
/// Returns an empty slice (no allocation to free) for non-variable fonts.
/// `output_allocator` backs the returned slice (long-lived — e.g. stored in
/// `Renderer.normalized` and freed via `Renderer.deinit`'s `state_allocator`,
/// or freed directly by a caller using this standalone); `scratch_allocator`
/// backs the axis/segment-map buffers used only inside this call.
pub fn normalizedCoords(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    font: parsing.Font,
    user_coords: []const UserCoord,
    ppem: f32,
) InitError![]const f32 {
    const fvar_table = font.tableData(.{ 'f', 'v', 'a', 'r' }) orelse return &.{};
    const axes = try parsing.Table.fvar.axes(scratch_allocator, fvar_table);
    defer scratch_allocator.free(axes);

    const coords = try output_allocator.alloc(f32, axes.len);
    errdefer output_allocator.free(coords);

    var segments: []const []const parsing.Table.avar.AxisValueMap = &.{};
    if (font.tableData(.{ 'a', 'v', 'a', 'r' })) |avar_table| {
        segments = parsing.Table.avar.segmentMaps(scratch_allocator, avar_table) catch &.{};
    }
    defer if (segments.len != 0) {
        for (segments) |s| scratch_allocator.free(s);
        scratch_allocator.free(segments);
    };

    for (axes, 0..) |axis, i| {
        var n = parsing.Table.fvar.normalizeAxisValue(axis, userValueForAxis(axis, user_coords, ppem));
        if (i < segments.len) n = parsing.Table.avar.mapValue(segments[i], n);
        coords[i] = n;
    }
    return coords;
}
