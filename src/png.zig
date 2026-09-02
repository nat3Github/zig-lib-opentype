//! Minimal PNG decoder for embedded color-glyph images (`sbix`/`CBDT`
//! `png ` graphic data). Scoped to non-interlaced grayscale/grayscale+
//! alpha/truecolor/truecolor+alpha/indexed (color types 0/2/4/6/3) — the
//! OT spec's PNG restrictions target truecolor+alpha, but real-world CBDT
//! fonts (e.g. Chromium's CBDT test corpus) ship indexed (palette) images,
//! so that's supported too. Indexed images may use bit depth 1/2/4/8;
//! every other color type stays 8-bit-only. 16-bit depth and Adam7
//! interlacing are rejected as unsupported rather than handled.
//!
//! Called from parsing.zig only: PNG bytes here are attacker-controlled
//! (embedded in an untrusted font), so this is parser-trust-boundary code,
//! not renderer code.

const std = @import("std");

pub const DecodeError = error{
    InvalidSignature,
    TruncatedChunk,
    MissingIhdr,
    UnsupportedColorType,
    UnsupportedBitDepth,
    UnsupportedInterlace,
    DimensionsTooLarge,
    ChecksumMismatch,
    ZlibError,
    InvalidFilterType,
    MissingPalette,
    InvalidPaletteIndex,
    OutOfMemory,
};

/// Decoded image, always normalized to 8-bit RGBA regardless of the
/// source PNG's color type (grayscale/gray+alpha/rgb get alpha filled in
/// as opaque or expanded from the source's own alpha channel).
pub const Image = struct {
    width: u32,
    height: u32,
    /// row-major RGBA8, `width * height * 4` bytes, no padding.
    pixels: []u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

// NOTE: caps decoded image dimensions well above any real color-glyph
// strike (largest sbix strikes are a few hundred px) so a crafted IHDR
// can't drive an unbounded allocation; raise if a legitimate strike needs
// more.
const max_dimension = 8192;

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

const ColorType = enum(u8) {
    grayscale = 0,
    truecolor = 2,
    indexed = 3,
    grayscale_alpha = 4,
    truecolor_alpha = 6,
};

fn channelsFor(color_type: ColorType) u8 {
    return switch (color_type) {
        .grayscale, .indexed => 1,
        .truecolor => 3,
        .grayscale_alpha => 2,
        .truecolor_alpha => 4,
    };
}

/// One packed sample from a bit-packed (depth < 8) PNG row: samples are
/// packed MSB-first, left to right, never crossing a byte boundary.
fn packedSampleAt(row: []const u8, index: usize, bit_depth: u8) u8 {
    const samples_per_byte = 8 / bit_depth;
    const byte_index = index / samples_per_byte;
    const bit_offset: u3 = @intCast((samples_per_byte - 1 - index % samples_per_byte) * bit_depth);
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(bit_depth)) - 1);
    return (row[byte_index] >> bit_offset) & mask;
}

fn paletteColor(plte: []const u8, trns: []const u8, index: u8) DecodeError![4]u8 {
    const p = @as(usize, index) * 3;
    if (p + 3 > plte.len) return error.InvalidPaletteIndex;
    const alpha: u8 = if (index < trns.len) trns[index] else 255;
    return .{ plte[p], plte[p + 1], plte[p + 2], alpha };
}

/// `scratch_allocator` backs temp buffers (compressed IDAT bytes,
/// decompressed rows, pre-filter output) freed before this returns;
/// `allocator` backs the returned `Image.pixels`, owned by the caller.
pub fn decode(scratch_allocator: std.mem.Allocator, allocator: std.mem.Allocator, data: []const u8) DecodeError!Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &png_signature)) return error.InvalidSignature;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: ColorType = .truecolor_alpha;
    var seen_ihdr = false;

    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(scratch_allocator);
    var plte_data: []const u8 = &.{};
    var trns_data: []const u8 = &.{};

    while (pos + 8 <= data.len) {
        const length = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 ..][0..4];
        const data_start = pos + 8;
        if (@as(u64, data_start) + length + 4 > data.len) return error.TruncatedChunk;
        const chunk_data = data[data_start..][0..length];

        var crc_hasher = std.hash.Crc32.init();
        crc_hasher.update(chunk_type);
        crc_hasher.update(chunk_data);
        const expected_crc = std.mem.readInt(u32, data[data_start + length ..][0..4], .big);
        if (crc_hasher.final() != expected_crc) return error.ChecksumMismatch;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_data.len < 13) return error.TruncatedChunk;
            width = std.mem.readInt(u32, chunk_data[0..4], .big);
            height = std.mem.readInt(u32, chunk_data[4..8], .big);
            bit_depth = chunk_data[8];
            color_type = switch (chunk_data[9]) {
                0 => .grayscale,
                2 => .truecolor,
                3 => .indexed,
                4 => .grayscale_alpha,
                6 => .truecolor_alpha,
                else => return error.UnsupportedColorType,
            };
            const interlace = chunk_data[12];
            if (color_type == .indexed) {
                if (bit_depth != 1 and bit_depth != 2 and bit_depth != 4 and bit_depth != 8) return error.UnsupportedBitDepth;
            } else if (bit_depth != 8) return error.UnsupportedBitDepth;
            if (interlace != 0) return error.UnsupportedInterlace;
            if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.DimensionsTooLarge;
            seen_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (!seen_ihdr) return error.MissingIhdr;
            plte_data = chunk_data;
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            if (!seen_ihdr) return error.MissingIhdr;
            trns_data = chunk_data;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (!seen_ihdr) return error.MissingIhdr;
            idat.appendSlice(scratch_allocator, chunk_data) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        pos = data_start + length + 4;
    }

    if (!seen_ihdr) return error.MissingIhdr;
    if (color_type == .indexed and plte_data.len == 0) return error.MissingPalette;
    const channels = channelsFor(color_type);

    var in_reader: std.Io.Reader = .fixed(idat.items);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in_reader, .zlib, &decompress_buffer);
    var raw: std.Io.Writer.Allocating = .init(scratch_allocator);
    defer raw.deinit();
    _ = decompress.reader.streamRemaining(&raw.writer) catch return error.ZlibError;

    const bits_per_pixel = @as(usize, bit_depth) * channels;
    const bpp = @max(1, (bits_per_pixel + 7) / 8);
    const stride = (@as(usize, width) * bits_per_pixel + 7) / 8;
    const expected_raw_len = (stride + 1) * height;
    if (raw.written().len < expected_raw_len) return error.ZlibError;

    const unfiltered = scratch_allocator.alloc(u8, stride * height) catch return error.OutOfMemory;
    defer scratch_allocator.free(unfiltered);

    var src_pos: usize = 0;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const filter_type = raw.written()[src_pos];
        src_pos += 1;
        const filtered_row = raw.written()[src_pos..][0..stride];
        src_pos += stride;
        const out_row = unfiltered[row * stride ..][0..stride];
        const prior_row: ?[]const u8 = if (row == 0) null else unfiltered[(row - 1) * stride ..][0..stride];

        var x: usize = 0;
        while (x < stride) : (x += 1) {
            const raw_byte = filtered_row[x];
            const a: u8 = if (x >= bpp) out_row[x - bpp] else 0;
            const b: u8 = if (prior_row) |p| p[x] else 0;
            const c: u8 = if (prior_row != null and x >= bpp) prior_row.?[x - bpp] else 0;
            out_row[x] = switch (filter_type) {
                0 => raw_byte,
                1 => raw_byte +% a,
                2 => raw_byte +% b,
                3 => raw_byte +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => raw_byte +% paeth(a, b, c),
                else => return error.InvalidFilterType,
            };
        }
    }

    const pixels = allocator.alloc(u8, @as(usize, width) * height * 4) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    var py: usize = 0;
    while (py < height) : (py += 1) {
        const pixel_row = unfiltered[py * stride ..][0..stride];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const dst = pixels[(py * @as(usize, width) + x) * 4 ..][0..4];
            if (color_type == .indexed) {
                const index = if (bit_depth == 8) pixel_row[x] else packedSampleAt(pixel_row, x, bit_depth);
                dst.* = try paletteColor(plte_data, trns_data, index);
                continue;
            }
            const src = pixel_row[x * channels ..];
            switch (color_type) {
                .grayscale => dst.* = .{ src[0], src[0], src[0], 255 },
                .grayscale_alpha => dst.* = .{ src[0], src[0], src[0], src[1] },
                .truecolor => dst.* = .{ src[0], src[1], src[2], 255 },
                .truecolor_alpha => dst.* = .{ src[0], src[1], src[2], src[3] },
                .indexed => unreachable,
            }
        }
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}
