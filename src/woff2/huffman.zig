const std = @import("std");

// Ported from vendor/brotli-decompressor/src/huffman/mod.rs. HuffmanTreeGroup
// (the allocator-generic tree-group container) is not ported yet — it isn't
// needed until decode.zig exists to consume it, and this codebase wants
// allocator roles explicit at the call site rather than baked into a struct.
//
// Golden-table tests from huffman/tests.rs (code_length_ht, complex,
// multilevel, singlelevel, simple_0..4 — thousands of lines of literal
// expected-table dumps) are not ported; only the hand-written boundary/guard
// tests are, since those are what exercise the safety checks CLAUDE.md asks
// for on attacker-controlled input. Round-trip decode tests once decode.zig
// exists are the intended coverage for full table correctness.

pub const BROTLI_HUFFMAN_MAX_CODE_LENGTH: comptime_int = 15;
pub const BROTLI_HUFFMAN_MAX_CODE_LENGTHS_SIZE: comptime_int = 704;
pub const BROTLI_HUFFMAN_MAX_TABLE_SIZE: comptime_int = 1080;
pub const BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH: comptime_int = 5;

pub const HuffmanCode = struct {
    value: u16 = 0,
    bits: u8 = 0,
};

const BROTLI_REVERSE_BITS_MAX: comptime_int = 8;
const BROTLI_REVERSE_BITS_BASE: comptime_int = 0;
const BROTLI_REVERSE_BITS_LOWEST: u32 = 1 << (BROTLI_REVERSE_BITS_MAX - 1 + BROTLI_REVERSE_BITS_BASE);

fn u5c(x: i32) u5 {
    return @intCast(x);
}

fn u6c(x: i32) u6 {
    return @intCast(x);
}

// Callers narrow their key with `@truncate(u8, ...)`, sound only because
// BROTLI_REVERSE_BITS_BASE == 0 here: keys accumulate from
// BROTLI_REVERSE_BITS_LOWEST and stay under 1 << BROTLI_REVERSE_BITS_MAX.
fn brotliReverseBits(num: u8) u32 {
    return @bitReverse(num);
}

// Stores code in table[offset], table[offset+step], ..., table[offset+end-step].
// Assumes end is an integer multiple of step. The bounds check on the last
// written index covers the whole loop.
fn replicateValue(table: []HuffmanCode, offset: u32, step: i32, end_in: i32, code: HuffmanCode) bool {
    var end = end_in;
    if (step <= 0 or end <= 0 or @rem(end, step) != 0) return false;
    const last_index: u64 = @as(u64, offset) + @as(u64, @intCast(end - step));
    if (last_index >= table.len) return false;
    while (true) {
        end -= step;
        table[@as(usize, offset) + @as(usize, @intCast(end))] = code;
        if (end == 0) break;
    }
    return true;
}

// Returns the table width of the next 2nd-level table. count is the histogram
// of bit lengths for the remaining symbols, len is the code length of the
// next processed symbol. The scan can run len past the caller's max_length,
// so count may run out underneath it — that's the null case.
fn nextTableBitSize(count: []const u16, len_in: i32, root_bits: i32) ?i32 {
    var len = len_in;
    std.debug.assert(len > root_bits);
    var left: i64 = @as(i64, 1) << u6c(len - root_bits);
    while (len < BROTLI_HUFFMAN_MAX_CODE_LENGTH) {
        if (@as(usize, @intCast(len)) >= count.len) return null;
        left -= count[@intCast(len)];
        if (left <= 0) break;
        len += 1;
        left <<= 1;
    }
    return len - root_bits;
}

// symbol_lists is indexed relative to symbol_lists_offset, and the relative
// index is deliberately negative for the per-length list heads (the
// reference implementation indexes backwards off a raw pointer here).
fn symbolListValue(symbol_lists: []const u16, symbol_lists_offset: usize, relative_index: i32) ?u16 {
    const index: i64 = @as(i64, @intCast(symbol_lists_offset)) + relative_index;
    if (index < 0 or @as(u64, @intCast(index)) >= symbol_lists.len) return null;
    return symbol_lists[@intCast(index)];
}

pub fn brotliBuildCodeLengthsHuffmanTable(table: []HuffmanCode, code_lengths: []const u8, count: []const u16) bool {
    var sorted: [18]i32 = undefined;
    var offset: [BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH + 1]i32 = undefined;
    const table_size: i32 = 1 << BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH;
    if (BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH > BROTLI_REVERSE_BITS_MAX or
        table.len < table_size or
        code_lengths.len < sorted.len or
        count.len <= BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH)
    {
        return false;
    }
    var actual_count = [_]u16{0} ** (BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH + 1);
    for (code_lengths[0..sorted.len]) |code_length| {
        const idx: usize = code_length;
        if (idx >= actual_count.len) return false;
        actual_count[idx] += 1;
    }
    if (!std.mem.eql(u16, actual_count[1..], count[1..actual_count.len])) return false;

    // generate offsets into sorted symbol table by code length
    var symbol: i32 = -1;
    var bits: i32 = 1;
    var b: u32 = 0;
    while (b < BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH) : (b += 1) {
        symbol += count[@intCast(bits)];
        offset[@intCast(bits)] = symbol;
        bits += 1;
    }
    // Symbols with code length 0 are placed after all other symbols.
    offset[0] = 17;

    // sort symbols by length, by symbol order within each length
    symbol = 18;
    while (true) {
        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            symbol -= 1;
            const len_idx: usize = code_lengths[@intCast(symbol)];
            const index = offset[len_idx];
            offset[len_idx] -= 1;
            sorted[@intCast(index)] = symbol;
        }
        if (symbol == 0) break;
    }

    // Special case: all symbols but one have 0 code length.
    if (offset[0] == 0) {
        const code = HuffmanCode{ .bits = 0, .value = @intCast(sorted[0]) };
        for (table[0..@intCast(table_size)]) |*val| val.* = code;
        return true;
    }

    // fill in table
    //
    // The caller only gets here with a complete prefix code (space != 0 is
    // rejected upstream), so the keys below sum to exactly
    // 1 << BROTLI_REVERSE_BITS_MAX and the last one used is 0xFF: truncating
    // `key` to u8 cannot lose bits.
    var key: u32 = 0;
    var key_step: u32 = BROTLI_REVERSE_BITS_LOWEST;
    symbol = 0;
    bits = 1;
    var step: i32 = 2;
    while (true) {
        var code = HuffmanCode{ .bits = @intCast(bits), .value = 0 };
        var bits_count: i32 = count[@intCast(bits)];
        while (bits_count != 0) {
            code.value = @intCast(sorted[@intCast(symbol)]);
            symbol += 1;
            const reversed_key = brotliReverseBits(@truncate(key));
            if (!replicateValue(table, reversed_key, step, table_size, code)) return false;
            key += key_step;
            bits_count -= 1;
        }
        step <<= 1;
        key_step >>= 1;
        bits += 1;
        if (!(bits <= BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH)) break;
    }
    return true;
}

pub fn brotliBuildHuffmanTable(
    root_table: []HuffmanCode,
    root_bits: i32,
    symbol_lists: []const u16,
    symbol_lists_offset: usize,
    count: []u16,
) u32 {
    var code = HuffmanCode{ .bits = 0, .value = 0 };
    var max_length: i32 = -1;

    // Entry preconditions. Everything below derives its index bounds from
    // these plus the max_length check further down: root_bits <= 8 keeps
    // every prefix key under 1 << 8, and max_length < count.len() keeps every
    // code-length index in range.
    if (root_bits <= 0 or
        root_bits > BROTLI_REVERSE_BITS_MAX or
        BROTLI_HUFFMAN_MAX_CODE_LENGTH - root_bits > BROTLI_REVERSE_BITS_MAX or
        symbol_lists_offset >= symbol_lists.len)
    {
        return 0;
    }

    while (true) {
        const v = symbolListValue(symbol_lists, symbol_lists_offset, max_length) orelse return 0;
        if (v != 0xFFFF) break;
        max_length -= 1;
    }
    max_length += BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1;
    // The scan above can walk off the front of symbol_lists' head region,
    // which is the one way max_length ends up negative. Callers may pass a
    // count histogram only as long as the code lengths they used, hence the
    // second bound.
    if (max_length < 0 or @as(usize, @intCast(max_length)) >= count.len) return 0;
    std.debug.assert(max_length <= BROTLI_HUFFMAN_MAX_CODE_LENGTH);

    var table_free_offset: u32 = 0;
    var table_bits: i32 = root_bits;
    var table_size: i32 = @as(i32, 1) << u5c(table_bits);
    var total_size: i32 = table_size;

    // fill in root table
    // reduce the table size to a smaller size if possible, and create the
    // repetitions by copy if possible in the coming loop
    if (table_bits > max_length) {
        table_bits = max_length;
        table_size = @as(i32, 1) << u5c(table_bits);
    }
    var key: u32 = 0;
    var key_step: u32 = BROTLI_REVERSE_BITS_LOWEST;
    var bits: i32 = 1;
    var step: i32 = 2;
    while (true) {
        code.bits = @intCast(bits);
        var symbol: i32 = bits - (BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1);
        var bits_count: i32 = count[@intCast(bits)];
        while (bits_count != 0) {
            symbol = symbolListValue(symbol_lists, symbol_lists_offset, symbol) orelse return 0;
            code.value = @intCast(symbol);
            const reversed_key = brotliReverseBits(@truncate(key));
            if (!replicateValue(root_table, table_free_offset + reversed_key, step, table_size, code)) return 0;
            key += key_step;
            bits_count -= 1;
        }
        step <<= 1;
        key_step >>= 1;
        bits += 1;
        if (!(bits <= table_bits)) break;
    }

    // if root_bits != table_bits we only created one fraction of the table,
    // and need to replicate it now.
    while (total_size != table_size) {
        const base: usize = table_free_offset;
        const size: usize = @intCast(table_size);
        if (base + 2 * size > root_table.len) return 0;
        std.mem.copyForwards(HuffmanCode, root_table[base + size .. base + 2 * size], root_table[base .. base + size]);
        table_size <<= 1;
    }

    // fill in 2nd level tables and add pointers to root table
    key_step = BROTLI_REVERSE_BITS_LOWEST >> u5c(root_bits - 1);
    var sub_key: u32 = BROTLI_REVERSE_BITS_LOWEST << 1;
    var sub_key_step: u32 = BROTLI_REVERSE_BITS_LOWEST;

    step = 2;
    var len: i32 = root_bits + 1;
    while (len <= max_length) {
        var symbol: i32 = len - (BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1);
        while (count[@intCast(len)] != 0) {
            if (sub_key == (BROTLI_REVERSE_BITS_LOWEST << 1)) {
                table_free_offset += @intCast(table_size);
                table_bits = nextTableBitSize(count, len, root_bits) orelse return 0;
                table_size = @as(i32, 1) << u5c(table_bits);
                total_size += table_size;
                sub_key = brotliReverseBits(@truncate(key));
                key += key_step;
                // Checked rather than assumed: this is narrowed into the u16
                // HuffmanCode::value, and sub_key then indexes a write.
                if (sub_key > table_free_offset) return 0;
                const table_value_usize: usize = table_free_offset - sub_key;
                if (table_value_usize > std.math.maxInt(u16)) return 0;
                if (sub_key >= root_table.len) return 0;
                root_table[sub_key].bits = @intCast(table_bits + root_bits);
                root_table[sub_key].value = @intCast(table_value_usize);
                sub_key = 0;
            }
            code.bits = @intCast(len - root_bits);
            symbol = symbolListValue(symbol_lists, symbol_lists_offset, symbol) orelse return 0;
            code.value = @intCast(symbol);
            const reversed_sub_key = brotliReverseBits(@truncate(sub_key));
            if (!replicateValue(root_table, table_free_offset + reversed_sub_key, step, table_size, code)) return 0;
            sub_key += sub_key_step;
            // len <= max_length < count.len(), and the loop condition just
            // read a nonzero count[len].
            count[@intCast(len)] -= 1;
        }
        step <<= 1;
        sub_key_step >>= 1;
        len += 1;
    }
    return @intCast(total_size);
}

pub fn brotliBuildSimpleHuffmanTable(table: []HuffmanCode, root_bits: i32, val: []const u16, num_symbols: u32) u32 {
    if (root_bits <= 0 or root_bits >= 32) return 0;
    // num_symbols is the raw 2-bit field (plus one extra bit when it reads
    // 3), so 0..=4 are the only encodable values.
    const required_symbols: usize = switch (num_symbols) {
        0 => 1,
        1 => 2,
        2, 3 => 3,
        4 => 4,
        else => return 0,
    };
    if (val.len < required_symbols) return 0;
    var table_size: u32 = 1;
    const goal_size: u32 = @as(u32, 1) << u5c(root_bits);
    if (table.len < goal_size) return 0;
    if (num_symbols == 0) {
        table[0].bits = 0;
        table[0].value = val[0];
    } else if (num_symbols == 1) {
        table[0].bits = 1;
        table[1].bits = 1;
        if (val[1] > val[0]) {
            table[0].value = val[0];
            table[1].value = val[1];
        } else {
            table[0].value = val[1];
            table[1].value = val[0];
        }
        table_size = 2;
    } else if (num_symbols == 2) {
        table[0].bits = 1;
        table[0].value = val[0];
        table[2].bits = 1;
        table[2].value = val[0];
        if (val[2] > val[1]) {
            table[1].value = val[1];
            table[3].value = val[2];
        } else {
            table[1].value = val[2];
            table[3].value = val[1];
        }
        table[1].bits = 2;
        table[3].bits = 2;
        table_size = 4;
    } else if (num_symbols == 3) {
        const last: u16 = if (val.len > 3) val[3] else 65535;
        var mval = [4]u16{ val[0], val[1], val[2], last };
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            var k: usize = i + 1;
            while (k < 4) : (k += 1) {
                if (mval[k] < mval[i]) std.mem.swap(u16, &mval[k], &mval[i]);
            }
        }
        for (0..4) |idx| table[idx].bits = 2;
        table[0].value = mval[0];
        table[2].value = mval[1];
        table[1].value = mval[2];
        table[3].value = mval[3];
        table_size = 4;
    } else {
        std.debug.assert(num_symbols == 4);
        var mval = [4]u16{ val[0], val[1], val[2], val[3] };
        if (mval[3] < mval[2]) std.mem.swap(u16, &mval[3], &mval[2]);
        for (0..7) |idx7| {
            table[idx7].value = mval[0];
            table[idx7].bits = @intCast(1 + (idx7 & 1));
        }
        table[1].value = mval[1];
        table[3].value = mval[2];
        table[5].value = mval[1];
        table[7].value = mval[3];
        table[3].bits = 3;
        table[7].bits = 3;
        table_size = 8;
    }
    while (table_size != goal_size) {
        var index: u32 = 0;
        while (index < table_size) : (index += 1) {
            table[table_size + index] = table[index];
        }
        table_size <<= 1;
    }
    return goal_size;
}

test "BrotliBuildSimpleHuffmanTable and BrotliBuildCodeLengthsHuffmanTable reject malformed inputs" {
    var table: [8]HuffmanCode = @splat(HuffmanCode{});
    const values = [_]u16{0} ** 4;
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, 3, &values, 5));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(table[0..4], 3, &values, 4));

    const code_lengths = [_]u8{0} ** 18;
    const count = [_]u16{0} ** 6;
    try std.testing.expect(!brotliBuildCodeLengthsHuffmanTable(&table, &code_lengths, &count));
}

fn guardCode() HuffmanCode {
    return .{ .bits = 1, .value = 7 };
}

test "replicateValue rejects degenerate step and end" {
    var table: [32]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expect(!replicateValue(&table, 0, 0, 8, guardCode())); // step == 0
    try std.testing.expect(!replicateValue(&table, 0, -2, 8, guardCode())); // step < 0
    try std.testing.expect(!replicateValue(&table, 0, 2, 0, guardCode())); // end == 0
    try std.testing.expect(!replicateValue(&table, 0, 2, -4, guardCode())); // end < 0
    try std.testing.expect(!replicateValue(&table, 0, 3, 8, guardCode())); // end % step != 0
    const zeroed: [32]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expectEqualSlices(HuffmanCode, &zeroed, &table);
}

test "replicateValue rejects extent past table" {
    var table: [8]HuffmanCode = @splat(HuffmanCode{});
    // Last index written would be offset + end - step == 2 + 8 - 2 == 8.
    try std.testing.expect(!replicateValue(&table, 2, 2, 8, guardCode()));
    const zeroed: [8]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expectEqualSlices(HuffmanCode, &zeroed, &table);
    // One less, and it just fits.
    try std.testing.expect(replicateValue(&table, 1, 2, 8, guardCode()));
    try std.testing.expectEqual(guardCode(), table[7]);
}

test "nextTableBitSize rejects short count" {
    // The scan runs len up to BROTLI_HUFFMAN_MAX_CODE_LENGTH, past whatever
    // the caller's max_length was, so count can run out underneath it.
    const short = [_]u16{0} ** 10;
    try std.testing.expectEqual(@as(?i32, null), nextTableBitSize(&short, 9, 8));
    const full = [_]u16{0} ** (BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1);
    try std.testing.expect(nextTableBitSize(&full, 9, 8) != null);
}

test "symbolListValue rejects out of range index" {
    const list = [_]u16{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(?u16, null), symbolListValue(&list, 2, -3)); // before the start
    try std.testing.expectEqual(@as(?u16, null), symbolListValue(&list, 2, 2)); // past the end
    try std.testing.expectEqual(@as(?u16, 1), symbolListValue(&list, 2, -2));
    try std.testing.expectEqual(@as(?u16, 4), symbolListValue(&list, 2, 1));
}

test "code lengths table rejects undersized slices" {
    var table: [32]HuffmanCode = @splat(HuffmanCode{});
    const code_lengths = [_]u8{0} ** 18;
    const count = [_]u16{0} ** 6;
    // table shorter than 1 << BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH
    try std.testing.expect(!brotliBuildCodeLengthsHuffmanTable(table[0..31], &code_lengths, &count));
    // fewer than 18 code lengths
    try std.testing.expect(!brotliBuildCodeLengthsHuffmanTable(&table, code_lengths[0..17], &count));
    // histogram too short to index by code length
    try std.testing.expect(!brotliBuildCodeLengthsHuffmanTable(&table, &code_lengths, count[0 .. 6 - 1]));
}

test "code lengths table rejects out of range code length" {
    var table: [32]HuffmanCode = @splat(HuffmanCode{});
    var code_lengths = [_]u8{0} ** 18;
    // 6 is past the end of the length histogram; without this check the sort
    // below would index `offset` out of bounds.
    code_lengths[3] = BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH + 1;
    const count = [_]u16{0} ** 6;
    try std.testing.expect(!brotliBuildCodeLengthsHuffmanTable(&table, &code_lengths, &count));
}

test "code lengths table rejects histogram mismatch" {
    var table: [32]HuffmanCode = @splat(HuffmanCode{});
    var code_lengths = [_]u8{0} ** 18;
    code_lengths[0] = 1;
    code_lengths[1] = 1;
    // The true histogram is count[1] == 2; claiming anything else would send
    // the sort loop outside `sorted`.
    var count = [_]u16{0} ** 6;
    count[1] = 3;
    try std.testing.expect(!brotliBuildCodeLengthsHuffmanTable(&table, &code_lengths, &count));
    count[1] = 2;
    try std.testing.expect(brotliBuildCodeLengthsHuffmanTable(&table, &code_lengths, &count));
}

// A symbol_lists image whose head region (the 16 entries before the offset)
// is all 0xFFFF except for the length the caller wants to report.
fn symbolListsWith(max_len: usize, symbol: u16) struct { list: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1 + 8]u16, offset: usize } {
    var list: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1 + 8]u16 = @splat(0xFFFF);
    const offset = BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1;
    list[offset - (BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1 - max_len)] = symbol;
    return .{ .list = list, .offset = offset };
}

test "build huffman table rejects bad root bits" {
    const built = symbolListsWith(1, 0);
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    var count: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1]u16 = @splat(0);
    count[1] = 2;
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, 0, &built.list, built.offset, &count));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, -1, &built.list, built.offset, &count));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, BROTLI_REVERSE_BITS_MAX + 1, &built.list, built.offset, &count));
    // BROTLI_HUFFMAN_MAX_CODE_LENGTH - root_bits must also fit the reversal.
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, BROTLI_HUFFMAN_MAX_CODE_LENGTH - BROTLI_REVERSE_BITS_MAX - 1, &built.list, built.offset, &count));
}

test "build huffman table rejects offset past symbol lists" {
    const built = symbolListsWith(1, 0);
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    var count: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1]u16 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, 8, &built.list, built.list.len, &count));
}

test "build huffman table rejects head scan underflow" {
    // Every head entry is 0xFFFF, so the scan walks off the front of the
    // slice instead of finding a longest code length.
    const list: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1 + 8]u16 = @splat(0xFFFF);
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    var count: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1]u16 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, 8, &list, 4, &count));
}

test "build huffman table rejects count shorter than max length" {
    const built = symbolListsWith(9, 0);
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    // max_length is 9, so a histogram of 9 entries cannot be indexed by it.
    var count: [9]u16 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, 8, &built.list, built.offset, &count));
}

test "build huffman table rejects undersized root table" {
    const built = symbolListsWith(1, 0);
    var count: [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1]u16 = @splat(0);
    count[1] = 2;
    // root_bits 8 wants a 256-entry root table; give it far less and the
    // replication bounds must reject rather than write past.
    var small: [4]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&small, 8, &built.list, built.offset, &count));
}

// With symbol_lists_offset == BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1, the head
// entry for code length L sits at index L, and each entry chains to the next
// symbol of that length. 0xFFFF means "no symbol of this length".
const GUARD_OFFSET: usize = BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1;

fn guardHeads() [32]u16 {
    return @splat(0xFFFF);
}

fn guardCounts() [BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1]u16 {
    return @splat(0);
}

// root_bits is pinned to 7..=8 by the entry check (both root_bits and
// BROTLI_HUFFMAN_MAX_CODE_LENGTH - root_bits must fit the 8-bit reversal), so
// these all use the real HUFFMAN_TABLE_BITS of 8. A max_length of 9 is then
// what forces a second-level table.
const GUARD_ROOT_BITS: i32 = 8;

test "build huffman table rejects symbol chain leaving the list" {
    // Root table pass: the second symbol of length 1 is chained to via
    // symbol_lists[OFFSET + 100], which is past the end of this list.
    var list = guardHeads();
    list[9] = 0; // longest code length is 9
    list[1] = 100; // ...and the length-1 chain leaves the list
    var count = guardCounts();
    count[1] = 2;
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, GUARD_ROOT_BITS, &list, GUARD_OFFSET, &count));
}

test "build huffman table rejects second level count shorter than the scan" {
    // A second-level table is needed (max_length 9 > root_bits 8), and
    // nextTableBitSize then scans past the end of this 10-entry histogram.
    var list = guardHeads();
    list[9] = 0;
    var count: [10]u16 = @splat(0);
    count[9] = 1;
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, GUARD_ROOT_BITS, &list, GUARD_OFFSET, &count));
}

test "build huffman table rejects second level link past root table" {
    // The link back into the root table is written at root_table[sub_key];
    // an empty root table has nowhere to put it.
    var list = guardHeads();
    list[9] = 0;
    var count = guardCounts();
    count[9] = 1;
    var empty: [0]HuffmanCode = .{};
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&empty, GUARD_ROOT_BITS, &list, GUARD_OFFSET, &count));
}

test "build huffman table rejects second level replicate past table" {
    var list = guardHeads();
    list[9] = 5;
    var count = guardCounts();
    count[9] = 2;
    // One entry is enough for the root link but not for the sub-table, which
    // starts at table_free_offset == 256.
    var table: [1]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, GUARD_ROOT_BITS, &list, GUARD_OFFSET, &count));
}

test "build huffman table rejects second level symbol chain leaving the list" {
    var list = guardHeads();
    list[9] = 100; // chains past the end when the second symbol is fetched
    var count = guardCounts();
    count[9] = 2;
    var table: [BROTLI_HUFFMAN_MAX_TABLE_SIZE]HuffmanCode = @splat(HuffmanCode{});
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(&table, GUARD_ROOT_BITS, &list, GUARD_OFFSET, &count));
}

test "build huffman table rejects second level offset past u16" {
    var list = guardHeads();
    // A self-referential length-9 chain, so symbols never run out.
    list[9] = 9;
    list[GUARD_OFFSET + 9] = 9;
    var count = guardCounts();
    count[9] = std.math.maxInt(u16);
    const table = try std.testing.allocator.alloc(HuffmanCode, @as(usize, 1) << 17);
    defer std.testing.allocator.free(table);
    @memset(table, HuffmanCode{});
    try std.testing.expectEqual(@as(u32, 0), brotliBuildHuffmanTable(table, GUARD_ROOT_BITS, &list, GUARD_OFFSET, &count));
}

test "simple table rejects bad root bits and symbol count" {
    var table: [8]HuffmanCode = @splat(HuffmanCode{});
    const val = [_]u16{0} ** 4;
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, 0, &val, 0));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, -1, &val, 0));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, 32, &val, 0));
    // num_symbols is only 0..=4; 5 and up are rejected by the same match that
    // decides how many entries of `val` are read.
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, 3, &val, 5));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, 3, &val, std.math.maxInt(u32)));
}

test "simple table rejects short val and table" {
    var table: [8]HuffmanCode = @splat(HuffmanCode{});
    const val = [_]u16{0} ** 4;
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, 3, val[0..3], 4));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(&table, 3, val[0..1], 1));
    try std.testing.expectEqual(@as(u32, 0), brotliBuildSimpleHuffmanTable(table[0..7], 3, &val, 4));
}
