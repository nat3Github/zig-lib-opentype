const std = @import("std");
const decode = @import("decode.zig");

const compressed = @embedFile("testdata_compressed.br");
const expected = @embedFile("testdata_expected.bin");

test "decompress: real WOFF2 font compressed table stream" {
    const output = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(output);

    try decode.decompress(std.testing.allocator, compressed, output);
    try std.testing.expectEqualSlices(u8, expected, output);
}

test "decompress: random corruption never panics" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    var buf: [compressed.len]u8 = undefined;
    var iter: usize = 0;
    while (iter < 500) : (iter += 1) {
        @memcpy(&buf, compressed);
        const num_flips = random.intRangeAtMost(usize, 1, 40);
        var f: usize = 0;
        while (f < num_flips) : (f += 1) {
            const idx = random.intRangeLessThan(usize, 0, buf.len);
            const bit: u3 = @intCast(random.intRangeLessThan(u8, 0, 8));
            buf[idx] ^= (@as(u8, 1) << bit);
        }
        const out_len = random.intRangeAtMost(usize, 0, expected.len + 16);
        const output = try std.testing.allocator.alloc(u8, out_len);
        defer std.testing.allocator.free(output);
        _ = decode.decompress(std.testing.allocator, &buf, output) catch {};
    }
}
