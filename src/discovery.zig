const std = @import("std");
const build_options = @import("build_options");

/// Platform font-discovery backends, each compiled in only when its build
/// option is on (see build.zig) — a link-time dependency like CoreText or
/// DirectWrite shouldn't attach to a consumer that never asked for it.
pub const fontconfig = if (build_options.fontconfig) @import("discovery/fontconfig.zig") else struct {};
pub const core_text = if (build_options.core_text) @import("discovery/core_text.zig") else struct {};
pub const directwrite = if (build_options.directwrite) @import("discovery/directwrite.zig") else struct {};
pub const android = if (build_options.android) @import("discovery/android.zig") else struct {};
pub const manifest = if (build_options.manifest) @import("discovery/manifest.zig") else struct {};
pub const web_fallback = if (build_options.font_fallback) @import("discovery/web_fallback.zig") else struct {};

test {
    _ = fontconfig;
    _ = android;
}

// NOTE: ported from vendor/font-kit (src/properties.rs, src/handle.rs,
// src/family_name.rs, src/matching.rs) — see CLAUDE.md vendor list.

pub const Style = enum {
    normal,
    italic,
    oblique,
};

pub const Weight = struct {
    value: f32 = normal.value,

    pub const thin: Weight = .{ .value = 100.0 };
    pub const extra_light: Weight = .{ .value = 200.0 };
    pub const light: Weight = .{ .value = 300.0 };
    pub const normal: Weight = .{ .value = 400.0 };
    pub const medium: Weight = .{ .value = 500.0 };
    pub const semibold: Weight = .{ .value = 600.0 };
    pub const bold: Weight = .{ .value = 700.0 };
    pub const extra_bold: Weight = .{ .value = 800.0 };
    pub const black: Weight = .{ .value = 900.0 };
};

pub const Stretch = struct {
    value: f32 = normal.value,

    pub const ultra_condensed: Stretch = .{ .value = 0.5 };
    pub const extra_condensed: Stretch = .{ .value = 0.625 };
    pub const condensed: Stretch = .{ .value = 0.75 };
    pub const semi_condensed: Stretch = .{ .value = 0.875 };
    pub const normal: Stretch = .{ .value = 1.0 };
    pub const semi_expanded: Stretch = .{ .value = 1.125 };
    pub const expanded: Stretch = .{ .value = 1.25 };
    pub const extra_expanded: Stretch = .{ .value = 1.5 };
    pub const ultra_expanded: Stretch = .{ .value = 2.0 };
};

pub const Properties = struct {
    style: Style = .normal,
    weight: Weight = .normal,
    stretch: Stretch = .normal,
    /// A variable face's `wght`/`wdth` axis span. Matching treats the face
    /// as every value in the range (CSS Fonts 4 §5.2), so the caller
    /// instances it at the requested value instead of `weight`/`stretch`.
    weight_range: ?Range = null,
    stretch_range: ?Range = null,
    /// Axis values a named instance of a variable face is fixed at (Android
    /// fonts.xml `<axis>`); a renderer applies these unless the caller pins
    /// the same axis itself.
    pinned_axes: [max_pinned_axes]PinnedAxis = undefined,
    pinned_axis_count: u8 = 0,

    pub const Range = struct { min: f32, max: f32 };
    pub const PinnedAxis = struct { tag: [4]u8, value: f32 };
    pub const max_pinned_axes = 4;

    pub fn pinnedAxes(self: *const Properties) []const PinnedAxis {
        return self.pinned_axes[0..self.pinned_axis_count];
    }
};

/// A value for the CSS `font-family` property (CSS Fonts Level 4 §2.1.3).
/// `cursive` and `fantasy` are left out: no font shared between platforms
/// to map them to. `system_ui` is deliberately per-OS (SF on macOS, Segoe UI
/// on Windows), so it has no metric-compatible chain.
pub const FamilyName = union(enum) {
    title: []const u8,
    serif,
    sans_serif,
    monospace,
    system_ui,

    /// The supported CSS generic-family keywords, in CSS's own spelling — a
    /// UI offering "pick a font" wants these listed alongside the concrete
    /// families from `availableFamilies`.
    pub const generic_keywords = [_][]const u8{ "serif", "sans-serif", "monospace", "system-ui" };

    /// Parses a `font-family` string: a generic keyword becomes its tag
    /// (so `generic_family_chains` and a backend's `generic_family_names`
    /// get a chance to run), anything else is a literal family title.
    pub fn fromString(name: []const u8) FamilyName {
        inline for (generic_keywords, 0..) |keyword, i| {
            if (std.mem.eql(u8, name, keyword)) return switch (i) {
                0 => .serif,
                1 => .sans_serif,
                2 => .monospace,
                else => .system_ui,
            };
        }
        return .{ .title = name };
    }

    pub fn toString(self: FamilyName) []const u8 {
        return switch (self) {
            .title => |title| title,
            .serif => generic_keywords[0],
            .sans_serif => generic_keywords[1],
            .monospace => generic_keywords[2],
            .system_ui => generic_keywords[3],
        };
    }

    pub fn isGeneric(name: []const u8) bool {
        return std.meta.activeTag(fromString(name)) != .title;
    }
};

pub const Handle = union(enum) {
    path: struct { path: []const u8, font_index: u32 = 0 },
    memory: struct { bytes: []const u8, font_index: u32 = 0 },
    /// A font resolved to a location, not yet fetched — for backends (e.g.
    /// `discovery/manifest.zig`) whose source data isn't retrievable
    /// synchronously. The caller is responsible for turning this into a
    /// `memory` handle (fetch `url`, hand the bytes back) before parsing.
    url: struct { url: []const u8, font_index: u32 = 0 },
};

pub const SelectionError = error{NotFound};

/// CSS Fonts Level 3 §5.2 font-style matching, applied over `candidates`
/// (`stretch` then `style` then `weight`, most-specific criterion first).
///
/// Ported from font-kit's `matching::find_best_match`, which builds a `Vec`
/// and narrows it with three `retain` passes.
pub fn findBestMatch(candidates: []const Properties, query: Properties, index_buf: []usize) SelectionError!usize {
    std.debug.assert(index_buf.len >= candidates.len);
    if (candidates.len == 0) return SelectionError.NotFound;

    var set_len = candidates.len;
    for (0..candidates.len) |i| index_buf[i] = i;

    const matching_stretch = findClosestStretch(candidates, index_buf[0..set_len], query.stretch);
    set_len = retain(candidates, index_buf[0..set_len], .stretch, matching_stretch);

    const matching_style = findPreferredStyle(candidates, index_buf[0..set_len], query.style);
    set_len = retain(candidates, index_buf[0..set_len], .style, matching_style);

    const matching_weight = findClosestWeight(candidates, index_buf[0..set_len], query.weight);
    set_len = retain(candidates, index_buf[0..set_len], .weight, matching_weight);

    if (set_len == 0) return SelectionError.NotFound;
    return index_buf[0];
}

const Axis = enum { stretch, weight };

/// The value in `candidate`'s span closest to `query`: a static face's only
/// value, or `query` clamped into a variable face's axis range.
fn nearestValue(candidate: Properties, comptime axis: Axis, query: f32) f32 {
    const value, const range = switch (axis) {
        .stretch => .{ candidate.stretch.value, candidate.stretch_range },
        .weight => .{ candidate.weight.value, candidate.weight_range },
    };
    const r = range orelse return value;
    return std.math.clamp(query, r.min, r.max);
}

fn retain(candidates: []const Properties, set: []usize, comptime field: enum { stretch, style, weight }, value: anytype) usize {
    var write: usize = 0;
    for (set) |index| {
        const matches = switch (field) {
            .stretch => nearestValue(candidates[index], .stretch, value.value) == value.value,
            .style => candidates[index].style == value,
            .weight => nearestValue(candidates[index], .weight, value.value) == value.value,
        };
        if (matches) {
            set[write] = index;
            write += 1;
        }
    }
    return write;
}

fn findClosestStretch(candidates: []const Properties, set: []const usize, query: Stretch) Stretch {
    for (set) |index| {
        if (nearestValue(candidates[index], .stretch, query.value) == query.value) return query;
    }
    if (query.value <= Stretch.normal.value) {
        if (closestBy(candidates, set, query, .stretch, .narrower)) |s| return s;
        return closestBy(candidates, set, query, .stretch, .any).?;
    } else {
        if (closestBy(candidates, set, query, .stretch, .wider)) |s| return s;
        return closestBy(candidates, set, query, .stretch, .any).?;
    }
}

fn findClosestWeight(candidates: []const Properties, set: []const usize, query: Weight) Weight {
    for (set) |index| {
        if (nearestValue(candidates[index], .weight, query.value) == query.value) return query;
    }
    // CSS Fonts Level 3 doesn't define the 400..500 exclusive case; font-kit
    // (and browsers) special-case 450 as the tiebreak boundary.
    if (query.value >= 400.0 and query.value < 450.0 and hasWeight(candidates, set, 500.0)) {
        return .medium;
    }
    if (query.value >= 450.0 and query.value <= 500.0 and hasWeight(candidates, set, 400.0)) {
        return .normal;
    }
    if (query.value <= 500.0) {
        if (closestBy(candidates, set, query, .weight, .narrower)) |w| return w;
        return closestBy(candidates, set, query, .weight, .any).?;
    } else {
        if (closestBy(candidates, set, query, .weight, .wider)) |w| return w;
        return closestBy(candidates, set, query, .weight, .any).?;
    }
}

fn hasWeight(candidates: []const Properties, set: []const usize, value: f32) bool {
    for (set) |index| {
        if (nearestValue(candidates[index], .weight, value) == value) return true;
    }
    return false;
}

const ClosestDirection = enum { narrower, wider, any };

fn closestBy(
    candidates: []const Properties,
    set: []const usize,
    query: anytype,
    comptime field: Axis,
    direction: ClosestDirection,
) ?@TypeOf(query) {
    var best: ?@TypeOf(query) = null;
    var best_delta: f32 = std.math.floatMax(f32);
    for (set) |index| {
        const candidate_value: @TypeOf(query) = .{ .value = nearestValue(candidates[index], field, query.value) };
        const in_direction = switch (direction) {
            .narrower => candidate_value.value < query.value,
            .wider => candidate_value.value > query.value,
            .any => true,
        };
        if (!in_direction) continue;
        const delta = @abs(candidate_value.value - query.value);
        if (delta < best_delta) {
            best_delta = delta;
            best = candidate_value;
        }
    }
    return best;
}

fn findPreferredStyle(candidates: []const Properties, set: []const usize, query: Style) Style {
    const preference: [3]Style = switch (query) {
        .italic => .{ .italic, .oblique, .normal },
        .oblique => .{ .oblique, .italic, .normal },
        .normal => .{ .normal, .oblique, .italic },
    };
    for (preference) |style| {
        for (set) |index| {
            if (candidates[index].style == style) return style;
        }
    }
    unreachable; // set is non-empty and every candidate has some Style
}

/// A set of font handles installed under one family name, with their
/// matching properties in the same order.
///
/// Diverges from font-kit's `FamilyHandle` (which holds only `fonts` — a
/// separate `Source::select_descriptions_in_family` call then opens and
/// reparses every font file to read style/weight/stretch): backends here
/// fill `properties` from whatever they already have on hand while listing
/// family members (e.g. the Fontconfig backend gets `slant`/`weight`/
/// `width` for free in the same query), so there's no second pass.
pub const FamilyHandle = struct {
    fonts: []const Handle,
    properties: []const Properties,
};

/// Family-name listing built in caller-owned buffers, the same no-alloc
/// shape as `selectFamilyByName`'s `handle_buf`/`path_storage`. Backends'
/// `availableFamilies(names_buf, name_storage, allocator) []const []const u8`
/// fill one of these: the OS lists a family once per face (fontconfig) or
/// with localized duplicates (CoreText), so appends dedupe, and both buffers
/// are hard caps — a machine with more fonts installed than fit just yields
/// a truncated list.
pub const FamilyList = struct {
    names: [][]const u8,
    storage: []u8,
    count: usize = 0,
    used: usize = 0,

    pub fn append(self: *FamilyList, name: []const u8) void {
        if (name.len == 0) return;
        if (self.count >= self.names.len or self.used + name.len > self.storage.len) return;
        for (self.names[0..self.count]) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const owned = self.storage[self.used..][0..name.len];
        @memcpy(owned, name);
        self.used += name.len;
        self.names[self.count] = owned;
        self.count += 1;
    }

    pub fn slice(self: *const FamilyList) []const []const u8 {
        return self.names[0..self.count];
    }
};

/// Tried before a backend's own generic name, so a generic lands on the same
/// metrics on every OS. Each chain is metric-compatible: Liberation and
/// Arimo/Tinos clone Arial/Times New Roman, and Menlo and DejaVu Sans Mono
/// both derive from Bitstream Vera Sans Mono. Android's fonts.xml aliases
/// "arial"/"times new roman" to its own sans-serif/serif, so those hit too.
pub const generic_family_chains = struct {
    pub const serif = [_][]const u8{ "Times New Roman", "Liberation Serif", "Tinos" };
    pub const sans_serif = [_][]const u8{ "Arial", "Liberation Sans", "Arimo" };
    pub const monospace = [_][]const u8{ "Menlo", "DejaVu Sans Mono", "Bitstream Vera Sans Mono", "Consolas" };
    pub const system_ui = [_][]const u8{};
};

/// Last resort after `generic_family_chains`, ported from font-kit's
/// `source.rs` `cfg(not(windows/macos/ios))` block: fontconfig (and other
/// backends that natively resolve CSS generic aliases) can look these up
/// as-is.
const generic_family_names = struct {
    const serif = "serif";
    const sans_serif = "sans-serif";
    const monospace = "monospace";
    const system_ui = "system-ui";
};

/// Resolves a `FamilyName` (title or CSS generic) to a family, by calling
/// `source.selectFamilyByName(name, handle_buf, properties_buf, scratch...) SelectionError!FamilyHandle`.
/// A generic tries each `generic_family_chains` entry first, then the
/// backend's own generic name.
///
/// `scratch` is forwarded verbatim after `properties_buf` — backends that
/// need extra caller-owned working memory beyond the two buffers (e.g. the
/// Fontconfig backend's `path_storage`, since fontconfig's own path
/// strings don't outlive the call) take it as trailing parameters instead
/// of this function hardcoding one scratch shape for every backend.
///
/// Ported from font-kit's `Source::select_family_by_generic_name`. No
/// vtable: `source` is any backend (e.g. a `Fontconfig` source) providing
/// that method — comptime duck-typing per [[feedback_zig_no_vtables]].
///
/// A backend can override the generic->real name mapping (font-kit does
/// this per-platform, e.g. CoreText has no native alias resolution for
/// "sans-serif" the way fontconfig does) by declaring its own
/// `pub const generic_family_names = struct { const serif = "..."; ... };`
/// with the same fields as the default table above.
pub fn selectFamilyByGenericName(
    source: anytype,
    family_name: FamilyName,
    handle_buf: []Handle,
    properties_buf: []Properties,
    scratch: anytype,
) SelectionError!FamilyHandle {
    const names = if (@hasDecl(@TypeOf(source.*), "generic_family_names"))
        @TypeOf(source.*).generic_family_names
    else
        generic_family_names;
    const chain: []const []const u8 = switch (family_name) {
        .title => |title| return selectFamilyByTitle(source, title, handle_buf, properties_buf, scratch),
        .serif => &generic_family_chains.serif,
        .sans_serif => &generic_family_chains.sans_serif,
        .monospace => &generic_family_chains.monospace,
        .system_ui => &generic_family_chains.system_ui,
    };
    for (chain) |name| {
        return selectFamilyByTitle(source, name, handle_buf, properties_buf, scratch) catch continue;
    }
    const native_name: []const u8 = switch (family_name) {
        .title => unreachable,
        .serif => names.serif,
        .sans_serif => names.sans_serif,
        .monospace => names.monospace,
        .system_ui => names.system_ui,
    };
    return selectFamilyByTitle(source, native_name, handle_buf, properties_buf, scratch);
}

fn selectFamilyByTitle(
    source: anytype,
    name: []const u8,
    handle_buf: []Handle,
    properties_buf: []Properties,
    scratch: anytype,
) SelectionError!FamilyHandle {
    return @call(.auto, @TypeOf(source.*).selectFamilyByName, .{ source, name, handle_buf, properties_buf } ++ scratch);
}

/// Collapses a BCP 47 tag or POSIX locale ("zh_TW.UTF-8") to what font
/// fallback distinguishes: the primary language, except Chinese, which
/// splits by script since Simplified and Traditional Han glyphs differ.
pub fn fallbackLanguage(tag: []const u8) []const u8 {
    var subtags = std.mem.tokenizeAny(u8, tag, "-_.@");
    const primary = subtags.next() orelse return tag;
    if (!std.ascii.eqlIgnoreCase(primary, "zh")) return primary;
    while (subtags.next()) |subtag| {
        for ([_][]const u8{ "Hant", "TW", "HK", "MO" }) |traditional| {
            if (std.ascii.eqlIgnoreCase(subtag, traditional)) return "zh-Hant";
        }
    }
    return "zh-Hans";
}

/// CSS Fonts Level 3 font matching over a source's families, in family-name
/// preference order. Ported from font-kit's `Source::select_best_match`.
/// See `selectFamilyByGenericName` for what `scratch` is.
pub fn selectBestMatch(
    source: anytype,
    family_names: []const FamilyName,
    properties: Properties,
    handle_buf: []Handle,
    properties_buf: []Properties,
    index_buf: []usize,
    scratch: anytype,
) ?Match {
    for (family_names) |family_name| {
        const family = selectFamilyByGenericName(source, family_name, handle_buf, properties_buf, scratch) catch continue;
        if (family.fonts.len == 0) continue;
        const index = findBestMatch(family.properties, properties, index_buf[0..family.fonts.len]) catch continue;
        return .{ .handle = family.fonts[index], .properties = family.properties[index] };
    }
    return null;
}

pub const Match = struct { handle: Handle, properties: Properties };
