const std = @import("std");
const parsing = @import("../parsing.zig");
const common = @import("common.zig");
const map_mod = @import("map.zig");
const apply_mod = @import("apply.zig");
const Buffer = common.Buffer;
const Cmap = common.Cmap;
const Tag = common.Tag;
const containsTag = common.containsTag;
const MapBuilder = map_mod.MapBuilder;
const Map = map_mod.Map;
const table_tag_hhea = apply_mod.table_tag_hhea;
const table_tag_hmtx = apply_mod.table_tag_hmtx;

// Ported from vendor/harfbuzz/src/hb-ot-shaper-hangul.cc (pinned
// 703e2d1441): the Hangul complex shaper. Unlike Arabic/Indic/etc., Hangul
// needs no ragel state machine or generated data table - L/V/T jamo
// composition/decomposition is fully algorithmic (the same UAX #15 D68/R2
// Hangul-syllable formula unicode.zig's decomposeCanonical/composeCanonical
// already use for NFC/NFD; this shaper duplicates the constants rather than
// reusing those since the OT-specific logic here interleaves font-glyph-
// coverage checks with the arithmetic, which those pure-Unicode functions
// don't do).
//
// Dispatch: this port has no Unicode-script-property table (the "caller
// supplies the tag" scope cut in this file's MapBuilder section doc comment
// applies here too), so the Hangul shaper activates when `hang` appears
// anywhere in `shape()`'s caller-supplied `script_tags`, standing in for
// hb's `hb_ot_shape_complex_categorize` Unicode-script dispatch.
//
// Scope cuts vs. hb-ot-shaper-hangul.cc: the general `hb_insert_dotted_circle`
// default-ignorable pass isn't ported (Hangul's own dotted-circle insertion
// for orphan tone marks below is self-contained and doesn't need it);
// `HB_BUFFER_FLAG_DO_NOT_INSERT_DOTTED_CIRCLE` has no equivalent buffer flag
// in this port, so dotted-circle insertion always happens when the font has
// the glyph.

pub const hang_script_tag = Tag{ 'h', 'a', 'n', 'g' };
pub const tag_calt = Tag{ 'c', 'a', 'l', 't' };

const HangulJmo = enum(u8) { none = 0, ljmo = 1, vjmo = 2, tjmo = 3 };

const hangul_feature_tags = [4]Tag{
    .{ 0, 0, 0, 0 },
    .{ 'l', 'j', 'm', 'o' },
    .{ 'v', 'j', 'm', 'o' },
    .{ 't', 'j', 'm', 'o' },
};

const hangul_l_base: u32 = 0x1100;
const hangul_v_base: u32 = 0x1161;
const hangul_t_base: u32 = 0x11A7;
const hangul_l_count: u32 = 19;
const hangul_v_count: u32 = 21;
const hangul_t_count: u32 = 28;
const hangul_s_base: u32 = 0xAC00;
const hangul_n_count: u32 = hangul_v_count * hangul_t_count;
const hangul_s_count: u32 = hangul_l_count * hangul_n_count;

fn isCombiningL(u: u32) bool {
    return u >= hangul_l_base and u < hangul_l_base + hangul_l_count;
}
fn isCombiningV(u: u32) bool {
    return u >= hangul_v_base and u < hangul_v_base + hangul_v_count;
}
fn isCombiningT(u: u32) bool {
    return u > hangul_t_base and u < hangul_t_base + hangul_t_count;
}
fn isCombinedS(u: u32) bool {
    return u >= hangul_s_base and u < hangul_s_base + hangul_s_count;
}

fn isHangulL(u: u32) bool {
    return (u >= 0x1100 and u <= 0x115F) or (u >= 0xA960 and u <= 0xA97C);
}
fn isHangulV(u: u32) bool {
    return (u >= 0x1160 and u <= 0x11A7) or (u >= 0xD7B0 and u <= 0xD7C6);
}
fn isHangulT(u: u32) bool {
    return (u >= 0x11A8 and u <= 0x11FF) or (u >= 0xD7CB and u <= 0xD7FB);
}
fn isHangulTone(u: u32) bool {
    return u >= 0x302E and u <= 0x302F;
}

fn hangulHasGlyph(cmap: ?Cmap, cp: u32) bool {
    const resolved = cmap orelse return false;
    if (resolved.lookup(@intCast(cp))) |g| return g != 0;
    return false;
}

fn hangulIsZeroWidthChar(cmap: ?Cmap, hhea: ?parsing.Table.hhea, hmtx_data: ?[]const u8, cp: u32) bool {
    const resolved = cmap orelse return false;
    const glyph = resolved.lookup(@intCast(cp)) orelse return false;
    const hh = hhea orelse return false;
    const hd = hmtx_data orelse return false;
    return parsing.Table.hmtx.metricForGlyph(hd, glyph, hh.number_of_h_metrics).advance_width == 0;
}

/// Ported from collect_features_hangul: registers ljmo/vjmo/tjmo as
/// non-global features (own mask bits, applied per-glyph by
/// `setupMasksHangul` below rather than to the whole run).
pub fn collectFeaturesHangul(map_builder: *MapBuilder) !void {
    for (hangul_feature_tags[1..]) |tag| try map_builder.addFeature(tag, .{}, 1);
}

/// Ported from override_features_hangul: re-adds `calt` non-globally so
/// `setupMasksHangul` below can clear it selectively on jamo glyphs
/// (Uniscribe parity - some fonts apply jamo lookups in calt, undesirable
/// here). Must run after `shape()`'s default_features loop, which already
/// added `calt` globally - `MapBuilder.compile`'s dedup pass (see its doc
/// comment) only un-globals the merged entry when the non-global add has a
/// later seq number than the global one, mirroring hb's real add order.
pub fn overrideFeaturesHangul(map_builder: *MapBuilder) !void {
    try map_builder.addFeature(tag_calt, .{}, 1);
}

/// Ported from preprocess_text_hangul: runs on the raw Unicode-codepoint
/// buffer before `normalize()`. Precomposes <L,V,T?> jamo sequences into a
/// single syllable when the font has that glyph, decomposes precomposed
/// syllables the font lacks, and reorders a following Hangul tone mark
/// (U+302E/F) to precede its base syllable.
pub fn preprocessHangul(font: parsing.Font, buffer: *Buffer, cmap: ?Cmap) !void {
    const hhea_data = font.tableData(table_tag_hhea);
    const hmtx_data = font.tableData(table_tag_hmtx);
    const hhea = if (hhea_data) |d| (parsing.Table.hhea.parse(d) catch null) else null;

    buffer.clearOutput();
    var start: usize = 0;
    var end: usize = 0;
    const count = buffer.info.items.len;

    buffer.idx = 0;
    while (buffer.idx < count and buffer.successful) {
        const u: u32 = buffer.cur(0).codepoint;

        if (isHangulTone(u)) {
            if (start < end and end == buffer.outLen()) {
                buffer.unsafeToBreakFromOutBuffer(start, buffer.idx);
                try buffer.nextGlyph();
                if (!hangulIsZeroWidthChar(cmap, hhea, hmtx_data, u)) {
                    buffer.mergeOutClusters(start, end + 1);
                    const info = buffer.out_info.items;
                    const tone = info[end];
                    var i = end;
                    while (i > start) : (i -= 1) info[i] = info[i - 1];
                    info[start] = tone;
                }
            } else {
                if (hangulHasGlyph(cmap, 0x25CC)) {
                    var chars: [2]u32 = undefined;
                    if (!hangulIsZeroWidthChar(cmap, hhea, hmtx_data, u)) {
                        chars = .{ u, 0x25CC };
                    } else {
                        chars = .{ 0x25CC, u };
                    }
                    try buffer.replaceGlyphs(1, &chars);
                } else {
                    try buffer.nextGlyph();
                }
            }
            start = buffer.outLen();
            end = start;
            continue;
        }

        start = buffer.outLen();

        if (isHangulL(u) and buffer.idx + 1 < count) {
            const l = u;
            const v: u32 = buffer.cur(1).codepoint;
            if (isHangulV(v)) {
                var t: u32 = 0;
                var tindex: u32 = 0;
                if (buffer.idx + 2 < count) {
                    const t_candidate: u32 = buffer.cur(2).codepoint;
                    if (isHangulT(t_candidate)) {
                        t = t_candidate;
                        tindex = t - hangul_t_base;
                    }
                }
                buffer.unsafeToBreak(buffer.idx, buffer.idx + (if (t != 0) @as(usize, 3) else 2));

                if (isCombiningL(l) and isCombiningV(v) and (t == 0 or isCombiningT(t))) {
                    const s = hangul_s_base + (l - hangul_l_base) * hangul_n_count + (v - hangul_v_base) * hangul_t_count + tindex;
                    if (hangulHasGlyph(cmap, s)) {
                        try buffer.replaceGlyphs(if (t != 0) 3 else 2, &.{s});
                        end = start + 1;
                        continue;
                    }
                }

                buffer.curPtr(0).hangul_feature = @intFromEnum(HangulJmo.ljmo);
                try buffer.nextGlyph();
                buffer.curPtr(0).hangul_feature = @intFromEnum(HangulJmo.vjmo);
                try buffer.nextGlyph();
                if (t != 0) {
                    buffer.curPtr(0).hangul_feature = @intFromEnum(HangulJmo.tjmo);
                    try buffer.nextGlyph();
                    end = start + 3;
                } else {
                    end = start + 2;
                }
                if (!buffer.successful) break;
                buffer.mergeOutGraphemeClusters(start, end);
                continue;
            }
        } else if (isCombinedS(u)) {
            const s = u;
            const has_glyph = hangulHasGlyph(cmap, s);
            const lindex = (s - hangul_s_base) / hangul_n_count;
            const nindex = (s - hangul_s_base) % hangul_n_count;
            const vindex = nindex / hangul_t_count;
            const tindex = nindex % hangul_t_count;

            if (tindex == 0 and buffer.idx + 1 < count and isCombiningT(buffer.cur(1).codepoint)) {
                const new_tindex: u32 = buffer.cur(1).codepoint - hangul_t_base;
                const new_s = s + new_tindex;
                if (hangulHasGlyph(cmap, new_s)) {
                    try buffer.replaceGlyphs(2, &.{new_s});
                    end = start + 1;
                    continue;
                } else {
                    buffer.unsafeToBreak(buffer.idx, buffer.idx + 2);
                }
            }

            if (!has_glyph or (tindex == 0 and buffer.idx + 1 < count and isHangulT(buffer.cur(1).codepoint))) {
                const decomposed = [3]u32{ hangul_l_base + lindex, hangul_v_base + vindex, hangul_t_base + tindex };
                if (hangulHasGlyph(cmap, decomposed[0]) and hangulHasGlyph(cmap, decomposed[1]) and (tindex == 0 or hangulHasGlyph(cmap, decomposed[2]))) {
                    var s_len: usize = if (tindex != 0) 3 else 2;
                    try buffer.replaceGlyphs(1, decomposed[0..s_len]);

                    if (has_glyph and tindex == 0) {
                        try buffer.nextGlyph();
                        s_len += 1;
                    }
                    if (!buffer.successful) break;

                    end = start + s_len;
                    var i = start;
                    buffer.out_info.items[i].hangul_feature = @intFromEnum(HangulJmo.ljmo);
                    i += 1;
                    buffer.out_info.items[i].hangul_feature = @intFromEnum(HangulJmo.vjmo);
                    i += 1;
                    if (i < end) buffer.out_info.items[i].hangul_feature = @intFromEnum(HangulJmo.tjmo);

                    buffer.mergeOutGraphemeClusters(start, end);
                    continue;
                } else if (tindex == 0 and buffer.idx + 1 < count and isHangulT(buffer.cur(1).codepoint)) {
                    buffer.unsafeToBreak(buffer.idx, buffer.idx + 2);
                }
            }

            if (has_glyph) end = start + 1;
        }

        try buffer.nextGlyph();
    }
    try buffer.sync();
}

/// Ported from setup_masks_hangul: runs after `normalize()` but before
/// `mapGlyphsFast()` overwrites `codepoint` with a glyph id, since it needs
/// the original Unicode value both for the ljmo/vjmo/tjmo mask lookup
/// (`hangul_feature`, set above by `preprocessHangul`) and the isL/isV/isT
/// check that keeps `calt` off jamo glyphs.
pub fn setupMasksHangul(buffer: *Buffer, map: Map) void {
    const calt_mask = map.get1Mask(tag_calt);
    for (buffer.info.items) |*info| {
        info.mask |= map.get1Mask(hangul_feature_tags[info.hangul_feature]);

        const u = info.codepoint;
        if (isHangulL(u) or isHangulV(u) or isHangulT(u)) info.mask &= ~calt_mask;
    }
}
