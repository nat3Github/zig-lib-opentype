// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const unicode = @import("../unicode.zig");
const common = @import("common.zig");
const map_mod = @import("map.zig");
const hangul_mod = @import("hangul.zig");
const Buffer = common.Buffer;
const ArabicAction = common.ArabicAction;
const Tag = common.Tag;
const MapBuilder = map_mod.MapBuilder;
const Map = map_mod.Map;
const MapFeatureFlags = map_mod.MapFeatureFlags;
const tag_calt = hangul_mod.tag_calt;
const apply_mod = @import("apply.zig");
const GlyphInfo = common.GlyphInfo;
const tag_stch = Tag{ 's', 't', 'c', 'h' };

// Ported from vendor/harfbuzz/src/hb-ot-shaper-arabic.cc (pinned 703e2d1441):
// the Arabic complex shaper, scoped this session to its core - the
// cursive-joining state machine (Joining_Type lookup + 7-state table) that
// picks isol/fina/fin2/fin3/medi/med2/init per glyph and feeds those as
// GSUB feature masks. This is what drives correct shaping for any real
// Arabic/Syriac font with proper GSUB tables.
//
// Deliberately deferred this session (per AskUserQuestion scope choice,
// "core joining only"), each a self-contained follow-up:
// - arabic_fallback_shape / hb-ot-shaper-arabic-fallback.hh: synthetic
//   isol/fina/medi/init glyph substitution for fonts lacking Arabic OT
//   features. Only matters for such fonts; real Arabic text fonts ship the
//   GSUB features this port already applies.
// - mongolian_variation_selectors (copy shaping action from base to a
//   following Mongolian variation selector) - Mongolian dispatch isn't
//   wired in at all this session (see dispatch note below).
// - buffer pre/post-context handling and the unsafe_to_break/
//   unsafe_to_concat/safe_to_insert_tatweel bookkeeping in hb's
//   arabic_joining: those exist for hb's incremental/segmented shaping
//   API, which this port's single-call `shape()` has no equivalent
//   surface for.
//
// Dispatch: activates when `arab` or `syrc` appears in `shape()`'s
// caller-supplied `script_tags` - same "caller supplies the tag" stand-in
// for hb's Unicode-script-property dispatch as the Hangul shaper above.
// hb's real dispatch table also routes Nko/Mandaic/Mongolian/Phags-pa/
// Manichaean/Psalter-Pahlavi/Sogdian/Old-Uyghur/Adlam/Chorasmian/Hanifi-
// Rohingya/Thaana through this same shaper; only Arabic/Syriac are wired
// here (the two scripts gen-arabic-table.py's own header comment names as
// the primary joining-table scripts) - extend `is_arabic`'s tag check if a
// caller needs one of the others (the joining-type table already has data
// for most of them, e.g. Mongolian, Phags-pa - only the dispatch tag is
// missing).

pub const arab_script_tag = Tag{ 'a', 'r', 'a', 'b' };
pub const syrc_script_tag = Tag{ 's', 'y', 'r', 'c' };
const tag_ccmp = Tag{ 'c', 'c', 'm', 'p' };
const tag_locl = Tag{ 'l', 'o', 'c', 'l' };
const tag_rlig = Tag{ 'r', 'l', 'i', 'g' };
pub const tag_liga = Tag{ 'l', 'i', 'g', 'a' };
pub const tag_clig = Tag{ 'c', 'l', 'i', 'g' };
const tag_mset = Tag{ 'm', 's', 'e', 't' };

/// Same order as `arabic_features`/`hb_arabic_joining_type_t`'s first 6
/// values (U/L/R/D/ALAPH/DALATH_RISH) - `unicode.ArabicJoiningType`'s
/// enum values 0-5 index this table's columns directly; `.transparent`
/// (6) never reaches the table (skipped in `arabicJoining` below, mirrors
/// hb's `if (this_type == JOINING_TYPE_T) continue`).
const ArabicStateEntry = struct { prev_action: ArabicAction, curr_action: ArabicAction, next_state: u8 };
const none = ArabicAction.none;
const arabic_state_table = [7][6]ArabicStateEntry{
    .{ .{ .prev_action = none, .curr_action = none, .next_state = 0 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 1 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 1 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 6 } },
    .{ .{ .prev_action = none, .curr_action = none, .next_state = 0 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 1 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = none, .curr_action = .fin2, .next_state = 5 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 6 } },
    .{ .{ .prev_action = none, .curr_action = none, .next_state = 0 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = .init, .curr_action = .fina, .next_state = 1 }, .{ .prev_action = .init, .curr_action = .fina, .next_state = 3 }, .{ .prev_action = .init, .curr_action = .fina, .next_state = 4 }, .{ .prev_action = .init, .curr_action = .fina, .next_state = 6 } },
    .{ .{ .prev_action = none, .curr_action = none, .next_state = 0 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = .medi, .curr_action = .fina, .next_state = 1 }, .{ .prev_action = .medi, .curr_action = .fina, .next_state = 3 }, .{ .prev_action = .medi, .curr_action = .fina, .next_state = 4 }, .{ .prev_action = .medi, .curr_action = .fina, .next_state = 6 } },
    .{ .{ .prev_action = none, .curr_action = none, .next_state = 0 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = .med2, .curr_action = .isol, .next_state = 1 }, .{ .prev_action = .med2, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = .med2, .curr_action = .fin2, .next_state = 5 }, .{ .prev_action = .med2, .curr_action = .isol, .next_state = 6 } },
    .{ .{ .prev_action = none, .curr_action = none, .next_state = 0 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = .isol, .curr_action = .isol, .next_state = 1 }, .{ .prev_action = .isol, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = .isol, .curr_action = .fin2, .next_state = 5 }, .{ .prev_action = .isol, .curr_action = .isol, .next_state = 6 } },
    .{ .{ .prev_action = none, .curr_action = none, .next_state = 0 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 1 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 2 }, .{ .prev_action = none, .curr_action = .fin3, .next_state = 5 }, .{ .prev_action = none, .curr_action = .isol, .next_state = 6 } },
};

/// Ported from `arabic_joining`: walks the buffer left-to-right (logical
/// order - this runs before the RTL visual-order reversal at the end of
/// `shape()`) assigning each glyph its positional-form action via the
/// state machine above. Transparent codepoints (combining marks/format
/// controls) get `.none` and don't affect the state.
fn arabicJoining(buffer: *Buffer) void {
    var prev: ?usize = null;
    var state: u8 = 0;
    for (buffer.info.items, 0..) |*info, i| {
        const jt = unicode.arabicJoiningType(@intCast(info.codepoint));
        if (jt == .transparent) {
            info.arabic_shaping_action = @intFromEnum(ArabicAction.none);
            continue;
        }

        const entry = arabic_state_table[state][@intFromEnum(jt)];
        if (entry.prev_action != .none and prev != null) {
            buffer.info.items[prev.?].arabic_shaping_action = @intFromEnum(entry.prev_action);
        }
        info.arabic_shaping_action = @intFromEnum(entry.curr_action);
        prev = i;
        state = entry.next_state;
    }
}

/// Same order as `ArabicAction`'s isol..init variants (index 0-6);
/// `.none` (7) never needs a tag since `setupMasksArabic` skips it.
const arabic_feature_tags = [7]Tag{
    .{ 'i', 's', 'o', 'l' },
    .{ 'f', 'i', 'n', 'a' },
    .{ 'f', 'i', 'n', '2' },
    .{ 'f', 'i', 'n', '3' },
    .{ 'm', 'e', 'd', 'i' },
    .{ 'm', 'e', 'd', '2' },
    .{ 'i', 'n', 'i', 't' },
};

/// Ported from `collect_features_arabic`, minus the fallback-shaping pause
/// (not ported, see this section's top doc comment). Each positional feature gets its own stage, and `ccmp`/`locl`
/// run before all of them. `manual_zwj` sticks because `MapBuilder.compile`
/// keeps the first registration's flags when `default_features` repeats a
/// tag.
pub fn collectFeaturesArabic(map_builder: *MapBuilder, is_arabic_script: bool) !void {
    const manual_zwj = MapFeatureFlags{ .manual_zwj = true };
    try map_builder.enableFeature(tag_stch, .{}, 1);
    try map_builder.addGsubPause(.arabic_record_stch);
    try map_builder.enableFeature(tag_ccmp, manual_zwj, 1);
    try map_builder.enableFeature(tag_locl, manual_zwj, 1);
    try map_builder.addGsubPause(.none);
    for (arabic_feature_tags) |tag| {
        try map_builder.addFeature(tag, manual_zwj, 1);
        try map_builder.addGsubPause(.none);
    }
    try map_builder.addGsubPause(.none);
    try map_builder.enableFeature(tag_rlig, manual_zwj, 1);
    if (is_arabic_script) try map_builder.addGsubPause(.none);
    try map_builder.enableFeature(tag_calt, manual_zwj, 1);
    // hb pauses here unless 'rclt' was already registered, which it never
    // is this early.
    try map_builder.addGsubPause(.none);
    try map_builder.enableFeature(tag_liga, manual_zwj, 1);
    try map_builder.enableFeature(tag_clig, manual_zwj, 1);
    try map_builder.enableFeature(tag_mset, manual_zwj, 1);
}

/// Ported from `setup_masks_arabic_plan`: runs `arabicJoining` then masks
/// each glyph with its assigned positional feature - must run before
/// `mapGlyphsFast` overwrites `codepoint` with a glyph id, same ordering
/// constraint as `setupMasksHangul` above.
pub fn setupMasksArabic(buffer: *Buffer, map: Map) void {
    arabicJoining(buffer);
    for (buffer.info.items) |*info| {
        const action = info.arabic_shaping_action;
        if (action < arabic_feature_tags.len) info.mask |= map.get1Mask(arabic_feature_tags[action]);
        info.is_arabic_word = unicode.isArabicWordCategory(@intCast(info.codepoint));
    }
}

/// Ported from `record_stch`: the pause right after 'stch'. Whatever it
/// multiplied alternates fixed and repeating tiles.
pub fn recordStch(buffer: *Buffer, map: Map) void {
    if (map.get1Mask(tag_stch) == 0) return;
    for (buffer.info.items) |*info| {
        if (!info.is_multiplied) continue;
        const action: ArabicAction = if (info.lig_comp % 2 == 1) .stch_repeating else .stch_fixed;
        info.arabic_shaping_action = @intFromEnum(action);
    }
}

fn isStch(info: GlyphInfo) bool {
    return info.arabic_shaping_action == @intFromEnum(ArabicAction.stch_fixed) or
        info.arabic_shaping_action == @intFromEnum(ArabicAction.stch_repeating);
}

/// hb's per-stretch glyph cap (`STCH_MAX_GLYPHS`).
const stch_max_glyphs = 256;

/// Ported from `apply_stch`: repeats each stretch's repeating tiles until the
/// stretch spans the rest of its word. Runs on the positioned, visual-order
/// buffer. Two passes, as in hb: measure how many copies to add, then grow
/// the buffer and copy glyphs toward its end.
pub fn applyStch(buffer: *Buffer, rtl: bool, metrics: apply_mod.HorizontalMetrics) !void {
    for (buffer.info.items) |info| {
        if (isStch(info)) break;
    } else return;

    if (!rtl) buffer.reverse();
    defer if (!rtl) buffer.reverse();

    var extra_glyphs: usize = 0;
    for ([_]bool{ false, true }) |cut| {
        const count = buffer.info.items.len;
        if (cut) {
            try buffer.info.resize(buffer.allocator, count + extra_glyphs);
            try buffer.pos.resize(buffer.allocator, count + extra_glyphs);
        }
        const info = buffer.info.items;
        const pos = buffer.pos.items;
        var j = count + extra_glyphs;
        var i = count;
        while (i > 0) {
            if (!isStch(info[i - 1])) {
                if (cut) {
                    j -= 1;
                    info[j] = info[i - 1];
                    pos[j] = pos[i - 1];
                }
                i -= 1;
                continue;
            }

            var w_fixed: i64 = 0;
            var w_repeating: i64 = 0;
            var n_fixed: usize = 0;
            var n_repeating: usize = 0;
            const end = i;
            while (i > 0 and isStch(info[i - 1])) {
                i -= 1;
                const width = metrics.advance(info[i].codepoint);
                if (info[i].arabic_shaping_action == @intFromEnum(ArabicAction.stch_fixed)) {
                    w_fixed += width;
                    n_fixed += 1;
                } else {
                    w_repeating += width;
                    n_repeating += 1;
                }
            }
            const start = i;
            var w_total: i64 = 0;
            var context = i;
            while (context > 0 and !isStch(info[context - 1]) and
                (common.isIgnorable(info[context - 1]) or info[context - 1].is_arabic_word))
            {
                context -= 1;
                w_total += pos[context].x_advance;
            }

            var n_copies: i64 = 0;
            const w_remaining_total = w_total - w_fixed;
            var w_remaining = w_remaining_total;
            if (w_remaining_total > w_repeating and w_repeating > 0) n_copies = @divTrunc(w_remaining_total, w_repeating) - 1;

            // One more repeat squeezed together can fit better than a gap.
            var extra_repeat_overlap: i64 = 0;
            const shortfall = w_remaining_total - w_repeating * (n_copies + 1);
            if (shortfall > 0 and n_repeating > 0) {
                n_copies += 1;
                const excess = (n_copies + 1) * w_repeating - w_remaining_total;
                if (excess > 0) {
                    extra_repeat_overlap = @divTrunc(excess, n_copies * @as(i64, @intCast(n_repeating)));
                    w_remaining = 0;
                }
            }

            var max_copies: i64 = 0;
            if (n_repeating > 0 and n_fixed + n_repeating < stch_max_glyphs) {
                max_copies = @intCast((stch_max_glyphs - n_fixed - n_repeating) / n_repeating);
            }
            n_copies = @min(n_copies, max_copies);

            if (!cut) {
                extra_glyphs += @as(usize, @intCast(n_copies)) * n_repeating;
                continue;
            }

            buffer.unsafeToBreak(context, end);
            var x_offset = @divTrunc(w_remaining, 2);
            var k = end;
            while (k > start) : (k -= 1) {
                const width = metrics.advance(info[k - 1].codepoint);
                const repeat: usize = if (info[k - 1].arabic_shaping_action == @intFromEnum(ArabicAction.stch_repeating)) 1 + @as(usize, @intCast(n_copies)) else 1;
                pos[k - 1].x_advance = 0;
                for (0..repeat) |n| {
                    if (rtl) {
                        x_offset -= width;
                        if (n > 0) x_offset += extra_repeat_overlap;
                    }
                    pos[k - 1].x_offset = @intCast(std.math.clamp(x_offset, std.math.minInt(i32), std.math.maxInt(i32)));
                    j -= 1;
                    info[j] = info[k - 1];
                    pos[j] = pos[k - 1];
                    if (!rtl) {
                        x_offset += width;
                        if (n > 0) x_offset -= extra_repeat_overlap;
                    }
                }
            }
        }
    }
}
