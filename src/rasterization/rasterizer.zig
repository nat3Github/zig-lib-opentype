const std = @import("std");
const common = @import("common.zig");
const IPoint = common.IPoint;
const trunc = common.trunc;
const fract = common.fract;
const upscale = common.upscale;
const one_pixel = common.one_pixel;
const ScaledPoint = common.ScaledPoint;
const fillRuleNonZero = common.fillRuleNonZero;

const RowCell = struct { x: i32, cover: i32 = 0, area: i64 = 0 };
const CellRef = struct { row: usize, index: usize };

pub const Rasterizer = struct {
    allocator: std.mem.Allocator,
    max_ex: i32,
    max_ey: i32,
    rows: []std.ArrayListUnmanaged(RowCell),

    x: i32 = 0,
    y: i32 = 0,
    current: ?CellRef = null,

    pub fn init(allocator: std.mem.Allocator, width: i32, height: i32) !Rasterizer {
        const rows = try allocator.alloc(std.ArrayListUnmanaged(RowCell), @intCast(height));
        for (rows) |*row| row.* = .empty;
        return .{ .allocator = allocator, .max_ex = width, .max_ey = height, .rows = rows };
    }

    pub fn deinit(self: *Rasterizer) void {
        for (self.rows) |*row| row.deinit(self.allocator);
        self.allocator.free(self.rows);
    }

    /// `gray_set_cell`: move to (or insert) the cell at `(ex, ey)`, keeping
    /// each row's cell list sorted by `x`. Cells left of the bitmap clamp
    /// to `x = -1` (still tracked, so their coverage contributes to the
    /// running sweep total); cells at/right of `max_ex`, or outside the
    /// vertical range, are dropped (`self.current = null`).
    fn setCell(self: *Rasterizer, ex_in: i32, ey: i32) !void {
        if (ey < 0 or ey >= self.max_ey or ex_in >= self.max_ex) {
            self.current = null;
            return;
        }
        const ex = @max(ex_in, -1);
        const row_index: usize = @intCast(ey);
        const row = &self.rows[row_index];

        // Consecutive calls almost always land on the same cell, or append to
        // the right end of the row; both skip the search entirely.
        if (self.current) |cur| {
            if (cur.row == row_index and row.items[cur.index].x == ex) return;
        }
        if (row.items.len > 0 and row.items[row.items.len - 1].x < ex) {
            try row.append(self.allocator, .{ .x = ex });
            self.current = .{ .row = row_index, .index = row.items.len - 1 };
            return;
        }

        var lo: usize = 0;
        var hi: usize = row.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (row.items[mid].x < ex) lo = mid + 1 else hi = mid;
        }
        const i = lo;

        if (i < row.items.len and row.items[i].x == ex) {
            self.current = .{ .row = row_index, .index = i };
            return;
        }

        try row.insert(self.allocator, i, .{ .x = ex });
        self.current = .{ .row = row_index, .index = i };
    }

    /// `FT_INTEGRATE`.
    fn integrate(self: *Rasterizer, a: i32, b: i32) void {
        const cur = self.current orelse return;
        const cell = &self.rows[cur.row].items[cur.index];
        cell.cover += a;
        cell.area += @as(i64, a) * @as(i64, b);
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
    fn renderLine(self: *Rasterizer, to_x: i32, to_y: i32) !void {
        var ey1 = trunc(self.y);
        const ey2 = trunc(to_y);

        if ((ey1 >= self.max_ey and ey2 >= self.max_ey) or (ey1 < 0 and ey2 < 0)) {
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
            try self.setCell(ex2, ey2);
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
                    try self.setCell(ex1, ey1);
                    if (ey1 == ey2) break;
                }
            } else {
                while (true) {
                    fy2 = 0;
                    self.integrate(fy2 - fy1, fx1 * 2);
                    fy1 = one_pixel;
                    ey1 -= 1;
                    try self.setCell(ex1, ey1);
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

                try self.setCell(ex1, ey1);
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
    fn renderConic(self: *Rasterizer, control: IPoint, to: IPoint) !void {
        const p0 = IPoint{ .x = self.x, .y = self.y };
        const p1 = IPoint{ .x = upscale(control.x), .y = upscale(control.y) };
        const p2 = IPoint{ .x = upscale(to.x), .y = upscale(to.y) };

        const above = self.max_ey;
        if ((trunc(p0.y) >= above and trunc(p1.y) >= above and trunc(p2.y) >= above) or
            (trunc(p0.y) < 0 and trunc(p1.y) < 0 and trunc(p2.y) < 0))
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
            try self.renderLine(p2.x, p2.y);
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
            try self.renderLine(@intCast(px >> 32), @intCast(py >> 32));
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
    fn renderCubic(self: *Rasterizer, control1: IPoint, control2: IPoint, to: IPoint) !void {
        var bez_stack: [16 * 3 + 1]IPoint = undefined;
        var arc: usize = 0;

        bez_stack[0] = .{ .x = upscale(to.x), .y = upscale(to.y) };
        bez_stack[1] = .{ .x = upscale(control2.x), .y = upscale(control2.y) };
        bez_stack[2] = .{ .x = upscale(control1.x), .y = upscale(control1.y) };
        bez_stack[3] = .{ .x = self.x, .y = self.y };

        const above = self.max_ey;
        if ((trunc(bez_stack[0].y) >= above and trunc(bez_stack[1].y) >= above and
            trunc(bez_stack[2].y) >= above and trunc(bez_stack[3].y) >= above) or
            (trunc(bez_stack[0].y) < 0 and trunc(bez_stack[1].y) < 0 and
                trunc(bez_stack[2].y) < 0 and trunc(bez_stack[3].y) < 0))
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

            try self.renderLine(a0.x, a0.y);
            if (arc == 0) return;
            arc -= 3;
        }
    }

    pub fn moveTo(self: *Rasterizer, to: IPoint) !void {
        const x = upscale(to.x);
        const y = upscale(to.y);
        try self.setCell(trunc(x), trunc(y));
        self.x = x;
        self.y = y;
    }

    pub fn lineTo(self: *Rasterizer, to: IPoint) !void {
        try self.renderLine(upscale(to.x), upscale(to.y));
    }

    pub fn conicTo(self: *Rasterizer, control: IPoint, to: IPoint) !void {
        try self.renderConic(control, to);
    }

    fn cubicTo(self: *Rasterizer, control1: IPoint, control2: IPoint, to: IPoint) !void {
        try self.renderCubic(control1, control2, to);
    }

    /// `gray_sweep`: turn accumulated per-cell area into gray spans.
    /// Row 0 of `pixels` is the top of the glyph (`max_ey - 1`); cell-space
    /// `y` increases upward from the bitmap's bottom row.
    pub fn sweep(self: *Rasterizer, pixels: []u8, width: i32) void {
        var y: i32 = 0;
        while (y < self.max_ey) : (y += 1) {
            const cells = self.rows[@as(usize, @intCast(y))].items;
            const pixel_row: usize = @intCast(self.max_ey - 1 - y);
            const row = pixels[pixel_row * @as(usize, @intCast(width)) ..][0..@intCast(width)];

            var x: i32 = 0;
            var cover: i64 = 0;
            for (cells) |cell| {
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
    pub fn decomposeCffSegments(raster: *Rasterizer, segments: []const common.IScaledCffSegment) !void {
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
