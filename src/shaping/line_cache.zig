const std = @import("std");
const common = @import("common.zig");
const metrics = @import("metrics.zig");
const unicode = @import("../unicode.zig");
const root = @import("../root.zig");

const Buffer = common.Buffer;
const EndMetric = metrics.EndMetric;

/// Decode `text` up to its first mandatory break into codepoints plus a
/// byte offset per codepoint, with a trailing end offset.
pub fn decodeLine(output: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!struct { codepoints: []u21, byte_offsets: []u32 } {
    var codepoints: std.ArrayList(u21) = .empty;
    errdefer codepoints.deinit(output);
    var byte_offsets: std.ArrayList(u32) = .empty;
    errdefer byte_offsets.deinit(output);
    // Upper-bound presize (codepoints/offsets <= byte count) avoids
    // per-append growth reallocations for every shaped line.
    try codepoints.ensureTotalCapacityPrecise(output, text.len);
    try byte_offsets.ensureTotalCapacityPrecise(output, text.len + 1);

    const hard_break_at = if (root.firstHardBreak(text)) |hb| hb.start else text.len;
    var i: usize = 0;
    while (i < text.len) {
        if (i >= hard_break_at) break;
        const cplen = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + cplen > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..cplen]) catch break;
        try byte_offsets.append(output, @intCast(i));
        try codepoints.append(output, cp);
        i += cplen;
    }
    try byte_offsets.append(output, @intCast(i));

    const cp_slice = try codepoints.toOwnedSlice(output);
    errdefer output.free(cp_slice);
    const off_slice = try byte_offsets.toOwnedSlice(output);
    return .{ .codepoints = cp_slice, .byte_offsets = off_slice };
}

/// One shaped line: a visual-order `Buffer` plus the tables needed to map
/// between its glyphs and the logical byte offsets of the text it came
/// from, and the per-font split of its glyph range.
///
/// Fonts are named by *index* into the priority-ordered font list the
/// shaper was handed, never by a caller-side pointer: the caller's own
/// font objects may be relocated by an unrelated load between the shape
/// and a later read of this line. `provider` arguments below resolve an
/// index back to glyph metrics by comptime duck typing, the same seam
/// `measureGlyphRange` uses.
pub const ShapedLine = struct {
    allocator: std.mem.Allocator,
    codepoints: []u21,
    /// Byte offset of each codepoint, plus trailing end offset.
    byte_offsets: []u32,
    buffer: Buffer,
    /// Used cluster starts/ends (byte offset ranges).
    cluster_starts: []u32,
    cluster_ends: []u32,
    segments: []Segment = &.{},

    /// Half-open glyph range shaped by font `font_index`.
    pub const Segment = struct { font_index: u16, glyph_start: u32, glyph_end: u32 };

    pub fn deinit(self: *ShapedLine) void {
        self.buffer.deinit();
        self.allocator.free(self.codepoints);
        self.allocator.free(self.byte_offsets);
        self.allocator.free(self.cluster_starts);
        self.allocator.free(self.cluster_ends);
        self.allocator.free(self.segments);
    }

    /// Font list index that shaped the glyph at `glyph_idx`; 0 (the
    /// primary) for a line with no per-font split.
    pub fn fontIndexForGlyph(self: ShapedLine, glyph_idx: usize) u16 {
        for (self.segments) |seg| {
            if (glyph_idx >= seg.glyph_start and glyph_idx < seg.glyph_end) return seg.font_index;
        }
        return 0;
    }

    /// Byte range of cluster at glyph_idx; correct in RTL runs.
    pub fn clusterByteRange(self: ShapedLine, glyph_idx: usize) Buffer.ByteRange {
        return self.buffer.clusterByteRange(self.cluster_starts, self.cluster_ends, self.byte_offsets, glyph_idx);
    }

    /// Byte offset after first glyph_count glyphs; visual order, not logical.
    pub fn byteOffsetForGlyph(self: ShapedLine, glyph_count: usize) usize {
        return self.buffer.byteOffsetForGlyph(self.byte_offsets, glyph_count);
    }

    /// Inverse of byteOffsetForGlyph; slice shape at byte boundary without reshaping.
    pub fn glyphLimitForByteOffset(self: ShapedLine, byte_offset: usize) usize {
        return self.buffer.glyphLimitForByteOffset(self.byte_offsets, byte_offset);
    }

    /// Glyphs of the logical byte prefix [0, byte_offset); RTL-correct.
    pub fn logicalPrefixGlyphs(self: ShapedLine, byte_offset: usize) Buffer.GlyphRange {
        return self.buffer.logicalPrefixGlyphs(self.byte_offsets, byte_offset);
    }

    /// Reads right to left, so a logical prefix sits at its right edge.
    pub fn isRtl(self: ShapedLine) bool {
        return self.buffer.isRtl();
    }

    /// Both directions in one shape: no logical prefix of it covers a
    /// contiguous stretch of the line, so measuring or slicing one by
    /// byte offset is meaningless whichever end you count from.
    pub fn isMixedDirection(self: ShapedLine) bool {
        var saw_forward = false;
        var saw_back = false;
        var prev: ?u32 = null;
        for (self.buffer.info.items) |info| {
            if (prev) |p| {
                if (info.cluster > p) saw_forward = true;
                if (info.cluster < p) saw_back = true;
            }
            prev = info.cluster;
        }
        return saw_forward and saw_back;
    }

    /// Size of the logical byte prefix [0, byte_offset) of this already
    /// shaped line; no reshaping. In an RTL run that prefix is the
    /// buffer's trailing glyphs, not its leading ones.
    ///
    /// Measured per glyph against *that glyph's own* font rather than
    /// through `measureGlyphRange`: an RTL run from a fallback font must
    /// measure against the fallback's metrics, not the primary's.
    pub fn measureLogicalPrefix(
        self: ShapedLine,
        gpa: std.mem.Allocator,
        provider: anytype,
        byte_offset: usize,
        snap: bool,
    ) !metrics.Size {
        const r = self.logicalPrefixGlyphs(byte_offset);
        var x: f32 = 0;
        var minx: f32 = 0;
        var maxx: f32 = 0;
        var miny: f32 = 0;
        var maxy: f32 = provider.height(0);
        for (self.buffer.info.items[r.start..r.end], self.buffer.pos.items[r.start..r.end], r.start..) |info, pos, gidx| {
            const fi = self.fontIndexForGlyph(gidx);
            const gi = try provider.glyphInfoGet(gpa, fi, info.codepoint);
            const off_x = provider.toPixels(fi, pos.x_offset);
            const adv = provider.toPixels(fi, pos.x_advance);
            const adv_used = if (snap) @round(adv) else adv;
            minx = @min(minx, x + off_x + gi.leftBearing);
            maxx = @max(maxx, x + off_x + gi.leftBearing + gi.w);
            maxx = @max(maxx, x + adv_used);
            miny = @min(miny, provider.ascent(fi) - gi.topBearing);
            maxy = @max(maxy, provider.ascent(fi) - gi.topBearing + gi.h);
            x += adv_used;
        }
        return .{ .w = maxx - minx, .h = maxy - miny };
    }

    pub const PrefixFit = struct { byte: usize, w: f32 };

    /// Longest logical byte prefix of this line that fits `mwidth` (device
    /// pixels), and its width: the inverse of `measureLogicalPrefix`, and
    /// exact in both directions because it is found by measuring through
    /// that same call at each cluster boundary.
    pub fn logicalPrefixForWidth(
        self: ShapedLine,
        gpa: std.mem.Allocator,
        provider: anytype,
        mwidth: f32,
        end_metric: EndMetric,
        snap: bool,
    ) !PrefixFit {
        var best: PrefixFit = .{ .byte = 0, .w = 0 };
        // ponytail: re-measures from the run's logical start per candidate
        // (quadratic in glyphs), which a fragment-sized run never notices;
        // make it incremental if whole-paragraph lines ever come through.
        for (self.cluster_ends) |boundary| {
            const w = (try self.measureLogicalPrefix(gpa, provider, boundary, snap)).w;
            if (w > mwidth) {
                if (end_metric == .nearest and w - mwidth < mwidth - best.w) return .{ .byte = boundary, .w = w };
                return best;
            }
            best = .{ .byte = boundary, .w = w };
        }
        return best;
    }

    /// Pen x, in device pixels from the run's left edge, of a caret
    /// sitting after `byte_offset` logical bytes -- advances only.
    /// `measureLogicalPrefix` answers an ink bounding box, whose
    /// per-glyph side bearings and overhang make it non-additive: a
    /// caret placed from it drifts off the pen positions the renderer
    /// actually draws the glyphs at, by a different amount per prefix.
    pub fn caretPenOffset(self: ShapedLine, provider: anytype, byte_offset: usize, snap: bool) f32 {
        const spot = self.buffer.caretSpot(self.byte_offsets, self.codepoints, byte_offset);
        var x: f32 = 0;
        var cluster_w: f32 = 0;
        for (self.buffer.pos.items[0..spot.glyph_end], 0..) |pos, gidx| {
            const adv = provider.toPixels(self.fontIndexForGlyph(gidx), pos.x_advance);
            const used = if (snap) @round(adv) else adv;
            if (gidx < spot.glyph_start) x += used else cluster_w += used;
        }
        if (spot.glyph_end == spot.glyph_start) return x;
        const gdef = provider.gdefTable(self.fontIndexForGlyph(spot.glyph_start));
        return x + cluster_w * self.buffer.caretFraction(spot, gdef);
    }

    /// Inverse of `caretPenOffset`: the caret stop nearest pen x, one
    /// per grapheme. Pen offsets run backwards through an RTL run's
    /// text, so this picks by distance rather than walking until a
    /// width is exceeded.
    /// ponytail: quadratic in glyphs, same as `logicalPrefixForWidth`;
    /// one click, one fragment-sized run.
    pub fn byteAtPenOffset(self: ShapedLine, provider: anytype, x: f32, snap: bool) usize {
        var best: usize = 0;
        var best_d: f32 = @abs(self.caretPenOffset(provider, 0, snap) - x);
        var graphemes = unicode.GraphemeBreakIterator.init(self.codepoints);
        while (graphemes.next()) |_| {
            const boundary = self.byte_offsets[graphemes.pos];
            const d = @abs(self.caretPenOffset(provider, boundary, snap) - x);
            if (d < best_d) {
                best_d = d;
                best = boundary;
            }
        }
        return best;
    }
};

/// Cache of whole shape results, so an unchanged caller (a static label, a
/// grid cell) doesn't rerun bidi + GSUB/GPOS every frame.
///
/// `FontKey` is the caller's opaque font identity; opentype never
/// interprets it and only ever hands it back. It must carry a `Context`
/// with `hash`/`eql`, so a caller whose key has padding or needs a
/// cheaper compare than `std.meta.eql` decides that itself.
///
/// Entries carry a `used` flag rather than borrowing the caller's own
/// map: a frame-driven caller calls `evictUnused` once per frame to drop
/// whatever went untouched, and `max_bytes` caps growth *within* a frame,
/// where no eviction point exists.
pub fn Cache(comptime FontKey: type) type {
    return struct {
        const Self = @This();

        map: std.HashMapUnmanaged(Key, Tracked, Key.Context, std.hash_map.default_max_load_percentage) = .empty,
        bytes: usize = 0,
        /// Compiled GSUB/GPOS plans, reused across shape calls (and
        /// frames) for the same font + script + features. Holds slices
        /// into font bytes, so a caller that frees any must `clearPlans`
        /// first. Self-bounded by `PlanCache.max_plans`.
        plans: root.PlanCache = .{},

        /// Budget before the cache is dropped wholesale. Counted in bytes,
        /// not lines: line length is caller-controlled and unbounded, so a
        /// line count would bound nothing.
        pub const max_bytes = 16 * 1024 * 1024;

        const Tracked = struct { value: Cached, used: bool = true };

        /// Everything that changes a shape result. Keys stored in the map
        /// point `text` and `features` into their value's owned buffer;
        /// lookups borrow the caller's.
        pub const Key = struct {
            font_key: FontKey,
            text: []const u8,
            item: ?Buffer.ByteRange,
            base_direction: unicode.Bidi.ParagraphDirection,
            features: []const root.Feature,
            tab: ?Tab,

            pub const Tab = struct { size: u8, origin_bits: u32 };

            // Equality over the full key, not the hash, decides a hit:
            // crafted text can collide any unkeyed hash, and a line shaped
            // from other bytes carries byte offsets that index past this
            // `text`.
            pub const Context = struct {
                pub fn hash(_: Context, key: Key) u64 {
                    var hasher = std.hash.Wyhash.init(0);
                    hasher.update(std.mem.asBytes(&FontKey.Context.hash(.{}, key.font_key)));
                    hasher.update(key.text);
                    if (key.item) |item| {
                        hasher.update(std.mem.asBytes(&item.start));
                        hasher.update(std.mem.asBytes(&item.end));
                    }
                    hasher.update(std.mem.asBytes(&key.base_direction));
                    for (key.features) |feature| {
                        hasher.update(&feature.tag);
                        hasher.update(std.mem.asBytes(&feature.value));
                    }
                    if (key.tab) |tab| {
                        hasher.update(std.mem.asBytes(&tab.size));
                        hasher.update(std.mem.asBytes(&tab.origin_bits));
                    }
                    return hasher.final();
                }

                pub fn eql(_: Context, a: Key, b: Key) bool {
                    // Scalar fields first: the byte-slice compares below are
                    // the expensive half, and most probes already differ here.
                    if (a.text.len != b.text.len or a.base_direction != b.base_direction) return false;
                    if (!std.meta.eql(a.item, b.item) or !std.meta.eql(a.tab, b.tab)) return false;
                    if (a.features.len != b.features.len) return false;
                    for (a.features, b.features) |fa, fb| {
                        if (!std.meta.eql(fa, fb)) return false;
                    }
                    if (!FontKey.Context.eql(.{}, a.font_key, b.font_key)) return false;
                    return std.mem.eql(u8, a.text, b.text);
                }
            };
        };

        /// Owned copy of a shape result. Segments name their font by
        /// `FontKey` rather than by list index: the index is only
        /// meaningful against the font list of the call that produced it,
        /// which a later frame no longer has.
        pub const Cached = struct {
            /// One allocation per cached line: backs every slice below
            /// plus the owning key's `text` and `features`.
            buffer: []align(buffer_alignment.toByteUnits()) u8,
            glyphs: []Glyph,
            codepoints: []u21,
            byte_offsets: []u32,
            cluster_starts: []u32,
            cluster_ends: []u32,
            segments: []Segment,

            pub const Segment = struct { font_key: FontKey, glyph_start: u32, glyph_end: u32 };

            /// The `GlyphInfo`/`GlyphPosition` fields a shaped line is read
            /// through; the rest is shaper scratch, zeroed on a hit.
            pub const Glyph = struct { glyph_id: u32, cluster: u32, x_advance: i32, x_offset: i32, y_offset: i32 };

            const buffer_alignment: std.mem.Alignment = .fromByteUnits(@max(
                @alignOf(Glyph),
                @alignOf(u21),
                @alignOf(u32),
                @alignOf(Segment),
                @alignOf(root.Feature),
            ));

            /// Returns the stored copy of `key` alongside the value; both
            /// are freed together by the value's `deinit`.
            fn init(gpa: std.mem.Allocator, key: Key, line: *const ShapedLine, segments: []const Segment) std.mem.Allocator.Error!struct { Key, Cached } {
                const glyph_count = line.buffer.info.items.len;
                var size: usize = 0;
                try reserve(&size, Glyph, glyph_count);
                try reserve(&size, u21, line.codepoints.len);
                try reserve(&size, u32, line.byte_offsets.len);
                try reserve(&size, u32, line.cluster_starts.len);
                try reserve(&size, u32, line.cluster_ends.len);
                try reserve(&size, Segment, segments.len);
                try reserve(&size, root.Feature, key.features.len);
                try reserve(&size, u8, key.text.len);
                const buffer = try gpa.alignedAlloc(u8, buffer_alignment, size);

                // Carve in the same order as `reserve` above so offsets match.
                var offset: usize = 0;
                const glyphs = carve(buffer, &offset, Glyph, glyph_count);
                for (glyphs, line.buffer.info.items, line.buffer.pos.items) |*glyph, info, pos| {
                    glyph.* = .{ .glyph_id = info.codepoint, .cluster = info.cluster, .x_advance = pos.x_advance, .x_offset = pos.x_offset, .y_offset = pos.y_offset };
                }
                const codepoints = carve(buffer, &offset, u21, line.codepoints.len);
                @memcpy(codepoints, line.codepoints);
                const byte_offsets = carve(buffer, &offset, u32, line.byte_offsets.len);
                @memcpy(byte_offsets, line.byte_offsets);
                const cluster_starts = carve(buffer, &offset, u32, line.cluster_starts.len);
                @memcpy(cluster_starts, line.cluster_starts);
                const cluster_ends = carve(buffer, &offset, u32, line.cluster_ends.len);
                @memcpy(cluster_ends, line.cluster_ends);
                const owned_segments = carve(buffer, &offset, Segment, segments.len);
                @memcpy(owned_segments, segments);
                const features = carve(buffer, &offset, root.Feature, key.features.len);
                @memcpy(features, key.features);
                const text = carve(buffer, &offset, u8, key.text.len);
                @memcpy(text, key.text);
                std.debug.assert(offset == size);

                var owned_key = key;
                owned_key.text = text;
                owned_key.features = features;
                return .{ owned_key, .{
                    .buffer = buffer,
                    .glyphs = glyphs,
                    .codepoints = codepoints,
                    .byte_offsets = byte_offsets,
                    .cluster_starts = cluster_starts,
                    .cluster_ends = cluster_ends,
                    .segments = owned_segments,
                } };
            }

            fn reserve(size: *usize, comptime T: type, element_count: usize) std.mem.Allocator.Error!void {
                const bytes = std.math.mul(usize, @sizeOf(T), element_count) catch return error.OutOfMemory;
                const start = std.mem.alignForward(usize, size.*, @alignOf(T));
                size.* = std.math.add(usize, start, bytes) catch return error.OutOfMemory;
            }

            fn carve(buffer: []align(buffer_alignment.toByteUnits()) u8, offset: *usize, comptime T: type, element_count: usize) []T {
                const start = std.mem.alignForward(usize, offset.*, @alignOf(T));
                offset.* = start + @sizeOf(T) * element_count;
                return @as([*]T, @ptrCast(@alignCast(buffer[start..offset.*].ptr)))[0..element_count];
            }

            pub fn byteSize(self: Cached) usize {
                return @sizeOf(Key) + @sizeOf(Cached) + self.buffer.len;
            }

            pub fn deinit(self: *Cached, gpa: std.mem.Allocator) void {
                gpa.free(self.buffer);
            }
        };

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.clear(gpa);
            self.map.deinit(gpa);
            self.plans.deinit(gpa);
            self.* = undefined;
        }

        /// Compiled plans hold slices into font bytes; a caller about to
        /// free or remap any font file must clear them first.
        pub fn clearPlans(self: *Self, gpa: std.mem.Allocator) void {
            self.plans.clear(gpa);
        }

        // ponytail: bulk clear rather than LRU -- eviction order only
        // matters if the budget is hit routinely. Swap in an LRU if a real
        // workload starts thrashing this.
        pub fn clear(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |tracked| tracked.value.deinit(gpa);
            self.map.clearRetainingCapacity();
            self.bytes = 0;
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        /// Marks the entry used, so the next `evictUnused` keeps it.
        pub fn getPtr(self: *Self, key: Key) ?*Cached {
            const tracked = self.map.getPtr(key) orelse return null;
            tracked.used = true;
            return &tracked.value;
        }

        pub fn remove(self: *Self, gpa: std.mem.Allocator, key: Key) void {
            const kv = self.map.fetchRemove(key) orelse return;
            var value = kv.value.value;
            self.bytes -= value.byteSize();
            value.deinit(gpa);
        }

        /// Drops every entry not looked up since the previous call.
        pub fn evictUnused(self: *Self, gpa: std.mem.Allocator) void {
            self.map.lockPointers();
            defer self.map.unlockPointers();
            var it = self.map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.used) {
                    entry.value_ptr.used = false;
                    continue;
                }
                self.bytes -= entry.value_ptr.value.byteSize();
                entry.value_ptr.value.deinit(gpa);
                self.map.removeByPtr(entry.key_ptr);
            }
        }

        /// Keeps `line` for later lookups with an equal `key`. Failing to
        /// allocate just leaves the line uncached.
        pub fn store(self: *Self, gpa: std.mem.Allocator, key: Key, line: *const ShapedLine, segments: []const Cached.Segment) void {
            const owned_key, var value = Cached.init(gpa, key, line, segments) catch return;
            const size = value.byteSize();
            if (size <= max_bytes) {
                if (self.bytes + size > max_bytes) self.clear(gpa);
                // Only reached after a miss or after dropping the stale entry.
                if (self.map.putNoClobber(gpa, owned_key, .{ .value = value })) {
                    self.bytes += size;
                    return;
                } else |_| {}
            }
            value.deinit(gpa);
        }

        /// Turns a hit into a caller-owned `ShapedLine`, resolving each
        /// segment's `FontKey` back to an index into the caller's current
        /// font list via `provider.fontIndexForKey`. `null` when any
        /// segment's font is gone, so the caller reshapes from scratch
        /// rather than rendering with segments silently missing.
        pub fn materialize(
            _: *Self,
            output: std.mem.Allocator,
            cached: *const Cached,
            provider: anytype,
        ) std.mem.Allocator.Error!?ShapedLine {
            const segments = try output.alloc(ShapedLine.Segment, cached.segments.len);
            errdefer output.free(segments);
            for (segments, cached.segments) |*dst, seg| {
                const font_index = provider.fontIndexForKey(seg.font_key) orelse {
                    output.free(segments);
                    return null;
                };
                dst.* = .{ .font_index = font_index, .glyph_start = seg.glyph_start, .glyph_end = seg.glyph_end };
            }

            var buffer = Buffer.init(output);
            errdefer buffer.deinit();
            try buffer.info.resize(output, cached.glyphs.len);
            try buffer.pos.resize(output, cached.glyphs.len);
            for (cached.glyphs, buffer.info.items, buffer.pos.items) |glyph, *info, *pos| {
                info.* = .{ .codepoint = glyph.glyph_id, .cluster = glyph.cluster };
                pos.* = .{ .x_advance = glyph.x_advance, .x_offset = glyph.x_offset, .y_offset = glyph.y_offset };
            }
            buffer.have_positions = true;

            const codepoints = try output.dupe(u21, cached.codepoints);
            errdefer output.free(codepoints);
            const byte_offsets = try output.dupe(u32, cached.byte_offsets);
            errdefer output.free(byte_offsets);
            const cluster_starts = try output.dupe(u32, cached.cluster_starts);
            errdefer output.free(cluster_starts);
            const cluster_ends = try output.dupe(u32, cached.cluster_ends);

            return .{
                .allocator = output,
                .codepoints = codepoints,
                .byte_offsets = byte_offsets,
                .buffer = buffer,
                .cluster_starts = cluster_starts,
                .cluster_ends = cluster_ends,
                .segments = segments,
            };
        }

        /// Shapes one line of `text` against `fonts` (priority order,
        /// parallel to `font_keys`), extending that stack on demand with
        /// whatever `provider` discovers for codepoints none of them
        /// cover, and caches the result under `font_key`.
        ///
        /// `output` may be a frame-scoped arena that resets right after
        /// the call: it backs the returned line and all scratch.
        /// `state_gpa` backs everything the cache and the caller's font
        /// state keep, and must outlive the call.
        ///
        /// `provider` supplies, by comptime duck typing:
        ///   coversCodepoint(cp: u21) bool
        ///   fontForCodepoint(state_gpa, cp: u21) ?FontKey
        ///   ensureFont(state_gpa, key: FontKey) !parsing.Font
        ///   fontIndexForKey(key: FontKey) ?u16
        ///   toPixels(font_index: u16, font_units: i32) f32
        ///   noteMissingCoverage(state_gpa, cp: u21) void
        pub fn shapeLine(
            self: *Self,
            output: std.mem.Allocator,
            state_gpa: std.mem.Allocator,
            provider: anytype,
            font_key: FontKey,
            fonts: []const root.parsing.Font,
            font_keys: []const FontKey,
            text: []const u8,
            item: ?Buffer.ByteRange,
            base_direction: unicode.Bidi.ParagraphDirection,
            style: Style,
        ) std.mem.Allocator.Error!ShapedLine {
            const has_tab = std.mem.indexOfScalar(u8, text, '\t') != null;
            const cache_key: Key = .{
                .font_key = font_key,
                .text = text,
                .item = item,
                .base_direction = base_direction,
                .features = style.features,
                // Tab-free text shapes the same wherever it starts, so it keeps one key.
                .tab = if (has_tab) .{ .size = style.tab_size, .origin_bits = @bitCast(style.tab_origin) } else null,
            };
            if (self.getPtr(cache_key)) |cached| {
                if (try self.materialize(output, cached, provider)) |line| return line;
                // A segment's font is gone since this line was cached, so
                // the cached line is now unrenderable as-is: drop it and
                // reshape from scratch rather than silently rendering with
                // missing segments.
                self.remove(state_gpa, cache_key);
            }

            const decoded = try decodeLine(output, text);
            var line_codepoints = decoded.codepoints;
            var line_byte_offsets = decoded.byte_offsets;
            errdefer output.free(line_codepoints);
            errdefer output.free(line_byte_offsets);

            // Codepoint range matching `item`'s byte range; the shaper works
            // in codepoint indices. Clamped to what decodeLine produced,
            // which stops at a hard break.
            var item_cp: ?root.Item = null;
            if (item) |it| {
                var cp_start: usize = 0;
                while (cp_start < decoded.codepoints.len and decoded.byte_offsets[cp_start] < it.start) cp_start += 1;
                var cp_end: usize = cp_start;
                while (cp_end < decoded.codepoints.len and decoded.byte_offsets[cp_end] < it.end) cp_end += 1;
                item_cp = .{ .start = cp_start, .end = cp_end };
            }

            const static_fonts = fonts.len;
            var fonts_list: std.ArrayList(root.parsing.Font) = .empty;
            defer fonts_list.deinit(output);
            var keys_list: std.ArrayList(FontKey) = .empty;
            defer keys_list.deinit(output);
            try fonts_list.appendSlice(output, fonts);
            try keys_list.appendSlice(output, font_keys);

            // Ask the provider for each newly-uncovered codepoint, skipping
            // any already covered by a font discovered earlier in this same
            // line. Uncapped: a CJK web fallback font is split into ~100
            // slices, so a long CJK line can need dozens, and every missing
            // codepoint must reach the provider to be fetched.
            var dynamic_cmaps: std.ArrayList([]const u8) = .empty;
            defer dynamic_cmaps.deinit(output);
            if (static_fonts > 0) {
                for (decoded.codepoints) |cp| {
                    if (provider.coversCodepoint(cp)) continue;
                    var covered = false;
                    for (dynamic_cmaps.items) |cm| {
                        if (root.Cmap.lookup(cm, cp) != null) {
                            covered = true;
                            break;
                        }
                    }
                    if (covered) continue;
                    if (provider.fontForCodepoint(state_gpa, cp)) |dyn_key| {
                        var already_added = false;
                        for (keys_list.items[static_fonts..]) |k| {
                            if (FontKey.Context.eql(.{}, k, dyn_key)) {
                                already_added = true;
                                break;
                            }
                        }
                        if (already_added) continue;
                        const dyn_font = provider.ensureFont(state_gpa, dyn_key) catch continue;
                        try fonts_list.append(output, dyn_font);
                        try keys_list.append(output, dyn_key);
                        const cmap = dyn_font.tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
                        if (cmap.len > 0) try dynamic_cmaps.append(output, cmap);
                    } else provider.noteMissingCoverage(state_gpa, cp);
                }
            }

            var result = Buffer.init(output);
            errdefer result.deinit();
            var segments: std.ArrayList(ShapedLine.Segment) = .empty;
            errdefer segments.deinit(output);
            var cache_segments: std.ArrayList(Cached.Segment) = .empty;
            errdefer cache_segments.deinit(output);

            if (decoded.codepoints.len > 0 and fonts_list.items.len > 0) {
                // Bidi outer, font fallback inner, so visual reordering
                // crosses font boundaries. state_gpa backs the plan cache:
                // `output` may be a frame arena, and a cached plan has to
                // outlive the call that built it.
                const shaped = root.shapeBidiParagraphWithFallback(output, fonts_list.items, decoded.codepoints, base_direction, &.{}, &.{}, style.features, item_cp, .{ .cache = &self.plans, .state_allocator = state_gpa }) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => root.BidiFallbackResult{ .buffer = Buffer.init(output), .font_indices = &.{} },
                };
                defer output.free(shaped.font_indices);
                result.deinit();
                result = shaped.buffer;

                // Coalesce consecutive same-font glyphs into segments. One
                // pass: segments name fonts by index, so nothing here holds
                // a caller-side pointer that a later font load could move.
                var g: usize = 0;
                while (g < shaped.font_indices.len) {
                    const fi = shaped.font_indices[g];
                    var h = g + 1;
                    while (h < shaped.font_indices.len and shaped.font_indices[h] == fi) h += 1;
                    try segments.append(output, .{ .font_index = @intCast(fi), .glyph_start = @intCast(g), .glyph_end = @intCast(h) });
                    try cache_segments.append(output, .{ .font_key = keys_list.items[fi], .glyph_start = @intCast(g), .glyph_end = @intCast(h) });
                    g = h;
                }
                if (has_tab) applyTabStops(&result, provider, fonts_list.items, segments.items, decoded.codepoints, style);
            }
            result.have_positions = true;

            // Rebase onto the item: from here on the line reads exactly like
            // a shape of `text[item.start..item.end]` alone -- clusters and
            // byte offsets relative to the item -- so every caller's
            // byte-offset math is unchanged by the context having been there.
            if (item_cp) |it_cp| {
                const it = item.?;
                const new_codepoints = try output.dupe(u21, line_codepoints[it_cp.start..it_cp.end]);
                errdefer output.free(new_codepoints);
                const new_offsets = try output.alloc(u32, it_cp.end - it_cp.start + 1);
                for (new_offsets[0 .. it_cp.end - it_cp.start], line_byte_offsets[it_cp.start..it_cp.end]) |*dst, off| {
                    dst.* = off -| @as(u32, @intCast(it.start));
                }
                new_offsets[it_cp.end - it_cp.start] = line_byte_offsets[it_cp.end] -| @as(u32, @intCast(it.start));
                for (result.info.items) |*info| info.cluster -= @intCast(it_cp.start);
                output.free(line_codepoints);
                output.free(line_byte_offsets);
                line_codepoints = new_codepoints;
                line_byte_offsets = new_offsets;
            }

            const cluster_tables = try result.buildClusterTables(output, line_byte_offsets);
            errdefer output.free(cluster_tables.starts);
            errdefer output.free(cluster_tables.ends);

            const line: ShapedLine = .{
                .allocator = output,
                .codepoints = line_codepoints,
                .byte_offsets = line_byte_offsets,
                .buffer = result,
                .cluster_starts = cluster_tables.starts,
                .cluster_ends = cluster_tables.ends,
                .segments = try segments.toOwnedSlice(output),
            };

            self.store(state_gpa, cache_key, &line, cache_segments.items);
            cache_segments.deinit(output);

            return line;
        }
    };
}

/// What a caller adds to shaping beyond the fonts themselves.
pub const Style = struct {
    features: []const root.Feature = &.{},
    tab_size: u8 = 8,
    /// Device-pixel pen x the text starts at on its line, so tab stops
    /// count from the line start rather than from the text.
    tab_origin: f32 = 0,
};

/// Fonts have no real tab glyph (U+0009 is .notdef or a zero-width
/// control), so each tab becomes the space glyph with whatever advance
/// reaches the next stop, `tab_size` space advances apart from the line
/// start. Stops follow the pen in reading order: an RTL line counts
/// them from its right edge.
/// ponytail: pen positions in a mixed-direction line are visual, so a
/// tab inside its embedded opposite-direction run snaps off the
/// visual pen rather than a per-run one.
fn applyTabStops(
    buffer: *Buffer,
    provider: anytype,
    fonts: []const root.parsing.Font,
    segments: []const ShapedLine.Segment,
    codepoints: []const u21,
    style: Style,
) void {
    const rtl = buffer.isRtl();
    var pen = style.tab_origin;
    for (0..segments.len) |si| {
        const seg = segments[if (rtl) segments.len - 1 - si else si];
        const font = fonts[seg.font_index];
        const space_glyph = root.Cmap.lookup(font.tableData("cmap".*) orelse &.{}, ' ') orelse 0;
        const space_units: i32 = blk: {
            const hhea = root.parsing.Table.hhea.parse(font.tableData("hhea".*) orelse &.{}) catch break :blk 0;
            const hmtx = font.tableData("hmtx".*) orelse break :blk 0;
            break :blk root.parsing.Table.hmtx.metricForGlyph(hmtx, space_glyph, hhea.number_of_h_metrics).advance_width;
        };
        const space_px = provider.toPixels(seg.font_index, space_units);
        for (seg.glyph_start..seg.glyph_end) |k| {
            const g = if (rtl) seg.glyph_end - 1 - (k - seg.glyph_start) else k;
            const info = &buffer.info.items[g];
            const pos = &buffer.pos.items[g];
            if (codepoints[info.cluster] == '\t' and space_px > 0) {
                const stop = space_px * @as(f32, @floatFromInt(style.tab_size));
                var next = if (stop > 0) (@floor(pen / stop) + 1) * stop else pen;
                // CSS: a stop closer than half a space is skipped.
                if (stop > 0 and next - pen < space_px * 0.5) next += stop;
                info.codepoint = space_glyph;
                pos.x_offset = 0;
                pos.x_advance = @intFromFloat(@round((next - pen) * @as(f32, @floatFromInt(space_units)) / space_px));
            }
            pen += provider.toPixels(seg.font_index, pos.x_advance);
        }
    }
}
