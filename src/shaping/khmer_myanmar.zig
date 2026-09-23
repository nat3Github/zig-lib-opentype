// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const common = @import("common.zig");
const map_mod = @import("map.zig");
const indic_mod = @import("indic.zig");
const syllable_machines = @import("syllable_machines.zig");
const arabic_mod = @import("arabic.zig");
const Buffer = common.Buffer;
const GlyphInfo = common.GlyphInfo;
const Cmap = common.Cmap;
const Tag = common.Tag;
const MapBuilder = map_mod.MapBuilder;
const Map = map_mod.Map;
const MapFeatureFlags = map_mod.MapFeatureFlags;
const ic_c = indic_mod.ic_c;
const ic_v = indic_mod.ic_v;
const ic_h = indic_mod.ic_h;
const ic_ra = indic_mod.ic_ra;
const ic_cs = indic_mod.ic_cs;
const ic_placeholder = indic_mod.ic_placeholder;
const ic_dottedcircle = indic_mod.ic_dottedcircle;
const indic_values = indic_mod.indic_values;
const indic_u8 = indic_mod.indic_u8;
const indicGetCategories = indic_mod.indicGetCategories;
const isIndicJoiner = indic_mod.isIndicJoiner;
const indicSortByPosition = indic_mod.indicSortByPosition;
const ip_pre_c = indic_mod.ip_pre_c;
const ip_pre_m = indic_mod.ip_pre_m;
const ip_base_c = indic_mod.ip_base_c;
const ip_after_main = indic_mod.ip_after_main;
const ip_below_c = indic_mod.ip_below_c;
const ip_before_sub = indic_mod.ip_before_sub;
const ip_after_sub = indic_mod.ip_after_sub;
const tag_rphf = indic_mod.tag_rphf;
const tag_pref = indic_mod.tag_pref;
const tag_blwf = indic_mod.tag_blwf;
const tag_abvf = indic_mod.tag_abvf;
const tag_pstf = indic_mod.tag_pstf;
const tag_pres = indic_mod.tag_pres;
const tag_abvs = indic_mod.tag_abvs;
const tag_blws = indic_mod.tag_blws;
const tag_psts = indic_mod.tag_psts;
const tag_liga = arabic_mod.tag_liga;
const tag_clig = arabic_mod.tag_clig;

// Ported from vendor/harfbuzz/src/hb-ot-shaper-khmer.cc +
// hb-ot-shaper-myanmar.cc; syllables come from hb's generated ragel
// tables (see syllable_machines.zig).
//
// Category/position values reuse the `ic_*`/`ip_*` constants the Indic
// section defines and `indicGetCategories`'s table directly - confirmed by
// reading hb-ot-shaper-khmer-machine.hh/myanmar-machine.hh's `#define
// khmer_category() ot_shaper_var_u8_category()` / `myanmar_category()` /
// `myanmar_position()`: these are literally the *same* per-glyph buffer-var
// slots Indic uses (`GlyphInfo.indic_category`/`indic_position`/
// `indic_syllable` here), just read under a different macro name, since
// hb never runs two complex shapers on one buffer. This port reuses those
// fields directly rather than adding khmer_category/myanmar_category
// fields that would just duplicate the same storage.
//
// Same architectural simplification as Indic: hb's real algorithm
// interleaves initial_reordering with per-basic-feature GSUB pauses; this
// port merges everything into one pre-GSUB pass (no pause machinery, see
// the module doc comment), and Khmer's `pref` mask-only "did it actually
// ligate" checks are approximated with pure Unicode-category syntax (a
// COENG+RO pair is always treated as a pref candidate) rather than a
// GSUB dry-run against the real font.
//
// Dotted-circle insertion for broken/malformed syllables runs via
// `common.insertDottedCircles` right after syllabification, same as the
// Indic section above.

pub const khmr_script_tag = Tag{ 'k', 'h', 'm', 'r' };
pub const mym2_script_tag = Tag{ 'm', 'y', 'm', '2' };
const tag_cfar = Tag{ 'c', 'f', 'a', 'r' };

/// Category values used only by Khmer/Myanmar in the shared generated
/// table (`indic_values`/`indic_u8`, see `indicGetCategories`) - the Indic
/// shaper's `ic_*` constants above cover every value the classic 9 Indic
/// scripts use, but Khmer/Myanmar reordering references several more.
const cat_vblw: u8 = 21;
const cat_vpre: u8 = 22;
/// Myanmar's "A" (Asat-adjacent vowel-killer mark); shares numeric value 9
/// with Indic's A/VD (see `ic_*`'s doc comment above `ic_x`).
const cat_a: u8 = 9;
const cat_as: u8 = 32;
const cat_mr: u8 = 36;
const cat_vs: u8 = 40;

const khmer_syllable_consonant: u8 = 0;
const khmer_syllable_broken: u8 = 1;
const khmer_syllable_non_khmer: u8 = 2;

pub fn collectFeaturesKhmer(map_builder: *MapBuilder) !void {
    const manual_joiners_syllable = MapFeatureFlags{ .manual_zwnj = true, .manual_zwj = true, .per_syllable = true };
    const manual_joiners = MapFeatureFlags{ .manual_zwnj = true, .manual_zwj = true };
    try map_builder.enableFeature(.{ 'l', 'o', 'c', 'l' }, .{ .per_syllable = true }, 1);
    try map_builder.enableFeature(.{ 'c', 'c', 'm', 'p' }, .{ .per_syllable = true }, 1);
    try map_builder.addFeature(tag_pref, manual_joiners_syllable, 1);
    try map_builder.addFeature(tag_blwf, manual_joiners_syllable, 1);
    try map_builder.addFeature(tag_abvf, manual_joiners_syllable, 1);
    try map_builder.addFeature(tag_pstf, manual_joiners_syllable, 1);
    try map_builder.addFeature(tag_cfar, manual_joiners_syllable, 1);
    try map_builder.addGsubPause(.none);
    try map_builder.enableFeature(tag_pres, manual_joiners, 1);
    try map_builder.enableFeature(tag_abvs, manual_joiners, 1);
    try map_builder.enableFeature(tag_blws, manual_joiners, 1);
    try map_builder.enableFeature(tag_psts, manual_joiners, 1);
}

/// Ported from `override_features_khmer`: Khmer's spec treats `clig` as a
/// required shaping feature, not an optional one, hence enabled here rather
/// than left to `default_features`'s ordinary global enable.
pub fn overrideFeaturesKhmer(map_builder: *MapBuilder) !void {
    try map_builder.enableFeature(tag_clig, .{}, 1);
    try map_builder.disableFeature(tag_liga);
}

/// Ported from `reorder_consonant_syllable`, called for both
/// `khmer_consonant_syllable` and `khmer_broken_cluster` syllable types
/// (matching `reorder_syllable_khmer`'s switch - broken clusters get the
/// same treatment since this port never inserts the dotted-circle
/// placeholder hb would have prepended first).
fn reorderKhmerSyllable(buffer: *Buffer, map: Map, start: usize, end: usize) void {
    const info = buffer.info.items;
    {
        const mask = map.get1Mask(tag_blwf) | map.get1Mask(tag_abvf) | map.get1Mask(tag_pstf);
        for (info[start + 1 .. end]) |*g| g.mask |= mask;
    }

    var num_coengs: usize = 0;
    var i = start + 1;
    while (i < end) : (i += 1) {
        if (info[i].indic_category == ic_h and num_coengs <= 2 and i + 1 < end) {
            num_coengs += 1;
            if (info[i + 1].indic_category == ic_ra) {
                info[i].mask |= map.get1Mask(tag_pref);
                info[i + 1].mask |= map.get1Mask(tag_pref);

                buffer.mergeClusters(start, i + 2);
                const t0 = info[i];
                const t1 = info[i + 1];
                var k = i;
                while (k > start) {
                    k -= 1;
                    info[k + 2] = info[k];
                }
                info[start] = t0;
                info[start + 1] = t1;

                if (map.get1Mask(tag_cfar) != 0) {
                    var j = i + 2;
                    while (j < end) : (j += 1) info[j].mask |= map.get1Mask(tag_cfar);
                }
                num_coengs = 2;
            }
        } else if (info[i].indic_category == cat_vpre) {
            buffer.mergeClusters(start, i + 1);
            const t = info[i];
            var k = i;
            while (k > start) {
                k -= 1;
                info[k + 1] = info[k];
            }
            info[start] = t;
        }
    }
}

/// Ported from `setup_masks_khmer` + `setup_syllables_khmer` +
/// `reorder_khmer`/`reorder_syllable_khmer`, collapsed into one pre-GSUB
/// pass at the same call site as `setupMasksIndic` (see that function's
/// doc comment for why).
pub fn setupMasksKhmer(buffer: *Buffer, map: Map, cmap: ?Cmap) !void {
    for (buffer.info.items) |*info| info.indic_category = @intCast(indicGetCategories(info.codepoint) & 0xFF);
    indic_mod.findSyllables(buffer.info.items, syllable_machines.khmer);
    _ = try common.insertDottedCircles(buffer, cmap, khmer_syllable_broken, ic_dottedcircle, null, null, false);

    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const syl = buffer.info.items[start].indic_syllable;
        var end = start + 1;
        while (end < buffer.info.items.len and buffer.info.items[end].indic_syllable == syl) end += 1;
        buffer.unsafeToBreak(start, end);

        const stype = syl & 0x0F;
        if (stype == khmer_syllable_consonant or stype == khmer_syllable_broken) {
            reorderKhmerSyllable(buffer, map, start, end);
        }
        start = end;
    }
}

fn isConsonantMyanmar(info: GlyphInfo) bool {
    const cat = info.indic_category;
    return cat == ic_c or cat == ic_cs or cat == ic_ra or cat == ic_v or cat == ic_placeholder or cat == ic_dottedcircle;
}

const myanmar_syllable_consonant: u8 = 0;
const myanmar_syllable_broken: u8 = 1;

/// Ported from `collect_features_myanmar`: unlike Khmer/Indic's basic
/// features, hb's real Myanmar shaper enables `rphf`/`pref`/`blwf`/`pstf`
/// *globally* (no per-glyph mask array, no `get_1_mask` calls anywhere in
/// hb-ot-shaper-myanmar.cc) - correctness here comes entirely from glyph
/// reordering before these lookups apply, not from masking. Only
/// `F_MANUAL_ZWJ` is set (not `F_MANUAL_ZWNJ`, unlike Khmer/Indic), matching
/// hb's flags exactly.
pub fn collectFeaturesMyanmar(map_builder: *MapBuilder) !void {
    const manual_zwj_syllable = MapFeatureFlags{ .manual_zwj = true, .per_syllable = true };
    const manual_zwj = MapFeatureFlags{ .manual_zwj = true };
    try map_builder.enableFeature(.{ 'l', 'o', 'c', 'l' }, .{ .per_syllable = true }, 1);
    try map_builder.enableFeature(.{ 'c', 'c', 'm', 'p' }, .{ .per_syllable = true }, 1);
    try map_builder.addGsubPause(.myanmar_reorder);
    for ([_]Tag{ tag_rphf, tag_pref, tag_blwf, tag_pstf }) |tag| {
        try map_builder.enableFeature(tag, manual_zwj_syllable, 1);
        try map_builder.addGsubPause(.none);
    }
    try map_builder.addGsubPause(.none);
    try map_builder.enableFeature(tag_pres, manual_zwj, 1);
    try map_builder.enableFeature(tag_abvs, manual_zwj, 1);
    try map_builder.enableFeature(tag_blws, manual_zwj, 1);
    try map_builder.enableFeature(tag_psts, manual_zwj, 1);
}

/// Ported from `initial_reordering_consonant_syllable`. Reuses
/// `indicSortByPosition` (the Indic section's stable insertion sort) since
/// Myanmar's `compare_myanmar_order` is the same "sort by position enum"
/// comparator over the same shared `indic_position` field.
fn reorderMyanmarSyllable(buffer: *Buffer, start: usize, end: usize) void {
    const info = buffer.info.items;

    var base: usize = end;
    var has_reph = false;
    var limit = start;
    if (start + 3 <= end and info[start].indic_category == ic_ra and info[start + 1].indic_category == cat_as and info[start + 2].indic_category == ic_h) {
        limit = start + 3;
        base = start;
        has_reph = true;
    }
    if (!has_reph) base = limit;
    {
        var i = limit;
        while (i < end) : (i += 1) {
            if (isConsonantMyanmar(info[i])) {
                base = i;
                break;
            }
        }
    }

    var i: usize = start;
    {
        const reph_count: usize = if (has_reph) 3 else 0;
        while (i < start + reph_count) : (i += 1) info[i].indic_position = ip_after_main;
    }
    while (i < base) : (i += 1) info[i].indic_position = ip_pre_c;
    if (i < end) {
        info[i].indic_position = ip_base_c;
        i += 1;
    }
    var pos: u8 = ip_after_main;
    while (i < end) : (i += 1) {
        if (info[i].indic_category == cat_mr) {
            info[i].indic_position = ip_pre_c;
            continue;
        }
        if (info[i].indic_category == cat_vpre) {
            info[i].indic_position = ip_pre_m;
            continue;
        }
        if (info[i].indic_category == cat_vs) {
            info[i].indic_position = info[i - 1].indic_position;
            continue;
        }
        if (pos == ip_after_main and info[i].indic_category == cat_vblw) {
            pos = ip_below_c;
            info[i].indic_position = pos;
            continue;
        }
        if (pos == ip_below_c and info[i].indic_category == cat_a) {
            info[i].indic_position = ip_before_sub;
            continue;
        }
        if (pos == ip_below_c and info[i].indic_category == cat_vblw) {
            info[i].indic_position = pos;
            continue;
        }
        if (pos == ip_below_c and info[i].indic_category != cat_a) {
            pos = ip_after_sub;
            info[i].indic_position = pos;
            continue;
        }
        info[i].indic_position = pos;
    }

    indicSortByPosition(info, start, end);

    var first_left_matra = end;
    var last_left_matra = end;
    for (start..end) |k| {
        if (info[k].indic_position == ip_pre_m) {
            if (first_left_matra == end) first_left_matra = k;
            last_left_matra = k;
        }
    }
    if (first_left_matra < last_left_matra) {
        buffer.reverseRange(first_left_matra, last_left_matra + 1);
        var ii = first_left_matra;
        var j = ii;
        while (j <= last_left_matra) : (j += 1) {
            if (info[j].indic_category == cat_vpre) {
                buffer.reverseRange(ii, j + 1);
                ii = j + 1;
            }
        }
    }
}

/// Ported from `setup_masks_myanmar` + `setup_syllables_myanmar` +
/// `reorder_myanmar`/`reorder_syllable_myanmar`, collapsed into one
/// pre-GSUB pass same as Khmer/Indic above. No `Map` parameter needed -
/// unlike Khmer/Indic, hb's real Myanmar shaper does no per-glyph feature
/// masking here (see `collectFeaturesMyanmar`'s doc comment).
pub fn setupMasksMyanmar(buffer: *Buffer) void {
    for (buffer.info.items) |*info| info.indic_category = @intCast(indicGetCategories(info.codepoint) & 0xFF);
    indic_mod.findSyllables(buffer.info.items, syllable_machines.myanmar);
    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const end = syllableEnd(buffer.info.items, start);
        buffer.unsafeToBreak(start, end);
        start = end;
    }
}

/// Ported from `reorder_myanmar`: the GSUB pause after `locl`/`ccmp`.
pub fn reorderMyanmar(buffer: *Buffer, cmap: ?Cmap) !void {
    _ = try common.insertDottedCircles(buffer, cmap, myanmar_syllable_broken, ic_dottedcircle, null, null, true);
    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const end = syllableEnd(buffer.info.items, start);
        const stype = buffer.info.items[start].indic_syllable & 0x0F;
        if (stype == myanmar_syllable_consonant or stype == myanmar_syllable_broken) {
            reorderMyanmarSyllable(buffer, start, end);
        }
        start = end;
    }
}

fn syllableEnd(info: []const GlyphInfo, start: usize) usize {
    var end = start + 1;
    while (end < info.len and info[end].indic_syllable == info[start].indic_syllable) end += 1;
    return end;
}
