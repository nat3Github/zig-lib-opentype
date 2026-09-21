// Derived from font-kit (MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const discovery = @import("../discovery.zig");
const unicode = @import("../unicode.zig");

// NOTE: ported from vendor/font-kit (src/sources/fontconfig.rs) — see
// CLAUDE.md vendor list.
//
// Loads libfontconfig via dlopen (std.DynLib) instead of linking against it
// at build time. font-kit itself supports both modes (its
// "source-fontconfig-dlopen" feature); this backend used to take the
// link-time path on the theory that it's only compiled for targets that
// always ship fontconfig (Linux desktop). That assumption breaks under
// cross-compilation: linking needs a target-arch libfontconfig.so in a
// sysroot, which a build host rarely has lying around. dlopen defers that
// requirement to runtime on the actual target machine, so cross-compiling
// (and building on a dev machine without fontconfig installed at all) both
// just work; `init()` fails with `SelectionError.NotFound` if the library
// isn't present at runtime, same as any other "not found" case.
//
// Also diverges from font-kit's `select_descriptions_in_family`, which
// opens and re-parses every font file in a family to read its
// style/weight/stretch. Fontconfig already carries that data (`slant`/
// `weight`/`width`) in the same pattern that lists family members, so this
// backend fetches it in the one `FcFontList` call instead of a second pass
// through the font loader.

// Opaque fontconfig handle types (public C ABI, fontconfig/fontconfig.h).
const FcConfig = opaque {};
const FcPattern = opaque {};
const FcObjectSet = opaque {};
const FcCharSet = opaque {};
const FcRange = opaque {};
const FcChar8 = u8;
const FcChar32 = u32;
const FcBool = c_int;

// `_FcFontSet`'s field layout is part of fontconfig's stable public ABI
// (accessed directly by every C caller that lists fonts), so hardcoding it
// here is as safe as hardcoding the FC_* string/int constants below.
const FcFontSet = extern struct {
    nfont: c_int,
    sfont: c_int,
    fonts: [*]?*FcPattern,
};

const FcResult = c_int;
const FcResultMatch: FcResult = 0;

const FcMatchKind = c_int;
const FcMatchPattern: FcMatchKind = 0;

const FC_FILE = "file";
const FC_INDEX = "index";

// FC_INDEX packs a variable font's named instance into the high 16 bits.
fn faceIndex(fc_index: c_int) u32 {
    return @as(u32, @bitCast(fc_index)) & 0xFFFF;
}
const FC_SLANT = "slant";
const FC_WEIGHT = "weight";
const FC_WIDTH = "width";
const FC_FAMILY = "family";
const FC_CHARSET = "charset";
const FC_LANG = "lang";

const FC_SLANT_ROMAN: c_int = 0;
const FC_SLANT_ITALIC: c_int = 100;
const FC_SLANT_OBLIQUE: c_int = 110;
const FC_WEIGHT_REGULAR: c_int = 80;
const FC_WIDTH_NORMAL: c_int = 100;

/// Function table dlopen'd out of libfontconfig. Field names must match the
/// C symbol names exactly — `load()` looks each one up by its Zig field name.
const Lib = struct {
    handle: std.DynLib,
    FcInitLoadConfigAndFonts: *const fn () callconv(.c) ?*FcConfig,
    FcConfigDestroy: *const fn (*FcConfig) callconv(.c) void,
    FcNameParse: *const fn ([*:0]const u8) callconv(.c) ?*FcPattern,
    FcPatternDestroy: *const fn (*FcPattern) callconv(.c) void,
    FcObjectSetCreate: *const fn () callconv(.c) ?*FcObjectSet,
    FcObjectSetAdd: *const fn (*FcObjectSet, [*:0]const u8) callconv(.c) c_int,
    FcObjectSetDestroy: *const fn (*FcObjectSet) callconv(.c) void,
    FcFontList: *const fn (?*FcConfig, *FcPattern, *FcObjectSet) callconv(.c) ?*FcFontSet,
    FcFontSetDestroy: *const fn (*FcFontSet) callconv(.c) void,
    FcPatternGetString: *const fn (*FcPattern, [*:0]const u8, c_int, *[*c]FcChar8) callconv(.c) FcResult,
    FcPatternGetInteger: *const fn (*FcPattern, [*:0]const u8, c_int, *c_int) callconv(.c) FcResult,
    FcPatternGetRange: *const fn (*FcPattern, [*:0]const u8, c_int, *?*FcRange) callconv(.c) FcResult,
    FcRangeGetDouble: *const fn (*const FcRange, *f64, *f64) callconv(.c) FcBool,
    FcConfigSubstitute: *const fn (?*FcConfig, *FcPattern, FcMatchKind) callconv(.c) c_int,
    FcDefaultSubstitute: *const fn (*FcPattern) callconv(.c) void,
    FcFontSort: *const fn (?*FcConfig, *FcPattern, c_int, ?*anyopaque, *FcResult) callconv(.c) ?*FcFontSet,
    FcWeightToOpenTypeDouble: *const fn (f64) callconv(.c) f64,
    FcPatternCreate: *const fn () callconv(.c) ?*FcPattern,
    FcCharSetCreate: *const fn () callconv(.c) ?*FcCharSet,
    FcCharSetDestroy: *const fn (*FcCharSet) callconv(.c) void,
    FcCharSetAddChar: *const fn (*FcCharSet, FcChar32) callconv(.c) FcBool,
    FcPatternAddCharSet: *const fn (*FcPattern, [*:0]const u8, *const FcCharSet) callconv(.c) FcBool,
    FcPatternAddString: *const fn (*FcPattern, [*:0]const u8, [*:0]const FcChar8) callconv(.c) FcBool,
    FcFontMatch: *const fn (?*FcConfig, *FcPattern, *FcResult) callconv(.c) ?*FcPattern,

    // Sonames to try in order: ".so.1" is what every distro package ships;
    // ".so" (dev-package symlink) is a fallback for non-standard setups.
    const sonames = [_][]const u8{ "libfontconfig.so.1", "libfontconfig.so" };

    fn load() !Lib {
        var maybe_handle: ?std.DynLib = null;
        for (sonames) |soname| {
            maybe_handle = std.DynLib.open(soname) catch continue;
            break;
        }
        var self: Lib = undefined;
        self.handle = maybe_handle orelse return error.LibraryNotFound;
        errdefer self.handle.close();

        inline for (@typeInfo(Lib).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "handle")) continue;
            @field(self, field.name) = self.handle.lookup(field.type, field.name) orelse
                return error.SymbolNotFound;
        }
        return self;
    }
};

pub const Fontconfig = struct {
    lib: Lib,
    config: *FcConfig,
    /// BCP 47 tag steering `selectFallbackForCodepoint` (e.g. Japanese vs.
    /// Chinese Han glyphs); `null` leaves it to the process locale, which
    /// `FcDefaultSubstitute` fills in.
    language: ?[]const u8 = null,

    pub fn init() discovery.SelectionError!Fontconfig {
        var lib = Lib.load() catch return discovery.SelectionError.NotFound;
        const config = lib.FcInitLoadConfigAndFonts() orelse {
            lib.handle.close();
            return discovery.SelectionError.NotFound;
        };
        return .{ .lib = lib, .config = config };
    }

    pub fn deinit(self: *Fontconfig) void {
        self.lib.FcConfigDestroy(self.config);
        self.lib.handle.close();
        self.* = undefined;
    }

    /// Looks up a font family by name (or a CSS generic name, resolved via
    /// fontconfig's alias substitution) and writes its member fonts and
    /// their properties into caller-owned `handle_buf`/`properties_buf`
    /// (same length, sized to the number of fonts expected in the family).
    ///
    /// The underlying fontconfig pattern strings don't outlive this call,
    /// so each returned `Handle.path.path` is a slice bump-allocated out of
    /// caller-owned `path_storage` instead of the heap — same no-alloc
    /// pattern as `findBestMatch`'s `index_buf`, and it sidesteps having to
    /// track which of a family's *N* paths (only one of which becomes the
    /// match) need freeing later.
    pub fn selectFamilyByName(
        self: *const Fontconfig,
        family_name: []const u8,
        handle_buf: []discovery.Handle,
        properties_buf: []discovery.Properties,
        path_storage: []u8,
        _: std.mem.Allocator,
    ) discovery.SelectionError!discovery.FamilyHandle {
        std.debug.assert(handle_buf.len == properties_buf.len);

        var resolved_name_buf: [256]u8 = undefined;
        const resolved_name = if (discovery.FamilyName.isGeneric(family_name))
            try self.selectGenericFontFamily(family_name, &resolved_name_buf)
        else
            family_name;

        var name_z_buf: [256]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_z_buf, "{s}", .{resolved_name}) catch return discovery.SelectionError.NotFound;

        const pattern = self.lib.FcNameParse(name_z.ptr) orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcPatternDestroy(pattern);

        const object_set = self.lib.FcObjectSetCreate() orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcObjectSetDestroy(object_set);
        for ([_][*:0]const u8{ FC_FILE, FC_INDEX, FC_SLANT, FC_WEIGHT, FC_WIDTH }) |object| {
            _ = self.lib.FcObjectSetAdd(object_set, object);
        }

        const font_set = self.lib.FcFontList(self.config, pattern, object_set) orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcFontSetDestroy(font_set);

        if (font_set.nfont == 0) return discovery.SelectionError.NotFound;
        const patterns = font_set.fonts[0..@intCast(font_set.nfont)];
        var count: usize = 0;
        var path_offset: usize = 0;
        for (patterns) |maybe_patt| {
            if (count >= handle_buf.len) break;
            const patt = maybe_patt orelse continue;

            const index = self.getInteger(patt, FC_INDEX) orelse 0;
            // A variable face is listed once whole (weight/width as ranges)
            // plus once per named instance; the whole face covers them all.
            if (@as(u32, @bitCast(index)) >> 16 != 0) continue;

            const path = self.getString(patt, FC_FILE) orelse continue;
            if (path_offset + path.len > path_storage.len) break;
            const owned_path = path_storage[path_offset..][0..path.len];
            @memcpy(owned_path, path);
            path_offset += path.len;

            const slant = self.getInteger(patt, FC_SLANT) orelse FC_SLANT_ROMAN;
            const weight_range = self.getRange(patt, FC_WEIGHT);
            const width_range = self.getRange(patt, FC_WIDTH);
            const weight: f64 = if (weight_range) |r| r[0] else @floatFromInt(self.getInteger(patt, FC_WEIGHT) orelse FC_WEIGHT_REGULAR);
            const width: f64 = if (width_range) |r| r[0] else @floatFromInt(self.getInteger(patt, FC_WIDTH) orelse FC_WIDTH_NORMAL);

            handle_buf[count] = .{ .path = .{ .path = owned_path, .font_index = faceIndex(index) } };
            properties_buf[count] = .{
                .style = slantToStyle(slant),
                .weight = .{ .value = self.openTypeWeight(weight) },
                .stretch = .{ .value = @floatCast(width / 100.0) },
                .weight_range = if (weight_range) |r| .{ .min = self.openTypeWeight(r[0]), .max = self.openTypeWeight(r[1]) } else null,
                .stretch_range = if (width_range) |r| .{ .min = @floatCast(r[0] / 100.0), .max = @floatCast(r[1] / 100.0) } else null,
            };
            count += 1;
        }

        if (count == 0) return discovery.SelectionError.NotFound;
        return .{ .fonts = handle_buf[0..count], .properties = properties_buf[0..count] };
    }

    /// Lists every font family fontconfig knows about (`FcFontList` with no
    /// pattern constraints, one `FC_FAMILY` per matched font — hence the
    /// dedupe in `discovery.FamilyList`, since a family shows up once per
    /// installed face).
    pub fn availableFamilies(
        self: *const Fontconfig,
        names_buf: [][]const u8,
        name_storage: []u8,
        _: std.mem.Allocator,
    ) []const []const u8 {
        var list: discovery.FamilyList = .{ .names = names_buf, .storage = name_storage };

        const pattern = self.lib.FcPatternCreate() orelse return list.slice();
        defer self.lib.FcPatternDestroy(pattern);

        const object_set = self.lib.FcObjectSetCreate() orelse return list.slice();
        defer self.lib.FcObjectSetDestroy(object_set);
        _ = self.lib.FcObjectSetAdd(object_set, FC_FAMILY);

        const font_set = self.lib.FcFontList(self.config, pattern, object_set) orelse return list.slice();
        defer self.lib.FcFontSetDestroy(font_set);

        for (font_set.fonts[0..@intCast(font_set.nfont)]) |maybe_patt| {
            const patt = maybe_patt orelse continue;
            list.append(self.getString(patt, FC_FAMILY) orelse continue);
        }
        return list.slice();
    }

    /// Finds a font covering `codepoint` the way every fontconfig-based text
    /// stack (Pango, HarfBuzz's own hb-ft/uharfbuzz users) does it: put the
    /// codepoint in an `FcCharSet`, run it through the config's normal
    /// substitution + match pipeline (`FcConfigSubstitute` pulls in the
    /// user's configured fallback chain), and take whatever `FcFontMatch`
    /// picks -- fontconfig already ranks installed fonts by charset coverage.
    pub fn selectFallbackForCodepoint(
        self: *const Fontconfig,
        codepoint: u21,
        path_storage: []u8,
    ) discovery.SelectionError!discovery.Handle {
        const charset = self.lib.FcCharSetCreate() orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcCharSetDestroy(charset);
        if (self.lib.FcCharSetAddChar(charset, @intCast(codepoint)) == 0) return discovery.SelectionError.NotFound;

        const pattern = self.lib.FcPatternCreate() orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcPatternDestroy(pattern);
        if (self.lib.FcPatternAddCharSet(pattern, FC_CHARSET, charset) == 0) return discovery.SelectionError.NotFound;
        for (preferredFallbackFamilies(unicode.scriptOf(codepoint))) |family| {
            _ = self.lib.FcPatternAddString(pattern, FC_FAMILY, family);
        }
        if (self.language) |tag| {
            var language_buf: [16]u8 = undefined;
            if (std.fmt.bufPrintZ(&language_buf, "{s}", .{fontconfigLanguage(tag)})) |language| {
                _ = self.lib.FcPatternAddString(pattern, FC_LANG, language.ptr);
            } else |_| {}
        }

        _ = self.lib.FcConfigSubstitute(self.config, pattern, FcMatchPattern);
        self.lib.FcDefaultSubstitute(pattern);

        var result: FcResult = undefined;
        const matched = self.lib.FcFontMatch(self.config, pattern, &result) orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcPatternDestroy(matched);
        if (result != FcResultMatch) return discovery.SelectionError.NotFound;

        const path = self.getString(matched, FC_FILE) orelse return discovery.SelectionError.NotFound;
        if (path.len > path_storage.len) return discovery.SelectionError.NotFound;
        const owned_path = path_storage[0..path.len];
        @memcpy(owned_path, path);

        const index = self.getInteger(matched, FC_INDEX) orelse 0;
        return .{ .path = .{ .path = owned_path, .font_index = faceIndex(index) } };
    }

    fn selectGenericFontFamily(self: *const Fontconfig, name: []const u8, name_buf: []u8) discovery.SelectionError![]const u8 {
        var buf: [256]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return discovery.SelectionError.NotFound;

        const pattern = self.lib.FcNameParse(name_z.ptr) orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcPatternDestroy(pattern);

        _ = self.lib.FcConfigSubstitute(self.config, pattern, FcMatchPattern);
        self.lib.FcDefaultSubstitute(pattern);

        var result: FcResult = undefined;
        const font_set = self.lib.FcFontSort(self.config, pattern, 1, null, &result) orelse return discovery.SelectionError.NotFound;
        defer self.lib.FcFontSetDestroy(font_set);

        if (font_set.nfont == 0) return discovery.SelectionError.NotFound;
        const first = font_set.fonts[0] orelse return discovery.SelectionError.NotFound;
        const family = self.getString(first, FC_FAMILY) orelse return discovery.SelectionError.NotFound;
        return std.fmt.bufPrint(name_buf, "{s}", .{family}) catch discovery.SelectionError.NotFound;
    }

    fn getString(self: *const Fontconfig, pattern: *FcPattern, object: [*:0]const u8) ?[]const u8 {
        var value: [*c]FcChar8 = null;
        if (self.lib.FcPatternGetString(pattern, object, 0, &value) != FcResultMatch or value == null) return null;
        return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    }

    fn getInteger(self: *const Fontconfig, pattern: *FcPattern, object: [*:0]const u8) ?c_int {
        var value: c_int = undefined;
        if (self.lib.FcPatternGetInteger(pattern, object, 0, &value) != FcResultMatch) return null;
        return value;
    }

    fn getRange(self: *const Fontconfig, pattern: *FcPattern, object: [*:0]const u8) ?[2]f64 {
        var range: ?*FcRange = null;
        if (self.lib.FcPatternGetRange(pattern, object, 0, &range) != FcResultMatch) return null;
        var begin: f64 = 0;
        var end: f64 = 0;
        if (self.lib.FcRangeGetDouble(range orelse return null, &begin, &end) == 0) return null;
        return .{ begin, end };
    }

    fn openTypeWeight(self: *const Fontconfig, fc_weight: f64) f32 {
        return @floatCast(self.lib.FcWeightToOpenTypeDouble(fc_weight));
    }
};

fn slantToStyle(slant: c_int) discovery.Style {
    if (slant >= FC_SLANT_OBLIQUE) return .oblique;
    if (slant >= FC_SLANT_ITALIC) return .italic;
    return .normal;
}

/// Noto families to try first per script, so Fedora/Ubuntu fall back to the
/// same faces Android's fonts.xml uses instead of whatever the distro config
/// ranks first. `FcFontMatch` ranks charset above family, so a listed family
/// only wins when it covers the codepoint. Arabic prefers Naskh, matching
/// Android, Windows (Segoe UI) and macOS (Geeza Pro). CJK is left out: which
/// Han glyph shapes to use is language-dependent, and the distro configs
/// already pick the right Noto CJK face from `FC_LANG`.
const preferred_fallback_families = [_]struct { script: *const [4]u8, families: []const [*:0]const u8 }{
    .{ .script = "Arab", .families = &.{ "Noto Naskh Arabic UI", "Noto Naskh Arabic", "Noto Sans Arabic UI", "Noto Sans Arabic" } },
    .{ .script = "Armn", .families = &.{"Noto Sans Armenian"} },
    .{ .script = "Beng", .families = &.{"Noto Sans Bengali"} },
    .{ .script = "Deva", .families = &.{"Noto Sans Devanagari"} },
    .{ .script = "Ethi", .families = &.{"Noto Sans Ethiopic"} },
    .{ .script = "Geor", .families = &.{"Noto Sans Georgian"} },
    .{ .script = "Gujr", .families = &.{"Noto Sans Gujarati"} },
    .{ .script = "Guru", .families = &.{"Noto Sans Gurmukhi"} },
    .{ .script = "Hebr", .families = &.{"Noto Sans Hebrew"} },
    .{ .script = "Khmr", .families = &.{"Noto Sans Khmer"} },
    .{ .script = "Knda", .families = &.{"Noto Sans Kannada"} },
    .{ .script = "Laoo", .families = &.{"Noto Sans Lao"} },
    .{ .script = "Mlym", .families = &.{"Noto Sans Malayalam"} },
    .{ .script = "Mymr", .families = &.{"Noto Sans Myanmar"} },
    .{ .script = "Orya", .families = &.{"Noto Sans Oriya"} },
    .{ .script = "Sinh", .families = &.{"Noto Sans Sinhala"} },
    .{ .script = "Taml", .families = &.{"Noto Sans Tamil"} },
    .{ .script = "Telu", .families = &.{"Noto Sans Telugu"} },
    .{ .script = "Thaa", .families = &.{"Noto Sans Thaana"} },
    .{ .script = "Thai", .families = &.{"Noto Sans Thai"} },
    .{ .script = "Tibt", .families = &.{"Noto Serif Tibetan"} },
};

pub fn preferredFallbackFamilies(script: [4]u8) []const [*:0]const u8 {
    for (preferred_fallback_families) |entry| {
        if (std.mem.eql(u8, entry.script, &script)) return entry.families;
    }
    return &.{};
}

// fontconfig's orthography table keys Chinese by region, not script.
pub fn fontconfigLanguage(tag: []const u8) []const u8 {
    const language = discovery.fallbackLanguage(tag);
    if (std.mem.eql(u8, language, "zh-Hans")) return "zh-cn";
    if (std.mem.eql(u8, language, "zh-Hant")) return "zh-tw";
    return language;
}

test "Fontconfig: preferred fallback families follow the codepoint's script" {
    try std.testing.expectEqualStrings("Noto Naskh Arabic UI", std.mem.span(preferredFallbackFamilies(unicode.scriptOf(0x0645))[0]));
    try std.testing.expectEqualStrings("Noto Sans Hebrew", std.mem.span(preferredFallbackFamilies(unicode.scriptOf(0x05D0))[0]));
    try std.testing.expectEqual(@as(usize, 0), preferredFallbackFamilies(unicode.scriptOf(0x4E2D)).len);
    try std.testing.expectEqual(@as(usize, 0), preferredFallbackFamilies(unicode.scriptOf('a')).len);
}

test "Fontconfig: language tags map Chinese scripts to fontconfig's region codes" {
    try std.testing.expectEqualStrings("zh-tw", fontconfigLanguage("zh-Hant"));
    try std.testing.expectEqualStrings("zh-cn", fontconfigLanguage("zh"));
    try std.testing.expectEqualStrings("ja", fontconfigLanguage("ja_JP.UTF-8"));
}
