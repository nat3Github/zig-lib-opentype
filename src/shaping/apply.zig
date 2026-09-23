// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const parsing = @import("../parsing.zig");
const common = @import("common.zig");
const map_mod = @import("map.zig");
const Buffer = common.Buffer;
const Cmap = common.Cmap;
const GlyphInfo = common.GlyphInfo;
const GlyphPosition = common.GlyphPosition;
const Direction = common.Direction;
const Tag = common.Tag;
const attach_type_mark = common.attach_type_mark;
const attach_type_cursive = common.attach_type_cursive;
const Map = map_mod.Map;
const LookupMapEntry = map_mod.LookupMapEntry;
const table_tag_gsub = map_mod.table_tag_gsub;
const table_tag_gpos = map_mod.table_tag_gpos;

// Ported from vendor/harfbuzz/src/hb-ot-layout-gsubgpos.hh + the per-format
// files under vendor/harfbuzz/src/OT/Layout/{GSUB,GPOS}/ (pinned
// 703e2d1441): applies a compiled Map's lookups against a Buffer.
//
// Scope, per the deliberate narrowing agreed for this session (full
// gsubgpos.hh + common.hh is ~11k lines - mark attachment, chaining
// context, extension lookups, and every format variant - a multi-session
// port on its own):
//   - GSUB: SingleSubst (f1/f2), MultipleSubst (f1), AlternateSubst (f1),
//     LigatureSubst (f1).
//   - GPOS: SinglePos (f1/f2), PairPos (f1/f2).
//   - Extension (GSUB 7/GPOS 9) is unwrapped transparently: real fonts
//     commonly wrap any of the above lookup types in Extension to get
//     32-bit subtable offsets, so this isn't a separate lookup type from
//     the caller's perspective, just an indirection the dispatch below
//     resolves before applying.
//   - GPOS: CursivePos (f1), MarkBasePos/MarkLigPos/MarkMarkPos (f1) - see
//     these lookup types' doc comments for the lig_id/lig_comp tracking cut
//     they share (GSUB substitution here never sets those fields, so the
//     multiplied-glyph/same-ligature disambiguation they drive always takes
//     hb's own no-match fallback path).
//   - GSUB/GPOS Contextual (5/7) and Chaining Contextual (6/8), all three
//     formats: 1 (glyph-sequence RuleSets, `applyRuleBasedContext` with
//     `.glyph` match mode), 2 (class-based RuleSets, same function with
//     `.class_def` mode), and 3 (coverage-based, `applyContextCore` called
//     directly - format 3 needs no separate RuleSet/Rule indirection since
//     every position already carries its own Coverage). Formats 1/2 try
//     each Rule/ChainRule in a RuleSet in order, first full match wins
//     (mirrors hb's `RuleSet::apply`'s `hb_any`); the match+apply core
//     (`applyContextCore`) is shared across all three formats and both
//     tables. Nested-lookup recursion (`LookupRecord`s applying another
//     lookup at a matched position) is capped at 64 levels
//     (`max_nesting_level`, mirrors hb's `HB_MAX_NESTING_LEVEL`) to bound
//     cost on adversarial cyclic lookup references per this repo's
//     CLAUDE.md guidance. `applyContextCore`'s nested-`LookupRecord` loop
//     ports hb's `apply_lookup` position bookkeeping in full, including
//     `Buffer.moveTo`'s ability to rewind already-committed GSUB output
//     back into pending input so a later record can re-match glyphs an
//     earlier one in the same rule just inserted or deleted.
//   - GSUB ReverseChainSingleSubst (type 8): the one lookup type hb (and
//     this port) applies back-to-front and in place, with no `have_output`/
//     `out_info` split - see `applyLookup`'s `isReverseLookup` branch. Not
//     reachable via nested `LookupRecord` application ("no chaining to this
//     type" in hb), enforced here via the same `depth != max_nesting_level`
//     check hb makes with `nesting_level_left`.
//   - Device tables: only VariationIndex deltas apply (hb at ppem 0);
//     ppem-specific hinting deltas are skipped.
//   - Ligature component matching requires an exact contiguous glyph run
//     (no lookup-flag skipping of marks between components). Real fonts
//     don't put combining marks between Latin ligature components in
//     practice, and scripts where they do (Arabic/Indic) are already out of
//     phase-1 scope per this component's complex-shaper deferral. PairPos's
//     *second* glyph lookup does use lookup-flag skipping (via GDEF glyph
//     class, when present) since that's the common "kern past a mark" case.
const gsub_tag_single = 1;
const gsub_tag_multiple = 2;
const gsub_tag_alternate = 3;
const gsub_tag_ligature = 4;
const gsub_tag_context = 5;
const gsub_tag_chain_context = 6;
const gsub_tag_extension = 7;
const gsub_tag_reverse_chain_single = 8;
const gpos_tag_single = 1;
const gpos_tag_pair = 2;
const gpos_tag_cursive = 3;
const gpos_tag_mark_to_base = 4;
const gpos_tag_mark_to_ligature = 5;
const gpos_tag_mark_to_mark = 6;
const gpos_tag_context = 7;
const gpos_tag_chain_context = 8;
const gpos_tag_extension = 9;

/// hb's `HB_MAX_CONTEXT_LENGTH`, the cap its `match_input` puts on a
/// LigatureSubst's componentCount.
const max_ligature_components = 64;

/// HB_OT_MAP_MAX_VALUE: the value the 'rand' feature is registered with,
/// and AlternateSubst's signal to pick an alternate at random.
pub const map_max_feature_value: u32 = 255;

/// Nested-lookup recursion cap for Contextual/Chaining Context lookups
/// (`applyLookupOnce`), mirroring hb's `HB_MAX_NESTING_LEVEL`.
const max_nesting_level: u8 = 64;
/// Max backtrack/input/lookahead length for a single Context/ChainContext
/// match, mirroring hb's `HB_MAX_CONTEXT_LENGTH`. Also the fixed size of
/// `applyContextCore`'s `positions` stack array.
const max_context_length: usize = 64;

/// ExtensionFormat1 (OT spec 6.2.6.2): format u16(=1), extensionLookupType
/// u16, extensionOffset Offset32 to the wrapped subtable. Used by fonts to
/// get 32-bit subtable offsets; unwraps to the real (lookup_type, offset)
/// pair the dispatch switches above already know how to apply. Nesting
/// (an Extension pointing at another Extension) is invalid per spec and
/// rejected rather than recursed into.
fn unwrapExtension(reader: parsing.Table.Layout.SubtableReader, extension_tag: u16) parsing.Font.ParseError!?struct { lookup_type: u16, sub_off: usize } {
    const format = try reader.u16At(0);
    if (format != 1) return null;
    const lookup_type = try reader.u16At(2);
    if (lookup_type == extension_tag) return null;
    const rel_off = try reader.u32At(4);
    return .{ .lookup_type = lookup_type, .sub_off = reader.offset + rel_off };
}

/// The GDEF pieces the lookup-flag skip predicate needs, resolved once per
/// shaping run rather than re-walked per glyph.
pub const Gdef = struct {
    classes: ?parsing.Table.Layout.ClassDef = null,
    /// `classes` decoded to a glyph-indexed array at plan time; `classes` is
    /// the fallback for callers that have no plan.
    dense_classes: ?[]const u8 = null,
    mark_attach: ?parsing.Table.Layout.ClassDef = null,
    mark_sets: ?parsing.Table.Gdef.MarkGlyphSets = null,
    /// Set only at non-default variation coords, as hb gates device deltas
    /// on `has_nonzero_coords`.
    variations: ?Variations = null,

    pub const Variations = struct {
        data: []const u8,
        store_offset: u32,
        normalized_coords: []const f32,
    };
};

/// hb's `roundf`, which it redefines as `floor(x + 0.5)`: halves round up,
/// not away from zero.
pub fn hbRound(x: f32) f32 {
    return @floor(x + 0.5);
}

/// hb's `Device::get_{x,y}_delta` at ppem 0: only a VariationIndex table
/// contributes. `device_offset` is relative to `base`.
fn deviceDelta(gdef: Gdef, base: parsing.Table.Layout.SubtableReader, device_offset: u16) i32 {
    if (device_offset == 0) return 0;
    const variations = gdef.variations orelse return 0;
    const device = parsing.Table.Layout.SubtableReader{ .data = base.data, .offset = base.offset + device_offset };
    if ((device.u16At(4) catch return 0) != 0x8000) return 0;
    const outer = device.u16At(0) catch return 0;
    const inner = device.u16At(2) catch return 0;
    return @intFromFloat(hbRound(parsing.Table.HVAR.itemDelta(variations.data, variations.store_offset, outer, inner, variations.normalized_coords)));
}

fn glyphClass(gdef: Gdef, glyph: u32) u16 {
    if (glyph > std.math.maxInt(u16)) return 0;
    if (gdef.dense_classes) |dense| return if (glyph < dense.len) dense[glyph] else 0;
    const cd = gdef.classes orelse return 0;
    return cd.getClass(@intCast(glyph)) catch 0;
}

/// hb's `glyph_props`, filled on first touch instead of by a buffer sweep
/// after every lookup. Cached against `gdef_class_glyph`, so a substitution
/// that changes the glyph id just recomputes.
fn cacheGlyphClasses(gdef: Gdef, info: *GlyphInfo) void {
    // Both are cached as u8 to keep GlyphInfo at 48 bytes; only classes
    // 1-4 (and the 1-255 markAttachmentType filter) are meaningful, so a
    // malformed out-of-range class folds to 0, which behaves identically.
    info.gdef_class = narrowClass(glyphClass(gdef, info.codepoint));
    info.gdef_mark_attach_class = if (info.codepoint > std.math.maxInt(u16)) 0 else narrowClass(markAttachClass(gdef, @intCast(info.codepoint)));
    info.gdef_class_glyph = info.codepoint;
}

fn infoGlyphClass(gdef: Gdef, info: *GlyphInfo) u16 {
    if (info.gdef_class_glyph != info.codepoint) cacheGlyphClasses(gdef, info);
    return info.gdef_class;
}

fn narrowClass(class: u16) u8 {
    return if (class > std.math.maxInt(u8)) 0 else @intCast(class);
}

fn markAttachClass(gdef: Gdef, glyph: u16) u16 {
    const cd = gdef.mark_attach orelse return 0;
    return cd.getClass(glyph) catch 0;
}

/// Drops every cached class: the cache key is a glyph id, so entries left
/// by another font would otherwise read as valid.
pub fn resetGlyphClasses(infos: []GlyphInfo) void {
    for (infos) |*info| info.gdef_class_glyph = std.math.maxInt(u32);
}

/// hb's `lookup_props`: the raw lookupFlag with the markFilteringSet index
/// packed above bit 16, so the skip predicate needs only one parameter.
fn lookupProps(lk: parsing.Table.Layout.Lookup) parsing.Font.ParseError!u32 {
    const flags = try lk.lookupFlags();
    const set = (try lk.markFilteringSet()) orelse return flags;
    return @as(u32, flags) | (@as(u32, set) << 16);
}

fn shouldSkipClass(class: u16, lookup_flags: u32) bool {
    return switch (class) {
        1 => lookup_flags & 0x0002 != 0, // Base: ignoreBaseGlyphs
        2 => lookup_flags & 0x0004 != 0, // Ligature: ignoreLigatures
        3 => lookup_flags & 0x0008 != 0, // Mark: ignoreMarks
        else => false, // 0 (unassigned) / 4 (Component): never filtered by these flags
    };
}

/// Which joiners a skip iterator may step over - hb's
/// `matcher_t::ignore_zwnj`/`ignore_zwj`.
/// `syllable`, when nonzero, confines matches to that syllable - hb's
/// per-syllable GSUB matching.
const Skip = struct { zwnj: bool, zwj: bool, hidden: bool, syllable: u8 = 0 };

/// hb's per-lookup `auto_zwnj`/`auto_zwj`: a complex shaper that handles
/// joiners itself (Indic, Khmer, Myanmar, USE) clears them so its own
/// features stop stepping over a joiner the text put there to block them.
const Joiners = struct {
    auto_zwnj: bool = true,
    auto_zwj: bool = true,
    per_syllable: bool = false,
    /// The current glyph's syllable when `per_syllable`, else 0.
    syllable: u8 = 0,

    /// hb's `skippy_iter::init(context_match = false)`. Matching a
    /// ligature's own components never steps over a ZWNJ in GSUB - that is
    /// what makes "f, ZWNJ, i" come out unligated.
    fn direct(self: Joiners, table_index: u1) Skip {
        return .{ .zwnj = table_index == 1, .zwj = self.auto_zwj, .hidden = table_index == 1, .syllable = if (table_index == 0) self.syllable else 0 };
    }

    /// hb's `skippy_iter::init(context_match = true)`. Backtrack/lookahead
    /// matching always steps over a ZWJ, and over a ZWNJ unless the shaper
    /// asked to see it; a context's input glyphs match with `direct`.
    fn contextual(self: Joiners, table_index: u1) Skip {
        return .{ .zwnj = table_index == 1 or self.auto_zwnj, .zwj = true, .hidden = table_index == 1, .syllable = if (table_index == 0) self.syllable else 0 };
    }
};

fn shouldSkipGlyph(info: *GlyphInfo, gdef: Gdef, lookup_flags: u32, skip: Skip) bool {
    return !matchesLookupProps(info, gdef, lookup_flags) or maybeSkippable(info.*, skip);
}

/// hb's `check_glyph_property`: the lookup-flag half of the skip predicate,
/// without the joiner handling. `applyLookup` gates each glyph it steps
/// over on this rather than on `shouldSkipGlyph`, because a lookup does
/// apply at a ZWJ/ZWNJ even though matching steps over one.
fn matchesLookupProps(info: *GlyphInfo, gdef: Gdef, lookup_flags: u32) bool {
    return !filteredByLookupProps(info, gdef, lookup_flags);
}

fn filteredByLookupProps(info: *GlyphInfo, gdef: Gdef, lookup_flags: u32) bool {
    const class = infoGlyphClass(gdef, info);
    if (shouldSkipClass(class, lookup_flags)) return true;
    if (class != 3 or info.codepoint > std.math.maxInt(u16)) return false;
    const glyph: u16 = @intCast(info.codepoint);
    // Mark-only filters, hb's `match_properties_mark`: useMarkFilteringSet
    // wins over markAttachmentType when both bits are set.
    if (lookup_flags & 0x0010 != 0) {
        const sets = gdef.mark_sets orelse return false;
        return !(sets.covers(@truncate(lookup_flags >> 16), glyph) catch false);
    }
    if (lookup_flags & 0xFF00 != 0) {
        if (gdef.mark_attach == null) return true;
        return (lookup_flags & 0xFF00) != (@as(u32, info.gdef_mark_attach_class) << 8);
    }
    return false;
}

/// Searches forward from `start` (inclusive) in `infos` for the first glyph
/// not filtered by `lookup_flags`. Generic over the backing slice so
/// Context/ChainContext matching (src/shaping.zig's `applyContextCore`) can
/// reuse it against either `buffer.info` (GSUB "input"/"lookahead", GPOS
/// everything) without duplicating the skip logic.
fn nextUnskippedIn(infos: []GlyphInfo, gdef: Gdef, lookup_flags: u32, skip: Skip, start: usize) ?usize {
    var i = start;
    while (i < infos.len) : (i += 1) {
        if (!shouldSkipGlyph(&infos[i], gdef, lookup_flags, skip)) return i;
    }
    return null;
}

/// Searches backward from `start - 1` down to 0 in `infos` for the first
/// glyph not filtered by `lookup_flags`. See `nextUnskippedIn`.
fn prevUnskippedIn(infos: []GlyphInfo, gdef: Gdef, lookup_flags: u32, skip: Skip, start: usize) ?usize {
    var i = start;
    while (i > 0) {
        i -= 1;
        if (!shouldSkipGlyph(&infos[i], gdef, lookup_flags, skip)) return i;
    }
    return null;
}

fn nextUnskipped(buffer: *const Buffer, gdef: Gdef, lookup_flags: u32, skip: Skip, start: usize) ?usize {
    return nextUnskippedIn(buffer.info.items, gdef, lookup_flags, skip, start);
}

/// hb's `may_skip` returning SKIP_MAYBE: a default ignorable is stepped over
/// only when it isn't the glyph being looked for. A glyph a ligature already
/// swallowed is no longer ignorable.
fn maybeSkippable(info: GlyphInfo, skip: Skip) bool {
    if (info.is_zwnj and !skip.zwnj) return false;
    if (info.is_zwj and !skip.zwj) return false;
    if (info.is_hidden and !skip.hidden) return false;
    return common.isIgnorable(info);
}

/// hb's `skippy_iter` with a match function, which the plain
/// `nextUnskippedIn`/`prevUnskippedIn` above (hb's matcher-less iterator)
/// can't express: a default ignorable is only SKIP_MAYBE, so it is stepped
/// over when it isn't the glyph being looked for and *matched* when it is.
/// Emoji ZWJ sequences depend on that - their ligatures list the joiner as a
/// real component. Any other glyph that doesn't match ends the search.
/// `matcher` is duck-typed: anything with `matches(GlyphInfo) !bool`.
fn matchForward(infos: []GlyphInfo, gdef: Gdef, lookup_flags: u32, skip: Skip, start: usize, matcher: anytype) !?usize {
    var i = start;
    while (i < infos.len) : (i += 1) {
        const info = infos[i];
        if (!matchesLookupProps(&infos[i], gdef, lookup_flags)) continue;
        if ((skip.syllable == 0 or info.indic_syllable == skip.syllable) and try matcher.matches(info)) return i;
        if (!maybeSkippable(info, skip)) return null;
    }
    return null;
}

const ComponentMatcher = struct {
    glyph: u16,
    lookup_mask: u32,

    fn matches(self: ComponentMatcher, info: GlyphInfo) error{}!bool {
        if (info.mask & self.lookup_mask == 0) return false;
        return info.codepoint == self.glyph;
    }
};

/// Wraps `matchAt` for `matchForward`/`matchBackward`.
const SlotMatcher = struct {
    reader: parsing.Table.Layout.SubtableReader,
    mode: MatchMode,
    off: usize,

    fn matches(self: SlotMatcher, info: GlyphInfo) parsing.Font.ParseError!bool {
        if (info.codepoint > std.math.maxInt(u16)) return false;
        return matchAt(self.reader, self.mode, self.off, @intCast(info.codepoint));
    }
};

/// `matchForward` walking backwards from `start - 1`.
fn matchBackward(infos: []GlyphInfo, gdef: Gdef, lookup_flags: u32, skip: Skip, start: usize, matcher: anytype) !?usize {
    var i = start;
    while (i > 0) {
        i -= 1;
        const info = infos[i];
        if (!matchesLookupProps(&infos[i], gdef, lookup_flags)) continue;
        if ((skip.syllable == 0 or info.indic_syllable == skip.syllable) and try matcher.matches(info)) return i;
        if (!maybeSkippable(info, skip)) return null;
    }
    return null;
}

/// Searches backward from `start - 1` down to 0 for the first glyph not
/// filtered by `lookup_flags`. Used by CursivePos (own lookup flags) and
/// MarkToBase/MarkToLigature (fixed ignoreMarks-only flags, matching hb's
/// `skippy_iter.set_lookup_props(LookupFlag::IgnoreMarks)` override), and by
/// GPOS Context/ChainContext backtrack matching (which, unlike GSUB, has no
/// out_info side - GPOS never replaces glyphs, so `buffer.info` before `idx`
/// is still the real left context).
fn prevUnskipped(buffer: *const Buffer, gdef: Gdef, lookup_flags: u32, skip: Skip, start: usize) ?usize {
    return prevUnskippedIn(buffer.info.items, gdef, lookup_flags, skip, start);
}

const lookup_flag_ignore_marks: u32 = 0x0008;

/// GPOS never tests a candidate glyph against the feature mask while
/// matching (only GSUB's ligature components and AlternateSubst read one),
/// and a GPOS Context rule can only recurse into GPOS, so there is nothing
/// for its nested lookups to carry.
const gpos_lookup_mask: u32 = 0;

fn isMarkGlyph(gdef: Gdef, info: *GlyphInfo) bool {
    return infoGlyphClass(gdef, info) == 3;
}

/// Reads an Offset16To<Anchor> field at `rel` (relative to `reader`'s own
/// base) and, if non-null, the anchor's xCoordinate/yCoordinate (offset
/// +2/+4 in every format) plus AnchorFormat3's variation deltas.
/// AnchorFormat2's hinted contour point is not used, matching hb at ppem 0.
const AnchorPoint = struct { x: i32, y: i32 };

fn readAnchor(gdef: Gdef, reader: parsing.Table.Layout.SubtableReader, rel: usize) parsing.Font.ParseError!?AnchorPoint {
    const off = try reader.u16At(rel);
    if (off == 0) return null;
    const anchor = parsing.Table.Layout.SubtableReader{ .data = reader.data, .offset = reader.offset + off };
    var point = AnchorPoint{ .x = try anchor.i16At(2), .y = try anchor.i16At(4) };
    if (gdef.variations != null and try anchor.u16At(0) == 3) {
        point.x += deviceDelta(gdef, anchor, try anchor.u16At(6));
        point.y += deviceDelta(gdef, anchor, try anchor.u16At(8));
    }
    return point;
}

/// AnchorMatrix (OT spec): rows u16, then row-major Offset16To<Anchor> cells
/// (row*cols+col), relative to the AnchorMatrix's own base. Shared layout
/// behind BaseArray, LigatureAttach (component-major) and Mark2Array.
fn readAnchorMatrixCell(gdef: Gdef, matrix: parsing.Table.Layout.SubtableReader, row: u16, col: u16, cols: u16) parsing.Font.ParseError!?AnchorPoint {
    if (col >= cols) return null;
    const rows = try matrix.u16At(0);
    if (row >= rows) return null;
    return readAnchor(gdef, matrix, 2 + (@as(usize, row) * cols + col) * 2);
}

/// Walks a chain of prior cursive attachments starting at `glyph_pos`,
/// summing the minor-direction offset each ancestor contributed - mirrors
/// hb's `resolve_cross_offset` (MarkArray.hh). A mark attaching to a glyph
/// that's itself cursively attached to something else needs this so its
/// perpendicular placement accounts for the whole chain, not just its
/// immediate parent.
fn resolveCrossOffset(buffer: *Buffer, glyph_pos: usize, horizontal: bool) i32 {
    var idx = glyph_pos;
    var offset: i32 = if (horizontal) buffer.posAt(idx).y_offset else buffer.posAt(idx).x_offset;
    var guard: usize = 0;
    while (buffer.posAt(idx).attach_type & attach_type_cursive != 0 and guard < buffer.len()) : (guard += 1) {
        const chain = buffer.posAt(idx).attach_chain;
        if (chain == 0) break;
        const parent: i64 = @as(i64, @intCast(idx)) + chain;
        if (parent < 0 or parent >= buffer.len()) break;
        idx = @intCast(parent);
        offset += if (horizontal) buffer.posAt(idx).y_offset else buffer.posAt(idx).x_offset;
    }
    return offset;
}

/// Ports MarkArray::apply (MarkArray.hh): resolves the mark's class-indexed
/// anchor against the matched base/ligature-component/mark2 glyph's anchor
/// at `row_index` in `anchor_matrix`, then records the perpendicular offset
/// plus a mark-attachment link (`attach_chain`/`attach_type`) back to
/// `glyph_pos` so a later cursive/mark chain walk (`resolveCrossOffset`) can
/// find it. Shared by MarkBasePos/MarkLigPos/MarkMarkPos, which differ only
/// in how they pick `row_index` and `glyph_pos`.
fn applyMarkAttach(
    gdef: Gdef,
    mark_array: parsing.Table.Layout.SubtableReader,
    mark_index: u16,
    anchor_matrix: parsing.Table.Layout.SubtableReader,
    class_count: u16,
    row_index: u16,
    glyph_pos: usize,
    buffer: *Buffer,
    direction: Direction,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    const mark_count = try mark_array.u16At(0);
    if (mark_index >= mark_count) return false;
    const rec_off = 2 + @as(usize, mark_index) * 4;
    const mark_class = try mark_array.u16At(rec_off);
    if (mark_class >= class_count) return false;
    const mark_anchor = try readAnchor(gdef, mark_array, rec_off + 2) orelse return false;
    const glyph_anchor = try readAnchorMatrixCell(gdef, anchor_matrix, row_index, mark_class, class_count) orelse return false;

    const horizontal = direction == .left_to_right or direction == .right_to_left;
    const base_offset = resolveCrossOffset(buffer, glyph_pos, horizontal);

    const chain_wide: i64 = @as(i64, @intCast(glyph_pos)) - @as(i64, @intCast(buffer.idx));
    const chain: i16 = @truncate(chain_wide);
    buffer.curPos(0).attach_chain = if (@as(i64, chain) == chain_wide) chain else 0;
    if (@as(i64, chain) == chain_wide) {
        const mark_pos = buffer.curPos(0);
        mark_pos.attach_type = attach_type_mark;
        mark_pos.x_offset = glyph_anchor.x - mark_anchor.x;
        mark_pos.y_offset = glyph_anchor.y - mark_anchor.y;
        if (horizontal) mark_pos.y_offset += base_offset else mark_pos.x_offset += base_offset;
    }

    buffer.idx += 1;
    return true;
}

/// Ports MarkBasePos (MarkBasePosFormat1.hh): attaches the current mark
/// glyph to the nearest preceding non-mark glyph (base). hb's `accept()`
/// gate (rejecting attachment to non-first glyphs of a MultipleSubst
/// sequence) is skipped: it only matters for glyphs GSUB's Multiple/
/// LigatureSubst marked "multiplied", which this port's GSUB apply engine
/// never sets (see gsub_tag_ligature's doc comment), so the gate would
/// always pass anyway.
fn applyGposMarkToBase(
    reader: parsing.Table.Layout.SubtableReader,
    gid: u16,
    gdef: Gdef,
    buffer: *Buffer,
    direction: Direction,
    skip: Skip,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    const mark_cov = try reader.coverageAt(2);
    const mark_index = try mark_cov.get(gid) orelse return false;

    const base_cov = try reader.coverageAt(4);
    var base_pos = buffer.idx;
    const base_index = while (true) {
        base_pos = prevUnskipped(buffer, gdef, lookup_flag_ignore_marks, skip, base_pos) orelse return false;
        const base_glyph = buffer.info.items[base_pos].codepoint;
        if (base_glyph > std.math.maxInt(u16)) return false;
        const covered = try base_cov.get(@intCast(base_glyph));
        if (covered != null or acceptsMarkBase(buffer.info.items, gdef, base_pos)) break covered orelse return false;
    };

    const class_count = try reader.u16At(6);
    const mark_array = try reader.subReaderAt(8);
    const base_array = try reader.subReaderAt(10);

    return applyMarkAttach(gdef, mark_array, mark_index, base_array, class_count, base_index, base_pos, buffer, direction);
}

/// MarkBasePos's `accept`: of a MultipleSubst sequence only the first glyph
/// takes marks, unless a mark sits inside the sequence.
fn acceptsMarkBase(infos: []GlyphInfo, gdef: Gdef, idx: usize) bool {
    const info = infos[idx];
    if (!info.is_multiplied or info.lig_comp == 0 or idx == 0) return true;
    const prev = infos[idx - 1];
    return isMarkGlyph(gdef, &infos[idx - 1]) or !prev.is_multiplied or
        info.lig_id != prev.lig_id or info.lig_comp != prev.lig_comp + 1;
}

/// Ports MarkLigPos (MarkLigPosFormat1.hh): attaches the current mark to a
/// component of the nearest preceding ligature glyph, picked from the
/// `lig_id`/`lig_comp` that GSUB's LigatureSubst stamped on both. A mark
/// with no matching ligature id falls back to the last component, which is
/// right for the common "one mark after a ligature" case.
fn applyGposMarkToLigature(
    reader: parsing.Table.Layout.SubtableReader,
    gid: u16,
    gdef: Gdef,
    buffer: *Buffer,
    direction: Direction,
    skip: Skip,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    const mark_cov = try reader.coverageAt(2);
    const mark_index = try mark_cov.get(gid) orelse return false;

    const lig_pos = prevUnskipped(buffer, gdef, lookup_flag_ignore_marks, skip, buffer.idx) orelse return false;
    const lig_glyph = buffer.info.items[lig_pos].codepoint;
    if (lig_glyph > std.math.maxInt(u16)) return false;
    const lig_cov = try reader.coverageAt(4);
    const lig_cov_index = try lig_cov.get(@intCast(lig_glyph)) orelse return false;

    const class_count = try reader.u16At(6);
    const mark_array = try reader.subReaderAt(8);
    const ligature_array = try reader.subReaderAt(10);

    const lig_count = try ligature_array.u16At(0);
    if (lig_cov_index >= lig_count) return false;
    const lig_attach = try ligature_array.subReaderAt(2 + @as(usize, lig_cov_index) * 2);

    const comp_count = try lig_attach.u16At(0);
    if (comp_count == 0) return false;
    const mark_info = buffer.info.items[buffer.idx];
    const lig_info = buffer.info.items[lig_pos];
    const comp_index = if (lig_info.lig_id != 0 and lig_info.lig_id == mark_info.lig_id and mark_info.lig_comp > 0)
        @min(comp_count, mark_info.lig_comp) - 1
    else
        comp_count - 1;

    return applyMarkAttach(gdef, mark_array, mark_index, lig_attach, class_count, comp_index, lig_pos, buffer, direction);
}

/// Ports MarkMarkPos (MarkMarkPosFormat1.hh): attaches the current mark to
/// the immediately preceding glyph, if that glyph is itself a mark (GDEF
/// class 3). hb's `set_lookup_props(lookup_props & ~IgnoreFlags)` search
/// clears all class-based skipping, so this is a plain idx-1 lookback, no
/// `prevUnskipped` needed. Two marks only stack if they sit on the same
/// base or on the same component of the same ligature.
/// hb's MarkMarkPosFormat1 "good" test: same base (neither is part of a
/// ligature), same component of the same ligature, or one of the two marks
/// is itself a ligature.
fn sameLigatureComponent(a: GlyphInfo, b: GlyphInfo) bool {
    if (a.lig_id == b.lig_id) return a.lig_id == 0 or a.lig_comp == b.lig_comp;
    return (a.lig_id > 0 and a.lig_comp == 0) or (b.lig_id > 0 and b.lig_comp == 0);
}

fn applyGposMarkToMark(
    reader: parsing.Table.Layout.SubtableReader,
    gid: u16,
    gdef: Gdef,
    lookup_flags: u32,
    buffer: *Buffer,
    direction: Direction,
    skip: Skip,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    const mark1_cov = try reader.coverageAt(2);
    const mark1_index = try mark1_cov.get(gid) orelse return false;
    // hb keeps the lookup's mark filtering but drops its IgnoreBase/
    // Ligatures/Marks bits, so the search stops at the first non-mark.
    const j = prevUnskipped(buffer, gdef, lookup_flags & ~@as(u32, 0x000E), skip, buffer.idx) orelse return false;
    if (!isMarkGlyph(gdef, &buffer.info.items[j])) return false;
    if (!sameLigatureComponent(buffer.info.items[buffer.idx], buffer.info.items[j])) return false;

    const mark2_glyph = buffer.info.items[j].codepoint;
    if (mark2_glyph > std.math.maxInt(u16)) return false;
    const mark2_cov = try reader.coverageAt(4);
    const mark2_index = try mark2_cov.get(@intCast(mark2_glyph)) orelse return false;

    const class_count = try reader.u16At(6);
    const mark1_array = try reader.subReaderAt(8);
    const mark2_array = try reader.subReaderAt(10);

    return applyMarkAttach(gdef, mark1_array, mark1_index, mark2_array, class_count, mark2_index, j, buffer, direction);
}

/// Iteratively ports `reverse_cursive_minor_offset` (CursivePosFormat1.hh):
/// when a glyph about to become a cursive child was already cursively
/// attached elsewhere, that old chain must be walked and reversed so the
/// whole subtree re-roots under the new parent. Ported iteratively (collect
/// the chain forward, apply effects in reverse) rather than hb's recursion
/// to avoid recursion depth scaling with buffer length on adversarial
/// input, per this repo's guard-cyclic-lookup-structures guidance.
fn reverseCursiveMinorOffset(buffer: *Buffer, start: usize, direction: Direction, new_parent: usize) error{OutOfMemory}!void {
    const horizontal = direction == .left_to_right or direction == .right_to_left;
    const len = buffer.len();

    const Link = struct { i: usize, j: usize, chain: i16, atype: u8 };
    var path: std.ArrayList(Link) = .empty;
    defer path.deinit(buffer.allocator);

    var i = start;
    while (true) {
        const chain = buffer.posAt(i).attach_chain;
        const atype = buffer.posAt(i).attach_type;
        if (chain == 0 or atype & attach_type_cursive == 0) break;
        buffer.posAt(i).attach_chain = 0;
        const j_wide: i64 = @as(i64, @intCast(i)) + chain;
        if (j_wide < 0 or j_wide >= len) break;
        const j: usize = @intCast(j_wide);
        if (j == new_parent) break;
        if (chain == std.math.minInt(i16)) break;
        try path.append(buffer.allocator, .{ .i = i, .j = j, .chain = -chain, .atype = atype });
        i = j;
    }

    var k = path.items.len;
    while (k > 0) {
        k -= 1;
        const link = path.items[k];
        if (horizontal) buffer.posAt(link.j).y_offset = -buffer.posAt(link.i).y_offset else buffer.posAt(link.j).x_offset = -buffer.posAt(link.i).x_offset;
        buffer.posAt(link.j).attach_chain = link.chain;
        buffer.posAt(link.j).attach_type = link.atype;
    }
}

/// Ports CursivePosFormat1 (CursivePosFormat1.hh): links the current
/// glyph's entry anchor to the nearest preceding (per lookup-flag skipping)
/// glyph's exit anchor, building a chain of `attach_chain`/`attach_type`
/// links resolved later by GPOS positioning consumers and by
/// `resolveCrossOffset` for marks attaching to a cursively-chained glyph.
fn applyGposCursive(
    reader: parsing.Table.Layout.SubtableReader,
    gid: u16,
    gdef: Gdef,
    lookup_flags: u32,
    buffer: *Buffer,
    direction: Direction,
    skip: Skip,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    const cov = try reader.coverageAt(2);
    const this_index = try cov.get(gid) orelse return false;
    const record_count = try reader.u16At(4);
    if (this_index >= record_count) return false;
    const entry_anchor = try readAnchor(gdef, reader, 6 + @as(usize, this_index) * 4) orelse return false;

    const i = prevUnskipped(buffer, gdef, lookup_flags, skip, buffer.idx) orelse return false;
    const prev_glyph = buffer.info.items[i].codepoint;
    if (prev_glyph > std.math.maxInt(u16)) return false;
    const prev_index = try cov.get(@intCast(prev_glyph)) orelse return false;
    if (prev_index >= record_count) return false;
    const exit_anchor = try readAnchor(gdef, reader, 6 + @as(usize, prev_index) * 4 + 2) orelse return false;

    const j = buffer.idx;
    switch (direction) {
        .left_to_right => {
            buffer.posAt(i).x_advance = exit_anchor.x + buffer.posAt(i).x_offset;
            const d = entry_anchor.x + buffer.posAt(j).x_offset;
            buffer.posAt(j).x_advance -= d;
            buffer.posAt(j).x_offset -= d;
        },
        .right_to_left => {
            const d = exit_anchor.x + buffer.posAt(i).x_offset;
            buffer.posAt(i).x_advance -= d;
            buffer.posAt(i).x_offset -= d;
            buffer.posAt(j).x_advance = entry_anchor.x + buffer.posAt(j).x_offset;
        },
        .top_to_bottom => {
            buffer.posAt(i).y_advance = exit_anchor.y + buffer.posAt(i).y_offset;
            const d = entry_anchor.y + buffer.posAt(j).y_offset;
            buffer.posAt(j).y_advance -= d;
            buffer.posAt(j).y_offset -= d;
        },
        .bottom_to_top => {
            const d = exit_anchor.y + buffer.posAt(i).y_offset;
            buffer.posAt(i).y_advance -= d;
            buffer.posAt(i).y_offset -= d;
            buffer.posAt(j).y_advance = entry_anchor.y;
        },
    }

    var child = i;
    var parent = j;
    var x_offset = entry_anchor.x - exit_anchor.x;
    var y_offset = entry_anchor.y - exit_anchor.y;
    if (lookup_flags & 0x0001 == 0) {
        const tmp = child;
        child = parent;
        parent = tmp;
        x_offset = -x_offset;
        y_offset = -y_offset;
    }

    try reverseCursiveMinorOffset(buffer, child, direction, parent);

    const horizontal = direction == .left_to_right or direction == .right_to_left;
    const chain_wide: i64 = @as(i64, @intCast(parent)) - @as(i64, @intCast(child));
    const chain: i16 = @truncate(chain_wide);
    buffer.posAt(child).attach_chain = if (@as(i64, chain) == chain_wide) chain else 0;
    if (@as(i64, chain) == chain_wide) {
        buffer.posAt(child).attach_type = attach_type_cursive;
        if (horizontal) buffer.posAt(child).y_offset = y_offset else buffer.posAt(child).x_offset = x_offset;

        if (buffer.posAt(parent).attach_chain == -buffer.posAt(child).attach_chain) {
            buffer.posAt(parent).attach_chain = 0;
            if (horizontal) buffer.posAt(parent).y_offset = 0 else buffer.posAt(parent).x_offset = 0;
        }
    }

    buffer.idx += 1;
    return true;
}

/// hb's `LigatureSet::collect_seconds` over every set of the subtable.
/// Walking stops after `budget` ligatures (offsets may repeat, so the font's
/// counts alone don't bound it) and yields a full digest, which rejects
/// nothing.
fn ligatureSeconds(reader: parsing.Table.Layout.SubtableReader, budget: usize) common.Digest {
    return collectLigatureSeconds(reader, budget) catch .full();
}

fn collectLigatureSeconds(reader: parsing.Table.Layout.SubtableReader, budget: usize) (parsing.Font.ParseError || error{Unfilterable})!common.Digest {
    var seconds: common.Digest = .{};
    var remaining = budget;
    const set_count = try reader.u16At(4);
    for (0..set_count) |set_index| {
        const ligset = try reader.subReaderAt(6 + set_index * 2);
        const lig_count = try ligset.u16At(0);
        for (0..lig_count) |lig_index| {
            if (remaining == 0) return error.Unfilterable;
            remaining -= 1;
            const lig = try ligset.subReaderAt(2 + lig_index * 2);
            if (try lig.u16At(2) <= 1) return .full();
            seconds.add(try lig.u16At(4));
        }
    }
    return seconds;
}

/// hb's `LigatureSet::apply` fast path: the glyph every ligature's second
/// component would be matched against, or null when that glyph is absent or
/// skippable and each ligature has to be matched in full.
fn ligatureSecondGlyph(buffer: *const Buffer, gdef: Gdef, lookup_flags: u32, skip: Skip) ?u32 {
    var i = buffer.idx + 1;
    while (i < buffer.info.items.len) : (i += 1) {
        const info = &buffer.info.items[i];
        if (!matchesLookupProps(info, gdef, lookup_flags)) continue;
        if (skip.syllable != 0 and info.indic_syllable != skip.syllable) return null;
        if (maybeSkippable(info.*, skip)) return null;
        return info.codepoint;
    }
    return null;
}

/// hb's `Coverage::get_coverage (glyph, cache)`: `max_value` caches "not
/// covered", and indices that don't fit the slot are never cached.
fn cachedCoverage(cov: parsing.Table.Layout.Coverage.Resolved, glyph: u16, cache: ?*common.MappingCache) parsing.Font.ParseError!?u16 {
    const c = cache orelse return cov.get(glyph);
    if (c.get(glyph)) |value| return if (value == common.MappingCache.max_value) null else value;
    const index = try cov.get(glyph);
    if (index) |i| {
        if (i < common.MappingCache.max_value) c.set(glyph, @intCast(i));
    } else c.set(glyph, common.MappingCache.max_value);
    return index;
}

fn cachedClass(class_def: parsing.Table.Layout.ClassDef, glyph: u16, cache: ?*common.MappingCache) parsing.Font.ParseError!u16 {
    const c = cache orelse return class_def.getClass(glyph);
    if (c.get(glyph)) |value| return value;
    const class = try class_def.getClass(glyph);
    if (class <= common.MappingCache.max_value) c.set(glyph, @intCast(class));
    return class;
}

fn valueRecordSize(format: u16) usize {
    return @as(usize, @popCount(@as(u8, @truncate(format)))) * 2;
}

fn applyValueRecord(gdef: Gdef, reader: parsing.Table.Layout.SubtableReader, offset: usize, format: u16, pos: *GlyphPosition, direction: Direction) parsing.Font.ParseError!void {
    const horizontal = direction == .left_to_right or direction == .right_to_left;
    var rel = offset;
    if (format & 0x0001 != 0) {
        pos.x_offset += try reader.i16At(rel);
        rel += 2;
    }
    if (format & 0x0002 != 0) {
        pos.y_offset += try reader.i16At(rel);
        rel += 2;
    }
    if (format & 0x0004 != 0) {
        if (horizontal) pos.x_advance += try reader.i16At(rel);
        rel += 2;
    }
    if (format & 0x0008 != 0) {
        if (!horizontal) pos.y_advance -= try reader.i16At(rel);
        rel += 2;
    }
    if (format & 0x0010 != 0) {
        pos.x_offset += deviceDelta(gdef, reader, try reader.u16At(rel));
        rel += 2;
    }
    if (format & 0x0020 != 0) {
        pos.y_offset += deviceDelta(gdef, reader, try reader.u16At(rel));
        rel += 2;
    }
    if (format & 0x0040 != 0) {
        if (horizontal) pos.x_advance += deviceDelta(gdef, reader, try reader.u16At(rel));
        rel += 2;
    }
    if (format & 0x0080 != 0) {
        if (!horizontal) pos.y_advance -= deviceDelta(gdef, reader, try reader.u16At(rel));
    }
}

/// How a single backtrack/input/lookahead position is tested against the
/// buffer glyph at that position - format 3 subtables store an
/// Offset16To<Coverage> per position (`.coverage`), format 1 rules store a
/// literal glyph id per position (`.glyph`), and format 2 rules store a
/// class number tested against a fixed ClassDef (`.class_def`). Mirrors
/// hb's `match_coverage`/`match_glyph`/`match_class`.
const MatchMode = union(enum) {
    coverage,
    glyph,
    class_def: parsing.Table.Layout.ClassDef,
};

fn matchAt(reader: parsing.Table.Layout.SubtableReader, mode: MatchMode, off: usize, glyph: u16) parsing.Font.ParseError!bool {
    switch (mode) {
        .coverage => {
            const cov = try reader.coverageAt(off);
            return (try cov.get(glyph)) != null;
        },
        .glyph => {
            const want = try reader.u16At(off);
            return want == glyph;
        },
        .class_def => |cd| {
            const want = try reader.u16At(off);
            return (try cd.getClass(glyph)) == want;
        },
    }
}

/// Resolved backtrack/input/lookahead/lookupRecord array positions for a
/// SequenceContext/ChainedSequenceContext subtable's rule being matched
/// (relative to `reader`'s own base, per `SubtableReader` convention).
/// `readContextFormat3Offsets`/`readChainContextFormat3Offsets` (format 3,
/// whole subtable, always `.coverage` mode) and `readRuleOffsets`/
/// `readChainRuleOffsets` (formats 1/2, one `Rule`/`ChainRule` at a time,
/// `.glyph` or `.class_def` mode selected by the caller) compute these from
/// the on-disk layouts so `applyContextCore` can share one match+apply
/// implementation across all formats.
///
/// `skip_first` handles one structural difference: format 3's input array
/// stores a coverage entry for position 0 too, but format 1/2 rules don't -
/// position 0 (the glyph that selected this RuleSet/Rule via the subtable's
/// own top-level Coverage/ClassDef) is implied matched, and the on-disk
/// array starts at position 1 ("HeadlessArray" in hb). When set,
/// `applyContextCore` skips its position-0 check and `input_base` is set 2
/// bytes before the array's real start so the existing `i * 2` indexing
/// still lands on position 1's real offset for `i == 1`.
const ContextOffsets = struct {
    backtrack_count: u16,
    backtrack_base: usize,
    backtrack_mode: MatchMode = .coverage,
    input_count: u16,
    input_base: usize,
    input_mode: MatchMode = .coverage,
    skip_first: bool = false,
    lookahead_count: u16,
    lookahead_base: usize,
    lookahead_mode: MatchMode = .coverage,
    lookup_count: u16,
    lookup_base: usize,
};

/// SequenceContextFormat3 (OT spec 6.3.3): format u16(=3), glyphCount u16,
/// lookupCount u16, then glyphCount Offset16To<Coverage> (one per input
/// position, including the first - matched separately from position 1+ by
/// `applyContextCore`), then lookupCount LookupRecords.
fn readContextFormat3Offsets(reader: parsing.Table.Layout.SubtableReader) parsing.Font.ParseError!ContextOffsets {
    const glyph_count = try reader.u16At(2);
    const lookup_count = try reader.u16At(4);
    return .{
        .backtrack_count = 0,
        .backtrack_base = 0,
        .input_count = glyph_count,
        .input_base = 6,
        .lookahead_count = 0,
        .lookahead_base = 0,
        .lookup_count = lookup_count,
        .lookup_base = 6 + @as(usize, glyph_count) * 2,
    };
}

/// ChainedSequenceContextFormat3 (OT spec 6.3.3): format u16(=3), then
/// three count-prefixed Offset16To<Coverage> arrays in match order
/// (backtrackCoverageOffsets, inputCoverageOffsets, lookaheadCoverageOffsets
/// - backtrack[0] is the glyph immediately preceding the match, matching
/// `match_backtrack`'s prev()-per-step convention; lookahead[0] is the
/// glyph immediately following), then a count-prefixed LookupRecord array.
fn readChainContextFormat3Offsets(reader: parsing.Table.Layout.SubtableReader) parsing.Font.ParseError!ContextOffsets {
    var off: usize = 2;
    const backtrack_count = try reader.u16At(off);
    off += 2;
    const backtrack_base = off;
    off += @as(usize, backtrack_count) * 2;
    const input_count = try reader.u16At(off);
    off += 2;
    const input_base = off;
    off += @as(usize, input_count) * 2;
    const lookahead_count = try reader.u16At(off);
    off += 2;
    const lookahead_base = off;
    off += @as(usize, lookahead_count) * 2;
    const lookup_count = try reader.u16At(off);
    off += 2;
    return .{
        .backtrack_count = backtrack_count,
        .backtrack_base = backtrack_base,
        .input_count = input_count,
        .input_base = input_base,
        .lookahead_count = lookahead_count,
        .lookahead_base = lookahead_base,
        .lookup_count = lookup_count,
        .lookup_base = off,
    };
}

/// Rule (OT spec 6.3.1, used by SequenceContextFormat1/2's RuleSets):
/// inputCount u16 (includes the first glyph, matched separately by the
/// caller via the subtable's top-level Coverage/ClassDef), lookupCount u16,
/// then (inputCount - 1) input values (glyph ids for format 1, class
/// numbers for format 2 - `input_mode` selects which) starting with the
/// second glyph, then lookupCount LookupRecords.
fn readRuleOffsets(rule: parsing.Table.Layout.SubtableReader, input_mode: MatchMode) parsing.Font.ParseError!ContextOffsets {
    const input_count = try rule.u16At(0);
    const lookup_count = try rule.u16At(2);
    const array_start = 4;
    const stored = if (input_count > 0) input_count - 1 else 0;
    return .{
        .backtrack_count = 0,
        .backtrack_base = 0,
        .input_count = input_count,
        .input_base = array_start - 2,
        .input_mode = input_mode,
        .skip_first = true,
        .lookahead_count = 0,
        .lookahead_base = 0,
        .lookup_count = lookup_count,
        .lookup_base = array_start + @as(usize, stored) * 2,
    };
}

/// ChainRule (OT spec 6.3.1, used by ChainedSequenceContextFormat1/2's
/// ChainRuleSets): backtrackCount u16, backtrack[backtrackCount] values (in
/// glyph sequence order - the array's first entry is the glyph immediately
/// preceding the match, same convention as `readChainContextFormat3Offsets`),
/// inputCount u16 (includes the first glyph, implied matched - same
/// headless-array convention as `readRuleOffsets`), input[inputCount - 1]
/// values, lookaheadCount u16, lookahead[lookaheadCount] values, lookupCount
/// u16, then lookupCount LookupRecords. `backtrack_mode`/`input_mode`/
/// `lookahead_mode` are independently selected by the caller since format 2
/// tests each array against its own ClassDef (backtrackClassDef/
/// inputClassDef/lookaheadClassDef).
fn readChainRuleOffsets(
    rule: parsing.Table.Layout.SubtableReader,
    backtrack_mode: MatchMode,
    input_mode: MatchMode,
    lookahead_mode: MatchMode,
) parsing.Font.ParseError!ContextOffsets {
    var off: usize = 0;
    const backtrack_count = try rule.u16At(off);
    off += 2;
    const backtrack_base = off;
    off += @as(usize, backtrack_count) * 2;
    const input_count = try rule.u16At(off);
    off += 2;
    const input_array_start = off;
    const stored = if (input_count > 0) input_count - 1 else 0;
    off += @as(usize, stored) * 2;
    const lookahead_count = try rule.u16At(off);
    off += 2;
    const lookahead_base = off;
    off += @as(usize, lookahead_count) * 2;
    const lookup_count = try rule.u16At(off);
    off += 2;
    return .{
        .backtrack_count = backtrack_count,
        .backtrack_base = backtrack_base,
        .backtrack_mode = backtrack_mode,
        .input_count = input_count,
        .input_base = input_array_start - 2,
        .input_mode = input_mode,
        .skip_first = true,
        .lookahead_count = lookahead_count,
        .lookahead_base = lookahead_base,
        .lookahead_mode = lookahead_mode,
        .lookup_count = lookup_count,
        .lookup_base = off,
    };
}

/// Attempts a single application of `lookup_index` (in the same table as
/// the caller) at the buffer's current position - one dispatch attempt
/// across that lookup's subtables, not the whole-buffer loop `applyLookup`
/// runs for a Map-driven top-level lookup. Used by `applyContextCore` to
/// apply a Context/ChainContext rule's `LookupRecord`s. `depth` is the
/// nesting budget; each hop through here consumes one level, guaranteeing
/// termination within `max_nesting_level` steps regardless of cyclic
/// LookupRecord references (CLAUDE.md's shaping attack-surface guidance).
/// No feature mask check on the nested lookup itself (hb's recursion
/// doesn't consult one either - masks gate the top-level per-feature
/// driving loop, not nested application), but `lookup_mask` still carries
/// the *outer* lookup's mask down, because hb leaves `c->lookup_mask`
/// untouched across `recurse` and the input matchers test candidate glyphs
/// against it.
fn applyLookupOnce(
    layout: parsing.Table.Layout,
    lookup_index: u16,
    lookup_mask: u32,
    random: bool,
    joiners: Joiners,
    gdef: Gdef,
    buffer: *Buffer,
    table_index: u1,
    direction: Direction,
    depth: u8,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    if (depth == 0) return false;
    if (buffer.idx >= buffer.len()) return false;
    buffer.max_ops -= 1;
    if (buffer.max_ops < 0) {
        buffer.successful = false;
        return false;
    }

    const lk = try layout.lookupAt(lookup_index);
    const lookup_type = try lk.lookupType();
    const lookup_flags = try lookupProps(lk);
    const sub_count = try lk.subtableCount();
    var si: u16 = 0;
    while (si < sub_count) : (si += 1) {
        const sub_off = try lk.subtableOffset(si);
        const applied = if (table_index == 0)
            try applyGsubSubtable(layout, lookup_type, sub_off, null, null, lookup_mask, random, joiners, buffer, gdef, lookup_flags, depth - 1)
        else
            try applyGposSubtable(layout, lookup_type, sub_off, null, null, joiners, gdef, lookup_flags, buffer, direction, depth - 1);
        if (applied) return true;
    }
    return false;
}

/// Ports the match+apply half of `context_apply_lookup`/
/// `chain_context_apply_lookup` (hb-ot-layout-gsubgpos.hh) for format-3
/// (coverage-based) Context/ChainContext subtables, GSUB and GPOS alike.
///
/// Backtrack matching differs by table: GSUB has `have_output` set during
/// its pass (see `applyLookup`), so already-processed glyphs live in
/// `buffer.out_info`, not `buffer.info` before `idx` - matches hb's
/// `backtrack_len()`-based addressing. GPOS never replaces glyphs, so it
/// has no such split; backtrack there walks `buffer.info` before `idx`
/// directly (same as `prevUnskipped`'s other callers).
///
/// Nested-lookup application (the `LookupRecord`s) ports hb's `apply_lookup`
/// directly: match positions recorded during the outer match (plain forward
/// indices into `buffer.info`) are first converted to hb's unified
/// backtrack+lookahead coordinate space, then each record's target is
/// reached via `buffer.moveTo` - which, unlike a plain forward cursor
/// advance, can rewind already-committed GSUB output out of `out_info` back
/// into pending `info` so a record can re-match a glyph an earlier record in
/// the same rule just inserted (this is exactly how a base->[base, matra
/// clone] MultipleSubst followed by a "matra,matra" ContextSubst relocates a
/// mark in practice - the earlier record's clone has to become visible as
/// forward input again for the later record to see it). A nested
/// application that changes buffer length shifts later positions and the
/// running match end by the resulting delta, same as hb.
fn applyContextCore(
    layout: parsing.Table.Layout,
    reader: parsing.Table.Layout.SubtableReader,
    offs: ContextOffsets,
    lookup_flags: u32,
    lookup_mask: u32,
    random: bool,
    joiners: Joiners,
    gdef: Gdef,
    buffer: *Buffer,
    table_index: u1,
    direction: Direction,
    depth: u8,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    if (offs.input_count == 0 or offs.input_count > max_context_length) return false;
    if (offs.backtrack_count > max_context_length or offs.lookahead_count > max_context_length) return false;

    const glyph = buffer.info.items[buffer.idx].codepoint;
    if (glyph > std.math.maxInt(u16)) return false;
    if (!offs.skip_first) {
        if (!try matchAt(reader, offs.input_mode, offs.input_base, @intCast(glyph))) return false;
    }

    var positions: [max_context_length]usize = undefined;
    positions[0] = buffer.idx;
    {
        var i: u16 = 1;
        var prev = buffer.idx;
        while (i < offs.input_count) : (i += 1) {
            const slot = SlotMatcher{ .reader = reader, .mode = offs.input_mode, .off = offs.input_base + @as(usize, i) * 2 };
            const next = try matchForward(buffer.info.items, gdef, lookup_flags, joiners.direct(table_index), prev + 1, slot) orelse return false;
            positions[i] = next;
            prev = next;
        }
    }
    const end_pos = positions[offs.input_count - 1] + 1;

    {
        var i: u16 = 0;
        var pos = end_pos;
        while (i < offs.lookahead_count) : (i += 1) {
            const slot = SlotMatcher{ .reader = reader, .mode = offs.lookahead_mode, .off = offs.lookahead_base + @as(usize, i) * 2 };
            const next = try matchForward(buffer.info.items, gdef, lookup_flags, joiners.contextual(table_index), pos, slot) orelse return false;
            pos = next + 1;
        }
    }

    {
        var i: u16 = 0;
        const out_items = buffer.outItems();
        var out_prev = out_items.len;
        var in_prev = buffer.idx;
        while (i < offs.backtrack_count) : (i += 1) {
            const slot = SlotMatcher{ .reader = reader, .mode = offs.backtrack_mode, .off = offs.backtrack_base + @as(usize, i) * 2 };
            const pos = if (table_index == 0)
                try matchBackward(out_items, gdef, lookup_flags, joiners.contextual(table_index), out_prev, slot) orelse return false
            else
                try matchBackward(buffer.info.items, gdef, lookup_flags, joiners.contextual(table_index), in_prev, slot) orelse return false;
            if (table_index == 0) out_prev = pos else in_prev = pos;
        }
    }

    // Convert `positions`/`end_pos` (recorded as plain forward indices into
    // `buffer.info`, relative to `buffer.idx` at match time) into hb's
    // unified backtrack+lookahead coordinate space, mirroring
    // `apply_lookup`'s opening block in hb-ot-layout-gsubgpos.hh. This lets
    // `buffer.moveTo` below reposition into already-committed `out_info`
    // when a later LookupRecord needs to re-match a glyph an earlier one in
    // the same rule just inserted (e.g. a MultipleSubst clone) - the
    // out-of-order splicing this function's doc comment used to say this
    // port skipped.
    var count: i64 = @intCast(offs.input_count);
    var end: i64 = blk: {
        const bl: i64 = @intCast(buffer.backtrackLen());
        const delta0: i64 = bl - @as(i64, @intCast(buffer.idx));
        var j: usize = 0;
        while (j < @as(usize, @intCast(count))) : (j += 1) {
            positions[j] = @intCast(@as(i64, @intCast(positions[j])) + delta0);
        }
        break :blk @as(i64, @intCast(end_pos)) + delta0;
    };

    var li: u16 = 0;
    while (li < offs.lookup_count and buffer.successful) : (li += 1) {
        const rec_off = offs.lookup_base + @as(usize, li) * 4;
        const seq_index = try reader.u16At(rec_off);
        const lookup_list_index = try reader.u16At(rec_off + 2);
        const idx_seq: usize = seq_index;
        if (idx_seq >= @as(usize, @intCast(count))) continue;

        const target_pos: i64 = @intCast(positions[idx_seq]);
        const orig_len: i64 = @intCast(buffer.backtrackLen() + buffer.lookaheadLen());
        if (target_pos >= orig_len) continue;

        try buffer.moveTo(@intCast(target_pos));
        if (!buffer.successful) break;
        if (buffer.max_ops <= 0) break;

        const applied = try applyLookupOnce(layout, lookup_list_index, lookup_mask, random, joiners, gdef, buffer, table_index, direction, depth);
        if (!applied) continue;

        const new_len: i64 = @intCast(buffer.backtrackLen() + buffer.lookaheadLen());
        var delta: i64 = new_len - orig_len;
        if (delta == 0) continue;

        end += delta;
        if (end < target_pos) {
            delta += target_pos - end;
            end = target_pos;
        }

        var next: i64 = @as(i64, @intCast(idx_seq)) + 1;
        if (delta > 0) {
            if (delta + count > max_context_length) break;
        } else {
            delta = @max(delta, next - count);
            next -= delta;
        }

        // Shift! (memmove positions[next+delta .. count+delta) = positions[next..count))
        const next_u: usize = @intCast(next);
        const count_u: usize = @intCast(count);
        if (delta > 0) {
            var k = count_u;
            while (k > next_u) {
                k -= 1;
                positions[@intCast(@as(i64, @intCast(k)) + delta)] = positions[k];
            }
        } else if (delta < 0) {
            var k = next_u;
            while (k < count_u) : (k += 1) {
                positions[@intCast(@as(i64, @intCast(k)) + delta)] = positions[k];
            }
        }
        next += delta;
        count += delta;

        var k: usize = idx_seq + 1;
        const next_u2: usize = @intCast(next);
        while (k < next_u2) : (k += 1) positions[k] = positions[k - 1] + 1;

        var k2: usize = next_u2;
        const count_u2: usize = @intCast(count);
        while (k2 < count_u2) : (k2 += 1) positions[k2] = @intCast(@as(i64, @intCast(positions[k2])) + delta);
    }
    std.debug.assert(end >= 0);
    try buffer.moveTo(@intCast(end));
    return true;
}

/// Ports `ContextFormat1_4`/`ContextFormat2_5`/`ChainContextFormat1_4`/
/// `ChainContextFormat2_5`'s `apply()` (hb-ot-layout-gsubgpos.hh): the
/// subtable's top-level Coverage picks a RuleSet/ChainRuleSet (format 1) or
/// its top-level Coverage plus `inputClassDef` picks one by class (format
/// 2), then each Rule/ChainRule in that set is tried in order - the first
/// whose backtrack/input/lookahead all match wins (`RuleSet::apply`'s
/// `hb_any` over its rules). Delegates the actual match+apply to
/// `applyContextCore` once per rule via `readRuleOffsets`/
/// `readChainRuleOffsets`.
fn applyRuleBasedContext(
    layout: parsing.Table.Layout,
    reader: parsing.Table.Layout.SubtableReader,
    lookup_flags: u32,
    lookup_mask: u32,
    random: bool,
    joiners: Joiners,
    gdef: Gdef,
    buffer: *Buffer,
    table_index: u1,
    direction: Direction,
    depth: u8,
    is_chain: bool,
    is_class: bool,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    const glyph = buffer.info.items[buffer.idx].codepoint;
    if (glyph > std.math.maxInt(u16)) return false;
    const gid: u16 = @intCast(glyph);

    const cov = try reader.coverageAt(2);
    const cov_index = try cov.get(gid) orelse return false;

    var rule_index: u16 = cov_index;
    var backtrack_mode: MatchMode = .glyph;
    var input_mode: MatchMode = .glyph;
    var lookahead_mode: MatchMode = .glyph;
    var ruleset_count_off: usize = undefined;
    if (is_chain) {
        if (is_class) {
            const bcd = try reader.classDefAt(4);
            const icd = try reader.classDefAt(6);
            const lcd = try reader.classDefAt(8);
            rule_index = try icd.getClass(gid);
            backtrack_mode = .{ .class_def = bcd };
            input_mode = .{ .class_def = icd };
            lookahead_mode = .{ .class_def = lcd };
            ruleset_count_off = 10;
        } else {
            ruleset_count_off = 4;
        }
    } else {
        if (is_class) {
            const icd = try reader.classDefAt(4);
            rule_index = try icd.getClass(gid);
            input_mode = .{ .class_def = icd };
            ruleset_count_off = 6;
        } else {
            ruleset_count_off = 4;
        }
    }

    const ruleset_count = try reader.u16At(ruleset_count_off);
    if (rule_index >= ruleset_count) return false;
    const ruleset = try reader.subReaderAt(ruleset_count_off + 2 + @as(usize, rule_index) * 2);
    const rule_count = try ruleset.u16At(0);

    var ri: u16 = 0;
    while (ri < rule_count) : (ri += 1) {
        const rule = try ruleset.subReaderAt(2 + @as(usize, ri) * 2);
        const offs = if (is_chain)
            try readChainRuleOffsets(rule, backtrack_mode, input_mode, lookahead_mode)
        else
            try readRuleOffsets(rule, input_mode);
        if (try applyContextCore(layout, rule, offs, lookup_flags, lookup_mask, random, joiners, gdef, buffer, table_index, direction, depth)) return true;
    }
    return false;
}

/// Ports `ReverseChainSingleSubstFormat1::apply` (OT spec 6.4): format
/// u16(=1), coverage offset16, backtrack (count-prefixed Offset16To<
/// Coverage> array, closest-preceding-glyph first - same convention as
/// ChainContext's backtrack), lookahead (same shape), then a count-prefixed
/// array of substitute GlyphIDs ordered by the top-level Coverage index.
/// Unlike every other lookup type here, this one is driven by `applyLookup`
/// walking the buffer *backward* with no `out_info` split (see that
/// function's `is_reverse` branch) - matching/substitution both act
/// directly on `buffer.info` in place, and the caller (not this function)
/// is responsible for the "no chaining to this type" nesting restriction
/// (checked via `depth != max_nesting_level` in `applyGsubSubtable`).
fn applyReverseChainSingleSubst(
    reader: parsing.Table.Layout.SubtableReader,
    gid: u16,
    lookup_flags: u32,
    joiners: Joiners,
    gdef: Gdef,
    buffer: *Buffer,
) parsing.Font.ParseError!bool {
    const cov = try reader.coverageAt(2);
    const index = try cov.get(gid) orelse return false;

    var off: usize = 4;
    const backtrack_count = try reader.u16At(off);
    off += 2;
    const backtrack_base = off;
    off += @as(usize, backtrack_count) * 2;
    const lookahead_count = try reader.u16At(off);
    off += 2;
    const lookahead_base = off;
    off += @as(usize, lookahead_count) * 2;
    const sub_count = try reader.u16At(off);
    off += 2;
    const sub_base = off;

    if (index >= sub_count) return false;
    if (backtrack_count > max_context_length or lookahead_count > max_context_length) return false;

    {
        var i: u16 = 0;
        var prev = buffer.idx;
        while (i < backtrack_count) : (i += 1) {
            const slot = SlotMatcher{ .reader = reader, .mode = .coverage, .off = backtrack_base + @as(usize, i) * 2 };
            prev = try matchBackward(buffer.info.items, gdef, lookup_flags, joiners.contextual(0), prev, slot) orelse return false;
        }
    }
    {
        var i: u16 = 0;
        var pos = buffer.idx + 1;
        while (i < lookahead_count) : (i += 1) {
            const slot = SlotMatcher{ .reader = reader, .mode = .coverage, .off = lookahead_base + @as(usize, i) * 2 };
            pos = (try matchForward(buffer.info.items, gdef, lookup_flags, joiners.contextual(0), pos, slot) orelse return false) + 1;
        }
    }

    const new_gid = try reader.u16At(sub_base + @as(usize, index) * 2);
    buffer.info.items[buffer.idx].codepoint = new_gid;
    buffer.info.items[buffer.idx].is_substituted = true;
    buffer.digest.add(new_gid);
    return true;
}

/// hb's `hb_ot_apply_context_t::_set_glyph_props`: stamps the glyphs a GSUB
/// lookup just appended to the output. `count` is how many it appended.
fn setGlyphProps(buffer: *Buffer, count: usize, ligature: bool, component: bool) void {
    const out = buffer.outItems();
    for (out[out.len - count ..]) |*glyph_info| {
        glyph_info.is_substituted = true;
        // hb: only the *last* Ligature/Multiple transformation counts, so a
        // ligature forgives an earlier multiplication.
        if (ligature) {
            glyph_info.is_ligated = true;
            glyph_info.is_multiplied = false;
        }
        if (component) glyph_info.is_multiplied = true;
    }
}

fn applyGsubSubtable(
    layout: parsing.Table.Layout,
    lookup_type: u16,
    sub_off: usize,
    cov0: ?*const parsing.Table.Layout.Coverage.Resolved,
    cache: ?*common.SubtableCache,
    lookup_mask: u32,
    random: bool,
    lookup_joiners: Joiners,
    buffer: *Buffer,
    gdef: Gdef,
    lookup_flags: u32,
    depth: u8,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    // hb resets the matcher's syllable to the current glyph's on every
    // application, nested ones included.
    var joiners = lookup_joiners;
    if (joiners.per_syllable) joiners.syllable = buffer.info.items[buffer.idx].indic_syllable;
    const reader = parsing.Table.Layout.SubtableReader{ .data = layout.data, .offset = sub_off, .cov0 = cov0 };
    const format = try reader.u16At(0);
    const glyph = buffer.info.items[buffer.idx].codepoint;
    if (glyph > std.math.maxInt(u16)) return false;
    const gid: u16 = @intCast(glyph);

    switch (lookup_type) {
        gsub_tag_single => {
            const cov = try reader.coverageAt(2);
            const idx = try cov.get(gid) orelse return false;
            switch (format) {
                1 => {
                    const delta = try reader.i16At(4);
                    const new_gid: u16 = @truncate(@as(u32, @bitCast(@as(i32, gid) +% @as(i32, delta))));
                    try buffer.replaceGlyph(new_gid);
                    setGlyphProps(buffer, 1, false, false);
                    return true;
                },
                2 => {
                    const count = try reader.u16At(4);
                    if (idx >= count) return false;
                    const new_gid = try reader.u16At(6 + @as(usize, idx) * 2);
                    try buffer.replaceGlyph(new_gid);
                    setGlyphProps(buffer, 1, false, false);
                    return true;
                },
                else => return false,
            }
        },
        gsub_tag_multiple => {
            if (format != 1) return false;
            const cov = try reader.coverageAt(2);
            const idx = try cov.get(gid) orelse return false;
            const seq_count = try reader.u16At(4);
            if (idx >= seq_count) return false;
            const seq = try reader.subReaderAt(6 + @as(usize, idx) * 2);
            const gcount = try seq.u16At(0);
            // The spec disallows an empty Sequence, but Uniscribe (and so
            // hb) reads it as a glyph deletion.
            if (gcount == 0) {
                buffer.deleteGlyph();
                return true;
            }
            // Sequence length is a u16 with no spec cap; the stack path
            // covers every real font, the heap path keeps a long one correct
            // instead of silently dropping the substitution.
            var stack_out: [64]u32 = undefined;
            const out = if (gcount <= stack_out.len)
                stack_out[0..gcount]
            else
                try buffer.allocator.alloc(u32, gcount);
            defer if (gcount > stack_out.len) buffer.allocator.free(out);
            var gi: usize = 0;
            while (gi < gcount) : (gi += 1) out[gi] = try seq.u16At(2 + gi * 2);
            const lig_id = buffer.info.items[buffer.idx].lig_id;
            try buffer.replaceGlyphs(1, out);
            setGlyphProps(buffer, gcount, false, true);
            // hb: a glyph already attached to a ligature keeps its lig props.
            if (lig_id == 0) {
                const out_items = buffer.outItems();
                const produced = out_items[out_items.len - gcount ..];
                for (produced, 0..) |*glyph_info, component| glyph_info.lig_comp = @truncate(component & 0x0F);
            }
            return true;
        },
        gsub_tag_alternate => {
            if (format != 1) return false;
            const cov = try reader.coverageAt(2);
            const idx = try cov.get(gid) orelse return false;
            const set_count = try reader.u16At(4);
            if (idx >= set_count) return false;
            const aset = try reader.subReaderAt(6 + @as(usize, idx) * 2);
            const count = try aset.u16At(0);
            if (count == 0 or lookup_mask == 0) return false;
            const shift: u5 = @intCast(@ctz(lookup_mask));
            const glyph_mask = buffer.info.items[buffer.idx].mask;
            var alt_index = (lookup_mask & glyph_mask) >> shift;
            // hb: a feature asking for the maximum value means "surprise
            // me", which only the 'rand' feature ever does.
            if (alt_index == map_max_feature_value and random) {
                buffer.unsafeToBreak(0, buffer.len());
                alt_index = buffer.randomNumber() % count + 1;
            }
            if (alt_index == 0 or alt_index > count) return false;
            const new_gid = try aset.u16At(2 + @as(usize, alt_index - 1) * 2);
            try buffer.replaceGlyph(new_gid);
            setGlyphProps(buffer, 1, false, false);
            return true;
        },
        gsub_tag_ligature => {
            if (format != 1) return false;
            const cov = try reader.coverageAt(2);
            const idx = try cachedCoverage(cov, gid, if (cache) |c| &c.coverage else null) orelse return false;
            const set_count = try reader.u16At(4);
            if (idx >= set_count) return false;
            const ligset = try reader.subReaderAt(6 + @as(usize, idx) * 2);
            const lig_count = try ligset.u16At(0);
            const second = if (lig_count > 1) ligatureSecondGlyph(buffer, gdef, lookup_flags, joiners.direct(0)) else null;
            if (second) |glyph_second| if (cache) |c| if (!c.seconds.mayHave(glyph_second)) return false;
            var li: usize = 0;
            while (li < lig_count) : (li += 1) {
                const lig = try ligset.subReaderAt(2 + li * 2);
                const lig_glyph = try lig.u16At(0);
                // componentCount includes the base glyph already matched via
                // Coverage; the on-disk component array (trailing glyphs to
                // match) has componentCount-1 entries.
                const component_count = try lig.u16At(2);
                // 64 is hb's own `HB_MAX_CONTEXT_LENGTH` cap on `match_input`.
                if (component_count == 0 or component_count > max_ligature_components) continue;
                const comp_count_m1 = component_count - 1;
                // The full match below would test its first component against
                // exactly `second`, so a mismatch here can't ligate.
                if (second) |glyph_second| if (comp_count_m1 > 0 and try lig.u16At(4) != glyph_second) continue;

                // Components are matched across `lookup_flags`-skipped
                // glyphs (an Arabic `rlig` with IgnoreMarks has to see
                // lam+alef through an intervening shadda), so the matched
                // positions aren't contiguous.
                var match_positions: [max_ligature_components]usize = undefined;
                match_positions[0] = buffer.idx;
                var matched = true;
                var ci: usize = 0;
                while (ci < comp_count_m1) : (ci += 1) {
                    // hb's `may_match`: a component outside this lookup's
                    // mask is a non-match, same as the wrong glyph id.
                    const component = ComponentMatcher{
                        .glyph = try lig.u16At(4 + ci * 2),
                        .lookup_mask = lookup_mask,
                    };
                    const next = try matchForward(buffer.info.items, gdef, lookup_flags, joiners.direct(0), match_positions[ci] + 1, component) orelse {
                        matched = false;
                        break;
                    };
                    match_positions[ci + 1] = next;
                }
                if (!matched) continue;

                // hb's `ligate_input`: the ligature replaces the first
                // component, skipped glyphs in between are kept (they end up
                // after it), and the remaining components are deleted.
                const end = match_positions[comp_count_m1] + 1;
                buffer.mergeClusters(buffer.idx, end);

                // A base (or a mark) that swallowed nothing but marks stays
                // a base (or a mark), so later marks can still attach to it;
                // anything else is a real ligature worth tracking.
                var is_base_ligature = infoGlyphClass(gdef, &buffer.info.items[match_positions[0]]) == 1;
                var is_mark_ligature = isMarkGlyph(gdef, &buffer.info.items[match_positions[0]]);
                for (match_positions[1..component_count]) |mp| {
                    if (!isMarkGlyph(gdef, &buffer.info.items[mp])) {
                        is_base_ligature = false;
                        is_mark_ligature = false;
                        break;
                    }
                }
                const is_ligature = !is_base_ligature and !is_mark_ligature;

                const lig_id: u8 = if (is_ligature) buffer.allocateLigId() else 0;
                var last_lig_id = buffer.info.items[buffer.idx].lig_id;
                var last_num_components: u16 = buffer.info.items[buffer.idx].lig_num_comps;
                var components_so_far: u16 = last_num_components;
                if (is_ligature) {
                    buffer.info.items[buffer.idx].lig_id = lig_id;
                    buffer.info.items[buffer.idx].lig_comp = 0;
                    buffer.info.items[buffer.idx].lig_num_comps = @truncate(component_count);
                }

                try buffer.replaceGlyph(lig_glyph);
                setGlyphProps(buffer, 1, true, false);
                var k: usize = 1;
                while (k < component_count) : (k += 1) {
                    while (buffer.idx < match_positions[k]) {
                        if (is_ligature) {
                            const cur = &buffer.info.items[buffer.idx];
                            const this_comp: u16 = if (cur.lig_comp == 0) last_num_components else cur.lig_comp;
                            cur.lig_id = lig_id;
                            cur.lig_comp = @truncate(components_so_far - last_num_components + @min(this_comp, last_num_components));
                            cur.lig_num_comps = 1;
                        }
                        try buffer.nextGlyph();
                    }
                    last_lig_id = buffer.info.items[buffer.idx].lig_id;
                    last_num_components = buffer.info.items[buffer.idx].lig_num_comps;
                    components_so_far += last_num_components;
                    buffer.skipGlyph();
                }

                // Marks that trailed the *last* component are still numbered
                // against that component's own former ligature; renumber them
                // into this one.
                if (!is_mark_ligature and last_lig_id != 0) {
                    for (buffer.info.items[buffer.idx..]) |*following| {
                        if (following.lig_id != last_lig_id) break;
                        if (following.lig_comp == 0) break;
                        following.lig_id = lig_id;
                        following.lig_comp = @truncate(components_so_far - last_num_components + @min(following.lig_comp, last_num_components));
                    }
                }
                return true;
            }
            return false;
        },
        // `direction` is unused down this path: table_index=0 means every
        // nested LookupRecord this can recurse into (via applyLookupOnce)
        // is itself GSUB, which never reads it.
        gsub_tag_context => {
            switch (format) {
                1 => return applyRuleBasedContext(layout, reader, lookup_flags, lookup_mask, random, joiners, gdef, buffer, 0, .left_to_right, depth, false, false),
                2 => return applyRuleBasedContext(layout, reader, lookup_flags, lookup_mask, random, joiners, gdef, buffer, 0, .left_to_right, depth, false, true),
                3 => {
                    const offs = try readContextFormat3Offsets(reader);
                    return applyContextCore(layout, reader, offs, lookup_flags, lookup_mask, random, joiners, gdef, buffer, 0, .left_to_right, depth);
                },
                else => return false,
            }
        },
        gsub_tag_chain_context => {
            switch (format) {
                1 => return applyRuleBasedContext(layout, reader, lookup_flags, lookup_mask, random, joiners, gdef, buffer, 0, .left_to_right, depth, true, false),
                2 => return applyRuleBasedContext(layout, reader, lookup_flags, lookup_mask, random, joiners, gdef, buffer, 0, .left_to_right, depth, true, true),
                3 => {
                    const offs = try readChainContextFormat3Offsets(reader);
                    return applyContextCore(layout, reader, offs, lookup_flags, lookup_mask, random, joiners, gdef, buffer, 0, .left_to_right, depth);
                },
                else => return false,
            }
        },
        gsub_tag_reverse_chain_single => {
            if (format != 1) return false;
            if (depth != max_nesting_level) return false;
            return applyReverseChainSingleSubst(reader, gid, lookup_flags, joiners, gdef, buffer);
        },
        gsub_tag_extension => {
            const unwrapped = try unwrapExtension(reader, gsub_tag_extension) orelse return false;
            return applyGsubSubtable(layout, unwrapped.lookup_type, unwrapped.sub_off, null, null, lookup_mask, random, joiners, buffer, gdef, lookup_flags, depth);
        },
        else => return false,
    }
}

fn applyGposSubtable(
    layout: parsing.Table.Layout,
    lookup_type: u16,
    sub_off: usize,
    cov0: ?*const parsing.Table.Layout.Coverage.Resolved,
    cache: ?*common.SubtableCache,
    joiners: Joiners,
    gdef: Gdef,
    lookup_flags: u32,
    buffer: *Buffer,
    direction: Direction,
    depth: u8,
) (parsing.Font.ParseError || error{OutOfMemory})!bool {
    const reader = parsing.Table.Layout.SubtableReader{ .data = layout.data, .offset = sub_off, .cov0 = cov0 };
    const format = try reader.u16At(0);
    const glyph = buffer.info.items[buffer.idx].codepoint;
    if (glyph > std.math.maxInt(u16)) return false;
    const gid: u16 = @intCast(glyph);

    switch (lookup_type) {
        gpos_tag_single => {
            const cov = try reader.coverageAt(2);
            const idx = try cov.get(gid) orelse return false;
            switch (format) {
                1 => {
                    const vf = try reader.u16At(4);
                    try applyValueRecord(gdef, reader, 6, vf, buffer.curPos(0), direction);
                    buffer.idx += 1;
                    return true;
                },
                2 => {
                    const vf = try reader.u16At(4);
                    const count = try reader.u16At(6);
                    if (idx >= count) return false;
                    const stride = valueRecordSize(vf);
                    try applyValueRecord(gdef, reader, 8 + idx * stride, vf, buffer.curPos(0), direction);
                    buffer.idx += 1;
                    return true;
                },
                else => return false,
            }
        },
        gpos_tag_pair => {
            if (format != 1 and format != 2) return false;
            const cov = try reader.coverageAt(2);
            const idx = try cachedCoverage(cov, gid, if (cache) |c| &c.coverage else null) orelse return false;
            const next = nextUnskipped(buffer, gdef, lookup_flags, joiners.direct(1), buffer.idx + 1) orelse return false;
            const second_glyph = buffer.info.items[next].codepoint;
            if (second_glyph > std.math.maxInt(u16)) return false;
            const second_gid: u16 = @intCast(second_glyph);
            const second_pos_offset = next - buffer.idx;

            switch (format) {
                1 => {
                    const vf1 = try reader.u16At(4);
                    const vf2 = try reader.u16At(6);
                    const pairset_count = try reader.u16At(8);
                    if (idx >= pairset_count) return false;
                    const pset = try reader.subReaderAt(10 + @as(usize, idx) * 2);
                    const rec_count = try pset.u16At(0);
                    const len1 = valueRecordSize(vf1);
                    const len2 = valueRecordSize(vf2);
                    const rec_size = 2 + len1 + len2;
                    var lo: u16 = 0;
                    var hi: u16 = rec_count;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        const rec_off = 2 + @as(usize, mid) * rec_size;
                        const sg = try pset.u16At(rec_off);
                        if (sg == second_gid) {
                            if (len1 > 0) try applyValueRecord(gdef, pset, rec_off + 2, vf1, buffer.curPos(0), direction);
                            if (len2 > 0) try applyValueRecord(gdef, pset, rec_off + 2 + len1, vf2, buffer.curPos(second_pos_offset), direction);
                            buffer.idx = next + @as(usize, if (len2 > 0) 1 else 0);
                            return true;
                        }
                        if (sg < second_gid) lo = mid + 1 else hi = mid;
                    }
                    return false;
                },
                2 => {
                    const vf1 = try reader.u16At(4);
                    const vf2 = try reader.u16At(6);
                    const cd1 = try reader.classDefAt(8);
                    const cd2 = try reader.classDefAt(10);
                    const class1count = try reader.u16At(12);
                    const class2count = try reader.u16At(14);
                    const k1 = try cachedClass(cd1, gid, if (cache) |c| &c.first else null);
                    const k2 = try cachedClass(cd2, second_gid, if (cache) |c| &c.second else null);
                    if (k1 >= class1count or k2 >= class2count) return false;
                    const len1 = valueRecordSize(vf1);
                    const len2 = valueRecordSize(vf2);
                    const rec_size = len1 + len2;
                    const rec_off = 16 + (@as(usize, k1) * class2count + k2) * rec_size;
                    if (len1 > 0) try applyValueRecord(gdef, reader, rec_off, vf1, buffer.curPos(0), direction);
                    if (len2 > 0) try applyValueRecord(gdef, reader, rec_off + len1, vf2, buffer.curPos(second_pos_offset), direction);
                    buffer.idx = next + @as(usize, if (len2 > 0) 1 else 0);
                    return true;
                },
                else => return false,
            }
        },
        gpos_tag_cursive => {
            if (format != 1) return false;
            return applyGposCursive(reader, gid, gdef, lookup_flags, buffer, direction, joiners.direct(1));
        },
        gpos_tag_mark_to_base => {
            if (format != 1) return false;
            return applyGposMarkToBase(reader, gid, gdef, buffer, direction, joiners.direct(1));
        },
        gpos_tag_mark_to_ligature => {
            if (format != 1) return false;
            return applyGposMarkToLigature(reader, gid, gdef, buffer, direction, joiners.direct(1));
        },
        gpos_tag_mark_to_mark => {
            if (format != 1) return false;
            return applyGposMarkToMark(reader, gid, gdef, lookup_flags, buffer, direction, joiners.direct(1));
        },
        gpos_tag_context => {
            switch (format) {
                1 => return applyRuleBasedContext(layout, reader, lookup_flags, gpos_lookup_mask, false, joiners, gdef, buffer, 1, direction, depth, false, false),
                2 => return applyRuleBasedContext(layout, reader, lookup_flags, gpos_lookup_mask, false, joiners, gdef, buffer, 1, direction, depth, false, true),
                3 => {
                    const offs = try readContextFormat3Offsets(reader);
                    return applyContextCore(layout, reader, offs, lookup_flags, gpos_lookup_mask, false, joiners, gdef, buffer, 1, direction, depth);
                },
                else => return false,
            }
        },
        gpos_tag_chain_context => {
            switch (format) {
                1 => return applyRuleBasedContext(layout, reader, lookup_flags, gpos_lookup_mask, false, joiners, gdef, buffer, 1, direction, depth, true, false),
                2 => return applyRuleBasedContext(layout, reader, lookup_flags, gpos_lookup_mask, false, joiners, gdef, buffer, 1, direction, depth, true, true),
                3 => {
                    const offs = try readChainContextFormat3Offsets(reader);
                    return applyContextCore(layout, reader, offs, lookup_flags, gpos_lookup_mask, false, joiners, gdef, buffer, 1, direction, depth);
                },
                else => return false,
            }
        },
        gpos_tag_extension => {
            const unwrapped = try unwrapExtension(reader, gpos_tag_extension) orelse return false;
            return applyGposSubtable(layout, unwrapped.lookup_type, unwrapped.sub_off, null, null, joiners, gdef, lookup_flags, buffer, direction, depth);
        },
        else => return false,
    }
}

/// GSUB's ReverseChainSingleSubst (type 8, possibly Extension-wrapped) is
/// the only lookup type hb applies back-to-front, in place - see
/// `applyLookup`'s `is_reverse` branch, ported from hb's
/// `SubstLookup::is_reverse`/`apply_backward`.
fn isReverseLookup(layout: parsing.Table.Layout, lk: parsing.Table.Layout.Lookup, lookup_type: u16) parsing.Font.ParseError!bool {
    if (lookup_type == gsub_tag_reverse_chain_single) return true;
    if (lookup_type != gsub_tag_extension) return false;
    if (try lk.subtableCount() == 0) return false;
    const sub_off = try lk.subtableOffset(0);
    const reader = parsing.Table.Layout.SubtableReader{ .data = layout.data, .offset = sub_off };
    const unwrapped = try unwrapExtension(reader, gsub_tag_extension) orelse return false;
    return unwrapped.lookup_type == gsub_tag_reverse_chain_single;
}

/// Ports hb's per-lookup `hb_set_digest_t` (the lookup accelerator in
/// hb-ot-layout-gsubgpos.hh): the union of each subtable's first input
/// Coverage, built once per plan and probed before walking the buffer for a
/// lookup. Most lookups in a large font cover nothing in a given run.
///
/// The digest may only over-approximate: anything unreadable here yields a
/// full digest, which filters nothing and leaves the walk exactly as it was.
///
/// Also appends one `SubtableInfo` per subtable (hb's
/// `hb_accelerate_subtables_context_t`), so `applyLookup` skips a subtable
/// whose Coverage can't hold the current glyph and applies the rest without
/// re-reading their headers. On a read error nothing is appended and the
/// full digest is returned, which puts `applyLookup` back on the slow path.
pub fn lookupDigest(
    allocator: std.mem.Allocator,
    layout: parsing.Table.Layout,
    lookup_index: u16,
    table_index: u1,
    subtables: *std.ArrayList(common.SubtableInfo),
    caches: *std.ArrayList(common.SubtableCache),
) error{OutOfMemory}!common.Digest {
    const start = subtables.items.len;
    const caches_start = caches.items.len;
    const digest = collectSubtableDigests(allocator, layout, lookup_index, table_index, subtables, caches) catch |err| {
        subtables.shrinkRetainingCapacity(start);
        caches.shrinkRetainingCapacity(caches_start);
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .full();
    };
    return digest;
}

fn collectSubtableDigests(
    allocator: std.mem.Allocator,
    layout: parsing.Table.Layout,
    lookup_index: u16,
    table_index: u1,
    subtables: *std.ArrayList(common.SubtableInfo),
    caches: *std.ArrayList(common.SubtableCache),
) (parsing.Font.ParseError || error{ OutOfMemory, Unfilterable })!common.Digest {
    const extension_tag: u16 = if (table_index == 0) gsub_tag_extension else gpos_tag_extension;
    const context_tag: u16 = if (table_index == 0) gsub_tag_context else gpos_tag_context;
    const chain_context_tag: u16 = if (table_index == 0) gsub_tag_chain_context else gpos_tag_chain_context;

    var digest: common.Digest = .{};
    const lk = try layout.lookupAt(lookup_index);
    const lookup_type = try lk.lookupType();
    const sub_count = try lk.subtableCount();
    // Bounded by the font: each subtable costs its lookup two bytes of offset.
    try subtables.ensureUnusedCapacity(allocator, sub_count);

    var si: u16 = 0;
    while (si < sub_count) : (si += 1) {
        const sub_off = try lk.subtableOffset(si);
        var reader = parsing.Table.Layout.SubtableReader{ .data = layout.data, .offset = sub_off };
        var effective_type = lookup_type;
        if (effective_type == extension_tag) {
            const unwrapped = (try unwrapExtension(reader, extension_tag)) orelse return error.Unfilterable;
            effective_type = unwrapped.lookup_type;
            reader = .{ .data = layout.data, .offset = unwrapped.sub_off };
        }
        const format = try reader.u16At(0);
        // Every subtable keeps its input Coverage at offset 2 except
        // Context/ChainContext format 3, where offset 2 is a glyph count and
        // the coverage offsets follow the counts.
        const coverage_rel: usize = if (format == 3 and (effective_type == context_tag or effective_type == chain_context_tag)) blk: {
            const offs = try (if (effective_type == context_tag)
                readContextFormat3Offsets(reader)
            else
                readChainContextFormat3Offsets(reader));
            if (offs.input_count == 0) return error.Unfilterable;
            break :blk offs.input_base;
        } else 2;
        const cov_off = try reader.u16At(coverage_rel);
        const cov = parsing.Table.Layout.Coverage{ .data = reader.data, .offset = reader.offset + cov_off };
        var sub_digest: common.Digest = .{};
        try cov.collectRanges(&sub_digest);
        digest.unionWith(sub_digest);
        if (reader.offset > std.math.maxInt(u32)) return error.InvalidTableFormat;
        // hb gives the first 8 subtables of a lookup an external cache.
        const cached = si < 8 and if (table_index == 0)
            effective_type == gsub_tag_ligature and format == 1
        else
            effective_type == gpos_tag_pair and format <= 2;
        var cache_index: u32 = common.SubtableInfo.no_cache;
        if (cached) {
            cache_index = @intCast(caches.items.len);
            try caches.append(allocator, .{
                .seconds = if (table_index == 0) ligatureSeconds(reader, layout.data.len / 2) else .full(),
            });
        }
        subtables.appendAssumeCapacity(.{
            .digest = sub_digest,
            .offset = @intCast(reader.offset),
            .lookup_type = effective_type,
            .coverage = if (coverage_rel == 2) try cov.resolve() else .{},
            .cache = cache_index,
        });
    }
    return digest;
}

fn applyLookup(
    layout: parsing.Table.Layout,
    entry: LookupMapEntry,
    gdef: Gdef,
    buffer: *Buffer,
    table_index: u1,
    direction: Direction,
    subtables: []const common.SubtableInfo,
    caches: []common.SubtableCache,
) (parsing.Font.ParseError || error{OutOfMemory})!void {
    const lk = try layout.lookupAt(entry.index);
    const lookup_type = try lk.lookupType();
    const lookup_flags = try lookupProps(lk);
    const joiners = Joiners{ .auto_zwnj = entry.auto_zwnj, .auto_zwj = entry.auto_zwj, .per_syllable = entry.per_syllable };
    const sub_count = try lk.subtableCount();

    if (table_index == 0 and try isReverseLookup(layout, lk, lookup_type)) {
        if (buffer.len() == 0) return;
        var idx = buffer.len() - 1;
        while (true) {
            buffer.idx = idx;
            if (buffer.info.items[idx].mask & entry.mask != 0 and
                entry.digest.mayHave(buffer.info.items[idx].codepoint) and
                matchesLookupProps(&buffer.info.items[idx], gdef, lookup_flags))
            {
                var si: u16 = 0;
                while (si < sub_count) : (si += 1) {
                    var sub_type = lookup_type;
                    var sub_cov: ?*const parsing.Table.Layout.Coverage.Resolved = null;
                    var sub_cache: ?*common.SubtableCache = null;
                    const sub_off = if (si < subtables.len) blk: {
                        if (!subtables[si].digest.mayHave(buffer.info.items[idx].codepoint)) continue;
                        sub_type = subtables[si].lookup_type;
                        if (subtables[si].coverage.format != 0) sub_cov = &subtables[si].coverage;
                        if (subtables[si].cache != common.SubtableInfo.no_cache) sub_cache = &caches[subtables[si].cache];
                        break :blk @as(usize, subtables[si].offset);
                    } else try lk.subtableOffset(si);
                    if (try applyGsubSubtable(layout, sub_type, sub_off, sub_cov, sub_cache, entry.mask, entry.random, joiners, buffer, gdef, lookup_flags, max_nesting_level)) break;
                }
            }
            if (idx == 0) break;
            idx -= 1;
        }
        buffer.idx = 0;
        return;
    }


    if (table_index == 0) buffer.clearOutput();
    while (buffer.idx < buffer.len()) {
        // hb's `apply_forward`: find the next applicable glyph in a tight
        // loop, then move the rejected run to the output in one step.
        const infos = buffer.info.items;
        var next = buffer.idx;
        while (next < infos.len) : (next += 1) {
            if (infos[next].mask & entry.mask != 0 and
                entry.digest.mayHave(infos[next].codepoint) and
                matchesLookupProps(&infos[next], gdef, lookup_flags)) break;
        }
        if (next > buffer.idx) try buffer.nextGlyphs(next - buffer.idx);
        if (buffer.idx >= buffer.len()) break;
        var applied = false;
        {
            var si: u16 = 0;
            while (si < sub_count) : (si += 1) {
                var sub_type = lookup_type;
                var sub_cov: ?*const parsing.Table.Layout.Coverage.Resolved = null;
                var sub_cache: ?*common.SubtableCache = null;
                const sub_off = if (si < subtables.len) blk: {
                    if (!subtables[si].digest.mayHave(buffer.info.items[buffer.idx].codepoint)) continue;
                    sub_type = subtables[si].lookup_type;
                    if (subtables[si].coverage.format != 0) sub_cov = &subtables[si].coverage;
                    if (subtables[si].cache != common.SubtableInfo.no_cache) sub_cache = &caches[subtables[si].cache];
                    break :blk @as(usize, subtables[si].offset);
                } else try lk.subtableOffset(si);
                applied = if (table_index == 0)
                    try applyGsubSubtable(layout, sub_type, sub_off, sub_cov, sub_cache, entry.mask, entry.random, joiners, buffer, gdef, lookup_flags, max_nesting_level)
                else
                    try applyGposSubtable(layout, sub_type, sub_off, sub_cov, sub_cache, joiners, gdef, lookup_flags, buffer, direction, max_nesting_level);
                if (applied) break;
            }
        }
        if (!applied) try buffer.nextGlyph();
    }
    if (table_index == 0) try buffer.sync() else buffer.idx = 0;
}

pub fn applyStage(
    font: parsing.Font,
    map: Map,
    table_index: u1,
    gdef: Gdef,
    buffer: *Buffer,
    direction: Direction,
    stage: u32,
) (parsing.Font.ParseError || error{OutOfMemory})!void {
    const tag = if (table_index == 0) table_tag_gsub else table_tag_gpos;
    const data = font.tableData(tag) orelse return;
    const layout = parsing.Table.Layout{ .data = data };
    buffer.updateDigest();
    for (map.getStageLookups(table_index, stage)) |entry| {
        // Substitutions during this pass only ever add glyphs to the buffer
        // digest, so a lookup skipped here could not have matched earlier in
        // the pass either. Added glyphs copy an input glyph's mask, so the
        // mask union never gains a feature bit within a stage.
        if (entry.mask & buffer.mask_union == 0) continue;
        if (!entry.digest.mayIntersect(buffer.digest)) continue;
        const subtables = map.subtables.items[entry.subtables_start..][0..entry.subtables_len];
        try applyLookup(layout, entry, gdef, buffer, table_index, direction, subtables, map.subtable_caches.items);
    }
}

/// Zero-context `hb_ot_layout_lookup_would_substitute`: does this GSUB
/// lookup substitute exactly this glyph sequence, standalone? The Indic
/// shaper asks this of a font's blwf/pstf/pref/vatu/rphf lookups to decide
/// where the base consonant and the reph are, before any lookup has run.
///
/// ponytail: only the four direct substitution types (plus Extension) are
/// answered; a context lookup reports "no". Real Indic fonts put these
/// features in Single/Ligature lookups, and a false "no" only costs the
/// syntactic fallback this function replaced.
fn lookupWouldSubstitute(
    layout: parsing.Table.Layout,
    lookup_index: u16,
    glyphs: []const u32,
) parsing.Font.ParseError!bool {
    if (glyphs.len == 0) return false;
    const lk = layout.lookupAt(lookup_index) catch return false;
    const lookup_type = try lk.lookupType();
    const sub_count = try lk.subtableCount();
    var si: u16 = 0;
    while (si < sub_count) : (si += 1) {
        if (try subtableWouldSubstitute(layout, lookup_type, try lk.subtableOffset(si), glyphs)) return true;
    }
    return false;
}

fn subtableWouldSubstitute(
    layout: parsing.Table.Layout,
    lookup_type: u16,
    sub_off: usize,
    glyphs: []const u32,
) parsing.Font.ParseError!bool {
    if (glyphs[0] > std.math.maxInt(u16)) return false;
    const gid: u16 = @intCast(glyphs[0]);
    const reader = parsing.Table.Layout.SubtableReader{ .data = layout.data, .offset = sub_off };
    switch (lookup_type) {
        gsub_tag_single, gsub_tag_multiple, gsub_tag_alternate => {
            if (glyphs.len != 1) return false;
            const cov = try reader.coverageAt(2);
            return try cov.get(gid) != null;
        },
        gsub_tag_ligature => {
            if (try reader.u16At(0) != 1) return false;
            const cov = try reader.coverageAt(2);
            const idx = try cov.get(gid) orelse return false;
            if (idx >= try reader.u16At(4)) return false;
            const ligset = try reader.subReaderAt(6 + @as(usize, idx) * 2);
            const lig_count = try ligset.u16At(0);
            var li: usize = 0;
            while (li < lig_count) : (li += 1) {
                const lig = try ligset.subReaderAt(2 + li * 2);
                if (try lig.u16At(2) != glyphs.len) continue;
                var ci: usize = 1;
                while (ci < glyphs.len) : (ci += 1) {
                    if (try lig.u16At(4 + (ci - 1) * 2) != glyphs[ci]) break;
                } else return true;
            }
            return false;
        },
        gsub_tag_extension => {
            const unwrapped = try unwrapExtension(reader, gsub_tag_extension) orelse return false;
            return subtableWouldSubstitute(layout, unwrapped.lookup_type, unwrapped.sub_off, glyphs);
        },
        else => return false,
    }
}

/// hb's `hb_indic_would_substitute_feature_t`: would any lookup of this
/// feature's own GSUB stage substitute `glyphs`?
pub fn featureWouldSubstitute(
    font: parsing.Font,
    map: Map,
    tag: Tag,
    glyphs: []const u32,
) parsing.Font.ParseError!bool {
    const stage = map.getFeatureStage(0, tag) orelse return false;
    const data = font.tableData(table_tag_gsub) orelse return false;
    const layout = parsing.Table.Layout{ .data = data };
    for (map.getStageLookups(0, stage)) |entry| {
        // A lookup whose coverage can't hold the first glyph can't match the
        // sequence either; the Indic shaper asks this of every consonant.
        if (glyphs.len != 0 and !entry.digest.mayHave(glyphs[0])) continue;
        if (try lookupWouldSubstitute(layout, entry.index, glyphs)) return true;
    }
    return false;
}

/// Ported from hb-ot-shape.cc's `hb_ot_hide_default_ignorables`: runs after
/// GSUB, before GPOS, so mark/kern lookups see the final (invisible) glyph
/// rather than whatever ink the font mapped the ignorable codepoint to
/// (e.g. CrimsonPro maps U+00AD SOFT HYPHEN to a visible hyphen-minus glyph
/// via cmap - left alone, that renders a stray "-" in normal text that never
/// hit an actual line break). Substitutes the font's space glyph in place of
/// the ignorable's glyph id; `zeroDefaultIgnorableAdvances` (after GPOS)
/// zeroes its advance/offset so it takes up no visible space either.
///
/// A font with no space glyph in its cmap at all (Noto Color Emoji and the
/// web-fallback slices cut from it) takes hb's other branch, deleting the
/// glyphs outright: the only substitute left would be .notdef, which with a
/// zeroed advance draws a visible box on top of the following glyph (U+FE0F
/// after an emoji base).
pub fn hideDefaultIgnorables(buffer: *Buffer, cmap: ?Cmap) void {
    if (cmap) |resolved| if (resolved.lookup(' ')) |space_glyph| {
        for (buffer.info.items) |*info| {
            if (common.isIgnorable(info.*)) info.codepoint = space_glyph;
        }
        return;
    };
    const with_positions = buffer.pos.items.len == buffer.info.items.len;
    var kept: usize = 0;
    for (buffer.info.items, 0..) |info, i| {
        if (common.isIgnorable(info)) continue;
        buffer.info.items[kept] = info;
        if (with_positions) buffer.pos.items[kept] = buffer.pos.items[i];
        kept += 1;
    }
    buffer.info.shrinkRetainingCapacity(kept);
    if (with_positions) buffer.pos.shrinkRetainingCapacity(kept);
    buffer.idx = @min(buffer.idx, kept);
}

/// Ported from hb-ot-shape.cc's `hb_ot_zero_width_default_ignorables`: runs
/// after GPOS so its advance/offset overrides whatever positioning the
/// substituted space glyph picked up (kerning, mark attachment, ...).
pub fn zeroDefaultIgnorableAdvances(buffer: *Buffer, direction: Direction) void {
    const horizontal = direction == .left_to_right or direction == .right_to_left;
    for (buffer.info.items, buffer.pos.items) |glyph_info, *pos| {
        if (!common.isIgnorable(glyph_info)) continue;
        pos.x_advance = 0;
        pos.y_advance = 0;
        if (horizontal) pos.x_offset = 0 else pos.y_offset = 0;
    }
}

pub const table_tag_gdef = Tag{ 'G', 'D', 'E', 'F' };
pub const table_tag_hhea = Tag{ 'h', 'h', 'e', 'a' };
pub const table_tag_hmtx = Tag{ 'h', 'm', 't', 'x' };
pub const table_tag_hvar = Tag{ 'H', 'V', 'A', 'R' };

/// Ported from hb-ot-shape.cc's `hb_ot_position_default`: writes each
/// glyph's hmtx advance width into its position record before GPOS runs, so
/// PairPos/mark-attachment math (and the post-GPOS steps below) has a real
/// baseline to adjust instead of zero. Horizontal only - no `vmtx` reader
/// exists in this port yet, so vertical text's y_advance stays 0 (same
/// "vertical writing mode not supported" gap already flagged elsewhere in
/// this component).
/// hb's `get_glyph_h_advance` in font units: hmtx plus HVAR at the
/// shaping coords.
pub const HorizontalMetrics = struct {
    hmtx: []const u8,
    number_of_h_metrics: u16,
    hvar: ?[]const u8,
    normalized_coords: []const f32,
    /// Evaluated once per buffer rather than once per glyph -- the region
    /// scalars only depend on the coords.
    scalars: parsing.Table.HVAR.RegionScalars = .{},

    pub fn init(font: parsing.Font, normalized_coords: []const f32) ?HorizontalMetrics {
        const hhea_data = font.tableData(table_tag_hhea) orelse return null;
        const hhea = parsing.Table.hhea.parse(hhea_data) catch return null;
        var self: HorizontalMetrics = .{
            .hmtx = font.tableData(table_tag_hmtx) orelse return null,
            .number_of_h_metrics = hhea.number_of_h_metrics,
            .hvar = if (normalized_coords.len != 0) font.tableData(table_tag_hvar) else null,
            .normalized_coords = normalized_coords,
        };
        if (self.hvar) |hv| {
            if (hv.len >= 8) {
                const store_offset = std.mem.readInt(u32, hv[4..][0..4], .big);
                self.scalars = .init(hv, store_offset, normalized_coords);
            }
        }
        return self;
    }

    pub fn advance(self: *const HorizontalMetrics, glyph: u32) i32 {
        const glyph_id: u16 = @intCast(glyph & 0xFFFF);
        const advance_width: i32 = parsing.Table.hmtx.metricForGlyph(self.hmtx, glyph_id, self.number_of_h_metrics).advance_width;
        const hv = self.hvar orelse return advance_width;
        return advance_width + @as(i32, @intFromFloat(hbRound(parsing.Table.HVAR.advanceWidthDelta(hv, glyph_id, self.normalized_coords, &self.scalars))));
    }
};

pub fn applyDefaultHorizontalAdvances(font: parsing.Font, buffer: *Buffer, cmap: ?Cmap, normalized_coords: []const f32) void {
    const metrics = HorizontalMetrics.init(font, normalized_coords) orelse return;
    var has_space_fallback = false;
    // hb's `hb_cache_t`, direct-mapped: text repeats glyphs, and an HVAR
    // delta costs a delta-set map lookup plus a delta-row walk each time.
    var cached_glyph: [256]u32 = @splat(std.math.maxInt(u32));
    var cached_advance: [256]i32 = undefined;
    for (buffer.info.items, buffer.pos.items) |glyph_info, *pos| {
        const glyph = glyph_info.codepoint;
        const slot = glyph & 0xFF;
        if (cached_glyph[slot] != glyph) {
            cached_glyph[slot] = glyph;
            cached_advance[slot] = metrics.advance(glyph);
        }
        pos.x_advance = cached_advance[slot];
        if (glyph_info.space_fallback != .not_space) has_space_fallback = true;
    }
    if (has_space_fallback) applySpaceFallbackAdvances(font, buffer, cmap, metrics.hmtx, metrics.number_of_h_metrics);
}

/// Ported from hb-ot-shape-fallback.cc's `_hb_ot_shape_fallback_spaces`: the
/// normalizer borrowed the plain space glyph for a Unicode space the font
/// has no glyph for, so its advance is the plain space's - resize it to what
/// that space character is actually worth. Horizontal only, matching
/// `applyDefaultHorizontalAdvances` above.
fn applySpaceFallbackAdvances(
    font: parsing.Font,
    buffer: *Buffer,
    cmap: ?Cmap,
    hmtx_data: []const u8,
    number_of_h_metrics: u16,
) void {
    const head_data = font.tableData(Tag{ 'h', 'e', 'a', 'd' }) orelse return;
    const units_per_em: i32 = (parsing.Table.head.parse(head_data) catch return).units_per_em;

    const advanceOf = struct {
        fn f(mtx: []const u8, n: u16, glyph_id: u32) i32 {
            return parsing.Table.hmtx.metricForGlyph(mtx, @intCast(glyph_id & 0xFFFF), n).advance_width;
        }
    }.f;

    for (buffer.info.items, buffer.pos.items) |glyph_info, *pos| {
        // A ligature that swallowed the space is no longer a space glyph.
        if (glyph_info.lig_num_comps > 1) continue;
        const divisor: i32 = switch (glyph_info.space_fallback) {
            .not_space, .space => continue,
            .em, .em_2, .em_3, .em_4, .em_5, .em_6, .em_16 => |t| @intFromEnum(t),
            .four_em_18 => {
                pos.x_advance = @intCast(@divTrunc(@as(i64, units_per_em) * 4, 18));
                continue;
            },
            .figure => {
                var digit: u21 = '0';
                while (digit <= '9') : (digit += 1) {
                    if (cmap) |c| if (c.lookup(digit)) |g| {
                        pos.x_advance = advanceOf(hmtx_data, number_of_h_metrics, g);
                        break;
                    };
                }
                continue;
            },
            .punctuation => {
                if (cmap) |c| if (c.lookup('.') orelse c.lookup(',')) |g| {
                    pos.x_advance = advanceOf(hmtx_data, number_of_h_metrics, g);
                };
                continue;
            },
            // Unicode says ~1/4-1/5 em, but plenty of fonts already have a
            // space about that wide; hb takes half the space instead.
            .narrow => {
                pos.x_advance = @divTrunc(pos.x_advance, 2);
                continue;
            },
        };
        pos.x_advance = @divTrunc(units_per_em + @divTrunc(divisor, 2), divisor);
    }
}

/// Ported from hb-ot-shape.cc's `zero_mark_widths_by_gdef`, called after
/// GPOS with `adjust_offsets` hardcoded false: real hb only passes `true`
/// when the font has no GPOS table at all (`!plan->apply_gpos`), a case this
/// port doesn't otherwise support (would also require the never-ported
/// fallback mark-positioning system) - so this covers the common
/// font-has-GPOS case exactly and degrades gracefully (mark advances still
/// zeroed, offsets just not backfilled) in the rare no-GPOS one.
pub fn zeroMarkWidthsByGdef(buffer: *Buffer, gdef: Gdef) void {
    for (buffer.info.items, buffer.pos.items) |*glyph_info, *pos| {
        if (isMarkGlyph(gdef, glyph_info)) {
            pos.x_advance = 0;
            pos.y_advance = 0;
        }
    }
}

/// Ported from GPOS.hh's `propagate_attachment_offsets`: mark/cursive
/// attachment lookups only record a relative link (`attach_chain`/
/// `attach_type`) plus the anchor-difference offset at apply time; this
/// walks each link back to its attachment target and accumulates the
/// target's own offset (recursively, for chains of attachments) so the
/// final `pos.x_offset`/`y_offset` are absolute. For marks it also
/// subtracts (LTR) or adds (RTL) the x_advance of every glyph between the
/// base and the mark, since GlyphPosition offsets are relative to the
/// glyph's own pen position, not the base's. `nesting_level` bounds
/// recursion the same way `max_nesting_level` bounds lookup nesting
/// elsewhere in this file - a malicious font could set up a long or cyclic
/// attach_chain walk otherwise.
fn propagateAttachmentOffsets(buffer: *Buffer, i: usize, direction: Direction, nesting_level: u8) void {
    const pos_i = buffer.posAt(i);
    const chain = pos_i.attach_chain;
    const atype = pos_i.attach_type;
    pos_i.attach_chain = 0;

    if (chain == 0) return;
    const j_signed = @as(i64, @intCast(i)) + chain;
    if (j_signed < 0 or j_signed >= buffer.len()) return;
    const j: usize = @intCast(j_signed);

    if (nesting_level == 0) return;

    if (buffer.posAt(j).attach_chain != 0) propagateAttachmentOffsets(buffer, j, direction, nesting_level - 1);

    const horizontal = direction == .left_to_right or direction == .right_to_left;
    const forward = direction == .left_to_right or direction == .top_to_bottom;

    if (atype & attach_type_cursive != 0) {
        if (horizontal) {
            buffer.posAt(i).y_offset += buffer.posAt(j).y_offset;
        } else {
            buffer.posAt(i).x_offset += buffer.posAt(j).x_offset;
        }
    } else {
        if (horizontal) {
            buffer.posAt(i).x_offset += buffer.posAt(j).x_offset;
        } else {
            buffer.posAt(i).y_offset += buffer.posAt(j).y_offset;
        }

        if (j < i) {
            if (forward) {
                var k = j;
                while (k < i) : (k += 1) {
                    buffer.posAt(i).x_offset -= buffer.posAt(k).x_advance;
                    buffer.posAt(i).y_offset -= buffer.posAt(k).y_advance;
                }
            } else {
                var k = j + 1;
                while (k < i + 1) : (k += 1) {
                    buffer.posAt(i).x_offset += buffer.posAt(k).x_advance;
                    buffer.posAt(i).y_offset += buffer.posAt(k).y_advance;
                }
            }
        } else {
            if (forward) {
                var k = i;
                while (k < j) : (k += 1) {
                    buffer.posAt(i).x_offset += buffer.posAt(k).x_advance;
                    buffer.posAt(i).y_offset += buffer.posAt(k).y_advance;
                }
            } else {
                var k = i + 1;
                while (k < j + 1) : (k += 1) {
                    buffer.posAt(i).x_offset -= buffer.posAt(k).x_advance;
                    buffer.posAt(i).y_offset -= buffer.posAt(k).y_advance;
                }
            }
        }
    }
}

/// Ported from GPOS.hh's `position_finish_offsets`: runs
/// `propagateAttachmentOffsets` over every glyph with a pending attachment
/// link, forward for LTR/TTB and backward for RTL/BTT (matching hb's
/// direction-dependent iteration order).
pub fn finishGposOffsets(buffer: *Buffer, direction: Direction) void {
    const forward = direction == .left_to_right or direction == .top_to_bottom;
    const len = buffer.len();
    if (forward) {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (buffer.posAt(i).attach_chain != 0) propagateAttachmentOffsets(buffer, i, direction, max_nesting_level);
        }
    } else {
        var i: usize = len;
        while (i > 0) {
            i -= 1;
            if (buffer.posAt(i).attach_chain != 0) propagateAttachmentOffsets(buffer, i, direction, max_nesting_level);
        }
    }
}

// Unicode normalization (ported from hb-ot-shape-normalize.cc's
// _hb_ot_shape_normalize) plus joiner (ZWJ/ZWNJ) skip handling. Runs once,
// on Unicode codepoints, before the codepoint field is overwritten with a
// glyph id (see GlyphInfo's var1 doc comment and `mapGlyphsFast`).
//
// Scope cuts vs. hb-ot-shape-normalize.cc, all because this port has no
// complex shapers yet (phase-1 scope, see this file's top doc comment) and
// no bidi/native-direction buffer reversal yet:
// - Normalization mode is hardcoded to COMPOSED_DIACRITICS. hb's `AUTO`
//   mode picks this same mode whichever way `plan->has_gpos_mark` goes
//   (both branches of that switch assign the same value - see the comment
//   left in place in hb-ot-shape-normalize.cc), so this isn't a behavioral
//   narrowing, just skipping a dead branch. `might_short_circuit` is
//   therefore always true and `always_short_circuit` always false.
// - `decompose`/`compose` are always `unicode.decomposeCanonical`/
//   `composeCanonical` - no per-shaper override (that mechanism exists
//   solely for complex shapers, e.g. Indic disallowing matra recomposition).
// - Variation-selector cluster handling (`handle_variation_selector_cluster`)
//   is not ported: a font-unsupported base+VS pair falls through to being
//   decomposed/passed-through character-by-character instead of getting
//   VS-aware GSUB glyph substitution. Rare in practice (most fonts either
//   fully support their VS sequences via cmap format 14, unaffected by this
//   cut, or don't support them at all).
// - Space fallback (`space_fallback_type`) and the U+2011 (non-breaking
//   hyphen) no-glyph fallback are not ported - a font missing a space
//   variant or U+2011 glyph gets .notdef instead of a fallback substitute.
// - The CGJ (U+034F) reorder-blocking-check special case is not ported -
//   this port has no "hidden but not ignorable" glyph-flag infrastructure
//   for the skip iterator to consult (see hb-ot-layout.hh's UPROPS_MASK_HIDDEN),
//   which is what that special case exists to protect.
// - hb_ensure_native_direction is not ported; hb_set_unicode_props's
//   grapheme-continuation tracking and hb_form_clusters are, as
//   normalize.zig's `formClusters`.
//
// Joiner (ZWJ/ZWNJ) handling: hb's skip iterator ignores ZWJ/ZWNJ during
// lookup-flag glyph matching based on per-lookup `auto_zwnj`/`auto_zwj` flags
// (see `shouldSkipGlyph`'s doc comment) that a complex shaper can override to
// "manual" for specific features. Since this port has no complex shapers,
// those flags are always "auto" (true), so ZWJ/ZWNJ are unconditionally
// skippable - `is_zwj`/`is_zwnj` on GlyphInfo (set once here from the
// original codepoint, before it's overwritten with a glyph id) are all
// `shouldSkipGlyph` needs.
