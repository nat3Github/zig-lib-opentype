// Derived from HarfBuzz (Old MIT), FreeType (FTL) and swash (MIT); see THIRD_PARTY_LICENSES.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
pub const png = @import("png.zig");
pub const PngDecodeError = png.DecodeError;
const woff2 = if (build_options.woff2) @import("woff2/woff2.zig") else struct {};

test {
    if (build_options.woff2) _ = woff2;
}

pub const Font = struct {
    data: []const u8,
    table_records: []const TableRecord,
    owned_data: bool = false,

    pub const ParseError = error{
        InvalidSfntVersion,
        InvalidTableDirectory,
        InvalidWoff,
        InvalidWoff2,
        InvalidCollection,
        TableNotFound,
        UnexpectedEndOfData,
        InvalidTableFormat,
        Woff2NotSupported,
        RecursionLimitExceeded,
    };

    pub const Tag = [4]u8;

    // A 4-byte tag compares as one u32 rather than through `mem.eql`'s
    // generic byte loop, which profiled hot in cold frames. Byte order is
    // irrelevant to equality, so the bitcast needs no endianness handling.
    pub fn tagEql(a: Tag, b: Tag) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }

    pub const TableRecord = struct {
        tag: Tag,
        offset: u32,
        length: u32,
    };

    pub fn parse(alloc: Allocator, bytes: []const u8) (ParseError || error{OutOfMemory})!Font {
        if (bytes.len < 4) return error.InvalidSfntVersion;
        if (std.mem.eql(u8, bytes[0..4], "wOFF")) return parseWoff(alloc, bytes);
        if (std.mem.eql(u8, bytes[0..4], "wOF2")) {
            if (!build_options.woff2) return error.Woff2NotSupported;
            return parseWoff2(alloc, bytes);
        }
        return parseSfntAt(alloc, bytes, 0);
    }

    pub fn deinit(self: Font, alloc: Allocator) void {
        alloc.free(self.table_records);
        if (self.owned_data) alloc.free(self.data);
    }

    pub const max_directory_tables = 256;
    pub const max_directory_size = 12 + max_directory_tables * 16;

    /// Looks `tag` up in a standalone prefix of an sfnt table directory
    /// (at most `max_directory_size` bytes), without the rest of the font.
    /// The returned range is unchecked: the caller reads it from its source.
    pub fn findTableInDirectory(directory: []const u8, tag: Tag) ?TableRecord {
        var cursor = Cursor{ .data = directory };
        if (!isSfntVersion(cursor.readU32() catch return null)) return null;
        const num_tables = @min(cursor.readU16() catch return null, max_directory_tables);
        cursor.skip(6) catch return null;
        for (0..num_tables) |_| {
            const record_tag = cursor.readBytes(4) catch return null;
            cursor.skip(4) catch return null;
            const offset = cursor.readU32() catch return null;
            const length = cursor.readU32() catch return null;
            if (std.mem.eql(u8, record_tag, &tag)) return .{ .tag = tag, .offset = offset, .length = length };
        }
        return null;
    }

    pub fn tableData(self: Font, tag: Tag) ?[]const u8 {
        for (self.table_records) |rec| {
            if (!tagEql(rec.tag, tag)) continue;
            if (@as(u64, rec.offset) + rec.length > self.data.len) return null;
            return self.data[rec.offset..][0..rec.length];
        }
        return null;
    }

    /// Bounds the assembled sfnt by something other than the directory's own
    /// length fields.
    pub const max_face_subset_size: u64 = 1 << 28;
    /// Same, for one `sbix` strike (Apple Color Emoji's largest is 74MiB).
    pub const max_sbix_strike_size: u64 = 1 << 27;

    pub const FaceSubsetOptions = struct {
        /// Leave the `sbix` table out of the assembled sfnt. Colour-bitmap
        /// strikes dominate some system faces -- Apple Color Emoji is 179MiB
        /// of sbix in a 180MiB face -- and only the strike matching the
        /// target ppem is ever decoded, so a caller that can supply that one
        /// strike later (`readSbixStrike`) should not read all nine. The
        /// table is omitted whole rather than left hollow: a strike list
        /// pointing at bytes that aren't there reads as a font whose glyphs
        /// are absent from every strike, which silently rasterizes the wrong
        /// thing instead of failing.
        drop_sbix: bool = false,
    };

    /// Reads face `face_index`'s table directory out of `file`, following the
    /// `ttcf` header if there is one. Shared by the two readers below, which
    /// both need the directory and nothing else before they know what to read.
    fn readFaceDirectory(
        io: std.Io,
        file: std.Io.File,
        face_index: u32,
        out: *[max_directory_size]u8,
    ) !usize {
        var header: [Collection.max_header_size]u8 = undefined;
        const header_len = try file.readPositionalAll(io, &header, 0);
        var offsets_buf: [Collection.max_faces]u32 = undefined;
        const directory_start: u64 = if (Collection.faceOffsets(header[0..header_len], &offsets_buf)) |offsets| blk: {
            if (face_index >= offsets.len) return error.InvalidCollection;
            break :blk offsets[face_index];
        } else 0;
        return file.readPositionalAll(io, out, directory_start);
    }

    /// Whether face `face_index` has an outline table this codebase can
    /// rasterize, answered from the face's table directory alone -- no table
    /// bytes, no parse. Font discovery uses it to drop a candidate whose
    /// glyphs are in a format we can't draw (Apple's `hvgl`-only UI faces)
    /// before anything reads the file proper.
    pub fn faceHasOutlineTable(io: std.Io, file: std.Io.File, face_index: u32) !bool {
        var directory: [max_directory_size]u8 = undefined;
        const directory_len = try readFaceDirectory(io, file, face_index, &directory);
        const outline_tags = [_]Tag{ .{ 'g', 'l', 'y', 'f' }, .{ 'C', 'F', 'F', ' ' }, .{ 'C', 'F', 'F', '2' } };
        for (outline_tags) |tag| {
            if (findTableInDirectory(directory[0..directory_len], tag) != null) return true;
        }
        return false;
    }

    /// Assembles face `face_index` of the sfnt or `ttcf` collection in `file`
    /// as a standalone sfnt, reading only that face's directory and tables --
    /// a collection's other faces are never touched, so one face of a
    /// multi-face .ttc costs its own tables instead of the whole file. Table
    /// offsets are rewritten for the new layout, so the result reparses with
    /// `parse` like any other font.
    pub fn readFaceAsStandaloneSfnt(
        alloc: Allocator,
        io: std.Io,
        file: std.Io.File,
        face_index: u32,
        options: FaceSubsetOptions,
    ) ![]u8 {
        const file_size = (try file.stat(io)).size;

        var directory: [max_directory_size]u8 = undefined;
        const directory_len = try readFaceDirectory(io, file, face_index, &directory);
        var cursor = Cursor{ .data = directory[0..directory_len] };
        const sfnt_version = try cursor.readU32();
        if (!isSfntVersion(sfnt_version)) return error.InvalidSfntVersion;
        const num_tables = try cursor.readU16();
        if (num_tables > max_directory_tables) return error.InvalidTableDirectory;
        try cursor.skip(6);

        const records = try alloc.alloc(TableRecord, num_tables);
        defer alloc.free(records);
        var kept: usize = 0;
        var total: u64 = 0;
        for (0..num_tables) |_| {
            const tag = try cursor.readBytes(4);
            _ = try cursor.readU32();
            const offset = try cursor.readU32();
            const length = try cursor.readU32();
            if (@as(u64, offset) + length > file_size) return error.InvalidTableDirectory;
            if (options.drop_sbix and tagEql(tag[0..4].*, .{ 's', 'b', 'i', 'x' })) continue;
            total = std.mem.alignForward(u64, total + length, 4);
            if (total > max_face_subset_size) return error.InvalidTableDirectory;
            records[kept] = .{ .tag = tag[0..4].*, .offset = offset, .length = length };
            kept += 1;
        }

        const directory_size = 12 + kept * 16;
        const sfnt = try alloc.alloc(u8, directory_size + @as(usize, @intCast(total)));
        errdefer alloc.free(sfnt);

        std.mem.writeInt(u32, sfnt[0..4], sfnt_version, .big);
        std.mem.writeInt(u16, sfnt[4..6], @intCast(kept), .big);
        @memset(sfnt[6..12], 0); // searchRange/entrySelector/rangeShift: unread by parseSfntAt

        var write_offset: usize = directory_size;
        for (records[0..kept], 0..) |rec, i| {
            const read = try file.readPositionalAll(io, sfnt[write_offset..][0..rec.length], rec.offset);
            if (read != rec.length) return error.UnexpectedEndOfData;
            const entry = sfnt[12 + i * 16 ..][0..16];
            entry[0..4].* = rec.tag;
            std.mem.writeInt(u32, entry[4..8], 0, .big); // checksum: unread by parseSfntAt
            std.mem.writeInt(u32, entry[8..12], @intCast(write_offset), .big);
            std.mem.writeInt(u32, entry[12..16], rec.length, .big);
            const padded = std.mem.alignForward(usize, write_offset + rec.length, 4);
            // Only the alignment gap needs zeroing -- the preads cover every
            // other byte. Zeroing the whole table region instead costs ~30ms
            // on a 180MB face, all of it immediately overwritten.
            @memset(sfnt[write_offset + rec.length .. padded], 0);
            write_offset = padded;
        }
        return sfnt;
    }

    /// The one `sbix` strike a renderer at `ppem` would pick, rebuilt as a
    /// valid single-strike `sbix` table, reading only that strike's bytes.
    /// A strike is self-contained (its glyph offsets are strike-relative),
    /// so moving one into a fresh table rewrites nothing but the strike list.
    /// Null when the face has no `sbix`, or none of its strikes is usable --
    /// the caller then holds a font with no colour bitmaps, exactly like one
    /// that never shipped any.
    ///
    /// Strike choice mirrors `Table.sbix.findStrike`: the smallest strike at
    /// or above `ppem`, else the largest below it.
    pub fn readSbixStrike(
        alloc: Allocator,
        io: std.Io,
        file: std.Io.File,
        face_index: u32,
        ppem: u16,
    ) !?[]u8 {
        var directory: [max_directory_size]u8 = undefined;
        const directory_len = try readFaceDirectory(io, file, face_index, &directory);
        const record = findTableInDirectory(directory[0..directory_len], .{ 's', 'b', 'i', 'x' }) orelse return null;

        const file_size = (try file.stat(io)).size;
        if (@as(u64, record.offset) + record.length > file_size) return error.InvalidTableDirectory;
        if (record.length < 8) return null;

        var header: [8]u8 = undefined;
        const header_read = try file.readPositionalAll(io, &header, record.offset);
        if (header_read != header.len) return error.UnexpectedEndOfData;
        const num_strikes = std.mem.readInt(u32, header[4..8], .big);
        if (num_strikes == 0) return null;
        if (8 + @as(u64, num_strikes) * 4 > record.length) return error.InvalidTableFormat;

        const offset_bytes = try alloc.alloc(u8, @as(usize, num_strikes) * 4);
        defer alloc.free(offset_bytes);
        const offsets_read = try file.readPositionalAll(io, offset_bytes, record.offset + 8);
        if (offsets_read != offset_bytes.len) return error.UnexpectedEndOfData;

        var chosen: ?u32 = null;
        var chosen_ppem: u16 = 0;
        for (0..num_strikes) |i| {
            const offset = std.mem.readInt(u32, offset_bytes[i * 4 ..][0..4], .big);
            if (@as(u64, offset) + 4 > record.length) return error.InvalidTableFormat;
            var strike_header: [4]u8 = undefined;
            const strike_read = try file.readPositionalAll(io, &strike_header, record.offset + offset);
            if (strike_read != strike_header.len) return error.UnexpectedEndOfData;
            const strike_ppem = std.mem.readInt(u16, strike_header[0..2], .big);
            if (strike_ppem == 0) continue;
            if (chosen == null) {
                chosen = offset;
                chosen_ppem = strike_ppem;
                continue;
            }
            const fits = strike_ppem >= ppem;
            const chosen_fits = chosen_ppem >= ppem;
            if (fits and (!chosen_fits or strike_ppem < chosen_ppem)) {
                chosen = offset;
                chosen_ppem = strike_ppem;
            } else if (!fits and !chosen_fits and strike_ppem > chosen_ppem) {
                chosen = offset;
                chosen_ppem = strike_ppem;
            }
        }
        const strike_offset = chosen orelse return null;

        // A strike runs until the next one starts. The list is not required to
        // be sorted, so this is the nearest following offset, not the next index.
        var strike_end: u32 = record.length;
        for (0..num_strikes) |i| {
            const offset = std.mem.readInt(u32, offset_bytes[i * 4 ..][0..4], .big);
            if (offset > strike_offset and offset < strike_end) strike_end = offset;
        }
        if (strike_end <= strike_offset) return error.InvalidTableFormat;
        const strike_len = strike_end - strike_offset;
        if (strike_len > max_sbix_strike_size) return error.InvalidTableFormat;

        const table = try alloc.alloc(u8, 12 + @as(usize, strike_len));
        errdefer alloc.free(table);
        table[0..2].* = header[0..2].*; // version
        table[2..4].* = header[2..4].*; // flags
        std.mem.writeInt(u32, table[4..8], 1, .big);
        std.mem.writeInt(u32, table[8..12], 12, .big);
        const body_read = try file.readPositionalAll(io, table[12..], record.offset + strike_offset);
        if (body_read != strike_len) return error.UnexpectedEndOfData;
        return table;
    }
};

pub const Collection = struct {
    data: []const u8,
    fonts: []const Font,

    pub fn parse(alloc: Allocator, bytes: []const u8) (Font.ParseError || error{OutOfMemory})!Collection {
        if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "ttcf")) return error.InvalidCollection;
        const num_fonts = std.mem.readInt(u32, bytes[8..][0..4], .big);
        if (12 + @as(u64, num_fonts) * 4 > bytes.len) return error.InvalidCollection;

        const fonts = try alloc.alloc(Font, num_fonts);
        errdefer alloc.free(fonts);
        var initialized: usize = 0;
        errdefer for (fonts[0..initialized]) |font| font.deinit(alloc);
        for (fonts, 0..) |*font, i| {
            const pos = 12 + i * 4;
            const offset = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            if (offset >= bytes.len) return error.InvalidCollection;
            font.* = parseSfntAt(alloc, bytes, offset) catch return error.InvalidCollection;
            initialized += 1;
        }
        return .{ .data = bytes, .fonts = fonts };
    }

    pub const max_faces = 256;
    pub const max_header_size = 12 + max_faces * 4;

    /// Face directory offsets from a standalone prefix of a `ttcf` header
    /// (at most `max_header_size` bytes); faces past `max_faces` are ignored.
    pub fn faceOffsets(header: []const u8, out: *[max_faces]u32) ?[]const u32 {
        if (header.len < 12 or !std.mem.eql(u8, header[0..4], "ttcf")) return null;
        const num_fonts = @min(std.mem.readInt(u32, header[8..][0..4], .big), max_faces);
        if (12 + @as(usize, num_fonts) * 4 > header.len) return null;
        for (out[0..num_fonts], 0..) |*offset, i| offset.* = std.mem.readInt(u32, header[12 + i * 4 ..][0..4], .big);
        return out[0..num_fonts];
    }

    pub fn deinit(self: Collection, alloc: Allocator) void {
        for (self.fonts) |font| font.deinit(alloc);
        alloc.free(self.fonts);
    }
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn atEnd(self: Cursor) bool {
        return self.pos >= self.data.len;
    }

    fn readU8(self: *Cursor) Font.ParseError!u8 {
        if (self.pos + 1 > self.data.len) return error.UnexpectedEndOfData;
        defer self.pos += 1;
        return self.data[self.pos];
    }

    fn readI8(self: *Cursor) Font.ParseError!i8 {
        return @bitCast(try self.readU8());
    }

    fn readU16(self: *Cursor) Font.ParseError!u16 {
        if (self.pos + 2 > self.data.len) return error.UnexpectedEndOfData;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    fn readI16(self: *Cursor) Font.ParseError!i16 {
        return @bitCast(try self.readU16());
    }

    fn readU32(self: *Cursor) Font.ParseError!u32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEndOfData;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn readI32(self: *Cursor) Font.ParseError!i32 {
        return @bitCast(try self.readU32());
    }

    fn readBytes(self: *Cursor, n: usize) Font.ParseError![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEndOfData;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    fn skip(self: *Cursor, n: usize) Font.ParseError!void {
        if (self.pos + n > self.data.len) return error.UnexpectedEndOfData;
        self.pos += n;
    }
};

/// Narrows a 64-bit-accumulated table offset to a `usize` index, or null when
/// `[offset, offset + need)` falls outside `data`. The wide accumulator is the
/// point: `base + fontProvidedU32` wraps in u32 before any range check can see
/// it.
fn offsetWithin(data: []const u8, offset: u64, need: u64) ?usize {
    if (offset + need > data.len) return null;
    return @intCast(offset);
}

fn sliceChecked(data: []const u8, offset: u32, len: u32) Font.ParseError![]const u8 {
    const end = @as(u64, offset) + len;
    if (end > data.len) return error.UnexpectedEndOfData;
    return data[offset..][0..len];
}

fn isSfntVersion(version: u32) bool {
    return version == 0x00010000 or version == 0x4F54544F or version == 0x74727565;
}

fn parseSfntAt(alloc: Allocator, data: []const u8, directory_start: usize) (Font.ParseError || error{OutOfMemory})!Font {
    var cursor = Cursor{ .data = data, .pos = directory_start };
    if (!isSfntVersion(try cursor.readU32())) return error.InvalidSfntVersion;
    const num_tables = try cursor.readU16();
    try cursor.skip(6);
    if (directory_start + 12 + @as(u64, num_tables) * 16 > data.len) return error.InvalidTableDirectory;

    const table_records = try alloc.alloc(Font.TableRecord, num_tables);
    errdefer alloc.free(table_records);
    for (table_records) |*rec| {
        const tag = try cursor.readBytes(4);
        _ = try cursor.readU32();
        const offset = try cursor.readU32();
        const length = try cursor.readU32();
        if (@as(u64, offset) + length > data.len) return error.InvalidTableDirectory;
        rec.* = .{ .tag = tag[0..4].*, .offset = offset, .length = length };
    }
    return .{ .data = data, .table_records = table_records };
}

/// Matches woff2/reconstruct.zig's cap: bounds decompressed output by
/// something other than the attacker-supplied length field.
const max_woff_table_size: u32 = 1 << 26;

fn parseWoff(alloc: Allocator, bytes: []const u8) (Font.ParseError || error{OutOfMemory})!Font {
    if (bytes.len < 44) return error.InvalidWoff;
    const num_tables = std.mem.readInt(u16, bytes[12..][0..2], .big);
    const dir_start: usize = 44;
    if (dir_start + @as(u64, num_tables) * 20 > bytes.len) return error.InvalidWoff;

    var combined: std.ArrayList(u8) = .empty;
    errdefer combined.deinit(alloc);
    const table_records = alloc.alloc(Font.TableRecord, num_tables) catch return error.OutOfMemory;
    errdefer alloc.free(table_records);

    for (table_records, 0..) |*rec, i| {
        const pos = dir_start + i * 20;
        const tag = bytes[pos..][0..4];
        const table_offset = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .big);
        const comp_length = std.mem.readInt(u32, bytes[pos + 8 ..][0..4], .big);
        const orig_length = std.mem.readInt(u32, bytes[pos + 12 ..][0..4], .big);
        if (@as(u64, table_offset) + comp_length > bytes.len) return error.InvalidWoff;
        const compressed = bytes[table_offset..][0..comp_length];

        if (combined.items.len + orig_length > max_woff_table_size) return error.InvalidWoff;
        const start_in_combined: u32 = @intCast(combined.items.len);
        if (comp_length == orig_length) {
            combined.appendSlice(alloc, compressed) catch return error.OutOfMemory;
        } else {
            // Decompress into an exactly-sized slice: a zlib bomb hits WriteFailed
            // instead of expanding until the allocator gives out.
            const out = combined.addManyAsSlice(alloc, orig_length) catch return error.OutOfMemory;
            var in_reader: std.Io.Reader = .fixed(compressed);
            var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&in_reader, .zlib, &decompress_buffer);
            var out_writer: std.Io.Writer = .fixed(out);
            const written = decompress.reader.streamRemaining(&out_writer) catch return error.InvalidWoff;
            if (written != orig_length) return error.InvalidWoff;
        }
        rec.* = .{ .tag = tag.*, .offset = start_in_combined, .length = orig_length };
    }

    const data = combined.toOwnedSlice(alloc) catch return error.OutOfMemory;
    return .{ .data = data, .table_records = table_records, .owned_data = true };
}

fn parseWoff2(alloc: Allocator, bytes: []const u8) (Font.ParseError || error{OutOfMemory})!Font {
    const result = woff2.reconstruct.parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => return error.InvalidWoff2,
    };
    defer alloc.free(result.data);
    defer alloc.free(result.tables);

    const flavor = std.mem.readInt(u32, bytes[4..8], .big);
    if (!isSfntVersion(flavor)) return error.InvalidWoff2;
    if (result.tables.len > Font.max_directory_tables) return error.InvalidWoff2;

    // Assemble a real sfnt, not just the table bytes: `data` outlives this
    // Font as a reusable font source, so it has to still describe itself
    // when something reparses it without the original table records.
    const directory_size = 12 + result.tables.len * 16;
    const sfnt = try alloc.alloc(u8, directory_size + result.data.len);
    errdefer alloc.free(sfnt);
    const table_records = try alloc.alloc(Font.TableRecord, result.tables.len);
    errdefer alloc.free(table_records);

    std.mem.writeInt(u32, sfnt[0..4], flavor, .big);
    std.mem.writeInt(u16, sfnt[4..6], @intCast(result.tables.len), .big);
    @memset(sfnt[6..12], 0); // searchRange/entrySelector/rangeShift: unread by parseSfntAt
    @memcpy(sfnt[directory_size..], result.data);
    for (table_records, result.tables, 0..) |*rec, t, i| {
        const offset: u32 = @intCast(directory_size + t.offset);
        rec.* = .{ .tag = t.tag, .offset = offset, .length = t.length };
        const entry = sfnt[12 + i * 16 ..][0..16];
        entry[0..4].* = t.tag;
        std.mem.writeInt(u32, entry[4..8], 0, .big); // checksum: unread by parseSfntAt
        std.mem.writeInt(u32, entry[8..12], offset, .big);
        std.mem.writeInt(u32, entry[12..16], t.length, .big);
    }

    return .{ .data = sfnt, .table_records = table_records, .owned_data = true };
}

pub const Table = struct {
    pub const head = struct {
        units_per_em: u16,
        index_to_loc_format: i16,

        pub fn parse(data: []const u8) Font.ParseError!head {
            if (data.len < 54) return error.InvalidTableFormat;
            return .{
                .units_per_em = std.mem.readInt(u16, data[18..][0..2], .big),
                .index_to_loc_format = std.mem.readInt(i16, data[50..][0..2], .big),
            };
        }
    };

    pub const hhea = struct {
        number_of_h_metrics: u16,

        pub fn parse(data: []const u8) Font.ParseError!hhea {
            if (data.len < 36) return error.InvalidTableFormat;
            return .{ .number_of_h_metrics = std.mem.readInt(u16, data[34..][0..2], .big) };
        }
    };

    /// `numOfLongVerMetrics` sits at the same byte offset (34) as hhea's
    /// `numberOfHMetrics` - the two tables share layout up to that field.
    pub const vhea = struct {
        number_of_long_ver_metrics: u16,

        pub fn parse(data: []const u8) Font.ParseError!vhea {
            if (data.len < 36) return error.InvalidTableFormat;
            return .{ .number_of_long_ver_metrics = std.mem.readInt(u16, data[34..][0..2], .big) };
        }
    };

    pub const maxp = struct {
        num_glyphs: u16,
        /// 0 for a version-0.5 (CFF-flavored) `maxp`, which has no
        /// hinting-related fields — safe, since CFF glyphs never reach the
        /// TrueType bytecode interpreter.
        max_twilight_points: u16 = 0,

        pub fn parse(data: []const u8) Font.ParseError!maxp {
            if (data.len < 6) return error.InvalidTableFormat;
            return .{
                .num_glyphs = std.mem.readInt(u16, data[4..][0..2], .big),
                .max_twilight_points = if (data.len >= 18) std.mem.readInt(u16, data[16..][0..2], .big) else 0,
            };
        }
    };

    /// Raw FWord array; each entry scaled to pixels by the hinting
    /// interpreter at run time (values depend on ppem, not fixed at parse).
    pub const cvt = struct {
        pub fn count(data: []const u8) u32 {
            return @intCast(data.len / 2);
        }

        pub fn entry(data: []const u8, index: u32) i16 {
            const pos = @as(usize, index) * 2;
            if (pos + 2 > data.len) return 0;
            return std.mem.readInt(i16, data[pos..][0..2], .big);
        }
    };

    /// Minimal `name` table reader: only nameID 6 (PostScript name), used by
    /// the CoreText discovery backend to disambiguate which font within a
    /// `.ttc` a `CTFontDescriptor` refers to (CoreText's font-matching API
    /// has no way to return a face index directly). PostScript names are
    /// always ASCII, so platform 3 (Windows, UTF-16BE) records are decoded
    /// by dropping the (always-zero) high byte rather than pulling in a
    /// full UTF-16 decoder.
    pub const name = struct {
        /// u16 count/offsets can't address past 6 + 65535*12 + 2*65535
        /// bytes, so a prefix this long loses no name records.
        pub const max_addressable_size = 1 << 20;

        pub fn postscriptName(data: []const u8, buf: []u8) ?[]const u8 {
            return findImpl(data, 6, buf) catch null;
        }

        /// Human-readable family name (nameID 16 "typographic family" if
        /// present, else nameID 1) -- for UI display only, e.g. showing which
        /// system font a dynamic fallback resolved to.
        pub fn familyName(data: []const u8, buf: []u8) ?[]const u8 {
            return (findImpl(data, 16, buf) catch null) orelse (findImpl(data, 1, buf) catch null);
        }

        fn findImpl(data: []const u8, name_id: u16, buf: []u8) !?[]const u8 {
            var cursor = Cursor{ .data = data };
            _ = try cursor.readU16(); // format
            const count = try cursor.readU16();
            const string_offset = try cursor.readU16();

            const Record = struct { offset: u16, length: u16 };
            var mac_record: ?Record = null;
            var win_record: ?Record = null;

            for (0..count) |_| {
                const platform_id = try cursor.readU16();
                _ = try cursor.readU16(); // encoding_id
                _ = try cursor.readU16(); // language_id
                const rec_name_id = try cursor.readU16();
                const length = try cursor.readU16();
                const offset = try cursor.readU16();
                if (rec_name_id != name_id) continue;
                if (platform_id == 1 and mac_record == null) mac_record = .{ .offset = offset, .length = length };
                if (platform_id == 3 and win_record == null) win_record = .{ .offset = offset, .length = length };
            }

            if (mac_record) |r| {
                const bytes = try sliceChecked(data, @as(u32, string_offset) + r.offset, r.length);
                if (bytes.len > buf.len) return null;
                @memcpy(buf[0..bytes.len], bytes);
                return buf[0..bytes.len];
            }
            if (win_record) |r| {
                const bytes = try sliceChecked(data, @as(u32, string_offset) + r.offset, r.length);
                const char_count = bytes.len / 2;
                if (char_count > buf.len) return null;
                for (0..char_count) |i| {
                    if (bytes[i * 2] != 0) return null; // non-ASCII PostScript name
                    buf[i] = bytes[i * 2 + 1];
                }
                return buf[0..char_count];
            }
            return null;
        }
    };

    pub const cmap = struct {
        pub fn lookup(data: []const u8, codepoint: u21) ?u16 {
            const sel = resolve(data) orelse return null;
            return sel.lookup(codepoint);
        }

        /// The subtable `lookup` would pick, resolved once so a caller
        /// looking up many codepoints doesn't re-scan and re-score the
        /// subtable directory per codepoint.
        pub const Resolved = struct {
            sub: []const u8,
            format: u16,

            /// A Macintosh-platform subtable is indexed by a byte in a
            /// legacy encoding, not by codepoint, so a Unicode request has
            /// to be translated first. Only ever `.none` unless the font
            /// has no Unicode subtable at all.
            legacy: Legacy = .none,

            /// The format 14 (Unicode Variation Sequences) subtable, empty
            /// when the font has none.
            variations: []const u8 = &.{},

            pub const Legacy = enum { none, ascii, mac_roman };

            /// hb's `get_variation_glyph`: the glyph for `codepoint` followed
            /// by variation selector `selector`, or null when the font lists
            /// no such sequence.
            pub fn lookupVariation(self: Resolved, codepoint: u21, selector: u21) ?u16 {
                const sub = self.variations;
                if (sub.len < 10) return null;
                const record_count = @min(std.mem.readInt(u32, sub[6..10], .big), (sub.len - 10) / 11);
                var lo: usize = 0;
                var hi: usize = record_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const pos = 10 + mid * 11;
                    const record_selector = std.mem.readInt(u24, sub[pos..][0..3], .big);
                    if (selector < record_selector) {
                        hi = mid;
                    } else if (selector > record_selector) {
                        lo = mid + 1;
                    } else {
                        const default_offset = std.mem.readInt(u32, sub[pos + 3 ..][0..4], .big);
                        const non_default_offset = std.mem.readInt(u32, sub[pos + 7 ..][0..4], .big);
                        if (default_offset != 0 and defaultUvsCovers(sub, default_offset, codepoint)) return self.lookup(codepoint);
                        if (non_default_offset == 0) return null;
                        return nonDefaultUvsGlyph(sub, non_default_offset, codepoint);
                    }
                }
                return null;
            }

            fn defaultUvsCovers(sub: []const u8, offset: u32, codepoint: u21) bool {
                if (@as(u64, offset) + 4 > sub.len) return false;
                const range_count = @min(std.mem.readInt(u32, sub[offset..][0..4], .big), (sub.len - offset - 4) / 4);
                var lo: usize = 0;
                var hi: usize = range_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const pos = offset + 4 + mid * 4;
                    const start = std.mem.readInt(u24, sub[pos..][0..3], .big);
                    if (codepoint < start) {
                        hi = mid;
                    } else if (codepoint > @as(u32, start) + sub[pos + 3]) {
                        lo = mid + 1;
                    } else return true;
                }
                return false;
            }

            fn nonDefaultUvsGlyph(sub: []const u8, offset: u32, codepoint: u21) ?u16 {
                if (@as(u64, offset) + 4 > sub.len) return null;
                const mapping_count = @min(std.mem.readInt(u32, sub[offset..][0..4], .big), (sub.len - offset - 4) / 5);
                var lo: usize = 0;
                var hi: usize = mapping_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const pos = offset + 4 + mid * 5;
                    const value = std.mem.readInt(u24, sub[pos..][0..3], .big);
                    if (codepoint < value) {
                        hi = mid;
                    } else if (codepoint > value) {
                        lo = mid + 1;
                    } else {
                        const glyph = std.mem.readInt(u16, sub[pos + 3 ..][0..2], .big);
                        return if (glyph == 0) null else glyph;
                    }
                }
                return null;
            }

            pub fn lookup(self: Resolved, codepoint: u21) ?u16 {
                const index: u21 = switch (self.legacy) {
                    .none => codepoint,
                    .ascii => if (codepoint < 0x80) codepoint else return null,
                    .mac_roman => if (codepoint < 0x80) codepoint else (unicodeToMacRoman(codepoint) orelse return null),
                };
                return switch (self.format) {
                    0 => lookupFormat0(self.sub, index),
                    4 => lookupFormat4(self.sub, index),
                    6 => lookupTrimmed(self.sub, index, false),
                    10 => lookupTrimmed(self.sub, index, true),
                    12 => lookupSegmented(self.sub, index, false),
                    13 => lookupSegmented(self.sub, index, true),
                    else => null,
                };
            }
        };

        /// Ported from hb-ot-cmap-table.hh's `unicode_to_macroman`: the
        /// non-ASCII half of Mac OS Roman, sorted by codepoint.
        const mac_roman_from_unicode = [_]struct { u16, u8 }{
            .{ 0x00A0, 0xCA }, .{ 0x00A1, 0xC1 }, .{ 0x00A2, 0xA2 }, .{ 0x00A3, 0xA3 },
            .{ 0x00A5, 0xB4 }, .{ 0x00A7, 0xA4 }, .{ 0x00A8, 0xAC }, .{ 0x00A9, 0xA9 },
            .{ 0x00AA, 0xBB }, .{ 0x00AB, 0xC7 }, .{ 0x00AC, 0xC2 }, .{ 0x00AE, 0xA8 },
            .{ 0x00AF, 0xF8 }, .{ 0x00B0, 0xA1 }, .{ 0x00B1, 0xB1 }, .{ 0x00B4, 0xAB },
            .{ 0x00B5, 0xB5 }, .{ 0x00B6, 0xA6 }, .{ 0x00B7, 0xE1 }, .{ 0x00B8, 0xFC },
            .{ 0x00BA, 0xBC }, .{ 0x00BB, 0xC8 }, .{ 0x00BF, 0xC0 }, .{ 0x00C0, 0xCB },
            .{ 0x00C1, 0xE7 }, .{ 0x00C2, 0xE5 }, .{ 0x00C3, 0xCC }, .{ 0x00C4, 0x80 },
            .{ 0x00C5, 0x81 }, .{ 0x00C6, 0xAE }, .{ 0x00C7, 0x82 }, .{ 0x00C8, 0xE9 },
            .{ 0x00C9, 0x83 }, .{ 0x00CA, 0xE6 }, .{ 0x00CB, 0xE8 }, .{ 0x00CC, 0xED },
            .{ 0x00CD, 0xEA }, .{ 0x00CE, 0xEB }, .{ 0x00CF, 0xEC }, .{ 0x00D1, 0x84 },
            .{ 0x00D2, 0xF1 }, .{ 0x00D3, 0xEE }, .{ 0x00D4, 0xEF }, .{ 0x00D5, 0xCD },
            .{ 0x00D6, 0x85 }, .{ 0x00D8, 0xAF }, .{ 0x00D9, 0xF4 }, .{ 0x00DA, 0xF2 },
            .{ 0x00DB, 0xF3 }, .{ 0x00DC, 0x86 }, .{ 0x00DF, 0xA7 }, .{ 0x00E0, 0x88 },
            .{ 0x00E1, 0x87 }, .{ 0x00E2, 0x89 }, .{ 0x00E3, 0x8B }, .{ 0x00E4, 0x8A },
            .{ 0x00E5, 0x8C }, .{ 0x00E6, 0xBE }, .{ 0x00E7, 0x8D }, .{ 0x00E8, 0x8F },
            .{ 0x00E9, 0x8E }, .{ 0x00EA, 0x90 }, .{ 0x00EB, 0x91 }, .{ 0x00EC, 0x93 },
            .{ 0x00ED, 0x92 }, .{ 0x00EE, 0x94 }, .{ 0x00EF, 0x95 }, .{ 0x00F1, 0x96 },
            .{ 0x00F2, 0x98 }, .{ 0x00F3, 0x97 }, .{ 0x00F4, 0x99 }, .{ 0x00F5, 0x9B },
            .{ 0x00F6, 0x9A }, .{ 0x00F7, 0xD6 }, .{ 0x00F8, 0xBF }, .{ 0x00F9, 0x9D },
            .{ 0x00FA, 0x9C }, .{ 0x00FB, 0x9E }, .{ 0x00FC, 0x9F }, .{ 0x00FF, 0xD8 },
            .{ 0x0131, 0xF5 }, .{ 0x0152, 0xCE }, .{ 0x0153, 0xCF }, .{ 0x0178, 0xD9 },
            .{ 0x0192, 0xC4 }, .{ 0x02C6, 0xF6 }, .{ 0x02C7, 0xFF }, .{ 0x02D8, 0xF9 },
            .{ 0x02D9, 0xFA }, .{ 0x02DA, 0xFB }, .{ 0x02DB, 0xFE }, .{ 0x02DC, 0xF7 },
            .{ 0x02DD, 0xFD }, .{ 0x03A9, 0xBD }, .{ 0x03C0, 0xB9 }, .{ 0x2013, 0xD0 },
            .{ 0x2014, 0xD1 }, .{ 0x2018, 0xD4 }, .{ 0x2019, 0xD5 }, .{ 0x201A, 0xE2 },
            .{ 0x201C, 0xD2 }, .{ 0x201D, 0xD3 }, .{ 0x201E, 0xE3 }, .{ 0x2020, 0xA0 },
            .{ 0x2021, 0xE0 }, .{ 0x2022, 0xA5 }, .{ 0x2026, 0xC9 }, .{ 0x2030, 0xE4 },
            .{ 0x2039, 0xDC }, .{ 0x203A, 0xDD }, .{ 0x2044, 0xDA }, .{ 0x20AC, 0xDB },
            .{ 0x2122, 0xAA }, .{ 0x2202, 0xB6 }, .{ 0x2206, 0xC6 }, .{ 0x220F, 0xB8 },
            .{ 0x2211, 0xB7 }, .{ 0x221A, 0xC3 }, .{ 0x221E, 0xB0 }, .{ 0x222B, 0xBA },
            .{ 0x2248, 0xC5 }, .{ 0x2260, 0xAD }, .{ 0x2264, 0xB2 }, .{ 0x2265, 0xB3 },
            .{ 0x25CA, 0xD7 }, .{ 0xF8FF, 0xF0 }, .{ 0xFB01, 0xDE }, .{ 0xFB02, 0xDF },
        };

        fn unicodeToMacRoman(codepoint: u21) ?u8 {
            if (codepoint > 0xFFFF) return null;
            const needle: u16 = @intCast(codepoint);
            var lo: usize = 0;
            var hi: usize = mac_roman_from_unicode.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const entry = mac_roman_from_unicode[mid];
                if (entry[0] == needle) return entry[1];
                if (entry[0] < needle) lo = mid + 1 else hi = mid;
            }
            return null;
        }

        pub fn resolve(data: []const u8) ?Resolved {
            const sel = selectSubtable(data) orelse return null;
            return .{ .sub = data[sel.offset..], .format = sel.format, .legacy = sel.legacy, .variations = variationSubtable(data) };
        }

        /// The (platform 0, encoding 5) format 14 subtable, clamped to its
        /// declared length.
        fn variationSubtable(data: []const u8) []const u8 {
            if (data.len < 4) return &.{};
            const num_tables = std.mem.readInt(u16, data[2..][0..2], .big);
            if (4 + @as(u64, num_tables) * 8 > data.len) return &.{};
            for (0..num_tables) |i| {
                const rec_pos = 4 + i * 8;
                const platform_id = std.mem.readInt(u16, data[rec_pos..][0..2], .big);
                const encoding_id = std.mem.readInt(u16, data[rec_pos + 2 ..][0..2], .big);
                if (platform_id != 0 or encoding_id != 5) continue;
                const offset = std.mem.readInt(u32, data[rec_pos + 4 ..][0..4], .big);
                if (@as(u64, offset) + 10 > data.len) return &.{};
                const sub = data[offset..];
                if (std.mem.readInt(u16, sub[0..2], .big) != 14) return &.{};
                const length = std.mem.readInt(u32, sub[2..6], .big);
                return sub[0..@min(length, sub.len)];
            }
            return &.{};
        }

        const Subtable = struct { offset: u32, format: u16, legacy: Resolved.Legacy };

        fn selectSubtable(data: []const u8) ?Subtable {
            if (data.len < 4) return null;
            const num_tables = std.mem.readInt(u16, data[2..][0..2], .big);
            if (4 + @as(u64, num_tables) * 8 > data.len) return null;

            var best_offset: ?u32 = null;
            var best_score: i32 = -1;
            var best_legacy: Resolved.Legacy = .none;
            var i: usize = 0;
            while (i < num_tables) : (i += 1) {
                const rec_pos = 4 + i * 8;
                const platform_id = std.mem.readInt(u16, data[rec_pos..][0..2], .big);
                const encoding_id = std.mem.readInt(u16, data[rec_pos + 2 ..][0..2], .big);
                const offset = std.mem.readInt(u32, data[rec_pos + 4 ..][0..4], .big);
                const score: i32 = switch (platform_id) {
                    3 => switch (encoding_id) {
                        10 => 5,
                        1 => 4,
                        else => 0,
                    },
                    0 => switch (encoding_id) {
                        4, 6 => 5,
                        3 => 3,
                        // Above the Macintosh platform below, which is only
                        // ever a last resort.
                        else => 2,
                    },
                    1 => 1,
                    else => 0,
                };
                if (score > best_score and offset < data.len) {
                    best_score = score;
                    best_offset = offset;
                    best_legacy = if (platform_id != 1)
                        .none
                    else if (encoding_id == 0)
                        .mac_roman
                    else
                        .ascii;
                }
            }
            const subtable_offset = best_offset orelse return null;
            if (subtable_offset + 2 > data.len) return null;
            const format = std.mem.readInt(u16, data[subtable_offset..][0..2], .big);
            return .{ .offset = subtable_offset, .format = format, .legacy = best_legacy };
        }

        /// An inclusive codepoint range with a non-.notdef glyph somewhere
        /// inside it, per `coverageRanges` below.
        pub const Range = struct { start: u21, end: u21 };

        /// Best-effort codepoint coverage of the same subtable `lookup`
        /// would use, for font-fallback "does this font have anything for
        /// this codepoint" checks -- not a substitute for `lookup` itself.
        /// Segment/group boundaries are trusted as-is rather than checking
        /// every codepoint inside a format 4 segment for a glyph-id-0 hole,
        /// same approximation HarfBuzz/Pango fallback consumers make.
        /// Ranges are sorted ascending and non-overlapping. Caller frees
        /// with `alloc`.
        pub fn coverageRanges(data: []const u8, alloc: Allocator) Allocator.Error![]Range {
            const sel = selectSubtable(data) orelse return &.{};
            const sub = data[sel.offset..];
            return switch (sel.format) {
                0 => coverageRangesFormat0(sub, alloc),
                4 => coverageRangesFormat4(sub, alloc),
                6 => coverageRangesTrimmed(sub, alloc, false),
                10 => coverageRangesTrimmed(sub, alloc, true),
                // Format 13 shares format 12's header and group layout; only
                // the glyph a group resolves to differs, which coverage
                // ranges do not record.
                12, 13 => coverageRangesFormat12(sub, alloc),
                else => &.{},
            };
        }

        /// Merged codepoint coverage across a font-fallback stack (multiple
        /// `coverageRanges` outputs, one per candidate font, earlier/lower
        /// index winning any overlap) -- e.g. CSS `font-family: A, B, C`,
        /// resolving which font in the list should render a given
        /// codepoint.
        pub const FallbackStack = struct {
            pub const Coverage = struct { entry_index: u8, range: Range };

            /// Sorted, non-overlapping, built once by `build`.
            coverage: []Coverage = &.{},

            pub fn deinit(self: *FallbackStack, alloc: Allocator) void {
                alloc.free(self.coverage);
                self.* = undefined;
            }

            /// Sweep-line merge of each entry's cmap coverage into one
            /// sorted table, earlier entries (lower index) winning any
            /// overlap. Breakpoints are the union of every range's
            /// start/end+1 across all entries, so the interval between
            /// consecutive breakpoints has a single winner. Runs once per
            /// distinct stack.
            pub fn build(alloc: Allocator, per_entry_ranges: []const []const Range) Allocator.Error!FallbackStack {
                var breakpoints: std.ArrayList(u32) = .empty;
                defer breakpoints.deinit(alloc);
                for (per_entry_ranges) |ranges| {
                    for (ranges) |r| {
                        try breakpoints.append(alloc, r.start);
                        try breakpoints.append(alloc, @as(u32, r.end) + 1);
                    }
                }
                if (breakpoints.items.len == 0) return .{};
                // A CJK face alone contributes ~20k format-12 groups (40k
                // breakpoints), so this needs to be n log n, not insertion sort.
                std.mem.sortUnstable(u32, breakpoints.items, {}, std.sort.asc(u32));

                var uniq: std.ArrayList(u32) = .empty;
                defer uniq.deinit(alloc);
                for (breakpoints.items) |bp| {
                    if (uniq.items.len == 0 or uniq.items[uniq.items.len - 1] != bp) try uniq.append(alloc, bp);
                }

                var out: std.ArrayList(Coverage) = .empty;
                errdefer out.deinit(alloc);
                var k: usize = 0;
                while (k + 1 < uniq.items.len) : (k += 1) {
                    const lo = uniq.items[k];
                    const hi = uniq.items[k + 1]; // exclusive
                    const probe: u21 = @intCast(lo);
                    const winner: ?u8 = for (per_entry_ranges, 0..) |ranges, idx| {
                        if (rangesContain(ranges, probe)) break @intCast(idx);
                    } else null;

                    if (winner) |w| {
                        if (out.items.len > 0 and out.items[out.items.len - 1].entry_index == w and out.items[out.items.len - 1].range.end + 1 == lo) {
                            out.items[out.items.len - 1].range.end = @intCast(hi - 1);
                        } else {
                            try out.append(alloc, .{ .entry_index = w, .range = .{ .start = @intCast(lo), .end = @intCast(hi - 1) } });
                        }
                    }
                }
                return .{ .coverage = try out.toOwnedSlice(alloc) };
            }

            fn rangesContain(ranges: []const Range, cp: u21) bool {
                var lo: usize = 0;
                var hi: usize = ranges.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (cp < ranges[mid].start) {
                        hi = mid;
                    } else if (cp > ranges[mid].end) {
                        lo = mid + 1;
                    } else {
                        return true;
                    }
                }
                return false;
            }

            /// Stack index of the highest-priority entry covering
            /// `codepoint`, or null if nothing in the stack does.
            pub fn entryIndexFor(self: *const FallbackStack, codepoint: u21) ?u8 {
                var lo: usize = 0;
                var hi: usize = self.coverage.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const r = self.coverage[mid].range;
                    if (codepoint < r.start) {
                        hi = mid;
                    } else if (codepoint > r.end) {
                        lo = mid + 1;
                    } else {
                        return self.coverage[mid].entry_index;
                    }
                }
                return null;
            }
        };

        fn coverageRangesFormat0(sub: []const u8, alloc: Allocator) Allocator.Error![]Range {
            var ranges: std.ArrayList(Range) = .empty;
            errdefer ranges.deinit(alloc);
            var cp: u21 = 0;
            while (cp < 256 and 6 + @as(usize, cp) < sub.len) : (cp += 1) {
                if (sub[6 + cp] == 0) continue;
                if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].end + 1 == cp) {
                    ranges.items[ranges.items.len - 1].end = cp;
                } else {
                    try ranges.append(alloc, .{ .start = cp, .end = cp });
                }
            }
            return ranges.toOwnedSlice(alloc);
        }

        fn coverageRangesFormat4(sub: []const u8, alloc: Allocator) Allocator.Error![]Range {
            if (sub.len < 14) return &.{};
            const seg_count_x2 = std.mem.readInt(u16, sub[6..][0..2], .big);
            const seg_count = seg_count_x2 / 2;
            const end_codes_start: usize = 14;
            const start_codes_start = end_codes_start + @as(usize, seg_count_x2) + 2;
            if (start_codes_start + @as(usize, seg_count_x2) > sub.len) return &.{};

            var ranges: std.ArrayList(Range) = .empty;
            errdefer ranges.deinit(alloc);
            var i: usize = 0;
            while (i < seg_count) : (i += 1) {
                const end_code = std.mem.readInt(u16, sub[end_codes_start + i * 2 ..][0..2], .big);
                const start_code = std.mem.readInt(u16, sub[start_codes_start + i * 2 ..][0..2], .big);
                // The mandatory terminator segment is {0xFFFF, 0xFFFF}; a
                // well-formed font has no real coverage there.
                if (start_code > end_code) continue;
                if (start_code == 0xFFFF and end_code == 0xFFFF) continue;
                try ranges.append(alloc, .{ .start = start_code, .end = end_code });
            }
            return ranges.toOwnedSlice(alloc);
        }

        fn coverageRangesTrimmed(sub: []const u8, alloc: Allocator, wide: bool) Allocator.Error![]Range {
            const t = trimmedHeader(sub, wide) orelse return &.{};
            if (t.count == 0) return &.{};
            const last = @min(@as(u64, t.first) + t.count - 1, 0x10FFFF);
            if (t.first > last) return &.{};
            return alloc.dupe(Range, &.{.{ .start = @intCast(t.first), .end = @intCast(last) }});
        }

        fn coverageRangesFormat12(sub: []const u8, alloc: Allocator) Allocator.Error![]Range {
            if (sub.len < 16) return &.{};
            const declared_groups = std.mem.readInt(u32, sub[12..][0..4], .big);
            const usable_groups = @min(declared_groups, (sub.len - 16) / 12);

            const ranges = try alloc.alloc(Range, usable_groups);
            var i: usize = 0;
            while (i < usable_groups) : (i += 1) {
                const pos = 16 + i * 12;
                const start_char = std.mem.readInt(u32, sub[pos..][0..4], .big);
                const end_char = std.mem.readInt(u32, sub[pos + 4 ..][0..4], .big);
                ranges[i] = .{ .start = @intCast(@min(start_char, 0x10FFFF)), .end = @intCast(@min(end_char, 0x10FFFF)) };
            }
            return ranges;
        }

        fn lookupFormat0(sub: []const u8, codepoint: u21) ?u16 {
            if (codepoint >= 256) return null;
            const pos = 6 + @as(usize, codepoint);
            if (pos >= sub.len) return null;
            const glyph = sub[pos];
            return if (glyph == 0) null else glyph;
        }

        fn lookupFormat4(sub: []const u8, codepoint: u21) ?u16 {
            if (codepoint > 0xFFFF or sub.len < 14) return null;
            const seg_count_x2 = std.mem.readInt(u16, sub[6..][0..2], .big);
            const seg_count = seg_count_x2 / 2;
            const end_codes_start: usize = 14;
            const start_codes_start = end_codes_start + @as(usize, seg_count_x2) + 2;
            const id_delta_start = start_codes_start + seg_count_x2;
            const id_range_offset_start = id_delta_start + seg_count_x2;
            if (id_range_offset_start + @as(usize, seg_count_x2) > sub.len) return null;

            // endCode[] is spec-required sorted, so binary search for the
            // first segment ending at or after the codepoint, same as
            // format 12 — format 4 is the more common subtable.
            var lo: usize = 0;
            var hi: usize = seg_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const end_code = std.mem.readInt(u16, sub[end_codes_start + mid * 2 ..][0..2], .big);
                if (end_code < codepoint) lo = mid + 1 else hi = mid;
            }
            const i = lo;
            if (i >= seg_count) return null;

            const start_code = std.mem.readInt(u16, sub[start_codes_start + i * 2 ..][0..2], .big);
            if (codepoint < start_code) return null;
            const id_delta: i16 = std.mem.readInt(i16, sub[id_delta_start + i * 2 ..][0..2], .big);
            const id_range_offset = std.mem.readInt(u16, sub[id_range_offset_start + i * 2 ..][0..2], .big);
            if (id_range_offset == 0) {
                return @truncate(@as(u32, @bitCast(@as(i32, codepoint) + id_delta)));
            }
            const glyph_pos = id_range_offset_start + i * 2 + id_range_offset + (@as(usize, codepoint) - start_code) * 2;
            if (glyph_pos + 2 > sub.len) return null;
            const glyph = std.mem.readInt(u16, sub[glyph_pos..][0..2], .big);
            if (glyph == 0) return null;
            return @truncate(@as(u32, @bitCast(@as(i32, glyph) + id_delta)));
        }

        const TrimmedHeader = struct { first: u32, count: u32, glyphs: usize };

        /// Format 6 (TrimmedTableMapping) and 10 (TrimmedArray): a first
        /// codepoint, an entry count and a dense glyphId array. Same shape
        /// either way; format 10 widens first/count to 32 bits and pads the
        /// header out to 20 bytes.
        fn trimmedHeader(sub: []const u8, wide: bool) ?TrimmedHeader {
            if (wide) {
                if (sub.len < 20) return null;
                return .{
                    .first = std.mem.readInt(u32, sub[12..][0..4], .big),
                    .count = std.mem.readInt(u32, sub[16..][0..4], .big),
                    .glyphs = 20,
                };
            }
            if (sub.len < 10) return null;
            return .{
                .first = std.mem.readInt(u16, sub[6..][0..2], .big),
                .count = std.mem.readInt(u16, sub[8..][0..2], .big),
                .glyphs = 10,
            };
        }

        fn lookupTrimmed(sub: []const u8, codepoint: u21, wide: bool) ?u16 {
            const t = trimmedHeader(sub, wide) orelse return null;
            if (codepoint < t.first) return null;
            const index = @as(u32, codepoint) - t.first;
            if (index >= t.count) return null;
            const pos = t.glyphs + @as(usize, index) * 2;
            if (pos + 2 > sub.len) return null;
            const glyph = std.mem.readInt(u16, sub[pos..][0..2], .big);
            return if (glyph == 0) null else glyph;
        }

        /// Format 12 (SegmentedCoverage) and 13 (ManyToOneRangeMappings):
        /// same groups, but a format-13 group maps its whole range to the
        /// one `glyphID` instead of counting up from `startGlyphID`.
        fn lookupSegmented(sub: []const u8, codepoint: u21, many_to_one: bool) ?u16 {
            if (sub.len < 16) return null;
            const declared_groups = std.mem.readInt(u32, sub[12..][0..4], .big);
            const usable_groups = @min(declared_groups, (sub.len - 16) / 12);

            // NOTE: groups are required sorted by startCharCode per spec, so
            // this can binary search instead of the O(num_groups) scan a
            // naive port would do; num_groups can be in the thousands for
            // CJK-heavy fonts and lookup runs per codepoint.
            var lo: usize = 0;
            var hi: usize = usable_groups;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const pos = 16 + mid * 12;
                const start_char = std.mem.readInt(u32, sub[pos..][0..4], .big);
                const end_char = std.mem.readInt(u32, sub[pos + 4 ..][0..4], .big);
                if (codepoint < start_char) {
                    hi = mid;
                } else if (codepoint > end_char) {
                    lo = mid + 1;
                } else {
                    const start_glyph = std.mem.readInt(u32, sub[pos + 8 ..][0..4], .big);
                    const glyph = if (many_to_one) start_glyph else start_glyph + (codepoint - start_char);
                    if (glyph > 0xFFFF) return null;
                    return @intCast(glyph);
                }
            }
            return null;
        }
    };

    pub const hmtx = struct {
        pub const Metric = struct {
            advance_width: u16,
            left_side_bearing: i16,
        };

        pub fn metricForGlyph(data: []const u8, glyph_id: u16, number_of_h_metrics: u16) Metric {
            const zero: Metric = .{ .advance_width = 0, .left_side_bearing = 0 };
            if (number_of_h_metrics == 0) return zero;
            if (glyph_id < number_of_h_metrics) {
                const pos = @as(usize, glyph_id) * 4;
                if (pos + 4 > data.len) return zero;
                return .{
                    .advance_width = std.mem.readInt(u16, data[pos..][0..2], .big),
                    .left_side_bearing = std.mem.readInt(i16, data[pos + 2 ..][0..2], .big),
                };
            }
            const last_pos = (@as(usize, number_of_h_metrics) - 1) * 4;
            if (last_pos + 4 > data.len) return zero;
            const advance = std.mem.readInt(u16, data[last_pos..][0..2], .big);
            const extra_index = glyph_id - number_of_h_metrics;
            const lsb_pos = @as(usize, number_of_h_metrics) * 4 + @as(usize, extra_index) * 2;
            const lsb = if (lsb_pos + 2 <= data.len) std.mem.readInt(i16, data[lsb_pos..][0..2], .big) else 0;
            return .{ .advance_width = advance, .left_side_bearing = lsb };
        }
    };

    /// Same on-disk layout as `hmtx` (longVerMetric records, then trailing
    /// topSideBearing-only entries), fields renamed for the vertical axis.
    pub const vmtx = struct {
        pub const Metric = struct {
            advance_height: u16,
            top_side_bearing: i16,
        };

        pub fn metricForGlyph(data: []const u8, glyph_id: u16, number_of_long_ver_metrics: u16) Metric {
            const zero: Metric = .{ .advance_height = 0, .top_side_bearing = 0 };
            if (number_of_long_ver_metrics == 0) return zero;
            if (glyph_id < number_of_long_ver_metrics) {
                const pos = @as(usize, glyph_id) * 4;
                if (pos + 4 > data.len) return zero;
                return .{
                    .advance_height = std.mem.readInt(u16, data[pos..][0..2], .big),
                    .top_side_bearing = std.mem.readInt(i16, data[pos + 2 ..][0..2], .big),
                };
            }
            const last_pos = (@as(usize, number_of_long_ver_metrics) - 1) * 4;
            if (last_pos + 4 > data.len) return zero;
            const advance = std.mem.readInt(u16, data[last_pos..][0..2], .big);
            const extra_index = glyph_id - number_of_long_ver_metrics;
            const tsb_pos = @as(usize, number_of_long_ver_metrics) * 4 + @as(usize, extra_index) * 2;
            const tsb = if (tsb_pos + 2 <= data.len) std.mem.readInt(i16, data[tsb_pos..][0..2], .big) else 0;
            return .{ .advance_height = advance, .top_side_bearing = tsb };
        }
    };

    /// Variable-font advance-width deltas. Ported from swash's
    /// `internal::var::{metric_delta, item_delta}` (which HVAR shares its
    /// ItemVariationStore format with MVAR/VVAR). Only the advance-width
    /// mapping is read (`hmtx.metricForGlyph`'s counterpart); lsb/rsb
    /// mappings aren't needed since nothing here reports side bearings
    /// separately from the outline itself.
    pub const HVAR = struct {
        pub fn advanceWidthDelta(data: []const u8, glyph_id: u16, normalized_coords: []const f32, scalars: ?*const RegionScalars) f32 {
            if (data.len < 8) return 0;
            const item_variation_store_offset = std.mem.readInt(u32, data[4..][0..4], .big);
            if (item_variation_store_offset == 0 or item_variation_store_offset >= data.len) return 0;

            var outer: u16 = 0;
            var inner: u16 = glyph_id;
            if (data.len >= 12) {
                const advance_width_mapping_offset = std.mem.readInt(u32, data[8..][0..4], .big);
                if (advance_width_mapping_offset != 0) {
                    const mapped = deltaSetIndexMapLookup(data, advance_width_mapping_offset, glyph_id) orelse return 0;
                    outer = mapped.outer;
                    inner = mapped.inner;
                }
            }
            return itemDeltaCached(data, item_variation_store_offset, outer, inner, normalized_coords, scalars);
        }

        const MapEntry = struct { outer: u16, inner: u16 };

        fn deltaSetIndexMapLookup(data: []const u8, offset: u32, glyph_id: u16) ?MapEntry {
            if (@as(u64, offset) + 4 > data.len) return null;
            const format = data[offset];
            const entry_format = data[offset + 1];
            const width: usize = ((entry_format >> 4) & 3) + 1;
            const inner_bit_count: u5 = @intCast((entry_format & 0xF) + 1);

            const map_count_field_size: usize = if (format == 0) 2 else 4;
            const map_data_offset = offset + 2 + map_count_field_size;
            if (@as(u64, offset) + 2 + map_count_field_size > data.len) return null;
            const map_count: u32 = if (format == 0)
                std.mem.readInt(u16, data[offset + 2 ..][0..2], .big)
            else
                std.mem.readInt(u32, data[offset + 2 ..][0..4], .big);
            if (map_count == 0) return .{ .outer = 0, .inner = glyph_id };

            const index: u32 = if (glyph_id >= map_count) map_count - 1 else glyph_id;
            const entry_pos = @as(u64, map_data_offset) + @as(u64, index) * width;
            if (entry_pos + width > data.len) return null;

            var raw: u32 = 0;
            var i: usize = 0;
            while (i < width) : (i += 1) raw = (raw << 8) | data[@intCast(entry_pos + i)];

            return .{ .outer = @intCast(raw >> inner_bit_count), .inner = @intCast(raw & ((@as(u32, 1) << inner_bit_count) - 1)) };
        }

        /// hb's `hb_scalar_cache`: the region scalars depend only on the
        /// region list and the coords, so a caller shaping many glyphs at one
        /// instance evaluates them once instead of per item.
        pub const RegionScalars = struct {
            // ponytail: real fonts stay well under this; beyond it `itemDelta`
            // just falls back to evaluating each scalar inline as before.
            const max_regions = 256;
            values: [max_regions]f32 = undefined,
            len: u16 = 0,

            pub fn init(data: []const u8, store_offset: u32, normalized_coords: []const f32) RegionScalars {
                var self: RegionScalars = .{};
                const store = store_offset;
                if (@as(u64, store) + 8 > data.len) return self;
                const region_list_offset = offsetWithin(data, @as(u64, store) + std.mem.readInt(u32, data[store + 2 ..][0..4], .big), 4) orelse return self;
                const axis_count = std.mem.readInt(u16, data[region_list_offset..][0..2], .big);
                const region_count = std.mem.readInt(u16, data[region_list_offset + 2 ..][0..2], .big);
                if (region_count > max_regions) return self;
                for (0..region_count) |i| {
                    self.values[i] = regionScalar(data, region_list_offset, axis_count, @intCast(i), normalized_coords);
                }
                self.len = region_count;
                return self;
            }
        };

        /// One VarRegionAxis::evaluate product, on F2Dot14 integers so the
        /// float rounding (and thus the rounded delta) matches hb's.
        fn regionScalar(data: []const u8, region_list_offset: usize, axis_count: u16, region_index: u16, normalized_coords: []const f32) f32 {
            const region_record_size = @as(usize, axis_count) * 6;
            const region_offset = region_list_offset + 4 + @as(usize, region_index) * region_record_size;
            var scalar: f32 = 1.0;
            var axis: usize = 0;
            while (axis < axis_count) : (axis += 1) {
                const region_axis_base = region_offset + axis * 6;
                if (region_axis_base + 6 > data.len) return 0;
                const start: i32 = std.mem.readInt(i16, data[region_axis_base..][0..2], .big);
                const peak: i32 = std.mem.readInt(i16, data[region_axis_base + 2 ..][0..2], .big);
                const end: i32 = std.mem.readInt(i16, data[region_axis_base + 4 ..][0..2], .big);
                const coord: i32 = if (axis < normalized_coords.len) @intFromFloat(@round(normalized_coords[axis] * 16384.0)) else 0;

                if (peak == 0 or coord == peak) continue;
                if (coord == 0) return 0;
                if (start > peak or peak > end or (start < 0 and end > 0)) continue;
                if (coord <= start or end <= coord) return 0;
                const factor = if (coord < peak)
                    @as(f32, @floatFromInt(coord - start)) / @as(f32, @floatFromInt(peak - start))
                else
                    @as(f32, @floatFromInt(end - coord)) / @as(f32, @floatFromInt(end - peak));
                scalar *= factor;
            }
            return scalar;
        }

        /// Also GDEF's ItemVariationStore (GPOS VariationIndex deltas).
        pub fn itemDelta(data: []const u8, store_offset: u32, outer: u16, inner: u16, normalized_coords: []const f32) f32 {
            return itemDeltaCached(data, store_offset, outer, inner, normalized_coords, null);
        }

        pub fn itemDeltaCached(data: []const u8, store_offset: u32, outer: u16, inner: u16, normalized_coords: []const f32, scalars: ?*const RegionScalars) f32 {
            const store = store_offset;
            if (@as(u64, store) + 8 > data.len) return 0;
            const region_list_offset = offsetWithin(data, @as(u64, store) + std.mem.readInt(u32, data[store + 2 ..][0..4], .big), 4) orelse return 0;
            const data_count = std.mem.readInt(u16, data[store + 6 ..][0..2], .big);
            if (outer >= data_count) return 0;

            const axis_count = std.mem.readInt(u16, data[region_list_offset..][0..2], .big);
            const region_count = std.mem.readInt(u16, data[region_list_offset + 2 ..][0..2], .big);

            const data_offset_pos = @as(u64, store) + 8 + @as(u64, outer) * 4;
            if (data_offset_pos + 4 > data.len) return 0;
            const item_data_base = offsetWithin(data, @as(u64, store) + std.mem.readInt(u32, data[@intCast(data_offset_pos)..][0..4], .big), 6) orelse return 0;

            const short_count = std.mem.readInt(u16, data[item_data_base + 2 ..][0..2], .big);
            const region_index_count = std.mem.readInt(u16, data[item_data_base + 4 ..][0..2], .big);
            // Spec requires wordDeltaCount <= regionIndexCount; a font that
            // violates it would underflow the row-stride math below.
            if (short_count > region_index_count) return 0;

            const region_index_base = item_data_base + 6;
            const elem_len = (@as(usize, region_index_count) - short_count) + @as(usize, short_count) * 2;
            const row_base = region_index_base + @as(usize, region_index_count) * 2;
            var delta_pos = row_base + @as(usize, inner) * elem_len;
            if (delta_pos + elem_len > data.len) return 0;

            var delta: f32 = 0;
            var idx: usize = 0;
            while (idx < region_index_count) : (idx += 1) {
                if (@as(u64, region_index_base) + @as(u64, idx) * 2 + 2 > data.len) return 0;
                const region_index = std.mem.readInt(u16, data[region_index_base + idx * 2 ..][0..2], .big);
                if (region_index >= region_count) return 0;

                const scalar = if (scalars) |sc|
                    (if (region_index < sc.len) sc.values[region_index] else regionScalar(data, region_list_offset, axis_count, region_index, normalized_coords))
                else
                    regionScalar(data, region_list_offset, axis_count, region_index, normalized_coords);

                const val: i16 = if (idx >= short_count) blk: {
                    const v: i8 = @bitCast(data[delta_pos]);
                    delta_pos += 1;
                    break :blk v;
                } else blk: {
                    const v = std.mem.readInt(i16, data[delta_pos..][0..2], .big);
                    delta_pos += 2;
                    break :blk v;
                };
                delta += scalar * @as(f32, @floatFromInt(val));
            }
            return delta;
        }
    };

    pub const glyf = struct {
        pub const Point = struct {
            x: i16,
            y: i16,
            on_curve: bool,
        };

        pub const Outline = struct {
            number_of_contours: i16,
            end_points_of_contours: []const u16,
            points: []const Point,
            /// Borrowed from `glyf_data`/`glyf_data`-derived buffers — not
            /// owned, unlike `points`/`end_points_of_contours`.
            instructions: []const u8 = &.{},
        };

        pub fn outline(
            alloc: Allocator,
            glyf_data: []const u8,
            loca_data: []const u8,
            index_to_loc_format: i16,
            glyph_id: u16,
        ) (Font.ParseError || error{OutOfMemory})!Outline {
            var loads: u32 = 0;
            return outlineRecursive(alloc, glyf_data, loca_data, index_to_loc_format, glyph_id, 0, &loads);
        }

        const empty: Outline = .{ .number_of_contours = 0, .end_points_of_contours = &.{}, .points = &.{} };

        /// Composite components fan out as well as nest, so the depth cap
        /// alone leaves the work exponential in depth (64 components eight
        /// levels deep is 64^8 decodes). Budget total glyph decodes too;
        /// real composites use single-digit components, two or three deep.
        const max_glyph_loads: u32 = 1024;

        fn spendLoad(loads: *u32) Font.ParseError!void {
            if (loads.* >= max_glyph_loads) return error.RecursionLimitExceeded;
            loads.* += 1;
        }

        fn locaBounds(loca_data: []const u8, index_to_loc_format: i16, glyph_id: u16) Font.ParseError!struct { start: u32, end: u32 } {
            if (index_to_loc_format == 0) {
                const pos = @as(usize, glyph_id) * 2;
                if (pos + 4 > loca_data.len) return error.UnexpectedEndOfData;
                const o1 = std.mem.readInt(u16, loca_data[pos..][0..2], .big);
                const o2 = std.mem.readInt(u16, loca_data[pos + 2 ..][0..2], .big);
                return .{ .start = @as(u32, o1) * 2, .end = @as(u32, o2) * 2 };
            }
            const pos = @as(usize, glyph_id) * 4;
            if (pos + 8 > loca_data.len) return error.UnexpectedEndOfData;
            return .{
                .start = std.mem.readInt(u32, loca_data[pos..][0..4], .big),
                .end = std.mem.readInt(u32, loca_data[pos + 4 ..][0..4], .big),
            };
        }

        pub const HeaderBounds = struct { number_of_contours: i16, x_min: i16, y_min: i16, x_max: i16, y_max: i16 };

        /// Reads a glyph's 10-byte glyf header directly (no outline
        /// decode) — `numberOfContours`/`xMin`/`yMin`/`xMax`/`yMax` are
        /// stored verbatim there. Used by sbix's fallback-outline bearing
        /// adjustment (`ttgload.c`'s "special treatment" for sbix glyphs
        /// that also carry a glyf contour), which only needs these bbox
        /// fields, not the full point list. Returns `null` for an empty
        /// glyph (e.g. space).
        pub fn headerBounds(glyf_data: []const u8, loca_data: []const u8, index_to_loc_format: i16, glyph_id: u16) Font.ParseError!?HeaderBounds {
            const bounds = try locaBounds(loca_data, index_to_loc_format, glyph_id);
            if (bounds.start > bounds.end or bounds.end > glyf_data.len) return error.InvalidTableFormat;
            if (bounds.start == bounds.end) return null;

            var cursor = Cursor{ .data = glyf_data[bounds.start..bounds.end] };
            const number_of_contours = try cursor.readI16();
            return .{
                .number_of_contours = number_of_contours,
                .x_min = try cursor.readI16(),
                .y_min = try cursor.readI16(),
                .x_max = try cursor.readI16(),
                .y_max = try cursor.readI16(),
            };
        }

        fn outlineRecursive(
            alloc: Allocator,
            glyf_data: []const u8,
            loca_data: []const u8,
            index_to_loc_format: i16,
            glyph_id: u16,
            depth: u32,
            loads: *u32,
        ) (Font.ParseError || error{OutOfMemory})!Outline {
            if (depth > 8) return error.RecursionLimitExceeded;
            try spendLoad(loads);
            const bounds = try locaBounds(loca_data, index_to_loc_format, glyph_id);
            if (bounds.start > bounds.end or bounds.end > glyf_data.len) return error.InvalidTableFormat;
            if (bounds.start == bounds.end) return empty;

            var cursor = Cursor{ .data = glyf_data[bounds.start..bounds.end] };
            const number_of_contours = try cursor.readI16();
            try cursor.skip(8);
            if (number_of_contours >= 0) return decodeSimpleGlyph(alloc, &cursor, number_of_contours);
            return decodeCompositeGlyph(alloc, glyf_data, loca_data, index_to_loc_format, &cursor, depth, loads);
        }

        fn decodeSimpleGlyph(alloc: Allocator, cursor: *Cursor, number_of_contours: i16) (Font.ParseError || error{OutOfMemory})!Outline {
            const nc: usize = @intCast(number_of_contours);
            const end_pts = try alloc.alloc(u16, nc);
            errdefer alloc.free(end_pts);
            // Spec requires strictly-increasing end points (every contour has at
            // least one point); consumers index contour ranges off these without
            // re-checking, so reject non-monotonic entries here.
            for (end_pts, 0..) |*e, i| {
                e.* = try cursor.readU16();
                if (i > 0 and e.* <= end_pts[i - 1]) return error.InvalidTableFormat;
            }
            const num_points: usize = if (nc == 0) 0 else @as(usize, end_pts[nc - 1]) + 1;

            const instruction_length = try cursor.readU16();
            const instructions = try cursor.readBytes(instruction_length);

            const flags = try alloc.alloc(u8, num_points);
            defer alloc.free(flags);
            {
                var i: usize = 0;
                while (i < num_points) {
                    const f = try cursor.readU8();
                    flags[i] = f;
                    i += 1;
                    if (f & 0x08 != 0) {
                        const repeat = try cursor.readU8();
                        var r: usize = 0;
                        while (r < repeat and i < num_points) : (r += 1) {
                            flags[i] = f;
                            i += 1;
                        }
                    }
                }
            }

            const points = try alloc.alloc(Point, num_points);
            errdefer alloc.free(points);
            var x: i32 = 0;
            for (points, 0..) |*p, i| {
                const f = flags[i];
                if (f & 0x02 != 0) {
                    const dx = try cursor.readU8();
                    x += if (f & 0x10 != 0) @as(i32, dx) else -@as(i32, dx);
                } else if (f & 0x10 == 0) {
                    x += try cursor.readI16();
                }
                p.* = .{ .x = clampToI16(x), .y = 0, .on_curve = (f & 0x01) != 0 };
            }
            var y: i32 = 0;
            for (points, 0..) |*p, i| {
                const f = flags[i];
                if (f & 0x04 != 0) {
                    const dy = try cursor.readU8();
                    y += if (f & 0x20 != 0) @as(i32, dy) else -@as(i32, dy);
                } else if (f & 0x20 == 0) {
                    y += try cursor.readI16();
                }
                p.y = clampToI16(y);
            }

            return .{
                .number_of_contours = number_of_contours,
                .end_points_of_contours = end_pts,
                .points = points,
                .instructions = instructions,
            };
        }

        fn decodeCompositeGlyph(
            alloc: Allocator,
            glyf_data: []const u8,
            loca_data: []const u8,
            index_to_loc_format: i16,
            cursor: *Cursor,
            depth: u32,
            loads: *u32,
        ) (Font.ParseError || error{OutOfMemory})!Outline {
            var points_list: std.ArrayList(Point) = .empty;
            defer points_list.deinit(alloc);
            var ends_list: std.ArrayList(u16) = .empty;
            defer ends_list.deinit(alloc);

            var more = true;
            var last_flags: u16 = 0;
            while (more) {
                const flags = try cursor.readU16();
                const glyph_index = try cursor.readU16();
                var arg1: f64 = 0;
                var arg2: f64 = 0;
                const args_are_words = flags & 0x0001 != 0;
                const args_are_xy = flags & 0x0002 != 0;
                if (args_are_words) {
                    if (args_are_xy) {
                        arg1 = @floatFromInt(try cursor.readI16());
                        arg2 = @floatFromInt(try cursor.readI16());
                    } else {
                        _ = try cursor.readU16();
                        _ = try cursor.readU16();
                    }
                } else {
                    if (args_are_xy) {
                        arg1 = @floatFromInt(try cursor.readI8());
                        arg2 = @floatFromInt(try cursor.readI8());
                    } else {
                        _ = try cursor.readU8();
                        _ = try cursor.readU8();
                    }
                }

                var xx: f64 = 1;
                var xy: f64 = 0;
                var yx: f64 = 0;
                var yy: f64 = 1;
                if (flags & 0x0008 != 0) {
                    xx = f2dot14(try cursor.readI16());
                    yy = xx;
                } else if (flags & 0x0040 != 0) {
                    xx = f2dot14(try cursor.readI16());
                    yy = f2dot14(try cursor.readI16());
                } else if (flags & 0x0080 != 0) {
                    xx = f2dot14(try cursor.readI16());
                    yx = f2dot14(try cursor.readI16());
                    xy = f2dot14(try cursor.readI16());
                    yy = f2dot14(try cursor.readI16());
                }

                // NOTE: point-matching composite args (ARGS_ARE_XY_VALUES
                // unset) are rare/deprecated; treated as a zero offset
                // rather than resolving the matched-point anchor.
                const dx: f64 = if (args_are_xy) arg1 else 0;
                const dy: f64 = if (args_are_xy) arg2 else 0;

                const component = try outlineRecursive(alloc, glyf_data, loca_data, index_to_loc_format, glyph_index, depth + 1, loads);
                defer alloc.free(component.points);
                defer alloc.free(component.end_points_of_contours);

                if (points_list.items.len + component.points.len > std.math.maxInt(u16))
                    return error.InvalidTableFormat;
                const base_point_count: u16 = @intCast(points_list.items.len);
                for (component.points) |p| {
                    const px: f64 = @floatFromInt(p.x);
                    const py: f64 = @floatFromInt(p.y);
                    const nx = xx * px + xy * py + dx;
                    const ny = yx * px + yy * py + dy;
                    points_list.append(alloc, .{
                        .x = clampToI16(@intFromFloat(@round(nx))),
                        .y = clampToI16(@intFromFloat(@round(ny))),
                        .on_curve = p.on_curve,
                    }) catch return error.OutOfMemory;
                }
                try appendShiftedEnds(alloc, &ends_list, component.end_points_of_contours, base_point_count);

                more = (flags & 0x0020) != 0;
                last_flags = flags;
            }

            var instructions: []const u8 = &.{};
            if (last_flags & 0x0100 != 0) {
                const instruction_length = try cursor.readU16();
                instructions = try cursor.readBytes(instruction_length);
            }

            const ends = ends_list.toOwnedSlice(alloc) catch return error.OutOfMemory;
            errdefer alloc.free(ends);
            return .{
                .number_of_contours = -1,
                .end_points_of_contours = ends,
                .points = points_list.toOwnedSlice(alloc) catch return error.OutOfMemory,
                .instructions = instructions,
            };
        }

        fn clampToI16(v: i32) i16 {
            return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
        }

        /// Rebases a component's contour ends onto the flattened point list.
        /// `e` is raw font data, so the sum can leave u16 even though the
        /// flattened point count itself is capped.
        fn appendShiftedEnds(
            alloc: Allocator,
            list: *std.ArrayList(u16),
            ends: []const u16,
            base: u16,
        ) (Font.ParseError || error{OutOfMemory})!void {
            for (ends) |e| {
                const shifted = @as(u32, e) + base;
                if (shifted > std.math.maxInt(u16)) return error.InvalidTableFormat;
                list.append(alloc, @intCast(shifted)) catch return error.OutOfMemory;
            }
        }

        fn f2dot14(v: i16) f64 {
            return @as(f64, @floatFromInt(v)) / 16384.0;
        }

        pub const ComponentHeader = struct {
            glyph_index: u16,
            more: bool,
            args_are_xy: bool,
            arg1: f64,
            arg2: f64,
            xx: f64,
            xy: f64,
            yx: f64,
            yy: f64,
            has_scale: bool,
            round_xy_to_grid: bool,
            scaled_component_offset: bool,
            use_my_metrics: bool,
            we_have_instructions: bool,
        };

        fn readComponentHeader(cursor: *Cursor) Font.ParseError!ComponentHeader {
            const flags = try cursor.readU16();
            const glyph_index = try cursor.readU16();
            var arg1: f64 = 0;
            var arg2: f64 = 0;
            const args_are_words = flags & 0x0001 != 0;
            const args_are_xy = flags & 0x0002 != 0;
            if (args_are_words) {
                if (args_are_xy) {
                    arg1 = @floatFromInt(try cursor.readI16());
                    arg2 = @floatFromInt(try cursor.readI16());
                } else {
                    _ = try cursor.readU16();
                    _ = try cursor.readU16();
                }
            } else {
                if (args_are_xy) {
                    arg1 = @floatFromInt(try cursor.readI8());
                    arg2 = @floatFromInt(try cursor.readI8());
                } else {
                    _ = try cursor.readU8();
                    _ = try cursor.readU8();
                }
            }

            var xx: f64 = 1;
            var xy: f64 = 0;
            var yx: f64 = 0;
            var yy: f64 = 1;
            const has_scale = (flags & (0x0008 | 0x0040 | 0x0080)) != 0;
            if (flags & 0x0008 != 0) {
                xx = f2dot14(try cursor.readI16());
                yy = xx;
            } else if (flags & 0x0040 != 0) {
                xx = f2dot14(try cursor.readI16());
                yy = f2dot14(try cursor.readI16());
            } else if (flags & 0x0080 != 0) {
                xx = f2dot14(try cursor.readI16());
                yx = f2dot14(try cursor.readI16());
                xy = f2dot14(try cursor.readI16());
                yy = f2dot14(try cursor.readI16());
            }

            return .{
                .glyph_index = glyph_index,
                .more = (flags & 0x0020) != 0,
                .args_are_xy = args_are_xy,
                .arg1 = arg1,
                .arg2 = arg2,
                .xx = xx,
                .xy = xy,
                .yx = yx,
                .yy = yy,
                .has_scale = has_scale,
                .round_xy_to_grid = (flags & 0x0004) != 0,
                .scaled_component_offset = (flags & 0x0800) != 0,
                .use_my_metrics = (flags & 0x0200) != 0,
                .we_have_instructions = (flags & 0x0100) != 0,
            };
        }

        /// Reads one glyph's data without recursing into composite
        /// components or flattening them — the per-component boundary
        /// `outline`/`outlineRecursive` erase is exactly what hinted
        /// composite rendering needs, since TrueType hinting instructions
        /// run per-component before the components are combined (see
        /// `rasterizeGlyfHinted` in rasterization.zig). `simple` carries the
        /// glyph's own (unflattened, unscaled) points and instructions,
        /// identical to what `outlineRecursive` would decode for a leaf
        /// glyph. `composite` carries the raw component headers (still in
        /// font-unit offsets / F2Dot14 transform) plus the composite's own
        /// trailing instructions, if any.
        pub const GlyphData = union(enum) {
            empty,
            simple: Outline,
            composite: struct {
                components: []const ComponentHeader,
                instructions: []const u8,
            },
        };

        pub fn readGlyph(
            alloc: Allocator,
            glyf_data: []const u8,
            loca_data: []const u8,
            index_to_loc_format: i16,
            glyph_id: u16,
        ) (Font.ParseError || error{OutOfMemory})!GlyphData {
            const bounds = try locaBounds(loca_data, index_to_loc_format, glyph_id);
            if (bounds.start > bounds.end or bounds.end > glyf_data.len) return error.InvalidTableFormat;
            if (bounds.start == bounds.end) return .empty;

            var cursor = Cursor{ .data = glyf_data[bounds.start..bounds.end] };
            const number_of_contours = try cursor.readI16();
            try cursor.skip(8);
            if (number_of_contours >= 0)
                return .{ .simple = try decodeSimpleGlyph(alloc, &cursor, number_of_contours) };

            var list: std.ArrayList(ComponentHeader) = .empty;
            errdefer list.deinit(alloc);
            var more = true;
            var last_flags_have_instructions = false;
            while (more) {
                const h = try readComponentHeader(&cursor);
                list.append(alloc, h) catch return error.OutOfMemory;
                more = h.more;
                last_flags_have_instructions = h.we_have_instructions;
            }

            var instructions: []const u8 = &.{};
            if (last_flags_have_instructions) {
                const instruction_length = try cursor.readU16();
                instructions = try cursor.readBytes(instruction_length);
            }

            return .{ .composite = .{
                .components = list.toOwnedSlice(alloc) catch return error.OutOfMemory,
                .instructions = instructions,
            } };
        }

        pub fn freeGlyphData(alloc: Allocator, data: GlyphData) void {
            switch (data) {
                .empty => {},
                .simple => |o| {
                    alloc.free(o.points);
                    alloc.free(o.end_points_of_contours);
                },
                .composite => |c| alloc.free(c.components),
            }
        }

        // Variable-font counterpart of `outline`: applies `gvar` tuple-variation
        // deltas (with IUP inference for points the font doesn't cover
        // explicitly) at every recursion level, including composite component
        // offsets, before combining. `normalized_coords` are per-axis values in
        // [-1, 1], in `gvar`'s axis order (`fvar` order), already passed through
        // `avar` remapping by the caller.
        pub fn outlineVaried(
            alloc: Allocator,
            glyf_data: []const u8,
            loca_data: []const u8,
            index_to_loc_format: i16,
            hmtx_data: []const u8,
            number_of_h_metrics: u16,
            gvar_header: gvar.Header,
            gvar_data: []const u8,
            glyph_id: u16,
            normalized_coords: []const f32,
        ) (Font.ParseError || error{OutOfMemory})!Outline {
            var loads: u32 = 0;
            return outlineVariedRecursive(
                alloc,
                glyf_data,
                loca_data,
                index_to_loc_format,
                hmtx_data,
                number_of_h_metrics,
                gvar_header,
                gvar_data,
                glyph_id,
                normalized_coords,
                0,
                &loads,
            );
        }

        fn outlineVariedRecursive(
            alloc: Allocator,
            glyf_data: []const u8,
            loca_data: []const u8,
            index_to_loc_format: i16,
            hmtx_data: []const u8,
            number_of_h_metrics: u16,
            gvar_header: gvar.Header,
            gvar_data: []const u8,
            glyph_id: u16,
            normalized_coords: []const f32,
            depth: u32,
            loads: *u32,
        ) (Font.ParseError || error{OutOfMemory})!Outline {
            if (depth > 8) return error.RecursionLimitExceeded;
            try spendLoad(loads);
            const bounds = try locaBounds(loca_data, index_to_loc_format, glyph_id);
            if (bounds.start > bounds.end or bounds.end > glyf_data.len) return error.InvalidTableFormat;
            if (bounds.start == bounds.end) return empty;

            var cursor = Cursor{ .data = glyf_data[bounds.start..bounds.end] };
            const number_of_contours = try cursor.readI16();
            const x_min = try cursor.readI16();
            try cursor.skip(6);

            // NOTE: only horizontal phantom points (pp1, pp2) are populated
            // from hmtx; vertical phantom points (pp3, pp4) need vmtx, which
            // isn't wired in here yet, so they stay at the origin. Any gvar
            // tuple whose deltas target them (rare; relevant to vertical
            // writing mode metrics variation, not outline shape) is inert
            // until vmtx support lands.
            const metric = hmtx.metricForGlyph(hmtx_data, glyph_id, number_of_h_metrics);
            const pp1x: f64 = @floatFromInt(@as(i32, x_min) - @as(i32, metric.left_side_bearing));
            const pp2x: f64 = pp1x + @as(f64, @floatFromInt(metric.advance_width));

            const variation_data = gvar.glyphVariationData(gvar_header, gvar_data, glyph_id);

            if (number_of_contours >= 0) {
                const raw = try decodeSimpleGlyph(alloc, &cursor, number_of_contours);
                defer alloc.free(raw.points);

                const n_real = raw.points.len;
                const extended = try alloc.alloc(gvar.Point2, n_real + 4);
                defer alloc.free(extended);
                for (extended[0..n_real], raw.points) |*e, p|
                    e.* = .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
                extended[n_real] = .{ .x = pp1x, .y = 0 };
                extended[n_real + 1] = .{ .x = pp2x, .y = 0 };
                extended[n_real + 2] = .{ .x = 0, .y = 0 };
                extended[n_real + 3] = .{ .x = 0, .y = 0 };

                if (variation_data.len != 0) {
                    try gvar.applyDeltas(alloc, gvar_header, variation_data, extended, raw.end_points_of_contours, normalized_coords);
                }

                const points = try alloc.alloc(Point, n_real);
                for (points, extended[0..n_real], raw.points) |*out, e, orig| {
                    out.* = .{
                        .x = clampToI16(@intFromFloat(@round(e.x))),
                        .y = clampToI16(@intFromFloat(@round(e.y))),
                        .on_curve = orig.on_curve,
                    };
                }
                return .{ .number_of_contours = number_of_contours, .end_points_of_contours = raw.end_points_of_contours, .points = points };
            }

            return decodeCompositeGlyphVaried(
                alloc,
                glyf_data,
                loca_data,
                index_to_loc_format,
                hmtx_data,
                number_of_h_metrics,
                gvar_header,
                gvar_data,
                &cursor,
                pp1x,
                pp2x,
                variation_data,
                normalized_coords,
                depth,
                loads,
            );
        }

        fn decodeCompositeGlyphVaried(
            alloc: Allocator,
            glyf_data: []const u8,
            loca_data: []const u8,
            index_to_loc_format: i16,
            hmtx_data: []const u8,
            number_of_h_metrics: u16,
            gvar_header: gvar.Header,
            gvar_data: []const u8,
            cursor: *Cursor,
            pp1x: f64,
            pp2x: f64,
            variation_data: []const u8,
            normalized_coords: []const f32,
            depth: u32,
            loads: *u32,
        ) (Font.ParseError || error{OutOfMemory})!Outline {
            var headers: std.ArrayList(ComponentHeader) = .empty;
            defer headers.deinit(alloc);

            var more = true;
            while (more) {
                const h = try readComponentHeader(cursor);
                headers.append(alloc, h) catch return error.OutOfMemory;
                more = h.more;
            }

            // Per gvar, a composite glyph's own point space is one pseudo-point
            // per component (its dx, dy offset) plus 4 phantom points; deltas
            // apply to those offsets directly. Uncovered pseudo-points get no
            // IUP inference (no contour structure to interpolate along), which
            // falls out here for free since `applyDeltas` is passed no contours.
            const n = headers.items.len;
            const extended = try alloc.alloc(gvar.Point2, n + 4);
            defer alloc.free(extended);
            for (extended[0..n], headers.items) |*e, h| e.* = .{ .x = h.arg1, .y = h.arg2 };
            extended[n] = .{ .x = pp1x, .y = 0 };
            extended[n + 1] = .{ .x = pp2x, .y = 0 };
            extended[n + 2] = .{ .x = 0, .y = 0 };
            extended[n + 3] = .{ .x = 0, .y = 0 };

            if (variation_data.len != 0) {
                try gvar.applyDeltas(alloc, gvar_header, variation_data, extended, &.{}, normalized_coords);
            }

            var points_list: std.ArrayList(Point) = .empty;
            defer points_list.deinit(alloc);
            var ends_list: std.ArrayList(u16) = .empty;
            defer ends_list.deinit(alloc);

            for (headers.items, 0..) |h, i| {
                // NOTE: point-matching composite args (ARGS_ARE_XY_VALUES
                // unset) are rare/deprecated; treated as a zero offset here
                // too, matching `decodeCompositeGlyph`.
                const dx = if (h.args_are_xy) extended[i].x else 0;
                const dy = if (h.args_are_xy) extended[i].y else 0;

                const component = try outlineVariedRecursive(
                    alloc,
                    glyf_data,
                    loca_data,
                    index_to_loc_format,
                    hmtx_data,
                    number_of_h_metrics,
                    gvar_header,
                    gvar_data,
                    h.glyph_index,
                    normalized_coords,
                    depth + 1,
                    loads,
                );
                defer alloc.free(component.points);
                defer alloc.free(component.end_points_of_contours);

                if (points_list.items.len + component.points.len > std.math.maxInt(u16))
                    return error.InvalidTableFormat;
                const base_point_count: u16 = @intCast(points_list.items.len);
                for (component.points) |p| {
                    const px: f64 = @floatFromInt(p.x);
                    const py: f64 = @floatFromInt(p.y);
                    const nx = h.xx * px + h.xy * py + dx;
                    const ny = h.yx * px + h.yy * py + dy;
                    points_list.append(alloc, .{
                        .x = clampToI16(@intFromFloat(@round(nx))),
                        .y = clampToI16(@intFromFloat(@round(ny))),
                        .on_curve = p.on_curve,
                    }) catch return error.OutOfMemory;
                }
                try appendShiftedEnds(alloc, &ends_list, component.end_points_of_contours, base_point_count);
            }

            const ends = ends_list.toOwnedSlice(alloc) catch return error.OutOfMemory;
            errdefer alloc.free(ends);
            return .{
                .number_of_contours = -1,
                .end_points_of_contours = ends,
                .points = points_list.toOwnedSlice(alloc) catch return error.OutOfMemory,
            };
        }
    };

    // Tuple Variation Store deltas for `glyf` outlines: per-glyph point
    // movements across the variation-axis design space. Ported from
    // FreeType's `TT_Vary_Apply_Glyph_Deltas`/`ft_var_apply_tuple` (and the
    // shared/private packed point and packed delta readers feeding it) in
    // `vendor/freetype/src/truetype/ttgxvar.c`. Math is done in plain f64
    // rather than FreeType's 16.16 fixed-point — this isn't a hinting VM
    // where bit-exact fixed-point matters, and f64 has ample precision for
    // outline-scale deltas.
    pub const gvar = struct {
        pub const Point2 = struct { x: f64, y: f64 };

        pub const Header = struct {
            axis_count: u16,
            glyph_count: u16,
            glyph_offsets: []const u32,
            shared_tuple_count: u16,
            shared_tuples: []const f32,
        };

        const tuples_share_point_numbers: u16 = 0x8000;
        const tuple_count_mask: u16 = 0x0FFF;
        const embedded_tuple_coord: u16 = 0x8000;
        const intermediate_tuple: u16 = 0x4000;
        const private_point_numbers: u16 = 0x2000;
        const tuple_index_mask: u16 = 0x0FFF;

        pub fn parseHeader(alloc: Allocator, data: []const u8) (Font.ParseError || error{OutOfMemory})!Header {
            if (data.len < 20) return error.InvalidTableFormat;
            const major_version = std.mem.readInt(u16, data[0..2], .big);
            if (major_version != 1) return error.InvalidTableFormat;
            const axis_count = std.mem.readInt(u16, data[4..][0..2], .big);
            const shared_tuple_count = std.mem.readInt(u16, data[6..][0..2], .big);
            const shared_tuples_offset = std.mem.readInt(u32, data[8..][0..4], .big);
            const glyph_count = std.mem.readInt(u16, data[12..][0..2], .big);
            const flags = std.mem.readInt(u16, data[14..][0..2], .big);
            const array_offset = std.mem.readInt(u32, data[16..][0..4], .big);

            const long_offsets = (flags & 1) != 0;
            const entry_size: usize = if (long_offsets) 4 else 2;
            const offsets_start = 20;
            const offsets_count = @as(usize, glyph_count) + 1;
            if (offsets_start + offsets_count * entry_size > data.len) return error.InvalidTableFormat;

            const glyph_offsets = try alloc.alloc(u32, offsets_count);
            errdefer alloc.free(glyph_offsets);
            for (glyph_offsets, 0..) |*o, i| {
                const pos = offsets_start + i * entry_size;
                const raw: u32 = if (long_offsets)
                    std.mem.readInt(u32, data[pos..][0..4], .big)
                else
                    @as(u32, std.mem.readInt(u16, data[pos..][0..2], .big)) * 2;
                const abs = @as(u64, array_offset) + raw;
                if (abs > data.len) return error.InvalidTableFormat;
                o.* = @intCast(abs);
            }

            var shared_tuples: []const f32 = &.{};
            if (shared_tuple_count > 0) {
                const count = @as(usize, shared_tuple_count) * axis_count;
                if (@as(u64, shared_tuples_offset) + @as(u64, count) * 2 > data.len) return error.InvalidTableFormat;
                const buf = try alloc.alloc(f32, count);
                for (buf, 0..) |*v, i| {
                    const pos = shared_tuples_offset + i * 2;
                    v.* = f2dot14ToF32(std.mem.readInt(i16, data[pos..][0..2], .big));
                }
                shared_tuples = buf;
            }

            return .{
                .axis_count = axis_count,
                .glyph_count = glyph_count,
                .glyph_offsets = glyph_offsets,
                .shared_tuple_count = shared_tuple_count,
                .shared_tuples = shared_tuples,
            };
        }

        pub fn glyphVariationData(header: Header, data: []const u8, glyph_id: u16) []const u8 {
            if (@as(usize, glyph_id) + 1 >= header.glyph_offsets.len) return &.{};
            const start = header.glyph_offsets[glyph_id];
            const end = header.glyph_offsets[glyph_id + 1];
            if (start >= end or end > data.len) return &.{};
            return data[start..end];
        }

        fn f2dot14ToF32(v: i16) f32 {
            return @as(f32, @floatFromInt(v)) / 16384.0;
        }

        const PointSet = struct { points: []const u16, all: bool };

        fn readPackedPointCount(data: []const u8, pos: *usize) Font.ParseError!u16 {
            if (pos.* + 1 > data.len) return error.UnexpectedEndOfData;
            var n: u16 = data[pos.*];
            pos.* += 1;
            if (n & 0x80 != 0) {
                if (pos.* + 1 > data.len) return error.UnexpectedEndOfData;
                n = (n & 0x7F) << 8 | data[pos.*];
                pos.* += 1;
            }
            return n;
        }

        fn readPackedPoints(alloc: Allocator, data: []const u8, pos: *usize) (Font.ParseError || error{OutOfMemory})!PointSet {
            const n = try readPackedPointCount(data, pos);
            if (n == 0) return .{ .points = &.{}, .all = true };

            const points = try alloc.alloc(u16, n);
            errdefer alloc.free(points);
            var i: usize = 0;
            var first: u16 = 0;
            while (i < n) {
                if (pos.* + 1 > data.len) return error.UnexpectedEndOfData;
                const runcnt = data[pos.*];
                pos.* += 1;
                const words = (runcnt & 0x80) != 0;
                var cnt: usize = (runcnt & 0x7F) + 1;
                if (cnt > n - i) cnt = n - i;

                var j: usize = 0;
                while (j < cnt) : (j += 1) {
                    if (words) {
                        if (pos.* + 2 > data.len) return error.UnexpectedEndOfData;
                        first +%= std.mem.readInt(u16, data[pos.*..][0..2], .big);
                        pos.* += 2;
                    } else {
                        if (pos.* + 1 > data.len) return error.UnexpectedEndOfData;
                        first +%= data[pos.*];
                        pos.* += 1;
                    }
                    points[i] = first;
                    i += 1;
                }
            }
            return .{ .points = points, .all = false };
        }

        fn readPackedDeltas(alloc: Allocator, data: []const u8, pos: *usize, count: usize) (Font.ParseError || error{OutOfMemory})![]f64 {
            const deltas = try alloc.alloc(f64, count);
            errdefer alloc.free(deltas);
            var i: usize = 0;
            while (i < count) {
                if (pos.* + 1 > data.len) return error.UnexpectedEndOfData;
                const runcnt = data[pos.*];
                pos.* += 1;
                var cnt: usize = (runcnt & 0x3F) + 1;
                if (cnt > count - i) cnt = count - i;

                if (runcnt & 0x80 != 0) {
                    var j: usize = 0;
                    while (j < cnt) : (j += 1) {
                        deltas[i] = 0;
                        i += 1;
                    }
                } else if (runcnt & 0x40 != 0) {
                    var j: usize = 0;
                    while (j < cnt) : (j += 1) {
                        if (pos.* + 2 > data.len) return error.UnexpectedEndOfData;
                        deltas[i] = @floatFromInt(std.mem.readInt(i16, data[pos.*..][0..2], .big));
                        pos.* += 2;
                        i += 1;
                    }
                } else {
                    var j: usize = 0;
                    while (j < cnt) : (j += 1) {
                        if (pos.* + 1 > data.len) return error.UnexpectedEndOfData;
                        deltas[i] = @floatFromInt(@as(i8, @bitCast(data[pos.*])));
                        pos.* += 1;
                        i += 1;
                    }
                }
            }
            return deltas;
        }

        fn applyTupleScalar(
            axis_count: usize,
            tuple_index: u16,
            tuple_coords: []const f32,
            im_start_coords: []const f32,
            im_end_coords: []const f32,
            normalized_coords: []const f32,
        ) f64 {
            var apply: f64 = 1.0;
            var i: usize = 0;
            while (i < axis_count) : (i += 1) {
                const tc: f64 = tuple_coords[i];
                if (tc == 0) continue;
                const ncv: f64 = if (i < normalized_coords.len) normalized_coords[i] else 0;
                if (ncv == 0) return 0;
                if (tc == ncv) continue;

                if (tuple_index & intermediate_tuple == 0) {
                    if ((tc > ncv and ncv > 0) or (tc < ncv and ncv < 0)) {
                        apply = apply * ncv / tc;
                    } else return 0;
                } else {
                    const s: f64 = im_start_coords[i];
                    const e: f64 = im_end_coords[i];
                    if (ncv <= s or ncv >= e) return 0;
                    if (ncv < tc) {
                        apply = apply * (ncv - s) / (tc - s);
                    } else {
                        apply = apply * (e - ncv) / (e - tc);
                    }
                }
            }
            return apply;
        }

        fn deltaShift(p1: usize, p2: usize, ref: usize, in_points: []const Point2, out_points: []Point2) void {
            const dx = out_points[ref].x - in_points[ref].x;
            const dy = out_points[ref].y - in_points[ref].y;
            if (dx == 0 and dy == 0) return;
            var p = p1;
            while (p < ref) : (p += 1) {
                out_points[p].x += dx;
                out_points[p].y += dy;
            }
            p = ref + 1;
            while (p <= p2) : (p += 1) {
                out_points[p].x += dx;
                out_points[p].y += dy;
            }
        }

        fn deltaInterpolate(p1: usize, p2: usize, ref1_in: usize, ref2_in: usize, in_points: []const Point2, out_points: []Point2) void {
            if (p1 > p2) return;
            inline for (.{ "x", "y" }) |axis| {
                var ref1 = ref1_in;
                var ref2 = ref2_in;
                if (@field(in_points[ref1], axis) > @field(in_points[ref2], axis)) {
                    const tmp = ref1;
                    ref1 = ref2;
                    ref2 = tmp;
                }
                const in1 = @field(in_points[ref1], axis);
                const in2 = @field(in_points[ref2], axis);
                const out1 = @field(out_points[ref1], axis);
                const out2 = @field(out_points[ref2], axis);
                const d1 = out1 - in1;
                const d2 = out2 - in2;
                if (in1 != in2 or out1 == out2) {
                    const scale: f64 = if (in1 != in2) (out2 - out1) / (in2 - in1) else 0;
                    var p = p1;
                    while (p <= p2) : (p += 1) {
                        const v = @field(in_points[p], axis);
                        const out = if (v <= in1) v + d1 else if (v >= in2) v + d2 else out1 + (v - in1) * scale;
                        @field(out_points[p], axis) = out;
                    }
                }
            }
        }

        // Interpolate points without an explicit delta, similar to the `IUP`
        // hinting instruction. `contour_ends` lists the last point index of
        // each contour (cumulative, as in `Outline.end_points_of_contours`);
        // an empty slice (composite pseudo-points) makes this a no-op, which
        // is correct — composite component offsets get no IUP inference.
        fn interpolateDeltas(contour_ends: []const u16, points_out: []Point2, points_org: []const Point2, has_delta: []const bool) void {
            if (has_delta.len == 0) return;
            var point: usize = 0;
            for (contour_ends) |end_u16| {
                // Only the *last* contour end is checked against the point
                // count at parse time, so an earlier entry can point past the
                // buffer; clamp the same way the hinting IUP does.
                var end: usize = end_u16;
                if (end >= has_delta.len) end = has_delta.len - 1;
                const first_point = point;

                while (point <= end and !has_delta[point]) point += 1;

                if (point <= end) {
                    const first_delta = point;
                    var cur_delta = point;
                    point += 1;

                    while (point <= end) : (point += 1) {
                        if (has_delta[point]) {
                            deltaInterpolate(cur_delta + 1, point - 1, cur_delta, point, points_org, points_out);
                            cur_delta = point;
                        }
                    }

                    if (cur_delta == first_delta) {
                        deltaShift(first_point, end, cur_delta, points_org, points_out);
                    } else {
                        deltaInterpolate(cur_delta + 1, end, cur_delta, first_delta, points_org, points_out);
                        if (first_delta > 0)
                            deltaInterpolate(first_point, first_delta - 1, cur_delta, first_delta, points_org, points_out);
                    }
                }
            }
        }

        // Apply every active tuple's deltas to `points` in place (length =
        // real point count + 4 phantom points, or component count + 4 for a
        // composite's pseudo-points). `contour_ends` covers real contours
        // only; pass `&.{}` for the composite pseudo-point case.
        pub fn applyDeltas(
            alloc: Allocator,
            header: Header,
            variation_data: []const u8,
            points: []Point2,
            contour_ends: []const u16,
            normalized_coords: []const f32,
        ) (Font.ParseError || error{OutOfMemory})!void {
            if (variation_data.len < 4) return;
            const n_points = points.len;

            const point_bufs = try alloc.alloc(Point2, n_points * 3);
            defer alloc.free(point_bufs);
            const points_org = point_bufs[0..n_points];
            const total_delta = point_bufs[n_points .. n_points * 2];
            const points_out = point_bufs[n_points * 2 .. n_points * 3];
            @memcpy(points_org, points);
            @memset(total_delta, .{ .x = 0, .y = 0 });

            const raw_tuple_count = std.mem.readInt(u16, variation_data[0..2], .big);
            const offset_to_data_field = std.mem.readInt(u16, variation_data[2..4], .big);
            var head_pos: usize = 4;
            var data_pos: usize = offset_to_data_field;
            if (data_pos > variation_data.len) return error.InvalidTableFormat;

            var shared_points: PointSet = .{ .points = &.{}, .all = false };
            var have_shared_points = false;
            if (raw_tuple_count & tuples_share_point_numbers != 0) {
                shared_points = try readPackedPoints(alloc, variation_data, &data_pos);
                have_shared_points = true;
            }
            defer if (have_shared_points and !shared_points.all) alloc.free(shared_points.points);

            const tuple_count = raw_tuple_count & tuple_count_mask;
            if (4 * @as(u64, tuple_count) > variation_data.len -| head_pos) return error.InvalidTableFormat;

            const axis_bufs = try alloc.alloc(f32, header.axis_count * 3);
            defer alloc.free(axis_bufs);
            const peak_buf = axis_bufs[0..header.axis_count];
            const im_start_buf = axis_bufs[header.axis_count .. header.axis_count * 2];
            const im_end_buf = axis_bufs[header.axis_count * 2 .. header.axis_count * 3];
            const has_delta = try alloc.alloc(bool, n_points);
            defer alloc.free(has_delta);

            var i: usize = 0;
            while (i < tuple_count) : (i += 1) {
                if (head_pos + 4 > variation_data.len) return error.InvalidTableFormat;
                const tuple_data_size = std.mem.readInt(u16, variation_data[head_pos..][0..2], .big);
                const tuple_index = std.mem.readInt(u16, variation_data[head_pos + 2 ..][0..2], .big);
                head_pos += 4;

                var tuple_coords: []const f32 = &.{};
                if (tuple_index & embedded_tuple_coord != 0) {
                    if (head_pos + @as(usize, header.axis_count) * 2 > variation_data.len) return error.InvalidTableFormat;
                    for (peak_buf, 0..) |*v, j|
                        v.* = f2dot14ToF32(std.mem.readInt(i16, variation_data[head_pos + j * 2 ..][0..2], .big));
                    head_pos += @as(usize, header.axis_count) * 2;
                    tuple_coords = peak_buf;
                } else {
                    const idx = tuple_index & tuple_index_mask;
                    if (idx >= header.shared_tuple_count) return error.InvalidTableFormat;
                    tuple_coords = header.shared_tuples[@as(usize, idx) * header.axis_count ..][0..header.axis_count];
                }

                if (tuple_index & intermediate_tuple != 0) {
                    if (head_pos + @as(usize, header.axis_count) * 4 > variation_data.len) return error.InvalidTableFormat;
                    for (im_start_buf, 0..) |*v, j|
                        v.* = f2dot14ToF32(std.mem.readInt(i16, variation_data[head_pos + j * 2 ..][0..2], .big));
                    head_pos += @as(usize, header.axis_count) * 2;
                    for (im_end_buf, 0..) |*v, j|
                        v.* = f2dot14ToF32(std.mem.readInt(i16, variation_data[head_pos + j * 2 ..][0..2], .big));
                    head_pos += @as(usize, header.axis_count) * 2;
                }

                const scale = applyTupleScalar(header.axis_count, tuple_index, tuple_coords, im_start_buf, im_end_buf, normalized_coords);
                if (scale == 0) {
                    data_pos += tuple_data_size;
                    continue;
                }

                var local_pos = data_pos;
                var points_here: PointSet = undefined;
                var free_points = false;
                if (tuple_index & private_point_numbers != 0) {
                    points_here = try readPackedPoints(alloc, variation_data, &local_pos);
                    free_points = true;
                } else {
                    points_here = shared_points;
                }
                defer if (free_points and !points_here.all) alloc.free(points_here.points);

                const point_count = if (points_here.all) n_points else points_here.points.len;
                const deltas_x = try readPackedDeltas(alloc, variation_data, &local_pos, point_count);
                defer alloc.free(deltas_x);
                const deltas_y = try readPackedDeltas(alloc, variation_data, &local_pos, point_count);
                defer alloc.free(deltas_y);

                if (points_here.all) {
                    for (0..n_points) |j| {
                        total_delta[j].x += deltas_x[j] * scale;
                        total_delta[j].y += deltas_y[j] * scale;
                    }
                } else {
                    @memset(has_delta, false);
                    @memcpy(points_out, points_org);
                    for (points_here.points, 0..) |idx, j| {
                        if (idx >= n_points) continue;
                        has_delta[idx] = true;
                        points_out[idx].x += deltas_x[j] * scale;
                        points_out[idx].y += deltas_y[j] * scale;
                    }
                    interpolateDeltas(contour_ends, points_out, points_org, has_delta);
                    for (0..n_points) |j| {
                        total_delta[j].x += points_out[j].x - points_org[j].x;
                        total_delta[j].y += points_out[j].y - points_org[j].y;
                    }
                }

                data_pos += tuple_data_size;
            }

            for (points, 0..) |*p, j| {
                p.x = points_org[j].x + total_delta[j].x;
                p.y = points_org[j].y + total_delta[j].y;
            }
        }
    };

    pub const cff = struct {
        pub const Bounds = struct {
            x_min: i32,
            y_min: i32,
            x_max: i32,
            y_max: i32,
        };

        pub const Point = struct { x: i32, y: i32 };

        /// One CFF Type2 charstring path command, in font units. Contours
        /// aren't explicitly closed by the charstring format (Type2 always
        /// implies a closing line back to the contour's `move_to`) — a new
        /// `move_to` (or end of `segments`) marks the previous contour's end.
        pub const Segment = union(enum) {
            move_to: Point,
            line_to: Point,
            curve_to: struct { c1: Point, c2: Point, to: Point },
        };

        pub const Outline = struct {
            segments: []const Segment,
        };

        pub const CharstringAndSubrs = struct {
            charstring: []const u8,
            global_subrs: CffIndex,
            local_subrs: CffIndex,
        };

        /// Exposed for `cff_hint/interp.zig`'s hinted charstring interpreter,
        /// which needs the raw charstring plus its bias-indexed local/global
        /// subr INDEXes rather than a decoded outline.
        pub fn charstringAndSubrsForGlyph(cff_data: []const u8, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!CharstringAndSubrs {
            return charstringAndSubrs(cff_data, glyph_id);
        }

        /// A `CharstringAndSubrs` with no local/global subroutines, for
        /// callers (e.g. `cff_hint/interp_test.zig`) driving a hand-built
        /// charstring that never calls `callsubr`/`callgsubr` and so has no
        /// need for a real CFF font blob to source subr INDEXes from.
        pub fn charstringAndSubrsWithoutSubrs(charstring: []const u8) CharstringAndSubrs {
            return .{ .charstring = charstring, .global_subrs = CffIndex.empty(charstring), .local_subrs = CffIndex.empty(charstring) };
        }

        fn charstringAndSubrs(cff_data: []const u8, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!CharstringAndSubrs {
            var ctx = try Context.init(cff_data);
            return ctx.charstringAndSubrs(glyph_id);
        }

        /// Per-font CFF state — INDEX headers, top DICT, and the Private
        /// DICT-derived local subrs/hints — parsed once. Resolving them per
        /// glyph instead means re-walking Name/TopDict/String/GSubr INDEXes,
        /// the top DICT, FDSelect and the Private DICT for every outline.
        /// CID fonts still consult FDSelect per glyph but memoize the last
        /// FD's subrs/hints, since consecutive glyphs almost always share one.
        pub const Context = struct {
            data: []const u8,
            global_subrs: CffIndex,
            charstrings: CffIndex,
            fdarray: ?CffIndex,
            fdselect_offset: u32,
            cached_fd: ?u8,
            local_subrs: CffIndex,
            private_hints: CffPrivateHints,

            pub fn init(cff_data: []const u8) Font.ParseError!Context {
                if (cff_data.len < 4) return error.InvalidTableFormat;
                const header_size = cff_data[2];
                var pos: usize = header_size;

                const name_index = try readCffIndex(cff_data, pos, false);
                pos = name_index.end_pos;
                const top_dict_index = try readCffIndex(cff_data, pos, false);
                pos = top_dict_index.end_pos;
                const string_index = try readCffIndex(cff_data, pos, false);
                pos = string_index.end_pos;
                const global_subrs = (try readCffIndex(cff_data, pos, false)).index;

                if (top_dict_index.index.count == 0) return error.InvalidTableFormat;
                const top = try parseCffDict(try top_dict_index.index.get(0));
                const charstrings_offset = top.charstrings_offset orelse return error.InvalidTableFormat;

                var self = Context{
                    .data = cff_data,
                    .global_subrs = global_subrs,
                    .charstrings = (try readCffIndex(cff_data, charstrings_offset, false)).index,
                    .fdarray = null,
                    .fdselect_offset = 0,
                    .cached_fd = null,
                    .local_subrs = CffIndex.empty(cff_data),
                    .private_hints = .{},
                };

                if (top.is_cid) {
                    if (top.fdarray_offset) |fda_off| {
                        self.fdselect_offset = top.fdselect_offset orelse return error.InvalidTableFormat;
                        self.fdarray = (try readCffIndex(cff_data, fda_off, false)).index;
                    } else {
                        // No FDArray to select from: hints come off the top
                        // DICT, but its Subrs stay out of reach (a CID font's
                        // local subrs live in the per-FD Private DICTs).
                        self.private_hints = try privateHintsFromDict(cff_data, top);
                    }
                } else {
                    self.local_subrs = try localSubrsFromPrivate(cff_data, top, false);
                    self.private_hints = try privateHintsFromDict(cff_data, top);
                }
                return self;
            }

            fn selectFd(self: *Context, glyph_id: u16) Font.ParseError!void {
                const fdarray = self.fdarray orelse return;
                const fd = try fdForGlyph(self.data, self.fdselect_offset, glyph_id);
                if (self.cached_fd) |cached| if (cached == fd) return;
                const fd_dict = try parseCffDict(try fdarray.get(fd));
                self.local_subrs = try localSubrsFromPrivate(self.data, fd_dict, false);
                self.private_hints = try privateHintsFromDict(self.data, fd_dict);
                self.cached_fd = fd;
            }

            pub fn charstringAndSubrs(self: *Context, glyph_id: u16) Font.ParseError!CharstringAndSubrs {
                try self.selectFd(glyph_id);
                return .{
                    .charstring = try self.charstrings.get(glyph_id),
                    .global_subrs = self.global_subrs,
                    .local_subrs = self.local_subrs,
                };
            }

            pub fn privateHints(self: *Context, glyph_id: u16) Font.ParseError!CffPrivateHints {
                try self.selectFd(glyph_id);
                return self.private_hints;
            }

            /// Decodes a glyph's charstring into path segments; see `outline`.
            pub fn outline(self: *Context, alloc: Allocator, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!Outline {
                const parts = try self.charstringAndSubrs(glyph_id);
                var interp = CharstringInterp.init(parts.global_subrs, parts.local_subrs, false, .{ .data = self.data, .vstore_offset = null });
                interp.emit_segments = std.ArrayListUnmanaged(Segment).empty;
                errdefer interp.emit_segments.?.deinit(alloc);
                interp.emit_alloc = alloc;
                try interp.run(parts.charstring);
                return .{ .segments = try interp.emit_segments.?.toOwnedSlice(alloc) };
            }
        };

        pub fn glyphBounds(alloc: Allocator, cff_data: []const u8, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!Bounds {
            _ = alloc;
            const parts = try charstringAndSubrs(cff_data, glyph_id);
            var interp = CharstringInterp.init(parts.global_subrs, parts.local_subrs, false, .{ .data = cff_data, .vstore_offset = null });
            try interp.run(parts.charstring);
            return interp.finalBounds();
        }

        /// Decodes a glyph's Type2 charstring into path segments (font
        /// units, unscaled) for rasterization. Caller owns the returned
        /// slice (`alloc.free(outline.segments)`).
        pub fn outline(alloc: Allocator, cff_data: []const u8, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!Outline {
            var ctx = try Context.init(cff_data);
            return ctx.outline(alloc, glyph_id);
        }
    };

    pub const cff2 = struct {
        pub const CharstringAndSubrs = struct {
            charstring: []const u8,
            global_subrs: CffIndex,
            local_subrs: CffIndex,
            vstore_offset: ?u32,
        };

        pub fn charstringAndSubrsForGlyph(cff2_data: []const u8, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!CharstringAndSubrs {
            return charstringAndSubrs(cff2_data, glyph_id);
        }

        fn charstringAndSubrs(cff2_data: []const u8, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!CharstringAndSubrs {
            if (cff2_data.len < 5) return error.InvalidTableFormat;
            const header_size = cff2_data[2];
            const top_dict_length = std.mem.readInt(u16, cff2_data[3..][0..2], .big);
            if (@as(u64, header_size) + top_dict_length > cff2_data.len) return error.InvalidTableFormat;
            const top_dict_data = cff2_data[header_size..][0..top_dict_length];
            const top = try parseCffDict(top_dict_data);

            const gsubr_pos = @as(usize, header_size) + top_dict_length;
            const global_subrs = (try readCffIndex(cff2_data, gsubr_pos, true)).index;

            const charstrings_offset = top.charstrings_offset orelse return error.InvalidTableFormat;
            const charstrings = (try readCffIndex(cff2_data, charstrings_offset, true)).index;
            const charstring = try charstrings.get(glyph_id);

            var fd: u8 = 0;
            if (top.fdselect_offset) |fdsel_off| fd = try fdForGlyph(cff2_data, fdsel_off, glyph_id);

            var local_subrs = CffIndex.empty(cff2_data);
            if (top.fdarray_offset) |fda_off| {
                const fdarray = (try readCffIndex(cff2_data, fda_off, true)).index;
                const fd_dict = try parseCffDict(try fdarray.get(fd));
                local_subrs = try localSubrsFromPrivate(cff2_data, fd_dict, true);
            }

            return .{ .charstring = charstring, .global_subrs = global_subrs, .local_subrs = local_subrs, .vstore_offset = top.vstore_offset };
        }

        pub fn glyphBounds(
            alloc: Allocator,
            cff2_data: []const u8,
            glyph_id: u16,
            normalized_coords: []const f32,
        ) (Font.ParseError || error{OutOfMemory})!cff.Bounds {
            // TODO(rasterization): alloc unused, see cff.glyphBounds.
            _ = alloc;
            // NOTE: bbox is computed against the values on the stack after
            // `blend` discards its region deltas, which is exactly the
            // default-instance result whenever normalized_coords is all
            // zero (every region's scalar is 0 at the default location).
            // Non-default instancing would need the deltas applied, which
            // this parsing-layer bbox helper deliberately doesn't do yet.
            _ = normalized_coords;
            const parts = try charstringAndSubrs(cff2_data, glyph_id);
            var interp = CharstringInterp.init(parts.global_subrs, parts.local_subrs, true, .{ .data = cff2_data, .vstore_offset = parts.vstore_offset });
            try interp.run(parts.charstring);
            return interp.finalBounds();
        }

        /// Decodes a glyph's CFF2 charstring into path segments (font
        /// units, unscaled, default/non-instanced location) for
        /// rasterization via `rasterization.rasterizeCff` — CFF2 charstrings
        /// decode to the same cubic segment shape as CFF1, so no separate
        /// rasterizer entry point is needed. Caller owns the returned slice
        /// (`alloc.free(outline.segments)`).
        pub fn outline(alloc: Allocator, cff2_data: []const u8, glyph_id: u16) (Font.ParseError || error{OutOfMemory})!cff.Outline {
            const parts = try charstringAndSubrs(cff2_data, glyph_id);
            return outlineFromParts(alloc, cff2_data, parts);
        }

        /// Like `outline`, but takes an already-resolved `CharstringAndSubrs`
        /// instead of re-deriving it from `cff2_data` -- lets fuzzing swap in
        /// an adversarial charstring while keeping real global/local subrs
        /// and vstore from a parseable font.
        pub fn outlineFromParts(alloc: Allocator, cff2_data: []const u8, parts: CharstringAndSubrs) (Font.ParseError || error{OutOfMemory})!cff.Outline {
            var interp = CharstringInterp.init(parts.global_subrs, parts.local_subrs, true, .{ .data = cff2_data, .vstore_offset = parts.vstore_offset });
            interp.emit_segments = std.ArrayListUnmanaged(cff.Segment).empty;
            errdefer interp.emit_segments.?.deinit(alloc);
            interp.emit_alloc = alloc;
            try interp.run(parts.charstring);
            return .{ .segments = try interp.emit_segments.?.toOwnedSlice(alloc) };
        }
    };

    pub const fvar = struct {
        pub const Axis = struct {
            tag: Font.Tag,
            min_value: f32,
            default_value: f32,
            max_value: f32,
        };

        pub fn axes(alloc: Allocator, data: []const u8) (Font.ParseError || error{OutOfMemory})![]const Axis {
            if (data.len < 16) return error.InvalidTableFormat;
            const axes_array_offset = std.mem.readInt(u16, data[4..][0..2], .big);
            const axis_count = std.mem.readInt(u16, data[8..][0..2], .big);
            const axis_size = std.mem.readInt(u16, data[10..][0..2], .big);
            if (axis_size < 20) return error.InvalidTableFormat;
            if (@as(u64, axes_array_offset) + @as(u64, axis_count) * axis_size > data.len) return error.InvalidTableFormat;

            const result = try alloc.alloc(Axis, axis_count);
            errdefer alloc.free(result);
            for (result, 0..) |*a, i| {
                const pos = @as(usize, axes_array_offset) + i * axis_size;
                if (pos + 20 > data.len) return error.InvalidTableFormat;
                a.* = .{
                    .tag = data[pos..][0..4].*,
                    .min_value = fixedToF32(std.mem.readInt(i32, data[pos + 4 ..][0..4], .big)),
                    .default_value = fixedToF32(std.mem.readInt(i32, data[pos + 8 ..][0..4], .big)),
                    .max_value = fixedToF32(std.mem.readInt(i32, data[pos + 12 ..][0..4], .big)),
                };
            }
            return result;
        }

        fn fixedToF32(v: i32) f32 {
            return @as(f32, @floatFromInt(v)) / 65536.0;
        }

        // OpenType "default normalization": map a user-space axis value to
        // [-1, 1] using the axis's (min, default, max) triple. Input to
        // avar's segment-map remap.
        pub fn normalizeAxisValue(axis: Axis, user_value: f32) f32 {
            const v = std.math.clamp(user_value, axis.min_value, axis.max_value);
            if (v == axis.default_value or axis.min_value == axis.max_value) return 0.0;
            if (v < axis.default_value) {
                if (axis.min_value == axis.default_value) return 0.0;
                return (v - axis.default_value) / (axis.default_value - axis.min_value);
            }
            if (axis.max_value == axis.default_value) return 0.0;
            return (v - axis.default_value) / (axis.max_value - axis.default_value);
        }
    };

    pub const avar = struct {
        pub const AxisValueMap = struct {
            from_coord: f32,
            to_coord: f32,
        };

        // Per-axis segment maps, in fvar axis order. avar2 (major version 2)
        // is out of scope; only version-1 axis remapping is parsed.
        pub fn segmentMaps(alloc: Allocator, data: []const u8) (Font.ParseError || error{OutOfMemory})![]const []const AxisValueMap {
            if (data.len < 8) return error.InvalidTableFormat;
            const major_version = std.mem.readInt(u16, data[0..2], .big);
            if (major_version != 1) return error.InvalidTableFormat;
            const axis_count = std.mem.readInt(u16, data[6..][0..2], .big);

            const result = try alloc.alloc([]const AxisValueMap, axis_count);
            errdefer alloc.free(result);
            var filled: usize = 0;
            errdefer for (result[0..filled]) |segment| alloc.free(segment);
            var pos: usize = 8;
            for (result) |*segment| {
                if (pos + 2 > data.len) return error.InvalidTableFormat;
                const map_count = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;
                if (pos + @as(u64, map_count) * 4 > data.len) return error.InvalidTableFormat;

                const maps = try alloc.alloc(AxisValueMap, map_count);
                for (maps) |*m| {
                    m.* = .{
                        .from_coord = f2dot14ToF32(std.mem.readInt(i16, data[pos..][0..2], .big)),
                        .to_coord = f2dot14ToF32(std.mem.readInt(i16, data[pos + 2 ..][0..2], .big)),
                    };
                    pos += 4;
                }
                segment.* = maps;
                filled += 1;
            }
            return result;
        }

        fn f2dot14ToF32(v: i16) f32 {
            return @as(f32, @floatFromInt(v)) / 16384.0;
        }

        /// Ported from hb's `SegmentMaps::map_float`, error recovery for
        /// short or duplicated maps included.
        pub fn mapValue(segment: []const AxisValueMap, value: f32) f32 {
            if (segment.len == 0) return value;
            if (segment.len == 1) return value - segment[0].from_coord + segment[0].to_coord;

            var start: usize = 0;
            var end: usize = segment.len;
            if (segment[0].from_coord == -1 and segment[0].to_coord == -1 and segment[1].from_coord == -1) start += 1;
            if (segment[end - 1].from_coord == 1 and segment[end - 1].to_coord == 1 and segment[end - 2].from_coord == 1) end -= 1;

            var i = start;
            while (i < end and value != segment[i].from_coord) i += 1;
            if (i < end) {
                var j = i;
                while (j + 1 < end and value == segment[j + 1].from_coord) j += 1;
                if (i == j) return segment[i].to_coord;
                if (i + 2 == j) return segment[i + 1].to_coord;
                if (value < 0) return segment[j].to_coord;
                if (value > 0) return segment[i].to_coord;
                return if (@abs(segment[i].to_coord) < @abs(segment[j].to_coord)) segment[i].to_coord else segment[j].to_coord;
            }

            i = start;
            while (i < end and value >= segment[i].from_coord) i += 1;
            if (i == 0) return value - segment[0].from_coord + segment[0].to_coord;
            if (i == end) return value - segment[end - 1].from_coord + segment[end - 1].to_coord;
            const before = segment[i - 1];
            const after = segment[i];
            return before.to_coord + (after.to_coord - before.to_coord) * (value - before.from_coord) / (after.from_coord - before.from_coord);
        }
    };

    pub const STAT = struct {
        pub const DesignAxis = struct {
            tag: Font.Tag,
            name_id: u16,
            ordering: u16,
        };

        pub const AxisIndexValue = struct {
            axis_index: u16,
            value: f32,
        };

        pub const AxisValue = union(enum) {
            format1: struct { axis_index: u16, flags: u16, value_name_id: u16, value: f32 },
            format2: struct { axis_index: u16, flags: u16, value_name_id: u16, nominal_value: f32, range_min_value: f32, range_max_value: f32 },
            format3: struct { axis_index: u16, flags: u16, value_name_id: u16, value: f32, linked_value: f32 },
            format4: struct { flags: u16, value_name_id: u16, axis_values: []const AxisIndexValue },
        };

        pub fn elidedFallbackNameId(data: []const u8) ?u16 {
            if (data.len < 20) return null;
            const minor_version = std.mem.readInt(u16, data[2..4], .big);
            if (minor_version < 1) return null;
            return std.mem.readInt(u16, data[18..20], .big);
        }

        pub fn designAxes(alloc: Allocator, data: []const u8) (Font.ParseError || error{OutOfMemory})![]const DesignAxis {
            if (data.len < 12) return error.InvalidTableFormat;
            const design_axis_size = std.mem.readInt(u16, data[4..][0..2], .big);
            const design_axis_count = std.mem.readInt(u16, data[6..][0..2], .big);
            const design_axes_offset = std.mem.readInt(u32, data[8..][0..4], .big);
            if (design_axis_size < 8) return error.InvalidTableFormat;
            if (@as(u64, design_axes_offset) + @as(u64, design_axis_count) * design_axis_size > data.len) return error.InvalidTableFormat;

            const result = try alloc.alloc(DesignAxis, design_axis_count);
            errdefer alloc.free(result);
            for (result, 0..) |*a, i| {
                const pos = @as(usize, design_axes_offset) + i * design_axis_size;
                if (pos + 8 > data.len) return error.InvalidTableFormat;
                a.* = .{
                    .tag = data[pos..][0..4].*,
                    .name_id = std.mem.readInt(u16, data[pos + 4 ..][0..2], .big),
                    .ordering = std.mem.readInt(u16, data[pos + 6 ..][0..2], .big),
                };
            }
            return result;
        }

        pub fn axisValues(alloc: Allocator, data: []const u8) (Font.ParseError || error{OutOfMemory})![]const AxisValue {
            if (data.len < 18) return error.InvalidTableFormat;
            const axis_value_count = std.mem.readInt(u16, data[12..][0..2], .big);
            const offsets_array_offset = std.mem.readInt(u32, data[14..][0..4], .big);
            if (@as(u64, offsets_array_offset) + @as(u64, axis_value_count) * 2 > data.len) return error.InvalidTableFormat;

            const result = try alloc.alloc(AxisValue, axis_value_count);
            errdefer alloc.free(result);
            var allocated: usize = 0;
            errdefer for (result[0..allocated]) |v| if (v == .format4) alloc.free(v.format4.axis_values);

            for (result, 0..) |*out, i| {
                const offset_pos = offsets_array_offset + i * 2;
                const table_offset = offsets_array_offset + std.mem.readInt(u16, data[offset_pos..][0..2], .big);
                if (table_offset + 2 > data.len) return error.InvalidTableFormat;
                const format = std.mem.readInt(u16, data[table_offset..][0..2], .big);
                switch (format) {
                    1 => {
                        if (table_offset + 12 > data.len) return error.InvalidTableFormat;
                        out.* = .{ .format1 = .{
                            .axis_index = std.mem.readInt(u16, data[table_offset + 2 ..][0..2], .big),
                            .flags = std.mem.readInt(u16, data[table_offset + 4 ..][0..2], .big),
                            .value_name_id = std.mem.readInt(u16, data[table_offset + 6 ..][0..2], .big),
                            .value = fixedToF32(std.mem.readInt(i32, data[table_offset + 8 ..][0..4], .big)),
                        } };
                    },
                    2 => {
                        if (table_offset + 20 > data.len) return error.InvalidTableFormat;
                        out.* = .{ .format2 = .{
                            .axis_index = std.mem.readInt(u16, data[table_offset + 2 ..][0..2], .big),
                            .flags = std.mem.readInt(u16, data[table_offset + 4 ..][0..2], .big),
                            .value_name_id = std.mem.readInt(u16, data[table_offset + 6 ..][0..2], .big),
                            .nominal_value = fixedToF32(std.mem.readInt(i32, data[table_offset + 8 ..][0..4], .big)),
                            .range_min_value = fixedToF32(std.mem.readInt(i32, data[table_offset + 12 ..][0..4], .big)),
                            .range_max_value = fixedToF32(std.mem.readInt(i32, data[table_offset + 16 ..][0..4], .big)),
                        } };
                    },
                    3 => {
                        if (table_offset + 16 > data.len) return error.InvalidTableFormat;
                        out.* = .{ .format3 = .{
                            .axis_index = std.mem.readInt(u16, data[table_offset + 2 ..][0..2], .big),
                            .flags = std.mem.readInt(u16, data[table_offset + 4 ..][0..2], .big),
                            .value_name_id = std.mem.readInt(u16, data[table_offset + 6 ..][0..2], .big),
                            .value = fixedToF32(std.mem.readInt(i32, data[table_offset + 8 ..][0..4], .big)),
                            .linked_value = fixedToF32(std.mem.readInt(i32, data[table_offset + 12 ..][0..4], .big)),
                        } };
                    },
                    4 => {
                        if (table_offset + 8 > data.len) return error.InvalidTableFormat;
                        const axis_count = std.mem.readInt(u16, data[table_offset + 2 ..][0..2], .big);
                        const flags = std.mem.readInt(u16, data[table_offset + 4 ..][0..2], .big);
                        const value_name_id = std.mem.readInt(u16, data[table_offset + 6 ..][0..2], .big);
                        if (table_offset + 8 + @as(u64, axis_count) * 6 > data.len) return error.InvalidTableFormat;
                        const record_values = try alloc.alloc(AxisIndexValue, axis_count);
                        for (record_values, 0..) |*r, j| {
                            const rp = table_offset + 8 + j * 6;
                            r.* = .{
                                .axis_index = std.mem.readInt(u16, data[rp..][0..2], .big),
                                .value = fixedToF32(std.mem.readInt(i32, data[rp + 2 ..][0..4], .big)),
                            };
                        }
                        out.* = .{ .format4 = .{ .flags = flags, .value_name_id = value_name_id, .axis_values = record_values } };
                    },
                    else => return error.InvalidTableFormat,
                }
                allocated += 1;
            }
            return result;
        }

        fn fixedToF32(v: i32) f32 {
            return @as(f32, @floatFromInt(v)) / 65536.0;
        }
    };

    pub const COLR = struct {
        pub const BaseGlyph = struct {
            base_glyph_id: u16,
            paint_format: u8,
        };

        pub fn version(data: []const u8) u16 {
            if (data.len < 2) return 0;
            return std.mem.readInt(u16, data[0..2], .big);
        }

        pub fn baseGlyphs(alloc: Allocator, data: []const u8) (Font.ParseError || error{OutOfMemory})![]const BaseGlyph {
            if (version(data) == 0) {
                if (data.len < 8) return error.InvalidTableFormat;
                const num_records = std.mem.readInt(u16, data[2..][0..2], .big);
                const records_offset = std.mem.readInt(u32, data[4..][0..4], .big);
                if (@as(u64, records_offset) + @as(u64, num_records) * 6 > data.len) return error.InvalidTableFormat;
                const result = try alloc.alloc(BaseGlyph, num_records);
                errdefer alloc.free(result);
                for (result, 0..) |*b, i| {
                    const pos = @as(usize, records_offset) + i * 6;
                    if (pos + 2 > data.len) return error.InvalidTableFormat;
                    b.* = .{ .base_glyph_id = std.mem.readInt(u16, data[pos..][0..2], .big), .paint_format = 0 };
                }
                return result;
            }

            if (data.len < 34) return error.InvalidTableFormat;
            const base_glyph_list_offset = std.mem.readInt(u32, data[14..][0..4], .big);
            if (base_glyph_list_offset == 0 or @as(u64, base_glyph_list_offset) + 4 > data.len) return error.InvalidTableFormat;
            const num_records = std.mem.readInt(u32, data[base_glyph_list_offset..][0..4], .big);
            if (@as(u64, base_glyph_list_offset) + 4 + @as(u64, num_records) * 6 > data.len) return error.InvalidTableFormat;

            const result = try alloc.alloc(BaseGlyph, num_records);
            errdefer alloc.free(result);
            for (result, 0..) |*b, i| {
                const pos = base_glyph_list_offset + 4 + i * 6;
                if (pos + 6 > data.len) return error.InvalidTableFormat;
                const glyph_id = std.mem.readInt(u16, data[pos..][0..2], .big);
                const paint_offset = std.mem.readInt(u32, data[pos + 2 ..][0..4], .big);
                const paint_pos = @as(u64, base_glyph_list_offset) + paint_offset;
                if (paint_pos >= data.len) return error.InvalidTableFormat;
                b.* = .{ .base_glyph_id = glyph_id, .paint_format = data[paint_pos] };
            }
            return result;
        }

        pub const LayerV0 = struct { glyph_id: u16, palette_index: u16 };

        /// v0 BaseGlyphRecord lookup by binary search (the array is
        /// required sorted by `glyphID` per spec). Returns the layer
        /// range `[firstLayerIndex, firstLayerIndex+numLayers)` into the
        /// flat LayerRecord array, or `null` if `glyph_id` isn't a v0
        /// color glyph.
        pub fn baseGlyphV0(data: []const u8, glyph_id: u16) Font.ParseError!?struct { first_layer_index: u16, num_layers: u16 } {
            if (data.len < 8) return error.InvalidTableFormat;
            const num_records = std.mem.readInt(u16, data[2..][0..2], .big);
            const records_offset = std.mem.readInt(u32, data[4..][0..4], .big);
            if (@as(u64, records_offset) + @as(u64, num_records) * 6 > data.len) return error.InvalidTableFormat;

            var lo: usize = 0;
            var hi: usize = num_records;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const pos = records_offset + mid * 6;
                const gid = std.mem.readInt(u16, data[pos..][0..2], .big);
                if (gid == glyph_id) {
                    return .{
                        .first_layer_index = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big),
                        .num_layers = std.mem.readInt(u16, data[pos + 4 ..][0..2], .big),
                    };
                }
                if (gid < glyph_id) lo = mid + 1 else hi = mid;
            }
            return null;
        }

        pub fn layerV0At(data: []const u8, first_layer_index: u16, i: u16) Font.ParseError!LayerV0 {
            if (data.len < 14) return error.InvalidTableFormat;
            const layer_records_offset = std.mem.readInt(u32, data[8..][0..4], .big);
            const num_layer_records = std.mem.readInt(u16, data[12..][0..2], .big);
            const index = @as(u32, first_layer_index) + i;
            if (index >= num_layer_records) return error.InvalidTableFormat;
            const pos = layer_records_offset + index * 4;
            if (pos + 4 > data.len) return error.UnexpectedEndOfData;
            return .{
                .glyph_id = std.mem.readInt(u16, data[pos..][0..2], .big),
                .palette_index = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big),
            };
        }

        /// Absolute offset (into `data`) of `glyph_id`'s root Paint
        /// subtable in the v1 BaseGlyphList, or `null` if the table is
        /// v0-only or has no v1 entry for this glyph. Binary search
        /// (BaseGlyphPaintRecord array is sorted by `glyphID` per spec).
        pub fn baseGlyphPaintOffset(data: []const u8, glyph_id: u16) Font.ParseError!?u32 {
            if (version(data) == 0) return null;
            if (data.len < 34) return error.InvalidTableFormat;
            const base_glyph_list_offset = std.mem.readInt(u32, data[14..][0..4], .big);
            if (base_glyph_list_offset == 0) return null;
            if (@as(u64, base_glyph_list_offset) + 4 > data.len) return error.InvalidTableFormat;
            const num_records = std.mem.readInt(u32, data[base_glyph_list_offset..][0..4], .big);
            if (@as(u64, base_glyph_list_offset) + 4 + @as(u64, num_records) * 6 > data.len) return error.InvalidTableFormat;

            var lo: usize = 0;
            var hi: usize = num_records;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const pos = base_glyph_list_offset + 4 + mid * 6;
                const gid = std.mem.readInt(u16, data[pos..][0..2], .big);
                if (gid == glyph_id) {
                    const rel_offset = std.mem.readInt(u32, data[pos + 2 ..][0..4], .big);
                    const abs = base_glyph_list_offset + rel_offset;
                    if (abs >= data.len) return error.UnexpectedEndOfData;
                    return abs;
                }
                if (gid < glyph_id) lo = mid + 1 else hi = mid;
            }
            return null;
        }

        /// Absolute offset of the `i`th layer's Paint subtable within a
        /// PaintColrLayers range starting at `first_layer_index`, from
        /// the v1 LayerList.
        pub fn layerListPaintOffset(data: []const u8, first_layer_index: u32, i: u32) Font.ParseError!u32 {
            if (data.len < 34) return error.InvalidTableFormat;
            const layer_list_offset = std.mem.readInt(u32, data[18..][0..4], .big);
            if (layer_list_offset == 0) return error.InvalidTableFormat;
            if (@as(u64, layer_list_offset) + 4 > data.len) return error.UnexpectedEndOfData;
            const num_layers = std.mem.readInt(u32, data[layer_list_offset..][0..4], .big);
            const index = first_layer_index + i;
            if (index >= num_layers) return error.InvalidTableFormat;
            const pos = layer_list_offset + 4 + index * 4;
            if (pos + 4 > data.len) return error.UnexpectedEndOfData;
            const rel_offset = std.mem.readInt(u32, data[pos..][0..4], .big);
            const abs = layer_list_offset + rel_offset;
            if (abs >= data.len) return error.UnexpectedEndOfData;
            return abs;
        }

        /// Generic bounds-checked reader for a single Paint subtable at
        /// `base` (absolute offset into `data`). Child-paint offsets
        /// (Offset24 fields) are self-relative to `base` — `ttcolr.c`'s
        /// `get_child_table_pointer( colr, paint_base, &p, &child_table_p )`.
        /// Format dispatch and paint-graph traversal semantics live in
        /// rasterization.zig (this reader only does bounds-checked field
        /// access, matching this codebase's GSUB/GPOS `SubtableReader`
        /// split).
        pub const PaintReader = struct {
            data: []const u8,
            base: u32,

            fn need(self: PaintReader, rel: u32, len: u32) Font.ParseError!void {
                if (@as(u64, self.base) + rel + len > self.data.len) return error.UnexpectedEndOfData;
            }

            pub fn format(self: PaintReader) Font.ParseError!u8 {
                try self.need(0, 1);
                return self.data[self.base];
            }

            pub fn u8At(self: PaintReader, rel: u32) Font.ParseError!u8 {
                try self.need(rel, 1);
                return self.data[self.base + rel];
            }

            pub fn i16At(self: PaintReader, rel: u32) Font.ParseError!i16 {
                try self.need(rel, 2);
                return @bitCast(std.mem.readInt(u16, self.data[self.base + rel ..][0..2], .big));
            }

            pub fn u16At(self: PaintReader, rel: u32) Font.ParseError!u16 {
                try self.need(rel, 2);
                return std.mem.readInt(u16, self.data[self.base + rel ..][0..2], .big);
            }

            pub fn i32At(self: PaintReader, rel: u32) Font.ParseError!i32 {
                try self.need(rel, 4);
                return @bitCast(std.mem.readInt(u32, self.data[self.base + rel ..][0..4], .big));
            }

            pub fn u32At(self: PaintReader, rel: u32) Font.ParseError!u32 {
                try self.need(rel, 4);
                return std.mem.readInt(u32, self.data[self.base + rel ..][0..4], .big);
            }

            /// Offset24 (24-bit big-endian) child-paint offset, resolved
            /// to an absolute offset into `data`. `null` for a zero
            /// offset (spec's "absent" sentinel).
            pub fn childOffsetAt(self: PaintReader, rel: u32) Font.ParseError!?u32 {
                try self.need(rel, 3);
                const b = self.data[self.base + rel ..][0..3];
                const off = (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
                if (off == 0) return null;
                const abs = self.base + off;
                if (abs >= self.data.len) return error.UnexpectedEndOfData;
                return abs;
            }

            /// A child paint reader rooted at `abs` (an offset already
            /// resolved via `childOffsetAt`, or any other absolute offset).
            pub fn at(self: PaintReader, abs: u32) PaintReader {
                return .{ .data = self.data, .base = abs };
            }
        };

        pub fn paintAt(data: []const u8, absolute_offset: u32) Font.ParseError!PaintReader {
            if (absolute_offset >= data.len) return error.UnexpectedEndOfData;
            return .{ .data = data, .base = absolute_offset };
        }
    };

    pub const CPAL = struct {
        // NOTE: `extern struct` pins field order to match the on-disk BGRA
        // ColorRecord layout exactly, so paletteColors can hand back a slice
        // that points straight into `data` with no allocation.
        pub const Color = extern struct {
            blue: u8,
            green: u8,
            red: u8,
            alpha: u8,
        };

        pub fn paletteColors(data: []const u8, palette_index: u16) Font.ParseError![]const Color {
            if (data.len < 12) return error.InvalidTableFormat;
            const num_palette_entries = std.mem.readInt(u16, data[2..][0..2], .big);
            const num_palettes = std.mem.readInt(u16, data[4..][0..2], .big);
            if (palette_index >= num_palettes) return error.InvalidTableFormat;
            const color_records_array_offset = std.mem.readInt(u32, data[8..][0..4], .big);

            const idx_pos = 12 + @as(usize, palette_index) * 2;
            if (idx_pos + 2 > data.len) return error.InvalidTableFormat;
            const first_color_index = std.mem.readInt(u16, data[idx_pos..][0..2], .big);

            const start = @as(u64, color_records_array_offset) + @as(u64, first_color_index) * 4;
            const end = start + @as(u64, num_palette_entries) * 4;
            if (end > data.len) return error.InvalidTableFormat;
            const bytes = data[@intCast(start)..@intCast(end)];
            const colors: [*]const Color = @ptrCast(bytes.ptr);
            return colors[0..num_palette_entries];
        }
    };

    /// Embedded color-bitmap strikes (OT spec 5.7.2). Each strike is a
    /// full alphabet rendered at one fixed `ppem`; the renderer picks the
    /// strike matching its target size exactly rather than scaling (this
    /// mirrors FreeType's `ttsbit.c`/`tt_face_load_sbix_image`, which
    /// requires an exact strike match too).
    pub const sbix = struct {
        pub const Strike = struct { ppem: u16, ppi: u16, offset: usize };

        pub const GraphicError = error{
            RecursionLimitExceeded,
            UnsupportedGraphicType,
        };

        /// Decoded, placed glyph image: `image` is 8-bit RGBA (converted
        /// from whatever PNG color type the font used), placement mirrors
        /// FreeType: `bitmap_left = origin_offset_x`,
        /// `bitmap_top = origin_offset_y + image.height`.
        pub const Image = struct {
            image: png.Image,
            origin_offset_x: i16,
            origin_offset_y: i16,

            pub fn deinit(self: Image, alloc: Allocator) void {
                self.image.deinit(alloc);
            }
        };

        pub fn strikeCount(data: []const u8) u32 {
            if (data.len < 8) return 0;
            return std.mem.readInt(u32, data[4..][0..4], .big);
        }

        fn strikeAt(data: []const u8, index: u32) Font.ParseError!Strike {
            const list_pos = 8 + @as(usize, index) * 4;
            if (list_pos + 4 > data.len) return error.UnexpectedEndOfData;
            const offset = std.mem.readInt(u32, data[list_pos..][0..4], .big);
            if (@as(u64, offset) + 4 > data.len) return error.UnexpectedEndOfData;
            return .{
                .ppem = std.mem.readInt(u16, data[offset..][0..2], .big),
                .ppi = std.mem.readInt(u16, data[offset + 2 ..][0..2], .big),
                .offset = offset,
            };
        }

        /// Nearest-strike lookup: sbix strikes are only embedded at a
        /// handful of fixed sizes (e.g. Apple Color Emoji ships {20, 26,
        /// 32, 40, 48, 52, 64, 96, 160}, nothing in between), so real
        /// renderers (CoreText, Skia) pick the smallest strike that's
        /// still >= the requested ppem and scale it down — downscaling
        /// looks better than upscaling a smaller strike. If every strike
        /// is smaller than requested, fall back to the largest available
        /// and scale up. The caller scales the decoded bitmap to the
        /// requested ppem.
        pub fn findStrike(data: []const u8, ppem: u16) Font.ParseError!?Strike {
            const count = strikeCount(data);
            var best: ?Strike = null;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const strike = try strikeAt(data, i);
                if (strike.ppem == 0) continue;
                const b = best orelse {
                    best = strike;
                    continue;
                };
                const strike_fits = strike.ppem >= ppem;
                const best_fits = b.ppem >= ppem;
                if (strike_fits and (!best_fits or strike.ppem < b.ppem)) {
                    best = strike;
                } else if (!strike_fits and !best_fits and strike.ppem > b.ppem) {
                    best = strike;
                }
            }
            return best;
        }

        const RawGraphic = struct {
            origin_offset_x: i16,
            origin_offset_y: i16,
            graphic_type: [4]u8,
            data: []const u8,
        };

        fn rawGraphic(data: []const u8, strike: Strike, glyph_id: u16) Font.ParseError!?RawGraphic {
            const offsets_start = strike.offset + 4;
            const entry_pos = offsets_start + @as(usize, glyph_id) * 4;
            if (entry_pos + 8 > data.len) return error.UnexpectedEndOfData;
            const glyph_start = std.mem.readInt(u32, data[entry_pos..][0..4], .big);
            const glyph_end = std.mem.readInt(u32, data[entry_pos + 4 ..][0..4], .big);
            if (glyph_start == glyph_end) return null;
            if (glyph_start > glyph_end or glyph_end - glyph_start < 8) return error.InvalidTableFormat;

            const record_start = strike.offset + glyph_start;
            const record_end = strike.offset + glyph_end;
            if (record_end > data.len) return error.UnexpectedEndOfData;
            const record = data[record_start..record_end];

            return .{
                .origin_offset_x = std.mem.readInt(i16, record[0..2], .big),
                .origin_offset_y = std.mem.readInt(i16, record[2..4], .big),
                .graphic_type = record[4..8].*,
                .data = record[8..],
            };
        }

        /// Decodes the glyph's image at `strike`, resolving `dupe`/`flip`
        /// indirection (depth-capped, matching FreeType's cap of 4 —
        /// `dupe` chains are attacker-controlled and can otherwise cycle).
        /// Returns `null` if the glyph has no graphic at this strike.
        pub fn decodeGlyph(
            scratch_alloc: Allocator,
            alloc: Allocator,
            data: []const u8,
            strike: Strike,
            glyph_id: u16,
        ) (Font.ParseError || GraphicError || png.DecodeError || error{OutOfMemory})!?Image {
            var current_glyph_id = glyph_id;
            var flipped = false;
            var depth: u8 = 0;
            while (true) {
                const graphic = try rawGraphic(data, strike, current_glyph_id) orelse return null;
                if (std.mem.eql(u8, &graphic.graphic_type, "flip")) {
                    flipped = !flipped;
                    if (depth >= 4) return error.RecursionLimitExceeded;
                    depth += 1;
                    if (graphic.data.len < 2) return error.UnexpectedEndOfData;
                    current_glyph_id = std.mem.readInt(u16, graphic.data[0..2], .big);
                    continue;
                }
                if (std.mem.eql(u8, &graphic.graphic_type, "dupe")) {
                    if (depth >= 4) return error.RecursionLimitExceeded;
                    depth += 1;
                    if (graphic.data.len < 2) return error.UnexpectedEndOfData;
                    current_glyph_id = std.mem.readInt(u16, graphic.data[0..2], .big);
                    continue;
                }
                if (!std.mem.eql(u8, &graphic.graphic_type, "png ")) return error.UnsupportedGraphicType;

                const image = try png.decode(scratch_alloc, alloc, graphic.data);
                if (flipped) mirrorRowsInPlace(image);
                return .{
                    .image = image,
                    .origin_offset_x = graphic.origin_offset_x,
                    .origin_offset_y = graphic.origin_offset_y,
                };
            }
        }

        fn mirrorRowsInPlace(image: png.Image) void {
            var y: usize = 0;
            while (y < image.height) : (y += 1) {
                const row = image.pixels[y * image.width * 4 ..][0 .. image.width * 4];
                var left: usize = 0;
                var right: usize = image.width - 1;
                while (left < right) : ({
                    left += 1;
                    right -= 1;
                }) {
                    const l = row[left * 4 ..][0..4];
                    const r = row[right * 4 ..][0..4];
                    const tmp = l.*;
                    l.* = r.*;
                    r.* = tmp;
                }
            }
        }
    };

    /// Embedded color-bitmap strikes (OT spec 5.7.1/5.7.3), the
    /// `CBLC`+`CBDT` counterpart to `sbix`. Same exact-ppem strike matching
    /// as `sbix` (see `sbix.findStrike`); only image formats 17/18 (small/
    /// big metrics + PNG data) are decoded — the only CBDT record shapes
    /// carrying a PNG payload — and only index subtable formats 1/2/3,
    /// which cover every color-bitmap font seen in practice. Sparse index
    /// formats 4/5 and metrics-in-CBLC image format 19 aren't implemented.
    pub const CBLC = struct {
        pub const Strike = struct {
            ppem_x: u8,
            ppem_y: u8,
            bit_depth: u8,
            index_subtable_array_offset: u32,
            number_of_index_subtables: u32,
        };

        pub const GraphicError = error{
            UnsupportedIndexFormat,
            UnsupportedImageFormat,
        };

        /// Decoded glyph image: `image` is 8-bit RGBA, `hori_bearing_x`/
        /// `hori_bearing_y` are the CBDT record's metrics, used verbatim as
        /// `bitmap_left`/`bitmap_top` (FreeType's `load_sbit_image`, unlike
        /// `sbix`, doesn't add the image height to the y bearing).
        pub const Image = struct {
            image: png.Image,
            hori_bearing_x: i8,
            hori_bearing_y: i8,

            pub fn deinit(self: Image, alloc: Allocator) void {
                self.image.deinit(alloc);
            }
        };

        pub fn strikeCount(data: []const u8) u32 {
            if (data.len < 8) return 0;
            return std.mem.readInt(u32, data[4..][0..4], .big);
        }

        fn strikeAt(data: []const u8, index: u32) Font.ParseError!Strike {
            const pos = 8 + @as(usize, index) * 48;
            if (pos + 48 > data.len) return error.UnexpectedEndOfData;
            return .{
                .index_subtable_array_offset = std.mem.readInt(u32, data[pos..][0..4], .big),
                .number_of_index_subtables = std.mem.readInt(u32, data[pos + 8 ..][0..4], .big),
                .ppem_x = data[pos + 44],
                .ppem_y = data[pos + 45],
                .bit_depth = data[pos + 46],
            };
        }

        /// Exact-match strike lookup, mirroring `sbix.findStrike` (CBLC
        /// strikes aren't scaled to arbitrary sizes either).
        pub fn findStrike(data: []const u8, ppem: u16) Font.ParseError!?Strike {
            const count = strikeCount(data);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const strike = try strikeAt(data, i);
                if (strike.ppem_x == ppem and strike.ppem_y == ppem) return strike;
            }
            return null;
        }

        const IndexSubtableHeader = struct {
            index_format: u16,
            image_format: u16,
            image_data_offset: u32,
            first_glyph_id: u16,
            subtable_pos: usize,
        };

        fn findIndexSubtable(data: []const u8, strike: Strike, glyph_id: u16) Font.ParseError!?IndexSubtableHeader {
            var i: u32 = 0;
            while (i < strike.number_of_index_subtables) : (i += 1) {
                const entry_pos = @as(usize, strike.index_subtable_array_offset) + @as(usize, i) * 8;
                if (entry_pos + 8 > data.len) return error.UnexpectedEndOfData;
                const first_glyph_id = std.mem.readInt(u16, data[entry_pos..][0..2], .big);
                const last_glyph_id = std.mem.readInt(u16, data[entry_pos + 2 ..][0..2], .big);
                const additional_offset = std.mem.readInt(u32, data[entry_pos + 4 ..][0..4], .big);
                if (glyph_id < first_glyph_id or glyph_id > last_glyph_id) continue;

                const subtable_pos = @as(usize, strike.index_subtable_array_offset) + additional_offset;
                if (subtable_pos + 8 > data.len) return error.UnexpectedEndOfData;
                return .{
                    .index_format = std.mem.readInt(u16, data[subtable_pos..][0..2], .big),
                    .image_format = std.mem.readInt(u16, data[subtable_pos + 2 ..][0..2], .big),
                    .image_data_offset = std.mem.readInt(u32, data[subtable_pos + 4 ..][0..4], .big),
                    .first_glyph_id = first_glyph_id,
                    .subtable_pos = subtable_pos,
                };
            }
            return null;
        }

        /// Byte range within `CBDT` for `glyph_id`'s bitmap record. Returns
        /// `null` for glyphs with no bitmap at this strike.
        fn glyphRecordRange(data: []const u8, header: IndexSubtableHeader, glyph_id: u16) (Font.ParseError || GraphicError)!?struct { start: u64, end: u64 } {
            const p = header.subtable_pos + 8;
            var rel_start: u32 = undefined;
            var rel_end: u32 = undefined;
            switch (header.index_format) {
                1 => {
                    const off = p + 4 * @as(usize, glyph_id - header.first_glyph_id);
                    if (off + 8 > data.len) return error.UnexpectedEndOfData;
                    rel_start = std.mem.readInt(u32, data[off..][0..4], .big);
                    rel_end = std.mem.readInt(u32, data[off + 4 ..][0..4], .big);
                    if (rel_start == rel_end) return null;
                },
                2 => {
                    if (p + 4 > data.len) return error.UnexpectedEndOfData;
                    const image_size = std.mem.readInt(u32, data[p..][0..4], .big);
                    const idx = @as(u32, glyph_id - header.first_glyph_id);
                    rel_start = image_size * idx;
                    rel_end = rel_start + image_size;
                },
                3 => {
                    const off = p + 2 * @as(usize, glyph_id - header.first_glyph_id);
                    if (off + 4 > data.len) return error.UnexpectedEndOfData;
                    rel_start = std.mem.readInt(u16, data[off..][0..2], .big);
                    rel_end = std.mem.readInt(u16, data[off + 2 ..][0..2], .big);
                    if (rel_start == rel_end) return null;
                },
                else => return error.UnsupportedIndexFormat,
            }
            if (rel_start > rel_end) return error.InvalidTableFormat;
            return .{
                .start = @as(u64, header.image_data_offset) + rel_start,
                .end = @as(u64, header.image_data_offset) + rel_end,
            };
        }

        /// Decodes the glyph's PNG bitmap at `strike`. Returns `null` if
        /// there's no bitmap for `glyph_id` at this strike.
        pub fn decodeGlyph(
            scratch_alloc: Allocator,
            alloc: Allocator,
            cblc_data: []const u8,
            cbdt_data: []const u8,
            strike: Strike,
            glyph_id: u16,
        ) (Font.ParseError || GraphicError || png.DecodeError || error{OutOfMemory})!?Image {
            const header = try findIndexSubtable(cblc_data, strike, glyph_id) orelse return null;
            const range = try glyphRecordRange(cblc_data, header, glyph_id) orelse return null;
            if (range.start > range.end or range.end > cbdt_data.len) return error.InvalidTableFormat;
            const record = cbdt_data[@intCast(range.start)..@intCast(range.end)];

            const metrics_size: usize = switch (header.image_format) {
                17 => 5,
                18 => 8,
                else => return error.UnsupportedImageFormat,
            };
            if (record.len < metrics_size + 4) return error.UnexpectedEndOfData;
            const hori_bearing_x: i8 = @bitCast(record[2]);
            const hori_bearing_y: i8 = @bitCast(record[3]);

            const png_len = std.mem.readInt(u32, record[metrics_size..][0..4], .big);
            const png_data_start = metrics_size + 4;
            if (@as(u64, png_data_start) + png_len > record.len) return error.UnexpectedEndOfData;
            const png_data = record[png_data_start..][0..png_len];

            const image = try png.decode(scratch_alloc, alloc, png_data);
            return .{ .image = image, .hori_bearing_x = hori_bearing_x, .hori_bearing_y = hori_bearing_y };
        }
    };

    /// Common ScriptList/FeatureList/LookupList header shared verbatim by
    /// GSUB and GPOS (OT spec 1.8.4), used to feed src/shaping.zig's port
    /// of hb-ot-map.cc. Only the parts hb-ot-map.cc actually reads are
    /// implemented: script/langsys/feature selection and per-feature lookup
    /// index lists. Lookup subtables themselves (the GSUB/GPOS apply engine)
    /// are a separate, later port.
    pub const Layout = struct {
        data: []const u8,

        const Header = struct { script_list: usize, feature_list: usize, lookup_list: usize, feature_variations: usize };

        fn header(self: Layout) Font.ParseError!Header {
            var c = Cursor{ .data = self.data };
            _ = try c.readU16(); // majorVersion
            const minor_version = try c.readU16();
            return .{
                .script_list = try c.readU16(),
                .feature_list = try c.readU16(),
                .lookup_list = try c.readU16(),
                .feature_variations = if (minor_version >= 1) try c.readU32() else 0,
            };
        }

        /// Caps condition evaluations per lookup: every record may point at
        /// the same large ConditionSet, which would otherwise make the scan
        /// quadratic in table size.
        const max_condition_evaluations = 1 << 16;

        /// hb's `FeatureVariations::find_index`: the first FeatureVariation
        /// record whose ConditionSet matches `normalized_coords`, or null.
        /// Only ConditionFormat1 (axis range) is evaluated; other formats
        /// never match. Missing coords count as the default (0).
        pub fn findFeatureVariationsIndex(self: Layout, normalized_coords: []const f32) Font.ParseError!?u32 {
            const h = try self.header();
            if (h.feature_variations == 0) return null;
            const data = self.data;
            var c = Cursor{ .data = data, .pos = offsetWithin(data, h.feature_variations, 8) orelse return error.UnexpectedEndOfData };
            _ = try c.readU32(); // version
            const record_count = try c.readU32();
            if (@as(u64, record_count) * 8 > data.len - c.pos) return error.UnexpectedEndOfData;

            var budget: usize = max_condition_evaluations;
            var i: u32 = 0;
            while (i < record_count) : (i += 1) {
                const condition_set_offset = try c.readU32();
                _ = try c.readU32(); // featureTableSubstitutionOffset
                if (condition_set_offset == 0) return i;
                const set_pos = offsetWithin(data, @as(u64, h.feature_variations) + condition_set_offset, 2) orelse return error.UnexpectedEndOfData;
                var sc = Cursor{ .data = data, .pos = set_pos };
                const condition_count = try sc.readU16();
                if (@as(u64, condition_count) * 4 > data.len - sc.pos) return error.UnexpectedEndOfData;
                if (condition_count > budget) return null;
                budget -= condition_count;

                const matched = for (0..condition_count) |_| {
                    const condition_offset = try sc.readU32();
                    const cond_pos = offsetWithin(data, @as(u64, set_pos) + condition_offset, 8) orelse break false;
                    var cc = Cursor{ .data = data, .pos = cond_pos };
                    if (try cc.readU16() != 1) break false;
                    const axis_index = try cc.readU16();
                    const filter_min = try cc.readI16();
                    const filter_max = try cc.readI16();
                    const coord_f: f32 = if (axis_index < normalized_coords.len) std.math.clamp(normalized_coords[axis_index], -1, 1) else 0;
                    const coord: i32 = @intFromFloat(@round(coord_f * 16384));
                    if (coord < filter_min or coord > filter_max) break false;
                } else true;
                if (matched) return i;
            }
            return null;
        }

        /// hb's `get_feature_variation`: absolute offset of the Feature table
        /// that FeatureVariation record `variations_index` substitutes for
        /// `feature_index`, or null to use the FeatureList's own.
        fn substituteFeatureOffset(self: Layout, h: Header, variations_index: u32, feature_index: u16) Font.ParseError!?usize {
            if (h.feature_variations == 0) return null;
            const data = self.data;
            var c = Cursor{ .data = data, .pos = offsetWithin(data, h.feature_variations, 8) orelse return error.UnexpectedEndOfData };
            _ = try c.readU32(); // version
            const record_count = try c.readU32();
            if (variations_index >= record_count) return null;
            c.pos = offsetWithin(data, @as(u64, c.pos) + @as(u64, variations_index) * 8 + 4, 4) orelse return error.UnexpectedEndOfData;
            const substitution_offset = try c.readU32();
            if (substitution_offset == 0) return null;
            const table_pos = offsetWithin(data, @as(u64, h.feature_variations) + substitution_offset, 6) orelse return error.UnexpectedEndOfData;
            var sc = Cursor{ .data = data, .pos = table_pos + 4 };
            const substitution_count = try sc.readU16();
            if (@as(u64, substitution_count) * 6 > data.len - sc.pos) return error.UnexpectedEndOfData;
            for (0..substitution_count) |_| {
                const substituted_index = try sc.readU16();
                const feature_offset = try sc.readU32();
                if (substituted_index != feature_index) continue;
                return offsetWithin(data, @as(u64, table_pos) + feature_offset, 4) orelse return error.UnexpectedEndOfData;
            }
            return null;
        }

        /// Reads a `u16 count` + `(Tag, Offset16)[count]` record list at
        /// `list_start` and returns the absolute offset (relative to
        /// `offset_base`) of the record tagged `tag`, if present. ScriptList/
        /// FeatureList records are offset from their own list start;
        /// Script's LangSysRecord array is offset from the Script table
        /// start (which precedes the record list by 2 bytes) — callers pass
        /// the appropriate `offset_base` for each case.
        fn findTaggedOffset(data: []const u8, list_start: usize, offset_base: usize, tag: Font.Tag) Font.ParseError!?usize {
            var c = Cursor{ .data = data, .pos = list_start };
            const count = try c.readU16();
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                const rec_tag = try c.readBytes(4);
                const rec_offset = try c.readU16();
                if (std.mem.eql(u8, rec_tag, &tag)) {
                    if (rec_offset == 0) return null;
                    const off = offset_base + rec_offset;
                    if (off > data.len) return error.UnexpectedEndOfData;
                    return off;
                }
            }
            return null;
        }

        pub const LangSys = struct {
            data: []const u8,
            offset: usize,

            pub fn requiredFeatureIndex(self: LangSys) Font.ParseError!?u16 {
                var c = Cursor{ .data = self.data, .pos = self.offset + 2 };
                const idx = try c.readU16();
                return if (idx == 0xFFFF) null else idx;
            }

            pub fn featureCount(self: LangSys) Font.ParseError!u16 {
                var c = Cursor{ .data = self.data, .pos = self.offset + 4 };
                return c.readU16();
            }

            pub fn featureIndexAt(self: LangSys, i: u16) Font.ParseError!u16 {
                var c = Cursor{ .data = self.data, .pos = self.offset + 6 + @as(usize, i) * 2 };
                return c.readU16();
            }
        };

        pub const Script = struct {
            data: []const u8,
            offset: usize,

            pub fn defaultLangSys(self: Script) Font.ParseError!?LangSys {
                var c = Cursor{ .data = self.data, .pos = self.offset };
                const off = try c.readU16();
                if (off == 0) return null;
                return .{ .data = self.data, .offset = self.offset + off };
            }

            pub fn findLangSys(self: Script, tag: Font.Tag) Font.ParseError!?LangSys {
                const found = try findTaggedOffset(self.data, self.offset + 2, self.offset, tag);
                return if (found) |off| LangSys{ .data = self.data, .offset = off } else null;
            }
        };

        pub fn findScript(self: Layout, tag: Font.Tag) Font.ParseError!?Script {
            const h = try self.header();
            if (h.script_list == 0) return null;
            const found = try findTaggedOffset(self.data, h.script_list, h.script_list, tag);
            return if (found) |off| Script{ .data = self.data, .offset = off } else null;
        }

        pub fn featureTagAt(self: Layout, feature_index: u16) Font.ParseError!?Font.Tag {
            const h = try self.header();
            if (h.feature_list == 0) return null;
            var c = Cursor{ .data = self.data, .pos = h.feature_list };
            const count = try c.readU16();
            if (feature_index >= count) return null;
            c.pos = h.feature_list + 2 + @as(usize, feature_index) * 6;
            const tag_bytes = try c.readBytes(4);
            return tag_bytes[0..4].*;
        }

        pub fn findFeatureIndex(self: Layout, tag: Font.Tag) Font.ParseError!?u16 {
            const h = try self.header();
            if (h.feature_list == 0) return null;
            var c = Cursor{ .data = self.data, .pos = h.feature_list };
            const count = try c.readU16();
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                const rec_tag = try c.readBytes(4);
                _ = try c.readU16();
                if (std.mem.eql(u8, rec_tag, &tag)) return i;
            }
            return null;
        }

        /// Returns the caller-owned lookup-index list referenced by
        /// FeatureList[feature_index], or by its substitute in FeatureVariation
        /// record `variations_index` (see `findFeatureVariationsIndex`).
        pub fn featureLookups(self: Layout, alloc: Allocator, feature_index: u16, variations_index: ?u32) (Font.ParseError || error{OutOfMemory})![]const u16 {
            const h = try self.header();
            const substitute = if (variations_index) |vi| try self.substituteFeatureOffset(h, vi, feature_index) else null;
            const feature_pos = substitute orelse blk: {
                var c = Cursor{ .data = self.data, .pos = h.feature_list + 2 + @as(usize, feature_index) * 6 };
                _ = try c.readBytes(4); // tag
                break :blk h.feature_list + try c.readU16();
            };
            var fc = Cursor{ .data = self.data, .pos = feature_pos };
            _ = try fc.readU16(); // featureParams offset
            const lookup_count = try fc.readU16();
            if (@as(u64, lookup_count) * 2 > self.data.len - fc.pos) return error.UnexpectedEndOfData;
            const result = try alloc.alloc(u16, lookup_count);
            errdefer alloc.free(result);
            for (result) |*r| r.* = try fc.readU16();
            return result;
        }

        pub fn lookupCount(self: Layout) Font.ParseError!u16 {
            const h = try self.header();
            if (h.lookup_list == 0) return 0;
            var c = Cursor{ .data = self.data, .pos = h.lookup_list };
            return c.readU16();
        }

        /// glyph -> coverage-index lookup (OT spec 1.8.1). Used by every
        /// GSUB/GPOS subtable format to test/rank membership of the glyph
        /// under the cursor.
        pub const Coverage = struct {
            data: []const u8,
            offset: usize,

            fn u16At(self: Coverage, pos: usize) Font.ParseError!u16 {
                var c = Cursor{ .data = self.data, .pos = pos };
                return c.readU16();
            }

            /// Feeds every covered glyph range to `sink.addRange(first, last)`
            /// (comptime duck-typed, no vtable). Used to build the set digests
            /// that let a shaping pass skip lookups it cannot match.
            pub fn collectRanges(self: Coverage, sink: anytype) Font.ParseError!void {
                const format = try self.u16At(self.offset);
                const count = try self.u16At(self.offset + 2);
                switch (format) {
                    1 => {
                        var i: u16 = 0;
                        while (i < count) : (i += 1) {
                            const g = try self.u16At(self.offset + 4 + @as(usize, i) * 2);
                            sink.addRange(g, g);
                        }
                    },
                    2 => {
                        var i: u16 = 0;
                        while (i < count) : (i += 1) {
                            const rec_pos = self.offset + 4 + @as(usize, i) * 6;
                            const start = try self.u16At(rec_pos);
                            const end = try self.u16At(rec_pos + 2);
                            if (start <= end) sink.addRange(start, end);
                        }
                    },
                    else => return error.InvalidTableFormat,
                }
            }

            /// The whole record array is bounds-checked once here, so the
            /// binary search below reads it without a per-probe check --
            /// this runs for every glyph of every subtable application.
            pub fn get(self: Coverage, glyph: u16) Font.ParseError!?u16 {
                return (try self.resolve()).get(glyph);
            }

            /// Validates the header and record array once, so repeated
            /// probes of the same subtable are a bare binary search. Held
            /// per subtable in the shaping plan.
            pub fn resolve(self: Coverage) Font.ParseError!Resolved {
                const format = try self.u16At(self.offset);
                const count = try self.u16At(self.offset + 2);
                const stride: usize = switch (format) {
                    1 => 2,
                    2 => 6,
                    else => return error.InvalidTableFormat,
                };
                return .{
                    .records = try recordArray(self.data, self.offset + 4, count, stride),
                    .format = @intCast(format),
                    .count = count,
                };
            }

            /// A `Coverage` with its header read and its records already
            /// bounds-checked. `format` 0 means "not resolved".
            pub const Resolved = struct {
                records: []const u8 = &.{},
                format: u8 = 0,
                count: u16 = 0,

                pub fn get(self: Resolved, glyph: u16) Font.ParseError!?u16 {
                    const format = self.format;
                    const count = self.count;
                    switch (format) {
                        1 => {
                            const records = self.records;
                            var lo: u16 = 0;
                            var hi: u16 = count;
                            while (lo < hi) {
                                const mid = lo + (hi - lo) / 2;
                                const g = readU16At(records, @as(usize, mid) * 2);
                                if (g == glyph) return mid;
                                if (g < glyph) lo = mid + 1 else hi = mid;
                            }
                            return null;
                        },
                        2 => {
                            const records = self.records;
                            var lo: u16 = 0;
                            var hi: u16 = count;
                            while (lo < hi) {
                                const mid = lo + (hi - lo) / 2;
                                const rec_pos = @as(usize, mid) * 6;
                                const start = readU16At(records, rec_pos);
                                const end = readU16At(records, rec_pos + 2);
                                if (glyph < start) {
                                    hi = mid;
                                    continue;
                                }
                                if (glyph > end) {
                                    lo = mid + 1;
                                    continue;
                                }
                                const index = @as(u32, readU16At(records, rec_pos + 4)) + (glyph - start);
                                if (index > std.math.maxInt(u16)) return error.InvalidTableFormat;
                                return @intCast(index);
                            }
                            return null;
                        },
                        else => return error.InvalidTableFormat,
                    }
                }
            };
        };

        /// `count` fixed-size records at `offset`, bounds- and
        /// overflow-checked once so the caller can index them freely.
        fn recordArray(data: []const u8, offset: usize, count: u16, stride: usize) Font.ParseError![]const u8 {
            const len = @as(usize, count) * stride;
            const end = std.math.add(usize, offset, len) catch return error.UnexpectedEndOfData;
            if (end > data.len) return error.UnexpectedEndOfData;
            return data[offset..end];
        }

        inline fn readU16At(records: []const u8, pos: usize) u16 {
            return std.mem.readInt(u16, records[pos..][0..2], .big);
        }

        /// glyph -> class lookup (OT spec 1.8.2). Used by PairPosFormat2's
        /// class-kerning matrix and (via `Table.Gdef`) to drive lookup-flag
        /// glyph skipping (ignoreBaseGlyphs/ignoreLigatures/ignoreMarks).
        pub const ClassDef = struct {
            data: []const u8,
            offset: usize,

            fn u16At(self: ClassDef, pos: usize) Font.ParseError!u16 {
                var c = Cursor{ .data = self.data, .pos = pos };
                return c.readU16();
            }

            /// Decodes the whole table into a glyph-indexed array, so the
            /// per-glyph lookup is one indexed read instead of a binary
            /// search. The length follows the table's own coverage (never
            /// `maxp`), capped at the format's 64K ceiling.
            pub fn decodeDense(self: ClassDef, allocator: Allocator) (Font.ParseError || error{OutOfMemory})!?[]u8 {
                const format = try self.u16At(self.offset);
                var dense: std.ArrayList(u8) = .empty;
                errdefer dense.deinit(allocator);
                switch (format) {
                    1 => {
                        const start_glyph = try self.u16At(self.offset + 2);
                        const count = try self.u16At(self.offset + 4);
                        if (count == 0) return null;
                        const records = try recordArray(self.data, self.offset + 6, count, 2);
                        try dense.appendNTimes(allocator, 0, @as(usize, start_glyph) + count);
                        for (0..count) |i| {
                            const class = readU16At(records, i * 2);
                            dense.items[start_glyph + i] = if (class > std.math.maxInt(u8)) 0 else @intCast(class);
                        }
                    },
                    2 => {
                        const count = try self.u16At(self.offset + 2);
                        if (count == 0) return null;
                        const records = try recordArray(self.data, self.offset + 4, count, 6);
                        for (0..count) |i| {
                            const start = readU16At(records, i * 6);
                            const end = readU16At(records, i * 6 + 2);
                            const class = readU16At(records, i * 6 + 4);
                            if (end < start or class > std.math.maxInt(u8)) continue;
                            if (dense.items.len <= end) try dense.appendNTimes(allocator, 0, @as(usize, end) + 1 - dense.items.len);
                            @memset(dense.items[start .. @as(usize, end) + 1], @intCast(class));
                        }
                    },
                    else => return error.InvalidTableFormat,
                }
                if (dense.items.len == 0) return null;
                return try dense.toOwnedSlice(allocator);
            }

            /// Returns 0 (the default/unassigned class) for glyphs the table
            /// doesn't cover, matching OT spec semantics.
            pub fn getClass(self: ClassDef, glyph: u16) Font.ParseError!u16 {
                const format = try self.u16At(self.offset);
                switch (format) {
                    1 => {
                        const start_glyph = try self.u16At(self.offset + 2);
                        const count = try self.u16At(self.offset + 4);
                        if (glyph < start_glyph or glyph - start_glyph >= count) return 0;
                        return self.u16At(self.offset + 6 + @as(usize, glyph - start_glyph) * 2);
                    },
                    2 => {
                        const count = try self.u16At(self.offset + 2);
                        const records = try recordArray(self.data, self.offset + 4, count, 6);
                        var lo: u16 = 0;
                        var hi: u16 = count;
                        while (lo < hi) {
                            const mid = lo + (hi - lo) / 2;
                            const rec_pos = @as(usize, mid) * 6;
                            const start = readU16At(records, rec_pos);
                            const end = readU16At(records, rec_pos + 2);
                            if (glyph < start) {
                                hi = mid;
                                continue;
                            }
                            if (glyph > end) {
                                lo = mid + 1;
                                continue;
                            }
                            return readU16At(records, rec_pos + 4);
                        }
                        return 0;
                    },
                    else => return error.InvalidTableFormat,
                }
            }
        };

        /// Lookup header (OT spec 1.8.4 LookupList/Lookup): type, flags, and
        /// the offsets of its subtables. Subtable *contents* are read
        /// through `SubtableReader`, keyed by `lookupType()`, since their
        /// layout is GSUB/GPOS-format-specific and that dispatch lives in
        /// src/shaping.zig's apply engine, not here.
        pub const Lookup = struct {
            data: []const u8,
            offset: usize,

            fn u16At(self: Lookup, pos: usize) Font.ParseError!u16 {
                var c = Cursor{ .data = self.data, .pos = pos };
                return c.readU16();
            }

            pub fn lookupType(self: Lookup) Font.ParseError!u16 {
                return self.u16At(self.offset);
            }

            pub fn lookupFlags(self: Lookup) Font.ParseError!u16 {
                return self.u16At(self.offset + 2);
            }

            pub fn subtableCount(self: Lookup) Font.ParseError!u16 {
                return self.u16At(self.offset + 4);
            }

            pub fn subtableOffset(self: Lookup, index: u16) Font.ParseError!usize {
                const rel = try self.u16At(self.offset + 6 + @as(usize, index) * 2);
                return self.offset + rel;
            }

            pub fn markFilteringSet(self: Lookup) Font.ParseError!?u16 {
                const flags = try self.lookupFlags();
                if (flags & 0x0010 == 0) return null;
                const count = try self.subtableCount();
                return try self.u16At(self.offset + 6 + @as(usize, count) * 2);
            }
        };

        pub fn lookupAt(self: Layout, index: u16) Font.ParseError!Lookup {
            const h = try self.header();
            if (h.lookup_list == 0) return error.InvalidTableFormat;
            var c = Cursor{ .data = self.data, .pos = h.lookup_list };
            const count = try c.readU16();
            if (index >= count) return error.InvalidTableFormat;
            c.pos = h.lookup_list + 2 + @as(usize, index) * 2;
            const rel = try c.readU16();
            return Lookup{ .data = self.data, .offset = h.lookup_list + rel };
        }

        /// Bounds-checked, offset-relative byte access into a single GSUB/
        /// GPOS lookup subtable. Deliberately generic (`u16At`/`i16At` plus
        /// `Offset16`-following helpers) rather than one struct per subtable
        /// format: the subtable formats this port supports (see
        /// shaping.zig's apply engine doc comment) are read directly against
        /// their OT-spec byte layout by the caller, keeping the
        /// attacker-controlled-bytes boundary (this type) free of
        /// substitution/positioning semantics.
        /// Backing bytes for NULL Offset16s (hb's `_hb_NullPool`). Every
        /// count field reads as zero; a read past the end is bounds-checked
        /// like any other.
        const null_table: [64]u8 = @splat(0);

        pub const SubtableReader = struct {
            data: []const u8,
            offset: usize,
            /// This subtable's input Coverage (the Offset16 at rel 2),
            /// resolved once at plan time -- see
            /// `shaping.common.SubtableInfo`. Points into the plan, which
            /// outlives every application. Readers made by `subReaderAt`
            /// deliberately do not inherit it: it describes this subtable.
            cov0: ?*const Coverage.Resolved = null,

            pub fn u16At(self: SubtableReader, rel: usize) Font.ParseError!u16 {
                var c = Cursor{ .data = self.data, .pos = self.offset + rel };
                return c.readU16();
            }

            pub fn i16At(self: SubtableReader, rel: usize) Font.ParseError!i16 {
                var c = Cursor{ .data = self.data, .pos = self.offset + rel };
                return c.readI16();
            }

            pub fn u32At(self: SubtableReader, rel: usize) Font.ParseError!u32 {
                var c = Cursor{ .data = self.data, .pos = self.offset + rel };
                return c.readU32();
            }

            /// Follows an Offset16 field at `rel` (relative to this
            /// subtable's own start, per OT convention) into a fresh reader
            /// based at the target.
            ///
            /// A NULL (zero) offset means "absent", not "the parent": hb
            /// resolves these to its all-zero Null pool, so an omitted
            /// RuleSet reads as zero rules rather than as the subtable
            /// header reinterpreted as one.
            pub fn subReaderAt(self: SubtableReader, rel: usize) Font.ParseError!SubtableReader {
                const off = try self.u16At(rel);
                if (off == 0) return .{ .data = &null_table, .offset = 0 };
                return .{ .data = self.data, .offset = self.offset + off };
            }

            pub fn coverageAt(self: SubtableReader, rel: usize) Font.ParseError!Coverage.Resolved {
                if (rel == 2) if (self.cov0) |c| return c.*;
                const off = try self.u16At(rel);
                const cov = Coverage{ .data = self.data, .offset = self.offset + off };
                return cov.resolve();
            }

            pub fn classDefAt(self: SubtableReader, rel: usize) Font.ParseError!ClassDef {
                const off = try self.u16At(rel);
                return .{ .data = self.data, .offset = self.offset + off };
            }
        };
    };

    /// GDEF glyph-class table (OT spec 'GDEF'), read as far as the three
    /// parts that drive GSUB/GPOS lookup-flag glyph skipping: the glyph
    /// class definition (Base/Ligature/Mark/Component), the mark
    /// attachment class definition (lookupFlag markAttachmentType) and
    /// MarkGlyphSetsDef (lookupFlag useMarkFilteringSet), plus LigCaretList
    /// for caret placement inside ligatures. AttachList/ItemVarStore are
    /// left unread.
    pub const Gdef = struct {
        /// Caret `caret_index` of ligature `glyph` in design units from the
        /// glyph origin, ported from hb LigCaretList::get_lig_carets. Null
        /// unless the glyph lists exactly `caret_count` carets (a mismatch
        /// means its components are not the ones the caller counted) or
        /// the caret is format 2 (contour point, needs the outline).
        /// Format 3's device/variation delta is not applied.
        pub fn ligCaret(data: []const u8, glyph: u16, caret_index: u16, caret_count: u16) Font.ParseError!?i16 {
            var c = Cursor{ .data = data, .pos = 8 };
            const list = try c.readU16();
            if (list == 0) return null;
            c.pos = list;
            const coverage = Layout.Coverage{ .data = data, .offset = list + @as(usize, try c.readU16()) };
            const index = (try coverage.get(glyph)) orelse return null;
            if (index >= try c.readU16()) return null;
            c.pos = list + 4 + @as(usize, index) * 2;
            const lig_glyph = list + @as(usize, try c.readU16());
            c.pos = lig_glyph;
            if (try c.readU16() != caret_count or caret_index >= caret_count) return null;
            c.pos = lig_glyph + 2 + @as(usize, caret_index) * 2;
            c.pos = lig_glyph + @as(usize, try c.readU16());
            const format = try c.readU16();
            if (format != 1 and format != 3) return null;
            return try c.readI16();
        }

        pub fn glyphClassDef(data: []const u8) Font.ParseError!?Layout.ClassDef {
            var c = Cursor{ .data = data, .pos = 4 };
            const off = try c.readU16();
            if (off == 0) return null;
            return .{ .data = data, .offset = off };
        }

        pub fn markAttachClassDef(data: []const u8) Font.ParseError!?Layout.ClassDef {
            var c = Cursor{ .data = data, .pos = 10 };
            const off = try c.readU16();
            if (off == 0) return null;
            return .{ .data = data, .offset = off };
        }

        pub const MarkGlyphSets = struct {
            data: []const u8,
            offset: usize,

            pub fn covers(self: MarkGlyphSets, set_index: u16, glyph: u16) Font.ParseError!bool {
                var c = Cursor{ .data = self.data, .pos = self.offset + 2 };
                const count = try c.readU16();
                if (set_index >= count) return false;
                c.pos = self.offset + 4 + @as(usize, set_index) * 4;
                const rel = try c.readU32();
                const cov_off = std.math.add(usize, self.offset, rel) catch return error.InvalidTableFormat;
                const cov = Layout.Coverage{ .data = self.data, .offset = cov_off };
                return (try cov.get(glyph)) != null;
            }
        };

        /// GDEF 1.3's ItemVariationStore offset, null before 1.3 or when absent.
        pub fn itemVariationStore(data: []const u8) ?u32 {
            if (data.len < 18) return null;
            if (std.mem.readInt(u16, data[2..4], .big) < 3) return null;
            const offset = std.mem.readInt(u32, data[14..18], .big);
            return if (offset == 0 or offset >= data.len) null else offset;
        }

        pub fn markGlyphSets(data: []const u8) Font.ParseError!?MarkGlyphSets {
            var c = Cursor{ .data = data, .pos = 2 };
            const minor = try c.readU16();
            if (minor < 2) return null;
            c.pos = 12;
            const off = try c.readU16();
            if (off == 0) return null;
            return .{ .data = data, .offset = off };
        }
    };
};

const CffIndex = struct {
    count: u32,
    off_size: u8,
    offsets_start: usize,
    data_start: usize,
    base: []const u8,

    fn empty(base: []const u8) CffIndex {
        return .{ .count = 0, .off_size = 0, .offsets_start = 0, .data_start = 0, .base = base };
    }

    fn readOffset(self: CffIndex, i: u32) Font.ParseError!u32 {
        const pos = self.offsets_start + @as(usize, i) * self.off_size;
        if (pos + self.off_size > self.base.len) return error.UnexpectedEndOfData;
        var v: u32 = 0;
        for (0..self.off_size) |k| v = (v << 8) | self.base[pos + k];
        return v;
    }

    pub fn get(self: CffIndex, i: u32) Font.ParseError![]const u8 {
        if (i >= self.count) return error.InvalidTableFormat;
        const off1 = try self.readOffset(i);
        const off2 = try self.readOffset(i + 1);
        if (off1 == 0 or off2 < off1) return error.InvalidTableFormat;
        const start = self.data_start + off1 - 1;
        const end = self.data_start + off2 - 1;
        if (end > self.base.len or start > end) return error.InvalidTableFormat;
        return self.base[start..end];
    }
};

fn readCffIndex(data: []const u8, pos: usize, count_is_u32: bool) Font.ParseError!struct { index: CffIndex, end_pos: usize } {
    var cursor = Cursor{ .data = data, .pos = pos };
    const count: u32 = if (count_is_u32) try cursor.readU32() else try cursor.readU16();
    if (count == 0) return .{ .index = CffIndex.empty(data), .end_pos = cursor.pos };

    const off_size = try cursor.readU8();
    if (off_size == 0 or off_size > 4) return error.InvalidTableFormat;
    const offsets_start = cursor.pos;
    const offset_array_bytes = (@as(u64, count) + 1) * off_size;
    if (offsets_start + offset_array_bytes > data.len) return error.UnexpectedEndOfData;
    cursor.pos = offsets_start + @as(usize, @intCast(offset_array_bytes));
    const data_start = cursor.pos;

    var index = CffIndex{ .count = count, .off_size = off_size, .offsets_start = offsets_start, .data_start = data_start, .base = data };
    const last_off = try index.readOffset(count);
    if (last_off == 0) return error.InvalidTableFormat;
    const end_pos = data_start + last_off - 1;
    if (end_pos > data.len) return error.InvalidTableFormat;
    return .{ .index = index, .end_pos = end_pos };
}

const CffDict = struct {
    charstrings_offset: ?u32 = null,
    private_size: u32 = 0,
    private_offset: u32 = 0,
    fdarray_offset: ?u32 = null,
    fdselect_offset: ?u32 = null,
    is_cid: bool = false,
    vstore_offset: ?u32 = null,
    subrs_offset: ?u32 = null,
};

fn numToU32(v: f64) u32 {
    if (v < 0) return 0;
    if (v > @as(f64, std.math.maxInt(u32))) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

fn parseCffDict(data: []const u8) Font.ParseError!CffDict {
    var result: CffDict = .{};
    var operands: [48]f64 = undefined;
    var n: usize = 0;
    var cursor = Cursor{ .data = data };
    while (!cursor.atEnd()) {
        const b0 = try cursor.readU8();
        if (b0 <= 27) {
            const op: u16 = if (b0 == 12) 1200 + @as(u16, try cursor.readU8()) else b0;
            switch (op) {
                17 => if (n >= 1) {
                    result.charstrings_offset = numToU32(operands[0]);
                },
                18 => if (n >= 2) {
                    result.private_size = numToU32(operands[0]);
                    result.private_offset = numToU32(operands[1]);
                },
                19 => if (n >= 1) {
                    result.subrs_offset = numToU32(operands[0]);
                },
                24 => if (n >= 1) {
                    result.vstore_offset = numToU32(operands[0]);
                },
                1230 => result.is_cid = true,
                1236 => if (n >= 1) {
                    result.fdarray_offset = numToU32(operands[0]);
                },
                1237 => if (n >= 1) {
                    result.fdselect_offset = numToU32(operands[0]);
                },
                else => {},
            }
            n = 0;
        } else {
            const v = try parseDictOperand(&cursor, b0);
            if (n < operands.len) {
                operands[n] = v;
                n += 1;
            }
        }
    }
    return result;
}

fn parseDictOperand(cursor: *Cursor, b0: u8) Font.ParseError!f64 {
    if (b0 >= 32 and b0 <= 246) return @floatFromInt(@as(i32, b0) - 139);
    if (b0 >= 247 and b0 <= 250) {
        const b1 = try cursor.readU8();
        return @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108);
    }
    if (b0 >= 251 and b0 <= 254) {
        const b1 = try cursor.readU8();
        return @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
    }
    if (b0 == 28) return @floatFromInt(try cursor.readI16());
    if (b0 == 29) return @floatFromInt(try cursor.readI32());
    if (b0 == 30) return parseRealNumber(cursor);
    if (b0 == 255) return @as(f64, @floatFromInt(try cursor.readI32())) / 65536.0;
    return error.InvalidTableFormat;
}

fn parseRealNumber(cursor: *Cursor) Font.ParseError!f64 {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    outer: while (true) {
        const byte = try cursor.readU8();
        const nibbles = [2]u4{ @intCast(byte >> 4), @intCast(byte & 0xF) };
        for (nibbles) |nib| {
            switch (nib) {
                0...9 => if (len < buf.len) {
                    buf[len] = '0' + @as(u8, nib);
                    len += 1;
                },
                0xa => if (len < buf.len) {
                    buf[len] = '.';
                    len += 1;
                },
                0xb => if (len < buf.len) {
                    buf[len] = 'E';
                    len += 1;
                },
                0xc => if (len + 1 < buf.len) {
                    buf[len] = 'E';
                    buf[len + 1] = '-';
                    len += 2;
                },
                0xe => if (len < buf.len) {
                    buf[len] = '-';
                    len += 1;
                },
                0xf => break :outer,
                else => {},
            }
        }
    }
    return std.fmt.parseFloat(f64, buf[0..len]) catch 0;
}

fn fdForGlyph(data: []const u8, fdselect_offset: u32, glyph_id: u16) Font.ParseError!u8 {
    var cursor = Cursor{ .data = data, .pos = fdselect_offset };
    const format = try cursor.readU8();
    switch (format) {
        0 => {
            const pos = @as(u64, fdselect_offset) + 1 + glyph_id;
            if (pos >= data.len) return error.UnexpectedEndOfData;
            return data[@intCast(pos)];
        },
        3 => {
            const n_ranges = try cursor.readU16();
            var prev_fd: u8 = 0;
            var i: usize = 0;
            while (i < n_ranges) : (i += 1) {
                const first = try cursor.readU16();
                const fd = try cursor.readU8();
                if (i > 0 and glyph_id < first) return prev_fd;
                prev_fd = fd;
            }
            const sentinel = try cursor.readU16();
            if (glyph_id < sentinel) return prev_fd;
            return error.InvalidTableFormat;
        },
        else => return error.InvalidTableFormat,
    }
}

fn localSubrsFromPrivate(data: []const u8, dict: CffDict, count_is_u32: bool) Font.ParseError!CffIndex {
    if (dict.private_size == 0) return CffIndex.empty(data);
    const private_data = try sliceChecked(data, dict.private_offset, dict.private_size);
    const private_dict = try parseCffDict(private_data);
    const subrs_offset = private_dict.subrs_offset orelse return CffIndex.empty(data);
    return (try readCffIndex(data, dict.private_offset + subrs_offset, count_is_u32)).index;
}

/// CFF Private DICT fields the Adobe (`cf2`) hinting engine needs — blue
/// zones, stem-darkening reference widths, and Type2 nominal/default
/// charstring width. Defaults per the CFF spec (Chapter 15/16); StemSnapH/V
/// are spec fields but `cf2` never reads them (confirmed by grep against
/// `vendor/freetype/src/psaux` — only the classic `pshinter` engine, which
/// this port doesn't implement, uses them), so they're not parsed here.
pub const CffPrivateHints = struct {
    blue_values: [14]f64 = undefined,
    blue_values_count: usize = 0,
    other_blues: [10]f64 = undefined,
    other_blues_count: usize = 0,
    family_blues: [14]f64 = undefined,
    family_blues_count: usize = 0,
    family_other_blues: [10]f64 = undefined,
    family_other_blues_count: usize = 0,
    blue_scale: f64 = 0.039625,
    blue_shift: f64 = 7,
    blue_fuzz: f64 = 1,
    std_hw: f64 = 0,
    std_vw: f64 = 0,
    language_group: i32 = 0,
    nominal_width_x: f64 = 0,
    default_width_x: f64 = 0,
};

fn deltaDecodeInto(buf: []f64, count: *usize, operands: []const f64) void {
    var running: f64 = 0;
    for (operands) |delta| {
        running += delta;
        if (count.* >= buf.len) break;
        buf[count.*] = running;
        count.* += 1;
    }
}

fn parseCffPrivateDict(data: []const u8) Font.ParseError!CffPrivateHints {
    var result: CffPrivateHints = .{};
    var operands: [48]f64 = undefined;
    var n: usize = 0;
    var cursor = Cursor{ .data = data };
    while (!cursor.atEnd()) {
        const b0 = try cursor.readU8();
        if (b0 <= 27) {
            const op: u16 = if (b0 == 12) 1200 + @as(u16, try cursor.readU8()) else b0;
            switch (op) {
                6 => deltaDecodeInto(&result.blue_values, &result.blue_values_count, operands[0..n]),
                7 => deltaDecodeInto(&result.other_blues, &result.other_blues_count, operands[0..n]),
                8 => deltaDecodeInto(&result.family_blues, &result.family_blues_count, operands[0..n]),
                9 => deltaDecodeInto(&result.family_other_blues, &result.family_other_blues_count, operands[0..n]),
                10 => if (n >= 1) {
                    result.std_hw = operands[0];
                },
                11 => if (n >= 1) {
                    result.std_vw = operands[0];
                },
                20 => if (n >= 1) {
                    result.default_width_x = operands[0];
                },
                21 => if (n >= 1) {
                    result.nominal_width_x = operands[0];
                },
                1209 => if (n >= 1) {
                    result.blue_scale = operands[0];
                },
                1210 => if (n >= 1) {
                    result.blue_shift = operands[0];
                },
                1211 => if (n >= 1) {
                    result.blue_fuzz = operands[0];
                },
                1217 => if (n >= 1) {
                    result.language_group = numToU32Signed(operands[0]);
                },
                else => {},
            }
            n = 0;
        } else {
            const v = try parseDictOperand(&cursor, b0);
            if (n < operands.len) {
                operands[n] = v;
                n += 1;
            }
        }
    }
    return result;
}

fn numToU32Signed(v: f64) i32 {
    if (v < @as(f64, std.math.minInt(i32))) return std.math.minInt(i32);
    if (v > @as(f64, std.math.maxInt(i32))) return std.math.maxInt(i32);
    return @intFromFloat(v);
}

/// Private-dict hint fields for the subfont that owns `glyph_id` — resolves
/// CID FDSelect the same way `charstringAndSubrs` does, so callers hinting a
/// CID-keyed CFF font get the right per-glyph-range blue zones/darkening
/// widths, not just the top-level (non-CID) Private dict.
pub fn cffPrivateHintsForGlyph(cff_data: []const u8, glyph_id: u16) Font.ParseError!CffPrivateHints {
    var ctx = try Table.cff.Context.init(cff_data);
    return ctx.privateHints(glyph_id);
}

fn privateHintsFromDict(data: []const u8, dict: CffDict) Font.ParseError!CffPrivateHints {
    if (dict.private_size == 0) return .{};
    return parseCffPrivateDict(try sliceChecked(data, dict.private_offset, dict.private_size));
}

const VstoreContext = struct {
    data: []const u8,
    vstore_offset: ?u32,
};

fn regionCountForVsIndex(ctx: VstoreContext, vsindex: u32) Font.ParseError!u16 {
    const vstore_off = ctx.vstore_offset orelse return 0;
    var cursor = Cursor{ .data = ctx.data, .pos = vstore_off };
    _ = try cursor.readU16();
    const store_start = cursor.pos;
    const format = try cursor.readU16();
    if (format != 1) return error.InvalidTableFormat;
    _ = try cursor.readU32();
    const item_count = try cursor.readU16();
    if (vsindex >= item_count) return error.InvalidTableFormat;
    try cursor.skip(@as(usize, vsindex) * 4);
    const subtable_offset = try cursor.readU32();
    var sub_cursor = Cursor{ .data = ctx.data, .pos = store_start + subtable_offset };
    _ = try sub_cursor.readU16(); // itemCount
    _ = try sub_cursor.readU16(); // wordDeltaCount (long/short-word flag + word count, not the region count)
    return sub_cursor.readU16(); // regionIndexCount
}

fn cubicExtrema(p0: f64, p1: f64, p2: f64, p3: f64, min_v: *f64, max_v: *f64) void {
    min_v.* = @min(min_v.*, @min(p0, p3));
    max_v.* = @max(max_v.*, @max(p0, p3));
    const a = -p0 + 3 * p1 - 3 * p2 + p3;
    const b = 2 * (p0 - 2 * p1 + p2);
    const c = p1 - p0;
    if (@abs(a) < 1e-9) {
        if (@abs(b) > 1e-9) {
            const t = -c / b;
            if (t > 0 and t < 1) evalCubicAt(p0, p1, p2, p3, t, min_v, max_v);
        }
        return;
    }
    const disc = b * b - 4 * a * c;
    if (disc < 0) return;
    const sq = @sqrt(disc);
    const t1 = (-b + sq) / (2 * a);
    const t2 = (-b - sq) / (2 * a);
    if (t1 > 0 and t1 < 1) evalCubicAt(p0, p1, p2, p3, t1, min_v, max_v);
    if (t2 > 0 and t2 < 1) evalCubicAt(p0, p1, p2, p3, t2, min_v, max_v);
}

fn evalCubicAt(p0: f64, p1: f64, p2: f64, p3: f64, t: f64, min_v: *f64, max_v: *f64) void {
    const mt = 1 - t;
    const v = mt * mt * mt * p0 + 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t * p3;
    min_v.* = @min(min_v.*, v);
    max_v.* = @max(max_v.*, v);
}

fn parseCharstringNumber(cursor: *Cursor, b0: u8) Font.ParseError!f64 {
    if (b0 == 28) return @floatFromInt(try cursor.readI16());
    if (b0 == 255) return @as(f64, @floatFromInt(try cursor.readI32())) / 65536.0;
    if (b0 <= 246) return @floatFromInt(@as(i32, b0) - 139);
    if (b0 <= 250) {
        const b1 = try cursor.readU8();
        return @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108);
    }
    const b1 = try cursor.readU8();
    return @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
}

/// Total charstring operators (across every subr call) one glyph may execute.
/// Matches HarfBuzz's `HB_MAX_OPS`; the largest real glyphs land three orders
/// of magnitude below it.
const max_charstring_ops: u32 = 0x40000;

// NOTE: Type2 charstring interpreter that tracks only the glyph's bounding
// box (per plan.md, path extraction belongs to rasterization); shared
// between CFF and CFF2, gated on `is_cff2` since CFF2 charstrings never
// carry a leading width value and add vsindex/blend for variable outlines.
const CharstringInterp = struct {
    global_subrs: CffIndex,
    local_subrs: CffIndex,
    is_cff2: bool,
    vstore: VstoreContext,
    vsindex: u32 = 0,
    /// Region count for `vsindex`, parsed on first `blend` and reused until
    /// a `vsindex` operator changes it — re-reading the ItemVariationStore
    /// header per blend is pure overhead on blend-heavy CFF2 charstrings.
    region_count: ?u16 = null,

    /// CFF2's operand stack is 513 deep (CFF1's is 48); `blend` on a font
    /// with many masters overflows the CFF1 limit, and `push` drops silently
    /// past the end, so sizing to the smaller limit truncates real fonts.
    stack: [513]f64 = undefined,
    sp: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    have_width: bool = false,
    n_stems: u32 = 0,
    depth: u32 = 0,
    /// Depth alone doesn't bound a subr graph that branches: budget the
    /// total operators executed, the way the hinting VM budgets instructions.
    ops: u32 = 0,

    min_x: f64 = std.math.inf(f64),
    min_y: f64 = std.math.inf(f64),
    max_x: f64 = -std.math.inf(f64),
    max_y: f64 = -std.math.inf(f64),

    // Path emission, opt-in via `Table.cff.outline` (bbox-only callers leave
    // this null so they pay no allocation cost).
    emit_alloc: ?Allocator = null,
    emit_segments: ?std.ArrayListUnmanaged(Table.cff.Segment) = null,

    fn init(global_subrs: CffIndex, local_subrs: CffIndex, is_cff2: bool, vstore: VstoreContext) CharstringInterp {
        return .{ .global_subrs = global_subrs, .local_subrs = local_subrs, .is_cff2 = is_cff2, .vstore = vstore };
    }

    /// Charstring coordinates accumulate unbounded deltas, so a hostile
    /// glyph can run them past i32 long before the interpreter's op budget
    /// stops it — and an out-of-range `@intFromFloat` is illegal behavior,
    /// not a wrap.
    fn roundToI32(v: f64) i32 {
        if (v >= @as(f64, std.math.maxInt(i32))) return std.math.maxInt(i32);
        if (v <= @as(f64, std.math.minInt(i32))) return std.math.minInt(i32);
        return @intFromFloat(@round(v));
    }

    fn roundPoint(x: f64, y: f64) Table.cff.Point {
        return .{ .x = roundToI32(x), .y = roundToI32(y) };
    }

    fn emit(self: *CharstringInterp, segment: Table.cff.Segment) error{OutOfMemory}!void {
        const list = self.emit_segments orelse return;
        var mutable_list = list;
        try mutable_list.append(self.emit_alloc.?, segment);
        self.emit_segments = mutable_list;
    }

    fn finalBounds(self: CharstringInterp) Table.cff.Bounds {
        if (self.min_x > self.max_x) return .{ .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 };
        return .{
            .x_min = roundToI32(self.min_x),
            .y_min = roundToI32(self.min_y),
            .x_max = roundToI32(self.max_x),
            .y_max = roundToI32(self.max_y),
        };
    }

    fn push(self: *CharstringInterp, v: f64) void {
        if (self.sp < self.stack.len) {
            self.stack[self.sp] = v;
            self.sp += 1;
        }
    }

    fn clearStack(self: *CharstringInterp) void {
        self.sp = 0;
    }

    fn trackPoint(self: *CharstringInterp, x: f64, y: f64) void {
        self.min_x = @min(self.min_x, x);
        self.max_x = @max(self.max_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_y = @max(self.max_y, y);
    }

    fn moveTo(self: *CharstringInterp, dx: f64, dy: f64) error{OutOfMemory}!void {
        self.x += dx;
        self.y += dy;
        self.trackPoint(self.x, self.y);
        try self.emit(.{ .move_to = roundPoint(self.x, self.y) });
    }

    fn lineTo(self: *CharstringInterp, dx: f64, dy: f64) error{OutOfMemory}!void {
        self.x += dx;
        self.y += dy;
        self.trackPoint(self.x, self.y);
        try self.emit(.{ .line_to = roundPoint(self.x, self.y) });
    }

    fn curveTo(self: *CharstringInterp, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) error{OutOfMemory}!void {
        const x0 = self.x;
        const y0 = self.y;
        const x1 = x0 + dx1;
        const y1 = y0 + dy1;
        const x2 = x1 + dx2;
        const y2 = y1 + dy2;
        const x3 = x2 + dx3;
        const y3 = y2 + dy3;
        self.trackPoint(x0, y0);
        self.trackPoint(x3, y3);
        cubicExtrema(x0, x1, x2, x3, &self.min_x, &self.max_x);
        cubicExtrema(y0, y1, y2, y3, &self.min_y, &self.max_y);
        self.x = x3;
        self.y = y3;
        try self.emit(.{ .curve_to = .{ .c1 = roundPoint(x1, y1), .c2 = roundPoint(x2, y2), .to = roundPoint(x3, y3) } });
    }

    fn maybeStripWidth(self: *CharstringInterp, has_extra: bool) void {
        if (self.is_cff2 or self.have_width) return;
        self.have_width = true;
        if (has_extra and self.sp > 0) {
            var i: usize = 0;
            while (i + 1 < self.sp) : (i += 1) self.stack[i] = self.stack[i + 1];
            self.sp -= 1;
        }
    }

    fn callSubr(self: *CharstringInterp, index: CffIndex, raw: f64) (Font.ParseError || error{OutOfMemory})!void {
        const bias: i64 = if (index.count < 1240) 107 else if (index.count < 33900) 1131 else 32768;
        const idx = @as(i64, @intFromFloat(raw)) + bias;
        if (idx < 0 or idx >= index.count) return error.InvalidTableFormat;
        const sub = try index.get(@intCast(idx));
        try self.run(sub);
    }

    fn doBlend(self: *CharstringInterp) (Font.ParseError || error{OutOfMemory})!void {
        if (self.sp == 0) return error.InvalidTableFormat;
        self.sp -= 1;
        const k_f = self.stack[self.sp];
        if (k_f < 0) return error.InvalidTableFormat;
        const k: usize = @intFromFloat(k_f);
        const region_count = self.region_count orelse blk: {
            const n = try regionCountForVsIndex(self.vstore, self.vsindex);
            self.region_count = n;
            break :blk n;
        };
        const total = k * (1 + @as(usize, region_count));
        if (total > self.sp) return error.InvalidTableFormat;
        self.sp = self.sp - total + k;
    }

    fn hflex(self: *CharstringInterp) (Font.ParseError || error{OutOfMemory})!void {
        if (self.sp < 7) return error.InvalidTableFormat;
        const s = &self.stack;
        try self.curveTo(s[0], 0, s[1], s[2], s[3], 0);
        try self.curveTo(s[4], 0, s[5], -s[2], s[6], 0);
    }

    fn flex(self: *CharstringInterp) (Font.ParseError || error{OutOfMemory})!void {
        if (self.sp < 12) return error.InvalidTableFormat;
        const s = &self.stack;
        try self.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
        try self.curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
    }

    fn hflex1(self: *CharstringInterp) (Font.ParseError || error{OutOfMemory})!void {
        if (self.sp < 9) return error.InvalidTableFormat;
        const s = &self.stack;
        try self.curveTo(s[0], s[1], s[2], s[3], s[4], 0);
        try self.curveTo(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
    }

    fn flex1(self: *CharstringInterp) (Font.ParseError || error{OutOfMemory})!void {
        if (self.sp < 11) return error.InvalidTableFormat;
        const s = &self.stack;
        const dx_sum = s[0] + s[2] + s[4] + s[6] + s[8];
        const dy_sum = s[1] + s[3] + s[5] + s[7] + s[9];
        try self.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
        if (@abs(dx_sum) > @abs(dy_sum)) {
            try self.curveTo(s[6], s[7], s[8], s[9], s[10], -dy_sum);
        } else {
            try self.curveTo(s[6], s[7], s[8], s[9], -dx_sum, s[10]);
        }
    }

    fn run(self: *CharstringInterp, charstring: []const u8) (Font.ParseError || error{OutOfMemory})!void {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 60) return error.RecursionLimitExceeded;

        var cursor = Cursor{ .data = charstring };
        while (!cursor.atEnd()) {
            self.ops += 1;
            if (self.ops > max_charstring_ops) return error.RecursionLimitExceeded;
            const b0 = try cursor.readU8();
            if (b0 >= 32 or b0 == 28) {
                self.push(try parseCharstringNumber(&cursor, b0));
                continue;
            }
            switch (b0) {
                1, 3, 18, 23 => {
                    self.maybeStripWidth(self.sp % 2 == 1);
                    self.n_stems += @intCast(self.sp / 2);
                    self.clearStack();
                },
                19, 20 => {
                    self.maybeStripWidth(self.sp % 2 == 1);
                    self.n_stems += @intCast(self.sp / 2);
                    self.clearStack();
                    try cursor.skip((self.n_stems + 7) / 8);
                },
                21 => {
                    self.maybeStripWidth(self.sp > 2);
                    if (self.sp >= 2) try self.moveTo(self.stack[0], self.stack[1]);
                    self.clearStack();
                },
                22 => {
                    self.maybeStripWidth(self.sp > 1);
                    if (self.sp >= 1) try self.moveTo(self.stack[0], 0);
                    self.clearStack();
                },
                4 => {
                    self.maybeStripWidth(self.sp > 1);
                    if (self.sp >= 1) try self.moveTo(0, self.stack[0]);
                    self.clearStack();
                },
                5 => {
                    var i: usize = 0;
                    while (i + 2 <= self.sp) : (i += 2) try self.lineTo(self.stack[i], self.stack[i + 1]);
                    self.clearStack();
                },
                6, 7 => {
                    var horizontal = b0 == 6;
                    var i: usize = 0;
                    while (i < self.sp) : (i += 1) {
                        if (horizontal) try self.lineTo(self.stack[i], 0) else try self.lineTo(0, self.stack[i]);
                        horizontal = !horizontal;
                    }
                    self.clearStack();
                },
                8 => {
                    var i: usize = 0;
                    while (i + 6 <= self.sp) : (i += 6)
                        try self.curveTo(self.stack[i], self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], self.stack[i + 4], self.stack[i + 5]);
                    self.clearStack();
                },
                24 => {
                    if (self.sp >= 2) {
                        const line_start = self.sp - 2;
                        var i: usize = 0;
                        while (i + 6 <= line_start) : (i += 6)
                            try self.curveTo(self.stack[i], self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], self.stack[i + 4], self.stack[i + 5]);
                        try self.lineTo(self.stack[line_start], self.stack[line_start + 1]);
                    }
                    self.clearStack();
                },
                25 => {
                    if (self.sp >= 6) {
                        const curve_start = self.sp - 6;
                        var i: usize = 0;
                        while (i + 2 <= curve_start) : (i += 2) try self.lineTo(self.stack[i], self.stack[i + 1]);
                        try self.curveTo(self.stack[curve_start], self.stack[curve_start + 1], self.stack[curve_start + 2], self.stack[curve_start + 3], self.stack[curve_start + 4], self.stack[curve_start + 5]);
                    }
                    self.clearStack();
                },
                26 => {
                    var i: usize = 0;
                    var dx1: f64 = 0;
                    if (self.sp % 4 == 1) {
                        dx1 = self.stack[0];
                        i = 1;
                    }
                    var first = true;
                    while (i + 4 <= self.sp) : (i += 4) {
                        try self.curveTo(if (first) dx1 else 0, self.stack[i], self.stack[i + 1], self.stack[i + 2], 0, self.stack[i + 3]);
                        first = false;
                    }
                    self.clearStack();
                },
                27 => {
                    var i: usize = 0;
                    var dy1: f64 = 0;
                    if (self.sp % 4 == 1) {
                        dy1 = self.stack[0];
                        i = 1;
                    }
                    var first = true;
                    while (i + 4 <= self.sp) : (i += 4) {
                        try self.curveTo(self.stack[i], if (first) dy1 else 0, self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], 0);
                        first = false;
                    }
                    self.clearStack();
                },
                30, 31 => {
                    var horizontal = b0 == 31;
                    var i: usize = 0;
                    while (self.sp - i >= 4) {
                        const remaining = self.sp - i;
                        const has_extra = remaining == 5;
                        if (horizontal) {
                            try self.curveTo(self.stack[i], 0, self.stack[i + 1], self.stack[i + 2], if (has_extra) self.stack[i + 4] else 0, self.stack[i + 3]);
                        } else {
                            try self.curveTo(0, self.stack[i], self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], if (has_extra) self.stack[i + 4] else 0);
                        }
                        i += 4;
                        horizontal = !horizontal;
                    }
                    self.clearStack();
                },
                10 => {
                    if (self.sp == 0) return error.InvalidTableFormat;
                    self.sp -= 1;
                    try self.callSubr(self.local_subrs, self.stack[self.sp]);
                },
                29 => {
                    if (self.sp == 0) return error.InvalidTableFormat;
                    self.sp -= 1;
                    try self.callSubr(self.global_subrs, self.stack[self.sp]);
                },
                11 => return,
                14 => {
                    self.maybeStripWidth(self.sp == 1 or self.sp == 5);
                    return;
                },
                15 => {
                    if (self.sp >= 1) {
                        self.vsindex = @intFromFloat(@max(self.stack[0], 0));
                        self.region_count = null;
                    }
                    self.clearStack();
                },
                16 => try self.doBlend(),
                12 => {
                    const b1 = try cursor.readU8();
                    switch (b1) {
                        34 => try self.hflex(),
                        35 => try self.flex(),
                        36 => try self.hflex1(),
                        37 => try self.flex1(),
                        else => {},
                    }
                    self.clearStack();
                },
                else => self.clearStack(),
            }
        }
    }
};
