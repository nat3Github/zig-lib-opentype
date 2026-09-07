const std = @import("std");
const bit_reader_mod = @import("bit_reader.zig");
const huffman_mod = @import("huffman.zig");
const prefix_mod = @import("prefix.zig");
const context_mod = @import("context.zig");
const dictionary_mod = @import("dictionary.zig");
const transform_mod = @import("transform.zig");
const transform_table = @import("transform_table.zig");

// Ported from vendor/brotli-decompressor/src/{decode,state}.rs, collapsed to
// a one-shot decoder: freetype's sfwoff2.c only ever calls
// BrotliDecoderDecompress once with the whole input buffer and the exact
// decompressed size known upfront (the WOFF2 table directory gives it), so
// the resumable NeedsMoreInput/NeedsMoreOutput state machine, the Safe*
// bit-reader variants, ring-buffer wraparound, and custom/compound
// dictionaries are all dropped. Output is written directly into the final,
// exactly-sized buffer and doubles as its own LZ77 history; backward copies
// are a plain increasing-index byte loop, which stays correct even when
// distance < length.

const BitReader = bit_reader_mod.BitReader;
const HuffmanCode = huffman_mod.HuffmanCode;
const BROTLI_HUFFMAN_MAX_TABLE_SIZE = huffman_mod.BROTLI_HUFFMAN_MAX_TABLE_SIZE;
const BROTLI_HUFFMAN_MAX_CODE_LENGTH = huffman_mod.BROTLI_HUFFMAN_MAX_CODE_LENGTH;
const BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH = huffman_mod.BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH;
const BROTLI_HUFFMAN_MAX_CODE_LENGTHS_SIZE = huffman_mod.BROTLI_HUFFMAN_MAX_CODE_LENGTHS_SIZE;

pub const Error = error{ OutOfMemory, Corrupt };

const HUFFMAN_TABLE_BITS: u32 = 8;
const HUFFMAN_TABLE_MASK: u32 = 0xff;
const CODE_LENGTH_CODES: usize = 18;
const kCodeLengthCodeOrder = [CODE_LENGTH_CODES]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const kCodeLengthPrefixLength = [16]u8{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
const kCodeLengthPrefixValue = [16]u8{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };
const kDefaultCodeLength: u32 = 8;
const kCodeLengthRepeatCode: u32 = 16;
const kNumLiteralCodes: u32 = 256;
const kNumInsertAndCopyCodes: u32 = 704;
const kNumBlockLengthCodes: u32 = 26;
const kDistanceContextBits: u32 = 2;
const kLiteralContextBits: u32 = 6;
const NUM_DISTANCE_SHORT_CODES: u32 = 16;
const BROTLI_MAX_DISTANCE_BITS: u32 = 24;
const kBrotliWindowGap: i32 = 16;
const kBrotliMaxAllowedDistance: i32 = 0x7FFFFFFC;

fn bitMask(n: u32) u32 {
    if (n == 0) return 0;
    if (n >= 32) return 0xFFFFFFFF;
    return (@as(u32, 1) << @intCast(n)) -% 1;
}

fn log2Floor(x_in: u32) u32 {
    var x = x_in;
    var result: u32 = 0;
    while (x != 0) : (x >>= 1) result += 1;
    return result;
}

fn decodeSymbol(bits: u32, table: []const HuffmanCode, br: *BitReader) u32 {
    var table_index = bits & HUFFMAN_TABLE_MASK;
    var table_element = table[table_index];
    if (table_element.bits > HUFFMAN_TABLE_BITS) {
        const nbits: u32 = table_element.bits - HUFFMAN_TABLE_BITS;
        br.dropBits(HUFFMAN_TABLE_BITS);
        table_index += table_element.value;
        table_element = table[table_index + ((bits >> HUFFMAN_TABLE_BITS) & bitMask(nbits))];
    }
    br.dropBits(table_element.bits);
    return table_element.value;
}

fn readSymbol(table: []const HuffmanCode, br: *BitReader, input: []const u8) u32 {
    return decodeSymbol(br.get16BitsUnmasked(input), table, br);
}

fn readBlockLength(table: []const HuffmanCode, br: *BitReader, input: []const u8) Error!u32 {
    const code = readSymbol(table, br, input);
    if (code >= prefix_mod.block_length_prefix_code.len) return error.Corrupt;
    const range = prefix_mod.block_length_prefix_code[code];
    return @as(u32, range.offset) + br.readBits(range.nbits, input);
}

fn decodeVarLenUint8(br: *BitReader, input: []const u8) u32 {
    if (br.readBits(1, input) == 0) return 0;
    const bits = br.readBits(3, input);
    if (bits == 0) return 1;
    const extra = br.readBits(bits, input);
    return (@as(u32, 1) << @intCast(bits)) + extra;
}

fn decodeWindowBits(br: *BitReader, input: []const u8) Error!u32 {
    if (br.readBits(1, input) == 0) return 16;
    var n = br.readBits(3, input);
    if (n != 0) return 17 + n;
    n = br.readBits(3, input);
    if (n == 1) return error.Corrupt; // large-window brotli unsupported
    if (n != 0) return 8 + n;
    return 17;
}

const MetaBlockHeader = struct {
    is_last: bool,
    is_metadata: bool,
    is_uncompressed: bool,
    len: i32,
};

fn decodeMetaBlockLength(br: *BitReader, input: []const u8) Error!MetaBlockHeader {
    const is_last = br.readBits(1, input) != 0;
    if (is_last) {
        if (br.readBits(1, input) != 0) {
            return .{ .is_last = true, .is_metadata = false, .is_uncompressed = false, .len = 0 };
        }
    }
    const nibble_bits = br.readBits(2, input);
    var len: i32 = 0;
    if (nibble_bits == 3) {
        if (br.readBits(1, input) != 0) return error.Corrupt; // reserved bit
        const size_bytes = br.readBits(2, input);
        if (size_bytes == 0) {
            return .{ .is_last = is_last, .is_metadata = true, .is_uncompressed = false, .len = 0 };
        }
        var i: u32 = 0;
        while (i < size_bytes) : (i += 1) {
            const bits = br.readBits(8, input);
            if (i + 1 == size_bytes and size_bytes > 1 and bits == 0) return error.Corrupt;
            len |= @as(i32, @intCast(bits)) << @intCast(i * 8);
        }
        len += 1;
        return .{ .is_last = is_last, .is_metadata = true, .is_uncompressed = false, .len = len };
    }
    const size_nibbles = nibble_bits + 4;
    var i: u32 = 0;
    while (i < size_nibbles) : (i += 1) {
        const bits = br.readBits(4, input);
        if (i + 1 == size_nibbles and size_nibbles > 4 and bits == 0) return error.Corrupt;
        len |= @as(i32, @intCast(bits)) << @intCast(i * 4);
    }
    var is_uncompressed = false;
    if (!is_last) {
        is_uncompressed = br.readBits(1, input) != 0;
    }
    len += 1;
    return .{ .is_last = is_last, .is_metadata = false, .is_uncompressed = is_uncompressed, .len = len };
}

fn readHuffmanCode(
    alphabet_size_in: u32,
    max_symbol: u32,
    table: []HuffmanCode,
    offset: usize,
    opt_table_size: ?*u32,
    br: *BitReader,
    input: []const u8,
) Error!void {
    if (offset > table.len) return error.Corrupt;
    const alphabet_size = alphabet_size_in & 0x7ff;

    const sub_loop_counter = br.readBits(2, input);
    if (sub_loop_counter == 1) {
        var num_symbols = br.readBits(2, input);
        if (alphabet_size == 0) return error.Corrupt;
        const max_bits = log2Floor(alphabet_size -% 1);
        var symbols: [4]u16 = .{ 0, 0, 0, 0 };
        var idx: u32 = 0;
        while (idx <= num_symbols) : (idx += 1) {
            const v = br.readBits(max_bits, input);
            if (v >= max_symbol) return error.Corrupt;
            symbols[idx] = @intCast(v);
        }
        {
            var a: u32 = 0;
            while (a < num_symbols) : (a += 1) {
                var b = a + 1;
                while (b <= num_symbols) : (b += 1) {
                    if (symbols[a] == symbols[b]) return error.Corrupt;
                }
            }
        }
        if (num_symbols == 3) {
            const extra = br.readBits(1, input);
            num_symbols += extra;
        }
        const table_size = huffman_mod.brotliBuildSimpleHuffmanTable(table[offset..], @intCast(HUFFMAN_TABLE_BITS), symbols[0..], num_symbols);
        if (table_size == 0) return error.Corrupt;
        if (opt_table_size) |ts| ts.* = table_size;
        return;
    }

    // Complex code: decode the code-length code lengths, then the symbol
    // code lengths, then build the real table.
    var space: u32 = 32;
    var num_codes: u32 = 0;
    var code_length_histo: [BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH + 1]u16 = @splat(0);
    var code_length_code_lengths: [CODE_LENGTH_CODES]u8 = @splat(0);

    // The initial 2-bit selector doubles as a skip count here: 0 means no
    // skip, 2/3 mean the encoder omitted that many leading entries of
    // kCodeLengthCodeOrder (their code length is implicitly 0).
    for (kCodeLengthCodeOrder[sub_loop_counter..]) |code_len_idx| {
        const ix = br.getBits(4, input);
        const prefix_len = kCodeLengthPrefixLength[ix];
        br.dropBits(prefix_len);
        const v: u8 = kCodeLengthPrefixValue[ix];
        code_length_code_lengths[code_len_idx] = v;
        if (v != 0) {
            space -%= @as(u32, 32) >> @intCast(v);
            num_codes += 1;
            code_length_histo[v] += 1;
            if (space -% 1 >= 32) break; // space == 0 or wrapped
        }
    }
    if (!(num_codes == 1 or space == 0)) return error.Corrupt;

    var cl_table: [32]HuffmanCode = @splat(HuffmanCode{});
    if (!huffman_mod.brotliBuildCodeLengthsHuffmanTable(&cl_table, &code_length_code_lengths, &code_length_histo)) {
        return error.Corrupt;
    }

    var full_histo: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1]u16 = @splat(0);
    var next_symbol: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1]i32 = undefined;
    var symbol_lists: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1 + BROTLI_HUFFMAN_MAX_CODE_LENGTHS_SIZE]u16 = undefined;
    const symbol_lists_index: i32 = BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1;

    {
        var ii: usize = 0;
        while (ii < BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1) : (ii += 1) {
            next_symbol[ii] = @as(i32, @intCast(ii)) - symbol_lists_index;
            symbol_lists[ii] = 0xFFFF;
        }
    }

    var symbol: u32 = 0;
    var repeat: u32 = 0;
    var space2: u32 = 32768;
    var prev_code_len: u32 = kDefaultCodeLength;
    var repeat_code_len: u32 = 0;

    while (symbol < max_symbol and space2 > 0) {
        br.fillBitWindow16(input);
        const p_index: u32 = @as(u32, @truncate(br.getBitsUnmasked())) & bitMask(BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH);
        const p = cl_table[p_index];
        br.dropBits(p.bits);
        const code_len: u32 = p.value;
        if (code_len < kCodeLengthRepeatCode) {
            repeat = 0;
            if (code_len != 0) {
                const ns = next_symbol[code_len];
                symbol_lists[@intCast(symbol_lists_index + ns)] = @intCast(symbol);
                next_symbol[code_len] = @intCast(symbol);
                prev_code_len = code_len;
                space2 -%= @as(u32, 32768) >> @intCast(code_len);
                full_histo[code_len] += 1;
            }
            symbol += 1;
        } else {
            const extra_bits: u32 = if (code_len == kCodeLengthRepeatCode) 2 else 3;
            const repeat_delta: u32 = @as(u32, @truncate(br.getBitsUnmasked())) & bitMask(extra_bits);
            br.dropBits(extra_bits);

            const new_len: u32 = if (code_len == kCodeLengthRepeatCode) prev_code_len else 0;
            if (repeat_code_len != new_len) {
                repeat = 0;
                repeat_code_len = new_len;
            }
            const old_repeat = repeat;
            if (repeat > 0) {
                repeat -= 2;
                repeat <<= @intCast(extra_bits);
            }
            repeat +%= repeat_delta +% 3;
            const actual_repeat_delta = repeat -% old_repeat;
            if (symbol +% actual_repeat_delta > max_symbol) {
                symbol = max_symbol;
                space2 = 0xFFFFF;
            } else if (repeat_code_len != 0) {
                const last = symbol +% actual_repeat_delta;
                var next = next_symbol[repeat_code_len];
                while (true) {
                    symbol_lists[@intCast(symbol_lists_index + next)] = @intCast(symbol);
                    next = @intCast(symbol);
                    symbol += 1;
                    if (symbol == last) break;
                }
                next_symbol[repeat_code_len] = next;
                space2 -%= actual_repeat_delta << @intCast(15 - repeat_code_len);
                full_histo[repeat_code_len] = @intCast(@as(u32, full_histo[repeat_code_len]) +% actual_repeat_delta);
            } else {
                symbol +%= actual_repeat_delta;
            }
        }
    }
    if (space2 != 0) return error.Corrupt;

    const table_size = huffman_mod.brotliBuildHuffmanTable(
        table[offset..],
        @intCast(HUFFMAN_TABLE_BITS),
        symbol_lists[0..],
        @intCast(symbol_lists_index),
        &full_histo,
    );
    if (table_size == 0) return error.Corrupt;
    if (opt_table_size) |ts| ts.* = table_size;
}

fn inverseMoveToFrontTransform(v: []u8, mtf: *[256]u8, mtf_upper_bound: *u32) void {
    var upper_bound = mtf_upper_bound.*;
    {
        var i: usize = 0;
        while (i <= upper_bound) : (i += 1) mtf[i] = @intCast(i);
    }
    upper_bound = 0;
    for (v) |*vi| {
        var index: i32 = vi.*;
        const value = mtf[@intCast(index)];
        upper_bound |= @as(u32, vi.*);
        vi.* = value;
        if (index <= 0) {
            mtf[0] = 0;
        } else {
            while (true) {
                index -= 1;
                mtf[@intCast(index + 1)] = mtf[@intCast(index)];
                if (index <= 0) break;
            }
        }
        mtf[0] = value;
    }
    mtf_upper_bound.* = upper_bound;
}

const TreeGroup = struct {
    codes: []HuffmanCode,
    htrees: []u32,
    alphabet_size: u32,
    max_symbol: u32,
    num_htrees: u32,

    fn init(arena: std.mem.Allocator, alphabet_size: u32, max_symbol: u32, num_htrees: u32) Error!TreeGroup {
        const codes = try arena.alloc(HuffmanCode, @as(usize, num_htrees) * BROTLI_HUFFMAN_MAX_TABLE_SIZE);
        @memset(codes, HuffmanCode{});
        const htrees = try arena.alloc(u32, num_htrees);
        @memset(htrees, 0);
        return .{ .codes = codes, .htrees = htrees, .alphabet_size = alphabet_size, .max_symbol = max_symbol, .num_htrees = num_htrees };
    }

    fn tree(self: TreeGroup, index: u32) []const HuffmanCode {
        return self.codes[self.htrees[index]..];
    }
};

fn huffmanTreeGroupDecode(group: *TreeGroup, br: *BitReader, input: []const u8) Error!void {
    var offset: u32 = 0;
    var i: u32 = 0;
    while (i < group.num_htrees) : (i += 1) {
        var table_size: u32 = 0;
        try readHuffmanCode(group.alphabet_size, group.max_symbol, group.codes, offset, &table_size, br, input);
        group.htrees[i] = offset;
        offset += table_size;
    }
}

const ContextMapResult = struct { num_htrees: u32, map: []u8 };

fn decodeContextMap(
    arena: std.mem.Allocator,
    context_map_size: u32,
    mtf: *[256]u8,
    mtf_upper_bound: *u32,
    br: *BitReader,
    input: []const u8,
) Error!ContextMapResult {
    const num_htrees = decodeVarLenUint8(br, input) + 1;
    const map = try arena.alloc(u8, context_map_size);
    if (num_htrees <= 1) {
        @memset(map, 0);
        return .{ .num_htrees = num_htrees, .map = map };
    }

    const peek5 = br.getBits(5, input);
    var max_run_length_prefix: u32 = 0;
    if (peek5 & 1 != 0) {
        max_run_length_prefix = (peek5 >> 1) + 1;
        br.dropBits(5);
    } else {
        br.dropBits(1);
    }

    const alphabet = num_htrees + max_run_length_prefix;
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    try readHuffmanCode(alphabet, alphabet, &table, 0, null, br, input);

    var context_index: u32 = 0;
    while (context_index < context_map_size) {
        const code = readSymbol(&table, br, input);
        if (code == 0) {
            map[context_index] = 0;
            context_index += 1;
            continue;
        }
        if (code > max_run_length_prefix) {
            map[context_index] = @intCast(code - max_run_length_prefix);
            context_index += 1;
            continue;
        }
        var reps = br.readBits(code, input);
        reps += @as(u32, 1) << @intCast(code);
        if (context_index + reps > context_map_size) return error.Corrupt;
        var r: u32 = 0;
        while (r < reps) : (r += 1) {
            map[context_index] = 0;
            context_index += 1;
        }
    }

    if (br.readBits(1, input) != 0) {
        inverseMoveToFrontTransform(map, mtf, mtf_upper_bound);
    }
    return .{ .num_htrees = num_htrees, .map = map };
}

const Decoder = struct {
    output: []u8,
    pos: usize,

    max_backward_distance: i32,
    dist_rb: [4]i32,
    dist_rb_idx: i32,
    mtf: [256]u8,
    mtf_upper_bound: u32,

    meta_block_remaining_len: i32 = 0,
    num_block_types: [3]u32,
    block_length: [3]u32,
    block_type_rb: [6]u32,

    context_modes: []const u8 = &.{},
    context_map: []const u8 = &.{},
    dist_context_map: []const u8 = &.{},
    trivial_literal_contexts: [8]u32,

    context_map_slice_index: usize,
    dist_context_map_slice_index: usize,
    literal_htree_index: u8,
    dist_htree_index: u8,
    trivial_literal_context: bool,
    context_lookup: []const u8,
    htree_command_index: u32,

    distance_postfix_bits: u32,
    num_direct_distance_codes: u32,
    distance_postfix_mask: i32,

    distance_code: i32 = 0,
    distance_context: i32 = 0,
    copy_length: i32 = 0,

    fn metablockBegin(self: *Decoder) void {
        self.meta_block_remaining_len = 0;
        self.block_length = .{ 1 << 24, 1 << 24, 1 << 24 };
        self.num_block_types = .{ 1, 1, 1 };
        self.block_type_rb = .{ 1, 0, 1, 0, 1, 0 };
        self.context_map_slice_index = 0;
        self.literal_htree_index = 0;
        self.dist_context_map_slice_index = 0;
        self.dist_htree_index = 0;
        self.context_lookup = context_mod.context_lookup[0][0..];
    }

    fn emitLiteral(self: *Decoder, byte: u8) Error!void {
        if (self.pos >= self.output.len) return error.Corrupt;
        self.output[self.pos] = byte;
        self.pos += 1;
    }
};

fn detectTrivialLiteralBlockTypes(dec: *Decoder) void {
    @memset(&dec.trivial_literal_contexts, 0);
    var i: usize = 0;
    while (i < dec.num_block_types[0]) : (i += 1) {
        const offset = i << @intCast(kLiteralContextBits);
        var err: usize = 0;
        const sample = dec.context_map[offset];
        var j: usize = 0;
        while (j < (@as(usize, 1) << @intCast(kLiteralContextBits))) : (j += 1) {
            err |= @as(usize, dec.context_map[offset + j]) ^ sample;
        }
        if (err == 0) dec.trivial_literal_contexts[i >> 5] |= (@as(u32, 1) << @intCast(i & 31));
    }
}

fn prepareLiteralDecoding(dec: *Decoder) void {
    const block_type: usize = dec.block_type_rb[1];
    const context_offset = block_type << @intCast(kLiteralContextBits);
    dec.context_map_slice_index = context_offset;
    const trivial = dec.trivial_literal_contexts[block_type >> 5];
    dec.trivial_literal_context = ((trivial >> @intCast(block_type & 31)) & 1) != 0;
    dec.literal_htree_index = dec.context_map[dec.context_map_slice_index];
    const context_mode_index: usize = @as(usize, dec.context_modes[block_type]) & 3;
    dec.context_lookup = context_mod.context_lookup[context_mode_index][0..];
}

fn decodeBlockTypeAndLength(dec: *Decoder, block_type_trees: []const HuffmanCode, block_len_trees: []const HuffmanCode, br: *BitReader, input: []const u8, tree_type: usize) Error!void {
    const max_block_type = dec.num_block_types[tree_type];
    if (max_block_type <= 1) return;
    const tree_offset = tree_type * BROTLI_HUFFMAN_MAX_TABLE_SIZE;
    var block_type = readSymbol(block_type_trees[tree_offset..], br, input);
    dec.block_length[tree_type] = try readBlockLength(block_len_trees[tree_offset..], br, input);

    const rb0 = dec.block_type_rb[tree_type * 2];
    const rb1 = dec.block_type_rb[tree_type * 2 + 1];
    if (block_type == 1) {
        block_type = rb1 + 1;
    } else if (block_type == 0) {
        block_type = rb0;
    } else {
        block_type -= 2;
    }
    if (block_type >= max_block_type) block_type -= max_block_type;
    dec.block_type_rb[tree_type * 2] = rb1;
    dec.block_type_rb[tree_type * 2 + 1] = block_type;
}

fn takeDistanceFromRingBuffer(dec: *Decoder) void {
    if (dec.distance_code == 0) {
        dec.dist_rb_idx -= 1;
        dec.distance_code = dec.dist_rb[@intCast(dec.dist_rb_idx & 3)];
        dec.distance_context = 1;
        return;
    }
    const shifted: u32 = @intCast(dec.distance_code << 1); // distance_code in [1,15]
    const shift: u5 = @intCast(shifted);
    const index_offset: i32 = @as(i32, @bitCast(@as(u32, 0xaaafff1b))) >> shift;
    var v: i32 = (dec.dist_rb_idx +% index_offset) & 3;
    dec.distance_code = dec.dist_rb[@intCast(v)];
    v = (@as(i32, @bitCast(@as(u32, 0xfa5fa500))) >> shift) & 3;
    if ((shifted & 0x3) != 0) {
        dec.distance_code +%= v;
    } else {
        dec.distance_code -%= v;
        if (dec.distance_code <= 0) dec.distance_code = 0x7fffffff;
    }
}

fn readCommand(dec: *Decoder, insert_copy_group: TreeGroup, br: *BitReader, input: []const u8, insert_length_out: *i32) Error!void {
    const cmd_code = readSymbol(insert_copy_group.tree(dec.htree_command_index), br, input);
    if (cmd_code >= prefix_mod.cmd_lut.len) return error.Corrupt;
    const v = prefix_mod.cmd_lut[cmd_code];
    dec.distance_code = v.distance_code;
    dec.distance_context = v.context;
    if (dec.dist_context_map_slice_index + @as(usize, v.context) >= dec.dist_context_map.len) return error.Corrupt;
    dec.dist_htree_index = dec.dist_context_map[dec.dist_context_map_slice_index + @as(usize, v.context)];

    var insert_length: i32 = v.insert_len_offset;
    var insert_len_extra: u32 = 0;
    if (v.insert_len_extra_bits != 0) {
        insert_len_extra = br.readBits(v.insert_len_extra_bits, input);
    }
    const copy_length_extra = br.readBits(v.copy_len_extra_bits, input);
    dec.copy_length = @as(i32, @intCast(copy_length_extra)) + @as(i32, v.copy_len_offset);
    if (dec.block_length[1] > 0) dec.block_length[1] -= 1;
    insert_length += @intCast(insert_len_extra);
    insert_length_out.* = insert_length;
}

fn readDistance(dec: *Decoder, distance_group: TreeGroup, br: *BitReader, input: []const u8) void {
    const code = readSymbol(distance_group.tree(dec.dist_htree_index), br, input);
    dec.distance_code = @intCast(code);
    dec.distance_context = 0;
    if (dec.distance_code < NUM_DISTANCE_SHORT_CODES) {
        takeDistanceFromRingBuffer(dec);
        if (dec.block_length[2] > 0) dec.block_length[2] -= 1;
        return;
    }
    var distval: i32 = dec.distance_code -% @as(i32, @intCast(dec.num_direct_distance_codes));
    if (distval >= 0) {
        if (dec.distance_postfix_bits == 0) {
            const nbits: u32 = @intCast((distval >> 1) + 1);
            const offset = ((2 + (distval & 1)) << @intCast(nbits)) -% 4;
            dec.distance_code = @as(i32, @intCast(dec.num_direct_distance_codes)) +% offset +% @as(i32, @intCast(br.readBits(nbits, input)));
        } else {
            const postfix = distval & dec.distance_postfix_mask;
            distval >>= @intCast(dec.distance_postfix_bits);
            const nbits: u32 = @intCast((distval >> 1) + 1);
            const bits = br.readBits(nbits, input);
            const offset = (((distval & 1) +% 2) << @intCast(nbits)) -% 4;
            dec.distance_code = ((offset +% @as(i32, @intCast(bits))) << @intCast(dec.distance_postfix_bits)) +% postfix +% @as(i32, @intCast(dec.num_direct_distance_codes));
        }
    }
    dec.distance_code = dec.distance_code -% @as(i32, @intCast(NUM_DISTANCE_SHORT_CODES)) +% 1;
    if (dec.block_length[2] > 0) dec.block_length[2] -= 1;
}

fn processCommands(
    dec: *Decoder,
    block_type_trees: []const HuffmanCode,
    block_len_trees: []const HuffmanCode,
    literal_group: TreeGroup,
    insert_copy_group: TreeGroup,
    distance_group: TreeGroup,
    br: *BitReader,
    input: []const u8,
) Error!void {
    while (true) {
        if (dec.block_length[1] == 0) {
            try decodeBlockTypeAndLength(dec, block_type_trees, block_len_trees, br, input, 1);
            dec.htree_command_index = dec.block_type_rb[3];
        }

        var insert_length: i32 = 0;
        try readCommand(dec, insert_copy_group, br, input, &insert_length);

        if (insert_length != 0) {
            dec.meta_block_remaining_len -= insert_length;
            var i: i32 = insert_length;
            while (i > 0) : (i -= 1) {
                if (dec.block_length[0] == 0) {
                    try decodeBlockTypeAndLength(dec, block_type_trees, block_len_trees, br, input, 0);
                    prepareLiteralDecoding(dec);
                }
                var literal: u8 = undefined;
                if (dec.trivial_literal_context) {
                    const tree = literal_group.tree(dec.literal_htree_index);
                    literal = @intCast(readSymbol(tree, br, input));
                } else {
                    const p1: usize = if (dec.pos >= 1) dec.output[dec.pos - 1] else 0;
                    const p2: usize = if (dec.pos >= 2) dec.output[dec.pos - 2] else 0;
                    const context: usize = dec.context_lookup[p1] | dec.context_lookup[p2 + 256];
                    if (dec.context_map_slice_index + context >= dec.context_map.len) return error.Corrupt;
                    const tree_idx = dec.context_map[dec.context_map_slice_index + context];
                    const tree = literal_group.tree(tree_idx);
                    literal = @intCast(readSymbol(tree, br, input));
                }
                try dec.emitLiteral(literal);
                if (dec.block_length[0] == 0) return error.Corrupt;
                dec.block_length[0] -= 1;
            }
            if (dec.meta_block_remaining_len <= 0) return;
        }

        // COMMAND_POST_DECODE_LITERALS
        if (dec.distance_code >= 0) {
            const not_distance_code: i32 = if (dec.distance_code != 0) 0 else 1;
            dec.distance_context = not_distance_code;
            dec.dist_rb_idx -= 1;
            dec.distance_code = dec.dist_rb[@intCast(dec.dist_rb_idx & 3)];
        } else {
            if (dec.block_length[2] == 0) {
                try decodeBlockTypeAndLength(dec, block_type_trees, block_len_trees, br, input, 2);
                dec.dist_context_map_slice_index = @as(usize, dec.block_type_rb[5]) << @intCast(kDistanceContextBits);
                const idx = dec.dist_context_map_slice_index + @as(usize, @intCast(dec.distance_context));
                if (idx >= dec.dist_context_map.len) return error.Corrupt;
                dec.dist_htree_index = dec.dist_context_map[idx];
            }
            readDistance(dec, distance_group, br, input);
        }

        const max_distance: i32 = @min(@as(i32, @intCast(@min(dec.pos, std.math.maxInt(i32)))), dec.max_backward_distance);
        const copy_len = dec.copy_length;

        if (dec.distance_code > max_distance) {
            if (dec.distance_code > kBrotliMaxAllowedDistance) return error.Corrupt;
            if (copy_len < dictionary_mod.min_dictionary_word_length or copy_len > dictionary_mod.max_dictionary_word_length) {
                return error.Corrupt;
            }
            const len_idx: usize = @intCast(copy_len);
            var offset: i32 = @intCast(dictionary_mod.dictionary_offsets_by_length[len_idx]);
            const word_id: i32 = dec.distance_code -% max_distance -% 1;
            const shift = dictionary_mod.dictionary_size_bits_by_length[len_idx];
            const mask: i32 = @intCast(bitMask(shift));
            const word_idx = word_id & mask;
            const transform_idx = word_id >> @intCast(shift);
            dec.dist_rb_idx +%= dec.distance_context;
            offset +%= word_idx *% copy_len;
            if (transform_idx < 0 or transform_idx >= transform_table.num_transforms) return error.Corrupt;
            if (offset < 0 or @as(i64, offset) + @as(i64, copy_len) > dictionary_mod.dictionary.len) return error.Corrupt;
            const word = dictionary_mod.dictionary[@intCast(offset)..@intCast(offset + copy_len)];
            var written: usize = @intCast(copy_len);
            if (transform_idx == 0) {
                if (dec.pos + written > dec.output.len) return error.Corrupt;
                @memcpy(dec.output[dec.pos .. dec.pos + written], word);
            } else {
                if (dec.pos > dec.output.len) return error.Corrupt;
                written = transform_mod.transformDictionaryWord(dec.output[dec.pos..], word, copy_len, transform_idx) orelse return error.Corrupt;
            }
            dec.pos += written;
            dec.meta_block_remaining_len -= @intCast(written);
        } else {
            dec.dist_rb[@intCast(dec.dist_rb_idx & 3)] = dec.distance_code;
            dec.dist_rb_idx += 1;
            dec.meta_block_remaining_len -= copy_len;
            if (copy_len < 0) return error.Corrupt;
            const n: usize = @intCast(copy_len);
            if (dec.distance_code <= 0 or @as(usize, @intCast(dec.distance_code)) > dec.pos) return error.Corrupt;
            const dist: usize = @intCast(dec.distance_code);
            if (dec.pos + n > dec.output.len) return error.Corrupt;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                dec.output[dec.pos] = dec.output[dec.pos - dist];
                dec.pos += 1;
            }
        }

        if (dec.meta_block_remaining_len <= 0) return;
    }
}

fn decodeCompressedMetablockBody(dec: *Decoder, arena: std.mem.Allocator, br: *BitReader, input: []const u8, len: i32) Error!void {
    dec.meta_block_remaining_len = len;

    const block_type_trees = try arena.alloc(HuffmanCode, 3 * BROTLI_HUFFMAN_MAX_TABLE_SIZE);
    @memset(block_type_trees, HuffmanCode{});
    const block_len_trees = try arena.alloc(HuffmanCode, 3 * BROTLI_HUFFMAN_MAX_TABLE_SIZE);
    @memset(block_len_trees, HuffmanCode{});

    var tt: usize = 0;
    while (tt < 3) : (tt += 1) {
        dec.num_block_types[tt] = decodeVarLenUint8(br, input) + 1;
        if (dec.num_block_types[tt] >= 2) {
            const tree_offset = tt * BROTLI_HUFFMAN_MAX_TABLE_SIZE;
            const alphabet = dec.num_block_types[tt] + 2;
            try readHuffmanCode(alphabet, alphabet, block_type_trees, tree_offset, null, br, input);
            try readHuffmanCode(kNumBlockLengthCodes, kNumBlockLengthCodes, block_len_trees, tree_offset, null, br, input);
            dec.block_length[tt] = try readBlockLength(block_len_trees[tree_offset..], br, input);
        }
    }

    var bits6 = br.readBits(6, input);
    dec.distance_postfix_bits = bits6 & bitMask(2);
    bits6 >>= 2;
    dec.num_direct_distance_codes = NUM_DISTANCE_SHORT_CODES + (bits6 << @intCast(dec.distance_postfix_bits));
    dec.distance_postfix_mask = @intCast(bitMask(dec.distance_postfix_bits));

    const context_modes = try arena.alloc(u8, dec.num_block_types[0]);
    for (context_modes) |*m| m.* = @intCast(br.readBits(2, input));
    dec.context_modes = context_modes;

    const literal_context_map = try decodeContextMap(arena, dec.num_block_types[0] << @intCast(kLiteralContextBits), &dec.mtf, &dec.mtf_upper_bound, br, input);
    dec.context_map = literal_context_map.map;
    detectTrivialLiteralBlockTypes(dec);

    const num_direct_codes = dec.num_direct_distance_codes - NUM_DISTANCE_SHORT_CODES;
    const num_distance_codes = NUM_DISTANCE_SHORT_CODES + num_direct_codes + (BROTLI_MAX_DISTANCE_BITS << @intCast(dec.distance_postfix_bits + 1));

    const dist_context_map = try decodeContextMap(arena, dec.num_block_types[2] << @intCast(kDistanceContextBits), &dec.mtf, &dec.mtf_upper_bound, br, input);
    dec.dist_context_map = dist_context_map.map;

    var literal_group = try TreeGroup.init(arena, kNumLiteralCodes, kNumLiteralCodes, literal_context_map.num_htrees);
    var insert_copy_group = try TreeGroup.init(arena, kNumInsertAndCopyCodes, kNumInsertAndCopyCodes, dec.num_block_types[1]);
    var distance_group = try TreeGroup.init(arena, num_distance_codes, num_distance_codes, dist_context_map.num_htrees);

    try huffmanTreeGroupDecode(&literal_group, br, input);
    try huffmanTreeGroupDecode(&insert_copy_group, br, input);
    try huffmanTreeGroupDecode(&distance_group, br, input);

    prepareLiteralDecoding(dec);
    dec.dist_context_map_slice_index = 0;
    dec.htree_command_index = 0;

    try processCommands(dec, block_type_trees, block_len_trees, literal_group, insert_copy_group, distance_group, br, input);

    if (dec.meta_block_remaining_len < 0) return error.Corrupt;
}

fn decodeOneMetablock(dec: *Decoder, arena: std.mem.Allocator, br: *BitReader, input: []const u8) Error!bool {
    dec.metablockBegin();
    const header = try decodeMetaBlockLength(br, input);
    if (header.is_metadata or header.is_uncompressed) {
        if (!br.jumpToByteBoundary()) return error.Corrupt;
    }
    if (header.is_metadata) {
        var remaining = header.len;
        while (remaining > 0) : (remaining -= 1) _ = br.readBits(8, input);
    } else if (header.len != 0) {
        if (header.is_uncompressed) {
            if (header.len < 0) return error.Corrupt;
            const n: usize = @intCast(header.len);
            if (n > br.remainingBytes()) return error.Corrupt;
            if (dec.pos + n > dec.output.len) return error.Corrupt;
            br.copyBytes(dec.output[dec.pos..], @intCast(n), input);
            dec.pos += n;
        } else {
            try decodeCompressedMetablockBody(dec, arena, br, input, header.len);
        }
    }
    if (header.is_last) {
        if (!br.jumpToByteBoundary()) return error.Corrupt;
    }
    return header.is_last;
}

/// Decompresses `compressed` (raw brotli stream, as embedded in WOFF2) into
/// `output`, which must be exactly the declared decompressed size.
pub fn decompress(gpa: std.mem.Allocator, compressed: []const u8, output: []u8) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The bit reader's fast paths overread past avail_in; pad so those
    // overreads stay in-bounds. Bookkeeping underflow past this point is
    // harmless since none of the Safe*/CheckInputAmount paths are used.
    const padded = try arena.alloc(u8, compressed.len + 64);
    @memcpy(padded[0..compressed.len], compressed);
    @memset(padded[compressed.len..], 0);

    var br = BitReader.init();
    br.avail_in = @intCast(compressed.len);
    if (!br.warmup(padded)) return error.Corrupt;

    const window_bits = try decodeWindowBits(&br, padded);

    var dec: Decoder = .{
        .output = output,
        .pos = 0,
        .max_backward_distance = (@as(i32, 1) << @intCast(window_bits)) -% kBrotliWindowGap,
        .dist_rb = .{ 16, 15, 11, 4 },
        .dist_rb_idx = 0,
        .mtf = undefined,
        .mtf_upper_bound = 255,
        .num_block_types = .{ 1, 1, 1 },
        .block_length = .{ 1 << 24, 1 << 24, 1 << 24 },
        .block_type_rb = .{ 1, 0, 1, 0, 1, 0 },
        .trivial_literal_contexts = @splat(0),
        .context_map_slice_index = 0,
        .dist_context_map_slice_index = 0,
        .literal_htree_index = 0,
        .dist_htree_index = 0,
        .trivial_literal_context = false,
        .context_lookup = context_mod.context_lookup[0][0..],
        .htree_command_index = 0,
        .distance_postfix_bits = 0,
        .num_direct_distance_codes = 0,
        .distance_postfix_mask = 0,
    };

    // Bounds the number of metablocks: a zero-length metadata block costs as
    // little as 6 bits and produces no output, so without a cap a crafted
    // stream that never sets is_last would loop until fillBitWindow's own
    // input.len guard turns further reads into stale zero bits — a hang,
    // not a crash, but still worth cutting short. The cap is a fixed
    // constant, not derived from an attacker-controlled header field.
    var metablocks: u32 = 0;
    const max_metablocks: u32 = 1 << 20;
    while (true) {
        metablocks += 1;
        if (metablocks > max_metablocks) return error.Corrupt;
        const is_last = try decodeOneMetablock(&dec, arena, &br, padded);
        if (is_last) break;
    }

    if (dec.pos != output.len) return error.Corrupt;
}

test "decompress: known 10x-then-y sequence round trip" {
    // The reference brotli-decompressor's own regression fixture for a tiny
    // stream ("XXXXXXXXXXYYYYYYYYYY", 20 bytes).
    const input = [_]u8{ 0x1b, 0x13, 0x00, 0x00, 0xa4, 0xb0, 0xb2, 0xea, 0x81, 0x47, 0x02, 0x8a };
    var output: [20]u8 = undefined;
    try decompress(std.testing.allocator, &input, &output);
    try std.testing.expectEqualStrings("XXXXXXXXXXYYYYYYYYYY", &output);
}

test "decompress: rejects output size mismatch" {
    const input = [_]u8{ 0x1b, 0x13, 0x00, 0x00, 0xa4, 0xb0, 0xb2, 0xea, 0x81, 0x47, 0x02, 0x8a };
    var output: [19]u8 = undefined;
    try std.testing.expectError(error.Corrupt, decompress(std.testing.allocator, &input, &output));
}
