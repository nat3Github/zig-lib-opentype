// Derived from brotli-decompressor (BSD-3-Clause); see THIRD_PARTY_LICENSES.
const std = @import("std");
const table = @import("transform_table.zig");

// Ported from vendor/brotli-decompressor/src/transform.rs. The static tables
// (kPrefixSuffix, kTransforms) live in the generated transform_table.zig;
// this file is the hand-written TransformDictionaryWord/ToUpperCase logic.
//
// The reference impl trusts `dst` to be oversized relative to any
// prefix+word+suffix it could produce and never bounds-checks writes into
// it. `transform` and dictionary word length are both attacker-influenced
// (WOFF2 is parsed from untrusted font bytes), so every write here is
// checked against dst.len instead, returning null on overflow rather than
// matching upstream's implicit "the caller sized this right" assumption.

fn prefixSuffixSlice(id: u8) []const u8 {
    var end: usize = id;
    while (end < table.prefix_suffix.len and table.prefix_suffix[end] != 0) : (end += 1) {}
    return table.prefix_suffix[id..end];
}

// p may extend past the logical end of the copied word into dst's unwritten
// tail (matches upstream, which slices to the end of its scratch buffer) --
// still memory safe since p is dst-bounded, just may read this call's own
// leftover bytes when they're not enough to fetch a needed continuation byte.
fn toUpperCase(p: []u8) ?u2 {
    if (p.len == 0) return null;
    if (p[0] < 0xc0) {
        if (p[0] >= 'a' and p[0] <= 'z') p[0] ^= 32;
        return 1;
    }
    if (p[0] < 0xe0) {
        if (p.len < 2) return null;
        p[1] ^= 32;
        return 2;
    }
    if (p.len < 3) return null;
    p[2] ^= 5;
    return 3;
}

pub fn transformDictionaryWord(dst: []u8, word: []const u8, len_in: i32, transform_index: i32) ?usize {
    if (transform_index < 0 or transform_index >= table.num_transforms) return null;
    const t = table.transforms[@intCast(transform_index)];
    var idx: usize = 0;

    for (prefixSuffixSlice(t.prefix_id)) |b| {
        if (idx >= dst.len) return null;
        dst[idx] = b;
        idx += 1;
    }

    var skip: i32 = if (t.transform < table.kOmitFirst1) 0 else @as(i32, t.transform) - (table.kOmitFirst1 - 1);
    var len = len_in;
    if (skip > len) skip = len;
    if (skip < 0 or @as(usize, @intCast(skip)) > word.len) return null;
    const skipped_word = word[@intCast(skip)..];
    len -= skip;
    if (t.transform <= table.kOmitLast9) len -= @as(i32, t.transform);

    const copy_start = idx;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        if (@as(usize, @intCast(i)) >= skipped_word.len) return null;
        if (idx >= dst.len) return null;
        dst[idx] = skipped_word[@intCast(i)];
        idx += 1;
    }

    if (t.transform == table.kUppercaseFirst) {
        _ = toUpperCase(dst[copy_start..]) orelse return null;
    } else if (t.transform == table.kUppercaseAll) {
        var offset = copy_start;
        var remaining = idx - copy_start;
        while (remaining > 0) {
            const step = toUpperCase(dst[offset..]) orelse return null;
            offset += step;
            remaining -= @min(remaining, step);
        }
    }

    for (prefixSuffixSlice(t.suffix_id)) |b| {
        if (idx >= dst.len) return null;
        dst[idx] = b;
        idx += 1;
    }
    return idx;
}

test "identity transform copies the word verbatim" {
    var dst: [16]u8 = undefined;
    const n = transformDictionaryWord(&dst, "hello", 5, 0).?;
    try std.testing.expectEqualStrings("hello", dst[0..n]);
}

test "uppercase first transform" {
    var dst: [16]u8 = undefined;
    const n = transformDictionaryWord(&dst, "hello", 5, 4).?; // kUppercaseFirst, suffix SP
    try std.testing.expectEqualStrings("Hello ", dst[0..n]);
}

test "uppercase all transform" {
    var dst: [16]u8 = undefined;
    const n = transformDictionaryWord(&dst, "hello", 5, 44).?; // kUppercaseAll, suffix EMPTY
    try std.testing.expectEqualStrings("HELLO", dst[0..n]);
}

test "omit first and omit last transforms" {
    var dst: [16]u8 = undefined;
    const n1 = transformDictionaryWord(&dst, "hello", 5, 3).?; // kOmitFirst1
    try std.testing.expectEqualStrings("ello", dst[0..n1]);
    const n2 = transformDictionaryWord(&dst, "hello", 5, 12).?; // kOmitLast1
    try std.testing.expectEqualStrings("hell", dst[0..n2]);
}

test "prefix and suffix transform" {
    var dst: [16]u8 = undefined;
    const n = transformDictionaryWord(&dst, "the", 3, 2).?; // prefix SP, suffix SP
    try std.testing.expectEqualStrings(" the ", dst[0..n]);
}

test "rejects out of range transform index" {
    var dst: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), transformDictionaryWord(&dst, "hello", 5, -1));
    try std.testing.expectEqual(@as(?usize, null), transformDictionaryWord(&dst, "hello", 5, table.num_transforms));
}

test "rejects dst too small for prefix" {
    var dst: [0]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), transformDictionaryWord(&dst, "hello", 5, 2)); // prefix SP
}

test "rejects dst too small for word body" {
    var dst: [3]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), transformDictionaryWord(&dst, "hello", 5, 0));
}

test "rejects dst too small for suffix" {
    var dst: [5]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), transformDictionaryWord(&dst, "hello", 5, 1)); // suffix SP
}

test "omit count exceeding word length yields empty body without underflow" {
    var dst: [16]u8 = undefined;
    // kOmitLast9 applied to a 3-byte word: len -= 9 goes negative in the
    // reference i32 arithmetic, which just means the copy loop never runs.
    const n = transformDictionaryWord(&dst, "abc", 3, 64).?; // kOmitLast9
    try std.testing.expectEqualStrings("", dst[0..n]);
}

test "skip exceeding word length clamps rather than underflows" {
    var dst: [16]u8 = undefined;
    const n = transformDictionaryWord(&dst, "ab", 2, 34).?; // kOmitFirst4
    try std.testing.expectEqualStrings("", dst[0..n]);
}

test "uppercase first rejects truncated multi-byte lead" {
    var dst: [1]u8 = undefined;
    // 0xc2 announces a 2-byte UTF-8 sequence but dst has no room for the
    // second byte, and the reference impl would read/write past its logical
    // word here -- this must fail closed instead.
    try std.testing.expectEqual(@as(?usize, null), transformDictionaryWord(&dst, &[_]u8{0xc2}, 1, 4));
}
