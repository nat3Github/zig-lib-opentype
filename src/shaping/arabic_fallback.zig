// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const parsing = @import("../parsing.zig");
const common = @import("common.zig");
const map_mod = @import("map.zig");
const apply_mod = @import("apply.zig");
const Tag = common.Tag;

// Ported from vendor/harfbuzz/src/hb-ot-shaper-arabic-fallback.hh: for a
// font whose GSUB has no init/medi/fina/isol, synthesize those lookups (and
// three rlig ligature lookups) from the cmap's Arabic Presentation Forms and
// run them through the regular GSUB applier. This is also what joins
// Arabic in the morx-only macOS fonts (Geeza Pro, Baghdad, ...) until morx
// is ported. hb's Windows-1256 hand-coded table is built on _WIN32 only, so
// hb-shape elsewhere never uses it and neither do we.

pub fn LigatureSet(comptime component_count: usize) type {
    return struct {
        first: u16,
        ligatures: []const struct { components: [component_count]u16, ligature: u16 },
    };
}

/// Same order as `shaping_table`'s columns, followed by the three rlig
/// ligature lookups.
const fallback_features = [_]Tag{
    .{ 'i', 'n', 'i', 't' },
    .{ 'm', 'e', 'd', 'i' },
    .{ 'f', 'i', 'n', 'a' },
    .{ 'i', 's', 'o', 'l' },
    .{ 'r', 'l', 'i', 'g' },
    .{ 'r', 'l', 'i', 'g' },
    .{ 'r', 'l', 'i', 'g' },
};

const lookup_flag_ignore_marks: u16 = 0x0008;
const gsub_single: u16 = 1;
const gsub_ligature: u16 = 4;

/// hb's `data_create_arabic` do_fallback: every non-Syriac positional
/// feature is missing from the font.
pub fn needed(map: map_mod.Map) bool {
    for (fallback_features[0..4]) |tag| if (!map.needsFallback(tag)) return false;
    return true;
}

fn nominalGlyph(cmap: parsing.Table.cmap.Resolved, codepoint: u21) ?u16 {
    const glyph = cmap.lookup(codepoint) orelse return null;
    return if (glyph == 0) null else glyph;
}

const Blob = struct {
    bytes: []u8,
    len: usize = 0,

    fn put(self: *Blob, value: u16) void {
        std.mem.writeInt(u16, self.bytes[self.len..][0..2], value, .big);
        self.len += 2;
    }

    fn patch(self: *Blob, at: usize, value: usize) void {
        std.mem.writeInt(u16, self.bytes[at..][0..2], @intCast(value), .big);
    }
};

const lookup_list_offset = 10;
const lookup_header_len = 8;

fn ligatureLookupBound(comptime table: anytype) usize {
    var len: usize = lookup_header_len + 6 + 4;
    for (table) |set| {
        len += 2 + 2 + 2;
        for (set.ligatures) |ligature| len += 2 + 4 + 2 * ligature.components.len;
    }
    return len;
}

const max_blob_len = lookup_list_offset + 2 + 2 * fallback_features.len +
    4 * (lookup_header_len + 6 + 4 + 4 * shaping_table.len) +
    ligatureLookupBound(ligature_3_table) + ligatureLookupBound(ligature_table) + ligatureLookupBound(ligature_mark_table);

fn beginLookup(blob: *Blob, lookup_type: u16, lookup_flags: u16) void {
    blob.put(lookup_type);
    blob.put(lookup_flags);
    blob.put(1);
    blob.put(lookup_header_len);
}

/// `arabic_fallback_synthesize_lookup_single`, as SingleSubst format 2.
fn writeSingleLookup(blob: *Blob, cmap: parsing.Table.cmap.Resolved, column: usize) bool {
    const Pair = struct { glyph: u16, substitute: u16 };
    var pairs: [shaping_table.len]Pair = undefined;
    var count: usize = 0;
    for (shaping_table, 0..) |row, i| {
        if (row[column] == 0) continue;
        const glyph = nominalGlyph(cmap, @intCast(shaping_table_first + i)) orelse continue;
        const substitute = nominalGlyph(cmap, row[column]) orelse continue;
        if (glyph == substitute) continue;
        pairs[count] = .{ .glyph = glyph, .substitute = substitute };
        count += 1;
    }
    if (count == 0) return false;
    std.sort.insertion(Pair, pairs[0..count], {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.glyph < b.glyph;
        }
    }.lessThan);

    beginLookup(blob, gsub_single, lookup_flag_ignore_marks);
    const subtable = blob.len;
    blob.put(2);
    blob.put(@intCast(6 + 2 * count));
    blob.put(@intCast(count));
    for (pairs[0..count]) |pair| blob.put(pair.substitute);
    blob.put(1);
    blob.put(@intCast(count));
    for (pairs[0..count]) |pair| blob.put(pair.glyph);
    std.debug.assert(blob.len - subtable == 10 + 4 * count);
    return true;
}

/// `arabic_fallback_synthesize_lookup_ligature`, as LigatureSubst format 1.
fn writeLigatureLookup(blob: *Blob, cmap: parsing.Table.cmap.Resolved, comptime table: anytype, lookup_flags: u16) bool {
    const Set = @TypeOf(table[0]);
    const Ligature = @typeInfo(@FieldType(Set, "ligatures")).pointer.child;
    const component_count = @typeInfo(@FieldType(Ligature, "components")).array.len;
    const First = struct { glyph: u16, set: usize };
    var firsts: [table.len]First = undefined;
    var first_count: usize = 0;
    for (table, 0..) |set, i| {
        const glyph = nominalGlyph(cmap, set.first) orelse continue;
        firsts[first_count] = .{ .glyph = glyph, .set = i };
        first_count += 1;
    }
    std.sort.insertion(First, firsts[0..first_count], {}, struct {
        fn lessThan(_: void, a: First, b: First) bool {
            return a.glyph < b.glyph;
        }
    }.lessThan);

    const Resolved = struct { glyph: u16, components: [component_count]u16 };
    const max_per_set = comptime blk: {
        var max: usize = 0;
        for (table) |set| max = @max(max, set.ligatures.len);
        break :blk max;
    };
    var resolved: [table.len][max_per_set]Resolved = undefined;
    var resolved_count: [table.len]usize = @splat(0);
    var total: usize = 0;
    for (firsts[0..first_count], 0..) |first, fi| {
        next_ligature: for (table[first.set].ligatures) |ligature| {
            const ligature_glyph = nominalGlyph(cmap, ligature.ligature) orelse continue;
            var components: [component_count]u16 = undefined;
            for (ligature.components, &components) |codepoint, *glyph| {
                glyph.* = nominalGlyph(cmap, codepoint) orelse continue :next_ligature;
            }
            resolved[fi][resolved_count[fi]] = .{ .glyph = ligature_glyph, .components = components };
            resolved_count[fi] += 1;
            total += 1;
        }
    }
    if (total == 0) return false;

    beginLookup(blob, gsub_ligature, lookup_flags);
    const subtable = blob.len;
    blob.put(1);
    const coverage_offset_at = blob.len;
    blob.put(0);
    blob.put(@intCast(first_count));
    const set_offsets_at = blob.len;
    for (0..first_count) |_| blob.put(0);
    blob.patch(coverage_offset_at, blob.len - subtable);
    blob.put(1);
    blob.put(@intCast(first_count));
    for (firsts[0..first_count]) |first| blob.put(first.glyph);
    for (0..first_count) |fi| {
        const set = blob.len;
        blob.patch(set_offsets_at + 2 * fi, set - subtable);
        const ligatures = resolved[fi][0..resolved_count[fi]];
        blob.put(@intCast(ligatures.len));
        const ligature_offsets_at = blob.len;
        for (ligatures) |_| blob.put(0);
        for (ligatures, 0..) |ligature, li| {
            blob.patch(ligature_offsets_at + 2 * li, blob.len - set);
            blob.put(ligature.glyph);
            blob.put(1 + component_count);
            for (ligature.components) |glyph| blob.put(glyph);
        }
    }
    return true;
}

/// hb's `arabic_fallback_shape` pause after rlig.
/// ponytail: the synthetic GSUB is rebuilt per shape call (a few hundred
/// cmap lookups); cache it on the plan if GSUB-less Arabic fonts get hot.
pub fn shape(
    map: map_mod.Map,
    cmap: ?parsing.Table.cmap.Resolved,
    gdef: apply_mod.Gdef,
    buffer: *common.Buffer,
    direction: common.Direction,
) (parsing.Font.ParseError || error{OutOfMemory})!void {
    if (!needed(map)) return;
    const resolved_cmap = cmap orelse return;
    var storage: [max_blob_len]u8 = undefined;
    var blob = Blob{ .bytes = &storage };
    blob.put(1);
    blob.put(0);
    blob.put(0);
    blob.put(0);
    blob.put(lookup_list_offset);
    const lookup_count_at = blob.len;
    blob.put(0);
    const lookup_offsets_at = blob.len;
    for (fallback_features) |_| blob.put(0);

    var masks: [fallback_features.len]u32 = undefined;
    var lookup_count: usize = 0;
    for (fallback_features, 0..) |tag, i| {
        const mask = map.get1Mask(tag);
        if (mask == 0) continue;
        const start = blob.len;
        const written = switch (i) {
            0...3 => writeSingleLookup(&blob, resolved_cmap, i),
            4 => writeLigatureLookup(&blob, resolved_cmap, ligature_3_table, lookup_flag_ignore_marks),
            5 => writeLigatureLookup(&blob, resolved_cmap, ligature_table, lookup_flag_ignore_marks),
            6 => writeLigatureLookup(&blob, resolved_cmap, ligature_mark_table, 0),
            else => unreachable,
        };
        if (!written) continue;
        blob.patch(lookup_offsets_at + 2 * lookup_count, start - lookup_list_offset);
        masks[lookup_count] = mask;
        lookup_count += 1;
    }
    blob.patch(lookup_count_at, lookup_count);

    const layout = parsing.Table.Layout{ .data = storage[0..blob.len] };
    for (masks[0..lookup_count], 0..) |mask, i| {
        try apply_mod.applySynthesizedGsubLookup(layout, @intCast(i), mask, gdef, buffer, direction);
    }
}

const shaping_table_first: u21 = 0x0621;

/// init, medi, fina, isol presentation form per letter, 0 = none.
pub const shaping_table = [_][4]u16{
    .{ 0x0000, 0x0000, 0x0000, 0xFE80 },
    .{ 0x0000, 0x0000, 0xFE82, 0xFE81 },
    .{ 0x0000, 0x0000, 0xFE84, 0xFE83 },
    .{ 0x0000, 0x0000, 0xFE86, 0xFE85 },
    .{ 0x0000, 0x0000, 0xFE88, 0xFE87 },
    .{ 0xFE8B, 0xFE8C, 0xFE8A, 0xFE89 },
    .{ 0x0000, 0x0000, 0xFE8E, 0xFE8D },
    .{ 0xFE91, 0xFE92, 0xFE90, 0xFE8F },
    .{ 0x0000, 0x0000, 0xFE94, 0xFE93 },
    .{ 0xFE97, 0xFE98, 0xFE96, 0xFE95 },
    .{ 0xFE9B, 0xFE9C, 0xFE9A, 0xFE99 },
    .{ 0xFE9F, 0xFEA0, 0xFE9E, 0xFE9D },
    .{ 0xFEA3, 0xFEA4, 0xFEA2, 0xFEA1 },
    .{ 0xFEA7, 0xFEA8, 0xFEA6, 0xFEA5 },
    .{ 0x0000, 0x0000, 0xFEAA, 0xFEA9 },
    .{ 0x0000, 0x0000, 0xFEAC, 0xFEAB },
    .{ 0x0000, 0x0000, 0xFEAE, 0xFEAD },
    .{ 0x0000, 0x0000, 0xFEB0, 0xFEAF },
    .{ 0xFEB3, 0xFEB4, 0xFEB2, 0xFEB1 },
    .{ 0xFEB7, 0xFEB8, 0xFEB6, 0xFEB5 },
    .{ 0xFEBB, 0xFEBC, 0xFEBA, 0xFEB9 },
    .{ 0xFEBF, 0xFEC0, 0xFEBE, 0xFEBD },
    .{ 0xFEC3, 0xFEC4, 0xFEC2, 0xFEC1 },
    .{ 0xFEC7, 0xFEC8, 0xFEC6, 0xFEC5 },
    .{ 0xFECB, 0xFECC, 0xFECA, 0xFEC9 },
    .{ 0xFECF, 0xFED0, 0xFECE, 0xFECD },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFED3, 0xFED4, 0xFED2, 0xFED1 },
    .{ 0xFED7, 0xFED8, 0xFED6, 0xFED5 },
    .{ 0xFEDB, 0xFEDC, 0xFEDA, 0xFED9 },
    .{ 0xFEDF, 0xFEE0, 0xFEDE, 0xFEDD },
    .{ 0xFEE3, 0xFEE4, 0xFEE2, 0xFEE1 },
    .{ 0xFEE7, 0xFEE8, 0xFEE6, 0xFEE5 },
    .{ 0xFEEB, 0xFEEC, 0xFEEA, 0xFEE9 },
    .{ 0x0000, 0x0000, 0xFEEE, 0xFEED },
    .{ 0xFBE8, 0xFBE9, 0xFEF0, 0xFEEF },
    .{ 0xFEF3, 0xFEF4, 0xFEF2, 0xFEF1 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFB51, 0xFB50 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0xFBDD },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB68, 0xFB69, 0xFB67, 0xFB66 },
    .{ 0xFB60, 0xFB61, 0xFB5F, 0xFB5E },
    .{ 0xFB54, 0xFB55, 0xFB53, 0xFB52 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB58, 0xFB59, 0xFB57, 0xFB56 },
    .{ 0xFB64, 0xFB65, 0xFB63, 0xFB62 },
    .{ 0xFB5C, 0xFB5D, 0xFB5B, 0xFB5A },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB78, 0xFB79, 0xFB77, 0xFB76 },
    .{ 0xFB74, 0xFB75, 0xFB73, 0xFB72 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB7C, 0xFB7D, 0xFB7B, 0xFB7A },
    .{ 0xFB80, 0xFB81, 0xFB7F, 0xFB7E },
    .{ 0x0000, 0x0000, 0xFB89, 0xFB88 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFB85, 0xFB84 },
    .{ 0x0000, 0x0000, 0xFB83, 0xFB82 },
    .{ 0x0000, 0x0000, 0xFB87, 0xFB86 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFB8D, 0xFB8C },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFB8B, 0xFB8A },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB6C, 0xFB6D, 0xFB6B, 0xFB6A },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB70, 0xFB71, 0xFB6F, 0xFB6E },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB90, 0xFB91, 0xFB8F, 0xFB8E },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFBD5, 0xFBD6, 0xFBD4, 0xFBD3 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB94, 0xFB95, 0xFB93, 0xFB92 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB9C, 0xFB9D, 0xFB9B, 0xFB9A },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFB98, 0xFB99, 0xFB97, 0xFB96 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFB9F, 0xFB9E },
    .{ 0xFBA2, 0xFBA3, 0xFBA1, 0xFBA0 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFBAC, 0xFBAD, 0xFBAB, 0xFBAA },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFBA5, 0xFBA4 },
    .{ 0xFBA8, 0xFBA9, 0xFBA7, 0xFBA6 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFBE1, 0xFBE0 },
    .{ 0x0000, 0x0000, 0xFBDA, 0xFBD9 },
    .{ 0x0000, 0x0000, 0xFBD8, 0xFBD7 },
    .{ 0x0000, 0x0000, 0xFBDC, 0xFBDB },
    .{ 0x0000, 0x0000, 0xFBE3, 0xFBE2 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFBDF, 0xFBDE },
    .{ 0xFBFE, 0xFBFF, 0xFBFD, 0xFBFC },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0xFBE6, 0xFBE7, 0xFBE5, 0xFBE4 },
    .{ 0x0000, 0x0000, 0x0000, 0x0000 },
    .{ 0x0000, 0x0000, 0xFBAF, 0xFBAE },
    .{ 0x0000, 0x0000, 0xFBB1, 0xFBB0 },
};

pub const ligature_3_table = [_]LigatureSet(2){
    .{ .first = 0xFEDF, .ligatures = &.{
        .{ .components = .{ 0xFEE4, 0xFEA4 }, .ligature = 0xFD88 },
        .{ .components = .{ 0xFEE0, 0xFEEA }, .ligature = 0xF201 },
        .{ .components = .{ 0xFEE4, 0xFEA0 }, .ligature = 0xF211 },
    } },
};

pub const ligature_table = [_]LigatureSet(1){
    .{ .first = 0xFE91, .ligatures = &.{
        .{ .components = .{ 0xFEE2 }, .ligature = 0xFC08 },
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFC9F },
        .{ .components = .{ 0xFEA0 }, .ligature = 0xFC9C },
        .{ .components = .{ 0xFEA4 }, .ligature = 0xFC9D },
        .{ .components = .{ 0xFEA8 }, .ligature = 0xFC9E },
    } },
    .{ .first = 0xFE92, .ligatures = &.{
        .{ .components = .{ 0xFEAE }, .ligature = 0xFC6A },
        .{ .components = .{ 0xFEE6 }, .ligature = 0xFC6D },
        .{ .components = .{ 0xFEF2 }, .ligature = 0xFC6F },
    } },
    .{ .first = 0xFE97, .ligatures = &.{
        .{ .components = .{ 0xFEE2 }, .ligature = 0xFC0E },
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCA4 },
        .{ .components = .{ 0xFEA0 }, .ligature = 0xFCA1 },
        .{ .components = .{ 0xFEA4 }, .ligature = 0xFCA2 },
        .{ .components = .{ 0xFEA8 }, .ligature = 0xFCA3 },
    } },
    .{ .first = 0xFE98, .ligatures = &.{
        .{ .components = .{ 0xFEAE }, .ligature = 0xFC70 },
        .{ .components = .{ 0xFEE6 }, .ligature = 0xFC73 },
        .{ .components = .{ 0xFEF2 }, .ligature = 0xFC75 },
    } },
    .{ .first = 0xFE9B, .ligatures = &.{
        .{ .components = .{ 0xFEE2 }, .ligature = 0xFC12 },
    } },
    .{ .first = 0xFE9F, .ligatures = &.{
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCA8 },
    } },
    .{ .first = 0xFEA3, .ligatures = &.{
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCAA },
    } },
    .{ .first = 0xFEA7, .ligatures = &.{
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCAC },
    } },
    .{ .first = 0xFEB3, .ligatures = &.{
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCB0 },
    } },
    .{ .first = 0xFEB7, .ligatures = &.{
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFD30 },
    } },
    .{ .first = 0xFED3, .ligatures = &.{
        .{ .components = .{ 0xFEF2 }, .ligature = 0xFC32 },
    } },
    .{ .first = 0xFEDF, .ligatures = &.{
        .{ .components = .{ 0xFE9E }, .ligature = 0xFC3F },
        .{ .components = .{ 0xFEA0 }, .ligature = 0xFCC9 },
        .{ .components = .{ 0xFEA2 }, .ligature = 0xFC40 },
        .{ .components = .{ 0xFEA4 }, .ligature = 0xFCCA },
        .{ .components = .{ 0xFEA6 }, .ligature = 0xFC41 },
        .{ .components = .{ 0xFEA8 }, .ligature = 0xFCCB },
        .{ .components = .{ 0xFEE2 }, .ligature = 0xFC42 },
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCCC },
        .{ .components = .{ 0xFEF0 }, .ligature = 0xFC43 },
        .{ .components = .{ 0xFEF2 }, .ligature = 0xFC44 },
        .{ .components = .{ 0xFEEC }, .ligature = 0xFCCD },
        .{ .components = .{ 0xFE82 }, .ligature = 0xFEF5 },
        .{ .components = .{ 0xFE84 }, .ligature = 0xFEF7 },
        .{ .components = .{ 0xFE88 }, .ligature = 0xFEF9 },
        .{ .components = .{ 0xFE8E }, .ligature = 0xFEFB },
    } },
    .{ .first = 0xFEE0, .ligatures = &.{
        .{ .components = .{ 0xFEF0 }, .ligature = 0xFC86 },
        .{ .components = .{ 0xFE82 }, .ligature = 0xFEF6 },
        .{ .components = .{ 0xFE84 }, .ligature = 0xFEF8 },
        .{ .components = .{ 0xFE88 }, .ligature = 0xFEFA },
        .{ .components = .{ 0xFE8E }, .ligature = 0xFEFC },
    } },
    .{ .first = 0xFEE3, .ligatures = &.{
        .{ .components = .{ 0xFEA0 }, .ligature = 0xFCCE },
        .{ .components = .{ 0xFEA4 }, .ligature = 0xFCCF },
        .{ .components = .{ 0xFEA8 }, .ligature = 0xFCD0 },
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCD1 },
    } },
    .{ .first = 0xFEE7, .ligatures = &.{
        .{ .components = .{ 0xFEE2 }, .ligature = 0xFC4E },
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCD5 },
        .{ .components = .{ 0xFEA0 }, .ligature = 0xFCD2 },
        .{ .components = .{ 0xFEA4 }, .ligature = 0xFCD3 },
    } },
    .{ .first = 0xFEE8, .ligatures = &.{
        .{ .components = .{ 0xFEF2 }, .ligature = 0xFC8F },
    } },
    .{ .first = 0xFEF3, .ligatures = &.{
        .{ .components = .{ 0xFEA0 }, .ligature = 0xFCDA },
        .{ .components = .{ 0xFEA4 }, .ligature = 0xFCDB },
        .{ .components = .{ 0xFEA8 }, .ligature = 0xFCDC },
        .{ .components = .{ 0xFEE4 }, .ligature = 0xFCDD },
    } },
    .{ .first = 0xFEF4, .ligatures = &.{
        .{ .components = .{ 0xFEAE }, .ligature = 0xFC91 },
        .{ .components = .{ 0xFEE6 }, .ligature = 0xFC94 },
    } },
};

pub const ligature_mark_table = [_]LigatureSet(1){
    .{ .first = 0x0651, .ligatures = &.{
        .{ .components = .{ 0x064C }, .ligature = 0xFC5E },
        .{ .components = .{ 0x064E }, .ligature = 0xFC60 },
        .{ .components = .{ 0x064F }, .ligature = 0xFC61 },
        .{ .components = .{ 0x0650 }, .ligature = 0xFC62 },
        .{ .components = .{ 0x064B }, .ligature = 0xF2EE },
    } },
};
