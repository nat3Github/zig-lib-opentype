const std = @import("std");
const discovery = @import("../discovery.zig");
const parsing = @import("../parsing.zig");
const unicode = @import("../unicode.zig");

// NOTE: ported from vendor/font-kit (src/sources/core_text.rs,
// src/loaders/core_text.rs)
//
// Diverges from font-kit in two ways:
// 1. Weight/width/slant come straight from `kCTFontTraitsAttribute` on the
//    matching `CTFontDescriptor`s, the same call that already lists family
//    members — font-kit's Rust loader instead opens and reparses every font
//    file's tables via its own `Font::properties()`. Same "properties
//    bundled into FamilyHandle" divergence as the Fontconfig backend.
// 2. CoreText has no API to report which face of a `.ttc` a descriptor
//    refers to (font-kit's own comment: "there's no API to load OpenType
//    collections on macOS"). font-kit resolves this by opening the file and
//    matching PostScript names via its own font loader; this backend does
//    the same but with this codebase's own `parsing.zig` (`Table.name`,
//    `Collection`) instead of pulling in a second OpenType parser.
const c = @import("core_text_bindings.zig");

// CoreText's normalized (-1..1) weight/width axes vs. CSS weight/stretch,
// ported verbatim from font-kit's `loaders/core_text.rs` piecewise-linear
// tables (`FONT_WEIGHT_MAPPING`, `Stretch::MAPPING`).
const font_weight_mapping = [9]f32{ -0.7, -0.5, -0.23, 0.0, 0.2, 0.3, 0.4, 0.6, 0.8 };
const stretch_mapping = [9]f32{
    discovery.Stretch.ultra_condensed.value,
    discovery.Stretch.extra_condensed.value,
    discovery.Stretch.condensed.value,
    discovery.Stretch.semi_condensed.value,
    discovery.Stretch.normal.value,
    discovery.Stretch.semi_expanded.value,
    discovery.Stretch.expanded.value,
    discovery.Stretch.extra_expanded.value,
    discovery.Stretch.ultra_expanded.value,
};

pub const CoreText = struct {
    /// CoreText has no native CSS-generic-alias resolution the way
    /// fontconfig does ("sans-serif" doesn't match any real family), so
    /// override discovery.zig's default table with font-kit's macOS
    /// hardcoded picks (`source.rs`, `cfg(any(windows, macos, ios))` block).
    pub const generic_family_names = struct {
        pub const serif = "Times New Roman";
        pub const sans_serif = "Arial";
        pub const monospace = "Courier New";
        // CoreText's own alias for the hidden `.AppleSystemUIFont` (SF).
        pub const system_ui = "System Font";
    };

    /// BCP 47 tag steering `selectFallbackForCodepoint` (e.g. Japanese vs.
    /// Chinese Han glyphs); `null` leaves it to the user's system languages.
    language: ?[]const u8 = null,

    pub fn init() discovery.SelectionError!CoreText {
        return .{};
    }

    pub fn deinit(self: *CoreText) void {
        self.* = undefined;
    }

    /// Looks up a font family by name and writes its member fonts and their
    /// properties into caller-owned `handle_buf`/`properties_buf` (same
    /// length). `path_storage` backs the returned `Handle.path.path` slices,
    /// same no-alloc pattern as the Fontconfig backend.
    pub fn selectFamilyByName(
        self: *const CoreText,
        family_name: []const u8,
        handle_buf: []discovery.Handle,
        properties_buf: []discovery.Properties,
        path_storage: []u8,
        allocator: std.mem.Allocator,
    ) discovery.SelectionError!discovery.FamilyHandle {
        _ = self;
        std.debug.assert(handle_buf.len == properties_buf.len);

        const family_cfstr = c.CFStringCreateWithBytes(null, family_name.ptr, @intCast(family_name.len), c.kCFStringEncodingUTF8, 0) orelse
            return discovery.SelectionError.NotFound;
        defer c.CFRelease(family_cfstr);

        var keys = [_]c.CFTypeRef{c.kCTFontFamilyNameAttribute};
        var values = [_]c.CFTypeRef{family_cfstr};
        const attributes = c.CFDictionaryCreate(
            null,
            @ptrCast(&keys),
            @ptrCast(&values),
            1,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        ) orelse return discovery.SelectionError.NotFound;
        defer c.CFRelease(attributes);

        const descriptor = c.CTFontDescriptorCreateWithAttributes(attributes) orelse return discovery.SelectionError.NotFound;
        defer c.CFRelease(descriptor);

        var descriptor_values = [_]c.CFTypeRef{descriptor};
        const descriptors = c.CFArrayCreate(null, @ptrCast(&descriptor_values), 1, &c.kCFTypeArrayCallBacks) orelse
            return discovery.SelectionError.NotFound;
        defer c.CFRelease(descriptors);

        const collection = c.CTFontCollectionCreateWithFontDescriptors(descriptors, null) orelse return discovery.SelectionError.NotFound;
        defer c.CFRelease(collection);

        const matches = c.CTFontCollectionCreateMatchingFontDescriptors(collection) orelse return discovery.SelectionError.NotFound;
        defer c.CFRelease(matches);

        const count: usize = @intCast(c.CFArrayGetCount(matches));
        if (count == 0) return discovery.SelectionError.NotFound;

        var out_count: usize = 0;
        var path_offset: usize = 0;
        for (0..count) |i| {
            if (out_count >= handle_buf.len) break;
            const desc: c.CTFontDescriptorRef = @ptrCast(@alignCast(c.CFArrayGetValueAtIndex(matches, @intCast(i))));

            const path = copyFilePath(desc, path_storage[path_offset..]) orelse continue;
            const properties = readProperties(desc);
            // CoreText lists a variable face once per named instance ("System
            // Font" alone is hundreds); its axis ranges already cover them.
            if (properties.weight_range != null or properties.stretch_range != null) {
                if (listsPath(handle_buf[0..out_count], path)) continue;
            }
            path_offset += path.len;

            handle_buf[out_count] = .{ .path = .{ .path = path, .font_index = resolveFontIndex(desc, path, allocator) } };
            properties_buf[out_count] = properties;
            out_count += 1;
        }

        if (out_count == 0) return discovery.SelectionError.NotFound;
        return .{ .fonts = handle_buf[0..out_count], .properties = properties_buf[0..out_count] };
    }

    /// Lists every font family installed on this machine, in
    /// `CTFontManagerCopyAvailableFontFamilyNames` order (CoreText's own
    /// catalog — the same list Font Book shows). See `discovery.FamilyList`
    /// for the buffer contract.
    pub fn availableFamilies(
        self: *const CoreText,
        names_buf: [][]const u8,
        name_storage: []u8,
        _: std.mem.Allocator,
    ) []const []const u8 {
        _ = self;
        var list: discovery.FamilyList = .{ .names = names_buf, .storage = name_storage };

        const families = c.CTFontManagerCopyAvailableFontFamilyNames() orelse return list.slice();
        defer c.CFRelease(families);

        var buf: [256]u8 = undefined;
        const count: usize = @intCast(c.CFArrayGetCount(families));
        for (0..count) |i| {
            const name: c.CFStringRef = @ptrCast(@alignCast(c.CFArrayGetValueAtIndex(families, @intCast(i)) orelse continue));
            if (c.CFStringGetCString(name, &buf, buf.len, c.kCFStringEncodingUTF8) == 0) continue;
            list.append(std.mem.sliceTo(&buf, 0));
        }
        return list.slice();
    }

    /// Finds a font covering `codepoint` via CoreText's own system cascade
    /// list (`CTFontCreateForString`) -- the same mechanism TextKit uses for
    /// glyph fallback, so results match what every other Cocoa app already
    /// renders. No cmap scanning of the local font catalog: CoreText already
    /// knows which installed font covers what.
    ///
    /// Which family a cascade bottoms out at depends on the *base* font
    /// passed in, not just the codepoint's script: an empty/system-UI base
    /// resolves CJK to `PingFangUI.ttc`, a private system-UI face whose
    /// glyphs live only in Apple's proprietary `hvgl` table (no
    /// glyf/CFF/CFF2 -- unrasterizable by any standard OpenType parser).
    /// Seeding from each generic content-font family instead (same families
    /// `generic_family_names` already maps for direct lookups) tends to
    /// land on the real content font (e.g. `Songti.ttc` for CJK), so try
    /// each and verify actual outline coverage via `CTFontCopyAvailableTables`
    /// rather than trusting the first cascade hit.
    ///
    /// The system-UI cascade is still tried first for everything but Han
    /// and kana: it's what native apps render UI text with (SF Arabic,
    /// SF Hebrew, Thonburi UI, Apple SD Gothic Neo), where the content seeds
    /// land on Times New Roman's Arabic or AppleMyungjo's serif Hangul. For
    /// kana it picks a Chinese symbols font, and for Han the unusable
    /// PingFangUI.
    pub fn selectFallbackForCodepoint(
        self: *const CoreText,
        codepoint: u21,
        path_storage: []u8,
        allocator: std.mem.Allocator,
    ) discovery.SelectionError!discovery.Handle {
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return discovery.SelectionError.NotFound;
        const cfstr = c.CFStringCreateWithBytes(null, &utf8_buf, @intCast(utf8_len), c.kCFStringEncodingUTF8, 0) orelse
            return discovery.SelectionError.NotFound;
        defer c.CFRelease(cfstr);
        const range: c.CFRange = .{ .location = 0, .length = c.CFStringGetLength(cfstr) };

        const language_cfstr: c.CFStringRef = if (self.language) |tag| blk: {
            const language = discovery.fallbackLanguage(tag);
            break :blk c.CFStringCreateWithBytes(null, language.ptr, @intCast(language.len), c.kCFStringEncodingUTF8, 0);
        } else null;
        defer if (language_cfstr) |language| c.CFRelease(language);

        const script = unicode.scriptOf(codepoint);
        const han_or_kana = for ([_]*const [4]u8{ "Hani", "Hira", "Kana", "Bopo" }) |tag| {
            if (std.mem.eql(u8, &script, tag)) break true;
        } else false;

        const base_families = [_]?[]const u8{
            null,
            generic_family_names.serif,
            generic_family_names.sans_serif,
            generic_family_names.monospace,
        };
        for (base_families[@intFromBool(han_or_kana)..]) |maybe_family_name| {
            // Size is irrelevant here -- only the resulting cascade list matters.
            const base_font = if (maybe_family_name) |family_name| blk: {
                const family_cfstr = c.CFStringCreateWithBytes(null, family_name.ptr, @intCast(family_name.len), c.kCFStringEncodingUTF8, 0) orelse continue;
                defer c.CFRelease(family_cfstr);
                break :blk c.CTFontCreateWithName(family_cfstr, 12.0, null) orelse continue;
            } else c.CTFontCreateUIFontForLanguage(c.kCTFontUIFontSystem, 12.0, null) orelse continue;
            defer c.CFRelease(base_font);

            const matched_font = (if (language_cfstr != null)
                c.CTFontCreateForStringWithLanguage(base_font, cfstr, range, language_cfstr)
            else
                c.CTFontCreateForString(base_font, cfstr, range)) orelse continue;
            defer c.CFRelease(matched_font);

            const matched_descriptor = c.CTFontCopyFontDescriptor(matched_font) orelse continue;
            defer c.CFRelease(matched_descriptor);

            // When nothing installed covers the string, CoreText's cascade
            // bottoms out at Apple's "Last Resort" font (every codepoint maps
            // to a boxed placeholder glyph) -- that's a fake match, not real
            // coverage.
            if (familyNameIs(matched_descriptor, "LastResort")) continue;
            if (!hasOutlineTable(matched_font)) continue;

            const path = copyFilePath(matched_descriptor, path_storage) orelse continue;
            return .{ .path = .{ .path = path, .font_index = resolveFontIndex(matched_descriptor, path, allocator) } };
        }
        return discovery.SelectionError.NotFound;
    }
};

/// True if `font` has an outline table this codebase can rasterize.
/// Queried straight from CoreText (`CTFontCopyAvailableTables`) rather than
/// opening and parsing the file ourselves -- cheaper, and avoids duplicating
/// dvui's own `hasUsableOutlines` file-based check just to reject a
/// known-bad candidate one step earlier.
fn hasOutlineTable(font: c.CTFontRef) bool {
    const tables = c.CTFontCopyAvailableTables(font, 0) orelse return false;
    defer c.CFRelease(tables);
    const count: usize = @intCast(c.CFArrayGetCount(tables));
    for (0..count) |i| {
        const tag_ptr = c.CFArrayGetValueAtIndex(tables, @intCast(i)) orelse continue;
        const tag: u32 = @truncate(@intFromPtr(tag_ptr));
        switch (tag) {
            fourCharCode("glyf"), fourCharCode("CFF "), fourCharCode("CFF2") => return true,
            else => {},
        }
    }
    return false;
}

fn fourCharCode(comptime tag: *const [4]u8) u32 {
    return (@as(u32, tag[0]) << 24) | (@as(u32, tag[1]) << 16) | (@as(u32, tag[2]) << 8) | tag[3];
}

fn familyNameIs(desc: c.CTFontDescriptorRef, name: []const u8) bool {
    const family_ref = c.CTFontDescriptorCopyAttribute(desc, c.kCTFontFamilyNameAttribute) orelse return false;
    const family_cfstr: c.CFStringRef = @ptrCast(@alignCast(family_ref));
    defer c.CFRelease(family_cfstr);
    var buf: [256]u8 = undefined;
    if (c.CFStringGetCString(family_cfstr, &buf, buf.len, c.kCFStringEncodingUTF8) == 0) return false;
    return std.mem.eql(u8, std.mem.sliceTo(&buf, 0), name);
}

fn copyFilePath(desc: c.CTFontDescriptorRef, buf: []u8) ?[]const u8 {
    const url: c.CFURLRef = @ptrCast(@alignCast(c.CTFontDescriptorCopyAttribute(desc, c.kCTFontURLAttribute) orelse return null));
    defer c.CFRelease(url);
    if (c.CFURLGetFileSystemRepresentation(url, 1, buf.ptr, @intCast(buf.len)) == 0) return null;
    return std.mem.sliceTo(buf, 0);
}

fn readProperties(desc: c.CTFontDescriptorRef) discovery.Properties {
    const traits_ref = c.CTFontDescriptorCopyAttribute(desc, c.kCTFontTraitsAttribute);
    if (traits_ref == null) return .{};
    const traits: c.CFDictionaryRef = @ptrCast(@alignCast(traits_ref));
    defer c.CFRelease(traits);

    const symbolic = getUInt32(traits, c.kCTFontSymbolicTrait) orelse 0;
    const weight_trait = getDouble(traits, c.kCTFontWeightTrait) orelse 0.0;
    const width_trait = getDouble(traits, c.kCTFontWidthTrait) orelse 0.0;
    const slant_trait = getDouble(traits, c.kCTFontSlantTrait) orelse 0.0;

    const style: discovery.Style = if (symbolic & c.kCTFontTraitItalic != 0)
        .italic
    else if (slant_trait > 0.0)
        .oblique
    else
        .normal;

    var properties: discovery.Properties = .{
        .style = style,
        .weight = coreTextToCssWeight(@floatCast(weight_trait)),
        .stretch = coreTextWidthToCssStretch(@floatCast(width_trait)),
    };
    readAxisRanges(desc, &properties);
    return properties;
}

fn readAxisRanges(desc: c.CTFontDescriptorRef, properties: *discovery.Properties) void {
    const axes_ref = c.CTFontDescriptorCopyAttribute(desc, c.kCTFontVariationAxesAttribute) orelse return;
    const axes: c.CFArrayRef = @ptrCast(@alignCast(axes_ref));
    defer c.CFRelease(axes);
    const count: usize = @intCast(c.CFArrayGetCount(axes));
    for (0..count) |i| {
        const axis: c.CFDictionaryRef = @ptrCast(@alignCast(c.CFArrayGetValueAtIndex(axes, @intCast(i)) orelse continue));
        const tag = getUInt32(axis, c.kCTFontVariationAxisIdentifierKey) orelse continue;
        const min = getDouble(axis, c.kCTFontVariationAxisMinimumValueKey) orelse continue;
        const max = getDouble(axis, c.kCTFontVariationAxisMaximumValueKey) orelse continue;
        // Old GX fonts (Skia) scale wght/wdth around 1.0, not CSS units.
        if (min < 1.0 or max > 1000.0 or min >= max) continue;
        switch (tag) {
            fourCharCode("wght") => properties.weight_range = .{ .min = @floatCast(min), .max = @floatCast(max) },
            fourCharCode("wdth") => properties.stretch_range = .{ .min = @floatCast(min / 100.0), .max = @floatCast(max / 100.0) },
            else => {},
        }
    }
}

fn listsPath(handles: []const discovery.Handle, path: []const u8) bool {
    for (handles) |handle| {
        if (std.mem.eql(u8, handle.path.path, path)) return true;
    }
    return false;
}

fn getUInt32(dict: c.CFDictionaryRef, key: c.CFTypeRef) ?u32 {
    const value = c.CFDictionaryGetValue(dict, key) orelse return null;
    var out: i32 = 0;
    if (c.CFNumberGetValue(@ptrCast(@alignCast(value)), c.kCFNumberSInt32Type, &out) == 0) return null;
    return @bitCast(out);
}

fn getDouble(dict: c.CFDictionaryRef, key: c.CFTypeRef) ?f64 {
    const value = c.CFDictionaryGetValue(dict, key) orelse return null;
    var out: f64 = 0;
    if (c.CFNumberGetValue(@ptrCast(@alignCast(value)), c.kCFNumberDoubleType, &out) == 0) return null;
    return out;
}

fn coreTextToCssWeight(weight: f32) discovery.Weight {
    return .{ .value = piecewiseLinearFindIndex(weight, &font_weight_mapping) * 100.0 + 100.0 };
}

fn coreTextWidthToCssStretch(width: f32) discovery.Stretch {
    return .{ .value = piecewiseLinearLookup(std.math.clamp((width + 0.4) * 10.0, 0.0, 8.0), &stretch_mapping) };
}

fn piecewiseLinearLookup(index: f32, mapping: []const f32) f32 {
    const lower = mapping[@intFromFloat(@floor(index))];
    const upper = mapping[@intFromFloat(@ceil(index))];
    return std.math.lerp(lower, upper, @mod(index, 1.0));
}

fn piecewiseLinearFindIndex(query: f32, mapping: []const f32) f32 {
    for (mapping, 0..) |v, i| {
        if (v == query) return @floatFromInt(i);
        if (v > query) {
            if (i == 0) return 0.0;
            const lower = mapping[i - 1];
            const t = (query - lower) / (v - lower);
            return @as(f32, @floatFromInt(i - 1)) + t;
        }
    }
    return @floatFromInt(mapping.len - 1);
}

/// Resolves which face of `path` a descriptor names. CoreText's matching
/// API has no face-index attribute, so for a `.ttc` this opens the file and
/// matches the descriptor's PostScript name (`kCTFontNameAttribute`)
/// against each face's `name` table (nameID 6) — same approach as
/// font-kit's `create_handles_from_core_text_collection`. Non-collection
/// fonts are always face 0, no file access needed.
fn resolveFontIndex(desc: c.CTFontDescriptorRef, path: []const u8, allocator: std.mem.Allocator) u32 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var magic: [4]u8 = undefined;
    {
        var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return 0;
        defer file.close(io);
        const n = file.readPositionalAll(io, &magic, 0) catch return 0;
        if (n < 4 or !std.mem.eql(u8, &magic, "ttcf")) return 0;
    }

    const postscript_ref = c.CTFontDescriptorCopyAttribute(desc, c.kCTFontNameAttribute) orelse return 0;
    const postscript_cfstr: c.CFStringRef = @ptrCast(@alignCast(postscript_ref));
    defer c.CFRelease(postscript_cfstr);
    var postscript_buf: [256]u8 = undefined;
    if (c.CFStringGetCString(postscript_cfstr, &postscript_buf, postscript_buf.len, c.kCFStringEncodingUTF8) == 0) return 0;
    const postscript_name = std.mem.sliceTo(&postscript_buf, 0);

    // Matches Font.zig's system_font_size_limit -- Apple Color Emoji.ttc is
    // ~180MB; a lower cap here silently falls back to face index 0 (wrong
    // face, e.g. a Latin/Roman face instead of the matched script's face)
    // while the actual font bytes load fine downstream with the correct cap.
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024)) catch return 0;
    defer allocator.free(data);

    const collection = parsing.Collection.parse(allocator, data) catch return 0;
    defer collection.deinit(allocator);
    var name_buf: [256]u8 = undefined;
    for (collection.fonts, 0..) |font, index| {
        const name_data = font.tableData(.{ 'n', 'a', 'm', 'e' }) orelse continue;
        const candidate = parsing.Table.name.postscriptName(name_data, &name_buf) orelse continue;
        if (std.mem.eql(u8, candidate, postscript_name)) return @intCast(index);
    }
    return 0;
}
