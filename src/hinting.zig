// Derived from FreeType (FTL); see THIRD_PARTY_LICENSES.
//! TrueType bytecode interpreter, ported from FreeType's `ttinterp.c`
//! (v35/base interpreter; no ClearType/subpixel-hinting-minimal hacks).
//!
//! Security note: this executes attacker-controlled bytecode embedded in
//! the font (`fpgm`/`prep`/glyph instructions). All resource limits below
//! are hard caps applied regardless of what the font's `maxp` table claims
//! — a malicious `maxp` cannot request an unbounded stack/storage/call
//! depth. `Interpreter.step` also enforces a total-instruction budget and
//! separate LOOPCALL/negative-jump counters (mirroring FreeType) to bound
//! runtime against crafted infinite loops.

const std = @import("std");
// Flip to true locally to trace the interpreter; comptime-const so it costs
// nothing (the whole std.debug.print call folds away) when left off.
const debug_trace = false;

pub const Point = struct { x: i32 = 0, y: i32 = 0 };
pub const UnitVector = struct { x: i16 = 0x4000, y: i16 = 0 };

pub const touch_x: u8 = 0x08;
pub const touch_y: u8 = 0x10;
pub const touch_both: u8 = touch_x | touch_y;
pub const on_curve: u8 = 0x01;

pub const Zone = struct {
    n_points: u16 = 0,
    n_contours: u16 = 0,
    cur: []Point = &.{},
    org: []Point = &.{},
    orus: []Point = &.{},
    tags: []u8 = &.{},
    /// End-point index per contour (inclusive), zone-local.
    contours: []const u16 = &.{},
};

pub const RoundState = enum(u8) {
    to_half_grid = 0,
    to_grid = 1,
    to_double_grid = 2,
    down_to_grid = 3,
    up_to_grid = 4,
    off = 5,
    super = 6,
    super_45 = 7,
};

pub const GraphicsState = struct {
    rp0: u16 = 0,
    rp1: u16 = 0,
    rp2: u16 = 0,
    gep0: u1 = 1,
    gep1: u1 = 1,
    gep2: u1 = 1,
    dual_vector: UnitVector = .{ .x = 0x4000, .y = 0 },
    proj_vector: UnitVector = .{ .x = 0x4000, .y = 0 },
    free_vector: UnitVector = .{ .x = 0x4000, .y = 0 },
    loop: i32 = 1,
    round_state: RoundState = .to_grid,
    /// Engine compensation; always zero (matches FreeType's default driver
    /// — no device-specific compensation table).
    compensation: [4]i32 = .{ 0, 0, 0, 0 },
    minimum_distance: i32 = 64,
    control_value_cutin: i32 = 68,
    single_width_cutin: i32 = 0,
    single_width_value: i32 = 0,
    delta_base: u16 = 9,
    delta_shift: u16 = 3,
    auto_flip: bool = true,
    instruct_control: u8 = 0,
    scan_control: bool = false,
    scan_type: i32 = 0,
};

pub const CodeRange = enum(u2) { font = 0, cvt = 1, glyph = 2 };

const DefRecord = struct {
    range: CodeRange,
    start: u32,
    end: u32 = 0,
    opc: u16,
    active: bool = false,
};

const DefKind = enum { fdef, idef };

/// What `fpgm` leaves behind in a fresh interpreter (`TT_Save_Context`
/// after `tt_size_run_fpgm`), so a re-target can restore it instead of
/// replaying `fpgm` against state left over from the previous size.
pub const FontProgramSnapshot = struct {
    storage: []i32,
    fdefs: []DefRecord,
    idefs: []DefRecord,
    max_func: i32,
    max_ins: i32,
    gs: GraphicsState,
    twilight: Zone,

    pub fn deinit(self: FontProgramSnapshot, state_allocator: std.mem.Allocator) void {
        state_allocator.free(self.storage);
        state_allocator.free(self.fdefs);
        state_allocator.free(self.idefs);
    }
};

const CallRecord = struct {
    caller_range: CodeRange,
    caller_ip: u32,
    cur_count: u32,
    kind: DefKind,
    index: u32,
};

pub const Limits = struct {
    max_stack: u32 = 0xFFFF,
    max_storage: u32 = 1024,
    max_function_defs: u32 = 1024,
    max_instruction_defs: u32 = 256,
    max_call_depth: u32 = 64,
    max_twilight_points: u32 = 4096,
    max_instructions: u32 = 1_000_000,

    /// FreeType's `tt_size_init_bytecode` sizing: arrays as declared in
    /// `maxp`, the stack with 50% (at least 128) slack for fonts whose
    /// bytecode overshoots `maxStackElements`. `caps` still bounds every
    /// field, since `maxp` is attacker-controlled.
    pub fn fromMaxp(
        caps: Limits,
        max_stack_elements: u16,
        max_storage: u16,
        max_function_defs: u16,
        max_instruction_defs: u16,
    ) Limits {
        var limits = caps;
        const stack_size = @as(u32, max_stack_elements) + @max(max_stack_elements / 2, 128);
        limits.max_stack = @min(stack_size, caps.max_stack);
        limits.max_storage = @min(max_storage, caps.max_storage);
        limits.max_function_defs = @min(max_function_defs, caps.max_function_defs);
        limits.max_instruction_defs = @min(max_instruction_defs, caps.max_instruction_defs);
        return limits;
    }
};

pub const Error = error{
    OutOfMemory,
    StackOverflow,
    StackUnderflow,
    CodeOverflow,
    NestedDefs,
    TooManyFunctionDefs,
    TooManyInstructionDefs,
    DefInGlyphBytecode,
    EndfInExecStream,
    InvalidCodeRange,
    BadArgument,
    ExecutionTooLong,
    CallStackOverflow,
    DivideByZero,
};

fn pixRound(x: i32) i32 {
    return (x +% 32) & ~@as(i32, 63);
}
fn pixFloor(x: i32) i32 {
    return x & ~@as(i32, 63);
}
fn pixCeil(x: i32) i32 {
    return (x +% 63) & ~@as(i32, 63);
}
fn padRound(x: i32, n: i32) i32 {
    return @divTrunc(x +% @divTrunc(n, 2), n) *% n;
}

fn mulFix(a: i32, b: i32) i32 {
    const prod: i64 = @as(i64, a) * @as(i64, b);
    const rounded = if (prod >= 0) prod + 0x8000 else prod - 0x8000;
    return @intCast(std.math.clamp(@divTrunc(rounded, 0x10000), std.math.minInt(i32), std.math.maxInt(i32)));
}

fn mulDiv(a: i32, b: i32, c: i32) i32 {
    if (c == 0) return std.math.maxInt(i32);
    var sign: i64 = 1;
    var ua: i64 = a;
    var ub: i64 = b;
    var uc: i64 = c;
    if (ua < 0) {
        ua = -ua;
        sign = -sign;
    }
    if (ub < 0) {
        ub = -ub;
        sign = -sign;
    }
    if (uc < 0) {
        uc = -uc;
        sign = -sign;
    }
    const result = @divTrunc(ua * ub + @divTrunc(uc, 2), uc);
    return @intCast(std.math.clamp(sign * result, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn mulDivNoRound(a: i32, b: i32, c: i32) i32 {
    if (c == 0) return std.math.maxInt(i32);
    var sign: i64 = 1;
    var ua: i64 = a;
    var ub: i64 = b;
    var uc: i64 = c;
    if (ua < 0) {
        ua = -ua;
        sign = -sign;
    }
    if (ub < 0) {
        ub = -ub;
        sign = -sign;
    }
    if (uc < 0) {
        uc = -uc;
        sign = -sign;
    }
    const result = @divTrunc(ua * ub, uc);
    return @intCast(std.math.clamp(sign * result, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// F26Dot6 x F2Dot14 -> F26Dot6, rounded.
fn mulFix14(a: i32, b: i16) i32 {
    const prod: i64 = @as(i64, a) * @as(i64, b);
    const rounded = prod + 0x2000 + (if (prod < 0) @as(i64, -1) else 0);
    return @intCast(@divFloor(rounded, 0x4000));
}

/// Dot product of (ax,ay) with 2.14 unit vector (bx,by) -> F26Dot6.
fn dotFix14(ax: i32, ay: i32, bx: i16, by: i16) i32 {
    const c: i64 = @as(i64, ax) * @as(i64, bx) + @as(i64, ay) * @as(i64, by);
    const rounded = c + 0x2000 + (if (c < 0) @as(i64, -1) else 0);
    return @intCast(@divFloor(rounded, 0x4000));
}

fn normalize(vx: i32, vy: i32) UnitVector {
    if (vx == 0 and vy == 0) return .{ .x = 0x4000, .y = 0 };
    const fx: f64 = @floatFromInt(vx);
    const fy: f64 = @floatFromInt(vy);
    const len = @sqrt(fx * fx + fy * fy);
    const nx = fx / len * 65536.0;
    const ny = fy / len * 65536.0;
    return .{
        .x = @intFromFloat(std.math.clamp(@round(nx / 4.0), -16384.0, 16384.0)),
        .y = @intFromFloat(std.math.clamp(@round(ny / 4.0), -16384.0, 16384.0)),
    };
}

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    limits: Limits,

    stack: []i32,
    top: u32 = 0,

    storage: []i32,

    /// Scaled (F26Dot6, ppem-relative) control-value table. Owned copy —
    /// callers rescale a fresh copy per ppem from the font's raw `cvt`
    /// FWords.
    cvt: []i32,

    fdefs: []DefRecord,
    num_fdefs: u32 = 0,
    idefs: []DefRecord,
    num_idefs: u32 = 0,
    max_func: i32 = -1,
    max_ins: i32 = -1,

    call_stack: []CallRecord,
    call_top: u32 = 0,

    code_ranges: [3][]const u8 = .{ &.{}, &.{}, &.{} },

    twilight: Zone = .{},
    pts: Zone = .{},

    gs: GraphicsState = .{},
    default_gs: GraphicsState = .{},
    zp0: *Zone = undefined,
    zp1: *Zone = undefined,
    zp2: *Zone = undefined,

    move_vector: Point = .{ .x = 0x10000, .y = 0 },
    move_x_only: bool = true,
    move_y_only: bool = false,

    cur_ppem: i32 = 0,
    scale: i32 = 0x10000,
    is_composite: bool = false,

    code: []const u8 = &.{},
    ip: u32 = 0,
    cur_range: CodeRange = .font,
    ini_range: CodeRange = .font,
    opcode: u8 = 0,
    length: i32 = 1,

    loopcall_counter: u64 = 0,
    loopcall_counter_max: u64 = 300,
    neg_jump_counter: u64 = 0,
    neg_jump_counter_max: u64 = 300,
    ins_counter: u64 = 0,

    threshold: i32 = 0,
    phase: i32 = 0,
    period: i32 = 64,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Error!Interpreter {
        const self: Interpreter = .{
            .allocator = allocator,
            .limits = limits,
            .stack = try allocator.alloc(i32, limits.max_stack),
            .storage = try allocator.alloc(i32, limits.max_storage),
            .cvt = &.{},
            .fdefs = try allocator.alloc(DefRecord, limits.max_function_defs),
            .idefs = try allocator.alloc(DefRecord, limits.max_instruction_defs),
            .call_stack = try allocator.alloc(CallRecord, limits.max_call_depth),
        };
        @memset(self.storage, 0);
        return self;
    }

    pub fn deinit(self: *Interpreter) void {
        self.allocator.free(self.stack);
        self.allocator.free(self.storage);
        self.allocator.free(self.cvt);
        self.allocator.free(self.fdefs);
        self.allocator.free(self.idefs);
        self.allocator.free(self.call_stack);
    }

    /// Replaces the CVT with a freshly scaled copy (own allocation) —
    /// call once after loading `cvt` values for a new ppem.
    pub fn setCvt(self: *Interpreter, scaled_values: []const i32) Error!void {
        self.allocator.free(self.cvt);
        self.cvt = try self.allocator.dupe(i32, scaled_values);
    }

    fn setZones(self: *Interpreter) void {
        self.zp0 = zoneFor(self, self.gs.gep0);
        self.zp1 = zoneFor(self, self.gs.gep1);
        self.zp2 = zoneFor(self, self.gs.gep2);
    }

    fn zoneFor(self: *Interpreter, sel: u1) *Zone {
        return if (sel == 0) &self.twilight else &self.pts;
    }

    fn computeFuncs(self: *Interpreter) void {
        const f_dot_p_raw: i64 = @as(i64, self.gs.proj_vector.x) * @as(i64, self.gs.free_vector.x) +
            @as(i64, self.gs.proj_vector.y) * @as(i64, self.gs.free_vector.y) + 0x2000;
        const f_dot_p: i64 = f_dot_p_raw >> 14;

        if (f_dot_p >= 0x3FFE) {
            self.move_vector = .{ .x = @as(i32, self.gs.free_vector.x) * 4, .y = @as(i32, self.gs.free_vector.y) * 4 };
        } else if (f_dot_p > -0x400 and f_dot_p < 0x400) {
            self.move_vector = .{ .x = 0, .y = 0 };
        } else {
            self.move_vector = .{
                .x = @intCast(@divTrunc(@as(i64, self.gs.free_vector.x) * 0x10000, f_dot_p)),
                .y = @intCast(@divTrunc(@as(i64, self.gs.free_vector.y) * 0x10000, f_dot_p)),
            };
        }

        self.move_x_only = f_dot_p >= 0x3FFE and self.gs.free_vector.x == 0x4000;
        self.move_y_only = f_dot_p >= 0x3FFE and self.gs.free_vector.y == 0x4000;
    }

    fn project(self: *Interpreter, dx: i32, dy: i32) i32 {
        if (self.gs.proj_vector.x == 0x4000) return dx;
        if (self.gs.proj_vector.y == 0x4000) return dy;
        return dotFix14(dx, dy, self.gs.proj_vector.x, self.gs.proj_vector.y);
    }

    fn dualProject(self: *Interpreter, dx: i32, dy: i32) i32 {
        if (self.gs.dual_vector.x == 0x4000) return dx;
        if (self.gs.dual_vector.y == 0x4000) return dy;
        return dotFix14(dx, dy, self.gs.dual_vector.x, self.gs.dual_vector.y);
    }

    fn projectPts(self: *Interpreter, v1: Point, v2: Point) i32 {
        return self.project(v1.x -% v2.x, v1.y -% v2.y);
    }

    fn dualProjectPts(self: *Interpreter, v1: Point, v2: Point) i32 {
        return self.dualProject(v1.x -% v2.x, v1.y -% v2.y);
    }

    fn moveDirect(self: *Interpreter, zone: *Zone, point: u16, distance: i32) void {
        if (self.move_vector.x != 0) {
            zone.cur[point].x +%= mulFix(distance, self.move_vector.x);
            zone.tags[point] |= touch_x;
        }
        if (self.move_vector.y != 0) {
            zone.cur[point].y +%= mulFix(distance, self.move_vector.y);
            zone.tags[point] |= touch_y;
        }
    }

    fn moveOrig(self: *Interpreter, zone: *Zone, point: u16, distance: i32) void {
        if (self.move_vector.x != 0) zone.org[point].x +%= mulFix(distance, self.move_vector.x);
        if (self.move_vector.y != 0) zone.org[point].y +%= mulFix(distance, self.move_vector.y);
    }

    fn moveZp2Point(self: *Interpreter, point: u16, dx: i32, dy: i32) void {
        if (self.gs.free_vector.x != 0) {
            self.zp2.cur[point].x +%= dx;
            self.zp2.tags[point] |= touch_x;
        }
        if (self.gs.free_vector.y != 0) {
            self.zp2.cur[point].y +%= dy;
            self.zp2.tags[point] |= touch_y;
        }
    }

    fn roundValue(self: *Interpreter, distance: i32, compensation: i32) i32 {
        return switch (self.gs.round_state) {
            .off => roundNone(distance, compensation),
            .to_half_grid => roundToHalfGrid(distance, compensation),
            .to_grid => roundToGrid(distance, compensation),
            .to_double_grid => roundToDoubleGrid(distance, compensation),
            .down_to_grid => roundDownToGrid(distance, compensation),
            .up_to_grid => roundUpToGrid(distance, compensation),
            .super => self.roundSuper(distance, compensation),
            .super_45 => self.roundSuper45(distance, compensation),
        };
    }

    fn roundNone(distance: i32, compensation: i32) i32 {
        if (distance >= 0) return @max(0, distance +% compensation);
        return @min(0, distance -% compensation);
    }
    fn roundToGrid(distance: i32, compensation: i32) i32 {
        if (distance >= 0) return @max(0, pixRound(distance +% compensation));
        return @min(0, -%pixRound(compensation -% distance));
    }
    fn roundToHalfGrid(distance: i32, compensation: i32) i32 {
        if (distance >= 0) return @max(32, pixFloor(distance +% compensation) +% 32);
        return @min(-32, -%(pixFloor(compensation -% distance) +% 32));
    }
    fn roundToDoubleGrid(distance: i32, compensation: i32) i32 {
        if (distance >= 0) return @max(0, padRound(distance +% compensation, 32));
        return @min(0, -%padRound(compensation -% distance, 32));
    }
    fn roundDownToGrid(distance: i32, compensation: i32) i32 {
        if (distance >= 0) return @max(0, pixFloor(distance +% compensation));
        return @min(0, -%pixFloor(compensation -% distance));
    }
    fn roundUpToGrid(distance: i32, compensation: i32) i32 {
        if (distance >= 0) return @max(0, pixCeil(distance +% compensation));
        return @min(0, -%pixCeil(compensation -% distance));
    }

    fn roundSuper(self: *Interpreter, distance: i32, compensation: i32) i32 {
        if (self.period <= 0) return distance;
        if (distance >= 0) {
            var val = (distance +% self.threshold -% self.phase +% compensation) & -%self.period;
            val +%= self.phase;
            if (val < 0) val = self.phase;
            return val;
        } else {
            var val = -%((self.threshold -% self.phase +% compensation -% distance) & -%self.period);
            val -%= self.phase;
            if (val > 0) val = -self.phase;
            return val;
        }
    }

    fn roundSuper45(self: *Interpreter, distance: i32, compensation: i32) i32 {
        if (self.period <= 0) return distance;
        if (distance >= 0) {
            var val = @divTrunc(distance +% self.threshold -% self.phase +% compensation, self.period) *% self.period;
            val +%= self.phase;
            if (val < 0) val = self.phase;
            return val;
        } else {
            var val = -%(@divTrunc(self.threshold -% self.phase +% compensation -% distance, self.period) *% self.period);
            val -%= self.phase;
            if (val > 0) val = -self.phase;
            return val;
        }
    }

    fn setSuperRound(self: *Interpreter, grid_period: i32, selector: i32) void {
        self.period = switch (selector & 0xC0) {
            0 => @divTrunc(grid_period, 2),
            0x40 => grid_period,
            0x80 => grid_period * 2,
            else => grid_period,
        };
        self.phase = switch (selector & 0x30) {
            0 => 0,
            0x10 => @divTrunc(self.period, 4),
            0x20 => @divTrunc(self.period, 2),
            0x30 => @divTrunc(self.period *% 3, 4),
            else => unreachable,
        };
        self.threshold = if ((selector & 0x0F) == 0) self.period - 1 else (@as(i32, selector & 0x0F) - 4) *% @divTrunc(self.period, 8);
    }

    fn readCvt(self: *Interpreter, index: u32) i32 {
        if (index >= self.cvt.len) return 0;
        return self.cvt[index];
    }

    fn writeCvt(self: *Interpreter, index: u32, value: i32) void {
        if (index >= self.cvt.len) return;
        self.cvt[index] = value;
    }

    // -- Setup / running -----------------------------------------------

    /// Runs the font program (`fpgm`) once per font; installs FDEFs used
    /// by later CVT/glyph programs.
    pub fn runFontProgram(self: *Interpreter, code: []const u8) Error!void {
        try self.run(code, .font);
    }

    pub fn saveFontProgram(self: *const Interpreter, state_allocator: std.mem.Allocator) Error!FontProgramSnapshot {
        const storage = try state_allocator.dupe(i32, self.storage);
        errdefer state_allocator.free(storage);
        const fdefs = try state_allocator.dupe(DefRecord, self.fdefs[0..self.num_fdefs]);
        errdefer state_allocator.free(fdefs);
        const idefs = try state_allocator.dupe(DefRecord, self.idefs[0..self.num_idefs]);
        return .{
            .storage = storage,
            .fdefs = fdefs,
            .idefs = idefs,
            .max_func = self.max_func,
            .max_ins = self.max_ins,
            .gs = self.gs,
            .twilight = self.twilight,
        };
    }

    /// `snapshot` must come from `saveFontProgram` on this interpreter.
    pub fn restoreFontProgram(self: *Interpreter, snapshot: FontProgramSnapshot) void {
        @memcpy(self.storage, snapshot.storage);
        @memcpy(self.fdefs[0..snapshot.fdefs.len], snapshot.fdefs);
        self.num_fdefs = @intCast(snapshot.fdefs.len);
        @memcpy(self.idefs[0..snapshot.idefs.len], snapshot.idefs);
        self.num_idefs = @intCast(snapshot.idefs.len);
        self.max_func = snapshot.max_func;
        self.max_ins = snapshot.max_ins;
        self.gs = snapshot.gs;
        self.twilight = snapshot.twilight;
    }

    /// Runs the CVT program (`prep`) once per (font, ppem); may mutate
    /// `self.cvt`/`self.storage`, both persisted for subsequent glyph runs,
    /// and `self.default_gs` (only the fields `TT_Save_Context` copies —
    /// see its doc comment).
    pub fn runCvtProgram(self: *Interpreter, code: []const u8) Error!void {
        self.pts = .{};
        try self.run(code, .cvt);
        self.default_gs.minimum_distance = self.gs.minimum_distance;
        self.default_gs.control_value_cutin = self.gs.control_value_cutin;
        self.default_gs.single_width_cutin = self.gs.single_width_cutin;
        self.default_gs.single_width_value = self.gs.single_width_value;
        self.default_gs.delta_base = self.gs.delta_base;
        self.default_gs.delta_shift = self.gs.delta_shift;
        self.default_gs.auto_flip = self.gs.auto_flip;
        self.default_gs.instruct_control = self.gs.instruct_control;
        self.default_gs.scan_control = self.gs.scan_control;
        self.default_gs.scan_type = self.gs.scan_type;
    }

    /// Runs one glyph's instructions against `pts`/`twilight`. `pts` and
    /// `twilight` must already contain scaled (F26Dot6) `org`==`cur`
    /// points (phantom points included in `pts`) before calling.
    pub fn runGlyphProgram(self: *Interpreter, code: []const u8, pts: Zone, twilight: Zone, is_composite: bool) Error!void {
        self.pts = pts;
        self.twilight = twilight;
        self.is_composite = is_composite;
        self.gs = self.default_gs;

        if (pts.n_points > 0)
            self.loopcall_counter_max = @max(50, 10 * @as(u64, pts.n_points)) + @max(50, self.cvt.len / 10)
        else
            self.loopcall_counter_max = 300 + 22 * self.cvt.len;
        self.neg_jump_counter_max = self.loopcall_counter_max;
        self.loopcall_counter = 0;
        self.neg_jump_counter = 0;

        try self.run(code, .glyph);
    }

    fn run(self: *Interpreter, code: []const u8, range: CodeRange) Error!void {
        if (code.len == 0) return;
        self.code = code;
        self.code_ranges[@intFromEnum(range)] = code;
        self.ip = 0;
        self.cur_range = range;
        self.ini_range = range;
        self.top = 0;
        self.call_top = 0;
        self.gs.round_state = .to_grid;
        self.period = 64;
        self.threshold = 0;
        self.phase = 0;
        self.setZones();
        self.computeFuncs();

        while (true) {
            self.ins_counter += 1;
            if (self.ins_counter > self.limits.max_instructions) return error.ExecutionTooLong;

            self.opcode = self.code[self.ip];
            self.length = 1;

            try self.step();

            self.ip = @intCast(@as(i64, self.ip) +% self.length);
            if (self.ip >= self.code.len) {
                if (self.call_top > 0) return error.CodeOverflow;
                return;
            }
        }
    }

    fn gotoCodeRange(self: *Interpreter, range: CodeRange, target_ip: u32) Error!void {
        const buf = self.code_ranges[@intFromEnum(range)];
        if (buf.len == 0) return error.InvalidCodeRange;
        if (target_ip > buf.len) return error.CodeOverflow;
        self.cur_range = range;
        self.code = buf;
        self.ip = target_ip;
        self.length = 0;
    }

    fn skipCode(self: *Interpreter) Error!void {
        const next_ip: i64 = @as(i64, self.ip) + self.length;
        if (next_ip < 0 or next_ip >= self.code.len) return error.CodeOverflow;
        self.ip = @intCast(next_ip);
        self.opcode = self.code[self.ip];
        self.length = opcodeLength(self.opcode);
        if (self.length < 0) {
            if (self.ip + 1 >= self.code.len) return error.CodeOverflow;
            self.length = 2 - self.length * self.code[self.ip + 1];
        }
    }

    fn opcodeLength(op: u8) i32 {
        return switch (op) {
            0x40 => -1,
            0x41 => -2,
            0xB0...0xB7 => @as(i32, op - 0xB0) + 2,
            0xB8...0xBF => @as(i32, op - 0xB8) * 2 + 3,
            else => 1,
        };
    }

    fn popPushCount(op: u8) struct { pop: u32, push: u32 } {
        return switch (op) {
            0x00...0x05 => .{ .pop = 0, .push = 0 },
            0x06...0x09 => .{ .pop = 2, .push = 0 },
            0x0A, 0x0B => .{ .pop = 2, .push = 0 },
            0x0C, 0x0D => .{ .pop = 0, .push = 2 },
            0x0E => .{ .pop = 0, .push = 0 },
            0x0F => .{ .pop = 5, .push = 0 },
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 => .{ .pop = 1, .push = 0 },
            0x18, 0x19 => .{ .pop = 0, .push = 0 },
            0x1A => .{ .pop = 1, .push = 0 },
            0x1B => .{ .pop = 0, .push = 0 },
            0x1C => .{ .pop = 1, .push = 0 },
            0x1D, 0x1E, 0x1F => .{ .pop = 1, .push = 0 },
            0x20 => .{ .pop = 1, .push = 2 },
            0x21 => .{ .pop = 1, .push = 0 },
            0x22 => .{ .pop = 0, .push = 0 },
            0x23 => .{ .pop = 2, .push = 2 },
            0x24 => .{ .pop = 0, .push = 1 },
            0x25 => .{ .pop = 1, .push = 1 },
            0x26 => .{ .pop = 1, .push = 0 },
            0x27 => .{ .pop = 2, .push = 0 },
            0x28 => .{ .pop = 0, .push = 0 },
            0x29 => .{ .pop = 1, .push = 0 },
            0x2A => .{ .pop = 2, .push = 0 },
            0x2B => .{ .pop = 1, .push = 0 },
            0x2C => .{ .pop = 1, .push = 0 },
            0x2D => .{ .pop = 0, .push = 0 },
            0x2E, 0x2F => .{ .pop = 1, .push = 0 },
            0x30, 0x31 => .{ .pop = 0, .push = 0 },
            0x32, 0x33 => .{ .pop = 0, .push = 0 },
            0x34, 0x35 => .{ .pop = 1, .push = 0 },
            0x36, 0x37 => .{ .pop = 1, .push = 0 },
            0x38 => .{ .pop = 1, .push = 0 },
            0x39 => .{ .pop = 0, .push = 0 },
            0x3A, 0x3B => .{ .pop = 2, .push = 0 },
            0x3C => .{ .pop = 0, .push = 0 },
            0x3D => .{ .pop = 0, .push = 0 },
            0x3E, 0x3F => .{ .pop = 2, .push = 0 },
            0x40, 0x41 => .{ .pop = 0, .push = 0 },
            0x42 => .{ .pop = 2, .push = 0 },
            0x43 => .{ .pop = 1, .push = 1 },
            0x44 => .{ .pop = 2, .push = 0 },
            0x45 => .{ .pop = 1, .push = 1 },
            0x46, 0x47 => .{ .pop = 1, .push = 1 },
            0x48 => .{ .pop = 2, .push = 0 },
            0x49, 0x4A => .{ .pop = 2, .push = 1 },
            0x4B => .{ .pop = 0, .push = 1 },
            0x4C => .{ .pop = 0, .push = 1 },
            0x4D, 0x4E => .{ .pop = 0, .push = 0 },
            0x4F => .{ .pop = 1, .push = 0 },
            0x50...0x55 => .{ .pop = 2, .push = 1 },
            0x56, 0x57 => .{ .pop = 1, .push = 1 },
            0x58 => .{ .pop = 1, .push = 0 },
            0x59 => .{ .pop = 0, .push = 0 },
            0x5A, 0x5B => .{ .pop = 2, .push = 1 },
            0x5C => .{ .pop = 1, .push = 1 },
            0x5D => .{ .pop = 1, .push = 0 },
            0x5E => .{ .pop = 1, .push = 0 },
            0x5F => .{ .pop = 1, .push = 0 },
            0x60, 0x61, 0x62, 0x63 => .{ .pop = 2, .push = 1 },
            0x64, 0x65, 0x66, 0x67 => .{ .pop = 1, .push = 1 },
            0x68...0x6F => .{ .pop = 1, .push = 1 },
            0x70 => .{ .pop = 2, .push = 0 },
            0x71, 0x72 => .{ .pop = 1, .push = 0 },
            0x73, 0x74, 0x75 => .{ .pop = 1, .push = 0 },
            0x76, 0x77 => .{ .pop = 1, .push = 0 },
            0x78, 0x79 => .{ .pop = 2, .push = 0 },
            0x7A => .{ .pop = 0, .push = 0 },
            0x7B => .{ .pop = 0, .push = 0 },
            0x7C, 0x7D => .{ .pop = 0, .push = 0 },
            0x7E => .{ .pop = 1, .push = 0 },
            0x7F => .{ .pop = 1, .push = 0 },
            0x80 => .{ .pop = 0, .push = 0 },
            0x81, 0x82 => .{ .pop = 2, .push = 0 },
            0x83, 0x84 => .{ .pop = 0, .push = 0 },
            0x85 => .{ .pop = 1, .push = 0 },
            0x86, 0x87 => .{ .pop = 2, .push = 0 },
            0x88 => .{ .pop = 1, .push = 1 },
            0x89 => .{ .pop = 1, .push = 0 },
            0x8A => .{ .pop = 3, .push = 3 },
            0x8B, 0x8C => .{ .pop = 2, .push = 1 },
            0x8D => .{ .pop = 1, .push = 0 },
            0x8E => .{ .pop = 2, .push = 0 },
            0x8F...0xAF => .{ .pop = 0, .push = 0 },
            0xB0...0xB7 => .{ .pop = 0, .push = @as(u32, op - 0xB0) + 1 },
            0xB8...0xBF => .{ .pop = 0, .push = @as(u32, op - 0xB8) + 1 },
            0xC0...0xDF => .{ .pop = 1, .push = 0 },
            0xE0...0xFF => .{ .pop = 2, .push = 0 },
        };
    }

    fn findFdef(self: *Interpreter, opc: u32) ?u32 {
        var i: u32 = 0;
        while (i < self.num_fdefs) : (i += 1) if (self.fdefs[i].opc == opc) return i;
        return null;
    }

    fn findIdef(self: *Interpreter, opc: u32) ?u32 {
        var i: u32 = 0;
        while (i < self.num_idefs) : (i += 1) if (self.idefs[i].opc == opc) return i;
        return null;
    }

    /// Executes exactly one opcode: decodes/pushes/pops per
    /// `popPushCount`, dispatches, and (for `IF`/`ELSE`/`FDEF`/`IDEF`/
    /// `NPUSHB`/`NPUSHW`/`PUSHB`/`PUSHW`) may itself advance `self.ip`
    /// and override `self.length`.
    fn step(self: *Interpreter) Error!void {
        const op = self.opcode;
        if (debug_trace) std.debug.print("[{s}] ip={d} op={x} top={d} stack={any}\n", .{ @tagName(self.cur_range), self.ip, op, self.top, self.stack[0..self.top] });

        // IF/ELSE/EIF drive control flow directly off the code stream
        // rather than the generic pop/push machinery (matches FreeType:
        // IF's stack effect is handled specially before the counted path).
        if (op == 0x58) {
            if (self.top < 1) return error.StackUnderflow;
            self.top -= 1;
            return self.insIf(self.stack[self.top]);
        }
        if (op == 0x1B) return self.insElse();
        if (op == 0x59) return; // EIF: no-op landing pad

        // These opcodes consume a `GS.loop`- or stack-encoded-count-many
        // extra operands below their nominal `popPushCount` window (the
        // TrueType spec's `Pop_Push_Count` table only covers the fixed
        // part). They manage `self.top` themselves, so bypass the counted
        // path entirely (same reasoning as IF/ELSE above).
        switch (op) {
            0x32, 0x33 => return self.insShp(op),
            0x38 => return self.insShpix(),
            0x39 => return self.insIp(),
            0x3C => return self.insAlignrp(),
            0x80 => return self.insFlippt(),
            0x5D, 0x71, 0x72 => return self.insDeltaP(op),
            0x73, 0x74, 0x75 => return self.insDeltaC(op),
            0x40 => return self.insNpushb(self.stack[self.top..]),
            0x41 => return self.insNpushw(self.stack[self.top..]),
            else => {},
        }

        const counts = popPushCount(op);
        var args_index: i64 = @as(i64, self.top) - counts.pop;
        if (args_index < 0) {
            var i: u32 = 0;
            while (i < counts.push) : (i += 1) self.stack[i] = 0;
            args_index = 0;
        }
        const new_top: i64 = args_index + counts.push;
        if (new_top > self.stack.len) return error.StackOverflow;

        const args_len = @max(counts.pop, counts.push);
        const args = self.stack[@intCast(args_index)..][0..args_len];

        try self.dispatch(op, args);
        self.top = @intCast(new_top);
    }

    fn pointIndexArg(v: i32) u16 {
        return if (v < 0 or v > 0xFFFF) 0xFFFF else @intCast(v);
    }

    fn dispatch(self: *Interpreter, op: u8, args: []i32) Error!void {
        switch (op) {
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05 => self.insSxyTca(op),
            0x06, 0x07 => try self.insSxVtl(op, pointIndexArg(args[1]), pointIndexArg(args[0]), true),
            0x08, 0x09 => try self.insSxVtl(op, pointIndexArg(args[1]), pointIndexArg(args[0]), false),
            0x0A => {
                self.gs.proj_vector = normalize(@as(i16, @truncate(args[0])), @as(i16, @truncate(args[1])));
                self.gs.dual_vector = self.gs.proj_vector;
                self.computeFuncs();
            },
            0x0B => {
                self.gs.free_vector = normalize(@as(i16, @truncate(args[0])), @as(i16, @truncate(args[1])));
                self.computeFuncs();
            },
            0x0C => {
                args[0] = self.gs.proj_vector.x;
                args[1] = self.gs.proj_vector.y;
            },
            0x0D => {
                args[0] = self.gs.free_vector.x;
                args[1] = self.gs.free_vector.y;
            },
            0x0E => {
                self.gs.free_vector = self.gs.proj_vector;
                self.computeFuncs();
            },
            0x0F => self.insIsect(args),
            0x10 => self.gs.rp0 = boundU16(args[0]),
            0x11 => self.gs.rp1 = boundU16(args[0]),
            0x12 => self.gs.rp2 = boundU16(args[0]),
            0x13 => {
                self.gs.gep0 = zoneSelector(args[0]);
                self.setZones();
            },
            0x14 => {
                self.gs.gep1 = zoneSelector(args[0]);
                self.setZones();
            },
            0x15 => {
                self.gs.gep2 = zoneSelector(args[0]);
                self.setZones();
            },
            0x16 => {
                const s = zoneSelector(args[0]);
                self.gs.gep0 = s;
                self.gs.gep1 = s;
                self.gs.gep2 = s;
                self.setZones();
            },
            0x17 => {
                if (args[0] < 0) return error.BadArgument;
                self.gs.loop = @min(args[0], 0xFFFF);
            },
            0x18 => {
                self.gs.round_state = .to_grid;
            },
            0x19 => {
                self.gs.round_state = .to_half_grid;
            },
            0x1A => self.gs.minimum_distance = args[0],
            0x1B => unreachable, // ELSE: handled in step()
            0x1C => try self.insJmpr(args),
            0x1D => self.gs.control_value_cutin = args[0],
            0x1E => self.gs.single_width_cutin = args[0],
            0x1F => self.gs.single_width_value = args[0],
            0x20 => {
                args[1] = args[0];
            },
            0x21 => {},
            0x22 => {},
            0x23 => {
                const tmp = args[0];
                args[0] = args[1];
                args[1] = tmp;
            },
            0x24 => args[0] = @intCast(self.top),
            0x25 => self.insCindex(args),
            0x26 => self.insMindex(args),
            0x27 => self.insAlignpts(args),
            0x28 => {},
            0x29 => self.insUtp(args),
            0x2A => try self.insLoopcall(args),
            0x2B => try self.insCall(args),
            0x2C => try self.insFdef(args),
            0x2D => try self.insEndf(),
            0x2E, 0x2F => self.insMdap(op, args),
            0x30, 0x31 => self.insIup(op),
            0x32, 0x33 => unreachable, // handled in step()
            0x34, 0x35 => self.insShc(op, args),
            0x36, 0x37 => self.insShz(op, args),
            0x38 => unreachable, // handled in step()
            0x39 => unreachable, // handled in step()
            0x3A, 0x3B => self.insMsirp(op, args),
            0x3C => unreachable, // handled in step()
            0x3D => {
                self.gs.round_state = .to_double_grid;
            },
            0x3E, 0x3F => self.insMiap(op, args),
            0x40, 0x41 => unreachable, // handled in step()
            0x42 => self.insWs(args),
            0x43 => self.insRs(args),
            0x44 => self.writeCvt(boundIndex(args[0], @intCast(self.cvt.len + 1)), args[1]),
            0x45 => args[0] = self.readCvt(boundIndex(args[0], @intCast(self.cvt.len + 1))),
            0x46, 0x47 => self.insGc(op, args),
            0x48 => self.insScfs(args),
            0x49, 0x4A => self.insMd(op, args),
            0x4B => args[0] = self.cur_ppem,
            0x4C => args[0] = 0,
            0x4D, 0x4E => {},
            0x4F => {},
            0x50 => args[0] = @intFromBool(args[0] < args[1]),
            0x51 => args[0] = @intFromBool(args[0] <= args[1]),
            0x52 => args[0] = @intFromBool(args[0] > args[1]),
            0x53 => args[0] = @intFromBool(args[0] >= args[1]),
            0x54 => args[0] = @intFromBool(args[0] == args[1]),
            0x55 => args[0] = @intFromBool(args[0] != args[1]),
            0x56 => args[0] = @intFromBool((self.roundValue(args[0], 0) & 64) == 64),
            0x57 => args[0] = @intFromBool((self.roundValue(args[0], 0) & 64) == 0),
            0x58 => unreachable,
            0x59 => unreachable,
            0x5A => args[0] = @intFromBool(args[0] != 0 and args[1] != 0),
            0x5B => args[0] = @intFromBool(args[0] != 0 or args[1] != 0),
            0x5C => args[0] = @intFromBool(args[0] == 0),
            0x5D => unreachable, // handled in step()
            0x5E => self.gs.delta_base = boundU16(args[0]),
            0x5F => {
                if (args[0] < 0 or args[0] > 6) return error.BadArgument;
                self.gs.delta_shift = @intCast(args[0]);
            },
            0x60 => args[0] = args[0] +% args[1],
            0x61 => args[0] = args[0] -% args[1],
            0x62 => {
                if (args[1] == 0) return error.DivideByZero;
                args[0] = mulDivNoRound(args[0], 64, args[1]);
            },
            0x63 => args[0] = mulDiv(args[0], args[1], 64),
            0x64 => if (args[0] < 0) {
                args[0] = -%args[0];
            },
            0x65 => args[0] = -%args[0],
            0x66 => args[0] = pixFloor(args[0]),
            0x67 => args[0] = pixCeil(args[0]),
            0x68, 0x69, 0x6A, 0x6B => args[0] = self.roundOpcode(op, args[0]),
            0x6C, 0x6D, 0x6E, 0x6F => args[0] = roundNone(args[0], self.gs.compensation[op & 3]),
            0x70 => self.writeCvt(boundIndex(args[0], @intCast(self.cvt.len + 1)), mulFix(args[1], self.scale)),
            0x71, 0x72 => unreachable, // handled in step()
            0x73, 0x74, 0x75 => unreachable, // handled in step()
            0x76 => {
                self.setSuperRound(0x4000, args[0]);
                self.gs.round_state = .super;
            },
            0x77 => {
                self.setSuperRound(0x2D41, args[0]);
                self.gs.round_state = .super_45;
            },
            0x78 => if (args[1] != 0) try self.insJmpr(args),
            0x79 => if (args[1] == 0) try self.insJmpr(args),
            0x7A => {
                self.gs.round_state = .off;
            },
            0x7B => {},
            0x7C => {
                self.gs.round_state = .up_to_grid;
            },
            0x7D => {
                self.gs.round_state = .down_to_grid;
            },
            0x7E => {},
            0x7F => {},
            0x80 => unreachable, // handled in step()
            0x81 => self.insFliprgon(args, true),
            0x82 => self.insFliprgon(args, false),
            0x83, 0x84 => {},
            0x85 => self.gs.scan_control = args[0] != 0,
            0x86, 0x87 => try self.insSdpvtl(op, args),
            0x88 => args[0] = self.insGetinfo(args[0]),
            0x89 => try self.insIdef(args),
            0x8A => insRoll(args),
            0x8B => args[0] = @max(args[0], args[1]),
            0x8C => args[0] = @min(args[0], args[1]),
            0x8D => self.gs.scan_type = args[0],
            0x8E => {},
            0x8F...0xAF => try self.insUnknownOrIdef(op, args),
            0xB0...0xB7 => try self.insPushb(op, args),
            0xB8...0xBF => try self.insPushw(op, args),
            0xC0...0xDF => self.insMdrp(op, args),
            0xE0...0xFF => self.insMirp(op, args),
        }
    }

    // -- Control flow -----------------------------------------------

    fn insIf(self: *Interpreter, cond: i32) Error!void {
        if (cond != 0) return;
        var n_ifs: i32 = 1;
        while (true) {
            try self.skipCode();
            switch (self.opcode) {
                0x58 => n_ifs += 1,
                0x1B => if (n_ifs == 1) return,
                0x59 => {
                    n_ifs -= 1;
                    if (n_ifs == 0) return;
                },
                else => {},
            }
        }
    }

    fn insElse(self: *Interpreter) Error!void {
        var n_ifs: i32 = 1;
        while (n_ifs != 0) {
            try self.skipCode();
            switch (self.opcode) {
                0x58 => n_ifs += 1,
                0x59 => n_ifs -= 1,
                else => {},
            }
        }
    }

    fn insJmpr(self: *Interpreter, args: []i32) Error!void {
        const new_ip: i64 = @as(i64, self.ip) + args[0];
        if (new_ip < 0) return;
        if (self.call_top > 0) {
            const def = if (self.call_stack[self.call_top - 1].kind == .fdef)
                self.fdefs[self.call_stack[self.call_top - 1].index]
            else
                self.idefs[self.call_stack[self.call_top - 1].index];
            if (new_ip > def.end) return;
        }
        self.ip = @intCast(new_ip);
        self.length = 0;
        if (args[0] < 0) {
            self.neg_jump_counter += 1;
            if (self.neg_jump_counter > self.neg_jump_counter_max) return error.ExecutionTooLong;
        }
    }

    fn insFdef(self: *Interpreter, args: []i32) Error!void {
        if (self.ini_range == .glyph) return error.DefInGlyphBytecode;
        const n: u32 = boundU32(args[0]);
        var existing = self.findFdef(n);
        if (existing == null) {
            if (self.num_fdefs >= self.fdefs.len) return error.TooManyFunctionDefs;
            existing = self.num_fdefs;
            self.num_fdefs += 1;
        }
        const idx = existing.?;
        const opc: u16 = @intCast(@min(n, 0xFFFF));
        self.fdefs[idx] = .{ .range = self.cur_range, .start = self.ip + 1, .opc = opc, .active = true };
        if (opc > self.max_func) self.max_func = opc;

        while (true) {
            self.skipCode() catch return;
            switch (self.opcode) {
                0x89, 0x2C => return error.NestedDefs,
                0x2D => {
                    self.fdefs[idx].end = self.ip;
                    return;
                },
                else => {},
            }
        }
    }

    fn insIdef(self: *Interpreter, args: []i32) Error!void {
        if (self.ini_range == .glyph) return error.DefInGlyphBytecode;
        if (args[0] < 0 or args[0] > 0xFF) return error.TooManyInstructionDefs;
        const n: u32 = @intCast(args[0]);
        var existing = self.findIdef(n);
        if (existing == null) {
            if (self.num_idefs >= self.idefs.len) return error.TooManyInstructionDefs;
            existing = self.num_idefs;
            self.num_idefs += 1;
        }
        const idx = existing.?;
        self.idefs[idx] = .{ .range = self.cur_range, .start = self.ip + 1, .opc = @intCast(n), .active = true };
        if (n > self.max_ins) self.max_ins = @intCast(n);

        while (true) {
            self.skipCode() catch return;
            switch (self.opcode) {
                0x89, 0x2C => return error.NestedDefs,
                0x2D => {
                    self.idefs[idx].end = self.ip;
                    return;
                },
                else => {},
            }
        }
    }

    fn insEndf(self: *Interpreter) Error!void {
        if (self.call_top == 0) return error.EndfInExecStream;
        self.call_top -= 1;
        var rec = &self.call_stack[self.call_top];
        rec.cur_count -= 1;
        if (rec.cur_count > 0) {
            self.call_top += 1;
            const def = if (rec.kind == .fdef) self.fdefs[rec.index] else self.idefs[rec.index];
            self.ip = def.start;
            self.length = 0;
        } else {
            try self.gotoCodeRange(rec.caller_range, rec.caller_ip);
        }
    }

    fn insCall(self: *Interpreter, args: []i32) Error!void {
        if (args[0] < 0) return;
        const f: u32 = @intCast(args[0]);
        const idx = self.findFdef(f) orelse return;
        if (!self.fdefs[idx].active) return;
        if (self.call_top >= self.call_stack.len) return error.CallStackOverflow;
        self.call_stack[self.call_top] = .{
            .caller_range = self.cur_range,
            .caller_ip = self.ip + 1,
            .cur_count = 1,
            .kind = .fdef,
            .index = idx,
        };
        self.call_top += 1;
        try self.gotoCodeRange(self.fdefs[idx].range, self.fdefs[idx].start);
    }

    fn insLoopcall(self: *Interpreter, args: []i32) Error!void {
        if (args[1] < 0) return;
        const f: u32 = @intCast(args[1]);
        const idx = self.findFdef(f) orelse return;
        if (!self.fdefs[idx].active) return;
        if (self.call_top >= self.call_stack.len) return error.CallStackOverflow;
        if (args[0] <= 0) return;
        self.call_stack[self.call_top] = .{
            .caller_range = self.cur_range,
            .caller_ip = self.ip + 1,
            .cur_count = @intCast(args[0]),
            .kind = .fdef,
            .index = idx,
        };
        self.call_top += 1;
        try self.gotoCodeRange(self.fdefs[idx].range, self.fdefs[idx].start);
        self.loopcall_counter += @intCast(args[0]);
        if (self.loopcall_counter > self.loopcall_counter_max) return error.ExecutionTooLong;
    }

    fn insUnknownOrIdef(self: *Interpreter, op: u8, args: []i32) Error!void {
        _ = args;
        const idx = self.findIdef(op) orelse return;
        if (!self.idefs[idx].active) return;
        if (self.call_top >= self.call_stack.len) return error.CallStackOverflow;
        self.call_stack[self.call_top] = .{
            .caller_range = self.cur_range,
            .caller_ip = self.ip + 1,
            .cur_count = 1,
            .kind = .idef,
            .index = idx,
        };
        self.call_top += 1;
        try self.gotoCodeRange(self.idefs[idx].range, self.idefs[idx].start);
    }

    // -- Push -----------------------------------------------------------

    fn insPushb(self: *Interpreter, op: u8, args: []i32) Error!void {
        const count: u32 = @as(u32, op - 0xB0) + 1;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            const pos = self.ip + 1 + k;
            if (pos >= self.code.len) return error.CodeOverflow;
            args[k] = self.code[pos];
        }
        self.length = @intCast(count + 1);
    }

    fn insPushw(self: *Interpreter, op: u8, args: []i32) Error!void {
        const count: u32 = @as(u32, op - 0xB8) + 1;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            const pos = self.ip + 1 + k * 2;
            if (pos + 1 >= self.code.len) return error.CodeOverflow;
            const hi = self.code[pos];
            const lo = self.code[pos + 1];
            args[k] = @as(i16, @bitCast(@as(u16, hi) << 8 | lo));
        }
        self.length = @intCast(2 * count + 1);
    }

    fn insNpushb(self: *Interpreter, args: []i32) Error!void {
        var ip = self.ip + 1;
        if (ip >= self.code.len) return error.CodeOverflow;
        const count: u32 = self.code[ip];
        if (ip + count >= self.code.len) return error.CodeOverflow;
        if (count > self.stack.len - self.top) return error.StackOverflow;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            ip += 1;
            args[k] = self.code[ip];
        }
        self.top += count;
        self.ip = ip + 1;
        self.length = 0;
    }

    fn insNpushw(self: *Interpreter, args: []i32) Error!void {
        var ip = self.ip + 1;
        if (ip >= self.code.len) return error.CodeOverflow;
        const count: u32 = self.code[ip];
        if (ip + 2 * count >= self.code.len) return error.CodeOverflow;
        if (count > self.stack.len - self.top) return error.StackOverflow;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            const hi = self.code[ip + 1];
            const lo = self.code[ip + 2];
            args[k] = @as(i16, @bitCast(@as(u16, hi) << 8 | lo));
            ip += 2;
        }
        self.top += count;
        self.ip = ip + 1;
        self.length = 0;
    }

    // -- Stack manipulation ----------------------------------------------

    /// `args` here is the 1-element window from the generic dispatch
    /// (declared pop=1); the elements MINDEX rotates live *below* that
    /// window, addressed via `args_index = self.top - 1` — mirrors
    /// FreeType's `args[-L]` pointer arithmetic.
    fn insMindex(self: *Interpreter, args: []i32) void {
        const args_index: i64 = @as(i64, self.top) - 1;
        const l = args[0];
        if (l <= 0 or l > args_index) return;
        const li: u32 = @intCast(l);
        const base: u32 = @intCast(args_index - li);
        const k = self.stack[base];
        var i: u32 = 0;
        while (i + 1 < li) : (i += 1) self.stack[base + i] = self.stack[base + i + 1];
        self.stack[base + li - 1] = k;
    }

    fn insCindex(self: *Interpreter, args: []i32) void {
        const args_index: i64 = @as(i64, self.top) - 1;
        const l = args[0];
        if (l <= 0 or l > args_index) {
            args[0] = 0;
            return;
        }
        args[0] = self.stack[@intCast(args_index - l)];
    }

    /// `A B C -> B C A` (`A`=args[2]/top, `B`=args[1], `C`=args[0]/bottom).
    fn insRoll(args: []i32) void {
        const a = args[0];
        const b = args[1];
        const c = args[2];
        args[0] = b;
        args[1] = c;
        args[2] = a;
    }

    /// Pops `GS.loop`-many extra operands from the stack top (resetting
    /// `GS.loop` to 1), for opcodes whose loop count isn't part of the
    /// declared `popPushCount` window (SHP/SHPIX/IP/ALIGNRP/FLIPPT).
    /// Returned slice is in push order (index 0 = deepest/first-pushed).
    fn popLoop(self: *Interpreter) ?[]i32 {
        const loop: u32 = if (self.gs.loop > 0) @intCast(self.gs.loop) else 1;
        self.gs.loop = 1;
        if (loop > self.top) return null;
        const base = self.top - loop;
        self.top = base;
        return self.stack[base..][0..loop];
    }

    // -- Vectors -----------------------------------------------------

    fn insSxyTca(self: *Interpreter, op: u8) void {
        const aa: i16 = if ((op & 1) != 0) 0x4000 else 0;
        const bb: i16 = aa ^ 0x4000;
        if (op < 4) {
            self.gs.proj_vector = .{ .x = aa, .y = bb };
            self.gs.dual_vector = .{ .x = aa, .y = bb };
        }
        if ((op & 2) == 0) {
            self.gs.free_vector = .{ .x = aa, .y = bb };
        }
        self.computeFuncs();
    }

    fn insSxVtl(self: *Interpreter, op: u8, idx1: u16, idx2: u16, is_proj: bool) Error!void {
        if (idx1 >= self.zp2.n_points or idx2 >= self.zp1.n_points) return;
        const p1 = self.zp1.cur[idx2];
        const p2 = self.zp2.cur[idx1];
        var a: i32 = p1.x -% p2.x;
        var b: i32 = p1.y -% p2.y;
        var eff_op = op;
        if (a == 0 and b == 0) {
            a = 0x4000;
            eff_op = 0;
        }
        if ((eff_op & 1) != 0) {
            const c = b;
            b = a;
            a = -%c;
        }
        const uv = normalize(a, b);
        if (is_proj) {
            self.gs.proj_vector = uv;
            self.gs.dual_vector = uv;
        } else {
            self.gs.free_vector = uv;
        }
        self.computeFuncs();
    }

    fn insSdpvtl(self: *Interpreter, op: u8, args: []i32) Error!void {
        const p2 = boundU16(args[1]);
        const p1 = boundU16(args[0]);
        if (p2 >= self.zp1.n_points or p1 >= self.zp2.n_points) return;
        const v1 = self.zp1.org[p2];
        const v2 = self.zp2.org[p1];
        var a: i32 = v1.x -% v2.x;
        var b: i32 = v1.y -% v2.y;
        var eff_op = op;
        if (a == 0 and b == 0) {
            a = 0x4000;
            eff_op = 0;
        }
        if ((eff_op & 1) != 0) {
            const c = b;
            b = a;
            a = -%c;
        }
        const uv = normalize(a, b);
        self.gs.proj_vector = uv;
        self.gs.dual_vector = uv;
        self.computeFuncs();
    }

    // -- Points / measuring --------------------------------------------

    fn computePointDisplacement(self: *Interpreter, cur: ?[]const Point) struct { ok: bool, dx: i32, dy: i32, refp: ?u32 } {
        const use_zp0 = (self.opcode & 1) != 0;
        const zp = if (use_zp0) self.zp0 else self.zp1;
        const p = if (use_zp0) self.gs.rp1 else self.gs.rp2;
        if (p >= zp.n_points) return .{ .ok = false, .dx = 0, .dy = 0, .refp = null };
        const refp: ?u32 = if (cur != null and cur.?.ptr == zp.cur.ptr) p else null;
        const d = self.projectPts(zp.cur[p], zp.org[p]);
        return .{ .ok = true, .dx = mulFix(d, self.move_vector.x), .dy = mulFix(d, self.move_vector.y), .refp = refp };
    }

    fn insIsect(self: *Interpreter, args: []i32) void {
        const point = boundU16(args[0]);
        const a0 = boundU16(args[1]);
        const a1 = boundU16(args[2]);
        const b0 = boundU16(args[3]);
        const b1 = boundU16(args[4]);
        if (b0 >= self.zp0.n_points or b1 >= self.zp0.n_points or
            a0 >= self.zp1.n_points or a1 >= self.zp1.n_points or
            point >= self.zp2.n_points) return;

        const dbx = self.zp0.cur[b1].x -% self.zp0.cur[b0].x;
        const dby = self.zp0.cur[b1].y -% self.zp0.cur[b0].y;
        const dax = self.zp1.cur[a1].x -% self.zp1.cur[a0].x;
        const day = self.zp1.cur[a1].y -% self.zp1.cur[a0].y;
        const dx = self.zp0.cur[b0].x -% self.zp1.cur[a0].x;
        const dy = self.zp0.cur[b0].y -% self.zp1.cur[a0].y;

        const discriminant = mulDiv(dax, -%dby, 0x40) +% mulDiv(day, dbx, 0x40);
        const dotproduct = mulDiv(dax, dbx, 0x40) +% mulDiv(day, dby, 0x40);

        if (19 *% @abs(discriminant) > @abs(dotproduct)) {
            const val = mulDiv(dx, -%dby, 0x40) +% mulDiv(dy, dbx, 0x40);
            const rx = mulDiv(val, dax, discriminant);
            const ry = mulDiv(val, day, discriminant);
            self.zp2.cur[point].x = self.zp1.cur[a0].x +% rx;
            self.zp2.cur[point].y = self.zp1.cur[a0].y +% ry;
        } else {
            self.zp2.cur[point].x = @divTrunc((self.zp1.cur[a0].x +% self.zp1.cur[a1].x) +% (self.zp0.cur[b0].x +% self.zp0.cur[b1].x), 4);
            self.zp2.cur[point].y = @divTrunc((self.zp1.cur[a0].y +% self.zp1.cur[a1].y) +% (self.zp0.cur[b0].y +% self.zp0.cur[b1].y), 4);
        }
        self.zp2.tags[point] |= touch_both;
    }

    fn insAlignpts(self: *Interpreter, args: []i32) void {
        const p1 = boundU16(args[0]);
        const p2 = boundU16(args[1]);
        if (p1 >= self.zp1.n_points or p2 >= self.zp0.n_points) return;
        const distance = @divTrunc(self.projectPts(self.zp0.cur[p2], self.zp1.cur[p1]), 2);
        self.moveDirect(self.zp1, p1, distance);
        self.moveDirect(self.zp0, p2, -%distance);
    }

    fn insAlignrp(self: *Interpreter) void {
        const pts = self.popLoop() orelse return;
        if (self.gs.rp0 >= self.zp0.n_points) return;
        for (pts) |raw| {
            const point = boundU16(raw);
            if (point >= self.zp1.n_points) continue;
            const distance = self.projectPts(self.zp1.cur[point], self.zp0.cur[self.gs.rp0]);
            self.moveDirect(self.zp1, point, -%distance);
        }
    }

    fn insUtp(self: *Interpreter, args: []i32) void {
        const point = boundU16(args[0]);
        if (point >= self.zp0.n_points) return;
        var mask: u8 = 0xFF;
        if (self.gs.free_vector.x != 0) mask &= ~touch_x;
        if (self.gs.free_vector.y != 0) mask &= ~touch_y;
        self.zp0.tags[point] &= mask;
    }

    fn insShp(self: *Interpreter, op: u8) void {
        self.opcode = op;
        const pts = self.popLoop() orelse return;
        const disp = self.computePointDisplacement(self.zp2.cur);
        if (!disp.ok) return;
        for (pts) |raw| {
            const point = boundU16(raw);
            if (point >= self.zp2.n_points) continue;
            if (disp.refp != null and disp.refp.? == point) continue;
            self.moveZp2Point(point, disp.dx, disp.dy);
        }
    }

    fn insShc(self: *Interpreter, op: u8, args: []i32) void {
        self.opcode = op;
        const contour = boundU16(args[0]);
        const bounds: u16 = if (self.gs.gep2 == 0) 1 else self.zp2.n_contours;
        if (contour >= bounds) return;
        const disp = self.computePointDisplacement(self.zp2.cur);
        if (!disp.ok) return;
        const start: u32 = if (contour == 0) 0 else @as(u32, self.zp2.contours[contour - 1]) + 1;
        // `contours` is raw glyf data (see `insIup`'s clamp): an entry past
        // the point count would walk `moveZp2Point` off the end of the zone.
        const limit: u32 = @min(
            if (self.gs.gep2 == 0) self.zp2.n_points else @as(u32, self.zp2.contours[contour]) + 1,
            self.zp2.n_points,
        );
        var i = start;
        while (i < limit) : (i += 1) {
            if (disp.refp != null and disp.refp.? == i) continue;
            self.moveZp2Point(@intCast(i), disp.dx, disp.dy);
        }
    }

    fn insShz(self: *Interpreter, op: u8, args: []i32) void {
        self.opcode = op;
        const zone: *Zone, const limit: u32 = switch (args[0]) {
            0 => .{ &self.twilight, self.twilight.n_points },
            1 => .{ &self.pts, if (self.pts.n_points > 4) self.pts.n_points - 4 else 0 },
            else => return,
        };
        const disp = self.computePointDisplacement(zone.cur);
        if (!disp.ok) return;
        if (disp.dx != 0) {
            var i: u32 = 0;
            while (i < limit) : (i += 1) {
                if (disp.refp != null and disp.refp.? == i) continue;
                zone.cur[i].x +%= disp.dx;
            }
        }
        if (disp.dy != 0) {
            var i: u32 = 0;
            while (i < limit) : (i += 1) {
                if (disp.refp != null and disp.refp.? == i) continue;
                zone.cur[i].y +%= disp.dy;
            }
        }
    }

    fn insShpix(self: *Interpreter) void {
        if (self.top < 1) {
            self.gs.loop = 1;
            return;
        }
        self.top -= 1;
        const amount = self.stack[self.top];
        const pts = self.popLoop() orelse return;
        const dx = mulFix14(amount, self.gs.free_vector.x);
        const dy = mulFix14(amount, self.gs.free_vector.y);
        for (pts) |raw| {
            const point = boundU16(raw);
            if (point >= self.zp2.n_points) continue;
            self.moveZp2Point(point, dx, dy);
        }
    }

    fn insMsirp(self: *Interpreter, op: u8, args: []i32) void {
        const point = boundU16(args[0]);
        if (point >= self.zp1.n_points or self.gs.rp0 >= self.zp0.n_points) return;
        if (self.gs.gep1 == 0) {
            self.zp1.org[point] = self.zp0.org[self.gs.rp0];
            self.moveOrig(self.zp1, point, args[1]);
            self.zp1.cur[point] = self.zp1.org[point];
        }
        const distance = self.projectPts(self.zp1.cur[point], self.zp0.cur[self.gs.rp0]);
        self.moveDirect(self.zp1, point, args[1] -% distance);
        self.gs.rp1 = self.gs.rp0;
        self.gs.rp2 = point;
        if ((op & 1) != 0) self.gs.rp0 = point;
    }

    fn insIp(self: *Interpreter) void {
        const pts = self.popLoop() orelse return;
        if (self.gs.rp1 >= self.zp0.n_points) return;

        const twilight = self.gs.gep0 == 0 or self.gs.gep1 == 0 or self.gs.gep2 == 0;
        const orus_base = if (twilight) self.zp0.org[self.gs.rp1] else self.zp0.orus[self.gs.rp1];
        const cur_base = self.zp0.cur[self.gs.rp1];

        var old_range: i32 = 0;
        var cur_range: i32 = 0;
        if (self.gs.rp2 < self.zp1.n_points) {
            const orus2 = if (twilight) self.zp1.org[self.gs.rp2] else self.zp1.orus[self.gs.rp2];
            old_range = self.dualProjectPts(orus2, orus_base);
            cur_range = self.projectPts(self.zp1.cur[self.gs.rp2], cur_base);
        }

        for (pts) |raw| {
            const point = boundU16(raw);
            if (point >= self.zp2.n_points) continue;

            const orus_p = if (twilight) self.zp2.org[point] else self.zp2.orus[point];
            const org_dist = self.dualProjectPts(orus_p, orus_base);
            const cur_dist = self.projectPts(self.zp2.cur[point], cur_base);

            var new_dist: i32 = 0;
            if (org_dist != 0) {
                new_dist = if (old_range != 0) mulDiv(org_dist, cur_range, old_range) else org_dist;
            }
            self.moveDirect(self.zp2, point, new_dist -% cur_dist);
        }
    }

    fn insIup(self: *Interpreter, op: u8) void {
        if (self.pts.n_contours == 0 or self.pts.n_points == 0) return;
        const use_x = (op & 1) != 0;

        var contour: u32 = 0;
        var point: u32 = 0;
        while (contour < self.pts.n_contours) : (contour += 1) {
            var end_point: u32 = self.pts.contours[contour];
            const first_point = point;
            if (end_point >= self.pts.n_points) end_point = self.pts.n_points - 1;

            while (point <= end_point and !touchedFor(self.pts.tags[point], use_x)) point += 1;

            if (point <= end_point) {
                const first_touched = point;
                var cur_touched = point;
                point += 1;
                while (point <= end_point) : (point += 1) {
                    if (touchedFor(self.pts.tags[point], use_x)) {
                        iupInterpolate(&self.pts, use_x, cur_touched + 1, point - 1, cur_touched, point);
                        cur_touched = point;
                    }
                }
                if (cur_touched == first_touched) {
                    iupShift(&self.pts, use_x, first_point, end_point, cur_touched);
                } else {
                    iupInterpolate(&self.pts, use_x, cur_touched + 1, end_point, cur_touched, first_touched);
                    if (first_touched > 0)
                        iupInterpolate(&self.pts, use_x, first_point, first_touched - 1, cur_touched, first_touched);
                }
            }
            point = end_point + 1;
        }
    }

    // -- Point positioning (MDAP/MIAP/MDRP/MIRP) ------------------------

    fn insMdap(self: *Interpreter, op: u8, args: []i32) void {
        self.opcode = op;
        const point = boundU16(args[0]);
        if (point >= self.zp0.n_points) return;
        var distance: i32 = 0;
        if ((op & 1) != 0) {
            const cur_dist = self.project(self.zp0.cur[point].x, self.zp0.cur[point].y);
            distance = self.roundValue(cur_dist, 0) -% cur_dist;
        }
        self.moveDirect(self.zp0, point, distance);
        self.gs.rp0 = point;
        self.gs.rp1 = point;
    }

    fn insMiap(self: *Interpreter, op: u8, args: []i32) void {
        self.opcode = op;
        const point = boundU16(args[0]);
        const cvt_entry = boundIndex(args[1], @intCast(self.cvt.len + 1));
        if (point >= self.zp0.n_points or cvt_entry >= self.cvt.len) {
            self.gs.rp0 = point;
            self.gs.rp1 = point;
            return;
        }
        var distance = self.readCvt(cvt_entry);
        if (self.gs.gep0 == 0) {
            self.zp0.org[point].x = mulFix14(distance, self.gs.free_vector.x);
            self.zp0.org[point].y = mulFix14(distance, self.gs.free_vector.y);
            self.zp0.cur[point] = self.zp0.org[point];
        }
        const org_dist = self.project(self.zp0.cur[point].x, self.zp0.cur[point].y);
        if ((op & 1) != 0) {
            var delta = distance -% org_dist;
            if (delta < 0) delta = -%delta;
            if (delta > self.gs.control_value_cutin) distance = org_dist;
            distance = self.roundValue(distance, 0);
        }
        self.moveDirect(self.zp0, point, distance -% org_dist);
        self.gs.rp0 = point;
        self.gs.rp1 = point;
    }

    fn insMdrp(self: *Interpreter, op: u8, args: []i32) void {
        self.opcode = op;
        const point = boundU16(args[0]);
        if (point >= self.zp1.n_points or self.gs.rp0 >= self.zp0.n_points) {
            self.gs.rp1 = self.gs.rp0;
            self.gs.rp2 = point;
            if ((op & 16) != 0) self.gs.rp0 = point;
            return;
        }

        var org_dist: i32 = undefined;
        if (self.gs.gep0 == 0 or self.gs.gep1 == 0) {
            org_dist = self.dualProjectPts(self.zp1.org[point], self.zp0.org[self.gs.rp0]);
        } else {
            const vx = self.zp1.orus[point].x -% self.zp0.orus[self.gs.rp0].x;
            const vy = self.zp1.orus[point].y -% self.zp0.orus[self.gs.rp0].y;
            org_dist = mulFix(self.dualProject(vx, vy), self.scale);
        }

        if (self.gs.single_width_cutin > 0) {
            const lo = self.gs.single_width_value -% self.gs.single_width_cutin;
            const hi = self.gs.single_width_value +% self.gs.single_width_cutin;
            if (org_dist < hi and org_dist > lo)
                org_dist = if (org_dist >= 0) self.gs.single_width_value else -self.gs.single_width_value;
        }

        const compensation = self.gs.compensation[op & 3];
        var distance = if ((op & 4) != 0) self.roundValue(org_dist, compensation) else roundNone(org_dist, compensation);

        if ((op & 8) != 0) {
            const min_d = self.gs.minimum_distance;
            if (org_dist >= 0) {
                if (distance < min_d) distance = min_d;
            } else {
                if (distance > -min_d) distance = -min_d;
            }
        }

        const cur_dist = self.projectPts(self.zp1.cur[point], self.zp0.cur[self.gs.rp0]);
        self.moveDirect(self.zp1, point, distance -% cur_dist);

        self.gs.rp1 = self.gs.rp0;
        self.gs.rp2 = point;
        if ((op & 16) != 0) self.gs.rp0 = point;
    }

    fn insMirp(self: *Interpreter, op: u8, args: []i32) void {
        self.opcode = op;
        const point = boundU16(args[0]);
        const cvt_entry: i64 = @as(i64, args[1]) + 1;

        if (point >= self.zp1.n_points or cvt_entry < 0 or cvt_entry >= @as(i64, @intCast(self.cvt.len)) + 1 or self.gs.rp0 >= self.zp0.n_points) {
            self.gs.rp1 = self.gs.rp0;
            self.gs.rp2 = point;
            if ((op & 16) != 0) self.gs.rp0 = point;
            return;
        }

        var cvt_dist: i32 = if (cvt_entry == 0) 0 else self.readCvt(@intCast(cvt_entry - 1));

        var delta = cvt_dist -% self.gs.single_width_value;
        if (delta < 0) delta = -%delta;
        if (delta < self.gs.single_width_cutin)
            cvt_dist = if (cvt_dist >= 0) self.gs.single_width_value else -self.gs.single_width_value;

        if (self.gs.gep1 == 0) {
            self.zp1.org[point].x = self.zp0.org[self.gs.rp0].x +% mulFix14(cvt_dist, self.gs.free_vector.x);
            self.zp1.org[point].y = self.zp0.org[self.gs.rp0].y +% mulFix14(cvt_dist, self.gs.free_vector.y);
            self.zp1.cur[point] = self.zp1.org[point];
        }

        const org_dist = self.dualProjectPts(self.zp1.org[point], self.zp0.org[self.gs.rp0]);
        const cur_dist = self.projectPts(self.zp1.cur[point], self.zp0.cur[self.gs.rp0]);

        if (self.gs.auto_flip and ((org_dist ^ cvt_dist) < 0)) cvt_dist = -%cvt_dist;

        const compensation = self.gs.compensation[op & 3];
        var distance: i32 = undefined;
        if ((op & 4) != 0) {
            if (self.gs.gep0 == self.gs.gep1) {
                var d = cvt_dist -% org_dist;
                if (d < 0) d = -%d;
                if (d > self.gs.control_value_cutin) cvt_dist = org_dist;
            }
            distance = self.roundValue(cvt_dist, compensation);
        } else {
            distance = roundNone(cvt_dist, compensation);
        }

        if ((op & 8) != 0) {
            const min_d = self.gs.minimum_distance;
            if (org_dist >= 0) {
                if (distance < min_d) distance = min_d;
            } else {
                if (distance > -min_d) distance = -min_d;
            }
        }

        self.moveDirect(self.zp1, point, distance -% cur_dist);

        self.gs.rp1 = self.gs.rp0;
        self.gs.rp2 = point;
        if ((op & 16) != 0) self.gs.rp0 = point;
    }

    // -- Coordinate / storage / cvt access -------------------------------

    fn insGc(self: *Interpreter, op: u8, args: []i32) void {
        const l = boundU16(args[0]);
        if (l >= self.zp2.n_points) {
            args[0] = 0;
            return;
        }
        args[0] = if ((op & 1) != 0) self.dualProject(self.zp2.org[l].x, self.zp2.org[l].y) else self.project(self.zp2.cur[l].x, self.zp2.cur[l].y);
    }

    fn insScfs(self: *Interpreter, args: []i32) void {
        const l = boundU16(args[0]);
        if (l >= self.zp2.n_points) return;
        const k = self.project(self.zp2.cur[l].x, self.zp2.cur[l].y);
        self.moveDirect(self.zp2, l, args[1] -% k);
        if (self.gs.gep2 == 0) self.zp2.org[l] = self.zp2.cur[l];
    }

    fn insMd(self: *Interpreter, op: u8, args: []i32) void {
        const l = boundU16(args[0]);
        const k = boundU16(args[1]);
        if (l >= self.zp0.n_points or k >= self.zp1.n_points) {
            args[0] = 0;
            return;
        }
        if ((op & 1) != 0) {
            args[0] = self.projectPts(self.zp0.cur[l], self.zp1.cur[k]);
            return;
        }
        if (self.gs.gep0 == 0 or self.gs.gep1 == 0) {
            args[0] = self.dualProjectPts(self.zp0.org[l], self.zp1.org[k]);
        } else {
            const vx = self.zp0.orus[l].x -% self.zp1.orus[k].x;
            const vy = self.zp0.orus[l].y -% self.zp1.orus[k].y;
            args[0] = mulFix(self.dualProject(vx, vy), self.scale);
        }
    }

    fn insWs(self: *Interpreter, args: []i32) void {
        const i = boundIndex(args[0], @intCast(self.storage.len + 1));
        if (i >= self.storage.len) return;
        self.storage[i] = args[1];
    }

    fn insRs(self: *Interpreter, args: []i32) void {
        const i = boundIndex(args[0], @intCast(self.storage.len + 1));
        args[0] = if (i >= self.storage.len) 0 else self.storage[i];
    }

    fn roundOpcode(self: *Interpreter, op: u8, distance: i32) i32 {
        return self.roundValue(distance, self.gs.compensation[op & 3]);
    }

    // -- Delta exceptions --------------------------------------------

    /// DELTAP1/2/3 (0x5D/0x71/0x72): declared stack effect is just the
    /// pair count `nump`, but the `nump` (point, exception) pairs below it
    /// aren't covered by `popPushCount` either — self-manages `self.top`
    /// like `popLoop`-based opcodes (see `step`'s bypass list).
    fn insDeltaP(self: *Interpreter, op: u8) void {
        self.opcode = op;
        if (self.top < 1) return;
        self.top -= 1;
        var nump = self.stack[self.top];
        const avail: i32 = @intCast(self.top / 2);
        if (nump < 0 or nump > avail) nump = avail;
        const total: u32 = @intCast(nump * 2);
        const base = self.top - total;
        self.top = base;

        var p: i32 = self.cur_ppem - @as(i32, self.gs.delta_base);
        p -= switch (op) {
            0x71 => @as(i32, 16),
            0x72 => 32,
            else => 0,
        };
        if (p < 0 or p > 15) return;
        const pp = p << 4;
        const f: i32 = @as(i32, 1) << @intCast(6 - self.gs.delta_shift);

        var n: u32 = 0;
        while (n < total / 2) : (n += 1) {
            const b = self.stack[base + n * 2];
            const a = boundU16(self.stack[base + n * 2 + 1]);
            if (a >= self.zp0.n_points) continue;
            if ((b & 0xF0) == pp) {
                var bb = (b & 0xF) - 8;
                if (bb >= 0) bb += 1;
                bb *= f;
                self.moveDirect(self.zp0, a, bb);
            }
        }
    }

    fn insDeltaC(self: *Interpreter, op: u8) void {
        self.opcode = op;
        if (self.top < 1) return;
        self.top -= 1;
        var nump = self.stack[self.top];
        const avail: i32 = @intCast(self.top / 2);
        if (nump < 0 or nump > avail) nump = avail;
        const total: u32 = @intCast(nump * 2);
        const base = self.top - total;
        self.top = base;

        var p: i32 = self.cur_ppem - @as(i32, self.gs.delta_base);
        p -= switch (op) {
            0x74 => @as(i32, 16),
            0x75 => 32,
            else => 0,
        };
        if (p < 0 or p > 15) return;
        const pp = p << 4;
        const f: i32 = @as(i32, 1) << @intCast(6 - self.gs.delta_shift);

        var n: u32 = 0;
        while (n < total / 2) : (n += 1) {
            const b = self.stack[base + n * 2];
            const a_raw = self.stack[base + n * 2 + 1];
            if (a_raw < 0) continue;
            const a: u32 = @intCast(a_raw);
            if (a >= self.cvt.len) continue;
            if ((b & 0xF0) == pp) {
                var bb = (b & 0xF) - 8;
                if (bb >= 0) bb += 1;
                bb *= f;
                self.cvt[a] +%= bb;
            }
        }
    }

    fn insFlippt(self: *Interpreter) void {
        const pts = self.popLoop() orelse return;
        for (pts) |raw| {
            const point = boundU16(raw);
            if (point >= self.pts.n_points) continue;
            self.pts.tags[point] ^= on_curve;
        }
    }

    fn insFliprgon(self: *Interpreter, args: []i32, on: bool) void {
        const l = boundU16(args[0]);
        const k = boundU16(args[1]);
        if (k >= self.pts.n_points or l >= self.pts.n_points or l > k) return;
        var i = l;
        while (i <= k) : (i += 1) {
            if (on) self.pts.tags[i] |= on_curve else self.pts.tags[i] &= ~on_curve;
        }
    }

    fn insGetinfo(self: *Interpreter, selector: i32) i32 {
        _ = self;
        var k: i32 = 0;
        if ((selector & 1) != 0) k = 35;
        // Bit 5: bi-level hinting and grayscale rendering -> return bit 12.
        // This rasterizer only ever produces AA coverage bitmaps (no
        // monochrome/LCD hinting mode), so `exc->grayscale` is always true.
        if ((selector & 32) != 0) k |= 1 << 12;
        return k;
    }
};

fn boundU16(v: i32) u16 {
    if (v < 0 or v > std.math.maxInt(u16)) return std.math.maxInt(u16);
    return @intCast(v);
}

fn boundU32(v: i32) u32 {
    if (v < 0) return std.math.maxInt(u32);
    return @intCast(v);
}

fn boundIndex(v: i32, limit: u32) u32 {
    if (v < 0 or @as(u32, @intCast(v)) >= limit) return limit;
    return @intCast(v);
}

fn zoneSelector(v: i32) u1 {
    return if (v == 0) 0 else 1;
}

fn touchedFor(tag: u8, use_x: bool) bool {
    return (tag & (if (use_x) touch_x else touch_y)) != 0;
}

fn iupShift(zone: *Zone, use_x: bool, p1: u32, p2: u32, p: u32) void {
    if (p >= zone.n_points or p2 >= zone.n_points) return;
    const dx = componentDelta(zone, use_x, p);
    if (dx == 0) return;
    var i = p1;
    while (i < p) : (i += 1) addComponent(zone, use_x, i, dx);
    i = p + 1;
    while (i <= p2) : (i += 1) addComponent(zone, use_x, i, dx);
}

fn componentDelta(zone: *Zone, use_x: bool, p: u32) i32 {
    return getComponent(zone.cur[p], use_x) -% getComponent(zone.org[p], use_x);
}

fn getComponent(v: Point, use_x: bool) i32 {
    return if (use_x) v.x else v.y;
}

fn addComponent(zone: *Zone, use_x: bool, i: u32, delta: i32) void {
    if (use_x) zone.cur[i].x +%= delta else zone.cur[i].y +%= delta;
}

fn setComponent(zone: *Zone, use_x: bool, i: u32, value: i32) void {
    if (use_x) zone.cur[i].x = value else zone.cur[i].y = value;
}

fn iupInterpolate(zone: *Zone, use_x: bool, p1: u32, p2: u32, ref1_in: u32, ref2_in: u32) void {
    if (p1 > p2 or p2 >= zone.n_points) return;
    if (ref1_in >= zone.n_points or ref2_in >= zone.n_points) return;

    var ref1 = ref1_in;
    var ref2 = ref2_in;
    var orus1 = getComponent(zone.orus[ref1], use_x);
    var orus2 = getComponent(zone.orus[ref2], use_x);
    if (orus1 > orus2) {
        const tmp_o = orus1;
        orus1 = orus2;
        orus2 = tmp_o;
        const tmp_r = ref1;
        ref1 = ref2;
        ref2 = tmp_r;
    }

    const org1 = getComponent(zone.org[ref1], use_x);
    const org2 = getComponent(zone.org[ref2], use_x);
    const cur1 = getComponent(zone.cur[ref1], use_x);
    const cur2 = getComponent(zone.cur[ref2], use_x);
    const delta1 = cur1 -% org1;
    const delta2 = cur2 -% org2;

    if (cur1 == cur2 or orus1 == orus2) {
        var i = p1;
        while (i <= p2) : (i += 1) {
            var x = getComponent(zone.org[i], use_x);
            if (x <= org1) {
                x +%= delta1;
            } else if (x >= org2) {
                x +%= delta2;
            } else {
                x = cur1;
            }
            setComponent(zone, use_x, i, x);
        }
    } else {
        var scale: i32 = 0;
        var scale_valid = false;
        var i = p1;
        while (i <= p2) : (i += 1) {
            var x = getComponent(zone.org[i], use_x);
            if (x <= org1) {
                x +%= delta1;
            } else if (x >= org2) {
                x +%= delta2;
            } else {
                if (!scale_valid) {
                    scale_valid = true;
                    scale = mulDivNoRound(cur2 -% cur1, 0x10000, orus2 -% orus1);
                }
                x = cur1 +% mulFix(getComponent(zone.orus[i], use_x) -% orus1, scale);
            }
            setComponent(zone, use_x, i, x);
        }
    }
}
