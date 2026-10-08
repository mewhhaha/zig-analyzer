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

/// The edits of every fix-all fix in `findings` that can be applied together.
pub fn safeFixAll(allocator: std.mem.Allocator, findings: []const analysis.Finding) ![]const analysis.Edit {
    var candidates: std.ArrayList(analysis.Edit) = .empty;
    defer candidates.deinit(allocator);
    for (findings) |finding| {
        for (finding.fixes) |fix| {
            if (fix.fix_all) try candidates.appendSlice(allocator, fix.edits);
        }
    }
    return nonOverlapping(allocator, candidates.items);
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
