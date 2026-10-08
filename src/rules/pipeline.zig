//! The file-local analysis driver: builds the syntax tree, tokens and scope
//! index once, runs every enabled rule module over them, applies suppression
//! directives once and returns the findings in source order.
const std = @import("std");

const syntax_scope = @import("../syntax/scope.zig");
const tokenize = @import("../syntax/tokens.zig").tokenize;
const configuration_parser = @import("configuration.zig");
const generated_source_detection = @import("generated_source.zig");
const containers = @import("semantic/containers.zig");
const Syntax = @import("context.zig").Syntax;
const registry = @import("registry.zig");
const types = @import("types.zig");
const support = @import("test_support.zig");

const Configuration = types.Configuration;
const Finding = types.Finding;
const Rule = types.Rule;
const Level = types.Level;
const LintProfile = types.LintProfile;
const parseConfiguration = configuration_parser.parse;
const Suppressions = configuration_parser.Suppressions;

pub const Options = struct {
    /// Tokens of `source` when the caller already has them; null tokenizes here.
    tokens: ?[]const std.zig.Token = null,
    /// Syntax tree of `source` when the caller already has it; null parses here.
    tree: ?*const std.zig.Ast = null,
    /// Scope index of `source` and `tokens` when the caller already has it.
    scopes: ?*const syntax_scope.Index = null,
    resolved_shapes: []const types.ResolvedShape = &.{},
    module_members: []const types.ModuleMembers = &.{},
};

pub fn findings(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    configuration: Configuration,
) ![]Finding {
    return try findingsWith(allocator, source, configuration, .{});
}

pub fn findingsWith(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    configuration: Configuration,
    options: Options,
) ![]Finding {
    if (generated_source_detection.isTranslateCOutput(source)) return &.{};
    var owned_tree: ?std.zig.Ast = null;
    defer if (owned_tree) |*owned| owned.deinit(allocator);
    const tree: *const std.zig.Ast = options.tree orelse tree: {
        owned_tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
        break :tree &owned_tree.?;
    };
    if (options.tokens) |tokens| return try findingsFromSyntax(allocator, source, tree, tokens, configuration, options);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    return try findingsFromSyntax(allocator, source, tree, tokens, configuration, options);
}

/// Only the `unresolved_member` findings that follow from `modules`, the
/// members the caller resolved for the file's imports. `findingsWith` reports
/// the same findings when given the same `module_members`; this entry point
/// serves callers that resolve imports in a separate pass (the project check).
pub fn moduleMemberFindings(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    modules: []const types.ModuleMembers,
) ![]Finding {
    if (modules.len == 0 or configuration.level(.unresolved_member) == .off) return &.{};
    var syntax = try Syntax.init(allocator, source, tokens);
    defer syntax.deinit(allocator);
    var found: std.ArrayList(Finding) = .empty;
    var run = syntax.ruleRun(allocator, configuration, &found);
    run.module_members = modules;
    try containers.findUnresolvedModuleMembers(run);
    const suppressions = try Suppressions.init(allocator, source);
    defer suppressions.deinit(allocator);
    suppressions.filter(&found);
    return try found.toOwnedSlice(allocator);
}

fn findingsFromSyntax(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    options: Options,
) ![]Finding {
    var owned_scopes: ?syntax_scope.Index = null;
    defer if (owned_scopes) |*owned| owned.deinit();
    const scope_index: *const syntax_scope.Index = options.scopes orelse scopes: {
        owned_scopes = try syntax_scope.Index.init(allocator, source, tokens);
        break :scopes &owned_scopes.?;
    };
    var found: std.ArrayList(Finding) = .empty;
    const suppressions = try Suppressions.init(allocator, source);
    defer suppressions.deinit(allocator);

    try registry.run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &found,
        .tree = tree,
        .scopes = scope_index,
        .resolved_shapes = options.resolved_shapes,
        .module_members = options.module_members,
    });
    suppressions.filter(&found);

    std.mem.sort(Finding, found.items, {}, struct {
        fn lessThan(_: void, left: Finding, right: Finding) bool {
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return @backingInt(left.rule) < @backingInt(right.rule);
        }
    }.lessThan);
    return try found.toOwnedSlice(allocator);
}

test {
    _ = registry;
}

test "findings include switch struct and var fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Options = struct { count: u32, enabled: bool = true };\n" ++
        "fn run(mode: Mode) void {\n" ++
        "    var count = 1;\n" ++
        "    _ = count;\n" ++
        "    _ = Options{};\n" ++
        "    switch (mode) { .fast => {} }\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var saw_switch = false;
    var saw_struct = false;
    var saw_var = false;
    for (found) |finding| {
        if (finding.rule == .missing_switch_prong or finding.rule == .missing_struct_field) {
            if (finding.rule == .missing_switch_prong) saw_switch = true else saw_struct = true;
            const text_edits = @import("../syntax/text_edits.zig");
            const edits = try text_edits.nonOverlapping(arena.allocator(), finding.fixes[0].edits);
            const fixed = try text_edits.apply(arena.allocator(), source, edits);
            var tree = try std.zig.Ast.parse(arena.allocator(), fixed, .{ .mode = .zig });
            defer tree.deinit(arena.allocator());
            try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
            for (try findings(arena.allocator(), fixed, Configuration.defaults())) |remaining| {
                try std.testing.expect(remaining.rule != finding.rule);
            }
        }
        if (finding.rule == .never_mutated_var) saw_var = true;
    }
    try std.testing.expect(saw_switch);
    try std.testing.expect(saw_struct);
    try std.testing.expect(saw_var);
}

test "suppression comments disable only named findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    // zig-analyzer: disable-next-line never-mutated-var\n" ++
        "    var value = 1;\n" ++
        "    _ = value;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
}

test "style findings require proven operands and expose safe fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "fn Bad_Function(mode: Mode, enabled: bool, value: u32, unknown: anytype) u32 {\n" ++
        "    _ = @as(u32, value);\n" ++
        "    _ = @as(u32, @as(u32, value));\n" ++
        "    _ = failing() catch {};\n" ++
        "    _ = unknown == true;\n" ++
        "    _ = switch (mode) { .fast => 1, else => 2 };\n" ++
        "    if (enabled == true) { return value; } else { return 0; }\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    for (std.enums.values(Rule)) |rule| if (rule.tier() == .style) {
        configuration.levels[@backingInt(rule)] = .warning;
    };
    const found = try findings(arena.allocator(), source, configuration);
    var saw_discarded_error = false;
    var saw_boolean = false;
    var saw_non_exhaustive = false;
    var saw_name = false;
    var cast_count: usize = 0;
    var saw_needless_else = false;
    for (found) |finding| switch (finding.rule) {
        .discarded_error => saw_discarded_error = true,
        .redundant_bool_comparison => {
            saw_boolean = true;
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        },
        .non_exhaustive_switch_else => saw_non_exhaustive = true,
        .non_idiomatic_name => saw_name = true,
        .needless_cast => cast_count += 1,
        .needless_else_after_terminator => saw_needless_else = true,
        else => {},
    };
    try std.testing.expect(saw_discarded_error);
    try std.testing.expect(saw_boolean);
    try std.testing.expect(saw_non_exhaustive);
    try std.testing.expect(saw_name);
    try std.testing.expect(cast_count >= 2);
    try std.testing.expect(saw_needless_else);
}

test "error comparisons and mixed operators report precise findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn classify(err: error{Missing}, value: u8) bool {\n" ++
        "    _ = 1 + value << 3;\n" ++
        "    return err == error.Other;\n" ++
        "}\n";
    const configuration = support.only(&.{.mixed_bitwise_arithmetic}, .warning);
    const found = try findings(arena.allocator(), source, configuration);
    var saw_error_comparison = false;
    var saw_mixed_operators = false;
    for (found) |finding| switch (finding.rule) {
        .error_value_comparison => saw_error_comparison = true,
        .mixed_bitwise_arithmetic => {
            saw_mixed_operators = true;
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            const replacement = finding.fixes[0].edits[0].replacement;
            try std.testing.expect(replacement.len > 0 and replacement[0] == '(');
        },
        else => {},
    };
    try std.testing.expect(saw_error_comparison);
    try std.testing.expect(saw_mixed_operators);
}

test "unused module aliases belong to unused import analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const module = @import(\"module.zig\");\n" ++
        "const Parser = @import(\"module.zig\").ParserType;\n";
    const configuration = support.only(&.{ .unused_private_declaration, .unused_import }, .warning);
    const found = try findings(arena.allocator(), source, configuration);
    var unused_imports: usize = 0;
    var unused_private_declarations: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .unused_import => unused_imports += 1,
        .unused_private_declaration => unused_private_declarations += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), unused_imports);
    try std.testing.expectEqual(@as(usize, 1), unused_private_declarations);
}

test "semantic findings understand captures mutations and shadowed switch operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const ExePathFormat = enum { elf, pe, macho, detect };\n" ++
        "const Flags = struct { enabled: bool };\n" ++
        "const Context = struct { value: u8 };\n" ++
        "const Result = union(enum) { done: u8, pending };\n" ++
        "fn run(callback: ?*const fn () void, exe_path_format: enum { detect, native }) void {\n" ++
        "    if (callback) |hook| hook();\n" ++
        "    var checksum: u64 = 0;\n" ++
        "    checksum +%= 1;\n" ++
        "    var flags: Flags = .{ .enabled = false };\n" ++
        "    @field(flags, \"enabled\") = true;\n" ++
        "    var result: Result = .{ .done = 1 };\n" ++
        "    _ = switch (result) { .done => |*value| value.*, .pending => 0 };\n" ++
        "    var storage = Context{ .value = 0 };\n" ++
        "    var context: *Context = context: { const context = &storage; break :context context; };\n" ++
        "    context.value = 1;\n" ++
        "    _ = switch (exe_path_format) { .detect => 1, .native => 2 };\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| switch (finding.rule) {
        .unresolved_call, .never_mutated_var, .missing_switch_prong => return error.TestUnexpectedResult,
        else => {},
    };
}

test "line and scoped suppressions apply to semantic and modular rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(ready: bool) void {\n" ++
        "    var value = if (ready) true else false; // zig-analyzer: disable-line never-mutated-var, redundant-boolean-if\n" ++
        "    _ = value;\n" ++
        "    defer { _ = ready; } // zig-analyzer: disable-line needless-defer-block\n" ++
        "}";
    const configuration = support.only(&.{ .redundant_boolean_if, .needless_defer_block }, .information);
    const found = try findings(arena.allocator(), source, configuration);

    for (found) |finding| switch (finding.rule) {
        .never_mutated_var, .redundant_boolean_if, .needless_defer_block => return error.TestUnexpectedResult,
        else => {},
    };
}

test "suppression directives filter findings of tree-sharing rules once in the driver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const unsuppressed: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "fn run(mode: Mode, n: u32) void {\n" ++
        "    if (mode == .fast) {} else if (mode == .safe) {}\n" ++
        "    _ = (n + 8 - 1) / 8;\n" ++
        "}";
    const suppressed: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "fn run(mode: Mode, n: u32) void {\n" ++
        "    // zig-analyzer: disable-next-line prefer-switch\n" ++
        "    if (mode == .fast) {} else if (mode == .safe) {}\n" ++
        "    // zig-analyzer: disable-next-line prefer-div-ceil\n" ++
        "    _ = (n + 8 - 1) / 8;\n" ++
        "}";
    const configuration = support.only(&.{ .prefer_switch, .prefer_div_ceil }, .information);
    var rules_found: usize = 0;
    for (try findings(arena.allocator(), unsuppressed, configuration)) |finding| switch (finding.rule) {
        .prefer_switch, .prefer_div_ceil => rules_found += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), rules_found);
    for (try findings(arena.allocator(), suppressed, configuration)) |finding| switch (finding.rule) {
        .prefer_switch, .prefer_div_ceil => return error.TestUnexpectedResult,
        else => {},
    };
}

test "a caller-provided tree gives the same findings as parsing in the driver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run() void { var value = 1; _ = value; }\nfn broken( {";
    var tree = try std.zig.Ast.parse(arena.allocator(), source, .{ .mode = .zig });
    const parsed = try findings(arena.allocator(), source, Configuration.defaults());
    const shared = try findingsWith(arena.allocator(), source, Configuration.defaults(), .{ .tree = &tree });
    try std.testing.expect(tree.errors.len != 0);
    try std.testing.expectEqual(parsed.len, shared.len);
    for (parsed, shared) |left, right| {
        try std.testing.expectEqual(left.rule, right.rule);
        try std.testing.expectEqual(left.span.start, right.span.start);
    }
}

test "scope-sensitive quick fixes are excluded from fix all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(enabled: bool) void {\n" ++
        "    var value = enabled;\n" ++
        "    _ = value;\n" ++
        "    if (enabled) { return; } else { consume(); }\n" ++
        "}\n";
    const configuration = try parseConfiguration(arena.allocator(),
        \\{"lints":{"rules":{"needless-else-after-terminator":"information"}}}
    );
    const found = try findings(arena.allocator(), source, configuration);
    var checked: usize = 0;
    for (found) |finding| {
        if (finding.rule != .never_mutated_var and finding.rule != .needless_else_after_terminator) continue;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expect(!finding.fixes[0].fix_all);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
}

test "lint profiles enable official idiomatic and strict rules incrementally" {
    const official = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"profile":"official"}}
    );
    try std.testing.expectEqual(LintProfile.official, official.lint_profile);
    try std.testing.expectEqual(Level.information, official.level(.redundant_qualified_name));
    try std.testing.expectEqual(Level.off, official.level(.prefer_optional_capture));

    const idiomatic = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"profile":"idiomatic","rules":{"prefer-try":"warning"}}}
    );
    try std.testing.expectEqual(Level.information, idiomatic.level(.underscore_private_name));
    try std.testing.expectEqual(Level.warning, idiomatic.level(.prefer_try));
    try std.testing.expectEqual(Level.information, idiomatic.level(.redundant_boolean_if));
    try std.testing.expectEqual(Level.information, idiomatic.level(.needless_defer_block));
    try std.testing.expectEqual(Level.information, idiomatic.level(.needless_empty_else));
    try std.testing.expectEqual(Level.off, idiomatic.level(.unsafe_orelse_unreachable));
    try std.testing.expectEqual(Level.information, idiomatic.level(.redundant_optional_unwrap));
    try std.testing.expectEqual(Level.off, idiomatic.level(.public_declaration_docs));

    const strict = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"profile":"strict"}}
    );
    try std.testing.expectEqual(Level.information, strict.level(.unsafe_orelse_unreachable));
    try std.testing.expectEqual(Level.information, strict.level(.lost_error_context));
    try std.testing.expectEqual(Level.information, strict.level(.error_collapsed_to_absence));
    try std.testing.expectEqual(Level.information, strict.level(.public_declaration_docs));
}

test "idiomatic rewrites are offered only for mechanically bounded forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Options = struct { count: u32 };\n" ++
        "fn load() !u32 { return 1; }\n" ++
        "fn inspect(optional: ?u32, actual: u32, pointer: *u32) !void {\n" ++
        "    if (optional != null) { _ = optional.?; }\n" ++
        "    const loaded = load() catch |err| return err;\n" ++
        "    try std.testing.expect(actual == 42);\n" ++
        "    const mode: Mode = Mode.fast;\n" ++
        "    const options: Options = Options{ .count = pointer.* };\n" ++
        "    _ = loaded; _ = mode; _ = options;\n" ++
        "}\n";
    const configuration = try parseConfiguration(arena.allocator(),
        \\{"lints":{"profile":"idiomatic"}}
    );
    const found = try findings(arena.allocator(), source, configuration);
    var optional_capture = false;
    var prefer_try = false;
    var testing = false;
    var pointer_const = false;
    var qualification = false;
    var initializer = false;
    for (found) |finding| switch (finding.rule) {
        .prefer_optional_capture => {
            optional_capture = true;
            try std.testing.expectEqualStrings("optional) |value|", finding.fixes[0].edits[0].replacement);
        },
        .prefer_try => prefer_try = true,
        .prefer_testing_expect_equal => testing = true,
        .mutable_pointer_parameter => pointer_const = true,
        .redundant_type_qualification => qualification = true,
        .prefer_anonymous_initializer => initializer = true,
        else => {},
    };
    try std.testing.expect(optional_capture);
    try std.testing.expect(prefer_try);
    try std.testing.expect(testing);
    try std.testing.expect(pointer_const);
    try std.testing.expect(qualification);
    try std.testing.expect(initializer);
}

test "error switches and import rules provide conservative actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const first = @import(\"./module.zig\");\n" ++
        "const second = @import(\"./module.zig\");\n" ++
        "const Failure = error{ Missing, Denied };\n" ++
        "fn classify(err: Failure) void { _ = switch (err) { error.Missing => {} }; }\n";
    const configuration = try parseConfiguration(arena.allocator(),
        \\{"lints":{"profile":"idiomatic"}}
    );
    const found = try findings(arena.allocator(), source, configuration);
    var error_switch = false;
    var duplicate = false;
    var unused_count: usize = 0;
    var normalized_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .non_exhaustive_error_switch => {
            error_switch = true;
            try std.testing.expect(std.mem.find(u8, finding.fixes[0].edits[0].replacement, "error.Denied") != null);
        },
        .duplicate_import => duplicate = true,
        .unused_import => unused_count += 1,
        .redundant_import_path => normalized_count += 1,
        else => {},
    };
    try std.testing.expect(error_switch);
    try std.testing.expect(duplicate);
    try std.testing.expectEqual(@as(usize, 2), unused_count);
    try std.testing.expectEqual(@as(usize, 2), normalized_count);
}

test "comptime hints use proven container members and explicit constant conditions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { value: u32, pub const enabled = true; };\n" ++
        "fn run() void {\n" ++
        "    _ = @hasField(State, \"value\");\n" ++
        "    _ = @hasField(State, \"missing\");\n" ++
        "    _ = @hasDecl(State, \"enabled\");\n" ++
        "    if (comptime true) {}\n" ++
        "}\n";
    const configuration = support.only(&.{ .unknown_comptime_member, .constant_comptime_condition }, .hint);
    const found = try findings(arena.allocator(), source, configuration);
    var member_count: usize = 0;
    var condition_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .unknown_comptime_member => member_count += 1,
        .constant_comptime_condition => condition_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), member_count);
    try std.testing.expectEqual(@as(usize, 1), condition_count);

    const generated_source: [:0]const u8 =
        "const Generated = Factory();\n" ++
        "fn inspect() void { _ = @hasField(Generated, \"missing\"); }\n";
    const generated_findings = try findingsWith(arena.allocator(), generated_source, configuration, .{ .resolved_shapes = &.{.{
        .type_name = "Generated",
        .kind = .structure,
        .fields = &.{ "name", "count" },
    }} });
    var generated_member_count: usize = 0;
    for (generated_findings) |finding| switch (finding.rule) {
        .unknown_comptime_member => generated_member_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), generated_member_count);
}

test "usingnamespace uncertainty stays within its container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mixin = struct { pub const shared = 1; };\n" ++
        "const Widget = struct {\n" ++
        "    usingnamespace Mixin;\n" ++
        "    count: u32,\n" ++
        "};\n" ++
        "const Plain = struct { count: u32 };\n" ++
        "fn run() void {\n" ++
        "    _ = @hasDecl(Widget, \"shared\");\n" ++
        "    _ = @hasDecl(Plain, \"missing\");\n" ++
        "    borrowed();\n" ++
        "}\n";
    const configuration = support.only(&.{.unknown_comptime_member}, .hint);
    const found = try findings(arena.allocator(), source, configuration);
    var member_count: usize = 0;
    var call_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_call) call_count += 1;
        if (finding.rule == .unknown_comptime_member) {
            member_count += 1;
            try std.testing.expect(std.mem.find(u8, finding.message, "'Plain'") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), member_count);
    try std.testing.expectEqual(@as(usize, 1), call_count);

    const control: [:0]const u8 = "fn run() void { borrowed(); }\n";
    const control_findings = try findings(arena.allocator(), control, configuration);
    var unresolved_count: usize = 0;
    for (control_findings) |finding| if (finding.rule == .unresolved_call) {
        unresolved_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), unresolved_count);
}
