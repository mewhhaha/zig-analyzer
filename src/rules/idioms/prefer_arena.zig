//! Scopes that make several allocations released by identical defers, which an arena frees at once.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{.prefer_arena};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_arena);
    if (level == .off) return;
    for (context.tokens, 0..) |token, opening| {
        if (token.tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        var allocation_count: usize = 0;
        var cleanup_count: usize = 0;
        var allocator_name: ?[]const u8 = null;
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
                if (allocator_name == null) allocator_name = candidate;
                if (std.mem.eql(u8, allocator_name.?, candidate)) allocation_count += 1;
            }
            if ((std.mem.eql(u8, method, "free") or std.mem.eql(u8, method, "destroy")) and
                allocator_name != null and context.tokenIs(index, allocator_name.?) and index > opening + 1 and
                (context.tokens[index - 1].tag == .keyword_defer or context.tokens[index - 1].tag == .keyword_errdefer)) cleanup_count += 1;
        }
        if (allocation_count < 3 or cleanup_count < allocation_count or has_direct_return) continue;
        try context.emit(.{
            .rule = .prefer_arena,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("scope makes {d} allocations from '{s}' and releases all at exit; an ArenaAllocator can make that lifetime structural", .{ allocation_count, allocator_name.? }),
        });
    }
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
