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
const tag_calt = hangul_mod.tag_calt;

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
// - record_stch/apply_stch ("stch" stretch/Syriac abbreviation
//   justification) - a separate, self-contained positioning feature.
// - reorder_marks_arabic (UAX #53 modifier-combining-mark reordering by
//   combining class) - affects diacritic visual order/position.
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

/// Ported from `collect_features_arabic`, minus the "stch" enable/pause
/// (deferred, see this section's top doc comment) and the pause callbacks
/// themselves (this port has no pause/stage machinery - see MapBuilder's
/// module doc comment; harmless to drop since nothing here needs a
/// mid-stream callback, only the final mask values matter).
///
/// Must run before `shape()`'s `default_features` loop: `ccmp`/`locl`/
/// `rlig`/`calt` are also enabled there without `manual_zwj`, and
/// `MapBuilder.compile`'s duplicate-tag merge keeps the *first* inserted
/// entry's flags (only `.global`/`.has_fallback` get overwritten by a
/// later duplicate - see `compile`'s dedup pass) - so registering these
/// with `manual_zwj = true` here first is what makes the merged feature
/// end up manual_zwj, same asymmetric-merge mechanism the Hangul shaper's
/// `overrideFeaturesHangul` doc comment explains for `.global` instead.
pub fn collectFeaturesArabic(map_builder: *MapBuilder) !void {
    try map_builder.enableFeature(tag_ccmp, .{ .manual_zwj = true }, 1);
    try map_builder.enableFeature(tag_locl, .{ .manual_zwj = true }, 1);
    for (arabic_feature_tags) |tag| try map_builder.addFeature(tag, .{ .manual_zwj = true }, 1);
    try map_builder.enableFeature(tag_rlig, .{ .manual_zwj = true }, 1);
    try map_builder.enableFeature(tag_calt, .{ .manual_zwj = true }, 1);
    try map_builder.enableFeature(tag_liga, .{ .manual_zwj = true }, 1);
    try map_builder.enableFeature(tag_clig, .{ .manual_zwj = true }, 1);
    try map_builder.enableFeature(tag_mset, .{ .manual_zwj = true }, 1);
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
    }
}
