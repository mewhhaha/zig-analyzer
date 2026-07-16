const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

const Resource = struct { acquisition: []const u8, release: []const u8 };

const resources = [_]Resource{
    .{ .acquisition = "openFile", .release = "close" },
    .{ .acquisition = "createFile", .release = "close" },
    .{ .acquisition = "openDir", .release = "close" },
    .{ .acquisition = "openIterableDir", .release = "close" },
    .{ .acquisition = "spawn", .release = "join" },
    .{ .acquisition = "init", .release = "deinit" },
    .{ .acquisition = "initCapacity", .release = "deinit" },
};

pub fn run(context: RuleRun) !void {
    try findReassignedCleanupBindings(context);
    try findErrorOnlyResourceCleanup(context);
    try findUncheckedAllocationSizes(context);
}

fn findReassignedCleanupBindings(context: RuleRun) !void {
    const level = context.level(.defer_uses_reassigned_binding);
    if (level == .off) return;
    for (context.tokens, 0..) |token, defer_index| {
        if (token.tag != .keyword_defer) continue;
        const scope_opening = context.enclosingOpeningBrace(defer_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const defer_end = context.statementEnd(defer_index) orelse continue;
        const cleanup_binding = cleanupBinding(context, defer_index + 1, defer_end) orelse continue;
        for (context.tokens[defer_end + 1 .. scope_end], defer_end + 1..) |candidate, index| {
            if (candidate.tag != .identifier or !context.tokenIs(index, cleanup_binding) or index + 1 >= scope_end or
                context.tokens[index + 1].tag != .equal or context.enclosingOpeningBrace(index) != scope_opening) continue;
            const assignment_end = context.statementEnd(index) orelse continue;
            if (replacementConsumesOriginal(context, cleanup_binding, index + 2, assignment_end) or
                releasedBeforeReplacement(context, cleanup_binding, defer_end + 1, index)) continue;
            try context.emit(.{
                .rule = .defer_uses_reassigned_binding,
                .level = level,
                .span = candidate.loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "binding '{s}' is reassigned after deferred cleanup captures it; cleanup will target the replacement and may leak the original value",
                    .{cleanup_binding},
                ),
            });
            break;
        }
    }
}

fn replacementConsumesOriginal(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    var names_original = false;
    var calls_realloc = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, name)) names_original = true;
        if (context.tokenIs(index, "realloc")) calls_realloc = true;
    }
    return names_original and calls_realloc;
}

fn releasedBeforeReplacement(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    const methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach", "unlock" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        var cleanup_method = false;
        for (methods) |method| {
            if (context.tokenIs(index, method)) cleanup_method = true;
        }
        if (!cleanup_method) continue;
        if (index >= 2 and context.tokens[index - 1].tag == .period and context.tokenIs(index - 2, name)) return true;
        if (releaseReferencesBinding(context, name, index, end)) return true;
    }
    return false;
}

fn cleanupBinding(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    const methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach", "unlock" };
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier) continue;
        var cleanup_method = false;
        for (methods) |method| {
            if (context.tokenIs(method_index, method)) cleanup_method = true;
        }
        if (!cleanup_method) continue;
        if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and
            context.tokens[method_index - 2].tag == .identifier and
            (context.tokenIs(method_index, "close") or context.tokenIs(method_index, "deinit") or
                context.tokenIs(method_index, "join") or context.tokenIs(method_index, "detach") or
                context.tokenIs(method_index, "unlock")))
        {
            const receiver_index = method_index - 2;
            const capture_receiver = receiver_index > start and context.tokens[receiver_index - 1].tag == .pipe or
                receiver_index > start + 1 and context.tokens[receiver_index - 1].tag == .asterisk and
                    context.tokens[receiver_index - 2].tag == .pipe;
            if (!capture_receiver) return context.tokenText(receiver_index);
        }
        if (method_index + 2 >= end or context.tokens[method_index + 1].tag != .l_paren) continue;
        const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier) return context.tokenText(argument_index);
        }
    }
    return null;
}

fn findErrorOnlyResourceCleanup(context: RuleRun) !void {
    const level = context.level(.resource_cleanup_on_error_only);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const resource = acquiredResource(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        var error_cleanup = false;
        var normal_cleanup = false;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |_, index| {
            if (!context.tokenIs(index, resource.release)) continue;
            const statement_start = precedingStatementKeyword(context.tokens, index);
            if (!releaseReferencesBinding(context, binding_name, index, scope_end)) continue;
            if (statement_start == .keyword_errdefer) error_cleanup = true else normal_cleanup = true;
        }
        if (!error_cleanup or normal_cleanup or bindingTransferred(context, binding_name, declaration_end + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .resource_cleanup_on_error_only,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "resource '{s}' is cleaned up by errdefer only; a successful return leaves {s} unhandled unless ownership is transferred",
                .{ binding_name, resource.release },
            ),
        });
    }
}

fn bindingTransferred(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index > start and
            context.tokens[index - 1].tag == .equal) return true;
        if (token.tag == .keyword_return) {
            const return_end = context.statementEnd(index) orelse continue;
            for (context.tokens[index + 1 .. @min(return_end, end)], index + 1..) |return_token, return_index| {
                if (return_token.tag == .identifier and context.tokenIs(return_index, name)) return true;
            }
        }
    }
    return false;
}

fn acquiredResource(context: RuleRun, start: usize, end: usize) ?Resource {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        for (resources) |resource| {
            if (!context.tokenIs(index, resource.acquisition)) continue;
            if ((std.mem.eql(u8, resource.acquisition, "init") or std.mem.eql(u8, resource.acquisition, "initCapacity")) and
                !containsManagedType(context, start, index)) continue;
            return resource;
        }
    }
    return null;
}

fn containsManagedType(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "ArrayList", "ArrayHashMap", "AutoHashMap", "StringHashMap", "ArenaAllocator", "GeneralPurposeAllocator" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

fn precedingStatementKeyword(tokens: []const std.zig.Token, index: usize) std.zig.Token.Tag {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_defer, .keyword_errdefer => return tokens[cursor].tag,
            .semicolon, .l_brace, .r_brace => return .invalid,
            else => {},
        }
    }
    return .invalid;
}

fn releaseReferencesBinding(context: RuleRun, name: []const u8, method_index: usize, end: usize) bool {
    if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and context.tokenIs(method_index - 2, name)) return true;
    if (method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) return false;
    const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse return false;
    for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn findUncheckedAllocationSizes(context: RuleRun) !void {
    const level = context.level(.allocation_size_overflow);
    if (level == .off) return;
    const Method = struct { name: []const u8, length_from_end: usize = 1 };
    const methods = [_]Method{
        .{ .name = "alloc" },
        .{ .name = "allocSentinel", .length_from_end = 2 },
        .{ .name = "alignedAlloc" },
        .{ .name = "realloc" },
    };
    for (context.tokens, 0..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= context.tokens.len or context.tokens[method_index + 1].tag != .l_paren) continue;
        var allocation_method: ?Method = null;
        for (methods) |method| {
            if (context.tokenIs(method_index, method.name)) allocation_method = method;
        }
        const method = allocation_method orelse continue;
        const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        const length = argumentFromEnd(context.tokens, method_index + 2, closing, method.length_from_end) orelse continue;
        var has_multiplication = false;
        var has_runtime_name = false;
        for (context.tokens[length.start..length.end], length.start..) |argument_token, argument_index| {
            if (argument_token.tag == .asterisk) has_multiplication = true;
            if (argument_token.tag == .identifier and identifierIsRuntimeBound(context, argument_index, method_index)) {
                has_runtime_name = true;
            }
        }
        if (!has_multiplication or !has_runtime_name) continue;
        try context.emit(.{
            .rule = .allocation_size_overflow,
            .level = level,
            .span = context.tokens[length.start].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "allocation length passed to {s} uses unchecked runtime multiplication; validate overflow before allocating",
                .{context.tokenText(method_index)},
            ),
        });
    }
}

const ArgumentRange = struct { start: usize, end: usize };

fn argumentFromEnd(tokens: []const std.zig.Token, start: usize, end: usize, from_end: usize) ?ArgumentRange {
    var arguments: [8]ArgumentRange = undefined;
    var argument_count: usize = 0;
    var depth: usize = 0;
    var argument_start = start;
    for (tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (argument_count == arguments.len) return null;
                arguments[argument_count] = .{ .start = argument_start, .end = index };
                argument_count += 1;
                argument_start = index + 1;
            },
            else => {},
        }
    }
    if (argument_start < end) {
        if (argument_count == arguments.len) return null;
        arguments[argument_count] = .{ .start = argument_start, .end = end };
        argument_count += 1;
    }
    if (from_end == 0 or from_end > argument_count) return null;
    return arguments[argument_count - from_end];
}

fn identifierIsRuntimeBound(context: RuleRun, identifier_index: usize, use_index: usize) bool {
    const body_start = containingRuntimeBodyStart(context, use_index) orelse return false;
    const name = context.tokenText(identifier_index);
    for (context.tokens[body_start + 1 .. use_index], body_start + 1..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > body_start + 1 and
            (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var)) return true;
        if (index > body_start and context.tokens[index - 1].tag == .pipe) return true;
        if (index > body_start + 1 and context.tokens[index - 1].tag == .asterisk and context.tokens[index - 2].tag == .pipe) return true;
    }

    var cursor = body_start;
    while (cursor > 0 and context.tokens[cursor].tag != .keyword_fn) : (cursor -= 1) {}
    if (context.tokens[cursor].tag != .keyword_fn) return false;
    for (context.tokens[cursor..body_start], cursor..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < body_start and
            context.tokens[index + 1].tag == .colon) return true;
    }
    return false;
}

fn containingRuntimeBodyStart(context: RuleRun, use_index: usize) ?usize {
    var candidate: ?usize = null;
    for (context.tokens[0..use_index], 0..) |token, index| {
        if (token.tag != .keyword_fn and token.tag != .keyword_test) continue;
        for (context.tokens[index + 1 .. use_index], index + 1..) |following, body_start| {
            if (following.tag != .l_brace) continue;
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse break;
            if (body_end > use_index) candidate = body_start;
            break;
        }
    }
    return candidate;
}

test "cleanup lifetime and allocation size mistakes warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize) !void { var file = try a.openFile(\"x\", .{}); errdefer file.close(); var bytes = try a.alloc(u8, count * 4); defer a.free(bytes); bytes = try a.alloc(u8, 2); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 3), findings.items.len);
}

test "realloc transfers the original allocation into the replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype) !void { var bytes = try a.alloc(u8, 1); defer a.free(bytes); bytes = try a.realloc(bytes, 2); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "constant allocation products are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "const KiB = 1024; fn run(a: anytype) !void { const bytes = try a.alloc(u8, 64 * KiB); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "allocSentinel checks the length rather than the sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize) !void { const bytes = try a.allocSentinel(u8, count * 2, 0); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.allocation_size_overflow, findings.items[0].rule);
}

test "defer loop captures do not bind later declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(values: anytype) !void { defer for (values) |*it| it.close(); var it = try Iterator.init(); defer it.close(); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
