//! Shared harness for rule unit tests. It builds the inputs the pipeline driver
//! hands every rule (tokens ending in `.eof`, syntax tree, scope index), runs a
//! rule, and applies the suppression directives of the source the way the
//! driver does, so each rule module's tests only state sources and expectations.
const std = @import("std");
const tokenize = @import("../syntax/tokens.zig").tokenize;
const configuration = @import("configuration.zig");
const context_module = @import("context.zig");
const RuleRun = context_module.RuleRun;
const Syntax = context_module.Syntax;
const types = @import("types.zig");

/// Default configuration with each of `rules` set to `level`.
pub fn only(rules: []const types.Rule, level: types.Level) types.Configuration {
    return with(types.Configuration.defaults(), rules, level);
}

/// `base` with each of `rules` set to `level`.
pub fn with(base: types.Configuration, rules: []const types.Rule, level: types.Level) types.Configuration {
    var result = base;
    for (rules) |rule| result.levels[@backingInt(rule)] = level;
    return result;
}

/// Runs `rule_run` over `source` and returns its findings minus those a
/// suppression directive covers. Everything allocated stays with `allocator`,
/// which tests make an arena.
pub fn findings(
    allocator: std.mem.Allocator,
    comptime rule_run: anytype,
    source: [:0]const u8,
    config: types.Configuration,
) ![]const types.Finding {
    const Plain = struct {
        fn run(_: @This(), context: RuleRun) !void {
            try rule_run(context);
        }
    };
    return execute(allocator, Plain{}, source, config);
}

/// `findings` for a rule that reads the compiler-resolved type shapes.
pub fn findingsShaped(
    allocator: std.mem.Allocator,
    comptime rule_run: anytype,
    shapes: []const types.ResolvedShape,
    source: [:0]const u8,
    config: types.Configuration,
) ![]const types.Finding {
    const Shaped = struct {
        shapes: []const types.ResolvedShape,
        fn run(shaped: @This(), context: RuleRun) !void {
            var shaped_context = context;
            shaped_context.resolved_shapes = shaped.shapes;
            try rule_run(shaped_context);
        }
    };
    return execute(allocator, Shaped{ .shapes = shapes }, source, config);
}

/// `findings` for rule entry points that take one extra argument after the run
/// context, such as a summary index.
pub fn findingsWith(
    allocator: std.mem.Allocator,
    comptime rule_run: anytype,
    extra: anytype,
    source: [:0]const u8,
    config: types.Configuration,
) ![]const types.Finding {
    const Bound = struct {
        extra: @TypeOf(extra),
        fn run(bound: @This(), context: RuleRun) !void {
            try rule_run(context, bound.extra);
        }
    };
    return execute(allocator, Bound{ .extra = extra }, source, config);
}

fn execute(allocator: std.mem.Allocator, runner: anytype, source: [:0]const u8, config: types.Configuration) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var syntax = try Syntax.init(allocator, source, tokens);
    defer syntax.deinit(allocator);
    var found: std.ArrayList(types.Finding) = .empty;
    try runner.run(syntax.ruleRun(allocator, config, &found));
    const suppressions = try configuration.Suppressions.init(allocator, source);
    defer suppressions.deinit(allocator);
    suppressions.filter(&found);
    return try found.toOwnedSlice(allocator);
}

/// Asserts the findings are exactly `expected`, in order.
pub fn expectRules(found: []const types.Finding, expected: []const types.Rule) !void {
    try std.testing.expectEqual(expected.len, found.len);
    for (expected, found) |rule, finding| try std.testing.expectEqual(rule, finding.rule);
}

/// Asserts the findings' spans cover exactly the `expected` texts of `source`, in order.
pub fn expectSpans(source: []const u8, found: []const types.Finding, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, found.len);
    for (expected, found) |text, finding| {
        try std.testing.expectEqualStrings(text, source[finding.span.start..finding.span.end]);
    }
}

const sample = "const a = 1;\n// zig-analyzer: disable-next-line never-mutated-var\nvar b = 2;\nvar c = 3;";

fn flagEveryVar(context: RuleRun) !void {
    for (context.tokens) |token| {
        if (token.tag != .keyword_var) continue;
        try context.emit(.{ .rule = .never_mutated_var, .level = context.level(.never_mutated_var), .span = token.loc, .message = "var" });
    }
}

test "findings hands rules the shared syntax and applies suppressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findings(arena.allocator(), flagEveryVar, sample, only(&.{.never_mutated_var}, .warning));
    try expectRules(found, &.{.never_mutated_var});
    try expectSpans(sample, found, &.{"var"});
    try std.testing.expectEqual(std.mem.findLast(u8, sample, "var").?, found[0].span.start);
}

test "rules whose level is off report nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findings(arena.allocator(), flagEveryVar, sample, only(&.{.never_mutated_var}, .off));
    try expectRules(found, &.{});
}
