// Derived from FreeType (FTL); see THIRD_PARTY_LICENSES.
const std = @import("std");
const common = @import("common.zig");
const IPoint = common.IPoint;
const trunc = common.trunc;
const fract = common.fract;
const upscale = common.upscale;
const one_pixel = common.one_pixel;
const ScaledPoint = common.ScaledPoint;
const fillRuleNonZero = common.fillRuleNonZero;

/// `TCell`: 24 bytes, same as FreeType's, so the pool holds as many cells.
const Cell = struct { x: i32, cover: i32, area: i64, next: *Cell };

/// `FT_RENDER_POOL_SIZE / sizeof(TCell)`.
const max_stack_cells = 16384 / @sizeOf(Cell);

pub const Rasterizer = struct {
    pub const OverflowError = error{RasterOverflow};

    min_ey: i32,
    max_ex: i32,
    max_ey: i32,
    pixel_rows: i32,

    ycells: [*]*Cell,
    cell: *Cell,
    cell_free: [*]Cell,
    cell_null: *Cell,
    overflow: bool = false,

    x: i32 = 0,
    y: i32 = 0,

    /// `gray_raster_render` + `gray_convert_glyph`: sweeps `outline` into
    /// `pixels` (`width * height`, zeroed by the caller). `outline` provides
    /// `decompose(*Rasterizer) OverflowError!void`, replayed once per band.
    pub fn render(scratch_allocator: std.mem.Allocator, pixels: []u8, width: i32, height: i32, outline: anytype) std.mem.Allocator.Error!void {
        const estimate = (@as(usize, @intCast(width)) + @as(usize, @intCast(height))) * 10;
        var stack_cells: [max_stack_cells]Cell = undefined;
        const heap_cells: ?[]Cell = if (estimate > max_stack_cells) try scratch_allocator.alloc(Cell, estimate) else null;
        defer if (heap_cells) |cells| scratch_allocator.free(cells);
        const pool: []Cell = heap_cells orelse &stack_cells;

        const cell_null = &pool[pool.len - 1];
        cell_null.* = .{ .x = std.math.maxInt(i32), .cover = 0, .area = 0, .next = cell_null };
        var raster: Rasterizer = .{
            .min_ey = 0,
            .max_ex = width,
            .max_ey = height,
            .pixel_rows = height,
            .ycells = @ptrCast(pool.ptr),
            .cell = cell_null,
            .cell_free = pool.ptr,
            .cell_null = cell_null,
        };

        var bands: [32]i32 = undefined;
        var band_count: usize = 0;
        while (true) {
            const count: usize = @intCast(raster.max_ey - raster.min_ey);
            @memset(raster.ycells[0..count], cell_null);
            raster.cell_free = pool.ptr + (count * @sizeOf(*Cell) + @sizeOf(Cell) - 1) / @sizeOf(Cell);
            raster.cell = cell_null;
            raster.overflow = false;

            if (outline.decompose(&raster)) {
                raster.sweep(pixels, width);
                if (band_count == 0) return;
                raster.max_ey = raster.min_ey;
                band_count -= 1;
                raster.min_ey = bands[band_count];
                continue;
            } else |_| {}

            const half = count >> 1;
            // Unreachable: one row holds at most `width + 1` cells and the
            // pool is at least `10 * (width + height)`.
            if (half == 0) return error.OutOfMemory;
            bands[band_count] = raster.min_ey;
            band_count += 1;
            raster.min_ey += @intCast(half);
        }
    }

    /// `gray_set_cell`: moves to (or inserts) the cell at `(ex, ey)` in the
    /// row's x-sorted list. Cells left of the bitmap clamp to `x = -1`;
    /// anything outside the band, or at/right of `max_ex`, goes to the
    /// `cell_null` dumpster, as does a new cell once the pool is full.
    fn setCell(self: *Rasterizer, ex_in: i32, ey: i32) void {
        if (ey < self.min_ey or ey >= self.max_ey or ex_in >= self.max_ex) {
            self.cell = self.cell_null;
            return;
        }
        const ex = @max(ex_in, -1);
        var link: **Cell = &self.ycells[@intCast(ey - self.min_ey)];
        while (true) {
            const cell = link.*;
            if (cell.x > ex) break;
            if (cell.x == ex) {
                self.cell = cell;
                return;
            }
            link = &cell.next;
        }

        if (&self.cell_free[0] == self.cell_null) {
            self.overflow = true;
            self.cell = self.cell_null;
            return;
        }
        const cell = &self.cell_free[0];
        self.cell_free += 1;
        cell.* = .{ .x = ex, .cover = 0, .area = 0, .next = link.* };
        link.* = cell;
        self.cell = cell;
    }

    /// `FT_INTEGRATE`.
    fn integrate(self: *Rasterizer, a: i32, b: i32) void {
        self.cell.cover += a;
        self.cell.area += @as(i64, a) * @as(i64, b);
    }

    /// `FT_UDIV`: reciprocal-multiply division used by `renderLine`'s
    /// general-line branch, deliberately approximate (not exact division)
    /// — this is FreeType's own optimization, and matching it (not plain
    /// division) is required to bit-match FreeType's coverage output.
    /// `b_r` is the reciprocal from `udivPrep`, already sign-adjusted by
    /// the caller to match the divisor implied at each call site.
    fn udiv(a: i64, b_r: i64) i32 {
        const ua: u64 = @bitCast(a);
        const ub: u64 = @bitCast(b_r);
        const shifted: u64 = (ua *% ub) >> 32;
        return @bitCast(@as(u32, @truncate(shifted)));
    }

    fn udivPrep(active: bool, b: i64) i64 {
        return if (active) @divTrunc(0xFFFFFFFF, b) else 0;
    }

    /// `gray_render_line` (`FT_INT64` variant — the one real FreeType
    /// builds use, since 64-bit integers are available on essentially
    /// every target today): walks cell-by-cell along the line using a
    /// side-tracking `prod` value instead of scanline decomposition.
    fn renderLine(self: *Rasterizer, to_x: i32, to_y: i32) void {
        var ey1 = trunc(self.y);
        const ey2 = trunc(to_y);

        if ((ey1 >= self.max_ey and ey2 >= self.max_ey) or (ey1 < self.min_ey and ey2 < self.min_ey)) {
            self.x = to_x;
            self.y = to_y;
            return;
        }

        var ex1 = trunc(self.x);
        const ex2 = trunc(to_x);

        var fx1 = fract(self.x);
        var fy1 = fract(self.y);

        const dx: i64 = @as(i64, to_x) - @as(i64, self.x);
        const dy: i64 = @as(i64, to_y) - @as(i64, self.y);

        if (ex1 == ex2 and ey1 == ey2) {
            // inside one cell: nothing to do before the tail integrate.
        } else if (dy == 0) {
            self.setCell(ex2, ey2);
            self.x = to_x;
            self.y = to_y;
            return;
        } else if (dx == 0) {
            var fy2: i32 = undefined;
            if (dy > 0) {
                while (true) {
                    fy2 = one_pixel;
                    self.integrate(fy2 - fy1, fx1 * 2);
                    fy1 = 0;
                    ey1 += 1;
                    self.setCell(ex1, ey1);
                    if (ey1 == ey2) break;
                }
            } else {
                while (true) {
                    fy2 = 0;
                    self.integrate(fy2 - fy1, fx1 * 2);
                    fy1 = one_pixel;
                    ey1 -= 1;
                    self.setCell(ex1, ey1);
                    if (ey1 == ey2) break;
                }
            }
        } else {
            var prod: i64 = dx * @as(i64, fy1) - dy * @as(i64, fx1);
            const dx_r = udivPrep(ex1 != ex2, dx);
            const dy_r = udivPrep(ey1 != ey2, dy);

            var fx2: i32 = undefined;
            var fy2: i32 = undefined;
            while (true) {
                const dx_op = dx * one_pixel;
                const dy_op = dy * one_pixel;

                if (prod - dx_op > 0 and prod <= 0) { // left
                    fx2 = 0;
                    fy2 = udiv(-prod, -dx_r);
                    prod -= dy_op;
                    self.integrate(fy2 - fy1, fx1 + fx2);
                    fx1 = one_pixel;
                    fy1 = fy2;
                    ex1 -= 1;
                } else if (prod - dx_op + dy_op > 0 and prod - dx_op <= 0) { // up
                    prod -= dx_op;
                    fx2 = udiv(-prod, dy_r);
                    fy2 = one_pixel;
                    self.integrate(fy2 - fy1, fx1 + fx2);
                    fx1 = fx2;
                    fy1 = 0;
                    ey1 += 1;
                } else if (prod + dy_op >= 0 and prod - dx_op + dy_op <= 0) { // right
                    prod += dy_op;
                    fx2 = one_pixel;
                    fy2 = udiv(prod, dx_r);
                    self.integrate(fy2 - fy1, fx1 + fx2);
                    fx1 = 0;
                    fy1 = fy2;
                    ex1 += 1;
                } else { // down
                    fx2 = udiv(prod, -dy_r);
                    fy2 = 0;
                    prod += dx_op;
                    self.integrate(fy2 - fy1, fx1 + fx2);
                    fx1 = fx2;
                    fy1 = one_pixel;
                    ey1 -= 1;
                }

                self.setCell(ex1, ey1);
                if (ex1 == ex2 and ey1 == ey2) break;
            }
        }

        const fx2 = fract(to_x);
        const fy2 = fract(to_y);
        self.integrate(fy2 - fy1, fx1 + fx2);

        self.x = to_x;
        self.y = to_y;
    }

    /// `gray_render_conic` (`FT_INT64` variant): flattens the quadratic
    /// arc by fixed-step DDA (the arc's second difference is constant,
    /// so each step is `P += Q; Q += R`) rather than recursive bisection.
    /// `control`/`to` are 26.6 (matching `self.x`/`self.y`, already 24.8).
    fn renderConic(self: *Rasterizer, control: IPoint, to: IPoint) void {
        const p0 = IPoint{ .x = self.x, .y = self.y };
        const p1 = IPoint{ .x = upscale(control.x), .y = upscale(control.y) };
        const p2 = IPoint{ .x = upscale(to.x), .y = upscale(to.y) };

        const above = self.max_ey;
        if ((trunc(p0.y) >= above and trunc(p1.y) >= above and trunc(p2.y) >= above) or
            (trunc(p0.y) < self.min_ey and trunc(p1.y) < self.min_ey and trunc(p2.y) < self.min_ey))
        {
            self.x = p2.x;
            self.y = p2.y;
            return;
        }

        const bx = p1.x - p0.x;
        const by = p1.y - p0.y;
        const ax = p2.x - p1.x - bx;
        const ay = p2.y - p1.y - by;

        var dx: i32 = @intCast(@abs(ax));
        const dy: i32 = @intCast(@abs(ay));
        if (dx < dy) dx = dy;

        if (dx <= one_pixel / 4) {
            self.renderLine(p2.x, p2.y);
            return;
        }

        var shift: i32 = 16;
        while (true) {
            dx >>= 2;
            shift -= 1;
            if (!(dx > one_pixel / 4)) break;
        }
        var count: u32 = @as(u32, 0x10000) >> @intCast(shift);
        const sh: u6 = @intCast(shift);

        var rx: i64 = @as(i64, ax) << @intCast(sh + sh);
        var ry: i64 = @as(i64, ay) << @intCast(sh + sh);

        var qx: i64 = (@as(i64, bx) << @intCast(sh + 17)) + rx;
        var qy: i64 = (@as(i64, by) << @intCast(sh + 17)) + ry;

        rx *= 2;
        ry *= 2;

        var px: i64 = @as(i64, p0.x) << 32;
        var py: i64 = @as(i64, p0.y) << 32;

        while (true) {
            px += qx;
            py += qy;
            qx += rx;
            qy += ry;
            self.renderLine(@intCast(px >> 32), @intCast(py >> 32));
            count -= 1;
            if (count == 0) break;
        }
    }

    /// `gray_split_cubic`: de Casteljau bisection at t=1/2, in place over a
    /// 7-point window `base[0..6]` ordered `[to, c2, c1, from]` at entry —
    /// `base[3]` (the split point) becomes the new shared endpoint between
    /// the two resulting 4-point sub-arcs `base[0..3]` and `base[3..6]`.
    fn splitCubic(base: []IPoint) void {
        base[6].x = base[3].x;
        var a: i32 = base[0].x + base[1].x;
        var b: i32 = base[1].x + base[2].x;
        var c: i32 = base[2].x + base[3].x;
        base[5].x = c >> 1;
        c += b;
        base[4].x = c >> 2;
        base[1].x = a >> 1;
        a += b;
        base[2].x = a >> 2;
        base[3].x = (a + c) >> 3;

        base[6].y = base[3].y;
        a = base[0].y + base[1].y;
        b = base[1].y + base[2].y;
        c = base[2].y + base[3].y;
        base[5].y = c >> 1;
        c += b;
        base[4].y = c >> 2;
        base[1].y = a >> 1;
        a += b;
        base[2].y = a >> 2;
        base[3].y = (a + c) >> 3;
    }

    /// `gray_render_cubic`: adaptive binary splitting until each sub-arc's
    /// deviation from its chord trisection points is within half a pixel
    /// (the `FT_INT64` conic DDA trick doesn't extend to cubics — FreeType
    /// itself falls back to bisection here). `control1`/`control2`/`to` are
    /// 26.6 (matching `self.x`/`self.y`, already 24.8 after `upscale`).
    fn renderCubic(self: *Rasterizer, control1: IPoint, control2: IPoint, to: IPoint) void {
        var bez_stack: [16 * 3 + 1]IPoint = undefined;
        var arc: usize = 0;

        bez_stack[0] = .{ .x = upscale(to.x), .y = upscale(to.y) };
        bez_stack[1] = .{ .x = upscale(control2.x), .y = upscale(control2.y) };
        bez_stack[2] = .{ .x = upscale(control1.x), .y = upscale(control1.y) };
        bez_stack[3] = .{ .x = self.x, .y = self.y };

        const above = self.max_ey;
        if ((trunc(bez_stack[0].y) >= above and trunc(bez_stack[1].y) >= above and
            trunc(bez_stack[2].y) >= above and trunc(bez_stack[3].y) >= above) or
            (trunc(bez_stack[0].y) < self.min_ey and trunc(bez_stack[1].y) < self.min_ey and
                trunc(bez_stack[2].y) < self.min_ey and trunc(bez_stack[3].y) < self.min_ey))
        {
            self.x = bez_stack[0].x;
            self.y = bez_stack[0].y;
            return;
        }

        while (true) {
            const a0 = bez_stack[arc];
            const a1 = bez_stack[arc + 1];
            const a2 = bez_stack[arc + 2];
            const a3 = bez_stack[arc + 3];

            if (@abs(2 * a0.x - 3 * a1.x + a3.x) > one_pixel / 2 or
                @abs(2 * a0.y - 3 * a1.y + a3.y) > one_pixel / 2 or
                @abs(a0.x - 3 * a2.x + 2 * a3.x) > one_pixel / 2 or
                @abs(a0.y - 3 * a2.y + 2 * a3.y) > one_pixel / 2)
            {
                splitCubic(bez_stack[arc..][0..7]);
                arc += 3;
                continue;
            }

            self.renderLine(a0.x, a0.y);
            if (arc == 0) return;
            arc -= 3;
        }
    }

    pub fn moveTo(self: *Rasterizer, to: IPoint) OverflowError!void {
        const x = upscale(to.x);
        const y = upscale(to.y);
        self.setCell(trunc(x), trunc(y));
        self.x = x;
        self.y = y;
        if (self.overflow) return error.RasterOverflow;
    }

    pub fn lineTo(self: *Rasterizer, to: IPoint) OverflowError!void {
        self.renderLine(upscale(to.x), upscale(to.y));
        if (self.overflow) return error.RasterOverflow;
    }

    pub fn conicTo(self: *Rasterizer, control: IPoint, to: IPoint) OverflowError!void {
        self.renderConic(control, to);
        if (self.overflow) return error.RasterOverflow;
    }

    fn cubicTo(self: *Rasterizer, control1: IPoint, control2: IPoint, to: IPoint) OverflowError!void {
        self.renderCubic(control1, control2, to);
        if (self.overflow) return error.RasterOverflow;
    }

    /// `gray_sweep` over the current band. Row 0 of `pixels` is the top of
    /// the glyph; cell-space `y` increases upward from the bottom row.
    fn sweep(self: *Rasterizer, pixels: []u8, width: i32) void {
        var y: i32 = self.min_ey;
        while (y < self.max_ey) : (y += 1) {
            const pixel_row: usize = @intCast(self.pixel_rows - 1 - y);
            const row = pixels[pixel_row * @as(usize, @intCast(width)) ..][0..@intCast(width)];

            var x: i32 = 0;
            var cover: i64 = 0;
            var cell = self.ycells[@intCast(y - self.min_ey)];
            while (cell != self.cell_null) : (cell = cell.next) {
                if (cover != 0 and cell.x > x) {
                    fillSpan(row, x, cell.x - x, fillRuleNonZero(cover));
                }

                cover += @as(i64, cell.cover) * (one_pixel * 2);
                const area = cover - cell.area;
                if (area != 0 and cell.x >= 0) {
                    row[@intCast(cell.x)] = fillRuleNonZero(area);
                }

                x = cell.x + 1;
            }

            if (cover != 0) {
                fillSpan(row, x, self.max_ex - x, fillRuleNonZero(cover));
            }
        }
    }

    fn fillSpan(row: []u8, x: i32, len: i32, value: u8) void {
        if (len <= 0) return;
        const start: usize = @intCast(x);
        const count: usize = @intCast(len);
        @memset(row[start..][0..count], value);
    }
    /// CFF Type2 charstrings never encode an explicit closing segment — a
    /// contour implicitly closes back to its `move_to` point, matching
    /// `psaux`'s `cff_builder_close_contour`.
    pub fn decomposeCffSegments(raster: *Rasterizer, segments: []const common.IScaledCffSegment) OverflowError!void {
        var contour_start: ?IPoint = null;
        for (segments) |segment| {
            switch (segment) {
                .move_to => |p| {
                    if (contour_start) |start| try raster.lineTo(start);
                    try raster.moveTo(p);
                    contour_start = p;
                },
                .line_to => |p| try raster.lineTo(p),
                .curve_to => |c| try raster.cubicTo(c.c1, c.c2, c.to),
            }
        }
        if (contour_start) |start| try raster.lineTo(start);
    }
};
