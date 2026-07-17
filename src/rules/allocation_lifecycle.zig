const std = @import("std");
const syntax_scope = @import("../syntax_scope.zig");
const types = @import("types.zig");
const tokenRefersToBinding = @import("context.zig").tokenRefersToBinding;

pub const Warning = struct {
    rule: types.Rule,
    span: std.zig.Token.Loc,
    message: []const u8,
    fixes: []const types.Fix = &.{},
};

pub const rules = [_]types.Rule{
    .unreleased_allocation,
    .cleanup_after_fallible_operation,
    .mismatched_allocation_release,
    .double_release,
    .use_after_release,
    .overwritten_owning_value,
};

pub fn enabled(configuration: types.Configuration) bool {
    for (rules) |rule| if (configuration.level(rule) != .off) return true;
    return false;
}

pub fn warnings(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) ![]Warning {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var scope_index = try syntax_scope.Index.init(allocator, source, tokens);
    defer scope_index.deinit();
    return warningsWithSyntax(allocator, source, &tree, tokens, &scope_index);
}

pub fn warningsWithSyntax(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
) ![]Warning {
    var found: std.ArrayList(Warning) = .empty;
    errdefer {
        for (found.items) |warning| freeWarning(allocator, warning);
        found.deinit(allocator);
    }

    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const declaration = tree.fullVarDecl(node) orelse continue;
        const initializer = declaration.ast.init_node.unwrap() orelse continue;
        const declaration_index: usize = declaration.ast.mut_token;
        if (declaration_index + 2 >= tokens.len) continue;
        const binding_index = declaration_index + 1;
        if (tokens[binding_index].tag != .identifier) continue;
        const binding_name = source[tokens[binding_index].loc.start..tokens[binding_index].loc.end];
        if (std.mem.eql(u8, binding_name, "_")) continue;
        const statement_end = findStatementEnd(tokens, declaration_index) orelse continue;
        const allocation = allocationFromValue(tree, initializer) orelse continue;
        if (allocation.allocator_source) |allocator_name| {
            if (allocatorIsArenaBacked(source, tokens, allocator_name)) continue;
        }
        const scope_end = enclosingScopeEnd(tokens, declaration_index) orelse continue;
        if (statement_end >= scope_end) continue;
        const mismatched_release = try findMismatchedRelease(
            allocator,
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            statement_end + 1,
            scope_end,
            allocation,
            &found,
        );
        try findReleaseOrderingIssues(
            allocator,
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            declaration_index,
            statement_end,
            scope_end,
            allocation,
            &found,
        );
        const cleanup = ownershipLeavesScope(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            statement_end + 1,
            scope_end,
            allocation.release,
        );
        if (cleanup == .released or mismatched_release) continue;
        // 'defer pool.deinit(...)' reclaims everything the pool handed out.
        if (allocation.receiver) |receiver_name| {
            if (deferDeinitializesReceiver(source, tokens, receiver_name, declaration_index, scope_end)) continue;
        }

        const message = switch (cleanup) {
            .released => unreachable,
            .errdefer_only => try std.fmt.allocPrint(
                allocator,
                "allocation '{s}' from {s} is released by errdefer only; the success path has no visible {s} or ownership return",
                .{ binding_name, allocation.method, allocation.release },
            ),
            .missing => try std.fmt.allocPrint(
                allocator,
                "allocation '{s}' from {s} has no visible {s} or ownership return before leaving this scope",
                .{ binding_name, allocation.method, allocation.release },
            ),
        };
        errdefer allocator.free(message);
        try found.append(allocator, .{
            .rule = .unreleased_allocation,
            .span = tokens[binding_index].loc,
            .message = message,
        });
    }
    return try found.toOwnedSlice(allocator);
}

const Allocation = struct {
    method: []const u8,
    release: []const u8,
    receiver: ?[]const u8,
    allocator_source: ?[]const u8,
};

fn allocationFromValue(tree: *const std.zig.Ast, value: std.zig.Ast.Node.Index) ?Allocation {
    return switch (tree.nodeTag(value)) {
        .@"try", .@"nosuspend", .@"comptime" => allocationFromValue(tree, tree.nodeData(value).node),
        .grouped_expression => allocationFromValue(tree, tree.nodeData(value).node_and_token[0]),
        .@"catch" => allocationFromValue(tree, tree.nodeData(value).node_and_node[0]),
        .@"orelse" => allocationFromValue(tree, tree.nodeData(value).node_and_node[0]) orelse
            allocationFromValue(tree, tree.nodeData(value).node_and_node[1]),
        .block_two, .block_two_semicolon, .block, .block_semicolon => allocationFromBlock(tree, value),
        .call, .call_comma, .call_one, .call_one_comma => allocationFromCall(tree, value),
        else => null,
    };
}

fn allocationFromBlock(tree: *const std.zig.Ast, block: std.zig.Ast.Node.Index) ?Allocation {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return null;
    for (statements) |statement| {
        if (tree.nodeTag(statement) != .@"break") continue;
        const break_value = tree.nodeData(statement).opt_token_and_opt_node[1].unwrap() orelse continue;
        if (allocationFromValue(tree, break_value)) |allocation| return allocation;
    }
    return null;
}

fn allocationFromCall(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?Allocation {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
    const method = tree.tokenSlice(method_token);
    const release = allocationRelease(method) orelse return null;
    if (expressionReferencesField(tree, receiver, "arena")) return null;
    if (std.mem.eql(u8, release, "free") and !expressionLooksLikeAllocator(tree, receiver)) return null;
    return .{
        .method = method,
        .release = release,
        .receiver = if (tree.nodeTag(receiver) == .identifier) tree.tokenSlice(tree.nodeMainToken(receiver)) else null,
        .allocator_source = allocatorSourceName(tree, receiver),
    };
}

fn expressionLooksLikeAllocator(tree: *const std.zig.Ast, expression: std.zig.Ast.Node.Index) bool {
    return switch (tree.nodeTag(expression)) {
        .identifier => true,
        .field_access => field: {
            const field_token = tree.nodeData(expression).node_and_token[1];
            const field_name = tree.tokenSlice(field_token);
            break :field std.mem.eql(u8, field_name, "allocator") or std.mem.eql(u8, field_name, "gpa");
        },
        .call, .call_comma, .call_one, .call_one_comma => call: {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const full_call = tree.fullCall(&buffer, expression) orelse break :call false;
            if (tree.nodeTag(full_call.ast.fn_expr) != .field_access) break :call false;
            const field_token = tree.nodeData(full_call.ast.fn_expr).node_and_token[1];
            break :call std.mem.eql(u8, tree.tokenSlice(field_token), "allocator");
        },
        else => false,
    };
}

fn allocatorSourceName(tree: *const std.zig.Ast, receiver: std.zig.Ast.Node.Index) ?[]const u8 {
    switch (tree.nodeTag(receiver)) {
        .identifier => return tree.tokenSlice(tree.nodeMainToken(receiver)),
        .call, .call_comma, .call_one, .call_one_comma => {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, receiver) orelse return null;
            if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
            const base, const field_token = tree.nodeData(call.ast.fn_expr).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(field_token), "allocator")) return null;
            if (tree.nodeTag(base) != .identifier) return null;
            return tree.tokenSlice(tree.nodeMainToken(base));
        },
        else => return null,
    }
}

const arena_backed_types = [_][]const u8{ "ArenaAllocator", "FixedBufferAllocator" };

fn allocatorIsArenaBacked(source: []const u8, tokens: []const std.zig.Token, allocator_name: []const u8) bool {
    var name = allocator_name;
    var hops: usize = 0;
    while (hops < 4) : (hops += 1) {
        const declaration = bindingDeclarationValue(source, tokens, name) orelse return false;
        for (tokens[declaration.start..declaration.end]) |token| {
            if (token.tag != .identifier) continue;
            const text = source[token.loc.start..token.loc.end];
            for (arena_backed_types) |arena_type| if (std.mem.eql(u8, text, arena_type)) return true;
        }
        name = allocatorCallReceiver(source, tokens, declaration) orelse return false;
    }
    return false;
}

const TokenRange = struct { start: usize, end: usize };

fn bindingDeclarationValue(source: []const u8, tokens: []const std.zig.Token, name: []const u8) ?TokenRange {
    for (tokens, 0..) |token, index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or index + 2 >= tokens.len or
            !tokenIsIdentifier(source, tokens[index + 1], name)) continue;
        const end = findStatementEnd(tokens, index) orelse continue;
        return .{ .start = index + 2, .end = end };
    }
    return null;
}

fn allocatorCallReceiver(source: []const u8, tokens: []const std.zig.Token, range: TokenRange) ?[]const u8 {
    var index = range.start;
    while (index + 3 < range.end) : (index += 1) {
        if (tokens[index].tag == .identifier and tokens[index + 1].tag == .period and
            tokenIsIdentifier(source, tokens[index + 2], "allocator") and tokens[index + 3].tag == .l_paren)
            return source[tokens[index].loc.start..tokens[index].loc.end];
    }
    return null;
}

fn expressionReferencesField(
    tree: *const std.zig.Ast,
    expression: std.zig.Ast.Node.Index,
    field_name: []const u8,
) bool {
    return switch (tree.nodeTag(expression)) {
        .identifier => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(expression)), field_name),
        .field_access => field: {
            const receiver, const field_token = tree.nodeData(expression).node_and_token;
            if (std.mem.eql(u8, tree.tokenSlice(field_token), field_name)) break :field true;
            break :field expressionReferencesField(tree, receiver, field_name);
        },
        .call, .call_comma, .call_one, .call_one_comma => call: {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, expression) orelse break :call false;
            break :call expressionReferencesField(tree, call.ast.fn_expr, field_name);
        },
        .grouped_expression => expressionReferencesField(tree, tree.nodeData(expression).node_and_token[0], field_name),
        else => false,
    };
}

fn allocationRelease(method: []const u8) ?[]const u8 {
    const free_methods = [_][]const u8{
        "alloc",
        "allocSentinel",
        "alignedAlloc",
        "dupe",
        "dupeZ",
        "realloc",
    };
    for (free_methods) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return "free";
    }
    if (std.mem.eql(u8, method, "create")) return "destroy";
    return null;
}

fn findMismatchedRelease(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    allocation: Allocation,
    found: *std.ArrayList(Warning),
) !bool {
    var mismatched = false;
    for (tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIsIdentifier(source, token, "free") and !tokenIsIdentifier(source, token, "destroy"))) continue;
        if (!releaseCallContainsBinding(source, tokens, scope_index, binding_name, binding_index, method_index, end)) continue;
        const actual_release = source[token.loc.start..token.loc.end];
        const receiver_is_binding = method_index >= 2 and
            tokenIsIdentifier(source, tokens[method_index - 2], binding_name) and
            identifierRefersToBinding(scope_index, binding_index, method_index - 2);
        const receiver_name = if (method_index >= 2 and tokens[method_index - 2].tag == .identifier)
            source[tokens[method_index - 2].loc.start..tokens[method_index - 2].loc.end]
        else
            null;
        const wrong_method = !std.mem.eql(u8, actual_release, allocation.release);
        const wrong_allocator = !receiver_is_binding and allocation.receiver != null and receiver_name != null and
            !std.mem.eql(u8, allocation.receiver.?, receiver_name.?);
        if (!wrong_method and !wrong_allocator) continue;
        mismatched = true;
        const message = if (wrong_method)
            try std.fmt.allocPrint(
                allocator,
                "allocation '{s}' from {s} must use {s}, not {s}",
                .{ binding_name, allocation.method, allocation.release, actual_release },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "allocation '{s}' created by allocator '{s}' is released through different allocator '{s}'",
                .{ binding_name, allocation.receiver.?, receiver_name.? },
            );
        try found.append(allocator, .{
            .rule = .mismatched_allocation_release,
            .span = token.loc,
            .message = message,
        });
    }
    return mismatched;
}

fn findReleaseOrderingIssues(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    declaration_index: usize,
    declaration_end: usize,
    scope_end: usize,
    allocation: Allocation,
    found: *std.ArrayList(Warning),
) !void {
    const declaration_scope = enclosingScope(tokens, declaration_index) orelse return;
    var releases: std.ArrayList(usize) = .empty;
    defer releases.deinit(allocator);
    for (tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |token, method_index| {
        if (!tokenIsIdentifier(source, token, allocation.release) or
            !releaseCallContainsBinding(source, tokens, scope_index, binding_name, binding_index, method_index, scope_end)) continue;
        const release_scope = enclosingScope(tokens, method_index) orelse continue;
        if (release_scope.opening != declaration_scope.opening) continue;
        if (!releaseUsesAllocationReceiver(source, tokens, scope_index, binding_name, binding_index, method_index, allocation.receiver)) continue;
        try releases.append(allocator, method_index);
    }

    if (releases.items.len != 0) {
        const first_release = releases.items[0];
        if (statementStartsWith(tokens, first_release, .keyword_defer) and
            fallibleOperationBetween(tokens, declaration_end + 1, first_release, declaration_scope.opening))
        {
            try found.append(allocator, .{
                .rule = .cleanup_after_fallible_operation,
                .span = tokens[binding_index].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "cleanup for allocation '{s}' is registered after a fallible operation; an earlier error can leak it",
                    .{binding_name},
                ),
            });
        }
        for (releases.items[1..]) |release_index| {
            try found.append(allocator, .{
                .rule = .double_release,
                .span = tokens[release_index].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "allocation '{s}' has more than one visible {s} in the same control-flow scope",
                    .{ binding_name, allocation.release },
                ),
                .fixes = try releaseDeletionFix(allocator, tokens, release_index),
            });
        }
        if (!statementStartsWith(tokens, first_release, .keyword_defer) and
            !statementStartsWith(tokens, first_release, .keyword_errdefer))
        {
            const release_end = findStatementEnd(tokens, first_release) orelse first_release;
            if (firstUseAfterRelease(source, tokens, scope_index, binding_name, binding_index, release_end + 1, scope_end, releases.items)) |use_index| {
                try found.append(allocator, .{
                    .rule = .use_after_release,
                    .span = tokens[use_index].loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "allocation '{s}' is used after its visible {s}",
                        .{ binding_name, allocation.release },
                    ),
                });
            }
        }
    }

    const before_release = if (releases.items.len == 0) scope_end else releases.items[0];
    if (owningAssignment(source, tokens, scope_index, binding_name, binding_index, declaration_end + 1, before_release)) |assignment_index| {
        try found.append(allocator, .{
            .rule = .overwritten_owning_value,
            .span = tokens[assignment_index].loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "assignment replaces owning value '{s}' before its original allocation is released",
                .{binding_name},
            ),
        });
    }
}

fn releaseDeletionFix(
    allocator: std.mem.Allocator,
    tokens: []const std.zig.Token,
    release_index: usize,
) ![]const types.Fix {
    var statement_start = release_index;
    while (statement_start > 0) {
        switch (tokens[statement_start - 1].tag) {
            .semicolon, .l_brace, .r_brace => break,
            else => statement_start -= 1,
        }
    }
    const statement_end = findStatementEnd(tokens, release_index) orelse release_index;
    const edits = try allocator.alloc(types.Edit, 1);
    errdefer allocator.free(edits);
    edits[0] = .{
        .span = .{ .start = tokens[statement_start].loc.start, .end = tokens[statement_end].loc.end },
        .replacement = "",
    };
    const fixes = try allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = "Delete the duplicate release", .kind = .quickfix, .edits = edits };
    return fixes;
}

fn releaseCallContainsBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    method_index: usize,
    end: usize,
) bool {
    if (method_index == 0 or method_index + 1 >= end or tokens[method_index - 1].tag != .period or
        tokens[method_index + 1].tag != .l_paren) return false;
    const closing = matchingToken(tokens, method_index + 1, .l_paren, .r_paren) orelse return false;
    if (closing >= end) return false;
    const receiver_is_binding = method_index >= 2 and
        tokenIsIdentifier(source, tokens[method_index - 2], binding_name) and
        identifierRefersToBinding(scope_index, binding_index, method_index - 2);
    return receiver_is_binding or releaseArgumentContainsBinding(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        method_index + 2,
        closing,
    );
}

fn releaseArgumentContainsBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    for (start..end) |index| {
        if (!tokenRefersToBinding(source, tokens, index, binding_name) or
            !identifierRefersToBinding(scope_index, binding_index, index)) continue;
        if (index + 1 < end and (tokens[index + 1].tag == .period or tokens[index + 1].tag == .l_bracket)) continue;
        return true;
    }
    return false;
}

fn releaseUsesAllocationReceiver(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    method_index: usize,
    allocation_receiver: ?[]const u8,
) bool {
    if (method_index < 2 or tokens[method_index - 2].tag != .identifier) return allocation_receiver == null;
    if (tokenIsIdentifier(source, tokens[method_index - 2], binding_name) and
        identifierRefersToBinding(scope_index, binding_index, method_index - 2)) return true;
    const expected_receiver = allocation_receiver orelse return true;
    return tokenIsIdentifier(source, tokens[method_index - 2], expected_receiver);
}

fn statementStartsWith(tokens: []const std.zig.Token, index: usize, expected: std.zig.Token.Tag) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .semicolon, .l_brace, .r_brace => return false,
            else => if (tokens[cursor].tag == expected) return true,
        }
    }
    return false;
}

fn fallibleOperationBetween(
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
    scope_opening: usize,
) bool {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_try) continue;
        const scope = enclosingScope(tokens, index) orelse continue;
        if (scope.opening == scope_opening) return true;
    }
    return false;
}

fn firstUseAfterRelease(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    release_indices: []const usize,
) ?usize {
    const declaration_scope = enclosingScope(tokens, binding_index) orelse return null;
    for (start..end) |index| {
        if (!tokenRefersToBinding(source, tokens, index, binding_name) or
            !identifierRefersToBinding(scope_index, binding_index, index)) continue;
        const use_scope = enclosingScope(tokens, index) orelse continue;
        if (use_scope.opening != declaration_scope.opening) continue;
        var belongs_to_release = false;
        for (release_indices) |release_index| {
            const closing = if (release_index + 1 < tokens.len and tokens[release_index + 1].tag == .l_paren)
                matchingToken(tokens, release_index + 1, .l_paren, .r_paren)
            else
                null;
            if (closing) |closing_index| if (index >= release_index -| 2 and index <= closing_index) {
                belongs_to_release = true;
                break;
            };
        }
        if (belongs_to_release) continue;
        if (index + 1 < tokens.len and tokens[index + 1].tag == .equal) return null;
        return index;
    }
    return null;
}

fn owningAssignment(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    const declaration_scope = enclosingScope(tokens, binding_index) orelse return null;
    var index = start;
    while (index + 2 < end) : (index += 1) {
        if (!tokenIsIdentifier(source, tokens[index], binding_name) or
            !identifierRefersToBinding(scope_index, binding_index, index) or
            tokens[index + 1].tag != .equal) continue;
        const assignment_scope = enclosingScope(tokens, index) orelse continue;
        if (assignment_scope.opening != declaration_scope.opening) continue;
        const statement_end = findStatementEnd(tokens, index) orelse continue;
        const value_end = @min(statement_end, end);
        var replaces_with_allocation = false;
        var realloc_consumes_original = false;
        for (tokens[index + 2 .. value_end], index + 2..) |rhs_token, rhs_index| {
            if (rhs_token.tag != .identifier) continue;
            const method = source[rhs_token.loc.start..rhs_token.loc.end];
            if (allocationRelease(method) == null) continue;
            replaces_with_allocation = true;
            if (!std.mem.eql(u8, method, "realloc") or rhs_index + 1 >= tokens.len or
                tokens[rhs_index + 1].tag != .l_paren) continue;
            const closing = matchingToken(tokens, rhs_index + 1, .l_paren, .r_paren) orelse continue;
            if (containsBinding(source, tokens, scope_index, binding_name, binding_index, rhs_index + 2, @min(closing, value_end))) {
                realloc_consumes_original = true;
            }
        }
        if (replaces_with_allocation and !realloc_consumes_original) return index;
    }
    return null;
}

const Cleanup = enum { released, errdefer_only, missing };

fn ownershipLeavesScope(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    release_method: []const u8,
) Cleanup {
    var found_errdefer = false;
    for (tokens[start..end], start..) |token, index| {
        if ((token.tag == .keyword_return or token.tag == .keyword_break) and
            controlFlowValueContainsBinding(source, tokens, scope_index, binding_name, binding_index, index + 1, end)) return .released;
        if (token.tag != .identifier or !std.mem.eql(u8, source[token.loc.start..token.loc.end], release_method)) continue;
        if (index == 0 or index + 2 >= end or tokens[index - 1].tag != .period or tokens[index + 1].tag != .l_paren) {
            continue;
        }
        const closing_parenthesis = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
        if (closing_parenthesis >= end) continue;
        const receiver_is_binding = index >= 2 and tokenIsIdentifier(source, tokens[index - 2], binding_name) and
            identifierRefersToBinding(scope_index, binding_index, index - 2);
        const argument_contains_binding = releaseArgumentContainsBinding(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            index + 2,
            closing_parenthesis,
        );
        if (!receiver_is_binding and !argument_contains_binding) continue;
        if (!statementStartsWithErrdefer(tokens, index)) return .released;
        found_errdefer = true;
    }
    if (bindingEscapes(source, tokens, scope_index, binding_name, binding_index, start, end, release_method)) return .released;
    return if (found_errdefer) .errdefer_only else .missing;
}

fn controlFlowValueContainsBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    scope_end: usize,
) bool {
    var end = start;
    while (end < scope_end and tokens[end].tag != .semicolon and tokens[end].tag != .r_brace) : (end += 1) {}
    return containsBinding(source, tokens, scope_index, binding_name, binding_index, start, end);
}

fn containsBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    for (tokens[start..end], start..) |token, index| {
        if (tokenIsIdentifier(source, token, binding_name) and
            identifierRefersToBinding(scope_index, binding_index, index)) return true;
    }
    return false;
}

fn bindingEscapes(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    release_method: []const u8,
) bool {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag == .l_paren and index > 0 and
            (tokens[index - 1].tag == .identifier or tokens[index - 1].tag == .builtin))
        {
            const closing = matchingToken(tokens, index, .l_paren, .r_paren) orelse continue;
            if (closing >= end or !containsBinding(source, tokens, scope_index, binding_name, binding_index, index + 1, closing)) continue;
            const method = source[tokens[index - 1].loc.start..tokens[index - 1].loc.end];
            if (!std.mem.eql(u8, method, release_method)) return true;
        }
        if (token.tag != .equal) continue;
        const statement_end = findStatementEnd(tokens, index) orelse continue;
        if (statement_end >= end or
            !containsBinding(source, tokens, scope_index, binding_name, binding_index, index + 1, statement_end) or
            assignmentDiscards(source, tokens, start, index)) continue;
        return true;
    }
    return false;
}

fn assignmentDiscards(
    source: []const u8,
    tokens: []const std.zig.Token,
    range_start: usize,
    equal_index: usize,
) bool {
    var start = equal_index;
    while (start > range_start) {
        const previous = tokens[start - 1].tag;
        if (previous == .semicolon or previous == .l_brace or previous == .r_brace) break;
        start -= 1;
    }
    return equal_index == start + 1 and tokenIsIdentifier(source, tokens[start], "_");
}

fn identifierRefersToBinding(
    scope_index: *const syntax_scope.Index,
    binding_index: usize,
    use_index: usize,
) bool {
    const binding = scope_index.findBinding(use_index) orelse return false;
    return binding.token_index == binding_index;
}

fn statementStartsWithErrdefer(tokens: []const std.zig.Token, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_errdefer => return true,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn deferDeinitializesReceiver(
    source: []const u8,
    tokens: []const std.zig.Token,
    receiver_name: []const u8,
    declaration_index: usize,
    scope_end: usize,
) bool {
    const scope = enclosingScope(tokens, declaration_index) orelse return false;
    var index = scope.opening + 1;
    while (index + 3 < scope_end) : (index += 1) {
        // Only 'defer' releases on the success path; 'errdefer' alone still
        // leaks when the function succeeds.
        if (tokens[index].tag != .keyword_defer) continue;
        const body_end = if (tokens[index + 1].tag == .l_brace)
            matchingToken(tokens, index + 1, .l_brace, .r_brace) orelse scope_end
        else
            findStatementEnd(tokens, index + 1) orelse scope_end;
        var body_index = index + 1;
        while (body_index + 2 < @min(body_end, scope_end)) : (body_index += 1) {
            if (tokens[body_index].tag == .identifier and
                tokenIsIdentifier(source, tokens[body_index], receiver_name) and
                tokens[body_index + 1].tag == .period and
                tokenIsIdentifier(source, tokens[body_index + 2], "deinit")) return true;
        }
        index = @min(body_end, scope_end - 1);
    }
    return false;
}

fn tokenIsIdentifier(source: []const u8, token: std.zig.Token, name: []const u8) bool {
    return token.tag == .identifier and std.mem.eql(u8, source[token.loc.start..token.loc.end], name);
}

fn findStatementEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
            else => {},
        }
    }
    return null;
}

fn matchingToken(
    tokens: []const std.zig.Token,
    opening_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    for (tokens[opening_index..], opening_index..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

const Scope = struct {
    opening: usize,
    closing: usize,
};

fn enclosingScopeEnd(tokens: []const std.zig.Token, index: usize) ?usize {
    return (enclosingScope(tokens, index) orelse return null).closing;
}

fn enclosingScope(tokens: []const std.zig.Token, index: usize) ?Scope {
    var depth: usize = 0;
    var cursor = index;
    const opening_index = while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) break cursor;
                depth -= 1;
            },
            else => {},
        }
    } else return null;

    depth = 0;
    for (tokens[opening_index..], opening_index..) |token, closing_index| {
        if (token.tag == .l_brace) depth += 1;
        if (token.tag != .r_brace) continue;
        depth -= 1;
        if (depth == 0) return .{ .opening = opening_index, .closing = closing_index };
    }
    return null;
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    errdefer tokens.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    return try tokens.toOwnedSlice(allocator);
}

test "warns when an allocation has no release" {
    const source = "fn leak(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); _ = buffer; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(std.mem.indexOf(u8, found[0].message, "buffer") != null);
}

test "accepts deferred and explicit releases" {
    const source =
        "fn clean(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16); defer allocator.free(buffer);" ++
        "const node = try allocator.create(u32); allocator.destroy(node); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a deferred pool deinit reclaims the pool's allocations" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "var pool: MemoryPool = .empty;" ++
        "defer pool.deinit(a);" ++
        "const first = try pool.create(a);" ++
        "const second = try pool.create(a);" ++
        "_ = first; _ = second; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an errdefer pool deinit alone still warns about the success path" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "var pool: MemoryPool = .empty;" ++
        "errdefer pool.deinit(a);" ++
        "const first = try pool.create(a);" ++
        "_ = first; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "errdefer alone still warns about the success path" {
    const source = "fn leak(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); errdefer allocator.free(buffer); _ = buffer; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "returning an allocation transfers ownership" {
    const source = "fn owned(allocator: std.mem.Allocator) ![]u8 { const buffer = try allocator.dupe(u8, \"zig\"); return normalize(buffer); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "container declarations do not inherit allocations from their methods" {
    const source =
        "const AOF = struct {" ++
        "pub const ReplayClient = struct {" ++
        "client: *Client," ++
        "fn init(allocator: std.mem.Allocator) !ReplayClient {" ++
        "const client = try allocator.create(Client);" ++
        "errdefer allocator.destroy(client);" ++
        "return .{ .client = client };" ++
        "}" ++
        "fn deinit(self: *ReplayClient, allocator: std.mem.Allocator) void { allocator.destroy(self.client); }" ++
        "};" ++
        "};";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "storing an allocation in an owner transfers ownership" {
    const source =
        "fn attach(self: *Owner, allocator: std.mem.Allocator) !void {" ++
        "const client = try allocator.create(Client);" ++
        "self.client = client;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "passing an allocation to an unknown call is treated as an escape" {
    const source =
        "fn attach(allocator: std.mem.Allocator) !void {" ++
        "const client = try allocator.create(Client);" ++
        "register(client);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "breaking an allocation from a labeled block transfers ownership" {
    const source =
        "fn attach(allocator: std.mem.Allocator) !*Client {" ++
        "return owner: {" ++
        "const client = try allocator.create(Client);" ++
        "break :owner client;" ++
        "};" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an owned allocation may clean itself up" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const shell = try Shell.create(allocator);" ++
        "defer shell.destroy();" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "arena allocations inherit the arena lifetime" {
    const source =
        "fn run(shell: *Shell) !void {" ++
        "const children = try shell.arena.allocator().alloc(u8, 16);" ++
        "_ = children;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "cleanup of a shadowing binding does not release the allocation" {
    const source =
        "fn leak(allocator: std.mem.Allocator, other: *Client) !void {" ++
        "const client = try allocator.create(Client);" ++
        "{ const client = other; allocator.destroy(client); }" ++
        "_ = client;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "release may wrap the owned pointer" {
    const source = "fn clean(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); defer allocator.free(@constCast(buffer)); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "nested labeled allocation expressions do not cross their enclosing scope" {
    const source =
        "fn resolve(b: anytype, existing: ?[]u8) void {" ++
        "const sha = existing orelse fetch: {" ++
        "const result = command();" ++
        "break :fetch b.dupe(u8, result);" ++
        "}; _ = sha; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(std.mem.indexOf(u8, found[0].message, "sha") != null);
}

test "cleanup registered after a fallible operation warns" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "try initialize(buffer);" ++
        "defer allocator.free(buffer);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.cleanup_after_fallible_operation, found[0].rule);
}

test "allocation release must match method and allocator" {
    const wrong_method =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.destroy(buffer);" ++
        "}";
    const method_findings = try warnings(std.testing.allocator, wrong_method);
    defer freeWarnings(std.testing.allocator, method_findings);
    try std.testing.expectEqual(@as(usize, 1), method_findings.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, method_findings[0].rule);

    const wrong_allocator =
        "fn run(allocator: std.mem.Allocator, other: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "other.free(buffer);" ++
        "}";
    const allocator_findings = try warnings(std.testing.allocator, wrong_allocator);
    defer freeWarnings(std.testing.allocator, allocator_findings);
    try std.testing.expectEqual(@as(usize, 1), allocator_findings.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, allocator_findings[0].rule);
}

test "non-allocator dupe methods may pair with destroy" {
    const source =
        "fn run(parsed: anytype) void {" ++
        "const edited_tree = parsed.tree.dupe();" ++
        "defer edited_tree.destroy();" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "double release and use after release are reported in straight line code" {
    const double_release_source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.free(buffer);" ++
        "allocator.free(buffer);" ++
        "}";
    const double_findings = try warnings(std.testing.allocator, double_release_source);
    defer freeWarnings(std.testing.allocator, double_findings);
    var saw_double = false;
    for (double_findings) |finding| {
        if (finding.rule == .double_release) saw_double = true;
    }
    try std.testing.expect(saw_double);

    const use_source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.free(buffer);" ++
        "consume(buffer);" ++
        "}";
    const use_findings = try warnings(std.testing.allocator, use_source);
    defer freeWarnings(std.testing.allocator, use_findings);
    var saw_use = false;
    for (use_findings) |finding| {
        if (finding.rule == .use_after_release) saw_use = true;
    }
    try std.testing.expect(saw_use);
}

test "overwriting an owning allocation before release is reported" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "var buffer = try allocator.alloc(u8, 16);" ++
        "buffer = try allocator.alloc(u8, 32);" ++
        "defer allocator.free(buffer);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    var saw_overwrite = false;
    for (found) |finding| {
        if (finding.rule == .overwritten_owning_value) saw_overwrite = true;
    }
    try std.testing.expect(saw_overwrite);
}

test "allocations through a binding derived from a local arena are exempt" {
    const source =
        "fn tally(gpa: std.mem.Allocator) !void {" ++
        "var scratch = std.heap.ArenaAllocator.init(gpa);" ++
        "defer scratch.deinit();" ++
        "const aa = scratch.allocator();" ++
        "const counts = try aa.alloc(usize, 4);" ++
        "_ = counts;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "releasing a field of the same name is not a release of the local binding" {
    const source =
        "fn rename(self: *Thing, a: std.mem.Allocator, new: []const u8) !void {" ++
        "const name = try a.dupe(u8, new);" ++
        "a.free(self.name);" ++
        "self.name = name;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "reassigning the binding after release ends the released lifetime" {
    const source =
        "fn refill(a: std.mem.Allocator) !void {" ++
        "var buf = try a.alloc(u8, 16);" ++
        "a.free(buf);" ++
        "buf = try a.alloc(u8, 32);" ++
        "fill(buf);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "realloc of the binding itself does not overwrite the owning value" {
    const source =
        "fn grow(a: std.mem.Allocator) !void {" ++
        "var buf = try a.alloc(u8, 8);" ++
        "buf = try a.realloc(buf, 16);" ++
        "a.free(buf);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "passing an allocation to a builtin call is treated as an escape" {
    const source =
        "fn zero(a: std.mem.Allocator) !void {" ++
        "const counts = try a.alloc(u8, 4);" ++
        "@memset(counts, 0);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "double release offers deletion of the duplicate statement" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.free(buffer);" ++
        "allocator.free(buffer);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    var double: ?Warning = null;
    for (found) |warning| {
        if (warning.rule == .double_release) double = warning;
    }
    try std.testing.expect(double != null);
    try std.testing.expectEqual(@as(usize, 1), double.?.fixes.len);
    try std.testing.expect(!double.?.fixes[0].fix_all);
    const edit = double.?.fixes[0].edits[0];
    try std.testing.expectEqualStrings("", edit.replacement);
    try std.testing.expectEqualStrings("allocator.free(buffer);", source[edit.span.start..edit.span.end]);
}

fn freeWarning(allocator: std.mem.Allocator, warning: Warning) void {
    allocator.free(warning.message);
    for (warning.fixes) |fix| {
        for (fix.edits) |edit| allocator.free(edit.replacement);
        allocator.free(fix.edits);
    }
    allocator.free(warning.fixes);
}

fn freeWarnings(allocator: std.mem.Allocator, found: []Warning) void {
    for (found) |warning| freeWarning(allocator, warning);
    allocator.free(found);
}
