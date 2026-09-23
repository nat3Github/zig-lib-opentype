// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const unicode = @import("../unicode.zig");
const common = @import("common.zig");
const map_mod = @import("map.zig");
const arabic_mod = @import("arabic.zig");
const indic_mod = @import("indic.zig");
const syllable_machines = @import("syllable_machines.zig");
const Buffer = common.Buffer;
const GlyphInfo = common.GlyphInfo;
const Cmap = common.Cmap;
const Tag = common.Tag;
const MapBuilder = map_mod.MapBuilder;
const Map = map_mod.Map;
const MapFeatureFlags = map_mod.MapFeatureFlags;

// Ported from vendor/harfbuzz/src/hb-ot-shaper-use.cc +
// hb-ot-shaper-use-machine.rl (pinned 703e2d1441): the Universal Shaping
// Engine, hb's catch-all shaper for ~30 scripts not covered by the classic
// Indic/Khmer/Myanmar shapers (Sinhala, Tibetan, Javanese, Balinese,
// Mongolian, Meetei Mayek, and many more - see MS's USE spec at
// https://docs.microsoft.com/en-us/typography/script-development/use).
//
// Category data (`unicode.useCategory`) is generated fresh from UCD source
// files by test/fixtures/unicode/gen/gen_use_categories.py - a verbatim,
// packTab-free port of gen-use-table.py's derivation logic, run one step
// *before* hb's packTab table compression, specifically to avoid the class
// of silent bug the Indic shaper's compressed-table-decode approach hit
// once (see [[project_opentype_renderer_plan]]). See that script's module
// doc comment for the full reasoning.
//
// Syllabification (`findSyllablesUse`) runs hb's generated ragel tables
// from hb-ot-shaper-use-machine.hh (see syllable_machines.zig).
//
// Reordering (`reorderUseSyllable`) is hb's `reorder_syllable_use` ported
// directly - it's simpler than Indic's (no base-consonant search, no
// reph-position-mode table), just two passes: move a leading REPHA (R)
// forward past post-base glyphs/halant, then move any VPre/VMPre glyph
// back to just after the last halant seen so far (or to the syllable
// start).
//
// Scope notes:
//   - hieroglyph_cluster's own script (Egyptian Hieroglyphs) needs no
//     reordering (not in reorder_syllable_use's applicable-type list) and
//     no basic-feature masking beyond what's already registered, so no
//     extra hieroglyph-specific code exists here beyond syllabification.
//
// Dispatch is the same "caller supplies the tag" stand-in used by every
// other complex shaper in this file. `use_script_tags` is the full list of
// OpenType script tags hb's `hb_ot_shaper_categorize` (hb-ot-shaper.hh)
// routes to the USE shaper - every entry in that switch's big trailing
// `case` block (Tibetan through Tolong Siki, Unicode 2.0 through 17.0
// additions), transcribed via each script's ISO 15924 tag in
// hb-script-list.h. Indic/Khmer/Myanmar/Hangul/Thai/Lao/Arabic/Syriac/
// Hebrew have their own dedicated shapers and are dispatched separately
// (see `shapeImpl` in shaping.zig), so they're deliberately absent here
// even though some (e.g. Mongolian, Sinhala) sit in the same hb switch arm.
pub const tibt_script_tag = Tag{ 't', 'i', 'b', 't' };
pub const mong_script_tag = Tag{ 'm', 'o', 'n', 'g' };
pub const sinh_script_tag = Tag{ 's', 'i', 'n', 'h' };
pub const buhd_script_tag = Tag{ 'b', 'u', 'h', 'd' };
pub const hano_script_tag = Tag{ 'h', 'a', 'n', 'o' };
pub const tglg_script_tag = Tag{ 't', 'g', 'l', 'g' };
pub const tagb_script_tag = Tag{ 't', 'a', 'g', 'b' };
pub const limb_script_tag = Tag{ 'l', 'i', 'm', 'b' };
pub const tale_script_tag = Tag{ 't', 'a', 'l', 'e' };
pub const bugi_script_tag = Tag{ 'b', 'u', 'g', 'i' };
pub const khar_script_tag = Tag{ 'k', 'h', 'a', 'r' };
pub const sylo_script_tag = Tag{ 's', 'y', 'l', 'o' };
pub const tfng_script_tag = Tag{ 't', 'f', 'n', 'g' };
pub const bali_script_tag = Tag{ 'b', 'a', 'l', 'i' };
pub const nkoo_script_tag = Tag{ 'n', 'k', 'o', ' ' };
pub const phag_script_tag = Tag{ 'p', 'h', 'a', 'g' };
pub const cham_script_tag = Tag{ 'c', 'h', 'a', 'm' };
pub const kali_script_tag = Tag{ 'k', 'a', 'l', 'i' };
pub const lepc_script_tag = Tag{ 'l', 'e', 'p', 'c' };
pub const rjng_script_tag = Tag{ 'r', 'j', 'n', 'g' };
pub const saur_script_tag = Tag{ 's', 'a', 'u', 'r' };
pub const sund_script_tag = Tag{ 's', 'u', 'n', 'd' };
pub const egyp_script_tag = Tag{ 'e', 'g', 'y', 'p' };
pub const java_script_tag = Tag{ 'j', 'a', 'v', 'a' };
pub const kthi_script_tag = Tag{ 'k', 't', 'h', 'i' };
pub const mtei_script_tag = Tag{ 'm', 't', 'e', 'i' };
pub const lana_script_tag = Tag{ 'l', 'a', 'n', 'a' };
pub const tavt_script_tag = Tag{ 't', 'a', 'v', 't' };
pub const batk_script_tag = Tag{ 'b', 'a', 't', 'k' };
pub const brah_script_tag = Tag{ 'b', 'r', 'a', 'h' };
pub const mand_script_tag = Tag{ 'm', 'a', 'n', 'd' };
pub const cakm_script_tag = Tag{ 'c', 'a', 'k', 'm' };
pub const plrd_script_tag = Tag{ 'p', 'l', 'r', 'd' };
pub const shrd_script_tag = Tag{ 's', 'h', 'r', 'd' };
pub const takr_script_tag = Tag{ 't', 'a', 'k', 'r' };
pub const dupl_script_tag = Tag{ 'd', 'u', 'p', 'l' };
pub const gran_script_tag = Tag{ 'g', 'r', 'a', 'n' };
pub const khoj_script_tag = Tag{ 'k', 'h', 'o', 'j' };
pub const sind_script_tag = Tag{ 's', 'i', 'n', 'd' };
pub const mahj_script_tag = Tag{ 'm', 'a', 'h', 'j' };
pub const mani_script_tag = Tag{ 'm', 'a', 'n', 'i' };
pub const modi_script_tag = Tag{ 'm', 'o', 'd', 'i' };
pub const hmng_script_tag = Tag{ 'h', 'm', 'n', 'g' };
pub const phlp_script_tag = Tag{ 'p', 'h', 'l', 'p' };
pub const sidd_script_tag = Tag{ 's', 'i', 'd', 'd' };
pub const tirh_script_tag = Tag{ 't', 'i', 'r', 'h' };
pub const ahom_script_tag = Tag{ 'a', 'h', 'o', 'm' };
pub const mult_script_tag = Tag{ 'm', 'u', 'l', 't' };
pub const adlm_script_tag = Tag{ 'a', 'd', 'l', 'm' };
pub const bhks_script_tag = Tag{ 'b', 'h', 'k', 's' };
pub const marc_script_tag = Tag{ 'm', 'a', 'r', 'c' };
pub const newa_script_tag = Tag{ 'n', 'e', 'w', 'a' };
pub const gonm_script_tag = Tag{ 'g', 'o', 'n', 'm' };
pub const soyo_script_tag = Tag{ 's', 'o', 'y', 'o' };
pub const zanb_script_tag = Tag{ 'z', 'a', 'n', 'b' };
pub const dogr_script_tag = Tag{ 'd', 'o', 'g', 'r' };
pub const gong_script_tag = Tag{ 'g', 'o', 'n', 'g' };
pub const rohg_script_tag = Tag{ 'r', 'o', 'h', 'g' };
pub const maka_script_tag = Tag{ 'm', 'a', 'k', 'a' };
pub const medf_script_tag = Tag{ 'm', 'e', 'd', 'f' };
pub const sogo_script_tag = Tag{ 's', 'o', 'g', 'o' };
pub const sogd_script_tag = Tag{ 's', 'o', 'g', 'd' };
pub const elym_script_tag = Tag{ 'e', 'l', 'y', 'm' };
pub const nand_script_tag = Tag{ 'n', 'a', 'n', 'd' };
pub const hmnp_script_tag = Tag{ 'h', 'm', 'n', 'p' };
pub const wcho_script_tag = Tag{ 'w', 'c', 'h', 'o' };
pub const chrs_script_tag = Tag{ 'c', 'h', 'r', 's' };
pub const diak_script_tag = Tag{ 'd', 'i', 'a', 'k' };
pub const kits_script_tag = Tag{ 'k', 'i', 't', 's' };
pub const yezi_script_tag = Tag{ 'y', 'e', 'z', 'i' };
pub const cpmn_script_tag = Tag{ 'c', 'p', 'm', 'n' };
pub const ougr_script_tag = Tag{ 'o', 'u', 'g', 'r' };
pub const tnsa_script_tag = Tag{ 't', 'n', 's', 'a' };
pub const toto_script_tag = Tag{ 't', 'o', 't', 'o' };
pub const vith_script_tag = Tag{ 'v', 'i', 't', 'h' };
pub const kawi_script_tag = Tag{ 'k', 'a', 'w', 'i' };
pub const nagm_script_tag = Tag{ 'n', 'a', 'g', 'm' };
pub const gara_script_tag = Tag{ 'g', 'a', 'r', 'a' };
pub const gukh_script_tag = Tag{ 'g', 'u', 'k', 'h' };
pub const krai_script_tag = Tag{ 'k', 'r', 'a', 'i' };
pub const onao_script_tag = Tag{ 'o', 'n', 'a', 'o' };
pub const sunu_script_tag = Tag{ 's', 'u', 'n', 'u' };
pub const todr_script_tag = Tag{ 't', 'o', 'd', 'r' };
pub const tutg_script_tag = Tag{ 't', 'u', 't', 'g' };
pub const berf_script_tag = Tag{ 'b', 'e', 'r', 'f' };
pub const sidt_script_tag = Tag{ 's', 'i', 'd', 't' };
pub const tayo_script_tag = Tag{ 't', 'a', 'y', 'o' };
pub const tols_script_tag = Tag{ 't', 'o', 'l', 's' };

pub const use_script_tags = [_]Tag{
    tibt_script_tag, mong_script_tag, sinh_script_tag, buhd_script_tag,
    hano_script_tag, tglg_script_tag, tagb_script_tag, limb_script_tag,
    tale_script_tag, bugi_script_tag, khar_script_tag, sylo_script_tag,
    tfng_script_tag, bali_script_tag, nkoo_script_tag, phag_script_tag,
    cham_script_tag, kali_script_tag, lepc_script_tag, rjng_script_tag,
    saur_script_tag, sund_script_tag, egyp_script_tag, java_script_tag,
    kthi_script_tag, mtei_script_tag, lana_script_tag, tavt_script_tag,
    batk_script_tag, brah_script_tag, mand_script_tag, cakm_script_tag,
    plrd_script_tag, shrd_script_tag, takr_script_tag, dupl_script_tag,
    gran_script_tag, khoj_script_tag, sind_script_tag, mahj_script_tag,
    mani_script_tag, modi_script_tag, hmng_script_tag, phlp_script_tag,
    sidd_script_tag, tirh_script_tag, ahom_script_tag, mult_script_tag,
    adlm_script_tag, bhks_script_tag, marc_script_tag, newa_script_tag,
    gonm_script_tag, soyo_script_tag, zanb_script_tag, dogr_script_tag,
    gong_script_tag, rohg_script_tag, maka_script_tag, medf_script_tag,
    sogo_script_tag, sogd_script_tag, elym_script_tag, nand_script_tag,
    hmnp_script_tag, wcho_script_tag, chrs_script_tag, diak_script_tag,
    kits_script_tag, yezi_script_tag, cpmn_script_tag, ougr_script_tag,
    tnsa_script_tag, toto_script_tag, vith_script_tag, kawi_script_tag,
    nagm_script_tag, gara_script_tag, gukh_script_tag, krai_script_tag,
    onao_script_tag, sunu_script_tag, todr_script_tag, tutg_script_tag,
    berf_script_tag, sidt_script_tag, tayo_script_tag, tols_script_tag,
};

/// Ported from `has_arabic_joining` (hb-ot-shaper-arabic-joining-list.hh),
/// restricted to the scripts that dispatch to USE rather than the dedicated
/// Arabic shaper (arab/syrc are excluded - see `shapeImpl` in shaping.zig).
/// Scripts in this list get the Arabic cursive-joining state machine
/// (`arabic_mod.setupMasksArabic`) instead of `setupTopographicalMasksUse`.
pub const use_arabic_joining_script_tags = [_]Tag{
    mand_script_tag, mani_script_tag, mong_script_tag, nkoo_script_tag,
    phlp_script_tag, adlm_script_tag, rohg_script_tag, sogd_script_tag,
    chrs_script_tag, ougr_script_tag, phag_script_tag,
};

const tag_nukt = Tag{ 'n', 'u', 'k', 't' };
const tag_akhn = Tag{ 'a', 'k', 'h', 'n' };
const tag_rphf = Tag{ 'r', 'p', 'h', 'f' };
const tag_pref = Tag{ 'p', 'r', 'e', 'f' };
const tag_rkrf = Tag{ 'r', 'k', 'r', 'f' };
const tag_abvf = Tag{ 'a', 'b', 'v', 'f' };
const tag_blwf = Tag{ 'b', 'l', 'w', 'f' };
const tag_half = Tag{ 'h', 'a', 'l', 'f' };
const tag_pstf = Tag{ 'p', 's', 't', 'f' };
const tag_vatu = Tag{ 'v', 'a', 't', 'u' };
const tag_cjct = Tag{ 'c', 'j', 'c', 't' };
const tag_abvs = Tag{ 'a', 'b', 'v', 's' };
const tag_blws = Tag{ 'b', 'l', 'w', 's' };
const tag_haln = Tag{ 'h', 'a', 'l', 'n' };
const tag_pres = Tag{ 'p', 'r', 'e', 's' };
const tag_psts = Tag{ 'p', 's', 't', 's' };

/// Same order as `joining_form_t` (ISOL/INIT/MEDI/FINA) - indexes both this
/// array and `setupTopographicalMasksUse`'s `masks`/`last_form`.
const use_topographical_features = [4]Tag{
    .{ 'i', 's', 'o', 'l' },
    .{ 'i', 'n', 'i', 't' },
    .{ 'm', 'e', 'd', 'i' },
    .{ 'f', 'i', 'n', 'a' },
};
const joining_form_isol: u8 = 0;
const joining_form_init: u8 = 1;
const joining_form_medi: u8 = 2;
const joining_form_fina: u8 = 3;
const joining_form_none: u8 = 4;

// Category values transcribed directly from hb-ot-shaper-use-machine.rl's
// `export X = N;` lines - must match gen_use_categories.py's
// USE_CATEGORY_CODE exactly, since that script's output (unicode.useCategory)
// is what populates `GlyphInfo.indic_category` (reused storage, not a new
// field - same convention the Khmer/Myanmar section already established)
// for this shaper.
const B: u8 = 1;
const N: u8 = 4;
const H: u8 = 12;
const ZWNJ: u8 = 14;
const R: u8 = 18;
const IS: u8 = 44;
const HVM: u8 = 53;
const FAbv: u8 = 24;
const FBlw: u8 = 25;
const FPst: u8 = 26;
const MAbv: u8 = 27;
const MBlw: u8 = 28;
const MPst: u8 = 29;
const MPre: u8 = 30;
const VAbv: u8 = 33;
const VBlw: u8 = 34;
const VPst: u8 = 35;
const VPre: u8 = 22;
const VMAbv: u8 = 37;
const VMBlw: u8 = 38;
const VMPst: u8 = 39;
const VMPre: u8 = 23;
const FMAbv: u8 = 45;
const FMBlw: u8 = 46;
const FMPst: u8 = 47;

/// Same order as `use_syllable_type_t` in hb-ot-shaper-use-machine.rl.
const use_virama_terminated_cluster: u8 = 0;
const use_sakot_terminated_cluster: u8 = 1;
const use_standard_cluster: u8 = 2;
const use_number_joiner_terminated_cluster: u8 = 3;
const use_numeral_cluster: u8 = 4;
const use_symbol_cluster: u8 = 5;
const use_hieroglyph_cluster: u8 = 6;
const use_broken_cluster: u8 = 7;
const use_non_cluster: u8 = 8;

/// Ported from `find_syllables_use`. Requires `GlyphInfo.indic_category`
/// to already hold each glyph's USE category (via `unicode.useCategory`).
fn findSyllablesUse(buffer: *Buffer) !void {
    const info = buffer.info.items;
    if (!hasMachineHiddenGlyph(info)) return indic_mod.findSyllables(info, syllable_machines.use);

    // hb runs the machine over a filtered view; each syllable then spans
    // original indices up to the next visible glyph, hidden ones included.
    const visible_index = try buffer.allocator.alloc(usize, info.len);
    defer buffer.allocator.free(visible_index);
    const visible = try buffer.allocator.alloc(GlyphInfo, info.len);
    defer buffer.allocator.free(visible);
    var visible_count: usize = 0;
    for (info, 0..) |glyph_info, i| {
        if (hiddenFromMachine(info, i)) continue;
        visible_index[visible_count] = i;
        visible[visible_count] = glyph_info;
        visible_count += 1;
    }
    indic_mod.findSyllables(visible[0..visible_count], syllable_machines.use);
    for (info[0..if (visible_count == 0) info.len else visible_index[0]]) |*glyph_info| glyph_info.indic_syllable = 0;
    for (0..visible_count) |v| {
        const range_end = if (v + 1 < visible_count) visible_index[v + 1] else info.len;
        for (info[visible_index[v]..range_end]) |*glyph_info| glyph_info.indic_syllable = visible[v].indic_syllable;
    }
}

const CGJ: u8 = 6;

/// `find_syllables_use`'s two `hb_filter`s: CGJ, and a ZWNJ whose next
/// non-CGJ glyph is a mark.
fn hiddenFromMachine(info: []const GlyphInfo, i: usize) bool {
    if (info[i].indic_category == CGJ) return true;
    if (info[i].indic_category != ZWNJ) return false;
    for (info[i + 1 ..]) |next| {
        if (next.indic_category != CGJ) return unicode.isUnicodeMark(@intCast(next.codepoint));
    }
    return false;
}

fn hasMachineHiddenGlyph(info: []const GlyphInfo) bool {
    for (0..info.len) |i| if (hiddenFromMachine(info, i)) return true;
    return false;
}

fn isPostBaseUse(cat: u8) bool {
    return switch (cat) {
        FAbv, FBlw, FPst, FMAbv, FMBlw, FMPst, MAbv, MBlw, MPst, MPre, VAbv, VBlw, VPst, VPre, VMAbv, VMBlw, VMPst, VMPre => true,
        else => false,
    };
}

fn isHalantUse(glyph_info: GlyphInfo) bool {
    const cat = glyph_info.indic_category;
    return (cat == H or cat == HVM or cat == IS) and !glyph_info.is_ligated;
}

/// Ported from `reorder_syllable_use`: only fires for the 5 syllable types
/// hb's own `FLAG_UNSAFE` mask in `reorder_syllable_use` lists (virama/
/// sakot-terminated, standard, symbol, broken - not number-joiner/numeral/
/// hieroglyph/non-cluster). Two independent passes: move a leading REPHA
/// forward past post-base glyphs/halant, then move any VPre/VMPre glyph
/// back to just after the last halant seen so far.
fn reorderUseSyllable(buffer: *Buffer, start: usize, end: usize, stype: u8) void {
    if (!(stype == use_virama_terminated_cluster or stype == use_sakot_terminated_cluster or
        stype == use_standard_cluster or stype == use_symbol_cluster or stype == use_broken_cluster))
        return;

    const info = buffer.info.items;

    if (info[start].indic_category == R and end - start > 1) {
        var i = start + 1;
        while (i < end) : (i += 1) {
            const is_post_base = isPostBaseUse(info[i].indic_category) or isHalantUse(info[i]);
            if (is_post_base or i == end - 1) {
                const target = if (is_post_base) i - 1 else i;
                buffer.mergeClusters(start, target + 1);
                const tmp = info[start];
                var k = start;
                while (k < target) : (k += 1) info[k] = info[k + 1];
                info[target] = tmp;
                break;
            }
        }
    }

    var j = start;
    var i = start;
    while (i < end) : (i += 1) {
        if (isHalantUse(info[i])) {
            j = i + 1;
        } else if ((info[i].indic_category == VPre or info[i].indic_category == VMPre) and
            // Only the first component of a MultipleSubst moves.
            info[i].lig_comp == 0 and j < i)
        {
            buffer.mergeClusters(j, i + 1);
            const tmp = info[i];
            var k = i;
            while (k > j) : (k -= 1) info[k] = info[k - 1];
            info[j] = tmp;
        }
    }
}

/// Ported from `collect_features_use`. The reordering pause runs after the
/// basic features, so a glyph `pref`/`rphf` substituted can be reclassified
/// (`recordPrefUse`/`recordRphfUse`) before `reorderUse` moves it.
pub fn collectFeaturesUse(map_builder: *MapBuilder) !void {
    const per_syllable = MapFeatureFlags{ .per_syllable = true };
    const manual_zwj_per_syllable = MapFeatureFlags{ .manual_zwj = true, .per_syllable = true };
    try map_builder.enableFeature(.{ 'l', 'o', 'c', 'l' }, per_syllable, 1);
    try map_builder.enableFeature(.{ 'c', 'c', 'm', 'p' }, per_syllable, 1);
    try map_builder.enableFeature(tag_nukt, per_syllable, 1);
    try map_builder.enableFeature(tag_akhn, manual_zwj_per_syllable, 1);

    try map_builder.addGsubPause(.clear_substitution_flags);
    try map_builder.addFeature(tag_rphf, manual_zwj_per_syllable, 1);
    try map_builder.addGsubPause(.use_record_rphf);
    try map_builder.addGsubPause(.clear_substitution_flags);
    try map_builder.enableFeature(tag_pref, manual_zwj_per_syllable, 1);
    try map_builder.addGsubPause(.use_record_pref);

    for ([_]Tag{ tag_rkrf, tag_abvf, tag_blwf, tag_half, tag_pstf, tag_vatu, tag_cjct }) |tag|
        try map_builder.enableFeature(tag, manual_zwj_per_syllable, 1);
    try map_builder.addGsubPause(.use_reorder);
    try map_builder.addGsubPause(.none);

    for (use_topographical_features) |tag| try map_builder.addFeature(tag, .{}, 1);
    try map_builder.addGsubPause(.none);

    for ([_]Tag{ tag_abvs, tag_blws, tag_haln, tag_pres, tag_psts }) |tag|
        try map_builder.enableFeature(tag, .{ .manual_zwj = true }, 1);
}

/// Ported from `setup_topographical_masks`: for USE scripts without Arabic-
/// style cursive joining data (`setupMasksUse`'s `is_arabic_joining ==
/// false` case), fakes isol/init/medi/fina joining forms purely from
/// syllable adjacency - each syllable starts ISOL; if the previous syllable
/// was left ISOL/FINA (i.e. still "open"), this syllable continues it
/// (becomes FINA, and the previous syllable is rewritten INIT/MEDI).
/// Hieroglyph and non-cluster syllables never join and reset the chain.
fn setupTopographicalMasksUse(buffer: *Buffer, map: Map) void {
    var masks: [4]u32 = undefined;
    var all_masks: u32 = 0;
    for (use_topographical_features, 0..) |tag, i| {
        masks[i] = map.get1Mask(tag);
        all_masks |= masks[i];
    }
    if (all_masks == 0) return;
    const other_masks = ~all_masks;

    const info = buffer.info.items;
    var last_start: usize = 0;
    var last_form: u8 = joining_form_none;

    var start: usize = 0;
    while (start < info.len) {
        const syl = info[start].indic_syllable;
        var end = start + 1;
        while (end < info.len and info[end].indic_syllable == syl) end += 1;

        switch (syl & 0x0F) {
            use_hieroglyph_cluster, use_non_cluster => last_form = joining_form_none,
            else => {
                const join = last_form == joining_form_fina or last_form == joining_form_isol;
                if (join) {
                    last_form = if (last_form == joining_form_fina) joining_form_medi else joining_form_init;
                    for (info[last_start..start]) |*gi| gi.mask = (gi.mask & other_masks) | masks[last_form];
                }
                last_form = if (join) joining_form_fina else joining_form_isol;
                for (info[start..end]) |*gi| gi.mask = (gi.mask & other_masks) | masks[last_form];
            },
        }

        last_start = start;
        start = end;
    }
}

/// Ported from `setup_masks_use` + `setup_rphf_mask` (folded together,
/// same "no pause machinery" simplification the Indic section uses):
/// classifies every glyph's USE category, syllabifies, masks the first
/// glyph (or first up-to-3 glyphs, matching hb) of each syllable for the
/// `rphf` feature, then reorders each syllable in place.
///
/// `is_arabic_joining` mirrors hb's `use_shape_plan_t::arabic_plan`: scripts
/// with Arabic-style cursive joining data (Mongolian, Phags-pa, ... - see
/// `use_arabic_joining_script_tags`) get isol/init/medi/fina assigned by
/// the Arabic joining-type state machine instead of the syllable-adjacency
/// fallback above (mutually exclusive, same as hb's early return in
/// `setup_topographical_masks`). The state machine reads raw codepoints, so
/// it must run before `codepoint` is overwritten with glyph ids.
pub fn setupMasksUse(buffer: *Buffer, map: Map, is_arabic_joining: bool) !void {
    if (is_arabic_joining) arabic_mod.setupMasksArabic(buffer, map);

    for (buffer.info.items) |*info| info.indic_category = unicode.useCategory(@intCast(info.codepoint));
    try findSyllablesUse(buffer);
    if (!is_arabic_joining) setupTopographicalMasksUse(buffer, map);

    const rphf_mask = map.get1Mask(tag_rphf);

    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const syl = buffer.info.items[start].indic_syllable;
        var end = start + 1;
        while (end < buffer.info.items.len and buffer.info.items[end].indic_syllable == syl) end += 1;
        buffer.unsafeToBreak(start, end);

        if (rphf_mask != 0) {
            const limit: usize = if (buffer.info.items[start].indic_category == R) 1 else @min(3, end - start);
            var i = start;
            while (i < start + limit) : (i += 1) buffer.info.items[i].mask |= rphf_mask;
        }
        start = end;
    }
}

/// Ported from `record_rphf_use`: a glyph `rphf` substituted is a repha.
pub fn recordRphfUse(buffer: *Buffer, map: Map) void {
    const rphf_mask = map.get1Mask(tag_rphf);
    if (rphf_mask == 0) return;
    const info = buffer.info.items;
    var start: usize = 0;
    while (start < info.len) {
        const end = syllableEnd(info, start);
        var i = start;
        while (i < end and info[i].mask & rphf_mask != 0) : (i += 1) {
            if (info[i].is_substituted) {
                info[i].indic_category = R;
                break;
            }
        }
        start = end;
    }
}

/// Ported from `record_pref_use`: a glyph `pref` substituted behaves as VPre.
pub fn recordPrefUse(buffer: *Buffer) void {
    const info = buffer.info.items;
    var start: usize = 0;
    while (start < info.len) {
        const end = syllableEnd(info, start);
        for (info[start..end]) |*glyph_info| {
            if (glyph_info.is_substituted) {
                glyph_info.indic_category = VPre;
                break;
            }
        }
        start = end;
    }
}

/// Ported from `reorder_use`.
pub fn reorderUse(buffer: *Buffer, cmap: ?Cmap) !void {
    _ = try common.insertDottedCircles(buffer, cmap, use_broken_cluster, B, R, null, true);
    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const end = syllableEnd(buffer.info.items, start);
        reorderUseSyllable(buffer, start, end, buffer.info.items[start].indic_syllable & 0x0F);
        start = end;
    }
}

fn syllableEnd(info: []const GlyphInfo, start: usize) usize {
    var end = start + 1;
    while (end < info.len and info[end].indic_syllable == info[start].indic_syllable) end += 1;
    return end;
}
