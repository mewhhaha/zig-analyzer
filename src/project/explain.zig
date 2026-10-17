//! `zig-analyzer explain`: a rule's documentation page, rendered as
//! `zig build rule-docs` renders it, from the rule catalog and the page's
//! hand-written body, which the build embeds from `docs/rules`; without a
//! rule, the rule codes grouped by tier.

const std = @import("std");
const rule_pages = @import("rule_pages");
const analysis = @import("../analysis.zig");
const catalog = @import("../rules/catalog.zig");
const rule_docs = @import("../rules/rule_docs.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, code: ?[]const u8) !u8 {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    var error_buffer: [256]u8 = undefined;
    var error_writer = std.Io.File.stderr().writer(io, &error_buffer);
    const exit_code = try explain(allocator, code, &file_writer.interface, &error_writer.interface);
    try file_writer.interface.flush();
    try error_writer.interface.flush();
    return exit_code;
}

fn explain(allocator: std.mem.Allocator, code: ?[]const u8, writer: *std.Io.Writer, errors: *std.Io.Writer) !u8 {
    const name = code orelse {
        try writeRuleCodes(allocator, writer);
        return 0;
    };
    const rule = analysis.ruleNamed(name) orelse {
        try errors.print("zig-analyzer explain: unknown rule '{s}'{f}\n", .{ name, analysis.DidYouMean{ .name = analysis.nearestRuleCode(name) } });
        return 2;
    };
    try writeRule(allocator, rule, writer);
    return 0;
}

/// The committed page of `rule` in `docs/rules`.
fn page(rule: analysis.Rule) []const u8 {
    @setEvalBranchQuota(100_000);
    return switch (rule) {
        inline else => |known| rule_pages.page(comptime known.code()),
    };
}

/// The rule's page without the generator's markers and with its link to the
/// rule index replaced by the page's address.
fn writeRule(allocator: std.mem.Allocator, rule: analysis.Rule, writer: *std.Io.Writer) !void {
    const document = try rule_docs.renderDocument(allocator, catalog.entry(rule), rule_docs.bodyOf(page(rule)) orelse "");
    defer allocator.free(document);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, document, "\n"), '\n');
    while (lines.next()) |line| {
        const generated = for ([_][]const u8{
            rule_docs.header_begin,
            rule_docs.header_end,
            rule_docs.footer_begin,
            rule_docs.footer_end,
            rule_docs.index_link,
        }) |marker| {
            if (std.mem.eql(u8, line, marker)) break true;
        } else false;
        if (generated) continue;
        try writer.print("{s}\n", .{line});
    }
    try writer.print("Documentation: {s}\n", .{catalog.documentationUrl(rule)});
}

fn writeRuleCodes(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const rules = try allocator.dupe(analysis.Rule, std.enums.values(analysis.Rule));
    defer allocator.free(rules);
    std.mem.sort(analysis.Rule, rules, {}, struct {
        fn lessThan(_: void, left: analysis.Rule, right: analysis.Rule) bool {
            return std.mem.lessThan(u8, left.code(), right.code());
        }
    }.lessThan);
    for (rule_docs.tier_titles, 0..) |tier_title, position| {
        var tier_count: usize = 0;
        for (rules) |rule| {
            if (rule.tier() == tier_title.tier) tier_count += 1;
        }
        if (position != 0) try writer.writeByte('\n');
        try writer.print("{s} ({d})\n", .{ tier_title.title, tier_count });
        for (rules) |rule| {
            if (rule.tier() == tier_title.tier) try writer.print("  {s}\n", .{rule.code()});
        }
    }
    try writer.writeAll("\nRun 'zig-analyzer explain <rule>' for a rule's documentation.\n");
}

test "explain prints a rule's facts and its page without the generator's markers" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try std.testing.expectEqual(@as(u8, 0), try explain(std.testing.allocator, "self-assignment", &output.writer, &errors.writer));
    const written = output.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "# `self-assignment`\n\nTier: correctness · Profile: none · Default: warning · Fixes: quick fix · Options: none\n\nReports an assignment where"));
    try std.testing.expect(std.mem.find(u8, written, "## Why it matters\n") != null);
    try std.testing.expect(std.mem.find(u8, written, "## Example\n\n```zig\n") != null);
    try std.testing.expect(std.mem.find(u8, written, "<!--") == null);
    try std.testing.expect(std.mem.find(u8, written, "[Rule index]") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "```\n\nDocumentation: https://github.com/mewhhaha/zig-analyzer/blob/main/docs/rules/self-assignment.md\n"));
    try std.testing.expectEqual(@as(usize, 0), errors.written().len);
}

test "explain suggests the nearest rule for an unknown code" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try std.testing.expectEqual(@as(u8, 2), try explain(std.testing.allocator, "self-asignment", &output.writer, &errors.writer));
    try std.testing.expectEqualStrings("zig-analyzer explain: unknown rule 'self-asignment'; did you mean 'self-assignment'?\n", errors.written());
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "explain without a rule lists every rule code under its tier" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try std.testing.expectEqual(@as(u8, 0), try explain(std.testing.allocator, null, &output.writer, &errors.writer));
    const written = output.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "Semantic diagnostics ("));
    const correctness = std.mem.find(u8, written, "\nCorrectness rules (").?;
    const style = std.mem.find(u8, written, "\nStyle rules (").?;
    for (std.enums.values(analysis.Rule)) |rule| {
        var line_buffer: [128]u8 = undefined;
        const line = try std.mem.print(&line_buffer, "\n  {s}\n", .{rule.code()});
        const position = std.mem.find(u8, written, line) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(rule.tier() == .semantic, position < correctness);
        try std.testing.expectEqual(rule.tier() == .style, position > style);
    }
}

test "every embedded page is the one the catalog renders" {
    for (std.enums.values(analysis.Rule)) |rule| {
        errdefer std.debug.print("stale embedded page for {s}\n", .{rule.code()});
        const body = rule_docs.bodyOf(page(rule)) orelse return error.TestUnexpectedResult;
        const document = try rule_docs.renderDocument(std.testing.allocator, catalog.entry(rule), body);
        defer std.testing.allocator.free(document);
        try std.testing.expectEqualStrings(document, page(rule));
    }
}
