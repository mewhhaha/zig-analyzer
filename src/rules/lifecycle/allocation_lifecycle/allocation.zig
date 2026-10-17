//! What the engine knows of an allocation: the `Allocation` a binding's
//! initializer produces (its method, its release, the receiver and the
//! allocator it came from), and the calls, blocks and wrappers that make one.
const std = @import("std");

const syntax_scope = @import("../../../syntax/scope.zig");
const owned_call = @import("../../owned_call.zig");
const resources = @import("../../resources.zig");
const summaries = @import("../../summaries.zig");

pub const Allocation = struct {
    method: []const u8,
    release: []const u8,
    receiver: ?[]const u8,
    allocator_source: ?[]const u8,
    allocator_member: ?[]const u8 = null,
    /// A single-item pointer to an array, which `destroy` releases as well as `free`.
    array_pointer: bool = false,
};

pub fn allocationFromValue(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    value: std.zig.Ast.Node.Index,
    summary_index: summaries.Index,
) ?Allocation {
    return switch (tree.nodeTag(value)) {
        .@"try", .@"nosuspend", .@"comptime" => allocationFromValue(source, tree, tokens, scope_index, tree.nodeData(value).node, summary_index),
        .grouped_expression => allocationFromValue(source, tree, tokens, scope_index, tree.nodeData(value).node_and_token[0], summary_index),
        .@"catch" => allocationFromValue(source, tree, tokens, scope_index, tree.nodeData(value).node_and_node[0], summary_index),
        .@"orelse" => allocationFromValue(source, tree, tokens, scope_index, tree.nodeData(value).node_and_node[0], summary_index) orelse
            allocationFromValue(source, tree, tokens, scope_index, tree.nodeData(value).node_and_node[1], summary_index),
        .block_two, .block_two_semicolon, .block, .block_semicolon => allocationFromBlock(source, tree, tokens, scope_index, value, summary_index),
        .call, .call_comma, .call_one, .call_one_comma => allocationFromCall(source, tree, tokens, scope_index, value, summary_index),
        else => null,
    };
}

fn allocationFromBlock(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    block: std.zig.Ast.Node.Index,
    summary_index: summaries.Index,
) ?Allocation {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return null;
    for (statements) |statement| {
        if (tree.nodeTag(statement) != .@"break") continue;
        const break_value = tree.nodeData(statement).opt_token_and_opt_node[1].unwrap() orelse continue;
        if (allocationFromValue(source, tree, tokens, scope_index, break_value, summary_index)) |allocation| return allocation;
    }
    return null;
}

fn allocationFromCall(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    summary_index: summaries.Index,
) ?Allocation {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) == .identifier) {
        const function_name = tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr));
        const owned = summary_index.ownedReturnCall(source, null, function_name) orelse return null;
        const allocator_argument = if (owned.allocator_parameter) |parameter|
            if (parameter < call.ast.params.len) call.ast.params[parameter] else null
        else
            null;
        return .{
            .method = function_name,
            .release = owned.release,
            .receiver = if (owned.allocator_parameter_member == null)
                if (allocator_argument) |argument|
                    if (tree.nodeTag(argument) == .identifier) tree.tokenSlice(tree.nodeMainToken(argument)) else null
                else
                    null
            else
                null,
            .allocator_source = if (allocator_argument) |argument| allocatorSourceName(source, tokens, tree, argument) else null,
            .allocator_member = owned.allocator_parameter_member,
            .array_pointer = owned.array_pointer,
        };
    }
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
    const method = tree.tokenSlice(method_token);
    const receiver_name = if (tree.nodeTag(receiver) == .identifier) tree.tokenSlice(tree.nodeMainToken(receiver)) else null;
    if ((std.mem.eql(u8, method, "print") or std.mem.eql(u8, method, "printSentinel")) and
        !owned_call.printReceiverIsAllocatorIndexed(scope_index, tree.lastToken(receiver))) return null;
    const callable = source[tokens[tree.firstToken(call.ast.fn_expr)].loc.start..tokens[tree.lastToken(call.ast.fn_expr)].loc.end];
    if (owned_call.standardAllocatorArgument(callable)) |parameter| {
        if (parameter >= call.ast.params.len) return null;
        const allocator_argument = call.ast.params[parameter];
        return .{
            .method = method,
            .release = "free",
            .receiver = if (tree.nodeTag(allocator_argument) == .identifier)
                tree.tokenSlice(tree.nodeMainToken(allocator_argument))
            else
                null,
            .allocator_source = allocatorSourceName(source, tokens, tree, allocator_argument),
        };
    }
    if (resources.allocationRelease(method)) |release| {
        if (std.mem.eql(u8, method, "create") and !expressionLooksLikeAllocationOwner(source, tokens, scope_index, tree, receiver)) return null;
        if (std.mem.eql(u8, release, "free") and !expressionLooksLikeAllocator(source, tokens, scope_index, tree, receiver)) return null;
        return .{
            .method = method,
            .release = release,
            .receiver = receiver_name,
            .allocator_source = allocatorSourceName(source, tokens, tree, receiver),
        };
    }
    const owned = if (receiver_name) |name|
        summary_index.ownedReturnCall(source, name, method) orelse return null
    else
        return null;
    const allocator_argument = if (owned.allocator_parameter) |parameter|
        if (parameter < call.ast.params.len) call.ast.params[parameter] else null
    else
        null;
    const allocator_expression = allocator_argument orelse if (owned.allocator_parameter_member != null) receiver else null;
    return .{
        .method = method,
        .release = owned.release,
        .receiver = if (owned.allocator_parameter_member == null)
            if (allocator_expression) |argument|
                if (tree.nodeTag(argument) == .identifier) tree.tokenSlice(tree.nodeMainToken(argument)) else null
            else
                null
        else
            null,
        .allocator_source = if (allocator_expression) |argument| allocatorSourceName(source, tokens, tree, argument) else null,
        .allocator_member = owned.allocator_parameter_member,
        .array_pointer = owned.array_pointer,
    };
}

fn expressionLooksLikeAllocationOwner(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    tree: *const std.zig.Ast,
    expression: std.zig.Ast.Node.Index,
) bool {
    if (expressionLooksLikeAllocator(source, tokens, scope_index, tree, expression)) return true;
    return switch (tree.nodeTag(expression)) {
        .identifier => std.ascii.findIgnoreCase(tree.tokenSlice(tree.nodeMainToken(expression)), "pool") != null,
        .field_access => std.ascii.findIgnoreCase(tree.tokenSlice(tree.nodeData(expression).node_and_token[1]), "pool") != null,
        else => false,
    };
}

fn expressionLooksLikeAllocator(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    tree: *const std.zig.Ast,
    expression: std.zig.Ast.Node.Index,
) bool {
    return switch (tree.nodeTag(expression)) {
        .identifier => identifier: {
            const name = tree.tokenSlice(tree.nodeMainToken(expression));
            break :identifier std.ascii.findIgnoreCase(name, "alloc") != null or
                std.ascii.findIgnoreCase(name, "arena") != null or
                std.mem.eql(u8, name, "gpa") or identifierHasAllocatorType(source, tokens, scope_index, name);
        },
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

pub fn identifierHasAllocatorType(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    name: []const u8,
) bool {
    var uses = scope_index.identifiersNamed(name, 0, tokens.len);
    while (uses.next()) |identifier_index| {
        if (identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .colon) continue;
        var parenthesis_depth: usize = 0;
        var bracket_depth: usize = 0;
        for (tokens[identifier_index + 2 ..], identifier_index + 2..) |type_token, type_index| {
            switch (type_token.tag) {
                .l_paren => parenthesis_depth += 1,
                .r_paren => {
                    if (parenthesis_depth == 0) break;
                    parenthesis_depth -= 1;
                },
                .l_bracket => bracket_depth += 1,
                .r_bracket => bracket_depth -|= 1,
                .comma, .equal, .semicolon, .l_brace => if (parenthesis_depth == 0 and bracket_depth == 0) break,
                .identifier => if (std.mem.eql(u8, source[type_token.loc.start..type_token.loc.end], "Allocator")) return true,
                else => {},
            }
            if (type_index + 1 >= tokens.len) break;
        }
    }
    return false;
}

fn allocatorSourceName(
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    receiver: std.zig.Ast.Node.Index,
) ?[]const u8 {
    switch (tree.nodeTag(receiver)) {
        .identifier => return tree.tokenSlice(tree.nodeMainToken(receiver)),
        .field_access => return source[tokens[tree.firstToken(receiver)].loc.start..tokens[tree.lastToken(receiver)].loc.end],
        .call, .call_comma, .call_one, .call_one_comma => {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, receiver) orelse return null;
            if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
            _, const field_token = tree.nodeData(call.ast.fn_expr).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(field_token), "allocator")) return null;
            return source[tokens[tree.firstToken(receiver)].loc.start..tokens[tree.lastToken(receiver)].loc.end];
        },
        else => return null,
    }
}
