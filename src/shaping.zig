const std = @import("std");
const parsing = @import("parsing.zig");

const common = @import("shaping/common.zig");
const metrics_mod = @import("shaping/metrics.zig");
const map_mod = @import("shaping/map.zig");
const apply_mod = @import("shaping/apply.zig");
const normalize_mod = @import("shaping/normalize.zig");
const hangul_mod = @import("shaping/hangul.zig");
const arabic_mod = @import("shaping/arabic.zig");
const thai_lao_mod = @import("shaping/thai_lao.zig");
const indic_mod = @import("shaping/indic.zig");
const khmer_myanmar_mod = @import("shaping/khmer_myanmar.zig");
const use_mod = @import("shaping/use.zig");
const unicode = @import("unicode.zig");

pub const glyph_flag_unsafe_to_break = common.glyph_flag_unsafe_to_break;
pub const glyph_flag_unsafe_to_concat = common.glyph_flag_unsafe_to_concat;
pub const glyph_flag_safe_to_insert_tatweel = common.glyph_flag_safe_to_insert_tatweel;
pub const glyph_flag_defined = common.glyph_flag_defined;
pub const GlyphInfo = common.GlyphInfo;
pub const GlyphPosition = common.GlyphPosition;
pub const Direction = common.Direction;
pub const ClusterLevel = common.ClusterLevel;
pub const Buffer = common.Buffer;
pub const Tag = common.Tag;

pub const EndMetric = metrics_mod.EndMetric;
pub const GlyphMetrics = metrics_mod.GlyphMetrics;
pub const measureGlyphRange = metrics_mod.measureGlyphRange;

pub const Map = map_mod.Map;
pub const MapBuilder = map_mod.MapBuilder;
pub const MapFeatureFlags = map_mod.MapFeatureFlags;
pub const FeatureMapEntry = map_mod.FeatureMapEntry;
pub const LookupMapEntry = map_mod.LookupMapEntry;
pub const StageMapEntry = map_mod.StageMapEntry;

const containsTag = common.containsTag;
const applyTable = apply_mod.applyTable;
const applyDefaultHorizontalAdvances = apply_mod.applyDefaultHorizontalAdvances;
const zeroMarkWidthsByGdef = apply_mod.zeroMarkWidthsByGdef;
const hideDefaultIgnorables = apply_mod.hideDefaultIgnorables;
const zeroDefaultIgnorableAdvances = apply_mod.zeroDefaultIgnorableAdvances;
const finishGposOffsets = apply_mod.finishGposOffsets;
const table_tag_gdef = apply_mod.table_tag_gdef;
const normalize = normalize_mod.normalize;
const setJoinerFlags = normalize_mod.setJoinerFlags;
const mapGlyphsFast = normalize_mod.mapGlyphsFast;
const hang_script_tag = hangul_mod.hang_script_tag;
const collectFeaturesHangul = hangul_mod.collectFeaturesHangul;
const overrideFeaturesHangul = hangul_mod.overrideFeaturesHangul;
const preprocessHangul = hangul_mod.preprocessHangul;
const setupMasksHangul = hangul_mod.setupMasksHangul;
const arab_script_tag = arabic_mod.arab_script_tag;
const syrc_script_tag = arabic_mod.syrc_script_tag;
const collectFeaturesArabic = arabic_mod.collectFeaturesArabic;
const setupMasksArabic = arabic_mod.setupMasksArabic;
const tag_liga = arabic_mod.tag_liga;
const thai_script_tag = thai_lao_mod.thai_script_tag;
const lao_script_tag = thai_lao_mod.lao_script_tag;
const preprocessTextThai = thai_lao_mod.preprocessTextThai;
const findIndicConfig = indic_mod.findIndicConfig;
const collectFeaturesIndic = indic_mod.collectFeaturesIndic;
const setupMasksIndic = indic_mod.setupMasksIndic;
const khmr_script_tag = khmer_myanmar_mod.khmr_script_tag;
const mym2_script_tag = khmer_myanmar_mod.mym2_script_tag;
const collectFeaturesKhmer = khmer_myanmar_mod.collectFeaturesKhmer;
const overrideFeaturesKhmer = khmer_myanmar_mod.overrideFeaturesKhmer;
const setupMasksKhmer = khmer_myanmar_mod.setupMasksKhmer;
const collectFeaturesMyanmar = khmer_myanmar_mod.collectFeaturesMyanmar;
const setupMasksMyanmar = khmer_myanmar_mod.setupMasksMyanmar;
const use_script_tags = use_mod.use_script_tags;
const collectFeaturesUse = use_mod.collectFeaturesUse;
const setupMasksUse = use_mod.setupMasksUse;

const tag_dflt_script = Tag{ 'D', 'F', 'L', 'T' };
const tag_latn_script = Tag{ 'l', 'a', 't', 'n' };
const tag_mymr_script = Tag{ 'm', 'y', 'm', 'r' };

/// GSUB/GPOS feature tags this port's apply engine actually implements
/// lookup types for (see apply.zig's top doc comment), intersected with
/// hb-ot-shape.cc's `common_features`/`horizontal_features` default set.
/// `mark`/`mkmk`/`curs` now included now that GPOS 3/4/5/6 are ported;
/// `calt`/`rclt` now included now that GSUB/GPOS Context/ChainContext (all
/// three formats) are ported - see apply.zig's top doc comment. `abvm`/
/// `blwm` are GPOS-only (Above/Below-base Mark Positioning - MarkBasePos/
/// MarkMarkPos, same lookup types as `mark`/`mkmk`) despite the name
/// resemblance to Indic's GSUB reordering features (`pref`/`blwf`/`half`,
/// still out of scope); included now since apply.zig already supports
/// their lookup types. `dist` (hb's `horizontal_features`, same tier as
/// `kern`) is a global GPOS-only feature - not Indic-specific despite the
/// name resemblance to Indic-only GSUB reordering features - and needed
/// even for scripts without a complex shaper (e.g. an Indic ChainContextPos
/// rule nesting a PairPos/SinglePos lookup under `dist` to reposition a
/// mark after a dotted-circle insertion).
pub const default_features = [_]Tag{
    .{ 'c', 'c', 'm', 'p' },
    .{ 'l', 'o', 'c', 'l' },
    .{ 'a', 'b', 'v', 'm' },
    .{ 'b', 'l', 'w', 'm' },
    .{ 'm', 'a', 'r', 'k' },
    .{ 'm', 'k', 'm', 'k' },
    .{ 'r', 'l', 'i', 'g' },
    .{ 'c', 'a', 'l', 't' },
    .{ 'c', 'u', 'r', 's' },
    .{ 'l', 'i', 'g', 'a' },
    .{ 'c', 'l', 'i', 'g' },
    .{ 'r', 'c', 'l', 't' },
    .{ 'k', 'e', 'r', 'n' },
    .{ 'd', 'i', 's', 't' },
};

/// Shapes `codepoints` against `font`: maps to glyph ids via cmap, then
/// runs the compiled GSUB/GPOS lookups for `script_tags`/`language_tags`
/// (first match wins, falling back to DFLT/dflt/latn - see MapBuilder.init)
/// with `default_features` plus any caller-supplied `extra_features`
/// enabled globally. `extra_features` exists for tests exercising specific
/// lookups the default feature set doesn't turn on (e.g. the shaping
/// conformance corpus's synthetic "test" feature). If `hang` appears in
/// `script_tags`, the Hangul complex shaper (see its section above) runs
/// first: syllable decompose/compose plus ljmo/vjmo/tjmo feature masking.
pub fn shape(
    allocator: std.mem.Allocator,
    font: parsing.Font,
    codepoints: []const u21,
    direction: Direction,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
) (parsing.Font.ParseError || error{OutOfMemory})!Buffer {
    return shapeImpl(allocator, font, codepoints, direction, script_tags, language_tags, extra_features, &.{}, null);
}

/// Same as `shape`, but `normalized_coords` (per-axis values in [-1, 1],
/// `fvar` axis order, already through `avar` remapping - see
/// `render.Renderer`'s `normalizedCoords`) apply HVAR advance-width deltas
/// on top of the default `hmtx` widths. Outline shape variation (`gvar`) is
/// handled separately by the rasterizer; this only affects `x_advance`.
pub fn shapeVaried(
    allocator: std.mem.Allocator,
    font: parsing.Font,
    codepoints: []const u21,
    direction: Direction,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
    normalized_coords: []const f32,
) (parsing.Font.ParseError || error{OutOfMemory})!Buffer {
    return shapeImpl(allocator, font, codepoints, direction, script_tags, language_tags, extra_features, normalized_coords, null);
}

/// Sub-range of a `shape*` call's `codepoints` to actually emit glyphs for.
/// Codepoints outside it are still shaped -- they supply the surrounding
/// context that ligation, Arabic joining, and mark attachment depend on --
/// but their glyphs are dropped from the result. Mirrors HarfBuzz's
/// `hb_buffer_add_utf8` `item_offset`/`item_length`.
pub const Item = struct {
    start: usize,
    end: usize,
};

/// Same as `shape`, but only emits glyphs whose cluster falls inside `item`;
/// `codepoints` outside it act as pre/post shaping context. Use when the
/// caller holds more text than it wants glyphs for: a styled run inside a
/// larger paragraph (so a ligature or joining form spanning the style
/// boundary still resolves against its real neighbours), or a truncated
/// measurement window whose tail would otherwise be shaped as if the text
/// ended there.
pub fn shapeWithContext(
    allocator: std.mem.Allocator,
    font: parsing.Font,
    codepoints: []const u21,
    item: Item,
    direction: Direction,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
) (parsing.Font.ParseError || error{OutOfMemory})!Buffer {
    return shapeImpl(allocator, font, codepoints, direction, script_tags, language_tags, extra_features, &.{}, item);
}

fn shapeImpl(
    allocator: std.mem.Allocator,
    font: parsing.Font,
    codepoints: []const u21,
    direction: Direction,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
    normalized_coords: []const f32,
    item: ?Item,
) (parsing.Font.ParseError || error{OutOfMemory})!Buffer {
    var buffer = Buffer.init(allocator);
    errdefer buffer.deinit();

    // Glyph count starts 1:1 with codepoints; presizing avoids the ~log2(n)
    // growth reallocations `.add()` would otherwise trigger per call.
    try buffer.info.ensureTotalCapacityPrecise(allocator, codepoints.len);
    try buffer.out_info.ensureTotalCapacityPrecise(allocator, codepoints.len);

    const cmap: ?parsing.Table.cmap.Resolved = if (font.tableData(.{ 'c', 'm', 'a', 'p' })) |d| parsing.Table.cmap.resolve(d) else null;
    for (codepoints, 0..) |cp, i| try buffer.add(cp, @intCast(i));

    const is_hangul = containsTag(script_tags, hang_script_tag);
    const is_arabic = containsTag(script_tags, arab_script_tag) or containsTag(script_tags, syrc_script_tag);
    const is_thai = containsTag(script_tags, thai_script_tag);
    const is_lao = containsTag(script_tags, lao_script_tag);
    const is_khmer = containsTag(script_tags, khmr_script_tag);

    // Map-building only depends on font+tags, not buffer glyph content, so
    // it happens before any shaper preprocessing (vs. a naive
    // preprocess-then-map order) both to give setupMasksHangul a chance to
    // run while `codepoint` still holds Unicode values, matching hb's real
    // ordering (setup_masks runs right after normalize, before
    // hb_ot_map_glyphs_fast), and because `preprocessTextThai`'s PUA-
    // fallback check needs `map.found_script[0]` - in hb this works because
    // the plan (which owns the map) is built once, before preprocess_text
    // even runs.
    var map_builder = try MapBuilder.init(allocator, font, script_tags, language_tags);
    defer map_builder.deinit();

    // Ported from `hb_ot_shaper_categorize`: the old-spec Indic, Myanmar,
    // and USE-family complex shapers only run if the font actually declares
    // GSUB support for the requested script - a font that only ships
    // DFLT/latn (or, for Myanmar, the pre-mym2 'mymr' tag) gets the plain
    // default shaper instead, even though the buffer's Unicode script maps
    // to one of these. Skipping this check made the USE shaper's broken-
    // cluster/dotted-circle logic fire on fonts with no script-specific
    // GSUB table at all (e.g. a Tai Viet vowel sign in a font whose GSUB
    // only has DFLT/cyrl/dev2/grek/latn), diverging from hb/browsers.
    // A font with no GSUB table at all (or none of the requested/DFLT/latn
    // scripts present) resolves to `null` here, matching hb's HB_TAG_NONE -
    // that's NOT the same as the font *having* a GSUB table that explicitly
    // resolves to DFLT/latn, so `null` must NOT gate off the complex shaper
    // (a bare cmap-only test font still gets Indic/USE reordering in hb).
    const gsub_script = map_builder.chosen_script[0];
    const gsub_is_dflt_or_latn = gsub_script != null and
        (std.mem.eql(u8, &gsub_script.?, &tag_dflt_script) or
            std.mem.eql(u8, &gsub_script.?, &tag_latn_script));

    const indic_config = if (gsub_is_dflt_or_latn) null else findIndicConfig(script_tags);
    const is_myanmar = containsTag(script_tags, mym2_script_tag) and
        !gsub_is_dflt_or_latn and
        !(gsub_script != null and std.mem.eql(u8, &gsub_script.?, &tag_mymr_script));
    var is_use = false;
    if (!gsub_is_dflt_or_latn) {
        for (use_script_tags) |tag| {
            if (containsTag(script_tags, tag)) {
                is_use = true;
                break;
            }
        }
    }
    var is_use_arabic_joining = false;
    for (use_mod.use_arabic_joining_script_tags) |tag| {
        if (containsTag(script_tags, tag)) {
            is_use_arabic_joining = true;
            break;
        }
    }
    if (is_hangul) try collectFeaturesHangul(&map_builder);
    if (is_arabic) try collectFeaturesArabic(&map_builder);
    if (indic_config != null) try collectFeaturesIndic(&map_builder);
    if (is_khmer) try collectFeaturesKhmer(&map_builder);
    if (is_myanmar) try collectFeaturesMyanmar(&map_builder);
    if (is_use) try collectFeaturesUse(&map_builder);
    for (default_features) |tag| try map_builder.enableFeature(tag, .{ .global = true }, 1);
    for (extra_features) |tag| try map_builder.enableFeature(tag, .{ .global = true }, 1);
    if (is_hangul) try overrideFeaturesHangul(&map_builder);
    if (is_khmer) try overrideFeaturesKhmer(&map_builder);
    if (indic_config != null) try map_builder.disableFeature(tag_liga);
    var map = try map_builder.compile(allocator);
    defer map.deinit(allocator);

    // hb runs the shaper's preprocess_text (Hangul syllable decompose/
    // compose, Thai SARA AM reorder/PUA fallback - see those shapers'
    // sections above) before normalize.
    if (is_hangul) try preprocessHangul(font, &buffer, cmap);
    if (is_thai or is_lao) try preprocessTextThai(&buffer, cmap, is_thai, map.found_script[0]);

    // COMPOSED_DIACRITICS_NO_SHORT_CIRCUIT in hb's terms - see normalize()'s
    // doc comment for why these four complex shapers need it.
    const might_short_circuit = !(indic_config != null or is_khmer or is_myanmar or is_use);
    const block_mark_recompose = indic_config != null or is_khmer or is_use;
    try normalize(&buffer, cmap, might_short_circuit, block_mark_recompose);

    buffer.resetMasks(map.global_mask);
    if (is_hangul) setupMasksHangul(&buffer, map);
    if (is_arabic) setupMasksArabic(&buffer, map);
    if (indic_config) |cfg| try setupMasksIndic(&buffer, map, cfg.*, cmap);
    if (is_khmer) try setupMasksKhmer(&buffer, map, cmap);
    if (is_myanmar) try setupMasksMyanmar(&buffer, cmap);
    if (is_use) try setupMasksUse(&buffer, map, cmap, is_use_arabic_joining);

    setJoinerFlags(&buffer);
    mapGlyphsFast(&buffer);

    const gdef_data = font.tableData(table_tag_gdef);
    const gdef_classdef: apply_mod.Gdef = if (gdef_data) |d| .{
        .classes = parsing.Table.Gdef.glyphClassDef(d) catch null,
        .mark_attach = parsing.Table.Gdef.markAttachClassDef(d) catch null,
        .mark_sets = parsing.Table.Gdef.markGlyphSets(d) catch null,
    } else .{};

    try applyTable(font, map, 0, gdef_classdef, &buffer, direction);
    hideDefaultIgnorables(&buffer, cmap);
    try buffer.clearPositions();
    applyDefaultHorizontalAdvances(font, &buffer, normalized_coords);
    // hb-ot-shape.cc's `zero_width_marks` shaper property: the Indic,
    // Khmer and Hangul shapers never zero mark advances (their fonts carry
    // real advances on marks that GPOS 'dist'/abvm/blwm then positions),
    // USE and Myanmar zero them *before* GPOS, everything else after.
    const zero_marks_early = is_use or is_myanmar;
    const zero_marks_late = !(zero_marks_early or is_hangul or is_khmer or indic_config != null);
    if (zero_marks_early) zeroMarkWidthsByGdef(&buffer, gdef_classdef);
    try applyTable(font, map, 1, gdef_classdef, &buffer, direction);
    if (zero_marks_late) zeroMarkWidthsByGdef(&buffer, gdef_classdef);
    finishGposOffsets(&buffer, direction);
    zeroDefaultIgnorableAdvances(&buffer, direction);

    // hb-ot-shape.cc hb_ot_position(): backward directions are shaped in
    // logical order and flipped to visual order as the final position step.
    if (direction == .right_to_left or direction == .bottom_to_top) buffer.reverse();

    if (item) |it| retainItemGlyphs(&buffer, it);

    return buffer;
}

/// Drops glyphs whose cluster lies outside `item`, keeping `info`/`pos`
/// parallel. Runs last, after positioning: context glyphs must survive every
/// GSUB/GPOS pass to influence the ones we keep, and only then go away.
fn retainItemGlyphs(buffer: *Buffer, item: Item) void {
    var kept: usize = 0;
    for (buffer.info.items, buffer.pos.items) |info, pos| {
        if (info.cluster < item.start or info.cluster >= item.end) continue;
        buffer.info.items[kept] = info;
        buffer.pos.items[kept] = pos;
        kept += 1;
    }
    buffer.info.shrinkRetainingCapacity(kept);
    buffer.pos.shrinkRetainingCapacity(kept);
    buffer.idx = @min(buffer.idx, kept);
}

/// Runs UAX #9 (via `unicode.Bidi`) over `codepoints`, itemizes into
/// (script × bidi-level) runs, shapes each run with `shape()` using the
/// direction implied by its resolved level (even = LTR, odd = RTL) and —
/// when `script_tags` is empty — the OpenType script tag guessed from the
/// run's Unicode Script, then concatenates the runs in visual order
/// (rule L2). `shape()` alone only applies a single caller-supplied
/// direction and script to the whole buffer, so mixed-direction and
/// mixed-script text (Arabic with Latin, Arabic marks next to Latin
/// letters) needs this wrapper. Cluster values in the returned buffer
/// index into the original `codepoints` slice.
pub fn shapeBidiParagraph(
    allocator: std.mem.Allocator,
    font: parsing.Font,
    codepoints: []const u21,
    base_direction: unicode.Bidi.ParagraphDirection,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
) (parsing.Font.ParseError || unicode.Bidi.Error || error{OutOfMemory})!Buffer {
    return shapeBidiParagraphVaried(allocator, font, codepoints, base_direction, script_tags, language_tags, extra_features, &.{});
}

/// Same as `shapeBidiParagraph`, threading `normalized_coords` into each
/// run's `shapeVaried` call - see `shapeVaried` for what it affects.
pub fn shapeBidiParagraphVaried(
    allocator: std.mem.Allocator,
    font: parsing.Font,
    codepoints: []const u21,
    base_direction: unicode.Bidi.ParagraphDirection,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
    normalized_coords: []const f32,
) (parsing.Font.ParseError || unicode.Bidi.Error || error{OutOfMemory})!Buffer {
    return shapeBidiParagraphImpl(allocator, &.{font}, codepoints, base_direction, script_tags, language_tags, extra_features, normalized_coords, null, null);
}

/// Result of `shapeBidiParagraphWithFallback`: `buffer` in visual order,
/// plus `font_indices[g]` = index into the caller's `fonts` slice of the
/// font that shaped glyph `g` (parallel to `buffer.info`). Caller owns and
/// must free `font_indices`.
pub const BidiFallbackResult = struct {
    buffer: Buffer,
    font_indices: []usize,
};

/// Like `shapeBidiParagraph`, but itemizes each directional run further by
/// cmap coverage across `fonts` (priority order, see `itemizeByFontCoverage`)
/// so an LTR island inside RTL text - or any span the primary font lacks -
/// is shaped against its own font while still being reordered into correct
/// visual position. Bidi/level itemization is the outer split and font
/// fallback the inner one, so visual reordering crosses font boundaries -
/// which nesting per-run `shapeBidiParagraph` calls the other way (font
/// outer, bidi inner) cannot. A codepoint covered by no font attaches to
/// the previous codepoint's font (falls back to `fonts[0]`/.notdef at the
/// paragraph start).
/// `item`, when non-null, restricts the emitted glyphs to that codepoint
/// range the way `shapeWithContext` does: everything outside it still shapes
/// (and so still joins, ligates and resolves bidi against its real
/// neighbours), but its glyphs are dropped at the end. Cluster values stay
/// indices into the whole `codepoints` slice.
pub fn shapeBidiParagraphWithFallback(
    allocator: std.mem.Allocator,
    fonts: []const parsing.Font,
    codepoints: []const u21,
    base_direction: unicode.Bidi.ParagraphDirection,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
    item: ?Item,
) (parsing.Font.ParseError || unicode.Bidi.Error || error{OutOfMemory})!BidiFallbackResult {
    var font_indices: std.ArrayList(usize) = .empty;
    errdefer font_indices.deinit(allocator);
    try font_indices.ensureTotalCapacityPrecise(allocator, codepoints.len);
    const buffer = try shapeBidiParagraphImpl(allocator, fonts, codepoints, base_direction, script_tags, language_tags, extra_features, &.{}, &font_indices, item);
    return .{ .buffer = buffer, .font_indices = try font_indices.toOwnedSlice(allocator) };
}

/// Shared implementation. `fonts` is the priority-ordered fallback stack
/// (a single-font caller passes `&.{font}`); when `font_indices_out` is
/// non-null it receives one entry per output glyph naming the `fonts` index
/// that shaped it. With one font every codepoint resolves to index 0, so
/// the itemization gains no extra splits and behavior matches the
/// pre-fallback single-font path exactly.
fn shapeBidiParagraphImpl(
    allocator: std.mem.Allocator,
    fonts: []const parsing.Font,
    codepoints: []const u21,
    base_direction: unicode.Bidi.ParagraphDirection,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
    normalized_coords: []const f32,
    font_indices_out: ?*std.ArrayList(usize),
    item: ?Item,
) (parsing.Font.ParseError || unicode.Bidi.Error || error{OutOfMemory})!Buffer {
    var result = Buffer.init(allocator);
    errdefer result.deinit();
    if (codepoints.len == 0) return result;

    const classes = try allocator.alloc(unicode.BidiClass, codepoints.len);
    defer allocator.free(classes);
    for (codepoints, 0..) |cp, i| classes[i] = unicode.BidiClass.of(cp);

    const levels = try unicode.Bidi.paragraphEmbeddingLevels(allocator, classes, base_direction, codepoints);
    defer allocator.free(levels);

    const resolved_scripts = try allocator.alloc([4]u8, codepoints.len);
    defer allocator.free(resolved_scripts);
    unicode.resolveScripts(codepoints, resolved_scripts);

    const cmaps = try allocator.alloc(?parsing.Table.cmap.Resolved, fonts.len);
    defer allocator.free(cmaps);
    for (fonts, cmaps) |font, *out| out.* = if (font.tableData(.{ 'c', 'm', 'a', 'p' })) |d| parsing.Table.cmap.resolve(d) else null;

    // Per-codepoint fallback font (first font whose cmap covers it), an
    // uncovered codepoint inheriting the previous one's font like
    // `itemizeByFontCoverage`.
    const font_of = try allocator.alloc(usize, codepoints.len);
    defer allocator.free(font_of);
    {
        var prev: usize = 0;
        for (codepoints, 0..) |cp, i| {
            const fi = coverageFontIndex(cmaps, cp) orelse prev;
            font_of[i] = fi;
            prev = fi;
        }
    }

    // Itemize by resolved Unicode script (Common/Inherited/Unknown absorbed
    // into adjacent strong scripts) intersecting bidi level and fallback
    // font. Inherited and other weak-script marks stay with the preceding
    // strong character even if UAX #9 W1 gave them a different level or a
    // different font would cover them — that keeps GPOS mark-to-base intact.
    // Script-specific marks (e.g. Arabic NSM after Latin) are strong Arab,
    // so they start a new run instead of gluing onto the Latin base,
    // matching Blink/ICU script itemization rather than grapheme-cluster
    // snapping across a script boundary.
    const Run = struct { start: usize, end: usize, level: u8, script: [4]u8, font_index: usize };
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);
    {
        var i: usize = 0;
        while (i < levels.len) {
            var j = i + 1;
            while (j < levels.len) {
                if (!std.mem.eql(u8, &resolved_scripts[j], &resolved_scripts[i])) break;
                const strong = !unicode.scriptIsWeak(unicode.scriptOf(codepoints[j]));
                // Bidi level boundaries must hold even for weak-script runs
                // of ordinary punctuation (e.g. U+2018 inheriting an
                // adjacent Yezidi run's script) - only an actual combining
                // mark (NSM) is allowed to ride along with a base at a
                // different W1-shifted level, to keep GPOS mark-to-base
                // intact.
                if (levels[j] != levels[i] and (strong or classes[j] != .nsm)) break;
                // Same exception as the level check above: only an actual
                // combining mark rides along on a font it isn't covered by
                // (needed for GPOS mark-to-base) - other weak-script
                // codepoints (space, punctuation, emoji) must still break so
                // they don't inherit a neighboring run's unrelated font and
                // render .notdef.
                if (font_of[j] != font_of[i] and (strong or classes[j] != .nsm)) break;
                j += 1;
            }
            try runs.append(allocator, .{
                .start = i,
                .end = j,
                .level = levels[i],
                .script = resolved_scripts[i],
                .font_index = font_of[i],
            });
            i = j;
        }
    }

    var run_buffers = try allocator.alloc(Buffer, runs.items.len);
    defer allocator.free(run_buffers);
    var run_buffers_made: usize = 0;
    defer for (run_buffers[0..run_buffers_made]) |*b| b.deinit();

    const run_levels = try allocator.alloc(u8, runs.items.len);
    defer allocator.free(run_levels);

    for (runs.items, 0..) |run, i| {
        const run_direction: Direction = if (run.level % 2 == 1) .right_to_left else .left_to_right;
        var ot_tags_storage: [2]Tag = undefined;
        const run_script_tags: []const Tag = if (script_tags.len != 0) script_tags else unicode.openTypeScriptTags(run.script, &ot_tags_storage);
        run_buffers[i] = try shapeImpl(allocator, fonts[run.font_index], codepoints[run.start..run.end], run_direction, run_script_tags, language_tags, extra_features, normalized_coords, null);
        run_buffers_made += 1;
        for (run_buffers[i].info.items) |*info| info.cluster += @intCast(run.start);
        run_levels[i] = run.level;
    }

    const run_order = try unicode.Bidi.reorderVisual(allocator, run_levels);
    defer allocator.free(run_order);

    for (run_order) |run_index| {
        const rb = &run_buffers[run_index];
        try result.info.appendSlice(allocator, rb.info.items);
        try result.pos.appendSlice(allocator, rb.pos.items);
        if (font_indices_out) |out| try out.appendNTimes(allocator, runs.items[run_index].font_index, rb.info.items.len);
    }
    result.have_positions = true;

    // Last, after every run has shaped and been placed in visual order: the
    // context has to survive GSUB/GPOS and reordering to do its job.
    if (item) |it| {
        if (font_indices_out) |out| {
            var kept: usize = 0;
            for (result.info.items, 0..) |info, g| {
                if (info.cluster < it.start or info.cluster >= it.end) continue;
                out.items[kept] = out.items[g];
                kept += 1;
            }
            out.shrinkRetainingCapacity(kept);
        }
        retainItemGlyphs(&result, it);
    }

    return result;
}

/// A maximal run of `codepoints[start..end]` assigned to `fonts[font_index]`
/// by `itemizeByFontCoverage`.
pub const Span = struct {
    font_index: usize,
    start: usize,
    end: usize,
};

fn coverageFontIndex(cmaps: []const ?parsing.Table.cmap.Resolved, codepoint: u21) ?usize {
    for (cmaps, 0..) |cmap, i| {
        const resolved = cmap orelse continue;
        if (resolved.lookup(codepoint)) |glyph_id| {
            if (glyph_id != 0) return i;
        }
    }
    return null;
}

/// Itemizes `text` into maximal spans, each assigned the first font in
/// `fonts` (priority order) whose cmap covers every codepoint in the span.
/// A codepoint uncovered by any font attaches to the previous span's font
/// (falls back to .notdef there) rather than forcing its own span - simplest
/// rule that still keeps span count minimal.
pub fn itemizeByFontCoverage(allocator: std.mem.Allocator, fonts: []const parsing.Font, text: []const u21) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);
    if (text.len == 0) return spans.toOwnedSlice(allocator);

    const cmaps = try allocator.alloc(?parsing.Table.cmap.Resolved, fonts.len);
    defer allocator.free(cmaps);
    for (fonts, cmaps) |font, *out| out.* = if (font.tableData(.{ 'c', 'm', 'a', 'p' })) |d| parsing.Table.cmap.resolve(d) else null;

    var current_font = coverageFontIndex(cmaps, text[0]) orelse 0;
    var start: usize = 0;
    for (text[1..], 1..) |codepoint, i| {
        const font_index = coverageFontIndex(cmaps, codepoint) orelse current_font;
        if (font_index != current_font) {
            try spans.append(allocator, .{ .font_index = current_font, .start = start, .end = i });
            start = i;
            current_font = font_index;
        }
    }
    try spans.append(allocator, .{ .font_index = current_font, .start = start, .end = text.len });
    return spans.toOwnedSlice(allocator);
}

/// Itemizes `codepoints` across `fonts` by cmap coverage (see
/// `itemizeByFontCoverage`), shapes each span independently against its
/// chosen font, and concatenates the results in visual order. Cluster
/// indices are offset by each span's start so they stay monotonic across
/// the whole original run rather than resetting per span.
pub fn shapeWithFallback(
    allocator: std.mem.Allocator,
    fonts: []const parsing.Font,
    codepoints: []const u21,
    direction: Direction,
    script_tags: []const Tag,
    language_tags: []const Tag,
    extra_features: []const Tag,
) (parsing.Font.ParseError || error{OutOfMemory})!Buffer {
    const spans = try itemizeByFontCoverage(allocator, fonts, codepoints);
    defer allocator.free(spans);

    var result = Buffer.init(allocator);
    errdefer result.deinit();

    // hb reverses the whole buffer to visual order as its last positioning
    // step; each span already comes back in its own visual order from
    // shape(), so combining spans in visual order for RTL/BTT just means
    // walking the span list back to front.
    const backward = direction == .right_to_left or direction == .bottom_to_top;
    var span_index: usize = 0;
    while (span_index < spans.len) : (span_index += 1) {
        const span = spans[if (backward) spans.len - 1 - span_index else span_index];
        var span_buffer = try shape(
            allocator,
            fonts[span.font_index],
            codepoints[span.start..span.end],
            direction,
            script_tags,
            language_tags,
            extra_features,
        );
        defer span_buffer.deinit();

        for (span_buffer.info.items) |*info| info.cluster += @intCast(span.start);
        try result.info.appendSlice(allocator, span_buffer.info.items);
        try result.pos.appendSlice(allocator, span_buffer.pos.items);
    }

    return result;
}
