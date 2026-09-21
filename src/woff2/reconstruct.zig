// Derived from FreeType (FTL); see THIRD_PARTY_LICENSES.
const std = @import("std");
const Allocator = std.mem.Allocator;
const decode_mod = @import("decode.zig");

// Ported from vendor/freetype/src/sfnt/sfwoff2.c: WOFF2 header + table
// directory parsing, and the glyf/loca/hmtx reconstruction transforms.
// Brotli decompression itself lives in decode.zig.
//
// ponytail: TTC (font-collection) WOFF2s are out of scope — sfwoff2.c's
// collection-directory parsing (selecting a sub-table-list per sub-font) has
// no test fixture here and adds a second indexing layer on top of an
// already-large port. Rejected with error.Corrupt instead. Add if a real
// WOFF2 TTC ever needs to load.
//
// Unlike sfwoff2.c we never assemble a real SFNT (header + checksummed table
// directory): the caller (parsing.zig) only wants table bytes addressable by
// tag/offset/length, exactly like the existing WOFF1 path (parseWoff), so
// all of sfwoff2.c's checksum computation, sfnt header synthesis, and
// dest-buffer padding/trimming bookkeeping is dropped.

pub const Error = error{ OutOfMemory, Corrupt };

pub const Table = struct {
    tag: [4]u8,
    offset: u32,
    length: u32,
};

pub const Result = struct {
    data: []u8,
    tables: []Table,
};

const max_uncompressed_size: u32 = 1 << 26; // matches sfwoff2.c's MAX_SFNT_SIZE heuristic

const known_tags = [63][4]u8{
    "cmap".*, "head".*, "hhea".*, "hmtx".*, "maxp".*, "name".*, "OS/2".*, "post".*,
    "cvt ".*, "fpgm".*, "glyf".*, "loca".*, "prep".*, "CFF ".*, "VORG".*, "EBDT".*,
    "EBLC".*, "gasp".*, "hdmx".*, "kern".*, "LTSH".*, "PCLT".*, "VDMX".*, "vhea".*,
    "vmtx".*, "BASE".*, "GDEF".*, "GPOS".*, "GSUB".*, "EBSC".*, "JSTF".*, "MATH".*,
    "CBDT".*, "CBLC".*, "COLR".*, "CPAL".*, "SVG ".*, "sbix".*, "acnt".*, "avar".*,
    "bdat".*, "bloc".*, "bsln".*, "cvar".*, "fdsc".*, "feat".*, "fmtx".*, "fvar".*,
    "gvar".*, "hsty".*, "just".*, "lcar".*, "mort".*, "morx".*, "opbd".*, "prop".*,
    "trak".*, "Zapf".*, "Silf".*, "Glat".*, "Gloc".*, "Feat".*, "Sill".*,
};

fn tagEql(a: [4]u8, b: [4]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readU8(r: *Reader) Error!u8 {
        if (r.pos + 1 > r.data.len) return error.Corrupt;
        defer r.pos += 1;
        return r.data[r.pos];
    }

    fn readU16(r: *Reader) Error!u16 {
        if (r.pos + 2 > r.data.len) return error.Corrupt;
        const v = std.mem.readInt(u16, r.data[r.pos..][0..2], .big);
        r.pos += 2;
        return v;
    }

    fn readU32(r: *Reader) Error!u32 {
        if (r.pos + 4 > r.data.len) return error.Corrupt;
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .big);
        r.pos += 4;
        return v;
    }

    fn skip(r: *Reader, n: usize) Error!void {
        if (r.pos + n > r.data.len) return error.Corrupt;
        r.pos += n;
    }

    fn readBytes(r: *Reader, n: usize) Error![]const u8 {
        if (r.pos + n > r.data.len) return error.Corrupt;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    fn read255UShort(r: *Reader) Error!u16 {
        const code = try r.readU8();
        if (code == 253) return r.readU16();
        if (code == 255) return @as(u16, try r.readU8()) + 253;
        if (code == 254) return @as(u16, try r.readU8()) + 253 * 2;
        return code;
    }

    fn readBase128(r: *Reader) Error!u32 {
        var result: u32 = 0;
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            const code = try r.readU8();
            if (i == 0 and code == 0x80) return error.Corrupt;
            if (result & 0xfe000000 != 0) return error.Corrupt;
            result = (result << 7) | (code & 0x7f);
            if (code & 0x80 == 0) return result;
        }
        return error.Corrupt;
    }
};

fn round4(v: usize) usize {
    return (v + 3) & ~@as(usize, 3);
}

const DirEntry = struct {
    tag: [4]u8,
    transform: bool,
    dst_length: u32,
    src_offset: u32,
    src_length: u32,
};

fn findEntry(entries: []const DirEntry, tag: [4]u8) ?*const DirEntry {
    for (entries) |*e| {
        if (tagEql(e.tag, tag)) return e;
    }
    return null;
}

pub fn parse(alloc: Allocator, bytes: []const u8) Error!Result {
    var r = Reader{ .data = bytes };
    _ = try r.readU32(); // signature; caller already matched "wOF2"
    const flavor = try r.readU32();
    const length = try r.readU32();
    const num_tables = try r.readU16();
    try r.skip(2);
    _ = try r.readU32(); // totalSfntSize: unused, we never synthesize a real sfnt
    const total_compressed_size = try r.readU32();
    try r.skip(4);
    const meta_offset = try r.readU32();
    const meta_length = try r.readU32();
    const meta_orig_length = try r.readU32();
    const priv_offset = try r.readU32();
    const priv_length = try r.readU32();

    if (@as(usize, length) != bytes.len) return error.Corrupt;
    if (num_tables == 0 or num_tables > 0xFFF) return error.Corrupt;
    if (48 + @as(u32, num_tables) * 20 >= length) return error.Corrupt;
    if (meta_offset == 0 and (meta_length != 0 or meta_orig_length != 0)) return error.Corrupt;
    if (meta_length != 0 and meta_orig_length == 0) return error.Corrupt;
    if (meta_offset != 0 and meta_offset >= length) return error.Corrupt;
    if (meta_offset != 0 and length - meta_offset < meta_length) return error.Corrupt;
    if (priv_offset == 0 and priv_length != 0) return error.Corrupt;
    if (priv_offset != 0 and priv_offset >= length) return error.Corrupt;
    if (priv_offset != 0 and length - priv_offset < priv_length) return error.Corrupt;

    var flavor_tag: [4]u8 = undefined;
    std.mem.writeInt(u32, &flavor_tag, flavor, .big);
    if (tagEql(flavor_tag, "ttcf".*)) return error.Corrupt;

    const entries = try alloc.alloc(DirEntry, num_tables);
    defer alloc.free(entries);

    var src_offset: u32 = 0;
    for (entries) |*e| {
        const flag_byte = try r.readU8();
        var tag: [4]u8 = undefined;
        if (flag_byte & 0x3f == 0x3f) {
            tag = (try r.readBytes(4))[0..4].*;
        } else {
            const idx = flag_byte & 0x3f;
            if (idx >= known_tags.len) return error.Corrupt;
            tag = known_tags[idx];
        }
        const xform_version = (flag_byte >> 6) & 0x03;
        const is_glyf_or_loca = tagEql(tag, "glyf".*) or tagEql(tag, "loca".*);
        const transform = if (is_glyf_or_loca) xform_version == 0 else xform_version != 0;

        const dst_length = try r.readBase128();
        var transform_length = dst_length;
        if (transform) {
            transform_length = try r.readBase128();
            if (tagEql(tag, "loca".*) and transform_length != 0) return error.Corrupt;
        }

        const sum = @addWithOverflow(src_offset, transform_length);
        if (sum[1] != 0) return error.Corrupt;

        e.* = .{
            .tag = tag,
            .transform = transform,
            .dst_length = dst_length,
            .src_offset = src_offset,
            .src_length = transform_length,
        };
        src_offset = sum[0];
    }

    const uncompressed_size: u32 = src_offset; // sum of every table's TransformLength, overflow-checked above
    if (uncompressed_size < 1 or uncompressed_size > max_uncompressed_size) return error.Corrupt;

    const compressed_offset = r.pos;
    var file_offset: usize = round4(compressed_offset + total_compressed_size);
    if (file_offset > length) return error.Corrupt;
    if (meta_offset != 0) {
        if (file_offset != meta_offset) return error.Corrupt;
        file_offset = round4(@as(usize, meta_offset) + meta_length);
    }
    if (priv_offset != 0) {
        if (file_offset != priv_offset) return error.Corrupt;
        file_offset = round4(@as(usize, priv_offset) + priv_length);
    }
    if (file_offset != round4(length)) return error.Corrupt;

    std.mem.sort(DirEntry, entries, {}, struct {
        fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
            return std.mem.order(u8, &a.tag, &b.tag) == .lt;
        }
    }.lessThan);
    for (entries[1..], 0..) |e, i| {
        if (tagEql(e.tag, entries[i].tag)) return error.Corrupt;
    }

    if (compressed_offset + @as(usize, total_compressed_size) > bytes.len) return error.Corrupt;
    const compressed = bytes[compressed_offset..][0..@as(usize, total_compressed_size)];

    const uncompressed = try alloc.alloc(u8, uncompressed_size);
    defer alloc.free(uncompressed);
    decode_mod.decompress(alloc, compressed, uncompressed) catch |e| return e;

    return reconstructTables(alloc, entries, uncompressed);
}

fn reconstructTables(alloc: Allocator, entries: []const DirEntry, uncompressed: []const u8) Error!Result {
    const glyf_entry = findEntry(entries, "glyf".*);
    const loca_entry = findEntry(entries, "loca".*);
    if ((glyf_entry == null) != (loca_entry == null)) return error.Corrupt;
    if (glyf_entry != null and glyf_entry.?.transform != loca_entry.?.transform) return error.Corrupt;

    var combined: std.ArrayList(u8) = .empty;
    errdefer combined.deinit(alloc);
    var records: std.ArrayList(Table) = .empty;
    errdefer records.deinit(alloc);

    var num_hmetrics: u16 = 0;
    var have_num_hmetrics = false;
    var glyf_x_mins: ?[]i16 = null;
    defer if (glyf_x_mins) |xm| alloc.free(xm);
    var glyf_num_glyphs: u16 = 0;
    var handled_loca = false;

    for (entries) |entry| {
        if (tagEql(entry.tag, "loca".*) and entry.transform) {
            if (!handled_loca) return error.Corrupt; // glyf ('g') always sorts before loca ('l')
            continue;
        }

        const entry_offset: usize = entry.src_offset;
        const entry_length: usize = entry.src_length;
        if (entry_offset + entry_length > uncompressed.len) return error.Corrupt;

        if (tagEql(entry.tag, "hhea".*)) {
            if (entry.src_length < 36) return error.Corrupt;
            num_hmetrics = std.mem.readInt(u16, uncompressed[entry_offset + 34 ..][0..2], .big);
            have_num_hmetrics = true;
        }

        if (!entry.transform) {
            const offset: u32 = @intCast(combined.items.len);
            try combined.appendSlice(alloc, uncompressed[entry_offset..][0..entry_length]);
            try records.append(alloc, .{ .tag = entry.tag, .offset = offset, .length = entry.src_length });
            continue;
        }

        if (tagEql(entry.tag, "glyf".*)) {
            const glyf_offset: u32 = @intCast(combined.items.len);
            const recon = try reconstructGlyf(alloc, uncompressed, entry, loca_entry.?.dst_length, &combined);
            glyf_x_mins = recon.x_mins;
            glyf_num_glyphs = recon.num_glyphs;
            try records.append(alloc, .{ .tag = entry.tag, .offset = glyf_offset, .length = recon.glyf_length });
            try records.append(alloc, .{ .tag = "loca".*, .offset = glyf_offset + recon.glyf_length, .length = recon.loca_length });
            handled_loca = true;
            continue;
        }

        if (tagEql(entry.tag, "hmtx".*)) {
            if (!have_num_hmetrics) return error.Corrupt;
            var num_glyphs = glyf_num_glyphs;
            var owned_x_mins: ?[]i16 = null;
            defer if (owned_x_mins) |xm| alloc.free(xm);
            const x_mins = glyf_x_mins orelse blk: {
                const gx = try getXMins(alloc, entries, uncompressed);
                owned_x_mins = gx.x_mins;
                num_glyphs = gx.num_glyphs;
                break :blk gx.x_mins;
            };

            const offset: u32 = @intCast(combined.items.len);
            try reconstructHmtx(alloc, uncompressed, entry, num_glyphs, num_hmetrics, x_mins, &combined);
            try records.append(alloc, .{ .tag = entry.tag, .offset = offset, .length = @intCast(combined.items.len - offset) });
            continue;
        }

        return error.Corrupt; // unknown transform
    }

    return .{ .data = try combined.toOwnedSlice(alloc), .tables = try records.toOwnedSlice(alloc) };
}

const Point = struct { x: i32, y: i32, on_curve: bool };

fn withSign(flag: u8, base_val: i32) i32 {
    return if (flag & 1 != 0) base_val else -base_val;
}

fn safeAdd(a: i32, b: i32) Error!i32 {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return error.Corrupt;
    return r[0];
}

// https://www.w3.org/TR/WOFF2/#triplet_decoding
fn tripletDecode(flags: []const u8, in: []const u8, n_points: usize, points: []Point) Error!usize {
    if (n_points > in.len) return error.Corrupt;
    var x: i32 = 0;
    var y: i32 = 0;
    var triplet_index: usize = 0;
    var i: usize = 0;
    while (i < n_points) : (i += 1) {
        var flag = flags[i];
        const on_curve = (flag >> 7) == 0;
        flag &= 0x7f;
        const data_bytes: usize = if (flag < 84) 1 else if (flag < 120) 2 else if (flag < 124) 3 else 4;

        const sum = @addWithOverflow(triplet_index, data_bytes);
        if (sum[1] != 0 or sum[0] > in.len) return error.Corrupt;

        var dx: i32 = 0;
        var dy: i32 = 0;
        if (flag < 10) {
            dy = withSign(flag, (@as(i32, flag & 14) << 7) + in[triplet_index]);
        } else if (flag < 20) {
            dx = withSign(flag, (@as(i32, (flag - 10) & 14) << 7) + in[triplet_index]);
        } else if (flag < 84) {
            const b0: i32 = flag - 20;
            const b1: i32 = in[triplet_index];
            dx = withSign(flag, 1 + (b0 & 0x30) + (b1 >> 4));
            dy = withSign(flag >> 1, 1 + ((b0 & 0x0c) << 2) + (b1 & 0x0f));
        } else if (flag < 120) {
            const b0: i32 = flag - 84;
            dx = withSign(flag, 1 + (@divTrunc(b0, 12) << 8) + in[triplet_index]);
            dy = withSign(flag >> 1, 1 + ((@mod(b0, 12) >> 2) << 8) + in[triplet_index + 1]);
        } else if (flag < 124) {
            const b2: i32 = in[triplet_index + 1];
            dx = withSign(flag, (@as(i32, in[triplet_index]) << 4) + (b2 >> 4));
            dy = withSign(flag >> 1, ((b2 & 0x0f) << 8) + in[triplet_index + 2]);
        } else {
            dx = withSign(flag, (@as(i32, in[triplet_index]) << 8) + in[triplet_index + 1]);
            dy = withSign(flag >> 1, (@as(i32, in[triplet_index + 2]) << 8) + in[triplet_index + 3]);
        }

        triplet_index += data_bytes;
        x = try safeAdd(x, dx);
        y = try safeAdd(y, dy);
        points[i] = .{ .x = x, .y = y, .on_curve = on_curve };
    }
    return triplet_index;
}

const GLYF_ON_CURVE: u8 = 1 << 0;
const GLYF_X_SHORT: u8 = 1 << 1;
const GLYF_Y_SHORT: u8 = 1 << 2;
const GLYF_REPEAT: u8 = 1 << 3;
const GLYF_THIS_X_IS_SAME: u8 = 1 << 4;
const GLYF_THIS_Y_IS_SAME: u8 = 1 << 5;
const GLYF_OVERLAP_SIMPLE: u8 = 1 << 6;

fn appendShortBE(alloc: Allocator, list: *std.ArrayList(u8), v: i32) Error!void {
    const v16: i16 = @truncate(v);
    const u: u16 = @bitCast(v16);
    try list.append(alloc, @intCast(u >> 8));
    try list.append(alloc, @intCast(u & 0xff));
}

fn storePoints(alloc: Allocator, points: []const Point, have_overlap: bool, out: *std.ArrayList(u8)) Error!void {
    var flags_buf: std.ArrayList(u8) = .empty;
    defer flags_buf.deinit(alloc);
    var x_buf: std.ArrayList(u8) = .empty;
    defer x_buf.deinit(alloc);
    var y_buf: std.ArrayList(u8) = .empty;
    defer y_buf.deinit(alloc);

    var last_flag: u8 = 0xFF; // sentinel: real flags never set bit 7 (unused)
    var repeat_count: u8 = 0;
    var last_x: i32 = 0;
    var last_y: i32 = 0;

    for (points, 0..) |p, i| {
        var flag: u8 = if (p.on_curve) GLYF_ON_CURVE else 0;
        if (i == 0 and have_overlap) flag |= GLYF_OVERLAP_SIMPLE;

        const dx = p.x - last_x;
        const dy = p.y - last_y;

        if (dx == 0) {
            flag |= GLYF_THIS_X_IS_SAME;
        } else if (dx > -256 and dx < 256) {
            flag |= GLYF_X_SHORT | (if (dx > 0) GLYF_THIS_X_IS_SAME else 0);
        }

        if (dy == 0) {
            flag |= GLYF_THIS_Y_IS_SAME;
        } else if (dy > -256 and dy < 256) {
            flag |= GLYF_Y_SHORT | (if (dy > 0) GLYF_THIS_Y_IS_SAME else 0);
        }

        if (flag == last_flag and repeat_count != 255) {
            flags_buf.items[flags_buf.items.len - 1] |= GLYF_REPEAT;
            repeat_count += 1;
        } else {
            if (repeat_count != 0) try flags_buf.append(alloc, repeat_count);
            try flags_buf.append(alloc, flag);
            repeat_count = 0;
        }

        last_x = p.x;
        last_y = p.y;
        last_flag = flag;
    }
    if (repeat_count != 0) try flags_buf.append(alloc, repeat_count);

    last_x = 0;
    last_y = 0;
    for (points) |p| {
        const dx = p.x - last_x;
        if (dx == 0) {
            // nothing to write
        } else if (dx > -256 and dx < 256) {
            try x_buf.append(alloc, @intCast(@abs(dx)));
        } else {
            try appendShortBE(alloc, &x_buf, dx);
        }
        last_x += dx;
    }
    for (points) |p| {
        const dy = p.y - last_y;
        if (dy == 0) {
            // nothing to write
        } else if (dy > -256 and dy < 256) {
            try y_buf.append(alloc, @intCast(@abs(dy)));
        } else {
            try appendShortBE(alloc, &y_buf, dy);
        }
        last_y += dy;
    }

    try out.appendSlice(alloc, flags_buf.items);
    try out.appendSlice(alloc, x_buf.items);
    try out.appendSlice(alloc, y_buf.items);
}

fn computeBbox(points: []const Point, out: *std.ArrayList(u8), alloc: Allocator) Error!i16 {
    var x_min: i32 = 0;
    var y_min: i32 = 0;
    var x_max: i32 = 0;
    var y_max: i32 = 0;
    if (points.len > 0) {
        x_min = points[0].x;
        y_min = points[0].y;
        x_max = points[0].x;
        y_max = points[0].y;
    }
    for (points[@min(1, points.len)..]) |p| {
        x_min = @min(x_min, p.x);
        y_min = @min(y_min, p.y);
        x_max = @max(x_max, p.x);
        y_max = @max(y_max, p.y);
    }
    try appendShortBE(alloc, out, x_min);
    try appendShortBE(alloc, out, y_min);
    try appendShortBE(alloc, out, x_max);
    try appendShortBE(alloc, out, y_max);
    return @truncate(x_min);
}

const FLAG_ARG_1_AND_2_ARE_WORDS: u16 = 1 << 0;
const FLAG_WE_HAVE_A_SCALE: u16 = 1 << 3;
const FLAG_MORE_COMPONENTS: u16 = 1 << 5;
const FLAG_WE_HAVE_AN_X_AND_Y_SCALE: u16 = 1 << 6;
const FLAG_WE_HAVE_A_TWO_BY_TWO: u16 = 1 << 7;
const FLAG_WE_HAVE_INSTRUCTIONS: u16 = 1 << 8;

fn compositeGlyphSize(uncompressed: []const u8, start_offset: usize) Error!struct { size: usize, have_instructions: bool } {
    var r = Reader{ .data = uncompressed, .pos = start_offset };
    var have_instructions = false;
    var flags: u16 = FLAG_MORE_COMPONENTS;
    while (flags & FLAG_MORE_COMPONENTS != 0) {
        flags = try r.readU16();
        if (flags & FLAG_WE_HAVE_INSTRUCTIONS != 0) have_instructions = true;
        var arg_size: usize = 2; // glyph index
        arg_size += if (flags & FLAG_ARG_1_AND_2_ARE_WORDS != 0) 4 else 2;
        if (flags & FLAG_WE_HAVE_A_SCALE != 0) {
            arg_size += 2;
        } else if (flags & FLAG_WE_HAVE_AN_X_AND_Y_SCALE != 0) {
            arg_size += 4;
        } else if (flags & FLAG_WE_HAVE_A_TWO_BY_TWO != 0) {
            arg_size += 8;
        }
        try r.skip(arg_size);
    }
    return .{ .size = r.pos - start_offset, .have_instructions = have_instructions };
}

const Substream = struct { start: usize, offset: usize, size: usize };

const N_CONTOUR_STREAM = 0;
const N_POINTS_STREAM = 1;
const FLAG_STREAM = 2;
const GLYPH_STREAM = 3;
const COMPOSITE_STREAM = 4;
const BBOX_STREAM = 5;
const INSTRUCTION_STREAM = 6;
const NUM_SUBSTREAMS = 7;

const HAVE_OVERLAP_SIMPLE_BITMAP: u16 = 0x1;
const CONTOUR_OFFSET_END_POINT = 10;

const GlyfResult = struct {
    glyf_length: u32,
    loca_length: u32,
    x_mins: []i16,
    num_glyphs: u16,
};

fn reconstructGlyf(
    alloc: Allocator,
    uncompressed: []const u8,
    entry: DirEntry,
    expected_loca_dst_length: u32,
    combined: *std.ArrayList(u8),
) Error!GlyfResult {
    const pos: usize = entry.src_offset;
    const transform_length: usize = entry.src_length;
    var hdr = Reader{ .data = uncompressed, .pos = pos };
    try hdr.skip(2);
    const option_flags = try hdr.readU16();
    const num_glyphs = try hdr.readU16();
    const index_format = try hdr.readU16();

    const expected_loca_length: u32 = (if (index_format != 0) @as(u32, 4) else 2) * (@as(u32, num_glyphs) + 1);
    if (expected_loca_dst_length != expected_loca_length) return error.Corrupt;

    var offset: usize = 2 + 2 + 2 + 2 + NUM_SUBSTREAMS * 4;
    if (offset > transform_length) return error.Corrupt;

    var substreams: [NUM_SUBSTREAMS]Substream = undefined;
    for (&substreams) |*s| {
        const size: usize = try hdr.readU32();
        if (size > transform_length - offset) return error.Corrupt;
        s.* = .{ .start = pos + offset, .offset = pos + offset, .size = size };
        offset += size;
    }

    var overlap_bitmap_offset: usize = 0;
    if (option_flags & HAVE_OVERLAP_SIMPLE_BITMAP != 0) {
        const overlap_bitmap_length: usize = (@as(usize, num_glyphs) + 7) >> 3;
        if (overlap_bitmap_length > transform_length - offset) return error.Corrupt;
        overlap_bitmap_offset = pos + offset;
        offset += overlap_bitmap_length;
    }

    const bbox_bitmap_offset = substreams[BBOX_STREAM].offset;
    const bbox_bitmap_length: usize = ((@as(usize, num_glyphs) + 31) >> 5) << 2;
    substreams[BBOX_STREAM].offset += bbox_bitmap_length;

    const x_mins = try alloc.alloc(i16, num_glyphs);
    errdefer alloc.free(x_mins);

    const glyf_start: usize = combined.items.len;
    const loca_values = try alloc.alloc(usize, @as(usize, num_glyphs) + 1);
    defer alloc.free(loca_values);

    var points_size: usize = 0;
    var glyph_buf: std.ArrayList(u8) = .empty;
    defer glyph_buf.deinit(alloc);

    var i: u16 = 0;
    while (i < num_glyphs) : (i += 1) {
        glyph_buf.clearRetainingCapacity();

        const bbox_byte_offset = bbox_bitmap_offset + @as(usize, i >> 3);
        if (bbox_byte_offset >= uncompressed.len) return error.Corrupt;
        const have_bbox = uncompressed[bbox_byte_offset] & (@as(u8, 0x80) >> @intCast(i & 7)) != 0;

        if (substreams[N_CONTOUR_STREAM].offset + 2 > uncompressed.len) return error.Corrupt;
        const n_contours = std.mem.readInt(u16, uncompressed[substreams[N_CONTOUR_STREAM].offset..][0..2], .big);
        substreams[N_CONTOUR_STREAM].offset += 2;

        var x_min: i16 = 0;

        if (n_contours == 0xffff) {
            if (!have_bbox) return error.Corrupt;

            const comp = try compositeGlyphSize(uncompressed, substreams[COMPOSITE_STREAM].offset);
            var instruction_size: usize = 0;
            if (comp.have_instructions) {
                var gr = Reader{ .data = uncompressed, .pos = substreams[GLYPH_STREAM].offset };
                instruction_size = try gr.read255UShort();
                substreams[GLYPH_STREAM].offset = gr.pos;
            }

            try appendShortBE(alloc, &glyph_buf, n_contours);

            if (substreams[BBOX_STREAM].offset + 8 > uncompressed.len) return error.Corrupt;
            x_min = std.mem.readInt(i16, uncompressed[substreams[BBOX_STREAM].offset..][0..2], .big);
            try glyph_buf.appendSlice(alloc, uncompressed[substreams[BBOX_STREAM].offset..][0..8]);
            substreams[BBOX_STREAM].offset += 8;

            if (substreams[COMPOSITE_STREAM].offset + comp.size > uncompressed.len) return error.Corrupt;
            try glyph_buf.appendSlice(alloc, uncompressed[substreams[COMPOSITE_STREAM].offset..][0..comp.size]);
            substreams[COMPOSITE_STREAM].offset += comp.size;

            if (comp.have_instructions) {
                try appendShortBE(alloc, &glyph_buf, @as(i32, @intCast(instruction_size)));
                if (substreams[INSTRUCTION_STREAM].offset + instruction_size > uncompressed.len) return error.Corrupt;
                try glyph_buf.appendSlice(alloc, uncompressed[substreams[INSTRUCTION_STREAM].offset..][0..instruction_size]);
                substreams[INSTRUCTION_STREAM].offset += instruction_size;
            }
        } else if (n_contours > 0) {
            var have_overlap = false;
            if (overlap_bitmap_offset != 0) {
                const overlap_byte_offset = overlap_bitmap_offset + @as(usize, i >> 3);
                if (overlap_byte_offset >= uncompressed.len) return error.Corrupt;
                have_overlap = uncompressed[overlap_byte_offset] & (@as(u8, 0x80) >> @intCast(i & 7)) != 0;
            }

            const n_points_arr = try alloc.alloc(u16, n_contours);
            defer alloc.free(n_points_arr);

            var np_reader = Reader{ .data = uncompressed, .pos = substreams[N_POINTS_STREAM].offset };
            var total_n_points: usize = 0;
            for (n_points_arr) |*np| {
                np.* = try np_reader.read255UShort();
                total_n_points += np.*;
            }
            substreams[N_POINTS_STREAM].offset = np_reader.pos;

            points_size += total_n_points;
            if (points_size > substreams[FLAG_STREAM].size) return error.Corrupt;
            if (total_n_points >= (1 << 27)) return error.Corrupt;

            if (substreams[FLAG_STREAM].offset + total_n_points > uncompressed.len) return error.Corrupt;
            const flags_slice = uncompressed[substreams[FLAG_STREAM].offset..][0..total_n_points];

            if (substreams[GLYPH_STREAM].size < substreams[GLYPH_STREAM].offset - substreams[GLYPH_STREAM].start) {
                return error.Corrupt;
            }
            const triplet_size = substreams[GLYPH_STREAM].size - (substreams[GLYPH_STREAM].offset - substreams[GLYPH_STREAM].start);
            if (substreams[GLYPH_STREAM].offset + triplet_size > uncompressed.len) return error.Corrupt;
            const triplet_buf = uncompressed[substreams[GLYPH_STREAM].offset..][0..triplet_size];

            const points = try alloc.alloc(Point, total_n_points);
            defer alloc.free(points);
            const triplet_bytes_used = try tripletDecode(flags_slice, triplet_buf, total_n_points, points);

            substreams[FLAG_STREAM].offset += total_n_points;
            substreams[GLYPH_STREAM].offset += triplet_bytes_used;

            var gr = Reader{ .data = uncompressed, .pos = substreams[GLYPH_STREAM].offset };
            const instruction_size: usize = try gr.read255UShort();
            substreams[GLYPH_STREAM].offset = gr.pos;

            try appendShortBE(alloc, &glyph_buf, n_contours);

            if (have_bbox) {
                if (substreams[BBOX_STREAM].offset + 8 > uncompressed.len) return error.Corrupt;
                x_min = std.mem.readInt(i16, uncompressed[substreams[BBOX_STREAM].offset..][0..2], .big);
                try glyph_buf.appendSlice(alloc, uncompressed[substreams[BBOX_STREAM].offset..][0..8]);
                substreams[BBOX_STREAM].offset += 8;
            } else {
                x_min = try computeBbox(points, &glyph_buf, alloc);
            }

            var end_point: i32 = -1;
            for (n_points_arr) |np| {
                end_point += np;
                if (end_point >= 65536) return error.Corrupt;
                try appendShortBE(alloc, &glyph_buf, end_point);
            }

            try appendShortBE(alloc, &glyph_buf, @as(i32, @intCast(instruction_size)));
            if (substreams[INSTRUCTION_STREAM].offset + instruction_size > uncompressed.len) return error.Corrupt;
            try glyph_buf.appendSlice(alloc, uncompressed[substreams[INSTRUCTION_STREAM].offset..][0..instruction_size]);
            substreams[INSTRUCTION_STREAM].offset += instruction_size;

            try storePoints(alloc, points, have_overlap, &glyph_buf);
        } else {
            if (have_bbox) return error.Corrupt; // empty glyph must not have an explicit bbox
        }

        loca_values[i] = combined.items.len - glyf_start;
        try combined.appendSlice(alloc, glyph_buf.items);
        while ((combined.items.len - glyf_start) % 4 != 0) try combined.append(alloc, 0);

        x_mins[i] = x_min;
    }

    const glyf_length: u32 = @intCast(combined.items.len - glyf_start);
    loca_values[num_glyphs] = combined.items.len - glyf_start;

    const loca_start: usize = combined.items.len;
    for (loca_values) |v| {
        if (index_format != 0) {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(v), .big);
            try combined.appendSlice(alloc, &tmp);
        } else {
            // Short loca stores offset/2 in a u16, so it can only describe a
            // glyf up to 128KiB — a font declaring indexFormat 0 with more
            // than that is corrupt, not a reason to trap in @intCast.
            if (v >> 1 > std.math.maxInt(u16)) return error.Corrupt;
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, @intCast(v >> 1), .big);
            try combined.appendSlice(alloc, &tmp);
        }
    }
    const loca_length: u32 = @intCast(combined.items.len - loca_start);

    return .{ .glyf_length = glyf_length, .loca_length = loca_length, .x_mins = x_mins, .num_glyphs = num_glyphs };
}

const XMinsResult = struct { x_mins: []i16, num_glyphs: u16 };

fn getXMins(alloc: Allocator, entries: []const DirEntry, uncompressed: []const u8) Error!XMinsResult {
    const maxp_entry = findEntry(entries, "maxp".*) orelse return error.Corrupt;
    const head_entry = findEntry(entries, "head".*) orelse return error.Corrupt;
    const loca_entry = findEntry(entries, "loca".*) orelse return error.Corrupt;
    const glyf_entry = findEntry(entries, "glyf".*) orelse return error.Corrupt;

    const maxp_offset: usize = maxp_entry.src_offset;
    if (maxp_offset + 6 > uncompressed.len) return error.Corrupt;
    const num_glyphs = std.mem.readInt(u16, uncompressed[maxp_offset + 4 ..][0..2], .big);

    const head_offset: usize = head_entry.src_offset;
    if (head_offset + 52 > uncompressed.len) return error.Corrupt;
    const index_format = std.mem.readInt(u16, uncompressed[head_offset + 50 ..][0..2], .big);
    const offset_size: usize = if (index_format != 0) 4 else 2;

    const x_mins = try alloc.alloc(i16, num_glyphs);
    errdefer alloc.free(x_mins);

    var loca_offset: usize = loca_entry.src_offset;
    const glyf_base: usize = glyf_entry.src_offset;
    var gi: u32 = 0;
    while (gi < num_glyphs) : (gi += 1) {
        if (loca_offset + offset_size > uncompressed.len) return error.Corrupt;
        var glyf_offset: usize = undefined;
        if (index_format != 0) {
            glyf_offset = std.mem.readInt(u32, uncompressed[loca_offset..][0..4], .big);
        } else {
            glyf_offset = @as(usize, std.mem.readInt(u16, uncompressed[loca_offset..][0..2], .big)) << 1;
        }
        loca_offset += offset_size;

        glyf_offset += glyf_base;
        if (glyf_offset + 4 > uncompressed.len) return error.Corrupt;
        x_mins[gi] = std.mem.readInt(i16, uncompressed[glyf_offset + 2 ..][0..2], .big);
    }

    return .{ .x_mins = x_mins, .num_glyphs = num_glyphs };
}

fn reconstructHmtx(
    alloc: Allocator,
    uncompressed: []const u8,
    entry: DirEntry,
    num_glyphs: u16,
    num_hmetrics: u16,
    x_mins: []const i16,
    combined: *std.ArrayList(u8),
) Error!void {
    if (entry.src_length < 1) return error.Corrupt;
    const hmtx_offset: usize = entry.src_offset;
    const hmtx_flags = uncompressed[hmtx_offset];
    var r = Reader{ .data = uncompressed, .pos = hmtx_offset + 1 };

    const has_proportional_lsbs = hmtx_flags & 1 == 0;
    const has_monospace_lsbs = hmtx_flags & 2 == 0;
    if (hmtx_flags & 0xFC != 0) return error.Corrupt;
    if (has_proportional_lsbs and has_monospace_lsbs) return error.Corrupt;
    if (num_hmetrics > num_glyphs or num_hmetrics < 1) return error.Corrupt;
    if (num_glyphs != x_mins.len) return error.Corrupt;

    const advance_widths = try alloc.alloc(u16, num_hmetrics);
    defer alloc.free(advance_widths);
    for (advance_widths) |*w| w.* = try r.readU16();

    const lsbs = try alloc.alloc(i16, num_glyphs);
    defer alloc.free(lsbs);
    for (lsbs[0..num_hmetrics], 0..) |*lsb, i| {
        lsb.* = if (has_proportional_lsbs) @bitCast(try r.readU16()) else x_mins[i];
    }
    for (lsbs[num_hmetrics..], num_hmetrics..) |*lsb, i| {
        lsb.* = if (has_monospace_lsbs) @bitCast(try r.readU16()) else x_mins[i];
    }

    for (0..num_glyphs) |i| {
        if (i < num_hmetrics) try appendShortBE(alloc, combined, advance_widths[i]);
        try appendShortBE(alloc, combined, lsbs[i]);
    }
}
