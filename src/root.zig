const std = @import("std");
const Io = std.Io;

pub const parsing = @import("parsing.zig");
pub const unicode = @import("unicode.zig");
pub const discovery = @import("discovery.zig");
pub const shaping = @import("shaping.zig");
pub const rasterization = @import("rasterization.zig");
pub const hinting = @import("hinting.zig");
pub const render = @import("render.zig");

// Flat re-exports of the symbols dvui's Font.zig / TextLayoutWidget.zig use.
// Keep in sync with those call sites.

pub const Font = parsing.Font;
pub const Cmap = parsing.Table.cmap;

pub const UserCoord = render.UserCoord;
pub const Renderer = render.Renderer;
pub const PositionedGlyph = render.PositionedGlyph;

pub const EndMetric = shaping.EndMetric;
pub const Buffer = shaping.Buffer;
pub const BidiFallbackResult = shaping.BidiFallbackResult;
pub const PlanCache = shaping.PlanCache;
pub const Plans = shaping.Plans;
pub const Item = shaping.Item;
pub const Feature = shaping.Feature;

pub const shapeWithContext = shaping.shapeWithContext;
pub const shapeBidiParagraphWithFallback = shaping.shapeBidiParagraphWithFallback;

pub const line_cache = @import("shaping/line_cache.zig");
pub const ShapedLine = line_cache.ShapedLine;
pub const decodeLine = line_cache.decodeLine;

pub const discovery_fontconfig = discovery.fontconfig;
pub const discovery_core_text = discovery.core_text;
pub const discovery_directwrite = discovery.directwrite;
pub const discovery_android = discovery.android;
pub const discovery_manifest = discovery.manifest;
pub const discovery_web_fallback = discovery.web_fallback;
/// The `font-fallback` build option: false means no discovery backend and
/// no web fallback is compiled in.
pub const font_fallback = @import("build_options").font_fallback;
pub const DiscoveryHandle = discovery.Handle;
pub const DiscoveryProperties = discovery.Properties;
pub const DiscoveryFamilyName = discovery.FamilyName;

pub const selectBestFontMatch = discovery.selectBestMatch;
pub const FamilyAliases = discovery.Aliases;
pub const CoverageCache = discovery.CoverageCache;

test {
    _ = discovery;
}

pub const LineBreakStrictness = unicode.LineBreakStrictness;
pub const WordBreakMode = unicode.WordBreakMode;

// UTF-8-byte-offset wrappers over `unicode.LineBreakIterator`, which only
// speaks codepoint indices. `scratch` backs the codepoint buffer the
// iterator needs; freed before returning, never retained.

fn eachLineBreakOpportunity(
    scratch: std.mem.Allocator,
    txt: []const u8,
    limit_byte: usize,
    strictness: LineBreakStrictness,
    word_break: WordBreakMode,
    context: anytype,
    comptime each: fn (@TypeOf(context), usize) bool,
) void {
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(scratch);
    var byte_offsets: std.ArrayList(usize) = .empty;
    defer byte_offsets.deinit(scratch);

    const limit = @min(limit_byte, txt.len);
    var i: usize = 0;
    while (i < limit) {
        const cplen = std.unicode.utf8ByteSequenceLength(txt[i]) catch break;
        if (i + cplen > txt.len) break;
        const cp = std.unicode.utf8Decode(txt[i..][0..cplen]) catch break;
        codepoints.append(scratch, cp) catch return;
        byte_offsets.append(scratch, i) catch return;
        i += cplen;
    }
    byte_offsets.append(scratch, i) catch return;

    var it = unicode.LineBreakIterator.init(codepoints.items);
    it.strictness = strictness;
    it.word_break = word_break;
    while (it.next()) |b| {
        // Skip index 0 and the synthetic eot the iterator always emits at
        // the window edge -- when `limit_byte < txt.len` that "end of text"
        // is just where we stopped decoding, not a real break opportunity.
        if (b.opportunity == .prohibited or b.index == 0 or b.index >= codepoints.items.len) continue;
        if (each(context, byte_offsets.items[b.index])) return;
    }
}

/// Last break opportunity at or before `limit_byte` (for soft-wrapping a
/// line that overflowed the available width back to a word boundary).
pub fn lastLineBreakOpportunity(scratch: std.mem.Allocator, txt: []const u8, limit_byte: usize, strictness: LineBreakStrictness, word_break: WordBreakMode) ?usize {
    var best: ?usize = null;
    eachLineBreakOpportunity(scratch, txt, limit_byte, strictness, word_break, &best, struct {
        fn f(b: *?usize, off: usize) bool {
            b.* = off;
            return false;
        }
    }.f);
    return best;
}

/// First break opportunity strictly after `after_byte`, or null. Used by
/// `overflow-wrap: normal` to let an over-long word run to its next natural
/// break instead of char-breaking it.
pub fn nextLineBreakOpportunity(scratch: std.mem.Allocator, txt: []const u8, after_byte: usize, strictness: LineBreakStrictness, word_break: WordBreakMode) ?usize {
    const Ctx = struct { after: usize, found: ?usize = null };
    var ctx: Ctx = .{ .after = after_byte };
    eachLineBreakOpportunity(scratch, txt, txt.len, strictness, word_break, &ctx, struct {
        fn f(c: *Ctx, off: usize) bool {
            if (off > c.after) {
                c.found = off;
                return true;
            }
            return false;
        }
    }.f);
    return ctx.found;
}

/// UAX #14 mandatory break (BK/CR/LF/NL classes): LF, VT, FF, CR, CRLF, NEL, LS, PS.
pub const HardBreak = struct { start: usize, len: usize };

fn isMandatoryBreakClass(class: unicode.LineBreakClass) bool {
    return switch (class) {
        .bk, .cr, .lf, .nl => true,
        else => false,
    };
}

/// First mandatory break in text, decoding UTF-8 as it scans. `null` if none.
pub fn firstHardBreak(text: []const u8) ?HardBreak {
    var i: usize = 0;
    while (i < text.len) {
        // Of the ASCII range only LF/VT/FF/CR carry a mandatory class --
        // 0x0E..0x1F are CM, not BK -- so ASCII never needs the decode and
        // line-break table lookup below.
        if (text[i] < 0x80) {
            if (text[i] >= 0x0A and text[i] <= 0x0D) {
                const len: usize = if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') 2 else 1;
                return .{ .start = i, .len = len };
            }
            i += 1;
            continue;
        }
        const cplen = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + cplen > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..cplen]) catch {
            i += 1;
            continue;
        };
        if (isMandatoryBreakClass(unicode.LineBreakClass.of(cp))) {
            const len = if (cp == '\r' and i + cplen < text.len and text[i + cplen] == '\n') cplen + 1 else cplen;
            return .{ .start = i, .len = len };
        }
        i += cplen;
    }
    return null;
}

/// Byte length of a mandatory break at the very end of `text`, else 0.
pub fn trailingHardBreakLen(text: []const u8) usize {
    if (text.len == 0) return 0;
    var i: usize = text.len - 1;
    while (i > 0 and (text[i] & 0xc0) == 0x80) i -= 1;
    const cplen = std.unicode.utf8ByteSequenceLength(text[i]) catch return 0;
    if (i + cplen != text.len) return 0;
    const cp = std.unicode.utf8Decode(text[i..][0..cplen]) catch return 0;
    if (!isMandatoryBreakClass(unicode.LineBreakClass.of(cp))) return 0;
    if (cp == '\n' and i > 0 and text[i - 1] == '\r') return cplen + 1;
    return cplen;
}
