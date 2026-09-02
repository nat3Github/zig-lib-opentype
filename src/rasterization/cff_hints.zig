// Adobe `cf2` CFF hinting engine — port of `vendor/freetype/src/psaux`
// (the modern, default `FT_CFF_HINTING_ADOBE` engine: blue-zone alignment,
// stem hint capture/mapping, and stem darkening with miter-join outline
// offsetting). Split to mirror `rasterization.zig`'s own split into
// `rasterization/{common,rasterizer,colr}.zig`: this file re-exports the
// public surface, each `cff_hint/*.zig` file ports one `psaux` source file.
//
// Not the classic `pshinter` engine (`FT_HINTING_FREETYPE`) — smaller but
// lower quality (no stem darkening); deliberately not the port target here.

//! CFF stem hints and the y-coordinate hint map — port of the non-
//! `GlyphPath` half of `vendor/freetype/src/psaux/pshints.c`. A `HintMap`
//! is a piecewise-linear function mapping character-space y-coordinates to
//! device space, built from captured/darkened `hstem`/`hstemhm` hints and
//! the current `hintmask`. Only y is hint-mapped this way (`cf2` never
//! grid-fits x — confirmed by `cf2_hintmap_build` only ever consulting
//! `hStemHintArray`, never `vStemHintArray`, despite taking both as
//! parameters); x gets uniform scale plus, if darkened, the outline-offset
//! widening in `glyphpath`.

const std = @import("std");

/// CFF spec: total hstem+vstem hints per glyph must fit in one hint mask,
/// max 96 bits (12 bytes) — hard cap, not merely what a well-formed font
/// happens to use (attacker-controlled charstrings are the thing this caps
/// against, per this repo's parsing-hardening convention).
pub const max_hints = 96;
pub const max_hint_edges = max_hints * 2;

pub const StemHint = struct {
    used: bool = false,
    /// Original character-space value.
    min: Fixed = 0,
    max: Fixed = 0,
    /// Device-space position after first use.
    min_ds: Fixed = 0,
    max_ds: Fixed = 0,
};

pub const StemHintArray = struct {
    items: [max_hints]StemHint = undefined,
    count: usize = 0,

    /// Silently drops hints past `max_hints` — same "defense in depth,
    /// should never trigger on a well-formed font" stance as FreeType's own
    /// `cf2_hintmask_setCounts` bitCount check.
    pub fn push(self: *StemHintArray, min: Fixed, max: Fixed) void {
        if (self.count >= max_hints) return;
        self.items[self.count] = .{ .min = min, .max = max };
        self.count += 1;
    }

    pub fn clear(self: *StemHintArray) void {
        self.count = 0;
    }
};

pub const HintMask = struct {
    is_valid: bool = false,
    is_new: bool = false,
    bit_count: usize = 0,
    byte_count: usize = 0,
    mask: [(max_hints + 7) / 8]u8 = [_]u8{0} ** ((max_hints + 7) / 8),

    fn setCounts(self: *HintMask, bit_count: usize) error{TooManyHints}!void {
        if (bit_count > max_hints) return error.TooManyHints;
        self.bit_count = bit_count;
        self.byte_count = (bit_count + 7) / 8;
        self.is_valid = true;
        self.is_new = true;
    }

    /// Consumes `byteCount` mask bytes already read by the caller (the
    /// charstring interpreter owns the byte cursor — this just interprets
    /// the bytes it hands over).
    pub fn setFromBytes(self: *HintMask, bit_count: usize, bytes: []const u8) error{TooManyHints}!void {
        try self.setCounts(bit_count);
        std.debug.assert(bytes.len >= self.byte_count);
        @memcpy(self.mask[0..self.byte_count], bytes[0..self.byte_count]);
    }

    pub fn setAll(self: *HintMask, bit_count: usize) void {
        self.setCounts(bit_count) catch return;
        if (self.byte_count == 0) return;
        // bits beyond `bitCount` in the final byte, e.g. bitCount%8==3 -> 0x1F
        const trailing_bits: u3 = @intCast((8 - (bit_count % 8)) % 8);
        const unused_mask: u8 = @intCast((@as(u16, 1) << trailing_bits) - 1);
        @memset(self.mask[0..self.byte_count], 0xFF);
        self.mask[self.byte_count - 1] &= ~unused_mask;
    }
};

const HintMove = struct { j: usize, move_up: Fixed };

pub const HintMap = struct {
    scale: Fixed = 0,
    hinted: bool = true,
    is_valid: bool = false,
    count: usize = 0,
    last_index: usize = 0,
    edge: [max_hint_edges]blues.Hint = undefined,
    hint_moves: [max_hints]HintMove = undefined,
    hint_moves_count: usize = 0,

    pub fn init(scale: Fixed, hinted: bool) HintMap {
        return .{ .scale = scale, .hinted = hinted };
    }

    /// Character-space y-coordinate -> device space, via the piecewise
    /// linear map (or uniform scale if there are no hints / hinting is off).
    pub fn map(self: *HintMap, cs_coord: Fixed) Fixed {
        if (self.count == 0 or !self.hinted) return mulFix(cs_coord, self.scale);

        var i = self.last_index;
        std.debug.assert(i < max_hint_edges);

        while (i < self.count - 1 and cs_coord >= self.edge[i + 1].cs_coord) i += 1;
        while (i > 0 and cs_coord < self.edge[i].cs_coord) i -= 1;
        self.last_index = i;

        if (i == 0 and cs_coord < self.edge[0].cs_coord) {
            return (mulFix(cs_coord -% self.edge[0].cs_coord, self.scale)) +% self.edge[0].ds_coord;
        }
        return (mulFix(cs_coord -% self.edge[i].cs_coord, self.edge[i].scale)) +% self.edge[i].ds_coord;
    }
};

/// Expands one `StemHint` (a min/max pair) into a bottom or top `Hint` edge
/// — port of `cf2_hint_init`. `-21`/`-20` unit widths are Type2's "ghost
/// hint" convention (single edge, not a stem pair); negative widths from
/// non-Adobe tools get their bottom/top swapped per the same permissive
/// handling FreeType/CoolType use.
pub fn stemHintToEdge(stem: StemHint, index: usize, darken_y: Fixed, hint_origin: Fixed, scale: Fixed, bottom: bool) blues.Hint {
    var hint: blues.Hint = .{};
    const width = stem.max -% stem.min;

    if (width == intToFixed(-21)) {
        if (bottom) {
            hint.cs_coord = stem.max;
            hint.flags = blues.flag_ghost_bottom;
        }
    } else if (width == intToFixed(-20)) {
        if (!bottom) {
            hint.cs_coord = stem.min;
            hint.flags = blues.flag_ghost_top;
        }
    } else if (width < 0) {
        if (bottom) {
            hint.cs_coord = stem.max;
            hint.flags = blues.flag_pair_bottom;
        } else {
            hint.cs_coord = stem.min;
            hint.flags = blues.flag_pair_top;
        }
    } else {
        if (bottom) {
            hint.cs_coord = stem.min;
            hint.flags = blues.flag_pair_bottom;
        } else {
            hint.cs_coord = stem.max;
            hint.flags = blues.flag_pair_top;
        }
    }

    if (hint.isTop()) hint.cs_coord +%= 2 *% darken_y;
    hint.cs_coord +%= hint_origin;
    hint.scale = scale;
    hint.index = index;

    if (hint.flags != 0 and stem.used) {
        hint.ds_coord = if (hint.isTop()) stem.max_ds else stem.min_ds;
        hint.lock();
    } else {
        hint.ds_coord = mulFix(hint.cs_coord, scale);
    }

    return hint;
}

/// Inserts one or a paired-edge hint into `hintmap.edge`, sorted by
/// `csCoord`, discarding hints that overlap an already-inserted one in
/// either character or device space — port of `cf2_hintmap_insertHint`.
fn insertHint(hintmap: *HintMap, initial_hint_map: ?*HintMap, bottom_hint_edge_in: blues.Hint, top_hint_edge_in: blues.Hint) void {
    var bottom_hint_edge = bottom_hint_edge_in;
    var top_hint_edge = top_hint_edge_in;

    std.debug.assert(bottom_hint_edge.isValid() or top_hint_edge.isValid());

    var is_pair = true;
    var first = &bottom_hint_edge;
    var second = &top_hint_edge;

    if (!bottom_hint_edge.isValid()) {
        first = &top_hint_edge;
        is_pair = false;
    } else if (!top_hint_edge.isValid()) {
        is_pair = false;
    }

    if (is_pair and top_hint_edge.cs_coord < bottom_hint_edge.cs_coord) return;

    var index_insert: usize = 0;
    while (index_insert < hintmap.count and hintmap.edge[index_insert].cs_coord < first.cs_coord) index_insert += 1;

    if (index_insert < hintmap.count) {
        if (hintmap.edge[index_insert].cs_coord == first.cs_coord) return;
        if (is_pair and hintmap.edge[index_insert].cs_coord <= second.cs_coord) return;
        if (hintmap.edge[index_insert].isPairTop()) return;
    }

    if (initial_hint_map) |initial| {
        if (initial.is_valid and !first.isLocked()) {
            if (is_pair) {
                const half_span = @divTrunc(second.cs_coord -% first.cs_coord, 2);
                const midpoint = initial.map(first.cs_coord +% half_span);
                const half_width = mulFix(half_span, hintmap.scale);
                first.ds_coord = midpoint -% half_width;
                second.ds_coord = midpoint +% half_width;
            } else {
                first.ds_coord = initial.map(first.cs_coord);
            }
        }
    }

    if (index_insert > 0 and first.ds_coord < hintmap.edge[index_insert - 1].ds_coord) return;
    if (index_insert < hintmap.count) {
        if (is_pair) {
            if (second.ds_coord > hintmap.edge[index_insert].ds_coord) return;
        } else if (first.ds_coord > hintmap.edge[index_insert].ds_coord) return;
    }

    const n: usize = if (is_pair) 2 else 1;
    if (hintmap.count + n > max_hint_edges) return;

    var i = hintmap.count;
    while (i > index_insert) {
        i -= 1;
        hintmap.edge[i + n] = hintmap.edge[i];
    }

    hintmap.edge[index_insert] = first.*;
    hintmap.count += 1;
    if (is_pair) {
        hintmap.edge[index_insert + 1] = second.*;
        hintmap.count += 1;
    }
}

/// First (bottom-up) + second (top-down) pass device-space overlap
/// resolution for unlocked edges — port of `cf2_hintmap_adjustHints`.
fn adjustHints(hintmap: *HintMap) void {
    hintmap.hint_moves_count = 0;

    var i: usize = 0;
    while (i < hintmap.count) {
        const is_pair = hintmap.edge[i].isPair();
        var move: Fixed = 0;

        const j: usize = if (is_pair) i + 1 else i;
        std.debug.assert(j < hintmap.count);

        const ds_coord_i = hintmap.edge[i].ds_coord;
        const ds_coord_j = hintmap.edge[j].ds_coord;

        if (!hintmap.edge[i].isLocked()) {
            const frac_down = fixedFraction(ds_coord_i);
            const frac_up = fixedFraction(ds_coord_j);

            const down_move_down: Fixed = 0 -% frac_down;
            const up_move_down: Fixed = 0 -% frac_up;
            const down_move_up: Fixed = if (frac_down == 0) 0 else one -% frac_down;
            const up_move_up: Fixed = if (frac_up == 0) 0 else one -% frac_up;

            const move_up = @min(down_move_up, up_move_up);
            const move_down = @max(down_move_down, up_move_down);

            const down_min_counter = blues.min_counter;
            const up_min_counter = blues.min_counter;
            var save_edge = false;

            if (j >= hintmap.count - 1 or hintmap.edge[j + 1].ds_coord >= ds_coord_j +% move_up +% up_min_counter) {
                if (i == 0 or hintmap.edge[i - 1].ds_coord <= ds_coord_i +% move_down -% down_min_counter) {
                    move = if (-%move_down < move_up) move_down else move_up;
                } else {
                    move = move_up;
                }
            } else {
                if (i == 0 or hintmap.edge[i - 1].ds_coord <= ds_coord_i +% move_down -% down_min_counter) {
                    move = move_down;
                    save_edge = move_up < -%move_down;
                } else {
                    move = 0;
                    save_edge = true;
                }
            }

            if (save_edge and j < hintmap.count - 1 and !hintmap.edge[j + 1].isLocked() and hintmap.hint_moves_count < hintmap.hint_moves.len) {
                hintmap.hint_moves[hintmap.hint_moves_count] = .{ .j = j, .move_up = move_up -% move };
                hintmap.hint_moves_count += 1;
            }

            hintmap.edge[i].ds_coord = ds_coord_i +% move;
            if (is_pair) hintmap.edge[j].ds_coord = ds_coord_j +% move;
        }

        if (i > 0 and hintmap.edge[i].cs_coord != hintmap.edge[i - 1].cs_coord) {
            hintmap.edge[i - 1].scale = divFix(hintmap.edge[i].ds_coord -% hintmap.edge[i - 1].ds_coord, hintmap.edge[i].cs_coord -% hintmap.edge[i - 1].cs_coord);
        }

        if (is_pair) {
            if (hintmap.edge[j].cs_coord != hintmap.edge[j - 1].cs_coord) {
                hintmap.edge[j - 1].scale = divFix(hintmap.edge[j].ds_coord -% hintmap.edge[j - 1].ds_coord, hintmap.edge[j].cs_coord -% hintmap.edge[j - 1].cs_coord);
            }
            i += 1;
        }
        i += 1;
    }

    var k = hintmap.hint_moves_count;
    while (k > 0) {
        k -= 1;
        const move = hintmap.hint_moves[k];
        const j = move.j;
        std.debug.assert(j < hintmap.count - 1);

        if (hintmap.edge[j + 1].ds_coord >= hintmap.edge[j].ds_coord +% move.move_up +% blues.min_counter) {
            hintmap.edge[j].ds_coord +%= move.move_up;
            if (hintmap.edge[j].isPair()) {
                std.debug.assert(j > 0);
                hintmap.edge[j - 1].ds_coord +%= move.move_up;
            }
        }
    }
}

pub const EmBoxHints = struct { bottom: blues.Hint, top: blues.Hint };

/// Builds (or rebuilds, at each hintmask substitution) the y-coordinate
/// hint map from captured/locked hstem hints — port of `cf2_hintmap_build`,
/// minus the one level of initial-map recursion (callers build the initial
/// map explicitly first, see ` interp`, since Zig has no default-arg
/// convenience for "call myself with different args" the way the C source
/// leans on).
pub fn build(
    hintmap: *HintMap,
    initial_hint_map: ?*HintMap,
    h_stems: *StemHintArray,
    mask: *HintMask,
    hint_origin: Fixed,
    is_initial_map: bool,
    xblues: *const blues.Blues,
    darken_y: Fixed,
    em_box_hints: ?EmBoxHints,
) void {
    if (!mask.is_valid) {
        mask.setAll(h_stems.count);
        if (!mask.is_valid) return;
    }

    hintmap.count = 0;
    hintmap.last_index = 0;

    var temp_mask = mask.*;
    const bit_count = h_stems.count;
    if (bit_count > mask.bit_count) return;

    if (em_box_hints) |eb| {
        const dummy: blues.Hint = .{};
        insertHint(hintmap, initial_hint_map, eb.bottom, dummy);
        insertHint(hintmap, initial_hint_map, dummy, eb.top);
    }

    var i: usize = 0;
    while (i < bit_count) : (i += 1) {
        const byte_idx = i / 8;
        const bit = @as(u8, 0x80) >> @intCast(i % 8);
        if (temp_mask.mask[byte_idx] & bit != 0) {
            var bottom = stemHintToEdge(h_stems.items[i], i, darken_y, hint_origin, hintmap.scale, true);
            var top = stemHintToEdge(h_stems.items[i], i, darken_y, hint_origin, hintmap.scale, false);
            const already_locked = bottom.isLocked() or top.isLocked();

            if (already_locked or blues.capture(xblues, &bottom, &top)) {
                insertHint(hintmap, initial_hint_map, bottom, top);
                temp_mask.mask[byte_idx] &= ~bit;
            }
        }
    }

    if (is_initial_map) {
        if (hintmap.count == 0 or hintmap.edge[0].cs_coord > 0 or hintmap.edge[hintmap.count - 1].cs_coord < 0) {
            var edge: blues.Hint = .{};
            edge.flags = blues.flag_ghost_bottom | blues.flag_locked | blues.flag_synthetic;
            edge.scale = hintmap.scale;
            const invalid: blues.Hint = .{};
            insertHint(hintmap, initial_hint_map, edge, invalid);
        }
    } else {
        i = 0;
        while (i < bit_count) : (i += 1) {
            const byte_idx = i / 8;
            const bit = @as(u8, 0x80) >> @intCast(i % 8);
            if (temp_mask.mask[byte_idx] & bit != 0) {
                const bottom = stemHintToEdge(h_stems.items[i], i, darken_y, hint_origin, hintmap.scale, true);
                const top = stemHintToEdge(h_stems.items[i], i, darken_y, hint_origin, hintmap.scale, false);
                insertHint(hintmap, initial_hint_map, bottom, top);
            }
        }
    }

    adjustHints(hintmap);

    if (!is_initial_map) {
        for (hintmap.edge[0..hintmap.count]) |e| {
            if (!e.isSynthetic()) {
                const stem = &h_stems.items[e.index];
                if (e.isTop()) stem.max_ds = e.ds_coord else stem.min_ds = e.ds_coord;
                stem.used = true;
            }
        }
    }

    hintmap.is_valid = true;
    mask.is_new = false;
}

test "single hstem pair produces a two-edge hint map with mid-stem scale" {
    var h_stems: StemHintArray = .{};
    h_stems.push(intToFixed(0), intToFixed(100));

    var mask: HintMask = .{};
    var xblues: blues.Blues = undefined;
    xblues.init(&xblues, .{
        .scale = one,
        .darken_y = 0,
        .stem_darkened = false,
        .language_group = 0,
        .blue_values = &.{},
        .other_blues = &.{},
        .family_blues = &.{},
        .family_other_blues = &.{},
        .blue_scale = doubleToFixed(0.039625),
        .blue_shift = intToFixed(7),
        .blue_fuzz = intToFixed(1),
    });

    var hintmap = HintMap.init(one, true);
    var initial = HintMap.init(one, true);
    build(&initial, null, &h_stems, &mask, 0, true, &xblues, 0, null);
    try std.testing.expect(initial.is_valid);

    mask.is_new = true;
    mask.is_valid = false;
    build(&hintmap, &initial, &h_stems, &mask, 0, false, &xblues, 0, null);

    try std.testing.expect(hintmap.is_valid);
    try std.testing.expect(hintmap.count >= 2);

    const mid = hintmap.map(intToFixed(50));
    try std.testing.expect(mid > 0);
}

test "unhinted map falls back to uniform scale" {
    var hintmap = HintMap.init(intToFixed(2), false);
    try std.testing.expectEqual(@as(Fixed, intToFixed(10)), hintmap.map(intToFixed(5)));
}
const blues = struct {
    //! CFF hinting blue zones — port of `vendor/freetype/src/psaux/psblues.c`.
    //! A `Blues` captures a font's `BlueValues`/`OtherBlues`/`FamilyBlues`/
    //! `FamilyOtherBlues` as top/bottom alignment zones in device space, used
    //! to snap stem hint edges to a common baseline/x-height/etc across a font.

    pub const flag_ghost_bottom: u32 = 0x1;
    pub const flag_ghost_top: u32 = 0x2;
    pub const flag_pair_bottom: u32 = 0x4;
    pub const flag_pair_top: u32 = 0x8;
    pub const flag_locked: u32 = 0x10;
    pub const flag_synthetic: u32 = 0x20;

    /// One hint edge — shared by `Blues.capture` and `HintMap` (in `hints.zig`),
    /// hence its own small self-contained type rather than living inside either.
    pub const Hint = struct {
        flags: u32 = 0,
        /// Index into the original stem-hint array (unused if synthetic).
        index: usize = 0,
        cs_coord: Fixed = 0,
        ds_coord: Fixed = 0,
        scale: Fixed = 0,

        pub fn isValid(self: Hint) bool {
            return self.flags != 0;
        }
        pub fn isPair(self: Hint) bool {
            return self.flags & (flag_pair_bottom | flag_pair_top) != 0;
        }
        pub fn isPairTop(self: Hint) bool {
            return self.flags & flag_pair_top != 0;
        }
        pub fn isTop(self: Hint) bool {
            return self.flags & (flag_pair_top | flag_ghost_top) != 0;
        }
        pub fn isBottom(self: Hint) bool {
            return self.flags & (flag_pair_bottom | flag_ghost_bottom) != 0;
        }
        pub fn isLocked(self: Hint) bool {
            return self.flags & flag_locked != 0;
        }
        pub fn isSynthetic(self: Hint) bool {
            return self.flags & flag_synthetic != 0;
        }
        pub fn lock(self: *Hint) void {
            self.flags |= flag_locked;
        }
    };

    pub const Zone = struct {
        cs_bottom_edge: Fixed = 0,
        cs_top_edge: Fixed = 0,
        /// May come from either this zone or a matching Family zone.
        cs_flat_edge: Fixed = 0,
        /// Top edge of bottom zone, or bottom edge of top zone (rounded).
        ds_flat_edge: Fixed = 0,
        bottom_zone: bool = false,
    };

    pub const max_blues = 7;
    pub const max_other_blues = 5;
    pub const max_zones = max_blues + max_other_blues;

    /// Synthetic em-box hint heuristic thresholds (1000-unit em, matches
    /// `CF2_ICF_Top`/`CF2_ICF_Bottom`).
    const icf_top: Fixed = intToFixed(880);
    const icf_bottom: Fixed = intToFixed(-120);

    /// Constant used for hint adjustment and synthetic em-box hint placement.
    pub const min_counter: Fixed = doubleToFixed(0.5);

    pub const Blues = struct {
        scale: Fixed = 0,
        count: usize = 0,
        suppress_overshoot: bool = false,
        do_em_box_hints: bool = false,

        blue_scale: Fixed = 0,
        blue_shift: Fixed = 0,
        blue_fuzz: Fixed = 0,

        boost: Fixed = 0,

        em_box_top_edge: Hint = .{},
        em_box_bottom_edge: Hint = .{},

        zone: [max_zones]Zone = undefined,
    };

    /// Inputs to `init` — everything `cf2_blues_init` reads from `CF2_Font`/
    /// its Private dict, isolated into a plain struct so `xblues.zig` doesn't
    /// need to know about charstring interpretation or font parsing.
    pub const Input = struct {
        /// `font->innerTransform.d` — pixels-per-font-unit, 16.16.
        scale: Fixed,
        /// `font->darkenY`, computed from stem darkening (see ` interp`).
        darken_y: Fixed,
        stem_darkened: bool,
        /// Private dict `LanguageGroup` (0 unless the font sets it).
        language_group: i32,
        /// Private dict delta-decoded zone arrays, already in `Fixed`.
        blue_values: []const Fixed,
        other_blues: []const Fixed,
        family_blues: []const Fixed,
        family_other_blues: []const Fixed,
        blue_scale: Fixed,
        blue_shift: Fixed,
        blue_fuzz: Fixed,
    };

    pub fn init(xblues: *Blues, in: Input) void {
        xblues.* = .{};
        xblues.scale = in.scale;
        xblues.blue_scale = in.blue_scale;
        xblues.blue_shift = in.blue_shift;
        xblues.blue_fuzz = in.blue_fuzz;

        var max_zone_height: Fixed = 0;

        const em_box_bottom = icf_bottom;
        const em_box_top = icf_top;

        if (in.language_group == 1 and
            (in.blue_values.len == 0 or
                (in.blue_values.len == 4 and
                    in.blue_values[0] < em_box_bottom and
                    in.blue_values[1] < em_box_bottom and
                    in.blue_values[2] > em_box_top and
                    in.blue_values[3] > em_box_top)))
        {
            xblues.em_box_bottom_edge.cs_coord = em_box_bottom -% epsilon;
            xblues.em_box_bottom_edge.ds_coord = fixedRound(mulFix(xblues.em_box_bottom_edge.cs_coord, xblues.scale)) -% min_counter;
            xblues.em_box_bottom_edge.scale = xblues.scale;
            xblues.em_box_bottom_edge.flags = flag_ghost_bottom | flag_locked | flag_synthetic;

            xblues.em_box_top_edge.cs_coord = em_box_top +% epsilon +% (2 *% in.darken_y);
            xblues.em_box_top_edge.ds_coord = fixedRound(mulFix(xblues.em_box_top_edge.cs_coord, xblues.scale)) +% min_counter;
            xblues.em_box_top_edge.scale = xblues.scale;
            xblues.em_box_top_edge.flags = flag_ghost_top | flag_locked | flag_synthetic;

            xblues.do_em_box_hints = true;
            return;
        }

        var i: usize = 0;
        while (i + 1 < in.blue_values.len) : (i += 2) {
            if (xblues.count >= max_zones) break;
            var zone: Zone = .{
                .cs_bottom_edge = in.blue_values[i],
                .cs_top_edge = in.blue_values[i + 1],
            };
            const zone_height = zone.cs_top_edge -% zone.cs_bottom_edge;
            if (zone_height < 0) continue;
            if (zone_height > max_zone_height) max_zone_height = zone_height;

            if (i != 0) {
                zone.cs_top_edge +%= 2 *% in.darken_y;
                zone.cs_bottom_edge +%= 2 *% in.darken_y;
            }

            if (i == 0) {
                zone.bottom_zone = true;
                zone.cs_flat_edge = zone.cs_top_edge;
            } else {
                zone.bottom_zone = false;
                zone.cs_flat_edge = zone.cs_bottom_edge;
            }

            xblues.zone[xblues.count] = zone;
            xblues.count += 1;
        }

        i = 0;
        while (i + 1 < in.other_blues.len) : (i += 2) {
            if (xblues.count >= max_zones) break;
            var zone: Zone = .{
                .cs_bottom_edge = in.other_blues[i],
                .cs_top_edge = in.other_blues[i + 1],
            };
            const zone_height = zone.cs_top_edge -% zone.cs_bottom_edge;
            if (zone_height < 0) continue;
            if (zone_height > max_zone_height) max_zone_height = zone_height;

            zone.bottom_zone = true;
            zone.cs_flat_edge = zone.cs_top_edge;

            xblues.zone[xblues.count] = zone;
            xblues.count += 1;
        }

        const cs_units_per_pixel = divFix(intToFixed(1), xblues.scale);

        for (xblues.zone[0..xblues.count]) |*zone| {
            const flat_edge = zone.cs_flat_edge;

            if (zone.bottom_zone) {
                var min_diff: Fixed = std.math.maxInt(i32);
                var j: usize = 0;
                while (j + 1 < in.family_other_blues.len) : (j += 2) {
                    const flat_family_edge = in.family_other_blues[j + 1];
                    const diff = fixedAbs(flat_edge -% flat_family_edge);
                    if (diff < min_diff and diff < cs_units_per_pixel) {
                        zone.cs_flat_edge = flat_family_edge;
                        min_diff = diff;
                        if (diff == 0) break;
                    }
                }
                if (in.family_blues.len >= 2) {
                    const flat_family_edge = in.family_blues[1];
                    const diff = fixedAbs(flat_edge -% flat_family_edge);
                    if (diff < min_diff and diff < cs_units_per_pixel) {
                        zone.cs_flat_edge = flat_family_edge;
                    }
                }
            } else {
                var min_diff: Fixed = std.math.maxInt(i32);
                var j: usize = 2;
                while (j < in.family_blues.len) : (j += 2) {
                    var flat_family_edge = in.family_blues[j];
                    flat_family_edge +%= 2 *% in.darken_y;
                    const diff = fixedAbs(flat_edge -% flat_family_edge);
                    if (diff < min_diff and diff < cs_units_per_pixel) {
                        zone.cs_flat_edge = flat_family_edge;
                        min_diff = diff;
                        if (diff == 0) break;
                    }
                }
            }
        }

        if (max_zone_height > 0) {
            const max_scale = divFix(intToFixed(1), max_zone_height);
            if (xblues.blue_scale > max_scale) xblues.blue_scale = max_scale;
        }

        if (xblues.scale < xblues.blue_scale) {
            xblues.suppress_overshoot = true;
            xblues.boost = doubleToFixed(0.6) -% mulDiv(doubleToFixed(0.6), xblues.scale, xblues.blue_scale);
            if (xblues.boost > 0x7FFF) xblues.boost = 0x7FFF;
        }

        if (in.stem_darkened) xblues.boost = 0;

        for (xblues.zone[0..xblues.count]) |*zone| {
            if (zone.bottom_zone) {
                zone.ds_flat_edge = fixedRound(mulFix(zone.cs_flat_edge, xblues.scale) -% xblues.boost);
            } else {
                zone.ds_flat_edge = fixedRound(mulFix(zone.cs_flat_edge, xblues.scale) +% xblues.boost);
            }
        }
    }

    /// Checks whether `bottomHintEdge`/`topHintEdge` are captured by a blue
    /// zone; if so, moves both edges (locking them) so one sits on the zone's
    /// flat edge (or at least the minimum overshoot / nearest pixel).
    pub fn capture(xblues: *const Blues, bottom_hint_edge: *Hint, top_hint_edge: *Hint) bool {
        const cs_fuzz = xblues.blue_fuzz;
        var ds_new: Fixed = 0;
        var ds_move: Fixed = 0;
        var captured = false;

        for (xblues.zone[0..xblues.count]) |zone| {
            if (zone.bottom_zone and bottom_hint_edge.isBottom()) {
                if (zone.cs_bottom_edge -% cs_fuzz <= bottom_hint_edge.cs_coord and
                    bottom_hint_edge.cs_coord <= zone.cs_top_edge +% cs_fuzz)
                {
                    if (xblues.suppress_overshoot) {
                        ds_new = zone.ds_flat_edge;
                    } else if (zone.cs_top_edge -% bottom_hint_edge.cs_coord >= xblues.blue_shift) {
                        ds_new = @min(fixedRound(bottom_hint_edge.ds_coord), zone.ds_flat_edge -% one);
                    } else {
                        ds_new = fixedRound(bottom_hint_edge.ds_coord);
                    }
                    ds_move = ds_new -% bottom_hint_edge.ds_coord;
                    captured = true;
                    break;
                }
            }

            if (!zone.bottom_zone and top_hint_edge.isTop()) {
                if (zone.cs_bottom_edge -% cs_fuzz <= top_hint_edge.cs_coord and
                    top_hint_edge.cs_coord <= zone.cs_top_edge +% cs_fuzz)
                {
                    if (xblues.suppress_overshoot) {
                        ds_new = zone.ds_flat_edge;
                    } else if (top_hint_edge.cs_coord -% zone.cs_bottom_edge >= xblues.blue_shift) {
                        ds_new = @max(fixedRound(top_hint_edge.ds_coord), zone.ds_flat_edge +% one);
                    } else {
                        ds_new = fixedRound(top_hint_edge.ds_coord);
                    }
                    ds_move = ds_new -% top_hint_edge.ds_coord;
                    captured = true;
                    break;
                }
            }
        }

        if (captured) {
            if (bottom_hint_edge.isValid()) {
                bottom_hint_edge.ds_coord +%= ds_move;
                bottom_hint_edge.lock();
            }
            if (top_hint_edge.isValid()) {
                top_hint_edge.ds_coord +%= ds_move;
                top_hint_edge.lock();
            }
        }

        return captured;
    }

    test "init produces a bottom zone from BlueValues and captures a matching hint" {
        var xblues: Blues = undefined;
        const bv = [_]Fixed{ intToFixed(-10), intToFixed(0) };
        init(&xblues, .{
            .scale = one, // 1 unit == 1 pixel, for easy math
            .darken_y = 0,
            .stem_darkened = false,
            .language_group = 0,
            .blue_values = &bv,
            .other_blues = &.{},
            .family_blues = &.{},
            .family_other_blues = &.{},
            .blue_scale = doubleToFixed(0.039625),
            .blue_shift = intToFixed(7),
            .blue_fuzz = intToFixed(1),
        });

        try std.testing.expectEqual(@as(usize, 1), xblues.count);
        try std.testing.expect(xblues.zone[0].bottom_zone);
        try std.testing.expectEqual(@as(Fixed, intToFixed(0)), xblues.zone[0].cs_flat_edge);

        var bottom: Hint = .{ .flags = flag_pair_bottom, .cs_coord = intToFixed(-5), .ds_coord = intToFixed(-5) };
        var top: Hint = .{};
        const got = capture(&xblues, &bottom, &top);
        try std.testing.expect(got);
        try std.testing.expect(bottom.isLocked());
    }

    test "capture rejects a hint outside every zone" {
        var xblues: Blues = undefined;
        const bv = [_]Fixed{ intToFixed(-10), intToFixed(0) };
        init(&xblues, .{
            .scale = one,
            .darken_y = 0,
            .stem_darkened = false,
            .language_group = 0,
            .blue_values = &bv,
            .other_blues = &.{},
            .family_blues = &.{},
            .family_other_blues = &.{},
            .blue_scale = doubleToFixed(0.039625),
            .blue_shift = intToFixed(7),
            .blue_fuzz = intToFixed(1),
        });

        var bottom: Hint = .{ .flags = flag_pair_bottom, .cs_coord = intToFixed(500), .ds_coord = intToFixed(500) };
        var top: Hint = .{};
        try std.testing.expect(!capture(&xblues, &bottom, &top));
    }
};

pub const glyphpath = struct {
    //! CFF hinted outline assembly — port of `CF2_GlyphPath` in
    //! `vendor/freetype/src/psaux/pshints.c`. Consumes character-space path
    //! ops from the charstring interpreter (` interp`), applies the
    //! y-coordinate hint map (`hints.zig`) plus, when stem darkening is on, an
    //! outward per-segment offset with miter-join geometry at corners (join
    //! computed by intersecting the offset lines; a connecting line is
    //! synthesized when no clean intersection exists) — this offsetting is
    //! the extra piece the classic `pshinter` engine doesn't have.
    //!
    //! `font->outerTransform` is hardcoded to identity in real FreeType too
    //! (`cf2_font_setup`'s own comment: "TODO: FreeType transform is simple
    //! scalar; for now, use identity for outer") — not a scope cut here,
    //! `hintPoint` below just skips multiplying/adding the no-op terms.

    pub const Point = struct { x: Fixed = 0, y: Fixed = 0 };

    pub const Segment = union(enum) {
        move_to: Point,
        line_to: Point,
        cube_to: struct { c1: Point, c2: Point, to: Point },
    };

    const PrevElemOp = enum { none, line_to, cube_to };

    /// Everything `cf2_glyphpath_init` copies from `CF2_Font` — isolated so
    /// this file doesn't need a full font/interpreter type to be testable.
    pub const Input = struct {
        scale_x: Fixed,
        scale_c: Fixed,
        scale_y: Fixed,
        fractional_translation: Point = .{},
        h_stems: *StemHintArray,
        hint_mask: *HintMask,
        hint_origin_y: Fixed,
        xblues: *const blues.Blues,
        darken: bool,
        darken_x: Fixed,
        darken_y: Fixed,
        reverse_winding: bool = false,
    };

    pub const GlyphPath = struct {
        allocator: std.mem.Allocator,
        segments: std.ArrayListUnmanaged(Segment) = .empty,
        winding_momentum: i32 = 0,

        hint_map: HintMap,
        first_hint_map: HintMap,
        initial_hint_map: HintMap,

        scale_x: Fixed,
        scale_c: Fixed,
        fractional_translation: Point,

        h_stems: *StemHintArray,
        hint_mask: *HintMask,
        hint_origin_y: Fixed,
        xblues: *const blues.Blues,

        darken: bool,
        x_offset: Fixed,
        y_offset: Fixed,
        miter_limit: Fixed,
        snap_threshold: Fixed,
        reverse_winding: bool,

        path_is_open: bool = false,
        path_is_closing: bool = false,
        move_is_pending: bool = true,
        elem_is_queued: bool = false,

        offset_start0: Point = .{},
        offset_start1: Point = .{},
        current_cs: Point = .{},
        current_ds: Point = .{},
        start: Point = .{},

        prev_elem_op: PrevElemOp = .none,
        prev_elem_p0: Point = .{},
        prev_elem_p1: Point = .{},
        prev_elem_p2: Point = .{},
        prev_elem_p3: Point = .{},

        pub fn init(allocator: std.mem.Allocator, in: Input) GlyphPath {
            return .{
                .allocator = allocator,
                .hint_map = HintMap.init(in.scale_y, true),
                .first_hint_map = HintMap.init(in.scale_y, true),
                .initial_hint_map = HintMap.init(in.scale_y, true),
                .scale_x = in.scale_x,
                .scale_c = in.scale_c,
                .fractional_translation = in.fractional_translation,
                .h_stems = in.h_stems,
                .hint_mask = in.hint_mask,
                .hint_origin_y = in.hint_origin_y,
                .xblues = in.xblues,
                .darken = in.darken,
                .x_offset = in.darken_x,
                .y_offset = in.darken_y,
                .miter_limit = 2 *% @max(fixedAbs(in.darken_x), fixedAbs(in.darken_y)),
                .snap_threshold = doubleToFixed(0.1),
                .reverse_winding = in.reverse_winding,
            };
        }

        pub fn deinit(self: *GlyphPath) void {
            self.segments.deinit(self.allocator);
        }

        fn emBoxHints(self: *const GlyphPath) ?EmBoxHints {
            if (!self.xblues.do_em_box_hints) return null;
            return .{ .bottom = self.xblues.em_box_bottom_edge, .top = self.xblues.em_box_top_edge };
        }

        /// Builds (or rebuilds) `hint_map` from the current `hint_mask` — port
        /// of the `cf2_hintmap_build` call sites in `moveTo`/`lineTo`/
        /// `curveTo`. Recurses one level to build `initial_hint_map` first (an
        /// all-hints-active pass) if it isn't valid yet, matching
        /// `cf2_hintmap_build`'s own one-level recursion.
        fn buildHintMap(self: *GlyphPath) void {
            if (!self.initial_hint_map.is_valid) {
                var temp_mask: HintMask = .{};
                build(&self.initial_hint_map, null, self.h_stems, &temp_mask, self.hint_origin_y, true, self.xblues, self.y_offset, self.emBoxHints());
            }
            build(&self.hint_map, &self.initial_hint_map, self.h_stems, self.hint_mask, self.hint_origin_y, false, self.xblues, self.y_offset, self.emBoxHints());
        }

        /// Character-space (x,y) -> device space, applying the y hint map and
        /// the (identity) outer transform + fractional translation.
        fn hintPoint(self: *GlyphPath, hint_map: *HintMap, x: Fixed, y: Fixed) Point {
            return .{
                .x = mulFix(self.scale_x, x) +% mulFix(self.scale_c, y) +% self.fractional_translation.x,
                .y = hint_map.map(y) +% self.fractional_translation.y,
            };
        }

        /// Intersects lines (u1,u2) and (v1,v2); false if parallel, or if the
        /// intersection is too far from the segment endpoints (`miterLimit`)
        /// — port of `cf2_glyphpath_computeIntersection`.
        fn computeIntersection(self: *const GlyphPath, pu1: Point, pu2: Point, pv1: Point, pv2: Point) ?Point {
            const scale = struct {
                fn f(x: Fixed) Fixed {
                    return (x +% 0x10) >> 5;
                }
            }.f;
            const perp = struct {
                fn f(ax: Fixed, ay: Fixed, bx: Fixed, by: Fixed) Fixed {
                    return mulFix(ax, by) -% mulFix(ay, bx);
                }
            }.f;

            const ux = scale(pu2.x -% pu1.x);
            const uy = scale(pu2.y -% pu1.y);
            const vx = scale(pv2.x -% pv1.x);
            const vy = scale(pv2.y -% pv1.y);
            const wx = scale(pv1.x -% pu1.x);
            const wy = scale(pv1.y -% pu1.y);

            const denominator = perp(ux, uy, vx, vy);
            if (denominator == 0) return null;

            const s = divFix(perp(wx, wy, vx, vy), denominator);

            var out: Point = .{
                .x = pu1.x +% mulFix(s, pu2.x -% pu1.x),
                .y = pu1.y +% mulFix(s, pu2.y -% pu1.y),
            };

            if (pu1.x == pu2.x and fixedAbs(out.x -% pu1.x) < self.snap_threshold) out.x = pu1.x;
            if (pu1.y == pu2.y and fixedAbs(out.y -% pu1.y) < self.snap_threshold) out.y = pu1.y;
            if (pv1.x == pv2.x and fixedAbs(out.x -% pv1.x) < self.snap_threshold) out.x = pv1.x;
            if (pv1.y == pv2.y and fixedAbs(out.y -% pv1.y) < self.snap_threshold) out.y = pv1.y;

            if (fixedAbs(out.x -% ((pu2.x +% pv1.x) >> 1)) > self.miter_limit) return null;
            if (fixedAbs(out.y -% ((pu2.y +% pv1.y) >> 1)) > self.miter_limit) return null;

            return out;
        }

        /// Emits the queued previous element (adjusting its end point to a
        /// miter intersection with the next element, or synthesizing a
        /// connecting line) — port of `cf2_glyphpath_pushPrevElem`.
        fn pushPrevElem(self: *GlyphPath, hint_map: *HintMap, next_p0: *Point, next_p1: Point, close: bool) std.mem.Allocator.Error!void {
            std.debug.assert(self.prev_elem_op == .line_to or self.prev_elem_op == .cube_to);

            const prev_p0: *Point = if (self.prev_elem_op == .line_to) &self.prev_elem_p0 else &self.prev_elem_p2;
            const prev_p1: *Point = if (self.prev_elem_op == .line_to) &self.prev_elem_p1 else &self.prev_elem_p3;

            var intersection: Point = .{};
            var use_intersection = false;

            if (prev_p1.x != next_p0.x or prev_p1.y != next_p0.y) {
                if (self.computeIntersection(prev_p0.*, prev_p1.*, next_p0.*, next_p1)) |ix| {
                    intersection = ix;
                    use_intersection = true;
                    prev_p1.* = intersection;
                }
            }

            const pt0 = self.current_ds;

            switch (self.prev_elem_op) {
                .line_to => {
                    const map_source = if (close) &self.first_hint_map else hint_map;
                    const pt1 = self.hintPoint(map_source, self.prev_elem_p1.x, self.prev_elem_p1.y);
                    if (pt0.x != pt1.x or pt0.y != pt1.y) {
                        try self.segments.append(self.allocator, .{ .line_to = pt1 });
                        self.current_ds = pt1;
                    }
                },
                .cube_to => {
                    const pt1 = self.hintPoint(hint_map, self.prev_elem_p1.x, self.prev_elem_p1.y);
                    const pt2 = self.hintPoint(hint_map, self.prev_elem_p2.x, self.prev_elem_p2.y);
                    const pt3 = self.hintPoint(hint_map, self.prev_elem_p3.x, self.prev_elem_p3.y);
                    try self.segments.append(self.allocator, .{ .cube_to = .{ .c1 = pt1, .c2 = pt2, .to = pt3 } });
                    self.current_ds = pt3;
                },
                .none => unreachable,
            }

            if (!use_intersection or close) {
                const map_source = if (close) &self.first_hint_map else hint_map;
                const pt1 = self.hintPoint(map_source, next_p0.x, next_p0.y);
                if (pt1.x != self.current_ds.x or pt1.y != self.current_ds.y) {
                    try self.segments.append(self.allocator, .{ .line_to = pt1 });
                    self.current_ds = pt1;
                }
            }

            if (use_intersection) next_p0.* = intersection;
        }

        fn pushMove(self: *GlyphPath, start: Point) std.mem.Allocator.Error!void {
            if (!self.hint_map.is_valid) {
                try self.moveTo(self.start.x, self.start.y);
            }
            const pt1 = self.hintPoint(&self.hint_map, start.x, start.y);
            try self.segments.append(self.allocator, .{ .move_to = pt1 });
            self.current_ds = pt1;
            self.offset_start0 = start;
        }

        /// Character-space outward offset for stem darkening, quantized into
        /// 8 direction buckets by a piecewise-linear approximation to angle
        /// (not true perpendicular-and-length) — port of
        /// `cf2_glyphpath_computeOffset`.
        fn computeOffset(self: *GlyphPath, x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Point {
            var dx = x2 -% x1;
            var dy = y2 -% y1;
            if (self.reverse_winding) {
                dx = -%dx;
                dy = -%dy;
            }

            if (!self.darken) return .{};

            self.winding_momentum +%= windingMomentum(x1, y1, x2, y2);

            const seventy: Fixed = doubleToFixed(0.7);
            const thirty: Fixed = doubleToFixed(1.0 - 0.7);
            const one_seventy: Fixed = doubleToFixed(1.0 + 0.7);

            if (dx >= 0) {
                if (dy >= 0) {
                    if (dx > 2 *% dy) return .{};
                    if (dy > 2 *% dx) return .{ .x = self.x_offset, .y = self.y_offset };
                    return .{ .x = mulFix(seventy, self.x_offset), .y = mulFix(thirty, self.y_offset) };
                } else {
                    if (dx > -%(2 *% dy)) return .{};
                    if (-%dy > 2 *% dx) return .{ .x = -%self.x_offset, .y = self.y_offset };
                    return .{ .x = mulFix(-%seventy, self.x_offset), .y = mulFix(thirty, self.y_offset) };
                }
            } else {
                if (dy >= 0) {
                    if (-%dx > 2 *% dy) return .{ .x = 0, .y = 2 *% self.y_offset };
                    if (dy > -%(2 *% dx)) return .{ .x = self.x_offset, .y = self.y_offset };
                    return .{ .x = mulFix(seventy, self.x_offset), .y = mulFix(one_seventy, self.y_offset) };
                } else {
                    if (-%dx > -%(2 *% dy)) return .{ .x = 0, .y = 2 *% self.y_offset };
                    if (-%dy > -%(2 *% dx)) return .{ .x = -%self.x_offset, .y = self.y_offset };
                    return .{ .x = mulFix(-%seventy, self.x_offset), .y = mulFix(one_seventy, self.y_offset) };
                }
            }
        }

        pub fn moveTo(self: *GlyphPath, x: Fixed, y: Fixed) std.mem.Allocator.Error!void {
            try self.closeOpenPath();

            self.current_cs = .{ .x = x, .y = y };
            self.start = self.current_cs;
            self.move_is_pending = true;

            if (!self.hint_map.is_valid or self.hint_mask.is_new) self.buildHintMap();
            self.first_hint_map = self.hint_map;
        }

        pub fn lineTo(self: *GlyphPath, x: Fixed, y: Fixed) std.mem.Allocator.Error!void {
            const new_hint_map = self.hint_mask.is_new and !self.path_is_closing;

            if (self.current_cs.x == x and self.current_cs.y == y and !new_hint_map) return;

            const offset = self.computeOffset(self.current_cs.x, self.current_cs.y, x, y);
            const p0: Point = .{ .x = self.current_cs.x +% offset.x, .y = self.current_cs.y +% offset.y };
            const p1: Point = .{ .x = x +% offset.x, .y = y +% offset.y };

            if (self.move_is_pending) {
                try self.pushMove(p0);
                self.move_is_pending = false;
                self.path_is_open = true;
                self.offset_start1 = p1;
            }

            if (self.elem_is_queued) {
                var next_p0 = p0;
                try self.pushPrevElem(&self.hint_map, &next_p0, p1, false);
            }

            self.elem_is_queued = true;
            self.prev_elem_op = .line_to;
            self.prev_elem_p0 = p0;
            self.prev_elem_p1 = p1;

            if (new_hint_map) self.buildHintMap();

            self.current_cs = .{ .x = x, .y = y };
        }

        pub fn curveTo(self: *GlyphPath, x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed, x3: Fixed, y3: Fixed) std.mem.Allocator.Error!void {
            const offset1 = self.computeOffset(self.current_cs.x, self.current_cs.y, x1, y1);
            const offset3 = self.computeOffset(x2, y2, x3, y3);

            self.winding_momentum +%= windingMomentum(x1, y1, x2, y2);

            const p0: Point = .{ .x = self.current_cs.x +% offset1.x, .y = self.current_cs.y +% offset1.y };
            const p1: Point = .{ .x = x1 +% offset1.x, .y = y1 +% offset1.y };
            const p2: Point = .{ .x = x2 +% offset3.x, .y = y2 +% offset3.y };
            const p3: Point = .{ .x = x3 +% offset3.x, .y = y3 +% offset3.y };

            if (self.move_is_pending) {
                try self.pushMove(p0);
                self.move_is_pending = false;
                self.path_is_open = true;
                self.offset_start1 = p1;
            }

            if (self.elem_is_queued) {
                var next_p0 = p0;
                try self.pushPrevElem(&self.hint_map, &next_p0, p1, false);
            }

            self.elem_is_queued = true;
            self.prev_elem_op = .cube_to;
            self.prev_elem_p0 = p0;
            self.prev_elem_p1 = p1;
            self.prev_elem_p2 = p2;
            self.prev_elem_p3 = p3;

            if (self.hint_mask.is_new) self.buildHintMap();

            self.current_cs = .{ .x = x3, .y = y3 };
        }

        pub fn closeOpenPath(self: *GlyphPath) std.mem.Allocator.Error!void {
            if (!self.path_is_open) return;

            self.path_is_closing = true;
            try self.lineTo(self.start.x, self.start.y);

            if (self.elem_is_queued) {
                var next_p0 = self.offset_start0;
                try self.pushPrevElem(&self.hint_map, &next_p0, self.offset_start1, true);
            }

            self.move_is_pending = true;
            self.path_is_open = false;
            self.path_is_closing = false;
            self.elem_is_queued = false;
        }
    };

    fn windingMomentum(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) i32 {
        return (x1 >> 16) *% ((y2 -% y1) >> 16) -% (y1 >> 16) *% ((x2 -% x1) >> 16);
    }

    test "unhinted, undarkened square round-trips through hint map with uniform scale" {
        var h_stems: StemHintArray = .{};
        var mask: HintMask = .{};
        var xblues: blues.Blues = undefined;
        blues.init(&xblues, .{
            .scale = one,
            .darken_y = 0,
            .stem_darkened = false,
            .language_group = 0,
            .blue_values = &.{},
            .other_blues = &.{},
            .family_blues = &.{},
            .family_other_blues = &.{},
            .blue_scale = doubleToFixed(0.039625),
            .blue_shift = intToFixed(7),
            .blue_fuzz = intToFixed(1),
        });

        var gp = GlyphPath.init(std.testing.allocator, .{
            .scale_x = one,
            .scale_c = 0,
            .scale_y = one,
            .h_stems = &h_stems,
            .hint_mask = &mask,
            .hint_origin_y = 0,
            .xblues = &xblues,
            .darken = false,
            .darken_x = 0,
            .darken_y = 0,
        });
        defer gp.deinit();

        try gp.moveTo(intToFixed(0), intToFixed(0));
        try gp.lineTo(intToFixed(10), intToFixed(0));
        try gp.lineTo(intToFixed(10), intToFixed(10));
        try gp.lineTo(intToFixed(0), intToFixed(10));
        try gp.closeOpenPath();

        try std.testing.expect(gp.segments.items.len >= 4);
        try std.testing.expectEqual(Segment{ .move_to = .{ .x = 0, .y = 0 } }, gp.segments.items[0]);
    }

    test "darkened square produces a wider outline (nonzero offset)" {
        var h_stems: StemHintArray = .{};
        var mask: HintMask = .{};
        var xblues: blues.Blues = undefined;
        blues.init(&xblues, .{
            .scale = one,
            .darken_y = 0,
            .stem_darkened = false,
            .language_group = 0,
            .blue_values = &.{},
            .other_blues = &.{},
            .family_blues = &.{},
            .family_other_blues = &.{},
            .blue_scale = doubleToFixed(0.039625),
            .blue_shift = intToFixed(7),
            .blue_fuzz = intToFixed(1),
        });

        var gp = GlyphPath.init(std.testing.allocator, .{
            .scale_x = one,
            .scale_c = 0,
            .scale_y = one,
            .h_stems = &h_stems,
            .hint_mask = &mask,
            .hint_origin_y = 0,
            .xblues = &xblues,
            .darken = true,
            .darken_x = doubleToFixed(0.4),
            .darken_y = doubleToFixed(0.4),
        });
        defer gp.deinit();

        try gp.moveTo(intToFixed(0), intToFixed(0));
        try gp.lineTo(intToFixed(100), intToFixed(0));
        try gp.lineTo(intToFixed(100), intToFixed(100));
        try gp.lineTo(intToFixed(0), intToFixed(100));
        try gp.closeOpenPath();

        // The +y segment (100,0)->(100,100) is dominant-axis +y, so
        // computeOffset gives it the full (xOffset, yOffset) push per its own
        // "dy > 2*dx" branch -> the top-right corner should land right of x=100.
        var saw_pushed_right = false;
        for (gp.segments.items) |seg| {
            if (seg == .line_to and seg.line_to.x > intToFixed(100)) saw_pushed_right = true;
        }
        try std.testing.expect(saw_pushed_right);
        try std.testing.expect(gp.winding_momentum != 0);
    }
};

pub const interp = struct {
    //! Hinted Type2 charstring interpreter — port of
    //! `cf2_interpT2CharString` (`vendor/freetype/src/psaux/psintrp.c`; this
    //! FreeType checkout renamed the classic `cf2*.c` psaux files to `ps*.c`,
    //! e.g. `cf2intrp.c` -> `psintrp.c`, `cf2font.c` -> `psfont.c`) plus the
    //! per-glyph darkening setup from `cf2_font_setup`/`cf2_computeDarkening`
    //! (`psfont.c`). Drives `hints.zig` (stem hint capture + hintmask) and
    //! `glyphpath` (hinted path assembly).
    //!
    //! CFF-only: the reference file is a merged Type1+Type2 interpreter (guarded
    //! throughout by `font->isT1`) and also handles CFF2 (`vsindex`/`blend`,
    //! `font->isCFF2`) — this port drops both, since this codebase's CFF2
    //! outline path is unhinted (see `parsing.zig`'s `CharstringInterp`, which
    //! already covers CFF2's `blend`). Also not ported, all deliberate,
    //! matching this codebase's established scope-cut style elsewhere:
    //! - Deprecated 4/5-arg `endchar` implied `seac` (accent composition):
    //!   needs StandardEncoding + CFF charset glyph-name lookup this codebase
    //!   doesn't have; extra operands are just dropped, no accent glyphs drawn.
    //! - Arithmetic/storage escape operators (`and`/`or`/`not`/`abs`/`add`/
    //!   `sub`/`div`/`neg`/`eq`/`drop`/`put`/`get`/`ifelse`/`random`/`mul`/
    //!   `sqrt`/`dup`/`exch`/`index`/`roll`) — same cut `parsing.zig`'s own
    //!   (unhinted) CFF interpreter already makes; only `hflex`/`flex`/
    //!   `hflex1`/`flex1` are ported from the escape (`12 xx`) space.
    //! - `Options.hinted = false` (fully unhinted CFF rendering through this
    //!   engine) isn't wired through: `glyphpath`'s `GlyphPath.init` always
    //!   constructs its `HintMap`s with `hinted = true` hardcoded. Not fixed
    //!   here since that's `glyphpath`'s own committed/tested surface.

    const parsing = @import("../parsing.zig");
    const GlyphPath = glyphpath.GlyphPath;
    const Segment = glyphpath.Segment;
    const Point = glyphpath.Point;

    pub const InterpError = error{
        UnexpectedEndOfData,
        InvalidCharstring,
        RecursionLimitExceeded,
        InstructionLimitExceeded,
        TooManyHints,
    } || parsing.Font.ParseError || std.mem.Allocator.Error;

    /// `CF2_MAX_SUBR` (16) plus one for the top-level charstring itself.
    const max_call_depth: u32 = 17;
    /// Bounded, unlike `psintrp.c`'s 20,000,000 (chosen there to be
    /// effectively unlimited for legitimate fonts) — this is still far above
    /// any real charstring's instruction count, just an explicit hard cap per
    /// this repo's CLAUDE.md guidance on bounding attacker-controlled loops.
    const default_instruction_budget: u32 = 100_000;

    /// Default `CFF_CONFIG_OPTION_DARKENING_PARAMETER_{X,Y}{1..4}` control
    /// points (`ftoption.h`) for the 5-part darkening curve — this port doesn't
    /// expose a way to override them (no caller has needed to yet).
    const darken_params = [8]i32{ 500, 400, 1000, 275, 1667, 275, 2333, 0 };

    pub const Options = struct {
        /// `font->innerTransform.{a,d}` — pixels-per-font-unit, 16.16.
        scale_x: Fixed,
        scale_y: Fixed,
        /// Shear/rotation cross term; identity (0) for an unrotated glyph.
        scale_c: Fixed = 0,
        /// `font->ppem`, already clamped/scaled by the caller; this port applies
        /// the "minimum 4 pixel" floor from `cf2_font_setup` on top.
        ppem: Fixed,
        fractional_translation: Point = .{},
        darken: bool = true,
        /// Character-space synthetic emboldening amounts; 0 for normal text.
        bolden_x: Fixed = 0,
        bolden_y: Fixed = 0,
    };

    pub const RenderResult = struct {
        /// Caller-owned (`allocator.free`), device-space (already hinted +
        /// scaled) path segments.
        segments: []Segment,
        /// Character-space (unscaled) advance width.
        width: Fixed,
    };

    /// Character-space stem width in 1000-unit space at unit `emRatio`,
    /// darkening curve in thousandths of a pixel -> `Fixed` character-space
    /// darkening amount — port of `cf2_computeDarkening` (`psfont.c`).
    fn computeDarkening(em_ratio: Fixed, ppem: Fixed, stem_width: Fixed, bolden_amount: Fixed, stem_darkened: bool) Fixed {
        if (bolden_amount == 0 and !stem_darkened) return 0;
        if (em_ratio < doubleToFixed(0.01)) return 0;

        var darken_amount: Fixed = 0;
        if (stem_darkened) {
            const p = darken_params;
            const stem_width_per_1000 = mulFix(stem_width +% bolden_amount, em_ratio);

            // NOTE: exact i64 product + clamp stands in for FT_MSB's
            // approximate log2 overflow guard -- same effect (clamp before an
            // i32 truncation could wrap), simpler to verify correct outright.
            const prod: i64 = @as(i64, stem_width_per_1000) * @as(i64, ppem);
            const rounded: i64 = if (prod >= 0) @divFloor(prod + 0x8000, 0x10000) else -(@divFloor(-prod + 0x8000, 0x10000));
            const x4_fixed: i64 = intToFixed(p[6]);
            const scaled_stem: Fixed = if (rounded > x4_fixed)
                intToFixed(p[6])
            else if (rounded < -x4_fixed)
                -%intToFixed(p[6])
            else
                @intCast(rounded);

            if (scaled_stem < intToFixed(p[0])) {
                darken_amount = divFix(intToFixed(p[1]), ppem);
            } else if (scaled_stem < intToFixed(p[2])) {
                const x = stem_width_per_1000 -% divFix(intToFixed(p[0]), ppem);
                darken_amount = mulDiv(x, p[3] - p[1], p[2] - p[0]) +% divFix(intToFixed(p[1]), ppem);
            } else if (scaled_stem < intToFixed(p[4])) {
                const x = stem_width_per_1000 -% divFix(intToFixed(p[2]), ppem);
                darken_amount = mulDiv(x, p[5] - p[3], p[4] - p[2]) +% divFix(intToFixed(p[3]), ppem);
            } else if (scaled_stem < intToFixed(p[6])) {
                const x = stem_width_per_1000 -% divFix(intToFixed(p[4]), ppem);
                darken_amount = mulDiv(x, p[7] - p[5], p[6] - p[4]) +% divFix(intToFixed(p[5]), ppem);
            } else {
                darken_amount = divFix(intToFixed(p[7]), ppem);
            }

            darken_amount = divFix(darken_amount, 2 *% em_ratio);
        }

        darken_amount +%= @divTrunc(bolden_amount, 2);
        return darken_amount;
    }

    fn fixedArrayFromDoubles(out: []Fixed, values: []const f64) []const Fixed {
        for (values, 0..) |v, i| out[i] = doubleToFixed(v);
        return out[0..values.len];
    }

    /// Minimal big-endian charstring byte cursor — deliberately not
    /// `parsing.zig`'s own `Cursor` (private to that file); this repo's
    /// convention elsewhere (`hinting.zig`, `rasterization/*.zig`) is likewise
    /// each component owns its own small cursor rather than sharing one.
    const Reader = struct {
        data: []const u8,
        pos: usize = 0,

        fn atEnd(self: Reader) bool {
            return self.pos >= self.data.len;
        }

        fn readU8(self: *Reader) InterpError!u8 {
            if (self.pos >= self.data.len) return error.UnexpectedEndOfData;
            const b = self.data[self.pos];
            self.pos += 1;
            return b;
        }

        fn readI16(self: *Reader) InterpError!i16 {
            if (self.pos + 2 > self.data.len) return error.UnexpectedEndOfData;
            const v = std.mem.readInt(i16, self.data[self.pos..][0..2], .big);
            self.pos += 2;
            return v;
        }

        fn readI32(self: *Reader) InterpError!i32 {
            if (self.pos + 4 > self.data.len) return error.UnexpectedEndOfData;
            const v = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
            self.pos += 4;
            return v;
        }

        fn readBytes(self: *Reader, n: usize) InterpError![]const u8 {
            if (self.pos + n > self.data.len) return error.UnexpectedEndOfData;
            const s = self.data[self.pos .. self.pos + n];
            self.pos += n;
            return s;
        }
    };

    /// Type2 number encoding (`Charstring Number Encoding`, CFF spec Ch. 3),
    /// yielding a `Fixed` directly instead of the `f64` `parsing.zig`'s own
    /// decoder uses — every value here ends up in `cf2`'s 16.16 pipeline.
    fn parseNumber(r: *Reader, b0: u8) InterpError!Fixed {
        if (b0 == 28) return intToFixed(try r.readI16());
        if (b0 == 255) return try r.readI32(); // already a 16.16 fixed value
        if (b0 <= 246) return intToFixed(@as(i32, b0) - 139);
        if (b0 <= 250) {
            const b1 = try r.readU8();
            return intToFixed((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108);
        }
        const b1 = try r.readU8();
        return intToFixed(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
    }

    const Interp = struct {
        data: parsing.Table.cff.CharstringAndSubrs,
        nominal_width_x: Fixed,
        scale_y: Fixed,
        xblues: *const blues.Blues,
        darken_y: Fixed,

        stack: [48]Fixed = undefined,
        sp: usize = 0,
        x: Fixed = 0,
        y: Fixed = 0,
        have_width: bool = false,
        width: Fixed,
        depth: u32 = 0,
        instruction_budget: u32 = default_instruction_budget,

        h_stems: StemHintArray = .{},
        v_stems: StemHintArray = .{},
        hint_mask: HintMask = .{},

        glyph_path: *GlyphPath,

        fn clearStack(self: *Interp) void {
            self.sp = 0;
        }

        fn resetForRerun(self: *Interp, glyph_path: *GlyphPath, default_width_x: Fixed) void {
            self.h_stems.clear();
            self.v_stems.clear();
            self.hint_mask = .{};
            self.sp = 0;
            self.x = 0;
            self.y = 0;
            self.have_width = false;
            self.width = default_width_x;
            self.depth = 0;
            self.instruction_budget = default_instruction_budget;
            self.glyph_path = glyph_path;
        }

        /// Shared hstem/vstem/hstemhm/vstemhm/implied-vstem body — port of
        /// `cf2_doStems`. `hintOffset` (Type1 left-sidebearing correction) is
        /// always 0 here since this port is CFF-only.
        fn doStems(self: *Interp, arr: *StemHintArray) void {
            const count = self.sp;
            const has_width_arg = (count % 2) == 1;
            if (has_width_arg and !self.have_width) self.width = self.stack[0] +% self.nominal_width_x;
            self.have_width = true;

            var i: usize = if (has_width_arg) 1 else 0;
            var position: Fixed = 0;
            while (i + 1 < count) : (i += 2) {
                position +%= self.stack[i];
                const min = position;
                position +%= self.stack[i + 1];
                const max = position;
                arr.push(min, max);
            }
            self.clearStack();
        }

        fn curveToRel(self: *Interp, i: usize) InterpError!void {
            const x1 = self.x +% self.stack[i];
            const y1 = self.y +% self.stack[i + 1];
            const x2 = x1 +% self.stack[i + 2];
            const y2 = y1 +% self.stack[i + 3];
            const x3 = x2 +% self.stack[i + 4];
            const y3 = y2 +% self.stack[i + 5];
            try self.glyph_path.curveTo(x1, y1, x2, y2, x3, y3);
            self.x = x3;
            self.y = y3;
        }

        fn hflex(self: *Interp) InterpError!void {
            if (self.sp < 7) return;
            const s = self.stack;
            const x0 = self.x;
            const y0 = self.y;
            const x1 = x0 +% s[0];
            const y1 = y0;
            const x2 = x1 +% s[1];
            const y2 = y1 +% s[2];
            const x3 = x2 +% s[3];
            const y3 = y2;
            try self.glyph_path.curveTo(x1, y1, x2, y2, x3, y3);
            const x4 = x3 +% s[4];
            const y4 = y3;
            const x5 = x4 +% s[5];
            const y5 = y0;
            const x6 = x5 +% s[6];
            const y6 = y0;
            try self.glyph_path.curveTo(x4, y4, x5, y5, x6, y6);
            self.x = x6;
            self.y = y6;
        }

        fn flex(self: *Interp) InterpError!void {
            if (self.sp < 12) return;
            try self.curveToRel(0);
            try self.curveToRel(6);
        }

        fn hflex1(self: *Interp) InterpError!void {
            if (self.sp < 9) return;
            const s = self.stack;
            const y0 = self.y;
            const x1 = self.x +% s[0];
            const y1 = self.y +% s[1];
            const x2 = x1 +% s[2];
            const y2 = y1 +% s[3];
            const x3 = x2 +% s[4];
            const y3 = y2;
            try self.glyph_path.curveTo(x1, y1, x2, y2, x3, y3);
            const x4 = x3 +% s[5];
            const y4 = y3;
            const x5 = x4 +% s[6];
            const y5 = y4 +% s[7];
            const x6 = x5 +% s[8];
            const y6 = y0;
            try self.glyph_path.curveTo(x4, y4, x5, y5, x6, y6);
            self.x = x6;
            self.y = y6;
        }

        fn flex1(self: *Interp) InterpError!void {
            if (self.sp < 11) return;
            const s = self.stack;
            const x0 = self.x;
            const y0 = self.y;
            const x1 = x0 +% s[0];
            const y1 = y0 +% s[1];
            const x2 = x1 +% s[2];
            const y2 = y1 +% s[3];
            const x3 = x2 +% s[4];
            const y3 = y2 +% s[5];
            try self.glyph_path.curveTo(x1, y1, x2, y2, x3, y3);
            const x4 = x3 +% s[6];
            const y4 = y3 +% s[7];
            const x5 = x4 +% s[8];
            const y5 = y4 +% s[9];
            const dx_sum = (x5 -% x0);
            const dy_sum = (y5 -% y0);
            var x6: Fixed = undefined;
            var y6: Fixed = undefined;
            if (fixedAbs(dx_sum) > fixedAbs(dy_sum)) {
                x6 = x5 +% s[10];
                y6 = y0;
            } else {
                x6 = x0;
                y6 = y5 +% s[10];
            }
            try self.glyph_path.curveTo(x4, y4, x5, y5, x6, y6);
            self.x = x6;
            self.y = y6;
        }

        /// Port of `cf2_interpT2CharString`'s main dispatch loop, recursing
        /// into `run` again for `callsubr`/`callgsubr` (matches this
        /// codebase's other CFF interpreter, `parsing.zig`'s `CharstringInterp`
        /// — recursion instead of `psintrp.c`'s own explicit subr-buffer stack)
        /// bounded by `max_call_depth` and `instruction_budget`.
        fn run(self: *Interp, charstring: []const u8) InterpError!void {
            self.depth += 1;
            defer self.depth -= 1;
            if (self.depth > max_call_depth) return error.RecursionLimitExceeded;

            var r: Reader = .{ .data = charstring };
            while (!r.atEnd()) {
                if (self.instruction_budget == 0) return error.InstructionLimitExceeded;
                self.instruction_budget -= 1;

                const b0 = try r.readU8();
                if (b0 >= 32 or b0 == 28) {
                    const v = try parseNumber(&r, b0);
                    if (self.sp < self.stack.len) {
                        self.stack[self.sp] = v;
                        self.sp += 1;
                    }
                    continue;
                }

                switch (b0) {
                    1, 18 => { // hstem, hstemhm
                        if (!self.hint_mask.is_valid) self.doStems(&self.h_stems) else self.clearStack();
                    },
                    3, 23 => { // vstem, vstemhm
                        if (!self.hint_mask.is_valid) self.doStems(&self.v_stems) else self.clearStack();
                    },
                    19, 20 => { // hintmask, cntrmask
                        self.doStems(&self.v_stems); // any leftover operands imply a trailing vstemhm
                        const total_bits = self.h_stems.count + self.v_stems.count;
                        const byte_count = (total_bits + 7) / 8;
                        const mask_bytes = try r.readBytes(byte_count);

                        if (b0 == 19) {
                            try self.hint_mask.setFromBytes(total_bits, mask_bytes);
                        } else {
                            // Counter mask: build a throwaway hint map purely to
                            // lock/position the counter-group hstems (side
                            // effect on the shared `h_stems` array via
                            // ` build`'s `stem.used`/`min_ds`/`max_ds`
                            // writes); the map itself is discarded.
                            var counter_mask: HintMask = .{};
                            try counter_mask.setFromBytes(total_bits, mask_bytes);
                            var counter_hint_map = HintMap.init(self.scale_y, true);
                            const em_box_hints: ?EmBoxHints = if (self.xblues.do_em_box_hints)
                                .{ .bottom = self.xblues.em_box_bottom_edge, .top = self.xblues.em_box_top_edge }
                            else
                                null;
                            build(&counter_hint_map, &self.glyph_path.initial_hint_map, &self.h_stems, &counter_mask, 0, false, self.xblues, self.darken_y, em_box_hints);
                        }
                    },
                    4 => { // vmoveto
                        if (self.sp > 1 and !self.have_width) self.width = self.stack[0] +% self.nominal_width_x;
                        self.have_width = true;
                        if (self.sp >= 1) {
                            self.y +%= self.stack[self.sp - 1];
                            try self.glyph_path.moveTo(self.x, self.y);
                        }
                        self.clearStack();
                    },
                    21 => { // rmoveto
                        if (self.sp > 2 and !self.have_width) self.width = self.stack[0] +% self.nominal_width_x;
                        self.have_width = true;
                        if (self.sp >= 2) {
                            self.x +%= self.stack[self.sp - 2];
                            self.y +%= self.stack[self.sp - 1];
                            try self.glyph_path.moveTo(self.x, self.y);
                        }
                        self.clearStack();
                    },
                    22 => { // hmoveto
                        if (self.sp > 1 and !self.have_width) self.width = self.stack[0] +% self.nominal_width_x;
                        self.have_width = true;
                        if (self.sp >= 1) {
                            self.x +%= self.stack[self.sp - 1];
                            try self.glyph_path.moveTo(self.x, self.y);
                        }
                        self.clearStack();
                    },
                    5 => { // rlineto
                        var i: usize = 0;
                        while (i + 2 <= self.sp) : (i += 2) {
                            self.x +%= self.stack[i];
                            self.y +%= self.stack[i + 1];
                            try self.glyph_path.lineTo(self.x, self.y);
                        }
                        self.clearStack();
                    },
                    6, 7 => { // hlineto, vlineto
                        var horizontal = b0 == 6;
                        var i: usize = 0;
                        while (i < self.sp) : (i += 1) {
                            if (horizontal) self.x +%= self.stack[i] else self.y +%= self.stack[i];
                            horizontal = !horizontal;
                            try self.glyph_path.lineTo(self.x, self.y);
                        }
                        self.clearStack();
                    },
                    8 => { // rrcurveto
                        var i: usize = 0;
                        while (i + 6 <= self.sp) : (i += 6) try self.curveToRel(i);
                        self.clearStack();
                    },
                    24 => { // rcurveline
                        if (self.sp >= 2) {
                            const line_start = self.sp - 2;
                            var i: usize = 0;
                            while (i + 6 <= line_start) : (i += 6) try self.curveToRel(i);
                            self.x +%= self.stack[line_start];
                            self.y +%= self.stack[line_start + 1];
                            try self.glyph_path.lineTo(self.x, self.y);
                        }
                        self.clearStack();
                    },
                    25 => { // rlinecurve
                        if (self.sp >= 6) {
                            const curve_start = self.sp - 6;
                            var i: usize = 0;
                            while (i + 2 <= curve_start) : (i += 2) {
                                self.x +%= self.stack[i];
                                self.y +%= self.stack[i + 1];
                                try self.glyph_path.lineTo(self.x, self.y);
                            }
                            try self.curveToRel(curve_start);
                        }
                        self.clearStack();
                    },
                    26 => { // vvcurveto
                        const count1 = self.sp;
                        const count = count1 & ~@as(usize, 2);
                        var i: usize = count1 - count;
                        while (i < count) {
                            var x1: Fixed = self.x;
                            if ((count - i) & 1 != 0) {
                                x1 = self.x +% self.stack[i];
                                i += 1;
                            }
                            const y1 = self.y +% self.stack[i];
                            const x2 = x1 +% self.stack[i + 1];
                            const y2 = y1 +% self.stack[i + 2];
                            const x3 = x2;
                            const y3 = y2 +% self.stack[i + 3];
                            try self.glyph_path.curveTo(x1, y1, x2, y2, x3, y3);
                            self.x = x3;
                            self.y = y3;
                            i += 4;
                        }
                        self.clearStack();
                    },
                    27 => { // hhcurveto
                        const count1 = self.sp;
                        const count = count1 & ~@as(usize, 2);
                        var i: usize = count1 - count;
                        while (i < count) {
                            var y1: Fixed = self.y;
                            if ((count - i) & 1 != 0) {
                                y1 = self.y +% self.stack[i];
                                i += 1;
                            }
                            const x1 = self.x +% self.stack[i];
                            const x2 = x1 +% self.stack[i + 1];
                            const y2 = y1 +% self.stack[i + 2];
                            const x3 = x2 +% self.stack[i + 3];
                            const y3 = y2;
                            try self.glyph_path.curveTo(x1, y1, x2, y2, x3, y3);
                            self.x = x3;
                            self.y = y3;
                            i += 4;
                        }
                        self.clearStack();
                    },
                    30, 31 => { // vhcurveto, hvcurveto
                        const count1 = self.sp;
                        const count = count1 & ~@as(usize, 2);
                        var i: usize = count1 - count;
                        var alternate = b0 == 31;
                        while (i < count) {
                            var x1: Fixed = undefined;
                            var y1: Fixed = undefined;
                            var x2: Fixed = undefined;
                            var y2: Fixed = undefined;
                            var x3: Fixed = undefined;
                            var y3: Fixed = undefined;
                            if (alternate) {
                                x1 = self.x +% self.stack[i];
                                y1 = self.y;
                                x2 = x1 +% self.stack[i + 1];
                                y2 = y1 +% self.stack[i + 2];
                                y3 = y2 +% self.stack[i + 3];
                                if (count - i == 5) {
                                    x3 = x2 +% self.stack[i + 4];
                                    i += 1;
                                } else {
                                    x3 = x2;
                                }
                                alternate = false;
                            } else {
                                x1 = self.x;
                                y1 = self.y +% self.stack[i];
                                x2 = x1 +% self.stack[i + 1];
                                y2 = y1 +% self.stack[i + 2];
                                x3 = x2 +% self.stack[i + 3];
                                if (count - i == 5) {
                                    y3 = y2 +% self.stack[i + 4];
                                    i += 1;
                                } else {
                                    y3 = y2;
                                }
                                alternate = true;
                            }
                            try self.glyph_path.curveTo(x1, y1, x2, y2, x3, y3);
                            self.x = x3;
                            self.y = y3;
                            i += 4;
                        }
                        self.clearStack();
                    },
                    10, 29 => { // callsubr, callgsubr
                        if (self.sp > 0) {
                            self.sp -= 1;
                            const raw = self.stack[self.sp];
                            const idx_val: i64 = raw >> 16;
                            const subrs = if (b0 == 29) self.data.global_subrs else self.data.local_subrs;
                            const bias: i64 = if (subrs.count < 1240) 107 else if (subrs.count < 33900) 1131 else 32768;
                            const real_idx = idx_val + bias;
                            if (real_idx < 0 or real_idx >= @as(i64, subrs.count)) return error.InvalidCharstring;
                            const sub = try subrs.get(@intCast(real_idx));
                            try self.run(sub);
                        }
                    },
                    11 => return, // return: unwind to the caller's `run` frame
                    12 => { // escape
                        const op2 = try r.readU8();
                        switch (op2) {
                            34 => try self.hflex(),
                            35 => try self.flex(),
                            36 => try self.hflex1(),
                            37 => try self.flex1(),
                            else => {}, // arithmetic/storage ops: not ported, see module doc comment
                        }
                        self.clearStack();
                    },
                    14 => { // endchar
                        if (self.sp == 1 or self.sp == 5) {
                            if (!self.have_width) self.width = self.stack[0] +% self.nominal_width_x;
                        }
                        self.have_width = true;
                        try self.glyph_path.closeOpenPath();
                        // Deprecated 4/5-arg implied `seac` not supported, see
                        // module doc comment -- leftover operands are dropped.
                        self.clearStack();
                        return;
                    },
                    else => self.clearStack(), // reserved / CFF2-only (vsindex, blend): no-op
                }
            }
        }
    };

    /// Renders one glyph's Type2 charstring into a hinted, device-space path —
    /// port of `cf2_getGlyphOutline` (`psfont.c`), including its darkening
    /// setup (`cf2_font_setup`) and CCW-winding-order darkening retry.
    pub fn render(
        allocator: std.mem.Allocator,
        data: parsing.Table.cff.CharstringAndSubrs,
        private_hints: parsing.CffPrivateHints,
        units_per_em: u16,
        options: Options,
    ) InterpError!RenderResult {
        const units_per_em_i: i32 = if (units_per_em == 0) 1000 else units_per_em;
        const em_ratio = divFix(intToFixed(1000), intToFixed(units_per_em_i));
        const ppem = @max(intToFixed(4), options.ppem);

        var std_vw = doubleToFixed(private_hints.std_vw);
        if (std_vw <= 0) std_vw = divFix(intToFixed(75), em_ratio);

        var darken_x: Fixed = 0;
        if (options.bolden_x > 0) {
            const bolden_x = @max(options.bolden_x, divFix(intToFixed(units_per_em_i), ppem));
            darken_x = computeDarkening(em_ratio, ppem, std_vw, bolden_x, false);
        } else {
            darken_x = computeDarkening(em_ratio, ppem, std_vw, 0, options.darken);
        }

        var std_hw = doubleToFixed(private_hints.std_hw);
        std_hw = if (std_hw > 0 and std_vw > 2 *% std_hw)
            divFix(intToFixed(75), em_ratio)
        else
            divFix(intToFixed(110), em_ratio);
        const darken_y = computeDarkening(em_ratio, ppem, std_hw, options.bolden_y, options.darken);
        const darkened = darken_x != 0 or darken_y != 0;

        var blue_values_buf: [14]Fixed = undefined;
        var other_blues_buf: [10]Fixed = undefined;
        var family_blues_buf: [14]Fixed = undefined;
        var family_other_blues_buf: [10]Fixed = undefined;

        var xblues: blues.Blues = undefined;
        blues.init(&xblues, .{
            .scale = options.scale_y,
            .darken_y = darken_y,
            .stem_darkened = darkened,
            .language_group = private_hints.language_group,
            .blue_values = fixedArrayFromDoubles(&blue_values_buf, private_hints.blue_values[0..private_hints.blue_values_count]),
            .other_blues = fixedArrayFromDoubles(&other_blues_buf, private_hints.other_blues[0..private_hints.other_blues_count]),
            .family_blues = fixedArrayFromDoubles(&family_blues_buf, private_hints.family_blues[0..private_hints.family_blues_count]),
            .family_other_blues = fixedArrayFromDoubles(&family_other_blues_buf, private_hints.family_other_blues[0..private_hints.family_other_blues_count]),
            .blue_scale = doubleToFixed(private_hints.blue_scale),
            .blue_shift = doubleToFixed(private_hints.blue_shift),
            .blue_fuzz = doubleToFixed(private_hints.blue_fuzz),
        });

        const nominal_width_x = doubleToFixed(private_hints.nominal_width_x);
        const default_width_x = doubleToFixed(private_hints.default_width_x);

        var xinterp: Interp = .{
            .data = data,
            .nominal_width_x = nominal_width_x,
            .scale_y = options.scale_y,
            .xblues = &xblues,
            .darken_y = darken_y,
            .width = default_width_x,
            .glyph_path = undefined,
        };

        var glyph_path = GlyphPath.init(allocator, .{
            .scale_x = options.scale_x,
            .scale_c = options.scale_c,
            .scale_y = options.scale_y,
            .fractional_translation = options.fractional_translation,
            .h_stems = &xinterp.h_stems,
            .hint_mask = &xinterp.hint_mask,
            .hint_origin_y = 0,
            .xblues = &xblues,
            .darken = darkened,
            .darken_x = darken_x,
            .darken_y = darken_y,
        });
        xinterp.glyph_path = &glyph_path;
        errdefer glyph_path.deinit();

        try xinterp.run(data.charstring);
        try glyph_path.closeOpenPath();

        // Winding order only affects darkening: CFF outlines are CCW by
        // convention, so a CW result under darkening means the outward stem
        // offset pushed the wrong way -- reinterpret once with reversed offset
        // direction, matching `cf2_getGlyphOutline`'s retry loop.
        if (darkened and glyph_path.winding_momentum < 0) {
            glyph_path.deinit();
            xinterp.resetForRerun(&glyph_path, default_width_x);

            glyph_path = GlyphPath.init(allocator, .{
                .scale_x = options.scale_x,
                .scale_c = options.scale_c,
                .scale_y = options.scale_y,
                .fractional_translation = options.fractional_translation,
                .h_stems = &xinterp.h_stems,
                .hint_mask = &xinterp.hint_mask,
                .hint_origin_y = 0,
                .xblues = &xblues,
                .darken = darkened,
                .darken_x = darken_x,
                .darken_y = darken_y,
                .reverse_winding = true,
            });
            xinterp.glyph_path = &glyph_path;

            try xinterp.run(data.charstring);
            try glyph_path.closeOpenPath();
        }

        return .{ .segments = try glyph_path.segments.toOwnedSlice(allocator), .width = xinterp.width };
    }

    fn testPrivateHints() parsing.CffPrivateHints {
        return .{
            .blue_scale = 0.039625,
            .blue_shift = 7,
            .blue_fuzz = 1,
        };
    }

    test "square charstring with one hstem+hintmask renders a closed 4-point path" {
        // 0 100 hstem ; hintmask (1 byte, bit0 set) ; 0 0 rmoveto ;
        // 100 0 rlineto ; 0 100 rlineto ; -100 0 rlineto ; endchar
        const charstring = [_]u8{
            139, 239,  1,
            19,  0x80, 139,
            139, 21,   239,
            139, 5,    139,
            239, 5,    39,
            139, 5,    14,
        };

        const data = parsing.Table.cff.charstringAndSubrsWithoutSubrs(&charstring);

        const result = try render(std.testing.allocator, data, testPrivateHints(), 1000, .{
            .scale_x = one,
            .scale_y = one,
            .ppem = intToFixed(100),
            .darken = false,
        });
        defer std.testing.allocator.free(result.segments);

        try std.testing.expect(result.segments.len >= 4);
        try std.testing.expectEqual(Segment{ .move_to = .{ .x = 0, .y = 0 } }, result.segments[0]);
    }
};

// 16.16 fixed-point arithmetic for the CFF (`cf2`) hinting engine — port of
// `vendor/freetype/src/psaux/psfixed.h` plus the `FT_MulFix`/`FT_DivFix`
// rounding semantics from `vendor/freetype/src/base/ftcalc.c`. Distinct
// fixed-point domain from `rasterization/common.zig`'s 26.6 (`ftMulFix`/
// `ftDivFix` there are F26Dot6, not F16Dot16) — kept separate rather than
// parameterized since the two callers never share a scale.
pub const Fixed = i32;

pub const one: Fixed = 0x10000;
pub const epsilon: Fixed = 1;

pub fn intToFixed(i: i32) Fixed {
    return i *% one;
}

pub fn fixedToInt(x: Fixed) i16 {
    const rounded: u32 = @as(u32, @bitCast(x)) +% 0x8000;
    return @truncate(@as(i32, @bitCast(rounded >> 16)));
}

pub fn fixedRound(x: Fixed) Fixed {
    const rounded: u32 = @as(u32, @bitCast(x)) +% 0x8000;
    return @bitCast(rounded & 0xFFFF0000);
}

pub fn fixedFloor(x: Fixed) Fixed {
    return @bitCast(@as(u32, @bitCast(x)) & 0xFFFF0000);
}

pub fn fixedFraction(x: Fixed) Fixed {
    return x -% fixedFloor(x);
}

pub fn fixedAbs(x: Fixed) Fixed {
    return if (x < 0) -%x else x;
}

pub fn doubleToFixed(f: f64) Fixed {
    const rounding: f64 = if (f >= 0) 0.5 else -0.5;
    return @intFromFloat(f * 65536.0 + rounding);
}

/// `a * b`, rounded to nearest (round-half-away-from-zero on the true
/// product), matching `FT_MulFix`'s `(a*b + 0x8000) >> 16` magnitude-space
/// rounding exactly (verified against ftcalc.c's non-64-bit fallback path,
/// which computes on `|a|`/`|b|` then reapplies the sign).
pub fn mulFix(a: Fixed, b: Fixed) Fixed {
    const prod: i64 = @as(i64, a) * @as(i64, b);
    const rounded: i64 = if (prod >= 0) (prod + 0x8000) >> 16 else -((-prod + 0x8000) >> 16);
    return @truncate(rounded);
}

/// `(a << 16) / b`, rounded to nearest, saturating to `maxInt(i32)` (sign-
/// adjusted) on division by zero — matches `FT_DivFix`.
pub fn divFix(a: Fixed, b: Fixed) Fixed {
    if (b == 0) return if (a < 0) -std.math.maxInt(i32) else std.math.maxInt(i32);
    const neg = (a < 0) != (b < 0);
    const au: u64 = @abs(a);
    const bu: u64 = @abs(b);
    const q: u64 = ((au << 16) + (bu >> 1)) / bu;
    const clamped: u32 = if (q > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(q);
    return if (neg) -@as(i32, @intCast(clamped)) else @intCast(clamped);
}

/// `a * b / c`, rounded to nearest — port of `FT_MulDiv`.
pub fn mulDiv(a: i32, b: i32, c: i32) i32 {
    if (c == 0) return if ((a < 0) != (b < 0)) -std.math.maxInt(i32) else std.math.maxInt(i32);
    const neg = ((a < 0) != (b < 0)) != (c < 0);
    const prod: u64 = @as(u64, @abs(a)) * @as(u64, @abs(b));
    const cu: u64 = @abs(c);
    const q: u64 = (prod + cu / 2) / cu;
    const clamped: u32 = if (q > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(q);
    return if (neg) -@as(i32, @intCast(clamped)) else @intCast(clamped);
}
