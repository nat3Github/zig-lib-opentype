const std = @import("std");
const parsing = @import("../parsing.zig");
const unicode = @import("../unicode.zig");

// Ported from vendor/harfbuzz/src/hb-buffer.hh + hb-buffer.cc (pinned
// 703e2d1441). The single-allocation info/out_info-aliasing trick hb uses to
// avoid a second malloc during in-place shaping is dropped in favor of two
// plain ArrayLists (Zig's allocator already amortizes growth); sync() swaps
// them instead. Everything else - cluster merge semantics, glyph-flag
// propagation, max_ops budget - is ported as-is since that's where the
// actual shaping correctness lives.

pub const glyph_flag_unsafe_to_break: u32 = 0x1;
pub const glyph_flag_unsafe_to_concat: u32 = 0x2;
pub const glyph_flag_safe_to_insert_tatweel: u32 = 0x4;
pub const glyph_flag_defined: u32 = 0x7;

pub const GlyphInfo = struct {
    /// Unicode codepoint before shaping, glyph index after shaping.
    codepoint: u32 = 0,
    /// Low bits (glyph_flag_*) plus shaper-assigned feature-lookup mask bits.
    mask: u32 = 0,
    cluster: u32 = 0,
    /// Scratch storage reused by GSUB/GPOS lookups (glyph_props, lig_props,
    /// syllable, ...) once those land; kept as plain bit-reinterpretable
    /// fields rather than named fields until a consumer exists. Also
    /// doubles as the normalizer's `normalizer_glyph_index` scratch slot
    /// (see `outputChar`/`nextChar`/`mapGlyphsFast`) - both uses are
    /// mutually exclusive in time (normalize finishes and converts
    /// `codepoint` to a real glyph id before any GSUB/GPOS lookup runs).
    var1: i32 = 0,
    var2: i32 = 0,
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
};

/// Same order as hb-ot-shaper-arabic.cc's `arabic_features`/`arabic_action_t`.
pub const ArabicAction = enum(u8) { isol, fina, fin2, fin3, medi, med2, init, none };

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

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    info: std.ArrayList(GlyphInfo) = .empty,
    out_info: std.ArrayList(GlyphInfo) = .empty,
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
        return self.out_info.items.len;
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

    fn prevInfo(self: Buffer) GlyphInfo {
        const n = self.out_info.items.len;
        return if (n > 0) self.out_info.items[n - 1] else GlyphInfo{};
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

        try self.out_info.ensureUnusedCapacity(self.allocator, glyph_ids.len);
        for (glyph_ids) |gid| {
            var glyph_info = orig_info;
            glyph_info.codepoint = gid;
            self.out_info.appendAssumeCapacity(glyph_info);
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
        try self.out_info.append(self.allocator, glyph_info);
    }

    /// Copies the glyph at idx to output without advancing idx.
    pub fn copyGlyph(self: *Buffer) !void {
        try self.outputInfo(self.cur(0));
    }

    /// Copies the glyph at idx to output (if have_output) and advances idx.
    pub fn nextGlyph(self: *Buffer) !void {
        if (self.have_output) {
            try self.out_info.append(self.allocator, self.info.items[self.idx]);
        }
        self.idx += 1;
    }

    /// Copies n glyphs at idx to output (if have_output) and advances idx.
    pub fn nextGlyphs(self: *Buffer, n: usize) !void {
        if (self.have_output) {
            try self.out_info.appendSlice(self.allocator, self.info.items[self.idx..][0..n]);
        }
        self.idx += n;
    }

    /// Advances idx without copying to output.
    pub fn skipGlyph(self: *Buffer) void {
        self.idx += 1;
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
            var i = self.out_info.items.len;
            while (i > 0 and self.out_info.items[i - 1].cluster == target_cluster) : (i -= 1) {
                setCluster(&self.out_info.items[i - 1], cluster, 0);
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

        var cluster = self.out_info.items[start].cluster;
        for (self.out_info.items[start + 1 .. end]) |glyph_info| cluster = @min(cluster, glyph_info.cluster);

        while (start > 0 and self.out_info.items[start - 1].cluster == self.out_info.items[start].cluster) start -= 1;
        while (end < self.out_info.items.len and self.out_info.items[end - 1].cluster == self.out_info.items[end].cluster) end += 1;

        if (end == self.out_info.items.len) {
            const target_cluster = self.out_info.items[end - 1].cluster;
            var k = self.idx;
            while (k < self.info.items.len and self.info.items[k].cluster == target_cluster) : (k += 1) {
                setCluster(&self.info.items[k], cluster, 0);
            }
        }

        for (self.out_info.items[start..end]) |*glyph_info| setCluster(glyph_info, cluster, 0);
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
            while (j > start and combiningClassOf(self.info.items[j - 1]) > combiningClassOf(self.info.items[i])) j -= 1;
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
            if (!interior) {
                for (self.out_info.items[start..]) |*glyph_info| glyph_info.mask |= mask;
                for (self.info.items[self.idx..end]) |*glyph_info| glyph_info.mask |= mask;
            } else {
                var cluster = self.infosFindMinCluster(self.info.items, self.idx, end, std.math.maxInt(u32));
                cluster = self.infosFindMinCluster(self.out_info.items, start, self.out_info.items.len, cluster);
                self.infosSetGlyphFlags(self.out_info.items, start, self.out_info.items.len, cluster, mask);
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
        const out_len = self.out_info.items.len;
        if (out_len < target) {
            const count = target - out_len;
            try self.out_info.appendSlice(self.allocator, self.info.items[self.idx..][0..count]);
            self.idx += count;
        } else if (out_len > target) {
            const count = out_len - target;
            // Splice the un-committed tail of out_info back in right before
            // the current input window; idx keeps its numeric value since
            // that's exactly where the spliced-in glyphs now start.
            try self.info.insertSlice(self.allocator, self.idx, self.out_info.items[out_len - count ..]);
            self.out_info.shrinkRetainingCapacity(out_len - count);
        }
    }

    /// Switches the buffer into output mode: subsequent next_glyph/
    /// output_glyph calls build out_info while info is read via idx.
    pub fn clearOutput(self: *Buffer) void {
        self.have_output = true;
        self.have_positions = false;
        self.idx = 0;
        self.out_info.clearRetainingCapacity();
    }

    pub fn clearPositions(self: *Buffer) !void {
        self.have_output = false;
        self.have_positions = true;
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
            std.mem.swap(std.ArrayList(GlyphInfo), &self.info, &self.out_info);
        }
        self.have_output = false;
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
        std.mem.sort(u32, starts.items, {}, std.sort.asc(u32));

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
    /// highlight uses `clusterByteRange` (order-independent), and
    /// line-wrap trim/measure/render reshape each final line's own
    /// byte-range. Remaining visual-order caller: mouse/touch hit-testing
    /// inside an RTL run, where the byte this maps a click to can still be
    /// off by a cluster.
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
    /// `byteOffsetForGlyph`.
    pub fn glyphLimitForByteOffset(self: *const Buffer, byte_offsets: []const u32, byte_offset: usize) usize {
        for (self.info.items, 0..) |info, idx| {
            if (byte_offsets[info.cluster] >= byte_offset) return idx;
        }
        return self.info.items.len;
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
pub fn insertDottedCircles(
    buffer: *Buffer,
    cmap_data: ?[]const u8,
    broken_syllable_type: u8,
    dottedcircle_category: u8,
    repha_category: ?u8,
    dottedcircle_position: ?u8,
) !bool {
    var has_broken = false;
    for (buffer.info.items) |info| {
        if (info.indic_syllable & 0x0F == broken_syllable_type) {
            has_broken = true;
            break;
        }
    }
    if (!has_broken) return false;

    const data = cmap_data orelse return false;
    const dottedcircle_glyph = parsing.Table.cmap.lookup(data, 0x25CC) orelse return false;

    var dottedcircle = GlyphInfo{};
    // Runs pre-mapGlyphsFast (codepoint still holds Unicode values here, see
    // outputChar/mapGlyphsFast) - stash the resolved glyph in var1 the same
    // way, not codepoint directly, or mapGlyphsFast's unconditional
    // `codepoint = var1` overwrite clobbers it back to 0.
    dottedcircle.codepoint = 0x25CC;
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
    for (tags) |t| if (std.mem.eql(u8, &t, &tag)) return true;
    return false;
}

pub fn combiningClassOf(info: GlyphInfo) u8 {
    return unicode.combiningClass(@intCast(info.codepoint));
}
