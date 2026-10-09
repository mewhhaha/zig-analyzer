//! The one table describing every rule: classification, defaults, options,
//! fix availability, and the documentation facts that `docs/rules` is
//! generated from. `Rule.tier`, `Rule.profile`, `Configuration.defaults`, the
//! settings parser, and the rule documents all derive from it.

const std = @import("std");
const types = @import("types.zig");

const Rule = types.Rule;
const Tier = types.Tier;
const Level = types.Level;
const LintProfile = types.LintProfile;

pub const Needs = enum {
    nothing,
    /// Inert until `zig-analyzer.json` declares the contract the rule enforces.
    contract,
    /// Needs facts from the patched compiler; off until opted into.
    compiler,
};

pub const Fixes = enum {
    none,
    /// Offers editor quick fixes that `check --fix` does not apply.
    quick_fix,
    /// Offers a provably safe rewrite that `check --fix` applies.
    fix_all,
};

/// Why a rule has no single-file example.
pub const Absent = enum {
    /// Needs several files or whole-project analysis.
    project,
    /// Needs compiler-backed facts.
    compiler,
    /// Needs project configuration, such as a contract or banned list.
    contract,
    /// Needs input over a size threshold too large to show.
    size,
    /// Judges the file path, not the source text.
    file_name,
};

pub const Example = union(enum) {
    /// A minimal source that triggers the rule when only it is enabled.
    source: [:0]const u8,
    none: Absent,
};

pub const Setting = enum {
    max_lines,
    max_columns,
    allow_unsplittable,
    markers,

    /// The key inside the rule's options object.
    pub fn key(comptime setting: Setting) []const u8 {
        const name = @tagName(setting);
        var bytes: [name.len]u8 = undefined;
        for (name, &bytes) |byte, *out| out.* = if (byte == '_') '-' else byte;
        const final = bytes;
        return &final;
    }

    pub fn description(setting: Setting) []const u8 {
        return switch (setting) {
            .max_lines => "the longest allowed function in source lines, a positive integer",
            .max_columns => "the longest allowed line in columns, a positive integer",
            .allow_unsplittable => "whether a line that cannot be split, such as one long string literal, is exempt, a boolean",
            .markers => "the comments that count as pending work, a non-empty array of non-empty strings",
        };
    }

    /// The default as written in `zig-analyzer.json`.
    pub fn defaultText(setting: Setting, allocator: std.mem.Allocator) ![]const u8 {
        const defaults = types.Configuration.defaults();
        return switch (setting) {
            .max_lines => allocator.print("{d}", .{defaults.function_length_limit}),
            .max_columns => allocator.print("{d}", .{defaults.line_length_limit}),
            .allow_unsplittable => allocator.print("{}", .{defaults.line_length_allow_unsplittable}),
            .markers => markers: {
                var text: std.ArrayList(u8) = .empty;
                errdefer text.deinit(allocator);
                try text.append(allocator, '[');
                for (defaults.todo_markers, 0..) |marker, index| {
                    if (index != 0) try text.appendSlice(allocator, ", ");
                    try text.print(allocator, "\"{s}\"", .{marker});
                }
                try text.append(allocator, ']');
                break :markers text.toOwnedSlice(allocator);
            },
        };
    }
};

/// The options object a rule accepts besides its `level`.
pub const Settings = enum {
    none,
    function_length,
    line_length,
    todo_comment,

    pub fn options(settings: Settings) []const Setting {
        return switch (settings) {
            .none => &.{},
            .function_length => &.{.max_lines},
            .line_length => &.{ .max_columns, .allow_unsplittable },
            .todo_comment => &.{.markers},
        };
    }
};

pub const Entry = struct {
    rule: Rule,
    tier: Tier,
    /// The lowest profile that enables the rule; null when only explicit
    /// configuration or a tier setting turns it on.
    profile: ?LintProfile = null,
    needs: Needs = .nothing,
    settings: Settings = .none,
    fixes: Fixes = .none,
    /// One sentence; the lead paragraph of the rule's document.
    summary: []const u8,
    /// An external specification of the convention the rule enforces.
    reference: ?[]const u8 = null,
    example: Example,

    pub fn defaultLevel(row: Entry) Level {
        if (row.needs != .nothing) return .off;
        return switch (row.tier) {
            .semantic => .@"error",
            .correctness => .warning,
            .style => .off,
        };
    }
};

const rule_count = @typeInfo(Rule).@"enum".field_names.len;

const table: [rule_count]Entry = table: {
    @setEvalBranchQuota(200_000);
    var sorted: [rule_count]Entry = undefined;
    var seen: [rule_count]bool = @splat(false);
    for (entries) |row| {
        const index = @backingInt(row.rule);
        if (seen[index]) @compileError("duplicate catalog entry for " ++ @tagName(row.rule));
        seen[index] = true;
        sorted[index] = row;
    }
    for (seen, 0..) |present, index| {
        if (!present) @compileError("missing catalog entry for " ++ @typeInfo(Rule).@"enum".field_names[index]);
    }
    break :table sorted;
};

pub fn entry(rule: Rule) *const Entry {
    return &table[@backingInt(rule)];
}

/// The rule's page in the repository, which every diagnostic links to.
pub fn documentationUrl(rule: Rule) []const u8 {
    @setEvalBranchQuota(100_000);
    return switch (rule) {
        inline else => |known| "https://github.com/mewhhaha/zig-analyzer/blob/main/docs/rules/" ++ comptime known.code() ++ ".md",
    };
}

test "documentation links point at the rule page" {
    try std.testing.expectEqualStrings(
        "https://github.com/mewhhaha/zig-analyzer/blob/main/docs/rules/self-assignment.md",
        documentationUrl(.self_assignment),
    );
}

test "every entry is coherent" {
    for (std.enums.values(Rule)) |rule| {
        const row = entry(rule);
        errdefer std.debug.print("incoherent catalog entry {s}\n", .{rule.code()});
        try std.testing.expectEqual(rule, row.rule);
        try std.testing.expect(row.summary.len != 0);
        try std.testing.expect(row.summary[row.summary.len - 1] == '.');
        try std.testing.expect(std.mem.findScalar(u8, row.summary, '\n') == null);
        if (row.tier == .semantic) {
            try std.testing.expectEqual(@as(?LintProfile, null), row.profile);
            try std.testing.expectEqual(Needs.nothing, row.needs);
        }
        if (row.settings != .none) try std.testing.expect(row.settings.options().len != 0);
        switch (row.needs) {
            .nothing => {},
            .contract => try std.testing.expectEqual(Example{ .none = .contract }, row.example),
            .compiler => try std.testing.expectEqual(Example{ .none = .compiler }, row.example),
        }
        switch (row.example) {
            .source => |source| try std.testing.expect(source.len != 0),
            .none => {},
        }
    }
}

const entries = [_]Entry{
    .{
        .rule = .unresolved_call,
        .tier = .semantic,
        .summary = "Reports an unqualified call whose function cannot be found in the analyzed scope.",
        .example = .{ .source =
        \\pub fn main() void {
        \\    helper();
        \\}
        },
    },
    .{
        .rule = .unresolved_identifier,
        .tier = .semantic,
        .summary = "Reports an unqualified non-call identifier whose declaration cannot be found in the analyzed file.",
        .example = .{ .source =
        \\pub fn main() void {
        \\    const total = count + 1;
        \\    _ = total;
        \\}
        },
    },
    .{
        .rule = .unresolved_member,
        .tier = .semantic,
        .summary = "Reports a field, declaration, or method access that is absent from a receiver whose complete shape is known: a local container, or an imported module whose public members the host resolved.",
        .example = .{ .source =
        \\const Point = struct { x: i32, y: i32 };
        \\
        \\pub fn main() void {
        \\    const p: Point = .{ .x = 1, .y = 2 };
        \\    _ = p.z;
        \\}
        },
    },
    .{
        .rule = .unresolved_label,
        .tier = .semantic,
        .summary = "Reports a `break` or `continue` whose named target is not an enclosing labeled block or loop.",
        .example = .{ .source =
        \\pub fn main() void {
        \\    for (0..3) |_| {
        \\        break :outer;
        \\    }
        \\}
        },
    },
    .{
        .rule = .missing_switch_prong,
        .tier = .semantic,
        .fixes = .quick_fix,
        .summary = "Reports a switch over a proven finite enum or tagged union that omits cases and has no `else` prong.",
        .reference = "https://ziglang.org/documentation/master/#Exhaustive-Switching",
        .example = .{ .source =
        \\const Color = enum { red, green, blue };
        \\
        \\fn name(c: Color) []const u8 {
        \\    return switch (c) {
        \\        .red => "red",
        \\        .green => "green",
        \\    };
        \\}
        },
    },
    .{
        .rule = .missing_struct_field,
        .tier = .semantic,
        .fixes = .quick_fix,
        .summary = "Reports a struct initializer that omits required fields without defaults.",
        .example = .{ .source =
        \\const Point = struct { x: i32, y: i32 };
        \\
        \\pub fn main() void {
        \\    const p: Point = .{ .x = 1 };
        \\    _ = p;
        \\}
        },
    },
    .{
        .rule = .never_mutated_var,
        .tier = .semantic,
        .fixes = .quick_fix,
        .summary = "Reports a local `var` whose binding and reachable mutable aliases are never mutated.",
        .example = .{ .source =
        \\pub fn main() void {
        \\    var count: u32 = 3;
        \\    _ = count;
        \\}
        },
    },
    .{
        .rule = .unreleased_allocation,
        .tier = .correctness,
        .summary = "Reports a mechanically identified allocation with no visible matching release or ownership return before scope exit.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\pub fn run(gpa: std.mem.Allocator) !void {
        \\    const buf = try gpa.alloc(u8, 16);
        \\    buf[0] = 1;
        \\}
        },
    },
    .{
        .rule = .error_value_comparison,
        .tier = .correctness,
        .summary = "Reports comparisons between an explicitly typed error set and a concrete error value that the set cannot contain.",
        .example = .{ .source =
        \\fn classify(err: error{Missing}) bool {
        \\    return err == error.Other;
        \\}
        },
    },
    .{
        .rule = .discarded_error,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports an empty `catch {}` body.",
        .reference = "https://ziglang.org/documentation/master/#Errors",
        .example = .{ .source =
        \\fn run() !void {}
        \\
        \\pub fn main() void {
        \\    run() catch {};
        \\}
        },
    },
    .{
        .rule = .redundant_bool_comparison,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a proven boolean compared with `true` or `false`.",
        .example = .{ .source =
        \\fn check(ready: bool) void {
        \\    if (ready == true) {}
        \\}
        },
    },
    .{
        .rule = .redundant_boolean_if,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports an `if` expression whose branches merely return a boolean condition or its negation.",
        .example = .{ .source =
        \\fn isAdult(age: u32) bool {
        \\    if (age >= 18) {
        \\        return true;
        \\    } else {
        \\        return false;
        \\    }
        \\}
        },
    },
    .{
        .rule = .non_exhaustive_switch_else,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports `else` used in a switch over a proven finite enum or tagged union when at most eight remaining cases can be named.",
        .reference = "https://ziglang.org/documentation/master/#Exhaustive-Switching",
        .example = .{ .source =
        \\const Color = enum { red, green, blue };
        \\
        \\fn name(c: Color) []const u8 {
        \\    return switch (c) {
        \\        .red => "red",
        \\        else => "other",
        \\    };
        \\}
        },
    },
    .{
        .rule = .non_idiomatic_name,
        .tier = .style,
        .profile = .official,
        .summary = "Reports declarations that do not follow Zig's function, type, or variable naming conventions.",
        .reference = "https://ziglang.org/documentation/master/#Names",
        .example = .{ .source =
        \\fn Compute_total() void {}
        },
    },
    .{
        .rule = .unsorted_imports,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports a safely reorderable top-level import block that is not grouped and sorted by path.",
        .example = .{ .source =
        \\const std = @import("std");
        \\const config = @import("config.zig");
        \\const app = @import("app.zig");
        },
    },
    .{
        .rule = .needless_cast,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports nested identical casts or a cast whose operand is proven to already have the target type.",
        .example = .{ .source =
        \\fn f(x: u32) u32 {
        \\    return @as(u32, x);
        \\}
        },
    },
    .{
        .rule = .needless_else_after_terminator,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports `else` after a branch that always returns, breaks, continues, or evaluates to `noreturn`.",
        .example = .{ .source =
        \\fn f(x: u32) u32 {
        \\    if (x > 3) {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        },
    },
    .{
        .rule = .needless_empty_else,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports an empty else branch.",
        .example = .{ .source =
        \\fn f(x: u32) void {
        \\    if (x > 3) {
        \\        _ = x;
        \\    } else {}
        \\}
        },
    },
    .{
        .rule = .mixed_bitwise_arithmetic,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports bitwise and arithmetic operators mixed without explicit parentheses.",
        .example = .{ .source =
        \\fn f(a: u32, b: u32) u32 {
        \\    return a & b + 1;
        \\}
        },
    },
    .{
        .rule = .unused_private_declaration,
        .tier = .style,
        .fixes = .quick_fix,
        .summary = "Reports a private declaration that is never referenced in its file.",
        .example = .{ .source =
        \\fn helper() void {}
        \\
        \\pub fn main() void {}
        },
    },
    .{
        .rule = .cleanup_after_fallible_operation,
        .tier = .correctness,
        .summary = "Reports cleanup registered only after another fallible operation can exit the scope.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(gpa: std.mem.Allocator) !void {
        \\    const a = try gpa.alloc(u8, 8);
        \\    const b = try gpa.alloc(u8, 8);
        \\    defer gpa.free(a);
        \\    defer gpa.free(b);
        \\}
        },
    },
    .{
        .rule = .mismatched_allocation_release,
        .tier = .correctness,
        .summary = "Reports an allocation released with the wrong method or through a different allocator.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(gpa: std.mem.Allocator) !void {
        \\    const p = try gpa.create(u32);
        \\    gpa.free(p);
        \\}
        },
    },
    .{
        .rule = .double_release,
        .tier = .correctness,
        .fixes = .quick_fix,
        .summary = "Reports more than one visible release of the same allocation in one control-flow scope.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(gpa: std.mem.Allocator) !void {
        \\    const buf = try gpa.alloc(u8, 8);
        \\    gpa.free(buf);
        \\    gpa.free(buf);
        \\}
        },
    },
    .{
        .rule = .use_after_release,
        .tier = .correctness,
        .summary = "Reports a visible use of an allocation after its matching release.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(gpa: std.mem.Allocator) !void {
        \\    const buf = try gpa.alloc(u8, 8);
        \\    gpa.free(buf);
        \\    buf[0] = 1;
        \\}
        },
    },
    .{
        .rule = .overwritten_owning_value,
        .tier = .correctness,
        .summary = "Reports assignment over an owning binding before its previous allocation is released.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(gpa: std.mem.Allocator) !void {
        \\    var buf = try gpa.alloc(u8, 8);
        \\    buf = try gpa.alloc(u8, 16);
        \\    gpa.free(buf);
        \\}
        },
    },
    .{
        .rule = .unsafe_catch_unreachable,
        .tier = .style,
        .profile = .strict,
        .fixes = .quick_fix,
        .summary = "Reports `catch unreachable` on an operation known to be fallible.",
        .reference = "https://ziglang.org/documentation/master/#Errors",
        .example = .{ .source =
        \\fn fail() !void {
        \\    return error.Failed;
        \\}
        \\
        \\fn run() !void {
        \\    fail() catch unreachable;
        \\}
        },
    },
    .{
        .rule = .lost_error_context,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports a catch that maps every failure to one replacement error without using the captured original error.",
        .reference = "https://ziglang.org/documentation/master/#Errors",
        .example = .{ .source =
        \\fn load() !void {
        \\    return error.Failed;
        \\}
        \\
        \\fn open() !void {
        \\    load() catch return error.LoadFailed;
        \\}
        },
    },
    .{
        .rule = .missing_resource_cleanup,
        .tier = .correctness,
        .fixes = .quick_fix,
        .summary = "Reports a recognized resource or mutex with no visible cleanup, unlock, or ownership transfer.",
        .example = .{ .source =
        \\fn save(directory: anytype) !void {
        \\    const file = try directory.openFile("state", .{});
        \\    try file.writeAll("ready");
        \\}
        },
    },
    .{
        .rule = .undefined_value_escape,
        .tier = .correctness,
        .summary = "Reports a value initialized with `undefined` that is read or escapes before whole-value initialization.",
        .example = .{ .source =
        \\fn f() u32 {
        \\    var x: u32 = undefined;
        \\    return x;
        \\}
        },
    },
    .{
        .rule = .unknown_comptime_member,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports `@hasField` or `@hasDecl` checks that are always false, and `@field` lookups that cannot succeed, for a resolved analyzed type shape.",
        .reference = "https://ziglang.org/documentation/master/#comptime",
        .example = .{ .source =
        \\const Point = struct { x: i32, y: i32 };
        \\
        \\const has = @hasField(Point, "z");
        },
    },
    .{
        .rule = .constant_comptime_condition,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports an explicitly comptime condition that is the literal `true` or `false`.",
        .reference = "https://ziglang.org/documentation/master/#comptime",
        .example = .{ .source =
        \\fn f() u32 {
        \\    if (comptime true) return 1;
        \\    return 2;
        \\}
        },
    },
    .{
        .rule = .vague_type_name,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports type names containing generic words that do not describe a domain role.",
        .reference = "https://ziglang.org/documentation/master/#Avoid-Redundancy-in-Names",
        .example = .{ .source =
        \\pub const Context = struct { key: u32 };
        },
    },
    .{
        .rule = .redundant_qualified_name,
        .tier = .style,
        .profile = .official,
        .summary = "Reports a nested type name that repeats its containing namespace.",
        .reference = "https://ziglang.org/documentation/master/#Avoid-Redundant-Names-in-Fully-Qualified-Namespaces",
        .example = .{ .source =
        \\const Parser = struct {
        \\    const ParserError = error{Bad};
        \\};
        },
    },
    .{
        .rule = .underscore_private_name,
        .tier = .style,
        .profile = .official,
        .summary = "Reports declarations prefixed with `_` to suggest privacy.",
        .reference = "https://ziglang.org/documentation/master/#Refrain-from-Underscore-Prefixes",
        .example = .{ .source =
        \\fn _helper() void {}
        },
    },
    .{
        .rule = .non_idiomatic_file_name,
        .tier = .style,
        .profile = .official,
        .summary = "Reports a Zig source filename whose casing does not match the kind of declaration it represents.",
        .reference = "https://ziglang.org/documentation/master/#Names",
        .example = .{ .none = .file_name },
    },
    .{
        .rule = .doc_comment_style,
        .tier = .style,
        .profile = .official,
        .summary = "Reports a doc comment that merely repeats information already supplied by the declaration name.",
        .reference = "https://ziglang.org/documentation/master/#Doc-Comment-Guidance",
        .example = .{ .source =
        \\/// render draws the frame.
        \\pub fn render() void {}
        },
    },
    .{
        .rule = .public_declaration_docs,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports a public declaration without a doc comment.",
        .reference = "https://ziglang.org/documentation/master/#Doc-Comment-Guidance",
        .example = .{ .source =
        \\pub fn run() void {}
        },
    },
    .{
        .rule = .prefer_optional_capture,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports an optional checked for non-null and then force-unwrapped in the guarded branch.",
        .reference = "https://ziglang.org/documentation/master/#if-with-Optionals",
        .example = .{ .source =
        \\fn f(maybe: ?u32) u32 {
        \\    if (maybe != null) {
        \\        return maybe.?;
        \\    }
        \\    return 0;
        \\}
        },
    },
    .{
        .rule = .prefer_try,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a caught error that is immediately returned unchanged.",
        .reference = "https://ziglang.org/documentation/master/#Errors",
        .example = .{ .source =
        \\fn run() !void {}
        \\
        \\fn f() !void {
        \\    run() catch |err| return err;
        \\}
        },
    },
    .{
        .rule = .prefer_testing_expect_equal,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports `std.testing.expect(actual == literal)`-style assertions.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\test "sum" {
        \\    const n: u32 = 2;
        \\    try std.testing.expect(n == 2);
        \\}
        },
    },
    .{
        .rule = .mutable_pointer_parameter,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports a `*T` parameter whose pointee is only read.",
        .example = .{ .source =
        \\fn total(p: *u32) u32 {
        \\    return p.* + 1;
        \\}
        },
    },
    .{
        .rule = .redundant_comptime,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports an explicit `comptime` expression already inside a comptime scope.",
        .reference = "https://ziglang.org/documentation/master/#comptime",
        .example = .{ .source =
        \\fn f() void {
        \\    comptime {
        \\        const n = comptime 1 + 2;
        \\        _ = n;
        \\    }
        \\}
        },
    },
    .{
        .rule = .redundant_inline,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `inline for` or `inline while` already inside a comptime scope.",
        .reference = "https://ziglang.org/documentation/master/#comptime",
        .example = .{ .source =
        \\fn f() void {
        \\    comptime {
        \\        inline for (0..3) |i| {
        \\            _ = i;
        \\        }
        \\    }
        \\}
        },
    },
    .{
        .rule = .needless_defer_block,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a `defer` or `errdefer` block containing only one expression statement.",
        .example = .{ .source =
        \\fn cleanup() void {}
        \\
        \\fn f() void {
        \\    defer {
        \\        cleanup();
        \\    }
        \\}
        },
    },
    .{
        .rule = .non_exhaustive_error_switch,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports a switch over a known finite error set that does not name every error.",
        .reference = "https://ziglang.org/documentation/master/#Exhaustive-Switching",
        .example = .{ .source =
        \\const E = error{ A, B, C };
        \\
        \\fn f(e: E) u32 {
        \\    return switch (e) {
        \\        error.A => 1,
        \\        error.B => 2,
        \\    };
        \\}
        },
    },
    .{
        .rule = .duplicate_import,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports the same module path imported more than once in one file.",
        .example = .{ .source =
        \\const std = @import("std");
        \\const also_std = @import("std");
        },
    },
    .{
        .rule = .unused_import,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a private import alias that is never referenced.",
        .example = .{ .source =
        \\const std = @import("std");
        },
    },
    .{
        .rule = .redundant_import_path,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a relative import path beginning with an unnecessary `./` segment.",
        .example = .{ .source =
        \\const util = @import("./util.zig");
        },
    },
    .{
        .rule = .redundant_type_qualification,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a fully qualified enum value when the result location already establishes its type.",
        .example = .{ .source =
        \\const Color = enum { red, green };
        \\
        \\const default: Color = Color.red;
        },
    },
    .{
        .rule = .prefer_anonymous_initializer,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a named aggregate initializer that repeats a type already established by the result location.",
        .example = .{ .source =
        \\const Point = struct { x: i32, y: i32 };
        \\
        \\const origin: Point = Point{ .x = 0, .y = 0 };
        },
    },
    .{
        .rule = .returning_local_slice,
        .tier = .correctness,
        .summary = "Reports a returned slice that points into a local array.",
        .example = .{ .source =
        \\fn name() []const u8 {
        \\    var buf: [16]u8 = undefined;
        \\    buf[0] = 'a';
        \\    return buf[0..1];
        \\}
        },
    },
    .{
        .rule = .unsafe_orelse_unreachable,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports `orelse unreachable` used to unwrap an optional.",
        .example = .{ .source =
        \\fn first(items: []const u32) u32 {
        \\    return if (items.len > 0) items[0] else 0;
        \\}
        \\
        \\fn use(maybe: ?u32) u32 {
        \\    return maybe orelse unreachable;
        \\}
        },
    },
    .{
        .rule = .redundant_optional_unwrap,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports force-unwrapping an optional inside a scope where its payload is already available as a capture.",
        .example = .{ .source =
        \\fn use(maybe: ?u32) u32 {
        \\    if (maybe) |value| {
        \\        return value + maybe.?;
        \\    }
        \\    return 0;
        \\}
        },
    },
    .{
        .rule = .prefer_testing_expect_equal_strings,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports byte-string equality assertions that use a generic boolean or equality check.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\test "greeting" {
        \\    const greeting: []const u8 = "hello";
        \\    try std.testing.expect(std.mem.eql(u8, greeting, "hello"));
        \\}
        },
    },
    .{
        .rule = .invalidated_container_view,
        .tier = .correctness,
        .summary = "Reports a slice or iterator used after an operation that may move or invalidate its container's backing storage.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn update(allocator: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    const old_items = list.items;
        \\    try list.append(allocator, 1);
        \\    consume(old_items);
        \\}
        \\
        \\fn consume(items: []const u8) void {
        \\    _ = items;
        \\}
        },
    },
    .{
        .rule = .returning_deinitialized_view,
        .tier = .correctness,
        .summary = "Reports a returned view whose backing container is deinitialized by a deferred cleanup during return.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn items(allocator: std.mem.Allocator) []u8 {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    defer list.deinit(allocator);
        \\    return list.items;
        \\}
        },
    },
    .{
        .rule = .returning_arena_allocation,
        .tier = .correctness,
        .summary = "Reports a returned value allocated from a local arena that is deinitialized before the function finishes returning.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn build(gpa: std.mem.Allocator) ![]u8 {
        \\    var arena = std.heap.ArenaAllocator.init(gpa);
        \\    defer arena.deinit();
        \\    return try arena.allocator().alloc(u8, 8);
        \\}
        },
    },
    .{
        .rule = .invalidated_element_pointer,
        .tier = .correctness,
        .summary = "Reports a pointer into a sequence or hash-map entry used after an operation that may reallocate or rehash the backing storage.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn run(allocator: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    defer list.deinit(allocator);
        \\    try list.append(allocator, 1);
        \\    const first = &list.items[0];
        \\    try list.append(allocator, 2);
        \\    first.* = 3;
        \\}
        },
    },
    .{
        .rule = .defer_uses_reassigned_binding,
        .tier = .correctness,
        .summary = "Reports a binding reassigned after deferred cleanup captures it by name.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn run(allocator: std.mem.Allocator) !void {
        \\    var buf = try allocator.alloc(u8, 8);
        \\    defer allocator.free(buf);
        \\    buf = try allocator.alloc(u8, 16);
        \\}
        },
    },
    .{
        .rule = .error_collapsed_to_absence,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports a catch that converts every error to `null` or another empty optional result.",
        .example = .{ .source =
        \\fn parse(text: []const u8) ?u32 {
        \\    return parseInt(text) catch null;
        \\}
        \\
        \\fn parseInt(text: []const u8) !u32 {
        \\    return @intCast(text.len);
        \\}
        },
    },
    .{
        .rule = .allocation_size_overflow,
        .tier = .correctness,
        .summary = "Reports unchecked runtime multiplication used as an allocation length.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn grid(allocator: std.mem.Allocator, w: usize, h: usize) ![]u8 {
        \\    return allocator.alloc(u8, w * h);
        \\}
        },
    },
    .{
        .rule = .resource_cleanup_on_error_only,
        .tier = .correctness,
        .summary = "Reports a resource cleaned up by `errdefer` only, with no successful-path cleanup or ownership transfer.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn load(dir: std.fs.Dir, name: []const u8) !void {
        \\    const file = try dir.openFile(name, .{});
        \\    errdefer file.close();
        \\    try process();
        \\}
        \\
        \\fn process() !void {}
        },
    },
    .{
        .rule = .iterator_invalidated_during_loop,
        .tier = .correctness,
        .summary = "Reports mutation of a map while an iterator over that map is active.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn run(allocator: std.mem.Allocator, map: *std.AutoHashMap(u32, u32)) !void {
        \\    var it = map.iterator();
        \\    while (it.next()) |entry| {
        \\        try map.put(entry.key_ptr.* + 1, 0);
        \\    }
        \\    _ = allocator;
        \\}
        },
    },
    .{
        .rule = .prefer_testing_expect_equal_slices,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports manual slice comparison in a test assertion.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\test "slices" {
        \\    const a = [_]u32{ 1, 2 };
        \\    const b = [_]u32{ 1, 2 };
        \\    try std.testing.expect(std.mem.eql(u32, &a, &b));
        \\}
        },
    },
    .{
        .rule = .prefer_testing_expect_error,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a manual catch-based assertion for one expected error.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn lookup() !void {
        \\    return error.NotFound;
        \\}
        \\
        \\test "lookup fails" {
        \\    lookup() catch |err| {
        \\        try std.testing.expectEqual(error.NotFound, err);
        \\        return;
        \\    };
        \\    return error.TestExpectedError;
        \\}
        },
    },
    .{
        .rule = .prefer_testing_expect_approx,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports a manual absolute-difference floating-point assertion.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\test "approx" {
        \\    const actual: f32 = 0.1 + 0.2;
        \\    const expected: f32 = 0.3;
        \\    try std.testing.expect(@abs(actual - expected) < tolerance);
        \\}
        \\
        \\const tolerance = 0.001;
        },
    },
    .{
        .rule = .prefer_optional_presence_test,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports an optional capture used only to test whether the optional is present.",
        .example = .{ .source =
        \\fn present(maybe: ?u32) bool {
        \\    return if (maybe) |_| true else false;
        \\}
        },
    },
    .{
        .rule = .redundant_error_capture,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a caught error capture that is never referenced.",
        .example = .{ .source =
        \\fn fail() !u32 {
        \\    return error.Boom;
        \\}
        \\
        \\fn run() u32 {
        \\    return fail() catch |err| 0;
        \\}
        },
    },
    .{
        .rule = .needless_switch_else_capture,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports an unused capture on a switch `else` prong.",
        .example = .{ .source =
        \\fn run(value: u32) u32 {
        \\    return switch (value) {
        \\        0 => 1,
        \\        else => |payload| 2,
        \\    };
        \\}
        },
    },
    .{
        .rule = .prefer_sentinel_termination,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports manual allocation of an extra element followed by writing a zero terminator.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn dupeZ(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
        \\    const buf = try allocator.alloc(u8, src.len + 1);
        \\    @memcpy(buf[0..src.len], src);
        \\    buf[src.len] = 0;
        \\    return buf;
        \\}
        },
    },
    .{
        .rule = .unreferenced_test_file,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports a test source file that is neither imported by another Zig file nor referenced from `build.zig`.",
        .example = .{ .none = .project },
    },
    .{
        .rule = .conflicting_build_options,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports one root source configured with different target or optimization options across compile units.",
        .example = .{ .none = .project },
    },
    .{
        .rule = .duplicate_module_import,
        .tier = .correctness,
        .summary = "Reports two import spellings in one file that resolve to the same Zig module path.",
        .example = .{ .source =
        \\const a = @import("util.zig");
        \\const b = @import("./util.zig");
        },
    },
    .{
        .rule = .returning_released_value,
        .tier = .correctness,
        .summary = "Reports a returned owning value that is released by a defer as the function exits.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(allocator: std.mem.Allocator) ![]u8 {
        \\    const buf = try allocator.alloc(u8, 8);
        \\    defer allocator.free(buf);
        \\    return buf;
        \\}
        },
    },
    .{
        .rule = .inclusive_index_bound,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports an inclusive `index <= len`-style assertion used before indexing that requires `index < len`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn at(items: []const u8, index: usize) u8 {
        \\    std.debug.assert(index <= items.len);
        \\    return items[index];
        \\}
        },
    },
    .{
        .rule = .unsigned_reverse_loop,
        .tier = .correctness,
        .fixes = .quick_fix,
        .summary = "Reports a descending unsigned loop whose condition remains true at zero and whose update then underflows.",
        .example = .{ .source =
        \\fn run(items: []u8) void {
        \\    var i: usize = items.len - 1;
        \\    while (i >= 0) : (i -= 1) {
        \\        items[i] = 0;
        \\    }
        \\}
        },
    },
    .{
        .rule = .missing_errdefer,
        .tier = .correctness,
        .fixes = .quick_fix,
        .summary = "Reports a recognized owning acquisition followed by another fallible operation or explicit error return without an intervening error-path release.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(allocator: std.mem.Allocator) !*u32 {
        \\    const p = try allocator.create(u32);
        \\    try check();
        \\    return p;
        \\}
        \\
        \\fn check() !void {}
        },
    },
    .{
        .rule = .aliased_memcpy,
        .tier = .correctness,
        .summary = "Reports `@memcpy` source and destination slices derived from the same base value.",
        .example = .{ .source =
        \\fn shift(buf: []u8) void {
        \\    @memcpy(buf[1..], buf[0 .. buf.len - 1]);
        \\}
        },
    },
    .{
        .rule = .negated_comptime_expression,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports `!comptime expression`, whose precedence is easy to misread.",
        .example = .{ .source =
        \\fn skip() void {
        \\    if (!comptime builtin.isDebug()) return;
        \\}
        },
    },
    .{
        .rule = .usize_in_packed_struct,
        .tier = .correctness,
        .summary = "Reports pointer-sized integer fields in packed or extern layouts.",
        .example = .{ .source =
        \\const Header = packed struct {
        \\    flags: u32,
        \\    count: usize,
        \\};
        },
    },
    .{
        .rule = .unbraced_multiline_if,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports an unbraced `if` whose single body statement begins on a later line.",
        .example = .{ .source =
        \\fn run(x: bool) void {
        \\    if (x)
        \\        doIt();
        \\}
        \\
        \\fn doIt() void {}
        },
    },
    .{
        .rule = .unconditional_busy_loop,
        .tier = .correctness,
        .summary = "Reports `while (true)` bodies with no visible break, return, or call.",
        .example = .{ .source =
        \\var flag: bool = false;
        \\
        \\fn wait() void {
        \\    while (true) {
        \\        if (flag) {}
        \\    }
        \\}
        },
    },
    .{
        .rule = .banned_identifier,
        .tier = .style,
        .summary = "Reports use of a project-configured identifier or dotted path.",
        .example = .{ .none = .contract },
    },
    .{
        .rule = .truncating_intcast,
        .tier = .style,
        .summary = "Reports `@intCast` from a wider integer binding to a narrower target, or from a signed integer to an unsigned target, without a visible range guard.",
        .example = .{ .source =
        \\fn shrink(count: u64) u32 {
        \\    const small: u32 = @intCast(count);
        \\    return small;
        \\}
        },
    },
    .{
        .rule = .padded_byte_compare,
        .tier = .correctness,
        .summary = "Reports byte-wise comparison of values whose struct layout contains padding.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const Pair = struct { a: u8, b: u32 };
        \\
        \\fn same(x: Pair, y: Pair) bool {
        \\    return std.mem.eql(u8, std.mem.asBytes(&x), std.mem.asBytes(&y));
        \\}
        },
    },
    .{
        .rule = .useless_error_return,
        .tier = .correctness,
        .summary = "Reports a fully visible function body that cannot fail although its signature returns an error union.",
        .example = .{ .source =
        \\fn answer() !u32 {
        \\    return 42;
        \\}
        },
    },
    .{
        .rule = .exposed_private_type,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports a public signature that names a private container type declared in the same file.",
        .example = .{ .source =
        \\const Config = struct { verbose: bool };
        \\
        \\pub fn run(config: Config) void {
        \\    _ = config;
        \\}
        },
    },
    .{
        .rule = .exposed_private_error_set,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports a public function signature that names a private error-set declaration.",
        .example = .{ .source =
        \\const Error = error{Boom};
        \\
        \\pub fn run() Error!void {
        \\    return error.Boom;
        \\}
        },
    },
    .{
        .rule = .deprecated_declaration,
        .tier = .correctness,
        .summary = "Reports references to resolved local and imported declarations marked deprecated in their doc comments.",
        .example = .{ .source =
        \\/// Deprecated: use `newName` instead.
        \\fn oldName() void {}
        \\
        \\fn run() void {
        \\    oldName();
        \\}
        },
    },
    .{
        .rule = .mutated_container_copy,
        .tier = .correctness,
        .summary = "Reports metadata mutation of an explicitly typed standard-library container copied from a field when neither value is otherwise observed.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const State = struct { list: std.ArrayList(u8) };
        \\
        \\fn use(self: *State) void {
        \\    var copy: std.ArrayList(u8) = self.list;
        \\    _ = copy.pop();
        \\}
        },
    },
    .{
        .rule = .prefer_range_for,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports an exact zero-based, unit-step counter `while` loop that a range `for` expresses directly.",
        .example = .{ .source =
        \\fn run() void {
        \\    var i: usize = 0;
        \\    while (i < 10) : (i += 1) {
        \\        step(i);
        \\    }
        \\}
        \\
        \\fn step(i: usize) void {
        \\    _ = i;
        \\}
        },
    },
    .{
        .rule = .prefer_index_of,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports a simple loop whose only purpose is comparing elements and returning a matching index or boolean presence result.",
        .example = .{ .source =
        \\fn find(items: []const u32, needle: u32) ?usize {
        \\    for (items, 0..) |item, i| {
        \\        if (item == needle) return i;
        \\    }
        \\    return null;
        \\}
        },
    },
    .{
        .rule = .prefer_memset,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a full-slice pointer-capture loop that only assigns one invariant value to each element.",
        .example = .{ .source =
        \\fn clear(items: []u8) void {
        \\    for (items) |*item| {
        \\        item.* = 0;
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_memcpy,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a full-range element loop that copies `source[index]` to a distinct `destination[index]`.",
        .example = .{ .source =
        \\fn copy() void {
        \\    var dst: [4]u8 = undefined;
        \\    const src = [_]u8{ 1, 2, 3, 4 };
        \\    for (0..dst.len) |j| {
        \\        dst[j] = src[j];
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_map_contains,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `map.get(key) != null` and `map.get(key) == null` when the receiver is proven to have a standard map type.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn has(map: std.AutoHashMap(u32, u32), key: u32) bool {
        \\    return map.get(key) != null;
        \\}
        },
    },
    .{
        .rule = .prefer_array_list_last,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `list.items[list.items.len - 1]` when `list` is proven to have a standard array-list type.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn last(list: std.ArrayList(u32)) u32 {
        \\    return list.items[list.items.len - 1];
        \\}
        \\
        \\fn terminate(list: std.ArrayList(u32)) void {
        \\    list.items[list.items.len - 1] = 0;
        \\}
        },
    },
    .{
        .rule = .prefer_optional_pop,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a non-empty check used only to guard a discarded `ArrayList.pop()` result.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn drop(values: *std.ArrayList(u8)) void {
        \\    if (values.items.len != 0) _ = values.pop();
        \\}
        },
    },
    .{
        .rule = .prefer_expression_initializer,
        .tier = .style,
        .summary = "Reports a local initialized with `undefined` and then assigned exactly once by every branch of an adjacent `if` or `switch`.",
        .example = .{ .source =
        \\fn pick(flag: bool) u32 {
        \\    var x: u32 = undefined;
        \\    if (flag) {
        \\        x = 1;
        \\    } else {
        \\        x = 2;
        \\    }
        \\    return x;
        \\}
        },
    },
    .{
        .rule = .combine_identical_switch_prongs,
        .tier = .style,
        .summary = "Reports adjacent switch prongs with identical bodies and no payload capture.",
        .example = .{ .source =
        \\fn run(n: u8) u8 {
        \\    return switch (n) {
        \\        0 => 1,
        \\        1 => 1,
        \\        else => 2,
        \\    };
        \\}
        },
    },
    .{
        .rule = .prefer_optional_while_capture,
        .tier = .style,
        .summary = "Reports `while (true)` loops whose first statement unwraps an optional with `orelse break`.",
        .example = .{ .source =
        \\fn next() ?u32 {
        \\    return null;
        \\}
        \\
        \\fn run() void {
        \\    while (true) {
        \\        const v = next() orelse break;
        \\        _ = v;
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_loop_else,
        .tier = .style,
        .summary = "Reports a boolean flag whose only purpose is to remember that a loop broke before fallback work.",
        .example = .{ .source =
        \\fn contains(items: []const u32, needle: u32) bool {
        \\    var found = false;
        \\    for (items) |item| {
        \\        if (item == needle) {
        \\            found = true;
        \\            break;
        \\        }
        \\    }
        \\    if (!found) return false;
        \\    return true;
        \\}
        },
    },
    .{
        .rule = .prefer_orelse,
        .tier = .style,
        .summary = "Reports an optional `if` expression whose present branch returns the captured payload unchanged.",
        .example = .{ .source =
        \\fn valueOr(opt: ?u32) u32 {
        \\    return if (opt) |v| v else 0;
        \\}
        },
    },
    .{
        .rule = .prefer_starts_with,
        .tier = .style,
        .summary = "Reports `std.mem.find(..., haystack, needle) == 0` (including legacy `indexOf` calls) prefix tests.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn isComment(line: []const u8) bool {
        \\    return std.mem.indexOf(u8, line, "//") == 0;
        \\}
        },
    },
    .{
        .rule = .prefer_ends_with,
        .tier = .style,
        .summary = "Reports a length-guarded `std.mem.eql` comparison against the tail slice of the same sequence.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn hasSuffix(text: []const u8, suffix: []const u8) bool {
        \\    return text.len >= suffix.len and std.mem.eql(u8, text[text.len - suffix.len ..], suffix);
        \\}
        },
    },
    .{
        .rule = .prefer_count_scalar,
        .tier = .style,
        .summary = "Reports a loop that increments one counter for elements equal to one scalar.",
        .example = .{ .source =
        \\fn countOf(values: []const u8, needle: u8) usize {
        \\    var count: usize = 0;
        \\    for (values) |value| {
        \\        if (value == needle) {
        \\            count += 1;
        \\        }
        \\    }
        \\    return count;
        \\}
        },
    },
    .{
        .rule = .prefer_replace_scalar,
        .tier = .style,
        .summary = "Reports a pointer-capture loop that replaces every element equal to one scalar.",
        .example = .{ .source =
        \\fn replace(values: []u8, old: u8, replacement: u8) void {
        \\    for (values) |*value| {
        \\        if (value.* == old) {
        \\            value.* = replacement;
        \\        }
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_multi_sequence_for,
        .tier = .style,
        .summary = "Reports a zero-based indexed `for` that uses its index only to read a second sequence with an asserted equal length.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn dot(a: []const f32, b: []const f32) f32 {
        \\    std.debug.assert(a.len == b.len);
        \\    var sum: f32 = 0;
        \\    for (a, 0..) |x, i| {
        \\        sum += x * b[i];
        \\    }
        \\    return sum;
        \\}
        },
    },
    .{
        .rule = .prefer_early_return,
        .tier = .style,
        .summary = "Reports an `if` whose `else` block contains only a return.",
        .example = .{ .source =
        \\fn parse(s: []const u8) !u32 {
        \\    if (s.len > 0) {
        \\        return s[0];
        \\    } else {
        \\        return error.Empty;
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_switch,
        .tier = .style,
        .summary = "Reports two or more equality-tested branches in one `if`/`else if` chain over a stable integer, enum, or error value.",
        .example = .{ .source =
        \\const Kind = enum { a, b, c };
        \\
        \\fn weight(kind: Kind) u32 {
        \\    if (kind == .a) {
        \\        return 1;
        \\    } else if (kind == .b) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_string_switch,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports three or more adjacent-style `std.mem.eql` string comparisons that map the same subject to simple values.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const Command = enum { start, stop, status, unknown };
        \\
        \\fn parse(cmd: []const u8) Command {
        \\    return if (std.mem.eql(u8, cmd, "start")) .start
        \\    else if (std.mem.eql(u8, cmd, "stop")) .stop
        \\    else if (std.mem.eql(u8, cmd, "status")) .status
        \\    else .unknown;
        \\}
        },
    },
    .{
        .rule = .prefer_log_over_print,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .quick_fix,
        .summary = "Reports `std.debug.print` outside test blocks and executable entrypoint files.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\pub fn report(count: usize) void {
        \\    std.debug.print("count: {d}\n", .{count});
        \\}
        },
    },
    .{
        .rule = .prefer_buffered_writer,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports writes through a directly obtained unbuffered writer inside a loop.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn dump(dir: std.fs.Dir, values: []const u8) !void {
        \\    const file = try dir.createFile("out.txt", .{});
        \\    const writer = file.writer();
        \\    for (values) |value| {
        \\        try writer.print("{d}\n", .{value});
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_arena,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports a scope with at least three allocations from one allocator and a matching release for each.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn work(gpa: std.mem.Allocator) !void {
        \\    const a = try gpa.alloc(u8, 16);
        \\    defer gpa.free(a);
        \\    const b = try gpa.alloc(u8, 32);
        \\    defer gpa.free(b);
        \\    const c = try gpa.alloc(u8, 64);
        \\    defer gpa.free(c);
        \\}
        },
    },
    .{
        .rule = .inconsistent_import_alias,
        .tier = .style,
        .summary = "Reports an import alias that differs from the dominant alias for the same module across the scanned project.",
        .example = .{ .none = .size },
    },
    .{
        .rule = .minority_naming_style,
        .tier = .style,
        .summary = "Reports a function, type, or constant whose casing differs from the project's dominant casing for that declaration kind.",
        .example = .{ .none = .size },
    },
    .{
        .rule = .inconsistent_parameter_vocabulary,
        .tier = .style,
        .summary = "Reports a parameter name that differs from the dominant name used for the same spelled type across the project.",
        .example = .{ .none = .size },
    },
    .{
        .rule = .inconsistent_error_set_style,
        .tier = .style,
        .summary = "Reports a public error-returning function whose explicit or inferred error-set style differs from the project majority.",
        .example = .{ .none = .size },
    },
    .{
        .rule = .modernize_managed_container,
        .tier = .style,
        .profile = .modernize,
        .summary = "Reports `std.array_list.Managed`, `std.array_list.AlignedManaged`, and `std.bit_set.DynamicManaged`, the allocator-storing compatibility containers.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn make(gpa: std.mem.Allocator) std.array_list.Managed(u8) {
        \\    return std.array_list.Managed(u8).init(gpa);
        \\}
        },
    },
    .{
        .rule = .modernize_deprecated_io,
        .tier = .style,
        .profile = .modernize,
        .fixes = .fix_all,
        .summary = "Reports known pre-`std.Io` reader, writer, and buffering adapters reached through `std.io` or `std.Io`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const read = std.Io.Reader.readAlloc;
        },
    },
    .{
        .rule = .modernize_deprecated_stdlib,
        .tier = .style,
        .profile = .modernize,
        .fixes = .fix_all,
        .summary = "Reports fully qualified `std` declarations Zig 0.17 deprecates or no longer ships, naming the current replacement.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn f(a: []const u8, b: []const u8) bool {
        \\    return std.mem.eql(u8, a, b) or std.ascii.eqlIgnoreCase(a, b) or std.mem.indexOf(u8, a, b) != null;
        \\}
        },
    },
    .{
        .rule = .modernize_deprecated_builtin,
        .tier = .style,
        .profile = .modernize,
        .fixes = .fix_all,
        .summary = "Reports Zig 0.17's deprecated enum conversion builtins and deprecated target constants from `@import(\"builtin\")`.",
        .example = .{ .source =
        \\const E = enum(u8) { a, b };
        \\
        \\fn f(x: u8) E {
        \\    return @enumFromInt(x);
        \\}
        \\fn g(e: E) u8 {
        \\    return @intFromEnum(e);
        \\}
        \\fn h(x: u8) E {
        \\    return @intToEnum(E, x);
        \\}
        },
    },
    .{
        .rule = .modernize_removed_syntax,
        .tier = .style,
        .profile = .modernize,
        .fixes = .fix_all,
        .summary = "Reports removed Zig 0.17 syntax: `@cImport`, obvious array multiplication expressions using `**`, `void{}`, `errdefer` error captures, and the `i0` primitive type.",
        .example = .{ .source =
        \\const unit = void{};
        },
    },
    .{
        .rule = .modernize_build_api,
        .tier = .style,
        .profile = .modernize,
        .fixes = .fix_all,
        .summary = "Reports removed `std.Build.args` and `LazyPath.basename` access, the deprecated `addTranslateC` build step, Windows resource compilation APIs, legacy Run argument wrappers, `lazyDependency`, and the old two-argument `findProgram` call.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{ .name = "tool", .root_module = b.createModule(.{}) });
        \\    const run = b.addRunArtifact(exe);
        \\    run.addArtifactArg(exe);
        \\}
        },
    },
    .{
        .rule = .modernize_bitcast,
        .tier = .style,
        .profile = .modernize,
        .summary = "Reports `@bitCast` calls with a syntactically proven array or vector source or destination for review during a Zig 0.17 migration.",
        .example = .{ .source =
        \\fn bytes(x: u32) [4]u8 {
        \\    const out: [4]u8 = @bitCast(x);
        \\    return out;
        \\}
        },
    },
    .{
        .rule = .modernize_extern_bitcast,
        .tier = .style,
        .profile = .modernize,
        .summary = "Reports `@bitCast` calls with a proven `extern struct` or `extern union` source or destination, which Zig 0.17 no longer permits.",
        .example = .{ .source =
        \\const Header = extern struct { a: u16, b: u16 };
        \\
        \\fn word(h: Header) u32 {
        \\    return @bitCast(h);
        \\}
        },
    },
    .{
        .rule = .modernize_global_linkage,
        .tier = .style,
        .profile = .modernize,
        .summary = "Reports Zig 0.17's removed `GlobalLinkage.internal` and `GlobalLinkage.link_once` tags in proven standard-library linkage paths or direct linkage options passed to `@export` and `@extern`.",
        .example = .{ .source =
        \\export fn answer() u32 {
        \\    return 42;
        \\}
        \\
        \\comptime {
        \\    @export(&answer, .{ .name = "answer", .linkage = .link_once });
        \\}
        },
    },
    .{
        .rule = .modernize_array_list_access,
        .tier = .style,
        .profile = .modernize,
        .fixes = .fix_all,
        .summary = "Reports deprecated `getLastOrNull()` and `getLast()` calls on proven standard `ArrayList` / `array_list.Aligned` values.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn last(gpa: std.mem.Allocator) !?u8 {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    defer list.deinit(gpa);
        \\    try list.append(gpa, 1);
        \\    return list.getLastOrNull();
        \\}
        },
    },
    .{
        .rule = .modernize_container_init,
        .tier = .style,
        .profile = .modernize,
        .fixes = .fix_all,
        .summary = "Reports removed `initEmpty()` and `initFull()` calls on proven fixed-size `std.bit_set.Integer`, `Array`, `Static` and `std.enums.EnumSet` types, including their legacy aliases.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn set() std.bit_set.IntegerBitSet(8) {
        \\    return std.bit_set.IntegerBitSet(8).initEmpty();
        \\}
        },
    },
    .{
        .rule = .prefer_div_ceil,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Suggests Zig 0.17's `@divCeil` for proven calls to `std.math.divCeil` and for conservative unsigned ceiling-division patterns such as `(count + block_size - 1) / block_size`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn blocks(count: u32) !u32 {
        \\    return try std.math.divCeil(u32, count, 8);
        \\}
        },
    },
    .{
        .rule = .function_length,
        .tier = .style,
        .profile = .disciplined,
        .settings = .function_length,
        .summary = "Reports a function spanning more source lines than the configured limit.",
        .example = .{ .none = .size },
    },
    .{
        .rule = .assertion_free_branching,
        .tier = .style,
        .profile = .disciplined,
        .summary = "Reports a nontrivial function with computed indexing but no visible assertion, unreachable arm, loop bound, or early-exit bounds validation.",
        .example = .{ .source =
        \\fn pick(table: []const u32, key: u32, mode: u32) u32 {
        \\    var total: u32 = 0;
        \\    if (mode == 0) {
        \\        total += 1;
        \\    }
        \\    const slot = key % 8;
        \\    total += table[slot];
        \\    return total;
        \\}
        },
    },
    .{
        .rule = .unbounded_loop,
        .tier = .style,
        .profile = .disciplined,
        .summary = "Reports a `while` loop with no visible comparison bound, exhaustion condition, or counter guard.",
        .example = .{ .source =
        \\fn spin(flag: *bool) void {
        \\    while (true) {
        \\        flag.* = !flag.*;
        \\    }
        \\}
        },
    },
    .{
        .rule = .allocation_after_init,
        .tier = .style,
        .profile = .disciplined,
        .summary = "Reports direct allocation in a function outside recognized `init*` and `create*` paths.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn grow(gpa: std.mem.Allocator) ![]u8 {
        \\    return try gpa.alloc(u8, 16);
        \\}
        },
    },
    .{
        .rule = .recursive_call,
        .tier = .style,
        .profile = .disciplined,
        .summary = "Reports direct recursion and proven two-function mutual recursion in the scanned project.",
        .example = .{ .source =
        \\fn fact(n: u64) u64 {
        \\    if (n == 0) return 1;
        \\    return n * fact(n - 1);
        \\}
        },
    },
    .{
        .rule = .line_length,
        .tier = .style,
        .settings = .line_length,
        .summary = "Reports source lines wider than the configured number of display columns.",
        .example = .{ .source =
        \\const message = "this string literal is deliberately long so that the whole declaration line goes past one hundred columns";
        },
    },
    .{
        .rule = .allocator_first_parameter,
        .tier = .style,
        .summary = "Reports a `std.mem.Allocator` parameter that is not first after an optional `self` parameter.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn repeat(count: usize, gpa: std.mem.Allocator) ![]u8 {
        \\    return gpa.alloc(u8, count);
        \\}
        },
    },
    .{
        .rule = .comptime_parameter_order,
        .tier = .style,
        .summary = "Reports a `comptime` parameter following a runtime parameter.",
        .example = .{ .source =
        \\fn fill(len: usize, comptime T: type) [4]T {
        \\    _ = len;
        \\    return undefined;
        \\}
        },
    },
    .{
        .rule = .todo_comment,
        .tier = .style,
        .settings = .todo_comment,
        .summary = "Reports configured task markers, by default `TODO`, `FIXME`, and `XXX`, in line comments.",
        .example = .{ .source =
        \\// TODO: handle the empty case
        \\fn first(items: []const u8) u8 {
        \\    return items[0];
        \\}
        },
    },
    .{
        .rule = .assertion_free_test,
        .tier = .style,
        .summary = "Reports a test block with no expectation, propagated fallible call, catch, or debug assertion.",
        .example = .{ .source =
        \\fn setup() void {}
        \\
        \\test "setup" {
        \\    setup();
        \\}
        },
    },
    .{
        .rule = .literal_boolean_argument,
        .tier = .style,
        .profile = .strict,
        .summary = "Reports literal `true` or `false` arguments passed to boolean parameters in multi-parameter project functions.",
        .example = .{ .source =
        \\fn open(path: []const u8, create: bool) void {
        \\    _ = path;
        \\    _ = create;
        \\}
        \\
        \\fn run() void {
        \\    open("log.txt", true);
        \\}
        },
    },
    .{
        .rule = .import_boundary,
        .tier = .correctness,
        .needs = .contract,
        .summary = "Reports an import denied by a project contract in `zig-analyzer.json`.",
        .example = .{ .none = .contract },
    },
    .{
        .rule = .discarded_must_use,
        .tier = .correctness,
        .needs = .contract,
        .summary = "Reports `_ = call()` when the callable has a declared must-use contract.",
        .example = .{ .none = .contract },
    },
    .{
        .rule = .copied_io_interface,
        .tier = .correctness,
        .summary = "Reports a standard reader or writer interface copied out of its implementation value.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn load(io: std.Io, path: []const u8) !void {
        \\    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        \\    var buffer: [1024]u8 = undefined;
        \\    var file_reader = file.reader(io, &buffer);
        \\    const reader = file_reader.interface;
        \\    _ = reader;
        \\}
        },
    },
    .{
        .rule = .directory_iteration_not_enabled,
        .tier = .correctness,
        .summary = "Reports iteration of a standard directory opened with literal options that do not set `.iterate = true`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn walk(io: std.Io, path: []const u8) !void {
        \\    var directory = try std.Io.Dir.cwd().openDir(io, path, .{});
        \\    var iterator = directory.iterate();
        \\    _ = &iterator;
        \\}
        },
    },
    .{
        .rule = .discarded_read_count,
        .tier = .correctness,
        .summary = "Reports an explicitly discarded byte count returned by a partial-read method.",
        .example = .{ .source =
        \\fn receive(reader: anytype) !u8 {
        \\    var bytes: [8]u8 = undefined;
        \\    _ = try reader.read(&bytes);
        \\    return bytes[0];
        \\}
        },
    },
    .{
        .rule = .discarded_realloc_result,
        .tier = .correctness,
        .summary = "Reports an explicitly discarded slice returned by `realloc` or `reallocAdvanced`.",
        .example = .{ .source =
        \\fn resize(allocator: anytype, bytes: []u8) !void {
        \\    _ = try allocator.realloc(bytes, 32);
        \\}
        },
    },
    .{
        .rule = .discarded_write_count,
        .tier = .correctness,
        .summary = "Reports an explicitly discarded return value from a writer's `write` method.",
        .example = .{ .source =
        \\fn send(writer: anytype, bytes: []const u8) !void {
        \\    _ = try writer.write(bytes);
        \\}
        },
    },
    .{
        .rule = .unreported_partial_send,
        .tier = .correctness,
        .summary = "Reports uses of the deprecated `std.Io.net.Socket.sendMany` API, whose error result discards the number of messages already sent.",
        .example = .{ .source =
        \\const std = @import("std");
        \\const Socket = std.Io.net.Socket;
        \\
        \\fn flush(io: std.Io, socket: *const Socket, messages: []Socket.Message) !void {
        \\    try socket.sendMany(io, messages, .{});
        \\}
        },
    },
    .{
        .rule = .unchecked_first_element,
        .tier = .correctness,
        .summary = "Reports a public function indexing a plain-slice parameter at zero without a visible proof that the slice is non-empty.",
        .example = .{ .source =
        \\pub fn first(bytes: []const u8) u8 {
        \\    return bytes[0];
        \\}
        },
    },
    .{
        .rule = .unsequenced_state_access,
        .tier = .correctness,
        .summary = "Reports an aggregate literal that copies a mutable local into one field while another field calls a state-changing method on the same local.",
        .example = .{ .source =
        \\const Lexer = struct {
        \\    source: []const u8,
        \\    pos: usize = 0,
        \\
        \\    fn next(self: *Lexer) !u8 {
        \\        defer self.pos += 1;
        \\        return self.source[self.pos];
        \\    }
        \\};
        \\
        \\const Parser = struct { lexer: Lexer, current: u8 };
        \\
        \\fn init(source: []const u8) !Parser {
        \\    var lexer = Lexer{ .source = source };
        \\    return .{ .lexer = lexer, .current = try lexer.next() };
        \\}
        },
    },
    .{
        .rule = .unchecked_slice_reinterpretation,
        .tier = .correctness,
        .summary = "Reports nested `@alignCast` and `@ptrCast` operations applied in either order to a plain slice without an alignment guarantee in its type.",
        .example = .{ .source =
        \\const Header = extern struct { magic: u32, len: u32 };
        \\
        \\fn parse(raw: []const u8) Header {
        \\    const aligned: *align(@alignOf(Header)) const u8 = @alignCast(@ptrCast(raw.ptr));
        \\    return @as(*const Header, @ptrCast(aligned)).*;
        \\}
        },
    },
    .{
        .rule = .undefined_readvec_destination,
        .tier = .correctness,
        .summary = "Reports `readVec` calls passed an array of slice descriptors that is still undefined, including locally declared descriptor structs containing slices.",
        .example = .{ .source =
        \\fn receive(reader: anytype) !void {
        \\    var buffers: [1][]u8 = undefined;
        \\    _ = try reader.readVec(&buffers);
        \\}
        },
    },
    .{
        .rule = .local_storage_escape,
        .tier = .correctness,
        .summary = "Reports a view or pointer into local storage retained by a returned aggregate, a callee, a longer-lived container, an output parameter, or direct assignment to module state.",
        .example = .{ .source =
        \\var saved: []const u8 = &.{};
        \\
        \\fn remember() void {
        \\    var scratch = [_]u8{ 1, 2, 3 };
        \\    saved = scratch[0..];
        \\}
        },
    },
    .{
        .rule = .incomplete_owned_field_cleanup,
        .tier = .correctness,
        .summary = "Reports an aggregate or container whose cleanup drops proven owned fields.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const Record = struct {
        \\    title: []u8,
        \\    payload: []u8,
        \\    allocator: std.mem.Allocator,
        \\
        \\    fn deinit(self: Record) void {
        \\        self.allocator.free(self.title);
        \\    }
        \\};
        \\
        \\fn makeRecord(allocator: std.mem.Allocator) !Record {
        \\    const title = try allocator.dupe(u8, "title");
        \\    const payload = try allocator.dupe(u8, "payload");
        \\    return .{ .title = title, .payload = payload, .allocator = allocator };
        \\}
        },
    },
    .{
        .rule = .partial_ownership_transfer,
        .tier = .correctness,
        .summary = "Reports returning one owned field from a value whose cleanup contract releases additional owned fields, without first cleaning or transferring the owner.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const Packet = struct {
        \\    header: []u8,
        \\    body: []u8,
        \\    allocator: std.mem.Allocator,
        \\
        \\    fn deinit(self: Packet) void {
        \\        self.allocator.free(self.header);
        \\        self.allocator.free(self.body);
        \\    }
        \\};
        \\
        \\fn readPacket(allocator: std.mem.Allocator) !Packet {
        \\    return .{
        \\        .header = try allocator.dupe(u8, "h"),
        \\        .body = try allocator.dupe(u8, "b"),
        \\        .allocator = allocator,
        \\    };
        \\}
        \\
        \\fn takeBody(allocator: std.mem.Allocator) ![]u8 {
        \\    const packet = try readPacket(allocator);
        \\    return packet.body;
        \\}
        },
    },
    .{
        .rule = .stale_index_map,
        .tier = .correctness,
        .summary = "Reports removal from an indexed sequence when a sibling map or an element field stores sequence indices and is not updated in the same operation.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const Registry = struct {
        \\    rows: std.ArrayList(Row),
        \\    by_name: std.StringHashMapUnmanaged(usize),
        \\
        \\    const Row = struct { name: []const u8 };
        \\
        \\    fn add(self: *Registry, allocator: std.mem.Allocator, name: []const u8) !void {
        \\        try self.by_name.put(allocator, name, self.rows.items.len);
        \\        try self.rows.append(allocator, .{ .name = name });
        \\    }
        \\
        \\    fn remove(self: *Registry, index: usize) void {
        \\        _ = self.rows.swapRemove(index);
        \\    }
        \\};
        },
    },
    .{
        .rule = .lock_order_cycle,
        .tier = .correctness,
        .summary = "Reports two functions that acquire the same pair of locks in opposite nested orders.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const Bank = struct {
        \\    primary: std.Thread.Mutex = .{},
        \\    secondary: std.Thread.Mutex = .{},
        \\
        \\    fn forward(self: *Bank) void {
        \\        self.primary.lock();
        \\        defer self.primary.unlock();
        \\        self.secondary.lock();
        \\        defer self.secondary.unlock();
        \\    }
        \\
        \\    fn reverse(self: *Bank) void {
        \\        self.secondary.lock();
        \\        defer self.secondary.unlock();
        \\        self.primary.lock();
        \\        defer self.primary.unlock();
        \\    }
        \\};
        },
    },
    .{
        .rule = .wait_while_holding_lock,
        .tier = .correctness,
        .summary = "Reports a loop that waits for shared state while retaining the lock another visible function needs to update that state.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const State = struct {
        \\    mutex: std.Thread.Mutex = .{},
        \\    ready: std.atomic.Value(bool) = .init(false),
        \\
        \\    fn wait(self: *State) void {
        \\        self.mutex.lock();
        \\        defer self.mutex.unlock();
        \\        while (!self.ready.load(.acquire)) {}
        \\    }
        \\
        \\    fn signal(self: *State) void {
        \\        self.mutex.lock();
        \\        defer self.mutex.unlock();
        \\        self.ready.store(true, .release);
        \\    }
        \\};
        },
    },
    .{
        .rule = .silent_buffer_truncation,
        .tier = .correctness,
        .summary = "Reports a void-returning fixed-buffer write that limits its copy with `@min` without reporting whether all input was written.",
        .example = .{ .source =
        \\const Writer = struct {
        \\    storage: [64]u8 = undefined,
        \\    used: usize = 0,
        \\
        \\    fn write(self: *Writer, bytes: []const u8) void {
        \\        const amount = @min(bytes.len, self.storage.len - self.used);
        \\        @memcpy(self.storage[self.used..][0..amount], bytes[0..amount]);
        \\        self.used += amount;
        \\    }
        \\};
        },
    },
    .{
        .rule = .pointer_only_free,
        .tier = .correctness,
        .summary = "Reports reconstructing a fixed-length slice from a many pointer and passing it to an allocator's `free` without receiving the allocation length.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn release(allocator: std.mem.Allocator, ptr: [*]u8) void {
        \\    const bytes = ptr[0..16];
        \\    allocator.free(bytes);
        \\}
        },
    },
    .{
        .rule = .nullable_pointer_length,
        .tier = .correctness,
        .summary = "Reports allocating from a length paired with a nullable C pointer, then returning the allocation uninitialized when the pointer is null.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn copy(allocator: std.mem.Allocator, ptr: ?[*]const u8, len: usize) ![]u8 {
        \\    const out = try allocator.alloc(u8, len);
        \\    if (ptr) |p| {
        \\        @memcpy(out, p[0..len]);
        \\    }
        \\    return out;
        \\}
        },
    },
    .{
        .rule = .discarded_resource,
        .tier = .correctness,
        .summary = "Reports explicitly discarded successful results from OS calls and recognized `std.Io.Dir` or `std.fs.Dir` methods that create files or handles.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn touch(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        \\    _ = io;
        \\    _ = try dir.openFile(path, .{});
        \\}
        },
    },
    .{
        .rule = .child_pipe_double_close,
        .tier = .correctness,
        .summary = "Reports manually closing a child process pipe before calling the child wait operation that owns cleanup of that pipe.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn run(io: std.Io, child: *std.process.Child) !void {
        \\    child.stdout.?.close(io);
        \\    try child.wait(io);
        \\}
        },
    },
    .{
        .rule = .unwaited_child_process,
        .tier = .correctness,
        .summary = "Reports a child returned by `std.process.spawn` that reaches the end of its scope without `wait`, `kill`, or ownership transfer.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn launch(io: std.Io, wait_for_it: bool) !void {
        \\    var child = try std.process.spawn(io, .{ .argv = &.{"true"} });
        \\    if (wait_for_it) {
        \\        _ = try child.wait(io);
        \\    }
        \\}
        },
    },
    .{
        .rule = .configuration_divergent_api,
        .tier = .style,
        .needs = .compiler,
        .summary = "Reports a public declaration whose compiler-resolved shape differs between configured compile units.",
        .example = .{ .none = .compiler },
    },
    .{
        .rule = .unreachable_public_declaration,
        .tier = .style,
        .needs = .compiler,
        .summary = "Reports a public declaration outside every successfully compiler-analyzed compile unit's import graph.",
        .example = .{ .none = .compiler },
    },
    .{
        .rule = .invariant_loop_condition,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports a `while` condition whose simple numeric comparison is fixed by a literal `const` binding.",
        .example = .{ .source =
        \\fn spin() void {
        \\    const limit = 10;
        \\    var i: u32 = 0;
        \\    while (limit > 5) {
        \\        i += 1;
        \\    }
        \\}
        },
    },
    .{
        .rule = .overflow_before_clamp,
        .tier = .correctness,
        .summary = "Reports direct checked integer addition inside `@min`, or subtraction inside `@max`, when the arithmetic can overflow or underflow before the clamp is evaluated.",
        .example = .{ .source =
        \\fn clampedEnd(start: u32, len: u32, max: u32) u32 {
        \\    return @min(start + len, max);
        \\}
        },
    },
    .{
        .rule = .unchecked_range_end,
        .tier = .correctness,
        .summary = "Reports unchecked addition used as a range end in a comparison or slice bound, such as `offset + bytes.len <= total` or `bytes[offset..offset + length]`, when the addition itself can overflow before bounds validation runs.",
        .example = .{ .source =
        \\fn fits(offset: usize, bytes: []const u8, total: usize) bool {
        \\    return offset + bytes.len <= total;
        \\}
        },
    },
    .{
        .rule = .quadratic_front_removal,
        .tier = .style,
        .profile = .disciplined,
        .summary = "Reports `orderedRemove(0)` while a loop drains the same `ArrayList` according to its remaining length.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn drain(queue: *std.ArrayList(u32)) void {
        \\    while (queue.items.len > 0) {
        \\        _ = queue.orderedRemove(0);
        \\    }
        \\}
        },
    },
    .{
        .rule = .self_assignment,
        .tier = .correctness,
        .fixes = .quick_fix,
        .summary = "Reports an assignment where the left-hand side and right-hand side evaluate to the same variable or field path.",
        .example = .{ .source =
        \\fn tally(values: []const u32) u32 {
        \\    var total: u32 = 0;
        \\    for (values) |value| total += value;
        \\    total = total;
        \\    return total;
        \\}
        },
    },
    .{
        .rule = .identical_comparison_operands,
        .tier = .correctness,
        .summary = "Reports a comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`) where both operands are textually and semantically identical paths.",
        .example = .{ .source =
        \\fn inRange(low: u32, high: u32) bool {
        \\    return low <= high and high == high;
        \\}
        },
    },
    .{
        .rule = .redundant_slice_end,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports a slice operation where the upper bound explicitly specifies `<slice>.len`.",
        .example = .{ .source =
        \\fn tail(bytes: []const u8) []const u8 {
        \\    return bytes[4..bytes.len];
        \\}
        },
    },
    .{
        .rule = .redundant_boolean_negation,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports double boolean negation operations (`!!x` or `!(!x)`) and negated boolean constants (`!true` or `!false`).",
        .example = .{ .source =
        \\fn isReady(flag: bool) bool {
        \\    return !!flag;
        \\}
        },
    },
    .{
        .rule = .prefer_min_max,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports conditional `if` expressions choosing the lesser or greater of two operands that can be expressed directly with `@min` or `@max`.",
        .example = .{ .source =
        \\fn smaller(a: u32, b: u32) u32 {
        \\    return if (a < b) a else b;
        \\}
        },
    },
    .{
        .rule = .identical_logical_operands,
        .tier = .correctness,
        .fixes = .fix_all,
        .summary = "Reports a logical `and` or `or` expression whose left-hand and right-hand operands evaluate to the exact same path.",
        .example = .{ .source =
        \\fn valid(a: bool, b: bool) bool {
        \\    return a and b and a and a;
        \\}
        },
    },
    .{
        .rule = .identical_conditional_branches,
        .tier = .correctness,
        .fixes = .fix_all,
        .summary = "Reports an `if` expression or statement where the `then` and `else` branches have identical bodies.",
        .example = .{ .source =
        \\fn pick(values: []const u32) u32 {
        \\    if (values.len > 4) {
        \\        return values[0];
        \\    } else {
        \\        return values[0];
        \\    }
        \\}
        },
    },
    .{
        .rule = .nan_comparison,
        .tier = .correctness,
        .fixes = .fix_all,
        .summary = "Reports comparison with a NaN value (`std.math.nan`, `std.math.snan`, `math.nan`, or `math.snan`).",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn isMissing(x: f64) bool {
        \\    return x == std.math.nan(f64);
        \\}
        },
    },
    .{
        .rule = .identical_bitwise_operands,
        .tier = .correctness,
        .fixes = .fix_all,
        .summary = "Reports a bitwise `&`, `|`, or `^` operation whose left-hand and right-hand operands evaluate to the exact same path.",
        .example = .{ .source =
        \\fn mask(flags: u32) u32 {
        \\    return flags & flags;
        \\}
        },
    },
    .{
        .rule = .prefer_empty_slice_len,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `std.mem.eql` or `mem.eql` comparisons where one operand is an empty string literal `\"\"` or empty slice `&.{}` instead of checking `.len == 0` or `.len != 0`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn isEmpty(name: []const u8) bool {
        \\    return std.mem.eql(u8, name, "");
        \\}
        },
    },
    .{
        .rule = .prefer_index_of_scalar,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `std.mem.find`, `findLast`, `findAny`, `findLastAny`, and `count` calls with a single-byte string literal.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn hasComma(line: []const u8) bool {
        \\    return std.mem.find(u8, line, ",") != null;
        \\}
        },
    },
    .{
        .rule = .prefer_split_scalar,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `std.mem.splitSequence`, `std.mem.splitBackwardsSequence`, `std.mem.tokenizeSequence`, or `std.mem.tokenizeAny` called with a single-character string literal instead of using `splitScalar`, `splitBackwardsScalar`, or `tokenizeScalar` with a character literal.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn firstField(line: []const u8) ?[]const u8 {
        \\    var parts = std.mem.splitSequence(u8, line, ",");
        \\    return parts.next();
        \\}
        },
    },
    .{
        .rule = .pointer_to_allocator,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports function parameters or struct fields typed as `*std.mem.Allocator` or `*Allocator`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn build(allocator: *std.mem.Allocator) ![]u8 {
        \\    return allocator.alloc(u8, 16);
        \\}
        },
    },
    .{
        .rule = .expect_equal_argument_order,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `std.testing.expectEqual` called with `(actual, expected)` where a literal constant is passed as the second argument instead of the first.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\test "answer" {
        \\    const value: u32 = 40 + 2;
        \\    try std.testing.expectEqual(value, 42);
        \\}
        },
    },
    .{
        .rule = .prefer_allocator_dupe,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports allocator `print` and `printSentinel` calls, and legacy `std.fmt.allocPrint` and `allocPrintSentinel` calls, that only duplicate a string.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn copy(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        \\    return std.fmt.allocPrint(allocator, "{s}", .{name});
        \\}
        },
    },
    .{
        .rule = .prefer_append_slice,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports loops that append slice elements one-by-one into an `ArrayList` or `ArrayListUnmanaged`, recommending `appendSlice` or `appendSliceAssumeCapacity` instead.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn addAll(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
        \\    for (bytes) |byte| {
        \\        try list.append(allocator, byte);
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_eql_over_order,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `std.mem.order(T, a, b) == .eq` or `!= .eq` used to test equality, recommending `std.mem.eql(T, a, b)` or `!std.mem.eql(T, a, b)` instead.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn same(a: []const u8, b: []const u8) bool {
        \\    return std.mem.order(u8, a, b) == .eq;
        \\}
        },
    },
    .{
        .rule = .prefer_math_pow,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `std.math.pow` for `f32` or `f64` called with exponents `0.5`, `2`, `1`, or `0` where simpler expressions exist.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn square(x: f64) f64 {
        \\    return std.math.pow(f64, x, 2);
        \\}
        },
    },
    .{
        .rule = .prefer_vector_splat,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `@Vector` literal initializers that repeat the same scalar value across all lanes, recommending `@splat` instead.",
        .example = .{ .source =
        \\const ones: @Vector(4, u32) = .{ 1, 1, 1, 1 };
        },
    },
    .{
        .rule = .prefer_vector_load,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `@Vector` literal initializers that manually unpack consecutive elements from an array (`.{ arr[0], arr[1], ... }`), recommending direct vector assignment or coercion.",
        .example = .{ .source =
        \\fn load(arr: [4]f32) @Vector(4, f32) {
        \\    return @as(@Vector(4, f32), .{ arr[0], arr[1], arr[2], arr[3] });
        \\}
        },
    },
    .{
        .rule = .prefer_vector_op,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports `@Vector` literal initializers that perform element-wise arithmetic on two vectors or arrays, recommending direct vector operators instead.",
        .example = .{ .source =
        \\fn add(a: @Vector(4, f32), b: @Vector(4, f32)) @Vector(4, f32) {
        \\    return @as(@Vector(4, f32), .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] });
        \\}
        },
    },
    .{
        .rule = .prefer_vector_reduce,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports serial lane-by-lane arithmetic or bitwise accumulations across vector or array lanes, recommending `@reduce`.",
        .example = .{ .source =
        \\fn sum(v: @Vector(4, u32)) u32 {
        \\    return v[0] + v[1] + v[2] + v[3];
        \\}
        },
    },
    .{
        .rule = .prefer_map_get_or_put,
        .tier = .style,
        .profile = .idiomatic,
        .summary = "Reports checking key presence via `map.contains(key)` or `map.get(key) == null` followed immediately by `map.put(key, value)`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn remember(map: *std.AutoHashMap(u32, u32), key: u32) !void {
        \\    if (!map.contains(key)) {
        \\        try map.put(key, 1);
        \\    }
        \\}
        },
    },
    .{
        .rule = .prefer_starts_with_scalar,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports calling `std.mem.startsWith` with a 1-character string literal (e.g. `\"-\"`, `\"/\"`, `\".\"`, `\"\\n\"`).",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn isFlag(arg: []const u8) bool {
        \\    return std.mem.startsWith(u8, arg, "-");
        \\}
        },
    },
    .{
        .rule = .prefer_ends_with_scalar,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports calling `std.mem.endsWith` with a 1-character string literal (e.g. `\"/\"`, `\".\"`, `\"\\n\"`).",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn isDir(path: []const u8) bool {
        \\    return std.mem.endsWith(u8, path, "/");
        \\}
        },
    },
    .{
        .rule = .prefer_write_byte,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports writing a single character via `writeAll` or `print`, recommending `writeByte` instead.",
        .example = .{ .source =
        \\fn newline(writer: anytype) !void {
        \\    try writer.writeAll("\n");
        \\}
        },
    },
    .{
        .rule = .prefer_simd_iota,
        .tier = .style,
        .profile = .idiomatic,
        .fixes = .fix_all,
        .summary = "Reports vector literals initialized with manually written sequential integers (`.{ 0, 1, 2, ... }`) instead of `std.simd.iota`.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\const lanes: @Vector(4, u32) = .{ 0, 1, 2, 3 };
        \\
        \\test "lanes" {
        \\    try std.testing.expectEqual(@as(u32, 3), lanes[3]);
        \\}
        },
    },
    .{
        .rule = .missing_container_deinit,
        .tier = .correctness,
        .fixes = .fix_all,
        .summary = "Reports local unmanaged containers that are mutated with allocating methods but have no visible `deinit`, slice conversion, or ownership transfer.",
        .example = .{ .source =
        \\const std = @import("std");
        \\
        \\fn collect(allocator: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    try list.append(allocator, 1);
        \\}
        },
    },
};
