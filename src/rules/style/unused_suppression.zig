//! Suppression directives, and rule names in them, that suppressed nothing.
//! A directive is judged only after every finding it could suppress is
//! known, so the drivers run this after applying the directives rather than
//! through the registry: the file pipeline judges the rules only it reports,
//! and the project engine the rules only it reports. A rule that a later
//! pass also reports, and a directive naming no rule while such a rule is on,
//! are left unjudged.
const std = @import("std");
const configuration = @import("../configuration.zig");
const project = @import("../project.zig");
const project_run = @import("../project/run.zig");
const test_support = @import("../test_support.zig");
const types = @import("../types.zig");
const RuleRun = @import("../context.zig").RuleRun;
const Suppressions = configuration.Suppressions;

pub const rules = [_]types.Rule{.unused_suppression};

/// Rules reported after the file pipeline, or beside it: the project
/// engine's, the file-local rules it refines with cross-file summaries, the
/// imported deprecations and module members of the CLI's cross-file pass,
/// and the file name rule.
const later_rules = project.rules ++ project.refines ++ [_]types.Rule{
    .deprecated_declaration,
    .removed_std_api,
    .unresolved_member,
    .non_idiomatic_file_name,
};

const later = set: {
    @setEvalBranchQuota(10_000);
    var rule_set: std.EnumSet(types.Rule) = .empty;
    for (later_rules) |rule| rule_set.insert(rule);
    break :set rule_set;
};

const project_only = set: {
    @setEvalBranchQuota(10_000);
    var rule_set: std.EnumSet(types.Rule) = .empty;
    for (project.rules) |rule| rule_set.insert(rule);
    break :set rule_set;
};

/// Reports the unused targets of `suppressions` once the file pipeline has
/// filtered its findings through them.
pub fn run(context: RuleRun, suppressions: *const Suppressions) !void {
    // A pass yet to come may still need a directive that names no rule.
    const judge_unnamed = !context.configuration.anyEnabled(&later_rules);
    var targets = suppressions.targets();
    while (targets.next()) |target| {
        if (target.rule) |rule| {
            if (rule == .unused_suppression or later.contains(rule) or context.level(rule) == .off) continue;
        } else if (!judge_unnamed) continue;
        if (suppressions.wasUsed(target.target)) continue;
        if (suppressions.suppressing(.unused_suppression, target.span.start, target.target.directive) != null) continue;
        try context.emit(.{
            .rule = .unused_suppression,
            .level = context.level(.unused_suppression),
            .span = target.span,
            .message = try message(context.allocator, target.rule),
            .fixes = try context.singleFix(.{
                .title = "Remove the unused suppression",
                .span = target.removal,
                .replacement = "",
            }),
        });
    }
}

/// Reports the unused targets that name project-only rules, once the
/// project engine's findings, not yet filtered by any directive, are all in.
pub fn runProject(run_context: project_run.ProjectRun) !void {
    const project_findings = run_context.findings.items.len;
    for (run_context.files, 0..) |file, file_index| {
        if (std.mem.find(u8, file.source, "// zig-analyzer:") == null) continue;
        if (run_context.levelFor(file_index, .unused_suppression) == .off) continue;
        const suppressions = try Suppressions.init(run_context.allocator, file.source);
        // Reported findings grow the list, so it is read afresh per file.
        for (run_context.findings.items[0..project_findings]) |entry| {
            if (entry.file_index == file_index) _ = suppressions.markUsed(entry.finding.rule, entry.finding.span.start);
        }
        var targets = suppressions.targets();
        while (targets.next()) |target| {
            const rule = target.rule orelse continue;
            if (!project_only.contains(rule) or run_context.levelFor(file_index, rule) == .off) continue;
            if (suppressions.wasUsed(target.target)) continue;
            if (suppressions.suppressing(.unused_suppression, target.span.start, target.target.directive) != null) continue;
            const edits = try run_context.allocator.alloc(types.Edit, 1);
            edits[0] = .{ .span = target.removal, .replacement = "" };
            const fixes = try run_context.allocator.alloc(types.Fix, 1);
            fixes[0] = .{ .title = "Remove the unused suppression", .kind = .quickfix, .edits = edits };
            try run_context.report(.{
                .file_index = file_index,
                .rule = .unused_suppression,
                .span = target.span,
                .message = try message(run_context.allocator, rule),
                .fixes = fixes,
            });
        }
    }
}

fn message(allocator: std.mem.Allocator, rule: ?types.Rule) ![]const u8 {
    const named = rule orelse return "suppression directive suppresses no finding";
    return try allocator.print("suppression of '{s}' suppresses no finding", .{named.code()});
}

/// The unused-suppression findings of the file pipeline with only `enabled`
/// and this rule on.
fn findings(allocator: std.mem.Allocator, source: [:0]const u8, enabled: []const types.Rule) ![]const types.Finding {
    var config = types.Configuration.defaults();
    @memset(&config.levels, .off);
    config.levels[@backingInt(types.Rule.unused_suppression)] = .information;
    for (enabled) |rule| config.levels[@backingInt(rule)] = .warning;
    const found = try @import("../pipeline.zig").findings(allocator, source, config);
    var unused: std.ArrayList(types.Finding) = .empty;
    errdefer unused.deinit(allocator);
    for (found) |finding| if (finding.rule == .unused_suppression) try unused.append(allocator, finding);
    return unused.toOwnedSlice(allocator);
}

test "a directive whose named rule reports nothing there is unused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    // zig-analyzer: disable-next-line never-mutated-var\n" ++
        "    const value = 1;\n" ++
        "    _ = value;\n" ++
        "    // zig-analyzer: disable-next-line never-mutated-var\n" ++
        "    var other = 2;\n" ++
        "    _ = other;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, &.{.never_mutated_var});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("never-mutated-var", source[found[0].span.start..found[0].span.end]);
    try std.testing.expect(found[0].span.start < std.mem.find(u8, source, "const value").?);
    try std.testing.expectEqualStrings("suppression of 'never-mutated-var' suppresses no finding", found[0].message);
}

test "only the unused names of a directive are reported, and their fixes keep it valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    // zig-analyzer: disable-next-line redundant-boolean-if, never-mutated-var, needless-defer-block\n" ++
        "    var value = 1;\n" ++
        "    _ = value;\n" ++
        "}\n";
    const found = try findings(allocator, source, &.{ .never_mutated_var, .redundant_boolean_if, .needless_defer_block });
    try std.testing.expectEqual(@as(usize, 2), found.len);
    const expected = [_][]const u8{
        "    // zig-analyzer: disable-next-line never-mutated-var, needless-defer-block\n",
        "    // zig-analyzer: disable-next-line redundant-boolean-if, never-mutated-var\n",
    };
    for (found, expected) |finding, line| {
        const edit = finding.fixes[0].edits[0];
        const fixed = try std.mem.concat(allocator, u8, &.{ source[0..edit.span.start], source[edit.span.end..] });
        try std.testing.expect(std.mem.find(u8, fixed, line) != null);
        try std.testing.expectEqual(@as(?[]const u8, null), try configuration.suppressionWarning(allocator, fixed));
    }
}

test "rules that are off, project rules and later passes are not judged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line never-mutated-var\n" ++
        "const a = 1;\n" ++
        "// zig-analyzer: disable-next-line literal-boolean-argument, missing-errdefer\n" ++
        "const b = 2;\n" ++
        "// zig-analyzer: disable-next-line deprecated-declaration\n" ++
        "const c = 3;\n" ++
        "// zig-analyzer: disable-next-line unused-suppression\n" ++
        "const d = 4;\n";
    try std.testing.expectEqual(@as(usize, 0), (try findings(arena.allocator(), source, &.{ .literal_boolean_argument, .missing_errdefer, .deprecated_declaration })).len);
}

test "a directive naming no rule is judged only when no later pass can use it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    // zig-analyzer: disable-next-line\n" ++
        "    return;\n" ++
        "}\n" ++
        "const value = 1; // zig-analyzer: disable-line all\n";
    const found = try findings(arena.allocator(), source, &.{});
    try std.testing.expectEqual(@as(usize, 2), found.len);
    // Removing a trailing directive keeps the code before it.
    const edit = found[1].fixes[0].edits[0];
    try std.testing.expectEqualStrings(" // zig-analyzer: disable-line all", source[edit.span.start..edit.span.end]);
    try std.testing.expectEqual(@as(usize, 0), (try findings(arena.allocator(), source, &.{.unresolved_member})).len);
}

test "the directives of other files and of the finding itself do not hide it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const suppressed: [:0]const u8 =
        "// zig-analyzer: disable-file unused-suppression\n" ++
        "// zig-analyzer: disable-next-line never-mutated-var\n" ++
        "const a = 1;\n";
    try std.testing.expectEqual(@as(usize, 0), (try findings(arena.allocator(), suppressed, &.{.never_mutated_var})).len);
    const scoped: [:0]const u8 =
        "// zig-analyzer: disable\n" ++
        "const a = 1;\n" ++
        "// zig-analyzer: enable\n";
    try std.testing.expectEqual(@as(usize, 1), (try findings(arena.allocator(), scoped, &.{})).len);
}

test "the project engine judges directives naming its own rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration_value = test_support.only(&.{ .literal_boolean_argument, .unused_suppression }, .information);
    const files = [_]project.SourceFile{.{
        .path = "src/walk.zig",
        .source = "fn walk(a: u8, flag: bool) void { _ = a; _ = flag; }\n" ++
            "fn run() void {\n" ++
            "    // zig-analyzer: disable-next-line literal-boolean-argument\n" ++
            "    walk(1, true);\n" ++
            "    // zig-analyzer: disable-next-line literal-boolean-argument\n" ++
            "    walk(2, @as(bool, undefined));\n" ++
            "}\n",
    }};
    const found = try project.findings(arena.allocator(), &files, configuration_value);
    var unused: usize = 0;
    for (found) |entry| {
        if (entry.finding.rule != .unused_suppression) continue;
        unused += 1;
        try std.testing.expect(entry.finding.span.start > std.mem.find(u8, files[0].source, "walk(1").?);
    }
    try std.testing.expectEqual(@as(usize, 1), unused);
}
