const std = @import("std");
const unicode = @import("../unicode.zig");
const common = @import("common.zig");
const map_mod = @import("map.zig");
const arabic_mod = @import("arabic.zig");
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
// Syllabification (`findSyllablesUse`) hand-ports the Ragel scanner
// grammar in hb-ot-shaper-use-machine.rl (not the generated .hh state
// tables, an unreadable merged DFA) as a greedy longest-match recursive
// matcher, same technique as the Indic/Khmer/Myanmar sections use for
// their own `.rl` grammars.
//
// Reordering (`reorderUseSyllable`) is hb's `reorder_syllable_use` ported
// directly - it's simpler than Indic's (no base-consonant search, no
// reph-position-mode table), just two passes: move a leading REPHA (R)
// forward past post-base glyphs/halant, then move any VPre/VMPre glyph
// back to just after the last halant seen so far (or to the syllable
// start).
//
// Scope cuts, same bucket as the ones already documented in the Indic
// section above:
//   - `record_rphf_use`/`record_pref_use` (post-GSUB-substitution
//     reclassification of a repha/pref glyph, needed for hb's real
//     pause-interleaved pipeline) aren't ported - this port's MapBuilder
//     has no GSUB-pause machinery (pre-existing scope cut), so, like
//     Indic, GSUB features are masked on and left to fire without a
//     would-substitute-style dry-run gate.
//   - dotted-circle insertion for broken/malformed syllables runs via
//     `common.insertDottedCircles` right after syllabification, since this
//     port has no GSUB-pause machinery to run it mid-pipeline like hb does.
//   - `setup_topographical_masks` (isol/init/medi/fina joining-form
//     features, needed by the small subset of USE scripts written with
//     Arabic-style cursive joining, e.g. Mongolian/Phags-pa) isn't
//     ported - out of scope for this session, a self-contained follow-up
//     if Mongolian/Phags-pa shaping quality matters later.
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
pub const nkoo_script_tag = Tag{ 'n', 'k', 'o', 'o' };
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
const O: u8 = 0;
const B: u8 = 1;
const N: u8 = 4;
const GB: u8 = 5;
const SUB: u8 = 11;
const H: u8 = 12;
const HN: u8 = 13;
const ZWNJ: u8 = 14;
const R: u8 = 18;
const CS: u8 = 43;
const IS: u8 = 44;
const Sk: u8 = 48;
const G: u8 = 49;
const J: u8 = 50;
const SB: u8 = 51;
const SE: u8 = 52;
const HVM: u8 = 53;
const HM: u8 = 54;
const HR: u8 = 55;
const RK: u8 = 56;
const FAbv: u8 = 24;
const FBlw: u8 = 25;
const FPst: u8 = 26;
const MAbv: u8 = 27;
const MBlw: u8 = 28;
const MPst: u8 = 29;
const MPre: u8 = 30;
const CMAbv: u8 = 31;
const CMBlw: u8 = 32;
const VAbv: u8 = 33;
const VBlw: u8 = 34;
const VPst: u8 = 35;
const VPre: u8 = 22;
const VMAbv: u8 = 37;
const VMBlw: u8 = 38;
const VMPst: u8 = 39;
const VMPre: u8 = 23;
const SMAbv: u8 = 41;
const SMBlw: u8 = 42;
const FMAbv: u8 = 45;
const FMBlw: u8 = 46;
const FMPst: u8 = 47;

fn isH(cat: u8) bool {
    return cat == H or cat == HVM or cat == IS or cat == Sk;
}

/// Ported from `consonant_modifiers = CMAbv* CMBlw* ((h B | SUB) CMAbv* CMBlw*)*`.
fn matchConsonantModifiers(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    while (q < end and info[q].indic_category == CMAbv) q += 1;
    while (q < end and info[q].indic_category == CMBlw) q += 1;
    while (true) {
        var r: usize = undefined;
        if (q < end and isH(info[q].indic_category) and q + 1 < end and info[q + 1].indic_category == B) {
            r = q + 2;
        } else if (q < end and info[q].indic_category == SUB) {
            r = q + 1;
        } else break;
        while (r < end and info[r].indic_category == CMAbv) r += 1;
        while (r < end and info[r].indic_category == CMBlw) r += 1;
        q = r;
    }
    return q;
}

/// Ported from `medial_consonants = MPre? MAbv? MBlw? MPst?`.
fn matchMedialConsonants(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    if (q < end and info[q].indic_category == MPre) q += 1;
    if (q < end and info[q].indic_category == MAbv) q += 1;
    if (q < end and info[q].indic_category == MBlw) q += 1;
    if (q < end and info[q].indic_category == MPst) q += 1;
    return q;
}

/// Ported from `dependent_vowels = VPre* VAbv* VBlw* VPst* | H`.
fn matchDependentVowels(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    while (q < end and info[q].indic_category == VPre) q += 1;
    while (q < end and info[q].indic_category == VAbv) q += 1;
    while (q < end and info[q].indic_category == VBlw) q += 1;
    while (q < end and info[q].indic_category == VPst) q += 1;
    if (q == p and q < end and info[q].indic_category == H) q += 1;
    return q;
}

/// Ported from `vowel_modifiers = HVM? VMPre* VMAbv* VMBlw* VMPst*`.
fn matchVowelModifiers(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    if (q < end and info[q].indic_category == HVM) q += 1;
    while (q < end and info[q].indic_category == VMPre) q += 1;
    while (q < end and info[q].indic_category == VMAbv) q += 1;
    while (q < end and info[q].indic_category == VMBlw) q += 1;
    while (q < end and info[q].indic_category == VMPst) q += 1;
    return q;
}

/// Ported from `final_consonants = FAbv* FBlw* FPst*`.
fn matchFinalConsonants(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    while (q < end and info[q].indic_category == FAbv) q += 1;
    while (q < end and info[q].indic_category == FBlw) q += 1;
    while (q < end and info[q].indic_category == FPst) q += 1;
    return q;
}

/// Ported from `final_modifiers = FMAbv* FMBlw* | FMPst?`.
fn matchFinalModifiers(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    while (q < end and info[q].indic_category == FMAbv) q += 1;
    while (q < end and info[q].indic_category == FMBlw) q += 1;
    if (q == p and q < end and info[q].indic_category == FMPst) q += 1;
    return q;
}

/// Ported from `complex_syllable_start = (R | CS)? (B | GB)`.
fn matchComplexSyllableStart(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    if (q < end and (info[q].indic_category == R or info[q].indic_category == CS)) q += 1;
    if (!(q < end and (info[q].indic_category == B or info[q].indic_category == GB))) return null;
    return q + 1;
}

/// Ported from `complex_syllable_middle = consonant_modifiers
/// medial_consonants dependent_vowels vowel_modifiers (Sk B)*`.
fn matchComplexSyllableMiddle(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = matchConsonantModifiers(info, p, end);
    q = matchMedialConsonants(info, q, end);
    q = matchDependentVowels(info, q, end);
    q = matchVowelModifiers(info, q, end);
    while (q + 1 < end and info[q].indic_category == Sk and info[q + 1].indic_category == B) q += 2;
    return q;
}

/// Ported from `complex_syllable_tail = complex_syllable_middle
/// final_consonants final_modifiers`.
fn matchComplexSyllableTail(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = matchComplexSyllableMiddle(info, p, end);
    q = matchFinalConsonants(info, q, end);
    q = matchFinalModifiers(info, q, end);
    return q;
}

/// Ported from `virama_terminated_cluster_tail = consonant_modifiers (IS | RK)`.
fn matchViramaTerminatedClusterTail(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    const q = matchConsonantModifiers(info, p, end);
    if (q < end and (info[q].indic_category == IS or info[q].indic_category == RK)) return q + 1;
    return null;
}

/// Ported from `virama_terminated_cluster = complex_syllable_start
/// virama_terminated_cluster_tail`.
fn matchViramaTerminatedCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    const s = matchComplexSyllableStart(info, p, end) orelse return null;
    return matchViramaTerminatedClusterTail(info, s, end);
}

/// Ported from `sakot_terminated_cluster_tail = complex_syllable_middle Sk`.
fn matchSakotTerminatedClusterTail(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    const q = matchComplexSyllableMiddle(info, p, end);
    if (q < end and info[q].indic_category == Sk) return q + 1;
    return null;
}

/// Ported from `sakot_terminated_cluster = complex_syllable_start
/// sakot_terminated_cluster_tail`.
fn matchSakotTerminatedCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    const s = matchComplexSyllableStart(info, p, end) orelse return null;
    return matchSakotTerminatedClusterTail(info, s, end);
}

/// Ported from `standard_cluster = complex_syllable_start complex_syllable_tail`.
fn matchStandardCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    const s = matchComplexSyllableStart(info, p, end) orelse return null;
    return matchComplexSyllableTail(info, s, end);
}

/// Ported from `number_joiner_terminated_cluster_tail = (HN N)* HN`.
fn matchNumberJoinerTerminatedClusterTail(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    while (q + 1 < end and info[q].indic_category == HN and info[q + 1].indic_category == N) q += 2;
    if (q < end and info[q].indic_category == HN) return q + 1;
    return null;
}

/// Ported from `numeral_cluster_tail = (HN N)+`.
fn matchNumeralClusterTail(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    var matched = false;
    while (q + 1 < end and info[q].indic_category == HN and info[q + 1].indic_category == N) {
        q += 2;
        matched = true;
    }
    if (!matched) return null;
    return q;
}

/// Ported from `symbol_cluster_tail = SMAbv+ SMBlw* | SMBlw+`.
fn matchSymbolClusterTail(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    var n: usize = 0;
    while (q < end and info[q].indic_category == SMAbv) {
        q += 1;
        n += 1;
    }
    if (n > 0) {
        while (q < end and info[q].indic_category == SMBlw) q += 1;
        return q;
    }
    q = p;
    n = 0;
    while (q < end and info[q].indic_category == SMBlw) {
        q += 1;
        n += 1;
    }
    if (n > 0) return q;
    return null;
}

/// Ported from `tail = complex_syllable_tail | sakot_terminated_cluster_tail
/// | symbol_cluster_tail | virama_terminated_cluster_tail` - returns the
/// longest of the four alternatives (complex_syllable_tail always
/// "matches", possibly zero-length, since every one of its components is
/// optional/star).
fn matchTailBest(info: []const GlyphInfo, p: usize, end: usize) usize {
    var best = matchComplexSyllableTail(info, p, end);
    if (matchSakotTerminatedClusterTail(info, p, end)) |q| best = @max(best, q);
    if (matchSymbolClusterTail(info, p, end)) |q| best = @max(best, q);
    if (matchViramaTerminatedClusterTail(info, p, end)) |q| best = @max(best, q);
    return best;
}

/// Ported from `broken_cluster = R? (tail | number_joiner_terminated_cluster_tail | numeral_cluster_tail)`.
fn matchBrokenCluster(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    if (q < end and info[q].indic_category == R) q += 1;
    var best = matchTailBest(info, q, end);
    if (matchNumberJoinerTerminatedClusterTail(info, q, end)) |e| best = @max(best, e);
    if (matchNumeralClusterTail(info, q, end)) |e| best = @max(best, e);
    return best;
}

/// Ported from `number_joiner_terminated_cluster = N number_joiner_terminated_cluster_tail`.
fn matchNumberJoinerTerminatedCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    if (!(p < end and info[p].indic_category == N)) return null;
    return matchNumberJoinerTerminatedClusterTail(info, p + 1, end);
}

/// Ported from `numeral_cluster = N numeral_cluster_tail?`.
fn matchNumeralCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    if (!(p < end and info[p].indic_category == N)) return null;
    if (matchNumeralClusterTail(info, p + 1, end)) |q| return q;
    return p + 1;
}

/// Ported from `symbol_cluster = (O | GB | SB) tail?`.
fn matchSymbolCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    if (!(p < end and (info[p].indic_category == O or info[p].indic_category == GB or info[p].indic_category == SB))) return null;
    return matchTailBest(info, p + 1, end);
}

/// Ported from `SB* G HR? HM? SE*` (the repeated unit inside hieroglyph_cluster).
fn matchHieroglyphGroup(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    while (q < end and info[q].indic_category == SB) q += 1;
    if (!(q < end and info[q].indic_category == G)) return null;
    q += 1;
    if (q < end and info[q].indic_category == HR) q += 1;
    if (q < end and info[q].indic_category == HM) q += 1;
    while (q < end and info[q].indic_category == SE) q += 1;
    return q;
}

/// Ported from `hieroglyph_cluster = SB* G HR? HM? SE* (J SB* (G HR? HM? SE*)?)*`.
fn matchHieroglyphCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = matchHieroglyphGroup(info, p, end) orelse return null;
    while (q < end and info[q].indic_category == J) {
        var r = q + 1;
        while (r < end and info[r].indic_category == SB) r += 1;
        q = matchHieroglyphGroup(info, r, end) orelse r;
    }
    return q;
}

fn consumeOptionalZwnj(info: []const GlyphInfo, p: usize, end: usize) usize {
    if (p < end and info[p].indic_category == ZWNJ) return p + 1;
    return p;
}

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

/// Ported from `find_syllables_use`: at each position, tries every
/// top-level alternative in the `main := |* ... *|` Ragel scanner (each
/// optionally followed by ZWNJ) and picks the longest match, first-listed
/// rule wins ties, falling back to a single-glyph `other` match. Requires
/// `GlyphInfo.indic_category` to already hold each glyph's USE category
/// (via `unicode.useCategory`).
///
/// Deliberate simplification vs. hb: the CGJ (U+034F) default-ignorable
/// exclusion filter `find_syllables_use`'s C++ builds via `hb_filter`
/// before running the scanner isn't ported - CGJ is rare enough in real
/// text that this port just runs the scanner over every glyph including
/// it, which only affects cluster boundaries around an explicit CGJ, not
/// ordinary shaping.
fn findSyllablesUse(buffer: *Buffer) void {
    const info = buffer.info.items;
    const count = info.len;
    var p: usize = 0;
    var serial: u8 = 1;
    while (p < count) {
        // 0 is a sentinel meaning "no rule has matched yet" - `other` (any
        // single glyph, `use_non_cluster`) is the Ragel scanner's *last*-
        // listed alternative, so it must lose every tie, not win them; a
        // stray combining mark with no base (e.g. an isolated USE(VMAbv))
        // matches `broken_cluster` at length 1 too, and that earlier-listed
        // rule has to take the tie so it gets flagged broken (and later
        // gets a dotted circle) instead of silently falling through as an
        // ordinary non_cluster glyph.
        var best_len: usize = 0;
        var best_type: u8 = use_non_cluster;

        if (matchViramaTerminatedCluster(info, p, count)) |e0| {
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_virama_terminated_cluster;
            }
        }
        if (matchSakotTerminatedCluster(info, p, count)) |e0| {
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_sakot_terminated_cluster;
            }
        }
        if (matchStandardCluster(info, p, count)) |e0| {
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_standard_cluster;
            }
        }
        if (matchNumberJoinerTerminatedCluster(info, p, count)) |e0| {
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_number_joiner_terminated_cluster;
            }
        }
        if (matchNumeralCluster(info, p, count)) |e0| {
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_numeral_cluster;
            }
        }
        if (matchSymbolCluster(info, p, count)) |e0| {
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_symbol_cluster;
            }
        }
        if (matchHieroglyphCluster(info, p, count)) |e0| {
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_hieroglyph_cluster;
            }
        }
        {
            const e0 = matchBrokenCluster(info, p, count);
            const e = consumeOptionalZwnj(info, e0, count);
            if (e - p > best_len) {
                best_len = e - p;
                best_type = use_broken_cluster;
            }
        }
        if (best_len == 0) best_len = 1; // `other`: no rule matched even one glyph.

        const start = p;
        const end = p + best_len;
        for (info[start..end]) |*gi| gi.indic_syllable = (serial << 4) | best_type;
        serial += 1;
        if (serial == 16) serial = 1;
        p = end;
    }
}

fn isPostBaseUse(cat: u8) bool {
    return switch (cat) {
        FAbv, FBlw, FPst, FMAbv, FMBlw, FMPst, MAbv, MBlw, MPst, MPre, VAbv, VBlw, VPst, VPre, VMAbv, VMBlw, VMPst, VMPre => true,
        else => false,
    };
}

fn isHalantUse(cat: u8) bool {
    return cat == H or cat == HVM or cat == IS;
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
            const is_post_base = isPostBaseUse(info[i].indic_category) or isHalantUse(info[i].indic_category);
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
        if (isHalantUse(info[i].indic_category)) {
            j = i + 1;
        } else if ((info[i].indic_category == VPre or info[i].indic_category == VMPre) and j < i) {
            buffer.mergeClusters(j, i + 1);
            const tmp = info[i];
            var k = i;
            while (k > j) : (k -= 1) info[k] = info[k - 1];
            info[j] = tmp;
        }
    }
}

/// Ported from `collect_features_use`, minus the `locl`/`ccmp` enables
/// (already unconditionally enabled by `shape()`'s `default_features`, same
/// as `collectFeaturesIndic`) and the pause registrations (no pause
/// machinery in this port, see the module doc comment).
pub fn collectFeaturesUse(map_builder: *MapBuilder) !void {
    const manual_joiners = MapFeatureFlags{ .manual_zwnj = true, .manual_zwj = true };
    // "Topographical features": registered unconditionally (isol/init/medi/
    // fina drive both the arabic-joining-script mask assignment in
    // `setupMasksUse` and `setupTopographicalMasksUse`'s syllable-adjacency
    // fallback for every other USE script).
    for (use_topographical_features) |tag| try map_builder.addFeature(tag, .{}, 1);
    try map_builder.enableFeature(tag_nukt, manual_joiners, 1);
    try map_builder.enableFeature(tag_akhn, manual_joiners, 1);
    try map_builder.addFeature(tag_rphf, manual_joiners, 1);
    try map_builder.enableFeature(tag_pref, manual_joiners, 1);
    try map_builder.enableFeature(tag_rkrf, manual_joiners, 1);
    try map_builder.enableFeature(tag_abvf, manual_joiners, 1);
    try map_builder.enableFeature(tag_blwf, manual_joiners, 1);
    try map_builder.enableFeature(tag_half, manual_joiners, 1);
    try map_builder.enableFeature(tag_pstf, manual_joiners, 1);
    try map_builder.enableFeature(tag_vatu, manual_joiners, 1);
    try map_builder.enableFeature(tag_cjct, manual_joiners, 1);
    try map_builder.enableFeature(tag_abvs, manual_joiners, 1);
    try map_builder.enableFeature(tag_blws, manual_joiners, 1);
    try map_builder.enableFeature(tag_haln, manual_joiners, 1);
    try map_builder.enableFeature(tag_pres, manual_joiners, 1);
    try map_builder.enableFeature(tag_psts, manual_joiners, 1);
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
pub fn setupMasksUse(buffer: *Buffer, map: Map, cmap: ?Cmap, is_arabic_joining: bool) !void {
    if (is_arabic_joining) arabic_mod.setupMasksArabic(buffer, map);

    for (buffer.info.items) |*info| info.indic_category = unicode.useCategory(@intCast(info.codepoint));
    findSyllablesUse(buffer);
    _ = try common.insertDottedCircles(buffer, cmap, use_broken_cluster, B, R, null);
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

        reorderUseSyllable(buffer, start, end, syl & 0x0F);

        start = end;
    }
}
