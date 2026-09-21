// Derived from HarfBuzz (Old MIT); see THIRD_PARTY_LICENSES.
// Ported from vendor/harfbuzz/src/hb-ot-map.hh + hb-ot-map.cc (pinned
// 703e2d1441): turns requested GSUB/GPOS feature tags into an ordered,
// mask-tagged lookup-index list per table, consulting the font's own
// Script/LangSys/Feature tables via parsing.zig's Table.Layout.
//
// Deliberate scope cuts vs. hb (phase-1 default-shaper port, no complex
// shaper yet):
// - hb_ot_tags_from_script_and_language (ISO script/BCP-47 -> OT tag
//   fallback table, ~1000 lines in hb-ot-tag.cc) is not ported: per
//   requirements.md's Shaping section, "caller supplies the tag" — callers
//   pass already-resolved OT script/language tag candidates directly.
// - Pause callbacks are ported as a `StagePause` enum on each stage
//   instead of hb's `pause_func_t` function pointers: the set of callbacks
//   is closed (one complex shaper per buffer, each with a fixed script of
//   pauses) so the caller that drives the stage loop switches on the tag,
//   keeping map.zig free of any dependency on the shapers.
const std = @import("std");
const parsing = @import("../parsing.zig");
const common = @import("common.zig");
const Tag = common.Tag;
const glyph_flag_defined = common.glyph_flag_defined;

pub const table_tag_gsub = Tag{ 'G', 'S', 'U', 'B' };
pub const table_tag_gpos = Tag{ 'G', 'P', 'O', 'S' };
const tag_dflt_script = Tag{ 'D', 'F', 'L', 'T' };
const tag_dflt_lang = Tag{ 'd', 'f', 'l', 't' };
const tag_latn_script = Tag{ 'l', 'a', 't', 'n' };

fn tagOrder(a: Tag, b: Tag) std.math.Order {
    return std.mem.order(u8, &a, &b);
}

fn bitStorage(v: u32) u6 {
    return if (v == 0) 0 else 32 - @clz(v);
}

pub const MapFeatureFlags = packed struct(u8) {
    /// Feature applies to all characters; uses the global mask bit, no
    /// per-feature mask allocated.
    global: bool = false,
    /// Has a fallback implementation, so include a mask bit even if the
    /// feature isn't found in the font.
    has_fallback: bool = false,
    /// Don't skip over ZWNJ when matching context (complex shapers only).
    manual_zwnj: bool = false,
    /// Don't skip over ZWJ when matching input (complex shapers only).
    manual_zwj: bool = false,
    /// If not found in the LangSys, look for it in the table's global
    /// feature list instead.
    global_search: bool = false,
    /// Randomly select a glyph from an AlternateSubst (complex shapers only).
    random: bool = false,
    /// Contain lookup application to within a syllable (complex shapers only).
    per_syllable: bool = false,
    _pad: u1 = 0,
};

pub const FeatureMapEntry = struct {
    tag: Tag,
    /// GSUB/GPOS feature index, null if not present in that table.
    index: [2]?u16 = .{ null, null },
    stage: [2]u32 = .{ 0, 0 },
    shift: u5 = 0,
    mask: u32 = 0,
    mask_1: u32 = 0,
    needs_fallback: bool = false,
    auto_zwnj: bool = true,
    auto_zwj: bool = true,
    random: bool = false,
    per_syllable: bool = false,
};

pub const LookupMapEntry = struct {
    index: u16,
    mask: u32,
    /// Union of this lookup's subtable Coverages; filled by `shaping.Plan`
    /// (the map builder has no reason to walk subtables). Left full so an
    /// unfilled entry filters nothing.
    digest: common.Digest = common.Digest.full(),
    auto_zwnj: bool = true,
    auto_zwj: bool = true,
    random: bool = false,
    per_syllable: bool = false,
    feature_tag: Tag = .{ ' ', ' ', ' ', ' ' },
};

/// hb registers a `pause_func_t` per stage; this port tags the stage
/// instead and lets the stage-loop driver (shaping.zig) dispatch, so map.zig
/// stays independent of the shapers.
pub const StagePause = enum(u8) {
    none,
    indic_initial_reorder,
    indic_final_reorder,
    clear_substitution_flags,
    use_record_rphf,
    use_record_pref,
    use_reorder,
    myanmar_reorder,
    arabic_record_stch,
};

pub const StageMapEntry = struct {
    /// Cumulative count of lookups (in table order) through this stage.
    last_lookup: u32,
    pause: StagePause = .none,
};

pub const Map = struct {
    global_mask: u32 = 0,
    chosen_script: [2]?Tag = .{ null, null },
    found_script: [2]bool = .{ false, false },
    features: std.ArrayList(FeatureMapEntry) = .empty,
    lookups: [2]std.ArrayList(LookupMapEntry) = .{ .empty, .empty },
    stages: [2]std.ArrayList(StageMapEntry) = .{ .empty, .empty },

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        self.features.deinit(allocator);
        for (&self.lookups) |*l| l.deinit(allocator);
        for (&self.stages) |*s| s.deinit(allocator);
        self.* = undefined;
    }

    fn findFeature(self: Map, tag: Tag) ?*const FeatureMapEntry {
        var lo: usize = 0;
        var hi: usize = self.features.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (tagOrder(self.features.items[mid].tag, tag)) {
                .eq => return &self.features.items[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    pub fn getMask(self: Map, tag: Tag) struct { mask: u32, shift: u5 } {
        const f = self.findFeature(tag) orelse return .{ .mask = 0, .shift = 0 };
        return .{ .mask = f.mask, .shift = f.shift };
    }

    pub fn needsFallback(self: Map, tag: Tag) bool {
        const f = self.findFeature(tag) orelse return false;
        return f.needs_fallback;
    }

    pub fn get1Mask(self: Map, tag: Tag) u32 {
        const f = self.findFeature(tag) orelse return 0;
        return f.mask_1;
    }

    pub fn getFeatureIndex(self: Map, table_index: u1, tag: Tag) ?u16 {
        const f = self.findFeature(tag) orelse return null;
        return f.index[table_index];
    }

    pub fn getFeatureStage(self: Map, table_index: u1, tag: Tag) ?u32 {
        const f = self.findFeature(tag) orelse return null;
        return f.stage[table_index];
    }

    pub fn stageCount(self: Map, table_index: u1) u32 {
        return @intCast(self.stages[table_index].items.len);
    }

    pub fn stagePause(self: Map, table_index: u1, stage: u32) StagePause {
        const stages = self.stages[table_index].items;
        if (stage >= stages.len) return .none;
        return stages[stage].pause;
    }

    pub fn getStageLookups(self: Map, table_index: u1, stage: u32) []const LookupMapEntry {
        const stages = self.stages[table_index].items;
        if (stage >= stages.len) return &.{};
        const start: u32 = if (stage == 0) 0 else stages[stage - 1].last_lookup;
        const end = stages[stage].last_lookup;
        return self.lookups[table_index].items[start..end];
    }
};

const PauseInfo = struct {
    index: u32,
    pause: StagePause,
};

const FeatureInfo = struct {
    tag: Tag,
    seq: u32,
    max_value: u32,
    flags: MapFeatureFlags,
    default_value: u32,
    stage: [2]u32,
};

fn featureInfoLessThan(_: void, a: FeatureInfo, b: FeatureInfo) bool {
    switch (tagOrder(a.tag, b.tag)) {
        .lt => return true,
        .gt => return false,
        .eq => return a.seq < b.seq,
    }
}

fn lookupLessThan(_: void, a: LookupMapEntry, b: LookupMapEntry) bool {
    return a.index < b.index;
}

/// hb's `hb_ot_layout_table_find_feature_variations` for GSUB and GPOS: the
/// FeatureVariation record each table applies at `normalized_coords` (no
/// coords = the default instance). A malformed record list is treated as
/// having none.
pub fn findFeatureVariations(font: parsing.Font, normalized_coords: []const f32) [2]?u32 {
    var result: [2]?u32 = .{ null, null };
    for ([2]Tag{ table_tag_gsub, table_tag_gpos }, 0..) |table_tag, i| {
        const data = font.tableData(table_tag) orelse continue;
        const layout = parsing.Table.Layout{ .data = data };
        result[i] = layout.findFeatureVariationsIndex(normalized_coords) catch null;
    }
    return result;
}

/// Builds a Map for one segment (font + candidate script/language tags),
/// mirroring hb_ot_map_builder_t. Caller adds features with addFeature/
/// enableFeature/disableFeature, then calls compile() once.
pub const MapBuilder = struct {
    allocator: std.mem.Allocator,
    layouts: [2]?parsing.Table.Layout = .{ null, null },
    language: [2]?parsing.Table.Layout.LangSys = .{ null, null },
    chosen_script: [2]?Tag = .{ null, null },
    found_script: [2]bool = .{ false, false },
    variations_index: [2]?u32 = .{ null, null },
    feature_infos: std.ArrayList(FeatureInfo) = .empty,
    current_stage: [2]u32 = .{ 0, 0 },
    pauses: [2]std.ArrayList(PauseInfo) = .{ .empty, .empty },

    pub fn init(allocator: std.mem.Allocator, font: parsing.Font, script_tags: []const Tag, language_tags: []const Tag, variations_index: [2]?u32) (parsing.Font.ParseError || error{OutOfMemory})!MapBuilder {
        var self = MapBuilder{ .allocator = allocator, .variations_index = variations_index };
        const table_tags = [2]Tag{ table_tag_gsub, table_tag_gpos };
        for (table_tags, 0..) |table_tag, i| {
            const data = font.tableData(table_tag) orelse continue;
            const layout = parsing.Table.Layout{ .data = data };
            self.layouts[i] = layout;

            var script: ?parsing.Table.Layout.Script = null;
            for (script_tags) |tag| {
                if (try layout.findScript(tag)) |s| {
                    script = s;
                    self.chosen_script[i] = tag;
                    self.found_script[i] = true;
                    break;
                }
            }
            if (script == null) {
                for ([_]Tag{ tag_dflt_script, tag_dflt_lang, tag_latn_script }) |fallback| {
                    if (try layout.findScript(fallback)) |s| {
                        script = s;
                        self.chosen_script[i] = fallback;
                        break;
                    }
                }
            }
            const s = script orelse continue;

            var lang: ?parsing.Table.Layout.LangSys = null;
            for (language_tags) |tag| {
                if (try s.findLangSys(tag)) |l| {
                    lang = l;
                    break;
                }
            }
            if (lang == null) lang = try s.findLangSys(tag_dflt_lang);
            if (lang == null) lang = try s.defaultLangSys();
            self.language[i] = lang;
        }
        return self;
    }

    pub fn deinit(self: *MapBuilder) void {
        self.feature_infos.deinit(self.allocator);
        for (&self.pauses) |*p| p.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addFeature(self: *MapBuilder, tag: Tag, flags: MapFeatureFlags, value: u32) !void {
        try self.feature_infos.append(self.allocator, .{
            .tag = tag,
            .seq = @intCast(self.feature_infos.items.len + 1),
            .max_value = value,
            .flags = flags,
            .default_value = if (flags.global) value else 0,
            .stage = self.current_stage,
        });
    }

    /// Ported from `hb_ot_map_builder_t::add_pause`: closes the current
    /// stage, so lookups of features added after it are applied only once
    /// every lookup of every earlier stage has run over the whole buffer.
    pub fn addPause(self: *MapBuilder, table_index: u1, pause: StagePause) !void {
        try self.pauses[table_index].append(self.allocator, .{ .index = self.current_stage[table_index], .pause = pause });
        self.current_stage[table_index] += 1;
    }

    pub fn addGsubPause(self: *MapBuilder, pause: StagePause) !void {
        try self.addPause(0, pause);
    }

    pub fn enableFeature(self: *MapBuilder, tag: Tag, flags: MapFeatureFlags, value: u32) !void {
        var f = flags;
        f.global = true;
        try self.addFeature(tag, f, value);
    }

    pub fn disableFeature(self: *MapBuilder, tag: Tag) !void {
        try self.addFeature(tag, .{ .global = true }, 0);
    }

    fn langSysFindFeature(self: MapBuilder, table_index: u1, tag: Tag) !?u16 {
        const layout = self.layouts[table_index] orelse return null;
        const lang = self.language[table_index] orelse return null;
        const count = try lang.featureCount();
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const feature_index = try lang.featureIndexAt(i);
            if (try layout.featureTagAt(feature_index)) |t| {
                if (std.mem.eql(u8, &t, &tag)) return feature_index;
            }
        }
        return null;
    }

    pub fn hasFeature(self: MapBuilder, tag: Tag) !bool {
        inline for (0..2) |table_index| {
            if (try self.langSysFindFeature(table_index, tag) != null) return true;
        }
        return false;
    }

    fn addLookups(
        self: *MapBuilder,
        m: *Map,
        table_index: u1,
        feature_index: ?u16,
        mask: u32,
        auto_zwnj: bool,
        auto_zwj: bool,
        random: bool,
        per_syllable: bool,
        feature_tag: Tag,
    ) !void {
        const idx = feature_index orelse return;
        const layout = self.layouts[table_index] orelse return;
        const lookup_indices = try layout.featureLookups(self.allocator, idx, self.variations_index[table_index]);
        defer self.allocator.free(lookup_indices);
        const table_lookup_count = try layout.lookupCount();
        for (lookup_indices) |li| {
            if (li >= table_lookup_count) continue;
            try m.lookups[table_index].append(self.allocator, .{
                .index = li,
                .mask = mask,
                .auto_zwnj = auto_zwnj,
                .auto_zwj = auto_zwj,
                .random = random,
                .per_syllable = per_syllable,
                .feature_tag = feature_tag,
            });
        }
    }

    /// Sorts and dedups only the lookups this stage appended (`from`
    /// onwards): earlier stages are already closed and must keep their
    /// application order.
    fn sortMergeLookups(list: *std.ArrayList(LookupMapEntry), from: usize) void {
        if (list.items.len <= from + 1) return;
        const tail = list.items[from..];
        common.insertionSort(LookupMapEntry, tail, {}, lookupLessThan);
        var j: usize = from;
        for (list.items[from + 1 ..]) |entry| {
            if (entry.index != list.items[j].index) {
                j += 1;
                list.items[j] = entry;
            } else {
                list.items[j].mask |= entry.mask;
                list.items[j].digest.unionWith(entry.digest);
                list.items[j].auto_zwnj = list.items[j].auto_zwnj and entry.auto_zwnj;
                list.items[j].auto_zwj = list.items[j].auto_zwj and entry.auto_zwj;
            }
        }
        list.shrinkRetainingCapacity(j + 1);
    }

    pub fn compile(self: *MapBuilder, allocator: std.mem.Allocator) !Map {
        var m = Map{};
        errdefer m.deinit(allocator);

        const global_bit_shift: u5 = 31; // 8 * sizeof(u32) - 1
        const global_bit_mask: u32 = @as(u32, 1) << global_bit_shift;
        m.global_mask = global_bit_mask;

        var required_feature_index: [2]?u16 = .{ null, null };
        var required_feature_tag: [2]?Tag = .{ null, null };
        var required_feature_stage: [2]u32 = .{ 0, 0 };

        inline for (0..2) |table_index| {
            m.chosen_script[table_index] = self.chosen_script[table_index];
            m.found_script[table_index] = self.found_script[table_index];
            if (self.language[table_index]) |lang| {
                if (try lang.requiredFeatureIndex()) |idx| {
                    required_feature_index[table_index] = idx;
                    if (self.layouts[table_index]) |layout| {
                        required_feature_tag[table_index] = try layout.featureTagAt(idx);
                    }
                }
            }
        }

        // Sort feature_infos by tag (seq as tiebreak) and merge duplicates,
        // matching hb_ot_map_builder_t::compile's dedup pass.
        common.insertionSort(FeatureInfo, self.feature_infos.items, {}, featureInfoLessThan);
        const infos = self.feature_infos.items;
        if (infos.len > 0) {
            var j: usize = 0;
            for (infos[1..]) |info| {
                if (!std.mem.eql(u8, &info.tag, &infos[j].tag)) {
                    j += 1;
                    infos[j] = info;
                } else {
                    if (info.flags.global) {
                        infos[j].flags.global = true;
                        infos[j].max_value = info.max_value;
                        infos[j].default_value = info.default_value;
                    } else {
                        if (infos[j].flags.global) infos[j].flags.global = false;
                        infos[j].max_value = @max(infos[j].max_value, info.max_value);
                    }
                    if (info.flags.has_fallback) infos[j].flags.has_fallback = true;
                    infos[j].stage[0] = @min(infos[j].stage[0], info.stage[0]);
                    infos[j].stage[1] = @min(infos[j].stage[1], info.stage[1]);
                }
            }
            self.feature_infos.shrinkRetainingCapacity(j + 1);
        }

        // Allocate mask bits. next_bit mirrors hb: reserve the low bits
        // already used by glyph_flag_defined, then hand out MAX_BITS-capped
        // ranges per non-global-bit feature.
        const global_bit_shift_limit = global_bit_shift;
        var next_bit: u5 = @intCast(@popCount(glyph_flag_defined) + 1);

        for (self.feature_infos.items) |info| {
            const bits_needed: u5 = if (info.flags.global and info.max_value == 1)
                0
            else
                @intCast(@min(8, bitStorage(info.max_value)));

            if (info.max_value == 0 or @as(u6, next_bit) + @as(u6, bits_needed) >= global_bit_shift_limit) continue;

            var found = false;
            var feature_index: [2]?u16 = .{ null, null };
            inline for (0..2) |table_index| {
                if (required_feature_tag[table_index]) |rt| {
                    if (std.mem.eql(u8, &rt, &info.tag)) required_feature_stage[table_index] = info.stage[table_index];
                }
                if (try self.langSysFindFeature(table_index, info.tag)) |idx| {
                    feature_index[table_index] = idx;
                    found = true;
                }
            }
            if (!found and info.flags.global_search) {
                inline for (0..2) |table_index| {
                    if (self.layouts[table_index]) |layout| {
                        if (try layout.findFeatureIndex(info.tag)) |idx| {
                            feature_index[table_index] = idx;
                            found = true;
                        }
                    }
                }
            }
            if (!found and !info.flags.has_fallback) continue;

            var entry = FeatureMapEntry{
                .tag = info.tag,
                .index = feature_index,
                .stage = info.stage,
                .auto_zwnj = !info.flags.manual_zwnj,
                .auto_zwj = !info.flags.manual_zwj,
                .random = info.flags.random,
                .per_syllable = info.flags.per_syllable,
                .needs_fallback = !found,
            };
            if (info.flags.global and info.max_value == 1) {
                entry.shift = global_bit_shift;
                entry.mask = global_bit_mask;
            } else {
                entry.shift = next_bit;
                entry.mask = (@as(u32, 1) << @intCast(@as(u6, next_bit) + bits_needed)) -% (@as(u32, 1) << next_bit);
                next_bit += bits_needed;
                m.global_mask |= (info.default_value << entry.shift) & entry.mask;
            }
            entry.mask_1 = (@as(u32, 1) << entry.shift) & entry.mask;
            try m.features.append(allocator, entry);
        }

        // hb's compile() closes both tables with a final pause, so there is
        // always at least one stage even with no shaper-registered pauses.
        try self.addPause(0, .none);
        try self.addPause(1, .none);

        inline for (0..2) |table_index| {
            var pause_index: usize = 0;
            var last_lookup_count: usize = 0;
            var stage: u32 = 0;
            while (stage < self.current_stage[table_index]) : (stage += 1) {
                if (required_feature_index[table_index]) |req_idx| {
                    if (required_feature_stage[table_index] == stage) {
                        try self.addLookups(&m, table_index, req_idx, global_bit_mask, true, true, false, false, .{ ' ', ' ', ' ', ' ' });
                    }
                }
                for (m.features.items) |feature| {
                    if (feature.stage[table_index] == stage) {
                        try self.addLookups(&m, table_index, feature.index[table_index], feature.mask, feature.auto_zwnj, feature.auto_zwj, feature.random, feature.per_syllable, feature.tag);
                    }
                }
                sortMergeLookups(&m.lookups[table_index], last_lookup_count);
                last_lookup_count = m.lookups[table_index].items.len;

                const pauses = self.pauses[table_index].items;
                if (pause_index < pauses.len and pauses[pause_index].index == stage) {
                    try m.stages[table_index].append(allocator, .{
                        .last_lookup = @intCast(last_lookup_count),
                        .pause = pauses[pause_index].pause,
                    });
                    pause_index += 1;
                }
            }
        }

        return m;
    }
};
