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
            self.* = undefined;
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
    };
}
