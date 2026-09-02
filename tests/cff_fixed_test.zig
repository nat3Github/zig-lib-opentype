const std = @import("std");
const cff_hint = @import("opentype").rasterization.cff_hint;
const Fixed = cff_hint.Fixed;
const intToFixed = cff_hint.intToFixed;
const one = cff_hint.one;
const mulFix = cff_hint.mulFix;
const divFix = cff_hint.divFix;
const fixedRound = cff_hint.fixedRound;
const fixedFloor = cff_hint.fixedFloor;
const fixedFraction = cff_hint.fixedFraction;
const fixedToInt = cff_hint.fixedToInt;

test "mulFix matches FT_MulFix on known values" {
    try std.testing.expectEqual(@as(Fixed, one), mulFix(one, one));
    try std.testing.expectEqual(@as(Fixed, intToFixed(6)), mulFix(intToFixed(2), intToFixed(3)));
    try std.testing.expectEqual(@as(Fixed, intToFixed(-6)), mulFix(intToFixed(2), intToFixed(-3)));
    try std.testing.expectEqual(@as(Fixed, intToFixed(-6)), mulFix(intToFixed(-2), intToFixed(3)));
    try std.testing.expectEqual(@as(Fixed, intToFixed(6)), mulFix(intToFixed(-2), intToFixed(-3)));
}

test "divFix matches FT_DivFix on known values" {
    try std.testing.expectEqual(@as(Fixed, intToFixed(2)), divFix(intToFixed(6), intToFixed(3)));
    try std.testing.expectEqual(@as(Fixed, intToFixed(-2)), divFix(intToFixed(6), intToFixed(-3)));
    try std.testing.expectEqual(@as(Fixed, std.math.maxInt(i32)), divFix(intToFixed(1), 0));
    try std.testing.expectEqual(@as(Fixed, -std.math.maxInt(i32)), divFix(intToFixed(-1), 0));
}

test "fixedRound and fixedFraction roundtrip" {
    const x = intToFixed(3) + 0x9000; // 3.5625
    try std.testing.expectEqual(@as(Fixed, intToFixed(4)), fixedRound(x));
    try std.testing.expectEqual(fixedFloor(x) +% fixedFraction(x), x);
}

test "fixedToInt rounds half toward positive infinity (matches FT's unsigned-add-then-shift)" {
    try std.testing.expectEqual(@as(i16, 4), fixedToInt(intToFixed(3) + 0x8000));
    // -3.5 rounds to -3, not -4: `cf2_fixedToInt` does (x+0x8000)>>16 in
    // unsigned arithmetic with no sign correction, so it's round-half-up
    // uniformly, not round-half-away-from-zero.
    try std.testing.expectEqual(@as(i16, -3), fixedToInt(intToFixed(-3) - 0x8000));
}
