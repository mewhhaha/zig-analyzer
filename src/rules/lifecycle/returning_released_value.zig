const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .returning_released_value,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.returning_released_value);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const release_method = releaseForAcquisition(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const deferred_release = findDeferredRelease(
            context,
            binding_name,
            release_method,
            declaration_end + 1,
            scope_end,
            scope_opening,
        ) orelse continue;

        for (context.tokens[deferred_release.statement_end + 1 .. scope_end], deferred_release.statement_end + 1..) |candidate, return_index| {
            if (candidate.tag != .keyword_return or return_index + 2 >= scope_end or
                context.tokens[return_index + 1].tag != .identifier or
                !context.tokenIs(return_index + 1, binding_name) or
                context.tokens[return_index + 2].tag != .semicolon or
                bindingShadowed(context, binding_name, declaration_index + 2, return_index)) continue;
            const related = try context.allocator.alloc(types.RelatedSpan, 1);
            related[0] = .{
                .span = context.tokens[deferred_release.method_index].loc,
                .message = try context.allocator.print(
                    "deferred {s} runs as this scope exits",
                    .{release_method},
                ),
            };
            try context.emit(.{
                .rule = .returning_released_value,
                .level = level,
                .span = context.tokens[return_index + 1].loc,
                .message = try context.allocator.print(
                    "returned value '{s}' is released by deferred {s} before the caller can use it",
                    .{ binding_name, release_method },
                ),
                .related = related,
            });
        }
    }
}

const DeferredRelease = struct {
    method_index: usize,
    statement_end: usize,
};

fn releaseForAcquisition(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const name = context.tokenText(index);
        if (resources.uniqueAllocationRelease(name)) |release| return release;
        const pair = resources.lookup(context.configuration, name, resources.callReceiver(context.source, context.tokens, index)) orelse continue;
        if (pair.kind != .managed) return pair.release;
    }
    return null;
}

fn findDeferredRelease(
    context: RuleRun,
    binding_name: []const u8,
    release_method: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?DeferredRelease {
    for (context.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_defer or context.enclosingOpeningBrace(defer_index) != scope_opening) continue;
        const statement_end = if (defer_index + 1 < end and context.tokens[defer_index + 1].tag == .l_brace)
            context.matchingToken(defer_index + 1, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(defer_index) orelse continue;
        for (context.tokens[defer_index + 1 .. statement_end], defer_index + 1..) |method, method_index| {
            if (method.tag != .identifier or !context.tokenIs(method_index, release_method) or
                !releaseReferencesBinding(context, binding_name, method_index, statement_end)) continue;
            if (containsTag(context.tokens, defer_index + 1, method_index, .keyword_if)) break;
            return .{ .method_index = method_index, .statement_end = statement_end };
        }
    }
    return null;
}

fn containsTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) bool {
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

fn releaseReferencesBinding(context: RuleRun, binding_name: []const u8, method_index: usize, end: usize) bool {
    if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and
        context.tokenIs(method_index - 2, binding_name)) return true;
    if (method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) return false;
    const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse return false;
    for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |argument, argument_index| {
        if (argument.tag == .identifier and context.tokenIs(argument_index, binding_name)) return true;
    }
    return false;
}

fn bindingShadowed(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if ((token.tag == .keyword_const or token.tag == .keyword_var) and index + 1 < end and
            context.tokenIs(index + 1, name)) return true;
        if (token.tag == .pipe and index + 1 < end and context.tokenIs(index + 1, name)) return true;
    }
    return false;
}

test "returning a deferred allocation or file reports the expired value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(allocator: anytype) ![]u8 { const value = try allocator.alloc(u8, 8); defer allocator.free(value); return value; }\n" ++
        "fn file(directory: anytype) !File { const opened = try directory.openFile(\"x\", .{}); defer opened.close(); return opened; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("value", source[findings[0].span.start..findings[0].span.end]);
    try std.testing.expectEqual(@as(usize, 1), findings[0].related.len);
}

test "ownership returns and error-only cleanup remain valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn owned(allocator: anytype) ![]u8 { const value = try allocator.alloc(u8, 8); errdefer allocator.free(value); return value; }\n" ++
        "fn length(allocator: anytype) !usize { const value = try allocator.alloc(u8, 8); defer allocator.free(value); return value.len; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a conditionally guarded defer can transfer ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(a: anytype) ![]u8 { var done = false; const value = try a.alloc(u8, 8); defer if (!done) a.free(value); done = true; return value; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a block-bodied defer still releases the returned value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(allocator: anytype) ![]u8 { const value = try allocator.alloc(u8, 8); defer { allocator.free(value); } return value; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("value", source[findings[0].span.start..findings[0].span.end]);
}

test "a declared resource pair reports returning a deferred release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const source: [:0]const u8 =
        "fn open() !Connection { const connection = try Db.open(); defer connection.close(); return connection; }";
    const declared = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    const builtin = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), builtin.len);
}
