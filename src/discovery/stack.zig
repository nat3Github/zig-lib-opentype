//! Family-alias resolution: the CSS `font-family` model, where one name
//! stands for an ordered list of real families and a name in that list may
//! itself be an alias. Flattening that graph and merging the flattened
//! stack's cmap coverage are the two halves here; neither needs to know
//! what a caller's font descriptor is beyond its family name and identity.

const std = @import("std");
const parsing = @import("../parsing.zig");

const Cmap = parsing.Table.cmap;

/// Registry of family aliases, and the flatten that turns one into a
/// concrete, duplicate-free family list.
///
/// `Font` is the caller's font descriptor, `Slot` one element of a
/// registered alias list. opentype never interprets either: it asks
/// `Font` for `familyName() []const u8` and `cacheKey() K` (any type
/// `std.meta.eql` can compare), and asks `Slot` for `apply(Font) Font` --
/// which is where a stack whose fonts disagree on size or weight applies
/// its per-family override.
pub fn Aliases(comptime Font: type, comptime Slot: type) type {
    return struct {
        const Self = @This();

        /// Registered alias name -> its ordered list, most-preferred
        /// first. Keys and values are owned; see `put`/`deinit`.
        map: std.StringHashMapUnmanaged([]const Slot) = .empty,

        pub const max_depth = 128;
        /// Depth alone doesn't bound the flatten: `A -> [A, A]` fans out
        /// 2^depth calls. This caps alias expansions per stack instead.
        pub const max_expansions = 256;
        /// `Cmap.FallbackStack` indexes stack entries with a u8, and a
        /// flatten is a fixed buffer so it needs no allocator.
        pub const max_families = 64;

        /// A flattened stack: concrete families, most-preferred first,
        /// each appearing once at its earliest position.
        pub const Flattened = struct {
            fonts: [max_families]Font = undefined,
            len: u8 = 0,
            expansions: u16 = 0,
            /// A budget stopped the walk, so the list is a prefix of what
            /// the aliases actually name. Callers warn on this; opentype
            /// has no business logging.
            hit_limit: bool = false,

            pub fn slice(self: *const Flattened) []const Font {
                return self.fonts[0..self.len];
            }
        };

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.map.iterator();
            while (it.next()) |kv| {
                gpa.free(kv.key_ptr.*);
                gpa.free(kv.value_ptr.*);
            }
            self.map.deinit(gpa);
        }

        pub fn get(self: *const Self, family: []const u8) ?[]const Slot {
            return self.map.get(family);
        }

        pub fn count(self: *const Self) u32 {
            return self.map.count();
        }

        /// Registered alias names, unordered.
        pub fn keyIterator(self: *const Self) @FieldType(Self, "map").KeyIterator {
            return self.map.keyIterator();
        }

        /// Register (or replace) `alias`. `slots` is copied. Returns true
        /// if an existing list was replaced, which invalidates anything
        /// the caller flattened earlier.
        pub fn put(
            self: *Self,
            gpa: std.mem.Allocator,
            alias: []const u8,
            slots: []const Slot,
        ) std.mem.Allocator.Error!bool {
            std.debug.assert(slots.len >= 1);
            const list = try gpa.dupe(Slot, slots);
            errdefer gpa.free(list);

            if (self.map.getEntry(alias)) |e| {
                gpa.free(e.value_ptr.*);
                e.value_ptr.* = list;
                return true;
            }
            const owned_key = try gpa.dupe(u8, alias);
            errdefer gpa.free(owned_key);
            try self.map.put(gpa, owned_key, list);
            return false;
        }

        /// The graph walk: depth-first, most-preferred first, cut off by
        /// either budget so a cycle terminates. A family reached twice
        /// keeps its first position, so a diamond of aliases lists it
        /// once.
        pub fn flatten(self: *const Self, font: Font) Flattened {
            var out: Flattened = .{};
            self.walk(&out, font, 0);
            return out;
        }

        fn walk(self: *const Self, out: *Flattened, font: Font, depth: u8) void {
            const list = self.map.get(font.familyName()) orelse {
                if (out.len == max_families) return;
                const key = font.cacheKey();
                for (out.slice()) |existing| if (std.meta.eql(existing.cacheKey(), key)) return;
                out.fonts[out.len] = font;
                out.len += 1;
                return;
            };
            if (depth == max_depth or out.expansions == max_expansions) {
                out.hit_limit = true;
                return;
            }
            out.expansions += 1;
            for (list) |slot| self.walk(out, slot.apply(font), depth + 1);
        }

        /// The one family an alias stands for when there is no stack to
        /// resolve against -- its first, followed through nesting. A
        /// cycle stops at `max_depth`.
        pub fn firstFamily(self: *const Self, font: Font) Font {
            var current = font;
            var depth: u8 = 0;
            while (depth < max_depth) : (depth += 1) {
                const list = self.map.get(current.familyName()) orelse break;
                current = list[0].apply(current);
            }
            return current;
        }
    };
}

/// Merged cmap coverage per flattened stack: which stack slot, if any,
/// covers a given codepoint.
///
/// Keyed by a caller-computed `u64` that must be *size-independent* --
/// `FallbackStack.build` sorts every cmap range of every family in the
/// stack, and that answer is the same at every size, so one entry serves
/// a stack at 12pt and at 24pt. Owns every `FallbackStack` it hands out;
/// callers borrow.
pub const CoverageCache = struct {
    map: std.AutoHashMapUnmanaged(u64, Cmap.FallbackStack) = .empty,

    pub fn deinit(self: *CoverageCache, gpa: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |fb| fb.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn get(self: *const CoverageCache, key: u64) ?Cmap.FallbackStack {
        return self.map.get(key);
    }

    /// Coverage of `fonts` (a flattened stack, most-preferred first),
    /// built and cached on a miss. Earlier fonts win an overlap.
    pub fn getOrBuild(
        self: *CoverageCache,
        gpa: std.mem.Allocator,
        key: u64,
        fonts: []const parsing.Font,
    ) std.mem.Allocator.Error!Cmap.FallbackStack {
        if (self.map.get(key)) |existing| return existing;

        const per_font = try gpa.alloc([]Cmap.Range, fonts.len);
        defer gpa.free(per_font);
        var built: usize = 0;
        defer for (per_font[0..built]) |r| gpa.free(r);

        for (fonts) |font| {
            const cmap_data = font.tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
            per_font[built] = try Cmap.coverageRanges(cmap_data, gpa);
            built += 1;
        }

        var stack = try Cmap.FallbackStack.build(gpa, per_font[0..built]);
        errdefer stack.deinit(gpa);
        try self.map.put(gpa, key, stack);
        return stack;
    }
};
