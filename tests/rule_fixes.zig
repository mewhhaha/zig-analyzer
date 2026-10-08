//! The fix round-trip property over every catalog example.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");
const round_trip = @import("fuzz/round_trip.zig");

const analysis = zig_analyzer.analysis;
const catalog = zig_analyzer.rule_catalog;

test "catalog example fixes preserve syntax and formatting and are idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var verdict: round_trip.Verdict = .{};
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
}
