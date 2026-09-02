const std = @import("std");
const opentype = @import("opentype");

test "lastLineBreakOpportunity / nextLineBreakOpportunity: adversarial byte offsets never panic" {
    const t = std.testing;
    const gpa = t.allocator;

    // Empty text: nothing to break on, regardless of limit.
    try t.expectEqual(@as(?usize, null), opentype.lastLineBreakOpportunity(gpa, "", 0, .strict, .normal));
    try t.expectEqual(@as(?usize, null), opentype.lastLineBreakOpportunity(gpa, "", 10, .strict, .normal));
    try t.expectEqual(@as(?usize, null), opentype.nextLineBreakOpportunity(gpa, "", 0, .strict, .normal));

    // limit_byte == 0: decode window is empty.
    try t.expectEqual(@as(?usize, null), opentype.lastLineBreakOpportunity(gpa, "hello world", 0, .strict, .normal));

    // limit_byte far past text.len must clamp, not overrun.
    try t.expectEqual(@as(?usize, 6), opentype.lastLineBreakOpportunity(gpa, "hello world", 1000, .strict, .normal));

    // limit_byte landing mid-codepoint (splitting a multi-byte UTF-8
    // sequence) must not panic or read past text.len; the codepoint
    // starting before the limit is still decoded in full (the "look one
    // char further" trick TextLayoutWidget relies on via `end + 1`).
    const multibyte = "a\u{00e9}b"; // 'a', 'é' (2 bytes), 'b'
    var i: usize = 0;
    while (i <= multibyte.len) : (i += 1) {
        _ = opentype.lastLineBreakOpportunity(gpa, multibyte, i, .strict, .normal);
        _ = opentype.nextLineBreakOpportunity(gpa, multibyte, i, .strict, .normal);
    }

    // Invalid UTF-8 mid-string: decode stops there, but must not panic and
    // must not report a break opportunity past the point it gave up.
    const invalid = "abc\xffdef";
    const brk = opentype.lastLineBreakOpportunity(gpa, invalid, invalid.len, .strict, .normal);
    if (brk) |b| try t.expect(b <= 3);

    // after_byte past text.len: must not panic, just find nothing.
    try t.expectEqual(@as(?usize, null), opentype.nextLineBreakOpportunity(gpa, "hello", 1000, .strict, .normal));
}

test "firstHardBreak / trailingHardBreakLen: adversarial bytes never panic" {
    const t = std.testing;
    try t.expectEqual(@as(?opentype.HardBreak, null), opentype.firstHardBreak(""));
    try t.expectEqual(@as(usize, 0), opentype.trailingHardBreakLen(""));

    // Lone continuation bytes (no valid lead byte anywhere): must not panic.
    try t.expectEqual(@as(?opentype.HardBreak, null), opentype.firstHardBreak("\x80\x80\x80"));
    try t.expectEqual(@as(usize, 0), opentype.trailingHardBreakLen("\x80\x80\x80"));

    // Truncated multi-byte sequence at the very end.
    try t.expectEqual(@as(usize, 0), opentype.trailingHardBreakLen("ab\xc3"));
}
