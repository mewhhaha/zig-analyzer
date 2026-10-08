//! Runs every catalog example through the analysis pipeline: the rule fires
//! when only it is enabled, offers the fixes the catalog promises, and obeys
//! both suppression directive forms.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

const analysis = zig_analyzer.analysis;
const catalog = zig_analyzer.rule_catalog;

/// Findings from the file pipeline and the project engine over one file.
fn examineFile(allocator: std.mem.Allocator, source: [:0]const u8, rule: analysis.Rule) ![]const analysis.Finding {
    var configuration = analysis.Configuration.defaults();
    @memset(&configuration.levels, .off);
    configuration.levels[@backingInt(rule)] = .warning;

    var found: std.ArrayList(analysis.Finding) = .empty;
    try found.appendSlice(allocator, try analysis.findings(allocator, source, configuration));
    const files = [_]zig_analyzer.project_rules.SourceFile{.{ .path = "example.zig", .source = source }};
    for (try zig_analyzer.project_rules.findings(allocator, &files, configuration)) |entry| {
        try found.append(allocator, entry.finding);
    }
    const suppressions = try analysis.Suppressions.init(allocator, source);
    suppressions.filter(&found);
    return found.toOwnedSlice(allocator);
}

fn countRule(found: []const analysis.Finding, rule: analysis.Rule) usize {
    var count: usize = 0;
    for (found) |finding| {
        if (finding.rule == rule) count += 1;
    }
    return count;
}

fn offeredFixes(found: []const analysis.Finding, rule: analysis.Rule) catalog.Fixes {
    var offered: catalog.Fixes = .none;
    for (found) |finding| {
        if (finding.rule != rule) continue;
        for (finding.fixes) |fix| {
            if (fix.fix_all) return .fix_all;
            offered = .quick_fix;
        }
    }
    return offered;
}

test "catalog examples fire, offer the cataloged fixes, and can be suppressed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var checked: usize = 0;
    for (std.enums.values(analysis.Rule)) |rule| {
        const row = catalog.entry(rule);
        const source = switch (row.example) {
            .source => |source| source,
            .none => continue,
        };
        errdefer std.debug.print("catalog example failed for {s}\n", .{rule.code()});
        const allocator = arena_state.allocator();

        const found = try examineFile(allocator, source, rule);
        const fired = countRule(found, rule);
        try std.testing.expect(fired != 0);
        try std.testing.expectEqual(row.fixes, offeredFixes(found, rule));

        const file_directive = try allocator.printSentinel(
            "// zig-analyzer: disable-file {s}\n{s}",
            .{ rule.code(), source },
            0,
        );
        try std.testing.expectEqual(@as(usize, 0), countRule(try examineFile(allocator, file_directive, rule), rule));

        var first_start: usize = std.math.maxInt(usize);
        for (found) |finding| {
            if (finding.rule == rule) first_start = @min(first_start, finding.span.start);
        }
        // A finding anchored at the very start of the file has no line above it
        // for a next-line directive; file-level directives cover that case.
        if (first_start == 0) {
            checked += 1;
            continue;
        }
        const line_start = if (std.mem.findScalarLast(u8, source[0..first_start], '\n')) |newline| newline + 1 else 0;
        const line_directive = try allocator.printSentinel(
            "{s}// zig-analyzer: disable-next-line {s}\n{s}",
            .{ source[0..line_start], rule.code(), source[line_start..] },
            0,
        );
        const remaining = countRule(try examineFile(allocator, line_directive, rule), rule);
        try std.testing.expect(remaining < fired);
        checked += 1;
    }
    try std.testing.expect(checked > 150);
}
