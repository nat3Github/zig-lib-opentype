const std = @import("std");
const discovery = @import("../discovery.zig");
const parsing = @import("../parsing.zig");

// NOTE: no vendor reference — font-kit only targets desktop OS font APIs,
// which always enumerate fonts already present on disk. A remote source
// (Google Fonts-style CDN, a self-hosted font server, anything reachable
// only by URL — not a browser-only concern, native apps pull fonts from
// URLs too) can't be enumerated that way, so unlike the other backends this
// one doesn't "discover" anything on its own: the caller supplies a
// manifest (family name -> variants -> font URL, e.g. the JSON a Google
// Fonts-style `css2` API would return) that it already fetched. This
// backend's only job is the synchronous half CSS font matching needs —
// parsing that manifest and running `findBestMatch` over it — matching
// `discovery.zig`'s `selectFamilyByName(...) SelectionError!FamilyHandle`
// shape used by every other backend.
//
// Matched fonts come back as `Handle.url`, not `Handle.memory`: the actual
// font bytes haven't been fetched yet, and fetching them is an async network
// call this backend can't make (nor should it — Zig has no portable async
// HTTP client, and a WASM host in particular has no fetch of its own). The
// caller fetches `url` however its host exposes that — libcurl, a WASM
// extern import backed by JS `fetch()`, whatever — and wraps the resulting
// bytes as `Handle.memory` before handing them to the parser.

const Data = struct {
    families: []const struct {
        name: []const u8,
        variants: []const struct {
            weight: f32 = 400.0,
            style: []const u8 = "normal",
            stretch: f32 = 1.0,
            url: []const u8,
            /// CSS `unicode-range` descriptor for this face, verbatim (e.g.
            /// what a Google Fonts `css2` response already emits per
            /// `@font-face`). Only `selectFallbackForCodepoint` reads it;
            /// an empty string means "coverage unknown", which excludes the
            /// variant from fallback but not from `selectFamilyByName`.
            unicode_range: []const u8 = "",
        },
    },
};

pub const ManifestSource = struct {
    /// Manifest JSON, already fetched by the caller. Re-parsed on every
    /// `selectFamilyByName` call, same per-call-query shape as the
    /// Fontconfig/CoreText/Android backends (no persistent cache here
    /// either).
    manifest_json: []const u8,

    pub fn init(manifest_json: []const u8) ManifestSource {
        return .{ .manifest_json = manifest_json };
    }

    /// Looks up a font family by exact name in the manifest and writes its
    /// variants' `Handle.url`s and properties into caller-owned
    /// `handle_buf`/`properties_buf` (same length). `url_storage` backs the
    /// returned `Handle.url.url` slices, same no-alloc-on-the-hot-path
    /// pattern as the Fontconfig/Android backends' `path_storage`.
    pub fn selectFamilyByName(
        self: *const ManifestSource,
        family_name: []const u8,
        handle_buf: []discovery.Handle,
        properties_buf: []discovery.Properties,
        url_storage: []u8,
        allocator: std.mem.Allocator,
    ) discovery.SelectionError!discovery.FamilyHandle {
        return selectFamilyFromManifest(self.manifest_json, family_name, handle_buf, properties_buf, url_storage, allocator);
    }

    /// Finds a manifest entry covering `codepoint`, for the "no OS font API"
    /// targets the manifest backend exists for (WASM/web above all). There is
    /// nothing to query -- a browser exposes no "which font covers U+4E2D"
    /// call from WASM, and CSS's own fallback runs inside the browser's
    /// renderer, not ours -- so the manifest's own document order *is* the
    /// fallback order, the same rule `discovery/android.zig` follows for
    /// `fonts.xml`.
    ///
    /// Coverage comes from each variant's `unicode_range`, not from a `cmap`:
    /// the font bytes haven't been fetched yet (that's the whole point of
    /// `Handle.url`), so the manifest has to declare coverage up front. A
    /// variant with no `unicode_range` is skipped rather than guessed at.
    ///
    /// Returns `Handle.url`; the caller fetches it and wraps the bytes as
    /// `Handle.memory` before parsing, exactly as for `selectFamilyByName`.
    pub fn selectFallbackForCodepoint(
        self: *const ManifestSource,
        codepoint: u21,
        url_storage: []u8,
        allocator: std.mem.Allocator,
    ) discovery.SelectionError!discovery.Handle {
        return fallbackFromManifest(self.manifest_json, codepoint, url_storage, allocator);
    }
};

fn fallbackFromManifest(
    manifest_json: []const u8,
    codepoint: u21,
    url_storage: []u8,
    allocator: std.mem.Allocator,
) discovery.SelectionError!discovery.Handle {
    const parsed = std.json.parseFromSlice(Data, allocator, manifest_json, .{
        .ignore_unknown_fields = true,
    }) catch return discovery.SelectionError.NotFound;
    defer parsed.deinit();

    for (parsed.value.families) |family| {
        for (family.variants) |variant| {
            if (!unicodeRangeCovers(variant.unicode_range, codepoint)) continue;
            if (variant.url.len > url_storage.len) continue;
            const url = url_storage[0..variant.url.len];
            @memcpy(url, variant.url);
            return .{ .url = .{ .url = url } };
        }
    }
    return discovery.SelectionError.NotFound;
}

/// True if a CSS `unicode-range` descriptor (CSS Fonts Level 4 §4.5) covers
/// `codepoint`. Parsed per query rather than pre-merged into a
/// `parsing.Table.cmap.FallbackStack`: building one allocates and
/// sweep-line-merges every range, which only pays off when the same stack
/// is queried repeatedly -- and this backend re-parses its JSON per call
/// anyway, while consumers (dvui's `Font.Cache.dynamic_fallback`) already
/// memoize per codepoint.
fn unicodeRangeCovers(spec: []const u8, codepoint: u21) bool {
    var tokens = std.mem.splitScalar(u8, spec, ',');
    while (tokens.next()) |token| {
        const range = parseRangeToken(token) orelse continue;
        if (codepoint >= range.start and codepoint <= range.end) return true;
    }
    return false;
}

/// One `unicode-range` token: `U+417`, `U+400-4FF`, or the wildcard form
/// `U+4??`. Malformed or out-of-Unicode tokens yield null (skipped by
/// `unicodeRangeCovers`) rather than being guessed at -- a misparsed range
/// silently renders the wrong font.
fn parseRangeToken(raw: []const u8) ?parsing.Table.cmap.Range {
    const token = std.mem.trim(u8, raw, " \t\r\n");
    if (token.len < 3 or (token[0] != 'U' and token[0] != 'u') or token[1] != '+') return null;
    const body = token[2..];

    if (std.mem.indexOfScalar(u8, body, '-')) |dash| {
        const start = std.fmt.parseInt(u21, body[0..dash], 16) catch return null;
        const end = std.fmt.parseInt(u21, body[dash + 1 ..], 16) catch return null;
        if (end < start) return null;
        return .{ .start = start, .end = end };
    }

    if (std.mem.indexOfScalar(u8, body, '?')) |first_wildcard| {
        // Wildcards are only legal as a trailing run (CSS Fonts 4 §4.5).
        for (body[first_wildcard..]) |ch| if (ch != '?') return null;
        var low: [6]u8 = undefined;
        var high: [6]u8 = undefined;
        if (body.len > low.len) return null;
        for (body, 0..) |ch, i| {
            low[i] = if (ch == '?') '0' else ch;
            high[i] = if (ch == '?') 'F' else ch;
        }
        const start = std.fmt.parseInt(u21, low[0..body.len], 16) catch return null;
        const end = std.fmt.parseInt(u21, high[0..body.len], 16) catch return null;
        return .{ .start = start, .end = end };
    }

    const single = std.fmt.parseInt(u21, body, 16) catch return null;
    return .{ .start = single, .end = single };
}

fn selectFamilyFromManifest(
    manifest_json: []const u8,
    family_name: []const u8,
    handle_buf: []discovery.Handle,
    properties_buf: []discovery.Properties,
    url_storage: []u8,
    allocator: std.mem.Allocator,
) discovery.SelectionError!discovery.FamilyHandle {
    std.debug.assert(handle_buf.len == properties_buf.len);

    const parsed = std.json.parseFromSlice(Data, allocator, manifest_json, .{
        .ignore_unknown_fields = true,
    }) catch return discovery.SelectionError.NotFound;
    defer parsed.deinit();

    var count: usize = 0;
    var url_offset: usize = 0;
    for (parsed.value.families) |family| {
        if (!std.mem.eql(u8, family.name, family_name)) continue;

        for (family.variants) |variant| {
            if (count >= handle_buf.len) break;
            if (url_offset + variant.url.len > url_storage.len) break;

            const url = url_storage[url_offset..][0..variant.url.len];
            @memcpy(url, variant.url);
            url_offset += variant.url.len;

            const style: discovery.Style = if (std.mem.eql(u8, variant.style, "italic"))
                .italic
            else if (std.mem.eql(u8, variant.style, "oblique"))
                .oblique
            else
                .normal;

            handle_buf[count] = .{ .url = .{ .url = url } };
            properties_buf[count] = .{
                .style = style,
                .weight = .{ .value = variant.weight },
                .stretch = .{ .value = variant.stretch },
            };
            count += 1;
        }
        break;
    }

    if (count == 0) return discovery.SelectionError.NotFound;
    return .{ .fonts = handle_buf[0..count], .properties = properties_buf[0..count] };
}
