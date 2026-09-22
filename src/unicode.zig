// Derived from HarfBuzz (Old MIT), unicode-linebreak (Apache-2.0) and ICU4X (Unicode-3.0); see THIRD_PARTY_LICENSES.
const std = @import("std");
const tables = @import("unicode/tables.zig");

// `std.mem.sort` (WikiSort) monomorphizes to ~15KiB per (T, lessThan) pair
// and is tuned for large arrays; every call site here sorts short-lived
// lists (bracket pairs, a few dozen entries), where insertion sort is both
// smaller and measurably faster.
fn insertionSort(comptime T: type, items: []T, context: anytype, comptime lessThan: fn (@TypeOf(context), T, T) bool) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j: usize = i;
        while (j > 0 and lessThan(context, key, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

// NOTE: property tables are pre-generated (not comptime-parsed) by
// test/fixtures/unicode/gen/gen_tables.py from the pinned UCD data; see
// src/unicode/tables.zig. Re-run that script after bumping the pinned
// Unicode version.
// Property tables are [N]u32 of (start << 8) | class, sorted by start; an
// entry runs until the next entry's start, and `no_class` marks a gap. See
// the header comment in unicode/tables.zig.
const no_class: u8 = 0xFF;

fn packedLookup(table: []const u32, codepoint: u21) u8 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (codepoint < table[mid] >> 8) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    if (lo == 0) return no_class;
    return @truncate(table[lo - 1]);
}

fn packedContains(table: []const u32, codepoint: u21) bool {
    return packedLookup(table, codepoint) == 1;
}

pub const BidiClass = enum {
    l,
    r,
    al,
    en,
    es,
    et,
    an,
    cs,
    nsm,
    bn,
    b,
    s,
    ws,
    on,
    lre,
    lro,
    rle,
    rlo,
    pdf,
    lri,
    rli,
    fsi,
    pdi,

    pub fn of(codepoint: u21) BidiClass {
        const class = packedLookup(&tables.bidi_class_ranges, codepoint);
        if (class == no_class) return .l;
        return @enumFromInt(class);
    }
};

const max_explicit_depth: u8 = 125;

fn nextOddLevel(level: u8) u8 {
    return if (level % 2 == 0) level + 1 else level + 2;
}

fn nextEvenLevel(level: u8) u8 {
    return if (level % 2 == 0) level + 2 else level + 1;
}

fn isIsolateInitiator(c: BidiClass) bool {
    return c == .lri or c == .rli or c == .fsi;
}

// BD8/P2: first strong directional type (L, R, or AL) in `classes`,
// skipping the contents of any nested isolates.
pub fn firstStrongDirection(classes: []const BidiClass) ?BidiClass {
    var isolate_depth: usize = 0;
    for (classes) |c| {
        if (isIsolateInitiator(c)) {
            isolate_depth += 1;
        } else if (c == .pdi) {
            if (isolate_depth > 0) isolate_depth -= 1;
        } else if (isolate_depth == 0 and (c == .l or c == .r or c == .al)) {
            return c;
        }
    }
    return null;
}

// BD9: index of the PDI matching the isolate initiator at `start`, or
// classes.len if unmatched.
fn matchingPdiIndex(classes: []const BidiClass, start: usize) usize {
    var depth: usize = 1;
    var j = start + 1;
    while (j < classes.len) : (j += 1) {
        if (isIsolateInitiator(classes[j])) {
            depth += 1;
        } else if (classes[j] == .pdi) {
            depth -= 1;
            if (depth == 0) return j;
        }
    }
    return classes.len;
}

fn fsiActsAsRtl(classes: []const BidiClass, fsi_index: usize) bool {
    const end = matchingPdiIndex(classes, fsi_index);
    const strong = firstStrongDirection(classes[fsi_index + 1 .. end]);
    return if (strong) |s| s != .l else false;
}

const ExplicitOverride = enum { neutral, ltr, rtl };
const ExplicitStackEntry = struct { level: u8, override: ExplicitOverride, isolate: bool };

fn strongOrNeutral(c: BidiClass) ?BidiClass {
    return switch (c) {
        .l => .l,
        .r, .en, .an => .r,
        else => null,
    };
}

fn isNeutralOrIsolateFormatting(c: BidiClass) bool {
    return switch (c) {
        .b, .s, .ws, .on, .fsi, .lri, .rli, .pdi => true,
        else => false,
    };
}

fn isRemovedByX9(c: BidiClass) bool {
    return c == .bn;
}

fn isL1Invisible(c: BidiClass) bool {
    return switch (c) {
        .ws, .lri, .rli, .fsi, .pdi, .lre, .rle, .lro, .rlo, .pdf, .bn => true,
        else => false,
    };
}

// BD16: U+2329/U+232A are canonically equivalent to U+3008/U+3009 and must
// match against either spelling when pairing brackets. This is the only
// canonical-singleton case among paired brackets in Unicode, so it's
// handled as a direct mapping rather than a general normalization pass.
fn canonicalBracket(codepoint: u21) u21 {
    return switch (codepoint) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => codepoint,
    };
}

fn bracketPairOf(codepoint: u21) ?tables.BidiBracketPair {
    var lo: usize = 0;
    var hi: usize = tables.bidi_bracket_pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = tables.bidi_bracket_pairs[mid];
        if (codepoint < entry.codepoint) {
            hi = mid;
        } else if (codepoint > entry.codepoint) {
            lo = mid + 1;
        } else {
            return entry;
        }
    }
    return null;
}

// UAX #9 rules W1-N2 (weak/neutral type resolution), applied over one
// isolating run sequence. `seq` holds original-text indices in logical
// order; `work` is the mutable per-character class array shared across the
// whole paragraph; `original` is the pristine input (needed by N0 to spot
// NSM runs that should follow a resolved bracket).
fn resolveIsolatingRunSequence(
    arena: std.mem.Allocator,
    work: []BidiClass,
    original: []const BidiClass,
    codepoints: ?[]const u21,
    levels: []u8,
    seq: []const usize,
    seq_level: u8,
    sos: BidiClass,
    eos: BidiClass,
) std.mem.Allocator.Error!void {
    // W1
    {
        var prev: BidiClass = sos;
        for (seq) |idx| {
            if (work[idx] == .nsm) {
                work[idx] = switch (prev) {
                    .lri, .rli, .fsi, .pdi => .on,
                    else => prev,
                };
            }
            prev = work[idx];
        }
    }
    // W2
    {
        var strong: BidiClass = sos;
        for (seq) |idx| {
            switch (work[idx]) {
                .l, .r, .al => strong = work[idx],
                .en => if (strong == .al) {
                    work[idx] = .an;
                },
                else => {},
            }
        }
    }
    // W3
    for (seq) |idx| {
        if (work[idx] == .al) work[idx] = .r;
    }
    // W4
    if (seq.len >= 3) {
        var j: usize = 1;
        while (j + 1 < seq.len) : (j += 1) {
            const prev_c = work[seq[j - 1]];
            const cur_c = work[seq[j]];
            const next_c = work[seq[j + 1]];
            if (cur_c == .es and prev_c == .en and next_c == .en) work[seq[j]] = .en;
            if (cur_c == .cs and prev_c == .en and next_c == .en) work[seq[j]] = .en;
            if (cur_c == .cs and prev_c == .an and next_c == .an) work[seq[j]] = .an;
        }
    }
    // W5
    {
        var j: usize = 0;
        while (j < seq.len) {
            if (work[seq[j]] == .et) {
                var k = j;
                while (k < seq.len and work[seq[k]] == .et) k += 1;
                const before_en = j > 0 and work[seq[j - 1]] == .en;
                const after_en = k < seq.len and work[seq[k]] == .en;
                if (before_en or after_en) {
                    var m = j;
                    while (m < k) : (m += 1) work[seq[m]] = .en;
                }
                j = k;
            } else j += 1;
        }
    }
    // W6
    for (seq) |idx| {
        switch (work[idx]) {
            .es, .et, .cs => work[idx] = .on,
            else => {},
        }
    }
    // W7
    {
        var strong: BidiClass = sos;
        for (seq) |idx| {
            switch (work[idx]) {
                .l, .r => strong = work[idx],
                .en => if (strong == .l) {
                    work[idx] = .l;
                },
                else => {},
            }
        }
    }

    // N0: paired bracket resolution (BD16 stack matching). Needs the
    // original codepoints (bracket pairing is per-character, not
    // per-class); skipped entirely when the caller has none (e.g. the
    // synthetic class-only BidiTest.txt conformance cases).
    if (codepoints) |cps| {
        const BracketStackEntry = struct { expected_close: u21, seq_pos: usize };
        var stack: [63]BracketStackEntry = undefined;
        var stack_len: usize = 0;

        const Pair = struct { open: usize, close: usize };
        var pairs: std.ArrayList(Pair) = .empty;

        for (seq, 0..) |idx, pos| {
            if (work[idx] != .on) continue;
            const bracket = bracketPairOf(cps[idx]) orelse continue;
            if (bracket.is_open) {
                // BD16: on stack overflow, stop pair identification for the
                // rest of the isolating run sequence entirely (not just
                // this bracket).
                if (stack_len == stack.len) break;
                stack[stack_len] = .{ .expected_close = canonicalBracket(bracket.paired_with), .seq_pos = pos };
                stack_len += 1;
            } else {
                var k = stack_len;
                while (k > 0) {
                    k -= 1;
                    if (stack[k].expected_close == canonicalBracket(cps[idx])) {
                        try pairs.append(arena, .{ .open = stack[k].seq_pos, .close = pos });
                        stack_len = k;
                        break;
                    }
                }
            }
        }

        insertionSort(Pair, pairs.items, {}, struct {
            fn lessThan(_: void, a: Pair, b: Pair) bool {
                return a.open < b.open;
            }
        }.lessThan);

        const embedding: BidiClass = if (seq_level % 2 == 0) .l else .r;
        const opposite: BidiClass = if (embedding == .l) .r else .l;

        for (pairs.items) |pair| {
            var found_embedding = false;
            var found_opposite = false;
            var k = pair.open + 1;
            while (k < pair.close) : (k += 1) {
                const norm = strongOrNeutral(work[seq[k]]) orelse continue;
                if (norm == embedding) {
                    found_embedding = true;
                    break;
                }
                found_opposite = true;
            }

            var resolved: ?BidiClass = null;
            if (found_embedding) {
                resolved = embedding;
            } else if (found_opposite) {
                var preceding: BidiClass = sos;
                var k2 = pair.open;
                while (k2 > 0) {
                    k2 -= 1;
                    if (strongOrNeutral(work[seq[k2]])) |norm| {
                        preceding = norm;
                        break;
                    }
                }
                resolved = if (preceding == opposite) opposite else embedding;
            }

            if (resolved) |r| {
                work[seq[pair.open]] = r;
                work[seq[pair.close]] = r;
                for ([_]usize{ pair.open, pair.close }) |bracket_pos| {
                    var k3 = bracket_pos + 1;
                    while (k3 < seq.len and original[seq[k3]] == .nsm) : (k3 += 1) {
                        work[seq[k3]] = r;
                    }
                }
            }
        }
    }

    // N1/N2
    {
        const embedding: BidiClass = if (seq_level % 2 == 0) .l else .r;
        var j: usize = 0;
        while (j < seq.len) {
            if (isNeutralOrIsolateFormatting(work[seq[j]])) {
                var k = j;
                while (k < seq.len and isNeutralOrIsolateFormatting(work[seq[k]])) k += 1;
                const before = if (j > 0) (strongOrNeutral(work[seq[j - 1]]) orelse embedding) else (strongOrNeutral(sos) orelse embedding);
                const after = if (k < seq.len) (strongOrNeutral(work[seq[k]]) orelse embedding) else (strongOrNeutral(eos) orelse embedding);
                const resolved = if (before == after) before else embedding;
                var m = j;
                while (m < k) : (m += 1) work[seq[m]] = resolved;
                j = k;
            } else j += 1;
        }
    }

    // I1/I2
    for (seq) |idx| {
        if (levels[idx] % 2 == 0) {
            switch (work[idx]) {
                .r => levels[idx] += 1,
                .an, .en => levels[idx] += 2,
                else => {},
            }
        } else {
            switch (work[idx]) {
                .l, .en, .an => levels[idx] += 1,
                else => {},
            }
        }
    }
}

// Under a level-0 paragraph every one of these resolves to level 0: no
// strong RTL, no numbers (I1 lifts EN/AN by two even at an even level) and
// no explicit directional control that could push the stack off level 0.
fn everyClassResolvesToLevelZero(classes: []const BidiClass) bool {
    for (classes) |c| switch (c) {
        .l, .es, .et, .cs, .nsm, .bn, .b, .s, .ws, .on => {},
        .r, .al, .en, .an, .lre, .lro, .rle, .rlo, .pdf, .lri, .rli, .fsi, .pdi => return false,
    };
    return true;
}

pub const Bidi = struct {
    pub const ParagraphDirection = enum { auto, ltr, rtl };

    pub const Error = error{InvalidExplicitEmbeddingNesting};

    // UAX #9 rules P2-I2: resolve one explicit + implicit level per input
    // codepoint. `classes` and the returned slice are parallel to the
    // input text. Characters removed by rule X9 (BN and the explicit
    // embedding/override initiators/PDF) keep a level (that of the
    // preceding non-removed character, or the paragraph level) rather than
    // being dropped from the output, so the returned slice stays parallel
    // to `classes`.
    pub fn paragraphEmbeddingLevels(
        allocator: std.mem.Allocator,
        classes: []const BidiClass,
        base_direction: ParagraphDirection,
        codepoints: ?[]const u21,
    ) (Error || std.mem.Allocator.Error)![]u8 {
        const n = classes.len;
        const result = try allocator.alloc(u8, n);
        errdefer allocator.free(result);
        if (n == 0) return result;

        if (base_direction != .rtl and everyClassResolvesToLevelZero(classes)) {
            @memset(result, 0);
            return result;
        }

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const paragraph_level: u8 = switch (base_direction) {
            .ltr => 0,
            .rtl => 1,
            .auto => blk: {
                const strong = firstStrongDirection(classes);
                break :blk if (strong) |s| (if (s == .l) @as(u8, 0) else @as(u8, 1)) else 0;
            },
        };

        const work = try arena.alloc(BidiClass, n);
        @memcpy(work, classes);
        const levels = try arena.alloc(u8, n);

        // X1-X8: explicit embedding/override/isolate levels.
        var stack: [max_explicit_depth + 2]ExplicitStackEntry = undefined;
        stack[0] = .{ .level = paragraph_level, .override = .neutral, .isolate = false };
        var stack_len: usize = 1;
        var overflow_isolate_count: usize = 0;
        var overflow_embedding_count: usize = 0;
        var valid_isolate_count: usize = 0;

        for (classes, 0..) |c, i| {
            switch (c) {
                .rle, .lre, .rlo, .lro => {
                    const top = stack[stack_len - 1];
                    levels[i] = top.level;
                    work[i] = .bn;
                    const new_level = if (c == .rle or c == .rlo) nextOddLevel(top.level) else nextEvenLevel(top.level);
                    const override: ExplicitOverride = switch (c) {
                        .lro => .ltr,
                        .rlo => .rtl,
                        else => .neutral,
                    };
                    if (new_level <= max_explicit_depth and overflow_isolate_count == 0 and overflow_embedding_count == 0) {
                        stack[stack_len] = .{ .level = new_level, .override = override, .isolate = false };
                        stack_len += 1;
                    } else if (overflow_isolate_count == 0) {
                        overflow_embedding_count += 1;
                    }
                },
                .rli, .lri, .fsi => {
                    const top = stack[stack_len - 1];
                    levels[i] = top.level;
                    if (top.override != .neutral) work[i] = if (top.override == .ltr) .l else .r;
                    const acts_rtl = if (c == .fsi) fsiActsAsRtl(classes, i) else c == .rli;
                    const new_level = if (acts_rtl) nextOddLevel(top.level) else nextEvenLevel(top.level);
                    if (new_level <= max_explicit_depth and overflow_isolate_count == 0 and overflow_embedding_count == 0) {
                        valid_isolate_count += 1;
                        stack[stack_len] = .{ .level = new_level, .override = .neutral, .isolate = true };
                        stack_len += 1;
                    } else {
                        overflow_isolate_count += 1;
                    }
                },
                .pdi => {
                    if (overflow_isolate_count > 0) {
                        overflow_isolate_count -= 1;
                    } else if (valid_isolate_count > 0) {
                        overflow_embedding_count = 0;
                        while (!stack[stack_len - 1].isolate) : (stack_len -= 1) {}
                        stack_len -= 1;
                        valid_isolate_count -= 1;
                    }
                    const top = stack[stack_len - 1];
                    levels[i] = top.level;
                    if (top.override != .neutral) work[i] = if (top.override == .ltr) .l else .r;
                },
                .pdf => {
                    if (overflow_isolate_count > 0) {
                        // no-op
                    } else if (overflow_embedding_count > 0) {
                        overflow_embedding_count -= 1;
                    } else if (stack_len >= 2 and !stack[stack_len - 1].isolate) {
                        stack_len -= 1;
                    }
                    levels[i] = stack[stack_len - 1].level;
                    work[i] = .bn;
                },
                .b => {
                    stack[0] = .{ .level = paragraph_level, .override = .neutral, .isolate = false };
                    stack_len = 1;
                    overflow_isolate_count = 0;
                    overflow_embedding_count = 0;
                    valid_isolate_count = 0;
                    levels[i] = paragraph_level;
                },
                .bn => levels[i] = stack[stack_len - 1].level,
                else => {
                    const top = stack[stack_len - 1];
                    levels[i] = top.level;
                    if (top.override != .neutral) work[i] = if (top.override == .ltr) .l else .r;
                },
            }
        }

        // X9: indices of characters not removed (retained for W/N/I rules).
        var run_indices: std.ArrayList(usize) = .empty;
        for (0..n) |i| {
            if (!isRemovedByX9(work[i])) try run_indices.append(arena, i);
        }

        // BD7: level runs are maximal same-level stretches of run_indices.
        const Run = struct { filtered_start: usize, filtered_end: usize, level: u8 };
        var runs: std.ArrayList(Run) = .empty;
        {
            var k: usize = 0;
            while (k < run_indices.items.len) {
                const lvl = levels[run_indices.items[k]];
                var j = k;
                while (j < run_indices.items.len and levels[run_indices.items[j]] == lvl) j += 1;
                try runs.append(arena, .{ .filtered_start = k, .filtered_end = j, .level = lvl });
                k = j;
            }
        }

        // sos/eos (X10) must be computed from the explicit (X1-X8) levels,
        // not the levels array as later mutated in place by I1/I2 below —
        // otherwise a run processed after an adjacent one would see that
        // neighbor's already-bumped implicit level instead of its original
        // embedding level.
        const explicit_levels = try arena.dupe(u8, levels);

        // BD13/X10: chain level runs into isolating run sequences via
        // matching isolate initiator -> PDI links.
        const run_start_sentinel = runs.items.len;
        const run_id_starting_at = try arena.alloc(usize, n + 1);
        @memset(run_id_starting_at, run_start_sentinel);
        for (runs.items, 0..) |run, run_id| {
            run_id_starting_at[run_indices.items[run.filtered_start]] = run_id;
        }
        const next_run = try arena.alloc(usize, runs.items.len);
        @memset(next_run, run_start_sentinel);
        const is_continuation = try arena.alloc(bool, runs.items.len);
        @memset(is_continuation, false);
        for (runs.items, 0..) |run, run_id| {
            const last_idx = run_indices.items[run.filtered_end - 1];
            if (isIsolateInitiator(classes[last_idx])) {
                const pdi_idx = matchingPdiIndex(classes, last_idx);
                if (pdi_idx < n) {
                    const follower = run_id_starting_at[pdi_idx];
                    if (follower != run_start_sentinel) {
                        next_run[run_id] = follower;
                        is_continuation[follower] = true;
                    }
                }
            }
        }

        for (runs.items, 0..) |first_run, run_id| {
            if (is_continuation[run_id]) continue;

            var seq: std.ArrayList(usize) = .empty;
            var cur = run_id;
            var last_run = first_run;
            while (true) {
                const run = runs.items[cur];
                last_run = run;
                for (run_indices.items[run.filtered_start..run.filtered_end]) |idx| {
                    try seq.append(arena, idx);
                }
                if (next_run[cur] == run_start_sentinel) break;
                cur = next_run[cur];
            }

            const seq_level = first_run.level;
            const preceding_level = if (first_run.filtered_start > 0)
                explicit_levels[run_indices.items[first_run.filtered_start - 1]]
            else
                paragraph_level;

            const last_idx = seq.items[seq.items.len - 1];
            const unmatched_isolate = isIsolateInitiator(classes[last_idx]) and matchingPdiIndex(classes, last_idx) >= n;
            const following_level = if (unmatched_isolate)
                paragraph_level
            else if (last_run.filtered_end < run_indices.items.len)
                explicit_levels[run_indices.items[last_run.filtered_end]]
            else
                paragraph_level;

            const sos: BidiClass = if (@max(seq_level, preceding_level) % 2 == 1) .r else .l;
            const eos: BidiClass = if (@max(seq_level, following_level) % 2 == 1) .r else .l;

            try resolveIsolatingRunSequence(arena, work, classes, codepoints, levels, seq.items, seq_level, sos, eos);
        }

        // L1: reset segment/paragraph separators and trailing or
        // pre-separator runs of whitespace/isolate-formatting/removed
        // characters to the paragraph level. Uses the ORIGINAL classes,
        // not the W/N/I-resolved ones.
        {
            var reset_mode = true;
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                const c = classes[i];
                if (c == .s or c == .b) {
                    levels[i] = paragraph_level;
                    reset_mode = true;
                } else if (isL1Invisible(c)) {
                    if (reset_mode) levels[i] = paragraph_level;
                } else {
                    reset_mode = false;
                }
            }
        }

        @memcpy(result, levels);
        return result;
    }

    // UAX #9 rule L2: given resolved levels, produce the visual order as a
    // permutation of logical indices.
    pub fn reorderVisual(allocator: std.mem.Allocator, levels: []const u8) std.mem.Allocator.Error![]usize {
        const order = try allocator.alloc(usize, levels.len);
        for (order, 0..) |*o, i| o.* = i;
        if (levels.len == 0) return order;

        var max_level: u8 = 0;
        var min_odd_level: ?u8 = null;
        for (levels) |l| {
            if (l > max_level) max_level = l;
            if (l % 2 == 1 and (min_odd_level == null or l < min_odd_level.?)) min_odd_level = l;
        }
        const lowest = min_odd_level orelse return order;

        var level = max_level;
        while (true) {
            var i: usize = 0;
            while (i < order.len) {
                if (levels[i] >= level) {
                    var j = i;
                    while (j < order.len and levels[j] >= level) : (j += 1) {}
                    std.mem.reverse(usize, order[i..j]);
                    i = j;
                } else i += 1;
            }
            if (level == lowest) break;
            level -= 1;
        }
        return order;
    }

    pub const LineRun = struct {
        /// Index into the `slices` given to `lineRuns`.
        slice: u32,
        /// Byte range within that slice.
        start: u32,
        end: u32,
        level: u8,
    };

    // One line held as consecutive UTF-8 slices (styled chunks) is resolved as
    // one paragraph, so neutrals resolve against neighbours in other slices;
    // runs are cut at level changes and slice boundaries. Null when every
    // level is even. An .auto `base_direction` is pinned to the first strong
    // direction so later lines of the same paragraph can carry it.
    pub fn lineRuns(allocator: std.mem.Allocator, slices: []const []const u8, base_direction: *ParagraphDirection) (Error || std.mem.Allocator.Error)!?[]LineRun {
        var total_bytes: usize = 0;
        for (slices) |s| total_bytes += s.len;
        if (total_bytes == 0) return null;

        const codepoints = try allocator.alloc(u21, total_bytes);
        defer allocator.free(codepoints);
        const slice_of = try allocator.alloc(u32, total_bytes);
        defer allocator.free(slice_of);
        const offset_of = try allocator.alloc(u32, total_bytes);
        defer allocator.free(offset_of);
        var n: usize = 0;
        for (slices, 0..) |s, si| {
            var i: usize = 0;
            while (i < s.len) {
                const d = decodeUtf8At(s, i);
                codepoints[n] = d.cp;
                slice_of[n] = @intCast(si);
                offset_of[n] = @intCast(i);
                n += 1;
                i += d.len;
            }
        }

        const classes = try allocator.alloc(BidiClass, n);
        defer allocator.free(classes);
        for (codepoints[0..n], classes) |cp, *c| c.* = BidiClass.of(cp);

        const levels = try paragraphEmbeddingLevels(allocator, classes, base_direction.*, codepoints[0..n]);
        defer allocator.free(levels);
        if (base_direction.* == .auto) {
            if (firstStrongDirection(classes)) |strong| base_direction.* = if (strong == .l) .ltr else .rtl;
        }
        for (levels) |l| {
            if (l % 2 == 1) break;
        } else return null;

        var runs: std.ArrayList(LineRun) = .empty;
        errdefer runs.deinit(allocator);
        for (levels, 0..) |level, i| {
            const si = slice_of[i];
            const end: u32 = if (i + 1 < n and slice_of[i + 1] == si) offset_of[i + 1] else @intCast(slices[si].len);
            if (runs.items.len > 0) {
                const last = &runs.items[runs.items.len - 1];
                if (last.slice == si and last.level == level) {
                    last.end = end;
                    continue;
                }
            }
            try runs.append(allocator, .{ .slice = si, .start = offset_of[i], .end = end, .level = level });
        }
        return try runs.toOwnedSlice(allocator);
    }

    // Byte-level prefilter: false means no codepoint in `utf8` is RTL or a
    // bidi control, so an LTR paragraph needs no reordering pass.
    pub fn mayNeedReorder(utf8: []const u8) bool {
        for (utf8, 0..) |b, i| {
            if (b < 0xd6) continue;
            const next: u8 = if (i + 1 < utf8.len) utf8[i + 1] else 0;
            switch (b) {
                0xd6...0xdf => return true, // U+0590..U+07FF Hebrew..NKo
                0xe0 => if (next >= 0xa0) return true, // U+0800..U+08FF
                0xe2 => if (next <= 0x81) return true, // U+2000..U+207F bidi controls
                0xef => if (next >= 0xac) return true, // U+FB00.. presentation forms
                0xf0 => if (next == 0x90 or next == 0x9e) return true, // U+10xxx, U+1Exxx RTL blocks
                else => {},
            }
        }
        return false;
    }
};

pub const GraphemeClusterBreak = enum {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
    extended_pictographic,

    pub fn of(codepoint: u21) GraphemeClusterBreak {
        const class = packedLookup(&tables.grapheme_cluster_break_ranges, codepoint);
        if (class == no_class) return .other;
        return @enumFromInt(class);
    }
};

const incb_extend: u8 = 1;
const incb_linker: u8 = 2;
const incb_consonant: u8 = 3;

fn indicConjunctBreakOf(codepoint: u21) u8 {
    const class = packedLookup(&tables.indic_conjunct_break_ranges, codepoint);
    return if (class == no_class) 0 else class;
}

// UAX #29 rules GB3-GB999: is there a boundary between text[i - 1] and
// text[i]? GB1/GB2 (sot/eot) are handled by the iterator's loop bounds.
fn isGraphemeBreakBefore(text: []const u21, i: usize) bool {
    const prev = GraphemeClusterBreak.of(text[i - 1]);
    const cur = GraphemeClusterBreak.of(text[i]);

    if (prev == .cr and cur == .lf) return false; // GB3
    if (prev == .control or prev == .cr or prev == .lf) return true; // GB4
    if (cur == .control or cur == .cr or cur == .lf) return true; // GB5
    if (prev == .l and (cur == .l or cur == .v or cur == .lv or cur == .lvt)) return false; // GB6
    if ((prev == .lv or prev == .v) and (cur == .v or cur == .t)) return false; // GB7
    if ((prev == .lvt or prev == .t) and cur == .t) return false; // GB8
    if (cur == .extend or cur == .zwj) return false; // GB9
    if (cur == .spacing_mark) return false; // GB9a
    if (prev == .prepend) return false; // GB9b

    // GB9c: InCB=Consonant [InCB=Extend|InCB=Linker]* InCB=Linker
    // [InCB=Extend|InCB=Linker]* x InCB=Consonant
    if (indicConjunctBreakOf(text[i]) == incb_consonant) {
        var k = i;
        var saw_linker = false;
        while (k > 0) {
            const c = indicConjunctBreakOf(text[k - 1]);
            if (c != incb_extend and c != incb_linker) break;
            saw_linker = saw_linker or c == incb_linker;
            k -= 1;
        }
        if (saw_linker and k > 0 and indicConjunctBreakOf(text[k - 1]) == incb_consonant) return false;
    }

    // GB11: Extended_Pictographic Extend* ZWJ x Extended_Pictographic
    if (cur == .extended_pictographic and prev == .zwj) {
        var k = i - 1;
        while (k > 0 and GraphemeClusterBreak.of(text[k - 1]) == .extend) k -= 1;
        if (k > 0 and GraphemeClusterBreak.of(text[k - 1]) == .extended_pictographic) return false;
    }

    // GB12/GB13: break between regional indicators only after a completed
    // (even-length) run of preceding regional indicators.
    if (prev == .regional_indicator and cur == .regional_indicator) {
        var count: usize = 0;
        var k = i;
        while (k > 0 and GraphemeClusterBreak.of(text[k - 1]) == .regional_indicator) {
            count += 1;
            k -= 1;
        }
        if (count % 2 == 1) return false;
    }

    return true; // GB999
}

// UAX #29 grapheme cluster boundaries over a codepoint sequence.
pub const GraphemeBreakIterator = struct {
    text: []const u21,
    pos: usize = 0,

    pub fn init(text: []const u21) GraphemeBreakIterator {
        return .{ .text = text };
    }

    // Returns the next grapheme cluster as a subslice of `text`, or null at
    // end of input.
    pub fn next(self: *GraphemeBreakIterator) ?[]const u21 {
        if (self.pos >= self.text.len) return null;
        var i = self.pos + 1;
        while (i < self.text.len and !isGraphemeBreakBefore(self.text, i)) : (i += 1) {}
        const start = self.pos;
        self.pos = i;
        return self.text[start..i];
    }
};

const Utf8Codepoint = struct { cp: u21, len: usize };

// Ill-formed bytes decode one at a time as U+FFFD so every byte is covered.
fn decodeUtf8At(utf8: []const u8, i: usize) Utf8Codepoint {
    const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + len > utf8.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(utf8[i..][0..len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

fn decodeUtf8Before(utf8: []const u8, end: usize) Utf8Codepoint {
    var start = end - 1;
    while (start > 0 and end - start < 4 and utf8[start] & 0xC0 == 0x80) start -= 1;
    const d = decodeUtf8At(utf8, start);
    if (start + d.len != end) return .{ .cp = 0xFFFD, .len = 1 };
    return d;
}

/// Byte offset of the grapheme boundary following the one at `start`.
/// Every lookback rule (GB9c, GB11, GB12) stays inside the cluster being
/// built, so the codepoints since `start` are all the context needed.
/// ponytail: a cluster longer than 128 codepoints is cut there; heap-backed
/// lookback if zalgo text ever needs a single caret stop.
pub fn nextGraphemeBoundary(utf8: []const u8, start: usize) usize {
    var cluster: [128]u21 = undefined;
    var n: usize = 0;
    var i = start;
    while (i < utf8.len) {
        const d = decodeUtf8At(utf8, i);
        if (n == cluster.len) return i;
        cluster[n] = d.cp;
        if (n > 0 and isGraphemeBreakBefore(cluster[0 .. n + 1], n)) return i;
        n += 1;
        i += d.len;
    }
    return utf8.len;
}

/// hb's `is_variation_selector`: VS1-256, not the Mongolian FVSes.
pub fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

fn isEmojiModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn isEmoji(cp: u21) bool {
    return isEmojiModifier(cp) or GraphemeClusterBreak.of(cp) == .extended_pictographic;
}

/// Where Backspace starts deleting when the caret sits at `end`. Ported
/// from Blink's BackspaceStateMachine: an emoji sequence (ZWJ, modifier,
/// keycap, flag pair, variation selector, tag sequence) goes as one unit,
/// CR LF as one, anything else one codepoint -- so a base letter survives
/// losing its accent.
/// ponytail: Emoji_Modifier_Base is approximated by Extended_Pictographic.
pub fn backspaceStart(utf8: []const u8, end: usize) usize {
    const State = enum { start, before_lf, before_keycap, before_vs_and_keycap, before_emoji_modifier, before_vs_and_emoji_modifier, before_vs, before_emoji, before_zwj, before_vs_and_zwj, odd_ris, even_ris, in_tag_sequence };
    var state: State = .start;
    var delete_from = end;
    var single_ri_from = end;
    var pair_ri_from: ?usize = null;
    var pos = end;
    while (pos > 0) {
        const d = decodeUtf8Before(utf8, pos);
        pos -= d.len;
        const cp = d.cp;
        switch (state) {
            .start => {
                delete_from = pos;
                single_ri_from = pos;
                state = if (cp == '\n')
                    .before_lf
                else if (isVariationSelector(cp))
                    .before_vs
                else if (GraphemeClusterBreak.of(cp) == .regional_indicator)
                    .odd_ris
                else if (isEmojiModifier(cp))
                    .before_emoji_modifier
                else if (cp == 0x20E3)
                    .before_keycap
                else if (cp == 0xE007F)
                    .in_tag_sequence
                else if (isEmoji(cp))
                    .before_emoji
                else
                    return pos;
            },
            .before_lf => return if (cp == '\r') pos else delete_from,
            .before_keycap => {
                if (isVariationSelector(cp)) {
                    state = .before_vs_and_keycap;
                } else return if ((cp >= '0' and cp <= '9') or cp == '#' or cp == '*') pos else delete_from;
            },
            .before_vs_and_keycap => return if ((cp >= '0' and cp <= '9') or cp == '#' or cp == '*') pos else delete_from,
            .before_emoji_modifier, .before_vs_and_emoji_modifier => {
                if (state == .before_emoji_modifier and isVariationSelector(cp)) {
                    state = .before_vs_and_emoji_modifier;
                } else if (GraphemeClusterBreak.of(cp) == .extended_pictographic) {
                    delete_from = pos;
                    state = .before_emoji;
                } else return delete_from;
            },
            .before_vs => {
                if (isEmoji(cp)) {
                    delete_from = pos;
                    state = .before_emoji;
                } else return if (isVariationSelector(cp)) delete_from else pos;
            },
            .before_emoji => {
                if (cp != 0x200D) return delete_from;
                state = .before_zwj;
            },
            .before_zwj, .before_vs_and_zwj => {
                if (isEmoji(cp)) {
                    delete_from = pos;
                    state = if (isEmojiModifier(cp)) .before_emoji_modifier else .before_emoji;
                } else if (state == .before_zwj and isVariationSelector(cp)) {
                    state = .before_vs_and_zwj;
                } else return delete_from;
            },
            .odd_ris, .even_ris => {
                if (GraphemeClusterBreak.of(cp) != .regional_indicator) return delete_from;
                pair_ri_from = pair_ri_from orelse pos;
                delete_from = if (state == .odd_ris) pair_ri_from.? else single_ri_from;
                state = if (state == .odd_ris) .even_ris else .odd_ris;
            },
            .in_tag_sequence => {
                if (cp >= 0xE0020 and cp <= 0xE007E) {
                    delete_from = pos;
                } else return if (cp == 0x1F3F4) pos else delete_from;
            },
        }
    }
    return delete_from;
}

// Dictionary-based word segmentation (Thai/Lao/Khmer/Myanmar): UAX #14
// leaves the Complex Context (SA) class with no default break opportunities
// (behaves like AL) and defers to "a more sophisticated approach... such as
// dictionary lookup" for scripts that don't use spaces between words. No
// harfbuzz/swash reference exists for this (neither shapes at the word
// level), so per CLAUDE.md's guidance for no-vendor-reference algorithm
// components, ported from icu4x's icu_collections::char16trie
// (Char16Trie/Char16TrieIterator — a compact binary trie over UTF-16 code
// units, ICU4C's UCharsTrie format) and icu_segmenter's
// DictionaryBreakIterator (complex/dictionary.rs): a single greedy forward
// walk tracking the longest dictionary-word prefix matched so far,
// backtracking to it on a failed extension, gated on grapheme-cluster
// boundaries so a match can't land mid-cluster.
//
// Trie data (unicode/dict/*.bin, one flat little-endian-u16 blob per
// script) is extracted from icu4x's own baked dictionary data by
// tools/dict_gen/ (a one-off Rust tool pinned to icu_segmenter 2.3.0, not
// run by `zig build` — see that directory's doc comment for regeneration
// instructions). The word lists themselves
// originate from ICU's own `.brk` dictionary files, same Unicode-3.0
// permissive license as icu4x's code — no separate data-licensing
// question. Cross-checked against icu4x's own test vectors (see
// test_dictionary_lao/khmer/myanmar in unicode_test.zig): byte-for-byte
// match on all three scripts' known break positions from icu4x's
// dictionary.rs test module.
//
// This port drops the wrapped integer payload from icu4x's `TrieResult`
// (`FinalValue(i32)`/`Intermediate(i32)`) since the dictionary-break
// algorithm only ever inspects which variant was returned, never the value
// itself — the position-skip amounts (`skip_value`/`skip_node_value`,
// needed to keep walking the trie correctly) are ported in full, only the
// value *decode* arithmetic is dropped.

fn trieGet(bytes: []const u8, pos: usize) ?u16 {
    const byte_off = pos * 2;
    if (byte_off + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[byte_off..][0..2], .little);
}

const trie_max_branch_linear_sub_node_length: usize = 5;
const trie_min_linear_match: u16 = 0x30;
const trie_max_linear_match_length: u16 = 0x10;
const trie_min_value_lead: u16 = trie_min_linear_match + trie_max_linear_match_length; // 0x40
const trie_node_type_mask: u16 = trie_min_value_lead - 1; // 0x3f
const trie_value_is_final: u16 = 0x8000;
const trie_min_two_unit_value_lead: u16 = 0x4000;
const trie_min_two_unit_node_value_lead: u16 = trie_min_value_lead + (256 << 6); // 0x4040
const trie_three_unit_node_value_lead: u16 = 0x7fc0;
const trie_three_unit_value_lead: u16 = 0x7fff;
const trie_min_two_unit_delta_lead: u16 = 0xfc00;
const trie_three_unit_delta_lead: u16 = 0xffff;

fn trieSkipValue(pos: usize, lead: u16) usize {
    if (lead < trie_min_two_unit_value_lead) return pos;
    if (lead < trie_three_unit_value_lead) return pos + 1;
    return pos + 2;
}

fn trieSkipNodeValue(pos: usize, lead: u16) usize {
    if (lead < trie_min_two_unit_node_value_lead) return pos;
    if (lead < trie_three_unit_node_value_lead) return pos + 1;
    return pos + 2;
}

const TrieResult = union(enum) { no_match, no_value, final_value: i32, intermediate: i32 };

fn trieU16Lead(supplementary: u21) u16 {
    return @intCast((@as(u32, supplementary) >> 10) + 0xd7c0);
}

fn trieU16Tail(supplementary: u21) u16 {
    return @intCast((@as(u32, supplementary) & 0x3ff) | 0xdc00);
}

const TrieIterator = struct {
    bytes: []const u8,
    pos: ?usize = 0,
    remaining_match_length: ?usize = null,

    fn stop(self: *TrieIterator) void {
        self.pos = null;
    }

    fn jumpByDelta(self: *TrieIterator, pos: usize) ?usize {
        const delta = trieGet(self.bytes, pos) orelse return null;
        if (delta < trie_min_two_unit_delta_lead) return pos + 1 + delta;
        if (delta == trie_three_unit_delta_lead) {
            const hi = trieGet(self.bytes, pos + 1) orelse return null;
            const lo = trieGet(self.bytes, pos + 2) orelse return null;
            return pos + ((@as(usize, hi) << 16) | lo) + 3;
        }
        const lo = trieGet(self.bytes, pos + 1) orelse return null;
        return pos + ((@as(usize, delta - trie_min_two_unit_delta_lead) << 16) | lo) + 2;
    }

    fn skipValuePos(self: *TrieIterator, pos: usize) ?usize {
        const lead = trieGet(self.bytes, pos) orelse return null;
        return trieSkipValue(pos + 1, lead & 0x7fff);
    }

    fn skipDelta(self: *TrieIterator, pos: usize) ?usize {
        const delta = trieGet(self.bytes, pos) orelse return null;
        if (delta < trie_min_two_unit_delta_lead) return pos + 1;
        if (delta == trie_three_unit_delta_lead) return pos + 3;
        return pos + 2;
    }

    fn readValue(self: *TrieIterator, pos: usize, lead_unit: u16) ?i32 {
        if (lead_unit < trie_min_two_unit_value_lead) return lead_unit;
        if (lead_unit < trie_three_unit_value_lead) {
            const lo = trieGet(self.bytes, pos) orelse return null;
            return (@as(i32, lead_unit - trie_min_two_unit_value_lead) << 16) | lo;
        }
        const hi = trieGet(self.bytes, pos) orelse return null;
        const lo = trieGet(self.bytes, pos + 1) orelse return null;
        return (@as(i32, hi) << 16) | lo;
    }

    fn readNodeValue(self: *TrieIterator, pos: usize, lead_unit: u16) ?i32 {
        if (lead_unit < trie_min_two_unit_node_value_lead) return @as(i32, lead_unit >> 6) - 1;
        if (lead_unit < trie_three_unit_node_value_lead) {
            const lo = trieGet(self.bytes, pos) orelse return null;
            return (@as(i32, (lead_unit & 0x7fc0) - trie_min_two_unit_node_value_lead) << 10) | lo;
        }
        const hi = trieGet(self.bytes, pos) orelse return null;
        const lo = trieGet(self.bytes, pos + 1) orelse return null;
        return (@as(i32, hi) << 16) | lo;
    }

    fn getValue(self: *TrieIterator, pos: usize) TrieResult {
        const lead_unit = trieGet(self.bytes, pos) orelse return .no_match;
        if (lead_unit & trie_value_is_final == trie_value_is_final) {
            const v = self.readValue(pos + 1, lead_unit & 0x7fff) orelse return .no_match;
            return .{ .final_value = v };
        }
        const v = self.readNodeValue(pos + 1, lead_unit) orelse return .no_match;
        return .{ .intermediate = v };
    }

    fn branchNext(self: *TrieIterator, start_pos: usize, start_length: usize, in_unit: u16) TrieResult {
        var pos = start_pos;
        var length = start_length;
        if (length == 0) {
            length = trieGet(self.bytes, pos) orelse {
                self.stop();
                return .no_match;
            };
            pos += 1;
        }
        length += 1;

        while (length > trie_max_branch_linear_sub_node_length) {
            const probe = trieGet(self.bytes, pos) orelse {
                self.stop();
                return .no_match;
            };
            if (in_unit < probe) {
                length >>= 1;
                pos = self.jumpByDelta(pos + 1) orelse {
                    self.stop();
                    return .no_match;
                };
            } else {
                length = length - (length >> 1);
                pos = self.skipDelta(pos + 1) orelse {
                    self.stop();
                    return .no_match;
                };
            }
        }

        while (true) {
            const probe = trieGet(self.bytes, pos) orelse {
                self.stop();
                return .no_match;
            };
            if (in_unit == probe) {
                pos += 1;
                var node = trieGet(self.bytes, pos) orelse {
                    self.stop();
                    return .no_match;
                };
                if (node & trie_value_is_final != 0) {
                    self.pos = pos;
                    return self.getValue(pos);
                }
                pos += 1;
                if (node < trie_min_two_unit_value_lead) {
                    pos += node;
                } else if (node < trie_three_unit_value_lead) {
                    const lo = trieGet(self.bytes, pos) orelse {
                        self.stop();
                        return .no_match;
                    };
                    pos += ((@as(usize, node - trie_min_two_unit_value_lead) << 16) | lo) + 1;
                } else {
                    const hi = trieGet(self.bytes, pos) orelse {
                        self.stop();
                        return .no_match;
                    };
                    const lo = trieGet(self.bytes, pos + 1) orelse {
                        self.stop();
                        return .no_match;
                    };
                    pos += ((@as(usize, hi) << 16) | lo) + 2;
                }
                node = trieGet(self.bytes, pos) orelse {
                    self.stop();
                    return .no_match;
                };
                self.pos = pos;
                if (node >= trie_min_value_lead) return self.getValue(pos);
                return .no_value;
            }
            length -= 1;
            pos = self.skipValuePos(pos + 1) orelse {
                self.stop();
                return .no_match;
            };
            if (length <= 1) break;
        }

        const probe2 = trieGet(self.bytes, pos) orelse {
            self.stop();
            return .no_match;
        };
        if (in_unit == probe2) {
            pos += 1;
            self.pos = pos;
            const node = trieGet(self.bytes, pos) orelse {
                self.stop();
                return .no_match;
            };
            if (node >= trie_min_value_lead) return self.getValue(pos);
            return .no_value;
        }
        self.stop();
        return .no_match;
    }

    fn nextImpl(self: *TrieIterator, start_pos: usize, in_unit: u16) TrieResult {
        var node = trieGet(self.bytes, start_pos) orelse {
            self.stop();
            return .no_match;
        };
        var pos = start_pos + 1;
        while (true) {
            if (node < trie_min_linear_match) {
                return self.branchNext(pos, node, in_unit);
            } else if (node < trie_min_value_lead) {
                const length = node - trie_min_linear_match;
                const probe = trieGet(self.bytes, pos) orelse {
                    self.stop();
                    return .no_match;
                };
                if (in_unit == probe) {
                    pos += 1;
                    if (length == 0) {
                        self.remaining_match_length = null;
                        self.pos = pos;
                        node = trieGet(self.bytes, pos) orelse {
                            self.stop();
                            return .no_match;
                        };
                        if (node >= trie_min_value_lead) return self.getValue(pos);
                        return .no_value;
                    }
                    self.remaining_match_length = @as(usize, length) - 1;
                    self.pos = pos;
                    return .no_value;
                }
                break;
            } else if (node & trie_value_is_final != 0) {
                break;
            } else {
                pos = trieSkipNodeValue(pos, node);
                node &= trie_node_type_mask;
            }
        }
        self.stop();
        return .no_match;
    }

    fn next16(self: *TrieIterator, c: u16) TrieResult {
        const pos = self.pos orelse return .no_match;
        if (self.remaining_match_length) |length| {
            const probe = trieGet(self.bytes, pos) orelse {
                self.stop();
                return .no_match;
            };
            if (c == probe) {
                const new_pos = pos + 1;
                self.pos = new_pos;
                if (length == 0) {
                    self.remaining_match_length = null;
                    const node = trieGet(self.bytes, new_pos) orelse {
                        self.stop();
                        return .no_match;
                    };
                    if (node >= trie_min_value_lead) return self.getValue(new_pos);
                } else {
                    self.remaining_match_length = length - 1;
                }
                return .no_value;
            }
            self.stop();
            return .no_match;
        }
        return self.nextImpl(pos, c);
    }

    fn next32(self: *TrieIterator, c: u21) TrieResult {
        if (c <= 0xffff) return self.next16(@intCast(c));
        const lead_result = self.next16(trieU16Lead(c));
        return switch (lead_result) {
            .no_value, .intermediate => self.next16(trieU16Tail(c)),
            else => .no_match,
        };
    }
};

pub const DictionaryScript = enum { thai, lao, khmer, myanmar };

const thai_trie_bytes = @embedFile("unicode/dict/thaidict.bin");
const lao_trie_bytes = @embedFile("unicode/dict/laodict.bin");
const khmer_trie_bytes = @embedFile("unicode/dict/khmerdict.bin");
const myanmar_trie_bytes = @embedFile("unicode/dict/burmesedict.bin");

fn dictionaryTrieBytes(script: DictionaryScript) []const u8 {
    return switch (script) {
        .thai => thai_trie_bytes,
        .lao => lao_trie_bytes,
        .khmer => khmer_trie_bytes,
        .myanmar => myanmar_trie_bytes,
    };
}

// Unicode block ranges for the four dictionary-segmented scripts —
// deliberately not a general Script-property table (this codebase doesn't
// have one; shaping's complex-script dispatch already established the
// "caller supplies script identity, no property-table lookup" pattern for
// the same reason). These four blocks are contiguous and script-exclusive
// enough that a plain range switch is the whole implementation needed.
pub fn dictionaryScriptOf(codepoint: u21) ?DictionaryScript {
    return switch (codepoint) {
        0x0E00...0x0E7F => .thai,
        0x0E80...0x0EFF => .lao,
        0x1000...0x109F => .myanmar,
        0x1780...0x17FF => .khmer,
        else => null,
    };
}

// Greedy longest-dictionary-word-match forward walk (ported from
// icu_segmenter's DictionaryBreakIterator::next, see module doc comment
// above). Unlike icu4x's incrementally-advanced grapheme_iter (an
// optimization needed because their trie walks over lazily-decoded
// UTF-8/16 code units), this operates on an already-decoded `[]const u21`,
// so the grapheme-boundary gate is just a direct `isGraphemeBreakBefore`
// call per candidate match end — no iterator-cloning/rewinding needed to
// keep it in sync with trie backtracking.
pub const DictionaryBreakIterator = struct {
    trie_bytes: []const u8,
    text: []const u21,
    pos: usize = 0,

    pub fn init(script: DictionaryScript, text: []const u21) DictionaryBreakIterator {
        return .{ .trie_bytes = dictionaryTrieBytes(script), .text = text };
    }

    // Returns the next word-break position (a codepoint index into `text`),
    // or null once the whole input has been consumed.
    pub fn next(self: *DictionaryBreakIterator) ?usize {
        if (self.pos >= self.text.len) return null;

        var iter = TrieIterator{ .bytes = self.trie_bytes };
        var intermediate_end: ?usize = null;
        var saw_prefix_only = false;

        var i = self.pos;
        while (i < self.text.len) : (i += 1) {
            switch (iter.next32(self.text[i])) {
                .final_value => {
                    self.pos = i + 1;
                    return self.pos;
                },
                .intermediate => {
                    const end = i + 1;
                    if (end < self.text.len and !isGraphemeBreakBefore(self.text, end)) continue;
                    intermediate_end = end;
                },
                .no_match => {
                    const end = intermediate_end orelse i + 1;
                    self.pos = end;
                    return end;
                },
                .no_value => saw_prefix_only = true,
            }
        }

        if (intermediate_end) |end| {
            self.pos = end;
            return end;
        }
        if (saw_prefix_only) {
            self.pos = self.text.len;
            return self.pos;
        }
        return null;
    }
};

fn dictionaryRunStart(text: []const u21, i: usize, script: DictionaryScript) usize {
    var k = i;
    while (k > 0 and dictionaryScriptOf(text[k - 1]) == script) : (k -= 1) {}
    return k;
}

fn dictionaryRunEnd(text: []const u21, i: usize, script: DictionaryScript) usize {
    var k = i;
    while (k < text.len and dictionaryScriptOf(text[k]) == script) : (k += 1) {}
    return k;
}

// Whether `i` is one of the dictionary's word-break positions within the
// maximal same-script run containing it. O(run length) per call (the run
// is re-walked from its start every time) — consistent with this file's
// existing per-boundary local-scan style (e.g. numberRunEndsAt); revisit
// only if profiling shows this matters for very long CJK/SEA-script runs.
fn isDictionaryWordBoundary(text: []const u21, i: usize, script: DictionaryScript) bool {
    const start = dictionaryRunStart(text, i, script);
    const end = dictionaryRunEnd(text, i, script);
    var iter = DictionaryBreakIterator.init(script, text[start..end]);
    while (iter.next()) |brk| {
        const abs = start + brk;
        if (abs == i) return true;
        if (abs > i) return false;
    }
    return false;
}

pub const LineBreakClass = enum {
    bk,
    cr,
    lf,
    cm,
    nl,
    sg,
    wj,
    zw,
    gl,
    sp,
    zwj,
    b2,
    ba,
    bb,
    hy,
    cb,
    cl,
    cp,
    ex,
    in,
    ns,
    op,
    qu,
    is,
    nu,
    po,
    pr,
    sy,
    ai,
    al,
    cj,
    eb,
    em,
    h2,
    h3,
    hl,
    id,
    jl,
    jv,
    jt,
    ri,
    sa,
    xx,

    pub fn of(codepoint: u21) LineBreakClass {
        const class = packedLookup(&tables.line_break_class_ranges, codepoint);
        if (class == no_class) return .xx;
        return @enumFromInt(class);
    }
};

pub const LineBreakOpportunity = enum { mandatory, allowed, prohibited };

pub const LineBreakBoundary = struct {
    /// Index into the source text (in codepoints) where the boundary falls.
    index: usize,
    opportunity: LineBreakOpportunity,
};

/// CSS Text Module Level 3 `line-break` property strictness. `.strict` is
/// the untailored UAX #14 default (what `LineBreakIterator` always produced
/// before tailoring existed); `.normal`/`.loose` only ever *add* break
/// opportunities on top of it, never remove one, per the spec's tables.
pub const LineBreakStrictness = enum { strict, normal, loose };

/// CSS Text Module Level 3 `word-break` property. `.normal` is a no-op
/// (customary UAX #14 behavior); `.break_all` and `.keep_all` are
/// implemented as class overrides in `LineBreakIterator`, not full
/// dictionary-based CJK/Southeast-Asian word segmentation.
pub const WordBreakMode = enum { normal, break_all, keep_all };

fn isInitialPunctuation(codepoint: u21) bool {
    return packedLookup(&tables.quote_punctuation_ranges, codepoint) == 0;
}

fn isFinalPunctuation(codepoint: u21) bool {
    return packedLookup(&tables.quote_punctuation_ranges, codepoint) == 1;
}

// East_Asian_Width in {F, W, H} — used by the LB19a/LB30 overrides below.
// LB30b extension (Unicode 16.0): "[Extended_Pictographic & Cn] × EM" —
// unassigned-but-Extended_Pictographic-flagged codepoints get the same
// no-break-before-EM treatment as real EB codepoints.
fn isExtendedPictographicUnassigned(codepoint: u21) bool {
    return packedContains(&tables.extended_pictographic_unassigned_ranges, codepoint);
}

fn isEastAsianWide(codepoint: u21) bool {
    return packedContains(&tables.east_asian_wide_ranges, codepoint);
}

// LB1 resolution used only by the LB25 override's own backward/forward
// text scan below (the state machine already applies this at the table
// level for the main pass): AI/SG/XX/SA -> AL, CJ -> NS.
fn lb1ResolveForLb25(codepoint: u21) LineBreakClass {
    return switch (LineBreakClass.of(codepoint)) {
        .ai, .sg, .xx, .sa => .al,
        .cj => .ns,
        else => |c| c,
    };
}

const lb9_no_attach = [_]LineBreakClass{ .bk, .cr, .lf, .nl, .sp, .zw };

// LB9/LB10: attach a run of CM/ZWJ to the nearest preceding character not
// itself CM/ZWJ (used only by the LB25 override's scan; the main pass gets
// this from the table's "sticky" extra states).
fn resolvedClassAtForLb25(text: []const u21, i: usize) LineBreakClass {
    const raw = lb1ResolveForLb25(text[i]);
    if (raw != .cm and raw != .zwj) return raw;

    var k = i;
    while (k > 0) {
        const prev = lb1ResolveForLb25(text[k - 1]);
        if (prev == .cm or prev == .zwj) {
            k -= 1;
            continue;
        }
        for (lb9_no_attach) |excluded| {
            if (prev == excluded) return .al;
        }
        return prev;
    }
    return .al;
}

// True if a NU (SY|IS)* run ends exactly at `pos` (`pos` itself is NU, or
// is SY/IS with such a run behind it) — the shared "immediately after a
// number" context LB25's rules key off of.
fn numberRunEndsAt(text: []const u21, pos: usize) bool {
    var k = pos;
    while (true) {
        const c = resolvedClassAtForLb25(text, k);
        if (c == .nu) return true;
        if ((c == .sy or c == .is) and k > 0) {
            k -= 1;
            continue;
        }
        return false;
    }
}

// LB25 (Unicode 15+ revision): the vendored crate's ported pair table still
// has the older, unconditional CL/CP-PO/PR-style LB25 pairs — most of these
// prohibitions actually only fire within an actual number context (a
// preceding/following NU, possibly through a SY/IS run, or a forward OP
// (IS)? NU lookahead), so this overrides the table's blanket `×` for
// exactly those 14 pairs it set unconditionally.
fn lb25Prohibited(text: []const u21, i: usize) bool {
    const a = resolvedClassAtForLb25(text, i - 1);
    const b = resolvedClassAtForLb25(text, i);

    if ((a == .cl or a == .cp) and (b == .po or b == .pr) and i >= 2 and numberRunEndsAt(text, i - 2)) return true;
    if ((b == .po or b == .pr or b == .nu) and numberRunEndsAt(text, i - 1)) return true;

    if ((a == .po or a == .pr) and b == .op) {
        if (i + 1 < text.len and resolvedClassAtForLb25(text, i + 1) == .nu) return true;
        if (i + 2 < text.len and resolvedClassAtForLb25(text, i + 1) == .is and resolvedClassAtForLb25(text, i + 2) == .nu) return true;
    }
    if ((a == .po or a == .pr) and b == .nu) return true;
    if ((a == .hy or a == .is) and b == .nu) return true;

    return false;
}

// Is (a, b) one of the pairs LB25 needs re-decided with number-context
// awareness? Most are the 14 pairs the ported (15.0) table's LB25 block
// already set to an unconditional `×` (see LB_RULES' LB25 block in
// gen_tables.py) — lb25Prohibited re-derives those with the real (16.0)
// number-context gating. `is => b == .po or .pr` is different: the old
// table never prohibited IS-then-PO/PR at all (row(is)[po/pr] is an
// ordinary allowed break), but 16.0's LB25 does when the IS is the tail of
// an actual number run (e.g. "123.€" — trailing decimal point directly
// followed by a currency symbol, one glued token) — gated here so
// lb25Prohibited's existing `numberRunEndsAt` check (already correct) gets
// a chance to run for it instead of leaving the table's un-prohibited
// default in place unconditionally.
fn isLb25TablePair(a: LineBreakClass, b: LineBreakClass) bool {
    return switch (a) {
        .cl, .cp => b == .po or b == .pr,
        .nu => b == .po or b == .pr or b == .nu,
        .po => b == .op or b == .nu,
        .pr => b == .op or b == .nu,
        .is => b == .nu or b == .po or b == .pr,
        .hy, .sy => b == .nu,
        else => false,
    };
}

// LB20a (Unicode 16.0, new rule not in the vendored 15.0 table): no break
// between a word-initial hyphen and a following AL —
// (sot|BK|CR|LF|NL|SP|ZW|CB|GL) (HY|U+2010) × AL. Checked directly against
// the raw text (not pair-table state) since, as with LB19/19a, sticky
// states fold "X after CL/CP/OP/QU/B2/ZW" and would hide the true
// preceding class.
fn isLb20aWordStartContext(class: LineBreakClass) bool {
    return switch (class) {
        .bk, .cr, .lf, .nl, .sp, .zw, .cb, .gl => true,
        else => false,
    };
}

fn lb20aNoBreakAfterWordInitialHyphen(text: []const u21, boundary_index: usize) bool {
    if (boundary_index == 0) return false;
    if (lb1ResolveForLb25(text[boundary_index]) != .al) return false;
    // Skip back over any CM/ZWJ run attached to the hyphen (LB9/10) — the
    // hyphen itself, not a combining mark riding on it, is what LB20a's
    // pattern actually matches against.
    var hy_index = boundary_index - 1;
    while (hy_index > 0) {
        const c = lb1ResolveForLb25(text[hy_index]);
        if (c != .cm and c != .zwj) break;
        hy_index -= 1;
    }
    const hy_class = lb1ResolveForLb25(text[hy_index]);
    if (hy_class != .hy and text[hy_index] != 0x2010) return false;
    if (hy_index == 0) return true;
    return isLb20aWordStartContext(lb1ResolveForLb25(text[hy_index - 1]));
}

// HLHYBA (Hebrew letter + hyphen/BA) sticky state, see tables.zig's
// line_break_pair_table comment for the extra-state layout: eot, sot, then
// ZWSP/OPSP/QUSP/CLSP/CPSP/B2SP/HLHYBA/RIRI starting right after sot.
const line_break_state_hlhyba: u8 = tables.line_break_state_sot + 7;

// LB13 (× CL, × CP, × EX, × SY — unconditional regardless of predecessor;
// unlike IS, these were not relaxed by the number-context revision that
// produced LB25) outranks the whole LB15/18/19 QU cluster, same as LB8/14
// below — a QU predecessor must not let the LB19a East-Asian-width
// recompute clobber this, e.g. Pf&QU immediately followed by EX.
fn isLb13UnconditionalClass(class: u8) bool {
    return class == @intFromEnum(LineBreakClass.cl) or class == @intFromEnum(LineBreakClass.cp) or
        class == @intFromEnum(LineBreakClass.ex) or class == @intFromEnum(LineBreakClass.sy);
}

// QUSP (QU followed by a run of spaces) sticky state — same layout as above,
// third extra state after sot (sot, ZWSP, OPSP, QUSP, ...).
const line_break_state_qusp: u8 = tables.line_break_state_sot + 3;

// Walks back from `boundary_index - 1` over a run of literal SP characters
// to the index of the QU character that started it (only ever called when
// `prev_state == line_break_state_qusp`, which guarantees such a QU
// exists).
fn quSpaceRunOriginIndex(text: []const u21, boundary_index: usize) usize {
    var k = boundary_index - 1;
    while (k > 0 and LineBreakClass.of(text[k]) == .sp) : (k -= 1) {}
    // The QU may carry a CM/ZWJ run attached via LB9/LB10 (e.g. QU CM SP*)
    // — skip back over that too to reach the actual QU codepoint.
    while (k > 0 and (LineBreakClass.of(text[k]) == .cm or LineBreakClass.of(text[k]) == .zwj)) : (k -= 1) {}
    return k;
}

// LB15a's own precondition on what precedes the [Pi&QU]: "(sot | BK | CR |
// LF | NL | OP | QU | GL | SP | ZW) [Pi&QU] SP* ×" — the no-break-through-
// the-space-run behavior only fires when the Pi quote itself sits at a
// line/clause start, not e.g. right after a plain letter.
fn isLb15aStartContext(class: LineBreakClass) bool {
    return switch (class) {
        .bk, .cr, .lf, .nl, .op, .qu, .gl, .sp, .zw => true,
        else => false,
    };
}

fn lb15aOriginContextOk(text: []const u21, origin_index: usize) bool {
    if (origin_index == 0) return true; // sot
    return isLb15aStartContext(LineBreakClass.of(text[origin_index - 1]));
}

// The RHS class set shared by LB15b (× [Pf&QU] (SP|GL|WJ|CL|QU|CP|EX|IS|SY|
// BK|CR|LF|NL|ZW|eot)).
fn isLb15bFollowClass(class: LineBreakClass) bool {
    return switch (class) {
        .sp, .gl, .wj, .cl, .qu, .cp, .ex, .is, .sy, .bk, .cr, .lf, .nl, .zw => true,
        else => false,
    };
}

// UAX #14 line-break opportunities over a codepoint sequence, ported from
// vendor/unicode-linebreak's linebreaks() (src/lib.rs): step a small state
// machine through tables.line_break_pair_table, one table lookup per
// codepoint. The table (built by
// test/fixtures/unicode/gen/gen_tables.py:build_line_break_pair_table,
// itself a port of gen-tables/src/main.rs's rules2table! macro) already
// encodes LB1-LB31 rule precedence, LB9/LB10 combining-mark attachment
// (via "sticky" extra states), and the LB7/8/14/15/16/17/21a/30a
// intervening-space-run rules — no separate per-rule matching needed. Only
// LB8a (ZWJ) is special-cased outside the table, matching upstream.
//
// The vendored crate is pinned to Unicode 15.0 rules (see
// vendor/unicode-linebreak/src/lib.rs UNICODE_VERSION), but the conformance
// corpus here is 16.0, which revised two rules after that pin: LB19/LB19a
// (quotation marks glue to both neighbors by default, ahead of LB18,
// except right after a space when not a closing (Pf) quote, or when
// "surrounded" by East-Asian-wide characters) and LB30 (its OP/CP
// no-break gained an "except when East-Asian-wide" condition). Both are
// applied as small overrides on top of the ported table rather than
// re-deriving the whole algorithm, since neither rule's class ever
// participates in any other LB20-LB31 rule (checked against
// gen-tables/src/main.rs's rule list), so the override fully determines
// the outcome for exactly the pairs it touches.
//
// NOTE: LB28a (Aksara clusters, whose classes we fold into AL/CM at
// table-gen time) isn't implemented — a narrow gap limited to Southeast
// Asian script tailoring. Upgrade path: add the Aksara pair rules if those
// scripts need exact conformance.
// word-break: break-all treats NU/AL/SA-class characters as ID for the
// purpose of line-breaking (CSS Text Module Level 3). HL (Hebrew letter)
// is deliberately excluded — the spec's list is NU/AL/SA only.
fn isBreakAllLetterClass(class: u8) bool {
    return class == @intFromEnum(LineBreakClass.al) or class == @intFromEnum(LineBreakClass.nu) or
        class == @intFromEnum(LineBreakClass.sa);
}

// word-break: keep-all suppresses implicit break opportunities between
// NU/AL/AI/ID pairs (CSS Text Module Level 3). SA isn't in this set, so
// keep-all never touches dictionary-based breaks inside Thai/Lao/Khmer/
// Myanmar words — matching the spec's carve-out that those stay permitted
// under keep-all.
fn isKeepAllClass(class: u8) bool {
    return class == @intFromEnum(LineBreakClass.nu) or class == @intFromEnum(LineBreakClass.al) or
        class == @intFromEnum(LineBreakClass.ai) or class == @intFromEnum(LineBreakClass.id);
}

const line_break_cjk_hyphen_wave_dash: u21 = 0x301C;
const line_break_cjk_hyphen_double: u21 = 0x30A0;
const line_break_narrow_hyphen: u21 = 0x2010;
const line_break_narrow_en_dash: u21 = 0x2013;
const line_break_centered_punctuation = [_]u21{ 0x30FB, 0xFF1A, 0xFF1B };

// CSS Text Module Level 3 `line-break` tailoring: `.normal`/`.loose` relax
// specific UAX #14 no-break defaults for CJK punctuation, on top of the
// unmodified `.strict` result computed above (callers only reach this when
// that result was a non-mandatory non-break). Every rule here only adds a
// break opportunity, never removes one, matching the spec's tables.
//
// NOTE: the spec qualifies the PO/PR (suffix/prefix) and centered-
// punctuation exceptions by East Asian Width; here they apply to the whole
// class/codepoint set, and the centered-punctuation codepoints only cover
// the three the spec names explicitly (KATAKANA MIDDLE DOT, FULLWIDTH
// COLON/SEMICOLON). Upgrade path: add the width qualifiers and the rest of
// the centered-punctuation set if strict CSS conformance is needed.
fn tailoredLineBreakAllowed(strictness: LineBreakStrictness, text: []const u21, boundary_index: usize, prev_state: u8) bool {
    const at = text[boundary_index];
    if (at == line_break_cjk_hyphen_wave_dash or at == line_break_cjk_hyphen_double) return true; // normal + loose

    if (strictness != .loose) return false;

    const prev_class_valid = prev_state < tables.line_break_col_eot;
    const class_at = @intFromEnum(LineBreakClass.of(at));

    if (class_at == @intFromEnum(LineBreakClass.cj)) return true; // break before CJ (small kana etc.)
    if (prev_class_valid and prev_state == @intFromEnum(LineBreakClass.cj)) return true; // break after CJ
    if (prev_class_valid and prev_state == @intFromEnum(LineBreakClass.in) and
        class_at == @intFromEnum(LineBreakClass.in)) return true; // break within inseparable-character runs
    for (line_break_centered_punctuation) |cp| {
        if (at == cp) return true;
    }
    if (prev_class_valid and prev_state == @intFromEnum(LineBreakClass.pr)) return true; // break after prefix
    if (class_at == @intFromEnum(LineBreakClass.po)) return true; // break before suffix
    if ((at == line_break_narrow_hyphen or at == line_break_narrow_en_dash) and
        prev_class_valid and prev_state == @intFromEnum(LineBreakClass.id)) return true;

    return false;
}

pub const LineBreakIterator = struct {
    text: []const u21,
    pos: usize = 0,
    state: u8 = tables.line_break_state_sot,
    prev_was_zwj: bool = false,
    done: bool = false,
    /// CSS `line-break` strictness. Default `.strict` reproduces the exact
    /// UAX #14 default algorithm (unchanged from before tailoring existed).
    strictness: LineBreakStrictness = .strict,
    /// CSS `word-break` mode. Default `.normal` is a no-op.
    word_break: WordBreakMode = .normal,

    pub fn init(text: []const u21) LineBreakIterator {
        return .{ .text = text };
    }

    pub fn next(self: *LineBreakIterator) ?LineBreakBoundary {
        if (self.done) return null;
        if (self.text.len == 0) {
            self.done = true;
            return null;
        }
        while (self.pos < self.text.len) {
            const raw_class: u8 = @intFromEnum(LineBreakClass.of(self.text[self.pos]));
            var class: u8 = raw_class;
            if (self.word_break == .break_all and isBreakAllLetterClass(class)) {
                class = @intFromEnum(LineBreakClass.id);
            }
            const val = tables.line_break_pair_table[self.state][class];
            var is_mandatory = val & tables.line_break_mandatory_break_bit != 0;
            var is_break = val & tables.line_break_allowed_break_bit != 0;
            const boundary_index = self.pos;
            const prev_state = self.state;

            const prev_is_qusp = prev_state == line_break_state_qusp;
            const qusp_origin_index = if (prev_is_qusp) quSpaceRunOriginIndex(self.text, boundary_index) else 0;
            const qusp_origin_is_pi = prev_is_qusp and isInitialPunctuation(self.text[qusp_origin_index]) and
                lb15aOriginContextOk(self.text, qusp_origin_index);
            // LB4/LB5 (BK/CR/LF/NL force a mandatory break) rank far above
            // every rule our overrides implement — if the table already
            // says this boundary is mandatory, none of them apply, so skip
            // the whole chain rather than let an override clobber it.
            const table_says_mandatory = is_mandatory;
            // LB8 (ZW SP* ÷, unconditional) and LB14 (OP SP* ×,
            // unconditional) also both outrank the whole LB15/18/19 QU
            // cluster and are unaffected by the 16.0 delta (they don't
            // interact with Pi/Pf at all) — the base table already gets
            // them right for every column including QU, so leave a
            // ZW/ZWSP or OP/OPSP-run-exit boundary alone rather than let the
            // class==QU branch below recompute it from scratch. The plain
            // (no-run-yet) ZW/OP state matters too: the table only enters
            // the ZWSP/OPSP sticky state once a SP has actually followed,
            // so "ZW QU" with no intervening space is still prev_state ==
            // plain ZW, not ZWSP.
            const prev_is_zwsp = prev_state == tables.line_break_state_sot + 1 or
                prev_state == @intFromEnum(LineBreakClass.zw);
            const prev_is_opsp = prev_state == tables.line_break_state_sot + 2 or
                prev_state == @intFromEnum(LineBreakClass.op);

            if (table_says_mandatory or prev_is_zwsp or prev_is_opsp or isLb13UnconditionalClass(class)) {
                // leave table's decision untouched
            } else if (prev_is_qusp and qusp_origin_is_pi) {
                // LB15a: "(sot|BK|CR|LF|NL|OP|QU|GL|SP|ZW) [Pi&QU] SP* ×" —
                // no break exiting a space run that traces back to an
                // initial-punctuation quote, regardless of what follows
                // (even another QU); this is the highest-priority rule in
                // the QU cluster, so it's checked before the class==QU and
                // prev==QU branches below.
                is_break = false;
                is_mandatory = false;
            } else if (class == @intFromEnum(LineBreakClass.qu)) { // LB15b/LB18/LB19/LB19a: boundary before a QU
                // A literal preceding SP, or a SP-run whose origin traces
                // to QU/CL/CP/B2 (QUSP already excludes the Pi-origin case,
                // short-circuited above; CLSP/CPSP/B2SP have no rule below
                // 18 that constrains the QU column, so LB18 governs them
                // same as plain SP), all count as "immediately preceded by
                // SP" for LB18's purposes. OPSP/ZWSP are handled by the
                // outer skip above (LB14/LB8 outrank this cluster entirely).
                const prev_sp_like = prev_is_qusp or prev_state == tables.line_break_state_sot + 4 or
                    prev_state == tables.line_break_state_sot + 5 or prev_state == tables.line_break_state_sot + 6 or
                    (boundary_index > 0 and LineBreakClass.of(self.text[boundary_index - 1]) == .sp);
                const q = self.text[boundary_index];
                if (isFinalPunctuation(q)) { // Pf&QU: LB15b, else LB18-vs-LB19
                    const follow_ok = boundary_index + 1 >= self.text.len or
                        isLb15bFollowClass(LineBreakClass.of(self.text[boundary_index + 1]));
                    is_break = !follow_ok and prev_sp_like;
                } else if (isInitialPunctuation(q)) { // Pi&QU: LB18-vs-LB19a (LB19's "×[QU-Pi]" excludes Pi)
                    is_break = if (prev_sp_like)
                        true
                    else
                        boundary_index > 0 and isEastAsianWide(self.text[boundary_index - 1]) and
                            boundary_index + 1 < self.text.len and isEastAsianWide(self.text[boundary_index + 1]);
                } else { // plain QU: LB18-vs-LB19 ("×[QU-Pi]" unconditional no-break unless LB18 wins)
                    is_break = prev_sp_like;
                }
                is_mandatory = false;
            } else if (prev_state == @intFromEnum(LineBreakClass.qu)) { // LB19/LB19a: boundary immediately after QU, no space
                const q = self.text[boundary_index - 1];
                if (isFinalPunctuation(q)) { // Pf&QU: LB19a symmetric East-Asian check
                    is_break = boundary_index >= 2 and isEastAsianWide(self.text[boundary_index - 2]) and
                        isEastAsianWide(self.text[boundary_index]);
                } else { // Pi or plain: LB19's "[QU-Pf] ×" unconditional no-break
                    is_break = false;
                }
                is_mandatory = false;
            } else if (prev_is_qusp and class == @intFromEnum(LineBreakClass.op)) {
                // Undo the base (15.0) table's "QU SP* × OP" persistence
                // (old LB15) for a non-Pi-origin run: 16.0 restricts that
                // no-break-through-spaces behavior to Pi&QU only (LB15a,
                // handled above); for any other QU, ordinary LB18 (SP ÷)
                // governs the OP column same as it already correctly does
                // for every other column via the table's QUSP-aliases-SP
                // behavior (untouched here).
                is_break = true;
                is_mandatory = false;
            } else if (class == @intFromEnum(LineBreakClass.is) and prev_state == @intFromEnum(LineBreakClass.sp) and
                boundary_index + 1 < self.text.len and lb1ResolveForLb25(self.text[boundary_index + 1]) == .nu)
            {
                // LB13's unconditional "× IS" (line 115 in gen_tables.py,
                // ported verbatim from the 15.0-era vendor table) lost its
                // "even after spaces" strength in 16.0, but only for an IS
                // that's about to start a numeric literal (followed by a
                // digit) — e.g. "equals .35 cents": SP then a bare leading
                // decimal point followed by "3" must still break, since
                // LB25's number-range grammar can't glue a *leading* IS
                // into a token (it requires NU first), so this SP-IS pair
                // falls back to plain LB18. A comma or other IS *not*
                // followed by a digit (e.g. "SP ,") stays glued via the
                // untouched table default, same as HY-then-IS ("-.3",
                // predecessor isn't SP so this branch doesn't fire at all).
                is_break = true;
                is_mandatory = false;
            } else if ((prev_state == @intFromEnum(LineBreakClass.al) or prev_state == @intFromEnum(LineBreakClass.hl) or
                prev_state == @intFromEnum(LineBreakClass.nu)) and class == @intFromEnum(LineBreakClass.op))
            { // LB30
                is_break = isEastAsianWide(self.text[boundary_index]);
                is_mandatory = false;
            } else if (prev_state == @intFromEnum(LineBreakClass.cp) and
                (class == @intFromEnum(LineBreakClass.al) or class == @intFromEnum(LineBreakClass.hl) or class == @intFromEnum(LineBreakClass.nu)))
            { // LB30
                is_break = boundary_index > 0 and isEastAsianWide(self.text[boundary_index - 1]);
                is_mandatory = false;
            } else if (boundary_index > 0 and prev_state < tables.line_break_col_eot and
                isLb25TablePair(@enumFromInt(prev_state), LineBreakClass.of(self.text[boundary_index])))
            { // LB25
                is_break = !lb25Prohibited(self.text, boundary_index);
                is_mandatory = false;
            } else if (lb1ResolveForLb25(self.text[boundary_index]) == .al and
                lb20aNoBreakAfterWordInitialHyphen(self.text, boundary_index))
            { // LB20a
                is_break = false;
                is_mandatory = false;
            } else if (prev_state == line_break_state_hlhyba and class == @intFromEnum(LineBreakClass.hl)) { // LB21a
                is_break = true;
                is_mandatory = false;
            } else if (class == @intFromEnum(LineBreakClass.em) and boundary_index > 0 and
                isExtendedPictographicUnassigned(self.text[boundary_index - 1]))
            { // LB30b extension
                is_break = false;
                is_mandatory = false;
            }

            if (!is_break and !is_mandatory and self.strictness != .strict) {
                is_break = tailoredLineBreakAllowed(self.strictness, self.text, boundary_index, prev_state);
            }

            if (is_break and !is_mandatory and self.word_break == .keep_all and
                prev_state < tables.line_break_col_eot and isKeepAllClass(prev_state) and isKeepAllClass(class))
            {
                is_break = false;
            }

            // Dictionary-based segmentation (Thai/Lao/Khmer/Myanmar):
            // UAX #14 gives SA no break opportunities against itself (LB1
            // resolves it AL-like, and AL-AL never breaks), deferring
            // entirely to "a more sophisticated approach" per the spec —
            // that's the dictionary lookup below. Only *adds* break
            // opportunities the base table withheld; never overrides a
            // mandatory break, and runs even under `keep_all` per the CSS
            // Text Module's explicit carve-out (dictionary word breaks
            // inside these scripts stay permitted there).
            if (!is_break and !is_mandatory and boundary_index > 0 and
                raw_class == @intFromEnum(LineBreakClass.sa) and
                LineBreakClass.of(self.text[boundary_index - 1]) == .sa)
            {
                if (dictionaryScriptOf(self.text[boundary_index])) |script| {
                    if (dictionaryScriptOf(self.text[boundary_index - 1]) == script) {
                        is_break = isDictionaryWordBoundary(self.text, boundary_index, script);
                    }
                }
            }

            is_break = is_break and (!self.prev_was_zwj or is_mandatory);

            self.state = val & ~(tables.line_break_allowed_break_bit | tables.line_break_mandatory_break_bit);
            self.prev_was_zwj = class == @intFromEnum(LineBreakClass.zwj);
            self.pos += 1;

            if (is_break) {
                return .{ .index = boundary_index, .opportunity = if (is_mandatory) .mandatory else .allowed };
            }
        }
        self.done = true;
        return .{ .index = self.text.len, .opportunity = .mandatory }; // LB3: always break at eot
    }
};

// Canonical decomposition/composition (UAX #15), ported from
// hb-ot-shape-normalize.cc's decompose()/recompose round plus the
// Hangul algorithmic (de)composition every Unicode-conformant
// implementation special-cases instead of tabulating (UnicodeData.txt
// doesn't list the ~11172 Hangul syllable decompositions individually,
// just First/Last range markers spanning them).
const hangul_s_base: u21 = 0xAC00;
const hangul_l_base: u21 = 0x1100;
const hangul_v_base: u21 = 0x1161;
const hangul_t_base: u21 = 0x11A7;
const hangul_l_count: u21 = 19;
const hangul_v_count: u21 = 21;
const hangul_t_count: u21 = 28;
const hangul_n_count: u21 = hangul_v_count * hangul_t_count;
const hangul_s_count: u21 = hangul_l_count * hangul_n_count;

/// USE (Universal Shaping Engine) category per hb-ot-shaper-use-machine.rl's
/// `export X = N;` numbering; 0 (O, OTHER) for every codepoint not
/// explicitly assigned a different category. See
/// test/fixtures/unicode/gen/gen_use_categories.py for how the table is
/// derived.
pub fn useCategory(codepoint: u21) u8 {
    const category = packedLookup(&tables.use_category_ranges, codepoint);
    return if (category == no_class) 0 else category;
}

/// Canonical_Combining_Class (UnicodeData.txt field 3); 0 for every
/// codepoint not explicitly assigned a nonzero class.
pub fn combiningClass(codepoint: u21) u8 {
    const class = packedLookup(&tables.combining_class_ranges, codepoint);
    return if (class == no_class) 0 else class;
}

/// hb's `modified_combining_class`: canonical class with hb's reordering
/// tweaks (SBL Hebrew point order, Shadda first, Telugu length marks before
/// nukta/virama, Thai/Tibetan vowel order). Shaping sorts and blocks on this.
pub fn modifiedCombiningClass(codepoint: u21) u8 {
    return switch (codepoint) {
        0x1A60, 0x0FC6 => 254,
        0x0F39 => 127,
        else => switch (combiningClass(codepoint)) {
            10 => 22,
            11 => 15,
            12 => 16,
            13 => 17,
            14 => 23,
            15 => 18,
            16 => 19,
            17 => 20,
            18 => 21,
            19 => 14,
            20 => 24,
            21 => 12,
            22 => 25,
            23 => 13,
            24 => 10,
            25 => 11,
            27 => 28,
            28 => 29,
            29 => 30,
            30 => 31,
            31 => 32,
            32 => 33,
            33 => 27,
            84 => 4,
            91 => 5,
            103 => 3,
            130 => 132,
            132 => 131,
            else => |class| class,
        },
    };
}

/// General_Category is Mn, Mc, or Me.
pub fn isUnicodeMark(codepoint: u21) bool {
    return packedContains(&tables.unicode_mark_ranges, codepoint);
}

/// Bidi_Mirroring_Glyph, or `codepoint` itself when it has none.
pub fn bidiMirror(codepoint: u21) u21 {
    const table = &tables.bidi_mirroring;
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const entry_codepoint = table[mid] >> 13;
        if (entry_codepoint < codepoint) {
            lo = mid + 1;
        } else if (entry_codepoint > codepoint) {
            hi = mid;
        } else {
            const delta = @as(i32, @intCast(table[mid] & 0x1FFF)) - 4096;
            return @intCast(@as(i32, codepoint) + delta);
        }
    }
    return codepoint;
}

/// hb's `HB_ARABIC_GENERAL_CATEGORY_IS_WORD`: letters other than cased
/// ones, marks, numbers, symbols, and unassigned/private-use codepoints.
pub fn isArabicWordCategory(codepoint: u21) bool {
    return packedContains(&tables.arabic_word_ranges, codepoint);
}

/// General_Category Nd.
pub fn isDecimalNumber(codepoint: u21) bool {
    return packedContains(&tables.decimal_number_ranges, codepoint);
}

/// Ported from hb-unicode.hh's `is_default_ignorable` - a hardcoded
/// approximation of Default_Ignorable_Code_Point (see that function's
/// comment for the exact character list this covers).
pub fn isDefaultIgnorable(codepoint: u21) bool {
    const plane = codepoint >> 16;
    if (plane == 0) {
        const page = codepoint >> 8;
        return switch (page) {
            0x00 => codepoint == 0x00AD,
            0x03 => codepoint == 0x034F,
            0x06 => codepoint == 0x061C,
            0x17 => codepoint >= 0x17B4 and codepoint <= 0x17B5,
            0x18 => codepoint >= 0x180B and codepoint <= 0x180E,
            0x20 => (codepoint >= 0x200B and codepoint <= 0x200F) or
                (codepoint >= 0x202A and codepoint <= 0x202E) or
                (codepoint >= 0x2060 and codepoint <= 0x206F),
            0xFE => (codepoint >= 0xFE00 and codepoint <= 0xFE0F) or codepoint == 0xFEFF,
            0xFF => codepoint >= 0xFFF0 and codepoint <= 0xFFF8,
            else => false,
        };
    }
    return switch (plane) {
        0x01 => codepoint >= 0x1D173 and codepoint <= 0x1D17A,
        0x0E => codepoint >= 0xE0000 and codepoint <= 0xE0FFF,
        else => false,
    };
}

/// hb-ot-shaper-arabic.cc's hb_arabic_joining_type_t, minus JOINING_TYPE_X
/// (the "not listed, resolve via general category" case) — `arabicJoiningType`
/// resolves that case internally, callers never see it.
pub const ArabicJoiningType = enum(u8) {
    non_joining = 0,
    left_joining = 1,
    right_joining = 2,
    dual_joining = 3,
    alaph = 4,
    dalath_rish = 5,
    transparent = 6,
};

/// Joining_Type/Joining_Group (UAX #53-relevant field of ArabicShaping.txt),
/// used by the Arabic complex shaper's cursive-joining state machine.
/// Codepoints not explicitly listed default to `.transparent` if they're
/// General_Category Mn/Me/Cf (combining marks, format controls — invisible
/// to joining), else `.non_joining` — mirrors hb's `get_joining_type`.
pub fn arabicJoiningType(codepoint: u21) ArabicJoiningType {
    const joining_type = packedLookup(&tables.arabic_joining_ranges, codepoint);
    if (joining_type != no_class) return @enumFromInt(joining_type);
    if (packedContains(&tables.arabic_transparent_ranges, codepoint)) return .transparent;
    return .non_joining;
}

pub const script_common: [4]u8 = .{ 'Z', 'y', 'y', 'y' };
pub const script_inherited: [4]u8 = .{ 'Z', 'i', 'n', 'h' };
pub const script_unknown: [4]u8 = .{ 'Z', 'z', 'z', 'z' };

/// ISO 15924 Script property (UAX #24), same four-letter codes as hb_script_t.
/// Unlisted codepoints are Unknown (`Zzzz`).
pub fn scriptOf(codepoint: u21) [4]u8 {
    const tag_index = packedLookup(&tables.script_ranges, codepoint);
    return if (tag_index == no_class) script_unknown else tables.script_tags[tag_index];
}

// A 4-byte tag compares as one u32 rather than through `mem.eql`'s generic
// byte loop, which profiled hot in cold frames. Byte order is irrelevant to
// equality, so the bitcast needs no endianness handling.
fn tagEql(a: [4]u8, b: [4]u8) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

pub fn scriptIsWeak(script: [4]u8) bool {
    return tagEql(script, script_common) or
        tagEql(script, script_inherited) or
        tagEql(script, script_unknown);
}

/// Resolves Common/Inherited/Unknown against adjacent strong scripts
/// (ICU ScriptRun / UAX #24 itemization, without paired-punctuation
/// matching). `out` is parallel to `codepoints`.
pub fn resolveScripts(codepoints: []const u21, out: [][4]u8) void {
    std.debug.assert(out.len >= codepoints.len);
    for (codepoints, 0..) |cp, i| out[i] = scriptOf(cp);
    resolveScriptsInPlace(out[0..codepoints.len]);
}

/// Same resolution as `resolveScripts` for a caller that already holds each
/// codepoint's raw `scriptOf` value, so the lookup is not repeated.
/// `scripts` enters raw and leaves resolved.
pub fn resolveScriptsInPlace(scripts: [][4]u8) void {
    var prev_strong: ?[4]u8 = null;
    for (scripts) |*script| {
        if (!scriptIsWeak(script.*)) {
            prev_strong = script.*;
        } else if (prev_strong) |strong| {
            script.* = strong;
        }
    }
    // A weak entry that the forward pass already filled holds a strong
    // script from its left, so treating it as strong here is harmless: an
    // entry still weak can only precede the first strong one, and every
    // entry before that is still weak too.
    var next_strong: ?[4]u8 = null;
    var i = scripts.len;
    while (i > 0) {
        i -= 1;
        if (!scriptIsWeak(scripts[i])) {
            next_strong = scripts[i];
        } else if (next_strong) |strong| {
            scripts[i] = strong;
        }
    }
}

/// hb-ot-tag.cc `hb_ot_old_tag_from_script`: ISO 15924 -> OpenType script tag.
pub fn openTypeOldScriptTag(iso: [4]u8) [4]u8 {
    if (tagEql(iso, .{ 'H', 'i', 'r', 'a' }) or tagEql(iso, .{ 'H', 'r', 'k', 't' }))
        return .{ 'k', 'a', 'n', 'a' };
    if (tagEql(iso, .{ 'L', 'a', 'o', 'o' })) return .{ 'l', 'a', 'o', ' ' };
    if (tagEql(iso, .{ 'Y', 'i', 'i', 'i' })) return .{ 'y', 'i', ' ', ' ' };
    if (tagEql(iso, .{ 'N', 'k', 'o', 'o' })) return .{ 'n', 'k', 'o', ' ' };
    if (tagEql(iso, .{ 'V', 'a', 'i', 'i' })) return .{ 'v', 'a', 'i', ' ' };
    if (tagEql(iso, .{ 'Z', 'm', 't', 'h' })) return .{ 'm', 'a', 't', 'h' };
    var tag = iso;
    tag[0] |= 0x20;
    return tag;
}

/// hb-ot-tag.cc `hb_ot_new_tag_from_script` (Indic v2 / mym2). Null if none.
pub fn openTypeNewScriptTag(iso: [4]u8) ?[4]u8 {
    const pairs = [_]struct { iso: [4]u8, ot: [4]u8 }{
        .{ .iso = .{ 'B', 'e', 'n', 'g' }, .ot = .{ 'b', 'n', 'g', '2' } },
        .{ .iso = .{ 'D', 'e', 'v', 'a' }, .ot = .{ 'd', 'e', 'v', '2' } },
        .{ .iso = .{ 'G', 'u', 'j', 'r' }, .ot = .{ 'g', 'j', 'r', '2' } },
        .{ .iso = .{ 'G', 'u', 'r', 'u' }, .ot = .{ 'g', 'u', 'r', '2' } },
        .{ .iso = .{ 'K', 'n', 'd', 'a' }, .ot = .{ 'k', 'n', 'd', '2' } },
        .{ .iso = .{ 'M', 'l', 'y', 'm' }, .ot = .{ 'm', 'l', 'm', '2' } },
        .{ .iso = .{ 'O', 'r', 'y', 'a' }, .ot = .{ 'o', 'r', 'y', '2' } },
        .{ .iso = .{ 'T', 'a', 'm', 'l' }, .ot = .{ 't', 'm', 'l', '2' } },
        .{ .iso = .{ 'T', 'e', 'l', 'u' }, .ot = .{ 't', 'e', 'l', '2' } },
        .{ .iso = .{ 'M', 'y', 'm', 'r' }, .ot = .{ 'm', 'y', 'm', '2' } },
    };
    for (pairs) |p| {
        if (tagEql(iso, p.iso)) return p.ot;
    }
    return null;
}

/// Fills `out` with the OpenType script tags HarfBuzz would try for `iso`
/// (v2 tag first when one exists, then the old-style tag). Returns the
/// written prefix.
pub fn openTypeScriptTags(iso: [4]u8, out: *[2][4]u8) [][4]u8 {
    var n: usize = 0;
    if (openTypeNewScriptTag(iso)) |t| {
        out[n] = t;
        n += 1;
    }
    out[n] = openTypeOldScriptTag(iso);
    n += 1;
    return out[0..n];
}

pub const Decomposition = struct { first: u21, second: u21 };

/// Single-step canonical decomposition (UAX #15 D68): Hangul LVT/LV
/// syllables split algorithmically, everything else via
/// canonical_decomposition_entries. `second == 0` means a singleton
/// decomposition. Null means `codepoint` has no canonical decomposition.
pub fn decomposeCanonical(codepoint: u21) ?Decomposition {
    if (codepoint >= hangul_s_base and codepoint < hangul_s_base + hangul_s_count) {
        const s_index = codepoint - hangul_s_base;
        if (s_index % hangul_t_count == 0) {
            const l_index = s_index / hangul_n_count;
            const v_index = (s_index % hangul_n_count) / hangul_t_count;
            return .{ .first = hangul_l_base + l_index, .second = hangul_v_base + v_index };
        }
        const lv_index = s_index - (s_index % hangul_t_count);
        return .{ .first = hangul_s_base + lv_index, .second = hangul_t_base + (s_index % hangul_t_count) };
    }

    var lo: usize = 0;
    var hi: usize = tables.canonical_decomposition_entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = tables.canonical_decomposition_entries[mid];
        const entry_codepoint: u21 = @truncate(entry >> 42);
        if (codepoint < entry_codepoint) {
            hi = mid;
        } else if (codepoint > entry_codepoint) {
            lo = mid + 1;
        } else {
            return .{ .first = @truncate(entry >> 21), .second = @truncate(entry) };
        }
    }
    return null;
}

/// Single-step canonical composition (UAX #15 R2): the inverse of
/// `decomposeCanonical`'s pair case, honoring Full_Composition_Exclusion
/// (baked into canonical_composition_entries at generation time - see
/// gen_tables.py). Null means `first`/`second` don't canonically compose.
pub fn composeCanonical(first: u21, second: u21) ?u21 {
    if (first >= hangul_l_base and first < hangul_l_base + hangul_l_count and
        second >= hangul_v_base and second < hangul_v_base + hangul_v_count)
    {
        const l_index = first - hangul_l_base;
        const v_index = second - hangul_v_base;
        return hangul_s_base + (l_index * hangul_v_count + v_index) * hangul_t_count;
    }
    if (first >= hangul_s_base and first < hangul_s_base + hangul_s_count and
        (first - hangul_s_base) % hangul_t_count == 0 and
        second > hangul_t_base and second < hangul_t_base + hangul_t_count)
    {
        return first + (second - hangul_t_base);
    }

    const key = (@as(u64, first) << 21) | @as(u64, second);
    var lo: usize = 0;
    var hi: usize = tables.canonical_composition_entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = tables.canonical_composition_entries[mid];
        const entry_key = entry >> 21;
        if (key < entry_key) {
            hi = mid;
        } else if (key > entry_key) {
            lo = mid + 1;
        } else {
            return @truncate(entry);
        }
    }
    return null;
}
