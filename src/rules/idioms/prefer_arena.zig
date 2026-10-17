//! Scopes that make several allocations released by identical defers, which an arena frees at once.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const syntax_scope = @import("../../syntax/scope.zig");

pub const rules = [_]types.Rule{.prefer_arena};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_arena);
    if (level == .off) return;
    var scenarios = try failureScenarios(context);
    defer scenarios.deinit(context.allocator);
    var test_only: ?syntax_scope.TestOnlyBodies = null;
    defer if (test_only) |*bodies| bodies.deinit(context.allocator);
    for (context.tokens, 0..) |token, opening| {
        if (token.tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        var allocation_count: usize = 0;
        var cleanup_count: usize = 0;
        var allocator_name: ?[]const u8 = null;
        var allocator_index: usize = 0;
        var nested_depth: usize = 0;
        var has_direct_return = false;
        for (context.tokens[opening + 1 .. closing], opening + 1..) |body_token, index| {
            if (body_token.tag == .l_brace) {
                nested_depth += 1;
                continue;
            }
            if (body_token.tag == .r_brace) {
                nested_depth -|= 1;
                continue;
            }
            if (nested_depth != 0) continue;
            if (body_token.tag == .keyword_return) has_direct_return = true;
            if (body_token.tag != .identifier or index + 3 >= closing or context.tokens[index + 1].tag != .period or
                context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .l_paren) continue;
            const method = context.tokenText(index + 2);
            if (std.mem.eql(u8, method, "alloc") or std.mem.eql(u8, method, "create") or std.mem.eql(u8, method, "dupe")) {
                const candidate = context.tokenText(index);
                if (allocator_name == null) {
                    allocator_name = candidate;
                    allocator_index = index;
                }
                if (std.mem.eql(u8, allocator_name.?, candidate)) allocation_count += 1;
            }
            // An errdefer release keeps the allocation alive on success, which an arena would not.
            if ((std.mem.eql(u8, method, "free") or std.mem.eql(u8, method, "destroy")) and
                allocator_name != null and context.tokenIs(index, allocator_name.?) and index > opening + 1 and
                context.tokens[index - 1].tag == .keyword_defer) cleanup_count += 1;
        }
        if (allocation_count < 3 or cleanup_count < allocation_count or has_direct_return) continue;
        // Leak-checked tests release each allocation on purpose: one arena would hide a leak.
        if (context.scopes.insideTestBlock(opening + 1) or testingAllocator(context, allocator_index)) continue;
        if (scenarios.count() != 0) if (enclosingFunctionName(context, opening)) |name| {
            if (scenarios.contains(name)) continue;
        };
        if (test_only == null) test_only = try syntax_scope.testOnlyBodies(context.allocator, context.source, context.tokens);
        if (test_only.?.contains(opening)) continue;
        try context.emit(.{
            .rule = .prefer_arena,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("scope makes {d} allocations from '{s}' and releases all at exit; an ArenaAllocator can make that lifetime structural", .{ allocation_count, allocator_name.? }),
        });
    }
}

/// Names passed to `checkAllAllocationFailures`: those functions exist to fail
/// and release each allocation in turn, which one arena would hide.
fn failureScenarios(context: RuleRun) !std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    errdefer names.deinit(context.allocator);
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "checkAllAllocationFailures") or
            context.tokens[index + 1].tag != .l_paren) continue;
        const closing = context.scopes.matchingToken(index + 1) orelse continue;
        for (context.tokens[index + 2 .. closing], index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier) try names.put(context.allocator, context.tokenText(argument_index), {});
        }
    }
    return names;
}

/// Whether the allocator named at `index` is declared from `std.testing`'s
/// leak-checking or failing allocators.
fn testingAllocator(context: RuleRun, index: usize) bool {
    const binding = context.scopes.findBinding(index) orelse return false;
    const name = binding.token_index;
    if (name == 0 or (context.tokens[name - 1].tag != .keyword_const and context.tokens[name - 1].tag != .keyword_var)) return false;
    const end = context.statementEnd(name - 1) orelse return false;
    const declaration = context.source[context.tokens[name].loc.start..context.tokens[end].loc.start];
    const testing_allocators = [_][]const u8{ "testing.allocator", "failing_allocator", "FailingAllocator" };
    for (testing_allocators) |spelling| if (std.mem.find(u8, declaration, spelling) != null) return true;
    return false;
}

/// The name of the function whose body is or encloses the block at `opening`.
fn enclosingFunctionName(context: RuleRun, opening: usize) ?[]const u8 {
    const body = context.scopes.enclosingFunctionBody(opening + 1) orelse return null;
    var cursor = body;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .keyword_fn => return if (context.tokens[cursor + 1].tag == .identifier) context.tokenText(cursor + 1) else null,
            .keyword_test, .semicolon, .l_brace, .r_brace => return null,
            else => {},
        }
    }
    return null;
}

test "repeated allocations with identical defers report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(allocator: anytype) !void {\n" ++
        "const a = try allocator.alloc(u8, 1); defer allocator.free(a);\n" ++
        "const b = try allocator.alloc(u8, 1); defer allocator.free(b);\n" ++
        "const c = try allocator.alloc(u8, 1); defer allocator.free(c); }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_arena}, .information));
    try support.expectRules(found, &.{.prefer_arena});
}

test "failure-sweep scenarios and errdefer-released allocations are not arena candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scenario(allocator: std.mem.Allocator) !void {\n" ++
        "    const a = try allocator.alloc(u8, 1); defer allocator.free(a);\n" ++
        "    const b = try allocator.alloc(u8, 1); defer allocator.free(b);\n" ++
        "    const c = try allocator.alloc(u8, 1); defer allocator.free(c);\n" ++
        "}\n" ++
        "fn fill(owner: *Owner, allocator: std.mem.Allocator) !void {\n" ++
        "    owner.a = try allocator.alloc(u8, 1); errdefer allocator.free(owner.a);\n" ++
        "    owner.b = try allocator.alloc(u8, 1); errdefer allocator.free(owner.b);\n" ++
        "    owner.c = try allocator.alloc(u8, 1); errdefer allocator.free(owner.c);\n" ++
        "}\n" ++
        "test {\n" ++
        "    try std.testing.checkAllAllocationFailures(std.testing.allocator, scenario, .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_arena}, .information));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "leak-checked tests and testing allocators are not arena candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const a = std.testing.allocator;\n" ++
        "test \"leak checked\" {\n" ++
        "    const x = try std.testing.allocator.alloc(u8, 1); defer std.testing.allocator.free(x);\n" ++
        "    const y = try std.testing.allocator.alloc(u8, 1); defer std.testing.allocator.free(y);\n" ++
        "    const z = try std.testing.allocator.alloc(u8, 1); defer std.testing.allocator.free(z);\n" ++
        "}\n" ++
        "pub fn shared() !void {\n" ++
        "    const x = try a.alloc(u8, 1); defer a.free(x);\n" ++
        "    const y = try a.alloc(u8, 1); defer a.free(y);\n" ++
        "    const z = try a.alloc(u8, 1); defer a.free(z);\n" ++
        "}\n" ++
        "fn helper(gpa: std.mem.Allocator) !void {\n" ++
        "    const x = try gpa.alloc(u8, 1); defer gpa.free(x);\n" ++
        "    const y = try gpa.alloc(u8, 1); defer gpa.free(y);\n" ++
        "    const z = try gpa.alloc(u8, 1); defer gpa.free(z);\n" ++
        "}\n" ++
        "test {\n" ++
        "    try helper(a);\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_arena}, .information));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}
