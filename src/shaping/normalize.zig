const parsing = @import("../parsing.zig");
const unicode = @import("../unicode.zig");
const common = @import("common.zig");
const Buffer = common.Buffer;
const GlyphInfo = common.GlyphInfo;
const combiningClassOf = common.combiningClassOf;

const NormalizeContext = struct {
    cmap_data: ?[]const u8,

    fn nominalGlyph(self: NormalizeContext, codepoint: u21) ?u32 {
        const data = self.cmap_data orelse return null;
        const glyph = parsing.Table.cmap.lookup(data, codepoint) orelse return null;
        return glyph;
    }
};

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
fn decomposeChar(ctx: NormalizeContext, buffer: *Buffer, shortest: bool, ab: u21) (error{OutOfMemory})!usize {
    const dec = unicode.decomposeCanonical(ab) orelse return 0;
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

/// Ported from decompose_current_character. `shortest` false is only ever
/// used by `decomposeMultiCharCluster` (mirroring hb's
/// `always_short_circuit`, always false in this port's scope per the
/// section doc comment above) - kept as a parameter anyway to keep this a
/// faithful, easy-to-diff port rather than collapsing it prematurely.
fn decomposeCurrentChar(ctx: NormalizeContext, buffer: *Buffer, shortest: bool) !void {
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

    // Font can't render `u` and it has no usable decomposition; no
    // space-fallback/U+2011 fallback (see section doc comment) - fall
    // through with glyph 0 (.notdef), same as hb's own last resort here.
    try nextChar(buffer, 0);
}

fn decomposeMultiCharCluster(ctx: NormalizeContext, buffer: *Buffer, end: usize, shortest: bool) !void {
    while (buffer.idx < end) try decomposeCurrentChar(ctx, buffer, shortest);
}

const max_reorder_combining_marks = 32; // HB_OT_SHAPE_MAX_COMBINING_MARKS

/// Ported from _hb_ot_shape_normalize's second (reorder) round: sorts each
/// maximal run of nonzero-combining-class glyphs into combining-class
/// order (UAX #15's canonical ordering), skipping runs long enough that the
/// O(n^2) insertion sort would be a real cost (matches hb's own bailout).
fn normalizeReorderRound(buffer: *Buffer) void {
    const infos = buffer.info.items;
    var i: usize = 0;
    while (i < infos.len) {
        if (combiningClassOf(infos[i]) == 0) {
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < infos.len and combiningClassOf(infos[end]) != 0) : (end += 1) {}
        if (end - i > max_reorder_combining_marks) {
            i = end;
            continue;
        }
        buffer.sortByCombiningClass(i, end);
        i = end;
    }
}

/// Ported from _hb_ot_shape_normalize's third (recompose) round: walks
/// left to right, trying to canonically compose each mark onto the most
/// recent starter (ccc=0 glyph) unless something with a lower-or-equal
/// combining class already sits between them (Unicode's "blocked" rule).
fn normalizeRecomposeRound(ctx: NormalizeContext, buffer: *Buffer, block_mark_recompose: bool) !void {
    buffer.clearOutput();
    const count = buffer.info.items.len;
    var starter: usize = 0;
    try buffer.nextGlyph();
    while (buffer.idx < count) {
        const cur_codepoint: u21 = @intCast(buffer.cur(0).codepoint);
        const cur_cc = unicode.combiningClass(cur_codepoint);

        compose_check: {
            if (!unicode.isUnicodeMark(cur_codepoint)) break :compose_check;
            const out_len = buffer.out_info.items.len;
            const prev_cc = unicode.combiningClass(@intCast(buffer.out_info.items[out_len - 1].codepoint));
            if (!(starter == out_len - 1 or prev_cc < cur_cc)) break :compose_check;
            const starter_codepoint: u21 = @intCast(buffer.out_info.items[starter].codepoint);
            if (block_mark_recompose and unicode.isUnicodeMark(starter_codepoint)) break :compose_check;
            const composed = unicode.composeCanonical(starter_codepoint, cur_codepoint) orelse break :compose_check;
            const glyph = ctx.nominalGlyph(composed) orelse break :compose_check;

            try buffer.nextGlyph(); // Copy cur to out-buffer.
            buffer.mergeOutClusters(starter, buffer.out_info.items.len);
            buffer.out_info.shrinkRetainingCapacity(buffer.out_info.items.len - 1);
            buffer.out_info.items[starter].codepoint = composed;
            buffer.out_info.items[starter].var1 = @bitCast(glyph);
            continue;
        }

        try buffer.nextGlyph();
        if (unicode.combiningClass(@intCast(buffer.out_info.items[buffer.out_info.items.len - 1].codepoint)) == 0) {
            starter = buffer.out_info.items.len - 1;
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
/// `might_short_circuit` mirrors hb's `might_short_circuit` local in
/// `_hb_ot_shape_normalize`: true for `HB_OT_SHAPE_NORMALIZATION_MODE_
/// COMPOSED_DIACRITICS`/`DEFAULT`/`NONE` (the fast cmap-first path is safe -
/// composed input is preferred whenever the font supports it directly), but
/// false for `COMPOSED_DIACRITICS_NO_SHORT_CIRCUIT`, which the Indic/Khmer/
/// Myanmar/USE complex shapers request (see their `normalization_preference`
/// in the matching `hb-ot-shaper-*.cc`) specifically so a composed character
/// that also has a cmap entry still gets canonically decomposed - those
/// shapers need the decomposed sequence (e.g. a split vowel matra's
/// left+right parts) as separate glyphs to reorder/mask, even when the font
/// additionally happens to have a precomposed glyph for the whole thing.
/// Skipping this per-script distinction (previously always true here) was a
/// concrete bug: it fed the wrong, non-decomposed cluster into these
/// shapers' syllable reordering. Callers pass `false` for those scripts,
/// `true` otherwise.
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
/// classify as a broken syllable). The one indic-specific hardcoded
/// exception (`0x09AF+0x09BC -> 0x09DF`) hb recomposes anyway isn't ported -
/// narrow enough to defer.
pub fn normalize(buffer: *Buffer, cmap_data: ?[]const u8, might_short_circuit: bool, block_mark_recompose: bool) !void {
    if (buffer.info.items.len == 0) return;
    const ctx = NormalizeContext{ .cmap_data = cmap_data };

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
        try decomposeMultiCharCluster(ctx, buffer, mark_end, might_short_circuit);
    }
    try buffer.sync();

    if (all_simple) return;

    normalizeReorderRound(buffer);
    try normalizeRecomposeRound(ctx, buffer, block_mark_recompose);
}

/// Ported from hb_set_unicode_props's ZWJ/ZWNJ half (the rest of that
/// function - grapheme-continuation tracking - is out of scope, see this
/// section's top doc comment). Must run after `normalize` (which may
/// insert/reorder/delete glyphs) and before `mapGlyphsFast` overwrites
/// `codepoint` with a glyph id.
pub fn setJoinerFlags(buffer: *Buffer) void {
    for (buffer.info.items) |*info| {
        info.is_zwj = info.codepoint == 0x200D;
        info.is_zwnj = info.codepoint == 0x200C;
        info.is_default_ignorable = unicode.isDefaultIgnorable(@intCast(info.codepoint));
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
