//! On-demand Noto font fallback for hosts with no system fonts to ask (web).
//! Ported from Flutter web (engine/src/flutter/lib/web_ui/lib/src/engine/:
//! font_fallbacks.dart, font_fallback_service.dart, noto_font.dart,
//! noto_font_encoding.dart; BSD-3-Clause, The Flutter Authors).
//!
//! The service only decides *which* fonts to fetch; the host fetches
//! `url(font)` however it can (browser `fetch`, retrying transient errors)
//! and reports back with `fontLoaded`/`fontFailed`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.web_fallback);

pub const data = @import("web_fallback_data.zig");

pub const no_parent: u16 = std.math.maxInt(u16);

pub const Font = struct {
    name: []const u8,
    /// Relative to `Service.base_url`.
    url: []const u8,
    /// For a split slice ("Noto Sans SC 12"), the font it was split from.
    monolithic_parent: u16 = no_parent,
};

pub const default_base_url = "https://fonts.gstatic.com/s/";

/// Fonts plus Flutter's packed codepoint -> component -> fonts tables
/// (see `Tables.decode` for the encoding).
pub const FontSet = struct {
    fonts: []const Font,
    encoded_font_sets: []const u8,
    encoded_font_set_ranges: []const u8,

    pub const noto: FontSet = .{
        .fonts = &data.fonts,
        .encoded_font_sets = data.encoded_font_sets,
        .encoded_font_set_ranges = data.encoded_font_set_ranges,
    };
};

const max_codepoint = 0x10ffff;

/// A component is a set of codepoints covered by exactly the same fonts.
pub const Tables = struct {
    component_starts: []u32,
    component_fonts: []u16,
    /// `range_ends[i]` is the exclusive end of range `i`; range 0 starts at 0.
    range_ends: []u32,
    range_components: []u16,

    pub const Error = error{ InvalidFontSet, OutOfMemory };

    pub fn decode(state_gpa: Allocator, set: FontSet) Error!Tables {
        var component_starts: std.ArrayList(u32) = .empty;
        errdefer component_starts.deinit(state_gpa);
        var component_fonts: std.ArrayList(u16) = .empty;
        errdefer component_fonts.deinit(state_gpa);

        try component_starts.append(state_gpa, 0);
        var previous_index: i64 = -1;
        var prefix: u64 = 0;
        for (set.encoded_font_sets) |code| {
            switch (code) {
                'a'...'z' => {
                    const index = previous_index + @as(i64, @intCast(prefix * 26 + (code - 'a'))) + 1;
                    if (index >= set.fonts.len) return error.InvalidFontSet;
                    try component_fonts.append(state_gpa, @intCast(index));
                    previous_index = index;
                    prefix = 0;
                },
                '0'...'9' => prefix = try decimalDigit(prefix, code),
                ',' => {
                    try component_starts.append(state_gpa, @intCast(component_fonts.items.len));
                    previous_index = -1;
                    prefix = 0;
                },
                else => return error.InvalidFontSet,
            }
        }
        try component_starts.append(state_gpa, @intCast(component_fonts.items.len));
        const component_count = component_starts.items.len - 1;

        var range_ends: std.ArrayList(u32) = .empty;
        errdefer range_ends.deinit(state_gpa);
        var range_components: std.ArrayList(u16) = .empty;
        errdefer range_components.deinit(state_gpa);

        var start: u64 = 0;
        var size: u64 = 1;
        prefix = 0;
        for (set.encoded_font_set_ranges) |code| {
            switch (code) {
                'A'...'Z' => {
                    const component = prefix * 26 + (code - 'A');
                    if (component >= component_count) return error.InvalidFontSet;
                    start += size;
                    if (start > max_codepoint + 1) return error.InvalidFontSet;
                    try range_ends.append(state_gpa, @intCast(start));
                    try range_components.append(state_gpa, @intCast(component));
                    prefix = 0;
                    size = 1;
                },
                'a'...'z' => {
                    size = prefix * 26 + (code - 'a') + 2;
                    prefix = 0;
                },
                '0'...'9' => prefix = try decimalDigit(prefix, code),
                else => return error.InvalidFontSet,
            }
        }
        if (start != max_codepoint + 1) return error.InvalidFontSet;

        return .{
            .component_starts = try component_starts.toOwnedSlice(state_gpa),
            .component_fonts = try component_fonts.toOwnedSlice(state_gpa),
            .range_ends = try range_ends.toOwnedSlice(state_gpa),
            .range_components = try range_components.toOwnedSlice(state_gpa),
        };
    }

    fn decimalDigit(prefix: u64, code: u8) error{InvalidFontSet}!u64 {
        if (prefix > max_codepoint) return error.InvalidFontSet;
        return prefix * 10 + (code - '0');
    }

    pub fn deinit(self: *Tables, state_gpa: Allocator) void {
        state_gpa.free(self.component_starts);
        state_gpa.free(self.component_fonts);
        state_gpa.free(self.range_ends);
        state_gpa.free(self.range_components);
        self.* = undefined;
    }

    pub fn componentCount(self: Tables) usize {
        return self.component_starts.len - 1;
    }

    pub fn componentOf(self: Tables, codepoint: u21) u16 {
        var start: usize = 0;
        var end: usize = self.range_ends.len;
        while (start != end) {
            const mid = start + (end - start) / 2;
            if (codepoint >= self.range_ends[mid]) start = mid + 1 else end = mid;
        }
        return self.range_components[start];
    }

    pub fn fontsOf(self: Tables, component: u16) []const u16 {
        return self.component_fonts[self.component_starts[component]..self.component_starts[component + 1]];
    }
};

/// Language tag -> preferred Noto family prefixes, in priority order.
const language_font_preferences = [_]struct { []const u8, []const []const u8 }{
    .{ "zh-Hant", &.{"Noto Sans TC"} },
    .{ "zh-TW", &.{"Noto Sans TC"} },
    .{ "zh-MO", &.{"Noto Sans TC"} },
    .{ "zh-HK", &.{ "Noto Sans HK", "Noto Sans TC" } },
    .{ "ja", &.{"Noto Sans JP"} },
    .{ "ko", &.{"Noto Sans KR"} },
    .{ "zh", &.{"Noto Sans SC"} },
    .{ "zh-Hans", &.{"Noto Sans SC"} },
    .{ "zh-CN", &.{ "Noto Sans SC", "Noto Sans TC" } },
};

const global_tie_breakers = [_][]const u8{
    "Noto Color Emoji",
    "Noto Sans Symbols",
    "Noto Sans SC",
    "Noto Sans TC",
    "Noto Sans HK",
    "Noto Sans JP",
    "Noto Sans KR",
};

fn prefixesForLanguage(language: []const u8) []const []const u8 {
    for (language_font_preferences) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], language)) return entry[1];
    }
    const dash = std.mem.indexOfScalar(u8, language, '-') orelse return &.{};
    for (language_font_preferences) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], language[0..dash])) return entry[1];
    }
    return &.{};
}

pub const Service = struct {
    set: FontSet = .noto,
    /// Fonts are fetched from `base_url` + '/' + their relative path; a
    /// trailing '/' is optional. Not copied.
    base_url: []const u8 = default_base_url,
    /// BCP 47 tag deciding Han glyph shapes (ja/ko/zh-Hans/zh-Hant/zh-HK);
    /// Flutter uses `navigator.language`. Not copied.
    language: ?[]const u8 = null,

    tables: ?Tables = null,
    font_states: []State = &.{},
    /// Fallback priority among registered fonts covering the same codepoint
    /// (lower wins); Flutter's `globalFontFallbacks` order.
    font_ranks: []u32 = &.{},
    next_rank: u32 = 1,
    failed_fonts_per_component: std.AutoHashMapUnmanaged(u16, u8) = .empty,
    unprocessed: std.AutoArrayHashMapUnmanaged(u21, void) = .empty,
    unsupported: std.AutoHashMapUnmanaged(u21, void) = .empty,
    registered_count: u32 = 0,
    total_permanent_failures: u32 = 0,
    broken: bool = false,
    /// Set whenever `process` could have new work.
    needs_process: bool = false,

    pub const State = enum(u8) { idle, pending, registered, unavailable };

    const unranked = std.math.maxInt(u32);
    const max_fonts_per_component = 5;
    const max_global_failures_before_broken = 10;

    pub fn deinit(self: *Service, state_gpa: Allocator) void {
        if (self.tables) |*tables| tables.deinit(state_gpa);
        state_gpa.free(self.font_states);
        state_gpa.free(self.font_ranks);
        self.failed_fonts_per_component.deinit(state_gpa);
        self.unprocessed.deinit(state_gpa);
        self.unsupported.deinit(state_gpa);
        self.* = undefined;
    }

    fn ensureTables(self: *Service, state_gpa: Allocator) Tables.Error!Tables {
        if (self.tables) |tables| return tables;
        var tables = try Tables.decode(state_gpa, self.set);
        errdefer tables.deinit(state_gpa);
        const states = try state_gpa.alloc(State, self.set.fonts.len);
        errdefer state_gpa.free(states);
        const ranks = try state_gpa.alloc(u32, self.set.fonts.len);
        @memset(states, .idle);
        @memset(ranks, unranked);
        self.font_states = states;
        self.font_ranks = ranks;
        self.tables = tables;
        return tables;
    }

    pub fn url(self: *const Service, font: u16, buf: []u8) error{NoSpaceLeft}![]const u8 {
        const separator = if (std.mem.endsWith(u8, self.base_url, "/")) "" else "/";
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ self.base_url, separator, self.set.fonts[font].url });
    }

    fn parentOf(self: *const Service, font: u16) ?u16 {
        const parent = self.set.fonts[font].monolithic_parent;
        return if (parent == no_parent) null else parent;
    }

    fn isRegistered(self: *const Service, font: u16) bool {
        if (self.font_states[font] == .registered) return true;
        const parent = self.parentOf(font) orelse return false;
        return self.font_states[parent] == .registered;
    }

    fn isPending(self: *const Service, font: u16) bool {
        if (self.font_states[font] == .pending) return true;
        const parent = self.parentOf(font) orelse return false;
        return self.font_states[parent] == .pending;
    }

    /// Highest-priority registered font covering `codepoint`, if any.
    pub fn registeredFontFor(self: *const Service, codepoint: u21) ?u16 {
        const tables = self.tables orelse return null;
        var best: ?u16 = null;
        for (tables.fontsOf(tables.componentOf(codepoint))) |font| {
            const candidate = if (self.font_states[font] == .registered) font else if (self.parentOf(font)) |parent|
                (if (self.font_states[parent] == .registered) parent else continue)
            else
                continue;
            if (best == null or self.font_ranks[candidate] < self.font_ranks[best.?]) best = candidate;
        }
        return best;
    }

    /// Queues `codepoint` for the next `process`; a no-op for codepoints
    /// already queued, already covered, or known unsupported.
    pub fn addMissingCodepoint(self: *Service, state_gpa: Allocator, codepoint: u21) Tables.Error!void {
        const tables = try self.ensureTables(state_gpa);
        if (self.unsupported.contains(codepoint) or self.unprocessed.contains(codepoint)) return;
        for (tables.fontsOf(tables.componentOf(codepoint))) |font| {
            if (self.isRegistered(font)) return;
        }
        try self.unprocessed.put(state_gpa, codepoint, {});
        self.needs_process = true;
    }

    /// Greedily picks the fewest fonts covering every queued codepoint that
    /// isn't already covered, pending, or unsupported; appends them to
    /// `out` (allocated with `scratch`) and marks them pending.
    pub fn process(self: *Service, state_gpa: Allocator, scratch: Allocator, out: *std.ArrayList(u16)) Allocator.Error!void {
        self.needs_process = false;
        const tables = self.tables orelse return;

        var gap: std.AutoArrayHashMapUnmanaged(u16, i64) = .empty;
        defer gap.deinit(scratch);
        var warned = false;

        var i: usize = 0;
        while (i < self.unprocessed.count()) {
            const codepoint = self.unprocessed.keys()[i];
            const component = tables.componentOf(codepoint);
            const fonts = tables.fontsOf(component);

            const covered = for (fonts) |font| {
                if (self.isRegistered(font)) break true;
            } else false;
            if (covered) {
                self.unprocessed.swapRemoveAt(i);
                continue;
            }
            const pending = for (fonts) |font| {
                if (self.isPending(font)) break true;
            } else false;
            if (pending) {
                i += 1;
                continue;
            }
            const all_unavailable = for (fonts) |font| {
                if (self.font_states[font] != .unavailable) break false;
            } else true;
            if (self.broken or all_unavailable or (self.failed_fonts_per_component.get(component) orelse 0) >= max_fonts_per_component) {
                if (!warned) log.warn("no Noto fallback font available for U+{X:0>4}", .{codepoint});
                warned = true;
                try self.unsupported.put(state_gpa, codepoint, {});
                self.unprocessed.swapRemoveAt(i);
                continue;
            }
            const entry = try gap.getOrPut(scratch, component);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
            i += 1;
        }
        if (gap.count() == 0) return;

        const first_new = out.items.len;
        try self.findFontsForComponents(tables, scratch, &gap, out);
        for (out.items[first_new..]) |font| self.font_states[font] = .pending;
    }

    fn findFontsForComponents(
        self: *const Service,
        tables: Tables,
        scratch: Allocator,
        gap: *std.AutoArrayHashMapUnmanaged(u16, i64),
        out: *std.ArrayList(u16),
    ) Allocator.Error!void {
        var candidates: std.AutoArrayHashMapUnmanaged(u16, i64) = .empty;
        defer candidates.deinit(scratch);
        var font_components: std.AutoHashMapUnmanaged(u16, std.ArrayList(u16)) = .empty;
        defer {
            var it = font_components.valueIterator();
            while (it.next()) |list| list.deinit(scratch);
            font_components.deinit(scratch);
        }

        for (gap.keys(), gap.values()) |component, count| {
            for (tables.fontsOf(component)) |font| {
                if (self.font_states[font] == .unavailable) continue;
                const cover = try candidates.getOrPut(scratch, font);
                if (!cover.found_existing) cover.value_ptr.* = 0;
                cover.value_ptr.* += count;
                const list = try font_components.getOrPut(scratch, font);
                if (!list.found_existing) list.value_ptr.* = .empty;
                try list.value_ptr.append(scratch, component);
            }
        }

        // Slices propagate their weight to a parent only if it's a candidate anyway.
        const initial_candidates = try scratch.dupe(u16, candidates.keys());
        defer scratch.free(initial_candidates);
        for (initial_candidates) |font| {
            const parent = self.parentOf(font) orelse continue;
            const parent_cover = candidates.getPtr(parent) orelse continue;
            parent_cover.* += candidates.get(font).?;
            const slice_components = font_components.get(font).?.items;
            try font_components.getPtr(parent).?.appendSlice(scratch, slice_components);
        }

        while (candidates.count() > 0) {
            const selected = self.selectBestFont(&candidates);
            try out.append(scratch, selected);
            _ = candidates.swapRemove(selected);

            for (font_components.get(selected).?.items) |component| {
                const count = gap.getPtr(component).?;
                if (count.* == 0) continue;
                for (tables.fontsOf(component)) |font| {
                    if (candidates.getPtr(font)) |cover| cover.* -= count.*;
                    const parent = self.parentOf(font) orelse continue;
                    if (candidates.getPtr(parent)) |cover| cover.* -= count.*;
                }
                count.* = 0;
            }

            var j: usize = 0;
            while (j < candidates.count()) {
                if (candidates.values()[j] <= 0) candidates.swapRemoveAt(j) else j += 1;
            }
        }
    }

    /// Language preference, then maximum coverage, then Flutter's global
    /// tie-breakers, then lowest font index.
    fn selectBestFont(self: *const Service, candidates: *const std.AutoArrayHashMapUnmanaged(u16, i64)) u16 {
        const fonts = candidates.keys();
        const covers = candidates.values();

        if (self.language) |language| {
            for (prefixesForLanguage(language)) |prefix| {
                if (self.maxCoverageFont(fonts, covers, prefix, 1)) |font| return font;
            }
        }

        var max_cover: i64 = std.math.minInt(i64);
        for (covers) |cover| max_cover = @max(max_cover, cover);
        for (global_tie_breakers) |prefix| {
            if (self.maxCoverageFont(fonts, covers, prefix, max_cover)) |font| return font;
        }
        return self.maxCoverageFont(fonts, covers, "", max_cover).?;
    }

    /// Among fonts named `prefix`* with cover >= `min_cover`: the highest
    /// cover, lowest font index on ties.
    fn maxCoverageFont(self: *const Service, fonts: []const u16, covers: []const i64, prefix: []const u8, min_cover: i64) ?u16 {
        var best: ?usize = null;
        for (fonts, covers, 0..) |font, cover, k| {
            if (cover < min_cover or !std.mem.startsWith(u8, self.set.fonts[font].name, prefix)) continue;
            if (best) |b| {
                if (cover < covers[b] or (cover == covers[b] and font > fonts[b])) continue;
            }
            best = k;
        }
        return if (best) |b| fonts[b] else null;
    }

    pub fn fontLoaded(self: *Service, font: u16) void {
        self.font_states[font] = .registered;
        self.registered_count += 1;
        self.needs_process = true;

        const name = self.set.fonts[font].name;
        var rank = self.next_rank;
        // A monolithic parent takes the place of its earliest registered slice.
        for (self.set.fonts, 0..) |candidate, slice| {
            if (candidate.monolithic_parent == font) rank = @min(rank, self.font_ranks[slice]);
        }
        if (std.mem.startsWith(u8, name, "Noto Color Emoji") or std.mem.eql(u8, name, "Noto Emoji")) rank = 0;
        self.font_ranks[font] = rank;
        self.next_rank += 1;
    }

    /// Permanent failure, after the host's own retries.
    pub fn fontFailed(self: *Service, state_gpa: Allocator, font: u16) void {
        const tables = self.tables.?;
        self.font_states[font] = .unavailable;
        self.total_permanent_failures += 1;
        self.needs_process = true;
        for (0..tables.componentCount()) |component| {
            if (std.mem.indexOfScalar(u16, tables.fontsOf(@intCast(component)), font) == null) continue;
            const entry = self.failed_fonts_per_component.getOrPut(state_gpa, @intCast(component)) catch continue;
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* +|= 1;
        }
        if (self.registered_count == 0 and self.total_permanent_failures >= max_global_failures_before_broken) {
            log.warn("font fallback disabled after {d} failures; check base_url \"{s}\"", .{ self.total_permanent_failures, self.base_url });
            self.broken = true;
        }
    }
};
