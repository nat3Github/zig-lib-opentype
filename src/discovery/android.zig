const std = @import("std");
const discovery = @import("../discovery.zig");

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

pub const Android = struct {
    /// Android's fonts.xml already defines "sans-serif"/"serif"/"monospace"/
    /// "cursive" as real family names, so those resolve natively like
    /// fontconfig's CSS aliases. "fantasy" has no Android family; fonts.xml
    /// itself aliases it to "serif" (`<alias name="fantasy" to="serif"/>`),
    /// so this override just short-circuits to the same result.
    pub const generic_family_names = struct {
        pub const serif = "serif";
        pub const sans_serif = "sans-serif";
        pub const monospace = "monospace";
        pub const cursive = "cursive";
        pub const fantasy = "serif";
    };

    pub fn init() discovery.SelectionError!Android {
        return .{};
    }

    pub fn deinit(self: *Android) void {
        self.* = undefined;
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
};

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
        if (!std.mem.eql(u8, name, target_family)) continue;

        var font_pos: usize = 0;
        while (findTag(family.body, "font", &font_pos)) |font| {
            if (count >= handle_buf.len) break;

            const weight = parseFloat(attrValue(font.attrs, "weight")) orelse 400.0;
            if (weight_filter) |wf| {
                if (weight != wf) continue;
            }

            const filename = std.mem.trim(u8, font.body, " \t\r\n");
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
        if (!std.mem.eql(u8, alias_name, name)) continue;
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
