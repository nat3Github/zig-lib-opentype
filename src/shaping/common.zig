// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const parsing = @import("../parsing.zig");
const unicode = @import("../unicode.zig");

// Ported from vendor/harfbuzz/src/hb-buffer.hh + hb-buffer.cc (pinned
// 703e2d1441), including the info/out_info aliasing: while the output is
// still a prefix of the input (`out_split` false), `nextGlyph` copies
// nothing and in-place substitutions write straight into `info`. Only an
// output that would overrun unread input splits the two apart
// (`makeRoomFor`, hb's `make_room_for`). Everything else - cluster merge
// semantics, glyph-flag propagation, max_ops budget - is ported as-is since
// that's where the actual shaping correctness lives.

pub const glyph_flag_unsafe_to_break: u32 = 0x1;
pub const glyph_flag_unsafe_to_concat: u32 = 0x2;
pub const glyph_flag_safe_to_insert_tatweel: u32 = 0x4;
pub const glyph_flag_defined: u32 = 0x7;

// `std.mem.sort` (WikiSort) monomorphizes to ~15KiB per (T, lessThan) pair
// and is tuned for large arrays; every call site using this sorts a
// short-lived list of a few dozen entries at most, where insertion sort is
// both smaller and measurably faster.
pub fn insertionSort(comptime T: type, items: []T, context: anytype, comptime lessThan: fn (@TypeOf(context), T, T) bool) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j: usize = i;
        while (j > 0 and lessThan(context, key, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

comptime { std.debug.assert(@sizeOf(GlyphInfo) == 48); }

pub const GlyphInfo = struct {
    /// Unicode codepoint before shaping, glyph index after shaping.
    codepoint: u32 = 0,
    /// Low bits (glyph_flag_*) plus shaper-assigned feature-lookup mask bits.
    mask: u32 = 0,
    cluster: u32 = 0,
    /// The normalizer's `normalizer_glyph_index` scratch slot: the font's
    /// mapping for `codepoint` while that still holds a Unicode value (see
    /// `outputChar`/`nextChar`/`mapGlyphsFast`).
    var1: i32 = 0,
    /// hb's `lig_props`, unpacked. A LigatureSubst that fires stamps the
    /// ligature and every mark it swallowed with one fresh `lig_id`, gives
    /// the ligature its component count and each mark the 1-based component
    /// it belongs to; GPOS's MarkToLigature then attaches a mark to *that*
    /// component rather than always the last, and MarkToMark only stacks
    /// two marks sitting on the same component. Zero `lig_id` means "not
    /// part of a ligature", which is also hb's "ids don't match" fallback.
    lig_id: u8 = 0,
    /// 1-based component index, marks only; 0 on a ligature base.
    lig_comp: u8 = 0,
    /// Components a ligature base swallowed; 1 for everything else.
    lig_num_comps: u8 = 1,
    /// Set once by `setJoinerFlags` from the original Unicode codepoint
    /// (0x200D/0x200C), before `codepoint` is overwritten with a glyph id -
    /// see `shouldSkipGlyph`.
    is_zwj: bool = false,
    is_zwnj: bool = false,
    /// Set once by `setJoinerFlags` from the original Unicode codepoint
    /// (`unicode.isDefaultIgnorable`) - consumed post-GSUB by
    /// `hideDefaultIgnorables` to zero out any Default_Ignorable_Code_Point
    /// glyph the font didn't otherwise substitute away.
    is_default_ignorable: bool = false,
    /// hb's UPROPS_MASK_HIDDEN: a default ignorable (CGJ, Mongolian FVS, tag
    /// characters) GSUB matching must not step over.
    is_hidden: bool = false,
    /// Hangul complex shaper: which jamo-position feature (ljmo/vjmo/tjmo,
    /// see `HangulJmo`) this glyph belongs to after `preprocessHangul`'s
    /// syllable decompose, 0 meaning none/not applicable.
    hangul_feature: u8 = 0,
    /// Arabic complex shaper: which positional-form feature (isol/fina/...,
    /// see `ArabicAction`) `arabicJoining` assigned this glyph, defaulting
    /// to `.none` (no positional substitution) for non-joining glyphs.
    arabic_shaping_action: u8 = @intFromEnum(ArabicAction.none),
    /// Indic complex shaper: category/position/syllable-id `setIndicProperties`/
    /// `findSyllablesIndic` assign per glyph before `reorderIndicSyllable`
    /// consumes them - see that section's doc comment. Also reused verbatim
    /// by the Khmer/Myanmar shapers below (`setupMasksKhmer`/`setupMasksMyanmar`)
    /// - this mirrors hb itself, which aliases the exact same buffer-var slots
    /// (`ot_shaper_var_u8_category`/`_auxiliary`) across Indic/Khmer/Myanmar
    /// since only one complex shaper runs per buffer.
    indic_category: u8 = 0,
    indic_position: u8 = 0,
    indic_syllable: u8 = 0,
    /// hb's `glyph_props` SUBSTITUTED/LIGATED/MULTIPLIED bits, set by the
    /// GSUB lookups that produce a glyph. The Indic shaper's final
    /// reordering reads them to tell a reph/pref candidate that actually
    /// ligated from one the font declined to substitute.
    is_substituted: bool = false,
    is_ligated: bool = false,
    is_multiplied: bool = false,
    /// Set by the normalizer when the font had no glyph for a Unicode space
    /// character and it substituted the plain space glyph instead; read back
    /// after default positioning to widen/narrow that borrowed advance.
    space_fallback: SpaceFallback = .not_space,
    /// Set by `reorderMarksArabic` on a modifier combining mark it moved to
    /// the front: its class reads as hb's CCC22/CCC26 so the sequence stays
    /// sorted.
    arabic_mcm_moved: bool = false,
    /// Arabic shaper: the source codepoint's General_Category is in hb's
    /// "word" set, which bounds a 'stch' stretch.
    is_arabic_word: bool = false,
    /// hb's cached `glyph_props`: GDEF GlyphClassDef and MarkAttachClassDef
    /// of `gdef_class_glyph`. Valid only while that still equals `codepoint`;
    /// anything else falls back to the ClassDef lookups, so a stale entry is
    /// never wrong.
    gdef_class_glyph: u32 = std.math.maxInt(u32),
    gdef_class: u8 = 0,
    gdef_mark_attach_class: u8 = 0,
    /// hb's `unicode_props` combining class, cached the same way: the raw
    /// `modifiedCombiningClass` of `ccc_codepoint` (the mcm adjustment is
    /// applied on read, so moving a mark doesn't invalidate it). Stale
    /// entries fall back to the table lookup, never to a wrong answer.
    ccc_codepoint: u32 = std.math.maxInt(u32),
    ccc: u8 = 0,
};

/// hb-unicode.hh's `space_t`. The `em_*` values double as the divisor of an
/// em that the space is worth, which is why they are numbered rather than
/// sequential.
pub const SpaceFallback = enum(u8) {
    not_space = 0,
    em = 1,
    em_2 = 2,
    em_3 = 3,
    em_4 = 4,
    em_5 = 5,
    em_6 = 6,
    em_16 = 16,
    four_em_18 = 17,
    space = 18,
    figure = 19,
    punctuation = 20,
    narrow = 21,
};

/// Ported from hb-unicode.hh's `space_fallback_type`: every GC=Zs codepoint
/// that has a sensible fallback width. U+1680 OGHAM SPACE MARK is absent on
/// purpose - it is a visible mark, not blank space.
pub fn spaceFallbackType(codepoint: u21) SpaceFallback {
    return switch (codepoint) {
        0x0020, 0x00A0 => .space,
        0x2000, 0x2002 => .em_2,
        0x2001, 0x2003, 0x3000 => .em,
        0x2004 => .em_3,
        0x2005 => .em_4,
        0x2006 => .em_6,
        0x2007 => .figure,
        0x2008 => .punctuation,
        0x2009 => .em_5,
        0x200A => .em_16,
        0x202F => .narrow,
        0x205F => .four_em_18,
        else => .not_space,
    };
}

/// Same order as hb-ot-shaper-arabic.cc's `arabic_features`/`arabic_action_t`.
pub const ArabicAction = enum(u8) { isol, fina, fin2, fin3, medi, med2, init, none, stch_fixed, stch_repeating };

pub const GlyphPosition = struct {
    x_advance: i32 = 0,
    y_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    /// Mark/cursive attachment link to another glyph in the same buffer,
    /// relative offset (negative = backward). 0 means unattached; see
    /// `attach_type` for which kind when nonzero.
    attach_chain: i16 = 0,
    attach_type: u8 = attach_type_none,
};

pub const attach_type_none: u8 = 0x00;
pub const attach_type_mark: u8 = 0x01;
pub const attach_type_cursive: u8 = 0x02;

pub const Direction = enum { left_to_right, right_to_left, top_to_bottom, bottom_to_top };

pub const ClusterLevel = enum {
    monotone_graphemes,
    monotone_characters,
    characters,
    graphemes,

    pub fn isMonotone(self: ClusterLevel) bool {
        return self == .monotone_graphemes or self == .monotone_characters;
    }

    pub fn isGraphemes(self: ClusterLevel) bool {
        return self == .monotone_graphemes or self == .graphemes;
    }
};

fn setCluster(glyph_info: *GlyphInfo, cluster: u32, mask: u32) void {
    if (glyph_info.cluster != cluster) {
        glyph_info.mask = (glyph_info.mask & ~glyph_flag_defined) | (mask & glyph_flag_defined);
    }
    glyph_info.cluster = cluster;
}

fn clusterGroupFunc(a: GlyphInfo, b: GlyphInfo) bool {
    return a.cluster == b.cluster;
}

/// Ported from vendor/harfbuzz/src/hb-set-digest.hh: three bits-pattern
/// filters over glyph ids, ANDed together to answer "might this set contain
/// g?". Approximate on the positive side only -- a false positive costs a
/// wasted lookup walk, a false negative would silently drop a substitution,
/// so every path that puts a glyph into a buffer has to `add` it.
pub const Digest = struct {
    masks: [n]u64 = @splat(0),

    const shifts = [_]u5{ 4, 0, 6 };
    const n = shifts.len;
    const mb1: u32 = 63;

    pub fn add(self: *Digest, glyph: u32) void {
        inline for (shifts, 0..) |shift, i| {
            self.masks[i] |= @as(u64, 1) << @intCast((glyph >> shift) & mb1);
        }
    }

    pub fn addRange(self: *Digest, first: u32, last: u32) void {
        inline for (shifts, 0..) |shift, i| {
            if ((last >> shift) - (first >> shift) >= mb1) {
                self.masks[i] = std.math.maxInt(u64);
            } else {
                const ma = @as(u64, 1) << @intCast((first >> shift) & mb1);
                const mb = @as(u64, 1) << @intCast((last >> shift) & mb1);
                self.masks[i] |= mb +% (mb -% ma) -% @intFromBool(mb < ma);
            }
        }
    }

    pub fn unionWith(self: *Digest, other: Digest) void {
        inline for (0..n) |i| self.masks[i] |= other.masks[i];
    }

    pub fn mayHave(self: Digest, glyph: u32) bool {
        inline for (shifts, 0..) |shift, i| {
            if (self.masks[i] & (@as(u64, 1) << @intCast((glyph >> shift) & mb1)) == 0) return false;
        }
        return true;
    }

    pub fn mayIntersect(self: Digest, other: Digest) bool {
        inline for (0..n) |i| {
            if (self.masks[i] & other.masks[i] == 0) return false;
        }
        return true;
    }

    pub fn clear(self: *Digest) void {
        self.masks = @splat(0);
    }

    /// Matches everything -- the safe answer whenever a lookup's coverage
    /// could not be read, so a malformed table degrades to "no filtering"
    /// instead of dropping lookups.
    pub fn full() Digest {
        return .{ .masks = @splat(std.math.maxInt(u64)) };
    }
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    /// Glyph ids currently in `info`/`out_info`; ANDed against a lookup's own
    /// digest to skip lookups that cannot match anything in this run.
    digest: Digest = .{},
    info: std.ArrayList(GlyphInfo) = .empty,
    /// Backing store for the output half only once it has split from
    /// `info`; read it through `outItems()`, never directly.
    out_info: std.ArrayList(GlyphInfo) = .empty,
    /// Glyphs committed to the output half of this pass.
    out_len: usize = 0,
    /// False while the output is still `info[0..out_len]` written in place.
    out_split: bool = false,
    pos: std.ArrayList(GlyphPosition) = .empty,
    /// Cursor into `info` (backtrack side when have_output is set).
    idx: usize = 0,
    have_output: bool = false,
    have_positions: bool = false,
    cluster_level: ClusterLevel = .monotone_graphemes,
    /// Operation budget consumed by cluster/flag-propagation work, mirroring
    /// hb's max_ops guard against O(n^2)-ish blowup on adversarial buffers.
    max_ops: i64 = std.math.maxInt(i64),
    successful: bool = true,
    /// hb's `random_state`: the minstd_rand stream the 'rand' feature draws
    /// alternates from. Seeded like hb so a buffer shapes identically.
    random_state: u32 = 1,
    /// Rolling source of `GlyphInfo.lig_id`s (hb's `_hb_allocate_lig_id`).
    /// Wraps within 1..7 like hb's 3-bit field; a collision only costs a
    /// mark the component disambiguation it would otherwise have got.
    lig_serial: u8 = 0,

    pub fn randomNumber(self: *Buffer) u32 {
        self.random_state = @intCast(@as(u64, self.random_state) * 48271 % 2147483647);
        return self.random_state;
    }

    pub fn allocateLigId(self: *Buffer) u8 {
        self.lig_serial = self.lig_serial % 7 + 1;
        return self.lig_serial;
    }

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.info.deinit(self.allocator);
        self.out_info.deinit(self.allocator);
        self.pos.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: Buffer) usize {
        return self.info.items.len;
    }

    pub fn outLen(self: Buffer) usize {
        return self.out_len;
    }

    /// The output half of an in-progress pass, wherever it currently lives.
    pub fn outItems(self: *Buffer) []GlyphInfo {
        return if (self.out_split) self.out_info.items else self.info.items[0..self.out_len];
    }

    /// hb's `make_room_for`: an output that would overrun input not yet read
    /// can no longer share `info`, so copy what is committed into `out_info`
    /// and run split from here to the end of the pass.
    fn makeRoomFor(self: *Buffer, num_in: usize, num_out: usize) !void {
        if (self.out_split or self.out_len + num_out <= self.idx + num_in) return;
        try self.unsplitToSplit();
    }

    fn unsplitToSplit(self: *Buffer) !void {
        if (self.out_split) return;
        self.out_info.clearRetainingCapacity();
        try self.out_info.appendSlice(self.allocator, self.info.items[0..self.out_len]);
        self.out_split = true;
    }

    /// Appends one glyph to the output half. The caller must have reserved
    /// room with `makeRoomFor` first, so the unsplit write is in bounds.
    fn outAppend(self: *Buffer, glyph_info: GlyphInfo) !void {
        if (self.out_split) {
            try self.out_info.append(self.allocator, glyph_info);
        } else {
            self.info.items[self.out_len] = glyph_info;
        }
        self.out_len += 1;
    }

    pub fn outShrink(self: *Buffer, new_len: usize) void {
        if (self.out_split) self.out_info.shrinkRetainingCapacity(new_len);
        self.out_len = new_len;
    }

    /// Ported from hb_buffer_t::backtrack_len(): during a GSUB pass
    /// (`have_output`), already-committed output lives in `out_info`; GPOS
    /// never splits the buffer, so its backtrack is just everything before
    /// `idx` in `info`.
    pub fn backtrackLen(self: Buffer) usize {
        return if (self.have_output) self.outLen() else self.idx;
    }

    /// Ported from hb_buffer_t::lookahead_len(): unconsumed input remaining
    /// from `idx` onward, valid for both GSUB and GPOS passes.
    pub fn lookaheadLen(self: Buffer) usize {
        return self.len() - self.idx;
    }

    pub fn cur(self: Buffer, i: usize) GlyphInfo {
        return self.info.items[self.idx + i];
    }

    pub fn curPtr(self: *Buffer, i: usize) *GlyphInfo {
        return &self.info.items[self.idx + i];
    }

    pub fn curPos(self: *Buffer, i: usize) *GlyphPosition {
        return &self.pos.items[self.idx + i];
    }

    /// Absolute (not idx-relative) position access, needed by mark/cursive
    /// attachment lookups that reach back to an earlier glyph in the buffer.
    pub fn posAt(self: *Buffer, absolute_index: usize) *GlyphPosition {
        return &self.pos.items[absolute_index];
    }

    fn prevInfo(self: *Buffer) GlyphInfo {
        const out = self.outItems();
        return if (out.len > 0) out[out.len - 1] else GlyphInfo{};
    }

    pub fn add(self: *Buffer, codepoint: u32, cluster: u32) !void {
        try self.info.append(self.allocator, .{ .codepoint = codepoint, .cluster = cluster });
    }

    pub fn addInfo(self: *Buffer, glyph_info: GlyphInfo) !void {
        try self.info.append(self.allocator, glyph_info);
    }

    /// Consumes num_in glyphs at idx, appending one output glyph per entry
    /// in glyph_ids (all sharing the consumed glyphs' merged cluster/mask).
    pub fn replaceGlyphs(self: *Buffer, num_in: usize, glyph_ids: []const u32) !void {
        self.mergeClusters(self.idx, self.idx + num_in);

        const orig_info = if (self.idx < self.info.items.len) self.cur(0) else self.prevInfo();

        try self.makeRoomFor(num_in, glyph_ids.len);
        for (glyph_ids) |gid| {
            var glyph_info = orig_info;
            glyph_info.codepoint = gid;
            try self.outAppend(glyph_info);
            self.digest.add(gid);
        }

        self.idx += num_in;
    }

    pub fn replaceGlyph(self: *Buffer, glyph_id: u32) !void {
        try self.replaceGlyphs(1, &.{glyph_id});
    }

    /// Copies the glyph at idx to output under a new glyph id, without
    /// consuming it (idx unchanged).
    pub fn outputGlyph(self: *Buffer, glyph_id: u32) !void {
        try self.replaceGlyphs(0, &.{glyph_id});
    }

    pub fn outputInfo(self: *Buffer, glyph_info: GlyphInfo) !void {
        try self.makeRoomFor(0, 1);
        try self.outAppend(glyph_info);
        self.digest.add(glyph_info.codepoint);
    }

    /// Rebuilds `digest` from the glyphs the buffer currently holds -- hb's
    /// `hb_buffer_t::update_digest`, called at the start of each GSUB/GPOS
    /// pass so stages that rewrite `codepoint` in place (glyph mapping, Thai
    /// PUA shaping, composition, ignorable hiding) are accounted for.
    pub fn updateDigest(self: *Buffer) void {
        self.digest.clear();
        for (self.info.items) |glyph_info| self.digest.add(glyph_info.codepoint);
        for (self.outItems()) |glyph_info| self.digest.add(glyph_info.codepoint);
    }

    /// Copies the glyph at idx to output without advancing idx.
    pub fn copyGlyph(self: *Buffer) !void {
        try self.outputInfo(self.cur(0));
    }

    /// Copies the glyph at idx to output (if have_output) and advances idx.
    pub fn nextGlyph(self: *Buffer) !void {
        if (self.have_output) {
            if (self.out_split) {
                try self.out_info.append(self.allocator, self.info.items[self.idx]);
            } else if (self.out_len != self.idx) {
                self.info.items[self.out_len] = self.info.items[self.idx];
            }
            self.out_len += 1;
        }
        self.idx += 1;
    }

    /// Copies n glyphs at idx to output (if have_output) and advances idx.
    pub fn nextGlyphs(self: *Buffer, n: usize) !void {
        if (self.have_output) {
            if (self.out_split) {
                try self.out_info.appendSlice(self.allocator, self.info.items[self.idx..][0..n]);
            } else if (self.out_len != self.idx) {
                std.mem.copyForwards(GlyphInfo, self.info.items[self.out_len..][0..n], self.info.items[self.idx..][0..n]);
            }
            self.out_len += n;
        }
        self.idx += n;
    }

    /// Advances idx without copying to output.
    pub fn skipGlyph(self: *Buffer) void {
        self.idx += 1;
    }

    /// Ported from hb_buffer_t::delete_glyph: drops the glyph at idx without
    /// emitting it, first folding its cluster into a neighbour so the
    /// cluster itself doesn't vanish from the output.
    pub fn deleteGlyph(self: *Buffer) void {
        const cluster = self.info.items[self.idx].cluster;
        const out = self.outItems();
        const out_len = out.len;
        const cluster_survives = (self.idx + 1 < self.info.items.len and cluster == self.info.items[self.idx + 1].cluster) or
            (out_len != 0 and cluster == out[out_len - 1].cluster);
        if (!cluster_survives) {
            if (out_len != 0) {
                if (cluster < out[out_len - 1].cluster) {
                    const mask = self.info.items[self.idx].mask;
                    const old_cluster = out[out_len - 1].cluster;
                    var i = out_len;
                    while (i != 0 and out[i - 1].cluster == old_cluster) : (i -= 1) {
                        setCluster(&out[i - 1], cluster, mask);
                    }
                }
            } else if (self.idx + 1 < self.info.items.len) {
                self.mergeClusters(self.idx, self.idx + 2);
            }
        }
        self.skipGlyph();
    }

    pub fn resetMasks(self: *Buffer, mask: u32) void {
        for (self.info.items) |*glyph_info| glyph_info.mask = mask;
    }

    pub fn addMasks(self: *Buffer, mask: u32) void {
        for (self.info.items) |*glyph_info| glyph_info.mask |= mask;
    }

    pub fn setMasks(self: *Buffer, value: u32, mask: u32, cluster_start: u32, cluster_end: u32) void {
        if (mask == 0) return;

        const not_mask = ~mask;
        const masked_value = value & mask;

        self.max_ops -= @intCast(self.info.items.len);
        if (self.max_ops < 0) self.successful = false;

        if (cluster_start == 0 and cluster_end == std.math.maxInt(u32)) {
            for (self.info.items) |*glyph_info| glyph_info.mask = (glyph_info.mask & not_mask) | masked_value;
            return;
        }

        for (self.info.items) |*glyph_info| {
            if (cluster_start <= glyph_info.cluster and glyph_info.cluster < cluster_end) {
                glyph_info.mask = (glyph_info.mask & not_mask) | masked_value;
            }
        }
    }

    pub fn mergeClusters(self: *Buffer, start: usize, end: usize) void {
        if (end - start < 2) return;
        if (!self.cluster_level.isMonotone()) {
            self.unsafeToBreak(start, end);
            return;
        }
        self.mergeClustersImpl(start, end);
    }

    pub fn mergeGraphemeClusters(self: *Buffer, start: usize, end: usize) void {
        if (end - start < 2) return;
        if (!self.cluster_level.isGraphemes()) {
            self.unsafeToBreak(start, end);
            return;
        }
        self.mergeClustersImpl(start, end);
    }

    fn mergeClustersImpl(self: *Buffer, start_in: usize, end_in: usize) void {
        var start = start_in;
        var end = end_in;

        self.max_ops -= @intCast(end - start);
        if (self.max_ops < 0) self.successful = false;

        var cluster = self.info.items[start].cluster;
        for (self.info.items[start + 1 .. end]) |glyph_info| cluster = @min(cluster, glyph_info.cluster);

        if (cluster != self.info.items[end - 1].cluster) {
            while (end < self.info.items.len and self.info.items[end - 1].cluster == self.info.items[end].cluster) end += 1;
        }

        if (cluster != self.info.items[start].cluster) {
            while (self.idx < start and self.info.items[start - 1].cluster == self.info.items[start].cluster) start -= 1;
        }

        if (self.idx == start and self.info.items[start].cluster != cluster) {
            const target_cluster = self.info.items[start].cluster;
            const out = self.outItems();
            var i = out.len;
            while (i > 0 and out[i - 1].cluster == target_cluster) : (i -= 1) {
                setCluster(&out[i - 1], cluster, 0);
            }
        }

        for (self.info.items[start..end]) |*glyph_info| setCluster(glyph_info, cluster, 0);
    }

    pub fn mergeOutClusters(self: *Buffer, start: usize, end: usize) void {
        if (end - start < 2) return;
        if (!self.cluster_level.isMonotone()) return;
        self.mergeOutClustersImpl(start, end);
    }

    pub fn mergeOutGraphemeClusters(self: *Buffer, start: usize, end: usize) void {
        if (end - start < 2) return;
        if (!self.cluster_level.isGraphemes()) return;
        self.mergeOutClustersImpl(start, end);
    }

    fn mergeOutClustersImpl(self: *Buffer, start_in: usize, end_in: usize) void {
        var start = start_in;
        var end = end_in;

        self.max_ops -= @intCast(end - start);
        if (self.max_ops < 0) self.successful = false;

        const out = self.outItems();
        var cluster = out[start].cluster;
        for (out[start + 1 .. end]) |glyph_info| cluster = @min(cluster, glyph_info.cluster);

        while (start > 0 and out[start - 1].cluster == out[start].cluster) start -= 1;
        while (end < out.len and out[end - 1].cluster == out[end].cluster) end += 1;

        if (end == out.len) {
            const target_cluster = out[end - 1].cluster;
            var k = self.idx;
            while (k < self.info.items.len and self.info.items[k].cluster == target_cluster) : (k += 1) {
                setCluster(&self.info.items[k], cluster, 0);
            }
        }

        for (out[start..end]) |*glyph_info| setCluster(glyph_info, cluster, 0);
    }

    /// Ported from hb_buffer_t::sort - insertion sort restricted to
    /// [start, end), merging clusters across every shift so cluster
    /// boundaries stay consistent with the reordering (used by the
    /// normalizer's combining-mark reorder round, always on short runs -
    /// see HB_OT_SHAPE_MAX_COMBINING_MARKS in `normalizeReorderRound`).
    pub fn sortByCombiningClass(self: *Buffer, start: usize, end: usize) void {
        var i = start + 1;
        while (i < end) : (i += 1) {
            var j = i;
            while (j > start and combiningClassOf(&self.info.items[j - 1]) > combiningClassOf(&self.info.items[i])) j -= 1;
            if (i == j) continue;
            self.mergeClusters(j, i + 1);
            const moved = self.info.items[i];
            var k = i;
            while (k > j) : (k -= 1) self.info.items[k] = self.info.items[k - 1];
            self.info.items[j] = moved;
        }
    }

    pub fn reverseRange(self: *Buffer, start: usize, end: usize) void {
        std.mem.reverse(GlyphInfo, self.info.items[start..end]);
        if (self.have_positions) std.mem.reverse(GlyphPosition, self.pos.items[start..end]);
    }

    pub fn reverse(self: *Buffer) void {
        self.reverseRange(0, self.info.items.len);
    }

    pub fn reverseGroups(self: *Buffer, comptime groupFn: fn (a: GlyphInfo, b: GlyphInfo) bool, merge_clusters: bool) void {
        if (self.info.items.len == 0) return;

        var start: usize = 0;
        var i: usize = 1;
        while (i < self.info.items.len) : (i += 1) {
            if (!groupFn(self.info.items[i - 1], self.info.items[i])) {
                if (merge_clusters) self.mergeClusters(start, i);
                self.reverseRange(start, i);
                start = i;
            }
        }
        if (merge_clusters) self.mergeClusters(start, i);
        self.reverseRange(start, i);

        self.reverse();
    }

    pub fn reverseClusters(self: *Buffer) void {
        self.reverseGroups(clusterGroupFunc, false);
    }

    fn infosFindMinCluster(self: Buffer, infos: []const GlyphInfo, start: usize, end: usize, cluster_in: u32) u32 {
        var cluster = cluster_in;
        if (start == end) return cluster;

        if (self.cluster_level == .characters) {
            for (infos[start..end]) |glyph_info| cluster = @min(cluster, glyph_info.cluster);
            return cluster;
        }

        return @min(cluster, @min(infos[start].cluster, infos[end - 1].cluster));
    }

    fn infosSetGlyphFlags(self: *Buffer, infos: []GlyphInfo, start: usize, end: usize, cluster: u32, mask: u32) void {
        if (start == end) return;

        self.max_ops -= @intCast(end - start);
        if (self.max_ops < 0) self.successful = false;

        const cluster_first = infos[start].cluster;
        const cluster_last = infos[end - 1].cluster;

        if (self.cluster_level == .characters or (cluster != cluster_first and cluster != cluster_last)) {
            for (infos[start..end]) |*glyph_info| {
                if (cluster != glyph_info.cluster) glyph_info.mask |= mask;
            }
            return;
        }

        if (cluster == cluster_first) {
            var i = end;
            while (start < i and infos[i - 1].cluster != cluster_first) : (i -= 1) {
                infos[i - 1].mask |= mask;
            }
        } else {
            var i = start;
            while (i < end and infos[i].cluster != cluster_last) : (i += 1) {
                infos[i].mask |= mask;
            }
        }
    }

    fn setGlyphFlagsImpl(self: *Buffer, mask: u32, start: usize, end: usize, interior: bool, from_out_buffer: bool) void {
        if (!from_out_buffer or !self.have_output) {
            if (!interior) {
                for (self.info.items[start..end]) |*glyph_info| glyph_info.mask |= mask;
            } else {
                const cluster = self.infosFindMinCluster(self.info.items, start, end, std.math.maxInt(u32));
                self.infosSetGlyphFlags(self.info.items, start, end, cluster, mask);
            }
        } else {
            const out = self.outItems();
            if (!interior) {
                for (out[start..]) |*glyph_info| glyph_info.mask |= mask;
                for (self.info.items[self.idx..end]) |*glyph_info| glyph_info.mask |= mask;
            } else {
                var cluster = self.infosFindMinCluster(self.info.items, self.idx, end, std.math.maxInt(u32));
                cluster = self.infosFindMinCluster(out, start, out.len, cluster);
                self.infosSetGlyphFlags(out, start, out.len, cluster, mask);
                self.infosSetGlyphFlags(self.info.items, self.idx, end, cluster, mask);
            }
        }
    }

    pub fn setGlyphFlags(self: *Buffer, mask: u32, start: usize, end_opt: ?usize, interior: bool, from_out_buffer: bool) void {
        if (end_opt) |raw_end| if (raw_end - start > 255) return;
        const end = @min(end_opt orelse self.info.items.len, self.info.items.len);
        if (interior and !from_out_buffer and end - start < 2) return;
        self.setGlyphFlagsImpl(mask, start, end, interior, from_out_buffer);
    }

    pub fn unsafeToBreak(self: *Buffer, start: usize, end: ?usize) void {
        self.setGlyphFlags(glyph_flag_unsafe_to_break | glyph_flag_unsafe_to_concat, start, end, true, false);
    }

    pub fn unsafeToBreakFromOutBuffer(self: *Buffer, start: usize, end: ?usize) void {
        self.setGlyphFlags(glyph_flag_unsafe_to_break | glyph_flag_unsafe_to_concat, start, end, true, true);
    }

    /// Ported from hb_buffer_t::move_to. `target` is an absolute position in
    /// the unified backtrack+lookahead coordinate space (`out_info` followed
    /// by the unconsumed tail of `info` starting at `idx`), i.e. the same
    /// addressing as hb's `backtrack_len() + lookahead_len()`. A target below
    /// `outLen()` rewinds already-emitted glyphs from the tail of `out_info`
    /// back into pending input (splicing them into `info` right before
    /// `idx`), letting a nested LookupRecord re-match glyphs a prior
    /// LookupRecord in the same rule just inserted - see `applyContextCore`.
    pub fn moveTo(self: *Buffer, target: usize) !void {
        if (!self.have_output) {
            self.idx = target;
            return;
        }
        if (!self.successful) return;
        const out_len = self.out_len;
        if (out_len < target) {
            try self.nextGlyphs(target - out_len);
        } else if (out_len > target) {
            const count = out_len - target;
            // The splice below reads the output while writing `info`, so the
            // two must not be the same array.
            try self.unsplitToSplit();
            // Splice the un-committed tail of out_info back in right before
            // the current input window; idx keeps its numeric value since
            // that's exactly where the spliced-in glyphs now start.
            try self.info.insertSlice(self.allocator, self.idx, self.out_info.items[out_len - count ..]);
            self.out_info.shrinkRetainingCapacity(out_len - count);
            self.out_len = out_len - count;
        }
    }

    /// Switches the buffer into output mode: subsequent next_glyph/
    /// output_glyph calls build out_info while info is read via idx.
    pub fn clearOutput(self: *Buffer) void {
        self.have_output = true;
        self.have_positions = false;
        self.idx = 0;
        self.out_len = 0;
        self.out_split = false;
        self.out_info.clearRetainingCapacity();
    }

    pub fn clearPositions(self: *Buffer) !void {
        self.have_output = false;
        self.have_positions = true;
        self.out_len = 0;
        self.out_split = false;
        self.out_info.clearRetainingCapacity();
        try self.pos.resize(self.allocator, self.info.items.len);
        @memset(self.pos.items, .{});
    }

    /// Finishes an output pass: copies any untouched trailing glyphs, then
    /// swaps info/out_info so the output becomes the new input.
    pub fn sync(self: *Buffer) !void {
        std.debug.assert(self.have_output);
        if (self.successful) {
            try self.nextGlyphs(self.info.items.len - self.idx);
            if (self.out_split) {
                std.mem.swap(std.ArrayList(GlyphInfo), &self.info, &self.out_info);
            } else {
                self.info.shrinkRetainingCapacity(self.out_len);
            }
        }
        self.have_output = false;
        self.out_len = 0;
        self.out_split = false;
        self.out_info.clearRetainingCapacity();
        self.idx = 0;
    }

    /// Ascending, deduplicated table of this buffer's cluster boundaries:
    /// `starts[i]` is a cluster value (== a codepoint index into the text
    /// that was shaped), `ends[i]` the byte offset (via `byte_offsets`,
    /// caller-decoded codepoint-index -> byte-offset table, one entry past
    /// the last codepoint) where that cluster ends -- the next used
    /// cluster's start, or end of text for the last one. Built once by a
    /// caller and reused across `clusterByteRange` calls so a glyph's
    /// logical byte range can be looked up without assuming buffer
    /// (visual) order matches logical order -- needed because a merged
    /// cluster can span codepoints that never appear as any glyph's
    /// `cluster` value.
    pub fn buildClusterTables(self: *const Buffer, gpa: std.mem.Allocator, byte_offsets: []const u32) std.mem.Allocator.Error!struct { starts: []u32, ends: []u32 } {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        // Upper-bound presize (unique clusters <= glyph count) avoids
        // per-append growth reallocations.
        try starts.ensureTotalCapacityPrecise(gpa, self.info.items.len);
        for (self.info.items) |info| {
            if (std.mem.indexOfScalar(u32, starts.items, info.cluster) == null) {
                try starts.append(gpa, info.cluster);
            }
        }
        insertionSort(u32, starts.items, {}, struct {
            fn lessThan(_: void, a: u32, b: u32) bool {
                return a < b;
            }
        }.lessThan);

        const ends = try gpa.alloc(u32, starts.items.len);
        errdefer gpa.free(ends);
        for (starts.items, 0..) |_, i| {
            const next_start = if (i + 1 < starts.items.len) starts.items[i + 1] else @as(u32, @intCast(byte_offsets.len - 1));
            ends[i] = byte_offsets[next_start];
        }

        return .{ .starts = try starts.toOwnedSlice(gpa), .ends = ends };
    }

    /// Logical byte range `[start, end)` of the cluster that glyph
    /// `info.items[glyph_idx]` belongs to, given the tables from
    /// `buildClusterTables`. Unlike `byteOffsetForGlyph`/
    /// `glyphLimitForByteOffset`, this never looks at a *different*
    /// glyph's position in the buffer, so it stays correct for glyphs
    /// inside an RTL run, where the next glyph in visual (buffer) order
    /// has a *smaller* cluster than the current one.
    pub const ByteRange = struct { start: usize, end: usize };

    pub fn clusterByteRange(self: *const Buffer, cluster_starts: []const u32, cluster_ends: []const u32, byte_offsets: []const u32, glyph_idx: usize) ByteRange {
        const cluster = self.info.items[glyph_idx].cluster;
        const i = std.mem.indexOfScalar(u32, cluster_starts, cluster).?;
        return .{ .start = byte_offsets[cluster], .end = cluster_ends[i] };
    }

    /// Byte offset in the original text immediately after the first
    /// `glyph_count` glyphs in shaped (visual) order. Exact for LTR text;
    /// for bidi-reordered runs this walks array order rather than logical
    /// order, so the byte offset it yields mid-RTL-run is a *visual*
    /// prefix, not a logical one. Callers that must be bidi-correct
    /// therefore do not slice a reordered shape through this: selection
    /// highlight uses `clusterByteRange` (order-independent), measurement
    /// and hit-testing use `logicalPrefixGlyphs`, and line-wrap trim/render
    /// reshape each final line's own byte-range.
    pub fn byteOffsetForGlyph(self: *const Buffer, byte_offsets: []const u32, glyph_count: usize) usize {
        if (glyph_count == 0) return 0;
        if (glyph_count >= self.info.items.len) return byte_offsets[byte_offsets.len - 1];
        const cluster = self.info.items[glyph_count].cluster;
        return byte_offsets[cluster];
    }

    /// Inverse of `byteOffsetForGlyph`: smallest glyph count whose
    /// `byteOffsetForGlyph` result is >= `byte_offset`. Lets a caller
    /// slice an already-shaped line at a byte boundary found some other
    /// way (a UAX #14 break search, a cursor byte offset) without
    /// reshaping. Same visual-vs-logical-order caveat as
    /// `byteOffsetForGlyph`: a logical prefix is `logicalPrefixGlyphs`.
    pub fn glyphLimitForByteOffset(self: *const Buffer, byte_offsets: []const u32, byte_offset: usize) usize {
        for (self.info.items, 0..) |info, idx| {
            if (byte_offsets[info.cluster] >= byte_offset) return idx;
        }
        return self.info.items.len;
    }

    pub const GlyphRange = struct { start: usize, end: usize };

    /// Glyphs covering the *logical* byte prefix `[0, byte_offset)`, picked
    /// by cluster rather than by buffer position. In an RTL run that prefix
    /// is the buffer's *trailing* glyphs, which is exactly where
    /// `glyphLimitForByteOffset`, counting from the buffer's start, answers
    /// for the wrong end of the run. Contiguous within one level run; a
    /// buffer holding both directions gets the enclosing range.
    pub fn logicalPrefixGlyphs(self: *const Buffer, byte_offsets: []const u32, byte_offset: usize) GlyphRange {
        var start: usize = self.info.items.len;
        var end: usize = 0;
        for (self.info.items, 0..) |info, idx| {
            if (byte_offsets[info.cluster] >= byte_offset) continue;
            start = @min(start, idx);
            end = idx + 1;
        }
        if (end == 0) return .{ .start = 0, .end = 0 };
        return .{ .start = start, .end = end };
    }

    /// Where a caret after the logical byte prefix `[0, byte_offset)` sits:
    /// past the full advances of glyphs `[0, glyph_start)` plus
    /// `caretFraction` of the advances of `[glyph_start, glyph_end)`. The
    /// second range is non-empty only when `byte_offset` falls on a grapheme
    /// boundary inside one cluster -- a ligature such as "fi" -- where the
    /// caret sits `component` of `components` graphemes into it.
    pub const CaretSpot = struct {
        glyph_start: usize,
        glyph_end: usize,
        component: u32 = 0,
        components: u32 = 1,
        rtl: bool,
    };

    pub fn caretSpot(self: *const Buffer, byte_offsets: []const u32, codepoints: []const u21, byte_offset: usize) CaretSpot {
        const rtl = self.isRtl();
        const r = self.logicalPrefixGlyphs(byte_offsets, byte_offset);
        const limit = if (!rtl) r.end else if (r.end == 0) self.info.items.len else r.start;
        const whole: CaretSpot = .{ .glyph_start = limit, .glyph_end = limit, .rtl = rtl };
        if (r.end == 0) return whole;

        var cluster: u32 = 0;
        for (self.info.items[r.start..r.end]) |info| {
            if (byte_offsets[info.cluster] < byte_offset) cluster = @max(cluster, info.cluster);
        }
        var cluster_end: usize = byte_offsets.len - 1;
        var glyph_start: usize = self.info.items.len;
        var glyph_end: usize = 0;
        for (self.info.items, 0..) |info, idx| {
            if (info.cluster > cluster) cluster_end = @min(cluster_end, info.cluster);
            if (info.cluster == cluster) {
                glyph_start = @min(glyph_start, idx);
                glyph_end = idx + 1;
            }
        }
        if (byte_offsets[cluster_end] <= byte_offset) return whole;

        var components: u32 = 0;
        var component: u32 = 0;
        var graphemes = unicode.GraphemeBreakIterator.init(codepoints[cluster..cluster_end]);
        while (graphemes.next()) |_| {
            components += 1;
            if (byte_offsets[cluster + graphemes.pos] <= byte_offset) component += 1;
        }
        if (components <= 1) return whole;
        return .{ .glyph_start = glyph_start, .glyph_end = glyph_end, .component = component, .components = components, .rtl = rtl };
    }

    /// Share of the `spot` cluster's advance left of the caret. A single
    /// ligature glyph listed in GDEF's LigCaretList uses the font's own
    /// caret (hb_ot_layout_get_ligature_carets); otherwise the advance is
    /// split evenly across the components, as Blink and Android do.
    pub fn caretFraction(self: *const Buffer, spot: CaretSpot, gdef: ?[]const u8) f32 {
        if (spot.glyph_end <= spot.glyph_start or spot.components <= 1) return 0;
        const n = spot.components;
        const k = spot.component;
        if (spot.glyph_end - spot.glyph_start == 1 and k > 0 and k < n) if (gdef) |data| {
            const glyph = self.info.items[spot.glyph_start].codepoint;
            const advance = self.pos.items[spot.glyph_start].x_advance;
            // LigCaretList carets run in increasing x, so an RTL ligature's
            // first component boundary is its rightmost caret.
            const caret_index: u16 = @intCast(if (spot.rtl) n - 1 - k else k - 1);
            if (advance > 0 and glyph <= std.math.maxInt(u16) and n <= std.math.maxInt(u16)) {
                if (parsing.Table.Gdef.ligCaret(data, @intCast(glyph), caret_index, @intCast(n - 1)) catch null) |caret| {
                    return std.math.clamp(@as(f32, @floatFromInt(caret)) / @as(f32, @floatFromInt(advance)), 0, 1);
                }
            }
        };
        const logical = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        return if (spot.rtl) 1 - logical else logical;
    }

    /// Glyphs run right to left: a later glyph belongs to an earlier cluster.
    /// Answers for one level run, which is what a fragment holds; a buffer
    /// mixing directions reports the direction of its first turn.
    pub fn isRtl(self: *const Buffer) bool {
        var prev: ?u32 = null;
        for (self.info.items) |info| {
            if (prev) |p| {
                if (info.cluster < p) return true;
                if (info.cluster > p) return false;
            }
            prev = info.cluster;
        }
        return false;
    }
};

/// Ported from `hb_syllabic_insert_dotted_circles` (hb-ot-shaper-syllabic.cc):
/// shared by Indic/Khmer/Myanmar/USE. Inserts U+25CC before every broken
/// syllable (skipping past a leading repha, if `repha_category` is given),
/// using the font's own dotted-circle glyph. No-op if the buffer has no
/// broken syllable of `broken_syllable_type` or the font lacks U+25CC.
///
/// Runs immediately after syllabification rather than in a GSUB pause
/// (this port has no pause machinery - see [[project_use_shaper_pipeline_gap]]),
/// so unlike hb this never sees a repha/pref glyph already reclassified by a
/// prior substitution pass; it only ever skips a *pre-substitution* repha.
pub const Cmap = parsing.Table.cmap.Resolved;

pub fn insertDottedCircles(
    buffer: *Buffer,
    cmap: ?Cmap,
    broken_syllable_type: u8,
    dottedcircle_category: u8,
    repha_category: ?u8,
    dottedcircle_position: ?u8,
    /// Whether `codepoint` already holds glyph ids (a GSUB-pause caller).
    glyphs_mapped: bool,
) !bool {
    var has_broken = false;
    for (buffer.info.items) |info| {
        if (info.indic_syllable & 0x0F == broken_syllable_type) {
            has_broken = true;
            break;
        }
    }
    if (!has_broken) return false;

    const resolved = cmap orelse return false;
    const dottedcircle_glyph = resolved.lookup(0x25CC) orelse return false;

    var dottedcircle = GlyphInfo{};
    // Pre-mapGlyphsFast callers need the glyph in var1 too, or
    // mapGlyphsFast's unconditional `codepoint = var1` clobbers it to 0.
    dottedcircle.codepoint = if (glyphs_mapped) dottedcircle_glyph else 0x25CC;
    dottedcircle.var1 = @bitCast(@as(u32, dottedcircle_glyph));
    dottedcircle.indic_category = dottedcircle_category;
    if (dottedcircle_position) |pos| dottedcircle.indic_position = pos;

    buffer.clearOutput();
    buffer.idx = 0;
    var last_syllable: u8 = 0;
    while (buffer.idx < buffer.info.items.len and buffer.successful) {
        const syllable = buffer.info.items[buffer.idx].indic_syllable;
        if (last_syllable != syllable and (syllable & 0x0F) == broken_syllable_type) {
            last_syllable = syllable;

            var ginfo = dottedcircle;
            ginfo.cluster = buffer.info.items[buffer.idx].cluster;
            ginfo.mask = buffer.info.items[buffer.idx].mask;
            ginfo.indic_syllable = syllable;

            if (repha_category) |rc| {
                while (buffer.idx < buffer.info.items.len and buffer.successful and
                    last_syllable == buffer.info.items[buffer.idx].indic_syllable and
                    buffer.info.items[buffer.idx].indic_category == rc)
                {
                    try buffer.nextGlyph();
                }
            }

            try buffer.outputInfo(ginfo);
        } else {
            try buffer.nextGlyph();
        }
    }
    try buffer.sync();
    return true;
}

pub const Tag = parsing.Font.Tag;

pub fn containsTag(tags: []const Tag, tag: Tag) bool {
    for (tags) |t| if (parsing.Font.tagEql(t, tag)) return true;
    return false;
}

/// hb's `_hb_glyph_info_is_default_ignorable`: GSUB output is no longer
/// ignorable.
pub fn isIgnorable(info: GlyphInfo) bool {
    return info.is_default_ignorable and !info.is_substituted;
}

/// One GSUB/GPOS subtable, resolved once at plan time (hb's
/// `hb_ot_layout_lookup_accelerator_t` entry): its set digest plus the
/// extension-unwrapped offset and type, so applying it to a glyph needs no
/// header re-read.
pub const SubtableInfo = struct {
    digest: Digest,
    offset: u32,
    lookup_type: u16,
};

pub fn combiningClassOf(info: *GlyphInfo) u8 {
    if (info.ccc_codepoint != info.codepoint) {
        info.ccc = unicode.modifiedCombiningClass(@intCast(info.codepoint));
        info.ccc_codepoint = info.codepoint;
    }
    if (info.arabic_mcm_moved) return if (info.ccc == 220) 22 else 26;
    return info.ccc;
}

