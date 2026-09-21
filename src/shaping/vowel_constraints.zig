// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
//! Port of hb-ot-shaper-vowel-constraints.cc (generated from
//! IndicShapingInvalidCluster.txt): inserts U+25CC between an independent
//! vowel and a following sign that would make it look like a different
//! independent vowel. Runs as the Indic/USE shapers' preprocess_text.
const std = @import("std");
const common = @import("common.zig");
const Buffer = common.Buffer;
const Tag = common.Tag;

const Script = enum { deva, beng, guru, gujr, orya, taml, telu, knda, mlym, sinh, brah, khoj, sind, tirh, modi, takr };

fn scriptFromTag(tag: Tag) ?Script {
    const scripts = [_]struct { Tag, Script }{
        .{ "deva".*, .deva }, .{ "dev2".*, .deva },
        .{ "beng".*, .beng }, .{ "bng2".*, .beng },
        .{ "guru".*, .guru }, .{ "gur2".*, .guru },
        .{ "gujr".*, .gujr }, .{ "gjr2".*, .gujr },
        .{ "orya".*, .orya }, .{ "ory2".*, .orya },
        .{ "taml".*, .taml }, .{ "tml2".*, .taml },
        .{ "telu".*, .telu }, .{ "tel2".*, .telu },
        .{ "knda".*, .knda }, .{ "knd2".*, .knda },
        .{ "mlym".*, .mlym }, .{ "mlm2".*, .mlym },
        .{ "sinh".*, .sinh }, .{ "brah".*, .brah },
        .{ "khoj".*, .khoj }, .{ "sind".*, .sind },
        .{ "tirh".*, .tirh }, .{ "modi".*, .modi },
        .{ "takr".*, .takr },
    };
    for (scripts) |entry| if (std.mem.eql(u8, &entry[0], &tag)) return entry[1];
    return null;
}

fn isConstrained(script: Script, first: u32, second: u32) bool {
    return switch (script) {
        .deva => switch (first) {
            0x0905 => switch (second) {
                0x093A, 0x093B, 0x093E, 0x0945, 0x0946, 0x0949, 0x094A, 0x094B, 0x094C, 0x094F, 0x0956, 0x0957 => true,
                else => false,
            },
            0x0906 => switch (second) {
                0x093A, 0x0945, 0x0946, 0x0947, 0x0948 => true,
                else => false,
            },
            0x0909 => second == 0x0941,
            0x090F => switch (second) {
                0x0945, 0x0946, 0x0947 => true,
                else => false,
            },
            else => false,
        },
        .beng => switch (first) {
            0x0985 => second == 0x09BE,
            0x098B => second == 0x09C3,
            0x098C => second == 0x09E2,
            else => false,
        },
        .guru => switch (first) {
            0x0A05 => switch (second) {
                0x0A3E, 0x0A48, 0x0A4C => true,
                else => false,
            },
            0x0A72 => switch (second) {
                0x0A3F, 0x0A40, 0x0A47 => true,
                else => false,
            },
            0x0A73 => switch (second) {
                0x0A41, 0x0A42, 0x0A4B => true,
                else => false,
            },
            else => false,
        },
        .gujr => switch (first) {
            0x0A85 => switch (second) {
                0x0ABE, 0x0AC5, 0x0AC7, 0x0AC8, 0x0AC9, 0x0ACB, 0x0ACC => true,
                else => false,
            },
            0x0AC5 => second == 0x0ABE,
            else => false,
        },
        .orya => switch (first) {
            0x0B05 => second == 0x0B3E,
            0x0B0F, 0x0B13 => second == 0x0B57,
            else => false,
        },
        .taml => first == 0x0B85 and second == 0x0BC2,
        .telu => switch (first) {
            0x0C12 => second == 0x0C4C or second == 0x0C55,
            0x0C3F, 0x0C46, 0x0C4A => second == 0x0C55,
            else => false,
        },
        .knda => switch (first) {
            0x0C89, 0x0C8B => second == 0x0CBE,
            0x0C92 => second == 0x0CCC,
            else => false,
        },
        .mlym => switch (first) {
            0x0D07, 0x0D09 => second == 0x0D57,
            0x0D0E => second == 0x0D46,
            0x0D12 => second == 0x0D3E or second == 0x0D57,
            else => false,
        },
        .sinh => switch (first) {
            0x0D85 => switch (second) {
                0x0DCF, 0x0DD0, 0x0DD1 => true,
                else => false,
            },
            0x0D8B, 0x0D8F, 0x0D94 => second == 0x0DDF,
            0x0D8D => second == 0x0DD8,
            0x0D91 => switch (second) {
                0x0DCA, 0x0DD9, 0x0DDA, 0x0DDC, 0x0DDD, 0x0DDE => true,
                else => false,
            },
            else => false,
        },
        .brah => switch (first) {
            0x11005 => second == 0x11038,
            0x1100B => second == 0x1103E,
            0x1100F => second == 0x11042,
            else => false,
        },
        .khoj => switch (first) {
            0x11200 => switch (second) {
                0x1122C, 0x11231, 0x11233 => true,
                else => false,
            },
            0x11206 => second == 0x1122C,
            0x1122C => second == 0x11230 or second == 0x11231,
            0x11240 => second == 0x1122E,
            else => false,
        },
        .sind => first == 0x112B0 and switch (second) {
            0x112E0, 0x112E5, 0x112E6, 0x112E7, 0x112E8 => true,
            else => false,
        },
        .tirh => switch (first) {
            0x11481 => second == 0x114B0,
            0x1148B, 0x1148D => second == 0x114BA,
            0x114AA => second == 0x114B5 or second == 0x114B6,
            else => false,
        },
        .modi => (first == 0x11600 or first == 0x11601) and (second == 0x11639 or second == 0x1163A),
        .takr => switch (first) {
            0x11680 => switch (second) {
                0x116AD, 0x116B4, 0x116B5 => true,
                else => false,
            },
            0x11686 => second == 0x116B2,
            else => false,
        },
    };
}

pub fn preprocessVowelConstraints(buffer: *Buffer, script_tags: []const Tag) !void {
    const script = for (script_tags) |tag| {
        if (scriptFromTag(tag)) |s| break s;
    } else return;

    buffer.clearOutput();
    const count = buffer.info.items.len;
    while (buffer.idx + 1 < count and buffer.successful) {
        const first = buffer.cur(0).codepoint;
        var matched = isConstrained(script, first, buffer.cur(1).codepoint);
        // Devanagari RA + VIRAMA + I: the dotted circle goes before the I.
        if (script == .deva and first == 0x0930 and buffer.cur(1).codepoint == 0x094D and
            buffer.idx + 2 < count and buffer.cur(2).codepoint == 0x0907)
        {
            try buffer.nextGlyph();
            matched = true;
        }
        try buffer.nextGlyph();
        if (matched) {
            try buffer.outputGlyph(0x25CC);
            try buffer.nextGlyph();
        }
    }
    try buffer.sync();
}
