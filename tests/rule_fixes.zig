//! The fix round-trip property over every catalog example, then one
//! compilation of all examples and their fix results (`zig build fix-check`).

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");
const compile_batch = @import("fuzz/compile_batch.zig");
const round_trip = @import("fuzz/round_trip.zig");

const analysis = zig_analyzer.analysis;
const catalog = zig_analyzer.rule_catalog;

test "catalog example fixes preserve syntax, lowering and formatting and are idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var corpus: compile_batch.Corpus = .init(std.testing.allocator);
    defer corpus.deinit();
    var verdict: round_trip.Verdict = .{ .corpus = &corpus };
    var everything = analysis.Configuration.defaults();
    @memset(&everything.levels, .warning);
    for (std.enums.values(analysis.Rule)) |rule| {
        defer _ = arena_state.reset(.retain_capacity);
        const source = switch (catalog.entry(rule).example) {
            .source => |source| source,
            .none => continue,
        };
        var only = analysis.Configuration.defaults();
        @memset(&only.levels, .off);
        only.levels[@backingInt(rule)] = .warning;
        try round_trip.checkRule(arena, &verdict, rule.code(), source, rule, only);
        try round_trip.checkCombined(arena, &verdict, rule.code(), source, everything);
    }
    try std.testing.expectEqual(@as(usize, 0), verdict.failures);
    try std.testing.expectEqual(@as(usize, 0), verdict.unformatted);
    try std.testing.expect(verdict.fix_all_applied > 0);
    try std.testing.expect(verdict.fixes_applied > 0);
    try std.testing.expect(verdict.formatted_inputs > 0);

    const outcome = try compile_batch.check(std.testing.allocator, std.testing.io, &corpus);
    std.debug.print("fix-check: {d} examples ({d} already erroneous, {d} skipped) and {d} fix results compiled\n", .{
        outcome.programs, outcome.erroneous, outcome.skipped, outcome.variants,
    });
    try std.testing.expectEqual(@as(usize, 0), outcome.failures);
    try std.testing.expect(outcome.variants > 0);
}
