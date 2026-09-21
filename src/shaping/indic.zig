// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const parsing = @import("../parsing.zig");
const common = @import("common.zig");
const apply_mod = @import("apply.zig");
const map_mod = @import("map.zig");
const Buffer = common.Buffer;
const GlyphInfo = common.GlyphInfo;
const Cmap = common.Cmap;
const Tag = common.Tag;
const MapBuilder = map_mod.MapBuilder;
const Map = map_mod.Map;
const MapFeatureFlags = map_mod.MapFeatureFlags;

// Ported from vendor/harfbuzz/src/hb-ot-shaper-indic.cc +
// hb-ot-shaper-indic-table.cc + hb-ot-shaper-indic-machine.rl (pinned
// 703e2d1441): the classic Indic shaper for the 9 scripts that use it
// (Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada,
// Malayalam). Khmer/Myanmar/Sinhala (which hb routes through the newer USE
// engine, not this classic shaper) are out of scope.
//
// Category/position classification (`indicGetCategories`) is a byte-exact
// port of the generated packtab lookup in hb-ot-shaper-indic-table.cc -
// mechanical and low-risk since it's a pure data-table decode.
//
// Syllabification (`findSyllablesIndic`) hand-ports the Ragel scanner
// grammar in hb-ot-shaper-indic-machine.rl (not the generated .hh state
// tables, which are an unreadable merged Ragel DFA shared with
// khmer/myanmar) as a greedy longest-match recursive matcher - the .rl
// grammar is a plain regex over category codes with no backtracking
// ambiguity that matters here, so per-rule maximal-munch matching plus
// "longest match across rules, first-listed wins ties" reproduces the
// scanner semantics.
//
// Reordering follows hb's two-phase shape: `initialReorderingIndic` runs as
// a GSUB pause after 'locl'/'ccmp' and `finalReorderingIndic` as one after
// the basic-forms features, each basic feature getting a stage of its own
// (see collectFeaturesIndic). That staging is what makes the font dry-runs
// (`IndicPlan.wouldSubstitute`, hb's `hb_ot_layout_lookup_would_substitute`)
// and the "did this candidate actually ligate" checks possible: the first
// needs a feature's lookups in isolation, the second needs them already
// applied.
//
// Two deliberate differences from hb remain:
//   - dotted-circle insertion for broken (malformed) syllables runs with
//     syllabification, before glyph mapping, rather than inside the
//     initial-reordering pause - see `setupMasksIndic`.
//   - the post-sort cluster merge in initial reordering always takes hb's
//     own old-spec/long-syllable shortcut of merging the whole post-base
//     run, rather than reconstructing which glyphs the sort moved.

const deva_tag = Tag{ 'd', 'e', 'v', 'a' };
const dev2_tag = Tag{ 'd', 'e', 'v', '2' };
const beng_tag = Tag{ 'b', 'e', 'n', 'g' };
const bng2_tag = Tag{ 'b', 'n', 'g', '2' };
const guru_tag = Tag{ 'g', 'u', 'r', 'u' };
const gur2_tag = Tag{ 'g', 'u', 'r', '2' };
const gujr_tag = Tag{ 'g', 'u', 'j', 'r' };
const gjr2_tag = Tag{ 'g', 'j', 'r', '2' };
const orya_tag = Tag{ 'o', 'r', 'y', 'a' };
const ory2_tag = Tag{ 'o', 'r', 'y', '2' };
const taml_tag = Tag{ 't', 'a', 'm', 'l' };
const tml2_tag = Tag{ 't', 'm', 'l', '2' };
const telu_tag = Tag{ 't', 'e', 'l', 'u' };
const tel2_tag = Tag{ 't', 'e', 'l', '2' };
const knda_tag = Tag{ 'k', 'n', 'd', 'a' };
const knd2_tag = Tag{ 'k', 'n', 'd', '2' };
const mlym_tag = Tag{ 'm', 'l', 'y', 'm' };
const mlm2_tag = Tag{ 'm', 'l', 'm', '2' };

const tag_nukt = Tag{ 'n', 'u', 'k', 't' };
const tag_akhn = Tag{ 'a', 'k', 'h', 'n' };
pub const tag_rphf = Tag{ 'r', 'p', 'h', 'f' };
const tag_rkrf = Tag{ 'r', 'k', 'r', 'f' };
pub const tag_pref = Tag{ 'p', 'r', 'e', 'f' };
pub const tag_blwf = Tag{ 'b', 'l', 'w', 'f' };
pub const tag_abvf = Tag{ 'a', 'b', 'v', 'f' };
const tag_half = Tag{ 'h', 'a', 'l', 'f' };
pub const tag_pstf = Tag{ 'p', 's', 't', 'f' };
const tag_vatu = Tag{ 'v', 'a', 't', 'u' };
const tag_cjct = Tag{ 'c', 'j', 'c', 't' };
const tag_init = Tag{ 'i', 'n', 'i', 't' };
pub const tag_pres = Tag{ 'p', 'r', 'e', 's' };
pub const tag_abvs = Tag{ 'a', 'b', 'v', 's' };
pub const tag_blws = Tag{ 'b', 'l', 'w', 's' };
pub const tag_psts = Tag{ 'p', 's', 't', 's' };
const tag_haln = Tag{ 'h', 'a', 'l', 'n' };

// I_Cat(...) values from hb-ot-shaper-indic-machine.hh; A and VD share value
// 9 there (used interchangeably in the syllable grammar).
pub const ic_x: u8 = 0;
pub const ic_c: u8 = 1;
pub const ic_v: u8 = 2;
pub const ic_n: u8 = 3;
pub const ic_h: u8 = 4;
pub const ic_zwnj: u8 = 5;
pub const ic_zwj: u8 = 6;
const ic_m: u8 = 7;
pub const ic_sm: u8 = 8;
pub const ic_placeholder: u8 = 10;
pub const ic_dottedcircle: u8 = 11;
const ic_rs: u8 = 12;
const ic_mpst: u8 = 13;
const ic_repha: u8 = 14;
pub const ic_ra: u8 = 15;
const ic_cm: u8 = 16;
const ic_symbol: u8 = 17;
pub const ic_cs: u8 = 18;
pub const ic_smpst: u8 = 57;

// ot_position_t values from hb-ot-shaper-indic.hh.
const ip_start: u8 = 0;
const ip_ra_to_become_reph: u8 = 1;
pub const ip_pre_m: u8 = 2;
pub const ip_pre_c: u8 = 3;
pub const ip_base_c: u8 = 4;
pub const ip_after_main: u8 = 5;
const ip_above_c: u8 = 6;
pub const ip_before_sub: u8 = 7;
pub const ip_below_c: u8 = 8;
pub const ip_after_sub: u8 = 9;
const ip_before_post: u8 = 10;
const ip_post_c: u8 = 11;
const ip_after_post: u8 = 12;
const ip_smvd: u8 = 13;
const ip_end: u8 = 14;

/// Ported from `_hb_indic_values`/`_hb_indic_u8` (generated by
/// gen-indic-table.py from IndicSyllabicCategory.txt +
/// IndicPositionalCategory.txt + Blocks.txt). Packed category|position
/// values also cover Khmer/Myanmar category codes (this shared table is
/// generated once for all three classic shapers, `hb_indic_get_categories`
/// is called directly by `hb-ot-shaper-khmer.cc`/`-myanmar.cc` too) - the
/// Khmer/Myanmar-only entries (index 1, 16-17, 19-21, 23, 26, 32-36, 38-39)
/// use the `cat_*` constants defined below, not `ic_*`/`ip_*` above.
pub const indic_values = [42]u16{ 3337, 3616, 1025, 1040, 1042, 1035, 1034, 2052, 1540, 3588, 1287, 3079, 2311, 2055, 1799, 519, 3619, 3625, 3085, 3620, 3621, 3622, 3587, 3623, 1039, 3598, 3609, 3345, 1800, 3336, 3385, 1026, 1556, 2069, 790, 2839, 3624, 3584, 3610, 3611, 3590, 3589 };
pub const indic_u8 = [1220]u8{
    1,   0,   50,  4,   5,   96,  0,   7,   8,   9,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   186, 0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   192,
    0,   0,   0,   0,   208, 224, 0,   0,   0,   0,   0,   0,   0,   0,   1,   0,
    2,   3,   0,   0,   0,   0,   0,   0,   0,   0,   4,   5,   6,   7,   8,   9,
    10,  11,  12,  13,  14,  15,  16,  17,  18,  19,  20,  21,  0,   0,   22,  23,
    24,  0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   25,  26,  0,   0,
    0,   27,  0,   0,   0,   0,   28,  29,  30,  0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   31,  0,   0,   0,   32,  0,   0,   0,   33,  0,   34,
    0,   0,   0,   0,   0,   0,   35,  0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   36,  0,   0,   0,   0,   0,   0,   37,  0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   25,  2,   10,  0,   0,   0,   0,   26,  0,
    27,  0,   0,   0,   28,  0,   0,   0,   0,   0,   29,  11,  30,  1,   1,   1,
    4,   31,  32,  33,  34,  1,   6,   2,   35,  1,   12,  13,  7,   1,   1,   3,
    36,  14,  15,  37,  16,  17,  6,   2,   38,  39,  18,  40,  7,   1,   1,   3,
    41,  42,  43,  44,  45,  46,  19,  2,   47,  0,   18,  48,  49,  1,   1,   3,
    20,  14,  50,  51,  0,   0,   21,  2,   0,   52,  53,  13,  7,   1,   1,   3,
    20,  54,  15,  55,  56,  17,  6,   2,   57,  0,   58,  59,  60,  61,  62,  63,
    4,   64,  65,  66,  16,  0,   19,  2,   0,   0,   67,  8,   9,   1,   1,   3,
    4,   22,  68,  69,  70,  71,  23,  2,   0,   0,   12,  8,   9,   1,   1,   3,
    72,  22,  73,  74,  75,  76,  23,  2,   77,  0,   78,  8,   9,   1,   1,   1,
    4,   79,  80,  81,  82,  83,  21,  2,   0,   84,  85,  1,   1,   86,  87,  88,
    89,  90,  2,   91,  92,  93,  94,  95,  96,  1,   97,  98,  2,   99,  0,   0,
    0,   0,   1,   1,   1,   100, 101, 11,  102, 103, 104, 105, 106, 107, 2,   10,
    0,   0,   0,   0,   108, 5,   5,   109, 110, 111, 0,   112, 113, 0,   114, 0,
    0,   0,   0,   0,   0,   0,   0,   0,   115, 0,   116, 0,   0,   0,   0,   0,
    0,   0,   0,   117, 0,   0,   0,   0,   0,   118, 0,   0,   0,   0,   5,   5,
    119, 120, 0,   0,   0,   0,   121, 1,   2,   122, 0,   0,   0,   0,   1,   1,
    123, 124, 24,  24,  0,   0,   0,   0,   0,   0,   125, 0,   0,   0,   0,   0,
    0,   126, 0,   0,   2,   2,   2,   10,  0,   0,   0,   0,   2,   2,   2,   2,
    4,   4,   4,   4,   10,  2,   2,   2,   26,  2,   2,   2,   8,   8,   8,   8,
    6,   18,  0,   4,   20,  14,  24,  2,   6,   6,   20,  6,   20,  6,   24,  2,
    4,   0,   0,   0,   6,   6,   6,   6,   66,  12,  14,  6,   6,   6,   20,  14,
    2,   0,   36,  50,  52,  18,  38,  68,  0,   0,   0,   32,  0,   0,   2,   16,
    56,  12,  14,  6,   0,   0,   0,   4,   44,  2,   16,  2,   6,   22,  0,   4,
    2,   0,   36,  28,  6,   28,  0,   4,   30,  30,  30,  30,  0,   0,   42,  0,
    34,  0,   0,   0,   0,   64,  0,   0,   0,   0,   0,   42,  12,  12,  6,   6,
    6,   6,   24,  2,   2,   18,  36,  112, 18,  18,  18,  18,  18,  18,  114, 116,
    118, 120, 122, 18,  0,   6,   6,   6,   44,  10,  0,   2,   54,  32,  46,  10,
    26,  0,   0,   0,   0,   0,   34,  70,  6,   20,  0,   14,  44,  2,   16,  10,
    2,   0,   72,  50,  124, 48,  0,   32,  48,  32,  46,  0,   126, 0,   0,   0,
    16,  2,   10,  10,  12,  2,   128, 0,   6,   6,   6,   14,  6,   14,  24,  2,
    22,  22,  52,  74,  76,  32,  46,  0,   16,  58,  58,  78,  130, 12,  14,  6,
    2,   0,   36,  132, 134, 32,  46,  0,   0,   0,   80,  136, 16,  0,   0,   0,
    0,   70,  14,  6,   6,   20,  0,   6,   20,  6,   24,  0,   16,  10,  10,  2,
    0,   16,  10,  0,   2,   10,  0,   2,   2,   0,   0,   22,  76,  48,  0,   82,
    54,  22,  84,  0,   12,  12,  138, 6,   28,  60,  38,  28,  86,  28,  88,  0,
    0,   0,   140, 86,  2,   10,  16,  0,   26,  2,   16,  2,   28,  60,  38,  60,
    38,  18,  88,  0,   0,   0,   74,  38,  0,   0,   16,  10,  142, 144, 0,   0,
    12,  12,  146, 6,   2,   148, 150, 22,  22,  22,  48,  82,  54,  22,  84,  152,
    0,   0,   2,   154, 0,   0,   0,   14,  0,   2,   2,   2,   2,   2,   26,  2,
    2,   156, 2,   2,   90,  6,   6,   6,   6,   158, 92,  94,  160, 162, 62,  58,
    164, 166, 168, 170, 4,   4,   0,   10,  2,   6,   6,   96,  98,  26,  2,   172,
    174, 100, 176, 178, 100, 102, 102, 2,   104, 62,  180, 2,   2,   182, 184, 186,
    12,  12,  12,  188, 4,   12,  190, 0,   2,   26,  2,   2,   2,   90,  6,   6,
    6,   6,   0,   92,  62,  94,  98,  192, 194, 196, 96,  198, 200, 106, 106, 108,
    108, 202, 0,   0,   42,  0,   204, 0,   8,   206, 8,   8,   208, 40,  210, 40,
    40,  2,   212, 214, 8,   34,  0,   0,   0,   0,   216, 0,   4,   4,   4,   0,
    0,   34,  0,   0,   0,   0,   110, 0,   0,   64,  110, 0,   0,   0,   218, 0,
    0,   42,  4,   34,  8,   40,  40,  40,  0,   0,   0,   220, 2,   2,   104, 16,
    4,   2,   2,   10,  16,  2,   4,   34,  0,   222, 78,  2,   56,  12,  0,   0,
    0,   80,  72,  0,   37,  37,  2,   2,   6,   6,   31,  31,  0,   0,   2,   37,
    29,  29,  37,  31,  37,  2,   12,  12,  31,  37,  11,  11,  31,  2,   24,  2,
    14,  14,  36,  36,  37,  11,  6,   37,  22,  27,  12,  37,  27,  27,  37,  6,
    24,  37,  11,  7,   11,  37,  11,  15,  11,  12,  15,  37,  37,  29,  0,   22,
    14,  12,  32,  32,  30,  30,  6,   29,  37,  15,  29,  37,  22,  37,  37,  12,
    12,  11,  22,  22,  37,  22,  15,  15,  11,  8,   14,  37,  14,  8,   2,   31,
    35,  32,  32,  33,  35,  35,  33,  33,  35,  23,  23,  23,  2,   32,  26,  38,
    38,  38,  30,  37,  12,  15,  12,  7,   15,  12,  37,  0,   0,   29,  29,  12,
    18,  11,  37,  13,  37,  3,   37,  28,  11,  10,  10,  37,  10,  11,  29,  31,
    37,  14,  37,  4,   4,   29,  6,   31,  2,   12,  12,  27,  25,  37,  2,   11,
    2,   24,  31,  35,  33,  34,  0,   32,  29,  9,   1,   21,  19,  20,  16,  2,
    21,  21,  17,  2,   23,  2,   2,   35,  32,  2,   20,  35,  34,  32,  32,  29,
    2,   29,  29,  32,  32,  35,  35,  34,  34,  34,  38,  39,  39,  26,  9,   39,
    27,  39,  0,   37,  0,   27,  27,  0,   0,   4,   4,   0,   41,  40,  5,   37,
    31,  12,  2,   23,
};

fn indicB4(i: usize) u8 {
    return (indic_u8[i >> 1] >> @as(u3, @intCast((i & 1) << 2))) & 15;
}

fn indicCategoriesIndex(u: u32) u8 {
    if (u >= 71396) return 37;
    const b4 = indicB4(u >> 9);
    const idx0: usize = (@as(usize, b4) << 3) + ((u >> 6) & 7);
    const v0 = indic_u8[70 + idx0];
    const idx1: usize = (@as(usize, v0) << 3) + ((u >> 3) & 7);
    const v1 = indic_u8[186 + idx1];
    const idx2: usize = (@as(usize, v1) << 2) + ((u >> 1) & 3);
    const v2 = indic_u8[488 + idx2];
    const idx3: usize = @as(usize, v2) + (u & 1);
    return indic_u8[996 + idx3];
}

pub fn indicGetCategories(u: u32) u16 {
    return indic_values[indicCategoriesIndex(u)];
}

fn setIndicProperties(info: *GlyphInfo) void {
    const packed_cats = indicGetCategories(info.codepoint);
    info.indic_category = @intCast(packed_cats & 0xFF);
    info.indic_position = @intCast(packed_cats >> 8);
}

fn isIndicConsonant(cat: u8) bool {
    return cat == ic_c or cat == ic_cs or cat == ic_ra or cat == ic_cm or cat == ic_v or
        cat == ic_placeholder or cat == ic_dottedcircle;
}

pub fn isIndicJoiner(cat: u8) bool {
    return cat == ic_zwj or cat == ic_zwnj;
}

/// Ported from `reph = (Ra H | Repha)`.
fn matchIndicReph(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    if (p < end and info[p].indic_category == ic_repha) return p + 1;
    if (p < end and info[p].indic_category == ic_ra and p + 1 < end and info[p + 1].indic_category == ic_h) return p + 2;
    return null;
}

/// Ported from `n = ((ZWNJ?.RS)? (N.N?)?)`.
fn matchIndicN(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    {
        var r = q;
        if (r < end and info[r].indic_category == ic_zwnj) r += 1;
        if (r < end and info[r].indic_category == ic_rs) {
            q = r + 1;
        } else if (q < end and info[q].indic_category == ic_rs) {
            q = q + 1;
        }
    }
    if (q < end and info[q].indic_category == ic_n) {
        q += 1;
        if (q < end and info[q].indic_category == ic_n) q += 1;
    }
    return q;
}

/// Ported from `cn = c.ZWJ?.n?`.
fn matchIndicCn(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    if (!(p < end and (info[p].indic_category == ic_c or info[p].indic_category == ic_ra))) return null;
    var q = p + 1;
    if (q < end and info[q].indic_category == ic_zwj) q += 1;
    return matchIndicN(info, q, end);
}

fn matchIndicSymbol(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    if (!(p < end and info[p].indic_category == ic_symbol)) return null;
    var q = p + 1;
    if (q < end and info[q].indic_category == ic_n) q += 1;
    return q;
}

/// Ported from `matra_group = z*.(M | sm? MPst).N?.H?`.
fn matchIndicMatraGroup(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    while (q < end and isIndicJoiner(info[q].indic_category)) q += 1;
    if (q < end and info[q].indic_category == ic_m) {
        q += 1;
    } else {
        var r = q;
        if (r < end and (info[r].indic_category == ic_sm or info[r].indic_category == ic_smpst)) r += 1;
        if (r < end and info[r].indic_category == ic_mpst) {
            q = r + 1;
        } else return null;
    }
    if (q < end and info[q].indic_category == ic_n) q += 1;
    if (q < end and info[q].indic_category == ic_h) q += 1;
    return q;
}

/// Ported from `syllable_tail = (z?.sm.sm?.ZWNJ?)? (A | VD)*` (A and VD
/// share category value 9, see `ic_*`'s doc comment).
fn matchIndicSyllableTail(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    {
        var r = q;
        if (r < end and isIndicJoiner(info[r].indic_category)) r += 1;
        if (r < end and (info[r].indic_category == ic_sm or info[r].indic_category == ic_smpst)) {
            r += 1;
            if (r < end and (info[r].indic_category == ic_sm or info[r].indic_category == ic_smpst)) r += 1;
            if (r < end and info[r].indic_category == ic_zwnj) r += 1;
            q = r;
        }
    }
    while (q < end and info[q].indic_category == 9) q += 1;
    return q;
}

/// Ported from `halant_group = (z?.H.(ZWJ.N?)?)`.
fn matchIndicHalantGroup(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var h_pos: ?usize = null;
    if (p < end and isIndicJoiner(info[p].indic_category) and p + 1 < end and info[p + 1].indic_category == ic_h) {
        h_pos = p + 2;
    } else if (p < end and info[p].indic_category == ic_h) {
        h_pos = p + 1;
    }
    var q = h_pos orelse return null;
    if (q < end and info[q].indic_category == ic_zwj) {
        var r = q + 1;
        if (r < end and info[r].indic_category == ic_n) r += 1;
        q = r;
    }
    return q;
}

/// Ported from `final_halant_group = halant_group | H.ZWNJ`.
fn matchIndicFinalHalantGroup(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    const a = matchIndicHalantGroup(info, p, end);
    var b: ?usize = null;
    if (p < end and info[p].indic_category == ic_h and p + 1 < end and info[p + 1].indic_category == ic_zwnj) b = p + 2;
    if (a == null and b == null) return null;
    return @max(a orelse 0, b orelse 0);
}

fn matchIndicMedialGroup(info: []const GlyphInfo, p: usize, end: usize) usize {
    if (p < end and info[p].indic_category == ic_cm) return p + 1;
    return p;
}

/// Ported from `halant_or_matra_group = (final_halant_group | matra_group*)`.
fn matchIndicHalantOrMatraGroup(info: []const GlyphInfo, p: usize, end: usize) usize {
    var best = p;
    {
        var q = p;
        while (matchIndicMatraGroup(info, q, end)) |nq| {
            if (nq == q) break;
            q = nq;
        }
        if (q > best) best = q;
    }
    if (matchIndicFinalHalantGroup(info, p, end)) |q| {
        if (q > best) best = q;
    }
    return best;
}

/// Ported from `complex_syllable_tail = (halant_group.cn)* medial_group
/// halant_or_matra_group syllable_tail`.
fn matchIndicComplexSyllableTail(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    while (true) {
        const hg = matchIndicHalantGroup(info, q, end) orelse break;
        const cn = matchIndicCn(info, hg, end) orelse break;
        q = cn;
    }
    q = matchIndicMedialGroup(info, q, end);
    q = matchIndicHalantOrMatraGroup(info, q, end);
    q = matchIndicSyllableTail(info, q, end);
    return q;
}

/// Ported from `consonant_syllable = (Repha|CS)? cn complex_syllable_tail`.
fn matchIndicConsonantSyllable(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    if (q < end and (info[q].indic_category == ic_repha or info[q].indic_category == ic_cs)) q += 1;
    const cn = matchIndicCn(info, q, end) orelse return null;
    return matchIndicComplexSyllableTail(info, cn, end);
}

/// Ported from `vowel_syllable = reph? V.n? (ZWJ | complex_syllable_tail)`.
fn matchIndicVowelSyllable(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q = p;
    if (matchIndicReph(info, q, end)) |r| q = r;
    if (!(q < end and info[q].indic_category == ic_v)) return null;
    q += 1;
    q = matchIndicN(info, q, end);
    var best = matchIndicComplexSyllableTail(info, q, end);
    if (q < end and info[q].indic_category == ic_zwj) best = @max(best, q + 1);
    return best;
}

/// Ported from `standalone_cluster = ((Repha|CS)? PLACEHOLDER | reph?
/// DOTTEDCIRCLE).n? complex_syllable_tail`.
fn matchIndicStandaloneCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    var q: ?usize = null;
    {
        var r = p;
        if (r < end and (info[r].indic_category == ic_repha or info[r].indic_category == ic_cs)) r += 1;
        if (r < end and info[r].indic_category == ic_placeholder) q = r + 1;
    }
    {
        var r = p;
        if (matchIndicReph(info, r, end)) |rr| r = rr;
        if (r < end and info[r].indic_category == ic_dottedcircle) {
            const alt = r + 1;
            if (q == null or alt > q.?) q = alt;
        }
    }
    var qq = q orelse return null;
    qq = matchIndicN(info, qq, end);
    return matchIndicComplexSyllableTail(info, qq, end);
}

/// Ported from `symbol_cluster = symbol syllable_tail`.
fn matchIndicSymbolCluster(info: []const GlyphInfo, p: usize, end: usize) ?usize {
    const s = matchIndicSymbol(info, p, end) orelse return null;
    return matchIndicSyllableTail(info, s, end);
}

/// Ported from `broken_cluster = reph? n? complex_syllable_tail`.
fn matchIndicBrokenCluster(info: []const GlyphInfo, p: usize, end: usize) usize {
    var q = p;
    if (matchIndicReph(info, q, end)) |r| q = r;
    q = matchIndicN(info, q, end);
    return matchIndicComplexSyllableTail(info, q, end);
}

/// Same order as `indic_syllable_type_t`.
const indic_syllable_consonant: u8 = 0;
const indic_syllable_vowel: u8 = 1;
const indic_syllable_standalone: u8 = 2;
const indic_syllable_symbol: u8 = 3;
const indic_syllable_broken: u8 = 4;
const indic_syllable_non_indic: u8 = 5;

/// Ported from `find_syllables_indic`: at each position, tries every
/// alternative in the `main := |* ... *|` Ragel scanner and picks the
/// longest match (first-listed rule wins ties), falling back to a
/// single-glyph `other` match. Requires `setIndicProperties` to have
/// already run on every glyph in the buffer.
fn findSyllablesIndic(buffer: *Buffer) void {
    const info = buffer.info.items;
    const count = info.len;
    var p: usize = 0;
    var serial: u8 = 1;
    while (p < count) {
        // 0 is a sentinel meaning "no rule matched yet" - `other` is the
        // Ragel scanner's last-listed alternative and must lose ties, not
        // win them; see the matching comment in use.zig's findSyllablesUse
        // for why this matters (a lone broken-cluster glyph must not fall
        // through to non_indic_cluster on a length tie).
        var best_len: usize = 0;
        var best_type: u8 = indic_syllable_non_indic;
        if (matchIndicConsonantSyllable(info, p, count)) |e| {
            const l = e - p;
            if (l > best_len) {
                best_len = l;
                best_type = indic_syllable_consonant;
            }
        }
        if (matchIndicVowelSyllable(info, p, count)) |e| {
            const l = e - p;
            if (l > best_len) {
                best_len = l;
                best_type = indic_syllable_vowel;
            }
        }
        if (matchIndicStandaloneCluster(info, p, count)) |e| {
            const l = e - p;
            if (l > best_len) {
                best_len = l;
                best_type = indic_syllable_standalone;
            }
        }
        if (matchIndicSymbolCluster(info, p, count)) |e| {
            const l = e - p;
            if (l > best_len) {
                best_len = l;
                best_type = indic_syllable_symbol;
            }
        }
        {
            const e = matchIndicBrokenCluster(info, p, count);
            const l = e - p;
            if (l > best_len) {
                best_len = l;
                best_type = indic_syllable_broken;
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

const IndicRephPosition = enum(u8) { after_main, before_sub, after_sub, before_post, after_post };
const IndicRephMode = enum(u8) { implicit, explicit, log_repha };
const IndicBlwfMode = enum(u8) { pre_and_post, post_only };

pub const IndicScriptConfig = struct {
    tag1: Tag,
    tag2: Tag,
    virama: u21,
    reph_pos: IndicRephPosition,
    reph_mode: IndicRephMode,
    blwf_mode: IndicBlwfMode,
    is_devanagari: bool,
    is_kannada: bool,
    is_malayalam: bool,
    is_tamil: bool,
};

/// Ported from `indic_configs`.
const indic_script_configs = [9]IndicScriptConfig{
    .{ .tag1 = deva_tag, .virama = 0x094D, .tag2 = dev2_tag, .reph_pos = .before_post, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = true, .is_kannada = false, .is_malayalam = false, .is_tamil = false },
    .{ .tag1 = beng_tag, .virama = 0x09CD, .tag2 = bng2_tag, .reph_pos = .after_sub, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false, .is_tamil = false },
    .{ .tag1 = guru_tag, .virama = 0x0A4D, .tag2 = gur2_tag, .reph_pos = .before_sub, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false, .is_tamil = false },
    .{ .tag1 = gujr_tag, .virama = 0x0ACD, .tag2 = gjr2_tag, .reph_pos = .before_post, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false, .is_tamil = false },
    .{ .tag1 = orya_tag, .virama = 0x0B4D, .tag2 = ory2_tag, .reph_pos = .after_main, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false, .is_tamil = false },
    .{ .tag1 = taml_tag, .virama = 0x0BCD, .tag2 = tml2_tag, .reph_pos = .after_post, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false, .is_tamil = true },
    .{ .tag1 = telu_tag, .virama = 0x0C4D, .tag2 = tel2_tag, .reph_pos = .after_post, .reph_mode = .explicit, .blwf_mode = .post_only, .is_devanagari = false, .is_kannada = false, .is_malayalam = false, .is_tamil = false },
    .{ .tag1 = knda_tag, .virama = 0x0CCD, .tag2 = knd2_tag, .reph_pos = .after_post, .reph_mode = .implicit, .blwf_mode = .post_only, .is_devanagari = false, .is_kannada = true, .is_malayalam = false, .is_tamil = false },
    .{ .tag1 = mlym_tag, .virama = 0x0D4D, .tag2 = mlm2_tag, .reph_pos = .after_main, .reph_mode = .log_repha, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = true, .is_tamil = false },
};

pub fn findIndicConfig(script_tags: []const Tag) ?*const IndicScriptConfig {
    for (script_tags) |t| {
        for (&indic_script_configs) |*cfg| {
            if (std.mem.eql(u8, &t, &cfg.tag1) or std.mem.eql(u8, &t, &cfg.tag2)) return cfg;
        }
    }
    return null;
}

/// Ported from `indic_shape_plan_t::is_old_spec`.
fn indicIsOldSpec(map: Map) bool {
    const tag = map.chosen_script[0] orelse return true;
    return tag[3] != '2';
}

/// Ported from `collect_features_indic`. `locl`/`ccmp` are enabled here as
/// well as in `default_features` so they land in the first stage. `rphf`/`pref`/`blwf`/`abvf`/`half`/`pstf`/`init` are
/// added non-globally (`addFeature`, not `enableFeature`) so
/// `MapBuilder.compile` allocates real mask bits the reordering passes can
/// assign per-glyph via `map.get1Mask`.
///
/// Every basic-forms feature gets a stage to itself, as in hb: a font is
/// free to give 'blwf' a lower lookup index than 'rphf', and merging them
/// into one stage would then apply them in the font's index order instead
/// of the spec's feature order (blwf eating the Ra+Halant that rphf was
/// supposed to ligate). The pause boundaries are also what let
/// `wouldSubstitute` probe one feature's lookups in isolation.
pub fn collectFeaturesIndic(map_builder: *MapBuilder) !void {
    const manual_joiners = MapFeatureFlags{ .manual_zwnj = true, .manual_zwj = true, .per_syllable = true };
    try map_builder.enableFeature(.{ 'l', 'o', 'c', 'l' }, .{ .per_syllable = true }, 1);
    try map_builder.enableFeature(.{ 'c', 'c', 'm', 'p' }, .{ .per_syllable = true }, 1);
    try map_builder.addGsubPause(.indic_initial_reorder);
    const basic_features = [_]Tag{ tag_nukt, tag_akhn, tag_rphf, tag_rkrf, tag_pref, tag_blwf, tag_abvf, tag_half, tag_pstf, tag_vatu, tag_cjct };
    const basic_global = [_]bool{ true, true, false, true, false, false, false, false, false, true, true };
    for (basic_features, basic_global) |tag, is_global| {
        if (is_global) try map_builder.enableFeature(tag, manual_joiners, 1) else try map_builder.addFeature(tag, manual_joiners, 1);
        try map_builder.addGsubPause(.none);
    }
    try map_builder.addGsubPause(.indic_final_reorder);
    try map_builder.addFeature(tag_init, manual_joiners, 1);
    try map_builder.enableFeature(tag_pres, manual_joiners, 1);
    try map_builder.enableFeature(tag_abvs, manual_joiners, 1);
    try map_builder.enableFeature(tag_blws, manual_joiners, 1);
    try map_builder.enableFeature(tag_psts, manual_joiners, 1);
    try map_builder.enableFeature(tag_haln, manual_joiners, 1);
}

/// Shifts `info[from..to]`/`info[to..from]` by one and drops `info[from]`
/// into the vacated slot at `to` - the memmove-based single-glyph move
/// `reorderIndicSyllable` uses for reph/consonant repositioning.
fn moveIndicGlyph(info: []GlyphInfo, from: usize, to: usize) void {
    if (from == to) return;
    const tmp = info[from];
    if (from < to) {
        var i = from;
        while (i < to) : (i += 1) info[i] = info[i + 1];
    } else {
        var i = from;
        while (i > to) : (i -= 1) info[i] = info[i - 1];
    }
    info[to] = tmp;
}

/// Stable insertion sort by `indic_position` - syllables are always short
/// (a handful of glyphs), so O(n^2) is simplest and plenty fast; must be
/// stable to match `hb_stable_sort` (glyphs sharing a position keep their
/// relative order).
pub fn indicSortByPosition(info: []GlyphInfo, lo: usize, hi: usize) void {
    var i = lo + 1;
    while (i < hi) : (i += 1) {
        const key = info[i];
        var j = i;
        while (j > lo and info[j - 1].indic_position > key.indic_position) : (j -= 1) info[j] = info[j - 1];
        info[j] = key;
    }
}

/// Ported from `final_reordering_syllable_indic`'s reph-move `switch`
/// (steps 2-6; step 1's `REPH_POS_AFTER_POST` early-exit to step 5 is the
/// `reph_pos != .after_post` guard around steps 2-4 below), minus the
/// ligation-state checks noted in this section's top doc comment.
fn indicRephTargetPosition(info: []const GlyphInfo, reph_pos: IndicRephPosition, start: usize, base: usize, end: usize) usize {
    if (reph_pos != .after_post) {
        var p = start + 1;
        while (p < base and info[p].indic_category != ic_h) p += 1;
        if (p < base and info[p].indic_category == ic_h) {
            if (p + 1 < base and isIndicJoiner(info[p + 1].indic_category)) p += 1;
            return p;
        }

        if (reph_pos == .after_main) {
            var q = base;
            while (q + 1 < end and info[q + 1].indic_position <= ip_after_main) q += 1;
            if (q < end) return q;
        }

        if (reph_pos == .after_sub) {
            var q = base;
            while (q + 1 < end and !(info[q + 1].indic_position == ip_post_c or info[q + 1].indic_position == ip_after_post or info[q + 1].indic_position == ip_smvd)) q += 1;
            if (q < end) return q;
        }
    }

    {
        var p = start + 1;
        while (p < base and info[p].indic_category != ic_h) p += 1;
        if (p < base and info[p].indic_category == ic_h) {
            if (p + 1 < base and isIndicJoiner(info[p + 1].indic_category)) p += 1;
            return p;
        }
    }

    var p = end - 1;
    while (p > start and info[p].indic_position == ip_smvd) p -= 1;
    if (info[p].indic_category == ic_h) {
        var i = base + 1;
        while (i < p) : (i += 1) {
            if (info[i].indic_category == ic_m or info[i].indic_category == ic_mpst) p -= 1;
        }
    }
    return p;
}

/// Per-segment state `initialReorderingIndic`/`finalReorderingIndic` need
/// beyond the buffer: the font (for the GSUB dry-runs), the compiled map
/// (feature masks and the per-feature lookup stages those dry-runs probe)
/// and the resolved virama glyph.
const IndicPlan = struct {
    font: parsing.Font,
    map: Map,
    config: IndicScriptConfig,
    is_old_spec: bool,
    /// hb's `load_virama_glyph`; 0 when the font has no virama, which
    /// switches off both the consonant-position probes and the halant
    /// recovery, exactly as in hb.
    virama_glyph: u32,

    /// hb's `hb_indic_would_substitute_feature_t::would_substitute`. A
    /// malformed lookup answers "no" rather than failing the shape - the
    /// caller only uses this to pick between two legal reorderings.
    fn wouldSubstitute(self: IndicPlan, tag: Tag, glyphs: []const u32) bool {
        return apply_mod.featureWouldSubstitute(self.font, self.map, tag, glyphs) catch false;
    }
};

fn ligatedAndDidntMultiply(glyph_info: GlyphInfo) bool {
    return glyph_info.is_ligated and !glyph_info.is_multiplied;
}

/// Ported from `consonant_position_from_face`: asks the font whether it has
/// a below-/post-/pre-base form for this consonant, so the base-consonant
/// search can skip it. Old-spec fonts order the pair Consonant,Virama and
/// new-spec ones Virama,Consonant, and some new-spec fonts shipped the
/// old-spec lookups unchanged - hb matches both orders, so this does too.
fn consonantPositionFromFace(plan: IndicPlan, consonant: u32) u8 {
    const glyphs = [3]u32{ plan.virama_glyph, consonant, plan.virama_glyph };
    if (plan.wouldSubstitute(tag_blwf, glyphs[0..2]) or plan.wouldSubstitute(tag_blwf, glyphs[1..3]) or
        plan.wouldSubstitute(tag_vatu, glyphs[0..2]) or plan.wouldSubstitute(tag_vatu, glyphs[1..3])) return ip_below_c;
    if (plan.wouldSubstitute(tag_pstf, glyphs[0..2]) or plan.wouldSubstitute(tag_pstf, glyphs[1..3])) return ip_post_c;
    if (plan.wouldSubstitute(tag_pref, glyphs[0..2]) or plan.wouldSubstitute(tag_pref, glyphs[1..3])) return ip_post_c;
    return ip_base_c;
}

/// Ported from `initial_reordering_consonant_syllable`, which
/// `initial_reordering_standalone_cluster` also delegates to.
fn initialReorderingSyllable(plan: IndicPlan, buffer: *Buffer, start: usize, end: usize) void {
    const info = buffer.info.items;
    const map = plan.map;
    const config = plan.config;

    if (config.is_kannada and start + 3 <= end and
        info[start].indic_category == ic_ra and info[start + 1].indic_category == ic_h and info[start + 2].indic_category == ic_zwj)
    {
        buffer.mergeClusters(start + 1, start + 3);
        const tmp = info[start + 1];
        info[start + 1] = info[start + 2];
        info[start + 2] = tmp;
    }

    var base: usize = end;
    var has_reph = false;
    {
        var limit = start;
        if (map.get1Mask(tag_rphf) != 0 and start + 3 <= end and
            ((config.reph_mode == .implicit and !isIndicJoiner(info[start + 2].indic_category)) or
                (config.reph_mode == .explicit and info[start + 2].indic_category == ic_zwj)))
        {
            const glyphs = [3]u32{
                info[start].codepoint,
                info[start + 1].codepoint,
                if (config.reph_mode == .explicit) info[start + 2].codepoint else 0,
            };
            if (plan.wouldSubstitute(tag_rphf, glyphs[0..2]) or
                (config.reph_mode == .explicit and plan.wouldSubstitute(tag_rphf, glyphs[0..3])))
            {
                limit = start + 2;
                while (limit < end and isIndicJoiner(info[limit].indic_category)) limit += 1;
                base = start;
                has_reph = true;
            }
        } else if (config.reph_mode == .log_repha and info[start].indic_category == ic_repha) {
            limit = start + 1;
            while (limit < end and isIndicJoiner(info[limit].indic_category)) limit += 1;
            base = start;
            has_reph = true;
        }

        var i = end;
        var seen_below = false;
        while (i > limit) {
            i -= 1;
            if (isIndicConsonant(info[i].indic_category)) {
                // A pre-base-reordering Ra was already given POS_POST_C by
                // `updateConsonantPositions`, so it is skipped here too.
                if (info[i].indic_position != ip_below_c and (info[i].indic_position != ip_post_c or seen_below)) {
                    base = i;
                    break;
                }
                if (info[i].indic_position == ip_below_c) seen_below = true;
                base = i;
            } else if (i > start and info[i].indic_category == ic_zwj and info[i - 1].indic_category == ic_h) {
                break;
            }
        }

        if (has_reph and base == start and limit - base <= 2) has_reph = false;
    }

    for (info[start..base]) |*g| g.indic_position = @min(ip_pre_c, g.indic_position);
    if (base < end) info[base].indic_position = ip_base_c;
    if (has_reph) info[start].indic_position = ip_ra_to_become_reph;

    if (plan.is_old_spec) {
        const disallow_double_halants = config.is_kannada;
        var i = base + 1;
        while (i < end) : (i += 1) {
            if (info[i].indic_category == ic_h) {
                var j = end - 1;
                while (j > i) : (j -= 1) {
                    if (isIndicConsonant(info[j].indic_category) or (disallow_double_halants and info[j].indic_category == ic_h)) break;
                }
                if (info[j].indic_category != ic_h and j > i) moveIndicGlyph(info, i, j);
                break;
            }
        }
    }

    {
        var last_pos: u8 = ip_start;
        var i = start;
        while (i < end) : (i += 1) {
            const c = info[i].indic_category;
            if (isIndicJoiner(c) or c == ic_n or c == ic_rs or c == ic_cm or c == ic_h) {
                info[i].indic_position = last_pos;
                if (c == ic_h and info[i].indic_position == ip_pre_m) {
                    var j = i;
                    while (j > start) {
                        j -= 1;
                        if (info[j].indic_position != ip_pre_m) {
                            info[i].indic_position = info[j].indic_position;
                            break;
                        }
                    }
                }
            } else if (info[i].indic_position != ip_smvd) {
                if (c == ic_mpst and i > start and info[i - 1].indic_category == ic_sm) info[i - 1].indic_position = info[i].indic_position;
                last_pos = info[i].indic_position;
            }
        }
    }

    {
        var last = base;
        var i = base + 1;
        while (i < end) : (i += 1) {
            if (isIndicConsonant(info[i].indic_category)) {
                var j = last + 1;
                while (j < i) : (j += 1) if (info[j].indic_position < ip_smvd) {
                    info[j].indic_position = info[i].indic_position;
                };
                last = i;
            } else if (info[i].indic_category == ic_m or info[i].indic_category == ic_mpst) {
                last = i;
            }
        }
    }

    indicSortByPosition(info, start, end);

    base = end;
    {
        var first_left_matra: usize = end;
        var last_left_matra: usize = end;
        var i = start;
        while (i < end) : (i += 1) {
            if (info[i].indic_position == ip_base_c) {
                base = i;
                break;
            } else if (info[i].indic_position == ip_pre_m) {
                if (first_left_matra == end) first_left_matra = i;
                last_left_matra = i;
            }
        }
        if (first_left_matra < last_left_matra) {
            buffer.reverseRange(first_left_matra, last_left_matra + 1);
            var ii = first_left_matra;
            var jj = ii;
            while (jj <= last_left_matra) : (jj += 1) {
                if (info[jj].indic_category == ic_m or info[jj].indic_category == ic_mpst) {
                    buffer.reverseRange(ii, jj + 1);
                    ii = jj + 1;
                }
            }
        }
    }
    // hb only merges the post-base run when the sort actually moved things
    // across the base; this port takes hb's own old-spec/long-syllable
    // shortcut of merging it unconditionally.
    buffer.mergeClusters(base, end);

    {
        var i = start;
        while (i < end and info[i].indic_position == ip_ra_to_become_reph) : (i += 1) info[i].mask |= map.get1Mask(tag_rphf);
    }
    {
        var mask = map.get1Mask(tag_half);
        if (!plan.is_old_spec and config.blwf_mode == .pre_and_post) mask |= map.get1Mask(tag_blwf);
        for (info[start..base]) |*g| g.mask |= mask;
    }
    if (base < end) {
        const mask = map.get1Mask(tag_blwf) | map.get1Mask(tag_abvf) | map.get1Mask(tag_pstf);
        for (info[base + 1 .. end]) |*g| g.mask |= mask;
    }

    if (plan.is_old_spec and config.is_devanagari) {
        var i = start;
        while (i + 1 < base) : (i += 1) {
            if (info[i].indic_category == ic_ra and info[i + 1].indic_category == ic_h and
                (i + 2 == base or info[i + 2].indic_category != ic_zwj))
            {
                info[i].mask |= map.get1Mask(tag_blwf);
                info[i + 1].mask |= map.get1Mask(tag_blwf);
            }
        }
    }

    const pref_mask = map.get1Mask(tag_pref);
    if (pref_mask != 0 and base + 2 < end) {
        var i = base + 1;
        while (i + 1 < end) : (i += 1) {
            const glyphs = [2]u32{ info[i].codepoint, info[i + 1].codepoint };
            if (plan.wouldSubstitute(tag_pref, &glyphs)) {
                info[i].mask |= pref_mask;
                info[i + 1].mask |= pref_mask;
                break;
            }
        }
    }

    {
        var i = start + 1;
        while (i < end) : (i += 1) {
            if (isIndicJoiner(info[i].indic_category)) {
                const non_joiner = info[i].indic_category == ic_zwnj;
                var j = i;
                while (true) {
                    j -= 1;
                    if (non_joiner) info[j].mask &= ~map.get1Mask(tag_half);
                    if (!(j > start and !isIndicConsonant(info[j].indic_category))) break;
                }
            }
        }
    }
}

/// Ported from `final_reordering_syllable_indic`: runs after the basic-forms
/// GSUB features, so it can tell a reph/pref candidate that actually ligated
/// from one the font declined to substitute.
fn finalReorderingSyllable(plan: IndicPlan, buffer: *Buffer, start: usize, end: usize) void {
    const info = buffer.info.items;
    const map = plan.map;
    const config = plan.config;
    const pref_mask = map.get1Mask(tag_pref);

    // Ligation may have destroyed the halant categories this function runs
    // on; recover the ones that are still literally the virama glyph.
    if (plan.virama_glyph != 0) {
        for (info[start..end]) |*g| {
            if (g.codepoint == plan.virama_glyph and g.is_ligated and g.is_multiplied) {
                g.indic_category = ic_h;
                g.is_ligated = false;
                g.is_multiplied = false;
            }
        }
    }

    var try_pref = pref_mask != 0;

    var base = start;
    while (base < end) : (base += 1) {
        if (info[base].indic_position < ip_base_c) continue;
        if (try_pref and base + 1 < end) {
            var i = base + 1;
            while (i < end) : (i += 1) {
                if (info[i].mask & pref_mask != 0) {
                    if (!(info[i].is_substituted and ligatedAndDidntMultiply(info[i]))) {
                        // A 'pref' candidate the font didn't form: the base
                        // is around here instead.
                        base = i;
                        while (base < end and info[base].indic_category == ic_h) base += 1;
                        if (base < end) info[base].indic_position = ip_base_c;
                        try_pref = false;
                    }
                    break;
                }
            }
            if (base == end) break;
        }
        if (config.is_malayalam) {
            var i = base + 1;
            while (i < end) : (i += 1) {
                while (i < end and isIndicJoiner(info[i].indic_category)) i += 1;
                if (i == end or info[i].indic_category != ic_h) break;
                i += 1;
                while (i < end and isIndicJoiner(info[i].indic_category)) i += 1;
                if (i < end and isIndicConsonant(info[i].indic_category) and info[i].indic_position == ip_below_c) {
                    base = i;
                    info[base].indic_position = ip_base_c;
                }
            }
        }
        if (start < base and info[base].indic_position > ip_base_c) base -= 1;
        break;
    }
    if (base == end and start < base and info[base - 1].indic_category == ic_zwj) base -= 1;
    if (base < end) {
        while (start < base and (info[base].indic_category == ic_n or info[base].indic_category == ic_h)) base -= 1;
    }

    if (start + 1 < end and start < base) {
        // If we lost track of base, position before the last thing instead.
        var new_pos = if (base == end) base - 2 else base - 1;

        // Malayalam/Tamil have no half or explicit-virama forms - what
        // 'half' produces there is a chillu or a ligated virama, and the
        // matra belongs after it.
        if (!config.is_malayalam and !config.is_tamil) {
            while (true) {
                while (new_pos > start and !(info[new_pos].indic_category == ic_m or
                    info[new_pos].indic_category == ic_mpst or info[new_pos].indic_category == ic_h)) new_pos -= 1;

                if (info[new_pos].indic_category == ic_h and info[new_pos].indic_position != ip_pre_m) {
                    // Uniscribe keeps the matra left of a Halant,ZWJ, so
                    // keep searching past it; a Halant,ZWNJ never gets here
                    // (the syllable machine ends the syllable at it).
                    if (new_pos + 1 < end and info[new_pos + 1].indic_category == ic_zwj and new_pos > start) {
                        new_pos -= 1;
                        continue;
                    }
                } else {
                    new_pos = start;
                }
                break;
            }
        }

        if (start < new_pos and info[new_pos].indic_position != ip_pre_m) {
            var i = new_pos;
            while (i > start) : (i -= 1) {
                if (info[i - 1].indic_position == ip_pre_m) {
                    const old_pos = i - 1;
                    if (old_pos < base and base <= new_pos) base -= 1;
                    moveIndicGlyph(info, old_pos, new_pos);
                    // Intentionally after the move: Indic matra reordering
                    // owns the cluster of everything it passed over.
                    buffer.mergeClusters(new_pos, @min(end, base + 1));
                    new_pos -= 1;
                }
            }
        } else {
            var i = start;
            while (i < base) : (i += 1) {
                if (info[i].indic_position == ip_pre_m) {
                    buffer.mergeClusters(i, @min(end, base + 1));
                    break;
                }
            }
        }
    }

    // A reph spelled Ra,H (or Ra,H,ZWJ) moves only if it ligated into the
    // reph form; a Repha encoded as its own character moves only if it
    // did *not* ligate (a font that ligated it is doing the job itself).
    if (start + 1 < end and info[start].indic_position == ip_ra_to_become_reph and
        ((info[start].indic_category == ic_repha) != ligatedAndDidntMultiply(info[start])))
    {
        const new_reph_pos = indicRephTargetPosition(info, config.reph_pos, start, base, end);
        buffer.mergeClusters(start, new_reph_pos + 1);
        moveIndicGlyph(info, start, new_reph_pos);
        if (start < base and base <= new_reph_pos) base -= 1;
    }

    if (try_pref and base + 1 < end) {
        var i = base + 1;
        while (i < end) : (i += 1) {
            if (info[i].mask & pref_mask != 0) {
                // Only a glyph the font actually produced gets reordered.
                if (ligatedAndDidntMultiply(info[i])) {
                    var new_pos = base;
                    if (!config.is_malayalam and !config.is_tamil) {
                        while (new_pos > start and !(info[new_pos - 1].indic_category == ic_m or
                            info[new_pos - 1].indic_category == ic_mpst or info[new_pos - 1].indic_category == ic_h)) new_pos -= 1;
                    }
                    if (new_pos > start and info[new_pos - 1].indic_category == ic_h) {
                        if (new_pos < end and isIndicJoiner(info[new_pos].indic_category)) new_pos += 1;
                    }
                    const old_pos = i;
                    buffer.mergeClusters(new_pos, old_pos + 1);
                    moveIndicGlyph(info, old_pos, new_pos);
                    if (new_pos <= base and base < old_pos) base += 1;
                }
                break;
            }
        }
    }

    if (info[start].indic_position == ip_pre_m) {
        if (start == 0) {
            info[start].mask |= map.get1Mask(tag_init);
        } else {
            buffer.unsafeToBreak(start - 1, start + 1);
        }
    }
}

fn forEachIndicSyllable(buffer: *Buffer, plan: IndicPlan, comptime reorder: fn (IndicPlan, *Buffer, usize, usize) void) void {
    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const syl = buffer.info.items[start].indic_syllable;
        var end = start + 1;
        while (end < buffer.info.items.len and buffer.info.items[end].indic_syllable == syl) end += 1;

        const stype = syl & 0x0F;
        if (stype == indic_syllable_consonant or stype == indic_syllable_vowel or
            stype == indic_syllable_standalone or stype == indic_syllable_broken)
        {
            reorder(plan, buffer, start, end);
        }
        start = end;
    }
}

fn indicPlan(font: parsing.Font, map: Map, config: IndicScriptConfig, cmap: ?Cmap) IndicPlan {
    return .{
        .font = font,
        .map = map,
        .config = config,
        .is_old_spec = indicIsOldSpec(map),
        .virama_glyph = if (cmap) |c| (c.lookup(config.virama) orelse 0) else 0,
    };
}

/// Ported from `setup_masks_indic` + `setup_syllables_indic`. Must run
/// before `mapGlyphsFast` overwrites `codepoint` with a glyph id -
/// `setIndicProperties` needs the original Unicode codepoint, and
/// `insertDottedCircles` inserts one. hb runs syllabification as the
/// shaper's first GSUB pause instead, i.e. after 'locl'/'ccmp'; nothing in
/// those two features feeds the syllable machine, which reads categories,
/// not glyphs.
pub fn setupMasksIndic(buffer: *Buffer, cmap: ?Cmap) !void {
    for (buffer.info.items) |*info| setIndicProperties(info);
    findSyllablesIndic(buffer);
    _ = try common.insertDottedCircles(buffer, cmap, indic_syllable_broken, ic_dottedcircle, ic_repha, ip_end, false);

    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const syl = buffer.info.items[start].indic_syllable;
        var end = start + 1;
        while (end < buffer.info.items.len and buffer.info.items[end].indic_syllable == syl) end += 1;
        buffer.unsafeToBreak(start, end);
        start = end;
    }
}

/// Ported from `initial_reordering_indic`: the GSUB pause after
/// 'locl'/'ccmp' and before the basic-forms features.
pub fn initialReorderingIndic(font: parsing.Font, buffer: *Buffer, map: Map, config: IndicScriptConfig, cmap: ?Cmap) void {
    const plan = indicPlan(font, map, config, cmap);
    if (plan.virama_glyph != 0) {
        for (buffer.info.items) |*info| {
            if (info.indic_position == ip_base_c) info.indic_position = consonantPositionFromFace(plan, info.codepoint);
        }
    }
    forEachIndicSyllable(buffer, plan, initialReorderingSyllable);
}

/// Ported from `final_reordering_indic`: the GSUB pause after the
/// basic-forms features and before the presentation-forms ones.
pub fn finalReorderingIndic(font: parsing.Font, buffer: *Buffer, map: Map, config: IndicScriptConfig, cmap: ?Cmap) void {
    forEachIndicSyllable(buffer, indicPlan(font, map, config, cmap), finalReorderingSyllable);
}
