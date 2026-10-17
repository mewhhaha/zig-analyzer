//! Combining and applying byte-span edits, shared by the CLI's `--fix` and the
//! language server's fix-all so both accept exactly the same edit sets.
const std = @import("std");
const analysis = @import("../analysis.zig");

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
/// edit, and identical duplicate edits collapse to one. The caller owns the
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
