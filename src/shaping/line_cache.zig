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
