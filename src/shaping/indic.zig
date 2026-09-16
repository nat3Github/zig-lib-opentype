const std = @import("std");
const common = @import("common.zig");
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
// Reordering (`reorderIndicSyllable`) merges hb's initial_reordering +
// final_reordering into one pre-GSUB pass, since this port's MapBuilder has
// no GSUB-pause machinery (see its module doc comment) to interleave
// reordering with per-feature lookup application the way hb does. Three
// consequences, all documented inline at their call sites:
//   - `consonant_position_from_face`, the rphf/pref candidate detection,
//     and the reph/pref "did it actually ligate" checks all use
//     `hb_ot_layout_lookup_would_substitute` (a GSUB dry-run against the
//     font) to confirm a lookup exists/fired before repositioning. This
//     port approximates all of those with pure Unicode-category syntax
//     (e.g. "Ra immediately after Halant" is always a pref candidate,
//     without checking the font actually has a pref lookup for it). Real
//     Indic fonts overwhelmingly follow the spec's syntactic patterns, so
//     this produces correct shaping for well-formed text against
//     conformant fonts; it can over-fire a reorder for a font that ships
//     the categories but not the matching GSUB feature.
//   - the pre-base-reordering Ra ("pref") physical move is dropped
//     entirely (mask-only): without post-substitution ligation state,
//     safely relocating a not-yet-ligated 2-glyph Halant+Ra span is
//     index-arithmetic-heavy for a narrow win (this affects only a few
//     conjunct patterns in Kannada/Malayalam/Telugu-style scripts); the
//     'pref' GSUB feature still gets masked on and fires in place.
//   - dotted-circle insertion for broken (malformed) syllables runs via
//     `common.insertDottedCircles` right after syllabification, since this
//     port has no GSUB-pause machinery to run it mid-pipeline like hb does
//     - see that function's doc comment.

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
const ic_zwnj: u8 = 5;
const ic_zwj: u8 = 6;
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
    reph_pos: IndicRephPosition,
    reph_mode: IndicRephMode,
    blwf_mode: IndicBlwfMode,
    is_devanagari: bool,
    is_kannada: bool,
    is_malayalam: bool,
};

/// Ported from `indic_configs` (virama codepoints dropped - this port
/// doesn't need the font virama-glyph recovery `final_reordering_indic`
/// uses, since it isn't tracking post-ligation glyph identity; see this
/// section's top doc comment).
const indic_script_configs = [9]IndicScriptConfig{
    .{ .tag1 = deva_tag, .tag2 = dev2_tag, .reph_pos = .before_post, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = true, .is_kannada = false, .is_malayalam = false },
    .{ .tag1 = beng_tag, .tag2 = bng2_tag, .reph_pos = .after_sub, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false },
    .{ .tag1 = guru_tag, .tag2 = gur2_tag, .reph_pos = .before_sub, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false },
    .{ .tag1 = gujr_tag, .tag2 = gjr2_tag, .reph_pos = .before_post, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false },
    .{ .tag1 = orya_tag, .tag2 = ory2_tag, .reph_pos = .after_main, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false },
    .{ .tag1 = taml_tag, .tag2 = tml2_tag, .reph_pos = .after_post, .reph_mode = .implicit, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = false },
    .{ .tag1 = telu_tag, .tag2 = tel2_tag, .reph_pos = .after_post, .reph_mode = .explicit, .blwf_mode = .post_only, .is_devanagari = false, .is_kannada = false, .is_malayalam = false },
    .{ .tag1 = knda_tag, .tag2 = knd2_tag, .reph_pos = .after_post, .reph_mode = .implicit, .blwf_mode = .post_only, .is_devanagari = false, .is_kannada = true, .is_malayalam = false },
    .{ .tag1 = mlym_tag, .tag2 = mlm2_tag, .reph_pos = .after_main, .reph_mode = .log_repha, .blwf_mode = .pre_and_post, .is_devanagari = false, .is_kannada = false, .is_malayalam = true },
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

/// Ported from `collect_features_indic`, minus the `loc`l/`ccmp` enables
/// (already unconditionally enabled by `shape()`'s `default_features`, see
/// its doc comment) and the pause registrations (no pause machinery in this
/// port, see the module doc comment). `rphf`/`pref`/`blwf`/`abvf`/`half`/
/// `pstf`/`init` are added non-globally (`addFeature`, not `enableFeature`)
/// so `MapBuilder.compile` allocates real mask bits `reorderIndicSyllable`
/// can assign per-glyph via `map.get1Mask`.
pub fn collectFeaturesIndic(map_builder: *MapBuilder) !void {
    const manual_joiners = MapFeatureFlags{ .manual_zwnj = true, .manual_zwj = true };
    try map_builder.enableFeature(tag_nukt, manual_joiners, 1);
    try map_builder.enableFeature(tag_akhn, manual_joiners, 1);
    try map_builder.addFeature(tag_rphf, manual_joiners, 1);
    try map_builder.enableFeature(tag_rkrf, manual_joiners, 1);
    try map_builder.addFeature(tag_pref, manual_joiners, 1);
    try map_builder.addFeature(tag_blwf, manual_joiners, 1);
    try map_builder.addFeature(tag_abvf, manual_joiners, 1);
    try map_builder.addFeature(tag_half, manual_joiners, 1);
    try map_builder.addFeature(tag_pstf, manual_joiners, 1);
    try map_builder.enableFeature(tag_vatu, manual_joiners, 1);
    try map_builder.enableFeature(tag_cjct, manual_joiners, 1);
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

/// Ported from `initial_reordering_consonant_syllable` +
/// `final_reordering_syllable_indic`, merged into one pre-GSUB pass - see
/// this section's top doc comment for what that drops relative to hb.
/// Runs on `consonant_syllable`/`vowel_syllable`/`standalone_cluster`/
/// `broken_cluster` syllables only (`symbol_cluster`/`non_indic_cluster`
/// are passed through unchanged, matching
/// `initial_reordering_syllable_indic`'s switch).
fn reorderIndicSyllable(buffer: *Buffer, map: Map, config: IndicScriptConfig, is_old_spec: bool, start: usize, end: usize) void {
    const info = buffer.info.items;

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
        if (start + 3 <= end and info[start].indic_category == ic_ra and info[start + 1].indic_category == ic_h and
            ((config.reph_mode == .implicit and !isIndicJoiner(info[start + 2].indic_category)) or
                (config.reph_mode == .explicit and info[start + 2].indic_category == ic_zwj)))
        {
            limit = start + 2;
            while (limit < end and isIndicJoiner(info[limit].indic_category)) limit += 1;
            base = start;
            has_reph = true;
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
                // hb's `consonant_position_from_face` reclassifies a
                // mid-syllable Ra to POS_BELOW_C/POS_POST_C when the font's
                // blwf/vatu/pstf/pref lookups would actually substitute it
                // there (approximated away, see this section's top doc
                // comment); a non-final Ra directly followed by another
                // Halant is syntactically always such a conjunct-forming Ra
                // (vattu/rakar/pref) across these scripts regardless of the
                // specific font, so skip it as a base candidate the same
                // way a real below/post form would be skipped.
                const is_reordering_ra = info[i].indic_category == ic_ra and i + 1 < end and info[i + 1].indic_category == ic_h;
                if (!is_reordering_ra and info[i].indic_position != ip_below_c and (info[i].indic_position != ip_post_c or seen_below)) {
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

    if (is_old_spec) {
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
        // hb merges pre-base matra clusters into the base as part of the
        // matra-repositioning search this port doesn't do (see this
        // section's top doc comment); approximate by merging the whole
        // pre-base run into the base's cluster whenever a left matra moved
        // there, so the reordered matra keeps the base's cluster/cursor
        // position instead of its own original one.
        if (first_left_matra < end) buffer.mergeClusters(start, @min(end, base + 1));
    }
    buffer.mergeClusters(base, end);

    {
        var i = start;
        while (i < end and info[i].indic_position == ip_ra_to_become_reph) : (i += 1) info[i].mask |= map.get1Mask(tag_rphf);
    }
    {
        var mask = map.get1Mask(tag_half);
        if (!is_old_spec and config.blwf_mode == .pre_and_post) mask |= map.get1Mask(tag_blwf);
        for (info[start..base]) |*g| g.mask |= mask;
    }
    if (base < end) {
        const mask = map.get1Mask(tag_blwf) | map.get1Mask(tag_abvf) | map.get1Mask(tag_pstf);
        for (info[base + 1 .. end]) |*g| g.mask |= mask;
    }

    if (is_old_spec and config.is_devanagari) {
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

    if (map.get1Mask(tag_pref) != 0 and base + 2 <= end) {
        var i = base + 1;
        while (i + 1 < end) : (i += 1) {
            if (info[i].indic_category == ic_h and info[i + 1].indic_category == ic_ra) {
                info[i].mask |= map.get1Mask(tag_pref);
                info[i + 1].mask |= map.get1Mask(tag_pref);
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

    if (start + 1 < end and info[start].indic_position == ip_ra_to_become_reph) {
        const new_reph_pos = indicRephTargetPosition(info, config.reph_pos, start, base, end);
        buffer.mergeClusters(start, new_reph_pos + 1);
        moveIndicGlyph(info, start, new_reph_pos);
        if (start < base and base <= new_reph_pos) base -= 1;
    }

    if (info[start].indic_position == ip_pre_m) {
        if (start == 0) {
            info[start].mask |= map.get1Mask(tag_init);
        } else {
            buffer.unsafeToBreak(start - 1, start + 1);
        }
    }
}

/// Ported from `setup_masks_indic` + `setup_syllables_indic` +
/// `initial_reordering_indic` + `final_reordering_indic`, collapsed into
/// one pre-GSUB pass at the same call site `setupMasksHangul`/
/// `setupMasksArabic` use (see the module doc comment on why this port has
/// no GSUB-pause machinery to run these as separate stages). Must run
/// before `mapGlyphsFast` overwrites `codepoint` with a glyph id -
/// `setIndicProperties` needs the original Unicode codepoint.
pub fn setupMasksIndic(buffer: *Buffer, map: Map, config: IndicScriptConfig, cmap: ?Cmap) !void {
    for (buffer.info.items) |*info| setIndicProperties(info);
    findSyllablesIndic(buffer);
    _ = try common.insertDottedCircles(buffer, cmap, indic_syllable_broken, ic_dottedcircle, ic_repha, ip_end);

    const is_old_spec = indicIsOldSpec(map);
    var start: usize = 0;
    while (start < buffer.info.items.len) {
        const syl = buffer.info.items[start].indic_syllable;
        var end = start + 1;
        while (end < buffer.info.items.len and buffer.info.items[end].indic_syllable == syl) end += 1;
        buffer.unsafeToBreak(start, end);

        const stype = syl & 0x0F;
        if (stype == indic_syllable_consonant or stype == indic_syllable_vowel or
            stype == indic_syllable_standalone or stype == indic_syllable_broken)
        {
            reorderIndicSyllable(buffer, map, config, is_old_spec, start, end);
        }
        start = end;
    }
}
