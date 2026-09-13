const std = @import("std");
const discovery = @import("../discovery.zig");

// NOTE: ported from vendor/font-kit (src/sources/directwrite.rs,
// src/loaders/directwrite.rs) — see CLAUDE.md vendor list.
//
// UNVERIFIED: this backend (and its `directwrite_bindings.zig` COM
// bindings) compiles for `x86_64-windows` but has never been *run* — no
// Windows machine was available. GUIDs and vtable layouts in the bindings
// file were checked against a third-party transcription of dwrite.h rather
// than derived by guesswork, but a wrong GUID or misordered vtable slot
// only shows up at runtime, so treat this as a first draft to exercise on
// real Windows before trusting it.
//
// Diverges from font-kit in the same way the CoreText/Fontconfig backends
// do: weight/stretch/style come straight off `IDWriteFont` (`GetWeight`/
// `GetStretch`/`GetStyle`), the same object this backend already opens to
// list family members, instead of a second pass that reopens and reparses
// every font file's tables.
const c = @import("directwrite_bindings.zig");

pub const DirectWrite = struct {
    /// DirectWrite has no native CSS-generic-alias resolution (no family is
    /// literally named "sans-serif"), so override discovery.zig's default
    /// table with font-kit's Windows hardcoded picks (`source.rs`,
    /// `cfg(target_family = "windows")` block).
    pub const generic_family_names = struct {
        pub const serif = "Times New Roman";
        pub const sans_serif = "Arial";
        pub const monospace = "Courier New";
    };

    factory: *c.IDWriteFactory,
    collection: *c.IDWriteFontCollection,
    /// BCP 47 tag steering `selectFallbackForCodepoint` (e.g. Japanese vs.
    /// Chinese Han glyphs); `null` lets the codepoint alone decide.
    language: ?[]const u8 = null,

    pub fn init() discovery.SelectionError!DirectWrite {
        var factory: ?*c.IDWriteFactory = null;
        if (c.DWriteCreateFactory(c.DWRITE_FACTORY_TYPE_SHARED, &c.IID_IDWriteFactory, &factory) != c.S_OK or factory == null)
            return discovery.SelectionError.NotFound;
        errdefer _ = factory.?.vtable.Release(factory.?);

        var collection: ?*c.IDWriteFontCollection = null;
        if (factory.?.vtable.GetSystemFontCollection(factory.?, &collection, 0) != c.S_OK or collection == null)
            return discovery.SelectionError.NotFound;

        return .{ .factory = factory.?, .collection = collection.? };
    }

    pub fn deinit(self: *DirectWrite) void {
        _ = self.collection.vtable.Release(self.collection);
        _ = self.factory.vtable.Release(self.factory);
        self.* = undefined;
    }

    /// Looks up a font family by name and writes its member fonts and their
    /// properties into caller-owned `handle_buf`/`properties_buf` (same
    /// length). `path_storage` backs the returned `Handle.path.path` slices
    /// (UTF-8, converted from DirectWrite's native UTF-16 paths), same
    /// no-alloc pattern as the Fontconfig/CoreText backends.
    pub fn selectFamilyByName(
        self: *const DirectWrite,
        family_name: []const u8,
        handle_buf: []discovery.Handle,
        properties_buf: []discovery.Properties,
        path_storage: []u8,
        _: std.mem.Allocator,
    ) discovery.SelectionError!discovery.FamilyHandle {
        std.debug.assert(handle_buf.len == properties_buf.len);

        var name_utf16_buf: [256]u16 = undefined;
        const name_utf16_len = std.unicode.utf8ToUtf16Le(&name_utf16_buf, family_name) catch return discovery.SelectionError.NotFound;
        if (name_utf16_len >= name_utf16_buf.len) return discovery.SelectionError.NotFound;
        name_utf16_buf[name_utf16_len] = 0;

        var family_index: u32 = undefined;
        var exists: c.BOOL = 0;
        if (self.collection.vtable.FindFamilyName(self.collection, name_utf16_buf[0..name_utf16_len :0], &family_index, &exists) != c.S_OK or exists == 0)
            return discovery.SelectionError.NotFound;

        var family: ?*c.IDWriteFontFamily = null;
        if (self.collection.vtable.GetFontFamily(self.collection, family_index, &family) != c.S_OK or family == null)
            return discovery.SelectionError.NotFound;
        defer _ = family.?.vtable.Release(family.?);

        const font_count = family.?.vtable.GetFontCount(family.?);
        if (font_count == 0) return discovery.SelectionError.NotFound;

        var out_count: usize = 0;
        var path_offset: usize = 0;
        for (0..font_count) |i| {
            if (out_count >= handle_buf.len) break;
            if (readFont(family.?, @intCast(i), path_storage[path_offset..])) |result| {
                handle_buf[out_count] = .{ .path = .{ .path = result.path, .font_index = result.font_index } };
                properties_buf[out_count] = result.properties;
                path_offset += result.path.len;
                out_count += 1;
            }
        }

        if (out_count == 0) return discovery.SelectionError.NotFound;
        return .{ .fonts = handle_buf[0..out_count], .properties = properties_buf[0..out_count] };
    }

    /// Finds a font covering `codepoint` via DirectWrite's own system
    /// fallback (`IDWriteFontFallback::MapCharacters`) -- the same mechanism
    /// DirectWrite text layout uses, so results match what other Windows
    /// apps render, rather than this code scanning the collection's cmaps
    /// itself.
    ///
    /// `MapCharacters` reads its text through a caller-supplied
    /// `IDWriteTextAnalysisSource`; `c.TextAnalysisSource` is a stack
    /// instance of one over the single encoded codepoint.
    ///
    /// `IDWriteFactory2` (Windows 8.1+) is queried per call rather than in
    /// `init`, so an older system still gets a working `selectFamilyByName`
    /// and just no dynamic fallback.
    pub fn selectFallbackForCodepoint(
        self: *const DirectWrite,
        codepoint: u21,
        path_storage: []u8,
    ) discovery.SelectionError!discovery.Handle {
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return discovery.SelectionError.NotFound;
        var text: [2]c.WCHAR = undefined;
        const text_len = std.unicode.utf8ToUtf16Le(&text, utf8_buf[0..utf8_len]) catch return discovery.SelectionError.NotFound;

        var factory2_ptr: ?*anyopaque = null;
        if (self.factory.vtable.QueryInterface(self.factory, &c.IID_IDWriteFactory2, &factory2_ptr) != c.S_OK or factory2_ptr == null)
            return discovery.SelectionError.NotFound;
        const factory2: *c.IDWriteFactory2 = @ptrCast(@alignCast(factory2_ptr.?));
        defer _ = factory2.vtable.Release(factory2);

        var fallback: ?*c.IDWriteFontFallback = null;
        if (factory2.vtable.GetSystemFontFallback(factory2, &fallback) != c.S_OK or fallback == null)
            return discovery.SelectionError.NotFound;
        defer _ = fallback.?.vtable.Release(fallback.?);

        // Seeded from the sans-serif generic, same as the CoreText backend:
        // the base family steers which family the cascade lands on, not just
        // the codepoint's script.
        var base_name: [64]c.WCHAR = undefined;
        const base_len = std.unicode.utf8ToUtf16Le(&base_name, generic_family_names.sans_serif) catch return discovery.SelectionError.NotFound;
        base_name[base_len] = 0;

        var source = c.TextAnalysisSource.init(text[0..text_len]);
        var locale_buf: [32]c.WCHAR = undefined;
        if (self.language) |tag| {
            const language = discovery.fallbackLanguage(tag);
            if (language.len < locale_buf.len) {
                if (std.unicode.utf8ToUtf16Le(&locale_buf, language)) |locale_len| {
                    locale_buf[locale_len] = 0;
                    source.locale = locale_buf[0..locale_len :0].ptr;
                } else |_| {}
            }
        }
        var mapped_length: c.UINT32 = 0;
        var mapped_font: ?*c.IDWriteFont = null;
        var scale: c.FLOAT = 1.0;
        if (fallback.?.vtable.MapCharacters(
            fallback.?,
            source.asSource(),
            0,
            @intCast(text_len),
            self.collection,
            base_name[0..base_len :0],
            c.DWRITE_FONT_WEIGHT_NORMAL,
            c.DWRITE_FONT_STYLE_NORMAL,
            c.DWRITE_FONT_STRETCH_NORMAL,
            &mapped_length,
            &mapped_font,
            &scale,
        ) != c.S_OK) return discovery.SelectionError.NotFound;
        // A null mappedFont means nothing installed covers the codepoint --
        // DirectWrite reports that instead of returning a placeholder font.
        const font = mapped_font orelse return discovery.SelectionError.NotFound;
        defer _ = font.vtable.Release(font);

        var font_face: ?*c.IDWriteFontFace = null;
        if (font.vtable.CreateFontFace(font, &font_face) != c.S_OK or font_face == null)
            return discovery.SelectionError.NotFound;
        defer _ = font_face.?.vtable.Release(font_face.?);

        const path = copyFilePath(font_face.?, path_storage) orelse return discovery.SelectionError.NotFound;
        return .{ .path = .{ .path = path, .font_index = font_face.?.vtable.GetIndex(font_face.?) } };
    }

    /// Lists every family in the system font collection, names converted
    /// from DirectWrite's native UTF-16. See `discovery.FamilyList` for the
    /// buffer contract.
    pub fn availableFamilies(
        self: *const DirectWrite,
        names_buf: [][]const u8,
        name_storage: []u8,
        _: std.mem.Allocator,
    ) []const []const u8 {
        var list: discovery.FamilyList = .{ .names = names_buf, .storage = name_storage };

        const family_count = self.collection.vtable.GetFontFamilyCount(self.collection);
        for (0..family_count) |i| {
            var family: ?*c.IDWriteFontFamily = null;
            if (self.collection.vtable.GetFontFamily(self.collection, @intCast(i), &family) != c.S_OK or family == null) continue;
            defer _ = family.?.vtable.Release(family.?);

            var buf: [256]u8 = undefined;
            list.append(familyName(family.?, &buf) orelse continue);
        }
        return list.slice();
    }
};

/// First localized name of `family` — the locale list is ordered by the
/// font's own preference, and the collection is keyed by whichever name
/// `FindFamilyName` accepts, which index 0 always is.
fn familyName(family: *c.IDWriteFontFamily, buf: []u8) ?[]const u8 {
    var names: ?*c.IDWriteLocalizedStrings = null;
    if (family.vtable.GetFamilyNames(family, &names) != c.S_OK or names == null) return null;
    defer _ = names.?.vtable.Release(names.?);
    if (names.?.vtable.GetCount(names.?) == 0) return null;

    var len: c.UINT32 = 0;
    if (names.?.vtable.GetStringLength(names.?, 0, &len) != c.S_OK) return null;

    var utf16_buf: [256]u16 = undefined;
    if (len + 1 > utf16_buf.len) return null;
    if (names.?.vtable.GetString(names.?, 0, &utf16_buf, len + 1) != c.S_OK) return null;

    return utf16ToUtf8(buf, utf16_buf[0..len]);
}

const FontResult = struct {
    path: []const u8,
    font_index: u32,
    properties: discovery.Properties,
};

fn readFont(family: *c.IDWriteFontFamily, index: u32, path_buf: []u8) ?FontResult {
    var font: ?*c.IDWriteFont = null;
    if (family.vtable.GetFont(family, index, &font) != c.S_OK or font == null) return null;
    defer _ = font.?.vtable.Release(font.?);

    var font_face: ?*c.IDWriteFontFace = null;
    if (font.?.vtable.CreateFontFace(font.?, &font_face) != c.S_OK or font_face == null) return null;
    defer _ = font_face.?.vtable.Release(font_face.?);

    const path = copyFilePath(font_face.?, path_buf) orelse return null;

    return .{
        .path = path,
        .font_index = font_face.?.vtable.GetIndex(font_face.?),
        .properties = readProperties(font.?),
    };
}

fn readProperties(font: *c.IDWriteFont) discovery.Properties {
    const weight = font.vtable.GetWeight(font);
    const stretch = font.vtable.GetStretch(font);
    const style = font.vtable.GetStyle(font);

    return .{
        .style = switch (style) {
            c.DWRITE_FONT_STYLE_ITALIC => .italic,
            c.DWRITE_FONT_STYLE_OBLIQUE => .oblique,
            else => .normal,
        },
        .weight = .{ .value = @floatFromInt(weight) },
        // DWRITE_FONT_STRETCH is already a 1..9 CSS-stretch-keyword index,
        // unlike CoreText's continuous -1..1 axis — no interpolation
        // needed, just look up the matching discovery.Stretch enumerator.
        .stretch = stretchFromDWrite(stretch),
    };
}

const stretch_mapping = [9]discovery.Stretch{
    discovery.Stretch.ultra_condensed,
    discovery.Stretch.extra_condensed,
    discovery.Stretch.condensed,
    discovery.Stretch.semi_condensed,
    discovery.Stretch.normal,
    discovery.Stretch.semi_expanded,
    discovery.Stretch.expanded,
    discovery.Stretch.extra_expanded,
    discovery.Stretch.ultra_expanded,
};

fn stretchFromDWrite(stretch: c.DWRITE_FONT_STRETCH) discovery.Stretch {
    if (stretch < 1 or stretch > 9) return discovery.Stretch.normal;
    return stretch_mapping[stretch - 1];
}

/// Resolves the on-disk path (as UTF-8, into `buf`) and copies it there.
/// Mirrors font-kit's `create_handle_from_dwrite_font`: get the face's
/// first `IDWriteFontFile`, its opaque reference key, then hand that key to
/// the file's *local* loader (`IDWriteLocalFontFileLoader`, reached via
/// `QueryInterface`) to resolve an actual filesystem path. Non-local fonts
/// (e.g. served by a custom collection loader) have no such path and are
/// skipped, same as font-kit's `.unwrap()` on `get_font_file_path`.
fn copyFilePath(font_face: *c.IDWriteFontFace, buf: []u8) ?[]const u8 {
    var file_count: u32 = 0;
    if (font_face.vtable.GetFiles(font_face, &file_count, null) != c.S_OK or file_count == 0) return null;

    var files: [4]?*c.IDWriteFontFile = .{null} ** 4;
    if (file_count > files.len) file_count = files.len;
    if (font_face.vtable.GetFiles(font_face, &file_count, &files) != c.S_OK) return null;
    defer for (files[0..file_count]) |f| {
        if (f) |file| _ = file.vtable.Release(file);
    };

    const file = files[0] orelse return null;

    var key: ?*const anyopaque = null;
    var key_size: u32 = 0;
    if (file.vtable.GetReferenceKey(file, &key, &key_size) != c.S_OK) return null;

    var loader: ?*c.IDWriteFontFileLoader = null;
    if (file.vtable.GetLoader(file, &loader) != c.S_OK or loader == null) return null;
    defer _ = loader.?.vtable.Release(loader.?);

    var local_loader: ?*anyopaque = null;
    if (loader.?.vtable.QueryInterface(loader.?, &c.IID_IDWriteLocalFontFileLoader, &local_loader) != c.S_OK or local_loader == null)
        return null;
    const local: *c.IDWriteLocalFontFileLoader = @ptrCast(@alignCast(local_loader.?));
    defer _ = local.vtable.Release(local);

    var path_len: u32 = 0;
    if (local.vtable.GetFilePathLengthFromKey(local, key, key_size, &path_len) != c.S_OK) return null;

    var path_utf16_buf: [4096]u16 = undefined;
    if (path_len + 1 > path_utf16_buf.len) return null;
    if (local.vtable.GetFilePathFromKey(local, key, key_size, &path_utf16_buf, path_len + 1) != c.S_OK) return null;

    return utf16ToUtf8(buf, path_utf16_buf[0..path_len]);
}

/// `std.unicode.utf16LeToUtf8` asserts `buf` is large enough rather than
/// erroring, so bound-check first: UTF-8 never needs more than 3 bytes per
/// UTF-16 code unit (a surrogate pair is 2 units for 4 bytes).
fn utf16ToUtf8(buf: []u8, utf16: []const u16) ?[]const u8 {
    if (utf16.len * 3 > buf.len) return null;
    const written = std.unicode.utf16LeToUtf8(buf, utf16) catch return null;
    return buf[0..written];
}
