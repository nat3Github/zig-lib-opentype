const parsing = @import("../parsing.zig");
const common = @import("common.zig");
const Buffer = common.Buffer;
const Cmap = common.Cmap;
const Tag = common.Tag;

// Ported from vendor/harfbuzz/src/hb-ot-shaper-thai.cc (pinned 703e2d1441):
// the Thai/Lao shaper. Two independent pieces, both run once per buffer in
// `preprocessTextThai` before `normalize()`:
//
// 1. SARA AM decompose+reorder (`<consonant, SARA AM>` -> `<consonant,
//    NIKHAHIT, SARA AA>`, with NIKHAHIT moved before any preceding
//    above-base marks) - always runs, independent of whether the font has
//    Thai/Lao GSUB, matching hb's unconditional first shaping rule.
// 2. PUA fallback shaping (`doThaiPuaShaping`) - only runs when the script
//    is Thai (not Lao) and the font's GSUB has no `thai` script entry,
//    remapping certain base/mark codepoints to Private Use Area glyphs an
//    old non-OpenType-aware Thai font ships instead, per
//    https://linux.thai.net/~thep/th-otf/shaping.html. `map.found_script[0]`
//    (GSUB table index) drives that check, which is why `shape()` now
//    builds `map` before calling this - see this section's dispatch note.
//
// Scope cut: `_hb_glyph_info_set_continuation` (hb's grapheme-continuation
// bit, set on the NIKHAHIT glyph so `hb_form_clusters` treats it as
// non-cluster-starting) is not ported - this port's cluster machinery has
// no continuation-tracking mechanism at all (see `hb_form_clusters`'s scope
// cut noted near `normalize()` above); the immediately-following
// `mergeOutClusters`/`mergeOutGraphemeClusters` calls already fold NIKHAHIT
// into its base's cluster, which is what actually matters for this port's
// monotone-cluster model.
//
// Dispatch: activates when `thai` or `lao ` appears in `shape()`'s
// caller-supplied `script_tags`, same "caller supplies the tag" stand-in
// used by the Hangul/Arabic shapers above.

pub const thai_script_tag = Tag{ 't', 'h', 'a', 'i' };
pub const lao_script_tag = Tag{ 'l', 'a', 'o', ' ' };

const ThaiConsonantType = enum(u8) { nc, ac, rc, dc, not_consonant };

fn thaiConsonantType(u: u32) ThaiConsonantType {
    if (u == 0x0E1B or u == 0x0E1D or u == 0x0E1F) return .ac;
    if (u == 0x0E0D or u == 0x0E10) return .rc;
    if (u == 0x0E0E or u == 0x0E0F) return .dc;
    if (u >= 0x0E01 and u <= 0x0E2E) return .nc;
    return .not_consonant;
}

const ThaiMarkType = enum(u8) { av, bv, t, not_mark };

fn thaiMarkType(u: u32) ThaiMarkType {
    if (u == 0x0E31 or (u >= 0x0E34 and u <= 0x0E37) or u == 0x0E47 or (u >= 0x0E4D and u <= 0x0E4E)) return .av;
    if (u >= 0x0E38 and u <= 0x0E3A) return .bv;
    if (u >= 0x0E48 and u <= 0x0E4C) return .t;
    return .not_mark;
}

const ThaiAction = enum(u8) { nop, sd, sl, sdl, rd };

const ThaiAboveState = enum(u8) { t0, t1, t2, t3 };

const thai_above_start_state = [5]ThaiAboveState{ .t0, .t1, .t0, .t0, .t3 };

const ThaiStateEdge = struct { action: ThaiAction, next: u8 };

const thai_above_state_machine = [4][3]ThaiStateEdge{
    .{ .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t3) }, .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t0) }, .{ .action = .sd, .next = @intFromEnum(ThaiAboveState.t3) } },
    .{ .{ .action = .sl, .next = @intFromEnum(ThaiAboveState.t2) }, .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t1) }, .{ .action = .sdl, .next = @intFromEnum(ThaiAboveState.t2) } },
    .{ .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t3) }, .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t2) }, .{ .action = .sl, .next = @intFromEnum(ThaiAboveState.t3) } },
    .{ .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t3) }, .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t3) }, .{ .action = .nop, .next = @intFromEnum(ThaiAboveState.t3) } },
};

const ThaiBelowState = enum(u8) { b0, b1, b2 };

const thai_below_start_state = [5]ThaiBelowState{ .b0, .b0, .b1, .b2, .b2 };

const thai_below_state_machine = [3][3]ThaiStateEdge{
    .{ .{ .action = .nop, .next = @intFromEnum(ThaiBelowState.b0) }, .{ .action = .nop, .next = @intFromEnum(ThaiBelowState.b2) }, .{ .action = .nop, .next = @intFromEnum(ThaiBelowState.b0) } },
    .{ .{ .action = .nop, .next = @intFromEnum(ThaiBelowState.b1) }, .{ .action = .rd, .next = @intFromEnum(ThaiBelowState.b2) }, .{ .action = .nop, .next = @intFromEnum(ThaiBelowState.b1) } },
    .{ .{ .action = .nop, .next = @intFromEnum(ThaiBelowState.b2) }, .{ .action = .sd, .next = @intFromEnum(ThaiBelowState.b2) }, .{ .action = .nop, .next = @intFromEnum(ThaiBelowState.b2) } },
};

const ThaiPuaMapping = struct { u: u16, win_pua: u16, mac_pua: u16 };

const thai_sd_mappings = [_]ThaiPuaMapping{
    .{ .u = 0x0E48, .win_pua = 0xF70A, .mac_pua = 0xF88B },
    .{ .u = 0x0E49, .win_pua = 0xF70B, .mac_pua = 0xF88E },
    .{ .u = 0x0E4A, .win_pua = 0xF70C, .mac_pua = 0xF891 },
    .{ .u = 0x0E4B, .win_pua = 0xF70D, .mac_pua = 0xF894 },
    .{ .u = 0x0E4C, .win_pua = 0xF70E, .mac_pua = 0xF897 },
    .{ .u = 0x0E38, .win_pua = 0xF718, .mac_pua = 0xF89B },
    .{ .u = 0x0E39, .win_pua = 0xF719, .mac_pua = 0xF89C },
    .{ .u = 0x0E3A, .win_pua = 0xF71A, .mac_pua = 0xF89D },
};

const thai_sdl_mappings = [_]ThaiPuaMapping{
    .{ .u = 0x0E48, .win_pua = 0xF705, .mac_pua = 0xF88C },
    .{ .u = 0x0E49, .win_pua = 0xF706, .mac_pua = 0xF88F },
    .{ .u = 0x0E4A, .win_pua = 0xF707, .mac_pua = 0xF892 },
    .{ .u = 0x0E4B, .win_pua = 0xF708, .mac_pua = 0xF895 },
    .{ .u = 0x0E4C, .win_pua = 0xF709, .mac_pua = 0xF898 },
};

const thai_sl_mappings = [_]ThaiPuaMapping{
    .{ .u = 0x0E48, .win_pua = 0xF713, .mac_pua = 0xF88A },
    .{ .u = 0x0E49, .win_pua = 0xF714, .mac_pua = 0xF88D },
    .{ .u = 0x0E4A, .win_pua = 0xF715, .mac_pua = 0xF890 },
    .{ .u = 0x0E4B, .win_pua = 0xF716, .mac_pua = 0xF893 },
    .{ .u = 0x0E4C, .win_pua = 0xF717, .mac_pua = 0xF896 },
    .{ .u = 0x0E31, .win_pua = 0xF710, .mac_pua = 0xF884 },
    .{ .u = 0x0E34, .win_pua = 0xF701, .mac_pua = 0xF885 },
    .{ .u = 0x0E35, .win_pua = 0xF702, .mac_pua = 0xF886 },
    .{ .u = 0x0E36, .win_pua = 0xF703, .mac_pua = 0xF887 },
    .{ .u = 0x0E37, .win_pua = 0xF704, .mac_pua = 0xF888 },
    .{ .u = 0x0E47, .win_pua = 0xF712, .mac_pua = 0xF889 },
    .{ .u = 0x0E4D, .win_pua = 0xF711, .mac_pua = 0xF899 },
};

const thai_rd_mappings = [_]ThaiPuaMapping{
    .{ .u = 0x0E0D, .win_pua = 0xF70F, .mac_pua = 0xF89A },
    .{ .u = 0x0E10, .win_pua = 0xF700, .mac_pua = 0xF89E },
};

fn thaiPuaMappingsFor(action: ThaiAction) []const ThaiPuaMapping {
    return switch (action) {
        .nop => &.{},
        .sd => &thai_sd_mappings,
        .sdl => &thai_sdl_mappings,
        .sl => &thai_sl_mappings,
        .rd => &thai_rd_mappings,
    };
}

fn thaiPuaShape(cmap: ?Cmap, u: u32, action: ThaiAction) u32 {
    if (action == .nop or u > 0xFFFF) return u;
    for (thaiPuaMappingsFor(action)) |mapping| {
        if (mapping.u != u) continue;
        if (cmap) |resolved| {
            if (resolved.lookup(mapping.win_pua)) |g| if (g != 0) return mapping.win_pua;
            if (resolved.lookup(mapping.mac_pua)) |g| if (g != 0) return mapping.mac_pua;
        }
        break;
    }
    return u;
}

/// Ported from `do_thai_pua_shaping`: only called when the font has no
/// Thai GSUB entry, so PUA glyphs stand in for the state-machine-selected
/// mark form.
fn doThaiPuaShaping(cmap: ?Cmap, buffer: *Buffer) void {
    var above_state: ThaiAboveState = thai_above_start_state[@intFromEnum(ThaiConsonantType.not_consonant)];
    var below_state: ThaiBelowState = thai_below_start_state[@intFromEnum(ThaiConsonantType.not_consonant)];
    var base: usize = 0;

    const info = buffer.info.items;
    for (info, 0..) |*glyph_info, i| {
        const mt = thaiMarkType(glyph_info.codepoint);
        if (mt == .not_mark) {
            const ct = thaiConsonantType(glyph_info.codepoint);
            above_state = thai_above_start_state[@intFromEnum(ct)];
            below_state = thai_below_start_state[@intFromEnum(ct)];
            base = i;
            continue;
        }

        const above_edge = thai_above_state_machine[@intFromEnum(above_state)][@intFromEnum(mt)];
        const below_edge = thai_below_state_machine[@intFromEnum(below_state)][@intFromEnum(mt)];
        above_state = @enumFromInt(above_edge.next);
        below_state = @enumFromInt(below_edge.next);

        const action = if (above_edge.action != .nop) above_edge.action else below_edge.action;

        buffer.unsafeToBreak(base, i);
        if (action == .rd) {
            info[base].codepoint = thaiPuaShape(cmap, info[base].codepoint, action);
        } else {
            info[i].codepoint = thaiPuaShape(cmap, glyph_info.codepoint, action);
        }
    }
}

fn thaiIsSaraAm(u: u32) bool {
    return (u & ~@as(u32, 0x0080)) == 0x0E33;
}

fn thaiIsAboveBaseMark(u: u32) bool {
    const x = u & ~@as(u32, 0x0080);
    return (x >= 0x0E34 and x <= 0x0E37) or (x >= 0x0E47 and x <= 0x0E4E) or x == 0x0E31 or x == 0x0E3B;
}

/// Ported from `preprocess_text_thai`: decomposes `<consonant, SARA AM>`
/// into `<consonant, NIKHAHIT, SARA AA>` and moves NIKHAHIT before any
/// preceding above-base marks, then (Thai only, not Lao) runs
/// `doThaiPuaShaping` if the font's GSUB has no `thai` script entry.
pub fn preprocessTextThai(buffer: *Buffer, cmap: ?Cmap, is_thai: bool, has_thai_gsub: bool) !void {
    buffer.clearOutput();
    const count = buffer.info.items.len;
    buffer.idx = 0;
    while (buffer.idx < count) {
        const u = buffer.cur(0).codepoint;
        if (!thaiIsSaraAm(u)) {
            try buffer.nextGlyph();
            continue;
        }

        try buffer.outputGlyph(u - 0x0E33 + 0x0E4D);
        try buffer.replaceGlyph(u - 1);

        const end = buffer.outLen();
        var start = end - 2;
        while (start > 0 and thaiIsAboveBaseMark(buffer.out_info.items[start - 1].codepoint)) start -= 1;

        if (start + 2 < end) {
            buffer.mergeOutClusters(start, end);
            const t = buffer.out_info.items[end - 2];
            var j = end - 2;
            while (j > start) : (j -= 1) buffer.out_info.items[j] = buffer.out_info.items[j - 1];
            buffer.out_info.items[start] = t;
        }

        if (start > 0) buffer.mergeOutGraphemeClusters(start - 1, end);
    }
    try buffer.sync();

    if (is_thai and !has_thai_gsub) doThaiPuaShaping(cmap, buffer);
}
