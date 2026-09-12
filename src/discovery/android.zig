const std = @import("std");
const discovery = @import("../discovery.zig");
const parsing = @import("../parsing.zig");
const unicode = @import("../unicode.zig");

// NOTE: no vendor reference — font-kit has no Android source (see
// [[project_font_discovery_branch]]: font-kit only ships CoreText/
// DirectWrite/Fontconfig sources, same gap this branch otherwise mirrors).
// Parses Android's `fonts.xml` directly instead: format documented at
// https://android.googlesource.com/platform/frameworks/base/+/master/data/fonts/fonts.xml
// `<family name="sans-serif"><font weight="400" style="normal">Roboto-Regular.ttf</font>...</family>`
// plus `<alias name="arial" to="sans-serif" [weight="400"]/>` entries.
//
// NOTE: only the modern (API 21+) `fonts.xml` schema is parsed, read
// fresh from disk on every call (no persistent cache — same per-call-query
// shape as the CoreText/Fontconfig backends, just via a hand-rolled scan
// instead of a system API). API <21's separate system_fonts.xml/
// fallback_fonts.xml format isn't handled; add if a target that old matters.
const fonts_xml_path = "/system/etc/fonts.xml";
const fonts_dir = "/system/fonts/";
// Android system fonts top out around 30MB (NotoSansCJK); the cap only
// exists so a corrupt/huge file can't be read into memory unbounded.
const font_size_limit = 64 * 1024 * 1024;

pub const Android = struct {
    /// Android's fonts.xml already defines "sans-serif"/"serif"/"monospace"
    /// as real family names, so those resolve natively like fontconfig's
    /// CSS aliases.
    pub const generic_family_names = struct {
        pub const serif = "serif";
        pub const sans_serif = "sans-serif";
        pub const monospace = "monospace";
    };

    /// BCP 47 tag picking among fonts.xml's per-language Han families
    /// (`zh-Hans`/`zh-Hant`/`ja`/`ko`) in `selectFallbackForCodepoint`;
    /// `null` takes the first covering family in document order.
    language: ?[]const u8 = null,

    pub fn init() discovery.SelectionError!Android {
        return .{};
    }

    pub fn deinit(self: *Android) void {
        self.* = undefined;
    }

    /// Lists the families fonts.xml defines. Reads the file per call, same
    /// as `selectFamilyByName`; see `availableFamiliesFromXml`.
    pub fn availableFamilies(
        self: *const Android,
        names_buf: [][]const u8,
        name_storage: []u8,
        allocator: std.mem.Allocator,
    ) []const []const u8 {
        _ = self;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data = std.Io.Dir.cwd().readFileAlloc(io, fonts_xml_path, allocator, .limited(4 * 1024 * 1024)) catch
            return names_buf[0..0];
        defer allocator.free(data);

        return availableFamiliesFromXml(data, names_buf, name_storage);
    }

    /// Looks up a font family by name (or an alias name from fonts.xml's
    /// `<alias>` table) and writes its member fonts and their properties
    /// into caller-owned `handle_buf`/`properties_buf` (same length).
    /// `path_storage` backs the returned `Handle.path.path` slices, same
    /// no-alloc pattern as the Fontconfig/CoreText backends.
    pub fn selectFamilyByName(
        self: *const Android,
        family_name: []const u8,
        handle_buf: []discovery.Handle,
        properties_buf: []discovery.Properties,
        path_storage: []u8,
        allocator: std.mem.Allocator,
    ) discovery.SelectionError!discovery.FamilyHandle {
        _ = self;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data = std.Io.Dir.cwd().readFileAlloc(io, fonts_xml_path, allocator, .limited(4 * 1024 * 1024)) catch
            return discovery.SelectionError.NotFound;
        defer allocator.free(data);

        return selectFamilyFromXml(data, family_name, handle_buf, properties_buf, path_storage);
    }

    /// Finds a font covering `codepoint`. Android has no query API for this
    /// (no CoreText cascade list, no fontconfig charset match): fonts.xml's
    /// own document order *is* the fallback order — the named families
    /// (sans-serif, serif, ...) first, then the unnamed per-script
    /// `<family lang="und-Arab">` fallback entries — so this walks it in
    /// order and takes the first font whose `cmap` maps the codepoint,
    /// which is what minikin's fallback chain resolves to.
    ///
    /// Coverage costs a full file read + parse per candidate, since the
    /// only coverage data is in the fonts themselves. Callers are expected
    /// to memoize per codepoint (dvui's `discoverDynamicFallback` does); if
    /// that ever isn't enough, read just the table directory + `cmap` range
    /// instead of the whole file.
    pub fn selectFallbackForCodepoint(
        self: *const Android,
        codepoint: u21,
        path_storage: []u8,
        allocator: std.mem.Allocator,
    ) discovery.SelectionError!discovery.Handle {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data = std.Io.Dir.cwd().readFileAlloc(io, fonts_xml_path, allocator, .limited(4 * 1024 * 1024)) catch
            return discovery.SelectionError.NotFound;
        defer allocator.free(data);

        return fallbackFromXml(data, codepoint, self.language, path_storage, FileCoverage{ .io = io, .allocator = allocator });
    }
};

/// Real coverage probe for `fallbackFromXml`: opens the candidate and looks
/// the codepoint up in its `cmap`. Split behind a `covers` method so the
/// XML-walk ordering is testable without a device's /system/fonts.
const FileCoverage = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    fn covers(self: FileCoverage, path: []const u8, font_index: u32, codepoint: u21) bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(font_size_limit)) catch return false;
        defer self.allocator.free(bytes);

        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "ttcf")) {
            const collection = parsing.Collection.parse(self.allocator, bytes) catch return false;
            defer collection.deinit(self.allocator);
            if (font_index >= collection.fonts.len) return false;
            return fontCovers(collection.fonts[font_index], codepoint);
        }

        const font = parsing.Font.parse(self.allocator, bytes) catch return false;
        defer font.deinit(self.allocator);
        return fontCovers(font, codepoint);
    }

    fn fontCovers(font: parsing.Font, codepoint: u21) bool {
        const cmap = font.tableData(.{ 'c', 'm', 'a', 'p' }) orelse return false;
        const glyph = parsing.Table.cmap.lookup(cmap, codepoint) orelse return false;
        return glyph != 0;
    }
};

/// Core fallback walk, split out from `selectFallbackForCodepoint` the same
/// way `selectFamilyFromXml` is: `coverage` is anything with a
/// `covers(path, font_index, codepoint) bool` method.
///
/// Han codepoints first try only the families tagged with `language`
/// (fonts.xml lists zh-Hans before ja/ko, so document order alone would give
/// Japanese text Chinese glyph shapes). Other scripts ignore `language`:
/// fonts.xml's per-script families are tagged `und-*`, not by language.
fn fallbackFromXml(
    data: []const u8,
    codepoint: u21,
    language: ?[]const u8,
    path_storage: []u8,
    coverage: anytype,
) discovery.SelectionError!discovery.Handle {
    if (language) |tag| {
        if (isHanUnified(codepoint)) {
            if (walkFallbackFamilies(data, codepoint, discovery.fallbackLanguage(tag), path_storage, coverage)) |handle| return handle;
        }
    }
    return walkFallbackFamilies(data, codepoint, null, path_storage, coverage) orelse discovery.SelectionError.NotFound;
}

fn isHanUnified(codepoint: u21) bool {
    const script = unicode.scriptOf(codepoint);
    for ([_]*const [4]u8{ "Hani", "Hira", "Kana", "Bopo" }) |han| {
        if (std.mem.eql(u8, &script, han)) return true;
    }
    return false;
}

/// True if fonts.xml's comma-separated `lang` attribute names `language`
/// (already collapsed by `discovery.fallbackLanguage`).
fn langListHas(lang_list: []const u8, language: []const u8) bool {
    var entries = std.mem.tokenizeAny(u8, lang_list, ", ");
    while (entries.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(discovery.fallbackLanguage(entry), language)) return true;
    }
    return false;
}

fn walkFallbackFamilies(
    data: []const u8,
    codepoint: u21,
    only_language: ?[]const u8,
    path_storage: []u8,
    coverage: anytype,
) ?discovery.Handle {
    var family_pos: usize = 0;
    while (findTag(data, "family", &family_pos)) |family| {
        if (only_language) |language| {
            if (!langListHas(attrValue(family.attrs, "lang") orelse continue, language)) continue;
        }
        var font_pos: usize = 0;
        while (findTag(family.body, "font", &font_pos)) |font| {
            const filename = fontFileName(font.body);
            if (filename.len == 0) continue;
            const path_len = fonts_dir.len + filename.len;
            if (path_len > path_storage.len) continue;
            const path = path_storage[0..path_len];
            @memcpy(path[0..fonts_dir.len], fonts_dir);
            @memcpy(path[fonts_dir.len..], filename);

            const font_index: u32 = @intFromFloat(parseFloat(attrValue(font.attrs, "index")) orelse 0.0);
            if (coverage.covers(path, font_index, codepoint))
                return .{ .path = .{ .path = path, .font_index = font_index } };
        }
    }
    return null;
}

/// A `<font>` body is the filename, optionally followed by `<axis/>` child
/// elements (variable-font instances, Android 8+), so it stops at the first
/// child tag rather than trimming the whole body.
fn fontFileName(body: []const u8) []const u8 {
    const text = body[0 .. std.mem.indexOfScalar(u8, body, '<') orelse body.len];
    return std.mem.trim(u8, text, " \t\r\n");
}

/// Lists every family name fonts.xml defines, including its `<alias>`
/// names (which `selectFamilyByName` resolves) — those are real, selectable
/// names on Android, e.g. "arial" mapping to "sans-serif". Unnamed
/// `<family>` entries are script fallbacks, not selectable, so they're
/// skipped. See `discovery.FamilyList` for the buffer contract.
pub fn availableFamiliesFromXml(
    data: []const u8,
    names_buf: [][]const u8,
    name_storage: []u8,
) []const []const u8 {
    var list: discovery.FamilyList = .{ .names = names_buf, .storage = name_storage };

    var family_pos: usize = 0;
    while (findTag(data, "family", &family_pos)) |family| {
        list.append(attrValue(family.attrs, "name") orelse continue);
    }
    var alias_pos: usize = 0;
    while (findTag(data, "alias", &alias_pos)) |alias| {
        list.append(attrValue(alias.attrs, "name") orelse continue);
    }
    return list.slice();
}

/// Core XML-scanning logic, split out from `selectFamilyByName` so it's
/// testable against an in-memory fonts.xml without needing to run on a real
/// Android device (see the `test`s below).
fn selectFamilyFromXml(
    data: []const u8,
    family_name: []const u8,
    handle_buf: []discovery.Handle,
    properties_buf: []discovery.Properties,
    path_storage: []u8,
) discovery.SelectionError!discovery.FamilyHandle {
    std.debug.assert(handle_buf.len == properties_buf.len);

    var weight_filter: ?f32 = null;
    const target_family = resolveAlias(data, family_name, &weight_filter) orelse family_name;

    var count: usize = 0;
    var path_offset: usize = 0;
    var family_pos: usize = 0;
    while (findTag(data, "family", &family_pos)) |family| {
        const name = attrValue(family.attrs, "name") orelse continue;
        if (!std.ascii.eqlIgnoreCase(name, target_family)) continue;

        var font_pos: usize = 0;
        while (findTag(family.body, "font", &font_pos)) |font| {
            if (count >= handle_buf.len) break;

            const weight = parseFloat(attrValue(font.attrs, "weight")) orelse 400.0;
            if (weight_filter) |wf| {
                if (weight != wf) continue;
            }

            const filename = fontFileName(font.body);
            if (filename.len == 0) continue;
            const path_len = fonts_dir.len + filename.len;
            if (path_offset + path_len > path_storage.len) break;
            const path = path_storage[path_offset..][0..path_len];
            @memcpy(path[0..fonts_dir.len], fonts_dir);
            @memcpy(path[fonts_dir.len..], filename);
            path_offset += path_len;

            const style: discovery.Style = if (std.mem.eql(u8, attrValue(font.attrs, "style") orelse "normal", "italic"))
                .italic
            else
                .normal;
            const index = parseFloat(attrValue(font.attrs, "index")) orelse 0.0;

            handle_buf[count] = .{ .path = .{ .path = path, .font_index = @intFromFloat(index) } };
            properties_buf[count] = .{ .style = style, .weight = .{ .value = weight } };
            count += 1;
        }
        break;
    }

    if (count == 0) return discovery.SelectionError.NotFound;
    return .{ .fonts = handle_buf[0..count], .properties = properties_buf[0..count] };
}

/// Resolves `name` against fonts.xml's `<alias name="..." to="..." [weight="..."]/>`
/// table. Returns the target family name (writing the alias's weight, if
/// any, into `weight_filter`), or `null` if `name` isn't an alias (i.e. it's
/// already a real family name).
fn resolveAlias(data: []const u8, name: []const u8, weight_filter: *?f32) ?[]const u8 {
    var pos: usize = 0;
    while (findTag(data, "alias", &pos)) |alias| {
        const alias_name = attrValue(alias.attrs, "name") orelse continue;
        if (!std.ascii.eqlIgnoreCase(alias_name, name)) continue;
        weight_filter.* = parseFloat(attrValue(alias.attrs, "weight"));
        return attrValue(alias.attrs, "to");
    }
    return null;
}

const Tag = struct {
    attrs: []const u8,
    body: []const u8,
};

/// Finds the next `<name ...>...</name>` (or self-closing `<name .../>`) tag
/// in `data` at or after `pos.*`, advances `pos.*` past it, and returns its
/// attribute text and body. Assumes tags of the same name never nest, which
/// holds for fonts.xml's flat family/font/alias schema.
fn findTag(data: []const u8, name: []const u8, pos: *usize) ?Tag {
    var open_buf: [32]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}", .{name}) catch return null;

    while (true) {
        const idx = std.mem.indexOfPos(u8, data, pos.*, open) orelse return null;
        const after = idx + open.len;
        const boundary_ok = after < data.len and switch (data[after]) {
            ' ', '\t', '\n', '\r', '>', '/' => true,
            else => false,
        };
        if (!boundary_ok) {
            pos.* = after;
            continue;
        }

        const gt = std.mem.indexOfScalarPos(u8, data, after, '>') orelse return null;
        const self_closing = gt > after and data[gt - 1] == '/';
        const attrs = data[after..(if (self_closing) gt - 1 else gt)];

        if (self_closing) {
            pos.* = gt + 1;
            return .{ .attrs = attrs, .body = "" };
        }

        var close_buf: [32]u8 = undefined;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{name}) catch return null;
        const body_start = gt + 1;
        const close_idx = std.mem.indexOfPos(u8, data, body_start, close) orelse return null;
        pos.* = close_idx + close.len;
        return .{ .attrs = attrs, .body = data[body_start..close_idx] };
    }
}

fn attrValue(attrs: []const u8, attr_name: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=\"", .{attr_name}) catch return null;
    const idx = std.mem.indexOf(u8, attrs, needle) orelse return null;
    const start = idx + needle.len;
    const end = std.mem.indexOfScalarPos(u8, attrs, start, '"') orelse return null;
    return attrs[start..end];
}

fn parseFloat(text: ?[]const u8) ?f32 {
    const t = text orelse return null;
    return std.fmt.parseFloat(f32, t) catch null;
}

const test_fonts_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<familyset>
    \\    <family name="sans-serif">
    \\        <font weight="400" style="normal">Roboto-Regular.ttf</font>
    \\        <font weight="400" style="italic">Roboto-Italic.ttf</font>
    \\        <font weight="500" style="normal">Roboto-Medium.ttf</font>
    \\    </family>
    \\    <family name="serif">
    \\        <font weight="400" style="normal">NotoSerif-Regular.ttf</font>
    \\    </family>
    \\    <family lang="und-Arab" variant="elegant">
    \\        <font weight="400" style="normal">NotoNaskhArabic-Regular.ttf</font>
    \\    </family>
    \\    <family name="myanmar-collection">
    \\        <font weight="400" style="normal" index="2">MyanmarFonts.ttc</font>
    \\    </family>
    \\    <alias name="sans-serif-medium" to="sans-serif" weight="500" />
    \\    <alias name="arial" to="sans-serif" />
    \\    <alias name="fantasy" to="serif" />
    \\</familyset>
;

test "Android: selectFamilyFromXml resolves a real family name" {
    var handle_buf: [8]discovery.Handle = undefined;
    var properties_buf: [8]discovery.Properties = undefined;
    var path_storage: [1024]u8 = undefined;

    const family = try selectFamilyFromXml(test_fonts_xml, "sans-serif", &handle_buf, &properties_buf, &path_storage);

    try std.testing.expectEqual(@as(usize, 3), family.fonts.len);
    try std.testing.expectEqualStrings("/system/fonts/Roboto-Regular.ttf", family.fonts[0].path.path);
    try std.testing.expectEqual(discovery.Style.italic, family.properties[1].style);
    try std.testing.expectEqual(@as(f32, 500.0), family.properties[2].weight.value);
}

test "Android: selectFamilyFromXml resolves a plain alias to its target family" {
    var handle_buf: [8]discovery.Handle = undefined;
    var properties_buf: [8]discovery.Properties = undefined;
    var path_storage: [1024]u8 = undefined;

    const family = try selectFamilyFromXml(test_fonts_xml, "arial", &handle_buf, &properties_buf, &path_storage);

    try std.testing.expectEqual(@as(usize, 3), family.fonts.len);
}

test "Android: selectFamilyFromXml resolves a weight-filtered alias to one font" {
    var handle_buf: [8]discovery.Handle = undefined;
    var properties_buf: [8]discovery.Properties = undefined;
    var path_storage: [1024]u8 = undefined;

    const family = try selectFamilyFromXml(test_fonts_xml, "sans-serif-medium", &handle_buf, &properties_buf, &path_storage);

    try std.testing.expectEqual(@as(usize, 1), family.fonts.len);
    try std.testing.expectEqualStrings("/system/fonts/Roboto-Medium.ttf", family.fonts[0].path.path);
}

test "Android: selectFamilyFromXml reads the ttc font_index attribute" {
    var handle_buf: [8]discovery.Handle = undefined;
    var properties_buf: [8]discovery.Properties = undefined;
    var path_storage: [1024]u8 = undefined;

    const family = try selectFamilyFromXml(test_fonts_xml, "myanmar-collection", &handle_buf, &properties_buf, &path_storage);

    try std.testing.expectEqual(@as(u32, 2), family.fonts[0].path.font_index);
}

test "Android: selectFamilyFromXml errors on an unknown family" {
    var handle_buf: [8]discovery.Handle = undefined;
    var properties_buf: [8]discovery.Properties = undefined;
    var path_storage: [1024]u8 = undefined;

    try std.testing.expectError(
        discovery.SelectionError.NotFound,
        selectFamilyFromXml(test_fonts_xml, "Definitely Not A Real Font Family XYZ123", &handle_buf, &properties_buf, &path_storage),
    );
}

/// Stand-in for `FileCoverage` in tests: "covers" exactly the paths listed.
const StubCoverage = struct {
    covering: []const []const u8,

    fn covers(self: StubCoverage, path: []const u8, font_index: u32, codepoint: u21) bool {
        _ = font_index;
        _ = codepoint;
        for (self.covering) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }
};

test "Android: fallbackFromXml walks fonts.xml order into unnamed script families" {
    var path_storage: [1024]u8 = undefined;
    const coverage = StubCoverage{ .covering = &.{"/system/fonts/NotoNaskhArabic-Regular.ttf"} };

    const handle = try fallbackFromXml(test_fonts_xml, 0x0645, null, &path_storage, coverage);

    try std.testing.expectEqualStrings("/system/fonts/NotoNaskhArabic-Regular.ttf", handle.path.path);
}

test "Android: fallbackFromXml prefers the first covering font in document order" {
    var path_storage: [1024]u8 = undefined;
    const coverage = StubCoverage{ .covering = &.{
        "/system/fonts/NotoSerif-Regular.ttf",
        "/system/fonts/Roboto-Italic.ttf",
    } };

    const handle = try fallbackFromXml(test_fonts_xml, 'a', null, &path_storage, coverage);

    try std.testing.expectEqualStrings("/system/fonts/Roboto-Italic.ttf", handle.path.path);
}

test "Android: fallbackFromXml carries the ttc font_index" {
    var path_storage: [1024]u8 = undefined;
    const coverage = StubCoverage{ .covering = &.{"/system/fonts/MyanmarFonts.ttc"} };

    const handle = try fallbackFromXml(test_fonts_xml, 0x1000, null, &path_storage, coverage);

    try std.testing.expectEqual(@as(u32, 2), handle.path.font_index);
}

test "Android: fallbackFromXml errors when nothing covers the codepoint" {
    var path_storage: [1024]u8 = undefined;
    const coverage = StubCoverage{ .covering = &.{} };

    try std.testing.expectError(
        discovery.SelectionError.NotFound,
        fallbackFromXml(test_fonts_xml, 0x1F600, null, &path_storage, coverage),
    );
}

test "Android: selectFamilyFromXml matches alias names case-insensitively" {
    var handle_buf: [8]discovery.Handle = undefined;
    var properties_buf: [8]discovery.Properties = undefined;
    var path_storage: [1024]u8 = undefined;

    const family = try selectFamilyFromXml(test_fonts_xml, "Arial", &handle_buf, &properties_buf, &path_storage);

    try std.testing.expectEqual(@as(usize, 3), family.fonts.len);
}

const test_cjk_fonts_xml =
    \\<familyset>
    \\    <family name="sans-serif">
    \\        <font weight="400" style="normal">Roboto-Regular.ttf</font>
    \\    </family>
    \\    <family lang="zh-Hans">
    \\        <font weight="400" style="normal" index="2">NotoSansCJK-Regular.ttc</font>
    \\    </family>
    \\    <family lang="zh-Hant,zh-Bopo">
    \\        <font weight="400" style="normal" index="3">NotoSansCJK-Regular.ttc</font>
    \\    </family>
    \\    <family lang="ja">
    \\        <font weight="400" style="normal" index="0">NotoSansCJK-Regular.ttc</font>
    \\    </family>
    \\</familyset>
;

fn expectCjkFallbackIndex(expected_index: u32, codepoint: u21, language: ?[]const u8) !void {
    var path_storage: [1024]u8 = undefined;
    const coverage = StubCoverage{ .covering = &.{"/system/fonts/NotoSansCJK-Regular.ttc"} };
    const handle = try fallbackFromXml(test_cjk_fonts_xml, codepoint, language, &path_storage, coverage);
    try std.testing.expectEqual(expected_index, handle.path.font_index);
}

test "Android: fallbackFromXml picks the Han family tagged with the language" {
    try expectCjkFallbackIndex(0, 0x4E2D, "ja-JP");
    try expectCjkFallbackIndex(3, 0x4E2D, "zh-TW");
    try expectCjkFallbackIndex(2, 0x4E2D, "zh-CN");
}

test "Android: fallbackFromXml takes document order without a matching language" {
    try expectCjkFallbackIndex(2, 0x4E2D, null);
    try expectCjkFallbackIndex(2, 0x4E2D, "ko");
}

test "Android: fallbackFromXml ignores the language outside Han" {
    var path_storage: [1024]u8 = undefined;
    const coverage = StubCoverage{ .covering = &.{ "/system/fonts/Roboto-Regular.ttf", "/system/fonts/NotoSansCJK-Regular.ttc" } };
    const handle = try fallbackFromXml(test_cjk_fonts_xml, 'a', "ja", &path_storage, coverage);
    try std.testing.expectEqualStrings("/system/fonts/Roboto-Regular.ttf", handle.path.path);
}

test "Android: fontFileName stops at a variable-font <axis> child" {
    try std.testing.expectEqualStrings("Roboto-Regular.ttf", fontFileName(
        "Roboto-Regular.ttf\n  <axis tag=\"wdth\" stylevalue=\"100\"/>\n",
    ));
}
