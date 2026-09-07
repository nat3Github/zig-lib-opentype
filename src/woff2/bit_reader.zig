const std = @import("std");

// Ported from vendor/brotli-decompressor/src/bit_reader/mod.rs. reg_t is
// hardcoded to u64 (the crate's `reg_t` type alias) since we only target
// 64-bit platforms; the crate's 32-bit reg_t branches are dropped.
const RegT = u64;
const register_bits: u32 = @bitSizeOf(RegT);

const bit_mask_table = [33]u32{
    0x0000,     0x00000001, 0x00000003, 0x00000007, 0x0000000F, 0x0000001F, 0x0000003F, 0x0000007F,
    0x000000FF, 0x000001FF, 0x000003FF, 0x000007FF, 0x00000FFF, 0x00001FFF, 0x00003FFF, 0x00007FFF,
    0x0000FFFF, 0x0001FFFF, 0x0003FFFF, 0x0007FFFF, 0x000FFFFF, 0x001FFFFF, 0x003FFFFF, 0x007FFFFF,
    0x00FFFFFF, 0x01FFFFFF, 0x03FFFFFF, 0x07FFFFFF, 0x0FFFFFFF, 0x1FFFFFFF, 0x3FFFFFFF, 0x7FFFFFFF,
    0xFFFFFFFF,
};

fn bitMask(n: u32) u32 {
    return bit_mask_table[n];
}

pub const BitReader = struct {
    val: RegT = 0,
    bit_pos: u32 = 0,
    next_in: u32 = 0,
    avail_in: u32 = 0,

    pub fn init() BitReader {
        return .{ .val = 0, .bit_pos = register_bits };
    }

    pub fn availableBits(self: BitReader) u32 {
        return register_bits - self.bit_pos;
    }

    pub fn remainingBytes(self: BitReader) u32 {
        return self.avail_in + (self.availableBits() >> 3);
    }

    pub fn checkInputAmount(self: BitReader, num: u32) bool {
        return self.avail_in >= num;
    }

    fn load16LE(input: []const u8, next_in: u32) u16 {
        const i: usize = next_in;
        return @as(u16, input[i]) | (@as(u16, input[i + 1]) << 8);
    }

    fn load32LE(input: []const u8, next_in: u32) u32 {
        const i: usize = next_in;
        return @as(u32, input[i]) | (@as(u32, input[i + 1]) << 8) |
            (@as(u32, input[i + 2]) << 16) | (@as(u32, input[i + 3]) << 24);
    }

    fn load64LE(input: []const u8, next_in: u32) u64 {
        const i: usize = next_in;
        var v: u64 = 0;
        inline for (0..8) |k| v |= @as(u64, input[i + k]) << (8 * k);
        return v;
    }

    // Guarantees at least n_bits valid without knowing n_bits at comptime.
    // avail_in is allowed to underflow (wrap) once the caller has exhausted
    // the real input and is reading only from the padded tail: callers that
    // rely on this (woff2 decode.zig) never consult avail_in for bounds
    // decisions past that point, only next_in/the padded buffer length.
    //
    // Every load is also bounded against `input.len`: without this, a
    // crafted stream that never sets is_last (e.g. a chain of zero-length
    // metadata blocks, each costing as little as 6 bits and producing no
    // output) can walk next_in past the end of the padded buffer before
    // decode.zig's metablock budget guard gets a chance to trip. Skipping
    // the refill once out of bounds just means further reads see stale
    // (already-zero-shifted) bits, which the decoder's existing corruption
    // checks reject.
    pub fn fillBitWindow(self: *BitReader, n_bits: u32, input: []const u8) void {
        if (n_bits <= 8 and self.bit_pos >= 56) {
            if (self.next_in + 8 > input.len) return;
            self.val >>= 56;
            self.bit_pos ^= 56;
            self.val |= load64LE(input, self.next_in) << 8;
            self.avail_in -%= 7;
            self.next_in += 7;
        } else if (n_bits <= 16 and self.bit_pos >= 48) {
            if (self.next_in + 8 > input.len) return;
            self.val >>= 48;
            self.bit_pos ^= 48;
            self.val |= load64LE(input, self.next_in) << 16;
            self.avail_in -%= 6;
            self.next_in += 6;
        } else if (self.bit_pos >= 32) {
            if (self.next_in + 4 > input.len) return;
            self.val >>= 32;
            self.bit_pos ^= 32;
            self.val |= @as(RegT, load32LE(input, self.next_in)) << 32;
            self.avail_in -%= 4;
            self.next_in += 4;
        }
    }

    fn fillBitWindowConst(self: *BitReader, comptime n_bits: u32, input: []const u8) void {
        self.fillBitWindow(n_bits, input);
    }

    // Guarantees only 16 bits, reading at most 4 bytes of input.
    pub fn fillBitWindow16(self: *BitReader, input: []const u8) void {
        self.fillBitWindowConst(17, input);
    }

    pub fn pullByte(self: *BitReader, input: []const u8) bool {
        if (self.avail_in == 0) return false;
        self.val >>= 8;
        self.val |= @as(RegT, input[self.next_in]) << 56;
        self.bit_pos -= 8;
        self.avail_in -= 1;
        self.next_in += 1;
        return true;
    }

    pub fn getBitsUnmasked(self: BitReader) RegT {
        return self.val >> @intCast(self.bit_pos);
    }

    pub fn get16BitsUnmasked(self: *BitReader, input: []const u8) u32 {
        self.fillBitWindowConst(16, input);
        return @truncate(self.getBitsUnmasked());
    }

    pub fn getBits(self: *BitReader, n_bits: u32, input: []const u8) u32 {
        self.fillBitWindow(n_bits, input);
        return @as(u32, @truncate(self.getBitsUnmasked())) & bitMask(n_bits);
    }

    // Tries to peek n_bits without consuming. False if not enough input.
    pub fn safeGetBits(self: *BitReader, n_bits: u32, val: *u32, input: []const u8) bool {
        while (self.availableBits() < n_bits) {
            if (!self.pullByte(input)) return false;
        }
        val.* = @as(u32, @truncate(self.getBitsUnmasked())) & bitMask(n_bits);
        return true;
    }

    pub fn dropBits(self: *BitReader, n_bits: u32) void {
        self.bit_pos += n_bits;
    }

    pub fn unload(self: *BitReader) void {
        const unused_bytes: u32 = self.availableBits() >> 3;
        const unused_bits: u32 = unused_bytes << 3;
        self.avail_in += unused_bytes;
        self.next_in -= unused_bytes;
        if (unused_bits == register_bits) {
            self.val = 0;
        } else {
            self.val <<= @intCast(unused_bits);
        }
        self.bit_pos += unused_bits;
    }

    // Precondition: accumulator already contains at least n_bits.
    pub fn takeBits(self: *BitReader, n_bits: u32, val: *u32) void {
        val.* = @as(u32, @truncate(self.getBitsUnmasked())) & bitMask(n_bits);
        self.dropBits(n_bits);
    }

    // Assumes enough input remains to perform fillBitWindow.
    pub fn readBits(self: *BitReader, n_bits: u32, input: []const u8) u32 {
        var val: u32 = 0;
        self.fillBitWindow(n_bits, input);
        self.takeBits(n_bits, &val);
        return val;
    }

    pub fn readConstantNBits(self: *BitReader, comptime n_bits: u32, input: []const u8) u32 {
        var val: u32 = 0;
        self.fillBitWindowConst(n_bits, input);
        self.takeBits(n_bits, &val);
        return val;
    }

    // Tries to read n_bits and advance. False (state unchanged) if not enough input.
    pub fn safeReadBits(self: *BitReader, n_bits: u32, val: *u32, input: []const u8) bool {
        while (self.availableBits() < n_bits) {
            if (!self.pullByte(input)) return false;
        }
        self.takeBits(n_bits, val);
        return true;
    }

    // Advances to the next byte boundary; false if the skipped padding bits
    // were nonzero (malformed stream).
    pub fn jumpToByteBoundary(self: *BitReader) bool {
        const pad_bits_count: u32 = self.availableBits() & 0x7;
        var pad_bits: u32 = 0;
        if (pad_bits_count != 0) self.takeBits(pad_bits_count, &pad_bits);
        return pad_bits == 0;
    }

    // Copies remaining buffered bytes to dest. num must not exceed remainingBytes().
    pub fn copyBytes(self: *BitReader, dest: []u8, num_in: u32, input: []const u8) void {
        var num = num_in;
        var offset: u32 = 0;
        while (self.availableBits() >= 8 and num > 0) {
            dest[offset] = @truncate(self.getBitsUnmasked());
            self.dropBits(8);
            offset += 1;
            num -= 1;
        }
        var i: u32 = 0;
        while (i < num) : (i += 1) {
            dest[offset + i] = input[self.next_in + i];
        }
        self.avail_in -= num;
        self.next_in += num;
    }

    pub fn warmup(self: *BitReader, input: []const u8) bool {
        if (self.availableBits() == 0 and !self.pullByte(input)) return false;
        return true;
    }
};

test "input range checks the end cursor via avail_in bookkeeping" {
    var br = BitReader{ .val = 0, .bit_pos = 64, .avail_in = 0, .next_in = 0 };
    try std.testing.expect(br.checkInputAmount(0));
    try std.testing.expect(!br.checkInputAmount(1));
}

test "warmup pulls one byte and shifts it into the top" {
    const data = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x21, 0xfd, 0xff, 0x87, 0x03, 0x6c, 0x63, 0x90, 0xde, 0xe9, 0x36, 0x04, 0xf8, 0x89, 0xb4, 0x4d, 0x57, 0x96, 0x51, 0x0a, 0x54, 0xb7, 0x54, 0xee, 0xf4, 0xdc, 0xa0, 0x05, 0x9b, 0xd2, 0x2b, 0x30, 0x8f };
    var br = BitReader{ .val = 0x0, .bit_pos = 64, .avail_in = 33, .next_in = 4 };
    const ret = br.pullByte(&data);
    try std.testing.expect(ret);
    try std.testing.expectEqual(@as(u64, 0x2100000000000000), br.val);
    try std.testing.expectEqual(@as(u32, 56), br.bit_pos);
    try std.testing.expectEqual(@as(u32, 32), br.avail_in);
    try std.testing.expectEqual(@as(u32, 5), br.next_in);
}

test "warmup on exhausted input fails without mutating state" {
    const data = [_]u8{ 0xde, 0xad, 0xeb };
    var br = BitReader{ .val = 0x86e884e1ffff577b, .bit_pos = 64, .avail_in = 0, .next_in = 3 };
    const ret = br.pullByte(&data);
    try std.testing.expect(!ret);
    try std.testing.expectEqual(@as(u64, 0x86e884e1ffff577b), br.val);
    try std.testing.expectEqual(@as(u32, 64), br.bit_pos);
    try std.testing.expectEqual(@as(u32, 0), br.avail_in);
    try std.testing.expectEqual(@as(u32, 3), br.next_in);
}

test "safeReadBits: enough bits already buffered" {
    const data = [_]u8{ 0x50, 0x3b, 0xbb, 0x5e, 0xc5, 0x96, 0x81, 0xb7, 0x52, 0x89, 0xea, 0x3d };
    var br = BitReader{ .val = 0xe1e56a736e04fbf5, .bit_pos = 6, .avail_in = 12, .next_in = 0 };
    var val: u32 = 0;
    const ret = br.safeReadBits(7, &val, &data);
    try std.testing.expect(ret);
    try std.testing.expectEqual(@as(u32, 0x6f), val);
    try std.testing.expectEqual(@as(u32, 12), br.avail_in);
    try std.testing.expectEqual(@as(u32, 0), br.next_in);
    try std.testing.expectEqual(@as(u32, 13), br.bit_pos);
}

test "safeReadBits: pulls bytes to satisfy the request" {
    const data = [_]u8{ 0xba, 0xd0, 0xf0, 0x0d, 0xc8, 0xcd, 0xcc };
    var br = BitReader{ .val = 0x017f115ae26916f0, .bit_pos = 57, .avail_in = 3, .next_in = 4 };
    var val: u32 = 0;
    const ret = br.safeReadBits(15, &val, &data);
    try std.testing.expect(ret);
    try std.testing.expectEqual(@as(u32, 0x6400), val);
    try std.testing.expectEqual(@as(u32, 2), br.avail_in);
    try std.testing.expectEqual(@as(u32, 5), br.next_in);
    try std.testing.expectEqual(@as(u32, 64), br.bit_pos);
}

test "safeReadBits: insufficient input leaves state untouched" {
    const data = [_]u8{ 0xee, 0xee, 0xf0, 0xd5 };
    var br = BitReader{ .val = 0x02f902339697460, .bit_pos = 57, .avail_in = 0, .next_in = 4 };
    var val: u32 = 0x74eca3f0;
    const ret = br.safeReadBits(14, &val, &data);
    try std.testing.expect(!ret);
    try std.testing.expectEqual(@as(u32, 0), br.avail_in);
    try std.testing.expectEqual(@as(u32, 4), br.next_in);
    try std.testing.expectEqual(@as(u32, 57), br.bit_pos);
    try std.testing.expectEqual(@as(u64, 0x02f902339697460), br.val);
    try std.testing.expectEqual(@as(u32, 0x74eca3f0), val);
}

test "readBits fills the window then takes the low bits" {
    const data = [_]u8{ 0xba, 0xaa, 0xad, 0xdd, 0x57, 0x5c, 0xd9, 0xa3, 0x3e, 0xb3, 0x77, 0xe7, 0xa0, 0x1e, 0x09, 0xd3, 0x12, 0xa1, 0x3f, 0xb8, 0x7e, 0x5a, 0x06, 0x86, 0xe5, 0x36, 0xef, 0x9c, 0x9f, 0x6d, 0x9b, 0xcc };
    var br = BitReader{ .val = 0xf5917f07daaaeabb, .bit_pos = 33, .avail_in = 29, .next_in = 3 };
    const ret = br.readBits(8, &data);
    try std.testing.expectEqual(@as(u32, 0x83), ret);
    try std.testing.expectEqual(@as(u32, 9), br.bit_pos);
    try std.testing.expectEqual(@as(u32, 25), br.avail_in);
    try std.testing.expectEqual(@as(u32, 7), br.next_in);
}

test "readBits: request satisfied entirely from the already-buffered window" {
    const data = [_]u8{ 0xba, 0xaa, 0xaa, 0xad, 0x74, 0x40, 0x8e, 0xee, 0xd2, 0x38, 0xf1, 0xf4, 0xf8, 0x1d, 0x9f, 0x24, 0x48, 0x1e, 0x82, 0xce, 0x48, 0x88, 0xd7, 0x25, 0x74, 0xaf, 0xe3, 0xea };
    var br = BitReader{ .val = 0x27e33b2440d3feaf, .bit_pos = 18, .avail_in = 24, .next_in = 4 };
    const ret = br.readBits(15, &data);
    try std.testing.expectEqual(@as(u32, 0x1034), ret);
    try std.testing.expectEqual(@as(u32, 33), br.bit_pos);
    try std.testing.expectEqual(@as(u32, 24), br.avail_in);
    try std.testing.expectEqual(@as(u32, 4), br.next_in);
}

test "readConstantNBits with a comptime bit count" {
    const data = [_]u8{ 0xff, 0x9a, 0xa0, 0xde, 0x50, 0x99, 0x67, 0x67, 0x69, 0x87, 0x0e, 0x69, 0xeb, 0x6a, 0xd1, 0x56, 0xc0, 0x32, 0x96, 0xed, 0x78, 0x0e, 0x19, 0xdd, 0x0b, 0xe8, 0xf8, 0x33, 0x9f, 0xe0, 0x69, 0x55, 0x59, 0x3f, 0x5d, 0xc8 };
    var br = BitReader{ .val = 0x0b3fc441e0181dc4, .bit_pos = 59, .avail_in = 33, .next_in = 1 };
    const ret = br.readConstantNBits(4, &data);
    try std.testing.expectEqual(@as(u32, 0x1), ret);
    try std.testing.expectEqual(@as(u32, 7), br.bit_pos);
    try std.testing.expectEqual(@as(u32, 26), br.avail_in);
    try std.testing.expectEqual(@as(u32, 8), br.next_in);
}

test "get16BitsUnmasked refills to guarantee 16 bits" {
    const data = [_]u8{ 0xf0, 0x0d, 0x7e, 0x18, 0x70, 0x1c, 0x18, 0x57, 0xbd, 0x73, 0x47, 0xc1, 0xb4, 0xf7, 0xe2, 0xbe, 0x17, 0x6e, 0x26, 0x01, 0xb2, 0xd5, 0x55, 0xd8, 0x68, 0x1b, 0xc2, 0x87, 0xb4, 0xb1, 0xd9, 0x42, 0xac, 0x0d, 0x67, 0xb1, 0x93, 0x54, 0x49, 0xa4, 0x69, 0xf8, 0x16, 0x0e, 0x61, 0xb3, 0xdb, 0x98, 0xbb, 0xeb, 0xfa, 0xcb, 0x14, 0xcd, 0x68, 0x77, 0xa1, 0x33, 0x6c, 0x49, 0xfa, 0x35, 0xbb, 0xeb, 0xee, 0x7b, 0xae };
    var br = BitReader{ .val = 0x655b1fe0dd6f1e78, .bit_pos = 63, .avail_in = 65, .next_in = 2 };
    const ret = br.get16BitsUnmasked(&data);
    try std.testing.expectEqual(@as(u32, 0x38e030fc), ret);
    try std.testing.expectEqual(@as(u32, 15), br.bit_pos);
    try std.testing.expectEqual(@as(u32, 59), br.avail_in);
    try std.testing.expectEqual(@as(u32, 8), br.next_in);
}
