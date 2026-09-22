// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const parsing = @import("../parsing.zig");
const unicode = @import("../unicode.zig");
const common = @import("common.zig");
const Buffer = common.Buffer;
const Cmap = common.Cmap;
const GlyphInfo = common.GlyphInfo;
const combiningClassOf = common.combiningClassOf;

pub const DecomposeOverride = enum { none, indic, khmer };

const NormalizeContext = struct {
    cmap: ?Cmap,
    /// hb's per-shaper `decompose` override (`decompose_indic`/`decompose_khmer`).
    decompose_override: DecomposeOverride = .none,
    /// `compose_hebrew`'s fallback half, which hb runs only when the font
    /// has no GPOS 'mark' feature to position the points itself.
    hebrew_presentation_forms: bool = false,
    cached_codepoint: [64]u21 = @splat(not_unicode),
    cached_glyph: [64]u32 = undefined,

    const not_unicode = std.math.maxInt(u21);
    const not_found = std.math.maxInt(u32);

    /// Ported from `decompose_indic`'s explicit "don't decompose these"
    /// cases: these four are letters in their own right, and splitting them
    /// leaves the syllable machine looking at a consonant plus a stray
    /// nukta/matra (a Tamil AU would shape as a broken cluster and take a
    /// dotted circle).
    fn blocksDecomposition(self: *NormalizeContext, ab: u21) bool {
        if (self.decompose_override != .indic) return false;
        return switch (ab) {
            0x0931, 0x09DC, 0x09DD, 0x0B94 => true,
            else => false,
        };
    }

    /// Ported from `decompose_khmer`: split matras with no Unicode
    /// decomposition still carry the pre-base 0x17C1 part.
    fn decompose(self: *NormalizeContext, ab: u21) ?unicode.Decomposition {
        if (self.decompose_override == .khmer) switch (ab) {
            0x17BE, 0x17BF, 0x17C0, 0x17C4, 0x17C5 => return .{ .first = 0x17C1, .second = ab },
            else => {},
        };
        return unicode.decomposeCanonical(ab);
    }

    /// `compose_indic` recomposes this composition exclusion anyway.
    fn compose(self: *NormalizeContext, a: u21, b: u21) ?u21 {
        if (self.decompose_override == .indic and a == 0x09AF and b == 0x09BC) return 0x09DF;
        if (unicode.composeCanonical(a, b)) |ab| return ab;
        if (self.hebrew_presentation_forms) return composeHebrew(a, b);
        return null;
    }

    fn variationGlyph(self: *NormalizeContext, codepoint: u21, selector: u21) ?u32 {
        const resolved = self.cmap orelse return null;
        return resolved.lookupVariation(codepoint, selector) orelse null;
    }

    /// hb's font-level nominal-glyph cache, direct-mapped: text repeats
    /// characters and each miss is a cmap subtable search.
    fn nominalGlyph(self: *NormalizeContext, codepoint: u21) ?u32 {
        const resolved = self.cmap orelse return null;
        const slot = codepoint & 0x3F;
        if (self.cached_codepoint[slot] != codepoint) {
            self.cached_codepoint[slot] = codepoint;
            self.cached_glyph[slot] = resolved.lookup(codepoint) orelse not_found;
        }
        const glyph = self.cached_glyph[slot];
        return if (glyph == not_found) null else glyph;
    }
};

/// Ported from `compose_hebrew`'s fallback: Hebrew presentation forms that
/// canonical composition excludes, but that old fonts without GPOS mark
/// positioning still rely on.
fn composeHebrew(a: u21, b: u21) ?u21 {
    const dagesh_forms = [_]u21{
        0xFB30, 0xFB31, 0xFB32, 0xFB33, 0xFB34, 0xFB35, 0xFB36, 0x0000, 0xFB38,
        0xFB39, 0xFB3A, 0xFB3B, 0xFB3C, 0x0000, 0xFB3E, 0x0000, 0xFB40, 0xFB41,
        0x0000, 0xFB43, 0xFB44, 0x0000, 0xFB46, 0xFB47, 0xFB48, 0xFB49, 0xFB4A,
    };
    return switch (b) {
        0x05B4 => if (a == 0x05D9) 0xFB1D else null, // HIRIQ
        0x05B7 => switch (a) { // PATAH
            0x05F2 => 0xFB1F,
            0x05D0 => 0xFB2E,
            else => null,
        },
        0x05B8 => if (a == 0x05D0) 0xFB2F else null, // QAMATS
        0x05B9 => if (a == 0x05D5) 0xFB4B else null, // HOLAM
        0x05BC => switch (a) { // DAGESH
            0x05D0...0x05EA => if (dagesh_forms[a - 0x05D0] != 0) dagesh_forms[a - 0x05D0] else null,
            0xFB2A => 0xFB2C,
            0xFB2B => 0xFB2D,
            else => null,
        },
        0x05BF => switch (a) { // RAFE
            0x05D1 => 0xFB4C,
            0x05DB => 0xFB4D,
            0x05E4 => 0xFB4E,
            else => null,
        },
        0x05C1 => switch (a) { // SHIN DOT
            0x05E9 => 0xFB2A,
            0xFB49 => 0xFB2C,
            else => null,
        },
        0x05C2 => switch (a) { // SIN DOT
            0x05E9 => 0xFB2B,
            0xFB49 => 0xFB2D,
            else => null,
        },
        else => null,
    };
}

/// Ported from output_char: appends a copy of the not-yet-consumed current
/// input glyph to the output (cluster/mask carried over, same as
/// `Buffer.outputGlyph`), stashing `glyph` (the font's mapping for
/// `unicode_codepoint`) in `var1` for `mapGlyphsFast` to pick up later, and
/// leaving `codepoint` set to the decomposed Unicode value.
fn outputChar(buffer: *Buffer, unicode_codepoint: u21, glyph: u32) !void {
    buffer.curPtr(0).var1 = @bitCast(glyph);
    try buffer.outputGlyph(unicode_codepoint);
}

/// Ported from next_char: stashes the resolved glyph id and advances past
/// the current input glyph without decomposing it.
fn nextChar(buffer: *Buffer, glyph: u32) !void {
    buffer.curPtr(0).var1 = @bitCast(glyph);
    try buffer.nextGlyph();
}

/// Ported from decompose(): recursively expands `ab`'s canonical
/// decomposition chain, emitting each resulting character via `outputChar`
/// once it's known final (font supports it, or it has no further
/// decomposition). Returns the number of characters emitted, or 0 if `ab`
/// doesn't decompose into anything the font can render (in which case
/// nothing is emitted and the caller falls back to treating `ab` as a
/// single unit). Unbounded recursion is safe here (unlike GSUB/GPOS lookup
/// nesting): the decomposition chain is fixed Unicode data, not
/// attacker/font-controlled, and UAX #15 guarantees it's finite and short.
fn decomposeChar(ctx: *NormalizeContext, buffer: *Buffer, shortest: bool, ab: u21) (error{OutOfMemory})!usize {
    if (ctx.blocksDecomposition(ab)) return 0;
    const dec = ctx.decompose(ab) orelse return 0;
    const a = dec.first;
    const b = dec.second;
    if (b != 0 and ctx.nominalGlyph(b) == null) return 0;

    const a_glyph = ctx.nominalGlyph(a);
    if (shortest and a_glyph != null) {
        try outputChar(buffer, a, a_glyph.?);
        if (b != 0) {
            try outputChar(buffer, b, ctx.nominalGlyph(b).?);
            return 2;
        }
        return 1;
    }

    const ret = try decomposeChar(ctx, buffer, shortest, a);
    if (ret != 0) {
        if (b != 0) {
            try outputChar(buffer, b, ctx.nominalGlyph(b).?);
            return ret + 1;
        }
        return ret;
    }

    if (a_glyph) |g| {
        try outputChar(buffer, a, g);
        if (b != 0) {
            try outputChar(buffer, b, ctx.nominalGlyph(b).?);
            return 2;
        }
        return 1;
    }

    return 0;
}

/// Ported from decompose_current_character.
fn decomposeCurrentChar(ctx: *NormalizeContext, buffer: *Buffer, shortest: bool) !void {
    const u: u21 = @intCast(buffer.cur(0).codepoint);

    if (shortest) {
        if (ctx.nominalGlyph(u)) |glyph| {
            try nextChar(buffer, glyph);
            return;
        }
    }

    if (try decomposeChar(ctx, buffer, shortest, u) != 0) {
        buffer.skipGlyph();
        return;
    }

    if (!shortest) {
        if (ctx.nominalGlyph(u)) |glyph| {
            try nextChar(buffer, glyph);
            return;
        }
    }

    const space_type = common.spaceFallbackType(u);
    if (space_type != .not_space) {
        if (ctx.nominalGlyph(' ')) |space_glyph| {
            buffer.curPtr(0).space_fallback = space_type;
            try nextChar(buffer, space_glyph);
            return;
        }
    }

    // U+2011 is the only non-space no-break character worth falling back to
    // its breaking counterpart; the space ones are handled just above.
    if (u == 0x2011) {
        if (ctx.nominalGlyph(0x2010)) |hyphen_glyph| {
            try nextChar(buffer, hyphen_glyph);
            return;
        }
    }

    // Font can't render `u` and it has no usable decomposition or fallback;
    // fall through with glyph 0 (.notdef), same as hb's own last resort.
    try nextChar(buffer, 0);
}

fn decomposeMultiCharCluster(ctx: *NormalizeContext, buffer: *Buffer, end: usize, shortest: bool) !void {
    for (buffer.info.items[buffer.idx..end]) |info| {
        if (unicode.isVariationSelector(@intCast(info.codepoint))) return handleVariationSelectorCluster(ctx, buffer, end);
    }
    while (buffer.idx < end) try decomposeCurrentChar(ctx, buffer, shortest);
}

/// Ported from `handle_variation_selector_cluster`: a cluster holding a
/// variation selector is not normalized at all. A base+selector pair the
/// font maps becomes one glyph; otherwise both pass through for GSUB.
fn handleVariationSelectorCluster(ctx: *NormalizeContext, buffer: *Buffer, end: usize) !void {
    while (buffer.idx + 1 < end) {
        const next: u21 = @intCast(buffer.cur(1).codepoint);
        if (!unicode.isVariationSelector(next)) {
            try nextChar(buffer, nominalOrNotdef(ctx, buffer));
            continue;
        }
        const base: u21 = @intCast(buffer.cur(0).codepoint);
        if (ctx.variationGlyph(base, next)) |glyph| {
            buffer.curPtr(0).var1 = @bitCast(glyph);
            try buffer.replaceGlyphs(2, &.{base});
        } else {
            try nextChar(buffer, nominalOrNotdef(ctx, buffer));
            try nextChar(buffer, nominalOrNotdef(ctx, buffer));
        }
        while (buffer.idx < end and unicode.isVariationSelector(@intCast(buffer.cur(0).codepoint))) {
            try nextChar(buffer, nominalOrNotdef(ctx, buffer));
        }
    }
    if (buffer.idx < end) try nextChar(buffer, nominalOrNotdef(ctx, buffer));
}

fn nominalOrNotdef(ctx: *NormalizeContext, buffer: *Buffer) u32 {
    return ctx.nominalGlyph(@intCast(buffer.cur(0).codepoint)) orelse 0;
}

const max_reorder_combining_marks = 32; // HB_OT_SHAPE_MAX_COMBINING_MARKS

/// Ported from _hb_ot_shape_normalize's second (reorder) round: sorts each
/// maximal run of nonzero-combining-class glyphs into combining-class
/// order (UAX #15's canonical ordering), skipping runs long enough that the
/// O(n^2) insertion sort would be a real cost (matches hb's own bailout).
fn normalizeReorderRound(buffer: *Buffer, reorder_marks: ReorderMarks) void {
    const infos = buffer.info.items;
    var i: usize = 0;
    while (i < infos.len) {
        if (combiningClassOf(&infos[i]) == 0) {
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < infos.len and combiningClassOf(&infos[end]) != 0) : (end += 1) {}
        if (end - i > max_reorder_combining_marks) {
            i = end;
            continue;
        }
        buffer.sortByCombiningClass(i, end);
        switch (reorder_marks) {
            .none => {},
            .arabic => reorderMarksArabic(buffer, i, end),
            .hebrew => reorderMarksHebrew(buffer, i, end),
        }
        i = end;
    }
}

fn isModifierCombiningMark(codepoint: u32) bool {
    return switch (codepoint) {
        0x0654, 0x0655, 0x0658, 0x06DC, 0x06E3, 0x06E7, 0x06E8, 0x08CA, 0x08CB, 0x08CD, 0x08CE, 0x08CF, 0x08D3, 0x08F3 => true,
        else => false,
    };
}

/// Ported from `reorder_marks_hebrew`: patah/qamats + sheva/hiriq + meteg/below
/// puts the meteg/below mark before the sheva/hiriq.
fn reorderMarksHebrew(buffer: *Buffer, start: usize, end: usize) void {
    const info = buffer.info.items;
    var i = start + 2;
    while (i < end) : (i += 1) {
        const c0 = combiningClassOf(&info[i - 2]);
        const c1 = combiningClassOf(&info[i - 1]);
        const c2 = combiningClassOf(&info[i]);
        if ((c0 == 20 or c0 == 21) and (c1 == 22 or c1 == 23) and (c2 == 25 or c2 == 220)) {
            buffer.mergeClusters(i - 1, i + 1);
            std.mem.swap(GlyphInfo, &info[i - 1], &info[i]);
            break;
        }
    }
}

/// Ported from `reorder_marks_arabic` (UAX #53): within a sorted mark run,
/// modifier combining marks of class 220/230 move ahead of the other marks.
fn reorderMarksArabic(buffer: *Buffer, run_start: usize, end: usize) void {
    const info = buffer.info.items;
    var start = run_start;
    var i = start;
    for ([_]u8{ 220, 230 }) |class| {
        while (i < end and combiningClassOf(&info[i]) < class) i += 1;
        if (i == end) break;
        if (combiningClassOf(&info[i]) > class) continue;
        var j = i;
        while (j < end and combiningClassOf(&info[j]) == class and isModifierCombiningMark(info[j].codepoint)) j += 1;
        if (i == j) continue;

        buffer.mergeClusters(start, j);
        std.mem.rotate(GlyphInfo, info[start..j], i - start);
        const new_start = start + j - i;
        while (start < new_start) : (start += 1) info[start].arabic_mcm_moved = true;
        i = j;
    }
}

/// Ported from _hb_ot_shape_normalize's third (recompose) round: walks
/// left to right, trying to canonically compose each mark onto the most
/// recent starter (ccc=0 glyph) unless something with a lower-or-equal
/// combining class already sits between them (Unicode's "blocked" rule).
fn normalizeRecomposeRound(ctx: *NormalizeContext, buffer: *Buffer, block_mark_recompose: bool) !void {
    buffer.clearOutput();
    const count = buffer.info.items.len;
    var starter: usize = 0;
    try buffer.nextGlyph();
    while (buffer.idx < count) {
        const cur_codepoint: u21 = @intCast(buffer.cur(0).codepoint);
        const cur_cc = combiningClassOf(buffer.curPtr(0));

        compose_check: {
            if (!unicode.isUnicodeMark(cur_codepoint)) break :compose_check;
            const out_len = buffer.outLen();
            const prev_cc = combiningClassOf(&buffer.outItems()[out_len - 1]);
            if (!(starter == out_len - 1 or prev_cc < cur_cc)) break :compose_check;
            const starter_codepoint: u21 = @intCast(buffer.outItems()[starter].codepoint);
            if (block_mark_recompose and unicode.isUnicodeMark(starter_codepoint)) break :compose_check;
            const composed = ctx.compose(starter_codepoint, cur_codepoint) orelse break :compose_check;
            const glyph = ctx.nominalGlyph(composed) orelse break :compose_check;

            try buffer.nextGlyph(); // Copy cur to out-buffer.
            buffer.mergeOutClusters(starter, buffer.outLen());
            buffer.outShrink(buffer.outLen() - 1);
            buffer.outItems()[starter].codepoint = composed;
            buffer.outItems()[starter].var1 = @bitCast(glyph);
            continue;
        }

        try buffer.nextGlyph();
        if (combiningClassOf(&buffer.outItems()[buffer.outLen() - 1]) == 0) {
            starter = buffer.outLen() - 1;
        }
    }
    try buffer.sync();
}

/// Top-level entry point, ported from _hb_ot_shape_normalize. Runs the
/// decompose round inline (rather than as a separate function like hb's,
/// since Zig has no equivalent of hb's batched `get_nominal_glyphs` call -
/// ported here as an unrolled per-glyph loop) followed by reorder and
/// recompose.
///
/// `mode` is the shaper's `normalization_preference`. Indic/Khmer/Myanmar/
/// USE ask for `composed_diacritics_no_short_circuit` so a composed
/// character the font also covers still decomposes (split matras must reach
/// the syllable machine in parts); Hangul asks for `none` (no recompose).
///
/// `block_mark_recompose` ports hb's per-shaper `compose` override
/// (`compose_indic`/`compose_khmer`/`compose_use` in the matching
/// `hb-ot-shaper-*.cc` - Myanmar has no override, so its caller passes
/// `false`): those three refuse to recompose a mark back onto another mark
/// ("avoid recomposing split matras" in hb's own comment), since a
/// multi-part vowel sign's decomposed form is what their syllable
/// reordering/dotted-circle logic needs to see. Without this gate the
/// generic recompose round above silently undoes `decomposeCurrentChar`'s
/// split the moment it runs, which is a real bug this port had until the
/// dotted-circle work surfaced it (a still-composed split matra can never
/// classify as a broken syllable).
pub const Mode = enum { none, composed_diacritics, composed_diacritics_no_short_circuit };
pub const ReorderMarks = enum { none, arabic, hebrew };

pub fn normalize(buffer: *Buffer, cmap: ?Cmap, mode: Mode, block_mark_recompose: bool, decompose_override: DecomposeOverride, reorder_marks: ReorderMarks, hebrew_presentation_forms: bool) !void {
    if (buffer.info.items.len == 0) return;
    const always_short_circuit = mode == .none;
    const might_short_circuit = mode != .composed_diacritics_no_short_circuit;
    var ctx_storage = NormalizeContext{ .cmap = cmap, .decompose_override = decompose_override, .hebrew_presentation_forms = hebrew_presentation_forms };
    const ctx = &ctx_storage;

    var all_simple = true;
    buffer.clearOutput();
    const count = buffer.info.items.len;
    buffer.idx = 0;
    while (buffer.idx < count) {
        var end = buffer.idx + 1;
        while (end < count) : (end += 1) {
            if (unicode.isUnicodeMark(@intCast(buffer.info.items[end].codepoint))) break;
        }
        if (end < count) end -= 1; // Leave one base for the marks to cluster with.

        if (might_short_circuit) {
            // Fast path: map directly via cmap while it keeps succeeding.
            while (buffer.idx < end) {
                const cp: u21 = @intCast(buffer.cur(0).codepoint);
                const glyph = ctx.nominalGlyph(cp) orelse break;
                try nextChar(buffer, glyph);
            }
        }
        while (buffer.idx < end) try decomposeCurrentChar(ctx, buffer, might_short_circuit);

        if (buffer.idx == count) break;
        all_simple = false;

        var mark_end = buffer.idx + 1;
        while (mark_end < count) : (mark_end += 1) {
            if (!unicode.isUnicodeMark(@intCast(buffer.info.items[mark_end].codepoint))) break;
        }
        try decomposeMultiCharCluster(ctx, buffer, mark_end, always_short_circuit);
    }
    try buffer.sync();

    if (!all_simple) normalizeReorderRound(buffer, reorder_marks);
    hideBlockingCgjs(buffer);
    if (all_simple) return;
    if (mode != .none) try normalizeRecomposeRound(ctx, buffer, block_mark_recompose);
}

/// Ported from `hb_set_unicode_props` + `hb_form_clusters`: every codepoint
/// hb considers a grapheme *continuation* is folded into the cluster of the
/// character it extends, so a whole emoji sequence (base, skin-tone
/// modifier, ZWJ-joined parts) reports one cluster instead of one per
/// codepoint.
///
/// This is deliberately not UAX #29 - hb implements "enough of Unicode
/// Graphemes" that reverse-direction shaping cannot split one, and nothing
/// more, so Hangul syllables and prepend sequences are left alone.
/// `unicode.GraphemeBreakIterator` is the full algorithm and would merge
/// strictly more than hb does. Runs before `normalize`, matching hb's
/// order, so decompositions inherit the already-merged cluster.
pub fn formClusters(buffer: *Buffer) void {
    const infos = buffer.info.items;
    var start: usize = 0;
    var prev_continuation = false;
    var i: usize = 1;
    while (i <= infos.len) : (i += 1) {
        const continuation = i < infos.len and isGraphemeContinuation(infos, i, prev_continuation);
        if (!continuation) {
            buffer.mergeGraphemeClusters(start, i);
            start = i;
        }
        prev_continuation = continuation;
    }
}

fn isRegionalIndicator(cp: u32) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// `prev_continuation` is whether `infos[i - 1]` itself continued something,
/// which only the regional-indicator rule needs: flags pair up two at a
/// time, so the second of a run joins the first but the third starts a new
/// one.
fn isGraphemeContinuation(infos: []const GlyphInfo, i: usize, prev_continuation: bool) bool {
    const cp = infos[i].codepoint;
    if (cp < 0x80) return false;
    // Any mark, default-ignorable ones (VS15/VS16) included - hb sets this
    // bit alongside the ignorable bit, not instead of it.
    if (unicode.isUnicodeMark(@intCast(cp))) return true;
    // Emoji_Modifier, i.e. the five skin tones.
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return true;
    if (isRegionalIndicator(cp)) return isRegionalIndicator(infos[i - 1].codepoint) and !prev_continuation;
    if (cp == 0x200D) return true;
    if (infos[i - 1].codepoint == 0x200D and
        unicode.GraphemeClusterBreak.of(@intCast(cp)) == .extended_pictographic) return true;
    // The Other_Grapheme_Extend characters that are not marks and that hb
    // chose to merge: halfwidth katakana sound marks, and the tag
    // characters that spell out sub-region flags. ZWNJ is left out on
    // purpose - keeping it separate gives more granular clusters.
    return (cp >= 0xFF9E and cp <= 0xFF9F) or (cp >= 0xE0020 and cp <= 0xE007F);
}

/// Ported from hb_set_unicode_props's ignorable half. Must run after `normalize` (which may
/// insert/reorder/delete glyphs) and before `mapGlyphsFast` overwrites
/// `codepoint` with a glyph id.
pub fn setJoinerFlags(buffer: *Buffer) void {
    for (buffer.info.items) |*info| {
        const cp = info.codepoint;
        info.is_zwj = cp == 0x200D;
        info.is_zwnj = cp == 0x200C;
        info.is_default_ignorable = unicode.isDefaultIgnorable(@intCast(cp));
        // A CGJ's hidden bit was already decided by `hideBlockingCgjs`.
        if (cp != 0x034F) info.is_hidden = (cp >= 0x180B and cp <= 0x180D) or cp == 0x180F or (cp >= 0xE0020 and cp <= 0xE007F);
    }
}

/// hb's post-reorder CGJ check: a CGJ that actually kept marks from
/// reordering across it stays hidden (unskippable); any other is skippable.
fn hideBlockingCgjs(buffer: *Buffer) void {
    const infos = buffer.info.items;
    for (infos, 0..) |*info, i| {
        if (info.codepoint != 0x034F) continue;
        const skippable = i > 0 and i + 1 < infos.len and
            (combiningClassOf(&infos[i + 1]) == 0 or combiningClassOf(&infos[i - 1]) <= combiningClassOf(&infos[i + 1]));
        info.is_hidden = !skippable;
    }
}

/// Ported from hb_ot_map_glyphs_fast: normalize() stashed each glyph's
/// resolved font glyph id in `var1` (see GlyphInfo's doc comment) while
/// `codepoint` still held the Unicode value for is_unicode_mark/
/// combining-class lookups; this is the point where `codepoint` becomes
/// the real glyph id GSUB/GPOS operate on.
pub fn mapGlyphsFast(buffer: *Buffer) void {
    for (buffer.info.items) |*info| info.codepoint = @bitCast(info.var1);
}
