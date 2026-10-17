//! Combining and applying byte-span edits, shared by the CLI's `--fix` and the
//! language server's fix-all so both accept exactly the same edit sets.
const std = @import("std");
const analysis = @import("../analysis.zig");
const tokenize = @import("tokens.zig").tokenize;

/// The subset of `edits` that can be applied together, in source order: an
/// edit overlapping an earlier accepted one is dropped, and identical
/// duplicates collapse to one. The caller owns the result.
pub fn nonOverlapping(allocator: std.mem.Allocator, edits: []const analysis.Edit) ![]const analysis.Edit {
    if (edits.len == 0) return &.{};
    const sorted = try allocator.dupe(analysis.Edit, edits);
    defer allocator.free(sorted);
    std.mem.sort(analysis.Edit, sorted, {}, struct {
        fn lessThan(_: void, left: analysis.Edit, right: analysis.Edit) bool {
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return left.span.end < right.span.end;
        }
    }.lessThan);
    var accepted: std.ArrayList(analysis.Edit) = .empty;
    errdefer accepted.deinit(allocator);
    for (sorted) |edit| {
        if (accepted.items.len != 0) {
            const previous = accepted.last().?;
            if (edit.span.start < previous.span.end) continue;
            if (std.meta.eql(edit.span, previous.span) and std.mem.eql(u8, edit.replacement, previous.replacement)) continue;
        }
        try accepted.append(allocator, edit);
    }
    return try accepted.toOwnedSlice(allocator);
}

/// The edits of `fixes` that can be applied together, in source order. Each
/// fix is accepted whole or not at all, so a multi-edit fix is never applied
/// halfway: a fix with an edit overlapping one of an earlier accepted fix (or
/// another of its own) is dropped. Fixes are taken in the order of their first
/// edit, and identical duplicate edits collapse to one. A lone deletion that
/// overlaps only accepted deletions merges with them. The caller owns the
/// result.
pub fn wholeFixes(allocator: std.mem.Allocator, fixes: []const []const analysis.Edit) ![]const analysis.Edit {
    const ordered = try allocator.dupe([]const analysis.Edit, fixes);
    defer allocator.free(ordered);
    std.mem.sort([]const analysis.Edit, ordered, {}, struct {
        fn lessThan(_: void, left: []const analysis.Edit, right: []const analysis.Edit) bool {
            return firstStart(left) < firstStart(right);
        }
    }.lessThan);
    // Sorted by span and pairwise non-overlapping, so the ends never decrease
    // either and a binary search finds the edits near a candidate.
    var accepted: std.ArrayList(analysis.Edit) = .empty;
    errdefer accepted.deinit(allocator);
    var pending: std.ArrayList(analysis.Edit) = .empty;
    defer pending.deinit(allocator);
    next_fix: for (ordered) |edits| {
        if (edits.len == 1 and try absorbDeletion(allocator, &accepted, edits[0])) continue;
        pending.clearRetainingCapacity();
        for (edits) |edit| {
            switch (conflict(accepted.items, edit)) {
                .overlap => continue :next_fix,
                .duplicate => continue,
                .none => {},
            }
            switch (conflict(pending.items, edit)) {
                .overlap => continue :next_fix,
                .duplicate => continue,
                .none => try insertSorted(allocator, &pending, edit),
            }
        }
        for (pending.items) |edit| try insertSorted(allocator, &accepted, edit);
    }
    return try accepted.toOwnedSlice(allocator);
}

/// Merges a lone deletion into the accepted deletions it overlaps, as when two
/// removed lines each claim the blank line between them: deleting the union is
/// what applying both would mean. False when `edit` overlaps nothing or meets
/// an edit that writes text, which the caller then judges as usual.
fn absorbDeletion(allocator: std.mem.Allocator, accepted: *std.ArrayList(analysis.Edit), edit: analysis.Edit) !bool {
    if (edit.replacement.len != 0) return false;
    const items = accepted.items;
    var first = std.sort.lowerBound(analysis.Edit, items, edit.span.start, struct {
        fn order(start: usize, item: analysis.Edit) std.math.Order {
            return std.math.order(start, item.span.end);
        }
    }.order);
    while (first < items.len and items[first].span.start <= edit.span.end and !overlaps(items[first].span, edit.span)) first += 1;
    if (first >= items.len or !overlaps(items[first].span, edit.span)) return false;
    var span = edit.span;
    var last = first;
    while (last < items.len and overlaps(items[last].span, span)) : (last += 1) {
        if (items[last].replacement.len != 0) return false;
        span = .{ .start = @min(span.start, items[last].span.start), .end = @max(span.end, items[last].span.end) };
    }
    // An edit inside the widened span would be swallowed.
    if (first > 0 and items[first - 1].span.end > span.start) return false;
    if (last < items.len and items[last].span.start < span.end) return false;
    try accepted.replaceRange(allocator, first, last - first, &.{.{ .span = span, .replacement = "" }});
    return true;
}

fn overlaps(left: std.zig.Token.Loc, right: std.zig.Token.Loc) bool {
    return left.start < right.end and right.start < left.end;
}

fn firstStart(edits: []const analysis.Edit) usize {
    var start: usize = std.math.maxInt(usize);
    for (edits) |edit| start = @min(start, edit.span.start);
    return start;
}

const Conflict = enum { none, duplicate, overlap };

/// How `edit` relates to the sorted, non-overlapping `edits`.
fn conflict(edits: []const analysis.Edit, edit: analysis.Edit) Conflict {
    var index = std.sort.lowerBound(analysis.Edit, edits, edit.span.start, struct {
        fn order(start: usize, item: analysis.Edit) std.math.Order {
            return std.math.order(start, item.span.end);
        }
    }.order);
    while (index < edits.len and edits[index].span.start <= edit.span.end) : (index += 1) {
        const other = edits[index];
        if (std.meta.eql(other.span, edit.span) and std.mem.eql(u8, other.replacement, edit.replacement)) return .duplicate;
        // Insertions at one point, or at a replacement's edge, apply in order.
        if (edit.span.start < other.span.end and other.span.start < edit.span.end) return .overlap;
    }
    return .none;
}

/// Inserts `edit` after every edit of `list` that sorts at or before it, so
/// insertions at one point keep their arrival order.
fn insertSorted(allocator: std.mem.Allocator, list: *std.ArrayList(analysis.Edit), edit: analysis.Edit) !void {
    const index = std.sort.upperBound(analysis.Edit, list.items, edit, struct {
        fn order(key: analysis.Edit, item: analysis.Edit) std.math.Order {
            if (key.span.start != item.span.start) return std.math.order(key.span.start, item.span.start);
            return std.math.order(key.span.end, item.span.end);
        }
    }.order);
    try list.insert(allocator, index, edit);
}

/// The edits of every fix-all fix in `findings` that can be applied together.
pub fn safeFixAll(allocator: std.mem.Allocator, findings: []const analysis.Finding) ![]const analysis.Edit {
    var candidates: std.ArrayList([]const analysis.Edit) = .empty;
    defer candidates.deinit(allocator);
    for (findings) |finding| {
        for (finding.fixes) |fix| {
            if (fix.fix_all) try candidates.append(allocator, fix.edits);
        }
    }
    return wholeFixes(allocator, candidates.items);
}

/// The most fix-all passes `fixAll` runs over one source.
pub const max_fix_all_passes = 4;

pub const FixedSource = struct {
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    /// Edits applied over all passes; zero when `source` is the input.
    edits: usize,
};

/// `source` with the fix-all edits of the rules `configuration` enables
/// applied, pass after pass until a pass has none (at most
/// `max_fix_all_passes`): one fix can expose another, as when a migrated call
/// becomes a single-byte search or a rewritten reference leaves its import
/// unused, and a second run must find nothing left to do. `tokens` are those of
/// `source`. Results are allocated with `allocator`, which should be an arena.
pub fn fixAll(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: analysis.Configuration,
) !FixedSource {
    return fixAllOf(allocator, source, tokens, configuration, null);
}

/// `fixAll` applying only the fixes of the findings of `rules`, when given.
/// Every enabled rule still runs, so the findings that depend on the others,
/// such as unused suppressions, are the ones `fixAll` sees.
pub fn fixAllOf(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: analysis.Configuration,
    rules: ?std.EnumSet(analysis.Rule),
) !FixedSource {
    var fixed: FixedSource = .{ .source = source, .tokens = tokens, .edits = 0 };
    for (0..max_fix_all_passes) |_| {
        var found: []const analysis.Finding = try analysis.findingsWith(allocator, fixed.source, configuration, .{ .tokens = fixed.tokens });
        if (rules) |selected| found = try findingsOf(allocator, found, selected);
        const edits = try collapseEmptiedBlocks(allocator, fixed.source, fixed.tokens, try safeFixAll(allocator, found));
        if (edits.len == 0) break;
        const next = try apply(allocator, fixed.source, edits);
        if (std.mem.eql(u8, next, fixed.source)) break;
        fixed = .{ .source = next, .tokens = try tokenize(allocator, next), .edits = fixed.edits + edits.len };
    }
    return fixed;
}

fn findingsOf(
    allocator: std.mem.Allocator,
    found: []const analysis.Finding,
    rules: std.EnumSet(analysis.Rule),
) ![]const analysis.Finding {
    var kept: std.ArrayList(analysis.Finding) = .empty;
    errdefer kept.deinit(allocator);
    for (found) |finding| if (rules.contains(finding.rule)) try kept.append(allocator, finding);
    return kept.toOwnedSlice(allocator);
}

/// The edits of `source` that make what `fixAll` makes of it, for a caller
/// that already has the first pass's edits (the language server's findings
/// also use the compiler's facts). Each later pass's edits are mapped back
/// through the earlier ones, merging with any they meet, so one sorted,
/// non-overlapping and non-touching edit set yields the converged text. When
/// the first pass exposes nothing more, its edits are returned as `fixAll`
/// would apply them. `tokens` are those of `source`; `allocator` should be an
/// arena, as for `fixAll`.
pub fn convergedFixAll(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    first_pass: []const analysis.Edit,
    configuration: analysis.Configuration,
) ![]const analysis.Edit {
    const first = try collapseEmptiedBlocks(allocator, source, tokens, first_pass);
    var composition: Composition = .{};
    var current = source;
    var edits = first;
    var passes: usize = 0;
    while (passes < max_fix_all_passes and edits.len != 0) {
        const next = try apply(allocator, current, edits);
        if (std.mem.eql(u8, next, current)) break;
        try composition.add(allocator, edits);
        current = next;
        passes += 1;
        if (passes == max_fix_all_passes) break;
        const current_tokens = try tokenize(allocator, current);
        const found = try analysis.findingsWith(allocator, current, configuration, .{ .tokens = current_tokens });
        edits = try collapseEmptiedBlocks(allocator, current, current_tokens, try safeFixAll(allocator, found));
    }
    if (passes <= 1) return first;
    return composition.originalEdits(allocator, source, current);
}

/// `edits`, sorted and non-overlapping as `wholeFixes` returns them, with
/// each run of deletions that together empty a block widened to everything
/// between its braces. A removal leaving its block empty already writes it
/// `{}`, but two removals each see the other's line still there, and together
/// (or merged into one deletion) would leave `{` and `}` on lines of their
/// own. Returns `edits` itself when no run empties a block.
pub fn collapseEmptiedBlocks(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    edits: []const analysis.Edit,
) ![]const analysis.Edit {
    var collapsed: std.ArrayList(analysis.Edit) = .empty;
    errdefer collapsed.deinit(allocator);
    var copied: usize = 0;
    var first: usize = 0;
    while (first < edits.len) {
        if (edits[first].replacement.len != 0) {
            first += 1;
            continue;
        }
        var last = first;
        while (last + 1 < edits.len and edits[last + 1].replacement.len == 0 and
            isBlank(source[edits[last].span.end..edits[last + 1].span.start])) last += 1;
        defer first = last + 1;
        const start = edits[first].span.start;
        const end = edits[last].span.end;
        const opening = std.mem.trimEnd(u8, source[0..start], " \t\r\n").len;
        const closing = end + (source[end..].len - std.mem.trimStart(u8, source[end..], " \t\r\n").len);
        if (opening == 0 or closing == source.len or !braceTokenAt(tokens, opening - 1, .l_brace) or
            !braceTokenAt(tokens, closing, .r_brace)) continue;
        // An edit that writes text between the braces keeps the block.
        if (first > 0 and edits[first - 1].span.end > opening) continue;
        if (last + 1 < edits.len and edits[last + 1].span.start < closing) continue;
        if (first == last and start == opening and end == closing) continue;
        try collapsed.appendSlice(allocator, edits[copied..first]);
        try collapsed.append(allocator, .{ .span = .{ .start = opening, .end = closing }, .replacement = "" });
        copied = last + 1;
    }
    if (copied == 0) return edits;
    try collapsed.appendSlice(allocator, edits[copied..]);
    return try collapsed.toOwnedSlice(allocator);
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

/// Whether a token tagged `tag` starts at byte `offset`, so a brace in a
/// comment or string is not taken for one.
fn braceTokenAt(tokens: []const std.zig.Token, offset: usize, tag: std.zig.Token.Tag) bool {
    const index = std.sort.lowerBound(std.zig.Token, tokens, offset, struct {
        fn order(target: usize, token: std.zig.Token) std.math.Order {
            return std.math.order(target, token.loc.start);
        }
    }.order);
    return index < tokens.len and tokens[index].loc.start == offset and tokens[index].tag == tag;
}

/// Edits of an original text that together make several passes of edits,
/// each pass applied to the previous one's result.
const Composition = struct {
    /// Sorted, non-overlapping and non-touching; between two regions the
    /// texts agree.
    regions: std.ArrayList(Region) = .empty,

    const Region = struct {
        /// The bytes of the original text this region replaces.
        original: std.zig.Token.Loc,
        /// The bytes of the latest text that replace them.
        current: std.zig.Token.Loc,
    };

    /// Composes a pass of sorted, non-overlapping `edits` of the latest text.
    fn add(composition: *Composition, allocator: std.mem.Allocator, edits: []const analysis.Edit) !void {
        const regions = composition.regions.items;
        var merged: std.ArrayList(Region) = .empty;
        try merged.ensureTotalCapacity(allocator, regions.len + edits.len);
        // Outside the regions seen so far, how far the latest text is ahead of
        // the original, and the next text ahead of the latest.
        var original_lead: isize = 0;
        var next_lead: isize = 0;
        var region_index: usize = 0;
        var edit_index: usize = 0;
        while (region_index < regions.len or edit_index < edits.len) {
            const from_region = edit_index == edits.len or
                (region_index < regions.len and regions[region_index].current.start <= edits[edit_index].span.start);
            const start = if (from_region) regions[region_index].current.start else edits[edit_index].span.start;
            const original_start = if (from_region) regions[region_index].original.start else shifted(start, -original_lead);
            const next_start = shifted(start, next_lead);
            // Take every region and edit that overlaps or touches the group,
            // so an insertion at a region's edge lands on the right side.
            var end = start;
            while (true) {
                if (region_index < regions.len and regions[region_index].current.start <= end) {
                    const region = regions[region_index];
                    end = @max(end, region.current.end);
                    original_lead += length(region.current) - length(region.original);
                    region_index += 1;
                } else if (edit_index < edits.len and edits[edit_index].span.start <= end) {
                    const edit = edits[edit_index];
                    end = @max(end, edit.span.end);
                    next_lead += @as(isize, @intCast(edit.replacement.len)) - length(edit.span);
                    edit_index += 1;
                } else break;
            }
            merged.appendAssumeCapacity(.{
                .original = .{ .start = original_start, .end = shifted(end, -original_lead) },
                .current = .{ .start = next_start, .end = shifted(end, next_lead) },
            });
        }
        composition.regions.deinit(allocator);
        composition.regions = merged;
    }

    /// The edits of `original` that make `latest`, the text after every pass.
    fn originalEdits(composition: Composition, allocator: std.mem.Allocator, original: []const u8, latest: []const u8) ![]const analysis.Edit {
        var result: std.ArrayList(analysis.Edit) = .empty;
        errdefer result.deinit(allocator);
        for (composition.regions.items) |region| {
            const replacement = latest[region.current.start..region.current.end];
            if (std.mem.eql(u8, replacement, original[region.original.start..region.original.end])) continue;
            try result.append(allocator, .{ .span = region.original, .replacement = replacement });
        }
        return try result.toOwnedSlice(allocator);
    }

    fn length(span: std.zig.Token.Loc) isize {
        return @intCast(span.end - span.start);
    }

    fn shifted(offset: usize, lead: isize) usize {
        return @intCast(@as(isize, @intCast(offset)) + lead);
    }
};

/// `source` with `edits` applied. The edits must be sorted and non-overlapping,
/// as `nonOverlapping` returns them.
pub fn apply(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    edits: []const analysis.Edit,
) ![:0]const u8 {
    var fixed: std.ArrayList(u8) = .empty;
    errdefer fixed.deinit(allocator);
    try fixed.ensureTotalCapacity(allocator, source.len);
    var source_offset: usize = 0;
    for (edits) |edit| {
        std.debug.assert(source_offset <= edit.span.start);
        std.debug.assert(edit.span.end <= source.len);
        try fixed.appendSlice(allocator, source[source_offset..edit.span.start]);
        try fixed.appendSlice(allocator, edit.replacement);
        source_offset = edit.span.end;
    }
    try fixed.appendSlice(allocator, source[source_offset..]);
    return try fixed.toOwnedSliceSentinel(allocator, 0);
}

test "overlapping edits are dropped and duplicates collapse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const accepted = try nonOverlapping(arena_state.allocator(), &.{
        .{ .span = .{ .start = 10, .end = 14 }, .replacement = "b" },
        .{ .span = .{ .start = 0, .end = 4 }, .replacement = "a" },
        .{ .span = .{ .start = 2, .end = 6 }, .replacement = "overlaps" },
        .{ .span = .{ .start = 10, .end = 14 }, .replacement = "b" },
        .{ .span = .{ .start = 14, .end = 14 }, .replacement = "c" },
    });
    try std.testing.expectEqual(@as(usize, 3), accepted.len);
    try std.testing.expectEqualStrings("a", accepted[0].replacement);
    try std.testing.expectEqualStrings("b", accepted[1].replacement);
    try std.testing.expectEqualStrings("c", accepted[2].replacement);
}

test "edits apply in source order" {
    const fixed = try apply(std.testing.allocator, "const a = 1;", &.{
        .{ .span = .{ .start = 6, .end = 7 }, .replacement = "value" },
        .{ .span = .{ .start = 10, .end = 11 }, .replacement = "2" },
    });
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings("const value = 2;", fixed);
}

test "fix-all collects only fix-all fixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const findings = [_]analysis.Finding{.{
        .rule = .redundant_boolean_if,
        .level = .warning,
        .span = .{ .start = 0, .end = 1 },
        .message = "x",
        .fixes = &.{
            .{ .title = "safe", .kind = .quickfix, .edits = &.{.{ .span = .{ .start = 0, .end = 1 }, .replacement = "a" }}, .fix_all = true },
            .{ .title = "manual", .kind = .quickfix, .edits = &.{.{ .span = .{ .start = 2, .end = 3 }, .replacement = "b" }} },
        },
    }};
    const edits = try safeFixAll(arena_state.allocator(), &findings);
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqualStrings("a", edits[0].replacement);
}

test "fix-all edits keep same-position insertions in input order and drop overlaps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const survivors = try nonOverlapping(arena, &.{
        .{ .span = .{ .start = 5, .end = 9 }, .replacement = "replacement" },
        .{ .span = .{ .start = 3, .end = 3 }, .replacement = "first insertion" },
        .{ .span = .{ .start = 3, .end = 3 }, .replacement = "first insertion" },
        .{ .span = .{ .start = 3, .end = 3 }, .replacement = "second insertion" },
        .{ .span = .{ .start = 7, .end = 12 }, .replacement = "overlaps the replacement" },
    });

    try std.testing.expectEqual(@as(usize, 3), survivors.len);
    try std.testing.expectEqualStrings("first insertion", survivors[0].replacement);
    try std.testing.expectEqualStrings("second insertion", survivors[1].replacement);
    try std.testing.expectEqualStrings("replacement", survivors[2].replacement);
}

test "fix-all accepts each fix whole or not at all" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The second fix rewrites at 2 and renames at 10; its rewrite overlaps the
    // first fix, so its rename must not be applied alone.
    const edits = try wholeFixes(arena, &.{
        &.{.{ .span = .{ .start = 1, .end = 6 }, .replacement = "first" }},
        &.{
            .{ .span = .{ .start = 10, .end = 13 }, .replacement = "renamed" },
            .{ .span = .{ .start = 2, .end = 4 }, .replacement = "needle" },
        },
        &.{
            .{ .span = .{ .start = 30, .end = 30 }, .replacement = "(" },
            .{ .span = .{ .start = 34, .end = 34 }, .replacement = ")" },
        },
    });
    try std.testing.expectEqual(@as(usize, 3), edits.len);
    try std.testing.expectEqualStrings("first", edits[0].replacement);
    try std.testing.expectEqualStrings("(", edits[1].replacement);
    try std.testing.expectEqualStrings(")", edits[2].replacement);
}

test "fix-all merges deletions that overlap on a shared blank line" {
    const source: [:0]const u8 = "const a = 1;\n\nconst b = 2;\n\nconst c = 3;\n";
    const first: []const analysis.Edit = &.{.{ .span = .{ .start = 14, .end = 28 }, .replacement = "" }};
    const second: []const analysis.Edit = &.{.{ .span = .{ .start = 27, .end = source.len }, .replacement = "" }};
    const merged = try wholeFixes(std.testing.allocator, &.{ first, second });
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    const fixed = try apply(std.testing.allocator, source, merged);
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings("const a = 1;\n\n", fixed);
    // A merged deletion never swallows an edit that writes text.
    const inserts: []const analysis.Edit = &.{
        .{ .span = .{ .start = 5, .end = 5 }, .replacement = "y" },
        .{ .span = .{ .start = 22, .end = 22 }, .replacement = "x" },
    };
    const head: []const analysis.Edit = &.{.{ .span = .{ .start = 14, .end = 20 }, .replacement = "" }};
    const tail: []const analysis.Edit = &.{.{ .span = .{ .start = 19, .end = 30 }, .replacement = "" }};
    const kept = try wholeFixes(std.testing.allocator, &.{ inserts, head, tail });
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqual(@as(usize, 3), kept.len);
    try std.testing.expectEqual(@as(usize, 20), kept[1].span.end);
}

test "fix-all collapses duplicate edits across fixes and drops self-overlapping fixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const edits = try wholeFixes(arena, &.{
        &.{
            .{ .span = .{ .start = 0, .end = 0 }, .replacement = "const std = @import(\"std\");\n" },
            .{ .span = .{ .start = 10, .end = 12 }, .replacement = "a" },
        },
        &.{
            .{ .span = .{ .start = 0, .end = 0 }, .replacement = "const std = @import(\"std\");\n" },
            .{ .span = .{ .start = 20, .end = 22 }, .replacement = "b" },
        },
        &.{
            .{ .span = .{ .start = 40, .end = 44 }, .replacement = "x" },
            .{ .span = .{ .start = 42, .end = 46 }, .replacement = "y" },
        },
    });
    try std.testing.expectEqual(@as(usize, 3), edits.len);
    try std.testing.expectEqual(@as(usize, 0), edits[0].span.start);
    try std.testing.expectEqualStrings("a", edits[1].replacement);
    try std.testing.expectEqualStrings("b", edits[2].replacement);
}

test "fix-all keeps same-position insertions from separate fixes in fix order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const edits = try wholeFixes(arena_state.allocator(), &.{
        &.{.{ .span = .{ .start = 3, .end = 3 }, .replacement = "first" }},
        &.{.{ .span = .{ .start = 3, .end = 5 }, .replacement = "replaced" }},
        &.{.{ .span = .{ .start = 3, .end = 3 }, .replacement = "second" }},
    });
    try std.testing.expectEqual(@as(usize, 3), edits.len);
    try std.testing.expectEqualStrings("first", edits[0].replacement);
    try std.testing.expectEqualStrings("second", edits[1].replacement);
    try std.testing.expectEqualStrings("replaced", edits[2].replacement);
}

test "fix-all passes continue until a fix exposes nothing more" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The migration to `find` and the scalar search rewrite the same call, so
    // one pass can apply only one of them.
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\pub fn open(output: []const u8) usize {
        \\    return std.mem.indexOf(u8, output, "(").?;
        \\}
        \\
    ;
    var configuration = analysis.Configuration.defaults();
    @memset(&configuration.levels, .off);
    configuration.levels[@backingInt(analysis.Rule.modernize_deprecated_stdlib)] = .warning;
    configuration.levels[@backingInt(analysis.Rule.prefer_index_of_scalar)] = .warning;
    const fixed = try fixAll(arena, source, try tokenize(arena, source), configuration);
    try std.testing.expect(std.mem.find(u8, fixed.source, "std.mem.findScalar(u8, output, '(')") != null);
    try std.testing.expectEqual(@as(usize, 0), (try safeFixAll(arena, try analysis.findings(arena, fixed.source, configuration))).len);
}

test "composed passes are edits of the original text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original: [:0]const u8 = "aaaa bbbb cccc dddd eeee";
    const passes = [_][]const analysis.Edit{
        &.{
            .{ .span = .{ .start = 0, .end = 4 }, .replacement = "A" },
            .{ .span = .{ .start = 10, .end = 14 }, .replacement = "CCCCCC" },
            .{ .span = .{ .start = 20, .end = 20 }, .replacement = "<" },
        },
        // "A bbbb CCCCCC dddd <eeee": inside, at the edges of and between
        // the first pass's edits.
        &.{
            .{ .span = .{ .start = 0, .end = 1 }, .replacement = "" },
            .{ .span = .{ .start = 2, .end = 6 }, .replacement = "B" },
            .{ .span = .{ .start = 7, .end = 7 }, .replacement = "[" },
            .{ .span = .{ .start = 9, .end = 11 }, .replacement = "x" },
            .{ .span = .{ .start = 13, .end = 13 }, .replacement = "]" },
            .{ .span = .{ .start = 19, .end = 20 }, .replacement = "" },
        },
        // A pass that undoes part of an earlier one leaves no edit there.
        &.{.{ .span = .{ .start = 1, .end = 2 }, .replacement = "bbbb" }},
    };
    var composition: Composition = .{};
    var current: [:0]const u8 = original;
    for (passes) |pass| {
        try composition.add(arena, pass);
        current = try apply(arena, current, pass);
    }
    try std.testing.expectEqualStrings(" bbbb [CCxCC] dddd eeee", current);
    const composed = try composition.originalEdits(arena, original, current);
    try std.testing.expectEqualStrings(current, try apply(arena, original, composed));
    for (composed[1..], composed[0 .. composed.len - 1]) |edit, previous| try std.testing.expect(previous.span.end < edit.span.start);
    // 'aaaa' deleted and 'cccc' rewritten; 'bbbb' and 'eeee' came back.
    try std.testing.expectEqual(@as(usize, 2), composed.len);
    try std.testing.expectEqualStrings("[CCxCC]", composed[1].replacement);
}

test "converged fix-all edits make the multi-pass result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\pub fn open(output: []const u8) usize {
        \\    return std.mem.indexOf(u8, output, "(").?;
        \\}
        \\
    ;
    var configuration = analysis.Configuration.defaults();
    @memset(&configuration.levels, .off);
    configuration.levels[@backingInt(analysis.Rule.modernize_deprecated_stdlib)] = .warning;
    configuration.levels[@backingInt(analysis.Rule.prefer_index_of_scalar)] = .warning;
    const first_pass = try safeFixAll(arena, try analysis.findings(arena, source, configuration));
    const tokens = try tokenize(arena, source);
    const edits = try convergedFixAll(arena, source, tokens, first_pass, configuration);
    const fixed = try fixAll(arena, source, try tokenize(arena, source), configuration);
    try std.testing.expectEqualStrings(fixed.source, try apply(arena, source, edits));
    try std.testing.expect(std.mem.find(u8, fixed.source, "std.mem.findScalar(u8, output, '(')") != null);
    // One pass that exposes nothing more is returned as it is.
    const call = std.mem.find(u8, source, "std.mem.indexOf").?;
    const one_pass: []const analysis.Edit = &.{.{ .span = .{ .start = call, .end = std.mem.find(u8, source, ";\n}").? }, .replacement = "0" }};
    try std.testing.expectEqual(one_pass.ptr, (try convergedFixAll(arena, source, tokens, one_pass, configuration)).ptr);
}

test "deletions emptying a block widen to its braces unless an edit writes inside" {
    const source = "fn f() void {\n    a();\n    b();\n}\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const a = std.mem.find(u8, source, "    a();").?;
    const b = std.mem.find(u8, source, "    b();").?;
    const deletions = [_]analysis.Edit{
        .{ .span = .{ .start = a, .end = b }, .replacement = "" },
        .{ .span = .{ .start = b, .end = b + "    b();\n".len }, .replacement = "" },
    };
    const collapsed = try collapseEmptiedBlocks(std.testing.allocator, source, tokens, &deletions);
    defer std.testing.allocator.free(collapsed);
    const fixed = try apply(std.testing.allocator, source, collapsed);
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings("fn f() void {}\n", fixed);
    const kept = [_]analysis.Edit{ .{ .span = .{ .start = a, .end = a }, .replacement = "c();" }, deletions[0], deletions[1] };
    try std.testing.expectEqual(@as([*]const analysis.Edit, &kept), (try collapseEmptiedBlocks(std.testing.allocator, source, tokens, &kept)).ptr);
}

test "fix-all writes a block its removals empty together as {}" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each discard is pointless; removing one alone keeps the other's line.
    const source: [:0]const u8 =
        \\pub fn run(a: u8, b: u8, flag: bool) u8 {
        \\    if (flag) {
        \\        _ = a;
        \\        _ = b;
        \\    }
        \\    while (flag) {
        \\        _ = a;
        \\
        \\        _ = b;
        \\    }
        \\    switch (a) {
        \\        0 => {
        \\            _ = a;
        \\            // kept
        \\            _ = b;
        \\        },
        \\        else => {},
        \\    }
        \\    return a + b;
        \\}
        \\
    ;
    var configuration = analysis.Configuration.defaults();
    @memset(&configuration.levels, .off);
    configuration.levels[@backingInt(analysis.Rule.pointless_discard)] = .warning;
    const fixed = try fixAll(arena, source, try tokenize(arena, source), configuration);
    try std.testing.expectEqualStrings(
        \\pub fn run(a: u8, b: u8, flag: bool) u8 {
        \\    if (flag) {}
        \\    while (flag) {}
        \\    switch (a) {
        \\        0 => {
        \\            // kept
        \\        },
        \\        else => {},
        \\    }
        \\    return a + b;
        \\}
        \\
    , fixed.source);
}
