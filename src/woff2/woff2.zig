// Derived from brotli-decompressor (BSD-3-Clause) and FreeType (FTL); see THIRD_PARTY_LICENSES.
// Ported from vendor/brotli-decompressor (Brotli decoder) and
// vendor/freetype/src/sfnt/sfwoff2.c (WOFF2 table reconstruction). See
// CLAUDE.md's "port, don't derive" rule and project_woff2_brotli_port_status
// memory for the file-by-file plan.
pub const bit_reader = @import("bit_reader.zig");
pub const prefix = @import("prefix.zig");
pub const dictionary = @import("dictionary.zig");
pub const huffman = @import("huffman.zig");
pub const context = @import("context.zig");
pub const transform = @import("transform.zig");
pub const decode = @import("decode.zig");
pub const reconstruct = @import("reconstruct.zig");
const test_real_woff2 = @import("test_real_woff2.zig");

test {
    _ = bit_reader;
    _ = prefix;
    _ = dictionary;
    _ = huffman;
    _ = context;
    _ = transform;
    _ = decode;
    _ = reconstruct;
    _ = test_real_woff2;
}

const std = @import("std");

test "generated prefix tables: spot-check first/last entries against vendor/brotli-decompressor/src/prefix.rs" {
    try std.testing.expectEqual(prefix.PrefixCodeRange{ .offset = 1, .nbits = 2 }, prefix.block_length_prefix_code[0]);
    try std.testing.expectEqual(prefix.PrefixCodeRange{ .offset = 16625, .nbits = 24 }, prefix.block_length_prefix_code[25]);
    try std.testing.expectEqual(prefix.CmdLutElement{
        .insert_len_extra_bits = 0x00,
        .copy_len_extra_bits = 0x00,
        .distance_code = 0,
        .context = 0x00,
        .insert_len_offset = 0x0000,
        .copy_len_offset = 0x0002,
    }, prefix.cmd_lut[0]);
    try std.testing.expectEqual(prefix.CmdLutElement{
        .insert_len_extra_bits = 0x18,
        .copy_len_extra_bits = 0x18,
        .distance_code = -1,
        .context = 0x03,
        .insert_len_offset = 0x5842,
        .copy_len_offset = 0x0846,
    }, prefix.cmd_lut[703]);
}

test "generated dictionary tables: spot-check against vendor/brotli-decompressor/src/dictionary/mod.rs" {
    try std.testing.expectEqual(@as(u32, 0), dictionary.dictionary_offsets_by_length[0]);
    try std.testing.expectEqual(@as(u32, 122016), dictionary.dictionary_offsets_by_length[24]);
    try std.testing.expectEqual(@as(u8, 0), dictionary.dictionary_size_bits_by_length[0]);
    try std.testing.expectEqual(@as(u8, 5), dictionary.dictionary_size_bits_by_length[24]);
    try std.testing.expectEqual(@as(u8, 4), dictionary.min_dictionary_word_length);
    try std.testing.expectEqual(@as(u8, 24), dictionary.max_dictionary_word_length);
    try std.testing.expectEqualStrings("timedownlifeleft", dictionary.dictionary[0..16]);
    try std.testing.expectEqual(@as(usize, 122784), dictionary.dictionary.len);
}

test "generated context table: spot-check against vendor/brotli-decompressor/src/context.rs" {
    // CONTEXT_LSB6, last byte: identity mod 64.
    try std.testing.expectEqual(@as(u8, 0), context.context_lookup[0][0]);
    try std.testing.expectEqual(@as(u8, 63), context.context_lookup[0][255]);
    // CONTEXT_MSB6, last byte: top 6 bits.
    try std.testing.expectEqual(@as(u8, 0), context.context_lookup[1][0]);
    try std.testing.expectEqual(@as(u8, 63), context.context_lookup[1][255]);
    // CONTEXT_SIGNED table ends in 7 (last entry, byte 255 second-last-byte row).
    try std.testing.expectEqual(@as(u8, 7), context.context_lookup[3][511]);
    try std.testing.expectEqual(4, @typeInfo(context.ContextType).@"enum".fields.len);
}
